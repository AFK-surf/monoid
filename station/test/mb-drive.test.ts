// The drive in MoonBit (station/mb src/drive: `stillfail-reader-harness --builder harness-drive`) held to the TypeScript it ports,
// src/drive/*, on the same inputs: what is pure (types, the order names are listed in, roots, names kept beside, a
// grant signed and read, CRC-32, DOS times, encodeURI, ids, which folder is protected), a drive's every operation over
// twin folders (one changed by each side; what they answered and what each folder came to compared, the folders' own
// paths aside), still.fail Helper's way to a protected folder (a fake helper, the same on both sides), a folder zipped
// (every entry, its bytes inflated), the trash, thumbnails and posters, what another station reads with a grant,
// folders watched on a clock of the test's own, and transfers run to their end in worlds of stations (a transfer
// refused where it would replace or go into its source, #6897, or where a folder's listing is cut short, #6902).
// The deflate is the program's own, not zlib's: a deflated entry is compared by what it inflates to.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHmac } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { EventEmitter } from "node:events";
import type { FSWatcher } from "node:fs";
import { crc32, inflateRawSync } from "node:zlib";
import { after, test } from "node:test";
import { mbHarnessBinary } from "./mb-harness.ts";
import { CODES, Drive, DriveError, dropFolder, rootName, rootView, rootsOf, typeOf } from "../src/drive/drive.ts";
import { type Fs, type Protected, direct, protectedPlace, protectedPlaceSoon } from "../src/drive/fs.ts";
import { covers, sign, verify } from "../src/drive/grants.ts";
import { driveForPeer, peerSource } from "../src/drive/module.ts";
import { free, shown, type Source, type Transfer, Transfers } from "../src/drive/transfers.ts";
import { toTrash } from "../src/drive/trash.ts";
import { zipFolder, TooBig, MAX_DEPTH } from "../src/drive/zip.ts";
import { idOf, kept, keep, thumbnail, wanted as imageWanted, type Codecs } from "../src/drive/thumbs.ts";
import { poster, posterPath, wanted as videoWanted } from "../src/drive/posters.ts";
import { FolderWatches } from "../src/drive/watch.ts";
import { bytesOf, withBytes } from "../src/mesh/bus.ts";
import { platform } from "../src/platform/index.ts";
import { tr } from "../src/ops/i18n.ts";
import { testClock } from "./hub-fakes.ts";
import { childGone } from "./child-gone.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `mb-drive-${what}-`)));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-drive", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  child.on("exit", (code) => { for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` })); });
  program = {
    child,
    next: (line) => new Promise((resolve) => {
      waiting.push((answer) => resolve(JSON.parse(answer)));
      child.stdin.write(`${line}\n`);
    }),
  };
  return program;
}
after(async () => {
  await childGone(program?.child);
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit answers of `c`, whole.
const ask = (c: Record<string, unknown>): Promise<any> => harness().next(JSON.stringify(c));
/// What MoonBit says of a pure case (its `ok`).
async function mb(c: Record<string, unknown>): Promise<any> {
  const answer = await ask(c);
  if ("error" in answer) throw new Error(`MoonBit: ${JSON.stringify(answer.error)}`);
  return answer.ok;
}

/// A refusal as the harness says it.
function errorOf(e: unknown): any {
  if (e instanceof DriveError) {
    const o: any = { code: e.code, message: e.message };
    if (e.have !== undefined) o.have = e.have;
    if (e.about !== undefined) o.about = e.about;
    if (e.need !== undefined) o.need = { grant: e.need.grant, top: e.need.top, window: e.need.window };
    return o;
  }
  if (e instanceof TooBig) return { code: "TooBig" };
  const err = e as NodeJS.ErrnoException;
  if (typeof err?.code === "string") return { fs: err.code, message: err.message };
  return { other: String((e as Error)?.message ?? e) };
}

/// The same paths on both sides: each twin's base said `<base>`.
function same(v: unknown, bases: string[]): unknown {
  let s = JSON.stringify(v);
  for (const b of bases) s = s.split(b).join("<base>");
  for (const b of bases) s = s.split(join(b, "..")).join("<up>");
  // A grant names its folder, and so is signed apart on each side.
  s = s.replace(/(\\?"grant\\?":\\?")[A-Za-z0-9_-]{40,}\.[A-Za-z0-9_-]+/g, "$1<grant>");
  return JSON.parse(s);
}

/// A folder as it is: each entry by its path, a folder `/`, a link its target, a file its bytes (base64).
function tree(dir: string, base = dir): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at).sort()) {
      const full = join(at, name);
      const rel = full.slice(base.length + 1);
      const s = lstatSync(full);
      if (s.isSymbolicLink()) out[rel] = `link:${readlinkSync(full).split(base).join("<base>")}`;
      else if (s.isDirectory()) {
        out[rel] = "/";
        walk(full);
      }
      // (a trash's info names where its file was, as words: put as words, base64 aligns them by threes)
      else if (rel.endsWith(".trashinfo")) out[rel] = readFileSync(full, "utf8").split(encodeURI(base)).join("<base>").split(base).join("<base>");
      else out[rel] = readFileSync(full).toString("base64").split(Buffer.from(base).toString("base64")).join("<base>");
    }
  };
  walk(dir);
  return out;
}

/// What a trash note says, its folder's path aside.
const T0 = Date.UTC(2026, 3, 5, 12, 0, 0) / 1000;

/// A world of the drive's: a home with a root pinned (`Season 1` and numbered episodes, notes, the station's data in
/// it, a link out and one in, a folder of uploads left long ago, git repositories), Documents as macOS protects it,
/// everything's time fixed. `twin` makes two the same.
function world(name: string) {
  const base = join(fresh(name), "home");
  mkdirSync(base);
  const root = join(base, "root");
  const data = join(root, ".stillfail");
  const w = (p: string, text: string | Buffer) => {
    mkdirSync(join(p, ".."), { recursive: true });
    writeFileSync(p, text);
  };
  w(join(data, "key"), "secret");
  w(join(root, "Season 1", "E10.mp4"), "ten");
  w(join(root, "Season 1", "E2.mp4"), "two");
  w(join(root, "Season 1", "e1.mp4"), "one");
  w(join(root, "Season 1", "Épisode.ogv"), "ogv");
  w(join(root, "notes.md"), "# hello\n");
  w(join(root, "data.json"), "{}");
  w(join(root, "big.bin"), Buffer.from(Array.from({ length: 300 * 1024 }, (_, i) => (i * 7) % 256)));
  w(join(root, "up", ".stillfail-up-old.part"), "old part");
  w(join(root, "up", ".stillfail-up-new.part"), "new part");
  w(join(root, "up", "kept.txt"), "kept");
  w(join(base, "outside.txt"), "out");
  w(join(base, "Documents", "secret.txt"), "doc");
  w(join(base, "Documents", "inner", "deep.txt"), "deep");
  w(join(base, "repos", "one", ".git", "HEAD"), "ref");
  w(join(base, "repos", "two", ".git"), "gitdir: elsewhere");
  w(join(base, "repos", "plain", "x"), "x");
  mkdirSync(join(base, "repos", ".hidden"));
  mkdirSync(join(base, "Music"));
  const text = Array.from({ length: 2000 }, (_, i) => `line ${i % 13} of the zip's text\n`).join("");
  w(join(root, "folder", "a.txt"), text);
  w(join(root, "folder", "sub", "b.bin"), Buffer.from(Array.from({ length: 64 }, (_, i) => (i * 97 + 13) % 256)));
  w(join(root, "folder", "sub", "empty"), "");
  w(join(root, "folder", "zz.txt"), "z");
  symlinkSync(join(base, "outside.txt"), join(root, "out-link"));
  symlinkSync(join(root, "notes.md"), join(root, "in-link"));
  symlinkSync(join(base, "outside.txt"), join(root, "folder", "link"));
  const fix = (at: string) => {
    for (const name of readdirSync(at)) {
      const full = join(at, name);
      if (lstatSync(full).isSymbolicLink()) continue;
      if (lstatSync(full).isDirectory()) fix(full);
      const old = name === ".stillfail-up-old.part" ? T0 - 3 * 86400 : T0;
      utimesSync(full, old, old);
    }
  };
  fix(base);
  utimesSync(base, T0, T0);
  const config = { drive: { roots: [root], workspaces: { joined: [join(base, "repos"), "relative", 5] } } };
  return { base, root, data, config };
}

/// A drive of a world as both sides make it: its config, what is protected, its home and clock, and, with `grants`, a
/// fake still.fail Helper that keeps them.
function specOf(wd: ReturnType<typeof world>, over: Record<string, unknown> = {}) {
  return { config: wd.config, protect: [wd.data], home: wd.base, now: T0 * 1000 + 1000, mounts: MOUNTS, ...over };
}

let MOUNTS: string[] = [];

type Log = { asked: unknown[]; checked: unknown[] };

const grantOfTop = (top: string) => {
  const n = top.split("/").at(-1)!.toLowerCase();
  return n === "documents" || n === "desktop" || n === "downloads" ? n : "removable";
};

/// The fake helper of harness.mbt `fake_helper`: the station's own calls after the helper's checks.
function fakeHelper(grants: Record<string, string>, home: string, log: Log): Protected {
  return {
    fs: ({ roots, protect }) => {
      const within = (p: string, d: string) => platform.paths.within(p, d);
      const check = (p: string) => {
        if (!roots.some((r) => within(p, r))) throw Object.assign(new Error("out of the roots"), { code: "outside" });
        if (protect.some((x) => within(p, x))) throw Object.assign(new Error("the station's own"), { code: "protected" });
        const place = protectedPlace(p, home, MOUNTS);
        if (place?.helper && grants[place.top] !== "granted") throw Object.assign(new Error("no grant"), { code: "grant", grant: grantOfTop(place.top), top: place.top });
      };
      const fs: Fs = {
        helper: true,
        list: async (p, most) => (check(p), direct.list(p, most)),
        names: async (p) => (check(p), direct.names(p)),
        stat: async (p) => (check(p), direct.stat(p)),
        lstat: async (p) => (check(p), direct.lstat(p)),
        real: async (p) => (check(p), direct.real(p)),
        read: async (p, o, l) => (check(p), direct.read(p, o, l)),
        readAll: async (p) => (check(p), direct.readAll(p)),
        copyTo: async (p, to) => (check(p), direct.copyTo(p, to)),
        write: async (p, wr) => (check(p), direct.write(p, wr)),
        rename: async (a, b) => (check(a), check(b), direct.rename(a, b)),
        mkdir: async (p, r) => (check(p), direct.mkdir(p, r)),
        remove: async (p) => (check(p), direct.remove(p)),
        trash: async (p, now, h) => (check(p), direct.trash(p, now, h)),
        unlink: async (p) => (check(p), direct.unlink(p)),
      };
      return fs;
    },
    known: (top) => (grants[top] === undefined ? undefined : { grant: grantOfTop(top) as any, state: grants[top] as any }),
    check: (tops) => void log.checked.push(tops),
    ask: async (grant, top) => (log.asked.push([grant, top]), "up"),
  };
}

function tsDrive(spec: any, log: Log): Drive {
  const files = spec.helper ? fakeHelper(spec.helper.grants ?? {}, spec.home, log) : null;
  return new Drive({ config: () => spec.config, protect: () => spec.protect, home: spec.home, ...(spec.now !== undefined ? { now: () => spec.now } : {}), files });
}

/// What the TypeScript answers of a drive case, as the harness says it.
async function tsDriveCase(c: any): Promise<any> {
  const log: Log = { asked: [], checked: [] };
  const base = tsDrive(c.drive, log);
  const d = c.scoped ? base.scoped(c.scoped) : base;
  const { root = "", path = "", anywhere = false } = c;
  let out: any;
  try {
    let ok: any;
    switch (c.op) {
      case "roots": ok = await d.roots(); break;
      case "rootView": ok = await d.rootView(path); break;
      case "place": {
        const p = await d.place(root, path, anywhere);
        ok = { root: p.root, top: p.top, asked: p.asked, found: p.found, entry: p.entry, parts: p.parts, helper: p.fs.helper, scope: p.scope };
        break;
      }
      case "locate": ok = await d.locate(root, path, anywhere); break;
      case "list": ok = await d.list(root, path, anywhere); break;
      case "stat": ok = await d.stat(root, path, anywhere); break;
      case "read": {
        const r = await d.read(root, path, c.offset, c.length, anywhere);
        ok = { bytes: r.bytes.toString("base64"), total: r.total, mtime: r.mtime, type: r.type };
        break;
      }
      case "file": {
        const f = await d.file(root, path, anywhere);
        if (f.copy && c.copyTo) await f.copy(c.copyTo);
        ok = { found: f.found, name: f.name, size: f.size, mtime: f.mtime, copy: f.copy !== null };
        break;
      }
      case "upload": {
        const u = await d.upload(root, path, c.id, c.offset, c.total, Buffer.from(c.body, "base64"), c.replace ?? false, anywhere);
        ok = { have: u.have, entry: u.entry };
        break;
      }
      case "mkdir": ok = await d.mkdir(root, path, anywhere); break;
      case "rename": ok = await d.rename(root, path, c.to, anywhere); break;
      case "remove": await d.remove(root, path, anywhere, c.permanent ?? false); ok = null; break;
      case "stage": ok = await d.stage(root, path, (n) => ({ safe: n, path: join(c.into, n) }), c.most, anywhere, c.zip ?? false); break;
      case "zip": ok = await d.zip(root, path, c.most, anywhere); break;
      case "folderToWatch": ok = await d.folderToWatch(root, path, anywhere); break;
      case "folders": ok = await d.folders(path, c.home, c.lang); break;
      case "checkRoot": ok = await d.checkRoot(path); break;
      default: throw new Error(`no op ${c.op}`);
    }
    out = { ok: JSON.parse(JSON.stringify(ok ?? null)) };
  } catch (e) {
    out = { error: errorOf(e) };
  }
  return { ...out, asked: log.asked, checked: log.checked };
}

/// One case given both sides on one world (what only reads).
async function bothRead(c: any, bases: string[]) {
  const [want, got] = [await tsDriveCase(c), await ask({ kind: "drive", ...c })];
  assert.deepEqual(same(got, bases), same(want, bases), `${c.op} ${c.root ?? ""} ${c.path ?? ""}`);
  return want;
}

test("what is pure: types, the listing's order, roots, names kept beside, grants, CRC-32, DOS times, ids", { skip }, async () => {
  MOUNTS = await platform.mountsSoon();
  const names = ["a.PNG", "b.jpeg", "clip.3gp", "x.ogv", "song.opus", "doc.PDF", ".hidden", "noext", "arch.zip", "sub.srt", "s.ass", "t.vtt", "page.htm", "v.ts", "a.b.c.md"];
  assert.deepEqual(await mb({ fn: "typeOf", names }), names.map(typeOf));
  for (const raw of [{ drive: { roots: ["/a/../b", "rel", 3, "/c/./d/"] } }, { drive: { workspaces: { w: ["/x", "/y/"] } } }, null, { drive: { roots: "x" } }])
    for (const workspace of [undefined, "w"]) assert.deepEqual(await mb({ fn: "rootsOf", raw, ...(workspace ? { workspace } : {}) }), rootsOf(raw, workspace ?? null));
  const paths = ["/", "/a/b", "/a/b/", "/Volumes/Disk"];
  assert.deepEqual(await mb({ fn: "rootName", paths }), paths.map(rootName));
  const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });
  const words = ["E10.mp4", "e1.mp4", "E2.mp4", "Épisode", "episode", "a", "B", "_x", "-y", "10", "9", "09", " z", "a b", "a-b", "a_b", "ä", "Ø", "z", "file02", "file2", "Season 1", "Season 10", "Season 2", "x.txt", "x 2.txt", "(1)", "[a]", "a.b", "ab"];
  const pairs = words.flatMap((a) => words.map((b) => [a, b]));
  const sign_ = (n: number) => (n < 0 ? -1 : n > 0 ? 1 : 0);
  assert.deepEqual(await mb({ fn: "collate", pairs }), pairs.map(([a, b]) => sign_(collator.compare(a!, b!))));
  assert.deepEqual(await mb({ fn: "sort", names: words }), [...words].sort(collator.compare));
  for (const [name, dir, taken] of [["a.txt", false, ["a 2.txt"]], ["b", true, []], ["c.d", true, []], [".env", false, []], ["x.tar.gz", false, ["x.tar 2.gz"]]] as const)
    assert.equal(await mb({ fn: "free", name, dir, taken }), free(name, dir, (n) => (taken as readonly string[]).includes(n)));
  const t = { by: "a@x", workspace: "ws", home: true, anywhere: true, move: false, from: { station: null, root: "/r", path: "", names: ["a"] }, to: { root: "/r", path: "d" }, conflicts: {}, id: "i", state: "copying", items: [{ path: "a", dir: true, size: 0 }, { path: "a/b", dir: false, size: 3 }], done: 1, at: 0, total: 3, copied: 0, placed: { a: "a" }, createdAt: 5 };
  assert.deepEqual(await mb({ fn: "shown", t }), shown(t as Transfer));
  assert.deepEqual(await mb({ fn: "shown", t: { ...t, state: "done", done: 2 } }), shown({ ...t, state: "done", done: 2 } as Transfer));
  const key = Buffer.alloc(32, 7);
  const g = { v: 1 as const, workspace: "ws", home: true, by: "a@x", anywhere: false, root: "/r", path: "p", names: ["a", "b c"], move: true, expires: 2_000_000 };
  const signed = sign(key, g);
  assert.equal(await mb({ fn: "sign", key: key.toString("hex"), grant: g }), signed);
  const checks = [
    { grant: signed, workspace: "ws", now: 1_000_000 }, { grant: signed, workspace: null, now: 1_000_000 }, { grant: signed, workspace: "other", now: 1 },
    { grant: signed, workspace: "ws", now: 3_000_000 }, { grant: `${signed}x`, workspace: "ws", now: 1 }, { grant: "nope", workspace: "ws", now: 1 },
    { grant: 5, workspace: "ws", now: 1 }, { grant: sign(Buffer.alloc(32, 8), g), workspace: "ws", now: 1 }, { grant: sign(key, { ...g, v: 2 } as any), workspace: "ws", now: 1 },
  ];
  for (const ch of checks) {
    let want: any;
    try { want = verify(key, ch.grant, ch.workspace, ch.now); } catch (e) { want = { refused: errorOf(e) }; }
    assert.deepEqual(await mb({ fn: "verify", key: key.toString("hex"), grant: ch.grant, ...(ch.workspace !== null ? { workspace: ch.workspace } : {}), now: ch.now }), want);
  }
  const cpaths = ["a", "a/x", "b c/y", "a/../b", "a//x", "c", "", "./a"];
  assert.deepEqual(await mb({ fn: "covers", grant: g, paths: cpaths }), cpaths.map((p) => covers(g, p)));
  const texts = ["/a b/ü#?.txt", "/x/[1]&%=;", "/日本/é 2.md"];
  assert.deepEqual(await mb({ fn: "encodeURI", texts }), texts.map((x) => encodeURI(x)));
  const times = [0, Date.UTC(1990, 5, 7, 13, 45, 31), Date.UTC(2026, 0, 1, 0, 0, 1), Date.UTC(2200, 0, 1), Date.UTC(2026, 6, 4, 23, 59, 59, 900)];
  const dos = (ms: number) => {
    const first = new Date(1980, 0, 1).getTime();
    const last = new Date(2108, 0, 1).getTime() - 1;
    const d = new Date(Math.max(first, Math.min(ms, last)));
    return [(d.getHours() << 11) | (d.getMinutes() << 5) | Math.floor(d.getSeconds() / 2), ((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()];
  };
  assert.deepEqual(await mb({ fn: "dos", times }), times.map(dos));
  const pieces = [Buffer.from("12345"), Buffer.from("6789"), Buffer.from(Array.from({ length: 999 }, (_, i) => i % 256))];
  assert.equal(await mb({ fn: "crc32", pieces: pieces.map((p) => p.toString("base64")) }), pieces.reduce((c, p) => crc32(p, c), 0) >>> 0);
  const ipaths = ["/a/b.png", "/日本.jpg", ""];
  assert.deepEqual(await mb({ fn: "idOf", paths: ipaths }), ipaths.map(idOf));
  const wnames = ["a.PNG", "b.gif", "c.webp", "d.MOV", "e.mkv", "f.jpeg", "g.mp3", "h.ogv"];
  assert.deepEqual(await mb({ fn: "wanted", names: wnames }), wnames.map((n) => [imageWanted(n), videoWanted(n)]));
  assert.equal(await mb({ fn: "posterPath", video: "/v/x.mp4", thumbs: "/t" }), posterPath("/v/x.mp4", "/t"));
  const home = "/Users/u";
  const mounts = ["/Users/u/OrbStack", "/Volumes/Data", "/mnt/nfs"];
  for (const path of ["/Users/u/Documents", "/Users/u/documents/x", "/Users/u/Desktop/a", "/Users/u/Downloads", "/Users/u/Library/Mobile Documents/x", "/Users/u/Library/CloudStorage", "/Users/u/OrbStack/m", "/mnt/nfs/a", "/Volumes/NoSuchDisk/x", "/Users/u/Doc", "/elsewhere"]) {
    assert.deepEqual(await mb({ fn: "protectedPlace", path, home, mounts }), await protectedPlaceSoon(path, home, mounts), path);
  }
  const parts = [".stillfail-up-abc.part", ".stillfail-up-a b.part", ".stillfail-up-.part", "x.part", `.stillfail-up-${"a".repeat(64)}.part`, `.stillfail-up-${"a".repeat(65)}.part`];
  assert.deepEqual(await mb({ fn: "isPart", names: parts }), parts.map((n) => /^\.stillfail-up-[A-Za-z0-9_-]{1,64}\.part$/.test(n)));
  const codes = Object.keys(CODES);
  assert.deepEqual(await mb({ fn: "codeStatus", codes }), codes.map((k) => CODES[k as keyof typeof CODES]));
  const places = ["home", "Desktop", "Documents", "Downloads", "Movies", "Videos", "Music", "Pictures"];
  for (const lang of ["zh", "en"] as const) assert.deepEqual(await mb({ fn: "placeWord", lang, names: places }), places.map((n) => tr(lang, `station.drive.place.${n}`)));
  const wd = world("pure");
  for (const path of [wd.root, join(wd.root, "notes.md"), join(wd.base, "nothing"), wd.base]) assert.deepEqual(await mb({ fn: "rootView", path }), await rootView(path));
  assert.equal(await mb({ fn: "dropFolder", home: wd.base }), await dropFolder(wd.base));
  mkdirSync(join(wd.base, "Downloads"));
  assert.equal(await mb({ fn: "dropFolder", home: wd.base }), await dropFolder(wd.base));
  assert.deepEqual(await mb({ fn: "disks", home: wd.base }), (await platform.disks(wd.base)).map((d) => [d.name, d.path]));
  const hdata = Buffer.from("what do ya want for nothing?");
  assert.equal(await mb({ fn: "hmac", key: Buffer.from("Jefe").toString("hex"), data: hdata.toString("base64") }), createHmac("sha256", "Jefe").update(hdata).digest("hex"));
  for (const b of [Buffer.alloc(0), Buffer.from([1]), Buffer.from([1, 2]), Buffer.from([251, 255, 0])])
    assert.deepEqual(await mb({ fn: "base64", data: b.toString("base64") }), [b.toString("base64"), b.toString("base64url")]);
  const values = [0, 1.5, -3, 2 ** 53, 2 ** 53 - 1, -(2 ** 53 - 1)];
  assert.deepEqual(await mb({ fn: "safeInteger", values }), values.map(Number.isSafeInteger));
});

test("a drive's reads: listings, a path kept in its root, a part read, the picker's folders, a root checked", { skip }, async () => {
  MOUNTS = await platform.mountsSoon();
  const wd = world("reads");
  const drive = specOf(wd);
  const bases = [wd.base];
  for (const anywhere of [false, true]) {
    for (const path of ["", "Season 1", "folder", "folder/sub", "up", "..", "a/../..", ".stillfail", "notes.md", "nothing", "out-link", "in-link", "./Season 1/"])
      await bothRead({ drive, op: "list", root: wd.root, path, anywhere }, bases);
    for (const [root, path] of [[wd.root, ""], [wd.root, "notes.md"], [wd.root, "Season 1/E2.mp4"], [wd.root, "out-link"], [wd.root, "in-link"], [wd.root, "missing"], [wd.base, "outside.txt"], ["/nowhere", ""], [`${wd.root}/`, "notes.md"], [join(wd.root, "folder"), ""]]) {
      for (const op of ["stat", "place", "locate", "folderToWatch"]) await bothRead({ drive, op, root, path, anywhere }, bases);
    }
  }
  for (const [path, offset, length] of [["big.bin", 0, 1000], ["big.bin", 300 * 1024 - 10, 100], ["big.bin", 999_999, 10], ["notes.md", 2, 3], ["Season 1", 0, 10], ["notes.md", -1, 3], ["notes.md", 0, 9 * 1024 * 1024], ["notes.md", 1.5, 3]] as const)
    await bothRead({ drive, op: "read", root: wd.root, path, offset, length, anywhere: false }, bases);
  await bothRead({ drive, op: "file", root: wd.root, path: "notes.md" }, bases);
  await bothRead({ drive, op: "file", root: wd.root, path: "Season 1" }, bases);
  await bothRead({ drive, op: "roots" }, bases);
  for (const path of [wd.root, join(wd.base, "nothing"), join(wd.root, "notes.md")]) await bothRead({ drive, op: "rootView", path }, bases);
  for (const lang of ["zh", "en"]) for (const path of ["", join(wd.base, "repos"), wd.base, join(wd.base, "repos", "one"), "relative", join(wd.base, "nothing"), wd.root])
    await bothRead({ drive, op: "folders", path, home: wd.base, lang }, bases);
  for (const path of [wd.root, "relative", join(wd.base, "nothing"), join(wd.root, "notes.md"), wd.data, join(wd.data, ".."), `${wd.base}/repos/../root`])
    await bothRead({ drive, op: "checkRoot", path }, bases);
  // A workspace the station joined: its own folders pinned.
  for (const op of ["list", "stat"]) for (const [root, path] of [[join(wd.base, "repos"), ""], [wd.root, ""]]) await bothRead({ drive, op, root, path, anywhere: false, scoped: "joined" }, bases);
  await bothRead({ drive, op: "roots", scoped: "joined" }, bases);
});

test("a drive's changes over twin folders: uploads in parts, folders made, renamed, removed to the trash, staged, zipped", { skip }, async () => {
  MOUNTS = await platform.mountsSoon();
  const a = world("changes-ts");
  const b = world("changes-mb");
  const bases = [a.base, b.base];
  const into = (wd: ReturnType<typeof world>) => {
    const dir = join(wd.base, "..", "staged");
    mkdirSync(dir, { recursive: true });
    return dir;
  };
  const steps: any[] = [
    { op: "upload", path: "new.txt", id: "u1", offset: 0, total: 6, body: Buffer.from("abc").toString("base64") },
    { op: "upload", path: "new.txt", id: "u1", offset: 4, total: 6, body: Buffer.from("ef").toString("base64") },
    { op: "upload", path: "new.txt", id: "u2", offset: 3, total: 6, body: Buffer.from("def").toString("base64") },
    { op: "upload", path: "new.txt", id: "u1", offset: 3, total: 6, body: Buffer.from("def").toString("base64") },
    { op: "upload", path: "new.txt", id: "u3", offset: 0, total: 1, body: Buffer.from("x").toString("base64") },
    { op: "upload", path: "new.txt", id: "u3", offset: 0, total: 1, body: Buffer.from("x").toString("base64"), replace: true },
    { op: "upload", path: "Season 1", id: "u4", offset: 0, total: 1, body: Buffer.from("x").toString("base64"), replace: true },
    { op: "upload", path: "up/fresh.txt", id: "u5", offset: 0, total: 2, body: Buffer.from("hi").toString("base64") },
    { op: "upload", path: "", id: "u6", offset: 0, total: 1, body: Buffer.from("x").toString("base64") },
    { op: "upload", path: "bad.txt", id: "no way", offset: 0, total: 1, body: Buffer.from("x").toString("base64") },
    { op: "upload", path: "bad.txt", id: "u7", offset: 0, total: 1, body: Buffer.from("xx").toString("base64") },
    { op: "mkdir", path: "made/deeper" },
    { op: "mkdir", path: "made" },
    { op: "mkdir", path: "" },
    { op: "rename", path: "made", to: "renamed/again" },
    { op: "rename", path: "renamed", to: "renamed/again/inner" },
    { op: "rename", path: "notes.md", to: "data.json" },
    { op: "rename", path: "notes.md", to: "NOTES.md" },
    { op: "rename", path: "", to: "x" },
    { op: "remove", path: "NOTES.md" },
    { op: "remove", path: "new.txt" },
    { op: "remove", path: "in-link" },
    { op: "remove", path: "renamed", permanent: true },
    { op: "remove", path: "" },
    { op: "remove", path: "missing" },
    { op: "stage", path: "data.json", most: 100, into: "<into>" },
    { op: "stage", path: "big.bin", most: 100, into: "<into>" },
    { op: "stage", path: "folder", most: 1_000_000, into: "<into>" },
    { op: "stage", path: "folder", most: 1_000_000, into: "<into>", zip: true },
    { op: "stage", path: "folder", most: 100, into: "<into>", zip: true },
    { op: "zip", path: "notes.md", most: 1_000_000 },
  ];
  for (const s of steps) {
    const ca = { drive: specOf(a), root: a.root, anywhere: false, ...s, ...(s.into ? { into: into(a) } : {}) };
    const cb = { drive: specOf(b), root: b.root, anywhere: false, ...s, ...(s.into ? { into: into(b) } : {}) };
    const want = await tsDriveCase(ca);
    const got = await ask({ kind: "drive", ...cb });
    // (a zip's size is its deflate's, which is the program's own: its entries are compared below)
    const zipped = s.zip === true && want.ok;
    const strip = (v: any) => JSON.parse(JSON.stringify(v), (k, x) => (k === "mtime" || (zipped && k === "size") ? "<mtime>" : x));
    assert.deepEqual(strip(same(got, bases)), strip(same(want, bases)), JSON.stringify(s));
  }
  // What each folder came to, and the trash, the same (a trash note's time is the drive's clock).
  const strip = (t: Record<string, string>) => Object.fromEntries(Object.entries(t).filter(([k]) => !k.includes("staged")));
  assert.deepEqual(strip(tree(b.base)), strip(tree(a.base)));
  // A zip to download: made in a folder of its own, its entries as the TypeScript's.
  const want = await tsDriveCase({ drive: specOf(a), op: "zip", root: a.root, path: "folder", most: 10_000_000 });
  const got = await ask({ kind: "drive", drive: specOf(b), op: "zip", root: b.root, path: "folder", most: 10_000_000 });
  assert.deepEqual(entries(join(got.ok.root, got.ok.path)), entries(join(want.ok.root, want.ok.path)));
  assert.equal(got.ok.name, want.ok.name);
});

/// A zip's entries as they are: each name, method, CRC, sizes, DOS time, attributes, and its bytes (inflated where
/// deflated), its structure checked as it is read (headers where the central directory says, the end where it is).
function entries(path: string) {
  const z = readFileSync(path);
  const end = z.length - 22;
  assert.equal(z.readUInt32LE(end), 0x06054b50);
  const count = z.readUInt16LE(end + 10);
  let at = z.readUInt32LE(end + 16);
  assert.equal(z.readUInt32LE(end + 12), end - at);
  const out: any[] = [];
  for (let i = 0; i < count; i++) {
    assert.equal(z.readUInt32LE(at), 0x02014b50);
    const n = z.readUInt16LE(at + 28);
    const name = z.subarray(at + 46, at + 46 + n).toString("utf8");
    const method = z.readUInt16LE(at + 10);
    const packed = z.readUInt32LE(at + 20);
    const size = z.readUInt32LE(at + 24);
    const local = z.readUInt32LE(at + 42);
    assert.equal(z.readUInt32LE(local), 0x04034b50);
    assert.equal(z.readUInt32LE(local + 14), z.readUInt32LE(at + 16), `${name}: its CRC in both headers`);
    const start = local + 30 + z.readUInt16LE(local + 26);
    const raw = z.subarray(start, start + packed);
    const bytes = method === 8 ? inflateRawSync(raw) : raw;
    assert.equal(bytes.length, size);
    assert.equal(crc32(bytes) >>> 0, z.readUInt32LE(at + 16));
    out.push({ name, method, crc: z.readUInt32LE(at + 16), size, stored: method === 0 ? raw.toString("base64") : null, bytes: bytes.toString("base64"), time: z.readUInt16LE(at + 12), date: z.readUInt16LE(at + 14), version: z.readUInt16LE(at + 4), flags: z.readUInt16LE(at + 8), attrs: z.readUInt32LE(at + 38) });
    at += 46 + n;
  }
  return out;
}

test("zipFolder: every entry as the TypeScript's, deflated where it shrinks, past `most` or MAX_DEPTH too big", { skip }, async () => {
  const wd = world("zip");
  const dir = join(wd.root, "folder");
  for (const skipNames of [[], ["zz.txt", "sub"]]) {
    const to = join(wd.base, `ts-${skipNames.length}.zip`);
    const mto = join(wd.base, `mb-${skipNames.length}.zip`);
    const size = await zipFolder(dir, to, 10_000_000, async (_p, n) => skipNames.includes(n), direct);
    const got = await ask({ kind: "zip", dir, to: mto, most: 10_000_000, skip: skipNames });
    assert.deepEqual(entries(mto), entries(to));
    assert.equal(typeof got.ok, "number");
    assert.equal(got.ok, readFileSync(mto).length);
    assert.equal(size, readFileSync(to).length);
  }
  // Past `most`: the same refusal, as the bytes come.
  for (const most of [10, 50_000]) {
    let want: any;
    try { await zipFolder(dir, join(wd.base, `ts-most-${most}.zip`), most, async () => false, direct); want = "ok"; } catch (e) { want = errorOf(e); }
    const got = await ask({ kind: "zip", dir, to: join(wd.base, `mb-most-${most}.zip`), most, skip: [] });
    assert.deepEqual(got.error ?? "ok", want);
  }
  let deep = join(wd.base, "deep");
  for (let i = 0; i <= MAX_DEPTH + 1; i++) deep = join(deep, "d");
  mkdirSync(deep, { recursive: true });
  let want: any;
  try { await zipFolder(join(wd.base, "deep"), join(wd.base, "ts-deep.zip"), 1e9, async () => false, direct); want = "ok"; } catch (e) { want = errorOf(e); }
  assert.deepEqual((await ask({ kind: "zip", dir: join(wd.base, "deep"), to: join(wd.base, "mb-deep.zip"), most: 1e9, skip: [] })).error, want);
  // A zip there already: not replaced.
  const there = await ask({ kind: "zip", dir, to: join(wd.base, "ts-0.zip"), most: 1e9, skip: [] });
  let tsThere: any;
  try { await zipFolder(dir, join(wd.base, "ts-0.zip"), 1e9, async () => false, direct); } catch (e) { tsThere = errorOf(e); }
  assert.equal(there.error.fs, tsThere.fs);
});

test("the trash: Finder's and the freedesktop's, a name there given a number, another disk's refused as the TypeScript's", { skip }, async () => {
  for (const kind of ["finder", "freedesktop", null] as const) {
    const roots = [fresh(`trash-ts-${kind}`), fresh(`trash-mb-${kind}`)];
    const answers: any[] = [];
    for (const [i, base] of roots.entries()) {
      const got: any[] = [];
      for (const name of ["f.txt", "f.txt", "folder", "noext", "f.txt"]) {
        const entry = join(base, name);
        if (name === "folder") mkdirSync(entry, { recursive: true }); else writeFileSync(entry, name);
        if (i === 0) {
          try { got.push({ ok: await toTrash(entry, kind, T0 * 1000, base) }); } catch (e) { got.push({ error: errorOf(e) }); }
        } else got.push(await ask({ kind: "trash", entry, ...(kind ? { trash: kind } : {}), now: T0 * 1000, home: base }));
      }
      answers.push(same(got, roots));
    }
    assert.deepEqual(answers[1], answers[0]);
    assert.deepEqual(tree(roots[1]!), tree(roots[0]!));
  }
});

test("thumbnails and posters: which files, kept ones taken or made again, a message's images given their hash", { skip }, async () => {
  const base = fresh("thumbs");
  const thumbs = join(base, "thumbs");
  mkdirSync(thumbs);
  const codecs: Codecs = {
    thumbnail: async (image: string, dir: string) => {
      if (!imageWanted(image)) return null as any;
      const path = join(dir, `${idOf(image)}.jpg`);
      writeFileSync(path, `thumb of ${image}`);
      return { path, type: "image/jpeg" };
    },
    thumbhash: async (image: string) => {
      if (image.split("/").at(-1)!.startsWith("bad")) throw new Error("not an image");
      return { hash: `hash:${image.split("/").at(-1)}`, width: 4, height: 3 };
    },
  } as any;
  const img = join(base, "a.png");
  writeFileSync(img, "png");
  writeFileSync(join(thumbs, `${idOf(join(base, "old.png"))}.png`), "old");
  utimesSync(join(thumbs, `${idOf(join(base, "old.png"))}.png`), T0, T0);
  const kase = async (c: any, want: any) => assert.deepEqual(await ask({ kind: "thumbs", thumbs, ...c }), { ok: JSON.parse(JSON.stringify(want)) }, JSON.stringify(c));
  await kase({ op: "kept", id: idOf(img) }, await kept(thumbs, idOf(img)));
  await kase({ op: "kept", id: idOf(join(base, "old.png")) }, await kept(thumbs, idOf(join(base, "old.png"))));
  await kase({ op: "thumbnail", image: img }, await thumbnail(img, thumbs, codecs));
  await kase({ op: "thumbnail", image: img, noCodecs: true }, await thumbnail(img, thumbs, null));
  await kase({ op: "kept", id: idOf(img), since: 1 }, await kept(thumbs, idOf(img), 1));
  // Made before `since`: removed (twice over: TypeScript's first, then MoonBit's of the same file made again).
  writeFileSync(join(thumbs, "x.jpg"), "x");
  utimesSync(join(thumbs, "x.jpg"), T0, T0);
  const wantGone = await kept(thumbs, "x", T0 * 1000 + 5000);
  writeFileSync(join(thumbs, "x.jpg"), "x");
  utimesSync(join(thumbs, "x.jpg"), T0, T0);
  await kase({ op: "kept", id: "x", since: T0 * 1000 + 5000 }, wantGone);
  assert.equal(existsSync(join(thumbs, "x.jpg")), false);
  const files = [{ name: "a.png", path: img, size: 3 }, { name: "bad.jpg", path: join(base, "bad.jpg"), size: 1 }, { name: "doc.pdf", path: "/x.pdf", size: 9 }];
  await kase({ op: "keep", files }, await keep(files as any, thumbs, codecs));
  await kase({ op: "keep", files: [files[2]] }, await keep([files[2]] as any, thumbs, codecs));
  await kase({ op: "keep", files, noCodecs: true }, await keep(files as any, thumbs, null));
  // A poster kept and fresh, one older than its video's time, a video not there, a folder: found without one made.
  const video = join(base, "v.mp4");
  writeFileSync(video, "video");
  writeFileSync(posterPath(video, thumbs), "jpeg");
  utimesSync(posterPath(video, thumbs), T0, T0);
  await kase({ op: "poster", video }, await poster(video, thumbs));
  await kase({ op: "poster", video, since: T0 * 1000 - 1 }, await poster(video, thumbs, T0 * 1000 - 1));
  await kase({ op: "poster", video: join(base, "none.mp4") }, await poster(join(base, "none.mp4"), thumbs));
  await kase({ op: "poster", video: base }, await poster(base, thumbs));
});

test("what another station reads with a grant: walked, a part, the rest as it is read, let go; a grant not this one's refused", { skip }, async () => {
  MOUNTS = await platform.mountsSoon();
  const a = world("peer-ts");
  const b = world("peer-mb");
  const key = Buffer.alloc(32, 7);
  const grantFor = (wd: ReturnType<typeof world>, over: Record<string, unknown> = {}) =>
    sign(key, { v: 1, workspace: "ws", home: true, by: "a@x", anywhere: false, root: wd.root, path: "", names: ["folder", "big.bin", "notes.md", "Season 1"], move: false, expires: 2_000_000, ...over } as any);
  const requests = (wd: ReturnType<typeof world>): any[] => [
    { method: "drive.walk", grant: grantFor(wd) },
    { method: "drive.walk", grant: grantFor(wd), names: ["folder", "nope", 5] },
    { method: "drive.walk", grant: grantFor(wd, { names: ["missing"] }) },
    { method: "drive.part", grant: grantFor(wd), path: "big.bin", offset: 0 },
    { method: "drive.part", grant: grantFor(wd), path: "big.bin", offset: 1000, whole: true },
    { method: "drive.part", grant: grantFor(wd), path: "notes.md", offset: 0, whole: true },
    { method: "drive.part", grant: grantFor(wd), path: "../outside.txt", offset: 0 },
    { method: "drive.part", grant: grantFor(wd), path: "big.bin", offset: -1 },
    { method: "drive.part", grant: grantFor(wd), path: "data.json", offset: 0 },
    { method: "drive.release", grant: grantFor(wd), names: ["notes.md"] },
    { method: "drive.release", grant: grantFor(wd, { move: true }), names: ["notes.md", "data.json"] },
    { method: "drive.nothing", grant: grantFor(wd) },
    { grant: grantFor(wd) },
    { method: "drive.walk", grant: grantFor(wd, { expires: 1 }) },
    { method: "drive.walk", grant: grantFor(wd, { workspace: "other" }) },
    { method: "drive.walk", grant: "forged.sig" },
    { method: "drive.walk", grant: grantFor(wd, { home: false, workspace: "ws" }) },
  ];
  const ra = requests(a);
  const rb = requests(b);
  for (let i = 0; i < ra.length; i++) {
    let want: any;
    try {
      const got = await driveForPeer(new Drive({ config: () => a.config, protect: () => [a.data], home: a.base, now: () => 1_000_000 }), key, ra[i], "ws", 1_000_000);
      const bytes = bytesOf(got);
      const o: any = { json: JSON.parse(JSON.stringify(got)) };
      if (bytes !== null) {
        const pieces: Buffer[] = [];
        for await (const p of bytes) pieces.push(p);
        o.bytes = Buffer.concat(pieces).toString("base64");
        o.pieces = pieces.map((p) => p.length);
      }
      want = { ok: o };
    } catch (e) {
      want = { error: { refused: (e as Error).message } };
    }
    const got = await ask({ kind: "peer", drive: { config: b.config, protect: [b.data], home: b.base, mounts: MOUNTS, now: 1_000_000 }, key: key.toString("hex"), request: rb[i], workspace: "ws", now: 1_000_000 });
    assert.deepEqual(same(got, [a.base, b.base]), same(want, [a.base, b.base]), JSON.stringify(ra[i].method));
  }
  assert.deepEqual(tree(b.base), tree(a.base));
});

test("folders watched on a clock of the test's own: a burst told once, kept between asks, held at most so long, let go", { skip }, async () => {
  const scripts: { held: number; kept: number; refuse?: string[]; steps: any[] }[] = [
    {
      held: 1500, kept: 5000, steps: [
        { do: "changed", dir: "/f", id: "c", tag: "first", timers: 1 },
        { do: "advance", ms: 1500 },
        { do: "changed", dir: "/f", id: "c", tag: "second", timers: 1 },
        { do: "emit", dir: "/f", ev: "change", timers: 1 },
        { do: "emit", dir: "/f", ev: "change" },
        { do: "advance", ms: 250 },
        { do: "emit", dir: "/f", ev: "change", timers: 1 },
        { do: "advance", ms: 250 },
        { do: "changed", dir: "/f", id: "c", tag: "third" },
        { do: "changed", dir: "/f", id: "other", tag: "fourth", timers: 1 },
        { do: "advance", ms: 1500 },
        { do: "advance", ms: 5000 },
      ],
    },
    {
      held: 1500, kept: 5000, refuse: ["/gone"], steps: [
        { do: "follow", dir: "/g", tag: "f1" },
        { do: "emit", dir: "/g", ev: "change", timers: 1 },
        { do: "emit", dir: "/g", ev: "change" },
        { do: "advance", ms: 250 },
        { do: "advance", ms: 60000 },
        { do: "emit", dir: "/g", ev: "error" },
        { do: "stop", tag: "f1" },
        { do: "follow", dir: "/gone", tag: "f2" },
        { do: "changed", dir: "/gone", id: "c", tag: "cannot", timers: 1 },
        { do: "advance", ms: 1500 },
        { do: "follow", dir: "/h", tag: "f3" },
        { do: "changed", dir: "/h", id: "c", tag: "both", timers: 1 },
        { do: "emit", dir: "/h", ev: "error" },
        { do: "close" },
      ],
    },
  ];
  for (const script of scripts) {
    const time = testClock();
    const emitters = new Map<string, EventEmitter>();
    let opened = 0;
    let closed = 0;
    const watches = new FolderWatches(script.held, script.kept, time.clock, (dir) => {
      if (script.refuse?.includes(dir)) throw Object.assign(new Error("no such folder"), { code: "ENOENT" });
      opened++;
      const e = new EventEmitter() as FSWatcher;
      e.close = () => void closed++;
      emitters.set(dir, e);
      return e;
    });
    const log: unknown[] = [];
    const stops = new Map<string, () => void>();
    let now = 0;
    const pending: Promise<unknown>[] = [];
    for (const s of script.steps) {
      const before = time.asked();
      if (s.do === "changed") pending.push(watches.changed(s.dir, s.id).then((yes) => log.push([s.tag, yes, now])));
      else if (s.do === "follow") {
        const stop = watches.follow(s.dir, () => log.push([s.tag, "told", now]));
        if (stop) stops.set(s.tag, stop); else log.push([s.tag, null, now]);
      } else if (s.do === "emit") emitters.get(s.dir)?.emit(s.ev === "error" ? "error" : "change", ...(s.ev === "error" ? [new Error("gone")] : ["rename", "x"]));
      else if (s.do === "advance") {
        now += s.ms;
        await time.adjust(s.ms);
        await Promise.resolve();
      } else if (s.do === "stop") stops.get(s.tag)?.();
      else if (s.do === "close") watches.close();
      // A step that sets a timer going: its fiber asleep before the clock moves.
      if (s.timers) await time.begun(before + s.timers);
      for (let i = 0; i < 4; i++) await Promise.resolve();
    }
    const got = await mb({ kind: "watch", ...script });
    const sorted = (l: any[]) => [...l].sort((x, y) => x[2] - y[2] || String(x[0]).localeCompare(String(y[0])));
    assert.deepEqual({ log: sorted(got.log), opened: got.opened, closed: got.closed }, { log: sorted(log), opened, closed });
    watches.close();
  }
});

/// A station of a transfers world: a root pinned in a home of its own, its data beside.
function station(base: string, name: string) {
  const at = join(base, name);
  const root = join(at, "root");
  const data = join(at, "data");
  mkdirSync(root, { recursive: true });
  mkdirSync(data, { recursive: true });
  return { base: at, root, data, config: { drive: { roots: [root] } } };
}

type World = { build: (s: Record<string, ReturnType<typeof station>>) => void; stations: string[]; into: string; steps: (s: Record<string, ReturnType<typeof station>>) => any[]; hooks?: (s: Record<string, ReturnType<typeof station>>) => any };

/// A world run by the TypeScript as harness.mbt `transfers_case` runs it.
async function tsTransfers(st: Record<string, ReturnType<typeof station>>, into: string, steps: any[], hooks: any, key: Buffer, now: number, dir: string) {
  const drives: Record<string, Drive> = {};
  for (const [n, s] of Object.entries(st)) drives[n] = new Drive({ config: () => s.config, protect: () => [s.data], home: s.base, now: () => now });
  const tags = new Map<string, string>();
  const ids = new Map<string, string>();
  const told: unknown[] = [];
  let away = hooks.away === true;
  const askPeer = async (station: string, request: any) => {
    const drive = drives[station];
    if (!drive) throw new Error("no such station");
    const req = JSON.parse(JSON.stringify(request));
    const got = await driveForPeer(drive, key, req, req.workspace, now);
    const bytes = bytesOf(got);
    if (!away || bytes === null) return got;
    return withBytes(got, (async function* () {
      for await (const piece of bytes) {
        yield piece.subarray(0, 256 * 1024);
        throw new Error("station is not reachable");
      }
    })());
  };
  let transfers!: Transfers;
  const remote = (t: Transfer): Source => {
    if (hooks.source === "cancelAt4") return {
      station: "A", part: 4,
      walk: async () => ({ items: [{ path: "f.txt", dir: false, size: 12 }] }),
      read: async (_p, offset) => {
        if (offset === 4) transfers.cancel("a@x", t.id);
        return { bytes: Buffer.from("abcdefghijkl".slice(offset, offset + 4)), size: 12, mtime: 5 };
      },
      release: async () => {},
    };
    if (hooks.source === "changed") {
      let mtime = 1;
      const content = () => (mtime === 1 ? "old-old-old!" : "new-new-new-new!");
      return {
        station: "A", part: 4,
        walk: async () => ({ items: [{ path: "f.txt", dir: false, size: 12 }] }),
        read: async (_p, offset) => {
          const got = { bytes: Buffer.from(content().slice(offset, offset + 4)), size: content().length, mtime };
          if (offset === 4) mtime = 2;
          return got;
        },
        release: async () => {},
      };
    }
    return peerSource(askPeer, t);
  };
  const make = () => (transfers = new Transfers({ dir, driveFor: () => drives[into]!, remote, now: () => now, changed: (t) => told.push([ids.get(t.id) ?? "<started>", t.state]) }));
  const withGrant = (spec: any) => {
    const s = JSON.parse(JSON.stringify(spec));
    if (s.from?.grant && typeof s.from.grant === "object") s.from.grant = sign(key, s.from.grant);
    return s;
  };
  const start = (tag: string, spec: any) => {
    const t = transfers.start(withGrant(spec));
    tags.set(tag, t.id);
    ids.set(t.id, tag);
  };
  make();
  const lists = new Map<Drive, Drive["list"]>();
  if (hooks.truncate) {
    const d = drives[hooks.truncate.station]!;
    const list = d.list.bind(d);
    lists.set(d, list);
    d.list = async (...args) => {
      const got = await list(...args);
      return args[1] === hooks.truncate.path ? { ...got, entries: got.entries.filter((e) => e.name !== hooks.truncate.drop), truncated: true } : got;
    };
  }
  if (hooks.cancelOnList) {
    const d = drives[into]!;
    const list = d.list.bind(d);
    lists.set(d, list);
    let held = false;
    d.list = async (...args) => {
      if (args[1] === hooks.cancelOnList.path && !held) {
        held = true;
        transfers.cancel("a@x", tags.get(hooks.cancelOnList.tag) ?? "");
        try { start(hooks.cancelOnList.thenTag, hooks.cancelOnList.then); } catch {}
      }
      return list(...args);
    };
  }
  const errors: unknown[] = [];
  for (const s of steps) {
    try {
      switch (s.do) {
        case "start": start(s.tag, s.spec); break;
        case "idle": await transfers.idle(); break;
        case "retry": transfers.retry("a@x", tags.get(s.tag) ?? ""); break;
        case "cancel": transfers.cancel("a@x", tags.get(s.tag) ?? ""); break;
        case "away": away = s.value; break;
        case "unhook": for (const [d, list] of lists) d.list = list; break;
        case "reopen": await transfers.close(); make(); break;
      }
    } catch (e) {
      errors.push([s.do, errorOf(e)]);
    }
  }
  await transfers.idle();
  const out: Record<string, unknown> = {};
  const files: Record<string, unknown> = {};
  for (const [tag, id] of tags) {
    out[tag] = JSON.parse(JSON.stringify(transfers.get(id) ?? null));
    const file = join(dir, `${id}.json`);
    files[tag] = existsSync(file) ? readFileSync(file, "utf8").split(id).join(`<${tag}>`) : null;
  }
  await transfers.close();
  return { transfers: out, told, files, errors };
}

/// A world given both sides on twin folders: what each transfer came to (its id aside), what was told, its kept file,
/// what went wrong, and each station's folders after.
async function bothTransfers(name: string, w: World) {
  const key = Buffer.alloc(32, 7);
  const now = 1_000_000;
  const sides = [fresh(`tr-${name}-ts`), fresh(`tr-${name}-mb`)];
  const worlds = sides.map((side) => {
    const st: Record<string, ReturnType<typeof station>> = {};
    for (const n of w.stations) st[n] = station(side, n);
    w.build(st);
    return st;
  });
  const dirOf = (st: Record<string, ReturnType<typeof station>>) => join(st[w.into]!.data, "drive-transfers");
  const want = await tsTransfers(worlds[0]!, w.into, w.steps(worlds[0]!), w.hooks?.(worlds[0]!) ?? {}, key, now, dirOf(worlds[0]!));
  const st = worlds[1]!;
  const got = await mb({
    kind: "transfers",
    stations: Object.fromEntries(Object.entries(st).map(([n, s]) => [n, { config: s.config, protect: [s.data], home: s.base, now }])),
    into: w.into, key: key.toString("hex"), now, dir: dirOf(st), steps: w.steps(st), hooks: w.hooks?.(st) ?? {},
  });
  const ids = (v: any) => JSON.parse(JSON.stringify(v), (k, x) => (k === "id" ? "<id>" : x));
  assert.deepEqual(same(ids(got), sides), same(ids(want), sides), name);
  // (each transfer's kept file is named by its id, and compared above)
  const kept = (t: Record<string, string>) => Object.fromEntries(Object.entries(t).filter(([k]) => !k.includes("drive-transfers/")).map(([k, v]) => [k.replace(/\.stillfail-up-[0-9a-f]{32}-/, ".stillfail-up-<id>-"), v]));
  for (const n of w.stations) assert.deepEqual(kept(tree(worlds[1]![n]!.base)), kept(tree(worlds[0]![n]!.base)), `${name}: ${n}'s folders`);
  return want;
}

const spec = (over: any) => ({ by: "a@x", workspace: "ws", home: true, anywhere: true, move: false, conflicts: {}, ...over });
const grantOf = (s: ReturnType<typeof station>, g: any) => ({ v: 1, workspace: "ws", home: true, by: "a@x", anywhere: true, root: s.root, path: "", names: [], move: false, expires: 1_000_000 + 1000, ...g });
const wr = (p: string, text: string | Buffer) => {
  mkdirSync(join(p, ".."), { recursive: true });
  writeFileSync(p, text);
};

test("transfers within a station: copied, kept beside, replaced, skipped; a name there not answered refused", { skip }, async () => {
  const done = await bothTransfers("local", {
    stations: ["one"], into: "one",
    build: ({ one }) => {
      wr(join(one!.root, "src", "a.txt"), "a");
      wr(join(one!.root, "src", "deep", "b.txt"), "bb");
      wr(join(one!.root, "src", "empty.txt"), "");
      wr(join(one!.root, "dst", "a.txt"), "old");
    },
    steps: ({ one }) => [
      { do: "start", tag: "first", spec: spec({ from: { station: null, root: one!.root, path: "src", names: ["deep", "a.txt", "empty.txt"] }, to: { root: one!.root, path: "dst" }, conflicts: { "a.txt": "keep" } }) },
      { do: "idle" },
      { do: "start", tag: "replaced", spec: spec({ from: { station: null, root: one!.root, path: "src", names: ["a.txt", "deep"] }, to: { root: one!.root, path: "dst" }, conflicts: { "a.txt": "replace", deep: "skip" } }) },
      { do: "idle" },
      { do: "start", tag: "asked", spec: spec({ from: { station: null, root: one!.root, path: "src", names: ["a.txt"] }, to: { root: one!.root, path: "dst" } }) },
      { do: "idle" },
      { do: "start", tag: "empty", spec: spec({ from: { station: null, root: one!.root, path: "src", names: [] }, to: { root: one!.root, path: "dst" } }) },
      { do: "start", tag: "moved", spec: spec({ move: true, from: { station: null, root: one!.root, path: "src", names: ["deep"] }, to: { root: one!.root, path: "" } }) },
      { do: "idle" },
    ],
  });
  assert.equal((done.transfers.first as any).state, "done");
  assert.equal((done.transfers.asked as any).state, "failed");
});

test("transfers refused where they would replace or go into their source (#6897): before anything is changed", { skip }, async () => {
  for (const alias of [false, true]) await bothTransfers(`self-replace-${alias}`, {
    stations: ["s"], into: "s",
    build: ({ s }) => {
      wr(join(s!.root, "note.txt"), "the only copy");
      if (alias) symlinkSync(s!.root, join(s!.base, "alias"), "dir");
    },
    steps: ({ s }) => [{ do: "start", tag: "t", spec: spec({ from: { station: null, root: s!.root, path: "", names: ["note.txt"] }, to: { root: alias ? join(s!.base, "alias") : s!.root, path: "" }, conflicts: { "note.txt": "replace" } }) }, { do: "idle" }],
  });
  for (const move of [false, true]) await bothTransfers(`into-self-${move}`, {
    stations: ["s"], into: "s",
    build: ({ s }) => { wr(join(s!.root, "project", "note.txt"), "original"); mkdirSync(join(s!.root, "project", "child")); },
    steps: ({ s }) => [{ do: "start", tag: "t", spec: spec({ move, from: { station: null, root: s!.root, path: "", names: ["project"] }, to: { root: s!.root, path: "project/child" } }) }, { do: "idle" }],
  });
  const parent = await bothTransfers("replace-parent", {
    stations: ["s"], into: "s",
    build: ({ s }) => {
      wr(join(s!.root, "folder", "note.txt"), "new note");
      wr(join(s!.root, "folder", "folder", "only.txt"), "only copy");
      wr(join(s!.root, "note.txt"), "old note");
    },
    steps: ({ s }) => [{ do: "start", tag: "t", spec: spec({ from: { station: null, root: s!.root, path: "folder", names: ["note.txt", "folder"] }, to: { root: s!.root, path: "" }, conflicts: { "note.txt": "replace", folder: "replace" } }) }, { do: "idle" }],
  });
  assert.match((parent.transfers.t as any).error, /replacing it would remove a source/);
  await bothTransfers("self-keep", {
    stations: ["s"], into: "s",
    build: ({ s }) => wr(join(s!.root, "note.txt"), "original"),
    steps: ({ s }) => [{ do: "start", tag: "t", spec: spec({ from: { station: null, root: s!.root, path: "", names: ["note.txt"] }, to: { root: s!.root, path: "" }, conflicts: { "note.txt": "keep" } }) }, { do: "idle" }],
  });
});

test("transfers refused where a folder's listing is cut short (#6902), none of a partial walk kept; taken up whole once it is not", { skip }, async () => {
  for (const remote of [false, true]) for (const move of [false, true]) {
    const name = `truncated-${remote}-${move}`;
    const got = await bothTransfers(name, {
      stations: remote ? ["A", "B"] : ["A"], into: remote ? "B" : "A",
      build: (s) => {
        wr(join(s.A!.root, "project", "deep", "shown.txt"), "shown");
        wr(join(s.A!.root, "project", "deep", "unseen.txt"), "unseen");
        const b = remote ? s.B! : s.A!;
        wr(join(b.root, "dst", "project", "old.txt"), "old");
      },
      hooks: () => ({ truncate: { station: "A", path: "project/deep", drop: "unseen.txt" } }),
      steps: (s) => {
        const b = remote ? s.B! : s.A!;
        return [
          { do: "start", tag: "t", spec: spec({ move, from: { station: remote ? "A" : null, ...(remote ? { grant: grantOf(s.A!, { names: ["project"], move }) } : {}), root: s.A!.root, path: "", names: ["project"] }, to: { root: b.root, path: "dst" }, conflicts: { project: "replace" } }) },
          { do: "idle" },
          { do: "unhook" },
          { do: "retry", tag: "t" },
          { do: "idle" },
        ];
      },
    });
    assert.equal((got.transfers.t as any).state, "done", name);
    assert.ok((got.told as any[]).some(([, state]) => state === "failed"), name);
  }
});

test("transfers from another station with its grant: read in parts, let go once moved; one whose station went away taken up again", { skip }, async () => {
  const big = Buffer.alloc(600 * 1024, 3);
  await bothTransfers("remote-move", {
    stations: ["A", "B"], into: "B",
    build: (s) => { wr(join(s.A!.root, "photos", "big.bin"), big); wr(join(s.A!.root, "note.md"), "# hi"); },
    steps: (s) => [
      { do: "start", tag: "t", spec: spec({ move: true, from: { station: "A", grant: grantOf(s.A!, { names: ["photos", "note.md"], move: true }), root: s.A!.root, path: "", names: ["photos", "note.md"] }, to: { root: s.B!.root, path: "" } }) },
      { do: "idle" },
    ],
  });
  const ramp = Buffer.from(Array.from({ length: 700 * 1024 }, (_, i) => i % 251));
  const away = await bothTransfers("remote-away", {
    stations: ["A", "B"], into: "B",
    build: (s) => wr(join(s.A!.root, "big.bin"), ramp),
    hooks: () => ({ away: true }),
    steps: (s) => [
      { do: "start", tag: "t", spec: spec({ from: { station: "A", grant: grantOf(s.A!, { names: ["big.bin"] }), root: s.A!.root, path: "", names: ["big.bin"] }, to: { root: s.B!.root, path: "" } }) },
      { do: "idle" },
      { do: "reopen" },
      { do: "away", value: false },
      { do: "retry", tag: "t" },
      { do: "idle" },
    ],
  });
  assert.equal((away.transfers.t as any).copied, ramp.length);
  await bothTransfers("remote-bad-grant", {
    stations: ["A", "B"], into: "B",
    build: (s) => wr(join(s.A!.root, "x.txt"), "x"),
    steps: (s) => [
      { do: "start", tag: "t", spec: spec({ from: { station: "A", grant: grantOf(s.A!, { names: ["other"] }), root: s.A!.root, path: "", names: ["x.txt"] }, to: { root: s.B!.root, path: "" } }) },
      { do: "idle" },
      { do: "start", tag: "nobody", spec: spec({ from: { station: "C", grant: "g", root: "/", path: "", names: ["x.txt"] }, to: { root: s.B!.root, path: "" } }) },
      { do: "idle" },
    ],
  });
});

test("transfers cancelled between parts or while their destination is listed, and a file changed while read read again", { skip }, async () => {
  await bothTransfers("cancel-read", {
    stations: ["B"], into: "B",
    build: () => {},
    hooks: () => ({ source: "cancelAt4" }),
    steps: (s) => [{ do: "start", tag: "t", spec: spec({ from: { station: "A", grant: "g", root: "/", path: "", names: ["f.txt"] }, to: { root: s.B!.root, path: "" } }) }, { do: "idle" }, { do: "cancel", tag: "t" }, { do: "retry", tag: "t" }],
  });
  for (const move of [false, true]) await bothTransfers(`cancel-place-${move}`, {
    stations: ["S"], into: "S",
    build: (s) => { wr(join(s.S!.root, "src", "f.txt"), "new"); wr(join(s.S!.root, "src", "next.txt"), "next"); wr(join(s.S!.root, "dst", "f.txt"), "old"); },
    hooks: (s) => ({ cancelOnList: { path: "dst", tag: "t", thenTag: "next", then: spec({ from: { station: null, root: s.S!.root, path: "src", names: ["next.txt"] }, to: { root: s.S!.root, path: "dst" } }) } }),
    steps: (s) => [
      { do: "start", tag: "t", spec: spec({ move, from: { station: null, root: s.S!.root, path: "src", names: ["f.txt"] }, to: { root: s.S!.root, path: "dst" }, conflicts: { "f.txt": "replace" } }) },
      { do: "idle" },
      { do: "idle" },
      { do: "reopen" },
    ],
  });
  await bothTransfers("changed", {
    stations: ["B"], into: "B",
    build: () => {},
    hooks: () => ({ source: "changed" }),
    steps: (s) => [{ do: "start", tag: "t", spec: spec({ from: { station: "A", grant: "g", root: "/", path: "", names: ["f.txt"] }, to: { root: s.B!.root, path: "" } }) }, { do: "idle" }],
  });
});

test("still.fail Helper's protected folders: reached through it with its grant, refused with its window up without, never watched", { skip }, async () => {
  MOUNTS = await platform.mountsSoon();
  const a = world("helper-ts");
  const b = world("helper-mb");
  const bases = [a.base, b.base];
  for (const grants of [{}, { docs: "granted" }, { docs: "denied" }]) {
    for (const s of [
      { op: "list", root: "<docs>", path: "", anywhere: true },
      { op: "list", root: "<docs>", path: "inner", anywhere: true },
      { op: "stat", root: "<docs>", path: "secret.txt", anywhere: true },
      { op: "read", root: "<docs>", path: "secret.txt", offset: 0, length: 10, anywhere: true },
      { op: "file", root: "<docs>", path: "secret.txt", anywhere: true },
      { op: "folderToWatch", root: "<docs>", path: "", anywhere: true },
      { op: "place", root: "<docs>", path: "inner", anywhere: true },
      { op: "rootView", path: "<docs>" },
      { op: "checkRoot", path: "<docs>" },
      { op: "folders", path: "<base>", home: "<base>", lang: "en" },
      { op: "list", root: "<root>", path: "", anywhere: true },
      { op: "mkdir", root: "<docs>", path: "made", anywhere: true },
      { op: "upload", root: "<docs>", path: "up.txt", id: "h1", offset: 0, total: 2, body: Buffer.from("hi").toString("base64"), anywhere: true },
      { op: "rename", root: "<docs>", path: "made", to: "made2", anywhere: true },
      { op: "remove", root: "<docs>", path: "made2", anywhere: true, permanent: true },
    ]) {
      const fill = (wd: ReturnType<typeof world>) => {
        const docs = join(wd.base, "Documents");
        const g = Object.fromEntries(Object.entries(grants).map(([k, v]) => [k === "docs" ? docs : k, v]));
        return JSON.parse(JSON.stringify({ drive: { ...specOf(wd), helper: { grants: g } }, ...s }).split("<docs>").join(docs).split("<root>").join(wd.root).split("<base>").join(wd.base));
      };
      const want = await tsDriveCase(fill(a));
      const got = await ask({ kind: "drive", ...fill(b) });
      const strip = (v: any) => JSON.parse(JSON.stringify(v), (k, x) => (k === "mtime" ? "<mtime>" : x));
      assert.deepEqual(strip(same(got, bases)), strip(same(want, bases)), `${JSON.stringify(grants)} ${s.op} ${s.path}`);
    }
  }
  assert.deepEqual(tree(b.base), tree(a.base));
});
