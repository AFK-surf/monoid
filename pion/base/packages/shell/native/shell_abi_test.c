// Standalone C ABI signature and queue test for shell_pion.c (compiled with mock sf_shell_*).
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Declarations from shell_pion.c
extern int32_t bsh_start(const char *dir_cstr);
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
extern int64_t bsh_now(void);
extern void *bsh_random(int32_t n);

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
    assert(bsh_start("/tmp/shell_pion_abi_test") == 1);
    assert(bsh_attached() == 1);

    bsh_on_wake(on_wake_cb, NULL);
    bsh_call(7, "echo", (const uint8_t *)"{}", 2, (const uint8_t *)"AB", 2, 1);
    assert(g_wake_count == 1);

    int64_t ans_len = 0;
    uint8_t *ans = (uint8_t *)bsh_wait(0, &ans_len);
    assert(ans != NULL);
    assert(ans_len == 13 + 11 + 2);
    assert(ans[0] == 7 && ans[8] == 1 && ans[9] == 11);
    bsh_free(ans);

    int64_t sync_len = 0;
    uint8_t *sync_ans = (uint8_t *)bsh_ask("echo", (const uint8_t *)"{}", 2, &sync_len);
    assert(sync_ans != NULL);
    assert(sync_len == 13 && memcmp(sync_ans, "{\"value\":123}", 13) == 0);
    bsh_free(sync_ans);

    // bsh_deliver filters ids <= 2^40 and queues ids > 2^40
    assert(bsh_deliver(100, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 0);
    uint64_t high_id = (1ULL << 40) + 5;
    assert(bsh_deliver(high_id, (const uint8_t *)"{}", 2, NULL, 0, NULL, 0, 0) == 1);
    int64_t ans2_len = 0;
    uint8_t *ans2 = (uint8_t *)bsh_wait(0, &ans2_len);
    assert(ans2 != NULL && ans2_len == 15);
    bsh_free(ans2);

    assert(bsh_now() > 0);
    uint8_t *rnd = (uint8_t *)bsh_random(32);
    assert(rnd != NULL);
    bsh_free(rnd);

    bsh_attach(&g_dummy_handle, NULL, NULL);
    assert(bsh_attached() == 1);

    printf("shell_abi_test: OK\n");
    return 0;
}
