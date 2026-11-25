import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Store } from "../src/store/store.ts";
import { routes as presetProjectRoutes } from "../src/api/routes/preset-projects.ts";
import { routes as projectRoutes } from "../src/api/routes/projects.ts";
import type { Request } from "../src/api/request.ts";
import { newSession } from "../src/sessions/lifecycle.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { readProjectsInfoStrict } from "../src/projects/info.ts";
import { Rig } from "./hub-fakes.ts";

const withModels = (r: Rig) => {
  r.raw.profiles = [
    { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6", "claude-sonnet-4-6"] },
  ];
  r.config = hubConfig(r.raw, r.dir);
  return r;
};

function makeReq(method: string, path: string, body: unknown, viewer?: Partial<Request["viewer"]>): Request {
  const raw = body === undefined ? Buffer.alloc(0) : Buffer.from(typeof body === "string" ? body : JSON.stringify(body), "utf8");
  return {
    method,
    path,
    query: new URLSearchParams(),
    body: raw,
    viewer: {
      sub: "u1",
      email: "a@example.com",
      name: "Alice",
      role: "member",
      workspace: "ws-1",
      device: "d1",
      home: true,
      ...viewer,
    },
    lang: "en",
  } as unknown as Request;
}

async function dispatch(routes: ReturnType<typeof presetProjectRoutes>, req: Request) {
  for (const r of routes) {
    if (r.method !== req.method) continue;
    const m = r.pattern.exec(req.path);
    if (m) return r.handle(req, m.slice(1));
  }
  throw new Error(`no route for ${req.method} ${req.path}`);
}

test("GET and PUT /preset-projects validate, merge, persist, and notify only on change", async () => {
  const dir = mkdtempSync(join(tmpdir(), "preset-proj-route-"));
  try {
    const store = Store.open(join(dir, "stillfail.db"));
    const told: [string, string][] = [];
    const routes = presetProjectRoutes({
      kept: store,
      told: (ws, sub) => told.push([ws, sub]),
    });

    // Missing sub -> 403
    const noSub = await dispatch(routes, makeReq("GET", "/preset-projects", undefined, { sub: "" }));
    assert.equal(noSub.status, 403);

    // Initial GET -> {}
    const g0 = await dispatch(routes, makeReq("GET", "/preset-projects", undefined));
    assert.equal(g0.status, 200);
    assert.deepEqual(JSON.parse(g0.body.toString("utf8")), { presetProjects: {} });

    // Invalid project (>80 chars) -> 400; 80 chars -> 200
    const bad = await dispatch(
      routes,
      makeReq("PUT", "/preset-projects", { presetProjects: { "p-1": { project: "x".repeat(81), rev: 1, at: 100 } } }),
    );
    assert.equal(bad.status, 400);
    const ok80 = await dispatch(
      routes,
      makeReq("PUT", "/preset-projects", { presetProjects: { "p-80": { project: "x".repeat(80), rev: 1, at: 100 } } }),
    );
    assert.equal(ok80.status, 200);
    // Clean p-80 back out by using fresh store below or verify p-1/p-2 merge cleanly
    told.length = 0;

    // Valid PUT -> persists and notifies
    const p1 = await dispatch(
      routes,
      makeReq("PUT", "/preset-projects", {
        presetProjects: {
          "p-1": { project: "monoid", rev: 1, at: 100 },
          "p-2": { project: "", rev: 1, at: 100 },
        },
      }),
    );
    assert.equal(p1.status, 200);
    const p1Map = JSON.parse(p1.body.toString("utf8")).presetProjects;
    assert.deepEqual(p1Map["p-1"], { project: "monoid", rev: 1, at: 100 });
    assert.deepEqual(p1Map["p-2"], { project: "", rev: 1, at: 100 });
    assert.deepEqual(told, [["ws-1", "u1"]]);

    // Same PUT again -> no duplicate notify
    const p2 = await dispatch(
      routes,
      makeReq("PUT", "/preset-projects", {
        presetProjects: { "p-1": { project: "monoid", rev: 1, at: 100 } },
      }),
    );
    assert.equal(p2.status, 200);
    assert.equal(told.length, 1);

    // Resetting p-1 to null with rev 2 wins and retains key
    const p3 = await dispatch(
      routes,
      makeReq("PUT", "/preset-projects", {
        presetProjects: { "p-1": { project: null, rev: 2, at: 200 } },
      }),
    );
    assert.equal(p3.status, 200);
    assert.deepEqual(JSON.parse(p3.body.toString("utf8")).presetProjects["p-1"], { project: null, rev: 2, at: 200 });
    assert.equal(told.length, 2);

    // Oversized body (> 256 KiB) -> 413
    const huge = await dispatch(routes, makeReq("PUT", "/preset-projects", " ".repeat(256 * 1024 + 10)));
    assert.equal(huge.status, 413);

    store.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("newSession applies carried preset_projects preference when projects feature is on", async () => {
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const sub = "u-alice";
    const preset = await f.hub.presets.add(ws, { name: "Monoid Dev", dirs: [], instructions: "" }, "alice@example.com", sub);
    const presetCross = await f.hub.presets.add(ws, { name: "General", dirs: [], instructions: "" }, "alice@example.com", sub);
    const presetAuto = await f.hub.presets.add(ws, { name: "Auto", dirs: [], instructions: "" }, "alice@example.com", sub);

    f.hub.store.putPresetProjects(
      ws,
      sub,
      JSON.stringify({
        [preset.id]: { project: "monoid", rev: 1, at: 100 },
        [presetCross.id]: { project: "", rev: 1, at: 100 },
        [presetAuto.id]: { project: null, rev: 1, at: 100 },
      }),
    );

    // 1. Named project preference -> applied unlocked
    const [, t1] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: sub,
      ws,
      preset: preset.id,
    });
    assert.equal(t1.project, "monoid");
    assert.ok(!t1.projectLocked);

    // 2. Explicit cross-project ("") preference -> applied unlocked
    const [, t2] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: sub,
      ws,
      preset: presetCross.id,
    });
    assert.equal(t2.project, "");
    assert.ok(!t2.projectLocked);

    // 3. null (auto) preference -> stays undefined/null for agent
    const [, t3] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: sub,
      ws,
      preset: presetAuto.id,
    });
    assert.equal(t3.project, undefined);

    // 4. Explicit caller override wins over preset preference
    const [, t4] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: sub,
      ws,
      preset: preset.id,
      project: "invar",
    });
    assert.equal(t4.project, "invar");
    assert.ok(!t4.projectLocked);
  } finally {
    await f.close();
  }
});

test("POST /projects/rename and /projects/merge update local threads and PROJECTS.jsonl", async () => {
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const [, t1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "alpha" });
    const [, t2] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "beta" });

    const routes = projectRoutes({
      store: f.hub.store,
      agents: { hub: f.hub } as any,
      data: f.dir,
    } as any);

    // Rename alpha -> gamma
    const r1 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "alpha", to: "gamma" }, { workspace: ws }));
    assert.equal(r1.status, 200);
    const body1 = JSON.parse(r1.body.toString("utf8"));
    assert.equal(body1.action, "rename");
    assert.equal(body1.local.updated, 1);
    assert.equal(f.hub.store.getThread(t1.id)?.project, "gamma");
    const info1 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("gamma" in info1.projects);

    // Merge beta -> gamma
    const r2 = await dispatch(routes, makeReq("POST", "/projects/merge", { from: "beta", to: "gamma" }, { workspace: ws }));
    assert.equal(r2.status, 200);
    const body2 = JSON.parse(r2.body.toString("utf8"));
    assert.equal(body2.action, "merge");
    assert.equal(body2.local.updated, 1);
    assert.equal(f.hub.store.getThread(t2.id)?.project, "gamma");

    // Unknown source -> 404
    const r404 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ghost", to: "newname" }, { workspace: ws }));
    assert.equal(r404.status, 404);

    // Rename to already-existing project -> 409 conflict
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "delta" });
    const r409 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "delta", to: "gamma" }, { workspace: ws }));
    assert.equal(r409.status, 409);

    // Rename rewrites carried preset_projects pointing to `from` -> `to` with rev++
    // and subsequent GET /preset-projects must immediately reflect the rename (no stale in-memory cache).
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const putPP = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { p1: { project: "delta", rev: 1, at: 10 } } }, { workspace: ws, sub: "u-alice" }),
    );
    assert.equal(putPP.status, 200);
    const getBefore = await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-alice" }));
    assert.equal(JSON.parse(getBefore.body.toString("utf8")).presetProjects.p1.project, "delta");

    const rRen = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "delta", to: "epsilon" }, { workspace: ws }));
    assert.equal(rRen.status, 200);
    const updatedPP = JSON.parse(f.hub.store.presetProjects(ws, "u-alice")!);
    assert.equal(updatedPP.p1.project, "epsilon");
    assert.equal(updatedPP.p1.rev, 1);
    assert.equal(updatedPP.p1.at, 10);
    assert.ok(updatedPP.p1.ren > 10);

    const getAfter = await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-alice" }));
    assert.equal(getAfter.status, 200);
    const afterMap = JSON.parse(getAfter.body.toString("utf8")).presetProjects;
    assert.equal(afterMap.p1.project, "epsilon", "GET /preset-projects must not serve stale cached value after rename");
    assert.equal(afterMap.p1.rev, 1);
  } finally {
    await f.close();
  }
});

test("newSession rejects invalid project before creating orphan session or polluting clientKey", async () => {
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    await assert.rejects(
      () => newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws: "ws-1", clientKey: "ck-bad", project: "bad,comma" }),
      /comma|invalid/i,
    );
    assert.equal(f.hub.store.listSessions().length, 0, "no orphan session created");
    assert.equal(f.hub.clientKeysMade.size, 0, "clientKey cache not polluted");
  } finally {
    await f.close();
  }
});

test("POST /projects/rename returns 403 when projects feature is disabled", async () => {
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => false }));
  try {
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const res = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "a", to: "b" }, { workspace: "ws-1" }));
    assert.equal(res.status, 403);
  } finally {
    await f.close();
  }
});

test("R3 Node Station regressions: project named 'disabled' -> 404 (not 403), peer rename migrates preset_projects, partial peer failure sets noCache, clientKey retry fills initialProject", async () => {
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);

    // 1. Project literally named "disabled" is unknown -> 404, never misclassified as 403!
    const rDisabled = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "disabled", to: "other" }, { workspace: ws }));
    assert.equal(rDisabled.status, 404, "unknown project named 'disabled' must return 404, not 403");

    // 2. Peer `thread.classify` rename also migrates peer's local `preset_projects` with rev++
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "oldPeer" });
    f.hub.store.putPresetProjects(ws, "u-peer", JSON.stringify({ p1: { project: "oldPeer", rev: 3, at: 50 } }));
    await classifyForPeer(f.hub, { rename: { from: "oldPeer", to: "newPeer" } }, ws);
    const peerPP = JSON.parse(f.hub.store.presetProjects(ws, "u-peer")!);
    assert.equal(peerPP.p1.project, "newPeer", "peer rename must rewrite peer preset_projects");
    assert.equal(peerPP.p1.rev, 3);
    assert.equal(peerPP.p1.at, 50);
    assert.ok(peerPP.p1.ren > 50);

    // 3. Strictly idempotent clientKey retry: unclassified thread stays unclassified even if preference is added later!
    const presetLate = await f.hub.presets.add(ws, { name: "LatePref", dirs: [] }, "alice@example.com", "u-alice");
    const [k1, t1] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: "u-alice",
      ws,
      preset: presetLate.id,
      clientKey: "ck-retry-idem",
    });
    assert.equal(t1.project, undefined);
    // Later user sets a default project on that preset
    f.hub.store.putPresetProjects(ws, "u-alice", JSON.stringify({ [presetLate.id]: { project: "after", rev: 1, at: 100 } }));
    // Retry with same clientKey must NOT rewrite the already-created unclassified thread
    const [k2, t2] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "alice@example.com",
      createdBySub: "u-alice",
      ws,
      preset: presetLate.id,
      clientKey: "ck-retry-idem",
    });
    assert.equal(k2, k1);
    assert.equal(t2.project, undefined, "idempotent clientKey retry must preserve original unclassified state");
  } finally {
    await f.close();
  }
});

test("R4 Node Station regressions: shared preset callerSub (Bob), offline peer 503, partial rename retry continuation + 409 for other->to, late device rename migration", async () => {
  const { chatCreate } = await import("../src/sessions/opened.ts");
  const { renameOrMergeProject } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";

    // 1. Item 6: Alice creates shared preset P; Bob sets P -> "BobProject"; Bob's parent session calls chat_create(preset: P) -> child gets "BobProject"
    const sharedPreset = await f.hub.presets.add(ws, { name: "SharedPreset", dirs: [] }, "alice@example.com", "u-alice");
    f.hub.store.putPresetProjects(ws, "u-alice", JSON.stringify({ [sharedPreset.id]: { project: "AlicePrivate", rev: 1, at: 10 } }));
    f.hub.store.putPresetProjects(ws, "u-bob", JSON.stringify({ [sharedPreset.id]: { project: "BobProject", rev: 1, at: 10 } }));
    const [bobParentKey] = await newSession(f.hub, {
      runtime: "claude",
      model: "claude-opus-4-6",
      createdBy: "bob@example.com",
      createdBySub: "u-bob",
      ws,
    });
    (f.hub as any).deliver = () => {};
    await chatCreate(f.hub, bobParentKey, {
      key: "bob-child",
      for: "person",
      preset: sharedPreset.id,
      text: "hello from bob",
    });
    const openedRec = f.hub.store.openedWith("", bobParentKey, "bob-child", "");
    assert.ok(openedRec, "opened record must exist for bob-child");
    const childThread = f.hub.store.homeChat(openedRec.child);
    assert.equal(childThread?.project, "BobProject", "shared preset must use caller Bob's preset_projects, never Alice's");

    // 2. Item 8a & 8b: Offline peer blocks rename with 503 (local untouched); partial peer failure returns 200+noCache and retry continues; other->to still 409
    const [, tSrc] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "srcProj" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "otherProj" });

    let peerOnline = false;
    let peerFailRename = true;
    const peerCalls: any[] = [];
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") {
        return { stations: [{ id: "peer-1", name: "Peer 1", online: peerOnline }] };
      }
      peerCalls.push({ station, req });
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify" && req.rename) {
        if (peerFailRename) throw new Error("peer-1 transient failure");
        return { updated: 2, skippedLocked: 0 };
      }
      return {};
    };

    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);

    // 8a. Peer offline -> 503 and local DB untouched
    const r503 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "srcProj", to: "dstProj" }, { workspace: ws }));
    assert.equal(r503.status, 503, "offline peer must block rename with 503");
    assert.equal(f.hub.store.getThread(tSrc.id)?.project, "srcProj", "local thread must remain untouched on 503");

    // 8b. Peer online but rename fails -> 200 with noCache: true; peer recovers -> retry same srcProj->dstProj succeeds (200) and updates peer; otherProj->dstProj still 409!
    peerOnline = true;
    peerFailRename = true;
    const rPartial = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "srcProj", to: "dstProj" }, { workspace: ws }));
    assert.equal(rPartial.status, 200);
    assert.equal(rPartial.noCache, true, "partial peer failure must set noCache: true");
    assert.equal(f.hub.store.getThread(tSrc.id)?.project, "dstProj");

    peerFailRename = false;
    const rRetry = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "srcProj", to: "dstProj" }, { workspace: ws }));
    assert.equal(rRetry.status, 200, "retrying same (from, to) after partial failure must continue cleanly");
    const retryBody = JSON.parse(rRetry.body.toString("utf8"));
    assert.equal(retryBody.peers[0]?.status, "ok");
    assert.equal(retryBody.peers[0]?.updated, 2);

    const rConflict = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "otherProj", to: "dstProj" }, { workspace: ws }));
    assert.equal(rConflict.status, 409, "independent rename to existing dstProj must still return 409");

    // 3. Item 8c: Late-arriving offline device PUT /preset-projects with at < renamed_at migrates to dstProj; at >= renamed_at preserves original
    const renameRow = f.hub.store.listProjectRenameEvents(ws).find((e) => e.from === "srcProj");
    assert.ok(renameRow, "project_rename_events row must be recorded");
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });

    const lateOld = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", {
        presetProjects: { "p-old": { project: "srcProj", rev: 1, at: renameRow.renamedAt - 100 } },
      }, { workspace: ws, sub: "u-late" }),
    );
    assert.equal(lateOld.status, 200);
    const lateOldMap = JSON.parse(lateOld.body.toString("utf8")).presetProjects;
    assert.equal(lateOldMap["p-old"].project, "dstProj", "late PUT with at < renamedAt must auto-migrate to dstProj");
    assert.equal(lateOldMap["p-old"].rev, 1);
    assert.equal(lateOldMap["p-old"].at, renameRow.renamedAt - 100);
    assert.equal(lateOldMap["p-old"].ren, renameRow.renamedAt);

    const lateNew = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", {
        presetProjects: { "p-new": { project: "srcProj", rev: 1, at: renameRow.renamedAt + 100 } },
      }, { workspace: ws, sub: "u-late" }),
    );
    assert.equal(lateNew.status, 200);
    const lateNewMap = JSON.parse(lateNew.body.toString("utf8")).presetProjects;
    assert.equal(lateNewMap["p-new"].project, "srcProj", "PUT with at >= renamedAt must preserve user's newer choice");

    // Keep renameOrMergeProject referenced cleanly
    assert.equal(typeof renameOrMergeProject, "function");
  } finally {
    await f.close();
  }
});

