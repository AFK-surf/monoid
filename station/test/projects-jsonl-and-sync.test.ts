import assert from "node:assert/strict";
import { test } from "node:test";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  PROJECTS_INFO_FILE,
  parseProjectsJsonl,
  projectsInfoPath,
  readProjectsInfoBestEffort,
  readProjectsInfoStrict,
  updateProjectInfo,
} from "../src/projects/info.ts";
import { createHash } from "node:crypto";
import { FILE_MOST, MemorySync, type Rec } from "../src/share/memory.ts";
import { Store } from "../src/store/store.ts";
import { Readers } from "../src/read/pool.ts";
import * as handover from "../src/store/handover.ts";
import { decide, readMemory } from "./reference/memory-merge.ts";
import { routes as projectRoutes } from "../src/api/routes/projects.ts";
import { memoryProgram } from "./memory-program.ts";
const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
import { hubConfig } from "../src/sessions/config.ts";
import { newSession } from "../src/sessions/lifecycle.ts";
import { PROJECTS_NAMES, THREAD_CLASSIFY, classifyChat, classifyForPeer, projectManage, projectNamesForPeer } from "../src/sessions/projects.ts";
import { Rig, settle } from "./hub-fakes.ts";

test("PROJECTS.jsonl: concurrent writes lose nothing, __proto__ is safe, no-op preserves updatedAt, corrupt/oversize throws on strict read, and read never mkdirs", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sf-projects-jsonl-"));
  const agentHome = join(dir, "nonexistent-agent-home");
  try {
    // 1. Reading from a non-existent directory returns empty AND never creates the directory!
    const empty = await readProjectsInfoStrict(agentHome, "ws-1", "ws-1");
    assert.deepEqual(Object.keys(empty.projects), []);
    assert.equal(existsSync(agentHome), false, "readProjectsInfoStrict must not mkdir on read");

    // 2. Concurrent writes to two different projects serialize cleanly and lose neither.
    await Promise.all([
      updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "proj-a", note: "Alpha", now: 1000 }),
      updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "proj-b", note: "Beta", refs: ["tokyo:~/b"], now: 1001 }),
    ]);
    const both = await readProjectsInfoStrict(agentHome, "ws-1", "ws-1");
    assert.equal(both.projects["proj-a"]?.note, "Alpha");
    assert.equal(both.projects["proj-b"]?.note, "Beta");
    assert.deepEqual(both.projects["proj-b"]?.refs, ["tokyo:~/b"]);

    // 3. No-op update does not bump updatedAt or rewrite.
    const noop = await updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "proj-a", note: "Alpha", now: 9999 });
    assert.equal(noop.changed, false);
    assert.equal(noop.doc.projects["proj-a"]?.updatedAt, 1000);

    // 4. __proto__ / constructor keys do not pollute Object.prototype (Object.create(null)).
    await updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "__proto__", note: "safe", now: 1002 });
    const withProto = await readProjectsInfoStrict(agentHome, "ws-1", "ws-1");
    assert.equal(Object.getPrototypeOf(withProto.projects), null);
    assert.equal(withProto.projects["__proto__"]?.note, "safe");
    assert.equal(({} as any).note, undefined);

    // 5. Corrupt JSONL line: strict read throws, while updateProjectInfo succeeds AND preserves the corrupt line verbatim!
    const file = projectsInfoPath(agentHome, "ws-1", "ws-1");
    const goodRaw = await readFile(file, "utf8");
    await writeFile(file, `${goodRaw}{not valid json\n`, "utf8");
    await assert.rejects(() => readProjectsInfoStrict(agentHome, "ws-1", "ws-1"), /corrupt|invalid|JSON/i);
    await updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "proj-c", note: "C", now: 2000 });
    const afterCorruptWrite = await readFile(file, "utf8");
    assert.ok(afterCorruptWrite.includes("{not valid json"), "corrupt/future line must be preserved verbatim");
    assert.ok(afterCorruptWrite.includes('"proj-c"'), "new project write must succeed despite one corrupt line");
    const best = await readProjectsInfoBestEffort(agentHome, "ws-1", "ws-1");
    assert.equal(best.projects["proj-a"]?.note, "Alpha");
    assert.equal(best.projects["proj-c"]?.note, "C");

    // 6. Oversize (> FILE_MOST = 512 KiB) throws on strict read and write.
    await writeFile(file, `${JSON.stringify({ name: "huge", note: "x".repeat(FILE_MOST + 100) })}\n`, "utf8");
    await assert.rejects(() => readProjectsInfoStrict(agentHome, "ws-1", "ws-1"), /512|exceeds|large/i);
    await assert.rejects(() => updateProjectInfo(agentHome, "ws-1", "ws-1", { name: "proj-d", now: 3000 }), /512|exceeds|large/i);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("memory-merge: PROJECTS.jsonl 3-way & 2-way merge deterministically without .conflict copy, and 0600 is held (TS reference + MoonBit parity)", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sf-projects-merge-"));
  const root = join(dir, "agent");
  await mkdir(root, { recursive: true });
  try {
    const lineA = `${JSON.stringify({ name: "alpha", note: "A", updatedAt: 100 })}\n`;
    const lineB = `${JSON.stringify({ name: "beta", note: "B", updatedAt: 200 })}\n`;
    const lineC = `${JSON.stringify({ name: "gamma", note: "C", updatedAt: 300 })}\n`;

    const bA = Buffer.from(lineA, "utf8");
    const bAB = Buffer.from(lineA + lineB, "utf8");
    const bAC = Buffer.from(lineA + lineC, "utf8");
    const bB = Buffer.from(lineB, "utf8");
    const blobs = new Map<string, Buffer>([
      [sha(bA), bA],
      [sha(bAB), bAB],
      [sha(bAC), bAC],
      [sha(bB), bB],
    ]);
    const contentOf = (h: string) => blobs.get(h) ?? null;
    const mkRec = (buf: Buffer, by: string, at: number, prev: string[]): Rec => ({
      hash: sha(buf), at, by, prev, size: buf.length, mode: 0o644,
    });

    // 3-way conflict (both sides added different lines after common ancestor A): deterministic union, NO conflict copy.
    const rAB = mkRec(bAB, "st1", 10, [sha(bA)]);
    const rAC = mkRec(bAC, "st2", 11, [sha(bA)]);
    const d3 = decide(PROJECTS_INFO_FILE, rAB, rAC, contentOf, (s) => s);
    assert.equal(d3.kind, "merge");
    assert.equal(d3.beside, null);
    const d3Rev = decide(PROJECTS_INFO_FILE, rAC, rAB, contentOf, (s) => s);
    assert.equal(d3Rev.kind, "merge");
    assert.equal(d3Rev.beside, null);
    assert.equal(d3.content?.toString("utf8"), d3Rev.content?.toString("utf8"), "3-way merge must be byte-identical from both sides");

    // 2-way (no common ancestor): deterministic union, NO conflict copy.
    const rA = mkRec(bA, "st1", 10, []);
    const rB = mkRec(bB, "st2", 11, []);
    const d2 = decide(PROJECTS_INFO_FILE, rA, rB, contentOf, (s) => s);
    assert.equal(d2.kind, "merge");
    assert.equal(d2.beside, null);
    const d2Rev = decide(PROJECTS_INFO_FILE, rB, rA, contentOf, (s) => s);
    assert.equal(d2Rev.kind, "merge");
    assert.equal(d2Rev.beside, null);
    assert.equal(d2.content?.toString("utf8"), d2Rev.content?.toString("utf8"), "2-way merge must be byte-identical from both sides");

    // 0600 PROJECTS.jsonl is treated as held (not synced).
    const p = join(root, PROJECTS_INFO_FILE);
    await writeFile(p, lineA, { mode: 0o600 });
    await chmod(p, 0o600);
    const scanned = await readMemory(root);
    assert.equal(scanned.files.has(PROJECTS_INFO_FILE), false);
    assert.equal(scanned.held.has(PROJECTS_INFO_FILE), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("MemorySync mixed-version compat: old peer without supports does not get PROJECTS.jsonl and still receives MEMORY.md; new peer receives both and fires onProjectsChanged", async () => {
  const dir = await mkdtemp(join(tmpdir(), "sf-projects-memsync-"));
  const dataA = join(dir, "a");
  const dataB = join(dir, "b");
  const homeA = join(dataA, "agent");
  const homeB = join(dataB, "agent");
  await mkdir(homeA, { recursive: true });
  await mkdir(homeB, { recursive: true });
  try {
    await writeFile(join(homeA, "MEMORY.md"), "- rule 1\n", "utf8");
    await writeFile(join(homeA, PROJECTS_INFO_FILE), `${JSON.stringify({ name: "still.fail", note: "core", updatedAt: 100 })}\n`, "utf8");

    // Simulate an old peer (no `supports` in memory.get, throws on unknown memoryPath in memory.put).
    const stA = "a".repeat(64);
    const stOld = "b".repeat(64);
    const stB = "c".repeat(64);
    const oldPuts: Record<string, any>[] = [];
    const oldCloud: any = {
      state: { station: stA },
      peersCurrent: true,
      home: () => "ws-1",
      memberships: () => [{ workspace: "ws-1", peers: [{ id: stOld, online: true }] }],
      fullMemberships: () => [{ workspace: "ws-1", peers: [{ id: stOld, online: true }] }],
      membership: () => ({ workspace: "ws-1", peers: [{ id: stOld, online: true }] }),
      onChange: () => () => {},
    };
    const syncA = new MemorySync({
      data: dataA,
      cloud: oldCloud,
      agentHome: () => homeA,
      ask: async (_st, _ws, req) => {
        if (req.method === "memory.get") return { files: {} }; // old peer: no `supports`
        if (req.method === "memory.put") {
          const files = req.files ?? {};
          oldPuts.push(files);
          if (PROJECTS_INFO_FILE in files) throw new Error("a malformed record of the memory");
          return { ok: true };
        }
        return {};
      },
    });
    await syncA.levelNow();
    await syncA.stop();
    assert.ok(oldPuts.length > 0, "old peer should still receive MEMORY.md");
    for (const batch of oldPuts) {
      assert.equal(PROJECTS_INFO_FILE in batch, false, "must NOT send PROJECTS.jsonl to old peer");
      assert.equal("MEMORY.md" in batch, true, "must still send MEMORY.md to old peer");
    }

    // Now test new peer receiving PROJECTS.jsonl and firing onProjectsChanged!
    const changedWs: string[] = [];
    const cloudB: any = {
      state: { station: stB },
      peersCurrent: true,
      home: () => "ws-1",
      memberships: () => [{ workspace: "ws-1", peers: [] }],
      fullMemberships: () => [{ workspace: "ws-1", peers: [] }],
      membership: () => ({ workspace: "ws-1", peers: [] }),
      onChange: () => () => {},
    };
    const syncB = new MemorySync({
      data: dataB,
      cloud: cloudB,
      agentHome: () => homeB,
      ask: async () => ({}),
      onProjectsChanged: (ws) => changedWs.push(ws),
    });
    const gotB = await syncB.handle(stA, { method: "memory.get" }, "ws-1");
    assert.ok(Array.isArray(gotB.supports) && gotB.supports.includes(PROJECTS_INFO_FILE));

    const contentBuf = Buffer.from(`${JSON.stringify({ name: "farview", note: "browser", updatedAt: 200 })}\n`, "utf8");
    const contentHash = sha(contentBuf);
    await syncB.handle(stA, {
      method: "memory.put",
      files: { [PROJECTS_INFO_FILE]: { hash: contentHash, at: 200, by: stA, prev: [], size: contentBuf.length, mode: 0o644 } },
      blobs: { [contentHash]: contentBuf.toString("base64") },
    }, "ws-1");
    await syncB.stop();
    assert.deepEqual(changedWs, ["ws-1"]);
    const readB = await readProjectsInfoStrict(homeB, "ws-1", "ws-1");
    assert.equal(readB.projects["farview"]?.note, "browser");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("tx rollback leaks zero StoreChange notifications, leftAt blocks propose, rig blocks project RPCs, and handover preserves proposal_outcomes", async () => {
  const r = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true });
  r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
  r.config = hubConfig(r.raw, r.dir);
  const rDest = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true });
  try {
    const [session, thread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();

    // 1. Failed setThreadClassification leaks ZERO StoreChange notifications.
    r.store.setThreadClassification(thread.id, { project: "still.fail", lock: true, force: true });
    const leaked: any[] = [];
    const off = r.store.subscribe((c) => leaked.push(c));
    assert.throws(() => r.store.setThreadClassification(thread.id, { project: "other", force: false }), /locked/);
    assert.equal(leaked.length, 0);
    off();

    // 2. Propose & resolve writes proposal_outcomes without mutating entries, and handover carries proposal_outcomes cleanly!
    const prop = JSON.parse(await r.call(session, "project_manage", { action: "propose", args: { name: "new-p", note: "n1" } }));
    r.store.resolveProposal(thread.id, prop.n, { action: "accept", name: "new-p", resolvedBy: "ada@example.com" });

    // Handover threads + entries + proposal_outcomes into rDest.
    const ctx = handover.newCtx({ from: "st1", fromData: r.dir, toData: rDest.dir, connects: {}, profiles: {}, ws: "ws-1" });
    for (const table of ["threads", "entries", "proposal_outcomes"] as const) {
      const rows = handover.chatPage(r.store.db, table, thread.id, null);
      handover.importRows(rDest.store.db, ctx, table, rows, { sessions: new Set(), threads: new Set() });
    }
    const destThreadRow = rDest.store.db.prepare("SELECT id FROM threads WHERE thread_ts = ?").get(thread.threadTs) as { id: number };
    const destThreadId = destThreadRow.id;
    const destEntry = rDest.store.entriesBetween(destThreadId, prop.n, prop.n)[0]!;
    assert.equal(destEntry.proposal?.status, "accepted");
    assert.equal(destEntry.proposal?.resolvedProject, "new-p");
    // And MoonBit reader on rDest ALSO overlays proposal_outcomes!
    const readers = new Readers(rDest.dir, 1, undefined, 1);
    try {
      const mbEntries = JSON.parse(await readers.read("entries", { thread: destThreadId, params: {} }, "en"));
      const mbProp = mbEntries.entries.find((e: any) => e.n === prop.n);
      assert.equal(mbProp?.proposal?.status, "accepted");
      assert.equal(mbProp?.proposal?.resolvedProject, "new-p");
    } finally {
      await readers.close();
    }

    // 3. leftAt !== null blocks propose on that thread.
    r.store.db.prepare("UPDATE thread_sessions SET left_at = 5000 WHERE thread = ? AND session = ?").run(thread.id, session);
    await assert.rejects(
      () => r.call(session, "project_manage", { action: "propose", args: { name: "after-leave" } }),
      /left/,
    );

    // 4. Rig-only station refuses project_manage, projects.names, and thread.classify.
    const rigStation = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true, isRig: () => true });
    rigStation.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    rigStation.config = hubConfig(rigStation.raw, rigStation.dir);
    try {
      const [sRig] = await newSession(rigStation.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      await settle();
      await assert.rejects(() => rigStation.call(sRig, "project_manage", { action: "list" }), /rig/);
      await assert.rejects(() => projectNamesForPeer(rigStation.hub, "ws-1"), /rig/);
      await assert.rejects(() => classifyForPeer(rigStation.hub, { chat: sRig, project: "" }, "ws-1"), /rig/);
    } finally {
      await rigStation.close();
    }
  } finally {
    await r.close();
    await rDest.close();
  }
});

test("R2 P0-1 & P0-2: unbound station refuses classification writes; 0600 PROJECTS.jsonl keeps 0600 on write and never leaks to peers", async () => {
  // P0-1: Unbound station (workspaces = []) refuses chat_configure(project) & project_manage before touching DB!
  const rUnbound = new Rig({ link: true, workspaces: [], projectsOn: () => true });
  rUnbound.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
  rUnbound.config = hubConfig(rUnbound.raw, rUnbound.dir);
  try {
    const [s, t] = await newSession(rUnbound.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: null });
    await settle();
    await assert.rejects(() => rUnbound.call(s, "chat_configure", { chat: `CHAT/${t.threadTs}`, project: "" }), /unbound|workspace/);
    await assert.rejects(() => rUnbound.call(s, "project_manage", { action: "list" }), /unbound|workspace/);
    assert.equal(rUnbound.store.getThread(t.id)?.project, undefined);
  } finally {
    await rUnbound.close();
  }

  // P0-2: 0600 private PROJECTS.jsonl stays 0600 after updateProjectInfo, stays held in memory scan, and NEVER leaks via projectNamesForPeer!
  const rPriv = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true });
  rPriv.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
  rPriv.config = hubConfig(rPriv.raw, rPriv.dir);
  try {
    const p = projectsInfoPath(rPriv.hub.config().agentHome, "ws-1", "ws-1");
    await mkdir(join(p, ".."), { recursive: true });
    await writeFile(p, `${JSON.stringify({ name: "secret-a", note: "private", updatedAt: 100 })}\n`, { mode: 0o600 });
    await chmod(p, 0o600);
    await updateProjectInfo(rPriv.hub.config().agentHome, "ws-1", "ws-1", { name: "secret-b", note: "also private", now: 200 });
    const { stat } = await import("node:fs/promises");
    const st = await stat(p);
    assert.equal(st.mode & 0o777, 0o600, "0600 PROJECTS.jsonl must retain 0600 mode after updateProjectInfo");
    const doc = await readProjectsInfoStrict(rPriv.hub.config().agentHome, "ws-1", "ws-1");
    assert.equal(doc.projects["secret-a"]?.note, "private");
    assert.equal(doc.projects["secret-b"]?.note, "also private");
    const scanned = await readMemory(join(p, ".."));
    assert.equal(scanned.held.has(PROJECTS_INFO_FILE), true);
    const peerRes = (await projectNamesForPeer(rPriv.hub, "ws-1")) as { projects: { name: string; count: number }[]; tags: { name: string; count: number }[] };
    assert.equal(peerRes.projects.some((x) => x.name === "secret-a" || x.name === "secret-b"), false, "0600 projects must not leak to peers");
  } finally {
    await rPriv.close();
  }
});

test("R2 P1: oversize >512 KiB PROJECTS.jsonl merge returns keep without blocking sync; deleteSession cleans proposal_outcomes; DB info_synced intent; beta->stable & cold-cache classifyForPeer; zero-await delta; KeptSend workspace isolation", async () => {
  // 1. Two ~292 KiB valid PROJECTS.jsonl merging > 512 KiB returns "keep" (no oversize Rec).
  const makeBig = (prefix: string) => {
    const lines: string[] = [];
    for (let i = 0; i < 650; i++) {
      lines.push(JSON.stringify({ name: `${prefix}-${String(i).padStart(4, "0")}`, note: "x".repeat(420), updatedAt: 100 + i }));
    }
    return Buffer.from(`${lines.join("\n")}\n`, "utf8");
  };
  const bigA = makeBig("pa");
  const bigB = makeBig("pb");
  assert.ok(bigA.length < FILE_MOST && bigB.length < FILE_MOST && bigA.length + bigB.length > FILE_MOST);
  const bigBlobs = new Map<string, Buffer>([[sha(bigA), bigA], [sha(bigB), bigB]]);
  const rBigA: Rec = { hash: sha(bigA), at: 10, by: "st1", prev: [], size: bigA.length, mode: 0o644 };
  const rBigB: Rec = { hash: sha(bigB), at: 11, by: "st2", prev: [], size: bigB.length, mode: 0o644 };
  const over = decide(PROJECTS_INFO_FILE, rBigA, rBigB, (h) => bigBlobs.get(h) ?? null, (s) => s);
  assert.equal(over.kind, "keep", "oversize merged PROJECTS.jsonl must return keep so it never blocks MEMORY.md/skills sync");

  // 2. deleteSession cleans proposal_outcomes when last member leaves, preserves when another member remains.
  const rDel = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true });
  rDel.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
  rDel.config = hubConfig(rDel.raw, rDel.dir);
  try {
    const [s1, t1] = await newSession(rDel.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const [s2] = await newSession(rDel.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    rDel.store.joinThread(t1.id, s2, "chat");
    const [pn] = rDel.store.insertMessage({
      thread: t1.id,
      ts: "1000.000100",
      authorKind: "agent",
      author: s1,
      text: "propose p1",
      proposal: { id: "p-del-1", name: "p1", status: "pending" },
    });
    rDel.store.resolveProposal(t1.id, pn, { action: "accept", name: "p1", resolvedBy: "ada@example.com" });
    assert.equal((rDel.store.db.prepare("SELECT COUNT(*) AS c FROM proposal_outcomes WHERE thread = ?").get(t1.id) as any).c, 1);
    rDel.store.deleteSession(s2);
    assert.equal((rDel.store.db.prepare("SELECT COUNT(*) AS c FROM proposal_outcomes WHERE thread = ?").get(t1.id) as any).c, 1, "still has s1");
    rDel.store.deleteSession(s1);
    assert.equal((rDel.store.db.prepare("SELECT COUNT(*) AS c FROM proposal_outcomes WHERE thread = ?").get(t1.id) as any).c, 0, "cleaned when last member removed");
  } finally {
    await rDel.close();
  }

  // 3. DB info_synced=1 prevents resurrecting deleted project on resolve replay; PUT /classification returns 200+infoError when PROJECTS.jsonl is oversize.
  const rIntent = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => true });
  rIntent.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
  rIntent.config = hubConfig(rIntent.raw, rIntent.dir);
  try {
    const { Admin } = await import("../src/api/admin.ts");
    const [s, t] = await newSession(rIntent.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await settle();
    const [pn] = rIntent.store.insertMessage({
      thread: t.id,
      ts: "1000.000200",
      authorKind: "agent",
      author: s,
      text: "propose alpha",
      proposal: { id: "p-int-1", name: "alpha", note: "first note", status: "pending" },
    });
    const admin = new Admin({ data: rIntent.dir, names: new Map(), read: async () => "{}", readBytes: async () => Buffer.from("{}") } as any, {
      store: rIntent.store,
      data: rIntent.dir,
      agents: { hub: rIntent.hub, cloud: { home: () => "ws-1" } } as any,
    });
    const mkReq = (method: string, path: string, body: unknown, ws = "ws-1", headers: Record<string, string> = {}): any => ({
      method, path, query: [], headers, body: Buffer.from(JSON.stringify(body), "utf8"),
      viewer: { email: "ada@example.com", sub: "u1", workspace: ws, role: "member", name: "Ada" }, lang: "en",
    });
    const res1 = await admin.handle(mkReq("POST", `/threads/${t.id}/proposals/${pn}/resolve`, { action: "accept", note: "recorded-note" }));
    assert.equal(res1.status, 200);
    // Delete alpha from PROJECTS.jsonl, then replay resolve -> must return 200 and NOT resurrect alpha!
    await updateProjectInfo(rIntent.hub.config().agentHome, "ws-1", "ws-1", { name: "alpha", delete: true, now: 2000 });
    const resReplay = await admin.handle(mkReq("POST", `/threads/${t.id}/proposals/${pn}/resolve`, { action: "accept", note: "stale" }));
    assert.equal(resReplay.status, 200);
    assert.equal((await readProjectsInfoStrict(rIntent.hub.config().agentHome, "ws-1", "ws-1")).projects["alpha"], undefined);

    // KeptSend bound to ws-1 is isolated from ws-2 (404 before once replay)!
    admin.keepSends([{ viewer: "ada@example.com", thread: t.id, key: "k-move-1", at: Date.now(), status: 200, headers: { "content-type": "application/json" }, body: Buffer.from('{"ok":true}').toString("base64") }], "ws-1");
    const otherWsReplay = await admin.handle(mkReq("POST", `/threads/${t.id}/messages`, { text: "hi" }, "ws-2", { "Idempotency-Key": "k-move-1" }));
    assert.equal(otherWsReplay.status, 404);
  } finally {
    await rIntent.close();
  }

  // 4. Beta -> Stable classifyForPeer returns Refused("unknown peer method"); cold-cache cross-station classifyForPeer succeeds via peersInWorkspace;
  //    formatWorkspaceProjectsDelta NEVER awaits a hanging peer!
  const rStable = new Rig({ link: true, workspaces: ["ws-1"], projectsOn: () => false });
  const rA = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-a" }, projectsOn: () => true });
  const rB = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-b" }, projectsOn: () => true });
  for (const x of [rStable, rA, rB]) {
    x.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    x.config = hubConfig(x.raw, x.dir);
  }
  rB.hub.onPeer(async (target: string, req: any) => {
    if (target === "" && req?.method === "peers") return { stations: [{ id: "st-a", online: true }, { id: "st-b", online: true }] };
    if (target === "st-a" && req?.method === PROJECTS_NAMES) return projectNamesForPeer(rA.hub, "ws-1", req?.check);
    throw new Error(`unexpected ${target} ${req?.method}`);
  });
  try {
    const [sSt] = await newSession(rStable.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    await assert.rejects(() => classifyForPeer(rStable.hub, { chat: sSt, project: "" }, "ws-1"), /unknown peer method/);

    // Project "only-on-a" exists ONLY on station A's active thread (no PROJECTS.jsonl, cold cache on B).
    const [, tA] = await newSession(rA.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    rA.store.setThreadClassification(tA.id, { project: "only-on-a", force: true });
    const [sB, tB] = await newSession(rB.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const classified = await classifyForPeer(rB.hub, { chat: sB, project: "only-on-a" }, "ws-1");
    assert.equal(classified.project, "only-on-a");
    assert.equal(rB.store.getThread(tB.id)?.project, "only-on-a");

    // Zero-await formatWorkspaceProjectsDelta with a slow/hanging peer that hasn't resolved yet!
    const { formatWorkspaceProjectsDelta } = await import("../src/sessions/projects.ts");
    let releaseSlowPeer = (): void => {};
    rA.hub.onPeer(() => new Promise((resolve) => { releaseSlowPeer = () => resolve({ stations: [] }); }));
    const [sHang] = await newSession(rA.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    const delta = await Promise.race([
      formatWorkspaceProjectsDelta(rA.hub, sHang, new Map()),
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error("delta blocked on slow peer")), 500)),
    ]);
    assert.ok(delta !== null && delta.text.includes("only-on-a"), "delta must return immediately without awaiting slow peer");
    releaseSlowPeer();
  } finally {
    await rStable.close();
    await rA.close();
    await rB.close();
  }
});

