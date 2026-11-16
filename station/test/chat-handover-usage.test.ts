// What a chat's agents spent goes with it (replica/handover.ts, store/handover.ts): its calls (`usage`), how far its
// transcripts were read (`usage_files`) and its usage as kept (`session_usage`) are sent with its rows to a station that
// takes them, put in once by id, their threads and accounts as they are there; a hand-over that fails takes out only
// what it put in. A chat handed before its calls went with it (a station from before: the real run of 2026-11-16,
// 2,489 chats' calls left on Office-VM-1, none on Office-Host-2) has them sent as the station it went to is heard from
// (`handover.usage`), once. Split from chat-handover.test.ts by subject; its stations are move-world.ts's.
import assert from "node:assert/strict";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { Refused } from "../src/mesh/bus.ts";
import { usageNow } from "../src/read/usage.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import type { UsageCall, UsageFor } from "../src/store/usage.ts";
import { message } from "./hub-fakes.ts";
import { WS, A, B, C, type Station, world, endTurn, stillfailChat, homeThread } from "./move-world.ts";

type Json = any;

type Call = { id: string; at: number; thread: number | null; profile: string | null; input: number; output: number; context: number | null };

/// Calls of session `key` recorded on `st` as its usage counter records them, read from transcript `file` (under its
/// data directory) up to `offset`.
function record(st: Station, key: string, file: string, offset: number, calls: Call[]): void {
  const path = join(st.rig.dir, "transcripts", "claude", file);
  st.rig.store.recordUsage(path, { session: key, offset, model: "claude-sonnet-4-5" }, "claude", calls.map((c): [UsageCall, UsageFor] => [
    { id: c.id, at: c.at, model: "claude-sonnet-4-5", subagent: false, fast: false, input: c.input, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: c.output, calls: 1, context: c.context, window: null },
    { turn: null, person: null, thread: c.thread, profile: c.profile },
  ]));
}

/// The calls of session `key` on `st`, by id: their thread, account and tokens.
function callsOf(st: Station, key: string): Record<string, Json> {
  const rows = st.rig.store.db.prepare("SELECT id, thread, profile, input, output FROM usage WHERE session = ? ORDER BY id").all(key) as Json[];
  return Object.fromEntries(rows.map((r) => [r.id, { thread: r.thread, profile: r.profile, input: r.input, output: r.output }]));
}

/// What `st` counts as its workspace's: the input of the calls of the sessions in sight there (not handed away, not
/// coming).
function inSight(st: Station): number {
  return (st.rig.store.db.prepare(`SELECT COALESCE(SUM(u.input), 0) AS n FROM usage u JOIN sessions s ON s.key = u.session
    WHERE s.ws IS NULL OR (s.ws NOT LIKE 'handed:%' AND s.ws NOT LIKE 'coming:%')`).get() as { n: number }).n;
}

const filesOf = (st: Station, key: string) => st.rig.store.db.prepare("SELECT path, offset FROM usage_files WHERE session = ? ORDER BY path").all(key).map((r) => ({ ...r })) as { path: string; offset: number }[];
const usageRequests = (w: ReturnType<typeof world>) => w.heard.filter((h) => h.method === "handover.usage");

/// `st` as a station from before calls went with a chat: it takes none with one, and knows no `handover.usage`
/// (`refuse`: that alone); what makes it as it is now again.
function fromBefore(st: Station, refuse: "all" | "usage" = "all"): () => void {
  const now = st.moves.answers(() => true);
  st.bus.on("handover.", async (peer: string, request: Json, ws?: string) => {
    if (request?.method === "handover.usage") throw new Refused("not begun: handover.begin first");
    const answer = await now(peer, request, ws);
    if (refuse === "all" && request?.method === "handover.begin") delete answer.usage;
    return answer;
  });
  return () => st.bus.on("handover.", now);
}

/// A still.fail chat of `st`'s with calls in its home thread, kept as its counter keeps them.
async function plainChatWithCalls(st: Station, prefix: string) {
  const { key, thread } = await stillfailChat(st);
  const t0 = st.fibers.now();
  record(st, key, `${prefix}.jsonl`, 70, [
    { id: `${prefix}-1`, at: t0 + 1_000, thread, profile: "cc", input: 10, output: 1, context: 100 },
    { id: `${prefix}-2`, at: t0 + 2_000, thread, profile: "cc", input: 20, output: 2, context: 200 },
  ]);
  st.rig.store.setSessionUsage(key, usageNow(st.rig.store, key)!);
  return key;
}

