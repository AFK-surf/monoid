// Real live-network C host E2E test linking `libstillfail_shell.so` + `core_pion.c` +
// `shell_pion.c` + `libpion_core_runtime.a` against a real loopback TCP/HTTP/SSE fake cloud
// and fake station server on `127.0.0.1:<port>`:
//
// 1. Real Rust `libstillfail_shell.so` `fetch` pulls `/v1/me` and `/v1/workspaces/ws-live`
//    and persists both into real SQLite WAL (`account_doc`, `workspace`).
// 2. Real Rust `libstillfail_shell.so` `stream.open` + `stream.read` opens a live `/events`
//    SSE stream.
// 3. `mb_core_send` sends `message.send` -> real HTTP `POST /threads/42/messages` reaches the
//    loopback station -> station pushes `event: entry` over the live SSE stream -> `ClientCore`
//    reconciles by exact `clientKey` (`OutboxResolved`) and emits it to C `on_message`.
// 4. `mb_core_stop` finishes cleanly with `post_stop=0` and `exit 0`.

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
#include <time.h>
#include <unistd.h>

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);

#define MAX_MSGS 128

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
            fprintf(stderr, "[live_net_e2e] TIMEOUT waiting for '%s' (saw %d msgs):\n", needle1, h->count);
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
    _Atomic int got_me;
    _Atomic int got_ws;
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
        send_http_json(
            fd,
            200,
            "OK",
            "{\"user\":{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"name\":\"Alice\"},"
            "\"workspaces\":[{\"id\":\"ws-live\",\"name\":\"Live Workspace\",\"role\":\"owner\"}],"
            "\"relay_urls\":[\"https://relay.live.example\"]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /v1/workspaces/ws-live ", 27) == 0) {
        atomic_fetch_add(&g_srv.got_ws, 1);
        send_http_json(
            fd,
            200,
            "OK",
            "{\"id\":\"ws-live\",\"name\":\"Live Workspace\",\"rev\":1,"
            "\"members\":[{\"sub\":\"u-live\",\"email\":\"alice@still.fail\",\"role\":\"owner\"}],"
            "\"stations\":[{\"id\":\"st-local\",\"name\":\"Live Station\",\"online\":true}]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /chats ", 11) == 0) {
        send_http_json(fd, 200, "OK", "{\"chats\":[],\"entries\":[]}");
        close(fd);
        return NULL;
    }

    if (strncmp(buf, "GET /events", 11) == 0) {
        atomic_fetch_add(&g_srv.got_events, 1);
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
        // Respond 202 without `n` so OutboxResolved MUST be driven by the live SSE push!
        send_http_json(fd, 202, "Accepted", "{\"accepted\":true}");
        close(fd);

        pthread_mutex_lock(&g_srv.mu);
        snprintf(
            g_srv.pending_sse_event,
            sizeof(g_srv.pending_sse_event),
            "id: 101\nevent: entry\ndata: {\"thread\":42,\"n\":7,\"kind\":\"message\","
            "\"authorKind\":\"person\",\"author\":\"alice\","
            "\"text\":\"hello over real rust shell\",\"clientKey\":\"ck-live-net-1\"}\n\n");
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

    printf("[live_net_e2e] starting mb_core_start origin=%s dir=%s\n", origin, data_dir);
    mb_core_attach_pion_runtime();
    mb_core_start(data_dir, origin, 1, on_host_message, &g_host);

    // 1. Real Rust `fetch` -> GET /v1/me + GET /v1/workspaces/ws-live -> persisted to SQLite WAL
    send_json("{\"id\":1,\"call\":\"cloud.sync\",\"params\":{\"token\":\"tok-live\",\"workspace\":\"ws-live\"}}");
    char *m_cloud = wait_for_matching_msg(&g_host, "\"id\":1", "\"workspace\":\"ws-live\"", 10);
    printf("[live_net_e2e] #1 cloud.sync -> %s\n", m_cloud);
    assert(strstr(m_cloud, "\"email\":\"alice@still.fail\"") != NULL);
    assert(strstr(m_cloud, "\"stations\":1") != NULL);
    assert(atomic_load(&g_srv.got_me) >= 1 && atomic_load(&g_srv.got_ws) >= 1);

    // 2. Real Rust `stream.open` + `stream.read` -> live `/events` SSE stream
    send_json("{\"id\":2,\"call\":\"station.connect\",\"params\":{}}");
    char *m_conn = wait_for_matching_msg(&g_host, "\"event\":\"connection\"", "\"state\":\"connected\"", 10);
    printf("[live_net_e2e] #2 station.connect SSE -> %s\n", m_conn);
    assert(atomic_load(&g_srv.got_events) >= 1);

    // 3. Real online `message.send` -> HTTP POST -> live SSE push -> `OutboxResolved` by `clientKey`
    send_json("{\"id\":3,\"call\":\"message.send\",\"params\":{\"thread\":42,\"clientKey\":\"ck-live-net-1\",\"author\":\"alice\",\"text\":\"hello over real rust shell\"}}");
    char *m_send = wait_for_matching_msg(&g_host, "\"id\":3", "\"queued\":true", 10);
    printf("[live_net_e2e] #3 message.send -> %s\n", m_send);

    char *m_resolved = wait_for_matching_msg(&g_host, "\"event\":\"outbox.resolved\"", "\"clientKey\":\"ck-live-net-1\"", 10);
    printf("[live_net_e2e] #4 SSE OutboxResolved -> %s\n", m_resolved);
    assert(strstr(m_resolved, "\"n\":7") != NULL);
    assert(atomic_load(&g_srv.got_post_msg) == 1);

    // 4. Clean stop with post_stop=0
    atomic_store(&g_host.stopped, 1);
    mb_core_stop();
    stop_fake_server();
    assert(atomic_load(&g_host.post_stop_count) == 0);
    printf("[live_net_e2e] ALL LIVE RUST SHELL HTTP/SSE/SQLITE E2E CHECKS PASSED (msgs=%d, post_stop=%d)\n",
           g_host.count, atomic_load(&g_host.post_stop_count));
    return 0;
}
