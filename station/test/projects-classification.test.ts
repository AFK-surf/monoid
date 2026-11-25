import assert from "node:assert/strict";
import { test } from "node:test";
import { Admin } from "../src/api/admin.ts";
import { Readers } from "../src/read/pool.ts";
import { Refused } from "../src/jobs/remote.ts";
import { readProjectsInfo, updateProjectInfo } from "../src/projects/info.ts";
import { sessionInstructions } from "../src/agents/instructions.ts";
import { latest as latestNote, untold as untoldNotes } from "../src/agents/migrations.ts";
import { handedWithChoices } from "../src/sessions/actor.ts";
import { NOTICE_MARK } from "../src/sessions/chat.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { newSession } from "../src/sessions/lifecycle.ts";
import { PROJECTS_NAMES, THREAD_CLASSIFY, classifyForPeer, formatWorkspaceProjectsDelta, projectNamesForPeer, type ProjectsToldState } from "../src/sessions/projects.ts";
import { commaSurface, feishuSurface, groupSurface, slackSurface } from "../src/store/rows.ts";
import * as handover from "../src/store/handover.ts";
import * as refViews from "./reference/views.ts";
import * as refStore from "./reference/store.ts";
import { FakeChat, Rig, settle } from "./hub-fakes.ts";

const withModels = (r: Rig) => {
  r.raw.profiles = [
    { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6", "claude-sonnet-4-6"] },
    { id: "cx", runtime: "codex", home: "homes/cx", models: ["gpt-5.4"] },
  ];
  r.config = hubConfig(r.raw, r.dir);
  return r;
};

function makeReq(
  method: string,
  path: string,
  body: unknown,
  viewer: { email: string; sub: string; workspace: string; role?: string },
  headers: Record<string, string> = {},
): any {
  const raw = body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body), "utf8");
  return {
    method,
    path,
    query: [],
    headers,
    body: raw,
    viewer: { email: viewer.email, sub: viewer.sub, workspace: viewer.workspace, role: viewer.role ?? "member" },
    lang: "en",
  };
}

const fakeReaders = (data: string): any => ({
  data,
  names: new Map<string, string>(),
  read: async () => "{}",
  readBytes: async () => Buffer.from("{}"),
});

