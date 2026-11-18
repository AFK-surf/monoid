// What making a chat again costs while its reply streams, on the parts that were most of it on a phone (0.1.10103 and
// 0.1.10123: `chat.make` 77-146 ms, `chat.draw` 13-22 ms with no Markdown read, 30 makes in a row): each of its files
// asked of the database twice (a thumbnail, a poster), each chat it links to read whole for a title, and every message
// drawn anew and walked to be found equal. Counted, not timed (what it takes is printed).
import assert from "node:assert/strict";
import { test } from "node:test";
import { dbName } from "../src/data.ts";
import type { NodeSql } from "../src/hosts/node-sql.ts";
import type { SqlRow, SqlValue } from "../src/host.ts";
import { cloneOf } from "../src/hosts/hermes-globals.ts";
import { holdLanguage } from "../src/i18n.ts";
import type { Topic } from "../src/protocol.ts";
import { work, workSince } from "../src/work.ts";
import { link, overview, rows, setup, threads, ui, workspace } from "./views-rig.ts";

holdLanguage();

// deno-lint-ignore no-explicit-any
type J = any;

const ST = "ws/a";
const FILES = 20;
const LINKS = 10;
const OPENED = 10;
const ROUNDS = 20;
const chatTopic: Topic = { topic: "chat", station: ST, thread: 7, session: null };
const sessionOf = (key: string): Topic => ({ topic: "session", station: ST, key });
const pageOf: Topic = { topic: "thread", station: ST, thread: 7 };
const member = (key: string): J => ({ thread: 7, session: key, connect: "ember", joinedAt: 1 });
const thread = (at: number): J => ({
  id: 7, surface: "ember", channel: "EMBER", channelName: null, threadTs: "7.0", title: null, createdAt: Math.trunc(at) - 10, creator: null,
  sessions: [member("k")], last: FILES + LINKS + 1, lastMessage: null, read: 0, unread: 0, people: [], firstText: null,
});
const fullSession = (key: string, patch: J = {}): J => ({
  key, connect: "c1", scope: "thread", title: null, createdBy: null, boundTo: [], creator: null, participants: [], runtime: "claude", profile: "p1",
  profilePinned: false, model: null, effort: null, runtimeSessionId: null, workspace: "/w", running: false, createdAt: 1, lastActiveAt: 1, archivedAt: null,
  process: "cold", turns: 0, pending: 0, firstText: null, lastTurn: null, ...patch,
});
const overviewOf = (): J => ({
  viewer: { via: "local" }, connects: [], profiles: [], processes: [], counts: { sessions: 0, running: 0, warm: 0 }, mesh: null, slackUsers: [], slackTeams: [], slackApps: [], disk: null, logins: [],
});
const agentOf = (key: string, patch: J = {}): J => ({ key, connect: "c1", profile: "p1", runtime: "claude", model: "opus", effort: null, process: "cold", pending: 0, lastTurn: null, ...patch });
const rowOf = (id: string, patch: J = {}): J => ({ id, session: id, thread: null, title: `${id} 的标题`, agents: [agentOf(id)], last: null, unread: false, mine: false, lastActiveAt: 1, connect: null, origin: null, ...patch });
const entry = (n: number, text: string, patch: J = {}): J => ({ thread: 7, n, kind: "message", ts: `${n}.0`, authorKind: "agent", author: "k", authorName: null, text, at: n, ...patch });

/// The chat's messages: FILES with a picture each (kept on the device but the last), LINKS each linking to a chat of the
/// station's list, and one of words alone.
function entries(): J[] {
  const out: J[] = [];
  for (let i = 0; i < FILES; i++) out.push(entry(i + 1, `截图 ${i}`, { attachments: [{ name: `img${i}.png`, path: `/w/out/img${i}.png`, size: 10, mime: "image/png" }] }));
  for (let i = 0; i < LINKS; i++) out.push(entry(FILES + i + 1, `看这个 https://app.still.fail/chats/l${i}`));
  out.push(entry(FILES + LINKS + 1, "好了"));
  return out;
}

/// The station's list: the chat (leading OPENED chats), the chats linked to (the last of them archived) and those opened.
function listed(titles: (i: number) => string = (i) => `链接 ${i}`): J[] {
  const opened = Array.from({ length: OPENED }, (_, i) => ({ session: `o${i}`, title: `开的 ${i}` }));
  return [
    rowOf("k", { thread: 7, title: "领头的", opened }),
    ...Array.from({ length: LINKS - 1 }, (_, i) => rowOf(`l${i}`, { thread: 100 + i, title: titles(i) })),
    ...Array.from({ length: OPENED }, (_, i) => rowOf(`o${i}`, { title: `开的 ${i} 现在`, agents: [agentOf(`o${i}`, { process: i % 2 === 0 ? "running" : "cold" })] })),
  ];
}

