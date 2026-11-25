// Wave 7 Sub-Wave 7.0 foundation tests (zero real-time sleeps; 100% deterministic):
// - `LiveProgram.binary` path observability on `MbProcess.live()`
// - `Readers.mbReader` zero disk probes in auto mode (`"auto"`) + explicit override priority
// - Pion-only cold-start (`mbReaderBinary() === null`): concurrent 2 first reads share 1 probe & cancel -> 1 child,
//   close-during-probe (0 orphans), cooldown, unsupported, hot-reload to MB, hot-reload to unavailable target (retires old PID),
//   and busy-slot non-rejection when start() fails
// - `OwnReader`: async `resolveReaderSelectionAsync("data")`, shared startup, close-during-probe, hot switch
// - `Served`: restart async `resolveBinary`, resolve failure backoff, sync throw in restart/spawn (0 unhandledRejection + backoff),
//   close-during-resolve (0 orphans)
// - Real `MeshLive` + `Served`: opposite `data` vs `serve` engines, explicit `mbReader` override passthrough, and `reference` branch
// - Recursive string-aware lexical static guard: forbids `shell_call_wait`, `read_bytes_range`, `write_atomic`,
//   `host_shim::wait`, `host_shim::shell_call` in `front`/`readops_*`/`reader_*` + counter-example assertions.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Effect, Fiber, Layer, Stream, SubscriptionRef } from "effect";
import {
  MbProcess,
  resetReaderSelectionStateForTest,
  resolveReaderSelectionAsync,
  setMbReaderBinaryOverrideForTest,
  setPionProbeRunnerForTest,
} from "../src/read/mb-reader.ts";
import { Readers } from "../src/read/pool.ts";
import { READER_MODES, type ReaderSelectConfig } from "../src/read/reader-select.ts";
import { OwnReader } from "../src/sessions/live.ts";
import { SERVED_AGAIN_MS, SERVED_STEADY_MS, Served, type ServingProcess } from "../src/mesh/served.ts";
import { MeshLive } from "../src/mesh/mesh.ts";
import { StationKey } from "../src/cloud/key.ts";
import { Net } from "../src/jobs/load.ts";
import {
  AdminApi,
  ControlPlane,
  Events,
  Key,
  MeshNative,
  MeshSide,
  Own,
  Parts,
  Paths,
  Peers,
  Previous,
  ReaderConfig,
  RigSide,
  ScreenRegistry,
  StationConfig,
  Store,
  Up,
} from "../src/services.ts";
import type { Mesh } from "../src/mesh/native.ts";
import { StationParts } from "../src/parts.ts";
import { Store as DbStore } from "../src/store/store.ts";
import { memoryMesh } from "./memory-mesh.ts";

const REPO_ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));

const nextTick = () => new Promise<void>((r) => setImmediate(r));

function makeStubReaderScript(dir: string, name: string, tag: string, opts: { serve?: boolean } = {}): string {
  const script = join(dir, name);
  const body = `#!/usr/bin/env node
const readline = require("node:readline");
if (process.argv.includes("--version")) {
  process.stdout.write("stillfail-pion 0.1.0 modes:footprint,packed,memory,data,serve\\n");
  process.exit(0);
}
const serveIdx = process.argv.indexOf("--serve");
if (${opts.serve ? "true" : "false"} && serveIdx >= 0 && process.argv[serveIdx + 1]) {
  process.stdout.write(JSON.stringify({ listening: process.argv[serveIdx + 1] }) + "\\n");
  process.stdin.resume();
  return;
}
const rl = readline.createInterface({ input: process.stdin });
process.stdout.write(JSON.stringify({ ready: { loadedMs: 1, openedMs: 1 } }) + "\\n");
rl.on("line", (line) => {
  if (!line.trim()) return;
  const ask = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: ask.id, text: JSON.stringify({ tag: ${JSON.stringify(tag)}, pid: process.pid, op: ask.op }) }) + "\\n");
});
`;
  writeFileSync(script, body, "utf8");
  chmodSync(script, 0o755);
  return script;
}

