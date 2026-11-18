// Background jobs: commands a session's agent starts that the station runs and keeps, apart from
// the agent's turns. Each runs in a process group of its own with its output in a log file; the agent hears when it
// ends, and whatever the job says on the way (`stillfail-job notify …`). A job with a port is a web service: kept up
// (started again when it ends, with a growing pause), and seen by the workspace's members through the station's
// /preview. Jobs outlive the station: a restart takes up what still runs, and starts again what does not (the machine
// restarted). They are not run under runners: their own groups and exit files are what lets them outlive it.
//
// Push, not poll: a job this station started is followed by its exit event; one an earlier station started (not its
// child) by its exit file appearing (a watch on jobs/exit), with a look at its leader once a second for the one end
// that writes no file (its shell killed) — Node has no exit event for a process that is not its child.
import { randomBytes } from "node:crypto";
import { type FSWatcher, existsSync, mkdirSync, readFileSync, watch } from "node:fs";
import { access, appendFile, lstat, open, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { join, sep } from "node:path";
import { Clock, Effect, Exit, FiberSet, Schedule, Scope } from "effect";
import { startEnv } from "../ops/agent-env.ts";
import { liveClock } from "../ops/fibers.ts";
import { log } from "../ops/log.ts";
import { JOB_LOG_CAP, rotateInPlace } from "../ops/storage.ts";
import { niced } from "../ops/nice.ts";
import { startLasting } from "../ops/processes.ts";
import { platform } from "../platform/index.ts";
import { type Sandbox, type SandboxPlace, sandboxCommand } from "../agents/sandbox.ts";
import { outputAt, tail } from "../read/jobs.ts";
import { ActorsProgram } from "../sessions/mb-actor.ts";
import { type JobRow, type Json, type ProcessRow, type Store } from "../store/store.ts";
import { endGroup, groupAlive, pidAlive, signalGroup, stillOurs } from "../ops/group.ts";
import type { Pressure, Why } from "./admit.ts";

export { outputAt, tail };

/// A job's log, and what is left of it, kept this long after its job ended (`collect`).
export const JOB_LOGS_KEPT_MS = 14 * 24 * 3600_000;
/// How many of its files (or reads of the store) `collect` goes through before it gives the loop back once.
export const COLLECT_YIELD_EVERY = 32;
/// A job's files whose job the store no longer has (its session deleted, its record cleared) kept this long.
export const JOB_FILES_ORPHAN_MS = 3600_000;

/// How many lines job_log gives by default.
export const LOG_LINES = 50;
/// How many of a job's notices the pages get with it.
const NOTICES_SHOWN = 20;
/// A job stopped from the pages is told to its agent only if the agent was at work this lately: one idle longer is not
/// woken for it (the job's state shows it stopped when the agent next looks).
const AWAKE_MS = 5 * 60_000;
/// How long a stop waits for a job's group to end before it is killed, and then for its end to be taken in.
const STOP_GRACE_MS = 5000;
const STOP_SETTLE_MS = 3000;
/// How often a stopping job's group is looked at, once its leader is gone, for members it left behind.
export const STOP_LOOK_MS = 100;
/// How often a job an earlier station started is looked at (its end when it wrote no exit file).
const FOLLOW_LOOK_MS = 1000;
/// What /jobs/notify takes at most.
export const NOTIFY_BODY_LIMIT = 64 * 1024;

/// How a job's command runs: under a shell that writes its exit code to a file when it ends, so a station that did not
/// start it (it outlived the one that did) still learns how it ended.
// The exit code is written aside and moved into place: a watch on jobs/exit hears a file as it is made, and on Linux
// (inotify) a `>` made it empty before printf wrote it, so a job an earlier station started was read ended with no
// code (CI, 2026-11-17). The move makes it there whole or not at all.
export const WRAPPER = `/bin/sh -c "$1"; code=$?; printf '%s' "$code" > "$2.tmp" && mv -f "$2.tmp" "$2"; exit "$code"`;

/// A word for sh, as it is.
const quoted = (word: string) => `'${word.replace(/'/g, `'\\''`)}'`;

/// What `stillfail-job` is, in each job's PATH: `stillfail-job notify <words>` (or the words on stdin) tells the agent;
/// `stillfail-job screen <command>…` runs the command with the machine's screen (jobs/admit.ts: one task's at a time),
/// asking for it again each second while another has it (/jobs/screen, `screenEndpoint`), and gives it back when the
/// command ends; killed before it could, the station finds its shell gone. `stillfail-job show <command>…` puts up a
/// window for a person and leaves it (a virtual machine, a simulator to look at): it waits as `screen` does, so the
/// window does not come up under another task's work, then gives the screen back at once and runs the command,
/// holding nothing however long it lasts. A job of a station from before it (no
/// STILLFAIL_JOB_SCREEN) runs the command as it is; one whose station has not answered for a minute runs it, said.
export const JOB_COMMAND = `#!/bin/sh
# stillfail-job notify <words>: tells the agent that started this job (the words, or stdin's).
# stillfail-job screen <command>...: runs the command with this machine's screen (windows, a simulator, screenshots),
# one task's at a time: it waits while another task has it, and gives it back when the command ends. For work done in
# minutes; a window kept up for a person is show's.
# stillfail-job show <command>...: puts up a window for a person (a virtual machine, a simulator to look at) and leaves
# it: waits for the screen to be free, then runs the command holding nothing.
token=\${STILLFAIL_JOB_TOKEN:-}
notify=\${STILLFAIL_JOB_NOTIFY:-}
case "$1" in
  notify)
    shift
    if [ "$#" -gt 0 ]; then printf '%s' "$*"; else cat; fi |
      curl -fsS -X POST -H "Authorization: Bearer $token" -H "content-type: text/plain; charset=utf-8" --data-binary @- "$notify" >/dev/null
    ;;
  screen|show)
    how=$1
    shift
    [ "$#" -gt 0 ] || { echo "usage: stillfail-job $how <command>..." >&2; exit 2; }
    screen=\${STILLFAIL_JOB_SCREEN:-}
    [ -n "$screen" ] || exec "$@"
    # (the process the station looks at: under Git's sh on Windows, Windows' own)
    pid=$$
    [ -r /proc/$$/winpid ] && pid=$(cat /proc/$$/winpid)
    ask() { curl -sS -X POST -H "Authorization: Bearer $token" --data-binary "$1 $pid" "$screen" 2>&1; }
    told=0 unheard=0
    while :; do
      said=$(ask take)
      case "$said" in
        *'"yours"'*) break ;;
        *'"waiting"'*)
          unheard=0
          # (who has it: said once, and again when it is someone else)
          who=$(printf '%s' "$said" | sed -n 's/.*"who":"\\([^"]*\\)".*/\\1/p')
          if [ "$told" != 1 ] || [ "$who" != "$was" ]; then
            echo "stillfail-job $how: waiting for the screen (\${who:-another task has it})" >&2
          fi
          told=1 was=$who ;;
        *'"error"'*) echo "stillfail-job screen: $said" >&2; exit 1 ;;
        *)
          # (the station not answering: restarting, or gone)
          unheard=$((unheard + 1))
          if [ "$unheard" -ge 60 ]; then
            echo "stillfail-job screen: the station has not answered for a minute; running it without waiting for the screen" >&2
            break
          fi ;;
      esac
      sleep 1
    done
    give() { ask give >/dev/null; }
    # (show: the screen free, the window put up holding nothing)
    if [ "$how" = show ]; then give; exec "$@"; fi
    trap 'give; exit 129' HUP
    trap 'give; exit 130' INT
    trap 'give; exit 143' TERM
    "$@"
    code=$?
    give
    exit "$code"
    ;;
  *) echo "usage: stillfail-job notify <words> | stillfail-job screen <command>... | stillfail-job show <command>..." >&2; exit 2 ;;