/// Statements counted as they run on the account's database: those of `file_kept`, and those reading a linked chat's
/// record (its JSON).
function counting(sql: NodeSql): { kept: number; linkedJson: number } {
  const counted = { kept: 0, linkedJson: 0 };
  const all = sql.all.bind(sql);
  sql.all = (q: string, params?: readonly SqlValue[]): SqlRow[] => {
    if (/\bfile_kept\b/.test(q)) counted.kept++;
    if (/\bjson\b/.test(q) && /\bchat\b/.test(q) && (params ?? []).some((p) => typeof p === "string" && /^l[0-9]+$/.test(p))) counted.linkedJson++;
    return all(q, params);
  };
  return counted;
}

async function rig() {
  const t = setup();
  const u = ui();
  t.subscribe(1, chatTopic);
  const now = t.host.nowMs();
  t.set(workspace(), { id: "ws", stations: [{ id: "a", name: "alpha", last_seen: Math.trunc(now / 1000) - 10, version: "0.4.0" }] });
  t.set(threads(ST), [thread(now)]);
  t.set(pageOf, { first: 1, last: FILES + LINKS + 1, entries: entries(), end: true, thread: thread(now) });
  t.set(sessionOf("k"), { session: fullSession("k"), threads: [thread(now)], turns: [] });
  t.set(overview(ST), overviewOf());
  t.set(link(ST), { state: "online" });
  t.set(rows(ST), listed());
  t.set({ topic: "archivedRows", station: ST }, [rowOf(`l${LINKS - 1}`, { thread: 100 + LINKS - 1, title: "归档的", archived: { at: 1, by: "auto" } })]);
  for (let i = 0; i < FILES - 1; i++) t.data.keepFile(ST, "k", `img${i}.png`, "thumb", "image/png", "AAAA");
  await t.read(u, 1);
  const sql = t.host.sqls.get(dbName("s1"))!;
  return { t, u, sql };
}

/// What a message of the chat shows as these tests look at it: its files' pictures kept, the chats it links to.
const drawnOf = (u: J) => u.value.messages.map((m: J) => [m.seq, (m.attachments ?? []).map((f: J) => [f.owner, f.held === true]), (m.chats ?? []).map((c: J) => [c.title, c.thread, c.archived === true])]);

test("a_chat_made_again_while_its_reply_streams_reads_no_file_kept_nor_linked_record_and_draws_its_messages_as_they_were", async () => {
  const { t, u, sql } = await rig();
  // As it is first made: each file's picture as kept, each link titled as its row is, the archived one said so.
  const shown = drawnOf(u);
  assert.deepEqual(shown.slice(0, FILES).map((m: J) => m[1][0]), Array.from({ length: FILES }, (_, i) => ["k", i < FILES - 1]));
  assert.deepEqual(shown.slice(FILES, FILES + LINKS).map((m: J) => m[2][0]), Array.from({ length: LINKS }, (_, i) => (i < LINKS - 1 ? [`链接 ${i}`, 100 + i, false] : ["归档的", 100 + i, true])));
  assert.deepEqual(u.value.opened.map((o: J) => [o.session, o.title, o.mark ?? null]), Array.from({ length: OPENED }, (_, i) => [`o${i}`, `开的 ${i} 现在`, i % 2 === 0 ? "run" : null]));

  // Its reply streams: the chat made again ROUNDS times, nothing it shows of its messages changed.
  const counted = counting(sql);
  const before = { ...work };
  const was = u.value;
  const started = performance.now();
  for (let i = 0; i < ROUNDS; i++) {
    t.set(sessionOf("k"), { session: fullSession("k", { lastActiveAt: 2 + i, turns: i + 1 }), threads: [thread(t.host.nowMs())], turns: [] });
    await t.read(u, 1);
  }
  const took = performance.now() - started;
  const made = workSince(before);
  console.log(`chat-draw: ${made.chats} makes of a chat of ${FILES} files, ${LINKS} links and ${OPENED} chats opened: ${counted.kept} statements of file_kept, ${counted.linkedJson} of linked records, ${(took / ROUNDS).toFixed(2)} ms a make (Node)`);
  assert.equal(made.chats, ROUNDS, "made again each time");
  assert.ok(counted.kept <= 1, `${counted.kept} statements of file_kept (${ROUNDS * FILES * 2} before)`);
  assert.equal(counted.linkedJson, 0, "no linked chat's record read");
  assert.deepEqual(drawnOf(u), shown);
  assert.deepEqual(u.value.messages, was.messages);
  assert.deepEqual(u.value.opened, was.opened);

  // What it is drawn with changing is drawn: a picture kept, a linked chat renamed, an opened one at work.
  t.data.keepFile(ST, "k", `img${FILES - 1}.png`, "poster", "image/jpeg", "BBBB");
  t.set(rows(ST), listed((i) => (i === 0 ? "改名了" : `链接 ${i}`)).map((r) => (r.id === "o1" ? { ...r, agents: [agentOf("o1", { process: "running" })] } : r)));
  t.set(sessionOf("k"), { session: fullSession("k", { lastActiveAt: 99 }), threads: [thread(t.host.nowMs())], turns: [] });
  await t.read(u, 1);
  const now = drawnOf(u);
  assert.deepEqual(now[FILES - 1][1], [["k", true]], "the picture kept since");
  assert.deepEqual(now[FILES][2], [["改名了", 100, false]], "the chat renamed");
  assert.equal(u.value.opened[1].mark, "run", "the chat opened now at work");

  // And what a core started anew on the same records makes of it is what this one made by keeping.
  const fresh = await rig();
  fresh.t.data.keepFile(ST, "k", `img${FILES - 1}.png`, "poster", "image/jpeg", "BBBB");
  fresh.t.set(rows(ST), listed((i) => (i === 0 ? "改名了" : `链接 ${i}`)).map((r) => (r.id === "o1" ? { ...r, agents: [agentOf("o1", { process: "running" })] } : r)));
  fresh.t.set(sessionOf("k"), { session: fullSession("k", { lastActiveAt: 99 }), threads: [thread(fresh.t.host.nowMs())], turns: [] });
  await fresh.t.read(fresh.u, 1);
  assert.deepEqual(fresh.u.value.messages, u.value.messages);
  assert.deepEqual(fresh.u.value.opened, u.value.opened);
  t.store.runner.shutdown();
  fresh.t.store.runner.shutdown();
});

