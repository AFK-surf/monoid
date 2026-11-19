// What runs out on the station's machine said before it does (ops/forewarn.ts): as it starts, again every ten minutes
// while it lasts, a relay's conflict once until it ends.
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Forewarn, LARGE_WAL_BYTES, type Look, lookAt, SAY_AGAIN_MS } from "../src/ops/forewarn.ts";

const MiB = 1_048_576;
const fine: Look = { diskFree: 100_000 * MiB, diskTotal: 500_000 * MiB, walBytes: 4 * MiB, openFds: 120, rss: 300 * MiB, relayConflict: false };
const said = (f: Forewarn, look: Partial<Look>, now: number) => f.look({ ...fine, ...look }, now).map((w) => w.message);

test("nothing is said while nothing runs out", () => {
  assert.deepEqual(new Forewarn().look(fine, 0), []);
});

test("a low disk is said as it starts and every ten minutes while it lasts, by what is free or its share", () => {
  const f = new Forewarn();
  const low = f.look({ ...fine, diskFree: 1_500 * MiB }, 0);
  assert.deepEqual(low, [{ at: "station", message: "low disk space on data directory", fields: { diskFreeMb: 1_500, diskTotalMb: 500_000, freePct: 0.3 } }]);
  assert.deepEqual(said(f, { diskFree: 1_500 * MiB }, 10_000), []);
  assert.deepEqual(said(f, { diskFree: 1_400 * MiB }, SAY_AGAIN_MS - 1), []);
  assert.deepEqual(said(f, { diskFree: 1_400 * MiB }, SAY_AGAIN_MS), ["low disk space on data directory"]);
  // Back to fine, then low again: said at once.
  assert.deepEqual(said(f, {}, SAY_AGAIN_MS + 10_000), []);
  assert.deepEqual(said(f, { diskFree: 1_400 * MiB }, SAY_AGAIN_MS + 20_000), ["low disk space on data directory"]);
  // A small disk: 4 % of it free is low though past 2 GiB.
  assert.deepEqual(new Forewarn().look({ ...fine, diskFree: 4_000 * MiB, diskTotal: 100_000 * MiB }, 0)[0]?.fields, { diskFreeMb: 4_000, diskTotalMb: 100_000, freePct: 4 });
  // Not said where the system says nothing of the disk.
  assert.deepEqual(said(new Forewarn(), { diskFree: null, diskTotal: null }, 0), []);
});

test("a large database log and many descriptors are said, with what goes with them", () => {
  const f = new Forewarn();
  assert.deepEqual(f.look({ ...fine, walBytes: LARGE_WAL_BYTES }, 0), []);
  assert.deepEqual(f.look({ ...fine, walBytes: 300 * MiB, openFds: 2_048 }, 0), [
    { at: "store", message: "database WAL file is large", fields: { walMb: 300 } },
    { at: "station", message: "high open file descriptor count", fields: { openFds: 2_048, rssMb: 300 } },
  ]);
  assert.deepEqual(new Forewarn().look({ ...fine, openFds: 5_000, rss: null }, 0)[0]?.fields, { openFds: 5_000 });
  assert.deepEqual(said(new Forewarn(), { openFds: null }, 0), []);
});

test("a relay's conflict is said once as it starts, and again only after it ended", () => {
  const f = new Forewarn();
  assert.deepEqual(f.look({ ...fine, relayConflict: true }, 0), [{ at: "mesh", message: "relay reports another endpoint with this station key", fields: {} }]);
  assert.deepEqual(said(f, { relayConflict: true }, 10_000), []);
  assert.deepEqual(said(f, { relayConflict: true }, 3 * SAY_AGAIN_MS), []);
  assert.deepEqual(said(f, { relayConflict: false }, 3 * SAY_AGAIN_MS + 10_000), []);
  assert.deepEqual(said(f, { relayConflict: true }, 3 * SAY_AGAIN_MS + 20_000), ["relay reports another endpoint with this station key"]);
});

test("what is looked at: the data directory's disk, its database's log, the process's own", async () => {
  const dir = mkdtempSync(join(tmpdir(), "forewarn-"));
  try {
    const none = await lookAt(dir, false);
    assert.equal(none.walBytes, 0);
    writeFileSync(join(dir, "stillfail.db-wal"), Buffer.alloc(4096));
    const l = await lookAt(dir, true);
    assert.equal(l.walBytes, 4096);
    assert.equal(l.relayConflict, true);
    assert.ok(l.diskTotal !== null && l.diskTotal > 0 && l.diskFree !== null && l.diskFree <= l.diskTotal);
    assert.ok(l.rss !== null && l.rss > 0);
    if (process.platform !== "win32") assert.ok(l.openFds !== null && l.openFds > 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
