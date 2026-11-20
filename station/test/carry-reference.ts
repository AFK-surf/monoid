// The gathering and placing of a retired station's files as a worker thread did them before they were the MoonBit
// program's (station/src/replica/carry.ts, station/mb src/replica/carry.mbt): the tests' only, what the program is
// compared with on the same data (mb-replica-carry.test.ts), and the files the tests make to give it. What it does is
// carry.ts's to say.
import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { appendFileSync, chmodSync, closeSync, copyFileSync, existsSync, linkSync, lstatSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, readlinkSync, realpathSync, renameSync, rmSync, symlinkSync, utimesSync, writeFileSync, writeSync } from "node:fs";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { ANY_NAME_DEPTH, rebuildableByName, rebuiltByName, rebuiltOfAnyName, roomOf } from "./footprint-reference.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS } from "../src/sessions/agent-home.ts";
import { runtimeKind } from "../src/agents/runtime.ts";
import { sessionPlaces, storage, transcriptSources } from "./reference/transcript-paths.ts";
import { carriedTo, moved } from "../src/replica/restore.ts";

import { type CarriedFile, type CarriedGit, type CarriedHome, type CarriedSession, type CarryIndex, type Gathered, SIZED_TRANSCRIPTS, type Sized, type Sizing, carriedPlace, cliKeptOf, indexFile, listFile } from "../src/replica/carry.ts";

export type { CarriedFile, CarryIndex, Gathered };

/// Whether an error reading a file is that this station may not read it (not that it went meanwhile).
const denied = (e: unknown) => ["EACCES", "EPERM"].includes((e as NodeJS.ErrnoException)?.code ?? "");

/// A session of the workspace as the gathering reads it.
type SessionAt = { key: string; workspace: string; cwd: string | null; runtime: string; profile: string; runtime_session_id: string | null; archived_at: number | null };

const within = (path: string, dir: string) => path === dir || path.startsWith(dir.endsWith(sep) ? dir : dir + sep);

/// A file's hash, read a piece at a time (a room's packed workspace is gigabytes).
export function hashFile(path: string): string {
  const h = createHash("sha256");
  const fd = openSync(path, "r");
  const buf = Buffer.allocUnsafe(1 << 20);
  try {
    for (;;) {
      const n = readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      h.update(buf.subarray(0, n));
    }
  } finally {
    closeSync(fd);
  }
  return h.digest("hex");
}

/// The lines of a file, read a piece at a time.
export function* linesOf(path: string): Generator<string> {
  const fd = openSync(path, "r");
  const buf = Buffer.allocUnsafe(1 << 20);
  let rest = Buffer.alloc(0);
  try {
    for (;;) {
      const n = readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      let chunk = Buffer.concat([rest, buf.subarray(0, n)]);
      for (let at = chunk.indexOf(10); at >= 0; at = chunk.indexOf(10)) {
        if (at > 0) yield chunk.subarray(0, at).toString("utf8");
        chunk = chunk.subarray(at + 1);
      }
      rest = Buffer.from(chunk);
    }
    if (rest.length > 0) yield rest.toString("utf8");
  } finally {
    closeSync(fd);
  }
}

/// A session's list, written a line at a time, its hash taken as it goes.
class ListFile {
  readonly #fd: number;
  readonly #hash = createHash("sha256");
  readonly tmp: string;
  files = 0;
  bytes = 0;
  readonly path: string;
  constructor(path: string) {
    this.path = path;
    this.tmp = `${path}.writing`;
    this.#fd = openSync(this.tmp, "w");
  }
  add(f: CarriedFile): void {
    const line = `${JSON.stringify(f)}\n`;
    this.#hash.update(line);
    writeSync(this.#fd, line);
    if ("hash" in f) {
      this.files++;
      this.bytes += f.size;
    }
  }
  close(): string {
    closeSync(this.#fd);
    renameSync(this.tmp, this.path);
    return this.#hash.digest("hex");
  }
}

const GIT_ENV = { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_SSH_COMMAND: "ssh -o BatchMode=yes" };
/// How long a fetch of a checkout's remote may take as it is gathered.
const FETCH_MS = 120_000;

const git = (dir: string, args: string[], timeout?: number): string | null => {
  try {
    return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], env: GIT_ENV, maxBuffer: 256 * 1024 * 1024, timeout }).trim();
  } catch {
    return null;
  }
};

