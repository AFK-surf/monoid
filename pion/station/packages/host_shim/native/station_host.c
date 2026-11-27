// Native C11 host shim for Pion station workers (POSIX + _WIN32).
// Mirrors station/mb/src/host/host.c with generation-guarded shell lifecycle and
// strict single-threaded Pion ownership: foreign threads (stdin reader, Rust shell
// tokio workers, sys threads) NEVER call Pion callbacks; they only enqueue native
// events into the mutex-protected queue and signal the event loop condvar.

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif

#include "station_host.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define PSAPI_VERSION 2
#include <windows.h>
#include <psapi.h>
#include <shellapi.h>
#include <tlhelp32.h>
typedef SRWLOCK sth_lock_t;
typedef CONDITION_VARIABLE sth_cond_t;
#define STH_LOCK_INIT SRWLOCK_INIT
#define STH_COND_INIT CONDITION_VARIABLE_INIT
static void sth_lock(sth_lock_t *l) { AcquireSRWLockExclusive(l); }
static void sth_unlock(sth_lock_t *l) { ReleaseSRWLockExclusive(l); }
static void sth_signal(sth_cond_t *c) { WakeConditionVariable(c); }
static void sth_broadcast(sth_cond_t *c) { WakeAllConditionVariable(c); }
static void sth_cond_wait(sth_cond_t *c, sth_lock_t *l) { SleepConditionVariableSRW(c, l, INFINITE, 0); }
#else
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <crt_externs.h>
#include <mach/mach.h>
#endif
typedef pthread_mutex_t sth_lock_t;
typedef pthread_cond_t sth_cond_t;
#define STH_LOCK_INIT PTHREAD_MUTEX_INITIALIZER
#define STH_COND_INIT PTHREAD_COND_INITIALIZER
static void sth_lock(sth_lock_t *l) { pthread_mutex_lock(l); }
static void sth_unlock(sth_lock_t *l) { pthread_mutex_unlock(l); }
static void sth_signal(sth_cond_t *c) { pthread_cond_signal(c); }
static void sth_broadcast(sth_cond_t *c) { pthread_cond_broadcast(c); }
static void sth_cond_wait(sth_cond_t *c, sth_lock_t *l) { pthread_cond_wait(c, l); }
#endif

#ifndef STH_TARGET_NAME
#define STH_TARGET_NAME "unknown"
#endif
#ifndef STH_PION_SHA
#define STH_PION_SHA "unknown"
#endif

// Rust client/shell C ABI (client/shell/src/ffi.rs).
typedef void (*sf_complete)(
    void *ctx,
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes);
extern void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx);
extern void sf_shell_stop(void *shell);
extern void sf_shell_call(
    const void *shell,
    uint64_t id,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes);
extern uint8_t *sf_shell_call_sync(
    const void *shell,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    size_t *out_len);
extern void sf_free(uint8_t *ptr, size_t len);

typedef struct sth_event {
    struct sth_event *next;
    uint8_t kind;
    uint8_t bounded;
    uint64_t id;
    size_t len;
    uint8_t data[];
} sth_event_t;

static sth_lock_t g_life = STH_LOCK_INIT;
static sth_lock_t g_lock = STH_LOCK_INIT;
static sth_cond_t g_stdin_cond = STH_COND_INIT;
static sth_cond_t g_sys_cond = STH_COND_INIT;
static sth_cond_t g_inflight_cond = STH_COND_INIT;

// On non-Apple POSIX, initialize `g_queue_cond` and `g_test_waiter_cond` strictly once
// with CLOCK_MONOTONIC (never double-initialized with PTHREAD_COND_INITIALIZER + pthread_cond_init).
#if !defined(_WIN32) && !defined(__APPLE__)
static pthread_cond_t g_queue_cond;
static pthread_cond_t g_test_waiter_cond;
static pthread_once_t g_cond_once = PTHREAD_ONCE_INIT;
static void init_queue_cond(void) {
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(&g_queue_cond, &attr);
    pthread_cond_init(&g_test_waiter_cond, &attr);
    pthread_condattr_destroy(&attr);
}
static void ensure_queue_init(void) { pthread_once(&g_cond_once, init_queue_cond); }
#else
static sth_cond_t g_queue_cond = STH_COND_INIT;
static sth_cond_t g_test_waiter_cond = STH_COND_INIT;
static void ensure_queue_init(void) {}
#endif

static sth_event_t *g_head = NULL;
static sth_event_t *g_tail = NULL;
static size_t g_stdin_queued = 0;
static size_t g_stdin_peak = 0;
static size_t g_stdin_waiters = 0;
static size_t g_stdin_limit = STH_STDIN_MOST;
static size_t g_sys_queued = 0;
static size_t g_sys_waiters = 0;
static size_t g_queue_waiters = 0;

