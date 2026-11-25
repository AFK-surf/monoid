// Tests for `share/memory-mb.ts` engine switching and real Pion `--builder memory` E2E:
// - `mb` default (zero main-thread statSync / zero fallback warn even if STILLFAIL_PION_READER is missing)
// - `pion` switch (`STILLFAIL_READER_MEMORY=pion` and `STILLFAIL_READER_ENGINE=pion`)
// - `shadow` strictly refused for `memory` (`allowShadow: false`), both per-mode and global env, with deduplicated warn
// - invalid engine value and missing Pion binary fallback to `mb` with deduplicated warning
// - explicit `options.binary` always respected regardless of env
// - malformed stdout JSON / non-object / unmatched id / non-string error isolation
// - real `STILLFAIL_PION_READER` binary end-to-end: tags, merge3, scan, decide, skillWrite/skillRead,
//   trimIdle auto-restart, >16 MiB (17 MiB) valid request, lone surrogate rejection, and skillWrite safety hardening
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { hearLines, type Line } from "../src/ops/log.ts";
import { platform } from "../src/platform/index.ts";
import { pionBinary } from "../src/read/mb-reader.ts";
import { MemoryProgram, MemoryProgramStopped } from "../src/share/memory-mb.ts";
import { merge3, stationTag } from "./reference/memory-merge.ts";
import { pinnedPion } from "./pion-pinned.ts";

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

