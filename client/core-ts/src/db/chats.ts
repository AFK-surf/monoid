// Chat rows, declared indexed reads, head/count queries, and moved-chat tracking (account.ts).
import type { SqlRow, SqlValue } from "../host.ts";
import { glanced, work } from "../work.ts";
import { CHAT_READS, rowColumns, type ChatRead } from "./chat-reads.ts";
import {
  type ChatCols,
  type ChatFound,
  type DbEnv,
  type HeadRow,
  type HeldChat,
  type J,
  K,
  type MovedTo,
  PUT_CHAT,
  TOPIC_OF,
  foundOf,
  frozen,
  get,
  idText,
  num,
  placesFor,
  str,
  u64,
} from "./collection.ts";
import type { SharedSidecar } from "../chat-row.ts";
import { KEPT } from "./kept.ts";
import { type SchemaSnapshot, ensureMoved, ensureSharedSidecar } from "./schema.ts";

/// Per-station identity, language, mark-capability, and verified build no-route metadata paired with `shared_sidecar`.
export type SharedMeta = { me: string; selves: string[]; lang: string; hiddenKnown: boolean; mutedKnown: boolean; noRouteBuild: string | null };
/// Keyed viewer marks persisted beside `shared_sidecar` (`shared_mark`).
export type SharedMarksSnapshot = {
  reads: ReadonlyMap<number, number>;
  pins: ReadonlyMap<string, number>;
  kept: ReadonlySet<number>;
  hidden?: ReadonlySet<number>;
  muted?: ReadonlySet<number>;
  dismissed: ReadonlySet<string>;
};
export type SharedMarkKind = "read" | "pin" | "kept" | "hidden" | "muted" | "dismissed";

/// The most rows of a list given that `setChats` compares with what is written by reading them by their keys: more,
/// and it reads the list once.
const CHATS_COMPARED_BY_KEY = 8;

export class ChatsStore {
  readonly #env: DbEnv;
  readonly #summaryOf: (station: string, key: string) => J;
  /// Each station's chat list (`chats`, `archived`) as it was last written, by K(list, station), each row by its id
  /// (HeldChat): the row object given and its place, nothing that grows with the row (its JSON would be the list again
  /// in memory, for every station the sync touches, the whole run, to save a read that is seldom needed). So `setChats`
  /// takes a row given that is the one written before (the same object, frozen) at the same place as written, reading
  /// nothing; the few others are read by their keys to be compared, many the list once. Kept true by every write of
  /// the table here (#putChatRow, #deleteChatRow), let go where it could not be (a burst rolled back, a station
  /// forgotten): then the next `setChats` reads the list once.
  readonly #chatsHeld = new Map<string, Map<string, HeldChat>>();
  /// Where each station said a chat of its went (schema.ts ensureMoved), by station and session; and by that station's
  /// thread, its session. Read whole as the database opens: a row a chat handed over, a few thousand once a whole
  /// station moved.
  readonly #moved = new Map<string, Map<string, MovedTo>>();
  readonly #movedThreads = new Map<string, Map<number, string>>();
  #movedMade = false;
  #sharedSidecarMade = false;

  constructor(env: DbEnv, summaryOf: (station: string, key: string) => J) {
    this.#env = env;
    this.#summaryOf = summaryOf;
  }

