// A station's sidebar made here from the chat list the station makes once for everyone (GET /chats?shared=1,
// `chat-shared`, `chat-shared-removed`) and what is the viewer's own (`GET /chats?marks=1`: where they read each chat
// to, the cards and needs they let go, pins, kept, hidden, muted, and their Slack identities). Made by the station per
// viewer, every change read every row it could touch again from disk while its machine was short of memory (3 to 10 s
// each on a station, 2026-11-03); the station makes the shared chat list, and each device puts its viewer's own marks
// on it by key.
import { get, isObject } from "../util.ts";
import type * as titles from "../titles.ts";
import { type Own, rowFor } from "../chat-row.ts";
import { current, tr } from "../i18n.ts";
import { glanced, work } from "../work.ts";

type J = Record<string, any>;

/// What of `GET /chats?marks=1` is the viewer's own for the shared chat list.
export type Marks = {
  kept: number[];
  hidden?: number[];
  muted?: number[];
  pins: Record<string, number>;
  selves: string[];
  /// The cards and needs the viewer let go (`<thread>:<seq>`), and where they read each chat to (chat-row.ts).
  dismissed: string[];
  reads: Record<string, number>;
};

/// The words a row says in the viewer's language.
export type Words = titles.TitleWords & { quotedOnly: string };

/// The words of the language the core speaks now, the same object while it is the same (what every row is made in:
/// RowsMemo `whole`, data.ts `inWords`).
let wordsNow: { lang: string; words: Words & { admin: string } } | null = null;
export function rowWords(): Words & { admin: string } {
  const lang = current();
  if (wordsNow?.lang !== lang) {
    wordsNow = { lang, words: { untitled: tr(lang, "core-views.new_chat"), directMessage: tr(lang, "core-views.direct_message"), quotedOnly: tr(lang, "station.chat.quotedOnly"), admin: tr(lang, "station.author.admin") } };
  }
  return wordsNow.words;
}

/// What a station's rows were last made of (`rowsShared`, `rowShared`), kept on its link (link.ts `rows`): each row by
/// its id, with what it was made of (`of`), so a row all of whose parts are as they were is the same object as before
/// (rule 6), and only those something changed are made again (work.ts `chatRowsMade`). What every row reads (whose rows
/// they are, the words) is `whole`: all of them are made again as it changes. Empty, it holds nothing, and the rows are
/// made as they always were.
export type RowsMemo = { whole: string; rows: Map<string, { of: unknown[]; row: J }> };
export const rowsMemo = (): RowsMemo => ({ whole: "", rows: new Map() });

/// Makes each row through `memo`: `row(key, of, make)` gives the row made before under `key` where `of` is all as it
/// was, else `make`'s. `done` puts what was made this time in its place (a row not asked again is let go).
function through(memo: RowsMemo, whole: string) {
  const was = memo.whole === whole ? memo.rows : new Map<string, { of: unknown[]; row: J }>();
  const now = new Map<string, { of: unknown[]; row: J }>();
  const same = (a: unknown[], b: unknown[]) => a.length === b.length && a.every((v, i) => v === b[i]);
  return {
    row(key: string, of: unknown[], make: () => J): J {
      const before = was.get(key);
      let row: J;
      if (before !== undefined && same(before.of, of)) row = before.row;
      else {
        work.chatRowsMade++;
        // (frozen: the same object is the same row, data.ts `inWords`, account.ts `setChats`)
        row = Object.freeze(make());
      }
      now.set(key, { of, row });
      return row;
    },
    done(): void {
      memo.whole = whole;
      memo.rows = now;
    },
  };
}

/// What of the station's answer is viewer marks (none where it is not a marks object).
export function marksOf(answer: unknown): Marks | null {
  if (!isObject(answer) || (!isObject(get(answer, "pins")) && !isObject(get(answer, "reads")))) return null;
  const o = (k: string) => (isObject(get(answer, k)) ? { ...(get(answer, k) as J) } : {});
  const a = (k: string) => (Array.isArray(get(answer, k)) ? [...(get(answer, k) as any[])] : []);
  return {
    kept: a("kept").filter((n): n is number => typeof n === "number"),
    ...(Array.isArray(get(answer, "hidden")) ? { hidden: a("hidden").filter((n): n is number => typeof n === "number") } : {}),
    ...(Array.isArray(get(answer, "muted")) ? { muted: a("muted").filter((n): n is number => typeof n === "number") } : {}),
    pins: o("pins"),
    selves: a("selves").filter((s): s is string => typeof s === "string"),
    dismissed: a("dismissed").filter((s): s is string => typeof s === "string"),
    reads: o("reads"),
  };
}

