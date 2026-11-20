import assert from "node:assert/strict";
import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { Announcements, announcementOf } from "../src/mesh/announcements.ts";
import type { MeshDescriptor } from "../src/mesh/endpoint.ts";
const scope = "ab".repeat(32);
const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, 70)]), format: "der", type: "pkcs8" });
const node = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
const signer = { id: node, sign: (text: string) => sign(null, Buffer.from(text), privateKey).toString("hex") };
const allowed = new Set([node]);
function descriptor(port = 1234, identity = { node, privateKey }, scopeValue = scope, generationValue = 1): MeshDescriptor {
  const { node: identityNode, privateKey: identityKey } = identity;
  const generation = Buffer.alloc(8); generation.writeBigUInt64BE(BigInt(generationValue));
  const binding = { policy: [...Buffer.alloc(32)], scope: [...Buffer.from(scopeValue, "hex")], endpoint: [...Buffer.from(identityNode, "hex")], neighbor: [...Buffer.alloc(32, 71)], generation: generationValue, transit: true, signature: [] as number[] };
  binding.signature = [...sign(null, Buffer.concat([Buffer.from("mesh-neighbor-binding/v2\0"), Buffer.from(binding.scope), Buffer.from(binding.policy), Buffer.from(binding.endpoint), Buffer.from(binding.neighbor), generation, Buffer.from([1])]), identityKey)];
  return { binding, address: { id: Buffer.from(binding.neighbor).toString("hex"), addrs: [{ Ip: `127.0.0.1:${port}` }] } };
}
test("signed directory rejects tampering, foreign scopes, and removed identities", () => {
  const db = new DatabaseSync(":memory:");
  try {
    assert.throws(() => new Announcements(db).publish(scope, descriptor(1234, { node, privateKey }, scope, 0), signer), /invalid scoped mesh binding/);
    const signed = new Announcements(db).publish(scope, descriptor(), signer);
    assert.equal(announcementOf(signed, scope, allowed).node, node);
    assert.throws(() => announcementOf(signed, "cd".repeat(32), allowed), /outside/);
    assert.throws(() => announcementOf(signed, scope, new Set()), /outside/);
    assert.throws(() => announcementOf({ ...signed, body: signed.body.replace("1234", "1235") }, scope, allowed), /signature/);
    const recursive = descriptor();
    recursive.address = { id: "47".repeat(32), addrs: [{ Custom: { id: 1 } }] };
    assert.throws(() => new Announcements(db).publish(scope, recursive, signer), /underlay/);
    const changed = descriptor(); changed.binding.transit = false;
    assert.throws(() => new Announcements(db).publish(scope, changed, signer), /binding signature/);
  } finally { db.close(); }
});
test("address revisions survive recreation and delayed announcements cannot roll them back", () => {
  const source = new DatabaseSync(":memory:"), target = new DatabaseSync(":memory:");
  try {
    const registry = new Announcements(source), recipient = new Announcements(target);
    const first = registry.publish(scope, descriptor(), signer);
    assert.deepEqual(new Announcements(source).publish(scope, descriptor(), signer), first);
    const next = new Announcements(source).publish(scope, descriptor(1235), signer);
    assert.equal(announcementOf(next, scope, allowed).revision, 2);
    assert.equal(recipient.take(next, scope, allowed), true);
    assert.equal(recipient.take(first, scope, allowed), false);
    assert.equal(recipient.take(next, scope, allowed), false);
    assert.deepEqual(recipient.list(scope, allowed), [next]);
    assert.deepEqual(recipient.list(scope, new Set()), []);
    assert.throws(() => recipient.take(first, scope, new Set(Array.from({ length: 257 }, (_, i) => String(i)))), /too many/);
  } finally { source.close(); target.close(); }
});