function withEnv(patch: Record<string, string | undefined>, fn: () => Promise<void> | void): Promise<void> {
  const prev = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(patch)) {
    prev.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  const restore = () => {
    for (const [k, v] of prev) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  };
  return Promise.resolve().then(fn).finally(restore);
}

function withMutableModeFlag(mode: "data" | "serve", value: boolean, fn: () => Promise<void> | void): Promise<void> {
  const meta = READER_MODES[mode] as { pionImplemented: boolean };
  const prev = meta.pionImplemented;
  meta.pionImplemented = value;
  return Promise.resolve()
    .then(fn)
    .finally(() => {
      meta.pionImplemented = prev;
    });
}

test("LiveProgram.binary exposes exact spawned executable path on MbProcess.live()", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-live-bin-"));
  const stub = makeStubReaderScript(dir, "stub-bin", "live-test");
  const proc = new MbProcess(stub, ["--data", dir]);
  try {
    await new Promise<void>((resolveReady, rejectReady) => {
      proc.once("message", () => resolveReady());
      proc.once("error", rejectReady);
      proc.once("exit", (code) => rejectReady(new Error(`unexpected exit ${code}`)));
    });
    const live = MbProcess.live().find((p) => p.binary === stub);
    assert.ok(live !== undefined, `expected MbProcess.live() to contain binary=${stub}`);
    assert.equal(live.binary, stub);
    assert.ok(live.pid > 0);
  } finally {
    await proc.terminate();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("Readers: explicit mbReader override ALWAYS wins and auto get mbReader does zero disk probes", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-explicit-"));
  const explicitStub = makeStubReaderScript(dir, "explicit-mb", "explicit-mb");
  const pionStub = makeStubReaderScript(dir, "pion-bin", "pion-bin");
  resetReaderSelectionStateForTest();
  await withMutableModeFlag("data", true, async () => {
    await withEnv({ STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: "pion" }, async () => {
      // Auto mode get mbReader MUST NOT touch mbReaderBinary() / disk.
      setMbReaderBinaryOverrideForTest(() => {
        throw new Error("mbReaderBinary() must not be called by get mbReader()");
      });
      const autoReaders = new Readers(dir, 1);
      assert.equal(autoReaders.mbReader, "auto");
      assert.equal(autoReaders.explicitMbReader, null);
      autoReaders.close();
      resetReaderSelectionStateForTest();

      setPionProbeRunnerForTest(async () => new Set(["data", "serve"]));
      const readers = Object.assign(
        new Readers(dir, 1, undefined, 1, { readers: () => ({ readers: { data: "pion" } }) }),
        { mbReader: explicitStub },
      );
      try {
        assert.equal(readers.mbReader, explicitStub);
        assert.equal(readers.explicitMbReader, explicitStub);
        const raw = await readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
        assert.equal(JSON.parse(raw).tag, "explicit-mb");
        const live = MbProcess.live().find((p) => p.args.includes(dir));
        assert.equal(live?.binary, explicitStub);
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
        rmSync(dir, { recursive: true, force: true });
      }
    });
  });
});

test("Readers: Pion-only cold-start concurrent share/cancel, close-during-probe, cooldown, unsupported, hot-reload (valid & unavailable), and busy-slot preservation", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-pion-only-"));
  const pionStubA = makeStubReaderScript(dir, "pion-a", "pion-a");
  const mbStubB = makeStubReaderScript(dir, "mb-b", "mb-b");
  resetReaderSelectionStateForTest();

  await withMutableModeFlag("data", true, async () => {
    // 1. Concurrent 2 first reads share 1 probe; cancelling 1 leaves only 1 spawned child;
    //    then hot-reload to unavailable MB retires old Pion PID and rejects instead of serving with old PID;
    //    then hot-reload to available MB spawns mbStubB.
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_ENGINE: undefined }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      const probeStarted = Promise.withResolvers<void>();
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      let probeCalls = 0;
      setPionProbeRunnerForTest(() => {
        probeCalls++;
        probeStarted.resolve();
        return new Promise((r) => {
          releaseProbe = r;
        });
      });

      let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
      const readers = new Readers(dir, 2, undefined, 1, { readers: () => cfg });
      try {
        assert.equal(readers.mbReader, "auto");
        assert.equal(readers.explicitMbReader, null);

        // Two concurrent reads while probe is pending share 1 probe; abort second before probe finishes -> only 1 child spawns.
        const ac = new AbortController();
        const readP1 = readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
        const readP2 = readers.read("latestMessages", { thread: 2, limit: 1 }, "en", { signal: ac.signal });
        await probeStarted.promise;
        assert.equal(probeCalls, 1);
        ac.abort();
        await assert.rejects(readP2, /cancelled/);
        releaseProbe(new Set(["data"]));
        const resA = JSON.parse(await readP1);
        assert.equal(resA.tag, "pion-a");
        await nextTick();
        const liveAfterFirst = MbProcess.live().filter((p) => p.args.includes(dir));
        assert.equal(liveAfterFirst.length, 1, "aborted concurrent first read must leave only 1 spawned child");
        assert.equal(liveAfterFirst[0]!.binary, pionStubA);
        const oldPionPid = resA.pid;

        // Hot-reload to UNAVAILABLE MB (mbReaderBinary() === null): MUST retire idle kept Pion slot and reject!
        cfg = { readers: { data: "mb" } };
        await assert.rejects(
          readers.read("latestMessages", { thread: 3, limit: 1 }, "en"),
          /stillfail-reader/,
          "hot-reload to unavailable MB must reject rather than reusing old Pion slot",
        );
        // Old slot is already removed from the pool (retireMismatchedIdle() === 0) and a follow-up read also rejects (old PID never answers).
        assert.equal(readers.retireMismatchedIdle(), 0, "old Pion slot must already be retired from pool");
        await assert.rejects(
          readers.read("latestMessages", { thread: 3, limit: 1 }, "en"),
          /stillfail-reader/,
          "old Pion PID must never answer subsequent reads after hot-reload to unavailable target",
        );
        void oldPionPid;

        // Now make mbStubB available -> next read spawns mbStubB.
        setMbReaderBinaryOverrideForTest(() => mbStubB);
        const resB = JSON.parse(await readers.read("latestMessages", { thread: 4, limit: 1 }, "en"));
        assert.equal(resB.tag, "mb-b");
        const liveB = MbProcess.live().find((p) => p.args.includes(dir) && p.binary === mbStubB);
        assert.ok(liveB !== undefined, "expected hot-reload to spawn mbStubB");
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
      }
    });

    // 2. Close during pending probe: deterministic wait on probeStarted, rejects cleanly and spawns ZERO children
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: "pion" }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      const probeStarted = Promise.withResolvers<void>();
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      setPionProbeRunnerForTest(() => {
        probeStarted.resolve();
        return new Promise((r) => {
          releaseProbe = r;
        });
      });
      const readers = new Readers(dir, 1);
      const beforePids = new Set(MbProcess.live().map((p) => p.pid));
      const readP = readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
      await probeStarted.promise;
      readers.close();
      releaseProbe(new Set(["data"]));
      await assert.rejects(readP, /station stopping|reader stopped/);
      await nextTick();
      const newProcs = MbProcess.live().filter((p) => !beforePids.has(p.pid) && p.args.includes(dir));
      assert.equal(newProcs.length, 0, "close during probe must not spawn orphan child");
      resetReaderSelectionStateForTest();
    });

    // 3. Cooldown / probe failure on Pion-only host: cleanly rejects waiters without uncaught throw
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: "pion" }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      setPionProbeRunnerForTest(async () => null);
      const readers = new Readers(dir, 1);
      try {
        await assert.rejects(readers.read("latestMessages", { thread: 1, limit: 1 }, "en"), /stillfail-reader|reader stopped/);
        readers.warm(); // must not throw
        await assert.rejects(readers.read("latestMessages", { thread: 1, limit: 1 }, "en"), /stillfail-reader/);
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
      }
    });

    // 4. Unsupported mode on Pion-only host: cleanly rejects without uncaught throw
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: "pion" }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      setPionProbeRunnerForTest(async () => new Set(["footprint"]));
      const readers = new Readers(dir, 1);
      try {
        await assert.rejects(readers.read("latestMessages", { thread: 1, limit: 1 }, "en"), /stillfail-reader|reader stopped/);
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
      }
    });

    // 5. Busy non-retiring slot present on the same line when start() fails for slot 2:
    //    queued waiter waits for busy slot instead of immediate false reject
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_ENGINE: undefined }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      const probeStarted = Promise.withResolvers<void>();
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      setPionProbeRunnerForTest(() => {
        probeStarted.resolve();
        return new Promise((r) => {
          releaseProbe = r;
        });
      });
      let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
      const readers = new Readers(dir, 2, undefined, 1, { readers: () => cfg });
      try {
        const p1 = readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
        await probeStarted.promise;
        // Temporarily switch config to unavailable MB so start() for slot 2 on `moved` fails while slot 1 is busy & non-retiring
        cfg = { readers: { data: "mb" } };
        const p2 = readers.read("latestMessages", { thread: 2, limit: 1 }, "en");
        let p2RejectedEarly = false;
        p2.catch(() => {
          p2RejectedEarly = true;
        });
        await nextTick();
        assert.equal(p2RejectedEarly, false, "queued waiter must not be rejected while a non-retiring busy slot exists");
        // Restore valid Pion config and release probe -> slot 1 completes p1 and then serves p2 cleanly
        cfg = { readers: { data: "pion" } };
        releaseProbe(new Set(["data"]));
        const [r1, r2] = await Promise.all([p1, p2]);
        assert.equal(JSON.parse(r1).tag, "pion-a");
        assert.equal(JSON.parse(r2).tag, "pion-a");
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
      }
    });
  });

  rmSync(dir, { recursive: true, force: true });
});

