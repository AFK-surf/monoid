// The paths a phone was found slow on (Cloud Trace of android 0.1.10174 and 0.1.10188, 2026-11-18), each held to what
// takes its cost away:
// - a station's link catching up after the network came back (station/sync.ts `#catching`, 14 batches in a minute) made
//   the chat list again whole each time, 168 ms a time: what a link says is said of the stations alone (views.ts
//   #chatsOf), the window not read again and its days the same objects;
// - one chat of one station starting its work read every station's counts again: each station's are read and kept by
//   themselves (chat-reads.ts `counts`);
// - a chat archived on one station counted every station's archive again: each station's archive is counted and kept by
//   itself (chat-reads.ts `archivedCount`);
// - a chat's outline read all of its entries (672 KB, its agents' replies most of them) for its people's few: it reads
//   theirs and their edits alone (account.ts peopleEntries), and makes the outline the whole of them made.
// HOT_PATHS_PRINT=1 prints what each took (bench/hot-paths.ts compares them with a core from before).
import assert from "node:assert/strict";
import { test } from "node:test";
import { merge } from "../src/entries.ts";
import { holdLanguage, t as words } from "../src/i18n.ts";
import { work } from "../src/work.ts";
import { link, rows, setup, ui, workspace } from "./views-rig.ts";

holdLanguage();
// deno-lint-ignore no-explicit-any
type J = any;

const print = process.env.HOT_PATHS_PRINT === "1";
const agent = (key: string, running = false): J => ({ key, connect: "c1", profile: "p1", runtime: "claude", model: "opus", effort: null, process: running ? "running" : "cold", pending: 0, lastTurn: null });
function row(station: string, i: number, at: number, running = false): J {
  const id = `${station.split("/")[1]}-${i}`;
  return { id, session: id, thread: i + 1, title: `${id} 的标题`, agents: [agent(id, running)], last: null, unread: false, mine: false, lastActiveAt: Math.trunc(at), connect: null, origin: null };
}
const workspaceOf = (ids: string[], nowS: number): J => ({ id: "ws", stations: ids.map((id) => ({ id, name: id, last_seen: Math.trunc(nowS), version: "0.4.0" })) });
const LIST = { topic: "chats", scope: "ws" };
const value = (t: ReturnType<typeof setup>, topic: J): J => {
  const v = t.store.value(topic);
  return v !== undefined && "ok" in v ? v.ok : undefined;
};

/// A rig of `ids` stations of `per` chats each, its chat list shown with a window of 30.
async function listed(ids: string[], per: number) {
  const t = setup();
  const u = ui();
  const now = t.host.nowMs();
  t.set(workspace(), workspaceOf(ids, t.nowS()));
  ids.forEach((id, s) => {
    // (the links kept as a page shows them: a topic nothing watches is let go of)
    t.store.watch(link(`ws/${id}`), () => {});
    t.set(link(`ws/${id}`), { state: "online" });
    t.set(rows(`ws/${id}`), Array.from({ length: per }, (_, i) => row(`ws/${id}`, i, now - (i * ids.length + s) * 60_000)));
  });
  t.window(LIST, 30);
  t.subscribe(1, LIST);
  await t.read(u, 1);
  return { t, u, now };
}

/// The statements a declared read of the chat table runs, by its name and station (each AccountDb's `chatCounted`).
function statements(t: ReturnType<typeof setup>, stations: string[]): Map<string, number> {
  const runs = new Map<string, number>();
  for (const st of stations) {
    const db = t.data.of(st) as J;
    const was = db.chatCounted.bind(db);
    // (the databases are one here, the account's: each counted once)
    if (db.__counted) continue;
    db.__counted = true;
    db.chatCounted = (read: J, p: J) => {
      const key = `${read.name} ${p.station ?? (p.stations ?? []).join(",")}`;
      runs.set(key, (runs.get(key) ?? 0) + 1);
      return was(read, p);
    };
  }
  return runs;
}

