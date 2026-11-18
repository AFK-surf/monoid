// A device's standing in safe mode, held to two laws in every state it can be in where a workspace's chain moved to
// its people's own logs, end to end on the station's own code (lock-pair-world.ts), and through what it takes to get
// out of each (`lock.pair`, `lock.pairCode`, `lock.restartOwn`, an owner taking a member out and adding them again):
//
// - Law A, the station and the page agree: once the device read what its station keeps, its page says it is confirmed
//   exactly where the station lets it in. A page confirmed that the station refuses is a device that thinks it is in
//   and is not (2026-11-15, #7059: a lock begun elsewhere taken for this one; a device bound by a lock it is not on).
// - Law B, every state has a way out: a page not confirmed, waiting for nothing outside it, offers what to do (ask
//   for approval, take a lock begun elsewhere as theirs, make this their only trusted device) or says who must act
//   (taken out, needs an app, waits to be taken out and added again); and asking does not answer that it waits in
//   no workspace. Its words never name a lock of one's own (to people there is one safe mode).
// - Law C, the vaults' page and the security page agree: safe mode on or off alike on both; where the vaults are
//   offered on this device, it signs for them exactly where the page says it signs, is offered 验证 on the vaults'
//   page exactly where the security page offers it, and, not confirmed, is never held on the vaults' page by a card
//   with nothing to press (it says it is not confirmed, with the way to 安全).
import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Effect } from "effect";
import { Cloud, writeState } from "../../../station/src/cloud/state.ts";
import { bring } from "../../../station/test/lock-moved-world.ts";
import type { CoreError } from "../src/error.ts";
import { lockView, read } from "../src/views/lock.ts";
import { vaultsView } from "../src/views/vault.ts";
import { hello as stationHello, setUp } from "./lock-handover-world.ts";
import { type Mode, type World, cleanText, stringsOf, world } from "./lock-pair-world.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// Both laws, of the page as it stands once the workspace was read (`where`: what the test did to get here).
async function lawful(w: World, where: string): Promise<J> {
  const page = await w.sync();
  const why = `${where}: ${JSON.stringify(page.me).slice(0, 400)}; ${w.why()}`;
  // Law A
  if (page.locked === true) assert.equal(page.me.confirmed === true, w.admits(), `the page ${page.me.confirmed ? "confirmed" : "not confirmed"}, the station ${w.admits() ? "letting it in" : "refusing it"}; ${why}`);
  // Law B
  waysOut(page, why);
  // Law C
  agrees(page, vaultsView(w.inner, "ws") as J, why);
  return page;
}

/// Law C: the vaults' page (`vaults`) as the security page (`page`) says this device stands.
function agrees(page: J, vaults: J, why: string) {
  const at = `${why}; vaults ${JSON.stringify({ locked: vaults.locked, canSign: vaults.canSign, stateText: vaults.stateText, confirmText: vaults.confirmText, plain: vaults.plain })}`;
  assert.equal(vaults.locked, page.locked, `safe mode ${page.locked ? "on" : "off"} on the security page, ${vaults.locked ? "on" : "off"} on the vaults'; ${at}`);
  if (page.locked === true && vaults.available === true) {
    assert.equal(vaults.canSign, page.signs, `the vaults' page ${vaults.canSign ? "signs" : "does not sign"}, the security page ${page.signs ? "signs" : "does not"}; ${at}`);
    assert.equal(Boolean(vaults.confirmText), Boolean(page.me.confirmText), `验证 offered on ${vaults.confirmText ? "the vaults' page alone" : "the security page alone"}; ${at}`);
    if (page.me.confirmed !== true) assert.equal(vaults.stateText, undefined, `not confirmed, held on the vaults' page by words with nothing to press; ${at}`);
  }
  for (const s of stringsOf(vaults)) assert.doesNotMatch(s, /个人锁|共享调试/, `the vaults' page says ${s}; ${at}`);
  assert.equal(cleanText(vaults), null, `${cleanText(vaults)}; ${at}`);
}

