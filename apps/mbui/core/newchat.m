#import <Foundation/Foundation.h>
#include <math.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "core_api.h"

extern int mb_core_perf_line(double span_ms, char *out, size_t n);
extern int mb_core_tap_line(int who, char *out, size_t n);
int mb_perf_on(void) { return 1; }

#define MOST 16384
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
typedef struct {
  double at;
  int id;
  size_t len;
  int ok, error, value, delta, waiting;
  char *text;
} Msg;
static Msg got[MOST];
static int got_n;
static dispatch_semaphore_t told;

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1e6;
}

static void on_message(const char *json, size_t len, const uint8_t *bytes, size_t blen, void *ctx) {
  (void)bytes; (void)blen; (void)ctx;
  double at = now_ms();
  int id = -1;
  if (len > 6 && strncmp(json, "{\"id\":", 6) == 0) id = atoi(json + 6);
  size_t head = len < 80 ? len : 80;
  char *text = NULL;
  if (len < 512 * 1024) {
    text = malloc(len + 1);
    memcpy(text, json, len);
    text[len] = 0;
  }
  os_unfair_lock_lock(&lock);
  if (got_n < MOST) {
    got[got_n].at = at;
    got[got_n].id = id;
    got[got_n].len = len;
    got[got_n].ok = memmem(json, head, "\"ok\":", 5) != NULL;
    got[got_n].error = memmem(json, head, "\"error\":", 8) != NULL;
    got[got_n].value = memmem(json, head, "\"value\":", 8) != NULL;
    got[got_n].delta = memmem(json, head, "\"delta\":", 8) != NULL;
    got[got_n].waiting = memmem(json, head, "\"waiting\":", 10) != NULL;
    got[got_n].text = text;
    got_n++;
    text = NULL;
  }
  os_unfair_lock_unlock(&lock);
  free(text);
  dispatch_semaphore_signal(told);
}

static int next_id = 100;
static char id_label[32768][64];

static int send_json_bytes(const char *label, NSString *json, const uint8_t *bytes, size_t blen) {
  int id = next_id++;
  if (id < 32768) snprintf(id_label[id], 64, "%s", label);
  NSString *full = [NSString stringWithFormat:@"{\"id\":%d,%@", id, json];
  NSData *d = [full dataUsingEncoding:NSUTF8StringEncoding];
  mb_core_send(d.bytes, d.length, bytes, blen);
  return id;
}

static int sub_topic(const char *label, NSString *topicJson) {
  return send_json_bytes(label, [NSString stringWithFormat:@"\"subscribe\":%@,\"keyed\":true}", topicJson], NULL, 0);
}

static void unsub(int id) {
  NSString *full = [NSString stringWithFormat:@"{\"id\":%d,\"unsubscribe\":true}", id];
  NSData *d = [full dataUsingEncoding:NSUTF8StringEncoding];
  mb_core_send(d.bytes, d.length, NULL, 0);
}

static int call_op(const char *label, NSString *name, NSString *paramsJson) {
  return send_json_bytes(label, [NSString stringWithFormat:@"\"call\":\"%@\",\"params\":%@}", name, paramsJson], NULL, 0);
}

static int call_op_bytes(const char *label, NSString *name, NSString *paramsJson, const uint8_t *bytes, size_t blen) {
  return send_json_bytes(label, [NSString stringWithFormat:@"\"call\":\"%@\",\"params\":%@}", name, paramsJson], bytes, blen);
}

static void clear_msgs(void) {
  os_unfair_lock_lock(&lock);
  for (int i = 0; i < got_n; i++) free(got[i].text);
  got_n = 0;
  os_unfair_lock_unlock(&lock);
}

static void reset_perf(void) {
  char buf[1024];
  mb_core_perf_line(1000.0, buf, sizeof buf);
  mb_core_tap_line(0, buf, sizeof buf);
}

