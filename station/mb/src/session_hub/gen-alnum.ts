// Writes alnum.mbt (node station/mb/src/session_hub/gen-alnum.ts): the code points JavaScript's
// /^[\p{Alphabetic}\p{N}]$/u takes, as ranges, which args.ts `isReason` counts by. station/test/mb-session-hub.test.ts
// holds the file to what this makes now (the Unicode of the Node it runs on).
import { writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

/// alnum.mbt's text.
export function alnumMbt(): string {
  const ranges: [number, number][] = [];
  const re = /^[\p{Alphabetic}\p{N}]$/u;
  let start = -1;
  for (let c = 0; c <= 0x110000; c++) {
    const ok = c < 0x110000 && !(c >= 0xd800 && c <= 0xdfff) && re.test(String.fromCodePoint(c));
    if (ok && start < 0) start = c;
    if (!ok && start >= 0) (ranges.push([start, c - 1]), (start = -1));
  }
  const lines = ranges.map(([a, b]) => `  (${a}, ${b}),`);
  return `// Written by gen-alnum.ts: don't edit. The code points of JavaScript's [\\p{Alphabetic}\\p{N}], as ranges (Unicode
// ${process.versions.unicode}).

///|
let alnum_ranges : Array[(Int, Int)] = [
${lines.join("\n")}
]
`;
}

if (import.meta.url === pathToFileURL(process.argv[1]!).href) writeFileSync(new URL("./alnum.mbt", import.meta.url), alnumMbt());