const skipWinStubs = platform.os === "windows" ? "POSIX shell stubs not used on win32" : false;

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
    process.stdout.write(JSON.stringify({ id: null, error: "no such ask" }) + "\\n");
    process.stdout.write(JSON.stringify({ id: 999999, tags: ["ghost"] }) + "\\n");
    process.stdout.write(JSON.stringify({ id: req.id, ok: true }) + "\\n");
  } else if (req.op === "nonStringError") {
    process.stdout.write(JSON.stringify({ id: req.id, error: 12345 }) + "\\n");
  } else {
    process.stdout.write(JSON.stringify({ id: req.id, tags: ["ok"] }) + "\\n");
  }
});
`;

test("mb default, pion switch, shadow refusal, invalid value, deduplicated fallback warn, and explicit binary override", { skip: skipWinStubs }, async () => {
  const dir = freshDir();
  const shellDir = freshDir("memory-shell-");
  const mbStub = makeStubBinary(dir, "stub-mb", tagResponderBody("from-mb"));
  const pionStub = makeStubBinary(dir, "stub-pion", tagResponderBody("from-pion"));
  const explicitStub = makeStubBinary(dir, "stub-explicit", tagResponderBody("from-explicit"));
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
      STILLFAIL_READER_MEMORY: undefined,
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
        assert.deepEqual((await p.ask("tags", { names: [123n] as unknown as string[] })).tags, ["from-mb"]);
      } finally {
        await p.close();
      }
    });
    assert.equal(
      logs.filter((l) => l.at === "memory" && l.message === "reader engine fallback").length,
      0,
      "default mb must not probe pionBinary or emit fallback warnings",
    );

    // Create the previously-absent binary now; `pion` mode must find and run it (proving no negative cache entry was recorded).
    const createdDeferred = makeStubBinary(dir, "deferred-pion", tagResponderBody("from-deferred-pion"));
    assert.equal(createdDeferred, deferredPionPath);
    await withEnv({
      STILLFAIL_MB_READER: mbStub,
      STILLFAIL_PION_READER: deferredPionPath,
      STILLFAIL_READER_MEMORY: "pion",
      STILLFAIL_READER_ENGINE: undefined,
    }, async () => {
      assert.equal(pionBinary(), deferredPionPath);
      const p = new MemoryProgram(shellDir);
      try {
        assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-deferred-pion"]);
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

    // 4. shadow is strictly forbidden for memory (both per-mode & global env) -> falls back to mb, deduplicated warn === 1.
    logs.length = 0;
    for (const envPair of [
      { STILLFAIL_READER_MEMORY: "shadow", STILLFAIL_READER_ENGINE: undefined },
      { STILLFAIL_READER_MEMORY: undefined, STILLFAIL_READER_ENGINE: "shadow" },
    ]) {
      await withEnv({
        STILLFAIL_MB_READER: mbStub,
        STILLFAIL_PION_READER: pionStub,
        ...envPair,
      }, async () => {
        const p = new MemoryProgram(shellDir);
        try {
          assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
        } finally {
          await p.close();
        }
      });
    }
    assert.equal(
      logs.filter((l) => l.level === "WARN" && l.at === "memory" && l.message === "reader engine fallback" && l.fields.reason === "shadow-forbidden").length,
      1,
      "expected exactly 1 deduplicated shadow-forbidden fallback warning across two triggers",
    );

    // 5. Invalid engine value falls back to mb with deduplicated warning.
    logs.length = 0;
    for (let i = 0; i < 2; i++) {
      await withEnv({
        STILLFAIL_MB_READER: mbStub,
        STILLFAIL_PION_READER: pionStub,
        STILLFAIL_READER_MEMORY: "bogus-engine",
        STILLFAIL_READER_ENGINE: undefined,
      }, async () => {
        const p = new MemoryProgram(shellDir);
        try {
          assert.deepEqual((await p.ask("tags", { names: ["x"] })).tags, ["from-mb"]);
        } finally {
          await p.close();
        }
      });
    }
    assert.equal(
      logs.filter((l) => l.level === "WARN" && l.at === "memory" && l.message === "reader engine fallback" && l.fields.reason === "invalid-value").length,
      1,
      "expected exactly 1 deduplicated invalid-value fallback warning",
    );

    // 6. Missing Pion binary safely falls back to mb and deduplicates warning across repeated starts.
    logs.length = 0;
    for (let i = 0; i < 2; i++) {
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
    }
    assert.equal(
      logs.filter((l) => l.level === "WARN" && l.at === "memory" && l.message === "reader engine fallback" && l.fields.reason === "pion-binary-missing").length,
      1,
      "expected exactly 1 deduplicated pion-binary-missing fallback warning",
    );

    // 7. Explicit options.binary is always respected even when STILLFAIL_READER_MEMORY=pion.
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

test("memory-mb isolates malformed JSON lines, non-object JSON frames, unmatched ids, and non-string errors", { skip: skipWinStubs }, async () => {
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
      assert.equal(
        logs.filter((l) => l.level === "WARN" && l.at === "memory" && l.message === "the memory's program returned an unmatched response").length,
        2,
        "expected unmatched response warnings for id:null and unknown numeric id",
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

test("real STILLFAIL_PION_READER binary end-to-end pion mode: ops, >16 MiB line, skillWrite safety, and idle restart", async (t) => {
  const explicitEnv = pinnedPion();
  const realPion = pionBinary();
  if (explicitEnv) {
    assert.ok(realPion !== null, `STILLFAIL_PION_READER=${explicitEnv} is set but not executable`);
  } else if (realPion === null) {
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return;
  }

  const root = freshDir("memory-real-pion-");
  const shellDir = join(root, "shell");
  const homeDir = join(root, "home");
  const blobsDir = join(root, "blobs");
  mkdirSync(shellDir, { recursive: true });
  mkdirSync(homeDir, { recursive: true });
  mkdirSync(blobsDir, { recursive: true });

  const sha = (s: string) => createHash("sha256").update(s).digest("hex");
  const hex = (s: string | Buffer) => (typeof s === "string" ? Buffer.from(s, "utf8") : s).toString("hex");
  const b64 = (s: string | Buffer) => Buffer.from(s).toString("base64");

  await withEnv({
    STILLFAIL_PION_READER: realPion!,
    STILLFAIL_READER_MEMORY: "pion",
    STILLFAIL_READER_ENGINE: undefined,
  }, async () => {
    const p = new MemoryProgram(shellDir);
    try {
      // 1. tags (including BigInt serialization compatibility) & merge3
      const stations = ["Mini 1", "中文 站点", "😀 emoji 😀"];
      const gotTags = await p.ask("tags", { names: stations });
      assert.deepEqual(gotTags.tags, stations.map(stationTag));
      const gotBigIntTags = await p.ask("tags", { names: [123n] as unknown as string[] });
      assert.deepEqual(gotBigIntTags.tags, ["123"]);

      const base = "a\nb\nc\n";
      const newer = "A\nb\nc\n";
      const older = "a\nb\nC\n";
      const gotMerge = await p.ask("merge3", { base: hex(base), newer: hex(newer), older: hex(older) });
      assert.equal(Buffer.from(gotMerge.value, "hex").toString("utf8"), merge3(base, newer, older));

      // 2. scan & decide
      writeFileSync(join(homeDir, "MEMORY.md"), "# mem\n- alpha\n");
      const scanned = await p.ask("scan", {
        dir: homeDir,
        blobs: blobsDir,
        kept: {},
        builtin: [],
        skipped: [],
        fileMost: 512 * 1024,
        skillMost: 4 * 1024 * 1024,
        skillFiles: 200,
      });
      assert.equal(scanned.files.length, 1);
      assert.equal(scanned.files[0].path, "MEMORY.md");
      assert.equal(scanned.files[0].hash, sha("# mem\n- alpha\n"));

      const decided = await p.ask("decide", {
        path: "MEMORY.md",
        mine: { hash: sha(newer), at: 2, by: "a".repeat(64), prev: [sha(base)], size: newer.length, mode: 0o644 },
        theirs: { hash: sha(older), at: 3, by: "b".repeat(64), prev: [sha(base)], size: older.length, mode: 0o644 },
        names: { ["a".repeat(64)]: "A", ["b".repeat(64)]: "B" },
        given: { [sha(base)]: hex(base), [sha(newer)]: hex(newer), [sha(older)]: hex(older) },
        blobs: blobsDir,
        prevMost: 16,
      });
      assert.equal(decided.kind, "merge");
      assert.equal(readFileSync(join(blobsDir, decided.rec.hash), "utf8"), "A\nb\nC\n");

      // 3. skillWrite + skillRead + safety hardening (NUL, file/dir collision, recoverable swap, no .tmp-/.bak- leftover)
      const skillParent = join(root, "skills");
      const skillDir = join(skillParent, "demo");
      mkdirSync(skillParent, { recursive: true });
      assert.deepEqual(
        await p.ask("skillWrite", { dir: skillDir, files: { "SKILL.md": b64("# v1\n") } }),
        { id: 6, written: true },
      );
      assert.deepEqual(readdirSync(skillParent), ["demo"]);

      // Replace existing skill cleanly via recoverable swap -> no .stillfail-tmp- or .stillfail-bak- left behind.
      const wr2 = await p.ask("skillWrite", { dir: skillDir, files: { "SKILL.md": b64("# v2\n"), "a/b.txt": b64("hi") } });
      assert.equal(wr2.written, true);
      assert.deepEqual(readdirSync(skillParent), ["demo"]);
      assert.equal(readFileSync(join(skillDir, "SKILL.md"), "utf8"), "# v2\n");

      // Long 240-byte ASCII skill name creates & replaces cleanly without hitting ENAMETOOLONG.
      const longSkillName = "a".repeat(240);
      const longSkillDir = join(skillParent, longSkillName);
      assert.equal((await p.ask("skillWrite", { dir: longSkillDir, files: { "SKILL.md": b64("# long v1\n") } })).written, true);
      assert.equal((await p.ask("skillWrite", { dir: longSkillDir, files: { "SKILL.md": b64("# long v2\n") } })).written, true);
      assert.equal(readFileSync(join(longSkillDir, "SKILL.md"), "utf8"), "# long v2\n");
      rmSync(longSkillDir, { recursive: true, force: true });

      // Lone UTF-16 surrogates via MemoryProgram.ask reject immediately without leaking #waiting or blocking trimIdle().
      await assert.rejects(p.ask("tags", { names: ["bad\uD800"] }), /invalid UTF-16 surrogate/);
      await assert.rejects(
        p.ask("skillWrite", { dir: skillDir, files: { "SKILL.md": b64("x"), "bad\uDC00": b64("y") } }),
        /invalid UTF-16 surrogate/,
      );
      assert.deepEqual((await p.ask("tags", { names: ["after-surrogate"] })).tags, ["after-surrogate"]);

      // NUL byte & file/dir collision rejected in both check:true and check:false, parent untouched.
      for (const check of [true, false]) {
        await assert.rejects(
          p.ask("skillWrite", { dir: skillDir, files: { "SKILL.md": b64("bad"), "a\0b": b64("x") }, ...(check ? { check: true } : {}) }),
          /bad path in a shared skill/,
        );
        await assert.rejects(
          p.ask("skillWrite", { dir: skillDir, files: { "a": b64("x"), "a/b": b64("y") }, ...(check ? { check: true } : {}) }),
          /bad path in a shared skill/,
        );
        assert.deepEqual(readdirSync(skillParent), ["demo"]);
        assert.equal(readFileSync(join(skillDir, "SKILL.md"), "utf8"), "# v2\n");
      }

      // Write failure on read-only parent: original skill stays intact and no .tmp-/.bak- left behind.
      if (platform.os !== "windows" && process.getuid?.() !== 0) {
        const roParent = join(root, "ro-skills");
        const roSkill = join(roParent, "demo");
        mkdirSync(roSkill, { recursive: true });
        writeFileSync(join(roSkill, "SKILL.md"), "# preserved\n");
        chmodSync(roParent, 0o555);
        try {
          await assert.rejects(p.ask("skillWrite", { dir: roSkill, files: { "SKILL.md": b64("# fail\n") } }));
          assert.deepEqual(readdirSync(roParent), ["demo"]);
          assert.equal(readFileSync(join(roSkill, "SKILL.md"), "utf8"), "# preserved\n");
        } finally {
          chmodSync(roParent, 0o755);
        }
      }

      // 4. >16 MiB (17 MiB) valid JSON-RPC request round-trip on real Pion binary, then normal ask & trimIdle auto-restart.
      const bigBytes = Buffer.alloc(8_600_000, 0x61); // 17.2 MiB hex string (> 16 MiB)
      const bigHex = bigBytes.toString("hex");
      assert.ok(bigHex.length > 16 * 1024 * 1024);
      const bigRes = await p.ask("isText", { bytes: bigHex });
      assert.equal(bigRes.value, true);

      // Subsequent ask and trimIdle() + automatic restart.
      assert.deepEqual((await p.ask("tags", { names: ["after-big"] })).tags, ["after-big"]);
      assert.equal(p.started, 1);
      assert.equal(p.trimIdle(), 1);
      assert.equal(p.running, false);
      assert.deepEqual((await p.ask("tags", { names: ["restarted"] })).tags, ["restarted"]);
      assert.equal(p.started, 2);
      assert.equal(existsSync(join(skillDir, "SKILL.md")), true);
    } finally {
      await p.close();
    }
    await assert.rejects(p.ask("tags", { names: [] }), MemoryProgramStopped);
  });

  // 5. Raw stdio protocol edge checks on real Pion binary: CR-only line, lone UTF-16 surrogates
  //    (including escaped "i\u0064" key), and colliding .stillfail-tmp-<pid>-1 / .stillfail-bak-<pid>-3 preservation.
  const collideParent = join(root, "collide-skills");
  const collideSkill = join(collideParent, "demo");
  mkdirSync(collideSkill, { recursive: true });
  writeFileSync(join(collideSkill, "SKILL.md"), "# old\n");

  const rawOut = await new Promise<string>((resolve, reject) => {
    const child = spawn(realPion!, ["--builder", "memory", "--shell-dir", shellDir], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    assert.ok(typeof child.pid === "number" && child.pid > 0);
    // Pre-occupy the exact first temp and backup candidate names this PID will probe.
    const occupiedTmp = join(collideParent, `.stillfail-tmp-${child.pid}-1`);
    const occupiedBak = join(collideParent, `.stillfail-bak-${child.pid}-3`);
    mkdirSync(occupiedTmp, { recursive: true });
    writeFileSync(join(occupiedTmp, "keep.txt"), "keep-tmp");
    mkdirSync(occupiedBak, { recursive: true });
    writeFileSync(join(occupiedBak, "keep.txt"), "keep-bak");

    let out = "";
    child.stdout!.on("data", (c: Buffer) => { out += c.toString("utf8"); });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) reject(new Error(`unexpected exit ${code}`));
      else resolve(out);
    });
    child.stdin!.write("\r\n");
    child.stdin!.write('{"id":1,"op":"tags","names":["\\uD800"]}\n');
    child.stdin!.write('{"i\\u0064":7,"op":"tags","names":["\\uD800"]}\n');
    child.stdin!.write('{"id":2,"op":"tags","names":["\\uDC00"]}\n');
    child.stdin!.write('{"id":"\\uD800","op":"tags","names":["x"]}\n');
    child.stdin!.write('{"id":3,"op":"tags","names":["\\uD83D\\uDE00"]}\n');
    child.stdin!.write(JSON.stringify({ id: 4, op: "skillWrite", dir: collideSkill, files: { "SKILL.md": b64("# new\n") } }) + "\n");
    child.stdin!.end();
  });
  const lines = rawOut.trim().split("\n").map((l) => JSON.parse(l));
  assert.deepEqual(lines, [
    { id: null, error: "unknown memory op " },
    { id: 1, error: "invalid UTF-16 surrogate" },
    { id: 7, error: "invalid UTF-16 surrogate" },
    { id: 2, error: "invalid UTF-16 surrogate" },
    { id: null, error: "invalid UTF-16 surrogate" },
    { id: 3, tags: ["station"] },
    { id: 4, written: true },
  ]);
  assert.equal(readFileSync(join(collideSkill, "SKILL.md"), "utf8"), "# new\n");
  const collideEntries = readdirSync(collideParent).sort();
  assert.equal(collideEntries.length, 3, `expected demo + 2 pre-occupied hidden dirs, got: ${collideEntries.join(", ")}`);
  assert.equal(readFileSync(join(collideParent, collideEntries[0], "keep.txt"), "utf8"), "keep-bak");
  assert.equal(readFileSync(join(collideParent, collideEntries[1], "keep.txt"), "utf8"), "keep-tmp");
});
