// Stage 2: Workspace vault discovery, join requests (requestJoin / cancelJoin / dismissJoin), atomic addMember /
// removeMember (409 conflict retry, join_cancelled race, bad-key isolation, no offline fork on remove), recovery-word
// preservation after requestJoin, and strict isolation from global lockPrompts (vaultAsks).
import assert from "node:assert/strict";
import { test } from "node:test";
import { ed25519 } from "@noble/curves/ed25519.js";
import { Effect } from "effect";
import { STORAGE_KEY } from "../src/accounts.ts";
import { type Entry, entryHash, next } from "../src/lock.ts";
import { PERSONAL_KEY } from "../src/personal-lock.ts";
import type { HttpRequest } from "../src/host.ts";
import { hex, utf8 } from "../src/util.ts";
import {
  type BoxCert, type Item, type JoinAsk, type JoinDismiss, type Vault,
  TAG, boxPublic, joinAskOk, sign, signedOk, trySealWith, usableBoxKey,
} from "../src/vault/crypto.ts";
import { vaultAsks, vaultCome, vaultsView } from "../src/views/vault.ts";
import { signerKnown } from "../src/views/lock.ts";
import { account, call } from "./helpers.ts";
import { withoutMesh } from "./lock-rig.ts";
import { started, stationReplies, status } from "./station-fixture.ts";
// @ts-ignore: the MoonBit build's JS, untyped
import * as rules from "../../../rules/js/rules.js";

const unhex = (h: string) => Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16));
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);

function edKey(seed: Uint8Array) {
  const id = `ed25519:${hex(ed25519.getPublicKey(seed))}`;
  return { id, hex: hex(ed25519.getPublicKey(seed)), signBytes: (b: Uint8Array) => hex(ed25519.sign(b, seed)) };
}

function lockEntry(e: ReturnType<typeof next>, by: ReturnType<typeof edKey>): Entry {
  return { ...e, sig: { key: by.id, alg: "Ed25519", sig: by.signBytes(new Uint8Array([...utf8("stillfail-lock/1 sig\0"), ...unhex(entryHash(e))])) } };
}

function makeWorkspaceLock(
  ws: string,
  ownerSub: string,
  ownerKey: ReturnType<typeof edKey>,
  members: { sub: string; email: string; role: string }[],
  devices: { id: string; sub: string; sign_key: string; label?: string }[],
): Entry[] {
  const body = {
    ws, owner: ownerSub,
    origins: ["https://app.still.fail"], rp_id: "still.fail",
    cloud_keys: { keys: [] },
    members,
    devices: devices.map((d) => ({ id: d.id, sub: d.sub, kind: "app", label: d.label ?? d.id.slice(0, 8), sign_key: d.sign_key })),
    passkeys: [], stations: [], gateways: [],
  };
  return [lockEntry(next(ws, null, 1000, "genesis", body), ownerKey)];
}

