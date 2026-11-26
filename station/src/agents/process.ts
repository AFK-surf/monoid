// A runtime process under a runner (./runner.ts), as the drivers find, end and take one up; the process itself is read
// and written by the station's MoonBit program (./mb-agents.ts `HostedProcess`).
//
// Taking up: lines this station has handled are acknowledged once handled, so a next station is sent exactly the rest.
// After a crash there is no snapshot; `ackedOffset` says up to where the dead station had handled, which the program
// reads again (silently) to know where things stand before the rest comes (mb-agents.ts `replayOwn`; a Codex
// app-server's, `bytesWithin`).
import { open, stat } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { keyPart } from "./sandbox-name.ts";
import { log } from "../ops/log.ts";
import { Lines, RunnerConnection, listeningSoon, runnerOf, runnersDir, type Exit, type RunnerInfo } from "./runner.ts";
import { wall } from "../ops/fibers.ts";
import type { RuntimeKind } from "./runtime.ts";

/// A wait on another process (a grace raced against its exit): the machine's time.
const sleep = wall.sleep;

/// Lines Rust logged at debug: only with STILLFAIL_AGENTS_DEBUG set.
export const debug = (at: string, message: string, fields?: Record<string, unknown>) => {
  if (process.env.STILLFAIL_AGENTS_DEBUG) log.info(at, message, fields);
};

/// A runner id from something of the station's (a session key, a profile id): safe as a file name and short enough for
/// the socket's path (104 bytes on macOS); a hash keeps two keys that clean up the same apart.
export function runnerId(kind: RuntimeKind, key: string): string {
  return `${kind}-${keyPart(key)}`;
}

/// How Rust's process.rs `describe` says an exit: its code, or the signal's name.
export function describeExit(exit: Exit): string {
  if (exit.code !== null) return String(exit.code);
  const named = ["TERM", "KILL", "INT", "HUP"];
  if (exit.signal && named.includes(exit.signal)) return `SIG${exit.signal}`;
  return exit.signal ? `signal ${exit.signal}` : "unknown";
}

export function groupAlive(pgid: number): boolean {
  try {
    process.kill(-pgid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "EPERM";
  }
}

const pidAlive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// A runner of this id that keeps its process still (its socket there: one on its way out has let it go).
export const findRunner = async (data: string, id: string): Promise<RunnerInfo | undefined> => {
  const runner = await runnerOf(data, id);
  return runner !== undefined && runner.id === id && (await listeningSoon(runner)) ? runner : undefined;
};
export const outFile = (data: string, id: string) => join(runnersDir(data), `${id}.out`);

/// The connection's socket, which runner.ts keeps to itself: its errors would otherwise go unhandled, and its closing
/// (the runner gone, or another station attached) is how this one learns of it.
function socketOf(conn: RunnerConnection): import("node:net").Socket {
  return conn["socket"];
}

/// Ends a runner of this id left by an earlier station, and waits for it to go: `only` that runner (by its pid and its
/// start), none started under its id since. Whether there was one to end.
export async function endRunner(data: string, id: string, label: string, only?: RunnerInfo): Promise<boolean> {
  const info = await findRunner(data, id);
  if (!info || (only !== undefined && (info.runner !== only.runner || info.startedAt !== only.startedAt))) return false;
  log.warn("agents::process", "ending a runtime process left by a previous run", { label, runner: info.runner, pgid: info.pgid });
  if (await listeningSoon(info)) {
    const conn = new RunnerConnection(info, () => {});
    socketOf(conn).on("error", () => {});
    conn.signal("TERM", true);
    await Promise.race([conn.exited, sleep(2000)]);
    if (groupAlive(info.pgid)) conn.signal("KILL", true);
    await Promise.race([conn.exited, sleep(1000)]);
    conn.done();
  }
  for (let i = 0; i < 300 && pidAlive(info.runner); i++) await sleep(10);
  return true;
}

/// Where the runner will start sending stdout from: the end of what the previous station acknowledged; and where of
/// stdout that station kept what is read again after a crash (`keep`, told with that same ack; null: a runner from
/// before, or none told). Asked by attaching once without acknowledging anything (the runner sends from its
/// acknowledged place on each attach, saying first where that is: one from before says nothing).
export function ackedOffset(
  info: RunnerInfo,
  out: string,
  time: Pick<typeof wall, "after"> = wall,
): Promise<{ at: number; keep: number | null }> {
  return new Promise((resolve) => {
    const socket = createConnection(info.socket);
    let carry = "";
    let done = false;
    // (what is said after the place is taken from the output's size, read off the station's thread, is not looked at)
    let ending = false;
    const finish = (at: number, keep: number | null = null) => {
      if (done) return;
      done = true;
      quiet();
      socket.destroy();
      resolve({ at, keep });
    };
    const size = () => stat(out).then((s) => s.size, () => 0);
    const atEnd = () => {
      if (done || ending) return;
      ending = true;
      quiet();
      void size().then((end) => finish(end));
    };
    socket.on("error", atEnd);
    socket.on("end", atEnd);
    socket.on("connect", () => socket.write(JSON.stringify({ op: "attach" }) + "\n"));
    socket.on("data", (chunk) => {
      if (ending) return;
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const message = JSON.parse(carry.slice(0, i));
        carry = carry.slice(i + 1);
        if (message.op === "attached" && Number.isSafeInteger(message.out)) return finish(message.out, Number.isSafeInteger(message.keep) ? Math.min(message.keep, message.out) : null);
        if (message.op === "out" && message.stream === "out") return finish(message.at);
        // The exit comes after all output: nothing of stdout was left to send.
        if (message.op === "exit") return atEnd();
      }
    });
    // Nothing of stdout comes: all of it was acknowledged. What it had then is the place; output written just after
    // that look would come in the moment after, and says its own place.
    let quiet = time.after(400, () => {
      void size().then((end) => {
        if (!done && !ending) quiet = time.after(150, () => finish(end));
      });
    });
  });
}

/// How much of a runner's output `bytesWithin` holds at once.
const READ_CHUNK = 1 << 20;

/// `linesWithin`'s lines as their bytes, not decoded: what reads only some of them tells the rest by how they begin
/// (codex.ts `takeUp`), and most of an app-server's output is lines it passes over, MBs each.
export async function* bytesWithin(file: string, start: number, end: number, chunk = READ_CHUNK): AsyncGenerator<{ bytes: Buffer; at: number }> {
  if (end <= start) return;
  const fd = await open(file, "r");
  try {
    // A line longer than a chunk is held a part at a time and joined once, at its end.
    const lines = new Lines();
    let at = start;
    // Where the line held (or the next) begins in the file.
    let base = start;
    while (at < end) {
      const buf = Buffer.allocUnsafe(Math.min(chunk, end - at));
      const { bytesRead: n } = await fd.read(buf, 0, buf.length, at);
      if (n <= 0) break;
      // Where the runner gave the disk back (what was acknowledged long before: native/runner `punch`) it reads as
      // zeros: skipped, with the line it cut (never carried on, a part at a time, as one line hundreds of MB long).
      let skip = 0;
      if (buf[0] === 0) {
        while (skip < n && buf[skip] === 0) skip++;
        lines.drop();
        base = at + skip;
      }
      at += n;
      for (const line of lines.take(buf.subarray(skip, n))) {
        const lineAt = base;
        base += line.length + 1;
        yield { bytes: line.at(-1) === 0x0d ? line.subarray(0, -1) : line, at: lineAt };
      }
    }
  } finally {
    await fd.close();
  }
}
