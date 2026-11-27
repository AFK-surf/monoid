// Tests for remote/sessions/*.gone-* read-only directory cleanup, hardlink mode preservation,
// and tombstone isolation across rooms(), close, budget, and sweep.
import assert from "node:assert/strict";
import { chmodSync, existsSync, linkSync, mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, describe, test } from "node:test";
import { Jobs } from "../src/jobs/jobs.ts";
import { IDLE_MS, Remote } from "../src/jobs/remote.ts";
import { platform } from "../src/platform/index.ts";
import { removeTree } from "../src/sessions/archive.ts";
import { Store } from "../src/store/store.ts";
import { killGroups } from "./kill-groups.ts";

const dirs: string[] = [];
const cleanup: (() => Promise<void> | void)[] = [];

after(async () => {
  for (const c of cleanup.reverse()) await c();
  for (const d of dirs) {
    await removeTree(d, { force: true }).catch(() => {});
  }
});

function makeStation(removeTask?: (path: string) => Promise<void>) {
  const dir = mkdtempSync(join(tmpdir(), "remote-gone-"));
  dirs.push(dir);
  const store = Store.open(":memory:");
  const jobs = new Jobs({ store, data: dir, notify: () => {}, link: () => null });
  const remote = new Remote({ data: dir, store, jobs, notify: () => {}, version: "0.1.1", removeTask });
  cleanup.push(async () => {
    await remote.close();
    await jobs.shutdown();
    await killGroups(store.listJobs(null).map((job) => job.pgid));
    store.close();
  });
  return { dir, store, jobs, remote };
}

/// Populates a remote room with a 0o555 read-only dir, a 0o444 file, and a hard link (nlink=2, mode 0o444)
/// to an external shared file (simulating pnpm store).
function populateReadOnlyRoom(roomDir: string, externalFile: string, workspace: string, peer: string, session: string, seen: number): void {
  const roDir = join(roomDir, "work", "ro-pkg");
  mkdirSync(roDir, { recursive: true });
  writeFileSync(join(roomDir, "session.json"), JSON.stringify({ workspace, station: peer, session, seen }));
  const roFile = join(roDir, "readonly.txt");
  writeFileSync(roFile, Buffer.alloc(2 * 1024 * 1024, 0x61));
  const linked = join(roDir, "shared-store-file.js");
  linkSync(externalFile, linked);
  if (platform.os !== "windows") {
    chmodSync(roFile, 0o444);
    chmodSync(roDir, 0o555);
  }
}

