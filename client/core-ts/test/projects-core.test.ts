// Comprehensive unit & integration tests for PR 2:
// - Module A: PresetProjects validation/merge/eviction + preset.setProject
// - Module B: SQLite chat_project & chat_tag indexes/triggers (including legacy in-place JSON updates)
// - Module C: chats topic filter params (project / unclassified / tag / groupBy="project"), core.receiveRaw / parseTopic,
//             ListedChat / ChatItem / ChatView project+tags+projectLocked, ChatMessage proposal
// - Module D: projects / project / tags 32 KB byte-budget pagination & PROJECTS.jsonl merge
// - Module E: chat.classify, proposal.resolve, project.updateInfo, project.rename, project.merge call parsing
import assert from "node:assert/strict";
import { test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { Effect } from "effect";
import {
  PRESET_PROJECTS_MOST,
  PRESET_PROJECT_MAX,
  RecordRefusal,
  mergePresetProjects,
  newerPresetProject,
  presetProjectsOf,
} from "../src/preset-records.ts";
import { CHAT_MADE, CHAT_MADE_ALT, ensureChatColumns, migrate } from "../src/db/schema.ts";
import { NodeSql } from "../src/hosts/node-sql.ts";
import { parseClientMessage, parseTopic } from "../src/protocol.ts";
import { parseCall } from "../src/core/calls.ts";
import { handlers } from "../src/core/execute.ts";
import { fetchProjectsInfo, install as installProjects, mergeProjectsInfoMaps, projectsInfoByStationKey, projectsInfoKey } from "../src/views/projects.ts";
import { carryPresetProjects, install as installPresets, presetProjectsKey } from "../src/views/presets.ts";
import { presetProjectsLacking } from "../src/presets-kept.ts";
import { diff as jsonDiff } from "../src/delta.ts";
import { CoreError } from "../src/error.ts";
import { holdLanguage } from "../src/i18n.ts";
import { setup, ui, workspace, overview } from "./views-rig.ts";

holdLanguage();

// deno-lint-ignore no-explicit-any
type J = any;

const enc = new TextEncoder();
const bytes = (v: unknown) => enc.encode(JSON.stringify(v)).length;

test("presetProjectsOf validates keys, values, and limits", () => {
  const valid = presetProjectsOf({
    "p-1": { project: "  monoid  ", rev: 1, at: 100 },
    "p-2": { project: "", rev: 2, at: 200 },
    "p-3": { project: null, rev: 3, at: 300 },
  });
  assert.deepEqual({ ...valid }, {
    "p-1": { project: "monoid", rev: 1, at: 100 },
    "p-2": { project: "", rev: 2, at: 200 },
    "p-3": { project: null, rev: 3, at: 300 },
  });

  assert.throws(() => presetProjectsOf(null), RecordRefusal);
  assert.throws(() => presetProjectsOf([]), RecordRefusal);
  assert.throws(() => presetProjectsOf({ "bad id!": { project: "a", rev: 1, at: 0 } }), RecordRefusal);
  assert.equal(PRESET_PROJECT_MAX, 80);
  assert.equal(presetProjectsOf({ "p-80": { project: "x".repeat(80), rev: 1, at: 0 } })["p-80"]!.project, "x".repeat(80));
  assert.throws(() => presetProjectsOf({ "p-1": { project: "x".repeat(81), rev: 1, at: 0 } }), RecordRefusal);
  // Prototype-key safety (__proto__ / constructor)
  const protoInput = JSON.parse('{"constructor":{"project":"monoid","rev":1,"at":10}}');
  const protoValid = presetProjectsOf(protoInput);
  assert.equal(Object.getPrototypeOf(protoValid), null);
  assert.equal(protoValid["constructor"]?.project, "monoid");
  assert.throws(() => presetProjectsOf({ "p-1": { project: "a\nb", rev: 1, at: 0 } }), RecordRefusal);
  assert.throws(() => presetProjectsOf({ "p-1": { project: "a,b", rev: 1, at: 0 } }), RecordRefusal);
  assert.throws(() => presetProjectsOf({ "p-1": { project: 123, rev: 1, at: 0 } }), RecordRefusal);
  assert.throws(() => presetProjectsOf({ "p-1": { project: "a", rev: 0, at: 0 } }), RecordRefusal);

  const tooMany: Record<string, unknown> = {};
  for (let i = 0; i <= PRESET_PROJECTS_MOST; i++) tooMany[`p-${i}`] = { project: "a", rev: 1, at: i };
  assert.throws(() => presetProjectsOf(tooMany), RecordRefusal);
});

test("newerPresetProject and mergePresetProjects tie-break and evict deterministically", () => {
  assert.deepEqual(
    newerPresetProject({ project: "a", rev: 2, at: 10 }, { project: "b", rev: 1, at: 999 }),
    { project: "a", rev: 2, at: 10 },
  );
  assert.deepEqual(
    newerPresetProject({ project: "a", rev: 2, at: 200 }, { project: "b", rev: 2, at: 100 }),
    { project: "a", rev: 2, at: 200 },
  );
  // Same rev & at -> canonical tie-breaker is commutative
  const x = { project: "alpha", rev: 2, at: 200 };
  const y = { project: "beta", rev: 2, at: 200 };
  assert.deepEqual(newerPresetProject(x, y), newerPresetProject(y, x));

  // Eviction: oldest project === null evicted before non-null
  const kept: Record<string, { project: string | null; rev: number; at: number }> = {};
  for (let i = 0; i < PRESET_PROJECTS_MOST; i++) {
    kept[`p-${String(i).padStart(3, "0")}`] = { project: i === 0 ? null : "monoid", rev: 1, at: 1000 + i };
  }
  const merged = mergePresetProjects(kept, { "p-new": { project: "invar", rev: 1, at: 500 } });
  assert.equal(Object.keys(merged).length, PRESET_PROJECTS_MOST);
  assert.equal(merged["p-000"], undefined, "oldest null entry evicted first");
  assert.deepEqual(merged["p-new"], { project: "invar", rev: 1, at: 500 });
});

test("parseTopic and parseClientMessage accept all new chats/projects/project/tags params and reject invalid groupBy", () => {
  const t1 = parseTopic({ topic: "chats", scope: "ws", project: "monoid", tag: "bug", groupBy: "project" });
  assert.deepEqual(t1, { topic: "chats", scope: "ws", mine: false, project: "monoid", tag: "bug", groupBy: "project" });

  const t2 = parseTopic({ topic: "chats", scope: "ws", unclassified: true, groupBy: "time" });
  assert.deepEqual(t2, { topic: "chats", scope: "ws", mine: false, unclassified: true, groupBy: "time" });

  const tCross = parseTopic({ topic: "chats", scope: "ws", project: "" });
  assert.deepEqual(tCross, { topic: "chats", scope: "ws", mine: false, project: "" });

  assert.equal(parseTopic({ topic: "chats", scope: "ws", groupBy: "invalid" }), null);

  assert.deepEqual(parseTopic({ topic: "projects", scope: "ws", cursor: "10" }), { topic: "projects", scope: "ws", cursor: "10" });
  assert.deepEqual(parseTopic({ topic: "project", scope: "ws", name: "monoid" }), { topic: "project", scope: "ws", name: "monoid" });
  assert.deepEqual(parseTopic({ topic: "tags", scope: "ws" }), { topic: "tags", scope: "ws" });

  const msg = parseClientMessage({ id: 1, subscribe: { topic: "chats", scope: "ws", project: "monoid", tag: "bug", groupBy: "project" }, keyed: true });
  assert.ok("kind" in msg && msg.kind === "subscribe" && msg.subscribe.groupBy === "project");

  // parseCall for all new operations
  assert.equal(parseCall("preset.setProject", { scope: "ws", presetId: "p-1", project: "monoid" }).kind, "presets");
  assert.equal(parseCall("preset.setProject", { scope: "ws", presetId: "p-1", project: null }).kind, "presets");
  assert.equal(parseCall("chat.classify", { station: "ws/s1", thread: 7, project: "monoid", tags: ["bug"] }).kind, "projects");
  assert.equal(parseCall("proposal.resolve", { station: "ws/s1", thread: 7, entryN: 3, action: "accept" }).kind, "projects");
  assert.equal(parseCall("project.updateInfo", { scope: "ws", name: "monoid", note: "hello" }).kind, "projects");
  assert.equal(parseCall("project.rename", { scope: "ws", from: "a", to: "b" }).kind, "projects");
  assert.equal(parseCall("project.merge", { scope: "ws", from: "a", to: "b" }).kind, "projects");

  const winCall = parseCall("chats.window", { scope: "ws", project: "monoid", tag: "bug", groupBy: "project", rows: 40 });
  assert.ok(winCall.kind === "chatsWindow" && winCall.list.project === "monoid" && winCall.list.tag === "bug" && winCall.list.groupBy === "project");
});

test("chats topic filters by project/unclassified/tag and groups by project in 4-tier order", async () => {
  const t = setup({ all: true });
  try {
    const st = "ws/s1";
    const now = 1_790_000_000_000;
    t.set(workspace(), { id: "ws", name: "W", stations: [{ id: "s1", name: "S1", online: true }], members: [] });
    t.set(overview(st), { viewer: { email: "a@x.com" }, counts: { running: 1 }, connects: [], slackUsers: [] });
    t.set({ topic: "link", station: st }, { state: "online" });
    const mkRow = (id: string, extra: Record<string, unknown>) => ({
      id,
      session: id,
      thread: Number(id.slice(1)),
      title: `Chat ${id}`,
      agents: [{ key: id, runtime: "claude", process: "cold" }],
      lastActiveAt: now,
      unread: false,
      mine: true,
      ...extra,
    });
    t.set({ topic: "chatRows", station: st }, [
      mkRow("c1", { pinned: now + 100, project: "alpha", tags: ["bug"], lastActiveAt: now - 500 }),
      mkRow("c2", { project: "alpha", tags: ["bug", "perf"], lastActiveAt: now - 200, agents: [{ key: "c2", runtime: "claude", process: "running" }] }),
      mkRow("c3", { project: "beta", tags: ["feat"], lastActiveAt: now - 100, unread: true }),
      mkRow("c4", { project: "", tags: ["bug"], lastActiveAt: now - 300, agents: [{ key: "c4", runtime: "claude", process: "cold", lastTurn: { endedAt: now - 300, outcome: "failed" } }] }),
      mkRow("c5", { lastActiveAt: now - 400 }), // unclassified
    ]);

    // 1. project="alpha"
    const uAlpha = ui();
    t.subscribe(1, { topic: "chats", scope: "ws", mine: false, project: "alpha" });
    await t.read(uAlpha, 1);
    const alphaIds = uAlpha.value.days.flatMap((d: J) => d.items.map((x: J) => x.id));
    assert.deepEqual(alphaIds, ["c1", "c2"]);
    assert.equal(uAlpha.value.days[0].items[0].project, "alpha");
    assert.deepEqual(uAlpha.value.days[0].items[0].tags, ["bug"]);

    // 2. project="" and unclassified=true BOTH return unified unclassified (null + "")
    const uCross = ui();
    t.subscribe(2, { topic: "chats", scope: "ws", mine: false, project: "" });
    await t.read(uCross, 2);
    assert.deepEqual(uCross.value.days.flatMap((d: J) => d.items.map((x: J) => x.id)), ["c4", "c5"]);

    // 3. unclassified=true
    const uUn = ui();
    t.subscribe(3, { topic: "chats", scope: "ws", mine: false, unclassified: true });
    await t.read(uUn, 3);
    assert.deepEqual(uUn.value.days.flatMap((d: J) => d.items.map((x: J) => x.id)), ["c4", "c5"]);

    // 4. tag="bug"
    const uTag = ui();
    t.subscribe(4, { topic: "chats", scope: "ws", mine: false, tag: "bug" });
    await t.read(uTag, 4);
    assert.deepEqual(uTag.value.days.flatMap((d: J) => d.items.map((x: J) => x.id)), ["c1", "c2", "c4"]);

    // 5. Orthogonal tag="bug" + project="alpha"
    const uBoth = ui();
    t.subscribe(5, { topic: "chats", scope: "ws", mine: false, project: "alpha", tag: "bug" });
    await t.read(uBoth, 5);
    assert.deepEqual(uBoth.value.days.flatMap((d: J) => d.items.map((x: J) => x.id)), ["c1", "c2"]);

    // 6. groupBy="project": named projects by latest activity (pinned stays INSIDE its project sorted first),
    //    then unified unclassified (null + "") at bottom, with canonical alertCount/runningCount/unreadCount!
    const uGrp = ui();
    t.subscribe(6, { topic: "chats", scope: "ws", mine: false, groupBy: "project" });
    await t.read(uGrp, 6);
    assert.deepEqual(uGrp.value.days, []);
    const groups = uGrp.value.groups as J[];
    assert.deepEqual(
      groups.map((g) => g.key),
      ["project:beta", "project:alpha", "unclassified"],
    );
    assert.equal(groups[0].unreadCount, 1);
    assert.equal(groups[1].chatCount, 2);
    assert.equal(groups[1].runningCount, 1);
    assert.deepEqual(groups[1].items.map((x: J) => x.id), ["c1", "c2"], "pinned c1 must stay inside project:alpha sorted first");
    assert.equal(groups[2].chatCount, 2);
    assert.equal(groups[2].alertCount, 1);
    assert.deepEqual(groups[2].items.map((x: J) => x.id), ["c4", "c5"], "unclassified must unify empty-string and null projects");

    // 7. projects view folds project="" into unclassifiedCount (crossCount === 0)
    const uProjs = ui();
    t.subscribe(7, { topic: "projects", scope: "ws" });
    await t.read(uProjs, 7);
    assert.equal(uProjs.value.unclassifiedCount, 2);
    assert.equal(uProjs.value.crossCount, 0);
  } finally {
    t.store.runner.shutdown();
  }
});

test("projects, project, and tags topics paginate strictly within 32 KB byte budget", async () => {
  const t = setup({ all: true });
  try {
    const st = "ws/s1";
    const now = 1_790_000_000_000;
    t.set(workspace(), { id: "ws", name: "W", stations: [{ id: "s1", name: "S1", online: true }], members: [] });
    t.set(overview(st), { viewer: { email: "a@x.com" }, counts: { running: 0 }, connects: [], slackUsers: [] });
    t.set({ topic: "link", station: st }, { state: "online" });

    const rows: J[] = [];
    const infoMap: Record<string, { note: string; refs: string[]; updatedAt: number }> = {};
    // 450 distinct projects with long names & 450 distinct tags -> forces multi-page pagination
    for (let i = 0; i < 450; i++) {
      const pname = `project-long-name-budget-check-${String(i).padStart(4, "0")}`;
      const tname = `tag-long-name-budget-check-${String(i).padStart(4, "0")}`;
      rows.push({
        id: `c${i}`,
        session: `c${i}`,
        thread: i + 1,
        title: `Chat ${i}`,
        agents: [{ key: `c${i}`, runtime: "claude", process: "cold" }],
        lastActiveAt: now - i * 1000,
        mine: true,
        project: pname,
        tags: [tname],
      });
      if (i < 5) {
        infoMap[pname] = { note: "x".repeat(500), refs: ["github.com/AFK-surf/monoid"], updatedAt: now };
      }
    }
    // Also add an info-only project with 0 chats
    infoMap["zero-chat-project"] = { note: "Registered in PROJECTS.jsonl", refs: ["github.com/AFK-surf/invar"], updatedAt: now };
    t.data.put("choice", "ws:ws:projectsInfo", infoMap, false);
    t.set({ topic: "chatRows", station: st }, rows);

    // Paginate through all `projects` pages
    const seenProjects: string[] = [];
    let cursor: string | undefined;
    let pages = 0;
    for (;;) {
      const u = ui();
      const id = 100 + pages;
      t.subscribe(id, { topic: "projects", scope: "ws", ...(cursor !== undefined ? { cursor } : {}) });
      await t.read(u, id);
      const size = bytes(u.value);
      assert.ok(size <= 32 * 1024, `projects page ${pages} exceeded 32 KB: ${size} bytes`);
      for (const item of u.value.items as J[]) {
        assert.equal(item.note, undefined, "list summary must never include long note");
        assert.equal(item.refs, undefined, "list summary must never include refs");
        seenProjects.push(item.name);
      }
      pages++;
      if (!u.value.nextCursor) break;
      cursor = u.value.nextCursor;
      assert.ok(pages < 20, "pagination must terminate");
    }
    assert.ok(pages >= 2, `expected multi-page pagination for 451 projects, got ${pages}`);
    assert.equal(new Set(seenProjects).size, 451);
    assert.ok(seenProjects.includes("zero-chat-project"));

    // Single project detail topic includes note & refs
    const uDetail = ui();
    t.subscribe(200, { topic: "project", scope: "ws", name: "zero-chat-project" });
    await t.read(uDetail, 200);
    assert.equal(uDetail.value.note, "Registered in PROJECTS.jsonl");
    assert.deepEqual(uDetail.value.refs, ["github.com/AFK-surf/invar"]);
    assert.equal(uDetail.value.hasInfo, true);
    assert.equal(uDetail.value.chatCount, 0);

    // Paginate through all `tags` pages
    const seenTags: string[] = [];
    let tagCursor: string | undefined;
    let tagPages = 0;
    for (;;) {
      const u = ui();
      const id = 300 + tagPages;
      t.subscribe(id, { topic: "tags", scope: "ws", ...(tagCursor !== undefined ? { cursor: tagCursor } : {}) });
      await t.read(u, id);
      const size = bytes(u.value);
      assert.ok(size <= 32 * 1024, `tags page ${tagPages} exceeded 32 KB: ${size} bytes`);
      for (const item of u.value.items as J[]) seenTags.push(item.name);
      tagPages++;
      if (!u.value.nextCursor) break;
      tagCursor = u.value.nextCursor;
      assert.ok(tagPages < 20, "tag pagination must terminate");
    }
    assert.equal(new Set(seenTags).size, 450);
  } finally {
    t.store.runner.shutdown();
  }
});

test("legacy CHAT_MADE=2/-2 DB upgrades chat_unmade to (3, -3) and uses COVERING INDEX chat_unmade", () => {
  const sql = new NodeSql(new DatabaseSync(":memory:"), true);
  migrate(sql);
  // Simulate legacy DB with CHAT_MADE=2/-2 partial index
  sql.exec("DROP INDEX IF EXISTS chat_unmade");
  sql.exec("ALTER TABLE chat ADD COLUMN state");
  sql.exec("ALTER TABLE chat ADD COLUMN watched");
  sql.exec("ALTER TABLE chat ADD COLUMN made");
  sql.exec("CREATE INDEX chat_unmade ON chat (made) WHERE made IS NULL OR made NOT IN (2, -2)");
  ensureChatColumns(sql, () => ({ state: null, watched: false }));
  const idxSql = String(sql.all("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'chat_unmade'")[0]![0]);
  assert.ok(idxSql.includes(`(${CHAT_MADE}, ${CHAT_MADE_ALT})`), `expected rebuilt chat_unmade, got: ${idxSql}`);
  const plan = sql.all(`EXPLAIN QUERY PLAN SELECT 1 FROM chat WHERE made IS NULL OR made NOT IN (${CHAT_MADE}, ${CHAT_MADE_ALT}) LIMIT 1`).map((r) => String(r[3])).join("\n");
  assert.match(plan, /COVERING INDEX chat_unmade/, `expected COVERING INDEX chat_unmade, got: ${plan}`);
  assert.doesNotMatch(plan, /^SCAN chat$/m, `must not full-table SCAN chat: ${plan}`);
});

test("chat_tag triggers stay consistent on pure-column UPDATE and legacy core JSON UPDATE", () => {
  const sql = new NodeSql(new DatabaseSync(":memory:"), true);
  migrate(sql);
  ensureChatColumns(sql, () => ({ state: null, watched: false }));
  const rowJson = JSON.stringify({ id: "c1", project: "P", hidden: false, tags: ["t1", "t2"] });
  sql.run(
    "INSERT INTO chat (station, id, archived, ord, last_active, mine, hidden, led, watched, project, made, json) VALUES (?, ?, 0, 1, 100, 1, 0, 0, 0, 'P', ?, ?)",
    ["ws/s1", "c1", CHAT_MADE, rowJson],
  );
  // 1. Pure-column UPDATE (without touching json) must update chat_tag from canonical NEW columns
  sql.run("UPDATE chat SET hidden = 1, led = 1, project = 'Q' WHERE station = 'ws/s1' AND id = 'c1'");
  const afterCol = sql.all("SELECT tag, hidden, led, project FROM chat_tag WHERE station = 'ws/s1' AND id = 'c1' ORDER BY tag");
  assert.deepEqual(afterCol, [["t1", 1, 1, "Q"], ["t2", 1, 1, "Q"]]);

  // 2. Legacy core updates json in place without bumping `made` -> chat_made_set + reopen keep chat_tag consistent
  const legacyJson = JSON.stringify({ id: "c1", project: "R", hidden: false, opener: { led: false }, tags: ["t3"] });
  sql.run("UPDATE chat SET json = ? WHERE station = 'ws/s1' AND id = 'c1'", [legacyJson]);
  const afterLegacyImmediate = sql.all("SELECT tag, hidden, led, project FROM chat_tag WHERE station = 'ws/s1' AND id = 'c1' ORDER BY tag");
  assert.deepEqual(afterLegacyImmediate, [["t3", 0, 0, "R"]]);
  ensureChatColumns(sql, () => ({ state: null, watched: false }));
  const afterReopen = sql.all("SELECT tag, hidden, led, project FROM chat_tag WHERE station = 'ws/s1' AND id = 'c1' ORDER BY tag");
  assert.deepEqual(afterReopen, [["t3", 0, 0, "R"]]);
});

test("overlaid, pending, and full-count groupBy='project' headers respect classification filters", async () => {
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "W", stations: [{ id: "s1", name: "S1", online: true }], members: [] });
    t.set(overview("ws/s1"), { connects: [], profiles: [] });
    // 60 chats in project A (with tag 'alpha') + 1 chat in project B
    const rows: J[] = [];
    for (let i = 0; i < 60; i++) {
      rows.push({
        id: `a-${i}`,
        session: `a-${i}`,
        thread: i + 1,
        title: `A ${i}`,
        lastActiveAt: 10_000 + i,
        mine: true,
        unread: false,
        project: "A",
        projectLocked: i === 0,
        tags: ["alpha"],
        agents: [],
      });
    }
    rows.push({ id: "b-1", session: "b-1", thread: 999, title: "B 1", lastActiveAt: 20_000, mine: true, unread: false, project: "B", tags: ["beta"], agents: [] });
    t.set({ topic: "chatRows", station: "ws/s1" }, rows);

    // Overlaid change on B-1 (rename/pin) must NOT leak into project A + tag 'alpha' list
    t.views.local.changing("ws/s1", 999, "b-1", { title: "B 1 renamed", pinned: 99_999 }, null);
    // Pending chat without project must NOT appear in project A; pending chat with project 'A' DOES appear in project A
    t.views.local.pendingNew("ws/s1", { runtime: "claude" }, "new:unclass");
    t.views.local.pendingQueue("new:unclass", { text: "hi" });
    t.views.local.pendingNew("ws/s1", { runtime: "claude", project: "A" }, "new:projA");
    t.views.local.pendingQueue("new:projA", { text: "hi" });

    // 1. Filtered by project A + tag alpha -> B-1 never leaks, total === 60
    const uFiltered = ui();
    const filteredTopic = { topic: "chats", scope: "ws", mine: false, project: "A", tag: "alpha" } as const;
    t.window(filteredTopic, 30);
    t.subscribe(1, filteredTopic);
    await t.read(uFiltered, 1);
    const flatIds = (uFiltered.value.days as J[]).flatMap((d: J) => (d.items as J[]).map((r: J) => r.id));
    assert.ok(!flatIds.includes("b-1"), "overlaid B chat must not leak into project A + tag alpha");
    assert.equal(uFiltered.value.more, 30, "60 total - 30 shown = 30 more");

    // 2. Filtered by project A (no tag) -> pending 'new:projA' appears, pending 'new:unclass' does not
    const uProjA = ui();
    const projATopic = { topic: "chats", scope: "ws", mine: false, project: "A" } as const;
    t.window(projATopic, 30);
    t.subscribe(2, projATopic);
    await t.read(uProjA, 2);
    const projAIds = (uProjA.value.days as J[]).flatMap((d: J) => (d.items as J[]).map((r: J) => r.id));
    assert.ok(projAIds.includes("new:projA"), "pending chat with project A must appear");
    assert.ok(!projAIds.includes("new:unclass"), "unclassified pending chat must not appear in project A");

    // 3. groupBy: "project" with window=50 -> project A group header has full-scope chatCount (61 with pending) while items <= 50
    const uGrouped = ui();
    const groupedTopic = { topic: "chats", scope: "ws", mine: false, project: "A", groupBy: "project" } as const;
    t.window(groupedTopic, 50);
    t.subscribe(3, groupedTopic);
    await t.read(uGrouped, 3);
    const grpA = (uGrouped.value.groups as J[]).find((g: J) => g.key === "project:A");
    assert.ok(grpA, "project:A group must exist");
    assert.equal(grpA.chatCount, 61, "group header must reflect full filtered scope (60 SQL + 1 pending), not window 50");
    assert.equal(grpA.items.length, 50, "group items must respect window=50");
    assert.equal(grpA.items.some((r: J) => r.id === "a-0" && r.projectLocked === true), false, "a-0 is oldest outside top 50");
  } finally {
    t.store.runner.shutdown();
  }
});

