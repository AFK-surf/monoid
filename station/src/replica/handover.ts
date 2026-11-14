// One chat handed from this station to another of its workspace while both are up (the owner, 2026-11-14: a
// whole-station move is every chat handed over, then its connects and logins; the reverse hand-over is the way back;
// replica/AGENTS.md). The unit: a session, its agent, its room and transcripts, with the threads it takes part in, and
// the sessions that share its still.fail home chat with it. A platform thread is routed per connect, so two bots'
// sessions in one Slack thread move each on its own, and each station keeps its own copy of that thread's log.
//
// Driven by the station that has it (A), each step said to the one that takes it (B) by `handover.*`, each side's state
// in a file of its own (`handover/out/<id>.json`, `handover/in/<id>.json`: a file a hand-over, written whole, as
// retire.ts keeps its own; no table, so nothing of it is in the copies' export or the schema), so that either started
// again goes on, or undoes what it put in:
// 1. checks, refused in words that say what to do (`check`);
// 2. the chat held here (sessions/hub.ts `holdChat`): its turn not cut (a busy one refused, or waited for), no new one,
//    its process ended, its jobs stopped and kept (what the jobs module starts there, move/jobs.ts); what is said to it
//    meanwhile is kept in its threads' logs, delivered where it ends up;
// 3. its files gathered alone (carry-worker.ts `gather` with its keys, a scratch of its own), what B lacks sent
//    (sending.ts), each checked by its hash there, placed (what B made kept, to take away where it fails);
// 4. its rows sent a bounded page at a time (store/handover.ts), put in through B's store, hidden (`comingWs`);
// 5. B counts what it has; A compares; only then A says it went (store `handOff`, durably, before anyone is told),
//    sends what was said meanwhile (its logs' rest, its threads' platforms' events waited for), tells B to show it, and
//    re-points each of its platform threads where the connect runs (connects/workspace.ts `route`).
// A failure before A said it went: B takes out what it put in, the chat goes on here, its jobs started again. After,
// nothing is undone: A tells B again until it answers (on start, on failure with a backoff; never polled).
// Nothing is posted in its threads nor said in the chat; its agent is told once as its next turn starts (moved_notes).
import { randomBytes } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { mkdir, readFile, readdir, rename, rm, statfs, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { type Bytes, Refused, bytesOf, withBytes } from "../mesh/bus.ts";
import { stopBytes } from "../mesh/files.ts";
import type { Fibers } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { knownOf } from "../connects/remote.ts";
import type { Described, Known } from "../connects/remote.ts";
import { CHAT_TABLES, BY_N, MARKS, type ChatTable, type Counts, type ImportCtx, afterOf, newCtx } from "../store/handover.ts";
import type { Store } from "../store/store.ts";
import { STILLFAIL_SURFACE, comingWs, handedWs } from "../store/rows.ts";
import type { CarriedJob, CarryIndex, Gathered } from "./carry-worker.ts";
import { HASH, STATION, WORKSPACE } from "./format.ts";
import type { Ask } from "./peers.ts";
import { HEADROOM, LACK_MOST, RETRY_MOST_MS, RETRY_MS, connectsThere, gatherSoon, placeSoon, rebuildGits } from "./retire.ts";
import { lackingIn, receiveFile, sendGathered } from "./sending.ts";
import { moved } from "./restore.ts";

type Json = any;

/// How long a hand-over waits for a busy chat's turn to end, where it was asked to wait.
export const TURN_WAIT_MS = 10 * 60_000;

/// What a session's account is known by across the workspace: the share it is a copy of or the host of (`share`), the
/// key it runs with (`key`, a hash of it), or a login not shared, by its id where it is (`own`: `<id>@<station>`, the
/// id it keeps where it moves); null: this machine's own login, which cannot be had elsewhere.
export type AccountOf = { share?: string; key?: string; own?: string; name: string };

/// A step of a hand-over on the station it leaves:
/// - `held`: checked and held, its jobs stopped and kept;
/// - `files`, `rows`: being sent;
/// - `gone`: it went (B counted what it has); B is told the rest and to show it, its threads re-pointed (`told`);
/// - `failed`: it did not go, and goes on here (B is told to take out what it put in, `dropOwed`);
/// - `done`: it is there, and every thread re-pointed.
export type OutStep = "held" | "files" | "rows" | "gone" | "failed" | "done";
export type Out = {
  id: string; keys: string[]; to: string; toName: string; ws: string; at: number; step: OutStep; error: string | null;
  jobs: CarriedJob[]; dropOwed: boolean;
  /// Of each thread (by its id here): the last entry and letter sent; and what B said it has.
  sent: Record<string, { entries: number; letters: number }>; counts: Counts | null;
  /// Each session's home thread here and there (B's answer), its threads' platforms' (connect, channel, ts), and those
  /// re-pointed already.
  there: Record<string, { thread: number | null; there: number | null }>; routes: { connect: string; channel: string; threadTs: string }[]; routed: number;
  /// Whether B showed it.
  shown: boolean;
  /// What was sent and placed of its files (bytes), for the status.
  done: number; total: number;
};
/// A step of one on the station it goes to: being put in (`coming`), shown (`shown`), taken out (`dropped`).
export type In = { id: string; origin: string; keys: string[]; ws: string; at: number; step: "coming" | "shown" | "dropped"; ctx: ImportCtx; carry: string | null; error: string | null };

export type HandoverDeps = {
  data: string;
  here: () => string | null;
  home: () => string | null;
  /// The whole stations of `ws` with their names (null while not current).
  roster: (ws: string) => { id: string; name: string; tasks?: boolean }[] | null;
  ask: Ask;
  fibers: Fibers;
  store: Store;
  /// The hub (sessions/hub.ts): a chat held one at a time and let go, its turn's state, what a thread's platform said
  /// waited for, a chat woken, a connect's surface.
  hub: {
    holdChat(key: string, why: string): Promise<void>;
    releaseChat(key: string): boolean;
    wakeChat(key: string): void;
    busy(key: string): boolean;
    /// Once its turn ended (at once where none runs).
    turnEnded(key: string): Promise<void>;
    drained(connect: string, channel: string, threadTs: string): Promise<void>;
    wsOf(key: string): string | null;
  };
  /// The workspace's connects (connects/workspace.ts): a thread re-pointed where its connect runs, what one says of
  /// itself and where it runs, learnt from another station, and how one goes (null: not known here).
  connects: {
    route(id: string, channel: string, threadTs: string, station: string): Promise<void>;
    describedFor(id: string): { station: string; described: Described } | null;
    learnOf(known: Known, station: string, described: Described): void;
    kindOf(id: string): { kind: string; mode: string } | null;
    own(): string[];
  } | null;
  /// The jobs of sessions here up now (with what it takes to run them again), and stopping them; one started again
  /// here (a hand-over that failed).
  jobs: { of(keys: string[]): CarriedJob[]; stop(keys: string[], why: string): Promise<void>; start(job: CarriedJob): void };
  /// What a profile here is known by elsewhere (null: none here), and the profile here of one so known (null: none).
  accounts: { of(id: string): AccountOf | null; here(a: AccountOf): string | null };
  reposDir: string;
  room?: () => Promise<{ free: number | null }>;
  hasGit?: () => Promise<boolean>;
  git?: (dir: string, args: string[]) => Promise<string>;
  lackMost?: number;
  work?: { gather: typeof gatherSoon; place: typeof placeSoon };
  /// Told as a hand-over's state changes (the scheduler, move/).
  changed?: (id: string) => void;
  /// For a test: a step's failure made there (`files`, `rows`, `counts`, `show`).
  fail?: (step: string) => void;
};

const dir = (data: string) => join(data, "replica", "handover");
const outFile = (data: string, id: string) => join(dir(data), "out", `${id}.json`);
const inFile = (data: string, id: string) => join(dir(data), "in", `${id}.json`);
const inFiles = (data: string, id: string) => join(dir(data), "in", id, "files");
const inMade = (data: string, id: string) => join(dir(data), "in", id, "made.txt");
const scratch = (data: string, id: string) => join(dir(data), "out", id);

async function writeJson(path: string, v: unknown): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  await writeFile(tmp, JSON.stringify(v));
  await rename(tmp, path);
}

