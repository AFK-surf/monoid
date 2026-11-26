// The agents' memory's files and merges by the MoonBit program (`--builder memory`, station/mb src/memory; the
// station's share/memory-mb.ts) held to the TypeScript it replaced (test/reference/memory-merge.ts) on the same input:
// byte for byte the same text of each function, the same decision of two records (its record, the merged content kept
// in blobs/, the version kept beside it), and the same files read of a workspace's memory, in the same order, held
// back alike.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import type { Rec } from "../src/share/memory.ts";
import { memoryPath, SKIPPED } from "../src/share/memory.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS } from "../src/sessions/agent-home.ts";
import { IDLE_MS, MemoryProgram, MemoryProgramStopped } from "../src/share/memory-mb.ts";
import { binary, decideMb, fresh, mb, memoryProgram, skip } from "./memory-program.ts";
import { alike, conflictPath, decide, isText, matches, merge3, readMemory, stationTag, unionLines } from "./reference/memory-merge.ts";

const sha = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

/// The same seeded stream of numbers on every machine.
function rng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/// Lines of a few words only, so that what is alike and what ties is common.
const WORDS = ["", "a", "b", "c", "- x", "- [ccvm] x", "- y", "# h", "---", "  1. one", "* [Studio] s", " - z", "中文", "é", "😀", "x\r", "[a] b", "　- w"];
function randomText(r: () => number, most: number): string {
  const n = Math.floor(r() * most);
  const lines: string[] = [];
  for (let i = 0; i < n; i++) lines.push(WORDS[Math.floor(r() * WORDS.length)]!);
  return lines.join(r() < 0.5 ? "\n" : "\r\n") + (r() < 0.5 ? "\n" : "");
}
/// `text` changed a little: lines taken out, put in, changed.
function edited(r: () => number, text: string): string {
  const lines = text.split("\n");
  const n = 1 + Math.floor(r() * 4);
  for (let k = 0; k < n; k++) {
    const at = Math.floor(r() * (lines.length + 1));
    const what = r();
    if (what < 0.33 && lines.length > 0) lines.splice(Math.min(at, lines.length - 1), 1);
    else if (what < 0.66) lines.splice(at, 0, WORDS[Math.floor(r() * WORDS.length)]!);
    else if (lines.length > 0) lines[Math.min(at, lines.length - 1)] = WORDS[Math.floor(r() * WORDS.length)]!;
  }
  return lines.join("\n");
}

test("isText: UTF-8 with no NUL as Buffer's round trip says it, byte for byte", { skip }, async () => {
  const cases: number[][] = [
    [], [0x61], [0x00], [0x61, 0x00, 0x62], [0xe4, 0xb8, 0xad], [0xf0, 0x9f, 0x98, 0x80], [0xef, 0xbb, 0xbf, 0x61], [0xef, 0xbf, 0xbd],
    // surrogates alone and paired, as CESU writes them
    [0xed, 0xa0, 0x80], [0xed, 0xbf, 0xbf], [0xed, 0xa0, 0xbd, 0xed, 0xb8, 0x80], [0xed, 0x9f, 0xbf],
    // longer forms than needed
    [0xc0, 0xaf], [0xc1, 0xbf], [0xe0, 0x80, 0xaf], [0xe0, 0x9f, 0xbf], [0xf0, 0x80, 0x80, 0xaf], [0xf0, 0x8f, 0xbf, 0xbf], [0xc0, 0x80],
    // cut short, at the end and before more
    [0xe4, 0xb8], [0xe4], [0xf0, 0x9f, 0x98], [0xe4, 0xb8, 0x61], [0xc3], [0xc3, 0x41],
    // past U+10FFFF, bytes that never lead, a stray continuation
    [0xf4, 0x8f, 0xbf, 0xbf], [0xf4, 0x90, 0x80, 0x80], [0xf5, 0x80, 0x80, 0x80], [0xf8, 0x88, 0x80, 0x80, 0x80], [0xfe], [0xff], [0x80], [0xbf, 0x61],
  ];
  const r = rng(7);
  for (let i = 0; i < 300; i++) {
    const n = Math.floor(r() * 12);
    const bytes: number[] = [];
    for (let k = 0; k < n; k++) bytes.push(r() < 0.5 ? Math.floor(r() * 256) : [0x61, 0x80, 0xbf, 0xc2, 0xe0, 0xed, 0xf0, 0xf4, 0x9f, 0xa0][Math.floor(r() * 10)]!);
    cases.push(bytes);
  }
  for (const c of cases) {
    const b = Buffer.from(c);
    assert.equal(await mb.isText(b), isText(b), `isText(${b.toString("hex")})`);
  }
});

