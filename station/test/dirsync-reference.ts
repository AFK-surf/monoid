// The sending side of station_task's directory sync as the station's TypeScript did it before it moved into the
// MoonBit program (station/mb src/reader/dirsync_source.mbt): what a directory has to sync (`listLocal`), the mirror
// brought up to date (`syncDir`) and its contents sent (`sendBlobs`). Nothing of the station runs it: it is what the
// tests compare the program's listing and requests with (test/mb-dirsync.test.ts), as it was at the move (#6512's
// station/src/jobs/dirsync.ts), its comments kept.
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { lstat, open, readlink, stat } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { zstdCompress } from "node:zlib";
import { NoBytes, withBytes } from "../src/mesh/bus.ts";
import { oneBytes } from "../src/mesh/files.ts";
import { walkBounded } from "../src/ops/walk.ts";
import { Bulk, EXEC, FILE, LINK, blobId } from "../src/jobs/dirsync.ts";

type Json = any;

/// Directories a walk outside Git leaves out, wherever they are: version control, dependencies and build output.
export const IGNORED = new Set([".git", ".hg", ".svn", ".jj", "node_modules", "target", "dist", "build", ".gradle", ".next", ".turbo", ".cache", "__pycache__", ".venv"]);
const IGNORED_FILES = new Set([".DS_Store"]);
/// At most this many files in a directory synced.
export const MAX_FILES = 200_000;
/// A walk outside Git lists at most this many entries (directories too), at most this deep.
const WALK_ENTRIES = 2 * MAX_FILES;
const WALK_DEPTH = 64;
const MAX_FILE = 1024 * 1024 * 1024;
/// A file goes in pieces of at most this much.
const PIECE = 512 * 1024;
/// To a station from before bytes went after a request (mesh/peer.ts): a request's packed data at most (base64 of the
/// compressed pieces), and its pieces at most: with the rest of the request it stays within the transport's message
/// (1 MiB).
const BODY = 720 * 1024;
const PIECES = 2000;
/// A request's pieces unpacked at most.
export const RAW = 16 * 1024 * 1024;
/// A request's packed pieces at most, after it: RAW, and what packing adds to what does not shrink.
export const PACKED = RAW + 1024 * 1024;
/// A page of a manifest or a plan, as JSON, at most about this much.
const PAGE = 512 * 1024;

const pack = promisify(zstdCompress);
const run = promisify(execFile);

/// The blob id of a file `size` bytes long, read as a stream.
async function fileId(path: string, size: number): Promise<string> {
  const hash = createHash("sha1").update(`blob ${size}\0`);
  let read = 0;
  for await (const chunk of createReadStream(path)) {
    hash.update(chunk as Buffer);
    read += (chunk as Buffer).length;
  }
  if (read !== size) throw new Error(`${path} changed while it was read`);
  return hash.digest("hex");
}

/// Whether a link at `path` (relative, / between parts) naming `target` stays inside the directory.
export function linkInside(path: string, target: string): boolean {
  if (target === "" || target.startsWith("/") || target.startsWith("\\") || /^[A-Za-z]:/.test(target)) return false;
  const parts = path.split("/").slice(0, -1);
  for (const part of target.split(/[\\/]/)) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (parts.length === 0) return false;
      parts.pop();
    } else parts.push(part);
  }
  return true;
}

const modeOf = (mode: number) => (mode & 0o111 ? EXEC : FILE);

// ── the source: what the directory has ──

/// `indexed`: its id is the Git index's (a clean tracked file), not yet the hash of its bytes.
export type Local = { path: string; hash: string; mode: string; size: number; indexed?: boolean };
/// `submodules`: what the target checks out in the mirror (a submodule's files are not sent): path, commit, URL.
export type Submodule = { path: string; id: string; url: string };
export type Listing = { files: Local[]; git: boolean; prefix: string; skipped: { path: string; why: string }[]; submodules: Submodule[] };

