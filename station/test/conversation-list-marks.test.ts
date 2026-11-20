import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { Readers } from "../src/read/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { autoArchive, ensureConversationChat } from "../src/sessions/lifecycle.ts";
import { MANUAL } from "../src/store/rows.ts";
import { Store } from "../src/store/store.ts";
import { FakeDriver } from "./hub-fakes.ts";
import { openStore } from "./reference/store.ts";
import { sharedChats } from "./reference/views.ts";

const viewer = { sub: "u", email: "ada@example.com", name: "Ada", role: "member", workspace: null as unknown as string, device: "d" };

function setup() {
  const data = mkdtempSync(join(tmpdir(), "conv-lm-"));
  const raw = { profiles: [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["opus"] }, { id: "cx", runtime: "codex", home: "homes/cx" }] };
  const config = hubConfig(raw, data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const hub = new Hub({
    config: () => config,
    store,
    chats: () => undefined,
    drivers: [new FakeDriver("claude"), new FakeDriver("codex")],
    mcpUrl: "http://127.0.0.1:1/mcp",
    internal: new InternalChat(),
    runners: () => [],
  });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.processes();
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const ask = async (method: string, path: string, body?: unknown, query: [string, string][] = []) => {
    const buf = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body));
    const r: Request = { method, path, query, headers: {}, body: buf, viewer: { ...viewer, workspace: "" }, lang: "en" };
    const a = await admin.handle(r);
    return [a.status, JSON.parse(String(a.body))] as const;
  };
  const close = async () => {
    await readers.close();
    await hub.shutdown();
    store.close();
    rmSync(data, { recursive: true, force: true });
  };
  return { data, store, hub, readers, admin, ask, close };
}

test("shared_rows merges unchatted Slack thread into one row, preserves id across chat creation and archive (§4 L)", async () => {
  const r = setup();
  try {
    const slack = r.store.openThread("slack:T1", "C1", "100.1", "Team thread", "U1");
    r.store.insertSession({
      key: "bot1:C1:100.1", connect: "bot1", scope: "thread", title: null,
      runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "bot2:C1:100.1", connect: "bot2", scope: "thread", title: null,
      runtime: "codex", profile: "cx", workspace: "/w/2", token: "t2", createdAt: 2000, lastActiveAt: 5000,
    });
    r.store.joinThread(slack.id, "bot1:C1:100.1", "bot1");
    r.store.joinThread(slack.id, "bot2:C1:100.1", "bot2");
    r.store.insertSession({
      key: "single:s-1", connect: "single", scope: "all", title: "Single",
      runtime: "claude", profile: "cc", workspace: "/w/s", token: "ts", createdAt: 500, lastActiveAt: 500,
    });
    r.store.joinThread(slack.id, "single:s-1", "single");
    r.store.insertSession({
      key: "other:C2:999.9", connect: "other", scope: "thread", title: "Relayed",
      runtime: "claude", profile: "cc", workspace: "/w/o", token: "to", createdAt: 500, lastActiveAt: 500,
    });
    r.store.joinThread(slack.id, "other:C2:999.9", "other");

    const v = { email: "ada@example.com", workspace: null };
    const mbRows = JSON.parse(await r.readers.read("chats", { viewer: v, words: { untitled: "Untitled", directMessage: "DM" }, archived: false }, "en"));
    const refStore = openStore(r.data);
    const refRows = sharedChats(refStore, false);
    refStore.db.close();

    const mbConv = mbRows.filter((row: any) => row.id === "bot1:C1:100.1" || row.id === "bot2:C1:100.1");
    assert.equal(mbConv.length, 1);
    assert.equal(mbConv[0].id, "bot1:C1:100.1");
    assert.equal(mbConv[0].lastActiveAt, 5000);
    assert.deepEqual(mbConv[0].agents.map((a: any) => a.key).sort(), ["bot1:C1:100.1", "bot2:C1:100.1"]);

    const refConv = refRows.filter((row: any) => row.id === "bot1:C1:100.1" || row.id === "bot2:C1:100.1");
    assert.equal(refConv.length, 1);
    assert.equal(refConv[0].id, "bot1:C1:100.1");
    assert.equal(refConv[0].lastActiveAt, 5000);
    assert.deepEqual(refConv[0].agents.map((a: any) => a.key).sort(), ["bot1:C1:100.1", "bot2:C1:100.1"]);

    // Session summary includes `conv` for non-anchor member and omits it for anchor.
    const s1 = JSON.parse(await r.readers.read("summary", { key: "bot1:C1:100.1" }, "en"));
    const s2 = JSON.parse(await r.readers.read("summary", { key: "bot2:C1:100.1" }, "en"));
    assert.equal(s1.conv, undefined);
    assert.equal(s2.conv, "bot1:C1:100.1");

    // Left member does not appear as a second row once home chat is created, and row id stays anchor.
    r.store.leaveThread(slack.id, "bot2:C1:100.1");
    const home = ensureConversationChat(r.hub, "bot1:C1:100.1", "ada@example.com", null);
    assert.equal(home.home, "bot1:C1:100.1");
    const mbAfterHome = JSON.parse(await r.readers.read("chats", { viewer: v, words: { untitled: "Untitled", directMessage: "DM" }, archived: false }, "en"));
    const convAfterHome = mbAfterHome.filter((row: any) => row.id === "bot1:C1:100.1" || row.id === "bot2:C1:100.1");
    assert.equal(convAfterHome.length, 1);
    assert.equal(convAfterHome[0].id, "bot1:C1:100.1");
    assert.equal(convAfterHome[0].thread, home.id);

    // Archiving yields 1 archived row with stable id = anchor.
    r.store.setArchived("bot2:C1:100.1", true, MANUAL);
    const mbArchived = JSON.parse(await r.readers.read("chats", { viewer: v, words: { untitled: "Untitled", directMessage: "DM" }, archived: true }, "en"));
    const convArchived = mbArchived.filter((row: any) => row.id === "bot1:C1:100.1" || row.id === "bot2:C1:100.1");
    assert.equal(convArchived.length, 1);
    assert.equal(convArchived[0].id, "bot1:C1:100.1");
  } finally {
    await r.close();
  }
});

