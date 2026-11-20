// The agents' memory, one for every station of a workspace (the user, 2026-11-14: 「直接全局共享，跟 station 相关的直接说明是
// 哪个 station」): its MEMORY.md and its skills (the team's own, not the station's built-in ones, not a link: a deployment's,
// a skill borrowed from another station's share) are the same on each, kept level between them over the station
// transport (`memory.get`, `memory.blobs`, `memory.put`). What is of one machine alone says which station it is of
// (the agents' instructions tell them so). Nobody shares anything or is asked: a station from before answers none of
// it and keeps its own as before.
//
// - Each file is a record (`Rec`): its content's hash ("" once deleted), when it was made by a clock that only rises
//   (the machine's time, or past the latest seen), the station that made it, and the hashes it was made after (`prev`),
//   so a station tells a version that comes after its own from one made beside it. The content of each version it keeps
//   is in blobs/ by hash, a file's recent ones too (what a merge reads as the version both were made from).
// - An edit here is found by the station looking at the files (a watch, settled a moment) and made a record of its own.
//   A version from another station that comes after this one's is written over it; one made beside it is merged
//   (station/mb src/memory, the MoonBit program's: memory-mb.ts), each station computing the same from the same two, so
//   they come to one with no station to decide. The files are read, hashed and kept in blobs/ there too, none of their
//   bytes on the station's thread but those it writes or sends.
// - No station is the one to follow: a station off keeps its copy, and is brought level when it is back. What a station
//   was given goes on to the others as anything changed here does.
// - Each workspace's own: a station in two keeps each one's apart (sessions/agent-home.ts `workspaceAgentHome`), and
//   gives one only to the stations of its workspace (the transport says which a request is of).
import { createHash } from "node:crypto";
import type { Dirent } from "node:fs";
import { chmod, copyFile, lstat, mkdir, readdir, readFile, rename, rmdir, unlink, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Clock } from "effect";
import type { Cloud } from "../cloud/state.ts";
import { Fibers } from "../ops/fibers.ts";
import { PrivateFile, writePrivateSoon } from "../ops/files.ts";
import { FollowedTree, type Watch } from "../ops/follow.ts";
import { log } from "../ops/log.ts";
import { portableName } from "../ops/paths.ts";
import { BUILTIN_SKILLS, FEEDBACK_SKILL, RETIRED_SKILLS, workspaceAgentHome } from "../sessions/agent-home.ts";
import { MemoryProgram } from "./memory-mb.ts";

type Json = any;

/// A file of the memory, as each station keeps and tells it. `hash` "" once deleted; `size` of its content; `mode` its
/// permission bits (0o644 or 0o755: a file of a skill only its owner may read, a key's, stays on its machine; MEMORY.md
/// is shared whatever its own); `origin`: what a station had before the memory was shared (its first
/// look), merged with another such without a version both were made from.
export type Rec = { hash: string; at: number; by: string; prev: string[]; size: number; mode: number; origin?: true };
type Kept = { clock: number; files: Record<string, Rec> };

/// A file is shared up to this size, a skill up to SKILL_MOST bytes and SKILL_FILES files: past them it is kept here
/// as it is and not sent (its copies elsewhere stay as they were).
const FILE_MOST = 512 * 1024;
const SKILL_MOST = 4 * 1024 * 1024;
const SKILL_FILES = 200;
/// A request carries at most this many bytes of content (the station transport takes 1 MB a request, base64 inflating).
const BATCH_BYTES = 600 * 1024;
/// The versions of a file kept after its present one.
const PREV_MOST = 16;
/// Edits are looked at once they have settled this long.
const SETTLE_MS = 2000;
/// A station not brought level is tried again after this, twice as long each time up to RETRY_MOST_MS.
export const RETRY_MS = 5_000;
const RETRY_MOST_MS = 10 * 60_000;
/// What a station writes in a MEMORY.md of nothing yet (agent-home.ts and stations of before): no memory of its own.
const EMPTY = new Set(["", "# still.fail memory", "# ember memory"]);
/// What is never part of a skill as shared: what a program makes beside its files.
export const SKIPPED = new Set(["__pycache__", "node_modules", ".venv", ".git", ".DS_Store"]);
/// The most directories of the agents' home watched (an inotify watch each on Linux, of the user's
/// fs.inotify.max_user_watches, 8192 on older kernels, shared with every program of theirs).
const FOLLOW_MOST = 1000;

const sha = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const HEX64 = /^[0-9a-f]{64}$/;
const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);
const BUILTIN = new Set([...BUILTIN_SKILLS, FEEDBACK_SKILL, ...RETIRED_SKILLS]);
/// A file only its owner may read (a key, a host's address kept beside a skill): this machine's alone, never shared.
const own = (m: number) => (m & 0o077) === 0;

/// Whether `path` names a file of the memory: MEMORY.md, or a file under skills/<name>/ of a team's skill (no built-in
/// one's), each component a portable name and none hidden.
export function memoryPath(path: unknown): path is string {
  if (typeof path !== "string" || path.length > 512) return false;
  if (path === "MEMORY.md") return true;
  const parts = path.split("/");
  if (parts.length < 3 || parts[0] !== "skills" || BUILTIN.has(parts[1]!)) return false;
  return parts.slice(1).every((p) => portableName(p) && !SKIPPED.has(p));
}

