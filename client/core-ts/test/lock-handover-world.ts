// The world of lock-handover.test.ts and lock-state-invariants.test.ts: a workspace's chain this device's genesis (s1
// the owner, this device its app; r2 bob an admin, r3 xena a member, each with an app device; stations A and B, the
// station's own code) and each member's `person` binding to their own log; w2, another workspace of s1's, lists
// station D, which takes nothing of `ws`. `setUp`'s options say what differs.
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect } from "effect";
import { type Entry as StationEntry, LockRefusal, entryHash as stationHash, fold as stationFold } from "../../../shared/lock.ts";
import { Cloud, writeState } from "../../../station/src/cloud/state.ts";
import { inLock, inLockBringing, lockPartRoute, lockRoute, refusalOf } from "../../../station/src/mesh/serve.ts";
import { deviceBuildsOf } from "../../../station/src/mesh/device-builds.ts";
import { buildOf } from "../../../station/src/api/oldest.ts";
import { HAND_OVER_FROM } from "../src/lock-handover.ts";
import { type Dev, type Key, Log, bring, dev, ed, signed, viewerOf } from "../../../station/test/lock-moved-world.ts";
import { d4Diff, d4Old } from "../../../station/test/lock-roster4-model.ts";
import { key, signed as simSigned } from "../../../station/test/lock-world-sim.ts";
import type { CoreError } from "../src/error.ts";
import { type Entry, type Signer, canonical, entryHash, next } from "../src/lock.ts";
import { bodyHash } from "../src/lock-moved.ts";
import { Core } from "../src/core.ts";
import { httpError } from "../src/station/requests.ts";
import { HostWire } from "../src/station/wire.ts";
import { hex, utf8 } from "../src/util.ts";
import { handOver, held, inForceOf, read } from "../src/views/lock.ts";
import { serveTrusted, tryOne } from "../src/views/pair.ts";
import { stationClock } from "./station-clock.ts";
import { grant, pipe, rig, withoutMesh } from "./lock-rig.ts";
import { signIn } from "./helpers.ts";

/// The device's clock as each test begins: thirty days past HAND_OVER_FROM, since when chains are handed over by
/// themselves (a genesis of before counts its fourteen days from then, `mayHandOver`).
export const T0 = HAND_OVER_FROM! + 30 * 86400;
/// The stations' clock: the core's (each test's rig sets it, station-clock.ts).
let clock = () => 0;

export const MINE = 7001;
export const seedOf = (n: number) => {
  const s = new Uint8Array(32);
  new DataView(s.buffer).setUint32(28, n);
  return s;
};
export const SETTINGS = (keys: unknown) => ({ origins: ["https://stillfail.test"], rp_id: "stillfail.test", cloud_keys: keys });

