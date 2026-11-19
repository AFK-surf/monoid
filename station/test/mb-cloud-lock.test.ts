// The station's lock in MoonBit (station/mb src/cloud_lock, `stillfail-reader-harness --builder harness-cloud-lock`) held to the
// TypeScript it is written from (src/cloud/key.ts, signed.ts, log-keep.ts, lock-bodies.ts, lock.ts, state.ts,
// mesh/person-chains.ts, moved-pin.ts, device-builds.ts, api/moved-from.ts and the lock's routes of mesh/serve.ts): the
// same events given both, each step's answer the same (the states in force, GET /lock, /lock/heads, POST /lock/given,
// each refusal's words) and every file each writes the same, byte for byte, read again the same.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { LOGS_ANY_FROM_BUILD, LOGS_BEFORE, MOVED_FROM_BUILD, ROOT_OUT_FROM_BUILD } from "../src/api/moved-from.ts";
import { loadKey, sha256hex } from "../src/cloud/key.ts";
import {
  type Entry, type LockState, LockRefusal, admit, asEntry, bodyHash, bodyRefusal, canonical, devicesFor, endpointBytes, endpointProof, entryHash, fold,
  lockChain, lowerRole, memberWithEmail, membersWithEmail, personChain, personFold, roster4Moved, shortCode, sigValid, signer, state4Moved,
  taggedSigValid, validKeyId, wsTag,
} from "../src/cloud/lock.ts";
import { keep, rechoose } from "../src/cloud/log-keep.ts";
import { signedPost } from "../src/cloud/signed.ts";
import { Cloud, joinedOf, personChainsOf, readState, rigsOf, waysSaidOf, writeState } from "../src/cloud/state.ts";
import { wall } from "../src/ops/fibers.ts";
import { deviceBuildsOf } from "../src/mesh/device-builds.ts";
import { answerLock } from "../src/mesh/lock-sync.ts";
import { pinBrought, pinMoved } from "../src/mesh/moved-pin.ts";
import { answerBodies, answerPerson } from "../src/mesh/person-sync.ts";
import { lockPartRoute, lockRoute, movedFloor, movedTooOld, refusalOf } from "../src/mesh/serve.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { WS as RWS, bases, genesisOf, key, nextOf, rng, signers } from "./lock-chains.ts";
import { bindBytes } from "./lock-roster4-model.ts";
import { Log, WS, WS2, ed, handover, signed, viewerOf, world } from "./lock-moved-world.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

let NOW = 2_000_000;
mock.method(wall, "now", () => NOW * 1000);

const dirs: string[] = [];
const fresh = (prefix: string) => {
  const d = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(d);
  return d;
};

type Json = any;

/// The program, asked a line at a time.
class Program {
  #child: ChildProcess;
  #next = 0;
  #waiting = new Map<number, (v: Json) => void>();
  constructor() {
    this.#child = spawn(binary!, ["--builder", "harness-cloud-lock", "--shell-dir", fresh("cloud-lock-shell-")], { stdio: ["pipe", "pipe", "inherit"] });
    createInterface({ input: this.#child.stdout! }).on("line", (line) => {
      const said = JSON.parse(line);
      this.#waiting.get(said.id)?.(said);
      this.#waiting.delete(said.id);
    });
  }
  ask(op: string, args: Json = {}): Promise<Json> {
    const id = ++this.#next;
    return new Promise((resolve) => {
      this.#waiting.set(id, resolve);
      this.#child.stdin!.write(`${JSON.stringify({ ...args, id, op })}\n`);
    });
  }
  close() {
    this.#child.stdin!.end();
  }
}

