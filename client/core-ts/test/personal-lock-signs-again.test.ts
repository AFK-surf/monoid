// A person's own lock as this device signs it (personal-lock.ts `#append`): an entry of this device's that lost its
// place (a station's 409; a read that moved the chain pinned while it was brought; a read that moved it with no seed in
// hand) is signed again after the head where that still says what was meant, only while a seed is in hand (inside the
// call that signed it, or the next act that has one: `#signAgain`), never asking the person by itself. The lock: its
// genesis this device's (a), P putting a second device (b, key 22) on, X putting c (33) on; the stations' Y takes b off
// and Z puts d (44) on, Y winning at P by the rules' second step (a removal).
import assert from "node:assert/strict";
import { test } from "node:test";
import { ed25519 } from "@noble/curves/ed25519.js";
import { Effect } from "effect";
import { CoreError } from "../src/error.ts";
import { t } from "../src/i18n.ts";
import { type Entry, entryHash, signedBytes } from "../src/lock.ts";
import { PersonalLock, type Statements } from "../src/personal-lock.ts";
import { Runner } from "../src/runtime.ts";
import { FakeHost } from "../src/testing.ts";
import { hex, utf8 } from "../src/util.ts";

const SUB = "s1";
const STATION = "ws/st";

/// The person's stations: the chains a read answers (`chains`), each chain brought taken (kept as the one chain where
/// `follow`); `taking`: what lands on the device as a station takes what it was brought, before its answer (once);
/// `refuse`: the next brought is refused as at odds (a station's 409), after `meanwhile` (once). `brought`: every chain.
function stations() {
  const say = { chains: [] as Entry[][], follow: true, taking: null as (() => Effect.Effect<void, CoreError>) | null, refuse: false, meanwhile: null as (() => void) | null };
  const brought: Entry[][] = [];
  return {
    say,
    brought,
    env: {
      read: (_sub: string, _at?: string) => Effect.sync(() => say.chains.map((c) => [...c])),
      bring: (_sub: string, chain: Entry[]) =>
        Effect.suspend(() => {
          brought.push(chain);
          if (say.refuse) {
            say.refuse = false;
            say.meanwhile?.();
            return Effect.fail(new CoreError("lock_refused", "this device brought a lock at odds with the one its person has here", 409));
          }
          if (say.follow) say.chains = [chain];
          const taking = say.taking;
          say.taking = null;
          return taking === null ? Effect.succeed(1) : Effect.map(taking(), () => 1);
        }),
    },
  };
}

/// A device named `name`, its key's seed sealed; `asked` counts each time the person is asked for it.
function device(name: string, at: ReturnType<typeof stations>) {
  const host = new FakeHost();
  const id = name.charCodeAt(0).toString(16).repeat(32);
  host.appKeys = true;
  host.randomBytes = (b: Uint8Array) => void b.fill(name.charCodeAt(0));
  const sealed = new Map<string, Uint8Array>();
  const asked = { n: 0 };
  host.secureSet = (key: string, value: Uint8Array) => Effect.sync(() => void sealed.set(key, value));
  host.secureGet = (key: string) => Effect.sync(() => {
    asked.n++;
    return sealed.get(key) ?? new Uint8Array(32).fill(name.charCodeAt(0));
  });
  host.secureAsk = () => Effect.sync(() => void asked.n++);
  const runner = new Runner(host.time.clock);
  const down = () => Effect.fail(new CoreError("network", "the cloud is down"));
  // (the key it signs workspaces' things with: none said at first, as an app from before signers were said there)
  const signKey = { v: null as string | null };
  const lock = new PersonalLock({ host, runner, cloud: down, device: () => Effect.succeed(id), label: () => name, changed: () => {}, stations: at.env, signKey: () => signKey.v });
  return { host, runner, lock, id, asked, signKey };
}

function signed(chain: Entry[], by: string, kind: string, body: unknown, at = 1_800_000_000): Entry {
  const seed = new Uint8Array(32).fill(by.charCodeAt(0));
  const last = chain.at(-1);
  const e = { v: 1 as const, ws: `person:${SUB}`, seq: chain.length, prev: last ? entryHash(last) : null, at, kind, body };
  return { ...e, sig: { key: `ed25519:${hex(ed25519.getPublicKey(seed))}`, alg: "Ed25519" as const, sig: hex(ed25519.sign(signedBytes(entryHash(e)), seed)) } };
}