async function git(dir: string, args: string[]): Promise<string> {
  const { stdout } = await run("git", ["-C", dir, ...args], { maxBuffer: 1 << 30, env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" } });
  return stdout;
}

const entries = (out: string) => out.split("\0").filter((s) => s !== "");

/// `git config -z` entries of `args` (--get-regexp's): key → value; none where git found none.
async function gitConfig(dir: string, args: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  const text = await git(dir, ["config", "-z", ...args]).catch(() => "");
  for (const entry of text.split("\0")) {
    const nl = entry.indexOf("\n");
    if (nl >= 0) out.set(entry.slice(0, nl), entry.slice(nl + 1));
    else if (entry !== "") out.set(entry, "");
  }
  return out;
}

/// A submodule's URL as Git takes it: one relative to the superproject's (`./`, `../`) against `base` (its origin's
/// URL; none without one), each `../` taking off the last part of it.
export function submoduleUrl(url: string, base: string): string {
  if (!url.startsWith("./") && !url.startsWith("../")) return url;
  if (base === "") return "";
  let b = base.replace(/\/+$/, "");
  let u = url;
  for (;;) {
    if (u.startsWith("./")) u = u.slice(2);
    else if (u.startsWith("../")) {
      u = u.slice(3);
      // (a part goes up to its `/`, or up to the `:` of `host:path`)
      const slash = b.lastIndexOf("/");
      // (`host:` keeps its colon)
      const cut = slash > 0 && !b.slice(0, slash).endsWith("/") ? slash : b.lastIndexOf(":") + 1;
      if (cut <= 0) return "";
      b = b.slice(0, cut);
    } else break;
  }
  return b.endsWith(":") ? b + u : `${b}/${u}`;
}

/// The submodules among `links` (path, the index's commit) as the target is to check them out: the commit checked out
/// in each, else the index's, and its URL. One with no URL is left out, said in `skipped`.
async function submodulesOf(dir: string, prefix: string, links: [string, string][], skipped: { path: string; why: string }[]): Promise<Submodule[]> {
  const out: Submodule[] = [];
  if (links.length === 0) return out;
  const listed = await gitConfig(dir, ["--blob", ":.gitmodules", "--get-regexp", "^submodule\\..*\\.(path|url)$"]);
  const own = await gitConfig(dir, ["--get-regexp", "^submodule\\..*\\.url$"]);
  const origin = (await git(dir, ["config", "--get", "remote.origin.url"]).catch(() => "")).trim();
  const named = new Map<string, string>();
  for (const [key, value] of listed) if (key.startsWith("submodule.") && key.endsWith(".path")) named.set(value, key.slice(10, -5));
  for (const [path, indexId] of links) {
    const name = named.get(prefix + path);
    const url = name === undefined ? "" : submoduleUrl(own.get(`submodule.${name}.url`) ?? listed.get(`submodule.${name}.url`) ?? "", origin);
    if (url === "") {
      skipped.push({ path, why: "submodule with no URL in .gitmodules" });
      continue;
    }
    let id = indexId;
    if ((await lstat(join(dir, ...path.split("/"), ".git")).catch(() => null)) !== null) {
      const head = (await git(join(dir, ...path.split("/")), ["rev-parse", "-q", "--verify", "HEAD^{commit}"]).catch(() => "")).trim();
      if (/^[0-9a-f]{40}$/.test(head)) id = head;
    }
    out.push({ path, id, url });
  }
  return out;
}

/// A file of the directory as it is on disk; null when it is not there (or a directory), a reason when it is left out.
async function onDisk(dir: string, path: string): Promise<Local | string | null> {
  const abs = join(dir, ...path.split("/"));
  let st;
  try {
    st = await lstat(abs);
  } catch {
    return null;
  }
  if (st.isSymbolicLink()) {
    const target = await readlink(abs);
    if (!linkInside(path, target)) return "symbolic link leading out of the directory";
    const content = Buffer.from(target);
    return { path, hash: blobId(content), mode: LINK, size: content.length };
  }
  if (st.isDirectory()) return null;
  if (!st.isFile()) return "not a regular file";
  if (st.size > MAX_FILE) return "larger than 1 GiB";
  return { path, hash: await fileId(abs, st.size), mode: modeOf(st.mode), size: st.size };
}

/// `todo` done 8 at a time.
async function pool<T>(items: T[], f: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(8, items.length) }, async () => {
    while (next < items.length) await f(items[next++]!);
  }));
}