static void dump_perf(const char *tag, double span_ms) {
  char js[1024] = {0}, tap[1024] = {0};
  mb_core_perf_line(span_ms, js, sizeof js);
  mb_core_tap_line(0, tap, sizeof tap);
  printf("  [perf %s %.1fms] js: %s\n", tag, span_ms, js[0] ? js : "(idle)");
  printf("  [perf %s %.1fms] shell: %s\n", tag, span_ms, tap[0] ? tap : "(none)");
}

// Extract newChat's `next` key and `station.station` from latest newChat value
static NSString *last_new_next = nil;
static NSString *last_new_station = nil;

static void parse_new_chat(const char *text) {
  if (!text) return;
  NSData *d = [NSData dataWithBytes:text length:strlen(text)];
  NSDictionary *m = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  NSDictionary *v = m[@"value"];
  if (![v isKindOfClass:[NSDictionary class]]) return;
  if ([v[@"next"] isKindOfClass:[NSString class]] && [v[@"next"] length] > 0) last_new_next = v[@"next"];
  NSDictionary *st = v[@"station"];
  if ([st isKindOfClass:[NSDictionary class]] && [st[@"station"] isKindOfClass:[NSString class]]) last_new_station = st[@"station"];
}

static int new_chat_sub_id = -1;

static void drain_and_print(double t0, double wait_ms, int watch_call_id, double *call_done_at) {
  int cursor = 0;
  double deadline = t0 + wait_ms;
  while (now_ms() < deadline) {
    dispatch_semaphore_wait(told, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_MSEC)));
    for (;;) {
      os_unfair_lock_lock(&lock);
      int have = got_n;
      os_unfair_lock_unlock(&lock);
      if (cursor >= have) break;
      Msg m = got[cursor++];
      double rel = m.at - t0;
      const char *lbl = (m.id >= 0 && m.id < 32768 && id_label[m.id][0]) ? id_label[m.id] : "?";
      const char *kind = m.ok ? "ok" : m.error ? "ERR" : m.delta ? "delta" : m.value ? "value" : m.waiting ? "wait" : "msg";
      if (m.id == new_chat_sub_id && m.value) parse_new_chat(m.text);
      if (m.id == watch_call_id && (m.ok || m.error) && call_done_at && *call_done_at < 0) *call_done_at = rel;
      printf("    +%7.2f ms  %-5s id=%-4d %-24s %7zu B%s\n", rel, kind, m.id, lbl, m.len,
             (m.error && m.text) ? [NSString stringWithFormat:@"  %.120s", m.text].UTF8String : "");
    }
    if (watch_call_id > 0 && call_done_at && *call_done_at >= 0 && now_ms() - (t0 + *call_done_at) > 150.0) break;
  }
}