test("matches: the same pairs, ties broken alike, none past 3000 lines apart", { skip }, async () => {
  const lines = (n: number, f: (i: number) => string) => Array.from({ length: n }, (_, i) => f(i));
  const cases: [string[], string[]][] = [
    [[], []], [[""], [""]], [["a"], []], [[], ["a"]], [["a", "b"], ["b", "a"]], [["a", "b", "a"], ["a", "a", "b"]],
    [["x", "a", "b", "y"], ["x", "b", "a", "y"]], [["a", "b", "c", "a", "b", "c"], ["c", "b", "a", "c", "b", "a"]],
    // 3000 apart is compared, 3001 not
    [lines(3000, (i) => `a${i}`), lines(3000, (i) => `b${i}`)],
    [lines(3001, (i) => `a${i}`), lines(5, (i) => `b${i}`)],
    [["s", ...lines(3001, (i) => `a${i}`), "e"], ["s", "e"]],
    [["s", ...lines(3000, (i) => `${i % 7}`), "e"], ["s", ...lines(2999, (i) => `${i % 5}`), "e"]],
  ];
  const r = rng(11);
  for (let i = 0; i < 300; i++) {
    const pick = () => lines(Math.floor(r() * 14), () => "abc"[Math.floor(r() * 3)]!);
    cases.push([pick(), pick()]);
  }
  for (const [a, b] of cases) assert.deepEqual(await mb.matches(a, b), matches(a, b), `matches(${a.length} lines, ${b.length} lines)`);
});

test("merge3: the same text, byte for byte, of every kind of two changes", { skip }, async () => {
  const many = (n: number, p: string) => Array.from({ length: n }, (_, i) => `${p}${i}`).join("\n");
  const cases: [string, string, string][] = [
    ["", "", ""], ["", "a", ""], ["", "", "b"], ["", "a", "b"], ["a\n", "a\n", "a\n"],
    ["a\nb\nc\n", "A\nb\nc\n", "a\nb\nC\n"],
    ["a\nb\n", "a\nb\nnew\n", "a\nb\nold\n"],
    ["a\nb\n", "a\n", "a\nb\n"],
    // both made the same change: once
    ["a\nb\nc", "a\nX\nc", "a\nX\nc"],
    // one deleted a line the other changed
    ["a\nb\nc", "a\nc", "a\nB\nc"],
    ["a\nb\nc", "a\nB\nc", "a\nc"],
    // CRLF: "\r" is a line's own
    ["a\r\nb\r\nc\r\n", "a\r\nB\r\nc\r\n", "a\r\nb\r\nC\r\n"],
    ["a\r\nb\r\n", "a\nb\n", "a\r\nb\r\nc\r\n"],
    // both added at one place, the newer's first
    ["- one\n", "- one\n- mine\n", "- one\n- theirs\n"],
    ["中\n文\n", "中\n😀\n文\n", "中\n文\né\n"],
    // adjacent non-overlapping edits: no conflict, no resurrection
    ["A\nB\nC\nD\n", "A'\nC\nD\n", "A\nB\nC'\nD\n"],
    // condense-rebound regression: 40 lines -> 10 lines vs edit at line 41 + append
    [
      [...Array.from({ length: 40 }, (_, i) => `- rule ${i}`), "- tail"].join("\n") + "\n",
      [...Array.from({ length: 10 }, (_, i) => `- compact ${i}`), "- tail"].join("\n") + "\n",
      [...Array.from({ length: 40 }, (_, i) => `- rule ${i}`), "- tail updated", "- appended"].join("\n") + "\n",
    ],
    // overlapping conflict with shared content line + fenced code block with duplicate closing braces
    [
      "# s\n- keep\n- old\n```js\nfunction f() {\n  if (x) {\n  }\n}\n```\n",
      "# s\n- keep\n- shared\n- newer\n```js\nfunction f() {\n  if (a) {\n  }\n}\n```\n",
      "# s\n- keep\n- shared\n- older\n```js\nfunction f() {\n  if (b) {\n  }\n}\n```\n",
    ],
    // too far apart: none
    [many(3001, "b"), many(3001, "w"), "x"],
    [many(10, "b"), many(3002, "w"), many(10, "b")],
    // within it still
    ["s\n" + many(2999, "b") + "\ne", "s\n" + many(2999, "w") + "\ne", "s\n" + many(2999, "l") + "\ne"],
  ];
  const r = rng(13);
  for (let i = 0; i < 300; i++) {
    const base = randomText(r, 12);
    cases.push([base, edited(r, base), edited(r, base)]);
  }
  for (const [base, w, l] of cases) assert.equal(await mb.merge3(base, w, l), merge3(base, w, l), `merge3(${JSON.stringify([base.slice(0, 60), w.slice(0, 60), l.slice(0, 60)])})`);
});

