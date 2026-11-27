// Standalone C11 unit & adversarial concurrency test for station_host.c.
// Deterministic synchronization only (zero sleeps).
// Verified under plain -Wall -Wextra -Werror, -fsanitize=address,undefined, and -fsanitize=thread.

#if !defined(_WIN32) && !defined(__APPLE__)
#define _POSIX_C_SOURCE 200809L
#endif

#include "station_host.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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

typedef struct stub_shell {
    sf_complete complete;
    void *ctx;
} stub_shell_t;

typedef struct async_req {
    sf_complete complete;
    void *ctx;
    uint64_t id;
    int is_fail;
    uint8_t *json;
    size_t json_len;
    uint8_t *bytes;
    size_t bytes_len;
    uint8_t has_bytes;
} async_req_t;

static pthread_mutex_t g_stub_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_stub_done = PTHREAD_COND_INITIALIZER;
static int g_stub_inflight = 0;
static sf_complete g_last_complete = NULL;
static void *g_last_ctx = NULL;
static atomic_int g_stop_count = 0;

static void stub_wait_all_workers_done(void) {
    pthread_mutex_lock(&g_stub_mu);
    while (g_stub_inflight > 0) {
        pthread_cond_wait(&g_stub_done, &g_stub_mu);
    }
    pthread_mutex_unlock(&g_stub_mu);
}

static void *async_complete_worker(void *arg) {
    async_req_t *r = (async_req_t *)arg;
    if (r->is_fail) {
        static const char msg[] = "boom";
        r->complete(r->ctx, r->id, NULL, 0, (const uint8_t *)msg, sizeof(msg) - 1, NULL, 0, 0);
    } else {
        r->complete(r->ctx, r->id, r->json, r->json_len, NULL, 0, r->bytes, r->bytes_len, r->has_bytes);
    }
    free(r->json);
    free(r->bytes);
    free(r);

    pthread_mutex_lock(&g_stub_mu);
    g_stub_inflight -= 1;
    if (g_stub_inflight == 0) {
        pthread_cond_broadcast(&g_stub_done);
    }
    pthread_mutex_unlock(&g_stub_mu);
    return NULL;
}

void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx) {
    if (data_dir == NULL || strcmp(data_dir, "FAIL") == 0) {
        return NULL;
    }
    stub_shell_t *sh = (stub_shell_t *)malloc(sizeof(*sh));
    assert(sh != NULL);
    sh->complete = complete;
    sh->ctx = ctx;
    pthread_mutex_lock(&g_stub_mu);
    g_last_complete = complete;
    g_last_ctx = ctx;
    pthread_mutex_unlock(&g_stub_mu);
    return sh;
}

void sf_shell_stop(void *shell) {
    atomic_fetch_add(&g_stop_count, 1);
    free(shell);
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
    const stub_shell_t *sh = (const stub_shell_t *)shell;
    async_req_t *r = (async_req_t *)calloc(1, sizeof(*r));
    assert(r != NULL);
    r->complete = sh->complete;
    r->ctx = sh->ctx;
    r->id = id;
    r->is_fail = (strcmp(op, "fail") == 0);
    r->json_len = json_len;
    if (json_len > 0 && json != NULL) {
        r->json = (uint8_t *)malloc(json_len);
        assert(r->json != NULL);
        memcpy(r->json, json, json_len);
    }
    r->bytes_len = bytes_len;
    r->has_bytes = has_bytes;
    if (has_bytes && bytes_len > 0 && bytes != NULL) {
        r->bytes = (uint8_t *)malloc(bytes_len);
        assert(r->bytes != NULL);
        memcpy(r->bytes, bytes, bytes_len);
    }

    pthread_mutex_lock(&g_stub_mu);
    g_stub_inflight += 1;
    pthread_mutex_unlock(&g_stub_mu);

    // Deliver completion on a real foreign thread to exercise TSan concurrency with sth_stop().
    pthread_t t;
    assert(pthread_create(&t, NULL, async_complete_worker, r) == 0);
    pthread_detach(t);
}

uint8_t *sf_shell_call_sync(
    const void *shell,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    size_t *out_len) {
    (void)shell;
    (void)json;
    (void)json_len;
    char buf[128];
    int n = snprintf(buf, sizeof(buf), "{\"value\":{\"op\":\"%s\"}}", op);
    uint8_t *out = (uint8_t *)malloc((size_t)n);
    assert(out != NULL);
    memcpy(out, buf, (size_t)n);
    *out_len = (size_t)n;
    return out;
}

