// The workspace lock as still.fail cloud keeps it (src/lock.ts): one chain, each entry following
// the last and signed by whom it may be, as a station checks it (station/test/lock.test.ts tests those rules); carried
// to the stations on their presence sockets and to members; the devices that asked for credentials, for the owner to
// check; devices waiting to be confirmed.
import assert from "node:assert/strict";
import test from "node:test";
import { LockAppendRefused, canonical, entryHash, extendLock, shortCode, type LockEntry } from "../src/lock.ts";
import { harness } from "./harness.ts";
import { signer } from "./lock-signer.ts";

const hex = (bytes: ArrayBuffer) => Buffer.from(bytes).toString("hex");

async function key() {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const id = hex((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const sign = async (message: string) => hex(await crypto.subtle.sign("Ed25519", pair.privateKey, new TextEncoder().encode(message)));
  return { id, sign };
}

test("the hash is the stations' and the core's (the same values in their tests)", async () => {
  const e = { v: 1, ws: "01HZZZZZZZZZZZZZZZZZZZZZZZ", seq: 3, prev: "ab".repeat(32), at: 1700000000, kind: "device", body: { sub: "s", id: "cd".repeat(32), kind: "web", label: "Chrome · 名字", exp: 1702592000 }, sig: {} } as LockEntry;
  assert.equal(await entryHash(e), "27e965570b626031e9640b781bdba3b5bb111ba2307b81bd9af8d14158f8578a");
  assert.equal(await shortCode("cd".repeat(32)), "UJV-HA9");
  assert.throws(() => canonical(0.5));
});

test("one chain per workspace: kept for members, carried to stations, healed by them", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    assert.equal((await bob("GET", `/v1/workspaces/${ws}/lock`)).status, 404, "members only");
    assert.deepEqual(await (await alice("GET", `/v1/workspaces/${ws}/lock`)).json(), { head: null, entries: [] });

    // A station, its presence socket and what it is told.
    const station = await key();
    const enrollment = await (await alice("POST", `/v1/workspaces/${ws}/enrollments`, { name: "willow" })).json() as any;
    await h.fetch("/v1/stations/enroll", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: enrollment.token, station: station.id, signature: await station.sign(`stillfail-station-enroll-v1:${h.origin}:${enrollment.token}:${station.id}`), version: "0.1.0" }) });
    const ts = h.now();
    const socket = (await h.fetch("/v1/stations/connect", { headers: { upgrade: "websocket", "x-stillfail-station": station.id, "x-stillfail-ts": String(ts), "x-stillfail-signature": await station.sign(`stillfail-station-connect-v1:${h.origin}:${station.id}:${ts}`) } })).webSocket!;
    // What the station is told, as it comes: the next frame that `is` so (no deadline: it comes, or the test times out).
    // What comes while one is awaited, before it, is older than it and let go: kept, a state frame from before (the
    // chain at seq 2, ahead of its clearing) answered the wait for the chain a station brought back at seq 2, before the
    // cloud had taken it, and the next entry was posted onto no chain (CI, 2026-10-16).
    const frames: any[] = [];
    let waiting: { is: (f: any) => boolean; resolve: (f: any) => void } | null = null;
    socket.addEventListener("message", (event) => {
      if (event.data === "pong") return;
      const f = JSON.parse(event.data as string);
      if (waiting?.is(f)) {
        waiting.resolve(f);
        waiting = null;
      } else if (!waiting) frames.push(f);
    });
    socket.accept();
    const next = (is: (f: any) => boolean) => {
      const had = frames.findIndex(is);
      if (had >= 0) return Promise.resolve(frames.splice(0, had + 1).at(-1));
      frames.length = 0;
      return new Promise<any>((resolve) => (waiting = { is, resolve }));
    };
    const state = (lock: (l: any) => boolean) => next((f) => f.type === "state" && lock(f.lock));
    await state((l) => l === null);

    const owner = signer("alice");
    const entry = owner.entry;
    const g = await owner.genesis(ws);
    const member = (sub: string) => ({ sub, email: `${sub}@example.test`, role: "member" });
    const e1 = await entry(ws, g, "member", member("bob"));
    const e2 = await entry(ws, e1, "member", member("carol"));
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [e1] })).status, 409, "no genesis");
    const head = (await (await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [g, e1] })).json() as any).head;
    assert.deepEqual(head, { seq: 1, hash: await entryHash(e1), genesis: await entryHash(g) });
    // The station hears the head, and asks for what it lacks.
    await state((l) => l?.hash === head.hash);
    socket.send(JSON.stringify({ type: "lock.get", after: 0 }));
    assert.deepEqual((await next((f) => f.type === "lock")).entries, [e1]);
    // What follows is kept; what it has, skipped; a fork, another genesis, or a gap, refused.
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [g, e1, e2] })).status, 200);
    const fork = await entry(ws, e1, "member", member("mallory"));
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [fork] })).status, 409);
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [await signer("x").genesis(ws)] })).status, 409);
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [{ ...(await entry(ws, e2, "member", member("dave"))), seq: 9 }] })).status, 409);
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [await entry("01HOTHERWSOTHERWSOTHERWSOT", e2, "member", member("dave"))] })).status, 400);
    // One a station would refuse, refused here too (kept, it would leave every entry after it refused there): signed
    // by a key the lock does not name, or not its signer's to make, or with its signature broken.
    const refused = async (e: LockEntry) => [(await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [e] })).status, (await (await alice("GET", `/v1/workspaces/${ws}/lock`)).json() as any).head.seq];
    assert.deepEqual(await refused(await signer("alice").entry(ws, e2, "member", member("dave"))), [409, 2], "a key not in the lock");
    assert.deepEqual(await refused(await entry(ws, e2, "member", { sub: "dave" })), [409, 2], "not a member");
    assert.deepEqual(await refused({ ...(await entry(ws, e2, "member", member("dave"))), at: 1001 }), [409, 2], "its signature broken");
    // Lost (the owner cleared it): a station brings it back.
    assert.equal((await bob("DELETE", `/v1/workspaces/${ws}/lock`)).status, 404);
    assert.equal((await alice("DELETE", `/v1/workspaces/${ws}/lock`)).status, 200);
    await state((l) => l === null);
    socket.send(JSON.stringify({ type: "lock.put", entries: [g, e1, e2] }));
    await state((l) => l?.seq === 2);
    // Turned off, a new genesis starts another chain.
    const off = await entry(ws, e2, "disable", {});
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [off] })).status, 200, "turned off");
    const g2 = await owner.genesis(ws, { again: true });
    assert.equal(((await (await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [g2] })).json()) as any).head.genesis, await entryHash(g2));
    assert.equal(((await (await alice("GET", `/v1/workspaces/${ws}`)).json()) as any).lock.seq, 0);
    // A station that holds the first chain (away when it was turned off) asks for the rest of its own: given it, its
    // end with it. One that names no chain, or one the cloud never kept, gets the chain kept now.
    socket.send(JSON.stringify({ type: "lock.get", after: 1, genesis: await entryHash(g) }));
    assert.deepEqual((await next((f) => f.type === "lock")).entries, [e2, off]);
    socket.send(JSON.stringify({ type: "lock.get", after: -1, genesis: "ab".repeat(32) }));
    assert.deepEqual((await next((f) => f.type === "lock")).entries, [g2]);
  } finally {
    await h.close();
  }
});

