// GET /overview's decisions and processes' memory: overviews asked at once (every device told the same change) share
// one making, kept by what the view is made of rather than by who asks.
import assert from "node:assert/strict";
import { test } from "node:test";
import { overview } from "../src/api/overview.ts";
import { platform } from "../src/platform/index.ts";
import { DecisionSessionsUnavailable } from "../src/store/legacy-decision-session.ts";
import { Store } from "../src/store/store.ts";
import { SessionChatPreparation } from "./reference/backfill/session-chat-index.ts";

type Checks = { options: Record<string, { count: number; chats: { session: string; at: number }[] }>; checked: number; failed: number };
const noChecks = (checked = 0): Checks => ({ options: {}, checked, failed: 0 });

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

const viewerOf = (email: string, role: string, workspace: string, home: boolean) =>
  ({ sub: `s-${email}`, email, name: email, role, workspace, device: "d", home });

/// A station of a real store whose policy checks, decisions version and clock the test holds.
function station(more: { hub?: Record<string, unknown>; made?: (viewer: any, options: any) => any } = {}) {
  const store = Store.open(":memory:");
  let version = 1;
  let now = 1_000_000;
  store.decisionsVersion = () => version;
  store.now = () => now;
  const asked: { since: number; viewer: unknown; answer: ReturnType<typeof deferred<Checks | null>> }[] = [];
  const hub: any = {
    processes: () => [],
    config: () => ({ dataDir: "/" }),
    policyChecks: (since: number, viewer: unknown) => {
      const answer = deferred<Checks | null>();
      asked.push({ since, viewer, answer });
      return answer.promise;
    },
    ...more.hub,
  };
  const accounts: any = {
    profilesView: () => [], loginsView: () => [], apiProviders: () => [], machineLogins: () => [], decisionModels: () => ["m"],
    automaticDecisionsView: more.made ?? ((viewer: any) => viewer.role === "owner" || viewer.role === "admin"
      ? { canEdit: true, recent: [] }
      : { canEdit: false, settings: {}, models: [], recent: [] }),
  };
  const deps = { store, hub, accounts, cloud: { state: null } as any, config: () => ({ connects: [] }) };
  return {
    store, hub, asked,
    ask: (viewer: ReturnType<typeof viewerOf>) => overview(deps, viewer, "en") as Promise<any>,
    bump: () => { version++; },
    advance: (ms: number) => { now += ms; },
  };
}

/// Lets every overview under way run up to what it waits on.
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

test("a workspace's managers asking at once share one reading of the policy's checks, each given a copy of its own", async () => {
  const s = station();
  try {
    const managers = [
      viewerOf("a@x", "owner", "w1", false), viewerOf("b@x", "admin", "w1", false),
      viewerOf("c@x", "admin", "w1", false), viewerOf("d@x", "owner", "w1", false),
    ];
    const answers = Promise.all(managers.map((v) => s.ask(v)));
    await settle();
    assert.equal(s.asked.length, 1, "one reading for the four");
    s.asked[0]!.answer.resolve(noChecks(4));
    const got = await answers;
    for (const r of got) {
      assert.equal(r.automaticDecisions.policy.checked, 4);
      assert.equal(r.automaticDecisions.canEditPolicy, true);
    }
    got[0].automaticDecisions.policy.checked = 99;
    assert.equal(got[1].automaticDecisions.policy.checked, 4, "each answer is its own copy");
    // Kept: another manager asking within the minute reads nothing again, and is not given the changed copy.
    const later = await s.ask(viewerOf("e@x", "admin", "w1", false));
    assert.equal(s.asked.length, 1);
    assert.equal(later.automaticDecisions.policy.checked, 4);
  } finally { s.store.close(); }
});

test("members are kept apart from managers, workspaces from each other and the home workspace from a joined one", async () => {
  const s = station();
  try {
    const owner = s.ask(viewerOf("a@x", "owner", "w1", false));
    const member = s.ask(viewerOf("m@x", "member", "w1", false));
    const reader = s.ask(viewerOf("r@x", "viewer", "w1", false));
    const otherWs = s.ask(viewerOf("b@x", "admin", "w2", false));
    const home = s.ask(viewerOf("c@x", "admin", "w1", true));
    await settle();
    // Members read no checks (they see no policy): only the three managers' views read them, one each.
    assert.deepEqual(s.asked.map((a) => a.viewer), [
      viewerOf("a@x", "owner", "w1", false), viewerOf("b@x", "admin", "w2", false), viewerOf("c@x", "admin", "w1", true),
    ]);
    s.asked.forEach((a, i) => a.answer.resolve(noChecks(i + 1)));
    const [o, m, r, w, h] = await Promise.all([owner, member, reader, otherWs, home]);
    assert.equal(o.automaticDecisions.policy.checked, 1);
    assert.equal(w.automaticDecisions.policy.checked, 2);
    assert.equal(h.automaticDecisions.policy.checked, 3);
    for (const v of [m, r]) {
      assert.equal(v.automaticDecisions.policy, undefined, "a member is not given the policy");
      assert.equal(v.automaticDecisions.canEditPolicy, undefined);
      assert.equal(v.automaticDecisions.canEdit, false);
    }
    // A member asking after the managers' view was kept is still not given it.
    const again = await s.ask(viewerOf("n@x", "member", "w1", false));
    assert.equal(again.automaticDecisions.policy, undefined);
    assert.equal(s.asked.length, 3);
  } finally { s.store.close(); }
});

