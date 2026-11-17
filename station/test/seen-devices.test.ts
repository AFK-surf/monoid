// The devices that came to a station (src/mesh/seen-devices.ts): kept on disk off the station's thread, so a device's
// connection waits on no file, and read back after a restart once written.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { SeenDevices } from "../src/mesh/seen-devices.ts";
import { timeFiles } from "../src/ops/file-waits.ts";

test("a device seen is kept without the station's thread waiting on the disk, and read back after a restart", async () => {
  const path = join(mkdtempSync(join(tmpdir(), "seen-devices-")), "mesh", "seen.json");
  const seen = new SeenDevices(path);
  const timed = timeFiles();
  try {
    for (let i = 0; i < 50; i++) seen.saw(1000 + i, { workspace: "w1", sub: `s${i % 5}`, email: `${i % 5}@x` }, `d${i}`, null, { kind: "app", label: `#${i}` });
    await seen.written();
    assert.equal(timed.take().calls, 0);
  } finally {
    timed.stop();
  }
  const again = new SeenDevices(path);
  assert.deepEqual(again.of("w1", 2000, "s0", true), seen.of("w1", 2000, "s0", true));
  assert.equal(again.of("w1", 2000, "s0", true).length, 50);
});