let program: Program | null = null;
const mb = () => {
  if (program === null) {
    program = new Program();
    void program.ask("now", { secs: NOW });
  }
  return program;
};
after(() => {
  program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

// ── the TypeScript's answers, in the program's shapes ─────────────────────────────────────────────────────────────

const pairs = <T>(m: Map<string, T>) => [...m].map(([k, v]) => [k, v]);
function stateJson(s: LockState): Json {
  return {
    ws: s.ws, seq: s.seq, head: s.head, genesis: s.genesis, origins: s.origins, rp_id: s.rp_id, cloud_keys: s.cloud_keys,
    members: pairs(s.members), devices: pairs(s.devices), signKeys: pairs(s.signKeys), passkeys: pairs(s.passkeys), signed: [...s.signed],
    stations: pairs(s.stations), gateways: [...s.gateways], persons: pairs(s.persons), disabled: s.disabled, ...(s.moved !== undefined ? { moved: s.moved } : {}),
  };
}
const lockedJson = (l: { state: LockState | null; waiting?: true } | null) => (l === null ? null : { state: l.state === null ? null : stateJson(l.state), ...(l.waiting === true ? { waiting: true } : {}) });
const keptJson = (k: { entries: Entry[]; aside?: Entry[] }) => ({ entries: k.entries, aside: k.aside ?? [] });
const pairsOf = (xs: [string, unknown[]][]) => xs.map(([g, es]) => [g, es]);
const asJson = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

/// The TypeScript Clouds of the test, by the name the program's are opened by.
const clouds = new Map<string, Cloud>();
const personRules = (genesis: string, ws: string) => ({ chain: (all: Entry[]) => personChain(all, genesis), pre: (e: Entry) => (e.ws !== ws ? "an entry of another lock" : null) });

async function tsAnswer(op: string, a: Json): Promise<Json> {
  const ws = a.ws ?? null;
  switch (op) {
    case "now": NOW = a.secs; return null;
    case "canonical": return canonical(a.value);
    case "entryHash": return entryHash(a.entry);
    case "asEntry": return asEntry(a.value);
    case "sigValid": return sigValid(a.sig, a.hash, a.origins, a.rp_id, a.passkey === true);
    case "validKeyId": return validKeyId(a.key);
    case "endpointProof": return endpointProof(a.ws, a.base, a.endpoint, a.proof);
    case "taggedSigValid": return taggedSigValid(a.key, a.sig, a.tag, a.digest);
    case "sha256hex": return sha256hex(a.text);
    case "shortCode": return shortCode(a.base);
    case "lowerRole": return lowerRole(a.a, a.b);
    case "wsTag": return wsTag(a.ws, a.genesis);
    case "bodyHash": return bodyHash(a.body);
    case "fold": return stateJson(fold(a.entries, a.now ?? null));
    case "lockChain": return asJson(lockChain(a.entries, a.root));
    case "personChain": return asJson(personChain(a.entries, a.root));
    case "personFold": return asJson(personFold(a.entries, a.sub));
    case "admit": {
      const { device, role } = admit(fold(a.entries, null), a.who, NOW);
      return { device: device.id, role };
    }
    case "signer": return signer(fold(a.entries, null), { key: a.key }, a.at ?? null);
    case "emails": {
      const s = fold(a.entries, null);
      return { first: memberWithEmail(s, a.email), all: membersWithEmail(s, a.email), devices: devicesFor(s, a.sub) };
    }
    case "state4Moved": {
      const s = state4Moved(a.ws, a.chain, a.chains, a.bodies, NOW);
      return { on: s.on, state: stateJson(s.state), rootIn: s.rootIn };
    }
    case "roster4Moved": return asJson(roster4Moved(a.ws, a.chain, a.chains, a.bodies, a.without ?? []));
    case "bodyRefusal": return bodyRefusal(a.ws, a.body, a.commits);
    case "keepLog": {
      const t = a.brought === undefined ? rechoose({ entries: a.entries, aside: a.aside }, personRules(a.genesis, a.logWs)) : keep({ entries: a.entries, aside: a.aside }, a.brought, personRules(a.genesis, a.logWs));
      return asJson({ ...t, kept: { entries: t.kept.entries, aside: t.kept.aside } });
    }
    case "loadKey": {
      const k = loadKey(a.data);
      return { id: k.id, signature: k.sign(a.message) };
    }
    case "signedRequest": {
      const k = loadKey(a.data);
      let seen: Json = null;
      const was = NOW;
      NOW = a.ts;
      try {
        await signedPost({ state: a.state } as never, k, a.path, a.tag, a.value, "still.fail cloud", async (url, init) => {
          seen = { url, headers: (({ "content-type": ct, "x-stillfail-station": st, "x-stillfail-ts": ts, "x-stillfail-signature": sig }) => ({ "content-type": ct, "x-stillfail-station": st, "x-stillfail-ts": ts, "x-stillfail-signature": sig }))(init!.headers as Record<string, string>), body: init!.body };
          return new Response("");
        });
      } finally {
        NOW = was;
      }
      return seen;
    }
    case "open": clouds.set(a.at, new Cloud(a.data, false)); return null;
    case "readState": return asJson(readState(a.data));
    case "writeState": writeState(a.data, a.state); return null;
    case "joinedOf": return asJson(joinedOf(a.raw));
    case "rigsOf": return asJson(rigsOf(a.raw));
    case "waysSaidOf": return asJson(waysSaidOf(a.raw));
    case "resetLock": return Cloud.resetLock(a.data);
  }
  const c = clouds.get(a.at)!;
  const chains = personChainsOf(c);
  switch (op) {
    case "state": return asJson(c.state);
    case "takeLock": return c.takeLock(a.entries, ws, a.fork === true);
    case "keepLock": {
      const t = c.keepLock(a.entries, ws, a.fork === true);
      return asJson({ taken: t.taken, off: t.off, refusal: t.refusal?.message ?? null });
    }
    case "locked": return lockedJson(c.locked(ws));
    case "chain": return lockedJson(c.chain(ws));
    case "list": return lockedJson(c.list(ws));
    case "rosterOf": return lockedJson(c.rosterOf(ws));
    case "waiting": return c.waiting(ws);
    case "kept": {
      const l = c.chain(ws) as { entries: Entry[]; aside?: Entry[] } | null;
      return l === null ? null : keptJson(l);
    }
    case "rootOut": return c.rootOut(ws);
    case "needs": return [...c.needs(ws)];
    case "logsOf": return c.logsOf(ws);
    case "lacking": return c.lacking(ws);
    case "forceWord": return c.forceWord(ws);
    case "givenTo": {
      const g = c.givenTo(ws, a.key);
      return g === "all" ? "all" : [...g];
    }
    case "takeBodies": return asJson(c.takeBodies(ws, a.bodies));
    case "bodies": return [...c.bodies(ws).all().keys()];
    case "grantKeys": return asJson(c.grantKeys(ws));
    case "pendingLock": return c.pendingLock(ws);
    case "leftJoined": c.leftJoined(ws); return null;
    case "succeed": return c.succeed(ws);
    case "setPlaneLists": c.setPlaneLists(a.peers, a.gateways); return null;
    case "update":
      c.update((st) => {
        if (a.peers !== undefined) st.peers = a.peers;
        if (a.joined !== undefined) st.joined = joinedOf(a.joined);
      });
      return null;
    case "filtered": {
      if (c.state === null) return null;
      const f = c.filtered(c.state);
      return asJson({ peers: f.peers, ...(f.gateways !== undefined ? { gateways: f.gateways } : {}) });
    }
    case "unprotected": return asJson(c.unprotected(ws));
    case "memberships": return asJson(c.memberships());
    case "membership": return asJson(c.membership(ws));
    case "leftOut": return c.leftOut(ws);
    case "home": return c.home();
    case "relays": return c.relays();
    case "rigs": return asJson(c.rigs(ws));
    case "rigsNamed": return asJson(c.rigsNamed(ws));
    case "lockAfter": return c.lockAfter(a.seq, ws);
    case "lockKept": return c.lockKept(ws);
    case "lockOff": {
      const k = c.lockOff(ws);
      return k === null ? null : keptJson(k);
    }
    case "reload": c.reload(); return null;
    case "reloadLock": c.reloadLock(); return null;
    case "reloadJoined": c.reloadJoined(); return null;
    case "offerMoved": c.offerMoved(ws, a.entries); return null;
    case "vouch": c.rigVouched = (w, r) => (a.rigs as { ws: string; id: string }[]).some((x) => x.ws === w && x.id === r.id); return null;
    case "personTake": return asJson(chains.take(a.genesis, a.sub, a.chain, ws, a.fork === true));
    case "personKeep": chains.keep(a.genesis, a.chain, ws, a.fork === true); return null;
    case "personNewest": return chains.newest(a.genesis, a.sub, a.chain);
    case "personChosen": return chains.chosen(a.genesis, a.sub, a.chain);
    case "personEvery": return pairsOf(chains.every());
    case "personAll": return chains.all(a.genesis);
    case "personOf": return pairsOf(chains.of(a.sub) as [string, unknown[]][]);
    case "personHeardIn": return pairsOf(chains.heardIn(ws) as [string, unknown[]][]);
    case "commitsTo": return asJson(chains.commitsTo(a.h));
    case "lockRoute": return asJson(lockRoute(c, a.method, a.query, Buffer.from(a.body), a.viewer));
    case "lockPartRoute": return asJson(lockPartRoute(c, a.part, a.method, Buffer.from(a.body), a.viewer));
    case "sawBuild": if (a.viewer.lockId !== undefined) deviceBuildsOf(c).saw(a.viewer.lockId, a.build ?? null, NOW); return null;
    case "movedFloor": return movedFloor(c, a.workspace);
    case "movedTooOld": return movedTooOld(c, { workspace: a.workspace } as never, a.build ?? null);
    case "refusal": return asJson(refusalOf(c, a.hello, a.device, new LockRefusal(a.why), undefined, a.sub ?? null));
    case "answerPerson": return asJson(answerPerson(chains, a.request, ws));
    case "answerBodies": return asJson(answerBodies(c, a.request, ws, a.peer ?? null));
    case "pinBrought": pinBrought(c, a.w ?? null, ws, a.entries, a.logs, a.bodies, a.who, a.me); return null;
    case "pinMoved": {
      const call = async (peer: string, w: string | null, request: Json) => {
        const at = a.stations[peer];
        if (at === undefined) throw new Error("unreachable");
        return answerLock(clouds.get(at)!, request, w, a.me) as Json;
      };
      return await pinMoved(c, call, ws, a.peers, a.me);
    }
  }
  throw new Error(`no such op: ${op}`);
}

/// What both say of `op` with `args`: the TypeScript's and the program's, the same, or the test fails naming it.
async function both(op: string, args: Json = {}, what = op): Promise<Json> {
  let ts: Json;
  try {
    ts = { ok: asJson(await tsAnswer(op, { ...args, data: args.data ?? undefined })) };
  } catch (e) {
    ts = { error: (e as Error).message, refused: e instanceof LockRefusal };
  }
  const said = await mb().ask(op, mbArgs(args));
  const m = "ok" in said ? { ok: said.ok } : { error: said.error, refused: said.refused };
  assert.deepStrictEqual(m, ts, `${what}: the program says what the TypeScript says`);
  return ts.ok;
}

/// The program's Clouds are on directories of their own (`<data>.mb`), each the TypeScript's twin.
const twin = (data: string) => `${data}.mb`;
function mbArgs(args: Json): Json {
  const out = { ...args };
  if (typeof out.data === "string" && !SHARED.has(out.data)) out.data = twin(out.data);
  return out;
}
/// Data directories both read as they are (a key made by one, read by the other).
const SHARED = new Set<string>();

/// Every file under each data directory and its twin the same, byte for byte (the temporary ones of a write aside).
async function sameFiles(data: string) {
  for (const c of clouds.values()) await personChainsOf(c).written();
  const walk = (root: string, at = ""): Map<string, Buffer> => {
    const out = new Map<string, Buffer>();
    if (!existsSync(join(root, at))) return out;
    for (const name of readdirSync(join(root, at))) {
      const p = join(at, name);
      if (statSync(join(root, p)).isDirectory()) for (const [k, v] of walk(root, p)) out.set(k, v);
      else if (!name.endsWith(".tmp")) out.set(p, readFileSync(join(root, p)));
    }
    return out;
  };
  const a = walk(data), b = walk(twin(data));
  assert.deepStrictEqual([...b.keys()].sort(), [...a.keys()].sort(), `${data}: the same files`);
  for (const [k, v] of a) assert.equal(b.get(k)!.toString("utf8"), v.toString("utf8"), `${k}: the same bytes`);
}

/// A station's data directory and its twin, cloud.json written alike in both, and each opened as `at`.
async function open(at: string, state: Json): Promise<string> {
  const data = fresh(`cloud-lock-${at}-`);
  for (const d of [data, twin(data)]) {
    mkdirSync(join(d, "mesh"), { recursive: true });
    writeState(d, state);
  }
  await both("open", { at, data });
  return data;
}

const stationState = (w: { ws: string; stations: { hex: string }[] }, i: number, extra: Json = {}) => ({
  origin: "https://app.still.fail", station: w.stations[i]!.hex, workspace: w.ws, workspace_name: "Team", name: `s${i}`, relay_url: "https://relay.still.fail", relay_urls: [],
  grant_keys: { keys: [] }, peers: w.stations.map((s, j) => ({ id: s.hex, name: `s${j}` })), revocations: [], ...extra,
});

/// What a device brings a station, both of them (POST /lock/person with its log and its bodies).
const bring = (at: string, log: Log, viewer: Json, ws = WS, bodies = true) =>
  both("lockPartRoute", { at, part: "person", method: "POST", body: JSON.stringify({ chain: log.entries, ...(bodies ? { bodies: [...log.bodies.values()].filter((b) => b.ws === ws) } : {}) }), viewer }, `${log.sub} brings their log`);

/// Every read a device or a station makes of `at`'s lock in `ws`, by each of `viewers`, the same.
async function reads(at: string, viewers: Json[], ws: string | null = null, keys: string[] = []) {
  for (const op of ["locked", "chain", "list", "rosterOf", "waiting", "kept", "rootOut", "needs", "logsOf", "lacking", "forceWord", "bodies", "grantKeys", "lockKept", "lockOff", "personEvery", "memberships", "unprotected", "filtered", "state"]) await both(op, { at, ws }, `${at} ${op}`);
  await both("lockAfter", { at, ws, seq: -1 });
  await both("lockAfter", { at, ws, seq: 0 });
  for (const v of viewers) {
    await both("lockRoute", { at, method: "GET", query: [], body: "", viewer: v }, `GET /lock as ${v.sub}`);
    await both("lockRoute", { at, method: "GET", query: [["after", "1"]], body: "", viewer: v }, `GET /lock?after=1 as ${v.sub}`);
    for (const part of ["person", "bodies", "logs", "heads"]) await both("lockPartRoute", { at, part, method: "GET", body: "", viewer: v }, `GET /lock/${part} as ${v.sub}`);
    const [, heads] = await both("lockPartRoute", { at, part: "heads", method: "GET", body: "", viewer: v });
    await both("lockPartRoute", { at, part: "given", method: "POST", body: JSON.stringify({ logs: [...heads.logs.map((x: [string, string]) => x[0]), "ab".repeat(32)], bodies: [...heads.bodies, "cd".repeat(32)] }), viewer: v }, `POST /lock/given as ${v.sub}`);
    await both("movedFloor", { at, workspace: v.workspace });
    for (const build of [null, 900, MOVED_FROM_BUILD - 1, MOVED_FROM_BUILD, ROOT_OUT_FROM_BUILD - 1, ROOT_OUT_FROM_BUILD, LOGS_ANY_FROM_BUILD - 1, LOGS_ANY_FROM_BUILD]) {
      await both("movedTooOld", { at, workspace: v.workspace, build });
    }
    const hello = { credential: `x.${Buffer.from(JSON.stringify({ ws: v.workspace })).toString("base64url")}.y`, ...(v.lockDevice ? { lock: { device: v.lockDevice.base, proof: v.lockDevice.proof } } : {}) };
    await both("refusal", { at, hello, device: v.device, why: "this device is not in the workspace's lock", sub: v.sub }, `a refusal of ${v.sub}`);
  }
  for (const k of keys) await both("givenTo", { at, ws, key: k }, `given to ${k.slice(0, 8)}`);
}

// ── the rules and the bytes ───────────────────────────────────────────────────────────────────────────────────────

test("the rules as the station takes them: canonical forms, hashes, signatures (Ed25519, P-256, passkeys), chains folded and chosen", { skip }, async () => {
  for (const v of [null, true, 1, -0, 2 ** 53, 1.5, "a\u0000\ud800é😀", [1, [2]], { b: 1, a: { "10": 1, "2": 2, z: [] } }, { u: undefined }]) await both("canonical", { value: v });
  for (const t of ["", "abc", "\ud800", "a\udc00b", "😀", "中文"]) await both("sha256hex", { text: t });
  for (const b of ["", "00".repeat(32), "x"]) await both("shortCode", { base: b });
  for (const [a, b] of [["owner", "admin"], ["member", "god"], ["viewer", "owner"], ["", ""]]) await both("lowerRole", { a, b });
  for (const id of [signers[0]!.id, "ed25519:" + "0".repeat(64), "ed25519:XYZ", "p256:" + Buffer.concat([Buffer.from([4]), Buffer.alloc(64, 1)]).toString("base64url"), "p256:nope", "rsa:1", "x".repeat(201)]) await both("validKeyId", { key: id });
  for (let seed = 1; seed <= 12; seed++) {
    const r = rng(seed);
    const chain: Entry[] = [genesisOf(r)];
    const all: Entry[] = [chain[0]!];
    for (let i = 1; i < 18; i++) {
      const e = nextOf(r, r.int(5) === 0 ? all[r.int(all.length)]! : chain.at(-1)!, i);
      all.push(e);
      if (r.int(3) !== 0) chain.push(e);
    }
    for (const e of all) {
      await both("asEntry", { value: e });
      await both("entryHash", { entry: e });
      const hash = (() => {
        try {
          return entryHash(e);
        } catch {
          return "00".repeat(32);
        }
      })();
      await both("sigValid", { sig: e.sig, hash, origins: ["https://app.still.fail"], rp_id: "app.still.fail", passkey: e.sig.alg === "webauthn" });
      await both("sigValid", { sig: e.sig, hash, origins: ["https://app.still.fail"], rp_id: "app.still.fail", passkey: e.sig.alg !== "webauthn" });
    }
    for (let n = 1; n <= chain.length; n++) await both("fold", { entries: chain.slice(0, n), now: 1000 + n * 60 }, `seed ${seed}: the chain to ${n}`);
    const shuffled = [...all].sort(() => r.next() - 0.5);
    await both("lockChain", { entries: shuffled, root: entryHash(all[0]!) }, `seed ${seed}: the active chain`);
    await both("emails", { entries: [chain[0]], email: "alice@x", sub: "alice" });
    for (const k of [signers[0]!.id, signers[1]!.id, "p256:nope"]) await both("signer", { entries: [chain[0]], key: k, at: null });
  }
  for (const v of [{}, { v: 1 }, { v: 1, ws: RWS, seq: -1, prev: null, at: 1, kind: "x", body: {}, sig: { key: "k", alg: "Ed25519", sig: "s" } }, { v: 1, ws: RWS, seq: 0, prev: null, at: 1.5, kind: "x", body: {}, sig: { key: "k", alg: "Ed25519", sig: "s" } }]) await both("asEntry", { value: v });
  // a base key's proof of an endpoint, a binding's tagged signature
  const b = key(70);
  const endpoint = key(71).hex;
  const proof = b.sign(endpointBytes(RWS, endpoint));
  for (const [ws, base, ep, pr] of [[RWS, b.hex, endpoint, proof], [RWS, b.hex, key(72).hex, proof], ["other", b.hex, endpoint, proof], [RWS, "nothex", endpoint, proof]]) await both("endpointProof", { ws, base, endpoint: ep, proof: pr });
  const digest = createHash("sha256").update("form").digest("hex");
  const tagged = b.sign(Buffer.concat([Buffer.from("stillfail-lock-bind/1\0"), Buffer.from(digest, "hex")]));
  for (const [k, sig, tag, dg] of [[b.id, tagged, "stillfail-lock-bind/1", digest], [b.id, tagged, "another", digest], [b.id, tagged, "stillfail-lock-bind/1", "zz"], ["p256:x", tagged, "t", digest]]) await both("taggedSigValid", { key: k, sig, tag, digest: dg });
  // who a connection is
  const r = rng(99);
  const g = genesisOf(r);
  for (const [i, ep] of [[0, key(80).hex], [1, key(81).hex], [3, key(82).hex]] as const) {
    const base = bases[i] ?? key(83);
    await both("admit", { entries: [g], who: { sub: ["alice", "bob", "carol", "dave"][i], endpoint: ep, base: base.hex, proof: base.sign(endpointBytes(RWS, ep)) } }, `admit ${i}`);
    await both("admit", { entries: [g], who: { sub: "alice", endpoint: ep } }, `admit ${i} by its endpoint alone`);
  }
});

test("a person's log kept by the fork choice: what is aside, what is refused, ASIDE_MOST", { skip }, async () => {
  const l = new Log("dana");
  for (let i = 0; i < 4; i++) l.add("device", { key: ed().id, id: ed().hex, label: `d${i}` });
  const genesis = l.genesis;
  const head = l.entries;
  // a second branch from seq 2 by the same device, and one by a stranger
  const fork = signed({ v: 1, ws: "person:dana", seq: 2, prev: entryHash(head[1]!), at: 1000, kind: "device", body: { key: ed().id, id: ed().hex, label: "other" } }, l.app.key);
  const stranger = signed({ v: 1, ws: "person:dana", seq: 3, prev: entryHash(head[2]!), at: 1000, kind: "device", body: { key: ed().id, id: ed().hex, label: "x" } }, ed());
  const elsewhere = { ...fork, ws: "person:erin" };
  await both("personFold", { entries: head, sub: "dana" });
  await both("personFold", { entries: head, sub: "erin" });
  await both("personChain", { entries: [stranger, ...head, fork], root: genesis });
  await both("keepLog", { genesis, logWs: "person:dana", entries: head.slice(0, 3), aside: [], brought: [head[3], fork, stranger, elsewhere, head[4]] });
  await both("keepLog", { genesis, logWs: "person:dana", entries: head, aside: [fork], brought: [] });
  await both("keepLog", { genesis, logWs: "person:dana", entries: head, aside: [fork, stranger] });
});

test("a station's key and what it signs: secret.key read and made, a signed request's headers", { skip }, async () => {
  const data = fresh("cloud-lock-key-");
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "secret.key"), Buffer.alloc(32, 7));
  SHARED.add(data);
  await both("loadKey", { data, message: "hello 😀" });
  // made by the program, read by the TypeScript
  const made = fresh("cloud-lock-made-");
  SHARED.add(made);
  const said = await mb().ask("loadKey", { data: made, message: "m" });
  assert.equal(readFileSync(join(made, "mesh", "secret.key")).length, 32, "32 raw bytes");
  assert.equal((statSync(join(made, "mesh", "secret.key")).mode & 0o777).toString(8), "600", "readable by this user alone");
  assert.equal(said.ok.id, loadKey(made).id, "the key it made is the one the TypeScript reads");
  const state = { origin: "https://app.still.fail", station: "st", workspace: "w" };
  await both("signedRequest", { data, state, path: "/v1/x", tag: "stillfail-station/1", value: { a: [1, "b"] }, ts: 1_700_000_000 });
  await both("signedRequest", { data, state: null, path: "/v1/x", tag: "t", value: {}, ts: 1 });
});