test("a reading that fails fails those waiting on it, and the next overview reads again", async () => {
  const s = station();
  try {
    const first = Promise.allSettled([s.ask(viewerOf("a@x", "owner", "w1", false)), s.ask(viewerOf("b@x", "admin", "w1", false))]);
    await settle();
    assert.equal(s.asked.length, 1);
    s.asked[0]!.answer.reject(new Error("reader gone"));
    const failed = await first;
    assert.deepEqual(failed.map((f) => f.status), ["rejected", "rejected"]);
    const next = s.ask(viewerOf("a@x", "owner", "w1", false));
    await settle();
    assert.equal(s.asked.length, 2, "read again, not left waiting on the failed one");
    s.asked[1]!.answer.resolve(noChecks(7));
    assert.equal((await next).automaticDecisions.policy.checked, 7);
  } finally { s.store.close(); }
});

test("an overview after the decisions changed does not take the making started before", async () => {
  const s = station();
  try {
    const before = s.ask(viewerOf("a@x", "owner", "w1", false));
    await settle();
    s.bump();
    const after = s.ask(viewerOf("b@x", "admin", "w1", false));
    await settle();
    assert.equal(s.asked.length, 2, "the changed decisions are read anew");
    s.asked[0]!.answer.resolve(noChecks(1));
    s.asked[1]!.answer.resolve(noChecks(2));
    assert.equal((await before).automaticDecisions.policy.checked, 1);
    assert.equal((await after).automaticDecisions.policy.checked, 2);
    // What is kept is the newer one's.
    assert.equal((await s.ask(viewerOf("c@x", "admin", "w1", false))).automaticDecisions.policy.checked, 2);
    assert.equal(s.asked.length, 2);
  } finally { s.store.close(); }
});

test("a making that must start again (old data prepared, the decisions changed meanwhile) does so without waiting on itself", async () => {
  // Old decisions' sessions not ready yet: prepared once, then made again, everyone asking at once waiting on that one.
  let ready = false;
  let prepared = 0;
  const s = station({ made: (viewer: any) => {
    if (!ready) throw new DecisionSessionsUnavailable();
    return { canEdit: viewer.role === "owner", recent: [] };
  } });
  try {
    s.store.prepareDecisionSessions = async () => { prepared++; ready = true; };
    const both = Promise.all([s.ask(viewerOf("a@x", "owner", "w1", false)), s.ask(viewerOf("b@x", "owner", "w1", false))]);
    await settle();
    assert.equal(s.asked.length, 1);
    s.asked[0]!.answer.resolve(noChecks(1));
    await settle();
    assert.equal(prepared, 1);
    assert.equal(s.asked.length, 2, "made again once prepared");
    s.asked[1]!.answer.resolve(noChecks(2));
    for (const r of await both) assert.equal(r.automaticDecisions.policy.checked, 2);
  } finally { s.store.close(); }

  // The decisions changed while a chat's name was prepared: made again on the new stamp, then kept.
  let preparing = 0;
  const t = station({
    hub: { prepareSessionChatNames: async (sessions: string[]) => {
      preparing++;
      const preparation = new SessionChatPreparation();
      for (const session of sessions) while (!preparation.step(t.store.db, session).done) {}
      if (preparing === 1) t.bump();
    } },
    made: (_viewer: any, options: any) => ({ canEdit: true, recent: [{ session: "s1", title: options.title("s1") }] }),
  });
  try {
    t.store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: "/work",
      token: "s1", createdAt: 1, lastActiveAt: 1, ws: "w1" });
    const older = t.store.openThread("slack", "C", "s1-older", null, null);
    t.store.joinThread(older.id, "s1", "slack");
    const thread = t.store.openThread("ember", "EMBER", "s1", "First", null);
    t.store.joinThread(thread.id, "s1", "ember");
    const answer = t.ask(viewerOf("a@x", "owner", "w1", false));
    await settle();
    t.asked[0]!.answer.resolve(noChecks(1));
    await settle();
    assert.equal(preparing, 1);
    assert.equal(t.asked.length, 2, "made again after the decisions changed");
    t.asked[1]!.answer.resolve(noChecks(2));
    const got = await answer;
    assert.equal(got.automaticDecisions.policy.checked, 2);
    assert.deepEqual(got.automaticDecisions.recent, [{ session: "s1", title: "First" }]);
    assert.equal((await t.ask(viewerOf("b@x", "admin", "w1", false))).automaticDecisions.policy.checked, 2, "kept on the new stamp");
    assert.equal(t.asked.length, 2);
  } finally { t.store.close(); }
});

test("overviews asked at once once the processes' memory is old measure it once", async () => {
  const s = station({ made: () => ({ canEdit: false, settings: {}, models: [], recent: [] }) });
  const original = platform.groupMemory;
  let measured = 0;
  let answer = deferred<Map<number, number>>();
  platform.groupMemory = (pgids: number[]) => { measured++; assert.deepEqual(pgids, [7]); return answer.promise; };
  try {
    s.store.listProcesses = () => [{ pgid: 7, runtime: "claude" } as any];
    const member = (email: string) => viewerOf(email, "member", "w1", false);
    const first = Promise.all(["a@x", "b@x", "c@x"].map((e) => s.ask(member(e))));
    await settle();
    assert.equal(measured, 1);
    answer.resolve(new Map([[7, 2048]]));
    for (const r of await first) assert.equal(r.processes[0].rssMb, 2);
    // Within the five seconds: kept.
    await s.ask(member("d@x"));
    assert.equal(measured, 1);
    // Older: measured again, once for all asking at once.
    s.advance(5_000);
    answer = deferred();
    const second = Promise.all(["a@x", "b@x"].map((e) => s.ask(member(e))));
    await settle();
    assert.equal(measured, 2);
    answer.resolve(new Map([[7, 4096]]));
    for (const r of await second) assert.equal(r.processes[0].rssMb, 4);
  } finally {
    platform.groupMemory = original;
    s.store.close();
  }
});