test("a_links_catching_up_makes_nothing_of_the_chat_list_again_but_what_it_says_of_the_stations", async () => {
  const ids = ["a", "b", "c", "d", "e", "f"];
  const { t, u } = await listed(ids, 60);
  const was = value(t, LIST);
  assert.equal(was.days.flatMap((d: J) => d.items).length, 30);
  assert.ok(was.more > 0);
  const listedWas = work.listed;
  let found = 0;
  const chatFound = t.data.chatFound.bind(t.data);
  t.data.chatFound = ((read: J, p: J, wants?: J) => {
    found++;
    return chatFound(read, p, wants);
  }) as typeof t.data.chatFound;
  const runs = statements(t, ids.map((id) => `ws/${id}`));
  const started = performance.now();
  // Twenty batches of a link catching up, 40 chats behind to none; then another station's link coming back.
  const said: (string | null)[] = [];
  for (let behind = 40; behind >= 0; behind -= 2) {
    t.set(link("ws/a"), { state: "online", catching: behind });
    await t.read(u, 1);
    said.push(value(t, LIST).syncing ?? null);
  }
  t.set(link("ws/b"), { state: "reconnecting", message: "断了" });
  await t.read(u, 1);
  const down = value(t, LIST);
  assert.equal(down.stations.find((s: J) => s.station === "ws/b").state, "connecting");
  t.set(link("ws/b"), { state: "online" });
  await t.read(u, 1);
  const took = performance.now() - started;
  const now = value(t, LIST);
  assert.equal(work.listed - listedWas, 0, "no row made again");
  assert.equal(found, 0, "the window not read again");
  assert.deepEqual([...runs], [], "no statement run");
  assert.equal(now.days, was.days, "its days the same objects");
  assert.equal(down.days, was.days);
  assert.equal(now.more, was.more);
  // What the stations say followed the links: how many are left as they came, none at the end.
  assert.equal(said[0], words("core-views.station.syncing_left", { n: 40 }));
  assert.equal(said[1], words("core-views.station.syncing_left", { n: 38 }));
  assert.equal(said.at(-1), null);
  assert.equal(now.stations.find((s: J) => s.station === "ws/b").state, "online");
  if (print) console.log(`22 changes of links, 6 stations of 60 chats, a window of 30: ${took.toFixed(1)} ms`);
});

test("one_stations_chat_starting_its_work_reads_that_stations_counts_alone", async () => {
  const ids = ["a", "b", "c", "d", "e", "f"];
  const { t, u, now } = await listed(ids, 20);
  const runs = statements(t, ids.map((id) => `ws/${id}`));
  // One chat of station c, below the window, starts its work: its row's state, which the window does not read.
  const st = "ws/c";
  const all = Array.from({ length: 20 }, (_, i) => row(st, i, now - (i * ids.length + 2) * 60_000, i === 19));
  t.set(rows(st), all);
  await t.read(u, 1);
  const counted = [...runs].filter(([k]) => k.startsWith("$chat-counts "));
  assert.deepEqual(counted, [[`$chat-counts ${st}`, 1]], "only its station's counts read again");
  assert.equal([...runs].filter(([k]) => k.startsWith("$chat-window ")).length, 0, "the window not read again");
  assert.equal(value(t, LIST).glyph !== undefined, true);
});

test("one_stations_chat_archived_counts_that_stations_archive_alone", async () => {
  const ids = ["a", "b", "c", "d", "e", "f"];
  const { t, now } = await listed(ids, 4);
  const archivedOf = (id: string, n: number) => Array.from({ length: n }, (_, i) => ({ ...row(`ws/${id}`, 100 + i, now - (i * ids.length + 1) * 60_000), archived: { at: now - i * 60_000, by: "manual" } }));
  for (const id of ids) t.set({ topic: "archivedRows", station: `ws/${id}` }, archivedOf(id, 5));
  const shown = ui();
  const ARCHIVE = { topic: "archive", scope: "ws", limit: 10 };
  t.subscribe(2, ARCHIVE);
  await t.read(shown, 2);
  assert.equal(value(t, ARCHIVE).total, 30);
  const runs = statements(t, ids.map((id) => `ws/${id}`));
  // One chat more archived on station c.
  const st = "ws/c";
  t.set({ topic: "archivedRows", station: st }, archivedOf("c", 6));
  await t.read(shown, 2);
  assert.equal(value(t, ARCHIVE).total, 31);
  const counted = [...runs].filter(([k]) => k.startsWith("$chat-archived-count "));
  assert.deepEqual(counted, [[`$chat-archived-count ${st}`, 1]], "only its station's archive counted again");
});

