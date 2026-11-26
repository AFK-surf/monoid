// A rig's grants across a launcher's handover (rig/module.ts `beforeServe`, rig/grants.ts `reload`): the next process
// reads `<data>/rig/grants.json` as it starts, while the one before still serves and may change it (a grant taken back,
// 免批准 turned on). What it read then is only held: it answers, tells and lets in nothing by it until the one before is
// gone and the record is read again, so a chat taken off the rig is not let back on, nor one let on left off.
import assert from "node:assert/strict";
import { createHash, generateKeyPairSync, sign as nodeSign } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type GrantBody, type RevokeBody, type SettingsBody, latest, signedBytes } from "../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash, signedBytes as entryBytes } from "../../shared/lock.ts";
import { Cloud } from "../src/cloud/state.ts";
import { PeerBus, Refused } from "../src/mesh/bus.ts";
import { Rig } from "../src/rig/module.ts";
import { RigSnapshotOrder } from "../src/rigs/module.ts";
import type { Json } from "../src/store/store.ts";

const RIG = "aa".repeat(32);
const STATION = "bb".repeat(32);
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest();

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}

/// The rig's person's own lock of one device, and what that device signs.
function person(sub: string) {
  const key = ed();
  const e = { v: 1, ws: `person:${sub}`, seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub, device: { key: key.id, id: ed().hex, label: "first" } } } as Omit<Entry, "sig">;
  const chain = [{ ...e, sig: { key: key.id, alg: "Ed25519", sig: key.sign(entryBytes(entryHash(e as Entry))) } } as Entry];
  return { chain, genesis: entryHash(chain[0]!), says: <B>(kind: "grant" | "revoke" | "settings", body: B) => ({ body, sig: { key: key.id, sig: key.sign(signedBytes(kind, body, sha256)) } }) };
}

/// The rig's cloud.json in memory: a rig of `pat` in workspace "ws", with one station.
const cloudOf = (genesis: string): any =>
  Object.assign(Object.create(Cloud.prototype), {
    state: { workspace: "ws", workspace_name: "ws", name: "", station: RIG, peers: [{ id: STATION }], revocations: [], rig: { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: genesis } },
    lock: null,
    peersCurrent: true,
    listeners: new Set(),
    relays: () => [],
  });

/// What is due in this process is done (promises chained on what is already settled), nothing more: no clock.
const drained = async () => {
  for (let i = 0; i < 20; i++) await new Promise<void>((resolve) => setImmediate(resolve));
};