esac
`;
export const JOB_COMMAND_NAME = "stillfail-job";

/// Tells a session's agent something (the hub's notify).
export type Notify = (session: string, text: string) => void;
/// A session's web service as members open it: its link (still.fail cloud's /o/ link of the session, naming the
/// service), when the station is in a workspace.
export type Link = (session: string, job: string) => string | null;

/// What the queue (jobs/admit.ts) measures of the machine: what the system says of its memory, and how long its input
/// has been idle (ms; none where it is not read: no person is seen at it).
export type Machine = { pressure(): Promise<Pressure | null>; inputIdle?(): Promise<number | null> };

export const liveMachine: Machine = {
  pressure: () => platform.memoryPressure(),
  inputIdle: () => platform.inputIdleMs(),
};

export type JobsOptions = {
  store: Store;
  /// The data directory: jobs live in its jobs/ (logs/, bin/, exit/).
  data: string;
  notify: Notify;
  link: Link;
  /// The clock its timers run on (a TestClock in tests).
  clock?: Clock.Clock;
  /// What the queue measures (the machine's own by default).
  machine?: Machine;
  /// The program the hub's actors run in (sessions/hub.ts `program`): the jobs' too. None: one of their own.
  program?: ActorsProgram | null;
};

/// What the program knows the jobs' shell by (as it knows an actor by its session).
const JOBS_KEY = "#jobs";

const hex = (n: number) => randomBytes(n).toString("hex");

/// JobRow as serde writes it (the token skipped, `sessionKey` as `session`).
export function jobJson(j: JobRow): Json {
  return {
    id: j.id, session: j.sessionKey, name: j.name, command: j.command, cwd: j.cwd, port: j.port, state: j.state, pgid: j.pgid,
    exitCode: j.exitCode, startedAt: j.startedAt, endedAt: j.endedAt, restarts: j.restarts, log: j.log, watch: j.watch,
    // Said only when so: what a station from before the queue answered has neither.
    ...(j.queued === true ? { queued: true } : {}),
    ...(j.screen === true ? { screen: true } : {}),
    ...(j.small === true ? { small: true } : {}),
  };
}

/// Whether a job is the queue's: another station's task (jobs/remote.ts names them `remote_…`).
export const queues = (job: JobRow): boolean => job.id.startsWith("remote_");

/// A job as the pages show it: its record, what it said lately (newest first) and when its output last grew.
export async function shown(store: Store, job: JobRow): Promise<Json> {
  const v = jobJson(job);
  v.notices = store.jobNotices(job.id, NOTICES_SHOWN);
  v.outputAt = await outputAt(job.log);
  return v;
}

/// The exit code a job's shell wrote when it ended, if it did.
async function readExitFile(path: string): Promise<number | null> {
  return await readFile(path, "utf8").then((t) => /^[+-]?\d+$/.test(t.trim()) ? Number(t.trim()) : null, () => null);
}

/// Where the claims that hold the screen are kept, in jobs/.
const SCREEN_FILE = "screen.json";

/// The claims an earlier station left holding the screen (what it wrote of them: none when there is nothing to read).
function heldClaims(path: string): Json[] {
  try {
    const kept: unknown = JSON.parse(readFileSync(path, "utf8")); // sync: read once, as Jobs is made, before the station serves
    if (!Array.isArray(kept)) return [];
    return kept.flatMap((c) =>
      typeof c?.job === "string" && Number.isInteger(c?.pid) && typeof c?.at === "number"
        ? [{ job: c.job, pid: c.pid, at: c.at, held: true, ...(typeof c?.since === "number" ? { since: c.since } : {}) }]
        : [],
    );
  } catch {
    return [];
  }
}

/// How a job is named to its agent.
export function named(job: Pick<JobRow, "id" | "name" | "port">): string {
  return job.port !== null ? `Service "${job.name}" (${job.id}, port ${job.port})` : `Job "${job.name}" (${job.id})`;
}

/// What a job a chat had running on a station retired is told as, started again (or not) as the chat moved here, or
/// back on that station as its move did not go through (replica/retire.ts): the words of a restart's (`relaunch`), the
/// move in place of the restart. `job` is its record here once it was started, else what it was named by there.
export function movedSaid(why: string, job: Pick<JobRow, "name" | "port"> & { id?: string | null }, error: string | null): string {
  const what = typeof job.id === "string" && job.id !== "" ? named({ id: job.id, name: job.name, port: job.port }) : job.port !== null ? `Service "${job.name}" (port ${job.port})` : `Job "${job.name}"`;
  return error === null ? `${why}; ${what} was started again.` : `${why}; ${what} could not be started again: ${error}`;
}

/// A job's command as Node runs it, until its end is taken in by the program.
type Running = {
  pgid: number;
  /// Its leader (the wrapper shell) is gone.
  gone: Promise<void>;
  /// Its end is taken in (the program answered its `exited`).
  settled: Promise<void>;
  settle: () => void;
};

/// The station's background jobs. What they are and do (a start's checks, the queue, the screen, an end told and a
/// service started again, a stop, a restart's taking up) is the MoonBit program's (station/mb's reader `--sessions`,
/// mb/src/reader/jobs.mbt and admit.mbt), as the pseudo-actor `#jobs` of the program the hub's actors run in (its own
/// where none is given: a rig's, a test's). This is what of them is the machine's, which the program asks for: a
/// command started in a group of its own and followed to its end, a signal sent, a log read, the memory and a person
/// at the machine looked at, the store; and what the station asks of them, said to the program.
export class Jobs {
  readonly store: Store;
  readonly dir: string;
  private readonly data: string;
  private notify: Notify;
  private link: Link;
  /// Where `stillfail-job notify` posts (the MCP endpoint's /jobs/notify).
  private notifyUrl = "";
  /// This station's sandboxes, by name (config.json's, sessions/agents.ts): where a sandbox's task runs.
  private sandboxes: (name: string) => Sandbox | null = () => null;
  private running = new Map<string, Running>();
  private closing = false;
  private scope: Scope.Closeable;
  /// Runs an effect as a fiber of these jobs' (a followed job's end): they end with it.
  private run: (effect: Effect.Effect<void>) => Promise<void>;
  /// Runs an effect on the jobs' clock but apart from them (a stop's grace goes on through a shutdown).
  private timed: (effect: Effect.Effect<void>) => Promise<void>;
  /// What waits for an exit file to appear, by job id; the watch on jobs/exit that tells them.
  private exitHeard = new Map<string, () => void>();
  private exitWatch: FSWatcher | null = null;
  private machine: Machine;
  /// The program they run in, and whether it is theirs alone (no hub gave one).
  readonly program: ActorsProgram;
  private own: boolean;