/// A still.fail chat of A's that also takes part in a Slack thread (by connect cl), with calls in both and none, kept
/// (session_usage) as A's counter keeps them.
async function chatWithCalls(a: Station) {
  const { key, thread } = await stillfailChat(a);
  const first = message({ text: "<@UBOT> look" });
  await a.connects.receive("cl", { type: "message", message: first });
  await endTurn(a, sessionKey("cl", first.channel, first.threadTs));
  const slack = a.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  a.rig.store.joinThread(slack.id, key, "cl");
  const t0 = a.fibers.now();
  record(a, key, "one.jsonl", 900, [
    { id: "a-1", at: t0 + 1_000, thread, profile: "cc", input: 100, output: 10, context: 1_000 },
    { id: "a-2", at: t0 + 2_000, thread: slack.id, profile: "cc", input: 200, output: 20, context: 2_000 },
    { id: "a-3", at: t0 + 3_000, thread: null, profile: "cc", input: 300, output: 30, context: 3_000 },
  ]);
  a.rig.store.setSessionUsage(key, usageNow(a.rig.store, key)!);
  return { key, thread, slack: { channel: first.channel, threadTs: first.threadTs }, t0 };
}

test("a chat handed over takes its calls: there with its threads and account as they are there, its transcripts' places moved, its usage as kept; out of sight here, counted once across both", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, slack } = await chatWithCalls(a);
  const total = inSight(a);
  assert.equal(total, 600);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  const home = homeThread(b, key);
  const slackThere = b.rig.store.threadAt("slack:T1", slack.channel, slack.threadTs)!.id;
  assert.deepEqual(callsOf(b, key), {
    "a-1": { thread: home, profile: "ccb", input: 100, output: 10 },
    "a-2": { thread: slackThere, profile: "ccb", input: 200, output: 20 },
    "a-3": { thread: null, profile: "ccb", input: 300, output: 30 },
  });
  assert.deepEqual(filesOf(b, key), [{ path: join(b.rig.dir, "transcripts", "claude", "one.jsonl"), offset: 900 }], "its transcript's place, under the data directory there");
  const kept = b.rig.store.sessionUsage(key);
  assert.equal(kept?.modelCalls, 3);
  assert.equal(kept?.outputTokens, 60);
  assert.equal(kept?.contextTokens, 3_000, "its context its latest call's");
  // (out of sight here, its calls kept: counted there alone)
  assert.equal(inSight(a), 0);
  assert.equal(inSight(b), total);
  assert.equal(Object.keys(callsOf(a, key)).length, 3, "kept here");
  // (it went with its calls: nothing of them sent again as B is heard from)
  a.moves.handover.reached(B);
  await w.quiet();
  assert.deepEqual(usageRequests(w), []);
});

test("handed over, its agent working there, and back: every call once on each side, the counts as sent; then a hand-over that fails takes out only the calls it put in", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, t0 } = await chatWithCalls(a);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const there = homeThread(b, key);
  record(b, key, "two.jsonl", 400, [
    { id: "b-1", at: t0 + 10_000, thread: there, profile: "ccb", input: 1_000, output: 100, context: 4_000 },
    { id: "b-2", at: t0 + 11_000, thread: there, profile: "ccb", input: 2_000, output: 200, context: 5_000 },
  ]);
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(a.rig.store.handedTo(key), null);
  const home = a.rig.store.homeChat(key)!.id;
  const calls = callsOf(a, key);
  assert.deepEqual(Object.keys(calls), ["a-1", "a-2", "a-3", "b-1", "b-2"], "each once");
  assert.deepEqual(calls["b-2"], { thread: home, profile: "cc", input: 2_000, output: 200 }, "its thread and account as they are here");
  assert.equal((a.rig.store.db.prepare("SELECT COUNT(*) AS n FROM usage WHERE session = ?").get(key) as { n: number }).n, 5);
  const kept = a.rig.store.sessionUsage(key);
  assert.equal(kept?.modelCalls, 5);
  assert.equal(kept?.outputTokens, 360);
  assert.equal(kept?.contextTokens, 5_000, "the latest call's, made there");
  assert.equal(inSight(b), 0);
  assert.equal(inSight(a), 3_600);

  // A hand-over that fails after its rows went: what was there before stays as it was, the call it put in is out.
  record(a, key, "one.jsonl", 1_200, [{ id: "a-4", at: t0 + 20_000, thread: home, profile: "cc", input: 7, output: 7, context: 6_000 }]);
  const before = { calls: callsOf(b, key), files: filesOf(b, key), kept: b.rig.store.sessionUsage(key) };
  assert.deepEqual(Object.keys(before.calls), ["a-1", "a-2", "a-3", "b-1", "b-2"], "B keeps what it had");
  let put: Json = null;
  a.onFail = (step) => {
    if (step === "counts") put = { calls: callsOf(b, key), files: filesOf(b, key) };
  };
  a.fails.add("counts");
  assert.notEqual(await a.moves.handover.handOver(key, B).then(() => null, (e: Error) => e.message), null);
  await w.quiet();
  assert.ok(put !== null && "a-4" in put.calls, `put in as it went: ${JSON.stringify(put)}`);
  assert.notDeepEqual(put.files, before.files, "a transcript read further put in as it went");
  assert.deepEqual({ calls: callsOf(b, key), files: filesOf(b, key), kept: b.rig.store.sessionUsage(key) }, before, "as it was before");
  assert.equal(a.rig.store.handedTo(key), null, "it goes on here");
  assert.equal(Object.keys(callsOf(a, key)).length, 6);
});

