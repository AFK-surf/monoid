// What of a workspace's chats goes along beside their copy as a station is retired from it (retire.ts; replica/AGENTS.md),
// or a chat handed over (handover.ts): their agents' transcripts and each session's own directory (its room: the
// workspace, and an archived one's packed workspace beside it), gathered on the station they leave and put in place on
// the one they go to. Nothing in it is changed on the way: each file is taken by its bytes (by their hash, as a copy's
// files are) and put at the same place under the other station's data directory. A checkout's own repository (`.git` a
// directory) goes as its files; a linked worktree's is git's to make again there (retire.ts `rebuildGits`), from what
// the index says of it. What a build or an install makes again (footprint.ts `rebuildable`), and what git ignores,
// stays behind. Only what is under the data directory's `sessions/` and `transcripts*/` goes, or is put.
//
// The gathering, the placing and the preview are the MoonBit program's (`--builder replica-carry`, station/mb's
// src/replica/carry.mbt), a process of its own each, so none of their walking, hashing, git or linking is on the main
// thread; a cancel ends it at once. The program is built for every system a station runs on: there is no gathering in
// TypeScript to fall back to (the one it replaced, station/test/carry-reference.ts, is the tests' only, which the
// program is compared with: station/test/mb-replica-carry.test.ts).
//
// A station has a million files under `sessions/`: none of it is one object. Each session's files are a list of their
// own on disk (a line each), and what goes along is an index of the lists (`CarryIndex`); the main thread reads the
// index and streams the lists, and what goes between the two stations is a list's piece at a time (retire.ts).
import { createHash } from "node:crypto";
import { isAbsolute, join, relative, sep } from "node:path";
import { MbProcess, mbReaderBinary } from "../read/mb-reader.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL } from "../sessions/agent-home.ts";

/// A file that goes along, a line of its session's list: where it is (under the station's data directory), its bytes'
/// hash, how big, its mode and time; a symbolic link its target instead (nothing to send).
export type CarriedFile = { path: string; hash: string; size: number; mode: number; mtimeMs: number } | { path: string; link: string };
/// A linked git worktree of a working directory (its `.git` a file naming its repository elsewhere): where it is, the
/// remote it came from, its branch (null: detached), its commit, and its commits no remote has (a bundle's hash; null:
/// none).
export type CarriedGit = { dir: string; remote: string; branch: string | null; head: string; bundle: string | null };
/// A session whose things go along: its key, its working directory, its room (null: not in the station's layout, so
/// nothing of its directory goes); its list (the hash of its file, the name it is sent by), how many files and bytes
/// it names; `at`: where the list is on the station it was gathered on.
export type CarriedSession = { key: string; workspace: string; room: string | null; list: string; files: number; bytes: number; at: string };
/// A job or service a session had running as its chats stopped: what it takes to run it again on the station the chats
/// go to, as one runs again after its station restarted (jobs.ts `relaunch`): where it ran, its port (a web service),
/// whether it is a watch (retire.ts `#startJobs`). One gathered by a station from before has only its name and command,
/// and is not started again there (its agent is told it did not move).
export type CarriedJob = { session: string; name: string; command: string; cwd?: string; port?: number | null; watch?: boolean };
/// What of a workspace's agent home goes along (its MEMORY.md, presets.json and the skills people or agents made: not
/// the station's own, nor those of the deployment linked beside them): where it is on the station gathered on, and its
/// list as a session's (retire.ts merges it into the agent home there, agent-carry.ts).
export type CarriedHome = { dir: string; list: string; files: number; bytes: number; at: string };
/// What goes along with a workspace's chats, all but the files: `dataDir` the retired station's; each session and its
/// list; the linked worktrees; the sessions whose directory is not the station's own (a person's project), which stays;
/// the jobs that were running; where each worktree's bundle is on the station gathered on; its agent home (none in an
/// index of a station from before, or where it has none).
export type CarryIndex = { v: 2; dataDir: string; sessions: CarriedSession[]; gits: CarriedGit[]; skipped: string[]; jobs: CarriedJob[]; bundles: Record<string, string>; files: number; bytes: number; agent?: CarriedHome | null };
/// What a gathering answers (the rest is on disk): where its index is, and how much it names.
/// `unreadable`: the files (and directories) of what goes that this station could not read: none goes left out silently,
/// what gathered them says so (the first few; `unreadableCount` all of them).
export type Gathered = { index: string; files: number; bytes: number; gits: number; skipped: number; unreadable?: string[]; unreadableCount?: number };
/// What a placing answers: how many it put, how many it lacked the bytes of, how many were in place already.
export type Placed = { placed: number; missing: number; kept: number };
/// What a retirement of a workspace would take of its sessions here (retire.ts `preview`).
export type Counted = { chats: number; archived: number; outside: number };