test("global bootstrap records configure native scopes without entering workspace announcements", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const { globalRelaysOf } = await import("../src/mesh/global-relays.ts");
  const db = new DatabaseSync(":memory:");
  const configs: any[] = [];
  const global = { node: "cd".repeat(32), name: "global", generation: 2, revision: 3,
    address: { id: "cd".repeat(32), addrs: [{ Ip: "127.0.0.1:4567" }] } };
  const endpoint = { meshConfigure: async (value: unknown) => { configs.push(value); return descriptor(); }, meshRemove: async () => {} } as any;
  const directory = new ScopeDirectory(endpoint, new Announcements(db), signer, () => {}, e => { throw e; });
  try {
    const roster = { scope, nodes: allowed, relayUrls: [], transit: true };
    await directory.set([{ ...roster, globalRelays: [global] }]);
    assert.deepEqual(configs.at(-1).globalRelays, [global]);
    assert.deepEqual(directory.policy(scope).nodes, [node]);
    assert.deepEqual(directory.policy(scope).globalRelays, [global]);
    const copied = directory.policy(scope); copied.globalRelays[0]!.generation = 99;
    assert.equal(directory.policy(scope).globalRelays[0]!.generation, 2, "relay policy cannot mutate the live roster");
    assert.ok(directory.records(scope).every(a => JSON.parse(a.body).node === node));
    await directory.set([roster]);
    assert.deepEqual(configs.at(-1).globalRelays, []);
    assert.deepEqual(directory.policy(scope).globalRelays, []);
    assert.throws(() => globalRelaysOf([global, global]), /invalid/);
    assert.throws(() => globalRelaysOf([{ ...global, address: { ...global.address, addrs: [{ Custom: {} }] } }]), /recursive/);
    assert.throws(() => directory.set([{ ...roster, globalRelays: [{ ...global, node, address: { ...global.address, id: node } }] }]), /conflicting/);
    assert.deepEqual(globalRelaysOf(undefined), []);
  } finally { directory.close(); db.close(); }
});

test("scope removal wins over an in-flight native configure", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const db = new DatabaseSync(":memory:");
  let finish!: (value: MeshDescriptor) => void;
  let started!: () => void;
  const configuring = new Promise<void>((resolve) => { started = resolve; });
  const removed: string[] = [], announced: string[] = [];
  const endpoint = {
    meshConfigure: () => { started(); return new Promise<MeshDescriptor>((resolve) => { finish = resolve; }); },
    meshRemove: async (s: string) => { removed.push(s); },
  } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const directory = new ScopeDirectory(endpoint, new Announcements(db), signer, (s) => announced.push(s), (error) => { throw error; });
  try {
    const adding = directory.set([{ scope, nodes: allowed, transit: true, relayUrls: [] }]);
    await configuring;
    const removing = directory.set([]);
    finish(descriptor());
    await Promise.all([adding, removing]);
    assert.deepEqual(removed, [scope]);
    assert.deepEqual(announced, [], "late completion must not publish a removed scope");
    assert.deepEqual(directory.records(scope), []);
  } finally { directory.close(); db.close(); }
});

test("unacknowledged scope creation is removed and inherited stale scopes are reconciled", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const db = new DatabaseSync(":memory:");
  const removed: string[] = [];
  let unsubscribed = false;
  const inherited = "cd".repeat(32);
  const endpoint = {
    meshListen: (f: (s: { scope: string; descriptor: MeshDescriptor }[]) => void) => {
      f([{ scope: inherited, descriptor: descriptor() }]);
      return () => { unsubscribed = true; };
    },
    meshConfigure: async () => { throw new Error("ack lost"); },
    meshRemove: async (s: string) => { removed.push(s); },
  } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const directory = new ScopeDirectory(endpoint, new Announcements(db), signer, () => {}, (error) => { throw error; });
  try {
    await assert.rejects(directory.set([{ scope, nodes: allowed, transit: true, relayUrls: [] }]), /ack lost/);
    await directory.set([]);
    assert.deepEqual(removed, [inherited, scope]);
  } finally { directory.close(); db.close(); }
  assert.equal(unsubscribed, true);
});

test("directory exchange is paged below the peer message limit and rechecks membership", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const db = new DatabaseSync(":memory:");
  const endpoint = {
    meshConfigure: async () => descriptor(), meshRemove: async () => {},
  } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const directory = new ScopeDirectory(endpoint, new Announcements(db), signer, () => {}, (error) => { throw error; });
  try {
    await directory.set([{ scope, nodes: allowed, transit: true, relayUrls: [] }]);
    const summary = await directory.exchange(scope, {});
    assert.deepEqual(summary, { versions: { [node]: 1 }, records: [] });
    const page = await directory.exchange(scope, { want: [node] });
    assert.equal(page.records.length, 1);
    await assert.rejects(directory.exchange(scope, { want: Array(17).fill(node) }), /invalid/);
    await assert.rejects(directory.exchange(scope, { want: ["cd".repeat(32)] }), /invalid/);
    await directory.set([]);
    await assert.rejects(directory.exchange(scope, { want: [node] }), /invalid/);
  } finally { directory.close(); db.close(); }
});

