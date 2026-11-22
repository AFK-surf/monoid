// Bounded reads for the new `agy` startup timing backfill path (usagecount/counter.mbt `recent_timing_candidates`
// -> `agy_only_sessions`, test/usage-counter-reference.ts `recentTimingCandidates` -> `agyOnlySessions`):
// - Only this new `agy` startup path is bounded via `turns_ended` (LIMIT 256, no `OFFSET`); legacy `UNTIMED_SESSIONS`
//   for `claude`/`codex` `speed IS NULL` is preserved as-is and not widened.
// - Handles >256 recent turns and thousands of same-millisecond `ended_at` rows in linear O(N) pages without drops.
// - Out-of-window historical turns and `usage_files` do not increase `recentTimingCandidates` query work.
// - Non-agy sessions (pure `codex` and mixed `codex+agy` / `agy+codex`) brought in only by `timeFrom` never locate
//   or read Codex transcripts; `agy` is backfilled once and archived `v1:` is not re-decompressed on restart.
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { zstdCompressSync } from "node:zlib";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { TIMED_BACK_MS, UsageCounter } from "../src/usage/counter.ts";
import {
  RECENT_ENDED_AFTER_SQL,
  RECENT_ENDED_FIRST_SQL,
  RECENT_ENDED_SAME_SQL,
  RECENT_RUNNING_TURNS_SQL,
  RECENT_TIMING_PAGE,
  ReferenceUsageCounter,
  recentTimingCandidates,
} from "./usage-counter-reference.ts";
import { testClock } from "./hub-fakes.ts";