test("R5 Node Station regressions: offline peer classify 404 vs rename 503, #tx openChatAtomic rollback, rename events/lock/18-hop/completed-no-replay, and legacy created_by_sub recovery", async () => {
  const { chatCreate } = await import("../src/sessions/opened.ts");
  const { classifyChat, renameOrMergeProject } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });

    // 1. Item 1: Offline peer -> classifyChat on unknown project returns 404 with propose hint (NOT 503), while rename returns 503
    const [kCls] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "knownA" });
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-off", name: "Off", online: false }] };
      return {};
    };
    await assert.rejects(
      () => classifyChat(f.hub, kCls, "self", { project: "nonexistentProj" }),
      (e: any) => e.status === 404 && /propose/i.test(e.message),
      "classifyChat must return 404 with propose hint even when a peer is offline",
    );
    const rRenOff = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "knownA", to: "targetB" }, { workspace: ws }));
    assert.equal(rRenOff.status, 503, "rename target check must still return 503 when a peer is offline");

    // Clear offline peer stub for subsequent tests
    (f.hub as any).peersInWorkspace = () => null;

    // 2. Item 2: Real SQLite #tx rollback in openChatAtomic on step 3 failure -> 0 threads & 0 thread_sessions, then retry succeeds with project="Keep"
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_keep_project BEFORE UPDATE ON threads
      WHEN NEW.project = 'Keep'
      BEGIN
        SELECT RAISE(ABORT, 'injected classification failure');
      END;
    `);
    await assert.rejects(
      () => newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, clientKey: "ck-tx-atomic", project: "Keep" }),
      /injected classification failure/,
    );
    const orphanCount = Number(f.hub.store.db.prepare("SELECT count(*) AS n FROM threads WHERE project = 'Keep'").get()?.n ?? 0);
    const txSession = f.hub.store.listSessions().find((s) => f.hub.store.homeChat(s.key) === null);
    assert.equal(orphanCount, 0);
    assert.ok(txSession, "session row exists, homeChat must be null because #tx rolled back threads+thread_sessions");
    const memberCount = Number(f.hub.store.db.prepare("SELECT count(*) AS n FROM thread_sessions WHERE session = ?").get(txSession.key)?.n ?? 0);
    assert.equal(memberCount, 0, "thread_sessions must also be rolled back on step-3 failure");

    f.hub.store.db.exec("DROP TRIGGER fail_keep_project");
    const [, tKeep] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, clientKey: "ck-tx-atomic", project: "Keep" });
    assert.equal(tKeep.project, "Keep", "retry with same clientKey after rollback must succeed with initial project");

    // 3a. Item 3: Completed A -> B, then recreate A + pref, then A -> B MUST return 409 and leave new A & original renamedAt untouched
    const [, tA1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ProjA" });
    const rAB1 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ProjA", to: "ProjB" }, { workspace: ws }));
    assert.equal(rAB1.status, 200);
    assert.equal(f.hub.store.getThread(tA1.id)?.project, "ProjB");
    const firstEv = f.hub.store.listProjectRenameEvents(ws).find((e) => e.from === "ProjA" && e.to === "ProjB")!;
    assert.ok(firstEv);

    const [, tA2] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ProjA" });
    f.hub.store.putPresetProjects(ws, "u-newA", JSON.stringify({ pA: { project: "ProjA", rev: 1, at: firstEv.renamedAt + 50 } }));
    const rAB2 = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ProjA", to: "ProjB" }, { workspace: ws }));
    assert.equal(rAB2.status, 409, "completed A->B must NOT be replayed after recreating A");
    assert.equal(f.hub.store.getThread(tA2.id)?.project, "ProjA");
    assert.equal(JSON.parse(f.hub.store.presetProjects(ws, "u-newA")!).pA.project, "ProjA");

    // 3b. Item 3: ChainA -> ChainB -> ChainC then replay ChainA -> ChainB rejected (404), and late old ChainA pref migrates to ChainC!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ChainA" });
    const rCAB = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ChainA", to: "ChainB" }, { workspace: ws }));
    assert.equal(rCAB.status, 200);
    const chainEv1 = f.hub.store.listProjectRenameEvents(ws).find((e) => e.from === "ChainA" && e.to === "ChainB")!;
    const rCBC = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ChainB", to: "ChainC" }, { workspace: ws }));
    assert.equal(rCBC.status, 200);
    const rCAReplay = await dispatch(routes, makeReq("POST", "/projects/rename", { from: "ChainA", to: "ChainB" }, { workspace: ws }));
    assert.equal(rCAReplay.status, 404, "completed ChainA->ChainB after ChainB->ChainC must be rejected with 404");
    const lateAC = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { pChain: { project: "ChainA", rev: 1, at: chainEv1.renamedAt - 10 } } }, { workspace: ws, sub: "u-chain" }),
    );
    assert.equal(JSON.parse(lateAC.body.toString("utf8")).presetProjects.pChain.project, "ChainC");

    // 18-hop chain: h0 -> h1 -> ... -> h18
    const baseAt = f.hub.store.now();
    for (let h = 0; h < 18; h++) {
      f.hub.store.insertProjectRenameEvent(ws, `hop-${h}`, `hop-${h + 1}`, baseAt + 100 + h * 10, null, []);
    }
    const r18 = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { p18: { project: "hop-0", rev: 1, at: baseAt } } }, { workspace: ws, sub: "u-18" }),
    );
    assert.equal(JSON.parse(r18.body.toString("utf8")).presetProjects.p18.project, "hop-18", "18-hop chain must migrate all the way to hop-18 without 16-hop truncation");

    // 3c. Item 3: Concurrent X -> Z and Y -> Z strictly serialized -> one 200, one 409
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ConcX" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ConcY" });
    const [resX, resY] = await Promise.all([
      dispatch(routes, makeReq("POST", "/projects/rename", { from: "ConcX", to: "ConcZ" }, { workspace: ws })),
      dispatch(routes, makeReq("POST", "/projects/rename", { from: "ConcY", to: "ConcZ" }, { workspace: ws })),
    ]);
    assert.deepEqual([resX.status, resY.status].sort((a, b) => a - b), [200, 409], "concurrent X->Z and Y->Z must serialize to exactly one 200 and one 409");

    // 4. Item 7: Legacy session (created_by_sub = NULL) recovery without cross-user leakage
    (f.hub as any).deliver = () => {};
    const alicePreset = await f.hub.presets.add(ws, { name: "AliceLegacy", dirs: [] }, "alice-leg@example.com", "u-alice-leg");
    f.hub.store.putPresetProjects(ws, "u-alice-leg", JSON.stringify({ [alicePreset.id]: { project: "Mine", rev: 1, at: 10 } }));

    // 4a. Alice's pre-upgrade session (created_by_sub = NULL) using Alice's own preset -> recovers preset.owner -> "Mine"
    const [kAliceLeg] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice-leg@example.com", ws });
    assert.equal(f.hub.store.sessionCreatorSub(kAliceLeg), null);
    await chatCreate(f.hub, kAliceLeg, { key: "alice-leg-child", for: "person", preset: alicePreset.id, text: "hi" });
    const aliceChild = f.hub.store.openedWith("", kAliceLeg, "alice-leg-child", "")!;
    assert.equal(f.hub.store.homeChat(aliceChild.child)?.project, "Mine", "legacy Alice session must recover own preset.owner preference");

    // 4b. Bob's pre-upgrade session (created_by_sub = NULL) using Alice's shared preset:
    //     - Before Bob has any session with created_by_sub: unresolvable -> stays undefined (NEVER leaks Alice's "Mine"!)
    const [kBobLeg1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "bob-leg@example.com", ws });
    await chatCreate(f.hub, kBobLeg1, { key: "bob-leg-unres", for: "person", preset: alicePreset.id, text: "hi" });
    const bobChildUnres = f.hub.store.openedWith("", kBobLeg1, "bob-leg-unres", "")!;
    assert.equal(f.hub.store.homeChat(bobChildUnres.child)?.project, undefined, "unresolvable legacy Bob must NEVER leak Alice's preference");

    //     - Once Bob has another session with created_by_sub="u-bob-leg" and pref "BobOwn": uniquely resolved -> gets "BobOwn"!
    f.hub.store.putPresetProjects(ws, "u-bob-leg", JSON.stringify({ [alicePreset.id]: { project: "BobOwn", rev: 1, at: 10 } }));
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "bob-leg@example.com", createdBySub: "u-bob-leg", ws });
    await chatCreate(f.hub, kBobLeg1, { key: "bob-leg-res", for: "person", preset: alicePreset.id, text: "hi" });
    const bobChildRes = f.hub.store.openedWith("", kBobLeg1, "bob-leg-res", "")!;
    assert.equal(f.hub.store.homeChat(bobChildRes.child)?.project, "BobOwn", "legacy Bob with unique email->sub must get BobOwn");

    assert.equal(typeof renameOrMergeProject, "function");
  } finally {
    await f.close();
  }
});

test("R6 Node Station regressions: atomic rename rollback, pending_info/pending_roster/new-key continuation, peer opId dedup & out-of-order convergence, same-ms chain, indexed lookupCreatorSubByEmail", async () => {
  const { chmodSync, mkdirSync, writeFileSync } = await import("node:fs");
  const { chatCreate } = await import("../src/sessions/opened.ts");
  const { classifyForPeer, renameOrMergeProject } = await import("../src/sessions/projects.ts");
  const { projectsInfoPath } = await import("../src/projects/info.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };

    // 1. Atomic local rename rollback on SQLite trigger failure -> retry with same key succeeds!
    const [, tAtom] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "AtomicA" });
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_atomic_b BEFORE UPDATE ON threads
      WHEN NEW.project = 'AtomicB'
      BEGIN SELECT RAISE(ABORT, 'injected atomic failure'); END;
    `);
    const rFail = await dispatch(routes, reqWithKey("/projects/rename", { from: "AtomicA", to: "AtomicB" }, "ik-atomic"));
    assert.equal(rFail.status, 500);
    assert.equal(f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-atomic"), null, "event row must roll back on local update failure");
    f.hub.store.db.exec("DROP TRIGGER fail_atomic_b");
    const rOk = await dispatch(routes, reqWithKey("/projects/rename", { from: "AtomicA", to: "AtomicB" }, "ik-atomic"));
    assert.equal(rOk.status, 200);
    assert.equal(f.hub.store.getThread(tAtom.id)?.project, "AtomicB");

    // 2. pending_info: PROJECTS.jsonl temporarily unreadable (chmod 0o000) -> 200 + infoError + noCache:true -> restore -> retry updates PROJECTS.jsonl!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "FileA" });
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    mkdirSync(join(infoFile, ".."), { recursive: true });
    writeFileSync(infoFile, `${JSON.stringify({ name: "FileA", note: "KeepMe", updatedAt: 10 })}\n`, { mode: 0o600 });
    chmodSync(infoFile, 0o000);
    let rInfoFail: any;
    try {
      rInfoFail = await dispatch(routes, reqWithKey("/projects/rename", { from: "FileA", to: "FileB" }, "ik-info"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rInfoFail.status, 200);
    assert.equal(rInfoFail.noCache, true);
    assert.ok(JSON.parse(rInfoFail.body.toString("utf8")).infoError, "unreadable PROJECTS.jsonl must report infoError");
    const rInfoRetry = await dispatch(routes, reqWithKey("/projects/rename", { from: "FileA", to: "FileB" }, "ik-info"));
    assert.equal(rInfoRetry.status, 200);
    assert.equal(JSON.parse(rInfoRetry.body.toString("utf8")).infoError, undefined);
    const infoAfter = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoAfter.projects["FileB"]?.note, "KeepMe", "retry must finish pending_info and rename PROJECTS.jsonl entry to FileB");

    // 3. pending_roster + 4. client new Idempotency-Key continuation + mismatched params 409
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "RosA" });
    const [, tPeerRos] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "RosA" });
    let rosterCalls = 0;
    let failSecondRoster = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") {
        rosterCalls++;
        // Call 1 is preflight check (succeeds), call 2 is fan-out roster (fails once)
        if (failSecondRoster && rosterCalls === 2) throw new Error("roster transient failure");
        return { stations: [{ id: "peer-real", name: "Peer Real", online: true }] };
      }
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    const rRos1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RosA", to: "RosB" }, "ik-ros-1"));
    assert.equal(rRos1.status, 200);
    assert.equal(rRos1.noCache, true);
    assert.ok(JSON.parse(rRos1.body.toString("utf8")).rosterError);
    assert.equal(peerRig.hub.store.getThread(tPeerRos.id)?.project, "RosA");

    // 4a. Same Idempotency-Key with DIFFERENT params -> 409
    const rMismatch = await dispatch(routes, reqWithKey("/projects/rename", { from: "RosA", to: "DifferentTarget" }, "ik-ros-1"));
    assert.equal(rMismatch.status, 409, "reusing Idempotency-Key for different params must return 409");

    // 4b. Client retries unfinished rename with a BRAND NEW Idempotency-Key -> continues pending_roster and updates peer!
    failSecondRoster = false;
    const rRos2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RosA", to: "RosB" }, "ik-ros-new-key"));
    assert.equal(rRos2.status, 200);
    assert.equal(peerRig.hub.store.getThread(tPeerRos.id)?.project, "RosB", "new-key continuation must recover pending_roster and update peer");

    // 5. Dual-Hub real classifyForPeer: lost response + peer recreates `Old` -> retry with same opId does NOT mutate new `Old`
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OldLost" });
    const [, tPeerOld1] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OldLost" });
    let dropPeerResponse = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-real", name: "Peer Real", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        const res = await classifyForPeer(peerRig.hub, req, ws);
        if (dropPeerResponse) throw new Error("connection reset after peer committed");
        return res;
      }
      return {};
    };
    const rLost1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "OldLost", to: "NewLost" }, "ik-lost"));
    assert.equal(rLost1.status, 200);
    assert.equal(peerRig.hub.store.getThread(tPeerOld1.id)?.project, "NewLost");
    // Peer creates a brand new thread named `OldLost` before coordinator retries
    const [, tPeerOld2] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OldLost" });
    const eventsBefore = peerRig.hub.store.listProjectRenameEvents(ws).filter((e) => e.from === "OldLost").length;
    dropPeerResponse = false;
    const rLost2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "OldLost", to: "NewLost" }, "ik-lost"));
    assert.equal(rLost2.status, 200);
    assert.equal(peerRig.hub.store.getThread(tPeerOld2.id)?.project, "OldLost", "opId dedup must NOT mutate newly created OldLost thread");
    assert.equal(peerRig.hub.store.listProjectRenameEvents(ws).filter((e) => e.from === "OldLost").length, eventsBefore, "peer must keep only 1 event for opId");

    // 6. Dual-Hub out-of-order: B->C (t2) reaches peer FIRST, then A->B (t1 <= t2) arrives -> peer converges A directly to C!
    const [, tPeerOOO] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OOOA" });
    const t1 = peerRig.hub.store.now();
    const t2 = t1 + 100;
    await classifyForPeer(peerRig.hub, { rename: { from: "OOOB", to: "OOOC", opId: "op-bc", renamedAt: t2 } }, ws);
    await classifyForPeer(peerRig.hub, { rename: { from: "OOOA", to: "OOOB", opId: "op-ab", renamedAt: t1 } }, ws);
    assert.equal(peerRig.hub.store.getThread(tPeerOOO.id)?.project, "OOOC", "out-of-order A->B arriving after B->C must forward-resolve to OOOC");

    // 7. Same-millisecond A->B + B->C migrates late old A preference all the way to C
    const sameMs = f.hub.store.now() + 5000;
    f.hub.store.insertProjectRenameEvent(ws, "MsA", "MsB", sameMs, null, []);
    f.hub.store.insertProjectRenameEvent(ws, "MsB", "MsC", sameMs, null, []);
    const rSameMs = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { pMs: { project: "MsA", rev: 1, at: sameMs - 1 } } }, { workspace: ws, sub: "u-ms" }),
    );
    assert.equal(JSON.parse(rSameMs.body.toString("utf8")).presetProjects.pMs.project, "MsC", "same-ms A->B + B->C must migrate old MsA pref to MsC");

    // 8. lookupCreatorSubByEmail uses session_creators_by_email index (no SCAN session_creators) + ambiguous email skips preset.owner fallback
    const plan = f.hub.store.db.prepare(
      "EXPLAIN QUERY PLAN SELECT DISTINCT sub FROM session_creators WHERE email_lower = ?1 AND sub != '' LIMIT 2",
    ).all("ambig@example.com") as { detail: string }[];
    const planText = plan.map((p) => p.detail).join("\n");
    assert.ok(planText.includes("session_creators_by_email") && !planText.includes("SCAN session_creators"), `expected index lookup, got: ${planText}`);

    (f.hub as any).deliver = () => {};
    const ambigPreset = await f.hub.presets.add(ws, { name: "AmbigPreset", dirs: [] }, "ambig@example.com", "u-ambig-1");
    f.hub.store.putPresetProjects(ws, "u-ambig-1", JSON.stringify({ [ambigPreset.id]: { project: "OwnerPref", rev: 1, at: 10 } }));
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ambig@example.com", createdBySub: "u-ambig-1", ws });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ambig@example.com", createdBySub: "u-ambig-2", ws });
    assert.equal(f.hub.store.lookupCreatorSubByEmail("ambig@example.com").kind, "ambiguous");
    const [kAmbigLeg] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ambig@example.com", ws });
    await chatCreate(f.hub, kAmbigLeg, { key: "ambig-child", for: "person", preset: ambigPreset.id, text: "hi" });
    const ambigChild = f.hub.store.openedWith("", kAmbigLeg, "ambig-child", "")!;
    assert.equal(f.hub.store.homeChat(ambigChild.child)?.project, undefined, "ambiguous email must NOT fall back to preset.owner");

    assert.equal(typeof renameOrMergeProject, "function");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R7 Node Station final regressions: preset_projects rollback, pending_info forward-resolve, same-ms reverse-order originSeq, transport-loss continuation, peer preset_projects at-guard, bidirectional rename deadlock-free, Admin bodyHash + takeover opKey, case-insensitive indexed lookupCreatorSubByEmail", async () => {
  const { chmodSync, mkdirSync, writeFileSync } = await import("node:fs");
  const { Admin } = await import("../src/api/admin.ts");
  const { chatCreate } = await import("../src/sessions/opened.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const { projectsInfoPath } = await import("../src/projects/info.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const peerPpRoutes = presetProjectRoutes({ kept: peerRig.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };

    // 1. Item 1: Trigger blocking UPDATE on preset_projects aborts & rolls back ENTIRE rename tx; retry after drop succeeds
    const [, tP1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "P1Old" });
    f.hub.store.putPresetProjects(ws, "u-p1", JSON.stringify({ pre1: { project: "P1Old", rev: 1, at: 10 } }));
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_preset_projects_update BEFORE UPDATE ON preset_projects
      WHEN NEW.sub = 'u-p1'
      BEGIN SELECT RAISE(ABORT, 'injected preset_projects failure'); END;
    `);
    const rP1Fail = await dispatch(routes, reqWithKey("/projects/rename", { from: "P1Old", to: "P1New" }, "ik-p1"));
    assert.equal(rP1Fail.status, 500, "SQLite error on preset_projects must NOT be swallowed");
    assert.equal(f.hub.store.getThread(tP1.id)?.project, "P1Old", "threads must roll back when preset_projects fails");
    assert.equal(f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-p1"), null, "project_rename_events must roll back");
    assert.equal(JSON.parse(f.hub.store.presetProjects(ws, "u-p1")!).pre1.project, "P1Old", "preset_projects must roll back");
    f.hub.store.db.exec("DROP TRIGGER fail_preset_projects_update");
    const rP1Ok = await dispatch(routes, reqWithKey("/projects/rename", { from: "P1Old", to: "P1New" }, "ik-p1"));
    assert.equal(rP1Ok.status, 200);
    assert.equal(f.hub.store.getThread(tP1.id)?.project, "P1New");
    assert.equal(JSON.parse(f.hub.store.presetProjects(ws, "u-p1")!).pre1.project, "P1New");

    // 2. Item 2: A->B fails PROJECTS.jsonl (pending_info), then B->C succeeds, then retry A->B merges directly into C without recreating B
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ChainInfoA" });
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    mkdirSync(join(infoFile, ".."), { recursive: true });
    writeFileSync(
      infoFile,
      `${JSON.stringify({ name: "ChainInfoA", note: "NoteA", refs: ["ref-a"], updatedAt: 10 })}\n`,
      { mode: 0o600 },
    );
    chmodSync(infoFile, 0o000);
    let rInfoAB: any;
    try {
      rInfoAB = await dispatch(routes, reqWithKey("/projects/rename", { from: "ChainInfoA", to: "ChainInfoB" }, "ik-ci-ab"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rInfoAB.status, 200);
    assert.ok(JSON.parse(rInfoAB.body.toString("utf8")).infoError);
    // Now B -> C succeeds normally
    const rInfoBC = await dispatch(routes, reqWithKey("/projects/rename", { from: "ChainInfoB", to: "ChainInfoC" }, "ik-ci-bc"));
    assert.equal(rInfoBC.status, 200);
    // Retry A -> B to finish pending_info -> must forward-resolve target to ChainInfoC and NEVER recreate ChainInfoB!
    const rInfoABRetry = await dispatch(routes, reqWithKey("/projects/rename", { from: "ChainInfoA", to: "ChainInfoB" }, "ik-ci-ab"));
    assert.equal(rInfoABRetry.status, 200);
    const infoMap = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoMap.projects["ChainInfoA"], undefined, "ChainInfoA must be removed");
    assert.equal(infoMap.projects["ChainInfoB"], undefined, "intermediate ChainInfoB must NOT be recreated");
    assert.equal(infoMap.projects["ChainInfoC"]?.note, "NoteA", "ChainInfoA note must merge directly into ChainInfoC");
    assert.deepEqual(infoMap.projects["ChainInfoC"]?.refs, ["ref-a"], "ChainInfoA refs must merge directly into ChainInfoC");

    // 3. Item 3: Same-millisecond A->B->C->D on coordinator, delivered in reverse order to peer -> all converge to D!
    const origNow = f.hub.store.now.bind(f.hub.store);
    const fixedMs = origNow() + 50_000;
    const [, tCoordA] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "SameMsA" });
    const [, tPeerA] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "SameMsA" });
    const capturedRpcs: any[] = [];
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        capturedRpcs.push(req);
        return { changed: 0 };
      }
      return {};
    };
    (f.hub.store as any).now = () => fixedMs;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "SameMsA", to: "SameMsB" }, "ik-ms-1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "SameMsB", to: "SameMsC" }, "ik-ms-2"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "SameMsC", to: "SameMsD" }, "ik-ms-3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    assert.equal(capturedRpcs.length, 3);
    assert.equal(f.hub.store.getThread(tCoordA.id)?.project, "SameMsD");
    // Deliver to peer in REVERSE order: C->D, B->C, A->B
    for (const rpc of [...capturedRpcs].reverse()) {
      await classifyForPeer(peerRig.hub, rpc, ws);
    }
    assert.equal(peerRig.hub.store.getThread(tPeerA.id)?.project, "SameMsD", "reverse-delivered same-ms chain must converge peer thread to SameMsD");
    const rLatePeerPref = await dispatch(
      peerPpRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { pSame: { project: "SameMsA", rev: 1, at: fixedMs - 1 } } }, { workspace: ws, sub: "u-same-ms" }),
    );
    assert.equal(
      JSON.parse(rLatePeerPref.body.toString("utf8")).presetProjects.pSame.project,
      "SameMsD",
      "early SameMsA pref submitted on peer must migrate all the way to SameMsD",
    );

    // 4. Item 4: Continuation when peersInWorkspace() returns null (transport lost) preserves pending_peers & returns rosterError + noCache:true
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "TransA" });
    const [, tPeerTrans] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "TransA" });
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") throw new Error("initial peer fail");
      return {};
    };
    const rTrans1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "TransA", to: "TransB" }, "ik-trans"));
    assert.equal(rTrans1.status, 200);
    assert.equal(rTrans1.noCache, true);
    assert.equal(peerRig.hub.store.getThread(tPeerTrans.id)?.project, "TransA");
    // Now transport disappears completely (peersInWorkspace returns null)
    (f.hub as any).peersInWorkspace = () => null;
    const rTrans2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "TransA", to: "TransB" }, "ik-trans"));
    assert.equal(rTrans2.status, 200);
    assert.equal(rTrans2.noCache, true, "transport unavailable during continuation must set noCache:true");
    assert.ok(JSON.parse(rTrans2.body.toString("utf8")).rosterError, "transport unavailable must report rosterError");
    const evTrans = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-trans")!;
    assert.deepEqual(evTrans.pendingPeers, ["peer-1"], "pending_peers must be preserved when transport is unavailable");
    // Transport comes back -> retry delivers to peer!
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    const rTrans3 = await dispatch(routes, reqWithKey("/projects/rename", { from: "TransA", to: "TransB" }, "ik-trans"));
    assert.equal(rTrans3.status, 200);
    assert.equal(rTrans3.noCache, undefined);
    assert.equal(peerRig.hub.store.getThread(tPeerTrans.id)?.project, "TransB", "peer must converge once transport recovers");

    // 5. Item 5: Peer preset_projects with newer `at >= renamedAt` is NOT overwritten by older rename RPC
    peerRig.hub.store.putPresetProjects(ws, "u-newer", JSON.stringify({ pKeep: { project: "KeepNew", rev: 2, at: 2000 } }));
    await classifyForPeer(peerRig.hub, { rename: { from: "KeepNew", to: "OldRename", opId: "op-old-at", renamedAt: 1000, originSeq: 1 } }, ws);
    const keptPref = JSON.parse(peerRig.hub.store.presetProjects(ws, "u-newer")!).pKeep;
    assert.equal(keptPref.project, "KeepNew", "newer preset_projects (at=2000 >= renamedAt=1000) must NOT be rewritten");
    assert.equal(keptPref.at, 2000);

    // 6. Item 6: Dual-Hub concurrent bidirectional rename (Hub1: First->FirstNew, Hub2: Second->SecondNew) completes with zero deadlock
    const [, tBid1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "BidFirst" });
    const [, tBid2Peer] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "BidSecond" });
    const [, tBid1Peer] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "BidFirst" });
    const [, tBid2Coord] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "BidSecond" });
    const peerRoutes = projectRoutes({ store: peerRig.hub.store, agents: { hub: peerRig.hub } as any, data: peerRig.dir } as any);
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-2", name: "Peer 2", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        await new Promise((r) => setTimeout(r, 20));
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    (peerRig.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        await new Promise((r) => setTimeout(r, 20));
        return classifyForPeer(f.hub, req, ws);
      }
      return {};
    };
    const [rBid1, rBid2] = await Promise.all([
      dispatch(routes, reqWithKey("/projects/rename", { from: "BidFirst", to: "BidFirstNew" }, "ik-bid-1")),
      dispatch(peerRoutes, reqWithKey("/projects/rename", { from: "BidSecond", to: "BidSecondNew" }, "ik-bid-2")),
    ]);
    assert.equal(rBid1.status, 200);
    assert.equal(rBid2.status, 200);
    assert.equal(f.hub.store.getThread(tBid1.id)?.project, "BidFirstNew");
    assert.equal(peerRig.hub.store.getThread(tBid1Peer.id)?.project, "BidFirstNew");
    assert.equal(peerRig.hub.store.getThread(tBid2Peer.id)?.project, "BidSecondNew");
    assert.equal(f.hub.store.getThread(tBid2Coord.id)?.project, "BidSecondNew");

    // 7. Item 7: Real Admin.handle bodyHash 409 + takeover opKey persistence across fresh Admin instance (restart)
    (f.hub as any).peersInWorkspace = () => null;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "AdmA" });
    const admin1 = new Admin({ data: f.dir, names: new Map() } as any, { store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir });
    const rAdmOk = await admin1.handle(reqWithKey("/projects/rename", { from: "AdmA", to: "AdmB" }, "ik-adm-1"));
    assert.equal(rAdmOk.status, 200);
    // Same Idempotency-Key with different body in Admin.once memory cache -> 409!
    const rAdmDiff = await admin1.handle(reqWithKey("/projects/rename", { from: "AdmA", to: "AdmC" }, "ik-adm-1"));
    assert.equal(rAdmDiff.status, 409, "Admin.once must return 409 when same Idempotency-Key is reused with different body");

    // Takeover key persistence: first attempt fails peer -> second attempt with NEW takeover key finishes -> fresh Admin (empty memory cache) replays takeover key
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "TakeA" });
    let failTakePeer = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (failTakePeer) throw new Error("fail once");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    const rTake1 = await admin1.handle(reqWithKey("/projects/rename", { from: "TakeA", to: "TakeB" }, "ik-take-1"));
    assert.equal(rTake1.status, 200);
    failTakePeer = false;
    const rTake2 = await admin1.handle(reqWithKey("/projects/rename", { from: "TakeA", to: "TakeB" }, "ik-take-2"));
    assert.equal(rTake2.status, 200);
    // Fresh Admin instance simulates station restart (empty in-memory slots)
    const admin2 = new Admin({ data: f.dir, names: new Map() } as any, { store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir });
    const rTakeReplaySame = await admin2.handle(reqWithKey("/projects/rename", { from: "TakeA", to: "TakeB" }, "ik-take-2"));
    assert.equal(rTakeReplaySame.status, 200, "takeover key must remain idempotent after station restart");
    const rTakeReplayDiff = await admin2.handle(reqWithKey("/projects/rename", { from: "TakeA", to: "TakeOther" }, "ik-take-2"));
    assert.equal(rTakeReplayDiff.status, 409, "takeover key with different params must return 409 after station restart");

    // 8. Item 8: Mixed-case email ambiguity + session_creators_by_email index lookup + opened.ts skips preset.owner fallback
    const lowerPlan = f.hub.store.db.prepare(
      "EXPLAIN QUERY PLAN SELECT DISTINCT sub FROM session_creators WHERE email_lower = ?1 AND sub != '' LIMIT 2",
    ).all("mixcase@example.com") as { detail: string }[];
    const lowerPlanText = lowerPlan.map((p) => p.detail).join("\n");
    assert.ok(
      lowerPlanText.includes("session_creators_by_email") && !lowerPlanText.includes("SCAN session_creators"),
      `expected session_creators_by_email index lookup, got: ${lowerPlanText}`,
    );

    (f.hub as any).deliver = () => {};
    const mixPreset = await f.hub.presets.add(ws, { name: "MixPreset", dirs: [] }, "MixCase@Example.com", "u-mix-1");
    f.hub.store.putPresetProjects(ws, "u-mix-1", JSON.stringify({ [mixPreset.id]: { project: "MixOwner", rev: 1, at: 10 } }));
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "MixCase@Example.com", createdBySub: "u-mix-1", ws });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "mixcase@example.com", createdBySub: "u-mix-2", ws });
    assert.equal(f.hub.store.lookupCreatorSubByEmail("MIXCASE@example.com").kind, "ambiguous");
    const [kMixLeg] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "mixcase@example.com", ws });
    await chatCreate(f.hub, kMixLeg, { key: "mix-child", for: "person", preset: mixPreset.id, text: "hi" });
    const mixChild = f.hub.store.openedWith("", kMixLeg, "mix-child", "")!;
    assert.equal(f.hub.store.homeChat(mixChild.child)?.project, undefined, "mixed-case ambiguous email must NOT fall back to preset.owner");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R8 Node Station final 4 micro-fixes: info-only concurrent X->Z vs Y->Z, monotonic Phase 2 + per-eventSeq pending_info lock, same-ms preset_projects original at preservation, and unfinished from->B blocks conflicting from->C", async () => {
  const { updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };

    // 1. Info-only X (note-X) and Y (note-Y) on same Hub: X->Z paused in outbound peer RPC while Y->Z runs -> 200 + 409, Z has note-X, Y & note-Y untouched
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "InfoX", note: "note-X", now: 100 });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "InfoY", note: "note-Y", now: 100 });
    let releaseXPeer!: () => void;
    const xPeerStarted = new Promise<void>((r) => {
      (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
        if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
        if (req.method === "projects.names") return { exists: false };
        if (req.method === "thread.classify" && req.rename?.from === "InfoX") {
          r();
          await new Promise<void>((res) => { releaseXPeer = res; });
          return classifyForPeer(peerRig.hub, req, ws);
        }
        return {};
      };
    });
    const pX = dispatch(routes, reqWithKey("/projects/rename", { from: "InfoX", to: "InfoZ" }, "ik-r8-xz"));
    await xPeerStarted;
    // While X->Z is in Phase 2 (before PROJECTS.jsonl is updated), Y->Z MUST immediately see pending target InfoZ and fail 409!
    const rY = await dispatch(routes, reqWithKey("/projects/rename", { from: "InfoY", to: "InfoZ" }, "ik-r8-yz"));
    assert.equal(rY.status, 409, "Y->Z must be rejected with 409 while X->Z has pending target Z");
    releaseXPeer();
    const rX = await pX;
    assert.equal(rX.status, 200);
    const info1 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info1.projects["InfoZ"]?.note, "note-X");
    assert.equal(info1.projects["InfoY"]?.note, "note-Y", "Y and note-Y must remain untouched");
    assert.equal(info1.projects["InfoX"], undefined);

    // 2. Stale first request stuck in peer RPC; takeover with new key finishes & clears pending_peers + PROJECTS.jsonl;
    //    recreate A with fresh note; first request then fails -> fresh A note & B original note intact, pending_peers stays []!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "Take2A" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "Take2A", note: "original note", now: 200 });
    let failFirstTake!: (e: Error) => void;
    let callIdx = 0;
    const firstStuck = new Promise<void>((started) => {
      (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
        if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
        if (req.method === "projects.names") return { exists: false };
        if (req.method === "thread.classify" && req.rename?.from === "Take2A") {
          callIdx++;
          if (callIdx === 1) {
            started();
            await new Promise<void>((_, rej) => { failFirstTake = rej; });
          }
          return classifyForPeer(peerRig.hub, req, ws);
        }
        return {};
      };
    });
    const pFirst = dispatch(routes, reqWithKey("/projects/rename", { from: "Take2A", to: "Take2B" }, "ik-r8-t1"));
    await firstStuck;
    // Takeover with a new Idempotency-Key completes while first request is still stuck in peer RPC
    const rTakeover = await dispatch(routes, reqWithKey("/projects/rename", { from: "Take2A", to: "Take2B" }, "ik-r8-t2"));
    assert.equal(rTakeover.status, 200);
    // Recreate Take2A with fresh note
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "Take2A", note: "fresh note", now: 300 });
    // Now first request's peer RPC finally fails with a transport error
    failFirstTake(new Error("late transport failure"));
    const rFirst = await pFirst;
    assert.equal(rFirst.status, 200);
    const evTake2 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r8-t1")!;
    assert.deepEqual(evTake2.pendingPeers, [], "late failing request must NOT re-add peer to pending_peers");
    assert.equal(evTake2.pendingInfo, false, "pending_info must remain false");
    const info2 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info2.projects["Take2A"]?.note, "fresh note", "late request must NOT clobber recreated Take2A's fresh note");
    assert.equal(info2.projects["Take2B"]?.note, "original note", "Take2B must keep original note");

    // 3. Same-ms fixed clock: pre-existing pref (at: t-10) + late pref (at: t-10) both open in C after A->B->C; newer pref (at: t) stays A
    (f.hub as any).peersInWorkspace = () => null;
    const origNow = f.hub.store.now.bind(f.hub.store);
    const fixedT = origNow() + 90_000;
    const pPreset = await f.hub.presets.add(ws, { name: "SameMsPreset", dirs: [] }, "alice@example.com", "u-ms-pre");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "MsPreA" });
    f.hub.store.putPresetProjects(ws, "u-ms-pre", JSON.stringify({ [pPreset.id]: { project: "MsPreA", rev: 1, at: fixedT - 10 } }));
    f.hub.store.putPresetProjects(ws, "u-ms-newer", JSON.stringify({ [pPreset.id]: { project: "MsPreA", rev: 1, at: fixedT } }));
    (f.hub.store as any).now = () => fixedT;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "MsPreA", to: "MsPreB" }, "ik-r8-ms1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "MsPreB", to: "MsPreC" }, "ik-r8-ms2"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Late device submits same original-timestamp preference (at: fixedT - 10)
    const rLatePut = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pPreset.id]: { project: "MsPreA", rev: 1, at: fixedT - 10 } } }, { workspace: ws, sub: "u-ms-late" }),
    );
    assert.equal(rLatePut.status, 200);
    // Open actual chats with newSession for both pre-existing and late users -> BOTH open in MsPreC!
    const [, tPreChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-ms-pre", ws, preset: pPreset.id });
    const [, tLateChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-ms-late", ws, preset: pPreset.id });
    const [, tNewerChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-ms-newer", ws, preset: pPreset.id });
    assert.equal(tPreChat.project, "MsPreC", "pre-existing pref must converge to MsPreC across same-ms A->B->C");
    assert.equal(tLateChat.project, "MsPreC", "late pref with same original at must also converge to MsPreC");
    assert.equal(tNewerChat.project, "MsPreA", "newer pref with at >= fixedT must keep MsPreA untouched");

    // 4. Unfinished A->B (pending peer) blocks conflicting A->C (409); after A->B completes, A->C succeeds (200) with old=B, new=C on both hubs
    const [, tOldCoord] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ReuseA" });
    const [, tOldPeer] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ReuseA" });
    let failReusePeer = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (failReusePeer) throw new Error("peer offline during ReuseA->ReuseB");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    const rReuseAB1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "ReuseA", to: "ReuseB" }, "ik-r8-ab"));
    assert.equal(rReuseAB1.status, 200);
    assert.equal(f.hub.store.getThread(tOldCoord.id)?.project, "ReuseB");
    assert.equal(peerRig.hub.store.getThread(tOldPeer.id)?.project, "ReuseA");
    // Recreate ReuseA locally and attempt ReuseA->ReuseC while ReuseA->ReuseB still has pending peer -> MUST return 409!
    const [, tNewCoord] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ReuseA" });
    const rReuseACBlocked = await dispatch(routes, reqWithKey("/projects/rename", { from: "ReuseA", to: "ReuseC" }, "ik-r8-ac"));
    assert.equal(rReuseACBlocked.status, 409, "conflicting ReuseA->ReuseC must be blocked while ReuseA->ReuseB has pending peer");
    // Retry ReuseA->ReuseB to completion
    failReusePeer = false;
    const rReuseAB2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "ReuseA", to: "ReuseB" }, "ik-r8-ab"));
    assert.equal(rReuseAB2.status, 200);
    assert.equal(peerRig.hub.store.getThread(tOldPeer.id)?.project, "ReuseB");
    // Now ReuseA->ReuseC succeeds!
    const rReuseACOk = await dispatch(routes, reqWithKey("/projects/rename", { from: "ReuseA", to: "ReuseC" }, "ik-r8-ac"));
    assert.equal(rReuseACOk.status, 200);
    assert.equal(f.hub.store.getThread(tOldCoord.id)?.project, "ReuseB", "coordinator old thread must stay ReuseB");
    assert.equal(peerRig.hub.store.getThread(tOldPeer.id)?.project, "ReuseB", "peer old thread must stay ReuseB");
    assert.equal(f.hub.store.getThread(tNewCoord.id)?.project, "ReuseC", "recreated thread must become ReuseC");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R9 Node Station final 5 closure regressions: B->C then A->B watermark stays B, auto-migration never bumps rev so offline edit wins, pending_info blocks conflicting X->Z, markRenameInfoDone failure retry preserves recreated A, transient 409 noCache allows same-key retry via Admin.handle", async () => {
  const { chmodSync } = await import("node:fs");
  const { Admin } = await import("../src/api/admin.ts");
  const { projectsInfoPath, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };

    // 1. B->C (t=1000) then A->B (t=2000): preset originally on A must stay on B after empty PUT & newSession!
    const pOrder = await f.hub.presets.add(ws, { name: "OrderPreset", dirs: [] }, "alice@example.com", "u-order");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdA" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdB" });
    const origNow = f.hub.store.now.bind(f.hub.store);
    const t0 = origNow() + 100_000;
    f.hub.store.putPresetProjects(ws, "u-order", JSON.stringify({ [pOrder.id]: { project: "OrdA", rev: 1, at: t0 - 500 } }));
    (f.hub.store as any).now = () => t0 + 1000;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdB", to: "OrdC" }, "ik-r9-bc"))).status, 200);
      (f.hub.store as any).now = () => t0 + 2000;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdA", to: "OrdB" }, "ik-r9-ab"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const rEmptyPut = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: {} }, { workspace: ws, sub: "u-order" }),
    );
    assert.equal(rEmptyPut.status, 200);
    const afterEmpty = JSON.parse(rEmptyPut.body.toString("utf8")).presetProjects[pOrder.id];
    assert.equal(afterEmpty.project, "OrdB", "empty PUT must NOT replay earlier B->C onto OrdB");
    assert.equal(afterEmpty.rev, 1, "auto-migration must NOT bump rev");
    const [, tOrderChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-order", ws, preset: pOrder.id });
    assert.equal(tOrderChat.project, "OrdB", "newSession after B->C then A->B must open in OrdB, not OrdC");

    // 2. Offline device real edit (rev: 2) wins over server auto-migration (A->B->C keeps rev: 1), while unedited old device (rev: 1, old at) converges to C
    const pOff = await f.hub.presets.add(ws, { name: "OffPreset", dirs: [] }, "alice@example.com", "u-off");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OffA" });
    const tOff = origNow() + 200_000;
    f.hub.store.putPresetProjects(ws, "u-off", JSON.stringify({ [pOff.id]: { project: "OffA", rev: 1, at: tOff - 500 } }));
    (f.hub.store as any).now = () => tOff;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OffA", to: "OffB" }, "ik-r9-off1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OffB", to: "OffC" }, "ik-r9-off2"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Unedited old device submits stale { project: "OffA", rev: 1, at: tOff - 500 } -> stays converged at OffC (rev: 1)
    const rStaleDev = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pOff.id]: { project: "OffA", rev: 1, at: tOff - 500 } } }, { workspace: ws, sub: "u-off" }),
    );
    assert.equal(rStaleDev.status, 200);
    const afterStale = JSON.parse(rStaleDev.body.toString("utf8")).presetProjects[pOff.id];
    assert.equal(afterStale.project, "OffC");
    assert.equal(afterStale.rev, 1);
    // Offline device that made a real user choice { project: "FreshChoice", rev: 2, at: tOff + 50 } -> MUST win!
    const rFreshDev = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pOff.id]: { project: "FreshChoice", rev: 2, at: tOff + 50 } } }, { workspace: ws, sub: "u-off" }),
    );
    assert.equal(rFreshDev.status, 200);
    const afterFresh = JSON.parse(rFreshDev.body.toString("utf8")).presetProjects[pOff.id];
    assert.equal(afterFresh.project, "FreshChoice", "offline user's rev:2 choice must NOT be overridden by auto-migration");
    assert.equal(afterFresh.rev, 2);

    // 3. X->Y commits SQLite but PROJECTS.jsonl is unreadable (pending_info = 1); restoring file & sending X->Z returns 409; retrying X->Y moves note to Y
    const [, tInfoX] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "PendInfoX" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "PendInfoX", note: "NoteForX", now: 100 });
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    chmodSync(infoFile, 0o000);
    let rXY1: any;
    try {
      rXY1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "PendInfoX", to: "PendInfoY" }, "ik-r9-xy"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rXY1.status, 200);
    assert.ok(JSON.parse(rXY1.body.toString("utf8")).infoError);
    // Conflicting X->Z while X->Y has pending_info = 1 MUST be rejected with 409!
    const rXZBlocked = await dispatch(routes, reqWithKey("/projects/rename", { from: "PendInfoX", to: "PendInfoZ" }, "ik-r9-xz"));
    assert.equal(rXZBlocked.status, 409, "pending_info=1 on X->Y must block conflicting X->Z");
    assert.equal(rXZBlocked.noCache, true);
    // Retry X->Y completes PROJECTS.jsonl migration -> Y has both thread and NoteForX
    const rXY2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "PendInfoX", to: "PendInfoY" }, "ik-r9-xy"));
    assert.equal(rXY2.status, 200);
    assert.equal(f.hub.store.getThread(tInfoX.id)?.project, "PendInfoY");
    const info3 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info3.projects["PendInfoY"]?.note, "NoteForX");
    assert.equal(info3.projects["PendInfoX"], undefined);

    // 4. SQLite trigger fails ONLY `UPDATE project_rename_events SET pending_info = 0` after PROJECTS.jsonl already moved A->B;
    //    drop trigger, recreate A with fresh note, retry A->B -> 200, recreated A keeps fresh note, B keeps orig note, pending_info = 0
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "MarkFailA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "MarkFailA", note: "OrigMarkNote", now: 100 });
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_mark_info_done BEFORE UPDATE OF pending_info ON project_rename_events
      WHEN OLD.from_name = 'MarkFailA' AND NEW.pending_info = 0
      BEGIN SELECT RAISE(ABORT, 'injected markRenameInfoDone failure'); END;
    `);
    const rMarkFail = await dispatch(routes, reqWithKey("/projects/rename", { from: "MarkFailA", to: "MarkFailB" }, "ik-r9-mark"));
    assert.equal(rMarkFail.status, 200);
    assert.equal(rMarkFail.noCache, true);
    assert.ok(JSON.parse(rMarkFail.body.toString("utf8")).infoError);
    f.hub.store.db.exec("DROP TRIGGER fail_mark_info_done");
    // Recreate MarkFailA with a brand new note AFTER the rename
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "MarkFailA", note: "FreshRecreatedNote", now: f.hub.store.now() + 5000 });
    // Retry A->B with same key -> must NOT re-move recreated MarkFailA; clears pending_info = 0!
    const rMarkRetry = await dispatch(routes, reqWithKey("/projects/rename", { from: "MarkFailA", to: "MarkFailB" }, "ik-r9-mark"));
    assert.equal(rMarkRetry.status, 200);
    assert.equal(JSON.parse(rMarkRetry.body.toString("utf8")).infoError, undefined);
    const evMark = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r9-mark")!;
    assert.equal(evMark.pendingInfo, false, "pending_info must be cleared on retry");
    const info4 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info4.projects["MarkFailA"]?.note, "FreshRecreatedNote", "recreated MarkFailA's fresh note must remain intact");
    assert.equal(info4.projects["MarkFailB"]?.note, "OrigMarkNote", "MarkFailB must keep only OrigMarkNote");

    // 5. Real Admin.handle: transient 409 on A->C (key `ik-ac`) is NOT cached (noCache:true); once A->B finishes, retrying SAME `ik-ac` returns 200!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "AdmRetryA" });
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "AdmRetryA" });
    let failAdmPeer = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (failAdmPeer) throw new Error("peer unreachable");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    const admin = new Admin({ data: f.dir, names: new Map() } as any, { store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir });
    const rAdmAB1 = await admin.handle(reqWithKey("/projects/rename", { from: "AdmRetryA", to: "AdmRetryB" }, "ik-r9-adm-ab"));
    assert.equal(rAdmAB1.status, 200);
    // Recreate AdmRetryA locally and send AdmRetryA -> AdmRetryC with key `ik-ac` while AB still has pending peer -> 409 (not cached!)
    const [, tAdmNew] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "AdmRetryA" });
    const rAdmAC1 = await admin.handle(reqWithKey("/projects/rename", { from: "AdmRetryA", to: "AdmRetryC" }, "ik-r9-adm-ac"));
    assert.equal(rAdmAC1.status, 409, "transient conflict must return 409");
    // Complete AdmRetryA -> AdmRetryB
    failAdmPeer = false;
    const rAdmAB2 = await admin.handle(reqWithKey("/projects/rename", { from: "AdmRetryA", to: "AdmRetryB" }, "ik-r9-adm-ab"));
    assert.equal(rAdmAB2.status, 200);
    // Retry AdmRetryA -> AdmRetryC with the EXACT SAME Idempotency-Key `ik-r9-adm-ac` -> MUST succeed 200!
    const rAdmAC2 = await admin.handle(reqWithKey("/projects/rename", { from: "AdmRetryA", to: "AdmRetryC" }, "ik-r9-adm-ac"));
    assert.equal(rAdmAC2.status, 200, "same Idempotency-Key after transient 409 must succeed once prerequisite completes");
    assert.equal(f.hub.store.getThread(tAdmNew.id)?.project, "AdmRetryC");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R10 Node Station final 3 closure regressions: late A->B after C->D & B->C carries forward-resolved watermark on peer, same-ms A->Z->B monotonic entry.at resists stale GET Z PUT-back, and same-ms A->B->C->D first-run preserves note all the way to D", async () => {
  const { updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const peerPpRoutes = presetProjectRoutes({ kept: peerRig.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };

    // 1. Coordinator runs A->B (t0, fails peer delivery), C->D (t0+100, reaches peer), B->C (t0+200, reaches peer),
    //    then retries A->B -> peer GET /preset-projects, empty PUT /preset-projects ({}), and newSession ALL stay on C (never D)!
    const origNow = f.hub.store.now.bind(f.hub.store);
    const t0 = origNow() + 300_000;
    const pPeer = await peerRig.hub.presets.add(ws, { name: "PeerPreset", dirs: [] }, "alice@example.com", "u-peer-wm");
    peerRig.hub.store.putPresetProjects(ws, "u-peer-wm", JSON.stringify({ [pPeer.id]: { project: "WmA", rev: 1, at: t0 - 500 } }));
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "WmA" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "WmC" });
    let failFirstAB = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (failFirstAB && req.rename?.from === "WmA" && req.rename?.to === "WmB") {
          throw new Error("initial WmA->WmB delivery dropped");
        }
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    (f.hub.store as any).now = () => t0;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WmA", to: "WmB" }, "ik-r10-ab"))).status, 200);
      (f.hub.store as any).now = () => t0 + 100;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WmC", to: "WmD" }, "ik-r10-cd"))).status, 200);
      (f.hub.store as any).now = () => t0 + 200;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WmB", to: "WmC" }, "ik-r10-bc"))).status, 200);
      // Now retry WmA->WmB with same key -> reaches peer after WmC->WmD and WmB->WmC
      failFirstAB = false;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WmA", to: "WmB" }, "ik-r10-ab"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const rPeerGet = await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-peer-wm" }));
    assert.equal(rPeerGet.status, 200);
    assert.equal(JSON.parse(rPeerGet.body.toString("utf8")).presetProjects[pPeer.id].project, "WmC");
    const rPeerEmptyPut = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: {} }, { workspace: ws, sub: "u-peer-wm" }));
    assert.equal(rPeerEmptyPut.status, 200);
    assert.equal(JSON.parse(rPeerEmptyPut.body.toString("utf8")).presetProjects[pPeer.id].project, "WmC", "empty PUT on peer must NOT replay earlier WmC->WmD");
    const [, tPeerChat] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-peer-wm", ws, preset: pPeer.id });
    assert.equal(tPeerChat.project, "WmC", "newSession on peer must open in WmC, never WmD");

    // 2. Fixed same-ms T: preset on A -> A->Z -> save GET snapshot (Z) -> Z->B -> PUT saved Z back -> stays B & newSession opens in B; rev:2 still wins!
    (f.hub as any).peersInWorkspace = () => null;
    const tSame = origNow() + 400_000;
    const pLex = await f.hub.presets.add(ws, { name: "LexPreset", dirs: [] }, "alice@example.com", "u-lex");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "LexA" });
    f.hub.store.putPresetProjects(ws, "u-lex", JSON.stringify({ [pLex.id]: { project: "LexA", rev: 1, at: tSame - 50 } }));
    (f.hub.store as any).now = () => tSame;
    let savedZMap: any;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LexA", to: "LexZ" }, "ik-r10-az"))).status, 200);
      const rGetZ = await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-lex" }));
      assert.equal(rGetZ.status, 200);
      savedZMap = JSON.parse(rGetZ.body.toString("utf8")).presetProjects;
      assert.equal(savedZMap[pLex.id].project, "LexZ");
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LexZ", to: "LexB" }, "ik-r10-zb"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // PUT stale GET snapshot { LexZ, rev: 1, at: tSame } back -> LexB has at = tSame + 1 > tSame so LexB MUST win!
    const rPutStaleZ = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: savedZMap }, { workspace: ws, sub: "u-lex" }));
    assert.equal(rPutStaleZ.status, 200);
    assert.equal(JSON.parse(rPutStaleZ.body.toString("utf8")).presetProjects[pLex.id].project, "LexB", "stale same-ms GET Z snapshot must NOT roll back LexB");
    const [, tLexChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-lex", ws, preset: pLex.id });
    assert.equal(tLexChat.project, "LexB");
    // Real offline edit with rev: 2 still wins over auto-migrated rev: 1
    const rOfflineRev2 = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pLex.id]: { project: "OfflineChoice", rev: 2, at: tSame } } }, { workspace: ws, sub: "u-lex" }),
    );
    assert.equal(rOfflineRev2.status, 200);
    assert.equal(JSON.parse(rOfflineRev2.body.toString("utf8")).presetProjects[pLex.id].project, "OfflineChoice");

    // 3. Same-ms T chain A->B->C->D (all first-run 200) moves note `keep-note` all the way to D and removes A, B, C!
    const tChain = origNow() + 500_000;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "NoteA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "NoteA", note: "keep-note", now: tChain - 10 });
    (f.hub.store as any).now = () => tChain;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "NoteA", to: "NoteB" }, "ik-r10-n1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "NoteB", to: "NoteC" }, "ik-r10-n2"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "NoteC", to: "NoteD" }, "ik-r10-n3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const infoChain = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoChain.projects["NoteD"]?.note, "keep-note", "same-ms A->B->C->D must preserve keep-note on NoteD");
    assert.equal(infoChain.projects["NoteA"], undefined);
    assert.equal(infoChain.projects["NoteB"], undefined);
    assert.equal(infoChain.projects["NoteC"], undefined);
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R11 Node Station root-cause closure regressions: same-ms A->B->C->D with C->D pending_info retry, Phase 1 PROJECTS.jsonl before peer RPC protects recreated A, and monotonic logical renamedAt fixes cross-peer empty & delayed stale Z snapshots", async () => {
  const { chmodSync } = await import("node:fs");
  const { projectsInfoPath, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerEmpty = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerDelayed = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const peerEmptyPpRoutes = presetProjectRoutes({ kept: peerEmpty.hub.store, told: () => {} });
    const peerDelayedPpRoutes = presetProjectRoutes({ kept: peerDelayed.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);

    // 1. P1-1: Fixed clock T -> A->B, B->C succeed; PROJECTS.jsonl unreadable on C->D (200 + infoError + noCache:true);
    //    restore file & retry C->D with same key -> 200, pending_info=false, D holds original note, C removed!
    const t1 = origNow() + 600_000;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R11A" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "R11A", note: "r11-keep-note", now: t1 - 10 });
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    (f.hub.store as any).now = () => t1;
    let rCD1: any;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R11A", to: "R11B" }, "ik-r11-ab"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R11B", to: "R11C" }, "ik-r11-bc"))).status, 200);
      chmodSync(infoFile, 0o000);
      try {
        rCD1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "R11C", to: "R11D" }, "ik-r11-cd"));
      } finally {
        chmodSync(infoFile, 0o600);
      }
      assert.equal(rCD1.status, 200);
      assert.equal(rCD1.noCache, true);
      assert.ok(JSON.parse(rCD1.body.toString("utf8")).infoError);
      const rCD2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "R11C", to: "R11D" }, "ik-r11-cd"));
      assert.equal(rCD2.status, 200);
      assert.equal(JSON.parse(rCD2.body.toString("utf8")).infoError, undefined);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const evCD = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r11-cd")!;
    assert.equal(evCD.pendingInfo, false);
    const info1 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info1.projects["R11D"]?.note, "r11-keep-note", "retried same-ms C->D must move note to R11D");
    assert.equal(info1.projects["R11C"], undefined, "R11C must be removed from PROJECTS.jsonl");

    // 2. P1-2: A->B paused in outbound peer RPC; while paused, recreate A thread + write new note to A;
    //    release peer -> new A keeps new note & thread, B keeps only old note!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "InfA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "InfA", note: "old-A-note", now: 100 });
    let releaseInfPeer!: () => void;
    const infPeerStarted = new Promise<void>((started) => {
      (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
        if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
        if (req.method === "projects.names") return { exists: false };
        if (req.method === "thread.classify" && req.rename?.from === "InfA") {
          started();
          await new Promise<void>((res) => { releaseInfPeer = res; });
          return classifyForPeer(peerEmpty.hub, req, ws);
        }
        return {};
      };
    });
    const pInfAB = dispatch(routes, reqWithKey("/projects/rename", { from: "InfA", to: "InfB" }, "ik-r11-inf"));
    await infPeerStarted;
    // While A->B is waiting on peer RPC, recreate InfA with a new thread and fresh note
    const [, tNewInfA] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "InfA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "InfA", note: "new-A-note", now: f.hub.store.now() + 1000 });
    releaseInfPeer();
    const rInfAB = await pInfAB;
    assert.equal(rInfAB.status, 200);
    assert.equal(f.hub.store.getThread(tNewInfA.id)?.project, "InfA", "recreated InfA thread must stay in InfA");
    const info2 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info2.projects["InfA"]?.note, "new-A-note", "recreated InfA must keep new-A-note");
    assert.equal(info2.projects["InfB"]?.note, "old-A-note", "InfB must keep only old-A-note");

    // 3. P1-3: Fixed clock T on coordinator: A->Z (save GET snapshot Z) then Z->B across two peers:
    //    (a) peerEmpty has no prior pref, receives A->Z then Z->B, then receives PUT of saved Z -> returns B & opens in B;
    //    (b) peerDelayed has prior A pref, misses A->Z initially, receives Z->B then retried A->Z, then receives PUT of saved Z -> stays B & opens in B (and rev:2 still wins)!
    const t3 = origNow() + 700_000;
    const p3 = await f.hub.presets.add(ws, { name: "P3", dirs: [] }, "alice@example.com", "u-p3");
    const p3Empty = await peerEmpty.hub.presets.add(ws, { name: "P3", dirs: [] }, "alice@example.com", "u-p3");
    const p3Del = await peerDelayed.hub.presets.add(ws, { name: "P3", dirs: [] }, "alice@example.com", "u-p3");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "MonoA" });
    f.hub.store.putPresetProjects(ws, "u-p3", JSON.stringify({ [p3.id]: { project: "MonoA", rev: 1, at: t3 - 50 } }));
    peerDelayed.hub.store.putPresetProjects(ws, "u-p3", JSON.stringify({ [p3Del.id]: { project: "MonoA", rev: 1, at: t3 - 50 } }));
    let dropDelayedAZ = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") {
        return {
          stations: [
            { id: "peer-empty", name: "Peer Empty", online: true },
            { id: "peer-delayed", name: "Peer Delayed", online: true },
          ],
        };
      }
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (station === "peer-empty") return classifyForPeer(peerEmpty.hub, req, ws);
        if (station === "peer-delayed") {
          if (dropDelayedAZ && req.rename?.from === "MonoA" && req.rename?.to === "MonoZ") {
            throw new Error("delayed peer dropped MonoA->MonoZ");
          }
          return classifyForPeer(peerDelayed.hub, req, ws);
        }
      }
      return {};
    };
    (f.hub.store as any).now = () => t3;
    let savedZEntry: any;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "MonoA", to: "MonoZ" }, "ik-r11-az"))).status, 200);
      const rGetZ = await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-p3" }));
      savedZEntry = JSON.parse(rGetZ.body.toString("utf8")).presetProjects[p3.id];
      assert.equal(savedZEntry.project, "MonoZ");
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "MonoZ", to: "MonoB" }, "ik-r11-zb"))).status, 200);
      // Now retry MonoA->MonoZ so peer-delayed receives it AFTER MonoZ->MonoB
      dropDelayedAZ = false;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "MonoA", to: "MonoZ" }, "ik-r11-az"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // (a) Empty peer receives stale savedZEntry -> migrates straight to MonoB & newSession opens in MonoB
    const rEmptyPut = await dispatch(
      peerEmptyPpRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [p3Empty.id]: savedZEntry } }, { workspace: ws, sub: "u-p3" }),
    );
    assert.equal(rEmptyPut.status, 200);
    assert.equal(JSON.parse(rEmptyPut.body.toString("utf8")).presetProjects[p3Empty.id].project, "MonoB");
    const [, tEmptyChat] = await newSession(peerEmpty.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-p3", ws, preset: p3Empty.id });
    assert.equal(tEmptyChat.project, "MonoB", "empty peer must open in MonoB after receiving stale Z snapshot");

    // (b) Delayed peer receives stale savedZEntry -> stays MonoB & newSession opens in MonoB; real rev:2 edit still wins!
    const rDelPut = await dispatch(
      peerDelayedPpRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [p3Del.id]: savedZEntry } }, { workspace: ws, sub: "u-p3" }),
    );
    assert.equal(rDelPut.status, 200);
    assert.equal(JSON.parse(rDelPut.body.toString("utf8")).presetProjects[p3Del.id].project, "MonoB");
    const [, tDelChat] = await newSession(peerDelayed.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-p3", ws, preset: p3Del.id });
    assert.equal(tDelChat.project, "MonoB", "delayed peer must open in MonoB after receiving stale Z snapshot");
    const rDelRev2 = await dispatch(
      peerDelayedPpRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [p3Del.id]: { project: "UserEditRev2", rev: 2, at: t3 } } }, { workspace: ws, sub: "u-p3" }),
    );
    assert.equal(rDelRev2.status, 200);
    assert.equal(JSON.parse(rDelRev2.body.toString("utf8")).presetProjects[p3Del.id].project, "UserEditRev2");
  } finally {
    await peerDelayed.close();
    await peerEmpty.close();
    await f.close();
  }
});

