// The usage counter's reads by the MoonBit program (station/mb src/usagecount, reader `--builder usage-counter`;
// src/usage/counter-mb.ts) against the TypeScript reads it replaced (test/usage-counter-reference.ts): the same scenarios
// on two stores of the same transcripts, one read by the reference, one by the program, and every usage table of both compared row by row, each value as SQLite keeps
// it (quote(): 1 is not 1.0 is not '1'). Then the program's own life: started at its first read, let go when trimmed,
// started again by the next.
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { iso, rememberCodexRollout } from "./reference/transcript-paths.ts";
import { packFile } from "../src/sessions/archive.ts";
import { Store } from "../src/store/store.ts";
import { installCompactUsage } from "../src/store/usage-compact.ts";
import { retireUsageIndexes } from "./reference/backfill/usage-retire.ts";
import { TIMED_BACK_MS, UsageCounter } from "../src/usage/counter.ts";
import { ReferenceUsageCounter, UNTIMED_SESSIONS, claudeProject } from "./usage-counter-reference.ts";
import { keepUsage } from "../src/usage/module.ts";
import { testClock } from "./hub-fakes.ts";

const binary = mbReaderBinary();
const skip = binary === null && "no MoonBit reader built (station/mb/build.sh)";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const f of cleanup) await f();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const claudeLine = (id: string, at: number, model: string, usage: unknown, extra: Record<string, unknown> = {}) =>
  JSON.stringify({ type: "assistant", timestamp: iso(at), isSidechain: false, ...extra, message: { id, model, usage } });
const usage = (input: number, read: number, short: number, long: number, output: number) => ({
  input_tokens: input, cache_read_input_tokens: read, cache_creation_input_tokens: short + long,
  cache_creation: { ephemeral_5m_input_tokens: short, ephemeral_1h_input_tokens: long }, output_tokens: output,
});

function append(path: string, lines: string[]) {
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, lines.map((l) => `${l}\n`).join(""));
}
const pack = (path: string) => {
  writeFileSync(`${path}.zst`, zstdCompressSync(readFileSync(path)));
  unlinkSync(path);
};

/// Every usage table of a store (and the counter's own), each row's values as SQLite keeps them, in order.
function dump(store: Store): Record<string, string[]> {
  const tables = (store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'usage%' OR name = 'session_usage') ORDER BY name").all() as { name: string }[]).map((r) => r.name);
  const out: Record<string, string[]> = {};
  for (const t of tables) {
    const cols = (store.db.prepare(`PRAGMA table_info("${t}")`).all() as { name: string }[]).map((c) => c.name);
    const rows = store.db.prepare(`SELECT ${cols.map((c) => `quote("${c}")`).join(" || '|' || ")} AS r FROM "${t}"`).all() as { r: string }[];
    out[t] = rows.map((r) => r.r).sort();
  }
  return out;
}

/// The recent contexts kept (usage_totals.compact_context).
const contexts = (store: Store) => (store.db.prepare("SELECT compact_context AS c FROM usage_totals WHERE compact_context IS NOT NULL").all() as { c: string }[]).map((r) => r.c).join("\n");

type World = {
  data: string; now: () => number; time: Awaited<ReturnType<typeof today>>;
  /// What happens to the station, done to both stores alike.
  each(f: (store: Store) => void): void;
  /// A read by both (`only`: of those sessions alone): both counted the same and wrote the same.
  read(only?: string[], why?: string): Promise<number>;
  ts: Store; mb: Store; tsCounter: ReferenceUsageCounter; mbCounter: UsageCounter;
};

async function today() {
  const time = testClock();
  await time.adjust(Date.parse("2026-10-06T08:00:00Z"));
  return time;
}

async function world(options: { compact?: boolean } = {}): Promise<World> {
  const time = await today();
  const data = mkdtempSync(join(tmpdir(), "mb-usage-counter-"));
  dirs.push(data);
  const profiles = [{ home: join(data, "homes/cc") }, { home: join(data, "homes/cx") }];
  const open = (name: string) => {
    const store = Store.open(join(data, `${name}.db`), null, time.clock);
    cleanup.push(() => { try { store.close(); } catch {} });
    return store;
  };
  const ts = open("ts");
  const mb = open("mb");
  if (options.compact) for (const s of [ts, mb]) {
    installCompactUsage(s.db);
    retireUsageIndexes(s.db);
  }
  const tsCounter = new ReferenceUsageCounter({ store: ts, config: () => ({ dataDir: data, profiles }), clock: time.clock });
  const mbCounter = new UsageCounter({ store: mb, config: () => ({ dataDir: data, profiles }), clock: time.clock, mb: binary });
  cleanup.unshift(() => tsCounter.stop(), () => mbCounter.stop());
  return {
    data, time, now: () => ts.now(), ts, mb, tsCounter, mbCounter,
    each: (f) => { f(ts); f(mb); },
    async read(only, why) {
      const set = only === undefined ? undefined : new Set(only);
      const told: string[][] = [[], []];
      const offs = [ts, mb].map((s, i) => s.subscribe((change) => { if (change.type === "usage") told[i]!.push(JSON.stringify(change)); }));
      const a = await tsCounter.read(set);
      const b = await mbCounter.read(set);
      for (const off of offs) off();
      assert.equal(b, a, `${why ?? "a read"}: as many new calls`);
      assert.deepEqual(told[1], told[0], `${why ?? "a read"}: the same told`);
      assert.deepEqual(dump(mb), dump(ts), `${why ?? "a read"}: the same written`);
      return a;
    },
  };
}

