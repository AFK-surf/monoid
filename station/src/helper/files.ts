// The drive's folders macOS keeps from a station launchd runs (Documents, Desktop, Downloads, disks; drive/fs.ts
// `protectedTop`), reached through still.fail Helper (native/helper's Files.swift), which holds the grants for them:
// the drive's operations as the helper's `files.*` requests, each on a connection of its own, told the roots it may
// reach and what it may not (the drive has checked the paths already; the helper checks them again). A file's bytes go
// over that connection as they are read or written, never a whole file at once: a read answers its head line, then
// the bytes; a write is answered once the file is open, then the station sends the bytes, then it answers again.
//
// Without the grant the helper refuses (`grant`) and touches nothing (macOS would put up its prompt and hold the call
// until a person answers): the drive puts the helper's window up on this Mac for it (`ask`), once in AGAIN_MS (the
// station's one window for grants, helper/grants.ts, whoever asks: the station's page and the agents too). What is
// known of each folder's grant is kept (`known`), looked at in the background where it is not (`check`), and looked at
// again when the helper says a grant changed or comes back; the drive's roots are told again (`changed`) when it is
// not what it was.
import { open, unlink } from "node:fs/promises";
import type net from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Access, Fs, Grant, Listed, Stat, Write, Written } from "../drive/fs.ts";
import { wall } from "../ops/fibers.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { windowWords } from "../screens/desktop.ts";
import type { HelperApp } from "./app.ts";
import { HelperGrants, type WindowState } from "./grants.ts";

// The window shown for a grant is not shown (nor brought forward) again for that grant this soon after (AGAIN_MS): a
// page read again, a client retrying, a person refreshing are never what puts it up; a person opening the folder once
// it has been closed this long is.
export { AGAIN_MS, type WindowState } from "./grants.ts";

/// What a write sends at a time (the socket takes it as it can).
const CHUNK = 256 * 1024;
/// How fresh a folder grant look stays for explicit picker refreshes (matching HelperGrants' FRESH_MS).
const ACCESS_FRESH_MS = 2_000;
/// How long to wait before retrying after still.fail Helper failed to answer (matching HelperGrants' SHOWN_MS).
const FAILED_BACKOFF_MS = 30_000;
const FOLDER_GRANTS: readonly Grant[] = ["documents", "desktop", "downloads", "removable", "network"];
const HOME_GRANTS = [
  ["Documents", "documents"],
  ["Desktop", "desktop"],
  ["Downloads", "downloads"],
] as const;

/// The helper's window's words for the drive's folders, in `lang` (Permissions.swift).
export function filesWords(lang: Lang): Record<string, string> {
  const w = (key: string) => tr(lang, `station.helper.window.${key}`);
  return {
    title: w("filesTitle"),
    subtitle: w("filesSubtitle"),
    documents: w("documents"),
    documentsWhy: w("documentsWhy"),
    desktop: w("desktop"),
    desktopWhy: w("desktopWhy"),
    downloads: w("downloads"),
    downloadsWhy: w("downloadsWhy"),
    removable: w("removable"),
    removableWhy: w("removableWhy"),
    network: w("network"),
    networkWhy: w("networkWhy"),
    deniedWhy: w("deniedWhy"),
    allow: w("allow"),
    done: w("done"),
  };
}

/// The helper's window's words when a person or an agent asks for a grant (the station's page, the `permissions`
/// tool): any of its rows, the screen's and the folders', under words that say it was asked for.
export function askWords(lang: Lang): Record<string, unknown> {
  return { ...windowWords(lang), ...filesWords(lang), title: tr(lang, "station.helper.window.askTitle"), subtitle: tr(lang, "station.helper.window.askSubtitle") };
}

type Refusal = Error & { code?: string; grant?: Grant; state?: Access["state"]; top?: string; pid?: number };

export class HelperFiles {
  readonly #helper: HelperApp;
  readonly #changed: () => void;
  readonly #lang: () => Lang;
  readonly #now: () => number;
  readonly #home: string;
  /// Each protected folder (its top) the drive met, with its grant; each grant's state, as last known.
  readonly #grantOf = new Map<string, Grant>();
  readonly #states = new Map<Grant, Access["state"]>();
  readonly #checking = new Map<string, Promise<void>>();
  readonly #checkedAt = new Map<string, number>();
  #failedAt = -Infinity;
  readonly #grants: HelperGrants;