function joinStation(opts: { roles: Record<string, string>; chains?: Record<string, Entry[]> }) {
  const vaults = new Map<string, Vault>();
  const items = new Map<string, Item>();
  const boxes = new Map<string, BoxCert>();
  const joins = new Map<string, { ask: JoinAsk | null; joinedUpTo: number; dismissUpTo: number; dismiss: JoinDismiss | null }>();
  let forceConflictOnce = false;
  let offline = false;

  const jk = (vault: string, sub: string) => `${vault}/${sub}`;

  const replyFor = (viewerSub: string) => (req: HttpRequest): unknown => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (!path.startsWith("/vault/")) return undefined;
    if (offline) return status(503, { error: "station offline", code: "vault_handover" });
    const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
    const [route, query] = path.split("?");
    const qs = new URLSearchParams(query ?? "");
    const k = `${req.method} ${route}`;
    const isAdmin = opts.roles[viewerSub] === "owner" || opts.roles[viewerSub] === "admin";
    switch (k) {
      case "GET /vault/plain":
        return { items: [], locked: true };
      case "GET /vault/uses":
      case "GET /vault/cross-uses":
        return { uses: [] };
      case "GET /vault/requests":
        return { requests: [] };
      case "GET /vault/asks":
        return { asks: [] };
      case "GET /vault/vaults": {
        const mine = [...vaults.values()].filter((v) => v.members.includes(viewerSub));
        const discoverable = [...vaults.values()]
          .filter((v) => !v.deleted && v.scope === "workspace" && !v.members.includes(viewerSub))
          .map((v) => ({
            id: v.id, ws: v.ws, name: v.name, scope: "workspace" as const,
            owner: v.owner, memberCount: v.members.length, seq: v.seq, at: v.at,
          }));
        return { vaults: mine, discoverable };
      }
      case "POST /vault/vaults/latest":
        return { vaults: (body.held as Vault[]).map((h) => vaults.get(h.id)).filter((v): v is Vault => v !== undefined) };
      case "PUT /vault/vaults": {
        const prev = vaults.get(body.id);
        const copy = qs.get("copy") === "1";
        if (forceConflictOnce && !copy && prev !== undefined) {
          forceConflictOnce = false;
          return status(409, { error: "conflict", code: "vault_conflict", vault: prev });
        }
        if (copy && prev && body.seq <= prev.seq && !(body.seq === prev.seq && rules.vault_supersedes_js(body, prev))) return { vault: prev };
        if (!copy && body.seq !== (prev ? prev.seq + 1 : 0)) return status(409, { error: "seq", code: "vault_conflict", vault: prev ?? null });
        if (!signedOk(body, TAG.vault)) return status(400, { error: "signature", code: "vault_invalid" });
        const approveSub = qs.get("approveJoinSub");
        const approveAt = qs.get("approveJoinAt");
        if (approveSub && approveAt !== null) {
          const row = joins.get(jk(body.id, approveSub));
          if (!row || !row.ask || row.ask.state !== "pending" || row.ask.at !== Number(approveAt) || row.ask.at <= row.joinedUpTo || row.ask.at <= row.dismissUpTo) {
            return status(409, { error: "join cancelled", code: "join_cancelled" });
          }
        }
        const added = (body.members as string[]).filter((m) => !(prev?.members ?? []).includes(m));
        for (const sub of added) {
          const row = joins.get(jk(body.id, sub));
          if (row && row.ask && row.ask.at > row.joinedUpTo) {
            row.joinedUpTo = row.ask.at;
          }
        }
        vaults.set(body.id, body);
        return { vault: body };
      }
      case "GET /vault/items": {
        const allowed = new Set([...vaults.values()].filter((v) => v.members.includes(viewerSub)).map((v) => v.id));
        return { items: [...items.values()].filter((i) => allowed.has(i.vault)) };
      }
      case "PUT /vault/items": {
        const prev = items.get(body.id);
        const copy = qs.get("copy") === "1";
        if (!vaults.has(body.vault)) return status(404, { error: "no vault", code: "vault_unknown" });
        if (copy && prev && body.version <= prev.version) return { item: prev };
        if (!copy && body.version !== (prev ? prev.version + 1 : 0)) return status(409, { error: "version", code: "vault_conflict", item: prev ?? null });
        items.set(body.id, body);
        return { item: body };
      }
      case "GET /vault/boxes":
        return opts.chains ? { boxes: [...boxes.values()], chains: opts.chains, roles: opts.roles } : { boxes: [...boxes.values()] };
      case "PUT /vault/boxes":
        if (!signedOk(body, TAG.box)) return status(400, { error: "signature", code: "vault_invalid" });
        boxes.set(body.device, body);
        return { box: body };
      case "GET /vault/joins": {
        const outJoins: JoinAsk[] = [];
        const outDismisses: JoinDismiss[] = [];
        for (const v of vaults.values()) {
          if (v.deleted || v.scope !== "workspace") continue;
          if (isAdmin && v.members.includes(viewerSub)) {
            for (const [key, row] of joins) {
              if (!key.startsWith(`${v.id}/`)) continue;
              if (row.ask && !v.members.includes(row.ask.sub) && row.ask.at > row.joinedUpTo) {
                if (row.ask.state === "cancelled" || row.ask.at > row.dismissUpTo) {
                  outJoins.push(row.ask);
                }
              }
              if (row.dismiss) outDismisses.push(row.dismiss);
            }
          } else if (!v.members.includes(viewerSub)) {
            const row = joins.get(jk(v.id, viewerSub));
            if (row) {
              if (row.ask && row.ask.at > row.joinedUpTo) outJoins.push(row.ask);
              if (row.dismiss) outDismisses.push(row.dismiss);
            }
          }
        }
        return { joins: outJoins, dismisses: outDismisses };
      }
      case "PUT /vault/joins": {
        const nextAsk = body as JoinAsk;
        const v = vaults.get(nextAsk.vault);
        if (!v || v.deleted || v.scope !== "workspace") return status(404, { error: "no vault", code: "vault_unknown" });
        if (v.members.includes(viewerSub)) return { join: nextAsk, alreadyMember: true };
        if (nextAsk.state === "pending") {
          const b = boxes.get(nextAsk.device);
          if (!b || b.box !== nextAsk.box) return status(409, { error: "box missing", code: "vault_box_missing" });
        }
        const key = jk(nextAsk.vault, nextAsk.sub);
        const cur = joins.get(key) ?? { ask: null, joinedUpTo: -1, dismissUpTo: -1, dismiss: null };
        if (cur.ask && cur.ask.at >= nextAsk.at) return { join: cur.ask };
        cur.ask = nextAsk;
        joins.set(key, cur);
        return { join: nextAsk };
      }
      case "PUT /vault/joins/dismiss": {
        const d = body as JoinDismiss;
        const v = vaults.get(d.vault);
        if (!v || v.deleted || v.scope !== "workspace" || !v.members.includes(viewerSub)) return status(404, { error: "no vault", code: "vault_unknown" });
        const key = jk(d.vault, d.sub);
        const cur = joins.get(key) ?? { ask: null, joinedUpTo: -1, dismissUpTo: -1, dismiss: null };
        if (d.upTo > cur.dismissUpTo) {
          cur.dismissUpTo = d.upTo;
          cur.dismiss = d;
        }
        joins.set(key, cur);
        return { dismiss: cur.dismiss ?? d };
      }
      default:
        return undefined;
    }
  };

  return {
    vaults, items, boxes, joins,
    setForceConflictOnce: (v: boolean) => { forceConflictOnce = v; },
    setOffline: (v: boolean) => { offline = v; },
    replyFor,
  };
}