const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

/// Whether a person (a creator reference) is the viewer whose email is `me`, or a Slack user they are (`selves`).
export function mineFor(me: string, selves: readonly string[]): (p: unknown) => boolean {
  const email = me.toLowerCase();
  const slack = new Set(selves);
  return (p: unknown): boolean => {
    if (!isObject(p)) return false;
    const pid = str(get(p, "id")) ?? "";
    const pe = str(get(p, "email"));
    return pid === me || (pe !== null && pe.toLowerCase() === email) || (get(p, "via") === "slack" && slack.has(pid.slice(pid.lastIndexOf(":") + 1)));
  };
}

/// A row's place in the list its station makes for everyone: the latest active first, of the row alone, so that one row
/// is written in its place by its key (account.ts `putChat`), nothing else read; rows active at once go by their ids in
/// every read that orders by place (`ORDER BY ord, id`: chat-reads.ts, account.ts Collection).
export const sharedPlace = (row: J): number => -num(row.lastActiveAt) || 0;

/// The viewer's own of a station's marks (chat-row.ts Own) as maps and sets, so that one row's is found by its keys:
/// made of the marks as they are read whole, then kept true by key (`read`, `threadMark`, `pin`, `letGo`, `scoped`), so
/// that an event or scoped read walks neither the marks nor the rows.
export class OwnHeld implements Own {
  me: string;
  selves: readonly string[];
  mine: (person: unknown) => boolean;
  readonly reads = new Map<number, number>();
  readonly dismissed = new Set<string>();
  readonly kept = new Set<number>();
  hidden?: Set<number>;
  muted?: Set<number>;
  readonly pins = new Map<string, number>();
  /// Each thread's of `dismissed`, to let them go by the thread.
  readonly #letGo = new Map<number, string[]>();
  constructor(marks: Marks, me: string) {
    this.me = me;
    this.selves = marks.selves;
    this.mine = mineFor(me, marks.selves);
    const reads = Object.entries(marks.reads);
    const pins = Object.entries(marks.pins);
    for (const [k, n] of reads) this.reads.set(Number(k), num(n));
    for (const d of marks.dismissed) this.#dismiss(d);
    for (const id of marks.kept) this.kept.add(id);
    if (marks.hidden !== undefined) this.hidden = new Set(marks.hidden);
    if (marks.muted !== undefined) this.muted = new Set(marks.muted);
    for (const [k, at] of pins) this.pins.set(k, num(at));
    glanced.marksWalked += reads.length + pins.length + marks.dismissed.length + marks.kept.length + (marks.hidden?.length ?? 0) + (marks.muted?.length ?? 0);
  }

  /// Updates the viewer's email if it was unknown or changed since the marks were read.
  forViewer(me: string): void {
    if (this.me === me) return;
    this.me = me;
    this.mine = mineFor(me, this.selves);
  }