test("unionLines: the same lines, marked alike, with and without the stations' names", { skip }, async () => {
  const names: (string | null)[] = [null, "ccvm", "Mini 1", "中文站", "x".repeat(90), ""];
  const cases: [string, string][] = [
    ["", ""], ["- x\n- y\n", "- [ccvm] x\n- z\n"], ["# 全局记忆\n\n- /tmp 共用。\n- ccvm 盘小。\n", "# 全局记忆\n\n- /tmp 共用。\n- UI 先出图。\n"],
    ["---\nname: a\n---\n- a\n", "---\nname: a\n---\n- b\n"],
    ["1. one\n2. two\n", "1. one\n3. three\n"], ["  * [Studio] s\n", "  * s\n"], ["[a] b\n", "b\n"], ["[a]b\n", "c\n"],
    [`- [${"y".repeat(80)}] long\n`, `- [${"y".repeat(81)}] longer\n`], ["- []  empty\n", "- [\n] x\n"],
    [" - nbsp\n　- ideographic\n﻿- bom\n", " - ls\n - mm\n"], ["\t\n  \n", "#x\n  # y\n"],
    ["10. ten\n-x\n- \n", "10.ten\n+ plus\n*\tstar\n"], ["a\r\nb\r\n", "a\nb\n"],
    // reordered paragraphs, checkboxes, fenced lines, and trailing-nl preservation on >3000 fallback
    ["- p2\n- p1\n- only-w\n", "- p1\n- p2\n- only-l\n"],
    ["- [ ] release\n```\n- [ccvm] keep\n```\n", "- [x] release\n```\n- [ccvm] keep\n```\n"],
    ["alpha", "beta\n\n\ngamma\n"],
    [
      Array.from({ length: 3010 }, (_, i) => `- rule ${i}`).join("\n") + "\n",
      [...Array.from({ length: 3010 }, (_, i) => `- rule ${3009 - i}`), "- unique-l"].join("\n") + "\n",
    ],
  ];
  const r = rng(17);
  for (let i = 0; i < 300; i++) cases.push([randomText(r, 10), randomText(r, 10)]);
  for (const [w, l] of cases) {
    for (const nw of names) {
      for (const nl of [null, "Studio", nw]) {
        assert.equal(await mb.unionLines(w, l, nw, nl), unionLines(w, l, nw, nl), `unionLines(${JSON.stringify([w.slice(0, 60), l.slice(0, 60), nw, nl])})`);
      }
    }
  }
});

test("alike: the same answer past each front matter, of what is half alike and what is not", { skip }, async () => {
  const fm = (name: string, body: string) => `---\nname: ${name}\ndescription: d\n---\n${body}`;
  const cases: [string, string][] = [
    ["", ""], ["a", "a"], ["\n\n", "\n"], [fm("a", "- one\n- two\n"), fm("b", "- one\n- three\n")], [fm("a", "- one\n"), fm("a", "- two\n")],
    ["---\n---\nbody\n", "---\n---\nbody\n"], ["---\nx\n---", "---\ny\n---"], ["---\nx\n----\nz\n", "---\ny\n---\nz\n"],
    [fm("a", "1\n2\n3\n4\n"), fm("a", "1\n2\n5\n6\n")], [fm("a", "1\n2\n3\n4\n5\n"), fm("a", "1\n2\n6\n7\n8\n")],
  ];
  const r = rng(19);
  for (let i = 0; i < 300; i++) {
    const a = randomText(r, 10);
    cases.push([r() < 0.5 ? fm("s", a) : a, r() < 0.5 ? edited(r, a) : randomText(r, 10)]);
  }
  for (const [a, b] of cases) assert.equal(await mb.alike(a, b), alike(a, b), `alike(${JSON.stringify([a.slice(0, 60), b.slice(0, 60)])})`);
});