test("projectDetailView stays strictly <= 32 KiB on 55 KB CJK note+refs and paginates refs; projects keyset cursor has zero duplicates on live reorder", async () => {
  const t = setup({ all: true });
  try {
    t.set(workspace(), { id: "ws", name: "W", stations: [{ id: "s1", name: "S1", online: true }], members: [] });
    t.set(overview("ws/s1"), { connects: [], profiles: [] });

    // 55 KB CJK counterexample: 2000 CJK chars note + 32 refs * 512 CJK chars
    const bigNote = "测".repeat(2000);
    const bigRefs = Array.from({ length: 32 }, (_, i) => `参考${i}-` + "字".repeat(512));
    t.data.put("choice", projectsInfoKey("ws"), {
      "big-cjk": { note: bigNote, refs: bigRefs, updatedAt: 1000 },
    }, false);
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "c0", session: "c0", thread: 1, title: "Big", lastActiveAt: 1000, mine: true, project: "big-cjk", agents: [] },
    ]);

    const seenRefs: string[] = [];
    let refCursor: string | undefined;
    let refPages = 0;
    for (;;) {
      const u = ui();
      const id = 400 + refPages;
      t.subscribe(id, { topic: "project", scope: "ws", name: "big-cjk", ...(refCursor !== undefined ? { cursor: refCursor } : {}) });
      await t.read(u, id);
      const sz = bytes(u.value);
      assert.ok(sz <= 32 * 1024, `project detail page ${refPages} exceeded 32 KiB: ${sz} bytes`);
      seenRefs.push(...(u.value.refs as string[]));
      refPages++;
      if (!u.value.nextCursor) break;
      refCursor = u.value.nextCursor;
      assert.ok(refPages < 20, "ref pagination must terminate");
    }
    assert.ok(refPages >= 2, "55 KB refs must paginate across multiple pages");
    assert.equal(seenRefs.length, 32);

    // Clear previous `big-cjk` info so workspace has exactly the 500 projects below
    t.data.put("choice", projectsInfoKey("ws"), {}, false);
    // Dynamic snapshot pagination test: 500 projects, read page 1, bump #316 to top, read remaining pages -> 0 duplicates AND exact 500/500 union
    const rows500: J[] = [];
    for (let i = 0; i < 500; i++) {
      rows500.push({
        id: `p-${i}`,
        session: `p-${i}`,
        thread: i + 1,
        title: `Chat ${i}`,
        lastActiveAt: 10_000 + (500 - i),
        mine: true,
        project: `proj-${String(i).padStart(3, "0")}`,
        tags: [`tag-long-snapshot-test-name-${String(i).padStart(3, "0")}-${"t".repeat(32)}`],
        agents: [],
      });
    }
    t.set({ topic: "chatRows", station: "ws/s1" }, rows500);
    const uP1 = ui();
    t.subscribe(501, { topic: "projects", scope: "ws" });
    await t.read(uP1, 501);
    const p1Names = (uP1.value.items as J[]).map((x: J) => x.name as string);
    let pCursor = uP1.value.nextCursor as string | undefined;
    assert.ok(pCursor, "500 projects must have nextCursor");

    // Mutate: bump project #316 (on page 2) to most recently active
    rows500[316] = { ...rows500[316], lastActiveAt: 999_999 };
    t.set({ topic: "chatRows", station: "ws/s1" }, [...rows500]);

    const seenProj = new Set<string>(p1Names);
    let projDups = 0;
    let projSub = 502;
    while (pCursor) {
      const uNext = ui();
      t.subscribe(projSub, { topic: "projects", scope: "ws", cursor: pCursor });
      await t.read(uNext, projSub++);
      for (const item of uNext.value.items as J[]) {
        if (seenProj.has(item.name)) projDups++;
        seenProj.add(item.name);
      }
      pCursor = uNext.value.nextCursor;
      assert.ok(projSub < 540, "projects pagination must terminate");
    }
    assert.equal(projDups, 0, "snapshot pagination must produce zero duplicates after live reorder");
    assert.equal(seenProj.size, 500, "snapshot pagination must cover exact 500/500 projects with zero omissions");

    // Tags snapshot pagination: 500 tags, bump tag-316 count between page 1 and page 2 -> 0 duplicates AND exact 500/500 union
    const uT1 = ui();
    t.subscribe(551, { topic: "tags", scope: "ws" });
    await t.read(uT1, 551);
    const seenTags = new Set<string>((uT1.value.items as J[]).map((x: J) => x.name as string));
    let tCursor = uT1.value.nextCursor as string | undefined;
    assert.ok(tCursor, "500 tags must have nextCursor");
    rows500.push({ id: "p-extra", session: "p-extra", thread: 999, title: "Boost", lastActiveAt: 999_999, mine: true, project: "proj-000", tags: [`tag-long-snapshot-test-name-316-${"t".repeat(32)}`], agents: [] });
    t.set({ topic: "chatRows", station: "ws/s1" }, [...rows500]);
    let tagDups = 0;
    let tagSub = 552;
    while (tCursor) {
      const uNext = ui();
      t.subscribe(tagSub, { topic: "tags", scope: "ws", cursor: tCursor });
      await t.read(uNext, tagSub++);
      for (const item of uNext.value.items as J[]) {
        if (seenTags.has(item.name)) tagDups++;
        seenTags.add(item.name);
      }
      tCursor = uNext.value.nextCursor;
      assert.ok(tagSub < 590, "tags pagination must terminate");
    }
    assert.equal(tagDups, 0, "tags snapshot pagination must produce zero duplicates");
    assert.equal(seenTags.size, 500, "tags snapshot pagination must cover exact 500/500 tags");
  } finally {
    t.store.runner.shutdown();
  }
});

