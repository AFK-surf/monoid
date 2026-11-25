// Wave 8 W8-0 Foundation tests:
// - `config.readers.sessions` selection & `STILLFAIL_READER_SESSIONS` > `config` > `STILLFAIL_READER_ENGINE` > `mb`
// - MB + Pion dual-install cold-start pending buffering (`post`, `hold`, single spawn, ready telemetry)
// - Pion-only cold-start (`mbReaderBinary() === null`)
// - Old Pion without `sessions` in `--version` `modes:` falls back to MB and records fallback exactly once
// - Concurrent two users on same `data` (actor+agent sharing vs dual-actor hub isolation)
// - `release()` during pending probe aborts cleanly with 0 spawned processes
// - `STILLFAIL_REQUIRE_PION_SESSIONS=1` throws on fallback / non-Pion / missing binary
// - Real built `stillfail-pion --sessions 1 --data <tmp>` walking skeleton handshake (`ready`, `db:null`, `quiet`, EOF 0)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import {
  SessionsProgram,
  type ProgramUser,
  type SessionsSpawnEvent,
  registerSessionsReaderConfig,
  sessionsBinaryAvailable,
  setSessionsSpawnObserverForTest,
} from "../src/agents/mb-program.ts";
import {
  mbReaderBinary,
  pionBinary,
  resetReaderSelectionStateForTest,
  setMbReaderBinaryOverrideForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { setReaderModeImplementedForTest } from "../src/read/reader-select.ts";
import { readerTelemetry } from "../src/read/reader-telemetry.ts";

const tempDirs: string[] = [];
function makeTmp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

after(() => {
  setSessionsSpawnObserverForTest(null);
  resetReaderSelectionStateForTest();
  for (const d of tempDirs) {
    try { rmSync(d, { recursive: true, force: true }); } catch {}
  }
});

function waitFor<T>(fn: () => T | undefined, timeoutMs = 5_000): Promise<T> {
  return new Promise((resolveWait, rejectWait) => {
    const start = Date.now();
    const check = () => {
      const v = fn();
      if (v !== undefined) return resolveWait(v);
      if (Date.now() - start > timeoutMs) return rejectWait(new Error("timed out waiting for condition"));
      setTimeout(check, 10);
    };
    check();
  });
}

test("W8-0: STILLFAIL_REQUIRE_PION_SESSIONS=1 throws when Pion is unimplemented, fallback, or missing", () => {
  resetReaderSelectionStateForTest();
  const data = makeTmp("sf-w8-req-");
  // Default `pionImplemented` is false in W8-0 -> MUST throw under STILLFAIL_REQUIRE_PION_SESSIONS=1
  assert.throws(
    () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "pion" } }),
    /STILLFAIL_REQUIRE_PION_SESSIONS=1/,
  );
  // Explicitly requesting "mb" -> MUST throw under STILLFAIL_REQUIRE_PION_SESSIONS=1
  assert.throws(
    () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "mb" }, pionImplemented: true }),
    /STILLFAIL_REQUIRE_PION_SESSIONS=1/,
  );
  // Missing Pion binary -> MUST throw under STILLFAIL_REQUIRE_PION_SESSIONS=1
  const prevPionEnv = process.env.STILLFAIL_PION_READER;
  try {
    process.env.STILLFAIL_PION_READER = join(data, "does-not-exist-pion");
    resetReaderSelectionStateForTest();
    assert.throws(
      () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "pion" }, pionImplemented: true }),
      /STILLFAIL_REQUIRE_PION_SESSIONS=1/,
    );
  } finally {
    if (prevPionEnv === undefined) delete process.env.STILLFAIL_PION_READER;
    else process.env.STILLFAIL_PION_READER = prevPionEnv;
    resetReaderSelectionStateForTest();
  }
});