test("signed announcements reach A through B without accepting another workspace", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const { exchangeScope } = await import("../src/mesh/scope-exchange.ts");
  const identities = [80, 81, 82].map((seed) => {
    const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, seed)]), format: "der", type: "pkcs8" });
    const node = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
    return { node, privateKey };
  });
  const nodes = new Set(identities.map((i) => i.node));
  const dbs = identities.map(() => new DatabaseSync(":memory:"));
  const dirs = identities.map((identity, i) => new ScopeDirectory({
    meshConfigure: async () => descriptor(1234 + i, identity), meshRemove: async () => {},
  } as unknown as import("../src/mesh/endpoint.ts").Endpoint, new Announcements(dbs[i]!), {
    id: identity.node, sign: (text) => sign(null, Buffer.from(text), identity.privateKey).toString("hex"),
  }, () => {}, (error) => { throw error; }));
  try {
    await Promise.all(dirs.map((d) => d.set([{ scope, nodes, transit: true, relayUrls: [] }])));
    await exchangeScope(dirs[1]!, scope, (request) => dirs[2]!.exchange(scope, request));
    await exchangeScope(dirs[0]!, scope, (request) => dirs[1]!.exchange(scope, request));
    assert.deepEqual(new Set(dirs[0]!.records(scope).map((r) => JSON.parse(r.body).node)), nodes);
    await assert.rejects(exchangeScope(dirs[0]!, scope, async () => ({ versions: { [node]: 1 }, records: [new Announcements(dbs[2]!).publish(scope, descriptor(), signer)] })), /unsolicited/);
    await assert.rejects(dirs[0]!.exchange("ef".repeat(32), {}), /invalid/);
  } finally { dirs.forEach((d) => d.close()); dbs.forEach((d) => d.close()); }
});

test("app.monoid.build and app.still.fail name one workspace's scope; another origin does not", async () => {
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const workspace = "01M3HNG540559HJG7H4RCWW0TE";
  const still = workspaceScope("https://app.still.fail", workspace);
  assert.equal(workspaceScope("https://app.monoid.build", workspace), still);
  assert.equal(workspaceScope("https://app.monoid.build/", workspace), still);
  assert.equal(workspaceScope("https://app.still.fail//", workspace), still);
  assert.notEqual(workspaceScope("https://example.test", workspace), still);
  assert.notEqual(workspaceScope("https://app.monoid.build", "other"), still);
});

test("a node on the peer's roster and not yet on this one's is not asked for, and the rest still comes level", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const { exchangeScope } = await import("../src/mesh/scope-exchange.ts");
  const identities = [90, 91, 92].map((seed) => {
    const privateKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, seed)]), format: "der", type: "pkcs8" });
    const node = createPublicKey(privateKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
    return { node, privateKey };
  });
  const dbs = identities.map(() => new DatabaseSync(":memory:"));
  const dirs = identities.map((identity, i) => new ScopeDirectory({
    meshConfigure: async () => descriptor(1300 + i, identity), meshRemove: async () => {},
  } as unknown as import("../src/mesh/endpoint.ts").Endpoint, new Announcements(dbs[i]!), {
    id: identity.node, sign: (text) => sign(null, Buffer.from(text), identity.privateKey).toString("hex"),
  }, () => {}, (error) => { throw error; }));
  try {
    const every = new Set(identities.map((i) => i.node));
    // B has C on its roster already; A does not yet (their rosters briefly differ).
    await dirs[0]!.set([{ scope, nodes: new Set([identities[0]!.node, identities[1]!.node]), transit: true, relayUrls: [] }]);
    await dirs[1]!.set([{ scope, nodes: every, transit: true, relayUrls: [] }]);
    await dirs[2]!.set([{ scope, nodes: every, transit: true, relayUrls: [] }]);
    await exchangeScope(dirs[1]!, scope, (request) => dirs[2]!.exchange(scope, request));
    assert.ok(dirs[0]!.admits(scope, identities[1]!.node));
    assert.equal(dirs[0]!.admits(scope, identities[2]!.node), false);
    const wanted: string[][] = [];
    await exchangeScope(dirs[0]!, scope, (request) => {
      if (request.want) wanted.push(request.want);
      return dirs[1]!.exchange(scope, request);
    });
    assert.deepEqual(wanted, [[identities[1]!.node]]);
    assert.deepEqual(new Set(dirs[0]!.records(scope).map((r) => JSON.parse(r.body).node)), new Set([identities[0]!.node, identities[1]!.node]));
    assert.deepEqual(new Set(dirs[1]!.records(scope).map((r) => JSON.parse(r.body).node)), every);
  } finally { dirs.forEach((d) => d.close()); dbs.forEach((d) => d.close()); }
});