const other = (n: string) => ({ key: `ed25519:${n.repeat(32)}`, id: n.repeat(32), label: `device ${n}` });
const grantBody = { station: STATION, request: "p1", session: "sess", chat: "chat", scope: "hour" as const, exp: 2_000_000_000 };
const isPut = (n: string) => (e: Entry) => e.kind === "device" && (e.body as { key: string }).key === other(n).key;
const changedWords = () => t("core-misc.lock.changedMeanwhile", { what: "\u0000" }).split("\u0000")[0]!;

async function setUp() {
  const st = stations();
  const a = device("a", st);
  await a.runner.run(a.lock.signGrant(SUB, grantBody, "why"));
  await a.runner.run(a.lock.addDevice(SUB, other("22"), "why"));
  await a.runner.run(a.lock.addDevice(SUB, other("33"), "why"));
  const [g, P, X] = a.lock.entries(SUB) as [Entry, Entry, Entry];
  const Y = signed([g, P], "a", "device.remove", { key: other("22").key }, 1_800_000_100);
  const Z = signed([g, P, Y], "a", "device", other("44"), 1_800_000_300);
  return { st, a, g, P, X, Y, Z };
}

test("in the call: a read moved the chain pinned to another branch while the entry was brought: signed again after its head, once, the person asked once", async () => {
  const w = await setUp();
  w.st.say.taking = () => Effect.andThen(Effect.sync(() => { w.st.say.follow = false; w.st.say.chains = [[w.g, w.P, w.Y, w.Z]]; }), w.a.lock.refresh(SUB));
  const before = w.a.asked.n;
  await w.a.runner.run(w.a.lock.addDevice(SUB, other("66"), "why"));
  assert.equal(w.a.asked.n - before, 1, "asked once, for the call");
  const pinned = w.a.lock.entries(SUB);
  assert.deepEqual(pinned.slice(0, 4).map(entryHash), [w.g, w.P, w.Y, w.Z].map(entryHash));
  assert.equal(pinned.filter(isPut("66")).length, 1, "on the chain once");
  assert.equal(pinned.at(-1)!.prev, entryHash(w.Z), "after the head");
  assert.equal(w.a.lock.standing(SUB), "member");
});

test("in the call: a station refuses it as at odds (another entry at its place): read, signed again after the head, taken", async () => {
  const w = await setUp();
  w.st.say.refuse = true;
  w.st.say.meanwhile = () => { w.st.say.follow = false; w.st.say.chains = [[w.g, w.P, w.Y, w.Z]]; };
  await w.a.runner.run(w.a.lock.addDevice(SUB, other("66"), "why"));
  const pinned = w.a.lock.entries(SUB);
  assert.deepEqual(pinned.slice(0, 4).map(entryHash), [w.g, w.P, w.Y, w.Z].map(entryHash), "the branch read");
  assert.equal(pinned.filter(isPut("66")).length, 1);
  assert.equal(pinned.at(-1)!.prev, entryHash(w.Z));
});

