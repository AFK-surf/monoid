// Trashing an entry must leave earlier entries recoverable, even when a relative link no longer resolves there.
import assert from "node:assert/strict";
import { lstat, mkdir, mkdtemp, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { toTrash } from "../src/drive/trash.ts";

for (const directory of [false, true]) {
  test(`Finder trash preserves a dangling link when another ${directory ? "folder" : "file"} has its name`, { skip: process.platform === "win32" ? "Windows has no Finder trash and may not allow symlinks" : false }, async (t) => {
    const home = await mkdtemp(join(tmpdir(), "trash-link-"));
    t.after(() => rm(home, { recursive: true, force: true }));
    const source = join(home, "work");
    await mkdir(source);
    await writeFile(join(source, "original.txt"), "original contents");
    const entry = join(source, "report.txt");
    await symlink("original.txt", entry);

    // This is a working link when deleted. Its relative target is absent from the trash afterwards.
    assert.equal(await readFile(entry, "utf8"), "original contents");
    const first = await toTrash(entry, "finder", 0, home);
    assert.equal(first, join(home, ".Trash", "report.txt"));
    assert.equal(await readlink(first!), "original.txt");
    await assert.rejects(readFile(first!), { code: "ENOENT" });

    if (directory) {
      await mkdir(entry);
      await writeFile(join(entry, "kept.txt"), "second contents");
    } else {
      await writeFile(entry, "second contents");
    }
    const second = await toTrash(entry, "finder", 0, home);
    assert.equal(second, join(home, ".Trash", "report 2.txt"));
    assert.equal(await readlink(first!), "original.txt");
    assert.equal(await readFile(directory ? join(second!, "kept.txt") : second!, "utf8"), "second contents");
    assert.equal(await readFile(join(source, "original.txt"), "utf8"), "original contents");
    await assert.rejects(lstat(entry), { code: "ENOENT" });
  });
}
