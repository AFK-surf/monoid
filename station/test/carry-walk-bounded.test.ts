// What a chat's gathering (the MoonBit program's, carry.ts / station/mb src/replica/carry.mbt) asks of the disk: what
// main's walk asked (a directory's listing, a file's lstat and hash), and for what is made again of any name only where
// a directory's own listing shows the sign of it (a `Build`, a `CACHEDIR.TAG`) and near the room's top
// (footprint-reference.ts ANY_NAME_DEPTH): an ordinary directory costs no look more than main's (drill 35's first pass of a 500 MB
// room was 9% slower). Counted by what the program itself asked of the shell (`count`, its answer's `looked`), under the
// chat's workspace; and the program's decision held to the reference's (test/carry-reference.ts) on the same tree.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { type CarriedFile, type CarryIndex, type Gathered, inProgram } from "../src/replica/carry.ts";
import { gather, linesOf } from "./carry-reference.ts";
import { Store } from "../src/store/store.ts";
import { HOME, chat, dataDir } from "./replica-fakes.ts";

type Json = any;
const skip = mbReaderBinary() === null ? "the station's MoonBit program is not built here" : false;

/// Every file a gathering's lists name.
function listedOf(g: Gathered): CarriedFile[] {
  const out: CarriedFile[] = [];
  for (const s of (JSON.parse(readFileSync(g.index, "utf8")) as CarryIndex).sessions) for (const line of linesOf(s.at)) out.push(JSON.parse(line));
  return out;
}

const put = (path: string, text = "x\n") => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, text);
};
const TAG = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n";

test("a gathering looks at the disk as main's walk did, but where a directory's listing shows what is made again of any name, near the room's top; the program and its reference take the same files", { skip }, async () => {
  const from = dataDir("walk");
  const db = join(from, "stillfail.db");
  const store = Store.open(db, join(from, "archive"));
  chat(store, from, "chat:w", null, 1);
  const ws = (store.getSession("chat:w") as Json).workspace as string;
  store.close();
  // (an ordinary room: 30 directories of 5 files)
  for (let d = 0; d < 30; d++) for (let f = 0; f < 5; f++) put(join(ws, `d${d}`, "sub", `f${f}.txt`));
  // (Xcode's derived data near the top, and the same deep; a Cargo target of another name; MoonBit's and Elixir's)
  for (const at of ["ios-dd", "a/b/c/d/dd"]) {
    put(join(ws, at, "Build", "Products", "app"));
    put(join(ws, at, "Build", "Intermediates.noindex", "o"));
  }
  put(join(ws, "rs-out", "CACHEDIR.TAG"), TAG);
  put(join(ws, "rs-out", ".rustc_info.json"), "{}");
  put(join(ws, "rs-out", "debug", "app"));
  put(join(ws, "mb", "moon.mod.json"), "{}");
  put(join(ws, "mb", "_build", "main.wasm"));
  put(join(ws, "mb", ".mooncakes", "x.mbt"));
  put(join(ws, "mb-new", "moon.mod"), 'name: "demo"\n');
  put(join(ws, "mb-new", "_build", "main.wasm"));
  put(join(ws, "mb-new", ".mooncakes", "x.mbt"));
  put(join(ws, "mb-pkg", "moon.pkg"), "import {}\n");
  put(join(ws, "mb-pkg", "_build", "pkg.o"));
  put(join(ws, "ex", "mix.exs"));
  put(join(ws, "ex", "deps", "jason", "mix.exs"));
  const g = await inProgram<Gathered & { looked: [string, string][] }>({ op: "gather", count: true, dataDir: from, db, ws: HOME, home: true, scratch: join(from, "scratch"), agent: null, keys: ["chat:w"], own: [] });
  const under = g.looked.filter(([, p]) => p.startsWith(`${ws}/`));
  const by = (k: string) => under.filter(([kind]) => kind === k).map(([, p]) => p.slice(ws.length + 1));
  // Nothing looked at on the disk but where a listing showed the sign, near the top.
  assert.deepEqual(by("fs.stat").sort(), ["ios-dd/Build/Intermediates.noindex", "ios-dd/Build/Products"], "a stat only where `Build` was listed, near the top");
  assert.deepEqual(by("fs.read"), ["rs-out/CACHEDIR.TAG"], "a tag read only where listed");
  // Main's: a listing a directory gone into, an lstat and a hash a file.
  const files = listedOf(g).filter((f) => "hash" in f).map((f) => f.path.slice(ws.length + 1));
  assert.ok(files.includes("a/b/c/d/dd/Build/Products/app"), "deep under the room, it goes as any other directory");
  for (const left of ["ios-dd/", "rs-out/", "mb/_build/", "mb/.mooncakes/", "mb-new/_build/", "mb-new/.mooncakes/", "mb-pkg/_build/", "ex/deps/"]) assert.ok(!files.some((f) => f.startsWith(left)), `${left} stays behind`);
  assert.equal(by("fs.hash").length, files.length, "a hash a file");
  assert.equal(by("fs.lstat").length, files.length, "an lstat a file, none of a directory");
  const listed = by("fs.readdir");
  assert.equal(listed.length, new Set(listed).size, "each directory listed once");
  assert.ok(listed.includes("ios-dd") && listed.includes("rs-out") && !listed.includes("ios-dd/Build") && !listed.includes("mb/_build"), "the sign's directory listed, nothing under it; one known by name not even listed");
  // The program's files as its reference's, on the same tree.
  const ref = gather(from, db, HOME, true, join(from, "scratch-ref"), null, ["chat:w"]);
  assert.deepEqual(files.sort(), listedOf(ref).filter((f) => "hash" in f).map((f) => f.path.slice(ws.length + 1)).sort(), "the program takes what its reference takes");
});