test("cloud.json read and written as the TypeScript does: its fields, their order, what is malformed left out", { skip }, async () => {
  const raw = {
    origin: "https://ember.3720.org", station: "s", workspace: "W", workspace_name: "Team", name: "n", relay_url: "https://ember.3720.org/relay", relay_urls: ["https://ember.3720.org/r", 5],
    grant_keys: { keys: [] }, peers: null, extra: { kept: true }, provider: "other", stillfail_relays: ["a", 1], gateway_keys: ["g"], removed_at: 5,
    joined: [{ workspace: "J", peers: [{ id: "p" }], revocations: [{ kind: "k", id: "i", at: 1 }, { kind: 1 }], locked: true, rigs: [{ id: "ab".repeat(32), owner: "o", version: "1" }, { id: "x" }], ways: { relays: ["r", 2], off: "x" } }, { workspace: "" }],
    rigs: [{ id: "cd".repeat(32), owner: "o", name: 3 }], ways: { relays: [] }, rig: { owner: "o", person: "ef".repeat(32), owner_email: 1 },
    rig_pending: { owner: "o", person: "ef".repeat(32), at: 10 }, rig_due: true, full_pending: { at: 1.5 },
  };
  const data = fresh("cloud-lock-state-");
  for (const d of [data, twin(data)]) {
    mkdirSync(join(d, "mesh"), { recursive: true });
    writeFileSync(join(d, "mesh", "cloud.json"), JSON.stringify(raw));
  }
  await both("readState", { data });
  await both("joinedOf", { raw: raw.joined });
  await both("rigsOf", { raw: raw.rigs });
  await both("waysSaidOf", { raw: raw.ways });
  await both("waysSaidOf", { raw: { off: [] } });
  // opened: the former host moved to the new, cloud.json written by each as it reads it
  await both("open", { at: "state", data });
  await sameFiles(data);
  for (const op of ["state", "home", "relays", "memberships", "filtered"]) await both(op, { at: "state" });
  await both("update", { at: "state", peers: [{ id: "q" }], joined: [{ workspace: "K", locked: true }] });
  await both("leftOut", { at: "state", ws: "K" });
  await sameFiles(data);
  await both("writeState", { data, state: { ...raw, joined: [], rigs: [], rig_due: false } });
  await sameFiles(data);
});

