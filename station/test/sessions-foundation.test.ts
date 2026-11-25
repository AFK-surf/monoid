// Wave 8 W8-0 Foundation tests (100% event/promise-driven, zero `setTimeout` polling):
// - `config.readers.sessions` selection & `STILLFAIL_READER_SESSIONS` > `config` > `STILLFAIL_READER_ENGINE` > `mb`
// - MB + Pion dual-install cold-start pending buffering (`post`, `hold`, single spawn, ready telemetry)
// - Pion-only cold-start (`mbReaderBinary() === null`)
// - Old Pion without `sessions` in `--version` `modes:` falls back to MB and records fallback exactly once
// - `STILLFAIL_REQUIRE_PION_SESSIONS=1` refuses both sync fallback and async cold-probe old capability set (0 MB spawns, `user.exited(1)`)
// - Concurrent two users on same `data` (actor+agent sharing vs dual-actor hub isolation with two distinct ready PIDs)
// - `release()` during pending probe aborts cleanly with 0 spawned processes
// - Real built `stillfail-pion --sessions 1 --data <tmp>` walking skeleton handshake (`ready`, `db:null`, `quiet`, EOF 0)
// - Shared `pion-sqlite-tx-scanner.ts` concatenated raw-tx SQL detection & missing-directory throw
import assert from "node:assert/strict";
import { spawn, type ChildProcessByStdio } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Readable, Writable } from "node:stream";
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
import { findRawTxControlViolations, scanPionDirForRawTxControl } from "./pion-sqlite-tx-scanner.ts";

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

/// Event-driven line reader over a child stdout stream (zero `setTimeout` polling).
function createLineReader(child: ChildProcessByStdio<Writable, Readable, Readable>) {
  let carry = "";
  const lines: string[] = [];
  const waiters: Array<(line: string) => void> = [];
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk: string) => {
    carry += chunk;
    for (let idx = carry.indexOf("\n"); idx >= 0; idx = carry.indexOf("\n")) {
      const line = carry.slice(0, idx);
      carry = carry.slice(idx + 1);
      const next = waiters.shift();
      if (next) next(line);
      else lines.push(line);
    }
  });
  return {
    nextLine(): Promise<string> {
      const existing = lines.shift();
      if (existing !== undefined) return Promise.resolve(existing);
      return new Promise((res) => waiters.push(res));
    },
  };
}

/// Event-driven `ProgramUser` with promise-based `waitSaid` and `waitExited` (zero `setTimeout`).
function createUser(actors: boolean) {
  const messages: any[] = [];
  const saidWaiters: Array<{ pred: (m: any) => boolean; resolve: (m: any) => void }> = [];
  let exitedCode: number | null = null;
  const exitWaiters: Array<(code: number) => void> = [];
  const user: ProgramUser = {
    actors,
    said(m) {
      messages.push(m);
      for (let i = saidWaiters.length - 1; i >= 0; i--) {
        if (saidWaiters[i]!.pred(m)) {
          const w = saidWaiters.splice(i, 1)[0]!;
          w.resolve(m);
        }
      }
    },
    exited(code) {
      exitedCode = code;
      while (exitWaiters.length > 0) exitWaiters.shift()!(code);
    },
  };
  return {
    user,
    messages,
    waitSaid(pred: (m: any) => boolean): Promise<any> {
      const hit = messages.find(pred);
      if (hit !== undefined) return Promise.resolve(hit);
      return new Promise((resolve) => saidWaiters.push({ pred, resolve }));
    },
    waitExited(): Promise<number> {
      if (exitedCode !== null) return Promise.resolve(exitedCode);
      return new Promise((resolve) => exitWaiters.push(resolve));
    },
  };
}

/// Event-driven spawn observer with promise-based `waitCount` (zero `setTimeout`).
function createSpawnTracker() {
  const events: SessionsSpawnEvent[] = [];
  const waiters: Array<{ pred: (evs: SessionsSpawnEvent[]) => boolean; resolve: () => void }> = [];
  setSessionsSpawnObserverForTest((ev) => {
    events.push(ev);
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i]!.pred(events)) {
        waiters.splice(i, 1)[0]!.resolve();
      }
    }
  });
  return {
    events,
    waitUntil(pred: (evs: SessionsSpawnEvent[]) => boolean): Promise<void> {
      if (pred(events)) return Promise.resolve();
      return new Promise((resolve) => waiters.push({ pred, resolve }));
    },
  };
}

