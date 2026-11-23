// Real C host end-to-end test simulating `apps/mbui` driving the Pion `ClientCore`
// through `apps/mbui/src/host/core_api.h` (`mb_core_start` -> `mb_core_send` ->
// `on_message` -> `mb_core_stop`) linked against real Rust `libstillfail_shell.so`.

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "core_api.h"

extern void mb_core_attach_pion_runtime(void);
extern int mb_core_deliver_media(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len);

#define MAX_MSGS 64

typedef struct recorded_msg {
    char *json;
    size_t len;
    uint8_t *bytes;
    size_t blen;
} recorded_msg_t;

typedef struct host_ctx {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    recorded_msg_t msgs[MAX_MSGS];
    int count;
    _Atomic int stopped;
    _Atomic int post_stop_count;
    uint64_t last_media_seq;
} host_ctx_t;

static host_ctx_t g_ctx;

static void on_host_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
    host_ctx_t *h = (host_ctx_t *)ctx;
    if (atomic_load(&h->stopped)) {
        atomic_fetch_add(&h->post_stop_count, 1);
        return;
    }
    pthread_mutex_lock(&h->mu);
    assert(h->count < MAX_MSGS);
    recorded_msg_t *slot = &h->msgs[h->count++];
    slot->json = (char *)malloc(len + 1);
    assert(slot->json != NULL);
    memcpy(slot->json, json, len);
    slot->json[len] = '\0';
    slot->len = len;
    if (bytes != NULL && blen > 0) {
        slot->bytes = (uint8_t *)malloc(blen);
        assert(slot->bytes != NULL);
        memcpy(slot->bytes, bytes, blen);
        slot->blen = blen;
    } else {
        slot->bytes = NULL;
        slot->blen = 0;
    }
    pthread_cond_broadcast(&h->cv);
    pthread_mutex_unlock(&h->mu);
}

static recorded_msg_t *wait_for_msg_index(host_ctx_t *h, int idx) {
    pthread_mutex_lock(&h->mu);
    while (h->count <= idx) {
        pthread_cond_wait(&h->cv, &h->mu);
    }
    recorded_msg_t *m = &h->msgs[idx];
    pthread_mutex_unlock(&h->mu);
    return m;
}

static void send_json(const char *s) {
    mb_core_send(s, strlen(s), NULL, 0);
}

static int extract_v_token(const char *json, char *out, size_t out_cap) {
    const char *p = strstr(json, "\"v\":\"");
    if (p == NULL) {
        return 0;
    }
    p += 5;
    size_t i = 0;
    while (p[i] != '\0' && p[i] != '"' && i + 1 < out_cap) {
        out[i] = p[i];
        i++;
    }
    out[i] = '\0';
    return p[i] == '"' && i > 0;
}

static int media_cb(
    uint64_t call,
    int kind,
    int key,
    uint64_t seq,
    uint64_t ts,
    const uint8_t *bytes,
    size_t len) {
    assert(call == 7 && kind == 2 && key == 1 && ts == 555);
    assert(bytes != NULL && len == 4 && memcmp(bytes, "AV1!", 4) == 0);
    g_ctx.last_media_seq = seq;
    return 1;
}

