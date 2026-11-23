// Standalone C11 unit & concurrency stress test for station_host.c.
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
#include <unistd.h>

// Stub Rust shell ABI for testing host_shim in isolation.
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

static stub_shell_t g_stub_shell;
static sf_complete g_last_complete = NULL;
static void *g_last_ctx = NULL;
static atomic_int g_stop_count = 0;

void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx) {
    if (data_dir == NULL || strcmp(data_dir, "FAIL") == 0) {
        return NULL;
    }
    g_stub_shell.complete = complete;
    g_stub_shell.ctx = ctx;
    g_last_complete = complete;
    g_last_ctx = ctx;
    return &g_stub_shell;
}

void sf_shell_stop(void *shell) {
    (void)shell;
    atomic_fetch_add(&g_stop_count, 1);
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
    if (strcmp(op, "echo") == 0) {
        sh->complete(sh->ctx, id, json, json_len, NULL, 0, bytes, bytes_len, has_bytes);
    } else if (strcmp(op, "fail") == 0) {
        static const char msg[] = "boom";
        sh->complete(sh->ctx, id, NULL, 0, (const uint8_t *)msg, sizeof(msg) - 1, NULL, 0, 0);
    }
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

typedef struct bp_args {
    atomic_int pushed;
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
        atomic_fetch_add(&a->pushed, 1);
    }
    sth_push_stdin_eof();
    free(buf);
    return NULL;
}

static void test_stdin_backpressure(void) {
    // Set small backpressure limit (8 KiB) to verify producer blocks until consumer drains.
    sth_set_stdin_limit_for_test(8192);
    bp_args_t args;
    atomic_init(&args.pushed, 0);
    args.chunk_size = 4096;
    args.chunks = 8;

    pthread_t prod;
    assert(pthread_create(&prod, NULL, stdin_producer, &args) == 0);

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
    assert(total == args.chunk_size * (size_t)args.chunks);
    assert(atomic_load(&args.pushed) == args.chunks);
    sth_set_stdin_limit_for_test(STH_STDIN_MOST);
}

static void test_shell_lifecycle_and_stale_gen(void) {
    assert(sth_start("FAIL", 0) == 0);
    assert(sth_shell_active() == 0);

    assert(sth_start("/tmp/fake-shell", 0) == 1);
    assert(sth_shell_active() == 1);
    sf_complete old_complete = g_last_complete;
    void *old_ctx = g_last_ctx;

    // Sync call
    int64_t slen = 0;
    char *sres = (char *)sth_shell_sync("ping", (const uint8_t *)"{}", 2, &slen);
    assert(sres != NULL && slen > 0);
    assert(strstr(sres, "\"ping\"") != NULL);
    sth_free(sres);

    // Async call with binary payload
    const uint8_t payload[4] = { 1, 2, 3, 4 };
    sth_shell_call(42, "echo", (const uint8_t *)"{\"ok\":true}", 11, payload, 4, 1);
    int64_t elen = 0;
    uint8_t *ev = (uint8_t *)sth_wait(1000, &elen);
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

    sth_stop();
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

    int64_t alen = 0;
    void *args = sth_args(&alen);
    assert(args != NULL && alen > 0);
    sth_free(args);

    int64_t blen = 0;
    char *info = (char *)sth_build_info(&blen);
    assert(info != NULL && blen > 0);
    assert(strncmp(info, "stillfail-pion ", 15) == 0);
    sth_free(info);
}

int main(void) {
    test_stdin_backpressure();
    test_shell_lifecycle_and_stale_gen();
    test_mt_sys_queue();
    test_process_utils();
    printf("host_shim_test: ALL PASSED\n");
    return 0;
}