test("a chain kept before the cloud checked entries is cut back to where the stations take it", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    const owner = signer("alice");
    const member = (sub: string) => ({ sub, email: `${sub}@example.test`, role: "member" });
    const g = await owner.genesis(ws);
    const e1 = await owner.entry(ws, g, "member", member("bob"));
    // Signed by a device the lock names without its key (2026-10-24): every station refused it, and all after it.
    const bad = await signer("alice").entry(ws, e1, "member", member("carol"));
    const after = await owner.entry(ws, bad, "member", member("dave"));
    const directories: any = await h.mf.getDurableObjectNamespace("DIRECTORY", "api");
    const directory = directories.get(directories.idFromName("primary"));
    await directory.keepLockUnchecked(ws, await Promise.all([g, e1, bad, after].map(async (e) => ({ seq: e.seq, entry: e, hash: await entryHash(e) }))));
    const kept = (await (await alice("GET", `/v1/workspaces/${ws}/lock`)).json()) as any;
    assert.deepEqual([kept.head.seq, kept.entries.length], [1, 2]);
    // What follows what the stations have is taken.
    const next = await owner.entry(ws, e1, "member", member("erin"));
    assert.equal(((await (await alice("POST", `/v1/workspaces/${ws}/lock`, { entries: [next] })).json()) as any).head.hash, await entryHash(next));
  } finally {
    await h.close();
  }
});

