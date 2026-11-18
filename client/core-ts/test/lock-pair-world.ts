// A new device approved face to face where a workspace's chain moved to its people's own logs, end to end on a core
// whose station is the station's own code (station/src/cloud/state.ts `Cloud`, its hello's admission and refusal,
// mesh/serve.ts `inLockBringing`, `refusalOf`, its routes `lockRoute`, `lockPartRoute`), as lock-left-out.test.ts has
// it, with the trusted devices it dials played here, each as one of a list of ways a real one goes wrong (`Fault`):
// it shows its code late or never, goes quiet, is turned away on, or signs the new device in and its answer never comes
// back (the line cut, or the phone put away), its entry reaching the station some time later. Each signs what the real
// one would (views/pair.ts `approve`): a newcomer's `member`, a member's web page's `web`, a device put on its person's
// own log, a member the chain carries unbound bound to the log their device begins.
//
// The world: `ws`, its chain alice's (r1, the owner; bob r2 an admin) then a `moved` to alice's own log, which says the
// settings, bob and station A. This core is s1's: by the mode, a newcomer's first app (`admit`), the web page of a member
// alice's log names by the log of s1's app X (`web`), s1's second app, X's log not naming it (`personal`), or the new app
// of a member the chain names with an app of theirs (X) and binds to no log, no log of theirs anywhere (`carried`).
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect } from "effect";
import { type Entry as StationEntry, LockRefusal, entryHash as stationHash } from "../../../station/src/cloud/lock.ts";
import { Cloud, writeState } from "../../../station/src/cloud/state.ts";
import { inLockBringing, lockPartRoute, lockRoute, refusalOf } from "../../../station/src/mesh/serve.ts";
import { type Dev, Log, bring as brought, dev, ed, signed, viewerOf } from "../../../station/test/lock-moved-world.ts";
import { key, signed as simSigned } from "../../../station/test/lock-world-sim.ts";
import { bindBytes } from "../../../station/test/lock-roster4-model.ts";
import { hooks } from "../src/core/execute.ts";
import { CoreError } from "../src/error.ts";
import type { Entry } from "../src/lock.ts";
import { pairSession, pakeKeys, pakeStart, sameMac } from "../src/pair.ts";
import { httpError } from "../src/station/requests.ts";
import { hex, utf8 } from "../src/util.ts";
import { held, read } from "../src/views/lock.ts";
import { dialer } from "../src/views/pair.ts";
import { call } from "./helpers.ts";
import { stationClock } from "./station-clock.ts";
import { grant, pipe, rig, unhex } from "./lock-rig.ts";
import { stationReplies } from "./station-fixture.ts";

let clock = () => 0;

/// The seed of key `n` of station/test/lock-world-sim.ts's `key`, as a device keeps it sealed.
const seedOf = (n: number) => {
  const s = new Uint8Array(32);
  new DataView(s.buffer).setUint32(28, n);
  return s;
};

type J = any;
export type Mode = "chain" | "admit" | "web" | "personal" | "carried";
export const MODES: Mode[] = ["chain", "admit", "web", "personal", "carried"];

/// How a trusted device dialled goes: `live` (its code shown, the code typed proved, it signs and answers after
/// `ms`); `never` (reached, it never says whether it shows a code: a phone put away as it was reached); `quiet` (its
/// code shown, then nothing more: put away as its code was read off it); `late` (its code shown `ms` after it was
/// asked); `deny` (turned away on it `ms` after it showed its code); `cut` (it signs, its entry reaching the station
/// `ms` after the confirmation, and the line goes as the confirmation arrives: the answer never comes); `gone` (as
/// `cut`, but the line goes silently, nothing more arriving either way); `mute` (the confirmation taken, then nothing:
/// it signs nothing and never answers). `then`, of `late`: what it does once it has
/// shown its code (`live` by default).
export type Fault = { kind: "live" | "never" | "quiet" | "late" | "deny" | "cut" | "gone" | "mute"; ms?: number; then?: Fault };

export type World = Awaited<ReturnType<typeof world>>;