test("stationTag and conflictPath: the same names of every kind of station's name", { skip }, async () => {
  const stations = [
    "ccvm", "Mini 1", "Studio's Mac", "中文 站点", "日本語", "한국어", "Ünïcödé", "é combining", "x²³ digits", "٣ arabic digit",
    "😀 emoji 😀", "---", "", "   ", "a--b", "-a-", "a_b-c", "!!!", "x".repeat(60), "中".repeat(50), "😀".repeat(30), `${"a".repeat(39)}😀`,
    "tab\tand\nline", "a/b\\c:d", "Ⅻ roman", "ǅ titlecase", "ʰ modifier", "〇 ideographic zero",
  ];
  for (const s of stations) {
    assert.equal(await mb.stationTag(s), stationTag(s), `stationTag(${JSON.stringify(s)})`);
    for (const path of ["MEMORY.md", "skills/a/SKILL.md", "skills/a/b/run", "skills/a/.hidden", "skills/a/x.tar.gz", "noext", ".dot"]) {
      assert.equal(await mb.conflictPath(path, s), conflictPath(path, s), `conflictPath(${path}, ${JSON.stringify(s)})`);
    }
  }
});

const A = "a".repeat(64);
const B = "b".repeat(64);
const NAMES: Record<string, string> = { [A]: "ccvm", [B]: "Mini 1" };
const nameOf = (s: string) => NAMES[s] ?? s.slice(0, 8);

/// What the reference decides and the program decides of the same two records and contents, made alike to compare:
/// the merged content read back from the program's blobs/.
async function bothDecide(path: string, mine: Rec | undefined, theirs: Rec, contents: Map<string, Buffer>, kept: Map<string, Buffer>) {
  const blobs = fresh("memory-blobs-");
  // What this station keeps: in its blobs/ (one of them changed on the disk, which is none).
  for (const [h, b] of kept) writeFileSync(join(blobs, h), b);
  const all = new Map([...kept, ...contents]);
  const want = decide(path, mine, theirs, (h) => all.get(h) ?? null, nameOf);
  const got = await decideMb(path, mine, theirs, contents, nameOf, blobs);
  const label = `decide(${path}, ${JSON.stringify(mine)}, ${JSON.stringify(theirs)})`;
  assert.equal(got.kind, want.kind, label);
  if (want.kind === "merge") {
    assert.deepEqual(got.rec, want.rec, label);
    // (what was brought or kept already, as the station writes it; what was made, from blobs/)
    assert.deepEqual(all.get(got.rec.hash) ?? readFileSync(join(blobs, got.rec.hash)), want.content, label);
    // made here: kept as only its owner reads it
    if (!all.has(got.rec.hash)) assert.equal(statSync(join(blobs, got.rec.hash)).mode & 0o777, 0o600, label);
    // (the program says where the other's is kept beside it; the station keeps it only at a memory's path)
    if (want.beside === null) assert.ok(got.beside === null || !memoryPath(got.beside.path), label);
    else assert.deepEqual({ path: got.beside?.path, rec: got.beside?.rec }, { path: want.beside.path, rec: want.beside.rec }, label);
  }
  if (want.kind === "take") assert.equal(got.content, all.has(theirs.hash), label);
}