export type Asked = { at: string; method: string; path: string; body: string; got?: number };
export type Opts = {
  /// More members of the chain: `ready: false` one with an app device and no log bound (r4); `web` one with only a web
  /// page (r5, an admin); `none` one with no device (r6, a member).
  more?: ("notReady" | "web" | "none")[];
  /// s1's own web page on the chain.
  myWeb?: boolean;
  /// s1 an admin (s0 the owner, its genesis signer); this device on the chain with another signer; s1's log not pinned;
  /// s1 a second owner (`second`: s0 the first, its genesis signer, bound to a log of their own as the others).
  mine?: "admin" | "otherKey" | "unpinned" | "second";
  /// Chains handed over by themselves here (`Host.handOverAuto`; off by default: they are all the same, the device's
  /// clock past HAND_OVER_FROM).
  auto?: boolean;
  /// The device's clock before HAND_OVER_FROM (2026-10-06), where chains are not handed over by themselves.
  early?: boolean;
  /// The genesis's `at` (unix seconds; 1000 by default).
  genesisAt?: number;
  /// With `second`: s0 made an admin by s1 after the bindings (the genesis's person no owner any more).
  firstLowered?: boolean;
  /// The host offers `lock.handOver` (by default).
  flag?: boolean;
  /// bob (r2) an owner, not an admin.
  bobOwner?: boolean;
  /// The workspace's members as the cloud's view says them (none by default).
  view?: { sub: string; email: string; role: string }[];
  /// Members whose log no station keeps (their app device never brought it).
  unbrought?: ("r2" | "r3")[];
  /// s1 bound to no log on the chain (with `second`: s0, the first owner, moves it), with a phone on the chain not on
  /// s1's log (`s1Phone`), so that this device binds nothing on the chain before the move (views/lock.ts `bindPerson`).
  unbound?: boolean;
  /// With `unbound` and `second`: s1 has no log of their own at all (apps from before own logs: none kept here nor by a
  /// station, this device holding no key of its own for one), the chain moved by s0 before this device first reads it (a
  /// device reading an unmoved chain begins its person's lock with nobody asked, views/lock.ts `ownLockFor`).
  noLog?: boolean;
  /// So many more members (m0, m1, …), each with an app device and a log of their own bound and brought.
  crowd?: number;
  /// Each of the crowd with a phone on their log alone (put on by their app device, never on the chain).
  crowdPhones?: boolean;
  /// Stations (by name) that serve what a moved chain is made of and do not say `heads` (GET /lock/heads, POST
  /// /lock/given: the build before), read whole.
  noHeads?: string[];
  /// A third station of the workspace, C.
  third?: boolean;
  /// Stations (by name) whose GET /lock does not say they serve `bodies`, `logs` and `builds`, nor their GET
  /// /lock/person `logs` and `builds` (stations from before), and those not reached at all, from the start.
  old?: string[];
  down?: string[];
  /// Stations that serve `bodies`, `logs` and `builds` but do not say they read a moved chain as it moved (`serves`
  /// without `carried`, on GET /lock and GET /lock/person: a station of the build before this one).
  noCarried?: string[];
  /// Stations whose GET /lock is not answered (reached otherwise: GET /lock/person answers), from the start.
  lockDown?: string[];
  /// The build each member's app device on the chain was seen on by every station, by its person ("" none said, null
  /// never seen); every other one seen on `0.1.0` (an unnumbered build, able) as the stations start.
  builds?: Record<string, string | null>;
  /// D, the station of s1's other workspace, says nothing of the devices' builds on GET /lock/person (one from before).
  dOld?: boolean;
};

