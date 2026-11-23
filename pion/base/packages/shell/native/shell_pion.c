// Native C bridge between Pion (`extern "C"`) and the Rust shell C ABI (`sf_shell_*`).
// Answers arrive on shell worker threads, are queued here under a mutex, and drained on
// the Pion runtime's own thread via `bsh_wait` / `Shell::pump`. Nothing here invokes Pion
// callbacks from foreign threads.

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#ifdef __linux__
#include <sys/random.h>
#endif

// Rust shell C ABI (client/shell/src/lib.rs).
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

// Framed answer record: [id:8 le][kind:1][text_len:4 le][text][bytes]
typedef struct bsh_answer {
    struct bsh_answer *next;
    size_t len;
    uint8_t data[];
} bsh_answer_t;

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_came = PTHREAD_COND_INITIALIZER;
static bsh_answer_t *g_first = NULL;
static bsh_answer_t *g_last = NULL;
static void *g_shell = NULL;
static void (*g_on_wake)(void *) = NULL;
static void *g_wake_ctx = NULL;

// Shared-shell call ID offset (2^40, exact in IEEE-754 double / JSON).
#define BSH_ATTACHED_BASE (1ULL << 40)

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
    (void)ctx;
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
    pthread_mutex_lock(&g_lock);
    if (g_last != NULL) {
        g_last->next = a;
    } else {
        g_first = a;
    }
    g_last = a;
    pthread_cond_signal(&g_came);
    void (*woke)(void *) = g_on_wake;
    void *wctx = g_wake_ctx;
    pthread_mutex_unlock(&g_lock);
    if (woke != NULL) {
        woke(wctx);
    }
}

// Start the shell with data directory `dir_cstr` (NUL-terminated UTF-8): returns 1 on success, 0 on failure.
int32_t bsh_start(const char *dir_cstr) {
    pthread_mutex_lock(&g_lock);
    int already = g_shell != NULL;
    pthread_mutex_unlock(&g_lock);
    if (already) {
        return 1;
    }
    const char *cdir = dir_cstr != NULL ? dir_cstr : "";
    struct stat was;
    int made = stat(cdir, &was) != 0;
    void *started = sf_shell_start(cdir, bsh_completed, NULL);
    if (started != NULL && made) {
        (void)chmod(cdir, 0700);
    }
    pthread_mutex_lock(&g_lock);
    g_shell = started;
    pthread_mutex_unlock(&g_lock);
    return started != NULL ? 1 : 0;
}

// Share a shell handle already started by the host process.
void bsh_attach(void *started, void (*woke)(void *), void *ctx) {
    pthread_mutex_lock(&g_lock);
    g_shell = started;
    g_on_wake = woke;
    g_wake_ctx = ctx;
    pthread_mutex_unlock(&g_lock);
}

// Register a wake callback invoked after each answer is queued (and immediately if non-empty).
void bsh_on_wake(void (*woke)(void *), void *ctx) {
    pthread_mutex_lock(&g_lock);
    g_on_wake = woke;
    g_wake_ctx = ctx;
    int has = (g_first != NULL && woke != NULL);
    pthread_mutex_unlock(&g_lock);
    if (has) {
        woke(ctx);
    }
}

// Returns 1 if a shell handle is started or attached, else 0.
int32_t bsh_attached(void) {
    pthread_mutex_lock(&g_lock);
    int32_t there = g_shell != NULL ? 1 : 0;
    pthread_mutex_unlock(&g_lock);
    return there;
}

// Deliver an answer from a shared host shell when `id > BSH_ATTACHED_BASE`.
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
    bsh_completed(NULL, id, json, json_len, error, error_len, bytes, bytes_len, has_bytes);
    return 1;
}

// Free a heap buffer returned by `bsh_wait`, `bsh_ask`, or `bsh_random`.
void bsh_free(void *ptr) {
    free(ptr);
}

// Pop the next queued answer as a malloc'd byte buffer (waiting at most `ms`; <0 blocks, 0 polls).
// Writes byte length to `*out_len` and returns NULL when no answer is available.
void *bsh_wait(int64_t ms, int64_t *out_len) {
    pthread_mutex_lock(&g_lock);
    if (g_first == NULL && ms != 0) {
        if (ms < 0) {
            while (g_first == NULL) {
                pthread_cond_wait(&g_came, &g_lock);
            }
        } else {
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_sec += ms / 1000;
            until.tv_nsec += (ms % 1000) * 1000000;
            if (until.tv_nsec >= 1000000000) {
                until.tv_sec += 1;
                until.tv_nsec -= 1000000000;
            }
            while (g_first == NULL && pthread_cond_timedwait(&g_came, &g_lock, &until) != ETIMEDOUT) {
            }
        }
    }
    bsh_answer_t *a = g_first;
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
    pthread_mutex_lock(&g_lock);
    void *sh = g_shell;
    pthread_mutex_unlock(&g_lock);
    if (sh == NULL) {
        static const char none[] = "the shell is not started";
        bsh_completed(NULL, (uint64_t)id, NULL, 0, (const uint8_t *)none, sizeof(none) - 1, NULL, 0, 0);
        return;
    }
    const char *cop = op_cstr != NULL ? op_cstr : "";
    size_t jlen = json_len > 0 ? (size_t)json_len : 0;
    size_t plen = payload_len > 0 ? (size_t)payload_len : 0;
    sf_shell_call(sh, (uint64_t)id, cop, json_ptr, jlen, payload_ptr, plen, has ? 1 : 0);
}

// Issue a synchronous shell ask: returns malloc'd JSON `{"value":...}` or `{"error":...}`
// and writes its length into `*out_len`. Caller frees with `bsh_free`.
void *bsh_ask(const char *op_cstr, const uint8_t *json_ptr, int64_t json_len, int64_t *out_len) {
    pthread_mutex_lock(&g_lock);
    void *sh = g_shell;
    pthread_mutex_unlock(&g_lock);
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
