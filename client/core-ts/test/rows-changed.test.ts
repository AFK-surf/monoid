// A station's chat list is made again only where what it is made of changed, written only where it changed, and
// nothing is read back to find out (rows-made.ts RowsMemo, db/account.ts `setChats`): what is stored is what a core
// started anew makes of the same shared list and marks, whatever came before; and what one change of one row makes the
// core do is by its key end to end (sync.ts #made, rows-made.ts OwnHeld, account.ts putChat): nothing else is looked at.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Worker } from "node:worker_threads";
import { worded } from "../src/chat-row.ts";
import { rowWords, sharedPlace } from "../src/station/rows-made.ts";
import type { Topic } from "../src/protocol.ts";
import { CAUSES, held } from "./real-size-asked.ts";
import { type Did, SHARED_KINDS, SHARED_PROBES, SHARED_WHOLE, Station, settled, anySharedChange, differences, madeAnew, madeFromStation, seeded, startedOn, stored } from "./rows-changed-run.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// How many changes of every kind are told, and their seed.
const SHARED_CHANGES = 150;
const SEED = 46;

/// The first place what is stored differs from what is made anew (using independent station ground truth on converged
/// whole/reconnect steps, and in-process viewer marks otherwise), after `what`.
const differ = (s: Parameters<typeof stored>[0], station: Station, what: string, converged = false) =>
  differences(stored(s), converged ? madeFromStation(station) : madeAnew(s, station)).slice(0, 8).map((d) => `after ${what}: ${d}`);

test("a chat list made of the one its station makes for everyone is what a core started anew makes of it, change after change", async () => {
  const station = new Station();
  const s = await startedOn(station);
  try {
    assert.equal(stored(s).length, station.shared.size);
    assert.deepEqual(differ(s, station, "everything was read", true), []);
    const r = seeded(SEED + 1);
    const told = new Map<string, number>();
    // (each kind in turn, in an order of its own each round: every kind, by key and whole, after every other)
    let round: (typeof SHARED_KINDS)[number][] = [];
    for (let i = 0; i < SHARED_CHANGES; i++) {
      if (round.length === 0) round = [...SHARED_KINDS].map((k) => [r(), k] as const).sort((a, b) => a[0] - b[0]).map(([, k]) => k);
      const kind = anySharedChange(station, s, r, round.pop());
      told.set(kind, (told.get(kind) ?? 0) + 1);
      await s.host.time.pass(settled(kind), 100);
      assert.deepEqual(differ(s, station, `change ${i} (${kind})`, SHARED_WHOLE.has(kind)), []);
    }
    // (every kind told, more than once: those by key between the whole reads)
    assert.ok([...told.values()].every((n) => n > 1) && told.size === new Set(SHARED_KINDS).size, JSON.stringify(Object.fromEntries(told)));
  } finally {
    s.core.close();
  }
});