test("projectsInfo multi-station updatedAt merge, generation guard, cross-ws rejection, and chat.classify optimistic overlay+rollback", async () => {
  // 1. Multi-station merge by updatedAt: empty station never wipes cached info, newer updatedAt wins
  const merged1 = mergeProjectsInfoMaps(
    { alpha: { note: "Newer", updatedAt: 200 }, beta: { note: "Keep", updatedAt: 100 } },
    { alpha: { note: "Older", updatedAt: 100 } },
  );
  assert.equal(merged1.alpha?.note, "Newer");
  assert.equal(merged1.beta?.note, "Keep");
  const merged2 = mergeProjectsInfoMaps(merged1, {});
  assert.equal(merged2.alpha?.note, "Newer");

  // 2. Generation guard (stale GET after PUT), cross-workspace station rejection, chat.classify optimistic overlay & rollback
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "W", stations: [{ id: "s1", name: "S1", online: true }], members: [{ sub: "u1", role: "viewer" }] });
    t.set(overview("ws/s1"), { connects: [], profiles: [], features: ["projects"] });
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "c1", session: "c1", thread: 10, title: "Chat 1", lastActiveAt: 1000, mine: true, project: "old", agents: [] },
    ]);

    let resolveGet: ((v: unknown) => void) | null = null;
    let classifyFail = false;
    const inner = {
      provider: { kind: "stillfail" },
      data: t.data,
      views: t.views,
      store: t.store,
      host: t.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: () => true,
        requests: {
          call: (addr: { toString(): string }, method: string, path: string, body: any) => {
            if (method === "GET" && path === "/projects/info") {
              return Effect.promise(() => new Promise((r) => { resolveGet = r; }));
            }
            if (method === "PUT" && path === "/projects/info") {
              return Effect.succeed({ projects: { alpha: { note: "Authoritative", updatedAt: 500 } } });
            }
            if (method === "PUT" && path === "/threads/10/classification") {
              if (classifyFail) return Effect.fail(new CoreError("http_500", "boom", 500));
              return Effect.succeed({ thread: 10, changed: true, body });
            }
            return Effect.fail(new CoreError("http_404", `no route ${method} ${path}`, 404));
          },
        },
      },
    } as any;

    installProjects(inner);
    installPresets(inner);

    // Cross-workspace preferred station rejected with CoreError
    const crossErr = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", name: "alpha", station: "other-ws/s2" } } as any, (() => {}) as any, ["c", 1] as any, null as any)),
    );
    assert.equal(crossErr._tag, "Failure");

    // Stale GET started before PUT must NOT overwrite PUT's authoritative result
    const getPromise = Effect.runPromise(fetchProjectsInfo(inner, "ws/s1"));
    const putRes = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", name: "alpha", note: "Authoritative" } } as any, (() => {}) as any, ["c", 2] as any, null as any)),
    );
    assert.equal(putRes._tag, "Success");
    resolveGet!({ projects: { alpha: { note: "Stale", updatedAt: 9999 } } });
    await getPromise;
    assert.equal((t.data.record("choice", projectsInfoKey("ws")) as any)?.alpha?.note, "Authoritative");

    // chat.classify optimistic overlay applies immediately and rolls back on failure
    classifyFail = true;
    const failRes = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "classify", scope: "ws", params: { station: "ws/s1", thread: 10, project: "newProj", tags: ["urgent"] } } as any, (() => {}) as any, ["c", 3] as any, null as any)),
    );
    assert.equal(failRes._tag, "Failure");
    assert.equal(t.views.local.asChanging("ws/s1", { id: "c1", thread: 10, project: "old" }).project, "old", "failed classify must roll back overlay");

    classifyFail = false;
    const okRes = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "classify", scope: "ws", params: { station: "ws/s1", thread: 10, project: "newProj", tags: ["urgent"] } } as any, (() => {}) as any, ["c", 4] as any, null as any)),
    );
    assert.equal(okRes._tag, "Success");
    const overlaid = t.views.local.asChanging("ws/s1", { id: "c1", thread: 10, project: "old" });
    assert.equal(overlaid.project, "newProj");
    assert.equal(overlaid.projectLocked, true);
    assert.deepEqual(overlaid.tags, ["urgent"]);

    // Read-only viewer refused on preset.setProject
    const roRes = await Effect.runPromise(
      Effect.result(handlers.presets!(inner, { kind: "presets", name: "setProject", station: "", scope: "ws", params: { scope: "ws", presetId: "p1", project: "monoid" } } as any, (() => {}) as any, ["c", 5] as any, null as any)),
    );
    assert.equal(roRes._tag, "Failure");
    assert.equal((roRes as any).failure.status, 403);
  } finally {
    t.store.runner.shutdown();
  }
});

