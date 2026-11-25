// Tests for `sessions/packed-mb.ts` engine switching and real Pion binary E2E contracts:
// - `mb` default (non-vacuous proof that `pionBinary()` is never probed or cached on default `mb`)
// - `pion` switch (`STILLFAIL_READER_PACKED=pion` and `STILLFAIL_READER_ENGINE=pion`) for both `PackedProgram` and `runPackedOnce`
// - explicit `options.binary` always takes precedence over env engine selection
// - missing Pion binary falls back safely to `mb` with deduped `pion-binary-missing` warning
// - `shadow` is strictly refused (`allowShadow: false`) and falls back safely to `mb` with `shadow-forbidden` warning
// - malformed JSON / non-object frames from child stdout are isolated with zero uncaughtException/unhandledRejection
// - real `STILLFAIL_PION_READER` binary E2E: table, pack/restore, >16 MiB lines, workspace pack/unpack,
//   and real mid-flight `workspace.pack` AbortSignal cancellation after output file begins writing
import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { MbProcess, pionBinary } from "../src/read/mb-reader.ts";
import { PackAborted, PackedProgram, runPackedOnce } from "../src/sessions/packed-mb.ts";
import { seekTable } from "./reference/packed.ts";
import { pinnedPion } from "./pion-pinned.ts";

const tempDirs: string[] = [];
after(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

function freshDir(prefix = "packed-switch-"): string {
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

function tagResponderBody(tag: string): string {
  return `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  process.stdout.write(JSON.stringify({ id: ask.id, tag: ${JSON.stringify(tag)} }) + "\\n");
});
`;
}

const MALFORMED_THEN_OK_BODY = `
import { createInterface } from "node:readline";
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line) return;
  const ask = JSON.parse(line);
  process.stdout.write("{not valid json\\n");
  process.stdout.write("null\\n");
  process.stdout.write("[1,2,3]\\n");
  process.stdout.write("\\"bare-string\\"\\n");
  process.stdout.write(JSON.stringify({ id: ask.id, ok: true }) + "\\n");
});
`;

test("mb default (zero pionBinary probe), pion switch, explicit binary override, missing-binary fallback, and shadow refusal", { skip: skipPosixStubs }, async () => {
  const dir = freshDir();
  const mbStub = makeStubBinary(dir, "stub-mb", tagResponderBody("mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", tagResponderBody("pion"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", tagResponderBody("explicit"));
  const missingBin = join(dir, "no-such-stillfail-pion");
  const deferredPionPath = join(dir, "deferred-pion");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Non-vacuous proof that default `mb` never calls `pionBinary()`:
    //    `pionBinary()` caches negative explicit path lookups (`explicit:<path> -> null`).
    //    Point `STILLFAIL_PION_READER` at `deferredPionPath` BEFORE it exists on disk, run default `mb`,
    //    then create `deferredPionPath` and switch to `pion`: if default `mb` had probed `pionBinary()`,
    //    the negative cache entry would force a fallback to `mb` instead of routing to `deferred-pion`.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: deferredPionPath,
      STILLFAIL_READER_PACKED: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new PackedProgram();
      try {
        assert.equal((await p.ask<{ tag: string }>("table", {})).tag, "mb");
      } finally {
        await p.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "mb");
    });
    assert.equal(logs.filter((l) => l.message === "reader engine fallback").length, 0);

    // Create the previously-absent binary now; `pion` mode must find and run it (proving no negative cache entry was recorded).
    const createdDeferred = makeStubBinary(dir, "deferred-pion", tagResponderBody("deferred-pion"));
    assert.equal(createdDeferred, deferredPionPath);
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: deferredPionPath,
      STILLFAIL_READER_PACKED: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), deferredPionPath);
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "deferred-pion");
    });

    // Default `mb` also stays on `mb` when a valid Pion binary is already available.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), pionStub);
      const p = new PackedProgram();
      try {
        assert.equal((await p.ask<{ tag: string }>("table", {})).tag, "mb");
      } finally {
        await p.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "mb");
    });

    // 2. STILLFAIL_READER_PACKED=pion routes both PackedProgram and runPackedOnce to Pion.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new PackedProgram();
      try {
        assert.equal((await p.ask<{ tag: string }>("table", {})).tag, "pion");
      } finally {
        await p.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "pion");
    });

    // 3. STILLFAIL_READER_ENGINE=pion routes both PackedProgram and runPackedOnce to Pion; explicit options.binary wins.
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: undefined,
      STILLFAIL_READER_ENGINE: "pion",
    }, async () => {
      const p = new PackedProgram();
      try {
        assert.equal((await p.ask<{ tag: string }>("table", {})).tag, "pion");
      } finally {
        await p.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "pion");
      const explicitP = new PackedProgram({ binary: explicitStub });
      try {
        assert.equal((await explicitP.ask<{ tag: string }>("table", {})).tag, "explicit");
      } finally {
        await explicitP.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {}, { binary: explicitStub })).tag, "explicit");
    });

    // 4. Missing Pion binary falls back safely to `mb` and logs deduped `pion-binary-missing` warning.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: missingBin,
      STILLFAIL_READER_PACKED: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), null);
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "mb");
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "mb");
    });
    const missingWarns = logs.filter(
      (l) => l.level === "WARN" && l.at === "archive" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-missing",
    );
    assert.equal(missingWarns.length, 1, "expected exactly one deduped pion-binary-missing fallback warning");

    // 5. `shadow` is strictly refused (`allowShadow: false`) and falls back safely to `mb`.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: pionStub,
      STILLFAIL_READER_PACKED: "shadow",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new PackedProgram();
      try {
        assert.equal((await p.ask<{ tag: string }>("table", {})).tag, "mb");
      } finally {
        await p.close();
      }
      assert.equal((await runPackedOnce<{ tag: string }>("table", {})).tag, "mb");
    });
    const shadowWarns = logs.filter(
      (l) => l.level === "WARN" && l.at === "archive" && l.message === "reader engine fallback" && l.fields.reason === "shadow-forbidden",
    );
    assert.equal(shadowWarns.length, 1, "expected exactly one deduped shadow-forbidden fallback warning");
  } finally {
    hearLines(null);
  }
});