test("off-thread directory hydration cannot overwrite a newer live announcement", async () => {
  const source = new DatabaseSync(":memory:"), target = new DatabaseSync(":memory:");
  let finish!: (records: import("../src/mesh/announcements.ts").Announcement[]) => void;
  try {
    const origin = new Announcements(source);
    const old = origin.publish(scope, descriptor(), signer);
    const next = origin.publish(scope, descriptor(1235), signer);
    const recipient = new Announcements(target, async (_scope, nodes) => {
      assert.deepEqual(nodes, [node]);
      return new Promise((resolve) => { finish = resolve; });
    });
    const loading = recipient.load(scope, allowed);
    recipient.take(next, scope, allowed);
    finish([old]); await loading;
    assert.deepEqual(recipient.list(scope, allowed), [next]);
    recipient.retain(new Map());
    assert.deepEqual(recipient.list(scope, allowed), []);
  } finally { source.close(); target.close(); }
});

test("a late persisted read cannot repopulate a removed scope", async () => {
  const db = new DatabaseSync(":memory:");
  let finish!: (records: import("../src/mesh/announcements.ts").Announcement[]) => void;
  try {
    const record = new Announcements(db).publish(scope, descriptor(), signer);
    const cache = new Announcements(db, () => new Promise((resolve) => { finish = resolve; }));
    const loading = cache.load(scope, allowed);
    cache.retain(new Map());
    finish([record]); await loading;
    assert.deepEqual(cache.list(scope, allowed), []);
  } finally { db.close(); }
});

test("failed native scope application retries once and a healthy scope does not poll", async () => {
  const { ScopeSync } = await import("../src/mesh/scope-sync.ts");
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const data = mkdtempSync(join(tmpdir(), "mesh-scope-sync-"));
  const db = new DatabaseSync(":memory:");
  const workspace = "ws", origin = "https://example.test";
  const scopes = workspaceScope(origin, workspace);
  const listeners = new Set<() => void>();
  const cloud = { data, peersCurrent: true, state: { origin, station: node }, relays: () => [], waysSaid: () => null,
    memberships: () => [{ workspace, peers: [] }], membership: (ws: string) => ws === workspace ? { workspace, peers: [] } : null, listen: (f: () => void) => { listeners.add(f); return () => { listeners.delete(f); }; },
  } as unknown as import("../src/cloud/state.ts").Cloud;
  let retry!: () => void;
  let tellRetry!: () => void;
  const scheduled = new Promise<void>((resolve) => { tellRetry = resolve; });
  const waits: number[] = [];
  let attempts = 0;
  const endpoint = { meshConfigure: async () => {
    if (++attempts === 1) throw new Error("front disconnected");
    return descriptor(1234, { node, privateKey }, scopes);
  }, meshRemove: async () => {} } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const sync = new ScopeSync(endpoint, db, cloud, signer, async () => { throw new Error("no peers"); }, async (args: any) => JSON.stringify(args.kind === "relayRecords" ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope) : []), {
    after: (ms, f) => { waits.push(ms); retry = () => { f(); }; tellRetry(); return () => {}; }, close: async () => {},
  });
  try {
    await scheduled;
    assert.deepEqual(waits, [1000]);
    retry();
    await sync.directory.reconcile();
    assert.equal(attempts, 2);
    assert.equal(sync.directory.ready(scopes, node), true);
    await sync.directory.reconcile();
    assert.deepEqual(waits, [1000], "no healthy polling timer");
    assert.equal(attempts, 2);
    const { signRelayRecord } = await import("../src/mesh/relay-records.ts");
    const relay = "03".repeat(32);
    const { RelayEnrollment } = await import("../src/mesh/enrollment.ts");
    const registry = new RelayEnrollment(db, node, () => 1000);
    const token = registry.issue(scopes, "relay", "member");
    const registration = registry.redeem(scopes, token.token, relay);
    await sync.registration(signRelayRecord(registration, signer.sign));
    assert.equal(sync.directory.ready(scopes, relay), true);
    assert.equal((sync.relays(workspace)[0] as any).revoked, 0);
    const revoked = await sync.revoke(workspace, relay);
    assert.equal(JSON.parse(revoked.body).generation, 2);
    assert.equal((sync.relays(workspace)[0] as any).revoked, 1);
    assert.deepEqual(await sync.revoke(workspace, relay), revoked, "repeat revoke is idempotent");
    await assert.rejects(sync.answer("ff".repeat(32), workspace, { method: "meshRelays.revoke", node: relay }), /membership/);
    assert.equal(sync.directory.ready(scopes, relay), false);
    await sync.registration(signRelayRecord(registration, signer.sign));
    assert.equal(sync.directory.ready(scopes, relay), false, "old grant cannot restore a revoked route target");
  } finally { await sync.close(); db.close(); rmSync(data, { recursive: true, force: true }); }
  assert.equal(listeners.size, 0);
});

