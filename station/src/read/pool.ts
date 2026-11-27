// The readers: processes of the MoonBit program (read/mb-reader.ts, `--data`), each with its own read-only connection,
// in lines that share none of them: the store's log written into the database (`log`), the pages of sessions'
// histories (`pages`), and every other read (`moved`), what devices ask and what the station tells alike. Among them,
// bulk reads leave room for chat reads. None of these reads holds up writes. They are started when reads come and let
// go once none has come for a while, but for the first of `moved`. One that dies fails what it held and is replaced by
// the next read. There is no reader thread in TypeScript to fall back to: how one answered the reads before the
// program took them is the tests' (test/reference-worker.ts, given a test's Readers by test/reference.ts as
// `reference`, which answers on the lines of before: `told` for what the station tells, `asked` for what devices ask).
import { availableParallelism, homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { catalog } from "../accounts/catalog.ts";
import { tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import type { InWorkspace } from "../store/rows.ts";
import { MinuteReader } from "../usage/minute-reader.ts";
import { OutflowChatIndex } from "./chat-index-builder.ts";
import { SaidBuilder } from "./said-builder.ts";
import { RequestedBuilder } from "./requested-builder.ts";
import { TurnBuilder } from "./turn-builder.ts";
import { RecentChatBuilder } from "./recent-chat-builder.ts";
import { RECENT_CHAT_PENDING } from "./recent-chat.ts";
import { SessionListBuilder } from "./session-list-builder.ts";
import { SESSION_LIST_PENDING } from "../store/session-list-index.ts";
import { SessionBindingsBuilder } from "./session-bindings-builder.ts";
import { ArchiveMarkBuilder } from "./archive-mark-builder.ts";
import { JobNameFirstBuilder, SessionUpJobsBuilder } from "./session-up-jobs-builder.ts";
import { WorkspaceUpJobsBuilder } from "./workspace-up-jobs-builder.ts";
import { WidgetSourcesBuilder } from "./widget-sources-builder.ts";
import { CcIndexBuilder } from "./cc-index-builder.ts";
import { CardPostsBuilder, ClosedCardsBuilder, PeopleSinceBuilder } from "./card-posts-builder.ts";
import { CC_SESSIONS_PENDING } from "../store/cc-thread-index.ts";
import { JOB_NAME_FIRST_PENDING } from "../store/job-name-first.ts";
import { CARD_POSTS_PENDING } from "../store/card-post-index.ts";
import { CLOSED_CARDS_PENDING } from "../store/legacy-closed-cards.ts";
import { PEOPLE_TIME_PENDING } from "../store/legacy-people-since.ts";
import { SESSION_BINDINGS_PENDING } from "../store/session-bindings-index.ts";
import { OUTFLOW_CHATS_PENDING } from "./outflow.ts";
import { LAST_MESSAGE_PENDING, LEGACY_EDITS_PENDING, LEGACY_SAID_PENDING, PAGE_LETTER_PENDING, REMOTE_RUNS_PENDING, SAID_PENDING, TURN_COUNT_PENDING, USAGE_CHATS_PENDING } from "./store.ts";
import { HttpError } from "./views.ts";
import { repairMergedEditLookup } from "../store/schema.ts";
import { EventEmitter } from "node:events";
import { type Answer, type Ask, type BackfillOptions, MbReader, type ReaderLike, type Ready, type ResolvedReaderSelection, breakerOfSelection, engineOfSelection, fallbackModeOf, mbReaderBinary, pionBinary, resolveReaderSelectionAsync, resolveReaderSelectionOrPending } from "./mb-reader.ts";
import { type PionBinaryStamp, pionCircuitBreaker } from "./pion-breaker.ts";
import { resolveReaderEngine } from "./reader-select.ts";
import { type TelemetryEngine, readerTelemetry } from "./reader-telemetry.ts";
import { wall } from "../ops/fibers.ts";
import { roots as machineRoots } from "./machine.ts";
import { platform } from "../platform/index.ts";
import type { CardEditPage, CardMessagePage } from "../store/card-outbox.ts";

/// How long a reader with nothing to do is kept.
const IDLE_MS = 60_000;
/// What a read is refused with while what it needs is prepared first (`answer` prepares it and asks again): each the
/// start of such a refusal's words. What answers a read elsewhere (mesh/served.ts) gives such a one back to be read here.
export const READS_PENDING = [LEGACY_EDITS_PENDING, LEGACY_SAID_PENDING, PAGE_LETTER_PENDING, LAST_MESSAGE_PENDING, SESSION_BINDINGS_PENDING,
  CC_SESSIONS_PENDING, JOB_NAME_FIRST_PENDING, CARD_POSTS_PENDING, CLOSED_CARDS_PENDING, PEOPLE_TIME_PENDING, TURN_COUNT_PENDING,
  SAID_PENDING, USAGE_CHATS_PENDING, REMOTE_RUNS_PENDING, OUTFLOW_CHATS_PENDING, RECENT_CHAT_PENDING,
  SESSION_LIST_PENDING];

/// A read that waited or took longer than this is logged, with what it was.
const SLOW_MS = 2_000;

/// `held`: the read it is answering, if any.
/// `binary`: the resolved binary path spawned for this slot (used to retire idle slots on hot config change).
type Slot = { worker: ReaderLike; held: Asked | null; idle?: () => void; retiring?: boolean; catalogVersion: number; binary?: string; engine?: TelemetryEngine; spawnedAt?: number; pionStamp?: PionBinaryStamp | null };

/// Deferred `ReaderLike` handle that reserves a pool `Slot` while a cold Pion `--version`
/// capability probe is in flight, without calling `readerBinary()` synchronously.
/// Handles `postMessage` queueing, `terminate()` during probe (zero orphan spawn), and probe failure.
class DeferredMbReader extends EventEmitter implements ReaderLike {
  #inner: MbReader | null = null;
  #queued: Ask[] = [];
  #terminated = false;
  #exited = false;
  readonly #onSpawned: (binary: string, engine: TelemetryEngine, spawnedAt: number, pionStamp: PionBinaryStamp | null | undefined) => void;

  constructor(data: string, resolveSelection: () => Promise<ResolvedReaderSelection>, onSpawned: (binary: string, engine: TelemetryEngine, spawnedAt: number, pionStamp: PionBinaryStamp | null | undefined) => void) {
    super();
    this.#onSpawned = onSpawned;
    void resolveSelection().then(
      (resolved) => {
        if (this.#terminated || this.#exited) return;
        let child: MbReader;
        const engine = engineOfSelection(resolved);
        const spawnedAt = wall.now();
        try {
          child = new MbReader(resolved.primaryBinary, data, { engine, fallbackMode: fallbackModeOf(resolved.selection), breaker: breakerOfSelection(resolved) });
        } catch (err) {
          this.#exited = true;
          this.emit("error", err instanceof Error ? err : new Error(String(err)));
          this.emit("exit", 1);
          return;
        }
        this.#inner = child;
        this.#onSpawned(resolved.primaryBinary, child.engine, spawnedAt, resolved.pionStamp);
        child.on("message", (msg) => this.emit("message", msg));
        child.on("error", (err) => this.emit("error", err));
        child.on("exit", (code) => {
          this.#exited = true;
          this.emit("exit", code);
        });
        for (const ask of this.#queued.splice(0)) child.postMessage(ask);
      },
      (err) => {
        if (this.#terminated || this.#exited) return;
        this.#exited = true;
        this.emit("error", err instanceof Error ? err : new Error(String(err)));
        this.emit("exit", 1);
      },
    );
  }

  postMessage(ask: Ask): void {
    if (this.#terminated || this.#exited) return;
    if (this.#inner !== null) this.#inner.postMessage(ask);
    else this.#queued.push(ask);
  }

  terminate(): Promise<number> {
    if (this.#inner !== null) return this.#inner.terminate();
    this.#terminated = true;
    this.#queued.length = 0;
    if (!this.#exited) {
      this.#exited = true;
      queueMicrotask(() => this.emit("exit", 0));
    }
    return Promise.resolve(0);
  }

  getHeapStatistics(): Promise<{ used_heap_size: number }> {
    return this.#inner !== null ? this.#inner.getHeapStatistics() : Promise.resolve({ used_heap_size: 0 });
  }
}

/// A read in line or being answered: when it was asked and when a reader took it, and the reader it is best read in (a
/// session's history, where its reading stands in memory).
type Asked = {
  ask: Ask;
  session: string | null;
  home: Slot | null;
  /// After every other read waiting, one at a time (`read`).
  background: boolean;
  at: number;
  took: number;
  resolve: (text: Text) => void;
  reject: (error: Error) => void;
};

/// A read's answer: its text, or its bytes as the MoonBit reader gave them (never decoded where they are only passed on:
/// `readBytes`).
type Text = string | Buffer;

/// A line of reads and the readers that answer it, at most `size` of them, the first read first. `room`: bulk reads leave
/// one of them for a chat read (what devices ask).
/// `rested`: when a background read may be taken again (one just read rests as long as it took).
/// `wake`: the line looked at again once it has rested (one at a time).
type Line = { told: boolean; size: number; room: boolean; slots: Slot[]; waiting: Asked[]; rested?: number; wake?: () => void };

/// How many sessions' readers are remembered (the most recently read).
const HOMES = 4096;
/// How long after the store changes its log is written into the database (`checkpointSoon`): at most this often.
const CHECKPOINT_MS = 2_000;
/// Writing the store's log into the database (main.mbt `checkpoint`) is no read and waits for no one: it has a reader
/// of its own (`log`). In line behind reads, a checkpoint may wait as the log grows until the main connection writes it
/// at its next commit (store.ts WAL_PAGES); on a device reader it can hold up interactive reads while reaching disk.
const CHECKPOINT = "checkpoint";
const cancelled = () => new HttpError(503, "read cancelled");
/// The scoped reads on the path to showing a chat, and those a device's lists are made of, each of a few rows and the
/// statistics kept of them (the sidebar, a session's detail and summary, a chat's latest messages). Other page reads,
/// including new kinds not yet classified, leave room for these, and these go before them: a slow transcript or resource
/// snapshot can block just as a slow aggregate can. A machine sample (api/host.ts), one job, the jobs up without
/// their chats, and a session's messages waiting for it (`pendingDeliveries`, on the way of a message to its agent) are
/// interactive too; jobs with their chats (an older device's, the sidebar made for it) are a bulk read.
const INTERACTIVE = new Set(["thread", "chats", "sharedChats", "chatMarks", "session", "summary", "latestMessages", "openedChatSaid", "chatHistoryMessages", "historyPendingCard", "stateQuestion", "statePendingCard", "deliveryCardState", "pendingDeliveries", "job"]);

/// One thread's current or older page is interactive. An `after` or explicit range can ask for an unbounded amount on
/// older clients, so it remains in the background until that request is paged end to end.
function interactive(a: Asked): boolean {
  if (INTERACTIVE.has(a.ask.op)) return true;
  if (a.ask.op === "changed") return (a.ask.args as { op?: unknown } | undefined)?.op === "sharedChats";
  if (a.ask.op === "openJobs") return a.ask.args?.chats === false;
  if (a.ask.op !== "entries" && a.ask.op !== "letters") return false;
  const params = a.ask.args?.params;
  const keys = Array.isArray(params) ? params.map((p: unknown) => Array.isArray(p) ? p[0] : null) : Object.keys(params ?? {});
  return !keys.includes("after") && !keys.includes("from") && !keys.includes("to");
}

/// A stretch of a session's history in brief (`from` and `to`): what a client fills in of it in the background, where its
/// stream left a hole or it holds less than there is (client/core-ts/src/station/channel-kinds.ts TRANSCRIPT). Up to
/// 1,000 items a read, 16 MB of a Codex transcript and 6 s on a station (2026-11-03), the sidebar waiting 9 s behind them.
/// One read whole (a step opened) is someone's waiting on it.
function filling(op: string, args: unknown): boolean {
  const a = args as { from?: unknown; to?: unknown; brief?: unknown } | null;
  return op === "timeline" && a !== null && typeof a.from === "string" && typeof a.to === "string" && a.brief === "1";
}

/// Reads by the pages' readers (`pages`): a history's pages, and the machine's own sessions (GET /machine-sessions, a walk
/// of every Claude and Codex project there, 14 s on a station, 2026-11-03), each of the files on the disk rather than the
/// database.
const PAGES = new Set(["timeline", "machineSessions"]);
/// A session's history, read by the MoonBit reader (station/mb src/history's transcripts.mbt) where its program is
/// there, on the pages' readers still: both its pages and where its reading stands (`transcriptState`, its live view's
/// start), so that each reads on from what the reader it was read in last keeps (`homes`); and what a watched transcript
/// gains (`tailRead`, sessions/live.ts), a file read as theirs are: on the readers of the database's reads, one bulk
/// slot among every bulk read, 34 of them queued up to 5 s at once on a busy station and the reads behind them too
/// (mm2, 2026-11-23).
const HISTORY = new Set(["timeline", "transcriptState", "tailRead"]);
/// The reads the MoonBit reader answers itself (station/mb src/readops), on readers of their own (`moved`): with HISTORY
/// and the checkpoint, every read there is.
const MOVED = new Set(["job", "jobLog", "historyPendingCard", "statePendingCard", "deliveryCardState", "reviewPendingCard", "stateQuestion", "pendingDeliveries", "latestMessages", "chatHistoryMessages", "openedChatSaid", "widgetState", "transcriptFile", "memory", "machineSessions", "machineSession", "sessionsAtWork", "policyChecks", "recentConnectPeople", "usageTurns", "usageCalls", "outflowMessages", "archiveLook", "recentChatList", "searchChatList", "threadList", "sharedOf", "sharedChats", "chatMarks", "entries", "letters", "summary", "sessions", "session", "threads", "thread", "turnNotices", "saidNotices", "chats", "chatRows", "outflowChats", "openJobs", "resourceChats", "usage", "outflowUsage", "sessionPlace", "changed", "internalCardEditPage", "internalCardMessagePage", "internalMeshControl"]);
/// The reads of this machine's own Claude Code and Codex sessions: the MoonBit reader is told where they are kept, from
/// this process's environment (read/machine.ts `roots`).
const MACHINE = new Set(["machineSessions", "machineSession"]);
/// A file a session's message names (read/sessions.ts `sessionPlace`): the program is given what only this process
/// knows (its HOME, its home directory, whether macOS's folder permissions apply) and the time (the git listings it
/// keeps a minute, macOS's mounts two seconds). It refuses by the key of its words, which the client says.
const placeOf = (args: unknown) => {
  return {
    ...(args as object),
    env: { home: process.env.HOME ?? "", homedir: homedir(), mac: platform.hasFolderPermissions },
    now: wall.now(),
  };
};
/// The reads that go by the time of day (a share used lately, a card answered lately): the MoonBit reader's clock is no
/// wall's, so it is given the time as the read is asked. A device's reads are given no words: what a station would
/// say there (a chat with no name, the local page and its admin, a refusal) the client says in its own language (the
/// owner, 2026-11-09; core-ts chat-row.ts `worded`, entries.ts `authorNameOf`). Only what the station says itself is
/// worded: its notices (a file's, an unnamed chat's) and what it sends Comma (`SAID`).
const WORDED = new Set(["sharedOf", "sharedChats", "chatMarks", "entries", "letters", "summary", "sessions", "session", "threads", "thread", "turnNotices", "saidNotices", "chats", "chatRows", "outflowChats", "openJobs", "resourceChats", "usage"]);
/// The reads whose words the station says itself, in the language asked.
const SAID = new Set(["turnNotices", "saidNotices", "outflowChats"]);
const wordsIn = (op: string, lang: Ask["lang"]) => !SAID.has(op) ? {} : {
  localPage: tr(lang, "station.creator.localPage"), admin: tr(lang, "station.author.admin"),
  ...(op === "turnNotices" || op === "saidNotices" ? { file: tr(lang, "station.notice.file"), untitled: tr(lang, "station.chat.untitled") } : {}),
  ...(op === "outflowChats" ? { untitled: tr(lang, "station.chat.untitled"), directMessage: tr(lang, "station.chat.directMessage") } : {}),
};

/// `changed`'s list's own args, given the words and the time its read is given (`WORDED`).
const changedOf = (args: unknown, lang: Ask["lang"]) => {
  const a = args as { op: string; args?: unknown };
  return { ...a, args: { ...(a.args as object), words: wordsIn(a.op, lang), now: wall.now() } };
};

export class Readers {
  /// What devices ask, and what the station tells (`told`), each answered by readers of its own.
  private asked: Line;
  /// The pages of sessions' histories (`timeline`), by a reader of their own: a page is read from the mark before it
  /// (read/transcripts.ts), megabytes of a long transcript, seconds from a disk short of memory; in line with what
  /// devices ask, the sidebar and a chat opened waited 20 s and more behind them on a station (2026-11-03).
  private pages: Line;
  private told: Line;
  /// The store's log written into the database (CHECKPOINT), by a reader of its own.
  private log: Line;
  /// The reads the MoonBit reader answers (MOVED), for devices and streams alike.
  private moved: Line;
  /// The reader each session's history was last read in (`timeline`).
  private homes = new Map<string, Slot>();
  private next = 0;
  private closed = false;
  private minutes: MinuteReader | null = null;
  /// What else lets go of what answers nothing when the station is short of memory (`onTrim`, `trimIdle`).
  private trims: (() => number)[] = [];
  private outflowChats: OutflowChatIndex | null = null;
  private said: SaidBuilder | null = null;
  private archiveLast: RequestedBuilder<number> | null = null;
  private legacyEdits: RequestedBuilder<number> | null = null;
  private legacySaid: RequestedBuilder<number> | null = null;
  private pageLetters: RequestedBuilder<number> | null = null;
  private turns: TurnBuilder | null = null;
  private recentChats: RecentChatBuilder | null = null;
  private sessionList: SessionListBuilder | null = null;
  private sessionBindings: SessionBindingsBuilder | null = null;
  private archiveMarks: ArchiveMarkBuilder | null = null;
  private sessionUpJobs: SessionUpJobsBuilder | null = null;
  private workspaceUpJobs: WorkspaceUpJobsBuilder | null = null;
  private jobNameFirst: JobNameFirstBuilder | null = null;
  private preparingWorkspaceUpJobs = false;
  /// Reads of the same old session share one unattended preparation, including during handover.
  private preparingUpJobs = new Set<string>();
  private widgetSources: WidgetSourcesBuilder | null = null;
  private cardPosts: CardPostsBuilder | null = null;
  private closedCards: ClosedCardsBuilder | null = null;
  private peopleSince: PeopleSinceBuilder | null = null;
  private ccIndex: CcIndexBuilder | null = null;
  /// A checkpoint is armed or running (`checkpointSoon`), and the store changed again since it was armed.
  private checkpointing = false;
  private again = false;
  /// The station's data directory, whose database they read.
  readonly data: string;
  /// What answers in a program's place: a test's reference (test/reference.ts).
  private readonly reference: ((data: string) => ReaderLike) | undefined;
  private readonly backfill: BackfillOptions;
  /// People's names as their credentials say them (the admin API's `deps.names`), given to every read.
  readonly names = new Map<string, string>();
  /// Explicit `mbReader` binary override set by tests (`Object.assign(new Readers(...), { mbReader: mb })`).
  /// When set, `start()` ALWAYS spawns `#explicitBinary` and never auto-selects.
  #explicitOverride = false;
  #explicitBinary: string | null = null;
  /// The MoonBit/Pion reader's program (read/mb-reader.ts); `null` where a test's reference answers instead (`reference`).
  /// In auto-selection mode, returns a stable non-null identity `"auto"` with zero disk probes on the main thread.
  get mbReader(): string | null {
    if (this.#explicitOverride) return this.#explicitBinary;
    if (this.reference !== undefined) return null;
    return "auto";
  }
  set mbReader(v: string | null) {
    this.#explicitOverride = true;
    this.#explicitBinary = v;
  }
  /// Non-null ONLY when an explicit `mbReader` override was assigned (distinguishes explicit test overrides
  /// from auto-selection mode in `mesh.ts`).
  get explicitMbReader(): string | null {
    return this.#explicitOverride ? this.#explicitBinary : null;
  }
  /// The store's schema repaired by the station's writer, where a builder leaves it to it (`prepareLegacyEdits`: the
  /// merged view, an index under it dropped by an older station): store/schema.ts `repairMergedEditLookup` on the main
  /// connection, waiting for no lock (services.ts); one found busy is tried again after a pause. None given: on a
  /// connection of its own, made for it.
  repairEdits: (() => void) | null = null;
  /// What only the hub knows, given to every read: sessions' process states and client keys (the hub sets these).
  processes: () => Map<string, string> = () => new Map();
  clientKeys: () => Map<string, string> = () => new Map();

  /// For what devices ask, at most two by default (STILLFAIL_READERS says otherwise); for what is told, `tellers`.
  constructor(data: string, size = Number(process.env.STILLFAIL_READERS) || Math.min(2, Math.max(1, availableParallelism() - 1)), reference?: (data: string) => ReaderLike, tellers = 1, backfill: BackfillOptions = {}) {
    this.data = data;
    this.reference = reference;
    this.backfill = backfill;
    this.asked = { told: false, size, room: true, slots: [], waiting: [] };
    // Two: one a background page (a history brought on, a stretch filled) may hold, one left for a page someone waits on.
    this.pages = { told: false, size: 2, room: false, slots: [], waiting: [] };
    this.told = { told: true, size: tellers, room: false, slots: [], waiting: [] };
    this.log = { told: true, size: 1, room: false, slots: [], waiting: [] };
    this.moved = { told: false, size, room: true, slots: [], waiting: [] };
  }

  /// Check statistical coverage without occupying a device reader or writing old history.
  startUsageIndex() {
    if (this.closed) return;
    if (this.minutes === null) this.minutes = new MinuteReader(join(this.data, "stillfail.db"), this.backfill);
    this.minutes.start();
  }

  /// Current synchronous auto-selection state (`bypass` for explicit/reference, `binary`, `pending`, or `unavailable`).
  #currentAutoSelection():
    | { kind: "bypass" }
    | { kind: "pending" }
    | { kind: "unavailable" }
    | { kind: "binary"; binary: string } {
    if (this.#explicitOverride || this.reference !== undefined) return { kind: "bypass" };
    try {
      const sel = resolveReaderSelectionOrPending("data", { config: this.backfill.readers, logAt: "readers" });
      return sel.pending ? { kind: "pending" } : { kind: "binary", binary: sel.primaryBinary };
    } catch {
      return { kind: "unavailable" };
    }
  }

  /// Retire idle slots (including idle `kept` slots) whose spawned binary no longer matches the current
  /// live `"data"` reader selection, or ALL idle slots when hot-switched to an unavailable/pending target.
  /// In-flight slots finish cleanly; once idle they will be retired on the next pump before serving new reads.
  retireMismatchedIdle(targetLine?: Line): number {
    if (this.closed || this.#explicitOverride || this.reference !== undefined) return 0;
    const lines = targetLine !== undefined ? [targetLine] : [this.asked, this.told, this.pages, this.log, this.moved];
    if (!lines.some((line) => line.slots.some((s) => s.held === null && !s.retiring))) return 0;
    const config = typeof this.backfill.readers === "function" ? this.backfill.readers() : this.backfill.readers;
    // Optimistically pass `hasPionBinary: true` to stay disk-free here; if the Pion binary is
    // actually absent on disk, `pionBin === null` below falls through to `#currentAutoSelection()`.
    const probe = resolveReaderEngine("data", { config, hasPionBinary: true });
    const breaker = config?.breaker === null ? null : (config?.breaker ?? pionCircuitBreaker);
    const mbBin = probe.engine === "mb" ? mbReaderBinary() : undefined;
    const pionBin = probe.engine === "pion" ? pionBinary() : undefined;
    let fallbackSelection:
      | { kind: "bypass" }
      | { kind: "pending" }
      | { kind: "unavailable" }
      | { kind: "binary"; binary: string }
      | undefined;
    const currentAuto = () => (fallbackSelection ??= this.#currentAutoSelection());
    let retired = 0;
    for (const line of lines) {
      for (const slot of line.slots.filter((s) => {
        if (s.held !== null || s.retiring) return false;
        if (probe.engine === "mb") {
          return mbBin === null || (s.binary !== undefined && s.binary !== mbBin);
        }
        // Steady-state Pion fast path: stay stat-free on the per-read pump hot path (only check
        // in-memory config/path and breaker state), so warm idle Pion readers do not call `statSync`
        // on every read nor get retired mid-auto-update while `<app>/` is being swapped.
        if (probe.engine === "pion" && pionBin !== null && s.engine === "pion" && s.binary === pionBin) {
          return probe.source === "default" && breaker !== null && breaker.isDemoted("data", s.pionStamp ?? null) && mbReaderBinary() !== null;
        }
        const cur = currentAuto();
        if (cur.kind === "bypass") return false;
        if (cur.kind === "unavailable") return true;
        if (cur.kind === "pending") return s.binary !== undefined;
        return s.binary !== undefined && s.binary !== cur.binary;
      })) {
        slot.idle?.();
        slot.idle = undefined;
        slot.retiring = true;
        line.slots = line.slots.filter((s) => s !== slot);
        void slot.worker.terminate();
        retired++;
      }
    }
    return retired;
  }

  private start(line: Line): { slot: Slot } | { error: Error } {
    let worker: ReaderLike;
    let spawnedBinary: string | undefined;
    let spawnedEngine: TelemetryEngine | undefined;
    let spawnedAt: number | undefined;
    let spawnedStamp: PionBinaryStamp | null | undefined;
    if (this.#explicitOverride) {
      if (this.#explicitBinary !== null) {
        spawnedBinary = this.#explicitBinary;
        spawnedAt = wall.now();
        const reader = new MbReader(this.#explicitBinary, this.data);
        spawnedEngine = reader.engine;
        worker = reader;
      } else if (this.reference !== undefined) {
        worker = this.reference(this.data);
      } else {
        return { error: new Error("reader binary is disabled") };
      }
    } else if (this.reference !== undefined) {
      worker = this.reference(this.data);
    } else {
      try {
        const sel = resolveReaderSelectionOrPending("data", { config: this.backfill.readers, logAt: "readers" });
        if (sel.pending) {
          worker = new DeferredMbReader(
            this.data,
            () => resolveReaderSelectionAsync("data", { config: this.backfill.readers, logAt: "readers" }),
            (bin, eng, at, stamp) => { slot.binary = bin; slot.engine = eng; slot.spawnedAt = at; slot.pionStamp = stamp; },
          );
        } else {
          spawnedBinary = sel.primaryBinary;
          spawnedAt = wall.now();
          spawnedStamp = sel.pionStamp;
          const reader = new MbReader(sel.primaryBinary, this.data, { engine: engineOfSelection(sel), fallbackMode: fallbackModeOf(sel.selection), breaker: breakerOfSelection(sel) });
          spawnedEngine = reader.engine;
          worker = reader;
        }
      } catch (err) {
        return { error: err instanceof Error ? err : new Error(String(err)) };
      }
    }
    const slot: Slot = { worker, held: null, catalogVersion: 0, binary: spawnedBinary, engine: spawnedEngine, spawnedAt, pionStamp: spawnedStamp };
    const slotEngine = (): TelemetryEngine | null => slot.engine ?? (slot.worker instanceof MbReader ? slot.worker.engine : null);
    const begun = wall.now();
    worker.on("message", (answer: Answer | Ready) => {
      // How long a reader took to start: a read given it as it starts waits on that (one read of 1.9 s took 18 s on
      // a station short of memory, 2026-11-03, a reader started for it).
      if (answer !== null && typeof answer === "object" && "ready" in answer) {
        const ms = wall.now() - (slot.spawnedAt ?? begun);
        const engine = slotEngine();
        const ready = answer.ready !== null && typeof answer.ready === "object" ? (answer.ready as Record<string, unknown>) : null;
        if (ms >= 1_000) log.warn("readers", "a reader started slowly", { ...(engine !== null ? { engine } : {}), mode: "data", ms, line: line === this.asked ? "asked" : line === this.pages ? "pages" : line === this.log ? "log" : line === this.moved ? "moved" : "told", ...(ready ?? {}) });
        return;
      }
      // An abandoned read may finish while its reader is being stopped. Do not give that reader another read until it exits.
      if (slot.retiring) return;
      const asked = slot.held;
      slot.held = null;
      if (asked !== null && asked.ask.id === answer.id) {
        const now = wall.now();
        const execMs = now - asked.took;
        const engine = slotEngine();
        const text = answer.body ?? answer.text;
        if (engine !== null) readerTelemetry.recordCall(engine, "data", execMs, text !== undefined);
        if (now - asked.at > SLOW_MS) log.warn("readers", "a read went slowly", { ...(engine !== null ? { engine } : {}), mode: "data", op: asked.ask.op, ...(asked.session !== null ? { session: asked.session, home: asked.home === slot } : {}), told: line.told, waitedMs: asked.took - asked.at, ms: execMs });
        // A background read rests its line as long as it took before the next: one after another, a history brought on
        // read 40 MB of a transcript in 10 s on a station short of memory (2026-11-03), every write and read waiting on the
        // disk meanwhile.
        if (asked.background) line.rested = now + execMs;
        if (text !== undefined) {
          const session = answer.prepareUpJobs;
          if (session !== undefined && !this.preparingUpJobs.has(session)) {
            this.preparingUpJobs.add(session);
            void this.prepareSessionUpJobs([session]).catch((error) => {
              if (!this.closed) log.warn("readers", "preparing a session's up jobs failed", { error: (error as Error).message });
            }).finally(() => this.preparingUpJobs.delete(session));
          }
          if (answer.prepareWorkspaceUpJobs && !this.preparingWorkspaceUpJobs) {
            this.preparingWorkspaceUpJobs = true;
            void this.prepareWorkspaceUpJobs().catch((error) => {
              if (!this.closed) log.warn("readers", "preparing workspace up jobs failed", { error: (error as Error).message });
            }).finally(() => { this.preparingWorkspaceUpJobs = false; });
          }
          asked.resolve(text);
        }
        else asked.reject(new HttpError(answer.status ?? 500, answer.error ?? "read failed"));
      }
      this.pump(line);
    });
    worker.on("error", (error) => {
      const engine = slotEngine();
      log.error("readers", "a reader failed", { ...(engine !== null ? { engine } : {}), mode: "data", error: error.message, reading: slot.held?.ask.op ?? null });
    });
    worker.on("exit", (code) => {
      slot.idle?.();
      line.slots = line.slots.filter((s) => s !== slot);
      if (slot.held !== null) {
        if (!slot.retiring && !this.closed) {
          const engine = slotEngine();
          if (engine !== null) readerTelemetry.recordCall(engine, "data", wall.now() - slot.held.took, false);
        }
        slot.held.reject(new HttpError(500, `the reader stopped (exit ${code})`));
        slot.held = null;
      }
      this.pump(line);
    });
    line.slots.push(slot);
    return { slot };
  }

  /// A reader with nothing to do goes after IDLE_MS, but not the one someone waits on first (`kept`): one started for a
  /// read took 3 s on a station short of memory (2026-11-03, its code read in again), the read itself 40 ms; the second
  /// of what devices ask, started as the first was busy, 16 s.
  private letGoLater(slot: Slot, line: Line) {
    if (slot.idle) return;
    // A thread's resources: the machine's time.
    slot.idle = wall.after(IDLE_MS, () => {
      slot.idle = undefined;
      if (slot.held !== null) return;
      if (this.kept(slot, line)) return;
      void slot.worker.terminate();
    });
  }

  /// Whether an idle reader stays: only the first of its readers (`moved`), a process of a few MB started again in
  /// milliseconds (a test's reference: those of what devices ask and what streams tell, threads each a V8 of its own).
  /// `trimIdle` lets it go when the station is short of memory.
  private kept(slot: Slot, line: Line): boolean {
    if (this.mbReader !== null) return line === this.moved && line.slots[0] === slot;
    return line === this.asked || line === this.told;
  }

  /// The readers kept (`kept`), started before anything is asked: the first reads after the station starts (an
  /// update), and one beside a slow one, need not wait on them. One of the program's readers: three threads were kept
  /// before (2026-11-15, ~150–200 MB of the station's 412–570 MB), one of which was never asked anything.
  warm() {
    if (this.closed) return;
    if (this.mbReader !== null) {
      if (this.moved.slots.length === 0) {
        const started = this.start(this.moved);
        if ("error" in started) log.warn("readers", "warm reader start failed", { mode: "data", error: started.error.message });
      }
      return;
    }
    for (const line of [this.asked, this.told]) {
      while (!this.closed && line.slots.length < line.size) {
        const started = this.start(line);
        if ("error" in started) {
          log.warn("readers", "warm reader start failed", { mode: "data", error: started.error.message });
          break;
        }
      }
    }
  }

  /// `trim` called by `trimIdle` too: what it let go of that answers nothing, a count.
  onTrim(trim: () => number) {
    this.trims.push(trim);
  }

  /// The answer, as JSON text. `told`: what an event stream or a notice tells, read by the station's own reader.
  /// `background`: what a client brings onto its device in the background (POST /batch: a session's history page after
  /// page): after every other read waiting, and one at a time. In line with the rest, a sweep's pages (1 to 4 s each on
  /// a station, 2 to 7 MB of a Codex transcript read: 2026-11-03) held the sidebar, a session opened and the rest 10 s and
  /// more behind them, four at once from each device.
  read(op: string, args: unknown, lang: Ask["lang"], options: { told?: boolean; background?: boolean; signal?: AbortSignal } = {}): Promise<string> {
    return this.answer(op, args, lang, options).then((text) => typeof text === "string" ? text : text.toString());
  }

  /// A read's answer as bytes, for what only passes it on (a device's request): the MoonBit reader's as it gave them.
  readBytes(op: string, args: unknown, lang: Ask["lang"], options: { told?: boolean; background?: boolean; signal?: AbortSignal } = {}): Promise<Buffer> {
    return this.answer(op, args, lang, options).then((text) => typeof text === "string" ? Buffer.from(text) : text);
  }

  private answer(op: string, args: unknown, lang: Ask["lang"], { told = false, background = false, signal }: { told?: boolean; background?: boolean; signal?: AbortSignal } = {}): Promise<Text> {
    if (op === "usage") return this.usageRead(args, lang, told, signal);
    if (op === "outflowUsage") return this.outflowUsageRead(args, lang, told, signal);
    if (op === "outflowChats") return this.outflowChatsRead(args, lang, told, signal);
    if (op === "recentChatList") return this.recentChatRead(args, lang, told, signal);
    if (op === "sessions") return this.sessionListRead(args, lang, told, background, signal);
    return this.saidRead(op, args, lang, told, background || filling(op, args), signal);
  }

  /// Prepare the same old-chat boundary for a sidebar read or the auto-archive check; concurrent requests share work.
  prepareSaid(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.said ??= new SaidBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.said.ready(threads, signal), signal);
  }

  /// Prepare only the requested chats' last messages in bounded slices for the archive and notices.
  prepareArchiveLast(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    // (by the MoonBit builder, station/mb's src/archivelast)
    const path = join(this.data, "stillfail.db");
    this.archiveLast ??= new RequestedBuilder(this.backfill, { select: { mode: "archive-last", options: { config: this.backfill.readers, logAt: "readers" } }, args: ["--builder", "archive-last", "--db", path] },
      "thread", "archive last message", (thread, cancel) => ({ thread, archiveLast: true, cancel }));
    return this.covered(this.archiveLast.ready(threads, signal), signal);
  }

  /// Share the bounded old-edit preparation between notices, and leave a cancelled request unattended.
  prepareLegacyEdits(signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    // (by the MoonBit builder, station/mb's src/legacy; a store whose merged view must be switched first repaired by
    // the station's writer, `repairEdits`, and asked again)
    const path = join(this.data, "stillfail.db");
    this.legacyEdits ??= new RequestedBuilder(this.backfill, { select: { mode: "legacy-edits", options: { config: this.backfill.readers, logAt: "readers" } }, args: ["--builder", "legacy-edits", "--db", path],
      repair: () => {
        if (this.repairEdits !== null) return this.repairEdits();
        // (readers given no writer, a test's: a connection of its own for the repair, waiting for no lock)
        const db = new DatabaseSync(path, { timeout: 0 });
        try { db.exec("PRAGMA synchronous = NORMAL"); repairMergedEditLookup(db); } finally { db.close(); }
      } }, "thread", "legacy edits", (thread, cancel) => ({ thread, legacyEdits: true, cancel }));
    return this.covered(this.legacyEdits.ready([0], signal), signal);
  }

  /// Read only one page for a guarded card outcome, behind interactive work and without a long-lived snapshot.
  async cardEditPage(thread: number, target: string, before: string | null, signal?: AbortSignal): Promise<CardEditPage> {
    return JSON.parse(await this.read("internalCardEditPage", { thread, target, before }, "zh", { background: true, signal })) as CardEditPage;
  }

  async cardMessagePage(thread: number, target: string, before: string | null, signal?: AbortSignal): Promise<CardMessagePage> {
    return JSON.parse(await this.read("internalCardMessagePage", { thread, target, before }, "zh", { background: true, signal })) as CardMessagePage;
  }

  /// Share the initial old-message scan between pages waiting for it.
  prepareLegacySaid(signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    // (by the MoonBit builder, station/mb's src/legacy)
    const path = join(this.data, "stillfail.db");
    this.legacySaid ??= new RequestedBuilder(this.backfill, { select: { mode: "legacy-said", options: { config: this.backfill.readers, logAt: "readers" } }, args: ["--builder", "legacy-said", "--db", path] },
      "thread", "legacy said", (thread, cancel) => ({ thread, legacySaid: true, cancel }));
    return this.covered(this.legacySaid.ready([0], signal), signal);
  }

  /// Prepare only the requested old chats' letter-message keys, sharing progress and handover with other readers.
  preparePageLetters(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    // (by the MoonBit builder, station/mb's src/letters)
    const path = join(this.data, "stillfail.db");
    this.pageLetters ??= new RequestedBuilder(this.backfill, { select: { mode: "page-letters", options: { config: this.backfill.readers, logAt: "readers" } }, args: ["--builder", "page-letters", "--db", path] },
      "thread", "old page letters", (thread, cancel) => ({ thread, pageLetters: true, cancel }));
    return this.covered(this.pageLetters.ready(threads, signal), signal);
  }

  /// Prepare the old connection bindings for session reads and auto-archiving together.
  prepareSessionBindings(signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.sessionBindings ??= new SessionBindingsBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.sessionBindings.readyIndex(signal), signal);
  }

  /// Prepare old pin and keep marks before automatic archiving.
  prepareArchiveMarks(signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.archiveMarks ??= new ArchiveMarkBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.archiveMarks.readyIndex(signal), signal);
  }

  /// Prepare the jobs of the sessions an archive check is waiting on.
  prepareSessionUpJobs(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.sessionUpJobs ??= new SessionUpJobsBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.sessionUpJobs.ready(sessions, signal), signal);
  }

  /// Prepare old up jobs without holding the reader whose answer asked for it.
  prepareWorkspaceUpJobs(signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.workspaceUpJobs ??= new WorkspaceUpJobsBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.workspaceUpJobs.ready(["all"], signal), signal);
  }

  /// Prepare a requested own chat's first member after handover, sharing and cancelling its bounded batches.
  prepareJobNameFirst(owner: string, thread: number, signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.jobNameFirst ??= new JobNameFirstBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.jobNameFirst.ready([JSON.stringify([owner, thread])], signal), signal);
  }

  /// Prepare only old threads whose widget sources a delivery needs.
  prepareWidgetSources(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.widgetSources ??= new WidgetSourcesBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.widgetSources.ready(threads, signal), signal);
  }

  /// Prepare old card posts requested by a read; concurrent reads share this work.
  prepareCardPosts(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.cardPosts ??= new CardPostsBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.cardPosts.ready(threads, signal), signal);
  }

  /// Prepare only the old closed cards requested by the read.
  prepareClosedCards(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.closedCards ??= new ClosedCardsBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.closedCards.ready(threads, signal), signal);
  }

  /// Prepare only the old people-time lookups requested by the read.
  preparePeopleSince(threads: readonly number[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.peopleSince ??= new PeopleSinceBuilder(join(this.data,"stillfail.db"),this.backfill);
    return this.covered(this.peopleSince.ready(threads,signal),signal);
  }

  /// Prepare the sessions needed to choose a chat's copy destinations.
  prepareCcSessions(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.ccIndex ??= new CcIndexBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.ccIndex.ready(sessions, signal), signal);
  }

  /// Prepare the ordered chat names for only the sessions a caller needs.
  prepareSessionChatNames(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.ccIndex ??= new CcIndexBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.ccIndex.readyNames(sessions, signal), signal);
  }

  /// Prepare the latest conversation for only the old sessions a caller needs.
  prepareLatestThreads(sessions: readonly string[], signal?: AbortSignal): Promise<void> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    this.ccIndex ??= new CcIndexBuilder(join(this.data, "stillfail.db"), this.backfill);
    return this.covered(this.ccIndex.readyLatest(sessions, signal), signal);
  }

  private async saidRead(op: string, args: unknown, lang: Ask["lang"], told: boolean, background: boolean, signal?: AbortSignal): Promise<Text> {
    while (!this.closed) {
      try { return await this.enqueue(op, args, lang, told, op === CHECKPOINT, background, signal); }
      catch (error) {
        if (!(error instanceof HttpError)) throw error;
        if (error.message === LEGACY_EDITS_PENDING) {
          await this.prepareLegacyEdits(signal);
          continue;
        }
        if (error.message === LEGACY_SAID_PENDING) {
          await this.prepareLegacySaid(signal);
          continue;
        }
        if (error.message.startsWith(PAGE_LETTER_PENDING)) {
          let threads: unknown;
          try { threads = JSON.parse(error.message.slice(PAGE_LETTER_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
          await this.preparePageLetters(threads, signal);
          continue;
        }
        if (error.message.startsWith(LAST_MESSAGE_PENDING)) {
          let threads: unknown;
          try { threads = JSON.parse(error.message.slice(LAST_MESSAGE_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
          await this.prepareArchiveLast(threads, signal);
          continue;
        }
        if (error.message === SESSION_BINDINGS_PENDING) {
          await this.prepareSessionBindings(signal);
          continue;
        }
        if (error.message.startsWith(CC_SESSIONS_PENDING)) {
          let sessions: unknown;
          try { sessions = JSON.parse(error.message.slice(CC_SESSIONS_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(sessions) || sessions.length === 0 || !sessions.every((key) => typeof key === "string")) throw error;
          await this.prepareCcSessions(sessions, signal);
          continue;
        }
        if (error.message.startsWith(JOB_NAME_FIRST_PENDING)) {
          let key: unknown;
          try { key = JSON.parse(error.message.slice(JOB_NAME_FIRST_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(key) || key.length !== 2 || typeof key[0] !== "string" || !Number.isSafeInteger(key[1])) throw error;
          await this.prepareJobNameFirst(key[0], key[1], signal);
          continue;
        }
        if (error.message.startsWith(CARD_POSTS_PENDING)) {
          let threads: unknown;
          try { threads = JSON.parse(error.message.slice(CARD_POSTS_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
          await this.prepareCardPosts(threads, signal);
          continue;
        }
        if (error.message.startsWith(CLOSED_CARDS_PENDING)) {
          let threads: unknown;
          try { threads = JSON.parse(error.message.slice(CLOSED_CARDS_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
          await this.prepareClosedCards(threads, signal);
          continue;
        }
        if (error.message.startsWith(PEOPLE_TIME_PENDING)) {
          let threads: unknown;
          try { threads = JSON.parse(error.message.slice(PEOPLE_TIME_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
          await this.preparePeopleSince(threads,signal);
          continue;
        }
        if (error.message.startsWith(TURN_COUNT_PENDING)) {
          let sessions: unknown;
          try { sessions = JSON.parse(error.message.slice(TURN_COUNT_PENDING.length)); } catch { throw error; }
          if (!Array.isArray(sessions) || sessions.length === 0 || !sessions.every((key) => typeof key === "string")) throw error;
          this.turns ??= new TurnBuilder(join(this.data, "stillfail.db"), this.backfill);
          await this.covered(this.turns.ready(sessions, signal), signal);
          continue;
        }
        if (!error.message.startsWith(SAID_PENDING)) throw error;
        let threads: unknown;
        try { threads = JSON.parse(error.message.slice(SAID_PENDING.length)); } catch { throw error; }
        if (!Array.isArray(threads) || threads.length === 0 || !threads.every(Number.isSafeInteger)) throw error;
        await this.prepareSaid(threads, signal);
      }
    }
    throw new HttpError(502, "station stopping");
  }

  private async covered(check: Promise<void>, signal?: AbortSignal): Promise<void> {
    try {
      if (!signal) await check;
      else await new Promise<void>((resolve, reject) => {
        const abort = () => { signal.removeEventListener("abort", abort); reject(cancelled()); };
        if (signal.aborted) abort();
        else signal.addEventListener("abort", abort, { once: true });
        check.then(() => { signal.removeEventListener("abort", abort); resolve(); }, (error) => { signal.removeEventListener("abort", abort); reject(error); });
      });
    }
    catch (error) {
      if (error instanceof HttpError && error.message === "read cancelled") throw error;
      if (this.closed) throw new HttpError(502, "station stopping");
      throw new HttpError(503, (error as Error).message);
    }
  }

  private async usageRead(args: unknown, lang: Ask["lang"], told: boolean, signal?: AbortSignal): Promise<Text> {
    const viewer = (args as { viewer?: InWorkspace | null } | null)?.viewer ?? null;
    const history = (args as { history?: unknown } | null)?.history === true;
    while (!this.closed) {
      try {
        return await this.enqueue("usage", args, lang, told, false, false, signal);
      } catch (error) {
        if (error instanceof HttpError && error.message === USAGE_CHATS_PENDING && history) {
          this.startUsageIndex();
          await this.covered(this.minutes!.readyChats(viewer), signal);
          continue;
        }
        if (!(error instanceof HttpError) || error.message !== REMOTE_RUNS_PENDING) throw error;
        this.startUsageIndex();
        await this.covered(this.minutes!.readyRemote(), signal);
      }
    }
    throw new HttpError(502, "station stopping");
  }

  /// What the program reads of usage is kept as it is written (store/usage-15m.ts): nothing to wait for.
  private async outflowUsageRead(args: unknown, lang: Ask["lang"], told: boolean, signal?: AbortSignal): Promise<Text> {
    return await this.enqueue("outflowUsage", args, lang, told, false, false, signal);
  }

  private async outflowChatsRead(args: unknown, lang: Ask["lang"], told: boolean, signal?: AbortSignal): Promise<Text> {
    const ws = (args as { ws?: InWorkspace } | null)?.ws;
    const viewer: InWorkspace = ws !== null && typeof ws === "object" && typeof ws.workspace === "string"
      ? { workspace: ws.workspace, home: ws.home === true } : { workspace: "\u0000home", home: true };
    while (!this.closed) {
      try { return await this.enqueue("outflowChats", args, lang, told, false, false, signal); }
      catch (error) {
        if (!(error instanceof HttpError) || error.message !== OUTFLOW_CHATS_PENDING) throw error;
        this.outflowChats ??= new OutflowChatIndex(join(this.data, "stillfail.db"), this.backfill);
        await this.covered(this.outflowChats.ready(viewer, signal), signal);
      }
    }
    throw new HttpError(502, "station stopping");
  }

  private async recentChatRead(args: unknown, lang: Ask["lang"], told: boolean, signal?: AbortSignal): Promise<Text> {
    const a = args as { ws?: unknown; home?: unknown } | null;
    const ws = a?.ws, home = a?.home;
    if ((ws !== null && typeof ws !== "string") || (home !== null && typeof home !== "string"))
      throw new HttpError(400, "invalid recent chat scope");
    while (!this.closed) {
      try { return await this.saidRead("recentChatList", args, lang, told, false, signal); }
      catch (error) {
        if (!(error instanceof HttpError) || error.message !== RECENT_CHAT_PENDING) throw error;
        this.recentChats ??= new RecentChatBuilder(join(this.data, "stillfail.db"), this.backfill);
        await this.covered(this.recentChats.readyScope({ ws, home }, signal), signal);
      }
    }
    throw new HttpError(502, "station stopping");
  }

  private async sessionListRead(args: unknown, lang: Ask["lang"], told: boolean, background: boolean, signal?: AbortSignal): Promise<Text> {
    while (!this.closed) {
      try { return await this.saidRead("sessions", args, lang, told, background, signal); }
      catch (error) {
        if (!(error instanceof HttpError) || error.message !== SESSION_LIST_PENDING) throw error;
        this.sessionList ??= new SessionListBuilder(join(this.data, "stillfail.db"), this.backfill);
        await this.covered(this.sessionList.readyIndex(signal), signal);
      }
    }
    throw new HttpError(502, "station stopping");
  }

  /// `first`: before the reads waiting (CHECKPOINT).
  private enqueue(op: string, args: unknown, lang: Ask["lang"], told: boolean, first = false, background = false, signal?: AbortSignal): Promise<Text> {
    if (this.closed) return Promise.reject(new HttpError(502, "station stopping"));
    if (signal?.aborted) return Promise.reject(cancelled());
    const history = this.mbReader !== null && HISTORY.has(op);
    if (this.mbReader !== null && op !== CHECKPOINT && !history && !MOVED.has(op)) return Promise.reject(new HttpError(500, `no read ${op}`));
    // (a test's reference: on the lines of before, what is told on its own, the pages', the rest)
    const line = op === CHECKPOINT ? this.log : history ? this.pages : this.mbReader !== null ? this.moved : told ? this.told : PAGES.has(op) ? this.pages : this.asked;
    // A session's history read where it was read before: that reader keeps where its reading stands in memory, another
    // reads it from disk (read/transcripts.ts).
    const session = (op === "timeline" || op === "transcriptState") && typeof (args as { key?: unknown })?.key === "string" ? (args as { key: string }).key : null;
    const home = session !== null ? this.homes.get(session) : undefined;
    const given = history ? args
      : line !== this.moved ? args
      : MACHINE.has(op) ? { ...(args as object), roots: machineRoots() }
      : op === "sessionPlace" ? placeOf(args)
      // (what of a list changed: the list read as its own read is, given its words; test/reference/digest.ts `changedOf`)
      : op === "changed" && WORDED.has((args as { op?: string }).op ?? "") ? changedOf(args, lang)
      : WORDED.has(op) ? { ...(args as object), words: wordsIn(op, lang), now: wall.now() }
      : args;
    const ask: Ask = { id: this.next++, op, args: given, lang, names: [], processes: [], clientKeys: [] };
    return new Promise((resolve, reject) => {
      let finished = false;
      const done = () => { finished = true; signal?.removeEventListener("abort", abort); };
      const asked: Asked = {
        ask, session, home: home !== undefined && line.slots.includes(home) ? home : null, background, at: wall.now(), took: 0,
        resolve: (text) => { if (!finished) { done(); resolve(text); } },
        reject: (error) => { if (!finished) { done(); reject(error); } },
      };
      const abort = () => {
        if (finished) return;
        const at = line.waiting.indexOf(asked);
        if (at >= 0) line.waiting.splice(at, 1);
        else {
          const slot = line.slots.find((s) => s.held === asked);
          if (slot) { slot.retiring = true; void slot.worker.terminate(); }
        }
        asked.reject(cancelled());
        if (at >= 0) this.pump(line);
      };
      signal?.addEventListener("abort", abort, { once: true });
      if (first) line.waiting.unshift(asked);
      else line.waiting.push(asked);
      this.pump(line);
    });
  }

  /// Reads in line go to its readers free, the first first (a session's history to its home reader when that one is
  /// free). Where bulk reads leave room (`room`, two readers or more), they hold one less than all: a later interactive
  /// read passes a waiting bulk read to the one left.
  private pump(line: Line) {
    if (this.closed) return;
    this.retireMismatchedIdle(line);
    while (line.waiting.length > 0) {
      const bulkHeld = line.slots.filter((s) => s.held !== null && !interactive(s.held) && !s.held.background).length;
      const limited = line.room && line.size > 1 && bulkHeld >= line.size - 1;
      // A background read only when no other waits, none of its kind is being read, and a reader is left beside it.
      const foreground = line.waiting.findIndex((a) => !a.background);
      const free = line.slots.filter((s) => s.held === null).length + (line.size - line.slots.length);
      const resting = line.rested !== undefined && wall.now() < line.rested;
      const behind = resting || line.slots.some((s) => s.held?.background === true) || (free < 2 && line.size > 1) ? -1 : line.waiting.findIndex((a) => a.background);
      // (a background read of a kind someone waits on, a batch's chat, is a background read: one at a time, after a rest)
      const first = line.waiting.findIndex((a) => !a.background && (interactive(a) || a.ask.op === CHECKPOINT));
      const at = limited || first >= 0 ? first : foreground >= 0 ? foreground : behind;
      if (at < 0) {
        // A background read waiting while the line rests: looked at again once it has, however early a timer fires
        // (one armed for as long as the read took woke a moment before it was over, the read left waiting for good).
        if (resting && line.wake === undefined && line.waiting.some((a) => a.background)) {
          line.wake = wall.after(Math.max(1, line.rested! - wall.now()), () => {
            line.wake = undefined;
            this.pump(line);
          });
        }
        break;
      }
      const asked = line.waiting[at]!;
      const home = asked.home !== null && asked.home.held === null && line.slots.includes(asked.home) ? asked.home : null;
      let slot: Slot | null = home ?? line.slots.find((s) => s.held === null) ?? null;
      if (slot === null && line.slots.length < line.size) {
        const started = this.start(line);
        if ("error" in started) {
          // Never throw uncaught inside exit/timer/pump callbacks.
          // If any non-retiring busy slot exists on this line, leave queued waiters in the queue so the busy
          // slot can take them once free (or retire on mismatch and reject cleanly then).
          if (line.slots.some((s) => !s.retiring)) break;
          line.waiting.splice(at, 1);
          asked.reject(new HttpError(500, started.error.message));
          for (const w of line.waiting.splice(0)) w.reject(new HttpError(500, started.error.message));
          break;
        }
        slot = started.slot;
      }
      if (slot === null) break;
      line.waiting.splice(at, 1);
      this.give(slot, asked);
    }
    for (const slot of line.slots) if (slot.held === null) this.letGoLater(slot, line);
  }

  private give(slot: Slot, asked: Asked) {
    slot.idle?.();
    slot.idle = undefined;
    slot.held = asked;
    asked.took = wall.now();
    if (asked.session !== null) {
      // Where its reading will stand.
      this.homes.delete(asked.session);
      this.homes.set(asked.session, slot);
      while (this.homes.size > HOMES) this.homes.delete(this.homes.keys().next().value!);
    }
    asked.ask.names = [...this.names];
    asked.ask.processes = [...this.processes()];
    asked.ask.clientKeys = [...this.clientKeys()];
    // (the MoonBit reader's prices are the catalog's as well: read/usage.ts `price`)
    const current = catalog();
    if (slot.catalogVersion !== current.version) {
      asked.ask.catalog = current.models;
      slot.catalogVersion = current.version;
    }
    slot.worker.postMessage(asked.ask);
  }

  /// The store changed: what its log (the WAL) holds is written into the database shortly, by a reader (main.mbt
  /// `checkpoint`), one at a time, at most once a CHECKPOINT_MS. The main thread does not (store.ts): there it held
  /// every device while it reached the disk.
  checkpointSoon() {
    if (this.closed) return;
    if (this.checkpointing) return void (this.again = true);
    this.checkpointing = true;
    this.again = false;
    wall.after(CHECKPOINT_MS, () => {
      if (this.closed) return;
      this.read(CHECKPOINT, {}, "en")
        .catch((error) => log.warn("readers", "the database's log not written into it", { error: (error as Error).message }))
        .finally(() => {
          this.checkpointing = false;
          if (this.again) this.checkpointSoon();
        });
    });
  }

  /// What answers nothing now let go at once, not after IDLE_MS (the station short of memory: ops/self-memory.ts): each
  /// reader with no read held or waiting (but for a test's reference threads `kept`: those a read waits seconds for to
  /// start, where the program's start takes milliseconds), each builder of old state nobody waits
  /// on (RequestedBuilder `trimIdle`), the usage checker, and what `onTrim` gave. A read under way is never stopped. How
  /// many were let go.
  trimIdle(): number {
    if (this.closed) return 0;
    let trimmed = 0;
    for (const line of this.mbReader !== null ? [this.asked, this.told, this.pages, this.log, this.moved] : [this.pages, this.log, this.moved]) {
      if (line.waiting.length > 0) continue;
      for (const slot of line.slots.filter((s) => s.held === null && !s.retiring)) {
        slot.idle?.();
        slot.idle = undefined;
        slot.retiring = true;
        // (out of its line at once: no read is given it as it ends)
        line.slots = line.slots.filter((s) => s !== slot);
        void slot.worker.terminate();
        trimmed++;
      }
    }
    const builders = [this.said, this.archiveLast, this.legacyEdits, this.legacySaid, this.pageLetters, this.turns, this.recentChats, this.sessionList,
      this.sessionBindings, this.archiveMarks, this.sessionUpJobs, this.workspaceUpJobs, this.jobNameFirst, this.widgetSources, this.cardPosts,
      this.closedCards, this.peopleSince, this.ccIndex];
    for (const b of builders) if (b?.trimIdle()) trimmed++;
    trimmed += this.minutes?.trimIdle() ?? 0;
    for (const trim of this.trims) {
      try { trimmed += trim(); }
      catch (error) { log.warn("readers", "letting go of what answers nothing failed", { error: (error as Error).message }); }
    }
    return trimmed;
  }

  /// The log written into the database waiting a while for the readers, and its file cut (main.mbt `checkpoint`'s
  /// `hard`): it grew past its bound (ops/storage.ts `walCheckpoint`). What SQLite answered.
  async checkpointHard(): Promise<unknown> {
    return JSON.parse(await this.read(CHECKPOINT, { hard: true }, "en"));
  }

  /// Each running reader's JS heap in use, in bytes (for the memory log).
  heaps(): Promise<number[]> {
    return Promise.all([...this.asked.slots, ...this.told.slots, ...this.log.slots, ...this.pages.slots, ...this.moved.slots].map((s) => s.worker.getHeapStatistics().then((h) => h.used_heap_size, () => 0)));
  }

  close() {
    this.closed = true;
    if (this.minutes !== null) void this.minutes.close();
    if (this.outflowChats !== null) void this.outflowChats.close();
    if (this.said !== null) void this.said.close();
    if (this.archiveLast !== null) void this.archiveLast.close();
    if (this.legacyEdits !== null) void this.legacyEdits.close();
    if (this.legacySaid !== null) void this.legacySaid.close();
    if (this.pageLetters !== null) void this.pageLetters.close();
    if (this.turns !== null) void this.turns.close();
    if (this.recentChats !== null) void this.recentChats.close();
    if (this.sessionList !== null) void this.sessionList.close();
    if (this.sessionBindings !== null) void this.sessionBindings.close();
    if (this.archiveMarks !== null) void this.archiveMarks.close();
    if (this.sessionUpJobs !== null) void this.sessionUpJobs.close();
    if (this.workspaceUpJobs !== null) void this.workspaceUpJobs.close();
    if (this.jobNameFirst !== null) void this.jobNameFirst.close();
    if (this.widgetSources !== null) void this.widgetSources.close();
    if (this.cardPosts !== null) void this.cardPosts.close();
    if (this.closedCards !== null) void this.closedCards.close();
    if (this.peopleSince !== null) void this.peopleSince.close();
    if (this.ccIndex !== null) void this.ccIndex.close();
    for (const line of [this.asked, this.told, this.log, this.pages, this.moved]) {
      for (const asked of line.waiting.splice(0)) asked.reject(new HttpError(502, "station stopping"));
      for (const { worker } of line.slots) void worker.terminate();
    }
  }
}