test("OwnReader: async resolveReaderSelectionAsync, shared startup, close-during-probe, and hot switch", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-own-reader-"));
  const pionStub = makeStubReaderScript(dir, "own-pion", "own-pion");
  const mbStub = makeStubReaderScript(dir, "own-mb", "own-mb");
  resetReaderSelectionStateForTest();

  await withMutableModeFlag("data", true, async () => {
    // 1. Cold-start pending -> ready + shared startup + hot config switch
    await withEnv({ STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_ENGINE: undefined }, async () => {
      setMbReaderBinaryOverrideForTest(() => mbStub);
      const probeStarted = Promise.withResolvers<void>();
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      let probeCalls = 0;
      setPionProbeRunnerForTest(() => {
        probeCalls++;
        probeStarted.resolve();
        return new Promise((r) => {
          releaseProbe = r;
        });
      });

      let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
      const own = new OwnReader(() => cfg);
      try {
        const p1 = own.tailRead("claude", { path: "/tmp/a.jsonl" });
        const p2 = own.tailRead("claude", { path: "/tmp/b.jsonl" });
        await probeStarted.promise;
        assert.equal(probeCalls, 1);
        releaseProbe(new Set(["data"]));
        const [r1, r2] = await Promise.all([p1, p2]);
        assert.equal((r1 as unknown as { tag: string }).tag, "own-pion");
        assert.equal((r2 as unknown as { tag: string }).tag, "own-pion");

        cfg = { readers: { data: "mb" } };
        const r3 = await own.tailRead("claude", { path: "/tmp/c.jsonl" });
        assert.equal((r3 as unknown as { tag: string }).tag, "own-mb");
      } finally {
        await own.close();
        resetReaderSelectionStateForTest();
      }
    });

    // 2. Close during pending probe rejects cleanly and spawns zero processes
    await withEnv({ STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: "pion" }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      const probeStarted = Promise.withResolvers<void>();
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      setPionProbeRunnerForTest(() => {
        probeStarted.resolve();
        return new Promise((r) => {
          releaseProbe = r;
        });
      });
      const own = new OwnReader();
      const beforePids = new Set(MbProcess.live().map((p) => p.pid));
      const p = own.tailRead("claude", { path: "/tmp/d.jsonl" });
      await probeStarted.promise;
      const closeP = own.close();
      releaseProbe(new Set(["data"]));
      await assert.rejects(p, /live view is closed/);
      await closeP;
      await nextTick();
      const spawned = MbProcess.live().filter((x) => !beforePids.has(x.pid) && x.binary === pionStub);
      assert.equal(spawned.length, 0);
      resetReaderSelectionStateForTest();
    });
  });

  rmSync(dir, { recursive: true, force: true });
});

