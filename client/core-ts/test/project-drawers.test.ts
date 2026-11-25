// Project/folder drawers in the core: device prefs (`chatDrawers`, `drawerCollapsed`), `project` on listed & whole
// chat rows, `chat.classify` optimistic overlay & rollback, `projects` workspace view (multi-station metadata, SSE
// refresh, 404 fallback), `project.setInfo`, and `newChat.create` carrying an optional `project`.
import assert from "node:assert/strict";
import { test } from "node:test";
import { answers, apply, call, readsOf, subscribe, v } from "./helpers.ts";
import { base, overview, started, status, stationReplies } from "./station-fixture.ts";

const S = "ws/st";
const profile = {
  id: "p1", name: "p1@x.com", runtime: "claude", runtimes: ["claude"], access: { kind: "subscription", key: "" }, home: "/h", homeExists: true, model: null, models: ["claude-opus-5-5"],
  env: [], usedBy: [], loginCommand: "", check: { state: "ok", detail: "", checkedAt: 1 }, quota: { state: "ok", windows: [], detail: null, checkedAt: 1 },
};

function sampleChat(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const session = typeof overrides.session === "string" ? overrides.session : "chat:c-10";
  const thread = typeof overrides.thread === "number" ? overrides.thread : 10;
  const title = typeof overrides.title === "string" ? overrides.title : "Implement feature";
  return {
    id: session,
    session,
    thread,
    title,
    lastActiveAt: 1_700_000_000_000,
    unread: false,
    mine: false,
    connect: null,
    origin: null,
    creator: null,
    people: [],
    ws: null,
    named: { thread: { surface: "ember", title }, firstText: null, channelName: null },
    mineOf: [{ id: "a@x.com", name: "A", email: "a@x.com", via: "cloud" }],
    said: null,
    pinned: null,
    last: null,
    agents: [{ key: session, connect: null, profile: "p1", runtime: "claude", model: "claude-opus-5-5", effort: null, process: "cold", pending: 0, lastTurn: null }],
    ...overrides,
  };
}

test("chatDrawers_and_drawerCollapsed_prefs_validate_persist_and_clear", async () => {
  const { host, core } = await started(base() as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "prefs" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 1).chatDrawers, undefined);
  assert.deepEqual(v(values, 1).drawerCollapsed, {});

  // Valid toggle on + per-workspace collapsed drawer keys.
  call(core, ui, 2, "prefs.set", { chatDrawers: "on", drawerCollapsed: { ws: JSON.stringify(["p:monoid", "unclassified"]) } });
  await host.settle();
  const emitted = host.takeEmitted();
  assert.ok((answers(emitted, 2) as { ok?: unknown })?.ok !== undefined, `prefs.set ok: ${JSON.stringify(answers(emitted, 2))}`);
  for (const [, m] of emitted) {
    const msg = m as Record<string, unknown>;
    if (msg.id === 1 && "value" in msg) values.set(1, msg.value);
  }
  subscribe(core, ui, 3, { topic: "prefs" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 3).chatDrawers, "on");
  assert.deepEqual(v(values, 3).drawerCollapsed, { ws: JSON.stringify(["p:monoid", "unclassified"]) });

  // Invalid value rejected cleanly.
  call(core, ui, 4, "prefs.set", { chatDrawers: "maybe" });
  await host.settle();
  const bad = answers(host.takeEmitted(), 4) as { error?: unknown } | undefined;
  assert.ok(bad?.error, `expected invalid chatDrawers to be rejected, got ${JSON.stringify(bad)}`);

  // Clear toggle and workspace map entry.
  call(core, ui, 5, "prefs.set", { chatDrawers: null, drawerCollapsed: { ws: null } });
  await host.settle();
  subscribe(core, ui, 6, { topic: "prefs" });
  await host.settle();
  apply(host, values);
  assert.equal(v(values, 6).chatDrawers, undefined);
  assert.deepEqual(v(values, 6).drawerCollapsed, {});
  core.close();
});