test("a device asking again within the hour, saying nothing new, is not written again; something new, or an hour on, is", async () => {
  // (2026-11-24: every credential wrote its device's last_seen, and a burst of a person's devices asking together waited
  // seconds on each other's writes behind the Directory's output gate)
  const h = await harness();
  try {
    const tokens = await h.login("alice");
    let alice = h.as(tokens);
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    const device = (await key()).id;
    const post = async (path: string, value: unknown) => (await h.fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(value) })).json() as Promise<any>;
    /** The clock put forward, alice's access credential made again for it; the time now. */
    const later = async (seconds: number) => {
      const { now } = await post("/__test/later", { seconds });
      alice = h.as({ ...tokens, access_token: (await post("/__test/access", { sub: tokens.subject, sid: tokens.session_id, seconds: 300 })).token });
      return now as number;
    };
    const devices = async () => ((await (await alice("GET", `/v1/workspaces/${ws}/devices`)).json()) as any).devices as any[];

    // An account deleted takes its devices with it, and what was remembered of them: signed up again and back in the
    // workspace in the same second, the same device is kept again.
    const join = async () => {
      const bob = h.as(await h.login("bob"));
      await alice("POST", `/v1/workspaces/${ws}/invitations`, { role: "member", email: "bob@example.test" });
      const invitation = ((await (await bob("GET", "/v1/me")).json()) as any).invitations[0];
      assert.equal((await bob("POST", `/v1/invitations/${invitation.id}/accept`)).status, 200);
      assert.equal((await bob("POST", `/v1/workspaces/${ws}/credential`, { device })).status, 200);
      return bob;
    };
    const bobs = async () => (await devices()).filter((d) => d.email === "bob@example.test").map((d) => d.device);
    const bob = await join();
    assert.deepEqual(await bobs(), [device]);
    assert.equal((await bob("DELETE", "/v1/me")).status, 200);
    assert.deepEqual(await bobs(), []);
    await join();
    assert.deepEqual(await bobs(), [device], "kept again, not taken as remembered");

    const ask = async (said: Record<string, string> = {}) => assert.equal((await alice("POST", `/v1/workspaces/${ws}/credential`, { device, ...said })).status, 200);
    const seen = async () => (await devices()).filter((d) => d.email === "alice@example.test").map((d) => [d.label, d.last_seen]);
    const first = await later(0);
    await ask({ label: "Mac" });
    assert.deepEqual(await seen(), [["Mac", first]]);
    await later(600);
    await ask();
    await later(600);
    await ask({ label: "Mac" });
    assert.deepEqual(await seen(), [["Mac", first]], "the same within the hour: not written");

    const renamed = await later(600);
    await ask({ label: "MacBook" });
    assert.deepEqual(await seen(), [["MacBook", renamed]], "a new label: written at once");

    await later(3599);
    await ask();
    assert.deepEqual(await seen(), [["MacBook", renamed]], "still within the hour");
    const hour = await later(1);
    await ask();
    assert.deepEqual(await seen(), [["MacBook", hour]], "an hour on: written again");
  } finally {
    await h.close();
  }
});

