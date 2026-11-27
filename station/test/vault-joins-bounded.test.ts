import assert from "node:assert/strict";
import { createPrivateKey, generateKeyPairSync, sign } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import type { Request } from "../src/api/request.ts";
import type { LockState } from "../../shared/lock.ts";
import { routes } from "../src/api/routes/vault.ts";
import {
  newBoxPair, signedBytes, TAG,
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

    // Unjoined admin Carol cannot self-insert via direct non-copy PUT /vault/vaults.
    const carolSelfInsert = r.unjoinedAdmin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 1, owner: "carol", name: "Team Vault", scope: "workspace" as const, members: ["alice", "carol"], epoch: 0, keys: [], at: 110 },
      TAG.vault,
    );
    const probeCarol = await r.call("PUT", "/vault/vaults", "carol", r.unjoinedAdmin.deviceId, carolSelfInsert);
    assert.equal(probeCarol.status, 404);

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

    // 5. Bob cancels; atomic approveJoin against stale at=200 is rejected with 409 join_cancelled!
    const bobCancel: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "cancelled" as const, at: 201 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobCancel)).status, 200);

    const addBobV1: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 1, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice", "bob"], epoch: 0, keys: [], at: 150 },
      TAG.vault,
    );
    const staleApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobV1, [["approveJoinSub", "bob"], ["approveJoinAt", "200"]]);
    assert.equal(staleApprove.status, 409);
    assert.equal(staleApprove.body.code, "join_cancelled");

    // 6. Bob re-applies with a faster client clock (at=999999 > vault.at=150); Alice approves atomically -> floor bumped using applicant's clock (999999)!
    const bobJoinFast: JoinAsk = r.bob.doSign(
      { v: 1 as const, ws: r.ws, vault: r.wsVaultId, sub: "bob", device: r.bob.deviceId, box: r.bob.box.pub, state: "pending" as const, at: 999999 },
      TAG.join,
    );
    assert.equal((await r.call("PUT", "/vault/joins", "bob", r.bob.deviceId, bobJoinFast)).status, 200);
    const okApprove = await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, addBobV1, [["approveJoinSub", "bob"], ["approveJoinAt", "999999"]]);
    assert.equal(okApprove.status, 200);

    // 7. Alice later removes Bob: old pre-join ask (at=999999) MUST NOT resurrect even though vault.at (150) < 999999!
    const removeBobV2: Vault = r.admin.doSign(
      { v: 1 as const, ws: r.ws, id: r.wsVaultId, seq: 2, owner: "alice", name: "Team Vault", scope: "workspace" as const, members: ["alice"], epoch: 1, keys: [], at: 160 },
      TAG.vault,
    );
    r.emitted.length = 0;
    assert.equal((await r.call("PUT", "/vault/vaults", "alice", r.admin.deviceId, removeBobV2)).status, 200);
    // Verify vault-discover is emitted AFTER vault-gone!
    const goneIdx = r.emitted.findIndex((e) => e.event === "vault-gone");
    const discIdx = r.emitted.findIndex((e) => e.event === "vault-discover");
    assert.ok(goneIdx >= 0 && discIdx > goneIdx, `vault-discover (${discIdx}) must follow vault-gone (${goneIdx})`);
    const afterRemove = await r.call("GET", "/vault/joins", "alice", r.admin.deviceId);
    assert.deepEqual(afterRemove.body.joins, [], "old pre-join ask must never resurrect after member removal");

    // 8. Query plan check for vault_joins_vault_at index (0 TEMP B-TREE).
    const plan = r.db.prepare(
      "EXPLAIN QUERY PLAN SELECT at, sub, body, dismiss_up_to FROM vault_joins WHERE ws = ? AND vault = ? AND state = 'pending' ORDER BY at DESC, sub ASC LIMIT 64",
    ).all(r.ws, r.wsVaultId) as { detail: string }[];
    assert.ok(plan.some((p) => p.detail.includes("USING INDEX vault_joins_vault_at")), `expected vault_joins_vault_at index: ${JSON.stringify(plan)}`);
    assert.ok(!plan.some((p) => p.detail.includes("TEMP B-TREE")), `unexpected temp sort: ${JSON.stringify(plan)}`);
  } finally {
    r.db.close();
  }
});
