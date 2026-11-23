// Standalone C ABI integration test against the real `apps/mbui/src/host/core_api.h`.
// Verifies:
// 1. 100% compile-time signature match for all 6 `core_api.h` functions.
// 2. Multi-threaded `start -> concurrent send (json + bytes) -> on_message -> stop` with zero races.
// 3. `on_message` is invoked without holding internal mutex (re-entrant `mb_core_send` does not deadlock).
// 4. `mb_core_screen_ack`, `mb_core_screen_input`, and `mb_core_route_media` dispatch cleanly.
// 5. Zero callbacks after `mb_core_stop` returns, and clean restart cycle.
// 6. Native wake loop (`mb_core_register_wake` / `mb_core_wake`) with no `mb_core_send` at all:
//    async wake, timer wake, a concurrent wake storm with no lost wakeup, and stop during a long timer.
// 7. Lifecycle races: concurrent `mb_core_stop` calls, `mb_core_start` during a stop, a message flood
//    that must not starve a due timer, and unregistering `on_wake` while it runs (no use after free).

#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

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

typedef int64_t (*mb_core_driver_wake_fn)(void *);
extern void mb_core_register_wake(mb_core_driver_wake_fn on_wake, void *user_ctx);
extern void mb_core_wake(void);

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

// ── Native wake loop tests ──

enum {
    WAKE_ASYNC = 1,
    WAKE_TIMER = 2,
    WAKE_STORM = 3,
    WAKE_LONG = 4,
    WAKE_AFTER_SEND = 5,
    WAKE_STOP_GATE = 6,
    WAKE_FLOOD = 7,
    WAKE_ZERO = 8,
    WAKE_STOP_SELF = 9,
    WAKE_STORM_SLOW = 10,
    WAKE_SEND_TIMER = 11,
};

typedef struct wake_state {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int mode;
    int calls;
    int pushes;
    int want_timer;
    int timer_armed;
    int in_stop;
    int start_attempted;
    int zero_run;
    int zero_run_most;
    int zero_sends_seen;
    int zero_done_calls;
    _Atomic int zero_issued;
    int64_t send_timer_asked_ns;
    int64_t flood_armed_ns;
    int64_t flood_fired_ns;
    long observed_seq;
    int64_t push_ns;
    _Atomic int64_t woke_ns;
    _Atomic long storm_seq;
    _Atomic int sends;
    _Atomic int stop_calls;
    _Atomic int flood_fired;
    _Atomic int flood_issued;
    int flood_backlog_at_fire;
    _Atomic int stopped_flag;
    _Atomic int post_stop_messages;
} wake_state_t;

static wake_state_t g_ws;

static int64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

static void sleep_ms(long ms) {
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) != 0) {
    }
}

#define FLOOD_BACKLOG 2000

static void ws_on_start(const char *data_dir, const char *cloud_origin, int beta, void *u) {
    (void)data_dir;
    (void)cloud_origin;
    (void)beta;
    wake_state_t *ws = (wake_state_t *)u;
    pthread_mutex_lock(&ws->mu);
    int flood = ws->mode == WAKE_FLOOD || ws->mode == WAKE_SEND_TIMER;
    pthread_mutex_unlock(&ws->mu);
    if (flood) {
        // The first `on_wake` (right after this) arms the timer: hold it until the flood is queued, so
        // the timer is due with messages waiting however late the producer thread gets scheduled.
        int64_t give_up = now_ns() + 3000000000LL;
        while (atomic_load(&ws->flood_issued) < FLOOD_BACKLOG && now_ns() < give_up) {
            sched_yield();
        }
    }
}