function world() {
  const dir = mkdtempSync(join(tmpdir(), "rig-handover-"));
  const owner = person("pat");
  const cloud = cloudOf(owner.genesis);
  const made: Rig[] = [];
  /// One process's rig on `dir`: its bus, what reached its tasks, and what it told the station.
  const start = (beforeServe?: Promise<void>) => {
    const bus = new PeerBus({ sleep: () => new Promise<void>(() => {}) });
    const ran: string[] = [];
    bus.otherwise(async (_peer, request) => {
      ran.push(`${request.method} ${request.session ?? ""}`);
      return { ok: request.method };
    });
    const told: { method: string; open: boolean; grants: string[] }[] = [];
    const rig = new Rig({ data: dir, cloud, bus, busy: () => false, stop: () => {}, running: () => [], ...(beforeServe !== undefined ? { beforeServe } : {}) });
    made.push(rig);
    return {
      rig, bus, ran, told,
      ask: (request: Json) => bus.handle("ws", STATION, request),
      // On the mesh: what it tells the station is kept.
      attach: () =>
        bus.attach(Object.assign(async (_to: string, _ws: string | null, request: Json) => {
          told.push({ method: request.method, open: request.rig?.open, grants: request.rig?.grants.map((g: any) => g.request) });
          return { ok: true };
        }, {}) as any),
    };
  };
  const now = () => Math.floor(Date.now() / 1000);
  const timeout = { kind: "fixed" as const, seconds: 3600 };
  return {
    dir, owner, start,
    file: () => readFileSync(join(dir, "rig", "grants.json"), "utf8"),
    grant: (request: string, session: string) => ({
      method: "rig.grant", chain: owner.chain,
      signed: owner.says("grant", { v: 1, sub: "pat", ws: "ws", rig: RIG, station: STATION, session, chat: `CHAT/${session}`, request, title: "a chat", by: "lee@example.com", timeout, at: now(), exp: latest(now(), timeout) } as GrantBody),
    }),
    revoke: (request: string) => ({ method: "rig.revoke", chain: owner.chain, signed: owner.says("revoke", { v: 1, sub: "pat", ws: "ws", rig: RIG, request, at: now() } as RevokeBody) }),
    settings: (seq: number, open: boolean) => ({ method: "rig.settings", chain: owner.chain, signed: owner.says("settings", { v: 1, sub: "pat", ws: "ws", rig: RIG, seq, open, at: now() } as SettingsBody) }),
    close: async () => {
      for (const rig of made) await rig.close();
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

const prepare = (session: string) => ({ method: "task.prepare", session, key: "k", spec: { name: "build", command: "make" } });
const noGrant = (e: unknown) => e instanceof Refused && /this chat has no grant of this station/.test(e.message);

test("a grant taken back while the next process starts is not let back on by what that one read as it started", async () => {
  const w = world();
  try {
    const before = w.start();
    await before.ask(w.grant("r1", "s1"));
    await before.rig.grants.written();

    // The next process starts (it reads the grant), the one before still serving.
    const gone = Promise.withResolvers<void>();
    const after = w.start(gone.promise);
    assert.deepEqual(after.rig.grants.view("ws")!.grants.map((g) => g.request), ["r1"], "what it read as it started");
    after.attach();
    const asked = after.ask(prepare("s1"));
    let settled = false;
    void asked.then(() => (settled = true), () => (settled = true));
    await drained();
    assert.equal(settled, false, "nothing answered by what may be out of date");
    assert.deepEqual(after.told, [], "nothing told by it");
    assert.equal(after.rig.stationRefusal(STATION, "ws"), "the rig is starting", "no one let in by it");

    // Taken back on the one before, which then stops (its grants written).
    assert.deepEqual(await before.ask(w.revoke("r1")), { ok: true });
    await before.rig.close();
    gone.resolve();
    await after.rig.ready();

    await assert.rejects(asked, noGrant);
    await assert.rejects(after.ask(prepare("s1")), noGrant);
    assert.deepEqual(after.ran, [], "the chat ran nothing");
    await drained();
    assert.deepEqual(after.told, [{ method: "rig.hello", open: false, grants: [] }], "and the station is told it has none");
    assert.equal(after.rig.stationRefusal(STATION, "ws"), "no chat of that station has a grant of this one");
  } finally {
    await w.close();
  }
});

test("免批准 turned on while the next process starts holds in that one once the one before is gone", async () => {
  const w = world();
  try {
    const before = w.start();
    assert.deepEqual(await before.ask(w.settings(1, false)), { ok: true });
    await before.rig.grants.written();

    const gone = Promise.withResolvers<void>();
    const after = w.start(gone.promise);
    after.attach();
    const asked = after.ask(prepare("s9"));

    assert.deepEqual(await before.ask(w.settings(2, true)), { ok: true });
    await before.rig.close();
    gone.resolve();
    await after.rig.ready();

    assert.deepEqual(await asked, { ok: "task.prepare" }, "a chat with no grant runs, 免批准 on");
    assert.deepEqual(after.ran, ["task.prepare s9"]);
    await drained();
    assert.deepEqual(after.told, [{ method: "rig.hello", open: true, grants: [] }], "and the station is told it is open");
    assert.equal(after.rig.stationRefusal(STATION, "ws"), null);
  } finally {
    await w.close();
  }
});

test("what the owner signs for the next process while the one before still runs waits, and is kept", async () => {
  const w = world();
  try {
    const before = w.start();
    const g1 = await before.ask(w.grant("r1", "s1"));
    assert.equal(g1.until, before.rig.grants.view("ws")!.grants[0]!.exp);
    assert.equal(typeof g1.boot, "string");
    assert.equal(typeof g1.rev, "number");
    await before.rig.grants.written();
    const gone = Promise.withResolvers<void>();
    const after = w.start(gone.promise);
    // A grant brought to the next process first: held until the record is read again, then taken on top of it.
    const brought = after.ask(w.grant("r2", "s2"));
    await before.rig.close();
    gone.resolve();
    await brought;
    assert.deepEqual(after.rig.grants.view("ws")!.grants.map((g) => g.request).sort(), ["r1", "r2"]);
    await after.rig.grants.written();
    assert.deepEqual(Object.keys(JSON.parse(w.file()).grants).sort(), ["r1", "r2"], "and written whole");
  } finally {
    await w.close();
  }
});

test("a next process stopped before the one before is gone stops at once, writes nothing and answers nothing", async () => {
  const w = world();
  try {
    const before = w.start();
    const g1 = await before.ask(w.grant("r1", "s1"));
    assert.equal(g1.until, before.rig.grants.view("ws")!.grants[0]!.exp);
    assert.equal(typeof g1.boot, "string");
    assert.equal(typeof g1.rev, "number");
    await before.rig.grants.written();
    const kept = w.file();

    const after = w.start(new Promise<void>(() => {})); // the one before never goes
    after.attach();
    // (each answer taken as it comes: the stop refuses them before they are looked at)
    const outcome = (p: Promise<Json>) => p.then((answer) => ({ answer }), (error: unknown) => ({ error }));
    const asked = outcome(after.ask(prepare("s1")));
    const signed = outcome(after.ask(w.grant("r2", "s2")));
    await after.rig.close();
    for (const o of [await asked, await signed]) {
      assert.ok("error" in o && o.error instanceof Refused && /this rig is stopping/.test(o.error.message), JSON.stringify(o));
    }
    await assert.rejects(after.rig.device(STATION, "ws", "s1", "d1", true), /the rig is stopping/);
    assert.deepEqual(after.ran, []);
    await drained();
    assert.deepEqual(after.told, []);
    assert.equal(w.file(), kept, "the record left as the one before wrote it");
  } finally {
    await w.close();
  }
});

test("a rig started cold (no process before it) answers at once by what it read", async () => {
  const w = world();
  try {
    const first = w.start();
    await first.ask(w.grant("r1", "s1"));
    await first.rig.close();
    const cold = w.start();
    assert.equal(cold.rig.grants.held(), false);
    assert.deepEqual(await cold.ask(prepare("s1")), { ok: "task.prepare" });
  } finally {
    await w.close();
  }
});

test("monotonic (boot, rev) stamps on rig snapshots drop stale rig.hello / rig.changed arriving after rig.grant", async () => {
  const w = world();
  try {
    const rig = w.start();
    const seen: Json[] = [];
    rig.bus.attach(Object.assign(async (_to: string, _ws: string | null, request: Json) => {
      seen.push(request);
      return { ok: true };
    }, {}) as any);
    await drained();
    // Initial rig.hello carries grants: [] at rev 0.
    assert.equal(seen.length, 1);
    const hello = seen[0]!;
    assert.equal(hello.method, "rig.hello");
    assert.deepEqual(hello.rig.grants, []);

    // Grant arrives and increments rev; both rig.grant reply and rig.changed carry the newer rev.
    const granted = await rig.ask(w.grant("r1", "s1"));
    await drained();
    assert.equal(seen.length, 2);
    const changed = seen[1]!;
    assert.equal(changed.method, "rig.changed");
    assert.equal(granted.boot, hello.boot);
    assert.ok(granted.rev > hello.rev);
    assert.equal(changed.boot, granted.boot);
    assert.equal(changed.rev, granted.rev);

    // Station order gate accepts rig.grant watermark, rejects late rig.hello, accepts matching rig.changed,
    // accepts a fresh boot after handover, and rejects delayed messages from the retired boot.
    const order = new RigSnapshotOrder();
    assert.equal(order.accept("ws\0rig", granted.boot, granted.rev), true);
    assert.equal(order.accept("ws\0rig", hello.boot, hello.rev), false, "late rig.hello dropped after rig.grant");
    assert.equal(order.accept("ws\0rig", changed.boot, changed.rev), true, "matching rig.changed accepted");
    assert.equal(order.accept("ws\0rig", "next-boot", 1), true, "fresh boot accepted");
    assert.equal(order.accept("ws\0rig", granted.boot, granted.rev + 10), false, "retired boot dropped");
    assert.equal(order.accept("ws\0rig", undefined, undefined), true, "older rigs without boot/rev stay compatible");
  } finally {
    await w.close();
  }
});
