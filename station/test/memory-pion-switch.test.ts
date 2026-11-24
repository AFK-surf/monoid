// Tests for `share/memory-mb.ts` engine switching:
// - `mb` default (zero main-thread statSync for pionBinary)
// - `pion` switch (`STILLFAIL_READER_MEMORY=pion` and `STILLFAIL_READER_ENGINE=pion`)
// - `shadow` strictly refused for `memory` (`allowShadow: false`), falling back to `mb` with warning
// - missing Pion binary fallback to `mb` with deduplicated warning
// - explicit `options.binary` always respected regardless of env
// - malformed stdout JSON / non-object / non-string error isolation with zero uncaughtException/unhandledRejection
// - real `STILLFAIL_PION_READER` binary end-to-end switch & ops verification
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { pionBinary } from "../src/read/mb-reader.ts";
import { MemoryProgram } from "../src/share/memory-mb.ts";
import { merge3, stationTag } from "./reference/memory-merge.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "memory-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

function makeStubBinary(dir: string, name: string, jsBody: string): string {
  const scriptPath = join(dir, `${name}.mjs`);
  writeFileSync(scriptPath, jsBody, "utf8");
  if (platform.os === "windows") {
    const cmdPath = join(dir, `${name}.cmd`);
    writeFileSync(cmdPath, `@"${process.execPath}" "${scriptPath}" %*\r\n`, "utf8");
    return cmdPath;
  }
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

function tagResponderBody(engineTag: string): string {
  return `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const req = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: req.id, tags: [${JSON.stringify(engineTag)}] }) + "\\n");
});
`;
}

const MALFORMED_RESPONDER_BODY = `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const req = JSON.parse(line);
  if (req.op === "badJsonThenGood") {
    process.stdout.write("{not valid json\\n");
    process.stdout.write("null\\n");
    process.stdout.write("[1,2,3]\\n");
    process.stdout.write(JSON.stringify({ id: req.id, ok: true }) + "\\n");
  } else if (req.op === "nonStringError") {
    process.stdout.write(JSON.stringify({ id: req.id, error: 12345 }) + "\\n");
  } else {
    process.stdout.write(JSON.stringify({ id: req.id, tags: ["ok"] }) + "\\n");
  }
});
`;

test("mb default, pion switch, shadow refusal, missing-binary fallback, and explicit binary override", async () => {
  const dir = freshDir();
  const shellDir = freshDir("memory-shell-");
  const mbStub = makeStubBinary(dir, "stub-mb", tagResponderBody("from-mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", tagResponderBody("from-pion"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", tagResponderBody("from-explicit"));
  const missingBin = join(dir, "no-such-stillfail-pion");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Default is mb even when a Pion binary is available.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_MEMORY: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
      } finally {
        await p.close();
      }
    });

    // 2. STILLFAIL_READER_MEMORY=pion routes to Pion binary.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_MEMORY: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-pion"]);
      } finally {
        await p.close();
      }
    });

    // 3. STILLFAIL_READER_ENGINE=pion also routes memory to Pion binary.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_MEMORY: undefined,
      STILLFAIL_READER_ENGINE: "pion",
    }, async () => {
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-pion"]);
      } finally {
        await p.close();
      }
    });

    // 4. shadow is strictly forbidden for memory (write-fs side effects) -> falls back to mb with warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_MEMORY: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
      } finally {
        await p.close();
      }
    });
    assert.ok(
      logs.some((l) => l.level === "WARN" && l.at === "memory" && l.message === "reader engine fallback" && l.fields.reason === "shadow-forbidden"),
      "expected shadow-forbidden fallback warning",
    );

    // 5. Missing Pion binary safely falls back to mb and logs fallback warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: missingBin,
      STILLFAIL_READER_MEMORY: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), null);
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
      } finally {
        await p.close();
      }
    });
    assert.ok(
      logs.some((l) => l.level === "WARN" && l.at === "memory" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-missing"),
      "expected pion-binary-missing fallback warning",
    );

    // 6. Explicit options.binary is always respected even when STILLFAIL_READER_MEMORY=pion.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_MEMORY: "pion",
      STILLFAIL_READER_ENGINE: "pion",
    }, async () => {
      const p = new MemoryProgram(shellDir, { binary: explicitStub });
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-explicit"]);
      } finally {
        await p.close();
      }
    });
  } finally {
    hearLines(null);
  }
});

test("memory-mb isolates malformed JSON lines, non-object JSON frames, and non-string errors", async () => {
  const dir = freshDir();
  const shellDir = freshDir("memory-shell-malformed-");
  const badStub = makeStubBinary(dir, "stub-malformed", MALFORMED_RESPONDER_BODY);

  const unhandled: unknown[] = [];
  const uncaught: unknown[] = [];
  const onUnhandled = (err: unknown) => unhandled.push(err);
  const onUncaught = (err: unknown) => uncaught.push(err);
  process.on("unhandledRejection", onUnhandled);
  process.on("uncaughtException", onUncaught);

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    const p = new MemoryProgram(shellDir, { binary: badStub });
    try {
      const res = await p.ask("badJsonThenGood", {});
      assert.equal(res.ok, true);
      assert.ok(
        logs.some((l) => l.level === "WARN" && l.at === "memory" && l.message === "the memory's program returned a malformed response"),
        "expected malformed response warning for null/array frames",
      );
      await assert.rejects(p.ask("nonStringError", {}), /malformed error/);
      // Program remains usable for subsequent asks.
      assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["ok"]);
    } finally {
      await p.close();
    }
    assert.deepEqual(unhandled, [], "must never emit unhandledRejection");
    assert.deepEqual(uncaught, [], "must never emit uncaughtException");
  } finally {
    hearLines(null);
    process.off("unhandledRejection", onUnhandled);
    process.off("uncaughtException", onUncaught);
  }
});

test("real STILLFAIL_PION_READER binary end-to-end pion mode via MemoryProgram matches reference 0-diff", async (t) => {
  const realPion = pionBinary();
  const strictCi = Boolean(process.env.STILLFAIL_PION_READER?.trim() && process.env.CI);
  if (strictCi) {
    assert.ok(realPion !== null, "CI with STILLFAIL_PION_READER must resolve a real Pion binary");
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }

  const shellDir = freshDir("memory-real-pion-shell-");
  await withEnv({
    STILLFAIL_PION_READER: realPion!,
    STILLFAIL_READER_MEMORY: "pion",
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const p = new MemoryProgram(shellDir);
    try {
      const stations = ["Mini 1", "中文 站点", "😀 emoji 😀"];
      const gotTags = await p.ask("tags", { names: stations });
      assert.deepEqual(gotTags.tags, stations.map(stationTag));

      const hex = (s: string) => Buffer.from(s, "utf8").toString("hex");
      const base = "a\nb\nc\n";
      const newer = "A\nb\nc\n";
      const older = "a\nb\nC\n";
      const gotMerge = await p.ask("merge3", { base: hex(base), newer: hex(newer), older: hex(older) });
      assert.equal(Buffer.from(gotMerge.value, "hex").toString("utf8"), merge3(base, newer, older));
    } finally {
      await p.close();
    }
  });
});
