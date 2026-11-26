// A workspace's vault where the workspace is not in security mode (src/cloud/vault-lock.ts, Cloud `vaultLock`): its
// members' own locks as one lock of no chain (`genesis` ""), so that a vault is always encrypted and kept by its person's
// own devices; who of a person's logs is theirs (the one their vaults are signed by, then the one their box certificate
// checks against, then the newest); its devices let in by their own proof alone; a secret to keep for someone whose own
// lock is not heard here yet waiting, sealed to their device as it comes; turned down from their app before any vault.
import assert from "node:assert/strict";
import { createPublicKey, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { type Entry, LockRefusal, admit, endpointBytes, entryHash, genesis as makeGenesis, memberWithEmail, signedBytes as lockBytes } from "../../shared/lock.ts";
import { personalVaultChains, personalVaultLock } from "../src/cloud/vault-lock.ts";
import { Cloud, personChainsOf, seenDevicesOf, writeState } from "../src/cloud/state.ts";
import { routes as requestRoutes } from "../src/api/routes/vault-requests.ts";
import { routes as vaultRoutes } from "../src/api/routes/vault.ts";
import { type BoxCert, type Grant, type Item, type Sig, type Vault, TAG, certOk, grantContext, keyContext, newBoxPair, openSeal, saveContext, seal, signedBytes } from "../src/vault/crypto.ts";
import { PlainStore } from "../src/vault/plain.ts";
import { Secrets } from "../src/vault/secrets.ts";
import { VaultStore } from "../src/vault/store.ts";
import { vaultTools } from "../src/vault/tool.ts";
import { STILLFAIL_SURFACE } from "../src/store/store.ts";
import { withoutUseReader } from "./vault-no-reader.ts";

const WS = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
const VAULT = "v_01HZZZZZZZZZZZZZZZZZZZZZZZ";

function ed() {
  const key = generateKeyPairSync("ed25519").privateKey;
  const hex = Buffer.from(createPublicKey(key).export({ format: "jwk" }).x as string, "base64url").toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Buffer | Uint8Array) => nodeSign(null, bytes, key).toString("hex") };
}
type Key = ReturnType<typeof ed>;
const fill = (b: number, n = 32) => new Uint8Array(n).fill(b);
const tick = () => new Promise((r) => setImmediate(r));
const signed = <T extends Record<string, unknown>>(o: T, tag: string, key: Key): T & { sig: Sig } => ({ ...o, sig: { key: key.id, alg: "Ed25519", sig: key.sign(signedBytes(o, tag)) } });

/// A person's own lock begun by one app device: its log's key (`log`), its endpoint's base key (`base`), the signer it
/// signs the workspace's things with (`signer`), its box key.
function person(sub: string, at = 1000) {
  const p = { sub, log: ed(), base: ed(), signer: ed(), box: newBoxPair() };
  const e = { v: 1, ws: `person:${sub}`, seq: 0, prev: null, at, kind: "genesis", body: { sub, device: { key: p.log.id, id: p.base.hex, label: sub, sign_key: p.signer.id } } } as Omit<Entry, "sig">;
  const chain = [{ ...e, sig: { key: p.log.id, alg: "Ed25519" as const, sig: p.log.sign(lockBytes(entryHash(e as Entry))) } } as Entry];
  return { ...p, chain, genesis: entryHash(chain[0]!), cert: (boxAt = 1000): BoxCert => signed({ v: 1 as const, ws: WS, device: p.base.hex, box: p.box.pub, at: boxAt }, TAG.box, p.signer) };
}
type Person = ReturnType<typeof person>;

/// What the lock is made of, held here: the logs (by genesis), the members known, each with the version that moves as
/// it changes.
function sources(logs: Person[], emails: Record<string, string>) {
  let chainsVer = 0, membersVer = 0;
  const chains = new Map(logs.map((p) => [p.genesis, p.chain as unknown[]]));
  const known = new Map(Object.entries(emails));
  return {
    chains: { version: () => chainsVer, every: () => [...chains] as [string, unknown[]][] },
    members: { version: () => membersVer, members: () => known },
    add: (p: Person) => (chains.set(p.genesis, p.chain), chainsVer++),
    know: (sub: string, email: string) => (known.set(sub, email), membersVer++),
  };
}
const okCert = (l: ReturnType<typeof personalVaultLock>, c: BoxCert) => certOk(l, c) === null;
/// What a store keeps, as the vault's lock is made of it (vault/module.ts `held`).
const heldBy = (v: VaultStore) => ({ version: () => v.version(), vaults: (w: string) => v.vaults(w), boxes: (w: string) => v.boxes(w), certOk: okCert });
const held = (vaults: Vault[] = [], boxes: BoxCert[] = []) => ({ version: () => vaults.length * 1000 + boxes.length, vaults: () => vaults, boxes: () => boxes, certOk: okCert });

