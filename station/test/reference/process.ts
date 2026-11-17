// What a runtime's process was to its driver before the station's MoonBit program read every one (src/agents/mb-agents.ts
// `HostedProcess`): its runner's connection read on the station's thread, a line at a time (src/agents/runner.ts
// `RunnerConnection`), and what a crash read again of its output, decoded here. The tests that compare the two, or that
// need a runner's process with no program, use it.
import { log } from "../../src/ops/log.ts";
import { wall } from "../../src/ops/fibers.ts";
import { bytesWithin, debug, describeExit, endRunner, groupAlive } from "../../src/agents/process.ts";
import { RunnerConnection, leave, listeningSoon, startRunner, type RunnerInfo } from "../../src/agents/runner.ts";

/// A wait on another process (a grace raced against its exit): the machine's time.
const sleep = wall.sleep;

const pidAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// The connection's socket, which runner.ts keeps to itself.
function socketOf(conn: RunnerConnection): import("node:net").Socket {
  return conn["socket"];
}

export type ProcessOptions = {
  /// For the log: what it is ("claude <session>", "codex app-server <profile>").
  label: string;
  /// Each line of its stdout, in order, with where in its output it begins and ends; acknowledged once this returns.
  line: (text: string, from: number, to: number) => void;
  /// It exited (all of its output handled), as `describeExit` says, unless it was let go first; with the last lines it
  /// wrote to stderr (STDERR_TAIL of them, "" when none): what a runtime that fails as it starts says of why.
  exit: (said: string, stderr: string) => void;
};

/// How many of a runtime's last stderr lines its exit carries, and how long each may be.
const STDERR_TAIL = 3;
const STDERR_LINE = 300;

export class AgentProcess {
  readonly info: RunnerInfo;
  private conn: RunnerConnection;
  private frozen = false;
  private gone = false;
  private killing = false;
  private said: string | null = null;
  /// Its last lines of stderr, for its exit.
  private stderr: string[] = [];
  /// Its exit, described; resolved once its last line has been handled.
  readonly exited: Promise<string>;

  private constructor(info: RunnerInfo, options: ProcessOptions) {
    this.info = info;
    let resolveExit!: (said: string) => void;
    this.exited = new Promise((resolve) => (resolveExit = resolve));
    this.conn = new RunnerConnection(info, (stream, text, from, to) => {
      // Frozen: the line stays unacknowledged, for whoever takes the process up next.
      if (this.frozen) return new Promise<void>(() => {});
      const line = text.endsWith("\r") ? text.slice(0, -1) : text;
      if (stream === "err") {
        debug("agents::process", "runtime stderr", { label: options.label, line: line.slice(0, 2000) });
        if (line.trim() !== "") this.stderr = [...this.stderr, line.trim().slice(0, STDERR_LINE)].slice(-STDERR_TAIL);
      } else options.line(line, from, to);
    });
    const socket = socketOf(this.conn);
    socket.on("error", (error) => {
      if (!this.gone) log.warn("agents::process", "runner connection failed", { label: options.label, error: String(error) });
    });
    socket.on("close", () => {
      if (this.gone || this.said !== null) return;
      // Another station attached (the runner keeps one connection), or the runner itself is gone (killed): then the
      // agent went with its stdin, and nothing will say how it ended.
      if (pidAlive(info.runner)) {
        log.warn("agents::process", "another station took the runner over; letting go", { label: options.label });
        this.frozen = true;
        this.gone = true;
      } else {
        this.said = "runner gone";
        resolveExit(this.said);
        if (!this.frozen) options.exit(this.said, this.stderr.join("\n"));
      }
    });
    this.conn.exited.then((exit) => {
      if (this.said !== null) return;
      this.said = describeExit(exit);
      resolveExit(this.said);
      if (this.frozen) return;
      options.exit(this.said, this.stderr.join("\n"));
      // Read to the end: the runner may go (kill does it once what is left of the group is gone).
      if (!this.killing) this.conn.done();
    });
  }