export async function setUp(o: Opts = {}) {
  const g = grant();
  const base = ed();
  // s1's own log: this device on it by its key there (its seed sealed here), no signer said yet (said in the ask)
  const k = key(MINE);
  const myLog = [simSigned({ v: 1, ws: "person:s1", seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub: "s1", device: { key: k.id, id: base.hex, label: "s1's app" } } } as Omit<StationEntry, "sig">, k)];
  const gMe = stationHash(myLog[0]!);
  const bob = new Log("r2"), xena = new Log("r3"), r4 = new Log("r4"), s0 = dev(), first = new Log("s0");
  const A = ed().hex, B = ed().hex, C = ed().hex, D = ed().hex, WEB = ed(), WEB5 = ed();
  const ours = o.third ? [A, B, C] : [A, B];
  const crowd = Array.from({ length: o.crowd ?? 0 }, (_, i) => new Log(`m${i}`));
  if (o.crowdPhones) for (const l of crowd) onLog(l, dev(), `${l.sub}'s phone`);
  let mine: Signer | null = null;
  let now = 0;
  const other = ed();
  const appOf = (sub: string, d: Dev) => ({ id: d.base.hex, sub, kind: "app", label: `${sub}'s app`, sign_key: d.signer.id });
  const r = await rig((signer) => {
    mine = signer;
    const members = [{ sub: "s1", email: "a@x.com", role: o.mine === "admin" ? "admin" : "owner" }, { sub: "r2", email: "b@x.com", role: o.bobOwner ? "owner" : "admin" }, { sub: "r3", email: "c@x.com", role: "member" }];
    const devices: Record<string, unknown>[] = [{ id: base.hex, sub: "s1", kind: "app", label: "s1's app", sign_key: o.mine === "otherKey" ? other.id : signer.id }, appOf("r2", bob.app), appOf("r3", xena.app)];
    if (o.mine === "admin") members.unshift({ sub: "s0", email: "o@x.com", role: "owner" }), devices.unshift(appOf("s0", s0));
    if (o.mine === "second") members.unshift({ sub: "s0", email: "o@x.com", role: "owner" }), devices.unshift(appOf("s0", first.app));
    if (o.more?.includes("notReady")) members.push({ sub: "r4", email: "d@x.com", role: "member" }), devices.push(appOf("r4", r4.app));
    if (o.more?.includes("web")) members.push({ sub: "r5", email: "e@x.com", role: "admin" });
    if (o.more?.includes("none")) members.push({ sub: "r6", email: "f@x.com", role: "member" });
    for (const l of crowd) members.push({ sub: l.sub, email: `${l.sub}@x.com`, role: "member" }), devices.push(appOf(l.sub, l.app));
    const e = next("ws", null, o.genesisAt ?? 1000, "genesis", { owner: members[0]!.sub, ...SETTINGS(g.keys), members, devices, passkeys: [], stations: ours.map((k, i) => ({ key: k, name: "abc"[i]! })), gateways: [] });
    const by = o.mine === "admin" ? s0.signer : o.mine === "second" ? first.app.signer : o.mine === "otherKey" ? other : null;
    return { ws: by === null ? signer.sign(e) : (signed(e as Omit<StationEntry, "sig">, by) as unknown as Entry) };
  }, (host) => {
    // (the device's clock thirty days past HAND_OVER_FROM, T0 below: chains are handed over by themselves from it)
    // (signed in again then: the account's token runs an hour from when it was signed in)
    if (o.early !== true) host.advance(T0 * 1000 - host.nowMs()), signIn(host);
    host.handOverByTests = o.flag !== false;
    host.handOverAuto = o.auto === true;
    now = Math.floor(host.nowMs() / 1000);
    if (o.mine === "unpinned" || o.noLog === true) return;
    host.storage.set(`personal-lock-${hex(utf8("s1"))}`, utf8(JSON.stringify(myLog)));
    host.storage.set("personal-signer-id", utf8(k.id));
    host.secure.set("personal-signer", { value: seedOf(MINE), user: true });
  }, ours, ours, undefined, [D], o.view === undefined ? {} : { members: o.view });
  clock = () => r.host.nowMs();
  stationClock(clock);
  let inner = r.core.inner;
  const signer = mine! as Signer;
  // The chain: the genesis, each member's binding, by their own device; the extras' web page.
  const chain: Entry[] = [r.cloud.chains.get("ws")![0]!];
  const after = (by: Key | Signer, kind: string, body: unknown): Entry => {
    const last = chain[chain.length - 1]!;
    const e = next("ws", { seq: last.seq, hash: entryHash(last), genesis: entryHash(chain[0]!) }, Math.max(last.at, now), kind, body);
    const s = "signBytes" in by ? by.sign(e) : (signed(e as Omit<StationEntry, "sig">, by) as unknown as Entry);
    chain.push(s);
    // (an app device approved on the chain meanwhile: seen by the stations on an able build, as it would be as it asks)
    if (kind === "device" && (body as { kind?: string }).kind === "app") for (const c of made) deviceBuildsOf(c).saw((body as { id: string }).id, 0, Math.floor(clock() / 1000));
    return s;
  };
  const made: Cloud[] = [];
  if (o.unbound !== true) after(o.mine === "otherKey" ? other : signer, "person", { sub: "s1", person: gMe });
  const s1Phone = dev();
  if (o.unbound === true) after(signer, "device", { id: s1Phone.base.hex, sub: "s1", kind: "app", label: "s1's phone", sign_key: s1Phone.signer.id });
  after(bob.app.signer, "person", { sub: "r2", person: bob.genesis });
  after(xena.app.signer, "person", { sub: "r3", person: xena.genesis });
  if (o.mine === "second") after(first.app.signer, "person", { sub: "s0", person: first.genesis });
  for (const l of crowd) after(l.app.signer, "person", { sub: l.sub, person: l.genesis });
  if (o.firstLowered) after(signer, "member", { sub: "s0", email: "o@x.com", role: "admin" });
  if (o.myWeb) after(signer, "device", { id: WEB.hex, sub: "s1", kind: "web", label: "s1's browser", exp: now + 10 * 86400 });
  if (o.more?.includes("web")) after(o.mine === "admin" ? s0.signer : signer, "device", { id: WEB5.hex, sub: "r5", kind: "web", label: "r5's browser", exp: now + 10 * 86400 });
  if (o.noLog === true) after(first.app.signer, "moved", { root: first.genesis });
  r.cloud.chains.set("ws", chain);
  // Stations A and B, the station's own code, the chain pinned and the members' logs heard
  const station = (id: string): Cloud => {
    const data = mkdtempSync(join(tmpdir(), "lock-handover-"));
    writeState(data, { origin: "https://stillfail.test", station: id, workspace: "ws", workspace_name: "W", name: id.slice(0, 4), relay_url: "", relay_urls: [], grant_keys: g.keys, peers: ours.map((p, i) => ({ id: p, name: `s${i}` })), revocations: [] } as never);
    const c = new Cloud(data, false);
    if (o.noLog === true) c.takeLock(chain.slice(0, -1) as unknown as StationEntry[]), c.takeLock(chain as unknown as StationEntry[], null, true);
    else c.takeLock(chain as unknown as StationEntry[]);
    // (each member's log as their app device brought it to the station, POST /lock/person)
    for (const l of [bob, xena, ...(o.mine === "second" ? [first] : []), ...crowd]) if (!o.unbrought?.includes(l.sub as "r2" | "r3")) bring(c, l, false, "ws");
    // (each member's app device on the chain seen asking on the build `builds` says, this one's own aside: it runs this)
    for (const [did, d] of stationFold(chain as unknown as StationEntry[], null).devices) {
      if (d.kind !== "app" || did === base.hex) continue;
      const b = o.builds?.[d.sub] === undefined ? "0.1.0" : o.builds[d.sub]!;
      if (b !== null) deviceBuildsOf(c).saw(did, buildOf(b), Math.floor(clock() / 1000));
    }
    made.push(c);
    return c;
  };
  const stations: { A: Cloud; B: Cloud; C?: Cloud } = { A: station(A), B: station(B), ...(o.third ? { C: station(C) } : {}) };
  const nameOf = (id: string) => (id === A ? "A" : id === B ? "B" : id === C ? "C" : id === D ? "D" : null);
  const st = { silent: false, down: new Set<string>(o.down ?? []), old: new Set<string>(o.old ?? []), noCarried: new Set<string>(o.noCarried ?? []), noHeads: new Set<string>(o.noHeads ?? []), lockDown: new Set<string>(o.lockDown ?? []), dOld: o.dOld === true, dSince: Math.floor(clock() / 1000), asked: [] as Asked[], hook: null as null | (() => void) };
  const viewer = viewerOf("s1", { base }, "owner", "ws");
  const route = (c: Cloud, method: string, path: string, body: unknown): Effect.Effect<unknown, CoreError> => {
    const [p, q] = path.split("?") as [string, string | undefined];
    // (POST /lock/given is a read)
    if (st.silent && method === "POST" && p !== "/lock/given") return Effect.never;
    const buf = Buffer.from(body === null || body === undefined ? "" : JSON.stringify(body));
    const [status, said] = p === "/lock" ? lockRoute(c, method, q ? [...new URLSearchParams(q)] : [], buf, viewer as never) : lockPartRoute(c, p.slice("/lock/".length), method, buf, viewer as never);
    // (a station from before: its rules know no `moved`, and it serves none of what a moved chain is made of)
    const from = Object.entries(stations).find(([, x]) => x === c)?.[0] ?? "";
    const out = p === "/lock" && st.old.has(from) && status === 200 ? { ...(said as object), serves: ((said as { serves?: string[] }).serves ?? []).filter((x) => x !== "bodies" && x !== "logs" && x !== "builds" && x !== "carried" && x !== "heads") }
      : p === "/lock" && st.noCarried.has(from) && status === 200 ? { ...(said as object), serves: ((said as { serves?: string[] }).serves ?? []).filter((x) => x !== "carried" && x !== "heads") }
      : p === "/lock" && st.noHeads.has(from) && status === 200 ? { ...(said as object), serves: ((said as { serves?: string[] }).serves ?? []).filter((x) => x !== "heads") }
      : p === "/lock/person" && method === "GET" && (st.old.has(from) || st.noCarried.has(from)) ? { chains: (said as { chains: unknown }).chains, ...(st.old.has(from) ? {} : { serves: ["logs", "builds"] }) }
      : said;
    // (the first time statements were taken: what the test changes before the `moved`)
    if (status === 200 && p === "/lock/person" && Array.isArray((body as { bodies?: unknown })?.bodies) && st.hook) {
      const h = st.hook;
      st.hook = null;
      h();
    }
    const asked = st.asked.at(-1);
    if (asked !== undefined && asked.path === path && asked.got === undefined) asked.got = Buffer.byteLength(JSON.stringify(out));
    return status === 200 ? Effect.succeed(out) : Effect.fail(httpError(status, out));
  };
  // (this device's mesh, and its requests to the workspace's stations, on a core as it starts: `restart`)
  const install = (inner: typeof r.core.inner) => {
    inner.mesh = () => withoutMesh(base.hex);
    const original = inner.stations.requests.call.bind(inner.stations.requests);
    inner.stations.requests.call = ((addr: { toString(): string }, method: string, path: string, body: unknown, ...rest: unknown[]) => {
      const [ws, id] = addr.toString().split("/");
      const n = id === undefined ? null : nameOf(id);
      if (path.startsWith("/lock") && n !== null && (n === "D" || (stations as Record<string, Cloud | undefined>)[n] !== undefined)) {
        const at = `${ws}/${n}`;
        st.asked.push({ at, method, path, body: JSON.stringify(body ?? null) });
        // (D, w2's: its GET /lock/person, keeping no log of s1's, says it serves logs and the devices' builds unless `dOld`)
        if ((id === D || ws !== "ws") && method === "GET" && path === "/lock/person") return Effect.succeed(st.dOld ? { chains: [] } : { chains: [], serves: ["logs", "builds"], builds: { since: st.dSince, devices: {} } });
        if (id === D || ws !== "ws") return method === "POST" ? Effect.succeed({}) : Effect.fail(httpError(404, { error: "no route" }));
        if (st.down.has(at.slice(-1)) || (st.lockDown.has(n) && method === "GET" && /^\/lock(\?|$)/.test(path))) return Effect.fail(httpError(503, { error: "not reached" }));
        return route((stations as Record<string, Cloud | undefined>)[n]!, method, path, body);
      }
      return (original as (...x: unknown[]) => unknown)(addr, method, path, body, ...rest);
    }) as typeof inner.stations.requests.call;
  };
  install(inner);
  /// The app started anew on the same host (test/vault.test.ts's): its database and secure storage as they were,
  /// nothing of the run before in memory; the lock is read as the sync reads it as it starts.
  const restart = async () => {
    await Effect.runPromise(inner.data.written);
    r.core.close();
    r.host.takeEmitted();
    r.core = await Core.create(r.host, { clock: r.host.time.clock, sample: 0, wire: () => new HostWire(r.host) });
    inner = r.core.inner;
    install(inner);
    await r.host.time.pass(500);
  };
  const run = async <X>(e: Effect.Effect<X, any>): Promise<{ ok?: X; error?: CoreError }> => {
    let out: { ok?: X; error?: CoreError } | null = null;
    inner.runner.fork(Effect.match(e, { onSuccess: (ok) => void (out = { ok }), onFailure: (error) => void (out = { error }) }));
    await r.host.time.passUntil(30_000, () => out !== null);
    assert.ok(out !== null, "no answer");
    await r.host.time.pass(100);
    return out;
  };
  await run(inner.adb.personal().refresh("s1"));
  await run(read(inner, "ws"));
  // (where chains are handed over by themselves and nothing holds it back, it may have moved as it was read)
  assert.ok((held(inner, "ws")?.entries.length ?? 0) >= chain.length, "the chain held");
  const asked = () => r.host.secureAsked.length;
  /// What this device's own log says past what it said before: each statement's kind and whom, its body's `prev`.
  const said = () => inner.adb.personal().entries("s1").slice(myLog.length).filter((e) => e.kind === "ws").map((e) => {
    const h = (e.body as { h: string }).h;
    const b = ((inner.data.record("lockBodies", "ws") as { bodies?: Record<string, unknown>[] } | null)?.bodies ?? []).find((x) => bodyHash(x) === h);
    return b === undefined ? { what: "ws (no body)", prev: null, h } : { what: `${b.kind} ${b.sub ?? (nameOf(String(b.key)) ?? "")}${b.role ? ` ${b.role}` : ""}`.trim(), prev: b.prev as string | null, h };
  });
  const hand = () => run(handOver(inner, "s1", "ws"));
  /// The chain's list as the model's D4 has it, by the station's own fold, rooted in s1's log.
  const d4Chain = (es: readonly Entry[]) => d4Old(stationFold(es as unknown as StationEntry[], null), gMe, Math.floor(r.host.nowMs() / 1000));
  /// Someone's first app device (`d`, with the log of their own `log`) asking this device as `sub`, the code shown here
  /// typed on it: the hello's answer and the proof's.
  const firstApp = async (sub: string, log: Log) => {
    const prompts = await r.watch({ topic: "lockPrompts" });
    const [trusted, phone] = await pipe();
    const id = log.app.base.hex;
    inner.runner.fork(serveTrusted(inner, id, base.hex, trusted));
    const first = await run(Effect.andThen(phone.send({ t: "hello", v: 1, workspaces: [{ ws: "ws", credential: g.credential("ws", id, sub) }], kind: "app", label: `${sub}'s app`, sign_key: log.app.signer.id, log: log.entries }), phone.next()));
    const answer = first.ok as { t: string };
    if (answer.t !== "code") return { answer, done: null };
    const code = ((await prompts()).pairing as { device: string; code: string }[]).find((p) => p.device === id)!.code;
    return { answer, done: await run(tryOne(inner, { id: base.hex, d: phone, workspaces: ["ws"] }, id, code)) };
  };
  /// An ask of the person's own lock's key for something else: grants signed (none: the ask alone).
  const askGrant = () => run(inner.adb.personal().signGrants("s1", [], "a grant"));
  return { r, get inner() { return inner; }, s1Phone, restart, first, signer, chain, after, stations, st, asked, said, hand, run, d4Chain, gMe, bob, xena, r4, crowd, base, WEB, WEB5, A, B, C, D, viewer, firstApp, g, askGrant, now: () => now };
}

