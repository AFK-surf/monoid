// Cross-workspace personal secret browsing & usage in client/core-ts:
// - browseCandidates strictly excludes team vaults (scope: "workspace"), unlisted items, unkeyed vaults
// - Workspace/single-item selection in Vaults.approve (browse)
// - Source workspace completely offline: decrypts from local SQLite cache and re-seals under grantContext(wsB, reqId)
// - usesView & lastUses merge cross-workspace uses with workspace and workspaceName
// - askAnswers returns approve/empty/elsewhere for browse, and source-workspace noKey/lasts for cross
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import { apply as applyOps } from "../src/delta.ts";
import type { HttpRequest } from "../src/host.ts";
import type { StationAddr } from "../src/station/addr.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import type { FakeHost } from "../src/testing.ts";
import { type Entry, Signer, entryHash, signedBytes } from "../src/lock.ts";
import { utf8 } from "../src/util.ts";
import {
  type BoxCert, type BrowseAnswer, type Grant, type Item, type Request, type Vault,
  TAG, boxPublic, encryptWith, grantContext, itemContext, keyContext, openSeal, sealWith, sign, signedOk,
} from "../src/vault/crypto.ts";
import { askAnswers, readStation } from "../src/views/vault.ts";
import { call, subscribe } from "./helpers.ts";
import { base, started, stationReplies, status } from "./station-fixture.ts";

const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);

function lockOf(ws: string, meSigner: { id: string; signBytes: (b: Uint8Array) => string }, deviceId: string, sub = "s1") {
  const e = {
    v: 1, ws, seq: 0, prev: null, at: 1000, kind: "genesis",
    body: {
      owner: sub, origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
      members: [{ sub, email: "me@x.com", role: "owner" }],
      devices: [{ id: deviceId, sub, kind: "app", label: "Mac", sign_key: meSigner.id }],
      passkeys: [], stations: [], gateways: [],
    },
  } as Omit<Entry, "sig">;
  const h = entryHash(e as Entry);
  const full = { ...e, sig: { key: meSigner.id, alg: "Ed25519", sig: meSigner.signBytes(signedBytes(h)) } } as Entry;
  return { head: { seq: 0, hash: h, genesis: h }, entries: [full], requests: [] };
}

function makeFakeStation(ws: string) {
  const vaults = new Map<string, Vault>();
  const items = new Map<string, Item>();
  const boxes = new Map<string, BoxCert>();
  const requests: Request[] = [];
  const grants: Grant[] = [];
  const browses: BrowseAnswer[] = [];
  const denials: unknown[] = [];
  const crossUses: unknown[] = [];
  const keepers = new Map<string, Uint8Array>();
  const down = { on: false };

  const reply = (req: HttpRequest): unknown => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (!path.startsWith("/vault/")) return undefined;
    if (down.on) return status(503, { error: "offline", code: "unavailable" });
    const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
    const [route, query] = path.split("?");
    const k = `${req.method} ${route}`;
    switch (k) {
      case "GET /vault/vaults": return { vaults: [...vaults.values()] };
      case "POST /vault/vaults/latest": return { vaults: [] };
      case "PUT /vault/vaults": vaults.set(body.id, body); return { vault: body };
      case "GET /vault/items": return { items: [...items.values()].filter((i) => !query || query === `vault=${i.vault}`) };
      case "PUT /vault/items": items.set(body.id, body); return { item: body };
      case "GET /vault/boxes": return { boxes: [...boxes.values()] };
      case "PUT /vault/boxes": boxes.set(body.device, body); return { box: body };
      case "GET /vault/requests": return { requests };
      case "GET /vault/uses": return { uses: [] };
      case "GET /vault/cross-uses": return { uses: crossUses };
      case "POST /vault/browses":
        browses.push(body);
        for (const q of requests) if (q.id === body.request) q.status = "granted";
        return { ok: true };
      case "POST /vault/grants": {
        const box = keepers.get(body.request);
        if (box) openSeal(box, body.secret, grantContext(ws, body.request));
        grants.push(body);
        for (const q of requests) if (q.id === body.request) q.status = "granted";
        return { ok: true };
      }
      case "POST /vault/denials":
        denials.push(body);
        for (const q of requests) if (q.id === body.request) q.status = "denied";
        return { ok: true };
      default: return status(404, { error: `no route ${k}` });
    }
  };
  return { vaults, items, boxes, requests, grants, browses, denials, crossUses, keepers, down, reply };
}

