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
#include <time.h>
#include <unistd.h>

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);

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
    _Atomic int drop_ws2_in_me;
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
        if (strstr(body, "\"code\":\"live_oauth_code_bob\"") != NULL) {
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
        send_http_json(fd, 401, "Unauthorized", "{\"error\":\"invalid_grant\"}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /chats ", 11) == 0) {
        send_http_json(fd, 200, "OK", "{\"chats\":[],\"entries\":[]}");
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

    // Register a private download for Alice before Phase 5 401 logout to verify 0 download registry leakage to Bob!
    send_json("{\"id\":2041,\"call\":\"download.join\",\"params\":{\"reader\":\"dl-alice-live\",\"fileKey\":\"alice-private-doc.pdf\",\"name\":\"alice-private-doc.pdf\",\"start\":0,\"end\":4096}}");
    wait_for_matching_msg(&g_host, "\"id\":2041,", "\"ok\"", 10);

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

    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    stop_fake_server();
    assert(atomic_load(&g_host.post_stop_count) == 0);
    printf("[live_net_e2e] ALL LIVE RUST SHELL + INVARIANT 1 ACCOUNT DB LIFECYCLE E2E CHECKS PASSED!\n");
    return 0;
}
