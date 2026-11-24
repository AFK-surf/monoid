// Tests for `sessions/packed-mb.ts` engine switching:
// - `mb` default (even when a Pion binary is available; zero main-thread statSync for pionBinary)
// - `pion` switch (`STILLFAIL_READER_PACKED=pion` and `STILLFAIL_READER_ENGINE=pion`) for both `PackedProgram` and `runPackedOnce`
// - explicit `options.binary` always takes precedence over env engine selection
// - missing Pion binary falls back safely to `mb` with deduped `pion-binary-missing` warning
// - `shadow` is strictly refused (`allowShadow: false`) and falls back safely to `mb` with `shadow-forbidden` warning
// - malformed JSON / non-object frames from child stdout are isolated with zero uncaughtException/unhandledRejection
// - real `STILLFAIL_PION_READER` binary end-to-end `pion` mode verifies seek table, transcript pack/restore, and workspace pack/unpack
import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { pionBinary } from "../src/read/mb-reader.ts";
import { PackedProgram, runPackedOnce } from "../src/sessions/packed-mb.ts";
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

test("mb default, pion switch, explicit binary override, missing-binary fallback, and shadow refusal", async () => {
  const dir = freshDir();
  const mbStub = makeStubBinary(dir, "stub-mb", tagResponderBody("mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", tagResponderBody("pion"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", tagResponderBody("explicit"));
  const missingBin = join(dir, "no-such-stillfail-pion");

  const logs: Line[] = [];
  hearLines((l) => logs.push(l));
  try {
    // 1. Default is `mb` even when a Pion binary is present (both PackedProgram and runPackedOnce).
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

    // 3. STILLFAIL_READER_ENGINE=pion also routes packed to Pion, while explicit options.binary wins.
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

test("malformed JSON and non-object stdout frames are isolated without uncaughtException or unhandledRejection", async () => {
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

test("real STILLFAIL_PION_READER binary end-to-end pion mode handles table, pack/restore, and workspace pack/unpack", async (t) => {
  const realPion = pionBinary();
  if (realPion === null) {
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
    } finally {
      await p.close();
    }

    await runPackedOnce("workspace.pack", { dir: ws, out: archive }, { shellDir: join(dir, "shell-once") });
    const unpacked = await runPackedOnce<{ refused: unknown[] }>(
      "workspace.unpack",
      { path: archive, dest },
      { shellDir: join(dir, "shell-unpack") },
    );
    assert.deepEqual(unpacked.refused, []);
    assert.equal(readFileSync(join(dest, "sub/hello.txt"), "utf8"), "hello workspace\n");
  });
});
