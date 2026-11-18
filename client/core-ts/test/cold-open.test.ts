// A page of the workspace's settings opened for the first time since the app started (the owner, 2026-11-16: 「设置页面
// 第一次点进去会卡挺久」): what its first screen costs is bound by what it shows, not by how much the device holds.
// On a core started anew on the real-size workspace (real-size.ts), Home shown (`chats`) and at rest, each page's topics
// subscribed as its first screen asks them (the settings' own with `cache.usage` ahead of them, as
// apps/mbui/e2e/traces/settings-appearance.trace sends them), on a device holding its chats' logs once and five times:
// - A: no station's whole overview is decorated (`work.overviews`) nor read (`work.overviewsRead`) to answer it: what
//   each page reads of an overview is kept beside it (schema.ts PART_COLUMNS), and whether this core can read it is
//   its verdict kept as it was written (db/kept.ts overviewFit).
// - B: it runs as many statements with five times the chats, messages and transcripts as with them once (`cache.usage`
//   too, first and again): no statement a chat, no log's rows summed.
//   The files kept of drives and chats (drive-kept.ts) the same, their parts five times as many: read of what each
//   file's parts take (`part_bytes`), never of `part`.
// - C: the settings' first screen's five topics have their first values out before `cache.usage` answers, though it was
//   asked first in the same turn: a call that changes nothing waits for what pages wait on (station/calls.ts).
// Counts, never a clock's milliseconds: deterministic on any machine. COLD_OPEN_PRINT=1 prints each page's counts at
// both sizes; COLD_OPEN_ONLY=<page> opens that page alone.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { holds } from "../src/data.ts";
import { handlers } from "../src/core/execute.ts";
import { DriveKept, chatKeptId, keptId } from "../src/drive-kept.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { parseTopic, type Topic } from "../src/protocol.ts";
import { install } from "../src/station/calls.ts";
import { FakeHost } from "../src/testing.ts";
import { work } from "../src/work.ts";
import { held } from "./real-size-asked.ts";
import { DOWN, PLAIN_WORKSPACE, UP, fixture, more } from "./real-size.ts";
import { call, subscribe } from "./helpers.ts";
import { started } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

install();

// ── the instrument: statements run (NodeSql's, as the test's host makes them) ──
let statements = 0;
/// The statements' text, while a page opens.
let said: string[] | null = null;
{
  const proto = NodeSql.prototype as J;
  const all = proto.all, run = proto.run, exec = proto.exec;
  proto.all = function (...a: J[]) {
    statements++;
    said?.push(String(a[0]));
    return all.apply(this, a);
  };
  proto.run = function (...a: J[]) {
    statements++;
    said?.push(String(a[0]));
    return run.apply(this, a);
  };
  proto.exec = function (...a: J[]) {
    statements++;
    said?.push(String(a[0]));
    return exec.apply(this, a);
  };
}

/// Each page as its first screen asks: its topics, and whether `cache.usage` is asked ahead of them.
const ws = "ws";
const station = UP[0]!;
const PAGES: Record<string, { topics: Record<string, unknown>[]; usage?: true }> = {
  "设置": { usage: true, topics: [{ topic: "workspace", workspace: ws }, { topic: "stations", scope: ws }, { topic: "connects", scope: ws, mine: false }, { topic: "vaults", workspace: ws }, { topic: "profiles", scope: ws }] },
  "连接": { topics: [{ topic: "stations", scope: ws }, { topic: "connects", scope: ws, mine: false }] },
  "连接 我的": { topics: [{ topic: "connects", scope: ws, mine: true }] },
  "一个连接": { topics: [{ topic: "connect", scope: ws, station, id: "c-slack-1" }] },
  "Station": { topics: [{ topic: "stations", scope: ws }] },
  "账号": { topics: [{ topic: "profiles", scope: ws }] },
  "密钥": { topics: [{ topic: "vaults", workspace: PLAIN_WORKSPACE }] },
  "自动决策": { topics: [{ topic: "settings", scope: ws }, { topic: "stationPart", scope: ws, station, part: "automaticDecisions" }] },
  "自动归档": { topics: [{ topic: "settings", scope: ws }, { topic: "stationPart", scope: ws, station, part: "archiving" }] },
  "已归档": { topics: [{ topic: "archive", scope: ws, limit: 60 }] },
  "Station 更新": { topics: [{ topic: "stationUpdates", scope: ws }] },
  "用量": { topics: [{ topic: "usage", scope: ws, days: 7 }] },
  "rail 对话": { topics: [{ topic: "railCard", scope: ws, place: "chats" }] },
  "rail 用量": { topics: [{ topic: "railCard", scope: ws, place: "usage" }] },
};