async function multiWsRig() {
  const stA = makeFakeStation("ws");
  const stB = makeFakeStation("wsB");
  const AT = "x-test-station";
  const me = { signer: null as Signer | null };

  const wire = (host: FakeHost): StationWire => {
    const inner = new HostWire(host);
    return {
      request: (station: StationAddr, head: RequestHead, body: Uint8Array) =>
        inner.request(station, { ...head, headers: [...head.headers, [AT, `${station.workspace}/${station.station}`]] }, body),
    };
  };

  const s = await started(base(), 0, wire, (x) => {
    x.host.appKeys = true;
    me.signer = Effect.runSync(Signer.make(x.host));
    x.cloud.more = [
      { id: "wsB", name: "Work B", role: "owner", locked: true, stations: [{ id: "stB", name: "Station B", online: true, last_seen: null }] },
    ];
    stationReplies(x.host, (req) => {
      const target = req.headers.find(([k]) => k.toLowerCase() === AT)?.[1];
      if (target === "ws/st") return stA.reply(req);
      if (target === "wsB/stB") return stB.reply(req);
      return undefined;
    });
  });

  const devId = "ab".repeat(32);
  const signerObj = { id: me.signer!.id, signBytes: (b: Uint8Array) => me.signer!.signBytes(b) };
  const lA = lockOf("ws", signerObj, devId, "s1");
  const lB = lockOf("wsB", signerObj, devId, "s1");
  s.core.inner.data.put("lock", "ws", lA);
  s.core.inner.data.put("lock", "wsB", lB);

  const ui = s.core.connect();
  const values = new Map<number, unknown>();
  const done = new Map<number, Record<string, unknown>>();
  let id = 100;
  const take = () => {
    for (const [, m] of s.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if ("value" in msg) values.set(msg.id as number, msg.value);
      else if ("delta" in msg) values.set(msg.id as number, applyOps(values.get(msg.id as number), msg.delta as never));
      else if ("ok" in msg || "error" in msg) done.set(msg.id as number, msg);
    }
  };
  const ask = async (name: string, params: Record<string, unknown>, steps = 200): Promise<any> => {
    const n = ++id;
    call(s.core, ui, n, name, params);
    for (let i = 0; i < steps && !done.has(n); i++) {
      await s.host.time.pass(10);
      take();
    }
    const a = done.get(n);
    if (!a) throw new Error(`${name}: no answer`);
    await s.host.time.pass(100);
    take();
    if ("error" in a) {
      const e = new Error((a.error as { message: string }).message) as Error & { code: string };
      e.code = (a.error as { code: string }).code;
      throw e;
    }
    return a.ok;
  };
  const watch = async (n: number, topic: Record<string, unknown>) => {
    subscribe(s.core, ui, n, topic as never);
    await s.host.time.pass(100);
    take();
    return () => {
      take();
      return values.get(n) as any;
    };
  };
  return { ...s, stA, stB, signerObj, devId, ask, watch };
}

