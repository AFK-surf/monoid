// Thin removable C ABI bridge implementing all 6 functions of `apps/mbui/src/host/core_api.h`
// for `pion/client-core`.
//
// Threading & lifecycle invariants:
// - `mb_core_send` copies JSON + optional bytes onto a FIFO queue and returns immediately (never blocks UI).
// - The dedicated core worker thread drains the queue and invokes the registered driver with the mutex unlocked.
// - `on_message` is NEVER invoked while holding the internal mutex (safe against re-entrant `mb_core_send`).
// - `mb_core_stop` signals shutdown, joins the core worker thread, waits for any in-flight `mb_core_emit`,
//   and clears callbacks; NO `on_message` callback can fire after `mb_core_stop` returns.

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "core_api.h"
#include "pion_rt.h"

// ── Internal driver slot API (for Pion core or C test harness) ──

typedef void (*mb_core_driver_start_fn)(
    const char *data_dir,
    const char *cloud_origin,
    int beta,
    void *user_ctx);

typedef void (*mb_core_driver_send_fn)(
    const char *json,
    size_t len,
    const uint8_t *bytes,
    size_t blen,
    void *user_ctx);

typedef void (*mb_core_driver_stop_fn)(void *user_ctx);

typedef int (*mb_core_driver_screen_ack_fn)(double call, double ts, void *user_ctx);

typedef int (*mb_core_driver_screen_input_fn)(
    double call,
    const uint8_t *json,
    size_t len,
    void *user_ctx);

typedef struct mb_core_driver {
    mb_core_driver_start_fn on_start;
    mb_core_driver_send_fn on_send;
    mb_core_driver_stop_fn on_stop;
    mb_core_driver_screen_ack_fn on_screen_ack;
    mb_core_driver_screen_input_fn on_screen_input;
    void *user_ctx;
} mb_core_driver_t;

void mb_core_register_driver(const mb_core_driver_t *driver);
int mb_core_emit(const char *json, size_t len, const uint8_t *bytes, size_t blen);
int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len);

// ── Internal queue & state ──

typedef struct core_msg_node {
    struct core_msg_node *next;
    char *json;
    size_t len;
    uint8_t *bytes;
    size_t blen;
} core_msg_node_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_ready_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_emit_done = PTHREAD_COND_INITIALIZER;

static int g_started = 0;
static int g_ready = 0;
static int g_stopping = 0;
static int g_in_flight_emits = 0;
static pthread_t g_worker;

static char *g_data_dir = NULL;
static char *g_cloud_origin = NULL;
static int g_beta = 0;
static mb_core_message_fn g_on_message = NULL;
static void *g_msg_ctx = NULL;

static core_msg_node_t *g_head = NULL;
static core_msg_node_t *g_tail = NULL;

static mb_core_driver_t g_driver = {NULL, NULL, NULL, NULL, NULL, NULL};
static mb_core_media_fn g_media_fn = NULL;

static char *dup_cstr(const char *s) {
    if (s == NULL) {
        return NULL;
    }
    size_t n = strlen(s);
    char *out = (char *)malloc(n + 1);
    if (out == NULL) {
        abort();
    }
    memcpy(out, s, n + 1);
    return out;
}

static void free_msg_node(core_msg_node_t *node) {
    if (node == NULL) {
        return;
    }
    free(node->json);
    free(node->bytes);
    free(node);
}

static void drain_queue_locked(void) {
    core_msg_node_t *cur = g_head;
    g_head = NULL;
    g_tail = NULL;
    while (cur != NULL) {
        core_msg_node_t *next = cur->next;
        free_msg_node(cur);
        cur = next;
    }
}

void mb_core_register_driver(const mb_core_driver_t *driver) {
    pthread_mutex_lock(&g_lock);
    if (driver != NULL) {
        g_driver = *driver;
    } else {
        memset(&g_driver, 0, sizeof(g_driver));
    }
    pthread_mutex_unlock(&g_lock);
}

int mb_core_emit(const char *json, size_t len, const uint8_t *bytes, size_t blen) {
    if (json == NULL && len > 0) {
        return 0;
    }
    pthread_mutex_lock(&g_lock);
    if (!g_started || g_stopping || g_on_message == NULL) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    mb_core_message_fn cb = g_on_message;
    void *ctx = g_msg_ctx;
    g_in_flight_emits += 1;
    pthread_mutex_unlock(&g_lock);

    cb(json, len, bytes, blen, ctx);

    pthread_mutex_lock(&g_lock);
    g_in_flight_emits -= 1;
    if (g_in_flight_emits == 0) {
        pthread_cond_broadcast(&g_emit_done);
    }
    pthread_mutex_unlock(&g_lock);
    return 1;
}

int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len) {
    pthread_mutex_lock(&g_lock);
    mb_core_media_fn fn = g_media_fn;
    pthread_mutex_unlock(&g_lock);
    if (fn == NULL) {
        return 0;
    }
    return fn(call, kind, key, seq, ts, bytes, len);
}

