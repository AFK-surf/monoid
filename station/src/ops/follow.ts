// A directory followed for what changes in it, and in the directories under it that its owner lets in, each with a
// watch of its own. Not Node's recursive watch: on Linux that is Node's own code (no system call watches a tree there),
// which lists the whole tree with readdirSync on the main thread, holds an inotify watch for every directory of it,
// a repository's .git and node_modules with the rest, and lists it again as any of it changes; past
// fs.inotify.max_user_watches it throws, and the agents' memory (#6206) asked again at every frame of the cloud's, the
// whole tree each time (a Linux station lost on the test channel, 2026-11-15). Here only what the owner names is
// listed, off the main thread (fs/promises), and no more than `most` directories are watched.
import { type Dirent, watch as nodeWatch } from "node:fs";
import { readdir } from "node:fs/promises";
import { join } from "node:path";

/// A directory's watch, not recursive: `changed` is told the name of what changed in it (null: something did).
export type Watch = (dir: string, changed: (name: string | null) => void) => { close(): void; on(event: "error", f: (e: Error) => void): unknown };

const watchDir: Watch = (dir, changed) => nodeWatch(dir, { persistent: false }, (_event, name) => changed(name === null ? null : String(name)));

export type Followed = {
  root: string;
  /// Whether the directory at `rel` (relative to the root, "/" between names; never "") is followed.
  into: (rel: string) => boolean;
  /// Something at `rel` changed ("" the root itself).
  changed: (rel: string) => void;
  /// A watch that failed after it was made (the system took it back): it is dropped, for the next `scan` to make again.
  failed?: (e: Error) => void;
  /// The most directories watched at once.
  most: number;
  watch?: Watch;
};

/// What a scan came to: `failed`, a watch the system would not make (out of inotify watches, of descriptors); `over`, more
/// directories let in than `most` (those past it not followed).
export type Scanned = { failed?: Error; over?: true };

export class FollowedTree {
  readonly root: string;
  readonly #f: Followed;
  readonly #watch: Watch;
  readonly #watches = new Map<string, { close(): void }>();
  #scanning: Promise<Scanned> | null = null;
  #again = false;
  #closed = false;

  constructor(f: Followed) {
    this.#f = f;
    this.root = f.root;
    this.#watch = f.watch ?? watchDir;
  }

  /// Tests: the watch of the directory at `rel` ("" the root), as the system gave it.
  watchOf(rel: string): unknown {
    return this.#watches.get(rel);
  }

  /// The directories watched now, relative to the root.
  watched(): string[] {
    return [...this.#watches.keys()];
  }

  /// The directories let in found again: those new watched, those gone let go. One at a time; one asked while another
  /// runs runs after it, and both callers get what that one came to.
  scan(): Promise<Scanned> {
    if (this.#scanning !== null) {
      this.#again = true;
      return this.#scanning;
    }
    const run = async (): Promise<Scanned> => {
      let r: Scanned;
      do {
        this.#again = false;
        r = await this.#scan();
      } while (this.#again && !this.#closed);
      return r;
    };
    const p = run().finally(() => {
      if (this.#scanning === p) this.#scanning = null;
    });
    this.#scanning = p;
    return p;
  }

  async #scan(): Promise<Scanned> {
    const found = new Set<string>();
    const result: Scanned = {};
    const walk = async (rel: string): Promise<void> => {
      if (this.#closed || result.failed !== undefined) return;
      if (found.size >= this.#f.most) {
        result.over = true;
        return;
      }
      found.add(rel);
      // The watch first, then the listing: what comes in between is told.
      if (!this.#add(rel, result)) return;
      let entries: Dirent[] = [];
      try {
        entries = await readdir(rel === "" ? this.root : join(this.root, rel), { withFileTypes: true });
      } catch {
        return;
      }
      for (const e of entries) {
        const sub = rel === "" ? e.name : `${rel}/${e.name}`;
        if (e.isDirectory() && this.#f.into(sub)) await walk(sub);
      }
    };
    await walk("");
    // A scan cut short lets nothing go: what it did not reach may still be there.
    if (result.failed === undefined && !this.#closed) {
      for (const [rel, w] of this.#watches) {
        if (found.has(rel)) continue;
        w.close();
        this.#watches.delete(rel);
      }
    }
    return result;
  }

  #add(rel: string, result: Scanned): boolean {
    if (this.#watches.has(rel)) return true;
    try {
      const w = this.#watch(rel === "" ? this.root : join(this.root, rel), (name) => {
        if (this.#closed) return;
        this.#f.changed(name === null ? rel : rel === "" ? name : `${rel}/${name}`);
      });
      w.on("error", (e) => {
        if (this.#watches.get(rel) !== w) return;
        w.close();
        this.#watches.delete(rel);
        this.#f.failed?.(e);
      });
      this.#watches.set(rel, w);
      return true;
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      // gone since it was listed: nothing to follow
      if (code !== "ENOENT" && code !== "ENOTDIR") result.failed = e as Error;
      return false;
    }
  }

  close(): void {
    this.#closed = true;
    for (const w of this.#watches.values()) w.close();
    this.#watches.clear();
  }
}
