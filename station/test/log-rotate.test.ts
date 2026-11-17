// A log other processes hold open with O_APPEND, cut where it is (src/ops/storage.ts `rotateInPlace`): launchd and
// systemd give stillfail.log to the launcher, the front and Node that way, and a job's shell opens its log with `>>`.
// Renamed or unlinked, they would write on into a file no name reaches; cut, each writer's next write lands at its start.
import assert from "node:assert/strict";
import { openSync, closeSync, readFileSync, statSync, writeSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { rotateInPlace } from "../src/ops/storage.ts";
import { tempDir } from "./temp-dir.ts";

test("a log held open for appending is cut where it is: same inode, no hole, what it had kept in .1", async () => {
  const dir = tempDir(join(tmpdir(), "rot-"));
  const log = join(dir, "stillfail.log");
  // As launchd opens it for the launcher (O_RDWR|O_APPEND), never closed meanwhile.
  const held = openSync(log, "a+");
  try {
    const before = Buffer.from("line of before\n".repeat(1000));
    writeSync(held, before);
    const inode = statSync(log).ino;
    assert.equal(await rotateInPlace(log, 1024), true, "past its cap: cut");
    assert.equal(statSync(log).ino, inode, "the same file: no writer loses it");
    assert.equal(statSync(log).size, 0);
    // What it kept: its last cap's worth (here the cap is the whole of what is kept).
    const kept = readFileSync(`${log}.1`);
    assert.equal(kept.length, 1024);
    assert.deepEqual(kept, before.subarray(before.length - 1024));
    assert.ok(!existsSync(`${log}.1.tmp`));
    // The holder writes on through its old descriptor: at the new end, not at its old offset (no hole of zeros).
    writeSync(held, "after\n");
    assert.equal(statSync(log).size, 6, "at the start again");
    assert.equal(readFileSync(log, "utf8"), "after\n");
    // Within its cap: nothing.
    assert.equal(await rotateInPlace(log, 1024), false);
  } finally {
    closeSync(held);
  }
});

test("a cut keeps all of what was there when its cap is above it, and the .1 before is replaced", async () => {
  const dir = tempDir(join(tmpdir(), "rot-"));
  const log = join(dir, "job.log");
  const held = openSync(log, "a");
  try {
    writeSync(held, "a".repeat(100));
    assert.equal(await rotateInPlace(log, 50, 1000), true);
    assert.equal(readFileSync(`${log}.1`, "utf8"), "a".repeat(100));
    writeSync(held, "b".repeat(60));
    assert.equal(await rotateInPlace(log, 50, 1000), true);
    assert.equal(readFileSync(`${log}.1`, "utf8"), "b".repeat(60), "the one before replaced: at most twice the cap");
    assert.equal(statSync(log).size, 0);
  } finally {
    closeSync(held);
  }
});

test("a log that is not there is no error", async () => {
  assert.equal(await rotateInPlace(join(tmpdir(), "no-such-log-here"), 1), false);
});