test("what_is_kept_of_a_session_is_known_as_it_is_kept_and_let_go", async () => {
  const { t, sql } = await rig();
  const counted = counting(sql);
  assert.equal(t.data.hasKeptFile(ST, "k", "img0.png", "thumb"), true);
  assert.equal(t.data.hasKeptFile(ST, "k", "img0.png", "poster"), false);
  assert.equal(t.data.hasKeptFile(ST, "k", "new.png", "thumb"), false);
  t.data.keepFile(ST, "k", "new.png", "thumb", "image/png", "CCCC");
  assert.equal(t.data.hasKeptFile(ST, "k", "new.png", "thumb"), true, "known as it is kept");
  assert.equal(t.data.hasKeptFile(ST, "other", "img0.png", "thumb"), false, "another session's are its own");
  t.data.retain((s) => s !== ST, null);
  assert.equal(t.data.hasKeptFile(ST, "k", "img0.png", "thumb"), false, "let go with its station");
  assert.ok(counted.kept <= 4, `${counted.kept} statements of file_kept`);
  t.store.runner.shutdown();
});

test("the_copy_hermes_makes_is_structured_clones", () => {
  const big = { rows: Array.from({ length: 2000 }, (_, i) => ({ id: `r${i}`, n: i, ok: i % 2 === 0, none: null, tags: ["a", "b"], deep: { at: { x: i } } })) };
  assert.deepStrictEqual(cloneOf(big), structuredClone(big));
  assert.notEqual((cloneOf(big) as J).rows[0], big.rows[0]);
  const bare = Object.assign(Object.create(null), { a: 1 });
  assert.deepStrictEqual(cloneOf(bare), structuredClone(bare));
  // Bytes, dates, maps and sets as structuredClone copies them, nested in plain data too.
  const bytes = new Uint8Array([1, 2, 3]).subarray(1);
  const odd = { bytes, at: new Date(5), map: new Map<J, J>([["k", { v: 1 }]]), set: new Set([1, 2]), buf: new ArrayBuffer(4) };
  const copy = cloneOf(odd) as J;
  assert.deepStrictEqual(copy, structuredClone(odd));
  assert.notEqual(copy.bytes, bytes);
  assert.deepEqual([...copy.bytes], [2, 3]);
  assert.notEqual(copy.map.get("k"), odd.map.get("k"));
  // A cycle, and an object met twice, each copied once.
  const cyclic: J = { name: "c", list: [] };
  cyclic.self = cyclic;
  cyclic.list.push(cyclic);
  const c = cloneOf(cyclic) as J;
  assert.equal(c.self, c);
  assert.equal(c.list[0], c);
  assert.notEqual(c, cyclic);
  const shared = { v: 1 };
  const twice = cloneOf({ a: shared, b: [shared], m: new Map([["s", shared]]) }) as J;
  assert.equal(twice.a, twice.m.get("s"), "where it falls back, as structuredClone keeps it");
  // Deeper than the plain copy goes: copied whole all the same.
  let deep: J = { leaf: true };
  for (let i = 0; i < 200; i++) deep = { next: deep };
  assert.deepStrictEqual(cloneOf(deep), structuredClone(deep));
});