static void ws_on_send(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *u) {
    (void)json;
    (void)len;
    (void)bytes;
    (void)blen;
    wake_state_t *ws = (wake_state_t *)u;
    atomic_fetch_add(&ws->sends, 1);
    pthread_mutex_lock(&ws->mu);
    int flood = ws->mode == WAKE_FLOOD || ws->mode == WAKE_SEND_TIMER;
    if (ws->mode == WAKE_SEND_TIMER && ws->send_timer_asked_ns == 0) {
        // The first flood message schedules a 40 ms timer (like a request timeout), without
        // `mb_core_wake()`: the core must ask `on_wake` for it although the queue never drains.
        ws->want_timer = 1;
        ws->send_timer_asked_ns = now_ns();
    }
    int stop_self = ws->mode == WAKE_STOP_SELF;
    if (ws->mode == WAKE_ZERO) {
        // Most `on_wake` calls made while a message was queued, between two messages.
        if (ws->zero_run > ws->zero_run_most) {
            ws->zero_run_most = ws->zero_run;
        }
        ws->zero_run = 0;
        ws->zero_sends_seen += 1;
    }
    pthread_cond_broadcast(&ws->cv);
    pthread_mutex_unlock(&ws->mu);
    if (stop_self) {
        mb_core_stop();
    }
    if (flood) {
        // Each flood message costs 200 us of core time.
        int64_t until = now_ns() + 200000;
        while (now_ns() < until) {
        }
        return;
    }
    // Like a real driver whose request scheduled a timeout: note it, never call `mb_core_wake()`.
    pthread_mutex_lock(&ws->mu);
    ws->want_timer = 1;
    pthread_mutex_unlock(&ws->mu);
}

static void ws_on_stop(void *u) {
    wake_state_t *ws = (wake_state_t *)u;
    atomic_fetch_add(&ws->stop_calls, 1);
    pthread_mutex_lock(&ws->mu);
    if (ws->mode == WAKE_STOP_GATE) {
        // Hold this stop open until another thread is about to call `mb_core_start`.
        ws->in_stop = 1;
        pthread_cond_broadcast(&ws->cv);
        while (!ws->start_attempted) {
            pthread_cond_wait(&ws->cv, &ws->mu);
        }
        pthread_mutex_unlock(&ws->mu);
        sleep_ms(10);
        return;
    }
    pthread_mutex_unlock(&ws->mu);
}

static int64_t ws_on_wake(void *u) {
    wake_state_t *ws = (wake_state_t *)u;
    static const char async_push[] = "{\"push\":\"async\"}";
    static const char timer_push[] = "{\"push\":\"timer\"}";
    pthread_mutex_lock(&ws->mu);
    ws->calls += 1;
    int calls = ws->calls;
    int mode = ws->mode;
    int arm_timer = 0;
    int timer_due = 0;
    if (mode == WAKE_AFTER_SEND) {
        if (ws->timer_armed) {
            ws->timer_armed = 0;
            timer_due = 1;
        } else if (ws->want_timer) {
            ws->want_timer = 0;
            ws->timer_armed = 1;
            arm_timer = 1;
        }
    }
    if (mode == WAKE_STORM) {
        long seq = atomic_load(&ws->storm_seq);
        if (seq > ws->observed_seq) {
            ws->observed_seq = seq;
        }
    }
    pthread_cond_broadcast(&ws->cv);
    pthread_mutex_unlock(&ws->mu);

    switch (mode) {
    case WAKE_ASYNC:
        if (calls > 1) {
            (void)mb_core_emit(async_push, sizeof(async_push) - 1, NULL, 0);
        }
        return -1;
    case WAKE_TIMER:
        if (calls == 1) {
            return 40;
        }
        (void)mb_core_emit(timer_push, sizeof(timer_push) - 1, NULL, 0);
        return -1;
    case WAKE_LONG:
        return 60000;
    case WAKE_STORM_SLOW: {
        // Each callout costs 100 us, so the storm always has a new wake pending when it returns.
        int64_t until = now_ns() + 100000;
        while (now_ns() < until) {
        }
        return -1;
    }
    case WAKE_ZERO: {
        // Asks to run again at once until all 20 messages are handled. `zero_issued` counts messages
        // whose `mb_core_send` returned, so more of them than handled means one is queued now.
        pthread_mutex_lock(&ws->mu);
        if (atomic_load(&ws->zero_issued) > ws->zero_sends_seen) {
            ws->zero_run += 1;
        }
        int done = ws->zero_sends_seen >= 20;
        if (done) {
            ws->zero_done_calls += 1;
            pthread_cond_broadcast(&ws->cv);
        }
        pthread_mutex_unlock(&ws->mu);
        return done ? -1 : 0;
    }
    case WAKE_SEND_TIMER: {
        pthread_mutex_lock(&ws->mu);
        int64_t now = now_ns();
        int64_t delay = -1;
        if (ws->want_timer && ws->flood_armed_ns == 0) {
            ws->flood_armed_ns = now;
            delay = 40;
        } else if (ws->flood_armed_ns != 0 && ws->flood_fired_ns == 0) {
            int64_t left_ns = ws->flood_armed_ns + 40000000LL - now;
            if (left_ns <= 0) {
                ws->flood_fired_ns = now;
                ws->flood_backlog_at_fire = atomic_load(&ws->flood_issued) - atomic_load(&ws->sends);
                atomic_store(&ws->flood_fired, 1);
                pthread_cond_broadcast(&ws->cv);
            } else {
                delay = (left_ns + 999999) / 1000000;
            }
        }
        pthread_mutex_unlock(&ws->mu);
        return delay;
    }
    case WAKE_FLOOD: {
        pthread_mutex_lock(&ws->mu);
        int64_t now = now_ns();
        int64_t delay = -1;
        if (ws->flood_armed_ns == 0) {
            ws->flood_armed_ns = now;
            delay = 50;
        } else if (ws->flood_fired_ns == 0) {
            int64_t left_ns = ws->flood_armed_ns + 50000000LL - now;
            if (left_ns <= 0) {
                ws->flood_fired_ns = now;
                ws->flood_backlog_at_fire = atomic_load(&ws->flood_issued) - atomic_load(&ws->sends);
                atomic_store(&ws->flood_fired, 1);
                pthread_cond_broadcast(&ws->cv);
            } else {
                delay = (left_ns + 999999) / 1000000;
            }
        }
        pthread_mutex_unlock(&ws->mu);
        return delay;
    }
    case WAKE_AFTER_SEND:
        if (arm_timer) {
            return 40;
        }
        if (timer_due) {
            (void)mb_core_emit(timer_push, sizeof(timer_push) - 1, NULL, 0);
        }
        return -1;
    default:
        return -1;
    }
}