  /// Where this station's sandboxes are found (sessions/agents.ts).
  setSandboxes(find: (name: string) => Sandbox | null): void {
    this.sandboxes = find;
  }

  constructor(options: JobsOptions) {
    this.store = options.store;
    this.notify = options.notify;
    this.link = options.link;
    const dir = join(options.data, "jobs");
    this.dir = dir;
    this.data = options.data;
    for (const sub of ["logs", "bin", "exit"]) mkdirSync(join(dir, sub), { recursive: true }); // sync: once, as Jobs is made, before the station serves
    // Runnable by name from any shell (on Windows from cmd or PowerShell, Codex's shell there, too).
    const script = join(dir, "bin", JOB_COMMAND_NAME);
    try {
      platform.makeCommand(script, JOB_COMMAND);
    } catch (error) {
      // The script is there for a POSIX shell; only another shell's way to it (no Git's sh on Windows) is missing.
      if (!existsSync(script)) throw error; // sync: once, as Jobs is made, before the station serves
      log.warn("jobs", "no stillfail-job for cmd and PowerShell", { error: String(error) });
    }
    this.scope = Effect.runSync(Scope.make());
    const runtime = Scope.provide(FiberSet.makeRuntimePromise<never, void, never>(), this.scope);
    this.run = Effect.runSync(options.clock ? runtime.pipe(Effect.provideService(Clock.Clock, options.clock)) : runtime);
    const clock = options.clock;
    this.timed = (effect) => Effect.runPromise(clock ? effect.pipe(Effect.provideService(Clock.Clock, clock)) : effect);
    this.machine = options.machine ?? liveMachine;
    const given = options.program ?? null;
    const program = given ?? ActorsProgram.open(options.data, clock ?? liveClock);
    // (the program is built for every system the station runs on: a checkout that did not build it runs no job)
    if (program === null) throw new Error("the station's MoonBit program is not built here (station/mb: build.sh): no job can run");
    this.program = program;
    this.own = given === null;
    program.shell({ key: JOBS_KEY, runtime: "claude", asked: (f, args) => this.asked(f, args), told: (f, args) => this.told(f, args) });
    // The claims an earlier station left holding the screen: theirs still.
    void this.call("claims", [heldClaims(join(dir, SCREEN_FILE))]);
  }