/// The sessions of a workspace whose things go along, as both the gathering and the preview read them (`home`: the
/// station's home workspace, whose sessions say none); `keys`: those sessions alone (a chat handed over, handover.ts),
/// whatever their `ws`.
const sessionsIn = (home: boolean, keys: readonly string[] | null = null) => keys !== null
  ? "SELECT key, workspace, cwd, runtime, profile, runtime_session_id, archived_at FROM sessions WHERE key IN (SELECT value FROM json_each(?)) ORDER BY key"
  : `SELECT key, workspace, cwd, runtime, profile, runtime_session_id, archived_at FROM sessions WHERE ${home ? "(ws = ? OR ws IS NULL)" : "ws = ?"} ORDER BY key`;

/// A session's room under `dataDir` as its files go along (footprint-reference.ts `roomOf`, said under `dataDir` as given,
/// `realData` its real path), null where its directory is not the station's own (it stays, `skipped`).
function roomFor(dataDir: string, realData: string, workspace: string): string | null {
  const real = roomOf(dataDir, workspace);
  return real === null || !within(real, realData) ? null : join(dataDir, relative(realData, real));
}

/// What a retirement of `ws` would take of its sessions here, as the app shows it first (retire.ts `preview`): how many
/// chats, archived or not, and how many have a directory that is not the station's own (the gathering's `skipped`),
/// found as the gathering finds it, no directory walked.
export function preview(dataDir: string, db: string, ws: string, home: boolean): { chats: number; archived: number; outside: number } {
  const d = new DatabaseSync(db, { readOnly: true, timeout: 30_000 });
  let realData = dataDir;
  try {
    realData = realpathSync(dataDir);
  } catch {}
  let chats = 0;
  let archived = 0;
  let outside = 0;
  try {
    for (const s of d.prepare(sessionsIn(home)).iterate(ws) as Iterable<SessionAt>) {
      if (s.archived_at === null) chats++;
      else archived++;
      if (roomFor(dataDir, realData, s.workspace) === null) outside++;
    }
  } finally {
    d.close();
  }
  return { chats, archived, outside };
}

/// A sizing's walk past its bound.
const CUT = Symbol("cut");

/// A session's files counted, for a sizing (`ListFile`'s count, nothing written).
class Tally {
  files = 0;
  bytes = 0;
  add(f: CarriedFile): void {
    if ("hash" in f) {
      this.files++;
      this.bytes += f.size;
    }
  }
  close(): string {
    return "";
  }
}

/// What goes along with the chats of `ws` on the station whose data directory is `dataDir`: their transcripts and each
/// one's room, a git checkout in it as git lists its files (tracked and not ignored) with its repository, a linked
/// worktree's commits no remote has in a bundle; written in `scratch` (a list a session, the index of them). A file of
/// the gathering before that has the same size and time is not read again (its hash from that session's list then).
/// `agent`: the workspace's agent home here, whose own files go along too (`homeFiles`). `keys`: those sessions alone,
/// not the workspace's (a chat handed over: its scratch is its own).
export function gather(dataDir: string, db: string, ws: string, home: boolean, scratch: string, agent: string | null = null, keys: readonly string[] | null = null): Gathered {
  return walked(dataDir, db, ws, home, scratch, agent, keys, null) as Gathered;
}

/// The sessions `keys` sized as a move would gather them (`Sizing`); with `places`, what this station has where those
/// would go (no database read).
export function sizes(dataDir: string, db: string, keys: readonly string[], sizing: Sizing): Sized[] {
  return walked(dataDir, db, "", false, "", null, keys, sizing) as Sized[];
}

