// Tasks on other stations of the workspace. Workspace peers call named operations over an
// authenticated station transport (`stillfail/station/1`, the mesh layer's); shell tasks are one service on it, never an
// admin API proxy. Any station of the workspace may run them (the transport checks the roster), as its agents may open a
// chat here whose agent runs the same commands: shell execution as the station's OS user, not a sandbox. A source session's
// tasks share one working directory on the target (remote/sessions/<id>/work). The source asks for it to be removed
// when the session is archived or deleted; the target removes it itself after IDLE_MS unused, and a directory mirrored
// in it (a task's `dir`) after MIRROR_IDLE_MS without a task, or sooner when the station's disk runs low (ops/disk.ts).
//
// The records are the Rust's files, written the same way (remote/incoming/<id>/task.json, sessions/<id>/session.json,
// outgoing/<id>.json, used/<id>.json), so either station reads what the other wrote. A task's station tells the one
// that started it when the task ends or says something (`task.changed`), and that one then asks it what (`task.get`):
// nothing asks about a task while nothing happens to it; one on a station from before that is not followed (its session is told).
// What is retried (a request that did not get through, a closed session's stations every 60 s) and the sweeps are the
// program's, on this clock; nothing here polls local state.
import { createHash, randomBytes } from "node:crypto";
import { constants, mkdirSync, readFileSync, renameSync } from "node:fs";
import { access, link, lstat, mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { DISK_LOW_BYTES, diskFree } from "../ops/disk.ts";
import { treeBytes } from "../ops/storage.ts";
import { walkBounded } from "../ops/walk.ts";
import { portableComponent, relativeParts } from "../ops/paths.ts";
import { PlaceRefused, Places } from "../ops/places.ts";
import { platform } from "../platform/index.ts";
import { Clock, Duration, Effect, Exit, FiberSet, Schedule, Scope } from "effect";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";
import { type Cloud, UNPROTECTED } from "../cloud/state.ts";
import { type Json, type Store } from "../store/store.ts";
import { type Jobs, jobJson, tail } from "./jobs.ts";
import { detailed, summary } from "./load.ts";
import { type Bytes, type Inbox, MESH_WAIT_MS, NoBytes, NoLink, type PeerCall, PeerBus, Refused, bytesOf, withBytes } from "../mesh/bus.ts";
import type { ActorsProgram } from "../sessions/mb-actor.ts";
import { version as runningVersion } from "../ops/version.ts";
import { fileBytes, readBytes, stopBytes, writeBytes } from "../mesh/files.ts";
import { Bulk, LINK, PACKED, patchOf } from "./dirsync.ts";
import { DEFAULT_LIMIT, WorkspaceReader } from "./workspace-size.ts";
import { SANDBOX, type Sandbox, ensureIdentity, sandboxDescribed } from "../agents/sandbox.ts";

// The requests between stations are the platform's bus (mesh/bus.ts); its types, here as they always were.
export { type Inbox, MESH_WAIT_MS, type PeerCall, Refused } from "../mesh/bus.ts";
/// A request that did not get through (asked again later).
class Unreached extends Error {}
/// Tells a session's agent something; a throw (or rejection) is "not told" (it is told again later).
export type RemoteNotify = (session: string, text: string) => void | Promise<void>;

export const CHUNK = 256 * 1024;
const MAX_FILE = 1024 * 1024 * 1024;
/// The changed files a patch is made of, at most (the rest is named, not in it).
const PATCH_MAX = 64 * 1024 * 1024;
/// A source session's directory unused this long is removed by the target, in case its source never says so.
export const IDLE_MS = 14 * 24 * 3600 * 1000;
/// A task its station does not know, or has not started, this long after its start was asked for is no longer followed.
export const GIVE_UP_MS = 10 * 60_000;
/// A mirror (a task's `dir` on the target) no task of its session has run in or synced for this long goes, with what
/// its tasks made there; the next start syncs it anew. Chats made one for each worktree and kept them all: 204 of
/// one session's, enough to fill the station's disk in hours (2026-10-20).
export const MIRROR_IDLE_MS = 24 * 3600 * 1000;
/// With the station's disk low (`relieve`), a mirror used within this stays.
export const MIRROR_RECENT_MS = 3600 * 1000;

export type RemoteOptions = {
  /// The data directory: remote/ and mesh/cloud.json in it.
  data: string;
  store: Store;
  jobs: Jobs;
  notify: RemoteNotify;
  /// The clock its schedules run on (a TestClock in tests).
  clock?: Clock.Clock;
  /// How long a request made before the mesh is up waits for it (MESH_WAIT_MS; tests shorten it).
  meshWaitMs?: number;
  /// The station's requests to and from the others (mesh/bus.ts); one of its own when none is given (tests).
  bus?: PeerBus;
  /// How a task's `dir` is looked at (ops/places.ts): the station syncs it itself, so in a folder macOS protects it
  /// must reach it itself, looked at off its thread. Default: without still.fail Helper.
  places?: Places;
  /// The bytes free on the disk holding `path` (tests say how full it is). Default: statfs.
  diskFree?: (path: string) => number | Promise<number>;
  /// Remove a mirror's tree. Tests can hold or fail the removal to exercise interrupted requests.
  removeMirror?: (path: string) => Promise<void>;
  /// How a closed session's task directory is removed (tests hold it to come between).
  removeTask?: (path: string) => Promise<void>;
  /// This station's version as `describe` says it (ops/version.ts; tests say theirs).
  version?: string;
  /// The last completed cleanup of files brought back. Tests can keep this across station restarts in memory.
  backTidy?: { read: () => Promise<number | null>; write: (at: number) => Promise<void> };
  /// Whether this station is opted into automatic new-chat assignment (`acceptAutoChats` in config.json).
  acceptAutoChats?: () => boolean;
};

/// A start that syncs a directory answers within this, synced or not (the sync goes on): an agent's tool call is given
/// up on after a minute, and the agent asking again (the same key) began another sync over the first, which the target
/// then refused as over, again and again (2026-10-19). Asked again, the start takes up the sync under way.
export const SYNC_ANSWER_MS = 40_000;
/// The tasks a source asks about at once (`task.gets`), at most.
export const GETS_MAX = 200;

/// station_list asks every station of the workspace at once and lists one that has not answered within this as
/// unanswered: not as offline, which it does not know (2026-11-14: one up and updating itself, asked by a station whose
/// relay was at 8 s, was listed offline and its person told so).
export const LIST_WAIT_MS = 2000;
/// station_list {station} waits this long for the one station asked before it says it did not answer.
export const LIST_ALONE_WAIT_MS = 10_000;
/// A station asked how busy it is (`describe`'s `load`) says it does not know when measuring takes longer than this.
export const LOAD_WAIT_MS = 1000;

/// What station_list says of a station asked `describe` (`got`, null when it did not answer within LIST_WAIT_MS), its
/// version as the roster has it being `seen`: offline only where no link to it would open (NoLink); otherwise it
/// did not answer, which says nothing of whether it is up. Its version is the one it says itself; the roster's copy,
/// what still.fail cloud listed when it last told this station its stations (it is not told again as a station
/// updates), is `version_seen`, never its version now. One from before says none in `describe`: it keeps the copy.
function heard(got: { ok: Json } | { error: Error } | null, seen: Json): Json {
  const copy = typeof seen === "string" ? { version_seen: seen } : {};
  if (got === null) return { ...copy, unanswered: `did not answer within ${LIST_WAIT_MS / 1000} s; not known to be offline: ask it alone` };
  if ("error" in got) {
    const { error } = got;
    if (error instanceof Refused) return { ...copy, refused: error.message };
    if (error instanceof NoLink) return { ...copy, offline: error.message };
    return { ...copy, unanswered: `${error.message}; not known to be offline: ask it alone` };
  }
  const says = field(got.ok, "version");
  return { ...(typeof says === "string" ? { version: says } : copy), load: summary(field(got.ok, "load")) };
}

const text = (v: Json, key: string): string => (v !== null && typeof v === "object" && typeof v[key] === "string" ? v[key] : "");
const field = (v: Json, key: string): Json => (v !== null && typeof v === "object" && !Array.isArray(v) && key in v ? v[key] : null);
/// serde_json's as_u64.
const asU64 = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? v : null);

