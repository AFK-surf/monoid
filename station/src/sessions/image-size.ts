// A picture's or a film's size as it is shown, from the few bytes of it that say: the core's reading
// (client/core-ts/src/mediaFacts.ts), of a file here or bytes at hand. A film's length and how many frames its picture
// has are read from the same header (shownFactsSoon), so a message carries them and a page shows them before it reads the
// film's head and its end.
import { open } from "node:fs/promises";
import { type Facts, facts, readAsync, readSync } from "../../../client/core-ts/src/mediaFacts.ts";

export type { Facts };

/// What the picture or film at `path` says of itself, read off the main thread (fs/promises): a film's head and its
/// moov box may be read from anywhere in a file of 50 MB or more.
export async function shownFactsSoon(path: string): Promise<Facts | null> {
  try {
    const file = await open(path, "r");
    try {
      const { size } = await file.stat();
      return await readAsync(
        facts(),
        async (start, end) => {
          const b = Buffer.alloc(end - start);
          const { bytesRead } = await file.read(b, 0, b.length, start);
          return b.subarray(0, bytesRead);
        },
        size,
      );
    } finally {
      await file.close();
    }
  } catch {
    return null;
  }
}

/// The size a picture's or a film's bytes `b` (all of them, or as far as they go) say it is shown at.
export function sizeOf(b: Uint8Array): [number, number] | null {
  const f = readSync(facts(), (at, n) => b.subarray(at, at + n));
  return f && [f.width, f.height];
}