void sf_free(uint8_t *ptr, size_t len) {
    (void)len;
    free(ptr);
}

static uint64_t read_u64_le(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) {
        v |= ((uint64_t)p[i]) << (8 * i);
    }
    return v;
}

static int contains_bytes(const uint8_t *hay, size_t hay_len, const char *needle) {
    size_t nlen = strlen(needle);
    if (nlen == 0 || hay == NULL || hay_len < nlen) {
        return 0;
    }
    for (size_t i = 0; i + nlen <= hay_len; i++) {
        if (memcmp(hay + i, needle, nlen) == 0) {
            return 1;
        }
    }
    return 0;
}

typedef struct bp_args {
    atomic_int pushed_chunks;
    atomic_int finished;
    size_t chunk_size;
    int chunks;
} bp_args_t;

static void *stdin_producer(void *arg) {
    bp_args_t *a = (bp_args_t *)arg;
    uint8_t *buf = (uint8_t *)malloc(a->chunk_size);
    assert(buf != NULL);
    memset(buf, 0x41, a->chunk_size);
    for (int i = 0; i < a->chunks; i++) {
        sth_push_stdin_chunk(buf, a->chunk_size);
        atomic_fetch_add(&a->pushed_chunks, 1);
    }
    sth_push_stdin_eof();
    atomic_store(&a->finished, 1);
    free(buf);
    return NULL;
}

static void test_stdin_backpressure_strict_cap(void) {
    // Use an oversized chunk (12 KiB) against an 8 KiB cap to prove slicing keeps peak <= cap
    // and producer deterministically blocks in cond_wait until consumer drains.
    const size_t limit = 8192;
    sth_set_stdin_limit_for_test(limit);

    bp_args_t args;
    atomic_init(&args.pushed_chunks, 0);
    atomic_init(&args.finished, 0);
    args.chunk_size = 12288; // larger than limit
    args.chunks = 4;

    pthread_t prod;
    assert(pthread_create(&prod, NULL, stdin_producer, &args) == 0);

    // Deterministic condvar wait with bounded timeout: guarantees producer is blocked on backpressure.
    assert(sth_wait_for_stdin_blocked_for_test(5000) == 1);
    assert(atomic_load(&args.finished) == 0);
    assert(atomic_load(&args.pushed_chunks) < args.chunks);
    assert(sth_stdin_queued_peak_for_test() <= limit);

    size_t total = 0;
    int saw_eof = 0;
    while (!saw_eof) {
        int64_t n = 0;
        uint8_t *ev = (uint8_t *)sth_wait(2000, &n);
        assert(ev != NULL && n >= 9);
        if (ev[0] == STH_EV_STDIN_DATA) {
            total += (size_t)(n - 9);
        } else if (ev[0] == STH_EV_STDIN_EOF) {
            saw_eof = 1;
        }
        sth_free(ev);
    }
    pthread_join(prod, NULL);
    assert(atomic_load(&args.finished) == 1);
    assert(total == args.chunk_size * (size_t)args.chunks);
    assert(sth_stdin_queued_peak_for_test() <= limit);
    sth_set_stdin_limit_for_test(STH_STDIN_MOST);
}

static void test_sth_stop_preserves_stdin_and_eof(void) {
    assert(sth_start("/tmp/fake-shell-preserve", 0) == 1);
    const char line[] = "{\"id\":7,\"op\":\"echo\"}\n";
    sth_push_stdin_chunk((const uint8_t *)line, sizeof(line) - 1);
    sth_push_stdin_eof();

    // Stopping shell MUST NOT drop queued stdin data or EOF.
    sth_stop();
    assert(sth_shell_active() == 0);

    int64_t n1 = 0;
    uint8_t *ev1 = (uint8_t *)sth_wait(1000, &n1);
    assert(ev1 != NULL && n1 == (int64_t)(9 + sizeof(line) - 1));
    assert(ev1[0] == STH_EV_STDIN_DATA);
    assert(memcmp(ev1 + 9, line, sizeof(line) - 1) == 0);
    sth_free(ev1);

    int64_t n2 = 0;
    uint8_t *ev2 = (uint8_t *)sth_wait(1000, &n2);
    assert(ev2 != NULL && n2 == 9);
    assert(ev2[0] == STH_EV_STDIN_EOF);
    sth_free(ev2);
}

typedef struct wake_waiter {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int done;
    void *ev;
    int64_t len;
} wake_waiter_t;

