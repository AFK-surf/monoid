// The repos module (move/AGENTS.md): an item is one canonical clone in the repository cache (sessions/hub.ts
// `reposDir`) that a chat's linked worktree hangs on, known by its remote (`repo:<url>`, the same on every station).
// Moved: there it is a clone of that remote (one there already is taken), with what no remote has of it fetched from a
// bundle sent along (`move.repo.make`, `move.repo.bundle`); progress in the bundle's bytes. Moved back: the clone there
// is removed where this move made it, never one that was there before. A chat whose worktree hangs on it needs it
// (chats.ts), and its own move only adds the worktree (replica/retire.ts `rebuildGits` with `clone: false`).
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, open, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { Refused, withBytes, type Bytes } from "../mesh/bus.ts";
import { fileBytes } from "../mesh/files.ts";
import type { Item, ItemState, Module, Progress } from "./module.ts";

type Json = any;

export type ReposDeps = {
  data: string;
  reposDir: string;
  /// The working directories of `ws`'s chats here (at most a plan's).
  workspaces: (ws: string) => string[];
  git: (dir: string, args: string[]) => Promise<string>;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  /// A deadline's timer (ops/fibers.ts `after`); none: none kept.
  after?: (ms: number, f: () => void) => () => void;
  /// A station's name, for words.
  name?: (station: string) => string;
};

/// How long a clone there is waited for, told back as it ends (`move.repo.made`): a request's answer is waited for
/// 30 s (mesh/peer.ts ANSWER_MS), a clone can take minutes.
export const CLONE_WAIT_MS = 60 * 60_000;

/// The remotes of the linked worktrees in a directory, read again only as the directory changes (an entry made or
/// taken out: its time): a plan is a stat a chat, not a read of every directory's entries each time it is asked.
const kept = new Map<string, { at: number; list: { repo: string; url: string }[] }>();
export async function worktreesKept(dir: string): Promise<{ repo: string; url: string }[]> {
  const at = (await stat(dir).catch(() => null))?.mtimeMs ?? -1;
  const was = kept.get(dir);
  if (was !== undefined && was.at === at) return was.list;
  const list = at < 0 ? [] : await worktreesIn(dir);
  kept.set(dir, { at, list });
  return list;
}

