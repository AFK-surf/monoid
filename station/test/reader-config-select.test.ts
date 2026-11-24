// Tests for Wave 4-D' unified reader selection, Pion capability gate (static table + async `--version` probe),
// permissive `config.json` `readers` validation, live in-memory config snapshots, and hot-reload on next spawn.
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { checkConfig } from "../src/accounts/check.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import {
  parsePionVersionModes,
  pionBinary,
  pionSupportedModes,
  probePionSupportedModes,
  resetReaderSelectionStateForTest,
  resolveReaderSelection,
} from "../src/read/mb-reader.ts";
import { resolveReaderEngine } from "../src/read/reader-select.ts";
import { RequestedBuilder } from "../src/read/requested-builder.ts";
import { makeReaderConfigSnapshot } from "../src/services.ts";
import { measureRoom } from "../src/sessions/footprint.ts";
import { PackedProgram, runPackedOnce } from "../src/sessions/packed-mb.ts";
import { MemoryProgram } from "../src/share/memory-mb.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "reader-config-select-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

const skipPosixStubs = platform.os === "windows" ? "POSIX shell stubs are not directly spawnable without shell: true on Windows" : false;

function makeStubBinary(dir: string, name: string, jsBody: string): string {
  const scriptPath = join(dir, `${name}.mjs`);
  writeFileSync(scriptPath, jsBody, "utf8");
  const shPath = join(dir, name);
  writeFileSync(shPath, `#!/bin/sh\nexec "${process.execPath}" "${scriptPath}" "$@"\n`, "utf8");
  chmodSync(shPath, 0o755);
  return shPath;
}