  /// Asks the program's jobs `method`.
  private async call(method: string, args: Json[]): Promise<Json> {
    return await this.program.call(JOBS_KEY, method, args);
  }

  /// Where `stillfail-job notify` posts, once the endpoint listens.
  setNotifyUrl(url: string): void {
    this.notifyUrl = url;
  }

  /// Who hears that a remote task's job changed (it ended, or said something): Remote, which tells the station that
  /// asked for it.
  private remoteHeard: ((job: JobRow) => void)[] = [];

  /// `f` whenever a remote task's job ends or says something.
  onRemote(f: (job: JobRow) => void): void {
    this.remoteHeard.push(f);
  }

  private remoteChanged(id: string): void {
    if (!id.startsWith("remote_")) return;
    const job = this.store.getJob(id);
    if (!job) return;
    for (const f of this.remoteHeard) {
      try {
        f(job);
      } catch (error) {
        log.warn("jobs", "remote task change not heard", { job: id, error: (error as Error).message });
      }
    }
  }

  /// A remote task's notices are kept by its job and returned to the source station by Remote, not told here.
  private tell(job: JobRow, text: string): void {
    if (job.sessionKey.startsWith("remote:")) return this.remoteChanged(job.id);
    this.say(job.sessionKey, text);
  }

  /// A word of the jobs' for a session's agent from outside them (its chat moved here with jobs started again,
  /// replica/retire.ts `movedSaid`): told as a job's end is, which wakes it.
  say(session: string, text: string): void {
    try {
      this.notify(session, text);
    } catch (error) {
      log.warn("jobs", "job notice not given", { session, error: (error as Error).message });
    }
  }

  /// What the program asks of the station for its jobs.
  private async asked(f: string, args: Json[]): Promise<Json> {
    if (f.startsWith("store.")) {
      const method = f.slice("store.".length);
      const store = this.store as unknown as Record<string, (...a: Json[]) => Json>;
      if (typeof store[method] !== "function") throw new Error(`no store method ${method}`);
      return store[method]!(...args) ?? null;
    }
    const [a, b, c, d, e, g, h, i, k] = args;
    switch (f) {
      case "node.isDir":
        return await stat(a).then((s) => s.isDirectory(), () => false);
      case "node.newJob":
        return this.made(a, b, c, d, e, g, h, i, k);
      case "node.spawn":
        return await this.spawn(this.store.getJob(a)!, b === true, c ?? {});
      case "node.notify":
        this.say(a, b);
        return null;
      case "node.remoteChanged":
        this.remoteChanged(a);
        return null;
      case "node.pressure":
        return await this.machine.pressure().catch(() => null);
      case "node.inputIdle":
        return this.machine.inputIdle === undefined ? null : await this.machine.inputIdle();
      case "node.pidAlive":
        return pidAlive(a);
      case "node.keepClaims":
        await this.keepClaims(a);
        return null;
      case "node.tail":
        return await tail(a, b);
      case "node.lost":
        return await access(this.lostFile(a)).then(() => true, () => false);
      case "node.append":
        await appendFile(a, b);
        return null;
      case "node.signal":
        signalGroup(a, b);
        return null;
      case "node.grace": {
        const running = this.running.get(a);
        if (running) await this.timed(this.grace(running));
        return null;
      }
      case "node.endLeftBehind": {
        const entry = this.leftBehind(a);
        if (entry) {
          if (await stillOurs(entry)) {
            log.warn("jobs", "ending a job an earlier station left running", { job: b, pgid: entry.pgid });
            await this.timed(endGroup(entry.pgid, STOP_GRACE_MS));
          }
          this.store.forgetProcess(entry.pgid);
        }
        return null;
      }
      case "node.recordedGroups": {
        const recorded = this.store.listProcesses().filter((p) => p.runtime === "job");
        // Each group asked after together, none waited on (stillOurs starts a process).
        return await Promise.all(recorded.map(async (p) => ({ pgid: p.pgid, label: p.label, ours: await stillOurs(p) })));
      }
      case "node.follow":
        this.follow(this.store.getJob(a)!, b);
        return null;
      case "node.readExit":
        return await readExitFile(this.exitFile(a));
    }
    throw new Error(`no jobs' ask ${f}`);
  }

  /// What the program tells the station of its jobs, needing no answer.
  private told(f: string, args: Json[]): void {
    if (f === "log") {
      const [level, message, fields] = args;
      (level === "warn" ? log.warn : level === "error" ? log.error : log.info)("jobs", message, fields ?? {});
    } else if (f === "node.endGroup") void this.timed(endGroup(args[0], STOP_GRACE_MS));
  }

  /// Starts a job for `session`: `command` run by sh in `cwd`; a web service when it has a port. `checked`: its caller
  /// looked at `cwd` already (ops/places.ts), which is not looked at again here.
  start(session: string, name: string, command: string, cwd: string, port: number | null, watch: boolean, checked = false): Promise<JobRow> {
    return this.startId(session, name, command, cwd, port, watch, null, checked);
  }