test("options card -> propose -> normal message -> accept/reassign/dismiss preserves options card, keeps entries append-only, and never enters pending_cards/chatMarks", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const [session, thread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();

    // 1. Post an options card first.
    const [optN] = r.store.insertMessage({
      thread: thread.id,
      ts: "1000.000100",
      authorKind: "agent",
      author: session,
      text: "Pick deployment strategy?",
      card: { type: "options", assignee: "ada@example.com", options: [{ label: "Canary" }, { label: "Full" }] },
    });
    assert.equal(r.store.pendingCard(thread.id)?.[0].n, optN);

    // 2. Propose a new project via project_manage(action="propose").
    const propRes = JSON.parse(await r.call(session, "project_manage", {
      action: "propose",
      args: { name: "monoid-billing", note: "Billing & invoices", refs: ["https://github.com/AFK-surf/billing"] },
    }));
    assert.equal(propRes.proposed, true);
    assert.equal(propRes.name, "monoid-billing");
    assert.match(propRes.reminder, /need_human/);

    // Verify options card is STILL the pending card and proposal is NOT in pending_cards or pending_system_cards!
    assert.equal(r.store.pendingCard(thread.id)?.[0].n, optN);
    const pendingRows = r.store.db.prepare("SELECT * FROM pending_cards WHERE thread = ?").all(thread.id) as any[];
    assert.equal(pendingRows.length, 1);
    assert.equal(pendingRows[0].n, optN);
    const sysRows = r.store.db.prepare("SELECT * FROM pending_system_cards WHERE thread = ?").all(thread.id) as any[];
    assert.equal(sysRows.length, 0);

    // Verify proposal entry has kind='message', card=NULL, options=NULL, proposal JSON intact.
    const propEntry = r.store.entriesBetween(thread.id, propRes.n, propRes.n)[0]!;
    assert.equal(propEntry.kind, "message");
    assert.equal(propEntry.card, undefined);
    assert.equal(propEntry.options, undefined);
    assert.equal(propEntry.proposal?.name, "monoid-billing");
    assert.equal(propEntry.proposal?.status, "pending");

    // Verify chatMarks shows only the options card, never the proposal.
    const rs = refStore.makeStore(r.store.db, r.dir);
    const marks = refViews.chatMarks(rs, { sub: "u1", email: "ada@example.com", name: "Ada", role: "member", workspace: "ws-1", device: "d1" });
    assert.equal(marks.card[thread.id]?.seq, optN);

    // 3. Normal person message closes the options card (as usual), while proposal stays pending!
    r.store.insertMessage({
      thread: thread.id,
      ts: "1000.000300",
      authorKind: "person",
      author: "ada@example.com",
      text: "Let's do Canary",
    });
    assert.equal(r.store.pendingCard(thread.id), null);
    assert.equal(r.store.entriesBetween(thread.id, propRes.n, propRes.n)[0]!.proposal?.status, "pending");

    // 4. Reverse order: post another proposal, then an options card -> options card is pending, proposal is untouched.
    const prop2 = JSON.parse(await r.call(session, "project_manage", {
      action: "propose",
      args: { name: "monoid-docs" },
    }));
    const [opt2N] = r.store.insertMessage({
      thread: thread.id,
      ts: "1000.000500",
      authorKind: "agent",
      author: session,
      text: "Ship now?",
      card: { type: "options", assignee: "ada@example.com", options: [{ label: "Ship" }] },
    });
    assert.equal(r.store.pendingCard(thread.id)?.[0].n, opt2N);

    // 5. Resolve first proposal via HTTP POST /threads/:id/proposals/:entryN/resolve (accept + idempotent retry).
    const admin = new Admin(fakeReaders(r.dir), { store: r.store, data: r.dir, agents: { hub: r.hub, cloud: { home: () => "ws-1" } } as any });
    const member = { email: "ada@example.com", sub: "u1", workspace: "ws-1", role: "member" };
    const acc = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${propRes.n}/resolve`, {
      action: "accept",
      name: "billing-v2",
      note: "Billing & subscriptions",
      refs: ["tokyo:~/code/billing"],
    }, member));
    assert.equal(acc.status, 200);
    const accJson = JSON.parse(acc.body.toString("utf8"));
    assert.equal(accJson.alreadyResolved, false);
    assert.equal(accJson.proposal.status, "accepted");
    assert.equal(accJson.proposal.resolvedProject, "billing-v2");
    assert.equal(accJson.thread.project, "billing-v2");
    assert.equal(accJson.thread.projectLocked, true);

    // Shared PROJECTS.jsonl was updated with note & refs, while raw entries.proposal remains immutable ("pending")!
    const info = await readProjectsInfo(r.hub.config().agentHome, "ws-1", "ws-1");
    assert.equal(info.projects["billing-v2"]?.note, "Billing & subscriptions");
    assert.deepEqual(info.projects["billing-v2"]?.refs, ["tokyo:~/code/billing"]);
    const rawEntry = r.store.db.prepare("SELECT proposal FROM entries WHERE thread = ? AND n = ?").get(thread.id, propRes.n) as { proposal: string };
    assert.equal(JSON.parse(rawEntry.proposal).status, "pending");
    const outcomeRow = r.store.db.prepare("SELECT status, project, resolved_by FROM proposal_outcomes WHERE thread = ? AND n = ?").get(thread.id, propRes.n) as any;
    assert.equal(outcomeRow.status, "accepted");
    assert.equal(outcomeRow.project, "billing-v2");
    assert.equal(r.store.entriesBetween(thread.id, propRes.n, propRes.n)[0]!.proposal?.status, "accepted");

    // Second resolve call is idempotent AND stale accept with different name/note does NOT overwrite PROJECTS.jsonl!
    const accAgain = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${propRes.n}/resolve`, {
      action: "dismiss",
      markCross: true,
    }, member));
    assert.equal(accAgain.status, 200);
    const accAgainJson = JSON.parse(accAgain.body.toString("utf8"));
    assert.equal(accAgainJson.alreadyResolved, true);
    assert.equal(accAgainJson.proposal.status, "accepted");
    assert.equal(accAgainJson.thread.project, "billing-v2");

    const staleAccept = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${propRes.n}/resolve`, {
      action: "accept",
      name: "stale-other",
      note: "STALE-OVERWRITE",
    }, member));
    assert.equal(staleAccept.status, 200);
    const staleSameName = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${propRes.n}/resolve`, {
      action: "accept",
      name: "billing-v2",
      note: "STALE-OVERWRITE-2",
    }, member));
    assert.equal(staleSameName.status, 200);
    const infoStillClean = await readProjectsInfo(r.hub.config().agentHome, "ws-1", "ws-1");
    assert.equal(infoStillClean.projects["billing-v2"]?.note, "Billing & subscriptions");
    assert.equal(infoStillClean.projects["stale-other"], undefined);

    // Dismiss WITHOUT markCross (markCross: false) writes NULL project in proposal_outcomes, leaves threads.project & project_locked untouched, and reads identically via MoonBit reader!
    const [, tDismiss] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    r.store.setThreadClassification(tDismiss.id, { project: "existing-p", force: true });
    const [pDisN] = r.store.insertMessage({
      thread: tDismiss.id,
      ts: "1000.000700",
      authorKind: "agent",
      author: session,
      text: "Propose ignore-me",
      proposal: { id: "prop-dismiss-plain", name: "ignore-me", status: "pending" },
    });
    const plainDis = await admin.handle(makeReq("POST", `/threads/${tDismiss.id}/proposals/${pDisN}/resolve`, {
      action: "dismiss",
      markCross: false,
    }, member));
    assert.equal(plainDis.status, 200);
    const plainDisJson = JSON.parse(plainDis.body.toString("utf8"));
    assert.equal(plainDisJson.proposal.status, "dismissed");
    assert.equal(plainDisJson.proposal.resolvedProject, undefined);
    assert.equal(plainDisJson.thread.project, "existing-p");
    assert.equal(plainDisJson.thread.projectLocked, undefined);
    const disReaders = new Readers(r.dir, 1, undefined, 1);
    try {
      const mbDis = JSON.parse(await disReaders.read("entries", { thread: tDismiss.id, params: {} }, "en"));
      const mbDisEntry = mbDis.entries.find((e: any) => e.n === pDisN);
      assert.equal(mbDisEntry?.proposal?.status, "dismissed");
      assert.equal(mbDisEntry?.proposal?.resolvedProject, undefined);
    } finally {
      await disReaders.close();
    }

    // Resolve second proposal with dismiss + markCross -> sets project="" and projectLocked=true.
    const dis = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${prop2.n}/resolve`, {
      action: "dismiss",
      markCross: true,
    }, member));
    assert.equal(dis.status, 200);
    const disJson = JSON.parse(dis.body.toString("utf8"));
    assert.equal(disJson.proposal.status, "dismissed");
    assert.equal(disJson.proposal.resolvedProject, "");
    assert.equal(disJson.thread.project, "");
    assert.equal(disJson.thread.projectLocked, true);
    // And options card opt2N is STILL pending!
    assert.equal(r.store.pendingCard(thread.id)?.[0].n, opt2N);
  } finally {
    await r.close();
  }
});

test("read-only viewer is refused (even with cached Idempotency-Key), idempotency keys isolate by workspace/method, and PUT /projects/info rejects full-map & bad types", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const [session, thread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();
    const prop = JSON.parse(await r.call(session, "project_manage", { action: "propose", args: { name: "alpha" } }));

    const admin = new Admin(fakeReaders(r.dir), { store: r.store, data: r.dir, agents: { hub: r.hub, cloud: { home: () => "ws-1" } } as any });
    const member = { email: "ada@example.com", sub: "u1", workspace: "ws-1", role: "member" };
    const viewer = { email: "ro@example.com", sub: "u-ro", workspace: "ws-1", role: "viewer" };

    const r1 = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${prop.n}/resolve`, { action: "accept" }, viewer));
    assert.equal(r1.status, 403);
    const r2 = await admin.handle(makeReq("PUT", `/threads/${thread.id}/classification`, { project: "alpha" }, viewer));
    assert.equal(r2.status, 403);
    const r3 = await admin.handle(makeReq("PUT", `/projects/info`, { name: "alpha", note: "nope" }, viewer));
    assert.equal(r3.status, 403);
    // GET /projects/info is allowed for read-only members.
    const r4 = await admin.handle(makeReq("GET", `/projects/info`, undefined, viewer));
    assert.equal(r4.status, 200);

    // Member writes with an Idempotency-Key; if same email is later read-only, replay is STILL 403!
    const okWrite = await admin.handle(makeReq("PUT", `/projects/info`, { name: "alpha", note: "v1" }, member, { "Idempotency-Key": "k-idem-1" }));
    assert.equal(okWrite.status, 200);
    const revokedReplay = await admin.handle(makeReq("PUT", `/projects/info`, { name: "alpha", note: "v1" }, { ...member, role: "viewer" }, { "Idempotency-Key": "k-idem-1" }));
    assert.equal(revokedReplay.status, 403);

    // Same Idempotency-Key on a different workspace does not collide.
    const otherWsWrite = await admin.handle(makeReq("PUT", `/projects/info`, { name: "beta", note: "ws2" }, { ...member, workspace: "ws-2" }, { "Idempotency-Key": "k-idem-1" }));
    assert.equal(otherWsWrite.status, 200);
    assert.ok(JSON.parse(otherWsWrite.body.toString("utf8")).projects["beta"]);

    // PUT /projects/info rejects full-map overwrite and wrong note/refs types with 400.
    assert.equal((await admin.handle(makeReq("PUT", `/projects/info`, { projects: { wipe: {} } }, member))).status, 400);
    assert.equal((await admin.handle(makeReq("PUT", `/projects/info`, { name: "alpha", note: 123 }, member))).status, 400);
    assert.equal((await admin.handle(makeReq("PUT", `/projects/info`, { name: "alpha", refs: [123] }, member))).status, 400);

    // Accepting a proposal with NO note/refs still registers the project in PROJECTS.jsonl!
    const accNoMeta = await admin.handle(makeReq("POST", `/threads/${thread.id}/proposals/${prop.n}/resolve`, { action: "accept" }, member));
    assert.equal(accNoMeta.status, 200);
    const infoAfter = await readProjectsInfo(r.hub.config().agentHome, "ws-1", "ws-1");
    assert.ok("alpha" in infoAfter.projects);
  } finally {
    await r.close();
  }
});

