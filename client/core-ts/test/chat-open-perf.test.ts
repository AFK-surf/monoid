// What opening or making a chat again costs on the parts that were most of it on a phone (root:chat.open, 49-205 ms of
// work in Hermes, `chat.shown` 175 ms of it): who a station's agents heard in Slack read of every message they ever
// heard as anything was said there, and every edited message made anew at every merge, so every one of them shown again
// (shownMessage, its words, its links) each time the chat was made. Counted, not timed.
import assert from "node:assert/strict";
import { test } from "node:test";
import { dbName } from "../src/data.ts";
import { merge } from "../src/entries.ts";
import type { NodeSql } from "../src/hosts/node-sql.ts";
import type { SqlRow, SqlValue } from "../src/host.ts";
import { holdLanguage } from "../src/i18n.ts";
import type { Topic } from "../src/protocol.ts";
import { work, workSince } from "../src/work.ts";
import { link, overview, setup, threads, ui } from "./views-rig.ts";

holdLanguage();

// deno-lint-ignore no-explicit-any
type J = any;

const ST = "ws/a";
const chatTopic: Topic = { topic: "chat", station: ST, thread: 7, session: null };
const sessionOf = (key: string): Topic => ({ topic: "session", station: ST, key });
const pageOf: Topic = { topic: "thread", station: ST, thread: 7 };
const member = (key: string): J => ({ thread: 7, session: key, connect: "ember", joinedAt: 1 });
const thread = (at: number): J => ({
  id: 7, surface: "ember", channel: "EMBER", channelName: null, threadTs: "7.0", title: null, createdAt: Math.trunc(at) - 10, creator: null,
  sessions: [member("k")], last: 70, lastMessage: null, read: 0, unread: 0, people: [], firstText: null,
});
const fullSession = (key: string, patch: J = {}): J => ({
  key, connect: "c1", scope: "thread", title: null, createdBy: null, boundTo: [], creator: null, participants: [], runtime: "claude", profile: "p1",
  profilePinned: false, model: null, effort: null, runtimeSessionId: null, workspace: "/w", running: false, createdAt: 1, lastActiveAt: 1, archivedAt: null,
  process: "cold", turns: 0, pending: 0, firstText: null, lastTurn: null, ...patch,
});
const overviewOf = (): J => ({
  viewer: { via: "local" }, connects: [], profiles: [], processes: [], counts: { sessions: 0, running: 0, warm: 0 }, mesh: null, slackUsers: [], slackTeams: [], slackApps: [], disk: null, logins: [],
});
const message = (n: number, text: string): J => ({ thread: 7, n, kind: "message", ts: `${n}.0`, authorKind: "agent", author: "k", authorName: null, text, at: n });
const edit = (n: number, target: number, text: string): J => ({ thread: 7, n, kind: "edit", target, text, attachments: [], quotes: [], at: n });

/// A transcript item of a message heard in Slack from `from` (`Name (U…)`), its Slack ts `ts` (seconds: when it was said).
const heard = (i: number, from: string, ts: number): [number, J] => [i, { at: "1970-01-01T00:00:01Z", kind: "user", text: `<message via="slack" thread="C0OPS/1.2" from="${from}" ts="${ts}">hi</message>` }];

/// Who a station's agents heard in Slack as the core named them before slack_who: every row heard, in the order said,
/// each id named as last heard, in the order first heard.
function reference(sql: NodeSql, station: string): [string, string][] {
  const rows = sql.all("SELECT user, who FROM slack_said WHERE station = ? AND out = 0 AND user IS NOT NULL AND who IS NOT NULL AND who != '' ORDER BY at", [station]);
  return [...new Map(rows.map((r) => [String(r[0]).replace(/^<@(.+)>$/, "$1"), String(r[1])])).entries()];
}

/// The rows the database's statements on what was heard in Slack give, counted from now.
function slackRows(sql: NodeSql): { rows: number } {
  const counted = { rows: 0 };
  const all = sql.all.bind(sql);
  sql.all = (q: string, params?: readonly SqlValue[]): SqlRow[] => {
    const rows = all(q, params);
    if (/\bslack_(said|who)\b/.test(q)) counted.rows += rows.length;
    return rows;
  };
  return counted;
}

