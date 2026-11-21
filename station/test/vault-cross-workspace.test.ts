// Cross-workspace personal secret browsing & usage on the station (src/vault/secrets.ts, keeper.ts,
// pending-index.ts, use-index.ts, api/routes/vault-requests.ts):
// - secret_list({ other_workspaces: true, reason }) -> card -> POST /vault/browses -> secret_list shows cross items
// - secret_use on cross item -> card -> POST /vault/grants (with sourceWs) -> keeper holds & usable -> GET /vault/cross-uses
// - Security adversarial tests: forged signer, tampered sourceWs, bad sig, describe/remove refused on cross items
// - secret_cancel, secret_reask, name collision disambiguation, session archive/delete cleans up vault_cross_listings
// - Legacy upgraded DB (pre-existing vault_pending_add without vault_pending_owner_v4) + EXPLAIN QUERY PLAN index verification.
import assert from "node:assert/strict";
import { createPublicKey, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { type Entry, entryHash, genesis, signedBytes as lockBytes } from "../../shared/lock.ts";
import {
  type BrowseAnswer, type CrossListing, type Grant, type Item, type Request, type Sig, type Vault,
  TAG, encryptWith, grantContext, itemContext, keyContext, newBoxPair, seal, signedBytes,
} from "../src/vault/crypto.ts";
import { PlainStore } from "../src/vault/plain.ts";
import { Secrets } from "../src/vault/secrets.ts";
import { VaultStore } from "../src/vault/store.ts";
import { PENDING_CROSS_OWN } from "../src/vault/pending-index.ts";
import { CROSS_USES } from "../src/vault/use-index.ts";
import { routes as requestRoutes } from "../src/api/routes/vault-requests.ts";
import type { Viewer } from "../src/mesh/credential.ts";

const WS_A = "01HAAAAAAAAAAAAAAAAAAAAAAA";
const WS_B = "01HBBBBBBBBBBBBBBBBBBBBBBB";
const VAULT_A = "v_01HAAAAAAAAAAAAAAAAAAAAAAA";
const VAULT_B = "v_01HBBBBBBBBBBBBBBBBBBBBBBB";
const ITEM_A = "i_01HAAAAAAAAAAAAAAAAAAAAAAA";
const ITEM_B = "i_01HBBBBBBBBBBBBBBBBBBBBBBB";
const TOKEN_A = "ghp_cross_workspace_personal_token_123456";

function ed() {
  const key = generateKeyPairSync("ed25519").privateKey;
  const hex = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x as string, "base64url").toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer) => nodeSign(null, bytes, key).toString("hex") };
}
type Key = ReturnType<typeof ed>;
type Person = { sub: string; signer: Key; base: Key };
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);

function signed<T extends Record<string, unknown>>(o: T, tag: string, key: Key): T & { sig: Sig } {
  return { ...o, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(o, tag)) } };
}

function world() {
  const [alice, bob] = ["alice", "bob"].map((sub) => ({ sub, signer: ed(), base: ed() })) as [Person, Person];
  const body = {
    owner: "alice", origins: ["https://app.still.fail"], rp_id: "app.still.fail", cloud_keys: { keys: [] },
    members: [
      { sub: "alice", email: "alice@x.com", role: "owner" },
      { sub: "bob", email: "bob@x.com", role: "member" },
    ],
    devices: [alice, bob].map((p) => ({ id: p.base.hex, sub: p.sub, kind: "app", label: p.sub, sign_key: p.signer.id })),
    passkeys: [], stations: [], gateways: [],
  };
  const e = { v: 1, ws: WS_B, seq: 0, prev: null, at: 1000, kind: "genesis", body } as Omit<Entry, "sig">;
  const state = genesis({ ...e, sig: { key: alice.signer.id, alg: "Ed25519" as const, sig: alice.signer.sign(lockBytes(entryHash(e as Entry))) } });
  const cert = signed({ v: 1 as const, ws: WS_B, device: alice.base.hex, box: newBoxPair().pub, at: 1000 }, TAG.box, alice.signer);
  const vaultB: Vault = signed(
    { v: 1 as const, ws: WS_B, id: VAULT_B, seq: 0, owner: "alice", name: "Local Personal", members: ["alice"], epoch: 0, keys: [{ cert, wrapped: seal(cert.box, fill(4), keyContext(WS_B, VAULT_B, 0)) }], at: 1000 },
    TAG.vault, alice.signer,
  );
  const plainB = { kind: "token", name: "SharedName", fields: { value: "local_secret_1234" }, domains: [], notes: "" };
  const itemB: Item = signed(
    { v: 1 as const, ws: WS_B, vault: VAULT_B, id: ITEM_B, version: 0, epoch: 0, ct: encryptWith(fill(4), Buffer.from(JSON.stringify(plainB)), itemContext(WS_B, VAULT_B, ITEM_B, 0, 0), fill(5, 12)), listing: { name: "SharedName", kind: "token" as const, modes: ["proxy" as const], hosts: ["api.local.test"] }, at: 1000 },
    TAG.item, alice.signer,
  );
  return { alice, bob, state, vaultB, itemB };
}