let devSeq = 0;

async function makeDevice(opts: {
  sub: string;
  email: string;
  devId: string;
  signerSeed: Uint8Array;
  st: ReturnType<typeof joinStation>;
  wsMembers: { sub: string; email: string; name: string; role: string }[];
  lockEntries: Entry[];
}) {
  const signer = edKey(opts.signerSeed);
  const myRole = opts.wsMembers.find((m) => m.sub === opts.sub)?.role ?? "member";
  const s = await started(undefined, 0, undefined, (x) => {
    x.host.appKeys = true;
    x.host.store(STORAGE_KEY, [account(opts.sub, opts.email, "", "tok", "r0", Math.floor(x.host.nowMs() / 1000) + 3600)]);
    x.host.secure.set("lock-signer", { value: opts.signerSeed, user: false });
    x.cloud.role = myRole;
    x.cloud.also = { locked: true, members: opts.wsMembers };
    stationReplies(x.host, (req) => opts.st.replyFor(opts.sub)(req));
  });
  s.core.inner.mesh = () => withoutMesh(opts.devId);
  signerKnown(s.core.inner, signer.id);
  await s.host.time.pass(1000 * (++devSeq));
  const head = opts.lockEntries[opts.lockEntries.length - 1]!;
  s.core.inner.data.put("lock", "ws", {
    entries: opts.lockEntries,
    head: { seq: head.seq, hash: entryHash(head), genesis: entryHash(opts.lockEntries[0]!) },
  });
  vaultCome(s.core.inner, "ws");
  const ui = s.core.connect();
  let nextId = 200;
  const askRaw = async (name: string, params: Record<string, unknown> = {}) => {
    const id = ++nextId;
    s.host.takeEmitted();
    call(s.core, ui, id, name, { workspace: "ws", ...params });
    let found: any;
    for (let i = 0; i < 60 && found === undefined; i++) {
      await s.host.time.pass(50);
      for (const [, m] of s.host.takeEmitted()) {
        const r = m as any;
        if (r.id === id && ("ok" in r || "error" in r)) found = r;
      }
    }
    assert.ok(found !== undefined, `${name}: no answer`);
    return found;
  };
  const ask = async (name: string, params: Record<string, unknown> = {}) => {
    const r = await askRaw(name, params);
    assert.equal(r.error, undefined, `${name}: ${JSON.stringify(r.error)}`);
    return r.ok as any;
  };
  const askErr = async (name: string, params: Record<string, unknown> = {}) => {
    const r = await askRaw(name, params);
    assert.ok(r.error !== undefined, `${name}: expected error, got ${JSON.stringify(r.ok)}`);
    return r.error as { code: string; message: string };
  };
  const sync = async () => {
    for (const a of s.core.inner.stations.also) {
      s.core.inner.runner.fork(Effect.ignore(a.read("ws/st")));
    }
    await s.host.time.pass(400);
    s.host.takeEmitted();
  };
  const deliverEvent = (name: string, data: unknown) => {
    for (const a of s.core.inner.stations.also) {
      a.event("ws/st", name, data);
    }
  };
  return { core: s.core, host: s.host, signer, ask, askErr, sync, deliverEvent };
}