test("W8-0: pion-sqlite-tx-scanner catches concatenated raw tx SQL and throws on missing dir", () => {
  const concatHits = findRawTxControlViolations("concat.pion", 'let _ = tx_db.exec("ROLL" + "BACK")');
  assert.equal(concatHits.length, 1, `expected concatenated ROLLBACK violation, got: ${concatHits.join("; ")}`);
  const multilineHits = findRawTxControlViolations("multiline.pion", 'let _ = tx_db.exec("COM" +\n  "MIT")');
  assert.equal(multilineHits.length, 1, `expected multiline COMMIT violation, got: ${multilineHits.join("; ")}`);
  assert.throws(
    () => scanPionDirForRawTxControl(join(tmpdir(), "definitely-nonexistent-pion-dir-w8-0")),
    /does not exist/,
  );
});

test("W8-0: STILLFAIL_REQUIRE_PION_SESSIONS=1 throws when Pion is unimplemented, fallback, or missing", () => {
  resetReaderSelectionStateForTest();
  const data = makeTmp("sf-w8-req-");
  assert.throws(
    () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "pion" } }),
    /STILLFAIL_REQUIRE_PION_SESSIONS=1/,
  );
  assert.throws(
    () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "mb" }, pionImplemented: true }),
    /STILLFAIL_REQUIRE_PION_SESSIONS=1/,
  );
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

const requireDualReader = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";

function requirePionOrSkip(t: { skip(msg?: string): void }): string | null {
  const pion = pionBinary();
  if (pion === null) {
    if (requireDualReader) {
      assert.fail("STILLFAIL_REQUIRE_DUAL_READER=1 requires stillfail-pion binary (STILLFAIL_PION_READER)");
    }
    t.skip("stillfail-pion binary not built");
    return null;
  }
  if (requireDualReader && mbReaderBinary() === null) {
    assert.fail("STILLFAIL_REQUIRE_DUAL_READER=1 requires MoonBit stillfail-reader binary (STILLFAIL_MB_READER)");
  }
  return pion;
}

