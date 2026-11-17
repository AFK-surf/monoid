// Which session opened each tab of the station's browser ("Whose a tab is"): learnt from the
// session's own connection to it (proxy.ts) and from a tab's opener, kept in <data>/browser/owners.json as Chrome keeps
// its tabs, so the next station process that takes the browser up still knows them. A tab gone is forgotten. These are
// the station's own context's tabs: one in a chat's own context (browsers.ts) is that chat's, by its context.
// Read and written off the station's thread (`PrivateFile`): what is learnt before it is read is kept over what it says.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { PrivateFile } from "../ops/files.ts";
import { log } from "../ops/log.ts";

export class Owners {
  readonly #file: PrivateFile;
  readonly #of = new Map<string, string>();
  /// Tabs said gone before the file was read: not taken from it.
  readonly #gone = new Set<string>();
  #loaded = false;
  /// Changed before the file was read: written once it is.
  #changed = false;
  readonly #ready: Promise<void>;

  constructor(dir: string) {
    this.#file = new PrivateFile(join(dir, "owners.json"));
    this.#ready = this.#load();
  }

  /// Once what the file said is known.
  ready(): Promise<void> {
    return this.#ready;
  }

  /// Once what was changed is written down (or failed).
  async written(): Promise<void> {
    await this.#ready;
    await this.#file.written();
  }

  /// The session that opened tab `targetId`, if one is known.
  of(targetId: string): string | undefined {
    return this.#of.get(targetId);
  }

  /// Tab `targetId` is `session`'s; whether that is news.
  set(targetId: string, session: string): boolean {
    if (this.#of.get(targetId) === session) return false;
    this.#of.set(targetId, session);
    this.#gone.delete(targetId);
    this.#write();
    return true;
  }

  /// Tab `targetId` is gone.
  drop(targetId: string) {
    if (!this.#loaded) {
      this.#gone.add(targetId);
      this.#of.delete(targetId);
      return this.#write();
    }
    if (this.#of.delete(targetId)) this.#write();
  }

  /// Only these tabs are there (the browser as a station process takes it up): the rest are forgotten. Asked once
  /// `ready` (browser.ts takes a Chrome up after it).
  keep(targetIds: Set<string>) {
    let changed = false;
    for (const id of [...this.#of.keys()]) if (!targetIds.has(id)) changed = this.#of.delete(id) || changed;
    if (changed) this.#write();
  }

  async #load() {
    const was = await read(this.#file.path);
    for (const [id, session] of Object.entries(was)) if (!this.#of.has(id) && !this.#gone.has(id)) this.#of.set(id, session);
    this.#loaded = true;
    this.#gone.clear();
    // What was learnt meanwhile, written now with what the file had.
    if (this.#changed) this.#write();
  }

  #write() {
    // Before the file is read, written once it is (with what it had).
    if (!this.#loaded) return void (this.#changed = true);
    this.#file
      .write(JSON.stringify(Object.fromEntries(this.#of), null, 2) + "\n")
      .catch((e) => log.warn("browser", "the tabs' owners could not be written", { error: (e as Error).message }));
  }
}

async function read(file: string): Promise<Record<string, string>> {
  try {
    const v = JSON.parse(await readFile(file, "utf8"));
    if (v === null || typeof v !== "object" || Array.isArray(v)) return {};
    return Object.fromEntries(Object.entries(v).filter((e): e is [string, string] => typeof e[1] === "string" && e[1] !== ""));
  } catch {
    return {};
  }
}