test("a workspace not in security mode: its vault's lock is its members' own, of no chain, the same object while nothing it is made of changes", () => {
  const alice = person("alice");
  const s = sources([alice], { alice: "alice@x.com", bob: "bob@x.com" });
  const owner = {};
  const lock = personalVaultLock(owner, WS, s);
  assert.deepEqual([lock.ws, lock.genesis, lock.head, lock.seq, lock.disabled], [WS, "", "", 0, false]);
  assert.deepEqual(lock.devices.get(alice.base.hex), { id: alice.base.hex, sub: "alice", kind: "app", label: "alice", sign_key: alice.signer.id, own: true });
  assert.deepEqual(lock.signKeys.get(alice.base.hex), [alice.signer.id]);
  // Every member known here is one of it, whoever has a lock of their own yet: bob with no device.
  assert.equal(memberWithEmail(lock, "bob@x.com")?.sub, "bob");
  assert.deepEqual([...lock.devices.values()].map((d) => d.sub), ["alice"]);
  assert.equal(personalVaultLock(owner, WS, s), lock, "the same object: GET /vault/requests reads a change by it");
  const bob = person("bob");
  s.add(bob);
  const after = personalVaultLock(owner, WS, s);
  assert.notEqual(after, lock);
  assert.equal(after.devices.get(bob.base.hex)?.sub, "bob");
});

test("of a person's two logs, the one their vault is signed by is theirs, then the one their box certificate checks against, then the newest: a log brought later takes neither", () => {
  const first = person("alice", 1000);
  const later = { ...person("alice", 2000) };
  const s = sources([first, later], { alice: "alice@x.com" });
  const devicesOf = (l: ReturnType<typeof personalVaultLock>) => [...l.devices.keys()];
  // Neither said by anything of the vault's: the newest.
  assert.deepEqual(devicesOf(personalVaultLock({}, WS, s)), [later.base.hex]);
  // Their box certificate, signed by the first log's device.
  assert.deepEqual(devicesOf(personalVaultLock({}, WS, s, held([], [first.cert()]))), [first.base.hex]);
  // Their vault, signed by the first log's device's signer, over a certificate of the later one's.
  const vault: Vault = signed(
    { v: 1 as const, ws: WS, id: VAULT, seq: 0, owner: "alice", name: "Personal", members: ["alice"], epoch: 0, keys: [{ cert: first.cert(), wrapped: seal(first.box.pub, fill(4), keyContext(WS, VAULT, 0)) }], at: 1000 },
    TAG.vault, first.signer,
  );
  assert.deepEqual(devicesOf(personalVaultLock({}, WS, s, held([vault], [later.cert(3000)]))), [first.base.hex]);
});

test("its devices let in by their own proof alone: a person's app device on their own lock; another's, a key not on it, or a proof that does not hold, not", () => {
  const alice = person("alice"), bob = person("bob");
  const lock = personalVaultLock({}, WS, sources([alice, bob], { alice: "alice@x.com", bob: "bob@x.com" }));
  const proof = (p: Person, endpoint: string) => p.base.sign(endpointBytes(WS, endpoint));
  const endpoint = ed().hex;
  assert.equal(admit(lock, { sub: "alice", endpoint, base: alice.base.hex, proof: proof(alice, endpoint) }, 0).device.id, alice.base.hex);
  assert.equal(admit(lock, { sub: "alice", endpoint: alice.base.hex }, 0).role, "member");
  assert.throws(() => admit(lock, { sub: "bob", endpoint, base: alice.base.hex, proof: proof(alice, endpoint) }, 0), LockRefusal);
  assert.throws(() => admit(lock, { sub: "alice", endpoint, base: alice.base.hex, proof: proof(bob, endpoint) }, 0), /invalid lock device proof/);
  assert.throws(() => admit(lock, { sub: "alice", endpoint: ed().hex }, 0), LockRefusal);
});