  /// A remote task supplies a stable id. Its caller serializes starts; an existing record is never spawned again.
  /// `queue`: it waits in the station's queue (jobs/admit.mbt) when there is no room for it now; `screen`: it uses the
  /// screen, one such at a time. `sandbox`: a sandbox's task, run in the chat's sandbox there (agents/sandbox.ts),
  /// never queued here: it takes nothing of this machine's.
  async startId(
    session: string, name: string, command: string, cwd: string, port: number | null, watch: boolean, id: string | null, checked = false,
    queue: { screen: boolean; small?: boolean } | null = null, sandbox: SandboxPlace | null = null,
  ): Promise<JobRow> {
    const job = await this.call("startId", [session, name, command, cwd, port, watch, id, checked, queue, sandbox]);
    if (job === null) throw new Error("the station is stopping");
    return job as JobRow;
  }

  /// A job's record, made and kept (what the program checked it may be).
  private made(
    session: string, name: string, command: string, cwd: string, port: number | null, watch: boolean, id: string | null,
    queue: { screen: boolean; small?: boolean } | null, sandbox: SandboxPlace | null,
  ): JobRow {
    const jobId = id ?? `job_${hex(4)}`;
    const shownName = name.trim() === "" ? (command.trim().split(/\s+/)[0] || "job") : [...name.trim()].slice(0, 60).join("");
    const job: JobRow = {
      log: join(this.dir, "logs", `${jobId}.log`),
      id: jobId,
      sessionKey: session,
      name: shownName,
      command,
      cwd,
      port,
      token: hex(16),
      state: "running",
      pgid: null,
      exitCode: null,
      startedAt: this.store.now(),
      endedAt: null,
      restarts: 0,
      watch,
      ...(queue !== null ? { queued: true, screen: queue.screen } : {}),
      ...(queue?.small === true ? { small: true } : {}),
      ...(sandbox !== null ? { sandbox } : {}),
    };
    this.store.insertJob(job);
    return job;
  }

  /// What the station's memory watch (jobs/memory.ts) read of the memory on its own look: what the queue goes by as a
  /// task asks to start, the queue looking at it itself only while one waits.
  memorySeen(pressure: Pressure | null): void {
    void this.call("memorySeen", [pressure]);
  }

  /// A waiting task's place in line (1: the next), what blocks it, and what the queue measured (the memory's pressure);
  /// null for one not waiting. If it could start but another is ahead, `why` is null. Waiting for the screen, who has
  /// it.
  async queueOf(id: string): Promise<{ place: number; why: Why | null; holder?: string; decision: { memoryPressure: Pressure | null } } | null> {
    return await this.call("queueOf", [id]);
  }

  /// Who has the screen, for one waiting for it (not `except`, a job of its own): the task's name, the chat it is
  /// for and since when; a person using it; none when it is free.
  async screenHolder(except: string | null = null): Promise<string | null> {
    return await this.call("screenHolder", [except]);
  }

  /// `stillfail-job screen`: process `pid` of the job with this token asks for the screen (`take`, again each second
  /// while it waits) or gives it back (`give`). Whether it has it now, or where it is in line and who has it.
  async screenAsked(token: string, ask: "take" | "give", pid: number): Promise<{ screen: "yours" } | { screen: "waiting"; place: number; who: string | null } | { screen: "given" }> {
    return await this.call("screenAsked", [token, ask, pid]);
  }

  /// The claims that hold the screen, written down for the next station (in place: a reader never sees half of it).
  private async keepClaims(held: Json[]): Promise<void> {
    const path = join(this.dir, SCREEN_FILE);
    try {
      await writeFile(`${path}.${process.pid}`, JSON.stringify(held) + "\n");
      await rename(`${path}.${process.pid}`, path);
    } catch (error) {
      log.warn("jobs", "who has the screen not written down", { error: (error as Error).message });
    }
  }

  /// Where a job's exit code is written when it ends.
  exitFile(id: string): string {
    return join(this.dir, "exit", id);
  }

  /// Where the sandbox bridge says a job's connection to its sandbox was lost (agents/sandbox-bridge.mjs `lostFile`).
  private lostFile(id: string): string {
    return join(this.dir, "exit", `${id}.lost`);
  }

  private track(id: string, pgid: number, gone: Promise<void>): Running {
    let settle = () => {};
    const settled = new Promise<void>((resolve) => (settle = resolve));
    const running: Running = { pgid, gone, settled, settle };
    this.running.set(id, running);
    return running;
  }

  /// Whether its process is still the station's to end: so until its end is taken in (`ended`), after the store says it ended.
  isRunning(id: string): boolean {
    return this.running.has(id);
  }

  /// Its end said to the program, which takes it in (its record, its agent told, a service started again).
  private ended(id: string, running: Running, code: number | null, ranMs: number): Effect.Effect<void> {
    return Effect.promise(async () => {
      try {
        await this.call("exited", [id, running.pgid, code, ranMs]);
      } catch (error) {
        log.warn("jobs", "a job's end not taken in", { job: id, error: (error as Error).message });
      } finally {
        if (this.running.get(id) === running) this.running.delete(id);
        running.settle();
      }
      // Its shell ended, and what it started and left running in its group was told to end (the program's SIGTERM):
      // what does not is made to, as a stop does. Left, they went on as orphans of nobody's (ppid 1) for good.
      if (!this.closing && groupAlive(running.pgid)) await this.timed(endGroup(running.pgid, STOP_GRACE_MS));
      const job = this.store.getJob(id);
      if (job !== null) await this.capLog(job.log);
    });
  }

