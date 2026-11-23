// Native C bridge between Pion (`extern "C"`) and the Rust shell C ABI (`sf_shell_*`).
// Answers arrive on shell worker threads, are queued here under a mutex, and drained on
// the Pion runtime's own thread via `bsh_wait` / `Shell::pump`. Nothing here invokes Pion
// callbacks from foreign threads. `bsh_screen_ack` / `bsh_screen_input` are plain C, safe to call
// from any thread (a media decoder's) without entering the Pion runtime.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#ifdef __linux__
#include <sys/random.h>
#endif

// Rust shell C ABI (client/shell/src/ffi.rs).
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

typedef void (*sf_say)(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len);
typedef uint8_t (*sf_media)(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len);

extern void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx);
extern void sf_shell_stop(void *shell);
extern void sf_shell_set_say(const void *shell, sf_say say, void *ctx);
extern void sf_shell_set_media(const void *shell, sf_media media, void *ctx);
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
extern uint8_t sf_shell_screen_ack(const void *shell, uint64_t call, double ts);
extern uint8_t sf_shell_screen_input(const void *shell, uint64_t call, const uint8_t *json, size_t len);
extern void sf_free(uint8_t *ptr, size_t len);

// Framed answer record: [id:8 le][kind:1][text_len:4 le][text][bytes]
typedef struct bsh_answer {
    struct bsh_answer *next;
    size_t len;
    uint8_t data[];
} bsh_answer_t;

// Lifecycle: `g_life` serializes `bsh_start` / `bsh_stop` / `bsh_attach` (held across `sf_shell_start` /
// `sf_shell_stop`, never taken by shell threads). `g_lock` guards everything below; it is never held across a
// call into the shell or a wake callback. Each owned shell gets a fresh nonzero generation `g_gen` passed as its
// completion `ctx`; `bsh_stop` bumps it, so a late answer of a stopped shell (`sf_shell_stop` shuts its runtime
// down in the background) is dropped instead of reaching the next shell's call of the same id.
// `g_in_flight` counts threads using `g_shell` outside the lock (calls, asks, screen ops, wake callbacks):
// `bsh_stop` waits for it to reach zero before the handle is released.
// Wake callbacks: each registration (`bsh_on_wake`, `bsh_attach`, `bsh_stop`) bumps `g_wake_reg`; calls of the
// current one are `g_wake_current`, calls of replaced ones `g_wake_stale`. Replacing a callback waits until no
// replaced one runs (unless the caller is itself inside one), so its `ctx` may be freed on return.
static pthread_mutex_t g_life = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_came; // `bsh_came()`: on a monotonic clock where the platform allows
static pthread_once_t g_came_once = PTHREAD_ONCE_INIT;
static pthread_cond_t g_in_flight_done = PTHREAD_COND_INITIALIZER;
static pthread_cond_t g_wake_done = PTHREAD_COND_INITIALIZER;
static bsh_answer_t *g_first = NULL;
static bsh_answer_t *g_last = NULL;
static void *g_shell = NULL;
static int g_shell_owned = 0;
static int g_stopping = 0;
static int g_in_flight = 0;
static uintptr_t g_gen = 0;
static uint64_t g_wait_epoch = 0;
static void (*g_on_wake)(void *) = NULL;
static void *g_wake_ctx = NULL;
static uint64_t g_wake_reg = 0;
static int g_wake_current = 0;
static int g_wake_stale = 0;
static _Thread_local int t_in_wake = 0;

typedef void (*bsh_say_fn)(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len);
typedef uint8_t (*bsh_media_fn)(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len);

static pthread_cond_t g_say_done = PTHREAD_COND_INITIALIZER;
static bsh_say_fn g_on_say = NULL;
static void *g_say_ctx = NULL;
static uint64_t g_say_reg = 0;
static int g_say_current = 0;
static int g_say_stale = 0;
static _Thread_local int t_in_say = 0;