static void *core_worker_main(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_lock);
    char *dir = dup_cstr(g_data_dir);
    char *origin = dup_cstr(g_cloud_origin);
    int beta = g_beta;
    mb_core_driver_t drv = g_driver;
    g_ready = 1;
    pthread_cond_broadcast(&g_ready_cond);
    pthread_mutex_unlock(&g_lock);

    if (dir == NULL || dir[0] == '\0') {
        static const char fatal_msg[] = "{\"fatal\":\"missing data_dir\"}";
        (void)mb_core_emit(fatal_msg, sizeof(fatal_msg) - 1, NULL, 0);
    } else if (drv.on_start != NULL) {
        drv.on_start(dir, origin != NULL ? origin : "", beta, drv.user_ctx);
    }

    for (;;) {
        pthread_mutex_lock(&g_lock);
        while (g_head == NULL && !g_stopping) {
            pthread_cond_wait(&g_cond, &g_lock);
        }
        if (g_stopping) {
            pthread_mutex_unlock(&g_lock);
            break;
        }
        core_msg_node_t *node = g_head;
        g_head = node->next;
        if (g_head == NULL) {
            g_tail = NULL;
        }
        mb_core_driver_t cur_drv = g_driver;
        pthread_mutex_unlock(&g_lock);

        if (cur_drv.on_send != NULL) {
            cur_drv.on_send(node->json, node->len, node->bytes, node->blen, cur_drv.user_ctx);
        } else {
            static const char no_drv[] = "{\"fatal\":\"core driver not attached\"}";
            (void)mb_core_emit(no_drv, sizeof(no_drv) - 1, NULL, 0);
        }
        free_msg_node(node);
    }

    pthread_mutex_lock(&g_lock);
    mb_core_driver_t stop_drv = g_driver;
    pthread_mutex_unlock(&g_lock);
    if (stop_drv.on_stop != NULL) {
        stop_drv.on_stop(stop_drv.user_ctx);
    }

    free(dir);
    free(origin);
    return NULL;
}

// ── Public `apps/mbui/src/host/core_api.h` 6-function C ABI ──

void mb_core_start(
    const char *data_dir,
    const char *cloud_origin,
    int beta,
    mb_core_message_fn on_message,
    void *ctx) {
    pthread_mutex_lock(&g_lock);
    if (g_started) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_data_dir = dup_cstr(data_dir);
    g_cloud_origin = dup_cstr(cloud_origin);
    g_beta = beta;
    g_on_message = on_message;
    g_msg_ctx = ctx;
    g_stopping = 0;
    g_ready = 0;
    g_started = 1;

    if (pthread_create(&g_worker, NULL, core_worker_main, NULL) != 0) {
        g_started = 0;
        free(g_data_dir);
        free(g_cloud_origin);
        g_data_dir = NULL;
        g_cloud_origin = NULL;
        g_on_message = NULL;
        g_msg_ctx = NULL;
        pthread_mutex_unlock(&g_lock);
        if (on_message != NULL) {
            static const char err[] = "{\"fatal\":\"failed to start core thread\"}";
            on_message(err, sizeof(err) - 1, NULL, 0, ctx);
        }
        return;
    }

    while (!g_ready) {
        pthread_cond_wait(&g_ready_cond, &g_lock);
    }
    pthread_mutex_unlock(&g_lock);
}

void mb_core_send(const char *json, size_t len, const uint8_t *bytes, size_t blen) {
    if (json == NULL && len > 0) {
        return;
    }
    core_msg_node_t *node = (core_msg_node_t *)calloc(1, sizeof(*node));
    if (node == NULL) {
        abort();
    }
    node->len = len;
    if (len > 0) {
        node->json = (char *)malloc(len + 1);
        if (node->json == NULL) {
            abort();
        }
        memcpy(node->json, json, len);
        node->json[len] = '\0';
    } else {
        node->json = dup_cstr("");
    }
    if (bytes != NULL && blen > 0) {
        node->bytes = (uint8_t *)malloc(blen);
        if (node->bytes == NULL) {
            abort();
        }
        memcpy(node->bytes, bytes, blen);
        node->blen = blen;
    }

    pthread_mutex_lock(&g_lock);
    if (!g_started || g_stopping) {
        pthread_mutex_unlock(&g_lock);
        free_msg_node(node);
        return;
    }
    if (g_tail != NULL) {
        g_tail->next = node;
    } else {
        g_head = node;
    }
    g_tail = node;
    pthread_cond_signal(&g_cond);
    pthread_mutex_unlock(&g_lock);
}

void mb_core_stop(void) {
    pthread_mutex_lock(&g_lock);
    if (!g_started) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_stopping = 1;
    pthread_cond_broadcast(&g_cond);
    pthread_t tid = g_worker;
    pthread_mutex_unlock(&g_lock);

    (void)pthread_join(tid, NULL);

    pthread_mutex_lock(&g_lock);
    while (g_in_flight_emits > 0) {
        pthread_cond_wait(&g_emit_done, &g_lock);
    }
    drain_queue_locked();
    free(g_data_dir);
    free(g_cloud_origin);
    g_data_dir = NULL;
    g_cloud_origin = NULL;
    g_on_message = NULL;
    g_msg_ctx = NULL;
    g_beta = 0;
    g_ready = 0;
    g_stopping = 0;
    g_started = 0;
    pthread_mutex_unlock(&g_lock);
}

int mb_core_screen_ack(double call, double ts) {
    pthread_mutex_lock(&g_lock);
    mb_core_driver_screen_ack_fn fn = g_driver.on_screen_ack;
    void *ctx = g_driver.user_ctx;
    pthread_mutex_unlock(&g_lock);
    if (fn == NULL) {
        return 0;
    }
    return fn(call, ts, ctx);
}

int mb_core_screen_input(double call, const uint8_t *json, size_t len) {
    pthread_mutex_lock(&g_lock);
    mb_core_driver_screen_input_fn fn = g_driver.on_screen_input;
    void *ctx = g_driver.user_ctx;
    pthread_mutex_unlock(&g_lock);
    if (fn == NULL) {
        return 0;
    }
    return fn(call, json, len, ctx);
}

void mb_core_route_media(mb_core_media_fn take) {
    pthread_mutex_lock(&g_lock);
    g_media_fn = take;
    pthread_mutex_unlock(&g_lock);
}
