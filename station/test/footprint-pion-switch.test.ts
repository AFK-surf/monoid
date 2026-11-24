// Tests for `sessions/footprint.ts` engine switching:
// - `mb` default (with zero main-thread statSync for pionBinary)
// - `pion` switch (`STILLFAIL_READER_FOOTPRINT=pion` and `STILLFAIL_READER_ENGINE=pion`)
// - `shadow` single-flight serial execution after primary completes, non-blocking primary return,
//   host hard timeout + child reap before releasing the single-flight slot, structured diff logging
//   (with summarized rebuild list and duration-noise suppression), malformed JSON frame isolation
//   with zero uncaughtException/unhandledRejection, and missing-binary fallback
// - Real `STILLFAIL_PION_READER` binary end-to-end `pion` + `shadow` test when provided.
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { MbProcess, mbReaderBinary, pionBinary } from "../src/read/mb-reader.ts";
import {
  measureRoom,
  measured,
  setShadowTimeoutForTest,
  waitForShadowMeasures,
} from "../src/sessions/footprint.ts";
import { measureRoomReference } from "./footprint-reference.ts";

const tempDirs: string[] = [];
after(() => {
  setShadowTimeoutForTest(null);
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

/** Bounded wait helper (fails loudly at deadline, never spins forever). */
async function waitUntil(pred: () => boolean, label: string, timeoutMs = 5_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!pred()) {
    if (Date.now() > deadline) assert.fail(`timed out waiting for: ${label}`);
    await new Promise<void>((r) => setTimeout(r, 10));
  }
}

function responderBody(responseJson: string, countFile?: string): string {
  const record = countFile
    ? `import { appendFileSync } from "node:fs";\nappendFileSync(${JSON.stringify(countFile)}, "1\\n");\n`
    : "";
  return `
import { createInterface } from "node:readline";
${record}const rl = createInterface({ input: process.stdin });
rl.once("line", () => {
  process.stdout.write(${JSON.stringify(responseJson)} + "\\n");
  process.exit(0);
});
`;
}

function makeHangAndRecordStub(dir: string, name: string, countFile: string): string {
  if (platform.os !== "windows") {
    const shPath = join(dir, name);
    // Pure POSIX sh avoids Node startup latency under macOS `taskpolicy -b`.
    writeFileSync(shPath, `#!/bin/sh\nprintf '1\\n' >> ${JSON.stringify(countFile)}\nexec sleep 60\n`, "utf8");
    chmodSync(shPath, 0o755);
    return shPath;
  }
  return makeStubBinary(
    dir,
    name,
    `import { appendFileSync } from "node:fs";\nappendFileSync(${JSON.stringify(countFile)}, "1\\n");\nprocess.stdin.resume();\nsetInterval(() => {}, 10000);\n`,
  );
}

function respondThenLingerBody(responseJson: string): string {
  return `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.once("line", () => {
  process.stdout.write(${JSON.stringify(responseJson)} + "\\n");
  // Deliberately stay alive after writing stdout to verify host hard-timeout reaps it.
  setInterval(() => {}, 10000);
});
`;
}

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

test("shadow mode is single-flight after primary, never blocks primary, reaps hanging/lingering shadows via hard timeout, and isolates malformed/crashing shadows", async () => {
  const dir = freshDir();
  const target = freshDir("footprint-shadow-");
  const countFile = join(dir, "shadow-starts.txt");
  const mbStub = makeStubBinary(dir, "mb-ok", responderBody('{"size":4096,"complete":true,"rebuild":[["a",4096],["b",1],["c",2],["d",3],["e",4],["f",5]]}'));
  const pionMatch = makeStubBinary(dir, "pion-match", responderBody('{"size":4096,"complete":true,"rebuild":[["a",4096],["b",1],["c",2],["d",3],["e",4],["f",5]]}'));
  const pionDiff = makeStubBinary(dir, "pion-diff", responderBody('{"size":8192,"complete":true,"rebuild":[]}'));
  const pionDuration = makeStubBinary(dir, "pion-duration", responderBody('{"size":1024,"complete":false,"reason":"duration","rebuild":[]}'));
  const pionCrash = makeStubBinary(dir, "pion-crash", CRASH_BODY);
  const pionNull = makeStubBinary(dir, "pion-null", responderBody("null"));
  const pionMalformed = makeStubBinary(dir, "pion-malformed", responderBody('{"size":"not-a-number"}'));
  const pionHang = makeHangAndRecordStub(dir, "pion-hang", countFile);
  const pionLinger = makeStubBinary(dir, "pion-linger", respondThenLingerBody('{"size":4096,"complete":true,"rebuild":[["a",4096],["b",1],["c",2],["d",3],["e",4],["f",5]]}'));

  const unhandled: unknown[] = [];
  const uncaught: unknown[] = [];
  const onUnhandled = (err: unknown) => unhandled.push(err);
  const onUncaught = (err: unknown) => uncaught.push(err);
  process.on("unhandledRejection", onUnhandled);
  process.on("uncaughtException", onUncaught);
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));

  try {
    // 1. Matching shadow: returns primary, zero diff warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionMatch,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const room = await measureRoom(target);
      assert.equal(room.bytes, 4096);
      assert.equal(room.rebuild.length, 6);
      await waitForShadowMeasures();
    });
    assert.equal(logs.filter((l) => l.message === "reader shadow diff").length, 0);

    // 2. Mismatching shadow: primary unaffected, diff logged with summarized rebuild (head <= 5).
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionDiff,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const room = await measureRoom(target);
      assert.equal(room.bytes, 4096);
      await waitForShadowMeasures();
    });
    const diffLog = logs.find((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader shadow diff");
    assert.ok(diffLog, "expected reader shadow diff warning");
    const primarySummary = diffLog.fields.primary as { rebuildSummary?: { count: number; head: unknown[] }; rebuild?: unknown };
    assert.equal(primarySummary.rebuild, undefined, "raw full rebuild array must not be dumped to log");
    assert.equal(primarySummary.rebuildSummary?.count, 6);
    assert.equal(primarySummary.rebuildSummary?.head.length, 5);

    // 3. Duration-truncated shadow suppresses diff noise.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionDuration,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal((await measureRoom(target)).bytes, 4096);
      await waitForShadowMeasures();
    });
    assert.equal(logs.filter((l) => l.message === "reader shadow diff").length, 0, "duration truncation should not warn");

    // 4. Shadow crash, JSON `null`, and malformed JSON frame: primary succeeds, zero uncaughtException/unhandledRejection.
    for (const badShadow of [pionCrash, pionNull, pionMalformed]) {
      logs.length = 0;
      await withEnv({
        STILLFAIL_MB_READER: mbStub,
        STILLFAIL_PION_READER: badShadow,
        STILLFAIL_READER_FOOTPRINT: "shadow",
        STILLFAIL_READER_ENGINE: undefined,
      }, async () => {
        assert.equal(await measured(target), 4096);
        await waitForShadowMeasures();
      });
      assert.ok(
        logs.some((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader shadow diff"),
        `expected shadow diff log for ${badShadow}`,
      );
    }

    // 5. Single-flight + non-blocking primary + host hard-timeout kill & slot release.
    setShadowTimeoutForTest(400);
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionHang,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      // (a) Primary returns immediately while the hanging shadow is still running in background.
      assert.equal(await measured(target), 4096);
      await waitUntil(() => existsSync(countFile) && readFileSync(countFile, "utf8").trim().split("\n").length === 1, "first shadow spawn");
      assert.ok(
        MbProcess.live().filter((p) => p.args.includes("footprint")).length >= 1,
        "hanging shadow must still be running after primary already returned",
      );

      // (b) Second measure while first shadow occupies the single-flight slot skips shadow completely.
      assert.equal(await measured(target), 4096);
      assert.equal(readFileSync(countFile, "utf8").trim().split("\n").length, 1, "single-flight must skip overlapping shadow");

      // (c) Host hard timeout kills the hanging shadow and releases the slot.
      await waitForShadowMeasures();
      await waitUntil(() => MbProcess.live().filter((p) => p.args.includes("footprint")).length === 0, "hanging shadow reaped");

      // Slot is now free: a subsequent measure launches a new shadow (count increments to 2).
      assert.equal(await measured(target), 4096);
      await waitForShadowMeasures();
      assert.equal(readFileSync(countFile, "utf8").trim().split("\n").length, 2, "slot must be released after hard-timeout reap");
    });

    // 6. Shadow that emits a valid JSON line then lingers without exiting is still killed at hard timeout before releasing slot.
    setShadowTimeoutForTest(400);
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionLinger,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal((await measureRoom(target)).bytes, 4096);
      await waitForShadowMeasures();
      await waitUntil(() => MbProcess.live().filter((p) => p.args.includes("footprint")).length === 0, "lingering shadow reaped");
    });

    assert.deepEqual(unhandled, [], "shadow mode must never emit unhandledRejection");
    assert.deepEqual(uncaught, [], "malformed shadow frames must never emit uncaughtException");
  } finally {
    setShadowTimeoutForTest(null);
    hearLines(null);
    process.off("unhandledRejection", onUnhandled);
    process.off("uncaughtException", onUncaught);
  }
});