static pthread_cond_t g_media_done = PTHREAD_COND_INITIALIZER;
static bsh_media_fn g_on_media = NULL;
static void *g_media_ctx = NULL;
static uint64_t g_media_reg = 0;
static int g_media_current = 0;
static int g_media_stale = 0;
static _Thread_local int t_in_media = 0;

static void bsh_came_init(void) {
#ifdef __APPLE__
    pthread_cond_init(&g_came, NULL);
#else
    pthread_condattr_t attr;
    pthread_condattr_init(&attr);
    pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
    pthread_cond_init(&g_came, &attr);
    pthread_condattr_destroy(&attr);
#endif
}

static pthread_cond_t *bsh_came(void) {
    pthread_once(&g_came_once, bsh_came_init);
    return &g_came;
}

// Under `g_lock`: the next generation, never 0 (0 marks answers that are not an owned shell's).
static uintptr_t bsh_next_gen_locked(void) {
    g_gen += 1;
    if (g_gen == 0) {
        g_gen = 1;
    }
    return g_gen;
}

// Under `g_lock`: replace the wake callback; calls of the old one become stale.
static void bsh_set_wake_locked(void (*woke)(void *), void *ctx) {
    g_on_wake = woke;
    g_wake_ctx = ctx;
    g_wake_reg += 1;
    g_wake_stale += g_wake_current;
    g_wake_current = 0;
}

// Under `g_lock`: wait until no replaced wake callback runs, unless this thread is inside one.
static void bsh_wait_stale_wakes_locked(void) {
    if (t_in_wake) {
        return;
    }
    while (g_wake_stale > 0) {
        pthread_cond_wait(&g_wake_done, &g_lock);
    }
}

// Shared-shell call ID offset (2^40, exact in IEEE-754 double / JSON).
#define BSH_ATTACHED_BASE (1ULL << 40)

// Under `g_lock`.
static void bsh_left_locked(void) {
    g_in_flight -= 1;
    if (g_in_flight == 0) {
        pthread_cond_broadcast(&g_in_flight_done);
    }
}

// Take the current handle for use outside the lock (NULL when none or stopping); release with `bsh_leave`.
static void *bsh_enter(void) {
    pthread_mutex_lock(&g_lock);
    void *sh = (g_shell != NULL && !g_stopping) ? g_shell : NULL;
    if (sh != NULL) {
        g_in_flight += 1;
    }
    pthread_mutex_unlock(&g_lock);
    return sh;
}

static void bsh_leave(void) {
    pthread_mutex_lock(&g_lock);
    bsh_left_locked();
    pthread_mutex_unlock(&g_lock);
}

// Under `g_lock`: a call of the current wake callback is about to run.
static void bsh_wake_begin_locked(void) {
    g_in_flight += 1;
    g_wake_current += 1;
}

// Run `woke` (registration `reg`) outside the lock, then account for it.
static void bsh_wake_run(void (*woke)(void *), void *ctx, uint64_t reg) {
    int outer = t_in_wake;
    t_in_wake = 1;
    woke(ctx);
    t_in_wake = outer;
    pthread_mutex_lock(&g_lock);
    if (reg == g_wake_reg) {
        g_wake_current -= 1;
    } else {
        g_wake_stale -= 1;
        if (g_wake_stale == 0) {
            pthread_cond_broadcast(&g_wake_done);
        }
    }
    bsh_left_locked();
    pthread_mutex_unlock(&g_lock);
}

static bsh_answer_t *bsh_frame(
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes) {
    const uint8_t *text = error_len > 0 ? error : json;
    size_t text_len = error_len > 0 ? error_len : json_len;
    size_t carried = (error_len == 0 && has_bytes) ? bytes_len : 0;
    bsh_answer_t *a = (bsh_answer_t *)malloc(sizeof(*a) + 13 + text_len + carried);
    if (a == NULL) {
        abort();
    }
    a->next = NULL;
    a->len = 13 + text_len + carried;
    for (int i = 0; i < 8; i++) {
        a->data[i] = (uint8_t)(id >> (8 * i));
    }
    a->data[8] = error_len > 0 ? 2 : (has_bytes ? 1 : 0);
    for (int i = 0; i < 4; i++) {
        a->data[9 + i] = (uint8_t)((uint32_t)text_len >> (8 * i));
    }
    if (text_len > 0 && text != NULL) {
        memcpy(a->data + 13, text, text_len);
    }
    if (carried > 0 && bytes != NULL) {
        memcpy(a->data + 13 + text_len, bytes, carried);
    }
    return a;
}