test("in the call, the same done meanwhile: nothing signed again, the call succeeds; the device put on otherwise meanwhile: not signed again, the call says what to do", async () => {
  // The same: d (44) put on by another device's Z, this one putting d on too.
  const w = await setUp();
  w.st.say.refuse = true;
  w.st.say.meanwhile = () => { w.st.say.follow = false; w.st.say.chains = [[w.g, w.P, w.Y, w.Z]]; };
  const n = w.st.brought.length;
  await w.a.runner.run(w.a.lock.addDevice(SUB, other("44"), "why"));
  assert.equal(w.st.brought.length - n, 1, "brought once, not signed again");
  assert.deepEqual(w.a.lock.entries(SUB).map(entryHash), [w.g, w.P, w.Y, w.Z].map(entryHash));
  // Otherwise: e (55) put on by another device under another name since X, this one putting e on too.
  const v = await setUp();
  const W = signed([v.g, v.P, v.X], "a", "device", { ...other("55"), label: "renamed" }, 1_800_000_400);
  v.st.say.refuse = true;
  v.st.say.meanwhile = () => { v.st.say.follow = false; v.st.say.chains = [[v.g, v.P, v.X, W]]; };
  const m = v.st.brought.length;
  const out = await v.a.runner.run(Effect.result(v.a.lock.addDevice(SUB, other("55"), "why")));
  assert.ok(out._tag === "Failure" && out.failure.code === "lock_refused" && out.failure.message.startsWith(changedWords()), JSON.stringify(out));
  assert.equal(v.st.brought.length - m, 1, "not signed again");
  assert.deepEqual(v.a.lock.entries(SUB).map(entryHash), [v.g, v.P, v.X, W].map(entryHash));
});

test("lost with no seed in hand (a read moved the chain pinned off this device's X): nothing signed, nobody asked; the next act with a seed signs it again, once", async () => {
  const w = await setUp();
  w.st.say.follow = false;
  w.st.say.chains = [[w.g, w.P, w.Y, w.Z]];
  const before = { asked: w.a.asked.n, brought: w.st.brought.length };
  await w.a.runner.run(w.a.lock.refresh(SUB));
  await w.a.host.time.pass(1_000);
  assert.deepEqual(w.a.lock.entries(SUB).map(entryHash), [w.g, w.P, w.Y, w.Z].map(entryHash), "the branch pinned, X aside");
  assert.equal(w.a.asked.n, before.asked, "nobody asked");
  assert.equal(w.st.brought.length, before.brought, "nothing signed");
  // The person signs a grant: their seed in hand, X signed again after Z.
  w.st.say.follow = true;
  await w.a.runner.run(w.a.lock.signGrant(SUB, grantBody, "why"));
  assert.equal(w.a.asked.n - before.asked, 1, "asked once, for the grant");
  const pinned = w.a.lock.entries(SUB);
  assert.equal(pinned.filter(isPut("33")).length, 1, "c on the chain again");
  assert.equal(pinned.at(-1)!.prev, entryHash(w.Z));
  // Again: no third.
  const n = w.st.brought.length;
  await w.a.runner.run(w.a.lock.signGrant(SUB, grantBody, "why"));
  assert.equal(w.st.brought.length, n, "nothing more signed");
});

/// Whether the device of `key` is on the chain: the last entry about it puts it on.
const isOn = (chain: Entry[], key: string) => chain.filter((e) => (e.body as { key?: string })?.key === key).at(-1)?.kind === "device";

/// This device's `acts` (each a device of `others` put on, or taken off), pinned after X; then a read moves the chain
/// pinned to the stations' `theirs` (Y winning at P, X and the acts aside together) with no seed in hand, and the next
/// act with one (a grant) signs them again. What it signed again, in order, and the chain pinned then.
async function lostTogether(acts: ["on" | "off", string][], theirs: (w: Awaited<ReturnType<typeof setUp>>) => Entry[] = (w) => [w.g, w.P, w.Y, w.Z]) {
  const w = await setUp();
  for (const [how, n] of acts) await w.a.runner.run(Effect.asVoid<unknown, CoreError, never>(how === "on" ? w.a.lock.addDevice(SUB, other(n), "why") : w.a.lock.removeDevice(SUB, other(n).key, "why")));
  const mine = w.a.lock.entries(SUB).slice(3);
  assert.equal(mine.length, acts.length, "each act pinned after X");
  const chain = theirs(w);
  w.st.say.follow = false;
  w.st.say.chains = [chain];
  await w.a.runner.run(w.a.lock.refresh(SUB));
  await w.a.host.time.pass(1_000);
  assert.deepEqual(w.a.lock.entries(SUB).map(entryHash), chain.map(entryHash), "the branch pinned, X and the acts aside");
  w.st.say.follow = true;
  await w.a.runner.run(w.a.lock.signGrant(SUB, grantBody, "why"));
  const pinned = w.a.lock.entries(SUB);
  assert.deepEqual(pinned.slice(0, chain.length).map(entryHash), chain.map(entryHash), "after their head");
  const again = pinned.slice(chain.length).filter((e) => e.kind === "device" || e.kind === "device.remove");
  return { w, pinned, again };
}

