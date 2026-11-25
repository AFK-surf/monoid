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
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { Readable, Writable } from "node:stream";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
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
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  setMbReaderBinaryOverrideForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { setReaderModeImplementedForTest } from "../src/read/reader-select.ts";
import { readerTelemetry } from "../src/read/reader-telemetry.ts";
import { ActorsProgram } from "../src/sessions/mb-actor.ts";
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
  assert.equal(
    findRawTxControlViolations("method.pion", 'if method == "release" || method == "savepoint" { () }').length,
    0,
    "standalone release/savepoint method names without a following identifier must not false-positive",
  );
  for (const op of ["SAVEPOINT", "RELEASE"]) {
    const source = `let _ = db.exec("${op} " + name)`;
    assert.equal(
      findRawTxControlViolations("dynamic.pion", source).length,
      1,
      `dynamic ${op} concatenation must be caught`,
    );
  }
  assert.equal(
    findRawTxControlViolations("interp.pion", 'let _ = db.exec("RELEASE \\{n}")').length,
    1,
    "RELEASE with Pion string interpolation must be caught",
  );
  assert.equal(
    findRawTxControlViolations("assign.pion", 'let op = "RELEASE"').length,
    1,
    "uppercase RELEASE assignment must be caught",
  );
  assert.equal(
    findRawTxControlViolations("multiline_rel.pion", 'let _ = db.exec("RELEASE"\n  + sp)').length,
    1,
    "multiline RELEASE + sp concatenation must be caught",
  );
  assert.equal(
    findRawTxControlViolations("sp1.pion", 'let _ = db.exec("RELEASE sp1")').length,
    1,
    "RELEASE <ident> must be caught",
  );
  assert.equal(
    findRawTxControlViolations("sp2.pion", 'let _ = db.exec("RELEASE \\"sp1\\"")').length,
    1,
    "RELEASE with double-quoted identifier must be caught",
  );
  assert.equal(
    findRawTxControlViolations("sp3.pion", 'let _ = db.exec("RELEASE [sp1]")').length,
    1,
    "RELEASE with bracketed identifier must be caught",
  );
  assert.equal(
    findRawTxControlViolations("sp4.pion", 'let _ = db.exec("SAVEPOINT sp1")').length,
    1,
    "SAVEPOINT <ident> must be caught",
  );
  assert.throws(
    () => scanPionDirForRawTxControl(join(tmpdir(), "definitely-nonexistent-pion-dir-w8-0")),
    /does not exist/,
  );

  // W8-F: scan real `sessions_actors/src` + negative mutation check on a real copied file.
  const actorsSrcDir = resolve(fileURLToPath(new URL("../../pion/station/packages/sessions_actors/src", import.meta.url)));
  assert.deepEqual(scanPionDirForRawTxControl(actorsSrcDir), []);
  const mutDir = makeTmp("sf-w8-tx-mut-");
  const realStore = readFileSync(join(actorsSrcDir, "actor_store.pion"), "utf8");
  writeFileSync(join(mutDir, "actor_store.pion"), realStore + '\nlet _ = db.exec("BEGIN IMMEDIATE")\n', "utf8");
  assert.ok(scanPionDirForRawTxControl(mutDir).length >= 1, "mutated actor_store.pion with raw BEGIN IMMEDIATE must be caught");
});

