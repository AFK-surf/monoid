// Standalone C ABI signature, queue, lifecycle and thread-safety test for shell_pion.c (compiled with mock
// sf_shell_*). Run under `-fsanitize=thread` and `-fsanitize=address,undefined` as well as plain.
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

// Declarations from shell_pion.c
extern int32_t bsh_start(const char *dir_cstr);
extern void bsh_stop(void);
extern void bsh_attach(void *started, void (*woke)(void *), void *ctx);
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

extern void bsh_on_wake(void (*woke)(void *), void *ctx);
extern void bsh_on_say(bsh_say_fn say, void *ctx);
extern void bsh_on_media(bsh_media_fn media, void *ctx);
extern int32_t bsh_attached(void);
extern int32_t bsh_deliver(
    uint64_t id,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *error,
    size_t error_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes);
extern void bsh_free(void *ptr);
extern void *bsh_wait(int64_t ms, int64_t *out_len);
extern void bsh_call(
    int64_t id,
    const char *op_cstr,
    const uint8_t *json_ptr,
    int64_t json_len,
    const uint8_t *payload_ptr,
    int64_t payload_len,
    int32_t has);
extern void *bsh_ask(const char *op_cstr, const uint8_t *json_ptr, int64_t json_len, int64_t *out_len);
extern int32_t bsh_screen_ack(double call, double ts);
extern int32_t bsh_screen_input(double call, const uint8_t *json, size_t len);
extern int64_t bsh_now(void);
extern void *bsh_random(int32_t n);

#define CHECK(cond)                                                                    \
    do {                                                                               \
        if (!(cond)) {                                                                 \
            fprintf(stderr, "shell_abi_test: %s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
            abort();                                                                   \
        }                                                                              \
    } while (0)

// Mock Rust shell C ABI: each started shell is a heap handle; `sf_shell_stop` aborts if any call is still
// inside it and poisons then frees it, so a use after stop is caught (ASan) or aborts (magic check).
typedef void (*sf_complete)(
    void *, uint64_t, const uint8_t *, size_t, const uint8_t *, size_t, const uint8_t *, size_t, uint8_t);

#define MOCK_MAGIC 0x5348454c4cULL

typedef struct mock_shell {
    uint64_t magic;
    sf_complete cb;
    void *ctx;
    bsh_say_fn say_cb;
    void *say_ctx;
    bsh_media_fn media_cb;
    void *media_ctx;
    atomic_int inside;
} mock_shell_t;

static pthread_mutex_t g_mock_last_lock = PTHREAD_MUTEX_INITIALIZER;
static mock_shell_t *g_last_mock_shell = NULL;

static atomic_int g_started = 0;
static atomic_int g_stopped = 0;
static atomic_llong g_acks_seen = 0;
static atomic_llong g_inputs_seen = 0;
static int g_wake_count = 0;
static int g_external_handle = 42;

// A deferred answer of a chosen shell, released by the test (deterministic: no sleeps).
static pthread_mutex_t g_slow_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_slow_cond = PTHREAD_COND_INITIALIZER;
static int g_slow_go = 0;
static pthread_t g_slow_thread;
static sf_complete g_slow_cb = NULL;
static void *g_slow_ctx = NULL;
static uint64_t g_slow_id = 0;

static mock_shell_t *live(const void *shell) {
    mock_shell_t *m = (mock_shell_t *)shell;
    CHECK(m != NULL && m->magic == MOCK_MAGIC);
    return m;
}

void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx) {
    CHECK(data_dir != NULL);
    CHECK(ctx != NULL);
    mock_shell_t *m = (mock_shell_t *)calloc(1, sizeof(*m));
    CHECK(m != NULL);
    m->magic = MOCK_MAGIC;
    m->cb = complete;
    m->ctx = ctx;
    atomic_init(&m->inside, 0);
    atomic_fetch_add(&g_started, 1);
    pthread_mutex_lock(&g_mock_last_lock);
    g_last_mock_shell = m;
    pthread_mutex_unlock(&g_mock_last_lock);
    return m;
}

