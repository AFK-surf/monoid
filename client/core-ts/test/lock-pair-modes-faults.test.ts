// A new device approved face to face in every way a device is (views/pair.ts), each with one to three trusted devices
// that go wrong as real ones do (lock-pair-world.ts `Fault`), end to end through the calls the app makes (`lock.pair`,
// `lock.pairCode`), the page it shows (`lock`) and the station's own admission. lock-pair-faults.test.ts holds a line
// that fails between one trusted device and the new one where the chain has not moved; this holds every way in:
// a member's first device where the chain never moved signed by an owner's (`chain`, one to three of them), a
// newcomer's first app where it moved (`admit`), a member's web page there (`web`), a member's new app joining their
// own lock (`personal`), and the new app of a member the chain carries bound to no log (`carried`).
//
// What must hold whatever happened (`laws`): every code typed is answered within the 40 s a call is given; a trusted
// device that signed the new device in has it in (the call answers so, the page says it is confirmed, the station lets
// it in), its answer lost or not; the page never says a lock's own name for a person's lock, nor a value not made, and
// never says it failed where it is in. A failure says its seed: PAIR_MODES_SEED=<seed> runs only that one
// (PAIR_MODES_RUNS=<n> runs n seeds from 1).
import assert from "node:assert/strict";
import { test } from "node:test";
import { t } from "../src/i18n.ts";
import { PAIR_LATE_CODE_MS, PAIR_PROVE_MS, PAIR_SIGNED_MS } from "../src/views/pair.ts";
import { type Fault, type Mode, MODES, type World, cleanText, world } from "./lock-pair-world.ts";