test("W8-0: STILLFAIL_REQUIRE_PION_SESSIONS=1 throws when Pion is unimplemented, fallback, or missing", () => {
  resetReaderSelectionStateForTest();
  const data = makeTmp("sf-w8-req-");
  assert.throws(
    () => SessionsProgram.of(data, true, { env: { STILLFAIL_REQUIRE_PION_SESSIONS: "1", STILLFAIL_READER_SESSIONS: "pion" }, pionImplemented: false }),
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

test("W8-E2: ActorsProgram routes cleanup RPCs to retired actor after forget() and drops non-cleanup RPCs", async () => {
  let user: { said: (msg: any) => void; exited: (code: number) => void } | null = null;
  const posted: any[] = [];
  const stubProc = {
    use(u: any) { user = u; },
    post(msg: any) { posted.push(msg); return true; },
    hold() {},
    release() {},
    kill() {},
  };
  const fakeClock = { currentTimeMillisUnsafe: () => 1000 } as any;
  const program = ActorsProgram.openForTest(stubProc as any, fakeClock);
  const calls: Array<{ fn: string; args: any[] }> = [];
  const tells: Array<{ fn: string; args: any[] }> = [];
  const shell = {
    key: "retired-sess",
    runtime: "claude" as const,
    asked: async (fn: string, args: any[]) => {
      calls.push({ fn, args });
      if (fn === "agent.steer") return false;
      return { ok: fn };
    },
    told: (fn: string, args: any[]) => {
      tells.push({ fn, args });
    },
  };
  program.shell(shell);

  // Retire the actor via forget() — simulating close() removing it from #actors.
  program.forget("retired-sess", shell);

  // 1. Cleanup RPCs (store.markUndelivered, agent.dispose, agent.steer) must still route and answer.
  user!.said({ rpc: 101, actor: "retired-sess", fn: "store.markUndelivered", args: [["m1"]] });
  user!.said({ rpc: 102, actor: "retired-sess", fn: "agent.dispose", args: [7] });
  user!.said({ rpc: 103, actor: "retired-sess", fn: "agent.steer", args: [7, "hi"] });
  // 2. Non-cleanup RPCs get an explicit terminal error reply (never dropped) and tells are ignored.
  user!.said({ rpc: 104, actor: "retired-sess", fn: "agent.prompt", args: [7, "nope"] });
  user!.said({ tell: "notify", actor: "retired-sess", args: ["nope"] });

  await new Promise((r) => setImmediate(r));

  assert.deepEqual(
    calls.map((c) => c.fn),
    ["store.markUndelivered", "agent.dispose", "agent.steer"],
    "only cleanup RPCs should be routed to retired actor after forget()",
  );
  assert.equal(tells.length, 0, "tells must not be routed to retired actor after forget()");

  const answers = posted.filter((m) => typeof m.answer === "number");
  assert.equal(answers.length, 4, "all 3 cleanup RPCs + 1 closed-actor RPC must receive a terminal answer reply");
  assert.deepEqual(
    answers.map((a) => [a.answer, a.value ?? null, a.error?.actorClosed === true]),
    [
      [104, null, true],
      [101, { ok: "store.markUndelivered" }, false],
      [102, { ok: "agent.dispose" }, false],
      [103, false, false],
    ],
  );

  // 3. Re-registering the same key routes normally again.
  const calls2: string[] = [];
  program.shell({
    key: "retired-sess",
    runtime: "claude",
    asked: async (fn: string) => {
      calls2.push(fn);
      return true;
    },
    told: () => {},
  });
  user!.said({ rpc: 105, actor: "retired-sess", fn: "agent.prompt", args: [8, "ok"] });
  await new Promise((r) => setImmediate(r));
  assert.deepEqual(calls2, ["agent.prompt"]);

  await program.close();
});

function r5RoutingFixture() {
  let receive!: (frame: any) => void;
  const posted: any[] = [];
  const program = ActorsProgram.openForTest(
    {
      use(user: any) { receive = user.said; },
      post(frame: any) { posted.push(frame); return true; },
      hold() {},
      release() {},
      kill() {},
    } as any,
    { currentTimeMillisUnsafe: () => 1000 } as any,
  );
  const events: string[] = [];
  function register(key: string, label: string) {
    const store = {
      getSession() { return { runtime: "claude" }; },
      markUndelivered() { events.push(`${label}/undo`); },
      markDelivered() { events.push(`${label}/mark`); },
    };
    const actor = program.actor(key, "claude", { store } as any);
    const session = {
      steer() { events.push(`${label}/steer`); return false; },
      dispose() { events.push(`${label}/dispose`); },
      snapshot() { return null; },
      detach() {},
    };
    const ready = actor.adopt({ runtime: "claude" } as any, session as any, "");
    const adoption = posted.at(-1);
    assert.equal(adoption.method, "adopt");
    receive({ returned: adoption.call, value: null });
    return { actor, ready, handle: adoption.args[1].handle as number };
  }
  async function deliver(frame: any) {
    receive(frame);
    await new Promise((r) => setImmediate(r));
    return posted.find((x) => x.answer === frame.rpc);
  }
  return { program, events, register, deliver, posted };
}

test("W8-E2 R5: fallback cleanup after actual MbActor.close", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    old.actor.close();
    const reply = await f.deliver({ rpc: 101, actor: "s", fn: "store.markUndelivered", args: ["s", []] });
    assert.equal(reply?.answer, 101);
    assert.deepEqual(f.events, ["old/undo"]);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R5: late runtime cleanup retains original handle owner on same-key replacement", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    const lateFrame = { rpc: 102, actor: "s", fn: "agent.dispose", args: [old.handle] };
    old.actor.close();
    const current = f.register("s", "new");
    await current.ready;
    assert.notEqual(old.handle, current.handle, "handles must be globally unique across ActorsProgram");
    const reply = await f.deliver(lateFrame);
    assert.equal(reply?.answer, 102);
    assert.deepEqual(f.events, ["old/dispose"]);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R5: delayed cleanup still receives answer after 512 other actors retire", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    old.actor.close();
    for (let i = 0; i < 512; ++i) {
      const item = f.program.actor(`other${i}`, "claude", { store: {} } as any);
      item.close();
    }
    const reply = await f.deliver({ rpc: 103, actor: "s", fn: "store.markUndelivered", args: ["s", []] });
    assert.equal(reply?.answer, 103);
    assert.deepEqual(f.events, ["old/undo"]);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R5: markDelivered dispatched before close always gets a terminal reply", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    const lateFrame = { rpc: 104, actor: "s", fn: "store.markDelivered", args: ["s", []] };
    old.actor.close();
    const reply = await f.deliver(lateFrame);
    assert.equal(reply?.answer, 104);
    assert.equal(reply?.error?.actorClosed, true);
    assert.deepEqual(f.events, []);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R5: stateForTurn dispatched before close receives a terminal stateWrite reply", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    const saving = old.actor.stateForTurn("t1", { kind: "all_done" } as any, null, null);
    const request = f.posted.at(-1);
    assert.equal(request.method, "stateForTurn");
    old.actor.close();
    const reply = await f.deliver({ rpc: 105, actor: "s", fn: "node.stateWrite", args: request.args });
    assert.equal(reply?.answer, 105);
    await f.program.close();
    await saving;
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R6: pending stateWrite after replacement uses the original record", async () => {
  let receive!: (frame: any) => void;
  const frames: any[] = [];
  const program = ActorsProgram.openForTest(
    {
      use(user: any) { receive = user.said; },
      post(x: any) { frames.push(x); return true; },
      hold() {},
      release() {},
      kill() {},
    } as any,
    { currentTimeMillisUnsafe: () => 100 } as any,
  );
  const rows: any[] = [];
  const store = {
    getSession() { return { runtime: "claude" }; },
    setAbout() {},
    declareTurn() {},
    setNeed(id: string, words: string) { rows.push([id, words]); },
    markUndelivered() { rows.push(["undo"]); },
  };
  const answer = async (id: number) => {
    await new Promise((r) => setImmediate(r));
    const reply = frames.find((f) => f.answer === id);
    assert.ok(reply, "missing terminal answer");
    return reply;
  };
  try {
    const old = program.actor("s", "claude", { store } as any);
    const first = old.stateForTurn("old-turn", { kind: "need_human" } as any, "old words", null);
    const req = frames.at(-1);
    old.close();
    const current = program.actor("s", "claude", { store } as any);
    const second = current.stateForTurn("new-turn", { kind: "need_human" } as any, "new words", null);
    receive({ rpc: 201, actor: "s", fn: "node.stateWrite", args: req.args });
    const reply = await answer(201);
    assert.ok(!reply.error, JSON.stringify(reply));
    assert.deepEqual(rows, [["old-turn", "old words"]]);
    // Consumed token must fail explicitly if replayed instead of silently succeeding.
    receive({ rpc: 202, actor: "s", fn: "node.stateWrite", args: req.args });
    const replay = await answer(202);
    assert.ok(replay.error, "replayed stateWrite token must fail explicitly");
    await program.close();
    await Promise.all([first, second]);
  } finally {
    await program.close();
  }
});

test("W8-E2 R6: autonomous steer keeps its store cleanup available across negative receipt", async () => {
  let receive!: (frame: any) => void;
  const frames: any[] = [];
  const program = ActorsProgram.openForTest(
    {
      use(user: any) { receive = user.said; },
      post(x: any) { frames.push(x); return true; },
      hold() {},
      release() {},
      kill() {},
    } as any,
    { currentTimeMillisUnsafe: () => 100 } as any,
  );
  const rows: any[] = [];
  const store = {
    getSession() { return { runtime: "claude" }; },
    markUndelivered() { rows.push(["undo"]); },
  };
  const answer = async (id: number) => {
    await new Promise((r) => setImmediate(r));
    const reply = frames.find((f) => f.answer === id);
    assert.ok(reply, "missing terminal answer");
    return reply;
  };
  try {
    const old = program.actor("s", "claude", { store } as any);
    let rejectSteer!: () => void;
    const ready = old.adopt(
      { runtime: "claude" } as any,
      { steer: () => new Promise((resolve) => { rejectSteer = () => resolve(false); }) } as any,
      "",
    );
    const adopt = frames.at(-1);
    receive({ returned: adopt.call, value: null });
    await ready;
    receive({ rpc: 210, actor: "s", fn: "agent.steer", args: [adopt.args[1].handle, "text"] });
    assert.equal(typeof rejectSteer, "function");
    old.close();
    const close = frames.at(-1);
    assert.equal(close.method, "close");
    receive({ returned: close.call, value: null });
    rejectSteer();
    assert.equal((await answer(210)).value, false);
    receive({ rpc: 211, actor: "s", fn: "store.markUndelivered", args: ["s", [{ thread: "th", n: 1 }]] });
    const reply = await answer(211);
    assert.deepEqual({ rows, error: reply.error?.message }, { rows: [["undo"]], error: undefined });
  } finally {
    await program.close();
  }
});

test("W8-E2 R6 NN1: close is returned before its compensation is asked", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    old.actor.close();
    const close = f.posted.at(-1);
    assert.equal(close.method, "close");
    await f.deliver({ returned: close.call, value: null });
    const reply = await f.deliver({ rpc: 201, actor: "s", fn: "store.markUndelivered", args: ["s", []] });
    assert.equal(reply?.error, undefined, JSON.stringify(reply));
    assert.deepEqual(f.events, ["old/undo"]);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R6 NN2: steer refused after close, then its compensation", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    old.actor.close();
    const close = f.posted.at(-1);
    await f.deliver({ rpc: 301, actor: "s", fn: "agent.steer", args: [old.handle, "x"] });
    await f.deliver({ returned: close.call, value: null });
    const reply = await f.deliver({ rpc: 302, actor: "s", fn: "store.markUndelivered", args: ["s", []] });
    assert.equal(reply?.error, undefined, JSON.stringify(reply));
    assert.deepEqual(f.events, ["old/steer", "old/undo"]);
  } finally {
    await f.program.close();
  }
});