int main(void) {
    memset(&g_ctx, 0, sizeof(g_ctx));
    pthread_mutex_init(&g_ctx.mu, NULL);
    pthread_cond_init(&g_ctx.cv, NULL);

    mb_core_attach_pion_runtime();
    mb_core_route_media(media_cb);

    char data_dir[128];
    snprintf(data_dir, sizeof(data_dir), "/tmp/pion_core_runtime_e2e_%ld", (long)time(NULL));

    printf("[core_runtime_e2e] starting mb_core_start at %s\n", data_dir);
    mb_core_start(data_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);

    int next_idx = 0;
    recorded_msg_t *m = NULL;

    // 1. settings.set + settings.get (real SQLite `workspace_pref`)
    send_json("{\"id\":1,\"call\":\"settings.set\",\"params\":{\"key\":\"theme\",\"value\":\"dark\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #1 settings.set -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":1") != NULL && strstr(m->json, "\"saved\":true") != NULL);

    send_json("{\"id\":2,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #2 settings.get -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":2") != NULL && strstr(m->json, "\"value\":\"dark\"") != NULL);

    // 2. chat.draft write & read (real SQLite `draft`)
    send_json("{\"id\":3,\"call\":\"chat.draft\",\"params\":{\"chat\":\"c-1\",\"text\":\"hello draft\",\"updatedAt\":12345}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #3 chat.draft put -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":3") != NULL && strstr(m->json, "\"saved\":true") != NULL);

    send_json("{\"id\":4,\"call\":\"chat.draft\",\"params\":{\"chat\":\"c-1\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #4 chat.draft get -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":4") != NULL && strstr(m->json, "hello draft") != NULL);

    // 3. accounts + account.switch + vault.status + vault.secrets
    send_json("{\"id\":5,\"call\":\"account.switch\",\"params\":{\"account\":\"alice@still.fail\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #5 account.switch -> %s\n", m->json);
    assert(strstr(m->json, "\"switched\":true") != NULL && strstr(m->json, "alice@still.fail") != NULL);

    send_json("{\"id\":6,\"call\":\"accounts\",\"params\":{}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #6 accounts -> %s\n", m->json);
    assert(strstr(m->json, "\"active\":\"alice@still.fail\"") != NULL);

    send_json("{\"id\":7,\"call\":\"vault.status\",\"params\":{}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #7 vault.status -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":7") != NULL && strstr(m->json, "\"vaultCount\":0") != NULL);

    send_json("{\"id\":8,\"call\":\"vault.secrets\",\"params\":{}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #8 vault.secrets -> %s\n", m->json);
    assert(strstr(m->json, "\"secrets\":[]") != NULL);

    // 4. message.send + message.edit + message.delete + card.answer + chat.read
    send_json("{\"id\":9,\"call\":\"message.send\",\"params\":{\"thread\":42,\"clientKey\":\"ck-e2e-1\",\"author\":\"alice\",\"text\":\"hi from C host\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9 message.send -> %s\n", m->json);
    assert(strstr(m->json, "\"queued\":true") != NULL && strstr(m->json, "ck-e2e-1") != NULL);

    send_json("{\"id\":10,\"call\":\"message.edit\",\"params\":{\"thread\":42,\"target\":1,\"text\":\"edited from C host\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #10 message.edit -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":10") != NULL && strstr(m->json, "\"target\":1") != NULL);

    send_json("{\"id\":11,\"call\":\"card.answer\",\"params\":{\"thread\":42,\"seq\":2,\"option\":\"Approve\",\"action\":\"reply\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #11 card.answer -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":11") != NULL && strstr(m->json, "\"option\":\"Approve\"") != NULL);

    send_json("{\"id\":12,\"call\":\"chat.read\",\"params\":{\"thread\":42,\"read\":5,\"unread\":0}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #12 chat.read -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":12") != NULL && strstr(m->json, "\"read\":5") != NULL);

    // 5. Subscription keyed delta + keep/have token (`v` -> `same: true` -> `delta + kept: true`)
    send_json("{\"id\":20,\"subscribe\":{\"topic\":\"settings\",\"scope\":\"ws-default\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 subscribe settings -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":20") != NULL && strstr(m->json, "\"value\"") != NULL);

    // Mutate while subscribed -> expect Call OK + live pushed Delta on sub 20!
    send_json("{\"id\":21,\"call\":\"settings.set\",\"params\":{\"key\":\"fontSize\",\"value\":16}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":21") != NULL && strstr(m->json, "\"saved\":true") != NULL);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 live delta -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":20") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "fontSize") != NULL);

    // Unsubscribe with keep: true -> receive `v` token
    send_json("{\"id\":20,\"unsubscribe\":true,\"keep\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 unsubscribe keep -> %s\n", m->json);
    char token[128];
    assert(extract_v_token(m->json, token, sizeof(token)));

    // Re-subscribe with `have: token` when unchanged -> expect `same: true`
    char resub_same[256];
    snprintf(resub_same, sizeof(resub_same), "{\"id\":22,\"subscribe\":{\"topic\":\"settings\",\"scope\":\"ws-default\"},\"keyed\":true,\"have\":\"%s\"}", token);
    send_json(resub_same);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #22 resubscribe have (unchanged) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":22") != NULL && strstr(m->json, "\"same\":true") != NULL);

    // Unsubscribe 22 without keep, mutate, then re-subscribe with old `have: token` -> expect `delta` + `kept: true`
    send_json("{\"id\":22,\"unsubscribe\":true}");
    send_json("{\"id\":23,\"call\":\"settings.set\",\"params\":{\"key\":\"theme\",\"value\":\"light\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":23") != NULL && strstr(m->json, "\"saved\":true") != NULL);

    char resub_diff[256];
    snprintf(resub_diff, sizeof(resub_diff), "{\"id\":24,\"subscribe\":{\"topic\":\"settings\",\"scope\":\"ws-default\"},\"keyed\":true,\"have\":\"%s\"}", token);
    send_json(resub_diff);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #24 resubscribe have (changed) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":24") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "\"kept\":true") != NULL && strstr(m->json, "light") != NULL);

    // 6. Binary payload round-trip + screen_ack / screen_input / route_media
    static const uint8_t bin[4] = {'P', 'I', 'O', 'N'};
    static const char echo_req[] = "{\"id\":30,\"call\":\"echo.bytes\",\"params\":{\"ok\":true}}";
    mb_core_send(echo_req, sizeof(echo_req) - 1, bin, sizeof(bin));
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #30 echo.bytes -> %s (blen=%zu)\n", m->json, m->blen);
    assert(m->bytes != NULL && m->blen == 4 && memcmp(m->bytes, "PION", 4) == 0);

    assert(mb_core_screen_ack(12.0, 999.0) == 1);
    static const uint8_t sc_in[] = "{\"type\":\"click\",\"x\":10}";
    assert(mb_core_screen_input(12.0, sc_in, sizeof(sc_in) - 1) == 1);
    assert(mb_core_deliver_media(7, 2, 1, 88, 555, (const uint8_t *)"AV1!", 4) == 1);
    assert(g_ctx.last_media_seq == 88);

    // 7. Stop cleanly and verify zero post-stop callbacks, then restart on same dir to prove SQLite persistence!
    mb_core_stop();
    atomic_store(&g_ctx.stopped, 1);
    send_json("{\"id\":99,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    assert(atomic_load(&g_ctx.post_stop_count) == 0);

    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(data_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    send_json("{\"id\":40,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #40 settings.get after restart -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":40") != NULL && strstr(m->json, "\"value\":\"light\"") != NULL);

    mb_core_stop();
    printf("[core_runtime_e2e] ALL REAL core_api.h + libstillfail_shell.so E2E CHECKS PASSED (msgs=%d, post_stop=%d)\n",
           g_ctx.count, atomic_load(&g_ctx.post_stop_count));
    return 0;
}