// A front from before the mesh operations (launcher STREAMS 4) answers every meshConfigure so: no retry makes it take
// one. The launcher is asked once to start the release's front, and no retry timer is set, with a launcher or without.
for (const launcher of [true, false]) test(`a front from before meshConfigure ${launcher ? "is restarted once" : "is said once"} and never retried on a timer`, async () => {
  const { ScopeSync } = await import("../src/mesh/scope-sync.ts");
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const { RelayEnrollment } = await import("../src/mesh/enrollment.ts");
  const { signRelayRecord } = await import("../src/mesh/relay-records.ts");
  const { hearLines } = await import("../src/ops/log.ts");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const data = mkdtempSync(join(tmpdir(), "mesh-old-front-"));
  const db = new DatabaseSync(":memory:");
  const workspace = "ws", origin = "https://example.test";
  const scopes = workspaceScope(origin, workspace);
  const cloud = { data, peersCurrent: true, state: { origin, station: node }, relays: () => [], waysSaid: () => null,
    memberships: () => [{ workspace, peers: [] }], membership: (ws: string) => ws === workspace ? { workspace, peers: [] } : null, listen: () => () => {},
  } as unknown as import("../src/cloud/state.ts").Cloud;
  const said: string[] = [];
  let tellSaid!: () => void;
  const toldOld = new Promise<void>((resolve) => { tellSaid = resolve; });
  hearLines((l) => { if (l.at !== "mesh") return; said.push(l.message); if (/before meshConfigure/.test(l.message)) tellSaid(); });
  let attempts = 0, restarts = 0;
  const waits: number[] = [];
  const endpoint = { meshConfigure: async () => { attempts++; throw new Error("no operation meshConfigure"); }, meshRemove: async () => {} } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const sync = new ScopeSync(endpoint, db, cloud, signer, async () => { throw new Error("no peers"); },
    async (args: any) => JSON.stringify(args.kind === "relayRecords" ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope) : []),
    { after: (ms) => { waits.push(ms); return () => {}; }, close: async () => {} }, launcher ? () => { restarts++; } : undefined);
  try {
    await toldOld;
    // the roster changed again (a relay registered): tried once more, still refused, nothing more said or asked
    const registry = new RelayEnrollment(db, node, () => 1000);
    const token = registry.issue(scopes, "relay", "member");
    await sync.registration(signRelayRecord(registry.redeem(scopes, token.token, "03".repeat(32)), signer.sign));
    assert.equal(attempts, 2);
    assert.equal(restarts, launcher ? 1 : 0);
    assert.deepEqual(waits, [], "no retry timer");
    assert.deepEqual(said.filter((m) => /before meshConfigure|mesh directory update failed/.test(m)).length, 1, JSON.stringify(said));
  } finally { hearLines(null); await sync.close(); db.close(); rmSync(data, { recursive: true, force: true }); }
});