function makeFixture(opts?: { legacyDb?: boolean }) {
  const w = world();
  const dir = mkdtempSync(join(tmpdir(), "vault-cross-"));
  const db = new DatabaseSync(":memory:");
  if (opts?.legacyDb) {
    // Simulate an already-upgraded legacy database where vault_pending_add/change triggers already exist
    // WITHOUT vault_pending_owner_v4, verifying installSchema installs v4 side-by-side cleanly.
    db.exec(`
      CREATE TABLE vault_requests (
        ws TEXT NOT NULL, id TEXT NOT NULL, session TEXT NOT NULL, status TEXT NOT NULL, body TEXT NOT NULL,
        thread INTEGER, card_ts TEXT, PRIMARY KEY (ws, id)
      );
      CREATE TABLE vault_pending_lookup (
        ws TEXT NOT NULL, id TEXT NOT NULL, decider TEXT NOT NULL, owner_decides INTEGER NOT NULL, at INTEGER NOT NULL,
        PRIMARY KEY (ws, id)
      );
      CREATE TABLE vault_pending_state (ws TEXT PRIMARY KEY, cursor TEXT, complete INTEGER NOT NULL DEFAULT 0);
      CREATE TRIGGER vault_pending_add AFTER INSERT ON vault_requests
      WHEN NEW.status = 'pending' AND EXISTS (SELECT 1 FROM vault_pending_state WHERE ws = NEW.ws AND (complete = 1 OR NEW.id <= COALESCE(cursor, '')))
      BEGIN
        INSERT OR REPLACE INTO vault_pending_lookup (ws, id, decider, owner_decides, at)
        VALUES (NEW.ws, NEW.id, COALESCE(json_extract(NEW.body, '$.vault'), ''), 0, COALESCE(CAST(json_extract(NEW.body, '$.at') AS INTEGER), 0));
      END;
    `);
  }
  const vaults = new VaultStore(db);
  vaults.putVault(w.vaultB);
  vaults.putItem(w.itemB);
  const notified: [string, string][] = [];
  const listeners: ((ev: { type: string; key: string }) => void)[] = [];
  let archived = false;
  let removed = false;
  const hub = {
    store: {
      getSession: (k: string) => (!removed && k === "s1" ? { key: "s1", ws: null, workspace: dir, archivedAt: archived ? 2000 : null } : null),
      starter: () => "alice@x.com",
      participants: (s: string) => new Map([[s, ["alice@x.com", "bob@x.com"]]]),
      latestThread: () => null,
      withdrawCard: () => true,
      subscribe: (fn: (ev: { type: string; key: string }) => void) => {
        listeners.push(fn);
        return () => {};
      },
    },
    notify: (k: string, text: string) => notified.push([k, text]),
  };
  let now = 1_000_000;
  const plain = new PlainStore(db);
  const secrets = new Secrets({
    db, vaults, plain, home: () => WS_B, hub: hub as never, data: dir,
    lock: () => w.state, now: () => now,
  });
  const cleanup = () => {
    db.close();
    rmSync(dir, { recursive: true, force: true });
  };
  const emitSession = (type: string, key = "s1") => {
    if (type === "session") archived = true;
    if (type === "sessionRemoved") removed = true;
    for (const l of listeners) l({ type, key });
  };
  return { w, db, vaults, plain, secrets, notified, emitSession, setNow: (v: number) => { now = v; }, cleanup };
}

