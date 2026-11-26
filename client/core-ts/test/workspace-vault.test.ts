// Shared workspace vaults (PR B: client/core-ts): creation permissions, non-safe-mode teammate chain folding & role
// merging, member management (add / remove + rekey), admin collaboration & owner takeover, pairing handover of both
// personal and workspace vaults, shared secret_save / explicit target vault approval, and personal-only isolation.
import assert from "node:assert/strict";
import { test } from "node:test";
import { ed25519 } from "@noble/curves/ed25519.js";
import { Effect } from "effect";
import { STORAGE_KEY } from "../src/accounts.ts";
import { CoreError } from "../src/error.ts";
import { type Entry, Signer, entryHash, next } from "../src/lock.ts";
import { PERSONAL_KEY, crypto as personCrypto } from "../src/personal-lock.ts";
import type { HttpRequest } from "../src/host.ts";
import { hex, utf8 } from "../src/util.ts";
import {
  type BoxCert, type Item, type Request, type Vault, TAG, boxPublic, decrypt, itemContext, keyContext, openSeal,
  rulesCrypto, saveContext, sealWith, sign, signedOk,
} from "../src/vault/crypto.ts";
import {
  BOX_KEY, askAnswers, handoverForApproved, needsBoxForHandover, pairBoxCerts, takeHanded, vaultCome, vaultsView,
} from "../src/views/vault.ts";
import { signerKnown } from "../src/views/lock.ts";
import { account, call, subscribe } from "./helpers.ts";
import { withoutMesh } from "./lock-rig.ts";
import { base, started, stationReplies, status } from "./station-fixture.ts";
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

/// Builds a valid 1-entry personal lock chain for `sub` with one app device (`devId`, `signKey`).
function makePersonalChain(sub: string, devId: string, personalSeed: Uint8Array, signKeyId: string, at = 1000): Entry[] {
  const pk = edKey(personalSeed);
  const body = { sub, device: { key: pk.id, id: devId, label: `${sub}-dev`, sign_key: signKeyId } };
  const e = next(`person:${sub}`, null, at, "genesis", body);
  return [lockEntry(e, pk)];
}

/// Builds a valid workspace lock genesis with given members and app devices.
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

/// Shared multi-member fake station supporting both safe mode and non-safe mode (`GET /vault/boxes` returning
/// `chains` + `roles`), with full rules validation on `PUT /vault/vaults` and `PUT /vault/items`.
function sharedStation(opts: {
  ws?: string;
  safeMode: boolean;
  roles: Record<string, string>;
  chains?: Record<string, Entry[]>;
  lockEntries?: Entry[];
  rejectUnknownMembers?: boolean;
}) {
  const ws = opts.ws ?? "ws";
  const vaults = new Map<string, Vault>();
  const items = new Map<string, Item>();
  const boxes = new Map<string, BoxCert>();
  const requests: Request[] = [];
  const plain = new Map<string, any>();
  const saves: unknown[] = [];

  const replyFor = (viewerSub: string) => (req: HttpRequest): unknown => {
    const path = req.url.replace("https://stillfail.test/admin/api", "");
    if (!path.startsWith("/vault/")) return undefined;
    const body = req.body && req.body.length > 0 ? JSON.parse(new TextDecoder().decode(req.body)) : null;
    const [route, query] = path.split("?");
    const k = `${req.method} ${route}`;
    const shown = ({ fields: _, ...rest }: any) => rest;
    switch (k) {
      case "GET /vault/plain":
        return { items: [...plain.values()].map(shown), locked: opts.safeMode };
      case "GET /vault/plain/item":
        return { item: plain.get(new URLSearchParams(query).get("id") ?? "") };
      case "PUT /vault/plain": {
        plain.set(body.id, { ...body, owner: `${viewerSub}@x.com` });
        return { item: shown(plain.get(body.id)) };
      }
      case "GET /vault/uses":
        return { uses: [] };
      case "GET /vault/requests":
        return { requests: requests.filter((r) => r.status === "pending") };
      case "GET /vault/vaults":
        return { vaults: [...vaults.values()].filter((v) => v.members.includes(viewerSub)) };
      case "POST /vault/vaults/latest":
        return { vaults: (body.held as Vault[]).map((h) => vaults.get(h.id)).filter((v): v is Vault => v !== undefined) };
      case "PUT /vault/vaults": {
        const prev = vaults.get(body.id);
        const copy = query === "copy=1";
        if (copy && prev && body.seq <= prev.seq && !(body.seq === prev.seq && rules.vault_supersedes_js(body, prev))) return { vault: prev };
        if (!copy && body.seq !== (prev ? prev.seq + 1 : 0)) return status(409, { error: "seq", code: "vault_conflict", vault: prev ?? null });
        if (!signedOk(body, TAG.vault)) return status(400, { error: "signature", code: "vault_invalid" });
        if (opts.rejectUnknownMembers) {
          const known = new Set([...Object.keys(opts.roles), ...Object.keys(opts.chains ?? {})]);
          for (const m of body.members ?? []) {
            if (!known.has(m)) return status(400, { error: `member ${m} is not in the lock`, code: "vault_invalid" });
          }
        }
        for (const key of body.keys ?? []) {
          if (!signedOk(key.cert, TAG.box) || "sub" in key.cert || "own" in key.cert) return status(400, { error: "bad cert", code: "vault_invalid" });
        }
        vaults.set(body.id, body);
        return { vault: body };
      }
      case "GET /vault/items": {
        const of = new URLSearchParams(query).get("vault");
        const allowed = new Set([...vaults.values()].filter((v) => v.members.includes(viewerSub) && (!of || v.id === of)).map((v) => v.id));
        return { items: [...items.values()].filter((i) => allowed.has(i.vault)) };
      }
      case "PUT /vault/items": {
        const prev = items.get(body.id);
        const copy = query === "copy=1";
        if (!vaults.has(body.vault)) return status(404, { error: "no vault", code: "vault_unknown" });
        if (copy && prev && body.version <= prev.version && !(body.version === prev.version && rules.item_supersedes_js(body, prev))) return { item: prev };
        if (!copy && body.version !== (prev ? prev.version + 1 : 0)) return status(409, { error: "version", code: "vault_conflict", item: prev ?? null });
        if (!signedOk(body, TAG.item)) return status(400, { error: "signature", code: "vault_invalid" });
        items.set(body.id, body);
        return { item: body };
      }
      case "GET /vault/boxes":
        return opts.safeMode
          ? { boxes: [...boxes.values()] }
          : { boxes: [...boxes.values()], chains: { ...(opts.chains ?? {}) }, roles: { ...opts.roles } };
      case "PUT /vault/boxes":
        if (!signedOk(body, TAG.box)) return status(400, { error: "signature", code: "vault_invalid" });
        boxes.set(body.device, body);
        return { box: body };
      case "POST /vault/saves": {
        const r = requests.find((q) => q.id === body.request);
        if (!r || !items.has(r.item) || items.get(r.item)!.vault !== body.vault) return status(409, { error: "not here", code: "vault_refused" });
        saves.push(body);
        r.status = "granted";
        return { ok: true };
      }
      default:
        return undefined;
    }
  };

  return { ws, vaults, items, boxes, requests, plain, saves, replyFor };
}