// ── a workspace's chain kept: on the head, forks, a keeper's branch, off and on again ───────────────────────────────

test("random chains kept as a station keeps them: on the head, off it, forks other keepers took; disabled, on again; read again from disk", { skip }, async () => {
  let aside = 0, turnedOff = 0, refused = 0;
  for (let seed = 1; seed <= 6; seed++) {
    const r = rng(100 + seed);
    const g = genesisOf(r);
    const at = `random-${seed}`;
    const data = await open(at, { origin: "https://app.still.fail", station: key(60).hex, workspace: RWS, workspace_name: "R", name: "s0", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [{ id: key(60).hex }], revocations: [] });
    await both("keepLock", { at, entries: [g] });
    const all: Entry[] = [g];
    for (let i = 1; i < 40; i++) {
      NOW = 2_000_000 + i;
      await both("now", { secs: NOW });
      const heads = (await both("kept", { at })) as { entries: Entry[] } | null;
      const from = heads === null ? g : r.int(4) === 0 ? all[r.int(all.length)]! : heads.entries.at(-1)!;
      const e = nextOf(r, from, i);
      all.push(e);
      const fork = r.int(3) === 0;
      const brought = r.int(5) === 0 ? [...all].sort(() => r.next() - 0.5).slice(0, 6) : [e];
      const t = await both("keepLock", { at, entries: brought, fork }, `seed ${seed} step ${i}`);
      if (t?.refusal) refused++;
      if (r.int(6) === 0) await both("takeLock", { at, entries: [e], fork }, `seed ${seed} step ${i}: taken`);
      const k = await both("kept", { at });
      if ((k?.aside.length ?? 0) > 0) aside++;
      await both("locked", { at });
      if ((await both("lockOff", { at })) !== null) turnedOff++;
    }
    await sameFiles(data);
    await both("open", { at, data });
    await both("kept", { at }, "read again from disk");
    await both("locked", { at }, "read again from disk");
    await both("lockOff", { at }, "read again from disk");
    await both("resetLock", { data });
    await both("reloadLock", { at });
    await both("locked", { at }, "taken away on this machine");
  }
  assert.ok(aside > 0 && turnedOff > 0 && refused > 0, `the events took every way: aside ${aside}, off ${turnedOff}, refused ${refused}`);
});