// A peer's exchange takes its records to the front too: refused so, it is not tried again on a timer either.
test("a front from before meshConfigure is not retried by a peer's directory exchange", async () => {
  const { ScopeSync } = await import("../src/mesh/scope-sync.ts");
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const { hearLines } = await import("../src/ops/log.ts");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const data = mkdtempSync(join(tmpdir(), "mesh-old-front-peer-"));
  const db = new DatabaseSync(":memory:"), theirs = new DatabaseSync(":memory:");
  const peerKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, 76)]), format: "der", type: "pkcs8" });
  const peer = createPublicKey(peerKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  const peerSigner = { id: peer, sign: (text: string) => sign(null, Buffer.from(text), peerKey).toString("hex") };
  const workspace = "ws", origin = "https://example.test";
  const scopes = workspaceScope(origin, workspace);
  const membership = { workspace, peers: [{ id: peer }] };
  const cloud = { data, peersCurrent: true, state: { origin, station: node }, relays: () => [], waysSaid: () => null,
    memberships: () => [membership], membership: (ws: string) => ws === workspace ? membership : null, listen: () => () => {},
  } as unknown as import("../src/cloud/state.ts").Cloud;
  // the peer's announcement, then a newer one it tells of when this station's exchange asks
  const kept = new Announcements(theirs);
  const first = kept.publish(scopes, descriptor(2001, { node: peer, privateKey: peerKey }, scopes), peerSigner);
  const newer = kept.publish(scopes, descriptor(2002, { node: peer, privateKey: peerKey }, scopes), peerSigner);
  let tellOld!: () => void;
  const toldOld = new Promise<void>((resolve) => { tellOld = resolve; });
  const said: string[] = [];
  hearLines((l) => { if (l.at !== "mesh") return; said.push(l.message); if (/before meshConfigure/.test(l.message)) tellOld(); });
  let attempts = 0, restarts = 0, tellThird!: () => void;
  const third = new Promise<void>((resolve) => { tellThird = resolve; });
  const waits: number[] = [];
  const endpoint = { meshConfigure: async () => { if (++attempts === 3) tellThird(); throw new Error("no operation meshConfigure"); }, meshRemove: async () => {} } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const sync = new ScopeSync(endpoint, db, cloud, signer, async (_target, _ws, request: any) => {
    if (request.method === "meshRelays.exchange") return { versions: {}, records: [] };
    return { versions: { [peer]: 2 }, records: request.want ? [newer] : [] };
  }, async (args: any) => JSON.stringify(args.kind === "relayRecords" ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope) : []),
  { after: (ms) => { waits.push(ms); return () => {}; }, close: async () => {} }, () => { restarts++; });
  try {
    await toldOld;
    // the peer gives its first announcement: kept (the exchange with it starts), then refused by the front
    await assert.rejects(sync.answer(peer, workspace, { method: "meshScopes.exchange", give: [first] }), /no operation meshConfigure/);
    // the exchange takes the newer one to the front: refused there as well
    await third;
    // what follows the third refusal is the promises it rejects, settled before the next turn of the loop
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(attempts, 3);
    assert.equal(restarts, 1);
    assert.deepEqual(waits, [], "no retry timer, of the roster or of the exchange");
    assert.equal(said.filter((m) => /before meshConfigure|mesh directory update failed/.test(m)).length, 1, JSON.stringify(said));
  } finally { hearLines(null); await sync.close(); db.close(); theirs.close(); rmSync(data, { recursive: true, force: true }); }
});