test("R12 Node Station exact state-machine regressions: repeated same-ms PUT info + retry moves note (no timestamp heuristic), wallAt preserves explicit rev:2 choice at same wall-ms T, and 4-state pending_info persists remote-only peer target registration across both peer retry and disk write failure", async () => {
  const { chmodSync, mkdirSync, writeFileSync } = await import("node:fs");
  const { projectsInfoPath, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer, projectNamesForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());

    // 1. P1-1: Fixed ms T: register A, then two updateProjectInfo calls -> A.updatedAt === T + 2;
    //    PROJECTS.jsonl unreadable on A->B (200 + infoError + noCache:true); restore & retry -> B has "latest" and A removed!
    const t1 = origNow() + 800_000;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R12A" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "R12A", note: "v1", now: t1 });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "R12A", note: "v2", now: t1 });
    const regLatest = await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "R12A", note: "latest", now: t1 });
    assert.ok((regLatest.doc.projects["R12A"]?.updatedAt ?? 0) >= t1 + 2, "repeated same-ms PUTs push A.updatedAt >= T + 2");
    (f.hub.store as any).now = () => t1;
    let r12AB1: any;
    try {
      chmodSync(infoFile, 0o000);
      try {
        r12AB1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "R12A", to: "R12B" }, "ik-r12-p1"));
      } finally {
        chmodSync(infoFile, 0o600);
      }
      assert.equal(r12AB1.status, 200);
      assert.equal(r12AB1.noCache, true);
      assert.ok(JSON.parse(r12AB1.body.toString("utf8")).infoError);
      const r12AB2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "R12A", to: "R12B" }, "ik-r12-p1"));
      assert.equal(r12AB2.status, 200);
      assert.equal(JSON.parse(r12AB2.body.toString("utf8")).infoError, undefined);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const ev12P1 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r12-p1")!;
    assert.equal(ev12P1.pendingInfo, false);
    assert.equal(ev12P1.pendingInfoState, 0);
    const infoP1 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoP1.projects["R12B"]?.note, "latest", "retry must unconditionally move R12A note to R12B even when A.updatedAt >= T + 2");
    assert.equal(infoP1.projects["R12A"], undefined);

    // 2. P1-2: Fixed wall-clock ms T: A->Z (renamedAt=T, wallAt=T), Z->B (renamedAt=T+1, wallAt=T);
    //    recreate Z thread, GET confirms B (rev=1), then explicit PUT { project: "Z", rev: 2, at: T } -> stays Z (rev=2) & opens in Z!
    const t2 = origNow() + 900_000;
    const pWall = await f.hub.presets.add(ws, { name: "WallPreset", dirs: [] }, "alice@example.com", "u-wall");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "WallA" });
    f.hub.store.putPresetProjects(ws, "u-wall", JSON.stringify({ [pWall.id]: { project: "WallA", rev: 1, at: t2 - 50 } }));
    (f.hub.store as any).now = () => t2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WallA", to: "WallZ" }, "ik-r12-az"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "WallZ", to: "WallB" }, "ik-r12-zb"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "WallZ" });
    const rWallGet = await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-wall" }));
    assert.equal(JSON.parse(rWallGet.body.toString("utf8")).presetProjects[pWall.id].project, "WallB");
    assert.equal(JSON.parse(rWallGet.body.toString("utf8")).presetProjects[pWall.id].rev, 1);
    const rWallPut = await dispatch(
      ppRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pWall.id]: { project: "WallZ", rev: 2, at: t2 } } }, { workspace: ws, sub: "u-wall" }),
    );
    assert.equal(rWallPut.status, 200);
    const afterWallPut = JSON.parse(rWallPut.body.toString("utf8")).presetProjects[pWall.id];
    assert.equal(afterWallPut.project, "WallZ", "explicit rev:2 choice at wall-clock T must NOT be replayed by WallZ->WallB");
    assert.equal(afterWallPut.rev, 2);
    const [, tWallChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-wall", ws, preset: pWall.id });
    assert.equal(tWallChat.project, "WallZ", "newSession must open in recreated WallZ");

    // 3a. P1-3a: Remote-only project (no local threads, no local PROJECTS.jsonl entry); first peer delivery fails -> retry succeeds -> B registered in coordinator PROJECTS.jsonl!
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "RemOnlyA" });
    let failRemPeer = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return projectNamesForPeer(peerRig.hub, ws, req.check);
      if (req.method === "thread.classify") {
        if (failRemPeer) throw new Error("peer transiently down");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    const rRem1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemOnlyA", to: "RemOnlyB" }, "ik-r12-rem-a"));
    assert.equal(rRem1.status, 200);
    assert.equal(rRem1.noCache, true);
    const evRem1 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r12-rem-a")!;
    assert.equal(evRem1.pendingInfoState, 2, "remote-only rename awaiting peer must enter pending_info = 2");
    failRemPeer = false;
    const rRem2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemOnlyA", to: "RemOnlyB" }, "ik-r12-rem-a"));
    assert.equal(rRem2.status, 200);
    assert.equal(rRem2.noCache, undefined);
    const evRem2 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r12-rem-a")!;
    assert.equal(evRem2.pendingInfoState, 0);
    assert.deepEqual(evRem2.pendingPeers, []);
    const info3a = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("RemOnlyB" in info3a.projects, "coordinator PROJECTS.jsonl must register RemOnlyB after peer reports updated=1");

    // 3b. P1-3b: Remote-only project; peer succeeds (updated=1), but coordinator PROJECTS.jsonl registration fails (chmod 0o000) -> pending_info=3 + infoError + noCache:true;
    //     restore file & retry -> 200, RemOnlyD registered in PROJECTS.jsonl, pending_info=0!
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "RemOnlyC" });
    mkdirSync(join(infoFile, ".."), { recursive: true });
    writeFileSync(infoFile, "", { flag: "a", mode: 0o600 });
    let lockFileOnClassify = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return projectNamesForPeer(peerRig.hub, ws, req.check);
      if (req.method === "thread.classify") {
        const res = await classifyForPeer(peerRig.hub, req, ws);
        if (lockFileOnClassify) chmodSync(infoFile, 0o000);
        return res;
      }
      return {};
    };
    let rRemB1: any;
    try {
      rRemB1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemOnlyC", to: "RemOnlyD" }, "ik-r12-rem-b"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rRemB1.status, 200);
    assert.equal(rRemB1.noCache, true);
    assert.ok(JSON.parse(rRemB1.body.toString("utf8")).infoError, "failed target registration must report infoError");
    const evRemB1 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r12-rem-b")!;
    assert.equal(evRemB1.pendingInfoState, 3, "failed target registration after peer updated=1 must stay in pending_info = 3");
    assert.deepEqual(evRemB1.pendingPeers, []);
    lockFileOnClassify = false;
    const rRemB2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemOnlyC", to: "RemOnlyD" }, "ik-r12-rem-b"));
    assert.equal(rRemB2.status, 200);
    assert.equal(JSON.parse(rRemB2.body.toString("utf8")).infoError, undefined);
    const evRemB2 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r12-rem-b")!;
    assert.equal(evRemB2.pendingInfoState, 0);
    const info3b = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("RemOnlyD" in info3b.projects, "retry must finish pending_info=3 and register RemOnlyD in PROJECTS.jsonl");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R13 Node Station final closure regressions: atomic PROJECTS.jsonl appliedOpIds across hard crash-restart, same-ms rebuilt Z across all 3 user classes, and persisted local_updated/remote_updated for remote-only peer rename", async () => {
  const { chmodSync } = await import("node:fs");
  const { projectsInfoPath, readProjectsInfoLenient, renameProjectInfo, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer, projectNamesForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerEmpty = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({ kept: f.hub.store, told: () => {} });
    const peerEmptyPpRoutes = presetProjectRoutes({ kept: peerEmpty.hub.store, told: () => {} });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);

    // 1. P1-1: Simulated hard crash between PROJECTS.jsonl atomic rename() and SQLite markRenameInfoState(0):
    //    reopen brand-new Store + Hub on same stillfail.db & agentHome, recreate CrashA with "fresh", retry original key -> CrashA keeps "fresh", CrashB keeps "original", pending_info=0!
    const fCrash = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
    try {
      await newSession(fCrash.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "CrashA" });
      await updateProjectInfo(fCrash.hub.config().agentHome, ws, fCrash.hub.homeWorkspace(), { name: "CrashA", note: "original", now: 100 });
      const crashOpId = "op-crash-atomic-1";
      const crashOpKey = "u1\0rename\0ik-r13-crash";
      const crashAt = fCrash.hub.store.now();
      fCrash.hub.store.commitLocalProjectRenameAtomic({
        ws,
        home: fCrash.hub.homeWorkspace(),
        action: "rename",
        from: "CrashA",
        to: "CrashB",
        renamedAt: crashAt,
        wallAt: crashAt,
        opKey: crashOpKey,
        opId: crashOpId,
        pendingPeers: [],
        pendingRoster: false,
        pendingInfo: true,
      });
      // Atomically move PROJECTS.jsonl with `opId` embedded, then DO NOT call markRenameInfoState (simulating instant process.exit!)
      const moved = await renameProjectInfo(fCrash.hub.config().agentHome, ws, fCrash.hub.homeWorkspace(), "CrashA", "CrashB", crashAt, {
        createIfMissing: true,
        opId: crashOpId,
      });
      assert.equal(moved.changed, true);

      // Verify public lenient read strips internal `appliedOpIds`
      const pub = await readProjectsInfoLenient(fCrash.hub.config().agentHome, ws, fCrash.hub.homeWorkspace());
      assert.equal((pub.projects["CrashB"] as any)?.appliedOpIds, undefined, "public GET /projects/info must never expose internal appliedOpIds");

      // Simulate hard restart: close Store & reopen brand-new Store + Hub on the exact same DB file & agentHome
      fCrash.store.close();
      fCrash.store = Store.open(join(fCrash.dir, "stillfail.db"));
      fCrash.hub = fCrash.newHub({ chats: () => undefined, link: true });
      const evBefore = fCrash.hub.store.findProjectRenameByOpKey(ws, crashOpKey)!;
      assert.equal(evBefore.pendingInfoState, 1, "reopened DB must still show pending_info = 1");
      // Recreate CrashA and write "fresh" note before retry
      await newSession(fCrash.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "CrashA" });
      await updateProjectInfo(fCrash.hub.config().agentHome, ws, fCrash.hub.homeWorkspace(), { name: "CrashA", note: "fresh", now: crashAt + 100 });
      const crashRoutes = projectRoutes({ store: fCrash.hub.store, agents: { hub: fCrash.hub } as any, data: fCrash.dir } as any);
      const rCrashRetry = await dispatch(crashRoutes, reqWithKey("/projects/rename", { from: "CrashA", to: "CrashB" }, "ik-r13-crash"));
      assert.equal(rCrashRetry.status, 200);
      assert.equal(JSON.parse(rCrashRetry.body.toString("utf8")).infoError, undefined);
      const evAfter = fCrash.hub.store.findProjectRenameByOpKey(ws, crashOpKey)!;
      assert.equal(evAfter.pendingInfoState, 0, "retry must clear pending_info = 0");
      const infoCrash = await readProjectsInfoStrict(fCrash.hub.config().agentHome, ws, fCrash.hub.homeWorkspace());
      assert.equal(infoCrash.projects["CrashA"]?.note, "fresh", "recreated CrashA's fresh note must be untouched");
      assert.equal(infoCrash.projects["CrashB"]?.note, "original", "CrashB must keep only original note");
    } finally {
      await fCrash.close();
    }

    // 2. P1-2: Fixed wall-clock T: A->Z, Z->B, rebuild Z thread; all 3 user classes (was A->B, was Other, first-time setter) stay on Z & open in Z;
    //    meanwhile peerEmpty (where Z was NOT rebuilt) still migrates stale Z (rev=1, at=T) to B!
    const t2 = origNow() + 1_100_000;
    const pCls = await f.hub.presets.add(ws, { name: "ClsPreset", dirs: [] }, "alice@example.com", "u-cls-1");
    const pEmpty = await peerEmpty.hub.presets.add(ws, { name: "ClsPreset", dirs: [] }, "alice@example.com", "u-cls-empty");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ClsA" });
    f.hub.store.putPresetProjects(ws, "u-cls-1", JSON.stringify({ [pCls.id]: { project: "ClsA", rev: 1, at: t2 - 50 } }));
    f.hub.store.putPresetProjects(ws, "u-cls-2", JSON.stringify({ [pCls.id]: { project: "Other", rev: 1, at: t2 - 50 } }));
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-empty", name: "Peer Empty", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") return classifyForPeer(peerEmpty.hub, req, ws);
      return {};
    };
    (f.hub.store as any).now = () => t2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "ClsA", to: "ClsZ" }, "ik-r13-az"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "ClsZ", to: "ClsB" }, "ik-r13-zb"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Rebuild ClsZ thread on coordinator (NOT on peerEmpty)
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ClsZ" });
    // User 1 (was A->B): rev=2, at=T
    const rU1 = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCls.id]: { project: "ClsZ", rev: 2, at: t2 } } }, { workspace: ws, sub: "u-cls-1" }));
    assert.equal(JSON.parse(rU1.body.toString("utf8")).presetProjects[pCls.id].project, "ClsZ");
    const [, tU1] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-cls-1", ws, preset: pCls.id });
    assert.equal(tU1.project, "ClsZ");
    // User 2 (was Other): rev=2, at=T
    const rU2 = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCls.id]: { project: "ClsZ", rev: 2, at: t2 } } }, { workspace: ws, sub: "u-cls-2" }));
    assert.equal(JSON.parse(rU2.body.toString("utf8")).presetProjects[pCls.id].project, "ClsZ");
    const [, tU2] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-cls-2", ws, preset: pCls.id });
    assert.equal(tU2.project, "ClsZ");
    // User 3 (first-time setter): rev=1, at=T
    const rU3 = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCls.id]: { project: "ClsZ", rev: 1, at: t2 } } }, { workspace: ws, sub: "u-cls-3" }));
    assert.equal(JSON.parse(rU3.body.toString("utf8")).presetProjects[pCls.id].project, "ClsZ");
    const [, tU3] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-cls-3", ws, preset: pCls.id });
    assert.equal(tU3.project, "ClsZ");
    // Empty peer (ClsZ NOT rebuilt there): stale Z (rev=1, at=T) still migrates to ClsB!
    const rEmptyStale = await dispatch(peerEmptyPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pEmpty.id]: { project: "ClsZ", rev: 1, at: t2 } } }, { workspace: ws, sub: "u-cls-empty" }));
    assert.equal(JSON.parse(rEmptyStale.body.toString("utf8")).presetProjects[pEmpty.id].project, "ClsB");

    // 3a. P1-3a: Remote-only peer commits updated=1, response is dropped; retry dedups on peer & STILL returns updated=1 -> coordinator registers B!
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "DupRemA" });
    let dropAfterPeerCommit = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return projectNamesForPeer(peerRig.hub, ws, req.check);
      if (req.method === "thread.classify") {
        const res = await classifyForPeer(peerRig.hub, req, ws);
        if (dropAfterPeerCommit) throw new Error("response dropped after peer commit");
        return res;
      }
      return {};
    };
    const rDup1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "DupRemA", to: "DupRemB" }, "ik-r13-dup"));
    assert.equal(rDup1.status, 200);
    assert.equal(rDup1.noCache, true);
    dropAfterPeerCommit = false;
    const rDup2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "DupRemA", to: "DupRemB" }, "ik-r13-dup"));
    assert.equal(rDup2.status, 200);
    const evDup = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r13-dup")!;
    assert.equal(evDup.pendingInfoState, 0);
    assert.deepEqual(evDup.pendingPeers, []);
    const info3a = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("DupRemB" in info3a.projects, "peer dedup must return persisted local_updated=1 so coordinator registers DupRemB");

    // 3b. P1-3b: Remote-only project; Phase 1 fails to read PROJECTS.jsonl (chmod 0o000 -> pending_info=1) while peer succeeds (updated=1 -> remote_updated=1);
    //     restore file & retry -> coordinator registers RemFailB and clears all pending!
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "RemFailA" });
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return projectNamesForPeer(peerRig.hub, ws, req.check);
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    let rRemFail1: any;
    chmodSync(infoFile, 0o000);
    try {
      rRemFail1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemFailA", to: "RemFailB" }, "ik-r13-remfail"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rRemFail1.status, 200);
    assert.equal(rRemFail1.noCache, true);
    const evRF1 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r13-remfail")!;
    assert.equal(evRF1.pendingInfoState, 1);
    assert.equal(evRF1.remoteUpdated, true, "remote_updated=1 must be persisted even while pending_info=1");
    assert.deepEqual(evRF1.pendingPeers, []);
    const rRemFail2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "RemFailA", to: "RemFailB" }, "ik-r13-remfail"));
    assert.equal(rRemFail2.status, 200);
    assert.equal(JSON.parse(rRemFail2.body.toString("utf8")).infoError, undefined);
    const evRF2 = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r13-remfail")!;
    assert.equal(evRF2.pendingInfoState, 0);
    const info3b = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("RemFailB" in info3b.projects, "retry after Phase 1 file failure must use remote_updated=1 to register RemFailB");
  } finally {
    await peerEmpty.close();
    await peerRig.close();
    await f.close();
  }
});