test("decide: the same outcome, record and merged content of every kind of two records", { skip }, async () => {
  const rec = (text: string | null, by: string, at: number, prev: string[] = [], extra: Partial<Rec> = {}): Rec => ({ hash: text === null ? "" : sha(text), at, by, prev, size: text === null ? 0 : Buffer.byteLength(text), mode: 0o644, ...extra });
  const c = (...texts: string[]) => new Map(texts.map((t) => [sha(t), Buffer.from(t)] as [string, Buffer]));
  const base = "- one\n- two\n";
  const mine = "- one\n- two\n- mine\n";
  const theirs = "- zero\n- one\n- two\n";
  // none here, the same, one after the other, both ways
  await bothDecide("MEMORY.md", undefined, rec(theirs, B, 2), c(theirs), new Map());
  await bothDecide("MEMORY.md", rec(mine, A, 2), rec(mine, B, 3), new Map(), c(mine));
  await bothDecide("MEMORY.md", rec(mine, B, 3), rec(mine, A, 2), new Map(), c(mine));
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(mine)]), c(theirs), c(mine));
  await bothDecide("MEMORY.md", rec(mine, A, 3, [sha(theirs)]), rec(theirs, B, 2), new Map(), c(mine));
  // made beside each other from one version: three-way, the base kept here, brought, or neither
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base));
  await bothDecide("MEMORY.md", rec(mine, A, 4, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs, base), c(mine));
  await bothDecide("skills/p/SKILL.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine));
  // ties: the same time, then the station, then the hash
  await bothDecide("MEMORY.md", rec(mine, A, 3, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base));
  await bothDecide("MEMORY.md", rec(mine, B, 3, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), c(mine, base));
  // deleted on one, edited on the other; deleted on both
  await bothDecide("MEMORY.md", rec(null, A, 5, [sha(base)]), rec(theirs, B, 3, [sha(base)]), c(theirs), new Map());
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(null, B, 6, [sha(base)]), new Map(), c(mine));
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(null, B, 6, [sha(base)]), new Map(), new Map());
  // none both came from: MEMORY.md each line once (marked where each was a station's of before), a skill alike or kept
  // beside, `.conflict-<station>`
  await bothDecide("MEMORY.md", rec(mine, A, 2, [], { origin: true }), rec(theirs, B, 3, [], { origin: true }), c(theirs), c(mine));
  await bothDecide("MEMORY.md", rec(mine, A, 2), rec(theirs, B, 3, [], { origin: true }), c(theirs), c(mine));
  await bothDecide("skills/p/SKILL.md", rec(mine, A, 2), rec(theirs, B, 3), c(theirs), c(mine));
  await bothDecide("skills/p/SKILL.md", rec("---\nname: p\n---\nA\nB\n", A, 2, [], { mode: 0o755 }), rec("---\nname: p\n---\nC\nD\n", B, 3), c("---\nname: p\n---\nC\nD\n"), c("---\nname: p\n---\nA\nB\n"));
  await bothDecide("skills/p/run", rec("x", A, 2), rec("y", B, 3), c("y"), c("x"));
  // what is no text: kept beside, never merged by lines
  const bin = Buffer.from([0x00, 0x01, 0xff]);
  const bin2 = Buffer.from([0xed, 0xa0, 0x80]);
  const hb = (b: Buffer, by: string, at: number, prev: string[] = []): Rec => ({ hash: sha(b), at, by, prev, size: b.length, mode: 0o644 });
  await bothDecide("skills/p/blob", hb(bin, A, 2, [sha(base)]), hb(bin2, B, 3, [sha(base)]), new Map([[sha(bin2), bin2]]), new Map([[sha(bin), bin], [sha(base), Buffer.from(base)]]));
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(bin)]), rec(theirs, B, 3, [sha(bin)]), c(theirs), new Map([[sha(mine), Buffer.from(mine)], [sha(bin), bin]]));
  // a version not here: kept
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base)]), rec(theirs, B, 3, [sha(base)]), new Map(), c(mine));
  await bothDecide("MEMORY.md", undefined, rec(theirs, B, 2), new Map(), new Map());
  // too far apart to merge: the newer's, the other's beside it
  const far = (p: string) => Array.from({ length: 3001 }, (_, i) => `${p}${i}`).join("\n");
  await bothDecide("skills/p/SKILL.md", rec(far("a"), A, 2, [sha(far("b"))]), rec(far("c"), B, 3, [sha(far("b"))]), c(far("c")), c(far("a"), far("b")));
  // so many versions before: at most 32 of them kept
  const many = Array.from({ length: 40 }, (_, i) => sha(`v${i}`));
  await bothDecide("MEMORY.md", rec(mine, A, 2, [sha(base), ...many.slice(0, 20)]), rec(theirs, B, 3, [sha(base), ...many.slice(20)]), c(theirs), c(mine, base));
  // a name that is no file's: nothing beside it
  NAMES[B] = "x".repeat(300);
  await bothDecide("skills/p/SKILL.md", rec(mine, A, 2), rec(theirs, B, 3), c(theirs), c(mine));
  NAMES[B] = "Mini 1";
  // Hypershell-style 8x repeated sections in MEMORY.md (with unique rules spread across copies + code fence) -> folded to 1x
  const hsBase = "# Global\n- shared A\n- shared B\n";
  const hsMine = [
    ...Array.from({ length: 4 }, (_, i) => `# Global\n- shared A\n- shared B\n- unique mine ${i}\n`),
    "# Code\n```ts\nfunction f() {\n  if (x) {\n  }\n}\n```\n",
  ].join("\n");
  const hsTheirs = [
    ...Array.from({ length: 4 }, (_, i) => `# Global\n- shared A\n- shared B\n- unique theirs ${i}\n`),
  ].join("\n");
  await bothDecide("MEMORY.md", rec(hsMine, A, 2, [sha(hsBase)]), rec(hsTheirs, B, 3, [sha(hsBase)]), c(hsTheirs), c(hsMine, hsBase));
  const hsPureDup = "# Global\n- shared A\n- shared B\n\n".repeat(4);
  const hsPureDup2 = "# Global\n- shared A\n- shared B\n\n".repeat(4) + "- extra\n";
  await bothDecide("MEMORY.md", rec(hsPureDup, A, 2), rec(hsPureDup2, B, 3), c(hsPureDup2), c(hsPureDup));
  // P0-1: non-MEMORY code file conflict keeps all closing braces
  const codeBase = "function f() {\n  return 0;\n}\n";
  const codeW = "function f() {\n  if (a) {\n    return 1;\n  }\n}\n";
  const codeL = "function f() {\n  if (b) {\n    return 2;\n  }\n}\n";
  await bothDecide("skills/p/run.ts", rec(codeW, A, 2, [sha(codeBase)]), rec(codeL, B, 3, [sha(codeBase)]), c(codeL), c(codeW, codeBase));
  // P0-2 / P1-1 / P1-2 / P2-2: MEMORY.md tables, thematic breaks, heading scopes, checkboxes, nested headings, inline/indented fences
  const structMine = "## A\n| k | v |\n|---|---|\n| 1 | 2 |\n***\n___\n- - -\n- 无\n- [ ] 发版\n### S\n- x\n## B\n| k | v |\n|---|---|\n| 3 | 4 |\n***\n- 无\n```x```\n    ```\n";
  const structTheirs = "## A\n- [x] 发版\n### S\n- y\n## B\n- z\n## A\n### S\n- x\n";
  await bothDecide("MEMORY.md", rec(structMine, A, 2), rec(structTheirs, B, 3), c(structTheirs), c(structMine));
  // random histories of a few versions
  const r = rng(23);
  for (let i = 0; i < 150; i++) {
    const texts = Array.from({ length: 4 }, () => randomText(r, 8));
    texts[1] = edited(r, texts[0]!);
    texts[2] = edited(r, texts[0]!);
    const pick = () => texts[Math.floor(r() * texts.length)]!;
    const [m, t] = [pick(), pick()];
    const prevOf = () => (r() < 0.6 ? [sha(texts[0]!)] : r() < 0.5 ? [] : [sha(pick())]);
    const mr = r() < 0.1 ? rec(null, A, 1 + Math.floor(r() * 3), prevOf()) : rec(m, A, 1 + Math.floor(r() * 3), prevOf(), r() < 0.3 ? { origin: true } : {});
    const tr = r() < 0.1 ? rec(null, B, 1 + Math.floor(r() * 3), prevOf()) : rec(t, B, 1 + Math.floor(r() * 3), prevOf(), r() < 0.3 ? { origin: true } : {});
    const kept = c(m, ...(r() < 0.5 ? [texts[0]!] : []));
    await bothDecide(r() < 0.5 ? "MEMORY.md" : "skills/p/SKILL.md", r() < 0.05 ? undefined : mr, tr, c(t), kept);
  }
});