test("chats handed before their calls went with them (a station from before): their calls go as it takes them, as it is heard from, once; a page of calls at a time, followed where a chat went on", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  // B as a station from before: it takes no calls with a chat, and knows no `handover.usage`.
  const now = fromBefore(b);
  const { key, t0, slack: s1 } = await chatWithCalls(a);
  // (and a Slack thread's chat with calls of its own, kept as A kept them)
  const first = message({ text: "<@UBOT> other", channel: "C2", threadTs: "1900.1", ts: "1900.1" });
  await a.connects.receive("cl", { type: "message", message: first });
  const other = sessionKey("cl", first.channel, first.threadTs);
  await endTurn(a, other);
  const otherThread = a.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!.id;
  record(a, other, "other.jsonl", 50, Array.from({ length: 1_003 }, (_, n) => ({ id: `o-${String(n).padStart(4, "0")}`, at: t0 + n, thread: otherThread, profile: "cc", input: 1, output: 1, context: n })));
  a.rig.store.setSessionUsage(other, usageNow(a.rig.store, other)!);
  for (const k of [key, other]) assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: k })).failed, null);
  await w.quiet();
  assert.deepEqual(callsOf(b, key), {}, "none went with it");
  assert.equal(b.rig.store.sessionUsage(key), null);
  assert.equal(b.rig.store.sessionUsage(other), null);
  // (its agent working there meanwhile: two calls of its own, later)
  const there = homeThread(b, key);
  record(b, key, "two.jsonl", 400, [
    { id: "b-1", at: t0 + 10_000, thread: there, profile: "ccb", input: 1_000, output: 100, context: 4_000 },
    { id: "b-2", at: t0 + 11_000, thread: there, profile: "ccb", input: 2_000, output: 200, context: 5_000 },
  ]);
  // Heard from while it does not take them: asked, refused, nothing kept of how far it went.
  a.moves.handover.reached(B);
  await w.quiet();
  assert.ok(usageRequests(w).length > 0 && usageRequests(w).every((h) => h.failed !== null), JSON.stringify(usageRequests(w)));
  const synced = join(a.rig.dir, "replica", "handover", "usage-synced.json");
  assert.equal(existsSync(synced), false, "not past any chat");
  assert.deepEqual(Object.keys(callsOf(b, key)), ["b-1", "b-2"]);
  // B updated: heard from, it is sent them.
  now();
  const asked = usageRequests(w).length;
  a.moves.handover.reached(B);
  await w.quiet();
  const sent = usageRequests(w).slice(asked);
  assert.ok(sent.every((h) => h.failed === null), JSON.stringify(sent));
  assert.equal(sent.length, 1 + 3, "a request for the one chat, three pages (500, 500, 3) for the other");
  const home = homeThread(b, key);
  const calls = callsOf(b, key);
  assert.deepEqual(Object.keys(calls), ["a-1", "a-2", "a-3", "b-1", "b-2"]);
  assert.deepEqual(calls["a-1"], { thread: home, profile: "ccb", input: 100, output: 10 }, "its home thread there");
  assert.equal(calls["a-2"]!.thread, b.rig.store.threadAt("slack:T1", s1.channel, s1.threadTs)!.id, "a Slack thread there by its place");
  const kept = b.rig.store.sessionUsage(key);
  assert.equal(kept?.modelCalls, 5, "its calls from before and its own there, added up");
  assert.equal(kept?.inputTokens, 3_600);
  assert.equal(kept?.contextTokens, 5_000, "its context its latest call's, made there");
  const otherCalls = callsOf(b, other);
  assert.equal(Object.keys(otherCalls).length, 1_003);
  assert.ok(Object.values(otherCalls).every((c: Json) => c.thread === b.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!.id && c.profile === "ccb"));
  assert.equal(b.rig.store.sessionUsage(other)?.modelCalls, 1_003);
  assert.deepEqual(filesOf(b, other), [{ path: join(b.rig.dir, "transcripts", "claude", "other.jsonl"), offset: 50 }]);
  assert.equal(inSight(b), 3_600 + 1_003);
  assert.equal(inSight(a), 0);
  assert.deepEqual(JSON.parse(readFileSync(synced, "utf8")), { [B]: [key, other].sort().at(-1) });
  // Heard from again, and after a start: nothing asked.
  const done = usageRequests(w).length;
  a.moves.handover.reached(B);
  await w.quiet();
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  a.moves.handover.reached(B);
  await w.quiet();
  assert.equal(usageRequests(w).length, done, "each chat's calls sent once");
  // (and again, as if the record of how far it went were lost, B's usage of the chat lost with it as a stop between its
  // calls taken and its usage kept would: nothing doubled there, its usage kept again as its calls say)
  await a.moves.close();
  rmSync(synced);
  b.rig.store.db.prepare("DELETE FROM session_usage WHERE session = ?").run(key);
  assert.equal(b.rig.store.sessionUsage(key), null);
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  assert.equal(Object.keys(callsOf(b, key)).length, 5);
  assert.equal(b.rig.store.sessionUsage(key)?.modelCalls, 5);
  assert.equal(Object.keys(callsOf(b, other)).length, 1_003);
});