test("Stage 2 end-to-end: discovery, requestJoin (no global popup, recovery words preserved), cancelJoin + join_cancelled, dismissJoin, addMember conflict retry & bad-cert isolation, removeMember offline guard & vault-gone re-discovery", async () => {
  const aliceSeed = fill(201), bobSeed = fill(202), carolSeed = fill(203), badSeed = fill(204);
  const aliceDev = "a1".repeat(32), bobDev = "b2".repeat(32), carolDev = "c3".repeat(32), badDev = "d4".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed), carolKey = edKey(carolSeed), badKey = edKey(badSeed);

  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
    { sub: "carol", email: "carol@x.com", name: "Carol", role: "member" },
  ];
  const lockEntries = makeWorkspaceLock(
    "ws",
    "alice",
    aliceKey,
    wsMembers.map(({ sub, email, role }) => ({ sub, email, role })),
    [
      { id: aliceDev, sub: "alice", sign_key: aliceKey.id, label: "Alice Mac" },
      { id: bobDev, sub: "bob", sign_key: bobKey.id, label: "Bob Phone" },
      { id: badDev, sub: "bob", sign_key: badKey.id, label: "Bob BadCert" },
      { id: carolDev, sub: "carol", sign_key: carolKey.id, label: "Carol Laptop" },
    ],
  );
  const st = joinStation({ roles: { alice: "owner", bob: "member", carol: "member" } });
  const alice = await makeDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, st, wsMembers, lockEntries });
  const bob = await makeDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, st, wsMembers, lockEntries });

  try {
    // 1. Alice sets up personal vault and creates a workspace vault initially containing only Alice.
    const setupA = await alice.ask("vault.setup", {});
    assert.ok(typeof setupA.words === "string" && setupA.words.split(" ").length === 24);
    const created = await alice.ask("vault.create", { name: "团队密钥库", scope: "workspace", members: ["alice"] });
    const wsVaultId: string = created.id;
    await alice.ask("vault.putItem", {
      vault: wsVaultId,
      plain: { kind: "token", name: "Deploy Token", fields: { value: "sec_team_42" }, domains: [], notes: "" },
      listing: { name: "Deploy Token", kind: "token", modes: ["env"], hosts: [] },
    });
    const itemId = [...st.items.values()].find((i) => i.vault === wsVaultId)!.id;

    // 2. Bob (not set up yet) discovers the workspace vault without becoming a member.
    await bob.sync();
    const bobView0 = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobView0.setUp, false);
    assert.equal(bobView0.hasRecovery, undefined);
    assert.equal(bobView0.availableWorkspaceVaults?.length, 1);
    assert.equal(bobView0.availableWorkspaceVaults[0].id, wsVaultId);
    assert.equal(bobView0.availableWorkspaceVaults[0].requested, false);

    // 3. Bob calls requestJoin: silently publishes BoxCert (no personal vault, no recovery words skipped) + JoinAsk.
    const req1 = await bob.ask("vault.requestJoin", { vault: wsVaultId });
    assert.equal(req1.asked, 1);
    assert.equal(req1.alreadyMember, false);

    const bobView1 = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobView1.setUp, true);
    assert.equal(bobView1.hasRecovery, undefined, "requestJoin must NOT mark hasRecovery=true");
    assert.equal(bobView1.vaults.length, 0, "requestJoin must NOT create a personal vault");
    assert.equal(bobView1.availableWorkspaceVaults[0].requested, true);

    // 4. Alice syncs: join request appears in VaultRow.joinRequests, NEVER in global vaultAsks (lockPrompts)!
    await alice.sync();
    assert.equal(vaultAsks(alice.core.inner).length, 0, "JoinAsk must NEVER trigger global lockPrompts popup");
    const aliceView1 = vaultsView(alice.core.inner, "ws") as any;
    const aliceWs1 = aliceView1.vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWs1.unjoinedCount, 2);
    assert.equal(aliceWs1.joinRequests?.length, 1);
    assert.equal(aliceWs1.joinRequests[0].sub, "bob");
    const firstAskAt: number = aliceWs1.joinRequests[0].at;

    // 5. Bob cancels join; Alice trying to approve while station is OFFLINE must fail without local fallback,
    //    and once online, Alice trying to approve the stale askAt fails atomically with 409 join_cancelled AND clears her cached pending row!
    const cancelRes = await bob.ask("vault.cancelJoin", { vault: wsVaultId });
    assert.deepEqual(cancelRes, { cancelled: true, alreadyMember: false });
    const bobViewCancel = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobViewCancel.availableWorkspaceVaults[0].requested, false);

    st.setOffline(true);
    const errOfflineApprove = await alice.askErr("vault.addMember", { vault: wsVaultId, sub: "bob", askAt: firstAskAt });
    assert.equal(errOfflineApprove.code, "vault_station_offline", "explicit join approval must disable local fallback when station is offline");
    assert.ok(!st.vaults.get(wsVaultId)!.members.includes("bob"));
    assert.ok(!(vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId).members.some((m: any) => m.sub === "bob"), "offline approval must not commit locally");
    st.setOffline(false);

    const errCancelled = await alice.askErr("vault.addMember", { vault: wsVaultId, sub: "bob", askAt: firstAskAt });
    assert.equal(errCancelled.code, "join_cancelled");
    assert.ok(!st.vaults.get(wsVaultId)!.members.includes("bob"));
    // Because GET /vault/joins returns signed cancelled tombstones and join_cancelled triggers readJoins, Alice's stale pending row is cleared!
    const aliceWsAfterCancel = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWsAfterCancel.joinRequests, undefined, "cancelled tombstone must clear admin's cached pending request");

    // 6. Bob requests join again; Alice dismisses it; Bob re-requests again with higher monotonic `at`.
    await bob.ask("vault.requestJoin", { vault: wsVaultId });
    await alice.sync();
    const aliceWs2 = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWs2.joinRequests?.length, 1);
    const secondAskAt: number = aliceWs2.joinRequests[0].at;
    assert.ok(secondAskAt > firstAskAt);

    await alice.ask("vault.dismissJoin", { vault: wsVaultId, sub: "bob", upTo: secondAskAt });
    const aliceWsAfterDismiss = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWsAfterDismiss.joinRequests, undefined);

    await bob.sync();
    assert.equal((vaultsView(bob.core.inner, "ws") as any).availableWorkspaceVaults[0].requested, false);

    // Bob re-requests after dismissal -> monotonic at > dismiss floor makes it visible again!
    await bob.ask("vault.requestJoin", { vault: wsVaultId });
    await alice.sync();
    const aliceWs3 = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWs3.joinRequests?.length, 1);
    const thirdAsk = aliceWs3.joinRequests[0];
    assert.ok(thirdAsk.at > secondAskAt);

    // 7. Inject a corrupted/low-order all-zero X25519 BoxCert for Bob's second device AND simulate 409 vault_conflict once:
    //    addMember must isolate the bad cert via trySealWith, retry 409 once, succeed, and wrap key to Bob's good device!
    const badCert = sign({ v: 1 as const, ws: "ws", device: badDev, box: `x25519:${"00".repeat(32)}`, at: 9999 }, TAG.box, badKey);
    st.boxes.set(badDev, badCert);
    await alice.sync();
    st.setForceConflictOnce(true);
    const addedBob = await alice.ask("vault.addMember", {
      vault: wsVaultId,
      sub: "bob",
      askAt: thirdAsk.at,
      askDevice: thirdAsk.device,
      askBox: thirdAsk.box,
    });
    assert.equal(addedBob.added, true);
    assert.equal(addedBob.keyedDevices, 1, "good device wrapped; low-order cert isolated cleanly");

    // 8. Bob syncs -> no longer discoverable, keyed immediately, can decrypt Alice's shared secret!
    await bob.sync();
    const bobViewJoined = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobViewJoined.availableWorkspaceVaults, undefined);
    assert.equal(bobViewJoined.vaults.find((v: any) => v.id === wsVaultId)?.keyed, true);
    const openedByBob = await bob.ask("vault.open", { item: itemId });
    assert.equal(openedByBob.plain.fields.value, "sec_team_42");

    // Already-keyed vault.ask returns { asked: 0 } cleanly (PR #9017 P2 fix).
    const alreadyKeyedAsk = await bob.ask("vault.ask", { vault: wsVaultId });
    assert.equal(alreadyKeyedAsk.asked, 0);

    // 9. Recovery words preserved: Bob calls vault.setup later -> gets 24 recovery words and personal vault, hasRecovery=true!
    const setupBob = await bob.ask("vault.setup", {});
    assert.ok(typeof setupBob.words === "string" && setupBob.words.split(" ").length === 24, "setup after requestJoin must still generate 24 recovery words");
    const bobViewAfterSetup = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobViewAfterSetup.hasRecovery, true);
    assert.ok(bobViewAfterSetup.vaults.some((v: any) => v.scope === "personal"));

    // 10. Proactive invite of uninitialized Carol (0 BoxCerts) -> added=true, keyedDevices=0, member row shows keyed=false.
    const addedCarol = await alice.ask("vault.addMember", { vault: wsVaultId, sub: "carol" });
    assert.equal(addedCarol.added, true);
    assert.equal(addedCarol.keyedDevices, 0);
    const aliceWs4 = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWs4.unjoinedCount, 0);
    const carolRow = aliceWs4.members.find((m: any) => m.sub === "carol");
    assert.equal(carolRow.keyed, false);

    // 11. Offline removeMember refuses to create a local epoch fork!
    st.setOffline(true);
    const offlineErr = await alice.askErr("vault.removeMember", { vault: wsVaultId, sub: "bob" });
    assert.equal(offlineErr.code, "vault_station_offline");
    st.setOffline(false);

    // 12. Online removeMember rotates epoch + 1, re-encrypts item, and vault-gone immediately restores discoverable for Bob!
    const removedBob = await alice.ask("vault.removeMember", { vault: wsVaultId, sub: "bob" });
    assert.equal(removedBob.removed, true);
    assert.equal(removedBob.rekeyed, true);
    assert.equal(removedBob.epoch, 1);
    assert.equal(st.items.get(itemId)!.epoch, 1);

    const latestAfterRemove = st.vaults.get(wsVaultId)!;
    bob.deliverEvent("vault-gone", { id: wsVaultId, vault: latestAfterRemove });
    const bobAfterGone = vaultsView(bob.core.inner, "ws") as any;
    assert.ok(!bobAfterGone.vaults.some((v: any) => v.id === wsVaultId));
    assert.equal(bobAfterGone.availableWorkspaceVaults?.length, 1, "vault-gone seeds discoverable immediately");
    assert.equal(bobAfterGone.availableWorkspaceVaults[0].id, wsVaultId);
    assert.equal(bobAfterGone.availableWorkspaceVaults[0].requested, false, "pre-join ask must NOT resurrect after remove");

    // Verify full sync also keeps requested=false due to station joined_up_to suppression!
    await bob.sync();
    const bobAfterSync = vaultsView(bob.core.inner, "ws") as any;
    assert.equal(bobAfterSync.availableWorkspaceVaults?.length, 1);
    assert.equal(bobAfterSync.availableWorkspaceVaults[0].requested, false);

    // 13. Non-canonical X25519 keys (high bit set and >= 2^255 - 19) are rejected by usableBoxKey & trySealWith!
    const validPub = boxPublic(fill(7));
    assert.equal(usableBoxKey(validPub), true);
    const nonCanon = unhex(validPub.slice(7));
    nonCanon[31]! |= 0x80;
    const highBitPub = `x25519:${hex(nonCanon)}`;
    assert.equal(usableBoxKey(highBitPub), false);
    assert.equal(trySealWith(highBitPub, fill(1), "ctx", fill(2)), null);
    const geP = new Uint8Array(32).fill(0xff);
    geP[31] = 0x7f;
    geP[0] = 0xed;
    assert.equal(usableBoxKey(`x25519:${hex(geP)}`), false);

    // 14. cancelJoin when already a member returns { cancelled: false, alreadyMember: true }.
    const reAddBob = await alice.ask("vault.addMember", { vault: wsVaultId, sub: "bob" });
    assert.equal(reAddBob.added, true);
    const lateCancel = await bob.ask("vault.cancelJoin", { vault: wsVaultId });
    assert.deepEqual(lateCancel, { cancelled: false, alreadyMember: true });
  } finally {
    alice.core.close();
    bob.core.close();
  }
});