test("W8-E2 R6 NN3: snapshot hands over and nothing of the old reaches its session", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    const snapping = old.actor.snapshot();
    const call = f.posted.at(-1);
    await f.deliver({ returned: call.call, value: { agent: old.handle } });
    await snapping;
    const reply = await f.deliver({ rpc: 401, actor: "s", fn: "agent.dispose", args: [old.handle] });
    assert.equal(reply?.error?.actorClosed, true, JSON.stringify(reply));
    assert.deepEqual(f.events, []);
  } finally {
    await f.program.close();
  }
});

for (const churn of [511, 512]) {
  test(`W8-E2 R7: steer refill compensation survives ${churn} unrelated retirements`, async () => {
    const frames: any[] = [];
    let receive!: (frame: any) => void;
    const program = ActorsProgram.openForTest(
      {
        use(user: any) { receive = user.said; },
        post(frame: any) { frames.push(frame); return true; },
        hold() {},
        release() {},
        kill() {},
      } as any,
      { currentTimeMillisUnsafe: () => 100 } as any,
    );
    let marked = false;
    const store = {
      getSession: () => ({ runtime: "claude" }),
      markDelivered(_k: string, rows: any[]) { if (rows.length > 0) marked = true; },
      markUndelivered() { marked = false; },
    };
    try {
      const old = program.actor("original", "claude", { store } as any);
      let finishSteer!: (v: boolean) => void;
      const adopted = old.adopt(
        { runtime: "claude" } as any,
        { steer: () => new Promise<boolean>((r) => { finishSteer = r; }) } as any,
        "",
      );
      const call = frames.at(-1);
      receive({ returned: call.call, value: null });
      await adopted;
      receive({ rpc: 799, actor: "original", fn: "store.markDelivered", args: ["original", [{ thread: "t", n: 1 }], 7001] });
      await new Promise((r) => setImmediate(r));
      assert.equal(marked, true);
      receive({ rpc: 800, actor: "original", fn: "agent.steer", args: [call.args[1].handle, "m"] });
      old.close();
      receive({ returned: frames.at(-1).call, value: null });
      finishSteer(false);
      await new Promise((r) => setImmediate(r));
      assert.equal(frames.find((x) => x.answer === 800)?.value, false);
      for (let i = 0; i < churn; i++) {
        const a = program.actor(`other-${i}`, "claude", { store } as any);
        a.close();
        receive({ returned: frames.at(-1).call, value: null });
      }
      receive({ rpc: 900, actor: "original", fn: "store.markUndelivered", args: ["original", [{ thread: "t", n: 1 }], 7001] });
      await new Promise((r) => setImmediate(r));
      const result = frames.find((x) => x.answer === 900);
      assert.deepEqual(
        { marked, error: result?.error?.message, answer: result?.answer },
        { marked: false, error: undefined, answer: 900 },
      );
    } finally {
      await program.close();
    }
  });
}