test("W8-0: real stillfail-pion --sessions walking skeleton handshake (ready, db:null zero stderr, quiet, EOF 0)", async (t) => {
  const pion = pionBinary();
  if (pion === null) {
    t.skip("stillfail-pion binary not built");
    return;
  }
  const data = makeTmp("sf-w8-skel-");
  const child = spawn(pion, ["--sessions", "1", "--data", data, "--sep", "/"], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.on("data", (chunk: string) => { stderr += chunk; });

  const exited = new Promise<number | null>((res) => child.once("close", (code) => res(code)));
  await waitFor(() => stdout.includes("\n") ? true : undefined);
  const firstLine = stdout.split("\n")[0]!;
  const readyMsg = JSON.parse(firstLine);
  assert.deepStrictEqual(readyMsg, { ready: true });
  assert.equal("active" in readyMsg, false);
  assert.equal("seen" in readyMsg, false);

  child.stdin.write('{"db":null}\n');
  await waitFor(() => stdout.split("\n").filter((l) => l.length > 0).length >= 2 ? true : undefined);
  const secondLine = stdout.split("\n").filter((l) => l.length > 0)[1]!;
  assert.deepStrictEqual(JSON.parse(secondLine), { quiet: true, active: 0, seen: 1 });

  child.stdin.end();
  const code = await exited;
  assert.equal(code, 0);
  assert.equal(stderr, "");
});

test("W8-0: config.readers.sessions, env precedence, MB+Pion pending cold start, Pion-only cold start, and release-during-pending", async (t) => {
  const pion = pionBinary();
  if (pion === null) {
    t.skip("stillfail-pion binary not built");
    return;
  }

  const restoreImpl = setReaderModeImplementedForTest("sessions", true);
  try {
    // 1. MB+Pion dual-install pending cold start via config.readers.sessions
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    const events1: SessionsSpawnEvent[] = [];
    setSessionsSpawnObserverForTest((ev) => events1.push(ev));

    let resolveProbe1!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbe1 = r; }));

    const data1 = makeTmp("sf-w8-dual-");
    const unregister1 = registerSessionsReaderConfig(data1, () => ({ readers: { sessions: "pion" } }));
    const received1: any[] = [];
    const user1: ProgramUser = { actors: true, said: (m) => received1.push(m), exited: () => {} };
    const prog1 = SessionsProgram.of(data1, true)!;
    assert.ok(prog1 !== null);
    prog1.use(user1);
    prog1.hold(user1, true);
    // Buffer a message BEFORE the probe resolves
    prog1.post({ db: null });
    assert.equal(events1.length, 0, "must not spawn before pending probe resolves");

    // Resolve probe advertising "sessions" -> single Pion spawn, buffered message flushed
    resolveProbe1(new Set(["footprint", "packed", "memory", "sessions"]));
    await waitFor(() => received1.find((m) => m.quiet === true));
    assert.equal(events1.filter((e) => !e.ready).length, 1);
    assert.equal(events1.filter((e) => e.ready).length, 1);
    assert.equal(events1[0]!.engine, "pion");
    assert.equal(events1[0]!.fallback, false);
    assert.ok(events1[0]!.pid !== null && events1[0]!.pid > 0);
    await prog1.release(user1);
    unregister1();

    // 2. Pion-only cold start (`mbReaderBinary() === null`)
    resetReaderSelectionStateForTest();
    setMbReaderBinaryOverrideForTest(() => null);
    let resolveProbe2!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbe2 = r; }));
    const events2: SessionsSpawnEvent[] = [];
    setSessionsSpawnObserverForTest((ev) => events2.push(ev));

    const data2 = makeTmp("sf-w8-piononly-");
    const unregister2 = registerSessionsReaderConfig(data2, () => ({ readers: { sessions: "pion" } }));
    assert.equal(sessionsBinaryAvailable(data2), true);
    const received2: any[] = [];
    const user2: ProgramUser = { actors: true, said: (m) => received2.push(m), exited: () => {} };
    const prog2 = SessionsProgram.of(data2, true)!;
    assert.ok(prog2 !== null);
    prog2.use(user2);
    prog2.post({ db: null });
    resolveProbe2(new Set(["footprint", "packed", "memory", "sessions"]));
    await waitFor(() => received2.find((m) => m.quiet === true));
    assert.equal(events2.filter((e) => e.ready && e.engine === "pion").length, 1);
    await prog2.release(user2);
    unregister2();

    // 3. Release during pending probe -> 0 processes spawned
    resetReaderSelectionStateForTest();
    let resolveProbe3!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbe3 = r; }));
    const events3: SessionsSpawnEvent[] = [];
    setSessionsSpawnObserverForTest((ev) => events3.push(ev));

    const data3 = makeTmp("sf-w8-relpend-");
    const unregister3 = registerSessionsReaderConfig(data3, () => ({ readers: { sessions: "pion" } }));
    const user3: ProgramUser = { actors: true, said: () => {}, exited: () => {} };
    const prog3 = SessionsProgram.of(data3, true)!;
    prog3.use(user3);
    prog3.post({ db: null });
    await prog3.release(user3);
    resolveProbe3(new Set(["footprint", "packed", "memory", "sessions"]));
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(events3.length, 0, "released pending SessionsProgram must spawn 0 processes");
    unregister3();

    // 4. Concurrent sharing (actor + agent share 1 process) vs dual-actor isolation (2 processes)
    resetReaderSelectionStateForTest();
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory", "sessions"]));
    const data4 = makeTmp("sf-w8-share-");
    const unregister4 = registerSessionsReaderConfig(data4, () => ({ readers: { sessions: "pion" } }));
    const uActor1: ProgramUser = { actors: true, said: () => {}, exited: () => {} };
    const uAgent1: ProgramUser = { actors: false, said: () => {}, exited: () => {} };
    const uActor2: ProgramUser = { actors: true, said: () => {}, exited: () => {} };
    const pA1 = SessionsProgram.of(data4, true)!;
    pA1.use(uActor1);
    const pAg = SessionsProgram.of(data4, false)!;
    assert.equal(pAg, pA1, "actor and agent on same data share one SessionsProgram");
    pAg.use(uAgent1);
    const pA2 = SessionsProgram.of(data4, true)!;
    assert.notEqual(pA2, pA1, "second actors hub on same data gets an isolated SessionsProgram");
    pA2.use(uActor2);
    await pA1.release(uActor1);
    await pAg.release(uAgent1);
    await pA2.release(uActor2);
    unregister4();

    // 5. Old Pion without "sessions" falls back to MB and records fallback exactly once
    if (mbReaderBinary() !== null) {
      resetReaderSelectionStateForTest();
      readerTelemetry.resetForTest();
      setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory"]));
      const events5: SessionsSpawnEvent[] = [];
      setSessionsSpawnObserverForTest((ev) => events5.push(ev));

      const data5 = makeTmp("sf-w8-oldpion-");
      const received5: any[] = [];
      const user5: ProgramUser = { actors: true, said: (m) => received5.push(m), exited: () => {} };
      const prog5 = SessionsProgram.of(data5, true, {
        env: { STILLFAIL_READER_SESSIONS: "pion" },
        pionImplemented: true,
      })!;
      prog5.use(user5);
      prog5.post({ db: null });
      await waitFor(() => received5.find((m) => m.quiet === true));
      assert.equal(events5.filter((e) => !e.ready).length, 1);
      assert.equal(events5[0]!.engine, "mb");
      assert.equal(events5[0]!.fallback, true);
      const summaries = readerTelemetry.flushWindow();
      const pionSessions = summaries.find((s) => s.engine === "pion" && s.mode === "sessions");
      assert.equal(pionSessions?.fallbacks, 1, "unsupported-mode fallback must be recorded exactly once");
      await prog5.release(user5);
    }

    // 6. Env precedence: STILLFAIL_READER_SESSIONS=mb overrides config.readers.sessions=pion
    if (mbReaderBinary() !== null) {
      resetReaderSelectionStateForTest();
      const events6: SessionsSpawnEvent[] = [];
      setSessionsSpawnObserverForTest((ev) => events6.push(ev));
      const data6 = makeTmp("sf-w8-prec-");
      const received6: any[] = [];
      const user6: ProgramUser = { actors: true, said: (m) => received6.push(m), exited: () => {} };
      const prog6 = SessionsProgram.of(data6, true, {
        config: { readers: { sessions: "pion" } },
        env: { STILLFAIL_READER_SESSIONS: "mb", STILLFAIL_READER_ENGINE: "pion" },
        pionImplemented: true,
      })!;
      prog6.use(user6);
      prog6.post({ db: null });
      await waitFor(() => received6.find((m) => m.quiet === true));
      assert.equal(events6[0]!.engine, "mb");
      assert.equal(events6[0]!.fallback, false);
      await prog6.release(user6);
    }
  } finally {
    restoreImpl();
    setSessionsSpawnObserverForTest(null);
    resetReaderSelectionStateForTest();
  }
});