async function withEnv<T>(overrides: Record<string, string | undefined>, fn: () => Promise<T>): Promise<T> {
  const saved = new Map<string, string | undefined>();
  for (const [k, v] of Object.entries(overrides)) {
    saved.set(k, process.env[k]);
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return await fn();
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

function versionAndTagStubBody(versionLine: string, tag: string, recordFile?: string): string {
  const recordSnippet = recordFile
    ? `import { appendFileSync } from "node:fs";\n`
    : "";
  const appendOnLine = recordFile
    ? `appendFileSync(${JSON.stringify(recordFile)}, ${JSON.stringify(`${tag}\n`)});\n`
    : "";
  return `
${recordSnippet}import { createInterface } from "node:readline";
if (process.argv.includes("--version")) {
  process.stdout.write(${JSON.stringify(versionLine)} + "\\n");
  process.exit(0);
}
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  ${appendOnLine}if (ask.op) {
    process.stdout.write(JSON.stringify({ id: ask.id, tag: ${JSON.stringify(tag)}, tags: [${JSON.stringify(tag)}] }) + "\\n");
  } else if ("path" in ask) {
    process.stdout.write(JSON.stringify({ size: ${tag === "pion" ? 2048 : 1024}, complete: true, rebuild: [] }) + "\\n");
    process.exit(0);
  } else {
    process.stdout.write(JSON.stringify({ done: true }) + "\\n");
  }
});
`;
}

test("precedence matrix: per-mode env > config.readers[mode] > global env > mb", () => {
  // 1. Default -> mb
  assert.equal(resolveReaderEngine("packed", { config: undefined, env: {}, hasPionBinary: true }).engine, "mb");
  // 2. Global env -> pion
  const globalOnly = resolveReaderEngine("packed", {
    config: undefined,
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(globalOnly.engine, "pion");
  assert.equal(globalOnly.source, "env");
  // 3. config.readers[mode] overrides global env
  const configWins = resolveReaderEngine("packed", {
    config: { readers: { packed: "mb" } },
    env: { STILLFAIL_READER_ENGINE: "pion" },
    hasPionBinary: true,
  });
  assert.equal(configWins.engine, "mb");
  assert.equal(configWins.source, "config");
  const configPionWins = resolveReaderEngine("memory", {
    config: { readers: { memory: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "mb" },
    hasPionBinary: true,
  });
  assert.equal(configPionWins.engine, "pion");
  assert.equal(configPionWins.source, "config");
  // 4. Per-mode env overrides config.readers[mode] and global env
  const perModeWins = resolveReaderEngine("packed", {
    config: { readers: { packed: "pion" } },
    env: { STILLFAIL_READER_ENGINE: "pion", STILLFAIL_READER_PACKED: "mb" },
    hasPionBinary: true,
  });
  assert.equal(perModeWins.engine, "mb");
  assert.equal(perModeWins.source, "env");
  // 5. Non-object config.readers (array/primitive) is ignored cleanly
  for (const badReaders of [["pion"], "pion", 42, true] as unknown[]) {
    const sel = resolveReaderEngine("packed", {
      config: { readers: badReaders as Record<string, unknown> },
      env: {},
      hasPionBinary: true,
    });
    assert.equal(sel.engine, "mb");
    assert.equal(sel.source, "default");
    assert.equal(sel.fallback, false);
  }
});

test("checkConfig never rejects invalid/unknown/non-object readers so unrelated ConfigFile.update succeeds (Opus P1-b)", () => {
  for (const readersValue of [
    { footprint: "not-a-valid-engine", "unknown-future-mode": "pion", packed: 123 },
    "pion",
    42,
    ["footprint"],
    null,
  ]) {
    const dir = freshDir("config-readers-");
    writeFileSync(join(dir, "config.json"), JSON.stringify({ language: "zh", readers: readersValue }, null, 2), "utf8");
    const cfg = new ConfigFile(dir);
    cfg.check = checkConfig;

    // Updating an unrelated setting (language / channel) must succeed 100% without throwing.
    const updated = cfg.update((raw) => {
      raw.language = "en";
      raw.channel = "beta";
    });
    assert.equal(updated.language, "en");
    assert.equal(updated.channel, "beta");
    assert.deepEqual(updated.readers, readersValue);
  }
});

test("same PackedProgram, MemoryProgram, and RequestedBuilder hot-switch from mb to pion on next spawn without disrupting in-flight work (Astra P1-1)", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("hot-switch-");
  const cfgDir = freshDir("hot-switch-cfg-");
  const shellDir = freshDir("hot-switch-shell-");
  const targetDir = freshDir("hot-switch-target-");
  const builderLog = join(dir, "builder-spawns.txt");

  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb-reader 1.0", "mb", builderLog));
  const pionStub = makeStubBinary(dir, "stub-pion", versionAndTagStubBody("stillfail-pion 0.1.0 modes:footprint,packed,memory", "pion", builderLog));

  // A stub that pauses its first response until released so we prove in-flight requests finish on the original mb child.
  const gateFile = join(dir, "release-gate");
  const gatedMbStub = makeStubBinary(
    dir,
    "stub-mb-gated",
    `
import { existsSync, watch } from "node:fs";
import { dirname, basename } from "node:path";
import { createInterface } from "node:readline";
const gate = ${JSON.stringify(gateFile)};
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  const reply = () => {
    process.stdout.write(JSON.stringify({ id: ask.id, tag: "mb", tags: ["mb"] }) + "\\n");
  };
  if (ask.op === "wait-gate" && !existsSync(gate)) {
    const w = watch(dirname(gate), () => {
      if (existsSync(gate)) { w.close(); reply(); }
    });
    if (existsSync(gate)) { w.close(); reply(); }
  } else {
    reply();
  }
});
`,
  );

  const cfg = new ConfigFile(cfgDir);
  cfg.check = checkConfig;
  const snap = makeReaderConfigSnapshot(cfg);

  try {
    await withEnv({
      STILLFAIL_MB_READER: gatedMbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: undefined,
      STILLFAIL_READER_MEMORY: undefined,
      STILLFAIL_READER_FOOTPRINT: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      // 1. PackedProgram: start on mb, hold in-flight request, switch config to pion mid-flight,
      //    verify in-flight finishes on mb, then trimIdle() -> next ask spawns pion!
      const packed = new PackedProgram({ readers: snap.get });
      try {
        assert.equal((await packed.ask<{ tag: string }>("table", {})).tag, "mb");
        assert.equal(packed.started, 1);

        const inFlight = packed.ask<{ tag: string }>("wait-gate", {});
        // Hot-update config.json while in-flight request is still running on mb.
        await cfg.updateSoon((raw) => {
          raw.readers = { packed: "pion", memory: "pion", footprint: "pion" };
        });
        assert.equal(snap.get()?.readers?.packed, "pion");

        // Release gate -> in-flight finishes cleanly on mb.
        writeFileSync(gateFile, "go", "utf8");
        assert.equal((await inFlight).tag, "mb");
        assert.equal(packed.started, 1);

        // Idle termination -> next spawn picks up pion from live config snapshot.
        assert.equal(packed.trimIdle(), 1);
        assert.equal((await packed.ask<{ tag: string }>("table", {})).tag, "pion");
        assert.equal(packed.started, 2);

        // runPackedOnce & measureRoom also observe live config snapshot on each call.
        assert.equal((await runPackedOnce<{ tag: string }>("table", {}, { readers: snap.get })).tag, "pion");
      } finally {
        await packed.close();
      }
    });

    // Reset config back to mb for MemoryProgram + footprint + RequestedBuilder tests.
    await cfg.updateSoon((raw) => {
      raw.readers = { packed: "mb", memory: "mb", footprint: "mb" };
    });

    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: undefined,
      STILLFAIL_READER_MEMORY: undefined,
      STILLFAIL_READER_FOOTPRINT: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      // 2. footprint: mb -> config update -> pion
      assert.equal((await measureRoom(targetDir, undefined, snap.get)).bytes, 1024);
      await cfg.updateSoon((raw) => {
        raw.readers = { memory: "mb", footprint: "pion" };
      });
      assert.equal((await measureRoom(targetDir, undefined, snap.get)).bytes, 2048);

      // 3. MemoryProgram: mb -> update config to pion -> trimIdle -> pion
      const mem = new MemoryProgram(shellDir, { readers: snap.get });
      try {
        assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["a"] })).tags, ["mb"]);
        assert.equal(mem.started, 1);

        await cfg.updateSoon((raw) => {
          raw.readers = { memory: "pion", footprint: "pion" };
        });
        // Still using warm mb child until idle.
        assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["b"] })).tags, ["mb"]);
        assert.equal(mem.started, 1);

        assert.equal(mem.trimIdle(), 1);
        assert.deepEqual((await mem.ask<{ tags: string[] }>("tags", { names: ["c"] })).tags, ["pion"]);
        assert.equal(mem.started, 2);
      } finally {
        await mem.close();
      }

      // 4. RequestedBuilder with dynamic `binary: () => string`: mb -> update config -> trimIdle -> pion
      await cfg.updateSoon((raw) => {
        raw.readers = { "session-counts": "mb" };
      });
      const builder = new RequestedBuilder<string>(
        { readers: snap.get },
        {
          binary: () => (snap.get()?.readers?.["session-counts"] === "pion" ? pionStub : mbStub),
          args: ["--builder", "session-counts", "--db", join(dir, "fake.db")],
        },
        "scope",
        "test dynamic builder",
      );
      try {
        await builder.ready(["one"]);
        await cfg.updateSoon((raw) => {
          raw.readers = { "session-counts": "pion" };
        });
        assert.equal(builder.trimIdle(), true);
        await builder.ready(["two"]);
      } finally {
        await builder.close();
      }

      const lines = readFileSync(builderLog, "utf8").trim().split("\n").filter(Boolean);
      assert.deepEqual(lines.slice(-2), ["mb", "pion"]);
    });
  } finally {
    snap.stop();
  }
});

