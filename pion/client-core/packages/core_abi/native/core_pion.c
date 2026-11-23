// Thin removable C ABI bridge implementing all 6 functions of `apps/mbui/src/host/core_api.h`
// for `pion/client-core`.
//
// Threading & lifecycle invariants:
// - `mb_core_send` copies JSON + optional bytes onto a FIFO queue and returns immediately (never blocks UI).
// - The dedicated core worker thread drains the queue and invokes the registered driver with the mutex unlocked.
// - `on_message` is NEVER invoked while holding the internal mutex (safe against re-entrant `mb_core_send`).
// - `mb_core_stop` signals shutdown, joins the core worker thread, waits for any in-flight `mb_core_emit`,
//   and clears callbacks; NO `on_message` callback can fire after `mb_core_stop` returns. Concurrent
//   `mb_core_stop` calls join once: later callers wait for the first to finish. Calling it from the
//   core worker (inside a driver callback) aborts. `mb_core_start` during
//   a stop waits for it to finish and then starts.
// - The worker sleeps only when nothing is due: no queued message, no pending `mb_core_wake`, and no
//   timer deadline reached. It is woken by `mb_core_send`, `mb_core_wake`, its timer deadline, or
//   `mb_core_stop`, and never polls.

#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <time.h>
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

// ── Native wake slot (separate from `mb_core_driver_t`, whose 6-field layout older bridges declare) ──
//
// `on_wake` runs on the core worker thread with the internal mutex unlocked, so it may call
// `mb_core_emit`, `mb_core_send` and `mb_core_wake`. It runs:
// - once right after `on_start`, so the driver can arm its first timer;
// - after any `mb_core_wake()` call made since the previous `on_wake` began (calls made while it
//   runs are never lost: the pending flag is cleared before it is invoked);
// - once the queue drains after `on_send` handled messages (one call per burst), since `on_send`
//   may have scheduled new timers;
// - when registered while the core runs;
// - when the delay it last returned has elapsed.
// A due timer or a pending `mb_core_wake()` (or registration, or the first call) alternates 1:1 with
// queued messages: at most one message runs before it, and at most one `on_wake` runs before the next
// message, so neither a message flood nor a wake storm (or `on_wake` returning 0) starves the other.
// The after-`on_send` call waits for the queue to drain, coalescing a burst into one call, but at most
// `CORE_SEND_BURST_CAP` messages: then it takes its turn too, so timers `on_send` schedules during an
// endless flood still get registered.
// `mb_core_register_wake` replaces the slot; called from any thread but the core worker, it returns
// only after an `on_wake` already running has returned, so the old `user_ctx` can then be freed.
// A delay returned by an `on_wake` that was replaced meanwhile is dropped.
// Its return value is a RELATIVE delay in milliseconds from when it returns (no shared clock base):
// - `< 0`: no timer; sleep until the next message, `mb_core_wake()` or `mb_core_stop()`;
// - `0`: run `on_wake` again right away (alternating with queued messages, one message first);
// - `> 0`: run `on_wake` again after that many milliseconds (measured on a monotonic clock) unless
//   something wakes it earlier; each `on_wake` return replaces the previous deadline.
typedef int64_t (*mb_core_driver_wake_fn)(void *user_ctx);

void mb_core_register_wake(mb_core_driver_wake_fn on_wake, void *user_ctx);
void mb_core_wake(void);
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
// Initialized by `ensure_cond_init` (on a monotonic clock where `pthread_cond_timedwait` allows it).
static pthread_cond_t g_cond;
static pthread_once_t g_cond_once = PTHREAD_ONCE_INIT;
static pthread_cond_t g_ready_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_emit_done = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_stopped_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_wake_done = PTHREAD_COND_INITIALIZER;

static int g_started = 0;
static int g_ready = 0;
static int g_stopping = 0;
static int g_in_flight_emits = 0;
// Counts finished stops, so a concurrent `mb_core_stop` waits for the stop it saw, not a later one.
static uint64_t g_stops_done = 0;
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