// A peer that does not answer the exchange is the workspace's ordinary state (a station that is off, one from before
// it), not this station's failure: said at INFO and tried again as ways.ts tries a peer, or not at all for one from
// before. This station's own directory failing is still a WARN, tried again within a minute.
async function peerExchange(answer: (request: any) => Promise<unknown>, meshConfigure?: () => Promise<MeshDescriptor>) {
  const { ScopeSync } = await import("../src/mesh/scope-sync.ts");
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const { hearLines } = await import("../src/ops/log.ts");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const data = mkdtempSync(join(tmpdir(), "mesh-peer-exchange-"));
  const db = new DatabaseSync(":memory:");
  const peer = "05".repeat(32);
  const workspace = "ws", origin = "https://example.test";
  const scopes = workspaceScope(origin, workspace);
  const membership = { workspace, peers: [{ id: peer }] };
  const cloud = { data, peersCurrent: true, state: { origin, station: node }, relays: () => [], waysSaid: () => null,
    memberships: () => [membership], membership: (ws: string) => ws === workspace ? membership : null, listen: () => () => {},
  } as unknown as import("../src/cloud/state.ts").Cloud;
  const said: { level: string; message: string }[] = [];
  hearLines((l) => { if (l.at === "mesh") said.push({ level: l.level, message: l.message }); });
  const waits: number[] = [];
  const due: (() => void)[] = [];
  let calls = 0, tell = () => {};
  const endpoint = { meshConfigure: meshConfigure ?? (async () => descriptor(1234, { node, privateKey }, scopes)), meshRemove: async () => {} } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const sync = new ScopeSync(endpoint, db, cloud, signer, async (_target, _ws, request: any) => { calls++; return answer(request); },
    async (args: any) => JSON.stringify(args.kind === "relayRecords" ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope) : []),
    { after: (ms, f) => { waits.push(ms); due.push(f); tell(); return () => {}; }, close: async () => {} });
  // until `n` timers are set (the loop's turns its promises settle in, not time)
  const timers = async (n: number) => {
    for (let turns = 0; waits.length < n; turns++) {
      if (turns > 200) throw new Error(`waited for timer ${n}, set: ${JSON.stringify(waits)}`);
      await new Promise<void>((resolve) => { tell = resolve; setImmediate(resolve); });
    }
  };
  const settled = async () => { for (let i = 0; i < 8; i++) await new Promise<void>((resolve) => setImmediate(resolve)); };
  const close = async () => { hearLines(null); await sync.close(); db.close(); rmSync(data, { recursive: true, force: true }); };
  return { sync, said, waits, due, calls: () => calls, timers, settled, close };
}
const updateFailed = (said: { level: string; message: string }[]) => said.filter((l) => l.level === "WARN" && /mesh directory update failed/.test(l.message));

test("a peer from before the directory exchange is not tried again on a timer, and is no warning", async () => {
  for (const refusal of ["session and task key are required (at most 256 / 128 bytes)", "unsupported peer method meshRelays.exchange"]) {
    const t = await peerExchange(async () => { throw new Error(refusal); });
    try {
      await t.settled();
      assert.equal(t.calls(), 1, refusal);
      assert.deepEqual(t.waits, [], `no retry timer: ${refusal}`);
      assert.deepEqual(updateFailed(t.said), [], JSON.stringify(t.said));
    } finally { await t.close(); }
  }
});

test("a peer that does not answer is said at INFO and tried again from 5 s, doubling to 10 min", async () => {
  const t = await peerExchange(async () => { throw new Error("peer request timed out; execution may have happened — query the same task key"); });
  try {
    const expected = [5_000, 10_000, 20_000, 40_000, 80_000, 160_000, 320_000, 600_000, 600_000];
    for (let i = 0; i < expected.length; i++) {
      await t.timers(i + 1);
      if (i + 1 < expected.length) t.due[i]!();
    }
    assert.deepEqual(t.waits, expected);
    assert.equal(t.calls(), expected.length);
    assert.deepEqual(updateFailed(t.said), [], JSON.stringify(t.said));
    assert.equal(t.said.filter((l) => l.level === "INFO" && l.message === "a station's mesh directory was not brought level").length, expected.length);
  } finally { await t.close(); }
});

test("this station's own directory failing is still a warning, tried again from 1 s up to a minute", async () => {
  const t = await peerExchange(async () => ({ versions: {}, records: [] }), async () => { throw new Error("ack lost"); });
  try {
    const expected = [1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000];
    for (let i = 0; i < expected.length; i++) {
      await t.timers(i + 1);
      if (i + 1 < expected.length) t.due[i]!();
    }
    assert.deepEqual(t.waits, expected);
    assert.equal(updateFailed(t.said).length, expected.length, JSON.stringify(t.said));
  } finally { await t.close(); }
});

test("Node and Rust verify the same signed address fixture", async () => {
  const { readFile } = await import("node:fs/promises");
  const record = JSON.parse(await readFile(new URL("../../libs/mesh-transport/tests/fixtures/announcement.json", import.meta.url), "utf8"));
  const value = JSON.parse(record.body);
  assert.equal(announcementOf(record, value.scope, new Set([value.node]), 3).revision, 7);
  assert.throws(() => announcementOf(record, value.scope, new Set([value.node]), 4), /binding/);
});