static void *g_shell = NULL;
static int g_stopping = 0;
static int g_in_flight = 0;
static uintptr_t g_gen = 0;
static uint64_t g_stop_gen = 0;
static int g_stdin_started = 0;

static void put_u64_le(uint8_t *at, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        at[i] = (uint8_t)(v >> (8 * i));
    }
}

static sth_event_t *event_alloc(uint8_t kind, uint64_t id, size_t len) {
    sth_event_t *e = (sth_event_t *)malloc(sizeof(*e) + (len ? len : 1));
    if (e == NULL) {
        abort();
    }
    e->next = NULL;
    e->kind = kind;
    e->bounded = 0;
    e->id = id;
    e->len = len;
    return e;
}

static void enqueue_locked(sth_event_t *e) {
    if (g_tail != NULL) {
        g_tail->next = e;
    } else {
        g_head = e;
    }
    g_tail = e;
    sth_signal(&g_queue_cond);
}

static void free_events(sth_event_t *list) {
    while (list != NULL) {
        sth_event_t *next = list->next;
        free(list);
        list = next;
    }
}

static uintptr_t next_gen_locked(void) {
    g_gen += 1;
    if (g_gen == 0) {
        g_gen = 1;
    }
    return g_gen;
}

static void *shell_enter(void) {
    sth_lock(&g_lock);
    void *sh = (g_shell != NULL && !g_stopping) ? g_shell : NULL;
    if (sh != NULL) {
        g_in_flight += 1;
    }
    sth_unlock(&g_lock);
    return sh;
}

static void shell_leave(void) {
    sth_lock(&g_lock);
    g_in_flight -= 1;
    if (g_in_flight == 0) {
        sth_broadcast(&g_inflight_cond);
    }
    sth_unlock(&g_lock);
}

static void shell_completed(
    void *ctx,
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes) {
    ensure_queue_init();
    uintptr_t gen = (uintptr_t)ctx;
    size_t carried = has_bytes ? bytes_len : 0;
    size_t payload_len = 8 + error_len + 8 + json_len + 1 + carried;
    sth_event_t *e = event_alloc(STH_EV_SHELL_DONE, id, payload_len);
    uint8_t *at = e->data;
    put_u64_le(at, (uint64_t)error_len);
    at += 8;
    if (error_len > 0 && error != NULL) {
        memcpy(at, error, error_len);
    }
    at += error_len;
    put_u64_le(at, (uint64_t)json_len);
    at += 8;
    if (json_len > 0 && json != NULL) {
        memcpy(at, json, json_len);
    }
    at += json_len;
    *at++ = has_bytes ? 1 : 0;
    if (carried > 0 && bytes != NULL) {
        memcpy(at, bytes, carried);
    }

    sth_lock(&g_lock);
    int live = (gen == 0) || (!g_stopping && g_shell != NULL && gen == g_gen);
    if (!live) {
        sth_unlock(&g_lock);
        free(e);
        return;
    }
    enqueue_locked(e);
    sth_unlock(&g_lock);
}

void sth_set_stdin_limit_for_test(size_t limit_bytes) {
    ensure_queue_init();
    sth_lock(&g_lock);
    g_stdin_limit = limit_bytes > 0 ? limit_bytes : STH_STDIN_MOST;
    g_stdin_peak = g_stdin_queued;
    sth_unlock(&g_lock);
}

size_t sth_stdin_queued_peak_for_test(void) {
    sth_lock(&g_lock);
    size_t p = g_stdin_peak;
    sth_unlock(&g_lock);
    return p;
}