test("projectsInfo per-station snapshots: empty station never wipes another station, and cross-device deletion converges when all stations drop key", async () => {
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), {
      id: "ws-snap",
      name: "Snap",
      stations: [
        { id: "s1", name: "S1", online: true },
        { id: "s2", name: "S2", online: true },
      ],
    });
    const responses: Record<string, Record<string, { note?: string; updatedAt?: number }>> = {
      "ws-snap/s1": { alpha: { note: "A1", updatedAt: 100 }, beta: { note: "B1", updatedAt: 100 } },
      "ws-snap/s2": {},
    };
    const inner = {
      provider: { kind: "stillfail" },
      data: t.data,
      views: t.views,
      store: t.store,
      host: t.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: () => true,
        requests: {
          call: (addr: { toString(): string }, method: string, path: string) => {
            if (method === "GET" && path === "/projects/info") {
              return Effect.succeed({ projects: responses[addr.toString()] ?? {} });
            }
            return Effect.fail(new CoreError("http_404", `no route ${method} ${path}`, 404));
          },
        },
      },
    } as any;

    installProjects(inner);

    // 1. Station s1 reports alpha & beta; station s2 reports {} -> s2 must NOT wipe s1's projects
    await Effect.runPromise(fetchProjectsInfo(inner, "ws-snap/s1"));
    await Effect.runPromise(fetchProjectsInfo(inner, "ws-snap/s2"));
    const afterEmpty = t.data.record("choice", projectsInfoKey("ws-snap")) as Record<string, { note?: string }>;
    assert.equal(afterEmpty.alpha?.note, "A1");
    assert.equal(afterEmpty.beta?.note, "B1");

    // 2. Cross-device deletion: s1 now omits beta (renamed/deleted elsewhere) while s2 still has {}
    //    -> merged across all station snapshots, beta must be dropped while alpha remains.
    responses["ws-snap/s1"] = { alpha: { note: "A1", updatedAt: 100 } };
    await Effect.runPromise(fetchProjectsInfo(inner, "ws-snap/s1"));
    const afterDelete = t.data.record("choice", projectsInfoKey("ws-snap")) as Record<string, { note?: string }>;
    assert.equal(afterDelete.alpha?.note, "A1");
    assert.equal("beta" in afterDelete, false, "deleted key must converge out once all stations drop it");
  } finally {
    t.store.runner.shutdown();
  }
});

test("R3 Core-TS regressions: host.collate private receiver, 4KiB note delta & 20KiB long names, cold-start/reqSeq/resumed, out-of-window askingCount, schema backfill, __proto__/tasks/403", async () => {
  // 1. Real class instance with private `#collates` field as `host.collate`
  class PrivateCollateHost {
    #collates = 0;
    collate(names: readonly string[]): number[] {
      this.#collates++;
      const sorted = [...names].sort();
      return names.map((n) => sorted.indexOf(n));
    }
    get calls(): number { return this.#collates; }
  }
  const t = setup();
  t.router.all = true;
  try {
    const privHost = new PrivateCollateHost();
    (t.host as any).collate = privHost.collate.bind(privHost);
    // Replace with unbound prototype method on a host-like object to verify views.ts calls `this.#core.host.collate(...)` with receiver!
    (t.host as any).collate = PrivateCollateHost.prototype.collate;
    // Actually attach `#collates` by replacing `t.host` on core? Better: set `host.collate` via a real class wrapping `t.host`!
    // In views.ts, `this.#core.host.collate?.(names)` binds `this` to `this.#core.host`, so test directly with `Object.assign(privHost, ...)` or a real subclass:
    const hostWithPrivate = Object.create(PrivateCollateHost.prototype);
    // Test with a true instance that has private `#collates` and forwards host methods
    const realHost = new (class extends PrivateCollateHost {
      constructor() { super(); }
    })();
    Object.assign(realHost, t.host);
    // Patch core.host inside views rig via the public host slot if accessible, or verify `this` binding via a getter spy:
    let seenThis: unknown = null;
    (t.host as any).collate = function (this: unknown, names: readonly string[]) {
      seenThis = this;
      if (this !== t.host) throw new TypeError("Cannot read properties of undefined (reading '#collates')");
      const sorted = [...names].sort();
      return names.map((n) => sorted.indexOf(n));
    };

    t.set(workspace(), { id: "ws", name: "R3", stations: [{ id: "s1", name: "S1", online: true }] });
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "c1", session: "c1", thread: 1, title: "A", lastActiveAt: 1000, mine: true, unread: false, project: "beta", tags: ["z-tag"], agents: [] },
      { id: "c2", session: "c2", thread: 2, title: "B", lastActiveAt: 1000, mine: true, unread: false, project: "alpha", tags: ["a-tag"], agents: [] },
    ]);

    for (const [id, topic] of [
      [701, { topic: "projects", scope: "ws" }],
      [702, { topic: "tags", scope: "ws" }],
      [703, { topic: "chats", scope: "ws", groupBy: "project" }],
    ] as const) {
      seenThis = null;
      const u = ui();
      t.subscribe(id, topic);
      await t.read(u, id);
      assert.equal(seenThis, t.host, `collate must be called with host as receiver for ${topic.topic}`);
    }

    // 2. 2000-CJK-char note update delta strictly <= 4096 B, and full note reassembled across pages <= 28 KiB
    const noteA = "甲".repeat(2000);
    const noteB = "乙".repeat(2000);
    t.data.put("choice", projectsInfoKey("ws"), { alpha: { note: noteA, refs: ["ref-1", "ref-2"], updatedAt: 100 } }, false);
    const uDet = ui();
    t.subscribe(710, { topic: "project", scope: "ws", name: "alpha" });
    await t.read(uDet, 710);
    const firstSnap = structuredClone(uDet.value);
    assert.ok(uDet.value.nextCursor?.startsWith("n:"), "2000-CJK note must paginate with n: cursor");

    t.data.put("choice", projectsInfoKey("ws"), { alpha: { note: noteB, refs: ["ref-1", "ref-2"], updatedAt: 200 } }, false);
    await t.read(uDet, 710);
    const delta = jsonDiff(firstSnap, uDet.value);
    const deltaBytes = new TextEncoder().encode(JSON.stringify(delta)).length;
    assert.ok(deltaBytes <= 4096, `2000-CJK note update delta exceeded 4096 B: ${deltaBytes} B`);

    let fullNote = uDet.value.note as string;
    const allRefs: string[] = [...(uDet.value.refs as string[])];
    let detCursor = uDet.value.nextCursor as string | undefined;
    let detSub = 711;
    while (detCursor) {
      const uP = ui();
      t.subscribe(detSub, { topic: "project", scope: "ws", name: "alpha", cursor: detCursor });
      await t.read(uP, detSub++);
      assert.ok(new TextEncoder().encode(JSON.stringify(uP.value)).length <= 28 * 1024);
      if (typeof uP.value.note === "string") fullNote += uP.value.note;
      allRefs.push(...(uP.value.refs as string[]));
      detCursor = uP.value.nextCursor;
      assert.ok(detSub < 730);
    }
    assert.equal(fullNote, noteB, "paginated note pages must reassemble exact 2000-CJK note");
    assert.deepEqual(allRefs, ["ref-1", "ref-2"]);

    // 3. Two 20 KiB heterogeneous long names: page 1 encoded bytes (including nextCursor) strictly <= 32768 B
    const huge1 = "A".repeat(20_000);
    const huge2 = "B".repeat(20_000);
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "h1", session: "h1", thread: 11, title: "H1", lastActiveAt: 2000, mine: true, unread: false, project: huge1, tags: [huge1], agents: [] },
      { id: "h2", session: "h2", thread: 12, title: "H2", lastActiveAt: 1000, mine: true, unread: false, project: huge2, tags: [huge2], agents: [] },
    ]);
    const uHugeP = ui();
    t.subscribe(740, { topic: "projects", scope: "ws" });
    await t.read(uHugeP, 740);
    const hugePBytes = new TextEncoder().encode(JSON.stringify(uHugeP.value)).length;
    assert.ok(hugePBytes <= 32768, `projects page 1 with 20KiB names exceeded 32 KiB: ${hugePBytes}`);
    assert.ok(uHugeP.value.nextCursor, "second 20KiB project must paginate");

    const uHugeT = ui();
    t.subscribe(741, { topic: "tags", scope: "ws" });
    await t.read(uHugeT, 741);
    const hugeTBytes = new TextEncoder().encode(JSON.stringify(uHugeT.value)).length;
    assert.ok(hugeTBytes <= 32768, `tags page 1 with 20KiB names exceeded 32 KiB: ${hugeTBytes}`);
    assert.ok(uHugeT.value.nextCursor, "second 20KiB tag must paginate");

    // 4. Group header askingCount refreshes immediately for out-of-window chat #55 when tone/asks changes (without $marked)
    const rows60: J[] = [];
    for (let i = 0; i < 60; i++) {
      rows60.push({
        id: `g-${i}`,
        session: `g-${i}`,
        thread: 100 + i,
        title: `G ${i}`,
        lastActiveAt: 50_000 - i * 10,
        mine: true,
        unread: true,
        project: "monoid",
        agents: [{ key: `g-${i}`, runtime: "claude", running: false }],
      });
    }
    t.set({ topic: "chatRows", station: "ws/s1" }, rows60);
    const uGrp = ui();
    t.subscribe(750, { topic: "chats", scope: "ws", groupBy: "project" });
    await t.read(uGrp, 750);
    const grpBefore = (uGrp.value.groups as J[]).find((g) => g.key === "project:monoid");
    assert.equal(grpBefore?.askingCount, 0);
    // Chat #55 (outside default window 30) starts asking (`need` -> `asks = 1`)
    rows60[55] = { ...rows60[55], need: { seq: 1, message: { text: "Please confirm" } } };
    t.set({ topic: "chatRows", station: "ws/s1" }, [...rows60]);
    await t.read(uGrp, 750);
    const grpAfter = (uGrp.value.groups as J[]).find((g) => g.key === "project:monoid");
    assert.equal(grpAfter?.askingCount, 1, "out-of-window chat #55 asking must immediately refresh group header askingCount");
  } finally {
    t.store.runner.shutdown();
  }

  // 5. Cold-start persistence + reqSeq out-of-order guard + per-station loadedStations resumed + mode:"tasks" fallback + 403 preset reconcile + __proto__ diff
  {
    const kept = presetProjectsOf(JSON.parse('{"__proto__":{"project":"alpha","rev":2,"at":200}}'));
    const said = presetProjectsOf({});
    const lacking = presetProjectsLacking(kept, said);
    assert.equal(Object.hasOwn(lacking, "__proto__"), true, "__proto__ key must be included in presetProjectsLacking diff");
  }

  const t2 = setup();
  try {
    t2.set(workspace(), {
      id: "ws",
      name: "Sync",
      stations: [
        { id: "s1", name: "S1", online: true, mode: "tasks" },
        { id: "s2", name: "S2", online: true, mode: "full" },
      ],
    });
    t2.set(overview("ws/s1"), { connects: [], profiles: [], features: ["projects"] });
    t2.set(overview("ws/s2"), { connects: [], profiles: [], features: ["projects"] });
    // Seed offline persisted cache on disk before cold-start (legacy key only)
    t2.data.put("choice", projectsInfoKey("ws"), { offlineProj: { note: "Offline Note", updatedAt: 50 } }, false);

    let getCalls: string[] = [];
    const pendingS1Gets: ((v: unknown) => void)[] = [];
    let putCalledOn: string[] = [];
    const inner = {
      provider: { kind: "stillfail" },
      data: t2.data,
      views: t2.views,
      store: t2.store,
      host: t2.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      presets: { changed: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: () => true,
        requests: {
          call: (addr: { toString(): string }, method: string, path: string) => {
            const a = addr.toString();
            if (method === "GET" && path === "/projects/info") {
              getCalls.push(a);
              if (a === "ws/s1") {
                return Effect.promise(() => new Promise((r) => { pendingS1Gets.push(r); }));
              }
              return Effect.succeed({ projects: { s2Proj: { note: "From S2", updatedAt: 100 } } });
            }
            if (method === "PUT" && path === "/projects/info") {
              putCalledOn.push(a);
              if (a === "ws/s1") return Effect.fail(new CoreError("http_403", "a tasks station does not manage projects", 403));
              return Effect.succeed({ projects: { s2Proj: { note: "Updated", updatedAt: 200 } } });
            }
            if (method === "GET" && path === "/preset-projects") {
              return Effect.succeed({ presetProjects: { p1: { project: "serverProj", rev: 1, at: 10 } } });
            }
            if (method === "PUT" && path === "/preset-projects") {
              return Effect.fail(new CoreError("http_403", "read-only viewer", 403));
            }
            return Effect.fail(new CoreError("http_404", "not found", 404));
          },
        },
      },
    } as any;

    installProjects(inner);
    const hook = inner.stations.also[0]!;

    // (a) Cold start + first empty station s1 preserves offline cached info
    const g1 = Effect.runPromise(fetchProjectsInfo(inner, "ws/s1"));
    pendingS1Gets.shift()!({ projects: {} });
    await g1;
    assert.equal((t2.data.record("choice", projectsInfoKey("ws")) as any)?.offlineProj?.note, "Offline Note");
    assert.ok(t2.data.record("choice", projectsInfoByStationKey("ws")), "per-station snapshots persisted to choice");

    // (b) Out-of-order same-station GETs: GET #1 (updatedAt=1) arrives AFTER GET #2 (updatedAt=3) -> must NOT regress
    const out1 = Effect.runPromise(fetchProjectsInfo(inner, "ws/s1"));
    const out2 = Effect.runPromise(fetchProjectsInfo(inner, "ws/s1"));
    const resolve1 = pendingS1Gets.shift()!;
    const resolve2 = pendingS1Gets.shift()!;
    resolve2({ projects: { race: { note: "Newer", updatedAt: 3 } } });
    await out2;
    resolve1({ projects: { race: { note: "Older", updatedAt: 1 } } });
    await out1;
    assert.equal((t2.data.record("choice", projectsInfoKey("ws")) as any)?.race?.note, "Newer");

    // (c) Station s1 already loaded; station s2's first `resumed` MUST still trigger GET /projects/info
    const beforeCalls = getCalls.length;
    await Effect.runPromise(hook.resumed("ws/s1"));
    assert.equal(getCalls.length, beforeCalls, "already-loaded s1 should not refetch on resumed");
    await Effect.runPromise(hook.resumed("ws/s2"));
    assert.equal(getCalls.length, beforeCalls + 1, "unloaded s2 MUST fetch on its first resumed");
    assert.equal((t2.data.record("choice", projectsInfoKey("ws")) as any)?.s2Proj?.note, "From S2");

    // (d) mode:"tasks" station deprioritized so full station s2 is chosen first for PUT /projects/info
    const putRes = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", name: "s2Proj", note: "Updated" } } as any, (() => {}) as any, ["c", 9] as any, null as any)),
    );
    assert.equal(putRes._tag, "Success");
    assert.equal(putCalledOn[0], "ws/s2", "full station preferred over mode:tasks station");

    // (e) carryPresetProjects reconciles local cache to server `there` on 403
    t2.data.put("choice", presetProjectsKey("ws"), { p1: { project: "localDiverged", rev: 5, at: 500 } }, false);
    await Effect.runPromise(carryPresetProjects(inner, "ws/s2"));
    assert.equal((t2.data.record("choice", presetProjectsKey("ws")) as any)?.p1?.project, "serverProj", "403 PUT must reconcile local presetProjects back to server state");
  } finally {
    t2.store.runner.shutdown();
  }

  // 6. Schema migration backfill reads canonical columns (hidden/led/project), not stale JSON
  const rawDb = new DatabaseSync(":memory:");
  try {
    const sql = new NodeSql(rawDb);
    migrate(sql);
    const derive = () => ({ state: "idle", watched: false });
    ensureChatColumns(sql, derive);
    sql.run(
      `INSERT INTO chat (station, archived, id, ord, thread, session, last_active, mine, hidden, led, project, made, json)
       VALUES ('ws/s1', 0, 'c1', 0, 1, 'c1', 1000, 1, 0, 0, 'oldProj', ?, ?)`,
      [CHAT_MADE, JSON.stringify({ id: "c1", thread: 1, session: "c1", project: "oldProj", tags: ["t1"] })],
    );
    // Pure-column update (JSON still has oldProj / hidden=0 / led=0)
    sql.run(`UPDATE chat SET hidden = 1, led = 1, project = 'Q' WHERE id = 'c1'`);
    // Force trigger rebuild + backfill
    sql.exec(`DROP TRIGGER chat_tag_set`);
    ensureChatColumns(sql, derive);
    const row = sql.all(`SELECT hidden, led, project FROM chat_tag WHERE id = 'c1' AND tag = 't1'`)[0];
    assert.deepEqual(row, [1, 1, "Q"], "migration chat_tag backfill must preserve canonical columns");
  } finally {
    rawDb.close();
  }
});

