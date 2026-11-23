// Standalone C ABI signature and queue test for shell_pion.c (compiled with mock sf_shell_*).
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pion_rt.h"

// Declarations from shell_pion.c
extern int32_t bsh_start(void *dir_str);
extern void bsh_attach(void *started, void (*woke)(void *), void *ctx);
extern void bsh_on_wake(void (*woke)(void *), void *ctx);
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
extern void *bsh_wait(int64_t ms);
extern void bsh_call(int64_t id, void *op_str, void *json_bytes, void *payload_bytes, int32_t has);
extern void *bsh_ask(void *op_str, void *json_bytes);
extern int64_t bsh_now(void);
extern void *bsh_random(int32_t n);

// Minimal PionBytes runtime stubs for standalone C verification
void *pion_bytes_new(int64_t len) {
    PionBytes *b = (PionBytes *)calloc(1, sizeof(PionBytes));
    assert(b != NULL);
    b->len = len;
    b->cap = len;
    b->data = len > 0 ? (uint8_t *)calloc((size_t)len, 1) : NULL;
    return (void *)b;
}

void *pion_bytes_from_ptr(void *p, int64_t len) {
    PionBytes *b = (PionBytes *)pion_bytes_new(len);
    if (len > 0 && p != NULL) {
        memcpy(b->data, p, (size_t)len);
    }
    return (void *)b;
}

// Mock Rust shell C ABI
typedef void (*sf_complete)(
    void *, uint64_t, const uint8_t *, size_t, const uint8_t *, size_t, const uint8_t *, size_t, uint8_t);

static sf_complete g_mock_cb = NULL;
static void *g_mock_ctx = NULL;
static int g_dummy_handle = 42;
static int g_wake_count = 0;

void *sf_shell_start(const char *data_dir, sf_complete complete, void *ctx) {
    assert(data_dir != NULL);
    g_mock_cb = complete;
    g_mock_ctx = ctx;
    return &g_dummy_handle;
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
    assert(shell == &g_dummy_handle);
    assert(op != NULL);
    (void)json;
    (void)json_len;
    const char *reply = "{\"ok\":true}";
    if (g_mock_cb != NULL) {
        g_mock_cb(g_mock_ctx, id, (const uint8_t *)reply, strlen(reply), NULL, 0, bytes, bytes_len, has_bytes);
    }
}

uint8_t *sf_shell_call_sync(
    const void *shell,
    const char *op,
    const uint8_t *json,
    size_t json_len,
    size_t *out_len) {
    assert(shell == &g_dummy_handle);
    assert(op != NULL);
    (void)json;
    (void)json_len;
    const char *resp = "{\"value\":123}";
    size_t n = strlen(resp);
    uint8_t *buf = (uint8_t *)malloc(n);
    assert(buf != NULL);
    memcpy(buf, resp, n);
    *out_len = n;
    return buf;
}

void sf_free(uint8_t *ptr, size_t len) {
    (void)len;
    free(ptr);
}

static void on_wake_cb(void *ctx) {
    (void)ctx;
    g_wake_count += 1;
}

int main(void) {
    assert(bsh_attached() == 0);
    PION_STATIC_STRING_DEF(dir_str, "/tmp");
    PION_STATIC_STRING_DEF(op_str, "test.op");
    assert(bsh_start(dir_str) == 1);
    assert(bsh_attached() == 1);

    bsh_on_wake(on_wake_cb, NULL);
    PionBytes *j = (PionBytes *)pion_bytes_from_ptr((void *)"{}", 2);
    PionBytes *p = (PionBytes *)pion_bytes_from_ptr((void *)"AB", 2);
    bsh_call(7, op_str, j, p, 1);
    assert(g_wake_count == 1);

    PionBytes *ans = (PionBytes *)bsh_wait(0);
    assert(ans->len == 13 + 11 + 2);
    assert(ans->data[0] == 7);
    assert(ans->data[8] == 1);

    PionBytes *sync_ans = (PionBytes *)bsh_ask(op_str, j);
    assert(sync_ans->len == 13);
    assert(memcmp(sync_ans->data, "{\"value\":123}", 13) == 0);

    // bsh_deliver filters ids <= 2^40 and queues ids > 2^40
    assert(bsh_deliver(100, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 0);
    uint64_t high_id = (1ULL << 40) + 5;
    assert(bsh_deliver(high_id, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    PionBytes *ans2 = (PionBytes *)bsh_wait(0);
    assert(ans2->len == 15);

    assert(bsh_now() > 0);
    PionBytes *rnd = (PionBytes *)bsh_random(32);
    assert(rnd->len == 32);

    bsh_attach(&g_dummy_handle, NULL, NULL);
    assert(bsh_attached() == 1);
    printf("shell_abi_test: OK\n");
    return 0;
}