/// Law B of a page whatever its world: not confirmed, a way out or who must act; confirmed and not signing where it
/// could, why and what to press; an owner told who alone turns a moved workspace off and on, or offered it; no word of a
/// lock of one's own.
function waysOut(page: J, why: string, root?: boolean) {
  const me = page.me;
  if (page.locked === true && me.confirmed !== true) {
    const ways = [me.waiting === true && "asks", me.forgetText && "forget", me.restartText && "restart", me.outText && "out", me.needsAppText && "needs an app", me.reboundText && "rebound"].filter(Boolean);
    assert.ok(ways.length > 0, `not confirmed and nothing to do nor anyone named to do it; ${why}`);
  }
  if (page.locked === true && me.confirmed === true && page.canSign === true && page.signs === false) {
    assert.ok(me.unsigned === true || typeof me.confirmText === "string", `confirmed, not signing, and nothing says why nor what to press; ${why}`);
  }
  if (page.owner === true && root !== undefined) {
    if (page.locked === true && !root) assert.equal(typeof page.rootText, "string", `another owner of a moved workspace not told who alone turns it off; ${why}`);
    if (page.locked === false && root) assert.equal(typeof page.onAgainText, "string", `the root's person not offered turning it on again; ${why}`);
    if (page.locked === false && !root) assert.equal(typeof page.rootText, "string", `another owner not told who alone turns it on again; ${why}`);
  }
  for (const s of stringsOf(page)) assert.doesNotMatch(s, /个人锁|共享调试/, `says ${s}; ${why}`);
  assert.equal(cleanText(page), null, `${cleanText(page)}; ${why}`);
}

/// `lock.pair` asked, as a page that offers it asks it: never that it waits in no workspace.
async function asks(w: World, where: string) {
  const out = await w.timed("lock.pair", { workspace: "ws" });
  assert.ok(out.answer !== undefined && "ok" in out.answer, `${where}: lock.pair answered ${JSON.stringify(out.answer)}; ${w.why()}`);
  await w.r.host.time.pass(2_000);
}

/// The code its first trusted device that showed one shows, typed.
async function typesShown(w: World, where: string) {
  assert.ok(w.shown.length > 0, `${where}: no code shown; ${w.why()}`);
  const out = await w.timed("lock.pairCode", { workspace: "ws", code: w.codes.get(w.shown[0]!)! });
  assert.ok(out.answer !== undefined && "ok" in out.answer, `${where}: lock.pairCode answered ${JSON.stringify(out.answer)}; ${w.why()}`);
}

for (const mode of ["admit", "web", "personal", "carried"] as Mode[]) {
  test(`${mode}: waiting, it asks; approved, it is in; both laws at each step`, async () => {
    const w = await world(mode);
    const waiting = await lawful(w, "at first");
    assert.equal(waiting.me.confirmed, false);
    assert.equal(waiting.me.waiting, true, `able to ask (${JSON.stringify(waiting.me)})`);
    await asks(w, "waiting");
    await lawful(w, "asked");
    await typesShown(w, "asked");
    const after = await lawful(w, "approved");
    assert.equal(after.me.confirmed, true, `in (${w.why()})`);
  });
}

test("a newcomer let in, then taken out: the station refuses it and its page is not confirmed, saying so", async () => {
  const w = await world("admit");
  await asks(w, "waiting");
  await typesShown(w, "asked");
  assert.equal((await lawful(w, "approved")).me.confirmed, true);
  const admits = [...w.alice.bodies].filter(([, b]) => b.kind === "member" && b.sub === "s1").map(([h]) => h).sort();
  w.alice.say("member.remove", { sub: "s1", cancels: admits }, "ws");
  // (as alice's app brings it, and as the station tells the device on its stream: its link refused then)
  bring(w.c, w.alice, true, "ws");
  w.hello();
  const out = await lawful(w, "taken out");
  assert.equal(out.me.confirmed, false, `out (${w.why()})`);
});

test("every other device of a member's lost: offered to make this their only trusted device; made so, it says who is to take them out and add them again; taken out it asks an owner and is in: both laws at each step", async () => {
  const w = await world("personal");
  w.faults.set(w.theirs[0]!, { kind: "never" });
  await lawful(w, "at first");
  await asks(w, "their devices not answering");
  // (each dialled PAIR_DIAL_TRIES times, then none found)
  await w.r.host.time.pass(120_000, 1_000);
  const none = await lawful(w, "none answered");
  assert.ok(typeof none.me.restartText === "string", `offered to make this their only trusted device (${JSON.stringify(none.me)})`);
  const restarted = await w.timed("lock.restartOwn", { workspace: "ws" });
  assert.ok(restarted.answer !== undefined && "ok" in restarted.answer, `lock.restartOwn: ${JSON.stringify(restarted.answer)}`);
  const rebound = await lawful(w, "made their only trusted device");
  assert.equal(rebound.me.confirmed, false);
  // The owner takes them out (their admit by the lock of before cancelled) and adds them again as a newcomer.
  const admits = [...w.alice.bodies].filter(([, b]) => b.kind === "member" && b.sub === "s1").map(([h]) => h).sort();
  w.alice.say("member.remove", { sub: "s1", cancels: admits }, "ws");
  bring(w.c, w.alice, true, "ws");
  w.hello();
  const out = await lawful(w, "taken out");
  assert.equal(out.me.confirmed, false);
  await asks(w, "taken out");
  assert.ok(w.shown.some((id) => w.owners.includes(id)), `an owner's app shows a code (${w.why()})`);
  await typesShown(w, "asking an owner");
  const back = await lawful(w, "added again");
  assert.equal(back.me.confirmed, true, `in (${w.why()})`);
  assert.equal(w.c.locked()!.state!.persons.get("s1"), w.inner.adb.personal().root("s1"), "bound at the station by the log begun here");
});