test("re-enrollment cannot reuse an address binding from the revoked generation", async () => {
  const { ScopeDirectory } = await import("../src/mesh/scope-directory.ts");
  const db = new DatabaseSync(":memory:");
  const records = new Announcements(db);
  const old = records.publish(scope, descriptor(), signer);
  const directory = new ScopeDirectory({} as import("../src/mesh/endpoint.ts").Endpoint, records, signer, () => {}, (error) => { throw error; });
  try {
    await directory.set([{ scope, nodes: allowed, generations: new Map([[node, 2]]), transit: false, relayUrls: [] }]);
    assert.deepEqual(directory.records(scope), []);
    assert.throws(() => directory.take(scope, [old]), /binding/);
  } finally { directory.close(); db.close(); }
});

test("remote relay revocation verifies the issuing station and exact target before applying", async () => {
  const { ScopeSync } = await import("../src/mesh/scope-sync.ts");
  const { workspaceScope } = await import("../src/mesh/enrollment-door.ts");
  const { signRelayRecord } = await import("../src/mesh/relay-records.ts");
  const { mkdtempSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const data = mkdtempSync(join(tmpdir(), "mesh-revoke-"));
  const db = new DatabaseSync(":memory:");
  const remoteKey = createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, 75)]), format: "der", type: "pkcs8" });
  const remote = createPublicKey(remoteKey).export({ format: "der", type: "spki" }).subarray(-32).toString("hex");
  const remoteSign = (text: string) => sign(null, Buffer.from(text), remoteKey).toString("hex");
  const workspace = "ws", origin = "https://example.test", relay = "03".repeat(32);
  const scoped = workspaceScope(origin, workspace);
  const membership = { workspace, peers: [{ id: remote }] };
  const cloud = { data, peersCurrent: true, state: { origin, station: node }, relays: () => [], waysSaid: () => null,
    memberships: () => [membership], membership: (ws: string) => ws === workspace ? membership : null, listen: () => () => {},
  } as unknown as import("../src/cloud/state.ts").Cloud;
  const endpoint = { meshConfigure: async () => descriptor(1234, { node, privateKey }, scoped), meshRemove: async () => {} } as unknown as import("../src/mesh/endpoint.ts").Endpoint;
  const record = { scope: scoped, node: relay, issuer: remote, generation: 1, name: "edge", made_by: "test", revoked: 0 };
  let response = signRelayRecord({ ...record, node: "04".repeat(32), generation: 2, revoked: 1 }, remoteSign);
  const requests: unknown[] = [];
  const sync = new ScopeSync(endpoint, db, cloud, signer, async (target, ws, request: any) => {
    if (request.method !== "meshRelays.revoke") throw new Error("unknown method");
    requests.push([target, ws, request]);
    return response;
  }, async (args: any) => JSON.stringify(args.kind === "relayRecords" ? db.prepare("SELECT body,signature FROM mesh_relay_records WHERE scope=?").all(args.scope) : []), { after: () => () => {}, close: async () => {} });
  try {
    await sync.registration(signRelayRecord(record, remoteSign));
    assert.equal(sync.directory.ready(scoped, relay), true);
    await assert.rejects(sync.revoke(workspace, relay), /invalid relay revocation reply/);
    assert.equal(sync.directory.ready(scoped, relay), true);
    response = signRelayRecord({ ...record, generation: 2, revoked: 1 }, signer.sign);
    await assert.rejects(sync.revoke(workspace, relay), /signature/);
    assert.equal(sync.directory.ready(scoped, relay), true);
    response = signRelayRecord({ ...record, generation: 2, revoked: 1 }, remoteSign);
    await sync.revoke(workspace, relay);
    assert.equal(sync.directory.ready(scoped, relay), false);
    assert.deepEqual(requests, Array.from({ length: 3 }, () => [remote, workspace, { method: "meshRelays.revoke", node: relay }]));
    await assert.rejects(sync.answer(remote, workspace, { method: "meshRelays.revoke", node: relay }), /issuing station/);
  } finally { await sync.close(); db.close(); rmSync(data, { recursive: true, force: true }); }
});