test("real STILLFAIL_PION_READER binary end-to-end pion and shadow verification", async (t) => {
  const realPion = pionBinary();
  if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }
  const tree = freshDir("footprint-real-e2e-");
  mkdirSync(join(tree, "app/node_modules/pkg"), { recursive: true });
  writeFileSync(join(tree, "app/node_modules/pkg/index.js"), Buffer.alloc(8192, 0x61));
  writeFileSync(join(tree, "readme.md"), Buffer.alloc(1024, 0x62));

  const ref = await measureRoomReference(tree);
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Real Pion binary via STILLFAIL_READER_FOOTPRINT=pion matches TS reference 0-diff.
    await withEnv({
      STILLFAIL_PION_READER: realPion,
      STILLFAIL_READER_FOOTPRINT: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const got = await measureRoom(tree);
      assert.deepEqual(got, ref);
    });

    // 2. If MoonBit reader is also available, verify real dual-run shadow produces 0 diff warnings.
    if (mbReaderBinary() !== null) {
      logs.length = 0;
      await withEnv({
        STILLFAIL_PION_READER: realPion,
        STILLFAIL_READER_FOOTPRINT: "shadow",
        STILLFAIL_READER_ENGINE: undefined,
      }, async () => {
        const got = await measureRoom(tree);
        assert.deepEqual(got, ref);
        await waitForShadowMeasures();
      });
      assert.equal(logs.filter((l) => l.message === "reader shadow diff").length, 0, "real Pion vs MB shadow must be 0-diff");
    }
  } finally {
    hearLines(null);
  }
});