test("the files read: the same, in the same order, held back alike, those changed kept in blobs/ privately", { skip }, async () => {
  const dir = fresh("memory-home-");
  const put = (path: string, text: string | Buffer, mode = 0o644) => {
    mkdirSync(join(dir, path, ".."), { recursive: true });
    writeFileSync(join(dir, path), text);
    chmodSync(join(dir, path), mode);
  };
  put("MEMORY.md", "# 全局记忆\n- 一条。\n");
  utimesSync(join(dir, "MEMORY.md"), 1_700_000_000.4567, 1_700_000_000.4567);
  // a skill with files at every depth, one to run, one only its owner reads, what programs make beside them
  put("skills/proj/SKILL.md", "---\nname: proj\n---\n- a\n");
  put("skills/proj/run.sh", "#!/bin/sh\n", 0o755);
  put("skills/proj/key", "secret\n", 0o600);
  put("skills/proj/b/c/d.txt", "deep\n");
  put("skills/proj/a.txt", "a\n");
  put("skills/proj/node_modules/x.js", "x\n");
  put("skills/proj/.hidden", "h\n");
  put("skills/proj/bad:name", "n\n");
  put("skills/proj/bin", Buffer.from([0, 1, 2, 255]));
  symlinkSync(join(dir, "skills/proj/a.txt"), join(dir, "skills/proj/link.txt"));
  // no SKILL.md yet; a built-in one; one skipped; a link; a file where a skill would be; not a portable name
  put("skills/draft/notes.md", "- later\n");
  put(`skills/${BUILTIN_SKILLS[0]}/SKILL.md`, "built in\n");
  put(`skills/${FEEDBACK_SKILL}/SKILL.md`, "built in\n");
  put("skills/__pycache__/SKILL.md", "x\n");
  symlinkSync(join(dir, "skills/proj"), join(dir, "skills/linked"));
  put("skills/loose.md", "x\n");
  put("skills/con/SKILL.md", "x\n");
  put("skills/trail./SKILL.md", "x\n");
  // too many files, too many bytes, a file too large
  put("skills/many/SKILL.md", "---\nname: many\n---\n");
  for (let i = 0; i < 200; i++) put(`skills/many/f${String(i).padStart(3, "0")}`, `${i}\n`);
  put("skills/large/SKILL.md", "---\nname: large\n---\n");
  put("skills/large/big", Buffer.alloc(512 * 1024 + 1, 0x61));
  put("skills/heavy/SKILL.md", "---\nname: heavy\n---\n");
  for (let i = 0; i < 9; i++) put(`skills/heavy/part${i}`, Buffer.alloc(500 * 1024, 0x62));
  put("skills/edge/SKILL.md", "---\nname: edge\n---\n");
  put("skills/edge/exact", Buffer.alloc(512 * 1024, 0x63));
  put("skills/中文技能/SKILL.md", "---\nname: 中文技能\n---\n- 中\n");
  put("skills/Ünï/SKILL.md", "---\nname: Ünï\n---\n");

  const want = await readMemory(dir);
  const scan = async (kept: Record<string, string>) => {
    const blobs = fresh("memory-blobs-");
    const got = await memoryProgram().ask("scan", { dir, blobs, kept, builtin: [...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS], skipped: [...SKIPPED], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 });
    return { got, blobs };
  };
  const { got, blobs } = await scan({});
  assert.deepEqual(got.files.map((f: any) => f.path), [...want.files.keys()]);
  assert.deepEqual(new Set(got.held), want.held);
  for (const f of got.files) {
    const w = want.files.get(f.path)!;
    assert.deepEqual({ hash: f.hash, size: f.size, mode: f.mode, mtime: f.mtime }, { hash: sha(w.bytes), size: w.bytes.length, mode: w.mode, mtime: w.mtime }, f.path);
    // kept, as only its owner reads it
    assert.deepEqual(readFileSync(join(blobs, f.hash)), w.bytes, f.path);
    assert.equal(statSync(join(blobs, f.hash)).mode & 0o777, 0o600, f.path);
  }
  // What the station keeps already is not kept again.
  const kept = Object.fromEntries(got.files.map((f: any) => [f.path, f.hash]));
  const again = await scan(kept);
  assert.deepEqual(again.got.files, got.files);
  for (const f of again.got.files) assert.equal(existsSync(join(again.blobs, f.hash)), false, f.path);
});