/// The name a source session, task or record goes by: sha256 of its parts as compact JSON (as serde writes them).
export function hash(v: Json): string {
  return createHash("sha256").update(JSON.stringify(v)).digest("hex");
}

export function readJson(path: string): Json {
  return JSON.parse(readFileSync(path, "utf8")); // sync: a use record before the program told those it read as it started (usedRecord), and the tests' cloud.json (cloudState)
}

/// How long what a task brought back is kept once nothing in it changed (`tidyBack`), and how often that is looked at.
const BACK_KEPT_MS = 6 * 3600_000;
const BACK_TIDY_MS = 3600_000;

/// How many entries `latestIn` looks at, at most: past it, what it looks at is kept (Infinity).
export const LATEST_MOST = 100_000;

/// When anything under `path` last changed (its own time for a file), off the thread; Infinity where it cannot be said
/// (kept): past LATEST_MOST entries too, or a walk cut short (ops/walk.ts `walkBounded`: on its root's disk, no link
/// followed).
export async function latestIn(path: string, most = LATEST_MOST): Promise<number> {
  let latest = -Infinity;
  let failed = false;
  const walked = await walkBounded(path, (e) => {
    if (e.stats !== null) latest = Math.max(latest, Number(e.stats.mtimeMs));
  }, { stat: true, maxEntries: most + 1, onError: () => void (failed = true) });
  if (failed || walked.truncated || latest === -Infinity) return Infinity;
  return latest;
}

/// remote/sessions' budget on a disk of `total` bytes (none known: its most): the source sessions' rooms here, their
/// work and mirrors, beyond which the longest unused go (`budget`) before the disk runs low. They took 63 GiB of a
/// station in five days (2026-11-15).
export const REMOTE_BUDGET_MOST = 32 * 1024 ** 3;
export const remoteBudget = (total: number | null): number => (total === null || !(total > 0) ? REMOTE_BUDGET_MOST : Math.min(REMOTE_BUDGET_MOST, Math.floor(total * 0.15)));
/// A room used within this stays, over its budget or not (the program's, remote_target.mbt `room_recent_ms`).
export const ROOM_RECENT_MS = 3600_000;
/// A task done here (remote/incoming/<task>), and one started from here whose end was told (remote/outgoing/<id>.json),
/// kept this long after: 3,255 of the first on a station of five days (2026-11-15), as a session's tasks were never
/// swept (the program's sweep leaves them to their room). The program's (remote_target.mbt `tasks_kept_ms`).
export const TASKS_KEPT_MS = 7 * 24 * 3600_000;

/// Path::with_extension: the file name's extension replaced (or added).
function withExtension(path: string, ext: string): string {
  const name = basename(path);
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return join(dirname(path), `${stem}.${ext}`);
}

/// What was asked of the program to write of each record and is not answered yet (`track`): a record of the chats' use
/// (`recordUse`, `closeSession`), a room's use (`work`).
const asking = new Map<string, Promise<unknown>>();

/// `asked` of the program writes `path`: waited for by `written`.
function track(path: string, asked: Promise<unknown>): void {
  const tail = Promise.allSettled([asking.get(path), asked]).then(() => undefined);
  asking.set(path, tail);
  void tail.then(() => {
    if (asking.get(path) === tail) asking.delete(path);
  });
}

/// The program's writes of each record under way (told `writing`, then `wrote`, before and after each: in the order
/// it says things, so a write told before what it tells next is waited for by what that wakes here).
const programWriting = new Map<string, Map<number, { done: Promise<void>; end: () => void }>>();

/// Once what was asked of `path` before is written (or failed) by the program.
export async function written(path: string): Promise<void> {
  await asking.get(path);
  const theirs = programWriting.get(path);
  if (theirs) await Promise.all([...theirs.values()].map((w) => w.done));
}

const isLink = (path: string): Promise<boolean> => lstat(path).then((st) => st.isSymbolicLink(), () => false);

/// Whether `path` is there, asked off the station's thread.
const there = (path: string): Promise<boolean> => access(path).then(() => true, () => false);

/// Relative paths only; transfers must not follow links planted by a task. Task commands themselves are trusted shell
/// execution, so separate working directories are organizational isolation, not an OS security boundary. Its links
/// looked at off the station's thread.
export async function filePath(root: string, relative: string, create: boolean): Promise<string> {
  if ((await lstat(root)).isSymbolicLink()) throw new Error("transfer root is a symbolic link");
  // Path::components: a leading / is the root (and on Windows a drive, a UNC share or a stream: relativeParts), a
  // leading . is the current directory, a later . is no component.
  const given = relativeParts(relative);
  const parts: string[] = [];
  let bad = given === null;
  (given ?? []).forEach((part, i) => {
    if (part === "") return;
    if (part === ".") {
      if (i === 0) bad = true;
      return;
    }
    parts.push(part);
  });
  if (bad || parts.length === 0) throw new Error("file path must be relative, without . or ..");
  let out = root;
  for (const part of parts) {
    out = join(out, part);
    if (await isLink(out)) throw new Error("file path contains a symbolic link");
  }
  if (create) await mkdir(dirname(out), { recursive: true });
  return out;
}

/// What processes gone left landed (Remote `answer`): each process's own directory, named by its pid.
async function tidyLanding(landing: string): Promise<void> {
  for (const name of await readdir(landing).catch(() => [] as string[])) {
    const pid = Number(name);
    if (Number.isSafeInteger(pid) && pid > 0 && (pid === process.pid || alive(pid))) continue;
    await rm(join(landing, name), { recursive: true, force: true }).catch(() => undefined);
  }
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return (e as NodeJS.ErrnoException).code === "EPERM";
  }
}

/// STANDARD base64 as the Rust decodes it: padded, nothing else in it.
function fromBase64(data: string): Buffer {
  if (data.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(data)) throw new Error("Invalid input length or symbol");
  return Buffer.from(data, "base64");
}

/// The OS and architecture as Rust's std::env::consts name them.
const OS = platform.os;
const ARCH = ({ arm64: "aarch64", x64: "x86_64", ia32: "x86", arm: "arm" } as Record<string, string>)[process.arch] ?? process.arch;

/// What the program knows the remote tasks' shell by.
const REMOTE_KEY = "#remote";

/// The remote tasks (station_task: tasks of other stations here, this station's sessions' tasks there). What they are
/// and do runs in the sessions' MoonBit program (station/mb src/reader/remote.mbt, remote_target.mbt,
/// remote_source.mbt), the pseudo-actor `#remote` of the program the jobs run in. This is what of them is the
/// transport's and the machine's, which the program asks for (`asked`): the requests to and from the other stations and
/// the bytes that go with them (a directory sync's packed requests, the program's), the folders
/// macOS protects, the load, the cloud's state; and what the station's own parts read at once: a session's shared
/// directory (`work`), the chats' use records as the program tells them (`workspaceTargets`; `recordUse` and
/// `closeSession` change them here at once and have the program write them).
export class Remote {
  readonly root: string;
  readonly store: Store;
  /// One bounded queue for both this station's workspaces and those of other stations' tasks.
  readonly workspaceReader: WorkspaceReader;
  private data: string;
  private jobs: Jobs;
  private notify: RemoteNotify;
  /// The requests to and from the other stations: what this answers is said on it (`describe`, the tasks).
  readonly bus: PeerBus;
  private places: Places;
  /// How busy this station is, told to the others in `describe` (load.ts); none: `describe` says nothing of it.
  private load: (() => Promise<Json>) | null = null;
  /// Withdrawals (`revoke`), one at a time.
  private serial: Promise<unknown> = Promise.resolve();
  /// When each source session's room was last used here (`seen`), as its record says once written.
  private seenAt = new Map<string, number>();
  /// What chats used of other stations' workspaces (`usedPath`; null: none), as the program told it (`used`) or as
  /// changed here and asked of it: what `workspaceTargets` says of every chat shown, again and again, read from the disk
  /// each time on the station's thread, 16 of them held it 2.5 s on a station short of memory (2026-11-03).
  private usedCache = new Map<string, Json | null>();
  /// The program told every record it read as it started (`usedReady`): one it did not tell is none.
  private usedReady = false;
  /// The changes of each record asked of the program and not answered yet, and the last it told of the record meanwhile
  /// (`usedHeld`): kept as changed here until the last is answered, then as it told it last (each of its changes is
  /// told, in its order), or as it answered where it told nothing.
  private usedAsked = new Map<string, number>();
  private usedHeld = new Map<string, Json | null>();
  /// The station is stopping: nothing more is followed.
  private stopped = false;
  /// The station's bulk requests to the others (syncs' contents, files' chunks), one at a time (dirsync.ts `Bulk`).
  private bulk = new Bulk();
  private scope: Scope.Closeable;
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  private diskFree: (path: string) => number | Promise<number>;
  private removeMirror: (path: string) => Promise<void>;
  private described: ((peer: string, workspace: string) => Json) | null = null;
  private acceptAutoChats: (() => boolean) | null = null;
  private version: string;
  private rigs: ((workspace: string, session: string, rig: Json, described: Json | null) => Promise<Json>) | null = null;
  /// This station's sandboxes (config.json's `sandboxes`, agents/sandbox.ts): stations of a kind of their own for
  /// station_task, named `sandbox:<name>`, whose tasks this station takes itself and runs there.
  private sandboxes: (() => Sandbox[]) | null = null;
  private removeTask: (path: string) => Promise<void>;
  /// Under how many bytes free the disk is low to the program's `relieve` (`relieve`'s `below`).
  private lowBelow = DISK_LOW_BYTES;
  /// The program the jobs run in (theirs: jobs/jobs.ts), these as `#remote` of it.
  private program: ActorsProgram;
  /// The bytes of the requests being answered, by the number the program is told (`bytes`), and those of the answers
  /// it gives (`outBytes`), sent after them.
  private inBytes = new Map<number, Bytes>();
  private outBytes = new Map<number, Bytes>();
  private bytesNext = 0;
  /// Where this process lands a sync's packed pieces for the program (`answer`): its own, as the next Node of a
  /// handover answers beside it.
  private landing: string;