let memberDeviceSeq = 0;

/// Boots one member's device core connected to `st`.
async function makeMemberDevice(opts: {
  sub: string;
  email: string;
  devId: string;
  signerSeed: Uint8Array;
  personalSeed?: Uint8Array;
  st: ReturnType<typeof sharedStation>;
  wsMembers: { sub: string; email: string; name: string; role: string }[];
  safeMode: boolean;
  lockEntries?: Entry[];
  personalChain?: Entry[];
}) {
  const signer = edKey(opts.signerSeed);
  const myRole = opts.wsMembers.find((m) => m.sub === opts.sub)?.role ?? "member";
  const s = await started(undefined, 0, undefined, (x) => {
    x.host.appKeys = true;
    x.host.store(STORAGE_KEY, [account(opts.sub, opts.email, "", "tok", "r0", Math.floor(x.host.nowMs() / 1000) + 3600)]);
    x.host.secure.set("lock-signer", { value: opts.signerSeed, user: false });
    if (opts.personalSeed) {
      x.host.secure.set(PERSONAL_KEY, { value: opts.personalSeed, user: false });
      x.host.storage.set("personal-signer-id", utf8(edKey(opts.personalSeed).id));
    }
    if (!opts.safeMode && opts.personalChain && opts.personalChain.length > 0) {
      x.host.store(`personal-lock-${hex(utf8(opts.sub))}`, opts.personalChain);
    }
    x.cloud.role = myRole;
    x.cloud.also = { locked: opts.safeMode, members: opts.wsMembers };
    stationReplies(x.host, (req) => {
      if (req.url.includes("/v1/me/personal-lock")) {
        return { entries: opts.personalChain ?? [] };
      }
      return opts.st.replyFor(opts.sub)(req);
    });
  });
  s.core.inner.mesh = () => withoutMesh(opts.devId);
  signerKnown(s.core.inner, signer.id);
  // Give each simulated device a distinct clock offset so deterministic FakeHost ULIDs never collide across members.
  await s.host.time.pass(1000 * (++memberDeviceSeq));
  if (opts.safeMode && opts.lockEntries && opts.lockEntries.length > 0) {
    const head = opts.lockEntries[opts.lockEntries.length - 1]!;
    s.core.inner.data.put("lock", "ws", {
      entries: opts.lockEntries,
      head: { seq: head.seq, hash: entryHash(head), genesis: entryHash(opts.lockEntries[0]!) },
    });
  } else if (opts.personalChain && opts.personalChain.length > 0) {
    s.core.inner.runner.fork(Effect.ignore(s.core.inner.adb.personal().refresh(opts.sub)));
    await s.host.time.pass(200);
  }
  vaultCome(s.core.inner, "ws");
  const ui = s.core.connect();
  let nextId = 100;
  let vaultsSubId: number | null = null;
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
  return { ...s, sub: opts.sub, devId: opts.devId, signer, ask, askErr, sync };
}