test("the files read: a MEMORY.md of nothing yet is not kept, nor told changed; one too large or a link held", { skip }, async () => {
  for (const [text, empty] of [["# still.fail memory\n", true], ["﻿  # ember memory \n\n", true], ["", true], ["# still.fail memory\n- one\n", false], [Buffer.from([0x23, 0xff]), false]] as [string | Buffer, boolean][]) {
    const dir = fresh("memory-home-");
    writeFileSync(join(dir, "MEMORY.md"), text);
    const blobs = fresh("memory-blobs-");
    const got = await memoryProgram().ask("scan", { dir, blobs, kept: {}, builtin: [], skipped: [], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 });
    assert.equal(got.files.length, 1);
    assert.equal(got.files[0].empty === true, empty, JSON.stringify(text));
    assert.equal(existsSync(join(blobs, got.files[0].hash)), !empty, JSON.stringify(text));
    // the station keeps a record of it already: told as any other
    const known = await memoryProgram().ask("scan", { dir, blobs, kept: { "MEMORY.md": "0".repeat(64) }, builtin: [], skipped: [], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 });
    assert.equal(known.files[0].empty, undefined);
  }
  for (const make of [
    (dir: string) => writeFileSync(join(dir, "MEMORY.md"), Buffer.alloc(512 * 1024 + 1, 0x61)),
    (dir: string) => (writeFileSync(join(dir, "real.md"), "x\n"), symlinkSync(join(dir, "real.md"), join(dir, "MEMORY.md"))),
    (dir: string) => (writeFileSync(join(dir, "MEMORY.md"), "x\n"), chmodSync(join(dir, "MEMORY.md"), 0o600)),
  ]) {
    const dir = fresh("memory-home-");
    make(dir);
    const ask = { dir, blobs: fresh("memory-blobs-"), kept: {}, builtin: [], skipped: [], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 };
    const got = await memoryProgram().ask("scan", ask);
    const want = await readMemory(dir);
    assert.deepEqual(got.files.map((f: any) => f.path), [...want.files.keys()]);
    assert.deepEqual(new Set(got.held), want.held);
  }
});