test("chats_and_chatRow_carry_project_and_chat_classify_applies_optimistically_and_rolls_back_on_error", async () => {
  const rows = [
    sampleChat({ session: "chat:c-10", thread: 10, title: "Named project chat", project: "monoid", projectLocked: true }),
    sampleChat({ session: "chat:c-11", thread: 11, title: "Cross project chat", project: "", projectLocked: true }),
    sampleChat({ session: "chat:c-12", thread: 12, title: "Unclassified chat", project: null, projectLocked: false }),
  ];
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, features: ["projects"] },
    "GET /chats?shared=1": rows,
    "GET /projects/info": { projects: { monoid: { note: "Main repo", refs: ["studio:~/code/monoid"] } } },
  };
  let failNextClassify = false;
  const { host, core } = await started(said as never);
  stationReplies(host, (req) => {
    if (req.method === "PUT" && req.url.endsWith("/admin/api/threads/12/classification")) {
      if (failNextClassify) {
        failNextClassify = false;
        return status(500, { error: "disk full" });
      }
      const body = JSON.parse(new TextDecoder().decode(req.body ?? new Uint8Array())) as { project?: string | null };
      rows[2] = { ...rows[2]!, project: body.project ?? null, projectLocked: true };
      said["GET /chats?shared=1"] = [...rows];
      return { ok: true, project: body.project ?? null, projectLocked: true };
    }
    return undefined;
  });

  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "chats", scope: "ws", mine: false });
  subscribe(core, ui, 2, { topic: "chatRow", station: S, session: "chat:c-10" });
  subscribe(core, ui, 3, { topic: "projects", scope: "ws" });
  await host.settle();
  apply(host, values);

  const flat = () => (v(values, 1).days as { items: Record<string, unknown>[] }[]).flatMap((d) => d.items);
  const byId = (session: string) => flat().find((r) => r.session === session);
  assert.equal(byId("chat:c-10")?.project, "monoid");
  assert.equal(byId("chat:c-10")?.projectLocked, undefined, "projectLocked stays whole-row only");
  assert.equal(byId("chat:c-11")?.project, "", "empty string distinguishes cross-project from unclassified");
  assert.equal(byId("chat:c-12")?.project, undefined, "null project omitted on listed row");
  assert.equal(v(values, 2).project, "monoid");
  assert.equal(v(values, 2).projectLocked, true);

  // Classify chat:c-12 into a new project: wire body matches station route, row updates, projectsInfo refreshes.
  const infoReadsBefore = host.requests.flatMap(readsOf).filter((u) => u.endsWith("/admin/api/projects/info")).length;
  said["GET /projects/info"] = {
    projects: {
      monoid: { note: "Main repo", refs: ["studio:~/code/monoid"] },
      web: { note: "Web client", refs: ["studio:~/code/web"] },
    },
  };
  call(core, ui, 10, "chat.classify", { station: S, thread: 12, project: "web" });
  await host.settle();
  apply(host, values);
  const putReq = host.requests.find((r) => r.method === "PUT" && r.url.endsWith("/admin/api/threads/12/classification"));
  assert.ok(putReq);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(putReq.body!)), { project: "web" });
  assert.equal(byId("chat:c-12")?.project, "web");
  const infoReadsAfter = host.requests.flatMap(readsOf).filter((u) => u.endsWith("/admin/api/projects/info")).length;
  assert.ok(infoReadsAfter > infoReadsBefore, "classifying into a named project refreshes projectsInfo");
  assert.deepEqual(v(values, 3).projects.map((p: { name: string }) => p.name), ["monoid", "web"]);

  // Clear project classification with clearProject: true.
  call(core, ui, 11, "chat.classify", { station: S, thread: 12, clearProject: true });
  await host.settle();
  apply(host, values);
  assert.equal(byId("chat:c-12")?.project, undefined);

  // Failed classify rolls back optimistic change.
  failNextClassify = true;
  call(core, ui, 12, "chat.classify", { station: S, thread: 12, project: "broken" });
  await host.settle();
  apply(host, values);
  assert.equal(byId("chat:c-12")?.project, undefined, "optimistic project rolled back when station rejects");
  core.close();
});