/// What of `dir` is synced: Git's files in a work tree, a walk without IGNORED elsewhere.
export async function listLocal(dir: string): Promise<Listing> {
  if (!(await stat(dir)).isDirectory()) throw new Error(`${dir} is not a directory`);
  let tree: string[] | null = null;
  try {
    tree = (await git(dir, ["rev-parse", "--is-inside-work-tree", "--show-prefix"])).split("\n");
    // A directory its work tree ignores (a build directory) has no files Git names: walked.
    if (tree[0] === "true" && tree[1] !== "") {
      const ignored = await git(dir, ["check-ignore", "-q", "."]).then(() => true, () => false);
      if (ignored) tree = null;
    }
  } catch {}
  const files: Local[] = [];
  const skipped: { path: string; why: string }[] = [];
  const take = (got: Local | string | null, path: string) => {
    if (typeof got === "string") skipped.push({ path, why: got });
    else if (got !== null) files.push(got);
  };
  const more = () => {
    if (files.length > MAX_FILES) throw new Error(`${dir} has more than ${MAX_FILES} files to sync`);
  };
  if (tree !== null && tree[0] === "true") {
    const prefix = tree[1] ?? "";
    const modified = new Set(entries(await git(dir, ["ls-files", "-z", "-m"])));
    const seen = new Set<string>();
    const hash: string[] = [];
    const clean: { path: string; id: string; mode: string }[] = [];
    const links: [string, string][] = [];
    for (const line of entries(await git(dir, ["ls-files", "-z", "-s"]))) {
      const tab = line.indexOf("\t");
      const [mode, id, stage] = line.slice(0, tab).split(" ");
      const path = line.slice(tab + 1);
      if (seen.has(path)) continue;
      seen.add(path);
      if (mode === "160000") {
        links.push([path, id!]);
        continue;
      }
      // A clean tracked file is what the index says; a changed one (or one in a conflict) is hashed.
      if (modified.has(path) || stage !== "0" || (mode !== FILE && mode !== EXEC && mode !== LINK)) {
        hash.push(path);
        continue;
      }
      if (mode === LINK) {
        hash.push(path);
        continue;
      }
      clean.push({ path, id: id!, mode: mode! });
      if (clean.length > MAX_FILES) throw new Error(`${dir} has more than ${MAX_FILES} files to sync`);
    }
    // Each one's size, off the station's main thread: one at a time there, a repository's thousands of files held every
    // device for seconds on a station short of memory (2026-11-02, 24 s in six hours).
    await pool(clean, async ({ path, id, mode }) => {
      const st = await lstat(join(dir, ...path.split("/"))).catch(() => null);
      if (st === null) return;
      if (!st.isFile()) hash.push(path);
      else files.push({ path, hash: id, mode, size: st.size, indexed: true });
    });
    more();
    for (const path of entries(await git(dir, ["ls-files", "-z", "-o", "--exclude-standard"]))) {
      if (path.endsWith("/")) skipped.push({ path: path.slice(0, -1), why: "nested repository" });
      else hash.push(path);
    }
    if (files.length + hash.length > MAX_FILES) throw new Error(`${dir} has more than ${MAX_FILES} files to sync`);
    await pool(hash, async (path) => take(await onDisk(dir, path), path));
    const submodules = await submodulesOf(dir, prefix, links, skipped);
    return { files: files.sort(byPath), git: true, prefix, skipped, submodules };
  }
  // Walked bounded (ops/walk.ts), yielding the station's thread as it goes: a directory on another file system mounted
  // in it is left out (said in `skipped`), no link followed. What would leave the listing short is an error, never a
  // listing short of files, whose absence the mirror would take for files removed.
  const found: string[] = [];
  const walked = await walkBounded(dir, (e) => {
    if (e.depth === 0) return;
    if (e.directory) {
      if (IGNORED.has(e.name)) return "skip";
      return;
    }
    if (IGNORED_FILES.has(e.name)) return;
    found.push(e.rel);
    if (found.length > MAX_FILES) throw new Error(`${dir} has more than ${MAX_FILES} files to sync`);
  }, {
    followRoot: true, maxEntries: WALK_ENTRIES, maxDepth: WALK_DEPTH, maxDurationMs: Number.POSITIVE_INFINITY,
    onError: (_, error, op) => { if (op === "readdir") throw error; },
    onCrossed: (e) => skipped.push({ path: e.rel, why: "another file system" }),
  });
  if (walked.reason === "entries") throw new Error(`${dir} has more than ${WALK_ENTRIES} entries to walk`);
  if (walked.reason === "depth") throw new Error(`${dir} is deeper than ${WALK_DEPTH} directories`);
  await pool(found, async (path) => take(await onDisk(dir, path), path));
  return { files: files.sort(byPath), git: false, prefix: "", skipped, submodules: [] };
}