static int32_t wait_for_counter_nonzero_locked(const size_t *counter, int64_t timeout_ms) {
    if (*counter > 0) {
        return 1;
    }
    if (timeout_ms == 0) {
        return 0;
    }
#if defined(_WIN32)
    if (timeout_ms < 0) {
        while (*counter == 0) {
            SleepConditionVariableSRW(&g_test_waiter_cond, &g_lock, INFINITE, 0);
        }
        return 1;
    }
    int64_t capped = timeout_ms > 86400000LL ? 86400000LL : timeout_ms;
    int64_t deadline = sth_now_ms() + capped;
    while (*counter == 0) {
        int64_t left = deadline - sth_now_ms();
        if (left <= 0) {
            break;
        }
        if (!SleepConditionVariableSRW(&g_test_waiter_cond, &g_lock, (DWORD)left, 0)) {
            if (GetLastError() == ERROR_TIMEOUT) {
                break;
            }
        }
    }
#elif defined(__APPLE__)
    if (timeout_ms < 0) {
        while (*counter == 0) {
            pthread_cond_wait(&g_test_waiter_cond, &g_lock);
        }
        return 1;
    }
    int64_t capped = timeout_ms > 86400000LL ? 86400000LL : timeout_ms;
    int64_t deadline = sth_now_ms() + capped;
    while (*counter == 0) {
        int64_t left = deadline - sth_now_ms();
        if (left <= 0) {
            break;
        }
        struct timespec rel;
        rel.tv_sec = (time_t)(left / 1000);
        rel.tv_nsec = (long)((left % 1000) * 1000000);
        if (pthread_cond_timedwait_relative_np(&g_test_waiter_cond, &g_lock, &rel) != 0) {
            break;
        }
    }
#else
    if (timeout_ms < 0) {
        while (*counter == 0) {
            pthread_cond_wait(&g_test_waiter_cond, &g_lock);
        }
        return 1;
    }
    int64_t capped = timeout_ms > 86400000LL ? 86400000LL : timeout_ms;
    struct timespec at;
    clock_gettime(CLOCK_MONOTONIC, &at);
    at.tv_sec += (time_t)(capped / 1000);
    at.tv_nsec += (long)((capped % 1000) * 1000000);
    if (at.tv_nsec >= 1000000000L) {
        at.tv_sec += 1;
        at.tv_nsec -= 1000000000L;
    }
    while (*counter == 0) {
        if (pthread_cond_timedwait(&g_test_waiter_cond, &g_lock, &at) != 0) {
            break;
        }
    }
#endif
    return *counter > 0 ? 1 : 0;
}

int32_t sth_wait_for_stdin_blocked_for_test(int64_t timeout_ms) {
    ensure_queue_init();
    sth_lock(&g_lock);
    int32_t ok = wait_for_counter_nonzero_locked(&g_stdin_waiters, timeout_ms);
    sth_unlock(&g_lock);
    return ok;
}

int32_t sth_wait_for_queue_waiter_for_test(int64_t timeout_ms) {
    ensure_queue_init();
    sth_lock(&g_lock);
    int32_t ok = wait_for_counter_nonzero_locked(&g_queue_waiters, timeout_ms);
    sth_unlock(&g_lock);
    return ok;
}

// Enqueues `data[0..len)` in slices so `g_stdin_queued` strictly never exceeds `g_stdin_limit`.
void sth_push_stdin_chunk(const uint8_t *data, size_t len) {
    if (len == 0 || data == NULL) {
        return;
    }
    ensure_queue_init();
    size_t off = 0;
    while (off < len) {
        sth_lock(&g_lock);
        while (g_stdin_queued >= g_stdin_limit) {
            g_stdin_waiters += 1;
            sth_broadcast(&g_test_waiter_cond);
            sth_cond_wait(&g_stdin_cond, &g_lock);
            g_stdin_waiters -= 1;
        }
        size_t room = g_stdin_limit - g_stdin_queued;
        size_t rem = len - off;
        size_t take = rem < room ? rem : room;
        g_stdin_queued += take;
        if (g_stdin_queued > g_stdin_peak) {
            g_stdin_peak = g_stdin_queued;
        }
        sth_unlock(&g_lock);

        sth_event_t *e = event_alloc(STH_EV_STDIN_DATA, 0, take);
        memcpy(e->data, data + off, take);

        sth_lock(&g_lock);
        enqueue_locked(e);
        sth_unlock(&g_lock);

        off += take;
    }
}

void sth_push_stdin_eof(void) {
    ensure_queue_init();
    sth_event_t *e = event_alloc(STH_EV_STDIN_EOF, 0, 0);
    sth_lock(&g_lock);
    enqueue_locked(e);
    sth_unlock(&g_lock);
}

void sth_push_sys(uint64_t id, const uint8_t *data, size_t len) {
    ensure_queue_init();
    sth_event_t *e = event_alloc(STH_EV_SYS, id, len);
    if (len > 0 && data != NULL) {
        memcpy(e->data, data, len);
    }
    sth_lock(&g_lock);
    enqueue_locked(e);
    sth_unlock(&g_lock);
}

void sth_push_sys_bounded(uint64_t id, const uint8_t *data, size_t len) {
    ensure_queue_init();
    sth_event_t *e = event_alloc(STH_EV_SYS, id, len);
    e->bounded = 1;
    if (len > 0 && data != NULL) {
        memcpy(e->data, data, len);
    }
    sth_lock(&g_lock);
    while (g_sys_queued >= STH_SYS_DATA_MOST) {
        g_sys_waiters += 1;
        sth_cond_wait(&g_sys_cond, &g_lock);
        g_sys_waiters -= 1;
    }
    g_sys_queued += len;
    enqueue_locked(e);
    sth_unlock(&g_lock);
}