test("workspace vault creation: admin succeeds in safe mode & non-safe mode, member is rejected, duplicate is rejected", async () => {
  for (const safeMode of [true, false]) {
    const aliceSeed = fill(11), bobSeed = fill(12), alicePSeed = fill(21), bobPSeed = fill(22);
    const aliceDev = "a1".repeat(32), bobDev = "b1".repeat(32);
    const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed);
    const wsMembers = [
      { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
      { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
    ];
    const aliceChain = makePersonalChain("alice", aliceDev, alicePSeed, aliceKey.id);
    const bobChain = makePersonalChain("bob", bobDev, bobPSeed, bobKey.id);
    const lockEntries = safeMode
      ? makeWorkspaceLock("ws", "alice", aliceKey, [
          { sub: "alice", email: "alice@x.com", role: "owner" },
          { sub: "bob", email: "bob@x.com", role: "member" },
        ], [
          { id: aliceDev, sub: "alice", sign_key: aliceKey.id },
          { id: bobDev, sub: "bob", sign_key: bobKey.id },
        ])
      : undefined;
    const st = sharedStation({
      safeMode,
      roles: { alice: "owner", bob: "member" },
      chains: safeMode ? undefined : { alice: aliceChain, bob: bobChain },
      lockEntries,
    });

    const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, personalSeed: alicePSeed, st, wsMembers, safeMode, lockEntries, personalChain: aliceChain });
    const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, personalSeed: bobPSeed, st, wsMembers, safeMode, lockEntries, personalChain: bobChain });

    try {
      await alice.ask("vault.setup", {});
      await bob.ask("vault.setup", {});
      await alice.sync();
      await bob.sync();

      // Before workspace vault exists: owner canCreateWorkspace=true, member canCreateWorkspace=false
      assert.equal((vaultsView(alice.core.inner, "ws") as any).canCreateWorkspace, true, `safeMode=${safeMode}: owner can create`);
      assert.equal((vaultsView(bob.core.inner, "ws") as any).canCreateWorkspace, false, `safeMode=${safeMode}: member cannot create`);

      // Member is rejected with vault_not_admin
      const errMember = await bob.askErr("vault.create", { name: "Team Secrets", scope: "workspace" });
      assert.equal(errMember.code, "vault_not_admin", `safeMode=${safeMode}: member rejected`);

      // Owner creates workspace vault
      const created = await alice.ask("vault.create", { name: "Team Secrets", scope: "workspace" });
      assert.ok(created.id, `safeMode=${safeMode}: workspace vault created`);
      const v = st.vaults.get(created.id)!;
      assert.equal(v.scope, "workspace");
      assert.equal(v.recovery, undefined, "workspace vault has no single-person recovery key");
      assert.deepEqual([...v.members].sort(), ["alice", "bob"]);

      // Duplicate workspace vault creation is rejected with vault_exists
      const errDup = await alice.askErr("vault.create", { name: "Team Secrets 2", scope: "workspace" });
      assert.equal(errDup.code, "vault_exists", `safeMode=${safeMode}: duplicate rejected`);

      // View shows scope="workspace", manages=true for owner, canCreateWorkspace=false
      const aView = vaultsView(alice.core.inner, "ws") as any;
      assert.equal(aView.canCreateWorkspace, false);
      const wsRowA = aView.vaults.find((x: any) => x.id === created.id);
      assert.equal(wsRowA.scope, "workspace");
      assert.equal(wsRowA.manages, true);
      const personalRowA = aView.vaults.find((x: any) => x.id !== created.id);
      assert.equal(personalRowA.scope, "personal");
      assert.equal(personalRowA.manages, true);
    } finally {
      alice.core.close();
      bob.core.close();
    }
  }
});

test("non-safe-mode two-member e2e: Bob folds Alice's chain from GET /vault/boxes on first read, decrypts & writes items, ignores bad chains", async () => {
  const aliceSeed = fill(31), bobSeed = fill(32), alicePSeed = fill(41), bobPSeed = fill(42);
  const aliceDev = "a2".repeat(32), bobDev = "b2".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
  ];
  const aliceChain = makePersonalChain("alice", aliceDev, alicePSeed, aliceKey.id);
  const bobChain = makePersonalChain("bob", bobDev, bobPSeed, bobKey.id);
  // Inject a malformed teammate chain for "mallory" to verify it is safely ignored
  const badChain = [{ seq: 0, kind: "genesis", body: { sub: "mallory" }, sig: { key: "bad", alg: "Ed25519", sig: "00" } }] as unknown as Entry[];
  const st = sharedStation({
    safeMode: false,
    roles: { alice: "owner", bob: "member", mallory: "member" },
    chains: { alice: aliceChain, bob: bobChain, mallory: badChain },
  });

  const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, personalSeed: alicePSeed, st, wsMembers, safeMode: false, personalChain: aliceChain });
  const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, personalSeed: bobPSeed, st, wsMembers, safeMode: false, personalChain: bobChain });

  try {
    await bob.ask("vault.setup", {});
    await alice.ask("vault.setup", {});
    // Alice syncs to get Bob's BoxCert + personal chain
    await alice.sync();

    const wsVault = await alice.ask("vault.create", { name: "Shared", scope: "workspace", members: ["alice", "bob"] });
    const itemA = await alice.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "API Key", fields: { value: "sk_from_alice" } },
      listing: { name: "API Key", kind: "token", modes: ["env"], hosts: [] },
    });

    // Bob has NEVER seen Alice's chain before; his very first sync pulls chains+roles from GET /vault/boxes before fits()!
    await bob.sync();
    const bView = vaultsView(bob.core.inner, "ws") as any;
    const rowB = bView.vaults.find((x: any) => x.id === wsVault.id);
    assert.ok(rowB, "Bob sees workspace vault on very first station read");
    assert.equal(rowB.scope, "workspace");
    assert.equal(rowB.manages, false, "regular member cannot manage workspace vault");
    assert.equal(rowB.keyed, true, "Bob's device is keyed");

    // Bob decrypts Alice's item
    const openedByBob = await bob.ask("vault.open", { item: itemA.id });
    assert.equal(openedByBob.plain.fields.value, "sk_from_alice");

    // Bob writes a new item to the workspace vault and Alice decrypts it
    const itemB = await bob.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "Bob Token", fields: { value: "sk_from_bob" } },
      listing: { name: "Bob Token", kind: "token", modes: ["env"], hosts: [] },
    });
    await alice.sync();
    const openedByAlice = await alice.ask("vault.open", { item: itemB.id });
    assert.equal(openedByAlice.plain.fields.value, "sk_from_bob");
  } finally {
    alice.core.close();
    bob.core.close();
  }
});

