// What making a chat again costs while its agent is working, on the parts that were most of it on a phone (0.1.10103 and
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

/// Statements counted as they run on the account's database: those of `file_kept`, those reading a linked chat's
/// record (its JSON), and those of `chat` finding or reading the chats it opened (asked by their ids, alone or in JSON).
function counting(sql: NodeSql): { kept: number; linkedJson: number; openedSql: number } {
  const counted = { kept: 0, linkedJson: 0, openedSql: 0 };
  const all = sql.all.bind(sql);
  sql.all = (q: string, params?: readonly SqlValue[]): SqlRow[] => {
    if (/\bfile_kept\b/.test(q)) counted.kept++;
    if (/\bjson\b/.test(q) && /\bchat\b/.test(q) && (params ?? []).some((p) => typeof p === "string" && /^l[0-9]+$/.test(p))) counted.linkedJson++;
    if (/\bchat\b/.test(q) && (params ?? []).some((p) => typeof p === "string" && /(^|")o[0-9]+("|$)/.test(p))) counted.openedSql++;
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

test("a_chat_made_again_while_its_agent_works_reads_no_file_kept_nor_linked_record_and_draws_its_messages_as_they_were", async () => {
  const { t, u, sql } = await rig();
  // As it is first made: each file's picture as kept, each link titled as its row is, the archived one said so.
  const shown = drawnOf(u);
  assert.deepEqual(shown.slice(0, FILES).map((m: J) => m[1][0]), Array.from({ length: FILES }, (_, i) => ["k", i < FILES - 1]));
  assert.deepEqual(shown.slice(FILES, FILES + LINKS).map((m: J) => m[2][0]), Array.from({ length: LINKS }, (_, i) => (i < LINKS - 1 ? [`链接 ${i}`, 100 + i, false] : ["归档的", 100 + i, true])));
  assert.deepEqual(
    u.value.opened.map((o: J) => [o.session, o.title, o.mark ?? null]),
    [
      ...Array.from({ length: OPENED / 2 }, (_, k) => OPENED - 2 - k * 2).map((i) => [`o${i}`, `开的 ${i} 现在`, "run"]),
      ...Array.from({ length: OPENED / 2 }, (_, k) => OPENED - 1 - k * 2).map((i) => [`o${i}`, `开的 ${i} 现在`, null]),
    ],
  );

  // While its agent is working: the chat made again ROUNDS times, nothing it shows of its messages changed.
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
  console.log(`chat-draw: ${made.chats} makes of a chat of ${FILES} files, ${LINKS} links and ${OPENED} chats opened: ${counted.kept} statements of file_kept, ${counted.linkedJson} of linked records, ${counted.openedSql} of opened chats, ${(took / ROUNDS).toFixed(2)} ms a make (Node)`);
  assert.equal(made.chats, ROUNDS, "made again each time");
  assert.ok(counted.kept <= 1, `${counted.kept} statements of file_kept (${ROUNDS * FILES * 2} before)`);
  assert.equal(counted.linkedJson, 0, "no linked chat's record read");
  assert.equal(counted.openedSql, 0, "no chat it opened found or read again");
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
  assert.equal(u.value.opened.find((o: J) => o.session === "o1")?.mark, "run", "the chat opened now at work");

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

const MANY = 150;
const STB = "ws/b";

/// A chat that leads MANY chats it opened, of every way one is found (`i % 10`): 0 listed by its id; 1 archived alone;
/// 2 listed by its session (another id); 3 on another station (a chat of the same id on this one not it); 4 listed and
/// archived by one id (the listed one it); 5 none (titled as it was given); 6 listed by its id and another by its session
/// placed first (the one of its id it); 7 archived by its id and listed by its session (the listed one it); 8 and 9 two
/// listed by its session, the first placed of them it (8: the later id placed first; 9: the earlier, by `ord` again
/// when their places are made one, the earlier id then).
function many(): { a: J[]; archived: J[]; b: J[]; opened: J[]; want: Map<string, { title: string; archived: boolean }> } {
  const opened: J[] = [];
  const a: J[] = [];
  const archived: J[] = [];
  const b: J[] = [];
  const want = new Map<string, { title: string; archived: boolean }>();
  const arch = { at: 1, by: "auto" };
  for (let i = 0; i < MANY; i++) {
    const s = `o${i}`;
    const k = i % 10;
    opened.push({ session: s, title: `给的 ${i}`, ...(k === 3 ? { station: "b" } : {}) });
    if (k === 0) a.push(rowOf(s, { title: `活 ${i}` }));
    if (k === 1) archived.push(rowOf(s, { title: `归 ${i}`, archived: arch }));
    if (k === 2) a.push(rowOf(`c${i}`, { session: s, title: `会 ${i}` }));
    if (k === 3) {
      b.push(rowOf(s, { title: `乙 ${i}` }));
      a.push(rowOf(s, { title: `错 ${i}` }));
    }
    if (k === 4) {
      a.push(rowOf(s, { title: `新 ${i}` }));
      archived.push(rowOf(s, { title: `旧 ${i}`, archived: arch }));
    }
    if (k === 6) {
      a.push(rowOf(`d${i}`, { session: s, title: `次 ${i}` }));
      a.push(rowOf(s, { title: `本 ${i}` }));
    }
    if (k === 7) {
      archived.push(rowOf(s, { title: `档 ${i}`, archived: arch }));
      a.push(rowOf(`e${i}`, { session: s, title: `活会 ${i}` }));
    }
    if (k === 8) {
      a.push(rowOf(`h${i}`, { session: s, title: `先 ${i}` }));
      a.push(rowOf(`g${i}`, { session: s, title: `后 ${i}` }));
    }
    if (k === 9) {
      a.push(rowOf(`g${i}`, { session: s, title: `前 ${i}` }));
      a.push(rowOf(`h${i}`, { session: s, title: `末 ${i}` }));
    }
    const title = [`活 ${i}`, `归 ${i}`, `会 ${i}`, `乙 ${i}`, `新 ${i}`, `给的 ${i}`, `本 ${i}`, `活会 ${i}`, `先 ${i}`, `前 ${i}`][k];
    want.set(`${k === 3 ? STB : ST}\u0001${s}`, { title, archived: k === 1 });
  }
  return { a: [rowOf("k", { thread: 7, title: "领头的", opened }), ...a], archived, b, opened, want };
}

test("opening_a_chat_with_many_opened_subchats_batches_sql_and_preserves_precedence", async () => {
  // Written by one core, then the chat opened on a core started anew on the same database: none of its opened chats
  // found yet, the archived and the other station's records not held.
  const w = setup();
  const now = w.host.nowMs();
  const m = many();
  w.set(workspace(), { id: "ws", stations: [{ id: "a", name: "alpha", last_seen: Math.trunc(now / 1000) - 10, version: "0.4.0" }, { id: "b", name: "beta", last_seen: Math.trunc(now / 1000) - 10, version: "0.4.0" }] });
  w.set(threads(ST), [thread(now)]);
  w.set(pageOf, { first: 1, last: 1, entries: [entry(1, "好了")], end: true, thread: thread(now) });
  w.set(sessionOf("k"), { session: fullSession("k"), threads: [thread(now)], turns: [] });
  for (const st of [ST, STB]) w.set(overview(st), overviewOf());
  w.set(rows(ST), m.a);
  w.set({ topic: "archivedRows", station: ST }, m.archived);
  w.set(rows(STB), m.b);
  await w.host.time.pass(100);

  const t = setup({ host: w.host });
  const sql = t.host.sqls.get(dbName("s1"))!;
  const u = ui();
  t.subscribe(1, chatTopic);
  // (what the chat reads given again, as its station's list is loaded where it is shown: this station's listed rows
  // written anew, the archived and the other station's read of the database)
  t.set(workspace(), { id: "ws", stations: [{ id: "a", name: "alpha", last_seen: Math.trunc(now / 1000) - 10, version: "0.4.0" }, { id: "b", name: "beta", last_seen: Math.trunc(now / 1000) - 10, version: "0.4.0" }] });
  t.set(threads(ST), [thread(now)]);
  t.set(pageOf, { first: 1, last: 1, entries: [entry(1, "好了")], end: true, thread: thread(now) });
  t.set(sessionOf("k"), { session: fullSession("k"), threads: [thread(now)], turns: [] });
  t.set(rows(ST), m.a);
  for (const st of [ST, STB]) {
    t.set(overview(st), overviewOf());
    t.set(link(st), { state: "online" });
  }
  const counted = counting(sql);
  const opening = performance.now();
  await t.read(u, 1);
  const openMs = performance.now() - opening;
  assert.ok(u.value !== undefined, "the chat shown");
  const cold = counted.openedSql;
  const opened: J[] = u.value.opened;
  console.log(`chat-opened: ${MANY} chats opened found and read cold in ${cold} statements of chat (${MANY * 2} one by one), opened in ${openMs.toFixed(1)} ms (Node)`);
  assert.ok(cold <= 3, `${cold} statements of chat for ${MANY} chats opened`);
  assert.equal(opened.length, MANY);
  for (const o of opened) {
    const want = m.want.get(`${o.station}\u0001${o.session}`);
    assert.deepEqual([o.session, o.title, o.archived === true], [o.session, want?.title, want?.archived], `${o.station} ${o.session}`);
  }
  // Each as one asked alone finds it (CHAT_READS.named), the listed before the archived in the list's order.
  for (const o of opened) {
    const one = t.data.chatNamed(o.station, o.session);
    assert.equal((one?.row as J | undefined)?.title ?? `给的 ${o.session.slice(1)}`, o.title, `${o.station} ${o.session} asked alone`);
    assert.equal(one?.archived === true, o.archived === true);
  }
  const firstArchived = opened.findIndex((o) => o.archived === true);
  assert.ok(firstArchived > 0 && opened.slice(firstArchived).every((o) => o.archived === true), "the archived last");

  // Made again as its agent works: none of them found or read again.
  const before = counted.openedSql;
  const was = u.value.opened;
  const making = performance.now();
  for (let i = 0; i < ROUNDS; i++) {
    t.set(sessionOf("k"), { session: fullSession("k", { lastActiveAt: 2 + i, turns: i + 1 }), threads: [thread(t.host.nowMs())], turns: [] });
    await t.read(u, 1);
  }
  console.log(`chat-opened: ${ROUNDS} makes again, ${counted.openedSql - before} statements of chat for the chats opened, ${((performance.now() - making) / ROUNDS).toFixed(2)} ms a make (Node)`);
  assert.equal(counted.openedSql - before, 0, "no chat it opened found or read again");
  assert.deepEqual(u.value.opened, was);

  // One renamed, one archived, one archived back: each shown so.
  const archivedNow = m.archived.filter((r) => r.id !== "o1");
  const listedNow = [...m.a.map((r) => (r.id === "o0" ? { ...r, title: "改了" } : r.id === "o10" ? null : r)).filter((r) => r !== null), rowOf("o1", { title: "回来了" })];
  t.set(rows(ST), listedNow);
  t.set({ topic: "archivedRows", station: ST }, [...archivedNow, rowOf("o10", { title: "活 10", archived: { at: 2, by: "auto" } })]);
  await t.read(u, 1);
  const of = (s: string) => (u.value.opened as J[]).find((o) => o.station === ST && o.session === s);
  assert.equal(of("o0")?.title, "改了");
  assert.deepEqual([of("o10")?.title, of("o10")?.archived], ["活 10", true]);
  assert.deepEqual([of("o1")?.title, of("o1")?.archived ?? false], ["回来了", false]);
  // Each chosen as SQLite orders them (CHAT_READS.named) also where two are placed alike: the earlier id. (Read with no
  // computed, so both statements run anew on the rows as they are.)
  const tied = Array.from({ length: MANY }, (_, i) => i).filter((i) => i % 10 >= 8);
  for (const i of tied) sql.run("UPDATE chat SET ord = (SELECT ord FROM chat WHERE station = ? AND archived = 0 AND id = ?) WHERE station = ? AND archived = 0 AND id = ?", [ST, `h${i}`, ST, `g${i}`]);
  const pairs = Array.from({ length: MANY }, (_, i) => [i % 10 === 3 ? STB : ST, `o${i}`] as const);
  const batched = t.data.chatNamedMany(pairs);
  for (const [st, s] of pairs) {
    const one = t.data.chatNamed(st, s);
    const many = batched.get(`${st}\u0001${s}`);
    assert.deepEqual([(many?.row as J | undefined)?.title, many?.archived], [(one?.row as J | undefined)?.title, one?.archived], `${st} ${s} with places alike`);
  }
  for (const i of tied) assert.equal((batched.get(`${ST}\u0001o${i}`)?.row as J | undefined)?.title, i % 10 === 8 ? `后 ${i}` : `前 ${i}`, `o${i}: the earlier id where placed alike`);
  t.store.runner.shutdown();
  w.store.runner.shutdown();
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
