// Wave 7 Sub-Wave 7.0 foundation tests:
// - Explicit `mbReader` override priority on `Readers` (never overridden by config/env Pion selection)
// - Pion-only cold-start (`mbReaderBinary() === null`): pending -> ready, cooldown, unsupported,
//   close-during-probe (zero orphan process), and hot-reload retiring idle slots (incl. kept slot)
// - `OwnReader`: async `resolveReaderSelectionAsync("data")`, close-during-probe, shared startup, hot switch
// - `Served` + `mesh.ts` DI: null-safe admin, reference mode, explicit override, opposite `data` vs `serve`,
//   restart async re-selection, close-during-resolve (zero orphan), resolve failure backoff
// - `LiveProgram.binary` path observability on `MbProcess.live()`
// - Static grep guard: forbid `shell_call_wait`, `read_bytes_range`, `write_atomic` in `front`/`readops_*`/`reader_*`,
//   and verify zero raw transaction SQL in `readops_core`.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
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
import { SERVED_STEADY_MS, Served, type ServingProcess } from "../src/mesh/served.ts";

const REPO_ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));

function makeStubReaderScript(dir: string, name: string, tag: string): string {
  const script = join(dir, name);
  const body = `#!/usr/bin/env node
const readline = require("node:readline");
if (process.argv.includes("--version")) {
  process.stdout.write("stillfail-pion 0.1.0 modes:footprint,packed,memory,data,serve\\n");
  process.exit(0);
}
const rl = readline.createInterface({ input: process.stdin });
process.stdout.write(JSON.stringify({ ready: { loadedMs: 1, openedMs: 1 } }) + "\\n");
rl.on("line", (line) => {
  if (!line.trim()) return;
  const ask = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: ask.id, text: JSON.stringify({ tag: ${JSON.stringify(tag)}, op: ask.op }) }) + "\\n");
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
  return Promise.resolve()
    .then(fn)
    .finally(restore);
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

test("Readers: explicit mbReader override ALWAYS wins over config/env Pion selection", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-explicit-"));
  const explicitStub = makeStubReaderScript(dir, "explicit-mb", "explicit-mb");
  const pionStub = makeStubReaderScript(dir, "pion-bin", "pion-bin");
  resetReaderSelectionStateForTest();
  await withMutableModeFlag("data", true, async () => {
    await withEnv({ STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: "pion" }, async () => {
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

test("Readers: Pion-only cold-start pending -> ready, close-during-probe, cooldown, unsupported, and hot-reload", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-pion-only-"));
  const pionStubA = makeStubReaderScript(dir, "pion-a", "pion-a");
  const mbStubB = makeStubReaderScript(dir, "mb-b", "mb-b");
  resetReaderSelectionStateForTest();

  await withMutableModeFlag("data", true, async () => {
    // 1. Pending -> ready on Pion-only host (mbReaderBinary() === null)
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_ENGINE: undefined }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      let probeCalls = 0;
      setPionProbeRunnerForTest(() => {
        probeCalls++;
        return new Promise((r) => { releaseProbe = r; });
      });

      let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
      const readers = new Readers(dir, 2, undefined, 1, { readers: () => cfg });
      try {
        // Constructor must NOT throw when mbReaderBinary() is null and mbReader is non-null identity.
        assert.ok(readers.mbReader !== null);
        assert.equal(readers.explicitMbReader, null);

        // Concurrent read while probe is pending reserves slot without throwing
        const readP = readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
        assert.equal(probeCalls, 1);
        releaseProbe(new Set(["data"]));
        const resA = JSON.parse(await readP);
        assert.equal(resA.tag, "pion-a");
        const liveA = MbProcess.live().find((p) => p.args.includes(dir));
        assert.equal(liveA?.binary, pionStubA);

        // Hot-reload: switch config to "mb" (with mbStubB available) -> idle kept slot retires and next read uses mbStubB
        setMbReaderBinaryOverrideForTest(() => mbStubB);
        cfg = { readers: { data: "mb" } };
        const resB = JSON.parse(await readers.read("latestMessages", { thread: 1, limit: 1 }, "en"));
        assert.equal(resB.tag, "mb-b");
        const liveB = MbProcess.live().find((p) => p.args.includes(dir) && p.binary === mbStubB);
        assert.ok(liveB !== undefined, "expected hot-reload to spawn mbStubB");
      } finally {
        readers.close();
        resetReaderSelectionStateForTest();
      }
    });

    // 2. Close during pending probe: rejects cleanly and spawns ZERO child processes
    await withEnv({ STILLFAIL_PION_READER: pionStubA, STILLFAIL_READER_DATA: "pion" }, async () => {
      setMbReaderBinaryOverrideForTest(() => null);
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      setPionProbeRunnerForTest(() => new Promise((r) => { releaseProbe = r; }));
      const readers = new Readers(dir, 1);
      const beforePids = new Set(MbProcess.live().map((p) => p.pid));
      const readP = readers.read("latestMessages", { thread: 1, limit: 1 }, "en");
      readers.close();
      releaseProbe(new Set(["data"]));
      await assert.rejects(readP, /station stopping|reader stopped/);
      await new Promise((r) => setTimeout(r, 30));
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
        // Second call hits cooldown synchronously in start() -> must reject cleanly, never throw uncaught
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
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      let probeCalls = 0;
      setPionProbeRunnerForTest(() => {
        probeCalls++;
        return new Promise((r) => { releaseProbe = r; });
      });

      let cfg: ReaderSelectConfig = { readers: { data: "pion" } };
      const own = new OwnReader(() => cfg);
      try {
        const p1 = own.tailRead("claude", { path: "/tmp/a.jsonl" });
        const p2 = own.tailRead("claude", { path: "/tmp/b.jsonl" });
        await new Promise((r) => setTimeout(r, 20));
        assert.equal(probeCalls, 1);
        releaseProbe(new Set(["data"]));
        const [r1, r2] = await Promise.all([p1, p2]);
        assert.equal((r1 as unknown as { tag: string }).tag, "own-pion");
        assert.equal((r2 as unknown as { tag: string }).tag, "own-pion");

        // Switch config to mb; OwnReader exits when idle so next call spawns mbStub
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
      let releaseProbe!: (modes: ReadonlySet<string> | null) => void;
      setPionProbeRunnerForTest(() => new Promise((r) => { releaseProbe = r; }));
      const own = new OwnReader();
      const beforePids = new Set(MbProcess.live().map((p) => p.pid));
      const p = own.tailRead("claude", { path: "/tmp/d.jsonl" });
      await new Promise((r) => setTimeout(r, 20));
      const closeP = own.close();
      releaseProbe(new Set(["data"]));
      await assert.rejects(p, /live view is closed/);
      await closeP;
      const spawned = MbProcess.live().filter((x) => !beforePids.has(x.pid) && x.binary === pionStub);
      assert.equal(spawned.length, 0);
      resetReaderSelectionStateForTest();
    });
  });

  rmSync(dir, { recursive: true, force: true });
});

test("Served: restart async resolveBinary, close-during-resolve (zero orphan), and resolve failure backoff", async () => {
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
  let rejectNext!: (err: Error) => void;
  let mode: "ok" | "defer" | "fail" = "ok";
  let nextBin = "/bin/pion-serve";

  const served = new Served(
    "/bin/mb-serve",
    dir,
    async () => ({ status: 200, headers: {}, body: Buffer.alloc(0) }),
    () => {},
    undefined,
    {
      spawn: (bin, args) => {
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
        if (mode === "ok") return Promise.resolve(nextBin);
        if (mode === "fail") return Promise.reject(new Error("probe failed"));
        return new Promise<string>((res, rej) => {
          resolveNext = res;
          rejectNext = rej;
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
    nowMs += SERVED_STEADY_MS + 100;
    spawned[0]!.emit("exit", 1);
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(spawned.length, 3);
    assert.equal(spawned[2]!.binary, "/bin/pion-serve");

    // 2. Resolve failure falls back to SERVED_AGAIN_MS timer (never throws uncaught)
    mode = "fail";
    nowMs += SERVED_STEADY_MS + 100;
    const timersBefore = timers.length;
    spawned[1]!.emit("exit", 1);
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(spawned.length, 3, "failed resolve must not spawn");
    assert.equal(timers.length, timersBefore + 1, "failed resolve must schedule backoff timer");

    // 3. Close during pending resolveBinary spawns ZERO orphan
    mode = "defer";
    const retry = timers.pop()!;
    retry.f();
    await served.close();
    resolveNext("/bin/orphan-serve");
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(spawned.length, 3, "close during resolveBinary must not spawn orphan");
    void rejectNext;
  } finally {
    await served.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("Independent data vs serve selection: opposite engines resolve independently", async () => {
  const dir = mkdtempSync(join(tmpdir(), "w7-data-serve-"));
  const pionStub = makeStubReaderScript(dir, "pion-dual", "pion");
  const mbStub = makeStubReaderScript(dir, "mb-dual", "mb");
  resetReaderSelectionStateForTest();

  await withMutableModeFlag("data", true, async () => {
    await withMutableModeFlag("serve", true, async () => {
      await withEnv({ STILLFAIL_PION_READER: pionStub, STILLFAIL_READER_DATA: undefined, STILLFAIL_READER_SERVE: undefined, STILLFAIL_READER_ENGINE: undefined }, async () => {
        setMbReaderBinaryOverrideForTest(() => mbStub);
        setPionProbeRunnerForTest(async () => new Set(["data", "serve"]));
        const cfg: ReaderSelectConfig = { readers: { data: "pion", serve: "mb" } };
        const dataSel = await resolveReaderSelectionAsync("data", { config: cfg });
        const serveSel = await resolveReaderSelectionAsync("serve", { config: cfg });
        assert.equal(dataSel.engine, "pion");
        assert.equal(dataSel.primaryBinary, pionStub);
        assert.equal(serveSel.engine, "mb");
        assert.equal(serveSel.primaryBinary, mbStub);

        const cfgFlip: ReaderSelectConfig = { readers: { data: "mb", serve: "pion" } };
        const dataSel2 = await resolveReaderSelectionAsync("data", { config: cfgFlip });
        const serveSel2 = await resolveReaderSelectionAsync("serve", { config: cfgFlip });
        assert.equal(dataSel2.engine, "mb");
        assert.equal(dataSel2.primaryBinary, mbStub);
        assert.equal(serveSel2.engine, "pion");
        assert.equal(serveSel2.primaryBinary, pionStub);
        resetReaderSelectionStateForTest();
      });
    });
  });

  rmSync(dir, { recursive: true, force: true });
});

test("Static guard: forbid shell_call_wait/read_bytes_range/write_atomic in front/readops_*/reader_* and raw tx SQL in readops_core", () => {
  const pkgRoot = join(REPO_ROOT, "pion", "station", "packages");
  const guardedPkgs = readdirSync(pkgRoot).filter(
    (name) => name === "front" || name.startsWith("readops_") || name.startsWith("reader_"),
  );
  assert.ok(guardedPkgs.includes("front"));
  assert.ok(guardedPkgs.includes("readops_core"));
  assert.ok(guardedPkgs.includes("reader_data"));
  assert.ok(guardedPkgs.includes("reader_serve"));

  const forbiddenWaitOps = [/\bshell_call_wait\b/, /\bread_bytes_range\b/, /\bwrite_atomic\b/];
  const rawTxSql = /"(?:BEGIN(?:\s+IMMEDIATE|\s+DEFERRED|\s+EXCLUSIVE)?|COMMIT|ROLLBACK|SAVEPOINT\s+\w+|RELEASE\s+\w+)"/i;

  for (const pkg of guardedPkgs) {
    const srcDir = join(pkgRoot, pkg, "src");
    for (const file of readdirSync(srcDir)) {
      if (!file.endsWith(".pion")) continue;
      const fullPath = join(srcDir, file);
      const lines = readFileSync(fullPath, "utf8").split("\n");
      for (let i = 0; i < lines.length; i++) {
        const code = lines[i]!.replace(/\/\/.*$/, "");
        for (const pat of forbiddenWaitOps) {
          assert.ok(
            !pat.test(code),
            `Forbidden ShellClient wait op ${pat} found in ${pkg}/src/${file}:${i + 1}`,
          );
        }
        if (pkg.startsWith("readops_")) {
          assert.ok(
            !rawTxSql.test(code),
            `Forbidden raw transaction SQL found in ${pkg}/src/${file}:${i + 1}: ${code.trim()}`,
          );
        }
      }
    }
  }
});