/// A second app device of `log`'s person (`d`) as the product puts it on their own log: a device entry signed by the
/// first device there (personal-lock.ts `#addApproved`), with the key it signs the chain with.
export const onLog = (log: Log, d: Dev, label: string) => log.add("device", { key: d.key.id, id: d.base.hex, label, sign_key: d.signer.id });

/// The core's state in force as the model's D4 has one (test/lock-moved-check.ts's reading).
export function d4Core(inner: any) {
  const f = inForceOf(inner, "ws");
  const devs = (sub: string, kind: string) => [...f.f.devices.values()].filter((d: any) => d.sub === sub && d.kind === kind);
  return {
    on: f.said === "on" ? "on" : f.said,
    settings: f.settings ? canonical(f.settings) : "-",
    members: new Map([...f.f.members].map(([sub, m]) => [sub, { role: m.role, email: m.email, lock: f.f.persons.get(sub) ?? "none", apps: devs(sub, "app").map((d: any) => d.sign_key).sort(), webs: devs(sub, "web").map((d: any) => d.id).sort() }])),
    stations: [...f.f.stations.keys()].sort(),
  };
}
/// A station's state as the model's D4 has one (its own `locked`), rooted in `root`.
export const d4Station = (c: Cloud, root: string, now: number) => d4Old(c.locked(null)!.state!, root, now);
export const admitted = (sub: string, d: { base: Key }, role: string) => ({ viewer: viewerOf(sub, d, role, "ws"), exp: 4102444800, iat: 0, sid: "s" });