test("need_human refuses about pointing to a proposal entry and askingMessage excludes proposals", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const [session, thread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();
    const prop = JSON.parse(await r.call(session, "project_manage", { action: "propose", args: { name: "gamma" } }));

    await assert.rejects(
      () => r.call(session, "chat_state", { kind: "need_human", need: "confirm project", about: prop.ts }),
      /project proposal is not a blocking question/,
    );
    await assert.rejects(
      () => r.call(session, "chat_post", { to: `CHAT/${thread.threadTs}`, text: "Waiting", kind: "need_human", need: "confirm project", about: prop.ts }),
      /project proposal is not a blocking question/,
    );
    // askingMessage must NOT pick up the proposal entry even when about is null!
    assert.equal(r.store.askingMessage(thread.id, null, [0, Date.now() + 60_000]), null);
    const rs = refStore.makeStore(r.store.db, r.dir);
    assert.equal(refStore.askingMessage(rs, thread.id, null, [0, Date.now() + 60_000]), null);
  } finally {
    await r.close();
  }
});

test("project_locked refuses agent overwrite of project AND tags, unknown project is refused, >3 tags throws, multi-agent thread succeeds silently, and action=create is refused", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const [s1, thread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [s2] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    // Register "still.fail" in PROJECTS.jsonl so it is a known project.
    await updateProjectInfo(r.hub.config().agentHome, "ws-1", "ws-1", { name: "still.fail", note: "core", now: 1000 });
    // Attach second agent to an external multi-agent thread (no single `home`).
    const sharedThread = r.store.openThread(slackSurface("c1", "T1"), "C123", "2000.000100", null, "U1");
    r.store.joinThread(sharedThread.id, s1, "c1");
    r.store.joinThread(sharedThread.id, s2, "c1");
    await settle();

    // Unknown project name is rejected by chat_configure, set_info, and reclassify!
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: "C123/2000.000100", project: "brand-new-unknown" }),
      /unknown project/,
    );
    await assert.rejects(
      () => r.call(s1, "project_manage", { action: "set_info", args: { name: "brand-new-unknown", note: "nope" } }),
      /unknown project/,
    );
    // More than 3 unique tags throws instead of silently truncating!
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: "C123/2000.000100", tags: ["a", "b", "c", "d"] }),
      /at most 3 tags/,
    );
    // Control chars / commas are rejected.
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: "C123/2000.000100", tags: ["bad,tag"] }),
      /control characters or commas/,
    );

    // Multi-agent thread classification succeeds silently without posting any notice!
    const beforeEntries = r.store.entriesBetween(sharedThread.id, 1, 100).length;
    const res = JSON.parse(await r.call(s1, "chat_configure", { chat: "C123/2000.000100", project: "still.fail", tags: ["bug", "  bug ", "ui", "extra1"] }));
    assert.equal(res.updated, true);
    assert.equal(res.project, "still.fail");
    assert.deepEqual(res.tags, ["bug", "ui", "extra1"]);
    assert.equal(r.store.entriesBetween(sharedThread.id, 1, 100).length, beforeEntries);

    // Mixing model config and project/tags is refused.
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: `CHAT/${thread.threadTs}`, model: "claude-opus-4-6", project: "still.fail" }),
      /cannot be combined/,
    );

    // Human locks project via PUT /threads/:id/classification.
    const admin = new Admin(fakeReaders(r.dir), { store: r.store, data: r.dir, agents: { hub: r.hub, cloud: { home: () => "ws-1" } } as any });
    const lockRes = await admin.handle(makeReq("PUT", `/threads/${thread.id}/classification`, { project: "locked-proj", tags: ["core"] }, { email: "ada@example.com", sub: "u1", workspace: "ws-1" }));
    assert.equal(lockRes.status, 200);
    assert.equal(r.store.getThread(thread.id)?.projectLocked, true);

    // Agent cannot overwrite locked project OR locked tags!
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: `CHAT/${thread.threadTs}`, project: "still.fail" }),
      /locked by a member/,
    );
    await assert.rejects(
      () => r.call(s1, "chat_configure", { chat: `CHAT/${thread.threadTs}`, tags_add: ["urgent"] }),
      /locked by a member/,
    );

    // Inspect mode of chat_configure includes project, project_locked, tags!
    const inspected = JSON.parse(await r.call(s1, "chat_configure", { chat: `CHAT/${thread.threadTs}` }));
    assert.equal(inspected.project, "locked-proj");
    assert.equal(inspected.project_locked, true);
    assert.deepEqual(inspected.tags, ["core"]);

    // project_manage intentionally has no "create" action.
    await assert.rejects(
      () => r.call(s1, "project_manage", { action: "create", args: { name: "nope" } }),
      /use action "propose"/,
    );
  } finally {
    await r.close();
  }
});