  /// A job's log held to JOB_LOG_CAP where it is (its shell appends to it: `exec >>`), what it had kept in `<log>.1`.
  private async capLog(path: string): Promise<boolean> {
    if (!path.startsWith(this.dir + sep)) return false;
    try {
      return await rotateInPlace(path, JOB_LOG_CAP);
    } catch (error) {
      log.warn("jobs", "a job's log not held to its bound", { log: path, error: (error as Error).message });
      return false;
    }
  }

  /// The logs of the jobs up held to their bound (ops/storage.ts Upkeep), and the files of jobs long over or gone
  /// collected (`collect`).
  async upkeep(now: number): Promise<{ capped: number; collected: string[] }> {
    let capped = 0;
    for (const job of this.store.jobsUp()) if (await this.capLog(job.log)) capped++;
    return { capped, collected: await this.collect(now) };
  }

  /// The files in jobs/logs and jobs/exit of a job the store no longer has, unchanged for JOB_FILES_ORPHAN_MS (its
  /// session deleted: 1,702 logs, 1.0 GB, on a station, 2026-11-15), and the log of a job that ended JOB_LOGS_KEPT_MS
  /// ago, removed: its record stays, its log reads as empty (job_log). Of one up (running, or a service to start again)
  /// nothing. The job ids whose files went.
  async collect(now: number): Promise<string[]> {
    const gone = new Set<string>();
    const up = new Set(this.store.jobsUp().map((j) => j.id));
    const looked = new Map<string, JobRow | null>();
    // (each read of the store is synchronous: so many files, all kept, made no await at all, and 1,043 reads held the
    // main thread 4.5 s, 2026-11-18; the loop is given back every COLLECT_YIELD_EVERY files or reads)
    let since = 0;
    const jobOf = (id: string) => {
      if (!looked.has(id)) {
        since++;
        looked.set(id, this.store.getJob(id));
      }
      return looked.get(id)!;
    };
    const idOf = (name: string, sub: "logs" | "exit") => (sub === "logs" ? /^(.+?)\.log(\.1(\.tmp)?)?$/.exec(name)?.[1] : /^(.+?)(\.(lost|tmp))?$/.exec(name)?.[1]) ?? null;
    const isUp = (id: string) => up.has(id) || this.running.has(id);
    for (const sub of ["logs", "exit"] as const) {
      const dir = join(this.dir, sub);
      for (const name of await readdir(dir).catch(() => [] as string[])) {
        if (++since >= COLLECT_YIELD_EVERY) {
          since = 0;
          await new Promise<void>((resolve) => setImmediate(resolve));
        }
        const id = idOf(name, sub);
        if (id === null || isUp(id)) continue;
        const job = jobOf(id);
        const file = join(dir, name);
        if (job === null) {
          const st = await lstat(file).catch(() => null);
          if (st === null || now - st.mtimeMs < JOB_FILES_ORPHAN_MS) continue;
        } else if (job.state === "running" || job.endedAt === null || now - job.endedAt < JOB_LOGS_KEPT_MS) continue;
        // (started again while the loop was given back)
        if (isUp(id)) continue;
        await rm(file, { force: true }).catch(() => undefined);
        gone.add(id);
      }
    }
    if (gone.size > 0) log.info("jobs", "files of jobs long over or gone removed", { jobs: gone.size });
    return [...gone];
  }

  /// Runs a job's command, and follows it to its end: its group. `extra`: variables it is given besides (the queue's
  /// CPUs).
  private async spawn(job: JobRow, restarted: boolean, extra: Record<string, string> = {}): Promise<number> {
    // Made (or found) here, so a log that cannot be written is said now; the shell opens it itself (below).
    await (await open(job.log, "a")).close();
    const exit = this.exitFile(job.id);
    await rm(exit, { force: true });
    await rm(`${exit}.tmp`, { force: true });
    await rm(this.lostFile(job.id), { force: true });
    // With the variables the station's owners set for what it starts for its agents (ops/agent-env.ts).
    const env: NodeJS.ProcessEnv = { ...platform.prependPath(startEnv(), join(this.dir, "bin")), ...extra };
    env.STILLFAIL_JOB_ID = job.id;
    env.STILLFAIL_JOB_TOKEN = job.token;
    env.STILLFAIL_JOB_NOTIFY = this.notifyUrl;
    // Web services of the workspace's other stations, through the same door (mesh/peer-http.ts).
    if (this.notifyUrl !== "") env.STILLFAIL_PEER_HTTP = this.notifyUrl.replace(/\/jobs\/notify$/, "/peer");
    if (job.port !== null) env.PORT = String(job.port);
    // A group of its own (detached: pgid = its pid; on Windows the job of the runner it runs under), not ended with the
    // station. The shell appends to the log itself: Git's sh on Windows cannot write to a file Node opened for
    // appending (its handle may only append). Lower than the station (ops/nice.ts): nice runs the shell in its own
    // process, the pid the same.
    const shell: [string, string[]] = [await platform.posixShellSoon(env), ["-c", `exec >>"$3" 2>&1; ${WRAPPER}`, JOB_COMMAND_NAME, job.command, exit, job.log]];
    // A sandbox's task (agents/sandbox.ts): its command runs there through the bridge, which the shell here runs
    // in its place: its output comes back to the log here, its exit code to the exit file here.
    if (job.sandbox !== undefined) {
      const sandbox = this.sandboxes(job.sandbox.sandbox);
      if (sandbox === null) throw new Error(`no sandbox ${job.sandbox.sandbox} in this station's config.json any more`);
      const door = Number(new URL(this.notifyUrl || "http://127.0.0.1:0").port);
      shell[1][3] = sandboxCommand(this.data, sandbox, job.sandbox, job.command, job.cwd, door > 0 ? [door] : [], this.lostFile(job.id));
    }
    // Where `stillfail-job screen` asks for the screen: this machine's, which a sandbox's commands do not have (and
    // their processes are not this machine's to look at).
    else if (this.notifyUrl !== "") env.STILLFAIL_JOB_SCREEN = this.notifyUrl.replace(/\/notify$/, "/screen");
    const child = startLasting(...niced(...shell), {
      cwd: job.cwd, env, stdio: "ignore",
    });
    child.on("error", () => {});
    const pgid = child.pid;
    if (pgid === undefined) throw new Error("the job ended before it started");
    this.store.recordProcess(pgid, this.store.now(), "job", `job: ${job.name}`);
    this.store.jobStarted(job.id, pgid, restarted);
    // another station's chat's task, begun: remembered past it and its session (the workspace's card counts them)
    if (!restarted && job.sessionKey.startsWith("remote:")) this.store.noteRemoteRun(job.id, job.sessionKey, this.store.now());
    const exited = new Promise<number | null>((resolve) => child.once("exit", (code) => resolve(code)));
    const running = this.track(job.id, pgid, exited.then(() => undefined));
    const began = this.store.now();
    void this.run(Effect.promise(() => exited).pipe(Effect.flatMap((code) => this.ended(job.id, running, code, this.store.now() - began)))).catch(() => undefined);
    return pgid;
  }