static void ws_on_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
    (void)bytes;
    (void)blen;
    wake_state_t *ws = (wake_state_t *)ctx;
    if (atomic_load(&ws->stopped_flag)) {
        atomic_fetch_add(&ws->post_stop_messages, 1);
        return;
    }
    assert(json != NULL && len > 0);
    pthread_mutex_lock(&ws->mu);
    ws->pushes += 1;
    ws->push_ns = now_ns();
    pthread_cond_broadcast(&ws->cv);
    pthread_mutex_unlock(&ws->mu);
}

// Waits (holding `ws->mu`) until `*field >= want`; returns 0 on timeout.
static int ws_wait_at_least(wake_state_t *ws, const int *field, int want, long timeout_ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += timeout_ms / 1000;
    until.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
        until.tv_sec += 1;
        until.tv_nsec -= 1000000000L;
    }
    while (*field < want) {
        if (pthread_cond_timedwait(&ws->cv, &ws->mu, &until) != 0 && *field < want) {
            return 0;
        }
    }
    return 1;
}

static void ws_begin(int mode) {
    pthread_mutex_lock(&g_ws.mu);
    g_ws.mode = mode;
    g_ws.calls = 0;
    g_ws.pushes = 0;
    g_ws.want_timer = 0;
    g_ws.timer_armed = 0;
    g_ws.in_stop = 0;
    g_ws.start_attempted = 0;
    g_ws.zero_run = 0;
    g_ws.zero_run_most = 0;
    g_ws.zero_sends_seen = 0;
    g_ws.zero_done_calls = 0;
    atomic_store(&g_ws.zero_issued, 0);
    g_ws.send_timer_asked_ns = 0;
    g_ws.flood_armed_ns = 0;
    g_ws.flood_fired_ns = 0;
    atomic_store(&g_ws.flood_fired, 0);
    atomic_store(&g_ws.flood_issued, 0);
    g_ws.flood_backlog_at_fire = 0;
    g_ws.observed_seq = 0;
    g_ws.push_ns = 0;
    pthread_mutex_unlock(&g_ws.mu);
    atomic_store(&g_ws.woke_ns, 0);
    atomic_store(&g_ws.storm_seq, 0);
    atomic_store(&g_ws.sends, 0);
    atomic_store(&g_ws.stopped_flag, 0);
    atomic_store(&g_ws.post_stop_messages, 0);
    mb_core_start("/tmp/pion-core-wake", "https://app.still.fail", 0, ws_on_message, &g_ws);
}

