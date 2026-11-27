import assert from "node:assert/strict";
import { createPrivateKey, generateKeyPairSync, sign } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import type { Request } from "../src/api/request.ts";
import type { LockState } from "../../shared/lock.ts";
import { routes } from "../src/api/routes/vault.ts";
import {
  newBoxPair, signedBytes, TAG, usableBoxKey,
  type BoxCert, type JoinAsk, type JoinDismiss, type Vault,
} from "../src/vault/crypto.ts";
import { VaultStore } from "../src/vault/store.ts";

function makeSigner(seedByte: number) {
  const seed = Buffer.alloc(32, seedByte);
  const priv = createPrivateKey({
    key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]),
    format: "der",
    type: "pkcs8",
  });
  const pubRaw = Buffer.from(
    generateKeyPairSync("ed25519", {
      privateKeyEncoding: { format: "der", type: "pkcs8" },
      publicKeyEncoding: { format: "der", type: "spki" },
    }).publicKey,
  );
  void pubRaw;
  const pubHex = Buffer.from(priv.export({ format: "jwk" }).x!, "base64url").toString("hex");
  const keyId = `ed25519:${pubHex}`;
  const deviceId = Buffer.alloc(32, seedByte).toString("hex");
  const box = newBoxPair();
  const doSign = <T extends Record<string, unknown>>(o: T, tag: string) => ({
    ...o,
    sig: { key: keyId, alg: "Ed25519" as const, sig: sign(null, signedBytes(o, tag), priv).toString("hex") },
  });
  return { keyId, deviceId, box, doSign };
}

function rig() {
  const ws = "ws_join_test";
  const admin = makeSigner(1);
  const bob = makeSigner(2);
  const unjoinedAdmin = makeSigner(3);
  const db = new DatabaseSync(":memory:");
  const vaults = new VaultStore(db);
  const state = {
    ws,
    genesis: "",
    head: "",
    seq: 0,
    members: new Map([
      ["alice", { sub: "alice", email: "alice@x.test", role: "owner" as const }],
      ["bob", { sub: "bob", email: "bob@x.test", role: "member" as const }],
      ["carol", { sub: "carol", email: "carol@x.test", role: "admin" as const }],
    ]),
    devices: new Map([
      [admin.deviceId, { id: admin.deviceId, sub: "alice", kind: "app" as const, label: "Alice Mac", own: true, sign_key: admin.keyId, endpoints: [admin.deviceId] }],
      [bob.deviceId, { id: bob.deviceId, sub: "bob", kind: "app" as const, label: "Bob Phone", own: true, sign_key: bob.keyId, endpoints: [bob.deviceId] }],
      [unjoinedAdmin.deviceId, { id: unjoinedAdmin.deviceId, sub: "carol", kind: "app" as const, label: "Carol Mac", own: true, sign_key: unjoinedAdmin.keyId, endpoints: [unjoinedAdmin.deviceId] }],
    ]),
    stations: new Map(),
    passkeys: new Map(),
    signKeys: new Map(),
    persons: new Map(),
    disabled: false,
  } as unknown as LockState;

  const emitted: { event: string; data: unknown; of: string; to: unknown }[] = [];
  const list = routes({
    vaults,
    lock: () => state,
    events: {
      tell: (event: string, data: unknown, of: string, to: unknown) => {
        emitted.push({ event, data, of, to });
      },
    } as never,
  });

  const call = async (method: string, path: string, viewerSub: string, viewerDevice: string, body?: unknown, query: [string, string][] = []) => {
    const route = list.find((r) => r.method === method && r.pattern.test(path))!;
    assert.ok(route, `route ${method} ${path} not found`);
    const role = state.members.get(viewerSub)?.role ?? "member";
    const req: Request = {
      method,
      path,
      query,
      headers: {},
      body: body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body), "utf8"),
      viewer: { sub: viewerSub, workspace: ws, email: `${viewerSub}@x.test`, name: viewerSub, role, device: viewerDevice },
      lang: "en",
    };
    const res = await route.handle(req, []);
    return { status: res.status, body: JSON.parse((res.body as Buffer).toString()) };
  };

  const wsVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZW";
  const adminCert: BoxCert = admin.doSign({ v: 1 as const, ws, device: admin.deviceId, box: admin.box.pub, at: 100 }, TAG.box);
  vaults.putBox(adminCert);
  const wsVault: Vault = admin.doSign(
    {
      v: 1 as const, ws, id: wsVaultId, seq: 0, owner: "alice", name: "Team Vault", scope: "workspace" as const,
      members: ["alice"], epoch: 0, keys: [], at: 100,
    },
    TAG.vault,
  );
  vaults.putVault(wsVault);

  return { ws, db, vaults, state, admin, bob, unjoinedAdmin, wsVaultId, wsVault, emitted, call };
}