test("a web page of someone the list names with no app: told to install one, asking nothing; both laws", async () => {
  const w = await world("admit", 1, { web: true });
  const page = await lawful(w, "a web page, no app of theirs");
  assert.deepEqual([page.me.confirmed, page.me.waiting], [false, false]);
  assert.equal(typeof page.me.needsAppText, "string", JSON.stringify(page.me));
});

test("its lock of before replaced by one begun elsewhere, which the workspace binds them by: refused and not confirmed, offered to take the new one as theirs; taken, it joins it face to face and is in, signing: both laws at each step", async () => {
  const w = await world("personal", 1, { replaced: true });
  const replaced = await lawful(w, "its lock begun anew elsewhere");
  assert.equal(w.inner.adb.personal().standing("s1"), "replaced", w.why());
  assert.equal(replaced.me.confirmed, false, "not confirmed where the station refuses it");
  assert.equal(typeof replaced.me.forgetText, "string", `offered to take the new one as theirs (${JSON.stringify(replaced.me)})`);
  const forgot = await w.timed("lock.forgetOwn", { workspace: "ws" });
  assert.ok(forgot.answer !== undefined && "ok" in forgot.answer, `lock.forgetOwn: ${JSON.stringify(forgot.answer)}`);
  await lawful(w, "the new one taken as theirs");
  await asks(w, "the new one taken as theirs");
  await typesShown(w, "asking their device on the new one");
  const after = await lawful(w, "joined the new one");
  assert.deepEqual([after.me.confirmed, after.signs], [true, true], `in and signing (${w.why()})`);
});

/// Both laws of the owner's world (lock-handover-world.ts): the page as this device holds it once the workspace was
/// read, station A's admission for Law A; `root`, whether this device's person is the one who alone turns it off.
async function lawfulOwner(w: Awaited<ReturnType<typeof setUp>>, where: string, root?: boolean): Promise<J> {
  await w.run(Effect.ignore(read(w.inner, "ws")));
  const page = lockView(w.inner, "ws") as J;
  const why = `${where}: ${JSON.stringify(page.me).slice(0, 300)}`;
  if (page.locked === true) assert.equal(page.me.confirmed === true, stationHello(w.stations.A, "s1", w.base, page.role).in, `the page and station A disagree; ${why}`);
  waysOut(page, why, root);
  agrees(page, vaultsView(w.inner, "ws") as J, why);
  return page;
}
const ask = (w: Awaited<ReturnType<typeof setUp>>, name: string, params: Record<string, unknown>) => w.run(Effect.tryPromise({ try: () => w.r.ask(name, params), catch: (e) => e as CoreError }));

test("put on its person's own lock without its signer said there: confirmed, not signing, says why and 验证; said, it signs: both laws at each step", async () => {
  const w = await world("personal", 1, { unsaid: true });
  await asks(w, "waiting");
  await typesShown(w, "asked");
  const before = await lawful(w, "its signer not said");
  assert.deepEqual([before.me.confirmed, before.signs, typeof before.me.confirmText], [true, false, "string"], JSON.stringify(before.me));
  const said = await w.timed("lock.confirmSigner", { workspace: "ws" });
  assert.ok(said.answer !== undefined && "ok" in said.answer, `lock.confirmSigner: ${JSON.stringify(said.answer)}`);
  const after = await lawful(w, "its signer said");
  assert.deepEqual([after.me.confirmed, after.signs, after.me.confirmText ?? null], [true, true, null], JSON.stringify(after.me));
});