test("two branches: what a device brings goes on from the head or is refused; what another keeper took moves the chain; a disable that lost its place is on again", { skip }, async () => {
  const w = world();
  const data = await open("forks", stationState(w, 0));
  const bob = w.bob.app.signer, alice = w.alice.app.signer;
  const after = (prev: Entry, kind: string, body: unknown, by = alice) => signed({ v: 1, ws: WS, seq: prev.seq + 1, prev: entryHash(prev), at: 1000, kind, body }, by);
  await both("keepLock", { at: "forks", entries: [w.first] });
  const a1 = after(w.first, "station", { key: ed().hex, name: "x" });
  const b1 = after(w.first, "station", { key: ed().hex, name: "y" }, bob);
  const off = after(w.first, "disable", {});
  for (const step of [
    { entries: [a1] }, { entries: [b1] }, { entries: [b1], fork: true }, { entries: [a1, b1], fork: true }, { entries: [after(a1, "member", { sub: "dave", email: "d@x", role: "member" })], fork: true },
    { entries: [off] }, { entries: [off], fork: true }, { entries: [after(b1, "station.remove", { key: "00".repeat(32) }, bob)], fork: true },
  ]) {
    await both("keepLock", { at: "forks", ...step });
    await both("kept", { at: "forks" });
    await both("locked", { at: "forks" });
    await both("lockOff", { at: "forks" });
    await both("lockRoute", { at: "forks", method: "POST", query: [], body: JSON.stringify({ entries: step.entries, keep: step.fork === true }), viewer: viewerOf("alice", w.alice.app, "owner") });
    await sameFiles(data);
  }
  // turned off, then on again where its disable lost its place to what another keeper took
  const fresh2 = await open("off", stationState(w, 0));
  await both("keepLock", { at: "off", entries: [w.first, off] });
  await both("locked", { at: "off" });
  await both("lockOff", { at: "off" });
  await both("keepLock", { at: "off", entries: [w.first] }, "a lock turned off here is not taken again");
  const heavier = after(w.first, "member", { sub: "erin", email: "e@x", role: "admin" });
  await both("keepLock", { at: "off", entries: [w.first, heavier], fork: true }, "on again by a branch the fork choice takes");
  // (which of the two the fork choice takes is the keys' tie: on again where it takes the other, off where the disable)
  const wins = lockChain([w.first, off, heavier], entryHash(w.first)).hashes.includes(entryHash(heavier));
  assert.equal((await both("locked", { at: "off" })) !== null, wins, wins ? "on again" : "still off");
  await sameFiles(fresh2);
});