test("old stillfail-pion binary capability probe: baseline 3 modes work, unannounced SQL mode falls back to mb with deduped warn and no restart loop (Astra P1-2)", { skip: skipPosixStubs }, async () => {
  resetReaderSelectionStateForTest();
  const dir = freshDir("cap-probe-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb-reader 1.0", "mb"));
  const oldPionStub = makeStubBinary(dir, "stub-pion-old", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));
  const partialPionStub = makeStubBinary(
    dir,
    "stub-pion-partial",
    versionAndTagStubBody("stillfail-pion 0.2.0 modes:footprint,packed,memory", "pion"),
  );
  const newPionStub = makeStubBinary(
    dir,
    "stub-pion-new",
    versionAndTagStubBody("stillfail-pion 0.3.0 modes:footprint,packed,memory,session-counts", "pion"),
  );

  // Unit check of parser
  assert.deepEqual([...parsePionVersionModes("stillfail-pion 0.1.0")].sort(), ["footprint", "memory", "packed"]);
  assert.deepEqual(
    [...parsePionVersionModes("stillfail-pion 0.3.0 modes:footprint,packed,memory,session-counts")].sort(),
    ["footprint", "memory", "packed", "session-counts"],
  );

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Old binary without `modes:` in `--version`:
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: oldPionStub,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      // Baseline 3 modes work immediately with zero probe.
      for (const mode of ["footprint", "packed", "memory"] as const) {
        const res = resolveReaderSelection(mode, {
          config: { readers: { [mode]: "pion" } },
          env: {},
        });
        assert.equal(res.engine, "pion");
        assert.equal(res.primaryBinary, oldPionStub);
      }

      // First call for a new SQL mode (with pionImplemented: true) triggers non-blocking async probe and safely runs mb.
      const first = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
        logAt: "cap-test",
      });
      assert.equal(first.engine, "mb");
      assert.equal(first.primaryBinary, mbStub);

      // Await probe completion deterministically.
      const supported = await probePionSupportedModes(oldPionStub);
      assert.equal(supported.has("footprint"), true);
      assert.equal(supported.has("packed"), true);
      assert.equal(supported.has("memory"), true);
      assert.equal(supported.has("session-counts"), false);

      // Subsequent calls permanently fall back to mb with reason "pion-binary-unsupported-mode" and deduped warn.
      for (let i = 0; i < 3; i++) {
        const next = resolveReaderSelection("session-counts", {
          config: { readers: { "session-counts": "pion" } },
          env: {},
          pionImplemented: true,
          logAt: "cap-test",
        });
        assert.equal(next.engine, "mb");
        assert.equal(next.primaryBinary, mbStub);
        assert.equal(next.selection.fallback, true);
        assert.equal(next.selection.reason, "pion-binary-unsupported-mode");
      }
      const unsupportedWarns = logs.filter(
        (l) => l.level === "WARN" && l.at === "cap-test" && l.fields.reason === "pion-binary-unsupported-mode",
      );
      assert.equal(unsupportedWarns.length, 1, "expected exactly 1 deduped pion-binary-unsupported-mode warning");
    });

    // 2. Partial binary declaring only baseline modes also rejects `post-blocks`.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: partialPionStub,
    }, async () => {
      const supported = await probePionSupportedModes(partialPionStub);
      assert.equal(supported.has("post-blocks"), false);
      const res = resolveReaderSelection("post-blocks", {
        config: { readers: { "post-blocks": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(res.engine, "mb");
      assert.equal(res.selection.reason, "pion-binary-unsupported-mode");
    });

    // 3. New binary declaring `modes:footprint,packed,memory,session-counts`:
    //    safe mb while probe is in flight, then switches to pion once probe completes!
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: newPionStub,
    }, async () => {
      assert.equal(pionSupportedModes(newPionStub), null);
      const whileProbing = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(whileProbing.engine, "mb");

      const supported = await probePionSupportedModes(newPionStub);
      assert.equal(supported.has("session-counts"), true);

      const afterProbe = resolveReaderSelection("session-counts", {
        config: { readers: { "session-counts": "pion" } },
        env: {},
        pionImplemented: true,
      });
      assert.equal(afterProbe.engine, "pion");
      assert.equal(afterProbe.primaryBinary, newPionStub);
      assert.equal(afterProbe.selection.fallback, false);
    });
  } finally {
    hearLines(null);
  }
});