function session(w: World, key: string, workspace: string, createdAt: number, runtime = "claude", profile = "cc") {
  w.each((s) => {
    s.insertSession({ key, connect: "ember", createdBy: "creator@x", runtime: "claude", profile: "cc", workspace, token: `t-${key}`, createdAt, lastActiveAt: createdAt });
    if (runtime !== "claude") s.setSessionRuntime(key, runtime, profile, false, null, null, null, null);
  });
}

function runtimeSession(w: World, key: string, id: string, profile = "cc") {
  w.each((s) => {
    s.setRuntimeSessionId(key, id);
    s.ranIn(key, id, profile);
  });
}

test("Claude Code: its own transcript and its sub-agents', read as they grow, a response growing, put to its turns", { skip }, async () => {
  const w = await world();
  const t = w.time;
  const workspace = join(w.data, "sessions/ember/c-1/workspace");
  const created = w.now();
  session(w, "chat:c-1", workspace, created);
  w.each((s) => s.startTurnFor("t1", "chat:c-1", "input", { profile: "cc", person: "a@x", thread: null }));
  const project = join(w.data, "transcripts/claude", claudeProject(workspace));
  const main = join(project, "r1.jsonl");
  append(main, [
    claudeLine("m0", created - 60_000, "claude-opus-5-5", usage(1, 0, 0, 0, 1)),
    claudeLine("m1", created + 1, "claude-opus-5-5", usage(10, 100, 7, 3, 1)),
    claudeLine("m1", created + 2, "claude-opus-5-5", usage(10, 100, 7, 3, 9)),
    claudeLine("syn", created + 2, "<synthetic>", usage(0, 0, 0, 0, 0)),
    JSON.stringify({ type: "user", message: { content: "has \"usage\" in it" } }),
    "not json \"usage\"",
    claudeLine("fast", created + 3, "claude-sonnet-5-5", { input_tokens: 5, cache_creation_input_tokens: 7, output_tokens: 1, speed: "fast" }),
  ]);
  append(join(project, "r1/subagents/agent-a.jsonl"), [claudeLine("s1", created + 4, "claude-haiku-4-5", usage(5, 0, 0, 0, 5))]);
  assert.equal(await w.read(undefined, "the first sweep"), 3);
  await t.adjust(15);
  w.each((s) => s.endTurn("t1", "completed", null, null, null));
  await t.adjust(15);
  w.each((s) => s.startTurnFor("t2", "chat:c-1", "input", { profile: "cc2", person: "b@x", thread: null }));
  const later = w.now();
  append(main, [claudeLine("m1", created + 2, "claude-opus-5-5", usage(10, 100, 7, 3, 12)), claudeLine("m2", later + 1, "claude-opus-5-5", usage(20, 0, 0, 0, 2))]);
  append(join(project, "r1/subagents/agent-a.jsonl"), [claudeLine("s2", later + 2, "claude-haiku-4-5", usage(6, 0, 0, 0, 1), { isSidechain: true })]);
  // A line still being written is left for the next read.
  appendFileSync(main, claudeLine("m3", later + 3, "claude-opus-5-5", usage(30, 0, 0, 0, 3)).slice(0, 40));
  assert.equal(await w.read(["chat:c-1"], "a working session asked alone"), 2);
  appendFileSync(main, `${claudeLine("m3", later + 3, "claude-opus-5-5", usage(30, 0, 0, 0, 3)).slice(40)}\n`);
  assert.equal(await w.read(undefined, "the line finished"), 1);
  assert.equal(await w.read(undefined, "nothing new"), 0);
});