// Queue `a` and run the wake callback outside the lock. With `gen` nonzero it must be the current owned
// shell's generation; with `gen` zero (a shared host shell's answer) a shell must be attached. `local` queues
// unconditionally (answers made here, not by a shell). Returns 1 if queued, else frees `a` and returns 0.
static int bsh_enqueue(bsh_answer_t *a, uintptr_t gen, int local) {
    pthread_mutex_lock(&g_lock);
    int live = local || (!g_stopping && g_shell != NULL && (gen != 0 ? gen == g_gen && g_shell_owned : 1));
    if (!live) {
        pthread_mutex_unlock(&g_lock);
        free(a);
        return 0;
    }
    if (g_last != NULL) {
        g_last->next = a;
    } else {
        g_first = a;
    }
    g_last = a;
    pthread_cond_signal(bsh_came());
    void (*woke)(void *) = g_on_wake;
    void *wctx = g_wake_ctx;
    uint64_t reg = g_wake_reg;
    if (woke != NULL) {
        bsh_wake_begin_locked();
    }
    pthread_mutex_unlock(&g_lock);
    if (woke != NULL) {
        bsh_wake_run(woke, wctx, reg);
    }
    return 1;
}

static void bsh_completed(
    void *ctx,
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes) {
    uintptr_t gen = (uintptr_t)ctx;
    if (gen == 0) {
        return;
    }
    (void)bsh_enqueue(bsh_frame(id, json, json_len, error, error_len, bytes, bytes_len, has_bytes), gen, 0);
}

// Under `g_lock`: take every queued answer and make blocked `bsh_wait` callers return NULL; free the result
// with `bsh_free_answers` outside the lock.
static bsh_answer_t *bsh_take_queue_locked(void) {
    bsh_answer_t *left = g_first;
    g_first = NULL;
    g_last = NULL;
    g_wait_epoch += 1;
    pthread_cond_broadcast(bsh_came());
    return left;
}

static void bsh_free_answers(bsh_answer_t *left) {
    while (left != NULL) {
        bsh_answer_t *next = left->next;
        free(left);
        left = next;
    }
}

// Calling `bsh_stop`, `bsh_start` or `bsh_attach` from a wake/say/media callback would wait for itself.
static void bsh_refuse_in_wake(const char *what) {
    if (t_in_wake || t_in_say || t_in_media) {
        fprintf(stderr, "shell_pion: %s called from a shell callback\n", what);
        abort();
    }
}

// Under `g_lock`: replace the say callback; calls of the old one become stale.
static void bsh_set_say_locked(bsh_say_fn say, void *ctx) {
    g_on_say = say;
    g_say_ctx = ctx;
    g_say_reg += 1;
    g_say_stale += g_say_current;
    g_say_current = 0;
}

static void bsh_wait_stale_says_locked(void) {
    if (t_in_say) {
        return;
    }
    while (g_say_stale > 0) {
        pthread_cond_wait(&g_say_done, &g_lock);
    }
}

// Under `g_lock`: replace the media callback; calls of the old one become stale.
static void bsh_set_media_locked(bsh_media_fn media, void *ctx) {
    g_on_media = media;
    g_media_ctx = ctx;
    g_media_reg += 1;
    g_media_stale += g_media_current;
    g_media_current = 0;
}

static void bsh_wait_stale_medias_locked(void) {
    if (t_in_media) {
        return;
    }
    while (g_media_stale > 0) {
        pthread_cond_wait(&g_media_done, &g_lock);
    }
}

