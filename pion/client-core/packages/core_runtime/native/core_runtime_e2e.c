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
#include <sys/stat.h>
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

#define MAX_MSGS 256

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

static long long extract_conn_seq(const char *json) {
    const char *p = strstr(json, "\"conn\":");
    if (p == NULL) {
        return -1;
    }
    return strtoll(p + 7, NULL, 10);
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

static void *foreign_screen_thread(void *arg) {
    (void)arg;
    // Direct pure-C `bsh_screen_ack` / `bsh_screen_input` into `sf_shell_screen_*` from a foreign thread:
    // no tapped stream for call 12 -> returns 0 cleanly without touching the Pion heap.
    assert(mb_core_screen_ack(12.0, 999.0) == 0);
    static const uint8_t sc_in[] = "{\"type\":\"click\",\"x\":10}";
    assert(mb_core_screen_input(12.0, sc_in, sizeof(sc_in) - 1) == 0);
    return NULL;
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

    // 0. Startup authoritative auth handshake (`{"id":0,"auth":{"conn":N,"scopes":{...},"workspaces":{...},"vaults":{...}}}`)
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #0 startup auth handshake -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":0") != NULL);
    assert(strstr(m->json, "\"auth\":{") != NULL);
    long long conn1 = extract_conn_seq(m->json);
    assert(conn1 > 0);
    char conn1_kv[64];
    snprintf(conn1_kv, sizeof(conn1_kv), "\"conn\":%lld", conn1);
    assert(strstr(m->json, conn1_kv) != NULL);
    assert(strstr(m->json, "\"scopes\":{") != NULL);
    assert(strstr(m->json, "\"workspaces\":{") != NULL);
    assert(strstr(m->json, "\"vaults\":{") != NULL);
    // Verify atomic TS-compatible device/auth file was persisted at `data_dir/device%2Fauth` with `"connSeq":<conn1>`
    char dev_auth_path[256];
    snprintf(dev_auth_path, sizeof(dev_auth_path), "%s/device%%2Fauth", data_dir);
    FILE *dev_auth_f = fopen(dev_auth_path, "r");
    assert(dev_auth_f != NULL);
    char dev_auth_buf[512];
    size_t dev_auth_n = fread(dev_auth_buf, 1, sizeof(dev_auth_buf) - 1, dev_auth_f);
    fclose(dev_auth_f);
    dev_auth_buf[dev_auth_n] = '\0';
    char conn1_auth_kv[64];
    snprintf(conn1_auth_kv, sizeof(conn1_auth_kv), "\"connSeq\":%lld", conn1);
    assert(strstr(dev_auth_buf, conn1_auth_kv) != NULL);
    // Verify authoritative `device/conn_seq_floor` was ALSO persisted on first startup!
    char floor_path[256];
    snprintf(floor_path, sizeof(floor_path), "%s/device%%2Fconn_seq_floor", data_dir);
    {
        FILE *ff = fopen(floor_path, "r");
        assert(ff != NULL);
        char fbuf[256];
        size_t fn = fread(fbuf, 1, sizeof(fbuf) - 1, ff);
        fclose(ff);
        fbuf[fn] = '\0';
        assert(strstr(fbuf, conn1_auth_kv) != NULL);
    }

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

    // 4. Real ops.ts calls: chat.send + chat.rename + decision.answer + chat.read
    send_json("{\"id\":9,\"call\":\"chat.send\",\"params\":{\"thread\":42,\"clientKey\":\"ck-e2e-1\",\"author\":\"alice\",\"text\":\"hi from C host\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9 chat.send -> %s\n", m->json);
    assert(strstr(m->json, "\"queued\":true") != NULL && strstr(m->json, "ck-e2e-1") != NULL);

    // Verify `rt.now()` persisted real Unix epoch milliseconds (> 1700000000000) into outbox `createdAt` (never monotonic uptime)!
    // Also verify `WireOutGen`: non-device-global `chat` carries `conn:<conn1>` + `authGen:1` (no `vaultGen`).
    send_json("{\"id\":19,\"subscribe\":{\"topic\":\"chat\",\"station\":\"st-local\",\"thread\":42},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #19 subscribe chat (outbox epoch check) -> %s\n", m->json);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL && strstr(m->json, "\"vaultGen\"") == NULL);
    const char *ca = strstr(m->json, "\"createdAt\":");
    assert(ca != NULL);
    long long created_at_ms = strtoll(ca + 12, NULL, 10);
    assert(created_at_ms > 1700000000000LL);

    // P1-2: `chat.place` and `chat.window` MUST NOT push unsolicited refreshes on active `chat` sub #19;
    // furthermore, subsequent refreshes (`chat.send` / `EntryAdded`) on #19 keep the opening `rows` snapshot,
    // and in Part 1 re-subscribing opens at the tail window (never anchoring at `at` before `newer` /
    // `chat.newer` / `chat.latest` are wired) so tail messages remain visible.
    send_json("{\"id\":191,\"call\":\"chat.place\",\"params\":{\"station\":\"st-local\",\"thread\":42,\"seq\":1,\"offset\":4.5}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":191") != NULL && strstr(m->json, "\"error\"") == NULL);
    send_json("{\"id\":192,\"call\":\"chat.window\",\"params\":{\"station\":\"st-local\",\"thread\":42,\"rows\":50}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":192") != NULL && strstr(m->json, "\"error\"") == NULL);
    // Sentinel call immediately after: next message MUST be #193 (zero unsolicited #19 chat delta in between!).
    send_json("{\"id\":193,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":193") != NULL && strstr(m->json, "\"theme\"") != NULL);
    // Now trigger a real refresh on active sub #19 via `chat.send`: #19 receives the new message delta,
    // and its `at`/`atOffset` MUST remain absent.
    send_json("{\"id\":1931,\"call\":\"chat.send\",\"params\":{\"thread\":42,\"clientKey\":\"ck-e2e-2\",\"author\":\"alice\",\"text\":\"second msg during active sub\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":1931") != NULL && strstr(m->json, "\"queued\":true") != NULL);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #19 live delta after chat.place+chat.send -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":19") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "second msg during active sub") != NULL);
    assert(strstr(m->json, "\"at\"") == NULL && strstr(m->json, "\"atOffset\"") == NULL);
    send_json("{\"id\":19,\"unsubscribe\":true}");

    // Re-subscribing opens at the tail window (latest message visible, no mid-thread `at` truncation).
    send_json("{\"id\":194,\"subscribe\":{\"topic\":\"chat\",\"station\":\"st-local\",\"thread\":42},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":194") != NULL && strstr(m->json, "second msg during active sub") != NULL);
    assert(strstr(m->json, "\"at\"") == NULL && strstr(m->json, "\"atOffset\"") == NULL);
    send_json("{\"id\":194,\"unsubscribe\":true}");
    send_json("{\"id\":195,\"call\":\"chat.place\",\"params\":{\"station\":\"st-local\",\"thread\":42,\"seq\":null}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":195") != NULL && strstr(m->json, "\"error\"") == NULL);

    send_json("{\"id\":10,\"call\":\"chat.rename\",\"params\":{\"thread\":42,\"title\":\"Renamed from C host\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #10 chat.rename -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":10") != NULL && strstr(m->json, "\"opId\"") != NULL);

    send_json("{\"id\":11,\"call\":\"decision.answer\",\"params\":{\"thread\":42,\"seq\":2,\"option\":\"Approve\",\"action\":\"reply\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #11 decision.answer -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":11") != NULL && strstr(m->json, "\"option\":\"Approve\"") != NULL);

    send_json("{\"id\":12,\"call\":\"chat.read\",\"params\":{\"thread\":42,\"read\":5,\"unread\":0}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #12 chat.read -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":12") != NULL && strstr(m->json, "\"read\":5") != NULL);

    // 5. Subscription keyed delta + keep/have token (`v` -> `same: true` -> `delta + kept: true`)
    // Verify `WireOutGen` on device-global topic `prefs`: MUST carry `conn:<conn1>` and MUST NOT carry `authGen` or `vaultGen`.
    send_json("{\"id\":20,\"subscribe\":{\"topic\":\"prefs\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 subscribe prefs -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":20") != NULL && strstr(m->json, "\"value\"") != NULL);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\"") == NULL && strstr(m->json, "\"vaultGen\"") == NULL);

    // Mutate while subscribed -> expect Call OK + live pushed Delta on sub 20!
    send_json("{\"id\":21,\"call\":\"prefs.set\",\"params\":{\"reader\":{\"size\":18}}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":21") != NULL && strstr(m->json, "\"error\"") == NULL);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 live delta -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":20") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "18") != NULL);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\"") == NULL);

    // Unsubscribe with keep: true -> receive `v` token (stamped with `conn:<conn1>`)
    send_json("{\"id\":20,\"unsubscribe\":true,\"keep\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #20 unsubscribe keep -> %s\n", m->json);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\"") == NULL);
    char token[128];
    assert(extract_v_token(m->json, token, sizeof(token)));

    // Re-subscribe with `have: token` when unchanged -> expect `same: true` + `conn:<conn1>`
    char resub_same[256];
    snprintf(resub_same, sizeof(resub_same), "{\"id\":22,\"subscribe\":{\"topic\":\"prefs\"},\"keyed\":true,\"have\":\"%s\"}", token);
    send_json(resub_same);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #22 resubscribe have (unchanged) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":22") != NULL && strstr(m->json, "\"same\":true") != NULL && strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\"") == NULL);

    // Unsubscribe 22 without keep, mutate, then re-subscribe with old `have: token` -> expect `delta` + `kept: true`
    send_json("{\"id\":22,\"unsubscribe\":true}");
    send_json("{\"id\":23,\"call\":\"prefs.set\",\"params\":{\"appearance\":\"light\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #23 prefs.set -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":23") != NULL && strstr(m->json, "\"error\"") == NULL);
    send_json("{\"id\":231,\"call\":\"settings.set\",\"params\":{\"key\":\"theme\",\"value\":\"light\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":231") != NULL && strstr(m->json, "\"saved\":true") != NULL);

    char resub_diff[256];
    snprintf(resub_diff, sizeof(resub_diff), "{\"id\":24,\"subscribe\":{\"topic\":\"prefs\"},\"keyed\":true,\"have\":\"%s\"}", token);
    send_json(resub_diff);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #24 resubscribe have (changed) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":24") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "\"kept\":true") != NULL && strstr(m->json, "light") != NULL);
    send_json("{\"id\":24,\"unsubscribe\":true}");

    // 5b. Runtime-evaluated topic (`workspaceMarks`) live subscription + keep/have -> same + live delta on prefs.set
    // Verify `WireOutGen`: aggregate `workspaceMarks` carries `conn:<conn1>` + `authGen:1` (no `vaultGen`).
    send_json("{\"id\":25,\"subscribe\":{\"topic\":\"workspaceMarks\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #25 subscribe workspaceMarks -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":25") != NULL && strstr(m->json, "\"value\"") != NULL && strstr(m->json, "\"badgeKinds\"") != NULL);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL && strstr(m->json, "\"vaultGen\"") == NULL);

    send_json("{\"id\":25,\"unsubscribe\":true,\"keep\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #25 unsubscribe workspaceMarks keep -> %s\n", m->json);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL);
    char wm_token[128];
    assert(extract_v_token(m->json, wm_token, sizeof(wm_token)));

    char wm_resub[256];
    snprintf(wm_resub, sizeof(wm_resub), "{\"id\":26,\"subscribe\":{\"topic\":\"workspaceMarks\"},\"keyed\":true,\"have\":\"%s\"}", wm_token);
    send_json(wm_resub);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #26 resubscribe workspaceMarks have (unchanged) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":26") != NULL && strstr(m->json, "\"same\":true") != NULL && strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL);

    // Mutate prefs (`badgeKinds.on = false`) while subscribed to workspaceMarks -> expect Call OK + live delta on id 26!
    send_json("{\"id\":27,\"call\":\"prefs.set\",\"params\":{\"badgeKinds\":{\"on\":false}}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":27") != NULL && strstr(m->json, "\"error\"") == NULL);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #26 workspaceMarks live delta -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":26") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "\"badgeKinds\"") != NULL && strstr(m->json, "\"set\":false") != NULL);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL);
    send_json("{\"id\":26,\"unsubscribe\":true}");

    // 5b2. Vault topic `vaults` MUST carry `conn:<conn1>` + `authGen:1` + `vaultGen:1`!
    send_json("{\"id\":28,\"subscribe\":{\"topic\":\"vaults\",\"workspace\":\"ws-default\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #28 subscribe vaults -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":28") != NULL && strstr(m->json, "\"value\"") != NULL);
    assert(strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL && strstr(m->json, "\"vaultGen\":1") != NULL);
    send_json("{\"id\":28,\"unsubscribe\":true}");

    // 5b3. Real `ws/st` address subscription + cross-workspace identical-payload `(topic_key, token)` kept isolation
    // + invalid subscribe error frame (all stamped with `conn:<conn1>`).
    send_json("{\"id\":29,\"subscribe\":{\"topic\":\"chat\",\"station\":\"ws-default/st-local\",\"thread\":42},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #29 subscribe chat (real ws/st) -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":29") != NULL && strstr(m->json, conn1_kv) != NULL && strstr(m->json, "\"authGen\":1") != NULL && strstr(m->json, "\"vaultGen\"") == NULL);
    send_json("{\"id\":29,\"unsubscribe\":true}");

    // Cross-workspace identical-payload `kept` cache isolation in `core_runtime`:
    // `chats` for `ws-keep-a` and `ws-keep-b` produce identical empty payloads & identical `v` tokens.
    // Keeping `ws-keep-b` MUST NOT allow `ws-keep-a` to hit `same:true` with `ws-keep-b`'s token!
    send_json("{\"id\":291,\"subscribe\":{\"topic\":\"chats\",\"scope\":\"ws-keep-b\",\"mine\":false},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":291") != NULL && strstr(m->json, "\"value\"") != NULL);
    send_json("{\"id\":291,\"unsubscribe\":true,\"keep\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    char wsb_tok[128];
    assert(extract_v_token(m->json, wsb_tok, sizeof(wsb_tok)));
    char cross_ws_sub[256];
    snprintf(cross_ws_sub, sizeof(cross_ws_sub),
             "{\"id\":292,\"subscribe\":{\"topic\":\"chats\",\"scope\":\"ws-keep-a\",\"mine\":false},\"keyed\":true,\"have\":\"%s\"}",
             wsb_tok);
    send_json(cross_ws_sub);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #292 cross-ws have token -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":292") != NULL && strstr(m->json, "\"value\"") != NULL && strstr(m->json, "\"same\":true") == NULL);
    send_json("{\"id\":292,\"unsubscribe\":true}");
    char same_ws_sub[256];
    snprintf(same_ws_sub, sizeof(same_ws_sub),
             "{\"id\":293,\"subscribe\":{\"topic\":\"chats\",\"scope\":\"ws-keep-b\",\"mine\":false},\"keyed\":true,\"have\":\"%s\"}",
             wsb_tok);
    send_json(same_ws_sub);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #293 same-ws have token -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":293") != NULL && strstr(m->json, "\"same\":true") != NULL);
    send_json("{\"id\":293,\"unsubscribe\":true}");

    send_json("{\"id\":98,\"subscribe\":123}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #98 invalid subscribe error -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":98") != NULL && strstr(m->json, "\"error\"") != NULL && strstr(m->json, conn1_kv) != NULL);

    // 5c. W28a real runtime topic projectors (status, lockPrompts, notices, notify, doing, lock),
    // `chat {session, compact}`, and `auth.complete {query}` (zero verifier/code/error_description leak)
    send_json("{\"id\":50,\"subscribe\":{\"topic\":\"status\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #50 subscribe status -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":50") != NULL && strstr(m->json, "\"items\":[]") != NULL && strstr(m->json, "\"lines\":[]") != NULL);
    send_json("{\"id\":50,\"unsubscribe\":true}");

    send_json("{\"id\":51,\"subscribe\":{\"topic\":\"lockPrompts\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #51 subscribe lockPrompts -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":51") != NULL && strstr(m->json, "\"pairing\":[]") != NULL && strstr(m->json, "\"asks\":[]") != NULL);
    send_json("{\"id\":51,\"unsubscribe\":true}");

    send_json("{\"id\":52,\"subscribe\":{\"topic\":\"notices\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #52 subscribe notices -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":52") != NULL && strstr(m->json, "\"items\":[]") != NULL);
    send_json("{\"id\":52,\"unsubscribe\":true}");

    send_json("{\"id\":53,\"subscribe\":{\"topic\":\"doing\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #53 subscribe doing -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":53") != NULL && strstr(m->json, "\"doing\":[]") != NULL);
    send_json("{\"id\":53,\"unsubscribe\":true}");

    send_json("{\"id\":54,\"subscribe\":{\"topic\":\"notify\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #54 subscribe notify -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":54") != NULL && strstr(m->json, "\"permission\":\"unknown\"") != NULL && strstr(m->json, "\"workspaces\":") != NULL);

    send_json("{\"id\":55,\"call\":\"notify.permission\",\"params\":{\"state\":\"granted\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    assert(strstr(m->json, "\"id\":55") != NULL && strstr(m->json, "\"error\"") == NULL);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #54 notify live delta -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":54") != NULL && strstr(m->json, "\"delta\"") != NULL && strstr(m->json, "\"granted\"") != NULL);
    send_json("{\"id\":54,\"unsubscribe\":true}");

    send_json("{\"id\":56,\"subscribe\":{\"topic\":\"chat\",\"station\":\"st-local\",\"session\":\"new:chat-e2e-compact\",\"compact\":true},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #56 subscribe chat {session, compact} -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":56") != NULL && strstr(m->json, "\"pending\":true") != NULL && strstr(m->json, "\"messages\":[]") != NULL);
    send_json("{\"id\":56,\"unsubscribe\":true}");

    send_json("{\"id\":57,\"call\":\"auth.begin\",\"params\":{}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #57 auth.begin -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":57") != NULL && strstr(m->json, "\"verifier\"") == NULL);
    const char *st_pos = strstr(m->json, "\"state\":\"");
    assert(st_pos != NULL);
    st_pos += 9;
    char auth_state[128];
    size_t si = 0;
    while (st_pos[si] != '\0' && st_pos[si] != '"' && si + 1 < sizeof(auth_state)) {
        auth_state[si] = st_pos[si];
        si++;
    }
    auth_state[si] = '\0';
    assert(si > 0);
    char auth_complete_req[384];
    snprintf(auth_complete_req, sizeof(auth_complete_req),
             "{\"id\":58,\"call\":\"auth.complete\",\"params\":{\"query\":\"?state=%s&code=e2e_secret_code_99\"}}",
             auth_state);
    send_json(auth_complete_req);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #58 auth.complete {query} -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":58") != NULL && strstr(m->json, "\"ok\":true") != NULL);
    assert(strstr(m->json, "e2e_secret_code_99") == NULL && strstr(m->json, "verifier") == NULL);

    send_json("{\"id\":59,\"call\":\"auth.complete\",\"params\":{\"query\":\"?error=access_denied&error_description=UNVERIFIED_XSS_LEAK\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #59 auth.complete error query -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":59") != NULL && strstr(m->json, "\"error\"") != NULL);
    assert(strstr(m->json, "UNVERIFIED_XSS_LEAK") == NULL);

    // 6. Binary payload round-trip + screen_ack / screen_input / route_media
    static const uint8_t bin[4] = {'P', 'I', 'O', 'N'};
    static const char echo_req[] = "{\"id\":30,\"call\":\"echo.bytes\",\"params\":{\"ok\":true}}";
    mb_core_send(echo_req, sizeof(echo_req) - 1, bin, sizeof(bin));
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #30 echo.bytes -> %s (blen=%zu)\n", m->json, m->blen);
    assert(m->bytes != NULL && m->blen == 4 && memcmp(m->bytes, "PION", 4) == 0);

    pthread_t screen_th;
    assert(pthread_create(&screen_th, NULL, foreign_screen_thread, NULL) == 0);
    assert(pthread_join(screen_th, NULL) == 0);
    assert(mb_core_deliver_media(7, 2, 1, 88, 555, (const uint8_t *)"AV1!", 4) == 1);
    assert(g_ctx.last_media_seq == 88);

    // 7. Stop cleanly and verify zero post-stop callbacks, then restart on same dir to prove SQLite persistence!
    mb_core_stop();
    atomic_store(&g_ctx.stopped, 1);
    send_json("{\"id\":99,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    assert(atomic_load(&g_ctx.post_stop_count) == 0);

    // Inject a sibling TS field (`capRev:ws-1`) into `device/auth` before restart and prove
    // restart merges `"connSeq":<conn2>` while preserving existing fields!
    {
        FILE *f = fopen(dev_auth_path, "w");
        assert(f != NULL);
        fprintf(f, "{\"connSeq\":%lld,\"capRev:ws-1\":\"keep-me\"}", conn1);
        fclose(f);
    }

    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(data_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    // Restart handshake MUST strictly increment device-level `connSeq` (`conn2 > conn1`)!
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] restart auth handshake -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":0") != NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn2 = extract_conn_seq(m->json);
    assert(conn2 > conn1);
    char conn2_kv[64];
    snprintf(conn2_kv, sizeof(conn2_kv), "\"conn\":%lld", conn2);
    assert(strstr(m->json, conn2_kv) != NULL);
    // Verify `device/auth` preserved `"capRev:ws-1":"keep-me"` and updated `"connSeq":<conn2>`!
    {
        FILE *f = fopen(dev_auth_path, "r");
        assert(f != NULL);
        char buf2[512];
        size_t n2 = fread(buf2, 1, sizeof(buf2) - 1, f);
        fclose(f);
        buf2[n2] = '\0';
        char conn2_auth_kv[64];
        snprintf(conn2_auth_kv, sizeof(conn2_auth_kv), "\"connSeq\":%lld", conn2);
        assert(strstr(buf2, conn2_auth_kv) != NULL);
        assert(strstr(buf2, "\"capRev:ws-1\":\"keep-me\"") != NULL);
    }

    send_json("{\"id\":40,\"call\":\"settings.get\",\"params\":{\"key\":\"theme\"}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #40 settings.get after restart -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":40") != NULL && strstr(m->json, "\"value\":\"light\"") != NULL);

    send_json("{\"id\":41,\"call\":\"prefs.get\",\"params\":{}}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #41 prefs.get after restart -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":41") != NULL && strstr(m->json, "\"appearance\":\"light\"") != NULL && strstr(m->json, "\"size\":18") != NULL);

    // Post-restart subscription MUST carry `conn:<conn2>` (strictly monotonic across restarts)!
    send_json("{\"id\":42,\"subscribe\":{\"topic\":\"prefs\"},\"keyed\":true}");
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #42 subscribe prefs after restart -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":42") != NULL && strstr(m->json, conn2_kv) != NULL && strstr(m->json, "\"authGen\"") == NULL);
    send_json("{\"id\":42,\"unsubscribe\":true}");

    mb_core_stop();

    // 8. Corrupt `device/auth` MUST NOT be overwritten (protects TS `capRev:*` records!),
    //    and `connSeq` MUST persist to `device/conn_seq_floor` and stay strictly monotonic across restarts!
    {
        FILE *f = fopen(dev_auth_path, "w");
        assert(f != NULL);
        fputs("{corrupt-ts-device-auth capRev:ws-99", f);
        fclose(f);
    }
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(data_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] restart #3 (corrupt device/auth) handshake -> %s\n", m->json);
    assert(strstr(m->json, "\"id\":0") != NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn3 = extract_conn_seq(m->json);
    assert(conn3 > conn2);
    // Verify `device/auth` was NOT overwritten!
    {
        FILE *f = fopen(dev_auth_path, "r");
        assert(f != NULL);
        char buf3[512];
        size_t n3 = fread(buf3, 1, sizeof(buf3) - 1, f);
        fclose(f);
        buf3[n3] = '\0';
        assert(strcmp(buf3, "{corrupt-ts-device-auth capRev:ws-99") == 0);
    }
    // Verify `device/conn_seq_floor` was persisted at `data_dir/device%2Fconn_seq_floor` with `"connSeq":<conn3>`!
    {
        FILE *f = fopen(floor_path, "r");
        assert(f != NULL);
        char fbuf[256];
        size_t fn = fread(fbuf, 1, sizeof(fbuf) - 1, f);
        fclose(f);
        fbuf[fn] = '\0';
        char conn3_kv[64];
        snprintf(conn3_kv, sizeof(conn3_kv), "\"connSeq\":%lld", conn3);
        assert(strstr(fbuf, conn3_kv) != NULL);
    }
    mb_core_stop();

    // Restart #4 while `device/auth` is still corrupt -> reads `device/conn_seq_floor` and increments `conn4 > conn3`!
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(data_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] restart #4 (floor recovery) handshake -> %s\n", m->json);
    long long conn4 = extract_conn_seq(m->json);
    assert(conn4 > conn3);
    mb_core_stop();

    // 9. Fail-open connSeq recovery aligned with TS `core.ts:406-414` + safe-integer overflow protection:
    //    9a. Cold directory (NO `device/conn_seq_floor`) with corrupt `device/auth` MUST preserve
    //        `device/auth` byte-for-byte untouched AND start normally (no fatal brick!), writing a
    //        valid safe integer to `device/conn_seq_floor`.
    char cold_dir[160];
    snprintf(cold_dir, sizeof(cold_dir), "%s_cold", data_dir);
    assert(mkdir(cold_dir, 0700) == 0);
    char cold_auth_path[256];
    snprintf(cold_auth_path, sizeof(cold_auth_path), "%s/device%%2Fauth", cold_dir);
    {
        FILE *f = fopen(cold_auth_path, "w");
        assert(f != NULL);
        fputs("{corrupt-ts-cold capRev:ws-cold", f);
        fclose(f);
    }
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9a cold corrupt device/auth fail-open -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL);
    assert(strstr(m->json, "\"id\":0") != NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_cold = extract_conn_seq(m->json);
    assert(conn_cold > conn4 && conn_cold <= 9007199254740991LL);
    // Verify `device/auth` is preserved byte-for-byte and `device/conn_seq_floor` was written with `conn_cold`.
    {
        FILE *f = fopen(cold_auth_path, "r");
        assert(f != NULL);
        char cbuf[256];
        size_t cn = fread(cbuf, 1, sizeof(cbuf) - 1, f);
        fclose(f);
        cbuf[cn] = '\0';
        assert(strcmp(cbuf, "{corrupt-ts-cold capRev:ws-cold") == 0);
    }
    char cold_floor_path[256];
    snprintf(cold_floor_path, sizeof(cold_floor_path), "%s/device%%2Fconn_seq_floor", cold_dir);
    {
        FILE *f = fopen(cold_floor_path, "r");
        assert(f != NULL);
        char fbuf[256];
        size_t fn = fread(fbuf, 1, sizeof(fbuf) - 1, f);
        fclose(f);
        fbuf[fn] = '\0';
        char cold_kv[64];
        snprintf(cold_kv, sizeof(cold_kv), "\"connSeq\":%lld", conn_cold);
        assert(strstr(fbuf, cold_kv) != NULL);
    }
    mb_core_stop();

    //    9b. Corrupt `device/conn_seq_floor` containing a decimal (`12.5`) MUST be rejected,
    //        overwritten/repaired with a valid safe integer, and emit a valid `auth` handshake.
    {
        FILE *f = fopen(cold_floor_path, "w");
        assert(f != NULL);
        fputs("{\"connSeq\":12.5}", f);
        fclose(f);
    }
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9b decimal floor repair -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_dec = extract_conn_seq(m->json);
    assert(conn_dec > conn_cold && conn_dec <= 9007199254740991LL);
    {
        FILE *f = fopen(cold_floor_path, "r");
        assert(f != NULL);
        char fbuf[256];
        size_t fn = fread(fbuf, 1, sizeof(fbuf) - 1, f);
        fclose(f);
        fbuf[fn] = '\0';
        char dec_kv[64];
        snprintf(dec_kv, sizeof(dec_kv), "\"connSeq\":%lld", conn_dec);
        assert(strstr(fbuf, dec_kv) != NULL);
    }
    mb_core_stop();

    //    9c. Corrupt `device/conn_seq_floor` containing `Int64::MAX` (`9223372036854775807`) or
    //        over-limit `9007199254740991` MUST be rejected without overflow wraparound,
    //        overwritten/repaired with a valid safe integer, and an immediate 2nd restart MUST
    //        still increment strictly monotonically (`conn_ovf2 > conn_ovf`).
    {
        FILE *f = fopen(cold_floor_path, "w");
        assert(f != NULL);
        fputs("{\"connSeq\":9223372036854775807}", f);
        fclose(f);
    }
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9c Int64::MAX overflow floor repair -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_ovf = extract_conn_seq(m->json);
    assert(conn_ovf > conn_dec && conn_ovf <= 9007199254740991LL);
    {
        FILE *f = fopen(cold_floor_path, "r");
        assert(f != NULL);
        char fbuf[256];
        size_t fn = fread(fbuf, 1, sizeof(fbuf) - 1, f);
        fclose(f);
        fbuf[fn] = '\0';
        char ovf_kv[64];
        snprintf(ovf_kv, sizeof(ovf_kv), "\"connSeq\":%lld", conn_ovf);
        assert(strstr(fbuf, ovf_kv) != NULL);
    }
    mb_core_stop();

    // Immediate 2nd in-process restart after repair: strictly monotonic `conn_ovf2 > conn_ovf`
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9c2 post-repair 2nd restart -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_ovf2 = extract_conn_seq(m->json);
    assert(conn_ovf2 > conn_ovf && conn_ovf2 <= 9007199254740991LL);
    mb_core_stop();

    //    9d. Pre-seeded disk boundary `MAX_PERSISTED_CONN_SEQ` (`9007199253740991`):
    //        two consecutive in-process restarts MUST emit strictly monotonic `9007199253740992`
    //        and `9007199253740993` without dropping the in-process `floor`!
    {
        FILE *f = fopen(cold_floor_path, "w");
        assert(f != NULL);
        fputs("{\"connSeq\":9007199253740991}", f);
        fclose(f);
    }
    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9d boundary restart #1 -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_r1 = extract_conn_seq(m->json);
    assert(conn_r1 == 9007199253740992LL);
    mb_core_stop();

    atomic_store(&g_ctx.stopped, 0);
    mb_core_start(cold_dir, "https://app.still.fail", 1, on_host_message, &g_ctx);
    m = wait_for_msg_index(&g_ctx, next_idx++);
    printf("[core_runtime_e2e] #9d boundary restart #2 -> %s\n", m->json);
    assert(strstr(m->json, "\"fatal\"") == NULL && strstr(m->json, "\"auth\":{") != NULL);
    long long conn_r2 = extract_conn_seq(m->json);
    assert(conn_r2 == 9007199253740993LL && conn_r2 > conn_r1);
    mb_core_stop();

    printf("[core_runtime_e2e] ALL REAL core_api.h + libstillfail_shell.so E2E CHECKS PASSED (msgs=%d, post_stop=%d)\n",
           g_ctx.count, atomic_load(&g_ctx.post_stop_count));
    return 0;
}