test("Stage 2 non-safe-mode: vault-joins-changed refreshes /vault/boxes chains so first join request surfaces immediately", async () => {
  const aliceSeed = fill(211), bobSeed = fill(212);
  const aliceDev = "e1".repeat(32), bobDev = "f2".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed);
  const makePersonalChain = (sub: string, devId: string, key: ReturnType<typeof edKey>): Entry[] => {
    const body = { sub, device: { key: key.id, id: devId, label: `${sub} Mac`, sign_key: key.id } };
    return [lockEntry(next(`person:${sub}`, null, 1000, "genesis", body), key)];
  };
  const aliceChain = makePersonalChain("alice", aliceDev, aliceKey);
  const bobChain = makePersonalChain("bob", bobDev, bobKey);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
  ];
  const chains: Record<string, Entry[]> = { alice: aliceChain };
  const st = joinStation({ roles: { alice: "owner", bob: "member" }, chains });
  const alice = await started(undefined, 0, undefined, (x) => {
    x.host.appKeys = true;
    x.host.store(STORAGE_KEY, [account("alice", "alice@x.com", "", "tok", "r0", Math.floor(x.host.nowMs() / 1000) + 3600)]);
    x.host.secure.set("lock-signer", { value: aliceSeed, user: false });
    x.host.secure.set(PERSONAL_KEY, { value: aliceSeed, user: false });
    x.host.storage.set("personal-signer-id", utf8(aliceKey.id));
    x.host.store(`personal-lock-${hex(utf8("alice"))}`, aliceChain);
    x.cloud.role = "owner";
    x.cloud.also = { locked: false, members: wsMembers };
    stationReplies(x.host, (req) => {
      if (req.url.includes("/v1/me/personal-lock")) return { entries: aliceChain };
      return st.replyFor("alice")(req);
    });
  });
  try {
    alice.core.inner.mesh = () => withoutMesh(aliceDev);
    signerKnown(alice.core.inner, aliceKey.id);
    await alice.host.time.pass(1000);
    alice.core.inner.runner.fork(Effect.ignore(alice.core.inner.adb.personal().refresh("alice")));
    await alice.host.time.pass(200);
    vaultCome(alice.core.inner, "ws");
    const ui = alice.core.connect();
    const askAlice = async (id: number, name: string, params: Record<string, unknown> = {}) => {
      alice.host.takeEmitted();
      call(alice.core, ui, id, name, { workspace: "ws", ...params });
      for (let i = 0; i < 60; i++) {
        await alice.host.time.pass(50);
        for (const [, m] of alice.host.takeEmitted()) {
          const r = m as any;
          if (r.id === id && ("ok" in r || "error" in r)) return r;
        }
      }
      throw new Error(`${name}: no answer`);
    };
    const rSetup = await askAlice(1, "vault.setup");
    assert.equal(rSetup.error, undefined);
    const rCreate = await askAlice(2, "vault.create", { name: "NonSafe Team", scope: "workspace", members: ["alice"] });
    assert.equal(rCreate.error, undefined);
    const wsVaultId = rCreate.ok.id as string;

    // Now Bob opens his personal lock for the first time (station learns bobChain + bobBox + bobJoin) — Alice has NOT synced!
    chains.bob = bobChain;
    const bobPub = boxPublic(fill(42));
    const bobBox: BoxCert = sign({ v: 1 as const, ws: "ws", device: bobDev, box: bobPub, at: 5000 }, TAG.box, bobKey);
    st.boxes.set(bobDev, bobBox);
    const bobJoin: JoinAsk = sign(
      { v: 1 as const, ws: "ws", vault: wsVaultId, sub: "bob", device: bobDev, box: bobPub, state: "pending" as const, at: 5001 },
      TAG.join,
      bobKey,
    );
    st.joins.set(`${wsVaultId}/bob`, { ask: bobJoin, joinedUpTo: -1, dismissUpTo: -1, dismiss: null });

    // Deliver ONLY vault-joins-changed (no full sync!): readJoins must detect unknown applicant chain, fetch /vault/boxes, and surface Bob immediately!
    for (const a of alice.core.inner.stations.also) a.event("ws/st", "vault-joins-changed", { vault: wsVaultId });
    await alice.host.time.pass(600);
    const aliceWs = (vaultsView(alice.core.inner, "ws") as any).vaults.find((v: any) => v.id === wsVaultId);
    assert.equal(aliceWs?.joinRequests?.length, 1, "first non-safe-mode join request must appear immediately on vault-joins-changed");
    assert.equal(aliceWs.joinRequests[0].sub, "bob");
  } finally {
    alice.core.close();
  }
});
