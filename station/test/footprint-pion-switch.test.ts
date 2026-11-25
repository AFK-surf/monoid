// Tests for `sessions/footprint.ts` engine switching:
// - `mb` default (zero main-thread statSync for pionBinary)
// - `pion` switch (`STILLFAIL_READER_FOOTPRINT=pion` and `STILLFAIL_READER_ENGINE=pion`)
// - `shadow` single-flight serial execution after primary completes, non-blocking primary return,
//   deterministic host hard-timeout reap & slot release via test hooks (zero wall-clock polling),
//   abort killing lingering post-response shadow immediately, structured diff logging (summarized
//   rebuild list, duration-noise suppression, separate timeout log), malformed JSON frame isolation
//   with zero uncaughtException/unhandledRejection, and missing-binary fallback
// - Dedicated real MoonBit + real Pion dual-run shadow 0-diff test (fails loudly in CI if missing).
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { MbProcess, mbReaderBinary, pionBinary } from "../src/read/mb-reader.ts";
import {
  isShadowInFlightForTest,
  lastShadowPidForTest,
  measureRoom,
  measured,
  triggerShadowDeadlineForTest,
  waitForShadowMeasures,
} from "../src/sessions/footprint.ts";
import { measureRoomReference } from "./footprint-reference.ts";
import { pinnedPion } from "./pion-pinned.ts";

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

/** Flush microtasks so primary `.then()` launches the single-flight shadow synchronously. */
const flushMicrotasks = () => new Promise<void>((r) => queueMicrotask(r));

function responderBody(responseJson: string): string {
  return `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.once("line", () => {
  process.stdout.write(${JSON.stringify(responseJson)} + "\\n");
  process.exit(0);
});
`;
}

function makeHangAndRecordStub(dir: string, name: string, countFile: string): string {
  if (platform.os !== "windows") {
    const shPath = join(dir, name);
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
  process.stdout.write(${JSON.stringify(responseJson)} + "\\n", () => {
    process.stderr.write("SHADOW_LINGER_READY\\n");
  });
  // Deliberately stay alive after writing stdout to verify abort/hard-timeout reaps it.
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

test("shadow mode is single-flight after primary, never blocks primary, reaps hanging/lingering shadows deterministically on deadline or abort, and isolates malformed/crashing shadows", async () => {
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

    // 5. Single-flight + non-blocking primary + deterministic deadline kill & slot release (zero wall-clock races).
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionHang,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(isShadowInFlightForTest(), false);
      // (a) Primary returns immediately while the hanging shadow occupies the single-flight slot.
      assert.equal(await measured(target), 4096);
      await flushMicrotasks();
      assert.equal(isShadowInFlightForTest(), true, "shadow must hold single-flight slot after primary returns");

      // (b) Second measure while first shadow occupies the slot skips shadow completely.
      assert.equal(await measured(target), 4096);
      assert.equal(isShadowInFlightForTest(), true, "first shadow must still hold the slot");

      // (c) Deterministically trigger host deadline -> kills shadow, logs timeout (not diff), releases slot.
      const shadowPid = lastShadowPidForTest();
      assert.ok(typeof shadowPid === "number" && shadowPid > 0, "expected active shadow pid");
      assert.equal(triggerShadowDeadlineForTest(), true, "expected active shadow deadline callback");
      await waitForShadowMeasures();
      assert.equal(isShadowInFlightForTest(), false, "slot must be released once shadow child closes");
      assert.equal(
        MbProcess.live().some((p) => p.pid === shadowPid),
        false,
        "hanging shadow child must be removed from MbProcess.live()",
      );
      assert.throws(() => process.kill(shadowPid, 0), { code: "ESRCH" }, "hanging shadow OS pid must be reaped");
      assert.ok(
        logs.some((l) => l.level === "WARN" && l.at === "footprint" && l.message === "reader shadow timed out"),
        "timeout must log `reader shadow timed out`",
      );
      assert.equal(
        logs.filter((l) => l.message === "reader shadow diff").length,
        0,
        "timeout must not be mixed into `reader shadow diff`",
      );

      // (d) Slot is free again: third measure launches a fresh shadow (which we then reap deterministically).
      assert.equal(await measured(target), 4096);
      await flushMicrotasks();
      assert.equal(isShadowInFlightForTest(), true, "third measure must acquire the released slot");
      const shadowPid2 = lastShadowPidForTest();
      assert.ok(typeof shadowPid2 === "number" && shadowPid2 !== shadowPid, "expected a new shadow pid");
      assert.equal(triggerShadowDeadlineForTest(), true);
      await waitForShadowMeasures();
      assert.equal(isShadowInFlightForTest(), false);
      assert.throws(() => process.kill(shadowPid2, 0), { code: "ESRCH" }, "second shadow OS pid must be reaped");
    });
    // At most 2 shadows ever ran (1st and 3rd; 2nd was skipped). Note countFile may have <= 2 lines
    // if SIGKILL arrived before sh appended, never > 2.
    const starts = (() => {
      try {
        return readFileSync(countFile, "utf8").trim().split("\n").filter(Boolean).length;
      } catch {
        return 0;
      }
    })();
    assert.ok(starts <= 2, `single-flight must never spawn more than 2 shadows across 3 measures (got ${starts})`);

    // 6. Lingering shadow (emits valid JSON line, then stays alive): caller AbortSignal kills it immediately
    //    and releases the single-flight slot without waiting for the 65s hard timeout.
    logs.length = 0;
    let resolveLingerReady!: () => void;
    const lingerReady = new Promise<void>((r) => { resolveLingerReady = r; });
    hearLines((l) => {
      logs.push(l);
      if (l.at === "readers" && l.fields.line === "SHADOW_LINGER_READY") resolveLingerReady();
    });
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionLinger,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const ac = new AbortController();
      assert.equal(await measured(target, ac.signal), 4096);
      // Event-driven wait until shadow has actually written its valid JSON response and entered linger state.
      await lingerReady;
      assert.equal(isShadowInFlightForTest(), true, "lingering shadow must still hold slot after emitting response");
      const lingerPid = lastShadowPidForTest();
      assert.ok(typeof lingerPid === "number" && lingerPid > 0, "expected lingering shadow pid");
      // Caller aborts after shadow already responded: lingering shadow must be killed immediately.
      ac.abort(new Error("caller cancelled after shadow response"));
      await waitForShadowMeasures();
      assert.equal(isShadowInFlightForTest(), false, "abort must kill lingering shadow and release slot");
      assert.equal(
        MbProcess.live().some((p) => p.pid === lingerPid),
        false,
        "lingering shadow must be removed from MbProcess.live()",
      );
      assert.throws(() => process.kill(lingerPid, 0), { code: "ESRCH" }, "lingering shadow OS pid must be reaped");
      assert.equal(
        logs.filter((l) => l.message === "reader shadow timed out" || l.message === "reader shadow diff").length,
        0,
        "aborted lingering shadow must not emit timeout or diff warnings",
      );
    });

    assert.deepEqual(unhandled, [], "shadow mode must never emit unhandledRejection");
    assert.deepEqual(uncaught, [], "malformed shadow frames must never emit uncaughtException");
  } finally {
    hearLines(null);
    process.off("unhandledRejection", onUnhandled);
    process.off("uncaughtException", onUncaught);
  }
});

