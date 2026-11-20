// Which of a module's items moved from here, kept across a start (move/AGENTS.md: each item's state is its module's,
// durable): a set of item ids in one JSON file, read once before the station serves, written whole as it changes.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { appendFile, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { wall } from "../ops/fibers.ts";

const RENAME_BACKOFF = [20, 40, 80, 160];

/// Replace the file atomically, allowing a short wait for Windows file locks to clear.
export async function replaceFile(path: string, text: string, opts?: { rename?: typeof rename; wait?: (ms: number) => Promise<void> }): Promise<void> {
  await mkdir(dirname(path), { recursive: true });
  const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
  const move = opts?.rename ?? rename;
  const wait = opts?.wait ?? wall.sleep;
  try {
    await writeFile(tmp, text);
    for (let attempt = 0; ; attempt++) {
      try {
        await move(tmp, path);
        return;
      } catch (error) {
        const delay = RENAME_BACKOFF[attempt];
        const code = (error as NodeJS.ErrnoException)?.code;
        if (delay === undefined || (code !== "EPERM" && code !== "EBUSY" && code !== "EACCES")) throw error;
        await wait(delay);
      }
    }
  } catch (error) {
    await rm(tmp, { force: true }).catch(() => {});
    throw error;
  }
}

export class KeptSet {
  readonly #path: string;
  #ids: Set<string>;
  #dirty = false;
  #saving: Promise<void> | null = null;

  constructor(path: string) {
    this.#path = path;
    try {
      this.#ids = new Set(JSON.parse(readFileSync(path, "utf8")) as string[]); // sync: read once, before the station serves
    } catch {
      this.#ids = new Set();
    }
  }

  has(id: string): boolean {
    return this.#ids.has(id);
  }