test("W8-E2 R8 LL1: steer refused while live does not pin actor past idle bound", async () => {
  const f = r5RoutingFixture();
  try {
    const old = f.register("s", "old");
    await old.ready;
    await f.deliver({ rpc: 1, actor: "s", fn: "agent.steer", args: [old.handle, "x"] });
    const gone = old.actor.dispose();
    const call = f.posted.filter((p: any) => p.method === "dispose").at(-1);
    await f.deliver({ returned: call.call, value: null });
    await gone;
    for (let i = 0; i < 600; i++) {
      const a = f.program.actor(`other${i}`, "claude", { store: {} } as any);
      a.close();
      await f.deliver({ returned: f.posted.at(-1).call, value: null });
    }
    const reply = await f.deliver({ rpc: 2, actor: "s", fn: "store.markUndelivered", args: ["s", []] });
    assert.equal(reply?.error?.actorClosed, true, "still held after 600 others: " + JSON.stringify(reply));
  } finally {
    await f.program.close();
  }
});

for (const refused of [false, true]) {
  test(`W8-E2 R8: disposed actor with settled local work is evicted (steer refused=${refused})`, async () => {
    let receive!: (frame: any) => void;
    const frames: any[] = [];
    const program = ActorsProgram.openForTest(
      {
        use(user: any) { receive = user.said; },
        post(frame: any) { frames.push(frame); return true; },
        hold() {},
        release() {},
        kill() {},
      } as any,
      { currentTimeMillisUnsafe: () => 100 } as any,
    );
    const key = "locally-settled";
    let storeCalls = 0;
    let disposed = 0;
    const store = {
      getSession: () => ({ runtime: "claude" }),
      markUndelivered() { storeCalls++; },
    };
    try {
      const actor = program.actor(key, "claude", { store } as any);
      const adopted = actor.adopt(
        { runtime: "claude" } as any,
        { steer: async () => !refused, dispose: async () => { disposed++; } } as any,
        "",
      );
      const request = frames.at(-1);
      const handle = request.args[1].handle;
      receive({ returned: request.call, value: null });
      await adopted;
      receive({ rpc: 1, actor: key, fn: "agent.steer", args: [handle, "reminder"] });
      await new Promise((r) => setImmediate(r));
      assert.equal(frames.find((f) => f.answer === 1).value, !refused);
      const disposal = actor.dispose();
      const disposeCall = frames.at(-1).call;
      receive({ rpc: 2, actor: key, fn: "agent.dispose", args: [handle] });
      await new Promise((r) => setImmediate(r));
      receive({ returned: disposeCall, value: null });
      await disposal;
      assert.equal(disposed, 1);
      for (let i = 0; i < 513; i++) {
        program.actor(`idle-${i}`, "claude", { store } as any).close();
        receive({ returned: frames.at(-1).call, value: null });
      }
      receive({ rpc: 3, actor: key, fn: "store.markUndelivered", args: [key, []] });
      await new Promise((r) => setImmediate(r));
      const reply = frames.find((f) => f.answer === 3);
      assert.deepEqual({ storeCalls, closed: reply?.error?.actorClosed === true }, { storeCalls: 0, closed: true });
    } finally {
      await program.close();
    }
  });
}

