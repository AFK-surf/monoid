import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { direct } from "../src/drive/fs.ts";
import { zipFolder } from "../src/drive/zip.ts";

for (const zone of ["America/Chicago", "UTC", "Asia/Shanghai"]) {
  test(`zipFolder: timestamps fit the ZIP date in ${zone}`, async () => {
    const base = await mkdtemp(join(tmpdir(), "zip-time-"));
    const before = process.env.TZ;
    process.env.TZ = zone;
    try {
      const dir = join(base, "folder");
      await mkdir(dir);
      await writeFile(join(dir, "file.txt"), "contents");
      const cases = [
        { ms: 0, date: [1980, 1, 1], time: [0, 0, 0] },
        { ms: new Date(1980, 0, 1).getTime() - 1, date: [1980, 1, 1], time: [0, 0, 0] },
        { ms: Date.UTC(1980, 0, 1), date: [1980, 1, 1], time: [zone === "Asia/Shanghai" ? 8 : 0, 0, 0] },
        { ms: new Date(2024, 5, 7, 13, 14, 15).getTime(), date: [2024, 6, 7], time: [13, 14, 14] },
        { ms: new Date(2108, 0, 1).getTime() - 1, date: [2107, 12, 31], time: [23, 59, 58] },
        { ms: new Date(2108, 0, 1).getTime(), date: [2107, 12, 31], time: [23, 59, 58] },
        { ms: Date.UTC(2108, 0, 1), date: [2107, 12, 31], time: zone === "America/Chicago" ? [18, 0, 0] : [23, 59, 58] },
        { ms: Date.UTC(2200, 0, 1), date: [2107, 12, 31], time: [23, 59, 58] },
      ];
      for (const [i, wanted] of cases.entries()) {
        const to = join(base, `${i}.zip`);
        // Controlled file and folder timestamps, independent of the disk's clock and timestamp range.
        const fs = { ...direct, lstat: async (path: string) => ({ ...await direct.lstat(path), mtimeMs: wanted.ms }) };
        await zipFolder(dir, to, 1024, async () => false, fs);
        const zip = await readFile(to);
        const end = zip.length - 22;
        assert.equal(zip.readUInt32LE(end), 0x06054b50);
        assert.equal(zip.readUInt16LE(end + 10), 2);
        let at = zip.readUInt32LE(end + 16);
        for (let n = 0; n < 2; n++) {
          assert.equal(zip.readUInt32LE(at), 0x02014b50);
          const local = zip.readUInt32LE(at + 42);
          const date = zip.readUInt16LE(at + 14);
          const time = zip.readUInt16LE(at + 12);
          assert.deepEqual([1980 + (date >> 9), (date >> 5) & 15, date & 31], wanted.date);
          assert.deepEqual([time >> 11, (time >> 5) & 63, (time & 31) * 2], wanted.time);
          assert.deepEqual([zip.readUInt16LE(local + 12), zip.readUInt16LE(local + 10)], [date, time]);
          at += 46 + zip.readUInt16LE(at + 28) + zip.readUInt16LE(at + 30) + zip.readUInt16LE(at + 32);
        }
      }
    } finally {
      if (before === undefined) delete process.env.TZ;
      else process.env.TZ = before;
      await rm(base, { recursive: true, force: true });
    }
  });
}
