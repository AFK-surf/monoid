// Tests for `sessions/footprint.ts` engine switching: `mb` default, `pion` switch
// (`STILLFAIL_READER_FOOTPRINT=pion` and `STILLFAIL_READER_ENGINE=pion`), `shadow` dual-run
// (zero interference with primary, structured diff warning, shadow crash isolation, shared
// AbortSignal cleanup), and safe fallback to `mb` when the Pion binary is missing.
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { MbProcess, pionBinary } from "../src/read/mb-reader.ts";
import { measureRoom, measured, waitForShadowMeasures } from "../src/sessions/footprint.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "footprint-switch-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  tempDirs.push(dir);
  return dir;
}

/** Write a tiny executable script that speaks the `--builder footprint` 1-line JSON protocol. */
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

function responderBody(responseJson: string, delayMs = 0): string {
  return `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.once("line", () => {
  const send = () => {
    process.stdout.write(${JSON.stringify(responseJson)} + "\\n");
    process.exit(0);
  };
  if (${delayMs} > 0) setTimeout(send, ${delayMs});
  else send();
});
`;
}

const HANG_BODY = `
process.stdin.resume();
setInterval(() => {}, 10000);
`;

const CRASH_BODY = `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.once("line", () => {
  process.exit(17);
});
`;

test("mb default, pion switch (STILLFAIL_READER_FOOTPRINT & STILLFAIL_READER_ENGINE), and missing-binary fallback", async () => {
  const dir = freshDir();
  const target = freshDir("footprint-target-");
  const mbStub = makeStubBinary(dir, "stub-mb", responderBody('{"size":1024,"complete":true,"rebuild":[]}'));
  const pionStub = makeStubBinary(dir, "stub-pion", responderBody('{"size":2048,"complete":true,"rebuild":[]}'));
  const missingBin = join(dir, "no-such-stillfail-pion");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Default is mb even when a Pion binary is available.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_FOOTPRINT: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), pionStub);
      assert.equal(await measured(target), 1024);
    });

    // 2. STILLFAIL_READER_FOOTPRINT=pion routes to Pion binary.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_FOOTPRINT: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(await measured(target), 2048);
    });

    // 3. STILLFAIL_READER_ENGINE=pion also routes footprint to Pion binary.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_FOOTPRINT: undefined,
      STILLFAIL_READER_ENGINE: "pion",
    }, async () => {
      assert.equal(await measured(target), 2048);
    });

    // 4. Missing Pion binary safely falls back to mb and logs fallback warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: missingBin,
      STILLFAIL_READER_FOOTPRINT: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), null);
      assert.equal(await measured(target), 1024);
    });
    assert.ok(
      logs.some((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-missing"),
      "expected pion-binary-missing fallback warning",
    );
  } finally {
    hearLines(null);
  }
});

test("shadow mode returns primary without waiting, logs diffs & shadow crashes without unhandledRejection, and cleans up on abort", async () => {
  const dir = freshDir();
  const target = freshDir("footprint-shadow-");
  const mbStub = makeStubBinary(dir, "mb-ok", responderBody('{"size":4096,"complete":true,"rebuild":[["a",4096]]}'));
  const pionMatch = makeStubBinary(dir, "pion-match", responderBody('{"size":4096,"complete":true,"rebuild":[["a",4096]]}'));
  const pionDiff = makeStubBinary(dir, "pion-diff", responderBody('{"size":8192,"complete":true,"rebuild":[]}'));
  const pionCrash = makeStubBinary(dir, "pion-crash", CRASH_BODY);
  const mbHang = makeStubBinary(dir, "mb-hang", HANG_BODY);
  const pionHang = makeStubBinary(dir, "pion-hang", HANG_BODY);

  const unhandled: unknown[] = [];
  const onUnhandled = (err: unknown) => unhandled.push(err);
  process.on("unhandledRejection", onUnhandled);
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));

  try {
    // 1. Shadow matching primary: returns primary, zero diff warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionMatch,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const room = await measureRoom(target);
      assert.deepEqual(room, { bytes: 4096, complete: true, rebuild: [["a", 4096]] });
      await waitForShadowMeasures();
    });
    assert.equal(
      logs.filter((l) => l.message === "reader shadow diff").length,
      0,
      "matching shadow must not log diff",
    );

    // 2. Shadow mismatching primary: primary result unaffected, diff logged with structured fields.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionDiff,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const room = await measureRoom(target);
      assert.deepEqual(room, { bytes: 4096, complete: true, rebuild: [["a", 4096]] });
      await waitForShadowMeasures();
    });
    const diffLog = logs.find((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader shadow diff");
    assert.ok(diffLog, "expected reader shadow diff warning");
    assert.ok(Array.isArray(diffLog.fields.diffs) && (diffLog.fields.diffs as string[]).some((d) => d.startsWith("bytes:")));

    // 3. Shadow crash: primary succeeds, diff warning logged, zero unhandledRejection.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionCrash,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(await measured(target), 4096);
      await waitForShadowMeasures();
    });
    assert.ok(
      logs.some((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader shadow diff"),
      "shadow crash should be logged as shadow diff",
    );

    // 4. AbortSignal cancels both primary and shadow processes cleanly with zero leaks.
    // Wait for prior completed children's `close` events before sampling the baseline count.
    const waitFootprintLive = async (targetCount: number) => {
      await new Promise<void>((resolve) => {
        const check = () => {
          if (MbProcess.live().filter((p) => p.args.includes("footprint")).length === targetCount) resolve();
          else setImmediate(check);
        };
        check();
      });
    };
    await waitFootprintLive(0);
    await withEnv({
      STILLFAIL_MB_READER: mbHang,
      STILLFAIL_PION_READER: pionHang,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const ac = new AbortController();
      const pending = measured(target, ac.signal);
      assert.equal(
        MbProcess.live().filter((p) => p.args.includes("footprint")).length,
        2,
        "shadow mode must spawn both primary and shadow footprint processes",
      );
      ac.abort(new Error("aborted shadow"));
      await assert.rejects(pending, /aborted shadow/);
      await waitForShadowMeasures();
    });
    await waitFootprintLive(0);
    assert.equal(
      MbProcess.live().filter((p) => p.args.includes("footprint")).length,
      0,
      "both primary and shadow processes must be reaped after abort",
    );
    assert.deepEqual(unhandled, [], "shadow mode must never emit unhandledRejection");
  } finally {
    hearLines(null);
    process.off("unhandledRejection", onUnhandled);
  }
});