  openMoved(snapshot?: SchemaSnapshot): void {
    try {
      ensureMoved(this.#env.sql, snapshot);
      this.#movedMade = true;
    } catch {
      // No room to make it: where chats went is known only while this core runs.
      return;
    }
    for (const r of this.#env.sql.all("SELECT station, session, there_station, thread, there, at, came FROM moved")) {
      this.#movedSet(String(r[0]), String(r[1]), { station: String(r[2]), thread: u64(r[3]), there: u64(r[4]), at: num(r[5]), ...(r[6] === 1 ? { came: true as const } : {}) });
    }
  }

  openSharedSidecar(snapshot?: SchemaSnapshot): void {
    try {
      ensureSharedSidecar(this.#env.sql, snapshot);
      this.#sharedSidecarMade = true;
    } catch {
      // No room to make it: shared chats fall back to whole reads.
    }
  }

  onRollback(): void {
    this.#chatsHeld.clear();
  }

  forgetStation(station: string): void {
    for (const list of ["chats", "archived"] as const) this.#chatsHeld.delete(K(list, station));
    if (this.#sharedSidecarMade) {
      this.#env.run("DELETE FROM shared_sidecar WHERE station = ?", [station]);
      this.#env.run("DELETE FROM shared_meta WHERE station = ?", [station]);
      this.#env.run("DELETE FROM shared_mark WHERE station = ?", [station]);
    }
  }

  /// Chat rows a query found (`found`: station, id), `archived` or not, in its order (account.ts #byKey); `all` the
  /// query again with their JSON (station, id, json, unread).
  chatRowsFound(found: SqlRow[], archived: number, all: () => SqlRow[]): (J | undefined)[] {
    const key = (r: SqlRow) => K("chat", String(r[0]), archived, String(r[1]));
    return this.#env.byKey(
      found.map((r) => [key(r), [r[0], r[1]]]),
      all,
      (keys) => this.#env.sql.all("SELECT c.station, c.id, c.json, c.unread FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = json_extract(k.value, '$[0]') AND c.archived = ? AND c.id = json_extract(k.value, '$[1]')", [keys, archived]),
      key,
      (r) => this.#chatRow(String(r[0]), archived, String(r[1]), r[2], r[3]),
    );
  }

  #chatRow(station: string, archived: number, id: string, json: SqlValue, unread: SqlValue): J {
    return this.#env.cached(K("chat", station, archived, id), json, (row) => {
      if (unread !== null && unread !== undefined) row.unread = unread === 1;
      return row;
    });
  }

  #chatCols(row: J): ChatCols {
    work.chatRowsSerialised++;
    const rest = { ...row };
    const unread = typeof rest.unread === "boolean" ? (rest.unread ? 1 : 0) : null;
    delete rest.unread;
    let running = 0;
    for (const a of Array.isArray(row.agents) ? row.agents : []) if (get(a, "process") === "running") running = 1;
    // (the columns the declared reads are told by as chat-reads.ts rowColumns says them: one rule)
    const c = rowColumns(row);
    return {
      json: JSON.stringify(rest),
      unread,
      thread: c.thread,
      session: c.session,
      clientKey: c.clientKey,
      lastActive: c.lastActive,
      pinnedAt: c.pinnedAt,
      mine: c.mine ? 1 : 0,
      running,
      tone: this.#env.derive.tone(row),
      asks: this.#env.derive.asks(row) ? 1 : 0,
      state: this.#env.derive.state(row),
      watched: this.#env.derive.watched(row) ? 1 : 0,
    };
  }

  /// (`c`: its columns, where they were made already)
  #putChatRow(station: string, archived: number, id: string, row: J, ord: number, before: J | undefined, ordBefore: number | undefined, c: ChatCols = this.#chatCols(row)): void {
    // (asked before the record is put: its triggers take the row kept beside it)
    const beside = this.#env.kept.writing("chat", [station, id]);
    this.#env.run(PUT_CHAT, [station, id, archived, ord, c.thread, c.session, c.clientKey, c.lastActive, c.pinnedAt, c.unread, c.mine, c.running, c.tone, c.asks, c.state, c.watched, c.json]);
    this.#chatsHeld.get(K(archived ? "archived" : "chats", station))?.set(id, { row, ord });
    const kept = frozen(JSON.parse(JSON.stringify(row)));
    this.#env.cache.set(K("chat", station, archived, id), kept);
    // (its row kept beside it went with it, by the triggers: made again of it, where it is listed)
    this.#env.kept.wrote(beside, () => (archived ? undefined : kept));
    this.#env.loadedList(station, archived ? "archived" : "chats")?.set(id, kept, [ord]);
    this.#env.tellChatRead(station, archived, id, before, kept, before === undefined ? undefined : ordBefore, ord);
    if (!archived) this.#came(station, row, c, before === undefined || (c.thread !== null && u64(get(before, "thread")) === null));
    if (!archived) this.#env.tellChat(station, id, before, kept);
    this.#env.tell({ topic: archived ? "archivedRows" : "chatRows", station });
  }

  /// A row whose record is as written, at another place alone (a list whose places are of each row, setChats `places`,
  /// given where its rows were placed otherwise, once): its place written by its key, the record not put again, nothing
  /// serialised or parsed (schema.ts chatTriggers are not of `ord`; the row kept beside it goes, as at any update of its
  /// record, db/kept.ts, made again as it is read). The reads that order by place told of it (chatKeys before and after),
  /// the list held here put in its order. Not the list's revision (rowsRev, setChats `changed`): what waits on it is a
  /// change made here waiting for the station's rows to say it (views/local.ts `settle`), which no place says.
  #placeChatRow(station: string, archived: number, id: string, row: J, record: J, ord: number, ordBefore: number): void {
    const list = archived ? "archived" : "chats";
    this.#env.run("UPDATE chat SET ord = ? WHERE station = ? AND archived = ? AND id = ?", [ord, station, archived, id]);
    this.#chatsHeld.get(K(list, station))?.set(id, { row, ord });
    const loaded = this.#env.loadedList(station, list);
    if (loaded !== undefined) {
      loaded.set(id, loaded.items.get(id) ?? record, [ord]);
      this.#env.tell({ topic: TOPIC_OF[list], station });
    }
    this.#env.tellChatRead(station, archived, id, record, record, ordBefore, ord);
  }

  /// A station's chat list as read: rows that changed are written, those gone deleted, the list read. What was written
  /// before is held (#chatsHeld): only what must be compared is read. `places`: each row's place, where the list says
  /// them of each row (one its station makes, rows-made.ts `sharedPlace`), else they are found from those written
  /// (placesFor). A list written in other places takes those given at this write, once.
  setChats(station: string, archived: boolean, rows: J[], confirmed: number | null, places?: readonly number[]): void {
    this.#env.write(() => {
      const a = archived ? 1 : 0;
      const list = archived ? "archived" : "chats";
      const items: [string, J][] = [];
      const given: number[] = [];
      const seen = new Set<string>();
      glanced.chatRowsWalked += rows.length;
      rows.forEach((row, i) => {
        const id = idText(get(row, "id"));
        // (one the station said went elsewhere: not listed of it, its rows gone as gone ones go)
        if (id === null || seen.has(id) || this.#movedAway(station, row)) return;
        seen.add(id);
        items.push([id, row]);
        if (places !== undefined) given.push(places[i]!);
      });
      let held = this.#chatsHeld.get(K(list, station));
      // (the row written, frozen: it cannot have changed since)
      const asHeld = (id: string, row: J) => held?.get(id)?.row === row && Object.isFrozen(row);
      // What is written of those to compare and those gone (id, ord, json, unread): by their keys where they are few,
      // else the list.
      const stored = new Map<string, SqlRow>();
      const unsure = held === undefined ? [] : [...items.filter(([id, row]) => !asHeld(id, row)).map(([id]) => id), ...[...held.keys()].filter((id) => !seen.has(id))];
      if (held === undefined || unsure.length > CHATS_COMPARED_BY_KEY) {
        for (const r of this.#env.sql.all("SELECT id, ord, json, unread FROM chat WHERE station = ? AND archived = ?", [station, a])) stored.set(String(r[0]), r);
        const was = held;
        held = new Map([...stored].map(([id, r]) => [id, { row: was?.get(id)?.row ?? null, ord: r[1] as number }]));
        this.#chatsHeld.set(K(list, station), held);
      } else if (unsure.length > 0) {
        for (const r of this.#env.sql.all("SELECT c.id, c.ord, c.json, c.unread FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = ? AND c.archived = ? AND c.id = k.value", [JSON.stringify(unsure), station, a])) stored.set(String(r[0]), r);
      }
      const was = held;
      const at = places !== undefined ? given : placesFor(items.map(([id]) => was.get(id)?.ord ?? null));
      // (a record as written: read just now, else the row given again, written as it is)
      const before = (id: string, row: J): J => {
        const r = stored.get(id);
        if (r !== undefined) return this.#chatRow(station, a, id, r[2], r[3]);
        const kept = this.#env.cache.get(K("chat", station, a, id));
        return kept !== undefined && kept !== null ? kept : frozen(JSON.parse(JSON.stringify(row)));
      };
      let changed = false;
      items.forEach(([id, row], i) => {
        const h = was.get(id);
        if (h !== undefined && asHeld(id, row)) {
          if (h.ord === at[i]) {
            glanced.chatRowsSame++;
            return;
          }
          // (moved alone)
          return this.#placeChatRow(station, a, id, row, before(id, row), at[i]!, h.ord);
        }
        const c = this.#chatCols(row);
        const r = stored.get(id);
        if (h !== undefined && r !== undefined && r[2] === c.json && r[3] === c.unread) {
          if (h.ord !== at[i]) return this.#placeChatRow(station, a, id, row, before(id, row), at[i]!, h.ord);
          h.row = row;
          return;
        }
        changed = true;
        this.#putChatRow(station, a, id, row, at[i]!, h === undefined ? undefined : before(id, row), h?.ord, c);
      });
      // (those gone, in the list's order)
      const gone = [...was].filter(([id]) => !seen.has(id)).sort(([, x], [, y]) => x.ord - y.ord);
      for (const [id, h] of gone) {
        changed = true;
        this.#deleteChatRow(station, a, id, before(id, h.row), h.ord);
      }
      this.#env.markListed(station, list, confirmed, changed);
    });
  }

  #deleteChatRow(station: string, archived: number, id: string, before: J | undefined, ordBefore: number): void {
    const kept = this.#env.kept.writing("chat", [station, id]);
    this.#env.run("DELETE FROM chat WHERE station = ? AND archived = ? AND id = ?", [station, archived, id]);
    if (archived === 0 && this.#sharedSidecarMade) {
      this.#env.run("DELETE FROM shared_sidecar WHERE station = ? AND id = ?", [station, id]);
    }
    this.#chatsHeld.get(K(archived ? "archived" : "chats", station))?.delete(id);
    this.#env.cache.delete(K("chat", station, archived, id));
    this.#env.kept.wrote(kept, () => undefined);
    this.#env.loadedList(station, archived ? "archived" : "chats")?.delete(id);
    this.#env.tellChatRead(station, archived, id, before, undefined, ordBefore, undefined);
    if (!archived) this.#env.tellChat(station, id, before, undefined);
    this.#env.tell({ topic: archived ? "archivedRows" : "chatRows", station });
  }

  /// A sidebar row as an event has it: at `place` where its list says each row's (setChats `places`), else in place, or
  /// last when new. Nothing while the station's rows were never read. The row written before (the same object, frozen) at
  /// the same place writes nothing and reads nothing; another is read by its key to be compared.
  putChat(station: string, row: J, place?: number): void {
    const id = idText(get(row, "id"));
    if (id === null || !this.#env.listed(station, "chats")) return;
    // (one the station said went elsewhere: not listed of it)
    if (this.#movedAway(station, row)) return this.dropChat(station, id);
    this.#env.write(() => {
      const h = this.#chatsHeld.get(K("chats", station))?.get(id);
      if (h !== undefined && h.row === row && Object.isFrozen(row)) {
        if (place === undefined || h.ord === place) return;
        // (as written, at another place: that alone)
        const kept = this.#env.cache.get(K("chat", station, 0, id));
        return this.#placeChatRow(station, 0, id, row, kept !== undefined && kept !== null ? kept : frozen(JSON.parse(JSON.stringify(row))), place, h.ord);
      }
      const r = this.#env.sql.all("SELECT ord, json, unread FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
      const c = this.#chatCols(row);
      if (r && r[1] === c.json && r[2] === c.unread) {
        if (place !== undefined && r[0] !== place) return this.#placeChatRow(station, 0, id, row, this.#chatRow(station, 0, id, r[1], r[2]), place, r[0] as number);
        if (h !== undefined) h.row = row;
        return;
      }
      const ord = place ?? (r ? (r[0] as number) : ((this.#env.sql.all("SELECT max(ord) FROM chat WHERE station = ? AND archived = 0", [station])[0]?.[0] as number | null) ?? -1) + 1);
      this.#putChatRow(station, 0, id, row, ord, r ? this.#chatRow(station, 0, id, r[1], r[2]) : undefined, r ? (r[0] as number) : undefined, c);
      this.#env.bumpRev(station, "chats");
    });
  }

  dropChat(station: string, id: string): void {
    // (not in the list as it was last written: nothing to drop, nothing read)
    const held = this.#chatsHeld.get(K("chats", station));
    if (held !== undefined && !held.has(id)) return;
    this.#env.write(() => {
      // (its record from the cache where it is held: only its place read)
      const kept = this.#env.cache.get(K("chat", station, 0, id));
      if (kept !== undefined && kept !== null) {
        const r = this.#env.sql.all("SELECT ord FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
        if (!r) return;
        this.#deleteChatRow(station, 0, id, kept, r[0] as number);
        this.#env.bumpRev(station, "chats");
        return;
      }
      const r = this.#env.sql.all("SELECT json, unread, ord FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
      if (!r) return;
      this.#deleteChatRow(station, 0, id, this.#chatRow(station, 0, id, r[0], r[1]), r[2] as number);
      this.#env.bumpRev(station, "chats");
    });
  }

  // ── chats moved to another station ──

  #movedSet(station: string, session: string, to: MovedTo | null): void {
    const was = this.#moved.get(station)?.get(session);
    if (was?.thread != null) this.#movedThreads.get(station)?.delete(was.thread);
    if (to === null) {
      this.#moved.get(station)?.delete(session);
      return;
    }
    let of = this.#moved.get(station);
    if (of === undefined) this.#moved.set(station, (of = new Map()));
    of.set(session, to);
    if (to.thread !== null) {
      let threads = this.#movedThreads.get(station);
      if (threads === undefined) this.#movedThreads.set(station, (threads = new Map()));
      threads.set(to.thread, session);
    }
  }

  /// Where `station` said its chat of `session` went; undefined: it did not, or it came back.
  moved(station: string, session: string): MovedTo | undefined {
    return this.#moved.get(station)?.get(session);
  }

  /// The session of `station`'s chat of `thread` that it said went elsewhere.
  movedThread(station: string, thread: number): string | undefined {
    return this.#movedThreads.get(station)?.get(thread);
  }

  /// The sessions `station` said went elsewhere.
  movedFrom(station: string): string[] {
    return [...(this.#moved.get(station)?.keys() ?? [])];
  }

  /// `station` says its chat of `session` went to `to` (null: came back to it). What it lists of it goes (its rows,
  /// listed and archived: `dropChatsOf`), and is not taken from it again while it says so; back, it is listed again
  /// (`freed`). Whether that changed what was known.
  putMoved(station: string, session: string, to: MovedTo | null): boolean {
    const was = this.moved(station, session);
    if (to === null ? was === undefined : was !== undefined && was.station === to.station && was.thread === to.thread && was.there === to.there && was.came === to.came) return false;
    this.#movedSet(station, session, to);
    this.#env.write(() => {
      if (this.#movedMade) {
        if (to === null) this.#env.run("DELETE FROM moved WHERE station = ? AND session = ?", [station, session]);
        else this.#env.run("INSERT OR REPLACE INTO moved (station, session, there_station, thread, there, at, came) VALUES (?, ?, ?, ?, ?, ?, ?)", [station, session, to.station, to.thread, to.there, to.at, to.came === true ? 1 : 0]);
      }
      if (to === null) this.#env.tellFreed(station, session);
      else this.dropChatsOf(station, session);
    });
    return true;
  }

  /// `station`'s rows of the chat of `session`, listed and archived, gone (found by `chat_session`).
  dropChatsOf(station: string, session: string): void {
    this.#env.write(() => {
      for (const r of this.#env.sql.all("SELECT archived, id, json, unread, ord FROM chat WHERE station = ? AND session = ?", [station, session])) {
        const archived = r[0] as number;
        const id = String(r[1]);
        this.#deleteChatRow(station, archived, id, this.#chatRow(station, archived, id, r[2], r[3]), r[4] as number);
        this.#env.bumpRev(station, archived ? "archived" : "chats");
      }
    });
  }

  /// Whether a row is one `station` said went elsewhere (`putMoved`): not listed of it.
  #movedAway(station: string, row: J): boolean {
    const of = this.#moved.get(station);
    if (of === undefined || of.size === 0) return false;
    const session = get(row, "session");
    return typeof session === "string" && of.has(session);
  }

  /// A listed row written of `station` whose chat says it came from another station of its workspace (its record's
  /// `from`, else its agent's summary's: that station's id; station/src/replica/handover.ts): that one's rows of it go and
  /// are not listed of it, as where it said so itself (`putMoved`), so a device that never heard it (it off) lists the
  /// chat once. What it says itself overrides this (its `chat-moved`, `GET /moved`, a `409 moved`).
  /// One rule whichever comes first, the row or its summary's `from`: a summary saying it written for a session whose
  /// row is listed takes that row so (`summaryCame`), and a row that comes to name its thread after it was taken
  /// without one says its thread here (else the chat is known here by no thread: a page by its thread never follows).
  /// (`first`: new to the list, or to its thread; its summary is read only then)
  #came(station: string, row: J, c: ChatCols, first: boolean): void {
    if (c.session === null) return;
    const from = str(get(row, "from")) ?? (first ? str(get(this.#summaryOf(station, c.session), "from")) : null);
    if (from === null || from === "" || from.includes("/")) return;
    const at = station.lastIndexOf("/");
    const there = `${at < 0 ? "" : station.slice(0, at + 1)}${from}`;
    if (there === station) return;
    const known = this.moved(there, c.session);
    if (known !== undefined && !(known.came === true && known.station === station && known.there === null && c.thread !== null)) return;
    // (its thread there as its row there says it, before that goes: what was sent to it there is aimed here by it)
    const thread = known?.thread ?? u64(this.#env.sql.all("SELECT thread FROM chat WHERE station = ? AND session = ? AND thread IS NOT NULL LIMIT 1", [there, c.session])[0]?.[0]);
    this.putMoved(there, c.session, { station, thread, there: c.thread, at: null, came: true });
    this.#env.tellCame(there, c.session);
  }

  /// A summary saying its chat came from another station (`from`), its row listed already: taken as a row new to the
  /// list is (`#came`), so the order the two come in changes nothing.
  summaryCame(station: string, key: string, summary: J): void {
    if (str(get(summary, "from")) === null) return;
    const r = this.#env.sql.all("SELECT json FROM chat WHERE station = ? AND session = ? AND archived = 0 LIMIT 1", [station, key])[0];
    if (r === undefined || typeof r[0] !== "string") return;
    const row = JSON.parse(r[0]) as J;
    this.#came(station, row, this.#chatCols(row), true);
  }

  // ── declared chat reads and head queries ──

  /// What a declared read finds (chat-reads.ts), each row with its record where `wants` says so (every row by default):
  /// read by its key, from the cache where it is held, its JSON read only where it is not.
  chatFound<P>(read: ChatRead<P>, p: P, wants: (cols: SqlRow) => boolean = () => true): ChatFound[] {
    const out = foundOf(this.chatCounted(read, p));
    if (read.records) this.chatRecords(out.filter((f) => wants(f.cols)));
    return out;
  }

  /// The records of rows a read found (`record` of each, undefined where it is gone): read by their keys, from the cache
  /// where held, their JSON read only where not.
  chatRecords(found: ChatFound[]): void {
    for (const archived of [0, 1]) {
      const of = found.filter((f) => (f.archived ? 1 : 0) === archived);
      if (of.length === 0) continue;
      const made = this.#records(of.map((f) => [f.station, f.id]), archived);
      of.forEach((f, i) => (f.record = made[i]));
    }
  }

  /// What a declared read of counts or columns answers (chat-reads.ts), as SQLite gives it.
  chatCounted<P>(read: ChatRead<P>, p: P): SqlRow[] {
    return this.#env.sql.all(read.sql, read.params(p));
  }

  /// Chat records by their keys (station, id), `archived` or not, in that order (undefined: none): each kept by its key
  /// as it is kept, the JSON of those not kept read by one statement (json_each), by their primary keys.
  #records(found: [string, string][], archived: number): (J | undefined)[] {
    const out: (J | undefined)[] = found.map(([station, id]) => this.#env.cache.get(K("chat", station, archived, id)) ?? undefined);
    const missing = found.filter((_, i) => out[i] === undefined);
    if (missing.length === 0) return out;
    const read = new Map<string, SqlRow>();
    for (const r of this.#env.sql.all("SELECT c.station, c.id, c.json, c.unread FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = json_extract(k.value, '$[0]') AND c.archived = ? AND c.id = json_extract(k.value, '$[1]')", [JSON.stringify(missing), archived])) {
      read.set(K(String(r[0]), String(r[1])), r);
    }
    found.forEach(([station, id], i) => {
      if (out[i] !== undefined) return;
      const r = read.get(K(station, id));
      if (r !== undefined) out[i] = this.#chatRow(station, archived, id, r[2], r[3]);
    });
    return out;
  }

  /// A sidebar row by its id where it is held in memory (read or written this run): nothing read.
  heldChat(station: string, id: string): J {
    const kept = this.#env.cache.get(K("chat", station, 0, id));
    return kept === null ? undefined : kept;
  }

  /// A sidebar row by its id.
  chat(station: string, id: string): J {
    // (a row kept by its key is the one in the database: written, it is kept anew; gone, let go)
    const kept = this.#env.cache.get(K("chat", station, 0, id));
    if (kept !== undefined && kept !== null) return kept;
    return this.chatFound(CHAT_READS.row, { station, id })[0]?.record;
  }

  /// The sidebar row of a thread.
  chatOfThread(station: string, thread: number): J {
    return this.chatFound(CHAT_READS.thread, { station, thread })[0]?.record;
  }

  /// The sidebar rows a thread's or an agent's session's changes touch: the thread's chat's; the rows the session is
  /// among the agents of (its own, and the chats it takes part in).
  chatsOf(station: string, of: { thread: number } | { session: string }): J[] {
    const rows = "thread" in of
      ? this.#env.sql.all("SELECT id, json, unread FROM chat WHERE station = ? AND archived = 0 AND thread = ?", [station, of.thread])
      : this.#env.sql.all("SELECT id, json, unread FROM chat WHERE station = ? AND archived = 0 AND (session = ? OR instr(json, ?) > 0)", [station, of.session, JSON.stringify(of.session)]);
    const out = rows.map((r) => this.#chatRow(station, 0, String(r[0]), r[1], r[2]));
    return "thread" in of ? out : out.filter((row) => Array.isArray(get(row, "agents")) && (get(row, "agents") as J[]).some((a) => get(a, "key") === of.session));
  }

  /// The sidebar row of an agent's session.
  chatOfSession(station: string, session: string): J {
    return this.chatFound(CHAT_READS.session, { station, session })[0]?.record;
  }

  /// The sidebar row an agent's session is among the agents of (`chat_agent`), the first in the list's order.
  chatOfAgent(station: string, session: string): J {
    return this.chatFound(CHAT_READS.agent, { station, session })[0]?.record;
  }

  /// The sidebar row asked for here under a client key (views/local.ts).
  chatOfClientKey(station: string, key: string): J {
    return this.chatFound(CHAT_READS.client, { station, key })[0]?.record;
  }

  /// The rows of these stations a list shows first: the pinned, then the latest active, `limit` of them; `mine`, of the
  /// viewer's own alone (a list of them, whose first rows are not the first of all: its column, not a row read to see).
  chatHead(stations: string[], limit: number, mine = false): [string, J][] {
    if (stations.length === 0) return [];
    const marks = stations.map(() => "?").join(", ");
    const where = `archived = 0 AND station IN (${marks})${mine ? " AND mine = 1" : ""} ORDER BY pinned_at DESC, last_active DESC LIMIT ?`;
    const found = this.#env.sql.all(`SELECT station, id FROM chat WHERE ${where}`, [...stations, limit]);
    const made = this.chatRowsFound(found, 0, () => this.#env.sql.all(`SELECT station, id, json, unread FROM chat WHERE ${where}`, [...stations, limit]));
    return found.flatMap((r, i): [string, J][] => (made[i] === undefined ? [] : [[String(r[0]), made[i]]]));
  }

  /// The rows of these stations a list shows first (chatHead's), each its row kept beside it under its station's key in
  /// force (`keys`), else its record: a record's JSON is read only where no row is kept under that key.
  listHead(stations: string[], limit: number, mine: boolean, keys: Map<string, string>): HeadRow[] {
    if (stations.length === 0) return [];
    const d = KEPT.listRow;
    if (!this.#env.kept.keeps(d)) return this.chatHead(stations, limit, mine).map(([station, record]) => ({ station, id: String(get(record, "id")), pinnedAt: num(get(record, "pinned")), row: null, record }));
    const marks = stations.map(() => "?").join(", ");
    const where = `c.archived = 0 AND c.station IN (${marks})${mine ? " AND c.mine = 1" : ""} ORDER BY c.pinned_at DESC, c.last_active DESC LIMIT ?`;
    // (a row kept under another key not read: joined by the one in force)
    const j = this.#env.kept.joined(d, "r", ["c.station", "c.id"], `json_extract(?, '$."' || c.station || '"')`);
    const found = this.#env.sql.all(`SELECT c.station, c.id, c.pinned_at, ${j.columns} FROM chat AS c ${j.join} WHERE ${where}`, [JSON.stringify(Object.fromEntries(keys)), ...stations, limit]);
    const out: HeadRow[] = [];
    const missing: SqlRow[] = [];
    for (const r of found) {
      const station = String(r[0]);
      const id = String(r[1]);
      const key = keys.get(station);
      const row = key === undefined ? undefined : this.#env.kept.taken(d, [station, id], key, r.slice(3));
      if (row === undefined) missing.push(r);
      out.push({ station, id, pinnedAt: typeof r[2] === "number" ? r[2] : null, row: row ?? null, record: undefined });
    }
    if (missing.length > 0) {
      // (theirs alone, by their keys, whatever their number: #byKey's `all` is these too)
      const theirs = () => this.#env.sql.all("SELECT c.station, c.id, c.json, c.unread FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = json_extract(k.value, '$[0]') AND c.archived = 0 AND c.id = json_extract(k.value, '$[1]')", [JSON.stringify(missing.map((r) => [r[0], r[1]]))]);
      const records = this.chatRowsFound(missing.map((r) => [r[0], r[1]]), 0, theirs);
      const by = new Map(missing.map((r, i) => [K(String(r[0]), String(r[1])), records[i]]));
      for (const h of out) if (h.row === null) h.record = by.get(K(h.station, h.id));
    }
    return out.filter((h) => h.row !== null || h.record !== undefined);
  }

  /// How many sidebar rows these stations have.
  chatCount(stations: string[]): number {
    if (stations.length === 0) return 0;
    return (this.#env.sql.all(`SELECT count(*) FROM chat WHERE archived = 0 AND station IN (${stations.map(() => "?").join(", ")})`, stations)[0]?.[0] as number) ?? 0;
  }

  /// The rows of these stations that ask something of their person or are unread (views/marks.ts).
  marked(stations: string[]): [string, J][] {
    if (stations.length === 0) return [];
    return this.chatFound(CHAT_READS.marked, { stations }).flatMap((f): [string, J][] => (f.record === undefined ? [] : [[f.station, f.record]]));
  }

  /// The viewer read a thread up to `n`: its rows unread no more where that covers their last message.
  readRows(station: string, thread: number, n: number): void {
    for (const r of this.#env.sql.all("SELECT id, ord, json, unread FROM chat WHERE station = ? AND archived = 0 AND thread = ? AND unread = 1", [station, thread])) {
      const id = String(r[0]);
      const before = this.#chatRow(station, 0, id, r[2], r[3]);
      const last = u64(get(get(before, "last"), "seq"));
      if (last !== null && n < last) continue;
      const after = { ...before, unread: false };
      this.#putChatRow(station, 0, id, after, r[1] as number, before, r[1] as number);
      this.#env.bumpRev(station, "chats");
    }
  }

  /// The chats a station's agents last spoke in, the latest first, from `since` on: at most `most`.
  recentThreads(station: string, since: number, most: number): number[] {
    return this.#env.sql.all("SELECT thread FROM chat WHERE station = ? AND archived = 0 AND thread IS NOT NULL AND last_active >= ? ORDER BY last_active DESC LIMIT ?", [station, since, most]).map((r) => r[0] as number);
  }

  // ── minimal shared chat sidecar (POST /changed/shared) ──

  #putSidecarRow(station: string, id: string, sc: SharedSidecar): void {
    if (!this.#sharedSidecarMade) return;
    this.#env.run(
      "INSERT OR REPLACE INTO shared_sidecar (station, id, digest, said, named, quoted_only, local_admin) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [station, id, sc.digest, sc.said === null ? null : JSON.stringify(sc.said), sc.named === null ? null : JSON.stringify(sc.named), sc.quotedOnly ? 1 : 0, sc.localAdmin ? 1 : 0],
    );
  }

  #putSharedMeta(station: string, meta: SharedMeta): void {
    if (!this.#sharedSidecarMade) return;
    this.#env.run(
      "INSERT OR REPLACE INTO shared_meta (station, me, selves, lang, hidden_known, muted_known, no_route_build) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [station, meta.me, JSON.stringify(meta.selves), meta.lang, meta.hiddenKnown ? 1 : 0, meta.mutedKnown ? 1 : 0, meta.noRouteBuild],
    );
  }

  #parseSidecar(r: SqlRow): SharedSidecar {
    return {
      digest: String(r[0]),
      said: typeof r[1] === "string" ? (JSON.parse(r[1]) as J) : null,
      named: typeof r[2] === "string" ? (JSON.parse(r[2]) as J) : null,
      quotedOnly: r[3] === 1,
      localAdmin: r[4] === 1,
    };
  }

  sharedMeta(station: string): SharedMeta | null {
    if (!this.#sharedSidecarMade) return null;
    const r = this.#env.sql.all("SELECT me, selves, lang, hidden_known, muted_known, no_route_build FROM shared_meta WHERE station = ?", [station])[0];
    if (!r) return null;
    try {
      const selves = JSON.parse(String(r[1]));
      if (!Array.isArray(selves)) return null;
      return {
        me: String(r[0]),
        selves: selves.map(String),
        lang: String(r[2]),
        hiddenKnown: r[3] === 1,
        mutedKnown: r[4] === 1,
        noRouteBuild: typeof r[5] === "string" && r[5] !== "" ? r[5] : null,
      };
    } catch {
      return null;
    }
  }

  setSharedNoRouteBuild(station: string, build: string | null): void {
    if (!this.#sharedSidecarMade) return;
    this.#env.write(() => {
      this.#env.run("UPDATE shared_meta SET no_route_build = ? WHERE station = ?", [build, station]);
    });
  }

  #readSharedMarks(station: string): {
    reads: Map<number, number>;
    pins: Map<string, number>;
    kept: Set<number>;
    hidden: Set<number>;
    muted: Set<number>;
    dismissed: Set<string>;
  } {
    const reads = new Map<number, number>();
    const pins = new Map<string, number>();
    const kept = new Set<number>();
    const hidden = new Set<number>();
    const muted = new Set<number>();
    const dismissed = new Set<string>();
    if (!this.#sharedSidecarMade) return { reads, pins, kept, hidden, muted, dismissed };
    for (const r of this.#env.sql.all("SELECT kind, k, v FROM shared_mark WHERE station = ?", [station])) {
      const kind = String(r[0]);
      const k = String(r[1]);
      if (kind === "read") reads.set(Number(k), Number(r[2]));
      else if (kind === "pin") pins.set(k, Number(r[2]));
      else if (kind === "kept") kept.add(Number(k));
      else if (kind === "hidden") hidden.add(Number(k));
      else if (kind === "muted") muted.add(Number(k));
      else if (kind === "dismissed") dismissed.add(k);
    }
    return { reads, pins, kept, hidden, muted, dismissed };
  }

  #replaceSharedMarks(station: string, marks: SharedMarksSnapshot): void {
    if (!this.#sharedSidecarMade) return;
    this.#env.run("DELETE FROM shared_mark WHERE station = ?", [station]);
    const put = (kind: SharedMarkKind, k: string, v: string) =>
      this.#env.run("INSERT OR REPLACE INTO shared_mark (station, kind, k, v) VALUES (?, ?, ?, ?)", [station, kind, k, v]);
    for (const [t, n] of marks.reads) put("read", String(t), String(n));
    for (const [s, at] of marks.pins) put("pin", s, String(at));
    for (const t of marks.kept) put("kept", String(t), "1");
    for (const t of marks.hidden ?? []) put("hidden", String(t), "1");
    for (const t of marks.muted ?? []) put("muted", String(t), "1");
    for (const d of marks.dismissed) put("dismissed", d, "1");
  }

  /// Diffs `newMarks` against persisted `shared_mark` rows, updates only changed keys in `shared_mark`, and returns
  /// the exact `ids` (pins) and `threads` (reads/kept/hidden/muted/dismissed) that changed.
  #diffAndSyncMarks(station: string, marks: SharedMarksSnapshot): { ids: Set<string>; threads: Set<number> } {
    const ids = new Set<string>();
    const threads = new Set<number>();
    if (!this.#sharedSidecarMade) return { ids, threads };
    const old = this.#readSharedMarks(station);
    const put = (kind: SharedMarkKind, k: string, v: string) =>
      this.#env.run("INSERT OR REPLACE INTO shared_mark (station, kind, k, v) VALUES (?, ?, ?, ?)", [station, kind, k, v]);
    const del = (kind: SharedMarkKind, k: string) =>
      this.#env.run("DELETE FROM shared_mark WHERE station = ? AND kind = ? AND k = ?", [station, kind, k]);

    for (const [t, n] of marks.reads) {
      if (old.reads.get(t) !== n) {
        threads.add(t);
        put("read", String(t), String(n));
      }
    }
    for (const t of old.reads.keys()) {
      if (!marks.reads.has(t)) {
        threads.add(t);
        del("read", String(t));
      }
    }
    for (const [s, at] of marks.pins) {
      if (old.pins.get(s) !== at) {
        ids.add(s);
        put("pin", s, String(at));
      }
    }
    for (const s of old.pins.keys()) {
      if (!marks.pins.has(s)) {
        ids.add(s);
        del("pin", s);
      }
    }
    const syncThreadSet = (kind: "kept" | "hidden" | "muted", oldSet: Set<number>, newSet: ReadonlySet<number> | undefined) => {
      const next = newSet ?? new Set<number>();
      for (const t of next) {
        if (!oldSet.has(t)) {
          threads.add(t);
          put(kind, String(t), "1");
        }
      }
      for (const t of oldSet) {
        if (!next.has(t)) {
          threads.add(t);
          del(kind, String(t));
        }
      }
    };
    syncThreadSet("kept", old.kept, marks.kept);
    syncThreadSet("hidden", old.hidden, marks.hidden);
    syncThreadSet("muted", old.muted, marks.muted);

    const threadOfDismissed = (d: string): number | null => {
      const at = d.indexOf(":");
      if (at <= 0) return null;
      const t = Number(d.slice(0, at));
      return Number.isInteger(t) ? t : null;
    };
    for (const d of marks.dismissed) {
      if (!old.dismissed.has(d)) {
        const t = threadOfDismissed(d);
        if (t !== null) threads.add(t);
        put("dismissed", d, "1");
      }
    }
    for (const d of old.dismissed) {
      if (!marks.dismissed.has(d)) {
        const t = threadOfDismissed(d);
        if (t !== null) threads.add(t);
        del("dismissed", d);
      }
    }
    return { ids, threads };
  }

  sharedDigests(station: string): Map<string, string> {
    const out = new Map<string, string>();
    if (!this.#sharedSidecarMade) return out;
    for (const r of this.#env.sql.all("SELECT id, digest FROM shared_sidecar WHERE station = ?", [station])) {
      out.set(String(r[0]), String(r[1]));
    }
    return out;
  }

  sharedSidecar(station: string, id: string): SharedSidecar | null {
    if (!this.#sharedSidecarMade) return null;
    const r = this.#env.sql.all("SELECT digest, said, named, quoted_only, local_admin FROM shared_sidecar WHERE station = ? AND id = ?", [station, id])[0];
    return r ? this.#parseSidecar(r) : null;
  }

  sharedSidecars(station: string): Map<string, SharedSidecar> {
    const out = new Map<string, SharedSidecar>();
    if (!this.#sharedSidecarMade) return out;
    for (const r of this.#env.sql.all("SELECT id, digest, said, named, quoted_only, local_admin FROM shared_sidecar WHERE station = ?", [station])) {
      out.set(String(r[0]), this.#parseSidecar(r.slice(1)));
    }
    return out;
  }

  clearSharedBaseline(station: string): void {
    if (!this.#sharedSidecarMade) return;
    this.#env.write(() => {
      this.#env.run("DELETE FROM shared_sidecar WHERE station = ?", [station]);
      this.#env.run("DELETE FROM shared_meta WHERE station = ?", [station]);
      this.#env.run("DELETE FROM shared_mark WHERE station = ?", [station]);
    });
  }

  /// Atomically writes the whole shared chat list along with its minimal sidecars, keyed viewer marks, and viewer/lang
  /// metadata in one transaction.
  setSharedChats(station: string, rows: J[], confirmed: number | null, places: readonly number[], sidecars: ReadonlyMap<string, SharedSidecar>, marks: SharedMarksSnapshot, meta: SharedMeta): void {
    this.#env.write(() => {
      this.setChats(station, false, rows, confirmed, places);
      if (!this.#sharedSidecarMade) return;
      const keep = new Set<string>();
      for (const row of rows) {
        const id = idText(get(row, "id"));
        if (id === null || this.#movedAway(station, row)) continue;
        keep.add(id);
        const sc = sidecars.get(id);
        if (sc !== undefined) this.#putSidecarRow(station, id, sc);
      }
      for (const r of this.#env.sql.all("SELECT id FROM shared_sidecar WHERE station = ?", [station])) {
        const id = String(r[0]);
        if (!keep.has(id)) this.#env.run("DELETE FROM shared_sidecar WHERE station = ? AND id = ?", [station, id]);
      }
      this.#replaceSharedMarks(station, marks);
      this.#putSharedMeta(station, meta);
    });
  }

  /// Atomically writes one sidebar row and its optional sidecar (never invalidates persisted marks).
  putSharedChat(station: string, row: J, place: number, sidecar: SharedSidecar | null): void {
    this.#env.write(() => {
      const id = idText(get(row, "id"));
      if (id === null || !this.#env.listed(station, "chats")) return;
      if (this.#movedAway(station, row)) {
        this.dropChat(station, id);
        return;
      }
      this.putChat(station, row, place);
      if (sidecar !== null) this.#putSidecarRow(station, id, sidecar);
    });
  }

  /// Atomically writes one or more sidebar rows, drops, optional sidecars, and their associated `shared_mark` updates
  /// in a single SQLite transaction so marks never commit ahead of the rows they affect.
  putSharedBatch(
    station: string,
    updates: readonly { row: J; place: number; sidecar: SharedSidecar | null }[],
    drops: readonly string[],
    markUpdates: readonly { kind: SharedMarkKind; k: string; v: string | null }[],
    scopedMarks: { scope: { sessions: readonly string[]; threads: readonly number[] }; marks: SharedMarksSnapshot } | null,
  ): void {
    this.#env.write(() => {
      if (this.#env.listed(station, "chats")) {
        for (const u of updates) {
          const id = idText(get(u.row, "id"));
          if (id === null) continue;
          if (this.#movedAway(station, u.row)) {
            this.dropChat(station, id);
            continue;
          }
          this.putChat(station, u.row, u.place);
          if (u.sidecar !== null) this.#putSidecarRow(station, id, u.sidecar);
        }
        for (const id of drops) this.dropChat(station, id);
      }
      if (!this.#sharedSidecarMade) return;
      for (const m of markUpdates) {
        if (m.v === null) this.#env.run("DELETE FROM shared_mark WHERE station = ? AND kind = ? AND k = ?", [station, m.kind, m.k]);
        else this.#env.run("INSERT OR REPLACE INTO shared_mark (station, kind, k, v) VALUES (?, ?, ?, ?)", [station, m.kind, m.k, m.v]);
      }
      if (scopedMarks !== null) {
        const { scope, marks } = scopedMarks;
        const put = (kind: SharedMarkKind, k: string, v: string) =>
          this.#env.run("INSERT OR REPLACE INTO shared_mark (station, kind, k, v) VALUES (?, ?, ?, ?)", [station, kind, k, v]);
        const del = (kind: SharedMarkKind, k: string) =>
          this.#env.run("DELETE FROM shared_mark WHERE station = ? AND kind = ? AND k = ?", [station, kind, k]);
        for (const s of scope.sessions) {
          const at = marks.pins.get(s);
          if (at === undefined) del("pin", s);
          else put("pin", s, String(at));
        }
        for (const t of scope.threads) {
          const key = String(t);
          const r = marks.reads.get(t);
          if (r === undefined) del("read", key);
          else put("read", key, String(r));
          if (marks.kept.has(t)) put("kept", key, "1");
          else del("kept", key);
          if (marks.hidden?.has(t)) put("hidden", key, "1");
          else del("hidden", key);
          if (marks.muted?.has(t)) put("muted", key, "1");
          else del("muted", key);
          this.#env.run("DELETE FROM shared_mark WHERE station = ? AND kind = 'dismissed' AND k LIKE ?", [station, `${t}:%`]);
        }
        if (scope.threads.length > 0) {
          const tSet = new Set(scope.threads);
          for (const d of marks.dismissed) {
            const at = d.indexOf(":");
            if (at > 0 && tSet.has(Number(d.slice(0, at)))) put("dismissed", d, "1");
          }
        }
      }
    });
  }

  /// Atomically applies a `POST /changed/shared` delta: deletes `gone` rows, upserts `changed` rows and their sidecars,
  /// diffs `newMarks` against `shared_mark` (merged with any `extraReproject` keys drained from `rowsWanted`) to
  /// re-project ONLY the affected unchanged rows by index (or all when `reprojectAll` is true, e.g. language change),
  /// and updates `shared_meta`. When `gone` and `changed` are empty, `reprojectAll` is false, `extraReproject` is
  /// empty, and no marks changed, zero `chat` rows are read or written.
  applySharedChanged(
    station: string,
    changed: readonly { row: J; place: number; sidecar: SharedSidecar }[],
    gone: readonly string[],
    reprojectAll: boolean,
    reproject: (row: J, sidecar: SharedSidecar) => { row: J; place: number },
    newMarks: SharedMarksSnapshot,
    confirmed: number | null,
    meta: SharedMeta,
    extraReproject?: { ids?: Iterable<string>; threads?: Iterable<number> },
  ): void {
    this.#env.write(() => {
      let anyChanged = false;
      const touched = new Set<string>();
      for (const id of gone) {
        touched.add(id);
        const kept = this.#env.cache.get(K("chat", station, 0, id));
        if (kept !== undefined && kept !== null) {
          const r = this.#env.sql.all("SELECT ord FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
          if (r) {
            this.#deleteChatRow(station, 0, id, kept, r[0] as number);
            anyChanged = true;
          } else if (this.#sharedSidecarMade) {
            this.#env.run("DELETE FROM shared_sidecar WHERE station = ? AND id = ?", [station, id]);
          }
        } else {
          const r = this.#env.sql.all("SELECT json, unread, ord FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
          if (r) {
            this.#deleteChatRow(station, 0, id, this.#chatRow(station, 0, id, r[0], r[1]), r[2] as number);
            anyChanged = true;
          } else if (this.#sharedSidecarMade) {
            this.#env.run("DELETE FROM shared_sidecar WHERE station = ? AND id = ?", [station, id]);
          }
        }
      }
      const upsertRow = (id: string, row: J, place: number): void => {
        if (this.#movedAway(station, row)) {
          this.dropChat(station, id);
          anyChanged = true;
          return;
        }
        const h = this.#chatsHeld.get(K("chats", station))?.get(id);
        if (h !== undefined && h.row === row && Object.isFrozen(row)) {
          if (h.ord === place) return;
          const kept = this.#env.cache.get(K("chat", station, 0, id));
          this.#placeChatRow(station, 0, id, row, kept !== undefined && kept !== null ? kept : frozen(JSON.parse(JSON.stringify(row))), place, h.ord);
          return;
        }
        const r = this.#env.sql.all("SELECT ord, json, unread FROM chat WHERE station = ? AND archived = 0 AND id = ?", [station, id])[0];
        const c = this.#chatCols(row);
        if (r && r[1] === c.json && r[2] === c.unread) {
          if (r[0] !== place) this.#placeChatRow(station, 0, id, row, this.#chatRow(station, 0, id, r[1], r[2]), place, r[0] as number);
          if (h !== undefined) h.row = row;
          return;
        }
        anyChanged = true;
        this.#putChatRow(station, 0, id, row, place, r ? this.#chatRow(station, 0, id, r[1], r[2]) : undefined, r ? (r[0] as number) : undefined, c);
      };
      for (const item of changed) {
        const id = idText(get(item.row, "id"));
        if (id === null) continue;
        touched.add(id);
        upsertRow(id, item.row, item.place);
        if (!this.#movedAway(station, item.row)) this.#putSidecarRow(station, id, item.sidecar);
      }
      const diff = this.#diffAndSyncMarks(station, newMarks);
      if (extraReproject?.ids) for (const id of extraReproject.ids) diff.ids.add(id);
      if (extraReproject?.threads) for (const t of extraReproject.threads) diff.threads.add(t);
      if (this.#sharedSidecarMade) {
        let targetIds: string[] = [];
        let sidecars: Map<string, SharedSidecar> | null = null;
        if (reprojectAll) {
          sidecars = this.sharedSidecars(station);
          targetIds = [...sidecars.keys()].filter((id) => !touched.has(id));
        } else if (diff.ids.size > 0 || diff.threads.size > 0) {
          const picked = new Set<string>();
          for (const id of diff.ids) if (!touched.has(id)) picked.add(id);
          if (diff.threads.size > 0) {
            for (const r of this.#env.sql.all(
              "SELECT c.id FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = ? AND c.archived = 0 AND c.thread = k.value",
              [JSON.stringify([...diff.threads]), station],
            )) {
              const id = String(r[0]);
              if (!touched.has(id)) picked.add(id);
            }
          }
          targetIds = [...picked];
          if (targetIds.length > 0) {
            sidecars = new Map();
            for (const r of this.#env.sql.all(
              "SELECT s.id, s.digest, s.said, s.named, s.quoted_only, s.local_admin FROM json_each(?) AS k CROSS JOIN shared_sidecar AS s WHERE s.station = ? AND s.id = k.value",
              [JSON.stringify(targetIds), station],
            )) {
              sidecars.set(String(r[0]), this.#parseSidecar(r.slice(1)));
            }
          }
        }
        if (targetIds.length > 0 && sidecars !== null) {
          for (const r of this.#env.sql.all(
            "SELECT c.id, c.ord, c.json, c.unread FROM json_each(?) AS k CROSS JOIN chat AS c WHERE c.station = ? AND c.archived = 0 AND c.id = k.value",
            [JSON.stringify(targetIds), station],
          )) {
            const id = String(r[0]);
            const sc = sidecars.get(id);
            if (!sc) continue;
            const before = this.#chatRow(station, 0, id, r[2], r[3]);
            const next = reproject(before, sc);
            const c = this.#chatCols(next.row);
            if (r[2] === c.json && r[3] === c.unread) {
              if (r[1] !== next.place) this.#placeChatRow(station, 0, id, next.row, before, next.place, r[1] as number);
              continue;
            }
            anyChanged = true;
            this.#putChatRow(station, 0, id, next.row, next.place, before, r[1] as number, c);
          }
        }
      }
      this.#putSharedMeta(station, meta);
      this.#env.markListed(station, "chats", confirmed, anyChanged);
    });
  }
}