test("Codex, its rollout found by its id and the one a running thread said; dsh; Grok; Cursor, Devin, Hermes, Antigravity", { skip }, async () => {
  const w = await world();
  const at = iso(w.now() + 1);
  const now = w.now();
  // Codex: its rollout by date, the model its turn named, a count told again with rate limits once.
  session(w, "codex-a", join(w.data, "wa"), now - 1_000, "codex", "cx");
  runtimeSession(w, "codex-a", "rid-a", "cx");
  const rolloutA = join(w.data, "transcripts/codex/2026/10/06", "rollout-2026-10-06T08-00-00-rid-a.jsonl");
  const count = (total: number, input: number, cached: number, output: number) => JSON.stringify({ timestamp: at, type: "event_msg", payload: {
    type: "token_count", info: { total_token_usage: { total_tokens: total }, last_token_usage: { input_tokens: input, cached_input_tokens: cached, output_tokens: output }, model_context_window: 272000 } } });
  append(rolloutA, [
    JSON.stringify({ timestamp: at, type: "session_meta", payload: { id: "rid-a", cwd: join(w.data, "wa") } }),
    JSON.stringify({ timestamp: at, type: "turn_context", payload: { model: "gpt-6" } }),
    count(100, 80, 30, 20), count(100, 80, 30, 20), count(250, 120, 100, 30),
  ]);
  // A running thread's rollout as it said it, in a home of its own.
  session(w, "codex-b", join(w.data, "wb"), now - 1_000, "codex", "cx");
  runtimeSession(w, "codex-b", "rid-b", "cx");
  w.each((s) => s.setRunning("codex-b", true));
  const said = join(w.data, "homes/cx/sessions/2026/10/06", "rollout-2026-10-06T08-00-00-rid-b.jsonl");
  assert.equal(rememberCodexRollout(join(w.data, "homes/cx"), "rid-b", said), said);
  append(said, [
    JSON.stringify({ timestamp: at, type: "session_meta", payload: { id: "rid-b", cwd: join(w.data, "wb") } }),
    JSON.stringify({ timestamp: at, type: "turn_context", payload: { model: "gpt-6-mini" } }),
    count(10, 5, 0, 5),
  ]);
  // dsh: the window told before its calls; Grok: what the station kept beside its transcript.
  session(w, "dsh-a", join(w.data, "wd"), now - 1_000, "dsh", "ds");
  runtimeSession(w, "dsh-a", "did", "ds");
  append(join(w.data, "transcripts/dsh/proj/did/session.v2.jsonl"), [
    JSON.stringify({ type: "request/context", data: { contextWindow: 128000 } }),
    JSON.stringify({ type: "assistant/message", time: now + 2, data: { message: { id: "d1", source: { model: "deepseek-v4" } }, usage: { inputTokens: 10, cacheReadTokens: 20, cacheWriteTokens: 5, outputTokens: 7 } } }),
  ]);
  append(join(w.data, "transcripts/dsh/proj/did/session.v1.jsonl"), [JSON.stringify({ type: "assistant/message", time: now + 2, data: { message: { id: "old" }, usage: { inputTokens: 1 } } })]);
  session(w, "grok-a", join(w.data, "wg"), now - 1_000, "grok", "gk");
  runtimeSession(w, "grok-a", "gid", "gk");
  append(join(w.data, "transcripts/grok/proj/gid/chat_history.jsonl"), [JSON.stringify({ type: "message" })]);
  append(join(w.data, "transcripts/grok/proj/gid/stillfail-usage.jsonl"), [
    JSON.stringify({ type: "stillfail/usage", id: "g1", time: now + 3, model: "grok-5", usage: { input: 9, cacheRead: 1, cacheWrite: 2, output: 3, calls: 4 }, context: 1234, window: 256000 }),
  ]);
  for (const runtime of ["cursor", "devin", "hermes", "agy"]) {
    session(w, `${runtime}-a`, join(w.data, `w-${runtime}`), now - 1_000, runtime, runtime);
    runtimeSession(w, `${runtime}-a`, `${runtime}-id`, runtime);
    append(join(w.data, `transcripts/${runtime}`, `${runtime}-id.jsonl`), [
      JSON.stringify({ type: "usage", run: "r1", time: now + 4, model: `${runtime}-model`, calls: 3, context: 999, window: 200000, usage: { inputTokens: 11, cacheReadTokens: 12, cacheWriteTokens: 13, outputTokens: 14 } }),
      JSON.stringify({ type: "usage", run: "r2", time: now + 5.5, usage: { inputTokens: 1 } }),
    ]);
  }
  const all = ["codex-a", "codex-b", "dsh-a", "grok-a", "cursor-a", "devin-a", "hermes-a", "agy-a"];
  w.each((s) => all.forEach((key, i) => s.startTurn(`turn-${i}`, key, "input")));
  assert.equal(await w.read(undefined, "every runtime"), 2 + 1 + 1 + 1 + 4 * 2);
  append(rolloutA, [count(400, 200, 150, 40)]);
  assert.equal(await w.read(["codex-a"], "Codex read on"), 1);
});