test("projects_topic_is_lazy_handles_sse_and_setInfo_and_degrades_on_404_stations", async () => {
  // Older station (404 on GET /projects/info): topic answers { projects: [], supported: false }.
  const oldSaid: Record<string, unknown> = {
    ...base(),
    "GET /projects/info": status(404, { error: "not found" }),
  };
  const oldStation = await started(oldSaid as never);
  const oldUi = oldStation.core.connect();
  const oldValues = new Map<number, unknown>();
  subscribe(oldStation.core, oldUi, 1, { topic: "projects", scope: "ws" });
  await oldStation.host.settle();
  apply(oldStation.host, oldValues);
  assert.deepEqual(v(oldValues, 1), { projects: [], supported: false });
  oldStation.core.close();

  // Modern station: lazy until subscribed, updates on SSE "projects" and on project.setInfo.
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, features: ["projects"] },
    "GET /projects/info": { projects: { alpha: { note: "First", refs: ["studio:~/code/alpha"] } } },
    "PUT /projects/info": { ok: true, projects: { alpha: { note: "Updated", refs: ["studio:~/code/alpha", "https://github.com/acme/alpha"] } } },
  };
  const { host, core, push } = await started(said as never);
  const reads = () => host.requests.flatMap(readsOf).filter((u) => u.endsWith("/admin/api/projects/info")).length;
  assert.equal(reads(), 0, "projectsInfo is not fetched until projects topic is subscribed");

  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "projects", scope: "ws" });
  await host.settle();
  apply(host, values);
  assert.equal(reads(), 1);
  assert.deepEqual(v(values, 1), {
    supported: true,
    projects: [{ name: "alpha", note: "First", refs: ["studio:~/code/alpha"] }],
  });

  // project.setInfo writes PUT /projects/info and refreshes the topic.
  said["GET /projects/info"] = { projects: { alpha: { note: "Updated", refs: ["studio:~/code/alpha", "https://github.com/acme/alpha"] } } };
  call(core, ui, 2, "project.setInfo", { station: S, name: "alpha", note: "Updated", refs: ["studio:~/code/alpha", "https://github.com/acme/alpha"] });
  await host.settle();
  apply(host, values);
  const putInfo = host.requests.find((r) => r.method === "PUT" && r.url.endsWith("/admin/api/projects/info"));
  assert.ok(putInfo);
  assert.deepEqual(JSON.parse(new TextDecoder().decode(putInfo.body!)), {
    name: "alpha",
    note: "Updated",
    refs: ["studio:~/code/alpha", "https://github.com/acme/alpha"],
  });
  assert.equal(reads(), 2);
  assert.deepEqual(v(values, 1).projects, [{ name: "alpha", note: "Updated", refs: ["studio:~/code/alpha", "https://github.com/acme/alpha"] }]);

  // SSE "projects" event refreshes projectsInfo immediately.
  said["GET /projects/info"] = {
    projects: {
      alpha: { note: "Updated", refs: ["studio:~/code/alpha"] },
      beta: { note: "Second" },
    },
  };
  push("projects", { workspace: "ws" });
  await host.settle();
  apply(host, values);
  assert.equal(reads(), 3);
  assert.deepEqual(v(values, 1).projects.map((p: { name: string }) => p.name), ["alpha", "beta"]);
  core.close();
});

test("newChat_create_forwards_optional_project_to_station_and_pending_row", async () => {
  const said: Record<string, unknown> = {
    ...base(),
    "GET /overview": { ...overview, profiles: [profile], features: ["projects"] },
    "POST /sessions": { key: "chat:c-new", thread: { id: 99, threadTs: "99.0" } },
  };
  const { host, core } = await started(said as never);
  const ui = core.connect();
  const values = new Map<number, unknown>();
  subscribe(core, ui, 1, { topic: "newChat", scope: "ws" });
  subscribe(core, ui, 2, { topic: "chats", scope: "ws", mine: false });
  await host.settle();
  apply(host, values);

  call(core, ui, 3, "newChat.create", { station: S, key: v(values, 1).next, project: "monoid" });
  await host.settle();
  apply(host, values);
  const postSession = host.requests.find((r) => r.method === "POST" && r.url.endsWith("/admin/api/sessions"));
  assert.ok(postSession);
  const body = JSON.parse(new TextDecoder().decode(postSession.body!)) as { project?: string };
  assert.equal(body.project, "monoid");
  const flat = (v(values, 2).days as { items: Record<string, unknown>[] }[]).flatMap((d) => d.items);
  assert.equal(flat.find((r) => r.session === "chat:c-new" || r.clientKey === v(values, 1).next)?.project, "monoid");
  core.close();
});