  /// `grants`: the station's one look at the grants and its window for them (default: its own).
  constructor(options: { helper: HelperApp; changed: () => void; lang?: () => Lang; now?: () => number; grants?: HelperGrants; home?: string }) {
    this.#helper = options.helper;
    this.#changed = options.changed;
    this.#lang = options.lang ?? stationLang;
    this.#now = options.now ?? (() => wall.now());
    this.#home = options.home ?? homedir();
    this.#grants = options.grants ?? new HelperGrants({ helper: options.helper, now: options.now });
    // Pick up folder grants already known to HelperGrants, and follow its refreshes (System Settings toggles,
    // permissions page, permissions tool) without waiting for the helper window or a restart.
    this.#syncGrants(false);
    this.#grants.onChange(() => this.#syncGrants(true));
    // A grant changed (its window saw it), or the helper came back: what is known is looked at again.
    options.helper.listen((event) => {
      if (event.event === "grants") this.#again();
    });
    options.helper.onBack(() => this.#again());
  }

  #homeGrant(top: string): Grant | undefined {
    const lower = top.toLowerCase();
    for (const [name, grant] of HOME_GRANTS) {
      if (lower === join(this.#home, name).toLowerCase()) return grant;
    }
    return undefined;
  }

  known(top: string): Access | undefined {
    const grant = this.#grantOf.get(top) ?? this.#homeGrant(top);
    const state = grant === undefined ? undefined : this.#states.get(grant);
    return grant === undefined || state === undefined ? undefined : { grant, state };
  }

  check(tops: string[]): void {
    if (this.#now() - this.#failedAt < FAILED_BACKOFF_MS) return;
    const asking = tops.filter((t) => !this.#checking.has(t));
    if (asking.length === 0) return;
    void this.#startLook(asking);
  }

  /// Look up `tops` now when not known or not yet granted, deduplicated and rate-limited against helper failures.
  async refresh(tops: string[]): Promise<void> {
    const unique = [...new Set(tops)];
    const waits: Promise<void>[] = [];
    const asking: string[] = [];
    const now = this.#now();
    for (const t of unique) {
      const going = this.#checking.get(t);
      if (going !== undefined) {
        if (!waits.includes(going)) waits.push(going);
        continue;
      }
      if (this.known(t)?.state === "granted") continue;
      const last = this.#checkedAt.get(t);
      if (last !== undefined && now - last < ACCESS_FRESH_MS) continue;
      asking.push(t);
    }
    if (asking.length > 0 && now - this.#failedAt >= FAILED_BACKOFF_MS) {
      waits.push(this.#startLook(asking));
    }
    if (waits.length > 0) await Promise.all(waits);
  }

  #startLook(asking: string[]): Promise<void> {
    const p = this.#look(asking).finally(() => {
      for (const t of asking) if (this.#checking.get(t) === p) this.#checking.delete(t);
    });
    for (const t of asking) this.#checking.set(t, p);
    return p;
  }

  /// What the helper says of `tops` now, kept; told when it is not what was known.
  async #look(tops: string[]): Promise<void> {
    try {
      const answer = await this.#helper.request({ op: "files.access", paths: tops });
      const at = this.#now();
      this.#failedAt = -Infinity;
      let changed = false;
      for (const t of tops) this.#checkedAt.set(t, at);
      for (const a of answer.access ?? []) {
        if (typeof a.grant !== "string") continue;
        this.#grantOf.set(a.path, a.grant);
        this.#checkedAt.set(a.path, at);
        changed = this.#learn(a.grant, a.state) || changed;
      }
      if (changed) this.#changed();
    } catch (error) {
      this.#failedAt = this.#now();
      log.warn("drive", "still.fail Helper did not say what it may open", { error: (error as Error).message });
    }
  }

  /// Sync folder grant states from HelperGrants' latest status snapshot.
  #syncGrants(notify: boolean): void {
    const files = this.#grants.status()?.files;
    if (!files) return;
    this.#failedAt = -Infinity;
    let changed = false;
    const all = files.all === "granted";
    for (const grant of FOLDER_GRANTS) {
      const raw = all ? "granted" : files[grant];
      if (raw === "granted" || raw === "denied" || raw === "unknown") {
        changed = this.#learn(grant, raw) || changed;
      }
    }
    if (changed && notify) this.#changed();
  }

  /// A grant's state as now known; whether that changed it.
  #learn(grant: Grant, state: Access["state"]): boolean {
    if (this.#states.get(grant) === state) return false;
    this.#states.set(grant, state);
    return true;
  }

  /// A request done at `path`: the grant of the protected folder it is in is given.
  #confirm(path: string) {
    const lower = path.toLowerCase();
    for (const [top, grant] of this.#grantOf) {
      const t = top.toLowerCase();
      if ((lower === t || lower.startsWith(`${t}/`)) && this.#learn(grant, "granted")) this.#changed();
    }
    for (const [name, grant] of HOME_GRANTS) {
      const t = join(this.#home, name).toLowerCase();
      if ((lower === t || lower.startsWith(`${t}/`)) && this.#learn(grant, "granted")) this.#changed();
    }
  }

  #again() {
    this.#failedAt = -Infinity;
    if (this.#grantOf.size > 0) void this.#startLook([...this.#grantOf.keys()]);
  }

  ask(grant: Grant, top: string): Promise<WindowState> {
    this.#grantOf.set(top, grant);
    return this.#grants.show(grant, filesWords(this.#lang()), { [grant]: top });
  }

  /// What Spotlight finds under the protected folder `top` for `query` (its query language), asked as still.fail Helper
  /// (which holds the folder's grant): at most `most`. Only of a folder known to be granted (`known`): one not would be
  /// refused, and nothing asks for a grant on a search's behalf.
  async search(top: string, query: string, most: number, protect: string[]): Promise<string[]> {
    const answer = await this.request({ op: "files.search", path: top, query, most, roots: [top], protect });
    return Array.isArray(answer?.paths) ? answer.paths.filter((p: unknown): p is string => typeof p === "string") : [];
  }

  fs(scope: { roots: string[]; protect: string[] }): Fs {
    return new HelperFs(this, scope);
  }

  /// One request, its answer; a grant refused or given learnt on the way. `restart`: the helper starts again to have a
  /// grant given since it started, and is asked once more.
  async request(op: Record<string, unknown>): Promise<any> {
    return this.#learning(op, () => this.#helper.request(op));
  }

  /// A connection for a stream: its head line read (a refusal thrown), the rest the caller's.
  async stream(op: Record<string, unknown>): Promise<{ head: any; socket: net.Socket; rest: Buffer }> {
    return this.#learning(op, async () => {
      const socket = await this.#helper.connect(op);
      return { ...(await lineOf(socket)), socket };
    });
  }

  async #learning<T>(op: Record<string, unknown>, ask: () => Promise<T>): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      try {
        const answer = await ask();
        // Done in a protected folder: its grant is there (its roots told so at once, not only when the window says).
        const path = typeof op.path === "string" ? op.path : typeof op.from === "string" ? op.from : null;
        if (path !== null) this.#confirm(path);
        return answer;
      } catch (e) {
        const r = e as Refusal;
        if (r.code === "restart" && attempt === 0 && typeof r.pid === "number") {
          await this.#helper.restarted(r.pid);
          continue;
        }
        if (r.code === "grant" && r.grant && r.state) {
          if (r.top) this.#grantOf.set(r.top, r.grant);
          if (this.#learn(r.grant, r.state)) this.#changed();
        }
        throw e;
      }
    }
  }
}