function walked(dataDir: string, db: string, ws: string, home: boolean, scratch: string, agent: string | null, keys: readonly string[] | null, sizing: Sizing | null): Gathered | Sized[] {
  const d = sizing?.places !== undefined ? null : new DatabaseSync(db, { readOnly: true, timeout: 30_000 });
  const gits: CarriedGit[] = [];
  const sessions: CarriedSession[] = [];
  const skipped: string[] = [];
  const bundles: Record<string, string> = {};
  const fetched = new Set<string>();
  if (sizing === null) mkdirSync(join(scratch, "lists"), { recursive: true });
  let files = 0;
  /// A sizing's entries walked of the session at hand, and its bound.
  let walkedOf = 0;
  const step = sizing === null ? () => {} : () => {
    if (++walkedOf > sizing.most) throw CUT;
  };
  let bytes = 0;
  // (per session: what its list said before, and what is in its list now)
  let before = new Map<string, { size: number; mtimeMs: number; hash: string }>();
  let seen = new Set<string>();
  let list: ListFile | Tally | null = null;
  /// A gathering's: the session's own repositories (a checkout's `.git` directory), walked whole once its room was: a
  /// linked worktree of one walked after it in the room fetches into it (`linked`).
  let ownGits: string[] = [];
  /// Where what is added may be (the agent home's own files are under it, not the data directory's sessions).
  let under: (path: string) => boolean = (path) => carriedPlace(dataDir, path);
  const unreadable: string[] = [];
  let unreadableCount = 0;
  const cannotRead = (path: string) => {
    unreadableCount++;
    if (unreadable.length < 5) unreadable.push(path);
  };
  const add = (path: string) => {
    if (seen.has(path) || !under(path) || list === null) return;
    seen.add(path);
    step();
    let st;
    try {
      st = lstatSync(path);
    } catch {
      return;
    }
    if (st.isSymbolicLink()) {
      list.add({ path, link: readlinkSync(path) });
      return;
    }
    if (!st.isFile()) return;
    if (sizing !== null) return list.add({ path, hash: "", size: st.size, mode: 0, mtimeMs: st.mtimeMs });
    const was = before.get(path);
    let hash: string;
    try {
      hash = was !== undefined && was.size === st.size && was.mtimeMs === st.mtimeMs ? was.hash : hashFile(path);
    } catch (e) {
      if (denied(e)) cannotRead(path);
      return;
    }
    list.add({ path, hash, size: st.size, mode: st.mode & 0o777, mtimeMs: st.mtimeMs });
  };
  /// Every file under `dir` as it is (a checkout's own repository).
  const whole = (dir: string) => {
    step();
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch (e) {
      if (denied(e)) cannotRead(dir);
      return;
    }
    for (const name of names.sort()) {
      const path = join(dir, name);
      let st;
      try {
        st = lstatSync(path);
      } catch {
        continue;
      }
      if (st.isDirectory()) whole(path);
      else add(path);
    }
  };
  /// Every file under `dir`, but what a build makes again; a git checkout in it as `checkout` takes it. `depth`: under
  /// the room's top (its own entries 1); what is made again of any name is asked only down to ANY_NAME_DEPTH, by its
  /// listing (footprint-reference.ts `rebuiltOfAnyName`), and by name from the listing of where it is (`rebuiltByName`).
  const tree = (dir: string, depth: number) => {
    step();
    let names: string[];
    try {
      names = readdirSync(dir);
    } catch (e) {
      if (denied(e)) cannotRead(dir);
      return;
    }
    if (names.includes(".git") && checkout(dir, depth)) return;
    if (depth <= ANY_NAME_DEPTH && rebuiltOfAnyName(dir, names)) return;
    const here = new Set(names);
    for (const name of names.sort()) {
      const path = join(dir, name);
      let st;
      try {
        st = lstatSync(path);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (name === ".git" || rebuiltByName(name, here) === null) tree(path, depth + 1);
      } else add(path);
    }
  };
  /// A git checkout at `dir`, taken: its files as git lists them (tracked, and untracked but not ignored), a directory
  /// it lists (a repository in it, a submodule) gone into; its `.git` as its files where it is the checkout's own
  /// repository or a submodule's (a relative `gitdir:`), made again from its remote where it is a linked worktree (an
  /// absolute one). False where git does not read it: its files then go as any others do, `.git` with them.
  const checkout = (dir: string, depth: number): boolean => {
    const dotgit = join(dir, ".git");
    let st;
    try {
      st = lstatSync(dotgit);
    } catch {
      return false;
    }
    const listed = git(dir, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]);
    if (listed === null) return false;
    // (what a build or an install makes again by its name stays behind here too, where git does not ignore it; one known
    // by what is in it goes as git lists it: footprint.ts `Rebuilt`)
    const made = new Map<string, boolean>();
    const rebuilt = (f: string): boolean => {
      const parts = f.split("/");
      for (let i = 1; i < parts.length; i++) {
        const at = parts.slice(0, i).join("/");
        let r = made.get(at);
        if (r === undefined) made.set(at, (r = rebuildableByName(join(dir, at))));
        if (r) return true;
      }
      return false;
    };
    const entries = [...new Set(listed.split("\0").map((f) => f.replace(/\/+$/, "")).filter((f) => f !== "" && !rebuilt(f)))];
    const take = () => {
      for (const f of entries) {
        const path = join(dir, f);
        let s;
        try {
          s = lstatSync(path);
        } catch {
          continue;
        }
        // (a repository in it git lists: what it ignores of its own, git says there; nothing of any name asked in a checkout)
        if (s.isDirectory()) {
          if (!rebuildableByName(path)) tree(path, Math.max(depth + 1, ANY_NAME_DEPTH + 1));
        } else add(path);
      }
    };
    if (st.isDirectory()) {
      if (sizing !== null) whole(dotgit);
      else ownGits.push(dotgit);
      take();
      return true;
    }
    if (!st.isFile()) return false;
    let said = "";
    try {
      said = readFileSync(dotgit, "utf8").trim();
    } catch {}
    const gitdir = said.startsWith("gitdir:") ? said.slice("gitdir:".length).trim() : null;
    const worktree = gitdir !== null && isAbsolute(gitdir) ? linked(dir) : null;
    if (worktree === null) add(dotgit);
    else gits.push(worktree);
    take();
    return true;
  };
  /// A linked worktree at `dir`, as it is made again elsewhere: its remote (fetched first, pruned, so a branch deleted
  /// there is not taken as still there), branch, commit, and its commits no remote has in a bundle. Null without a
  /// remote or a commit.
  const linked = (dir: string): CarriedGit | null => {
    // (a sizing fetches and bundles nothing: its `.git` file is counted, what git makes again there is not)
    if (sizing !== null) return null;
    const remote = git(dir, ["remote", "get-url", "origin"]);
    const head = git(dir, ["rev-parse", "--verify", "-q", "HEAD"]);
    if (remote === null || remote === "" || head === null || head === "") return null;
    const common = git(dir, ["rev-parse", "--git-common-dir"]);
    const repo = common === null ? dir : resolve(dir, common);
    if (!fetched.has(repo)) {
      fetched.add(repo);
      git(dir, ["fetch", "-q", "--no-write-fetch-head", "--prune", "origin"], FETCH_MS);
    }
    const branch = git(dir, ["symbolic-ref", "--short", "-q", "HEAD"]);
    const bundle = join(scratch, `${gits.length}.bundle`);
    rmSync(bundle, { force: true });
    // (git refuses a bundle of nothing: every commit of it is on a remote already)
    let hash: string | null = null;
    if (git(dir, ["bundle", "create", "-q", bundle, "HEAD", "--not", "--remotes"]) !== null && existsSync(bundle)) {
      hash = hashFile(bundle);
      bundles[hash] = bundle;
      bytes += lstatSync(bundle).size;
    }
    return { dir, remote, branch: branch === null || branch === "" ? null : branch, head, bundle: hash };
  };
  /// A session's room, whole (an archived one's workspace packed in it).
  const roomWalk = (room: string) => {
    let names: string[] = [];
    try {
      names = readdirSync(room);
    } catch {}
    const here = new Set(names);
    for (const name of names.sort()) {
      // (its lock, and what is being written as it is looked at, stay)
      if (name === "archive.lock" || name.endsWith(".writing")) continue;
      const path = join(room, name);
      let st;
      try {
        st = lstatSync(path);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (rebuiltByName(name, here) === null) tree(path, 1);
      } else add(path);
    }
  };
  const sized: Sized[] = [];
  // The other station's side: what it has where each session's things would go.
  if (sizing?.places !== undefined) {
    for (const p of sizing.places) {
      seen = new Set();
      walkedOf = 0;
      const tally = new Tally();
      list = tally;
      let complete = true;
      try {
        for (const t of p.transcripts.slice(0, SIZED_TRANSCRIPTS)) {
          let st;
          try {
            st = lstatSync(t);
          } catch {
            continue;
          }
          if (st.isDirectory()) whole(t);
          else add(t);
        }
        if (p.room !== null) roomWalk(p.room);
      } catch (e) {
        if (e !== CUT) throw e;
        complete = false;
      }
      list = null;
      sized.push({ ...p, bytes: tally.bytes, files: tally.files, complete });
    }
    return sized;
  }
  let realData = dataDir;
  try {
    realData = realpathSync(dataDir);
  } catch {}
  try {
    const rows = d!.prepare(sessionsIn(home, keys)).all(keys !== null ? JSON.stringify(keys) : ws) as SessionAt[];
    const runs = d!.prepare("SELECT id, profile, runtime FROM runtime_sessions WHERE session_key = ? ORDER BY at");
    for (const s of rows) {
      const at = listFile(scratch, s.key);
      // (the hashes the list before said, by path: this session's alone)
      before = new Map();
      if (sizing === null && existsSync(at)) for (const line of linesOf(at)) {
        try {
          const f = JSON.parse(line) as CarriedFile;
          if ("hash" in f) before.set(f.path, { size: f.size, mtimeMs: f.mtimeMs, hash: f.hash });
        } catch {}
      }
      seen = new Set();
      walkedOf = 0;
      ownGits = [];
      list = sizing !== null ? new Tally() : new ListFile(at);
      let complete = true;
      /// (a sizing's: where its transcripts are, which the other station is asked to size of its own)
      const tplaces: string[] = [];
      try {
        // Its transcripts: each runtime session's, where the station keeps them (its shared place), and a Claude one's
        // subagents beside it.
        const ids = (runs.all(s.key) as { id: string; profile: string | null; runtime: string | null }[]).map((r) => ({ id: r.id, profile: r.profile, runtime: r.runtime ?? s.runtime }));
        if (s.runtime_session_id !== null && !ids.some((r) => r.id === s.runtime_session_id)) ids.push({ id: s.runtime_session_id, profile: s.profile, runtime: s.runtime });
        // (looked for first where the runtime resumes it: under the project of the room's real path; another of the same
        // id elsewhere is an older copy)
        const places = sessionPlaces(s);
        const found = transcriptSources(dataDir, [], ids.filter((r) => runtimeKind(r.runtime) !== null), [...new Set([...places.map(realOf), ...places])]);
        for (const t of found.paths) {
          add(storage(t.path));
          if (tplaces.length < SIZED_TRANSCRIPTS) tplaces.push(storage(t.path));
          if (t.runtime === "claude") {
            const id = t.path.slice(t.path.lastIndexOf(sep) + 1).replace(/\.jsonl$/, "");
            whole(join(dirname(t.path), id));
            if (tplaces.length < SIZED_TRANSCRIPTS) tplaces.push(join(dirname(t.path), id));
          }
        }
        // An Antigravity CLI conversation's own store in its profile's home: what `session/load` takes it up from.
        for (const r of ids) {
          if (r.runtime !== "agy" || r.profile === null) continue;
          const kept = cliKeptOf(dataDir, r.profile, r.id);
          for (const f of kept.files) add(f);
          for (const dir of kept.dirs) if (existsSync(dir)) whole(dir);
        }
        // Its room, whole (an archived one's workspace packed in it): one that is not the station's goes nowhere.
        const room = roomFor(dataDir, realData, s.workspace);
        if (room === null) skipped.push(s.key);
        else roomWalk(room);
        // (its own repositories last, as the fetches of its linked worktrees left them)
        for (const dotgit of ownGits) whole(dotgit);
      } catch (e) {
        if (e !== CUT) throw e;
        complete = false;
      }
      const done = list!;
      if (sizing !== null) {
        list = null;
        sized.push({ key: s.key, room: roomFor(dataDir, realData, s.workspace), transcripts: tplaces, bytes: done.bytes, files: done.files, complete });
        continue;
      }
      list = null;
      const hash = done.close();
      sessions.push({ key: s.key, workspace: s.workspace, room: roomFor(dataDir, realData, s.workspace), list: hash, files: done.files, bytes: done.bytes, at });
      files += done.files;
      bytes += done.bytes;
    }
  } finally {
    d!.close();
  }
  if (sizing !== null) return sized;
  // The agent home's own files, a list as a session's, in the same way (the hashes of the gathering before kept).
  let carriedHome: CarriedHome | null = null;
  if (agent !== null && existsSync(agent)) {
    const at = join(scratch, "lists", "agent-home.jsonl");
    before = new Map();
    if (existsSync(at)) for (const line of linesOf(at)) {
      try {
        const f = JSON.parse(line) as CarriedFile;
        if ("hash" in f) before.set(f.path, { size: f.size, mtimeMs: f.mtimeMs, hash: f.hash });
      } catch {}
    }
    seen = new Set();
    list = new ListFile(at);
    under = (path) => within(path, agent) && path !== agent;
    for (const path of homeFiles(agent)) add(path);
    const done = list;
    list = null;
    const hash = done.close();
    carriedHome = { dir: agent, list: hash, files: done.files, bytes: done.bytes, at };
    files += done.files;
    bytes += done.bytes;
  }
  const index: CarryIndex = { v: 2, dataDir, sessions, gits, skipped, jobs: [], bundles, files, bytes, agent: carriedHome };
  const path = indexFile(scratch);
  writeFileSync(`${path}.tmp`, JSON.stringify(index));
  renameSync(`${path}.tmp`, path);
  return { index: path, files, bytes, gits: gits.length, skipped: skipped.length, ...(unreadableCount > 0 ? { unreadable, unreadableCount } : {}) };
}