test("a station in no workspace has no vault lock; one in a workspace not in security mode has its members' own, named by who came and who asked", async () => {
  const empty = mkdtempSync(join(tmpdir(), "vault-lock-none-"));
  const data = mkdtempSync(join(tmpdir(), "vault-lock-"));
  try {
    assert.equal(new Cloud(empty, false).vaultLock(null), null);
    writeState(data, { origin: "https://stillfail.test", station: "st", workspace: WS, workspace_name: "W", name: "studio", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [] } as never);
    const c = new Cloud(data, false);
    const alice = person("alice");
    personChainsOf(c).keep(alice.genesis, alice.chain, WS);
    seenDevicesOf(c).remember(WS, "bob", "bob@x.com");
    const lock = c.vaultLock(WS)!;
    assert.equal(lock.genesis, "");
    assert.equal(lock.devices.get(alice.base.hex)?.sub, "alice");
    assert.equal(memberWithEmail(lock, "bob@x.com")?.sub, "bob");
    assert.equal(c.vaultLock(null), lock, "the home workspace's by null, the same object");
    // (the logs and devices written off the thread first: removed while one is written, the directory is not empty)
    await Promise.all([personChainsOf(c).written(), seenDevicesOf(c).written()]);
    c.close();
  } finally {
    rmSync(empty, { recursive: true, force: true });
    rmSync(data, { recursive: true, force: true });
  }
});

function harness(lock: () => ReturnType<typeof personalVaultLock>) {
  const db = new DatabaseSync(":memory:");
  const vaults = new VaultStore(db);
  const plain = new PlainStore(db);
  const notified: [string, string][] = [];
  const cards: { text: string; card: unknown }[] = [];
  const hub = {
    store: {
      getSession: (k: string) => (k === "s1" ? { key: "s1", ws: null, workspace: "/tmp", archivedAt: null } : null),
      starter: () => "alice@x.com",
      participants: (k: string) => new Map(k === "s1" ? [["s1", ["alice@x.com"]]] : []),
      latestThread: () => ({ connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } }),
      sessionThreadById: () => ({ connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } }),
      withdrawCard: () => true,
      restateCard: () => true,
      insertMessage: (m: { text: string; card: unknown }) => (cards.push({ text: m.text, card: m.card }), [cards.length]),
      pendingCardHeader: () => (cards.length === 0 ? null : [{ ts: String(cards.length) }, cards.at(-1)!.card]),
      subscribe: () => () => {},
    },
    chat: () => ({ post: async () => String(cards.length + 1) }),
    shared: () => {},
    notify: (k: string, text: string) => notified.push([k, text]),
  };
  const dir = mkdtempSync(join(tmpdir(), "vault-personal-"));
  const secrets = new Secrets({ db: withoutUseReader(db), vaults, plain, home: () => WS, hub: hub as never, data: dir, lock: () => lock(), now: () => 1_000_000 });
  return { db, vaults, plain, secrets, dir };
}

test("a secret to keep for someone whose own lock is not heard here yet: their vault 'off', the request waiting sealed to nothing, sealed to their device as its certificate comes; nothing written to the plain library", async () => {
  const alice = person("alice");
  const s = sources([], { alice: "alice@x.com" });
  const owner = {};
  const h = harness(() => personalVaultLock(owner, WS, s, heldBy(h.vaults)));
  try {
    assert.equal(h.secrets.status("s1"), "off", "secret_list tells the agent their vault is not turned on");
    void h.secrets.save("s1", { name: "GitHub", kind: "token", reason: "ci", value: "ghp_x", cwd: h.dir });
    await tick();
    const pending = () => h.secrets.pending(WS, personalVaultLock(owner, WS, s, heldBy(h.vaults)), { sub: "alice", email: "alice@x.com" });
    let [r] = pending();
    assert.deepEqual([r?.vault, r?.sealed, r?.box !== ""], ["", [], true]);
    assert.equal(h.plain.items(WS, "alice@x.com").length, 0);
    // Their app turns the vault on: its own lock heard here, its certificate published by the device itself.
    s.add(alice);
    const put = vaultRoutes({ vaults: h.vaults, lock: () => personalVaultLock(owner, WS, s, heldBy(h.vaults)), boxed: (l, c) => h.secrets.boxed(l, c) })
      .find((x) => x.method === "PUT" && x.pattern.test("/vault/boxes"))!;
    const viewer = { sub: "alice", workspace: WS, email: "alice@x.com", name: "Alice", role: "member", device: alice.base.hex };
    const answer = await put.handle({ method: "PUT", path: "/vault/boxes", query: [], headers: {}, body: Buffer.from(JSON.stringify(alice.cert())), viewer, lang: "en" } as never, []);
    assert.equal(answer.status, 200);
    [r] = pending();
    assert.deepEqual(JSON.parse(Buffer.from(openSeal(alice.box.priv, r!.sealed!.find((x) => x.box === alice.box.pub)!.secret, saveContext(WS, r!.id))).toString()), { value: "ghp_x" });
    // Someone else's device publishes nothing for them.
    const bob = person("bob");
    s.add(bob);
    const theirs = await put.handle({ method: "PUT", path: "/vault/boxes", query: [], headers: {}, body: Buffer.from(JSON.stringify(alice.cert(2000))), viewer: { ...viewer, sub: "bob", device: bob.base.hex }, lang: "en" } as never, []);
    assert.equal(theirs.status, 403);
  } finally {
    rmSync(h.dir, { recursive: true, force: true });
  }
});