test("a chat list written as given is what was given, after each change of the real-size workspace", async () => {
  const h = await held();
  try {
    const words = rowWords();
    // What each station's lists were last given (its rows in this device's words, each id once), as a core started anew
    // with nothing held would write them: a list given whole, and each row told since by its key (as the sync writes a
    // list its station makes, real-size-asked.ts `rowsTold`); the rows of a list written at their places in those places
    // (rows-made.ts `sharedPlace`, then by id), the others in the order given.
    const given = new Map<string, { rows: Map<string, J>; placed: boolean }>();
    const asGiven = (rows: Iterable<J>) =>
      [...rows].map((r) => {
        const { unread, ...rest } = worded(r, words);
        return { id: r.id, json: JSON.stringify(rest), unread: typeof unread === "boolean" ? (unread ? 1 : 0) : null };
      });
    const whole = (key: string, rows: J[], placed: boolean) => {
      const byId = new Map<string, J>();
      for (const r of rows) if (!byId.has(r.id)) byId.set(r.id, r);
      given.set(key, { rows: byId, placed });
    };
    const keyOf = (station: string, archived: boolean) => `${station} ${archived ? 1 : 0}`;
    const set = h.t.set;
    h.t.set = (topic: Topic, value: unknown) => {
      if (topic.topic === "chatRows" || topic.topic === "archivedRows") whole(keyOf(String(topic.station), topic.topic === "archivedRows"), value as J[], false);
      set(topic, value);
    };
    const data = h.t.data;
    const { setChatsAt, putChat, dropChat, putSharedBatch, applySharedChanged } = data;
    data.setChatsAt = (station, rows, places) => {
      whole(keyOf(station, false), rows as J[], true);
      setChatsAt.call(data, station, rows, places);
    };
    data.putChat = (station, row, place) => {
      given.get(keyOf(station, false))?.rows.set((row as J).id, row);
      putChat.call(data, station, row, place);
    };
    data.dropChat = (station, id) => {
      given.get(keyOf(station, false))?.rows.delete(id);
      dropChat.call(data, station, id);
    };
    data.putSharedBatch = (station, updates, drops, markUpdates, scopedMarks) => {
      const m = given.get(keyOf(station, false))?.rows;
      for (const u of updates) m?.set((u.row as J).id, u.row);
      for (const id of drops) m?.delete(id);
      putSharedBatch.call(data, station, updates, drops, markUpdates, scopedMarks);
    };
    data.applySharedChanged = (station, changed, gone, reprojectAll, reproject, newMarks, meta, extraReproject) => {
      const m = given.get(keyOf(station, false))?.rows;
      for (const id of gone) m?.delete(id);
      for (const item of changed) m?.set((item.row as J).id, item.row);
      applySharedChanged.call(data, station, changed, gone, reprojectAll, reproject, newMarks, meta, extraReproject);
    };
    // (as the rig was made: the fixture's)
    const { fixture } = await import("./real-size.ts");
    for (const [topic, value] of fixture(h.base, h.chat)) if (topic.topic === "chatRows" || topic.topic === "archivedRows") whole(keyOf(String(topic.station), topic.topic === "archivedRows"), value as J[], topic.topic === "chatRows");
    const id = (r: J) => String(r.id);
    const inOrder = ({ rows, placed }: { rows: Map<string, J>; placed: boolean }) =>
      asGiven(placed ? [...rows.values()].sort((a, b) => sharedPlace(a) - sharedPlace(b) || (id(a) < id(b) ? -1 : id(a) > id(b) ? 1 : 0)) : rows.values());
    const check = (what: string) => {
      for (const [key, list] of given) {
        const [station, archived] = key.split(" ");
        const now = h.t.data.of(station!)!.sql.all("SELECT id, json, unread FROM chat WHERE station = ? AND archived = ? ORDER BY ord, id", [station!, Number(archived)])
          .map((r) => ({ id: String(r[0]), json: String(r[1]), unread: r[2] as number | null }));
        assert.deepEqual(differences(now, inOrder(list)).slice(0, 8), [], `${station}'s ${archived === "1" ? "archived" : "listed"} chats after ${what}`);
      }
    };
    check("the workspace was set");
    for (const [cause, c] of Object.entries(CAUSES)) {
      c.run(h);
      await h.t.host.time.pass(c.ms ?? 1000, 100);
      check(cause);
    }
  } finally {
    h.t.store.runner.shutdown();
  }
});

/// Each probe measured at a size, in a worker of its own (real-size.ts reads its size as it loads).
function probedAt(realSize: Record<string, number>): Promise<{ chats: number; did: Record<string, Did>; differ: string[] }> {
  return inWorker(realSize, {});
}

/// rows-changed-run.ts at a size, in a worker of its own, as `what` says.
function inWorker<T>(realSize: Record<string, number>, what: Record<string, unknown>): Promise<T> {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL("./rows-changed-run.ts", import.meta.url), { workerData: { rowsChanged: true, realSize, ...what } });
    w.once("message", (m) => {
      void w.terminate();
      if ((m as { error?: string }).error !== undefined) reject(new Error((m as { error: string }).error));
      else resolve(m);
    });
    w.once("error", reject);
  });
}

/// What a probe did, as a line of a table.
const line = (d: Did) => `made ${d.made} serialised ${d.serialised} json ${d.chatJson} glanced ${JSON.stringify(Object.fromEntries(Object.entries(d.glanced).filter(([, n]) => n !== 0)))}`;

/// The most rows one change of one chat makes again: its own row, once for each step of the change that changes it, two
/// at most. Each of the fixture's agents is in one chat, so no row shares a member with it, and none other is made.
const MOST_MADE = 2;
/// The rows a change writes itself besides those made again: a read finds its chat's row by its thread and writes it
/// read (account.ts #readRows). What is read of the chats' JSON is at most what is serialised: a row given that is not
/// the one written before is read by its key to be compared, the others not at all.
const WRITTEN_ALSO: Record<string, number> = { read: 1 };

test("what one change of a row of the list its station makes makes the core do is that row's, and nothing else is looked at", async () => {
  const [one, three] = await Promise.all([probedAt({}), probedAt({ chats: 3 })]);
  assert.ok(three.chats >= 2.5 * one.chats, `three times the chats: ${one.chats} → ${three.chats}`);
  console.log(`What each change of a station that makes its list made the core do, at ${one.chats} and ${three.chats} chats:\n${Object.keys(SHARED_PROBES).map((n) => `  ${n.padEnd(14)} ${line(one.did[n]!)}  |  ${line(three.did[n]!)}`).join("\n")}`);
  assert.deepEqual(one.differ, []);
  assert.deepEqual(three.differ, []);
  for (const name of Object.keys(SHARED_PROBES)) {
    if (SHARED_WHOLE.has(name)) continue;
    const [a, b] = [one.did[name]!, three.did[name]!];
    assert.ok(a.made <= MOST_MADE, `${name}: made ${a.made} rows`);
    assert.ok(a.serialised <= a.made + (WRITTEN_ALSO[name] ?? 0), `${name}: serialised ${a.serialised}, more than the ${a.made} made`);
    assert.ok(a.chatJson <= a.serialised, `${name}: read ${a.chatJson} chats' JSON, more than the ${a.serialised} serialised`);
    assert.deepEqual(Object.entries(a.glanced).filter(([, n]) => n !== 0), [], `${name}: looked at nothing but its row`);
    assert.deepEqual(b, a, `${name} with three times the chats`);
  }
});