test("lost together with no seed in hand, c put on (X) then taken off by this device: both signed again in that order, c off at the end", async () => {
  const { w, pinned, again } = await lostTogether([["off", "33"]]);
  assert.deepEqual(w.a.lock.pendingShown(SUB), [], "nothing failed");
  assert.deepEqual(again.map((e) => e.kind), ["device", "device.remove"], "both signed again, in the order made");
  assert.ok(!isOn(pinned, other("33").key), "c off");
});

test("lost together with no seed in hand, c on (X), off, on again: all three signed again in that order (an earlier one signed again does not make the third done), c on", async () => {
  const { w, pinned, again } = await lostTogether([["off", "33"], ["on", "33"]]);
  assert.deepEqual(w.a.lock.pendingShown(SUB), [], "nothing failed");
  assert.deepEqual(again.map((e) => e.kind), ["device", "device.remove", "device"], "all three signed again, in the order made");
  assert.ok(isOn(pinned, other("33").key), "c on");
});

test("lost (X puts c on), then c named otherwise by this device on the branch that won, later: X is not signed again", async () => {
  const W = (w: Awaited<ReturnType<typeof setUp>>) => signed([w.g, w.P, w.Y, w.Z], "a", "device", { ...other("33"), label: "renamed" }, 1_800_000_900);
  const { w, pinned, again } = await lostTogether([], (w) => [w.g, w.P, w.Y, w.Z, W(w)]);
  assert.deepEqual(again, [], "nothing signed again");
  assert.deepEqual(w.a.lock.pendingShown(SUB), [], "nothing to tell: what decided otherwise is this device's own later act");
  assert.equal((pinned.filter(isPut("33")).at(-1)!.body as { label: string }).label, "renamed");
});

test("lost (X puts c on), then c named otherwise by another device of the person's since: X not signed again, and told as a pending one that failed is", async () => {
  // b (a device of seed b) put on the branch that won, and it renames c.
  const bKey = `ed25519:${hex(ed25519.getPublicKey(new Uint8Array(32).fill("b".charCodeAt(0))))}`;
  const B = (w: Awaited<ReturnType<typeof setUp>>) => signed([w.g, w.P, w.Y, w.Z], "a", "device", { key: bKey, id: "bb".repeat(32), label: "device b" }, 1_800_000_800);
  const W = (w: Awaited<ReturnType<typeof setUp>>) => signed([w.g, w.P, w.Y, w.Z, B(w)], "b", "device", { ...other("33"), label: "renamed" }, 1_800_000_900);
  const { w, pinned, again } = await lostTogether([], (w) => [w.g, w.P, w.Y, w.Z, B(w), W(w)]);
  assert.deepEqual(again, [], "nothing signed again");
  assert.equal((pinned.filter(isPut("33")).at(-1)!.body as { label: string }).label, "renamed");
  const shown = w.a.lock.pendingShown(SUB);
  assert.deepEqual(shown.map((x) => [x.item.id, x.item.state, x.item.act]), [[entryHash(w.X), "failed", "approve"]], "one failed row, X");
  assert.equal(shown[0]!.row.state, "failed");
  // 知道了 takes it away.
  w.a.lock.dismissPending(SUB, shown[0]!.item.id);
  assert.deepEqual(w.a.lock.pendingShown(SUB), []);
});

/// A workspace's statement as `lock.joinStation` makes one (a station taken in), made after `after` (whose heads it
/// was made after are kept in `heads`), shown as the person's act.
function protecting(heads: string[]): Statements {
  return (after) => {
    heads.push(entryHash(after.at(-1)!));
    return { bodies: [{ ws: "ws", kind: "station", key: "aa".repeat(32), prev: null, salt: heads.length.toString(16).padStart(32, "0") }], shown: [{ act: "protectStation", name: "a" }] };
  };
}