test("R3 P0-1: handover catch-up preserves ctx.threads.ns, updates A->B, maps proposal_outcomes to n=2, and rollback restores original thread", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r3-p01-"));
  const srcStore = Store.open(join(dir, "src.db"));
  const dstStore = Store.open(join(dir, "dst.db"));
  try {
    // Target already has an external Slack thread with entry n=1 (causing entry-number offset on import) and unlocked project "old-dst".
    const dstThread = dstStore.openThread("slack:T1", "C1", "100.1", null, "ada@example.com");
    dstStore.insertMessage({ thread: dstThread.id, ts: "100.1", authorKind: "person", author: "ada", text: "dst-first", attachments: [] });
    dstStore.setThreadClassification(dstThread.id, { project: "old-dst", lock: false, force: true });

    // Source has the same external thread, starting with its own proposal at n=1 (different ts -> maps to target n=2!) and locked project "A".
    const srcThread = srcStore.openThread("slack:T1", "C1", "100.1", null, "ada@example.com");
    const [srcPropN] = srcStore.insertMessage({
      thread: srcThread.id,
      ts: "100.2",
      authorKind: "agent",
      author: "chat:c-src",
      text: "propose A",
      attachments: [],
      proposal: { id: "prop-r3", name: "A", status: "pending" },
    });
    assert.equal(srcPropN, 1);
    srcStore.setThreadClassification(srcThread.id, { project: "A", lock: true, force: true });

    // Round 1 handover import (threads + entries)
    const srcDb = (srcStore as any).db;
    const dstDb = (dstStore as any).db;
    const ctx = handover.newCtx({ from: "st-src", here: "st-dst", fromData: dir, toData: dir, connects: {}, profiles: {}, ws: "ws-1" });
    const mkTouched = () => ({ threads: new Set<number>(), sessions: new Set<string>() });

    handover.importRows(dstDb, ctx, "threads", handover.chatPage(srcDb, "threads", srcThread.id, null), mkTouched());
    handover.importRows(dstDb, ctx, "entries", handover.chatPage(srcDb, "entries", srcThread.id, null), mkTouched());
    assert.equal(ctx.threads[String(srcThread.id)]?.ns["1"], 2, "round 1 maps source n=1 to target n=2");
    assert.equal(dstStore.getThread(dstThread.id)?.project, "A");

    // Before catch-up: source updates project to "B" and resolves proposal n=1!
    srcStore.setThreadClassification(srcThread.id, { project: "B", lock: true, force: true });
    srcStore.resolveProposal(srcThread.id, srcPropN, { action: "accept", name: "B", resolvedBy: "ada@example.com" });

    // Catch-up re-sends threads + proposal_outcomes!
    handover.importRows(dstDb, ctx, "threads", handover.chatPage(srcDb, "threads", srcThread.id, null), mkTouched());
    handover.importRows(dstDb, ctx, "proposal_outcomes", handover.chatPage(srcDb, "proposal_outcomes", srcThread.id, null), mkTouched());

    // Assert: ctx.threads[was].ns STILL maps "1" -> 2, target thread project is "B", and target entry n=2 (NOT n=1!) got the outcome!
    assert.equal(ctx.threads[String(srcThread.id)]?.ns["1"], 2, "catch-up must preserve ctx.threads[was].ns");
    assert.equal(dstStore.getThread(dstThread.id)?.project, "B", "catch-up must update project A -> B");
    assert.equal(dstStore.getEntry(dstThread.id, 1)?.proposal, undefined, "target n=1 must NOT receive source n=1 outcome");
    assert.equal(dstStore.getEntry(dstThread.id, 2)?.proposal?.status, "accepted", "target n=2 must receive resolved outcome");
    assert.equal(dstStore.getEntry(dstThread.id, 2)?.proposal?.resolvedProject, "B");

    // Rollback must restore target existing thread's original classification ("old-dst", unlocked)!
    handover.dropImport(dstDb, ctx);
    const restored = dstStore.getThread(dstThread.id);
    assert.equal(restored?.project, "old-dst", "rollback must restore target original project");
    assert.notEqual(restored?.projectLocked, true, "rollback must restore target original lock");
  } finally {
    srcStore.close();
    dstStore.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R3 P0-2: previously shared PROJECTS.jsonl later chmod 0600 refuses peer overwrite/delete", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r3-p02-"));
  const dataB = join(dir, "b");
  const homeB = join(dataB, "agent");
  await mkdir(homeB, { recursive: true });
  const stA = "a".repeat(64);
  const stB = "b".repeat(64);
  const cloudB: any = {
    state: { station: stB },
    peersCurrent: true,
    home: () => "ws-1",
    memberships: () => [{ workspace: "ws-1", peers: [] }],
    fullMemberships: () => [{ workspace: "ws-1", peers: [] }],
    membership: () => ({ workspace: "ws-1", peers: [] }),
    onChange: () => () => {},
  };
  const syncB = new MemorySync({
    data: dataB,
    cloud: cloudB,
    agentHome: () => homeB,
    ask: async () => ({}),
  });
  try {
    // 1. Peer A shares PROJECTS.jsonl at 0644 to B.
    const fileB = join(homeB, PROJECTS_INFO_FILE);
    const initial = `${JSON.stringify({ name: "shared", note: "v1", updatedAt: 100 })}\n`;
    const buf1 = Buffer.from(initial, "utf8");
    const h1 = sha(buf1);
    await syncB.handle(stA, {
      method: "memory.put",
      files: { [PROJECTS_INFO_FILE]: { hash: h1, at: 100, by: stA, prev: [], size: buf1.length, mode: 0o644 } },
      blobs: { [h1]: buf1.toString("base64") },
    }, "ws-1");
    assert.equal(await readFile(fileB, "utf8"), initial);

    // 2. User on B makes PROJECTS.jsonl private (0600) with identical content (same hash!).
    await chmod(fileB, 0o600);

    // 3. Peer A pushes updated PROJECTS.jsonl -> B must refuse to overwrite its 0600 file!
    const updated = `${JSON.stringify({ name: "shared", note: "from-a-v2", updatedAt: 200 })}\n`;
    const buf2 = Buffer.from(updated, "utf8");
    const h2 = sha(buf2);
    await syncB.handle(stA, {
      method: "memory.put",
      files: { [PROJECTS_INFO_FILE]: { hash: h2, at: 200, by: stA, prev: [h1], size: buf2.length, mode: 0o644 } },
      blobs: { [h2]: buf2.toString("base64") },
    }, "ws-1");
    assert.equal(await readFile(fileB, "utf8"), initial, "0600 PROJECTS.jsonl must NOT be overwritten by peer update");
    assert.equal((await stat(fileB)).mode & 0o777, 0o600, "0600 mode must remain intact");

    // 4. Peer A pushes deletion of PROJECTS.jsonl -> B must refuse to unlink its 0600 file!
    await syncB.handle(stA, {
      method: "memory.put",
      files: { [PROJECTS_INFO_FILE]: { hash: "", at: 300, by: stA, prev: [h2, h1], size: 0, mode: 0o644 } },
      blobs: {},
    }, "ws-1");
    assert.equal(await readFile(fileB, "utf8"), initial, "0600 PROJECTS.jsonl must NOT be deleted by peer delete");
    assert.equal((await stat(fileB)).mode & 0o777, 0o600);
  } finally {
    await syncB.stop();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R3 P1-1 & P1-2: pre-validated resolve 400, old-DB DEFAULT 1, GET lenient corruptLines, and 3-way compact union refs parity", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r3-p11-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  const store = Store.open(join(dir, "s.db"));
  try {
    const routes = projectRoutes({ store, data: dir, agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } } as any);
    const postResolve = routes.find((r) => r.method === "POST" && r.pattern.test("/threads/1/proposals/1/resolve"))!;
    const getInfo = routes.find((r) => r.method === "GET" && r.pattern.test("/projects/info"))!;

    const thread = store.openThread("stillfail", "CHAT", "500.1", null, "ada@example.com");
    const [propN] = store.insertMessage({
      thread: thread.id, ts: "500.1", authorKind: "agent", author: "chat:c-1", text: "propose", attachments: [],
      proposal: { id: "prop-val", name: "monoid", status: "pending" },
    });

    // 2001-char note must return 400 BEFORE resolveProposal mutates DB!
    const badReq = { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept", note: "x".repeat(2001) })) } as any;
    const badAns = await postResolve.handle(badReq, [String(thread.id), String(propN)]);
    assert.equal(badAns.status, 400, "2001-char note must return 400");
    assert.equal(store.getEntry(thread.id, propN)?.proposal?.status, "pending", "proposal must stay pending after 400");

    // Valid note succeeds with 200 and persists!
    const okReq = { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept", note: "good note" })) } as any;
    const okAns = await postResolve.handle(okReq, [String(thread.id), String(propN)]);
    assert.equal(okAns.status, 200);
    assert.equal(store.getEntry(thread.id, propN)?.proposal?.status, "accepted");

    // Old DB migration: table without info_synced gets DEFAULT 1 on existing rows!
    const oldDbPath = join(dir, "old.db");
    const { DatabaseSync } = await import("node:sqlite");
    const oldDb = new DatabaseSync(oldDbPath);
    oldDb.exec(`CREATE TABLE threads (id INTEGER PRIMARY KEY, surface TEXT, channel TEXT, thread_ts TEXT, home TEXT, created_by TEXT, title TEXT, title_from TEXT, hidden_at INTEGER);
      CREATE TABLE entries (thread INTEGER, n INTEGER, kind TEXT, ts TEXT, author_kind TEXT, author TEXT, text TEXT, at INTEGER, attachments TEXT, card TEXT, target INTEGER, PRIMARY KEY (thread, n));
      CREATE TABLE proposal_outcomes (thread INTEGER NOT NULL, n INTEGER NOT NULL, status TEXT NOT NULL, project TEXT, resolved_by TEXT NOT NULL, resolved_at INTEGER NOT NULL, PRIMARY KEY (thread, n));
      INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at) VALUES (1, 1, 'accepted', 'deleted-proj', 'ada@example.com', 100);`);
    const { addProjectColumns } = await import("../src/store/schema.ts");
    addProjectColumns(oldDb);
    const migrated = oldDb.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = 1 AND n = 1").get() as { info_synced: number };
    assert.equal(migrated.info_synced, 1, "old DB migration must set info_synced = 1 on existing outcomes");
    oldDb.close();

    // GET /projects/info returns 200 + corruptLines when a bad line exists.
    const wsPath = projectsInfoPath(agentHome, "ws-1", null);
    await mkdir(join(agentHome, "ws-ws-1"), { recursive: true });
    await writeFile(wsPath, `${JSON.stringify({ name: "alpha", note: "ok", updatedAt: 10 })}\n{broken-json\n`, "utf8");
    const infoAns = await getInfo.handle({ viewer: { workspace: "ws-1" }, body: Buffer.alloc(0) } as any, []);
    assert.equal(infoAns.status, 200);
    const parsedInfo = JSON.parse((infoAns.body as Buffer).toString("utf8"));
    assert.equal(parsedInfo.projects.alpha.note, "ok");
    assert.equal(parsedInfo.corruptLines, 1);

    // P1-2: Two ~309 KiB PROJECTS.jsonl files with overlapping project names carrying complementary refs ->
    // TS reference and MoonBit `decide` compact identically (<= 512 KiB) and preserve BOTH sides' refs!
    const linesA: string[] = [];
    const linesB: string[] = [];
    const pad = "n".repeat(450);
    for (let i = 0; i < 560; i++) {
      const name = `proj-${String(i).padStart(4, "0")}`;
      linesA.push(JSON.stringify({ name, note: `A-${pad}`, refs: [`ref-a-${i}`], updatedAt: 100 + i }));
      linesB.push(JSON.stringify({ name, note: `B-${pad}`, refs: [`ref-b-${i}`], updatedAt: 200 + i }));
    }
    const bufA = Buffer.from(`${linesA.join("\n")}\n`, "utf8");
    const bufB = Buffer.from(`${linesB.join("\n")}\n`, "utf8");
    assert.ok(bufA.length > 260 * 1024 && bufA.length < 512 * 1024);
    assert.ok(bufB.length > 260 * 1024 && bufB.length < 512 * 1024);
    assert.ok(bufA.length + bufB.length > 512 * 1024, "combined uncompacted union exceeds 512 KiB");

    const hA = sha(bufA);
    const hB = sha(bufB);
    const recA: Rec = { hash: hA, at: 1000, by: "a".repeat(64), prev: [], size: bufA.length, mode: 0o644 };
    const recB: Rec = { hash: hB, at: 1001, by: "b".repeat(64), prev: [], size: bufB.length, mode: 0o644 };
    const blobs = new Map([[hA, bufA], [hB, bufB]]);
    const tsCompact = decide("PROJECTS.jsonl", recA, recB, (h: string) => blobs.get(h) ?? null, (id: string) => id);
    assert.equal(tsCompact.kind, "merge", "TS reference must compact overlapping >512 KiB into <= 512 KiB merge");
    assert.ok(tsCompact.content !== null && tsCompact.content.length <= 512 * 1024);
    const parsedCompact = parseProjectsJsonl(tsCompact.content.toString("utf8"), { strict: true });
    assert.deepEqual(parsedCompact.projects["proj-0000"]?.refs, ["ref-b-0", "ref-a-0"], "both sides' refs must be preserved");

    const mbCompact = await memoryProgram().ask<any>("decide", {
      path: "PROJECTS.jsonl",
      mine: recA,
      theirs: recB,
      names: { [recA.by]: "a", [recB.by]: "b" },
      given: { [hA]: bufA.toString("hex"), [hB]: bufB.toString("hex") },
      blobs: join(dir, "blobs-compact"),
      prevMost: 16,
    });
    assert.equal(mbCompact.kind, "merge", "MoonBit must compact overlapping >512 KiB into <= 512 KiB merge");
    assert.equal(mbCompact.rec.hash, tsCompact.rec.hash, "MoonBit and TS reference compacted PROJECTS.jsonl must be byte-for-byte identical!");
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R3 P1-3 & P2: empty rename throws without side effects; peer 205th project exact check; multi-external-thread project inheritance", async () => {
  const rA = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-a" }, projectsOn: () => true });
  const rB = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-b" }, projectsOn: () => true });
  for (const x of [rA, rB]) {
    x.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    x.config = hubConfig(x.raw, x.dir);
  }
  rB.hub.onPeer(async (target: string, req: any) => {
    if (target === "" && req?.method === "peers") return { stations: [{ id: "st-a", online: true }, { id: "st-b", online: true }] };
    if (target === "st-a" && req?.method === PROJECTS_NAMES) return projectNamesForPeer(rA.hub, "ws-1", req?.check);
    throw new Error(`unexpected ${target} ${req?.method}`);
  });
  try {
    const [sB, tB] = await newSession(rB.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
    // Empty workspace rename(from="ghost", to="brand-new") must fail with zero PROJECTS.jsonl created!
    await assert.rejects(() => projectManage(rB.hub, sB, { action: "rename", args: { from: "ghost", to: "brand-new" } }), /unknown project/);
    await assert.rejects(() => stat(join(rB.config.agentHome, "PROJECTS.jsonl")));

    // Peer A has 205 distinct projects (> 200 list cap); B classifies against project #205 via exact `check` RPC!
    for (let i = 1; i <= 205; i++) {
      const [, t] = await newSession(rA.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      rA.store.setThreadClassification(t.id, { project: `p-${String(i).padStart(3, "0")}`, force: true });
    }
    const resJson = JSON.parse(await classifyChat(rB.hub, sB, "self", { project: "p-205" }));
    assert.equal(resJson.project, "p-205", "peer exact check must find 205th project beyond 200-item list cap");
    assert.equal(rB.store.getThread(tB.id)?.project, "p-205");

    // P2: multi-external-thread session inherits project from the most recently delivered external thread!
    const ext1 = rB.store.openThread("slack:T1", "C1", "200.1", null, "ada@example.com");
    const ext2 = rB.store.openThread("slack:T1", "C2", "200.2", null, "ada@example.com");
    rB.store.joinThread(ext1.id, sB, "slack-1");
    rB.store.joinThread(ext2.id, sB, "slack-1");
    rB.store.setThreadClassification(ext1.id, { project: "proj-ext-1", force: true });
    rB.store.setThreadClassification(ext2.id, { project: "proj-ext-2", force: true });
    const [e1] = rB.store.insertMessage({ thread: ext1.id, ts: "200.1", authorKind: "person", author: "u", text: "hi 1", attachments: [] });
    const [e2] = rB.store.insertMessage({ thread: ext2.id, ts: "200.2", authorKind: "person", author: "u", text: "hi 2", attachments: [] });
    rB.store.deliver(ext1.id, e1, [sB]);
    rB.store.deliver(ext2.id, e2, [sB]);
    rB.store.markDelivered(sB, [{ thread: ext1.id, n: e1, ts: "200.1", at: 1000, authorKind: "person", author: "u", text: "hi 1", attachments: [] } as any]);
    await new Promise((res) => setTimeout(res, 5));
    rB.store.markDelivered(sB, [{ thread: ext2.id, n: e2, ts: "200.2", at: 2000, authorKind: "person", author: "u", text: "hi 2", attachments: [] } as any]);
    assert.equal(rB.store.latestDeliveredThread(sB)?.project, "proj-ext-2", "latestDeliveredThread must pick most recently delivered external thread");
  } finally {
    await rA.close();
    await rB.close();
  }
});

test("R4-1 & R4-2: derived active_thread_index/tags SQL exactness, EXPLAIN plan, 2500 archived zero-scan, 1100 exact count, and 0-SQL/0-stat hot cache", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r4-sql-"));
  const store = Store.open(join(dir, "s.db"));
  const db = (store as any).db;
  try {
    // 1. Other workspace ("ws-other") has 2,000 lex-earlier projects + 500 newer rows of the same name "target-p",
    //    and target workspace ("ws-1") has 2,500 archived rows + 2 active rows of "target-p"!
    db.exec("BEGIN");
    const insSess = db.prepare("INSERT INTO sessions (key, scope, runtime, profile, model, connect, workspace, cwd, token, created_by, created_at, last_active_at, ws, archived_at) VALUES (?, 'chat', 'claude', 'cc', 'm', 'chat', '/w', '/w', ?, 'u', 1000, 1000, ?, ?)");
    const insThr = db.prepare("INSERT INTO threads (surface, channel, thread_ts, home, created_by, created_at, project, tags) VALUES ('stillfail', 'CHAT', ?, ?, 'u', 1000, ?, ?)");
    const insMem = db.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?, ?, 'chat', 1000)");
    for (let i = 0; i < 2000; i++) {
      const k = `chat:other-${i}`;
      insSess.run(k, `tok-${k}`, "ws-other", null);
      const t = insThr.run(`1.${i}`, k, `aaa-${String(i).padStart(4, "0")}`, null);
      insMem.run(Number(t.lastInsertRowid), k);
    }
    for (let i = 0; i < 500; i++) {
      const k = `chat:other-same-${i}`;
      insSess.run(k, `tok-${k}`, "ws-other", null);
      const t = insThr.run(`2.${i}`, k, "target-p", null);
      insMem.run(Number(t.lastInsertRowid), k);
    }
    for (let i = 0; i < 2500; i++) {
      const k = `chat:arch-${i}`;
      insSess.run(k, `tok-${k}`, "ws-1", 1000 + i);
      const t = insThr.run(`3.${i}`, k, "target-p", JSON.stringify(["archived-tag"]));
      insMem.run(Number(t.lastInsertRowid), k);
    }
    for (let i = 0; i < 2; i++) {
      const k = `chat:act-${i}`;
      insSess.run(k, `tok-${k}`, "ws-1", null);
      const t = insThr.run(`4.${i}`, k, "target-p", null);
      insMem.run(Number(t.lastInsertRowid), k);
    }
    // 1,100 active sessions for "big-proj", 1,099 for tag "tag-a", 1 for tag "tag-b"
    for (let i = 0; i < 1100; i++) {
      const k = `chat:big-${i}`;
      insSess.run(k, `tok-${k}`, "ws-1", null);
      const tag = i < 1099 ? "tag-a" : "tag-b";
      const t = insThr.run(`5.${i}`, k, "big-proj", JSON.stringify([tag]));
      insMem.run(Number(t.lastInsertRowid), k);
    }
    db.exec("COMMIT");

    // EXPLAIN QUERY PLAN must use active_thread_index_project and active_thread_tags!
    const planProj = db.prepare("EXPLAIN QUERY PLAN SELECT 1 FROM active_thread_index INDEXED BY active_thread_index_project WHERE ws = ? AND project = ? LIMIT 1").all("ws-1", "target-p") as { detail: string }[];
    assert.ok(planProj.some((r) => /active_thread_index_project/.test(r.detail)), `expected active_thread_index_project in plan: ${JSON.stringify(planProj)}`);
    const planTag = db.prepare("EXPLAIN QUERY PLAN SELECT tag FROM active_thread_tags WHERE ws = ? AND tag > ? ORDER BY tag LIMIT 1").all("ws-1", "") as { detail: string }[];
    assert.ok(planTag.some((r) => /active_thread_tags/.test(r.detail)), `expected active_thread_tags in plan: ${JSON.stringify(planTag)}`);

    assert.equal(store.hasActiveProjectInWorkspace("ws-1", "ws-home", "target-p"), true);
    const res = store.workspaceProjectNames("ws-1", "ws-home", 200);
    const byP = new Map(res.projects.map((p) => [p.name, p.count]));
    const byT = new Map(res.tags.map((t) => [t.name, t.count]));
    assert.equal(byP.get("target-p"), 2, "must count only the 2 active threads (zero archived, zero other-ws)");
    assert.equal(byP.get("big-proj"), 1100, "1,100 active sessions must return exact 1100");
    assert.equal(byT.get("tag-a"), 1099, "tag-a must return exact 1099");
    assert.equal(byT.get("tag-b"), 1, "tag-b must return exact 1");
    assert.equal(byT.has("archived-tag"), false, "archived tags must not appear");

    // Hot path cache: 2 consecutive ordinary messages -> 2nd delivery calls workspaceProjectNames 0 times!
    const r = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-hot" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s1, t1] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      r.store.setThreadClassification(t1.id, { project: "hot-proj", force: true });
      const { formatWorkspaceProjectsDelta } = await import("../src/sessions/projects.ts");
      const told = new Map();
      let sqlCalls = 0;
      const origWpn = r.store.workspaceProjectNames.bind(r.store);
      r.store.workspaceProjectNames = (...a: Parameters<typeof origWpn>) => { sqlCalls++; return origWpn(...a); };

      const d1 = await formatWorkspaceProjectsDelta(r.hub, s1, told);
      assert.ok(d1 !== null && d1.text.includes("hot-proj"));
      d1.markTold();
      assert.equal(sqlCalls, 1);

      // Append an ordinary user message (entries.length > 0) -> MUST NOT invalidate localProjectsCache!
      r.store.insertMessage({ thread: t1.id, ts: "99.1", authorKind: "person", author: "ada", text: "ordinary msg 2", attachments: [] });
      const d2 = await formatWorkspaceProjectsDelta(r.hub, s1, told);
      assert.equal(d2, null);
      assert.equal(sqlCalls, 1, "ordinary message delivery must hit hot cache with 0 SQL calls");
    } finally {
      await r.close();
    }
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R4-3: handover preserves target mid-move human lock, rolls back proposal_outcomes.info_synced 1->0, and gates old receiver catch-up", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r4-ho-"));
  const srcStore = Store.open(join(dir, "src.db"));
  const dstStore = Store.open(join(dir, "dst.db"));
  try {
    const dstThread = dstStore.openThread("slack:T1", "C9", "900.1", null, "ada@example.com");
    dstStore.insertMessage({ thread: dstThread.id, ts: "900.1", authorKind: "person", author: "ada", text: "hi", attachments: [] });
    dstStore.setThreadClassification(dstThread.id, { project: "initial-unlocked", lock: false, force: true });

    const srcThread = srcStore.openThread("slack:T1", "C9", "900.1", null, "ada@example.com");
    const [propN] = srcStore.insertMessage({
      thread: srcThread.id, ts: "900.2", authorKind: "agent", author: "chat:c-s", text: "propose", attachments: [],
      proposal: { id: "prop-ho", name: "A", status: "pending" },
    });
    srcStore.setThreadClassification(srcThread.id, { project: "A", lock: false, force: true });

    const srcDb = (srcStore as any).db;
    const dstDb = (dstStore as any).db;
    const ctx = handover.newCtx({ from: "st-src", here: "st-dst", fromData: dir, toData: dir, connects: {}, profiles: {}, ws: "ws-1" });
    const mkTouched = () => ({ threads: new Set<number>(), sessions: new Set<string>() });

    // Round 1
    handover.importRows(dstDb, ctx, "threads", handover.chatPage(srcDb, "threads", srcThread.id, null), mkTouched());
    handover.importRows(dstDb, ctx, "entries", handover.chatPage(srcDb, "entries", srcThread.id, null), mkTouched());

    // Target already had proposal_outcomes with info_synced = 0 on mapped entry n=2
    const mappedN = ctx.threads[String(srcThread.id)]!.ns[String(propN)]!;
    dstDb.prepare("INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at, info_synced) VALUES (?, ?, 'accepted', 'A', 'ada@example.com', 100, 0)").run(dstThread.id, mappedN);

    // During handover: target member sets human lock "human" on dstThread!
    dstStore.setThreadClassification(dstThread.id, { project: "human", lock: true, force: true });
    // Meanwhile source updates project to "src-late" and has matching outcome with info_synced = 1!
    srcStore.setThreadClassification(srcThread.id, { project: "src-late", lock: true, force: true });
    srcDb.prepare("INSERT INTO proposal_outcomes (thread, n, status, project, resolved_by, resolved_at, info_synced) VALUES (?, ?, 'accepted', 'A', 'ada@example.com', 100, 1)").run(srcThread.id, propN);

    // Catch-up: target's mid-move human lock MUST be preserved; proposal_outcomes info_synced advances 0 -> 1!
    handover.importRows(dstDb, ctx, "threads", handover.chatPage(srcDb, "threads", srcThread.id, null), mkTouched());
    handover.importRows(dstDb, ctx, "proposal_outcomes", handover.chatPage(srcDb, "proposal_outcomes", srcThread.id, null), mkTouched());
    assert.equal(dstStore.getThread(dstThread.id)?.project, "human", "target mid-handover human lock must NOT be overwritten by catch-up");
    assert.equal(dstStore.getThread(dstThread.id)?.projectLocked, true);
    assert.equal((dstDb.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(dstThread.id, mappedN) as any).info_synced, 1);

    // Rollback must restore proposal_outcomes.info_synced back to 0!
    handover.dropImport(dstDb, ctx);
    assert.equal((dstDb.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(dstThread.id, mappedN) as any).info_synced, 0, "dropImport must restore proposal_outcomes.info_synced back to 0");
  } finally {
    srcStore.close();
    dstStore.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R4-4, R4-5, R4-6, R4-7: explicit clear on resolve, tombstone prevents resurrection, 200+infoError, outbox 4 scenarios, stale-cache rename rejection, and NULL delivered thread inheritance", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r4-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  const store = Store.open(join(dir, "s.db"));
  try {
    const routes = projectRoutes({ store, data: dir, agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } } as any);
    const postResolve = routes.find((r) => r.method === "POST" && r.pattern.test("/threads/1/proposals/1/resolve"))!;

    // 1. Explicit clear: proposal has note & refs; accept passes note: "", refs: [] -> PROJECTS.jsonl has neither!
    const t1 = store.openThread("stillfail", "CHAT", "600.1", null, "ada@example.com");
    const [p1] = store.insertMessage({
      thread: t1.id, ts: "600.1", authorKind: "agent", author: "chat:c-1", text: "propose", attachments: [],
      proposal: { id: "prop-clr", name: "clear-me", note: "orig-note", refs: ["orig-ref"], status: "pending" },
    });
    const clrAns = await postResolve.handle(
      { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept", note: "", refs: [] })) } as any,
      [String(t1.id), String(p1)],
    );
    assert.equal(clrAns.status, 200);
    const afterClr = await readProjectsInfoStrict(agentHome, "ws-1", null);
    assert.equal(afterClr.projects["clear-me"]?.note, undefined, "explicit empty note must clear proposal note");
    assert.equal(afterClr.projects["clear-me"]?.refs, undefined, "explicit empty refs must clear proposal refs");

    // 2. Tombstone prevents resurrection when info_synced was interrupted at 0 and project was subsequently deleted!
    const t2 = store.openThread("stillfail", "CHAT", "600.2", null, "ada@example.com");
    const [p2] = store.insertMessage({
      thread: t2.id, ts: "600.2", authorKind: "agent", author: "chat:c-2", text: "propose", attachments: [],
      proposal: { id: "prop-tomb", name: "doomed", note: "n", status: "pending" },
    });
    const res2 = store.resolveProposal(t2.id, p2, { action: "accept", resolvedBy: "ada@example.com" });
    // Simulate file write succeeded, markProposalInfoSynced crashed (info_synced stays 0), then user deleted project!
    await updateProjectInfo(agentHome, "ws-1", null, { name: "doomed", note: "n", now: res2.proposal.resolvedAt! });
    await updateProjectInfo(agentHome, "ws-1", null, { name: "doomed", delete: true, now: res2.proposal.resolvedAt! + 10 });
    const replayAns = await postResolve.handle(
      { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept" })) } as any,
      [String(t2.id), String(p2)],
    );
    assert.equal(replayAns.status, 200);
    const afterTomb = await readProjectsInfoStrict(agentHome, "ws-1", null);
    assert.equal("doomed" in afterTomb.projects, false, "tombstone must prevent stale replay from resurrecting deleted project");

    // 3. File write failure returns 200 + infoError (keeping info_synced = 0), then recovery retry succeeds and sets info_synced = 1!
    const t3 = store.openThread("stillfail", "CHAT", "600.3", null, "ada@example.com");
    const [p3] = store.insertMessage({
      thread: t3.id, ts: "600.3", authorKind: "agent", author: "chat:c-3", text: "propose", attachments: [],
      proposal: { id: "prop-err", name: "retry-ok", status: "pending" },
    });
    const wsFile = projectsInfoPath(agentHome, "ws-1", null);
    const savedBefore = await readFile(wsFile, "utf8");
    await writeFile(wsFile, `${JSON.stringify({ name: "huge", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
    const errAns = await postResolve.handle(
      { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept" })) } as any,
      [String(t3.id), String(p3)],
    );
    assert.equal(errAns.status, 200, "resolve after DB commit must return 200 + infoError on file failure");
    const errBody = JSON.parse((errAns.body as Buffer).toString("utf8"));
    assert.ok(typeof errBody.infoError === "string" && errBody.infoError.length > 0);
    assert.equal(((store as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t3.id, p3) as any).info_synced, 0);
    // Recover file and retry -> succeeds and sets info_synced = 1!
    await writeFile(wsFile, savedBefore, "utf8");
    const recAns = await postResolve.handle(
      { viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1" }, body: Buffer.from(JSON.stringify({ action: "accept" })) } as any,
      [String(t3.id), String(p3)],
    );
    assert.equal(recAns.status, 200);
    assert.equal(JSON.parse((recAns.body as Buffer).toString("utf8")).infoError, undefined);
    assert.equal(((store as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t3.id, p3) as any).info_synced, 1);

    // 4. External proposal outbox 4 scenarios + stale-cache rename rejection + NULL delivered thread inheritance!
    const r = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r4" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s, homeThread] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      // (a) Stale peerProjectsCache has deleted "ghost" -> rename("ghost", "fabricated") MUST fail!
      r.hub.setPeerProjectsCache("ws-1", r.store.now(), ["ghost"]);
      r.hub.onPeer(async (target: string, req: any) => {
        if (target === "" && req?.method === "peers") return { stations: [{ id: "st-r4", online: true }] };
        return { exists: false };
      });
      await assert.rejects(() => projectManage(r.hub, s, { action: "rename", args: { from: "ghost", to: "fabricated" } }), /unknown project/);
      await assert.rejects(() => stat(join(r.config.agentHome, PROJECTS_INFO_FILE)));

      // (b) External proposal 4 scenarios:
      const extThread = r.store.openThread("slack:T1", "C01234567", "700.1", null, "ada@example.com");
      r.store.joinThread(extThread.id, s, "slack-1");
      let postCount = 0;
      let echoBeforeReturn = false;
      const fakeChat: any = {
        post: async () => {
          postCount++;
          const ts = `700.${postCount + 1}`;
          if (echoBeforeReturn) {
            // Simulate external platform echo landing before insertMessage with proposal = NULL!
            r.store.insertMessage({ thread: extThread.id, ts, authorKind: "agent", author: s, text: "echo", attachments: [] });
          }
          return ts;
        },
      };
      (r.hub as any).chat = () => fakeChat;

      // (b1) Concurrent calls -> only 1 external post!
      const [c1, c2] = await Promise.all([
        projectManage(r.hub, s, { action: "propose", args: { name: "ext-p", to: `C01234567/700.1` } }),
        projectManage(r.hub, s, { action: "propose", args: { name: "ext-p", to: `C01234567/700.1` } }),
      ]);
      assert.equal(postCount, 1, "concurrent propose must post externally only once");
      const firstProp = JSON.parse(c1);
      assert.equal(JSON.parse(c2).id, firstProp.id);

      // (b2) Dismiss then immediately re-propose same name -> posts NEW message with NEW entry & NEW ID!
      r.store.resolveProposal(extThread.id, firstProp.n, { action: "dismiss", resolvedBy: "ada@example.com" });
      const reProp = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "ext-p", to: `C01234567/700.1` } }));
      assert.equal(postCount, 2, "re-propose after dismiss must post a new message");
      assert.notEqual(reProp.n, firstProp.n);
      assert.notEqual(reProp.id, firstProp.id);
      r.store.resolveProposal(extThread.id, reProp.n, { action: "dismiss", resolvedBy: "ada@example.com" });

      // (b3) External echo lands before insertMessage -> attaches via append-only `entry_proposals` (single local message!) & resolves cleanly!
      const countBeforeEcho = r.store.entriesAfter(extThread.id, 0).length;
      echoBeforeReturn = true;
      const echoProp = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "ext-echo", to: `C01234567/700.1` } }));
      assert.equal(r.store.entriesAfter(extThread.id, 0).length, countBeforeEcho + 1, "echo collision must produce only 1 local message via entry_proposals sidecar");
      assert.equal(r.store.getEntry(extThread.id, echoProp.n)?.proposal?.id, echoProp.id);
      const resolvedEcho = r.store.resolveProposal(extThread.id, echoProp.n, { action: "accept", resolvedBy: "ada@example.com" });
      assert.equal(resolvedEcho.proposal.status, "accepted");
      echoBeforeReturn = false;

      // (b4) Simulated crash after chat.post persisted posted_ts in pending_proposals -> retry does NOT double-post and keeps same ID!
      const beforeCrashPosts = postCount;
      r.store.putPendingProposalOutbox(extThread.id, s, "crash-p", { id: "prop-crash-1", name: "crash-p", status: "pending" });
      r.store.setPendingProposalPostedTs(extThread.id, s, "crash-p", "700.999");
      const recovered = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "crash-p", to: `C01234567/700.1` } }));
      assert.equal(postCount, beforeCrashPosts, "outbox recovery with posted_ts must NOT double-post externally");
      assert.equal(recovered.id, "prop-crash-1");
      assert.equal(recovered.ts, "700.999");

      // (c) Sub-session inheritance: home thread has project "home-proj", but most recently delivered external thread has project = NULL ->
      //     child opened by `chatCreate` must NOT inherit "home-proj"!
      r.store.setThreadClassification(homeThread.id, { project: "home-proj", force: true });
      const nullExt = r.store.openThread("slack:T1", "C-NULL", "800.1", null, "ada@example.com");
      r.store.joinThread(nullExt.id, s, "slack-1");
      const [en] = r.store.insertMessage({ thread: nullExt.id, ts: "800.1", authorKind: "person", author: "u", text: "unclassified", attachments: [] });
      r.store.deliver(nullExt.id, en, [s]);
      r.store.markDelivered(s, [{ thread: nullExt.id, n: en, ts: "800.1", at: 9000, authorKind: "person", author: "u", text: "unclassified", attachments: [] } as any]);
      const { chatCreate } = await import("../src/sessions/opened.ts");
      await chatCreate(r.hub, s, { for: "me", key: "k-null-inherit", text: "child task" });
      const openedRec = r.store.openedWith("", s, "k-null-inherit", "");
      assert.ok(openedRec !== null);
      const childThread = r.store.latestThread(openedRec.child)?.thread;
      assert.equal(childThread?.project, undefined, "child must NOT inherit home project when most recently delivered thread is unclassified (NULL)");
    } finally {
      await r.close();
    }
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R5 P1-1, P1-2, P1-3: multi-agent rejoin DISTINCT, legacy DB without left_at upgrade + meta recovery, and reverse-index EXPLAIN", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r5-sql-"));
  const store = Store.open(join(dir, "s.db"));
  const db = (store as any).db;
  try {
    // P1-1: Two agents in same workspace on a classified+tagged thread; one leaves and rejoins -> ZERO UNIQUE error, count = 1!
    const t = store.openThread("slack:T1", "C555", "10.1", null, "ada@example.com");
    store.setThreadClassification(t.id, { project: "multi-p", tags: ["t1"], force: true });
    db.prepare("INSERT INTO sessions (key, scope, runtime, profile, model, connect, workspace, cwd, token, created_by, created_at, last_active_at, ws) VALUES (?, 'chat', 'claude', 'cc', 'm', 'chat', '/w', '/w', ?, 'u', 1000, 1000, 'ws-1')").run("chat:a1", "tok-a1");
    db.prepare("INSERT INTO sessions (key, scope, runtime, profile, model, connect, workspace, cwd, token, created_by, created_at, last_active_at, ws) VALUES (?, 'chat', 'claude', 'cc', 'm', 'chat', '/w', '/w', ?, 'u', 1000, 1000, 'ws-1')").run("chat:a2", "tok-a2");
    store.joinThread(t.id, "chat:a1", "slack-1");
    store.joinThread(t.id, "chat:a2", "slack-1");
    assert.equal(store.leaveThread(t.id, "chat:a2"), true);
    assert.equal(store.joinThread(t.id, "chat:a2", "slack-1"), true, "rejoin must not throw UNIQUE constraint failed");
    const agg = store.workspaceProjectNames("ws-1", "ws-home", 50);
    assert.equal(agg.projects.find((p) => p.name === "multi-p")?.count, 1);
    assert.equal(agg.tags.find((x) => x.name === "t1")?.count, 1);

    // P1-3: EXPLAIN QUERY PLAN for reverse-index DELETEs!
    const p1 = db.prepare("EXPLAIN QUERY PLAN DELETE FROM active_thread_index WHERE thread = ?").all(t.id) as { detail: string }[];
    assert.ok(p1.some((r) => /active_thread_index_thread/.test(r.detail)), `expected active_thread_index_thread in plan: ${JSON.stringify(p1)}`);
    const p2 = db.prepare("EXPLAIN QUERY PLAN DELETE FROM active_thread_tags WHERE ws = ? AND thread = ?").all("ws-1", t.id) as { detail: string }[];
    assert.ok(p2.some((r) => /active_thread_tags_thread/.test(r.detail)), `expected active_thread_tags_thread in plan: ${JSON.stringify(p2)}`);

    // P1-2: Legacy DB missing `thread_sessions.left_at` opens cleanly on FIRST Store.open and backfills active_thread_index!
    const legacyPath = join(dir, "legacy.db");
    const { DatabaseSync } = await import("node:sqlite");
    const leg = new DatabaseSync(legacyPath);
    leg.exec(`
      PRAGMA user_version = 13;
      CREATE TABLE sessions (key TEXT PRIMARY KEY, connect TEXT NOT NULL, scope TEXT NOT NULL, title TEXT, created_by TEXT, runtime TEXT NOT NULL, profile TEXT NOT NULL, profile_pinned INTEGER NOT NULL DEFAULT 0, profiles TEXT, model TEXT, effort TEXT, fast INTEGER, speed TEXT, tui INTEGER, afresh INTEGER, context INTEGER, context_before INTEGER, compactions INTEGER, runtime_session_id TEXT, workspace TEXT NOT NULL, cwd TEXT, token TEXT NOT NULL UNIQUE, running INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, last_active_at INTEGER NOT NULL, archived_at INTEGER, ws TEXT);
      CREATE TABLE threads (id INTEGER PRIMARY KEY AUTOINCREMENT, surface TEXT NOT NULL, channel TEXT NOT NULL, thread_ts TEXT NOT NULL, home TEXT, created_by TEXT, title TEXT, title_from TEXT, created_at INTEGER NOT NULL, hidden_at INTEGER, project TEXT, project_locked INTEGER NOT NULL DEFAULT 0, tags TEXT, UNIQUE(surface, channel, thread_ts));
      CREATE TABLE thread_sessions (thread INTEGER NOT NULL, session TEXT NOT NULL, connect TEXT NOT NULL, joined_at INTEGER NOT NULL, PRIMARY KEY (thread, session));
      INSERT INTO sessions (key, connect, scope, runtime, profile, workspace, token, created_at, last_active_at, ws) VALUES ('chat:leg1', 'chat', 'chat', 'claude', 'cc', '/w', 'tok-leg1', 100, 100, 'ws-leg');
      INSERT INTO threads (id, surface, channel, thread_ts, home, created_at, project, tags) VALUES (1, 'stillfail', 'CHAT', '1.1', 'chat:leg1', 100, 'legacy-proj', '["leg-tag"]');
      INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (1, 'chat:leg1', 'chat', 100);
    `);
    leg.close();

    const legStore = Store.open(legacyPath);
    try {
      assert.equal(legStore.hasActiveProjectInWorkspace("ws-leg", "ws-home", "legacy-proj"), true, "legacy DB without left_at must upgrade & backfill on first open");
      assert.equal(legStore.workspaceProjectNames("ws-leg", "ws-home", 50).tags.find((x) => x.name === "leg-tag")?.count, 1);

      // Interrupted backfill recovery: wipe active_thread_index + delete _project_index_meta marker, reopen -> auto re-backfills!
      (legStore as any).db.exec("DELETE FROM active_thread_index; DELETE FROM active_thread_tags; DELETE FROM _project_index_meta;");
    } finally {
      legStore.close();
    }
    const legStore2 = Store.open(legacyPath);
    try {
      assert.equal(legStore2.hasActiveProjectInWorkspace("ws-leg", "ws-home", "legacy-proj"), true, "missing _project_index_meta must trigger automatic re-backfill on reopen");
    } finally {
      legStore2.close();
    }
  } finally {
    store.close();
    await rm(dir, { recursive: true, force: true });
  }
});

test("R5 P1-4, P1-5, P1-6, P1-7, P1-8, P1-9: uncertain receipt outbox, explicit clear on existing project, Idempotency-Key retry after infoError, 6-permutation tombstones, and dropImport preserves target human lock", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r5-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    // P1-8: All 6 permutations of [old@10, del@20, new@30] produce identical output without old@10, and re-appending old@10 never resurrects!
    const { parseProjectsJsonlWithRaw, serializeProjectsJsonl } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const oldLine = JSON.stringify({ name: "p", note: "old-note", refs: ["old-ref"], updatedAt: 10 });
    const delLine = JSON.stringify({ name: "p", deleted: true, updatedAt: 20 });
    const newLine = JSON.stringify({ name: "p", note: "new-note", refs: ["new-ref"], updatedAt: 30 });
    const perms = [
      [oldLine, delLine, newLine],
      [oldLine, newLine, delLine],
      [delLine, oldLine, newLine],
      [delLine, newLine, oldLine],
      [newLine, oldLine, delLine],
      [newLine, delLine, oldLine],
    ];
    let baselineSerialized = "";
    for (const perm of perms) {
      const txt = `${perm.join("\n")}\n`;
      const parsed = parseProjectsJsonlWithRaw(txt, { strict: true });
      assert.equal(parsed.doc.projects["p"]?.note, "new-note");
      assert.deepEqual(parsed.doc.projects["p"]?.refs, ["new-ref"]);
      const ser = serializeProjectsJsonl(parsed.doc, parsed.preservedRawLines, parsed.tombstones);
      const cmp = compactProjectsJsonl(txt);
      assert.equal(ser, cmp, "serializeProjectsJsonl and compactProjectsJsonl must match identically across all 6 permutations");
      if (baselineSerialized === "") baselineSerialized = ser;
      else assert.equal(ser, baselineSerialized);
    }
    // Re-appending old@10 after serialization (which carries deletedAt: 20) still drops old@10!
    const withLaggingOld = `${baselineSerialized}${oldLine}\n`;
    const reparsed = parseProjectsJsonlWithRaw(withLaggingOld, { strict: true });
    assert.equal(reparsed.doc.projects["p"]?.note, "new-note");
    assert.deepEqual(reparsed.doc.projects["p"]?.refs, ["new-ref"]);

    // P1-6 & P1-7: Registered project with existing note & refs explicitly cleared via resolve; AND Admin.handle with same Idempotency-Key retries after infoError!
    const { Admin } = await import("../src/api/admin.ts");
    const store = Store.open(join(dir, "s.db"));
    try {
      await updateProjectInfo(agentHome, "ws-1", null, { name: "existing-p", note: "old-n", refs: ["old-r"], now: 100 });
      const t = store.openThread("stillfail", "CHAT", "100.1", null, "ada@example.com");
      const [pN] = store.insertMessage({
        thread: t.id, ts: "100.1", authorKind: "agent", author: "chat:c-1", text: "propose", attachments: [],
        proposal: { id: "prop-clr-ex", name: "existing-p", note: "prop-n", refs: ["prop-r"], status: "pending" },
      });
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      const savedGood = await readFile(wsFile, "utf8");
      // Corrupt with oversize > 512 KiB to trigger infoError on first Admin.handle call with Idempotency-Key!
      await writeFile(wsFile, `${JSON.stringify({ name: "huge", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq = () => ({
        method: "POST",
        path: `/threads/${t.id}/proposals/${pN}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r5-1" },
        body: Buffer.from(JSON.stringify({ action: "accept", note: "", refs: [] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      const ans1 = await admin.handle(mkReq());
      assert.equal(ans1.status, 200);
      assert.ok(JSON.parse((ans1.body as Buffer).toString("utf8")).infoError, "first call must return 200 + infoError");

      // Fix file and retry with SAME Idempotency-Key -> Admin.once must NOT return cached infoError; must write file & clear note/refs!
      await writeFile(wsFile, savedGood, "utf8");
      const ans2 = await admin.handle(mkReq());
      assert.equal(ans2.status, 200);
      assert.equal(JSON.parse((ans2.body as Buffer).toString("utf8")).infoError, undefined, "retry with same Idempotency-Key must reconcile & succeed without infoError");
      const afterClear = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.equal(afterClear.projects["existing-p"]?.note, undefined, "explicit clear must remove existing project's old note");
      assert.equal(afterClear.projects["existing-p"]?.refs, undefined, "explicit clear must remove existing project's old refs");
      assert.equal(((store as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t.id, pN) as any).info_synced, 1);
    } finally {
      store.close();
    }

    // P1-4: Uncertain receipt window (setPendingProposalPostedTs throws) -> in-process retry & restart+echo & restart-no-echo all post <= 1 time!
    const r = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r5" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const extT = r.store.openThread("slack:T1", "C88888888", "50.1", null, "ada@example.com");
      r.store.joinThread(extT.id, s, "slack-1");
      let sends = 0;
      (r.hub as any).chat = () => ({ post: async () => `50.${++sends + 1}` });
      const origSetTs = r.store.setPendingProposalPostedTs.bind(r.store);
      let failOnce = true;
      r.store.setPendingProposalPostedTs = (...a: Parameters<typeof origSetTs>) => {
        if (failOnce) { failOnce = false; throw new Error("simulated DB write failure after chat.post"); }
        return origSetTs(...a);
      };
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "uncertain-p", to: "C88888888/50.1" } }), /simulated DB write failure/);
      assert.equal(sends, 1);
      // In-process retry recovers from hub.postedProposalsByOutboxId without double-posting!
      const recInProc = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "uncertain-p", to: "C88888888/50.1" } }));
      assert.equal(sends, 1, "in-process retry after receipt persist failure must NOT double-post");
      assert.equal(recInProc.ts, "50.2");

      // Simulated restart with sending=1, posted_ts=NULL and NO echo yet -> refuses to double-post!
      r.store.putPendingProposalOutbox(extT.id, s, "restart-p", { id: "prop-rst", name: "restart-p", status: "pending" }, r.store.lastEntry(extT.id));
      r.store.markPendingProposalSending(extT.id, s, "restart-p");
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "restart-p", to: "C88888888/50.1" } }), /uncertain/i);
      assert.equal(sends, 1, "restart without echo must refuse to double-post");

      // Once external echo arrives in entries (carrying real NOTICE_MARK), retry reconciles via entry_proposals with 0 extra posts!
      const { stationLang } = await import("../src/ops/i18n.ts");
      const { markNotice } = await import("../src/sessions/chat.ts");
      const echoLink = `${r.hub.link(s)}?thread=${extT.id}#proposal=prop-rst`;
      const echoText = stationLang() === "zh"
        ? `建议新建项目「restart-p」并将当前对话归入该项目。\n请在 still.fail 中确认：${echoLink}`
        : `Proposed creating project "restart-p" and assigning this conversation to it.\nConfirm in still.fail: ${echoLink}`;
      // Plain same-text message WITHOUT NOTICE_MARK must NOT be hijacked as an echo!
      r.store.insertMessage({ thread: extT.id, ts: "50.98", authorKind: "agent", author: s, text: echoText, attachments: [] });
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "restart-p", to: "C88888888/50.1" } }), /uncertain/i);
      // Real markNotice(echoText) echo reconciles cleanly!
      r.store.insertMessage({ thread: extT.id, ts: "50.99", authorKind: "agent", author: s, text: markNotice(echoText), attachments: [] });
      const recEcho = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "restart-p", to: "C88888888/50.1" } }));
      assert.equal(sends, 1, "echo reconciliation must NOT double-post");
      assert.equal(recEcho.id, "prop-rst");
      assert.equal(r.store.getEntry(extT.id, recEcho.n)?.proposal?.id, "prop-rst");

      // Non-consecutive message gap + messagePageEntries + askingMessage exclusion for entry_proposals sidecar!
      r.store.insertMessage({ thread: extT.id, ts: "50.99b", authorKind: "agent", author: s, text: "gap-entry", attachments: [] });
      const [afterEvN] = r.store.insertMessage({ thread: extT.id, ts: "50.100", authorKind: "agent", author: s, text: "after-ev", attachments: [] });
      assert.ok(afterEvN > recEcho.n + 1, "numbers must be non-consecutive to hit MESSAGE_PAGE_ENTRIES");
      const page = r.store.messagePageEntries(extT.id, [recEcho.n, afterEvN]);
      assert.equal(page.find((e) => e.n === recEcho.n)?.proposal?.id, "prop-rst", "messagePageEntries must include entry_proposals sidecar across gaps");
      assert.equal(r.store.askingMessage(extT.id, recEcho.n, [0, r.store.now() + 1000]), null, "askingMessage must exclude entry_proposals sidecar");
    } finally {
      await r.close();
    }

    // P1-9: dropImport preserves target member's mid-handover human lock ("human"/1), while still restoring untouched thread (NULL/0)!
    const srcS = Store.open(join(dir, "ho-src.db"));
    const dstS = Store.open(join(dir, "ho-dst.db"));
    try {
      const dstT1 = dstS.openThread("slack:T1", "C1", "10.1", null, "ada@example.com");
      const dstT2 = dstS.openThread("slack:T1", "C2", "20.1", null, "ada@example.com");
      const srcT1 = srcS.openThread("slack:T1", "C1", "10.1", null, "ada@example.com");
      const srcT2 = srcS.openThread("slack:T1", "C2", "20.1", null, "ada@example.com");
      srcS.setThreadClassification(srcT1.id, { project: "A", lock: false, force: true });
      srcS.setThreadClassification(srcT2.id, { project: "B", lock: false, force: true });
      const ctx = handover.newCtx({ from: "st-s", here: "st-d", fromData: dir, toData: dir, connects: {}, profiles: {}, ws: "ws-1" });
      const mkT = () => ({ threads: new Set<number>(), sessions: new Set<string>() });
      handover.importRows((dstS as any).db, ctx, "threads", handover.chatPage((srcS as any).db, "threads", srcT1.id, null), mkT());
      handover.importRows((dstS as any).db, ctx, "threads", handover.chatPage((srcS as any).db, "threads", srcT2.id, null), mkT());
      assert.equal(dstS.getThread(dstT1.id)?.project, "A");
      assert.equal(dstS.getThread(dstT2.id)?.project, "B");
      // Target member locks dstT1 to "human"/1 during handover; dstT2 stays untouched ("B"/0).
      dstS.setThreadClassification(dstT1.id, { project: "human", lock: true, force: true });
      // Cancel handover via dropImport!
      handover.dropImport((dstS as any).db, ctx);
      assert.equal(dstS.getThread(dstT1.id)?.project, "human", "dropImport must preserve target member's mid-handover human lock");
      assert.equal(dstS.getThread(dstT1.id)?.projectLocked, true);
      assert.equal(dstS.getThread(dstT2.id)?.project, undefined, "dropImport must restore untouched thread back to NULL");
    } finally {
      srcS.close();
      dstS.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R6 P1-1..P1-6 & P2: disconnect/reject/10m-TTL outbox, markNotice echo & no-hijack, platform bot author dedup, stateQuestion sidecar, field-level clear watermarks, monotonic tombstones, and handover warn", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r6-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { makeStore: makeReadStore, stateQuestion } = await import("../src/read/store.ts");
    const { Readers } = await import("../src/read/pool.ts");
    const { parseProjectsJsonlWithRaw, serializeProjectsJsonl, renameProjectInfo } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1, 2, 3: Outbox disconnect/reject/10m TTL + built-in local path + markNotice echo & no-hijack + platform bot author dedup
    let clockMs = 1_700_000_000_000;
    const r = new Rig({ link: true, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r6" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.config = hubConfig(r.raw, r.dir);
    (r.store as any).now = () => clockMs;
    try {
      const [s, localT] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });

      // Built-in still.fail chat posts directly without pending_proposals stuck state.
      const localRes = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "local-p" } }));
      assert.equal(localRes.proposed, true);
      assert.equal(r.store.getPendingProposalOutbox(localT.id, s, "local-p"), null, "built-in chat must not leave pending_proposals");

      // External thread tests:
      const extT = r.store.openThread("slack:T1", "C77777777", "70.1", null, "ada@example.com");
      r.store.joinThread(extT.id, s, "slack-1");
      let extSends = 0;
      let mode: "disconnected" | "reject" | "timeout" | "ok" = "disconnected";
      (r.hub as any).chat = () => {
        if (mode === "disconnected") throw new Error("connect slack-1 is not running");
        return {
          post: async () => {
            if (mode === "reject") throw new Error("slack_api failed: channel_not_found");
            if (mode === "timeout") throw new Error("request timed out (ETIMEDOUT)");
            return `70.${++extSends + 1}`;
          },
        };
      };

      // 1a. Channel disconnected before post -> outbox NOT poisoned -> reconnect succeeds!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "disc-p", to: "C77777777/70.1" } }), /not running/);
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "disc-p"), null, "disconnect before post must not poison outbox");
      mode = "ok";
      const discOk = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "disc-p", to: "C77777777/70.1" } }));
      assert.equal(discOk.proposed, true);
      assert.equal(extSends, 1);

      // 1b. Deterministic platform rejection (channel_not_found) -> resets outbox -> next retry succeeds!
      mode = "reject";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "rej-p", to: "C77777777/70.1" } }), /channel_not_found/);
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "rej-p"), null, "deterministic rejection must clear outbox");
      mode = "ok";
      const rejOk = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "rej-p", to: "C77777777/70.1" } }));
      assert.equal(rejOk.proposed, true);
      assert.equal(extSends, 2);

      // 1c. Uncertain timeout -> NEVER blindly auto-retries even after advancing clock +10 min (total sends stays 2)!
      mode = "timeout";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "ttl-p", to: "C77777777/70.1" } }), /ETIMEDOUT/);
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "ttl-p")?.sending, true);
      mode = "ok";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "ttl-p", to: "C77777777/70.1" } }), /uncertain/i);
      clockMs += 10 * 60_000 + 1;
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "ttl-p", to: "C77777777/70.1" } }), /uncertain/i);
      assert.equal(extSends, 2, "uncertain timeout must NEVER blindly double-post even after 10 minutes");

      // 2. Real markNotice(text) echo reconciliation vs plain message / person message non-hijack
      const propObj = { id: "prop-echo-r6", name: "echo-r6", proposer: s, status: "pending" as const };
      r.store.putPendingProposalOutbox(extT.id, s, "echo-r6", propObj, r.store.lastEntry(extT.id), "slack-1");
      r.store.markPendingProposalSending(extT.id, s, "echo-r6");
      const expectedText = renderProposalText(r.hub, extT, s, propObj);
      // Plain text (no NOTICE_MARK) and person-authored message (even with NOTICE_MARK) must NOT match!
      r.store.insertMessage({ thread: extT.id, ts: "70.50", authorKind: "agent", author: "U_BOT_SLACK", text: expectedText, attachments: [] });
      r.store.insertMessage({ thread: extT.id, ts: "70.51", authorKind: "person", author: "U_HUMAN", text: markNotice(expectedText), attachments: [] });
      assert.equal(r.store.findEchoEntryAfter(extT.id, 0, expectedText, propObj.id), null, "must never match plain message or person message");
      // Real bot notice echo with markNotice(expectedText) matches & attaches via entry_proposals!
      const [echoN] = r.store.insertMessage({ thread: extT.id, ts: "70.52", authorKind: "agent", author: "U_BOT_SLACK", text: markNotice(expectedText), attachments: [] });
      const rec = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "echo-r6", to: "C77777777/70.1" } }));
      assert.equal(rec.id, "prop-echo-r6");
      assert.equal(rec.n, echoN);
      assert.equal(extSends, 2, "reconciled echo must not send again");
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "echo-r6"), null, "verified attachment clears outbox");

      // 3. Platform bot author ("U_BOT_SLACK") echo already attached -> consecutive proposeProject calls send 0 extra times & keep original author!
      const dup1 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "echo-r6", to: "C77777777/70.1" } }));
      const dup2 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "echo-r6", to: "C77777777/70.1" } }));
      assert.equal(dup1.id, "prop-echo-r6");
      assert.equal(dup1.deduplicated, true);
      assert.equal(dup2.id, "prop-echo-r6");
      assert.equal(dup2.deduplicated, true);
      assert.equal(extSends, 2, "platform bot author echo must deduplicate subsequent retries without double-posting");
      const keptEntry = r.store.getEntry(extT.id, echoN);
      assert.equal(keptEntry?.author, "U_BOT_SLACK", "original platform bot author must stay intact");

      // 4. stateQuestion (TS + MoonBit Reader) rejects entry_proposals sidecar proposal as { kind: "proposal" }, allows ordinary question!
      const [qN] = r.store.insertMessage({ thread: extT.id, ts: "70.60", authorKind: "agent", author: s, text: "Which option do you prefer?", attachments: [] });
      const readStore = makeReadStore((r.store as any).db, r.dir);
      assert.deepEqual(stateQuestion(readStore, s, [extT.id], "70.52"), { kind: "proposal" }, "TS stateQuestion must reject sidecar entry_proposals as proposal");
      assert.equal(stateQuestion(readStore, s, [extT.id], "70.60").kind, "found", "TS stateQuestion must accept ordinary question");

      const readers = new Readers(r.dir, 1);
      try {
        const mbProp = JSON.parse(await readers.read("stateQuestion", { key: s, threads: [extT.id], ts: "70.52" }, "en"));
        const mbQ = JSON.parse(await readers.read("stateQuestion", { key: s, threads: [extT.id], ts: "70.60" }, "en"));
        assert.deepEqual(mbProp, { kind: "proposal" }, "MoonBit state_question must reject sidecar entry_proposals as proposal");
        assert.equal(mbQ.kind, "found", "MoonBit state_question must accept ordinary question");
      } finally {
        await readers.close();
      }
      assert.ok(qN > echoN);
    } finally {
      await r.close();
    }

    // 5. Field-level clear watermarks (`noteClearedAt` / `refsClearedAt`) across no-common-ancestor merge + subsequent legal addition
    await updateProjectInfo(agentHome, "ws-1", null, { name: "clr-proj", note: "old-note", refs: ["old-ref"], now: 100 });
    const oldSnapBuf = await readFile(projectsInfoPath(agentHome, "ws-1", null));
    await updateProjectInfo(agentHome, "ws-1", null, { name: "clr-proj", note: null, refs: null, now: 100 });
    const clearedSnapBuf = await readFile(projectsInfoPath(agentHome, "ws-1", null));
    const hOld = sha(oldSnapBuf);
    const hClr = sha(clearedSnapBuf);
    const recOld: Rec = { hash: hOld, at: 100, by: "a".repeat(64), prev: [], size: oldSnapBuf.length, mode: 0o644 };
    const recClr: Rec = { hash: hClr, at: 101, by: "b".repeat(64), prev: [], size: clearedSnapBuf.length, mode: 0o644 };
    const blobs1 = new Map([[hOld, oldSnapBuf], [hClr, clearedSnapBuf]]);
    const tsMergedClr = decide("PROJECTS.jsonl", recClr, recOld, (h: string) => blobs1.get(h) ?? null, (id: string) => id);
    assert.equal(tsMergedClr.kind, "merge");
    const parsedClr = parseProjectsJsonlWithRaw(tsMergedClr.content!.toString("utf8"), { strict: true });
    assert.equal(parsedClr.doc.projects["clr-proj"]?.note, undefined, "cleared note must not resurrect on no-ancestor merge");
    assert.equal(parsedClr.doc.projects["clr-proj"]?.refs, undefined, "cleared refs must not resurrect on no-ancestor merge");
    assert.ok(typeof parsedClr.doc.projects["clr-proj"]?.noteClearedAt === "number");
    assert.ok(typeof parsedClr.doc.projects["clr-proj"]?.refsClearedAt === "number");

    const mbMergedClr = await memoryProgram().ask<any>("decide", {
      path: "PROJECTS.jsonl",
      mine: recClr,
      theirs: recOld,
      names: { [recClr.by]: "b", [recOld.by]: "a" },
      given: { [hOld]: oldSnapBuf.toString("hex"), [hClr]: clearedSnapBuf.toString("hex") },
      blobs: join(dir, "blobs-r6-clr"),
      prevMost: 16,
    });
    assert.equal(mbMergedClr.rec.hash, tsMergedClr.rec.hash, "MoonBit and TS field-level clear merge must be byte-for-byte identical");

    // Subsequent addition of new refs at higher timestamp preserves only new refs, never old note or old ref!
    await updateProjectInfo(agentHome, "ws-1", null, { name: "clr-proj", refs: ["new-ref"], now: 120 });
    const addedBuf = await readFile(projectsInfoPath(agentHome, "ws-1", null));
    const mergedAddedText = compactProjectsJsonl(`${addedBuf.toString("utf8")}${oldSnapBuf.toString("utf8")}`);
    const parsedAdded = parseProjectsJsonlWithRaw(mergedAddedText, { strict: true });
    assert.equal(parsedAdded.doc.projects["clr-proj"]?.note, undefined, "old note must still stay cleared");
    assert.deepEqual(parsedAdded.doc.projects["clr-proj"]?.refs, ["new-ref"], "new ref after clear watermark must be kept while old ref stays suppressed");

    // 6. Same-millisecond delete -> recreate -> delete (now=110) + clock-ahead live entry (updatedAt=500) deletion
    await updateProjectInfo(agentHome, "ws-1", null, { name: "mono-p", note: "v1", now: 100 });
    await updateProjectInfo(agentHome, "ws-1", null, { name: "mono-p", delete: true, now: 110 });
    await updateProjectInfo(agentHome, "ws-1", null, { name: "mono-p", note: "recreated", now: 110 });
    const recreatedCopy = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    await updateProjectInfo(agentHome, "ws-1", null, { name: "mono-p", delete: true, now: 110 });
    const finalDeleted = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const afterMonoMerge = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${finalDeleted}${recreatedCopy}`), { strict: true });
    assert.equal(afterMonoMerge.doc.projects["mono-p"], undefined, "same-ms delete->recreate->delete must not resurrect recreated@111");

    // Clock-ahead remote live entry (updatedAt=500) deleted at local clock now=110 -> merged with old copy stays deleted!
    await updateProjectInfo(agentHome, "ws-1", null, { name: "ahead-p", note: "future", now: 500 });
    const aheadCopy = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    await updateProjectInfo(agentHome, "ws-1", null, { name: "ahead-p", delete: true, now: 110 });
    const aheadDeleted = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const afterAheadMerge = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${aheadDeleted}${aheadCopy}`), { strict: true });
    assert.equal(afterAheadMerge.doc.projects["ahead-p"], undefined, "deleting clock-ahead live entry must write tombstone >= updatedAt");

    // renameProjectInfo also writes monotonic tombstone >= src.updatedAt
    await updateProjectInfo(agentHome, "ws-1", null, { name: "ren-src", note: "future-src", now: 600 });
    const renSrcCopy = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    await renameProjectInfo(agentHome, "ws-1", null, "ren-src", "ren-dst", 120);
    const renAfter = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const afterRenMerge = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${renAfter}${renSrcCopy}`), { strict: true });
    assert.equal(afterRenMerge.doc.projects["ren-src"], undefined, "renameProjectInfo tombstone must cover clock-ahead src.updatedAt");
    assert.ok(afterRenMerge.doc.projects["ren-dst"] !== undefined);

    // 7. Handover to older station checks entry_proposals sidecar as well as entries.proposal
    const handoverSrc = await readFile(join(process.cwd(), "src/replica/handover.ts"), "utf8");
    assert.match(handoverSrc, /FROM entry_proposals WHERE thread = \? LIMIT 1/, "handover degrade warning must also check entry_proposals");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R7 final polish: open_proposals O(log N) & 0-scan entries, uncertain errors never retry, concurrent dual-agent ambiguous echo & non-ownBot guard, field-level noteAt/refsAt & local-empty clear & slow-clock rename & >512KiB compaction & handover warn", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r7-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { applyProposalInfoSync, parseProjectsJsonlWithRaw, renameProjectInfo } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1. open_proposals O(log N) lookup with 1,000 unrelated pending proposals + no entries_proposal index in schema
    const schemaTs = await readFile(join(process.cwd(), "src/store/schema.ts"), "utf8");
    const schemaMbt = await readFile(join(process.cwd(), "mb/src/store_schema/schema.mbt"), "utf8");
    assert.equal(schemaTs.includes("entries_proposal"), false, "schema.ts must not create entries_proposal index on entries");
    assert.equal(schemaMbt.includes("entries_proposal"), false, "schema.mbt must not create entries_proposal index on entries");

    const store = Store.open(join(dir, "open-prop.db"));
    try {
      const t = store.openThread("stillfail", "CHAT", "800.1", null, "ada@example.com");
      const db = (store as any).db;
      db.exec("BEGIN");
      const ins = db.prepare("INSERT INTO entries (thread, n, ts, kind, author_kind, author, text, attachments, proposal, at) VALUES (?, ?, ?, 'message', 'agent', 'chat:other', 'p', '[]', ?, 1000)");
      for (let i = 1; i <= 1000; i++) {
        ins.run(t.id, i, `800.${i}`, JSON.stringify({ id: `p-${i}`, name: `other-${i}`, proposer: "chat:other", status: "pending" }));
      }
      db.exec("COMMIT");
      const [targetN] = store.insertMessage({
        thread: t.id, ts: "800.2000", authorKind: "agent", author: "U_BOT_SLACK", text: "target", attachments: [],
        proposal: { id: "prop-target-r7", name: "target-p", proposer: "chat:me", status: "pending" },
      });
      const plan = db.prepare(
        `EXPLAIN QUERY PLAN
         SELECT o.n, e.ts, COALESCE(e.proposal, ep.proposal) AS proposal
         FROM open_proposals o
         JOIN entries e ON e.thread = o.thread AND e.n = o.n
         LEFT JOIN entry_proposals ep ON ep.thread = o.thread AND ep.n = o.n
         LEFT JOIN proposal_outcomes po ON po.thread = o.thread AND po.n = o.n
         WHERE o.thread = ? AND o.proposer = ? AND o.name = ? AND po.thread IS NULL
         ORDER BY o.n DESC LIMIT 1`,
      ).all(t.id, "chat:me", "target-p") as { detail: string }[];
      assert.ok(plan.some((p) => /SEARCH o USING (PRIMARY KEY|COVERING INDEX|INDEX)/.test(p.detail)), `expected indexed open_proposals lookup, got: ${JSON.stringify(plan)}`);
      const found = store.findPendingProposal(t.id, "chat:me", "target-p");
      assert.equal(found?.n, targetN);
      assert.equal(found?.proposal.id, "prop-target-r7");
      assert.equal(store.findPendingProposal(t.id, "chat:me", "nonexistent"), null);
    } finally {
      store.close();
    }

    // 2 & 3. Missing seq/message_id stays uncertain (never retries), 429 definite reject clears outbox,
    //        concurrent dual-agent identical degraded text out-of-order echo + non-ownBot guard
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r7" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [{ id: "slack-1", type: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [sA] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const [sB] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const extT = r.store.openThread("slack:T1", "C66666666", "90.1", null, "ada@example.com");
      r.store.joinThread(extT.id, sA, "slack-1");
      r.store.joinThread(extT.id, sB, "slack-1");

      let postMode: "feishu-no-id" | "comma-no-seq" | "429" | "ok" = "feishu-no-id";
      let totalSends = 0;
      const fakeBot = {
        botUserId: () => "U_OWN_BOT",
        workspace: () => "T1",
        post: async () => {
          totalSends++;
          if (postMode === "feishu-no-id") throw new Error("feishu post succeeded without message_id");
          if (postMode === "comma-no-seq") throw new Error("comma response missing seq");
          if (postMode === "429") throw new Error("HTTP 429 rate_limited");
          return `90.${totalSends + 10}`;
        },
      };
      (r.hub as any).chat = () => fakeBot;
      (r.hub as any).chatOf = (id: string) => (id === "slack-1" ? fakeBot : undefined);

      // Feishu missing message_id -> uncertain -> keeps sending=1, immediate retry does NOT re-send!
      await assert.rejects(() => projectManage(r.hub, sA, { action: "propose", args: { name: "feishu-p", to: "C66666666/90.1" } }), /message_id/);
      assert.equal(totalSends, 1);
      postMode = "ok";
      await assert.rejects(() => projectManage(r.hub, sA, { action: "propose", args: { name: "feishu-p", to: "C66666666/90.1" } }), /uncertain/i);
      assert.equal(totalSends, 1, "feishu missing message_id must not re-send");

      // Comma missing seq -> uncertain -> keeps sending=1, immediate retry does NOT re-send!
      postMode = "comma-no-seq";
      await assert.rejects(() => projectManage(r.hub, sA, { action: "propose", args: { name: "comma-p", to: "C66666666/90.1" } }), /missing seq/);
      assert.equal(totalSends, 2);
      postMode = "ok";
      await assert.rejects(() => projectManage(r.hub, sA, { action: "propose", args: { name: "comma-p", to: "C66666666/90.1" } }), /uncertain/i);
      assert.equal(totalSends, 2, "comma missing seq must not re-send");

      // Definite 429 rate_limited -> clears outbox -> immediate retry succeeds!
      postMode = "429";
      await assert.rejects(() => projectManage(r.hub, sA, { action: "propose", args: { name: "rate-p", to: "C66666666/90.1" } }), /429/);
      assert.equal(r.store.getPendingProposalOutbox(extT.id, sA, "rate-p"), null, "429 must clear outbox");
      postMode = "ok";
      const rateOk = JSON.parse(await projectManage(r.hub, sA, { action: "propose", args: { name: "rate-p", to: "C66666666/90.1" } }));
      assert.equal(rateOk.proposed, true);

      // Non-ownBot person sends markNotice(text) through acceptInTurn -> must NOT touch outbox!
      const pGuard = { id: "prop-guard", name: "guard-p", proposer: sA, status: "pending" as const };
      r.store.putPendingProposalOutbox(extT.id, sA, "guard-p", pGuard, r.store.lastEntry(extT.id), "slack-1");
      r.store.markPendingProposalSending(extT.id, sA, "guard-p");
      const guardText = renderProposalText(r.hub, extT, sA, pGuard);
      await (r.hub as any).acceptInTurn("slack-1", {
        channel: "C66666666",
        threadTs: "90.1",
        ts: "90.777",
        user: "U_RANDOM_PERSON",
        text: markNotice(guardText),
        addressed: false,
      });
      assert.equal(r.store.getPendingProposalOutbox(extT.id, sA, "guard-p")?.sending, true, "non-ownBot notice must not clear outbox");

      // Concurrent dual-agent identical degraded text with out-of-order ownBot echo (B's echo arrives while both A & B are sending=1):
      const gateA = Promise.withResolvers<string>();
      const gateB = Promise.withResolvers<string>();
      let callIdx = 0;
      const dualBot = {
        botUserId: () => "U_OWN_BOT",
        workspace: () => "T1",
        post: async () => (++callIdx === 1 ? gateA.promise : gateB.promise),
      };
      (r.hub as any).chat = () => dualBot;
      (r.hub as any).chatOf = (id: string) => (id === "slack-1" ? dualBot : undefined);

      const promA = projectManage(r.hub, sA, { action: "propose", args: { name: "shared-p", to: "C66666666/90.1" } });
      const promB = projectManage(r.hub, sB, { action: "propose", args: { name: "shared-p", to: "C66666666/90.1" } });
      // Wait a tick so both outboxes are marked sending=1
      await new Promise((res) => setTimeout(res, 10));
      const outA = r.store.getPendingProposalOutbox(extT.id, sA, "shared-p")!;
      const outB = r.store.getPendingProposalOutbox(extT.id, sB, "shared-p")!;
      assert.equal(outA.sending, true);
      assert.equal(outB.sending, true);
      const degradedTextB = renderProposalText(r.hub, extT, sB, outB.payload);
      assert.ok(degradedTextB.includes(`[#${outB.id}]`), "degraded text must carry proposal ID marker");

      // B's ownBot echo arrives BEFORE either post resolves -> uniquely reconciles B (never hijacks A)!
      await r.hub.receive("slack-1", {
        type: "ownNotice",
        message: {
          channel: "C66666666",
          threadTs: "90.1",
          ts: "90.902",
          user: "U_OWN_BOT",
          text: markNotice(degradedTextB),
          addressed: false,
        },
      });
      assert.equal(r.store.getPendingProposalOutbox(extT.id, sA, "shared-p")?.sending, true, "B's echo must not clear A's outbox");
      assert.equal(r.store.getPendingProposalOutbox(extT.id, sB, "shared-p"), null, "B's marker-identified echo must reconcile B's outbox");

      // Now B resolves with 90.902 and A resolves with 90.901 -> each gets its own exact proposal ID!
      gateB.resolve("90.902");
      gateA.resolve("90.901");
      const [resA, resB] = await Promise.all([promA, promB]);
      const parsedA = JSON.parse(resA);
      const parsedB = JSON.parse(resB);
      assert.equal(parsedA.id, outA.id, "Agent A must receive A's exact proposal ID");
      assert.equal(parsedB.id, outB.id, "Agent B must receive B's exact proposal ID");
      assert.equal(parsedA.ts, "90.901");
      assert.equal(parsedB.ts, "90.902");
    } finally {
      await r.close();
    }

    // 4a. Field-level timestamps: A clears note@20, B edits only refs@30 (still carrying old note@10) -> both 3-way & 2-way keep note cleared and B's new refs!
    const baseBuf = Buffer.from(`${JSON.stringify({ name: "fp", note: "old", noteAt: 10, refs: ["r0"], refsAt: 10, updatedAt: 10 })}\n`, "utf8");
    const aBuf = Buffer.from(`${JSON.stringify({ name: "fp", refs: ["r0"], refsAt: 10, updatedAt: 20, noteClearedAt: 20 })}\n`, "utf8");
    const bBuf = Buffer.from(`${JSON.stringify({ name: "fp", note: "old", noteAt: 10, refs: ["r0", "r-new"], refsAt: 30, updatedAt: 30 })}\n`, "utf8");
    const hBase = sha(baseBuf), hA = sha(aBuf), hB = sha(bBuf);
    const blobs = new Map([[hBase, baseBuf], [hA, aBuf], [hB, bBuf]]);
    // With common ancestor (`prev: [hBase]`):
    const recA3: Rec = { hash: hA, at: 20, by: "a".repeat(64), prev: [hBase], size: aBuf.length, mode: 0o644 };
    const recB3: Rec = { hash: hB, at: 30, by: "b".repeat(64), prev: [hBase], size: bBuf.length, mode: 0o644 };
    const m3 = decide("PROJECTS.jsonl", recA3, recB3, (h: string) => blobs.get(h) ?? null, (id: string) => id);
    assert.equal(m3.kind, "merge");
    const p3 = parseProjectsJsonlWithRaw(m3.content!.toString("utf8"), { strict: true });
    assert.equal(p3.doc.projects["fp"]?.note, undefined, "3-way merge must keep note cleared");
    assert.deepEqual(p3.doc.projects["fp"]?.refs, ["r-new", "r0"], "3-way merge must keep B's new refs");
    // Without common ancestor (`prev: []`):
    const recA2: Rec = { hash: hA, at: 20, by: "a".repeat(64), prev: [], size: aBuf.length, mode: 0o644 };
    const recB2: Rec = { hash: hB, at: 30, by: "b".repeat(64), prev: [], size: bBuf.length, mode: 0o644 };
    const m2 = decide("PROJECTS.jsonl", recA2, recB2, (h: string) => blobs.get(h) ?? null, (id: string) => id);
    assert.equal(m2.kind, "merge");
    const p2 = parseProjectsJsonlWithRaw(m2.content!.toString("utf8"), { strict: true });
    assert.equal(p2.doc.projects["fp"]?.note, undefined, "2-way merge must keep note cleared");
    assert.deepEqual(p2.doc.projects["fp"]?.refs, ["r-new", "r0"], "2-way merge must keep B's new refs");

    // 4b. Local-empty explicit clear via updateProjectInfo AND applyProposalInfoSync persists noteClearedAt so old note never resurrects!
    await updateProjectInfo(agentHome, "ws-1", null, { name: "empty-clr", refs: ["r1"], now: 100 });
    const clr1 = await updateProjectInfo(agentHome, "ws-1", null, { name: "empty-clr", note: null, now: 110 });
    assert.equal(clr1.changed, true, "explicit clear on locally empty note must persist noteClearedAt");
    const afterClr1 = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const olderWithNote = `${JSON.stringify({ name: "empty-clr", note: "stale-note", noteAt: 90, refs: ["r1"], refsAt: 90, updatedAt: 90 })}\n`;
    const mergedClr1 = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${afterClr1}${olderWithNote}`), { strict: true });
    assert.equal(mergedClr1.doc.projects["empty-clr"]?.note, undefined, "old note must not resurrect after local-empty PUT clear");

    await updateProjectInfo(agentHome, "ws-1", null, { name: "empty-res", refs: ["r1"], now: 100 });
    const clrRes = await applyProposalInfoSync(agentHome, "ws-1", null, { name: "empty-res", note: null, resolvedAt: 120, isReplay: false });
    assert.equal(clrRes.changed, true, "explicit clear on locally empty note via resolve must persist noteClearedAt");
    const afterClrRes = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const olderResNote = `${JSON.stringify({ name: "empty-res", note: "stale-res-note", noteAt: 95, updatedAt: 95 })}\n`;
    const mergedClrRes = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${afterClrRes}${olderResNote}`), { strict: true });
    assert.equal(mergedClrRes.doc.projects["empty-res"]?.note, undefined, "old note must not resurrect after local-empty resolve clear");

    // 4c. Slow-clock rename after clear@1010 & refill@1020 with local now=100 preserves new note on return, re-read, and merge!
    await updateProjectInfo(agentHome, "ws-1", null, { name: "slow-from", note: "v0", now: 1000 });
    await updateProjectInfo(agentHome, "ws-1", null, { name: "slow-from", note: null, now: 1010 });
    await updateProjectInfo(agentHome, "ws-1", null, { name: "slow-from", note: "refilled", now: 1020 });
    const oldSlowCopy = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const renRes = await renameProjectInfo(agentHome, "ws-1", null, "slow-from", "slow-to", 100);
    assert.equal(renRes.doc.projects["slow-to"]?.note, "refilled", "rename return doc must keep refilled note");
    const reRead = await readProjectsInfoStrict(agentHome, "ws-1", null);
    assert.equal(reRead.projects["slow-to"]?.note, "refilled", "re-reading disk after slow-clock rename must keep refilled note");
    const afterSlowDisk = await readFile(projectsInfoPath(agentHome, "ws-1", null), "utf8");
    const mergedSlow = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${afterSlowDisk}${oldSlowCopy}`), { strict: true });
    assert.equal(mergedSlow.doc.projects["slow-from"], undefined, "renamed source must stay deleted against old copy");
    assert.equal(mergedSlow.doc.projects["slow-to"]?.note, "refilled", "renamed target must keep refilled note after merge");

    // 4d. Real >512 KiB input with field-level clear watermarks: TS & MoonBit compact_projects_jsonl produce byte-identical hash!
    const pad = "z".repeat(450);
    const bigA: string[] = [];
    const bigB: string[] = [];
    for (let i = 0; i < 700; i++) {
      const nm = `big-${String(i).padStart(4, "0")}`;
      if (i % 2 === 0) {
        bigA.push(JSON.stringify({ name: nm, refs: [`ra-${i}`], refsAt: 100 + i, updatedAt: 200 + i, noteClearedAt: 200 + i }));
        bigB.push(JSON.stringify({ name: nm, note: `stale-${pad}`, noteAt: 100 + i, refs: [`rb-${i}`], refsAt: 250 + i, updatedAt: 250 + i }));
      } else {
        bigA.push(JSON.stringify({ name: nm, note: `A-${pad}`, noteAt: 100 + i, refs: [`ra-${i}`], refsAt: 100 + i, updatedAt: 100 + i }));
        bigB.push(JSON.stringify({ name: nm, note: `B-${pad}`, noteAt: 200 + i, refs: [`rb-${i}`], refsAt: 200 + i, updatedAt: 200 + i }));
      }
    }
    const bigBufA = Buffer.from(`${bigA.join("\n")}\n`, "utf8");
    const bigBufB = Buffer.from(`${bigB.join("\n")}\n`, "utf8");
    assert.ok(bigBufA.length + bigBufB.length > 512 * 1024, "combined input must exceed 512 KiB to trigger compaction");
    const hBigA = sha(bigBufA), hBigB = sha(bigBufB);
    const bigRecA: Rec = { hash: hBigA, at: 5000, by: "a".repeat(64), prev: [], size: bigBufA.length, mode: 0o644 };
    const bigRecB: Rec = { hash: hBigB, at: 5001, by: "b".repeat(64), prev: [], size: bigBufB.length, mode: 0o644 };
    const bigBlobs = new Map([[hBigA, bigBufA], [hBigB, bigBufB]]);
    const tsBig = decide("PROJECTS.jsonl", bigRecA, bigRecB, (h: string) => bigBlobs.get(h) ?? null, (id: string) => id);
    assert.equal(tsBig.kind, "merge");
    const parsedBig = parseProjectsJsonlWithRaw(tsBig.content!.toString("utf8"), { strict: true });
    assert.equal(parsedBig.doc.projects["big-0000"]?.note, undefined, "compacted >512KiB must keep cleared note suppressed");
    assert.deepEqual(parsedBig.doc.projects["big-0000"]?.refs, ["rb-0", "ra-0"], "compacted >512KiB must keep both refs with newer first");
    const mbBig = await memoryProgram().ask<any>("decide", {
      path: "PROJECTS.jsonl",
      mine: bigRecA,
      theirs: bigRecB,
      names: { [bigRecA.by]: "a", [bigRecB.by]: "b" },
      given: { [hBigA]: bigBufA.toString("hex"), [hBigB]: bigBufB.toString("hex") },
      blobs: join(dir, "blobs-r7-big"),
      prevMost: 16,
    });
    assert.equal(mbBig.rec.hash, tsBig.rec.hash, "MoonBit and TS >512KiB field-clear compaction must be byte-for-byte identical");

    // 4e. Real behavior test: handover of a thread with ONLY entry_proposals sidecar to an older station (projects: false) triggers log.warn!
    const { A, B, WS, stillfailChat, world } = await import("./move-world.ts");
    const { log } = await import("../src/ops/log.ts");
    const w = world();
    try {
      const a = w.get(A);
      const b = w.get(B);
      const { key, thread } = await stillfailChat(a);
      const [hoN] = a.rig.store.insertMessage({ thread, ts: "999.1", authorKind: "agent", author: key, text: "msg", attachments: [] });
      a.rig.store.attachEntryProposal(thread, hoN, { id: "prop-ho-only", name: "ho-only", status: "pending" });
      // Wrap b's handover. bus handler so handover.begin returns projects: false (simulating an older station).
      const origAnswers = b.moves.answers(() => true);
      b.bus.on("handover.", async (from: string, req: any, wsArg?: string) => {
        const res = await origAnswers(from, req, wsArg);
        if (req?.method === "handover.begin" && res && typeof res === "object") {
          return { ...res, projects: false };
        }
        return res;
      });
      const warns: string[] = [];
      const origWarn = log.warn.bind(log);
      (log as any).warn = (scope: string, msg: string, fields?: unknown) => {
        if (scope === "handover") warns.push(msg);
        return origWarn(scope, msg, fields as any);
      };
      try {
        await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
        await w.quiet();
      } finally {
        (log as any).warn = origWarn;
      }
      assert.ok(
        warns.some((m) => /does not support chat project\/tag classification or proposals yet/.test(m)),
        `expected handover degrade warn for entry_proposals-only thread, got: ${JSON.stringify(warns)}`,
      );
    } finally {
      for (const st of w.stations.values()) {
        await st.moves.handover.close();
        await st.rig.close();
      }
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R8 P1-1..P1-5: Comma in-flight disconnect, cross-connect dual-bot echo, dropImport restores open_proposals, field-level applyProposalInfoSync compensation, and 3-order associative refAts merge", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r8-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { Admin } = await import("../src/api/admin.ts");
    const { parseProjectsJsonlWithRaw, serializeProjectsJsonl } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1 & 2. Comma in-flight disconnect never retries + dual-connect dual-bot cross-connect echo
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r8" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "comma-1", kind: "comma", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slack-A", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slack-B", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [sC] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const commaT = r.store.openThread("comma:comma-1", "CM1", "10.1", null, "ada@example.com");
      r.store.joinThread(commaT.id, sC, "comma-1");

      let commaSends = 0;
      const commaBot = {
        botUserId: () => "U_COMMA",
        workspace: () => null,
        post: async () => {
          commaSends++;
          throw new Error("Comma is not connected");
        },
      };
      (r.hub as any).chat = (id: string) => {
        if (id === "comma-1") return commaBot;
        throw new Error(`unexpected connect ${id}`);
      };
      // P1-1: In-flight Comma disconnect -> outbox keeps sending=1, retry refuses without double-posting (total = 1)!
      await assert.rejects(() => projectManage(r.hub, sC, { action: "propose", args: { name: "comma-disc", to: "CM1/10.1" } }), /Comma is not connected/);
      assert.equal(commaSends, 1);
      assert.equal(r.store.getPendingProposalOutbox(commaT.id, sC, "comma-disc")?.sending, true);
      await assert.rejects(() => projectManage(r.hub, sC, { action: "propose", args: { name: "comma-disc", to: "CM1/10.1" } }), /uncertain/i);
      assert.equal(commaSends, 1, "in-flight Comma disconnect must never double-post on retry");

      // P1-2: Dual-connect dual-bot cross-connect echo in same Slack workspace & thread
      const [sA] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const [sB] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const slackT = r.store.openThread("slack:T1", "C55555555", "20.1", null, "ada@example.com");
      r.store.joinThread(slackT.id, sA, "slack-A");
      r.store.joinThread(slackT.id, sB, "slack-B");

      const gateA = Promise.withResolvers<string>();
      const gateB = Promise.withResolvers<string>();
      const botA = { botUserId: () => "U_BOT_A", workspace: () => "T1", post: async () => gateA.promise };
      const botB = { botUserId: () => "U_BOT_B", workspace: () => "T1", post: async () => gateB.promise };
      (r.hub as any).chat = (id: string) => (id === "slack-A" ? botA : botB);
      (r.hub as any).chatOf = (id: string) => (id === "slack-A" ? botA : id === "slack-B" ? botB : undefined);

      const pA = projectManage(r.hub, sA, { action: "propose", args: { name: "cross-p", to: "C55555555/20.1" } });
      const pB = projectManage(r.hub, sB, { action: "propose", args: { name: "cross-p", to: "C55555555/20.1" } });
      await new Promise((res) => setTimeout(res, 10));
      const outA = r.store.getPendingProposalOutbox(slackT.id, sA, "cross-p")!;
      const outB = r.store.getPendingProposalOutbox(slackT.id, sB, "cross-p")!;
      const textA = renderProposalText(r.hub, slackT, sA, outA.payload);

      // Deliver Bot A's echo THROUGH connect `slack-B` -> must reconcile A's outbox (NOT B's)!
      await (r.hub as any).acceptInTurn("slack-B", {
        channel: "C55555555",
        threadTs: "20.1",
        ts: "20.101",
        user: "U_BOT_A",
        text: markNotice(textA),
        addressed: false,
      });
      assert.equal(r.store.getPendingProposalOutbox(slackT.id, sA, "cross-p"), null, "cross-connect echo from U_BOT_A must reconcile slack-A's outbox");
      assert.equal(r.store.getPendingProposalOutbox(slackT.id, sB, "cross-p")?.sending, true, "slack-B's outbox must remain untouched");

      gateA.resolve("20.101");
      gateB.resolve("20.102");
      const [resA, resB] = await Promise.all([pA, pB]);
      const objA = JSON.parse(resA);
      const objB = JSON.parse(resB);
      assert.equal(objA.id, outA.id);
      assert.equal(objA.ts, "20.101");
      assert.equal(objB.id, outB.id);
      assert.equal(objB.ts, "20.102");
      assert.equal(r.store.getEntry(slackT.id, objA.n)?.proposal?.proposer, sA);
      assert.equal(r.store.getEntry(slackT.id, objB.n)?.proposal?.proposer, sB);
    } finally {
      await r.close();
    }

    // 3. Handover dropImport deletes imported proposal_outcomes -> restores open_proposals so findPendingProposal hits & retry sends 0!
    const schemaTs = await readFile(join(process.cwd(), "src/store/schema.ts"), "utf8");
    const schemaMbt = await readFile(join(process.cwd(), "mb/src/store_schema/schema.mbt"), "utf8");
    assert.ok(schemaTs.includes("open_proposals_outcomes_ad") && schemaTs.includes("open_proposals_sidecar_ad"));
    assert.ok(schemaMbt.includes("open_proposals_outcomes_ad") && schemaMbt.includes("open_proposals_sidecar_ad"));

    const srcS = Store.open(join(dir, "r8-src.db"));
    const dstS = Store.open(join(dir, "r8-dst.db"));
    try {
      const srcT = srcS.openThread("slack:T1", "C30", "30.1", null, "ada@example.com");
      const dstT = dstS.openThread("slack:T1", "C30", "30.1", null, "ada@example.com");
      const [srcN] = srcS.insertMessage({
        thread: srcT.id, ts: "30.2", authorKind: "agent", author: "chat:s1", text: "p", attachments: [],
        proposal: { id: "prop-ho-rb", name: "rb-p", proposer: "chat:s1", status: "pending" },
      });
      const [dstN] = dstS.insertMessage({
        thread: dstT.id, ts: "30.2", authorKind: "agent", author: "chat:s1", text: "p", attachments: [],
        proposal: { id: "prop-ho-rb", name: "rb-p", proposer: "chat:s1", status: "pending" },
      });
      srcS.resolveProposal(srcT.id, srcN, { action: "accept", resolvedBy: "ada@example.com" });
      assert.equal(dstS.findPendingProposal(dstT.id, "chat:s1", "rb-p")?.n, dstN);

      const ctx = handover.newCtx({ from: "st-s", here: "st-d", fromData: dir, toData: dir, connects: {}, profiles: {}, ws: "ws-1" });
      const mkT = () => ({ threads: new Set<number>(), sessions: new Set<string>() });
      handover.importRows((dstS as any).db, ctx, "threads", handover.chatPage((srcS as any).db, "threads", srcT.id, null), mkT());
      handover.importRows((dstS as any).db, ctx, "entries", handover.chatPage((srcS as any).db, "entries", srcT.id, null), mkT());
      handover.importRows((dstS as any).db, ctx, "proposal_outcomes", handover.chatPage((srcS as any).db, "proposal_outcomes", srcT.id, null), mkT());
      assert.equal(dstS.findPendingProposal(dstT.id, "chat:s1", "rb-p"), null, "imported outcome removes open_proposals entry");

      // Cancel handover via dropImport -> outcome deleted -> open_proposals_outcomes_ad restores open_proposals!
      handover.dropImport((dstS as any).db, ctx);
      assert.equal(((dstS as any).db.prepare("SELECT COUNT(*) AS c FROM proposal_outcomes WHERE thread = ?").get(dstT.id) as any).c, 0);
      assert.equal(dstS.getEntry(dstT.id, dstN)?.proposal?.status, "pending");
      assert.equal(dstS.findPendingProposal(dstT.id, "chat:s1", "rb-p")?.n, dstN, "dropImport must restore open_proposals so retries do not double-post");
    } finally {
      srcS.close();
      dstS.close();
    }

    // 4. Field-independent applyProposalInfoSync compensation (intervening refs edit at 150 + replay advancing old noteClearedAt=10 -> 101)
    let storeClock = 101;
    const compStore = Store.open(join(dir, "r8-comp.db"));
    (compStore as any).now = () => storeClock;
    try {
      // 4a. Intervening refs edit at 150 between failed clear@101 and Idempotency-Key retry
      await updateProjectInfo(agentHome, "ws-1", null, { name: "comp-p", note: "old-note", refs: ["r0"], now: 50 });
      const t1 = compStore.openThread("stillfail", "CHAT", "40.1", null, "ada@example.com");
      const [p1] = compStore.insertMessage({
        thread: t1.id, ts: "40.1", authorKind: "agent", author: "chat:c1", text: "p", attachments: [],
        proposal: { id: "prop-comp-1", name: "comp-p", note: "prop-note", status: "pending" },
      });
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store: compStore,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      const saved = await readFile(wsFile, "utf8");
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq1 = () => ({
        method: "POST",
        path: `/threads/${t1.id}/proposals/${p1}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r8-1" },
        body: Buffer.from(JSON.stringify({ action: "accept", note: "" })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      const a1 = await admin.handle(mkReq1());
      assert.equal(a1.status, 200);
      assert.ok(JSON.parse((a1.body as Buffer).toString("utf8")).infoError);

      // Restore file & apply an unrelated refs edit at t=150 BEFORE retrying the Idempotency-Key!
      await writeFile(wsFile, saved, "utf8");
      await updateProjectInfo(agentHome, "ws-1", null, { name: "comp-p", refs: ["r0", "r150"], now: 150 });

      // Retry with same Idempotency-Key -> MUST clear old note@50 AND preserve new refs@150!
      const a2 = await admin.handle(mkReq1());
      assert.equal(a2.status, 200);
      assert.equal(JSON.parse((a2.body as Buffer).toString("utf8")).infoError, undefined);
      const afterComp = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.equal(afterComp.projects["comp-p"]?.note, undefined, "retry after intervening refs@150 must still clear note@50");
      assert.deepEqual(afterComp.projects["comp-p"]?.refs, ["r150", "r0"], "intervening refs@150 must be preserved");
      assert.equal(((compStore as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t1.id, p1) as any).info_synced, 1);

      // 4b. Locally empty note with old noteClearedAt=10 -> failed clear@101 retried advances noteClearedAt to 101 so note@50 never resurrects!
      await updateProjectInfo(agentHome, "ws-1", null, { name: "replay-clr", note: "init", now: 5 });
      await updateProjectInfo(agentHome, "ws-1", null, { name: "replay-clr", note: null, now: 10 });
      const t2 = compStore.openThread("stillfail", "CHAT", "41.1", null, "ada@example.com");
      const [p2] = compStore.insertMessage({
        thread: t2.id, ts: "41.1", authorKind: "agent", author: "chat:c2", text: "p", attachments: [],
        proposal: { id: "prop-comp-2", name: "replay-clr", status: "pending" },
      });
      const saved2 = await readFile(wsFile, "utf8");
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq2 = () => ({
        method: "POST",
        path: `/threads/${t2.id}/proposals/${p2}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r8-2" },
        body: Buffer.from(JSON.stringify({ action: "accept", note: null })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReq2())).body as Buffer).toString("utf8")).infoError);
      await writeFile(wsFile, saved2, "utf8");
      assert.equal(JSON.parse(((await admin.handle(mkReq2())).body as Buffer).toString("utf8")).infoError, undefined);
      const afterReplay = await readFile(wsFile, "utf8");
      const staleNote50 = `${JSON.stringify({ name: "replay-clr", note: "stale@50", noteAt: 50, updatedAt: 50 })}\n`;
      const mergedReplay = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${afterReplay}${staleNote50}`), { strict: true });
      assert.equal(mergedReplay.doc.projects["replay-clr"]?.note, undefined, "replayed clear@101 must advance noteClearedAt past 50");
      assert.ok((mergedReplay.doc.projects["replay-clr"]?.noteClearedAt ?? 0) >= 101);
    } finally {
      compStore.close();
    }

    // 5. 3-order associative refAts merge (old@10, clear@20, new@30) including real >512 KiB TS & MoonBit compaction!
    const lineOld = JSON.stringify({ name: "assoc", refs: ["old"], refsAt: 10, refAts: { old: 10 }, updatedAt: 10 });
    const lineClear = JSON.stringify({ name: "assoc", updatedAt: 20, refsClearedAt: 20 });
    const lineNew = JSON.stringify({ name: "assoc", refs: ["new"], refsAt: 30, refAts: { new: 30 }, updatedAt: 30 });

    // Order A: all 3 lines at once
    const orderA = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${lineOld}\n${lineClear}\n${lineNew}\n`), { strict: true });
    assert.deepEqual(orderA.doc.projects["assoc"]?.refs, ["new"]);

    // Order B: merge old@10 + new@30, serialize, then merge with clear@20
    const stepB1 = parseProjectsJsonlWithRaw(`${lineOld}\n${lineNew}\n`, { strict: true });
    const serB1 = serializeProjectsJsonl(stepB1.doc, stepB1.preservedRawLines, stepB1.tombstones);
    const orderB = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${serB1}${lineClear}\n`), { strict: true });
    assert.deepEqual(orderB.doc.projects["assoc"]?.refs, ["new"], "Order B must drop old@10 even after intermediate merge with new@30");

    // Order C: real >512 KiB compaction (TS & MoonBit) of old@10 + new@30, then merge with clear@20!
    const pad = "q".repeat(480);
    const linesC1: string[] = [lineOld];
    const linesC2: string[] = [lineNew];
    for (let i = 0; i < 600; i++) {
      const nm = `pad-${String(i).padStart(4, "0")}`;
      linesC1.push(JSON.stringify({ name: nm, note: `A-${pad}`, noteAt: 10, refs: [`ra-${i}`], refsAt: 10, refAts: { [`ra-${i}`]: 10 }, updatedAt: 10 }));
      linesC2.push(JSON.stringify({ name: nm, note: `B-${pad}`, noteAt: 30, refs: [`rb-${i}`], refsAt: 30, refAts: { [`rb-${i}`]: 30 }, updatedAt: 30 }));
    }
    const bufC1 = Buffer.from(`${linesC1.join("\n")}\n`, "utf8");
    const bufC2 = Buffer.from(`${linesC2.join("\n")}\n`, "utf8");
    assert.ok(bufC1.length + bufC2.length > 512 * 1024, "Order C inputs must exceed 512 KiB to trigger compaction");
    const hC1 = sha(bufC1), hC2 = sha(bufC2);
    const recC1: Rec = { hash: hC1, at: 100, by: "a".repeat(64), prev: [], size: bufC1.length, mode: 0o644 };
    const recC2: Rec = { hash: hC2, at: 101, by: "b".repeat(64), prev: [], size: bufC2.length, mode: 0o644 };
    const blobsC = new Map([[hC1, bufC1], [hC2, bufC2]]);
    const tsC = decide("PROJECTS.jsonl", recC1, recC2, (h: string) => blobsC.get(h) ?? null, (id: string) => id);
    assert.equal(tsC.kind, "merge");
    const mbC = await memoryProgram().ask<any>("decide", {
      path: "PROJECTS.jsonl",
      mine: recC1,
      theirs: recC2,
      names: { [recC1.by]: "a", [recC2.by]: "b" },
      given: { [hC1]: bufC1.toString("hex"), [hC2]: bufC2.toString("hex") },
      blobs: join(dir, "blobs-r8-assoc"),
      prevMost: 16,
    });
    assert.equal(mbC.rec.hash, tsC.rec.hash, "TS and MoonBit >512KiB refAts compaction must be byte-for-byte identical");
    // Now merge the compacted >512 KiB output with clear@20!
    const orderC = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${tsC.content!.toString("utf8")}${lineClear}\n`), { strict: true });
    assert.deepEqual(orderC.doc.projects["assoc"]?.refs, ["new"], "Order C (>512KiB compacted) must still drop old@10 and keep only new@30");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R10 P1-1..P1-4: real CommaSurface pre-send vs in-flight closed, real Slack toEvent own-notice & history fallback, applyProposalInfoSync per-ref clear filter, and deletedAt field-level filter across all 4 engines", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r10-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { CommaSurface } = await import("../src/comma/surface.ts");
    const { toEvent } = await import("../src/slack/surface.ts");
    const { Admin } = await import("../src/api/admin.ts");
    const { parseProjectsJsonlWithRaw, serializeProjectsJsonl } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");

    // 1. Real CommaSurface: pre-send no-socket (`notSent: true`) clears outbox & retries cleanly; in-flight `closed()` keeps `sending=1` & never retries!
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r10" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "comma-r10", kind: "comma", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slack-r10", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [sC] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const commaT = r.store.openThread("comma:comma-r10", "CM1", "10.1", null, "ada@example.com");
      r.store.joinThread(commaT.id, sC, "comma-r10");

      const surface = new CommaSurface({
        connect: "comma-r10",
        server: "http://127.0.0.1:1",
        token: "tok",
        name: "st-r10",
        tasks: { byThread: () => ({ task: "t1", threadTs: "10.1" }) },
        store: r.store,
        models: () => ({}),
        lang: "en",
      } as any);
      (r.hub as any).chat = (id: string) => (id === "comma-r10" ? surface : undefined);

      // 1a. Pre-send socket_ === null -> 0 frames sent, outbox cleared, reconnect sends 1 frame & persists!
      let sentFrames: any[] = [];
      await assert.rejects(() => projectManage(r.hub, sC, { action: "propose", args: { name: "comma-pre", to: "CM1/10.1" } }));
      assert.equal(sentFrames.length, 0);
      assert.equal(r.store.getPendingProposalOutbox(commaT.id, sC, "comma-pre"), null, "pre-send no-socket must clear outbox");

      // Attach fake live socket that answers with seq=101
      let dropOnSend = false;
      (surface as any).socket_ = {
        send: (raw: string) => {
          const f = JSON.parse(raw);
          sentFrames.push(f);
          if (dropOnSend) {
            queueMicrotask(() => (surface as any).closed());
          } else {
            queueMicrotask(() => {
              const w = (surface as any).waiting.get(f.id);
              if (w) {
                (surface as any).waiting.delete(f.id);
                w.resolve({ seq: 101 });
              }
            });
          }
        },
      };
      const okPre = JSON.parse(await projectManage(r.hub, sC, { action: "propose", args: { name: "comma-pre", to: "CM1/10.1" } }));
      assert.equal(okPre.proposed, true);
      assert.equal(sentFrames.length, 1, "retry after socket restored must send exactly 1 frame");

      // 1b. In-flight waiting rejected by closed() -> 1 frame sent, outbox stays sending=1, reconnect + retry still sends 0 more frames!
      sentFrames = [];
      dropOnSend = true;
      await assert.rejects(() => projectManage(r.hub, sC, { action: "propose", args: { name: "comma-mid", to: "CM1/10.1" } }), /Comma is not connected/);
      assert.equal(sentFrames.length, 1);
      assert.equal(r.store.getPendingProposalOutbox(commaT.id, sC, "comma-mid")?.sending, true, "in-flight closed() must keep sending=1");
      dropOnSend = false;
      (surface as any).socket_ = {
        send: (raw: string) => {
          sentFrames.push(JSON.parse(raw));
        },
      };
      await assert.rejects(() => projectManage(r.hub, sC, { action: "propose", args: { name: "comma-mid", to: "CM1/10.1" } }), /uncertain/i);
      assert.equal(sentFrames.length, 1, "retry after in-flight closed() must NOT send a second frame");

      // 2. Real Slack toEvent own-notice pass-through + single-connect echo reconciliation + chat.history fallback
      // 2a. Plain own-bot message still returns null from toEvent
      assert.equal(toEvent({ type: "message", channel: "C99", thread_ts: "50.1", ts: "50.2", user: "U_SLK_BOT", text: "plain bot msg" }, "U_SLK_BOT", "B_SLK"), null);
      // 2b. Single Slack connect loses chat.post receipt -> own-bot notice event via toEvent -> acceptInTurn reconciles without waking agent!
      const [sS] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const slackT = r.store.openThread("slack:T1", "C99", "50.1", null, "ada@example.com");
      r.store.joinThread(slackT.id, sS, "slack-r10");

      let slackSends = 0;
      const historyLog: { ts: string; user: string; text: string; fromBot: boolean }[] = [];
      const slackFake = {
        botUserId: () => "U_SLK_BOT",
        workspace: () => "T1",
        post: async (_here: any, text: string) => {
          slackSends++;
          const ts = `50.${10 + slackSends}`;
          historyLog.push({ ts, user: "U_SLK_BOT", text, fromBot: true });
          throw new Error("socket hang up after platform accepted");
        },
        history: async () => historyLog,
      };
      (r.hub as any).chat = (id: string) => (id === "slack-r10" ? slackFake : surface);
      (r.hub as any).chatOf = (id: string) => (id === "slack-r10" ? slackFake : undefined);

      const deliveriesBefore = ((r.store as any).db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ?").get(slackT.id) as any).c;
      await assert.rejects(() => projectManage(r.hub, sS, { action: "propose", args: { name: "slk-echo", to: "C99/50.1" } }), /socket hang up/);
      assert.equal(slackSends, 1);
      const outSlk = r.store.getPendingProposalOutbox(slackT.id, sS, "slk-echo")!;
      assert.equal(outSlk.sending, true);

      // Feed the real raw Slack event (with bot_id only, testing user normalization to botUserId) through toEvent -> hub.receive!
      const rawEcho = historyLog[0]!;
      const ev = toEvent({ type: "message", subtype: "bot_message", channel: "C99", thread_ts: "50.1", ts: rawEcho.ts, bot_id: "B_SLK", text: rawEcho.text }, "U_SLK_BOT", "B_SLK");
      assert.ok(ev !== null && ev.type === "ownNotice" && ev.message.user === "U_SLK_BOT" && ev.message.addressed === false);
      await r.hub.receive("slack-r10", ev);

      assert.equal(r.store.getPendingProposalOutbox(slackT.id, sS, "slk-echo"), null, "toEvent -> acceptInTurn must clear outbox");
      const foundSlk = r.store.findPendingProposal(slackT.id, sS, "slk-echo");
      assert.equal(foundSlk?.proposal.id, outSlk.id, "local SQLite must hold 1 resolvable proposal");
      const deliveriesAfter = ((r.store as any).db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ?").get(slackT.id) as any).c;
      assert.equal(deliveriesAfter, deliveriesBefore, "own-bot notice echo must NEVER wake agent");
      assert.equal(slackSends, 1);

      // 2c. Both chat.post receipt AND Socket Mode event lost -> retry reconciles via chat.history without double-posting!
      await assert.rejects(() => projectManage(r.hub, sS, { action: "propose", args: { name: "slk-hist", to: "C99/50.1" } }), /socket hang up/);
      assert.equal(slackSends, 2);
      const outHist = r.store.getPendingProposalOutbox(slackT.id, sS, "slk-hist")!;
      assert.equal(outHist.sending, true);
      const recHist = JSON.parse(await projectManage(r.hub, sS, { action: "propose", args: { name: "slk-hist", to: "C99/50.1" } }));
      assert.equal(slackSends, 2, "chat.history fallback must recover ts with 0 extra posts");
      assert.equal(recHist.id, outHist.id);
      assert.equal(recHist.ts, historyLog[1]!.ts);
      assert.equal(r.store.getPendingProposalOutbox(slackT.id, sS, "slk-hist"), null);
    } finally {
      await r.close();
    }

    // 3. applyProposalInfoSync per-ref clear watermark filter: old@80, clear refs=[] at 101 fails disk,
    //    another member keeps old & adds new@150, retry same Idempotency-Key drops old@80 and keeps new@150!
    let storeClock = 101;
    const compStore = Store.open(join(dir, "r10-comp.db"));
    (compStore as any).now = () => storeClock;
    try {
      await updateProjectInfo(agentHome, "ws-1", null, { name: "ref-clr", refs: ["old"], now: 80 });
      const t = compStore.openThread("stillfail", "CHAT", "60.1", null, "ada@example.com");
      const [pN] = compStore.insertMessage({
        thread: t.id, ts: "60.1", authorKind: "agent", author: "chat:r10", text: "p", attachments: [],
        proposal: { id: "prop-ref-clr", name: "ref-clr", refs: ["old"], status: "pending" },
      });
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store: compStore,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      const saved = await readFile(wsFile, "utf8");
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq = () => ({
        method: "POST",
        path: `/threads/${t.id}/proposals/${pN}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r10-refs" },
        body: Buffer.from(JSON.stringify({ action: "accept", refs: [] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReq())).body as Buffer).toString("utf8")).infoError);

      // Restore file & another member keeps "old" and adds "new" at t=150!
      await writeFile(wsFile, saved, "utf8");
      await updateProjectInfo(agentHome, "ws-1", null, { name: "ref-clr", refs: ["old", "new"], now: 150 });

      // Retry with same Idempotency-Key -> drops old@80, keeps new@150, sets refsClearedAt=101, info_synced=1!
      const res2 = await admin.handle(mkReq());
      assert.equal(res2.status, 200);
      assert.equal(JSON.parse((res2.body as Buffer).toString("utf8")).infoError, undefined);
      const row = (compStore as any).db.prepare("SELECT info_refs, info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t.id, pN) as any;
      assert.equal(row.info_refs, "[]");
      assert.equal(row.info_synced, 1);
      const afterDisk = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.deepEqual(afterDisk.projects["ref-clr"]?.refs, ["new"], "per-ref clear@101 must drop old@80 while preserving new@150");
      assert.equal(afterDisk.projects["ref-clr"]?.refsClearedAt, 101);
      const diskText = await readFile(wsFile, "utf8");
      const staleOld80 = `${JSON.stringify({ name: "ref-clr", refs: ["old"], refsAt: 80, refAts: { old: 80 }, updatedAt: 80 })}\n`;
      const mergedStale = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${diskText}${staleOld80}`), { strict: true });
      assert.deepEqual(mergedStale.doc.projects["ref-clr"]?.refs, ["new"], "merging old@80 copy must still keep only new@150");
    } finally {
      compStore.close();
    }

    // 4. Project-level deletedAt watermark filters field-level noteAt & per-ref refAts across all 4 engines!
    const oldLive = JSON.stringify({ name: "del-filt", note: "old-note", noteAt: 10, refs: ["old"], refsAt: 10, refAts: { old: 10 }, updatedAt: 10 });
    const delRow = JSON.stringify({ name: "del-filt", deleted: true, updatedAt: 20 });
    const newLive = JSON.stringify({ name: "del-filt", refs: ["new"], refsAt: 30, refAts: { new: 30 }, updatedAt: 30 });

    // Path A: merge all 3 at once
    const pathA = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${oldLive}\n${delRow}\n${newLive}\n`), { strict: true });
    assert.equal(pathA.doc.projects["del-filt"]?.note, undefined);
    assert.deepEqual(pathA.doc.projects["del-filt"]?.refs, ["new"]);

    // Path B: merge the 2 live rows first, serialize, then merge with deleted@20
    const liveTwo = parseProjectsJsonlWithRaw(`${oldLive}\n${newLive}\n`, { strict: true });
    const serLiveTwo = serializeProjectsJsonl(liveTwo.doc, liveTwo.preservedRawLines, liveTwo.tombstones);
    const pathB = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${serLiveTwo}${delRow}\n`), { strict: true });
    assert.equal(pathB.doc.projects["del-filt"]?.note, undefined, "Path B must drop old-note@10 via deletedAt=20");
    assert.deepEqual(pathB.doc.projects["del-filt"]?.refs, ["new"], "Path B must drop old@10 via deletedAt=20");

    // Path C: >512 KiB real TS & MoonBit decide compaction of the 2 live rows (byte-identical hash), then merge with deleted@20
    const pad = "w".repeat(480);
    const big1: string[] = [oldLive];
    const big2: string[] = [newLive];
    for (let i = 0; i < 600; i++) {
      const nm = `dpad-${String(i).padStart(4, "0")}`;
      big1.push(JSON.stringify({ name: nm, note: `A-${pad}`, noteAt: 10, refs: [`ra-${i}`], refsAt: 10, refAts: { [`ra-${i}`]: 10 }, updatedAt: 10 }));
      big2.push(JSON.stringify({ name: nm, note: `B-${pad}`, noteAt: 30, refs: [`rb-${i}`], refsAt: 30, refAts: { [`rb-${i}`]: 30 }, updatedAt: 30 }));
    }
    const b1 = Buffer.from(`${big1.join("\n")}\n`, "utf8");
    const b2 = Buffer.from(`${big2.join("\n")}\n`, "utf8");
    assert.ok(b1.length + b2.length > 512 * 1024);
    const hb1 = sha(b1), hb2 = sha(b2);
    const rb1: Rec = { hash: hb1, at: 100, by: "a".repeat(64), prev: [], size: b1.length, mode: 0o644 };
    const rb2: Rec = { hash: hb2, at: 101, by: "b".repeat(64), prev: [], size: b2.length, mode: 0o644 };
    const bMap = new Map([[hb1, b1], [hb2, b2]]);
    const tsBigDel = decide("PROJECTS.jsonl", rb1, rb2, (h: string) => bMap.get(h) ?? null, (id: string) => id);
    assert.equal(tsBigDel.kind, "merge");
    const mbBigDel = await memoryProgram().ask<any>("decide", {
      path: "PROJECTS.jsonl",
      mine: rb1,
      theirs: rb2,
      names: { [rb1.by]: "a", [rb2.by]: "b" },
      given: { [hb1]: b1.toString("hex"), [hb2]: b2.toString("hex") },
      blobs: join(dir, "blobs-r10-del"),
      prevMost: 16,
    });
    assert.equal(mbBigDel.rec.hash, tsBigDel.rec.hash, "TS and MoonBit >512KiB compaction must be byte-for-byte identical");
    const pathC = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${tsBigDel.content!.toString("utf8")}${delRow}\n`), { strict: true });
    assert.equal(pathC.doc.projects["del-filt"]?.note, undefined, "Path C must drop old-note@10 via deletedAt=20");
    assert.deepEqual(pathC.doc.projects["del-filt"]?.refs, ["new"], "Path C must drop old@10 via deletedAt=20");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R11 final polish: Slack ownNotice isolation (sayStands chat.update), baseN guard & proposal.id marker, real SlackSurface.history bot_id + >20 pagination + post-await local re-check, and applyProposalInfoSync non-empty refs per-item merge", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r11-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { SlackSurface, toEvent } = await import("../src/slack/surface.ts");
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { Admin } = await import("../src/api/admin.ts");
    const { parseProjectsJsonlWithRaw } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1. Real SlackSurface: ownNotice does NOT trigger heard() / overwrite ends.mine, so sayStands uses chat.update (not chat.postMessage)!
    const apiCalls: { method: string; params: [string, string][] }[] = [];
    const mockClient = {
      api: async (method: string, params: [string, string][]) => {
        apiCalls.push({ method, params });
        if (method === "chat.postMessage") return { ok: true, ts: "1700000100.000100" };
        if (method === "chat.update") return { ok: true, ts: "1700000100.000100" };
        return { ok: true };
      },
    };
    const slk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: mockClient as any, connect: "slk-1" });
    (slk as any).me = { team: "T1", teamId: "T1", url: "https://t1.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
    // Bot posts a regular reply (sets ends.mine = { ts: "1700000100.000100", ... })
    const postTs = await slk.post({ channel: "C100", threadTs: "1700000000.000100" }, "Here is my answer", []);
    assert.equal(postTs, "1700000100.000100");
    // Now its own station notice echo arrives via toEvent -> MUST be type: "ownNotice" (NOT "message"), so SlackSurface's `if (event?.type === "message") this.heard(...)` is skipped!
    const ownEv = toEvent(
      { type: "message", subtype: "bot_message", channel: "C100", thread_ts: "1700000000.000100", ts: "1700000101.000100", bot_id: "B_MY_BOT", text: markNotice("Notice [#prop-1]") },
      "U_MY_BOT",
      "B_MY_BOT",
    );
    assert.equal(ownEv?.type, "ownNotice");
    // End of turn: sayStands must call chat.update on the original bot message (NOT a new chat.postMessage)!
    apiCalls.length = 0;
    await (slk as any).sayStands({ channel: "C100", threadTs: "1700000000.000100" }, "C100/1700000000.000100", { kind: "done", words: "All done" });
    assert.ok(apiCalls.some((c) => c.method === "chat.update"), "sayStands must use chat.update when ownNotice did not clobber ends.mine");
    assert.equal(apiCalls.some((c) => c.method === "chat.postMessage"), false, "sayStands must NOT post a separate chat.postMessage");

    // 2 & 3. baseN guard + real SlackSurface.history (bot_id-only row, >20 replies pagination, post-await local re-check)
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r11" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [{ id: "slk-r11", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });
      const extT = r.store.openThread("slack:T1", "C200", "1700000000.000100", null, "ada@example.com");
      r.store.joinThread(extT.id, s, "slk-r11");

      // Insert 4 pre-existing entries (n = 1..4) including an old notice at n = 4 (baseN = 4).
      for (let i = 1; i <= 3; i++) {
        r.store.insertMessage({ thread: extT.id, ts: `170000000${i}.000100`, authorKind: "person", author: "U_USER", text: `msg ${i}`, attachments: [] });
      }
      const [oldNoticeN] = r.store.insertMessage({
        thread: extT.id, ts: "1700000004.000100", authorKind: "agent", author: "U_MY_BOT",
        text: markNotice('Proposed creating project "stale-p" and assigning this conversation to it.'), attachments: [],
      });
      assert.equal(oldNoticeN, 4);

      // Prepare real SlackSurface with mocked conversations.replies client!
      let repliesPages: any[][] = [];
      let historyHook: (() => Promise<void>) | null = null;
      const slkClient = {
        api: async (method: string, params: [string, string][]) => {
          if (method === "conversations.replies") {
            if (historyHook) await historyHook();
            const cur = params.find(([k]) => k === "cursor")?.[1] ?? "0";
            const idx = Number(cur);
            const msgs = repliesPages[idx] ?? [];
            const next = idx + 1 < repliesPages.length ? String(idx + 1) : "";
            return { ok: true, messages: msgs, response_metadata: { next_cursor: next } };
          }
          if (method === "chat.postMessage") {
            throw new Error("ETIMEDOUT before response");
          }
          return { ok: true };
        },
      };
      const realSlk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: slkClient as any, connect: "slk-r11" });
      (realSlk as any).me = { team: "T1", teamId: "T1", url: "https://t1.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
      (r.hub as any).chat = () => realSlk;
      (r.hub as any).chatOf = (id: string) => (id === "slk-r11" ? realSlk : undefined);

      // 2. Pre-existing notice at n=baseN=4 -> propose times out before reaching platform -> history returns only old notice -> retry refuses & never attaches to n=4!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "stale-p", to: "C200/1700000000.000100" } }), /ETIMEDOUT/);
      const outStale = r.store.getPendingProposalOutbox(extT.id, s, "stale-p")!;
      assert.equal(outStale.baseN, 4);
      repliesPages = [[
        { ts: "1700000004.000100", bot_id: "B_MY_BOT", text: markNotice('Proposed creating project "stale-p" and assigning this conversation to it.') },
      ]];
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "stale-p", to: "C200/1700000000.000100" } }), /uncertain/i);
      assert.equal(r.store.getEntry(extT.id, 4)?.proposal, undefined, "must NEVER attach new proposal onto pre-existing n=4");
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "stale-p")?.sending, true);

      // 3a. Real SlackSurface.history: row has ONLY `bot_id` (no `user`) -> normalized to U_MY_BOT -> recovers proposal!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "botid-p", to: "C200/1700000000.000100" } }), /ETIMEDOUT/);
      const outBotId = r.store.getPendingProposalOutbox(extT.id, s, "botid-p")!;
      const botIdText = renderProposalText(r.hub, extT, s, outBotId.payload);
      repliesPages = [[
        { ts: "1700000050.000100", bot_id: "B_MY_BOT", text: markNotice(botIdText) },
      ]];
      const recBotId = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "botid-p", to: "C200/1700000000.000100" } }));
      assert.equal(recBotId.id, outBotId.id);
      assert.equal(recBotId.ts, "1700000050.000100");
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "botid-p"), null);

      // 3b. Real SlackSurface.history: 25 ordinary replies landed AFTER the proposal -> recovers proposal across >20 messages!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "busy-p", to: "C200/1700000000.000100" } }), /ETIMEDOUT/);
      const outBusy = r.store.getPendingProposalOutbox(extT.id, s, "busy-p")!;
      const busyText = renderProposalText(r.hub, extT, s, outBusy.payload);
      const manyReplies: any[] = [
        { ts: "1700000060.000100", bot_id: "B_MY_BOT", text: markNotice(busyText) },
      ];
      for (let i = 1; i <= 25; i++) {
        manyReplies.push({ ts: `1700000${String(60 + i).padStart(3, "0")}.000100`, user: "U_USER", text: `reply ${i}` });
      }
      repliesPages = [manyReplies];
      const recBusy = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "busy-p", to: "C200/1700000000.000100" } }));
      assert.equal(recBusy.id, outBusy.id);
      assert.equal(recBusy.ts, "1700000060.000100");
      assert.equal(r.store.getPendingProposalOutbox(extT.id, s, "busy-p"), null);

      // 3c. While `await chat.history(...)` is suspended (and returns empty), inbound ownNotice echo finishes landing -> retry returns landed proposal instead of "uncertain"!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "race-p", to: "C200/1700000000.000100" } }), /ETIMEDOUT/);
      const outRace = r.store.getPendingProposalOutbox(extT.id, s, "race-p")!;
      const raceText = renderProposalText(r.hub, extT, s, outRace.payload);
      repliesPages = [[]];
      historyHook = async () => {
        historyHook = null;
        const ev = toEvent(
          { type: "message", subtype: "bot_message", channel: "C200", thread_ts: "1700000000.000100", ts: "1700000200.000100", bot_id: "B_MY_BOT", text: markNotice(raceText) },
          "U_MY_BOT",
          "B_MY_BOT",
        )!;
        await r.hub.receive("slk-r11", ev);
      };
      const recRace = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "race-p", to: "C200/1700000000.000100" } }));
      assert.equal(recRace.id, outRace.id, "post-await local re-check must return landed proposal instead of uncertain");
      assert.equal(recRace.ts, "1700000200.000100");
    } finally {
      await r.close();
    }

    // 4. applyProposalInfoSync non-empty refs replacement per-item compensation == normal PROJECTS.jsonl merge!
    let storeClock = 101;
    const compStore = Store.open(join(dir, "r11-comp.db"));
    (compStore as any).now = () => storeClock;
    try {
      await updateProjectInfo(agentHome, "ws-1", null, { name: "rep-p", refs: ["old"], now: 80 });
      const t = compStore.openThread("stillfail", "CHAT", "70.1", null, "ada@example.com");
      const [pN] = compStore.insertMessage({
        thread: t.id, ts: "70.1", authorKind: "agent", author: "chat:r11", text: "p", attachments: [],
        proposal: { id: "prop-rep-refs", name: "rep-p", refs: ["old"], status: "pending" },
      });
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store: compStore,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      const saved = await readFile(wsFile, "utf8");
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq = () => ({
        method: "POST",
        path: `/threads/${t.id}/proposals/${pN}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r11-rep" },
        body: Buffer.from(JSON.stringify({ action: "accept", refs: ["approved"] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReq())).body as Buffer).toString("utf8")).infoError);

      // Restore file & another member keeps "old" and adds "new" at t=150!
      await writeFile(wsFile, saved, "utf8");
      await updateProjectInfo(agentHome, "ws-1", null, { name: "rep-p", refs: ["old", "new"], now: 150 });
      const fileBText = await readFile(wsFile, "utf8");

      // Retry same Idempotency-Key -> compensates approved=["approved"]@101 against fileB -> ["new", "approved"] + refsClearedAt=101!
      const res2 = await admin.handle(mkReq());
      assert.equal(res2.status, 200);
      assert.equal(JSON.parse((res2.body as Buffer).toString("utf8")).infoError, undefined);
      const row = (compStore as any).db.prepare("SELECT info_refs, info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t.id, pN) as any;
      assert.equal(row.info_refs, '["approved"]');
      assert.equal(row.info_synced, 1);

      const afterComp = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.deepEqual(afterComp.projects["rep-p"]?.refs, ["new", "approved"], "non-empty replacement compensation must yield [new, approved]");
      assert.equal(afterComp.projects["rep-p"]?.refsClearedAt, 101);

      // Control group: merging two normal files (fileA: approved@101 replacing old@80; fileB: old@80 + new@150) produces the exact same refs!
      const fileAText = `${JSON.stringify({ name: "rep-p", refs: ["approved"], refsAt: 102, refAts: { approved: 102 }, updatedAt: 102, refsClearedAt: 101 })}\n`;
      const controlMerged = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${fileAText}${fileBText}`), { strict: true });
      assert.deepEqual(controlMerged.doc.projects["rep-p"]?.refs, afterComp.projects["rep-p"]?.refs, "compensated result must match normal PROJECTS.jsonl merge");

      // Merging lagging old@80 copy still keeps ["new", "approved"]!
      const diskText = await readFile(wsFile, "utf8");
      const staleOld80 = `${JSON.stringify({ name: "rep-p", refs: ["old"], refsAt: 80, refAts: { old: 80 }, updatedAt: 80 })}\n`;
      const afterStale = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${diskText}${staleOld80}`), { strict: true });
      assert.deepEqual(afterStale.doc.projects["rep-p"]?.refs, ["new", "approved"]);
    } finally {
      compStore.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R12 constructive close: applyProposalInfoSync canonical delta merge, group aseq & Slack 2001-reply resumable cursor, and R12->R10 RemoteSurface bot_id-only fallback", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r12-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { SlackSurface } = await import("../src/slack/surface.ts");
    const { RemoteSurface } = await import("../src/connects/remote.ts");
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { Admin } = await import("../src/api/admin.ts");
    const { parseProjectsJsonlWithRaw } = await import("../src/projects/info.ts");
    const { compactProjectsJsonl } = await import("./reference/memory-merge.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1. applyProposalInfoSync canonical delta merge (Astra P1-1a & P1-1b)
    let storeClock = 101;
    const compStore = Store.open(join(dir, "r12-comp.db"));
    (compStore as any).now = () => storeClock;
    try {
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store: compStore,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      await mkdir(join(agentHome, "workspaces", "ws-1"), { recursive: true });

      // 1a. 101 approves ["A"] (disk write fails), retry reads copy with refsClearedAt=90, A@91 ->
      //     retry persists refsClearedAt=101, A@102, info_synced=1; merging B@95 keeps only ["A"] (matches control group).
      const t1 = compStore.openThread("stillfail", "CHAT", "80.1", null, "ada@example.com");
      const [p1] = compStore.insertMessage({
        thread: t1.id, ts: "80.1", authorKind: "agent", author: "chat:r12a", text: "p", attachments: [],
        proposal: { id: "prop-r12-1a", name: "delta-a", refs: ["A"], status: "pending" },
      });
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq1a = () => ({
        method: "POST",
        path: `/threads/${t1.id}/proposals/${p1}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r12-1a" },
        body: Buffer.from(JSON.stringify({ action: "accept", refs: ["A"] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReq1a())).body as Buffer).toString("utf8")).infoError);

      // Copy on disk has refsClearedAt=90, A@91
      const copy90 = `${JSON.stringify({ name: "delta-a", refs: ["A"], refsAt: 91, refAts: { A: 91 }, updatedAt: 91, refsClearedAt: 90 })}\n`;
      await writeFile(wsFile, copy90, "utf8");
      const res1a = await admin.handle(mkReq1a());
      assert.equal(res1a.status, 200);
      assert.equal(JSON.parse((res1a.body as Buffer).toString("utf8")).infoError, undefined);
      const row1a = (compStore as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t1.id, p1) as any;
      assert.equal(row1a.info_synced, 1);
      const doc1a = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.equal(doc1a.projects["delta-a"]?.refsClearedAt, 101);
      assert.equal(doc1a.projects["delta-a"]?.refAts?.["A"], 102);
      assert.deepEqual(doc1a.projects["delta-a"]?.refs, ["A"]);
      // Merging B@95 keeps only ["A"], identical to control group!
      const disk1a = await readFile(wsFile, "utf8");
      const lineB95 = `${JSON.stringify({ name: "delta-a", refs: ["B"], refsAt: 95, refAts: { B: 95 }, updatedAt: 95 })}\n`;
      const merged1a = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${disk1a}${lineB95}`), { strict: true });
      const normal1a = `${JSON.stringify({ name: "delta-a", refs: ["A"], refsAt: 102, refAts: { A: 102 }, updatedAt: 102, refsClearedAt: 101 })}\n`;
      const control1a = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${copy90}${normal1a}${lineB95}`), { strict: true });
      assert.deepEqual(merged1a.doc.projects["delta-a"]?.refs, ["A"]);
      assert.deepEqual(merged1a.doc.projects["delta-a"]?.refs, control1a.doc.projects["delta-a"]?.refs);

      // 1b. Two stations both replace at 101 (station 1 approves ["A"], station 2 approves ["B"]) ->
      //     compensating A on top of B's file yields ["A", "B"], refsClearedAt=101, info_synced=1 (matches merging two normal files).
      const t2 = compStore.openThread("stillfail", "CHAT", "81.1", null, "ada@example.com");
      const [p2] = compStore.insertMessage({
        thread: t2.id, ts: "81.1", authorKind: "agent", author: "chat:r12b", text: "p", attachments: [],
        proposal: { id: "prop-r12-1b", name: "delta-ab", refs: ["A"], status: "pending" },
      });
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReq1b = () => ({
        method: "POST",
        path: `/threads/${t2.id}/proposals/${p2}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r12-1b" },
        body: Buffer.from(JSON.stringify({ action: "accept", refs: ["A"] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReq1b())).body as Buffer).toString("utf8")).infoError);

      const station2File = `${JSON.stringify({ name: "delta-ab", refs: ["B"], refsAt: 102, refAts: { B: 102 }, updatedAt: 102, refsClearedAt: 101 })}\n`;
      await writeFile(wsFile, station2File, "utf8");
      const res1b = await admin.handle(mkReq1b());
      assert.equal(res1b.status, 200);
      assert.equal(JSON.parse((res1b.body as Buffer).toString("utf8")).infoError, undefined);
      const row1b = (compStore as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(t2.id, p2) as any;
      assert.equal(row1b.info_synced, 1);
      const doc1b = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.deepEqual(doc1b.projects["delta-ab"]?.refs, ["A", "B"]);
      assert.equal(doc1b.projects["delta-ab"]?.refsClearedAt, 101);
      const station1Normal = `${JSON.stringify({ name: "delta-ab", refs: ["A"], refsAt: 102, refAts: { A: 102 }, updatedAt: 102, refsClearedAt: 101 })}\n`;
      const control1b = parseProjectsJsonlWithRaw(compactProjectsJsonl(`${station1Normal}${station2File}`), { strict: true });
      assert.deepEqual(doc1b.projects["delta-ab"]?.refs, control1b.doc.projects["delta-ab"]?.refs);
      assert.equal(doc1b.projects["delta-ab"]?.refsClearedAt, control1b.doc.projects["delta-ab"]?.refsClearedAt);
    } finally {
      compStore.close();
    }

    // 2 & 3. Group aseq pagination, Slack 2,001-reply resumable cursor, and R12->R10 RemoteSurface bot_id-only fallback
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r12" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "grp-r12", kind: "group", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slk-r12", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slk-r10-rem", kind: "slack", mode: "per-thread", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });

      // 2a. Group thread: proposal at aseq=100 followed by 201 replies (aseq 101..301) -> recovers aseq=100 across pages, sends=1!
      const grpT = r.store.openThread("group:grp-r12", "G1", "10.1", null, "ada@example.com");
      r.store.joinThread(grpT.id, s, "grp-r12");
      let grpSends = 0;
      const grpAll: { ts: string; user: string; text: string; fromBot: boolean }[] = [];
      const grpFake = {
        botUserId: () => "bot-grp",
        workspace: () => "G1",
        post: async (_here: any, text: string) => {
          grpSends++;
          grpAll.push({ ts: "100", user: "bot-grp", text, fromBot: true });
          for (let seq = 101; seq <= 301; seq++) {
            grpAll.push({ ts: String(seq), user: "u-member", text: `reply ${seq}`, fromBot: false });
          }
          throw new Error("group socket dropped after send");
        },
        history: async (_here: any, before: string, limit: number) => {
          const until = before === "" ? Number.MAX_SAFE_INTEGER : Number(before);
          const earlier = grpAll.filter((m) => Number(m.ts) < until);
          return earlier.slice(Math.max(0, earlier.length - limit));
        },
      };
      (r.hub as any).chat = (id: string) => (id === "grp-r12" ? grpFake : undefined);
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "grp-aseq", to: "G1/10.1" } }), /group socket dropped/);
      assert.equal(grpSends, 1);
      const outGrp = r.store.getPendingProposalOutbox(grpT.id, s, "grp-aseq")!;
      const recGrp = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "grp-aseq", to: "G1/10.1" } }));
      assert.equal(grpSends, 1, "group aseq cross-page recovery must NOT send a second message");
      assert.equal(recGrp.id, outGrp.id);
      assert.equal(recGrp.ts, "100");
      assert.equal(r.store.getPendingProposalOutbox(grpT.id, s, "grp-aseq"), null);

      // 2b. Slack thread: proposal followed by 2,001 replies (11 pages of 200) ->
      //     1st retry makes 10 conversations.replies calls and persists history_cursor;
      //     2nd retry resumes at page 11 (1 call) and recovers proposal + clears outbox (total 11 calls)!
      const slkT = r.store.openThread("slack:T1", "C300", "1700000000.000100", null, "ada@example.com");
      r.store.joinThread(slkT.id, s, "slk-r12");
      let slkRepliesCalls = 0;
      let slkPages: any[][] = [];
      const slkClient = {
        api: async (method: string, params: [string, string][]) => {
          if (method === "chat.postMessage") throw new Error("ETIMEDOUT after accept");
          if (method === "conversations.replies") {
            slkRepliesCalls++;
            const cur = params.find(([k]) => k === "cursor")?.[1] ?? "0";
            const idx = Number(cur);
            const msgs = slkPages[idx] ?? [];
            const next = idx + 1 < slkPages.length ? String(idx + 1) : "";
            return { ok: true, messages: msgs, response_metadata: { next_cursor: next } };
          }
          return { ok: true };
        },
      };
      const realSlk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: slkClient as any, connect: "slk-r12" });
      (realSlk as any).me = { team: "T1", teamId: "T1", url: "https://t1.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
      (r.hub as any).chat = (id: string) => (id === "slk-r12" ? realSlk : grpFake);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-2001", to: "C300/1700000000.000100" } }), /ETIMEDOUT/);
      const out2001 = r.store.getPendingProposalOutbox(slkT.id, s, "slk-2001")!;
      const text2001 = renderProposalText(r.hub, slkT, s, out2001.payload);
      // Build 11 pages: first 10 pages have 200 replies each (2,000 replies), page 11 has 1 reply + the proposal!
      slkPages = [];
      for (let p = 0; p < 10; p++) {
        const page: any[] = [];
        for (let i = 0; i < 200; i++) {
          page.push({ ts: `170000${String(p * 200 + i + 1).padStart(4, "0")}.000100`, user: "U_USER", text: `r-${p}-${i}` });
        }
        slkPages.push(page);
      }
      slkPages.push([
        { ts: "1700002001.000100", user: "U_USER", text: "r-last" },
        { ts: "1700002002.000100", bot_id: "B_MY_BOT", text: markNotice(text2001) },
      ]);

      // Retry #1: scans pages 0..9 (10 calls), saves JSON history_cursor={c:"10",s:"1700002000.000100"}, throws uncertain
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-2001", to: "C300/1700000000.000100" } }), /uncertain/i);
      assert.equal(slkRepliesCalls, 10, "first retry must stop at 10-page budget");
      const savedCur = JSON.parse(r.store.getPendingProposalOutbox(slkT.id, s, "slk-2001")!.historyCursor!);
      assert.equal(savedCur.c, "10", "must persist resumable history_cursor token");
      assert.equal(savedCur.s, "1700002000.000100", "must persist lastScannedTs for invalid_cursor recovery");

      // Retry #2: resumes from cursor="10" (1 call), recovers proposal and clears outbox!
      const rec2001 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "slk-2001", to: "C300/1700000000.000100" } }));
      assert.equal(slkRepliesCalls, 11, "second retry must resume at page 11 with only 1 additional call (11 total)");
      assert.equal(rec2001.id, out2001.id);
      assert.equal(rec2001.ts, "1700002002.000100");
      assert.equal(r.store.getPendingProposalOutbox(slkT.id, s, "slk-2001"), null);

      // 3. R12 RemoteSurface.history proxying legacy R10 Slack connect (Described has NO top-level botId, NO findNoticeInHistory,
      //    but carries R10's identity.botId = "B_MY_BOT"): rejects B_OTHER_BOT & U_OTHER, recovers B_MY_BOT!
      const remT = r.store.openThread("slack:T2", "C400", "1700000000.000200", null, "ada@example.com");
      r.store.joinThread(remT.id, s, "slk-r10-rem");
      let remHistoryRows: { ts: string; user: string; text: string; fromBot: boolean }[] = [];
      const r10Described = {
        kind: "slack" as const,
        workspace: "ws-1",
        mode: "multi-session" as const,
        requireMention: false,
        bind: { runtime: "claude" },
        botUserId: "U_MY_BOT",
        botName: "bot",
        identity: { team: "T2", teamId: "T2", url: "", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" },
        platform: "slack",
        team: "T2",
        cards: true,
        loginCards: true,
        mention: ["<@", ">"] as [string, string],
        link: "<\u0001|\u0002>",
        has: ["history"], // NO findNoticeInHistory, NO top-level botId (R10 station)
      };
      const remSurface = new RemoteSurface(
        "slk-r10-rem",
        { id: "slk-r10-rem", kind: "slack" } as any,
        "st-old-r10",
        r10Described,
        async (_st, req) => {
          if (req.op === "post") throw new Error("remote connect timed out after post");
          if (req.op === "history") return { result: remHistoryRows };
          return { result: null };
        },
        null,
      );
      assert.equal((remSurface as any).findNoticeInHistory, undefined, "R10 remote surface must not expose findNoticeInHistory");
      assert.equal(remSurface.botId(), "B_MY_BOT", "RemoteSurface.botId() must fall back to identity.botId");
      (r.hub as any).chat = (id: string) => (id === "slk-r10-rem" ? remSurface : realSlk);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "rem-r10", to: "C400/1700000000.000200" } }), /timed out/);
      const outRem = r.store.getPendingProposalOutbox(remT.id, s, "rem-r10")!;
      const remText = renderProposalText(r.hub, remT, s, outRem.payload);

      // 3a. Spoofed rows from U_OTHER or another bot B_OTHER_BOT (even with fromBot: true & valid proposal.id) must be rejected!
      remHistoryRows = [
        { ts: "1700000010.000200", user: "U_OTHER", text: markNotice(remText), fromBot: false },
        { ts: "1700000011.000200", user: "U_OTHER", text: markNotice(remText), fromBot: true },
        { ts: "1700000012.000200", user: "B_OTHER_BOT", text: markNotice(remText), fromBot: true },
      ];
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "rem-r10", to: "C400/1700000000.000200" } }), /uncertain/i);
      assert.equal(r.store.findPendingProposal(remT.id, s, "rem-r10"), null, "spoofed U_OTHER / B_OTHER_BOT rows must be rejected");

      // 3b. Genuine R10 bot_id-only row (`user: "B_MY_BOT", fromBot: true`) with valid proposal.id marker recovers & persists 1 resolvable proposal!
      remHistoryRows = [
        ...remHistoryRows,
        { ts: "1700000013.000200", user: "B_MY_BOT", text: markNotice(remText), fromBot: true },
      ];
      const recRem = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "rem-r10", to: "C400/1700000000.000200" } }));
      assert.equal(recRem.id, outRem.id);
      assert.equal(recRem.ts, "1700000013.000200");
      assert.equal(r.store.getPendingProposalOutbox(remT.id, s, "rem-r10"), null);
      const foundRem = r.store.findPendingProposal(remT.id, s, "rem-r10");
      assert.equal(foundRem?.proposal.id, outRem.id);
    } finally {
      await r.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R13 final 5 precision fixes: strict botId/identity match, single-project applyProposalInfoSync (corrupt line + 267KB legacy file), Slack invalid_cursor recovery across DB reopen, real GroupSurface unsent short-page & all-unsent recovery, and Slack findNoticeInHistory dual-marker link toggle", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r13-all-"));
  const agentHome = join(dir, "agent");
  await mkdir(agentHome, { recursive: true });
  try {
    const { SlackSurface } = await import("../src/slack/surface.ts");
    const { GroupSurface } = await import("../src/group/surface.ts");
    const { RemoteSurface } = await import("../src/connects/remote.ts");
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { Admin } = await import("../src/api/admin.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1. applyProposalInfoSync single-project delta merge:
    //    (a) file with valid record + hand-edited corrupt line -> compensation succeeds, info_synced=1, corrupt line preserved verbatim!
    //    (b) ~267 KB legacy file (refs without refAts, which if expanded whole would exceed 512 KiB, but clearing target refs fits <= 512 KiB) -> succeeds & info_synced=1!
    let storeClock = 201;
    const compStore = Store.open(join(dir, "r13-comp.db"));
    (compStore as any).now = () => storeClock;
    try {
      const admin = new Admin(
        { names: new Map() } as any,
        {
          store: compStore,
          data: dir,
          agents: { hub: { config: () => ({ agentHome }), invalidateProjectsCache: () => {} } } as any,
        } as any,
      );
      const wsFile = projectsInfoPath(agentHome, "ws-1", null);
      await mkdir(join(agentHome, "workspaces", "ws-1"), { recursive: true });

      // 1a. Corrupt line preserved verbatim during compensation
      const tCorrupt = compStore.openThread("stillfail", "CHAT", "90.1", null, "ada@example.com");
      const [pCorrupt] = compStore.insertMessage({
        thread: tCorrupt.id, ts: "90.1", authorKind: "agent", author: "chat:r13c", text: "p", attachments: [],
        proposal: { id: "prop-r13-corrupt", name: "corrupt-ok", note: "fixed", status: "pending" },
      });
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReqCorrupt = () => ({
        method: "POST",
        path: `/threads/${tCorrupt.id}/proposals/${pCorrupt}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r13-corrupt" },
        body: Buffer.from(JSON.stringify({ action: "accept", note: "fixed" })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReqCorrupt())).body as Buffer).toString("utf8")).infoError);

      const corruptLine = "{not valid json hand-edited";
      await writeFile(wsFile, `${JSON.stringify({ name: "other-p", note: "keep", updatedAt: 50 })}\n${corruptLine}\n`, "utf8");
      const resCorrupt = await admin.handle(mkReqCorrupt());
      assert.equal(resCorrupt.status, 200);
      assert.equal(JSON.parse((resCorrupt.body as Buffer).toString("utf8")).infoError, undefined);
      const rowCorrupt = (compStore as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(tCorrupt.id, pCorrupt) as any;
      assert.equal(rowCorrupt.info_synced, 1);
      const rawAfterCorrupt = await readFile(wsFile, "utf8");
      assert.ok(rawAfterCorrupt.includes(corruptLine), "hand-edited corrupt line must be preserved verbatim");
      assert.ok(rawAfterCorrupt.includes('"corrupt-ok"'));
      assert.ok(rawAfterCorrupt.includes('"other-p"'));

      // 1b. ~267 KB legacy file (refs without refAts): clearing target project's large refs succeeds even though expanding whole file first would exceed 512 KiB!
      const tBig = compStore.openThread("stillfail", "CHAT", "91.1", null, "ada@example.com");
      const [pBig] = compStore.insertMessage({
        thread: tBig.id, ts: "91.1", authorKind: "agent", author: "chat:r13b", text: "p", attachments: [],
        proposal: { id: "prop-r13-big", name: "big-target", refs: ["a"], status: "pending" },
      });
      await writeFile(wsFile, `${JSON.stringify({ name: "big", note: "x".repeat(FILE_MOST + 10) })}\n`, "utf8");
      const mkReqBig = () => ({
        method: "POST",
        path: `/threads/${tBig.id}/proposals/${pBig}/resolve`,
        query: [],
        headers: { "idempotency-key": "idem-r13-big" },
        body: Buffer.from(JSON.stringify({ action: "accept", refs: [] })),
        viewer: { workspace: "ws-1", email: "ada@example.com", sub: "u1", name: "", role: "member" },
        lang: "en",
      } as any);
      assert.ok(JSON.parse(((await admin.handle(mkReqBig())).body as Buffer).toString("utf8")).infoError);

      // Construct ~270 KB legacy file where target project holds ~120 KB of refs (which when expanded with refAts would push total > 512 KiB,
      // while clearing target project's refs leaves the serialized file well under 512 KiB!).
      const legacyLines: string[] = [];
      for (let i = 0; i < 65; i++) {
        const refs = Array.from({ length: 16 }, (_, j) => `repo-${i}-${j}-${"a".repeat(160)}`);
        legacyLines.push(JSON.stringify({ name: `legacy-${String(i).padStart(3, "0")}`, refs, updatedAt: 100 }));
      }
      const targetRefs = Array.from({ length: 16 }, (_, j) => `target-ref-${j}-${"z".repeat(4800)}`);
      legacyLines.push(JSON.stringify({ name: "big-target", refs: targetRefs, updatedAt: 100 }));
      const legacyText = `${legacyLines.join("\n")}\n`;
      assert.ok(Buffer.byteLength(legacyText, "utf8") > 250 * 1024 && Buffer.byteLength(legacyText, "utf8") < FILE_MOST);
      await writeFile(wsFile, legacyText, "utf8");

      const resBig = await admin.handle(mkReqBig());
      assert.equal(resBig.status, 200);
      assert.equal(JSON.parse((resBig.body as Buffer).toString("utf8")).infoError, undefined);
      const rowBig = (compStore as any).db.prepare("SELECT info_synced FROM proposal_outcomes WHERE thread = ? AND n = ?").get(tBig.id, pBig) as any;
      assert.equal(rowBig.info_synced, 1);
      const docBig = await readProjectsInfoStrict(agentHome, "ws-1", null);
      assert.equal(docBig.projects["big-target"]?.refs, undefined, "target project refs must be cleared");
      assert.equal(docBig.projects["big-target"]?.refsClearedAt, 201);
    } finally {
      compStore.close();
    }

    // 2. Slack invalid_cursor recovery across DB reopen + dual-marker link toggle + real GroupSurface unsent replies + empty botUserId/botId rejection
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r13" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "slk-r13", kind: "slack", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "grp-r13", kind: "group", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "unk-r13", kind: "slack", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });

      // 2a. Slack invalid_cursor recovery across SQLite reopen:
      //     Retry #1 scans 10 pages & persists { c, s }; DB closes & reopens; Retry #2 gets invalid_cursor for old cursor ->
      //     automatically drops cursor & re-queries with oldest = savedSince -> recovers proposal in 2 API calls!
      const slkT = r.store.openThread("slack:T1", "C500", "1700000000.000100", null, "ada@example.com");
      r.store.joinThread(slkT.id, s, "slk-r13");
      let expiredCursor = false;
      const seenQueries: { cursor: string | null; oldest: string | null }[] = [];
      let slkPages: any[][] = [];
      let tailAfterSince: any[] = [];
      const slkClient = {
        api: async (method: string, params: [string, string][]) => {
          if (method === "chat.postMessage") throw new Error("ETIMEDOUT after accept");
          if (method === "conversations.replies") {
            const cur = params.find(([k]) => k === "cursor")?.[1] ?? null;
            const oldest = params.find(([k]) => k === "oldest")?.[1] ?? null;
            seenQueries.push({ cursor: cur, oldest });
            if (expiredCursor && cur === "10") {
              throw new Error("slack conversations.replies: invalid_cursor");
            }
            if (expiredCursor && cur === null && oldest === "1700002000.000100") {
              return { ok: true, messages: tailAfterSince, response_metadata: { next_cursor: "" } };
            }
            const idx = cur ? Number(cur) : 0;
            const msgs = slkPages[idx] ?? [];
            const next = idx + 1 < slkPages.length ? String(idx + 1) : "";
            return { ok: true, messages: msgs, response_metadata: { next_cursor: next } };
          }
          return { ok: true };
        },
      };
      const realSlk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: slkClient as any, connect: "slk-r13" });
      (realSlk as any).me = { team: "T1", teamId: "T1", url: "https://t1.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
      (r.hub as any).chat = (id: string) => (id === "slk-r13" ? realSlk : undefined);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-invcur", to: "C500/1700000000.000100" } }), /ETIMEDOUT/);
      const outInv = r.store.getPendingProposalOutbox(slkT.id, s, "slk-invcur")!;
      const textInv = renderProposalText(r.hub, slkT, s, outInv.payload);
      slkPages = [];
      for (let p = 0; p < 10; p++) {
        const page: any[] = [];
        for (let i = 0; i < 200; i++) {
          page.push({ ts: `170000${String(p * 200 + i + 1).padStart(4, "0")}.000100`, user: "U_USER", text: `m-${p}-${i}` });
        }
        slkPages.push(page);
      }
      tailAfterSince = [{ ts: "1700002002.000100", bot_id: "B_MY_BOT", text: markNotice(textInv) }];
      slkPages.push(tailAfterSince);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-invcur", to: "C500/1700000000.000100" } }), /uncertain/i);
      const persistedCursor = r.store.getPendingProposalOutbox(slkT.id, s, "slk-invcur")?.historyCursor;
      assert.ok(persistedCursor && JSON.parse(persistedCursor).c === "10" && JSON.parse(persistedCursor).s === "1700002000.000100");

      // Close & reopen SQLite DB to verify persisted cursor survives restart!
      const dbPath = join(r.dir, "stillfail.db");
      r.store.close();
      const reopened = Store.open(dbPath);
      (r as any).store = reopened;
      (r.hub as any).store = reopened;

      seenQueries.length = 0;
      expiredCursor = true;
      const recInv = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "slk-invcur", to: "C500/1700000000.000100" } }));
      assert.equal(recInv.id, outInv.id);
      assert.equal(recInv.ts, "1700002002.000100");
      assert.equal(seenQueries.length, 2, "must try persisted cursor once, catch invalid_cursor, and re-query with oldest=savedSince");
      assert.equal(seenQueries[0]!.cursor, "10");
      assert.equal(seenQueries[1]!.cursor, null);
      assert.equal(seenQueries[1]!.oldest, "1700002000.000100");
      assert.equal(reopened.getPendingProposalOutbox(slkT.id, s, "slk-invcur"), null);

      // 2b. Native Slack findNoticeInHistory dual-marker link toggle (both directions!):
      //     (i) Sent WITH hub.link() (#proposal=<id>), retried WITHOUT hub.link() -> recovers!
      //     (ii) Sent WITHOUT hub.link() ([#<id>]), retried WITH hub.link() -> recovers!
      expiredCursor = false;
      (r.hub as any).link = () => "https://app.still.fail/chats/s1";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-link-on", to: "C500/1700000000.000100" } }), /ETIMEDOUT/);
      const outLinkOn = reopened.getPendingProposalOutbox(slkT.id, s, "slk-link-on")!;
      const textLinkOn = renderProposalText(r.hub, slkT, s, outLinkOn.payload);
      assert.ok(textLinkOn.includes(`#proposal=${encodeURIComponent(outLinkOn.id)}`));
      slkPages = [[{ ts: "1700003001.000100", bot_id: "B_MY_BOT", text: markNotice(textLinkOn) }]];
      // Disable hub.link() on retry!
      (r.hub as any).link = () => undefined;
      const recLinkOn = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "slk-link-on", to: "C500/1700000000.000100" } }));
      assert.equal(recLinkOn.ts, "1700003001.000100");

      // Direction (ii): Sent WITHOUT hub.link() ([#<id>]), retried WITH hub.link()!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "slk-link-off", to: "C500/1700000000.000100" } }), /ETIMEDOUT/);
      const outLinkOff = reopened.getPendingProposalOutbox(slkT.id, s, "slk-link-off")!;
      const textLinkOff = renderProposalText(r.hub, slkT, s, outLinkOff.payload);
      assert.ok(textLinkOff.includes(`[#${outLinkOff.id}]`));
      slkPages = [[{ ts: "1700003002.000100", bot_id: "B_MY_BOT", text: markNotice(textLinkOff) }]];
      // Enable hub.link() on retry!
      (r.hub as any).link = () => "https://app.still.fail/chats/s1";
      const recLinkOff = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "slk-link-off", to: "C500/1700000000.000100" } }));
      assert.equal(recLinkOff.ts, "1700003002.000100");
      (r.hub as any).link = () => undefined;

      // 2c. Real GroupSurface.history: proposal at aseq=100, followed by 201 replies (aseq 101..301):
      //     (i) 1 unsent reply in newest 200 (short page of 199 live items) -> 2 pages recover aseq=100, sends=1!
      //     (ii) ALL 200 newest replies unsent -> still recovers aseq=100, sends=1!
      const grpT = reopened.openThread("group:grp-r13", "G2", "10.1", null, "ada@example.com");
      reopened.joinThread(grpT.id, s, "grp-r13");
      const realGrp = new GroupSurface({
        connect: "grp-r13",
        server: "a".repeat(64),
        key: "1".repeat(64),
        relays: [],
        code: "",
        botName: "bot",
        threads: {} as any,
        endpoints: {} as any,
      });
      (realGrp as any).me = { team: "G", teamId: "G", url: "", botUserId: "bot-grp", botName: "bot", botImage: null, botId: "" };
      let grpSends = 0;
      let grpEvents: any[] = [];
      (realGrp as any).post = async (_here: any, text: string) => {
        grpSends++;
        const events: any[] = [
          { id: "ev-100", aseq: 100, event: { kind: "msg.post", topic: "10.1", author: "bot-grp", body: { text } } },
        ];
        for (let seq = 101; seq <= 301; seq++) {
          events.push({ id: `ev-${seq}`, aseq: seq, event: { kind: "msg.post", topic: "10.1", author: "u-mem", body: { text: `r-${seq}` } } });
        }
        // Unsend 1 message in the newest 200 (aseq=250) -> makes page 1 return 199 live messages (<200)!
        events.push({ id: "ev-unsend-250", aseq: 302, event: { kind: "msg.unsend", topic: "10.1", author: "u-mem", body: { target: "ev-250" } } });
        grpEvents = events;
        throw new Error("group send lost receipt");
      };
      (realGrp as any).eventsAfter = async (_space: string, after: number) => grpEvents.filter((e) => e.aseq > after).slice(0, 100);
      (r.hub as any).chat = (id: string) => (id === "grp-r13" ? realGrp : realSlk);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "grp-unsend-1", to: "G2/10.1" } }), /group send lost/);
      assert.equal(grpSends, 1);
      const outG1 = reopened.getPendingProposalOutbox(grpT.id, s, "grp-unsend-1")!;
      const recG1 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "grp-unsend-1", to: "G2/10.1" } }));
      assert.equal(grpSends, 1);
      assert.equal(recG1.id, outG1.id);
      assert.equal(recG1.ts, "100");

      // Boundary (ii): ALL 201 replies (101..301) after aseq=100 are unsent in a fresh thread G2/10.2!
      const grpT2 = reopened.openThread("group:grp-r13", "G2", "10.2", null, "ada@example.com");
      reopened.joinThread(grpT2.id, s, "grp-r13");
      (realGrp as any).post = async (_here: any, text: string) => {
        grpSends++;
        const events: any[] = [
          { id: "ev-100b", aseq: 100, event: { kind: "msg.post", topic: "10.2", author: "bot-grp", body: { text } } },
        ];
        for (let seq = 101; seq <= 301; seq++) {
          events.push({ id: `ev-b-${seq}`, aseq: seq, event: { kind: "msg.post", topic: "10.2", author: "u-mem", body: { text: `r-${seq}` } } });
        }
        let nextAseq = 302;
        for (let seq = 101; seq <= 301; seq++) {
          events.push({ id: `ev-ub-${seq}`, aseq: nextAseq++, event: { kind: "msg.unsend", topic: "10.2", author: "u-mem", body: { target: `ev-b-${seq}` } } });
        }
        grpEvents = events;
        throw new Error("group send lost receipt 2");
      };
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "grp-unsend-all", to: "G2/10.2" } }), /group send lost/);
      assert.equal(grpSends, 2);
      const outG2 = reopened.getPendingProposalOutbox(grpT2.id, s, "grp-unsend-all")!;
      const recG2 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "grp-unsend-all", to: "G2/10.2" } }));
      assert.equal(grpSends, 2);
      assert.equal(recG2.id, outG2.id);
      assert.equal(recG2.ts, "100");

      // 2d. Empty botUserId AND empty botId -> trustedSender is always false (never matches any message)!
      const unkT = reopened.openThread("slack:T3", "C600", "1700000000.000300", null, "ada@example.com");
      reopened.joinThread(unkT.id, s, "unk-r13");
      const unkSurface = new RemoteSurface(
        "unk-r13",
        { id: "unk-r13", kind: "slack" } as any,
        "st-unk",
        {
          kind: "slack",
          workspace: "ws-1",
          mode: "multi-session",
          requireMention: false,
          bind: { runtime: "claude" },
          botUserId: "",
          botName: "",
          identity: null,
          platform: "slack",
          team: "T3",
          cards: false,
          loginCards: false,
          mention: ["<@", ">"],
          link: "<\u0001|\u0002>",
          has: ["history"],
        },
        async (_st, req) => {
          if (req.op === "post") throw new Error("unk timeout");
          if (req.op === "history") {
            const outU = reopened.getPendingProposalOutbox(unkT.id, s, "unk-p")!;
            const txtU = renderProposalText(r.hub, unkT, s, outU.payload);
            return { result: [{ ts: "1700000050.000300", user: "B_ANY_BOT", text: markNotice(txtU), fromBot: true }] };
          }
          return { result: null };
        },
        null,
      );
      (r.hub as any).chat = (id: string) => (id === "unk-r13" ? unkSurface : realSlk);
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "unk-p", to: "C600/1700000000.000300" } }), /unk timeout/);
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "unk-p", to: "C600/1700000000.000300" } }), /uncertain/i);
      assert.equal(reopened.findPendingProposal(unkT.id, s, "unk-p"), null, "empty botUserId+botId must never accept any history row");
    } finally {
      await r.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R14 full-channel closure: real FeishuSurface chat+thread findNoticeInHistory, real GroupSurface large-space aseq>20000 resumable scan, and bidirectional R12/R14 findNoticeInHistory mixed-version compat", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r14-all-"));
  try {
    const { FeishuSurface } = await import("../src/feishu/surface.ts");
    const { GroupSurface } = await import("../src/group/surface.ts");
    const { SlackSurface } = await import("../src/slack/surface.ts");
    const { RemoteSurface } = await import("../src/connects/remote.ts");
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r14" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "fs-r14", kind: "feishu", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "grp-r14", kind: "group", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "slk-r12-rem", kind: "slack", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });

      // 1. Real FeishuSurface.findNoticeInHistory: both ordinary `chat` container AND `thread` container!
      const fsChatT = r.store.openThread("feishu:fs-r14", "oc_chat1", "om_root1", null, "ada@example.com");
      r.store.joinThread(fsChatT.id, s, "fs-r14");
      const fsTopicT = r.store.openThread("feishu:fs-r14", "oc_chat2", "omt_topic1", null, "ada@example.com");
      r.store.joinThread(fsTopicT.id, s, "fs-r14");

      let fsSends = 0;
      const fsQueries: Record<string, string>[] = [];
      let fsItems: any[] = [];
      const fsClient = {
        api: async (method: string, path: string, _body?: any, query?: Record<string, string>) => {
          if (method === "GET" && path === "/open-apis/im/v1/messages") {
            fsQueries.push({ ...(query ?? {}) });
            return { data: { items: fsItems, has_more: false, page_token: "" } };
          }
          return { data: {} };
        },
      };
      const realFs = new FeishuSurface({
        connect: "fs-r14",
        appId: "cli_my_app",
        appSecret: "sec_1",
        domain: "feishu",
        threads: { topicRoot: () => null } as any,
        client: fsClient as any,
      });
      (realFs as any).me = { team: "FS", teamId: "FS", url: "", botUserId: "ou_my_bot", botName: "bot", botImage: null, botId: "" };
      (realFs as any).post = async () => {
        fsSends++;
        throw new Error("feishu post lost message_id receipt");
      };
      (r.hub as any).chat = (id: string) => (id === "fs-r14" ? realFs : undefined);

      // 1a. Ordinary chat (topicRoot === null -> container_id_type="chat", container_id="oc_chat1", start_time present)
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "fs-chat-p", to: "oc_chat1/om_root1" } }), /lost message_id/);
      assert.equal(fsSends, 1);
      const outFsChat = r.store.getPendingProposalOutbox(fsChatT.id, s, "fs-chat-p")!;
      const textFsChat = renderProposalText(r.hub, fsChatT, s, outFsChat.payload);
      // Spoofed user message + other app message must be rejected; only own app (`cli_my_app`) accepted!
      fsItems = [
        { message_id: "om_spoof_user", chat_id: "oc_chat1", msg_type: "text", body: { content: JSON.stringify({ text: markNotice(textFsChat) }) }, sender: { sender_type: "user", id: "ou_user1" } },
        { message_id: "om_spoof_app", chat_id: "oc_chat1", msg_type: "text", body: { content: JSON.stringify({ text: markNotice(textFsChat) }) }, sender: { sender_type: "app", id: "cli_other_app" } },
        { message_id: "om_real_chat", chat_id: "oc_chat1", msg_type: "text", body: { content: JSON.stringify({ text: markNotice(textFsChat) }) }, sender: { sender_type: "app", id: "cli_my_app" } },
      ];
      fsQueries.length = 0;
      const recFsChat = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "fs-chat-p", to: "oc_chat1/om_root1" } }));
      assert.equal(fsSends, 1, "Feishu chat recovery must not send a second message");
      assert.equal(recFsChat.id, outFsChat.id);
      assert.equal(recFsChat.ts, "om_real_chat");
      assert.equal(fsQueries[0]?.container_id_type, "chat");
      assert.equal(fsQueries[0]?.container_id, "oc_chat1");
      assert.ok(fsQueries[0]?.start_time, "chat container must pass start_time");
      assert.equal(r.store.getPendingProposalOutbox(fsChatT.id, s, "fs-chat-p"), null);

      // 1b. Topic/thread chat (`omt_topic1` -> container_id_type="thread", container_id="omt_topic1", NO start_time!)
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "fs-topic-p", to: "oc_chat2/omt_topic1" } }), /lost message_id/);
      assert.equal(fsSends, 2);
      const outFsTopic = r.store.getPendingProposalOutbox(fsTopicT.id, s, "fs-topic-p")!;
      const textFsTopic = renderProposalText(r.hub, fsTopicT, s, outFsTopic.payload);
      fsItems = [
        { message_id: "om_real_topic", chat_id: "oc_chat2", msg_type: "text", body: { content: JSON.stringify({ text: markNotice(textFsTopic) }) }, sender: { sender_type: "app", id: "cli_my_app" } },
      ];
      fsQueries.length = 0;
      const recFsTopic = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "fs-topic-p", to: "oc_chat2/omt_topic1" } }));
      assert.equal(fsSends, 2);
      assert.equal(recFsTopic.ts, "om_real_topic");
      assert.equal(fsQueries[0]?.container_id_type, "thread");
      assert.equal(fsQueries[0]?.container_id, "omt_topic1");
      assert.equal(fsQueries[0]?.start_time, undefined, "thread container must NOT pass start_time");

      // 2. Real GroupSurface.findNoticeInHistory on large space (20,000 events in other topics, proposal at aseq=20001 + 201 replies + 1 unsend):
      //    Retry #1 scans 40 pages (20,000 events) and persists history_cursor="20000";
      //    Retry #2 resumes at after=20000 in 1 single page and recovers aseq=20001, sends=1!
      const grpT = r.store.openThread("group:grp-r14", "G3", "10.1", null, "ada@example.com");
      r.store.joinThread(grpT.id, s, "grp-r14");
      const realGrp = new GroupSurface({
        connect: "grp-r14",
        server: "b".repeat(64),
        key: "2".repeat(64),
        relays: [],
        code: "",
        botName: "bot",
        threads: {} as any,
        endpoints: {} as any,
      });
      (realGrp as any).me = { team: "G", teamId: "G", url: "", botUserId: "bot-grp-14", botName: "bot", botImage: null, botId: "" };
      let grpSends = 0;
      let grpPostedText = "";
      let eventsAfterCalls = 0;
      (realGrp as any).post = async (_here: any, text: string) => {
        grpSends++;
        grpPostedText = text;
        throw new Error("group lost receipt on large space");
      };
      (realGrp as any).eventsAfter = async (_space: string, after: number) => {
        eventsAfterCalls++;
        if (after < 20000) {
          const end = Math.min(20000, after + 500);
          const batch: any[] = [];
          for (let seq = after + 1; seq <= end; seq++) {
            if (seq === 20000) {
              // Spoofed non-bot author in target topic carrying exact proposal text -> MUST be rejected!
              batch.push({ id: `ev-${seq}`, aseq: seq, event: { kind: "msg.post", topic: "10.1", author: "u-spoof", body: { text: grpPostedText } } });
            } else {
              batch.push({ id: `ev-${seq}`, aseq: seq, event: { kind: "msg.post", topic: "other-topic", author: "u-other", body: { text: "noise" } } });
            }
          }
          return batch;
        }
        if (after === 20000) {
          const batch: any[] = [
            { id: "ev-20001", aseq: 20001, event: { kind: "msg.post", topic: "10.1", author: "bot-grp-14", body: { text: grpPostedText } } },
          ];
          for (let seq = 20002; seq <= 20202; seq++) {
            batch.push({ id: `ev-${seq}`, aseq: seq, event: { kind: "msg.post", topic: "10.1", author: "u-mem", body: { text: `r-${seq}` } } });
          }
          batch.push({ id: "ev-unsend", aseq: 20203, event: { kind: "msg.unsend", topic: "10.1", author: "u-mem", body: { target: "ev-20100" } } });
          return batch;
        }
        return [];
      };
      (r.hub as any).chat = (id: string) => (id === "grp-r14" ? realGrp : realFs);

      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "grp-20k", to: "G3/10.1" } }), /large space/);
      assert.equal(grpSends, 1);
      const outG20k = r.store.getPendingProposalOutbox(grpT.id, s, "grp-20k")!;

      // Retry #1: scans 40 pages (events 1..20000), rejects spoofed aseq=20000, persists history_cursor="20000"
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "grp-20k", to: "G3/10.1" } }), /uncertain/i);
      assert.equal(eventsAfterCalls, 40, "first retry must scan 40 pages");
      assert.equal(r.store.getPendingProposalOutbox(grpT.id, s, "grp-20k")?.historyCursor, "20000");

      // Retry #2: resumes at after=20000 in 1 single page, recovers aseq=20001 and clears outbox!
      const recG20k = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "grp-20k", to: "G3/10.1" } }));
      assert.equal(eventsAfterCalls, 41, "second retry must resume from 20000 with 1 single page call");
      assert.equal(grpSends, 1);
      assert.equal(recG20k.id, outG20k.id);
      assert.equal(recG20k.ts, "20001");
      assert.equal(r.store.getPendingProposalOutbox(grpT.id, s, "grp-20k"), null);

      // 3. Bidirectional R12/R14 findNoticeInHistory mixed-version compatibility:
      // 3a. R14 session station + V1 R12 remote Slack connect (has ["history", "findNoticeInHistory"], NO V2; only checks opts.marker):
      //     works even when hub.link() toggled between send and retry (both directions)!
      const remT = r.store.openThread("slack:T9", "C900", "1700000000.000900", null, "ada@example.com");
      r.store.joinThread(remT.id, s, "slk-r12-rem");
      let v1StoredText = "";
      let v1StoredTs = "";
      const v1SeenMarkers: string[] = [];
      const r12Remote = new RemoteSurface(
        "slk-r12-rem",
        { id: "slk-r12-rem", kind: "slack" } as any,
        "st-r12-v1",
        {
          kind: "slack",
          workspace: "ws-1",
          mode: "multi-session",
          requireMention: false,
          bind: { runtime: "claude" },
          botUserId: "U_MY_BOT",
          botId: "B_MY_BOT",
          botName: "bot",
          identity: null,
          platform: "slack",
          team: "T9",
          cards: true,
          loginCards: true,
          mention: ["<@", ">"],
          link: "<\u0001|\u0002>",
          has: ["history", "findNoticeInHistory"], // V1 only (NO findNoticeInHistoryV2)
        },
        async (_st, req) => {
          if (req.op === "post") {
            v1StoredText = String(req.args[1]);
            throw new Error("r12 remote post lost receipt");
          }
          if (req.op === "findNoticeInHistory") {
            const opts = req.args[1] as { marker?: string };
            v1SeenMarkers.push(opts.marker ?? "");
            // Legacy R12 handler ONLY checks `opts.marker`!
            if (typeof opts.marker === "string" && opts.marker !== "" && v1StoredText.includes(opts.marker)) {
              return { result: { ts: v1StoredTs, cursor: null, done: true } };
            }
            return { result: { ts: null, cursor: null, done: true } };
          }
          return { result: null };
        },
        null,
      );
      assert.equal(r12Remote.supportsFindNoticeV2(), false);
      (r.hub as any).chat = (id: string) => (id === "slk-r12-rem" ? r12Remote : realFs);

      // Direction (i): sent WITH link, retried WITHOUT link
      (r.hub as any).link = () => "https://app.still.fail/chats/s1";
      v1StoredTs = "1700009001.000900";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "mix-link-on", to: "C900/1700000000.000900" } }), /lost receipt/);
      (r.hub as any).link = () => undefined;
      v1SeenMarkers.length = 0;
      const recMix1 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "mix-link-on", to: "C900/1700000000.000900" } }));
      assert.equal(recMix1.ts, "1700009001.000900");
      assert.equal(v1SeenMarkers.length, 2, "must fall back to alternate marker on V1 remote station");

      // Direction (ii): sent WITHOUT link, retried WITH link
      (r.hub as any).link = () => undefined;
      v1StoredTs = "1700009002.000900";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "mix-link-off", to: "C900/1700000000.000900" } }), /lost receipt/);
      (r.hub as any).link = () => "https://app.still.fail/chats/s1";
      v1SeenMarkers.length = 0;
      const recMix2 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "mix-link-off", to: "C900/1700000000.000900" } }));
      assert.equal(recMix2.ts, "1700009002.000900");
      assert.equal(v1SeenMarkers.length, 2);

      // 3b. Legacy V1 caller (only `opts.marker`, NO `proposalId`) calling R14 SlackSurface.findNoticeInHistory:
      //     rejects B_OTHER_BOT and recovers B_MY_BOT!
      const v1SlackClient = {
        api: async () => ({
          ok: true,
          messages: [
            { ts: "1700009010.000100", bot_id: "B_OTHER_BOT", text: markNotice("Notice [#prop-v1-only]") },
            { ts: "1700009011.000100", bot_id: "B_MY_BOT", text: markNotice("Notice [#prop-v1-only]") },
          ],
          response_metadata: { next_cursor: "" },
        }),
      };
      const r14Slk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: v1SlackClient as any, connect: "slk-v1-check" });
      (r14Slk as any).me = { team: "T9", teamId: "T9", url: "https://t9.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
      const v1Res = await r14Slk.findNoticeInHistory(
        { channel: "C900", threadTs: "1700000000.000900" },
        { marker: "[#prop-v1-only]", sinceSec: 1700000000, cursor: null, maxPages: 10 },
      );
      assert.equal(v1Res.ts, "1700009011.000100", "R14 SlackSurface must support V1 marker-only callers while rejecting B_OTHER_BOT");
      assert.equal(v1Res.done, true);
    } finally {
      await r.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("R15 final 3 precision fixes: V1 marker ID extraction across encodings, V1-only remote {v1m,c} multi-page resume on altMarker, and Comma task.put ownNotice reconciliation", async () => {
  const dir = await mkdtemp(join(tmpdir(), "stillfail-r15-all-"));
  try {
    const { SlackSurface } = await import("../src/slack/surface.ts");
    const { CommaSurface, seqTs } = await import("../src/comma/surface.ts");
    const { RemoteSurface } = await import("../src/connects/remote.ts");
    const { markNotice } = await import("../src/sessions/chat.ts");
    const { sessionKey } = await import("../src/sessions/hub.ts");
    const { renderProposalText } = await import("../src/sessions/projects.ts");

    // 1. V1 caller passing ONLY opts.marker (no proposalId) finds opposite encoding on R14 SlackSurface while rejecting B_OTHER_BOT!
    const v1EncClient = {
      api: async () => ({
        ok: true,
        messages: [
          { ts: "1700010001.000100", bot_id: "B_OTHER_BOT", text: markNotice("Confirm: https://app.still.fail/chats/s1#proposal=prop-v1-link") },
          { ts: "1700010002.000100", bot_id: "B_MY_BOT", text: markNotice("Confirm: https://app.still.fail/chats/s1#proposal=prop-v1-link") },
          { ts: "1700010003.000100", bot_id: "B_OTHER_BOT", text: markNotice("Confirm in still.fail [#prop-v1-plain].") },
          { ts: "1700010004.000100", bot_id: "B_MY_BOT", text: markNotice("Confirm in still.fail [#prop-v1-plain].") },
        ],
        response_metadata: { next_cursor: "" },
      }),
    };
    const r15Slk = new SlackSurface({ appToken: "xapp-1", botToken: "xoxb-1", client: v1EncClient as any, connect: "slk-r15" });
    (r15Slk as any).me = { team: "T1", teamId: "T1", url: "https://t1.slack.com", botUserId: "U_MY_BOT", botName: "bot", botImage: null, botId: "B_MY_BOT" };
    // Plain marker query finds link-encoded message
    const resA = await r15Slk.findNoticeInHistory(
      { channel: "C1", threadTs: "1700000000.000100" },
      { marker: "[#prop-v1-link]", sinceSec: 1700000000, cursor: null, maxPages: 10 },
    );
    assert.equal(resA.ts, "1700010002.000100");
    // Link marker query finds plain-encoded message
    const resB = await r15Slk.findNoticeInHistory(
      { channel: "C1", threadTs: "1700000000.000100" },
      { marker: "#proposal=prop-v1-plain", sinceSec: 1700000000, cursor: null, maxPages: 10 },
    );
    assert.equal(resB.ts, "1700010004.000100");

    // 2 & 3. V1-only remote { v1m, c } 11-page altMarker resume + real CommaSurface task.put ownNotice reconciliation
    const r = new Rig({ link: false, workspaces: ["ws-1"], place: { workspace: "ws-1", station: "st-r15" }, projectsOn: () => true });
    r.raw.profiles = [{ id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-4-6"] }];
    r.raw.connects = [
      { id: "slk-v1-11p", kind: "slack", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
      { id: "cm-r15", kind: "comma", mode: "multi-session", profile: "cc", model: "claude-opus-4-6", workspace: "ws-1" } as any,
    ];
    r.config = hubConfig(r.raw, r.dir);
    try {
      const [s] = await newSession(r.hub, { runtime: "claude", model: "claude-opus-4-6", createdBy: "ada@example.com", ws: "ws-1" });

      // 2. R14 session station + V1-only remote Slack connect (11 pages of 200; sent WITH link, retried WITHOUT link; target on page 11):
      const remT = r.store.openThread("slack:T1", "C700", "1700000000.000700", null, "ada@example.com");
      r.store.joinThread(remT.id, s, "slk-v1-11p");
      let remPosts = 0;
      let remPostedText = "";
      const remPages: any[][] = [];
      for (let p = 0; p < 10; p++) {
        remPages.push(Array.from({ length: 200 }, (_, i) => ({ ts: `170000${String(p * 200 + i + 1).padStart(4, "0")}.000700`, text: `noise-${p}-${i}` })));
      }
      const remV1Surface = new RemoteSurface(
        "slk-v1-11p",
        { id: "slk-v1-11p", kind: "slack" } as any,
        "st-r12-v1",
        {
          kind: "slack",
          workspace: "ws-1",
          mode: "multi-session",
          requireMention: false,
          bind: { runtime: "claude" },
          botUserId: "U_MY_BOT",
          botId: "B_MY_BOT",
          botName: "bot",
          identity: null,
          platform: "slack",
          team: "T1",
          cards: true,
          loginCards: true,
          mention: ["<@", ">"],
          link: "<\u0001|\u0002>",
          has: ["history", "findNoticeInHistory"], // V1 only (NO findNoticeInHistoryV2)
        },
        async (_st, req) => {
          if (req.op === "post") {
            remPosts++;
            remPostedText = String(req.args[1]);
            remPages[10] = [{ ts: "1700002011.000700", text: remPostedText }];
            throw new Error("v1 remote post lost receipt");
          }
          if (req.op === "findNoticeInHistory") {
            const opts = req.args[1] as { marker?: string; cursor: string | null; maxPages: number };
            let idx = opts.cursor ? Number(opts.cursor) : 0;
            for (let step = 0; step < opts.maxPages; step++) {
              const msgs = remPages[idx] ?? [];
              for (const m of msgs) {
                if (typeof opts.marker === "string" && opts.marker !== "" && m.text.includes(opts.marker)) {
                  return { result: { ts: m.ts, cursor: null, done: true } };
                }
              }
              idx++;
              if (idx >= remPages.length) return { result: { ts: null, cursor: null, done: true } };
            }
            return { result: { ts: null, cursor: String(idx), done: false } };
          }
          return { result: null };
        },
        null,
      );
      (r.hub as any).chat = (id: string) => (id === "slk-v1-11p" ? remV1Surface : undefined);

      // Send WITH link, then disable link on retries
      (r.hub as any).link = () => "https://app.still.fail/chats/s1";
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "v1-11p", to: "C700/1700000000.000700" } }), /lost receipt/);
      assert.equal(remPosts, 1);
      const outV1 = r.store.getPendingProposalOutbox(remT.id, s, "v1-11p")!;
      (r.hub as any).link = () => undefined;

      // Retry #1: scans pages 0..9 with primaryMarker ([#-]), persists { v1m: "[#<id>]", c: "10" }
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "v1-11p", to: "C700/1700000000.000700" } }), /uncertain/i);
      const cur1 = JSON.parse(r.store.getPendingProposalOutbox(remT.id, s, "v1-11p")!.historyCursor!);
      assert.equal(cur1.v1m, `[#${outV1.id}]`);
      assert.equal(cur1.c, "10");

      // Retry #2: finishes primaryMarker page 11 (done: true), switches to altMarker (#proposal=<id>) pages 0..9, persists { v1m: "#proposal=<id>", c: "10" }!
      await assert.rejects(() => projectManage(r.hub, s, { action: "propose", args: { name: "v1-11p", to: "C700/1700000000.000700" } }), /uncertain/i);
      const cur2 = JSON.parse(r.store.getPendingProposalOutbox(remT.id, s, "v1-11p")!.historyCursor!);
      assert.equal(cur2.v1m, `#proposal=${encodeURIComponent(outV1.id)}`);
      assert.equal(cur2.c, "10");

      // Retry #3: resumes altMarker at page 11, immediately recovers ts & clears outbox (total posts = 1)!
      const recV1 = JSON.parse(await projectManage(r.hub, s, { action: "propose", args: { name: "v1-11p", to: "C700/1700000000.000700" } }));
      assert.equal(remPosts, 1);
      assert.equal(recV1.id, outV1.id);
      assert.equal(recV1.ts, "1700002011.000700");
      assert.equal(r.store.getPendingProposalOutbox(remT.id, s, "v1-11p"), null);

      // 3. Real CommaSurface task.put ownNotice reconciliation:
      const cmThreadTs = "100.1";
      const cmSession = sessionKey("cm-r15", "TASK", cmThreadTs);
      const cmT = r.store.openThread("comma:cm-r15", "TASK", cmThreadTs, null, "ada@example.com");
      r.store.insertSession({
        key: cmSession,
        connect: "cm-r15",
        scope: "thread",
        runtime: "claude",
        model: "claude-opus-4-6",
        profile: "cc",
        workspace: r.dir,
        ws: "ws-1",
        createdBy: "ada@example.com",
        token: "tok-cm-r15",
        createdAt: r.store.now(),
        lastActiveAt: r.store.now(),
      });
      r.store.joinThread(cmT.id, cmSession, "cm-r15");

      const taskObj = { task: "cnv_r15", threadTs: cmThreadTs, answered: 0, left: false, start: { requester: "u1", title: null, runtime: "claude", model: "claude-opus-4-6" }, links: null };
      const cmSurface = new CommaSurface({
        connect: "cm-r15",
        server: "http://127.0.0.1:1",
        token: "tok",
        name: "st-r15",
        tasks: {
          byThread: (_c: string, ts: string) => (ts === cmThreadTs ? taskObj : null),
          get: (_c: string, tid: string) => (tid === "cnv_r15" ? taskObj : null),
          setLinks: () => {},
          given: () => {},
        },
        store: r.store,
        models: () => ({}),
        lang: "en",
      } as any);
      (cmSurface as any).handler = (ev: any) => r.hub.receive("cm-r15", ev);
      (r.hub as any).chat = (id: string) => (id === "cm-r15" ? cmSurface : remV1Surface);

      let cmPostCount = 0;
      let cmPostedText = "";
      (cmSurface as any).socket_ = {
        send: (raw: string) => {
          const f = JSON.parse(raw);
          if (f.method === "task.post") {
            cmPostCount++;
            cmPostedText = String(f.params?.text ?? "");
            // Drop response (simulate in-flight disconnect after Comma accepted!)
            queueMicrotask(() => (cmSurface as any).closed());
          }
        },
      };

      const deliveriesBefore = ((r.store as any).db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ?").get(cmT.id) as any).c;
      await assert.rejects(() => projectManage(r.hub, cmSession, { action: "propose", args: { name: "cm-put-p", to: `TASK/${cmThreadTs}` } }), /Comma is not connected/);
      assert.equal(cmPostCount, 1);
      const outCm = r.store.getPendingProposalOutbox(cmT.id, cmSession, "cm-put-p")!;
      assert.equal(outCm.sending, true);
      assert.ok(cmPostedText.includes(`[#${outCm.id}]`));

      // Negative checks: wrong author.session OR missing NOTICE_MARK must NOT reconcile outbox!
      await (cmSurface as any).put({
        task: "cnv_r15",
        through: 21,
        answered: 0,
        messages: [
          { seq: 20, author: { kind: "agent", session: "other-session" }, text: cmPostedText },
          { seq: 21, author: { kind: "agent", session: cmSession }, text: renderProposalText(r.hub, cmT, cmSession, outCm.payload) },
        ],
      });
      assert.ok(r.store.getPendingProposalOutbox(cmT.id, cmSession, "cm-put-p") !== null, "wrong session / missing NOTICE_MARK must NOT reconcile");

      // Genuine own-session replayed notice at seq=22 -> reconciles outbox, persists proposal at seqTs(22), 0 agent deliveries!
      const putRes = await (cmSurface as any).put({
        task: "cnv_r15",
        through: 22,
        answered: 0,
        messages: [
          { seq: 22, author: { kind: "agent", session: cmSession }, text: cmPostedText },
        ],
      });
      assert.deepEqual(putRes, { through: 22 });
      assert.equal(r.store.getPendingProposalOutbox(cmT.id, cmSession, "cm-put-p"), null, "task.put ownNotice must clear outbox");
      const foundCm = r.store.findPendingProposal(cmT.id, cmSession, "cm-put-p");
      assert.equal(foundCm?.proposal.id, outCm.id);
      assert.equal(foundCm?.ts, seqTs(22));
      const deliveriesAfter = ((r.store as any).db.prepare("SELECT COUNT(*) AS c FROM deliveries WHERE thread = ?").get(cmT.id) as any).c;
      assert.equal(deliveriesAfter, deliveriesBefore, "Comma ownNotice must NEVER wake agent");

      // Subsequent proposeProject returns deduplicated hit with 0 extra posts!
      const dedupCm = JSON.parse(await projectManage(r.hub, cmSession, { action: "propose", args: { name: "cm-put-p", to: `TASK/${cmThreadTs}` } }));
      assert.equal(dedupCm.deduplicated, true);
      assert.equal(dedupCm.id, outCm.id);
      assert.equal(cmPostCount, 1);
    } finally {
      await r.close();
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