const binary = mbReaderBinary();
const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];
after(async () => {
  for (const f of cleanup) await f();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function planOf(db: Store["db"], sql: string, params: unknown[]): string[] {
  return (db.prepare(`EXPLAIN QUERY PLAN ${sql}`).all(...(params as any[])) as { detail: string }[]).map((r) => r.detail);
}

test("recentTimingCandidates uses turns_ended index seeks without scanning usage_files or using OFFSET", () => {
  const time = testClock();
  const store = Store.open(":memory:", null, time.clock);
  cleanup.unshift(() => store.close());

  const runPlan = planOf(store.db, RECENT_RUNNING_TURNS_SQL, [0]);
  const firstPlan = planOf(store.db, RECENT_ENDED_FIRST_SQL, [1000]);
  const samePlan = planOf(store.db, RECENT_ENDED_SAME_SQL, [1000, 0]);
  const afterPlan = planOf(store.db, RECENT_ENDED_AFTER_SQL, [1000]);

  for (const [name, plan] of [["running", runPlan], ["ended-first", firstPlan], ["ended-same", samePlan], ["ended-after", afterPlan]] as const) {
    assert.ok(plan.some((d) => d.includes("SEARCH turns USING INDEX turns_ended")), `${name}: expected turns_ended index seek, got ${JSON.stringify(plan)}`);
    assert.ok(!plan.some((d) => d.includes("SCAN ")), `${name}: unexpected full scan ${JSON.stringify(plan)}`);
    assert.ok(!plan.some((d) => d.includes("usage_files")), `${name}: must not touch usage_files ${JSON.stringify(plan)}`);
  }
  // Exact 2-column seek on (ended_at=? AND rowid>?) for both running and same-millisecond ended pages.
  assert.ok(runPlan.some((d) => d.includes("ended_at=?") && d.includes("rowid>?")), `running seek: ${JSON.stringify(runPlan)}`);
  assert.ok(samePlan.some((d) => d.includes("ended_at=?") && d.includes("rowid>?")), `same-ms seek: ${JSON.stringify(samePlan)}`);
});

test("recentTimingCandidates paginates >256 turns and thousands of same-millisecond ended_at rows linearly without dropping any", async () => {
  const time = testClock();
  const now = Date.parse("2026-11-21T00:00:00Z");
  await time.adjust(now);
  const store = Store.open(":memory:", null, time.clock);
  cleanup.unshift(() => store.close());

  const timeFrom = now - TIMED_BACK_MS;
  store.db.exec("BEGIN IMMEDIATE");
  try {
    const insSession = store.db.prepare(
      "INSERT INTO sessions (key, connect, scope, created_by, runtime, profile, workspace, token, created_at, last_active_at) VALUES (?, 'ember', 'chat', 'a@x', 'agy', 'ag', '/w', ?, ?, ?)",
    );
    const insTurn = store.db.prepare(
      "INSERT INTO turns (id, session_key, kind, started_at, ended_at) VALUES (?, ?, 'input', ?, ?)",
    );
    const insFile = store.db.prepare(
      "INSERT INTO usage_files (path, session, offset, model, speed) VALUES (?, ?, 100, 'gemini-4-neon', ',,,')",
    );
    // 2,000 out-of-window historical sessions/turns/usage_files (must not be returned or increase recent page count).
    for (let i = 0; i < 2000; i++) {
      const key = `old-${i}`;
      insSession.run(key, `t-${key}`, timeFrom - 10_000_000, timeFrom - 10_000_000);
      insTurn.run(`turn-old-${i}`, key, timeFrom - 10_000_000, timeFrom - 1000 - i);
      insFile.run(`/data/transcripts/agy/${key}.jsonl`, key);
    }
    // 300 running turns (spans >1 page of 256).
    for (let i = 0; i < 300; i++) {
      const key = `run-${i}`;
      insSession.run(key, `t-${key}`, now - 1000, now);
      insTurn.run(`turn-run-${i}`, key, now - 1000, null);
    }
    // 2,100 ended turns sharing the exact same `ended_at` millisecond (tests O(N) linear pagination, no drops).
    const sameTs = timeFrom + 50_000;
    for (let i = 0; i < 2100; i++) {
      const key = `same-${i}`;
      insSession.run(key, `t-${key}`, sameTs - 100, sameTs);
      insTurn.run(`turn-same-${i}`, key, sameTs - 100, sameTs);
    }
    // 300 ended turns at distinct timestamps after sameTs.
    for (let i = 0; i < 300; i++) {
      const key = `after-${i}`;
      insSession.run(key, `t-${key}`, sameTs + 1000 + i, sameTs + 2000 + i);
      insTurn.run(`turn-after-${i}`, key, sameTs + 1000 + i, sameTs + 2000 + i);
    }
    store.db.exec("COMMIT");
  } catch (e) {
    store.db.exec("ROLLBACK");
    throw e;
  }

  // Count SQLite query executions during recentTimingCandidates to assert O(N / 256) linear pages.
  let queries = 0;
  const countedDb = {
    prepare(sql: string) {
      const stmt = store.db.prepare(sql);
      return {
        all(...args: any[]) {
          queries++;
          return stmt.all(...args);
        },
      };
    },
  } as unknown as typeof store.db;

  const got = recentTimingCandidates(countedDb, timeFrom);
  const set = new Set(got);
  assert.equal(got.length, 300 + 2100 + 300, "exact deduplicated count of all recent/running sessions");
  assert.equal(set.size, got.length, "no duplicate sessions");
  assert.ok(!set.has("old-0") && !set.has("old-1999"), "out-of-window historical sessions excluded");
  assert.ok(set.has("run-0") && set.has("run-299"), "all running sessions included across pages");
  assert.ok(set.has("same-0") && set.has("same-1000") && set.has("same-2099"), "all 2100 same-ms sessions included without drops");
  assert.ok(set.has("after-0") && set.has("after-299"), "all later sessions included");
  // Expected pages: 2 running + 1 first + ~9 same-ms + 2 after ~= 14..16 queries (linear in N/256, not quadratic).
  const maxLinearPages = Math.ceil(300 / RECENT_TIMING_PAGE) + Math.ceil((2100 + 300) / RECENT_TIMING_PAGE) + 6;
  assert.ok(queries <= maxLinearPages, `expected <= ${maxLinearPages} paged queries, got ${queries}`);
});

test("mixed-runtime session (pi ',,,' + archived agy 'v1:') does not re-decompress or rewrite timing on repeated startups", { skip: binary === null && "no MoonBit reader built" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "usage-timing-mixed-"));
  dirs.push(data);
  const time = testClock();
  const t0 = Date.parse("2026-11-20T08:00:00Z");
  await time.adjust(t0);

  const open = (name: string) => {
    const s = Store.open(join(data, `${name}.db`), null, time.clock);
    cleanup.unshift(() => s.close());
    return s;
  };
  const tsStore = open("ts");
  const mbStore = open("mb");
  const each = (f: (s: Store) => void) => { f(tsStore); f(mbStore); };

  each((s) => {
    s.insertSession({ key: "mixed-1", connect: "ember", createdBy: "a@x", runtime: "pi", profile: "pi", workspace: join(data, "w-mixed"), token: "tok", createdAt: t0 - 1000, lastActiveAt: t0 });
    s.setRuntimeSessionId("mixed-1", "pi-id");
    s.ranIn("mixed-1", "pi-id", "pi");
    s.setSessionRuntime("mixed-1", "agy", "ag", false, null, null, null, null);
    s.setRuntimeSessionId("mixed-1", "agy-id");
    s.ranIn("mixed-1", "agy-id", "ag");
    s.startTurnFor("t1", "mixed-1", "input", { profile: "ag", person: "a@x", thread: null });
  });

  const piPath = join(data, "transcripts/pi/pi-id.jsonl");
  const agyPath = join(data, "transcripts/agy/agy-id.jsonl");
  mkdirSync(dirname(piPath), { recursive: true });
  mkdirSync(dirname(agyPath), { recursive: true });
  appendFileSync(piPath, `${JSON.stringify({ type: "message", id: "p1", timestamp: new Date(t0 + 1000).toISOString(), message: { role: "assistant", model: "m1", usage: { input: 10, output: 5, cacheRead: 0, cacheWrite: 0 } } })}\n`);
  appendFileSync(agyPath, [
    JSON.stringify({ type: "user", time: t0 + 2000 }),
    JSON.stringify({ type: "tool", startedAt: t0 + 2500, time: t0 + 3500 }),
    JSON.stringify({ type: "usage", run: "r1", time: t0 + 5000, model: "gemini-4-neon", calls: 1, usage: { inputTokens: 10, outputTokens: 100 } }),
    JSON.stringify({ type: "end", time: t0 + 5100 }),
  ].join("\n") + "\n");

  const config = () => ({ dataDir: data, profiles: [{ home: join(data, "homes/ag") }] });
  const runOnce = async (timeFrom?: number) => {
    const ts = new ReferenceUsageCounter({ store: tsStore, config, clock: time.clock });
    const mb = new UsageCounter({ store: mbStore, config, clock: time.clock, mb: binary });
    try {
      await ts.read(undefined, timeFrom);
      await mb.read(undefined, timeFrom);
    } finally {
      await ts.stop();
      await mb.stop();
    }
  };

  await runOnce();
  each((s) => s.endTurn("t1", "completed", null, null, null));
  // Archive agy transcript and simulate legacy ',,,' on both files.
  writeFileSync(`${agyPath}.zst`, zstdCompressSync(readFileSync(agyPath)));
  unlinkSync(agyPath);
  each((s) => {
    s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = ',,,'");
    s.db.prepare("UPDATE usage_counter SET through = ? WHERE id = 1").run(t0 + 60_000);
  });

  // First startup backfill upgrades agy to 'v1:' and leaves pi at ',,,'.
  await runOnce(t0 - TIMED_BACK_MS);
  assert.equal((mbStore.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r1'").get() as { gen_ms: number }).gen_ms, 2000);
  assert.equal((mbStore.db.prepare("SELECT speed FROM usage_files WHERE path = ?").get(agyPath) as { speed: string }).speed, "v1:");
  assert.equal((mbStore.db.prepare("SELECT speed FROM usage_files WHERE path = ?").get(piPath) as { speed: string }).speed, ",,,");

  // Second startup: pi ',,,' must not trigger agy backfill or re-decompress archived agy.
  each((s) => s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0"));
  await runOnce(t0 - TIMED_BACK_MS);
  assert.equal((mbStore.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r1'").get() as { gen_ms: number }).gen_ms, 0, "archived upgraded agy not re-decompressed/re-timed");
  assert.equal((tsStore.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r1'").get() as { gen_ms: number }).gen_ms, 0, "TS reference parity");
});

test("agy-only startup backfill skips Codex transcript lookup for pure-codex and mixed codex+agy/agy+codex sessions", { skip: binary === null && "no MoonBit reader built" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "usage-timing-agy-only-"));
  dirs.push(data);
  const time = testClock();
  const t0 = Date.parse("2026-11-20T08:00:00Z");
  await time.adjust(t0);

  const open = (name: string) => {
    const s = Store.open(join(data, `${name}.db`), null, time.clock);
    cleanup.unshift(() => s.close());
    return s;
  };
  const tsStore = open("ts");
  const mbStore = open("mb");
  const each = (f: (s: Store) => void) => { f(tsStore); f(mbStore); };

  // 1. Pure codex session (already timed / no speed IS NULL row): turn inside timeFrom, cursor after turn.
  // 2. Mixed codex -> agy session: codex already timed (',,,'), agy archived with legacy ',,,'.
  // 3. Mixed agy -> codex session: agy archived with legacy ',,,', codex already timed (',,,').
  each((s) => {
    s.insertSession({ key: "pure-codex", connect: "ember", createdBy: "a@x", runtime: "codex", profile: "cx", workspace: join(data, "w-cx"), token: "tok-cx", createdAt: t0 - 1000, lastActiveAt: t0 });
    s.setRuntimeSessionId("pure-codex", "cx-pure");
    s.ranIn("pure-codex", "cx-pure", "cx");
    s.startTurnFor("t-cx", "pure-codex", "input", { profile: "cx", person: "a@x", thread: null });

    s.insertSession({ key: "codex-to-agy", connect: "ember", createdBy: "a@x", runtime: "codex", profile: "cx", workspace: join(data, "w-c2a"), token: "tok-c2a", createdAt: t0 - 1000, lastActiveAt: t0 });
    s.setRuntimeSessionId("codex-to-agy", "cx-c2a");
    s.ranIn("codex-to-agy", "cx-c2a", "cx");
    s.setSessionRuntime("codex-to-agy", "agy", "ag", false, null, null, null, null);
    s.setRuntimeSessionId("codex-to-agy", "agy-c2a");
    s.ranIn("codex-to-agy", "agy-c2a", "ag");
    s.startTurnFor("t-c2a", "codex-to-agy", "input", { profile: "ag", person: "a@x", thread: null });

    s.insertSession({ key: "agy-to-codex", connect: "ember", createdBy: "a@x", runtime: "agy", profile: "ag", workspace: join(data, "w-a2c"), token: "tok-a2c", createdAt: t0 - 1000, lastActiveAt: t0 });
    s.setRuntimeSessionId("agy-to-codex", "agy-a2c");
    s.ranIn("agy-to-codex", "agy-a2c", "ag");
    s.setSessionRuntime("agy-to-codex", "codex", "cx", false, null, null, null, null);
    s.setRuntimeSessionId("agy-to-codex", "cx-a2c");
    s.ranIn("agy-to-codex", "cx-a2c", "cx");
    s.startTurnFor("t-a2c", "agy-to-codex", "input", { profile: "cx", person: "a@x", thread: null });
  });

  const codexLine = (id: string, at: number, outTok: number) => [
    JSON.stringify({ timestamp: new Date(at - 1000).toISOString(), type: "session_meta", payload: { id } }),
    JSON.stringify({ timestamp: new Date(at - 500).toISOString(), type: "turn_context", payload: { model: "gpt-6.2-sol" } }),
    JSON.stringify({ timestamp: new Date(at).toISOString(), type: "event_msg", payload: { type: "token_count", info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: outTok }, total_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: outTok } } } }),
  ].join("\n") + "\n";

  const agyLines = (run: string) => [
    JSON.stringify({ type: "user", time: t0 + 2000 }),
    JSON.stringify({ type: "tool", startedAt: t0 + 2500, time: t0 + 3500 }),
    JSON.stringify({ type: "usage", run, time: t0 + 5000, model: "gemini-4-neon", calls: 1, usage: { inputTokens: 10, outputTokens: 100 } }),
    JSON.stringify({ type: "end", time: t0 + 5100 }),
  ].join("\n") + "\n";

  const codexDir = join(data, "transcripts/codex/2026/11/20");
  mkdirSync(codexDir, { recursive: true });
  const cxPurePath = join(codexDir, "rollout-2026-11-20T08-00-00-cx-pure.jsonl");
  const cxC2aPath = join(codexDir, "rollout-2026-11-20T08-00-00-cx-c2a.jsonl");
  const cxA2cPath = join(codexDir, "rollout-2026-11-20T08-00-00-cx-a2c.jsonl");
  const agyC2aPath = join(data, "transcripts/agy/agy-c2a.jsonl");
  const agyA2cPath = join(data, "transcripts/agy/agy-a2c.jsonl");
  mkdirSync(dirname(agyC2aPath), { recursive: true });

  writeFileSync(cxC2aPath, codexLine("cx-c2a", t0 + 1000, 11));
  writeFileSync(cxA2cPath, codexLine("cx-a2c", t0 + 1000, 12));
  writeFileSync(agyC2aPath, agyLines("r-c2a"));
  writeFileSync(agyA2cPath, agyLines("r-a2c"));

  const config = () => ({ dataDir: data, profiles: [{ home: join(data, "homes/cx") }, { home: join(data, "homes/ag") }] });
  const runOnce = async (timeFrom?: number) => {
    const ts = new ReferenceUsageCounter({ store: tsStore, config, clock: time.clock });
    const mb = new UsageCounter({ store: mbStore, config, clock: time.clock, mb: binary });
    try {
      const tsAdded = await ts.read(undefined, timeFrom);
      const mbAdded = await mb.read(undefined, timeFrom);
      assert.equal(mbAdded, tsAdded, "added parity");
      return mbAdded;
    } finally {
      await ts.stop();
      await mb.stop();
    }
  };

  // Initial read records the two mixed sessions; pure-codex has no file yet so no usage_files row exists for it.
  await runOnce();
  each((s) => {
    s.endTurn("t-cx", "completed", null, null, null);
    s.endTurn("t-c2a", "completed", null, null, null);
    s.endTurn("t-a2c", "completed", null, null, null);
  });

  // Archive both agy transcripts and simulate legacy ',,,' on all existing usage_files rows.
  for (const p of [agyC2aPath, agyA2cPath]) {
    writeFileSync(`${p}.zst`, zstdCompressSync(readFileSync(p)));
    unlinkSync(p);
  }
  // Now place an unread Codex rollout file for pure-codex AND append a new Codex event to both mixed sessions' Codex
  // files, while advancing `through` past all turns. Because all sessions are outside `recent` and none has `speed IS NULL`,
  // ONLY `recentTimingCandidates` (`agy_only_sessions`) brings them in: Codex transcripts must NEVER be located or read.
  writeFileSync(cxPurePath, codexLine("cx-pure", t0 + 2000, 21));
  appendFileSync(cxC2aPath, `${JSON.stringify({ timestamp: new Date(t0 + 2000).toISOString(), type: "event_msg", payload: { type: "token_count", info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 22 }, total_token_usage: { input_tokens: 20, cached_input_tokens: 0, output_tokens: 33 } } } })}\n`);
  appendFileSync(cxA2cPath, `${JSON.stringify({ timestamp: new Date(t0 + 2000).toISOString(), type: "event_msg", payload: { type: "token_count", info: { last_token_usage: { input_tokens: 10, cached_input_tokens: 0, output_tokens: 23 }, total_token_usage: { input_tokens: 20, cached_input_tokens: 0, output_tokens: 35 } } } })}\n`);

  const cxOffsetsBefore = (mbStore.db.prepare("SELECT path, offset FROM usage_files WHERE path IN (?, ?) ORDER BY path").all(cxC2aPath, cxA2cPath) as { path: string; offset: number }[])
    .map((r) => [r.path, r.offset]);

  each((s) => {
    s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0; UPDATE usage_files SET speed = ',,,'");
    s.db.prepare("UPDATE usage_counter SET through = ? WHERE id = 1").run(t0 + 120_000);
  });

  // First startup backfill: 0 new calls (no Codex file read!), both agy transcripts backfilled to 2000ms and 'v1:'.
  assert.equal(await runOnce(t0 - TIMED_BACK_MS), 0, "no new Codex calls read during agy-only startup backfill");
  for (const [label, s] of [["mb", mbStore], ["ts", tsStore]] as const) {
    assert.equal((s.db.prepare("SELECT COUNT(*) AS n FROM usage_files WHERE path = ?").get(cxPurePath) as { n: number }).n, 0, `${label}: pure-codex never located/read`);
    const cxOffsetsAfter = (s.db.prepare("SELECT path, offset FROM usage_files WHERE path IN (?, ?) ORDER BY path").all(cxC2aPath, cxA2cPath) as { path: string; offset: number }[])
      .map((r) => [r.path, r.offset]);
    assert.deepEqual(cxOffsetsAfter, cxOffsetsBefore, `${label}: mixed sessions' Codex offsets untouched`);
    assert.equal((s.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r-c2a'").get() as { gen_ms: number }).gen_ms, 2000, `${label}: codex->agy backfilled`);
    assert.equal((s.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r-a2c'").get() as { gen_ms: number }).gen_ms, 2000, `${label}: agy->codex backfilled`);
    assert.equal((s.db.prepare("SELECT speed FROM usage_files WHERE path = ?").get(agyC2aPath) as { speed: string }).speed, "v1:");
    assert.equal((s.db.prepare("SELECT speed FROM usage_files WHERE path = ?").get(agyA2cPath) as { speed: string }).speed, "v1:");
  }

  // Second startup: upgraded archived `v1:` agy transcripts must NOT be re-decompressed or re-timed.
  each((s) => s.db.exec("UPDATE usage SET gen_ms = 0, gen_output = 0"));
  assert.equal(await runOnce(t0 - TIMED_BACK_MS), 0);
  for (const [label, s] of [["mb", mbStore], ["ts", tsStore]] as const) {
    assert.equal((s.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r-c2a'").get() as { gen_ms: number }).gen_ms, 0, `${label}: archived v1 codex->agy not re-timed`);
    assert.equal((s.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r-a2c'").get() as { gen_ms: number }).gen_ms, 0, `${label}: archived v1 agy->codex not re-timed`);
  }
});

test("agy-only startup backfill skips untracked idle agy files (plain + archived) and already-upgraded v1 unarchived files", { skip: binary === null && "no MoonBit reader built" }, async () => {
  const data = mkdtempSync(join(tmpdir(), "usage-timing-untracked-agy-"));
  dirs.push(data);
  const time = testClock();
  const t0 = Date.parse("2026-11-20T08:00:00Z");
  await time.adjust(t0);

  const open = (name: string) => {
    const s = Store.open(join(data, `${name}.db`), null, time.clock);
    cleanup.unshift(() => s.close());
    return s;
  };
  const tsStore = open("ts");
  const mbStore = open("mb");
  const each = (f: (s: Store) => void) => { f(tsStore); f(mbStore); };

  const agyTurn = (run: string, base: number, outTok: number) => [
    JSON.stringify({ type: "user", time: base }),
    JSON.stringify({ type: "tool", startedAt: base + 500, time: base + 1500 }),
    JSON.stringify({ type: "usage", run, time: base + 3000, model: "gemini-4-neon", calls: 1, usage: { inputTokens: 10, outputTokens: outTok } }),
    JSON.stringify({ type: "end", time: base + 3100 }),
  ].join("\n") + "\n";

  // Untracked idle sessions whose turn ended BEFORE usage_counter.since (t0 + 60_000) and >= timeFrom:
  // one archived (.jsonl.zst), one plain (.jsonl).
  // Plus one tracked, already-upgraded v1 unarchived session whose turn is outside recent.
  each((s) => {
    s.insertSession({ key: "untracked-plain", connect: "ember", createdBy: "a@x", runtime: "agy", profile: "ag", workspace: join(data, "w-up"), token: "tok-up", createdAt: t0 - 2000, lastActiveAt: t0 });
    s.setRuntimeSessionId("untracked-plain", "agy-up");
    s.ranIn("untracked-plain", "agy-up", "ag");
    s.startTurnFor("t-up", "untracked-plain", "input", { profile: "ag", person: "a@x", thread: null });
    s.endTurn("t-up", "completed", null, null, null);

    s.insertSession({ key: "untracked-arch", connect: "ember", createdBy: "a@x", runtime: "agy", profile: "ag", workspace: join(data, "w-ua"), token: "tok-ua", createdAt: t0 - 2000, lastActiveAt: t0 });
    s.setRuntimeSessionId("untracked-arch", "agy-ua");
    s.ranIn("untracked-arch", "agy-ua", "ag");
    s.startTurnFor("t-ua", "untracked-arch", "input", { profile: "ag", person: "a@x", thread: null });
    s.endTurn("t-ua", "completed", null, null, null);

    s.insertSession({ key: "upgraded-v1", connect: "ember", createdBy: "a@x", runtime: "agy", profile: "ag", workspace: join(data, "w-v1"), token: "tok-v1", createdAt: t0 - 2000, lastActiveAt: t0 });
    s.setRuntimeSessionId("upgraded-v1", "agy-v1");
    s.ranIn("upgraded-v1", "agy-v1", "ag");
    s.startTurnFor("t-v1", "upgraded-v1", "input", { profile: "ag", person: "a@x", thread: null });
  });

  const agyDir = join(data, "transcripts/agy");
  mkdirSync(agyDir, { recursive: true });
  const upPath = join(agyDir, "agy-up.jsonl");
  const uaPath = join(agyDir, "agy-ua.jsonl");
  const v1Path = join(agyDir, "agy-v1.jsonl");
  writeFileSync(v1Path, agyTurn("r-v1-initial", t0 + 1000, 120));

  const config = () => ({ dataDir: data, profiles: [{ home: join(data, "homes/ag") }] });
  const runOnce = async (only?: ReadonlySet<string>, timeFrom?: number) => {
    const ts = new ReferenceUsageCounter({ store: tsStore, config, clock: time.clock });
    const mb = new UsageCounter({ store: mbStore, config, clock: time.clock, mb: binary });
    try {
      const tsAdded = await ts.read(only, timeFrom);
      const mbAdded = await mb.read(only, timeFrom);
      assert.equal(mbAdded, tsAdded, "added parity");
      return mbAdded;
    } finally {
      await ts.stop();
      await mb.stop();
    }
  };

  // Track `upgraded-v1` normally so it has offset > 0 and speed = 'v1:'.
  assert.equal(await runOnce(new Set(["upgraded-v1"])), 1);
  each((s) => s.endTurn("t-v1", "completed", null, null, null));
  const v1OffsetBefore = (mbStore.db.prepare("SELECT offset FROM usage_files WHERE path = ?").get(v1Path) as { offset: number }).offset;
  assert.equal((mbStore.db.prepare("SELECT speed FROM usage_files WHERE path = ?").get(v1Path) as { speed: string }).speed, "v1:");

  // Now create the two untracked historical agy transcripts (plain + archived .zst) and advance usage_counter.since
  // and through past all three turns (ended_at < since, ended_at >= timeFrom). Also append a new usage turn to the
  // already-upgraded v1 unarchived file.
  writeFileSync(upPath, agyTurn("r-up-old", t0 + 500, 80));
  writeFileSync(`${uaPath}.zst`, zstdCompressSync(Buffer.from(agyTurn("r-ua-old", t0 + 500, 90))));
  appendFileSync(v1Path, agyTurn("r-v1-appended", t0 + 10_000, 150));

  each((s) => {
    s.db.prepare("UPDATE usage_counter SET since = ?, through = ? WHERE id = 1").run(t0 + 60_000, t0 + 120_000);
  });

  // Startup read with timeFrom: none of the three sessions are in `recent` or `UNTIMED_SESSIONS`.
  // `agy_only_sessions` must skip untracked (no `was`) and already-v1 (`!needs_timing`) files before entering `read_file`.
  assert.equal(await runOnce(undefined, t0 - TIMED_BACK_MS), 0, "timeFrom agy-only startup reads 0 calls");
  for (const [label, s] of [["mb", mbStore], ["ts", tsStore]] as const) {
    assert.equal((s.db.prepare("SELECT COUNT(*) AS n FROM usage_files WHERE path IN (?, ?)").get(upPath, uaPath) as { n: number }).n, 0, `${label}: untracked plain+archived agy have no usage_files rows`);
    assert.equal((s.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE id IN ('agy:r-up-old', 'agy:r-ua-old', 'agy:r-v1-appended')").get() as { n: number }).n, 0, `${label}: no untracked or v1-appended usage recorded`);
    assert.equal((s.db.prepare("SELECT offset FROM usage_files WHERE path = ?").get(v1Path) as { offset: number }).offset, v1OffsetBefore, `${label}: upgraded v1 file offset untouched by timeFrom`);
  }

  // Normal recent read (e.g. a new turn ending after through) MUST still read the appended usage from the v1 file.
  await time.adjust(t0 + 130_000);
  each((s) => {
    s.startTurnFor("t-v1-2", "upgraded-v1", "input", { profile: "ag", person: "a@x", thread: null });
    s.endTurn("t-v1-2", "completed", null, null, null);
  });
  assert.equal(await runOnce(undefined, t0 - TIMED_BACK_MS), 1, "normal recent read still picks up appended v1 usage");
  for (const [label, s] of [["mb", mbStore], ["ts", tsStore]] as const) {
    assert.equal((s.db.prepare("SELECT gen_ms FROM usage WHERE id = 'agy:r-v1-appended'").get() as { gen_ms: number }).gen_ms, 2000, `${label}: normal recent read times appended v1 call`);
  }
});