// Waits for subscription `id`'s first value (at most `most` ms): how long it took, or -1.
static double wait_value(int id, double most) {
  double t0 = now_ms();
  int cursor = 0;
  os_unfair_lock_lock(&lock);
  cursor = got_n;
  os_unfair_lock_unlock(&lock);
  while (now_ms() - t0 < most) {
    dispatch_semaphore_wait(told, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_MSEC)));
    os_unfair_lock_lock(&lock);
    int have = got_n;
    int found = 0;
    for (; cursor < have; cursor++) if (got[cursor].id == id && (got[cursor].value || got[cursor].error)) found = 1;
    os_unfair_lock_unlock(&lock);
    if (found) return now_ms() - t0;
  }
  return -1;
}
static void do_new_send(double t0, NSString *station, NSString *key, NSString *words, NSString *uploadsJson) {
  call_op("composer.starting(1)", @"composer.starting", @"{\"key\":\"new:ws\",\"starting\":true}");
  int take_id = call_op("composer.take", @"composer.take", [NSString stringWithFormat:@"{\"key\":\"new:ws\",\"station\":\"%@\"}", station]);
  int create_id = call_op("newChat.create", @"newChat.create", [NSString stringWithFormat:@"{\"station\":\"%@\",\"key\":\"%@\"}", station, key]);
  call_op("composer.carry", @"composer.carry", [NSString stringWithFormat:@"{\"key\":\"new:ws\",\"to\":\"%@:%@\"}", station, key]);
  // Transition NewChat -> Chat(r) in place, exactly as page_pane.mbt + chat_page_made do:
  call_op("chat.window", @"chat.window", [NSString stringWithFormat:@"{\"station\":\"%@\",\"session\":\"%@\",\"rows\":30}", station, key]);
  int s_chat = sub_topic("sub:chat", [NSString stringWithFormat:@"{\"topic\":\"chat\",\"station\":\"%@\",\"session\":\"%@\",\"compact\":true}", station, key]);
  int s_comp = sub_topic("sub:composer(chat)", [NSString stringWithFormat:@"{\"topic\":\"composer\",\"key\":\"%@:%@\"}", station, key]);
  int s_row  = sub_topic("sub:chatRow", [NSString stringWithFormat:@"{\"topic\":\"chatRow\",\"station\":\"%@\",\"session\":\"%@\"}", station, key]);
  int s_jobs = sub_topic("sub:chatJobs", [NSString stringWithFormat:@"{\"topic\":\"chatJobs\",\"station\":\"%@\",\"session\":\"%@\",\"summary\":true,\"compact\":true}", station, key]);
  if (new_chat_sub_id > 0) { unsub(new_chat_sub_id); new_chat_sub_id = -1; }

  // Wait for take + create before firing chat.send, just as new_chat.mbt's `send()` callback waits for `taken.val` and `made.val`!
  int got_take = 0, got_create = 0;
  int cursor = 0;
  double deadline = t0 + 10000.0;
  int send_id = -1;
  while (now_ms() < deadline) {
    dispatch_semaphore_wait(told, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_MSEC)));
    for (;;) {
      os_unfair_lock_lock(&lock);
      int have = got_n;
      os_unfair_lock_unlock(&lock);
      if (cursor >= have) break;
      Msg m = got[cursor++];
      double rel = m.at - t0;
      const char *lbl = (m.id >= 0 && m.id < 32768 && id_label[m.id][0]) ? id_label[m.id] : "?";
      const char *kind = m.ok ? "ok" : m.error ? "ERR" : m.delta ? "delta" : m.value ? "value" : m.waiting ? "wait" : "msg";
      if (m.id == new_chat_sub_id && m.value) parse_new_chat(m.text);
      printf("    +%7.2f ms  %-5s id=%-4d %-24s %7zu B%s\n", rel, kind, m.id, lbl, m.len,
             (m.error && m.text) ? [NSString stringWithFormat:@"  %.120s", m.text].UTF8String : "");
      if (m.id == take_id && (m.ok || m.error)) got_take = 1;
      if (m.id == create_id && (m.ok || m.error)) got_create = 1;
      if (got_take && got_create && send_id < 0) {
        NSString *p = [NSString stringWithFormat:@"{\"station\":\"%@\",\"session\":\"%@\",\"text\":%@,\"attachments\":[],\"quotes\":[]%@}",
                       station, key, words, uploadsJson ?: @""];
        send_id = call_op("chat.send", @"chat.send", p);
        printf("    +%7.2f ms  --> fired chat.send (id=%d) after take+create\n", now_ms() - t0, send_id);
      }
      if (send_id > 0 && m.id == send_id && (m.ok || m.error)) {
        call_op("composer.starting(0)", @"composer.starting", @"{\"key\":\"new:ws\",\"starting\":false}");
        deadline = now_ms() + 150.0;
      }
    }
  }
  unsub(s_chat); unsub(s_comp); unsub(s_row); unsub(s_jobs);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: newchat <data_dir>\n"); return 2; }
    told = dispatch_semaphore_create(0);
    int up = getenv("STATIONS") && strcmp(getenv("STATIONS"), "up") == 0;
    double boot0 = now_ms();
    mb_core_start(argv[1], up ? "http://192.0.2.1:9" : "http://127.0.0.1:9", 0, on_message, NULL);

    printf("\n=== 1. BOOT + OPEN WIDE FRAME LANDING ON NEWCHAT (ws) ===\n");
    reset_perf();
    sub_topic("sub:prefs", @"{\"topic\":\"prefs\"}");
    sub_topic("sub:accounts", @"{\"topic\":\"accounts\"}");
    sub_topic("sub:workspaces", @"{\"topic\":\"workspaces\"}");
    sub_topic("sub:downloads", @"{\"topic\":\"downloads\"}");
    sub_topic("sub:lock", @"{\"topic\":\"lock\",\"workspace\":\"ws\"}");
    sub_topic("sub:workspaceMarks", @"{\"topic\":\"workspaceMarks\"}");
    call_op("chats.window(30)", @"chats.window", @"{\"scope\":\"ws\",\"mine\":false,\"rows\":30}");
    sub_topic("sub:chats(ws)", @"{\"topic\":\"chats\",\"scope\":\"ws\",\"mine\":false}");
    sub_topic("sub:longJobs", @"{\"topic\":\"longJobs\",\"scope\":\"ws\"}");
    sub_topic("sub:status", @"{\"topic\":\"status\",\"workspace\":\"ws\"}");
    sub_topic("sub:driveTransfers", @"{\"topic\":\"driveTransfers\",\"workspace\":\"ws\"}");
    sub_topic("sub:stations", @"{\"topic\":\"stations\",\"scope\":\"ws\"}");
    new_chat_sub_id = sub_topic("sub:newChat", @"{\"topic\":\"newChat\",\"scope\":\"ws\"}");
    int comp_new_id = sub_topic("sub:composer(new)", @"{\"topic\":\"composer\",\"key\":\"new:ws\"}");
    (void)comp_new_id;
    drain_and_print(boot0, 2500.0, -1, NULL);
    dump_perf("boot", now_ms() - boot0);
    printf("  newChat resolved: station=%s next=%s\n",
           last_new_station ? last_new_station.UTF8String : "(nil)",
           last_new_next ? last_new_next.UTF8String : "(nil)");

    // Let background startup settle
    clear_msgs();
    usleep(500 * 1000);
    clear_msgs();

    NSString *st = last_new_station ?: @"ws/maple";

    printf("\n=== 2. WARM PLAIN-TEXT NEWCHAT SEND (chats.window=30) ===\n");
    reset_perf();
    double t2 = now_ms();
    call_op("composer.text", @"composer.text", @"{\"key\":\"new:ws\",\"text\":\"把发布说明写一下\"}");
    NSString *k2 = last_new_next ?: @"new:probe-plain-1";
    do_new_send(t2, st, k2, @"\"把发布说明写一下\"", nil);
    dump_perf("plain-send", now_ms() - t2);

    // Re-open NewChat
    clear_msgs();
    new_chat_sub_id = sub_topic("sub:newChat", @"{\"topic\":\"newChat\",\"scope\":\"ws\"}");
    drain_and_print(now_ms(), 400.0, -1, NULL);
    clear_msgs();

    printf("\n=== 3. NEWCHAT TYPE '@maple' (6 chatSearch subs w/ elsewhere=true) + PICK 2 REFS + IMMEDIATE ENTER ===\n");
    reset_perf();
    double t3 = now_ms();
    NSArray<NSString *> *queries = @[@"", @"m", @"ma", @"map", @"mapl", @"maple"];
    int prev_search = -1;
    for (NSString *q in queries) {
      NSString *txt = [NSString stringWithFormat:@"@%@", q];
      call_op("composer.text", @"composer.text", [NSString stringWithFormat:@"{\"key\":\"new:ws\",\"text\":\"%@\"}", txt]);
      call_op("ref.at", @"ref.at", [NSString stringWithFormat:@"{\"text\":\"%@\",\"caret\":%lu}", txt, (unsigned long)txt.length]);
      if (prev_search > 0) unsub(prev_search);
      prev_search = sub_topic("sub:chatSearch",
        [NSString stringWithFormat:@"{\"topic\":\"chatSearch\",\"scope\":\"ws\",\"query\":\"%@\",\"station\":\"%@\",\"limit\":8,\"elsewhere\":true}", q, st]);
      // (held till its menu shows, as a person typing sees it, a letter after another)
      printf("    '@%s' typed: chatSearch's first value in %.1f ms\n", q.UTF8String, wait_value(prev_search, 5000));
      usleep(120 * 1000);
    }
    if (prev_search > 0) unsub(prev_search);
    // Pick 2 chats (1 local ws/maple, 1 cross-ws or local) and immediately press Enter:
    call_op("chat.ref(1)", @"chat.ref", [NSString stringWithFormat:@"{\"station\":\"%@\",\"id\":\"k-maple-0\",\"title\":\"Monoid 看板模式想法\",\"base\":\"https://app.still.fail\",\"into\":\"ws\"}", st]);
    call_op("chat.ref(2)", @"chat.ref", [NSString stringWithFormat:@"{\"station\":\"%@\",\"id\":\"k-maple-1\",\"title\":\"group：基于 monoid 基建的 IM\",\"base\":\"https://app.still.fail\",\"into\":\"ws\"}", st]);
    NSString *refMsg = @"@[Monoid 看板模式想法] @[group：基于 monoid 基建的 IM] 这俩为啥卡了几个小时";
    call_op("composer.text", @"composer.text", [NSString stringWithFormat:@"{\"key\":\"new:ws\",\"text\":\"%@\"}", refMsg]);
    call_op("ref.marks", @"ref.marks", [NSString stringWithFormat:@"{\"text\":\"%@\"}", refMsg]);
    call_op("ref.words", @"ref.words", [NSString stringWithFormat:@"{\"text\":\"%@\"}", refMsg]);
    // Now user presses Enter! Because words contains "@[", send_sharing calls chat.outsideRefs BEFORE calling new_send!
    double enter_at = now_ms();
    int out_id = call_op("chat.outsideRefs", @"chat.outsideRefs", [NSString stringWithFormat:@"{\"station\":\"%@\",\"text\":\"%@\"}", st, refMsg]);
    double out_done = -1;
    drain_and_print(t3, 10000.0, out_id, &out_done);
    printf("  --> Enter pressed at +%.2f ms; chat.outsideRefs answered at +%.2f ms (Enter-to-outsideRefs latency = %.2f ms)\n",
           enter_at - t3, out_done, out_done - (enter_at - t3));
    NSString *k3 = last_new_next ?: @"new:probe-at-1";
    do_new_send(now_ms(), st, k3, [NSString stringWithFormat:@"\"%@\"", refMsg], nil);
    dump_perf("at-search-and-send", now_ms() - t3);

    // Re-open NewChat
    clear_msgs();
    new_chat_sub_id = sub_topic("sub:newChat", @"{\"topic\":\"newChat\",\"scope\":\"ws\"}");
    drain_and_print(now_ms(), 400.0, -1, NULL);
    clear_msgs();

    printf("\n=== 4. NEWCHAT PASTE 2 CHAT LINKS (ref.pasted -> chat.ref) + IMMEDIATE ENTER ===\n");
    reset_perf();
    double t4 = now_ms();
    NSString *pastedLinks = @"https://app.still.fail/w/ws/s/maple/chats/k-maple-0 https://app.still.fail/w/ws/s/maple/chats/k-maple-1 这俩为啥卡了几个小时";
    int pasted_id = call_op("ref.pasted", @"ref.pasted", [NSString stringWithFormat:@"{\"text\":\"%@\",\"here\":\"%@\"}", pastedLinks, st]);
    double pasted_done = -1;
    drain_and_print(t4, 5000.0, pasted_id, &pasted_done);
    printf("  --> ref.pasted answered at +%.2f ms\n", pasted_done);
    dump_perf("paste-links", now_ms() - t4);

    // Re-open NewChat + test 24 MB image/video attachment!
    clear_msgs();
    printf("\n=== 5. NEWCHAT ATTACH 24 MB FILE/VIDEO (composer.add w/ bytes) + IMMEDIATE ENTER ===\n");
    reset_perf();
    size_t fsize = 24 * 1024 * 1024;
    uint8_t *fbytes = calloc(1, fsize);
    // PNG header so imageSize inspects it
    const uint8_t png[24] = {0x89,'P','N','G',0x0d,0x0a,0x1a,0x0a, 0,0,0,13,'I','H','D','R', 0,0,0x0b,0xd0, 0,0,0x07,0xac};
    memcpy(fbytes, png, 24);
    double t5 = now_ms();
    NSString *addParams = [NSString stringWithFormat:
      @"{\"key\":\"new:ws\",\"station\":\"%@\",\"files\":[{\"id\":\"f-probe-24m\",\"name\":\"demo.mp4\",\"size\":%zu,\"blob\":{\"hostBytes\":[0,%zu],\"type\":\"video/mp4\"}}]}",
      st, fsize, fsize];
    int add_id = call_op_bytes("composer.add(24MB)", @"composer.add", addParams, fbytes, fsize);
    call_op("composer.text", @"composer.text", @"{\"key\":\"new:ws\",\"text\":\"看看这个录屏\"}");
    double add_done = -1;
    drain_and_print(t5, 5000.0, add_id, &add_done);
    printf("  --> composer.add(24MB) answered at +%.2f ms; now pressing Enter!\n", add_done);
    double t5_send = now_ms();
    NSString *k5 = last_new_next ?: @"new:probe-file-1";
    NSString *upJson = [NSString stringWithFormat:@",\"uploads\":[{\"id\":\"f-probe-24m\",\"name\":\"demo.mp4\",\"size\":%zu}]", fsize];
    do_new_send(t5_send, st, k5, @"\"看看这个录屏\"", upJson);
    // Let #upload / #keepWhole / uploadName SHA-256 run for 1500ms while probing Hermes responsiveness!
    double ping0 = now_ms();
    int ping_id = call_op("ping(ref.at)", @"ref.at", @"{\"text\":\"hello\",\"caret\":5}");
    double ping_done = -1;
    drain_and_print(ping0, 5000.0, ping_id, &ping_done);
    printf("  --> Hermes ping right after 24MB NewChat send answered in %.2f ms\n", ping_done);
    free(fbytes);
    dump_perf("file-24mb-send", now_ms() - t5);

    printf("\n=== 6. GROW CHATS WINDOW TO 600 (board/scrolled) + NEWCHAT SEND ===\n");
    clear_msgs();
    new_chat_sub_id = sub_topic("sub:newChat", @"{\"topic\":\"newChat\",\"scope\":\"ws\"}");
    call_op("chats.window(600)", @"chats.window", @"{\"scope\":\"ws\",\"mine\":false,\"rows\":600}");
    drain_and_print(now_ms(), 1500.0, -1, NULL);
    clear_msgs();
    reset_perf();
    double t6 = now_ms();
    call_op("composer.text", @"composer.text", @"{\"key\":\"new:ws\",\"text\":\"大窗口下新建对话发送\"}");
    NSString *k6 = last_new_next ?: @"new:probe-win600-1";
    do_new_send(t6, st, k6, @"\"大窗口下新建对话发送\"", nil);
    dump_perf("win600-send", now_ms() - t6);

    mb_core_stop();
    return 0;
  }
}