test("vault.setMembers: adding Carol keeps epoch & seals key; removing Carol rotates epoch+1 & re-encrypts items", async () => {
  const aliceSeed = fill(51), bobSeed = fill(52), carolSeed = fill(53);
  const aliceDev = "a3".repeat(32), bobDev = "b3".repeat(32), carolDev = "c3".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed), carolKey = edKey(carolSeed);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "admin" },
    { sub: "carol", email: "carol@x.com", name: "Carol", role: "member" },
  ];
  const lockEntries = makeWorkspaceLock("ws", "alice", aliceKey, [
    { sub: "alice", email: "alice@x.com", role: "owner" },
    { sub: "bob", email: "bob@x.com", role: "admin" },
    { sub: "carol", email: "carol@x.com", role: "member" },
  ], [
    { id: aliceDev, sub: "alice", sign_key: aliceKey.id },
    { id: bobDev, sub: "bob", sign_key: bobKey.id },
    { id: carolDev, sub: "carol", sign_key: carolKey.id },
  ]);
  const st = sharedStation({ safeMode: true, roles: { alice: "owner", bob: "admin", carol: "member" }, lockEntries });

  const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, st, wsMembers, safeMode: true, lockEntries });
  const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, st, wsMembers, safeMode: true, lockEntries });
  const carol = await makeMemberDevice({ sub: "carol", email: "carol@x.com", devId: carolDev, signerSeed: carolSeed, st, wsMembers, safeMode: true, lockEntries });

  try {
    await alice.ask("vault.setup", {});
    await bob.ask("vault.setup", {});
    await carol.ask("vault.setup", {});
    await alice.sync();
    await bob.sync();
    await carol.sync();

    // Alice creates workspace vault with only Alice and Bob
    const wsVault = await alice.ask("vault.create", { name: "Shared", scope: "workspace", members: ["alice", "bob"] });
    const item1 = await alice.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "Secret1", fields: { value: "v1_secret" } },
      listing: { name: "Secret1", kind: "token", modes: ["env"], hosts: [] },
    });
    assert.equal(st.vaults.get(wsVault.id)!.epoch, 0);

    // Add Carol -> keeps epoch 0, seals key to Carol
    const added = await alice.ask("vault.setMembers", { vault: wsVault.id, members: ["alice", "bob", "carol"] });
    assert.equal(added.rekeyed, false);
    assert.equal(st.vaults.get(wsVault.id)!.epoch, 0);
    assert.ok(st.vaults.get(wsVault.id)!.keys.some((k) => k.cert.device === carolDev));

    // Carol syncs and opens Secret1
    await carol.sync();
    const carolOpened = await carol.ask("vault.open", { item: item1.id });
    assert.equal(carolOpened.plain.fields.value, "v1_secret");

    // Capture Carol's old epoch-0 vault key so we can prove she cannot decrypt epoch-1 items
    const carolBoxPriv = carol.host.secure.get(BOX_KEY)!.value;
    const carolWrapped0 = st.vaults.get(wsVault.id)!.keys.find((k) => k.cert.device === carolDev)!.wrapped;
    const epoch0Key = openSeal(carolBoxPriv, carolWrapped0, keyContext("ws", wsVault.id, 0));

    // Remove Carol -> rotates epoch to 1 and re-encrypts Secret1
    const removed = await alice.ask("vault.setMembers", { vault: wsVault.id, members: ["alice", "bob"] });
    assert.equal(removed.rekeyed, true);
    assert.equal(removed.epoch, 1);
    const vAfter = st.vaults.get(wsVault.id)!;
    assert.equal(vAfter.epoch, 1);
    assert.ok(!vAfter.members.includes("carol"));
    assert.ok(!vAfter.keys.some((k) => k.cert.device === carolDev));

    // Re-encrypted item1 is now at epoch 1 and cannot be decrypted with Carol's epoch-0 key
    const reencryptedItem1 = st.items.get(item1.id)!;
    assert.equal(reencryptedItem1.epoch, 1);
    assert.equal(reencryptedItem1.version, 1);
    assert.throws(() => decrypt(epoch0Key, reencryptedItem1.ct, itemContext("ws", wsVault.id, item1.id, reencryptedItem1.version, 1)));

    // New item written after Carol's removal is at epoch 1 and unreadable by Carol's epoch-0 key, readable by Bob
    const item2 = await alice.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "Secret2", fields: { value: "v2_after_carol" } },
      listing: { name: "Secret2", kind: "token", modes: ["env"], hosts: [] },
    });
    const newItem2 = st.items.get(item2.id)!;
    assert.equal(newItem2.epoch, 1);
    assert.throws(() => decrypt(epoch0Key, newItem2.ct, itemContext("ws", wsVault.id, item2.id, newItem2.version, 1)));

    await bob.sync();
    assert.equal((await bob.ask("vault.open", { item: item1.id })).plain.fields.value, "v1_secret");
    assert.equal((await bob.ask("vault.open", { item: item2.id })).plain.fields.value, "v2_after_carol");
  } finally {
    alice.core.close();
    bob.core.close();
    carol.core.close();
  }
});