#ifdef _WIN32
static DWORD WINAPI read_stdin_thread(LPVOID arg) {
    (void)arg;
    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    uint8_t buf[65536];
    DWORD n = 0;
    while (ReadFile(in, buf, (DWORD)sizeof(buf), &n, NULL) && n > 0) {
        sth_push_stdin_chunk(buf, (size_t)n);
    }
    sth_push_stdin_eof();
    return 0;
}
#else
static void *read_stdin_thread(void *arg) {
    (void)arg;
    uint8_t buf[65536];
    for (;;) {
        ssize_t n = read(0, buf, sizeof(buf));
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            break;
        }
        sth_push_stdin_chunk(buf, (size_t)n);
    }
    sth_push_stdin_eof();
    return NULL;
}

static void raise_nofile(void) {
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) != 0) {
        return;
    }
    rlim_t most = 65536;
    rlim_t cap = (limit.rlim_max == RLIM_INFINITY || limit.rlim_max > most) ? most : limit.rlim_max;
    rlim_t targets[3] = {
        cap,
        cap < 10240 ? cap : 10240,
        cap < 4096 ? cap : 4096,
    };
    for (int i = 0; i < 3; i++) {
        if (targets[i] <= limit.rlim_cur) {
            return;
        }
        struct rlimit next = { targets[i], limit.rlim_max };
        if (setrlimit(RLIMIT_NOFILE, &next) == 0) {
            return;
        }
    }
}
#endif

// Unlink only STH_EV_SHELL_DONE events from the queue (under g_lock), preserving
// queued STH_EV_STDIN_DATA, STH_EV_STDIN_EOF, and STH_EV_SYS events in FIFO order.
static sth_event_t *drop_shell_events_locked(void) {
    sth_event_t *dropped = NULL;
    sth_event_t *prev = NULL;
    sth_event_t *cur = g_head;
    while (cur != NULL) {
        sth_event_t *next = cur->next;
        if (cur->kind == STH_EV_SHELL_DONE) {
            if (prev != NULL) {
                prev->next = next;
            } else {
                g_head = next;
            }
            cur->next = dropped;
            dropped = cur;
        } else {
            prev = cur;
        }
        cur = next;
    }
    g_tail = prev;
    return dropped;
}

static void stop_shell_held(void) {
    ensure_queue_init();
    sth_lock(&g_lock);
    g_stopping = 1;
    (void)next_gen_locked();
    g_stop_gen += 1;
    sth_event_t *dropped = drop_shell_events_locked();
    sth_broadcast(&g_queue_cond);
    while (g_in_flight > 0) {
        sth_cond_wait(&g_inflight_cond, &g_lock);
    }
    void *owned = g_shell;
    g_shell = NULL;
    sth_unlock(&g_lock);

    free_events(dropped);
    if (owned != NULL) {
        sf_shell_stop(owned);
    }

    sth_lock(&g_lock);
    sth_event_t *late = drop_shell_events_locked();
    g_stopping = 0;
    sth_unlock(&g_lock);
    free_events(late);
}

int32_t sth_start(const char *shell_dir, int32_t start_stdin) {
    ensure_queue_init();
#ifndef _WIN32
    raise_nofile();
    signal(SIGPIPE, SIG_IGN);
#endif
    sth_lock(&g_life);
    int started_shell_now = 0;
    if (shell_dir != NULL && shell_dir[0] != '\0') {
        sth_lock(&g_lock);
        int had = g_shell != NULL;
        sth_unlock(&g_lock);
        if (had) {
            stop_shell_held();
        }
        sth_lock(&g_lock);
        uintptr_t gen = next_gen_locked();
        sth_event_t *stale = drop_shell_events_locked();
        sth_unlock(&g_lock);
        free_events(stale);

        void *started = sf_shell_start(shell_dir, shell_completed, (void *)gen);
        if (started == NULL) {
            sth_unlock(&g_life);
            return 0;
        }
        sth_lock(&g_lock);
        g_shell = started;
        sth_unlock(&g_lock);
        started_shell_now = 1;
    }

    if (start_stdin) {
        sth_lock(&g_lock);
        int need_stdin = !g_stdin_started;
        if (need_stdin) {
            g_stdin_started = 1;
        }
        sth_unlock(&g_lock);
        if (need_stdin) {
            int thread_ok = 0;
#ifdef _WIN32
            HANDLE t = CreateThread(NULL, 0, read_stdin_thread, NULL, 0, NULL);
            if (t != NULL) {
                CloseHandle(t);
                thread_ok = 1;
            }
#else
            pthread_t t;
            if (pthread_create(&t, NULL, read_stdin_thread, NULL) == 0) {
                pthread_detach(t);
                thread_ok = 1;
            }
#endif
            if (!thread_ok) {
                sth_lock(&g_lock);
                g_stdin_started = 0;
                sth_unlock(&g_lock);
                if (started_shell_now) {
                    stop_shell_held();
                }
                sth_unlock(&g_life);
                return 0;
            }
        }
    }
    sth_unlock(&g_life);
    return 1;
}