const byPath = (a: { path: string }, b: { path: string }) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0);

// ── the source: bringing a mirror up to date ──

/// A sync request to the target, for the task being started (`sync.<method>`, its session and key added).
export type Ask = (method: string, more: Json) => Promise<Json>;

export type Synced = {
  files: number;
  git: boolean;
  /// Contents the mirror had nowhere, sent: how many, their bytes, and the bytes that went (compressed).
  sent: { files: number; bytes: number; packed: number; requests: number };
  written: number;
  removed: number;
  /// What was left out (the first 50), and how many.
  skipped: { path: string; why: string }[];
  skippedCount: number;
  /// The submodules the target is to check out.
  submodules: number;
  /// The directory's place in its Git work tree ("" outside one).
  prefix: string;
  ms: number;
};

const reuseKey = (hash: string, mode: string) => `${mode === LINK ? "link" : "file"}:${hash}`;

/// Builds `sync.commit` request payloads whose final serialized UTF-8 JSON bytes stay within `budget` (covering `id`,
/// `set`, `remove`, `final`, and `submodules` plus JSON frame overhead).
export function commitPages(
  id: string,
  set: [string, string, string][],
  remove: string[],
  submodules: Submodule[],
  budget = PAGE,
): { id: string; set: [string, string, string][]; remove: string[]; final: boolean; submodules?: [string, string, string][] }[] {
  const frameBase = Buffer.byteLength(JSON.stringify({ id, set: [], remove: [], final: false }));
  const pages: { set: [string, string, string][]; remove: string[]; bytes: number }[] = [{ set: [], remove: [], bytes: frameBase }];
  for (const item of set) {
    const n = Buffer.byteLength(JSON.stringify(item));
    const cur = pages.at(-1)!;
    const comma = cur.set.length > 0 ? 1 : 0;
    if (cur.bytes + comma + n > budget && (cur.set.length > 0 || cur.remove.length > 0)) {
      pages.push({ set: [item], remove: [], bytes: frameBase + n });
    } else {
      cur.set.push(item);
      cur.bytes += comma + n;
    }
  }
  for (const path of remove) {
    const n = Buffer.byteLength(JSON.stringify(path));
    const cur = pages.at(-1)!;
    const comma = cur.remove.length > 0 ? 1 : 0;
    if (cur.bytes + comma + n > budget && (cur.set.length > 0 || cur.remove.length > 0)) {
      pages.push({ set: [], remove: [path], bytes: frameBase + n });
    } else {
      cur.remove.push(path);
      cur.bytes += comma + n;
    }
  }
  const subsJson: [string, string, string][] = submodules.map((s) => [s.path, s.id, s.url]);
  if (subsJson.length > 0) {
    const last = pages.at(-1)!;
    const withSubs = last.bytes - 1 + Buffer.byteLength(',"submodules":') + Buffer.byteLength(JSON.stringify(subsJson));
    if (withSubs > budget && (last.set.length > 0 || last.remove.length > 0)) {
      pages.push({ set: [], remove: [], bytes: frameBase });
    }
  }
  return pages.map((page, i) => {
    const isLast = i === pages.length - 1;
    return {
      id,
      set: page.set,
      remove: page.remove,
      final: isLast,
      ...(isLast && subsJson.length > 0 ? { submodules: subsJson } : {}),
    };
  });
}