  #dismiss(d: string): void {
    if (this.dismissed.has(d)) return;
    this.dismissed.add(d);
    const thread = Number(d.slice(0, d.indexOf(":")));
    this.#letGo.set(thread, [...(this.#letGo.get(thread) ?? []), d]);
  }

  /// Those of some chats read again (`read`): false where what every row reads changed (so all rows are made again).
  scoped(read: Marks, scope: { sessions: readonly string[]; threads: readonly number[] }): boolean {
    const same = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((v, i) => v === b[i]);
    let whole = false;
    if (!same(read.selves, this.selves)) {
      this.selves = read.selves;
      this.mine = mineFor(this.me, this.selves);
      whole = true;
    }
    if ((read.hidden === undefined) !== (this.hidden === undefined)) {
      this.hidden = read.hidden === undefined ? undefined : new Set();
      whole = true;
    }
    if ((read.muted === undefined) !== (this.muted === undefined)) {
      this.muted = read.muted === undefined ? undefined : new Set();
      whole = true;
    }
    for (const id of scope.threads) {
      this.reads.delete(id);
      this.kept.delete(id);
      this.hidden?.delete(id);
      this.muted?.delete(id);
      for (const d of this.#letGo.get(id) ?? []) this.dismissed.delete(d);
      this.#letGo.delete(id);
    }
    for (const key of scope.sessions) this.pins.delete(key);
    for (const [k, n] of Object.entries(read.reads)) this.reads.set(Number(k), num(n));
    for (const d of read.dismissed) this.#dismiss(d);
    for (const id of read.kept) this.kept.add(id);
    for (const id of read.hidden ?? []) this.hidden?.add(id);
    for (const id of read.muted ?? []) this.muted?.add(id);
    for (const [k, at] of Object.entries(read.pins)) this.pins.set(k, num(at));
    return !whole;
  }

  /// Where the viewer read a thread to, as the station told it or as it was read here: the furthest.
  read(thread: number, n: number): void {
    this.reads.set(thread, Math.max(this.reads.get(thread) ?? 0, n));
  }

  /// A thread's mark of the viewer's (kept from archiving, hidden, muted) set or let go; true where a previously absent
  /// mark kind appeared so every row is made again with it.
  threadMark(kind: "kept" | "hidden" | "muted", thread: number, on: boolean): boolean {
    let whole = false;
    let set = this[kind];
    if (set === undefined) {
      set = new Set();
      if (kind === "hidden") this.hidden = set;
      else if (kind === "muted") this.muted = set;
      whole = true;
    }
    if (on) set.add(thread);
    else set.delete(thread);
    return whole;
  }

  /// What the viewer pinned (`at`) or let go (null), by its agent's key.
  pin(key: string, at: number | null): void {
    if (at === null) this.pins.delete(key);
    else this.pins.set(key, at);
  }

  /// What waits in a thread at entry `n` (its card, its agent's need) that the viewer will not take up.
  letGo(thread: number, n: number): void {
    this.#dismiss(`${thread}:${n}`);
  }
}

/// What every row of the viewer's sidebar of the list its station makes reads (RowsMemo `whole`): whose rows they are
/// and the words.
export const sharedWhole = (me: string, selves: readonly string[], words: Words): string => JSON.stringify(["shared", me, selves, words]);

/// What rowFor reads of the viewer's own for a row of that list: where they read it to, the cards they let go of it,
/// its marks.
function ownParts(row: J, own: Own): unknown[] {
  const thread = typeof row.thread === "number" ? row.thread : null;
  if (thread === null) return [row, own.pins.get(row.id)];
  const letGo = (c: unknown) => (isObject(c) ? own.dismissed.has(`${thread}:${get(c, "seq")}`) : null);
  return [row, own.pins.get(row.id), own.reads.get(thread), letGo(row.card), letGo(row.need), letGo(row.decision), own.kept.has(thread), own.hidden?.has(thread), own.muted?.has(thread)];
}

/// The viewer's row of one row of that list (`shared`), by its key, through `memo` as `rowsShared` makes each: the row
/// made before where its parts are as they were. `memo` must be of the same whole (`sharedWhole`): the caller's to say.
export function rowShared(shared: J, own: Own, words: Words, memo: RowsMemo): J {
  const id = String(shared.id);
  const of = ownParts(shared, own);
  const before = memo.rows.get(id);
  if (before !== undefined && before.of.length === of.length && before.of.every((v, i) => v === of[i])) return before.row;
  work.chatRowsMade++;
  const row = Object.freeze(rowFor(shared, own, words));
  memo.rows.set(id, { of, row });
  return row;
}

/// The viewer's sidebar of the chat list its station made for everyone (`shared`, by row id) and the marks that are
/// theirs (`own`, OwnHeld), in their places (`sharedPlace`, then by id); made through `memo` (RowsMemo).
export function rowsShared(shared: Iterable<J>, own: OwnHeld, me: string, words: Words, memo: RowsMemo = rowsMemo()): J[] {
  own.forViewer(me);
  const rows = through(memo, sharedWhole(me, own.selves, words));
  const out = [...shared].map((row) => rows.row(String(row.id), ownParts(row, own), () => rowFor(row, own, words)));
  rows.done();
  glanced.chatRowsMapped += out.length;
  const id = (r: J) => String(r.id);
  return out.sort((a, b) => sharedPlace(a) - sharedPlace(b) || (id(a) < id(b) ? -1 : id(a) > id(b) ? 1 : 0));
}