const r9RoutingCases = [
  { name: "outstanding delivery, no configured db, receipt after close", delivery: true, memory: false, replyFirst: false },
  { name: "outstanding delivery, in-memory db, receipt after close", delivery: true, memory: true, replyFirst: false },
  { name: "notice only, receipt after close", delivery: false, memory: false, replyFirst: false },
  { name: "outstanding refill delivery, receipt before snapshot returns", delivery: true, memory: false, replyFirst: true },
];
for (const { name, delivery, memory, replyFirst } of r9RoutingCases) {
  test(`W8-E2 R9: ${name}`, async () => {
    const frames: any[] = [];
    let receive!: (msg: any) => void;
    const proc = {
      use(user: any) { receive = user.said; },
      post(msg: any) { frames.push(msg); return true; },
      hold() {},
      release() {},
      kill() {},
    };
    const clock = { currentTimeMillisUnsafe: () => 100 } as any;
    const db = new DatabaseSync(":memory:");
    db.exec("CREATE TABLE delivery(marked INTEGER); INSERT INTO delivery VALUES (0)");
    const store = {
      db,
      told() {},
      getSession: () => ({ runtime: "claude" }),
      markDelivered(_key: string, rows: any[]) { if (rows.length) db.exec("UPDATE delivery SET marked = 1"); },
      markUndelivered(_key: string, rows: any[]) { if (rows.length) db.exec("UPDATE delivery SET marked = 0"); },
    };
    const program = ActorsProgram.openForTest(proc as any, clock, memory ? store : null);
    const settle = () => new Promise((r) => setImmediate(r));
    try {
      assert.equal(frames.find((f) => Object.hasOwn(f, "db"))?.db, null, "worker has no attached database");
      const key = "subject";
      const actor = program.actor(key, "claude", { store } as any);
      let finish!: (v: boolean) => void;
      const adopted = actor.adopt(
        { runtime: "claude" } as any,
        {
          steer: () => new Promise<boolean>((r) => { finish = r; }),
          dispose: async () => {},
          snapshot: () => null,
          detach() {},
        } as any,
        "",
      );
      const { call, args } = frames.at(-1);
      const handle = args[1].handle;
      receive({ returned: call, value: null });
      await adopted;
      if (delivery) {
        receive({ rpc: 10, actor: key, fn: "store.markDelivered", args: [key, [{ thread: "t", n: 1 }], 9001] });
        await settle();
        assert.equal(frames.find((f) => f.answer === 10)?.error, undefined);
        assert.equal((db.prepare("SELECT marked FROM delivery").get() as any).marked, 1);
      }
      receive({ rpc: 1, actor: key, fn: "agent.steer", args: [handle, delivery ? "message" : "notice"] });
      const refuse = async () => {
        finish(false);
        await settle();
        assert.equal(frames.find((f) => f.answer === 1).value, false);
      };
      if (replyFirst) {
        const snapshot = actor.snapshot();
        const snapshotCall = frames.at(-1).call;
        await refuse();
        receive({ returned: snapshotCall, value: { agent: handle } });
        await snapshot;
      } else {
        actor.close();
        receive({ returned: frames.at(-1).call, value: null });
        receive({ rpc: 2, actor: key, fn: "agent.dispose", args: [handle] });
        await settle();
        assert.equal(frames.find((f) => f.answer === 2).value, null);
        const others: number[] = [];
        for (let i = 0; i < 512; i++) {
          program.actor(`idle-${i}`, "claude", { store } as any).close();
          others.push(frames.at(-1).call);
        }
        await refuse();
        for (const c of others) receive({ returned: c, value: null });
      }
      receive({
        rpc: 3,
        actor: key,
        fn: "store.markUndelivered",
        args: delivery ? [key, [{ thread: "t", n: 1 }], 9001] : [key, []],
      });
      await settle();
      assert.deepEqual(
        {
          closed: frames.find((f) => f.answer === 3)?.error?.actorClosed === true,
          marked: (db.prepare("SELECT marked FROM delivery").get() as any).marked,
        },
        { closed: !delivery, marked: 0 },
      );
    } finally {
      await program.close();
      db.close();
    }
  });
}

function r10RoutingFixture() {
  let receive!: (frame: any) => void;
  const frames: any[] = [];
  const writes: string[] = [];
  const seenArgCounts: { fn: string; argc: number }[] = [];
  const db = new DatabaseSync(":memory:");
  db.exec("CREATE TABLE delivery (n INTEGER PRIMARY KEY, marked INTEGER); INSERT INTO delivery VALUES (1,0), (2,0)");
  const program = ActorsProgram.openForTest(
    {
      use(user: any) { receive = user.said; },
      post(frame: any) { frames.push(frame); return true; },
      hold() {},
      release() {},
      kill() {},
    } as any,
    { currentTimeMillisUnsafe: () => 100 } as any,
  );
  let next = 10;
  const rpc = async (fn: string, args: any[]) => {
    const id = next++;
    receive({ rpc: id, actor: "s", fn, args });
    await new Promise((r) => setImmediate(r));
    const reply = frames.find((f) => f.answer === id);
    assert.ok(reply);
    return reply;
  };
  const tell = (tellName: string, args: any[]) => {
    receive({ actor: "s", tell: tellName, args });
  };
  const register = async (label: string, failMark = false) => {
    const store = {
      getSession() { return { runtime: "claude" }; },
      markDelivered(...callArgs: any[]) {
        seenArgCounts.push({ fn: "markDelivered", argc: callArgs.length });
        if (failMark) throw new Error("mark failed");
        for (const row of callArgs[1]) db.prepare("UPDATE delivery SET marked=1 WHERE n=?").run(row.n);
      },
      markUndelivered(...callArgs: any[]) {
        seenArgCounts.push({ fn: "markUndelivered", argc: callArgs.length });
        if (callArgs[1].length) writes.push(label);
        for (const row of callArgs[1]) db.prepare("UPDATE delivery SET marked=0 WHERE n=?").run(row.n);
      },
    };
    const actor = program.actor("s", "claude", { store } as any);
    const adoption = actor.adopt(
      { runtime: "claude" } as any,
      { steer: async (text: string) => text === "accept", dispose: async () => {}, snapshot: () => null, detach() {} } as any,
      "",
    );
    const { args, call } = frames.at(-1);
    receive({ returned: call, value: null });
    await adoption;
    const handle = args[1].handle;
    return {
      actor,
      handle,
      snapshot: async () => {
        const done = actor.snapshot();
        receive({ returned: frames.at(-1).call, value: { agent: handle } });
        await done;
      },
    };
  };
  const read = () => (db.prepare("SELECT marked FROM delivery WHERE n=1").get() as any).marked;
  return {
    program,
    rpc,
    tell,
    register,
    writes,
    seenArgCounts,
    read,
    close: async () => { await program.close(); db.close(); },
  };
}