/// The chats' logs a device holds besides the workspace's, `k` times: each chat its messages and an agent's transcript.
const LOGS = { threads: 120, entries: 12, transcript: 6 };
/// The files kept on the device (drive-kept.ts), the same files `k` times as many parts each: a drive's, a video
/// played, and the chats' (of the sessions above).
const FILES = { file: 2, played: 2, chat: 8, parts: 20, part: 100 };
type Device = { host: FakeHost; drive: number };

async function device(k: number): Promise<Device> {
  const h = await held(false);
  const data = h.t.data;
  const stations = [...UP, DOWN];
  for (let i = 0; i < LOGS.threads * k; i++) {
    const st = stations[i % stations.length]!;
    const id = 50_000 + i;
    const session = `logs-${i}`;
    data.putThread(st, { id, title: i % 4 === 0 ? undefined : `对话 ${i}`, surface: i % 3 === 0 ? "slack" : "chat", channel: i % 3 === 0 ? "C0OPS" : "CHAT", firstText: `第一句 ${i}`, sessions: [{ session }] });
    data.putItems("entry", st, String(id), Array.from({ length: LOGS.entries }, (_, n) => [n + 1, { text: `消息 ${n} `.repeat(10) }]));
    data.putItems("transcript", st, session, Array.from({ length: LOGS.transcript }, (_, n) => [n, { type: "tool_result", content: "输出 ".repeat(200) + n }]));
    if (i % 100 === 99) await h.t.host.time.pass(50);
  }
  // (a tree of Markdown kept, as Home's rows' read: the real-size workspace's own are read once a process, markdown.ts)
  data.mdStore(UP[0]!, "t:50000")!.put("cold-open", "[]");
  const kept = new DriveKept(h.t.host);
  const parts = FILES.parts * k;
  const size = parts * FILES.part;
  const files: [string, "file" | "played" | "chat"][] = [
    ...Array.from({ length: FILES.file }, (_, i) => [keptId(station, "/Users/a", `book-${i}.pdf`), "file"] as [string, "file"]),
    ...Array.from({ length: FILES.played }, (_, i) => [keptId(station, "/Users/a", `film-${i}.mp4`), "played"] as [string, "played"]),
    ...Array.from({ length: FILES.chat }, (_, i) => [chatKeptId(UP[i % UP.length]!, `logs-${i}`, `shot-${i}.png`), "chat"] as [string, "chat"]),
  ];
  for (const [id, kind] of files) {
    for (let p = 0; p < parts; p++) await Effect.runPromise(kept.keep(id, kind, 1, size, "application/octet-stream", p * FILES.part, new Uint8Array(FILES.part)));
  }
  await h.t.host.time.pass(200);
  await rest(h);
  h.t.store.runner.shutdown();
  return { host: h.t.host, drive: (FILES.file + FILES.played) * size };
}

async function rest(h: J): Promise<void> {
  for (let i = 0; i < 100; i++) {
    const before = statements;
    await h.t.host.settle();
    if (h.t.host.takeEmitted().length === 0 && statements === before) return;
  }
  throw new Error("the core did not come to rest");
}

type Opened = { overviews: number; overviewsRead: number; statements: number; usage?: { first: number; again: number }; unanswered: string[]; parts: string[] };

/// Page `name` opened first on a core started anew on `d`, Home shown and at rest.
async function open(d: Device, name: string): Promise<Opened> {
  const h = await held(false, { host: d.host, cold: true });
  const live = [...fixture(h.base, h.chat), ...more(h.base)].filter(([topic]) => !holds(topic));
  live.forEach(([topic], i) => h.t.store.subscribe(9, i + 1, topic, false));
  for (let round = 0; round < 2; round++) {
    h.setLive();
    await h.t.host.time.pass(100);
  }
  const chats = parseTopic({ topic: "chats", scope: ws, mine: false }) as Topic;
  h.t.window(chats, 30);
  h.t.store.subscribe(1, 100, chats, true);
  await h.t.host.time.pass(100);
  await rest(h);
  const page = PAGES[name]!;
  const answered = new Set<number>();
  const from = { overviews: work.overviews, overviewsRead: work.overviewsRead, statements };
  const inner = { data: h.t.data, store: h.t.store, driveKept: new DriveKept(d.host) } as J;
  said = [];
  let usage: { first: number; again: number } | undefined;
  let usageDone = page.usage !== true;
  if (page.usage) {
    const start = statements;
    h.t.store.runner.fork(Effect.tap(handlers.cacheUsage!(inner, { kind: "cacheUsage" } as J, () => {}, [1, 20], {} as J), (r: J) => Effect.sync(() => {
      assert.equal(r.drive, d.drive, "the drives' files kept, counted");
      assert.equal(r.chats.reduce((n: number, c: J) => n + c.files.length, 0) + r.loose.length, FILES.chat, "the chats' files kept, listed");
      usage = { first: statements - start, again: 0 };
      usageDone = true;
    })));
  }
  page.topics.forEach((t, i) => h.t.store.subscribe(1, 21 + i, parseTopic(t) as Topic, true));
  for (let t = 0; t < 3000 && (!usageDone || page.topics.some((_, i) => !answered.has(21 + i))); t += 10) {
    await h.t.host.time.pass(10, 10);
    for (const [, m] of h.t.host.takeEmitted()) if (typeof (m as J).id === "number" && ("value" in (m as J) || "error" in (m as J))) answered.add((m as J).id);
  }
  const out: Opened = {
    overviews: work.overviews - from.overviews,
    overviewsRead: work.overviewsRead - from.overviewsRead,
    statements: statements - from.statements,
    unanswered: [...page.topics.filter((_, i) => !answered.has(21 + i)).map((t) => String(t.topic)), ...(usageDone ? [] : ["cache.usage"])],
    parts: [],
  };
  if (usage !== undefined) {
    const start = statements;
    await h.t.store.runner.run(handlers.cacheUsage!(inner, { kind: "cacheUsage" } as J, () => {}, [1, 21], {} as J));
    usage.again = statements - start;
    out.usage = usage;
  }
  out.parts = said.filter((q) => /\b(FROM|JOIN) part\b/.test(q));
  said = null;
  h.t.store.runner.shutdown();
  return out;
}