  constructor(options: RemoteOptions) {
    this.data = options.data;
    this.version = options.version ?? runningVersion();
    this.acceptAutoChats = options.acceptAutoChats ?? null;
    this.store = options.store;
    this.workspaceReader = new WorkspaceReader(() => this.store.now());
    this.jobs = options.jobs;
    this.notify = options.notify;
    this.places = options.places ?? new Places({ own: options.data });
    this.diskFree = options.diskFree ?? diskFree;
    this.removeMirror = options.removeMirror ?? ((path) => rm(path, { recursive: true, force: true }));
    this.removeTask = options.removeTask ?? ((path) => rm(path, { recursive: true, force: true }));
    this.root = join(options.data, "remote");
    for (const name of ["incoming", "outgoing", "sessions", "used", "prepared"]) mkdirSync(join(this.root, name), { recursive: true }); // sync: once, as it is made
    this.landing = join(this.root, "landing", String(process.pid));
    void tidyLanding(join(this.root, "landing"));
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
    const tidiedAt = join(this.root, "back-tidied.json");
    this.startBackTidying(options.backTidy ?? {
      read: async () => {
        try {
          const at: unknown = JSON.parse(await readFile(tidiedAt, "utf8"));
          return typeof at === "number" && Number.isSafeInteger(at) && at >= 0 ? at : null;
        } catch { return null; }
      },
      write: async (at) => { await writeFile(tidiedAt, JSON.stringify(at)); },
    });
    this.program = this.jobs.program;
    this.program.shell({ key: REMOTE_KEY, runtime: "claude", clock: options.clock, asked: (f, args) => this.asked(f, args), told: (f, args) => this.told(f, args) });
    void this.call("start", [this.root]);
    this.bus = options.bus ?? new PeerBus({ waitMs: options.meshWaitMs ?? MESH_WAIT_MS, sleep: (ms) => this.run(Effect.sleep(Duration.millis(ms))).catch(() => undefined) });
    // What this answers: how this station is and what it takes, and the tasks (whatever no other part answers).
    this.bus.on("describe", (peer, _request, workspace) => this.describe(peer, workspace ?? ""));
    this.bus.otherwise((peer, request, workspace) => this.answer(workspace ?? "", peer, request));
    // A task started from here changed on its station: asked about.
    this.bus.on("task.changed", (_peer, request, workspace) => this.call("changed", [workspace ?? "", request]));
    // A task here told of by the station (stopped from the pages): its source is told.
    this.jobs.onRemote((job) => void this.call("pushOut", [job.id.slice("remote_".length)]).catch(() => undefined));
    this.bus.whenAttached(() => this.started());
  }

  /// Asks the program's remote tasks `method`.
  private async call(method: string, args: Json[]): Promise<Json> {
    return await this.program.call(REMOTE_KEY, method, args);
  }