for (const order of ["before accepted steer", "after accepted steer", "stopped while opening"] as const) {
  test(`W8-E2 R10: finished delivery is released at snapshot (${order})`, async () => {
    const f = r10RoutingFixture();
    const rows = [{ thread: "t", n: 1 }];
    try {
      const old = await f.register("old");
      if (order === "after accepted steer") assert.equal((await f.rpc("agent.steer", [old.handle, "accept"])).value, true);
      const markArgs = order === "before accepted steer" ? ["s", rows, 101] : ["s", rows];
      assert.equal((await f.rpc("store.markDelivered", markArgs)).error, undefined);
      if (order === "before accepted steer") {
        assert.equal((await f.rpc("agent.steer", [old.handle, "accept"])).value, true);
        f.tell("store.deliverySettled", [101]);
      }
      assert.equal(f.read(), 1);
      await old.snapshot();
      const probe = await f.rpc("store.markUndelivered", ["s", []]);
      assert.equal(probe.error?.actorClosed, true, "a completed batch kept its owner routable");
      assert.ok(f.seenArgCounts.every((c) => c.argc === 2), "batchId must not leak to Store methods");
    } finally {
      await f.close();
    }
  });
}

test("W8-E2 R10: late undo settles the marking actor across same-key replacement, with a shared database", async () => {
  const f = r10RoutingFixture();
  const rows = [{ thread: "t", n: 1 }];
  try {
    const old = await f.register("original");
    await f.rpc("store.markDelivered", ["s", rows, 202]);
    assert.equal((await f.rpc("agent.steer", [old.handle, "refuse"])).value, false);
    await old.snapshot();
    const current = await f.register("replacement");
    await f.rpc("store.markUndelivered", ["s", rows, 202]);
    assert.equal(f.read(), 0);
    await current.snapshot();
    const probe = await f.rpc("store.markUndelivered", ["s", []]);
    assert.deepEqual({ owners: f.writes, closed: probe.error?.actorClosed === true }, { owners: ["original"], closed: true });
    assert.ok(f.seenArgCounts.every((c) => c.argc === 2), "batchId must not leak to Store methods");
  } finally {
    await f.close();
  }
});

test("W8-E2 R10: store.deliverySettled releases retired actor after snapshot and failed markDelivered does not pin", async () => {
  const f = r10RoutingFixture();
  const rows = [{ thread: "t", n: 1 }];
  try {
    const old = await f.register("old");
    assert.equal((await f.rpc("store.markDelivered", ["s", rows, 303])).error, undefined);
    await old.snapshot();
    f.tell("store.deliverySettled", [303]);
    const probe1 = await f.rpc("store.markUndelivered", ["s", rows, 303]);
    assert.equal(probe1.error?.actorClosed, true, "store.deliverySettled must release retired actor");

    const failing = await f.register("failing", true);
    const failedReply = await f.rpc("store.markDelivered", ["s", rows, 304]);
    assert.ok(failedReply.error, "markDelivered should fail");
    await failing.snapshot();
    const probe2 = await f.rpc("store.markUndelivered", ["s", rows, 304]);
    assert.equal(probe2.error?.actorClosed, true, "failed markDelivered must not pin retired actor");
  } finally {
    await f.close();
  }
});

test("W8-F PP4: agent.steer(true) does NOT coarsely clear another provisional delivery batchId, and { db } clears stale provisional batches", async () => {
  const f = r10RoutingFixture();
  const rows = [{ thread: "t", n: 1 }];
  try {
    const old = await f.register("old");
    assert.equal((await f.rpc("store.markDelivered", ["s", rows, 401])).error, undefined);
    // Accepting steer must NOT clear batch 401; only explicit store.deliverySettled / store.markUndelivered may.
    assert.equal((await f.rpc("agent.steer", [old.handle, "accept"])).value, true);
    await old.snapshot();
    // Batch 401 must still route markUndelivered to the original retired actor until explicitly settled.
    assert.equal((await f.rpc("store.markUndelivered", ["s", rows, 401])).error, undefined);
    assert.deepEqual(f.writes, ["old"]);

    // Now test `{ db: null }` rotation clears provisional batches cleanly, AND a same-key replacement
    // actor registered before a late 3-arg `store.markUndelivered` MUST NOT receive the stale undo!
    const old2 = await f.register("old2");
    assert.equal((await f.rpc("store.markDelivered", ["s", rows, 402])).error, undefined);
    await old2.snapshot();
    f.program.post({ db: null });
    const replacement = await f.register("replacement");
    const probeAfterDb = await f.rpc("store.markUndelivered", ["s", rows, 402]);
    assert.equal(probeAfterDb.error?.actorClosed, true, "stale 3-arg store.markUndelivered must return actorClosed: true");
    assert.deepEqual(f.writes, ["old"], "replacement actor must NEVER be written by stale 3-arg undo");
    await replacement.snapshot();
  } finally {
    await f.close();
  }
});

