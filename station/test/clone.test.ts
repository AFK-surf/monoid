// Cross-platform CoW file/tree clone primitive tests (src/ops/clone.ts).
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { cloneFile, clonesAt, cloneTree, sameCloneableVolume } from "../src/ops/clone.ts";
import { platform } from "../src/platform/index.ts";

const dirs: string[] = [];
function scratch(tag: string): string {
  const dir = mkdtempSync(join(tmpdir(), `clone-test-${tag}-`));
  dirs.push(dir);
  return dir;
}

after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// Returns the first extent physical disk offset of `filePath`, or null if unavailable on this OS/FS.
function firstPhysicalOffset(filePath: string): bigint | null {
  if (platform.os === "macos") {
    const out = execFileSync(
      "python3",
      [
        "-c",
        [
          "import fcntl, struct, sys",
          "F_LOG2PHYS = 49",
          "with open(sys.argv[1], 'rb') as f:",
          "    # struct log2phys is #pragma pack(4): u_int32_t flags (4) + off_t contigbytes (8) + off_t devoffset (8) = 20 bytes",
          "    buf = fcntl.fcntl(f.fileno(), F_LOG2PHYS, b'\\x00' * 20)",
          "    _, _, devoffset = struct.unpack('<Iqq', buf[:20])",
          "    print(devoffset)",
        ].join("\n"),
        filePath,
      ],
      { encoding: "utf8" },
    ).trim();
    return BigInt(out);
  }
  if (platform.os === "linux") {
    const out = execFileSync(
      "python3",
      [
        "-c",
        [
          "import fcntl, struct, sys",
          "FS_IOC_FIEMAP = 0xC020660B",
          "with open(sys.argv[1], 'rb') as f:",
          "    # struct fiemap (32B) + 1 fiemap_extent (56B) = 88B",
          "    req = bytearray(struct.pack('=QQIIII', 0, 1 << 60, 0, 0, 1, 0) + b'\\x00' * 56)",
          "    fcntl.ioctl(f.fileno(), FS_IOC_FIEMAP, req, True)",
          "    mapped = struct.unpack_from('=I', req, 20)[0]",
          "    if mapped < 1:",
          "        print(-1)",
          "    else:",
          "        phys = struct.unpack_from('=Q', req, 32 + 8)[0]",
          "        print(phys)",
        ].join("\n"),
        filePath,
      ],
      { encoding: "utf8" },
    ).trim();
    const val = BigInt(out);
    return val < 0n ? null : val;
  }
  return null;
}

describe("src/ops/clone.ts", () => {
  test("cloneFile performs true CoW clone on >=64 KiB file, preserves independence, and refreshes mtime", async (t) => {
    const dir = scratch("cow");
    const canClone = await clonesAt(dir);
    assert.equal(await sameCloneableVolume(dir, dir), canClone);

    const src = join(dir, "src.bin");
    const dst = join(dir, "dst.bin");
    const payload = Buffer.alloc(128 * 1024, 0x41);
    writeFileSync(src, payload);
    const oldTime = new Date("2020-01-01T00:00:00Z");
    utimesSync(src, oldTime, oldTime);

    const beforeMs = Date.now();
    await cloneFile(src, dst);

    const stSrc = statSync(src);
    const stDst = statSync(dst);
    assert.notEqual(stSrc.ino, stDst.ino, "cloned file must have its own inode");
    assert.equal(stDst.nlink, 1, "cloned file must not be a hard link");
    assert.deepEqual(readFileSync(dst), payload);
    assert.ok(stDst.mtimeMs >= beforeMs - 2_000, `target mtime (${stDst.mtimeMs}) must be refreshed near now (${beforeMs})`);

    if (!canClone) {
      t.diagnostic("filesystem does not support CoW cloning; skipped physical extent offset assertion");
      return;
    }

    const offSrc = firstPhysicalOffset(src);
    const offDst = firstPhysicalOffset(dst);
    assert.ok(offSrc !== null && offSrc > 0n, `expected positive physical offset for src, got ${offSrc}`);
    assert.equal(offSrc, offDst, "CoW clone must share the same first-extent physical offset");

    // Mutating the clone must not affect the source.
    const modified = Buffer.alloc(128 * 1024, 0x42);
    writeFileSync(dst, modified);
    assert.deepEqual(readFileSync(src), payload, "source bytes must remain unchanged after mutating clone");
    assert.deepEqual(readFileSync(dst), modified);
  });

  test("8 concurrent cloneFile(..., { excl: true }) race: exactly 1 succeeds, 7 throw EEXIST, zero leftover .clone-* files", async () => {
    const dir = scratch("excl-race");
    const src = join(dir, "src.bin");
    const dst = join(dir, "target.bin");
    writeFileSync(src, Buffer.alloc(96 * 1024, 0x5a));

    const results = await Promise.allSettled(Array.from({ length: 8 }, () => cloneFile(src, dst, { excl: true })));
    const ok = results.filter((r) => r.status === "fulfilled");
    const errs = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");

    assert.equal(ok.length, 1, `expected exactly 1 winner, got ${ok.length}`);
    assert.equal(errs.length, 7, `expected 7 rejections, got ${errs.length}`);
    for (const e of errs) {
      assert.equal((e.reason as NodeJS.ErrnoException).code, "EEXIST");
    }
    const leftovers = readdirSync(dir).filter((n) => n.startsWith(".clone-"));
    assert.deepEqual(leftovers, [], "no leftover .clone-* temp files");
  });

  test("small (<64 KiB) cloneFile strictly enforces excl: true", async () => {
    const dir = scratch("small-excl");
    const src = join(dir, "small.txt");
    const dst = join(dir, "dst.txt");
    writeFileSync(src, "hello small");

    await cloneFile(src, dst, { excl: true });
    assert.equal(readFileSync(dst, "utf8"), "hello small");
    await assert.rejects(() => cloneFile(src, dst, { excl: true }), (err: NodeJS.ErrnoException) => err.code === "EEXIST");
  });

  test("cloneTree clones directory contents on cloneable volumes and preserves independence", async (t) => {
    const dir = scratch("tree");
    if (!(await clonesAt(dir))) {
      t.skip("filesystem does not support CoW cloning");
      return;
    }
    const srcDir = join(dir, "src");
    const dstDir = join(dir, "dst");
    mkdirSync(join(srcDir, "nested"), { recursive: true });
    const big = Buffer.alloc(96 * 1024, 0x33);
    writeFileSync(join(srcDir, "nested", "big.bin"), big);
    writeFileSync(join(srcDir, "small.txt"), "abc\n");

    await cloneTree(srcDir, dstDir);
    assert.deepEqual(readFileSync(join(dstDir, "nested", "big.bin")), big);
    assert.equal(readFileSync(join(dstDir, "small.txt"), "utf8"), "abc\n");

    const offSrc = firstPhysicalOffset(join(srcDir, "nested", "big.bin"));
    const offDst = firstPhysicalOffset(join(dstDir, "nested", "big.bin"));
    assert.ok(offSrc !== null && offSrc > 0n);
    assert.equal(offSrc, offDst, "cloneTree must preserve CoW physical extent sharing");

    writeFileSync(join(dstDir, "small.txt"), "changed\n");
    assert.equal(readFileSync(join(srcDir, "small.txt"), "utf8"), "abc\n");
  });
});