static void *indefinite_waiter_thread(void *arg) {
    wake_waiter_t *w = (wake_waiter_t *)arg;
    int64_t len = -1;
    void *ev = sth_wait(-1, &len);
    pthread_mutex_lock(&w->mu);
    w->ev = ev;
    w->len = len;
    w->done = 1;
    pthread_cond_signal(&w->cv);
    pthread_mutex_unlock(&w->mu);
    return NULL;
}

static void test_sth_stop_wakes_indefinite_wait_on_empty_queue(void) {
    assert(sth_start("/tmp/fake-shell-wake", 0) == 1);
    wake_waiter_t w;
    memset(&w, 0, sizeof(w));
    w.len = -1;
    assert(pthread_mutex_init(&w.mu, NULL) == 0);
    assert(pthread_cond_init(&w.cv, NULL) == 0);

    pthread_t waiter;
    assert(pthread_create(&waiter, NULL, indefinite_waiter_thread, &w) == 0);

    // Wait deterministically until waiter is inside sth_wait(-1), then stop shell.
    assert(sth_wait_for_queue_waiter_for_test(5000) == 1);
    sth_stop();

    // Bounded 5000ms wait: a regression that drops stop-wake fails by assertion instead of hanging.
    pthread_mutex_lock(&w.mu);
    struct timespec dl;
    clock_gettime(CLOCK_REALTIME, &dl);
    dl.tv_sec += 5;
    while (!w.done) {
        if (pthread_cond_timedwait(&w.cv, &w.mu, &dl) != 0) {
            break;
        }
    }
    int finished = w.done;
    void *ev = w.ev;
    int64_t len = w.len;
    pthread_mutex_unlock(&w.mu);

    assert(finished == 1);
    pthread_join(waiter, NULL);
    pthread_cond_destroy(&w.cv);
    pthread_mutex_destroy(&w.mu);
    assert(ev == NULL && len == 0);
}

static void test_shell_lifecycle_and_foreign_thread_race(void) {
    assert(sth_start("FAIL", 0) == 0);
    assert(sth_shell_active() == 0);

    assert(sth_start("/tmp/fake-shell", 0) == 1);
    assert(sth_shell_active() == 1);
    pthread_mutex_lock(&g_stub_mu);
    sf_complete old_complete = g_last_complete;
    void *old_ctx = g_last_ctx;
    pthread_mutex_unlock(&g_stub_mu);

    // Sync call (length-bounded check, never calling strstr on non-NUL-terminated buffer).
    int64_t slen = 0;
    uint8_t *sres = (uint8_t *)sth_shell_sync("ping", (const uint8_t *)"{}", 2, &slen);
    assert(sres != NULL && slen > 0);
    assert(contains_bytes(sres, (size_t)slen, "\"ping\""));
    sth_free(sres);

    // Async call completed by a real foreign thread.
    const uint8_t payload[4] = { 1, 2, 3, 4 };
    sth_shell_call(42, "echo", (const uint8_t *)"{\"ok\":true}", 11, payload, 4, 1);
    int64_t elen = 0;
    uint8_t *ev = (uint8_t *)sth_wait(2000, &elen);
    assert(ev != NULL && elen > 9);
    assert(ev[0] == STH_EV_SHELL_DONE);
    assert(read_u64_le(ev + 1) == 42);
    uint64_t err_len = read_u64_le(ev + 9);
    uint64_t json_len = read_u64_le(ev + 9 + 8 + err_len);
    assert(err_len == 0);
    assert(json_len == 11);
    assert(ev[9 + 8 + err_len + 8 + json_len] == 1);
    assert(memcmp(ev + 9 + 8 + err_len + 8 + json_len + 1, payload, 4) == 0);
    sth_free(ev);

    // Stop and restart; late completion from old generation must be dropped.
    sth_stop();
    assert(sth_shell_active() == 0);
    assert(atomic_load(&g_stop_count) >= 1);

    assert(sth_start("/tmp/fake-shell-2", 0) == 1);
    old_complete(old_ctx, 99, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0);
    int64_t stale_len = 0;
    void *stale = sth_wait(0, &stale_len);
    assert(stale == NULL && stale_len == 0);

    // Stress concurrent foreign-thread completions racing with sth_stop() under TSan.
    for (int round = 0; round < 16; round++) {
        for (int k = 0; k < 4; k++) {
            sth_shell_call((int64_t)(round * 10 + k), "echo", (const uint8_t *)"{}", 2, NULL, 0, 0);
        }
        sth_stop();
        assert(sth_start("/tmp/fake-shell-race", 0) == 1);
    }
    sth_stop();
    // Deterministically wait for every foreign completion worker to exit (zero sleeps).
    stub_wait_all_workers_done();
}