/// A record as a peer tells it; null when it is none.
export function recOf(raw: unknown): Rec | null {
  if (!isObject(raw)) return null;
  const { hash, at, by, prev, size, mode } = raw;
  if (typeof hash !== "string" || (hash !== "" && !HEX64.test(hash)) || !Number.isSafeInteger(at) || at < 0) return null;
  if (typeof by !== "string" || !HEX64.test(by) || !Array.isArray(prev) || prev.length > PREV_MOST * 2 || !prev.every((h) => typeof h === "string" && HEX64.test(h))) return null;
  if (!Number.isSafeInteger(size) || size < 0 || size > FILE_MOST || ![0o644, 0o755].includes(mode)) return null;
  return { hash, at, by, prev: [...prev], size, mode, ...(raw.origin === true ? { origin: true as const } : {}) };
}

const history = (r: Rec) => [r.hash, ...r.prev].filter((h) => h !== "");
const after = (r: Rec, prev: string[]) => [...new Set([r.hash, ...prev, ...r.prev].filter((h) => h !== ""))].slice(0, PREV_MOST);

/// What one station's record of a file and another's make, as the program decides it (mb/src/memory decide.mbt): the
/// one that comes after the other, or, made beside each other, a merge both stations compute alike (its content kept in
/// blobs/ by then; `beside`: the other's version kept beside it, where it could not be merged).
type Outcome = { kind: "keep" } | { kind: "take"; content: boolean } | { kind: "merge"; rec: Rec; beside: { path: string; rec: Rec } | null };

/// What the program found of a file of the memory (mb/src/memory files.mbt `scan`): its content's hash (kept in
/// blobs/ where it changed), size, shared mode and mtime; `empty`: a MEMORY.md of nothing yet, not kept.
type Found = { path: string; hash: string; size: number; mode: number; mtime: number; empty?: true };

export type MemoryDeps = {
  data: string;
  /// Which stations are in each of the station's workspaces, and this one's id and name.
  cloud: Cloud;
  /// A request to another station of workspace `workspace` (the station transport).
  ask: (station: string, workspace: string, request: Json) => Promise<Json>;
  /// The agents' home (its MEMORY.md and skills/ are the home workspace's, a joined one's in workspaces/<id>).
  agentHome: () => string;
  clock?: Clock.Clock;
  /// Tests: nothing set going by itself (no watch, no station brought level but by `levelNow`).
  still?: boolean;
  /// Tests: a directory's watch (ops/follow.ts).
  watch?: Watch;
  /// Tests: the MoonBit program (readerBinary's where none is given).
  binary?: string;
};

/// Whether the agents' home's directory at `rel` is followed: skills/ and what is shared of each skill in it, of the home
/// workspace and of each joined one (workspaces/<id>/skills/…), MEMORY.md being seen by its directory's watch. Nothing
/// else in the home (a repository, a cache an agent put there) is listed or watched.
export function memoryFollowed(rel: string): boolean {
  const parts = rel.split("/");
  let i = 0;
  if (parts[0] === "workspaces") {
    if (parts.length === 1) return true;
    if (!/^[0-9A-Za-z_-]{1,128}$/.test(parts[1]!)) return false;
    if (parts.length === 2) return true;
    i = 2;
  }
  if (parts[i] !== "skills") return false;
  if (parts.length === i + 1) return true;
  if (BUILTIN.has(parts[i + 1]!)) return false;
  return parts.slice(i + 1).every((n) => portableName(n) && !SKIPPED.has(n));
}

/// A station from before the memory was shared: nothing to bring level with it.
/// (Before 0.1.9133 a station answers a method it does not know as a task's request it lacks the keys of.)
const before = (e: unknown) => /unsupported peer method|unknown memory method|session and task key are required/i.test((e as Error)?.message ?? "");

export class MemorySync {
  readonly #deps: MemoryDeps;
  readonly #time: Fibers;
  readonly #program: MemoryProgram;
  readonly #kept = new Map<string, Kept>();
  readonly #files = new Map<string, PrivateFile>();
  /// One look, merge or write at a time a workspace: what the station does to its files there goes in this order.
  readonly #lanes = new Map<string, Promise<unknown>>();
  readonly #levelAt = new Map<string, string>();
  readonly #going = new Set<string>();
  readonly #retries = new Map<string, { wait: number; due: boolean; cancel: () => void }>();
  readonly #settle = new Map<string, () => void>();
  #tree: FollowedTree | null = null;
  #followRetry: { wait: number; due: boolean; cancel: () => void } | null = null;
  #followOver = false;
  #stops: (() => void)[] = [];
  #stopped = false;

  constructor(deps: MemoryDeps) {
    this.#deps = deps;
    this.#time = new Fibers("memory", deps.clock);
    this.#program = new MemoryProgram(this.#root(), deps.binary === undefined ? {} : { binary: deps.binary });
  }

  /// The program let go if nothing is asked of it (read/pool.ts `onTrim`): 1, else 0.
  trimIdle(): number {
    return this.#program.trimIdle();
  }