/// A connection's first line (a refusal thrown), and what came after it; the socket paused, nobody listening.
function lineOf(socket: net.Socket, carry: Buffer = Buffer.alloc(0)): Promise<{ head: any; rest: Buffer }> {
  return new Promise((resolve, reject) => {
    let got = carry;
    const done = () => {
      socket.off("data", data);
      socket.off("close", closed);
      socket.off("error", failed);
      socket.pause();
    };
    const take = () => {
      const at = got.indexOf(10);
      if (at < 0) return false;
      done();
      let head;
      try {
        head = JSON.parse(got.subarray(0, at).toString("utf8"));
      } catch (e) {
        socket.destroy();
        reject(e as Error);
        return true;
      }
      if (typeof head?.error === "string") {
        socket.destroy();
        reject(Object.assign(new Error(head.error), head));
      } else resolve({ head, rest: got.subarray(at + 1) });
      return true;
    };
    const data = (chunk: Buffer) => {
      got = Buffer.concat([got, chunk]);
      take();
    };
    const closed = () => {
      done();
      reject(ended());
    };
    const failed = () => {};
    if (take()) return;
    socket.on("data", data);
    socket.on("close", closed);
    socket.on("error", failed);
    socket.resume();
  });
}

/// The helper went before it said all it had to (it ended, it was restarted): the drive's `io`.
const ended = () => Object.assign(new Error("still.fail Helper ended before it answered"), { code: "EIO" });

/// The rest of a stream (`rest`, then all that comes) given to `take` as it comes, the socket held while `take` works;
/// resolved at its end with how much came.
function drain(socket: net.Socket, rest: Buffer, take: (chunk: Buffer) => Promise<void> | void): Promise<number> {
  return new Promise((resolve, reject) => {
    let got = 0;
    let chain = Promise.resolve();
    let failed: unknown = null;
    const put = (chunk: Buffer) => {
      got += chunk.length;
      chain = chain.then(() => (failed === null ? take(chunk) : undefined)).catch((e) => {
        failed ??= e;
        socket.destroy();
      });
    };
    if (rest.length > 0) put(rest);
    socket.on("data", (chunk: Buffer) => {
      socket.pause();
      put(chunk);
      void chain.then(() => socket.resume());
    });
    socket.on("error", () => {});
    socket.on("close", () => void chain.then(() => (failed !== null ? reject(failed) : resolve(got))));
    socket.resume();
  });
}

