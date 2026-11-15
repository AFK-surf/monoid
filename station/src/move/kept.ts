// Which of a module's items moved from here, kept across a start (move/AGENTS.md: each item's state is its module's,
// durable): a set of item ids in one JSON file, read once before the station serves, written whole as it changes.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { appendFile, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

export class KeptSet {
  readonly #path: string;
  #ids: Set<string>;

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

  async add(id: string): Promise<void> {
    if (this.#ids.has(id)) return;
    this.#ids.add(id);
    await this.#save();
  }

  async delete(id: string): Promise<void> {
    if (!this.#ids.delete(id)) return;
    await this.#save();
  }

  async #save(): Promise<void> {
    await mkdir(dirname(this.#path), { recursive: true });
    const tmp = `${this.#path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify([...this.#ids]));
    await rename(tmp, this.#path);
  }
}

/// Records by key in one JSON file, kept across a start as `KeptSet` keeps ids: read once before the station serves,
/// written whole as it changes.
export class KeptMap<T> {
  readonly #path: string;
  #map: Map<string, T>;

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

  async #save(): Promise<void> {
    await mkdir(dirname(this.#path), { recursive: true });
    const tmp = `${this.#path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(Object.fromEntries(this.#map)));
    await rename(tmp, this.#path);
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

  get(key: string): T | undefined {
    return this.#map.get(key);
  }
  has(key: string): boolean {
    return this.#map.has(key);
  }
  values(): T[] {
    return [...this.#map.values()];
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
    await mkdir(dirname(this.#path), { recursive: true });
    const tmp = `${this.#path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, [...this.#map].map(([k, v]) => `${JSON.stringify({ k, v })}\n`).join(""));
    await rename(tmp, this.#path);
  }
}
