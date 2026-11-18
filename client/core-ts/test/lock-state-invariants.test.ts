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
import assert from "node:assert/strict";
import { test } from "node:test";
import { bring } from "../../../station/test/lock-moved-world.ts";
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
  const me = page.me;
  if (page.locked === true && me.confirmed !== true) {
    const ways = [me.waiting === true && "asks", me.forgetText && "forget", me.restartText && "restart", me.outText && "out", me.needsAppText && "needs an app", me.reboundText && "rebound"].filter(Boolean);
    assert.ok(ways.length > 0, `not confirmed and nothing to do nor anyone named to do it; ${why}`);
  }
  for (const s of stringsOf(page)) assert.doesNotMatch(s, /个人锁|共享调试/, `says ${s}; ${why}`);
  assert.equal(cleanText(page), null, `${cleanText(page)}; ${why}`);
  return page;
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