test("a secret to keep turned down from the app of whoever it is for, before any lock of theirs is heard: signed by any key of theirs, decided by their credential; not by anyone else's", async () => {
  const s = sources([], { alice: "alice@x.com", bob: "bob@x.com" });
  const owner = {};
  const lock = () => personalVaultLock(owner, WS, s);
  const h = harness(lock);
  try {
    void h.secrets.save("s1", { name: "Slack", kind: "token", reason: "z", value: "xoxb", cwd: h.dir });
    await tick();
    const [r] = h.secrets.pending(WS, lock(), { sub: "alice", email: "alice@x.com" });
    const any = ed();
    const deny = signed({ v: 1 as const, ws: WS, request: r!.id, at: 1000 }, TAG.deny, any);
    const route = requestRoutes({ secrets: h.secrets, plain: h.plain, lock })
      .find((x) => x.method === "POST" && x.pattern.test("/vault/denials"))!;
    const by = (sub: string, email: string) => route.handle({ method: "POST", path: "/vault/denials", query: [], headers: {}, body: Buffer.from(JSON.stringify(deny)), viewer: { sub, email, workspace: WS, device: any.hex }, lang: "en" } as never, []);
    assert.equal((await by("bob", "bob@x.com")).status, 409, "someone else's refusal is not taken");
    assert.equal((await by("alice", "Alice@x.com")).status, 200);
    assert.deepEqual(h.secrets.pending(WS, lock(), { sub: "alice", email: "alice@x.com" }), []);
  } finally {
    rmSync(h.dir, { recursive: true, force: true });
  }
});

test("GET /vault/requests where the lock is its members' own: a lock made again while it waits is read again, nobody refused as not admitted", async () => {
  const s = sources([], { bob: "bob@x.com" });
  const owner = {};
  let ready!: () => void;
  const preparing = new Promise<void>((resolve) => { ready = resolve; });
  let first = true;
  const secrets = { preparePending: () => (first ? ((first = false), preparing) : Promise.resolve()), pending: () => [{ id: "theirs" }] };
  const route = requestRoutes({ secrets: secrets as never, plain: {} as never, lock: () => personalVaultLock(owner, WS, s) })
    .find((x) => x.method === "GET" && x.pattern.test("/vault/requests"))!;
  const answer = route.handle({ viewer: { sub: "bob", email: "bob@x.com", workspace: WS, device: ed().hex } } as never, []);
  s.add(person("alice"));
  ready();
  const a = await answer;
  assert.equal(a.status, 200);
  assert.deepEqual(JSON.parse(String(a.body)).requests, [{ id: "theirs" }]);
});