test("W8-F: AgentsHost.replay().close() sends codexReplayed when reader is alive and IDs never collide across AgentsHost instances on a shared SessionsProgram", async (t) => {
  const pion = requirePionOrSkip(t);
  if (pion === null) return;
  const { AgentsHost } = await import("../src/agents/mb-agents.ts");
  const data = makeTmp("sf-w8-replay-close-");
  const prev = process.env.STILLFAIL_READER_SESSIONS;
  process.env.STILLFAIL_READER_SESSIONS = "pion";
  resetReaderSelectionStateForTest();

  // Keep the underlying SessionsProgram alive via an actors user while Host A closes and Host B opens.
  const keepAliveUser: ProgramUser = { actors: true, said: () => {}, exited: () => {} };
  const sharedProg = SessionsProgram.of(data, true)!;
  sharedProg.use(keepAliveUser);

  const hostA = AgentsHost.where(data);
  const postedA: any[] = [];
  const origPostA = hostA.post.bind(hostA);
  hostA.post = (msg: any) => {
    postedA.push(msg);
    origPostA(msg);
  };
  const driverA = {};
  hostA.use(driverA);
  try {
    const repA = hostA.replay();
    repA.feed([["item/started", "thread-1", "commandExecution", "c1"]]);
    repA.close();
    const feedMsgA = postedA.find((m) => typeof m.codexReplay === "number");
    assert.ok(feedMsgA, "expected codexReplay post from Host A");
    assert.ok(
      postedA.some((m) => m.codexReplayed === feedMsgA.codexReplay),
      `expected codexReplayed:${feedMsgA.codexReplay} on replay.close(), got: ${JSON.stringify(postedA)}`,
    );
    await hostA.close(driverA);

    // Open Host B on the exact same `data` (reuses `sharedProg`): its replay ID MUST be strictly > Host A's ID,
    // so any late `{ replayed: idA }` from Host A cannot corrupt Host B's replay!
    const hostB = AgentsHost.where(data);
    assert.notEqual(hostB, hostA);
    const postedB: any[] = [];
    const origPostB = hostB.post.bind(hostB);
    hostB.post = (msg: any) => {
      postedB.push(msg);
      origPostB(msg);
    };
    const driverB = {};
    hostB.use(driverB);
    try {
      const repB = hostB.replay();
      repB.feed([["item/started", "thread-2", "commandExecution", "c2"]]);
      const feedMsgB = postedB.find((m) => typeof m.codexReplay === "number");
      assert.ok(feedMsgB, "expected codexReplay post from Host B");
      assert.ok(
        feedMsgB.codexReplay > feedMsgA.codexReplay,
        `Host B replay id (${feedMsgB.codexReplay}) must exceed Host A id (${feedMsgA.codexReplay}) on shared SessionsProgram`,
      );
      const liveB = await repB.done();
      assert.ok(
        liveB["thread-2"] !== undefined && JSON.stringify(liveB["thread-2"]).includes("c2"),
        `Host B replay must resolve with its own thread-2 step c2, got: ${JSON.stringify(liveB)}`,
      );
      repB.close();
    } finally {
      await hostB.close(driverB);
    }
  } finally {
    await sharedProg.release(keepAliveUser);
    if (prev === undefined) delete process.env.STILLFAIL_READER_SESSIONS;
    else process.env.STILLFAIL_READER_SESSIONS = prev;
    resetReaderSelectionStateForTest();
  }
});

test("W8-F R3 P1: AgentsHost session IDs remain monotonic across SessionsProgram restart so new sessions never collide with re-attached live sessions", async (t) => {
  const pion = requirePionOrSkip(t);
  if (pion === null) return;
  const { AgentsHost } = await import("../src/agents/mb-agents.ts");
  const data = makeTmp("sf-w8-restart-id-");
  const prev = process.env.STILLFAIL_READER_SESSIONS;
  process.env.STILLFAIL_READER_SESSIONS = "pion";
  resetReaderSelectionStateForTest();

  const host = AgentsHost.where(data);
  const driver = {};
  host.use(driver);
  const origUse = SessionsProgram.prototype.use;
  const capturedAgentUsers: ProgramUser[] = [];
  // (every end of a SessionsProgram the agents' user hears, by program: after the one this test kills, any other is a
  // restart that failed, which fails the test at once instead of waiting on a re-attach that never comes)
  const ends: Array<{ program: SessionsProgram | null; code: number }> = [];
  let activeProgram: SessionsProgram | null = null;
  let allowKillOf: SessionsProgram | null = null;
  let guardActive = true;
  let rejectUnexpectedExit!: (err: Error) => void;
  const unexpectedExit = new Promise<never>((_, reject) => {
    rejectUnexpectedExit = reject;
  });
  unexpectedExit.catch(() => {});
  const watched = new WeakSet<ProgramUser>();
  SessionsProgram.prototype.use = function (this: SessionsProgram, user: ProgramUser) {
    if (!user.actors) {
      capturedAgentUsers.push(user);
      activeProgram = this;
      if (!watched.has(user)) {
        watched.add(user);
        const exited = user.exited.bind(user);
        user.exited = (code: number) => {
          const ended = activeProgram;
          ends.push({ program: ended, code });
          if (guardActive && ended !== allowKillOf) {
            rejectUnexpectedExit(new Error(`unexpected SessionsProgram exit (${code}) before expected transition`));
          }
          exited(code);
        };
      }
    }
    return origUse.call(this, user);
  };
  const spawns = createSpawnTracker();
  try {
    // 1. Attach live session A (id `a`) with only agents using the SessionsProgram.
    const heardA: any[] = [];
    const heardB: any[] = [];
    const makeFakeHosted = (n: number, out: any[], onAttached: () => void = () => {}) => ({
      n,
      info: { socket: join(data, `fake-${n}.sock`), pid: 999999 },
      kind: "claude" as const,
      flavor: {},
      orphans: false,
      routed: false,
      gone: false,
      detaching: false,
      turnNow: () => null,
      liveNow: () => null,
      attached() { onAttached(); },
      heard(h: any) { out.push(h); },
      inTurn(fn: () => void) { fn(); },
      exited_() {},
      closed_() {},
      left_() {},
    });

    const idA = host.number();
    // (A's second `attached()` is AgentsHost re-attaching it to the restarted SessionsProgram: no wall-clock deadline)
    let attachedA = 0;
    let secondAttach!: () => void;
    const secondAttachSeen = new Promise<void>((resolveSeen) => (secondAttach = resolveSeen));
    const procA = makeFakeHosted(idA, heardA, () => {
      attachedA += 1;
      if (attachedA === 2) secondAttach();
    });
    host.attach(procA as any);
    assert.equal(attachedA, 1, "A attached once to the first SessionsProgram");
    const firstProg = host.program();
    assert.ok(firstProg !== null, "first SessionsProgram must be active");
    // (the first generation really running: its Pion `--sessions` process said ready, past the `--version` probe, so
    // the kill below ends a process rather than calling off a pending start; any exit before ready fails at once)
    const readies = () => spawns.events.filter((e) => e.ready);
    await Promise.race([spawns.waitUntil(() => readies().length >= 1), unexpectedExit]);
    const first = readies()[0]!;
    assert.equal(first.engine, "pion", "the first generation is stillfail-pion");
    assert.ok(first.pid !== null, "the first generation has a process");

    // 2. Kill the underlying SessionsProgram so AgentsHost.#exited triggers a restart and re-attaches A with idA.
    allowKillOf = firstProg;
    firstProg.kill();
    await Promise.race([Promise.all([secondAttachSeen, spawns.waitUntil(() => readies().length >= 2)]), unexpectedExit]);
    guardActive = false;
    assert.equal(attachedA, 2, "A re-attached exactly once after the restart");
    assert.deepEqual(ends.map((e) => e.program === firstProg), [true], "only the killed generation ended");
    const second = readies()[1]!;
    assert.equal(second.engine, "pion", "the second generation is stillfail-pion");
    assert.ok(second.pid !== null && second.pid !== first.pid, `a second --sessions process (${second.pid}) beside the killed one (${first.pid})`);
    const secondProg = host.program();
    assert.ok(secondProg !== null && secondProg !== firstProg, "AgentsHost must restart a fresh SessionsProgram");
    const agentUser = capturedAgentUsers.at(-1);
    assert.ok(agentUser !== undefined, "restarted SessionsProgram must have registered AgentsHost ProgramUser");

    // 3. Allocate a new session B after restart -> its ID MUST be strictly > idA (never reset to 1 or collide!).
    const idB = host.number();
    assert.ok(idB > idA, `post-restart session id (${idB}) must exceed live session A id (${idA})`);
    const procB = makeFakeHosted(idB, heardB);
    host.attach(procB as any);

    // 4. Dispatch frames for idA and idB through the restarted SessionsProgram's real agent ProgramUser
    //    and assert A and B each receive ONLY their own frames (no #sessions[idA] overwrite).
    agentUser.said({ lines: idA, events: [{ kind: "a-only" }], turn: null, to: 1 });
    agentUser.said({ lines: idB, events: [{ kind: "b-only" }], turn: null, to: 2 });
    assert.equal(heardA.length, 1, "live session A must receive its own frame after restart");
    assert.deepEqual(heardA[0].events, [{ kind: "a-only" }]);
    assert.equal(heardB.length, 1, "new session B must receive its own frame after restart");
    assert.deepEqual(heardB[0].events, [{ kind: "b-only" }]);

    host.forget(procA as any);
    host.forget(procB as any);
  } finally {
    guardActive = false;
    setSessionsSpawnObserverForTest(null);
    SessionsProgram.prototype.use = origUse;
    await host.close(driver);
    if (prev === undefined) delete process.env.STILLFAIL_READER_SESSIONS;
    else process.env.STILLFAIL_READER_SESSIONS = prev;
    resetReaderSelectionStateForTest();
  }
});

