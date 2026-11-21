// Agent processes kept by runners (native/runner §1): each claude or codex process is the
// child of a `stillfail-runner` that outlives this station, restarting or crashing. Starting one gives a handle; a
// station starting finds those of before (<data>/run/runners/*.json) and takes them up again where it stopped reading:
// what it has handled is acknowledged line by line, so nothing is read twice and nothing is lost.
//
// On Windows the runner's socket is a named pipe (`\\.\pipe\…`, its `socket`), which is not a file: opening it, even
// to see it is there, is a connection, and the runner keeps one at a time. So it is never looked at but to attach.
import { spawn } from "node:child_process";
import { access, lstat, readFile, readdir, rm } from "node:fs/promises";
import { createConnection, type Socket } from "node:net";
import { join } from "node:path";
import { niced } from "../ops/nice.ts";
import { withShellCommand } from "../ops/shell-path.ts";
import { platform } from "../platform/index.ts";
import { runnerBinary } from "../platform/processes.ts";
import { log } from "../ops/log.ts";
import { wall } from "../ops/fibers.ts";

export type RunnerInfo = {
  id: string;
  runner: number;
  pid: number;
  pgid: number;
  startedAt: number;
  program: string;
  args: string[];
  socket: string;
  /// It gives back stdout's disk only up to an ack's `keep` (one from before gives back up to the ack).
  keeps?: boolean;
  /// A terminal's (`pty`): its program on a pseudo-terminal (terminals/), and the size it started with.
  pty?: boolean;
  cols?: number;
  rows?: number;
};

export type Exit = { code: number | null; signal: string | null };

/// The runner binary: STILLFAIL_RUNNER, else beside the station's code in a release, else where cargo built it.
export { runnerBinary };

export const runnersDir = (data: string) => join(data, "run", "runners");

/// A person's terminal's runner (terminals/), not an agent's: its id's start. What takes up agents' runners leaves it.
export const TERMINAL_RUNNER = "term-";
export const isTerminalRunner = (id: string) => id.startsWith(TERMINAL_RUNNER);

/// Whether a runner of before (its info file there, itself alive) still keeps its process: its socket there (one on its
/// way out has removed it), looked at off the station's thread. A pipe cannot be looked at (see above): the info file,
/// which goes with it, says so then.
export const listeningSoon = async (info: RunnerInfo) => !platform.runnerSocketVisible || (await access(info.socket).then(() => true, () => false));

/// A program named by its command (not a path) that `env`'s PATH does not have: the runtime is not installed there.
export class CommandMissing extends Error {
  readonly command: string;
  constructor(command: string) {
    super(`the runner did not start: ${command} is not on PATH`);
    this.command = command;
  }
}

/// How long a runner has to say it is ready (`startRunner`).
const RUNNER_READY_MS = 30_000;

/// Starts `program` under a runner, its environment `env` (the agent's whole environment), in `cwd`.
/// `pty`: the program on a pseudo-terminal of that size (a person's terminal, terminals/), not on pipes.
export async function startRunner(data: string, id: string, program: string, args: string[], env: NodeJS.ProcessEnv, cwd: string, pty?: { cols: number; rows: number }): Promise<RunnerInfo> {
  // Looked for as the runner would (its PATH is `env`'s): one not there is told apart from a runner that failed.
  env = await withShellCommand(program, env);
  if (!/[\\/]/.test(program) && (await platform.findCommandSoon(program, env)) === null) return Promise.reject(new CommandMissing(program));
  return new Promise((resolve, reject) => {
    // Lower than the station (ops/nice.ts), the runtime it starts and what that starts too.
    const [command, given] = niced(runnerBinary(), ["--dir", runnersDir(data), "--id", id, "--cwd", cwd, ...(pty ? ["--pty", `${pty.cols}x${pty.rows}`] : []), "--", program, ...args]);
    const child = spawn(command, given, {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
    });
    let out = "";
    let err = "";
    let settled = false;
    const settle = (then: () => void) => {
      if (settled) return;
      settled = true;
      stop();
      then();
    };
    // A runner that never says it is ready nor lets go of its stdout (stuck as it starts, or its output held by what it
    // started) is given up: a session's start waited on one forever (FB-34).
    // timer: deadline for stillfail-runner to report ready
    const stop = wall.after(RUNNER_READY_MS, () => settle(() => {
      try { child.kill("SIGKILL"); } catch {}
      child.stdout.destroy();
      child.stderr.destroy();
      reject(new Error(`the runner did not start within ${RUNNER_READY_MS / 1000}s`));
    }));
    child.stdout.on("data", (b) => (out += b));
    child.stderr.on("data", (b) => (err += b));
    child.on("error", (error) => settle(() => reject(error)));
    // The ready line comes before the runner lets go of its stdout; a runner that fails says why and exits non-zero.
    child.stdout.on("end", () => settle(() => {
      const line = out.split("\n").find((l) => l.startsWith("{"));
      if (line) {
        const ready = JSON.parse(line);
        if (ready.ready) return resolve(ready as RunnerInfo);
      }
      reject(new Error(`the runner did not start: ${err.trim() || out.trim()}`));
    }));
    child.unref();
  });
}