static void bsh_say_trampoline(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len) {
    uintptr_t gen = (uintptr_t)ctx;
    if (gen == 0) {
        return;
    }
    pthread_mutex_lock(&g_lock);
    if (g_stopping || g_shell == NULL || !g_shell_owned || gen != g_gen || g_on_say == NULL) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    bsh_say_fn cb = g_on_say;
    void *cb_ctx = g_say_ctx;
    uint64_t reg = g_say_reg;
    g_in_flight += 1;
    g_say_current += 1;
    pthread_mutex_unlock(&g_lock);

    int outer = t_in_say;
    t_in_say = 1;
    cb(cb_ctx, json, json_len, bytes, bytes_len);
    t_in_say = outer;

    pthread_mutex_lock(&g_lock);
    if (reg == g_say_reg) {
        g_say_current -= 1;
    } else {
        g_say_stale -= 1;
        if (g_say_stale == 0) {
            pthread_cond_broadcast(&g_say_done);
        }
    }
    bsh_left_locked();
    pthread_mutex_unlock(&g_lock);
}

static uint8_t bsh_media_trampoline(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len) {
    uintptr_t gen = (uintptr_t)ctx;
    if (gen == 0) {
        return 0;
    }
    pthread_mutex_lock(&g_lock);
    if (g_stopping || g_shell == NULL || !g_shell_owned || gen != g_gen || g_on_media == NULL) {
        pthread_mutex_unlock(&g_lock);
        return 0;
    }
    bsh_media_fn cb = g_on_media;
    void *cb_ctx = g_media_ctx;
    uint64_t reg = g_media_reg;
    g_in_flight += 1;
    g_media_current += 1;
    pthread_mutex_unlock(&g_lock);

    int outer = t_in_media;
    t_in_media = 1;
    uint8_t taken = cb(cb_ctx, call, kind, key, seq, ts, bytes, bytes_len);
    t_in_media = outer;

    pthread_mutex_lock(&g_lock);
    if (reg == g_media_reg) {
        g_media_current -= 1;
    } else {
        g_media_stale -= 1;
        if (g_media_stale == 0) {
            pthread_cond_broadcast(&g_media_done);
        }
    }
    bsh_left_locked();
    pthread_mutex_unlock(&g_lock);
    return taken;
}

// Under `g_life`. Detach the current shell: wake blocked `bsh_wait` callers (they return NULL), wait for
// in-flight users, drop queued answers and the wake/say/media callbacks, then stop an owned shell outside `g_lock`.
static void bsh_stop_held(void) {
    pthread_mutex_lock(&g_lock);
    g_stopping = 1;
    (void)bsh_next_gen_locked();
    bsh_set_wake_locked(NULL, NULL);
    bsh_set_say_locked(NULL, NULL);
    bsh_set_media_locked(NULL, NULL);
    bsh_free_answers(bsh_take_queue_locked());
    while (g_in_flight > 0) {
        pthread_cond_wait(&g_in_flight_done, &g_lock);
    }
    bsh_answer_t *left = bsh_take_queue_locked();
    void *owned = g_shell_owned ? g_shell : NULL;
    g_shell = NULL;
    g_shell_owned = 0;
    pthread_mutex_unlock(&g_lock);
    bsh_free_answers(left);
    if (owned != NULL) {
        sf_shell_stop(owned);
    }
    pthread_mutex_lock(&g_lock);
    g_stopping = 0;
    pthread_mutex_unlock(&g_lock);
}

// Stop the started shell (or detach a shared one), dropping queued and late answers. Must not be called
// from a wake callback.
void bsh_stop(void) {
    bsh_refuse_in_wake("bsh_stop");
    pthread_mutex_lock(&g_life);
    bsh_stop_held();
    pthread_mutex_unlock(&g_life);
}

