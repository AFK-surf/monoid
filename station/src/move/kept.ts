// Which of a module's items moved from here, kept across a start (move/AGENTS.md: each item's state is its module's,
// durable): a set of item ids in one JSON file, read once before the station serves, written whole as it changes.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
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