describe("remote .gone-* read-only cleanup and tombstone isolation", () => {
  test("session.close, budget, and sweep cleanly remove read-only rooms without chmod-ing external hardlinked files", async () => {
    const extDir = mkdtempSync(join(tmpdir(), "remote-gone-ext-"));
    dirs.push(extDir);
    const sharedFile = join(extDir, "pnpm-store-entry.js");
    writeFileSync(sharedFile, "module.exports = 1;\n");
    if (platform.os !== "windows") chmodSync(sharedFile, 0o444);

    // 1. session.close
    {
      const r = makeStation();
      const roomDir = r.remote.room("ws", "peer-a", "s-close");
      populateReadOnlyRoom(roomDir, sharedFile, "ws", "peer-a", "s-close", Date.now());
      assert.equal(statSync(sharedFile).nlink, 2);

      const ans = await r.remote.handle("ws", "peer-a", { method: "session.close", session: "s-close" });
      assert.deepEqual(ans, { closed: true });
      const left = readdirSync(join(r.remote.root, "sessions"));
      assert.deepEqual(left, [], `expected no leftover room or .gone-* after session.close, got ${left.join(",")}`);
      if (platform.os !== "windows") {
        assert.equal(statSync(sharedFile).mode & 0o777, 0o444, "external hardlinked file mode must stay 0o444");
      }
    }

    // 2. budget
    {
      const r = makeStation();
      const now = Date.now();
      const roomDir = r.remote.room("ws", "peer-a", "s-budget");
      populateReadOnlyRoom(roomDir, sharedFile, "ws", "peer-a", "s-budget", now - 3 * 24 * 3600_000);

      const freed = await r.remote.budget(now, 1024);
      assert.ok(freed > 0, `expected budget to free bytes, got ${freed}`);
      const left = readdirSync(join(r.remote.root, "sessions"));
      assert.deepEqual(left, [], `expected no leftover room or .gone-* after budget, got ${left.join(",")}`);
      if (platform.os !== "windows") {
        assert.equal(statSync(sharedFile).mode & 0o777, 0o444, "external hardlinked file mode must stay 0o444 after budget");
      }
    }

    // 3. sweep (idle room)
    {
      const r = makeStation();
      const now = Date.now();
      const roomDir = r.remote.room("ws", "peer-a", "s-sweep");
      populateReadOnlyRoom(roomDir, sharedFile, "ws", "peer-a", "s-sweep", now - IDLE_MS - 60_000);

      await r.remote.sweep(now);
      const left = readdirSync(join(r.remote.root, "sessions"));
      assert.deepEqual(left, [], `expected no leftover room or .gone-* after sweep, got ${left.join(",")}`);
      if (platform.os !== "windows") {
        assert.equal(statSync(sharedFile).mode & 0o777, 0o444, "external hardlinked file mode must stay 0o444 after sweep");
      }
    }
  });

  test("failed removal leaving <64hex>.gone-<8hex> tombstone is ignored by rooms()/budget and cleaned by sweep without harming live room", async () => {
    let failNext = true;
    const r = makeStation(async (path) => {
      if (failNext) {
        failNext = false;
        throw Object.assign(new Error("injected removal failure"), { code: "EACCES" });
      }
      await removeTree(path, { force: true });
    });

    const now = Date.now();
    const roomDir = r.remote.room("ws", "peer-a", "s-tomb");
    mkdirSync(join(roomDir, "work"), { recursive: true });
    writeFileSync(join(roomDir, "session.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "s-tomb", seen: now - 3 * 24 * 3600_000 }));
    writeFileSync(join(roomDir, "work", "big.bin"), Buffer.alloc(2 * 1024 * 1024, 0x77));

    // Trigger budget: first removeTask fails, leaving <64hex>.gone-<8hex> containing session.json.
    const freed1 = await r.remote.budget(now, 1024);
    assert.equal(freed1, 0, "failed removal must not count as freed bytes");
    const sessionsDir = join(r.remote.root, "sessions");
    const afterFail = readdirSync(sessionsDir);
    assert.equal(afterFail.length, 1);
    assert.match(afterFail[0]!, /^[0-9a-f]{64}\.gone-[0-9a-f]{8}$/, "tombstone must have single .gone-<8hex> suffix");
    assert.ok(existsSync(join(sessionsDir, afterFail[0]!, "session.json")), "tombstone still contains session.json");

    // Re-create a fresh live room for the same session.
    mkdirSync(join(roomDir, "work"), { recursive: true });
    writeFileSync(join(roomDir, "session.json"), JSON.stringify({ workspace: "ws", station: "peer-a", session: "s-tomb", seen: now }));
    writeFileSync(join(roomDir, "work", "live.txt"), "alive\n");

    // Run budget again: rooms() must ignore the tombstone (never append a second .gone-* suffix!).
    const freed2 = await r.remote.budget(now, 1024);
    assert.equal(freed2, 0, "recent live room stays and tombstone is not re-closed by budget");
    const afterBudget2 = readdirSync(sessionsDir).sort();
    assert.ok(afterBudget2.every((n) => !/\.gone-[0-9a-f]{8}\.gone-/.test(n)), `must not double-suffix tombstones: ${afterBudget2.join(",")}`);

    // Run sweep: must delete the tombstone immediately without harming the new live room!
    await r.remote.sweep(now);
    const afterSweep = readdirSync(sessionsDir);
    assert.equal(afterSweep.length, 1, `only live room should remain, got ${afterSweep.join(",")}`);
    assert.match(afterSweep[0]!, /^[0-9a-f]{64}$/);
    assert.equal(existsSync(join(roomDir, "work", "live.txt")), true, "live room must be untouched by tombstone sweep");
  });

  test("cross-engine handover: Reader sweep drains <remote.root>/tombstones/* left by Pion station-main", async () => {
    const r = makeStation();
    const tombDir = join(r.remote.root, "tombstones", ".gone-monoid-1700000000000-1");
    const roNested = join(tombDir, "pkg", "ro");
    mkdirSync(roNested, { recursive: true });
    writeFileSync(join(roNested, "artifact.txt"), "leftover\n");
    if (platform.os !== "windows") {
      chmodSync(roNested, 0o555);
    }

    await r.remote.sweep(Date.now());
    const remaining = readdirSync(join(r.remote.root, "tombstones"));
    assert.deepEqual(remaining, [], `expected Reader sweep to drain remote/tombstones, got ${remaining.join(",")}`);
  });
});