test("cross-station projects.names and rename/merge report offline, unsupported, and update locked chats keeping lock; workspaces stay isolated", async () => {
  const peerStation = withModels(new Rig({ link: true, workspaces: ["ws-1", "ws-2"], place: { workspace: "ws-1", station: "st-peer" }, projectsOn: () => true }));
  const localStation = withModels(new Rig({
    link: true,
    workspaces: ["ws-1", "ws-2"],
    place: { workspace: "ws-1", station: "st-local" },
    projectsOn: () => true,
  }));
  localStation.hub.onPeer(async (target: string, request: any, ws?: string | null) => {
    if (target === "" && request?.method === "peers") {
      return {
        workspace: ws ?? "ws-1",
        current: true,
        stations: [
          { id: "st-local", name: "local", online: true },
          { id: "st-peer", name: "peer-online", online: true },
          { id: "st-old", name: "peer-old", online: true },
          { id: "st-off", name: "peer-offline", online: false },
          { id: "st-rig", name: "peer-rig", online: true },
        ],
      };
    }
    if (target === "st-old") throw new Refused(`unknown peer method ${request?.method}`);
    if (target === "st-rig") throw new Refused("a rig does not serve project queries");
    if (target === "st-peer") {
      if (request?.method === PROJECTS_NAMES) return projectNamesForPeer(peerStation.hub, ws ?? "ws-1");
      if (request?.method === THREAD_CLASSIFY) return classifyForPeer(peerStation.hub, request, ws ?? "ws-1");
    }
    throw new Error(`unexpected peer call ${target} ${request?.method}`);
  });
  try {
    // Local ws-1: 1 unlocked + 1 locked in "legacy"
    const [l1, lt1] = await newSession(localStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [, lt2] = await newSession(localStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    localStation.store.setThreadClassification(lt1.id, { project: "legacy", tags: ["v1"], force: true });
    localStation.store.setThreadClassification(lt2.id, { project: "legacy", lock: true, force: true });
    // Local ws-2: must stay completely isolated from ws-1!
    const [, lws2] = await newSession(localStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-2" });
    localStation.store.setThreadClassification(lws2.id, { project: "secret-ws2", tags: ["ws2-only"], force: true });

    // Peer ws-1: 1 unlocked in "legacy", 1 in "remote-only"
    const [, pt1] = await newSession(peerStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [, pt2] = await newSession(peerStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    peerStation.store.setThreadClassification(pt1.id, { project: "legacy", force: true });
    peerStation.store.setThreadClassification(pt2.id, { project: "remote-only", tags: ["peer-tag"], force: true });
    // Peer ws-2: isolated!
    const [, pws2] = await newSession(peerStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-2" });
    peerStation.store.setThreadClassification(pws2.id, { project: "peer-ws2", force: true });
    await settle();

    // 1. project_manage(action="list") aggregates across online peers and isolates ws-2.
    const listed = JSON.parse(await localStation.call(l1, "project_manage", { action: "list" }));
    const projMap = Object.fromEntries(listed.projects.map((p: any) => [p.name, p.count]));
    assert.equal(projMap["legacy"], 3);
    assert.equal(projMap["remote-only"], 1);
    assert.equal(projMap["secret-ws2"], undefined);
    assert.equal(projMap["peer-ws2"], undefined);
    assert.deepEqual(
      listed.peers.map((p: any) => [p.name, p.status]).sort(),
      [["peer-offline", "offline"], ["peer-old", "unsupported"], ["peer-online", "ok"], ["peer-rig", "rig"]],
    );

    // 2. project_manage(action="rename") updates unlocked AND locked locally & on online peer (keeping projectLocked=true), reports offline/unsupported.
    const renamed = JSON.parse(await localStation.call(l1, "project_manage", { action: "rename", args: { from: "legacy", to: "modern" } }));
    assert.deepEqual(renamed.local, { updated: 2, skippedLocked: 0 });
    assert.equal(localStation.store.getThread(lt1.id)?.project, "modern");
    assert.equal(localStation.store.getThread(lt2.id)?.project, "modern");
    assert.equal(localStation.store.getThread(lt2.id)?.projectLocked, true);
    assert.equal(peerStation.store.getThread(pt1.id)?.project, "modern");
    assert.equal(localStation.store.getThread(lws2.id)?.project, "secret-ws2"); // ws-2 untouched!
    const peerByName = Object.fromEntries(renamed.peers.map((p: any) => [p.name, p]));
    assert.equal(peerByName["peer-online"].status, "ok");
    assert.equal(peerByName["peer-online"].updated, 1);
    assert.equal(peerByName["peer-old"].status, "unsupported");
    assert.equal(peerByName["peer-offline"].status, "offline");
    assert.equal(peerByName["peer-rig"].status, "rig");
  } finally {
    await localStation.close();
    await peerStation.close();
  }
});

test("external channels (Slack, Feishu, group, Comma) deliver plain text + NOTICE_MARK + link without note/refs or card/options/buttons", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const extChats = new Map<string, FakeChat>();
  const hub = r.newHub({ chats: (id) => extChats.get(id), link: true });
  r.hub = hub;
  try {
    const channels: [string, string, string, string][] = [
      ["slack-c", slackSurface("slack-c", "T1"), "C01", "1700.000100"],
      ["feishu-c", feishuSurface("feishu-c"), "oc_12345", "om_67890"],
      ["group-c", groupSurface("group-c"), "s_0123456789abcdef01234567", "t_0123456789abcdef"],
      ["comma-c", commaSurface("comma-c"), "COMMA1", "1700.000200"],
    ];
    for (const [connect, surface, channel, threadTs] of channels) {
      const fake = new FakeChat(`B_${connect}`);
      extChats.set(connect, fake);
      const [session] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const extThread = r.store.openThread(surface, channel, threadTs, null, "U1");
      r.store.joinThread(extThread.id, session, connect);
      await settle();

      const res = JSON.parse(await r.call(session, "project_manage", {
        action: "propose",
        args: { name: `proj-${connect}`, note: "INTERNAL-SECRET-NOTE", refs: ["tokyo:~/private/repo"], to: `${channel}/${threadTs}` },
      }));
      assert.equal(res.proposed, true);
      assert.equal(fake.posts.length, 1);
      // Plain text with NOTICE_MARK and direct still.fail link, NO note/refs leaked, NO card / options / buttons!
      assert.match(fake.posts[0]![1], /proj-/);
      assert.match(fake.posts[0]![1], /https?:\/\/.*\/o\//);
      assert.deepEqual(fake.marked, [0], "external channel proposal must include NOTICE_MARK");
      assert.doesNotMatch(fake.posts[0]![1], /INTERNAL-SECRET-NOTE/);
      assert.doesNotMatch(fake.posts[0]![1], /private\/repo/);
      assert.equal(fake.carried[0], null);
      // Local entry carries full proposal JSON (with note/refs for still.fail UI) and never enters pending_cards!
      const entry = r.store.entriesBetween(extThread.id, res.n, res.n)[0]!;
      assert.equal(entry.proposal?.name, `proj-${connect}`);
      assert.equal(entry.proposal?.note, "INTERNAL-SECRET-NOTE");
      assert.equal(r.store.pendingCard(extThread.id), null);
    }
  } finally {
    await r.close();
  }
});

test("handover preserves classification columns with project_locked=1 priority", () => {
  const r1 = new Rig();
  const r2 = new Rig();
  try {
    const tLocal = r1.store.openThread("slack:T1", "C1", "100.000100", null, "U1");
    r1.store.setThreadClassification(tLocal.id, { project: "human-choice", tags: ["keep"], lock: true, force: true });

    const tIncoming = r2.store.openThread("slack:T1", "C1", "100.000100", null, "U1");
    r2.store.setThreadClassification(tIncoming.id, { project: "agent-guess", tags: ["other"], force: true });
    const rows = handover.chatPage(r2.store.db, "threads", tIncoming.id, null);

    const ctx = handover.newCtx({ from: "st2", fromData: r2.dir, toData: r1.dir, connects: {}, profiles: {}, ws: "ws-1" });
    handover.importRows(r1.store.db, ctx, "threads", rows, { sessions: new Set(), threads: new Set() });
    const merged = r1.store.getThread(tLocal.id)!;
    assert.equal(merged.project, "human-choice");
    assert.equal(merged.projectLocked, true);
    assert.deepEqual(merged.tags, ["keep"]);

    // Conversely, unlocked local thread takes incoming locked project!
    const tLocal2 = r1.store.openThread("slack:T1", "C1", "100.000200", null, "U1");
    r1.store.setThreadClassification(tLocal2.id, { project: "old-guess", force: true });
    const tIn2 = r2.store.openThread("slack:T1", "C1", "100.000200", null, "U1");
    r2.store.setThreadClassification(tIn2.id, { project: "human-locked-incoming", tags: ["inc"], lock: true, force: true });
    const rows2 = handover.chatPage(r2.store.db, "threads", tIn2.id, null);
    handover.importRows(r1.store.db, ctx, "threads", rows2, { sessions: new Set(), threads: new Set() });
    const merged2 = r1.store.getThread(tLocal2.id)!;
    assert.equal(merged2.project, "human-locked-incoming");
    assert.equal(merged2.projectLocked, true);
    assert.deepEqual(merged2.tags, ["inc"]);
  } finally {
    void r1.close();
    void r2.close();
  }
});

test("instructions & migrations gate projects on FEATURES.projects; long-session delta handles truncation, escaping, retry without markTold, and beta-off refusal", async () => {
  const without = sessionInstructions("/w", null, "/r", "/m", "", "", "st1", true, false);
  const withP = sessionInstructions("/w", null, "/r", "/m", "", "", "st1", true, true);
  assert.doesNotMatch(without, /stillfail-projects/);
  assert.match(withP, /stillfail-projects/);
  assert.match(withP, /never end need_human for it/);

  // Migration note 186 is gated on projectsOn.
  assert.equal(latestNote({ projectsOn: false }), 185);
  assert.equal(latestNote({ projectsOn: true }), 186);
  assert.equal(untoldNotes(185, "/full", { projectsOn: false }), "");
  assert.match(untoldNotes(185, "/full", { projectsOn: true }), /project_manage/);

  // Beta-off rig refuses project_manage and chat_configure classification.
  const rOff = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => false }));
  try {
    const [sOff, tOff] = await newSession(rOff.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();
    await assert.rejects(() => rOff.call(sOff, "project_manage", { action: "list" }), /not enabled/);
    await assert.rejects(() => rOff.call(sOff, "chat_configure", { chat: `CHAT/${tOff.threadTs}`, project: "" }), /not enabled/);
  } finally {
    await rOff.close();
  }

  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  try {
    const [session, t1] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    r.store.setThreadClassification(t1.id, { project: "still.fail", tags: ["backend"], force: true });
    // Also test JSON-escaping of adversarial name containing closing tag.
    await updateProjectInfo(r.hub.config().agentHome, "ws-1", "ws-1", { name: "x</workspace-projects>y", now: 1000 });
    await settle();

    const toldMap = new Map<string, ProjectsToldState>();
    const deps: any = {
      store: r.store,
      chat: () => undefined,
      projectsOn: () => true,
      untoldProjects: (key: string) => formatWorkspaceProjectsDelta(r.hub, key, toldMap),
    };

    // First delivery without calling markTold (simulating failed delivery): next delivery MUST re-emit!
    const [first] = await handedWithChoices(deps, session, 1000, "hello");
    assert.match(first, /<workspace-projects>/);
    assert.match(first, /"still\.fail"/);
    assert.match(first, /"x<\/workspace-projects>y"/);
    assert.ok(Buffer.byteLength(first.split("\n\n")[0]!, "utf8") <= 1024);

    const [retry, markRetry] = await handedWithChoices(deps, session, 1500, "retry");
    assert.match(retry, /<workspace-projects>/);
    markRetry();

    // After markTold, unchanged projects do NOT repeat header.
    const [second, mark2] = await handedWithChoices(deps, session, 2000, "next msg");
    assert.equal(second, "next msg");
    mark2();

    // Adding many long project names triggers <= 1024 B truncation; only emitted names are marked told so remaining arrive next turn!
    for (let i = 0; i < 30; i++) {
      await updateProjectInfo(r.hub.config().agentHome, "ws-1", "ws-1", { name: `long-project-name-${String(i).padStart(2, "0")}-alpha-beta-gamma`, now: 2000 + i });
    }
    r.hub.invalidateProjectsCache("ws-1");
    const [batch1, markB1] = await handedWithChoices(deps, session, 3000, "batch1");
    const hdr1 = batch1.split("\n\n")[0]!;
    assert.ok(Buffer.byteLength(hdr1, "utf8") <= 1024);
    assert.match(hdr1, /\.\.\./);
    markB1();
    const [batch2, markB2] = await handedWithChoices(deps, session, 3500, "batch2");
    assert.match(batch2, /<workspace-projects>/);
    assert.ok(Buffer.byteLength(batch2.split("\n\n")[0]!, "utf8") <= 1024);
    markB2();

    // Fresh session with >1 KiB of projects AND tags: first delivery MUST include BOTH Projects and Tags (never starve tags),
    // and next delivery continues emitting remaining unseen projects!
    const [freshSession] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [fresh1, markF1] = await handedWithChoices(deps, freshSession, 4000, "fresh1");
    const freshHdr1 = fresh1.split("\n\n")[0]!;
    assert.ok(Buffer.byteLength(freshHdr1, "utf8") <= 1024);
    assert.match(freshHdr1, /Projects:/);
    assert.match(freshHdr1, /Tags:.*"backend"/);
    markF1();
    const [fresh2, markF2] = await handedWithChoices(deps, freshSession, 4500, "fresh2");
    const freshHdr2 = fresh2.split("\n\n")[0]!;
    assert.match(freshHdr2, /Projects:/);
    assert.doesNotMatch(freshHdr2, /Tags:/);
    assert.ok(Buffer.byteLength(freshHdr2, "utf8") <= 1024);
    markF2();
  } finally {
    await r.close();
  }
});

test("MoonBit stillfail-reader emits project, projectLocked, tags, and proposal across chats, changed, thread, entries, and stateQuestion", async () => {
  const r = withModels(new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true }));
  const readers = new Readers(r.dir, 1, undefined, 1);
  try {
    const [sNone, tNone] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [sCross, tCross] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [sNamed, tNamed] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    r.store.setThreadClassification(tCross.id, { project: "", tags: ["misc"], force: true });
    r.store.setThreadClassification(tNamed.id, { project: "still.fail", tags: ["backend", "pr1"], lock: true, force: true });
    const prop = JSON.parse(await r.call(sNamed, "project_manage", {
      action: "propose",
      args: { name: "new-proj", note: "New project note", refs: ["https://github.com/AFK-surf/monoid"] },
    }));
    await settle();

    const viewer = { sub: "u1", email: "ada@example.com", name: "Ada", role: "member", workspace: "ws-1", device: "d1" };
    // 1. GET /chats (via MoonBit reader)
    const chats = JSON.parse(await readers.read("chats", { viewer, archived: false }, "en")) as any[];
    const byId = Object.fromEntries(chats.map((c) => [c.id, c]));
    assert.equal("project" in byId[sNone], false);
    assert.equal("tags" in byId[sNone], false);
    assert.equal(byId[sCross].project, "");
    assert.deepEqual(byId[sCross].tags, ["misc"]);
    assert.equal(byId[sNamed].project, "still.fail");
    assert.deepEqual(byId[sNamed].tags, ["backend", "pr1"]);

    // 2. POST /changed/chats (via MoonBit reader)
    const changed = JSON.parse(await readers.read("changed", { op: "chats", args: { viewer, archived: false }, id: "id", held: {} }, "en"));
    const changedById = Object.fromEntries(changed.rows.map((c: any) => [c.id, c]));
    assert.equal(changedById[sNamed].project, "still.fail");
    assert.deepEqual(changedById[sNamed].tags, ["backend", "pr1"]);
    assert.equal(changedById[sCross].project, "");

    // 3. GET /threads/:id (via MoonBit reader)
    const threadView = JSON.parse(await readers.read("thread", { viewer, id: tNamed.id }, "en"));
    assert.equal(threadView.project, "still.fail");
    assert.equal(threadView.projectLocked, true);
    assert.deepEqual(threadView.tags, ["backend", "pr1"]);

    // 4. GET /threads/:id/entries (via MoonBit reader)
    const entries = JSON.parse(await readers.read("entries", { viewer, thread: tNamed.id, params: [] }, "en"));
    const propEntry = entries.entries.find((e: any) => e.n === prop.n);
    assert.equal(propEntry.kind, "message");
    assert.equal(propEntry.card, undefined);
    assert.equal(propEntry.options, undefined);
    assert.equal(propEntry.proposal?.name, "new-proj");
    assert.equal(propEntry.proposal?.status, "pending");
    assert.equal(propEntry.proposal?.note, "New project note");
    assert.deepEqual(propEntry.proposal?.refs, ["https://github.com/AFK-surf/monoid"]);

    // 5. stateQuestion (via MoonBit reader) returns { kind: "proposal" }
    const sq = JSON.parse(await readers.read("stateQuestion", { key: sNamed, threads: [tNamed.id], ts: prop.ts }, "en"));
    assert.deepEqual(sq, { kind: "proposal" });

    // 6. Verify parity with TS reference `views.chats`!
    const rs = refStore.makeStore(r.store.db, r.dir);
    const refChats = refViews.chats(rs, viewer, false);
    const refById = Object.fromEntries(refChats.map((c: any) => [c.id, c]));
    assert.equal(refById[sNamed].project, byId[sNamed].project);
    assert.deepEqual(refById[sNamed].tags, byId[sNamed].tags);
    assert.equal(refById[sCross].project, byId[sCross].project);
    assert.equal("project" in refById[sNone], false);
  } finally {
    await readers.close();
    await r.close();
  }
});