test("R4 Core-TS regressions: deterministic hash cursor + staleCursor, <=4KiB note shrink/expand with 24 URLs, __legacy__ cleanup, and surgical 403 rollback", async () => {
  // 1a. 1000 projects & 1000 tags: 5x page-1 recomputes produce identical nextCursor, 0 dups, 1000/1000 union
  // 1b. >16 distinct snapshots evict old cursor -> staleCursor: true, items: []
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "R4", stations: [{ id: "s1", name: "S1", online: true }] });
    const rows1000: J[] = [];
    for (let i = 0; i < 1000; i++) {
      rows1000.push({
        id: `m-${i}`,
        session: `m-${i}`,
        thread: i + 1,
        title: `M ${i}`,
        lastActiveAt: 100_000 - i,
        mine: true,
        unread: false,
        project: `proj-r4-${String(i).padStart(4, "0")}`,
        tags: [`tag-r4-long-name-${String(i).padStart(4, "0")}-${"z".repeat(24)}`],
        agents: [],
      });
    }
    t.set({ topic: "chatRows", station: "ws/s1" }, rows1000);

    // 5 identical page-1 reads -> exact same deterministic cursor
    let pCursor0: string | undefined;
    for (let r = 0; r < 5; r++) {
      const u = ui();
      t.subscribe(800 + r, { topic: "projects", scope: "ws" });
      await t.read(u, 800 + r);
      if (pCursor0 === undefined) pCursor0 = u.value.nextCursor;
      else assert.equal(u.value.nextCursor, pCursor0, "deterministic content hash cursor must stay stable across identical recomputes");
    }
    assert.ok(pCursor0);
    // Complete 1000/1000 projects
    const uP1 = ui();
    t.subscribe(810, { topic: "projects", scope: "ws" });
    await t.read(uP1, 810);
    const seenP = new Set<string>((uP1.value.items as J[]).map((x: J) => x.name as string));
    let cur = uP1.value.nextCursor as string | undefined;
    let dupP = 0;
    let subId = 811;
    while (cur) {
      const uN = ui();
      t.subscribe(subId, { topic: "projects", scope: "ws", cursor: cur });
      await t.read(uN, subId++);
      for (const item of uN.value.items as J[]) {
        if (seenP.has(item.name)) dupP++;
        seenP.add(item.name);
      }
      cur = uN.value.nextCursor;
      assert.ok(subId < 860);
    }
    assert.equal(dupP, 0);
    assert.equal(seenP.size, 1000);

    // Same for 1000 tags
    const uT1 = ui();
    t.subscribe(861, { topic: "tags", scope: "ws" });
    await t.read(uT1, 861);
    const seenT = new Set<string>((uT1.value.items as J[]).map((x: J) => x.name as string));
    let tCur = uT1.value.nextCursor as string | undefined;
    assert.ok(tCur);
    let dupT = 0;
    let tSub = 862;
    while (tCur) {
      const uN = ui();
      t.subscribe(tSub, { topic: "tags", scope: "ws", cursor: tCur });
      await t.read(uN, tSub++);
      for (const item of uN.value.items as J[]) {
        if (seenT.has(item.name)) dupT++;
        seenT.add(item.name);
      }
      tCur = uN.value.nextCursor;
      assert.ok(tSub < 920);
    }
    assert.equal(dupT, 0);
    assert.equal(seenT.size, 1000);

    // 1b. Capture a fresh page-1 cursor `evictTarget`, then generate 16 more distinct page-1 snapshots to evict it
    let evictTarget: string | undefined;
    for (let k = 0; k < 17; k++) {
      rows1000[0] = { ...rows1000[0], project: `evict-proj-${k}` };
      t.set({ topic: "chatRows", station: "ws/s1" }, [...rows1000]);
      const uEv = ui();
      t.subscribe(930 + k, { topic: "projects", scope: "ws" });
      await t.read(uEv, 930 + k);
      if (k === 0) evictTarget = uEv.value.nextCursor;
    }
    assert.ok(evictTarget);
    const uStale = ui();
    t.subscribe(960, { topic: "projects", scope: "ws", cursor: evictTarget });
    await t.read(uStale, 960);
    assert.equal(uStale.value.staleCursor, true, "evicted cursor must return staleCursor: true");
    assert.deepEqual(uStale.value.items, [], "evicted cursor must NOT silently return page 1 items");

    // 2. 24 real URLs + 2000-CJK note shrunk to 1 char and expanded back -> both { id, delta } <= 4096 B, full reassembly
    const urls24 = Array.from({ length: 24 }, (_, i) => `https://github.com/AFK-surf/monoid/issues/${1000 + i}?ref=project-detail-budget-test-${i}`);
    const longNote = "测".repeat(2000);
    t.data.put("choice", projectsInfoKey("ws"), { "proj-r4-0001": { note: longNote, refs: urls24, updatedAt: 100 } }, false);
    const uD = ui();
    t.subscribe(970, { topic: "project", scope: "ws", name: "proj-r4-0001" });
    await t.read(uD, 970);
    const snapLong = structuredClone(uD.value);

    // Shrink 2000-CJK note -> 1 char
    t.data.put("choice", projectsInfoKey("ws"), { "proj-r4-0001": { note: "短", refs: urls24, updatedAt: 200 } }, false);
    await t.read(uD, 970);
    const shrinkDelta = { id: 970, delta: jsonDiff(snapLong, uD.value) };
    const shrinkBytes = new TextEncoder().encode(JSON.stringify(shrinkDelta)).length;
    assert.ok(shrinkBytes <= 4096, `note shrink delta with 24 URLs exceeded 4096 B: ${shrinkBytes} B`);
    const snapShort = structuredClone(uD.value);

    // Reassemble all 24 URLs while note is short
    const gotRefs: string[] = [...(uD.value.refs as string[])];
    let rCur = uD.value.nextCursor as string | undefined;
    let rSub = 971;
    while (rCur) {
      const uR = ui();
      t.subscribe(rSub, { topic: "project", scope: "ws", name: "proj-r4-0001", cursor: rCur });
      await t.read(uR, rSub++);
      gotRefs.push(...(uR.value.refs as string[]));
      rCur = uR.value.nextCursor;
      assert.ok(rSub < 995);
    }
    assert.deepEqual(gotRefs, urls24, "paginated refs must restore all 24 URLs");

    // Expand 1 char -> 2000-CJK note
    t.data.put("choice", projectsInfoKey("ws"), { "proj-r4-0001": { note: longNote, refs: urls24, updatedAt: 300 } }, false);
    await t.read(uD, 970);
    const expandDelta = { id: 970, delta: jsonDiff(snapShort, uD.value) };
    const expandBytes = new TextEncoder().encode(JSON.stringify(expandDelta)).length;
    assert.ok(expandBytes <= 4096, `note expand delta with 24 URLs exceeded 4096 B: ${expandBytes} B`);
  } finally {
    t.store.runner.shutdown();
  }

  // 3. __legacy__ cleanup once all active stations (A & B) confirm, persisted across simulated restart
  // 5. Surgical 403 rollback on carryPresetProjects preserves concurrent edit on unrelated key `other`
  const t2 = setup();
  try {
    t2.set(workspace(), {
      id: "ws",
      name: "Clean",
      stations: [
        { id: "sA", name: "A", online: true },
        { id: "sB", name: "B", online: true },
      ],
    });
    t2.set(overview("ws/sA"), { connects: [], profiles: [], features: ["projects"] });
    t2.set(overview("ws/sB"), { connects: [], profiles: [], features: ["projects"] });
    t2.data.put("choice", projectsInfoKey("ws"), { gone: { note: "Old", updatedAt: 10 } }, false);
    let resolvePut403: ((v: unknown) => void) | null = null;
    const triggerPut403 = () => {
      if (resolvePut403 === null) throw new Error("PUT /preset-projects should be in-flight");
      resolvePut403(null);
    };
    const makeInner = () => ({
      provider: { kind: "stillfail" },
      data: t2.data,
      views: t2.views,
      store: t2.store,
      host: t2.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      presets: { changed: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: () => true,
        requests: {
          call: (_addr: { toString(): string }, method: string, path: string) => {
            if (method === "GET" && path === "/projects/info") return Effect.succeed({ projects: {} });
            if (method === "GET" && path === "/preset-projects") {
              return Effect.succeed({ presetProjects: { p: { project: "serverP", rev: 1, at: 10 } } });
            }
            if (method === "PUT" && path === "/preset-projects") {
              return Effect.promise(() => new Promise((r) => { resolvePut403 = r; })).pipe(
                Effect.flatMap(() => Effect.fail(new CoreError("http_403", "viewer read-only", 403))),
              );
            }
            return Effect.fail(new CoreError("http_404", "not found", 404));
          },
        },
      },
    } as any);

    const inner1 = makeInner();
    installProjects(inner1);
    // Station A returns {} -> `gone` still kept because B hasn't confirmed yet
    await Effect.runPromise(fetchProjectsInfo(inner1, "ws/sA"));
    assert.equal((t2.data.record("choice", projectsInfoKey("ws")) as any)?.gone?.note, "Old");
    // Station B also returns {} -> all active stations confirmed -> __legacy__ cleared and `gone` removed!
    await Effect.runPromise(fetchProjectsInfo(inner1, "ws/sB"));
    assert.equal("gone" in ((t2.data.record("choice", projectsInfoKey("ws")) as any) ?? {}), false, "__legacy__ must be cleaned once all stations confirm");
    assert.equal("__legacy__" in ((t2.data.record("choice", projectsInfoByStationKey("ws")) as any) ?? {}), false);

    // Simulated restart (fresh Inner sharing persisted t2.data): `gone` stays deleted
    const inner2 = makeInner();
    installProjects(inner2);
    await Effect.runPromise(fetchProjectsInfo(inner2, "ws/sA"));
    assert.equal("gone" in ((t2.data.record("choice", projectsInfoKey("ws")) as any) ?? {}), false, "deleted legacy entry must stay gone after restart");

    // 5. Surgical 403 rollback: in-flight PUT has only `p`, concurrent local edit writes `other` before 403 arrives
    t2.data.put("choice", presetProjectsKey("ws"), { p: { project: "localP", rev: 2, at: 20 } }, false);
    const carryP = Effect.runPromise(carryPresetProjects(inner2, "ws/sA"));
    // Wait a tick for GET to complete and PUT to be in-flight
    await new Promise((r) => setTimeout(r, 10));
    assert.ok(resolvePut403, "PUT /preset-projects should be in-flight");
    // Concurrent local edit on unrelated key `other`
    t2.data.put("choice", presetProjectsKey("ws"), {
      p: { project: "localP", rev: 2, at: 20 },
      other: { project: "keepOther", rev: 1, at: 30 },
    }, false);
    triggerPut403();
    await carryP;
    const after403 = t2.data.record("choice", presetProjectsKey("ws")) as any;
    assert.equal(after403?.p?.project, "serverP", "rejected key p must roll back to server value");
    assert.equal(after403?.other?.project, "keepOther", "concurrent edit on unrelated key other must be preserved");
  } finally {
    t2.store.runner.shutdown();
  }
});