// Start the shell with data directory `dir_cstr` (NUL-terminated UTF-8): returns 1 on success, 0 on failure.
// A shell already started or attached is stopped first, and answers still queued (such as a not-started
// error of a call made while none ran) are dropped, so nothing from before reaches the new one.
int32_t bsh_start(const char *dir_cstr) {
    bsh_refuse_in_wake("bsh_start");
    pthread_mutex_lock(&g_life);
    pthread_mutex_lock(&g_lock);
    int there = g_shell != NULL;
    pthread_mutex_unlock(&g_lock);
    if (there) {
        bsh_stop_held();
    }
    pthread_mutex_lock(&g_lock);
    uintptr_t gen = bsh_next_gen_locked();
    bsh_answer_t *left = bsh_take_queue_locked();
    pthread_mutex_unlock(&g_lock);
    bsh_free_answers(left);
    const char *cdir = dir_cstr != NULL ? dir_cstr : "";
    struct stat was;
    int made = stat(cdir, &was) != 0;
    void *started = sf_shell_start(cdir, bsh_completed, (void *)gen);
    if (started != NULL) {
        if (made) {
            (void)chmod(cdir, 0700);
        }
        sf_shell_set_say(started, bsh_say_trampoline, (void *)gen);
        sf_shell_set_media(started, bsh_media_trampoline, (void *)gen);
    }
    pthread_mutex_lock(&g_lock);
    g_shell = started;
    g_shell_owned = started != NULL;
    // Double-clear any not-started answers enqueued while `sf_shell_start` was running.
    bsh_answer_t *stray = bsh_take_queue_locked();
    pthread_mutex_unlock(&g_lock);
    bsh_free_answers(stray);
    pthread_mutex_unlock(&g_life);
    return started != NULL ? 1 : 0;
}

// Share a shell handle already started by the host process (this side never stops it). A shell this side
// started is stopped first, and answers still queued are dropped.
void bsh_attach(void *started, void (*woke)(void *), void *ctx) {
    bsh_refuse_in_wake("bsh_attach");
    pthread_mutex_lock(&g_life);
    pthread_mutex_lock(&g_lock);
    int owned = g_shell_owned;
    pthread_mutex_unlock(&g_lock);
    if (owned) {
        bsh_stop_held();
    }
    pthread_mutex_lock(&g_lock);
    bsh_answer_t *left = bsh_take_queue_locked();
    g_shell = started;
    g_shell_owned = 0;
    bsh_set_wake_locked(woke, ctx);
    bsh_wait_stale_wakes_locked();
    pthread_mutex_unlock(&g_lock);
    bsh_free_answers(left);
    pthread_mutex_unlock(&g_life);
}

// Register a wake callback invoked after each answer is queued (and at once if answers wait), replacing the
// previous one. On return no call of a replaced callback runs (unless called from inside one), so a caller
// unregistering with `bsh_on_wake(NULL, NULL)` may free that callback's `ctx`.
void bsh_on_wake(void (*woke)(void *), void *ctx) {
    pthread_mutex_lock(&g_lock);
    bsh_set_wake_locked(woke, ctx);
    uint64_t reg = g_wake_reg;
    // Wait first, uncounted: a call counted while waiting could be moved to stale by a concurrent
    // `bsh_stop` and then wait for itself. Afterwards call at once only if still registered.
    bsh_wait_stale_wakes_locked();
    int has = woke != NULL && reg == g_wake_reg && g_first != NULL && !g_stopping;
    if (has) {
        bsh_wake_begin_locked();
    }
    pthread_mutex_unlock(&g_lock);
    if (has) {
        bsh_wake_run(woke, ctx, reg);
    }
}

// Register a pure-C direct `say` callback invoked from shell threads (`sf_shell_set_say`), replacing the
// previous one. On return no call of a replaced callback runs (unless called from inside one).
void bsh_on_say(bsh_say_fn say, void *ctx) {
    pthread_mutex_lock(&g_lock);
    bsh_set_say_locked(say, ctx);
    bsh_wait_stale_says_locked();
    pthread_mutex_unlock(&g_lock);
}

