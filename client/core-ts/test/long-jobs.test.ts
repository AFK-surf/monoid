// What is left up long on a workspace's stations (the `longJobs` view, jobs.ts `longJobs`) as whose it is: in a
// workspace of one, all of it the viewer's; where others are members, what the viewer's chats run (a chat's second
// agent's too, by `chat_agent`) and the viewer's own views lighting the bell, the rest (another's chats, a job of no
// chat, a shared station's simulators) folded apart, lighting nothing.
import assert from "node:assert/strict";
import { test } from "node:test";
import { holdLanguage } from "../src/i18n.ts";
import { LONG } from "../src/jobs.ts";
import { link, rows, setup, ui, workspace } from "./views-rig.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const ME = { sub: "s1", email: "me@x.com", name: "我", role: "member" };
const ANA = { sub: "s2", email: "ana@x.com", name: "Ana Lee", role: "member" };
const agent = (key: string): J => ({ key, connect: null, profile: "p1", runtime: "claude", model: "claude-opus-5-5", effort: null, process: "cold", pending: 0, lastTurn: null });
const chat = (id: string, mine: boolean, agents: string[], at: number): J => ({ id, session: id, thread: 0, title: id === "own" ? "修登录" : "Ana 的发布", agents: agents.map(agent), last: null, unread: false, mine, lastActiveAt: at, connect: null, origin: null });

async function longJobsOf(members: J[]): Promise<J> {
  const t = setup();
  const now = t.host.nowMs();
  const up = (id: string, session: string, patch: J = {}): J => ({ id, session, name: id, state: "running", port: null, startedAt: now - 2 * LONG, ...patch });
  t.set(workspace(), { id: "ws", role: "member", members, stations: [{ id: "a", name: "alpha", last_seen: null, version: null }] });
  t.set(link("ws/a"), { state: "online" });
  t.set(rows("ws/a"), [chat("own", true, ["own", "helper"], now - 1_000), chat("theirs", false, ["theirs"], now - 2_000)]);
  t.set({ topic: "jobs", station: "ws/a" }, [
    up("svc", "own", { port: 3000 }),
    // (the second agent of the viewer's chat: found by `chat_agent`)
    up("help", "helper"),
    up("ana-svc", "theirs", { port: 3001 }),
    up("loose", "gone"),
  ]);
  const u = ui();
  t.subscribe(1, { topic: "longJobs", scope: "ws" });
  await t.read(u, 1);
  // (a station's screens are no record of the device's: its link's, set once the view asks them)
  const view = (id: string, patch: J = {}): J => ({ id, name: "Ana Lee", device: "MacBook", at: now - 2 * LONG, may: true, ...patch });
  t.set({ topic: "screens", station: "ws/a" }, {
    screens: [
      { id: "simulator:A", title: "iPhone A", since: now - 3 * LONG, closable: true, views: [view("v1", { name: "我", mine: true })] },
      { id: "simulator:B", title: "iPhone B", since: now - 3 * LONG, closable: true, views: [view("v2")] },
    ],
  });
  await t.read(u, 1);
  return u.value;
}

const ids = (groups: J[] | undefined) => (groups ?? []).map((g: J) => [g.key, g.jobs.map((j: J) => j.id)]);

test("where_others_are_members_the_viewers_own_light_the_bell_and_the_rest_fold_apart", async () => {
  const v = await longJobsOf([ME, ANA]);
  assert.deepEqual(ids(v.groups), [["services", ["svc"]], ["jobs", ["help"]], ["simulators", ["screen:simulator:A"]], ["views", ["view:simulator:A/v1"]]]);
  assert.deepEqual(ids(v.otherGroups), [["services", ["ana-svc"]], ["jobs", ["loose"]], ["simulators", ["screen:simulator:B"]], ["views", ["view:simulator:B/v2"]]]);
  assert.deepEqual([v.otherCount, v.otherText], [4, "其他运行中 · 4"]);
  assert.equal(v.lit, true);
  assert.deepEqual(v.ids.sort(), ["ws/a/help", "ws/a/screen:simulator:A", "ws/a/svc", "ws/a/view:simulator:A/v1"]);
  // (a second agent's task is in the chat it is among the agents of)
  assert.equal(v.groups[1].jobs[0].whereText, "修登录");
  assert.equal(v.otherGroups[0].jobs[0].whereText, "Ana 的发布");
});

test("in_a_workspace_of_one_all_of_it_is_the_viewers_and_nothing_is_folded", async () => {
  const v = await longJobsOf([ME]);
  assert.deepEqual(ids(v.groups), [["services", ["svc", "ana-svc"]], ["jobs", ["help", "loose"]], ["simulators", ["screen:simulator:A", "screen:simulator:B"]], ["views", ["view:simulator:A/v1", "view:simulator:B/v2"]]]);
  assert.ok(!("otherGroups" in v) && !("otherCount" in v) && !("otherText" in v), JSON.stringify(Object.keys(v)));
});
