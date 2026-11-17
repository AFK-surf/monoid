// The memory's MoonBit program (station/mb src/memory, `--builder memory`) asked as the reference's functions are
// called (test/reference/memory-merge.ts), so that a test gives both the same and compares what they say. Content goes
// as hex both ways.
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import type { Rec } from "../src/share/memory.ts";
import { MemoryProgram } from "../src/share/memory-mb.ts";

export const binary = mbReaderBinary();
/// What a test of the program says where it is not built.
export const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

let program: MemoryProgram | null = null;
const dirs: string[] = [];
after(async () => {
  await program?.close();
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

/// A directory of the test's own, gone after it.
export function fresh(prefix = "memory-mb-"): string {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
}

/// The one program the test's file asks.
export function memoryProgram(): MemoryProgram {
  program ??= new MemoryProgram(fresh("memory-shell-"), { binary: binary! });
  return program;
}

const hex = (s: string | Buffer) => (typeof s === "string" ? Buffer.from(s, "utf8") : s).toString("hex");
const text = (h: string) => Buffer.from(h, "hex").toString("utf8");

export const mb = {
  isText: async (bytes: Buffer): Promise<boolean> => (await memoryProgram().ask("isText", { bytes: hex(bytes) })).value,
  matches: async (a: string[], b: string[]): Promise<[number, number][] | null> => (await memoryProgram().ask("matches", { a, b })).value,
  merge3: async (base: string | Buffer, newer: string | Buffer, older: string | Buffer): Promise<string | null> => {
    const v = (await memoryProgram().ask("merge3", { base: hex(base), newer: hex(newer), older: hex(older) })).value;
    return v === null ? null : text(v);
  },
  unionLines: async (newer: string | Buffer, older: string | Buffer, newerName: string | null, olderName: string | null): Promise<string> =>
    text((await memoryProgram().ask("union", { newer: hex(newer), older: hex(older), newerName, olderName })).value),
  alike: async (a: string | Buffer, b: string | Buffer): Promise<boolean> => (await memoryProgram().ask("alike", { a: hex(a), b: hex(b) })).value,
  conflictPath: async (path: string, station: string): Promise<string> => (await memoryProgram().ask("conflictPath", { path, station })).value,
  stationTag: async (name: string): Promise<string> => (await memoryProgram().ask("tags", { names: [name] })).tags[0],
};

/// What the program decides of `mine` and `theirs` (decide.mbt), the contents given it as a peer brings them and its
/// blobs in `blobs`: as the reference's `decide` says it, the merged content read back from blobs/.
export async function decideMb(path: string, mine: Rec | undefined, theirs: Rec, contents: Map<string, Buffer>, nameOf: (s: string) => string, blobs: string): Promise<Json> {
  const given: Record<string, string> = {};
  for (const [h, b] of contents) given[h] = b.toString("hex");
  const names: Record<string, string> = { [theirs.by]: nameOf(theirs.by), ...(mine ? { [mine.by]: nameOf(mine.by) } : {}) };
  return memoryProgram().ask("decide", { path, mine: mine ?? null, theirs, names, given, blobs, prevMost: 16 });
}

type Json = any;