  /// Starts `program` under a runner `id`. A runner of that id still there (a process an earlier station left and
  /// nobody took up) is ended first, as process.rs reap_stale_groups did.
  static async start(data: string, id: string, program: string, args: string[], env: Record<string, string>, cwd: string, options: ProcessOptions) {
    await endRunner(data, id, options.label);
    const info = await startRunner(data, id, program, args, env, cwd);
    return new AgentProcess(info, options);
  }

  /// Takes up the process a runner keeps: from its first line not acknowledged.
  static async adopt(info: RunnerInfo, options: ProcessOptions) {
    if (!(await listeningSoon(info))) throw new Error(`runner ${info.id} has no socket`);
    return new AgentProcess(info, options);
  }

  get pgid() {
    return this.info.pgid;
  }

  hasExited() {
    return this.said !== null;
  }

  /// Let go (or frozen for that): no longer this station's to write to, kill or hear.
  handed() {
    return this.frozen;
  }

  /// Writes a line to its stdin (the newline added); nothing once it is let go.
  write(line: string) {
    if (this.frozen) return;
    this.conn.write(line.endsWith("\n") ? line : `${line}\n`);
  }

  /// The runner gives the disk back under its stdout only up to `at` (told with the next ack): what is read again after
  /// a crash begins there.
  keepFrom(at: number) {
    this.conn.keep = at;
  }

  /// Stops handling its lines: the next station is sent them.
  freeze() {
    this.frozen = true;
  }

  /// Lets go of it without ending it. What was handled is acknowledged first (acks go out as handlers return).
  detach() {
    this.frozen = true;
    if (this.gone) return;
    this.gone = true;
    leave(new Promise((resolve) => setImmediate(() => resolve(this.conn.detach()))));
  }

  /// Once it has exited by itself and been read to the end, its runner (told `done`) cleans up and goes, a moment after:
  /// waited for, so a process started or taken up under its id next is never that runner on its way out (taken up, it
  /// would be gone under the one taking it: its socket removed, its agent long exited). One let go stays for the next
  /// station; one still running is not this to wait for.
  async released() {
    if (this.frozen || this.said === null) return;
    for (let i = 0; i < 200 && pidAlive(this.info.runner); i++) await sleep(10);
  }

  /// SIGTERM the whole group, SIGKILL whatever is left after `graceMs`; then the runner may go.
  async kill(graceMs: number) {
    if (this.frozen) return;
    if (this.killing) {
      await this.exited;
      return;
    }
    this.killing = true;
    this.conn.signal("TERM", true);
    // The leader's exit is the signal the group is done; what outlives it, or a leader that ignores SIGTERM, is killed.
    await Promise.race([this.exited, sleep(graceMs)]);
    if (groupAlive(this.pgid)) {
      this.conn.signal("KILL", true);
      // Gone once the system has taken them away, a moment after.
      for (let i = 0; i < 100 && groupAlive(this.pgid); i++) await sleep(10);
    }
    await Promise.race([this.exited, sleep(1000)]);
    this.conn.done();
    // The runner itself goes once it has told: waited for, so a process started under its id next is not taken for it.
    for (let i = 0; i < 200 && pidAlive(this.info.runner); i++) await sleep(10);
  }
}

/// How much of a runner's output `linesBefore` holds at once.
const READ_CHUNK = 1 << 20;

/// The whole lines of `file` before byte `end` (a line boundary: acknowledgements are at line ends), one at a time: an
/// app-server's output holds days of its threads (hundreds of MB), more than one string can, so it is never held whole.
export async function* linesBefore(file: string, end: number, chunk = READ_CHUNK): AsyncGenerator<string> {
  for await (const line of linesWithin(file, 0, end, chunk)) yield line.text;
}

/// The whole lines of `file` from byte `start` to byte `end` (both line boundaries), each with where it begins. Read off
/// the station's thread: what a station taking up its runners reads, up to hundreds of MB, held it 33 s on one
/// (2026-11-06).
export async function* linesWithin(file: string, start: number, end: number, chunk = READ_CHUNK): AsyncGenerator<{ text: string; at: number }> {
  for await (const line of bytesWithin(file, start, end, chunk)) yield { text: line.bytes.toString("utf8"), at: line.at };
}