test("browseCandidates excludes team vaults & unlisted items; offline cross-workspace approve & usesView", async () => {
  const r = await multiWsRig();
  try {
    // 1. Set up personal vaults in ws (source) and wsB (target)
    const setupA = await r.ask("vault.setup", { workspace: "ws" });
    const personalA = setupA.made as string;
    const itemListed = await r.ask("vault.putItem", {
      workspace: "ws",
      vault: personalA,
      plain: { kind: "token", name: "GitHub A", fields: { value: "ghp_from_wsA_offline" }, domains: [], notes: "" },
      listing: { name: "GitHub A", kind: "token", modes: ["proxy", "env"], hosts: ["api.github.com"], env: "GH_TOKEN" },
    });
    await r.ask("vault.putItem", {
      workspace: "ws",
      vault: personalA,
      plain: { kind: "token", name: "Private Only", fields: { value: "secret_unlisted" }, domains: [], notes: "" },
    });

    // Inject a TEAM vault (scope: "workspace") in ws with a listed item — must NEVER appear in browseCandidates
    const teamVaultId = "v_team_ws";
    const boxCertA = r.stA.boxes.get(r.devId)!;
    const teamKey = fill(9);
    const teamVault: Vault = sign({
      v: 1 as const, ws: "ws", id: teamVaultId, seq: 0, owner: "s1", scope: "workspace" as const,
      name: "Team Vault A", members: ["s1"], epoch: 0,
      keys: [{ cert: boxCertA, wrapped: sealWith(boxCertA.box, teamKey, keyContext("ws", teamVaultId, 0), fill(10)) }],
      at: 1000,
    }, TAG.vault, r.signerObj);
    const teamItem: Item = sign({
      v: 1 as const, ws: "ws", vault: teamVaultId, id: "i_team_1", version: 0, epoch: 0,
      ct: encryptWith(teamKey, utf8(JSON.stringify({ kind: "token", name: "TeamSecret", fields: { value: "team_val" }, domains: [], notes: "" })), itemContext("ws", teamVaultId, "i_team_1", 0, 0), fill(11, 12)),
      listing: { name: "TeamSecret", kind: "token" as const, modes: ["proxy" as const], hosts: ["team.test"] },
      at: 1000,
    }, TAG.item, r.signerObj);
    r.stA.vaults.set(teamVaultId, teamVault);
    r.stA.items.set("i_team_1", teamItem);
    await Effect.runPromise(readStation(r.core.inner, "ws/st"));

    await r.ask("vault.setup", { workspace: "wsB" });

    // 2. Query vault.browseCandidates from wsB
    const cand = await r.ask("vault.browseCandidates", { workspace: "wsB" });
    assert.equal(cand.workspaces.length, 1);
    assert.equal(cand.workspaces[0].id, "ws");
    assert.equal(cand.workspaces[0].name, "W");
    assert.deepEqual(cand.workspaces[0].items.map((i: any) => i.name), ["GitHub A"]);

    // 3. Browse request arrives on wsB; check askAnswers; approve while ws is COMPLETELY OFFLINE
    const browseReq: Request = {
      id: "r_browse_1", ws: "wsB", vault: "", item: "", session: "s1", chat: "CHAT/1.0",
      mode: "browse", reason: "need personal github token", owner: "me@x.com", box: "", at: 1005, status: "pending",
      browse: {},
    };
    r.stB.requests.push(browseReq);
    await Effect.runPromise(readStation(r.core.inner, "wsB/stB"));

    assert.deepEqual(
      askAnswers(r.core.inner, "wsB", [{ request: "r_browse_1", save: false, browse: true }])[0],
      { answer: "approve", browseWorkspaces: 1, browseItems: 1 },
    );

    // Reactive cross-workspace update: subscribe to wsB vaults topic while r_browse_1 is pending,
    // then add a second listed personal secret in ws (wsA); wsB's vaults topic must auto-update browseItems 1 -> 2.
    const vaultsBSub = await r.watch(98, { topic: "vaults", workspace: "wsB" });
    const reqBefore = (vaultsBSub().requests as any[]).find((q) => q.id === "r_browse_1");
    assert.equal(reqBefore.browseWorkspaces, 1);
    assert.equal(reqBefore.browseItems, 1);

    await r.ask("vault.putItem", {
      workspace: "ws",
      vault: personalA,
      plain: { kind: "token", name: "NPM A", fields: { value: "npm_from_wsA" }, domains: [], notes: "" },
      listing: { name: "NPM A", kind: "token", modes: ["proxy"], hosts: ["registry.npmjs.org"] },
    });
    const reqAfter = (vaultsBSub().requests as any[]).find((q) => q.id === "r_browse_1");
    assert.equal(reqAfter.browseWorkspaces, 1);
    assert.equal(reqAfter.browseItems, 2);

    // Take ws station COMPLETELY OFFLINE!
    r.stA.down.on = true;

    const browseRes = await r.ask("vault.approve", {
      workspace: "wsB",
      request: "r_browse_1",
      items: [{ workspace: "ws", vault: personalA, item: itemListed.id }],
    });
    assert.deepEqual(browseRes, { request: "r_browse_1", workspaces: 1, items: 1 });
    assert.equal(r.stB.browses.length, 1);
    assert.ok(signedOk(r.stB.browses[0]!, TAG.browse));
    assert.equal(r.stB.browses[0]!.items.length, 1);
    assert.equal(r.stB.browses[0]!.items[0]!.sourceWs, "ws");

    // 4. Cross-workspace use request arrives on wsB while ws is STILL OFFLINE
    const keeperPriv = fill(22);
    const keeperPub = boxPublic(keeperPriv);
    r.stB.keepers.set("r_cross_use_1", keeperPriv);
    const crossUseReq: Request = {
      id: "r_cross_use_1", ws: "wsB", vault: personalA, item: itemListed.id, session: "s1", chat: "CHAT/1.0",
      mode: "proxy", hosts: ["api.github.com"], reason: "call GitHub API", owner: "me@x.com",
      box: keeperPub, at: 1006, status: "pending",
      cross: { workspace: "ws", workspaceName: "W", vaultName: "Personal" },
    };
    r.stB.requests.push(crossUseReq);
    await Effect.runPromise(readStation(r.core.inner, "wsB/stB"));

    assert.equal(
      askAnswers(r.core.inner, "wsB", [{ request: "r_cross_use_1", save: false, crossWs: "ws" }])[0]!.answer,
      "approve",
    );

    const useRes = await r.ask("vault.approve", {
      workspace: "wsB",
      request: "r_cross_use_1",
      scope: "once",
    });
    assert.equal(useRes.request, "r_cross_use_1");
    assert.equal(useRes.scope, "once");
    assert.equal(r.stB.grants.length, 1);
    const g = r.stB.grants[0]!;
    assert.equal(g.sourceWs, "ws");
    assert.equal(g.ws, "wsB");
    assert.ok(signedOk(g, TAG.grant));
    const opened = JSON.parse(new TextDecoder().decode(openSeal(keeperPriv, g.secret, grantContext("wsB", "r_cross_use_1"))));
    assert.equal(opened.fields.value, "ghp_from_wsA_offline");

    // 5. Cross-workspace use shows up in usesView of personalA in ws with workspace="wsB"
    r.stB.crossUses.push({
      request: "r_cross_use_1",
      sourceWorkspace: "ws",
      sourceVault: personalA,
      item: itemListed.id,
      session: "s1",
      chatTitle: "Deploy in Work B",
      mode: "proxy",
      hosts: ["api.github.com"],
      status: "granted",
      scope: "once",
      at: 1007,
    });
    await Effect.runPromise(readStation(r.core.inner, "wsB/stB"));
    const usesSub = await r.watch(99, { topic: "vaultUses", workspace: "ws", vault: personalA, item: itemListed.id });
    const uses = usesSub() as { uses: { session: string; chatTitle: string | null; workspace?: string; workspaceName?: string }[] };
    assert.equal(uses.uses.length, 1);
    assert.equal(uses.uses[0]!.session, "s1");
    assert.equal(uses.uses[0]!.chatTitle, "Deploy in Work B");
    assert.equal(uses.uses[0]!.workspace, "wsB");
    assert.equal(uses.uses[0]!.workspaceName, "Work B");
  } finally {
    r.core.close();
  }
});