test("non-security mode personalVaultLock preserves member roles and GET /vault/boxes returns chains and roles", async () => {
  const data = mkdtempSync(join(tmpdir(), "vault-lock-roles-"));
  try {
    writeState(data, { origin: "https://stillfail.test", station: "st", workspace: WS, workspace_name: "W", name: "studio", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [] } as never);
    const c = new Cloud(data, false);
    const alice = person("alice"), bob = person("bob");
    personChainsOf(c).keep(alice.genesis, alice.chain, WS);
    personChainsOf(c).keep(bob.genesis, bob.chain, WS);
    seenDevicesOf(c).saw(1000, { workspace: WS, sub: "alice", email: "alice@x.com", role: "owner" }, alice.base.hex, alice.base.hex, { kind: "app" });
    seenDevicesOf(c).remember(WS, "bob", "bob@x.com", "admin");
    const lock = c.vaultLock(WS)!;
    assert.equal(lock.members.get("alice")?.role, "owner");
    assert.equal(lock.members.get("bob")?.role, "admin");

    const db = new DatabaseSync(":memory:");
    const vaults = new VaultStore(db);
    vaults.putBox(alice.cert());
    const getBoxes = vaultRoutes({ vaults, lock: () => c.vaultLock(WS), chains: (ws) => c.vaultChains(ws) })
      .find((x) => x.method === "GET" && x.pattern.test("/vault/boxes"))!;
    const ans = await getBoxes.handle({ method: "GET", path: "/vault/boxes", query: [], headers: {}, body: Buffer.alloc(0), viewer: { sub: "alice", workspace: WS, email: "alice@x.com", name: "Alice", role: "owner", device: alice.base.hex }, lang: "en" } as never, []);
    assert.equal(ans.status, 200);
    const parsed = JSON.parse(String(ans.body));
    assert.equal(parsed.boxes.length, 1);
    assert.deepEqual(parsed.roles, { alice: "owner", bob: "admin" });
    assert.deepEqual(parsed.chains.alice, alice.chain);
    assert.deepEqual(parsed.chains.bob, bob.chain);
    assert.deepEqual(personalVaultChains(WS, { chains: personChainsOf(c), members: seenDevicesOf(c) }).alice, alice.chain);

    // Role downgrade via mesh hello (`saw`) overrides stale `remember` role in `#viewers`.
    seenDevicesOf(c).saw(2000, { workspace: WS, sub: "bob", email: "bob@x.com", role: "member" }, bob.base.hex, bob.base.hex, { kind: "app" });
    assert.equal(seenDevicesOf(c).roles(WS).get("bob"), "member");
    assert.equal(c.vaultLock(WS)!.members.get("bob")?.role, "member");
    await Promise.all([personChainsOf(c).written(), seenDevicesOf(c).written()]);
    c.close();
  } finally {
    rmSync(data, { recursive: true, force: true });
  }
});

