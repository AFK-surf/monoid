// Where each entry of a transcript is (mb/src/history `Mark`; test/reference/tail.ts): what the pages of a history ask
// for (GET /sessions/:key/timeline), and where a session's live view goes on from (sessions/live.ts), read from a place
// near it, not from the transcript's start. A transcript is read once: as it is read, where its reading stands and a
// mark every MARK_EVERY entries (or MARK_BYTES) are kept, and kept on disk (`<data>/transcript-marks/`), so a reader
// that starts again (one goes after a minute idle, all of them at every start of the station) reads on from there, and
// a page of a long one (hundreds of MB) is the lines from the mark before it. How many entries a transcript has is what
// it was counted to have, the same across the station's starts.
//
// Kept as they were read by `READING` (mb/src/history; test/reference/transcript.ts): what a line gives changes with
// it, so marks of another are read anew. Here only where they are kept and their letting go; the TypeScript reading of
// them is the tests' (test/reference/transcripts.ts).
import { createHash } from "node:crypto";
import { rm } from "node:fs/promises";
import { join } from "node:path";

/// Where the readings of transcripts are kept on disk.
export const marksDir = (dataDir: string) => join(dataDir, "transcript-marks");

/// Where a transcript's reading is kept on disk, in `dir`.
export const fileOf = (dir: string, path: string) => join(dir, `${createHash("sha1").update(path).digest("hex")}.json`);

/// Lets go of what is kept on disk of transcripts' readings (their session deleted), off the main thread.
export async function forgetMarksSoon(dir: string, paths: string[]): Promise<void> {
  await Promise.all(paths.map((path) => rm(fileOf(dir, path), { force: true })));
}