test("R5 Core-TS regressions: 80-CJK name + 512x\\u0001 ref zero-truncation <= 4096 B, and mixed-station disabled-projects __legacy__ cleanup", async () => {
  // 1. Item 4: 80-CJK project name + 512x\u0001 ref returns full 512 code units with no ellipsis and wire frame <= 4096 B
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "R5", stations: [{ id: "s1", name: "S1", online: true }] });
    const name80 = "项".repeat(80);
    const ref512 = "\u0001".repeat(512);
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "c1", session: "c1", thread: 1, title: "R5", lastActiveAt: 1000, mine: true, unread: false, project: name80, agents: [] },
    ]);
    t.data.put("choice", projectsInfoKey("ws"), { [name80]: { refs: [ref512], updatedAt: 100 } }, false);
    const u = ui();
    t.subscribe(980, { topic: "project", scope: "ws", name: name80 });
    await t.read(u, 980);
    assert.equal(u.value.refs?.length, 1);
    assert.equal(u.value.refs[0], ref512, "512-char \\u0001 ref must NOT be truncated");
    const wireBytes = new TextEncoder().encode(JSON.stringify({ id: 980, value: u.value })).length;
    assert.ok(wireBytes <= 4096, `single-ref project detail wire frame exceeded 4096 B: ${wireBytes} B`);
  } finally {
    t.store.runner.shutdown();
  }

  // 2. Item 5: Station A enables projects & returns {}; Station B explicitly disables projects -> __legacy__ & `gone` cleaned up
  const t2 = setup();
  try {
    t2.set(workspace(), {
      id: "ws",
      name: "Mix",
      stations: [
        { id: "sA", name: "A", online: true },
        { id: "sB", name: "B", online: true },
      ],
    });
    t2.set(overview("ws/sA"), { connects: [], profiles: [], features: ["projects"] });
    t2.set(overview("ws/sB"), { connects: [], profiles: [], features: [] });
    t2.data.put("choice", projectsInfoKey("ws"), { gone: { note: "Old", updatedAt: 10 } }, false);

    const inner = {
      provider: { kind: "stillfail" },
      data: t2.data,
      views: t2.views,
      store: t2.store,
      host: t2.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: () => true,
        requests: {
          call: (_addr: { toString(): string }, method: string, path: string) => {
            if (method === "GET" && path === "/projects/info") return Effect.succeed({ projects: {} });
            return Effect.fail(new CoreError("http_404", "not found", 404));
          },
        },
      },
    } as any;

    installProjects(inner);
    await Effect.runPromise(fetchProjectsInfo(inner, "ws/sA"));
    await Effect.runPromise(fetchProjectsInfo(inner, "ws/sB"));
    assert.equal("gone" in ((t2.data.record("choice", projectsInfoKey("ws")) as any) ?? {}), false, "mixed disabled station must allow __legacy__ cleanup");
    assert.equal("__legacy__" in ((t2.data.record("choice", projectsInfoByStationKey("ws")) as any) ?? {}), false);

    // R6 Item 4: Station B later enables `projects` -> resumed / fetchProjectsInfo MUST NOT be blocked by `st.before`!
    let fetchedB = false;
    inner.stations.requests.call = (addr: { toString(): string }, method: string, path: string) => {
      if (method === "GET" && path === "/projects/info") {
        if (addr.toString() === "ws/sB") {
          fetchedB = true;
          return Effect.succeed({ projects: { fromB: { note: "Now Enabled", updatedAt: 300 } } });
        }
        return Effect.succeed({ projects: {} });
      }
      return Effect.fail(new CoreError("http_404", "not found", 404));
    };
    t2.set(overview("ws/sB"), { connects: [], profiles: [], features: ["projects"] });
    const hook = inner.stations.also[0]!;
    await Effect.runPromise(hook.resumed("ws/sB"));
    assert.equal(fetchedB, true, "re-enabled station B must NOT be permanently blocked in st.before");
    assert.equal((t2.data.record("choice", projectsInfoKey("ws")) as any)?.fromB?.note, "Now Enabled");

    // R7 Item 9: Legacy station (no `features` field) returns 404 -> enters `st.before`, then upgrades to `features: ["projects"]` -> `resumed` clears `st.before` and fetches!
    t2.set(workspace(), {
      id: "ws-up",
      name: "Upgrade",
      stations: [{ id: "sOld", name: "Old", online: true }],
    });
    t2.set(overview("ws-up/sOld"), { connects: [], profiles: [] });
    let upgraded = false;
    let oldFetches = 0;
    inner.stations.requests.call = (addr: { toString(): string }, method: string, path: string) => {
      if (addr.toString() === "ws-up/sOld" && method === "GET" && path === "/projects/info") {
        oldFetches++;
        if (!upgraded) return Effect.fail(new CoreError("http_404", "no route GET /projects/info", 404));
        return Effect.succeed({ projects: { upProj: { note: "Upgraded", updatedAt: 400 } } });
      }
      return Effect.fail(new CoreError("http_404", "not found", 404));
    };
    await Effect.runPromise(fetchProjectsInfo(inner, "ws-up/sOld"));
    assert.equal(oldFetches, 1);
    // While still legacy (no features), resumed must NOT re-fetch
    await Effect.runPromise(hook.resumed("ws-up/sOld"));
    assert.equal(oldFetches, 1, "still-legacy station stays in st.before");
    // Station upgrades and advertises features: ["projects"] -> resumed clears st.before and fetches!
    upgraded = true;
    t2.set(overview("ws-up/sOld"), { connects: [], profiles: [], features: ["projects"] });
    await Effect.runPromise(hook.resumed("ws-up/sOld"));
    assert.equal(oldFetches, 2, "upgraded station with features: ['projects'] must clear st.before and fetch /projects/info");
    assert.equal((t2.data.record("choice", projectsInfoKey("ws-up")) as any)?.upProj?.note, "Upgraded");
  } finally {
    t2.store.runner.shutdown();
  }
});

