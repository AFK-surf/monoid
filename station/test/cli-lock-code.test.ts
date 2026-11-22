// `stillfail lock status` and `stillfail status` say this machine's security code wherever its person may be asked
// for it: waiting for a lock (`enroll --lock`, or its owner's check of a rig, FB-45) with the code to check, and off
// in a workspace with the code all the same, so whoever checks a rig in the app reads it at the machine. Pinned, as
// before.
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { entryHash, shortCode } from "../../shared/lock.ts";
import { lockCommand, status } from "../src/cli.ts";
import { Cloud, pendingLockPath, writeState } from "../src/cloud/state.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { WS, ed, world } from "./lock-moved-world.ts";

const say = (key: string, args?: Record<string, unknown>) => tr(stationLang(), key, args);

function machine(rig: boolean, more: Record<string, unknown> = {}) {
  const key = ed();
  const data = mkdtempSync(join(tmpdir(), "cli-lock-code-"));
  writeState(data, {
    origin: "https://app.still.fail", station: key.hex, workspace: WS, workspace_name: "Team", name: "build-box", relay_url: "", relay_urls: [],
    grant_keys: { keys: [] }, peers: [], revocations: [],
    ...(rig ? { rig: { owner: "alice", owner_email: "alice@x", owner_name: "alice", person: "ab".repeat(32) } } : {}),
    ...more,
  });
  return { data, code: shortCode(key.hex) };
}

test("a security code is read off a station's id as the app reads it (lock-form.ts `shortCodeOf`), the same as sfpages' `station_short_code`", () => {
  assert.equal(shortCode("0".repeat(64)), "3EL-E55");
  assert.equal(shortCode("a7".repeat(32)), "5XC-L6N");
  assert.equal(shortCode("0123456789abcdef".repeat(4)), "D4A-K4W");
});

test("`lock status`: waiting for a lock with the code to check, off in a workspace with its code, pinned as before (FB-45)", () => {
  // A rig that joined before safe mode: off, and its code.
  const off = machine(true);
  assert.equal(lockCommand(off.data, "status"), `${say("station.cli.lock.none")}\n${say("station.cli.lock.code", { code: off.code })}`);
  assert.ok(status(off.data).split("\n").includes(say("station.cli.lock.code", { code: off.code })), status(off.data));
  // Its owner checked it: waiting for the lock named, the code to check (a rig's words, a whole station's).
  const w = world();
  writeFileSync(pendingLockPath(off.data), JSON.stringify({ hash: entryHash(w.first) }));
  assert.equal(lockCommand(off.data, "status"), say("station.cli.rig.pending", { code: off.code }));
  assert.ok(status(off.data).split("\n").includes(say("station.cli.rig.pending", { code: off.code })), status(off.data));
  const whole = machine(false);
  writeFileSync(pendingLockPath(whole.data), JSON.stringify({ hash: entryHash(w.first) }));
  assert.equal(lockCommand(whole.data, "status"), say("station.cli.lock.pending", { code: whole.code }));
  // Pinned: as before, no code.
  const cloud = new Cloud(off.data, false);
  cloud.takeLock([w.first]);
  const pinned = lockCommand(off.data, "status");
  assert.match(pinned, new RegExp(say("station.cli.lock.status", { seq: 0, hash: entryHash(w.first).slice(0, 16), members: 3, devices: 3, stations: 2 }).replace(/[()…]/g, ".")));
  assert.ok(!pinned.includes(off.code));
  // Removed from its workspace: off, no code.
  const removed = machine(false, { removed_at: 1 });
  assert.equal(lockCommand(removed.data, "status"), say("station.cli.lock.none"));
  assert.ok(!status(removed.data).includes(removed.code));
});
