// src/host/apple_reports.m's tests: a report MetricKit gave (its JSON, as MXCrashDiagnostic's and MXHangDiagnostic's
// JSONRepresentation have it) turned into the `$exception` event PostHog is sent. Run on a Mac by
// scripts/ios-reports-test.sh (Foundation's alone: no MetricKit, no device).
#define SF_REPORTS_PURE 1
#include "../src/host/apple_reports.m"

static int failed;

#define CHECK(c)                                                      \
  do {                                                                \
    if (!(c)) {                                                       \
      fprintf(stderr, "%s:%d: failed: %s\n", __FILE__, __LINE__, #c); \
      failed = 1;                                                     \
    }                                                                 \
  } while (0)
#define SAME(got, want)                                                                                         \
  do {                                                                                                          \
    id got_ = (got), want_ = (want);                                                                            \
    if (!(got_ == want_ || [got_ isEqual:want_])) {                                                             \
      fprintf(stderr, "%s:%d: %s\n  gave %s\n  want %s\n", __FILE__, __LINE__, #got, [got_ description].UTF8String, \
              [want_ description].UTF8String);                                                                  \
      failed = 1;                                                                                               \
    }                                                                                                           \
  } while (0)

static NSDictionary *frame(NSString *binary, NSString *uuid, long long offset, long long address, NSDictionary *caller) {
  NSMutableDictionary *f = [@{@"binaryName" : binary, @"binaryUUID" : uuid, @"offsetIntoBinaryTextSegment" : @(offset),
                              @"address" : @(address), @"sampleCount" : @1} mutableCopy];
  if (caller) f[@"subFrames"] = @[ caller ];
  return f;
}

static NSString *const APP_UUID = @"0B6F2A54-3A1C-3C61-9D0E-5C2B7D3B8A11";
static NSString *const KERNEL_UUID = @"A1B2C3D4-0000-3000-8000-0000000000AA";

// A crash as build 37 on an iPhone18,2 sent it: SIGSEGV in the app's own binary, called from UIKit; another thread's
// stack first in the list, not the crashed one.
static NSDictionary *segv(void) {
  NSDictionary *crashed = frame(@"mbui", APP_UUID, 0x1234, 0x100001234,
                                frame(@"mbui", APP_UUID, 0x5678, 0x100005678, frame(@"UIKitCore", KERNEL_UUID, 0x9abc, 0x18f009abc, nil)));
  NSDictionary *other = frame(@"libsystem_kernel.dylib", KERNEL_UUID, 0x10, 0x1e0000010, nil);
  return @{
    @"version" : @"1.0.0",
    @"callStackTree" : @{
      @"callStackPerThread" : @YES,
      @"callStacks" : @[ @{@"threadAttributed" : @NO, @"callStackRootFrames" : @[ other ]},
                         @{@"threadAttributed" : @YES, @"callStackRootFrames" : @[ crashed ]} ],
    },
    @"diagnosticMetaData" : @{
      @"appVersion" : @"0.1.0",
      @"appBuildVersion" : @"37",
      @"osVersion" : @"iPhone OS 27.2 (24C101)",
      @"deviceType" : @"iPhone18,2",
      @"platformArchitecture" : @"arm64e",
      @"bundleIdentifier" : @"fail.still.iphone",
      @"isTestFlightApp" : @YES,
      @"exceptionType" : @1,
      @"exceptionCode" : @0,
      @"signal" : @11,
      @"terminationReason" : @"Namespace SIGNAL, Code 11 Segmentation fault: 11",
      @"virtualMemoryRegionInfo" : @"0 is not in any region.",
    },
  };
}

static NSDictionary *const_here(void) {
  return @{@"app" : @"ios", @"$lib" : @"stillfail-ios", @"release" : @"0.1.0 (38)", @"$os" : @"iOS", @"$device_manufacturer" : @"Apple"};
}

int main(void) {
  @autoreleasepool {
    NSString *rid = sf_report_id(@"crash", segv());
    // the id: 16 bytes of hex, the same for the same report however its dictionary was made, another for a hang's
    CHECK(rid.length == 32);
    NSMutableDictionary *again = [NSMutableDictionary dictionary];
    for (NSString *k in [segv().allKeys reverseObjectEnumerator]) again[k] = segv()[k];
    SAME(sf_report_id(@"crash", again), rid);
    CHECK(![sf_report_id(@"hang", segv()) isEqual:rid]);
    // its uuid: of the id, a name's (version 5, RFC 4122's variant)
    NSString *uuid = sf_report_uuid(rid);
    CHECK([[NSUUID alloc] initWithUUIDString:uuid] != nil);
    SAME([uuid substringWithRange:NSMakeRange(14, 1)], @"5");
    CHECK([@"89ab" containsString:[uuid substringWithRange:NSMakeRange(19, 1)]]);
    SAME(sf_report_uuid(rid), uuid);

    NSDictionary *e = sf_report_event(@{@"kind" : @"crash", @"at" : @1794030000123.0, @"diagnostic" : segv()}, rid, @"108123", const_here());
    SAME(e[@"event"], @"$exception");
    SAME(e[@"distinct_id"], @"108123");
    SAME(e[@"uuid"], uuid);
    SAME(e[@"timestamp"], @"2026-11-07T05:40:00.123Z");
    NSDictionary *p = e[@"properties"];
    SAME(p[@"$exception_level"], @"fatal");
    SAME(p[@"reason"], @"crash");
    NSDictionary *x = [p[@"$exception_list"] firstObject];
    SAME(x[@"type"], @"SIGSEGV");
    SAME(x[@"value"], @"EXC_BAD_ACCESS: Namespace SIGNAL, Code 11 Segmentation fault: 11");
    SAME(x[@"mechanism"][@"handled"], @NO);
    SAME(x[@"mechanism"][@"type"], @"signalhandler");
    // the build and device the report says, over the app's now
    SAME(p[@"release"], @"0.1.0 (37)");
    SAME(p[@"$app_version"], @"0.1.0");
    SAME(p[@"$app_build"], @"37");
    SAME(p[@"$os_version"], @"27.2");
    SAME(p[@"os_build"], @"iPhone OS 27.2 (24C101)");
    SAME(p[@"$device_model"], @"iPhone18,2");
    SAME(p[@"app"], @"ios");
    SAME(p[@"$lib"], @"stillfail-ios");
    SAME(p[@"testflight"], @YES);
    SAME(p[@"signal"], @"SIGSEGV");
    SAME(p[@"exception_type"], @"EXC_BAD_ACCESS");
    SAME(p[@"exception_code"], @0);
    SAME(p[@"vm_region"], @"0 is not in any region.");
    // the attributed thread's frames, innermost first, each with what the dSYM is read by
    NSArray *frames = p[@"frames"];
    SAME(@(frames.count), @3);
    SAME(frames[0], (@{@"binary" : @"mbui", @"uuid" : APP_UUID, @"offset" : @0x1234, @"address" : @0x100001234}));
    SAME(frames[2][@"binary"], @"UIKitCore");
    SAME(p[@"$exception_fingerprint"], @"ios:SIGSEGV:mbui + 0x1234|mbui + 0x5678|UIKitCore + 0x9abc");
    NSString *trace = p[@"trace"];
    CHECK([trace hasPrefix:@"EXC_BAD_ACCESS (SIGSEGV)\nCrashed thread:\n0   mbui"]);
    CHECK([trace containsString:@"0x100005678 + 22136 (0B6F2A54-3A1C-3C61-9D0E-5C2B7D3B8A11)"]);
    CHECK(![trace containsString:@"libsystem_kernel"]);

    // an Objective-C exception not caught: its name the type, its message said
    NSMutableDictionary *objc = segv().mutableCopy, *meta = [segv()[@"diagnosticMetaData"] mutableCopy];
    meta[@"signal"] = @6;
    meta[@"exceptionType"] = @10;
    meta[@"terminationReason"] = nil;
    meta[@"objectiveCexceptionReason"] = @{@"exceptionName" : @"NSInvalidArgumentException", @"composedMessage" : @"-[__NSCFNumber length]: unrecognized selector"};
    objc[@"diagnosticMetaData"] = meta;
    NSDictionary *o = sf_report_event(@{@"kind" : @"crash", @"at" : @0, @"diagnostic" : objc}, sf_report_id(@"crash", objc), @"108123", const_here())[@"properties"];
    SAME([o[@"$exception_list"] firstObject][@"type"], @"NSInvalidArgumentException");
    SAME([o[@"$exception_list"] firstObject][@"value"], @"EXC_CRASH (SIGABRT): -[__NSCFNumber length]: unrecognized selector");
    SAME(o[@"objc_exception"], @"NSInvalidArgumentException");
    CHECK([o[@"$exception_fingerprint"] hasPrefix:@"ios:NSInvalidArgumentException:mbui + 0x1234|"]);

    // a hang: the main thread's frames, an error, how long
    NSMutableDictionary *hang = segv().mutableCopy;
    hang[@"diagnosticMetaData"] = @{@"appVersion" : @"0.1.0", @"appBuildVersion" : @"37", @"hangDuration" : @"3.25 sec"};
    NSDictionary *h = sf_report_event(@{@"kind" : @"hang", @"at" : @0, @"hang_ms" : @3250, @"diagnostic" : hang}, sf_report_id(@"hang", hang), @"108123", const_here())[@"properties"];
    SAME(h[@"$exception_level"], @"error");
    SAME(h[@"reason"], @"hang");
    SAME(h[@"hang_ms"], @3250);
    SAME([h[@"$exception_list"] firstObject][@"type"], @"Hang");
    SAME([h[@"$exception_list"] firstObject][@"value"], @"the main thread hung 3.2 s");
    SAME([h[@"$exception_list"] firstObject][@"mechanism"][@"type"], @"hang");
    CHECK([h[@"$exception_fingerprint"] hasPrefix:@"ios:Hang:mbui + 0x1234|"]);
    CHECK([h[@"trace"] containsString:@"Main thread:\n"]);

    // what is not a report this makes: no account, a kind of its own, no diagnostic, no id
    CHECK(sf_report_event(@{@"kind" : @"crash", @"at" : @0, @"diagnostic" : segv()}, rid, @"", const_here()) == nil);
    CHECK(sf_report_event(@{@"kind" : @"cpu", @"at" : @0, @"diagnostic" : segv()}, rid, @"108123", const_here()) == nil);
    CHECK(sf_report_event(@{@"kind" : @"crash", @"at" : @0}, rid, @"108123", const_here()) == nil);
    CHECK(sf_report_event(@{@"kind" : @"crash", @"at" : @0, @"diagnostic" : segv()}, @"short", @"108123", const_here()) == nil);
    // a report with no stacks: still an event, with no fingerprint (PostHog groups it by its type)
    NSDictionary *bare = sf_report_event(@{@"kind" : @"crash", @"at" : @0, @"diagnostic" : @{@"diagnosticMetaData" : @{@"signal" : @9}}}, rid, @"108123", const_here());
    SAME([bare[@"properties"][@"$exception_list"] firstObject][@"type"], @"SIGKILL");
    CHECK(bare[@"properties"][@"$exception_fingerprint"] == nil);
    SAME(bare[@"properties"][@"release"], @"0.1.0 (38)");
    // the whole event is JSON PostHog takes
    CHECK([NSJSONSerialization isValidJSONObject:e]);

    // macOS MetricKit crash & hang: fingerprint uses "macos:" prefix instead of "ios:"
    NSDictionary *mac_here = @{@"app" : @"macos", @"$lib" : @"stillfail-macos", @"release" : @"0.1.0 (38)", @"$os" : @"macOS", @"$device_manufacturer" : @"Apple"};
    NSDictionary *me = sf_report_event(@{@"kind" : @"crash", @"at" : @1794030000123.0, @"diagnostic" : segv()}, rid, @"108123", mac_here);
    SAME(me[@"properties"][@"$exception_fingerprint"], @"macos:SIGSEGV:mbui + 0x1234|mbui + 0x5678|UIKitCore + 0x9abc");
    NSDictionary *mh = sf_report_event(@{@"kind" : @"hang", @"at" : @0, @"hang_ms" : @2500, @"diagnostic" : hang}, sf_report_id(@"hang", hang), @"108123", mac_here);
    CHECK([mh[@"properties"][@"$exception_fingerprint"] hasPrefix:@"macos:Hang:mbui + 0x1234|"]);

    // watchdog_hang event: macOS and iOS formats, valid JSON, requires hang_ms > 0
    NSString *wd_rid = @"0123456789abcdef0123456789abcdef";
    NSDictionary *wd_mac = sf_report_event(@{@"kind" : @"watchdog_hang", @"at" : @1794030000500.0, @"hang_ms" : @2600}, wd_rid, @"108123", mac_here);
    CHECK(wd_mac != nil);
    CHECK([NSJSONSerialization isValidJSONObject:wd_mac]);
    SAME(wd_mac[@"event"], @"$exception");
    SAME(wd_mac[@"distinct_id"], @"108123");
    SAME(wd_mac[@"uuid"], sf_report_uuid(wd_rid));
    SAME(wd_mac[@"properties"][@"reason"], @"watchdog_hang");
    SAME(wd_mac[@"properties"][@"hang_ms"], @2600);
    SAME(wd_mac[@"properties"][@"$exception_level"], @"error");
    SAME(wd_mac[@"properties"][@"$exception_fingerprint"], @"macos:MainThreadHang:watchdog");
    NSDictionary *wdx = [wd_mac[@"properties"][@"$exception_list"] firstObject];
    SAME(wdx[@"type"], @"MainThreadHang");
    SAME(wdx[@"value"], @"the main thread did not respond for 2.6 s");
    SAME(wdx[@"mechanism"][@"type"], @"watchdog");
    SAME(wdx[@"mechanism"][@"handled"], @NO);

    NSDictionary *wd_ios = sf_report_event(@{@"kind" : @"watchdog_hang", @"at" : @1794030000500.0, @"hang_ms" : @2100}, wd_rid, @"108123", const_here());
    SAME(wd_ios[@"properties"][@"$exception_fingerprint"], @"ios:MainThreadHang:watchdog");
    CHECK(sf_report_event(@{@"kind" : @"watchdog_hang", @"at" : @0, @"hang_ms" : @0}, wd_rid, @"108123", mac_here) == nil);

    // watchdog state machine: normal ticks, background reset, >=2s & 2-miss trigger, dedup within stall, 5/10min cap
    sf_wd_state wd;
    memset(&wd, 0, sizeof wd);
    int send_ping = 0;
    uint64_t hang_ms = 0;
    // inactive: no ping, no report
    CHECK(sf_wd_tick(&wd, 0, 1000, 0, &send_ping, &hang_ms) == 0);
    CHECK(send_ping == 0);
    // first active tick dispatches ping 1
    CHECK(sf_wd_tick(&wd, 1, 2000, 0, &send_ping, &hang_ms) == 0);
    CHECK(send_ping == 1 && wd.ping_seq == 1);
    // 1st miss (1000ms elapsed): not yet reported
    CHECK(sf_wd_tick(&wd, 1, 3000, 0, &send_ping, &hang_ms) == 0);
    CHECK(send_ping == 0);
    // 2nd miss (2000ms elapsed): reports once
    CHECK(sf_wd_tick(&wd, 1, 4000, 0, &send_ping, &hang_ms) == 1);
    CHECK(hang_ms == 2000 && send_ping == 0);
    // 3rd miss in same stall: deduplicated
    CHECK(sf_wd_tick(&wd, 1, 5000, 0, &send_ping, &hang_ms) == 0);
    // main thread recovers (pong == 1): re-arms and dispatches ping 2
    CHECK(sf_wd_tick(&wd, 1, 6000, 1, &send_ping, &hang_ms) == 0);
    CHECK(send_ping == 1 && wd.ping_seq == 2);
    // backgrounding during stall resets counter so sleep/background never false-fires
    CHECK(sf_wd_tick(&wd, 1, 7000, 1, &send_ping, &hang_ms) == 0);
    CHECK(sf_wd_tick(&wd, 0, 8000, 1, &send_ping, &hang_ms) == 0);
    CHECK(sf_wd_tick(&wd, 1, 9000, 1, &send_ping, &hang_ms) == 0);
    CHECK(wd.consecutive_misses == 1);
    // rate limit: 4 more stalls within 10 min fire (total 5), 6th is suppressed, then after 10 min fires again
    uint64_t t = 20000;
    uint64_t seq = wd.ping_seq;
    for (int i = 0; i < 4; i++) {
      CHECK(sf_wd_tick(&wd, 1, t, seq, &send_ping, &hang_ms) == 0);
      seq = wd.ping_seq;
      CHECK(sf_wd_tick(&wd, 1, t + 1000, seq - 1, &send_ping, &hang_ms) == 0);
      CHECK(sf_wd_tick(&wd, 1, t + 2100, seq - 1, &send_ping, &hang_ms) == 1);
      CHECK(hang_ms == 2100);
      t += 5000;
    }
    // 6th stall within 10 min window: suppressed
    CHECK(sf_wd_tick(&wd, 1, t, seq, &send_ping, &hang_ms) == 0);
    seq = wd.ping_seq;
    CHECK(sf_wd_tick(&wd, 1, t + 1000, seq - 1, &send_ping, &hang_ms) == 0);
    CHECK(sf_wd_tick(&wd, 1, t + 2200, seq - 1, &send_ping, &hang_ms) == 0);
    // after 10-minute window expires, allowed again
    t = 4000 + SF_WD_WINDOW_MS + 1000;
    CHECK(sf_wd_tick(&wd, 1, t, seq, &send_ping, &hang_ms) == 0);
    seq = wd.ping_seq;
    CHECK(sf_wd_tick(&wd, 1, t + 1000, seq - 1, &send_ping, &hang_ms) == 0);
    CHECK(sf_wd_tick(&wd, 1, t + 2500, seq - 1, &send_ping, &hang_ms) == 1);
    CHECK(hang_ms == 2500);

    // ── sf_hottest_js: Hermes .cpuprofile parsing ──
    {
      CHECK(sf_hottest_js(nil) == nil);
      CHECK(sf_hottest_js([@"not json" dataUsingEncoding:NSUTF8StringEncoding]) == nil);
      CHECK(sf_hottest_js([@"{}" dataUsingEncoding:NSUTF8StringEncoding]) == nil);

      // Build a 14-frame deep chain to verify 12-frame stack cap, plus [root], '(' truncation, anonymous, recursion.
      NSMutableDictionary *framesMap = [@{
        @"1" : @{@"name" : @"[root]"},
        @"2" : @{@"name" : @"outer(arg1, arg2)", @"funcLine" : @10, @"funcColumn" : @2, @"parent" : @1},
        @"3" : @{@"name" : @"(a, b)", @"funcLine" : @99, @"funcColumn" : @1, @"parent" : @"2"},
        @"4" : @{@"name" : @"inner(x)", @"funcLine" : @42, @"funcColumn" : @8, @"parent" : @3},
        // Recursive call of inner(x) on top of itself: inclusive should count once per sample.
        @"5" : @{@"name" : @"inner(y)", @"funcLine" : @42, @"funcColumn" : @8, @"parent" : @4},
        // Frame without funcLine
        @"6" : @{@"name" : @"nativeHelper(z)", @"parent" : @1},
      } mutableCopy];
      // Deep stack: frames 100..113 (14 frames above root)
      for (int i = 0; i < 14; i++) {
        NSString *fid = [NSString stringWithFormat:@"%d", 100 + i];
        id parent = i == 0 ? @1 : [NSString stringWithFormat:@"%d", 100 + i - 1];
        framesMap[fid] = @{@"name" : [NSString stringWithFormat:@"deep%d()", i], @"parent" : parent};
      }
      // 10 samples: 2 idle ([root]), 5 in frame 5 (recursive inner), 2 in frame 6 (nativeHelper), 1 in frame 113 (deep)
      NSArray *samplesArr = @[
        @{@"sf" : @1},
        @{@"sf" : @"1"},
        @{@"sf" : @5},
        @{@"sf" : @5},
        @{@"sf" : @5},
        @{@"sf" : @5},
        @{@"sf" : @5},
        @{@"sf" : @6},
        @{@"sf" : @6},
        @{@"sf" : @113},
      ];
      NSData *traceData = [NSJSONSerialization dataWithJSONObject:@{@"stackFrames" : framesMap, @"samples" : samplesArr} options:0 error:nil];
      NSDictionary *hot = sf_hottest_js(traceData);
      CHECK(hot != nil);
      CHECK([NSJSONSerialization isValidJSONObject:hot]);
      SAME(hot[@"busy_percent"], @80);
      NSDictionary *fns = hot[@"functions"];
      // inner@42:8 appeared in 5 of 10 samples (deduplicated per sample -> 50%, not 100%)
      SAME(fns[@"inner@42:8"], @50);
      SAME(fns[@"(anonymous)@99:1"], @50);
      SAME(fns[@"outer@10:2"], @50);
      SAME(fns[@"nativeHelper"], @20);
      CHECK(fns[@"[root]"] == nil);
      NSArray *stacks = hot[@"stacks"];
      SAME(@(stacks.count), @3);
      SAME(stacks[0][@"percent"], @50);
      SAME(stacks[0][@"stack"], @"inner@42:8 < inner@42:8 < (anonymous)@99:1 < outer@10:2");
      SAME(stacks[1][@"percent"], @20);
      SAME(stacks[1][@"stack"], @"nativeHelper");
      SAME(stacks[2][@"percent"], @10);
      // 14 frames capped at 12 (deep13 down to deep2)
      NSArray *deepParts = [stacks[2][@"stack"] componentsSeparatedByString:@" < "];
      SAME(@(deepParts.count), @12);
      SAME(deepParts.firstObject, @"deep13");
      SAME(deepParts.lastObject, @"deep2");
    }

    // ── sf_memory_runaway_event: full stats, caps, sorting, negative growth, quiet fallback ──
    {
      NSMutableDictionary *callsBefore = [NSMutableDictionary dictionary];
      NSMutableDictionary *callsAfter = [NSMutableDictionary dictionary];
      // Create 25 ops: ops 0..19 have deltas 20..1 and unanswered 20..1; ops 20..24 have 0 delta and 0 unanswered.
      for (int i = 0; i < 25; i++) {
        NSString *op = [NSString stringWithFormat:@"op%02d", i];
        int base = 1000 - i * 10;
        int delta = i < 20 ? (20 - i) * 10 : 0;
        int unans = i < 18 ? (18 - i) : 0;
        callsBefore[op] = @[ @(base), @0 ];
        callsAfter[op] = @[ @(base + delta), @(unans) ];
      }
      NSDictionary *statsBefore = @{@"calls" : callsBefore};
      NSDictionary *statsAfter = @{
        @"calls" : callsAfter,
        @"handles" : @{@"tcp" : @12, @"iroh" : @3},
        @"sqls" : @{@"open" : @4},
      };
      NSDictionary *jsHot = @{@"busy_percent" : @75, @"functions" : @{@"parse@1:0" : @60}, @"stacks" : @[]};
      uint64_t fpBefore = 1600ULL * 1024 * 1024;
      uint64_t fpAfter = 1700ULL * 1024 * 1024;  // +100 MB over 15 s = +400 MB/min
      NSDictionary *macHere = @{@"app" : @"macos", @"$lib" : @"stillfail-macos", @"release" : @"0.2.0 (42)", @"$os" : @"macOS", @"$device_manufacturer" : @"Apple"};
      NSDictionary *ev = sf_memory_runaway_event(fpBefore, fpAfter, 15000, statsBefore, statsAfter, jsHot,
                                                 @"acc-1", macHere, 1794030000123.0, @"00000000-0000-4000-8000-000000000001");
      CHECK(ev != nil);
      CHECK([NSJSONSerialization isValidJSONObject:ev]);
      SAME(ev[@"event"], @"$exception");
      SAME(ev[@"distinct_id"], @"acc-1");
      SAME(ev[@"uuid"], @"00000000-0000-4000-8000-000000000001");
      SAME(ev[@"timestamp"], @"2026-11-07T05:40:00.123Z");
      NSDictionary *mp = ev[@"properties"];
      SAME(mp[@"reason"], @"memory_runaway");
      SAME(mp[@"$exception_level"], @"error");
      SAME(mp[@"footprint_mb"], @1700);
      SAME(mp[@"footprint_grew_mb_per_min"], @400);
      SAME(mp[@"window_s"], @15);
      SAME(@([mp[@"shell_calls"] count]), @15);
      SAME(mp[@"shell_calls"][@"op00"], @200);
      SAME(mp[@"shell_calls"][@"op14"], @60);
      CHECK(mp[@"shell_calls"][@"op15"] == nil);
      SAME(@([mp[@"shell_calls_total"] count]), @20);
      SAME(mp[@"shell_calls_total"][@"op00"], @1200);
      SAME(@([mp[@"shell_unanswered"] count]), @15);
      SAME(mp[@"shell_unanswered"][@"op00"], @18);
      CHECK(mp[@"shell_unanswered"][@"op15"] == nil);
      SAME(mp[@"shell_handles"], (@{@"tcp" : @12, @"iroh" : @3}));
      SAME(mp[@"shell_sqls"], (@{@"open" : @4}));
      SAME(mp[@"js"], jsHot);
      NSDictionary *mx = [mp[@"$exception_list"] firstObject];
      SAME(mx[@"type"], @"MemoryRunaway");
      SAME(mx[@"value"], @"footprint 1700 MB, +400 MB/min; shell: op00 ×200, op01 ×190, op02 ×180");
      SAME(mx[@"mechanism"], (@{@"handled" : @YES, @"synthetic" : @NO, @"type" : @"generic"}));

      // Negative growth and nil/empty stats fallback to "quiet"
      uint64_t fpDropBefore = 1600ULL * 1024 * 1024;
      uint64_t fpDropAfter = 1599ULL * 1024 * 1024;  // -1 MB over 15 s = -4 MB/min
      NSDictionary *quiet = sf_memory_runaway_event(fpDropBefore, fpDropAfter, 15000, nil, nil, nil,
                                                    @"acc-1", macHere, 0, @"00000000-0000-4000-8000-000000000002");
      CHECK(quiet != nil);
      CHECK([NSJSONSerialization isValidJSONObject:quiet]);
      NSDictionary *qp = quiet[@"properties"];
      SAME(qp[@"footprint_mb"], @1599);
      SAME(qp[@"footprint_grew_mb_per_min"], @(-4));
      SAME(@([qp[@"shell_calls"] count]), @0);
      SAME(@([qp[@"shell_calls_total"] count]), @0);
      SAME(@([qp[@"shell_unanswered"] count]), @0);
      CHECK(qp[@"shell_handles"] == nil);
      CHECK(qp[@"shell_sqls"] == nil);
      CHECK(qp[@"js"] == nil);
      SAME([qp[@"$exception_list"] firstObject][@"value"], @"footprint 1599 MB, -4 MB/min; shell: quiet");
    }
    {
      // the theme the person chose, kept under the key mbui's iOS host reads as the app starts (ios_app.m initial_dark)
      NSString *suite = [NSString stringWithFormat:@"ios_reports_test.%d", getpid()];
      NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suite];
      CHECK(sf_theme_pref(d) == 0);
      CHECK(sf_set_theme_pref(d, @"dark") == 1);
      SAME([d stringForKey:@"mbui.theme_pref"], @"dark");
      CHECK(sf_theme_pref(d) == 2);
      CHECK(sf_set_theme_pref(d, @"light") == 1);
      CHECK(sf_theme_pref(d) == 1);
      // anything else not kept, what was kept left as it was
      CHECK(sf_set_theme_pref(d, @"sepia") == 0);
      CHECK(sf_set_theme_pref(d, @"") == 0);
      CHECK(sf_theme_pref(d) == 1);
      CHECK(sf_set_theme_pref(d, @"system") == 1);
      SAME([d stringForKey:@"mbui.theme_pref"], @"system");
      CHECK(sf_theme_pref(d) == 0);
      // last active workspace kept for frame-0 cold-start pre-subscription and cleared on sign-out
      CHECK(sf_set_last_workspace(d, @"ws_1") == 1);
      SAME([d stringForKey:@"mbui.last_workspace"], @"ws_1");
      CHECK(sf_set_last_workspace(d, @"") == 1);
      CHECK([d stringForKey:@"mbui.last_workspace"] == nil);
      [d removePersistentDomainForName:suite];
    }
  }
  if (!failed) printf("ios reports: ok\n");
  return failed;
}