  /// A request of another station's taken in here (`otherwise`): its bytes, if any, kept for the program to have
  /// written where it says (`bytes`); an answer's (a file asked for whole) sent after it. A sync's packed pieces
  /// (`sync.put`, PACKED at most) are landed in a file first, named to the program (`landed`), which unpacks and writes
  /// them itself (station/mb src/reader/dirsync.mbt `put_blobs`): its thousands of small files' writes, stats and renames
  /// held this thread for seconds when they were Node's (2026-11-15: 6.0 s and 4.2 s on a station short of memory).
  private async answer(workspace: string, peer: string, request: Json): Promise<Json> {
    const bytes = bytesOf(request);
    // (`landed` is only ever this station's own: never a path another station names)
    const { landed: _, ...asked0 } = request ?? {};
    let asked: Json = asked0;
    let id = 0;
    let landed: string | null = null;
    try {
      if (bytes !== null && request?.method === "sync.put") {
        landed = join(this.landing, `${++this.bytesNext}.zst`);
        await mkdir(this.landing, { recursive: true });
        const file = await open(landed, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
        try {
          await writeBytes(file, bytes, 0, PACKED);
        } finally {
          await file.close();
        }
        asked = { ...asked, landed };
      } else if (bytes !== null) {
        id = ++this.bytesNext;
        this.inBytes.set(id, bytes);
        asked = { ...asked, bytes: id };
      }
      const answer = await this.call("handle", [workspace, peer, asked]);
      const out = typeof answer?.outBytes === "number" ? this.outBytes.get(answer.outBytes) : undefined;
      if (out !== undefined) {
        this.outBytes.delete(answer.outBytes);
        const { outBytes: _, ...rest } = answer;
        return withBytes(rest, out);
      }
      return answer;
    } finally {
      const left = id === 0 ? undefined : this.inBytes.get(id);
      this.inBytes.delete(id);
      if (left !== undefined) await stopBytes(left).catch(() => undefined);
      if (landed !== null) await rm(landed, { force: true }).catch(() => undefined);
    }
  }

  /// What the program asks of the station for the remote tasks.
  private async asked(f: string, args: Json[]): Promise<Json> {
    if (f.startsWith("store.")) {
      const method = f.slice("store.".length);
      const store = this.store as unknown as Record<string, (...a: Json[]) => Json>;
      if (typeof store[method] !== "function") throw new Error(`no store method ${method}`);
      return store[method]!(...args) ?? null;
    }
    const [a, b, c, d, e] = args;
    switch (f) {
      case "node.ask":
        return await this.ask(a, b);
      case "node.seen": {
        // (the program writes its record when `write`; one asked of it before by work() is written before it reads it)
        const seen = this.seen(a, b, c);
        if (!seen.write) await written(join(this.room(a, b, c), "session.json"));
        return seen;
      }
      case "node.written":
        await written(a);
        return null;
      case "node.seenAt":
        return this.seenAt.get(a) ?? null;
      case "node.forgetSeen":
        this.seenAt.delete(a);
        return null;
      case "node.closeRoom":
        return this.closeRoom(a, b, c);
      case "node.removeTask":
        await this.removeTask(a);
        return null;
      case "node.removeMirror":
        await this.removeMirror(a);
        return null;
      case "node.treeBytes":
        return (await treeBytes(a)).bytes;
      case "node.roomInfo":
        // A room's size, and when it was last used here (its record may say an older time: `seen`).
        return { bytes: (await treeBytes(a)).bytes, seenAt: this.seenAt.get(a) ?? 0 };
      case "node.load":
        return await this.measuredLoad();
      case "node.workspaceSize": {
        const size = this.workspaceReader.size(a, b ?? DEFAULT_LIMIT);
        return size === null ? { present: true, pending: true, path: a } : { present: true, pending: false, path: a, ...size };
      }
      case "node.jobJson":
        return jobJson(a);
      case "node.tail":
        return await tail(a, b);
      case "node.ensureIdentity":
        await ensureIdentity(this.data);
        return null;
      case "node.filePut":
        return await this.filePut(a, b);
      case "node.fileGet":
        return await this.fileGet(a, b);
      case "node.diskLow": {
        try {
          return (await this.diskFree(a)) < this.lowBelow;
        } catch {
          return false;
        }
      }
      case "node.notify":
        await this.notify(a, b);
        return null;
      case "node.cloudState":
        return this.cloudState();
      case "node.sandboxes":
        return (this.sandboxes?.() ?? []).map((s) => ({ name: s.name }));
      case "node.listStations":
        return await this.stationList(a, b, c);
      case "node.stationFile":
        return await this.stationFile(a, b, c, d);
      case "node.directory":
        try {
          await this.places.directory(a, { lang: "en", agent: true, self: true });
        } catch (e) {
          if (e instanceof PlaceRefused && (e.code === "gone" || e.code === "not_a_directory")) throw new Error(`${a} is not a directory`);
          throw e;
        }
        return null;
      case "node.resolve":
        return resolve(a);
      case "node.syncPacking": {
        // Where the program has the shell pack a sync's next request (dirsync_source.mbt `flush_pieces`), which it
        // removes once sent: this process's own, as what lands here is (`answer`).
        await mkdir(this.landing, { recursive: true });
        return join(this.landing, `${++this.bytesNext}.out.zst`);
      }
      case "node.syncPut": {
        // A sync's packed pieces, in the file at `c`, sent to station `a` in the request `b` after it (`d`), or, to a
        // station from before (its transport threw NoBytes, the program then asks so), base64 in it; in their turn
        // with the station's other bulk requests.
        if (d === true) {
          const size = (await stat(c)).size;
          return await this.bulk.run(() => this.ask(a, withBytes(b, fileBytes(c, 0, size))));
        }
        const data = (await readFile(c)).toString("base64");
        return await this.bulk.run(() => this.ask(a, { ...b, data }));
      }
      case "node.bringBack":
        return await this.bringBack(a);
    }
    throw new Error(`no remote ask ${f}`);
  }

  /// What the program tells the station of the remote tasks, needing no answer.
  private told(f: string, args: Json[]): void {
    if (f === "writing") {
      const [path, id] = args as [string, number];
      let end!: () => void;
      const done = new Promise<void>((resolve) => (end = resolve));
      const theirs = programWriting.get(path) ?? new Map();
      theirs.set(id, { done, end });
      programWriting.set(path, theirs);
      return;
    }
    if (f === "wrote") {
      const [path, id] = args as [string, number];
      const theirs = programWriting.get(path);
      theirs?.get(id)?.end();
      theirs?.delete(id);
      if (theirs?.size === 0) programWriting.delete(path);
      return;
    }
    if (f === "used") {
      // A chat's use record as the program has it now (null: none); one changed here since is told by its answer.
      const [path, record] = args as [string, Json | null];
      if (this.usedAsked.has(path)) this.usedHeld.set(path, record ?? null);
      else this.usedCache.set(path, record ?? null);
      return;
    }
    if (f === "usedReady") {
      this.usedReady = true;
      return;
    }
    if (f === "log") {
      const [level, message, fields] = args;
      (level === "warn" ? log.warn : level === "error" ? log.error : log.info)("remote", message, fields ?? {});
    }
  }

  /// The transport is there (the bus's, mesh/mesh.ts; a test's).
  attach(call: PeerCall): void {
    this.bus.attach(call);
  }

  /// Follows the tasks started from here and the sessions closing, tells the sources of tasks here what they missed;
  /// sweeps now and hourly; moves prepared records from before (all the program's).
  private started(): void {
    void this.call("attached", []).catch(() => undefined);
  }

  /// Schedule the cleanup across station restarts, remembering each completed sweep.
  private startBackTidying(record: NonNullable<RemoteOptions["backTidy"]>): void {
    // Updates can restart the station more often than this hourly cleanup. Remember the last completed sweep, so a new
    // process waits only for what remains of the hour. A missing or unreadable record means it should sweep now.
    const delay = Effect.promise(async () => {
      const last = await record.read().catch(() => null);
      return last === null ? 0 : Math.min(BACK_TIDY_MS, Math.max(0, last + BACK_TIDY_MS - this.store.now()));
    });
    const tidy = Effect.promise(async () => {
      try {
        if (this.stopped) return;
        await this.tidyBack();
        // An interrupted sweep must be tried again by the next station, not recorded as complete.
        if (!this.stopped) await record.write(this.store.now());
      } catch (error) {
        log.warn("remote", "could not clean brought-back files", { error: String(error) });
      }
    });
    void this.run(delay.pipe(
      Effect.flatMap((ms) => Effect.sleep(Duration.millis(ms))),
      Effect.andThen(tidy.pipe(Effect.repeat(Schedule.spaced("1 hour")))),
      Effect.asVoid,
    )).catch(() => undefined);
  }

  /// What tasks brought back (`station-back/<key>` of each session's workspace in use) let go of once nothing in it
  /// changed for BACK_KEPT_MS: kept indefinitely, these files can fill the disk. Off the station's thread.
  private async tidyBack(): Promise<void> {
    const now = wall.now();
    for (const row of this.store.liveSessions()) {
      if (this.stopped) return;
      const back = join(row.workspace, "station-back");
      for (const name of await readdir(back).catch(() => [] as string[])) {
        const dir = join(back, name);
        if ((await latestIn(dir)) < now - BACK_KEPT_MS) await rm(dir, { recursive: true, force: true }).catch(() => undefined);
      }
    }
  }

  /// Its schedules end (the station stops).
  async close(): Promise<void> {
    this.stopped = true;
    this.workspaceReader.close();
    await Effect.runPromise(Scope.close(this.scope, Exit.void));
  }


  private serially<T>(f: () => Promise<T>): Promise<T> {
    const result = this.serial.then(f, f);
    this.serial = result.catch(() => undefined);
    return result;
  }

  room(workspace: string, peer: string, session: string): string {
    return join(this.root, "sessions", hash([workspace, peer, session]));
  }

  /// A source session's shared directory, made and noted as used (a command run there with a secret of the vault:
  /// vault/secrets.ts `heard`); its record written by the program.
  work(workspace: string, peer: string, session: string): string {
    const seen = this.seen(workspace, peer, session);
    if (seen.write) track(join(this.room(workspace, peer, session), "session.json"), this.call("writeSession", [workspace, peer, session, seen.now]).catch(() => undefined));
    return seen.work;
  }

  /// Makes a source session's shared directory and notes when it was last used (at most once a minute): `write`, its
  /// record is to be written saying `now` (the program's: remote.mbt `seen`).
  private seen(workspace: string, peer: string, session: string): { work: string; write: boolean; now: number } {
    const room = this.room(workspace, peer, session);
    const now = this.store.now();
    // Used within the minute: noted already (its record's write may still be on its way: `closeHere` asks this too).
    const last = this.seenAt.get(room);
    if (last !== undefined && now - last < 60_000) return { work: join(room, "work"), write: false, now };
    mkdirSync(join(room, "work"), { recursive: true }); // sync: work() gives the directory at once; once a minute a room
    this.seenAt.set(room, now);
    return { work: join(room, "work"), write: true, now };
  }

  /// A source session's tasks' directories and its room taken out of their places in one step, its use asked again just
  /// before (`seen` > `since`: used meanwhile, nothing taken: null); `since` null, at once (its source asked). A use
  /// after this makes the room anew. What the program removes then: {aside, room}.
  private closeRoom(room: string, dirs: string[], since: number | null): Json {
    if (since !== null && (this.seenAt.get(room) ?? 0) > since) return null;
    const gone = (path: string) => `${path}.gone-${randomBytes(4).toString("hex")}`;
    const aside: string[] = [];
    for (const dir of dirs) {
      const to = gone(dir);
      try {
        renameSync(dir, to); // sync: the tasks' directories and the room go in one step after their use is asked again
        aside.push(to);
      } catch {}
    }
    const roomGone = gone(room);
    let moved = false;
    try {
      renameSync(room, roomGone); // sync: in the same step as its tasks' directories, so that no work() comes between
      moved = true;
    } catch {}
    this.seenAt.delete(room);
    return { aside, room: moved ? roomGone : null };
  }

  /// The target's own cleanup (the program's): a source session's directory unused for IDLE_MS, with nothing running,
  /// goes; so do task directories from before shared session directories, and mirrors long unused.
  async sweep(now: number): Promise<void> {
    await this.call("sweep", [now]);
  }

  /// The disk of the station's data has less than DISK_LOW_BYTES free: mirrors go, the longest unused first (the
  /// program's).
  /// `below`: what counts as low (under the soft mark the mirrors go sooner: ops/disk.ts).
  async relieve(now: number, below = DISK_LOW_BYTES): Promise<void> {
    this.lowBelow = below;
    try {
      await this.call("relieve", [now]);
    } finally {
      this.lowBelow = DISK_LOW_BYTES;
    }
  }

  /// The upkeep's (ops/storage.ts Upkeep): tasks long over let go of, and the rooms held to their budget on a disk
  /// of `disk`'s size.
  async upkeep(now: number, disk: { free: number; total: number } | null): Promise<{ expired: number; freed: number }> {
    const expired = await this.expire(now);
    const freed = await this.budget(now, remoteBudget(disk?.total ?? null));
    return { expired, freed };
  }

  /// remote/sessions held to `budget` (the program's, remote_target.mbt `budget`): the mirrors not in use go first, the
  /// longest unused first; then the rooms with no task running there, the longest unused first. One used within
  /// ROOM_RECENT_MS, and anything a task runs in, stays. The bytes freed.
  async budget(now: number, budget: number): Promise<number> {
    const freed = await this.call("budget", [now, budget]);
    return typeof freed === "number" ? freed : 0;
  }

  /// Tasks long over let go of (the program's, remote_target.mbt `expire`): remote/incoming/<task> whose job ended
  /// TASKS_KEPT_MS ago (or the store no longer has, and unchanged as long), and remote/outgoing/<id>.json told its end
  /// (`delivered`) and unchanged as long. How many.
  async expire(now: number): Promise<number> {
    const gone = await this.call("expire", [now]);
    return typeof gone === "number" ? gone : 0;
  }

  /// Prepared records from before they were kept by session (remote/prepared/<hash>.json) moved into their session's
  /// (the program's, as the transport is there: `attached`).
  private async movePrepared(): Promise<void> {
    await this.call("movePrepared", []);
  }

  usedPath(session: string): string {
    return join(this.root, "used", `${hash(session)}.json`);
  }

  /// Stations on which this session has a remote workspace, within the workspace it still belongs to.
  workspaceTargets(session: string): { workspace: string; stations: string[] } | null {
    const row = this.store.getSession(session);
    if (!row || row.archivedAt !== null) return null;
    try {
      const workspace = this.workspace(row.ws ?? null);
      const record = this.usedRecord(this.usedPath(session));
      if (record === null || record.closing === true || record.workspace !== workspace || !Array.isArray(record.stations)) return null;
      return { workspace, stations: record.stations.filter((s: unknown): s is string => typeof s === "string" && s !== "") };
    } catch {
      return null;
    }
  }

  /// Resolve only a station this chat has used; the empty id names its own station.
  async workspaceStation(session: string, named: string): Promise<string> {
    if (!this.store.getSession(session)) throw new Error("unknown session");
    if (named === "" || named === this.ownId()) return "";
    const targets = this.workspaceTargets(session);
    if (targets === null) throw new Error("this chat has no remote workspace on that station");
    const station = targets.stations.includes(named) ? named : await this.stationNamed(targets.workspace, named);
    if (station === this.ownId()) return "";
    if (!targets.stations.includes(station)) throw new Error("this chat has no remote workspace on that station");
    return station;
  }

  /// The target answers immediately while its size is measured off the station's thread. Older or offline stations
  /// simply supply no reading; the next look tries again without treating the missing answer as an empty workspace.
  async workspaceSize(session: string, station: string, limit = DEFAULT_LIMIT): Promise<{ path: string; bytes: number; complete: boolean } | null> {
    const targets = this.workspaceTargets(session);
    if (!targets || !targets.stations.includes(station)) return null;
    const answer = await this.bounded(this.ask(station, { method: "session.size", workspace: targets.workspace, session, limit }), LIST_WAIT_MS);
    if (!answer || "error" in answer) return null;
    const value = answer.ok;
    if (value?.present !== true || value.pending === true || typeof value.path !== "string" || !Number.isSafeInteger(value.bytes) || value.bytes < 0 || typeof value.complete !== "boolean") return null;
    return { path: value.path, bytes: value.bytes, complete: value.complete };
  }

  /// A chat's use record as kept here (null: none). Until the program told every record it read as it started, one it
  /// did not tell yet is read here, once.
  private usedRecord(path: string): Json | null {
    const kept = this.usedCache.get(path);
    if (kept !== undefined) return kept;
    if (this.usedReady) return null;
    let read: Json | null;
    try {
      read = readJson(path); // sync: only until usedReady, as the program starts
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      read = null;
    }
    this.usedCache.set(path, read);
    return read;
  }

  /// A change of the use record at `path` asked of the program (`asked`): kept here as made until it answers with the
  /// record as it wrote it.
  private changed(path: string, asked: Promise<Json>): void {
    this.usedAsked.set(path, (this.usedAsked.get(path) ?? 0) + 1);
    const answered = asked.then((record) => ({ record }), () => null);
    track(path, answered);
    void answered.then((got) => {
      const left = (this.usedAsked.get(path) ?? 1) - 1;
      if (left > 0) return void this.usedAsked.set(path, left);
      this.usedAsked.delete(path);
      const held = this.usedHeld.get(path);
      this.usedHeld.delete(path);
      if (held !== undefined) this.usedCache.set(path, held);
      else if (got !== null) this.usedCache.set(path, got.record);
    });
  }

  /// The source remembers which stations a session ran tasks on, to ask them to clean up when it closes: kept here at
  /// once, written by the program (remote_source.mbt `record_use`, which a station_task of the program's calls itself).
  recordUse(workspace: string, session: string, station: string): void {
    const path = this.usedPath(session);
    let had: Json | null;
    try {
      had = this.usedRecord(path);
    } catch {
      had = null;
    }
    const known = had !== null && Array.isArray(had.stations) && had.stations.some((s: Json) => s === station);
    if (known && had.closing !== true) return;
    const v: Json = had === null ? { session, workspace, stations: [] } : structuredClone(had);
    if (!known) {
      if (!Array.isArray(v.stations)) throw new Error("bad record");
      v.stations.push(station);
    }
    // Used again after closing (shown again): close later from the start.
    v.closing = false;
    v.closed = [];
    v.workspace = workspace;
    this.usedCache.set(path, v);
    this.changed(path, this.call("recordUse", [workspace, session, station]));
  }

  /// A session was archived or deleted: its tasks on other stations stop and their directories are removed. Asked until
  /// each station has answered (30 days at most), across restarts (the program's: remote_source.mbt `close_session`).
  closeSession(session: string): void {
    const path = this.usedPath(session);
    let had: Json | null = null;
    try {
      had = this.usedRecord(path);
    } catch {}
    const since = this.store.now();
    if (had !== null) this.usedCache.set(path, { ...structuredClone(had), closing: true, since });
    this.changed(path, this.call("closeSession", [session, since]));
  }

  /// Where messages from other stations' sessions go (session.message): any station of the workspace may send them,
  /// trusted for tasks or not.
  setInbox(inbox: Inbox): void {
    this.bus.on([
      "session.message", "session.read", "session.file", "session.put",
      "session.create", "session.create.preset", "session.create.speed", "session.create.preset.speed", "session.create.preset.tui",
      "session.archive", "session.configure", "session.list", "session.notice",
    ], inbox);
  }

  /// Where requests about what stations share go (share.*, share/index.ts): any station of the workspace may ask;
  /// what each share allows is checked there.
  setShares(shares: Inbox): void {
    this.bus.on("share.", shares);
  }

  /// Where requests about the agents' memory go (memory.*, share/memory.ts): the stations of the workspace it is of.
  setMemory(memory: Inbox): void {
    this.bus.on("memory.", memory);
  }

  /// Where requests about chats shared across workspaces go (xshare.*, xshare/index.ts): `inside` those of this
  /// workspace's stations, `outside` every request of a station that is not of it (the transport lets those through
  /// only while there is one).
  setOutside(handlers: { inside: Inbox; outside: Inbox }): void {
    this.bus.on("xshare.", handlers.inside);
    this.bus.outside(handlers.outside);
  }

  /// How this station's load is measured (load.ts `measure`), for `describe`.
  setLoad(load: () => Promise<Json>): void {
    this.load = load;
  }

  /// What is said of a workspace's rig in station_list besides how busy it is (rigs/module.ts): whose it is, whether
  /// the asking chat may use it and who may. `described`: its `describe` answer, null when it was not reached.
  setRigs(said: (workspace: string, session: string, rig: Json, described: Json | null) => Promise<Json>): void {
    this.rigs = said;
  }

  /// What this machine says of itself besides (`describe`), to the station asking: a rig says it is one, what of a
  /// station it is not (no chats, no sessions), and who may use it (rig/module.ts).
  setDescribed(more: (peer: string, workspace: string) => Json): void {
    this.described = more;
  }

  /// `what`, or null when it has not settled within `ms` on the clock (it goes on); its rejection as `error`.
  private async bounded<T>(what: Promise<T>, ms: number): Promise<{ ok: T } | { error: Error } | null> {
    let out: { ok: T } | { error: Error } | null = null;
    const settled = what.then(
      (ok) => void (out = { ok }),
      (error) => void (out = { error: error instanceof Error ? error : new Error(String(error)) }),
    );
    await this.run(Effect.race(Effect.promise(() => settled), Effect.sleep(Duration.millis(ms)))).catch(() => undefined);
    return out;
  }

  /// A host reading with its own time, or why it is unavailable; a slow reader never holds a task reply indefinitely.
  private async measuredLoad(): Promise<Json> {
    const read = this.load;
    if (read === null) return { unavailable: "not measured" };
    const load = await this.bounded(Promise.resolve().then(read), LOAD_WAIT_MS);
    return load === null ? { unavailable: `not measured within ${LOAD_WAIT_MS / 1000} s` } : "ok" in load ? load.ok : { unavailable: load.error.message };
  }

  /// `describe`'s answer: what this station takes, and how busy it is (`load`, LOAD_WAIT_MS at most).
  private async describe(peer = "", workspace = ""): Promise<Json> {
    const answer: Json = { protocol: 1, version: this.version, os: OS, arch: ARCH, tasks: true, sessions: true, messages: true, reads: true, files: true, chats: true, acceptAutoChats: this.acceptAutoChats?.() === true, sync: 1, smallTasks: 1, fileChunkBytes: CHUNK, maxFileBytes: MAX_FILE };
    if (this.load !== null) answer.load = await this.measuredLoad();
    return this.described === null ? answer : { ...answer, ...this.described(peer, workspace) };
  }

  /// This station's own description (load, mode, sessions) without sending a peer RPC to itself.
  selfDescribe(): Promise<Json> {
    return this.describe();
  }

  /// station_list: the stations of `workspace`, each asked how busy it is at once (this one answers itself); one that
  /// has not answered within LIST_WAIT_MS is listed unanswered, one that refused says why, one safe mode leaves out
  /// (the roster's `unprotected`) after them, not asked, saying why it cannot be called. Each says its version itself.
  private async listStations(workspace: string, session: string): Promise<Json> {
    const { unprotected, ...roster } = (await this.ask("", { method: "peers", workspace })) ?? {};
    const own = this.ownId();
    const stations = Array.isArray(roster?.stations) ? roster.stations : [];
    const left = (Array.isArray(unprotected) ? unprotected : []).map((entry: Json) => ({ ...entry, unprotected: UNPROTECTED }));
    const listed = await Promise.all(
      stations.map(async (entry: Json) => {
        const id = text(entry, "id");
        if (id === "") return entry;
        const { version: seen, ...rest } = entry;
        if (id === own) return { ...rest, here: true, version: this.version, load: summary((await this.describe()).load ?? null) };
        const got = await this.bounded(this.ask(id, { method: "describe", workspace }), LIST_WAIT_MS);
        return { ...rest, ...heard(got, seen) };
      }),
    );
    // Its stations that only run tasks (rigs: rigs/module.ts says whose each is and who may use it) after the whole
    // ones, in the same list, `mode: "tasks"`: asked the same way, at once.
    const rigs = Array.isArray(roster?.rigs) ? (roster.rigs as Json[]) : [];
    const said = this.rigs;
    // Its sandboxes too (agents/sandbox.ts), by `sandbox:<name>`: nothing to ask, they are this station's.
    const sandboxes = (this.sandboxes?.() ?? []).map((d) => ({ id: SANDBOX + d.name, name: d.name, ...sandboxDescribed(d) }));
    listed.push(...sandboxes);
    if (rigs.length === 0 || said === null) return { ...roster, stations: [...listed, ...left], rigs: undefined, rigsWaiting: undefined };
    const listedRigs = await Promise.all(
      rigs.map(async (rig: Json) => {
        const entry = { id: text(rig, "id"), name: text(rig, "name") };
        const got = await this.bounded(this.ask(entry.id, { method: "describe", workspace }), LIST_WAIT_MS);
        return { ...entry, ...(await said(workspace, session, rig, got !== null && "ok" in got ? got.ok : null)), ...heard(got, field(rig, "version")) };
      }),
    );
    const { rigs: _, rigsWaiting: __, ...rest } = roster as Record<string, Json>;
    return { ...rest, stations: [...listed, ...listedRigs, ...left] };
  }

  /// The id of the station an agent names: station_list shows each by its name and its id, and either is taken. A name
  /// no station of the workspace has (a station of another workspace this one shares chats with is named by its id)
  /// goes on as given, to be refused or reached as an id.
  private async stationNamed(workspace: string, named: string): Promise<string> {
    if (named === "") return named;
    // One of its sandboxes, by `sandbox:<name>` or its name.
    const lower = named.toLowerCase();
    const sandbox = (this.sandboxes?.() ?? []).find((d) => (SANDBOX + d.name).toLowerCase() === lower || d.name.toLowerCase() === lower);
    if (sandbox !== undefined) return SANDBOX + sandbox.name;
    let stations: Json[] = [];
    let roster: Json;
    try {
      roster = await this.ask("", { method: "peers", workspace });
      // One safe mode leaves out too: named, it is refused saying why (peer.ts `member`).
      stations = [roster?.stations, roster?.rigs, roster?.unprotected].flatMap((list) => (Array.isArray(list) ? list : []));
    } catch {
      return named;
    }
    if (stations.some((s) => text(s, "id") === named)) return named;
    // (a rig is named as a station is: what runs on one is asked of it the same way)
    const same = stations.filter((s) => text(s, "name").toLowerCase() === named.toLowerCase());
    if (same.length > 1) throw new Error(`${same.length} stations are named ${named}; give the id station_list shows for the one meant`);
    if (same.length === 1) return text(same[0], "id");
    // A rig of a workspace in security mode its person has not signed for: no station sends it anything, said so.
    const waiting = (Array.isArray(roster?.rigsWaiting) ? (roster.rigsWaiting as Json[]) : []).find((r) => text(r, "id") === named || text(r, "name").toLowerCase() === named.toLowerCase());
    if (waiting !== undefined) throw new Error(`the station ${text(waiting, "name") || named} is not taken into this workspace yet: its owner ${text(waiting, "owner_email") || text(waiting, "owner")} has to check its security code in still.fail first`);
    return named;
  }

  /// mesh/cloud.json as the station keeps it in memory (`followRoster`); read from the file where none is given (tests).
  /// Read again at every task, the file held the main thread on a station whose disk was kept busy.
  place: (() => Json | null) | null = null;

  private cloudState(): Json {
    return this.place !== null ? this.place() : readJson(join(this.data, "mesh", "cloud.json"));
  }

  /// This station's id (mesh/cloud.json), "" when it has none.
  private ownId(): string {
    try {
      return text(this.cloudState(), "station");
    } catch {
      return "";
    }
  }

  /// Whether stations of other workspaces are heard at all.
  hearsOutside(): boolean {
    return this.bus.hearsOutside();
  }

  /// A request of a station that is not of this workspace (the transport checked it names this workspace).
  handleOutside(peer: string, request: Json, workspace?: string): Promise<Json> {
    return this.bus.handleOutside(peer, request, workspace);
  }

  /// A request to another station of the workspace (session_send's messages, and this module's own). One to a sandbox
  /// is this station's own: answered here as a station's would be, its tasks run in the sandbox.
  ask(station: string, request: Json): Promise<Json> {
    if (station.startsWith(SANDBOX)) {
      const workspace = text(request, "workspace");
      const sandbox = this.sandboxes?.().find((d) => SANDBOX + d.name === station);
      if (sandbox === undefined) return Promise.reject(new Refused("no such sandbox on this station (config.json's sandboxes)"));
      if (text(request, "method") === "describe") return Promise.resolve(sandboxDescribed(sandbox));
      return this.bus.handle(workspace, station, request);
    }
    return this.bus.ask(station, request);
  }

  /// Where this station's sandboxes come from (config.json's, sessions/agents.ts).
  setSandboxes(list: () => Sandbox[]): void {
    this.sandboxes = list;
  }

  /// Called only after the transport authenticates the source station and checks current workspace membership.
  handle(workspace: string, peer: string, request: Json): Promise<Json> {
    return this.bus.handle(workspace, peer, request);
  }

  /// Peers removed from a workspace (or the workspace left) have their tasks stopped, without touching any local jobs.
  /// `rosters`: each workspace the station is in now, with its other stations.
  revoke(rosters: { workspace: string; peers: string[] }[], membershipCurrent: boolean): Promise<void> {
    return this.serially(async () => {
      await this.call("revoke", [rosters as unknown as Json, membershipCurrent]);
    });
  }

  /// The workspace a session's tasks go in (mesh/cloud.json): its chat's, the home one for those from before; while the
  /// station is still in it.
  private workspace(own: string | null): string {
    const state = this.cloudState();
    if (state === null) throw new Error("station has no workspace");
    if ((field(state, "removed_at") ?? null) !== null) throw new Error("station was removed from workspace");
    const home = text(state, "workspace");
    if (home === "") throw new Error("station has no workspace");
    const ws = own ?? home;
    const joined = field(state, "joined");
    if (ws !== home && !(Array.isArray(joined) && joined.some((j: Json) => text(j, "workspace") === ws))) throw new Error("station is no longer in this chat's workspace");
    return ws;
  }

  outgoing(workspace: string, session: string, station: string, key: string): string {
    return join(this.root, "outgoing", `${hash([workspace, session, station, key])}.json`);
  }

  /// station_list (the program's tool asks it here): the stations of the workspace, or one in detail.
  private async stationList(workspace: string, session: string, station: string): Promise<Json> {
    if (station === "") return this.listStations(workspace, session);
    if (station === this.ownId()) return detailed(await this.describe());
    // Waited for longer than in the list: one starting or updating itself has its time to answer.
    const got = await this.bounded(this.ask(station, { method: "describe", workspace }), LIST_ALONE_WAIT_MS);
    if (got === null) return { id: station, unanswered: `did not answer within ${LIST_ALONE_WAIT_MS / 1000} s; not known to be offline (it may be starting or updating): ask again in a minute` };
    if ("error" in got) throw got.error;
    return detailed(got.ok);
  }

  // ── a task's files sent and fetched, for the program ──

  /// file.put: an input of a task, whole after the request (its bytes kept for it: `bytes`), or a chunk of base64 in it
  /// from a station from before; {bytes, whole: whether the file is all there now}.
  private async filePut(path: string, request: Json): Promise<Json> {
    const incoming = typeof request?.bytes === "number" ? this.inBytes.get(request.bytes) : undefined;
    if (incoming !== undefined) {
      this.inBytes.delete(request.bytes);
      const size = asU64(field(request, "size"));
      if (size === null || size > MAX_FILE) throw new Error("file limit exceeded");
      const file = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o666);
      try {
        if (!(await file.stat()).isFile()) throw new Error("only regular files can be transferred");
        if ((await writeBytes(file, incoming, 0, size)) !== size) throw new Error("the file did not all come");
        await file.truncate(size);
        await file.sync();
      } finally {
        await file.close();
      }
      return { bytes: size, whole: true };
    }
    const offset = asU64(field(request, "offset"));
    if (offset === null) throw new Error("offset is required");
    const data = fromBase64(text(request, "data"));
    if (data.length > CHUNK || offset + data.length > MAX_FILE) throw new Error("file limit exceeded");
    const file = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o666);
    try {
      const stat = await file.stat();
      if (!stat.isFile()) throw new Error("only regular files can be transferred");
      if (offset > stat.size) throw new Error("file offset leaves a gap");
      for (let at = 0; at < data.length; ) at += (await file.write(data, at, data.length - at, offset + at)).bytesWritten;
      if (field(request, "final") === true) {
        await file.truncate(offset + data.length);
        await file.sync();
      }
    } finally {
      await file.close();
    }
    return { bytes: data.length, whole: field(request, "final") === true };
  }

  /// file.get: a task's file, all of it from `offset` after the answer (`outBytes`), or a chunk to a station from before.
  private async fileGet(path: string, request: Json): Promise<Json> {
    const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = await file.stat();
      if (!stat.isFile()) throw new Error("only regular files can be transferred");
      const size = stat.size;
      if (size > MAX_FILE) throw new Error("file limit exceeded");
      const offset = asU64(field(request, "offset")) ?? 0;
      if (offset > size) throw new Error("offset past end");
      if (field(request, "whole") === true) {
        const id = ++this.bytesNext;
        this.outBytes.set(id, fileBytes(path, offset, size));
        return { size, outBytes: id };
      }
      const buffer = Buffer.alloc(CHUNK);
      const { bytesRead: n } = await file.read(buffer, 0, CHUNK, offset);
      return { data: buffer.subarray(0, n).toString("base64"), size, eof: offset + n >= size };
    } finally {
      await file.close();
    }
  }

  /// A file of a task's station (`request`'s path) to `path` here, whole after one answer (a station from before answers
  /// a chunk, and is asked for each); its size. An existing file is replaced only when `replace`.
  private async download(ask: (request: Json) => Promise<Json>, request: Json, path: string, replace: boolean): Promise<number> {
    if (!replace && (await there(path))) throw new Error("local output already exists; choose another path");
    const temp = withExtension(path, `${randomBytes(8).toString("hex")}.part`);
    // Written off the station's thread: each chunk, and the whole flushed to the disk (a task's files brought back held
    // it 3 s so on a machine short of memory, 2026-10-25).
    const file = await open(temp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o666);
    try {
      let size: number;
      try {
        let offset = 0;
        for (;;) {
          const answer = await this.bulk.run(async () => {
            const got = await ask({ ...request, method: "file.get", offset, whole: true });
            const bytes = bytesOf(got);
            if (bytes !== null) offset += await writeBytes(file, bytes, offset, MAX_FILE);
            return got;
          });
          if (bytesOf(answer) !== null) {
            if (offset !== asU64(field(answer, "size"))) throw new Error("the file did not all come");
            await file.sync();
            size = offset;
            break;
          }
          const data = fromBase64(text(answer, "data"));
          if (data.length > CHUNK || offset + data.length > MAX_FILE) throw new Error("invalid file response");
          for (let at = 0; at < data.length; ) at += (await file.write(data, at, data.length - at)).bytesWritten;
          offset += data.length;
          if (field(answer, "eof") === true) {
            await file.sync();
            size = offset;
            break;
          }
          if (data.length === 0) throw new Error("file transfer made no progress");
        }
      } finally {
        await file.close();
      }
      if (replace) await rename(temp, path);
      else await link(temp, path);
      return size;
    } finally {
      await rm(temp, { force: true });
    }
  }

  /// A file of a task's station in memory; null when it is bigger than `limit`.
  private async fetchFile(ask: (request: Json) => Promise<Json>, path: string, limit: number): Promise<Buffer | null> {
    const parts: Buffer[] = [];
    for (let offset = 0; ; ) {
      const got = await this.bulk.run(async () => {
        const answer = await ask({ method: "file.get", path, offset, whole: true });
        const bytes = bytesOf(answer);
        const size = asU64(field(answer, "size")) ?? 0;
        if (size > limit) {
          if (bytes !== null) await stopBytes(bytes);
          return null;
        }
        if (bytes === null) return { data: fromBase64(text(answer, "data")), eof: field(answer, "eof") === true };
        const data = await readBytes(bytes, limit);
        if (offset + data.length !== size) throw new Error("the file did not all come");
        return { data, eof: true };
      });
      if (got === null) return null;
      parts.push(got.data);
      offset += got.data.length;
      if (got.eof) return Buffer.concat(parts);
      if (got.data.length === 0) throw new Error("file transfer made no progress");
    }
  }

  /// After a task ends: what it was to bring back (`back`, into station-back/<key> of its session's workspace), and,
  /// for a task with a directory, the synced files its command changed there, as a patch for the agent to apply or
  /// not (nothing here is overwritten). An Unreached when its station could not be asked (asked again next round).
  private async bringBack(entry: Json): Promise<Json> {
    const station = text(entry, "station");
    const key = text(entry, "key");
    const base = { workspace: field(entry, "workspace"), session: field(entry, "session"), key };
    const ask = (request: Json) =>
      this.ask(station, { ...base, ...request }).catch((error) => {
        throw error instanceof Refused ? error : new Unreached((error as Error).message);
      });
    const row = this.store.getSession(text(entry, "session"));
    if (!row) return { error: "the session is gone" };
    const dest = join(row.workspace, "station-back", portableComponent(key));
    const out: Json = {};
    const back: string[] = Array.isArray(entry.back) ? entry.back : [];
    if (back.length > 0) {
      let files: [string, number | null][];
      let prefix = "";
      try {
        const found = await ask({ method: "task.files", paths: back });
        files = found.files;
        prefix = text(found, "base") === "" ? "" : `${text(found, "base")}/`;
      } catch (error) {
        // A station from before has no task.files: the paths are files.
        if (!(error instanceof Refused && /unsupported peer method/.test(error.message))) throw error;
        files = back.map((p) => [p, 0]);
      }
      await mkdir(dest, { recursive: true });
      const got: string[] = [];
      const missing: string[] = [];
      for (const [p, size] of files) {
        if (size === null) {
          missing.push(`${p}: not there`);
          continue;
        }
        try {
          await this.download(ask, { path: prefix + p }, await filePath(dest, p, true), true);
          got.push(p);
        } catch (error) {
          if (error instanceof Unreached) throw error;
          missing.push(`${p}: ${(error as Error).message}`);
        }
      }
      out.files = { dir: dest, count: got.length, files: got.slice(0, 50), missing };
    }
    if (typeof entry.dir === "string") {
      let found: Json;
      try {
        found = await ask({ method: "sync.changes" });
      } catch (error) {
        if (error instanceof Unreached) throw error;
        out.changed = { error: (error as Error).message };
        return out;
      }
      const changes: Json[] = Array.isArray(found?.changes) ? found.changes : [];
      if (changes.length > 0) {
        const items = [];
        const missing: string[] = [];
        let total = 0;
        for (const c of changes) {
          let after: Buffer | null = null;
          if (c.newMode === LINK) after = Buffer.from(String(c.link ?? ""));
          else if (c.hash !== null) {
            try {
              after = await this.fetchFile(ask, `${text(found, "base")}/${c.path}`, PATCH_MAX - total);
            } catch (error) {
              if (error instanceof Unreached) throw error;
            }
            if (after === null) {
              missing.push(c.path);
              continue;
            }
            total += after.length;
          }
          items.push({ path: String(c.path), old: String(c.old), mode: String(c.mode), after, afterMode: c.newMode ?? null });
        }
        const made = await patchOf(entry.dir, text(entry, "prefix"), join(this.root, `patch-${randomBytes(6).toString("hex")}`), items);
        const changed: Json = {
          count: changes.length,
          more: found.more === true,
          files: changes.slice(0, 50).map((c) => c.path),
          note: "the command changed these synced files on that station; nothing here was changed",
        };
        if (made !== null && made.patch !== "") {
          await mkdir(dest, { recursive: true });
          const file = join(dest, "changes.patch");
          await writeFile(file, made.patch);
          changed.patch = file;
          changed.apply = `review it, then git apply it in ${entry.dir} if wanted`;
        }
        const left = [...missing, ...(made?.missing ?? (made === null ? changes.map((c) => String(c.path)) : []))];
        if (left.length > 0) changed.notInPatch = left.slice(0, 50);
        out.changed = changed;
      }
    }
    return out;
  }

  /// What a directory sync of `dir` sends from here (the program's listing: dirsync_source.mbt `list_local`), for the
  /// tests that compare it with what the TypeScript listed (test/dirsync-reference.ts).
  async listLocal(dir: string): Promise<Json> {
    return await this.call("listLocal", [dir]);
  }

  /// What the station_* tools do, as `session`: among the stations of its workspace (the program's).
  async tool(tool: string, session: string, args: Json): Promise<Json> {
    return await this.call("tool", [tool, session, args]);
  }

  /// station_file (the program's tool asks it here): an input uploaded, an output downloaded into `root`, the session's
  /// workspace.
  private async stationFile(station: string, request: Json, args: Json, root: string): Promise<Json> {
    const localArg = text(args, "local");
    let relative = localArg;
    if (isAbsolute(localArg)) {
      // Path::strip_prefix: whole components of the session's workspace (as the machine compares them); a `..` left in
      // it is filePath's to refuse.
      const within = platform.paths.relativeIn(root, localArg);
      if (within === null) throw new Error("local file must be inside this session workspace");
      relative = within;
    }
    const direction = text(args, "direction");
    const path = await filePath(root, relative, direction === "download");
    request.path = field(args, "path");
    if (direction === "upload") {
      const file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      try {
        const stat = await file.stat();
        const size = stat.size;
        if (!stat.isFile() || size > MAX_FILE) throw new Error("input must be a regular file of at most 1 GiB");
        // Whole, after one request; to a station from before, in chunks.
        try {
          await this.bulk.run(() => this.ask(station, withBytes({ ...request, method: "file.put", offset: 0, size }, fileBytes(path, 0, size))));
          return { uploaded: path, bytes: size };
        } catch (error) {
          if (!(error instanceof NoBytes)) throw error;
        }
        let offset = 0;
        for (;;) {
          const chunk = Buffer.alloc(CHUNK);
          const { bytesRead: n } = await file.read(chunk, 0, CHUNK, offset);
          request.method = "file.put";
          request.offset = offset;
          request.data = chunk.subarray(0, n).toString("base64");
          request.final = offset + n === size;
          await this.bulk.run(() => this.ask(station, { ...request }));
          offset += n;
          if (offset === size) break;
          if (n === 0) throw new Error("input changed while reading");
        }
        return { uploaded: path, bytes: size };
      } finally {
        await file.close();
      }
    }
    if (direction === "download") {
      const size = await this.download((r) => this.ask(station, r), request, path, false);
      return { downloaded: path, bytes: size };
    }
    throw new Error("direction must be upload or download");
  }
}

/// The target side of the station transport: a request taken in, its answer as the wire has it
/// (`{"result": …}` or `{"error": "…"}`). The transport checks the peer and its workspace before.
export async function answerPeer(remote: Remote, workspace: string, peer: string, request: Json): Promise<Json> {
  try {
    return { result: await remote.handle(workspace, peer, request) };
  } catch (error) {
    return { error: (error as Error).message };
  }
}

/// Tasks of peers no longer in the workspace, or no longer allowed, stop: looked at whenever the roster or the config
/// changes.
export function followRoster(cloud: Cloud, remote: Remote, config: { listen(f: () => void): () => void }): () => void {
  remote.place = () => cloud.state as unknown as Json;
  const look = () => {
    const rosters = cloud.memberships().map((m) => ({ workspace: m.workspace, peers: m.peers.flatMap((p) => (typeof p?.id === "string" ? [p.id as string] : [])) }));
    void remote
      .revoke(rosters, cloud.peersCurrent)
      .catch((error) => log.warn("peer", "revoking tasks failed", { error: (error as Error).message }));
  };
  look();
  const unlisten = cloud.listen(look);
  const unconfig = config.listen(look);
  return () => (unlisten(), unconfig());
}
