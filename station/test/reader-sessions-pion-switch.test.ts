// Wave 8 W8-F end-to-end dual-engine parity, real spawn verification, and crash-exit-70 recovery
// for `--sessions` (`station/mb/src/reader` vs `pion/station/packages/reader_sessions`).
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import { Clock, Effect } from "effect";
import { AgentsHost } from "../src/agents/mb-agents.ts";
import {
  SessionsProgram,
  setSessionsSpawnObserverForTest,
  type SessionsSpawnEvent,
} from "../src/agents/mb-program.ts";
import { mbReaderBinary, pionBinary, resetReaderSelectionStateForTest } from "../src/read/mb-reader.ts";
import { ActorsProgram } from "../src/sessions/mb-actor.ts";
import { Store } from "../src/store/store.ts";

const STATION_DIR = resolve(fileURLToPath(new URL("..", import.meta.url)));
const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
const requirePion = process.env.STILLFAIL_REQUIRE_PION_SESSIONS === "1";

const tmpDirs: string[] = [];
const liveChildren = new Set<ChildProcessWithoutNullStreams>();

after(() => {
  for (const child of liveChildren) {
    try {
      child.kill("SIGKILL");
    } catch {}
  }
  liveChildren.clear();
  for (const dir of tmpDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function makeTmp(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}

function createLineReader(proc: ChildProcessWithoutNullStreams) {
  let buf = "";
  const lines: string[] = [];
  const waiters: Array<() => void> = [];
  proc.stdout.setEncoding("utf8");
  proc.stdout.on("data", (chunk: string) => {
    buf += chunk;
    for (let nl = buf.indexOf("\n"); nl >= 0; nl = buf.indexOf("\n")) {
      lines.push(buf.slice(0, nl));
      buf = buf.slice(nl + 1);
    }
    while (waiters.length > 0 && lines.length > 0) {
      waiters.shift()!();
    }
  });
  return {
    async nextLine(): Promise<string> {
      while (lines.length === 0) {
        await new Promise<void>((r) => waiters.push(r));
      }
      return lines.shift()!;
    },
    drainAvailable(): string[] {
      return lines.splice(0, lines.length);
    },
  };
}

async function runProtocolTranscript(binary: string, dataDir: string, dbPath: string): Promise<{
  frames: unknown[];
  stderr: string;
  code: number | null;
}> {
  const child = spawn(binary, ["--sessions", "1", "--data", dataDir, "--sep", "/"], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  liveChildren.add(child);
  let stderr = "";
  child.stderr.setEncoding("utf8");
  child.stderr.on("data", (c: string) => {
    stderr += c;
  });
  const reader = createLineReader(child);
  const exited = new Promise<number | null>((res) => child.once("close", (code) => res(code)));

  try {
    const frames: unknown[] = [];
    // 1. Handshake
    const ready = JSON.parse(await reader.nextLine());
    assert.deepEqual(ready, { ready: true });
    frames.push(ready);

    // 2. Attach DB + seed Codex replay (process-scoped Agents) BEFORE db rotation
    child.stdin.write(JSON.stringify({ db: dbPath, now: 1000 }) + "\n");
    frames.push(JSON.parse(await reader.nextLine())); // quiet

    // Normal Codex replay using the real production 4-tuple notice (`codex.ts:1138` / `agents_codex.mbt:366`):
    // `[method, threadId, itemType, stepId]`.
    child.stdin.write(
      JSON.stringify({
        codexReplay: 7,
        notices: [["item/started", "thread-a", "commandExecution", "step-1"]],
      }) + "\n",
    );

    // 3. Rotate DB (`{"db": dbPath}`) — Agents must keep replay #7 across rotation!
    child.stdin.write(JSON.stringify({ db: dbPath, now: 2000 }) + "\n");
    frames.push(JSON.parse(await reader.nextLine())); // quiet after rotation

    // 4. 65+ lines in a single chunk (65 maxConcurrentTurns + 1 freeze + 1 codexReplayed)
    const bigChunk: string[] = [];
    for (let i = 1; i <= 65; i++) {
      bigChunk.push(JSON.stringify({ maxConcurrentTurns: i, now: 2000 + i }));
    }
    bigChunk.push(JSON.stringify({ freeze: 9 }));
    bigChunk.push(JSON.stringify({ codexReplayed: 7 }));
    child.stdin.write(bigChunk.join("\n") + "\n");

    // Preserve the COMPLETE ordered frame sequence up to EOF (all 65 quiet frames + frozen + replayed).
    let quietCount = 0;
    let frozenFrame: any = null;
    let replayedFrame: any = null;
    for (let i = 0; i < 67; i++) {
      const f = JSON.parse(await reader.nextLine());
      frames.push(f);
      if (f.quiet === true) {
        quietCount++;
      } else if (f.frozen === 9) {
        frozenFrame = f;
      } else if (f.replayed === 7) {
        replayedFrame = f;
      }
    }
    assert.equal(quietCount, 65, "all 65 same-chunk lines must produce 65 quiet frames");
    assert.deepEqual(frozenFrame, { frozen: 9, states: {} });
    assert.ok(replayedFrame !== null && typeof replayedFrame.live === "object", "Agents replay #7 must survive db rotation");
    const threadLive = replayedFrame.live["thread-a"];
    assert.ok(
      threadLive !== undefined && JSON.stringify(threadLive).includes("step-1"),
      `replayedFrame.live["thread-a"] must contain step-1 across db rotation, got: ${JSON.stringify(replayedFrame)}`,
    );

    child.stdin.end();
    const code = await exited;
    for (const trailing of reader.drainAvailable()) {
      frames.push(JSON.parse(trailing));
    }
    return { frames, stderr, code };
  } finally {
    liveChildren.delete(child);
    if (child.exitCode === null && !child.killed) {
      try {
        child.kill("SIGKILL");
      } catch {}
    }
  }
}

test("W8-F dual-snapshot parity: MB and Pion --sessions produce 0-diff on 65-line chunk, Codex replay, and cross-db Agents survival", async (t) => {
  const pion = pionBinary();
  const mb = mbReaderBinary();
  if (pion === null || mb === null) {
    if (requireDual) {
      assert.fail(`STILLFAIL_REQUIRE_DUAL_READER=1 requires both binaries (pion=${pion}, mb=${mb})`);
    }
    t.skip(`dual-engine binaries unavailable (pion=${pion !== null}, mb=${mb !== null})`);
    return;
  }

  // Create initial SQLite snapshot, then clone into two isolated directories.
  const seedDir = makeTmp("sf-w8f-seed-");
  const seedStore = Store.open(join(seedDir, "stillfail.db"));
  seedStore.close();

  const dirMb = makeTmp("sf-w8f-mb-");
  const dirPion = makeTmp("sf-w8f-pion-");
  cpSync(seedDir, dirMb, { recursive: true });
  cpSync(seedDir, dirPion, { recursive: true });

  const [resMb, resPion] = await Promise.all([
    runProtocolTranscript(mb, dirMb, join(dirMb, "stillfail.db")),
    runProtocolTranscript(pion, dirPion, join(dirPion, "stillfail.db")),
  ]);

  assert.equal(resMb.code, 0, `MB exited ${resMb.code}: ${resMb.stderr}`);
  assert.equal(resPion.code, 0, `Pion exited ${resPion.code}: ${resPion.stderr}`);
  assert.equal(resMb.stderr, "", `MB unexpected stderr: ${resMb.stderr}`);
  assert.equal(resPion.stderr, "", `Pion unexpected stderr: ${resPion.stderr}`);
  assert.deepEqual(resPion.frames, resMb.frames, "Pion --sessions frames must match MB 0-diff");
});

test("W8-F real spawn observation: STILLFAIL_READER_SESSIONS=pion + STILLFAIL_REQUIRE_PION_SESSIONS=1 spawns verified stillfail-pion PID with 0 MB fallback", async (t) => {
  const pion = pionBinary();
  if (pion === null) {
    if (requirePion || requireDual) {
      assert.fail("stillfail-pion binary required");
    }
    t.skip("stillfail-pion binary not built");
    return;
  }

  resetReaderSelectionStateForTest();
  const dataDir = makeTmp("sf-w8f-spawn-");
  const store = Store.open(join(dataDir, "stillfail.db"));
  const events: SessionsSpawnEvent[] = [];
  let resolveReady!: () => void;
  const readySeen = new Promise<void>((r) => {
    resolveReady = r;
  });
  setSessionsSpawnObserverForTest((ev) => {
    events.push(ev);
    if (ev.ready) resolveReady();
  });

  const prevEngine = process.env.STILLFAIL_READER_SESSIONS;
  const prevReq = process.env.STILLFAIL_REQUIRE_PION_SESSIONS;
  process.env.STILLFAIL_READER_SESSIONS = "pion";
  process.env.STILLFAIL_REQUIRE_PION_SESSIONS = "1";

  let program: ActorsProgram | null = null;
  try {
    program = ActorsProgram.open(dataDir, Effect.runSync(Clock.clockWith(Effect.succeed)), store);
    assert.ok(program !== null, "ActorsProgram.open must succeed under forced Pion");
    await readySeen;
    assert.ok(events.length >= 1, "expected at least 1 sessions spawn event");
    assert.ok(
      events.every((e) => e.engine === "pion" && e.fallback === false && e.pid !== null && e.pid > 0 && e.binary === pion),
      `expected verified Pion spawn with 0 MB and 0 fallback, got: ${JSON.stringify(events)}`,
    );
    // Verify AgentsHost shares the same Pion program and replay().close() works cleanly without leaking.
    const agentsHost = AgentsHost.where(dataDir);
    const driver = {};
    agentsHost.use(driver);
    const rep = agentsHost.replay();
    rep.feed([["item/started", "thread-x", "commandExecution", "s1"]]);
    rep.close();
    await agentsHost.close(driver);
  } finally {
    setSessionsSpawnObserverForTest(null);
    if (program !== null) await program.close();
    store.close();
    if (prevEngine === undefined) delete process.env.STILLFAIL_READER_SESSIONS;
    else process.env.STILLFAIL_READER_SESSIONS = prevEngine;
    if (prevReq === undefined) delete process.env.STILLFAIL_REQUIRE_PION_SESSIONS;
    else process.env.STILLFAIL_REQUIRE_PION_SESSIONS = prevReq;
    resetReaderSelectionStateForTest();
  }
});

test("W8-F crash recovery: killing verified stillfail-pion PID causes ActorsProgram process exit 70 and clean restart recovery", async (t) => {
  const pion = pionBinary();
  if (pion === null) {
    if (requirePion || requireDual) {
      assert.fail("stillfail-pion binary required");
    }
    t.skip("stillfail-pion binary not built");
    return;
  }

  const dataDir = makeTmp("sf-w8f-kill70-");
  const script = `
import { Clock, Effect } from "effect";
import { setSessionsSpawnObserverForTest } from "./src/agents/mb-program.ts";
import { ActorsProgram } from "./src/sessions/mb-actor.ts";
import { Store } from "./src/store/store.ts";

const dataDir = process.env.TEST_DATA_DIR;
const mode = process.env.TEST_MODE;
const store = Store.open(dataDir + "/stillfail.db");
let spawnedPid = 0;
let spawnedBinary = "";
let resolveSpawn;
const spawnSeen = new Promise((r) => { resolveSpawn = r; });
setSessionsSpawnObserverForTest((ev) => {
  if (ev.engine === "pion" && ev.fallback === false && ev.pid !== null && ev.pid > 0) {
    spawnedPid = ev.pid;
    spawnedBinary = ev.binary;
    if (ev.ready) resolveSpawn();
  }
});
const program = ActorsProgram.open(dataDir, Effect.runSync(Clock.clockWith(Effect.succeed)), store);
if (!program) {
  console.error("NO_PROGRAM");
  process.exit(2);
}
await spawnSeen;
if (spawnedPid <= 0) {
  console.error("NO_PION_PID");
  process.exit(2);
}
console.log(JSON.stringify({ mode, pid: spawnedPid, binary: spawnedBinary }));
if (mode === "kill") {
  try { process.kill(spawnedPid, "SIGKILL"); } catch {}
} else {
  // Recovery boot: verify ActorsProgram comes up cleanly on the same DB and exits 0.
  await program.close();
  store.close();
  process.exit(0);
}
`;

  const runSub = (mode: "kill" | "recover") =>
    new Promise<{ code: number | null; stdout: string; stderr: string }>((resolveSub) => {
      const child = spawn(process.execPath, ["--input-type=module", "-e", script], {
        cwd: STATION_DIR,
        env: {
          ...process.env,
          TEST_DATA_DIR: dataDir,
          TEST_MODE: mode,
          STILLFAIL_PION_READER: pion,
          STILLFAIL_READER_SESSIONS: "pion",
          STILLFAIL_REQUIRE_PION_SESSIONS: "1",
        },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (c: string) => {
        stdout += c;
      });
      child.stderr.on("data", (c: string) => {
        stderr += c;
      });
      child.once("close", (code) => resolveSub({ code, stdout, stderr }));
    });

  // 1. Kill verified Pion PID -> TS ActorsProgram must exit with code 70.
  const first = await runSub("kill");
  assert.equal(first.code, 70, `expected ActorsProgram exit code 70 after SIGKILLing Pion PID, got ${first.code}; stdout=${first.stdout} stderr=${first.stderr}`);
  const firstInfo = JSON.parse(first.stdout.trim().split("\n").pop()!);
  assert.equal(firstInfo.binary, pion);
  assert.ok(firstInfo.pid > 0);

  // 2. Simulated runner keepalive restart: re-opening on the same DB succeeds cleanly with a fresh Pion PID.
  const second = await runSub("recover");
  assert.equal(second.code, 0, `expected recovery restart exit 0, got ${second.code}; stdout=${second.stdout} stderr=${second.stderr}`);
  const secondInfo = JSON.parse(second.stdout.trim().split("\n").pop()!);
  assert.equal(secondInfo.binary, pion);
  assert.ok(secondInfo.pid > 0);
});