// Register a pure-C direct `media` callback invoked from shell threads (`sf_shell_set_media`), replacing the
// previous one. On return no call of a replaced callback runs (unless called from inside one).
void bsh_on_media(bsh_media_fn media, void *ctx) {
    pthread_mutex_lock(&g_lock);
    bsh_set_media_locked(media, ctx);
    bsh_wait_stale_medias_locked();
    pthread_mutex_unlock(&g_lock);
}

// Returns 1 if a shell handle is started or attached, else 0.
int32_t bsh_attached(void) {
    pthread_mutex_lock(&g_lock);
    int32_t there = (g_shell != NULL && !g_stopping) ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
    return there;
}

// Deliver an answer from a shared host shell when `id > BSH_ATTACHED_BASE`: returns 1 if queued, 0 if the
// id is not this side's or no shell is attached.
int32_t bsh_deliver(
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes) {
    if (id <= BSH_ATTACHED_BASE) {
        return 0;
    }
    return bsh_enqueue(bsh_frame(id, json, json_len, error, error_len, bytes, bytes_len, has_bytes), 0, 0);
}

// 1 if `call` is a whole number in [0, 2^64).
static int bsh_call_id(double call) {
    return call >= 0.0 && call < 18446744073709551616.0 && call == (double)(uint64_t)call;
}

// Acknowledge a screen frame of stream call `call` shown at `ts`: thread-safe, callable from any thread
// without the Pion runtime. Returns 1 if the shell took it, 0 otherwise.
int32_t bsh_screen_ack(double call, double ts) {
    if (!bsh_call_id(call)) {
        return 0;
    }
    void *sh = bsh_enter();
    if (sh == NULL) {
        return 0;
    }
    uint8_t ok = sf_shell_screen_ack(sh, (uint64_t)call, ts);
    bsh_leave();
    return ok ? 1 : 0;
}

// Send screen input JSON (`json`, `len` bytes) on stream call `call`: thread-safe like `bsh_screen_ack`.
int32_t bsh_screen_input(double call, const uint8_t *json, size_t len) {
    if (!bsh_call_id(call) || (json == NULL && len > 0)) {
        return 0;
    }
    void *sh = bsh_enter();
    if (sh == NULL) {
        return 0;
    }
    uint8_t ok = sf_shell_screen_input(sh, (uint64_t)call, json, len);
    bsh_leave();
    return ok ? 1 : 0;
}

// Free a heap buffer returned by `bsh_wait`, `bsh_ask`, or `bsh_random`.
void bsh_free(void *ptr) {
    free(ptr);
}

// Longest timed wait (100 years), so the deadline in nanoseconds cannot overflow.
#define BSH_WAIT_MAX_MS 3155760000000LL

static int64_t bsh_mono_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