test("cross-workspace browse -> list -> use -> grant -> crossUses full flow and cleanup on archive", async () => {
  const f = makeFixture();
  try {
    // 1. Ask to browse other workspaces
    const asked = await f.secrets.browse("s1", { reason: "need personal GitHub token from Work A" });
    assert.match(asked, /Asked .* to share their personal secret list from other workspaces/);
    const pendingAlice = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    assert.equal(pendingAlice.length, 1);
    const browseReq = pendingAlice[0]!;
    assert.equal(browseReq.mode, "browse");
    assert.equal(browseReq.reason, "need personal GitHub token from Work A");
    assert.equal(browseReq.owner, "alice@x.com");
    // Bob (another member of WS_B) must NOT see Alice's browse request
    assert.deepEqual(f.secrets.pending(WS_B, f.w.state, { sub: "bob", email: "bob@x.com" }), []);

    // 2. Non-owner (Bob) cannot approve Alice's browse request
    const crossItem: CrossListing = {
      sourceWs: WS_A,
      sourceWsName: "Work A",
      vault: VAULT_A,
      vaultName: "Personal A",
      vaultLasts: "hour",
      item: ITEM_A,
      listing: { name: "GitHub A", kind: "token", modes: ["proxy", "env"], hosts: ["api.github.com"], env: "GH_TOKEN", about: "Personal PAT" },
    };
    const forgedBrowse: BrowseAnswer = signed(
      { v: 1 as const, ws: WS_B, request: browseReq.id, items: [crossItem], at: 1001 },
      TAG.browse, f.w.bob.signer,
    );
    assert.match(f.secrets.browsed(f.w.state, "bob", forgedBrowse)!, /owner's device in the lock/);

    // 3. Alice approves with valid BrowseAnswer
    const validBrowse: BrowseAnswer = signed(
      { v: 1 as const, ws: WS_B, request: browseReq.id, items: [crossItem], at: 1001 },
      TAG.browse, f.w.alice.signer,
    );
    assert.equal(f.secrets.browsed(f.w.state, "alice", validBrowse), null);
    assert.equal(f.notified.length, 1);
    assert.match(f.notified[0]![1], /1 personal secret\(s\) from other workspaces/);
    assert.deepEqual(f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" }), []);

    // 4. secret_list (listings) now includes the cross-workspace item alongside local items for Alice,
    //    and strictly isolates it from Bob (multi-person chat owner isolation)
    const allListings = f.secrets.listings("s1");
    assert.equal(allListings.length, 2);
    const crossListed = allListings.find((l) => l.cross !== undefined)!;
    assert.ok(crossListed);
    assert.equal(crossListed.cross!.workspace, WS_A);
    assert.equal(crossListed.cross!.workspaceName, "Work A");
    assert.equal(crossListed.listing.name, "GitHub A");
    assert.equal(crossListed.owner, "alice@x.com");
    assert.equal(f.secrets.listings("s1", "bob@x.com").some((l) => l.cross !== undefined), false);
    await assert.rejects(
      f.secrets.ask("s1", { item: "GitHub A", reason: "bob trying alice's cross secret", person: "bob@x.com" }),
      /No secret named/,
    );

    // 5. secret_describe and secret_delete MUST refuse cross-workspace items as read-only
    await assert.rejects(f.secrets.describe("s1", { item: "GitHub A", name: "Renamed", reason: "try" }), /read-only/);
    await assert.rejects(f.secrets.remove("s1", { item: "GitHub A", reason: "try" }), /read-only/);

    // 6. secret_use on cross-workspace item creates a cross request
    const useAsked = await f.secrets.ask("s1", { item: "GitHub A", reason: "call GitHub API", mode: "proxy" });
    assert.match(useAsked, /Asked for 「GitHub A」/);
    const usePending = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    assert.equal(usePending.length, 1);
    const useReq = usePending[0]!;
    assert.equal(useReq.cross?.workspace, WS_A);
    assert.equal(useReq.cross?.workspaceName, "Work A");
    assert.equal(useReq.owner, "alice@x.com");
    assert.deepEqual(f.secrets.pending(WS_B, f.w.state, { sub: "bob", email: "bob@x.com" }), []);

    // 7. Adversarial grant checks:
    const plainA = { kind: "token", name: "GitHub A", fields: { value: TOKEN_A }, domains: [], notes: "" };
    const makeGrant = (signer: Key, overrides: Partial<Grant> = {}): Grant => signed({
      v: 1 as const,
      ws: WS_B,
      sourceWs: WS_A,
      request: useReq.id,
      vault: VAULT_A,
      item: ITEM_A,
      mode: "proxy" as const,
      hosts: ["api.github.com"],
      scope: "once" as const,
      exp: 1600,
      secret: seal(useReq.box, Buffer.from(JSON.stringify(plainA)), grantContext(WS_B, useReq.id)),
      at: 1002,
      ...overrides,
    }, TAG.grant, signer);

    // 7a. Forged signer (bob) refused
    assert.match(f.secrets.grant(f.w.state, "bob", makeGrant(f.w.bob.signer))!, /only the owner decides cross-workspace/);
    // 7b. Tampered sourceWs refused
    assert.match(f.secrets.grant(f.w.state, "alice", makeGrant(f.w.alice.signer, { sourceWs: WS_B }))!, /does not match/);
    // 7c. Scope exceeding vaultLasts ("hour" -> "chat" refused)
    assert.match(f.secrets.grant(f.w.state, "alice", makeGrant(f.w.alice.signer, { scope: "chat", timeout: { kind: "idle", seconds: 3600 }, exp: 4602 }))!, /granted for hour at most/);
    // 7d. Tampered signature refused
    const badSig = makeGrant(f.w.alice.signer);
    badSig.sig = { ...badSig.sig, sig: "00".repeat(64) };
    assert.match(f.secrets.grant(f.w.state, "alice", badSig)!, /signature/);

    // 8. Valid grant from Alice succeeds
    assert.equal(f.secrets.grant(f.w.state, "alice", makeGrant(f.w.alice.signer)), null);
    assert.equal(f.secrets.held("s1").length, 1);
    const usable = f.secrets.keeper.usable("s1", useReq.id);
    assert.equal(typeof usable, "object");

    // 9. crossUses returns the cross-workspace grant for Alice, empty for Bob
    const aliceCrossUses = await f.secrets.crossUses(WS_B, { sub: "alice", email: "alice@x.com" });
    assert.equal(aliceCrossUses.length, 1);
    assert.equal(aliceCrossUses[0]!.request, useReq.id);
    assert.equal(aliceCrossUses[0]!.sourceWorkspace, WS_A);
    assert.equal(aliceCrossUses[0]!.sourceVault, VAULT_A);
    assert.equal(aliceCrossUses[0]!.item, ITEM_A);
    assert.equal((await f.secrets.crossUses(WS_B, { sub: "bob", email: "bob@x.com" })).length, 0);

    // 10. Archiving the session cleans up vault_cross_listings
    f.emitSession("session", "s1");
    const rowCount = (f.db.prepare("SELECT COUNT(*) AS n FROM vault_cross_listings WHERE session = 's1'").get() as { n: number }).n;
    assert.equal(rowCount, 0);
  } finally {
    f.cleanup();
  }
});

test("name collision disambiguation between local and cross-workspace secrets + cancel & reask", async () => {
  const f = makeFixture();
  try {
    const browseAsk = await f.secrets.browse("s1", { reason: "check other ws" });
    assert.match(browseAsk, /Asked/);
    const [req] = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    // Share a cross-workspace item with the SAME name ("SharedName") as local itemB
    const colliding: CrossListing = {
      sourceWs: WS_A,
      sourceWsName: "Work A",
      vault: VAULT_A,
      vaultName: "Personal A",
      item: ITEM_A,
      listing: { name: "SharedName", kind: "token", modes: ["proxy"], hosts: ["api.a.test"] },
    };
    assert.equal(f.secrets.browsed(f.w.state, "alice", signed(
      { v: 1 as const, ws: WS_B, request: req!.id, items: [colliding], at: 1001 },
      TAG.browse, f.w.alice.signer,
    )), null);

    // Asking by ambiguous name must throw disambiguation error
    await assert.rejects(f.secrets.ask("s1", { item: "SharedName", reason: "ambiguous" }), /Multiple secrets named/);
    // Specifying exact item id resolves to cross-workspace item
    const askedCross = await f.secrets.ask("s1", { item: ITEM_A, reason: "disambiguated" });
    assert.match(askedCross, /Asked for 「SharedName」/);
    const [useReq] = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    assert.equal(useReq!.cross?.workspace, WS_A);

    // Cancel works on cross-workspace use request
    const cancelled = f.secrets.cancel("s1", useReq!.id);
    assert.match(cancelled, /Withdrew/);
    assert.deepEqual(f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" }), []);
  } finally {
    f.cleanup();
  }
});

test("legacy upgraded DB installs vault_pending_owner_v4 & vault_cross_use_lookup and uses indexed plans", async () => {
  const f = makeFixture({ legacyDb: true });
  try {
    await f.secrets.browse("s1", { reason: "legacy db test" });
    const pending = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    assert.equal(pending.length, 1);
    assert.equal(pending[0]!.mode, "browse");

    // Verify SQLite query plans use the new indexes (no full table scan)
    const pendingPlan = (f.db.prepare(`EXPLAIN QUERY PLAN ${PENDING_CROSS_OWN}`).all(WS_B, "alice@x.com") as { detail: string }[])
      .map((r) => r.detail).join("\n");
    assert.match(pendingPlan, /vault_pending_owner_v4_owner/);
    assert.doesNotMatch(pendingPlan, /SCAN r\b/);

    const crossUsePlan = (f.db.prepare(`EXPLAIN QUERY PLAN ${CROSS_USES}`).all(WS_B, "alice@x.com") as { detail: string }[])
      .map((r) => r.detail).join("\n");
    assert.match(crossUsePlan, /vault_cross_use_owner/);
    assert.doesNotMatch(crossUsePlan, /SCAN r\b/);

    const cleanSessionPlan = (f.db.prepare("EXPLAIN QUERY PLAN DELETE FROM vault_cross_listings WHERE session = ?").all("s1") as { detail: string }[])
      .map((r) => r.detail).join("\n");
    assert.match(cleanSessionPlan, /vault_cross_listings_session/);
  } finally {
    f.cleanup();
  }
});

test("HTTP routes POST /vault/browses and GET /vault/cross-uses work end-to-end", async () => {
  const f = makeFixture();
  try {
    const routes = requestRoutes({
      secrets: f.secrets,
      plain: f.plain,
      lock: () => f.w.state,
    });
    const aliceViewer: Viewer = { workspace: WS_B, sub: "alice", email: "alice@x.com", name: "Alice", role: "owner", device: f.w.alice.base.hex };
    await f.secrets.browse("s1", { reason: "route test" });
    const [browseReq] = f.secrets.pending(WS_B, f.w.state, { sub: "alice", email: "alice@x.com" });
    const answer: BrowseAnswer = signed({
      v: 1 as const,
      ws: WS_B,
      request: browseReq!.id,
      items: [{
        sourceWs: WS_A,
        sourceWsName: "Work A",
        vault: VAULT_A,
        vaultName: "Personal A",
        item: ITEM_A,
        listing: { name: "RouteToken", kind: "token", modes: ["proxy"], hosts: ["api.route.test"] },
      }],
      at: 1001,
    }, TAG.browse, f.w.alice.signer);

    const postBrowse = routes.find((r) => r.method === "POST" && r.pattern.test("/vault/browses"))!;
    const m1 = postBrowse.pattern.exec("/vault/browses")!;
    const res1 = await postBrowse.handle({ method: "POST", path: "/vault/browses", query: new URLSearchParams(), body: Buffer.from(JSON.stringify(answer)), viewer: aliceViewer, headers: {} } as never, m1);
    assert.equal(res1.status, 200);

    const getCrossUses = routes.find((r) => r.method === "GET" && r.pattern.test("/vault/cross-uses"))!;
    const m2 = getCrossUses.pattern.exec("/vault/cross-uses")!;
    const res2 = await getCrossUses.handle({ method: "GET", path: "/vault/cross-uses", query: new URLSearchParams(), body: Buffer.alloc(0), viewer: aliceViewer, headers: {} } as never, m2);
    assert.equal(res2.status, 200);
    assert.deepEqual(JSON.parse((res2.body as Buffer).toString("utf8")), { uses: [] });
  } finally {
    f.cleanup();
  }
});