void sth_stop(void) {
    ensure_queue_init();
    sth_lock(&g_life);
    stop_shell_held();
    sth_unlock(&g_life);
}

int32_t sth_shell_active(void) {
    sth_lock(&g_lock);
    int32_t active = (g_shell != NULL && !g_stopping) ? 1 : 0;
    sth_unlock(&g_lock);
    return active;
}

void *sth_wait(int64_t ms, int64_t *out_len) {
    ensure_queue_init();
    sth_lock(&g_lock);
    uint64_t stop_gen = g_stop_gen;
    if (g_head == NULL && ms != 0) {
        g_queue_waiters += 1;
        sth_broadcast(&g_test_waiter_cond);
#ifdef _WIN32
        if (ms < 0) {
            while (g_head == NULL && g_stop_gen == stop_gen) {
                SleepConditionVariableSRW(&g_queue_cond, &g_lock, INFINITE, 0);
            }
        } else {
            int64_t capped = ms > 86400000LL ? 86400000LL : ms;
            int64_t deadline = sth_now_ms() + capped;
            while (g_head == NULL && g_stop_gen == stop_gen) {
                int64_t left = deadline - sth_now_ms();
                if (left <= 0) {
                    break;
                }
                if (!SleepConditionVariableSRW(&g_queue_cond, &g_lock, (DWORD)left, 0)) {
                    break;
                }
            }
        }
#elif defined(__APPLE__)
        if (ms < 0) {
            while (g_head == NULL && g_stop_gen == stop_gen) {
                pthread_cond_wait(&g_queue_cond, &g_lock);
            }
        } else {
            int64_t capped = ms > 86400000LL ? 86400000LL : ms;
            int64_t deadline = sth_now_ms() + capped;
            while (g_head == NULL && g_stop_gen == stop_gen) {
                int64_t left = deadline - sth_now_ms();
                if (left <= 0) {
                    break;
                }
                struct timespec rel;
                rel.tv_sec = (time_t)(left / 1000);
                rel.tv_nsec = (long)((left % 1000) * 1000000);
                if (pthread_cond_timedwait_relative_np(&g_queue_cond, &g_lock, &rel) != 0) {
                    break;
                }
            }
        }
#else
        if (ms < 0) {
            while (g_head == NULL && g_stop_gen == stop_gen) {
                pthread_cond_wait(&g_queue_cond, &g_lock);
            }
        } else {
            int64_t capped = ms > 86400000LL ? 86400000LL : ms;
            struct timespec at;
            clock_gettime(CLOCK_MONOTONIC, &at);
            at.tv_sec += (time_t)(capped / 1000);
            at.tv_nsec += (long)((capped % 1000) * 1000000);
            if (at.tv_nsec >= 1000000000L) {
                at.tv_sec += 1;
                at.tv_nsec -= 1000000000L;
            }
            while (g_head == NULL && g_stop_gen == stop_gen) {
                if (pthread_cond_timedwait(&g_queue_cond, &g_lock, &at) != 0) {
                    break;
                }
            }
        }
#endif
        g_queue_waiters -= 1;
    }
    // Always prioritize delivering any retained event (e.g., stdin/EOF); only return NULL
    // when the queue is actually empty (timed out or woken by sth_stop()).
    sth_event_t *e = g_head;
    if (e != NULL) {
        g_head = e->next;
        if (g_head == NULL) {
            g_tail = NULL;
        }
        if (e->kind == STH_EV_STDIN_DATA) {
            g_stdin_queued -= e->len;
            if (g_stdin_queued < g_stdin_limit) {
                sth_signal(&g_stdin_cond);
            }
        }
        if (e->bounded) {
            g_sys_queued -= e->len;
            if (g_sys_waiters > 0 && g_sys_queued < STH_SYS_DATA_MOST) {
                sth_broadcast(&g_sys_cond);
            }
        }
    }
    sth_unlock(&g_lock);

    if (e == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }

    size_t total = 9 + e->len;
    uint8_t *out = (uint8_t *)malloc(total);
    if (out == NULL) {
        abort();
    }
    out[0] = e->kind;
    put_u64_le(out + 1, e->id);
    if (e->len > 0) {
        memcpy(out + 9, e->data, e->len);
    }
    free(e);
    if (out_len != NULL) {
        *out_len = (int64_t)total;
    }
    return out;
}

static int32_t write_fd_all(
#ifdef _WIN32
    DWORD std_handle,
#else
    int fd,
#endif
    const uint8_t *data,
    int64_t len) {
    if (len <= 0) {
        return 1;
    }
    if (data == NULL) {
        return 0;
    }
    size_t total = (size_t)len;
    size_t done = 0;
    while (done < total) {
#ifdef _WIN32
        DWORD n = 0;
        DWORD chunk = (total - done) > 0x7fffffffU ? 0x7fffffffU : (DWORD)(total - done);
        if (!WriteFile(GetStdHandle(std_handle), data + done, chunk, &n, NULL) || n == 0) {
            return 0;
        }
        done += (size_t)n;
#else
        ssize_t n = write(fd, data + done, total - done);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            return 0;
        }
        done += (size_t)n;
#endif
    }
    return 1;
}