test("a credential writes nothing: the devices are written together by the cron's minute, by what reads them, and forgotten with what is taken out", async () => {
  // (2026-11-24: a person's endpoints asking together, each relay its own device, each wrote its row, and every answer
  // of the Directory waited seconds behind the output gate)
  const h = await harness();
  try {
    const aliceTokens = await h.login("alice");
    const bobTokens = await h.login("bob");
    const carolTokens = await h.login("carol");
    let alice = h.as(aliceTokens);
    let bob = h.as(bobTokens);
    let carol = h.as(carolTokens);
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    await alice("POST", `/v1/workspaces/${ws}/invitations`, { role: "member", email: "bob@example.test" });
    const invitation = ((await (await bob("GET", "/v1/me")).json()) as any).invitations[0];
    assert.equal((await bob("POST", `/v1/invitations/${invitation.id}/accept`)).status, 200);
    const dir = await h.object("DIRECTORY", "primary");
    const post = async (path: string, value: unknown) => (await h.fetch(path, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(value) })).json() as Promise<any>;
    /** The clock put forward, the access credentials made again for it; the time now. */
    const later = async (seconds: number) => {
      const { now } = await post("/__test/later", { seconds });
      const fresh = async (t: typeof aliceTokens) => h.as({ ...t, access_token: (await post("/__test/access", { sub: t.subject, sid: t.session_id, seconds: 300 })).token });
      [alice, bob, carol] = await Promise.all([fresh(aliceTokens), fresh(bobTokens), fresh(carolTokens)]);
      return now as number;
    };
    const ask = async (as: typeof alice, workspace: string, device: string, said: Record<string, string> = {}) => assert.equal((await as("POST", `/v1/workspaces/${workspace}/credential`, { device, ...said })).status, 200);
    /** A device's row as kept (null: none), its fields taken out of what the object's call answers. */
    const row = async (workspace: string, sub: string, device: string) => {
      const r = await dir.storedDeviceRow(workspace, sub, device);
      return r === null ? null : { base: r.base, kind: r.kind, label: r.label, first_seen: r.first_seen, last_seen: r.last_seen };
    };
    const bobSub = bobTokens.subject as string;
    const aliceSub = aliceTokens.subject as string;

    // A burst of bob's endpoints, and one of them saying more after: nothing written, all of it held.
    const start = await later(0);
    const [a, b, c, d, e] = (await Promise.all([key(), key(), key(), key(), key()])).map((k) => k.id);
    await Promise.all([a, b, c].map((device) => ask(bob, ws, device!)));
    await ask(bob, ws, a!, { label: "Mac" });
    await ask(bob, ws, a!, { kind: "app" });
    for (const device of [a, b, c]) assert.equal(await row(ws, bobSub, device!), null, "a credential writes no row");
    assert.equal(await dir.storedDevices(), 0);
    assert.equal(await dir.pendingDevices(), 3);

    // The cron's minute writes them, what each said kept together; ten minutes on, not before, the next.
    await dir.tellAdmins({ type: "relays" });
    assert.equal(await dir.pendingDevices(), 0);
    assert.deepEqual(await row(ws, bobSub, a!), { base: null, kind: "app", label: "Mac", first_seen: start, last_seen: start });
    assert.equal(await dir.storedDevices(), 3);
    const seenAt = await later(60);
    await ask(bob, ws, d!);
    await dir.tellAdmins({ type: "relays" });
    assert.equal(await row(ws, bobSub, d!), null, "a minute on: not written");
    await later(539);
    await dir.tellAdmins({ type: "relays" });
    assert.equal(await row(ws, bobSub, d!), null, "still within ten minutes");
    await later(1);
    await dir.tellAdmins({ type: "relays" });
    assert.deepEqual(await row(ws, bobSub, d!), { base: null, kind: null, label: null, first_seen: seenAt, last_seen: seenAt });

    // What reads them writes them at once: the devices a member is shown (not someone outside, refused first), a move's export.
    const renamed = await later(60);
    await ask(bob, ws, a!, { label: "MacBook" });
    assert.equal((await carol("GET", `/v1/workspaces/${ws}/devices`)).status, 404);
    assert.equal(await dir.pendingDevices(), 1, "a refused read writes nothing");
    const bobs = ((await (await bob("GET", `/v1/workspaces/${ws}/devices`)).json()) as any).devices;
    assert.deepEqual(bobs.filter((x: any) => x.device === a).map((x: any) => [x.kind, x.label, x.first_seen, x.last_seen]), [["app", "MacBook", start, renamed]]);
    assert.equal(await dir.pendingDevices(), 0);
    await ask(bob, ws, e!);
    const exported = (await dir.moveExport()).devices as { device: string }[];
    assert.ok(exported.some((x) => x.device === e), "the export has what was held");
    assert.equal(await dir.pendingDevices(), 0);

    // A workspace gone, or an account deleted, takes what is held of it: nothing written of it after.
    const other = (await (await alice("POST", "/v1/workspaces", { name: "Other" })).json() as any).id as string;
    await ask(alice, other, a!);
    await ask(alice, ws, b!);
    assert.equal(await dir.pendingDevices(), 2);
    assert.equal((await alice("DELETE", `/v1/workspaces/${other}`)).status, 200);
    assert.equal(await dir.pendingDevices(), 1, "the workspace's held device gone, the other kept");
    await later(600);
    await ask(bob, ws, c!, { label: "Phone" });
    assert.equal(await dir.pendingDevices(), 2);
    assert.equal((await bob("DELETE", "/v1/me")).status, 200);
    assert.equal(await dir.pendingDevices(), 1, "the account's held device gone, alice's kept");
    await dir.tellAdmins({ type: "relays" });
    await dir.flushDevicesNow();
    assert.equal(await row(other, aliceSub, a!), null, "no row of the workspace gone");
    assert.equal(await row(ws, bobSub, c!), null, "no row of the account deleted");
    assert.notEqual(await row(ws, aliceSub, b!), null);

    // A move's import forgets what is held, and the minute after it writes at once.
    const f = (await key()).id;
    await ask(alice, ws, f);
    assert.equal(await dir.pendingDevices(), 1);
    await dir.moveImport({});
    assert.equal(await dir.pendingDevices(), 0);
    assert.equal(await row(ws, aliceSub, f), null);
    await later(1);
    await ask(alice, ws, (await key()).id);
    await dir.tellAdmins({ type: "relays" });
    assert.equal(await dir.pendingDevices(), 0, "written at once after a move, not ten minutes after the last");
  } finally {
    await h.close();
  }
});

