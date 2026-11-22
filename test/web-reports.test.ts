import assert from "node:assert/strict";
import test from "node:test";
import { BAR_BATCH_MS, BAR_BATCH_SIZE, detectOs, WebReports, type ReportsStorage } from "../web/src/mbui/reports.ts";

function memoryStorage(initial: Record<string, string> = {}): ReportsStorage {
  const map = new Map<string, string>(Object.entries(initial));
  return {
    getItem: (k) => map.get(k) ?? null,
    setItem: (k, v) => {
      map.set(k, v);
    },
  };
}

test("non-own origin or missing PostHog sink disables reporting completely", () => {
  const sent: { url: string; body: string; keepalive: boolean }[] = [];
  const noKey = new WebReports({
    sink: null,
    origin: "https://app.still.fail",
    release: "1700000000000",
    os: "macOS",
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });
  assert.equal(noKey.tell("hello", "", "", 0, 0), 0);
  assert.equal(noKey.tell("bar_switch_ready", "", "", 0, 0), 0);
  assert.equal(noKey.tell("reporting", "", "", 0, 0), -1);
  noKey.tell("hang", '{"stall_ms":120}', "", 0, 0);
  noKey.tell("bar_switch", '{"to":"chats"}', "", 0, 0);
  noKey.flush(true);
  assert.equal(sent.length, 0);

  const localOrigin = new WebReports({
    sink: { host: "https://us.i.posthog.com", key: "phc_test" },
    origin: "http://localhost:5173",
    release: "1700000000000",
    os: "macOS",
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });
  assert.equal(localOrigin.tell("hello", "", "", 0, 0), 0);
  assert.equal(localOrigin.tell("bar_switch_ready", "", "", 0, 0), 0);
  assert.equal(localOrigin.tell("reporting", "", "", 0, 0), -1);
  localOrigin.tell("core_failed", "boom", "", 0, 0);
  assert.equal(sent.length, 0);
});

test("turning reporting off drops queued and future events and persists in storage", () => {
  const storage = memoryStorage();
  const sent: { url: string; body: string; keepalive: boolean }[] = [];
  let cancelled = 0;
  const r = new WebReports({
    sink: { host: "https://us.i.posthog.com", key: "phc_test" },
    origin: "https://app.youdid.wtf",
    release: "1700000000000",
    os: "Linux",
    storage,
    schedule: () => 42,
    cancel: () => {
      cancelled++;
    },
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });
  assert.equal(r.tell("hello", "", "", 0, 0), 1);
  assert.equal(r.tell("bar_switch_ready", "", "", 0, 0), 1);
  assert.equal(r.tell("reporting", "", "", 0, 0), 1);
  r.tell("bar_switch", '{"to":"stations"}', "", 0, 0);
  assert.equal(r.queuedCount, 1);

  r.tell("set_reporting", "", "", 0, 0);
  assert.equal(r.tell("reporting", "", "", 0, 0), 0);
  assert.equal(r.queuedCount, 0);
  assert.equal(cancelled, 1);

  r.tell("hang", '{"stall_ms":200}', "", 0, 0);
  r.tell("hang_summary", '{"hangs":1}', "", 0, 0);
  r.tell("bar_switch", '{"to":"files"}', "", 0, 0);
  r.tell("core_failed", "oom", "", 0, 0);
  r.tell("ui_fault", "UI fault", "", 0, 0);
  r.flush(true);
  assert.equal(sent.length, 0);

  // Persisted across reloads
  const r2 = new WebReports({
    sink: { host: "https://us.i.posthog.com", key: "phc_test" },
    origin: "https://app.youdid.wtf",
    release: "1700000000000",
    os: "Linux",
    storage,
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });
  assert.equal(r2.tell("reporting", "", "", 0, 0), 0);
});