test("admin collaboration & owner takeover: non-creator admin Bob manages workspace vault and takes over owner when removing creator Alice", async () => {
  const aliceSeed = fill(61), bobSeed = fill(62), bob2Seed = fill(63);
  const aliceDev = "a4".repeat(32), bobDev = "b4".repeat(32), bob2Dev = "b5".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed), bob2Key = edKey(bob2Seed);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "admin" },
  ];
  const lockEntries = makeWorkspaceLock("ws", "alice", aliceKey, [
    { sub: "alice", email: "alice@x.com", role: "owner" },
    { sub: "bob", email: "bob@x.com", role: "admin" },
  ], [
    { id: aliceDev, sub: "alice", sign_key: aliceKey.id },
    { id: bobDev, sub: "bob", sign_key: bobKey.id },
    { id: bob2Dev, sub: "bob", sign_key: bob2Key.id },
  ]);
  const st = sharedStation({ safeMode: true, roles: { alice: "owner", bob: "admin" }, lockEntries });

  const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, st, wsMembers, safeMode: true, lockEntries });
  const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, st, wsMembers, safeMode: true, lockEntries });
  const bob2 = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bob2Dev, signerSeed: bob2Seed, st, wsMembers, safeMode: true, lockEntries });

  try {
    await alice.ask("vault.setup", {});
    await bob.ask("vault.setup", {});
    await alice.sync();

    const wsVault = await alice.ask("vault.create", { name: "Team", scope: "workspace", members: ["alice", "bob"] });
    const item = await alice.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "ProdKey", fields: { value: "prod_secret" } },
      listing: { name: "ProdKey", kind: "token", modes: ["env"], hosts: [] },
    });

    // Bob's second device sets up after workspace vault was created
    await bob2.ask("vault.setup", {});
    await bob.sync();

    // Non-creator admin Bob sees manages=true and can setLasts + addDevice
    const bView = vaultsView(bob.core.inner, "ws") as any;
    const rowB = bView.vaults.find((x: any) => x.id === wsVault.id);
    assert.equal(rowB.mine, false);
    assert.equal(rowB.manages, true);

    await bob.ask("vault.setLasts", { vault: wsVault.id, lasts: "hour" });
    assert.equal(st.vaults.get(wsVault.id)!.lasts, "hour");

    const addRes = await bob.ask("vault.addDevice", { vault: wsVault.id, device: bob2Dev });
    assert.equal(addRes.added, 1);
    assert.ok(st.vaults.get(wsVault.id)!.keys.some((k) => k.cert.device === bob2Dev));

    // Bob removes original creator Alice -> owner is taken over by Bob and epoch rotates to 1
    const takeover = await bob.ask("vault.setMembers", { vault: wsVault.id, members: ["bob"] });
    assert.equal(takeover.rekeyed, true);
    assert.equal(takeover.epoch, 1);
    const vNow = st.vaults.get(wsVault.id)!;
    assert.equal(vNow.owner, "bob", "Bob took over owner from removed creator Alice");
    assert.deepEqual(vNow.members, ["bob"]);
    assert.equal(st.items.get(item.id)!.epoch, 1);

    // Bob can also delete the workspace vault
    await bob.ask("vault.delete", { vault: wsVault.id });
    assert.equal(st.vaults.get(wsVault.id)!.deleted, true);
  } finally {
    alice.core.close();
    bob.core.close();
    bob2.core.close();
  }
});