test("W8-0: real stillfail-pion --sessions walking skeleton handshake (ready, db:null zero stderr, quiet, EOF 0)", async (t) => {
  const pion = requirePionOrSkip(t);
  if (pion === null) return;
  const data = makeTmp("sf-w8-skel-");
  const child = spawn(pion, ["--sessions", "1", "--data", data, "--sep", "/"], { stdio: ["pipe", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (chunk: string) => { stderr += chunk; });

  const reader = createLineReader(child);
  const exited = new Promise<number | null>((res) => child.once("close", (code) => res(code)));

  const firstLine = await reader.nextLine();
  const readyMsg = JSON.parse(firstLine);
  assert.deepStrictEqual(readyMsg, { ready: true });
  assert.equal("active" in readyMsg, false);
  assert.equal("seen" in readyMsg, false);

  child.stdin.write('{"db":null}\n');
  const secondLine = await reader.nextLine();
  assert.deepStrictEqual(JSON.parse(secondLine), { quiet: true, active: 0, seen: 1 });

  child.stdin.end();
  const code = await exited;
  assert.equal(code, 0);
  assert.equal(stderr, "");
});

test("W8-0: config.readers.sessions, env precedence, pending cold starts, dual-hub isolation, and require-pion async refusal", async (t) => {
  const pion = requirePionOrSkip(t);
  if (pion === null) return;

  const restoreImpl = setReaderModeImplementedForTest("sessions", true);
  try {
    // 1. MB+Pion dual-install pending cold start via config.readers.sessions
    resetReaderSelectionStateForTest();
    readerTelemetry.resetForTest();
    const tracker1 = createSpawnTracker();

    let resolveProbe1!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbe1 = r; }));

    const data1 = makeTmp("sf-w8-dual-");
    const unregister1 = registerSessionsReaderConfig(data1, () => ({ readers: { sessions: "pion" } }));
    const u1 = createUser(true);
    const prog1 = SessionsProgram.of(data1, true)!;
    assert.ok(prog1 !== null);
    prog1.use(u1.user);
    prog1.hold(u1.user, true);
    prog1.post({ db: null });
    assert.equal(tracker1.events.length, 0, "must not spawn before pending probe resolves");

    resolveProbe1(new Set(["footprint", "packed", "memory", "sessions"]));
    await u1.waitSaid((m) => m.quiet === true);
    assert.equal(tracker1.events.filter((e) => !e.ready).length, 1);
    assert.equal(tracker1.events.filter((e) => e.ready).length, 1);
    assert.equal(tracker1.events[0]!.engine, "pion");
    assert.equal(tracker1.events[0]!.fallback, false);
    assert.ok(tracker1.events[0]!.pid !== null && tracker1.events[0]!.pid > 0);
    await prog1.release(u1.user);
    unregister1();

    // 2. Pion-only cold start (`mbReaderBinary() === null`)
    resetReaderSelectionStateForTest();
    setMbReaderBinaryOverrideForTest(() => null);
    let resolveProbe2!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbe2 = r; }));
    const tracker2 = createSpawnTracker();

    const data2 = makeTmp("sf-w8-piononly-");
    const unregister2 = registerSessionsReaderConfig(data2, () => ({ readers: { sessions: "pion" } }));
    assert.equal(sessionsBinaryAvailable(data2), true);
    const u2 = createUser(true);
    const prog2 = SessionsProgram.of(data2, true)!;
    assert.ok(prog2 !== null);
    prog2.use(u2.user);
    prog2.post({ db: null });
    resolveProbe2(new Set(["footprint", "packed", "memory", "sessions"]));
    await u2.waitSaid((m) => m.quiet === true);
    assert.equal(tracker2.events.filter((e) => e.ready && e.engine === "pion").length, 1);
    await prog2.release(u2.user);
    unregister2();

    // 3. Release during pending probe -> 0 processes spawned (promise-driven, zero setTimeout)
    resetReaderSelectionStateForTest();
    let resolveProbe3!: (modes: ReadonlySet<string> | null) => void;
    const probePromise3 = new Promise<ReadonlySet<string> | null>((r) => { resolveProbe3 = r; });
    setPionProbeRunnerForTest(() => probePromise3);
    const tracker3 = createSpawnTracker();

    const data3 = makeTmp("sf-w8-relpend-");
    const unregister3 = registerSessionsReaderConfig(data3, () => ({ readers: { sessions: "pion" } }));
    const u3 = createUser(true);
    const prog3 = SessionsProgram.of(data3, true)!;
    prog3.use(u3.user);
    prog3.post({ db: null });
    await prog3.release(u3.user);
    resolveProbe3(new Set(["footprint", "packed", "memory", "sessions"]));
    await probePromise3;
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(tracker3.events.length, 0, "released pending SessionsProgram must spawn 0 processes");
    unregister3();

    // 4. STILLFAIL_REQUIRE_PION_SESSIONS=1 async cold probe returning old capability set -> refuses fallback, 0 MB spawns, notifies user.exited(1)
    resetReaderSelectionStateForTest();
    let resolveProbeReq!: (modes: ReadonlySet<string> | null) => void;
    setPionProbeRunnerForTest(() => new Promise((r) => { resolveProbeReq = r; }));
    const trackerReq = createSpawnTracker();
    const dataReq = makeTmp("sf-w8-req-async-");
    const uReq = createUser(true);
    const progReq = SessionsProgram.of(dataReq, true, {
      env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "pion" },
      pionImplemented: true,
    })!;
    progReq.use(uReq.user);
    resolveProbeReq(new Set(["footprint", "packed", "memory"]));
    const exitCodeReq = await uReq.waitExited();
    assert.equal(exitCodeReq, 1, "async old-capability refusal must notify user.exited(1)");
    assert.equal(trackerReq.events.length, 0, "STILLFAIL_REQUIRE_PION_SESSIONS=1 must spawn 0 MB fallback processes");
    assert.equal(progReq.ended, true);

    // 5. Concurrent sharing (actor + agent share 1 process) vs dual-actor isolation (2 distinct ready PIDs)
    resetReaderSelectionStateForTest();
    setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory", "sessions"]));
    const tracker4 = createSpawnTracker();
    const data4 = makeTmp("sf-w8-share-");
    const unregister4 = registerSessionsReaderConfig(data4, () => ({ readers: { sessions: "pion" } }));
    const uActor1 = createUser(true);
    const uAgent1 = createUser(false);
    const uActor2 = createUser(true);
    const pA1 = SessionsProgram.of(data4, true)!;
    pA1.use(uActor1.user);
    const pAg = SessionsProgram.of(data4, false)!;
    assert.equal(pAg, pA1, "actor and agent on same data share one SessionsProgram");
    pAg.use(uAgent1.user);
    const pA2 = SessionsProgram.of(data4, true)!;
    assert.notEqual(pA2, pA1, "second actors hub on same data gets an isolated SessionsProgram");
    pA2.use(uActor2.user);
    await tracker4.waitUntil((evs) => evs.filter((e) => e.ready).length === 2);
    const readyEvs = tracker4.events.filter((e) => e.ready);
    assert.equal(readyEvs.length, 2);
    assert.ok(readyEvs[0]!.pid !== null && readyEvs[0]!.pid > 0);
    assert.ok(readyEvs[1]!.pid !== null && readyEvs[1]!.pid > 0);
    assert.notEqual(readyEvs[0]!.pid, readyEvs[1]!.pid, "two isolated hubs must run in two distinct child PIDs");
    await pA1.release(uActor1.user);
    await pAg.release(uAgent1.user);
    await pA2.release(uActor2.user);
    unregister4();

    // 6. Old Pion without "sessions" falls back to MB and records fallback exactly once
    if (mbReaderBinary() !== null) {
      resetReaderSelectionStateForTest();
      readerTelemetry.resetForTest();
      setPionProbeRunnerForTest(async () => new Set(["footprint", "packed", "memory"]));
      const tracker5 = createSpawnTracker();

      const data5 = makeTmp("sf-w8-oldpion-");
      const u5 = createUser(true);
      const prog5 = SessionsProgram.of(data5, true, {
        env: { STILLFAIL_READER_SESSIONS: "pion" },
        pionImplemented: true,
      })!;
      prog5.use(u5.user);
      prog5.post({ db: null });
      await u5.waitSaid((m) => m.quiet === true);
      assert.equal(tracker5.events.filter((e) => !e.ready).length, 1);
      assert.equal(tracker5.events[0]!.engine, "mb");
      assert.equal(tracker5.events[0]!.fallback, true);
      const summaries = readerTelemetry.flushWindow();
      const pionSessions = summaries.find((s) => s.engine === "pion" && s.mode === "sessions");
      assert.equal(pionSessions?.fallbacks, 1, "unsupported-mode fallback must be recorded exactly once");
      await prog5.release(u5.user);
    }

    // 7. Env precedence: STILLFAIL_READER_SESSIONS=mb overrides config.readers.sessions=pion
    if (mbReaderBinary() !== null) {
      resetReaderSelectionStateForTest();
      const tracker6 = createSpawnTracker();
      const data6 = makeTmp("sf-w8-prec-");
      const u6 = createUser(true);
      const prog6 = SessionsProgram.of(data6, true, {
        config: { readers: { sessions: "pion" } },
        env: { STILLFAIL_READER_SESSIONS: "mb", STILLFAIL_READER_ENGINE: "pion" },
        pionImplemented: true,
      })!;
      prog6.use(u6.user);
      prog6.post({ db: null });
      await u6.waitSaid((m) => m.quiet === true);
      assert.equal(tracker6.events[0]!.engine, "mb");
      assert.equal(tracker6.events[0]!.fallback, false);
      await prog6.release(u6.user);
    }
    // 8. Pending kill() + synchronous release(u1): 0 sync callbacks, microtask notifies only still-subscribed u2, 0 spawns
    resetReaderSelectionStateForTest();
    let resolveProbeKill!: (modes: ReadonlySet<string> | null) => void;
    const probePromiseKill = new Promise<ReadonlySet<string> | null>((r) => { resolveProbeKill = r; });
    setPionProbeRunnerForTest(() => probePromiseKill);
    const trackerKill = createSpawnTracker();
    const dataKill = makeTmp("sf-w8-killpend-");
    const unregisterKill = registerSessionsReaderConfig(dataKill, () => ({ readers: { sessions: "pion" } }));
    let u1Exited = 0;
    let u2Exited = 0;
    let u2Code: number | null = null;
    const u1Kill: ProgramUser = { actors: true, said: () => {}, exited: () => { u1Exited++; } };
    const u2Kill: ProgramUser = { actors: false, said: () => {}, exited: (code) => { u2Exited++; u2Code = code; } };
    const progKill = SessionsProgram.of(dataKill, true)!;
    progKill.use(u1Kill);
    progKill.use(u2Kill);
    progKill.kill();
    void progKill.release(u1Kill);
    // Synchronously 0 exit callbacks (deferred via queueMicrotask so process.on("exit") does not trigger process.exit(70)).
    assert.equal(u1Exited, 0, "u1 must not be notified synchronously");
    assert.equal(u2Exited, 0, "u2 must not be notified synchronously");
    await Promise.resolve();
    assert.equal(u1Exited, 0, "released u1 must receive 0 exited callbacks after microtask");
    assert.equal(u2Exited, 1, "still-subscribed u2 must receive exactly 1 exited callback after microtask");
    assert.equal(u2Code, 1);
    resolveProbeKill(new Set(["footprint", "packed", "memory", "sessions"]));
    await probePromiseKill;
    await Promise.resolve();
    assert.equal(trackerKill.events.length, 0, "killed pending SessionsProgram must spawn 0 processes");
    unregisterKill();
  } finally {
    restoreImpl();
    setSessionsSpawnObserverForTest(null);
    resetReaderSelectionStateForTest();
  }
});