int32_t sth_write_stdout(const uint8_t *data, int64_t len) {
#ifdef _WIN32
    return write_fd_all(STD_OUTPUT_HANDLE, data, len);
#else
    return write_fd_all(1, data, len);
#endif
}

int32_t sth_write_stderr(const uint8_t *data, int64_t len) {
#ifdef _WIN32
    return write_fd_all(STD_ERROR_HANDLE, data, len);
#else
    return write_fd_all(2, data, len);
#endif
}

void sth_shell_call(
    int64_t id,
    const char *op,
    const uint8_t *json,
    int64_t json_len,
    const uint8_t *bytes,
    int64_t bytes_len,
    int32_t has_bytes) {
    void *sh = shell_enter();
    if (sh == NULL) {
        static const char none[] = "no shell";
        shell_completed(NULL, (uint64_t)id, NULL, 0, (const uint8_t *)none, sizeof(none) - 1, NULL, 0, 0);
        return;
    }
    const char *cop = op != NULL ? op : "";
    size_t jlen = json_len > 0 ? (size_t)json_len : 0;
    size_t blen = bytes_len > 0 ? (size_t)bytes_len : 0;
    sf_shell_call(sh, (uint64_t)id, cop, json, jlen, bytes, blen, has_bytes ? 1 : 0);
    shell_leave();
}

void *sth_shell_sync(
    const char *op,
    const uint8_t *json,
    int64_t json_len,
    int64_t *out_len) {
    void *sh = shell_enter();
    if (sh == NULL) {
        static const char none[] = "{\"error\":\"no shell\"}";
        size_t n = sizeof(none) - 1;
        uint8_t *out = (uint8_t *)malloc(n);
        if (out == NULL) {
            abort();
        }
        memcpy(out, none, n);
        if (out_len != NULL) {
            *out_len = (int64_t)n;
        }
        return out;
    }
    const char *cop = op != NULL ? op : "";
    size_t jlen = json_len > 0 ? (size_t)json_len : 0;
    size_t n = 0;
    uint8_t *answer = sf_shell_call_sync(sh, cop, json, jlen, &n);
    shell_leave();
    if (answer == NULL || n == 0) {
        if (answer != NULL) {
            sf_free(answer, n);
        }
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    uint8_t *out = (uint8_t *)malloc(n);
    if (out == NULL) {
        abort();
    }
    memcpy(out, answer, n);
    sf_free(answer, n);
    if (out_len != NULL) {
        *out_len = (int64_t)n;
    }
    return out;
}

#define STH_DIRECT_SLICE_MAX (256LL * 1024LL * 1024LL)

void *sth_read_file_slice(
    const char *path,
    int64_t from,
    int64_t length,
    int64_t *out_len) {
    if (out_len != NULL) {
        *out_len = -2;
    }
    if (path == NULL || path[0] == '\0' || from < 0) {
        return NULL;
    }
#ifdef _WIN32
    int wlen = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
    if (wlen <= 0) {
        if (out_len != NULL) {
            *out_len = -1;
        }
        return NULL;
    }
    wchar_t *wpath = (wchar_t *)malloc(sizeof(wchar_t) * (size_t)wlen);
    if (wpath == NULL) {
        abort();
    }
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, wlen) <= 0) {
        free(wpath);
        if (out_len != NULL) {
            *out_len = -1;
        }
        return NULL;
    }
    HANDLE h = CreateFileW(
        wpath,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL);
    free(wpath);
    if (h == INVALID_HANDLE_VALUE) {
        if (out_len != NULL) {
            *out_len = -1;
        }
        return NULL;
    }
    if (GetFileType(h) != FILE_TYPE_DISK) {
        CloseHandle(h);
        return NULL;
    }
    if (length == 0) {
        CloseHandle(h);
        uint8_t *empty = (uint8_t *)malloc(1);
        if (empty == NULL) {
            abort();
        }
        if (out_len != NULL) {
            *out_len = 0;
        }
        return empty;
    }
    LARGE_INTEGER fsz_li;
    if (!GetFileSizeEx(h, &fsz_li)) {
        CloseHandle(h);
        return NULL;
    }
    int64_t fsz = (int64_t)fsz_li.QuadPart;
    if (from >= fsz) {
        CloseHandle(h);
        uint8_t *empty = (uint8_t *)malloc(1);
        if (empty == NULL) {
            abort();
        }
        if (out_len != NULL) {
            *out_len = 0;
        }
        return empty;
    }
    int64_t avail = fsz - from;
    int64_t target = (length >= 0 && length < avail) ? length : avail;
    if (target > STH_DIRECT_SLICE_MAX) {
        CloseHandle(h);
        return NULL;
    }
    LARGE_INTEGER seek_li;
    seek_li.QuadPart = from;
    if (!SetFilePointerEx(h, seek_li, NULL, FILE_BEGIN)) {
        CloseHandle(h);
        return NULL;
    }
    size_t cap = target > 0 ? (size_t)target : 1;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        CloseHandle(h);
        abort();
    }
    size_t got = 0;
    while (1) {
        if (length >= 0 && got >= (size_t)target) {
            break;
        }
        if (length < 0 && got == cap) {
            size_t next_cap = cap < 65536 ? 65536 : cap * 2;
            if (next_cap > (size_t)STH_DIRECT_SLICE_MAX) {
                next_cap = (size_t)STH_DIRECT_SLICE_MAX;
            }
            if (next_cap <= cap) {
                free(buf);
                CloseHandle(h);
                return NULL;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, next_cap);
            if (nbuf == NULL) {
                free(buf);
                CloseHandle(h);
                abort();
            }
            buf = nbuf;
            cap = next_cap;
        }
        size_t rem = (length >= 0 ? (size_t)target : cap) - got;
        DWORD want = rem > 0x40000000u ? (DWORD)0x40000000u : (DWORD)rem;
        DWORD rd = 0;
        if (!ReadFile(h, buf + got, want, &rd, NULL)) {
            free(buf);
            CloseHandle(h);
            return NULL;
        }
        if (rd == 0) {
            break;
        }
        got += (size_t)rd;
    }
    CloseHandle(h);
    if (out_len != NULL) {
        *out_len = (int64_t)got;
    }
    return buf;