/// A clone refused for want of a login, in words that say what to do (null: another failure).
export function cloneLogin(error: string, url: string, station: string): string | null {
  if (!/Authentication failed|could not read Username|terminal prompts disabled|Permission denied \(publickey|Repository not found|access denied/i.test(error)) return null;
  const host = /^[a-z]+:\/\/(?:[^@/]*@)?([^/:]+)/i.exec(url)?.[1] ?? /^[^@]+@([^:]+):/.exec(url)?.[1] ?? url;
  return `${station} could not clone ${url}: it is not signed in to ${host}. Sign in to ${host} on ${station} (its git credentials or an SSH key there), then move it again`;
}

/// The remote of the canonical clone a linked worktree at `dir` hangs on (its `.git` a file naming it), as its config
/// says it: null for a directory that is none.
export async function worktreeRemote(dir: string): Promise<{ repo: string; url: string } | null> {
  const said = await readFile(join(dir, ".git"), "utf8").catch(() => null);
  if (said === null || !said.startsWith("gitdir:")) return null;
  const gitdir = said.slice("gitdir:".length).trim();
  if (!isAbsolute(gitdir)) return null;
  // (<repo>/.git/worktrees/<name>)
  const common = resolve(gitdir, "..", "..");
  const config = await readFile(join(common, "config"), "utf8").catch(() => "");
  const m = /\[remote "origin"\][^[]*?url\s*=\s*(.+)/.exec(config);
  return m === null ? null : { repo: dirname(common), url: m[1]!.trim() };
}

/// The canonical clones the linked worktrees in `workspace` hang on (it, and the directories right under it).
export async function worktreesIn(workspace: string): Promise<{ repo: string; url: string }[]> {
  const out: { repo: string; url: string }[] = [];
  const at = await worktreeRemote(workspace);
  if (at !== null) out.push(at);
  for (const name of await readdir(workspace).catch(() => [] as string[])) {
    const r = await worktreeRemote(join(workspace, name));
    if (r !== null && !out.some((x) => x.url === r.url)) out.push(r);
  }
  return out;
}

export const repoItemId = (url: string) => `repo:${url}`;

/// What a station keeps of the clones moves made here (removed on a move back), by remote.
type Made = Record<string, { dir: string; made: boolean }>;

export class ReposModule implements Module {
  readonly id = "repos";
  readonly needs = [] as const;
  /// What a move copies stays here too: moving it stops nothing here (scheduler `stops`, `wouldStop`).
  usableHere(): boolean {
    return true;
  }
  readonly #d: ReposDeps;
  readonly #there = new Map<string, boolean>();
  readonly #local = new Map<string, string>();
  readonly #moving = new Map<string, Progress>();
  /// The clones asked of another station and not told ended yet, by remote.
  readonly #cloning = new Map<string, { done: (error: string | null) => void }>();
  /// The clones under way here for another station, by remote.
  readonly #clones = new Map<string, Promise<void>>();
  #made: Made;

  constructor(d: ReposDeps) {
    this.#d = d;
    try {
      this.#made = JSON.parse(readFileSync(join(d.data, "move", "repos.json"), "utf8")) as Made; // sync: read once, before the station serves
    } catch {
      this.#made = {};
    }
  }

  async plan(ws: string, to: string): Promise<Item[]> {
    const items: Item[] = [];
    for (const w of this.#d.workspaces(ws)) {
      for (const r of await worktreesKept(w)) {
        const id = repoItemId(r.url);
        if (items.some((x) => x.id === id)) continue;
        this.#local.set(id, r.repo);
        items.push({ module: "repos", id, label: basename(r.repo), needs: [] });
      }
    }
    if (items.length > 0 && to !== "") {
      const answer = await this.#d.ask(to, { method: "move.repo.have", urls: items.map((x) => x.id.slice(5)) }).catch(() => null);
      for (const x of items) this.#there.set(x.id, answer?.have?.[x.id.slice(5)] === true);
    }
    return items;
  }

  async move(item: Item, to: string, progress: (p: Progress) => void): Promise<void> {
    const repo = this.#local.get(item.id);
    if (repo === undefined) throw new Error(`repository ${item.label} is not here`);
    const url = item.id.slice(5);
    // (cloned there by itself, told back as it ends: a clone of minutes waits on no request's answer)
    const told = new Promise<string | null>((resolve) => this.#cloning.set(url, { done: resolve }));
    let late = () => {};
    const deadline = new Promise<string | null>((resolve) => (late = this.#d.after?.(CLONE_WAIT_MS, () => resolve(`the clone of ${url} there did not end in ${CLONE_WAIT_MS / 60_000} min: move it again`)) ?? (() => {}))); // timer: a deadline for the clone there
    try {
      const made = await this.#d.ask(to, { method: "move.repo.make", url, name: basename(repo) });
      if (made?.cloning === true) {
        const error = await Promise.race([told, deadline]);
        if (error !== null) throw new Error(error);
      }
    } finally {
      late();
      this.#cloning.delete(url);
    }
    // What no remote has of it, in a bundle (git makes none where all of it is on a remote).
    const bundle = join(this.#d.data, "move", `${randomBytes(4).toString("hex")}.bundle`);
    await mkdir(dirname(bundle), { recursive: true });
    try {
      const made = await this.#d.git(repo, ["bundle", "create", "-q", bundle, "--branches", "--tags", "--not", "--remotes"]).then(() => true, () => false);
      const size = made ? (await stat(bundle).catch(() => null))?.size ?? 0 : 0;
      const p = { done: 0, total: size, unit: "bytes" };
      this.#moving.set(item.id, p);
      progress(p);
      if (size > 0) await this.#d.ask(to, withBytes({ method: "move.repo.bundle", url }, fileBytes(bundle, 0, size)));
      progress({ done: size, total: size, unit: "bytes" });
      this.#there.set(item.id, true);
    } finally {
      this.#moving.delete(item.id);
      await rm(bundle, { force: true });
    }
  }

  async back(item: Item, from: string): Promise<void> {
    await this.#d.ask(from, { method: "move.repo.drop", url: item.id.slice(5) });
    this.#there.set(item.id, false);
  }

  state(item: Item): ItemState {
    const p = this.#moving.get(item.id);
    if (p !== undefined) return { state: "moving", progress: p };
    return { state: this.#there.get(item.id) === true ? "there" : "here" };
  }

  /// A clone of `url` made here, named after `name`.
  async #clone(url: string, named: string): Promise<void> {
    const base = named.replace(/[^A-Za-z0-9._-]/g, "-") || "repo";
    let name = base;
    const exists = (n: string) => stat(join(this.#d.reposDir, n)).then(() => true, () => false);
    for (let i = 2; await exists(name); i++) name = `${base}-${i}`;
    await mkdir(this.#d.reposDir, { recursive: true });
    const temp = `.cloning-${randomBytes(4).toString("hex")}`;
    try {
      await this.#d.git(this.#d.reposDir, ["clone", "-q", "--", url, temp]);
      await rename(join(this.#d.reposDir, temp), join(this.#d.reposDir, name));
    } finally {
      await rm(join(this.#d.reposDir, temp), { recursive: true, force: true });
    }
    this.#made[url] = { dir: join(this.#d.reposDir, name), made: true };
    await this.#saveMade();
  }

  /// The clone here of remote `url` (null: none).
  async #cloneOf(url: string): Promise<string | null> {
    for (const name of (await readdir(this.#d.reposDir).catch(() => [] as string[])).sort()) {
      if (name.startsWith(".")) continue;
      const dir = join(this.#d.reposDir, name);
      if ((await this.#d.git(dir, ["remote", "get-url", "origin"]).catch(() => null)) === url) return dir;
    }
    return null;
  }

  async #saveMade(): Promise<void> {
    const path = join(this.#d.data, "move", "repos.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#made));
    await rename(tmp, path);
  }

  /// What another station asks of the clones here (`move.repo.*`).
  async answer(peer: string, request: Json, bytes: Bytes | null): Promise<Json> {
    const url = typeof request.url === "string" ? request.url : "";
    switch (request.method) {
      case "move.repo.made": {
        this.#cloning.get(url)?.done(typeof request.error === "string" ? request.error : null);
        return { ok: true };
      }
      case "move.repo.have": {
        const have: Record<string, boolean> = {};
        for (const u of (Array.isArray(request.urls) ? request.urls : []).slice(0, 500)) if (typeof u === "string") have[u] = (await this.#cloneOf(u)) !== null;
        return { have };
      }
      case "move.repo.make": {
        if (url === "") throw new Refused("no remote named");
        if (this.#clones.has(url)) return { cloning: true };
        if ((await this.#cloneOf(url)) !== null) return { ok: true, made: this.#made[url]?.made === true };
        // (answered at once: the clone goes on by itself, and its end is told to the station that asked)
        const clone = this.#clone(url, String(request.name ?? "")).then(
          () => null,
          (e: Error) => cloneLogin(e.message, url, this.#d.name?.(this.#d.here()) ?? "this station") ?? `the clone of ${url} failed there: ${e.message.split("\n").filter(Boolean).at(-1) ?? e.message}`,
        ).then((error) => this.#d.ask(peer, { method: "move.repo.made", url, ...(error !== null ? { error } : {}) }).catch(() => {}));
        this.#clones.set(url, clone.finally(() => this.#clones.delete(url)));
        return { cloning: true };
      }
      case "move.repo.bundle": {
        const dir = await this.#cloneOf(url);
        if (dir === null || bytes === null) throw new Refused("no clone of that remote here: move.repo.make first");
        const files = join(this.#d.data, "move", "in", "repos");
        const name = `${randomBytes(8).toString("hex")}`;
        // (taken by its bytes as they come; its name is no hash, so it is written as it is)
        await mkdir(files, { recursive: true });
        const path = join(files, name);
        // (written as it comes, never held whole)
        const out = await open(path, "w");
        try {
          for await (const piece of bytes) await out.write(piece);
        } finally {
          await out.close();
        }
        try {
          await this.#d.git(dir, ["fetch", "-q", "--update-head-ok", path, "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"]);
        } finally {
          await rm(path, { force: true });
        }
        return { ok: true };
      }
      case "move.repo.drop": {
        const m = this.#made[url];
        if (m?.made === true) await rm(m.dir, { recursive: true, force: true });
        delete this.#made[url];
        await this.#saveMade();
        return { ok: true };
      }
    }
    throw new Refused("no such repo request");
  }
}