/// The files of an agent home that go along: its MEMORY.md and presets.json, and every skill of its skills/ that people
/// or agents made (none of the station's own, which it writes again at every start; none whose name begins with a dot
/// or is `synced`, its runtimes' and a sync's own; none linked there, the deployment's), each skill's files but what a
/// build or an install makes again. A link is not followed.
export function homeFiles(agent: string): string[] {
  const out: string[] = [];
  const file = (path: string) => {
    try {
      if (lstatSync(path).isFile()) out.push(path);
    } catch {}
  };
  file(join(agent, "MEMORY.md"));
  file(join(agent, "presets.json"));
  const skills = join(agent, "skills");
  const own = new Set([...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS]);
  const walk = (dir: string) => {
    let names: string[] = [];
    try {
      names = readdirSync(dir);
    } catch {}
    const here = new Set(names);
    for (const name of names.sort()) {
      const path = join(dir, name);
      let st;
      try {
        st = lstatSync(path);
      } catch {
        continue;
      }
      if (st.isDirectory()) {
        if (rebuiltByName(name, here) === null) walk(path);
      } else if (st.isFile()) out.push(path);
    }
  };
  let names: string[] = [];
  try {
    names = readdirSync(skills);
  } catch {}
  for (const name of names.sort()) {
    if (name.startsWith(".") || name === "synced" || own.has(name)) continue;
    try {
      if (!lstatSync(join(skills, name)).isDirectory()) continue;
    } catch {
      continue;
    }
    walk(join(skills, name));
  }
  return out;
}

