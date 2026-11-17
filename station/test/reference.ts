// The reader thread the MoonBit program's answers are compared with (test/reference-worker.ts).
import { Worker } from "node:worker_threads";
import { Readers } from "../src/read/pool.ts";

/// The reference reader, a thread on `data`, given to a test's Readers in the program's place.
export const REFERENCE = (data: string) =>
  new Worker(new URL("./reference-worker.ts", import.meta.url), { workerData: { data }, resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 8 } });

/// Readers on `data` whose reads the program answers (`mb`, its binary), or else the reader thread of before.
export function readersOf(data: string, mb: string | null, size = 1): Readers {
  return mb === null ? new Readers(data, size, REFERENCE) : Object.assign(new Readers(data, size), { mbReader: mb });
}