test("Served: restart async resolveBinary, resolve failure backoff, sync spawn throw (0 unhandledRejection), and close-during-resolve", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-served-"));
  class FakeProc extends EventEmitter implements ServingProcess {
    readonly binary: string;
    terminated = false;
    constructor(binary: string) {
      super();
      this.binary = binary;
    }
    postMessage(_msg: unknown) {}
    terminate(): Promise<number> {
      this.terminated = true;
      return Promise.resolve(0);
    }
  }

  const spawned: FakeProc[] = [];
  let nowMs = 10_000;
  const timers: Array<{ ms: number; f: () => void }> = [];
  let resolveNext!: (bin: string) => void;
  let resolveDone = Promise.withResolvers<void>();
  let mode: "ok" | "defer" | "fail" = "ok";
  let throwOnNextSpawn = false;
  let nextBin = "/bin/pion-serve";

  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);

  const served = new Served(
    "/bin/mb-serve",
    dir,
    async () => ({ status: 200, headers: {}, body: Buffer.alloc(0) }),
    () => {},
    undefined,
    {
      spawn: (bin, args) => {
        if (throwOnNextSpawn) {
          throwOnNextSpawn = false;
          throw new Error("simulated sync spawn failure");
        }
        const p = new FakeProc(bin);
        spawned.push(p);
        const sockPath = args[args.indexOf("--serve") + 1]!;
        queueMicrotask(() => p.emit("message", { listening: sockPath }));
        return p;
      },
      now: () => nowMs,
      after: (ms, f) => {
        const item = { ms, f };
        timers.push(item);
        return () => {
          const idx = timers.indexOf(item);
          if (idx >= 0) timers.splice(idx, 1);
        };
      },
      resolveBinary: () => {
        if (mode === "ok") {
          const p = Promise.resolve(nextBin);
          void p.finally(() => resolveDone.resolve());
          return p;
        }
        if (mode === "fail") {
          const p = Promise.reject(new Error("probe failed"));
          void p.catch(() => {}).finally(() => resolveDone.resolve());
          return p;
        }
        return new Promise<string>((res) => {
          resolveNext = (v) => {
            res(v);
            resolveDone.resolve();
          };
        });
      },
    },
  );

  try {
    const paths = await served.start();
    assert.equal(paths.length, 2);
    assert.equal(spawned.length, 2);
    assert.equal(spawned[0]!.binary, "/bin/mb-serve");

    // 1. Steady exit triggers immediate async re-selection to /bin/pion-serve
    resolveDone = Promise.withResolvers<void>();
    nowMs += SERVED_STEADY_MS + 100;
    spawned[0]!.emit("exit", 1);
    await resolveDone.promise;
    await nextTick();
    assert.equal(spawned.length, 3);
    assert.equal(spawned[2]!.binary, "/bin/pion-serve");

    // 2. Astra P1-2: resolveBinary succeeds, but #start/spawn throws synchronously -> 0 unhandledRejection + SERVED_AGAIN_MS backoff
    resolveDone = Promise.withResolvers<void>();
    throwOnNextSpawn = true;
    nowMs += SERVED_STEADY_MS + 100;
    const timersBeforeSyncThrow = timers.length;
    spawned[2]!.emit("exit", 1);
    await resolveDone.promise;
    await nextTick();
    assert.equal(unhandled.length, 0, "sync throw in Served restart must never cause unhandledRejection");
    assert.equal(timers.length, timersBeforeSyncThrow + 1, "sync spawn throw must schedule backoff retry");
    assert.equal(timers[timers.length - 1]!.ms, SERVED_AGAIN_MS);
    // Firing the backoff timer recovers cleanly
    resolveDone = Promise.withResolvers<void>();
    timers.pop()!.f();
    await resolveDone.promise;
    await nextTick();
    assert.equal(spawned.length, 4);
    assert.equal(spawned[3]!.binary, "/bin/pion-serve");

    // 3. Resolve failure falls back to SERVED_AGAIN_MS timer
    resolveDone = Promise.withResolvers<void>();
    mode = "fail";
    nowMs += SERVED_STEADY_MS + 100;
    const timersBefore = timers.length;
    spawned[1]!.emit("exit", 1);
    await resolveDone.promise;
    await nextTick();
    assert.equal(spawned.length, 4, "failed resolve must not spawn");
    assert.equal(timers.length, timersBefore + 1, "failed resolve must schedule backoff timer");
    assert.equal(timers[timers.length - 1]!.ms, SERVED_AGAIN_MS);

    // 4. Close during pending resolveBinary spawns ZERO orphan
    resolveDone = Promise.withResolvers<void>();
    mode = "defer";
    const retry = timers.pop()!;
    retry.f();
    await served.close();
    resolveNext("/bin/orphan-serve");
    await resolveDone.promise;
    await nextTick();
    assert.equal(spawned.length, 4, "close during resolveBinary must not spawn orphan");
    assert.equal(unhandled.length, 0);
  } finally {
    process.off("unhandledRejection", onUnhandled);
    await served.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("MeshLive + Served DI: opposite data/serve engines, explicit mbReader passthrough, and reference mode", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-mesh-di-"));
  const pionStub = makeStubReaderScript(dir, "pion-dual", "pion", { serve: true });
  const mbStub = makeStubReaderScript(dir, "mb-dual", "mb", { serve: true });
  const explicitStub = makeStubReaderScript(dir, "explicit-serve", "explicit", { serve: true });
  resetReaderSelectionStateForTest();

  async function runMeshCase(
    readers: Readers,
    readerCfg: ReaderSelectConfig | undefined,
    expectRouted: boolean,
  ): Promise<{ routedCalls: number; serveBinaries: string[] }> {
    const cloudDir = mkdtempSync(join(dir, "cloud-"));
    const mesh = memoryMesh();
    const store = DbStore.open(":memory:");
    const routed = Promise.withResolvers<void>();
    const accepting = Promise.withResolvers<void>();
    let routedCalls = 0;
    const cloud = {
      state: { workspace_name: "ws" },
      data: cloudDir,
      relays: () => [],
      memberships: () => [],
      fullMemberships: () => [],
      rigIn: () => null,
      peersCurrent: false,
      listen: () => () => {},
      toolCalls: null,
      removed: () => false,
    };
    const inputs = Layer.mergeAll(
      Layer.succeed(MeshSide)({ net: new Net(), peers: { route: null }, outside: null, forwarded: () => false, runtimes: () => [], device: null }),
      Layer.succeed(Previous)({ pid: null, gone: Promise.resolve(), exited: Promise.resolve() }),
      Layer.succeed(Own)({ paths: () => [] } as never),
      Layer.succeed(Peers)({ attach: () => {} } as never),
      Layer.succeed(Parts)(new StationParts()),
      Layer.succeed(Paths)({ data: dir, app: dir }),
      Layer.succeed(StationConfig)({ raw: () => ({}), listen: () => () => {} } as never),
      Layer.succeed(ReaderConfig)(() => readerCfg),
      Layer.succeed(ControlPlane)({
        state: cloud,
        changes: Stream.never,
        presence: Effect.never,
        spec: () => ({ name: "still.fail cloud", tools: false }),
        credential: () => undefined,
      } as never),
      Layer.succeed(Key)(new StationKey(Buffer.alloc(32))),
      Layer.succeed(MeshNative)({
        bind: async (options: Parameters<Mesh["bind"]>[0]) => {
          const endpoint = await mesh.bind(options);
          endpoint.online = () => new Promise<void>(() => {});
          endpoint.route = async (_alpn: Buffer, _paths: string[], _routes: string[]) => {
            routedCalls++;
            routed.resolve();
            return true;
          };
          const accept = endpoint.accept.bind(endpoint);
          endpoint.accept = () => {
            accepting.resolve();
            return accept();
          };
          return endpoint;
        },
      } as unknown as Mesh),
      Layer.succeed(Store)(store),
      Layer.succeed(AdminApi)({ readers, claimSay: () => Promise.resolve(null), saidElsewhere: () => {} } as never),
      Layer.succeed(Events)({ tell: () => {} } as never),
      Layer.succeed(Up)(Effect.runSync(SubscriptionRef.make(true))),
      Layer.succeed(ScreenRegistry)(null!),
      RigSide.layer,
    );
    const fiber = Effect.runFork(
      Effect.scoped(
        Effect.gen(function* () {
          yield* Layer.build(MeshLive.pipe(Layer.provide(inputs)));
          yield* Effect.never;
        }),
      ),
    );
    try {
      await accepting.promise;
      if (expectRouted) await routed.promise;
      const serveBinaries = MbProcess.live()
        .filter((p) => p.args.includes("--serve") && p.args.includes(readers.data))
        .map((p) => p.binary);
      return { routedCalls, serveBinaries };
    } finally {
      await Effect.runPromise(Fiber.interrupt(fiber));
      store.close();
      rmSync(cloudDir, { recursive: true, force: true });
    }
  }

  await withMutableModeFlag("data", true, async () => {
    await withMutableModeFlag("serve", true, async () => {
      await withEnv(
        { STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_SERVE: undefined, STILLFAIL_READER_ENGINE: undefined },
        async () => {
          setMbReaderBinaryOverrideForTest(() => mbStub);
          setPionProbeRunnerForTest(async () => new Set(["data", "serve"]));

          // Case A: opposite engines -> data=pion, serve=mb
          const cfgA: ReaderSelectConfig = { readers: { data: "pion", serve: "mb" } };
          const readersA = new Readers(join(dir, "case-a"), 1, undefined, 1, { readers: () => cfgA });
          try {
            const readRes = JSON.parse(await readersA.read("latestMessages", { thread: 1, limit: 1 }, "en"));
            assert.equal(readRes.tag, "pion");
            const meshA = await runMeshCase(readersA, cfgA, true);
            assert.ok(meshA.routedCalls >= 1);
            assert.equal(meshA.serveBinaries.length, 2);
            assert.ok(meshA.serveBinaries.every((b) => b === mbStub), `expected serve to spawn mbStub, got ${meshA.serveBinaries}`);
          } finally {
            readersA.close();
          }

          // Case B: explicit mbReader override passthrough -> Served spawns explicitStub
          const readersB = Object.assign(new Readers(join(dir, "case-b"), 1), { mbReader: explicitStub });
          try {
            const meshB = await runMeshCase(readersB, { readers: { serve: "pion" } }, true);
            assert.ok(meshB.routedCalls >= 1);
            assert.equal(meshB.serveBinaries.length, 2);
            assert.ok(meshB.serveBinaries.every((b) => b === explicitStub), `expected explicit override passthrough, got ${meshB.serveBinaries}`);
          } finally {
            readersB.close();
          }

          // Case C: reference mode (readers.mbReader === null) -> Served never spawned, route never called
          const readersC = new Readers(join(dir, "case-c"), 1, () => new EventEmitter() as never);
          try {
            assert.equal(readersC.mbReader, null);
            const meshC = await runMeshCase(readersC, { readers: { serve: "pion" } }, false);
            assert.equal(meshC.routedCalls, 0);
            assert.equal(meshC.serveBinaries.length, 0);
          } finally {
            readersC.close();
          }

          // Case D: flip opposite engines -> data=mb, serve=pion
          const cfgD: ReaderSelectConfig = { readers: { data: "mb", serve: "pion" } };
          const dataSel = await resolveReaderSelectionAsync("data", { config: cfgD });
          const serveSel = await resolveReaderSelectionAsync("serve", { config: cfgD });
          assert.equal(dataSel.engine, "mb");
          assert.equal(serveSel.engine, "pion");

          resetReaderSelectionStateForTest();
        },
      );
    });
  });

  rmSync(dir, { recursive: true, force: true });
});