/// A seeded random (mulberry32): the same seed, the same draws.
function rng(seed: number) {
  let s = seed >>> 0;
  const next = () => {
    let x = (s += 0x6d2b79f5);
    x = Math.imul(x ^ (x >>> 15), x | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
  return { next, int: (n: number) => Math.floor(next() * n), pick: <A>(xs: readonly A[]) => xs[Math.floor(next() * xs.length)]! };
}

/// The most a call is given (the app's and the rig's): every code typed is answered before it.
const CALL_MS = 40_000;

/// `lock.pair` asked, and the clock let go until a code is shown (or `most` ms). Whatever the way in and whatever its
/// trusted devices do, nobody is asked on this device from asking to the code shown: a code is shown before anyone is
/// asked anything (the trusted device's own ask is held in lock-admits.test.ts, the person's own lock asked into).
async function asked(w: World, most = 5_000) {
  const before = w.r.host.secureAsked.length;
  const out = await w.timed("lock.pair", { workspace: "ws" });
  assert.ok(out.answer !== undefined && "ok" in out.answer, `lock.pair: ${JSON.stringify(out.answer)} (${w.why()})`);
  for (let i = 0; i < most / 100 && w.shown.length === 0; i++) await w.r.host.time.pass(100);
  assert.deepEqual(w.r.host.secureAsked.slice(before), [], `asked before a code was typed (${w.mode}; ${w.why()})`);
}

const typed = (w: World, code: string) => w.timed("lock.pairCode", { workspace: "ws", code });
const errorOf = (a: Record<string, any> | undefined) => (a !== undefined && "error" in a ? (a.error as { code: string; message: string }) : null);

/// The laws, once a code typed was answered (`calls`: each with how long it took) and things settled.
async function laws(w: World, calls: { ms: number | null; answer?: Record<string, any> }[], why: string) {
  for (const c of calls) assert.ok(c.ms !== null && c.ms < CALL_MS, `a code typed answered after ${c.ms} ms; ${why}`);
  await w.r.host.time.pass(15_000, 1_000);
  const page = await w.page();
  const clean = cleanText(page);
  assert.equal(clean, null, `the page ${clean}; ${why}`);
  const signed = w.signedBy.length > 0;
  if (signed) {
    assert.ok(calls.some((c) => c.answer !== undefined && "ok" in c.answer), `signed in by ${w.signedBy[0]!.id.slice(0, 6)}, yet no code typed was answered so: ${calls.map((c) => JSON.stringify(c.answer?.error ?? "ok")).join(", ")}; ${why}`);
    assert.equal(page.me.confirmed, true, `signed in, yet the page not confirmed (${JSON.stringify(page.me.pair)}); ${why}`);
    assert.equal(await w.admits(), true, `signed in, yet the station does not let it in; ${why}`);
    // In, and able to do what a trusted device does (sign, approve, open what is sealed for it): never confirmed with
    // its own lock left behind, as a carried member's new app was with its approval lost (the station let it in by
    // what its own device brought, this device outside that lock and signing nothing).
    if (w.mode !== "web") assert.equal(page.signs, true, `signed in and confirmed, yet it does not sign; ${why}`);
    if (w.mode !== "web" && w.mode !== "chain") {
      assert.equal(w.inner.adb.personal().standing("s1"), "member", `signed in, yet not on its person's own lock; ${why}`);
      assert.equal(w.inner.adb.personal().signerUnsaid("s1"), false, `on its person's own lock without its signer said; ${why}`);
    }
  }
  if (page.me.confirmed === true) assert.notEqual(page.me.pair?.state, "failed", `in, yet its page says it failed: ${JSON.stringify(page.me.pair)}; ${why}`);
  for (const c of calls) if (c.answer !== undefined && "ok" in c.answer) assert.ok(signed, `answered approved, yet nothing signed it in; ${why}`);
}

// ── each bug, as it was found ──

test("waiting in two workspaces, approved into the person's own lock by a carried member's app: in where the moved one lets it in by that lock; the other, whose chain binds them by none, says where it was approved, by its name", async () => {
  const w = await world("carried", 1, { w2: true });
  await w.page();
  await asked(w);
  const done = await typed(w, w.codes.get(w.ids[0]!)!);
  assert.ok(done.answer !== undefined && "ok" in done.answer, JSON.stringify(done.answer));
  await laws(w, [done], w.why());
  const other = await w.pageOf2();
  assert.equal(other.me.confirmed, false, "not in the other");
  assert.equal(other.me.pair?.state, "failed", JSON.stringify(other.me.pair));
  assert.equal(other.me.pair?.error, t("core-misc.lock.pairElsewhere", { names: "W" }), "says it was approved in W");
  assert.equal(cleanText(other), null, `${cleanText(other)}`);
});

test("a carried member's new app: the code shown by their own app is shown on its page as showing, typed it is in, and its page never says it failed elsewhere", async () => {
  const w = await world("carried");
  await w.page();
  await asked(w);
  const before = await w.page();
  const showing = (before.me.pair?.approvers ?? []).filter((a: { showing: boolean }) => a.showing).length;
  assert.equal(showing, 1, `their app shows the code for this workspace (${JSON.stringify(before.me.pair)}; ${w.why()})`);
  const done = await typed(w, w.codes.get(w.ids[0]!)!);
  assert.ok(done.answer !== undefined && "ok" in done.answer, JSON.stringify(done.answer));
  // (right after: before 2026-11-18 its try said 已在 person:s1 中批准 until a read let it in)
  const pair = (await w.page()).me;
  assert.equal(cleanText(pair), null, `${cleanText(pair)}`);
  assert.notEqual(pair.pair?.state, "failed", JSON.stringify(pair.pair));
  await laws(w, [done], w.why());
});

test("a member's new app joins their own lock: in at once, the workspaces their lock lets it in to read as it is approved", async () => {
  const w = await world("personal");
  await w.page();
  await asked(w);
  const done = await typed(w, w.codes.get(w.ids[0]!)!);
  assert.ok(done.answer !== undefined && "ok" in done.answer, JSON.stringify(done.answer));
  assert.equal(await w.admits(), true, "the station lets it in");
  await w.r.host.time.pass(300);
  assert.equal((await w.page()).me.confirmed, true, `confirmed as the call answered (${w.why()})`);
  await laws(w, [done], w.why());
});

for (const [mode, cloudOnly] of [["personal", false], ["personal", true], ["carried", false]] as const) {
  test(`${mode}: put on their lock, the line cut as the confirmation arrived${cloudOnly ? " (their lock read of the cloud alone)" : ""}: in, not said to have failed`, async () => {
    const w = await world(mode);
    await w.page();
    w.faults.set(w.ids[0]!, { kind: "cut", ms: 0 });
    await asked(w);
    if (cloudOnly) w.st.personDown = true;
    const done = await typed(w, w.codes.get(w.ids[0]!)!);
    assert.equal(w.signedBy.length, 1, "signed in");
    assert.ok(done.answer !== undefined && "ok" in done.answer, `answered ${JSON.stringify(done.answer)} after ${done.ms} ms (${w.why()})`);
    assert.ok(done.ms! < PAIR_SIGNED_MS, `answered after ${done.ms} ms`);
    w.st.personDown = false;
    await laws(w, [done], w.why());
  });
}

for (const mode of ["admit", "web"] as const) {
  test(`${mode}: signed in, the line cut as the confirmation arrived and the entry at the station 1.5 s later: read again as nothing tells it, in well within PAIR_SIGNED_MS`, async () => {
    const w = await world(mode);
    await w.page();
    w.faults.set(w.ids[0]!, { kind: "cut", ms: 1_500 });
    await asked(w);
    const done = await typed(w, w.codes.get(w.ids[0]!)!);
    assert.ok(done.answer !== undefined && "ok" in done.answer, `answered ${JSON.stringify(done.answer)} after ${done.ms} ms (${w.why()})`);
    assert.ok(done.ms! >= 1_500 && done.ms! < 1_500 + 3_000 + 3_000, `answered after ${done.ms} ms`);
    await laws(w, [done], w.why());
  });
}

test("two trusted devices, one reached that never says whether it shows a code: a wrong code is said wrong in PAIR_LATE_CODE_MS, not after its dial's 30 s", async () => {
  const w = await world("admit", 2);
  await w.page();
  w.faults.set(w.ids[1]!, { kind: "never" });
  await asked(w);
  const wrong = await typed(w, "999999");
  assert.equal(errorOf(wrong.answer)?.code, "pair_wrong", JSON.stringify(wrong.answer));
  assert.ok(wrong.ms! <= PAIR_LATE_CODE_MS + 100, `said wrong after ${wrong.ms} ms`);
  // (and the right one still lets it in)
  const right = await typed(w, w.codes.get(w.ids[0]!)!);
  assert.ok(right.answer !== undefined && "ok" in right.answer, JSON.stringify(right.answer));
  await laws(w, [wrong, right], w.why());
});

test("a code typed that one trusted device says is wrong at once, another's code coming 7 s after it was typed and that one going quiet after the confirmation: answered within the 40 s a call is given", async () => {
  const w = await world("admit", 2);
  await w.page();
  w.faults.set(w.ids[1]!, { kind: "late", ms: 8_000, then: { kind: "mute" } });
  await asked(w);
  await w.r.host.time.pass(1_000);
  const done = await typed(w, w.codes.get(w.ids[1]!)!);
  // (nothing signed: the other's code still shown, said wrong or gone)
  assert.ok(["pair_wrong", "pair_ended"].includes(errorOf(done.answer)?.code ?? ""), JSON.stringify(done.answer));
  assert.ok(done.ms !== null && done.ms <= PAIR_PROVE_MS + PAIR_SIGNED_MS + 100, `answered after ${done.ms} ms`);
  await laws(w, [done], w.why());
});

// ── every way in, each with what its trusted devices do drawn by a seed ──

const KINDS: Fault["kind"][] = ["live", "live", "never", "quiet", "late", "deny", "cut", "gone", "mute"];
function fault(r: ReturnType<typeof rng>): Fault {
  const kind = r.pick(KINDS);
  if (kind === "late") return { kind, ms: r.pick([1_000, 3_000, 6_000]), then: fault(r) };
  return { kind, ms: kind === "deny" ? r.pick([500, 5_000]) : r.pick([0, 0, 300, 1_500, 3_000]) };
}

async function once(seed: number): Promise<string> {
  const r = rng(seed);
  const mode: Mode = r.pick(MODES);
  const n = 1 + r.int(mode === "admit" ? 2 : 3);
  const w = await world(mode, n);
  await w.page();
  const faults = w.ids.slice(0, n).map((id) => {
    const f = fault(r);
    w.faults.set(id, f);
    return f;
  });
  const wrongFirst = r.int(4) === 0;
  const said = `seed ${seed}: ${mode}, ${n} trusted: ${JSON.stringify(faults)}${wrongFirst ? ", a wrong code first" : ""}`;
  await asked(w, 8_000);
  const calls: { ms: number | null; answer?: Record<string, any> }[] = [];
  if (w.shown.length > 0) {
    if (wrongFirst) calls.push(await typed(w, "999999"));
    const id = r.pick(w.shown);
    calls.push(await typed(w, w.codes.get(id)!));
  }
  await laws(w, calls, `${said}; answered ${calls.map((c) => `${JSON.stringify(c.answer?.error?.code ?? "ok")} after ${c.ms} ms`).join(", ")}; ${w.why()}`);
  return said;
}

const RUNS = Number(process.env.PAIR_MODES_RUNS ?? 30);
const seeds = process.env.PAIR_MODES_SEED ? [Number(process.env.PAIR_MODES_SEED)] : Array.from({ length: RUNS }, (_, i) => i + 1);

test("every way a new device is approved face to face, its trusted devices going wrong as they do: answered in time, in where it was signed in, its page clean", async () => {
  for (const seed of seeds) {
    const said = await once(seed);
    if (process.env.PAIR_MODES_TRACE) console.error(said);
  }
});