function readAll<T>(at: string): T[] {
  let names: string[] = [];
  try {
    names = readdirSync(at); // sync: read once, before the station serves
  } catch {}
  const out: T[] = [];
  for (const name of names) {
    if (!name.endsWith(".json")) continue;
    try {
      out.push(JSON.parse(readFileSync(join(at, name), "utf8")) as T); // sync: read once, before the station serves
    } catch {}
  }
  return out;
}

const roomHere = (data: string) => async () => {
  const s = await statfs(data).catch(() => null);
  return { free: s === null ? null : Number(s.bavail) * Number(s.bsize) };
};
const gb = (n: number) => `${(n / 1024 ** 3).toFixed(1)} GB`;

/// The hand-over's id: of its sessions and the station it goes to, the same each time it is asked.
export const handoverId = (keys: string[], to: string, at: number) => `${at.toString(36)}-${Buffer.from(keys[0] ?? "").toString("hex").slice(0, 24)}-${to.slice(0, 8)}`;

export class Handover {
  readonly #d: HandoverDeps;
  readonly #outs = new Map<string, Out>();
  readonly #ins = new Map<string, In>();
  readonly #runs = new Map<string, Promise<void>>();
  readonly #again = new Map<string, () => void>();
  readonly #tries = new Map<string, number>();
  readonly #work: { gather: typeof gatherSoon; place: typeof placeSoon };
  #closed = false;