  get #me(): string {
    return this.#deps.cloud.state?.station ?? "";
  }

  #root(): string {
    return join(this.#deps.data, "share", "memory");
  }

  /// Where workspace `ws`'s memory is, made where it is a joined one's not made yet.
  #home(ws: string): Promise<string> {
    return workspaceAgentHome(this.#deps.agentHome(), ws, this.#deps.cloud.home());
  }

  /// A station's name in `ws` as its roster says (the same on every station of it): what marks its lines and names a
  /// version kept beside another.
  #nameOf(ws: string, station: string): string {
    const peers = this.#deps.cloud.membership(ws)?.peers ?? [];
    const named = peers.find((p: Json) => p?.id === station)?.name;
    if (typeof named === "string" && named.trim() !== "") return named.trim();
    if (station === this.#me && typeof this.#deps.cloud.state?.name === "string" && this.#deps.cloud.state.name.trim() !== "") return this.#deps.cloud.state.name.trim();
    return station.slice(0, 8);
  }

  #lane<A>(ws: string, f: () => Promise<A>): Promise<A> {
    const run = (this.#lanes.get(ws) ?? Promise.resolve()).then(f, f);
    this.#lanes.set(ws, run.catch(() => undefined));
    return run;
  }

  // ── what is kept ──

  async #state(ws: string): Promise<Kept & { fresh: boolean }> {
    const had = this.#kept.get(ws);
    if (had) return { ...had, fresh: false };
    let kept: Kept | null = null;
    try {
      const raw = JSON.parse(await readFile(join(this.#root(), `${ws}.json`), "utf8"));
      const files: Record<string, Rec> = {};
      for (const [path, r] of Object.entries(isObject(raw?.files) ? raw.files : {})) {
        const rec = recOf(r);
        if (rec !== null && memoryPath(path)) files[path] = rec;
      }
      kept = { clock: Number.isSafeInteger(raw?.clock) ? raw.clock : 0, files };
    } catch {}
    const fresh = kept === null;
    kept ??= { clock: 0, files: {} };
    this.#kept.set(ws, kept);
    return { ...kept, fresh };
  }

  #save(ws: string): void {
    const kept = this.#kept.get(ws);
    if (!kept) return;
    let file = this.#files.get(ws);
    if (!file) this.#files.set(ws, (file = new PrivateFile(join(this.#root(), `${ws}.json`))));
    void file.write(JSON.stringify(kept)).catch((e) => log.warn("memory", "the memory's records not written", { workspace: ws, error: (e as Error).message }));
  }

  /// Once what was kept is written (tests).
  async written(): Promise<void> {
    await Promise.all([...this.#lanes.values()]);
    await Promise.all([...this.#files.values()].map((f) => f.written()));
  }

  #tick(ws: string, atLeast = 0): number {
    const kept = this.#kept.get(ws)!;
    kept.clock = Math.max(kept.clock + 1, this.#time.now(), atLeast);
    return kept.clock;
  }

  #blob(hash: string): string {
    return join(this.#root(), "blobs", hash);
  }

  async #content(hash: string): Promise<Buffer | null> {
    if (hash === "") return null;
    try {
      const bytes = await readFile(this.#blob(hash));
      return sha(bytes) === hash ? bytes : null;
    } catch {
      return null;
    }
  }

  /// `bytes`, of version `hash`, kept unless they are already.
  async #keepBlob(hash: string, bytes: Buffer): Promise<void> {
    try {
      await lstat(this.#blob(hash));
    } catch {
      await writePrivateSoon(this.#blob(hash), bytes);
    }
  }

  /// A version's bytes to write: what a peer brought, else what blobs/ keeps of it (the program read it or made it
  /// there); null when neither has it.
  async #bytes(hash: string, given: Map<string, Buffer>): Promise<Buffer | null> {
    return given.get(hash) ?? (await readFile(this.#blob(hash)).catch(() => null));
  }

  // ── the files as they are ──

  /// The memory's files in `dir` as they are now, in the order they were read, those changed since the station kept
  /// them kept in blobs/, and the skills that are not shared as they are (too large, a link): their records stay as they
  /// were. Read by the program (mb/src/memory files.mbt `scan`, as test/reference/memory-merge.ts `readMemory`).
  async #read(dir: string, kept: Record<string, Rec>): Promise<{ files: Map<string, Found>; held: Set<string> }> {
    const answer = await this.#program.ask<{ files: Found[]; held: string[] }>("scan", {
      dir, blobs: join(this.#root(), "blobs"), kept: Object.fromEntries(Object.entries(kept).map(([p, r]) => [p, r.hash])),
      builtin: [...BUILTIN], skipped: [...SKIPPED], fileMost: FILE_MOST, skillMost: SKILL_MOST, skillFiles: SKILL_FILES,
    });
    return { files: new Map(answer.files.map((f) => [f.path, f])), held: new Set(answer.held) };
  }

  /// Records made of what changed in `ws`'s files since the last look (whether any did).
  async #look(ws: string): Promise<boolean> {
    const state = await this.#state(ws);
    const kept = this.#kept.get(ws)!;
    const me = this.#me;
    if (me === "") return false;
    const { files, held } = await this.#read(await this.#home(ws), kept.files);
    const isHeld = (path: string) => held.has(path) || [...held].some((h) => h.endsWith("/") && path.startsWith(h));
    let changed = false;
    for (const [path, f] of files) {
      const hash = f.hash;
      const rec = kept.files[path];
      if (rec?.hash === hash) continue;
      if (rec === undefined && path === "MEMORY.md" && f.empty === true) continue;
      // What it had before the memory was shared (its first look) goes as when it was last changed; anything after, as now.
      const origin = state.fresh && rec === undefined;
      const at = origin ? this.#tick(ws, f.mtime) : this.#tick(ws);
      kept.files[path] = { hash, at, by: me, prev: rec === undefined ? [] : after(rec, []), size: f.size, mode: f.mode, ...(origin ? { origin: true as const } : {}) };
      changed = true;
    }
    for (const [path, rec] of Object.entries(kept.files)) {
      if (rec.hash === "" || files.has(path) || isHeld(path)) continue;
      kept.files[path] = { hash: "", at: this.#tick(ws), by: me, prev: after(rec, []), size: 0, mode: rec.mode };
      changed = true;
    }
    if (await this.#mend(ws)) changed = true;
    if (changed || state.fresh) this.#save(ws);
    return changed;
  }

  /// What stations of 0.1.9133 to 0.1.9168 left of skills kept apart, mended as each looks, each station alike: two or
  /// more kept apart from one skill with one body (a station had taken another's copy first and named it for itself,
  /// `stillfail-MBA` beside `stillfail-Mini1`) come to one, the one named for the station whose record it is (else the
  /// first by name), the others deleted as an agent would delete them; and a file only its owner reads that was moved
  /// into one kept apart is put back beside the skill it came from as well (where what is outside the station reads it).
  async #mend(ws: string): Promise<boolean> {
    const kept = this.#kept.get(ws)!;
    // Skills kept apart: `<base>-<tag>` whose front matter names it so and says `[<station>]` of that tag (each
    // SKILL.md read by the program: mb/src/memory answer.mbt `asides`).
    const skills: { skill: string; hash: string; author: string }[] = [];
    for (const [path, rec] of Object.entries(kept.files)) {
      const m = /^skills\/([^/]+)\/SKILL\.md$/.exec(path);
      if (m === null || rec.hash === "") continue;
      skills.push({ skill: m[1]!, hash: rec.hash, author: this.#nameOf(ws, rec.by) });
    }
    const aside = skills.length === 0 ? [] : (await this.#program.ask<{ asides: { skill: string; base: string; tag: string; author: string; body: string }[] }>("asides", { blobs: join(this.#root(), "blobs"), skills })).asides;
    let changed = false;
    const gone = new Set<string>();
    const groups = new Map<string, typeof aside>();
    for (const a of aside) groups.set(`${a.base}\0${a.body}`, [...(groups.get(`${a.base}\0${a.body}`) ?? []), a]);
    for (const group of groups.values()) {
      if (group.length < 2) continue;
      group.sort((x, y) => Number(y.tag === y.author) - Number(x.tag === x.author) || (x.skill < y.skill ? -1 : 1));
      for (const extra of group.slice(1)) {
        for (const [path, r] of Object.entries(kept.files)) {
          if (!path.startsWith(`skills/${extra.skill}/`) || r.hash === "") continue;
          if (await this.#write(ws, path, { hash: "", at: this.#tick(ws), by: this.#me, prev: after(r, []), size: 0, mode: r.mode }, null)) changed = true;
        }
        gone.add(extra.skill);
        log.info("memory", "a skill kept apart twice made one", { workspace: ws, kept: group[0]!.skill, gone: extra.skill });
      }
    }
    for (const a of aside) {
      if (gone.has(a.skill)) continue;
      const from = join(await this.#home(ws), "skills", a.skill);
      const to = join(await this.#home(ws), "skills", a.base);
      try {
        if (!(await lstat(to)).isDirectory()) continue;
      } catch {
        continue;
      }
      let entries: Dirent[] = [];
      try {
        entries = await readdir(from, { withFileTypes: true });
      } catch {}
      for (const e of entries) {
        if (!e.isFile()) continue;
        const st = await lstat(join(from, e.name));
        if (!own(st.mode)) continue;
        try {
          await lstat(join(to, e.name));
          continue;
        } catch {}
        await copyFile(join(from, e.name), join(to, e.name)).then(() => chmod(join(to, e.name), st.mode & 0o777)).catch((err) => log.warn("memory", "a file of a skill kept apart not put back", { skill: a.skill, file: e.name, error: (err as Error).message }));
      }
    }
    return changed;
  }

  /// `rec`'s version of `path` written in `ws`'s files (deleted where it is), unless the file changed since the last look
  /// (an edit not yet looked at: it is looked at first, and merged). Whether it was.
  async #write(ws: string, path: string, rec: Rec, content: Buffer | null): Promise<boolean> {
    const kept = this.#kept.get(ws)!;
    const dir = await this.#home(ws);
    const full = join(dir, ...path.split("/"));
    const parts = path.split("/");
    // A skill this station has as a link (a deployment's, one borrowed from a share) stays as it is: the record is kept.
    if (parts[0] === "skills") {
      try {
        if ((await lstat(join(dir, "skills", parts[1]!))).isSymbolicLink()) {
          kept.files[path] = rec;
          return true;
        }
      } catch {}
    }
    const nowHash = (await this.#program.ask<{ hash: string | null }>("hash", { path: full })).hash ?? "";
    const was = kept.files[path];
    // (a MEMORY.md of nothing yet is read only where it may be one: no record of it, something there)
    const empty = async () => EMPTY.has(((await readFile(full).catch(() => null))?.toString("utf8") ?? "\0").trim());
    if (nowHash !== (was?.hash ?? "") && !(was === undefined && path === "MEMORY.md" && nowHash !== "" && (await empty()))) {
      // Edited here since it was looked at: looked at again (and merged, made beside it) before anything is written.
      this.#again(ws);
      return false;
    }
    if (content === null) {
      await unlink(full).catch(() => undefined);
      // Its directories, emptied, go too (up to the skill's).
      for (let d = dirname(full); parts[0] === "skills" && d.length > join(dir, "skills").length; d = dirname(d)) {
        if (!(await rmdir(d).then(() => true, () => false))) break;
      }
    } else {
      await mkdir(dirname(full), { recursive: true });
      const tmp = `${full}.${process.pid}.memory-tmp`;
      await writeFile(tmp, content, { mode: rec.mode });
      await chmod(tmp, rec.mode);
      await rename(tmp, full);
      await this.#keepBlob(rec.hash, content);
    }
    kept.files[path] = rec;
    return true;
  }

  /// What another station said of `ws`'s files taken here: each version that comes after this one's written, each made
  /// beside it merged. `given`: the versions' content it brought. Whether anything here changed.
  async #take(ws: string, theirs: Record<string, Rec>, given: Map<string, Buffer>): Promise<boolean> {
    const kept = this.#kept.get(ws)!;
    let changed = await this.#apart(ws, theirs, given);
    for (const [path, rec] of Object.entries(theirs)) {
      const mine = kept.files[path];
      // What it brought of the versions this decision may read (the rest are blobs/'s), and the stations' names.
      const brought: Record<string, string> = {};
      for (const h of new Set([rec.hash, ...rec.prev, ...history(mine ?? rec)])) {
        const b = given.get(h);
        if (b !== undefined) brought[h] = b.toString("hex");
      }
      const names: Record<string, string> = { [rec.by]: this.#nameOf(ws, rec.by), ...(mine ? { [mine.by]: this.#nameOf(ws, mine.by) } : {}) };
      const outcome = await this.#program.ask<Outcome>("decide", { path, mine: mine ?? null, theirs: rec, names, given: brought, blobs: join(this.#root(), "blobs"), prevMost: PREV_MOST });
      if (outcome.kind === "keep") continue;
      if (outcome.kind === "take") {
        // (`content`: the program found it, brought or kept, as what it is)
        const content = rec.hash === "" || !outcome.content ? null : await this.#bytes(rec.hash, given);
        if (rec.hash !== "" && content === null) continue;
        if (kept.files[path]?.hash === rec.hash) kept.files[path] = rec;
        else if (!(await this.#write(ws, path, rec, content))) continue;
        kept.clock = Math.max(kept.clock, rec.at);
        changed = true;
        continue;
      }
      const content = await this.#bytes(outcome.rec.hash, given);
      if (content === null) continue;
      if (!(await this.#write(ws, path, outcome.rec, content))) continue;
      kept.clock = Math.max(kept.clock, outcome.rec.at);
      const beside = outcome.beside !== null && memoryPath(outcome.beside.path) ? outcome.beside : null;
      if (beside !== null && kept.files[beside.path]?.hash !== beside.rec.hash) {
        const lc = await this.#bytes(beside.rec.hash, given);
        if (lc !== null) await this.#write(ws, beside.path, beside.rec, lc);
      }
      log.info("memory", "a file of the memory made apart merged", { workspace: ws, path, beside: beside?.path ?? null });
      changed = true;
    }
    if (changed) this.#save(ws);
    return changed;
  }

  /// Skills two stations each had before the memory was shared, of one name and nothing alike (Mini1's `stillfail` its
  /// own machine's, ccvm's the project's): not merged, the smaller (the station of the lesser id, of two alike) kept as
  /// a skill of its own, `<name>-<station>`, its SKILL.md saying so. Each station comes to the same: the one whose
  /// skill it is moves its own aside and takes the other's; the other leaves its own and takes the moved one beside it.
  /// Their records of the name are taken out of `theirs` where this station's stays. Whether anything here changed.
  async #apart(ws: string, theirs: Record<string, Rec>, given: Map<string, Buffer>): Promise<boolean> {
    const kept = this.#kept.get(ws)!;
    const me = this.#me;
    const skillsOf = (files: Record<string, Rec>) => {
      const out = new Map<string, [string, Rec][]>();
      for (const [path, r] of Object.entries(files)) {
        const parts = path.split("/");
        if (parts[0] !== "skills" || r.hash === "") continue;
        out.set(parts[1]!, [...(out.get(parts[1]!) ?? []), [path, r]]);
      }
      return out;
    };
    const mineBy = skillsOf(kept.files);
    let changed = false;
    for (const [name, their] of skillsOf(theirs)) {
      const mine = mineBy.get(name);
      if (mine === undefined) continue;
      const skillMd = `skills/${name}/SKILL.md`;
      const ms = kept.files[skillMd];
      const ts = theirs[skillMd];
      if (!ms || !ts || ms.hash === ts.hash || [...mine, ...their].some(([, r]) => r.origin !== true)) continue;
      if (history(ms).some((h) => history(ts).includes(h))) continue;
      // One skill each kept on (copied once, edited on both since): merged file by file, not kept apart.
      const tb = given.get(ts.hash);
      const { alike } = await this.#program.ask<{ alike: boolean | null }>("alikeKept", { blobs: join(this.#root(), "blobs"), a: ms.hash, b: ts.hash, given: tb === undefined ? {} : { [ts.hash]: tb.toString("hex") } });
      if (alike !== false) continue;
      const size = (files: [string, Rec][]) => files.reduce((n, [, r]) => n + r.size, 0);
      const [sm, st] = [size(mine), size(their)];
      const mineAside = sm !== st ? sm < st : me < ts.by;
      // Named for the station that made it, not the one keeping it (a station that took another's copy first).
      const owner = (mineAside ? ms : ts).by;
      const aside = `${name}-${(await this.#program.ask<{ tags: string[] }>("tags", { names: [this.#nameOf(ws, owner)] })).tags[0]}`;
      if (!portableName(aside) || BUILTIN.has(aside)) continue;
      const moved: [string, Rec, Buffer][] = [];
      for (const [path, r] of mineAside ? mine : their) {
        const content = mineAside ? await this.#content(r.hash) : (given.get(r.hash) ?? (await this.#content(r.hash)));
        if (content === null) {
          moved.length = 0;
          break;
        }
        const to = `skills/${aside}/${path.slice(`skills/${name}/`.length)}`;
        const bytes = path === skillMd ? asideSkill(content, aside, this.#nameOf(ws, owner)) : content;
        moved.push([to, { hash: sha(bytes), at: r.at, by: r.by, prev: [], size: bytes.length, mode: r.mode, origin: true }, bytes]);
      }
      if (moved.length === 0) continue;
      for (const [to, r, bytes] of moved) if (kept.files[to]?.hash !== r.hash && !(await this.#write(ws, to, r, bytes))) return changed;
      if (mineAside) {
        // Its own moved aside: gone from under the name with no record of it, for the other's to come in as new.
        for (const [path, r] of mine) if (await this.#write(ws, path, { ...r, hash: "" }, null)) delete kept.files[path];
        await this.#copyRest(ws, name, aside);
      } else for (const [path] of their) delete theirs[path];
      log.info("memory", "two skills of one name kept apart", { workspace: ws, skill: name, aside });
      changed = true;
    }
    return changed;
  }

  /// What is left of skill `name` here once its shared files moved aside (a file only its owner reads, which never
  /// leaves this machine): copied beside them, where the skill says it is, and left where it was too, since what is
  /// outside the station may read it there (Mini1's release job reads `skills/stillfail/station-update-host`).
  async #copyRest(ws: string, name: string, aside: string): Promise<void> {
    const from = join(await this.#home(ws), "skills", name);
    const to = join(await this.#home(ws), "skills", aside);
    const walk = async (rel: string): Promise<void> => {
      let entries: Dirent[] = [];
      try {
        entries = await readdir(join(from, rel), { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        const sub = rel === "" ? e.name : join(rel, e.name);
        if (e.isDirectory()) await walk(sub);
        else if (e.isFile()) {
          try {
            await lstat(join(to, sub));
            continue;
          } catch {}
          await mkdir(dirname(join(to, sub)), { recursive: true });
          try {
            await copyFile(join(from, sub), join(to, sub));
            await chmod(join(to, sub), (await lstat(join(from, sub))).mode & 0o777);
          } catch (err) {
            log.warn("memory", "a file of a skill kept apart not copied beside it", { skill: name, file: sub, error: (err as Error).message });
          }
        }
      }
    };
    await walk("");
  }

  // ── between the stations ──

  /// A peer's `memory.*` request in workspace `ws` (the transport checked it is of it).
  async handle(_peer: string, request: Json, ws: string | undefined): Promise<Json> {
    if (!ws || this.#deps.cloud.membership(ws) === null) throw new Error("not a workspace of this station's");
    switch (request?.method) {
      case "memory.get":
        return this.#lane(ws, async () => {
          await this.#look(ws);
          return { files: this.#kept.get(ws)!.files };
        });
      case "memory.blobs": {
        const out: Record<string, string> = {};
        let bytes = 0;
        for (const h of Array.isArray(request.hashes) ? request.hashes : []) {
          if (typeof h !== "string" || !HEX64.test(h) || bytes > BATCH_BYTES) continue;
          // Only what a record of this workspace names: nothing of another's.
          if (!Object.values(this.#kept.get(ws)?.files ?? {}).some((r) => r.hash === h || r.prev.includes(h))) continue;
          const c = await this.#content(h);
          if (c !== null) (out[h] = c.toString("base64")), (bytes += c.length);
        }
        return { blobs: out };
      }
      case "memory.put":
        return this.#lane(ws, async () => {
          await this.#look(ws);
          const theirs: Record<string, Rec> = {};
          for (const [path, raw] of Object.entries(isObject(request.files) ? request.files : {})) {
            const rec = recOf(raw);
            if (rec === null || !memoryPath(path)) throw new Error("a malformed record of the memory");
            theirs[path] = rec;
          }
          const given = new Map<string, Buffer>();
          for (const [h, b64] of Object.entries(isObject(request.blobs) ? request.blobs : {})) {
            const bytes = Buffer.from(String(b64), "base64");
            if (sha(bytes) === h) given.set(h, bytes);
          }
          if (await this.#take(ws, theirs, given)) this.#again(ws);
          return { taken: true };
        });
    }
    throw new Error("unknown memory method");
  }

  /// Brings `peer` and this station level in `ws`: what it has that comes after or beside this station's taken here,
  /// then what this station has that it lacks given it.
  /// Answers the word of this station's records it gave from: one looked at while `memory.put` was under way is not
  /// counted as given.
  async #level(peer: string, ws: string): Promise<string> {
    const ask = this.#deps.ask;
    const got: Json = await ask(peer, ws, { method: "memory.get" });
    const theirs: Record<string, Rec> = {};
    for (const [path, raw] of Object.entries(isObject(got?.files) ? got.files : {})) {
      const rec = recOf(raw);
      if (rec !== null && memoryPath(path)) theirs[path] = rec;
    }
    const { give, synced } = await this.#lane(ws, async () => {
      await this.#look(ws);
      const kept = this.#kept.get(ws)!;
      // Their versions this station has not: fetched, a batch at a time.
      const maybe: Rec[] = [];
      for (const [path, rec] of Object.entries(theirs)) {
        const mine = kept.files[path];
        if (rec.hash === "" || mine?.hash === rec.hash || mine?.prev.includes(rec.hash)) continue;
        maybe.push(rec);
        // Made beside this station's: the version both came from too, where this station keeps it not (what a merge
        // reads to take only what each changed).
        if (mine !== undefined && mine.hash !== "" && !rec.prev.includes(mine.hash)) {
          const common = history(mine).find((h) => history(rec).includes(h));
          if (common !== undefined) maybe.push({ ...rec, hash: common });
        }
      }
      // (which of them blobs/ keeps, the program says: none of their bytes read here)
      const have = maybe.length === 0 ? [] : (await this.#program.ask<{ have: boolean[] }>("have", { blobs: join(this.#root(), "blobs"), hashes: maybe.map((r) => r.hash) })).have;
      const wanted = maybe.filter((_, i) => have[i] !== true);
      const given = new Map<string, Buffer>();
      for (let i = 0; i < wanted.length;) {
        const batch: string[] = [];
        let bytes = 0;
        while (i < wanted.length && (batch.length === 0 || bytes + wanted[i]!.size <= BATCH_BYTES)) (bytes += wanted[i]!.size), batch.push(wanted[i++]!.hash);
        const blobs: Json = await ask(peer, ws, { method: "memory.blobs", hashes: batch });
        for (const [h, b64] of Object.entries(isObject(blobs?.blobs) ? blobs.blobs : {})) {
          const b = Buffer.from(String(b64), "base64");
          if (sha(b) === h) given.set(h, b);
        }
      }
      await this.#take(ws, theirs, given);
      // What it lacks of this station's, to give it, and their word: read in the lane, before another look changes them.
      const files = this.#kept.get(ws)!.files;
      const give: [string, Rec][] = Object.entries(files).filter(([path, r]) => theirs[path]?.hash !== r.hash && !theirs[path]?.prev.includes(r.hash));
      return { give, synced: this.#word(ws) };
    });
    for (let i = 0; i < give.length;) {
      const files: Record<string, Rec> = {};
      const blobs: Record<string, string> = {};
      let bytes = 0;
      while (i < give.length && (Object.keys(files).length === 0 || bytes + give[i]![1].size <= BATCH_BYTES)) {
        const [path, r] = give[i++]!;
        const c = r.hash === "" ? null : await this.#content(r.hash);
        if (r.hash !== "" && c === null) continue;
        files[path] = r;
        if (c !== null) (blobs[r.hash] = c.toString("base64")), (bytes += c.length);
      }
      if (Object.keys(files).length > 0) await ask(peer, ws, { method: "memory.put", files, blobs });
    }
    return synced;
  }

  /// What `ws`'s records are, as a word that changes when any of them does.
  #word(ws: string): string {
    const files = this.#kept.get(ws)?.files ?? {};
    return sha(Buffer.from(JSON.stringify(Object.entries(files).map(([p, r]) => [p, r.hash]).sort())));
  }

  #bring(peer: string, ws: string): void {
    const key = `${ws}|${peer}`;
    const retry = this.#retries.get(key);
    if (this.#going.has(key) || (retry !== undefined && !retry.due)) return;
    const at = this.#word(ws);
    if (this.#levelAt.get(key) === at && this.#kept.has(ws)) return;
    this.#going.add(key);
    this.#level(peer, ws).then(
      (synced) => {
        this.#levelAt.set(key, synced);
        this.#retries.delete(key);
      },
      (e) => {
        if (before(e)) {
          this.#levelAt.set(key, at);
          this.#retries.delete(key);
          return;
        }
        log.info("memory", "the memory was not brought level with a station", { peer: peer.slice(0, 12), workspace: ws, error: (e as Error).message });
        if (this.#stopped) return;
        const wait = retry === undefined ? RETRY_MS : Math.min(retry.wait * 2, RETRY_MOST_MS);
        const next = { wait, due: false, cancel: () => {} };
        next.cancel = this.#time.after(wait, () => { // timer: a retry after a failure, with a backoff
          next.due = true;
          this.#lookAll();
        });
        this.#retries.set(key, next);
      },
    ).finally(() => {
      this.#going.delete(key);
      if (!this.#stopped) this.#lookAll();
    });
  }

  /// Each workspace's files looked at, and each station of it brought level where it is not yet.
  #lookAll(): void {
    const cloud = this.#deps.cloud;
    const st = cloud.state;
    // (a station that only runs tasks keeps no memory and asks nothing of the others)
    if (this.#stopped || this.#deps.still || !st || !cloud.peersCurrent || st.rig !== undefined) return;
    this.#follow();
    for (const m of cloud.memberships()) {
      const peers = m.peers.filter((p: Json) => typeof p?.id === "string" && HEX64.test(p.id) && p.id !== st.station);
      if (peers.length === 0) continue;
      if (!this.#kept.has(m.workspace)) {
        void this.#lane(m.workspace, () => this.#look(m.workspace)).then(() => this.#lookAll(), (e) => log.warn("memory", "the memory's files not read", { workspace: m.workspace, error: (e as Error).message }));
        continue;
      }
      for (const p of peers) this.#bring(p.id, m.workspace);
    }
  }

  /// `ws`'s files looked at again, then its stations brought level.
  #again(ws: string): void {
    void this.#lane(ws, () => this.#look(ws)).then(() => this.#lookAll(), (e) => log.warn("memory", "the memory's files not read", { workspace: ws, error: (e as Error).message }));
  }

  /// The agents' home watched: an edit in a workspace's memory, settled, is looked at. Made once for a home (not again
  /// at each frame of the cloud's): a watch the system would not make is tried again after a while (`#refollow`).
  #follow(): void {
    const root = this.#deps.agentHome();
    if (this.#tree?.root === root) return;
    this.#tree?.close();
    this.#followRetry?.cancel();
    this.#followRetry = null;
    this.#followOver = false;
    this.#tree = new FollowedTree({
      root,
      into: memoryFollowed,
      most: FOLLOW_MOST,
      ...(this.#deps.watch ? { watch: this.#deps.watch } : {}),
      changed: (rel) => this.#changed(rel),
      failed: (e) => {
        log.warn("memory", "the agents' home no longer followed", { error: e.message });
        this.#refollow();
      },
    });
    this.#scanTree();
  }

  /// The directories followed found again (a directory made or gone, a retry).
  #scanTree(): void {
    const tree = this.#tree;
    if (tree === null || this.#stopped) return;
    void tree.scan().then((r) => {
      if (tree !== this.#tree || this.#stopped) return;
      if (r.over && !this.#followOver) log.warn("memory", "the agents' home has more directories than are followed", { most: FOLLOW_MOST });
      this.#followOver = r.over === true;
      if (r.failed === undefined) {
        if (this.#followRetry?.due) this.#followRetry = null;
        return;
      }
      log.warn("memory", "the agents' home cannot be followed", { error: r.failed.message });
      this.#refollow();
    });
  }

  /// A scan again after a watch failed, twice as long each time up to RETRY_MOST_MS.
  #refollow(): void {
    if (this.#stopped) return;
    const was = this.#followRetry;
    if (was !== null && !was.due) return;
    const wait = was === null ? RETRY_MS : Math.min(was.wait * 2, RETRY_MOST_MS);
    const next = { wait, due: false, cancel: () => {} };
    next.cancel = this.#time.after(wait, () => { // timer: a retry after a failure, with a backoff
      next.due = true;
      this.#scanTree();
    });
    this.#followRetry = next;
  }

  /// What changed at `rel` of the agents' home: an edit of a workspace's memory looked at once it settled.
  #changed(rel: string): void {
    const parts = rel.split("/");
    const ws = parts[0] === "workspaces" ? parts[1] : this.#deps.cloud.home();
    const what = parts[0] === "workspaces" ? parts[2] : parts[0];
    // workspaces/<id> made: followed from now on
    if (parts[0] === "workspaces" && parts.length <= 2) return this.#settleScan();
    if (!ws || (what !== "MEMORY.md" && what !== "skills")) return;
    this.#settle.get(ws)?.();
    this.#settle.set(ws, this.#time.after(SETTLE_MS, () => { // timer: a debounce of a burst
      this.#settle.delete(ws);
      this.#scanTree();
      this.#again(ws);
    }));
  }

  #settleScan(): void {
    this.#settle.get("")?.();
    this.#settle.set("", this.#time.after(SETTLE_MS, () => (this.#settle.delete(""), this.#scanTree()))); // timer: a debounce of a burst
  }

  /// Followed from now on: the files, the rosters (a station come, one back).
  start(): void {
    this.#stops.push(this.#deps.cloud.listen(() => this.#lookAll()));
    this.#lookAll();
  }

  async stop(): Promise<void> {
    this.#stopped = true;
    for (const s of this.#stops) s();
    this.#tree?.close();
    this.#followRetry?.cancel();
    for (const r of this.#retries.values()) r.cancel();
    await this.#time.close();
    await this.written();
    await this.#program.close();
  }

  /// Each workspace's files looked at and each station of it brought level, one after another (tests); a station that
  /// cannot be reached is passed over.
  async levelNow(): Promise<void> {
    const cloud = this.#deps.cloud;
    for (const m of cloud.memberships()) {
      await this.#lane(m.workspace, () => this.#look(m.workspace));
      for (const p of m.peers) {
        if (typeof p?.id !== "string" || p.id === this.#me) continue;
        await this.#level(p.id, m.workspace).catch((e) => {
          if (!before(e) && !/unavailable|not reached/.test((e as Error).message)) throw e;
        });
      }
    }
    await this.written();
  }
}

/// A skill's SKILL.md as it is kept aside under `name`, of `station`: its front matter's name that one, its description
/// saying whose it is (the same on every station that makes it).
export function asideSkill(content: Buffer, name: string, station: string): Buffer {
  const text = content.toString("utf8");
  const front = /^---\n([\s\S]*?)\n---/.exec(text);
  if (front === null) return Buffer.from(`---\nname: ${name}\ndescription: [${station}] ${station}'s own, kept apart from another station's skill of the same name\n---\n\n${text}`, "utf8");
  let body = front[1]!;
  body = /^name:.*$/m.test(body) ? body.replace(/^name:.*$/m, `name: ${name}`) : `name: ${name}\n${body}`;
  body = /^description:\s*/m.test(body) ? body.replace(/^description:\s*/m, `description: [${station}] `) : `${body}\ndescription: [${station}] ${station}'s own, kept apart from another station's skill of the same name`;
  return Buffer.from(`---\n${body}\n---${text.slice(front[0].length)}`, "utf8");
}
