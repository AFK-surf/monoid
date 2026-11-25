// Windows-only remote filePath validation split out from remote.test.ts so Linux CI runs remote.test.ts with 0 skips.
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { filePath } from "../src/jobs/remote.ts";

test("on Windows a backslash separates too, and a drive, a share or a stream is not relative", { skip: process.platform !== "win32" && "Windows only" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "remote-win-path-"));
  try {
    for (const path of ["..\\outside.txt", "a\\..\\..\\secret", ".\\a", "C:\\Windows\\win.ini", "C:secret", "\\\\server\\share\\x", "\\x", "file:stream"]) {
      await assert.rejects(filePath(dir, path, true), Error, path);
    }
    assert.equal(await filePath(dir, "nested\\file", false), join(dir, "nested", "file"));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