test("the files read: a MEMORY.md only its owner reads is told as any other, 0o644; a file of a skill only its owner reads is not", { skip }, async () => {
  const dir = fresh("memory-home-");
  writeFileSync(join(dir, "MEMORY.md"), "- one\n");
  chmodSync(join(dir, "MEMORY.md"), 0o600);
  mkdirSync(join(dir, "skills/p"), { recursive: true });
  writeFileSync(join(dir, "skills/p/SKILL.md"), "- a\n");
  writeFileSync(join(dir, "skills/p/secret"), "key\n");
  chmodSync(join(dir, "skills/p/secret"), 0o600);
  const got = await memoryProgram().ask("scan", { dir, blobs: fresh("memory-blobs-"), kept: {}, builtin: [], skipped: [], fileMost: 512 * 1024, skillMost: 4 * 1024 * 1024, skillFiles: 200 });
  assert.deepEqual(got.files.map((f: any) => [f.path, f.mode]), [["MEMORY.md", 0o644], ["skills/p/SKILL.md", 0o644]]);
  assert.equal(got.files[0].hash, sha(Buffer.from("- one\n")));
  const want = await readMemory(dir);
  assert.deepEqual([...want.files].map(([p, f]) => [p, f.mode]), [["MEMORY.md", 0o644], ["skills/p/SKILL.md", 0o644]]);
});

test("the program is started by an ask, let go IDLE_MS after the last, or at once when the station is short of memory", { skip }, async () => {
  let due: (() => void) | null = null;
  const program = new MemoryProgram(fresh("memory-shell-"), { binary: binary!, after: (ms, f) => (assert.equal(ms, IDLE_MS), (due = f), () => (due = null)) });
  try {
    assert.equal(program.running, false);
    assert.equal((await program.ask("tags", { names: ["a b"] })).tags[0], "a-b");
    assert.equal(program.running, true);
    assert.notEqual(due, null);
    due!();
    assert.equal(program.running, false);
    // asked again: a new one, which a trim lets go
    await program.ask("tags", { names: ["c"] });
    assert.equal(program.started, 2);
    assert.equal(program.trimIdle(), 1);
    assert.equal(program.running, false);
    await assert.rejects(program.ask("nothing", {}), /unknown memory op/);
  } finally {
    await program.close();
  }
  await assert.rejects(program.ask("tags", { names: [] }), MemoryProgramStopped);
});