/// The world of `mode`, with `trusted` trusted devices of those it dials (1 to 3): the first the one a real world has
/// (alice's app for a newcomer, X otherwise), the others more of the same person's (bob's app for a newcomer, a second
/// and third device on X's log, or on the chain for `carried`, alice's own on the chain for `chain`). `chain`: the chain
/// never moved (s1 a member of it with no device yet, whose first an owner's device signs in). Options: `web` this core
/// a web page (as `web` is; of a newcomer, whom nobody can approve); `w2` a second workspace of s1's whose chain never
/// moved and names no device of theirs, its owner's devices none of those played here; `replaced` (with `personal`) this
/// device on a lock of s1's begun before (pinned here as it starts), X's log begun since elsewhere, which alice's log
/// binds them by (`replaced` as s1's own lock stands here); `unsaid` (with `personal`) this device put on X's log without
/// the key it signs the workspace's things with, as an app from before signers were said there was.
export async function world(mode: Mode, trusted = 1, o: { web?: boolean; w2?: boolean; replaced?: boolean; unsaid?: boolean } = {}) {
  const g = grant();
  const settings = { origins: ["https://stillfail.test"], rp_id: "stillfail.test", cloud_keys: g.keys };
  const alice = new Log("r1"), bob = new Log("r2"), x = new Log("s1");
  const A = ed().hex, base = ed();
  const named = mode === "web" || mode === "personal";
  const moving = mode !== "chain";
  // (more of s1's devices: on X's log where it is named; on the chain where it carries them)
  const more: Dev[] = Array.from({ length: Math.max(0, trusted - 1) }, () => dev());
  if (named) for (const d of more) x.add("device", { key: d.key.id, id: d.base.hex, label: `s1's device ${d.base.hex.slice(0, 4)}`, sign_key: d.signer.id });
  if (moving) {
    alice.say("open", { ...settings, email: "r1@x.com" }, "ws");
    alice.say("member", { sub: "r2", email: "r2@x.com", lock: bob.genesis, role: "admin" }, "ws");
    alice.say("station", { key: A }, "ws");
  }
  if (named) alice.say("member", { sub: "s1", email: "s1@x.com", lock: x.genesis, role: "member" }, "ws");
  const app = (sub: string, d: Dev, label: string) => ({ id: d.base.hex, sub, kind: "app", label, sign_key: d.signer.id });
  const body = {
    owner: "r1", ...settings, passkeys: [], stations: [{ key: A, name: "a" }], gateways: [],
    members: [{ sub: "r1", email: "r1@x.com", role: "owner" }, { sub: "r2", email: "r2@x.com", role: "admin" }, ...(mode !== "admit" ? [{ sub: "s1", email: "s1@x.com", role: "member" }] : [])],
    devices: [app("r1", alice.app, "r1's app"), ...(mode === "chain" ? more.map((d, i) => app("r1", d, `r1's app ${i + 2}`)) : []), app("r2", bob.app, "r2's app"), ...(mode !== "admit" && mode !== "chain" ? [app("s1", x.app, "s1's app")] : []), ...(mode === "carried" ? more.map((d, i) => app("s1", d, `s1's app ${i + 2}`)) : [])],
  };
  const first = signed({ v: 1, ws: "ws", seq: 0, prev: null, at: 1000, kind: "genesis", body }, alice.app.signer);
  const moved = signed({ v: 1, ws: "ws", seq: 1, prev: stationHash(first), at: 1000, kind: "moved", body: { root: alice.genesis } }, alice.app.signer);
  // (`w2`: its genesis z1's, s1 a member with no device; no station, read of the cloud)
  const z1 = ed();
  const w2 = signed({ v: 1, ws: "w2", seq: 0, prev: null, at: 1000, kind: "genesis", body: { owner: "z1", ...settings, passkeys: [], stations: [], gateways: [], members: [{ sub: "z1", email: "z1@x.com", role: "owner" }, { sub: "s1", email: "s1@x.com", role: "member" }], devices: [{ id: z1.hex, sub: "z1", kind: "app", label: "z1's app", sign_key: z1.id }] } }, z1);
  // (`replaced`: s1's lock of before, this device on it by a key whose seed is sealed here, as an app that joined it)
  const k = key(7_301);
  const before = o.replaced ? [simSigned({ v: 1, ws: "person:s1", seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub: "s1", device: { key: k.id, id: base.hex, label: "s1's app" } } } as never, k)] : [];
  const r = await rig(() => ({ ws: first as unknown as Entry, ...(o.w2 ? { w2: w2 as unknown as Entry } : {}) }), (host) => {
    if (mode === "web" || o.web) host.appKeys = false;
    if (o.replaced) {
      host.storage.set(`personal-lock-${hex(utf8("s1"))}`, utf8(JSON.stringify(before)));
      host.storage.set("personal-signer-id", utf8(k.id));
      host.secure.set("personal-signer", { value: seedOf(7_301), user: true });
    }
  }, [A], [A], undefined, [], { role: "member" });
  clock = () => r.host.nowMs();
  stationClock(clock);
  stationReplies(r.host, (req) => (req.url.endsWith("/v1/me/personal-lock") ? (req.method === "GET" ? { entries: cloudKeeps.s1 } : { ok: true }) : r.cloud.reply(req)));
  r.cloud.chains.set("ws", (moving ? [first, moved] : [first]) as unknown as Entry[]);
  const inner = r.core.inner;
  inner.mesh = () => Effect.succeed({ deviceId: () => base.hex, sign: () => ({ publicKey: new Uint8Array(32), signature: new Uint8Array(64) }), link: () => Effect.fail(CoreError.plainly("mesh", "no station link here")) } as never);
  inner.cloudSync.credential = () => Effect.succeed({ credential: "signed-member", issued_at: 1000, expires_at: 4102444800, relay_url: "https://relay.example" });
  const data = mkdtempSync(join(tmpdir(), "lock-pair-world-"));
  writeState(data, { origin: "https://stillfail.test", station: A, workspace: "ws", workspace_name: "W", name: "a", relay_url: "", relay_urls: [], grant_keys: g.keys, peers: [{ id: A, name: "a" }], revocations: [] } as never);
  const c = new Cloud(data, false);
  c.takeLock([first]);
  if (moving) c.takeLock([first, moved], null, true);
  /// What the cloud keeps of s1's own lock (for the devices from before): what a trusted device brought it too.
  const cloudKeeps: { s1: Entry[] } = { s1: [] };
  const bring = (l: Log) => {
    brought(c, l, true, "ws");
    if (l === x) cloudKeeps.s1 = x.entries as unknown as Entry[];
  };
  for (const l of !moving ? [] : named ? [alice, bob, x] : [alice, bob]) bring(l);
  const viewer = viewerOf("s1", { base }, "member", "ws");
  /// `personDown`: the station answers no read of a person's own lock (the cloud's copy alone is reached).
  const st = { refusals: [] as J[], admitted: 0, personDown: false };
  /// The link's hello to A, as the station answers it: null where it lets this device in; else its refusal, told the
  /// core as the mesh wire tells it (station/mesh-wire.ts `refusedFor`).
  const hello = (): CoreError | null => {
    const own = inner.adb.personal().entries("s1");
    const said = { lock: { device: base.hex, proof: viewer.lockDevice.proof, ...(own.length > 0 ? { person: own } : {}) } };
    try {
      inLockBringing(c, { viewer, exp: 4102444800, iat: 0, sid: "" } as never, "member", viewer.device, said);
    } catch (e) {
      if (!(e instanceof LockRefusal)) throw e;
      const refusal = refusalOf(c, said, viewer.device, e, undefined, "s1") as J;
      st.refusals.push(refusal);
      return hooks.lockRefused?.(inner, "ws", A, refusal.lock, refusal) ?? new CoreError("lock_unconfirmed", e.message);
    }
    st.admitted++;
    return null;
  };
  /// Whether station A lets this device in now (asked as its next hello would be, nothing told the core).
  const admits = () => {
    const own = inner.adb.personal().entries("s1");
    try {
      inLockBringing(c, { viewer, exp: 4102444800, iat: 0, sid: "" } as never, "member", viewer.device, { lock: { device: base.hex, proof: viewer.lockDevice.proof, ...(own.length > 0 ? { person: own } : {}) } });
      return true;
    } catch (e) {
      if (!(e instanceof LockRefusal)) throw e;
      return false;
    }
  };
  const cameOnline = inner.stations.cameOnline.bind(inner.stations);
  inner.stations.cameOnline = (address: string) => {
    cameOnline(address);
    // (its link dialled again on its own, as the mesh does: never within the call that asked it)
    if (address === `ws/${A}`) inner.runner.fork(Effect.suspend(() => (hello() === null ? Effect.ignore(read(inner, "ws")) : Effect.void)));
  };
  const original = inner.stations.requests.call.bind(inner.stations.requests);
  // (each ask answered as it runs, not as it is made: a refusal told the core makes it ask again within that ask)
  inner.stations.requests.call = ((addr: { toString(): string }, method: string, path: string, body: unknown, ...rest: unknown[]): Effect.Effect<unknown, CoreError> => Effect.suspend(() => {
    const [w, id] = addr.toString().split("/");
    if (id !== A || !path.startsWith("/lock")) return (original as (...x: unknown[]) => Effect.Effect<unknown, CoreError>)(addr, method, path, body, ...rest);
    if (w !== "ws") return Effect.fail(httpError(404, { error: "no route" }));
    if (st.personDown && path.startsWith("/lock/person")) return Effect.fail(new CoreError("station_offline", "not reached"));
    const waits = hooks.lockWaiting?.(inner, w, A) ?? null;
    if (waits !== null) return Effect.fail(waits);
    const no = hello();
    if (no !== null) return Effect.fail(no);
    const [p, q] = path.split("?") as [string, string | undefined];
    const buf = Buffer.from(body === null || body === undefined ? "" : JSON.stringify(body));
    const [status, out] = p === "/lock" ? lockRoute(c, method, q ? [...new URLSearchParams(q)] : [], buf, viewer as never) : lockPartRoute(c, p.slice("/lock/".length), method, buf, viewer as never);
    return status === 200 ? Effect.succeed(out) : Effect.fail(httpError(status, out));
  })) as typeof inner.stations.requests.call;

  // The trusted devices it may dial, by base id, in the order `world`'s doc gives; each signs as a real one would.
  // (each answers what it is asked as the real one would, whatever the mode: an owner's or admin's app a newcomer
  // whose hello brings their log, an app of s1's their web page or their new app asking into their own lock)
  const devices: Dev[] = mode === "admit" ? [alice.app, bob.app] : mode === "chain" ? [alice.app, ...more] : [x.app, ...more];
  const ids = devices.map((d) => d.base.hex);
  const owners = [alice.app.base.hex, bob.app.base.hex, ...(mode === "chain" ? more.map((d) => d.base.hex) : [])];
  const signers = new Map([alice.app, bob.app, ...more].map((d) => [d.base.hex, d.signer]));
  const theirs = [x.app.base.hex, ...more.map((d) => d.base.hex)];
  const now = () => Math.floor(r.host.nowMs() / 1000);
  const approve = (hello: J, by: string): J => {
    // (the chain never moved: an entry of it, signed by the owner's device that approves it, as `Lock.append` signs)
    if (mode === "chain") {
      const chain = r.cloud.chains.get("ws")! as unknown as StationEntry[];
      const last = chain.at(-1)!;
      const e = signed({ v: 1, ws: "ws", seq: last.seq + 1, prev: stationHash(last), at: Math.max(last.at, now()), kind: "device", body: { id: base.hex, sub: "s1", kind: hello.kind === "web" ? "web" : "app", label: "Pixel", ...(typeof hello.sign_key === "string" ? { sign_key: hello.sign_key } : {}), ...(hello.kind === "web" ? { exp: now() + 30 * 86400 } : {}) } }, signers.get(by) ?? alice.app.signer);
      c.takeLock([...chain, e]);
      r.cloud.chains.set("ws", [...chain, e] as unknown as Entry[]);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    }
    if (owners.includes(by)) {
      alice.say("member", { sub: "s1", email: "s1@x.com", lock: stationHash(hello.log[0]), role: "member" }, "ws");
      bring(alice);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    }
    if (hello.kind === "web") {
      x.add("web", { id: base.hex, label: "Chrome", exp: now() + 30 * 86400 }, x.app.key, now());
      bring(x);
      return { t: "approved", workspaces: ["ws"], failed: [] };
    }
    x.add("device", { key: hello.personal.key, id: base.hex, label: "Pixel", ...(typeof hello.sign_key === "string" && !o.unsaid ? { sign_key: hello.sign_key } : {}) });
    // (a member the chain carries unbound: bound to the log their device puts this one on, in the same ask:
    // views/lock.ts `bindsFor`)
    if (mode === "carried" && !x.entries.some((e) => e.kind === "ws")) x.say("bind", { key: x.app.signer.id, sig: x.app.signer.sign(bindBytes("ws", "s1", x.genesis, stationHash(moved))) }, "ws");
    bring(x);
    return { t: "approved", workspaces: ["person:s1"], failed: [], chains: { s1: x.entries } };
  };
  /// The code each shows (as typed on the new device), and how each goes.
  const codes = new Map([...ids, ...owners, ...theirs].map((id, i) => [id, `24681${i}`]));
  const faults = new Map<string, Fault>([...owners, ...theirs].map((id) => [id, { kind: "live" }]));
  /// What came of it: those dialled, those that showed their code, those that signed it in (and when).
  const dialled: string[] = [];
  const shown: string[] = [];
  const signedBy: { id: string; at: number }[] = [];
  const serve = (id: string, there: Awaited<ReturnType<typeof pipe>>[1]) => Effect.gen(function* () {
    const hello = (yield* there.next()) as J;
    if (hello === null) return;
    const where = owners.includes(id) ? (mode === "chain" || (Array.isArray(hello.log) && hello.log.length > 0) ? ["ws"] : []) : !theirs.includes(id) ? [] : hello.kind === "web" ? ["ws"] : hello.personal ? ["person:s1"] : [];
    if (where.length === 0) return yield* there.send({ t: "no", error: "not_here" });
    let f = faults.get(id)!;
    if (f.kind === "never") return yield* Effect.never;
    if (f.kind === "late") {
      yield* Effect.sleep(f.ms ?? 0);
      f = f.then ?? { kind: "live" };
    }
    yield* there.send({ t: "code", workspaces: where });
    shown.push(id);
    if (f.kind === "quiet") return yield* Effect.never;
    if (f.kind === "deny") {
      yield* Effect.sleep(f.ms ?? 0);
      return yield* there.send({ t: "no", error: "denied" });
    }
    let left = 5;
    for (;;) {
      const m = (yield* there.next()) as J;
      if (m === null || m.t !== "pake") return;
      const p = pakeStart(codes.get(id)!, pairSession(base.hex, id, where), (b) => b.fill(5));
      const keys = pakeKeys(p, unhex(m.y), "trusted")!;
      yield* there.send({ t: "pake", y: hex(p.share), mac: hex(keys.mine), ...(hello.personal ? { roots: { s1: x.genesis } } : {}) });
      const c = (yield* there.next()) as J;
      if (c === null) return;
      if (c.t === "confirm" && sameMac(keys.theirs, unhex(c.mac ?? ""))) break;
      if (--left <= 0) return yield* there.send({ t: "no", error: "tries" });
      yield* there.send({ t: "wrong", left });
    }
    if (f.kind === "mute") return yield* Effect.never;
    const signs = Effect.andThen(Effect.sleep(f.ms ?? 0), Effect.sync(() => {
      signedBy.push({ id, at: r.host.nowMs() });
      return approve(hello, id);
    }));
    if (f.kind === "cut" || f.kind === "gone") {
      if (f.kind === "cut") there.close();
      inner.runner.fork(Effect.asVoid(signs));
      return yield* Effect.never;
    }
    yield* there.send(yield* signs);
  });
  dialer.open = (_inner, id) => Effect.flatMap(Effect.promise(() => pipe()), ([here, there]) => Effect.sync(() => {
    dialled.push(id);
    inner.runner.fork(Effect.ignore(serve(id, there)));
    return here;
  }));

  await settle(r, inner, read(inner, "ws"));
  assert.equal(held(inner, "ws")?.entries.at(-1)?.kind, moving ? "moved" : "genesis", "the chain held");
  const lock = await r.watch({ topic: "lock", workspace: "ws" });
  /// The page as it stands once what was set going settled.
  const page = async () => {
    await r.host.time.pass(2_000);
    return (await lock()) as J;
  };
  /// A call as the app makes it, the clock stepped 10 ms at a time: how long until it was answered (null: none in
  /// `most` ms), and the answer (`ok` or `error`).
  const timed = async (name: string, params: Record<string, unknown>, most = 60_000) => {
    const ui = r.core.connect();
    const n = 90_000 + Math.floor(Math.random() * 1e6);
    call(r.core, ui, n, name, params);
    const t0 = r.host.nowMs();
    let answer: Record<string, J> | undefined;
    // (10 ms steps at first, where an answer comes at once; 100 ms after)
    while (answer === undefined && r.host.nowMs() - t0 < most) {
      await r.host.time.pass(r.host.nowMs() - t0 < 300 ? 10 : 100);
      for (const [, m] of r.host.takeEmitted()) {
        const msg = m as Record<string, unknown>;
        if (msg.id === n && ("ok" in msg || "error" in msg)) answer = msg as Record<string, J>;
      }
    }
    return { ms: answer === undefined ? null : r.host.nowMs() - t0, answer };
  };
  const why = () => `refused ${st.refusals.length}, last ${String(st.refusals.at(-1)?.error).slice(0, 80)}; admitted ${st.admitted}; standing ${inner.adb.personal().standing("s1")}; dialled ${dialled.map((d) => d.slice(0, 6))}; shown ${shown.map((d) => d.slice(0, 6))}; signed ${signedBy.map((s) => s.id.slice(0, 6))}`;
  /// The workspace read as a link that opens reads it, and what was set going settled.
  const sync = async () => {
    await settle(r, inner, Effect.ignore(read(inner, "ws")));
    return page();
  };
  const page2 = o.w2 ? await r.watch({ topic: "lock", workspace: "w2" }) : null;
  /// `w2`'s page as it stands once what was set going settled.
  const pageOf2 = async () => {
    await r.host.time.pass(2_000);
    return (await page2!()) as J;
  };
  return { pageOf2, before, sync, owners, theirs, r, inner, c, st, mode, ids, codes, faults, dialled, shown, signedBy, alice, bob, x, base, A, page, timed, hello, admits, why, cloudKeeps };
}