test("devices that asked for credentials, for the owner to check; devices waiting to be confirmed", async () => {
  const h = await harness();
  try {
    const alice = h.as(await h.login("alice"));
    const bob = h.as(await h.login("bob"));
    const ws = (await (await alice("POST", "/v1/workspaces", { name: "Home" })).json() as any).id as string;
    const invite = await (await alice("POST", `/v1/workspaces/${ws}/invitations`, { role: "member", email: "bob@example.test" })).json() as any;
    await bob("POST", "/v1/invitations/accept", { token: invite.token });

    // An older client names only its endpoint; a newer one its base key, proving the endpoint is its own.
    const old = await key();
    const base = await key();
    const endpoint = await key();
    assert.equal((await bob("POST", `/v1/workspaces/${ws}/credential`, { device: old.id })).status, 200);
    const proof = await base.sign(`stillfail-lock-endpoint/1\0${ws}\0${endpoint.id}`);
    assert.equal((await bob("POST", `/v1/workspaces/${ws}/credential`, { device: endpoint.id, base: base.id, proof: await old.sign("x"), kind: "app" })).status, 400, "a proof by another key");
    assert.equal((await bob("POST", `/v1/workspaces/${ws}/credential`, { device: endpoint.id, base: base.id, proof, kind: "app", label: "bob's Mac" })).status, 200);
    assert.equal((await alice("POST", `/v1/workspaces/${ws}/credential`, { device: (await key()).id })).status, 200);
    const devices = ((await (await alice("GET", `/v1/workspaces/${ws}/devices`)).json()) as any).devices;
    assert.deepEqual(devices.filter((d: any) => d.email === "bob@example.test").map((d: any) => [d.email, d.device, d.base, d.kind, d.label]).sort(), [
      ["bob@example.test", endpoint.id, base.id, "app", "bob's Mac"],
      ["bob@example.test", old.id, null, null, null],
    ].sort());
    assert.ok(devices.every((d: any) => typeof d.last_seen === "number"));
    // A member sees only their own (when each of theirs was last used, on the security page); owners and admins everyone's.
    assert.deepEqual(devices.map((d: any) => d.email).sort(), ["alice@example.test", "bob@example.test", "bob@example.test"]);
    const bobs = ((await (await bob("GET", `/v1/workspaces/${ws}/devices`)).json()) as any).devices;
    assert.deepEqual(bobs.map((d: any) => d.device).sort(), [endpoint.id, old.id].sort());

    // A device asks to be confirmed: its code, as both sides work it out; seen by owners and the member, gone once answered.
    const waiting = await key();
    const asked = await (await bob("POST", `/v1/workspaces/${ws}/lock/requests`, { base: waiting.id, kind: "web", label: "Chrome" })).json() as any;
    assert.equal(asked.code, await shortCode(waiting.id));
    assert.deepEqual(((await (await alice("GET", `/v1/workspaces/${ws}/lock/requests`)).json()) as any).requests.map((r: any) => [r.base, r.email, r.code]), [[waiting.id, "bob@example.test", asked.code]]);
    assert.equal((await alice("DELETE", `/v1/workspaces/${ws}/lock/requests/${waiting.id}`)).status, 200);
    assert.deepEqual(((await (await bob("GET", `/v1/workspaces/${ws}/lock/requests`)).json()) as any).requests, []);

    // Of one person's devices with the same kind and name only the latest waits (the same browser, its storage
    // cleared); those without a name, or of another kind, each wait. One asked a week ago is dropped; asking again,
    // it waits anew.
    const listed = async () => ((await (await alice("GET", `/v1/workspaces/${ws}/lock/requests`)).json()) as any).requests.map((r: any) => r.base);
    const count = async () => ((await (await alice("GET", `/v1/workspaces/${ws}`)).json()) as any).lock_requests;
    const [chrome, again, phone, unnamed, unnamed2] = await Promise.all([key(), key(), key(), key(), key()]);
    const ask = (k: { id: string }, kind: string, label: string) => bob("POST", `/v1/workspaces/${ws}/lock/requests`, { base: k.id, kind, label });
    await ask(chrome, "web", "still.fail · Chrome · macOS");
    await ask(phone, "app", "still.fail · Chrome · macOS");
    await ask(unnamed, "web", "");
    await ask(unnamed2, "web", "");
    await ask(again, "web", "still.fail · Chrome · macOS");
    assert.deepEqual((await listed()).sort(), [phone.id, unnamed.id, unnamed2.id, again.id].sort());
    assert.equal(await count(), 4);
    const directories: any = await h.mf.getDurableObjectNamespace("DIRECTORY", "api");
    const directory = directories.get(directories.idFromName("primary"));
    await directory.ageLockRequest(ws, phone.id, 7 * 86400);
    await directory.ageLockRequest(ws, unnamed.id, 7 * 86400 - 60);
    assert.deepEqual((await listed()).sort(), [unnamed.id, unnamed2.id, again.id].sort());
    assert.equal(await count(), 3);
    await ask(phone, "app", "still.fail · Chrome · macOS");
    assert.deepEqual((await listed()).sort(), [phone.id, unnamed.id, unnamed2.id, again.id].sort());
  } finally {
    await h.close();
  }
});