/// A rig with a chat on ST shown, its station's agents having heard 5,000 messages in Slack from 20 people (renamed as
/// they went) over 50 sessions.
async function heardMuch() {
  const t = setup();
  const u = ui();
  t.subscribe(1, chatTopic);
  t.set(threads(ST), [thread(t.host.nowMs())]);
  t.set(pageOf, { first: 1, last: 2, entries: [message(1, "hi"), message(2, "<@U3> 看一下")], end: false, thread: thread(t.host.nowMs()) });
  t.set(sessionOf("k"), { session: fullSession("k"), threads: [thread(t.host.nowMs())], turns: [] });
  t.set(overview(ST), overviewOf());
  t.set(link(ST), { state: "online" });
  let ts = 1000;
  for (let s = 0; s < 50; s++) {
    const items: [number, J][] = [];
    for (let i = 0; i < 100; i++) {
      const who = (s * 100 + i) % 20;
      // (each person renamed every 1,000 messages; the ids of a few heard as their mentions, as a bot's are)
      const id = who % 7 === 0 ? `<@U${who}>` : `U${who}`;
      items.push(heard(i, `Name ${who} v${Math.floor((s * 100 + i) / 1000)} (${id})`, ts++));
    }
    t.data.putItems("transcript", ST, `k${s}`, items);
  }
  await t.read(u, 1);
  const sql = t.host.sqls.get(dbName("s1"))!;
  return { t, u, sql, next: () => ts++ };
}

test("who_a_station_heard_in_slack_is_read_of_one_row_a_person_not_of_every_message_heard", async () => {
  const { t, u, sql, next } = await heardMuch();
  assert.equal(Number(sql.all("SELECT count(*) FROM slack_said WHERE station = ?", [ST])[0]![0]), 5000);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  assert.equal(t.data.slackNames(ST).length, 20);
  assert.ok(u.value.messages.length === 2, JSON.stringify(u.value).slice(0, 300));

  // Someone heard again as they were last named: the names are the list they were, and what was heard is not read again.
  const names = t.data.slackNames(ST);
  const [, last] = names.find(([id]) => id === "U3")!;
  let counted = slackRows(sql);
  const before = { ...work };
  t.data.putItems("transcript", ST, "k-new", [heard(0, `${last} (U3)`, next())]);
  await t.read(u, 1);
  const chats = workSince(before).chats;
  console.log(`a message heard from someone named as before: ${counted.rows} rows read of what was heard in Slack`);
  assert.ok(counted.rows <= 8, `${counted.rows} rows read of what was heard in Slack (5,000 before)`);
  assert.ok(t.data.slackNames(ST) === names, "the very list it was");
  // (the chat is not made again for a name that did not change)
  assert.equal(chats, 0);

  // Someone heard for the first time, and someone renamed: the chat made again, reading of them alone.
  counted = slackRows(sql);
  t.data.putItems("transcript", ST, "k-new", [heard(1, "Newcomer (U99)", next()), heard(2, "Three Renamed (U3)", next())]);
  await t.read(u, 1);
  const read = counted.rows;
  console.log(`someone new and someone renamed: ${read} rows read of what was heard in Slack`);
  assert.ok(read <= 20 + 8, `${read} rows read of what was heard in Slack`);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  assert.deepEqual(t.data.slackNames(ST).slice(-1), [["U99", "Newcomer"]]);
  t.store.runner.shutdown();
});

test("who_was_heard_in_slack_is_what_the_messages_kept_say_as_some_go_and_as_it_is_filled_anew", async () => {
  const { t, u, sql, next } = await heardMuch();
  // A person's last name heard in a session that goes, and their first heard in another that goes: named and ordered by
  // what is left.
  t.data.putItems("transcript", ST, "k-late", [heard(0, "Late Name (U5)", next()), heard(1, "Only Here (U77)", next())]);
  await t.read(u, 1);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  t.data.forgetLog("transcript", ST, "k-late");
  await t.read(u, 1);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  assert.ok(!t.data.slackNames(ST).some(([id]) => id === "U77"));
  t.data.forgetLog("transcript", ST, "k0");
  await t.read(u, 1);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  // A transcript cut: what was heard past it goes.
  t.data.putItems("transcript", ST, "k49", [], 10);
  await t.read(u, 1);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  // An item written over by another person's: the one written over found again.
  t.data.putItems("transcript", ST, "k-over", [heard(0, "First (U88)", next())]);
  t.data.putItems("transcript", ST, "k-over", [heard(0, "Second (U89)", next())]);
  await t.read(u, 1);
  assert.deepEqual(t.data.slackNames(ST), reference(sql, ST));
  assert.ok(!t.data.slackNames(ST).some(([id]) => id === "U88"));
  const now = reference(sql, ST);
  t.store.runner.shutdown();
  // A core from before slack_who: it is made and filled as the database opens.
  sql.exec("DROP TABLE slack_who");
  const again = setup({ host: t.host });
  assert.deepEqual(again.data.slackNames(ST), now);
  // A core that kept it while a core from before wrote slack_said: filled anew with slack_said.
  sql.exec("DROP TABLE slack_said");
  again.store.runner.shutdown();
  const anew = setup({ host: t.host });
  assert.deepEqual(anew.data.slackNames(ST), reference(sql, ST));
  anew.store.runner.shutdown();
});