static mb_core_driver_wake_fn g_wake_fn = NULL;
static void *g_wake_ctx = NULL;
// Set by `mb_core_wake`, registration and start: runs `on_wake` in turn with queued messages.
static int g_wake_pending = 0;
// Set after `on_send`: runs `on_wake` once the queue has drained.
static int g_sent_wake_pending = 0;
static int g_has_deadline = 0;
static int64_t g_deadline_ns = 0;
static int g_in_flight_wake = 0;

static void init_cond_once(void) {
    pthread_condattr_t attr;
    if (pthread_condattr_init(&attr) != 0) {
        abort();
    }
#if !defined(__APPLE__)
    // Deadlines are on `CLOCK_MONOTONIC`, so wall-clock changes never stretch a timed wait.
    if (pthread_condattr_setclock(&attr, CLOCK_MONOTONIC) != 0) {
        abort();
    }
#endif
    if (pthread_cond_init(&g_cond, &attr) != 0) {
        abort();
    }
    (void)pthread_condattr_destroy(&attr);
}

static void ensure_cond_init(void) {
    (void)pthread_once(&g_cond_once, init_cond_once);
}

// Messages handled before an after-`on_send` `on_wake` runs even though the queue is not empty.
#define CORE_SEND_BURST_CAP 16

// Delays beyond this (about 100 years) are clamped so deadline arithmetic never overflows.
#define CORE_WAKE_DELAY_MOST_MS ((int64_t)3155760000000LL)

static int64_t mono_now_ns(void) {
    struct timespec ts;
    (void)clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + (int64_t)ts.tv_nsec;
}

// Waits on `g_cond` (holding `g_lock`) until the monotonic `deadline_ns`, `now_ns` being earlier.
// Callers re-check every condition afterwards, so spurious wakeups only cause one more loop round.
static void timed_wait_locked(int64_t deadline_ns, int64_t now_ns) {
    struct timespec ts;
#if defined(__APPLE__)
    int64_t rem_ns = deadline_ns - now_ns;
    ts.tv_sec = (time_t)(rem_ns / 1000000000LL);
    ts.tv_nsec = (long)(rem_ns % 1000000000LL);
    (void)pthread_cond_timedwait_relative_np(&g_cond, &g_lock, &ts);
#else
    (void)now_ns;
    ts.tv_sec = (time_t)(deadline_ns / 1000000000LL);
    ts.tv_nsec = (long)(deadline_ns % 1000000000LL);
    (void)pthread_cond_timedwait(&g_cond, &g_lock, &ts);
#endif
}

// Records the delay `on_wake` returned (see the contract above). Holds `g_lock`.
static void arm_wake_locked(int64_t delay_ms) {
    if (delay_ms < 0) {
        g_has_deadline = 0;
        return;
    }
    if (delay_ms > CORE_WAKE_DELAY_MOST_MS) {
        delay_ms = CORE_WAKE_DELAY_MOST_MS;
    }
    g_has_deadline = 1;
    g_deadline_ns = mono_now_ns() + delay_ms * 1000000LL;
}

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

void mb_core_register_wake(mb_core_driver_wake_fn on_wake, void *user_ctx) {
    ensure_cond_init();
    pthread_mutex_lock(&g_lock);
    g_wake_fn = on_wake;
    g_wake_ctx = on_wake != NULL ? user_ctx : NULL;
    if (on_wake != NULL) {
        // A driver attached to a running core gets its first `on_wake` to arm timers.
        if (g_started && !g_stopping) {
            g_wake_pending = 1;
        }
    } else {
        g_wake_pending = 0;
        g_sent_wake_pending = 0;
        g_has_deadline = 0;
    }
    pthread_cond_signal(&g_cond);
    // `g_worker` is valid whenever an `on_wake` is in flight. The worker itself never waits for its
    // own callout (it may re-register from inside `on_wake` or `on_send`).
    while (g_in_flight_wake && !pthread_equal(pthread_self(), g_worker)) {
        pthread_cond_wait(&g_wake_done, &g_lock);
    }
    pthread_mutex_unlock(&g_lock);
}