/// Strip `//` and `/* ... */` comments from Pion source while respecting `"..."` string literals
/// (so URLs like `"https://example.com"` inside strings never truncate the rest of the line).
function stripPionCommentsLexical(source: string): string {
  let out = "";
  let i = 0;
  const n = source.length;
  while (i < n) {
    const ch = source[i]!;
    if (ch === '"') {
      out += ch;
      i++;
      while (i < n) {
        const c = source[i]!;
        out += c;
        i++;
        if (c === "\\" && i < n) {
          out += source[i]!;
          i++;
          continue;
        }
        if (c === '"') break;
      }
      continue;
    }
    if (ch === "/" && source[i + 1] === "/") {
      while (i < n && source[i] !== "\n") i++;
      continue;
    }
    if (ch === "/" && source[i + 1] === "*") {
      i += 2;
      while (i < n && !(source[i] === "*" && source[i + 1] === "/")) {
        if (source[i] === "\n") out += "\n";
        i++;
      }
      if (i < n) i += 2;
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

function walkPionFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkPionFiles(full));
    else if (entry.name.endsWith(".pion")) out.push(full);
  }
  return out;
}

function findForbiddenShellCalls(source: string): string[] {
  const forbidden = [
    /\bshell_call_wait\b/,
    /\bshell_call_wait_with\b/,
    /\bread_bytes_range\b/,
    /\bwrite_atomic\b/,
    /\bhost_shim::wait\b/,
    /\bhost_shim::shell_call\b/,
    /\bbuilders_usage::(?:unpacked|read_from|packed_from|parts_of|anchor_at|first_line)\b/,
  ];
  const stripped = stripPionCommentsLexical(source);
  const hits: string[] = [];
  const lines = stripped.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    for (const pat of forbidden) {
      if (pat.test(line)) hits.push(`line ${i + 1}: ${pat}`);
    }
  }
  return hits;
}