/// What the index at `indexPath` says put under this station's data directory `dataDir`, each session's list and each
/// file's bytes read from `from` (`<hash>` each, put in place by `putFile`): where the retired station
/// had it, moved to here. One there already with the same size and time, or the same bytes, is left as it is, another
/// put in its place. A link to the retired station's data directory names this one's. What of it could not be put (its
/// bytes not brought) is counted. `made`: a file the paths it put where nothing was are written to, a line each (what a
/// hand-over that fails takes away again, handover.ts). `aside`: a directory what was there and is replaced is moved
/// into, the first time (`list.txt` says where each was: what a hand-over that fails puts back, handover.ts); none:
/// what is replaced is removed. `placed`: a file of what this placing put or found in place before (path, hash, size,
/// time), kept by it: one the index says the same of again is left without being looked at (a hand-over's second
/// pass touches only what changed since its first).
export function place(dataDir: string, indexPath: string, from: string, made: string | null = null, aside: string | null = null, placed: string | null = null, projects = false): { placed: number; missing: number; kept: number } {
  const index = JSON.parse(readFileSync(indexPath, "utf8")) as CarryIndex;
  // (what is there that is this placing's own already, made or put aside before: replaced, not put aside again)
  const ours = new Set<string>();
  for (const at of [made, aside === null ? null : join(aside, "list.txt")]) {
    if (at !== null && existsSync(at)) for (const line of linesOf(at)) if (line !== "") ours.add(line.split("\t")[0]!);
  }
  const known = new Map<string, string>();
  if (placed !== null && existsSync(placed)) for (const line of linesOf(placed)) {
    const tab = line.indexOf("\t");
    if (tab > 0) known.set(line.slice(0, tab), line.slice(tab + 1));
  }
  const placedFd = placed === null ? null : openSync(placed, "a");
  const same = (_path: string, f: { hash: string; size: number; mtimeMs: number }) => `${f.hash}\t${f.size}\t${Math.trunc(f.mtimeMs)}`;
  const seen = {
    before: (path: string, f: { hash: string; size: number; mtimeMs: number }) => known.get(path) === same(path, f),
    now: (path: string, f: { hash: string; size: number; mtimeMs: number }) => {
      if (placedFd !== null && known.get(path) !== same(path, f)) writeSync(placedFd, `${path}\t${same(path, f)}\n`);
    },
  };
  const madeFd = made === null ? null : openSync(made, "a");
  const fresh = (path: string) => {
    ours.add(path);
    if (madeFd !== null) writeSync(madeFd, `${path}\n`);
  };
  const away = (path: string) => {
    if (aside === null || ours.has(path)) return void rmSync(path, { recursive: true, force: true });
    mkdirSync(aside, { recursive: true });
    const name = `${createHash("sha256").update(path).digest("hex").slice(0, 32)}-${randomBytes(4).toString("hex")}`;
    renameSync(path, join(aside, name));
    appendFileSync(join(aside, "list.txt"), `${path}\t${name}\n`);
    ours.add(path);
  };
  try {
    return placeAll(index, dataDir, from, fresh, away, seen, projects);
  } finally {
    if (madeFd !== null) closeSync(madeFd);
    if (placedFd !== null) closeSync(placedFd);
  }
}

