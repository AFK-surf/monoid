// Real live-network C host E2E test linking `libstillfail_shell.so` + `core_pion.c` +
// `shell_pion.c` + `libpion_core_runtime.a` against a real loopback TCP/HTTP/SSE fake cloud
// and fake station server on `127.0.0.1:<port>`:
//
// Exercises the FULL Slice 2B-1 Invariant 1 end-to-end lifecycle:
// 1. Cold boot on completely EMPTY `data_dir` (unauthenticated):
//    - `account.doc("me")` is `null`, `workspaces.list` is `[]`, `workspace.get`/`draft.put`/`cloud.sync` return `unauthenticated`.
//    - `default.db` is NEVER created on disk!
// 2. Real pure-`query` `auth.begin` -> `auth.complete` (`POST /v1/auth/token`):
//    - Atomically opens & switches ALL DB holders to `account-u-live.db` (still 0 `default.db`!).
//    - Persists TS-compatible `accounts` (epoch seconds `access_expires` + ULID `session`), never leaks tokens/code/verifier.
// 3. Real Rust `fetch` (`cloud.sync` with W1 & W2), pinned origin guard (`origin_mismatch`), local draft (`draft.put`),
//    real SSE reconnect after 503 + `chat.send` -> `OutboxResolved` + <=4KB keyed delta,
//    then W2 revocation via 2nd `cloud.sync` (persisting `completed_purge_gen` in `account-u-live.db`).
// 4. Full restart in authenticated state on the same `data_dir`:
//    - Reopens `account-u-live.db` and preserves local draft, workspace W1, thread/outbox, and W2 revocation (`completed_purge_gen`)!
// 5. Permanent refresh failure (`auth.refresh` -> HTTP 401 `invalid_grant`) removing the last account from disk:
//    - Invalidates session, bumps `session_gen`, stops `CloudSync`, writes empty `accounts` `[]` to disk.
// 6. Full restart in unauthenticated state on the same `data_dir`:
//    - `account.doc("me")` is `null` and `workspaces.list` is `[]` (0 private data leak from `account-u-live.db`)!

#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);
extern void pion_core_test_set_fail_dir_fsync(int32_t enable);

static int64_t mono_ms_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000LL + (int64_t)(ts.tv_nsec / 1000000LL);
}

#define MAX_MSGS 1024
#define WS1_ID "01ARZ3NDEKTSV4RRFFQ69G5FAV"
#define WS2_ID "01ARZ3NDEKTSV4RRFFQ69G5FBW"

typedef struct recorded_msg {
    char *json;
    size_t len;
} recorded_msg_t;

typedef struct host_ctx {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    recorded_msg_t msgs[MAX_MSGS];
    int count;
    _Atomic int stopped;
    _Atomic int post_stop_count;
} host_ctx_t;

static host_ctx_t g_host;

static void reset_host_ctx(host_ctx_t *h) {
    pthread_mutex_lock(&h->mu);
    for (int i = 0; i < h->count; i++) {
        free(h->msgs[i].json);
    }
    h->count = 0;
    pthread_mutex_unlock(&h->mu);
    atomic_store(&h->stopped, 0);
    atomic_store(&h->post_stop_count, 0);
}

static void on_host_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
    (void)bytes;
    (void)blen;
    host_ctx_t *h = (host_ctx_t *)ctx;
    if (atomic_load(&h->stopped)) {
        atomic_fetch_add(&h->post_stop_count, 1);
        return;
    }
    pthread_mutex_lock(&h->mu);
    assert(h->count < MAX_MSGS);
    recorded_msg_t *slot = &h->msgs[h->count++];
    slot->json = (char *)malloc(len + 1);
    assert(slot->json != NULL);
    memcpy(slot->json, json, len);
    slot->json[len] = '\0';
    slot->len = len;
    pthread_cond_broadcast(&h->cv);
    pthread_mutex_unlock(&h->mu);
}

static char *wait_for_matching_msg(host_ctx_t *h, const char *needle1, const char *needle2, int timeout_sec) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_sec;
    pthread_mutex_lock(&h->mu);
    for (;;) {
        for (int i = 0; i < h->count; i++) {
            if (strstr(h->msgs[i].json, needle1) != NULL &&
                (needle2 == NULL || strstr(h->msgs[i].json, needle2) != NULL)) {
                char *found = h->msgs[i].json;
                pthread_mutex_unlock(&h->mu);
                return found;
            }
        }
        int rc = pthread_cond_timedwait(&h->cv, &h->mu, &deadline);
        if (rc == ETIMEDOUT) {
            fprintf(stderr, "[live_net_e2e] TIMEOUT waiting for '%s' (needle2='%s', saw %d msgs):\n",
                    needle1, needle2 ? needle2 : "", h->count);
            for (int i = 0; i < h->count; i++) {
                fprintf(stderr, "  msg[%d]: %s\n", i, h->msgs[i].json);
            }
            pthread_mutex_unlock(&h->mu);
            abort();
        }
    }
}

static void send_json(const char *s) {
    mb_core_send(s, strlen(s), NULL, 0);
}

static int file_exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

// ── Minimal loopback HTTP/1.1 + SSE fake cloud & fake station server ──

typedef struct fake_server {
    int listen_fd;
    uint16_t port;
    pthread_t thread;
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int shutdown;
    int sse_push_ready;
    char pending_sse_event[1024];
    int slow_token_entered;
    int slow_token_release;
    int slow_refresh_hold;
    int slow_refresh_entered;
    int slow_refresh_release;
    int ws1_401_gate_enabled;
    int ws1_401_budget;
    int ws1_200_gate_enabled;
    int ws1_200_budget;
    int ws1_plain_200_gate_enabled;
    int refresh_gate_enabled;
    int refresh_budget;
    char ws1_expected_bearer[64];
    char ws1_hold_401_bearer[80];
    char ws1_me_name[64];
    char ws1_custom_name[64];
    char ws1_custom_station[64];
    int cloud_ws_push_ready;
    char pending_cloud_ws_msg[512];
    _Atomic int cloud_ws_connected;
    _Atomic int enable_cloud_ws;
    _Atomic int refresh_fail_500_remaining;
    _Atomic int ws1_403_once;
    _Atomic int active_http_conns;
    _Atomic int drop_ws2_in_me;
    _Atomic int serve_ws1_lock;
    _Atomic int ws1_downgrade_member; // 0=owner, 1=member, 2=admin
    _Atomic int ws1_require_rotated_token;
    _Atomic int ws2_require_rotated_token;
    _Atomic int ws1_always_401;
    _Atomic int allow_refresh_rotate;
    _Atomic int refresh_rotate_seq;
    _Atomic int got_ws1_401;
    _Atomic int got_ws1_rotated_ok;
    _Atomic int got_ws1_plain_ok;
    _Atomic int got_ws2_401;
    _Atomic int got_ws2_rotated_ok;
    _Atomic int got_me;
    _Atomic int got_ws;
    _Atomic int got_auth_token;
    _Atomic int got_auth_refresh;
    _Atomic int got_events;
    _Atomic int got_post_msg;
} fake_server_t;

static fake_server_t g_srv;

static void wait_srv_atomic_ge(const _Atomic int *counter, int target, int timeout_sec) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_sec;
    pthread_mutex_lock(&g_srv.mu);
    while (atomic_load(counter) < target && !g_srv.shutdown) {
        int rc = pthread_cond_timedwait(&g_srv.cv, &g_srv.mu, &deadline);
        if (rc == ETIMEDOUT && atomic_load(counter) < target) {
            fprintf(stderr, "[live_net_e2e] TIMEOUT waiting for server counter >= %d (got %d)\n",
                    target, atomic_load(counter));
            pthread_mutex_unlock(&g_srv.mu);
            abort();
        }
    }
    pthread_mutex_unlock(&g_srv.mu);
}

static void wait_srv_atomic_eq(const _Atomic int *counter, int target, int timeout_sec) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += timeout_sec;
    pthread_mutex_lock(&g_srv.mu);
    while (atomic_load(counter) != target && !g_srv.shutdown) {
        int rc = pthread_cond_timedwait(&g_srv.cv, &g_srv.mu, &deadline);
        if (rc == ETIMEDOUT && atomic_load(counter) != target) {
            fprintf(stderr, "[live_net_e2e] TIMEOUT waiting for server counter == %d (got %d)\n",
                    target, atomic_load(counter));
            pthread_mutex_unlock(&g_srv.mu);
            abort();
        }
    }
    pthread_mutex_unlock(&g_srv.mu);
}

static void write_all_fd(int fd, const char *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t n = send(fd, buf + off, len - off, 0);
        if (n <= 0) {
            return;
        }
        off += (size_t)n;
    }
}

static uint32_t sha1_rol(uint32_t v, unsigned bits) {
    return (v << bits) | (v >> (32U - bits));
}

static void sha1_digest(const uint8_t *msg, size_t len, uint8_t out[20]) {
    uint32_t h0 = 0x67452301U, h1 = 0xEFCDAB89U, h2 = 0x98BADCFEU, h3 = 0x10325476U, h4 = 0xC3D2E1F0U;
    size_t padded_len = ((len + 9U + 63U) / 64U) * 64U;
    uint8_t *buf = (uint8_t *)calloc(1, padded_len);
    assert(buf != NULL);
    memcpy(buf, msg, len);
    buf[len] = 0x80U;
    uint64_t bit_len = (uint64_t)len * 8ULL;
    for (int i = 0; i < 8; i++) {
        buf[padded_len - 1 - (size_t)i] = (uint8_t)(bit_len >> (i * 8));
    }
    for (size_t off = 0; off < padded_len; off += 64U) {
        uint32_t w[80];
        for (int i = 0; i < 16; i++) {
            w[i] = ((uint32_t)buf[off + i * 4] << 24) |
                   ((uint32_t)buf[off + i * 4 + 1] << 16) |
                   ((uint32_t)buf[off + i * 4 + 2] << 8) |
                   ((uint32_t)buf[off + i * 4 + 3]);
        }
        for (int i = 16; i < 80; i++) {
            w[i] = sha1_rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
        }
        uint32_t a = h0, b = h1, c = h2, d = h3, e = h4;
        for (int i = 0; i < 80; i++) {
            uint32_t f, k;
            if (i < 20) { f = (b & c) | ((~b) & d); k = 0x5A827999U; }
            else if (i < 40) { f = b ^ c ^ d; k = 0x6ED9EBA1U; }
            else if (i < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDCU; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6U; }
            uint32_t tmp = sha1_rol(a, 5) + f + e + k + w[i];
            e = d; d = c; c = sha1_rol(b, 30); b = a; a = tmp;
        }
        h0 += a; h1 += b; h2 += c; h3 += d; h4 += e;
    }
    free(buf);
    uint32_t hs[5] = { h0, h1, h2, h3, h4 };
    for (int i = 0; i < 5; i++) {
        out[i * 4] = (uint8_t)(hs[i] >> 24);
        out[i * 4 + 1] = (uint8_t)(hs[i] >> 16);
        out[i * 4 + 2] = (uint8_t)(hs[i] >> 8);
        out[i * 4 + 3] = (uint8_t)(hs[i]);
    }
}

static void base64_encode_20(const uint8_t in[20], char out[32]) {
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    int o = 0;
    for (int i = 0; i < 20; i += 3) {
        uint32_t v = ((uint32_t)in[i] << 16) |
                     ((i + 1 < 20 ? (uint32_t)in[i + 1] : 0U) << 8) |
                     (i + 2 < 20 ? (uint32_t)in[i + 2] : 0U);
        out[o++] = tbl[(v >> 18) & 63U];
        out[o++] = tbl[(v >> 12) & 63U];
        out[o++] = (i + 1 < 20) ? tbl[(v >> 6) & 63U] : '=';
        out[o++] = (i + 2 < 20) ? tbl[v & 63U] : '=';
    }
    out[o] = '\0';
}

static void ws_send_text_frame(int fd, const char *text) {
    size_t len = strlen(text);
    uint8_t hdr[4];
    size_t hlen = 0;
    hdr[hlen++] = 0x81U; // FIN + text opcode
    if (len < 126U) {
        hdr[hlen++] = (uint8_t)len;
    } else {
        hdr[hlen++] = 126U;
        hdr[hlen++] = (uint8_t)(len >> 8);
        hdr[hlen++] = (uint8_t)(len & 0xFFU);
    }
    write_all_fd(fd, (const char *)hdr, hlen);
    write_all_fd(fd, text, len);
}

static void send_http_json(int fd, int status, const char *status_text, const char *body) {
    char resp[4096];
    int n = snprintf(
        resp,
        sizeof(resp),
        "HTTP/1.1 %d %s\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n%s",
        status,
        status_text,
        strlen(body),
        body);
    assert(n > 0 && (size_t)n < sizeof(resp));
    write_all_fd(fd, resp, (size_t)n);
}