  values(): string[] {
    return [...this.#ids];
  }
  get size(): number {
    return this.#ids.size;
  }

  async add(id: string): Promise<void> {
    if (this.#ids.has(id)) return;
    this.#ids.add(id);
    await this.#save();
  }

  async delete(id: string): Promise<void> {
    if (!this.#ids.delete(id)) return;
    await this.#save();
  }

  #save(): Promise<void> {
    this.#dirty = true;
    return (this.#saving ??= Promise.resolve().then(() => this.#flush()));
  }

  async #flush(): Promise<void> {
    try {
      while (this.#dirty) {
        this.#dirty = false;
        await replaceFile(this.#path, JSON.stringify([...this.#ids]));
      }
    } finally {
      this.#saving = null;
    }
  }
}

/// Records by key in one JSON file, kept across a start as `KeptSet` keeps ids: read once before the station serves,
/// written whole as it changes.
export class KeptMap<T> {
  readonly #path: string;
  #map: Map<string, T>;
  #dirty = false;
  #saving: Promise<void> | null = null;

  constructor(path: string) {
    this.#path = path;
    try {
      this.#map = new Map(Object.entries(JSON.parse(readFileSync(path, "utf8")) as Record<string, T>)); // sync: read once, before the station serves
    } catch {
      this.#map = new Map();
    }
  }

  get(key: string): T | undefined {
    return this.#map.get(key);
  }

  entries(): [string, T][] {
    return [...this.#map.entries()];
  }

  async set(key: string, value: T): Promise<void> {
    this.#map.set(key, value);
    await this.#save();
  }

  async delete(key: string): Promise<void> {
    if (!this.#map.delete(key)) return;
    await this.#save();
  }

  #save(): Promise<void> {
    this.#dirty = true;
    return (this.#saving ??= Promise.resolve().then(() => this.#flush()));
  }

  async #flush(): Promise<void> {
    try {
      while (this.#dirty) {
        this.#dirty = false;
        await replaceFile(this.#path, JSON.stringify(Object.fromEntries(this.#map)));
      }
    } finally {
      this.#saving = null;
    }
  }
}

/// Records by key kept across a start, a change a line appended (`{"k": key, "v": record}`, `{"k": key}` let go), so
/// that one item's change writes that item alone however many are kept: read once before the station serves, the
/// lines played in order (one cut short as the station stopped is left out), and written again whole then, once, where
/// they have grown past twice what they say. `from`: a file of before (records by key, one JSON object), taken in and
/// let go as the lines are first written.
export class KeptLog<T> {
  readonly #path: string;
  readonly #map = new Map<string, T>();
  /// What was asked to be written before (a line, the rewrite at a start): each written after it.
  #ready: Promise<void> = Promise.resolve();

  constructor(path: string, from?: { path: string; records: (raw: unknown) => [string, T][] }) {
    this.#path = path;
    let lines = 0;
    let text: string | null = null;
    try {
      text = readFileSync(path, "utf8"); // sync: read once, before the station serves
    } catch {}
    if (text !== null) {
      for (const line of text.split("\n")) {
        if (line === "") continue;
        let r: { k?: unknown; v?: T };
        try {
          r = JSON.parse(line);
        } catch {
          continue;
        }
        if (typeof r?.k !== "string") continue;
        lines++;
        if ("v" in r) this.#map.set(r.k, r.v as T);
        else this.#map.delete(r.k);
      }
      // (written again whole where it grew past twice what it says, or a line was cut short: what follows starts a line)
      if (lines > 2 * this.#map.size + 64 || (text !== "" && !text.endsWith("\n"))) this.#ready = this.#rewrite();
    } else if (from !== undefined) {
      let raw: unknown = null;
      try {
        raw = JSON.parse(readFileSync(from.path, "utf8")); // sync: read once, before the station serves
      } catch {}
      if (raw !== null) {
        for (const [k, v] of from.records(raw)) this.#map.set(k, v);
        this.#ready = this.#rewrite().then(() => rm(from.path, { force: true }));
      }
    }
  }

  /// Once what was asked to be written (the file of before taken in and let go too) is on disk.
  settled(): Promise<void> {
    return this.#ready.catch(() => {});
  }

  get(key: string): T | undefined {
    return this.#map.get(key);
  }
  has(key: string): boolean {
    return this.#map.has(key);
  }
  values(): T[] {
    return [...this.#map.values()];
  }
  keys(): string[] {
    return [...this.#map.keys()];
  }
  get size(): number {
    return this.#map.size;
  }

  async set(key: string, value: T): Promise<void> {
    this.#map.set(key, value);
    await this.#append({ k: key, v: value });
  }

  async delete(key: string): Promise<void> {
    if (!this.#map.delete(key)) return;
    await this.#append({ k: key });
  }

  /// Several changes in one write: each `[key, value]` set, each `[key, undefined]` let go (one not kept: nothing).
  async many(changes: [string, T | undefined][]): Promise<void> {
    const lines: unknown[] = [];
    for (const [k, v] of changes) {
      if (v !== undefined) (this.#map.set(k, v), lines.push({ k, v }));
      else if (this.#map.delete(k)) lines.push({ k });
    }
    if (lines.length > 0) await this.#appendAll(lines);
  }

  #appendAll(lines: unknown[]): Promise<void> {
    const text = lines.map((l) => `${JSON.stringify(l)}\n`).join("");
    const done = this.#ready.catch(() => {}).then(async () => {
      await mkdir(dirname(this.#path), { recursive: true });
      await appendFile(this.#path, text);
    });
    this.#ready = done.catch(() => {});
    return done;
  }

  /// One line more, after those asked before it (in the order the changes were made).
  #append(line: unknown): Promise<void> {
    const text = `${JSON.stringify(line)}\n`;
    const done = this.#ready.catch(() => {}).then(async () => {
      await mkdir(dirname(this.#path), { recursive: true });
      await appendFile(this.#path, text);
    });
    this.#ready = done.catch(() => {});
    return done;
  }

  async #rewrite(): Promise<void> {
    await replaceFile(this.#path, [...this.#map].map(([k, v]) => `${JSON.stringify({ k, v })}\n`).join(""));
  }
}

/// The logins lent for what moved (move/accounts.ts `Lent`), each by its share, and the items each was lent for: a
/// line for a share's record and a line for each item it is lent for (`KeptLog`), so that an item that comes back
/// finds the shares lent for it by its name and writes its own line alone, however many it was lent for with.
export class LentLog<T extends { for: string[] }> {
  readonly #log: KeptLog<Omit<T, "for"> | string>;
  readonly #for = new Map<string, Set<string>>();
  readonly #sharesOf = new Map<string, Set<string>>();
  /// The shares lent (their records' keys).
  readonly #shares = new Set<string>();

  /// `from`: the file of before (each share's record whole, its items in `for`).
  constructor(path: string, from: string) {
    type Line = Omit<T, "for"> | string;
    this.#log = new KeptLog<Line>(path, {
      path: from,
      records: (raw) => Object.entries((raw ?? {}) as Record<string, T>).flatMap(([share, l]): [string, Line][] => {
        const { for: items, ...base } = l;
        return [[`s:${share}`, base], ...(items ?? []).map((n): [string, Line] => [`f:${share}\n${n}`, share])];
      }),
    });
    for (const k of this.#log.keys()) if (k.startsWith("s:")) this.#shares.add(k.slice(2));
    for (const k of this.#log.keys()) if (k.startsWith("f:")) this.#index(k.slice(2, k.indexOf("\n")), k.slice(k.indexOf("\n") + 1), true);
  }

  /// Once what was asked to be written (the file of before taken in and let go too) is on disk (KeptLog `settled`).
  settled(): Promise<void> {
    return this.#log.settled();
  }

  #index(share: string, item: string, on: boolean): void {
    const items = this.#for.get(share) ?? new Set<string>();
    const shares = this.#sharesOf.get(item) ?? new Set<string>();
    if (on) (items.add(item), shares.add(share));
    else (items.delete(item), shares.delete(share));
    if (items.size > 0) this.#for.set(share, items);
    else this.#for.delete(share);
    if (shares.size > 0) this.#sharesOf.set(item, shares);
    else this.#sharesOf.delete(item);
  }

  get(share: string): T | undefined {
    const base = this.#log.get(`s:${share}`);
    return base === undefined || typeof base === "string" ? undefined : ({ ...base, for: [...(this.#for.get(share) ?? [])] } as T);
  }
  /// Every share lent (few: a station's logins).
  entries(): [string, T][] {
    const out: [string, T][] = [];
    for (const share of this.#shares) out.push([share, this.get(share)!]);
    return out;
  }
  /// The shares lent for item `name` (by the item's name).
  sharesFor(name: string): string[] {
    return [...(this.#sharesOf.get(name) ?? [])];
  }
  /// How many items share `share` is lent for.
  forCount(share: string): number {
    return this.#for.get(share)?.size ?? 0;
  }

  /// Share `share`'s record but for what it is lent for.
  base(share: string): Omit<T, "for"> | undefined {
    const base = this.#log.get(`s:${share}`);
    return base === undefined || typeof base === "string" ? undefined : base;
  }
  /// Share `share`'s record but for what it is lent for, written (its items as they were).
  async setBase(share: string, base: Omit<T, "for">): Promise<void> {
    this.#shares.add(share);
    await this.#log.set(`s:${share}`, base);
  }
  /// Share `share`'s record (`for`: the items it is lent for, as they are to be: each one added or taken off its line).
  async set(share: string, l: T): Promise<void> {
    const { for: items, ...base } = l;
    this.#shares.add(share);
    await this.#log.set(`s:${share}`, base);
    const want = new Set(items);
    for (const n of [...(this.#for.get(share) ?? [])]) if (!want.has(n)) await this.unlent(share, n);
    for (const n of want) await this.lentFor(share, n);
  }
  async lentFor(share: string, name: string): Promise<void> {
    if (this.#for.get(share)?.has(name) === true) return;
    this.#index(share, name, true);
    await this.#log.set(`f:${share}\n${name}`, share);
  }
  async unlent(share: string, name: string): Promise<void> {
    if (this.#for.get(share)?.has(name) !== true) return;
    this.#index(share, name, false);
    await this.#log.delete(`f:${share}\n${name}`);
  }
  async delete(share: string): Promise<void> {
    for (const n of [...(this.#for.get(share) ?? [])]) await this.unlent(share, n);
    this.#shares.delete(share);
    await this.#log.delete(`s:${share}`);
  }
}