test("Static guard: recursive lexical scan forbids blocking shell ops & raw host_shim wait/call in front/readops_*/reader_*", () => {
  // Lexical counter-example self-tests:
  assert.ok(
    findForbiddenShellCalls('let u = "https://example.com"; shell_call_wait(x)').length === 1,
    "URL string literal before forbidden call must NOT hide the call",
  );
  assert.equal(findForbiddenShellCalls("// shell_call_wait(x)\n/* host_shim::wait(0) */\nlet ok = 1").length, 0);
  assert.ok(findForbiddenShellCalls("let _ = shell_call_wait_with(c, op, j, None)").length === 1);
  assert.ok(findForbiddenShellCalls("let _ = host_shim::wait(10)").length === 1);
  assert.ok(findForbiddenShellCalls("let _ = host_shim::shell_call(id, op, j, None)").length === 1);
  assert.ok(findForbiddenShellCalls("let _ = builders_usage::unpacked(sh, p)").length === 1);
  assert.ok(findForbiddenShellCalls("let _ = builders_usage::read_from(sh, p, 0)").length === 1);

  const pkgRoot = join(REPO_ROOT, "pion", "station", "packages");
  const guardedPkgs = readdirSync(pkgRoot).filter(
    (name) => name === "front" || name.startsWith("readops_") || name.startsWith("reader_"),
  );
  assert.ok(guardedPkgs.includes("front"));
  assert.ok(guardedPkgs.includes("readops_core"));
  assert.ok(guardedPkgs.includes("reader_data"));
  assert.ok(guardedPkgs.includes("reader_serve"));

  for (const pkg of guardedPkgs) {
    const files = walkPionFiles(join(pkgRoot, pkg, "src"));
    for (const fullPath of files) {
      const hits = findForbiddenShellCalls(readFileSync(fullPath, "utf8"));
      assert.deepStrictEqual(hits, [], `Forbidden shell call in ${fullPath}`);
    }
  }
});