static void *handle_client_body(int fd, int *counted) {
    char buf[8192];
    size_t used = 0;
    size_t header_end = 0;
    size_t content_len = 0;

    while (used + 1 < sizeof(buf)) {
        ssize_t n = recv(fd, buf + used, sizeof(buf) - 1 - used, 0);
        if (n <= 0) {
            break;
        }
        used += (size_t)n;
        buf[used] = '\0';
        char *sep = strstr(buf, "\r\n\r\n");
        if (sep != NULL) {
            header_end = (size_t)(sep - buf) + 4;
            char *cl = strstr(buf, "content-length:");
            if (cl == NULL) {
                cl = strstr(buf, "Content-Length:");
            }
            if (cl != NULL && cl < sep) {
                content_len = (size_t)strtoul(cl + 15, NULL, 10);
            }
            if (used >= header_end + content_len) {
                break;
            }
        }
    }

    if (header_end == 0) {
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/events", 14) == 0 && atomic_load(&g_srv.enable_cloud_ws)) {
        const char *kh = strstr(buf, "Sec-WebSocket-Key:");
        if (kh == NULL) kh = strstr(buf, "sec-websocket-key:");
        if (kh != NULL) {
            kh += 18;
            while (*kh == ' ' || *kh == '\t') kh++;
            char key[128];
            size_t ki = 0;
            while (kh[ki] != '\0' && kh[ki] != '\r' && kh[ki] != '\n' && ki + 1 < sizeof(key)) {
                key[ki] = kh[ki];
                ki++;
            }
            key[ki] = '\0';
            char concat[256];
            snprintf(concat, sizeof(concat), "%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11", key);
            uint8_t sha[20];
            sha1_digest((const uint8_t *)concat, strlen(concat), sha);
            char accept_b64[32];
            base64_encode_20(sha, accept_b64);
            char resp[512];
            snprintf(
                resp,
                sizeof(resp),
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                "Sec-WebSocket-Accept: %s\r\n"
                "Sec-WebSocket-Protocol: stillfail-events\r\n\r\n",
                accept_b64);
            write_all_fd(fd, resp, strlen(resp));
            int my_ws_gen = 0;
            if (*counted) {
                *counted = 0;
                pthread_mutex_lock(&g_srv.mu);
                atomic_fetch_sub(&g_srv.active_http_conns, 1);
                my_ws_gen = atomic_fetch_add(&g_srv.cloud_ws_connected, 1) + 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
            }
            pthread_mutex_lock(&g_srv.mu);
            while (!g_srv.shutdown && atomic_load(&g_srv.enable_cloud_ws) && atomic_load(&g_srv.cloud_ws_connected) == my_ws_gen) {
                if (g_srv.cloud_ws_push_ready) {
                    char msg[512];
                    memcpy(msg, g_srv.pending_cloud_ws_msg, sizeof(msg));
                    g_srv.cloud_ws_push_ready = 0;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);
                    ws_send_text_frame(fd, msg);
                    pthread_mutex_lock(&g_srv.mu);
                } else {
                    pthread_cond_wait(&g_srv.cv, &g_srv.mu);
                }
            }
            pthread_mutex_unlock(&g_srv.mu);
            close(fd);
            return NULL;
        }
    }

    if (strncmp(buf, "GET /v1/me ", 11) == 0) {
        pthread_mutex_lock(&g_srv.mu);
        atomic_fetch_add(&g_srv.got_me, 1);
        char me_ws1_name[64];
        snprintf(me_ws1_name, sizeof(me_ws1_name), "%s", g_srv.ws1_me_name[0] ? g_srv.ws1_me_name : "Live Workspace");
        pthread_cond_broadcast(&g_srv.cv);
        pthread_mutex_unlock(&g_srv.mu);
        int rmode = atomic_load(&g_srv.ws1_downgrade_member);
        const char *ws1_role = (rmode == 2) ? "admin" : ((rmode == 1) ? "member" : "owner");
        if (atomic_load(&g_srv.drop_ws2_in_me)) {
            char body[1024];
            snprintf(
                body,
                sizeof(body),
                "{\"user\":{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\"},"
                "\"workspaces\":[{\"id\":\"" WS1_ID "\",\"name\":\"%s\",\"role\":\"%s\",\"created_at\":1700000000,\"stations\":1,\"members\":1}],"
                "\"relay_urls\":[\"https://relay.live.example\"]}",
                me_ws1_name,
                ws1_role);
            send_http_json(fd, 200, "OK", body);
        } else {
            char body[1024];
            snprintf(
                body,
                sizeof(body),
                "{\"user\":{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\"},"
                "\"workspaces\":["
                "{\"id\":\"" WS1_ID "\",\"name\":\"%s\",\"role\":\"%s\",\"created_at\":1700000000,\"stations\":1,\"members\":1},"
                "{\"id\":\"" WS2_ID "\",\"name\":\"Drop Me WS\",\"role\":\"member\",\"created_at\":1700000001,\"stations\":1,\"members\":2}"
                "],"
                "\"relay_urls\":[\"https://relay.live.example\"]}",
                me_ws1_name,
                ws1_role);
            send_http_json(fd, 200, "OK", body);
        }
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/workspaces/" WS1_ID " ", 46) == 0) {
        atomic_fetch_add(&g_srv.got_ws, 1);
        if (atomic_exchange(&g_srv.ws1_403_once, 0) != 0) {
            send_http_json(fd, 403, "Forbidden", "{\"error\":\"trigger_reconcile\"}");
            close(fd);
            return NULL;
        }
        if (atomic_load(&g_srv.ws1_always_401)) {
            pthread_mutex_lock(&g_srv.mu);
            atomic_fetch_add(&g_srv.got_ws1_401, 1);
            pthread_cond_broadcast(&g_srv.cv);
            while (g_srv.ws1_401_gate_enabled && g_srv.ws1_401_budget <= 0 && !g_srv.shutdown) {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
            if (g_srv.ws1_401_gate_enabled && g_srv.ws1_401_budget > 0) {
                g_srv.ws1_401_budget -= 1;
            }
            pthread_mutex_unlock(&g_srv.mu);
            send_http_json(fd, 401, "Unauthorized", "{\"error\":\"persistent_401\"}");
            close(fd);
            return NULL;
        }
        if (atomic_load(&g_srv.ws1_require_rotated_token)) {
            pthread_mutex_lock(&g_srv.mu);
            char expected_hdr[96];
            if (g_srv.ws1_expected_bearer[0] != '\0') {
                snprintf(expected_hdr, sizeof(expected_hdr), "Bearer %s", g_srv.ws1_expected_bearer);
            } else {
                snprintf(expected_hdr, sizeof(expected_hdr), "Bearer acc-rotated-99");
            }
            pthread_mutex_unlock(&g_srv.mu);
            if (strstr(buf, expected_hdr) == NULL) {
                pthread_mutex_lock(&g_srv.mu);
                atomic_fetch_add(&g_srv.got_ws1_401, 1);
                pthread_cond_broadcast(&g_srv.cv);
                int should_hold = g_srv.ws1_401_gate_enabled &&
                    (g_srv.ws1_hold_401_bearer[0] == '\0' || strstr(buf, g_srv.ws1_hold_401_bearer) != NULL);
                if (should_hold) {
                    while (g_srv.ws1_401_gate_enabled && g_srv.ws1_401_budget <= 0 && !g_srv.shutdown) {
                        pthread_cond_wait(&g_srv.cv, &g_srv.mu);
                    }
                    if (g_srv.ws1_401_gate_enabled && g_srv.ws1_401_budget > 0) {
                        g_srv.ws1_401_budget -= 1;
                    }
                }
                pthread_mutex_unlock(&g_srv.mu);
                send_http_json(fd, 401, "Unauthorized", "{\"error\":\"token_expired\"}");
                close(fd);
                return NULL;
            }
            pthread_mutex_lock(&g_srv.mu);
            atomic_fetch_add(&g_srv.got_ws1_rotated_ok, 1);
            char wname[64], sname[64];
            snprintf(wname, sizeof(wname), "%s", g_srv.ws1_custom_name[0] ? g_srv.ws1_custom_name : "Live Member Workspace");
            snprintf(sname, sizeof(sname), "%s", g_srv.ws1_custom_station[0] ? g_srv.ws1_custom_station : "Live Member Station");
            pthread_cond_broadcast(&g_srv.cv);
            while (g_srv.ws1_200_gate_enabled && g_srv.ws1_200_budget <= 0 && !g_srv.shutdown) {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
            if (g_srv.ws1_200_gate_enabled && g_srv.ws1_200_budget > 0) {
                g_srv.ws1_200_budget -= 1;
            }
            pthread_mutex_unlock(&g_srv.mu);
            int rmode = atomic_load(&g_srv.ws1_downgrade_member);
            const char *role_str = (rmode == 2) ? "admin" : ((rmode == 1) ? "member" : "owner");
            char wbody[1024];
            snprintf(
                wbody,
                sizeof(wbody),
                "{\"id\":\"" WS1_ID "\",\"name\":\"%s\",\"rev\":2,\"role\":\"%s\","
                "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"%s\"}],"
                "\"stations\":[{\"id\":\"st-local\",\"name\":\"%s\",\"online\":true}]}",
                wname,
                role_str,
                role_str,
                sname);
            send_http_json(fd, 200, "OK", wbody);
            close(fd);
            return NULL;
        }
        pthread_mutex_lock(&g_srv.mu);
        atomic_fetch_add(&g_srv.got_ws1_plain_ok, 1);
        char wname[64], sname[64];
        snprintf(wname, sizeof(wname), "%s", g_srv.ws1_custom_name[0] ? g_srv.ws1_custom_name : "Live Workspace");
        snprintf(sname, sizeof(sname), "%s", g_srv.ws1_custom_station[0] ? g_srv.ws1_custom_station : "Live Station");
        pthread_cond_broadcast(&g_srv.cv);
        while (g_srv.ws1_plain_200_gate_enabled && !g_srv.shutdown) {
            pthread_cond_wait(&g_srv.cv, &g_srv.mu);
        }
        pthread_mutex_unlock(&g_srv.mu);
        int rmode = atomic_load(&g_srv.ws1_downgrade_member);
        const char *role_str = (rmode == 2) ? "admin" : ((rmode == 1) ? "member" : "owner");
        char wbody[1024];
        snprintf(
            wbody,
            sizeof(wbody),
            "{\"id\":\"" WS1_ID "\",\"name\":\"%s\",\"rev\":1,\"role\":\"%s\","
            "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"%s\"}],"
            "\"stations\":[{\"id\":\"st-local\",\"name\":\"%s\",\"online\":true}]}",
            wname,
            role_str,
            role_str,
            sname);
        send_http_json(fd, 200, "OK", wbody);
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/workspaces/" WS2_ID " ", 46) == 0) {
        atomic_fetch_add(&g_srv.got_ws, 1);
        if (atomic_load(&g_srv.ws2_require_rotated_token)) {
            pthread_mutex_lock(&g_srv.mu);
            char expected_hdr[96];
            if (g_srv.ws1_expected_bearer[0] != '\0') {
                snprintf(expected_hdr, sizeof(expected_hdr), "Bearer %s", g_srv.ws1_expected_bearer);
            } else {
                snprintf(expected_hdr, sizeof(expected_hdr), "Bearer acc-rotated-99");
            }
            pthread_mutex_unlock(&g_srv.mu);
            if (strstr(buf, expected_hdr) == NULL) {
                pthread_mutex_lock(&g_srv.mu);
                atomic_fetch_add(&g_srv.got_ws2_401, 1);
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                send_http_json(fd, 401, "Unauthorized", "{\"error\":\"token_expired\"}");
                close(fd);
                return NULL;
            }
            pthread_mutex_lock(&g_srv.mu);
            atomic_fetch_add(&g_srv.got_ws2_rotated_ok, 1);
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
        }
        send_http_json(
            fd,
            200,
            "OK",
            "{\"id\":\"" WS2_ID "\",\"name\":\"Drop Me WS\",\"rev\":1,"
            "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"member\"}],"
            "\"stations\":[{\"id\":\"st-drop\",\"name\":\"Drop Station\",\"online\":true}]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "POST /v1/auth/token ", 20) == 0) {
        const char *body = buf + header_end;
        assert(strstr(body, "\"code_verifier\":\"") != NULL);
        assert(strstr(body, "\"redirect_uri\":\"stillfail://auth/callback\"") != NULL);
        atomic_fetch_add(&g_srv.got_auth_token, 1);
        if (strstr(body, "\"code\":\"live_oauth_code_slow_cancel\"") != NULL ||
            strstr(body, "\"code\":\"live_oauth_code_slow_alice\"") != NULL) {
            int is_alice = strstr(body, "\"code\":\"live_oauth_code_slow_alice\"") != NULL;
            pthread_mutex_lock(&g_srv.mu);
            g_srv.slow_token_entered = 1;
            pthread_cond_broadcast(&g_srv.cv);
            while (!g_srv.slow_token_release && !g_srv.shutdown) {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
            pthread_mutex_unlock(&g_srv.mu);
            if (is_alice) {
                send_http_json(
                    fd,
                    200,
                    "OK",
                    "{\"access_token\":\"acc-alice-cancelled\",\"refresh_token\":\"ref-alice-cancelled\","
                    "\"subject\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"expires_at\":1900000000}");
            } else {
                send_http_json(
                    fd,
                    200,
                    "OK",
                    "{\"access_token\":\"acc-slow-1\",\"refresh_token\":\"ref-slow-1\","
                    "\"subject\":\"u-slow\",\"email\":\"slow@still.fail\",\"name\":\"Slow\",\"expires_at\":1900000000}");
            }
        } else if (strstr(body, "\"code\":\"live_oauth_code_bob\"") != NULL) {
            send_http_json(
                fd,
                200,
                "OK",
                "{\"access_token\":\"acc-bob-1\",\"refresh_token\":\"ref-bob-1\","
                "\"subject\":\"u-bob\",\"email\":\"bob@still.fail\",\"name\":\"Bob\",\"expires_at\":1900000000}");
        } else {
            assert(strstr(body, "\"code\":\"live_oauth_code_42\"") != NULL);
            send_http_json(
                fd,
                200,
                "OK",
                "{\"access_token\":\"acc-exchanged-42\",\"refresh_token\":\"ref-exchanged-42\","
                "\"subject\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"expires_at\":1900000000}");
        }
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "POST /v1/auth/refresh ", 22) == 0) {
        const char *body = buf + header_end;
        assert(strstr(body, "\"request_id\":\"") != NULL);
        assert(strstr(body, "\"refresh_token\":\"ref-exchanged-42\"") != NULL ||
               strstr(body, "\"refresh_token\":\"ref-bob-1\"") != NULL ||
               strstr(body, "\"refresh_token\":\"ref-rotated-") != NULL);
        pthread_mutex_lock(&g_srv.mu);
        atomic_fetch_add(&g_srv.got_auth_refresh, 1);
        pthread_cond_broadcast(&g_srv.cv);
        if (g_srv.slow_refresh_hold) {
            g_srv.slow_refresh_entered = 1;
            pthread_cond_broadcast(&g_srv.cv);
            while (!g_srv.slow_refresh_release && !g_srv.shutdown) {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
        }
        while (g_srv.refresh_gate_enabled && g_srv.refresh_budget <= 0 && !g_srv.shutdown) {
            pthread_cond_wait(&g_srv.cv, &g_srv.mu);
        }
        if (g_srv.refresh_gate_enabled && g_srv.refresh_budget > 0) {
            g_srv.refresh_budget -= 1;
        }
        pthread_mutex_unlock(&g_srv.mu);
        int fail500 = atomic_load(&g_srv.refresh_fail_500_remaining);
        while (fail500 > 0) {
            if (atomic_compare_exchange_weak(&g_srv.refresh_fail_500_remaining, &fail500, fail500 - 1)) {
                send_http_json(fd, 500, "Internal Server Error", "{\"error\":\"transient_refresh_500\"}");
                close(fd);
                return NULL;
            }
        }
        if (atomic_load(&g_srv.allow_refresh_rotate) &&
            (strstr(body, "\"refresh_token\":\"ref-exchanged-42\"") != NULL ||
             strstr(body, "\"refresh_token\":\"ref-rotated-") != NULL)) {
            int seq = atomic_fetch_add(&g_srv.refresh_rotate_seq, 1) + 1;
            char rbody[512];
            if (seq == 1) {
                snprintf(
                    rbody,
                    sizeof(rbody),
                    "{\"access_token\":\"acc-rotated-99\",\"refresh_token\":\"ref-rotated-99\","
                    "\"expires_at\":1900001000,\"name\":\"Alice\"}");
            } else {
                snprintf(
                    rbody,
                    sizeof(rbody),
                    "{\"access_token\":\"acc-rotated-%d\",\"refresh_token\":\"ref-rotated-%d\","
                    "\"expires_at\":1900001000,\"name\":\"Alice\"}",
                    99 + seq,
                    99 + seq);
            }
            send_http_json(fd, 200, "OK", rbody);
        } else {
            send_http_json(fd, 401, "Unauthorized", "{\"error\":\"invalid_grant\"}");
        }
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /chats ", 11) == 0) {
        send_http_json(fd, 200, "OK", "{\"chats\":[],\"entries\":[]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /lock ", 10) == 0 && atomic_load(&g_srv.serve_ws1_lock)) {
        send_http_json(
            fd,
            200,
            "OK",
            "{\"head\":{\"seq\":0,"
            "\"hash\":\"133454df5fac09e1946014d43cc066d2daed6c1108a806366ed51ccec959e409\","
            "\"genesis\":\"133454df5fac09e1946014d43cc066d2daed6c1108a806366ed51ccec959e409\"},"
            "\"entries\":[{\"v\":1,\"ws\":\"" WS1_ID "\",\"seq\":0,\"prev\":null,\"at\":1700000000,\"kind\":\"genesis\","
            "\"body\":{\"owner\":\"u-live\",\"origins\":[\"https://app.still.fail\"],\"rp_id\":\"still.fail\","
            "\"cloud_keys\":{\"keys\":[]},"
            "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"owner\"}],"
            "\"devices\":[{\"id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
            "\"sub\":\"u-live\",\"kind\":\"app\",\"label\":\"Alice\","
            "\"sign_key\":\"ed25519:2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12\"}],"
            "\"passkeys\":[],\"stations\":[],\"gateways\":[]},"
            "\"sig\":{\"key\":\"ed25519:2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12\","
            "\"alg\":\"Ed25519\","
            "\"sig\":\"9f0011ddc00e1c06d11a1e73628377a9f048f7737c88e1c110b8723f36c95af83816e75a569d58d6a5441bb27d4524abdb765859ffedf53ca0a3a3e9eac4d80c\"}}]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /events", 11) == 0) {
        int ev_attempt = atomic_fetch_add(&g_srv.got_events, 1) + 1;
        if (ev_attempt == 1) {
            send_http_json(fd, 503, "Service Unavailable", "{\"error\":\"retry\"}");
            close(fd);
            return NULL;
        }
        static const char sse_head[] =
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: text/event-stream\r\n"
            "Cache-Control: no-cache\r\n"
            "Connection: keep-alive\r\n\r\n"
            ": connected\n\n";
        write_all_fd(fd, sse_head, sizeof(sse_head) - 1);
        if (*counted) {
            *counted = 0;
            pthread_mutex_lock(&g_srv.mu);
            atomic_fetch_sub(&g_srv.active_http_conns, 1);
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
        }

        pthread_mutex_lock(&g_srv.mu);
        while (!g_srv.shutdown) {
            if (g_srv.sse_push_ready) {
                char ev[1024];
                memcpy(ev, g_srv.pending_sse_event, sizeof(ev));
                g_srv.sse_push_ready = 0;
                pthread_mutex_unlock(&g_srv.mu);
                write_all_fd(fd, ev, strlen(ev));
                pthread_mutex_lock(&g_srv.mu);
            } else {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
        }
        pthread_mutex_unlock(&g_srv.mu);
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "POST /threads/42/messages ", 26) == 0) {
        const char *body = buf + header_end;
        assert(strstr(body, "ck-live-net-1") != NULL);
        assert(strstr(body, "hello over real rust shell") != NULL);
        atomic_fetch_add(&g_srv.got_post_msg, 1);
        send_http_json(fd, 202, "Accepted", "{\"accepted\":true}");
        close(fd);

        pthread_mutex_lock(&g_srv.mu);
        snprintf(
            g_srv.pending_sse_event,
            sizeof(g_srv.pending_sse_event),
            "id: 101\nevent: thread\ndata: {\"workspace\":\"ws-default\",\"id\":42,\"entries\":[{\"n\":7,\"kind\":\"message\","
            "\"authorKind\":\"person\",\"author\":\"alice\","
            "\"text\":\"hello over real rust shell\",\"clientKey\":\"ck-live-net-1\"}]}\n\n");
        g_srv.sse_push_ready = 1;
        pthread_cond_broadcast(&g_srv.cv);
        pthread_mutex_unlock(&g_srv.mu);
        return NULL;
    }

    send_http_json(fd, 404, "Not Found", "{\"error\":\"not_found\"}");
    close(fd);
    return NULL;
}

static void *handle_client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    int counted = 1;
    (void)handle_client_body(fd, &counted);
    if (counted) {
        pthread_mutex_lock(&g_srv.mu);
        atomic_fetch_sub(&g_srv.active_http_conns, 1);
        pthread_cond_broadcast(&g_srv.cv);
        pthread_mutex_unlock(&g_srv.mu);
    }
    return NULL;
}

static void *server_accept_loop(void *arg) {
    (void)arg;
    for (;;) {
        int cfd = accept(g_srv.listen_fd, NULL, NULL);
        if (cfd < 0) {
            pthread_mutex_lock(&g_srv.mu);
            int done = g_srv.shutdown;
            pthread_mutex_unlock(&g_srv.mu);
            if (done) {
                break;
            }
            continue;
        }
        pthread_mutex_lock(&g_srv.mu);
        atomic_fetch_add(&g_srv.active_http_conns, 1);
        pthread_mutex_unlock(&g_srv.mu);
        pthread_t th;
        if (pthread_create(&th, NULL, handle_client_thread, (void *)(intptr_t)cfd) == 0) {
            pthread_detach(th);
        } else {
            pthread_mutex_lock(&g_srv.mu);
            atomic_fetch_sub(&g_srv.active_http_conns, 1);
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
            close(cfd);
        }
    }
    return NULL;
}

static void start_fake_server(void) {
    memset(&g_srv, 0, sizeof(g_srv));
    pthread_mutex_init(&g_srv.mu, NULL);
    pthread_cond_init(&g_srv.cv, NULL);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(fd >= 0);
    int opt = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    assert(bind(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(fd, 16) == 0);

    socklen_t alen = sizeof(addr);
    assert(getsockname(fd, (struct sockaddr *)&addr, &alen) == 0);
    g_srv.listen_fd = fd;
    g_srv.port = ntohs(addr.sin_port);
    assert(pthread_create(&g_srv.thread, NULL, server_accept_loop, NULL) == 0);
}

static void stop_fake_server(void) {
    pthread_mutex_lock(&g_srv.mu);
    g_srv.shutdown = 1;
    pthread_cond_broadcast(&g_srv.cv);
    pthread_mutex_unlock(&g_srv.mu);
    shutdown(g_srv.listen_fd, SHUT_RDWR);
    close(g_srv.listen_fd);
    pthread_join(g_srv.thread, NULL);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    memset(&g_host, 0, sizeof(g_host));
    pthread_mutex_init(&g_host.mu, NULL);
    pthread_cond_init(&g_host.cv, NULL);

    start_fake_server();
    char origin[128];
    snprintf(origin, sizeof(origin), "http://127.0.0.1:%u", (unsigned)g_srv.port);

    char data_dir[128];
    snprintf(data_dir, sizeof(data_dir), "/tmp/pion_live_net_e2e_%ld_%d", (long)time(NULL), (int)getpid());
    char default_db_path[256];
    snprintf(default_db_path, sizeof(default_db_path), "%s/databases/default.db", data_dir);
    char alice_db_path[256];
    snprintf(alice_db_path, sizeof(alice_db_path), "%s/databases/account-u-live.db", data_dir);

    // ── PHASE 1: Empty directory cold boot (unauthenticated) ──
    printf("[live_net_e2e] Phase 1: empty dir cold boot origin=%s dir=%s\n", origin, data_dir);
    mb_core_attach_pion_runtime();
    mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
    wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);

    send_json("{\"id\":1001,\"call\":\"account.doc\",\"params\":{\"name\":\"me\"}}");
    char *m_unauth_me = wait_for_matching_msg(&g_host, "\"id\":1001,", "\"ok\":null", 10);
    printf("[live_net_e2e] unauth account.doc(me) -> %s\n", m_unauth_me);

    send_json("{\"id\":1002,\"call\":\"workspaces.list\",\"params\":{}}");
    char *m_unauth_ws = wait_for_matching_msg(&g_host, "\"id\":1002,", "\"workspaces\":[]", 10);
    printf("[live_net_e2e] unauth workspaces.list -> %s\n", m_unauth_ws);

    send_json("{\"id\":1003,\"call\":\"cloud.sync\",\"params\":{}}");
    wait_for_matching_msg(&g_host, "\"id\":1003,", "unauthenticated", 10);

    send_json("{\"id\":1004,\"call\":\"draft.put\",\"params\":{\"key\":\"new:" WS1_ID "\",\"value\":{\"text\":\"no\"}}}");
    wait_for_matching_msg(&g_host, "\"id\":1004,", "unauthenticated", 10);

    assert(!file_exists(default_db_path));

    // ── PHASE 2: First sign-in via pure-`query` `auth.begin` -> `auth.complete` (`POST /v1/auth/token`) ──
    // Atomically opens & switches ALL DB holders to `account-u-live.db` BEFORE persisting `accounts`!
    send_json("{\"id\":20,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
    char *m_auth = wait_for_matching_msg(&g_host, "\"id\":20,", "\"url\":\"http", 10);
    printf("[live_net_e2e] #20 auth.begin -> %s\n", m_auth);
    assert(strstr(m_auth, "/v1/auth/google/start?state=") != NULL);
    assert(strstr(m_auth, "code_challenge_method=S256") != NULL);
    assert(strstr(m_auth, "verifier") == NULL);
    const char *st_p = strstr(m_auth, "\"state\":\"");
    assert(st_p != NULL);
    st_p += 9;
    char oauth_state[128];
    size_t oi = 0;
    while (st_p[oi] != '\0' && st_p[oi] != '"' && oi + 1 < sizeof(oauth_state)) {
        oauth_state[oi] = st_p[oi];
        oi++;
    }
    oauth_state[oi] = '\0';
    assert(oi > 0);
    char complete_cmd[512];
    snprintf(complete_cmd, sizeof(complete_cmd),
             "{\"id\":21,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_42\"}}",
             oauth_state);
    send_json(complete_cmd);
    char *m_auth_done = wait_for_matching_msg(&g_host, "\"id\":21,", "\"email\":\"alice@still.fail\"", 10);
    printf("[live_net_e2e] #21 auth.complete pure query -> %s\n", m_auth_done);
    assert(strstr(m_auth_done, "\"returnTo\":\"/\"") != NULL);
    assert(strstr(m_auth_done, "acc-exchanged-42") == NULL && strstr(m_auth_done, "ref-exchanged-42") == NULL);
    assert(strstr(m_auth_done, "live_oauth_code_42") == NULL && strstr(m_auth_done, "verifier") == NULL);
    assert(atomic_load(&g_srv.got_auth_token) == 1);
    assert(file_exists(alice_db_path));
    assert(!file_exists(default_db_path));

    // ── PHASE 3: Cloud sync (W1+W2), origin guard, local draft, SSE + outbox, and W2 drop (`completed_purge_gen`) ──
    send_json("{\"id\":1,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
    char *m_cloud = wait_for_matching_msg(&g_host, "\"id\":1,", "\"workspace\":\"" WS1_ID "\"", 10);
    printf("[live_net_e2e] #1 cloud.sync W1 -> %s\n", m_cloud);
    assert(strstr(m_cloud, "\"email\":\"alice@still.fail\"") != NULL);
    assert(strstr(m_cloud, "\"stations\":1") != NULL);

    send_json("{\"id\":102,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS2_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":102,", "\"workspace\":\"" WS2_ID "\"", 10);

    // Pinned trusted origin guard + strict ULID workspace parameter check in `cloud.sync`:
    send_json("{\"id\":101,\"call\":\"cloud.sync\",\"params\":{\"origin\":\"https://evil.example\"}}");
    char *m_bad_orig = wait_for_matching_msg(&g_host, "\"id\":101,", "origin_mismatch", 10);
    printf("[live_net_e2e] #101 cloud.sync foreign origin rejected -> %s\n", m_bad_orig);

    send_json("{\"id\":107,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"not-a-ulid\"}}");
    wait_for_matching_msg(&g_host, "\"id\":107,", "bad_params", 10);

    // Write local draft for WS1 (`new:<WS1>`) and WS2 (`new:<WS2>`).
    send_json("{\"id\":103,\"call\":\"draft.put\",\"params\":{\"key\":\"new:" WS1_ID "\",\"value\":{\"text\":\"persisted-alice-draft\"}}}");
    wait_for_matching_msg(&g_host, "\"id\":103,", "\"ok\"", 10);
    send_json("{\"id\":104,\"call\":\"draft.put\",\"params\":{\"key\":\"new:" WS2_ID "\",\"value\":{\"text\":\"drop-me-draft\"}}}");
    wait_for_matching_msg(&g_host, "\"id\":104,", "\"ok\"", 10);

    // Subscribe to real `packages/views` projections: workspaces, stations, chats, chat, lock, vaults
    send_json("{\"id\":10,\"subscribe\":{\"topic\":\"workspaces\"},\"keyed\":true}");
    char *m_ws_sub = wait_for_matching_msg(&g_host, "\"id\":10,", "\"workspaces\"", 10);
    assert(strstr(m_ws_sub, "Live Workspace") != NULL);

    send_json("{\"id\":11,\"subscribe\":{\"topic\":\"stations\",\"scope\":\"" WS1_ID "\"},\"keyed\":true}");
    wait_for_matching_msg(&g_host, "\"id\":11,", "Live Station", 10);

    send_json("{\"id\":12,\"subscribe\":{\"topic\":\"chats\",\"scope\":\"" WS1_ID "\"},\"keyed\":true}");
    wait_for_matching_msg(&g_host, "\"id\":12,", "\"days\"", 10);

    send_json("{\"id\":13,\"subscribe\":{\"topic\":\"chat\",\"station\":\"st-local\",\"thread\":42},\"keyed\":true}");
    wait_for_matching_msg(&g_host, "\"id\":13,", "\"messages\"", 10);

    send_json("{\"id\":14,\"subscribe\":{\"topic\":\"lock\",\"workspace\":\"" WS1_ID "\"},\"keyed\":true}");
    char *m_lock_sub = wait_for_matching_msg(&g_host, "\"id\":14,", "\"locked\":false", 10);
    assert(strstr(m_lock_sub, "\xe4\xb8\xaa\xe4\xba\xba\xe9\x94\x81") == NULL);

    send_json("{\"id\":15,\"subscribe\":{\"topic\":\"vaults\",\"workspace\":\"" WS1_ID "\"},\"keyed\":true}");
    wait_for_matching_msg(&g_host, "\"id\":15,", "\"vaults\"", 10);

    // Real Rust `stream.open` + `stream.read` -> first /events returns 503 -> timer reconnect -> SSE `OutboxResolved` + <=4KB keyed delta!
    send_json("{\"id\":2,\"call\":\"station.connect\",\"params\":{}}");
    wait_for_matching_msg(&g_host, "\"event\":\"connection\"", "\"state\":\"connected\"", 10);
    assert(atomic_load(&g_srv.got_events) >= 2);

    send_json("{\"id\":3,\"call\":\"chat.send\",\"params\":{\"thread\":42,\"clientKey\":\"ck-live-net-1\",\"author\":\"alice\",\"text\":\"hello over real rust shell\"}}");
    wait_for_matching_msg(&g_host, "\"id\":3,", "\"queued\":true", 10);

    char *m_resolved = wait_for_matching_msg(&g_host, "\"event\":\"outbox.resolved\"", "\"clientKey\":\"ck-live-net-1\"", 10);
    assert(strstr(m_resolved, "\"n\":7") != NULL);
    assert(atomic_load(&g_srv.got_post_msg) == 1);

    char *m_chat_delta = wait_for_matching_msg(&g_host, "\"id\":13,", "\"seq\":7", 10);
    assert(strstr(m_chat_delta, "\"delta\"") != NULL);
    assert(strstr(m_chat_delta, "hello over real rust shell") != NULL);
    assert(strlen(m_chat_delta) <= 4096);

    // Revoke WS2 via 2nd `/v1/me` reconcile -> atomically purges WS2 + persists `completed_purge_gen[WS2]` in `account-u-live.db`!
    atomic_store(&g_srv.drop_ws2_in_me, 1);
    send_json("{\"id\":105,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":105,", "\"workspaces\":1", 10);
    send_json("{\"id\":106,\"call\":\"workspace.get\",\"params\":{\"workspace\":\"" WS2_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":106,", "access_revoked", 10);

    assert(!file_exists(default_db_path));

    // Stop cleanly before Phase 4 authenticated restart.
    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    assert(atomic_load(&g_host.post_stop_count) == 0);

    // ── PHASE 4: Authenticated restart — verify `account-u-live.db` data & `completed_purge_gen` survived! ──
    printf("[live_net_e2e] Phase 4: authenticated restart on %s\n", data_dir);
    reset_host_ctx(&g_host);
    mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
    wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);

    // Local draft for WS1 MUST survive restart!
    send_json("{\"id\":201,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
    char *m_draft_back = wait_for_matching_msg(&g_host, "\"id\":201,", "persisted-alice-draft", 10);
    printf("[live_net_e2e] Phase 4 draft.get -> %s\n", m_draft_back);

    // Workspace W1 MUST survive restart; dropped W2 MUST stay revoked & absent!
    send_json("{\"id\":202,\"call\":\"workspaces.list\",\"params\":{}}");
    char *m_ws_back = wait_for_matching_msg(&g_host, "\"id\":202,", WS1_ID, 10);
    printf("[live_net_e2e] Phase 4 workspaces.list -> %s\n", m_ws_back);
    assert(strstr(m_ws_back, WS2_ID) == NULL);

    send_json("{\"id\":203,\"call\":\"workspace.get\",\"params\":{\"workspace\":\"" WS2_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":203,", "access_revoked", 10);

    // Persisted message on thread 42 MUST survive restart!
    send_json("{\"id\":204,\"subscribe\":{\"topic\":\"chat\",\"station\":\"st-local\",\"thread\":42},\"keyed\":true}");
    char *m_thread_back = wait_for_matching_msg(&g_host, "\"id\":204,", "hello over real rust shell", 10);
    printf("[live_net_e2e] Phase 4 persisted chat -> %s\n", m_thread_back);

    // Register a private download + muted workspace preference for Alice before Phase 5 401 logout
    // to verify 0 download/notify/outbox leakage to Bob!
    send_json("{\"id\":2041,\"call\":\"download.join\",\"params\":{\"reader\":\"dl-alice-live\",\"fileKey\":\"alice-private-doc.pdf\",\"name\":\"alice-private-doc.pdf\",\"start\":0,\"end\":4096}}");
    wait_for_matching_msg(&g_host, "\"id\":2041,", "\"ok\"", 10);
    send_json("{\"id\":2042,\"call\":\"notify.set\",\"params\":{\"muted\":[\"" WS1_ID "\"]}}");
    wait_for_matching_msg(&g_host, "\"id\":2042,", "\"ok\"", 10);

    // ── PHASE 5: Permanent 401 refresh removes the last account — immediate unauth `:memory:` switch BEFORE restart! ──
    printf("[live_net_e2e] Phase 5: triggering permanent 401 auth.refresh\n");
    send_json("{\"id\":205,\"call\":\"auth.refresh\",\"params\":{\"sub\":\"u-live\"}}");
    char *m_ref_401 = wait_for_matching_msg(&g_host, "\"id\":205,", "\"error\"", 10);
    printf("[live_net_e2e] Phase 5 auth.refresh 401 -> %s\n", m_ref_401);
    assert(atomic_load(&g_srv.got_auth_refresh) == 1);

    // IMMEDIATELY (WITHOUT restarting!): sessions.list, jobs.open, account.doc(me), workspaces.list, downloads MUST all be empty/null!
    send_json("{\"id\":206,\"call\":\"sessions.list\",\"params\":{}}");
    wait_for_matching_msg(&g_host, "\"id\":206,", "\"sessions\":[]", 10);
    send_json("{\"id\":207,\"call\":\"jobs.open\",\"params\":{}}");
    wait_for_matching_msg(&g_host, "\"id\":207,", "\"jobs\":[]", 10);
    send_json("{\"id\":208,\"call\":\"account.doc\",\"params\":{\"name\":\"me\"}}");
    wait_for_matching_msg(&g_host, "\"id\":208,", "\"ok\":null", 10);
    send_json("{\"id\":209,\"call\":\"workspaces.list\",\"params\":{}}");
    char *m_immed_ws = wait_for_matching_msg(&g_host, "\"id\":209,", "\"workspaces\":[]", 10);
    assert(strstr(m_immed_ws, WS1_ID) == NULL);
    send_json("{\"id\":210,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":210,", "unauthenticated", 10);
    send_json("{\"id\":211,\"subscribe\":{\"topic\":\"downloads\"},\"keyed\":true}");
    char *m_immed_dl = wait_for_matching_msg(&g_host, "\"id\":211,", "\"value\"", 10);
    assert(strstr(m_immed_dl, "alice-private-doc.pdf") == NULL);
    send_json("{\"id\":2111,\"subscribe\":{\"topic\":\"notify\"},\"keyed\":true}");
    char *m_immed_notify = wait_for_matching_msg(&g_host, "\"id\":2111,", "\"value\"", 10);
    assert(strstr(m_immed_notify, "\"workspaces\":[]") != NULL && strstr(m_immed_notify, "\"muted\":[]") != NULL);
    assert(strstr(m_immed_notify, WS1_ID) == NULL && strstr(m_immed_notify, "Live Workspace") == NULL);

    // Same-process direct switch to Bob right after Alice's 401 logout (WITHOUT restarting):
    // Verify 0 Alice downloads and 0 Alice outbound entry frames leak to Bob!
    send_json("{\"id\":212,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
    char *m_bob_direct_b = wait_for_matching_msg(&g_host, "\"id\":212,", "\"state\":\"", 10);
    const char *bdp = strstr(m_bob_direct_b, "\"state\":\"");
    assert(bdp != NULL);
    bdp += 9;
    char bob_d_state[128];
    size_t bdi = 0;
    while (bdp[bdi] != '\0' && bdp[bdi] != '"' && bdi + 1 < sizeof(bob_d_state)) {
        bob_d_state[bdi] = bdp[bdi];
        bdi++;
    }
    bob_d_state[bdi] = '\0';
    char bob_d_complete[512];
    snprintf(bob_d_complete, sizeof(bob_d_complete),
             "{\"id\":213,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_bob\"}}",
             bob_d_state);
    send_json(bob_d_complete);
    wait_for_matching_msg(&g_host, "\"id\":213,", "\"email\":\"bob@still.fail\"", 10);
    send_json("{\"id\":214,\"subscribe\":{\"topic\":\"downloads\"},\"keyed\":true}");
    char *m_bob_dl = wait_for_matching_msg(&g_host, "\"id\":214,", "\"value\"", 10);
    assert(strstr(m_bob_dl, "alice-private-doc.pdf") == NULL);
    send_json("{\"id\":2141,\"subscribe\":{\"topic\":\"notify\"},\"keyed\":true}");
    char *m_bob_notify = wait_for_matching_msg(&g_host, "\"id\":2141,", "\"value\"", 10);
    assert(strstr(m_bob_notify, "\"muted\":[]") != NULL && strstr(m_bob_notify, WS1_ID) == NULL);
    // Log Bob back out with 401 before Phase 6 unauthenticated restart!
    send_json("{\"id\":215,\"call\":\"auth.refresh\",\"params\":{\"sub\":\"u-bob\"}}");
    wait_for_matching_msg(&g_host, "\"id\":215,", "\"error\"", 10);

    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    assert(atomic_load(&g_host.post_stop_count) == 0);

    // ── PHASE 6: Unauthenticated restart after last account removed — 0 private data leak! ──
    printf("[live_net_e2e] Phase 6: unauthenticated restart after logout on %s\n", data_dir);
    reset_host_ctx(&g_host);
    mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
    wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);

    send_json("{\"id\":301,\"call\":\"account.doc\",\"params\":{\"name\":\"me\"}}");
    char *m_post_logout_me = wait_for_matching_msg(&g_host, "\"id\":301,", "\"ok\":null", 10);
    printf("[live_net_e2e] Phase 6 account.doc(me) -> %s\n", m_post_logout_me);

    send_json("{\"id\":302,\"call\":\"workspaces.list\",\"params\":{}}");
    char *m_post_logout_ws = wait_for_matching_msg(&g_host, "\"id\":302,", "\"workspaces\":[]", 10);
    printf("[live_net_e2e] Phase 6 workspaces.list -> %s\n", m_post_logout_ws);
    assert(strstr(m_post_logout_ws, WS1_ID) == NULL);

    send_json("{\"id\":303,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":303,", "unauthenticated", 10);
    assert(!file_exists(default_db_path));

    // Phase 6b (R4 Item 2): In-flight `auth.complete` interrupted by `auth.cancel` MUST NOT install login!
    {
        char slow_db_path[256];
        snprintf(slow_db_path, sizeof(slow_db_path), "%s/databases/account-u-slow.db", data_dir);
        pthread_mutex_lock(&g_srv.mu);
        g_srv.slow_token_entered = 0;
        g_srv.slow_token_release = 0;
        pthread_mutex_unlock(&g_srv.mu);

        send_json("{\"id\":304,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_slow_b = wait_for_matching_msg(&g_host, "\"id\":304,", "\"state\":\"", 10);
        const char *ssp = strstr(m_slow_b, "\"state\":\"");
        assert(ssp != NULL);
        ssp += 9;
        char slow_state[128];
        size_t ssi = 0;
        while (ssp[ssi] != '\0' && ssp[ssi] != '"' && ssi + 1 < sizeof(slow_state)) {
            slow_state[ssi] = ssp[ssi];
            ssi++;
        }
        slow_state[ssi] = '\0';
        char slow_complete[512];
        snprintf(slow_complete, sizeof(slow_complete),
                 "{\"id\":305,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_slow_cancel\"}}",
                 slow_state);
        send_json(slow_complete);

        // Wait until the real HTTP server has received `/v1/auth/token`, then send `auth.cancel` while in flight!
        pthread_mutex_lock(&g_srv.mu);
        while (!g_srv.slow_token_entered) {
            pthread_cond_wait(&g_srv.cv, &g_srv.mu);
        }
        pthread_mutex_unlock(&g_srv.mu);

        send_json("{\"id\":306,\"call\":\"auth.cancel\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":306,", "\"ok\":", 10);

        pthread_mutex_lock(&g_srv.mu);
        g_srv.slow_token_release = 1;
        pthread_cond_broadcast(&g_srv.cv);
        pthread_mutex_unlock(&g_srv.mu);

        char *m_slow_err = wait_for_matching_msg(&g_host, "\"id\":305,", "login_expired", 10);
        printf("[live_net_e2e] Phase 6b in-flight auth.cancel -> %s\n", m_slow_err);
        assert(!file_exists(slow_db_path));
        send_json("{\"id\":307,\"call\":\"workspaces.list\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":307,", "\"workspaces\":[]", 10);
    }

    // ── PHASE 7: Same-process sign-in with ANOTHER account (`u-bob`) -> 401 logout -> same-process re-login as `u-live`! ──
    printf("[live_net_e2e] Phase 7: same-process account switch via 401 logout + re-login\n");
    char bob_db_path[256];
    snprintf(bob_db_path, sizeof(bob_db_path), "%s/databases/account-u-bob.db", data_dir);
    send_json("{\"id\":401,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
    char *m_bob_begin = wait_for_matching_msg(&g_host, "\"id\":401,", "\"state\":\"", 10);
    const char *bsp = strstr(m_bob_begin, "\"state\":\"");
    assert(bsp != NULL);
    bsp += 9;
    char bob_state[128];
    size_t bi = 0;
    while (bsp[bi] != '\0' && bsp[bi] != '"' && bi + 1 < sizeof(bob_state)) {
        bob_state[bi] = bsp[bi];
        bi++;
    }
    bob_state[bi] = '\0';
    char bob_complete[512];
    snprintf(bob_complete, sizeof(bob_complete),
             "{\"id\":402,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_bob\"}}",
             bob_state);
    send_json(bob_complete);
    wait_for_matching_msg(&g_host, "\"id\":402,", "\"email\":\"bob@still.fail\"", 10);
    assert(file_exists(bob_db_path));
    assert(!file_exists(default_db_path));
    // Persist a Bob-unique private marker into `account-u-bob.db` so Phase 9 can prove Bob's DB is
    // genuinely mounted & hydrated after rejected-Alice cleanup!
    send_json("{\"id\":4031,\"call\":\"settings.set\",\"params\":{\"key\":\"bob_marker\",\"value\":\"bob-private-marker-phase9\"}}");
    wait_for_matching_msg(&g_host, "\"id\":4031,", "\"saved\":true", 10);
    // Bob MUST NOT see Alice's draft!
    send_json("{\"id\":403,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
    char *m_bob_draft = wait_for_matching_msg(&g_host, "\"id\":403,", "\"ok\":", 10);
    assert(strstr(m_bob_draft, "persisted-alice-draft") == NULL);

    // Trigger 401 on Bob and IMMEDIATELY re-login as Alice in the SAME process (no restart)!
    send_json("{\"id\":404,\"call\":\"auth.refresh\",\"params\":{\"sub\":\"u-bob\"}}");
    wait_for_matching_msg(&g_host, "\"id\":404,", "\"error\"", 10);
    send_json("{\"id\":405,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
    char *m_alice_re = wait_for_matching_msg(&g_host, "\"id\":405,", "\"state\":\"", 10);
    const char *asp = strstr(m_alice_re, "\"state\":\"");
    assert(asp != NULL);
    asp += 9;
    char alice_re_state[128];
    size_t ai = 0;
    while (asp[ai] != '\0' && asp[ai] != '"' && ai + 1 < sizeof(alice_re_state)) {
        alice_re_state[ai] = asp[ai];
        ai++;
    }
    alice_re_state[ai] = '\0';
    char alice_re_complete[512];
    snprintf(alice_re_complete, sizeof(alice_re_complete),
             "{\"id\":406,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_42\"}}",
             alice_re_state);
    send_json(alice_re_complete);
    wait_for_matching_msg(&g_host, "\"id\":406,", "\"email\":\"alice@still.fail\"", 10);
    send_json("{\"id\":407,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
    wait_for_matching_msg(&g_host, "\"id\":407,", "persisted-alice-draft", 10);
    assert(!file_exists(default_db_path));

    // ── PHASE 8 (R5 Primitives A & B): Same-account re-login cancel preserves disk tuple +
    //    Active account A + sibling B -> A 401 -> A re-login puts A at index 0, groups workspaces
    //    under A, default auth.refresh targets A, and restart opens account-u-live.db! ──
    printf("[live_net_e2e] Phase 8: same-account re-login cancel preservation & active account [A, B] ordering\n");
    {
        // 8a. Re-login of SAME signed-in account `u-live` interrupted by `auth.cancel` MUST preserve `ref-exchanged-42`!
        pthread_mutex_lock(&g_srv.mu);
        g_srv.slow_token_entered = 0;
        g_srv.slow_token_release = 0;
        pthread_mutex_unlock(&g_srv.mu);

        send_json("{\"id\":501,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_re_b = wait_for_matching_msg(&g_host, "\"id\":501,", "\"state\":\"", 10);
        const char *rsp = strstr(m_re_b, "\"state\":\"");
        assert(rsp != NULL);
        rsp += 9;
        char re_state[128];
        size_t ri = 0;
        while (rsp[ri] != '\0' && rsp[ri] != '"' && ri + 1 < sizeof(re_state)) {
            re_state[ri] = rsp[ri];
            ri++;
        }
        re_state[ri] = '\0';
        char re_complete[512];
        snprintf(re_complete, sizeof(re_complete),
                 "{\"id\":502,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_slow_alice\"}}",
                 re_state);
        send_json(re_complete);
        pthread_mutex_lock(&g_srv.mu);
        while (!g_srv.slow_token_entered) {
            pthread_cond_wait(&g_srv.cv, &g_srv.mu);
        }
        pthread_mutex_unlock(&g_srv.mu);
        send_json("{\"id\":503,\"call\":\"auth.cancel\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":503,", "\"ok\":", 10);
        pthread_mutex_lock(&g_srv.mu);
        g_srv.slow_token_release = 1;
        pthread_cond_broadcast(&g_srv.cv);
        pthread_mutex_unlock(&g_srv.mu);
        wait_for_matching_msg(&g_host, "\"id\":502,", "login_expired", 10);

        // Disk `accounts` MUST still contain `u-live` with original `ref-exchanged-42`!
        char accts_path[256];
        snprintf(accts_path, sizeof(accts_path), "%s/accounts", data_dir);
        FILE *af = fopen(accts_path, "r");
        assert(af != NULL);
        char abuf[2048];
        size_t an = fread(abuf, 1, sizeof(abuf) - 1, af);
        fclose(af);
        abuf[an] = '\0';
        assert(strstr(abuf, "\"sub\":\"u-live\"") != NULL && strstr(abuf, "\"refresh\":\"ref-exchanged-42\"") != NULL);
        assert(strstr(abuf, "ref-alice-cancelled") == NULL);

        // 8b. Seed sibling Bob alongside active Alice on disk (`[u-live, u-bob]`), restart,
        //     401-remove Alice (leaving `[u-bob]` on disk), then re-login as Alice:
        //     Alice MUST be persisted at index 0 (`[u-live, u-bob]`), workspaces MUST belong to Alice,
        //     and cold restart MUST open `account-u-live.db`!
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();
        assert(atomic_load(&g_host.post_stop_count) == 0);

        af = fopen(accts_path, "w");
        assert(af != NULL);
        fputs("[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"picture\":\"\","
              "\"access\":\"acc-exchanged-42\",\"refresh\":\"ref-exchanged-42\",\"access_expires\":1900000000,"
              "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5FAV\"},"
              "{\"sub\":\"u-bob\",\"email\":\"bob@still.fail\",\"name\":\"Bob\",\"picture\":\"\","
              "\"access\":\"acc-bob-1\",\"refresh\":\"ref-bob-1\",\"access_expires\":1900000000,"
              "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5FBW\"}]", af);
        fclose(af);

        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);

        // Default `auth.refresh` (no `sub` param!) MUST target active Alice (`u-live`), removing Alice & leaving `[u-bob]`:
        send_json("{\"id\":504,\"call\":\"auth.refresh\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":504,", "\"error\"", 10);

        // Now Alice re-logs in while `[u-bob]` is on disk:
        send_json("{\"id\":505,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_a2_b = wait_for_matching_msg(&g_host, "\"id\":505,", "\"state\":\"", 10);
        const char *a2p = strstr(m_a2_b, "\"state\":\"");
        assert(a2p != NULL);
        a2p += 9;
        char a2_state[128];
        size_t a2i = 0;
        while (a2p[a2i] != '\0' && a2p[a2i] != '"' && a2i + 1 < sizeof(a2_state)) {
            a2_state[a2i] = a2p[a2i];
            a2i++;
        }
        a2_state[a2i] = '\0';
        char a2_complete[512];
        snprintf(a2_complete, sizeof(a2_complete),
                 "{\"id\":506,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_42\"}}",
                 a2_state);
        send_json(a2_complete);
        wait_for_matching_msg(&g_host, "\"id\":506,", "\"email\":\"alice@still.fail\"", 10);

        // Verify disk `accounts` has `u-live` BEFORE `u-bob` (index 0 == active account)!
        af = fopen(accts_path, "r");
        assert(af != NULL);
        an = fread(abuf, 1, sizeof(abuf) - 1, af);
        fclose(af);
        abuf[an] = '\0';
        const char *pos_alice = strstr(abuf, "\"sub\":\"u-live\"");
        const char *pos_bob = strstr(abuf, "\"sub\":\"u-bob\"");
        assert(pos_alice != NULL && pos_bob != NULL && pos_alice < pos_bob);

        // Subscribe `workspaces` and verify WS1 belongs to `u-live` (NOT `u-bob`)!
        send_json("{\"id\":507,\"subscribe\":{\"topic\":\"workspaces\"},\"keyed\":true}");
        char *m_ws_grp = wait_for_matching_msg(&g_host, "\"id\":507,", WS1_ID, 10);
        const char *grp_alice = strstr(m_ws_grp, "\"sub\":\"u-live\"");
        const char *grp_ws1 = strstr(m_ws_grp, WS1_ID);
        const char *grp_bob = strstr(m_ws_grp, "\"sub\":\"u-bob\"");
        assert(grp_alice != NULL && grp_ws1 != NULL && grp_bob != NULL && grp_alice < grp_ws1 && grp_ws1 < grp_bob);

        // Restart cleanly and verify cold restart opens `account-u-live.db` (Alice's draft survives)!
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();
        assert(atomic_load(&g_host.post_stop_count) == 0);
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        send_json("{\"id\":508,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":508,", "persisted-alice-draft", 10);
        printf("[live_net_e2e] Phase 8 PASSED (active [A,B] ordering + same-account cancel preservation + restart account-A.db)\n");
    }

    // ── PHASE 9 (R11 single-owner `.core.lock`): Live Cloud 401 refresh invalidation:
    //    1) Synchronous CAS removal of `u-live` from `<dir>/accounts` (preserving sibling `u-bob`)
    //       + immediate `:memory:` isolation (< 1s) + 0ms `mb_core_stop()`.
    //    2) Cold restart mounts surviving sibling `u-bob`'s private `account-u-bob.db` cleanly. ──
    printf("[live_net_e2e] Phase 9: single-owner sync 401 CAS removal + sibling Bob cold-boot mount\n");
    {
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();
        assert(atomic_load(&g_host.post_stop_count) == 0);

        char accts_path[256];
        snprintf(accts_path, sizeof(accts_path), "%s/accounts", data_dir);
        FILE *af = fopen(accts_path, "w");
        assert(af != NULL);
        fputs("[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"picture\":\"\","
              "\"access\":\"acc-exchanged-42\",\"refresh\":\"ref-exchanged-42\",\"access_expires\":1900000000,"
              "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5R8A\"},"
              "{\"sub\":\"u-bob\",\"email\":\"bob@still.fail\",\"name\":\"Bob\",\"picture\":\"\","
              "\"access\":\"acc-bob-1\",\"refresh\":\"ref-bob-1\",\"access_expires\":1900000000,"
              "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5R8B\"}]", af);
        fclose(af);

        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        // Confirm Alice's private draft is readable BEFORE 401:
        send_json("{\"id\":600,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":600,", "persisted-alice-draft", 10);

        // Trigger real Cloud 401 on Alice (with sibling Bob on disk): synchronously CAS-removes Alice
        // from `<dir>/accounts` (preserving Bob!), switches immediately to `:memory:` (0 Alice leak!),
        // and stops in 0ms!
        int64_t t0 = mono_ms_now();
        send_json("{\"id\":601,\"call\":\"auth.refresh\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":601,", "\"error\"", 10);
        int64_t q_ms = mono_ms_now() - t0;
        printf("[live_net_e2e] Phase 9 401 invalidation latency = %lld ms\n", (long long)q_ms);
        assert(q_ms < 1000);

        // Assert read gate is ALREADY closed (`:memory:`, 0 Alice private data leak)!
        send_json("{\"id\":602,\"call\":\"account.doc\",\"params\":{\"name\":\"me\"}}");
        wait_for_matching_msg(&g_host, "\"id\":602,", "\"ok\":null", 10);
        send_json("{\"id\":603,\"call\":\"workspaces.list\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":603,", "\"workspaces\":[]", 10);
        send_json("{\"id\":604,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        char *m_gated_draft = wait_for_matching_msg(&g_host, "\"id\":604,", NULL, 10);
        assert(strstr(m_gated_draft, "persisted-alice-draft") == NULL);

        // P1-3 E2E: On unbound `:memory:` with sibling Bob still listed, `account.switch("u-bob")`
        // MUST fail with `account_sub_mismatch` and MUST NOT bind `:memory:` or open read gate!
        send_json("{\"id\":6041,\"call\":\"account.switch\",\"params\":{\"account\":\"u-bob\"}}");
        wait_for_matching_msg(&g_host, "\"id\":6041,", "account_sub_mismatch", 10);
        send_json("{\"id\":6042,\"call\":\"workspaces.list\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":6042,", "\"workspaces\":[]", 10);

        // Verify disk `accounts` ALREADY has ONLY `u-bob` (`u-live` synchronously CAS-removed)!
        af = fopen(accts_path, "r");
        assert(af != NULL);
        char abuf[2048];
        size_t an = fread(abuf, 1, sizeof(abuf) - 1, af);
        fclose(af);
        abuf[an] = '\0';
        assert(strstr(abuf, "\"sub\":\"u-live\"") == NULL && strstr(abuf, "\"sub\":\"u-bob\"") != NULL);

        // Stop cleanly at 0ms!
        int64_t ts0 = mono_ms_now();
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();
        int64_t stop_ms = mono_ms_now() - ts0;
        printf("[live_net_e2e] Phase 9 stop latency = %lld ms\n", (long long)stop_ms);
        assert(stop_ms < 1000);
        assert(atomic_load(&g_host.post_stop_count) == 0);

        // Cold restart: directly mounts sibling Bob (`account-u-bob.db`), never opens Alice!
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        send_json("{\"id\":605,\"subscribe\":{\"topic\":\"accounts\"},\"keyed\":true}");
        char *m_bob_active = wait_for_matching_msg(&g_host, "\"id\":605,", "bob@still.fail", 10);
        assert(strstr(m_bob_active, "alice@still.fail") == NULL);

        // Alice's private draft MUST NEVER leak after restart (Bob's DB is active, Alice was removed)!
        send_json("{\"id\":606,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        char *m_post_draft = wait_for_matching_msg(&g_host, "\"id\":606,", NULL, 10);
        assert(strstr(m_post_draft, "persisted-alice-draft") == NULL);

        // Hard-assert Bob's private `account-u-bob.db` is genuinely mounted & hydrated (`bob_marker` readable)!
        send_json("{\"id\":607,\"call\":\"settings.get\",\"params\":{\"key\":\"bob_marker\"}}");
        wait_for_matching_msg(&g_host, "\"id\":607,", "\"value\":\"bob-private-marker-phase9\"", 10);
        printf("[live_net_e2e] Phase 9 PASSED (sync 401 removal + P1-3 account.switch guard + 0ms stop + cold-boot Bob mount)\n");
    }

    // ── PHASE 10 (R14 single-source-of-truth `<dir>/accounts` + startup `sync_dir` fence + native lock hydration + prefs isolation):
    //    10a. Inactive sibling Bob 401 while dir fsync fails (`-2`): records Bob in `rejected_tuples_in_memory`
    //         while active Alice stays intact -> restore `[Alice, Bob]` on disk -> Alice 401 strips BOTH Alice
    //         and rejected Bob from disk -> cold restart mounts `:memory:` (Bob is NOT resurrected!).
    //    10b. Startup `sync_accounts_dir` fail-closed (Codex P1-4): dir fsync failure on cold boot refuses to
    //         trust unconfirmed `<dir>/accounts` and starts in `:memory:`; then real verified Ed25519 lock-root
    //         hydration across 401 -> `:memory:` -> same-process `auth.complete` (without network `GET /lock`)!
    //    10c. Device pref `prefs.set("workspace", WS1_ID)` persisted by Alice -> Alice 401 -> same-process
    //         Bob login (Bob's DB does NOT contain `WS1_ID`) -> no-arg `station.connect` MUST NOT return `WS1_ID`! ──
    printf("[live_net_e2e] Phase 10: R14 sibling 401 filter, startup sync_dir fail-closed, native lock hydration & prefs workspace isolation\n");
    {
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();
        assert(atomic_load(&g_host.post_stop_count) == 0);

        char accts_path[256];
        snprintf(accts_path, sizeof(accts_path), "%s/accounts", data_dir);
        const char *both_json =
            "[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"picture\":\"\","
            "\"access\":\"acc-exchanged-42\",\"refresh\":\"ref-exchanged-42\",\"access_expires\":1900000000,"
            "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5R13A\"},"
            "{\"sub\":\"u-bob\",\"email\":\"bob@still.fail\",\"name\":\"Bob\",\"picture\":\"\","
            "\"access\":\"acc-bob-1\",\"refresh\":\"ref-bob-1\",\"access_expires\":1900000000,"
            "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5R13B\"}]";
        FILE *af = fopen(accts_path, "w");
        assert(af != NULL);
        fputs(both_json, af);
        fclose(af);

        // 10a: Inactive Bob 401 under `-2` write failure -> tracked in memory, active Alice stays alive!
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        send_json("{\"id\":700,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":700,", "persisted-alice-draft", 10);

        pion_core_test_set_fail_dir_fsync(1);
        send_json("{\"id\":701,\"call\":\"auth.refresh\",\"params\":{\"sub\":\"u-bob\"}}");
        wait_for_matching_msg(&g_host, "\"id\":701,", "\"error\"", 10);
        // Active Alice MUST remain readable!
        send_json("{\"id\":702,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":702,", "persisted-alice-draft", 10);

        // Simulate Bob still lingering in `<dir>/accounts` (as if `write_atomic` had failed with `-1` ENOSPC)
        // and restore dir fsync -> Alice 401 MUST filter out BOTH Alice AND rejected Bob from disk!
        pion_core_test_set_fail_dir_fsync(0);
        af = fopen(accts_path, "w");
        assert(af != NULL);
        fputs(both_json, af);
        fclose(af);
        send_json("{\"id\":703,\"call\":\"auth.refresh\",\"params\":{\"sub\":\"u-live\"}}");
        wait_for_matching_msg(&g_host, "\"id\":703,", "\"error\"", 10);
        // Verify disk `<dir>/accounts` no longer resurrects rejected Bob!
        af = fopen(accts_path, "r");
        if (af != NULL) {
            char abuf2[2048];
            size_t an2 = fread(abuf2, 1, sizeof(abuf2) - 1, af);
            fclose(af);
            abuf2[an2] = '\0';
            assert(strstr(abuf2, "\"sub\":\"u-bob\"") == NULL && strstr(abuf2, "\"sub\":\"u-live\"") == NULL);
        }
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();

        // Cold restart MUST stay unauthenticated `:memory:` (NEITHER Alice NOR rejected Bob activates!):
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        send_json("{\"id\":704,\"call\":\"settings.get\",\"params\":{\"key\":\"bob_marker\"}}");
        char *m_no_bob = wait_for_matching_msg(&g_host, "\"id\":704,", NULL, 10);
        assert(strstr(m_no_bob, "bob-private-marker-phase9") == NULL);
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();

        // 10b: Startup `sync_accounts_dir` transient fail-closed + `auth.complete` `-2` rollback `-2`
        //      refuses publishing new login (P1-1) + same-instance backoff auto-recovery (P1-4) +
        //      native verified login Ed25519 lock-root hydration!
        const char *alice_only_b =
            "[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\",\"picture\":\"\","
            "\"access\":\"acc-exchanged-42\",\"refresh\":\"ref-exchanged-42\",\"access_expires\":1900000000,"
            "\"session\":\"01ARZ3NDEKTSV4RRFFQ69G5R14B\"}]";
        af = fopen(accts_path, "w");
        assert(af != NULL);
        fputs(alice_only_b, af);
        fclose(af);

        // Directory fsync failure on cold boot MUST fail closed into `:memory:` (0 unconfirmed disk tokens):
        pion_core_test_set_fail_dir_fsync(1);
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        send_json("{\"id\":705,\"call\":\"workspaces.list\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":705,", "\"workspaces\":[]", 10);
        send_json("{\"id\":706,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        char *m_sync_fail = wait_for_matching_msg(&g_host, "\"id\":706,", NULL, 10);
        assert(strstr(m_sync_fail, "persisted-alice-draft") == NULL);

        // `auth.begin` + `auth.cancel` while startup sync is pending MUST NOT cancel startup backoff retry!
        send_json("{\"id\":7061,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        wait_for_matching_msg(&g_host, "\"id\":7061,", "\"state\":\"", 10);
        send_json("{\"id\":7062,\"call\":\"auth.cancel\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":7062,", "\"ok\":", 10);

        // P1-1 E2E: `auth.complete` while dir fsync fails (`-2` write -> `-2` rollback visibly restores Alice):
        // MUST return `storage_error` and NEVER activate Bob!
        send_json("{\"id\":7063,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_rb_b = wait_for_matching_msg(&g_host, "\"id\":7063,", "\"state\":\"", 10);
        const char *rbp = strstr(m_rb_b, "\"state\":\"");
        assert(rbp != NULL);
        rbp += 9;
        char rb_state[128];
        size_t rbi = 0;
        while (rbp[rbi] != '\0' && rbp[rbi] != '"' && rbi + 1 < sizeof(rb_state)) {
            rb_state[rbi] = rbp[rbi];
            rbi++;
        }
        rb_state[rbi] = '\0';
        char rb_comp[512];
        snprintf(rb_comp, sizeof(rb_comp),
                 "{\"id\":7064,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_bob\"}}",
                 rb_state);
        send_json(rb_comp);
        wait_for_matching_msg(&g_host, "\"id\":7064,", "\"storage_error\"", 10);

        // P1-4 + P2-1 E2E: Persist a device pref (`appearance=dark`) before recovery, then clear
        // transient dir fsync failure WITHOUT restarting this running core instance!
        // The in-instance backoff retry fiber MUST automatically mount Alice, seed device prefs
        // (skipping `workspace`), and restore `account.doc("me")`, `workspaces.list`, and `persisted-alice-draft`!
        send_json("{\"id\":70645,\"call\":\"prefs.set\",\"params\":{\"appearance\":\"dark\"}}");
        wait_for_matching_msg(&g_host, "\"id\":70645,", "\"ok\":", 10);
        send_json("{\"id\":7065,\"subscribe\":{\"topic\":\"accounts\"},\"keyed\":true}");
        wait_for_matching_msg(&g_host, "\"id\":7065,", "\"value\":[]", 10);
        pion_core_test_set_fail_dir_fsync(0);
        wait_for_matching_msg(&g_host, "\"id\":7065,", "alice@still.fail", 10);
        send_json("{\"id\":7066,\"call\":\"account.doc\",\"params\":{\"name\":\"me\"}}");
        char *m_rec_me = wait_for_matching_msg(&g_host, "\"id\":7066,", "alice@still.fail", 10);
        assert(strstr(m_rec_me, "\"ok\":null") == NULL);
        send_json("{\"id\":7067,\"call\":\"draft.get\",\"params\":{\"key\":\"new:" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":7067,", "persisted-alice-draft", 10);
        send_json("{\"id\":7068,\"call\":\"workspaces.list\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":7068,", WS1_ID, 10);
        send_json("{\"id\":7069,\"subscribe\":{\"topic\":\"prefs\"},\"keyed\":true}");
        wait_for_matching_msg(&g_host, "\"id\":7069,", "\"appearance\":\"dark\"", 10);

        // Persist `workspace = WS1_ID` pref on the recovered Alice instance, then restart with `serve_ws1_lock = 1`
        // to pin real Ed25519 genesis on `WS1_ID` via `GET /lock`, then 401 -> `:memory:` -> real verified
        // `auth.complete` (with `GET /lock` disabled = 404!) and verify `lock.status` STILL reports `locked:true`!
        send_json("{\"id\":707,\"call\":\"prefs.set\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":707,", "\"ok\":", 10);
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();

        atomic_store(&g_srv.serve_ws1_lock, 1);
        reset_host_ctx(&g_host);
        mb_core_start(data_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);
        // Subscribe `lock` BEFORE `station.connect` so `GET /lock` deterministically emits the `locked=true` delta:
        send_json("{\"id\":7081,\"subscribe\":{\"topic\":\"lock\",\"workspace\":\"" WS1_ID "\"},\"keyed\":true}");
        wait_for_matching_msg(&g_host, "\"id\":7081,", "\"locked\":false", 10);
        send_json("{\"id\":708,\"call\":\"station.connect\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"event\":\"connection\"", "\"state\":\"connected\"", 10);
        wait_for_matching_msg(&g_host, "\"id\":7081,", "\"path\":[\"locked\"],\"set\":true", 10);
        send_json("{\"id\":7082,\"call\":\"lock.status\",\"params\":{}}");
        char *m_lock_pre = wait_for_matching_msg(&g_host, "\"id\":7082,", "\"locked\":true", 10);
        assert(strstr(m_lock_pre, "133454df5fac09e1946014d43cc066d2daed6c1108a806366ed51ccec959e409") != NULL);

        // Disable network `GET /lock` (404), trigger Alice 401 -> `:memory:`, then real verified `auth.complete`:
        atomic_store(&g_srv.serve_ws1_lock, 0);
        send_json("{\"id\":7083,\"call\":\"auth.refresh\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":7083,", "\"error\"", 10);
        send_json("{\"id\":7084,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_a10b = wait_for_matching_msg(&g_host, "\"id\":7084,", "\"state\":\"", 10);
        const char *ap10b = strstr(m_a10b, "\"state\":\"");
        assert(ap10b != NULL);
        ap10b += 9;
        char st10b[128];
        size_t s10bi = 0;
        while (ap10b[s10bi] != '\0' && ap10b[s10bi] != '"' && s10bi + 1 < sizeof(st10b)) {
            st10b[s10bi] = ap10b[s10bi];
            s10bi++;
        }
        st10b[s10bi] = '\0';
        char comp10b[512];
        snprintf(comp10b, sizeof(comp10b),
                 "{\"id\":7085,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_42\"}}",
                 st10b);
        send_json(comp10b);
        wait_for_matching_msg(&g_host, "\"id\":7085,", "\"email\":\"alice@still.fail\"", 10);
        // Without `station.connect` (and with `GET /lock` returning 404!), `lock.status` MUST STILL be `locked:true` + pinned genesis!
        send_json("{\"id\":7086,\"call\":\"lock.status\",\"params\":{}}");
        char *m_lock_post = wait_for_matching_msg(&g_host, "\"id\":7086,", "\"locked\":true", 10);
        assert(strstr(m_lock_post, "133454df5fac09e1946014d43cc066d2daed6c1108a806366ed51ccec959e409") != NULL);

        // 10c: Alice's device pref `workspace = WS1_ID` is persisted -> Alice 401 -> same-process Bob login
        // (Bob's DB does NOT contain `WS1_ID`!) -> no-arg `station.connect` MUST NOT return `WS1_ID`!
        send_json("{\"id\":710,\"call\":\"auth.refresh\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":710,", "\"error\"", 10);

        send_json("{\"id\":711,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_b10 = wait_for_matching_msg(&g_host, "\"id\":711,", "\"state\":\"", 10);
        const char *sp10 = strstr(m_b10, "\"state\":\"");
        assert(sp10 != NULL);
        sp10 += 9;
        char st10[128];
        size_t s10i = 0;
        while (sp10[s10i] != '\0' && sp10[s10i] != '"' && s10i + 1 < sizeof(st10)) {
            st10[s10i] = sp10[s10i];
            s10i++;
        }
        st10[s10i] = '\0';
        char comp10[512];
        snprintf(comp10, sizeof(comp10),
                 "{\"id\":712,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_bob\"}}",
                 st10);
        send_json(comp10);
        wait_for_matching_msg(&g_host, "\"id\":712,", "\"email\":\"bob@still.fail\"", 10);
        send_json("{\"id\":713,\"call\":\"station.connect\",\"params\":{}}");
        char *m_conn10 = wait_for_matching_msg(&g_host, "\"id\":713,", NULL, 10);
        assert(strstr(m_conn10, WS1_ID) == NULL);
        printf("[live_net_e2e] Phase 10 PASSED (sibling 401 filter, startup sync_dir fail-closed, native lock hydration & prefs workspace isolation)\n");
    }

    // ── Phase 11 (R4 Test 5): Cloud `/v1/workspaces/<ws>` 401 -> OAuth refresh 200 -> `on_adopt_or_update`
    // auto-requeues pending workspace confirmation with rotated bearer token (no external WS event!) ──
    {
        atomic_store(&g_host.stopped, 1);
        mb_core_stop();

        char phase11_dir[256];
        snprintf(phase11_dir, sizeof(phase11_dir), "/tmp/pion_live_net_e2e_p11_%d", (int)getpid());
        mkdir(phase11_dir, 0700);
        atomic_store(&g_srv.drop_ws2_in_me, 1);
        atomic_store(&g_srv.serve_ws1_lock, 0);
        atomic_store(&g_srv.ws1_downgrade_member, 0);
        atomic_store(&g_srv.ws1_require_rotated_token, 0);
        atomic_store(&g_srv.allow_refresh_rotate, 1);
        atomic_store(&g_srv.enable_cloud_ws, 1);
        atomic_store(&g_srv.cloud_ws_connected, 0);
        atomic_store(&g_srv.got_ws1_401, 0);
        atomic_store(&g_srv.got_ws1_rotated_ok, 0);
        pthread_mutex_lock(&g_srv.mu);
        g_srv.ws1_custom_name[0] = '\0';
        g_srv.ws1_custom_station[0] = '\0';
        g_srv.cloud_ws_push_ready = 0;
        pthread_mutex_unlock(&g_srv.mu);

        reset_host_ctx(&g_host);
        mb_core_start(phase11_dir, origin, 1, on_host_message, &g_host);
        wait_for_matching_msg(&g_host, "\"id\":0,", "\"auth\":{", 10);

        // Sign in Alice with `acc-exchanged-42` / `ref-exchanged-42`
        send_json("{\"id\":801,\"call\":\"auth.begin\",\"params\":{\"redirect_uri\":\"stillfail://auth/callback\",\"return_to\":\"/\"}}");
        char *m_b11 = wait_for_matching_msg(&g_host, "\"id\":801,", "\"state\":\"", 10);
        const char *sp11 = strstr(m_b11, "\"state\":\"");
        assert(sp11 != NULL);
        sp11 += 9;
        char st11[128];
        size_t s11i = 0;
        while (sp11[s11i] != '\0' && sp11[s11i] != '"' && s11i + 1 < sizeof(st11)) {
            st11[s11i] = sp11[s11i];
            s11i++;
        }
        st11[s11i] = '\0';
        char comp11[512];
        snprintf(comp11, sizeof(comp11),
                 "{\"id\":802,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=live_oauth_code_42\"}}",
                 st11);
        send_json(comp11);
        wait_for_matching_msg(&g_host, "\"id\":802,", "\"email\":\"alice@still.fail\"", 10);

        // Sync initial owner workspace + subscribe `workspace` & `stations`
        send_json("{\"id\":803,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
        wait_for_matching_msg(&g_host, "\"id\":803,", "\"ok\":{", 10);
        send_json("{\"id\":811,\"subscribe\":{\"topic\":\"workspace\",\"workspace\":\"" WS1_ID "\"},\"keyed\":true}");
        wait_for_matching_msg(&g_host, "\"id\":811,", "Live Workspace", 10);
        send_json("{\"id\":812,\"subscribe\":{\"topic\":\"stations\",\"scope\":\"" WS1_ID "\"},\"keyed\":true}");
        wait_for_matching_msg(&g_host, "\"id\":812,", "Live Station", 10);

        // Arm downgrade (`owner -> member`) AND require rotated bearer token `acc-rotated-99` on `/v1/workspaces/WS1_ID`!
        atomic_store(&g_srv.ws1_downgrade_member, 1);
        atomic_store(&g_srv.ws1_require_rotated_token, 1);

        // Trigger `/v1/me` downgrade -> `on_workspace_refresh` hits 401 -> `POST /v1/auth/refresh` 200 ->
        // `on_adopt_or_update` calls `requeue_pending_cloud_confirmations` -> retries `/v1/workspaces/WS1_ID`
        // with `acc-rotated-99` -> confirms BOTH `workspace:` and `stations:`!
        send_json("{\"id\":804,\"call\":\"cloud.sync\",\"params\":{}}");
        wait_for_matching_msg(&g_host, "\"id\":811,", "\"waiting\":true", 10);
        wait_for_matching_msg(&g_host, "\"id\":812,", "\"waiting\":true", 10);
        wait_for_matching_msg(&g_host, "\"id\":804,", "token_expired (401)", 10);
        wait_for_matching_msg(&g_host, "\"id\":811,", "Live Member Workspace", 10);
        wait_for_matching_msg(&g_host, "\"id\":812,", "Live Member Station", 10);

        assert(atomic_load(&g_srv.got_ws1_401) >= 1);
        assert(atomic_load(&g_srv.got_ws1_rotated_ok) >= 1);
        printf("[live_net_e2e] Phase 11 PASSED (401 -> bearer refresh -> requeue_pending_cloud_confirmations confirmed workspace & stations)\n");

        // Phase 11b-1 (R6 Codex P1-3): Transient HTTP 500 on `POST /v1/auth/refresh` MUST NOT
        // permanently lock out the current `bearer_gen` or consume the rotated-401 budget; bounded
        // backoff retry self-heals on the 2nd refresh (200) and confirms `workspace` & `stations`!
        {
            atomic_store(&g_srv.ws1_downgrade_member, 0);
            atomic_store(&g_srv.ws1_require_rotated_token, 0);
            atomic_store(&g_srv.ws1_always_401, 0);
            send_json("{\"id\":8050,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
            wait_for_matching_msg(&g_host, "\"id\":8050,", "\"ok\":{", 10);

            int ws401_base_500 = atomic_load(&g_srv.got_ws1_401);
            int ref_base_500 = atomic_load(&g_srv.got_auth_refresh);
            int rot_ok_base = atomic_load(&g_srv.got_ws1_rotated_ok);
            int next_seq = atomic_load(&g_srv.refresh_rotate_seq) + 1;
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq);
            g_srv.refresh_gate_enabled = 1;
            g_srv.refresh_budget = 0;
            pthread_mutex_unlock(&g_srv.mu);
            atomic_store(&g_srv.refresh_fail_500_remaining, 1);
            atomic_store(&g_srv.ws1_downgrade_member, 1);
            atomic_store(&g_srv.ws1_require_rotated_token, 1);

            send_json("{\"id\":8051,\"call\":\"cloud.sync\",\"params\":{}}");
            wait_for_matching_msg(&g_host, "\"id\":8051,", "token_expired (401)", 10);
            // Hold Refresh #1 until BOTH initial 401s have arrived and deduped, then release the transient 500
            // so Refresh #2 MUST come strictly from the bounded backoff self-heal timer!
            wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base_500 + 2, 10);
            wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_500 + 1, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.refresh_gate_enabled = 0;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Deterministically wait for bounded backoff recovery (#2 -> 200) -> confirmed!
            wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_500 + 2, 10);
            wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base + 1, 10);
            assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_500 == 2);
            printf("[live_net_e2e] Phase 11b-1 PASSED (transient refresh 500 -> bounded backoff self-heal -> rotated 200 confirmed)\n");
        }

        // Phase 11b-2 (R6 Codex P2 + Opus P2-2): Deterministically latch-stepped persistent
        // 401 -> refresh -> 401 circuit breaker MUST stop at EXACTLY 2 refreshes (ZERO `nanosleep`)!
        {
            atomic_store(&g_srv.ws1_downgrade_member, 0);
            atomic_store(&g_srv.ws1_require_rotated_token, 0);
            atomic_store(&g_srv.ws1_always_401, 0);
            atomic_store(&g_srv.refresh_fail_500_remaining, 0);
            send_json("{\"id\":805,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
            wait_for_matching_msg(&g_host, "\"id\":805,", "\"ok\":{", 10);

            int ws401_base = atomic_load(&g_srv.got_ws1_401);
            int ref_base = atomic_load(&g_srv.got_auth_refresh);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_401_gate_enabled = 1;
            g_srv.ws1_401_budget = 0;
            g_srv.refresh_gate_enabled = 1;
            g_srv.refresh_budget = 0;
            pthread_mutex_unlock(&g_srv.mu);

            atomic_store(&g_srv.ws1_downgrade_member, 2); // owner -> admin (Boundary 1)
            atomic_store(&g_srv.ws1_always_401, 1);
            send_json("{\"id\":806,\"call\":\"cloud.sync\",\"params\":{}}");

            // Step 1: `cloud.sync({})` triggers both `on_workspace_refresh` and `cloud.sync` detail fetches
            // on the SAME initial `bearer_gen`; wait for both 401s at the latch and release them ->
            // concurrent 401s on the same `bearer_gen` MUST deduplicate into Refresh #1!
            wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base + 2, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_401_budget += 2;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
            wait_for_matching_msg(&g_host, "\"id\":806,", "persistent_401 (401)", 10);

            wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base + 1, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.refresh_budget += 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Step 2: Refresh #1 rotated bearer (`rotated_count = 1`) and requeued `/v1/workspaces/WS1_ID`;
            // release that 401 -> triggers Refresh #2!
            wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base + 3, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_401_budget += 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base + 2, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.refresh_budget += 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Step 3: Refresh #2 rotated bearer (`rotated_count = 2`) and requeued `/v1/workspaces/WS1_ID`;
            // release that terminal 401 (circuit breaker trips!) and disable latches.
            wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base + 4, 10);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_401_gate_enabled = 0;
            g_srv.refresh_gate_enabled = 0;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Deterministic drain fence (R7 Codex P2):
            // 1. Send probe `cloud.sync({ workspace: WS1_ID })` under persistent 401 and wait for its `"id":807` error;
            // 2. Drain pending runtime microtasks via two sequential round-trip RPCs (`lock.status` + `workspaces.list`)
            //    and confirm ZERO in-flight HTTP/refresh connections remain on the server (`active_http_conns == 0`);
            // 3. Assert `got_auth_refresh - ref_base == 2` EXACTLY!
            send_json("{\"id\":807,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
            wait_for_matching_msg(&g_host, "\"id\":807,", "persistent_401 (401)", 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
            send_json("{\"id\":808,\"call\":\"lock.status\",\"params\":{}}");
            wait_for_matching_msg(&g_host, "\"id\":808,", "\"ok\":{", 10);
            send_json("{\"id\":809,\"call\":\"workspaces.list\",\"params\":{}}");
            wait_for_matching_msg(&g_host, "\"id\":809,", "\"ok\":{", 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
            int refreshes_after_cb = atomic_load(&g_srv.got_auth_refresh) - ref_base;
            assert(refreshes_after_cb == 2);
            printf("[live_net_e2e] Phase 11b-2 PASSED (deterministic latch + runtime/server drain fence converged at EXACTLY %d refreshes)\n", refreshes_after_cb);
        }

        // Phase 11b-3 (R8 Codex P2): Keep Boundary 1 at `role="admin"` (NEVER upgrade to `"owner"`!),
        // confirm Boundary 1 via live `CloudSync` WebSocket `WorkspaceChanged` push -> `on_workspace_fetched_with_epoch`
        // (`Ok(true)` clears Boundary 1's 401 state!), then enter Boundary 2 via second downgrade `admin -> member`
        // (brand-new `boundary_seq`), verify 401 -> refresh -> AND assert on CLIENT SIDE that BOTH `workspace`
        // and `stations` topics become readable & confirmed!
        {
            wait_srv_atomic_ge(&g_srv.cloud_ws_connected, 1, 10);
            // Step A: Confirm Boundary 1 while STAYING `role="admin"` via real `CloudSync` WS push!
            atomic_store(&g_srv.ws1_always_401, 0);
            atomic_store(&g_srv.ws1_require_rotated_token, 0);
            atomic_store(&g_srv.ws1_downgrade_member, 2); // stays "admin"!
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Admin B1 Confirmed");
            snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Admin B1 Station");
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Client-side assertion: live `CloudSync` WS push confirmed Boundary 1 (`admin`) on BOTH topics!
            wait_for_matching_msg(&g_host, "\"id\":811,", "Live Admin B1 Confirmed", 10);
            wait_for_matching_msg(&g_host, "\"id\":812,", "Live Admin B1 Station", 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);

            // Step B: Enter Boundary 2 via second downgrade `admin -> member` (new `boundary_seq`, NEVER upgraded!)
            int ref_base_b2 = atomic_load(&g_srv.got_auth_refresh);
            int rot_ok_base_b2 = atomic_load(&g_srv.got_ws1_rotated_ok);
            int next_seq_b2 = atomic_load(&g_srv.refresh_rotate_seq) + 1;
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_b2);
            snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Member B2 Confirmed");
            snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Member B2 Station");
            pthread_mutex_unlock(&g_srv.mu);
            atomic_store(&g_srv.ws1_downgrade_member, 1); // admin -> member!
            atomic_store(&g_srv.ws1_require_rotated_token, 1);

            // Trigger Boundary 2 downgrade via real `CloudSync` WS `workspaces` push -> `/v1/me` -> 401 -> refresh -> 200!
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspaces\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            // Client-side assertions: BOTH `workspace` and `stations` become readable & confirmed on Boundary 2!
            wait_for_matching_msg(&g_host, "\"id\":811,", "Live Member B2 Confirmed", 10);
            wait_for_matching_msg(&g_host, "\"id\":812,", "Live Member B2 Station", 10);
            wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_b2 + 1, 10);
            wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_b2 + 1, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
            assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_b2 == 1);
            printf("[live_net_e2e] Phase 11b-3 PASSED (admin CloudSync WS confirmed B1 -> member B2 fresh 401 budget -> client workspace & stations confirmed)\n");
        }

        // Phase 11b-4 (R10 Codex P1-2 + P2 — ZERO `test.*` RPCs in production runtime!):
        // (a) Non-zero `PendingAuthConfirm` still active for station keys (`chats` waiting=true)
        //     while Cloud keys (`workspace`/`stations`) are ALREADY confirmed: live detail 401 ->
        //     refresh -> auto-replay + `/v1/me` crossing mid-replay (`Ok(false)` auto-continuation
        //     with fresh `base_seq` until `Ok(true)` commits)!
        // (b) Cross-workspace bearer rotation (`orig_bearer_gen != sess.bearer_gen`): WS1's old-bearer
        //     401 arrives AFTER WS2 already rotated the bearer -> ZERO extra refresh, immediate
        //     auto-replay on live bearer confirms WS1 `workspace` & `stations`!
        // (c) Normal live workspace detail 401 (`boundary_id == 0L`): 3 consecutive 401 -> refresh ->
        //     auto-replay -> commit cycles ALL succeed & cleanly reset `"ws|0"` budget!
        {
            // (a) Stay in `role="member"` from Phase 11b-3: verify station key `chats` is STILL gated
            //     by non-zero `PendingAuthConfirm` while Cloud keys (`workspace`/`stations`) are confirmed!
            send_json("{\"id\":813,\"subscribe\":{\"topic\":\"chats\",\"scope\":\"" WS1_ID "\"},\"keyed\":true}");
            wait_for_matching_msg(&g_host, "\"id\":813,", "\"waiting\":true", 10);

            int ref_base_4a = atomic_load(&g_srv.got_auth_refresh);
            int rot_ok_base_4a = atomic_load(&g_srv.got_ws1_rotated_ok);
            int next_seq_4a = atomic_load(&g_srv.refresh_rotate_seq) + 1;
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_4a);
            snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Stale PreMe");
            snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Stale PreMe St");
            g_srv.ws1_200_gate_enabled = 1;
            g_srv.ws1_200_budget = 0;
            pthread_mutex_unlock(&g_srv.mu);
            atomic_store(&g_srv.ws1_require_rotated_token, 1);

            // Live WS `workspace` event under active non-zero `PendingAuthConfirm` (with Cloud keys
            // already confirmed!) -> 401 -> 1 refresh -> auto-replay parks at rotated 200 latch!
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_4a + 1, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);

            // While replay #1 (`"Live Stale PreMe"`) is parked in-flight, push WS `workspaces` so
            // `/v1/me` advances `base_seq` past replay #1's `req_seq`!
            int me_base_4a = atomic_load(&g_srv.got_me);
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspaces\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
            wait_srv_atomic_ge(&g_srv.got_me, me_base_4a + 1, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);
            // Core-thread barrier RPC ensuring `commit_cloud_me` has updated `base_seq`:
            send_json("{\"id\":821,\"call\":\"workspaces.list\",\"params\":{}}");
            wait_for_matching_msg(&g_host, "\"id\":821,", "\"ok\":{", 10);

            // Update server payload for replay #2 and release parked replay #1 -> `Ok(false)` ->
            // `pending_live_ws_replay` stays alive & auto-continues with updated `base_seq` -> `Ok(true)`!
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live OkFalse AutoContinue");
            snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live OkFalse St");
            g_srv.ws1_200_gate_enabled = 0;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            wait_for_matching_msg(&g_host, "\"id\":811,", "Live OkFalse AutoContinue", 10);
            wait_for_matching_msg(&g_host, "\"id\":812,", "Live OkFalse St", 10);
            wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_4a + 2, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
            assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_4a == 1);
            // Stale pre-`/v1/me` payload from `Ok(false)` MUST NEVER have been emitted to host:
            pthread_mutex_lock(&g_host.mu);
            for (int mi = 0; mi < g_host.count; mi++) {
                assert(strstr(g_host.msgs[mi].json, "Live Stale PreMe") == NULL);
            }
            pthread_mutex_unlock(&g_host.mu);
            printf("[live_net_e2e] Phase 11b-4a PASSED (non-zero PendingAuthConfirm live 401 replay + mid-replay /v1/me Ok(false) auto-continued to Ok(true))\n");

            // (b) Cross-workspace bearer rotation (`orig_bearer_gen != sess.bearer_gen`):
            //     Re-enable WS2 in `/v1/me`, upgrade WS1 to `owner` (`boundary_id == 0L`), park WS1's
            //     old-bearer 401 at latch, rotate bearer via WS2's 401, then release WS1's late 401 ->
            //     ZERO extra refresh, immediate replay with live rotated bearer confirms WS1!
            atomic_store(&g_srv.drop_ws2_in_me, 0);
            atomic_store(&g_srv.ws1_downgrade_member, 0);
            atomic_store(&g_srv.ws1_require_rotated_token, 0);
            atomic_store(&g_srv.ws2_require_rotated_token, 0);
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_custom_name[0] = '\0';
            g_srv.ws1_custom_station[0] = '\0';
            pthread_mutex_unlock(&g_srv.mu);
            send_json("{\"id\":822,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
            wait_for_matching_msg(&g_host, "\"id\":822,", "\"ok\":{", 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);

            int ws401_base_4b = atomic_load(&g_srv.got_ws1_401);
            int ref_base_4b = atomic_load(&g_srv.got_auth_refresh);
            int rot_ok_base_4b = atomic_load(&g_srv.got_ws1_rotated_ok);
            int ws2_rot_base_4b = atomic_load(&g_srv.got_ws2_rotated_ok);
            int next_seq_4b = atomic_load(&g_srv.refresh_rotate_seq) + 1;
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_4b);
            snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live CrossWS Replayed");
            snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live CrossWS St");
            g_srv.ws1_401_gate_enabled = 1;
            g_srv.ws1_401_budget = 0;
            pthread_mutex_unlock(&g_srv.mu);
            atomic_store(&g_srv.ws1_require_rotated_token, 1);
            atomic_store(&g_srv.ws2_require_rotated_token, 1);

            // Step 1: WS1 starts fetch with OLD bearer and parks at 401 latch:
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
            wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base_4b + 1, 10);

            // Step 2: WS2 hits 401, rotates bearer ONCE, and replays WS2 with the new bearer:
            pthread_mutex_lock(&g_srv.mu);
            snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS2_ID "\"}");
            g_srv.cloud_ws_push_ready = 1;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
            wait_srv_atomic_ge(&g_srv.got_ws2_rotated_ok, ws2_rot_base_4b + 1, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);
            assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_4b == 1);

            // Step 3: Release WS1's stale old-bearer 401 -> ZERO second refresh, immediate live-bearer replay!
            pthread_mutex_lock(&g_srv.mu);
            g_srv.ws1_401_gate_enabled = 0;
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);

            wait_for_matching_msg(&g_host, "\"id\":811,", "Live CrossWS Replayed", 10);
            wait_for_matching_msg(&g_host, "\"id\":812,", "Live CrossWS St", 10);
            wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_4b + 1, 10);
            wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
            assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_4b == 1);
            atomic_store(&g_srv.ws2_require_rotated_token, 0);
            atomic_store(&g_srv.drop_ws2_in_me, 1);
            printf("[live_net_e2e] Phase 11b-4b PASSED (cross-workspace bearer rotation -> late WS1 401 replayed immediately with 0 extra refresh)\n");

            // (c) Normal live workspace detail 401 (`boundary_id == 0L`): 3 CONSECUTIVE
            //     401 -> refresh -> auto-replay -> commit cycles ALL succeed & cleanly reset `"ws|0"`!
            for (int cycle = 1; cycle <= 3; cycle++) {
                int ref_base_c = atomic_load(&g_srv.got_auth_refresh);
                int rot_ok_base_c = atomic_load(&g_srv.got_ws1_rotated_ok);
                int next_seq_c = atomic_load(&g_srv.refresh_rotate_seq) + 1;
                char exp_ws_name[64], exp_st_name[64];
                snprintf(exp_ws_name, sizeof(exp_ws_name), "Live Normal Cycle %d", cycle);
                snprintf(exp_st_name, sizeof(exp_st_name), "Live Normal St %d", cycle);
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_c);
                snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "%s", exp_ws_name);
                snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "%s", exp_st_name);
                pthread_mutex_unlock(&g_srv.mu);
                atomic_store(&g_srv.ws1_require_rotated_token, 1);

                // Push live `workspace` event while `boundary_id == 0L`: 401 -> refresh -> auto-replay -> 200 -> reset `"ws|0"`!
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);

                wait_for_matching_msg(&g_host, "\"id\":811,", exp_ws_name, 10);
                wait_for_matching_msg(&g_host, "\"id\":812,", exp_st_name, 10);
                wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_c + 1, 10);
                wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_c + 1, 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_c == 1);
            }
            printf("[live_net_e2e] Phase 11b-4c PASSED (3/3 consecutive normal boundary_id=0 live 401->refresh->replay cycles succeeded & reset budget)\n");

            // Phase 11b-5 (R11 Codex P1-1 + P1-2):
            // (a) Older detail `req_seq = N` commits `Ok(true)` WHILE OAuth refresh for newer detail
            //     `req_seq = N+1` 401 is still in-flight -> `pending_live_ws_replay_seq` retains `N+1`
            //     (`N < N+1`), so new bearer adoption still replays `N+2 >= N+1` and retires demand!
            // (b) Same-bearer 401 crossing role upgrade (`member -> owner`, `boundary_1 -> 0L`):
            //     demand is NOT dropped, re-issued under `boundary_id == 0L`, refreshes, and commits!
            {
                // (a) Park older detail `req_seq = N` at plain 200 latch:
                int plain_base_5a = atomic_load(&g_srv.got_ws1_plain_ok);
                int ref_base_5a = atomic_load(&g_srv.got_auth_refresh);
                int rot_ok_base_5a = atomic_load(&g_srv.got_ws1_rotated_ok);
                atomic_store(&g_srv.ws1_require_rotated_token, 0);
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Older Commit N");
                snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Older St N");
                g_srv.ws1_plain_200_gate_enabled = 1;
                pthread_mutex_unlock(&g_srv.mu);

                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_ws1_plain_ok, plain_base_5a + 1, 10);

                // Start newer detail `req_seq = N+1` -> hits 401 -> parks OAuth refresh at refresh latch:
                int next_seq_5a = atomic_load(&g_srv.refresh_rotate_seq) + 1;
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_5a);
                snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Newer Replay N2");
                snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Newer St N2");
                g_srv.refresh_gate_enabled = 1;
                g_srv.refresh_budget = 0;
                pthread_mutex_unlock(&g_srv.mu);
                atomic_store(&g_srv.ws1_require_rotated_token, 1);

                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_5a + 1, 10);

                // While refresh for `N+1` is parked in-flight, release older `N` so `N` commits `Ok(true)` FIRST!
                pthread_mutex_lock(&g_srv.mu);
                g_srv.ws1_plain_200_gate_enabled = 0;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_for_matching_msg(&g_host, "\"id\":811,", "Live Older Commit N", 10);
                wait_for_matching_msg(&g_host, "\"id\":812,", "Live Older St N", 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);

                // Now release refresh -> new bearer adopted -> `N+1` MUST STILL replay as `N+2 >= N+1`!
                pthread_mutex_lock(&g_srv.mu);
                g_srv.refresh_gate_enabled = 0;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_for_matching_msg(&g_host, "\"id\":811,", "Live Newer Replay N2", 10);
                wait_for_matching_msg(&g_host, "\"id\":812,", "Live Newer St N2", 10);
                wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_5a + 1, 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5a == 1);
                printf("[live_net_e2e] Phase 11b-5a PASSED (older commit N did NOT erase newer 401 replay demand N+1; replayed N+2 after refresh)\n");

                // (b) Same-bearer 401 crossing role upgrade (`member -> owner`, `boundary_1 -> 0L`):
                atomic_store(&g_srv.ws1_downgrade_member, 1); // owner -> member (installs boundary_1 > 0)
                atomic_store(&g_srv.ws1_require_rotated_token, 0);
                pthread_mutex_lock(&g_srv.mu);
                g_srv.ws1_custom_name[0] = '\0';
                g_srv.ws1_custom_station[0] = '\0';
                pthread_mutex_unlock(&g_srv.mu);
                send_json("{\"id\":824,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
                wait_for_matching_msg(&g_host, "\"id\":824,", "\"ok\":{", 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                // Confirm baseline role is `"member"` via `workspaces.list` + subscribe `workspaces` for deterministic commit barrier:
                send_json("{\"id\":8241,\"call\":\"workspaces.list\",\"params\":{}}");
                char *m_wl_5b_before = wait_for_matching_msg(&g_host, "\"id\":8241,", "\"ok\":{", 10);
                assert(strstr(m_wl_5b_before, "\"role\":\"member\"") != NULL);
                send_json("{\"id\":814,\"subscribe\":{\"topic\":\"workspaces\"},\"keyed\":true}");
                wait_for_matching_msg(&g_host, "\"id\":814,", "\"role\":\"member\"", 10);

                int ws401_base_5b = atomic_load(&g_srv.got_ws1_401);
                int ref_base_5b = atomic_load(&g_srv.got_auth_refresh);
                int rot_ok_base_5b = atomic_load(&g_srv.got_ws1_rotated_ok);
                int next_seq_5b = atomic_load(&g_srv.refresh_rotate_seq) + 1;
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_5b);
                snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Upgrade CrossB");
                snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Upgrade St");
                g_srv.ws1_401_gate_enabled = 1;
                g_srv.ws1_401_budget = 0;
                pthread_mutex_unlock(&g_srv.mu);
                atomic_store(&g_srv.ws1_require_rotated_token, 1);

                // Start detail fetch under `boundary_1 > 0` and park its 401 response at server latch:
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base_5b + 1, 10);

                // While that `boundary_1` 401 is parked, upgrade Alice `member -> owner` (`boundary_1 -> 0L`)
                // on the SAME bearer and explicitly prove `workspaces.list` already committed `"role":"owner"`
                // BEFORE releasing the parked 401!
                int me_base_5b = atomic_load(&g_srv.got_me);
                atomic_store(&g_srv.ws1_downgrade_member, 0);
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspaces\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_me, me_base_5b + 1, 10);
                wait_for_matching_msg(&g_host, "\"id\":814,", "\"role\":\"owner\"", 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);
                send_json("{\"id\":825,\"call\":\"workspaces.list\",\"params\":{}}");
                char *m_wl_5b_after = wait_for_matching_msg(&g_host, "\"id\":825,", "\"ok\":{", 10);
                assert(strstr(m_wl_5b_after, "\"role\":\"owner\"") != NULL);
                assert(atomic_load(&g_srv.got_ws1_401) == ws401_base_5b + 1);
                assert(atomic_load(&g_srv.got_auth_refresh) == ref_base_5b);

                // Release parked `boundary_1` 401 -> same bearer across `boundary_1 -> 0L` MUST re-issue
                // under `0L`, trigger refresh once, and commit latest workspace & stations!
                pthread_mutex_lock(&g_srv.mu);
                g_srv.ws1_401_gate_enabled = 0;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);

                wait_for_matching_msg(&g_host, "\"id\":811,", "Live Upgrade CrossB", 10);
                wait_for_matching_msg(&g_host, "\"id\":812,", "Live Upgrade St", 10);
                wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_5b + 1, 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5b == 1);
                printf("[live_net_e2e] Phase 11b-5b PASSED (workspaces.list confirmed owner BEFORE 401 release; same-bearer 401 across boundary_1->0L re-issued & confirmed)\n");

                // (c) R12 Codex P1: Role upgrade (`member -> owner`, `boundary_1 -> 0L`) inserted strictly
                //     BETWEEN detail 401 starting OAuth Refresh #1 AND Refresh #1 returning transient HTTP 500!
                //     With ZERO further external WS pushes, retiring old boundary MUST hand off the live
                //     replay demand to `0L`, trigger a new detail fetch + Refresh #2 (200), and confirm client!
                atomic_store(&g_srv.ws1_downgrade_member, 1); // owner -> member (installs boundary_1 > 0)
                atomic_store(&g_srv.ws1_require_rotated_token, 0);
                pthread_mutex_lock(&g_srv.mu);
                g_srv.ws1_custom_name[0] = '\0';
                g_srv.ws1_custom_station[0] = '\0';
                pthread_mutex_unlock(&g_srv.mu);
                send_json("{\"id\":826,\"call\":\"cloud.sync\",\"params\":{\"workspace\":\"" WS1_ID "\"}}");
                wait_for_matching_msg(&g_host, "\"id\":826,", "\"ok\":{", 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                send_json("{\"id\":8261,\"call\":\"workspaces.list\",\"params\":{}}");
                char *m_wl_5c_before = wait_for_matching_msg(&g_host, "\"id\":8261,", "\"ok\":{", 10);
                assert(strstr(m_wl_5c_before, "\"role\":\"member\"") != NULL);
                // Fresh `workspaces` subscription for 0-polling event-driven commit barrier (docs/development.md):
                send_json("{\"id\":815,\"subscribe\":{\"topic\":\"workspaces\"},\"keyed\":true}");
                wait_for_matching_msg(&g_host, "\"id\":815,", "\"role\":\"member\"", 10);

                int ref_base_5c = atomic_load(&g_srv.got_auth_refresh);
                int rot_ok_base_5c = atomic_load(&g_srv.got_ws1_rotated_ok);
                int next_seq_5c = atomic_load(&g_srv.refresh_rotate_seq) + 1;
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + next_seq_5c);
                snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Handoff 500 Confirmed");
                snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Handoff 500 St");
                g_srv.refresh_gate_enabled = 1;
                g_srv.refresh_budget = 0;
                pthread_mutex_unlock(&g_srv.mu);
                atomic_store(&g_srv.refresh_fail_500_remaining, 1);
                atomic_store(&g_srv.ws1_require_rotated_token, 1);

                // Trigger detail 401 under `boundary_1` -> starts OAuth Refresh #1 which parks at refresh latch:
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_5c + 1, 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);

                // While Refresh #1 (destined for transient HTTP 500) is parked in-flight, upgrade `member -> owner`
                // and wait deterministically on `id:815` (`workspaces` topic push, ZERO polling!) + confirm `workspaces.list`!
                int me_base_5c = atomic_load(&g_srv.got_me);
                atomic_store(&g_srv.ws1_downgrade_member, 0);
                pthread_mutex_lock(&g_srv.mu);
                snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspaces\"}");
                g_srv.cloud_ws_push_ready = 1;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);
                wait_srv_atomic_ge(&g_srv.got_me, me_base_5c + 1, 10);
                wait_for_matching_msg(&g_host, "\"id\":815,", "\"role\":\"owner\"", 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);
                send_json("{\"id\":827,\"call\":\"workspaces.list\",\"params\":{}}");
                char *m_wl_5c_after = wait_for_matching_msg(&g_host, "\"id\":827,", "\"ok\":{", 10);
                assert(strstr(m_wl_5c_after, "\"role\":\"owner\"") != NULL);
                assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5c == 1);

                // Release parked Refresh #1 -> returns transient HTTP 500 -> old boundary retires & hands off
                // live replay demand to `0L` -> auto-fetches under `0L` -> Refresh #2 (200) -> commits client!
                pthread_mutex_lock(&g_srv.mu);
                g_srv.refresh_gate_enabled = 0;
                pthread_cond_broadcast(&g_srv.cv);
                pthread_mutex_unlock(&g_srv.mu);

                wait_for_matching_msg(&g_host, "\"id\":811,", "Live Handoff 500 Confirmed", 10);
                wait_for_matching_msg(&g_host, "\"id\":812,", "Live Handoff 500 St", 10);
                wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_5c + 2, 10);
                wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_5c + 1, 10);
                wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5c == 2);
                printf("[live_net_e2e] Phase 11b-5c PASSED (boundary_1->0L upgrade mid-refresh before transient 500 handed off to 0L & confirmed with 0 polling)\n");

                // (d) R13 Codex P1: At `cur_rot == 2` with the 2nd rotated bearer's 200 STILL in-flight,
                //     a late old-bearer 401 MUST NOT prematurely erase `pending_live_ws_replay_seq`:
                //     when a newer `/v1/me` fences that in-flight 200 (`Ok(false)`), the runtime MUST
                //     automatically re-fetch with the live bearer and commit `Ok(true)` (0 extra refresh)!
                {
                    int cur_seq_5d = atomic_load(&g_srv.refresh_rotate_seq);
                    int ws401_base_5d = atomic_load(&g_srv.got_ws1_401);
                    int ref_base_5d = atomic_load(&g_srv.got_auth_refresh);
                    int rot_ok_base_5d = atomic_load(&g_srv.got_ws1_rotated_ok);
                    pthread_mutex_lock(&g_srv.mu);
                    snprintf(g_srv.ws1_hold_401_bearer, sizeof(g_srv.ws1_hold_401_bearer), "Bearer acc-rotated-%d", 99 + cur_seq_5d);
                    snprintf(g_srv.ws1_expected_bearer, sizeof(g_srv.ws1_expected_bearer), "acc-rotated-%d", 99 + cur_seq_5d + 2);
                    snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Rot2 Stale PreMe");
                    snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Rot2 Stale St");
                    g_srv.ws1_401_gate_enabled = 1;
                    g_srv.ws1_401_budget = 0;
                    g_srv.ws1_200_gate_enabled = 1;
                    g_srv.ws1_200_budget = 0;
                    pthread_mutex_unlock(&g_srv.mu);
                    atomic_store(&g_srv.ws1_require_rotated_token, 1);

                    // Step 1: Fire 2 concurrent WS `workspace` events on OLD bearer `gen G` -> BOTH park at 401 latch:
                    pthread_mutex_lock(&g_srv.mu);
                    snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                    g_srv.cloud_ws_push_ready = 1;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);
                    wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base_5d + 1, 10);

                    pthread_mutex_lock(&g_srv.mu);
                    snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspace\",\"id\":\"" WS1_ID "\"}");
                    g_srv.cloud_ws_push_ready = 1;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);
                    wait_srv_atomic_ge(&g_srv.got_ws1_401, ws401_base_5d + 2, 10);

                    // Step 2: Release ONLY 1 of the 2 `gen G` 401s -> Refresh #1 (`cur_rot=1`, `gen G+1` 401 passes
                    // immediately) -> Refresh #2 (`cur_rot=2`, `gen G+2` 200 parks at 200 latch)!
                    pthread_mutex_lock(&g_srv.mu);
                    g_srv.ws1_401_budget += 1;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);

                    wait_srv_atomic_ge(&g_srv.got_auth_refresh, ref_base_5d + 2, 10);
                    wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_5d + 1, 10);
                    wait_srv_atomic_eq(&g_srv.active_http_conns, 2, 10);

                    // Step 3: Release the 2nd parked `gen G` 401 WHILE `cur_rot == 2` and `gen G+2`'s 200 is in-flight!
                    pthread_mutex_lock(&g_srv.mu);
                    g_srv.ws1_401_gate_enabled = 0;
                    g_srv.ws1_hold_401_bearer[0] = '\0';
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);
                    wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);
                    send_json("{\"id\":828,\"call\":\"workspaces.list\",\"params\":{}}");
                    wait_for_matching_msg(&g_host, "\"id\":828,", "\"ok\":{", 10);
                    assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5d == 2);

                    // Step 4: Advance `/v1/me` (event-driven barrier via `id:815` `"Live Rot2 Me Fence"`) so the
                    // parked `gen G+2` 200 will be rejected with `Ok(false)`!
                    int me_base_5d = atomic_load(&g_srv.got_me);
                    pthread_mutex_lock(&g_srv.mu);
                    snprintf(g_srv.ws1_me_name, sizeof(g_srv.ws1_me_name), "Live Rot2 Me Fence");
                    snprintf(g_srv.pending_cloud_ws_msg, sizeof(g_srv.pending_cloud_ws_msg), "{\"type\":\"workspaces\"}");
                    g_srv.cloud_ws_push_ready = 1;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);
                    wait_srv_atomic_ge(&g_srv.got_me, me_base_5d + 1, 10);
                    wait_for_matching_msg(&g_host, "\"id\":815,", "Live Rot2 Me Fence", 10);
                    wait_srv_atomic_eq(&g_srv.active_http_conns, 1, 10);

                    // Step 5: Release parked `gen G+2` 200 -> `Ok(false)` -> `pending_live_ws_replay_seq` STILL alive ->
                    // automatically re-fetches with live `gen G+2` bearer and commits `Ok(true)` with 0 extra refresh!
                    pthread_mutex_lock(&g_srv.mu);
                    g_srv.ws1_me_name[0] = '\0';
                    snprintf(g_srv.ws1_custom_name, sizeof(g_srv.ws1_custom_name), "Live Rot2 Late401 Preserved");
                    snprintf(g_srv.ws1_custom_station, sizeof(g_srv.ws1_custom_station), "Live Rot2 Late401 St");
                    g_srv.ws1_200_gate_enabled = 0;
                    pthread_cond_broadcast(&g_srv.cv);
                    pthread_mutex_unlock(&g_srv.mu);

                    wait_for_matching_msg(&g_host, "\"id\":811,", "Live Rot2 Late401 Preserved", 10);
                    wait_for_matching_msg(&g_host, "\"id\":812,", "Live Rot2 Late401 St", 10);
                    wait_srv_atomic_ge(&g_srv.got_ws1_rotated_ok, rot_ok_base_5d + 2, 10);
                    wait_srv_atomic_eq(&g_srv.active_http_conns, 0, 10);
                    assert(atomic_load(&g_srv.got_auth_refresh) - ref_base_5d == 2);
                    pthread_mutex_lock(&g_host.mu);
                    for (int mi = 0; mi < g_host.count; mi++) {
                        assert(strstr(g_host.msgs[mi].json, "Live Rot2 Stale PreMe") == NULL);
                    }
                    pthread_mutex_unlock(&g_host.mu);
                    printf("[live_net_e2e] Phase 11b-5d PASSED (late old-bearer 401 at cur_rot==2 preserved live replay across Ok(false) with 0 extra refresh)\n");
                }
            }
            atomic_store(&g_srv.enable_cloud_ws, 0);
            pthread_mutex_lock(&g_srv.mu);
            pthread_cond_broadcast(&g_srv.cv);
            pthread_mutex_unlock(&g_srv.mu);
        }
    }

    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    stop_fake_server();
    assert(atomic_load(&g_host.post_stop_count) == 0);
    printf("[live_net_e2e] ALL LIVE RUST SHELL + INVARIANT 1 ACCOUNT DB LIFECYCLE E2E CHECKS PASSED!\n");
    return 0;
}