test("workspace vault agent tools: secret_use assigns to chat starter member, secret_list reports scope/vaultName, and secret_save defaults to personal vault", async () => {
  const alice = person("alice"), bob = person("bob");
  const roles = new Map([["alice", "owner"], ["bob", "member"]]);
  const s = {
    ...sources([alice, bob], { alice: "alice@x.com", bob: "bob@x.com" }),
  };
  (s.members as any).roles = () => roles;
  const owner = {};
  const db = new DatabaseSync(":memory:");
  const vaults = new VaultStore(db);
  const plain = new PlainStore(db);
  const cards: { text: string; card: any }[] = [];
  const notified: [string, string][] = [];
  const hub = {
    store: {
      getSession: (k: string) => (k === "s-bob" ? { key: "s-bob", ws: null, workspace: "/tmp", archivedAt: null } : null),
      starter: () => "bob@x.com",
      participants: (k: string) => new Map(k === "s-bob" ? [["s-bob", ["bob@x.com"]]] : []),
      latestThread: () => ({ connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } }),
      sessionThreadById: () => ({ connect: "c", thread: { id: 1, channel: "CHAT", threadTs: "1.0", surface: STILLFAIL_SURFACE } }),
      withdrawCard: () => true,
      restateCard: () => true,
      insertMessage: (m: { text: string; card: unknown }) => (cards.push({ text: m.text, card: m.card }), [cards.length]),
      pendingCardHeader: () => (cards.length === 0 ? null : [{ ts: String(cards.length) }, cards.at(-1)!.card]),
      subscribe: () => () => {},
    },
    chat: () => ({ post: async () => String(cards.length + 1) }),
    shared: () => {},
    notify: (k: string, text: string) => notified.push([k, text]),
  };
  const dir = mkdtempSync(join(tmpdir(), "vault-ws-tools-"));
  const getLock = () => personalVaultLock(owner, WS, s, heldBy(vaults));
  const secrets = new Secrets({ db: withoutUseReader(db), vaults, plain, home: () => WS, hub: hub as never, data: dir, lock: () => getLock(), now: () => 1_000_000 });
  const tools = vaultTools(secrets, () => dir);
  const callTool = (name: string, args: Record<string, unknown>) => tools.find((t) => t.name === name)!.run("s-bob", args);
  try {
    vaults.putBox(alice.cert());
    vaults.putBox(bob.cert());

    // secret_save schema must not expose a scope parameter (agents never pre-bind workspace vault).
    const saveSchema = tools.find((t) => t.name === "secret_save")!.inputSchema as { properties: Record<string, unknown> };
    assert.equal("scope" in saveSchema.properties, false);

    // Create a workspace vault owned by Alice with members [Alice, Bob], plus Bob's personal vault.
    const wsVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZW";
    const pVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZP";
    const wsVault: Vault = signed(
      {
        v: 1 as const, ws: WS, id: wsVaultId, seq: 0, owner: "alice", name: "Team Vault", scope: "workspace" as const,
        members: ["alice", "bob"], epoch: 0,
        keys: [
          { cert: alice.cert(), wrapped: seal(alice.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
          { cert: bob.cert(), wrapped: seal(bob.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
        ],
        at: 1000,
      },
      TAG.vault, alice.signer,
    );
    const pVault: Vault = signed(
      {
        v: 1 as const, ws: WS, id: pVaultId, seq: 0, owner: "bob", name: "Bob Personal",
        members: ["bob"], epoch: 0,
        keys: [{ cert: bob.cert(), wrapped: seal(bob.box.pub, fill(2), keyContext(WS, pVaultId, 0)) }],
        at: 1000,
      },
      TAG.vault, bob.signer,
    );
    vaults.putVault(wsVault);
    vaults.putVault(pVault);

    const wsItemId = "i_01HZZZZZZZZZZZZZZZZZZZZZZW";
    const pItemId = "i_01HZZZZZZZZZZZZZZZZZZZZZZP";
    const wsItem: Item = signed(
      { v: 1 as const, ws: WS, vault: wsVaultId, id: wsItemId, version: 0, epoch: 0, ct: "A".repeat(48), listing: { name: "Team API Key", kind: "token" as const, modes: ["env" as const], hosts: [] }, at: 1000 },
      TAG.item, alice.signer,
    );
    const pItem: Item = signed(
      { v: 1 as const, ws: WS, vault: pVaultId, id: pItemId, version: 0, epoch: 0, ct: "B".repeat(48), listing: { name: "My Key", kind: "token" as const, modes: ["env" as const], hosts: [] }, at: 1000 },
      TAG.item, bob.signer,
    );
    vaults.putItem(wsItem);
    vaults.putItem(pItem);

    // 1. secret_list reports scope and vaultName.
    const listed = JSON.parse(await callTool("secret_list", {}));
    const teamRow = listed.secrets.find((x: any) => x.item === wsItemId);
    const personalRow = listed.secrets.find((x: any) => x.item === pItemId);
    assert.equal(teamRow.scope, "workspace");
    assert.equal(teamRow.vaultName, "Team Vault");
    assert.equal(personalRow.scope, "personal");
    assert.equal(personalRow.vaultName, "Bob Personal");

    // 2. secret_use from Bob's chat for Alice's workspace vault secret assigns the card to Bob (not Alice), and Bob can approve.
    await callTool("secret_use", { item: "Team API Key", reason: "deploy" });
    assert.equal(cards.at(-1)!.card.assignee, "bob@x.com");
    const [useReq] = secrets.pending(WS, getLock(), { sub: "bob", email: "bob@x.com" });
    assert.equal(useReq?.vault, wsVaultId);
    const grant: Grant = signed(
      {
        v: 1 as const, ws: WS, request: useReq!.id, vault: wsVaultId, item: wsItemId, mode: "env" as const, hosts: [], scope: "once" as const, exp: 2000,
        secret: seal(useReq!.box, Buffer.from(JSON.stringify({ kind: "token", name: "Team API Key", fields: { value: "sec_123" } })), grantContext(WS, useReq!.id)),
        at: 1000,
      },
      TAG.grant, bob.signer,
    );
    assert.equal(secrets.grant(getLock(), "bob", grant), null);

    // 3. secret_save always defaults to Bob's personal vault (never pre-binds workspace vault, even if extra scope arg is passed).
    await callTool("secret_save", { name: "Shared Token", about: "CI token", kind: "token", reason: "shared", value: "tok_shared", scope: "workspace" });
    const [saveReq] = secrets.pending(WS, getLock(), { sub: "bob", email: "bob@x.com" });
    assert.equal(saveReq?.vault, pVaultId);
    assert.equal(saveReq?.save?.shared, undefined);
    assert.equal(saveReq?.save?.vaultName, undefined);
    assert.equal(cards.at(-1)!.card.vault.save.shared, undefined);
    assert.equal(cards.at(-1)!.card.vault.save.vaultName, undefined);
    // Sealed to Bob's own device (so Bob can approve and save to personal or manually pick workspace vault).
    assert.deepEqual(
      JSON.parse(Buffer.from(openSeal(bob.box.priv, saveReq!.sealed!.find((x) => x.box === bob.box.pub)!.secret, saveContext(WS, saveReq!.id))).toString()),
      { value: "tok_shared" },
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("non-security mode PUT /vault/vaults: owner/admin creates & copies workspace vault with unseen members; non-admin & security mode stay rejected", async () => {
  const alice = person("alice");
  const bob = person("bob");
  const dave = person("dave");
  const roles = new Map([["alice", "owner"], ["bob", "admin"], ["dave", "member"]]);
  const s = { ...sources([alice, bob, dave], { alice: "alice@x.com", bob: "bob@x.com", dave: "dave@x.com" }) };
  (s.members as any).roles = () => roles;

  const owner = {};
  const db = new DatabaseSync(":memory:");
  const vaults = new VaultStore(db);
  const getLock = () => personalVaultLock(owner, WS, s, heldBy(vaults));
  const routeList = vaultRoutes({ vaults, lock: () => getLock() });
  const putVault = routeList.find((x) => x.method === "PUT" && x.pattern.test("/vault/vaults"))!;
  const getVaults = routeList.find((x) => x.method === "GET" && x.pattern.test("/vault/vaults"))!;
  const viewerOf = (sub: string, role: string, dev: string) => ({ sub, workspace: WS, email: `${sub}@x.com`, name: sub, role, device: dev });

  const lockBefore = getLock();
  assert.equal(lockBefore.members.has("carol"), false, "carol has never connected to this station");

  const wsVaultId = "v_01HZZZZZZZZZZZZZZZZZZZZZZC";
  // 1. Ordinary member (dave) cannot create a workspace vault with unseen members.
  const forgedByMember: Vault = signed(
    {
      v: 1 as const, ws: WS, id: wsVaultId, seq: 0, owner: "dave", name: "Forged", scope: "workspace" as const,
      members: ["dave", "carol"], epoch: 0,
      keys: [{ cert: dave.cert(), wrapped: seal(dave.box.pub, fill(9), keyContext(WS, wsVaultId, 0)) }],
      at: 1000,
    },
    TAG.vault, dave.signer,
  );
  const memberRes = await putVault.handle({
    method: "PUT", path: "/vault/vaults", query: [], headers: {},
    body: Buffer.from(JSON.stringify(forgedByMember)), viewer: viewerOf("dave", "member", dave.base.hex), lang: "en",
  } as never, []);
  assert.equal(memberRes.status, 400);
  assert.equal(JSON.parse(String(memberRes.body)).code, "vault_invalid");

  // 2. Owner (alice) creates workspace vault including unseen member "carol".
  const wsVault0: Vault = signed(
    {
      v: 1 as const, ws: WS, id: wsVaultId, seq: 0, owner: "alice", name: "Team Vault", scope: "workspace" as const,
      members: ["alice", "bob", "carol"], epoch: 0,
      keys: [
        { cert: alice.cert(), wrapped: seal(alice.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
        { cert: bob.cert(), wrapped: seal(bob.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
      ],
      at: 1000,
    },
    TAG.vault, alice.signer,
  );
  const createRes = await putVault.handle({
    method: "PUT", path: "/vault/vaults", query: [], headers: {},
    body: Buffer.from(JSON.stringify(wsVault0)), viewer: viewerOf("alice", "owner", alice.base.hex), lang: "en",
  } as never, []);
  assert.equal(createRes.status, 200);
  // Original lock object was not mutated.
  assert.equal(lockBefore.members.has("carol"), false);
  // After write, vaults.version() incremented and personalVaultLock refreshes with carol as member while preserving roles.
  const lockAfter = getLock();
  assert.notEqual(lockAfter, lockBefore);
  assert.equal(lockAfter.members.get("carol")?.role, "member");
  assert.equal(lockAfter.members.get("alice")?.role, "owner");
  assert.equal(lockAfter.members.get("bob")?.role, "admin");
  // Carol sees the workspace vault via GET /vault/vaults.
  const carolGet = await getVaults.handle({
    method: "GET", path: "/vault/vaults", query: [], headers: {}, body: Buffer.alloc(0),
    viewer: viewerOf("carol", "member", ed().hex), lang: "en",
  } as never, []);
  assert.equal(carolGet.status, 200);
  assert.deepEqual(JSON.parse(String(carolGet.body)).vaults.map((v: Vault) => v.id), [wsVaultId]);

  // 3. Cross-station ?copy=1 onto a second station that has never seen carol (nor alice) succeeds when signed by admin bob.
  const s2 = { ...sources([bob], { bob: "bob@x.com" }) };
  (s2.members as any).roles = () => new Map([["bob", "admin"]]);
  const owner2 = {};
  const db2 = new DatabaseSync(":memory:");
  const vaults2 = new VaultStore(db2);
  const getLock2 = () => personalVaultLock(owner2, WS, s2, heldBy(vaults2));
  const putVault2 = vaultRoutes({ vaults: vaults2, lock: () => getLock2() }).find((x) => x.method === "PUT" && x.pattern.test("/vault/vaults"))!;
  const wsVault1: Vault = signed(
    {
      v: 1 as const, ws: WS, id: wsVaultId, seq: 1, owner: "alice", name: "Team Vault", scope: "workspace" as const,
      members: ["alice", "bob", "carol"], epoch: 0,
      keys: [{ cert: bob.cert(), wrapped: seal(bob.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) }],
      at: 1005,
    },
    TAG.vault, bob.signer,
  );
  const copyRes = await putVault2.handle({
    method: "PUT", path: "/vault/vaults", query: [["copy", "1"]], headers: {},
    body: Buffer.from(JSON.stringify(wsVault1)), viewer: viewerOf("bob", "admin", bob.base.hex), lang: "en",
  } as never, []);
  assert.equal(copyRes.status, 200);
  assert.equal(getLock2().members.get("carol")?.role, "member");
  assert.equal(getLock2().members.get("bob")?.role, "admin");

  // 4. Keys sealed to an unauthenticated device (carol's unknown device) are still rejected.
  const carol = person("carol");
  const badKeyVault: Vault = signed(
    {
      v: 1 as const, ws: WS, id: wsVaultId, seq: 1, owner: "alice", name: "Team Vault", scope: "workspace" as const,
      members: ["alice", "bob", "carol"], epoch: 0,
      keys: [
        { cert: alice.cert(), wrapped: seal(alice.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
        { cert: carol.cert(), wrapped: seal(carol.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) },
      ],
      at: 1006,
    },
    TAG.vault, alice.signer,
  );
  const badKeyRes = await putVault.handle({
    method: "PUT", path: "/vault/vaults", query: [], headers: {},
    body: Buffer.from(JSON.stringify(badKeyVault)), viewer: viewerOf("alice", "owner", alice.base.hex), lang: "en",
  } as never, []);
  assert.equal(badKeyRes.status, 400);
  assert.equal(JSON.parse(String(badKeyRes.body)).code, "vault_invalid");

  // 5. Security mode (l.genesis !== ""): unseen member is STILL strictly rejected with "member carol is not in the lock".
  const gEntry: Omit<Entry, "sig"> = {
    v: 1, ws: WS, seq: 0, prev: null, at: 1000, kind: "genesis",
    body: {
      ws: WS, owner: "alice", origins: ["https://app.still.fail"], rp_id: "still.fail", cloud_keys: { keys: [] },
      members: [{ sub: "alice", email: "alice@x.com", role: "owner" }],
      devices: [{ id: alice.base.hex, sub: "alice", kind: "app", label: "alice", sign_key: alice.signer.id }],
      passkeys: [], stations: [], gateways: [],
    },
  };
  const safeGenesis: Entry = { ...gEntry, sig: { key: alice.signer.id, alg: "Ed25519", sig: alice.signer.sign(lockBytes(entryHash(gEntry as Entry))) } };
  const safeLock = makeGenesis(safeGenesis);
  assert.notEqual(safeLock.genesis, "");
  const safeDb = new DatabaseSync(":memory:");
  const safeVaults = new VaultStore(safeDb);
  const safePut = vaultRoutes({ vaults: safeVaults, lock: () => safeLock }).find((x) => x.method === "PUT" && x.pattern.test("/vault/vaults"))!;
  const safeWsVault: Vault = signed(
    {
      v: 1 as const, ws: WS, id: wsVaultId, seq: 0, owner: "alice", name: "Safe Team", scope: "workspace" as const,
      members: ["alice", "carol"], epoch: 0,
      keys: [{ cert: alice.cert(), wrapped: seal(alice.box.pub, fill(1), keyContext(WS, wsVaultId, 0)) }],
      at: 1000,
    },
    TAG.vault, alice.signer,
  );
  const safeRes = await safePut.handle({
    method: "PUT", path: "/vault/vaults", query: [], headers: {},
    body: Buffer.from(JSON.stringify(safeWsVault)), viewer: viewerOf("alice", "owner", alice.base.hex), lang: "en",
  } as never, []);
  assert.equal(safeRes.status, 400);
  assert.match(JSON.parse(String(safeRes.body)).error, /member carol is not in the lock/);
});