test("W8-F P1-3: pion --version probe settles to null on >64 KiB stdout and when a grandchild holds stdout open after direct child exits", async (t) => {
  if (process.platform === "win32") {
    t.skip("POSIX shebang fixture");
    return;
  }
  const dir = makeTmp("sf-w8-probe-");
  resetReaderSelectionStateForTest();

  // (a) Over-limit stdout (>64 KiB) settles immediately to null (assert fixture actually ran!).
  const ranFile = join(dir, "big-ran.flag");
  const bigBin = join(dir, "big-stdout.mjs");
  writeFileSync(
    bigBin,
    [
      `#!${process.execPath}`,
      `import { writeFileSync } from "node:fs";`,
      `writeFileSync(${JSON.stringify(ranFile)}, "ran");`,
      `process.stdout.write("x".repeat(80 * 1024));`,
    ].join("\n") + "\n",
    "utf8",
  );
  chmodSync(bigBin, 0o755);
  const bigRes = await probePionSupportedModes(bigBin);
  assert.equal(existsSync(ranFile), true, "big-stdout fixture must have actually executed");
  assert.equal(bigRes, null, "probe output exceeding 64 KiB must settle to null");

  // (b) Direct child exits 0 while a spawned grandchild keeps stdout pipe open ->
  // must settle to null after timeout (never hang forever). Assert pidFile exists & clean up grandchild PID in finally.
  const pidFile = join(dir, "grandchild.pid");
  const holdBin = join(dir, "grandchild-stdout.mjs");
  writeFileSync(
    holdBin,
    [
      `#!${process.execPath}`,
      `import { spawn } from "node:child_process";`,
      `import { writeFileSync } from "node:fs";`,
      `const gc = spawn(process.execPath, ["-e", "setInterval(() => {}, 60000)"], { stdio: ["ignore", 1, "ignore"], detached: true });`,
      `writeFileSync(${JSON.stringify(pidFile)}, String(gc.pid));`,
      `gc.unref();`,
      `process.exit(0);`,
    ].join("\n") + "\n",
    "utf8",
  );
  chmodSync(holdBin, 0o755);
  let gcPid = 0;
  try {
    const holdRes = await probePionSupportedModes(holdBin);
    assert.equal(existsSync(pidFile), true, "grandchild fixture must have written pidFile");
    gcPid = Number(readFileSync(pidFile, "utf8").trim());
    assert.ok(Number.isInteger(gcPid) && gcPid > 0, `expected valid grandchild PID, got ${gcPid}`);
    assert.equal(holdRes, null, "probe with grandchild holding stdout open must time out and settle to null");
  } finally {
    if (gcPid <= 0 && existsSync(pidFile)) {
      gcPid = Number(readFileSync(pidFile, "utf8").trim());
    }
    if (Number.isInteger(gcPid) && gcPid > 0) {
      try {
        process.kill(gcPid, "SIGKILL");
      } catch {}
    }
    resetReaderSelectionStateForTest();
  }
});