test("how long each call took: Claude Code's from what asked it, Codex's to its last item, a response read in two parts", { skip }, async () => {
  const w = await world();
  const t0 = w.now();
  const workspace = join(w.data, "sessions/ember/c-9/workspace");
  session(w, "chat:c-9", workspace, t0 - 1_000);
  w.each((s) => s.startTurnFor("t9", "chat:c-9", "input", { profile: "cc", person: "a@x", thread: null }));
  const main = join(w.data, "transcripts/claude", claudeProject(workspace), "r9.jsonl");
  const asked = (at: number) => JSON.stringify({ parentUuid: "p", isSidechain: false, type: "user", message: { role: "user", content: "go" }, timestamp: iso(at) });
  append(main, [asked(t0 + 1_000)]);
  assert.equal(await w.read(undefined, "asked, nothing written yet"), 0);
  append(main, [claudeLine("k1", t0 + 3_000, "claude-opus-5-5", usage(1, 0, 0, 0, 10)), asked(t0 + 3_500)]);
  assert.equal(await w.read(undefined, "its first block"), 1);
  append(main, [
    claudeLine("k1", t0 + 5_000, "claude-opus-5-5", usage(1, 0, 0, 0, 30)),
    JSON.stringify({ type: "api-request", sessionId: "s", id: "r", timestamp: iso(t0 + 6_000) }),
    claudeLine("k2", t0 + 8_000, "claude-opus-5-5", usage(1, 0, 0, 0, 5)),
  ]);
  assert.equal(await w.read(undefined, "its last block, and the next call"), 1);
  // Codex: asked by a turn begun and by a tool's output, timed to the last item before each count.
  session(w, "codex-t", join(w.data, "wt"), t0 - 1_000, "codex", "cx");
  runtimeSession(w, "codex-t", "rid-t", "cx");
  w.each((s) => s.startTurn("turn-t", "codex-t", "input"));
  const rollout = join(w.data, "transcripts/codex/2026/10/06", "rollout-2026-10-06T08-00-00-rid-t.jsonl");
  const line = (at: number, type: string, payload: Record<string, unknown>) => JSON.stringify({ timestamp: iso(at), type, payload });
  const count = (at: number, total: number, output: number) => line(at, "event_msg", {
    type: "token_count", info: { total_token_usage: { total_tokens: total }, last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: output } },
  });
  append(rollout, [
    line(t0, "session_meta", { id: "rid-t", cwd: join(w.data, "wt") }),
    line(t0, "turn_context", { model: "gpt-6" }),
    line(t0 + 1_000, "event_msg", { type: "task_started" }),
    line(t0 + 2_000, "response_item", { type: "reasoning", summary: [] }),
    line(t0 + 4_000, "response_item", { type: "custom_tool_call", name: "exec" }),
  ]);
  assert.equal(await w.read(["codex-t"], "Codex writing"), 0);
  append(rollout, [
    line(t0 + 4_500, "response_item", { type: "custom_tool_call_output", output: "ok" }),
    count(t0 + 4_600, 100, 30),
    line(t0 + 6_000, "response_item", { type: "message", role: "assistant", content: [] }),
    count(t0 + 6_100, 200, 40),
  ]);
  assert.equal(await w.read(["codex-t"], "Codex counted"), 2);
  const timed = (store: Store) => store.db.prepare("SELECT id, output, gen_ms, gen_output FROM usage WHERE gen_ms > 0 ORDER BY id").all();
  assert.deepEqual(timed(w.ts).map((r) => [r.id, r.output, r.gen_ms, r.gen_output]), [
    ["codex:rid-t:100", 30, 3_000, 30], ["codex:rid-t:200", 40, 1_400, 40], ["k1", 30, 4_000, 30], ["k2", 5, 2_000, 5],
  ]);
  const quarters = w.ts.db.prepare("SELECT SUM(gen_ms) AS ms, SUM(gen_output) AS output FROM usage_15m").get() as { ms: number; output: number };
  assert.deepEqual([quarters.ms, quarters.output], [10_400, 105]);
});

