// What a group connect has heard of its anchor (`im/2`), kept in <data>/group-threads.json so that a station started
// again neither hands its agents a message twice nor loses one said meanwhile: for each connect, each space's place
// (`aseq`, the anchor's number of the last event of it taken: what `POST /sync` goes on from), this device's own count
// there and its last event's id (`dseq`, `prev`: what its next event is signed after), and each stream's last message
// taken (`last`, by its key: the space's id for its lobby, `<space>/<topic>` for a topic). A space first heard of with
// events in it has its place kept as it is: what was said before the station was in it is history (chat_history), not
// a request.
//
// A file of `im/1`'s (a stream's `since` and each conversation's last message number) names nothing `im/2` has: it is
// read as nothing heard yet, every space then first heard of.
//
// Written off the station's thread, one write at a time, the newest state each time (a burst of messages is one write
// or two).
import { readFileSync } from "node:fs";
import { rename, writeFile } from "node:fs/promises";
import { log } from "../ops/log.ts";

export type SpaceKept = { aseq: number; dseq: number; prev: string };
type Of = { v: 2; spaces: Record<string, SpaceKept>; last: Record<string, number> };
type Kept = Record<string, Of>;

const whole = (v: unknown) => (typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : 0);

export class GroupThreads {
  readonly path: string;
  private kept: Kept = {};
  private writing: Promise<void> = Promise.resolve();
  private dirty = false;

  constructor(path: string) {
    this.path = path;
    try {
      const v = JSON.parse(readFileSync(path, "utf8")); // sync: read once, before the station serves
      if (v !== null && typeof v === "object" && !Array.isArray(v)) {
        for (const [connect, of] of Object.entries(v as Record<string, any>)) {
          // (im/1's: nothing of it is im/2's)
          if (of?.v !== 2 || of.spaces === null || typeof of.spaces !== "object") continue;
          const spaces: Record<string, SpaceKept> = {};
          for (const [id, s] of Object.entries(of.spaces as Record<string, any>)) spaces[id] = { aseq: whole(s?.aseq), dseq: whole(s?.dseq), prev: typeof s?.prev === "string" ? s.prev : "" };
          const last: Record<string, number> = {};
          if (of.last !== null && typeof of.last === "object") for (const [k, n] of Object.entries(of.last)) last[k] = whole(n);
          this.kept[connect] = { v: 2, spaces, last };
        }
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") log.warn("group", "group threads file unreadable; starting empty", { error: (error as Error).message });
    }
  }

  private of(connect: string): Of {
    return (this.kept[connect] ??= { v: 2, spaces: {}, last: {} });
  }

  /// The spaces heard of, by id: where each goes on from.
  spaces(connect: string): Record<string, SpaceKept> {
    return this.kept[connect]?.spaces ?? {};
  }

  /// A space's place; undefined for one not heard of yet.
  space(connect: string, space: string): SpaceKept | undefined {
    return this.kept[connect]?.spaces[space];
  }

  /// A space's events taken up to `aseq` (a message of `stream` among them, where it is one).
  took(connect: string, space: string, aseq: number, stream?: string) {
    const of = this.of(connect);
    const s = (of.spaces[space] ??= { aseq: 0, dseq: 0, prev: "" });
    let changed = false;
    if (aseq > s.aseq) {
      s.aseq = aseq;
      changed = true;
    }
    if (stream !== undefined && (of.last[stream] ?? 0) < aseq) {
      of.last[stream] = aseq;
      changed = true;
    }
    if (changed) this.save();
  }

  /// The last message taken of a stream (0: none).
  last(connect: string, stream: string): number {
    return this.kept[connect]?.last[stream] ?? 0;
  }

  /// This device said its `dseq`-th event in the space, of id `prev` ("" where it is not known: one the anchor counts
  /// and this station kept nothing of).
  said(connect: string, space: string, dseq: number, prev: string) {
    const s = (this.of(connect).spaces[space] ??= { aseq: 0, dseq: 0, prev: "" });
    if (dseq < s.dseq || (dseq === s.dseq && (prev === "" || prev === s.prev))) return;
    // (a count the anchor said, of an event kept nowhere here: its id not known, the one after it says none)
    if (prev !== "" || dseq > s.dseq) s.prev = prev;
    s.dseq = dseq;
    this.save();
  }

  /// A space the connect is no longer in: its place and its streams'.
  forget(connect: string, space: string) {
    const of = this.kept[connect];
    if (of === undefined || !(space in of.spaces)) return;
    delete of.spaces[space];
    for (const k of Object.keys(of.last)) if (k === space || k.startsWith(`${space}/`)) delete of.last[k];
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
