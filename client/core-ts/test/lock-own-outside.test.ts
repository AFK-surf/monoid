// A device trusted in a workspace's lock that never moved (it signs there), its person's own lock begun since on
// another device of theirs, which does not name it (standing `outside`): it stays confirmed and signing (laws A to C
// of lock-state-invariants.test.ts), and is offered what joins it to that lock (`ownLock`, 完成此设备的批准), which
// what is signed for its person alone needs. Before (FB-45) its page said 受信任 and offered nothing, while
// 改为只执行任务 refused it saying to ask on this device. Asked, it joins that lock on the code its other device
// shows, and 改为只执行任务 goes on.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect } from "effect";
import type { CoreError } from "../src/error.ts";
import type { Entry } from "../src/lock.ts";
import { t } from "../src/i18n.ts";
import { vaultsView } from "../src/views/vault.ts";
import { world } from "./lock-pair-world.ts";

// deno-lint-ignore no-explicit-any
type J = any;

test("trusted here, its own lock begun on another device: confirmed and signing, offered to join it; 改为只执行任务 says where, and goes on once joined (FB-45)", async () => {
  const w = await world("chain");
  // Its person's own lock begun on another device of theirs (x's), which names this one nowhere: known here before
  // this device is approved into the workspace's lock, so nothing begins one of its own here.
  w.cloudKeeps.s1 = w.x.entries as unknown as Entry[];
  await w.c.bring(w.x, true, "ws");
  let out: unknown = null;
  w.inner.runner.fork(Effect.match(w.inner.adb.personal().refresh("s1"), { onSuccess: () => void (out = "ok"), onFailure: (e) => void (out = e) }));
  await w.r.host.time.passUntil(30_000, () => out !== null);
  await w.page();
  // Approved into the workspace's lock by the owner's device, as a member's first device is.
  const pair = await w.timed("lock.pair", { workspace: "ws" });
  assert.ok(pair.answer !== undefined && "ok" in pair.answer, `lock.pair: ${JSON.stringify(pair.answer)}; ${w.why()}`);
  for (let i = 0; i < 50 && w.shown.length === 0; i++) await w.r.host.time.pass(100);
  const typed = await w.timed("lock.pairCode", { workspace: "ws", code: w.codes.get(w.ids[0]!)! });
  assert.ok(typed.answer !== undefined && "ok" in typed.answer, `lock.pairCode: ${JSON.stringify(typed.answer)}; ${w.why()}`);
  const trusted = await w.sync();
  assert.equal(trusted.me.confirmed, true, `${JSON.stringify(trusted.me)}; ${w.why()}`);
  assert.equal(trusted.signs, true, `${JSON.stringify(trusted.me)}; ${w.why()}`);
  assert.equal(w.inner.adb.personal().standing("s1"), "outside", `standing ${w.inner.adb.personal().standing("s1")}; ${w.why()}`);

  // Laws A to C hold, and the way to join that lock is offered.
  const page = await w.sync();
  const why = `${JSON.stringify(page.me).slice(0, 400)}; ${w.why()}`;
  assert.equal(page.me.confirmed, true, why);
  assert.equal(page.me.waiting, false, why);
  assert.equal(page.signs, true, why);
  assert.equal(page.me.ownLock, true, why);
  assert.equal(await w.admits(), true, `Law A: confirmed, and the station lets it in; ${why}`);
  assert.equal((vaultsView(w.inner, "ws") as J).canSign, true, `Law C: the vaults' page signs as the security page; ${why}`);

  // 改为只执行任务: refused, saying where on this device it is asked (设置 › 安全).
  const tasks = await w.timed("rig.setMode", { workspace: "ws", station: w.A, mode: "tasks" });
  const refused = tasks.answer?.error as CoreError | undefined;
  assert.equal(refused?.code, "personal_outside", JSON.stringify(tasks.answer));
  assert.equal(refused?.message, t("core-misc.personal.outsideSafe"));
  assert.match(String(refused?.message), /设置 › 安全/);

  // Asked from here, it joins its person's lock on the code their other device shows (that device asked, nothing else).
  const shownBefore = w.shown.length;
  const join = await w.timed("lock.pair", { workspace: "ws" });
  assert.ok(join.answer !== undefined && "ok" in join.answer, `lock.pair joining: ${JSON.stringify(join.answer)}; ${w.why()}`);
  for (let i = 0; i < 50 && w.shown.length === shownBefore; i++) await w.r.host.time.pass(100);
  assert.ok(w.shown.slice(shownBefore).includes(w.x.app.base.hex), `their other device shows the code; ${w.why()}`);
  const joined = await w.timed("lock.pairCode", { workspace: "ws", code: w.codes.get(w.x.app.base.hex)! });
  assert.ok(joined.answer !== undefined && "ok" in joined.answer, `lock.pairCode joining: ${JSON.stringify(joined.answer)}; ${w.why()}`);
  await w.r.host.time.pass(5_000);
  assert.equal(w.inner.adb.personal().standing("s1"), "member", w.why());
  const after = await w.sync();
  assert.equal(after.me.ownLock, undefined, JSON.stringify(after.me));
  assert.equal(after.me.confirmed, true);
  assert.equal(after.signs, true);

  // 改为只执行任务 goes on: the station asked to pin their own lock's hash.
  const modes: J[] = [];
  const original = w.inner.stations.requests.call.bind(w.inner.stations.requests);
  w.inner.stations.requests.call = ((addr: J, method: string, path: string, body: unknown, ...rest: unknown[]) =>
    path === "/mode" ? Effect.sync(() => (modes.push(body), { ok: true })) : (original as (...x: unknown[]) => Effect.Effect<unknown, CoreError>)(addr, method, path, body, ...rest)) as typeof w.inner.stations.requests.call;
  const again = await w.timed("rig.setMode", { workspace: "ws", station: w.A, mode: "tasks" });
  assert.notEqual((again.answer?.error as CoreError | undefined)?.code, "personal_outside", JSON.stringify(again.answer));
  assert.deepEqual(modes, [{ mode: "tasks", person: w.x.genesis }], JSON.stringify(again.answer));
});