/// `path`'s real path, the part of it not there yet as it is: what a process working in it will see (`/private/tmp/…`
/// where it is behind a symlink).
function realOf(path: string): string {
  const rest: string[] = [];
  for (let at = path; ; at = dirname(at)) {
    try {
      return join(realpathSync(at), ...rest.reverse());
    } catch {
      if (dirname(at) === at) return path;
      rest.push(basename(at));
    }
  }
}

type Seen = { before(path: string, f: { hash: string; size: number; mtimeMs: number }): boolean; now(path: string, f: { hash: string; size: number; mtimeMs: number }): void };
function placeAll(index: CarryIndex, dataDir: string, from: string, fresh: (path: string) => void, away: (path: string) => void, seen: Seen | null = null, projects = false): { placed: number; missing: number; kept: number } {
  let placed = 0;
  let missing = 0;
  let kept = 0;
  const root = resolve(dataDir);
  for (const s of index.sessions) {
    const list = join(from, s.list);
    // (a chat handed over: its Claude transcripts under the project of its room here as the runtime sees it, its real
    // path, whatever project they were under there)
    const room = projects ? realOf(moved(s.workspace, index.dataDir, dataDir)) : null;
    if (!existsSync(list)) {
      missing += s.files;
      continue;
    }
    for (const line of linesOf(list)) {
      let f: CarriedFile;
      try {
        f = JSON.parse(line) as CarriedFile;
      } catch {
        continue;
      }
      // (resolved first: a path the other station said is put under this one's sessions or transcripts, or nowhere)
      // (`projects`, a chat handed over: a Claude transcript under its room's project here, where one there before
      // would otherwise be the one its agent resumes; a retirement's stays where it was put, found by its id)
      const path = resolve(projects ? carriedTo(f.path, index.dataDir, dataDir, room) : moved(f.path, index.dataDir, dataDir));
      if (!carriedPlace(root, path)) continue;
      // (placed by this placing before as the index says it now: not looked at again)
      if (!("link" in f) && seen?.before(path, f) === true) {
        kept++;
        continue;
      }
      let there = null;
      try {
        there = lstatSync(path);
      } catch {}
      if ("link" in f) {
        const target = isAbsolute(f.link) ? moved(f.link, index.dataDir, dataDir) : f.link;
        if (there !== null) {
          if (there.isSymbolicLink() && readlinkSync(path) === target) {
            kept++;
            continue;
          }
          away(path);
        }
        mkdirSync(dirname(path), { recursive: true });
        symlinkSync(target, path);
        if (there === null) fresh(path);
        placed++;
        continue;
      }
      if (there !== null && there.isFile() && there.size === f.size && (Math.trunc(there.mtimeMs) === Math.trunc(f.mtimeMs) || hashFile(path) === f.hash)) {
        seen?.now(path, f);
        kept++;
        continue;
      }
      const blob = join(from, f.hash);
      if (!existsSync(blob)) {
        missing++;
        continue;
      }
      mkdirSync(dirname(path), { recursive: true });
      const tmp = `${path}.${randomBytes(4).toString("hex")}.carrying`;
      putFile(blob, tmp);
      chmodSync(tmp, f.mode);
      utimesSync(tmp, f.mtimeMs / 1000, f.mtimeMs / 1000);
      if (there !== null) away(path);
      renameSync(tmp, path);
      if (there === null) fresh(path);
      seen?.now(path, f);
      placed++;
    }
  }
  return { placed, missing, kept };
}

/// A file sent (`blob`) put at `tmp` without copying its bytes: linked to it, where nothing else is linked to it yet.
/// One linked already (the same bytes at another path, or a placing cut between its link and its rename) is copied, so
/// that no two paths share a file (one written in place would change the other); so is one where the disk makes no
/// link (another volume, a file system without them, too many links). Node's copy with COPYFILE_FICLONE copies the
/// bytes on APFS (measured 2026-11-14: a station's disk filled as a retirement's 55 GB were placed), so no clone is
/// asked for.
export function putFile(blob: string, tmp: string): void {
  if (lstatSync(blob).nlink === 1) {
    try {
      linkSync(blob, tmp);
      return;
    } catch (e) {
      if (!["EXDEV", "EPERM", "ENOTSUP", "EMLINK", "ENOSYS"].includes((e as NodeJS.ErrnoException).code ?? "")) throw e;
    }
  }
  copyFileSync(blob, tmp);
}