test("the floor of a workspace whose state is made of more than LOGS_BEFORE logs", { skip }, async () => {
  const w = world();
  handover(w);
  const more = Array.from({ length: LOGS_BEFORE - 3 }, (_, i) => new Log(`p${i}`));
  for (const l of more) w.alice.say("member", { sub: l.sub, email: `${l.sub}@x`, lock: l.genesis, role: "member" });
  await open("many", stationState(w, 0));
  await both("takeLock", { at: "many", entries: [w.first] });
  for (const l of [w.alice, w.bob, w.carol]) await bring("many", l, viewerOf(l.sub, l.app));
  for (const l of more) await bring("many", l, viewerOf(l.sub, l.app), WS, false);
  await both("takeLock", { at: "many", entries: [w.first, w.moved], fork: true });
  assert.equal((await both("needs", { at: "many" })).length, LOGS_BEFORE);
  assert.equal(await both("movedFloor", { at: "many", workspace: WS }), MOVED_FROM_BUILD);
  const last = new Log("plast");
  w.alice.say("member", { sub: last.sub, email: "plast@x", lock: last.genesis, role: "member" });
  await bring("many", w.alice, viewerOf("alice", w.alice.app, "owner"));
  await bring("many", last, viewerOf("plast", last.app), WS, false);
  assert.equal((await both("needs", { at: "many" })).length, LOGS_BEFORE + 1);
  assert.equal(await both("movedFloor", { at: "many", workspace: WS }), LOGS_ANY_FROM_BUILD);
  for (const build of [LOGS_ANY_FROM_BUILD - 1, LOGS_ANY_FROM_BUILD, 0, null]) await both("movedTooOld", { at: "many", workspace: WS, build });
  await both("movedTooOld", { at: "many", workspace: WS2, build: LOGS_ANY_FROM_BUILD - 1 });
  await reads("many", [viewerOf("bob", w.bob.app, "admin")]);
});

// ── a workspace whose chain moved ─────────────────────────────────────────────────────────────────────────────────

test("a moved workspace: the state in force from the logs and bodies, the reads by their heads, who is given what, a removal's `out` and `left`, the floors, read again", { skip }, async () => {
  const w = world();
  const said = handover(w);
  const data = await open("moved", stationState(w, 0));
  await both("takeLock", { at: "moved", entries: [w.first] });
  await both("takeLock", { at: "moved", entries: [w.first, w.moved], fork: true });
  const alice = viewerOf("alice", w.alice.app, "owner"), bob = viewerOf("bob", w.bob.app, "admin"), carol = viewerOf("carol", w.carol.app);
  const stranger = viewerOf("carol", { base: ed() } as never);
  const viewers = [alice, bob, carol, stranger, { ...carol, lockDevice: undefined }];
  const keys = [w.stations[0]!.hex, w.stations[2]!.hex, w.carol.app.base.hex, w.carol.app.signer.id, w.carol.app.key.id, "ff".repeat(32)];
  await reads("moved", viewers, null, keys);
  assert.equal((await both("locked", { at: "moved" })).waiting, true, "waiting for the root's log");
  // the root's log first: waiting no more
  await bring("moved", w.alice, alice);
  await reads("moved", viewers, null, keys);
  assert.equal((await both("locked", { at: "moved" })).waiting, undefined, "the root's log: on");
  for (const l of [w.bob, w.carol]) await bring("moved", l, viewerOf(l.sub, l.app));
  await reads("moved", viewers, null, keys);
  await sameFiles(data);
  // bodies alone, some refused
  await both("takeBodies", { at: "moved", ws: null, bodies: [{ ws: WS, kind: "x" }, "x".repeat(20_000), [...w.alice.bodies.values()][0], { ...[...w.alice.bodies.values()][1], salt: "other" }] });
  // carol taken out by alice: given only the removal's chain, told who may let her in
  w.alice.say("member.remove", { sub: "carol", cancels: [said.carol.h] });
  await bring("moved", w.alice, alice);
  await reads("moved", viewers, null, keys);
  const out = await both("refusal", { at: "moved", hello: { credential: "x.e30.y", lock: { device: carol.lockDevice.base, proof: carol.lockDevice.proof } }, device: carol.device, why: "out", sub: "carol" });
  assert.ok(out.out?.bodies.length > 0 && out.left?.approvers.length > 0, "carol is told what took her out and whom to ask");
  assert.notEqual((await both("givenTo", { at: "moved", key: w.carol.app.signer.id })), "all", "carol's signer is given only the removal's chain");
  // a statement whose body is not kept: lacking
  const dan = new Log("dan");
  await both("personKeep", { at: "moved", genesis: dan.genesis, chain: dan.entries, ws: WS2 });
  w.alice.say("member", { sub: "erin", email: "erin@x", lock: dan.genesis, role: "member" });
  await both("personKeep", { at: "moved", genesis: w.alice.genesis, chain: w.alice.entries, ws: WS });
  await reads("moved", [bob], null, keys);
  // the root's person out of `~root` by an owner's removal naming the root's log: ROOT_OUT_FROM_BUILD
  w.alice.say("member", { sub: "bob", email: "bob@x", lock: w.bob.genesis, role: "owner" });
  await bring("moved", w.alice, alice);
  w.bob.say("member.remove", { sub: "alice", cancels: [w.alice.genesis] });
  await bring("moved", w.bob, bob);
  await reads("moved", viewers, null, keys);
  assert.equal(await both("rootOut", { at: "moved" }), true, "the root's person out of ~root");
  assert.equal(await both("movedFloor", { at: "moved", workspace: WS }), ROOT_OUT_FROM_BUILD);
  // off by the root's log, then on again
  w.alice.say("off", {});
  await bring("moved", w.alice, alice);
  await reads("moved", viewers, null, keys);
  w.alice.say("open", { ...w.settings, email: "alice@x" });
  await bring("moved", w.alice, alice);
  await reads("moved", viewers, null, keys);
  // the devices' builds as seen here
  for (const [v, b] of [[alice, 9300], [bob, null], [carol, 9000]] as const) await both("sawBuild", { at: "moved", viewer: { ...v, lockId: v.lockDevice!.base }, build: b });
  await both("lockRoute", { at: "moved", method: "GET", query: [], body: "", viewer: alice }, "GET /lock with the builds");
  await both("lockPartRoute", { at: "moved", part: "person", method: "GET", body: "", viewer: alice }, "GET /lock/person with the builds");
  // between the stations
  for (const request of [{ method: "lock.person.heads" }, { method: "lock.person.kept" }, { method: "lock.person.get", genesis: w.alice.genesis }, { method: "lock.person.get", genesis: w.bob.genesis, hashes: [entryHash(w.bob.entries[0]!)] }, { method: "lock.person.put", chain: w.carol.entries }, { method: "nope" }]) {
    await both("answerPerson", { at: "moved", ws: WS, request });
  }
  for (const peer of [w.stations[1]!.hex, w.stations[2]!.hex, null]) {
    for (const request of [{ method: "lock.bodies.kept" }, { method: "lock.bodies.get", hashes: [...w.alice.bodies.keys()] }]) await both("answerBodies", { at: "moved", ws: WS, request, peer });
  }
  for (const h of [...w.alice.bodies.keys()].slice(0, 3)) await both("commitsTo", { at: "moved", h });
  await sameFiles(data);
  // read again from disk: the same state
  await both("open", { at: "moved", data });
  await reads("moved", viewers, null, keys);
  await sameFiles(data);
});