test("handoverForApproved in non-safe mode hands over both personal and workspace vaults under a single boxPriv", async () => {
  const aliceSeed = fill(71), alice2Seed = fill(72), bobSeed = fill(73);
  const alicePSeed = fill(81), alice2PSeed = fill(82), bobPSeed = fill(83);
  const aliceDev = "a5".repeat(32), alice2Dev = "a6".repeat(32), bobDev = "b6".repeat(32);
  const aliceKey = edKey(aliceSeed), alice2Key = edKey(alice2Seed), bobKey = edKey(bobSeed);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "admin" },
  ];
  const aliceChain0 = makePersonalChain("alice", aliceDev, alicePSeed, aliceKey.id);
  const bobChain = makePersonalChain("bob", bobDev, bobPSeed, bobKey.id);
  // Build updated personal chain for Alice after approving alice2Dev
  const alicePk = edKey(alicePSeed);
  const alice2Pk = edKey(alice2PSeed);
  const head0 = { seq: 0, hash: entryHash(aliceChain0[0]!), genesis: entryHash(aliceChain0[0]!) };
  const addAlice2 = lockEntry(
    next("person:alice", head0, 1005, "device", { key: alice2Pk.id, id: alice2Dev, label: "alice-2", sign_key: alice2Key.id }),
    alicePk,
  );
  const aliceChain1 = [...aliceChain0, addAlice2];

  const st = sharedStation({
    safeMode: false,
    roles: { alice: "owner", bob: "admin" },
    chains: { alice: aliceChain0, bob: bobChain },
  });

  const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, personalSeed: alicePSeed, st, wsMembers, safeMode: false, personalChain: aliceChain0 });
  const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, personalSeed: bobPSeed, st, wsMembers, safeMode: false, personalChain: bobChain });
  const alice2 = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: alice2Dev, signerSeed: alice2Seed, personalSeed: alice2PSeed, st, wsMembers, safeMode: false, personalChain: aliceChain1 });

  try {
    await bob.ask("vault.setup", {});
    const setupA = await alice.ask("vault.setup", {});
    await alice.sync();

    // Bob creates workspace vault (so Alice is non-creator owner/admin of workspace vault!)
    await bob.sync();
    const wsVault = await bob.ask("vault.create", { name: "Team", scope: "workspace", members: ["alice", "bob"] });
    const personalItem = await alice.ask("vault.putItem", {
      vault: setupA.made,
      plain: { kind: "token", name: "Mine", fields: { value: "my_personal_val" } },
      listing: { name: "Mine", kind: "token", modes: ["env"], hosts: [] },
    });
    const wsItem = await bob.ask("vault.putItem", {
      vault: wsVault.id,
      plain: { kind: "token", name: "Ours", fields: { value: "our_shared_val" } },
      listing: { name: "Ours", kind: "token", modes: ["env"], hosts: [] },
    });
    await alice.sync();
    // Lock Alice's RAM keys so handover must use boxPriv
    await alice.ask("vault.lock", {});

    // alice2 prepares boxCerts for pairing
    const alice2Signer = await Effect.runPromise(Signer.load(alice2.host));
    const { certs: boxCerts } = await Effect.runPromise(pairBoxCerts(alice2.core.inner, alice2Dev, alice2Signer!, ["alice"], ["ws"]));

    assert.equal(needsBoxForHandover(alice.core.inner, alice2Dev, ["alice"], ["ws"], boxCerts), true);

    // Update station's alice chain to aliceChain1 and run handoverForApproved with a single boxPriv
    const boxPriv = alice.host.secure.get(BOX_KEY)!.value;
    const handed = await Effect.runPromise(handoverForApproved(alice.core.inner, {
      device: alice2Dev,
      signKey: alice2Key.id,
      subs: ["alice"],
      workspaces: ["ws"],
      boxCerts,
      boxPriv,
      chains: { alice: aliceChain1 },
    }));

    const handedIds = handed.map((h) => h.vault?.id).filter(Boolean).sort();
    assert.deepEqual(handedIds, [setupA.made, wsVault.id].sort(), "both personal and workspace vaults handed over");

    // alice2 takes handed vaults, syncs items, and opens secrets from BOTH vaults
    takeHanded(alice2.core.inner, handed);
    await alice2.sync();
    assert.equal((await alice2.ask("vault.open", { item: personalItem.id })).plain.fields.value, "my_personal_val");
    assert.equal((await alice2.ask("vault.open", { item: wsItem.id })).plain.fields.value, "our_shared_val");
  } finally {
    alice.core.close();
    bob.core.close();
    alice2.core.close();
  }
});

