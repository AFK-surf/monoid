// What a chat's gathering (replica/carry-worker.ts) asks of the disk: what main's walk asked (a directory's listing, an
// entry's lstat, a file opened to hash it), and for what is made again of any name only where a directory's own listing
// shows the sign of it (a `Build`, a `CACHEDIR.TAG`) and near the room's top (footprint.ts ANY_NAME_DEPTH): an ordinary
// directory costs no look more than main's (drill 35's first pass of a 500 MB room was 9% slower). Counted by kind, the
// calls of node:fs the walk makes under the chat's workspace.
import assert from "node:assert/strict";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import { test } from "node:test";
import { type CarriedFile, type CarryIndex, type Gathered, gather, linesOf } from "../src/replica/carry-worker.ts";
import { Store } from "../src/store/store.ts";
import { HOME, chat, dataDir } from "./replica-fakes.ts";

type Json = any;
const require = createRequire(import.meta.url);

/// Every file a gathering's lists name.
function listedOf(g: Gathered): CarriedFile[] {
  const out: CarriedFile[] = [];
  for (const s of (JSON.parse(readFileSync(g.index, "utf8")) as CarryIndex).sessions) for (const line of linesOf(s.at)) out.push(JSON.parse(line));
  return out;
}

/// The calls of node:fs's synchronous functions from now on (`stop`), each with its path.
function watch(kinds: string[]) {
  const fs = require("node:fs") as Record<string, Json>;
  const was = new Map(kinds.map((k) => [k, fs[k]]));
  const calls: [string, string][] = [];
  for (const k of kinds) fs[k] = (path: unknown, ...rest: unknown[]) => (calls.push([k, String(path)]), was.get(k)(path, ...rest));
  syncBuiltinESMExports();
  return {
    calls,
    stop: () => {
      for (const k of kinds) fs[k] = was.get(k);
      syncBuiltinESMExports();
    },
  };
}

const put = (path: string, text = "x\n") => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, text);
};
const TAG = "Signature: 8a477f597d28d172789f06886806bc55\n# This file is a cache directory tag created by cargo.\n";

test("a gathering looks at the disk as main's walk did, but where a directory's listing shows what is made again of any name, near the room's top", () => {
  const from = dataDir("walk");
  const db = join(from, "stillfail.db");
  const store = Store.open(db, join(from, "archive"));
  chat(store, from, "chat:w", null, 1);
  const ws = (store.getSession("chat:w") as Json).workspace as string;
  store.close();
  // (an ordinary room: 30 directories of 5 files)
  for (let d = 0; d < 30; d++) for (let f = 0; f < 5; f++) put(join(ws, `d${d}`, `sub`, `f${f}.txt`));
  // (Xcode's derived data near the top, and the same deep; a Cargo target of another name)
  for (const at of ["ios-dd", "a/b/c/d/dd"]) {
    put(join(ws, at, "Build", "Products", "app"));
    put(join(ws, at, "Build", "Intermediates.noindex", "o"));
  }
  put(join(ws, "rs-out", "CACHEDIR.TAG"), TAG);
  put(join(ws, "rs-out", ".rustc_info.json"), "{}");
  put(join(ws, "rs-out", "debug", "app"));
  const w = watch(["readdirSync", "lstatSync", "statSync", "existsSync", "openSync", "readFileSync"]);
  const g = ((): Gathered => {
    try {
      return gather(from, db, HOME, true, join(from, "scratch"), null, ["chat:w"]);
    } finally {
      w.stop();
    }
  })();
  const under = w.calls.filter(([, p]) => p.startsWith(ws));
  const by = (k: string) => under.filter(([kind]) => kind === k).map(([, p]) => p.slice(ws.length + 1));
  // Nothing looked at on the disk but where a listing showed the sign, near the top.
  assert.deepEqual(by("statSync").sort(), ["ios-dd/Build/Intermediates.noindex", "ios-dd/Build/Products"], "a stat only where `Build` was listed, near the top");
  assert.deepEqual(by("existsSync"), ["rs-out/CACHEDIR.TAG"], "a tag looked for only where listed");
  assert.deepEqual(by("readFileSync"), [], "nothing read whole");
  // Main's: a listing a directory gone into, an lstat an entry, an open a file hashed (and the tag read).
  const files = listedOf(g).filter((f) => "hash" in f).map((f) => f.path.slice(ws.length + 1));
  assert.ok(files.includes("a/b/c/d/dd/Build/Products/app"), "deep under the room, it goes as any other directory");
  assert.ok(!files.some((f) => f.startsWith("ios-dd/") || f.startsWith("rs-out/")), "near the top, it stays behind");
  assert.equal(by("openSync").filter((p) => !p.startsWith("rs-out/")).length, files.length, "an open a file hashed");
  assert.deepEqual(by("openSync").filter((p) => p.startsWith("rs-out/")), ["rs-out/CACHEDIR.TAG"]);
  // (each directory gone into listed once: those whose listing shows the sign too, then left)
  const listed = by("readdirSync");
  assert.equal(listed.length, new Set(listed).size, "each directory listed once");
  assert.ok(listed.includes("ios-dd") && listed.includes("rs-out") && !listed.includes("ios-dd/Build"), "the sign's directory listed, nothing under it");
});