test("carried and bound: members the chain named on no log keep what it said of them, and bind their own log themselves", { skip }, async () => {
  const w = world();
  w.alice.say("open", { ...w.settings, email: "alice@x" });
  w.alice.say("station", { key: w.stations[0]!.hex });
  await open("bind", stationState(w, 0));
  await both("takeLock", { at: "bind", entries: [w.first] });
  await both("takeLock", { at: "bind", entries: [w.first, w.moved], fork: true });
  await bring("bind", w.alice, viewerOf("alice", w.alice.app, "owner"));
  const bob = viewerOf("bob", w.bob.app, "admin"), carol = viewerOf("carol", w.carol.app);
  await reads("bind", [bob, carol], null, [w.bob.app.signer.id, w.carol.app.signer.id]);
  const by = w.bob.app.signer;
  const moved = entryHash(w.moved);
  w.bob.say("bind", { key: by.id, sig: by.sign(bindBytes(WS, "bob", w.bob.genesis, moved)) });
  w.carol.say("bind", { key: w.carol.app.signer.id, sig: w.carol.app.signer.sign(bindBytes(WS2, "carol", w.carol.genesis, moved)) });
  for (const l of [w.bob, w.carol]) await bring("bind", l, viewerOf(l.sub, l.app));
  const st = await both("locked", { at: "bind" });
  assert.deepEqual(new Map(st.state.persons).get("bob"), w.bob.genesis, "bob bound by his own binding");
  assert.equal(new Map(st.state.persons).get("carol"), undefined, "a binding for another workspace binds nothing");
  await both("roster4Moved", { ws: WS, chain: [w.first, w.moved], chains: [w.alice.entries, w.bob.entries, w.carol.entries], bodies: [...w.alice.bodies.values(), ...w.bob.bodies.values(), ...w.carol.bodies.values()] });
  await both("state4Moved", { ws: WS, chain: [w.first, w.moved], chains: [w.alice.entries, w.bob.entries], bodies: [...w.alice.bodies.values(), ...w.bob.bodies.values()] });
  await reads("bind", [bob, carol], null, [w.bob.app.signer.id, w.carol.app.signer.id]);
});

test("a joined workspace's lock is let go by nothing the plane says: left out of a frame and named again unlocked, it stays pinned; a moved one stays as its logs say", { skip }, async () => {
  const w = world(WS2);
  handover(w);
  const home = { origin: "https://app.still.fail", station: w.stations[0]!.hex, workspace: WS, workspace_name: "Home", name: "s0", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [], revocations: [] };
  const joined = [{ workspace: WS2, workspace_name: "Team", name: "s0", peers: w.stations.map((s) => ({ id: s.hex })), revocations: [], locked: true }];
  const data = await open("joined", { ...home, joined });
  await both("leftOut", { at: "joined", ws: WS2 });
  await both("takeLock", { at: "joined", ws: WS2, entries: [w.first] });
  await both("takeLock", { at: "joined", ws: WS2, entries: [w.first, w.moved], fork: true });
  const alice = viewerOf("alice", w.alice.app, "owner", WS2);
  await bring("joined", w.alice, alice, WS2);
  for (const op of ["leftOut", "locked", "membership", "memberships"]) await both(op, { at: "joined", ws: WS2 });
  // the plane leaves it out, then names it again unlocked
  assert.notEqual(await both("locked", { at: "joined", ws: WS2 }), null, "pinned");
  await both("leftJoined", { at: "joined", ws: WS2 });
  await both("update", { at: "joined", joined: [] });
  await both("update", { at: "joined", joined: [{ ...joined[0], locked: false }] });
  for (const op of ["leftOut", "locked", "chain", "membership", "memberships", "unprotected"]) await both(op, { at: "joined", ws: WS2 }, `after the plane named it again unlocked: ${op}`);
  assert.notEqual(await both("locked", { at: "joined", ws: WS2 }), null, "still pinned: the plane's word let nothing go");
  await reads("joined", [alice, viewerOf("dan", { base: ed() } as never, "member", WS2)], WS2, [w.stations[1]!.hex]);
  await sameFiles(data);
  // its rigs: none the plane names is taken in security mode until its person signed for it
  const rig = { id: "ab".repeat(32), name: "r", owner: "alice", owner_email: "a@x", owner_name: "A" };
  await both("update", { at: "joined", joined: [{ ...joined[0], rigs: [rig] }] });
  await both("rigs", { at: "joined", ws: WS2 });
  await both("rigsNamed", { at: "joined", ws: WS2 });
  await both("givenTo", { at: "joined", ws: WS2, key: rig.id });
  await both("vouch", { at: "joined", rigs: [{ ws: WS2, id: rig.id }] });
  await both("rigs", { at: "joined", ws: WS2 });
  await both("givenTo", { at: "joined", ws: WS2, key: rig.id });
  // it takes over as home: its lock is the home one's
  await both("succeed", { at: "joined", ws: WS2 });
  await both("chain", { at: "joined" });
  await sameFiles(data);
});

