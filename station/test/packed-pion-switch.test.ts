// Tests for `sessions/packed-mb.ts` engine switching and real Pion binary E2E edge contracts:
// - `mb` default (zero main-thread statSync / zero fallback warn even when STILLFAIL_PION_READER is broken)
// - `pion` switch (`STILLFAIL_READER_PACKED=pion` and `STILLFAIL_READER_ENGINE=pion`) for both `PackedProgram` and `runPackedOnce`
// - explicit `options.binary` always takes precedence over env engine selection
// - missing Pion binary falls back safely to `mb` with deduped `pion-binary-missing` warning
// - `shadow` is strictly refused (`allowShadow: false`) and falls back safely to `mb` with `shadow-forbidden` warning
// - malformed JSON / non-object frames from child stdout are isolated with zero uncaughtException/unhandledRejection
// - real `STILLFAIL_PION_READER` binary E2E: table, pack/restore, workspace pack/unpack, >16 MiB lines,
//   `\r\n` framing parity, lone UTF-16 surrogate rejection without invoking shell, and `runPackedOnce` abort
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { pionBinary } from "../src/read/mb-reader.ts";
import { PackAborted, PackedProgram, runPackedOnce } from "../src/sessions/packed-mb.ts";
import { seekTable } from "./reference/packed.ts";

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

test("mb default, pion switch, explicit binary override, missing-binary fallback, and shadow refusal", { skip: skipPosixStubs }, async () => {
  const dir = freshDir();
  const mbStub = makeStubBinary(dir, "stub-mb", tagResponderBody("mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", tagResponderBody("pion"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", tagResponderBody("explicit"));
  const missingBin = join(dir, "no-such-stillfail-pion");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Default is `mb` even when a Pion binary is present, AND does not probe broken STILLFAIL_PION_READER.
    logs.length = 0;
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: missingBin,
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
    assert.equal(
      logs.filter((l) => l.message === "reader engine fallback").length,
      0,
      "default mb path must not probe STILLFAIL_PION_READER or emit fallback warnings",
    );

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

/** Run raw stdin bytes through `binary --builder packed --shell-dir <dir>` and collect stdout lines. */
function runRawPacked(binary: string, shellDir: string, stdinText: string): Promise<{ code: number | null; lines: string[]; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["--builder", "packed", "--shell-dir", shellDir], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const chunks: Buffer[] = [];
    let stderr = "";
    child.stdout!.on("data", (c: Buffer) => chunks.push(c));
    child.stderr!.on("data", (c: Buffer) => { stderr += c.toString("utf8"); });
    child.on("error", reject);
    child.on("close", (code) => {
      const text = Buffer.concat(chunks).toString("utf8");
      const lines = text.length === 0 ? [] : text.replace(/\n$/, "").split("\n");
      resolve({ code, lines, stderr });
    });
    child.stdin!.end(stdinText);
  });
}

test("real STILLFAIL_PION_READER binary E2E: ops, >16 MiB lines, CRLF & lone-surrogate parity, and workspace.pack abort", async (t) => {
  const explicitEnv = process.env.STILLFAIL_PION_READER?.trim();
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

      // >16 MiB valid request line (16,777,252+ bytes) must succeed without truncation or hang.
      const bigPad = "x".repeat(16 * 1024 * 1024 + 64);
      const bigResp = await p.ask<{ table: string }>("table", { frames: [[1, 2]], pad: bigPad });
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

    // Raw stdio framing parity: `\r\n` returns `{id:null,error:"no such ask"}` (not skipped),
    // lone UTF-16 surrogates are rejected before shell dispatch, valid surrogate pair succeeds.
    const surrogateOut = join(dir, "should-not-exist.zst");
    const raw = await runRawPacked(
      realPion,
      join(dir, "shell-raw"),
      [
        "\r",
        "",
        `{"id":1,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${surrogateOut.replaceAll("\\", "\\\\")}\\ud800"}`,
        `{"id":2,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${surrogateOut.replaceAll("\\", "\\\\")}\\udc00"}`,
        `{"id":3,"op":"pack","path":${JSON.stringify(transcript)},"temp":"${surrogateOut.replaceAll("\\", "\\\\")}\\ud800\\u0041"}`,
        `{"id":"\\ud83d\\ude00","op":"table","frames":[[5,6]]}`,
      ].join("\n") + "\n",
    );
    assert.equal(raw.code, 0, `raw packed exited ${raw.code}: ${raw.stderr}`);
    assert.equal(raw.lines.length, 5, `expected 5 answers (CR-only + 3 lone surrogates + 1 valid), got ${raw.lines.length}`);
    for (let i = 0; i < 4; i++) {
      assert.deepEqual(JSON.parse(raw.lines[i]!), { id: null, error: "no such ask" }, `line ${i}`);
    }
    assert.deepEqual(JSON.parse(raw.lines[4]!), {
      id: "😀",
      table: seekTable([{ packed: 5, size: 6 }]).toString("hex"),
    });
    assert.equal(existsSync(surrogateOut), false, "lone surrogate request must never invoke shell");

    // Mid-flight AbortSignal on real Pion `runPackedOnce("workspace.pack")` rejects cleanly with PackAborted.
    const bigWs = join(dir, "big-ws");
    mkdirSync(bigWs, { recursive: true });
    const noisy = Buffer.alloc(4 * 1024 * 1024);
    for (let i = 0; i < noisy.length; i++) noisy[i] = (i * 2654435761) >>> 24;
    for (let k = 0; k < 12; k++) writeFileSync(join(bigWs, `blob-${k}.bin`), noisy);
    const abortAc = new AbortController();
    const packPromise = runPackedOnce(
      "workspace.pack",
      { dir: bigWs, out: join(dir, "aborted.tar.zst") },
      { shellDir: join(dir, "shell-abort"), signal: abortAc.signal },
    );
    queueMicrotask(() => abortAc.abort());
    await assert.rejects(packPromise, PackAborted);
  });
});