/// `e` run on the core, the clock stepped until it ends (30 s at most).
async function settle(r: Awaited<ReturnType<typeof rig>>, inner: Awaited<ReturnType<typeof rig>>["core"]["inner"], e: Effect.Effect<unknown, unknown>) {
  let out: unknown = null;
  inner.runner.fork(Effect.match(e, { onSuccess: () => void (out = "ok"), onFailure: (error) => void (out = { error }) }));
  await r.host.time.passUntil(30_000, () => out !== null);
  assert.ok(out !== null, "no answer");
  await r.host.time.pass(100);
}

/// The strings a topic's value says anywhere in it, for the words people see.
export function stringsOf(v: unknown, out: string[] = []): string[] {
  if (typeof v === "string") out.push(v);
  else if (Array.isArray(v)) for (const x of v) stringsOf(x, out);
  else if (v !== null && typeof v === "object") for (const x of Object.values(v)) stringsOf(x, out);
  return out;
}

/// What a page shown to people never says: a lock's own name for a person's lock, nor a value not made.
export function cleanText(v: unknown): string | null {
  const text = JSON.stringify(v ?? null);
  for (const bad of ["person:", "undefined", "NaN", "个人锁"]) if (text.includes(bad)) return `says ${bad}: …${text.slice(Math.max(0, text.indexOf(bad) - 80), text.indexOf(bad) + 40)}…`;
  return null;
}