// Pop the next queued answer as a malloc'd byte buffer (waiting at most `ms`; <0 blocks, 0 polls).
// Writes byte length to `*out_len` and returns NULL when no answer is available.
void *bsh_wait(int64_t ms, int64_t *out_len) {
    pthread_mutex_lock(&g_lock);
    uint64_t epoch = g_wait_epoch;
    if (g_first == NULL && ms != 0) {
        if (ms < 0) {
            while (g_first == NULL && epoch == g_wait_epoch) {
                pthread_cond_wait(bsh_came(), &g_lock);
            }
        } else {
            // Deadline on the monotonic clock, so a wall-clock jump neither shortens nor stretches the wait.
            int64_t capped = ms > BSH_WAIT_MAX_MS ? BSH_WAIT_MAX_MS : ms;
            int64_t until_ns = bsh_mono_ns() + capped * 1000000;
            while (g_first == NULL && epoch == g_wait_epoch) {
                int64_t left = until_ns - bsh_mono_ns();
                if (left <= 0) {
                    break;
                }
#ifdef __APPLE__
                struct timespec rel = {(time_t)(left / 1000000000), (long)(left % 1000000000)};
                (void)pthread_cond_timedwait_relative_np(bsh_came(), &g_lock, &rel);
#else
                struct timespec until = {(time_t)(until_ns / 1000000000), (long)(until_ns % 1000000000)};
                (void)pthread_cond_timedwait(bsh_came(), &g_lock, &until);
#endif
            }
        }
    }
    bsh_answer_t *a = epoch == g_wait_epoch ? g_first : NULL;
    if (a != NULL) {
        g_first = a->next;
        if (g_first == NULL) {
            g_last = NULL;
        }
    }
    pthread_mutex_unlock(&g_lock);
    if (a == NULL) {
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    void *out = malloc(a->len);
    if (out == NULL) {
        abort();
    }
    memcpy(out, a->data, a->len);
    if (out_len != NULL) {
        *out_len = (int64_t)a->len;
    }
    free(a);
    return out;
}

// Issue an async shell call using raw C-ABI pointers.
void bsh_call(
    int64_t id,
    const char *op_cstr,
    const uint8_t *json_ptr,
    int64_t json_len,
    const uint8_t *payload_ptr,
    int64_t payload_len,
    int32_t has) {
    void *sh = bsh_enter();
    if (sh == NULL) {
        static const char none[] = "the shell is not started";
        (void)bsh_enqueue(bsh_frame((uint64_t)id, NULL, 0, (const uint8_t *)none, sizeof(none) - 1, NULL, 0, 0), 0, 1);
        return;
    }
    const char *cop = op_cstr != NULL ? op_cstr : "";
    size_t jlen = json_len > 0 ? (size_t)json_len : 0;
    size_t plen = payload_len > 0 ? (size_t)payload_len : 0;
    sf_shell_call(sh, (uint64_t)id, cop, json_ptr, jlen, payload_ptr, plen, has ? 1 : 0);
    bsh_leave();
}

// Issue a synchronous shell ask: returns malloc'd JSON `{"value":...}` or `{"error":...}`
// and writes its length into `*out_len`. Caller frees with `bsh_free`.
void *bsh_ask(const char *op_cstr, const uint8_t *json_ptr, int64_t json_len, int64_t *out_len) {
    void *sh = bsh_enter();
    if (sh == NULL) {
        static const char none[] = "{\"error\":\"the shell is not started\"}";
        size_t n = sizeof(none) - 1;
        void *out = malloc(n);
        if (out == NULL) {
            abort();
        }
        memcpy(out, none, n);
        if (out_len != NULL) {
            *out_len = (int64_t)n;
        }
        return out;
    }
    const char *cop = op_cstr != NULL ? op_cstr : "";
    size_t jlen = json_len > 0 ? (size_t)json_len : 0;
    size_t ans_len = 0;
    uint8_t *answer = sf_shell_call_sync(sh, cop, json_ptr, jlen, &ans_len);
    bsh_leave();
    if (ans_len == 0 || answer == NULL) {
        sf_free(answer, ans_len);
        if (out_len != NULL) {
            *out_len = 0;
        }
        return NULL;
    }
    void *out = malloc(ans_len);
    if (out == NULL) {
        abort();
    }
    memcpy(out, answer, ans_len);
    sf_free(answer, ans_len);
    if (out_len != NULL) {
        *out_len = (int64_t)ans_len;
    }
    return out;
}

// Monotonic clock in milliseconds.
int64_t bsh_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

// `n` bytes of OS cryptographic randomness returned as a malloc'd buffer (freed with `bsh_free`).
void *bsh_random(int32_t n) {
    if (n <= 0) {
        return NULL;
    }
    uint8_t *out = (uint8_t *)malloc((size_t)n);
    if (out == NULL) {
        abort();
    }
#ifdef __linux__
    size_t done = 0;
    while (done < (size_t)n) {
        ssize_t got = getrandom(out + done, (size_t)n - done, 0);
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            abort();
        }
        done += (size_t)got;
    }
#else
    arc4random_buf(out, (size_t)n);
#endif
    return (void *)out;
}