void sf_shell_set_say(const void *shell, bsh_say_fn say, void *ctx) {
    mock_shell_t *m = live(shell);
    m->say_cb = say;
    m->say_ctx = ctx;
}

void sf_shell_set_media(const void *shell, bsh_media_fn media, void *ctx) {
    mock_shell_t *m = live(shell);
    m->media_cb = media;
    m->media_ctx = ctx;
}

void sf_shell_stop(void *shell) {
    mock_shell_t *m = live(shell);
    pthread_mutex_lock(&g_mock_last_lock);
    if (g_last_mock_shell == m) {
        g_last_mock_shell = NULL;
    }
    pthread_mutex_unlock(&g_mock_last_lock);
    if (atomic_load(&m->inside) != 0) {
        fprintf(stderr, "shell_abi_test: sf_shell_stop with %d call(s) in flight\n", atomic_load(&m->inside));
        abort();
    }
    m->magic = 0;
    free(m);
    atomic_fetch_add(&g_stopped, 1);
}

static void *slow_answer(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_slow_lock);
    while (!g_slow_go) {
        pthread_cond_wait(&g_slow_cond, &g_slow_lock);
    }
    pthread_mutex_unlock(&g_slow_lock);
    const char *reply = "STALE_OLD_REPLY";
    g_slow_cb(g_slow_ctx, g_slow_id, (const uint8_t *)reply, strlen(reply), NULL, 0, NULL, 0, 0);
    return NULL;
}

void sf_shell_call(
    const void *shell,
    uint64_t id,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len,
    uint8_t has_bytes) {
    mock_shell_t *m = live(shell);
    atomic_fetch_add(&m->inside, 1);
    CHECK(op != NULL);
    (void)json;
    (void)json_len;
    if (strcmp(op, "slow") == 0) {
        // Answer later from another thread, as a shell worker would, possibly after this shell stopped.
        g_slow_cb = m->cb;
        g_slow_ctx = m->ctx;
        g_slow_id = id;
        CHECK(pthread_create(&g_slow_thread, NULL, slow_answer, NULL) == 0);
    } else {
        const char *reply = strcmp(op, "fresh") == 0 ? "FRESH_NEW_REPLY" : "{\"ok\":true}";
        m->cb(m->ctx, id, (const uint8_t *)reply, strlen(reply), NULL, 0, bytes, bytes_len, has_bytes);
    }
    atomic_fetch_sub(&m->inside, 1);
}

uint8_t *sf_shell_call_sync(
    const void *shell,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    size_t *out_len) {
    mock_shell_t *m = live(shell);
    atomic_fetch_add(&m->inside, 1);
    CHECK(op != NULL);
    (void)json;
    (void)json_len;
    const char *resp = "{\"value\":123}";
    size_t n = strlen(resp);
    uint8_t *buf = (uint8_t *)malloc(n);
    CHECK(buf != NULL);
    memcpy(buf, resp, n);
    *out_len = n;
    atomic_fetch_sub(&m->inside, 1);
    return buf;
}

uint8_t sf_shell_screen_ack(const void *shell, uint64_t call, double ts) {
    mock_shell_t *m = live(shell);
    atomic_fetch_add(&m->inside, 1);
    sched_yield();
    CHECK(live(shell) == m);
    CHECK(call < 1000 && ts == (double)call + 0.5);
    atomic_fetch_add(&g_acks_seen, 1);
    atomic_fetch_sub(&m->inside, 1);
    return 1;
}

uint8_t sf_shell_screen_input(const void *shell, uint64_t call, const uint8_t *json, size_t len) {
    mock_shell_t *m = live(shell);
    atomic_fetch_add(&m->inside, 1);
    sched_yield();
    CHECK(live(shell) == m);
    CHECK(call < 1000 && json != NULL && len == 7 && memcmp(json, "{\"k\":1}", 7) == 0);
    atomic_fetch_add(&g_inputs_seen, 1);
    atomic_fetch_sub(&m->inside, 1);
    return 1;
}