static void ws_end_sent(int sends) {
    mb_core_stop();
    atomic_store(&g_ws.stopped_flag, 1);
    mb_core_wake();
    assert(mb_core_emit("{}", 2, NULL, 0) == 0);
    assert(atomic_load(&g_ws.post_stop_messages) == 0);
    assert(sends < 0 || atomic_load(&g_ws.sends) == sends);
}

static void ws_end(void) {
    ws_end_sent(0);
}

static void *concurrent_stopper(void *arg) {
    (void)arg;
    mb_core_stop();
    return NULL;
}

static void *start_during_stop(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_ws.mu);
    while (!g_ws.in_stop) {
        pthread_cond_wait(&g_ws.cv, &g_ws.mu);
    }
    g_ws.mode = WAKE_ASYNC;
    g_ws.start_attempted = 1;
    pthread_cond_broadcast(&g_ws.cv);
    pthread_mutex_unlock(&g_ws.mu);
    mb_core_start("/tmp/pion-core-wake", "https://app.still.fail", 0, ws_on_message, &g_ws);
    return NULL;
}

static void *flood_sender(void *arg) {
    (void)arg;
    static const char msg[] = "{\"id\":2,\"call\":\"flood\"}";
    int64_t give_up = now_ns() + 3000000000LL;
    // Keeps up to FLOOD_BACKLOG messages (400 ms of core work) queued, so the queue does not drain even
    // when this thread is descheduled for a while.
    while (!atomic_load(&g_ws.flood_fired) && now_ns() < give_up) {
        if (atomic_load(&g_ws.flood_issued) - atomic_load(&g_ws.sends) < FLOOD_BACKLOG) {
            atomic_fetch_add(&g_ws.flood_issued, 1);
            mb_core_send(msg, sizeof(msg) - 1, NULL, 0);
        } else {
            sched_yield();
        }
    }
    return NULL;
}

typedef struct wake_block {
    _Atomic int returned;
    int touched;
} wake_block_t;

// Runs 30 ms, then writes its heap `ctx`; unregistering meanwhile must wait for it.
static int64_t blocking_wake(void *u) {
    wake_block_t *blk = (wake_block_t *)u;
    pthread_mutex_lock(&g_ws.mu);
    g_ws.calls += 1;
    pthread_cond_broadcast(&g_ws.cv);
    pthread_mutex_unlock(&g_ws.mu);
    sleep_ms(30);
    blk->touched = 1;
    atomic_store(&blk->returned, 1);
    return 10;
}

// Unregisters itself from inside `on_wake` (on the core worker): must not wait for itself.
static int64_t self_unregister_wake(void *u) {
    (void)u;
    mb_core_register_wake(NULL, NULL);
    pthread_mutex_lock(&g_ws.mu);
    g_ws.calls += 1;
    pthread_cond_broadcast(&g_ws.cv);
    pthread_mutex_unlock(&g_ws.mu);
    return 5;
}

static _Atomic int g_storm_on = 0;

static void *wake_stormer(void *arg) {
    (void)arg;
    int64_t give_up = now_ns() + 3000000000LL;
    while (atomic_load(&g_storm_on) && now_ns() < give_up) {
        mb_core_wake();
    }
    return NULL;
}

// Waits until `on_send` has run `want` times; returns 0 after `timeout_ms`.
static int ws_wait_sends(int want, long timeout_ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += timeout_ms / 1000;
    until.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
        until.tv_sec += 1;
        until.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&g_ws.mu);
    while (atomic_load(&g_ws.sends) < want) {
        if (pthread_cond_timedwait(&g_ws.cv, &g_ws.mu, &until) != 0 && atomic_load(&g_ws.sends) < want) {
            pthread_mutex_unlock(&g_ws.mu);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_ws.mu);
    return 1;
}

