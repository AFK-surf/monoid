// The machine's own flush of what a placing took (replica/sending.ts `flushOnce`), run once: the test world's stations
// count theirs and run none (move-world.ts).
import assert from "node:assert/strict";
import { existsSync, mkdtempSync } from "node:fs";
import { rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { flushOnce, flushesOnce } from "../src/replica/sending.ts";

test("the machine's flush of a directory's file system runs and flushes its one file there", { skip: flushesOnce ? false : "no flush of a file system at once on this machine" }, async () => {
  const dir = mkdtempSync(join(tmpdir(), "flush-once-"));
  try {
    await flushOnce(dir);
    assert.ok(existsSync(join(dir, "flushed")));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