static void *sys_worker(void *arg) {
    uint64_t base = (uint64_t)(uintptr_t)arg;
    for (uint64_t i = 0; i < 64; i++) {
        uint8_t b[16];
        memset(b, (int)(i & 0xff), sizeof(b));
        if (i % 2 == 0) {
            sth_push_sys(base + i, b, sizeof(b));
        } else {
            sth_push_sys_bounded(base + i, b, sizeof(b));
        }
    }
    return NULL;
}

static void test_mt_sys_queue(void) {
    pthread_t th[4];
    for (int i = 0; i < 4; i++) {
        assert(pthread_create(&th[i], NULL, sys_worker, (void *)(uintptr_t)((i + 1) * 1000)) == 0);
    }
    int received = 0;
    while (received < 4 * 64) {
        int64_t n = 0;
        uint8_t *ev = (uint8_t *)sth_wait(2000, &n);
        assert(ev != NULL && n == 9 + 16);
        assert(ev[0] == STH_EV_SYS);
        sth_free(ev);
        received += 1;
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(th[i], NULL);
    }
}

static void test_process_utils(void) {
    assert(sth_pid() > 0);
    int64_t t0 = sth_now_ms();
    int64_t t1 = sth_now_ms();
    assert(t1 >= t0);
    assert(sth_wall_ms() > 1700000000000LL);
    assert(sth_rss_bytes() > 0);
    assert(sth_open_fd_count() >= 3);
    assert(sth_open_thread_count() >= 1);

    int64_t alen = 0;
    void *args = sth_args(&alen);
    assert(args != NULL && alen > 0);
    sth_free(args);

    int64_t blen = 0;
    uint8_t *info = (uint8_t *)sth_build_info(&blen);
    assert(info != NULL && blen > 0);
    assert(contains_bytes(info, (size_t)blen, "stillfail-pion "));
    sth_free(info);
}

static void test_read_file_slice(void) {
    char path[256];
    snprintf(path, sizeof(path), "/tmp/sth_slice_test_%d.bin", (int)sth_pid());
    FILE *f = fopen(path, "wb");
    assert(f != NULL);
    const char payload[] = "0123456789abcdef";
    assert(fwrite(payload, 1, 16, f) == 16);
    fclose(f);

    // Whole file (length < 0).
    int64_t n = -99;
    uint8_t *b = (uint8_t *)sth_read_file_slice(path, 0, -1, &n);
    assert(b != NULL && n == 16 && memcmp(b, payload, 16) == 0);
    sth_free(b);

    // Sub-slice in middle.
    b = (uint8_t *)sth_read_file_slice(path, 4, 6, &n);
    assert(b != NULL && n == 6 && memcmp(b, "456789", 6) == 0);
    sth_free(b);

    // Slice clamping past EOF.
    b = (uint8_t *)sth_read_file_slice(path, 12, 100, &n);
    assert(b != NULL && n == 4 && memcmp(b, "cdef", 4) == 0);
    sth_free(b);

    // Offset at/past EOF returns non-NULL empty slice.
    b = (uint8_t *)sth_read_file_slice(path, 16, 10, &n);
    assert(b != NULL && n == 0);
    sth_free(b);
    b = (uint8_t *)sth_read_file_slice(path, 999, -1, &n);
    assert(b != NULL && n == 0);
    sth_free(b);

    // Zero length returns non-NULL empty slice.
    b = (uint8_t *)sth_read_file_slice(path, 2, 0, &n);
    assert(b != NULL && n == 0);
    sth_free(b);

    // Negative offset -> fallback (-2).
    b = (uint8_t *)sth_read_file_slice(path, -1, 4, &n);
    assert(b == NULL && n == -2);

    // Directory -> fallback (-2) on POSIX.
    b = (uint8_t *)sth_read_file_slice("/tmp", 0, 16, &n);
    assert(b == NULL && n == -2);

    unlink(path);

    // Missing file -> -1.
    b = (uint8_t *)sth_read_file_slice(path, 0, 16, &n);
    assert(b == NULL && n == -1);
}

int main(void) {
    test_stdin_backpressure_strict_cap();
    test_sth_stop_preserves_stdin_and_eof();
    test_sth_stop_wakes_indefinite_wait_on_empty_queue();
    test_shell_lifecycle_and_foreign_thread_race();
    test_mt_sys_queue();
    test_process_utils();
    test_read_file_slice();
    printf("host_shim_test: ALL PASSED\n");
    return 0;
}