test("a workspace's statements refused at a station as at odds (another device of the person's moved their lock on meanwhile, a 409): read, made again and signed after the head with the seed in hand, taken; the person asked once, nothing of the refused kept as said", async () => {
  const w = await setUp();
  const Q = signed([w.g, w.P, w.X], "a", "device", other("77"), 1_800_000_500);
  w.st.say.refuse = true;
  w.st.say.meanwhile = () => { w.st.say.follow = false; w.st.say.chains = [[w.g, w.P, w.X, Q]]; };
  const heads: string[] = [];
  const before = { asked: w.a.asked.n, brought: w.st.brought.length };
  const out = await w.a.runner.run(Effect.result(w.a.lock.say(SUB, "ws", protecting(heads), "why")));
  assert.ok(out._tag === "Success" && out.success === null, JSON.stringify(out));
  assert.equal(w.a.asked.n - before.asked, 1, "asked once, for the call");
  assert.equal(w.st.brought.length - before.brought, 2, "brought, refused, brought again");
  assert.deepEqual(heads, [entryHash(w.X), entryHash(Q)], "made after the head pinned, then after the one the stations said");
  const pinned = w.a.lock.entries(SUB);
  assert.deepEqual(pinned.slice(0, 4).map(entryHash), [w.g, w.P, w.X, Q].map(entryHash), "the stations' head");
  assert.deepEqual(pinned.slice(4).map((e) => [e.kind, e.prev]), [["ws", entryHash(Q)]], "the statement once, after it");
  assert.deepEqual(w.a.lock.pendingShown(SUB), [], "nothing pending nor failed");
  const stated = JSON.parse(new TextDecoder().decode(w.a.host.storage.get(`personal-lock-stated-${hex(utf8(SUB))}`)!)) as [string, unknown][];
  assert.equal(stated.length, 1, "only the statement taken kept as said");
  // Brought again with nothing moved meanwhile: refused as it was, nothing signed again.
  const v = await setUp();
  v.st.say.refuse = true;
  const n = v.st.brought.length;
  const refused = await v.a.runner.run(Effect.result(v.a.lock.say(SUB, "ws", protecting([]), "why")));
  assert.ok(refused._tag === "Failure" && refused.failure.code === "lock_refused", JSON.stringify(refused));
  assert.equal(v.st.brought.length - n, 1, "not signed again");
  assert.equal(v.a.host.storage.get(`personal-lock-stated-${hex(utf8(SUB))}`), undefined, "the refused not kept as said");
});

test("lost with no seed in hand, then the person verifies this device (confirmSigner) or signs for a rig (signRig): the seed in hand signs again what lost its place, once, nobody asked again", async () => {
  for (const act of ["rig", "confirm"] as const) {
    const w = await setUp();
    w.st.say.follow = false;
    w.st.say.chains = [[w.g, w.P, w.Y, w.Z]];
    await w.a.runner.run(w.a.lock.refresh(SUB));
    await w.a.host.time.pass(1_000);
    assert.equal(w.a.lock.entries(SUB).filter(isPut("33")).length, 0, `${act}: X aside`);
    w.st.say.follow = true;
    // (its signer known only now: not said on its person's lock, as an app from before; 验证 offered)
    if (act === "confirm") {
      w.a.signKey.v = `ed25519:${"5e".repeat(32)}`;
      assert.equal(w.a.lock.signerUnsaid(SUB), true);
    }
    const before = w.a.asked.n;
    if (act === "rig") await w.a.runner.run(w.a.lock.signRig(SUB, "settings", { v: 1 }, "why"));
    else await w.a.runner.run(Effect.result(w.a.lock.confirmSigner(SUB, "why")));
    const pinned = w.a.lock.entries(SUB);
    assert.equal(pinned.filter(isPut("33")).length, 1, `${act}: c on the chain again`);
    assert.equal(pinned.slice(4).filter(isPut("33"))[0]?.prev, entryHash(w.Z), `${act}: after the head`);
    assert.equal(w.a.asked.n - before, 1, `${act}: asked once`);
    if (act === "confirm") assert.equal(w.a.lock.signerUnsaid(SUB), false, "its signer said");
  }
});