test("malformed JSON and non-object stdout frames are isolated without uncaughtException or unhandledRejection", { skip: skipPosixStubs }, async () => {
  const dir = freshDir();
  const noisyStub = makeStubBinary(dir, "stub-noisy", MALFORMED_THEN_OK_BODY);

  const unhandled: unknown[] = [];
  const uncaught: unknown[] = [];
  const onUnhandled = (err: unknown) => unhandled.push(err);
  const onUncaught = (err: unknown) => uncaught.push(err);
  process.on("unhandledRejection", onUnhandled);
  process.on("uncaughtException", onUncaught);

  try {
    const p = new PackedProgram({ binary: noisyStub });
    try {
      const ans = await p.ask<{ ok: boolean }>("table", {});
      assert.equal(ans.ok, true);
    } finally {
      await p.close();
    }
    const once = await runPackedOnce<{ ok: boolean }>("table", {}, { binary: noisyStub });
    assert.equal(once.ok, true);

    assert.deepEqual(unhandled, [], "malformed frames must never emit unhandledRejection");
    assert.deepEqual(uncaught, [], "malformed frames must never emit uncaughtException");
  } finally {
    process.off("unhandledRejection", onUnhandled);
    process.off("uncaughtException", onUncaught);
  }
});

test("real STILLFAIL_PION_READER binary E2E: ops, >16 MiB lines, and real mid-flight workspace.pack abort", async (t) => {
  const explicitEnv = pinnedPion();
  const realPion = pionBinary();
  if (explicitEnv) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER is set (${explicitEnv}) but resolved to null`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }
  const dir = freshDir("packed-real-pion-");
  const transcript = join(dir, "t.jsonl");
  const packedFile = join(dir, "t.jsonl.zst");
  const restored = join(dir, "t.restored.jsonl");
  const content = Buffer.from("{\"line\":1,\"text\":\"你好 Pion\"}\n{\"line\":2}\n");
  writeFileSync(transcript, content);

  const ws = join(dir, "ws");
  mkdirSync(join(ws, "sub"), { recursive: true });
  writeFileSync(join(ws, "sub/hello.txt"), "hello workspace\n");
  const archive = join(dir, "ws.tar.zst");
  const dest = join(dir, "dest");
  mkdirSync(dest);

  await withEnv({
    STILLFAIL_PION_READER: realPion,
    STILLFAIL_READER_PACKED: "pion",
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const p = new PackedProgram({ shellDir: join(dir, "shell") });
    try {
      const tbl = await p.ask<{ table: string }>("table", { frames: [[10, 20], [30, 40]] });
      assert.equal(tbl.table, seekTable([{ packed: 10, size: 20 }, { packed: 30, size: 40 }]).toString("hex"));

      await p.ask("pack", { path: transcript, temp: packedFile });
      const seg = await p.ask<{ segmented: boolean }>("segmented", { path: packedFile });
      assert.equal(seg.segmented, true);
      await p.ask("restore", { source: packedFile, temp: restored });
      assert.deepEqual(readFileSync(restored), content);

      // >16 MiB valid request line (16,777,252+ bytes) via PackedProgram must succeed without truncation or hang.
      const bigResp = await p.ask<{ table: string }>("table", { frames: [[1, 2]], pad: "x".repeat(16 * 1024 * 1024 + 64) });
      assert.equal(bigResp.table, seekTable([{ packed: 1, size: 2 }]).toString("hex"));
    } finally {
      await p.close();
    }

    // >16 MiB valid request via runPackedOnce as well.
    const bigOnce = await runPackedOnce<{ table: string }>(
      "table",
      { frames: [[3, 4]], pad: "y".repeat(16 * 1024 * 1024 + 64) },
      { shellDir: join(dir, "shell-big-once") },
    );
    assert.equal(bigOnce.table, seekTable([{ packed: 3, size: 4 }]).toString("hex"));

    await runPackedOnce("workspace.pack", { dir: ws, out: archive }, { shellDir: join(dir, "shell-once") });
    const unpacked = await runPackedOnce<{ refused: unknown[] }>(
      "workspace.unpack",
      { path: archive, dest },
      { shellDir: join(dir, "shell-unpack") },
    );
    assert.deepEqual(unpacked.refused, []);
    assert.equal(readFileSync(join(dest, "sub/hello.txt"), "utf8"), "hello workspace\n");

    // Real mid-flight AbortSignal on Pion `runPackedOnce("workspace.pack")` (matching cold-archive.test.ts:567):
    // write 24 MiB of incompressible pseudo-random bytes, wait until the target archive file actually starts
    // being written (`size > 0`), then abort and verify PackAborted, intact workspace, and zero lingering child.
    const bigWs = join(dir, "big-ws");
    mkdirSync(bigWs, { recursive: true });
    const blob = Buffer.allocUnsafe(24 << 20);
    let seed = 0x12345678;
    for (let i = 0; i < blob.length; i += 4) {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      blob.writeUInt32LE(seed, i);
    }
    const blobPath = join(bigWs, "data.bin");
    writeFileSync(blobPath, blob);

    const abortedOut = join(dir, "aborted.tar.zst");
    const abortAc = new AbortController();
    const abortShellDir = join(dir, "shell-abort");
    const packPromise = runPackedOnce(
      "workspace.pack",
      { dir: bigWs, out: abortedOut },
      { shellDir: abortShellDir, signal: abortAc.signal },
    );
    let sawWriting = false;
    for (let i = 0; i < 1000; i++) {
      if (existsSync(abortedOut) && statSync(abortedOut).size > 0) {
        sawWriting = true;
        break;
      }
      await new Promise((res) => setTimeout(res, 5));
    }
    assert.ok(sawWriting, "expected aborted.tar.zst to begin writing (size > 0) before abort");
    abortAc.abort();
    await assert.rejects(packPromise, PackAborted);
    assert.equal(statSync(blobPath).size, blob.length, "original workspace file must stay intact after abort");
    assert.equal(
      MbProcess.live().some((proc) => proc.args.includes(abortShellDir)),
      false,
      "aborted packed child process must exit and be removed from MbProcess.live()",
    );
  });
});