static void send_ui_messages(int n) {
    static const char msg[] = "{\"id\":3,\"call\":\"ui\"}";
    for (int i = 0; i < n; i++) {
        mb_core_send(msg, sizeof(msg) - 1, NULL, 0);
    }
}

static void *async_waker(void *arg) {
    (void)arg;
    sleep_ms(30);
    atomic_store(&g_ws.woke_ns, now_ns());
    mb_core_wake();
    return NULL;
}

static void *storm_waker(void *arg) {
    int n = *(const int *)arg;
    for (int i = 0; i < n; i++) {
        atomic_fetch_add(&g_ws.storm_seq, 1);
        mb_core_wake();
    }
    return NULL;
}

static void run_wake_tests(void) {
    pthread_mutex_init(&g_ws.mu, NULL);
    pthread_cond_init(&g_ws.cv, NULL);
    mb_core_driver_t drv = {ws_on_start, ws_on_send, ws_on_stop, NULL, NULL, &g_ws};
    mb_core_register_driver(&drv);
    mb_core_register_wake(ws_on_wake, &g_ws);

    // Case 1: UI fully idle; a background thread's `mb_core_wake()` makes `on_wake` push an event.
    ws_begin(WAKE_ASYNC);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    int64_t t0 = now_ns();
    pthread_t waker;
    assert(pthread_create(&waker, NULL, async_waker, NULL) == 0);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.pushes, 1, 1000));
    // Latency from the `mb_core_wake()` call itself to the pushed event (excludes the waker's own
    // sleep, whose length is up to the OS scheduler).
    int64_t async_ms = (g_ws.push_ns - atomic_load(&g_ws.woke_ns)) / 1000000;
    int64_t since_start_ms = (g_ws.push_ns - t0) / 1000000;
    assert(g_ws.calls == 2);
    pthread_mutex_unlock(&g_ws.mu);
    assert(pthread_join(waker, NULL) == 0);
    assert(since_start_ms >= 30 && async_ms >= 0 && async_ms < 200);
    ws_end();

    // Case 2: UI fully idle, no `mb_core_wake()`; the 40 ms timer from the first `on_wake` fires,
    // pushes, and returns -1, after which the worker stays asleep.
    int64_t t1 = now_ns();
    ws_begin(WAKE_TIMER);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.pushes, 1, 1000));
    int64_t timer_ms = (g_ws.push_ns - t1) / 1000000;
    assert(g_ws.calls == 2);
    // Nothing is due any more: no further `on_wake` within 100 ms.
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, 3, 100));
    assert(g_ws.calls == 2 && g_ws.pushes == 1);
    pthread_mutex_unlock(&g_ws.mu);
    // Never early; the upper bound only rules out a missed timer (OS timer slack on a loaded host
    // alone can exceed 100 ms).
    assert(timer_ms >= 40 && timer_ms < 1000);
    ws_end();

    // Case 3: 4 threads x 50 concurrent `mb_core_wake()` calls; some `on_wake` after the last
    // call must observe the final shared state (no lost wakeup), coalescing is allowed.
    ws_begin(WAKE_STORM);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    enum { STORM_THREADS = 4, STORM_EACH = 50 };
    pthread_t storm[STORM_THREADS];
    int each = STORM_EACH;
    for (int i = 0; i < STORM_THREADS; i++) {
        assert(pthread_create(&storm[i], NULL, storm_waker, &each) == 0);
    }
    for (int i = 0; i < STORM_THREADS; i++) {
        assert(pthread_join(storm[i], NULL) == 0);
    }
    assert(atomic_load(&g_ws.storm_seq) == STORM_THREADS * STORM_EACH);
    pthread_mutex_lock(&g_ws.mu);
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 1;
    while (g_ws.observed_seq < STORM_THREADS * STORM_EACH) {
        if (pthread_cond_timedwait(&g_ws.cv, &g_ws.mu, &until) != 0) {
            break;
        }
    }
    long observed = g_ws.observed_seq;
    int storm_calls = g_ws.calls;
    pthread_mutex_unlock(&g_ws.mu);
    assert(observed == STORM_THREADS * STORM_EACH);
    assert(storm_calls >= 2 && storm_calls <= 1 + STORM_THREADS * STORM_EACH);
    ws_end();

    // Case 4: `on_wake` arms a 60 s timer; `mb_core_stop()` 20 ms later returns at once.
    ws_begin(WAKE_LONG);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    sleep_ms(20);
    int64_t t2 = now_ns();
    ws_end();
    int64_t stop_ms = (now_ns() - t2) / 1000000;
    pthread_mutex_lock(&g_ws.mu);
    assert(g_ws.calls == 1 && g_ws.pushes == 0);
    pthread_mutex_unlock(&g_ws.mu);
    assert(stop_ms < 200);

    // Case 5: one `mb_core_send`, then the UI is idle. `on_send` only notes it needs a 40 ms timer;
    // the worker asks `on_wake` after draining the queue, gets 40, and the timer pushes the event.
    ws_begin(WAKE_AFTER_SEND);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    int64_t t3 = now_ns();
    static const char req[] = "{\"id\":1,\"call\":\"chat.open\"}";
    mb_core_send(req, sizeof(req) - 1, NULL, 0);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.pushes, 1, 1000));
    int64_t send_timer_ms = (g_ws.push_ns - t3) / 1000000;
    assert(g_ws.calls == 3 && g_ws.pushes == 1);
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, 4, 100));
    pthread_mutex_unlock(&g_ws.mu);
    assert(send_timer_ms >= 40 && send_timer_ms < 1000);
    ws_end_sent(1);

    // Case 6: `on_wake` registered while the core runs is called at once; unregistering clears it.
    mb_core_register_wake(NULL, NULL);
    ws_begin(WAKE_LONG);
    mb_core_register_wake(ws_on_wake, &g_ws);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    mb_core_register_wake(NULL, NULL);
    mb_core_wake();
    pthread_mutex_lock(&g_ws.mu);
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, 2, 100));
    pthread_mutex_unlock(&g_ws.mu);
    ws_end();

    // Case 7: two threads call `mb_core_stop()` at once, 200 start/stop rounds: one join, one
    // `on_stop` per round, never a hang.
    mb_core_register_wake(ws_on_wake, &g_ws);
    atomic_store(&g_ws.stop_calls, 0);
    for (int round = 0; round < 200; round++) {
        ws_begin(WAKE_ASYNC);
        pthread_t stoppers[2];
        for (int i = 0; i < 2; i++) {
            assert(pthread_create(&stoppers[i], NULL, concurrent_stopper, NULL) == 0);
        }
        for (int i = 0; i < 2; i++) {
            assert(pthread_join(stoppers[i], NULL) == 0);
        }
        assert(atomic_load(&g_ws.stop_calls) == round + 1);
        assert(mb_core_emit("{}", 2, NULL, 0) == 0);
    }

    // Case 8: `mb_core_start()` while a stop is under way is not dropped: it starts after the stop.
    ws_begin(WAKE_STOP_GATE);
    pthread_t restarter;
    assert(pthread_create(&restarter, NULL, start_during_stop, NULL) == 0);
    mb_core_stop();
    assert(pthread_join(restarter, NULL) == 0);
    static const char alive[] = "{\"alive\":1}";
    assert(mb_core_emit(alive, sizeof(alive) - 1, NULL, 0) == 1);
    ws_end();

    // Case 9: a standing message flood must not starve a due 50 ms timer: it fires on time while
    // messages are still queued.
    ws_begin(WAKE_FLOOD);
    pthread_t flooder;
    assert(pthread_create(&flooder, NULL, flood_sender, NULL) == 0);
    pthread_mutex_lock(&g_ws.mu);
    struct timespec flood_until;
    clock_gettime(CLOCK_REALTIME, &flood_until);
    flood_until.tv_sec += 3;
    while (g_ws.flood_fired_ns == 0) {
        if (pthread_cond_timedwait(&g_ws.cv, &g_ws.mu, &flood_until) != 0) {
            break;
        }
    }
    int64_t flood_ms = g_ws.flood_fired_ns != 0 ? (g_ws.flood_fired_ns - g_ws.flood_armed_ns) / 1000000 : -1;
    int flood_backlog = g_ws.flood_backlog_at_fire;
    pthread_mutex_unlock(&g_ws.mu);
    assert(pthread_join(flooder, NULL) == 0);
    int flood_sends = atomic_load(&g_ws.sends);
    if (!(flood_ms >= 50 && flood_ms < 1000 && flood_backlog > 0)) {
        fprintf(stderr, "flood: timer=%lldms backlog_at_fire=%d sends=%d\n", (long long)flood_ms, flood_backlog, flood_sends);
    }
    assert(flood_ms >= 50 && flood_ms < 1000 && flood_backlog > 0);
    ws_end_sent(-1);

    // Case 10: unregistering from another thread waits for a running `on_wake`, so its ctx can be
    // freed at once (ASan catches a use after free); a delay it returns afterwards is dropped.
    mb_core_register_wake(NULL, NULL);
    ws_begin(WAKE_LONG);
    wake_block_t *blk = (wake_block_t *)calloc(1, sizeof(*blk));
    assert(blk != NULL);
    mb_core_register_wake(blocking_wake, blk);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    mb_core_register_wake(NULL, NULL);
    assert(atomic_load(&blk->returned) == 1 && blk->touched == 1);
    free(blk);
    pthread_mutex_lock(&g_ws.mu);
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, 2, 100));
    pthread_mutex_unlock(&g_ws.mu);
    ws_end();

    // Case 11: `on_wake` unregistering itself on the core worker does not deadlock.
    ws_begin(WAKE_LONG);
    mb_core_register_wake(self_unregister_wake, NULL);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, 2, 100));
    pthread_mutex_unlock(&g_ws.mu);
    ws_end();

    mb_core_register_wake(ws_on_wake, &g_ws);

    // Case 15: during a standing flood, a timer the first `on_send` schedules (no `mb_core_wake()`) is
    // registered within `CORE_SEND_BURST_CAP` messages and fires on time with messages still queued.
    ws_begin(WAKE_SEND_TIMER);
    pthread_t flooder15;
    assert(pthread_create(&flooder15, NULL, flood_sender, NULL) == 0);
    pthread_mutex_lock(&g_ws.mu);
    struct timespec until15;
    clock_gettime(CLOCK_REALTIME, &until15);
    until15.tv_sec += 3;
    while (g_ws.flood_fired_ns == 0) {
        if (pthread_cond_timedwait(&g_ws.cv, &g_ws.mu, &until15) != 0) {
            break;
        }
    }
    int64_t send_timer_fired_ms =
        g_ws.flood_fired_ns != 0 ? (g_ws.flood_fired_ns - g_ws.send_timer_asked_ns) / 1000000 : -1;
    int64_t send_timer_armed_ms =
        g_ws.flood_armed_ns != 0 ? (g_ws.flood_armed_ns - g_ws.send_timer_asked_ns) / 1000000 : -1;
    int send_timer_backlog = g_ws.flood_backlog_at_fire;
    pthread_mutex_unlock(&g_ws.mu);
    assert(pthread_join(flooder15, NULL) == 0);
    // Bursts still coalesce: about one `on_wake` per 16 messages (plus the timer's own), not one each.
    pthread_mutex_lock(&g_ws.mu);
    int send_timer_calls = g_ws.calls;
    pthread_mutex_unlock(&g_ws.mu);
    int send_timer_sends = atomic_load(&g_ws.sends);
    assert(send_timer_calls <= send_timer_sends / 8 + 10);
    if (!(send_timer_fired_ms >= 40 && send_timer_fired_ms < 1000 && send_timer_backlog > 0)) {
        fprintf(stderr, "send-timer: armed=%lldms fired=%lldms backlog_at_fire=%d\n", (long long)send_timer_armed_ms,
                (long long)send_timer_fired_ms, send_timer_backlog);
    }
    assert(send_timer_armed_ms >= 0 && send_timer_fired_ms >= 40 && send_timer_fired_ms < 1000 && send_timer_backlog > 0);
    ws_end_sent(-1);

    // Case 12: a `mb_core_wake()` storm from another thread does not starve UI messages: all 20 are
    // handled while it goes on.
    ws_begin(WAKE_STORM_SLOW);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 1, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    atomic_store(&g_storm_on, 1);
    pthread_t stormer;
    assert(pthread_create(&stormer, NULL, wake_stormer, NULL) == 0);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 50, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    int64_t t12 = now_ns();
    send_ui_messages(20);
    int storm_sends_ok = ws_wait_sends(20, 1000);
    int64_t storm_ui_ms = (now_ns() - t12) / 1000000;
    int storm_still_on = atomic_load(&g_storm_on);
    atomic_store(&g_storm_on, 0);
    assert(pthread_join(stormer, NULL) == 0);
    assert(storm_sends_ok && storm_still_on);
    ws_end_sent(20);

    // Case 13: `on_wake` returning 0 (run again at once) alternates with UI messages: all 20 are
    // handled with at most one `on_wake` between two of them, then it sleeps.
    ws_begin(WAKE_ZERO);
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.calls, 50, 1000));
    pthread_mutex_unlock(&g_ws.mu);
    int64_t t13 = now_ns();
    static const char zmsg[] = "{\"id\":4,\"call\":\"ui\"}";
    for (int i = 0; i < 20; i++) {
        mb_core_send(zmsg, sizeof(zmsg) - 1, NULL, 0);
        atomic_fetch_add(&g_ws.zero_issued, 1);
    }
    pthread_mutex_lock(&g_ws.mu);
    assert(ws_wait_at_least(&g_ws, &g_ws.zero_sends_seen, 20, 1000));
    int64_t zero_ui_ms = (now_ns() - t13) / 1000000;
    // The `on_wake` after the last message returns -1, and then nothing more is due.
    assert(ws_wait_at_least(&g_ws, &g_ws.zero_done_calls, 1, 1000));
    int zero_calls = g_ws.calls;
    assert(!ws_wait_at_least(&g_ws, &g_ws.calls, zero_calls + 1, 100));
    int zero_between = g_ws.zero_run_most;
    int zero_done = g_ws.zero_done_calls;
    pthread_mutex_unlock(&g_ws.mu);
    assert(zero_between <= 1 && zero_done == 1);
    ws_end_sent(20);

    // Case 14: `mb_core_stop()` from the core worker (inside `on_send`) aborts instead of joining
    // itself. Runs in a child process.
    fflush(NULL);
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        // Keep the expected abort message out of the test output.
        (void)freopen("/dev/null", "w", stderr);
        ws_begin(WAKE_STOP_SELF);
        send_ui_messages(1);
        sleep_ms(5000);
        _exit(0);
    }
    int child_status = 0;
    assert(waitpid(child, &child_status, 0) == child);
    assert(WIFSIGNALED(child_status) && WTERMSIG(child_status) == SIGABRT);

    mb_core_register_wake(NULL, NULL);
    mb_core_register_driver(NULL);
    printf("core_abi_test: fairness OK (storm: 20 ui in %lldms; zero-delay: 20 ui in %lldms, <=%d on_wake between; "
           "send-timer in flood: armed %lldms, fired %lldms with %d queued, %d on_wake for %d messages; "
           "self-stop aborts)\n",
           (long long)storm_ui_ms,
           (long long)zero_ui_ms,
           zero_between,
           (long long)send_timer_armed_ms,
           (long long)send_timer_fired_ms,
           send_timer_backlog,
           send_timer_calls,
           send_timer_sends);
    printf("core_abi_test: lifecycle OK (stop_rounds=200, flood_timer=%lldms with %d queued, %d handled)\n",
           (long long)flood_ms,
           flood_backlog,
           flood_sends);
    printf("core_abi_test: wake OK (send_timer=%lldms, async=%lldms after wake, %lldms after start; timer=%lldms, storm_calls=%d, stop=%lldms, post_stop_messages=%d)\n",
           (long long)send_timer_ms,
           (long long)async_ms,
           (long long)since_start_ms,
           (long long)timer_ms,
           storm_calls,
           (long long)stop_ms,
           atomic_load(&g_ws.post_stop_messages));
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

    run_wake_tests();
    return 0;
}
