// The reader thread the MoonBit program's answers are compared with (test/reference-worker.ts).
import { Readers } from "../src/read/pool.ts";

export const REFERENCE_WORKER = new URL("./reference-worker.ts", import.meta.url);

/// Readers on `data` whose reads the program answers (`mb`, its binary), or else the reader thread of before.
export function readersOf(data: string, mb: string | null, size = 1): Readers {
  return mb === null ? new Readers(data, size, REFERENCE_WORKER) : Object.assign(new Readers(data, size), { mbReader: mb });
}