#else
    int fd = -1;
    do {
        fd = open(path, O_RDONLY);
    } while (fd < 0 && errno == EINTR);
    if (fd < 0) {
        if (out_len != NULL) {
            *out_len = -1;
        }
        return NULL;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return NULL;
    }
    if (length == 0) {
        close(fd);
        uint8_t *empty = (uint8_t *)malloc(1);
        if (empty == NULL) {
            abort();
        }
        if (out_len != NULL) {
            *out_len = 0;
        }
        return empty;
    }
    int64_t fsz = (int64_t)st.st_size;
    if (from >= fsz) {
        close(fd);
        uint8_t *empty = (uint8_t *)malloc(1);
        if (empty == NULL) {
            abort();
        }
        if (out_len != NULL) {
            *out_len = 0;
        }
        return empty;
    }
    int64_t avail = fsz - from;
    int64_t target = (length >= 0 && length < avail) ? length : avail;
    if (target > STH_DIRECT_SLICE_MAX) {
        close(fd);
        return NULL;
    }
    size_t cap = target > 0 ? (size_t)target : 1;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (buf == NULL) {
        close(fd);
        abort();
    }
    size_t got = 0;
    while (1) {
        if (length >= 0 && got >= (size_t)target) {
            break;
        }
        if (length < 0 && got == cap) {
            size_t next_cap = cap < 65536 ? 65536 : cap * 2;
            if (next_cap > (size_t)STH_DIRECT_SLICE_MAX) {
                next_cap = (size_t)STH_DIRECT_SLICE_MAX;
            }
            if (next_cap <= cap) {
                free(buf);
                close(fd);
                return NULL;
            }
            uint8_t *nbuf = (uint8_t *)realloc(buf, next_cap);
            if (nbuf == NULL) {
                free(buf);
                close(fd);
                abort();
            }
            buf = nbuf;
            cap = next_cap;
        }
        size_t rem = (length >= 0 ? (size_t)target : cap) - got;
        if (rem > 0x40000000u) {
            rem = 0x40000000u;
        }
        ssize_t r = pread(fd, buf + got, rem, (off_t)(from + (int64_t)got));
        if (r > 0) {
            got += (size_t)r;
        } else if (r == 0) {
            break;
        } else if (errno == EINTR) {
            continue;
        } else {
            free(buf);
            close(fd);
            return NULL;
        }
    }
    close(fd);
    if (out_len != NULL) {
        *out_len = (int64_t)got;
    }
    return buf;
#endif
}

void *sth_args(int64_t *out_len) {
    size_t len = 0;
    char *all = NULL;
#if defined(_WIN32)
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 0; argv != NULL && i < argc; i++) {
        int n = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, NULL, 0, NULL, NULL);
        if (n <= 0) {
            continue;
        }
        char *next = (char *)realloc(all, len + (size_t)n);
        if (next == NULL) {
            free(all);
            LocalFree(argv);
            abort();
        }
        all = next;
        WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, all + len, n, NULL, NULL);
        len += (size_t)n;
    }
    if (argv != NULL) {
        LocalFree(argv);
    }