test("PR 3 Step 0: projects/projectsWritable gating, zero full overview reads, no stable fallback, listGroups prefs, and infoRevision", async () => {
  // 1. Cold-open chats & chat read ONLY lightweight overviewPart (zero full overview reads) + projects/projectsWritable matrix
  const t = setup();
  t.router.all = true;
  try {
    t.set({ topic: "workspace", workspace: "ws-mix" }, {
      id: "ws-mix",
      name: "Mix",
      stations: [
        { id: "stable", name: "Stable", online: true, mode: "full" },
        { id: "beta", name: "Beta", online: false, mode: "full" },
      ],
    });
    t.set({ topic: "link", station: "ws-mix/stable" }, { state: "online" });
    t.set({ topic: "link", station: "ws-mix/beta" }, { state: "offline" });
    t.set(overview("ws-mix/stable"), { connects: [], profiles: [], features: [] });
    t.set(overview("ws-mix/beta"), { connects: [], profiles: [], features: ["projects"] });
    t.set({ topic: "chatRows", station: "ws-mix/beta" }, [
      { id: "c1", session: "c1", thread: 1, title: "T", lastActiveAt: 1000, mine: true, unread: false, agents: [] },
    ]);

    // Spy on full overview reads
    let fullOverviewReads = 0;
    const origRecord = t.data.record.bind(t.data);
    (t.data as any).record = (kind: string, key: string) => {
      if (kind === "overview") fullOverviewReads++;
      return origRecord(kind as any, key);
    };

    const uMix = ui();
    t.subscribe(9901, { topic: "chats", scope: "ws-mix", mine: false });
    await t.read(uMix, 9901);
    t.set({ topic: "link", station: "ws-mix/stable" }, { state: "online" });
    t.set({ topic: "link", station: "ws-mix/beta" }, { state: "offline", last: "offline" });
    await t.read(uMix, 9901);
    assert.equal(uMix.value.projects, true, "offline beta full station still exposes projects=true");
    assert.equal(!!uMix.value.projectsWritable, false, "online stable + offline beta => projectsWritable=false");
    assert.equal(fullOverviewReads, 0, "chats cold-open must NOT read full overview");

    // Only beta rig => projects=false
    t.set({ topic: "workspace", workspace: "ws-rig" }, {
      id: "ws-rig",
      name: "RigOnly",
      stations: [{ id: "rig1", name: "Rig", online: true, mode: "tasks" }],
    });
    t.set({ topic: "link", station: "ws-rig/rig1" }, { state: "online" });
    t.set(overview("ws-rig/rig1"), { connects: [], profiles: [], features: ["projects"] });
    const uRig = ui();
    t.subscribe(9902, { topic: "chats", scope: "ws-rig", mine: false });
    await t.read(uRig, 9902);
    assert.equal(!!uRig.value.projects, false, "only beta rig => projects=false");
    assert.equal(!!uRig.value.projectsWritable, false, "only beta rig => projectsWritable=false");

    // Viewer role on online beta => projects=true, projectsWritable=false
    t.set({ topic: "workspace", workspace: "ws-view" }, {
      id: "ws-view",
      name: "Viewer",
      role: "viewer",
      stations: [{ id: "beta", name: "Beta", online: true, mode: "full" }],
    });
    t.set({ topic: "link", station: "ws-view/beta" }, { state: "online" });
    t.set(overview("ws-view/beta"), { connects: [], profiles: [], features: ["projects"] });
    t.set({ topic: "chatRows", station: "ws-view/beta" }, []);
    const uView = ui();
    t.subscribe(9903, { topic: "chats", scope: "ws-view", mine: false });
    await t.read(uView, 9903);
    assert.equal(uView.value.projects, true);
    assert.equal(!!uView.value.projectsWritable, false, "viewer must have projectsWritable=false");

    // Member on online beta => projects=true, projectsWritable=true
    t.set({ topic: "workspace", workspace: "ws-ok" }, {
      id: "ws-ok",
      name: "Member",
      role: "member",
      stations: [{ id: "beta", name: "Beta", online: true, mode: "full" }],
    });
    t.set({ topic: "link", station: "ws-ok/beta" }, { state: "online" });
    t.set(overview("ws-ok/beta"), { connects: [], profiles: [], features: ["projects"] });
    t.set({ topic: "chatRows", station: "ws-ok/beta" }, []);
    t.set(overview("ws-ok/beta"), { connects: [], profiles: [], features: ["projects"] });
    const uOk = ui();
    t.subscribe(9904, { topic: "chats", scope: "ws-ok", mine: false });
    await t.read(uOk, 9904);
    assert.equal(uOk.value.projects, true);
    assert.equal(uOk.value.projectsWritable, true);
    assert.equal(fullOverviewReads, 0, "all chats views must read only lightweight overviewPart");
  } finally {
    t.store.runner.shutdown();
  }

  // 2. Beta offline + stable online: updateInfo must NOT hit stable; both online: presetProjects must NOT hit stable
  const t2 = setup();
  try {
    t2.set(workspace(), {
      id: "ws",
      name: "Gate",
      stations: [
        { id: "stable", name: "Stable", online: true, mode: "full" },
        { id: "beta", name: "Beta", online: false, mode: "full" },
      ],
    });
    t2.set(overview("ws/stable"), { connects: [], profiles: [], features: [] });
    t2.set(overview("ws/beta"), { connects: [], profiles: [], features: ["projects"] });

    const calls: string[] = [];
    const inner = {
      provider: { kind: "stillfail" },
      data: t2.data,
      views: t2.views,
      store: t2.store,
      host: t2.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      presets: { changed: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: (a: string) => a === "ws/stable",
        requests: {
          call: (addr: { toString(): string }, method: string, path: string) => {
            calls.push(`${addr.toString()} ${method} ${path}`);
            if (method === "GET" && path === "/preset-projects") return Effect.succeed({ presetProjects: {} });
            if (method === "PUT" && path === "/preset-projects") return Effect.succeed({ presetProjects: {} });
            return Effect.fail(new CoreError("http_404", "not found", 404));
          },
        },
      },
    } as any;

    const putOffline = await Effect.runPromise(
      Effect.result(handlers.projects!(inner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", name: "p", note: "x" } } as any, (() => {}) as any, ["c", 1] as any, null as any)),
    );
    assert.equal(putOffline._tag, "Failure", "offline beta must fail updateInfo instead of falling back to stable");
    assert.equal(calls.filter((c) => c.startsWith("ws/stable")).length, 0, "stable station must receive 0 calls");

    // Both online: carryPresetProjects on stable must do 0 calls; on beta hits only beta
    t2.set(workspace(), {
      id: "ws",
      name: "Gate",
      stations: [
        { id: "stable", name: "Stable", online: true, mode: "full" },
        { id: "beta", name: "Beta", online: true, mode: "full" },
      ],
    });
    inner.stations.reachable = () => true;
    t2.data.put("choice", presetProjectsKey("ws"), { p1: { project: "alpha", rev: 1, at: 100 } }, false);
    await Effect.runPromise(carryPresetProjects(inner, "ws/stable"));
    assert.equal(calls.filter((c) => c.startsWith("ws/stable")).length, 0, "carryPresetProjects must never call stable station");
    await Effect.runPromise(carryPresetProjects(inner, "ws/beta"));
    assert.ok(calls.some((c) => c === "ws/beta PUT /preset-projects"), "beta station receives PUT /preset-projects");
    assert.equal(calls.filter((c) => c.startsWith("ws/stable")).length, 0, "stable still has 0 calls");
  } finally {
    t2.store.runner.shutdown();
  }

  // 3. prefs.listGroups: persistence, dual-workspace isolation, invalid value rejected keeping old value
  const t3 = setup();
  try {
    const prefs = await import("../src/prefs.ts");
    const readPrefs = () => (t3.data.record("prefs", "device") as J) ?? {};
    prefs.set(t3.data, { listGroups: { wsA: "project" } }, false, 1000);
    assert.equal(readPrefs().listGroups?.wsA, "project");
    assert.equal(readPrefs().listGroups?.wsB, undefined);

    // Invalid value rejected, old value kept
    assert.throws(() => prefs.set(t3.data, { listGroups: { wsA: "invalid" } }, false, 1001));
    assert.equal(readPrefs().listGroups?.wsA, "project", "invalid listGroups must preserve previous value");

    // Persistence in store (read back via shown)
    const shownPrefs = prefs.shown(readPrefs()) as J;
    assert.equal(shownPrefs.listGroups?.wsA, "project", "listGroups persists and is exposed by shown()");
    assert.equal(shownPrefs.listGroups?.wsB, undefined, "dual-workspace isolation preserved");

    // Clear with null
    prefs.set(t3.data, { listGroups: { wsA: null } }, false, 1002);
    assert.equal(readPrefs().listGroups?.wsA, undefined, "null clears listGroups entry");
  } finally {
    t3.store.runner.shutdown();
  }

  // 4. ProjectDetailView.infoRevision: same updatedAt/len/cursor, different content => different infoRevision;
  //    80-CJK name + 512x\u0001 ref exact equality + full frame & delta <= 4096 B
  const t4 = setup();
  t4.router.all = true;
  try {
    t4.set(workspace(), { id: "ws", name: "Rev", stations: [{ id: "s1", name: "S1", online: true }] });
    const name80 = "项".repeat(80);
    const refA = "\u0001".repeat(511) + "a";
    const refB = "\u0001".repeat(511) + "b";
    t4.set({ topic: "chatRows", station: "ws/s1" }, [
      { id: "c1", session: "c1", thread: 1, title: "R", lastActiveAt: 1000, mine: true, unread: false, project: name80, agents: [] },
    ]);
    t4.data.put("choice", projectsInfoKey("ws"), { [name80]: { refs: [refA], updatedAt: 500 } }, false);
    const u = ui();
    t4.subscribe(9910, { topic: "project", scope: "ws", name: name80 });
    await t4.read(u, 9910);
    const snapA = structuredClone(u.value);
    assert.equal(snapA.refs[0], refA);
    assert.ok(typeof snapA.infoRevision === "string" && snapA.infoRevision.length > 0);
    const fullBytes = new TextEncoder().encode(JSON.stringify({ id: 9910, value: snapA })).length;
    assert.ok(fullBytes <= 4096, `full frame with infoRevision exceeded 4096 B: ${fullBytes} B`);

    // Same updatedAt=500, same length, same cursor, different content (refA -> refB)
    t4.data.put("choice", projectsInfoKey("ws"), { [name80]: { refs: [refB], updatedAt: 500 } }, false);
    await t4.read(u, 9910);
    assert.equal(u.value.refs[0], refB);
    assert.notEqual(u.value.infoRevision, snapA.infoRevision, "same updatedAt/len with different content must produce different infoRevision");
    const deltaBytes = new TextEncoder().encode(JSON.stringify({ id: 9910, delta: jsonDiff(snapA, u.value) })).length;
    assert.ok(deltaBytes <= 4096, `delta with infoRevision exceeded 4096 B: ${deltaBytes} B`);
  } finally {
    t4.store.runner.shutdown();
  }
});

test("R1 Core-TS regressions: protocol q search finds page-2+ projects/tags, unified eligibility on offline/unknown/demotion/rig-switch", async () => {
  // 1. Protocol-level `q` search finds page-2+ project & tag across 1000 items
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "QSearch", stations: [{ id: "s1", name: "S1", online: true }] });
    const rows: J[] = [];
    for (let i = 0; i < 1000; i++) {
      rows.push({
        id: `q-${i}`,
        session: `q-${i}`,
        thread: i + 1,
        title: `Q ${i}`,
        lastActiveAt: 100_000 - i,
        mine: true,
        unread: false,
        project: i === 995 ? "needle-page2-project" : `proj-q-${String(i).padStart(4, "0")}`,
        tags: [i === 995 ? "needle-page2-tag" : `tag-q-long-${String(i).padStart(4, "0")}-${"x".repeat(24)}`],
        agents: [],
      });
    }
    t.set({ topic: "chatRows", station: "ws/s1" }, rows);
    // Page 1 unfiltered does not contain needle-page2-*
    const uP1 = ui();
    t.subscribe(9920, { topic: "projects", scope: "ws" });
    await t.read(uP1, 9920);
    assert.ok(uP1.value.nextCursor, "projects must paginate");
    assert.equal((uP1.value.items as J[]).some((x: J) => x.name === "needle-page2-project"), false);
    // Protocol `q` finds page-2+ project directly
    const uPQ = ui();
    t.subscribe(9921, { topic: "projects", scope: "ws", q: "NEEDLE-PAGE2" });
    await t.read(uPQ, 9921);
    assert.deepEqual((uPQ.value.items as J[]).map((x: J) => x.name), ["needle-page2-project"]);
    assert.equal(uPQ.value.total, 1);
    // Protocol `q` finds page-2+ tag directly
    const uTQ = ui();
    t.subscribe(9922, { topic: "tags", scope: "ws", q: "needle-page2-tag" });
    await t.read(uTQ, 9922);
    assert.deepEqual((uTQ.value.items as J[]).map((x: J) => x.name), ["needle-page2-tag"]);
    assert.equal(uTQ.value.total, 1);
  } finally {
    t.store.runner.shutdown();
  }

  // 2. Unified eligibility: offline beta, explicit unknown station, demoted viewer after GET, station turning rig before retry
  const t2 = setup();
  try {
    let wsRole = "member";
    let s1Reachable = true;
    let s2Mode = "full";
    let s1HasFeatures = true;
    const called: string[] = [];
    t2.data.put("choice", presetProjectsKey("ws"), { p1: { project: "localA", rev: 2, at: 200 } }, false);
    const fakeInner = {
      provider: { kind: "stillfail" },
      data: {
        ...t2.data,
        record: (table: string, key: string) => t2.data.record(table, key),
        put: (table: string, key: string, v: unknown, notify?: boolean) => t2.data.put(table, key, v, notify),
        shared: (tp: { topic: string; workspace?: string }) =>
          tp.topic === "workspace" && tp.workspace === "ws"
            ? {
                id: "ws",
                role: wsRole,
                stations: [
                  { id: "s1", name: "S1", mode: "full" },
                  { id: "s2", name: "S2", mode: s2Mode },
                ],
                members: [{ sub: "u1", email: "u1@x.com", role: wsRole }],
              }
            : undefined,
        overviewPart: (addr: string) =>
          addr === "ws/s1" ? (s1HasFeatures ? { features: ["projects"] } : {}) : { features: ["projects"] },
      },
      views: t2.views,
      store: { get: () => undefined, inUse: () => false },
      host: t2.host,
      router: { owners: [] },
      workspaces: { owner: () => "u1" },
      accounts: { list: () => [{ sub: "u1", email: "u1@x.com" }] },
      scheduler: { enqueue: () => {} },
      presets: { changed: () => {} },
      stations: {
        also: [] as any[],
        link: (a: string) => ({ addr: { toString: () => a } }),
        reachable: (a: string) => (a === "ws/s1" ? s1Reachable : true),
        requests: {
          call: (addr: { toString(): string }, method: string, path: string) => {
            const a = addr.toString();
            called.push(`${method} ${a} ${path}`);
            if (method === "GET" && path === "/preset-projects") {
              // Demote to viewer between GET and PUT
              wsRole = "viewer";
              return Effect.succeed({ presetProjects: { p1: { project: "serverOld", rev: 1, at: 100 } } });
            }
            if (method === "PUT" && path === "/projects/info" && a === "ws/s1") {
              // Turn s2 into rig before retry!
              s2Mode = "rig";
              return Effect.fail(new CoreError("http_404", "no route", 404));
            }
            return Effect.succeed({ ok: true });
          },
        },
      },
    } as any;

    installProjects(fakeInner);
    installPresets(fakeInner);

    // (a) Explicit station with unknown capabilities must fail
    s1HasFeatures = false;
    const unknownRes = await Effect.runPromise(
      Effect.result(handlers.projects!(fakeInner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", station: "ws/s1", name: "monoid", note: "hi" } } as any, (() => {}) as any, ["c", 1] as any, null as any)),
    );
    assert.equal(unknownRes._tag, "Failure", "explicit station with unknown features must be rejected");
    s1HasFeatures = true;

    // (b) Retry loop re-checks eligibility: s1 404s and s2 turned rig -> s2 must NOT be called
    called.length = 0;
    const retryRes = await Effect.runPromise(
      Effect.result(handlers.projects!(fakeInner, { kind: "projects", name: "updateInfo", scope: "ws", params: { scope: "ws", name: "monoid", note: "hi" } } as any, (() => {}) as any, ["c", 2] as any, null as any)),
    );
    assert.equal(retryRes._tag, "Failure");
    assert.equal(called.some((c) => c.includes("ws/s2")), false, "s2 turned rig before retry must not be called");

    // (c) carryPresetProjects: demoted to viewer after GET -> must NOT send PUT and must roll back local key
    s2Mode = "full";
    called.length = 0;
    await Effect.runPromise(carryPresetProjects(fakeInner, "ws/s1"));
    assert.equal(called.some((c) => c.startsWith("PUT ")), false, "demoted viewer must not send PUT /preset-projects");
    assert.equal((t2.data.record("choice", presetProjectsKey("ws")) as any)?.p1?.project, "serverOld", "demoted viewer local key rolled back");

    // (d) preset.setProject fails when only eligible beta station goes offline
    wsRole = "member";
    s1Reachable = false;
    s2Mode = "rig";
    const setOffRes = await Effect.runPromise(
      Effect.result(handlers.presets!(fakeInner, { kind: "presets", name: "setProject", scope: "ws", params: { scope: "ws", presetId: "p1", project: "monoid" } } as any, (() => {}) as any, ["c", 3] as any, null as any)),
    );
    assert.equal(setOffRes._tag, "Failure", "setProject must fail when no eligible online full station exists");
  } finally {
    t2.store.runner.shutdown();
  }
});

test("R3 status counts parity: mine=false failed chat matches across groupSummary, groupSummaryTag, overlay rowGroupFlags, and projectSummary", async () => {
  const t = setup();
  t.router.all = true;
  try {
    t.set(workspace(), { id: "ws", name: "Parity", stations: [{ id: "s1", name: "S1", online: true }] });
    t.set(overview("ws/s1"), { connects: [], profiles: [], features: ["projects"] });
    t.set({ topic: "chatRows", station: "ws/s1" }, [
      {
        id: "c-fail-other",
        session: "c-fail-other",
        thread: 101,
        title: "Colleague failed",
        lastActiveAt: 5000,
        mine: false,
        unread: false,
        project: "monoid",
        tags: ["ops"],
        agents: [{ key: "c-fail-other", runtime: "claude", process: "cold", lastTurn: { endedAt: 5000, outcome: "failed" } }],
      },
      {
        id: "c-run",
        session: "c-run",
        thread: 102,
        title: "Running chat",
        lastActiveAt: 4000,
        mine: true,
        unread: false,
        project: "monoid",
        tags: ["ops"],
        agents: [{ key: "c-run", runtime: "claude", process: "running" }],
      },
      {
        id: "c-unread",
        session: "c-unread",
        thread: 103,
        title: "Unread chat",
        lastActiveAt: 3000,
        mine: true,
        unread: true,
        project: "monoid",
        tags: ["ops"],
        agents: [{ key: "c-unread", runtime: "claude", process: "cold" }],
      },
    ]);

    // 1. Grouped chats SQL (`groupSummary`)
    const u1 = ui();
    t.subscribe(991, { topic: "chats", scope: "ws", filter: "all", groupBy: "project" });
    await t.read(u1, 991);
    const g1 = u1.value.groups.find((g: any) => g.key === "project:monoid");
    assert.equal(g1.runningCount, 1);
    assert.equal(g1.alertCount, 1, "mine=false failed chat must count in groupSummary.alertCount");
    assert.equal(g1.unreadCount, 1);

    // 2. Grouped + tag SQL (`groupSummaryTag`)
    const u2 = ui();
    t.subscribe(992, { topic: "chats", scope: "ws", filter: "all", groupBy: "project", tag: "ops" });
    await t.read(u2, 992);
    const g2 = u2.value.groups.find((g: any) => g.key === "project:monoid");
    assert.equal(g2.runningCount, 1);
    assert.equal(g2.alertCount, 1, "mine=false failed chat must count in groupSummaryTag.alertCount");
    assert.equal(g2.unreadCount, 1);

    // 3. Settings `projects` topic (`projectSummary`)
    const u3 = ui();
    t.subscribe(993, { topic: "projects", scope: "ws" });
    await t.read(u3, 993);
    const p3 = u3.value.items.find((p: any) => p.name === "monoid");
    assert.equal(p3.runningCount, 1);
    assert.equal(p3.alertCount, 1, "mine=false failed chat must count in projects.alertCount");
    assert.equal(p3.unreadCount, 1);

    // 4. Local overlay on `c-fail-other` (pin toggle) -> `rowGroupFlags` must match SQL counts identically!
    t.views.local.changing("ws/s1", 101, "c-fail-other", { pinned: 99_999 }, null);
    await t.read(u1, 991);
    const g1Overlay = u1.value.groups.find((g: any) => g.key === "project:monoid");
    assert.equal(g1Overlay.runningCount, 1);
    assert.equal(g1Overlay.alertCount, 1, "overlaid mine=false failed chat must keep identical alertCount");
    assert.equal(g1Overlay.unreadCount, 1);
  } finally {
    t.store.runner.shutdown();
  }
});

test("R4 Astra P1-2: colleague-assigned pending card keeps askingCount 1->1->1 before/during/after pin overlay for both assignee and colleague", async () => {
  for (const viewerEmail of ["alice@x.com", "bob@x.com"]) {
    const t = setup();
    t.router.all = true;
    try {
      t.set(workspace(), {
        id: "ws",
        name: "CardParity",
        stations: [{ id: "s1", name: "S1", online: true }],
        members: [
          { sub: "u-alice", email: "alice@x.com", name: "Alice" },
          { sub: "u-bob", email: "bob@x.com", name: "Bob" },
        ],
      });
      t.set(overview("ws/s1"), {
        viewer: { email: viewerEmail },
        connects: [],
        profiles: [],
        features: ["projects"],
      });
      t.set({ topic: "chatRows", station: "ws/s1" }, [
        {
          id: "c-card",
          session: "c-card",
          thread: 201,
          title: "Card assigned to Alice",
          lastActiveAt: 5000,
          mine: viewerEmail === "alice@x.com",
          unread: false,
          project: "monoid",
          tags: ["ops"],
          agents: [{ key: "c-card", runtime: "claude", process: "cold" }],
          card: {
            seq: 5,
            card: { type: "options", assignee: "alice@x.com", options: [{ label: "Yes" }] },
            message: { text: "Approve?" },
          },
        },
      ]);
      const u = ui();
      t.subscribe(995, { topic: "chats", scope: "ws", filter: "all", groupBy: "project" });
      await t.read(u, 995);
      const before = u.value.groups.find((g: any) => g.key === "project:monoid");
      assert.equal(before.askingCount, 1, `[${viewerEmail}] SQL askingCount before overlay must be 1`);

      // Pin overlay -> row moves to `win.apart`, counted by `addRowToGroupTotals` (`rowGroupFlags`)
      const changeId = t.views.local.changing("ws/s1", 201, "c-card", { pinned: 99_999 }, null);
      await t.read(u, 995);
      const during = u.value.groups.find((g: any) => g.key === "project:monoid");
      assert.equal(during.askingCount, 1, `[${viewerEmail}] overlay askingCount must stay 1 (no 1->0->1 flicker)`);

      // Release overlay -> back to SQL
      t.views.local.changed(changeId, false, 0);
      await t.read(u, 995);
      const after = u.value.groups.find((g: any) => g.key === "project:monoid");
      assert.equal(after.askingCount, 1, `[${viewerEmail}] post-overlay askingCount must remain 1`);
    } finally {
      t.store.runner.shutdown();
    }
  }
});