/// Runners of before this station, alive now: their info files, those whose runner is alive, read without holding the
/// station's thread: what is looked at every few seconds (jobs/memory.ts, resources/watch.ts). Their files are some 10 kB each (a command's arguments), and
/// on a machine short of memory twenty runners took up to 5 s to read on the thread (2026-10-25).
export async function liveRunners(data: string, options: { strict?: boolean } = {}): Promise<RunnerInfo[]> {
  const dir = runnersDir(data);
  let names: string[];
  try {
    names = await readdir(dir);
  } catch (error) {
    // Recovery must not mistake an unreadable directory for no runners and start a second owner for their threads.
    if (options.strict && (error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    return [];
  }
  const read = await Promise.all(names.filter((f) => f.endsWith(".json")).map((f) => readFile(join(dir, f), "utf8").catch(() => null)));
  return read.flatMap((text) => (text === null ? [] : alive(() => text)));
}

/// Runner `id`'s, its file alone (read off the station's thread), if its runner is alive.
export async function runnerOf(data: string, id: string): Promise<RunnerInfo | undefined> {
  const text = await readFile(join(runnersDir(data), `${id}.json`), "utf8").catch(() => null);
  return text === null ? undefined : alive(() => text)[0];
}

/// What an info file says, if its runner is alive.
function alive(text: () => string): RunnerInfo[] {
  try {
    const info = JSON.parse(text()) as RunnerInfo;
    process.kill(info.runner, 0);
    return [info];
  } catch {
    return [];
  }
}

/// How far a process's start as the system tells it may be past the `startedAt` its runner wrote (native/runner
/// `STARTED_SLACK_MS`): clocks read two ways, and ps says whole seconds.
const STARTED_SLACK_MS = 60_000;

/// Whether the runner an info file names is alive and is that runner (native/runner `live_runner`): its pid there, and
/// not started after the runner said it had (a pid gone long ago reused by another process).
export async function liveRunner(info: RunnerInfo): Promise<boolean> {
  try {
    process.kill(info.runner, 0);
  } catch {
    // Gone (or another user's process of that pid: not our runner).
    return false;
  }
  const started = await platform.startTimeOf(info.runner).catch(() => null);
  return started === null || typeof info.startedAt !== "number" || started <= info.startedAt + STARTED_SLACK_MS;
}

/// The files a runner keeps beside its info file (native/runner `Paths`).
const RUNNER_FILES = [".json", ".out", ".err", ".sock"];
/// A runner's files with no info file beside them this long are left over (one starting writes its info file last).
export const RUNNER_LEFT_MS = 5 * 60_000;

/// The files of runners gone (killed, crashed, the machine restarted: a runner removes its own only when it ends well)
/// removed: an info file whose runner is not alive, with its output, errors and socket; and output, errors, sockets and
/// half-written info files with no info file, unchanged for RUNNER_LEFT_MS. Chats' runners have ids of their own each
/// time (`claude-chat_…-<random>`), so nothing ever started again under one of them to clear it: 1.1 GB of them on a
/// station (2026-11-15). The ids removed. `orphan` ends a runner alive that nobody holds, saying whether it did (the
/// hub's `endOrphan`: a runner left so went on for good), which then goes with its files.
export async function sweepRunners(data: string, now: number, orphan?: (info: RunnerInfo) => Promise<boolean>): Promise<string[]> {
  const dir = runnersDir(data);
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const infos = new Set(names.filter((n) => n.endsWith(".json")).map((n) => n.slice(0, -5)));
  const gone = new Set<string>();
  const remove = async (id: string) => {
    for (const ext of RUNNER_FILES) await rm(join(dir, `${id}${ext}`), { force: true }).catch(() => undefined);
    gone.add(id);
  };
  for (const id of infos) {
    const text = await readFile(join(dir, `${id}.json`), "utf8").catch(() => null);
    let info: RunnerInfo | null = null;
    try {
      info = text === null ? null : (JSON.parse(text) as RunnerInfo);
    } catch {}
    if (info === null || typeof info.runner !== "number") {
      // One that does not read: left over only once it has stood unchanged a while.
      const st = await lstat(join(dir, `${id}.json`)).catch(() => null);
      if (st !== null && now - st.mtimeMs >= RUNNER_LEFT_MS) await remove(id);
      continue;
    }
    if (!(await liveRunner(info))) await remove(id);
    else if (orphan !== undefined && !isTerminalRunner(id) && (await orphan(info).catch(() => false))) await remove(id);
  }
  for (const name of names) {
    const ext = RUNNER_FILES.find((e) => e !== ".json" && name.endsWith(e)) ?? (name.endsWith(".tmp") ? ".tmp" : null);
    if (ext === null) continue;
    const id = name.slice(0, -ext.length);
    if (infos.has(id) || gone.has(id)) continue;
    const st = await lstat(join(dir, name)).catch(() => null);
    if (st === null || now - st.mtimeMs < RUNNER_LEFT_MS) continue;
    await rm(join(dir, name), { force: true }).catch(() => undefined);
    gone.add(id);
  }
  if (gone.size > 0) log.info("agents::runner", "runners gone, their files removed", { count: gone.size });
  return [...gone];
}

/// Connections being let go: each one closed on this side and read to its end, so its runner has taken every ack sent on
/// it (a runner reads a connection's messages in order up to its end). One dropped instead could be ended by the next
/// station's attach with its last acks unread, and those lines handled again by it.
const leaving = new Set<Promise<void>>();

export function leave(left: Promise<void>) {
  leaving.add(left);
  void left.finally(() => leaving.delete(left));
}

/// Once every connection let go so far has reached its end.
export async function allLeft() {
  while (leaving.size > 0) await Promise.all(leaving);
}

/// Whole lines of bytes that come a piece at a time: a runner's messages of 64 KB (`RunnerConnection`), an output read
/// again a part at a time (process.ts `linesWithin`). A line's pieces are kept as they came and joined once at its end,
/// and a newline is looked for only in the piece that came. Joined again with each piece and searched from its start, a
/// line of L bytes copied and scanned L²/(2·64 KB) bytes on the main thread: a `thread/resume` reply of 160 MB on one
/// line, some 200 GB, and stations killed by the launcher one after another as they took it up (2026-11-13).
export class Lines {
  private parts: Buffer[] = [];
  private size = 0;

  /// The lines `bytes` ends, in order, without their newline; what it leaves of one is held for the next piece.
  take(bytes: Buffer): Buffer[] {
    const lines: Buffer[] = [];
    let from = 0;
    for (let i = bytes.indexOf(10); i >= 0; i = bytes.indexOf(10, from)) {
      const last = bytes.subarray(from, i);
      if (this.parts.length === 0) lines.push(last);
      else {
        this.parts.push(last);
        lines.push(Buffer.concat(this.parts, this.size + last.length));
        this.drop();
      }
      from = i + 1;
    }
    if (from < bytes.length) {
      this.parts.push(bytes.subarray(from));
      this.size += bytes.length - from;
    }
    return lines;
  }

  /// Lets go of what is held of a line: the next piece begins one.
  drop() {
    this.parts = [];
    this.size = 0;
  }
}

/// A connection to one runner: what the agent says, line by line, from where this station last acknowledged.
export class RunnerConnection {
  readonly info: RunnerInfo;
  private socket: Socket;
  private carry = "";
  private lines: Record<"out" | "err", Lines> = { out: new Lines(), err: new Lines() };
  /// Where each stream's next line starts, as the runner counts bytes.
  private at: Record<"out" | "err", number> = { out: -1, err: -1 };
  private acked: Record<"out" | "err", number> = { out: 0, err: 0 };
  /// Up to where of stdout the runner may give the disk back (native/runner `punch`), told with each ack: what a station
  /// reads again after a crash begins there (process.ts `readFrom`). Null: up to what was acknowledged.
  keep: number | null = null;
  private queue: Promise<void> = Promise.resolve();
  private left = false;
  readonly exited: Promise<Exit>;
  private exit!: (e: Exit) => void;

  /// `line` is called for each whole line in order, one at a time (a promise is waited for); once it is done, the line
  /// is acknowledged.
  constructor(info: RunnerInfo, line: (stream: "out" | "err", text: string, from: number, to: number) => void | Promise<void>) {
    this.info = info;
    this.exited = new Promise((resolve) => (this.exit = resolve));
    this.socket = createConnection(info.socket);
    this.socket.on("connect", () => this.send({ op: "attach" }));
    this.socket.on("data", (chunk) => {
      if (this.left) return;
      this.carry += chunk.toString("utf8");
      for (let i = this.carry.indexOf("\n"); i >= 0; i = this.carry.indexOf("\n")) {
        const message = JSON.parse(this.carry.slice(0, i));
        this.carry = this.carry.slice(i + 1);
        if (message.op === "out") this.data(message.stream, message.at, Buffer.from(message.data, "base64"), line);
        else if (message.op === "exit") this.queue = this.queue.then(() => this.exit({ code: message.code, signal: message.signal }));
      }
    });
  }

  private data(stream: "out" | "err", at: number, bytes: Buffer, line: (s: "out" | "err", t: string, from: number, to: number) => void | Promise<void>) {
    if (this.at[stream] < 0) this.at[stream] = at;
    for (const whole of this.lines[stream].take(bytes)) {
      const text = whole.toString("utf8");
      const start = this.at[stream];
      this.at[stream] += whole.length + 1;
      const end = this.at[stream];
      this.queue = this.queue.then(async () => {
        await line(stream, text, start, end);
        this.acked[stream] = end;
        this.send({ op: "ack", out: this.acked.out, err: this.acked.err, ...(this.keep !== null ? { keep: this.keep } : {}) });
      });
    }
  }

  private send(message: unknown) {
    if (this.socket.writable) this.socket.write(JSON.stringify(message) + "\n");
  }

  write(text: string) {
    this.send({ op: "write", data: Buffer.from(text).toString("base64") });
  }

  closeStdin() {
    this.send({ op: "close_stdin" });
  }

  signal(signal: "TERM" | "KILL" | "INT", group = true) {
    this.send({ op: "signal", signal, group });
  }

  /// Read to the end: the runner cleans up and goes.
  done() {
    this.send({ op: "done" });
    this.socket.end();
  }

  /// This station lets go (stopping, handing over): the runner keeps the agent for the next one. Its side is closed and
  /// what comes meanwhile is not handled; resolved once the runner, having read to the end, closed it too (or was gone).
  /// A pipe has no closing of one side: it is asked to (`leave`), and closes once it has read up to there.
  detach(): Promise<void> {
    this.left = true;
    if (this.socket.destroyed) return Promise.resolve();
    const closed = new Promise<void>((resolve) => this.socket.once("close", () => resolve()));
    if (platform.runnerSaysLeave) this.send({ op: "leave" });
    this.socket.end();
    return closed;
  }
}