test("default mb does zero pionBinary() probe and explicit binary override always wins", { skip: skipPosixStubs }, async () => {
  const dir = freshDir("zero-probe-");
  const mbStub = makeStubBinary(dir, "stub-mb", versionAndTagStubBody("mb", "mb"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", versionAndTagStubBody("explicit", "explicit"));
  const deferredPion = join(dir, "deferred-pion");

  await withEnv({
    STILLFAIL_MB_READER: mbStub,
    STILLFAIL_PION_READER: deferredPion,
    STILLFAIL_READER_ENGINE: undefined,
    STILLFAIL_READER_PACKED: undefined,
  }, async () => {
    // Run resolveReaderSelection on default mb BEFORE deferredPion exists.
    const mbRes = resolveReaderSelection("packed", { config: undefined, env: {} });
    assert.equal(mbRes.engine, "mb");
    assert.equal(mbRes.primaryBinary, mbStub);

    // Explicit binary override also skips pionBinary() probe even if env requests pion.
    const explicitRes = resolveReaderSelection("packed", {
      binary: explicitStub,
      config: { readers: { packed: "pion" } },
      env: { STILLFAIL_READER_PACKED: "pion" },
    });
    assert.equal(explicitRes.primaryBinary, explicitStub);

    // Now create deferredPion: if either call above had probed pionBinary(), its negative cache would return null.
    makeStubBinary(dir, "deferred-pion", versionAndTagStubBody("stillfail-pion 0.1.0", "pion"));
    assert.equal(pionBinary(), deferredPion);
    const pionRes = resolveReaderSelection("packed", {
      config: { readers: { packed: "pion" } },
      env: {},
    });
    assert.equal(pionRes.engine, "pion");
    assert.equal(pionRes.primaryBinary, deferredPion);
  });
});