/// Whether `path` is one that goes along, or is put: under `dataDir`'s `sessions/` or a `transcripts*/` of it.
export function carriedPlace(dataDir: string, path: string): boolean {
  const rel = relative(dataDir, path);
  if (rel === "" || rel.startsWith("..") || isAbsolute(rel)) return false;
  const parts = rel.split(sep);
  return parts.length > 1 && (parts[0] === "sessions" || parts[0]!.startsWith("transcripts"));
}

/// Where a gathering keeps its index and its lists, in `scratch`.
export const indexFile = (scratch: string) => join(scratch, "index.json");
export const listFile = (scratch: string, key: string) => join(scratch, "lists", `${createHash("sha256").update(key).digest("hex").slice(0, 32)}.jsonl`);

/// The agent home's skills that are the station's own, which it writes again at every start: none of them goes along.
const OWN_SKILLS = [...BUILTIN_SKILLS, FEEDBACK_SKILL];

/// One ask of the program (`--builder replica-carry`): its answer, or its error; ended at once where `signal` says (a
/// cancel: "called off"). `binary`: the program (mbReaderBinary unless a test says).
export function inProgram<T>(asked: Record<string, unknown> & { dataDir: string }, signal?: AbortSignal, binary: string | null = mbReaderBinary()): Promise<T> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(new Error("called off"));
    if (binary === null) return reject(new Error("the station's MoonBit program (stillfail-reader) is not here: its files cannot be gathered or placed"));
    const p = new MbProcess(binary, ["--builder", "replica-carry", "--sep", sep, "--shell-dir", join(asked.dataDir, "shell")]);
    let settled = false;
    const done = (f: () => void) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener("abort", stop);
      f();
    };
    const stop = () => done(() => {
      p.kill();
      reject(new Error("called off"));
    });
    signal?.addEventListener("abort", stop, { once: true });
    p.on("message", (m: { answer?: T; error?: string }) => done(() => (m.error !== undefined ? reject(new Error(m.error)) : resolve(m.answer as T))));
    p.on("error", (e: Error) => done(() => reject(e)));
    p.on("exit", (code: number) => done(() => reject(new Error(`the gathering's program ended saying nothing (${code})`))));
    p.postMessage(asked);
  });
}

/// What goes along with the chats of `ws` on the station whose data directory is `dataDir`: their transcripts and each
/// one's room, a git checkout in it as git lists its files (tracked and not ignored) with its repository, a linked
/// worktree's commits no remote has in a bundle; written in `scratch` (a list a session, the index of them). A file of
/// the gathering before that has the same size and time is not read again (its hash from that session's list then).
/// `agent`: the workspace's agent home here, whose own files go along too (its MEMORY.md and presets.json, and every
/// skill people or agents made: none of the station's own, none whose name begins with a dot or is `synced`, none linked
/// there). `keys`: those sessions alone, not the workspace's (a chat handed over: its scratch is its own).
export const gatherSoon = (dataDir: string, db: string, ws: string, home: boolean, scratch: string, signal?: AbortSignal, agent: string | null = null, keys: readonly string[] | null = null) =>
  inProgram<Gathered>({ op: "gather", dataDir, db, ws, home, scratch, agent, keys, own: OWN_SKILLS }, signal);

/// What the index at `index` says put under this station's data directory `dataDir`, each session's list and each
/// file's bytes read from `from` (`<hash>` each, linked into place where nothing else links it, else copied: two paths
/// never share a file): where the retired station had it, moved to here. One there already with the same size and
/// time, or the same bytes, is left as it is, another put in its place. A link to the retired station's data directory
/// names this one's. What of it could not be put (its bytes not brought) is counted. `made`: a file the paths it put
/// where nothing was are written to, a line each (what a hand-over that fails takes away again, handover.ts). `aside`:
/// a directory what was there and is replaced is moved into, the first time (`list.txt` says where each was: what a
/// hand-over that fails puts back, handover.ts); none: what is replaced is removed. `placed`: a file of what this placing
/// put or found in place before (path, hash, size, time), kept by it: one the index says the same of again is left
/// without being looked at (a hand-over's second pass touches only what changed since its first). `projects` (a chat
/// handed over): its Claude transcripts under its room's project here.
export const placeSoon = (dataDir: string, index: string, from: string, made: string | null = null, aside: string | null = null, placed: string | null = null, projects = false) =>
  inProgram<Placed>({ op: "place", dataDir, index, from, made, aside, placed, projects });

/// What a retirement of `ws` would take of its sessions here, as the app shows it first (retire.ts `preview`): how many
/// chats, archived or not, and how many have a directory that is not the station's own (the gathering's `skipped`),
/// found as the gathering finds it, no directory walked.
export const previewSoon = (dataDir: string, db: string, ws: string, home: boolean) => inProgram<Counted>({ op: "preview", dataDir, db, ws, home });