  /// The end of a job an earlier station started (not this one's child): its exit file appearing (heard from the watch
  /// on jobs/exit), or its leader gone (looked at once a second: that end writes no file and has no event). The file is
  /// looked for once a second too only where the directory is not watched (four jobs followed on a station,
  /// 2026-10-25). Every look at the file is off the main thread; one asked while another is out is made once that one
  /// comes back, so a write it may have missed is not.
  private leaderGone(id: string, pgid: number): Effect.Effect<void> {
    const exit = this.exitFile(id);
    const there = () => access(exit).then(() => true, () => false);
    const heard = Effect.callback<void>((resume) => {
      let done = false;
      let looking = false;
      let again = false;
      const look = (): void => {
        if (done) return;
        if (looking) {
          again = true;
          return;
        }
        looking = true;
        void there().then((is) => {
          looking = false;
          if (done) return;
          if (is) {
            done = true;
            resume(Effect.void);
          } else if (again) {
            again = false;
            look();
          }
        });
      };
      this.exitHeard.set(id, look);
      this.watchExits();
      // Written before the watch began: no event tells it.
      look();
      return Effect.sync(() => {
        done = true;
        if (this.exitHeard.get(id) === look) this.exitHeard.delete(id);
      });
    });
    const looked = Effect.promise(async () => !pidAlive(pgid) || (this.exitWatch === null && (await there()))).pipe(
      Effect.repeat({ schedule: Schedule.spaced(FOLLOW_LOOK_MS), until: (gone) => gone }),
      Effect.asVoid,
    );
    return Effect.race(looked, heard);
  }

  /// The watch on jobs/exit (one for all followed jobs), while any is followed.
  private watchExits(): void {
    if (this.exitWatch !== null) return;
    try {
      // No name: the system let events go or ran them together (an overflowed inotify queue, FSEvents' coalescing), so
      // every job followed looks again.
      this.exitWatch = watch(join(this.dir, "exit"), (_event, file) => {
        if (file) this.exitHeard.get(file.toString())?.();
        else for (const look of [...this.exitHeard.values()]) look();
      });
      this.exitWatch.unref();
      this.exitWatch.on("error", () => {});
    } catch {
      // Not watched: the look once a second still finds it.
    }
  }

  /// Follows a job an earlier station started (it went on through the restart) to its end.
  private follow(job: JobRow, pgid: number): void {
    let heard = () => {};
    const gone = new Promise<void>((resolve) => (heard = resolve));
    const running = this.track(job.id, pgid, gone);
    const began = this.store.now() - Math.max(0, this.store.now() - job.startedAt);
    const id = job.id;
    void this.run(
      this.leaderGone(id, pgid).pipe(
        Effect.andThen(Effect.sync(() => heard())),
        // What its shell wrote, if it did.
        Effect.andThen(Effect.promise(() => readExitFile(this.exitFile(id)))),
        Effect.flatMap((code) => this.ended(id, running, code, this.store.now() - began)),
      ),
    ).catch(() => undefined);
  }

  /// A stop's wait for a job's end: its leader's comes as an event; members it left behind have none, and are looked at
  /// within the grace. Killed if not ended by then, and its end taken in.
  private grace(running: Running): Effect.Effect<void> {
    return Effect.gen(function* () {
      yield* Effect.promise(() => running.gone).pipe(
        Effect.andThen(
          Effect.repeat(Effect.sync(() => groupAlive(running.pgid)), {
            schedule: Schedule.spaced(STOP_LOOK_MS),
            until: (alive) => !alive,
          }),
        ),
        Effect.timeoutOption(STOP_GRACE_MS),
      );
      if (groupAlive(running.pgid)) signalGroup(running.pgid, "SIGKILL");
      yield* Effect.promise(() => running.settled).pipe(Effect.timeoutOption(STOP_SETTLE_MS));
    });
  }

  /// Stops a job: its process group asked to end, then made to.
  async stop(id: string): Promise<JobRow> {
    const job = await this.call("stop", [id]);
    return (job ?? this.store.getJob(id)) as JobRow;
  }