test("a chat handed without its calls after the last run stopped past its key is looked at again: its calls go there all the same", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  // (where the last run stopped: past every chat's key, as one whose key sorts after this one's would leave it)
  const synced = join(a.rig.dir, "replica", "handover", "usage-synced.json");
  mkdirSync(join(a.rig.dir, "replica", "handover"), { recursive: true });
  writeFileSync(synced, JSON.stringify({ [B]: "chat:~" }));
  await a.moves.close();
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  const now = fromBefore(b);
  const key = await plainChatWithCalls(a, "p");
  assert.ok(key < "chat:~");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.deepEqual(callsOf(b, key), {});
  now();
  a.moves.handover.reached(B);
  await w.quiet();
  assert.deepEqual(Object.keys(callsOf(b, key)), ["p-1", "p-2"]);
  assert.equal(b.rig.store.sessionUsage(key)?.modelCalls, 2);
  assert.deepEqual(JSON.parse(readFileSync(synced, "utf8")), { [B]: key });
});

test("a chat handed without its calls that went on from there to a third station: its calls followed there", async () => {
  const w = world([A, B, C]);
  const a = w.get(A);
  const b = w.get(B);
  const c = w.get(C);
  // (B from before as the chat comes; then taking calls with a chat, but answering no `handover.usage` until it is on)
  const now = fromBefore(b);
  const key = await plainChatWithCalls(a, "f");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  now();
  fromBefore(b, "usage");
  const on = await b.moves.scheduler.move(WS, C, { module: "chats", item: key });
  await w.quiet();
  assert.equal(on.failed, null, JSON.stringify(on));
  assert.equal(b.rig.store.handedTo(key)?.station, C);
  assert.deepEqual(callsOf(c, key), {}, "none on the way");
  now();
  const asked = usageRequests(w).length;
  a.moves.handover.reached(B);
  await w.quiet();
  const sent = usageRequests(w).slice(asked);
  assert.deepEqual(sent.map((h) => [h.to.slice(0, 1), h.failed]), [["b", null], ["c", null]], "asked of B, which says where it went on, then of C");
  assert.deepEqual(callsOf(c, key), {
    "f-1": { thread: homeThread(c, key), profile: "ccc", input: 10, output: 1 },
    "f-2": { thread: homeThread(c, key), profile: "ccc", input: 20, output: 2 },
  });
  assert.equal(c.rig.store.sessionUsage(key)?.modelCalls, 2);
  assert.deepEqual(callsOf(b, key), {}, "not put in where it is not");
});