/// A device of `sub`'s (`k`) at a station's hello, as the mesh makes it: in, or refused with what the refusal tells it
/// (station/src/mesh/serve.ts `refusalOf`: left out, whom to ask, whether the list names an app of `sub`'s).
export const hello = (c: Cloud, sub: string, k: Key, role: string): { in: boolean; left?: { approvers: string[]; apps?: boolean } } => {
  const v = viewerOf(sub, { base: k }, role, "ws");
  const said = { lock: { device: k.hex, proof: v.lockDevice.proof } };
  try {
    inLockBringing(c, { viewer: v, exp: 4102444800, iat: 0, sid: "" } as never, role, v.device, said);
    return { in: true };
  } catch (e) {
    if (!(e instanceof LockRefusal)) throw e;
    return { in: false, left: (refusalOf(c, said, v.device, e, undefined, sub) as { left?: { approvers: string[]; apps?: boolean } }).left };
  }
};

/// Nothing said in this device's own log, nobody asked: what every handover here holds.
export const silent = (w: Awaited<ReturnType<typeof setUp>>) => {
  assert.equal(w.asked(), 0, "nobody asked");
  assert.deepEqual(w.said(), [], "nothing said in its log");
  assert.deepEqual(w.inner.adb.personal().entries("s1").filter((e) => e.kind === "web"), [], "no web page said in its log");
};
export const movedAt = (w: Awaited<ReturnType<typeof setUp>>) => Object.values(w.stations).map((c) => c.chain(null)?.state?.moved ?? null);
/// Each of the stations brought the chain as it stands here (as another keeper's), and the person logs of `logs`.
export const takeChain = (w: Awaited<ReturnType<typeof setUp>>, logs: Log[] = []) => {
  for (const c of Object.values(w.stations)) {
    c.takeLock([...w.chain] as unknown as StationEntry[]);
    for (const l of logs) bring(c, l, false, "ws");
  }
};
/// The chain's list before, at A, B and here, every one of `devices` let in by A.
export const asTheChain = async (w: Awaited<ReturnType<typeof setUp>>, before: ReturnType<Awaited<ReturnType<typeof setUp>>["d4Chain"]>, devices: [string, { base: Key }, string][]) => {
  await w.run(read(w.inner, "ws"));
  assert.equal(held(w.inner, "ws")?.entries.at(-1)?.kind, "moved", "the chain held moved");
  const now = Math.floor(w.r.host.nowMs() / 1000);
  assert.deepEqual(d4Diff(before, d4Core(w.inner)), [], "the state in force here is the chain's list before (the model's d4Old)");
  for (const [n, c] of Object.entries(w.stations)) assert.deepEqual(d4Diff(before, d4Station(c, w.gMe, now)), [], `${n}'s state is the chain's list before`);
  for (const [sub, d, role] of devices) {
    const a = admitted(sub, d, role);
    assert.equal(inLock(w.stations.A, a as never, role, a.viewer.device).viewer.role, role, `${sub}'s device ${d.base.hex.slice(0, 6)} let in by A`);
  }
};