test("real STILLFAIL_PION_READER binary end-to-end pion mode matches TS oracle 0-diff", async (t) => {
  const realPion = pionBinary();
  if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }
  const tree = freshDir("footprint-real-pion-");
  mkdirSync(join(tree, "app/node_modules/pkg"), { recursive: true });
  writeFileSync(join(tree, "app/node_modules/pkg/index.js"), Buffer.alloc(8192, 0x61));
  writeFileSync(join(tree, "readme.md"), Buffer.alloc(1024, 0x62));

  const ref = await measureRoomReference(tree);
  await withEnv({
    STILLFAIL_PION_READER: realPion,
    STILLFAIL_READER_FOOTPRINT: "pion",
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const got = await measureRoom(tree);
    assert.deepEqual(got, ref);
  });
});

test("real MoonBit + real Pion dual-run shadow produces 0 diff", async (t) => {
  const realPion = pionBinary();
  const realMb = mbReaderBinary();
  const strictCi = Boolean(pinnedPion() && process.env.CI);
  if (strictCi) {
    assert.ok(realPion !== null, "CI with STILLFAIL_PION_READER must resolve a real Pion binary");
    assert.ok(realMb !== null, "CI with STILLFAIL_PION_READER must also have a real MoonBit stillfail-reader binary");
    assert.notEqual(
      resolve(realMb),
      resolve(realPion),
      "dual-run shadow in CI must execute two distinct binaries (MoonBit stillfail-reader vs Pion stillfail-pion)",
    );
  } else if (realPion === null || realMb === null || resolve(realMb) === resolve(realPion)) {
    t.skip("requires distinct built MoonBit stillfail-reader and Pion stillfail-pion binaries");
    return;
  }

  const tree = freshDir("footprint-real-shadow-");
  mkdirSync(join(tree, "app/node_modules/pkg"), { recursive: true });
  writeFileSync(join(tree, "app/node_modules/pkg/index.js"), Buffer.alloc(8192, 0x61));
  writeFileSync(join(tree, "readme.md"), Buffer.alloc(1024, 0x62));

  const ref = await measureRoomReference(tree);
  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    await withEnv({
      STILLFAIL_MB_READER: realMb,
      STILLFAIL_PION_READER: realPion,
      STILLFAIL_READER_FOOTPRINT: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const got = await measureRoom(tree);
      assert.deepEqual(got, ref);
      await waitForShadowMeasures();
    });
    assert.equal(
      logs.filter((l) => l.message === "reader shadow diff" || l.message === "reader shadow timed out").length,
      0,
      "real MoonBit + real Pion shadow must produce 0 diff and 0 timeouts",
    );
  } finally {
    hearLines(null);
  }
});
