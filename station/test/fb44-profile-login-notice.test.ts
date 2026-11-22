// FB-44: the workspace's managers are told which profile's login is over, to sign it in again (its name, runtime and
// the station whose login it is), once in four hours a workspace, and at once again after it was good.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { Notifier, PROFILE_LOGIN_COOLDOWN_MS, ProfileLoginCooldown } from "../src/cloud/notify.ts";
import { Cloud } from "../src/cloud/state.ts";
import { tr } from "../src/ops/i18n.ts";

test("FB-44: a profile's login over is pushed to the managers of each workspace it serves, cooled down, cleared when good", async (t) => {
  const scope = Effect.runSync(Scope.make());
  t.after(() => Effect.runPromise(Scope.close(scope, Exit.void)));
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  const store: any = { subscribe: () => () => {}, sessionWs: () => null };
  const readers: any = { read: async () => "[]" };
  const cloud: any = Object.assign(Object.create(Cloud.prototype), {
    state: {
      origin: "http://x", station: "s", workspace: "ws-home", workspace_name: "Home", name: "willow", peers: [], revocations: [],
      joined: [{ workspace: "ws-joined", workspace_name: "Joined", name: "willow-joined", peers: [], revocations: [] }],
    },
    lock: null,
  });
  const posted: { notices: any[]; ws: string | undefined }[] = [];
  const notifier = new Notifier(store, readers, cloud, async (notices, ws) => void posted.push({ notices, ws }), { clock });
  const cooldown = new ProfileLoginCooldown();
  const t0 = 1_790_000_000_000;
  const lost = (at: number, workspaces = ["ws-home", "ws-joined", "ws-gone"]) =>
    notifier.notifyProfileLogin({ workspaces, profileId: "sh-1", profile: "Claude A", runtimeTitle: "Claude Code", stationName: "Host A", at }, cooldown);
  assert.equal(lost(t0), 2, "each workspace the station is in");
  assert.equal(lost(t0 + 60_000), 0, "cooled down");
  cooldown.clear("sh-1");
  assert.equal(lost(t0 + 120_000, ["ws-home"]), 1, "told at once after it was good again");
  assert.equal(lost(t0 + 120_000, ["ws-joined"]), 1, "cleared in every workspace");
  assert.equal(lost(t0 + 180_000), 0, "cooled down again in both");
  assert.equal(lost(t0 + 120_000 + PROFILE_LOGIN_COOLDOWN_MS), 2, "and told again four hours on");
  for (let i = 0; i < 10 && posted.length < 2; i++) {
    await Effect.runPromise(clock.adjust("1 second"));
    for (let j = 0; j < 5; j++) await new Promise((r) => setImmediate(r));
  }
  const home = posted.find((p) => p.ws === undefined)!;
  assert.deepEqual(home.notices[0], {
    to: [],
    audience: "managers",
    kind: "failed",
    session: "profile:sh-1",
    thread: 0,
    seq: null,
    title: "Host A",
    by: "Claude Code",
    text: tr("zh", "station.notice.profileLogin", { profile: "Claude A", runtime: "Claude Code", station: "Host A" }),
    at: t0,
  });
  assert.ok(posted.some((p) => p.ws === "ws-joined"));
  assert.equal(tr("zh", "station.notice.profileLogin", { profile: "Claude A", runtime: "Claude Code", station: "Host A" }), "账号 Claude A（Claude Code · Host A）登录已失效，请重新登录");
  assert.equal(tr("en", "station.notice.profileLogin", { profile: "Claude A", runtime: "Claude Code", station: "Host A" }), "Account Claude A (Claude Code · Host A) signed out; please sign in again");
  notifier.close();
});