#elif defined(__APPLE__)
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 0; i < argc; i++) {
        size_t n = strlen(argv[i]) + 1;
        char *next = (char *)realloc(all, len + n);
        if (next == NULL) {
            free(all);
            abort();
        }
        all = next;
        memcpy(all + len, argv[i], n);
        len += n;
    }
#else
    FILE *f = fopen("/proc/self/cmdline", "rb");
    if (f != NULL) {
        char buf[4096];
        size_t n = 0;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
            char *next = (char *)realloc(all, len + n);
            if (next == NULL) {
                free(all);
                fclose(f);
                abort();
            }
            all = next;
            memcpy(all + len, buf, n);
            len += n;
        }
        fclose(f);
    }
#endif
    if (out_len != NULL) {
        *out_len = (int64_t)len;
    }
    return all;
}

int32_t sth_pid(void) {
#ifdef _WIN32
    return (int32_t)GetCurrentProcessId();
#else
    return (int32_t)getpid();
#endif
}

void sth_exit(int32_t code) {
    exit((int)code);
}

int64_t sth_now_ms(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64();
#else
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
#endif
}

int64_t sth_wall_ms(void) {
#ifdef _WIN32
    FILETIME t;
    GetSystemTimePreciseAsFileTime(&t);
    uint64_t v = ((uint64_t)t.dwHighDateTime << 32) | t.dwLowDateTime;
    return (int64_t)((v - 116444736000000000ULL) / 10000ULL);
#else
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
#endif
}

int64_t sth_rss_bytes(void) {
#if defined(_WIN32)
    PROCESS_MEMORY_COUNTERS pmc;
    memset(&pmc, 0, sizeof(pmc));
    if (K32GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof(pmc))) {
        return (int64_t)pmc.WorkingSetSize;
    }
    return -1;
#elif defined(__APPLE__)
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (int64_t)info.resident_size;
    }
    return -1;
#else
    FILE *f = fopen("/proc/self/statm", "r");
    if (f == NULL) {
        return -1;
    }
    unsigned long size_pages = 0;
    unsigned long resident_pages = 0;
    int got = fscanf(f, "%lu %lu", &size_pages, &resident_pages);
    fclose(f);
    if (got != 2) {
        return -1;
    }
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) {
        ps = 4096;
    }
    return (int64_t)resident_pages * (int64_t)ps;
#endif
}

int32_t sth_open_fd_count(void) {
#if defined(_WIN32)
    DWORD count = 0;
    if (GetProcessHandleCount(GetCurrentProcess(), &count)) {
        return (int32_t)count;
    }
    return -1;
#else
#if defined(__APPLE__)
    const char *dir_path = "/dev/fd";
#else
    const char *dir_path = "/proc/self/fd";
#endif
    DIR *d = opendir(dir_path);
    if (d == NULL) {
        return -1;
    }
    int32_t count = 0;
    struct dirent *ent = NULL;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) {
            continue;
        }
        count += 1;
    }
    closedir(d);
    // Subtract 1 for the directory stream fd opened above.
    return count > 0 ? count - 1 : 0;
#endif
}

int32_t sth_open_thread_count(void) {
#if defined(_WIN32)
    DWORD pid = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) {
        return -1;
    }
    THREADENTRY32 te;
    memset(&te, 0, sizeof(te));
    te.dwSize = sizeof(te);
    int32_t count = 0;
    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID == pid) {
                count += 1;
            }
        } while (Thread32Next(snap, &te));
    }
    CloseHandle(snap);
    return count > 0 ? count : -1;
#elif defined(__APPLE__)
    thread_act_array_t list = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &list, &count) != KERN_SUCCESS) {
        return -1;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, (vm_size_t)count * sizeof(thread_act_t));
    return (int32_t)count;
#else
    FILE *f = fopen("/proc/self/status", "r");
    if (f == NULL) {
        return -1;
    }
    char line[256];
    int32_t threads = -1;
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "Threads:", 8) == 0) {
            int parsed = 0;
            if (sscanf(line + 8, "%d", &parsed) == 1 && parsed > 0) {
                threads = (int32_t)parsed;
            }
            break;
        }
    }
    fclose(f);
    return threads;
#endif
}

void *sth_build_info(int64_t *out_len) {
    char buf[256];
    int n = snprintf(
        buf,
        sizeof(buf),
        "stillfail-pion 0.1.0 (target=%s, pion=%s)",
        STH_TARGET_NAME,
        STH_PION_SHA);
    if (n < 0) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    size_t len = (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1;
    char *out = (char *)malloc(len);
    if (out == NULL) {
        abort();
    }
    memcpy(out, buf, len);
    if (out_len != NULL) {
        *out_len = (int64_t)len;
    }
    return out;
}

void sth_free(void *ptr) {
    free(ptr);
}