test("a list held in the places of before takes its places of each row once, each a write of its place alone", async () => {
  type Moved = { chats: number; put: number; placed: number; keptBefore: number; keptAfter: number; chatJson: number; differ: string[] };
  const [one, three] = await Promise.all([inWorker<Moved>({}, { moved: true }), inWorker<Moved>({ chats: 3 }, { moved: true })]);
  console.log(`A list in the places of before, written whole once: ${JSON.stringify(one)} | ${JSON.stringify(three)}`);
  for (const m of [one, three]) {
    assert.deepEqual(m.differ, [], "every row where sharedPlace puts it, as made anew");
    assert.equal(m.put, 0, "no record put again");
    // (the rows kept beside them go as their places are written, as at any update of their records, and are made again
    // as they are read: said, not held)
    console.log(`  ${m.chats} chats: ${m.placed} places written, ${m.keptBefore - m.keptAfter} of ${m.keptBefore} kept rows went`);
    assert.ok(m.chatJson <= m.chats, `the list's JSON read at most once: ${m.chatJson} rows for ${m.chats}`);
    assert.ok(m.placed <= m.chats, `a place written a row at most: ${m.placed}`);
  }
  assert.ok(one.placed > 0, "the places of before moved");
  assert.ok(three.placed <= 3 * one.placed + 3, `only the rows moved grow with the chats: ${one.placed} → ${three.placed}`);
});

test("a cold restart with baseline and one changed row reconciles via POST /changed/shared in O(1)", async () => {
  type ColdDelta = {
    chats: number;
    changedSharedCalls: number;
    wholeSharedCalls: number;
    marksOwnCalls: number;
    made: number;
    serialised: number;
    put: number;
    chatJson: number;
    glanced: Record<string, number>;
    differ: string[];
  };
  const [one, three] = await Promise.all([inWorker<ColdDelta>({}, { coldDelta: true }), inWorker<ColdDelta>({ chats: 3 }, { coldDelta: true })]);
  console.log(`Cold restart with baseline and 1 changed row: ${JSON.stringify(one)} | ${JSON.stringify(three)}`);
  assert.ok(three.chats >= 2.5 * one.chats, `three times the chats: ${one.chats} → ${three.chats}`);
  for (const m of [one, three]) {
    assert.deepEqual(m.differ, [], "converged to independent station ground truth");
    assert.equal(m.changedSharedCalls, 1, "POST /changed/shared called once");
    assert.equal(m.wholeSharedCalls, 0, "GET /chats?shared=1 not called");
    assert.equal(m.marksOwnCalls, 1, "GET /chats?marks=1&own=1 called once");
    assert.equal(m.made, 1, "only the 1 changed row was projected");
    assert.equal(m.serialised, 1, "only the 1 changed row was serialised");
    assert.equal(m.put, 1, "only the 1 changed row was written to SQLite chat table");
    assert.ok(m.chatJson <= 1, `at most 1 chat json read, got ${m.chatJson}`);
    assert.equal(m.glanced.chatRowsWalked ?? 0, 0, "no full chat list walk");
    assert.equal(m.glanced.chatRowsMapped ?? 0, 0, "no full chat list map");
    assert.equal(m.glanced.chatRowsSame ?? 0, 0, "no full chat list equality scan");
    assert.equal(m.glanced.chatRowsWorded ?? 0, 1, "only the 1 changed row was worded");
  }
  const budget = (m: ColdDelta) => ({
    changedSharedCalls: m.changedSharedCalls,
    wholeSharedCalls: m.wholeSharedCalls,
    marksOwnCalls: m.marksOwnCalls,
    made: m.made,
    serialised: m.serialised,
    put: m.put,
    chatJson: m.chatJson,
    chatRowsWalked: m.glanced.chatRowsWalked ?? 0,
    chatRowsMapped: m.glanced.chatRowsMapped ?? 0,
    chatRowsWorded: m.glanced.chatRowsWorded ?? 0,
  });
  assert.deepEqual(budget(three), budget(one), "O(1) cold-start 1-row delta budget independent of total chats");
});