test("workspace vault discovery exposes minimal metadata only, blocks pre-existing PUT/latest leaks, and enforces BoxCert + atomic join approval + tombstone convergence", async () => {
  const r = rig();
  try {
    // 1. Bob sees discoverable workspace vault metadata (NO keys/members/items), and cannot see Alice's personal vault.
    const personalId = "v_01HZZZZZZZZZZZZZZZZZZZZZZP";
    const personalVault: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: personalId, seq: 0, owner: "alice", name: "Alice Private", members: ["alice"], epoch: 0, keys: [], at: 100 },
      TAG.vault,
    );
    r.vaults.putVault(personalVault);

    const bobGet = await r.call("GET", "/vault/vaults", "bob", r.bob.deviceId);
    assert.equal(bobGet.status, 200);
    assert.deepEqual(bobGet.body.vaults, []);
    assert.equal(bobGet.body.discoverable.length, 1);
    assert.deepEqual(bobGet.body.discoverable[0], {
      id: r.wsVaultId, ws: r.ws, name: "Team Vault", scope: "workspace", owner: "alice", memberCount: 1, seq: 0, at: 100,
    });
    assert.equal("keys" in bobGet.body.discoverable[0], false);
    assert.equal("members" in bobGet.body.discoverable[0], false);

    // GET /vault/discover dedicated route contract.
    const bobDisc = await r.call("GET", "/vault/discover", "bob", r.bob.deviceId);
    assert.equal(bobDisc.status, 200);
    assert.deepEqual(bobDisc.body.discoverable, bobGet.body.discoverable);
    const aliceDisc = await r.call("GET", "/vault/discover", "alice", r.admin.deviceId);
    assert.equal(aliceDisc.status, 200);
    assert.deepEqual(aliceDisc.body.discoverable, []);
    const aliceGet = await r.call("GET", "/vault/vaults", "alice", r.admin.deviceId);
    assert.equal("discoverable" in aliceGet.body, false, "GET /vault/vaults omits empty discoverable for backwards compatibility");

    // 2. Pre-existing route leaks closed: Bob (knowing wsVaultId) cannot extract `prev` via PUT /vault/vaults or POST /vault/vaults/latest.
    const probeConflict = await r.call("PUT", "/vault/vaults", "bob", r.bob.deviceId, { ...r.wsVault, seq: 99 });
    assert.equal(probeConflict.status, 404);
    assert.equal(probeConflict.body.vault, undefined);

    const probeCopy = await r.call("PUT", "/vault/vaults", "bob", r.bob.deviceId, { ...r.wsVault, seq: 0 }, [["copy", "1"]]);
    assert.equal(probeCopy.status, 404);
    assert.equal(probeCopy.body.vault, undefined);

    const forgedLatest = r.bob.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 0, owner: "bob", name: "Fake", scope: "workspace" as const, members: ["bob"], epoch: 0, keys: [], at: 100 },
      TAG.vault,
    );
    const probeLatest = await r.call("POST", "/vault/vaults/latest", "bob", r.bob.deviceId, { held: [forgedLatest] });
    assert.equal(probeLatest.status, 200);
    assert.deepEqual(probeLatest.body.vaults, [], "ordinary member forged workspace witness must not return real workspace vault");

    // Unjoined admin Carol cannot self-insert via direct PUT, or read via self-forged /latest witness!
    const carolSelfInsert = r.unjoinedAdmin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 1, owner: "carol", name: "Team Vault", scope: "workspace" as const, members: ["alice", "carol"], epoch: 0, keys: [], at: 110 },
      TAG.vault,
    );
    const probeCarol = await r.call("PUT", "/vault/vaults", "carol", r.unjoinedAdmin.deviceId, carolSelfInsert);
    assert.equal(probeCarol.status, 404);
    assert.deepEqual(r.vaults.vault(r.ws, r.wsVaultId)!.members, ["alice"]);
    const carolForgedLatest = r.unjoinedAdmin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 0, owner: "carol", name: "Fake", scope: "workspace" as const, members: ["carol"], epoch: 0, keys: [], at: 100 },
      TAG.vault,
    );
    const probeCarolLatest = await r.call("POST", "/vault/vaults/latest", "carol", r.unjoinedAdmin.deviceId, { held: [carolForgedLatest] });
    assert.equal(probeCarolLatest.status, 200);
    assert.deepEqual(probeCarolLatest.body.vaults, [], "unjoined admin forged witness must not read workspace vault via /latest");

    // Cross-scope witness (personal witness claiming wsVaultId) must be rejected by /latest.
    const crossScopeWitness = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 0, owner: "alice", name: "Fake Personal", members: ["alice", "bob"], epoch: 0, keys: [], at: 100 },
      TAG.vault,
    );
    const probeCrossScope = await r.call("POST", "/vault/vaults/latest", "bob", r.bob.deviceId, { held: [crossScopeWitness] });
    assert.equal(probeCrossScope.status, 200);
    assert.deepEqual(probeCrossScope.body.vaults, [], "personal witness must not return a workspace vault via /latest");

    // Lagging station catchup: if Carol was added at seq 1 elsewhere and signed seq 2 (even after Alice rotated keys
    // or was demoted), a lagging station at seq 0 MUST catch up cleanly via `?copy=1` under `vaultOk`!
    const lagDb = new DatabaseSync(":memory:");
    try {
      const lagVaults = new VaultStore(lagDb);
      lagVaults.putVault(r.wsVault);
      const lagRoutes = routes({ vaults: lagVaults, lock: () => r.state });
      const putRoute = lagRoutes.find((x) => x.method === "PUT" && x.pattern.test("/vault/vaults"))!;
      const carolSeq2: Vault = r.unjoinedAdmin.doSign(
        { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 2, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice", "carol", "bob"], epoch: 0, keys: [], at: 120 },
        TAG.vault,
      );
      const lagRes = await putRoute.handle(
        {
          method: "PUT", path: "/vault/vaults", query: [["copy", "1"]], headers: {},
          body: Buffer.from(JSON.stringify(carolSeq2), "utf8"),
          viewer: { sub: "bob", workspace: r.ws, email: "bob@x.test", name: "bob", role: "member", device: r.bob.deviceId },
          lang: "en",
        },
        [],
      );
      assert.equal(lagRes.status, 200, "lagging station must catch up on ?copy=1 signed by a current workspace admin");
      assert.equal(lagVaults.vault(r.ws, r.wsVaultId)!.seq, 2);
    } finally {
      lagDb.close();
    }

    // Non-canonical X25519 box keys (high bit set or >= 2^255 - 19) are rejected by usableBoxKey, PUT /vault/boxes, and PUT /vault/joins.
    const canonRaw = Buffer.from(r.bob.box.pub.slice(7), "hex");
    const highBitRaw = Buffer.from(canonRaw);
    highBitRaw[31] |= 0x80;
    const highBitPub = `x25519:${highBitRaw.toString("hex")}`;
    assert.equal(usableBoxKey(r.bob.box.pub), true);
    assert.equal(usableBoxKey(highBitPub), false, "X25519 key with high bit set must be rejected");
    const geP = Buffer.alloc(32, 0xff);
    geP[31] = 0x7f;
    geP[0] = 0xed;
    assert.equal(usableBoxKey(`x25519:${geP.toString("hex")}`), false, "X25519 key >= 2^255-19 must be rejected");
    const badBoxCert: BoxCert = r.bob.doSign({ v: 1 as const, ws: r.ws, device: r.bob.deviceId, box: highBitPub, at: 198 }, TAG.box);
    const badBoxPut = await r.call("PUT", "/vault/boxes", "bob", r.bob.deviceId, badBoxCert);
    assert.equal(badBoxPut.status, 400);

    // 3. Dismiss-before-ask tombstone (`body = NULL`, `state = 'none'`) does not throw 500 on GET or PUT.
    const earlyDismiss: JoinDismiss = r.admin.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", upTo: 150, at: 150 },
      TAG.joinDismiss,
    );
    const d0 = await r.call("PUT", "/vault/joins/dismiss", "alice", r.admin.deviceId, earlyDismiss);
    assert.equal(d0.status, 200);
    const j0 = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.equal(j0.status, 200);
    assert.deepEqual(j0.body.joins, []);
    assert.equal(j0.body.dismisses.length, 1);

    // 4. Bob must publish BoxCert before PUT /vault/joins pending is accepted (409 vault_box_missing).
    const bobJoin1: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 200 },
      TAG.join,
    );
    const noBox = await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobJoin1);
    assert.equal(noBox.status, 409);
    assert.equal(noBox.body.code, "vault_box_missing");

    const bobCert: BoxCert = r.bob.doSign({ v: 1 as const, ws: r.ws, device: r.bob.deviceId, box: r.bob.box.pub, at: 199 }, TAG.box);
    r.vaults.putBox(bobCert);
    const okJoin1 = await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobJoin1);
    assert.equal(okJoin1.status, 200);

    // Alice sees Bob's pending join ask; Bob sees his own pending join ask; Carol (not in vault) sees nothing of Bob.
    const aliceJoins = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.deepEqual(aliceJoins.body.joins, [bobJoin1]);
    const bobJoins = await r.call("GET", "/vault/joins", "bob", r.bob.deviceId);
    assert.deepEqual(bobJoins.body.joins, [bobJoin1]);
    const carolJoins = await r.call("GET", "/vault/joins", "carol", r.unjoinedAdmin.deviceId);
    assert.deepEqual(carolJoins.body.joins, []);

    // 5. Bob cancels; GET /vault/joins returns signed cancelled tombstone to Alice, and atomic approveJoin fails with 409 join_cancelled!
    const bobCancel: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "cancelled" as const, at: 201 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobCancel)).status, 200);
    const aliceSeesCancel = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.deepEqual(aliceSeesCancel.body.joins, [bobCancel], "managing admin must receive signed cancelled tombstone to clear stale pending ask");

    const addBobV1: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 1, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice", "bob"], epoch: 0, keys: [], at: 150 },
      TAG.vault,
    );
    // Partial approveJoin params (without device/box/sig) must be rejected with 400 vault_invalid (no fallback!).
    const partialApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobV1, [["approveJoinSub", "bob"], ["approveJoinAt", "200"]]);
    assert.equal(partialApprove.status, 400, "partial approveJoin params without device/box/sig must fail with 400");
    assert.equal(partialApprove.body.code, "vault_invalid");

    const addBobKeyedV1: Vault = r.admin.doSign(
      {
        v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 1, owner: "alice", name: "Team Vault", scope: "workspace" as const,
        members: ["alice", "bob"], epoch: 0, keys: [{ cert: bobCert, wrapped: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }], at: 150,
      },
      TAG.vault,
    );
    const staleApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobKeyedV1, [
      ["approveJoinSub", "bob"], ["approveJoinAt", "200"], ["approveJoinDevice", r.bob.deviceId], ["approveJoinBox", r.bob.box.pub], ["approveJoinSig", bobJoin1.sig.sig],
    ]);
    assert.equal(staleApprove.status, 409);
    assert.equal(staleApprove.body.code, "join_cancelled");

    // 6. Bob re-applies with a faster client clock (at=999999 > vault.at=150); explicit approval must reject missing
    //    keys (400), reject mismatched sig (409 join_cancelled), and succeed with exact 5-param binding + wrapped key!
    const bobJoinFast: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 999999 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobJoinFast)).status, 200);
    const missingKeyApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobV1, [
      ["approveJoinSub", "bob"], ["approveJoinAt", "999999"], ["approveJoinDevice", r.bob.deviceId], ["approveJoinBox", r.bob.box.pub], ["approveJoinSig", bobJoinFast.sig.sig],
    ]);
    assert.equal(missingKeyApprove.status, 400, "explicit device/box approval must require next.keys to wrap that device and box");
    const wrongSigApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobKeyedV1, [
      ["approveJoinSub", "bob"], ["approveJoinAt", "999999"], ["approveJoinDevice", r.bob.deviceId], ["approveJoinBox", r.bob.box.pub], ["approveJoinSig", bobJoin1.sig.sig],
    ]);
    assert.equal(wrongSigApprove.status, 409, "mismatched approveJoinSig must fail with 409 join_cancelled");
    assert.equal(wrongSigApprove.body.code, "join_cancelled");
    const okApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobKeyedV1, [
      ["approveJoinSub", "bob"], ["approveJoinAt", "999999"], ["approveJoinDevice", r.bob.deviceId], ["approveJoinBox", r.bob.box.pub], ["approveJoinSig", bobJoinFast.sig.sig],
    ]);
    assert.equal(okApprove.status, 200);

    // 7. Alice later removes Bob: old pre-join ask (at=999999) MUST NOT resurrect even though vault.at (150) < 999999!
    const removeBobV2: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 2, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice"], epoch: 1, keys: [], at: 160 },
      TAG.vault,
    );
    r.emitted.length = 0;
    assert.equal((await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, removeBobV2)).status, 200);
    // Offline Bob presenting Alice's signed witness (`addBobKeyedV1`) receives the latest vault proving Bob was removed!
    const bobLatestValid = await r.call("POST", "/vault/vaults/latest", "bob", r.bob.deviceId, { held: [addBobKeyedV1] });
    assert.equal(bobLatestValid.status, 200);
    assert.equal(bobLatestValid.body.vaults.length, 1);
    assert.equal(bobLatestValid.body.vaults[0].seq, 2);
    // Verify vault-discover is emitted AFTER vault-gone!
    const goneIdx = r.emitted.findIndex((e) => e.event === "vault-gone");
    const discIdx = r.emitted.findIndex((e) => e.event === "vault-discover");
    assert.ok(goneIdx >= 0 && discIdx > goneIdx, `vault-discover (${discIdx}) must follow vault-gone (${goneIdx})`);
    const afterRemove = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.deepEqual(afterRemove.body.joins, [], "old pre-join ask must never resurrect after member removal");
    const bobAfterRemove = await r.call("GET", "/vault/joins", "bob", r.bob.deviceId);
    assert.deepEqual(bobAfterRemove.body.joins, [], "pre-join ask suppressed by joined_up_to is not returned as active to bob");

    // 8. Demoted admin's dismiss (upTo=2000000) stops suppressing Bob's ask, AND a remaining admin can replace it
    //    even with a LOWER upTo (1000001 < 2000000) — persisted in SQLite, not silently dropped!
    const addCarolV3: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 3, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice", "carol"], epoch: 1, keys: [], at: 170 },
      TAG.vault,
    );
    assert.equal((await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addCarolV3)).status, 200);
    const bobJoin3: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 1000001 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobJoin3)).status, 200);
    const carolDismiss: JoinDismiss = r.unjoinedAdmin.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", upTo: 2000000, at: 2000000 },
      TAG.joinDismiss,
    );
    assert.equal((await r.call("PUT", "/vault/joins/dismiss", "carol", r.unjoinedAdmin.deviceId, carolDismiss)).status, 200);
    assert.deepEqual((await r.call("GET", "/vault/joins", "alice", r.admin.deviceId)).body.joins, []);
    // Demote Carol -> her dismiss is now inactive; Alice sees Bob's ask again AND can replace it at lower upTo=1000001!
    r.state.members.set("carol", { sub: "carol", email: "carol@x.test", role: "member" });
    assert.deepEqual((await r.call("GET", "/vault/joins", "alice", r.admin.deviceId)).body.joins, [bobJoin3]);
    const aliceReDismiss: JoinDismiss = r.admin.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", upTo: 1000001, at: 1000002 },
      TAG.joinDismiss,
    );
    const reDismissRes = await r.call("PUT", "/vault/joins/dismiss", "alice", r.admin.deviceId, aliceReDismiss);
    assert.equal(reDismissRes.status, 200, "re-dismissing after previous admin demotion at lower upTo must persist");
    assert.equal(r.vaults.joinSnapshot(r.ws, r.wsVaultId, "bob")!.dismissUpTo, 1000001);
    assert.deepEqual((await r.call("GET", "/vault/joins", "alice", r.admin.deviceId)).body.joins, []);

    // 8b. 70 newer cancelled rows must NEVER starve an older pending join ask (separate per-state quotas)!
    const bobPendingUnderCancels: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 1000005 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobPendingUnderCancels)).status, 200);
    for (let i = 0; i < 70; i++) {
      const s = makeSigner(50 + i);
      const sub = `canc_${String(i).padStart(3, "0")}`;
      r.state.members.set(sub, { sub, email: `${sub}@x.test`, role: "member" });
      r.state.devices.set(s.deviceId, { id: s.deviceId, sub, kind: "app", label: sub, own: true, sign_key: s.keyId, endpoints: [s.deviceId] } as never);
      const cAsk: JoinAsk = s.doSign(
        { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub, device: s.deviceId, box: s.box.pub, state: "cancelled" as const, at: 2000000 + i },
        TAG.join,
      );
      assert.equal((await r.call("PUT", "/vault/joins", sub, s.deviceId, cAsk)).status, 200);
    }
    const underCancels = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.ok(
      underCancels.body.joins.some((j: JoinAsk) => j.sub === "bob" && j.state === "pending" && j.at === 1000005),
      "70 newer cancelled tombstones must not starve older pending join ask",
    );

    // 9. Discovery ignores 80 personal vaults and returns newest active workspace vaults via partial index (0 TEMP B-TREE).
    for (let i = 0; i < 80; i++) {
      const pid = `v_01HZZZZZZZZZZZZZZZZZZZ${i.toString(36).toUpperCase().padStart(2, "0").replace(/O/g, "8").replace(/I/g, "9").replace(/L/g, "7").replace(/U/g, "6")}`;
      const pv: Vault = r.admin.doSign(
        { v: 1 as const, ws: r.ws, id: pid, seq: 0, owner: "alice", name: `Personal ${i}`, members: ["alice"], epoch: 0, keys: [], at: 100 + i },
        TAG.vault,
      );
      r.vaults.putVault(pv);
    }
    const newerWsId = "v_01JZZZZZZZZZZZZZZZZZZZZZ99";
    const newerWs: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: newerWsId, seq: 0, owner: "alice", name: "Newer Team Vault", scope: "workspace" as const, members: ["alice"], epoch: 0, keys: [], at: 300 },
      TAG.vault,
    );
    r.vaults.putVault(newerWs);
    const bobDiscMany = await r.call("GET", "/vault/discover", "bob", r.bob.deviceId);
    assert.equal(bobDiscMany.status, 200);
    assert.equal(bobDiscMany.body.discoverable[0].id, newerWsId, "newest workspace vault must not be crowded out by 80 personal vaults");

    // 10. Dismiss pagination reaches beyond 64 records via dismissAfterVault/dismissAfterSub.
    for (let i = 0; i < 68; i++) {
      const sub = `user_${String(i).padStart(3, "0")}`;
      const dm: JoinDismiss = r.admin.doSign(
        { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub, upTo: 500 + i, at: 500 + i },
        TAG.joinDismiss,
      );
      assert.equal((await r.call("PUT", "/vault/joins/dismiss", "alice", r.admin.deviceId, dm)).status, 200);
    }
    const page1 = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.equal(page1.body.dismisses.length, 64);
    assert.ok(page1.body.nextDismissCursor, "must return nextDismissCursor when >64 dismisses exist");
    const page2 = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId, undefined, [
      ["dismissAfterVault", page1.body.nextDismissCursor.vault],
      ["dismissAfterSub", page1.body.nextDismissCursor.sub],
    ]);
    assert.ok(page2.body.dismisses.length >= 5, "second page must deliver remaining dismisses past 64");

    // 10b. Scan-budget exhaustion on filtered dismisses still returns a nextCursor so subsequent pages find valid dismisses!
    const scanBudget = r.vaults.joinDismissesForVaults(r.ws, [r.wsVaultId], 64, {
      maxScan: 10,
      accept: () => false,
    });
    assert.equal(scanBudget.dismisses.length, 0);
    assert.ok(scanBudget.nextCursor !== undefined, "exhausting maxScan on filtered rows must still return nextCursor");

    // 10c. Pending scan budget exhaustion across 4 vaults MUST NOT starve cancelled tombstones (independent budgets + cursor)!
    const starvDb = new DatabaseSync(":memory:");
    try {
      const starvStore = new VaultStore(starvDb);
      const vIds = [0, 1, 2, 3].map((n) => `v_01JSTARVE0000000000000000${n}`);
      for (const vid of vIds) {
        const sv: Vault = r.admin.doSign(
          { v: 1 as const, ws: r.ws, id: vid, seq: 0, owner: "alice", name: `V${vid}`, scope: "workspace" as const, members: ["alice"], epoch: 0, keys: [], at: 100 },
          TAG.vault,
        );
        starvStore.putVault(sv);
        const body = JSON.stringify(sv);
        for (let i = 0; i < 128; i++) {
          const pAsk: JoinAsk = r.bob.doSign(
            { v: 1 as const, ws: r.ws, vault: vid, sub: `pend_${i}`, device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 5000 + i },
            TAG.join,
          );
          starvStore.putJoinIf(pAsk, body, null, false);
        }
      }
      // Put 3 valid cancelled tombstones on vault 0.
      const v0Body = JSON.stringify(starvStore.vault(r.ws, vIds[0]!)!);
      for (let i = 0; i < 3; i++) {
        const cAsk: JoinAsk = r.bob.doSign(
          { v: 1 as const, ws: r.ws, vault: vIds[0]!, sub: `canc_ok_${i}`, device: r.bob.deviceId, box: r.bob.box.pub, state: "cancelled" as const, at: 8000 + i },
          TAG.join,
        );
        starvStore.putJoinIf(cAsk, v0Body, null, false);
      }
      const res1 = starvStore.joinsForVaults(r.ws, vIds, 128, {
        perVault: 64,
        perVaultCancelled: 64,
        cancelledLimit: 2,
        perVaultScan: 128,
        maxScan: 512,
        cancelledMaxScan: 512,
        accept: (a) => a.state === "cancelled",
      });
      assert.equal(res1.joins.length, 2, "exhausted pending maxScan (4*128=512) must NEVER starve cancelled tombstones");
      assert.ok(res1.nextCancelledCursor !== undefined, "cancelled pagination must return nextCancelledCursor when more cancelled rows remain");
      const res2 = starvStore.joinsForVaults(r.ws, vIds, 128, {
        perVault: 64,
        perVaultCancelled: 64,
        cancelledLimit: 2,
        perVaultScan: 128,
        maxScan: 512,
        cancelledMaxScan: 512,
        cancelledAfterVault: res1.nextCancelledCursor.vault,
        cancelledAfterAt: res1.nextCancelledCursor.at,
        cancelledAfterSub: res1.nextCancelledCursor.sub,
        accept: (a) => a.state === "cancelled",
      });
      assert.equal(res2.joins.length, 1, "second cancelled page must deliver the remaining 3rd cancelled tombstone");
      assert.equal(res2.nextCancelledCursor, undefined);
    } finally {
      starvDb.close();
    }

    // 11. Query plan checks: 0 TEMP B-TREE across workspace discovery, join cursor seeks, and dismiss partial index.
    const planDisc = r.db.prepare(
      "EXPLAIN QUERY PLAN SELECT id, body FROM vaults WHERE ws = ? AND json_valid(body) AND json_extract(body, '$.scope') = 'workspace' AND json_type(body, '$.deleted') IS NOT 'true' ORDER BY id DESC LIMIT 16",
    ).all(r.ws) as { detail: string }[];
    assert.ok(planDisc.some((p) => p.detail.includes("USING INDEX vaults_workspace_active")), `expected vaults_workspace_active index: ${JSON.stringify(planDisc)}`);
    assert.ok(!planDisc.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort in discovery: ${JSON.stringify(planDisc)}`);

    const planSameAt = r.db.prepare(
      "EXPLAIN QUERY PLAN SELECT at, sub, body, joined_up_to, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_at WHERE ws = ? AND vault = ? AND state = 'pending' AND at = ? AND sub > ? ORDER BY at DESC, sub ASC LIMIT 64",
    ).all(r.ws, r.wsVaultId, 1000, "bob") as { detail: string }[];
    assert.ok(planSameAt.some((p) => p.detail.includes("USING INDEX vault_joins_vault_at") && p.detail.includes("at=?") && p.detail.includes("sub>?")), `expected split same-at index seek: ${JSON.stringify(planSameAt)}`);
    assert.ok(!planSameAt.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort: ${JSON.stringify(planSameAt)}`);

    const planOlder = r.db.prepare(
      "EXPLAIN QUERY PLAN SELECT at, sub, body, joined_up_to, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_at WHERE ws = ? AND vault = ? AND state = 'pending' AND at < ? ORDER BY at DESC, sub ASC LIMIT 64",
    ).all(r.ws, r.wsVaultId, 1000) as { detail: string }[];
    assert.ok(planOlder.some((p) => p.detail.includes("USING INDEX vault_joins_vault_at") && p.detail.includes("at<?")), `expected split older-at index seek: ${JSON.stringify(planOlder)}`);
    assert.ok(!planOlder.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort: ${JSON.stringify(planOlder)}`);

    const planDismiss = r.db.prepare(
      "EXPLAIN QUERY PLAN SELECT sub, dismiss_body FROM vault_joins INDEXED BY vault_joins_vault_dismiss WHERE ws = ? AND vault = ? AND dismiss_body IS NOT NULL AND sub > ? ORDER BY sub ASC LIMIT 64",
    ).all(r.ws, r.wsVaultId, "user_010") as { detail: string }[];
    assert.ok(planDismiss.some((p) => p.detail.includes("USING INDEX vault_joins_vault_dismiss") && p.detail.includes("sub>?")), `expected vault_joins_vault_dismiss partial index seek: ${JSON.stringify(planDismiss)}`);
    assert.ok(!planDismiss.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort: ${JSON.stringify(planDismiss)}`);
  } finally {
    r.db.close();
  }
});