  /// Where each side stood, read before the station serves: a chat being handed over is held again before its agents
  /// are taken up.
  constructor(d: HandoverDeps) {
    this.#d = d;
    this.#work = d.work ?? { gather: gatherSoon, place: placeSoon };
    for (const o of readAll<Out>(join(dir(d.data), "out"))) this.#outs.set(o.id, o);
    for (const i of readAll<In>(join(dir(d.data), "in"))) this.#ins.set(i.id, i);
    for (const o of this.#outs.values()) if (o.step === "held" || o.step === "files" || o.step === "rows") for (const key of o.keys) void d.hub.holdChat(key, `moving to ${o.toName || o.to.slice(0, 8)}`);
  }

  /// Begun (the mesh attached): each hand-over goes on where it stood. One cut before it went did not go: undone.
  async start(): Promise<void> {
    for (const o of this.#outs.values()) {
      if (o.step === "held" || o.step === "files" || o.step === "rows") await this.#fail(o, "this station started again as the chat was being handed over: it goes on here; hand it over again");
      else if (o.step === "gone" || (o.step === "failed" && o.dropOwed)) this.#go(o);
    }
  }

  async close(): Promise<void> {
    this.#closed = true;
    for (const stop of this.#again.values()) stop();
    this.#again.clear();
    await Promise.all([...this.#runs.values()].map((p) => p.catch(() => {})));
  }

  /// What is under way brought to rest (a test's).
  async settle(): Promise<void> {
    while (this.#runs.size > 0) await Promise.all([...this.#runs.values()].map((p) => p.catch(() => {})));
  }

  /// The hand-overs from here, the latest of each chat first.
  outs(): Out[] {
    return [...this.#outs.values()].sort((a, b) => b.at - a.at);
  }
  ins(): In[] {
    return [...this.#ins.values()];
  }
  /// The latest hand-over of session `key` from here (none: never).
  outOf(key: string): Out | null {
    return this.outs().find((o) => o.keys.includes(key)) ?? null;
  }

  // ── the station it leaves ──

  /// The sessions handed over with `key`: those that share its still.fail home chat (threads.home).
  together(key: string): string[] {
    const keys = new Set([key]);
    const home = this.#d.store.homeChat(key);
    if (home !== null && home.surface === STILLFAIL_SURFACE) for (const m of this.#d.store.threadSessions(home.id)) keys.add(m.session);
    return [...keys].sort();
  }

  /// Why chat `key` cannot be handed to `to` now, in words that say what to do (null: it can). `ignoreFiles`: one whose
  /// room is not the station's own goes without its files.
  check(key: string, to: string, opts: { ignoreFiles?: boolean } = {}): string | null {
    const here = this.#d.here();
    const row = this.#d.store.getSession(key);
    if (here === null || row === null) return "there is no such chat here";
    const ws = this.#d.hub.wsOf(key);
    if (ws === null || row.ws?.startsWith(handedWs("")) || row.ws?.startsWith(comingWs(""))) return "that chat is not of a workspace this station is in now (handed over already, or not shown yet here)";
    if (!WORKSPACE.test(ws) || !STATION.test(to) || to === here) return "name another station of the chat's workspace";
    const target = this.#d.roster(ws)?.find((s) => s.id === to);
    if (target === undefined) return "that station is not one of this chat's workspace's: name one station_list lists";
    if (target.tasks === true) return `${target.name} only runs tasks: a chat goes only to a whole station`;
    const busy = this.outs().find((o) => o.keys.includes(key) && (o.step === "held" || o.step === "files" || o.step === "rows" || o.step === "gone"));
    if (busy !== undefined) return busy.step === "gone" ? `that chat is going to ${busy.toName || busy.to.slice(0, 8)} already: wait for it to be there` : "that chat is being handed over already: wait for it, or look at station_move status";
    for (const k of this.together(key)) {
      const s = this.#d.store.getSession(k);
      if (s === null) continue;
      const kind = s.connect === "chat" || s.connect === "ember" ? null : this.#d.connects?.kindOf(s.connect) ?? null;
      if (kind !== null && (kind.mode === "single-session" || (kind.kind !== "slack" && kind.kind !== "feishu"))) {
        return `chat ${k} is of connect ${s.connect} (${kind.mode === "single-session" ? "one session for all its messages" : kind.kind}), whose chats run only where it runs: move the connect with its chats (station_move, module connects)`;
      }
      if (!opts.ignoreFiles && s.archivedAt === null && !s.workspace.startsWith(join(this.#d.data, "sessions"))) {
        return `chat ${k} works in ${s.workspace}, which is not this station's own: its files would not go; ask again with its files left behind if that is meant`;
      }
    }
    return null;
  }

  /// The accounts sessions `keys` run on (their sessions' and runtime sessions' profiles), as they are known across the
  /// workspace (`AccountOf`; null: this machine's own, which cannot go).
  accountsOf(keys: string[]): Map<string, AccountOf | null> {
    const out = new Map<string, AccountOf | null>();
    for (const key of keys) {
      const row = this.#d.store.getSession(key);
      if (row === null) continue;
      const ids = new Set<string>([row.profile, ...(row.profiles ?? [])]);
      for (const r of this.#d.store.chatPage("runtime_sessions", key, null, 500)) if (typeof r.profile === "string") ids.add(r.profile);
      for (const id of ids) if (!out.has(id)) out.set(id, this.#d.accounts.of(id));
    }
    return out;
  }

  /// Hands chat `key` (and those sharing its home chat) to `to`: checked, held, sent, switched; what happened said back.
  /// `wait`: a busy chat's turn is waited for (TURN_WAIT_MS at most), else refused. `progress`: how far its files went.
  async handOver(key: string, to: string, opts: { wait?: boolean; ignoreFiles?: boolean; progress?: (p: { done: number; total: number; unit: string }) => void } = {}): Promise<Out> {
    const why = this.check(key, to, opts);
    if (why !== null) throw new Refused(why);
    const keys = this.together(key);
    const ws = this.#d.hub.wsOf(key)!;
    for (const k of keys) {
      if (!this.#d.hub.busy(k)) continue;
      if (opts.wait !== true) throw new Refused(`chat ${k} is in a turn now: ask again when it ended, or with wait, which waits for it`);
      let late: () => void = () => {};
      const deadline = new Promise<"late">((resolve) => (late = this.#d.fibers.after(TURN_WAIT_MS, () => resolve("late")))); // timer: a deadline for the turn's end
      const ended = await Promise.race([this.#d.hub.turnEnded(k).then(() => "ended" as const), deadline]);
      late();
      if (ended === "late") throw new Refused(`chat ${k} was still in its turn after ${TURN_WAIT_MS / 60_000} min: ask again later`);
    }
    const name = this.#d.roster(ws)?.find((s) => s.id === to)?.name ?? "";
    const o: Out = {
      id: handoverId(keys, to, this.#d.fibers.now()), keys, to, toName: name, ws, at: this.#d.fibers.now(), step: "held", error: null, jobs: [], dropOwed: false,
      sent: {}, counts: null, there: {}, routes: [], routed: 0, shown: false, done: 0, total: 0,
    };
    this.#outs.set(o.id, o);
    for (const k of keys) await this.#d.hub.holdChat(k, `moving to ${name || to.slice(0, 8)}`);
    o.jobs = this.#d.jobs.of(keys);
    await this.#save(o);
    await this.#d.jobs.stop(keys, `its chat is being handed to ${name || "another station"}`);
    try {
      await this.#send(o, opts.progress);
    } catch (e) {
      const error = (e as Error).message;
      // (this process stopping: the next goes on from where it stood, `start`)
      if (this.#closed) throw new Refused(`this station stopped as the chat was being handed over: it goes on here once it is up again`);
      await this.#fail(o, error);
      throw new Refused(`the chat did not go to ${name || "that station"} and goes on here: ${error}`);
    }
    // (what is told after it went is told until it answers: by itself, on failure with a backoff)
    await this.#afterGone(o).catch((e) => {
      log.warn("handover", "a chat that went is not all told there yet", { id: o.id, error: (e as Error).message });
      this.#retry(o);
    });
    return o;
  }

  /// Steps 3 to 5 up to `gone`.
  async #send(o: Out, progress?: (p: { done: number; total: number; unit: string }) => void): Promise<void> {
    const here = this.#d.here()!;
    const d = this.#d;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    // Its accounts there, its connects as they are known there, said first (refused there in words).
    const accounts = Object.fromEntries([...this.accountsOf(o.keys)].map(([id, a]) => [id, a]));
    const used = [...new Set(o.keys.flatMap((k) => [d.store.getSession(k)?.connect ?? "", ...d.store.sessionThreads(k).map((t) => t.connect)]).filter((c) => c !== ""))];
    const connects = connectsThere(d.connects?.own() ?? [], used, here, o.to);
    const described: { known: Known; station: string; described: Described }[] = [];
    for (const id of used) {
      const it = d.connects?.describedFor(id);
      if (it) described.push({ known: knownOf(id, here), station: it.station, described: it.described });
    }
    const begun = await ask({ method: "handover.begin", keys: o.keys, ws: o.ws, dataDir: d.data, accounts, connects, described });
    // Its files: gathered alone, what is not there sent, placed and checked there.
    o.step = "files";
    await this.#save(o);
    const db = join(d.data, "stillfail.db");
    const g: Gathered = await this.#work.gather(d.data, db, o.ws, false, scratch(d.data, o.id), undefined, null, o.keys);
    const need = HEADROOM + g.bytes + Math.ceil(g.bytes / 20);
    if (g.gits > 0 && begun?.git === false) throw new Error(`${o.toName || "that station"} has no git, and this chat has ${g.gits} git worktree${g.gits === 1 ? "" : "s"} to be made again there: install git there first`);
    if (typeof begun?.free === "number" && need > begun.free) throw new Error(`${o.toName || "that station"} has ${gb(begun.free)} free and this chat needs ${gb(need)}: free some room there, or pick another station`);
    d.fail?.("files");
    const carry = await sendGathered(g, {
      lacking: (hashes) => ask({ method: "handover.lacking", hashes }),
      put: (hash, bytes) => d.ask(o.to, withBytes({ method: "handover.put", workspace: o.ws, origin: here, id: o.id, name: hash }, bytes)),
      most: d.lackMost ?? LACK_MOST,
      stopping: () => this.#closed,
      total: (bytes) => (o.total = bytes, progress?.({ done: 0, total: bytes, unit: "bytes" })),
      done: (bytes) => (o.done += bytes, progress?.({ done: o.done, total: o.total, unit: "bytes" })),
    }, true);
    if (carry === null) throw new Error("this station is stopping");
    const placed = await ask({ method: "handover.place", carry });
    if (typeof placed?.missing === "number" && placed.missing > 0) throw new Error(`${placed.missing} of its files are not there after they were sent`);
    // Its rows, a page at a time, then what B has compared with what was sent.
    o.step = "rows";
    await this.#save(o);
    d.fail?.("rows");
    const sent = await this.#sendRows(o, ask, null);
    const counts = (await ask({ method: "handover.counts" }))?.counts as Counts | undefined;
    d.fail?.("counts");
    const differs = counts === undefined ? "it said nothing" : differ(sent, counts);
    if (differs !== null) throw new Error(`what it has is not what was sent (${differs})`);
    // Gone: said here first, durably, before anything else is told.
    o.counts = counts!;
    o.there = Object.fromEntries(o.keys.map((k) => [k, { thread: d.store.homeChat(k)?.id ?? null, there: typeof (counts as Json).homes?.[k] === "number" ? (counts as Json).homes[k] : null }]));
    o.routes = [];
    for (const k of o.keys) {
      for (const t of d.store.sessionThreads(k)) {
        if (t.thread.surface === STILLFAIL_SURFACE || t.connect === "chat" || t.connect === "ember") continue;
        o.routes.push({ connect: t.connect, channel: t.thread.channel, threadTs: t.thread.threadTs });
      }
    }
    o.step = "gone";
    await this.#save(o);
    d.store.handOff(o.keys, o.to, d.home(), o.there);
    for (const k of o.keys) d.hub.releaseChat(k);
    await rm(scratch(d.data, o.id), { recursive: true, force: true });
    log.info("handover", "a chat went to another station", { id: o.id, to: o.to, keys: o.keys.length });
  }

  /// The chat's rows sent a page at a time (`from`: each thread's entries and letters after what was sent, alone):
  /// what was sent, counted as the station it goes to counts it.
  async #sendRows(o: Out, ask: (r: Json) => Promise<Json>, from: Out["sent"] | null): Promise<Counts> {
    const store = this.#d.store;
    const sent: Counts = { sessions: 0, entries: {}, letters: {}, rows: {} };
    const page = async (table: ChatTable, rows: Json[]) => {
      if (rows.length === 0) return;
      await ask({ method: "handover.rows", table, rows });
      if (table === "sessions") sent.sessions += rows.length;
      else if (table === "entries" || table === "letters") for (const r of rows) sent[table][String(r.thread)] = (sent[table][String(r.thread)] ?? 0) + 1;
      else if (table !== "threads") sent.rows[table] = (sent.rows[table] ?? 0) + rows.length;
    };
    const pages = async (table: ChatTable, of: number | string, after: Json = null) => {
      for (;;) {
        const rows = store.chatPage(table, of, after, 500, o.keys);
        await page(table, rows);
        if (rows.length < 500 || table === "threads" || table === "sessions" || table === "thread_sessions" || table === "opened_chats") return rows.at(-1);
        after = afterOf(table, rows.at(-1)!);
      }
    };
    if (from === null) for (const k of o.keys) await pages("sessions", k);
    for (let after = 0; ; ) {
      const threads = store.chatThreads(o.keys, after, 200);
      for (const t of threads) {
        if (from === null) await pages("threads", t);
        if (from === null) await pages("thread_sessions", t);
        const was = from?.[String(t)] ?? { entries: 0, letters: 0 };
        const lastE = await pages("entries", t, from === null ? null : was.entries);
        const lastL = await pages("letters", t, from === null ? null : was.letters);
        o.sent[String(t)] = { entries: Math.max(was.entries, Number(lastE?.n ?? 0)), letters: Math.max(was.letters, Number(lastL?.n ?? 0)) };
        if (from === null) for (const table of [...BY_N.filter((x) => x === "closed_cards"), ...MARKS]) await pages(table, t);
      }
      if (threads.length < 200) break;
      after = threads.at(-1)!;
    }
    for (const k of o.keys) {
      for (const table of (from === null ? ["turns", "runtime_sessions", "pins", "opened_chats", "deliveries"] : ["deliveries"]) as ChatTable[]) await pages(table, k);
    }
    void CHAT_TABLES;
    return sent;
  }

  /// After it went: what was said meanwhile (its logs' rest, its platforms' events waited for), then B told to show it,
  /// then each of its platform threads re-pointed where its connect runs; told until each answers.
  async #afterGone(o: Out): Promise<void> {
    const d = this.#d;
    const here = d.here()!;
    const ask = (request: Json) => d.ask(o.to, { ...request, workspace: o.ws, origin: here, id: o.id });
    if (!o.shown) {
      // (its threads of this station's own connects point there at once: what comes from now on goes there; what came
      // before is waited for, and goes with the rest of its logs)
      for (const r of o.routes) {
        if (d.connects?.describedFor(r.connect)?.station === here) await d.connects.route(r.connect, r.channel, r.threadTs, o.to);
        await d.hub.drained(r.connect, r.channel, r.threadTs);
      }
      await this.#sendRows(o, ask, o.sent);
      d.fail?.("show");
      await ask({ method: "handover.show" });
      o.shown = true;
      await this.#save(o);
    }
    for (; o.routed < o.routes.length; o.routed++) {
      const r = o.routes[o.routed]!;
      await d.connects?.route(r.connect, r.channel, r.threadTs, o.to);
      await this.#save(o);
    }
    o.step = "done";
    await this.#save(o);
  }

  /// It did not go: B told to take out what it put in (told until it answers), the chat back to work here, its jobs
  /// started again; why kept.
  async #fail(o: Out, error: string): Promise<void> {
    log.warn("handover", "a chat was not handed over: it goes on here", { id: o.id, to: o.to, error });
    o.step = "failed";
    o.error = error;
    o.dropOwed = true;
    await this.#save(o);
    for (const k of o.keys) if (!this.#d.hub.releaseChat(k)) this.#d.hub.wakeChat(k);
    for (const j of o.jobs) {
      try {
        this.#d.jobs.start(j);
      } catch (e) {
        log.warn("handover", "a job of a chat not handed over not started again", { job: j.name, error: (e as Error).message });
      }
    }
    await rm(scratch(this.#d.data, o.id), { recursive: true, force: true });
    await this.#drop(o).catch(() => this.#retry(o));
  }

  async #drop(o: Out): Promise<void> {
    const here = this.#d.here()!;
    await this.#d.ask(o.to, { method: "handover.drop", workspace: o.ws, origin: here, id: o.id });
    o.dropOwed = false;
    await this.#save(o);
  }

  /// What is owed to B told (after it went: the rest; failed: the drop), again until it answers.
  #go(o: Out): void {
    if (this.#closed || this.#runs.has(o.id)) return;
    this.#again.get(o.id)?.();
    this.#again.delete(o.id);
    const run = (o.step === "gone" ? this.#afterGone(o) : o.dropOwed ? this.#drop(o) : Promise.resolve())
      .then(() => void this.#tries.delete(o.id), () => this.#retry(o))
      .finally(() => void this.#runs.delete(o.id));
    this.#runs.set(o.id, run);
  }

  #retry(o: Out): void {
    if (this.#closed) return;
    const n = this.#tries.get(o.id) ?? 0;
    this.#tries.set(o.id, n + 1);
    this.#again.set(o.id, this.#d.fibers.after(Math.min(RETRY_MS * 2 ** n, RETRY_MOST_MS), () => this.#go(o))); // timer: a retry after a failure
  }

  /// The other station came up (its link opened): what is owed to it told now.
  reached(station: string): void {
    for (const o of this.#outs.values()) if (o.to === station && (o.step === "gone" || o.dropOwed)) this.#go(o);
  }

  async #save(o: Out): Promise<void> {
    await writeJson(outFile(this.#d.data, o.id), o);
    this.#d.changed?.(o.id);
  }
  async #saveIn(i: In): Promise<void> {
    await writeJson(inFile(this.#d.data, i.id), i);
    this.#d.changed?.(i.id);
  }

  // ── the station it goes to ──

  /// What this station answers of it (`handover.*`), from stations of the chat's workspace, of their own chats.
  answers(inWorkspace: (peer: string, ws: string) => boolean) {
    return async (peer: string, request: Json, workspace?: string): Promise<Json> => {
      const bytes = bytesOf(request);
      try {
        const ws = typeof request?.workspace === "string" ? request.workspace : "";
        const id = typeof request?.id === "string" ? request.id : "";
        if (!WORKSPACE.test(ws) || (workspace !== undefined && workspace !== ws) || !inWorkspace(peer, ws) || request?.origin !== peer) throw new Refused("not a station of this workspace");
        if (!/^[0-9a-z-]{1,80}$/.test(id)) throw new Refused("not a hand-over");
        if (request.method === "handover.begin") return await this.#begin(peer, ws, id, request);
        const i = this.#ins.get(id);
        if (request.method === "handover.drop") return await this.#dropIn(i);
        if (i === undefined || i.origin !== peer) throw new Refused("not begun: handover.begin first");
        switch (request.method) {
          case "handover.lacking": {
            const hashes = Array.isArray(request.hashes) ? request.hashes : [];
            if (hashes.length > (this.#d.lackMost ?? LACK_MOST) || !hashes.every((h: unknown) => typeof h === "string" && HASH.test(h))) throw new Refused("too many hashes");
            return { lacking: await lackingIn(inFiles(this.#d.data, id), hashes) };
          }
          case "handover.put": {
            const name = String(request.name ?? "");
            if (bytes === null || !HASH.test(name)) throw new Refused("not a file's hash");
            await receiveFile(inFiles(this.#d.data, id), name, bytes as Bytes);
            return { ok: true };
          }
          case "handover.place":
            return await this.#place(i, String(request.carry ?? ""));
          case "handover.rows": {
            if (i.step !== "coming") throw new Refused("shown already");
            const table = String(request.table ?? "") as ChatTable;
            if (!CHAT_TABLES.includes(table) || !Array.isArray(request.rows) || request.rows.length > 500) throw new Refused("not a page of a chat's rows");
            this.#d.fail?.("import");
            this.#d.store.importRows(i.ctx, table, request.rows);
            await this.#saveIn(i);
            return { ok: true };
          }
          case "handover.counts": {
            const homes: Record<string, number | null> = {};
            for (const k of i.keys) homes[k] = this.#d.store.homeChat(k)?.id ?? null;
            return { counts: { ...i.ctx.counts, homes } };
          }
          case "handover.show":
            return await this.#show(i);
        }
        throw new Refused("no such hand-over request");
      } finally {
        if (bytes !== null) await stopBytes(bytes).catch(() => {});
      }
    };
  }

  async #begin(origin: string, ws: string, id: string, request: Json): Promise<Json> {
    const was = this.#ins.get(id);
    if (was !== undefined && was.step !== "coming") throw new Refused(`that hand-over was ${was.step} here already`);
    const keys: string[] = Array.isArray(request.keys) ? request.keys.filter((k: unknown): k is string => typeof k === "string") : [];
    if (keys.length === 0) throw new Refused("no chat named");
    // Its accounts as they are here: each the profile of the same share, or of the same key; one not here refused,
    // named.
    const profiles: Record<string, string> = {};
    const missing: string[] = [];
    for (const [pid, a] of Object.entries((request.accounts ?? {}) as Record<string, AccountOf | null>)) {
      const here = a === null ? null : this.#d.accounts.here(a);
      if (here === null) missing.push(a?.name || pid);
      else profiles[pid] = here;
    }
    if (missing.length > 0) throw new Refused(`the account${missing.length === 1 ? "" : "s"} ${missing.join(", ")} ${missing.length === 1 ? "is" : "are"} not usable on this station: move or share ${missing.length === 1 ? "it" : "them"} here first (station_move, module accounts)`);
    for (const x of Array.isArray(request.described) ? request.described : []) {
      if (x?.known && typeof x.station === "string" && x.described) this.#d.connects?.learnOf(x.known, x.station, x.described);
    }
    const strings = (v: Json) => Object.fromEntries(Object.entries(v ?? {}).filter((e): e is [string, string] => typeof e[1] === "string"));
    const i: In = was ?? {
      id, origin, keys, ws, at: this.#d.fibers.now(), step: "coming", carry: null, error: null,
      ctx: newCtx({ from: origin, fromData: String(request.dataDir ?? ""), toData: this.#d.data, connects: strings(request.connects), profiles, ws: comingWs(ws) }),
    };
    this.#ins.set(id, i);
    await this.#saveIn(i);
    const [room, git] = await Promise.all([(this.#d.room ?? roomHere(this.#d.data))().catch(() => ({ free: null })), (this.#d.hasGit ?? (async () => true))().catch(() => false)]);
    return { ok: true, free: room.free, git };
  }

  async #place(i: In, carry: string): Promise<Json> {
    if (!HASH.test(carry)) throw new Refused("not a copy's name");
    const files = inFiles(this.#d.data, i.id);
    const index = join(files, carry);
    const placed = await this.#work.place(this.#d.data, index, files, inMade(this.#d.data, i.id));
    const c = JSON.parse(await readFile(index, "utf8")) as CarryIndex;
    if (c.gits.length > 0 && this.#d.git !== undefined) await rebuildGits(this.#d.data, this.#d.reposDir, c, files, this.#d.git);
    i.carry = carry;
    await this.#saveIn(i);
    return { ok: true, placed: placed.placed, missing: placed.missing };
  }

  /// Shown: of its workspace here, its agents told once where it runs now; its jobs are the jobs module's to start.
  async #show(i: In): Promise<Json> {
    if (i.step === "shown") return { ok: true };
    const home = this.#d.home();
    this.#d.store.showChat(i.keys, i.ws === home ? null : i.ws);
    const from = this.#d.roster(i.ws)?.find((s) => s.id === i.origin)?.name || i.origin.slice(0, 12);
    for (const k of i.keys) {
      const row = this.#d.store.getSession(k);
      if (row === null) continue;
      this.#d.store.setMovedNote(k, movedHere(from, row.workspace, i.ctx.fromData, this.#d.data));
    }
    i.step = "shown";
    await this.#saveIn(i);
    await rm(join(dir(this.#d.data), "in", i.id), { recursive: true, force: true });
    for (const k of i.keys) this.#d.hub.wakeChat(k);
    log.info("handover", "a chat handed here goes on here", { id: i.id, origin: i.origin, keys: i.keys.length });
    return { ok: true };
  }

  /// What a hand-over that did not go put in here, taken out: its rows (store `dropImport`) and the files placed where
  /// nothing was.
  async #dropIn(i: In | undefined): Promise<Json> {
    if (i === undefined || i.step === "dropped") return { ok: true };
    if (i.step === "shown") throw new Refused("it is shown here: it went");
    this.#d.store.dropImport(i.ctx);
    const made = await readFile(inMade(this.#d.data, i.id), "utf8").catch(() => "");
    for (const path of made.split("\n")) if (path !== "") await rm(path, { force: true }).catch(() => {});
    i.step = "dropped";
    await this.#saveIn(i);
    await rm(join(dir(this.#d.data), "in", i.id), { recursive: true, force: true });
    return { ok: true };
  }
}

/// Where what was sent and what it has differ, in words (null: they do not).
function differ(sent: Counts, there: Counts): string | null {
  if (sent.sessions !== there.sessions) return `${sent.sessions} sessions sent, ${there.sessions} there`;
  for (const k of ["entries", "letters"] as const) {
    for (const [t, n] of Object.entries(sent[k])) if ((there[k][t] ?? 0) !== n) return `${n} ${k} of a thread sent, ${there[k][t] ?? 0} there`;
  }
  for (const [t, n] of Object.entries(sent.rows)) if ((there.rows[t] ?? 0) !== n) return `${n} rows of ${t} sent, ${there.rows[t] ?? 0} there`;
  return null;
}

/// What a chat handed here is told once, as its next turn starts: where it runs now, where its files are.
export function movedHere(from: string, workspace: string, fromData: string, toData: string): string {
  const lines = [`<chat-moved>This chat was handed here from station ${from}: it goes on on this station.`];
  if (fromData !== "" && fromData !== toData) lines.push(`Its files were under ${fromData} and are under ${toData} now: a path you noted under the old one is the same under the new one (your working directory is ${moved(workspace, fromData, toData)}).`);
  lines.push("Its background jobs are started again here as they move; nobody asked anything of you by this, and it is said once.</chat-moved>");
  return lines.join("\n");
}