/// Brings the target's mirror up to date with `dir`; null when the task started already (nothing synced: a start
/// asked again returns the job that started).
/// `bulk`: where its contents wait their turn with the station's other bulk requests.
export async function syncDir(ask: Ask, dir: string, now: () => number = Date.now, bulk: Bulk = new Bulk()): Promise<Synced | null> {
  const t0 = now();
  const begun = await ask("sync.begin", { safe: 1 });
  if (begun?.started === true) return null;
  if (begun?.safe !== 1) throw new Error("the target cannot protect remote results during sync; update that station before starting");
  const id = String(begun?.id ?? "");
  const listing = await listLocal(dir);
  const there = new Map<string, [string, string]>();
  for (let after: number | null = 0; after !== null; ) {
    const page: Json = await ask("sync.manifest", { id, after });
    for (const [path, hash, mode] of page.entries as [string, string, string][]) there.set(path, [hash, mode]);
    after = typeof page.next === "number" ? page.next : null;
  }
  const base = new Map<string, [string, string]>();
  for (let after: number | null = 0; after !== null; ) {
    const page: Json = await ask("sync.base", { id, after });
    for (const [path, hash, mode] of page.entries as [string, string, string][]) base.set(path, [hash, mode]);
    after = typeof page.next === "number" ? page.next : null;
  }
  // Compare the source with the last source version, not the mirror's possibly newer task output.
  const same = (f: Local) => {
    const t = base.get(f.path);
    return t !== undefined && t[0] === f.hash && t[1] === f.mode;
  };
  // What would go with the index's id is hashed first: with a Git filter or eol conversion (a .bat checked out with
  // CRLF, LFS) the bytes on disk are not what the index names, and what the mirror has may be them already.
  const gone = new Set<string>();
  await pool(listing.files.filter((f) => f.indexed && !same(f)), async (f) => {
    const got = await onDisk(dir, f.path);
    if (got === null || typeof got === "string") {
      gone.add(f.path);
      if (typeof got === "string") listing.skipped.push({ path: f.path, why: got });
      return;
    }
    Object.assign(f, got, { indexed: false });
  });
  if (gone.size > 0) listing.files = listing.files.filter((f) => !gone.has(f.path));
  const have = new Set([...there.values()].map(([hash, mode]) => reuseKey(hash, mode)));
  const set: [string, string, string][] = [];
  const need = new Map<string, Local>();
  for (const f of listing.files) {
    if (same(f)) continue;
    set.push([f.path, f.hash, f.mode]);
    if (!have.has(reuseKey(f.hash, f.mode)) && !need.has(f.hash)) need.set(f.hash, f);
  }
  const local = new Set(listing.files.map((f) => f.path));
  const remove = [...base.keys()].filter((p) => !local.has(p));
  const sent = await sendBlobs(ask, id, dir, [...need.values()], bulk);
  const commits = commitPages(id, set, remove, listing.submodules);
  let answer: Json = null;
  for (const commit of commits) {
    answer = await ask("sync.commit", commit);
  }
  return {
    files: listing.files.length,
    git: listing.git,
    sent,
    written: Number(answer?.written ?? 0),
    removed: Number(answer?.removed ?? 0),
    skipped: listing.skipped.slice(0, 50),
    skippedCount: listing.skipped.length,
    submodules: listing.submodules.length,
    prefix: listing.prefix,
    ms: now() - t0,
  };
}

