// What a group connect has heard of its server, kept in <data>/group-threads.json so that a station started again
// neither hands its agents a message twice nor loses one said meanwhile: for each connect, the id of the last event its
// stream heard (where the next stream goes on from, `since`), and for each conversation the number of the last message
// taken (`last`: what is read again after it, `?after=`). A conversation first heard of with messages in it has its
// last number kept as it is: what was said before the station was in it is history (chat_history), not a request.
//
// Written off the station's thread, one write at a time, the newest state each time (a burst of messages is one write
// or two).
import { readFileSync } from "node:fs";
import { rename, writeFile } from "node:fs/promises";
import { log } from "../ops/log.ts";

type Of = { since: string | null; last: Record<string, number> };
type Kept = Record<string, Of>;

export class GroupThreads {
  readonly path: string;
  private kept: Kept = {};
  private writing: Promise<void> = Promise.resolve();
  private dirty = false;

  constructor(path: string) {
    this.path = path;
    try {
      const v = JSON.parse(readFileSync(path, "utf8")); // sync: read once, before the station serves
      if (v !== null && typeof v === "object" && !Array.isArray(v)) this.kept = v;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("group", "group threads file unreadable; starting empty", { error: (error as Error).message });
    }
  }

  private of(connect: string): Of {
    const at = (this.kept[connect] ??= { since: null, last: {} });
    if (typeof at.since !== "string") at.since = null;
    if (at.last === null || typeof at.last !== "object") at.last = {};
    return at;
  }

  /// Where the connect's next event stream goes on from (null: from now).
  since(connect: string): string | null {
    return this.kept[connect]?.since ?? null;
  }

  heardEvent(connect: string, id: string) {
    const at = this.of(connect);
    if (at.since === id) return;
    at.since = id;
    this.save();
  }

  /// The number of the last message taken of a conversation; undefined for one not heard of yet.
  last(connect: string, conversation: string): number | undefined {
    const n = this.kept[connect]?.last?.[conversation];
    return typeof n === "number" ? n : undefined;
  }

  took(connect: string, conversation: string, n: number) {
    const last = this.of(connect).last;
    if ((last[conversation] ?? -1) >= n) return;
    last[conversation] = n;
    this.save();
  }

  /// A conversation the connect is no longer in.
  forget(connect: string, conversation: string) {
    const last = this.kept[connect]?.last;
    if (last === undefined || !(conversation in last)) return;
    delete last[conversation];
    this.save();
  }

  /// A connect removed, or bound anew as another member: what it heard goes.
  drop(connect: string) {
    if (!(connect in this.kept)) return;
    delete this.kept[connect];
    this.save();
  }

  private save() {
    if (this.dirty) return;
    this.dirty = true;
    this.writing = this.writing.then(async () => {
      this.dirty = false;
      const tmp = `${this.path}.tmp`;
      try {
        await writeFile(tmp, JSON.stringify(this.kept));
        await rename(tmp, this.path);
      } catch (error) {
        log.warn("group", "group threads not kept", { error: (error as Error).message });
      }
    });
  }

  /// Once what was changed is on the disk.
  flushed(): Promise<void> {
    return this.writing;
  }
}
