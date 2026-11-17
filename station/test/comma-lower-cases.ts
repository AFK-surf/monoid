// JavaScript's String.prototype.toLowerCase as Comma's Task index lowercases a waited-for email with it (stats.ts
// attentionFields, now station/mb/src/comma), for the program to lowercase as Node does: each code point's lowercase
// (one code point, or more: U+0130 is two), and the Cased and Case_Ignorable properties that decide a capital sigma's
// final form. `node test/comma-lower-cases.ts` writes them as station/mb/src/comma/lower_table.mbt.
import { writeFileSync } from "node:fs";

const MAX = 0x10ffff;
const surrogate = (cp: number) => cp >= 0xd800 && cp <= 0xdfff;

/// Ranges [start, end, step, delta] of the code points whose lowercase is one code point `delta` away; then those
/// whose lowercase is more than one.
const ranges: [number, number, number, number][] = [];
const more: [number, number[]][] = [];
for (let cp = 0; cp <= MAX; cp++) {
  if (surrogate(cp) || cp === 0x3a3) continue;
  const lower = [...String.fromCodePoint(cp).toLowerCase()].map((c) => c.codePointAt(0)!);
  if (lower.length === 1 && lower[0] === cp) continue;
  if (lower.length !== 1) { more.push([cp, lower]); continue; }
  const delta = lower[0]! - cp;
  const last = ranges[ranges.length - 1];
  if (last !== undefined && last[3] === delta) {
    const step = cp - last[1];
    if (last[0] === last[1] && (step === 1 || step === 2)) { last[1] = cp; last[2] = step; continue; }
    if (step === last[2]) { last[1] = cp; continue; }
  }
  ranges.push([cp, cp, 1, delta]);
}

const property = (re: RegExp): [number, number][] => {
  const out: [number, number][] = [];
  for (let cp = 0; cp <= MAX; cp++) {
    if (surrogate(cp) || !re.test(String.fromCodePoint(cp))) continue;
    const last = out[out.length - 1];
    if (last !== undefined && last[1] === cp - 1) last[1] = cp;
    else out.push([cp, cp]);
  }
  return out;
};

const rows = (items: string[]) => items.map((i) => `  ${i},`).join("\n");
/// A list as `moon fmt` writes it: on one line where it fits.
const list = (head: string, items: string[]) => {
  const line = `${head} [${items.join(", ")}]`;
  return line.length <= 100 ? line : `${head} [\n${rows(items)}\n]`;
};
const text = `// Written by station/test/comma-lower-cases.ts from Node ${process.version}'s own toLowerCase: do not edit it.

///|
/// Code points whose lowercase is one code point: (start, end, step, delta).
let lower_ranges : FixedArray[(Int32, Int32, Int32, Int32)] = [
${rows(ranges.map((r) => `(${r.join(", ")})`))}
]

///|
/// Code points whose lowercase is more than one.
${list("let lower_more : FixedArray[(Int32, FixedArray[Int32])] =", more.map(([cp, l]) => `(${cp}, [${l.join(", ")}])`))}

///|
/// The Cased property's ranges.
let cased_ranges : FixedArray[(Int32, Int32)] = [
${rows(property(/\p{Cased}/u).map((r) => `(${r.join(", ")})`))}
]

///|
/// The Case_Ignorable property's ranges.
let ignorable_ranges : FixedArray[(Int32, Int32)] = [
${rows(property(/\p{Case_Ignorable}/u).map((r) => `(${r.join(", ")})`))}
]
`;
writeFileSync(new URL("../mb/src/comma/lower_table.mbt", import.meta.url), text);
