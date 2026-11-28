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

#define MAX_MSGS 256
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
    _Atomic int drop_ws2_in_me;
    _Atomic int serve_ws1_lock;
    _Atomic int got_me;
    _Atomic int got_ws;
    _Atomic int got_auth_token;
    _Atomic int got_auth_refresh;
    _Atomic int got_events;
    _Atomic int got_post_msg;
} fake_server_t;

static fake_server_t g_srv;

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

static void *handle_client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
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

    if (strncmp(buf, "GET /v1/me ", 11) == 0) {
        atomic_fetch_add(&g_srv.got_me, 1);
        if (atomic_load(&g_srv.drop_ws2_in_me)) {
            send_http_json(
                fd,
                200,
                "OK",
                "{\"user\":{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\"},"
                "\"workspaces\":[{\"id\":\"" WS1_ID "\",\"name\":\"Live Workspace\",\"role\":\"owner\",\"created_at\":1700000000,\"stations\":1,\"members\":1}],"
                "\"relay_urls\":[\"https://relay.live.example\"]}");
        } else {
            send_http_json(
                fd,
                200,
                "OK",
                "{\"user\":{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\"},"
                "\"workspaces\":["
                "{\"id\":\"" WS1_ID "\",\"name\":\"Live Workspace\",\"role\":\"owner\",\"created_at\":1700000000,\"stations\":1,\"members\":1},"
                "{\"id\":\"" WS2_ID "\",\"name\":\"Drop Me WS\",\"role\":\"member\",\"created_at\":1700000001,\"stations\":1,\"members\":2}"
                "],"
                "\"relay_urls\":[\"https://relay.live.example\"]}");
        }
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/workspaces/" WS1_ID " ", 46) == 0) {
        atomic_fetch_add(&g_srv.got_ws, 1);
        send_http_json(
            fd,
            200,
            "OK",
            "{\"id\":\"" WS1_ID "\",\"name\":\"Live Workspace\",\"rev\":1,"
            "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"owner\"}],"
            "\"stations\":[{\"id\":\"st-local\",\"name\":\"Live Station\",\"online\":true}]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/workspaces/" WS2_ID " ", 46) == 0) {
        atomic_fetch_add(&g_srv.got_ws, 1);
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
               strstr(body, "\"refresh_token\":\"ref-bob-1\"") != NULL);
        atomic_fetch_add(&g_srv.got_auth_refresh, 1);
        pthread_mutex_lock(&g_srv.mu);
        if (g_srv.slow_refresh_hold) {
            g_srv.slow_refresh_entered = 1;
            pthread_cond_broadcast(&g_srv.cv);
            while (!g_srv.slow_refresh_release && !g_srv.shutdown) {
                pthread_cond_wait(&g_srv.cv, &g_srv.mu);
            }
        }
        pthread_mutex_unlock(&g_srv.mu);
        send_http_json(fd, 401, "Unauthorized", "{\"error\":\"invalid_grant\"}");
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
        pthread_t th;
        if (pthread_create(&th, NULL, handle_client_thread, (void *)(intptr_t)cfd) == 0) {
            pthread_detach(th);
        } else {
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

    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    stop_fake_server();
    assert(atomic_load(&g_host.post_stop_count) == 0);
    printf("[live_net_e2e] ALL LIVE RUST SHELL + INVARIANT 1 ACCOUNT DB LIFECYCLE E2E CHECKS PASSED!\n");
    return 0;
}