test("an_edited_message_is_the_object_it_was_while_its_edits_are_so_the_chat_shows_it_again_only_as_it_changes", async () => {
  const entries: J[] = [];
  for (let i = 1; i <= 20; i++) entries.push(message(i, `第 ${i} 条`));
  for (let i = 1; i <= 20; i++) entries.push(edit(20 + i, i, `第 ${i} 条（改过）`));
  const first = merge(entries);
  const heardOf = (es: J[]) => {
    const heard: [number, number][] = [];
    merge(es, (seq, e) => heard.push([seq, (e as J).n]));
    return heard;
  };
  assert.deepEqual(first.map((m) => [m.text, m.editedAt]), entries.slice(0, 20).map((_, i) => [`第 ${i + 1} 条（改过）`, 21 + i]));
  const second = merge([...entries]);
  assert.ok(first.every((m, i) => m === second[i]), "the very objects they were");
  // (what source hears of them, the same as they are made or taken)
  assert.deepEqual(heardOf(entries), heardOf(entries));
  assert.deepEqual(heardOf(entries).filter(([seq]) => seq === 3), [[3, 3], [3, 23]]);
  // An edit more: that message alone made again.
  const more = [...entries, edit(41, 3, "第 3 条（又改）")];
  const third = merge(more);
  assert.ok(third.every((m, i) => (i === 2 ? m !== first[i] && m.text === "第 3 条（又改）" : m === first[i])));

  // Shown in a chat: something else changing makes the chat again, not its messages.
  const t = setup();
  const u = ui();
  t.subscribe(1, chatTopic);
  t.set(threads(ST), [thread(t.host.nowMs())]);
  t.set(pageOf, { first: 1, last: 40, entries, end: true, thread: thread(t.host.nowMs()) });
  t.set(sessionOf("k"), { session: fullSession("k"), threads: [thread(t.host.nowMs())], turns: [] });
  t.set(overview(ST), overviewOf());
  t.set(link(ST), { state: "connecting" });
  await t.read(u, 1);
  assert.equal(u.value.messages.length, 20);
  assert.equal(u.value.messages[0].text, "第 1 条（改过）");
  for (const [i, state] of ["online", "connecting", "online"].entries()) {
    const before = { ...work };
    t.set(link(ST), { state });
    t.set(sessionOf("k"), { session: fullSession("k", { lastActiveAt: 10 + i }), threads: [thread(t.host.nowMs())], turns: [] });
    await t.read(u, 1);
    const made = workSince(before);
    assert.ok(made.chats >= 1, "the chat made again");
    assert.equal(made.messages, 0, `${made.messages} messages shown again`);
    assert.equal(u.value.link.state, state);
  }
  // An edit coming: that message alone.
  const before = { ...work };
  t.set(pageOf, { first: 1, last: 41, entries: more, end: true, thread: thread(t.host.nowMs()) });
  await t.read(u, 1);
  assert.equal(workSince(before).messages, 1);
  assert.equal(u.value.messages[2].text, "第 3 条（又改）");
  t.store.runner.shutdown();
});

test("chat_view_settles_only_mine_outbox_entries_and_marks_waiting_tail_across_many_person_messages", async () => {
  const t = setup();
  const u = ui();
  try {
    const entries: J[] = [];
    for (let n = 1; n <= 1200; n++) {
      const isMine = n % 2 === 0;
      const text = n === 1 || n === 600 ? "shared text" : `person msg ${n}`;
      entries.push({
        thread: 7,
        n,
        kind: "message",
        ts: `${n}.0`,
        authorKind: "person",
        author: isMine ? "me@x.com" : "other@x.com",
        authorName: isMine ? "Me" : "Other",
        text,
        attachments: [],
        quotes: [],
        at: n,
      });
    }
    t.views.local.outboxAdd(ST, 7, { text: "shared text", attachments: [], quotes: [] }, 0);
    const keepId = t.views.local.outboxAdd(ST, 7, { text: "still unsent", attachments: [], quotes: [] }, 599);
    t.subscribe(1, chatTopic);
    t.set(threads(ST), [thread(t.host.nowMs())]);
    t.set(pageOf, { first: 1, last: 1200, entries, end: true, thread: thread(t.host.nowMs()) });
    t.set(sessionOf("k"), { session: fullSession("k", { pending: 2 }), threads: [thread(t.host.nowMs())], turns: [] });
    t.set(overview(ST), overviewOf());
    t.set(link(ST), { state: "online" });
    await t.read(u, 1);

    assert.equal(u.value.messages.length, 1200);
    assert.equal(u.value.messages[0].mine, false);
    assert.equal(u.value.messages[599].mine, true);
    assert.deepEqual(t.views.local.outbox(ST, 7).map((m: J) => m.id), [keepId]);
    assert.deepEqual(u.value.outbox.map((m: J) => m.id), [keepId]);
    const waitingSeqs = u.value.messages.filter((m: J) => m.waiting === true).map((m: J) => m.seq);
    assert.deepEqual(waitingSeqs, [1199, 1200]);
  } finally {
    t.store.runner.shutdown();
  }
});