test("moved-pin: a joined station pins a moved chain only once a station's logs and bodies make a state naming it; the owner's device brings one with its logs and bodies", { skip }, async () => {
  for (const protect of [true, false]) {
    const w = world();
    handover(w);
    if (protect) w.alice.say("station", { key: w.stations[2]!.hex }, w.ws);
    await open("s0", stationState(w, 0));
    await both("takeLock", { at: "s0", entries: [w.first] });
    await both("takeLock", { at: "s0", entries: [w.first, w.moved], fork: true });
    for (const l of [w.alice, w.bob, w.carol]) await bring("s0", l, viewerOf(l.sub, l.app));
    const data = await open("s2", {
      origin: "https://app.still.fail", station: w.stations[2]!.hex, workspace: WS2, workspace_name: "Other", name: "s2", relay_url: "", relay_urls: [], grant_keys: { keys: [] }, peers: [{ id: w.stations[2]!.hex }], revocations: [],
      joined: [{ workspace: WS, workspace_name: "Team", name: "s2", peers: w.stations.map((s) => ({ id: s.hex })), revocations: [], locked: true }],
    });
    const pin = { at: "s2", ws: WS, peers: [w.stations[0]!.hex, w.stations[1]!.hex], me: w.stations[2]!.hex, stations: { [w.stations[0]!.hex]: "s0" } };
    await both("pinMoved", pin, "nothing offered: nothing pinned");
    await both("offerMoved", { at: "s2", ws: WS, entries: [w.first, w.moved] });
    await both("leftOut", { at: "s2", ws: WS });
    assert.equal(await both("pinMoved", pin, `protected ${protect}`), protect, "pinned only where the state names it");
    for (const op of ["chain", "locked", "leftOut", "bodies", "personEvery"]) await both(op, { at: "s2", ws: WS });
    await sameFiles(data);
  }
  // the home station enrolled by its token alone, brought the chain, its logs and bodies by its owner's device
  const w = world();
  handover(w);
  for (const [who, viewer, logs, bodies] of [
    ["bob", viewerOf("bob", w.bob.app, "owner"), [w.alice.entries, w.bob.entries], [...w.alice.bodies.values()]],
    ["alice without bodies", viewerOf("alice", w.alice.app, "owner"), [w.alice.entries], undefined],
    ["alice", viewerOf("alice", w.alice.app, "owner"), [w.alice.entries, w.bob.entries, w.carol.entries], [...w.alice.bodies.values()]],
  ] as const) {
    const data = await open("home", stationState(w, 0));
    await both("lockRoute", { at: "home", method: "POST", query: [], body: JSON.stringify({ entries: [w.first, w.moved], logs, bodies }), viewer }, `brought by ${who}`);
    await both("locked", { at: "home" });
    await sameFiles(data);
  }
  // and by `pinBrought` itself
  await open("brought", stationState(w, 1));
  await both("pinBrought", { at: "brought", w: null, ws: WS, entries: [w.first, w.moved], logs: [w.alice.entries], bodies: [...w.alice.bodies.values()], who: { sub: "carol", endpoint: ed().hex }, me: w.stations[1]!.hex });
  await both("pinBrought", { at: "brought", w: null, ws: WS, entries: [w.first, w.moved], logs: "x", bodies: [], who: { sub: "alice", endpoint: ed().hex }, me: w.stations[1]!.hex });
});

test("a person's logs kept here: on the head, by another keeper, CHAINS_A_PERSON, the root's log never let go, read again", { skip }, async () => {
  const w = world();
  handover(w);
  const data = await open("persons", stationState(w, 0));
  await both("takeLock", { at: "persons", entries: [w.first] });
  await both("takeLock", { at: "persons", entries: [w.first, w.moved], fork: true });
  await bring("persons", w.alice, viewerOf("alice", w.alice.app, "owner"));
  // alice begins her lock anew five times: the root's log stays, the oldest of the rest go
  for (let i = 0; i < 5; i++) {
    const again = new Log("alice");
    again.add("device", { key: ed().id, id: ed().hex, label: `n${i}` });
    await both("personTake", { at: "persons", genesis: again.genesis, sub: "alice", chain: again.entries, ws: WS });
  }
  await both("personOf", { at: "persons", sub: "alice" });
  await both("personHeardIn", { at: "persons", ws: WS });
  // a fork of carol's log by a device itself (refused, not on the head), then by a station (kept aside)
  const c1 = w.carol.add("device", { key: ed().id, id: ed().hex, label: "c1" });
  const c2 = signed({ ...c1, body: { key: ed().id, id: ed().hex, label: "c2" } } as never, w.carol.app.key);
  await both("personTake", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: w.carol.entries, ws: WS });
  await both("personTake", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: [...w.carol.entries.slice(0, -1), c2], ws: WS });
  await both("personTake", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: [c2], ws: WS, fork: true });
  await both("personAll", { at: "persons", genesis: w.carol.genesis });
  await both("personNewest", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: [...w.carol.entries.slice(0, -1), c2] });
  await both("personNewest", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: w.carol.entries });
  await both("personChosen", { at: "persons", genesis: w.carol.genesis, sub: "carol", chain: [c2] });
  await both("lockRoute", { at: "persons", method: "POST", query: [], body: JSON.stringify({ person: w.carol.entries }), viewer: viewerOf("carol", w.carol.app) });
  await sameFiles(data);
  await both("open", { at: "persons", data });
  await both("personEvery", { at: "persons" }, "read again from disk");
  await both("personAll", { at: "persons", genesis: w.carol.genesis }, "read again from disk");
});

test("what a device is answered of malformed asks, a role that may not, a lock of another workspace", { skip }, async () => {
  const w = world();
  await open("asks", stationState(w, 0));
  const carol = viewerOf("carol", w.carol.app);
  for (const body of ["{", "", JSON.stringify({ entries: [] }), JSON.stringify({ entries: [{ v: 2 }] }), JSON.stringify({ entries: [w.first] })]) {
    await both("lockRoute", { at: "asks", method: "POST", query: [], body, viewer: carol });
    await both("lockRoute", { at: "asks", method: "POST", query: [], body, viewer: viewerOf("alice", w.alice.app, "owner") });
  }
  await both("lockRoute", { at: "asks", method: "PUT", query: [], body: "", viewer: carol });
  await both("lockRoute", { at: "asks", method: "GET", query: [["after", "x"]], body: "", viewer: carol });
  for (const [part, method, body] of [["bodies", "POST", "{"], ["bodies", "POST", JSON.stringify({ bodies: 5 })], ["bodies", "PUT", ""], ["given", "GET", ""], ["devicesx", "GET", ""], ["person", "POST", JSON.stringify({ chain: [] })], ["person", "DELETE", ""]]) {
    await both("lockPartRoute", { at: "asks", part, method, body, viewer: carol });
  }
  const other = world(WS2);
  await both("keepLock", { at: "asks", entries: [other.first] }, "another workspace's lock");
});