test("a_chats_outline_reads_its_peoples_messages_and_their_edits_alone_and_is_what_all_of_them_make", async () => {
  const t = setup({ all: true });
  const u = ui();
  const st = "ws/st";
  t.set(workspace(), workspaceOf(["st"], t.nowS()));
  t.set(link(st), { state: "online" });
  const at = Date.UTC(2026, 0, 5, 9, 30);
  const long = `## 改了什么\n\n${"这一段说的是列表为什么跳了一下，以及怎么改的：先量，再改，最后对比前后。".repeat(40)}\n\n\`\`\`ts\nconst x = 1;\n\`\`\``;
  const entries: [number, J][] = [];
  const people: number[] = [];
  for (let n = 1; n <= 500; n++) {
    const person = n % 25 === 1;
    if (person) people.push(n);
    entries.push([n, { thread: 7, n, kind: "message", ts: `${n}.0`, authorKind: person ? "person" : "agent", author: person ? "a@x.com" : "k1", authorName: null, text: person ? `第 ${n} 句` : long, at: at + n * 60_000 }]);
  }
  // Edits of two people's messages and of an agent's.
  const edits: [number, J][] = [
    [501, { thread: 7, n: 501, kind: "edit", target: people[3], ts: "501.0", authorKind: "person", author: "a@x.com", text: "改过的话", at: at + 501 * 60_000 }],
    [502, { thread: 7, n: 502, kind: "edit", target: 2, ts: "502.0", authorKind: "agent", author: "k1", text: long, at: at + 502 * 60_000 }],
    [503, { thread: 7, n: 503, kind: "edit", target: people[5], ts: "503.0", authorKind: "person", author: "a@x.com", text: "又改了", at: at + 503 * 60_000 }],
  ];
  t.data.putItems("entry", st, "7", [...entries, ...edits]);
  // What all of them make (entries.ts merge), its people's.
  const whole = (upTo: number) => merge([...t.data.logRange("entry", st, "7", 1, upTo).values()]).filter((m: J) => m.authorKind === "person");
  const db = t.data.of(st) as J;
  let bytes = 0;
  const all = db.sql.all.bind(db.sql);
  db.sql.all = (q: string, p?: J) => {
    const out = all(q, p);
    for (const r of out) for (const c of r) if (typeof c === "string") bytes += c.length;
    return out;
  };
  const rowsWas = work.logRows;
  const started = performance.now();
  t.subscribe(1, { topic: "chatOutline", station: st, thread: 7 });
  await t.read(u, 1);
  const took = performance.now() - started;
  const read = work.logRows - rowsWas;
  db.sql.all = all;
  assert.equal(read, people.length + 2, "its people's messages and the edits of those read, nothing of the agents'");
  assert.ok(bytes < 8_000, `${bytes} characters read`);
  const seqs = (v: J) => v.days.flatMap((d: J) => d.seqs);
  assert.deepEqual(seqs(u.value), whole(503).map((m: J) => m.seq));
  assert.equal(u.value.count, people.length);
  // What it then holds is what all of them make: as they are, after another edit and a person's message more.
  t.data.putItems("entry", st, "7", [[504, { thread: 7, n: 504, kind: "edit", target: people[0], ts: "504.0", authorKind: "person", author: "a@x.com", text: "第一句改了", at: at + 504 * 60_000 }]]);
  t.data.putItems("entry", st, "7", [[505, { thread: 7, n: 505, kind: "message", ts: "505.0", authorKind: "person", author: "b@x.com", authorName: "Bo", text: "我也说一句", at: at + 505 * 60_000 }]]);
  await t.read(u, 1);
  assert.deepEqual(seqs(u.value), whole(505).map((m: J) => m.seq));
  assert.equal(u.value.count, people.length + 1);
  // And what it reads of them, made as all of them are.
  const peopleNow = t.data.peopleEntries(st, 7, 505);
  const made = merge([...peopleNow.held.keys()].sort((a, b) => a - b).map((n) => peopleNow.held.get(n))).filter((m: J) => m.authorKind === "person");
  assert.deepStrictEqual(made, whole(505));
  const editsAll = new Map<number, number[]>();
  for (const [n, e] of t.data.logRange("entry", st, "7", 1, 505) as Map<number, J>) if (e.kind === "edit") editsAll.set(e.target, [...(editsAll.get(e.target) ?? []), n]);
  assert.deepStrictEqual(peopleNow.edits, editsAll);
  if (print) console.log(`a chat of 505 entries, ${people.length + 1} of its people: its outline first made in ${took.toFixed(1)} ms, ${read} entries and ${bytes} characters read`);
});