test("what was read before calls were timed is timed once, from then on, as a counter starts; no call more", { skip }, async () => {
  const w = await world();
  const t0 = w.now();
  const workspace = join(w.data, "sessions/ember/c-8/workspace");
  session(w, "chat:c-8", workspace, t0 - 1_000);
  w.each((s) => s.startTurnFor("t8", "chat:c-8", "input", { profile: "cc", person: "a@x", thread: null }));
  const main = join(w.data, "transcripts/claude", claudeProject(workspace), "r8.jsonl");
  const asked = (at: number) => JSON.stringify({ parentUuid: "p", isSidechain: false, type: "user", message: { role: "user", content: "go" }, timestamp: iso(at) });
  append(main, [
    asked(t0 + 1_000), claudeLine("j1", t0 + 3_000, "claude-opus-5-5", usage(1, 0, 0, 0, 10)),
    asked(t0 + 10_000), claudeLine("j2", t0 + 14_000, "claude-opus-5-5", usage(1, 0, 0, 0, 20)),
  ]);
  assert.equal(await w.read(undefined, "read and timed"), 2);
  // As a station from before the calls were timed left them: none timed, nothing kept of where its reading stood.
  w.each((s) => s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = NULL"));
  append(main, [asked(t0 + 20_000)]);
  // Counters started anew (what they kept of each transcript let go), told to time from j2 on.
  const profiles = [{ home: join(w.data, "homes/cc") }, { home: join(w.data, "homes/cx") }];
  const ts = new ReferenceUsageCounter({ store: w.ts, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock });
  const mb = new UsageCounter({ store: w.mb, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock, mb: binary });
  cleanup.unshift(() => ts.stop(), () => mb.stop());
  const from = t0 + 5_000;
  assert.equal(await ts.read(new Set(["chat:c-8"]), from), 0);
  assert.equal(await mb.read(new Set(["chat:c-8"]), from), 0);
  assert.deepEqual(dump(w.mb), dump(w.ts), "timed again alike");
  const timed = (store: Store) => store.db.prepare("SELECT id, gen_ms, gen_output FROM usage ORDER BY id").all().map((r) => [r.id, r.gen_ms, r.gen_output]);
  assert.deepEqual(timed(w.ts), [["j1", 0, 0], ["j2", 4_000, 20]]);
  // Its reading goes on from where it stood: the next call timed from the line that asked it.
  append(main, [claudeLine("j3", t0 + 23_000, "claude-opus-5-5", usage(1, 0, 0, 0, 30))]);
  assert.equal(await ts.read(new Set(["chat:c-8"])), 1);
  assert.equal(await mb.read(new Set(["chat:c-8"])), 1);
  assert.deepEqual(dump(w.mb), dump(w.ts), "read on alike");
  assert.deepEqual(timed(w.ts).at(-1), ["j3", 3_000, 30]);
});

test("as a counter starts it finds itself, off the station's thread, the sessions of the last TIMED_BACK_MS read before calls were timed: timed once, none found to time kept so", { skip }, async () => {
  const w = await world();
  const t0 = w.now();
  const asked = (at: number) => JSON.stringify({ parentUuid: "p", isSidechain: false, type: "user", message: { role: "user", content: "go" }, timestamp: iso(at) });
  // c-7 asked, then answered (timed); c-6 a transcript of no call and nothing that asked one (nothing to time).
  const ws7 = join(w.data, "sessions/ember/c-7/workspace");
  const ws6 = join(w.data, "sessions/ember/c-6/workspace");
  session(w, "chat:c-7", ws7, t0 - 1_000);
  session(w, "chat:c-6", ws6, t0 - 1_000);
  w.each((s) => {
    s.startTurnFor("t7", "chat:c-7", "input", { profile: "cc", person: "a@x", thread: null });
    s.startTurnFor("t6", "chat:c-6", "input", { profile: "cc", person: "a@x", thread: null });
  });
  const p7 = join(w.data, "transcripts/claude", claudeProject(ws7), "r7.jsonl");
  const p6 = join(w.data, "transcripts/claude", claudeProject(ws6), "r6.jsonl");
  append(p7, [asked(t0 + 1_000), claudeLine("h1", t0 + 3_000, "claude-opus-5-5", usage(1, 0, 0, 0, 10))]);
  append(p6, [JSON.stringify({ type: "summary", summary: "s", leafUuid: "l" })]);
  // Antigravity's calls are not timed: its transcript read before is not read again for it.
  session(w, "agy-a", join(w.data, "w-agy"), t0 - 1_000, "agy", "agy");
  runtimeSession(w, "agy-a", "agy-id", "agy");
  w.each((s) => s.startTurn("ta", "agy-a", "input"));
  append(join(w.data, "transcripts/agy", "agy-id.jsonl"), [
    JSON.stringify({ type: "usage", run: "r1", time: t0 + 4, model: "agy-model", calls: 1, context: 9, window: 200000, usage: { inputTokens: 1, outputTokens: 2 } }),
  ]);
  assert.equal(await w.read(undefined, "read and timed"), 2);
  assert.equal((w.mb.db.prepare("SELECT COUNT(*) AS n FROM usage_files WHERE speed IS NULL").get() as { n: number }).n, 0, "read now: none left as read before calls were timed");
  w.each((s) => {
    s.endTurn("t7", "completed", null, null, null);
    s.endTurn("t6", "completed", null, null, null);
    s.endTurn("ta", "completed", null, null, null);
  });
  await w.time.adjust(2 * 86_400_000);
  // As a station from before the calls were timed left them, its last sweep after both turns ended: no session ran
  // since that sweep.
  w.each((s) => s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = NULL"));
  w.each((s) => s.db.prepare("UPDATE usage_counter SET through = ? WHERE id = 1").run(w.now()));
  const profiles = [{ home: join(w.data, "homes/cc") }, { home: join(w.data, "homes/cx") }];
  const speeds = (store: Store) => (store.db.prepare("SELECT path, speed FROM usage_files ORDER BY path").all() as { path: string; speed: string | null }[]).map((r) => [r.path, r.speed]);
  const timed = (store: Store) => store.db.prepare("SELECT id, gen_ms, gen_output FROM usage ORDER BY id").all().map((r) => [r.id, r.gen_ms, r.gen_output]);
  // Nothing of it asked on the station's thread.
  w.mb.usageActiveSessions = () => assert.fail("the sessions to time back asked on the station's thread");
  const starts = async () => {
    const ts = new ReferenceUsageCounter({ store: w.ts, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock });
    const mb = new UsageCounter({ store: w.mb, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock, mb: binary, settleMs: 20, safetyMs: 60 * 60_000 });
    cleanup.unshift(() => ts.stop(), () => mb.stop());
    await ts.read(undefined, w.now() - TIMED_BACK_MS);
    const waits = w.time.asked();
    mb.start();
    // Its first wait: what it reads as it starts read.
    await w.time.begun(waits + 1);
    await mb.stop();
  };
  await starts();
  assert.deepEqual(dump(w.mb), dump(w.ts), "timed back alike");
  assert.deepEqual(timed(w.mb).filter(([id]) => id === "h1"), [["h1", 2_000, 10]]);
  const kept = speeds(w.mb);
  assert.equal(kept.length, 3);
  assert.notEqual(new Map(kept as [string, string][]).get(p7) ?? null, null, "where its reading stands kept");
  assert.equal(new Map(kept as [string, string][]).get(p6), ",,,", "nothing found to time: kept as none");
  assert.deepEqual(w.mb.db.prepare(UNTIMED_SESSIONS).all(w.now() - TIMED_BACK_MS), [], "none left to time back");
  // Read on with still nothing to time: kept so.
  append(p6, [JSON.stringify({ type: "summary", summary: "t", leafUuid: "m" })]);
  assert.equal(await w.read(["chat:c-6"], "read on, nothing to time"), 0);
  assert.equal(new Map(speeds(w.mb) as [string, string][]).get(p6), ",,,", "read on: still kept as none");
  // Started again: each timed already, none read again (its calls' times, lost since, not found again).
  w.each((s) => s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0"));
  await starts();
  assert.deepEqual(dump(w.mb), dump(w.ts), "not timed again alike");
  assert.deepEqual(timed(w.mb).filter(([id]) => id === "h1"), [["h1", 0, 0]], "not timed again");
  assert.deepEqual(speeds(w.mb), kept);
});

test("a transcript's calls are timed again WRITE_BATCH a write: one that fails leaves those written before it, the rest timed the next time", { skip }, async () => {
  const w = await world();
  const t0 = w.now();
  const workspace = join(w.data, "sessions/ember/c-5/workspace");
  session(w, "chat:c-5", workspace, t0 - 1_000);
  w.each((s) => s.startTurnFor("t5", "chat:c-5", "input", { profile: "cc", person: "a@x", thread: null }));
  const main = join(w.data, "transcripts/claude", claudeProject(workspace), "r5.jsonl");
  const asked = (at: number) => JSON.stringify({ parentUuid: "p", isSidechain: false, type: "user", message: { role: "user", content: "go" }, timestamp: iso(at) });
  const id = (i: number) => `c${String(i).padStart(3, "0")}`;
  const lines: string[] = [];
  for (let i = 0; i < 150; i++) lines.push(asked(t0 + 1_000 + i * 1_000), claudeLine(id(i), t0 + 1_500 + i * 1_000, "claude-opus-5-5", usage(1, 0, 0, 0, 1)));
  append(main, lines);
  assert.equal(await w.read(["chat:c-5"], "read and timed"), 150);
  w.each((s) => s.db.exec(`UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = NULL;
    CREATE TRIGGER fails_at_c100 BEFORE UPDATE OF gen_ms ON usage WHEN NEW.id = 'c100' BEGIN SELECT RAISE(ABORT, 'fails at c100'); END;`));
  const profiles = [{ home: join(w.data, "homes/cc") }, { home: join(w.data, "homes/cx") }];
  const ts = new ReferenceUsageCounter({ store: w.ts, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock });
  const mb = new UsageCounter({ store: w.mb, config: () => ({ dataDir: w.data, profiles }), clock: w.time.clock, mb: binary });
  cleanup.unshift(() => ts.stop(), () => mb.stop());
  const timed = (store: Store) => (store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE gen_ms > 0").get() as { n: number }).n;
  const speed = (store: Store) => (store.db.prepare("SELECT speed FROM usage_files").get() as { speed: string | null }).speed;
  await assert.rejects(ts.read(new Set(["chat:c-5"]), t0), /c100/);
  await assert.rejects(mb.read(new Set(["chat:c-5"]), t0), /c100/);
  // The first 64 written in their own write; the write holding c100 undone (c064..c127), its position not kept.
  assert.equal(timed(w.ts), 64);
  assert.equal(timed(w.mb), 64);
  assert.equal(speed(w.mb), null);
  assert.deepEqual(dump(w.mb), dump(w.ts), "failed alike");
  w.each((s) => s.db.exec("DROP TRIGGER fails_at_c100"));
  assert.equal(await ts.read(new Set(["chat:c-5"]), t0), 0);
  assert.equal(await mb.read(new Set(["chat:c-5"]), t0), 0);
  assert.deepEqual(dump(w.mb), dump(w.ts), "timed again alike");
  assert.equal(timed(w.mb), 150);
  assert.notEqual(speed(w.mb), null);
});

test("a transcript cut short or replaced is read again from its start, its old calls not taken; put away, read from its frames", { skip }, async () => {
  for (const how of ["shortened", "replaced", "segmented", "single-frame"] as const) {
    const w = await world();
    const now = w.now();
    const workspace = join(w.data, `ws-${how}`);
    session(w, "k", workspace, now - 120_000);
    runtimeSession(w, "k", "r");
    w.each((s) => s.startTurn("t", "k", "input"));
    const path = join(w.data, "transcripts/claude", claudeProject(workspace), "r.jsonl");
    // Long enough for an anchor of its own and for the boundary to fall inside the first read's lines.
    append(path, Array.from({ length: 30 }, (_, i) => claudeLine(`a${i}`, now + i, "claude-opus-5-5", usage(i, 0, 0, 0, 1))));
    assert.equal(await w.read(["k"], `${how}: first`), 30);
    if (how === "shortened") writeFileSync(path, `${claudeLine("b0", now - 10, "claude-opus-5-5", usage(1, 0, 0, 0, 1))}\n`);
    else if (how === "replaced") writeFileSync(path, Array.from({ length: 40 }, (_, i) => `${claudeLine(`c${i}`, now + 100 + i, "claude-opus-5-5", usage(i, 0, 0, 0, 2))}\n`).join(""));
    else {
      append(path, [claudeLine("late", now - 1, "claude-opus-5-5", usage(2, 0, 0, 0, 1)), claudeLine("new", now + 50, "claude-opus-5-5", usage(3, 0, 0, 0, 1))]);
      if (how === "segmented") await packFile(path);
      else pack(path);
    }
    await w.read(["k"], `${how}: again`);
    // And the program started again (nothing kept but the database) reads on as the other does.
    w.mbCounter.trimIdle();
    if (how === "replaced") writeFileSync(path, "x".repeat(10) + "\n", { flag: "a" });
    await w.read(["k"], `${how}: after`);
  }
});

test("a large transcript, its lines across many parts, compressed in segments, read from the segment its offset is in", { skip }, async () => {
  const w = await world();
  const now = w.now();
  const workspace = join(w.data, "big");
  session(w, "k", workspace, now - 120_000);
  runtimeSession(w, "k", "r");
  w.each((s) => s.startTurn("t", "k", "input"));
  const path = join(w.data, "transcripts/claude", claudeProject(workspace), "r.jsonl");
  const filler = "y".repeat(3000);
  const lines = (from: number, n: number) => Array.from({ length: n }, (_, i) => claudeLine(`m${from + i}`, now + from + i, "claude-opus-5-5", usage(i % 7, i, 0, 0, i % 5), { pad: filler }));
  append(path, lines(0, 800));
  assert.equal(await w.read(["k"], "a large file in parts"), 800);
  append(path, lines(800, 400));
  await packFile(path);
  assert.equal(await w.read(["k"], "its segments read on"), 400);
});

test("a chat that switched runtime counts its earlier runtime's last calls on that account", { skip }, async () => {
  const w = await world();
  const workspace = join(w.data, "sessions/ember/c-switch/workspace");
  const key = "chat:c-switch";
  const now = w.now();
  session(w, key, workspace, now - 120_000);
  w.each((s) => s.startTurnFor("t1", key, "input", { profile: "cc", person: "a@x", thread: null }));
  runtimeSession(w, key, "r1");
  w.each((s) => s.setSessionRuntime(key, "codex", "cx", false, null, null, null, null));
  const path = join(w.data, "transcripts/claude", claudeProject(workspace), "r1.jsonl");
  append(path, [claudeLine("old", now - 60_000, "claude-opus-5-5", usage(10, 0, 0, 0, 1)), claudeLine("new", now + 1, "claude-opus-5-5", usage(2, 0, 0, 0, 1))]);
  w.each((s) => s.endTurn("t1", "completed", null, null, null));
  assert.equal(await w.read(undefined, "the switched runtime"), 1);
  assert.equal(await w.read(undefined, "again"), 0);
});

test("the compact statistics: the recent contexts, a compaction, a saved summary seeding them, a late call", { skip }, async () => {
  const w = await world({ compact: true });
  const t = w.time;
  const workspace = join(w.data, "compact");
  const key = "chat:c-compact";
  const now = w.now();
  session(w, key, workspace, now - 120_000);
  runtimeSession(w, key, "r1");
  w.each((s) => s.startTurnFor("t1", key, "input", { profile: "cc", person: "a@x", thread: null }));
  const path = join(w.data, "transcripts/claude", claudeProject(workspace), "r1.jsonl");
  append(path, [
    claudeLine("c1", now + 1, "claude-opus-5-5", usage(10, 90_000, 500, 0, 1)),
    claudeLine("c2", now + 2, "claude-opus-5-5", usage(10, 95_000, 0, 700, 1)),
  ]);
  assert.equal(await w.read(undefined, "the first calls"), 2);
  await t.adjust(10);
  w.each((s) => s.endTurn("t1", "completed", null, null, null));
  w.each((s) => s.startTurnFor("t2", key, "input", { profile: "cc", person: "a@x", thread: null }));
  const later = w.now();
  append(path, [
    // compacted: under half of what the call before sent
    claudeLine("c3", later + 1, "claude-opus-5-5", usage(10, 20_000, 0, 0, 1)),
    claudeLine("c4", later + 2, "claude-sonnet-5-5", usage(10, 1_000, 0, 0, 1), { }),
    claudeLine("c5", later + 3, "claude-opus-5-5", usage(10, 2_000, 0, 0, 1)),
    claudeLine("c6", later + 3, "claude-opus-5-5", usage(10, 2_500, 0, 0, 1)),
    claudeLine("c7", later + 4, "claude-opus-5-5", usage(10, 3_000, 0, 0, 1)),
  ]);
  assert.equal(await w.read(["chat:c-compact"], "a compaction"), 5);
  assert.match(contexts(w.mb), /"compacted":true/, "a compaction is in the turns kept");
  // A call before the last ones: out of order.
  append(path, [claudeLine("c0", later - 5, "claude-opus-5-5", usage(10, 4_000, 0, 0, 1))]);
  assert.equal(await w.read(["chat:c-compact"], "a call out of order"), 1);
  assert.match(contexts(w.mb), /"uncertain":true/, "a call out of order made the turns uncertain");
  w.each((s) => keepUsage(s, key));
  append(path, [claudeLine("c8", later + 9, "claude-opus-5-5", usage(10, 3_500, 0, 0, 1))]);
  assert.equal(await w.read(["chat:c-compact"], "after the summary was kept"), 1);
});

test("calls counted before the compact statistics seed their context from the session's saved summary", { skip }, async () => {
  const w = await world();
  const key = "chat:c-seed";
  const workspace = join(w.data, "seed");
  const now = w.now();
  session(w, key, workspace, now - 120_000);
  runtimeSession(w, key, "r1");
  w.each((s) => s.startTurnFor("t1", key, "input", { profile: "cc", person: "a@x", thread: null }));
  const path = join(w.data, "transcripts/claude", claudeProject(workspace), "r1.jsonl");
  append(path, [claudeLine("o1", now + 1, "claude-opus-5-5", usage(10, 1_000, 300, 0, 1)), claudeLine("o2", now + 2, "claude-opus-5-5", usage(10, 2_000, 0, 0, 1))]);
  assert.equal(await w.read(undefined, "before the compact statistics"), 2);
  w.each((s) => keepUsage(s, key));
  w.each((s) => { installCompactUsage(s.db); retireUsageIndexes(s.db); });
  append(path, [claudeLine("o3", now + 3, "claude-opus-5-5", usage(10, 2_500, 0, 0, 1)), claudeLine("o2", now + 2, "claude-opus-5-5", usage(10, 2_000, 0, 0, 4))]);
  assert.equal(await w.read(["chat:c-seed"], "seeded from the saved summary"), 1);
  assert.match(contexts(w.mb), /"saved":\{"runtimeSession":"r1"/, "seeded from the saved summary");
  // A call at the saved summary's own time makes the order unknown.
  append(path, [claudeLine("o4", now + 2, "claude-opus-5-5", usage(10, 2_600, 0, 0, 1))]);
  await w.read(["chat:c-seed"], "a call at the summary's time");
  assert.doesNotMatch(contexts(w.mb), /"saved"/, "the saved summary let go");
});

test("the program starts at its first read, is let go when trimmed or idle, and starts again for the next", { skip }, async () => {
  const time = await today();
  const data = mkdtempSync(join(tmpdir(), "mb-usage-life-"));
  dirs.push(data);
  const store = Store.open(join(data, "stillfail.db"), null, time.clock);
  cleanup.push(() => { try { store.close(); } catch {} });
  const timers: { ms: number; f: () => void; on: boolean }[] = [];
  const after = (ms: number, f: () => void) => {
    const t = { ms, f, on: true };
    timers.push(t);
    return () => { t.on = false; };
  };
  const counter = new UsageCounter({ store, config: () => ({ dataDir: data, profiles: [] }), clock: time.clock, mb: binary, after });
  cleanup.unshift(() => counter.stop());
  const workspace = join(data, "w");
  store.insertSession({ key: "k", connect: "ember", createdBy: "c@x", runtime: "claude", profile: "cc", workspace, token: "t-k", createdAt: store.now() - 1, lastActiveAt: store.now() });
  store.setRuntimeSessionId("k", "r");
  store.startTurn("t", "k", "input");
  const path = join(data, "transcripts/claude", claudeProject(workspace), "r.jsonl");
  append(path, [claudeLine("x1", store.now() + 1, "claude-opus-5-5", usage(1, 0, 0, 0, 1))]);
  assert.equal(counter.trimIdle(), 0, "nothing to let go before the first read");
  assert.equal(await counter.read(), 1);
  assert.equal(counter.trimIdle(), 1, "let go at once with nothing asked of it");
  assert.equal(counter.trimIdle(), 0);
  append(path, [claudeLine("x2", store.now() + 2, "claude-opus-5-5", usage(2, 0, 0, 0, 1))]);
  assert.equal(await counter.read(new Set(["k"])), 1, "started again by the next read, read on from where it was");
  // Idle IDLE_MS: its timer lets it go.
  const armed = timers.filter((t) => t.on).at(-1)!;
  assert.equal(armed.ms, 60_000);
  armed.f();
  assert.equal(counter.trimIdle(), 0, "already let go");
  append(path, [claudeLine("x3", store.now() + 3, "claude-opus-5-5", usage(3, 0, 0, 0, 1))]);
  assert.equal(await counter.read(new Set(["k"])), 1);
  assert.deepEqual(store.db.prepare("SELECT id FROM usage ORDER BY id").all().map((r) => r.id), ["x1", "x2", "x3"]);
});

test("there is no counter without the program: in memory, or where it was not built, it says so", () => {
  const store = Store.open(":memory:", null);
  cleanup.push(() => { try { store.close(); } catch {} });
  assert.throws(() => new UsageCounter({ store, config: () => ({ dataDir: "/nowhere", profiles: [] }), mb: "/bin/true" }), /not one in memory/);
  const data = mkdtempSync(join(tmpdir(), "mb-usage-off-"));
  dirs.push(data);
  const file = Store.open(join(data, "stillfail.db"), null);
  cleanup.push(() => { try { file.close(); } catch {} });
  assert.throws(() => new UsageCounter({ store: file, config: () => ({ dataDir: data, profiles: [] }), mb: null }), /MoonBit reader/);
  // Made, it starts nothing before its first read.
  const counter = new UsageCounter({ store: file, config: () => ({ dataDir: data, profiles: [] }), mb: "/bin/true" });
  assert.equal(counter.trimIdle(), 0);
});
