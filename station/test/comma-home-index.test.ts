import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { workspaceIndex } from "../src/comma/workspace-index.ts";
import { CommaStats, type StationRows } from "../src/comma/stats.ts";

const quiet = () => () => {};
const empty = async () => ({ stations: [], unread: [] });
const row = (thread: number, title: string): StationRows => ({
  usage: { rows: [] }, chats: [{ thread, title, surface: "stillfail", createdAt: 1, lastActiveAt: 2, agents: [] }],
});

test("a home uses only its own persistent index, including on restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "comma-home-index-"));
  await CommaStats.makeDirs(dir);
  const legacy = new CommaStats(join(dir, "comma-stats.db"), empty, quiet);
  try { await legacy.apply([row(1, "unknown owner")], [], 0); } finally { await legacy.close(); }
  const old = CommaStats.inWorkspace(dir, "old-home", empty, quiet);
  try { await old.apply([row(2, "old home")], [], 0); } finally { await old.close(); }
  let home = "new-home", version = 1;
  const next = workspaceIndex(dir, home, () => true, () => version, empty, quiet);
  try {
    assert.equal(await next.stats.taskTitle("1"), "");
    assert.equal(await next.stats.taskTitle("2"), "");
    await next.stats.apply([row(3, "new home")], [], 0);
  } finally { await next.stats.close(); }
  home = "old-home"; version++;
  const reopened = workspaceIndex(dir, home, () => true, () => version, empty, quiet);
  try {
    assert.equal(await reopened.stats.taskTitle("2"), "old home");
    assert.equal(await reopened.stats.taskTitle("3"), "");
  } finally { await reopened.stats.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("different workspace strings do not share an index when UTF-8 would replace a surrogate", async () => {
  const dir = mkdtempSync(join(tmpdir(), "comma-home-keys-"));
  await CommaStats.makeDirs(dir);
  const first = CommaStats.inWorkspace(dir, "workspace-\ud800", empty, quiet);
  const second = CommaStats.inWorkspace(dir, "workspace-\ufffd", empty, quiet);
  try {
    await first.apply([row(1, "only first")], [], 0);
    assert.equal(await second.taskTitle("1"), "");
  } finally { await first.close(); await second.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("a read spanning a home change is discarded, even if that home returns", async () => {
  const dir = mkdtempSync(join(tmpdir(), "comma-home-read-"));
  await CommaStats.makeDirs(dir);
  let home = "one", version = 0, calls = 0;
  let release!: (value: { stations: StationRows[]; unread: string[] }) => void;
  const pending = new Promise<{ stations: StationRows[]; unread: string[] }>((resolve) => { release = resolve; });
  const index = workspaceIndex(dir, "one", () => home === "one", () => version,
    async () => ++calls === 1 ? pending : { stations: [row(1, "current")], unread: [] }, quiet);
  const written: string[] = [];
  const stop = index.stats.tasks.listen(() => void index.stats.taskTitle("1").then((title) => written.push(title)));
  try {
    index.indexes.start();
    home = "two"; version++;
    home = "one"; version++;
    index.indexes.start();
    release({ stations: [row(1, "obsolete")], unread: [] });
    await index.stats.settled();
    assert.equal(await index.stats.taskTitle("1"), "current");
    assert.deepEqual(written, ["current"]);
  } finally { release({ stations: [], unread: [] }); stop(); await index.stats.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("a home change during bounded index preparation discards the old build", async () => {
  const dir = mkdtempSync(join(tmpdir(), "comma-home-prepare-"));
  await CommaStats.makeDirs(dir);
  let home = "one", version = 0, read = false;
  const index = workspaceIndex(dir, "one", () => home === "one", () => version,
    async () => { read = true; return { stations: [row(9, "obsolete")], unread: [] }; }, quiet);
  try {
    const usage = Array.from({ length: 512 }, (_, i) => ({ day: "9999-12-31", session: `s${i}`, runtime: "test", calls: 1 }));
    await index.stats.apply([{ usage: { rows: usage }, chats: row(1, "kept").chats }], [], 0);
    index.indexes.start();
    await new Promise<void>((resolve) => setImmediate(() => { assert.ok(read); home = "two"; version++; resolve(); }));
    await index.stats.settled();
    assert.equal(await index.stats.taskTitle("1"), "kept");
    assert.equal(await index.stats.taskTitle("9"), "");
  } finally { await index.stats.close(); rmSync(dir, { recursive: true, force: true }); }
});