test("R14 Node Station ultimate closure regressions: tombstone/18-chain pinned appliedOpIds + prune, cross-peer carried Z logical clock bump & info-only rebuilt Z, atomic markRenamePeersResolved rollback + peer opId replay, P2-1 localUpdated continuation, and P2-2 set_info strips appliedOpIds", async () => {
  const { chmodSync } = await import("node:fs");
  const { projectsInfoPath, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer, projectManage, projectNamesForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({
      kept: f.hub.store,
      told: () => {},
      agentHome: () => f.hub.config().agentHome,
      homeWorkspace: () => f.hub.homeWorkspace(),
    });
    const peerPpRoutes = presetProjectRoutes({
      kept: peerRig.hub.store,
      told: () => {},
      agentHome: () => peerRig.hub.config().agentHome,
      homeWorkspace: () => peerRig.hub.homeWorkspace(),
    });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());

    // 1. P1-1A: TombA -> "" (merge into cross-project) where ONLY SQLite markRenameInfoState fails -> recreate TombA + fresh note -> retry returns 200, TombA & fresh note preserved, appliedOpIds pruned!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "TombA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "TombA", note: "old-tomb", now: 100 });
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_r14_tomb BEFORE UPDATE OF pending_info ON project_rename_events
      WHEN OLD.from_name = 'TombA' AND NEW.pending_info = 0
      BEGIN SELECT RAISE(ABORT, 'injected tomb mark failure'); END;
    `);
    const rTomb1 = await dispatch(routes, reqWithKey("/projects/merge", { from: "TombA", to: "" }, "ik-r14-tomb"));
    assert.equal(rTomb1.status, 200);
    assert.equal(rTomb1.noCache, true);
    assert.ok(JSON.parse(rTomb1.body.toString("utf8")).infoError);
    f.hub.store.db.exec("DROP TRIGGER fail_r14_tomb");
    const [, tTombNew] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "TombA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), {
      name: "TombA",
      note: "fresh-tomb",
      now: f.hub.store.now() + 100,
      keepOpIds: f.hub.store.listPendingRenameInfoOpIds(ws),
    });
    const rTomb2 = await dispatch(routes, reqWithKey("/projects/merge", { from: "TombA", to: "" }, "ik-r14-tomb"));
    assert.equal(rTomb2.status, 200);
    assert.equal(JSON.parse(rTomb2.body.toString("utf8")).infoError, undefined);
    assert.equal(f.hub.store.getThread(tTombNew.id)?.project, "TombA", "recreated TombA thread must remain intact");
    const infoTomb = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoTomb.projects["TombA"]?.note, "fresh-tomb", "recreated TombA fresh note must survive retry");
    assert.equal(infoTomb.projects["TombA"]?.appliedOpIds, undefined, "confirmed appliedOpIds must be pruned after SQLite confirms");

    // 2. P1-1B: N0 -> N1 fails only SQLite mark -> 18 consecutive renames N1->N2->...->N19 -> recreate N0 + fresh note -> retry N0->N1 preserves N0 and never merges into N19!
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "N0" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "N0", note: "orig-N0", now: 100 });
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_r14_n0 BEFORE UPDATE OF pending_info ON project_rename_events
      WHEN OLD.from_name = 'N0' AND NEW.pending_info = 0
      BEGIN SELECT RAISE(ABORT, 'injected N0 mark failure'); END;
    `);
    const rN0Fail = await dispatch(routes, reqWithKey("/projects/rename", { from: "N0", to: "N1" }, "ik-r14-n0"));
    assert.equal(rN0Fail.status, 200);
    assert.ok(JSON.parse(rN0Fail.body.toString("utf8")).infoError);
    f.hub.store.db.exec("DROP TRIGGER fail_r14_n0");
    for (let i = 1; i <= 18; i++) {
      const rStep = await dispatch(routes, reqWithKey("/projects/rename", { from: `N${i}`, to: `N${i + 1}` }, `ik-r14-n-${i}`));
      assert.equal(rStep.status, 200);
    }
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "N0" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), {
      name: "N0",
      note: "fresh-N0",
      now: f.hub.store.now() + 500,
      keepOpIds: f.hub.store.listPendingRenameInfoOpIds(ws),
    });
    const rN0Retry = await dispatch(routes, reqWithKey("/projects/rename", { from: "N0", to: "N1" }, "ik-r14-n0"));
    assert.equal(rN0Retry.status, 200);
    assert.equal(JSON.parse(rN0Retry.body.toString("utf8")).infoError, undefined);
    const infoChain = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(infoChain.projects["N0"]?.note, "fresh-N0", "pinned pending opId must NOT be evicted across 18 renames");
    assert.equal(infoChain.projects["N19"]?.note, "orig-N0", "N19 must keep only orig-N0, never absorb fresh-N0");

    // 3. P1-2A: Frozen wall-clock T: S1 runs A->Z->B synced to peer S2 (no Z thread) -> S1 rebuilds Z -> explicit Z (rev=2, at=T) carried S1->S2->S1 stays Z & opens in Z on BOTH;
    //    truly stale (at=T-1) still migrates to B; subsequent same-ms Z->C migrates to C on BOTH!
    const t2 = origNow() + 1_300_000;
    const pCarry1 = await f.hub.presets.add(ws, { name: "CarryP", dirs: [] }, "alice@example.com", "u-carry");
    const pCarry2 = await peerRig.hub.presets.add(ws, { name: "CarryP", dirs: [] }, "alice@example.com", "u-carry");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "CarA" });
    f.hub.store.putPresetProjects(ws, "u-carry", JSON.stringify({ [pCarry1.id]: { project: "CarA", rev: 1, at: t2 - 10 } }));
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    (f.hub.store as any).now = () => t2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "CarA", to: "CarZ" }, "ik-r14-az"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "CarZ", to: "CarB" }, "ik-r14-zb"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Rebuild CarZ on S1 (NOT on S2)
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "CarZ" });
    const rS1Z = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCarry1.id]: { project: "CarZ", rev: 2, at: t2 } } }, { workspace: ws, sub: "u-carry" }));
    const s1Entry = JSON.parse(rS1Z.body.toString("utf8")).presetProjects[pCarry1.id];
    assert.equal(s1Entry.project, "CarZ");
    assert.equal(s1Entry.rev, 2);
    assert.equal(s1Entry.at, t2, "S1 must keep user choice wall-clock at immutable");
    assert.equal(s1Entry.ren, t2 + 1, "S1 must advance logical ren past skipped CarZ->CarB while keeping rev=2 & at=t2");
    // Carry S1 response verbatim to S2 (which has NO CarZ thread!)
    const rS2Z = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCarry2.id]: s1Entry } }, { workspace: ws, sub: "u-carry" }));
    const s2Entry = JSON.parse(rS2Z.body.toString("utf8")).presetProjects[pCarry2.id];
    assert.equal(s2Entry.project, "CarZ", "S2 without local CarZ thread must preserve carried CarZ");
    // Carry S2 response back to S1
    const rS1Back = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCarry1.id]: s2Entry } }, { workspace: ws, sub: "u-carry" }));
    assert.equal(JSON.parse(rS1Back.body.toString("utf8")).presetProjects[pCarry1.id].project, "CarZ");
    const [, tS1Open] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-carry", ws, preset: pCarry1.id });
    const [, tS2Open] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-carry", ws, preset: pCarry2.id });
    assert.equal(tS1Open.project, "CarZ");
    assert.equal(tS2Open.project, "CarZ");
    // Truly stale snapshot (at = T - 1) still migrates to CarB
    const rStaleOld = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCarry2.id]: { project: "CarZ", rev: 1, at: t2 - 1 } } }, { workspace: ws, sub: "u-stale-old" }));
    assert.equal(JSON.parse(rStaleOld.body.toString("utf8")).presetProjects[pCarry2.id].project, "CarB");
    // Subsequent same-ms CarZ -> CarC migrates BOTH S1 and S2 directly to CarC!
    (f.hub.store as any).now = () => t2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "CarZ", to: "CarC" }, "ik-r14-zc"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const [, tS1C] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-carry", ws, preset: pCarry1.id });
    const [, tS2C] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-carry", ws, preset: pCarry2.id });
    assert.equal(tS1C.project, "CarC", "subsequent same-ms CarZ->CarC must migrate S1 to CarC");
    assert.equal(tS2C.project, "CarC", "subsequent same-ms CarZ->CarC must migrate S2 directly to CarC");

    // 4. P1-2B: Single station frozen wall-clock T: A->Z->B then rebuild Z ONLY via PUT /projects/info (no local thread, home workspace) -> first-time pick Z stays Z & opens in Z!
    (f.hub as any).peersInWorkspace = () => null;
    const tInfoOnly = origNow() + 1_400_000;
    const pInfoOnly = await f.hub.presets.add(ws, { name: "InfoOnlyP", dirs: [] }, "alice@example.com", "u-info-only");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "IoA" });
    (f.hub.store as any).now = () => tInfoOnly;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "IoA", to: "IoZ" }, "ik-r14-io1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "IoZ", to: "IoB" }, "ik-r14-io2"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const rPutIoZ = await dispatch(routes, makeReq("PUT", "/projects/info", { name: "IoZ", note: "rebuilt-info-only" }, { workspace: ws }));
    assert.equal(rPutIoZ.status, 200);
    const rPickIoZ = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pInfoOnly.id]: { project: "IoZ", rev: 1, at: tInfoOnly } } }, { workspace: ws, sub: "u-info-only" }));
    assert.equal(JSON.parse(rPickIoZ.body.toString("utf8")).presetProjects[pInfoOnly.id].project, "IoZ", "info-only rebuilt IoZ must be recognized as active");
    const [, tIoZChat] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-info-only", ws, preset: pInfoOnly.id });
    assert.equal(tIoZChat.project, "IoZ");

    // 5. P1-3: Remote-only peer thread renamed to PeerB; trigger fails ONLY coordinator's atomic markRenamePeersResolved tx -> drop trigger & retry -> peer replays opId with updated=1 -> PeerB registered!
    await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "PeerA" });
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return projectNamesForPeer(peerRig.hub, ws, req.check);
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_r14_peer_tx BEFORE UPDATE OF pending_peers ON project_rename_events
      WHEN OLD.from_name = 'PeerA'
      BEGIN SELECT RAISE(ABORT, 'injected atomic peer tx failure'); END;
    `);
    const rPeerTxFail = await dispatch(routes, reqWithKey("/projects/rename", { from: "PeerA", to: "PeerB" }, "ik-r14-peer-tx"));
    assert.equal(rPeerTxFail.status, 500, "failed atomic markRenamePeersResolved tx must abort cleanly");
    f.hub.store.db.exec("DROP TRIGGER fail_r14_peer_tx");
    const rPeerTxRetry = await dispatch(routes, reqWithKey("/projects/rename", { from: "PeerA", to: "PeerB" }, "ik-r14-peer-tx"));
    assert.equal(rPeerTxRetry.status, 200);
    const evPeerTx = f.hub.store.findProjectRenameByOpKey(ws, "u1\0rename\0ik-r14-peer-tx")!;
    assert.deepEqual(evPeerTx.pendingPeers, []);
    assert.equal(evPeerTx.pendingInfoState, 0);
    const infoPeerB = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("PeerB" in infoPeerB.projects, "retry after markRenamePeersResolved rollback must register PeerB via peer opId replay");

    // 6a. P2-1: Delete SoloA metadata while keeping local thread; chmod 0o000 on PROJECTS.jsonl during SoloA->SoloB; restore & retry -> SoloB registered!
    (f.hub as any).peersInWorkspace = () => null;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "SoloA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "SoloA", delete: true, now: f.hub.store.now() + 10 });
    let rSolo1: any;
    chmodSync(infoFile, 0o000);
    try {
      rSolo1 = await dispatch(routes, reqWithKey("/projects/rename", { from: "SoloA", to: "SoloB" }, "ik-r14-solo"));
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(rSolo1.status, 200);
    assert.equal(rSolo1.noCache, true);
    const rSolo2 = await dispatch(routes, reqWithKey("/projects/rename", { from: "SoloA", to: "SoloB" }, "ik-r14-solo"));
    assert.equal(rSolo2.status, 200);
    const infoSolo = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.ok("SoloB" in infoSolo.projects, "P2-1 retry must use persisted localUpdated>0 to register SoloB");

    // 6b. P2-2: ToolA -> ToolB then projectManage(set_info) must strip internal appliedOpIds from response!
    const [kTool] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ToolA" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "ToolA", note: "t-orig", now: 100 });
    assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "ToolA", to: "ToolB" }, "ik-r14-tool"))).status, 200);
    const setInfoRaw = await projectManage(f.hub, kTool, { action: "set_info", args: { name: "ToolB", note: "t-clean" } });
    const setInfoRes = JSON.parse(setInfoRaw);
    assert.equal(setInfoRes.info?.note, "t-clean");
    assert.equal(setInfoRes.info?.appliedOpIds, undefined, "project_manage set_info must strip internal appliedOpIds");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R15 Node Station final 4 closure regressions: concurrent PUT /preset-projects zero lost update, delayed older rename respects chosenAt, 65 pending opIds lossless parse, and unreadable PROJECTS.jsonl returns retryable 503 + noCache", async () => {
  const { chmodSync } = await import("node:fs");
  const { Admin } = await import("../src/api/admin.ts");
  const { projectsInfoPath, updateProjectInfo } = await import("../src/projects/info.ts");
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const peerPpRoutes = presetProjectRoutes({
      kept: peerRig.hub.store,
      told: () => {},
      agentHome: () => peerRig.hub.config().agentHome,
      homeWorkspace: () => peerRig.hub.homeWorkspace(),
    });
    const admin = new Admin({ data: f.dir, names: new Map() } as any, { store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir });
    const reqWithKey = (method: string, path: string, body: unknown, idemKey?: string, sub = "u1") => {
      const r = makeReq(method, path, body, { workspace: ws, sub });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);
    const infoFile = projectsInfoPath(f.hub.config().agentHome, ws, f.hub.homeWorkspace());

    // 1. P1-1: Concurrent PUT /preset-projects (including one hitting async narrow-window PROJECTS.jsonl read) -> zero lost updates!
    const tConc = origNow() + 1_500_000;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "ConcA" });
    (f.hub.store as any).now = () => tConc;
    try {
      assert.equal((await admin.handle(reqWithKey("POST", "/projects/rename", { from: "ConcA", to: "ConcZ" }, "ik-r15-c1"))).status, 200);
      assert.equal((await admin.handle(reqWithKey("POST", "/projects/rename", { from: "ConcZ", to: "ConcB" }, "ik-r15-c2"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "ConcZ", note: "rebuilt", now: tConc + 10 });
    // Concurrent pair 1: two disjoint non-window keys
    const [rC1, rC2] = await Promise.all([
      admin.handle(reqWithKey("PUT", "/preset-projects", { presetProjects: { one: { project: "East", rev: 1, at: tConc } } }, "ik-r15-put-1", "u-conc")),
      admin.handle(reqWithKey("PUT", "/preset-projects", { presetProjects: { two: { project: "West", rev: 1, at: tConc } } }, "ik-r15-put-2", "u-conc")),
    ]);
    assert.equal(rC1.status, 200);
    assert.equal(rC2.status, 200);
    const rCGet1 = await admin.handle(reqWithKey("GET", "/preset-projects", undefined, undefined, "u-conc"));
    const cMap1 = JSON.parse(rCGet1.body.toString("utf8")).presetProjects;
    assert.equal(cMap1.one?.project, "East");
    assert.equal(cMap1.two?.project, "West");
    // Concurrent pair 2: one hits async narrow-window read for info-only ConcZ while other writes `three=North`
    const [rC3, rC4] = await Promise.all([
      admin.handle(reqWithKey("PUT", "/preset-projects", { presetProjects: { zKey: { project: "ConcZ", rev: 1, at: tConc } } }, "ik-r15-put-3", "u-conc")),
      admin.handle(reqWithKey("PUT", "/preset-projects", { presetProjects: { three: { project: "North", rev: 1, at: tConc } } }, "ik-r15-put-4", "u-conc")),
    ]);
    assert.equal(rC3.status, 200);
    assert.equal(rC4.status, 200);
    const rCGet2 = await admin.handle(reqWithKey("GET", "/preset-projects", undefined, undefined, "u-conc"));
    const cMap2 = JSON.parse(rCGet2.body.toString("utf8")).presetProjects;
    assert.equal(cMap2.zKey?.project, "ConcZ", "narrow-window async PUT must preserve ConcZ");
    assert.equal(cMap2.three?.project, "North", "concurrent PUT during async read must NOT be lost");

    // 2. P1-2: Dual-hub same clock: T A->B reaches peer; T+100 A->C dropped; T+200 user picks A (both fresh & rev:2 from B);
    //    delayed T+100 A->C delivered -> BOTH stay A; subsequent T+300 A->D -> BOTH migrate to D!
    const tDel = origNow() + 1_600_000;
    const pDel = await peerRig.hub.presets.add(ws, { name: "DelPreset", dirs: [] }, "alice@example.com", "u-del-1");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "DelA" });
    peerRig.hub.store.putPresetProjects(ws, "u-del-2", JSON.stringify({ [pDel.id]: { project: "DelA", rev: 1, at: tDel - 50 } }));
    let dropAC = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (dropAC && req.rename?.from === "DelA" && req.rename?.to === "DelC") throw new Error("drop DelA->DelC");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    (f.hub.store as any).now = () => tDel;
    try {
      assert.equal((await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: "DelA", to: "DelB" }, "ik-r15-dab"))).status, 200);
      await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "DelA" });
      (f.hub.store as any).now = () => tDel + 100;
      assert.equal((await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: "DelA", to: "DelC" }, "ik-r15-dac"))).status, 200);
      // T+200: recreate DelA and explicitly choose DelA on peer for both fresh user (u-del-1) and previously-migrated user (u-del-2)
      await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "DelA" });
      const rPick1 = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pDel.id]: { project: "DelA", rev: 1, at: tDel + 200 } } }, { workspace: ws, sub: "u-del-1" }));
      assert.equal(JSON.parse(rPick1.body.toString("utf8")).presetProjects[pDel.id].project, "DelA");
      const rPick2 = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pDel.id]: { project: "DelA", rev: 2, at: tDel + 200 } } }, { workspace: ws, sub: "u-del-2" }));
      assert.equal(JSON.parse(rPick2.body.toString("utf8")).presetProjects[pDel.id].project, "DelA");
      // Deliver delayed T+100 DelA->DelC to peer
      dropAC = false;
      assert.equal((await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: "DelA", to: "DelC" }, "ik-r15-dac"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Both users MUST stay on DelA (not overridden by delayed T+100 DelA->DelC)!
    assert.equal(JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-del-1" }))).body.toString("utf8")).presetProjects[pDel.id].project, "DelA");
    assert.equal(JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-del-2" }))).body.toString("utf8")).presetProjects[pDel.id].project, "DelA");
    const [, tDelOpen1] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del-1", ws, preset: pDel.id });
    const [, tDelOpen2] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del-2", ws, preset: pDel.id });
    assert.equal(tDelOpen1.project, "DelA");
    assert.equal(tDelOpen2.project, "DelA");
    // Now send real T+300 DelA->DelD -> BOTH users migrate to DelD!
    (f.hub.store as any).now = () => tDel + 300;
    try {
      assert.equal((await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: "DelA", to: "DelD" }, "ik-r15-dad"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const [, tDelD1] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del-1", ws, preset: pDel.id });
    const [, tDelD2] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del-2", ws, preset: pDel.id });
    assert.equal(tDelD1.project, "DelD");
    assert.equal(tDelD2.project, "DelD");

    // 3. P1-3: 65 consecutive renames N0->N1->...->N65 all fail SQLite pending_info=0 mark -> restore SQLite -> recreate N0 + fresh note -> retry N0->N1 preserves N0!
    (f.hub as any).peersInWorkspace = () => null;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "P65_0" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "P65_0", note: "orig-65", now: 100 });
    f.hub.store.db.exec(`
      CREATE TRIGGER fail_r15_65 BEFORE UPDATE OF pending_info ON project_rename_events
      WHEN OLD.from_name LIKE 'P65_%' AND NEW.pending_info = 0
      BEGIN SELECT RAISE(ABORT, 'injected 65 mark failure'); END;
    `);
    try {
      for (let i = 0; i < 65; i++) {
        const r = await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: `P65_${i}`, to: `P65_${i + 1}` }, `ik-r15-65-${i}`));
        assert.equal(r.status, 200);
        assert.ok(JSON.parse(r.body.toString("utf8")).infoError);
      }
    } finally {
      f.hub.store.db.exec("DROP TRIGGER fail_r15_65");
    }
    assert.equal(f.hub.store.listPendingRenameInfoOpIds(ws).size, 65, "all 65 pending opIds must be tracked");
    const [, tP65New] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "P65_0" });
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), {
      name: "P65_0",
      note: "fresh-65",
      now: f.hub.store.now() + 1000,
      keepOpIds: f.hub.store.listPendingRenameInfoOpIds(ws),
    });
    const r65Retry = await dispatch(routes, reqWithKey("POST", "/projects/rename", { from: "P65_0", to: "P65_1" }, "ik-r15-65-0"));
    assert.equal(r65Retry.status, 200);
    assert.equal(JSON.parse(r65Retry.body.toString("utf8")).infoError, undefined);
    assert.equal(f.hub.store.getThread(tP65New.id)?.project, "P65_0");
    const info65 = await readProjectsInfoStrict(f.hub.config().agentHome, ws, f.hub.homeWorkspace());
    assert.equal(info65.projects["P65_0"]?.note, "fresh-65", "65th-oldest pending opId must NOT be truncated during parse");
    assert.equal(info65.projects["P65_65"]?.note, "orig-65");

    // 4. P2-1: Unreadable PROJECTS.jsonl during narrow window returns retryable 503 (noCache) without mutating pref; restoring file allows same-key retry -> 200 with Z!
    const t503 = origNow() + 1_700_000;
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "Err503A" });
    (f.hub.store as any).now = () => t503;
    try {
      assert.equal((await admin.handle(reqWithKey("POST", "/projects/rename", { from: "Err503A", to: "Err503Z" }, "ik-r15-503-1"))).status, 200);
      assert.equal((await admin.handle(reqWithKey("POST", "/projects/rename", { from: "Err503Z", to: "Err503B" }, "ik-r15-503-2"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    await updateProjectInfo(f.hub.config().agentHome, ws, f.hub.homeWorkspace(), { name: "Err503Z", note: "only-note", now: t503 + 10 });
    let r503Fail: any;
    chmodSync(infoFile, 0o000);
    try {
      r503Fail = await admin.handle(
        reqWithKey("PUT", "/preset-projects", { presetProjects: { p503: { project: "Err503Z", rev: 1, at: t503 } } }, "ik-r15-503-put", "u-503"),
      );
    } finally {
      chmodSync(infoFile, 0o600);
    }
    assert.equal(r503Fail.status, 503, "unreadable PROJECTS.jsonl in narrow window must return 503");
    assert.equal(f.hub.store.presetProjects(ws, "u-503"), null, "503 must NOT persist or rewrite preference to Err503B");
    const r503Retry = await admin.handle(
      reqWithKey("PUT", "/preset-projects", { presetProjects: { p503: { project: "Err503Z", rev: 1, at: t503 } } }, "ik-r15-503-put", "u-503"),
    );
    assert.equal(r503Retry.status, 200, "same Idempotency-Key retry after 503 must succeed");
    assert.equal(JSON.parse(r503Retry.body.toString("utf8")).presetProjects.p503.project, "Err503Z");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R16 Node Station final wallAt-strict closure regressions: multi-rename same-wall-ms logical drift (wallAt=T, renamedAt=T+2) never overrides explicit T+1 choice on either ordered or delayed peer delivery", async () => {
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({
      kept: f.hub.store,
      told: () => {},
      agentHome: () => f.hub.config().agentHome,
      homeWorkspace: () => f.hub.homeWorkspace(),
    });
    const peerPpRoutes = presetProjectRoutes({
      kept: peerRig.hub.store,
      told: () => {},
      agentHome: () => peerRig.hub.config().agentHome,
      homeWorkspace: () => peerRig.hub.homeWorkspace(),
    });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);

    // 1. Ordered delivery: at wallAt=T coordinator runs X->Y (T), Else->Next (T+1), A->C (wallAt=T, renamedAt=T+2), all 200 on peer;
    //    clock advances to T+1, coordinator rebuilds A, user submits { project: "A", rev: 2, at: T+1 } on peer -> peer PUT/GET/newSession AND carry back to coord ALL stay A;
    //    subsequent T+2 A->D still migrates to D!
    const t1 = origNow() + 1_900_000;
    const pOrd1 = await f.hub.presets.add(ws, { name: "Ord16", dirs: [] }, "alice@example.com", "u-ord16");
    const pOrd2 = await peerRig.hub.presets.add(ws, { name: "Ord16", dirs: [] }, "alice@example.com", "u-ord16");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdX" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdElse" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdA" });
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };
    (f.hub.store as any).now = () => t1;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdX", to: "OrdY" }, "ik-r16-o1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdElse", to: "OrdNext" }, "ik-r16-o2"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdA", to: "OrdC" }, "ik-r16-o3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    // Clock advances to T+1; coordinator rebuilds OrdA; user submits { project: "OrdA", rev: 2, at: T+1 } on peer
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "OrdA" });
    const rPeerOrdPut = await dispatch(
      peerPpRoutes,
      makeReq("PUT", "/preset-projects", { presetProjects: { [pOrd2.id]: { project: "OrdA", rev: 2, at: t1 + 1 } } }, { workspace: ws, sub: "u-ord16" }),
    );
    assert.equal(rPeerOrdPut.status, 200);
    const peerOrdEntry = JSON.parse(rPeerOrdPut.body.toString("utf8")).presetProjects[pOrd2.id];
    assert.equal(peerOrdEntry.project, "OrdA", "explicit choice at T+1 (> wallAt=T) must NOT be overridden by drifted renamedAt=T+2");
    assert.equal(JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-ord16" }))).body.toString("utf8")).presetProjects[pOrd2.id].project, "OrdA");
    const [, tOrdPeerOpen] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-ord16", ws, preset: pOrd2.id });
    assert.equal(tOrdPeerOpen.project, "OrdA");
    // Carry back to coordinator -> also stays OrdA
    const rCoordBack = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pOrd1.id]: peerOrdEntry } }, { workspace: ws, sub: "u-ord16" }));
    assert.equal(JSON.parse(rCoordBack.body.toString("utf8")).presetProjects[pOrd1.id].project, "OrdA");
    // Subsequent real rename at T+2 OrdA -> OrdD still migrates to OrdD!
    (f.hub.store as any).now = () => t1 + 2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "OrdA", to: "OrdD" }, "ik-r16-o4"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const [, tOrdPeerD] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-ord16", ws, preset: pOrd2.id });
    assert.equal(tOrdPeerD.project, "OrdD", "real T+2 rename OrdA->OrdD must migrate peer to OrdD");

    // 2. Delayed delivery: at wallAt=T coordinator runs A->B (T), Else->Next (T+1) delivered to peer, and A->C (wallAt=T, renamedAt=T+2) dropped;
    //    at T+1 coordinator rebuilds A, two users (rev:2 from B, and first-time rev:1) submit A@T+1 on peer;
    //    retrying delayed A->C to peer keeps BOTH on A; subsequent T+2 A->D migrates BOTH to D!
    const t2 = origNow() + 2_000_000;
    const pDel = await peerRig.hub.presets.add(ws, { name: "Del16", dirs: [] }, "alice@example.com", "u-del16-a");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "LagA" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "LagElse" });
    peerRig.hub.store.putPresetProjects(ws, "u-del16-a", JSON.stringify({ [pDel.id]: { project: "LagA", rev: 1, at: t2 - 50 } }));
    let dropLagAC = true;
    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (dropLagAC && req.rename?.from === "LagA" && req.rename?.to === "LagC") throw new Error("drop LagA->LagC");
        return classifyForPeer(peerRig.hub, req, ws);
      }
      return {};
    };
    (f.hub.store as any).now = () => t2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LagA", to: "LagB" }, "ik-r16-d1"))).status, 200);
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LagElse", to: "LagNext" }, "ik-r16-d2"))).status, 200);
      await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "LagA" });
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LagA", to: "LagC" }, "ik-r16-d3"))).status, 200);
      // At T+1 coordinator rebuilds LagA; users submit LagA@T+1 (both rev:2 from LagB and first-time rev:1) on peer
      await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "LagA" });
      const rDelA = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pDel.id]: { project: "LagA", rev: 2, at: t2 + 1 } } }, { workspace: ws, sub: "u-del16-a" }));
      assert.equal(JSON.parse(rDelA.body.toString("utf8")).presetProjects[pDel.id].project, "LagA");
      const rDelB = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pDel.id]: { project: "LagA", rev: 1, at: t2 + 1 } } }, { workspace: ws, sub: "u-del16-b" }));
      assert.equal(JSON.parse(rDelB.body.toString("utf8")).presetProjects[pDel.id].project, "LagA");
      // Retry delayed LagA->LagC (wallAt=T, renamedAt=T+2) to peer -> BOTH users must stay on LagA!
      dropLagAC = false;
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LagA", to: "LagC" }, "ik-r16-d3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    assert.equal(JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-del16-a" }))).body.toString("utf8")).presetProjects[pDel.id].project, "LagA");
    assert.equal(JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-del16-b" }))).body.toString("utf8")).presetProjects[pDel.id].project, "LagA");
    const [, tLagAOpen] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del16-a", ws, preset: pDel.id });
    const [, tLagBOpen] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del16-b", ws, preset: pDel.id });
    assert.equal(tLagAOpen.project, "LagA");
    assert.equal(tLagBOpen.project, "LagA");
    // Subsequent real T+2 rename LagA -> LagD migrates BOTH users to LagD!
    (f.hub.store as any).now = () => t2 + 2;
    try {
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "LagA", to: "LagD" }, "ik-r16-d4"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }
    const [, tLagAD] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del16-a", ws, preset: pDel.id });
    const [, tLagBD] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-del16-b", ws, preset: pDel.id });
    assert.equal(tLagAD.project, "LagD");
    assert.equal(tLagBD.project, "LagD");
  } finally {
    await peerRig.close();
    await f.close();
  }
});

test("R17 Node Station orthogonal entry.at vs entry.ren closure regressions: intermediate snapshot Zulu@(at=T-10, ren=T+1) carried before or after Zulu->Beta converges cleanly to Beta on both stations", async () => {
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerA = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerB = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({
      kept: f.hub.store,
      told: () => {},
      agentHome: () => f.hub.config().agentHome,
      homeWorkspace: () => f.hub.homeWorkspace(),
    });
    const peerAPpRoutes = presetProjectRoutes({
      kept: peerA.hub.store,
      told: () => {},
      agentHome: () => peerA.hub.config().agentHome,
      homeWorkspace: () => peerA.hub.homeWorkspace(),
    });
    const peerBPpRoutes = presetProjectRoutes({
      kept: peerB.hub.store,
      told: () => {},
      agentHome: () => peerB.hub.config().agentHome,
      homeWorkspace: () => peerB.hub.homeWorkspace(),
    });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);
    const T = origNow() + 2_200_000;

    const pCoord = await f.hub.presets.add(ws, { name: "R17P", dirs: [] }, "alice@example.com", "u-r17");
    const pPeerA = await peerA.hub.presets.add(ws, { name: "R17P", dirs: [] }, "alice@example.com", "u-r17");
    const pPeerB = await peerB.hub.presets.add(ws, { name: "R17P", dirs: [] }, "alice@example.com", "u-r17");
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R17Other" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R17Alpha" });
    f.hub.store.putPresetProjects(ws, "u-r17", JSON.stringify({ [pCoord.id]: { project: "R17Alpha", rev: 1, at: T - 10 } }));

    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") {
        return {
          stations: [
            { id: "peer-a", name: "Peer A", online: true },
            { id: "peer-b", name: "Peer B", online: true },
          ],
        };
      }
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify") {
        if (station === "peer-a") return classifyForPeer(peerA.hub, req, ws);
        if (station === "peer-b") return classifyForPeer(peerB.hub, req, ws);
      }
      return {};
    };

    let midZuluSnap: any;
    (f.hub.store as any).now = () => T;
    try {
      // Step 1: Other -> Next (T)
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R17Other", to: "R17Next" }, "ik-r17-1"))).status, 200);
      // Step 2: Alpha -> Zulu (T+1)
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R17Alpha", to: "R17Zulu" }, "ik-r17-2"))).status, 200);
      midZuluSnap = JSON.parse((await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r17" }))).body.toString("utf8")).presetProjects[pCoord.id];
      assert.deepEqual(midZuluSnap, { project: "R17Zulu", rev: 1, at: T - 10, ren: T + 1 });

      // Path A: carry intermediate Zulu snapshot to peerA BEFORE Zulu -> Beta
      const rPutA = await dispatch(peerAPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pPeerA.id]: midZuluSnap } }, { workspace: ws, sub: "u-r17" }));
      assert.equal(JSON.parse(rPutA.body.toString("utf8")).presetProjects[pPeerA.id].project, "R17Zulu");

      // Step 3: Zulu -> Beta (T+2)
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R17Zulu", to: "R17Beta" }, "ik-r17-3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }

    // Verify Path A: both coordinator and peerA have Beta in GET and direct newSession
    const coordBeta = JSON.parse((await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r17" }))).body.toString("utf8")).presetProjects[pCoord.id];
    assert.deepEqual(coordBeta, { project: "R17Beta", rev: 1, at: T - 10, ren: T + 2 });
    const peerABeta = JSON.parse((await dispatch(peerAPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r17" }))).body.toString("utf8")).presetProjects[pPeerA.id];
    assert.deepEqual(peerABeta, { project: "R17Beta", rev: 1, at: T - 10, ren: T + 2 });
    const [, tCoordA] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r17", ws, preset: pCoord.id });
    const [, tPeerA] = await newSession(peerA.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r17", ws, preset: pPeerA.id });
    assert.equal(tCoordA.project, "R17Beta");
    assert.equal(tPeerA.project, "R17Beta");

    // Path B: carry intermediate Zulu snapshot to peerB AFTER Zulu -> Beta; peerB auto-migrates to Beta (ren=T+2) and bidirectional sync stays Beta!
    const rPutB = await dispatch(peerBPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pPeerB.id]: midZuluSnap } }, { workspace: ws, sub: "u-r17" }));
    const peerBBeta = JSON.parse(rPutB.body.toString("utf8")).presetProjects[pPeerB.id];
    assert.deepEqual(peerBBeta, { project: "R17Beta", rev: 1, at: T - 10, ren: T + 2 });
    // Bidirectional sync with coordinator (even if stale midZuluSnap is PUT back to coordinator!)
    const rCoordStale = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCoord.id]: midZuluSnap } }, { workspace: ws, sub: "u-r17" }));
    assert.equal(JSON.parse(rCoordStale.body.toString("utf8")).presetProjects[pCoord.id].project, "R17Beta", "stale Zulu@(ren=T+1) must NEVER roll back Beta@(ren=T+2)");
    const rPeerBSync = await dispatch(peerBPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pPeerB.id]: coordBeta } }, { workspace: ws, sub: "u-r17" }));
    assert.equal(JSON.parse(rPeerBSync.body.toString("utf8")).presetProjects[pPeerB.id].project, "R17Beta");
    const [, tPeerB] = await newSession(peerB.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r17", ws, preset: pPeerB.id });
    assert.equal(tPeerB.project, "R17Beta");
  } finally {
    await peerB.close();
    await peerA.close();
    await f.close();
  }
});

test("R18 Astra R17 edge regression: carried snapshot with ren watermark {Zulu, rev:1, at:T, ren:T+1} migrates to Beta (ren:T+2) even after Zulu is rebuilt on peer at T+100", async () => {
  const { classifyForPeer } = await import("../src/sessions/projects.ts");
  const f = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const peerRig = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const ws = "ws-1";
    const routes = projectRoutes({ store: f.hub.store, agents: { hub: f.hub } as any, data: f.dir } as any);
    const ppRoutes = presetProjectRoutes({
      kept: f.hub.store,
      told: () => {},
      agentHome: () => f.hub.config().agentHome,
      homeWorkspace: () => f.hub.homeWorkspace(),
    });
    const peerPpRoutes = presetProjectRoutes({
      kept: peerRig.hub.store,
      told: () => {},
      agentHome: () => peerRig.hub.config().agentHome,
      homeWorkspace: () => peerRig.hub.homeWorkspace(),
    });
    const reqWithKey = (path: string, body: unknown, idemKey?: string) => {
      const r = makeReq("POST", path, body, { workspace: ws });
      (r as any).headers = idemKey ? { "idempotency-key": idemKey } : {};
      return r;
    };
    const origNow = f.hub.store.now.bind(f.hub.store);
    const T = origNow() + 2_300_000;

    const pCoord = await f.hub.presets.add(ws, { name: "R18P", dirs: [] }, "alice@example.com", "u-r18");
    const pPeer = await peerRig.hub.presets.add(ws, { name: "R18P", dirs: [] }, "alice@example.com", "u-r18");
    // Original threads on both stations
    const [, tCoordOrig] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R18Alpha" });
    const [, tPeerOrig] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R18Alpha" });
    await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R18Other" });

    // User selects Alpha at wall-clock T (rev:1, at:T)
    const rInit = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCoord.id]: { project: "R18Alpha", rev: 1, at: T } } }, { workspace: ws, sub: "u-r18" }));
    assert.equal(rInit.status, 200);

    (f.hub as any).peersInWorkspace = () => async (station: string, req: any) => {
      if (station === "" && req.method === "peers") return { stations: [{ id: "peer-1", name: "Peer 1", online: true }] };
      if (req.method === "projects.names") return { exists: false };
      if (req.method === "thread.classify" && station === "peer-1") return classifyForPeer(peerRig.hub, req, ws);
      return {};
    };

    let midZuluSnap: any;
    (f.hub.store as any).now = () => T;
    try {
      // Unrelated rename at T -> logical clock T
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R18Other", to: "R18Next" }, "ik-r18-1"))).status, 200);
      // Alpha -> Zulu at same wall-clock T -> logical clock T+1
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R18Alpha", to: "R18Zulu" }, "ik-r18-2"))).status, 200);
      midZuluSnap = JSON.parse((await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r18" }))).body.toString("utf8")).presetProjects[pCoord.id];
      assert.deepEqual(midZuluSnap, { project: "R18Zulu", rev: 1, at: T, ren: T + 1 });

      // Zulu -> Beta at same wall-clock T -> logical clock T+2 (both original threads move to Beta)
      assert.equal((await dispatch(routes, reqWithKey("/projects/rename", { from: "R18Zulu", to: "R18Beta" }, "ik-r18-3"))).status, 200);
    } finally {
      (f.hub.store as any).now = origNow;
    }

    assert.equal(f.hub.store.threadAt(tCoordOrig.surface, tCoordOrig.channel, tCoordOrig.threadTs)?.project, "R18Beta");
    assert.equal(peerRig.hub.store.threadAt(tPeerOrig.surface, tPeerOrig.channel, tPeerOrig.threadTs)?.project, "R18Beta");

    // At T+100, rebuild a new thread named R18Zulu on peer
    const origPeerNow = peerRig.hub.store.now.bind(peerRig.hub.store);
    let rebuiltThread!: typeof tPeerOrig;
    (peerRig.hub.store as any).now = () => T + 100;
    try {
      const [, tRebuilt] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", ws, project: "R18Zulu" });
      rebuiltThread = tRebuilt;
    } finally {
      (peerRig.hub.store as any).now = origPeerNow;
    }
    assert.equal(peerRig.hub.store.threadAt(rebuiltThread.surface, rebuiltThread.channel, rebuiltThread.threadTs)?.project, "R18Zulu");

    // Carry intermediate snapshot { project: "R18Zulu", rev: 1, at: T, ren: T + 1 } to peer via PUT:
    // Because initialRen !== undefined, it MUST NOT be blocked by the rebuilt active R18Zulu thread!
    const rPeerPut = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pPeer.id]: midZuluSnap } }, { workspace: ws, sub: "u-r18" }));
    assert.equal(rPeerPut.status, 200);
    const peerPutEntry = JSON.parse(rPeerPut.body.toString("utf8")).presetProjects[pPeer.id];
    assert.deepEqual(peerPutEntry, { project: "R18Beta", rev: 1, at: T, ren: T + 2 });

    const peerGetEntry = JSON.parse((await dispatch(peerPpRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r18" }))).body.toString("utf8")).presetProjects[pPeer.id];
    assert.deepEqual(peerGetEntry, { project: "R18Beta", rev: 1, at: T, ren: T + 2 });

    const [, tPeerNew] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r18", ws, preset: pPeer.id });
    assert.equal(tPeerNew.project, "R18Beta");

    // Rebuilt thread must stay on R18Zulu
    assert.equal(peerRig.hub.store.threadAt(rebuiltThread.surface, rebuiltThread.channel, rebuiltThread.threadTs)?.project, "R18Zulu");

    // Bidirectional sync with coordinator: both GET and newSession remain R18Beta
    const coordGetBefore = JSON.parse((await dispatch(ppRoutes, makeReq("GET", "/preset-projects", undefined, { workspace: ws, sub: "u-r18" }))).body.toString("utf8")).presetProjects[pCoord.id];
    assert.deepEqual(coordGetBefore, { project: "R18Beta", rev: 1, at: T, ren: T + 2 });
    const rCoordSync = await dispatch(ppRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pCoord.id]: peerGetEntry } }, { workspace: ws, sub: "u-r18" }));
    assert.deepEqual(JSON.parse(rCoordSync.body.toString("utf8")).presetProjects[pCoord.id], { project: "R18Beta", rev: 1, at: T, ren: T + 2 });
    const rPeerSync = await dispatch(peerPpRoutes, makeReq("PUT", "/preset-projects", { presetProjects: { [pPeer.id]: coordGetBefore } }, { workspace: ws, sub: "u-r18" }));
    assert.deepEqual(JSON.parse(rPeerSync.body.toString("utf8")).presetProjects[pPeer.id], { project: "R18Beta", rev: 1, at: T, ren: T + 2 });

    const [, tCoordFinal] = await newSession(f.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r18", ws, preset: pCoord.id });
    const [, tPeerFinal] = await newSession(peerRig.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "alice@example.com", createdBySub: "u-r18", ws, preset: pPeer.id });
    assert.equal(tCoordFinal.project, "R18Beta");
    assert.equal(tPeerFinal.project, "R18Beta");
    assert.equal(peerRig.hub.store.threadAt(rebuiltThread.surface, rebuiltThread.channel, rebuiltThread.threadTs)?.project, "R18Zulu");
  } finally {
    await peerRig.close();
    await f.close();
  }
});