type Piece = { hash: string; size: number; offset: number; data: Buffer };

/// Sends the contents in `need` in packed requests, each of RAW at most, its packed pieces after it; to a station from
/// before, each within BODY, base64 in it. Checks each file is still what was hashed.
async function sendBlobs(ask: Ask, id: string, dir: string, need: Local[], bulk: Bulk): Promise<Synced["sent"]> {
  const sent = { files: need.length, bytes: 0, packed: 0, requests: 0 };
  // Whether the station takes the packed pieces after the request: until its transport says it does not (NoBytes, the
  // first request not sent).
  let after = true;
  // How much a request's pieces shrink, from the last one (assumed not at all at first).
  let ratio = 1;
  let batch: Piece[] = [];
  let raw = 0;
  const flush = async (pieces: Piece[]): Promise<void> => {
    if (pieces.length === 0) return;
    const plain = Buffer.concat(pieces.map((p) => p.data));
    const packed = await pack(plain);
    const blobs = pieces.map((p) => [p.hash, p.size, p.offset, p.data.length]);
    if (after) {
      try {
        await bulk.run(() => ask("sync.put", withBytes({ id, blobs }, oneBytes(packed))));
      } catch (error) {
        if (!(error instanceof NoBytes)) throw error;
        after = false;
        return flush(pieces);
      }
    } else {
      const data = packed.toString("base64");
      if (data.length > BODY && pieces.length > 1) {
        const half = Math.ceil(pieces.length / 2);
        await flush(pieces.slice(0, half));
        await flush(pieces.slice(half));
        return;
      }
      await bulk.run(() => ask("sync.put", { id, blobs, data }));
    }
    ratio = Math.max(0.02, packed.length / Math.max(1, plain.length));
    sent.requests++;
    sent.packed += packed.length;
  };
  const add = async (piece: Piece) => {
    const budget = after ? RAW : Math.min(RAW, (BODY * 0.7) / ratio);
    if (batch.length > 0 && (raw + piece.data.length > budget || batch.length >= PIECES)) {
      const pieces = batch;
      batch = [];
      raw = 0;
      await flush(pieces);
    }
    batch.push(piece);
    raw += piece.data.length;
    sent.bytes += piece.data.length;
  };
  for (const f of need) {
    const abs = join(dir, ...f.path.split("/"));
    const changed = () => new Error(`${f.path} changed while syncing; start again`);
    if (f.mode === LINK) {
      const content = Buffer.from(await readlink(abs).catch(() => ""));
      if (blobId(content) !== f.hash) throw changed();
      await add({ hash: f.hash, size: content.length, offset: 0, data: content });
      continue;
    }
    const file = await open(abs, "r").catch(() => null);
    if (file === null) throw changed();
    try {
      const hash = createHash("sha1").update(`blob ${f.size}\0`);
      let offset = 0;
      do {
        const data = Buffer.alloc(Math.min(PIECE, f.size - offset));
        const { bytesRead } = await file.read(data, 0, data.length, offset);
        if (bytesRead !== data.length) throw changed();
        hash.update(data);
        if (offset + data.length === f.size && hash.digest("hex") !== f.hash) throw changed();
        await add({ hash: f.hash, size: f.size, offset, data });
        offset += data.length;
      } while (offset < f.size);
    } finally {
      await file.close();
    }
  }
  await flush(batch);
  return sent;
}