void mb_core_wake(void) {
    ensure_cond_init();
    pthread_mutex_lock(&g_lock);
    if (g_started && !g_stopping) {
        g_wake_pending = 1;
        pthread_cond_signal(&g_cond);
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

    pthread_mutex_lock(&g_lock);
    // First `on_wake` right after `on_start` lets the driver arm its timers.
    g_wake_pending = 1;
    // Whether the last callout was `on_wake`: a due or pending wake then yields to one queued message.
    int last_ran_wake = 0;
    // Messages handled since the last `on_wake`.
    int sent_since_wake = 0;
    for (;;) {
        if (g_stopping) {
            break;
        }
        int64_t now = 0;
        int timer_due = 0;
        if (g_has_deadline) {
            now = mono_now_ns();
            timer_due = now >= g_deadline_ns;
        }
        int wake_due = timer_due || g_wake_pending ||
                       (g_sent_wake_pending && sent_since_wake >= CORE_SEND_BURST_CAP);
        // A due timer or pending wake and queued messages take turns, so neither starves the other.
        if (g_head != NULL && (!wake_due || last_ran_wake)) {
            last_ran_wake = 0;
            sent_since_wake += 1;
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
            pthread_mutex_lock(&g_lock);
            // `on_send` may have scheduled timers: ask `on_wake` for the new deadline once the queue
            // is drained (the queue is checked first, so a burst coalesces into one call).
            if (g_wake_fn != NULL) {
                g_sent_wake_pending = 1;
            }
            continue;
        }
        if (wake_due || g_sent_wake_pending) {
            last_ran_wake = 1;
            sent_since_wake = 0;
            // Clear before calling out so a `mb_core_wake()` made while `on_wake` runs is kept.
            g_wake_pending = 0;
            g_sent_wake_pending = 0;
            g_has_deadline = 0;
            mb_core_driver_wake_fn wake_fn = g_wake_fn;
            void *wake_ctx = g_wake_ctx;
            if (wake_fn == NULL) {
                continue;
            }
            g_in_flight_wake = 1;
            pthread_mutex_unlock(&g_lock);
            int64_t delay_ms = wake_fn(wake_ctx);
            pthread_mutex_lock(&g_lock);
            g_in_flight_wake = 0;
            pthread_cond_broadcast(&g_wake_done);
            // A slot replaced or cleared meanwhile must not get the old callback's deadline.
            if (g_wake_fn == wake_fn && g_wake_ctx == wake_ctx && !g_stopping) {
                arm_wake_locked(delay_ms);
            }
            continue;
        }
        if (g_has_deadline) {
            timed_wait_locked(g_deadline_ns, now);
        } else {
            pthread_cond_wait(&g_cond, &g_lock);
        }
    }
    pthread_mutex_unlock(&g_lock);

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
    ensure_cond_init();
    pthread_mutex_lock(&g_lock);
    // A stop under way finishes first; then this start goes ahead unless another start won.
    while (g_stopping) {
        pthread_cond_wait(&g_stopped_cond, &g_lock);
    }
    if (g_started) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_data_dir = dup_cstr(data_dir);
    g_cloud_origin = dup_cstr(cloud_origin);
    g_beta = beta;
    g_wake_pending = 0;
    g_sent_wake_pending = 0;
    g_has_deadline = 0;
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

    ensure_cond_init();
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
    ensure_cond_init();
    pthread_mutex_lock(&g_lock);
    if (!g_started) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (pthread_equal(pthread_self(), g_worker)) {
        // Joining itself would leave a zombie worker and a core that looks stopped but is not.
        pthread_mutex_unlock(&g_lock);
        fprintf(stderr, "mb_core_stop: cannot be called from core worker thread\n");
        abort();
    }
    if (g_stopping) {
        // Another thread owns this stop (and the join): wait for it to finish.
        uint64_t seen = g_stops_done;
        while (g_stops_done == seen) {
            pthread_cond_wait(&g_stopped_cond, &g_lock);
        }
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
    g_wake_pending = 0;
    g_sent_wake_pending = 0;
    g_has_deadline = 0;
    g_ready = 0;
    g_stopping = 0;
    g_started = 0;
    g_stops_done += 1;
    pthread_cond_broadcast(&g_stopped_cond);
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