test("each_settings_page_opened_first_decorates_no_overview_and_reads_no_more_with_five_times_the_logs", { timeout: 600_000 }, async () => {
  const once = await device(1);
  const five = await device(5);
  const found: string[] = [];
  for (const name of Object.keys(PAGES).filter((n) => process.env.COLD_OPEN_ONLY === undefined || n === process.env.COLD_OPEN_ONLY)) {
    const [a, b] = [await open(once, name), await open(five, name)];
    if (process.env.COLD_OPEN_PRINT === "1") console.log(name, JSON.stringify(a), JSON.stringify(b));
    assert.deepEqual([a.unanswered, b.unanswered], [[], []], `${name}: answered`);
    if (a.overviews + b.overviews > 0) found.push(`${name}: ${a.overviews} overviews decorated`);
    if (a.overviewsRead + b.overviewsRead > 0) found.push(`${name}: ${a.overviewsRead} overviews read`);
    if (a.statements !== b.statements) found.push(`${name}: ${a.statements} statements, ${b.statements} with five times the logs`);
    if (a.parts.length + b.parts.length > 0) found.push(`${name}: the files' parts read: ${[...new Set([...a.parts, ...b.parts])].join(" | ")}`);
    if (a.usage !== undefined && JSON.stringify(a.usage) !== JSON.stringify(b.usage)) found.push(`${name}: cache.usage ran ${JSON.stringify(a.usage)} statements, ${JSON.stringify(b.usage)} with five times the logs`);
  }
  assert.deepEqual(found, []);
});

test("the_settings_first_screen_has_its_values_out_before_cache_usage_answers_though_it_was_asked_first", async () => {
  const t = await started();
  const data = t.core.inner.data;
  for (let i = 0; i < 40; i++) {
    data.putThread("ws/st", { id: 100 + i, title: `对话 ${i}`, sessions: [{ session: `s${i}` }] });
    data.putItems("entry", "ws/st", String(100 + i), Array.from({ length: 10 }, (_, n) => [n + 1, { text: "x".repeat(200) }]));
  }
  await t.host.time.pass(100);
  t.host.takeEmitted();
  const ui = t.core.connect();
  // As the app sends them in one go: the call first.
  call(t.core, ui, 20, "cache.usage", {});
  const five: Topic[] = [{ topic: "workspace", workspace: "ws" }, { topic: "stations", scope: "ws" }, { topic: "connects", scope: "ws", mine: false }, { topic: "vaults", workspace: "ws" }, { topic: "profiles", scope: "ws" }];
  five.forEach((topic, i) => subscribe(t.core, ui, 21 + i, topic));
  const order: number[] = [];
  for (let i = 0; i < 100 && order.length < 6; i++) {
    await t.host.time.pass(10, 10);
    for (const [client, m] of t.host.takeEmitted()) {
      const id = (m as J).id;
      if (client === ui && typeof id === "number" && !order.includes(id) && ("value" in (m as J) || "ok" in (m as J) || "error" in (m as J))) order.push(id);
    }
  }
  assert.deepEqual([...order].sort(), [20, 21, 22, 23, 24, 25], "every one answered");
  assert.equal(order.at(-1), 20, `cache.usage answered last: ${order.join(", ")}`);
  t.core.close();
});
