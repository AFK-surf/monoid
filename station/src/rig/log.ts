// What a rig was told to run (a station that only runs tasks): a line for each command a station prepared on it and each one run with a
// secret, with the chat that asked, kept on the rig itself (<data>/rig/commands.log), where no station or agent
// writes. Its person reads the last of it from their app (through a station); `stillfail status` names the file.
import { appendFile, mkdir, open, rename, stat } from "node:fs/promises";
import { dirname } from "node:path";

/// `device`: a chat's connection to one of the rig's devices (`name` the device's, `command` how it was reached).
export type Command = { at: number; workspace?: string; station: string; session: string; key: string; name: string; command: string; kind: "task" | "secret" | "device" };

/// The file goes to `.1` past this, the one before it gone.
const FILE_MAX = 4 * 1024 * 1024;
/// A line's command is cut to this (what was run in full is in the task's own record).
const COMMAND_MAX = 2000;
/// The most of the file's end read for its last lines.
const TAIL_BYTES = 256 * 1024;

export class CommandLog {
  readonly #path: string;
  /// The lines asked for, appended in turn off the main thread (two going past FILE_MAX at once would each move the
  /// file aside, the second taking the first's line with it).
  #queue: Promise<void>;

  constructor(path: string) {
    this.#path = path;
    this.#queue = mkdir(dirname(path), { recursive: true }).then(() => {}, () => {});
  }

  add(c: Command): void {
    const line = JSON.stringify({ ...c, command: c.command.slice(0, COMMAND_MAX) }) + "\n";
    this.#queue = this.#queue.then(() => this.#append(line));
  }

  async #append(line: string): Promise<void> {
    try {
      const size = await stat(this.#path).then((s) => s.size, () => 0);
      if (size > FILE_MAX) await rename(this.#path, `${this.#path}.1`);
      await appendFile(this.#path, line, { mode: 0o600 });
    } catch {
      // A full disk does not stop the task: the station's own log says what it ran too.
    }
  }

  /// Once every line asked for so far is written (or failed).
  written(): Promise<void> {
    return this.#queue;
  }

  /// Its last `limit` lines, newest first (those asked for before it among them). When `workspace` is given, only lines
  /// of that workspace (and legacy lines without `workspace` when `includeLegacy` is true).
  async last(limit: number, workspace?: string, includeLegacy = false): Promise<Command[]> {
    await this.#queue;
    let fh: Awaited<ReturnType<typeof open>>;
    try {
      fh = await open(this.#path, "r");
    } catch {
      return [];
    }
    try {
      const size = (await fh.stat()).size;
      const from = Math.max(0, size - TAIL_BYTES);
      const buffer = Buffer.alloc(size - from);
      const { bytesRead } = await fh.read(buffer, 0, buffer.length, from);
      const lines = buffer.subarray(0, bytesRead).toString("utf8").split("\n");
      // Read from the middle of the file: its first line is the end of one.
      if (from > 0) lines.shift();
      const out: Command[] = [];
      for (let i = lines.length - 1; i >= 0 && out.length < limit; i--) {
        if (lines[i] === "") continue;
        try {
          const parsed = JSON.parse(lines[i]!) as Command;
          if (workspace !== undefined && parsed.workspace !== workspace && !(includeLegacy && parsed.workspace === undefined)) continue;
          out.push(parsed);
        } catch {}
      }
      return out;
    } finally {
      await fh.close().catch(() => {});
    }
  }
}