test("secret_save shared/explicit vault targeting, vaultNoKey, and personal-only isolation (setup & migrate)", async () => {
  const aliceSeed = fill(91), bobSeed = fill(92), bob2Seed = fill(93);
  const aliceDev = "a7".repeat(32), bobDev = "b7".repeat(32), bob2Dev = "b8".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed), bob2Key = edKey(bob2Seed);
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
  ];
  const lockEntries = makeWorkspaceLock("ws", "alice", aliceKey, [
    { sub: "alice", email: "alice@x.com", role: "owner" },
    { sub: "bob", email: "bob@x.com", role: "member" },
  ], [
    { id: aliceDev, sub: "alice", sign_key: aliceKey.id },
    { id: bobDev, sub: "bob", sign_key: bobKey.id },
    { id: bob2Dev, sub: "bob", sign_key: bob2Key.id },
  ]);
  const st = sharedStation({ safeMode: true, roles: { alice: "owner", bob: "member" }, lockEntries });

  const alice = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, st, wsMembers, safeMode: true, lockEntries });
  const bob = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bobDev, signerSeed: bobSeed, st, wsMembers, safeMode: true, lockEntries });
  const bob2 = await makeMemberDevice({ sub: "bob", email: "bob@x.com", devId: bob2Dev, signerSeed: bob2Seed, st, wsMembers, safeMode: true, lockEntries });

  try {
    // Seed a plain personal item on station before Alice sets up
    st.plain.set("i_plain_1", {
      id: "i_plain_1", owner: "alice@x.com", version: 0, kind: "token", name: "LegacyToken",
      fields: { value: "legacy_secret" }, notes: "", at: 100,
    });

    await alice.ask("vault.setup", {});
    await alice.sync();
    // Alice creates workspace vault including Bob BEFORE Bob runs setup()
    const wsVault = await alice.ask("vault.create", { name: "Shared", scope: "workspace", members: ["alice", "bob"] });

    // Bob syncs and sees workspace vault, then runs vault.setup(): MUST still create Bob's own personal vault!
    await bob.sync();
    const bobSetup = await bob.ask("vault.setup", {});
    assert.ok(bobSetup.made && bobSetup.made !== wsVault.id, "setup() creates personal vault even when workspace vault exists");
    const bobPersonalId = bobSetup.made as string;

    // Seed another plain item and run Alice's migrate(): MUST go into Alice's personal vault, never workspace vault!
    st.plain.set("i_plain_2", {
      id: "i_plain_2", owner: "alice@x.com", version: 0, kind: "token", name: "Legacy2",
      fields: { value: "legacy_2" }, notes: "", at: 101,
    });
    await alice.sync();
    const mig = await alice.ask("vault.migrate", {});
    assert.equal(mig.moved, 1);
    const migratedItem = [...st.items.values()].find((i) => i.listing?.name === "Legacy2" || i.vault !== wsVault.id);
    assert.ok(migratedItem && migratedItem.vault !== wsVault.id, "migrate() never moves plain secrets into workspace vault");

    // Alice grants Bob's first device (bobDev) access to workspace vault, but NOT bob2Dev
    await alice.sync();
    await alice.ask("vault.addDevice", { vault: wsVault.id, device: bobDev });
    // Bob2 sets up (gets personal vault key from Bob, NOT workspace vault key)
    await bob2.ask("vault.setup", {});
    await bob.sync();
    await bob.ask("vault.addDevice", { vault: bobPersonalId, device: bob2Dev });
    await bob2.sync();

    const reqBox = boxPublic(fill(99));
    // 1. Default personal secret_save (no vault passed on approve): MUST land in personal vault, never workspace vault.
    const rDefault: Request = {
      id: "r_default", ws: "ws", vault: "", item: "i_01JADEF0000000000000000001", session: "k1", chat: "7",
      mode: "env", hosts: [], reason: "save personal", box: reqBox, at: 200, status: "pending", owner: "bob@x.com",
      save: { kind: "token", name: "PersonalTok", modes: ["env"], hosts: [], typed: true },
    };
    st.requests.push(rDefault);
    await bob.sync();
    // askAnswers carries saveTargets (personal first, workspace second) for chat save cards when >1 keyed vault exists.
    const bobAns = askAnswers(bob.core.inner, "ws", [{ request: "r_default", save: true }]);
    assert.equal(bobAns[0]?.answer, "approve");
    assert.equal(bobAns[0]?.saveTargets?.length, 2);
    assert.equal(bobAns[0]?.saveTargets?.[0]?.id, bobPersonalId);
    assert.equal(bobAns[0]?.saveTargets?.[0]?.workspace, undefined);
    assert.equal(bobAns[0]?.saveTargets?.[1]?.id, wsVault.id);
    assert.equal(bobAns[0]?.saveTargets?.[1]?.workspace, true);
    const okDefault = await bob.ask("vault.approve", { request: "r_default", scope: "once", typed: { secret: "tok_personal" } });
    assert.equal(okDefault.vault, bobPersonalId, "default secret_save lands in personal vault, not workspace vault");

    // 2. Explicit targetVault on approve: bob2 passing vault=wsVault fails vault_no_key; bob passing vault=wsVault succeeds and Alice can decrypt it immediately.
    const rExplicit: Request = {
      id: "r_explicit", ws: "ws", vault: "", item: "i_01JAEX00000000000000000001", session: "k1", chat: "7",
      mode: "env", hosts: [], reason: "save explicit", box: reqBox, at: 201, status: "pending", owner: "bob@x.com",
      save: { kind: "token", name: "ExplicitTok", modes: ["env"], hosts: [], typed: true },
    };
    st.requests.push(rExplicit);
    await bob2.sync();
    await bob.sync();
    const errExp = await bob2.askErr("vault.approve", { request: "r_explicit", scope: "once", typed: { secret: "tok_exp" }, vault: wsVault.id });
    assert.equal(errExp.code, "vault_no_key");
    const okExp = await bob.ask("vault.approve", { request: "r_explicit", scope: "once", typed: { secret: "tok_exp" }, vault: wsVault.id });
    assert.equal(okExp.vault, wsVault.id);
    assert.equal(st.items.get("i_01JAEX00000000000000000001")!.vault, wsVault.id);
    await alice.sync();
    assert.equal((await alice.ask("vault.open", { item: "i_01JAEX00000000000000000001" })).plain.fields.value, "tok_exp");

    // 3. Even if an older station sends save.shared=true with r.vault=wsVault.id, approving without explicit vault STILL defaults to personal vault (and bob2 with personal key is NOT noKey).
    const rLegacyShared: Request = {
      id: "r_shared", ws: "ws", vault: wsVault.id, item: "i_01JASHARED0000000000000001", session: "k1", chat: "7",
      mode: "env", hosts: [], reason: "save legacy shared", box: reqBox, at: 202, status: "pending", owner: "bob@x.com",
      save: { kind: "token", name: "SharedTok", modes: ["env"], hosts: [], typed: true, shared: true, vaultName: "Shared" },
    };
    st.requests.push(rLegacyShared);
    await bob2.sync();
    await bob.sync();

    assert.equal(askAnswers(bob2.core.inner, "ws", [{ request: "r_shared", save: true }])[0]?.answer, "approve");
    const b2View = vaultsView(bob2.core.inner, "ws") as any;
    const reqRowB2 = b2View.requests.find((x: any) => x.id === "r_shared");
    assert.equal(reqRowB2.noKey, undefined);

    const okLegacy = await bob2.ask("vault.approve", { request: "r_shared", scope: "once", typed: { secret: "tok_legacy" } });
    assert.equal(okLegacy.vault, bobPersonalId, "legacy save.shared=true without explicit targetVault still defaults to personal vault");
    assert.equal(st.items.get("i_01JASHARED0000000000000001")!.vault, bobPersonalId);
  } finally {
    alice.core.close();
    bob.core.close();
    bob2.core.close();
  }
});