test("the root's person turns a moved workspace off and on again: offered at each step, both laws", async () => {
  const w = await setUp({ early: true });
  assert.equal((await w.hand()).error, undefined);
  const on = await lawfulOwner(w, "moved, on", true);
  assert.deepEqual([on.locked, on.rootText ?? null], [true, null]);
  const off = await ask(w, "lock.disable", { workspace: "ws" });
  assert.equal(off.error, undefined, off.error?.message);
  const offPage = await lawfulOwner(w, "moved, off", true);
  assert.equal(offPage.locked, false);
  const again = await ask(w, "lock.open", { workspace: "ws" });
  assert.equal(again.error, undefined, again.error?.message);
  const onPage = await lawfulOwner(w, "moved, on again", true);
  assert.equal(onPage.locked, true);
});

test("another owner of a workspace moved by the root's person: told who alone turns it off, and turning it off is refused; off by that person, told who alone turns it on: both laws", async () => {
  const w = await setUp({ mine: "second", unbound: true, noLog: true });
  const on = await lawfulOwner(w, "moved by another, on", false);
  assert.equal(on.locked, true);
  const off = await ask(w, "lock.disable", { workspace: "ws" });
  // (refused: who alone may is said on the page; this device on no log of its person's answers as one on none does)
  assert.ok(["lock_root_only", "lock_moved"].includes(off.error?.code ?? ""), JSON.stringify(off));
  // The root's person turns it off on their own device: `off` in their log, brought to the stations.
  const first = w.first as unknown as { say: (kind: string, what: Record<string, unknown>, ws?: string) => unknown };
  first.say("off", {}, "ws");
  for (const c of Object.values(w.stations)) bring(c, w.first as never, true, "ws");
  const offPage = await lawfulOwner(w, "turned off by the root's person", false);
  assert.equal(offPage.locked, false, JSON.stringify(offPage).slice(0, 300));
});

test("every station of a moved workspace reset on its machine (stillfail lock reset): the lock let go here, never brought back by a read, the cloud's copy dropped, and turned on again anew: both laws", async () => {
  const w = await setUp({ early: true });
  assert.equal((await w.hand()).error, undefined);
  await lawfulOwner(w, "moved, on", true);
  // Each station's lock gone from its machine: a station keeping none, its state as before.
  for (const name of ["A", "B"] as const) {
    const was = w.stations[name];
    const data = mkdtempSync(join(tmpdir(), "lock-reset-"));
    writeState(data, { origin: "https://stillfail.test", station: name === "A" ? w.A : w.B, workspace: "ws", workspace_name: "W", name, relay_url: "", relay_urls: [], grant_keys: w.g.keys, peers: [{ id: w.A, name: "A" }, { id: w.B, name: "B" }], revocations: [] } as never);
    w.stations[name] = new Cloud(data, false);
    void was;
  }
  const reset = await lawfulOwner(w, "every station reset");
  assert.equal(reset.locked, false, "the lock let go here");
  await w.r.host.time.pass(5_000);
  for (const c of Object.values(w.stations)) assert.equal(c.chain(null), null, "never brought back by a read");
  assert.equal(w.r.cloud.chains.has("ws"), false, "the cloud's copy dropped");
  // Turned on anew: a genesis of its own, the cloud's copy of before no `lock_exists` in its way; its stations, which
  // keep none, are protected again by the owner's 保护 (lock.joinStation), each its own step.
  const again = await ask(w, "lock.open", { workspace: "ws" });
  assert.equal(again.error, undefined, again.error?.message);
  assert.deepEqual(w.r.cloud.chains.get("ws")?.map((e) => e.kind), ["genesis"], "a genesis of its own at the cloud");
  await lawfulOwner(w, "on anew");
});

test("its lock of before replaced elsewhere, this device on it with no signer said there: the vaults' page offers no 验证 (nothing to confirm on a lock the workspace does not bind it by), it is not confirmed, with the way to 安全: all three laws", async () => {
  const w = await world("personal", 1, { replaced: true });
  const page = await lawful(w, "its lock begun anew elsewhere");
  assert.equal(w.inner.adb.personal().standing("s1"), "replaced", w.why());
  assert.equal(w.inner.adb.personal().signerUnsaid("s1"), true, "its signer not said on the lock of before");
  const vaults = vaultsView(w.inner, "ws") as J;
  assert.deepEqual([page.me.confirmed, vaults.canSign, vaults.confirmText ?? null, vaults.stateText ?? null], [false, false, null, null], JSON.stringify(vaults).slice(0, 400));
});
