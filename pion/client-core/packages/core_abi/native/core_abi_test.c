// Standalone C ABI integration test against the real `apps/mbui/src/host/core_api.h`.
// Verifies:
// 1. 100% compile-time signature match for all 6 `core_api.h` functions.
// 2. Multi-threaded `start -> concurrent send (json + bytes) -> on_message -> stop` with zero races.
// 3. `on_message` is invoked without holding internal mutex (re-entrant `mb_core_send` does not deadlock).
// 4. `mb_core_screen_ack`, `mb_core_screen_input`, and `mb_core_route_media` dispatch cleanly.
// 5. Zero callbacks after `mb_core_stop` returns, and clean restart cycle.

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "core_api.h"

// Internal driver hooks from core_pion.c
typedef void (*mb_core_driver_start_fn)(const char *, const char *, int, void *);
typedef void (*mb_core_driver_send_fn)(const char *, size_t, const uint8_t *, size_t, void *);
typedef void (*mb_core_driver_stop_fn)(void *);
typedef int (*mb_core_driver_screen_ack_fn)(double, double, void *);
typedef int (*mb_core_driver_screen_input_fn)(double, const uint8_t *, size_t, void *);

typedef struct mb_core_driver {
    mb_core_driver_start_fn on_start;
    mb_core_driver_send_fn on_send;
    mb_core_driver_stop_fn on_stop;
    mb_core_driver_screen_ack_fn on_screen_ack;
    mb_core_driver_screen_input_fn on_screen_input;
    void *user_ctx;
} mb_core_driver_t;

extern void mb_core_register_driver(const mb_core_driver_t *driver);
extern int mb_core_emit(const char *json, size_t len, const uint8_t *bytes, size_t blen);
extern int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len);

// Compile-time exact ABI signature assertions against `core_api.h`
static void (*const k_chk_start)(const char *, const char *, int, mb_core_message_fn, void *) = mb_core_start;
static void (*const k_chk_send)(const char *, size_t, const uint8_t *, size_t) = mb_core_send;
static void (*const k_chk_stop)(void) = mb_core_stop;
static int (*const k_chk_ack)(double, double) = mb_core_screen_ack;
static int (*const k_chk_input)(double, const uint8_t *, size_t) = mb_core_screen_input;
static void (*const k_chk_media)(mb_core_media_fn) = mb_core_route_media;

typedef struct test_state {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int started_count;
    int stopped_count;
    int received_count;
    int binary_count;
    int fatal_count;
    int reentrant_sent;
    int target_count;
    _Atomic int stopped_flag;
    _Atomic int post_stop_callbacks;
    double last_ack_call;
    double last_ack_ts;
    size_t last_input_len;
    uint64_t last_media_seq;
} test_state_t;

static test_state_t g_st;

static void drv_on_start(const char *data_dir, const char *cloud_origin, int beta, void *u) {
    test_state_t *st = (test_state_t *)u;
    assert(data_dir != NULL && strcmp(data_dir, "/tmp/pion-core-test") == 0);
    assert(cloud_origin != NULL && strcmp(cloud_origin, "https://app.still.fail") == 0);
    assert(beta == 1);
    pthread_mutex_lock(&st->mu);
    st->started_count += 1;
    pthread_mutex_unlock(&st->mu);
}

static void drv_on_send(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *u) {
    (void)u;
    // Echo message back to host through mb_core_emit on the core thread
    (void)mb_core_emit(json, len, bytes, blen);
}

static void drv_on_stop(void *u) {
    test_state_t *st = (test_state_t *)u;
    pthread_mutex_lock(&st->mu);
    st->stopped_count += 1;
    pthread_mutex_unlock(&st->mu);
}

static int drv_screen_ack(double call, double ts, void *u) {
    test_state_t *st = (test_state_t *)u;
    st->last_ack_call = call;
    st->last_ack_ts = ts;
    return 1;
}

static int drv_screen_input(double call, const uint8_t *json, size_t len, void *u) {
    (void)call;
    (void)json;
    test_state_t *st = (test_state_t *)u;
    st->last_input_len = len;
    return 1;
}

static int media_take_cb(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len) {
    assert(call == 99 && kind == 2 && key == 1 && ts == 123456);
    assert(bytes != NULL && len == 4 && memcmp(bytes, "VP9!", 4) == 0);
    g_st.last_media_seq = seq;
    return 1;
}

static void on_host_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
    test_state_t *st = (test_state_t *)ctx;
    if (atomic_load(&st->stopped_flag)) {
        atomic_fetch_add(&st->post_stop_callbacks, 1);
        return;
    }
    assert(json != NULL && len > 0);
    if (len >= 8 && memcmp(json, "{\"fatal\"", 8) == 0) {
        pthread_mutex_lock(&st->mu);
        st->fatal_count += 1;
        pthread_cond_broadcast(&st->cv);
        pthread_mutex_unlock(&st->mu);
        return;
    }

    int trigger_reentrant = 0;
    pthread_mutex_lock(&st->mu);
    st->received_count += 1;
    if (bytes != NULL && blen == 4 && memcmp(bytes, "BIN!", 4) == 0) {
        st->binary_count += 1;
    }
    if (!st->reentrant_sent) {
        st->reentrant_sent = 1;
        trigger_reentrant = 1;
    }
    if (st->received_count >= st->target_count) {
        pthread_cond_broadcast(&st->cv);
    }
    pthread_mutex_unlock(&st->mu);

    // Re-entrant send from inside `on_message` proves internal lock is NOT held during callback.
    if (trigger_reentrant) {
        static const char ping[] = "{\"id\":9999,\"call\":\"reentrant\"}";
        mb_core_send(ping, sizeof(ping) - 1, NULL, 0);
    }
}