test("marks: pin normalization, unpin all members, legacy non-anchor pin folding, rename, auto-archive pin protection (§4 M)", async () => {
  const r = setup();
  try {
    const slack = r.store.openThread("slack:T1", "C1", "200.1", "T", "U1");
    r.store.insertSession({
      key: "b1:C1:200.1", connect: "b1", scope: "thread", title: null,
      runtime: "claude", profile: "cc", workspace: "/w/1", token: "t1", createdAt: 1000, lastActiveAt: 1000,
    });
    r.store.insertSession({
      key: "b2:C1:200.1", connect: "b2", scope: "thread", title: null,
      runtime: "claude", profile: "cc", workspace: "/w/2", token: "t2", createdAt: 2000, lastActiveAt: 2000,
    });
    r.store.joinThread(slack.id, "b1:C1:200.1", "b1");
    r.store.joinThread(slack.id, "b2:C1:200.1", "b2");
    const home = ensureConversationChat(r.hub, "b1:C1:200.1", "ada@example.com", null);

    // Pin via non-anchor writes to anchor.
    const [pinSt, pinRes] = await r.ask("PUT", `/sessions/${encodeURIComponent("b2:C1:200.1")}/pin`);
    assert.equal(pinSt, 200);
    assert.equal(pinRes.session, "b1:C1:200.1");
    assert.equal(pinRes.pinned, true);

    // Auto-archive protects conversation when pinned.
    autoArchive(r.hub, 2000 + 30 * 86_400_000);
    assert.equal(r.store.getSession("b1:C1:200.1")?.archivedAt, null);
    assert.equal(r.store.getSession("b2:C1:200.1")?.archivedAt, null);

    // Simulate legacy non-anchor pin written during downgrade: reading folds it onto anchor, and DELETE clears all members.
    const v = { email: "ada@example.com", workspace: null };
    r.store.db.prepare("DELETE FROM pins").run();
    r.store.db.prepare("INSERT INTO pins (viewer, session, at) VALUES (?, ?, 1234)").run("ada@example.com", "b2:C1:200.1");
    const rows = JSON.parse(await r.readers.read("chats", { viewer: v, words: { untitled: "Untitled", directMessage: "DM" }, archived: false }, "en"));
    const convRow = rows.find((x: any) => x.id === "b1:C1:200.1");
    assert.equal(convRow?.pinned, 1234);

    // Unpin via anchor clears legacy non-anchor pin too.
    const [unpinSt] = await r.ask("DELETE", `/sessions/${encodeURIComponent("b1:C1:200.1")}/pin`);
    assert.equal(unpinSt, 200);
    const rowsAfter = JSON.parse(await r.readers.read("chats", { viewer: v, words: { untitled: "Untitled", directMessage: "DM" }, archived: false }, "en"));
    assert.equal(rowsAfter.find((x: any) => x.id === "b1:C1:200.1")?.pinned, null);

    // Rename via non-anchor updates anchor title and home chat title.
    const [titleSt] = await r.ask("POST", `/sessions/${encodeURIComponent("b2:C1:200.1")}/title`, { title: "Renamed Conv" });
    assert.equal(titleSt, 200);
    assert.equal(r.store.getSession("b1:C1:200.1")?.title, "Renamed Conv");
    assert.equal(r.store.getThread(home.id)?.title, "Renamed Conv");
  } finally {
    await r.close();
  }
});
