// What the station read of a picture or a film on its main thread before it read it off it (fs/promises,
// src/sessions/image-size.ts shownFactsSoon): the tests hold the two to the same facts.
import { closeSync, openSync, readSync as readFile } from "node:fs";
import { type Facts, facts, readSync } from "../../../client/core-ts/src/mediaFacts.ts";

export * from "../../src/sessions/image-size.ts";

/// The size the picture or film at `path` is shown at.
export function shownSize(path: string): [number, number] | null {
  const f = shownFacts(path);
  return f && [f.width, f.height];
}

/// What the picture or film at `path` says of itself.
export function shownFacts(path: string): Facts | null {
  try {
    const file = openSync(path, "r");
    try {
      return readSync(facts(), (at, n) => {
        const b = Buffer.alloc(n);
        return b.subarray(0, readFile(file, b, 0, n, at));
      });
    } finally {
      closeSync(file);
    }
  } catch {
    return null;
  }
}