typedef struct producer_arg {
    int tid;
    int count;
} producer_arg_t;

static void *producer_thread(void *arg) {
    producer_arg_t *pa = (producer_arg_t *)arg;
    static const uint8_t bin[4] = {'B', 'I', 'N', '!'};
    char buf[128];
    for (int i = 0; i < pa->count; i++) {
        int n = snprintf(buf, sizeof(buf), "{\"id\":%d,\"call\":\"msg\",\"params\":{\"t\":%d,\"i\":%d}}", pa->tid * 1000 + i, pa->tid, i);
        assert(n > 0);
        if ((i & 1) == 0) {
            mb_core_send(buf, (size_t)n, bin, sizeof(bin));
        } else {
            mb_core_send(buf, (size_t)n, NULL, 0);
        }
    }
    return NULL;
}

int main(void) {
    (void)k_chk_start;
    (void)k_chk_send;
    (void)k_chk_stop;
    (void)k_chk_ack;
    (void)k_chk_input;
    (void)k_chk_media;

    memset(&g_st, 0, sizeof(g_st));
    pthread_mutex_init(&g_st.mu, NULL);
    pthread_cond_init(&g_st.cv, NULL);

    mb_core_driver_t drv = {
        drv_on_start,
        drv_on_send,
        drv_on_stop,
        drv_screen_ack,
        drv_screen_input,
        &g_st,
    };
    mb_core_register_driver(&drv);

    // 1. Multi-threaded start -> 4 producers x 50 msgs + 1 re-entrant msg = 201 messages
    const int n_threads = 4;
    const int per_thread = 50;
    g_st.target_count = n_threads * per_thread + 1;

    mb_core_start("/tmp/pion-core-test", "https://app.still.fail", 1, on_host_message, &g_st);

    pthread_t threads[4];
    producer_arg_t args[4];
    for (int t = 0; t < n_threads; t++) {
        args[t].tid = t + 1;
        args[t].count = per_thread;
        assert(pthread_create(&threads[t], NULL, producer_thread, &args[t]) == 0);
    }
    for (int t = 0; t < n_threads; t++) {
        assert(pthread_join(threads[t], NULL) == 0);
    }

    pthread_mutex_lock(&g_st.mu);
    while (g_st.received_count < g_st.target_count) {
        pthread_cond_wait(&g_st.cv, &g_st.mu);
    }
    pthread_mutex_unlock(&g_st.mu);

    assert(g_st.started_count == 1);
    assert(g_st.received_count == 201);
    assert(g_st.binary_count == 100);

    // 2. screen_ack, screen_input, route_media
    assert(mb_core_screen_ack(42.0, 9001.0) == 1);
    assert(g_st.last_ack_call == 42.0 && g_st.last_ack_ts == 9001.0);

    static const uint8_t inp[] = "{\"type\":\"key\",\"code\":\"Enter\"}";
    assert(mb_core_screen_input(42.0, inp, sizeof(inp) - 1) == 1);
    assert(g_st.last_input_len == sizeof(inp) - 1);

    mb_core_route_media(media_take_cb);
    assert(mb_core_deliver_media(99, 2, 1, 77, 123456, (const uint8_t *)"VP9!", 4) == 1);
    assert(g_st.last_media_seq == 77);
    mb_core_route_media(NULL);
    assert(mb_core_deliver_media(99, 2, 1, 78, 123456, (const uint8_t *)"VP9!", 4) == 0);

    // 3. Stop and verify ZERO callbacks after mb_core_stop returns
    mb_core_stop();
    atomic_store(&g_st.stopped_flag, 1);
    assert(g_st.stopped_count == 1);

    static const char late[] = "{\"id\":5000,\"call\":\"late\"}";
    mb_core_send(late, sizeof(late) - 1, NULL, 0);
    assert(mb_core_emit(late, sizeof(late) - 1, NULL, 0) == 0);
    assert(atomic_load(&g_st.post_stop_callbacks) == 0);

    // 4. Restart with empty data_dir emits {"fatal":...}
    atomic_store(&g_st.stopped_flag, 0);
    mb_core_start("", "https://app.still.fail", 0, on_host_message, &g_st);
    pthread_mutex_lock(&g_st.mu);
    while (g_st.fatal_count < 1) {
        pthread_cond_wait(&g_st.cv, &g_st.mu);
    }
    pthread_mutex_unlock(&g_st.mu);
    mb_core_stop();
    assert(g_st.fatal_count == 1);

    printf("core_abi_test: OK (received=%d, binary=%d, fatal=%d, post_stop_cb=%d)\n",
           g_st.received_count,
           g_st.binary_count,
           g_st.fatal_count,
           atomic_load(&g_st.post_stop_callbacks));
    return 0;
}