test("ui_hang, ui_hang_summary, and exception payloads match PostHog schema", () => {
  const storage = memoryStorage();
  const sent: { url: string; body: string; keepalive: boolean }[] = [];
  let seq = 0;
  const r = new WebReports({
    sink: { host: "https://us.i.posthog.com", key: "phc_live" },
    origin: "https://app.still.fail",
    release: "1795344457000",
    os: "macOS",
    storage,
    now: () => 1_700_000_000_000,
    uuid: () => `uuid-${++seq}`,
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });

  // Before signed_in, uses anonymous fallback
  r.tell("hang", '{"page":"Chat","stall_ms":85}', "", 0, 0);
  assert.equal(sent.length, 1);
  assert.equal(sent[0]!.url, "https://us.i.posthog.com/batch/");
  assert.equal(sent[0]!.keepalive, false);
  const hangReq = JSON.parse(sent[0]!.body) as { api_key: string; batch: { event: string; distinct_id: string; uuid: string; timestamp: string; properties: Record<string, unknown> }[] };
  assert.equal(hangReq.api_key, "phc_live");
  assert.equal(hangReq.batch[0]!.event, "ui_hang");
  assert.equal(hangReq.batch[0]!.distinct_id, "web-anonymous");
  assert.equal(hangReq.batch[0]!.properties.app, "web");
  assert.equal(hangReq.batch[0]!.properties.release, "1795344457000");
  assert.equal(hangReq.batch[0]!.properties.$lib, "stillfail-web");
  assert.equal(hangReq.batch[0]!.properties.$os, "macOS");
  assert.equal(hangReq.batch[0]!.properties.page, "Chat");
  assert.equal(hangReq.batch[0]!.properties.stall_ms, 85);

  // After signed_in, uses account sub and persists it
  r.tell("signed_in", "user-sub-123", "", 0, 0);
  r.tell("core_failed", "worker crashed", "", 0, 0);
  const excReq = JSON.parse(sent[1]!.body) as { batch: { event: string; distinct_id: string; properties: Record<string, unknown> }[] };
  assert.equal(excReq.batch[0]!.event, "$exception");
  assert.equal(excReq.batch[0]!.distinct_id, "user-sub-123");
  assert.equal(excReq.batch[0]!.properties.reason, "core_failed");
  assert.equal(excReq.batch[0]!.properties.$exception_level, "error");
  assert.deepEqual(excReq.batch[0]!.properties.$exception_list, [
    { type: "CoreFailed", value: "worker crashed", mechanism: { handled: true, synthetic: false, type: "generic" } },
  ]);

  // hang_summary uses keepalive=true and also flushes queued bar_switch
  r.tell("bar_switch", '{"to":"stations","composed_ms":14.5,"cut":false,"topics_count":0,"topics":[]}', "", 0, 0);
  r.tell("hang_summary", '{"hangs":2,"shown_ms":60000}', "", 0, 0);
  assert.equal(sent.length, 4);
  assert.equal(sent[2]!.keepalive, true);
  assert.equal(JSON.parse(sent[2]!.body).batch[0].event, "ui_hang_summary");
  assert.equal(sent[3]!.keepalive, true);
  assert.equal(JSON.parse(sent[3]!.body).batch[0].event, "bar_switch");
});

test("bar_switch batches up to BAR_BATCH_SIZE, flushes on timer, and flushes on pagehide", () => {
  const sent: { url: string; body: string; keepalive: boolean }[] = [];
  let scheduledFn: (() => void) | null = null;
  let scheduledMs = 0;
  const r = new WebReports({
    sink: { host: "https://us.i.posthog.com", key: "phc_live" },
    origin: "https://app.still.fail",
    release: "1",
    os: "Windows",
    schedule: (fn, ms) => {
      scheduledFn = fn;
      scheduledMs = ms;
      return 1;
    },
    cancel: () => {
      scheduledFn = null;
    },
    send: (url, body, keepalive) => sent.push({ url, body, keepalive }),
  });

  // Queue BAR_BATCH_SIZE - 1 events: stays queued with timer
  for (let i = 0; i < BAR_BATCH_SIZE - 1; i++) {
    r.tell("bar_switch", `{"to":"p${i}","cut":false}`, "", 0, 0);
  }
  assert.equal(sent.length, 0);
  assert.equal(r.queuedCount, BAR_BATCH_SIZE - 1);
  assert.equal(scheduledMs, BAR_BATCH_MS);

  // One more reaches BAR_BATCH_SIZE -> flushes immediately
  r.tell("bar_switch", '{"to":"last","cut":false}', "", 0, 0);
  assert.equal(sent.length, 1);
  assert.equal(sent[0]!.keepalive, false);
  assert.equal(JSON.parse(sent[0]!.body).batch.length, BAR_BATCH_SIZE);
  assert.equal(r.queuedCount, 0);

  // Queue 1 and fire timer
  r.tell("bar_switch", '{"to":"timer","cut":false}', "", 0, 0);
  assert.ok(scheduledFn !== null);
  (scheduledFn as () => void)();
  assert.equal(sent.length, 2);
  assert.equal(JSON.parse(sent[1]!.body).batch[0].properties.to, "timer");

  // Queue 1 and flush(true) (pagehide)
  r.tell("bar_switch", '{"to":"hide","cut":false}', "", 0, 0);
  r.flush(true);
  assert.equal(sent.length, 3);
  assert.equal(sent[2]!.keepalive, true);
  assert.equal(JSON.parse(sent[2]!.body).batch[0].properties.to, "hide");
});

test("detectOs normalizes common browser user agents", () => {
  assert.equal(detectOs("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"), "macOS");
  assert.equal(detectOs("Mozilla/5.0 (Windows NT 10.0; Win64; x64)"), "Windows");
  assert.equal(detectOs("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)"), "iOS");
  assert.equal(detectOs("Mozilla/5.0 (Linux; Android 15; Pixel 9)"), "Android");
  assert.equal(detectOs("Mozilla/5.0 (X11; Linux x86_64)"), "Linux");
  assert.equal(detectOs("CustomAgent/1.0"), "Unknown");
});