const statOf = (a: any): Stat => ({ dir: a.dir === true, file: a.file === true, link: a.link === true, size: Number(a.size) || 0, mtimeMs: Number(a.mtime) || 0 });

/// The drive's operations as still.fail Helper's requests, in one scope.
class HelperFs implements Fs {
  readonly helper = true;
  readonly #files: HelperFiles;
  readonly #scope: { roots: string[]; protect: string[] };

  constructor(files: HelperFiles, scope: { roots: string[]; protect: string[] }) {
    this.#files = files;
    this.#scope = scope;
  }

  #ask(op: string, fields: Record<string, unknown>): Promise<any> {
    return this.#files.request({ op, ...fields, ...this.#scope });
  }

  async list(dir: string, most: number): Promise<{ entries: Listed[]; more: boolean }> {
    const a = await this.#ask("files.list", { path: dir, most });
    const entries = (a.entries ?? []).map((e: any): Listed => ({ name: e.name, link: e.link === true, real: e.real ?? join(dir, e.name), stat: e.gone ? null : statOf(e) }));
    return { entries, more: a.more === true };
  }

  async names(dir: string): Promise<string[]> {
    return (await this.#ask("files.names", { path: dir })).names ?? [];
  }

  async stat(path: string): Promise<Stat> {
    return statOf(await this.#ask("files.stat", { path, follow: true }));
  }

  async lstat(path: string): Promise<Stat> {
    return statOf(await this.#ask("files.stat", { path, follow: false }));
  }

  async real(path: string): Promise<string> {
    return (await this.#ask("files.real", { path })).path;
  }

  async read(path: string, offset: number, length: number): Promise<{ bytes: Buffer; size: number; mtimeMs: number }> {
    const { head, socket, rest } = await this.#files.stream({ op: "files.read", path, offset, length, ...this.#scope });
    const want = Number(head.length) || 0;
    const bytes = Buffer.alloc(want);
    let at = 0;
    await drain(socket, rest, (chunk) => {
      at += chunk.copy(bytes, at);
    });
    if (at < want) throw ended();
    return { bytes, size: Number(head.size) || 0, mtimeMs: Number(head.mtime) || 0 };
  }

  async readAll(path: string): Promise<Buffer> {
    const s = await this.stat(path);
    return (await this.read(path, 0, s.size)).bytes;
  }

  async copyTo(path: string, to: string): Promise<void> {
    const out = await open(to, "wx");
    try {
      const s = await this.stat(path);
      const { head, socket, rest } = await this.#files.stream({ op: "files.read", path, offset: 0, length: s.size, ...this.#scope });
      const got = await drain(socket, rest, async (chunk) => {
        let done = 0;
        while (done < chunk.length) done += (await out.write(chunk, done, chunk.length - done)).bytesWritten;
      });
      if (got < (Number(head.length) || 0)) throw ended();
      await out.close();
    } catch (e) {
      await out.close().catch(() => {});
      await unlink(to).catch(() => {});
      throw e;
    }
  }

  async write(path: string, w: Write): Promise<Written> {
    const fields = { path, offset: w.offset, length: w.data.length, create: w.create, ...(w.truncate !== undefined ? { truncate: w.truncate } : {}), ...(w.sync ? { sync: true } : {}) };
    const { head, socket } = await this.#files.stream({ op: "files.write", ...fields, ...this.#scope });
    // Smaller than asked: nothing written (the helper sees the connection end before any byte).
    if (w.atLeast !== undefined && Number(head.size) < w.atLeast) {
      socket.destroy();
      return { size: Number(head.size), short: true };
    }
    const answer = lineOf(socket);
    socket.on("error", () => {});
    for (let at = 0; at < w.data.length; at += CHUNK) {
      if (socket.destroyed) break;
      if (!socket.write(w.data.subarray(at, at + CHUNK))) await new Promise((resolve) => (socket.once("drain", resolve), socket.once("close", resolve)));
    }
    const { head: done } = await answer;
    socket.destroy();
    return { size: Number(done.size) };
  }

  async rename(from: string, to: string): Promise<void> {
    await this.#ask("files.rename", { from, to });
  }

  async mkdir(path: string, recursive: boolean): Promise<void> {
    await this.#ask("files.mkdir", { path, recursive });
  }

  async remove(path: string): Promise<void> {
    await this.#ask("files.remove", { path });
  }

  async trash(path: string): Promise<string | null> {
    return (await this.#ask("files.trash", { path })).to ?? null;
  }

  async unlink(path: string): Promise<void> {
    await this.#ask("files.unlink", { path });
  }
}