  /// The record of a job's group an earlier station started (not one this station follows).
  private leftBehind(pgid: number): ProcessRow | null {
    for (const r of this.running.values()) if (r.pgid === pgid) return null;
    const entry = this.store.processByGroup(pgid);
    return entry?.runtime === "job" ? entry : null;
  }

  /// Stops a job for someone on the pages: its agent is told who did (it did not ask for it), if it was at work within
  /// AWAKE; an idle one is not woken for it.
  async stopFor(id: string, who: string): Promise<JobRow> {
    const job = await this.stop(id);
    if (this.awake(job.sessionKey)) this.tell(job, `${named(job)} was stopped by ${who} from still.fail's page.`);
    return job;
  }

  /// Stops every job and service that runs or waits to start again, `why` written at the end of each one's log: the
  /// station left its workspace, and does no work outside one; or it starts already out of it, and what an earlier
  /// station left running (it ended before it could stop them) is ended. Agents are not told (no turn runs meanwhile,
  /// and telling them once it is back would wake them all); a job's state and log say it when one looks. `only`: those
  /// of some sessions alone (a station retired from one workspace stops that one's chats' jobs: replica/retire.ts).
  async stopAll(why: string, only: (job: JobRow) => boolean = () => true): Promise<void> {
    for (const job of this.store.jobsUp().filter(only)) {
      log.warn("jobs", "stopping a job", { job: job.id, why });
      try {
        await this.stop(job.id);
      } catch (error) {
        log.warn("jobs", "job not stopped", { job: job.id, error: (error as Error).message });
        continue;
      }
      await appendFile(job.log, `\n[still.fail] stopped: ${why}\n`).catch(() => undefined);
    }
  }

  /// Takes a session's jobs that are over off its record (the pages' 清掉已结束的), their logs with them: the ids gone.
  async clearEnded(session: string): Promise<string[]> {
    const gone = this.store.clearEndedJobs(session);
    await Promise.all(gone.map(async ([id, file]) => {
      if (file.startsWith(this.dir + sep)) await rm(file, { force: true });
      await rm(this.exitFile(id), { force: true });
      await rm(`${this.exitFile(id)}.tmp`, { force: true });
    }));
    return gone.map(([id]) => id);
  }

  /// Whether a session's agent is in a turn, or was within AWAKE.
  private awake(session: string): boolean {
    const s = this.store.getSession(session);
    return s !== null && (s.running || this.store.now() - s.lastActiveAt < AWAKE_MS);
  }

  /// After a start of the station: what still runs is followed again; what ended meanwhile is told as ended; what was
  /// running and is gone without a word (the machine restarted, or an older station ended it) runs again, and its agent
  /// is told; a service waiting to start again starts. Groups of jobs no longer running are ended.
  async relaunch(): Promise<void> {
    await this.call("relaunch", []);
  }

  /// The station stops: its jobs go on (the next station takes them up); what followed them and the services' restart
  /// pauses end here.
  async shutdown(): Promise<void> {
    if (this.closing) return;
    this.closing = true;
    // (what is let go of let go of even where the program could not be asked: a program of its own left running else)
    try {
      await this.call("shutdown", []);
    } finally {
      this.exitWatch?.close();
      this.exitWatch = null;
      await Effect.runPromise(Scope.close(this.scope, Exit.void));
      if (this.own) await this.program.close();
    }
  }

  /// `stillfail-job notify`: the job with this token tells its agent something.
  async notified(token: string, text: string): Promise<void> {
    await this.call("notified", [token, text]);
  }

  /// A job as the agent reads it: a service with its link.
  view(job: JobRow): Json {
    const v = jobJson(job);
    if (job.port !== null) v.link = this.link(job.sessionKey, job.id);
    return v;
  }
}

/// POST /jobs/notify on the MCP endpoint (server.rs `answer_mcp`): a job's `stillfail-job notify`, its token as the
/// bearer, its words as the body (at most 64 KiB). The HTTP wiring is the server's: it gives the authorization header
/// and the body read so far (more than the limit is refused).
export async function notifyEndpoint(jobs: Jobs, authorization: string | undefined, body: Buffer | string): Promise<{ status: number; body: Json }> {
  const token = authorization?.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  const bytes = typeof body === "string" ? Buffer.from(body) : body;
  if (bytes.length > NOTIFY_BODY_LIMIT) return { status: 400, body: { error: "length limit exceeded" } };
  try {
    await jobs.notified(token, new TextDecoder("utf-8").decode(bytes));
    return { status: 200, body: { ok: true } };
  } catch (error) {
    return { status: 400, body: { error: (error as Error).message } };
  }
}

/// POST /jobs/screen on the MCP endpoint: a job's `stillfail-job screen`, its token as the bearer, `take <pid>` or
/// `give <pid>` as the body (`Jobs.screenAsked`): `{screen: "yours"}`, `{screen: "waiting", place}`, `{screen:
/// "given"}`, or `{error}`.
export async function screenEndpoint(jobs: Jobs, authorization: string | undefined, body: Buffer | string): Promise<{ status: number; body: Json }> {
  const token = authorization?.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  const asked = /^(take|give) ([0-9]{1,10})\s*$/.exec(typeof body === "string" ? body : body.toString("utf8"));
  if (asked === null) return { status: 400, body: { error: "take <pid> or give <pid>" } };
  try {
    return { status: 200, body: await jobs.screenAsked(token, asked[1] as "take" | "give", Number(asked[2])) };
  } catch (error) {
    return { status: 400, body: { error: (error as Error).message } };
  }
}