void sf_free(uint8_t *ptr, size_t len) {
    (void)len;
    free(ptr);
}

static void on_wake_cb(void *ctx) {
    (void)ctx;
    g_wake_count += 1;
}

static void test_basics(void) {
    CHECK(bsh_attached() == 0);
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    CHECK(bsh_attached() == 1);

    bsh_on_wake(on_wake_cb, NULL);
    bsh_call(7, "echo", (const uint8_t *)"{}", 2, (const uint8_t *)"AB", 2, 1);
    CHECK(g_wake_count == 1);

    int64_t ans_len = 0;
    uint8_t *ans = (uint8_t *)bsh_wait(0, &ans_len);
    CHECK(ans != NULL);
    CHECK(ans_len == 13 + 11 + 2);
    CHECK(ans[0] == 7 && ans[8] == 1 && ans[9] == 11);
    bsh_free(ans);

    int64_t sync_len = 0;
    uint8_t *sync_ans = (uint8_t *)bsh_ask("echo", (const uint8_t *)"{}", 2, &sync_len);
    CHECK(sync_ans != NULL);
    CHECK(sync_len == 13 && memcmp(sync_ans, "{\"value\":123}", 13) == 0);
    bsh_free(sync_ans);

    // bsh_deliver filters ids <= 2^40 and queues ids > 2^40
    CHECK(bsh_deliver(100, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 0);
    uint64_t high_id = (1ULL << 40) + 5;
    CHECK(bsh_deliver(high_id, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    int64_t ans2_len = 0;
    uint8_t *ans2 = (uint8_t *)bsh_wait(0, &ans2_len);
    CHECK(ans2 != NULL && ans2_len == 15);
    bsh_free(ans2);

    CHECK(bsh_now() > 0);
    uint8_t *rnd = (uint8_t *)bsh_random(32);
    CHECK(rnd != NULL);
    bsh_free(rnd);

    // Attaching a host shell stops the one started here; this side never stops the host's.
    int stopped = atomic_load(&g_stopped);
    bsh_attach(&g_external_handle, NULL, NULL);
    CHECK(bsh_attached() == 1);
    CHECK(atomic_load(&g_stopped) == stopped + 1);
    CHECK(bsh_deliver(high_id, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    bsh_stop();
    CHECK(atomic_load(&g_stopped) == stopped + 1);
    CHECK(bsh_attached() == 0);
    CHECK(bsh_wait(0, NULL) == NULL);
    CHECK(bsh_deliver(high_id, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 0);

    // Without a shell: calls answer an error locally, asks an error envelope, screen ops refuse.
    bsh_call(9, "echo", NULL, 0, NULL, 0, 0);
    int64_t err_len = 0;
    uint8_t *err = (uint8_t *)bsh_wait(0, &err_len);
    CHECK(err != NULL && err[0] == 9 && err[8] == 2);
    bsh_free(err);
    int64_t none_len = 0;
    uint8_t *none = (uint8_t *)bsh_ask("echo", NULL, 0, &none_len);
    CHECK(none != NULL && none_len > 0 && memcmp(none, "{\"error\"", 8) == 0);
    bsh_free(none);
    CHECK(bsh_screen_ack(1, 1.5) == 0);
    CHECK(bsh_screen_input(1, (const uint8_t *)"{\"k\":1}", 7) == 0);
}

// Gate: an answer of a stopped shell that comes after a restart never reaches the new shell's same id.
static void test_restart_drops_late_answers(void) {
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    bsh_call(1, "slow", NULL, 0, NULL, 0, 0);
    bsh_stop();
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    bsh_call(1, "fresh", NULL, 0, NULL, 0, 0);
    pthread_mutex_lock(&g_slow_lock);
    g_slow_go = 1;
    pthread_cond_broadcast(&g_slow_cond);
    pthread_mutex_unlock(&g_slow_lock);
    CHECK(pthread_join(g_slow_thread, NULL) == 0);

    int64_t len = 0;
    uint8_t *got = (uint8_t *)bsh_wait(0, &len);
    CHECK(got != NULL && got[0] == 1 && got[8] == 0 && got[9] == 15);
    CHECK(len == 13 + 15 && memcmp(got + 13, "FRESH_NEW_REPLY", 15) == 0);
    bsh_free(got);
    CHECK(bsh_wait(20, &len) == NULL && len == 0);

    // A not-started error queued while no shell ran never reaches the next shell's call of the same id.
    bsh_stop();
    bsh_call(7, "echo", NULL, 0, NULL, 0, 0);
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    bsh_call(7, "fresh", NULL, 0, NULL, 0, 0);
    got = (uint8_t *)bsh_wait(0, &len);
    CHECK(got != NULL && got[0] == 7 && got[8] == 0 && len == 13 + 15 && memcmp(got + 13, "FRESH_NEW_REPLY", 15) == 0);
    bsh_free(got);
    CHECK(bsh_wait(20, &len) == NULL && len == 0);

    // Restarting without an explicit stop also drops what the old shell queued.
    bsh_call(2, "echo", NULL, 0, NULL, 0, 0);
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    CHECK(bsh_wait(0, NULL) == NULL);
    bsh_stop();
}

// A blocked `bsh_wait` returns NULL when the shell stops.
static atomic_int g_wait_done = 0;
static atomic_int g_wait_got_null = 0;

static void *blocked_wait(void *arg) {
    (void)arg;
    int64_t len = -1;
    void *got = bsh_wait(-1, &len);
    atomic_store(&g_wait_got_null, got == NULL && len == 0);
    atomic_store(&g_wait_done, 1);
    return NULL;
}

static void test_stop_wakes_waiters(void) {
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    pthread_t t;
    CHECK(pthread_create(&t, NULL, blocked_wait, NULL) == 0);
    // The waiter may block before or after any one stop: stop until it has returned.
    while (!atomic_load(&g_wait_done)) {
        bsh_stop();
        sched_yield();
    }
    CHECK(pthread_join(t, NULL) == 0);
    CHECK(atomic_load(&g_wait_got_null));
}

// A timed wait with nothing queued lasts its whole timeout (monotonic deadline) and returns NULL.
static void test_timed_wait(void) {
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    int64_t t0 = bsh_now();
    int64_t len = -1;
    CHECK(bsh_wait(30, &len) == NULL && len == 0);
    CHECK(bsh_now() - t0 >= 30);
    bsh_stop();
}

// W26b P2: `bsh_wait(INT64_MAX)` must clamp cleanly without signed overflow under UBSan.
static atomic_int g_max_wait_done = 0;
static atomic_int g_max_wait_ok = 0;

static void *wait_max_thread(void *arg) {
    (void)arg;
    int64_t len = -1;
    void *got = bsh_wait(INT64_MAX, &len);
    atomic_store(&g_max_wait_ok, got == NULL && len == 0);
    atomic_store(&g_max_wait_done, 1);
    return NULL;
}

static void test_wait_max_no_overflow(void) {
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    atomic_store(&g_max_wait_done, 0);
    atomic_store(&g_max_wait_ok, 0);
    pthread_t t;
    CHECK(pthread_create(&t, NULL, wait_max_thread, NULL) == 0);
    while (!atomic_load(&g_max_wait_done)) {
        bsh_stop();
        sched_yield();
    }
    CHECK(pthread_join(t, NULL) == 0);
    CHECK(atomic_load(&g_max_wait_ok));
}

// Pure-C `bsh_on_say` / `bsh_on_media` cross-thread delivery, stale-gen filtering, and safe unregistration.
typedef struct media_say_ctx {
    atomic_int says;
    atomic_int medias;
} media_say_ctx_t;

static void test_say_cb(
    void *ctx,
    const uint8_t *json,
    size_t json_len,
    const uint8_t *bytes,
    size_t bytes_len) {
    media_say_ctx_t *m = (media_say_ctx_t *)ctx;
    CHECK(json != NULL && json_len == 11 && memcmp(json, "{\"say\":123}", 11) == 0);
    CHECK(bytes != NULL && bytes_len == 3 && memcmp(bytes, "RAW", 3) == 0);
    atomic_fetch_add(&m->says, 1);
}

static uint8_t test_media_cb(
    void *ctx,
    uint64_t call,
    uint8_t kind,
    uint8_t key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t bytes_len) {
    media_say_ctx_t *m = (media_say_ctx_t *)ctx;
    CHECK(call == 7 && kind == 2 && key == 1 && seq > 0 && ts == 900);
    CHECK(bytes != NULL && bytes_len == 4 && memcmp(bytes, "AV1!", 4) == 0);
    atomic_fetch_add(&m->medias, 1);
    return 1;
}

typedef struct media_emitter_args {
    bsh_say_fn say_trampoline;
    void *say_gen;
    bsh_media_fn media_trampoline;
    void *media_gen;
    int rounds;
} media_emitter_args_t;

static void *emit_media_and_say_worker(void *arg) {
    media_emitter_args_t *a = (media_emitter_args_t *)arg;
    for (int i = 1; i <= a->rounds; i++) {
        a->say_trampoline(a->say_gen, (const uint8_t *)"{\"say\":123}", 11, (const uint8_t *)"RAW", 3);
        (void)a->media_trampoline(a->media_gen, 7, 2, 1, (uint64_t)i, 900, (const uint8_t *)"AV1!", 4);
    }
    return NULL;
}

static void test_say_and_media_across_restarts(void) {
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    media_say_ctx_t *ctx = (media_say_ctx_t *)calloc(1, sizeof(*ctx));
    CHECK(ctx != NULL);
    bsh_on_say(test_say_cb, ctx);
    bsh_on_media(test_media_cb, ctx);

    pthread_mutex_lock(&g_mock_last_lock);
    mock_shell_t *m = g_last_mock_shell;
    CHECK(m != NULL && m->say_cb != NULL && m->media_cb != NULL);
    media_emitter_args_t args = {m->say_cb, m->say_ctx, m->media_cb, m->media_ctx, 200};
    pthread_mutex_unlock(&g_mock_last_lock);

    pthread_t w1, w2;
    CHECK(pthread_create(&w1, NULL, emit_media_and_say_worker, &args) == 0);
    CHECK(pthread_create(&w2, NULL, emit_media_and_say_worker, &args) == 0);
    CHECK(pthread_join(w1, NULL) == 0);
    CHECK(pthread_join(w2, NULL) == 0);
    CHECK(atomic_load(&ctx->says) == 400);
    CHECK(atomic_load(&ctx->medias) == 400);

    // Stop shell and verify stale-generation callbacks from old shell are dropped (return 0 / no-op).
    bsh_stop();
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    bsh_on_say(test_say_cb, ctx);
    bsh_on_media(test_media_cb, ctx);
    args.say_trampoline(args.say_gen, (const uint8_t *)"{\"say\":123}", 11, (const uint8_t *)"RAW", 3);
    CHECK(args.media_trampoline(args.media_gen, 7, 2, 1, 999, 900, (const uint8_t *)"AV1!", 4) == 0);
    CHECK(atomic_load(&ctx->says) == 400);
    CHECK(atomic_load(&ctx->medias) == 400);

    // Unregistering waits for any in-flight callback so freeing ctx immediately is ASan/TSAN-safe.
    bsh_on_media(NULL, NULL);
    bsh_on_say(NULL, NULL);
    free(ctx);
    bsh_stop();
}

// A wake callback held inside until released; it writes into its heap ctx after release, so a caller that
// frees ctx too early is caught by ASan.
typedef struct held_wake {
    pthread_mutex_t lock;
    pthread_cond_t cond;
    int entered;
    int release;
    int calls;
} held_wake_t;

static held_wake_t *held_new(void) {
    held_wake_t *h = (held_wake_t *)calloc(1, sizeof(*h));
    CHECK(h != NULL);
    pthread_mutex_init(&h->lock, NULL);
    pthread_cond_init(&h->cond, NULL);
    return h;
}

static void held_free(held_wake_t *h) {
    pthread_mutex_destroy(&h->lock);
    pthread_cond_destroy(&h->cond);
    h->calls = -1;
    free(h);
}

static void held_wake(void *ctx) {
    held_wake_t *h = (held_wake_t *)ctx;
    pthread_mutex_lock(&h->lock);
    h->entered = 1;
    pthread_cond_broadcast(&h->cond);
    while (!h->release) {
        pthread_cond_wait(&h->cond, &h->lock);
    }
    pthread_mutex_unlock(&h->lock);
    sched_yield();
    h->calls += 1;
}

static void held_await_entered(held_wake_t *h) {
    pthread_mutex_lock(&h->lock);
    while (!h->entered) {
        pthread_cond_wait(&h->cond, &h->lock);
    }
    pthread_mutex_unlock(&h->lock);
}

static void held_release(held_wake_t *h) {
    pthread_mutex_lock(&h->lock);
    h->release = 1;
    pthread_cond_broadcast(&h->cond);
    pthread_mutex_unlock(&h->lock);
}

static atomic_int g_unreg_returned = 0;
static atomic_int g_registering = 0;
static atomic_int g_stopping_now = 0;

static void *deliver_one(void *arg) {
    (void)arg;
    CHECK(bsh_deliver((1ULL << 40) + 1, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    return NULL;
}

static void *unregister_wake(void *arg) {
    (void)arg;
    bsh_on_wake(NULL, NULL);
    atomic_store(&g_unreg_returned, 1);
    return NULL;
}

static void *stop_shell(void *arg) {
    (void)arg;
    atomic_store(&g_stopping_now, 1);
    bsh_stop();
    atomic_store(&g_unreg_returned, 1);
    return NULL;
}

static void counting_wake(void *ctx) {
    *(int *)ctx += 1;
}

static void *register_counting(void *arg) {
    atomic_store(&g_registering, 1);
    bsh_on_wake(counting_wake, arg);
    return NULL;
}

static void *register_held(void *arg) {
    bsh_on_wake(held_wake, arg);
    return NULL;
}

// Inside a wake callback, replacing the callback does not wait for itself.
static int g_reentrant_calls = 0;
static void reentrant_wake(void *ctx) {
    (void)ctx;
    g_reentrant_calls += 1;
    bsh_on_wake(NULL, NULL);
}

static void test_wake_unregister(void) {
    int64_t len = 0;
    // Unregistering waits for a running call of the old callback, so its ctx may be freed at once.
    bsh_attach(&g_external_handle, NULL, NULL);
    held_wake_t *h = held_new();
    bsh_on_wake(held_wake, h);
    pthread_t d;
    CHECK(pthread_create(&d, NULL, deliver_one, NULL) == 0);
    held_await_entered(h);
    atomic_store(&g_unreg_returned, 0);
    pthread_t u;
    CHECK(pthread_create(&u, NULL, unregister_wake, NULL) == 0);
    for (int i = 0; i < 100; i++) {
        sched_yield();
    }
    CHECK(atomic_load(&g_unreg_returned) == 0);
    held_release(h);
    CHECK(pthread_join(u, NULL) == 0);
    CHECK(h->calls == 1);
    held_free(h);
    CHECK(pthread_join(d, NULL) == 0);
    void *got = bsh_wait(0, &len);
    CHECK(got != NULL);
    bsh_free(got);

    // The immediate call of a newly registered callback (answers waiting) is waited for by bsh_stop too.
    bsh_attach(&g_external_handle, NULL, NULL);
    CHECK(bsh_deliver((1ULL << 40) + 3, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    h = held_new();
    pthread_t w, r;
    CHECK(pthread_create(&w, NULL, register_held, h) == 0);
    held_await_entered(h);
    atomic_store(&g_unreg_returned, 0);
    CHECK(pthread_create(&r, NULL, stop_shell, NULL) == 0);
    for (int i = 0; i < 100; i++) {
        sched_yield();
    }
    CHECK(atomic_load(&g_unreg_returned) == 0);
    held_release(h);
    CHECK(pthread_join(r, NULL) == 0);
    CHECK(pthread_join(w, NULL) == 0);
    CHECK(h->calls == 1);
    held_free(h);

    // Three threads: one inside the old callback, one replacing it while answers wait, one stopping. The
    // replacer must not count its own immediate call while waiting, or the stop would wait on it forever.
    alarm(10); // a deadlock here fails the run (SIGALRM) instead of hanging it
    bsh_attach(&g_external_handle, NULL, NULL);
    h = held_new();
    bsh_on_wake(held_wake, h);
    CHECK(pthread_create(&d, NULL, deliver_one, NULL) == 0);
    held_await_entered(h);
    static int new_calls = 0;
    pthread_t n;
    CHECK(pthread_create(&n, NULL, register_counting, &new_calls) == 0);
    while (!atomic_load(&g_registering)) {
        sched_yield();
    }
    for (int i = 0; i < 1000; i++) {
        sched_yield();
    }
    atomic_store(&g_stopping_now, 0);
    CHECK(pthread_create(&r, NULL, stop_shell, NULL) == 0);
    while (!atomic_load(&g_stopping_now)) {
        sched_yield();
    }
    for (int i = 0; i < 1000; i++) {
        sched_yield();
    }
    held_release(h);
    CHECK(pthread_join(d, NULL) == 0);
    CHECK(pthread_join(n, NULL) == 0);
    CHECK(pthread_join(r, NULL) == 0);
    alarm(0);
    CHECK(h->calls == 1);
    held_free(h);
    CHECK(bsh_wait(0, NULL) == NULL);

    // Re-entrant replacement from inside a callback returns at once.
    bsh_attach(&g_external_handle, NULL, NULL);
    bsh_on_wake(reentrant_wake, NULL);
    CHECK(bsh_deliver((1ULL << 40) + 4, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    CHECK(g_reentrant_calls == 1);
    CHECK(bsh_deliver((1ULL << 40) + 5, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    CHECK(g_reentrant_calls == 1);
    bsh_stop();
}

// Gate: foreign threads hammer the screen ops while the shell restarts; none touches a stopped handle
// (the mock aborts on a stop with an op inside), and every op that reported success reached a live shell.
#define SCREEN_THREADS 4
#define SCREEN_ROUNDS 600

static atomic_int g_screen_go = 0;
static atomic_llong g_acks_ok = 0;
static atomic_llong g_inputs_ok = 0;
static atomic_int g_hammers_done = 0;

// Each hammer keeps going until SCREEN_ROUNDS acks and SCREEN_ROUNDS inputs of its own got through.
static void *screen_hammer(void *arg) {
    (void)arg;
    while (!atomic_load(&g_screen_go)) {
        sched_yield();
    }
    int acks = 0;
    int inputs = 0;
    for (int i = 0; acks < SCREEN_ROUNDS || inputs < SCREEN_ROUNDS; i++) {
        double call = (double)(i % 1000);
        if (acks < SCREEN_ROUNDS && bsh_screen_ack(call, call + 0.5)) {
            acks++;
            atomic_fetch_add(&g_acks_ok, 1);
        }
        if (inputs < SCREEN_ROUNDS && bsh_screen_input(call, (const uint8_t *)"{\"k\":1}", 7)) {
            inputs++;
            atomic_fetch_add(&g_inputs_ok, 1);
        }
    }
    atomic_fetch_add(&g_hammers_done, 1);
    return NULL;
}

static void test_screen_ops_across_restarts(void) {
    CHECK(bsh_screen_ack(-1, 0) == 0);
    CHECK(bsh_screen_ack(1.5, 0) == 0);
    CHECK(bsh_screen_input(1, NULL, 3) == 0);
    long long acks_before = atomic_load(&g_acks_seen);
    long long inputs_before = atomic_load(&g_inputs_seen);
    CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
    CHECK(bsh_screen_ack(3, 3.5) == 1);
    CHECK(bsh_screen_input(3, (const uint8_t *)"{\"k\":1}", 7) == 1);
    atomic_fetch_add(&g_acks_ok, 1);
    atomic_fetch_add(&g_inputs_ok, 1);

    pthread_t t[SCREEN_THREADS];
    for (int i = 0; i < SCREEN_THREADS; i++) {
        CHECK(pthread_create(&t[i], NULL, screen_hammer, NULL) == 0);
    }
    atomic_store(&g_screen_go, 1);
    // Restart for as long as the hammers run (and at least 50 times), so every op overlaps restarts.
    int restarts = 0;
    while (atomic_load(&g_hammers_done) < SCREEN_THREADS || restarts < 50) {
        bsh_stop();
        sched_yield();
        CHECK(bsh_start("/tmp/shell_pion_abi_test") == 1);
        // Let each shell take a few ops before it is stopped again.
        long long seen = atomic_load(&g_acks_ok) + atomic_load(&g_inputs_ok);
        while (atomic_load(&g_hammers_done) < SCREEN_THREADS &&
               atomic_load(&g_acks_ok) + atomic_load(&g_inputs_ok) < seen + 8) {
            sched_yield();
        }
        restarts++;
    }
    for (int i = 0; i < SCREEN_THREADS; i++) {
        CHECK(pthread_join(t[i], NULL) == 0);
    }
    bsh_stop();
    CHECK(atomic_load(&g_acks_seen) - acks_before == atomic_load(&g_acks_ok));
    CHECK(atomic_load(&g_inputs_seen) - inputs_before == atomic_load(&g_inputs_ok));
    CHECK(atomic_load(&g_acks_ok) == 1 + SCREEN_THREADS * SCREEN_ROUNDS);
    CHECK(atomic_load(&g_inputs_ok) == 1 + SCREEN_THREADS * SCREEN_ROUNDS);
    CHECK(atomic_load(&g_started) == atomic_load(&g_stopped));
    printf(
        "shell_abi_test: screen ops %lld acks / %lld inputs delivered across %d restarts\n",
        (long long)atomic_load(&g_acks_ok),
        (long long)atomic_load(&g_inputs_ok),
        restarts);
}

// bsh_stop from inside a wake callback aborts loudly instead of waiting for itself (in a child process).
static void stopping_wake(void *ctx) {
    (void)ctx;
    bsh_stop();
}

static void test_stop_in_wake_aborts(void) {
    fflush(NULL);
    pid_t pid = fork();
    CHECK(pid >= 0);
    if (pid == 0) {
        bsh_attach(&g_external_handle, stopping_wake, NULL);
        (void)bsh_deliver((1ULL << 40) + 9, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0);
        _exit(0);
    }
    int status = 0;
    CHECK(waitpid(pid, &status, 0) == pid);
    CHECK(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
}

int main(void) {
    test_stop_in_wake_aborts();
    test_basics();
    test_restart_drops_late_answers();
    test_stop_wakes_waiters();
    test_timed_wait();
    test_wait_max_no_overflow();
    test_say_and_media_across_restarts();
    test_wake_unregister();
    test_screen_ops_across_restarts();
    printf("shell_abi_test: OK\n");
    return 0;
}