test("non-safe-mode unseen cloud member: creates with all members on new station, falls back to station-known members on old station, and localizes explicit member error", async () => {
  const aliceSeed = fill(101), bobSeed = fill(102), alicePSeed = fill(111), bobPSeed = fill(112);
  const aliceDev = "a8".repeat(32), bobDev = "b9".repeat(32);
  const aliceKey = edKey(aliceSeed), bobKey = edKey(bobSeed);
  // Cloud workspace roster includes Carol, who has NEVER connected to the station.
  const wsMembers = [
    { sub: "alice", email: "alice@x.com", name: "Alice", role: "owner" },
    { sub: "bob", email: "bob@x.com", name: "Bob", role: "member" },
    { sub: "carol", email: "carol@x.com", name: "Carol", role: "member" },
  ];
  const aliceChain = makePersonalChain("alice", aliceDev, alicePSeed, aliceKey.id);
  const bobChain = makePersonalChain("bob", bobDev, bobPSeed, bobKey.id);

  // 1. New station accepts unseen workspace members -> created with all 3 members.
  const newSt = sharedStation({
    safeMode: false,
    roles: { alice: "owner", bob: "member" },
    chains: { alice: aliceChain, bob: bobChain },
  });
  const aliceNew = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, personalSeed: alicePSeed, st: newSt, wsMembers, safeMode: false, personalChain: aliceChain });
  try {
    await aliceNew.ask("vault.setup", {});
    await aliceNew.sync();
    const created = await aliceNew.ask("vault.create", { name: "Team", scope: "workspace" });
    assert.deepEqual([...newSt.vaults.get(created.id)!.members].sort(), ["alice", "bob", "carol"]);
  } finally {
    aliceNew.core.close();
  }

  // 2. Old station rejects unseen member "carol" with "member carol is not in the lock":
  //    default create falls back to station-known members ["alice", "bob"];
  //    explicit setMembers including "carol" surfaces localized message (not raw English internal error).
  const oldSt = sharedStation({
    safeMode: false,
    roles: { alice: "owner", bob: "member" },
    chains: { alice: aliceChain, bob: bobChain },
    rejectUnknownMembers: true,
  });
  const aliceOld = await makeMemberDevice({ sub: "alice", email: "alice@x.com", devId: aliceDev, signerSeed: aliceSeed, personalSeed: alicePSeed, st: oldSt, wsMembers, safeMode: false, personalChain: aliceChain });
  try {
    await aliceOld.ask("vault.setup", {});
    await aliceOld.sync();
    // Explicit opts.members with unseen Carol fails with localized message.
    const explicitErr = await aliceOld.askErr("vault.create", { name: "Team", scope: "workspace", members: ["alice", "carol"] });
    assert.equal(explicitErr.code, "vault_invalid");
    assert.ok(!explicitErr.message.includes("is not in the lock"), `expected localized error, got: ${explicitErr.message}`);

    // Default create (no explicit members) falls back to station-known members ["alice", "bob"].
    const created = await aliceOld.ask("vault.create", { name: "Team", scope: "workspace" });
    assert.deepEqual([...oldSt.vaults.get(created.id)!.members].sort(), ["alice", "bob"]);

    // setMembers adding unseen Carol on old station fails with localized message.
    const setErr = await aliceOld.askErr("vault.setMembers", { vault: created.id, members: ["alice", "bob", "carol"] });
    assert.equal(setErr.code, "vault_invalid");
    assert.ok(!setErr.message.includes("is not in the lock"), `expected localized error, got: ${setErr.message}`);
  } finally {
    aliceOld.core.close();
  }
});