test("an entry signed with a device someone else put in under the signer's name is kept no more: a station would let it change nothing", async () => {
  const owner = signer("alice");
  const admin = signer("bob");
  const fake = signer("alice");
  const ws = "01HZZZZZZZZZZZZZZZZZZZZZZZ";
  const bobs = { id: admin.key.slice(8), sub: "bob", kind: "app", label: "", sign_key: admin.key };
  const g = await owner.genesis(ws, { members: [{ sub: "alice", email: "alice@example.test", role: "owner" }, { sub: "bob", email: "bob@example.test", role: "admin" }], devices: [{ id: owner.key.slice(8), sub: "alice", kind: "app", label: "", sign_key: owner.key }, bobs] });
  // bob (an admin) puts a device of his in under alice's name: taken, as a station takes it (not hers).
  const put = await admin.entry(ws, g, "device", { id: fake.key.slice(8), sub: "alice", kind: "app", label: "alice?", sign_key: fake.key });
  assert.equal(extendLock([g], [put], 2000).adding.length, 1);
  // What it signs, as the owner: refused.
  const off = await fake.entry(ws, put, "disable", {});
  assert.throws(() => extendLock([g, put], [off], 2000), (e: any) => e instanceof LockAppendRefused && e.code === "lock_refused");
  // alice's own device signs it: taken.
  assert.equal(extendLock([g, put], [await owner.entry(ws, put, "disable", {})], 2000).adding.length, 1);
});
