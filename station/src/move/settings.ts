// The settings module (move/AGENTS.md): an item is one setting of config.json that is a person's choice, not a fact of
// this machine (`SETTINGS`), `setting:<name>`. Moved: the other station takes this one's value, keeping its own former
// one (`move/settings.json` there); moved back: its former value put back (none: the setting taken out). The machine's
// facts (its data directory, ports, profiles' homes, its connects, accounts) are not settings here: each moves by its
// own module or stays.
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Refused } from "../mesh/bus.ts";
import type { Item, ItemState, Module } from "./module.ts";

type Json = any;

/// The settings that are a person's choice (config.json, as sessions/config.ts and agents/sandbox.ts read them).
export const SETTINGS = ["sandboxes", "agentEnv", "askToName", "maxNudges", "warmMinutes", "maxWarmClaude", "afreshAbove", "afreshWhenCold", "autoArchiveDays", "autoArchiveReviewed", "archivedWorkspaceDays", "slackArchiveDays", "automaticDecisions"] as const;

export type SettingsDeps = {
  data: string;
  config: { raw(): Json; update(f: (raw: Json) => void): void };
  ask: (station: string, request: Json) => Promise<Json>;
};

/// What a move set here: each setting's former value (`had` false: there was none).
type Former = Record<string, { had: boolean; value?: Json; from: string }>;

export class SettingsModule implements Module {
  readonly id = "settings";
  readonly needs = [] as const;
  readonly #d: SettingsDeps;
  readonly #moved = new Set<string>();
  #former: Former;

  constructor(d: SettingsDeps) {
    this.#d = d;
    try {
      this.#former = JSON.parse(readFileSync(join(d.data, "move", "settings.json"), "utf8")) as Former; // sync: read once, before the station serves
    } catch {
      this.#former = {};
    }
  }

  async plan(): Promise<Item[]> {
    const raw = this.#d.config.raw() ?? {};
    return SETTINGS.filter((k) => raw[k] !== undefined).map((k) => ({ module: "settings", id: `setting:${k}`, label: k, needs: [] }));
  }

  async move(item: Item, to: string): Promise<void> {
    const key = item.id.slice("setting:".length);
    await this.#d.ask(to, { method: "move.setting.put", key, value: this.#d.config.raw()?.[key] ?? null });
    this.#moved.add(item.id);
  }

  async back(item: Item, from: string): Promise<void> {
    await this.#d.ask(from, { method: "move.setting.back", key: item.id.slice("setting:".length) });
    this.#moved.delete(item.id);
  }

  state(item: Item): ItemState {
    return { state: this.#moved.has(item.id) ? "there" : "here" };
  }

  async #save(): Promise<void> {
    const path = join(this.#d.data, "move", "settings.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#former));
    await rename(tmp, path);
  }

  /// What another station asks of this one's settings (`move.setting.*`).
  async answer(peer: string, request: Json): Promise<Json> {
    const key = String(request.key ?? "");
    if (!(SETTINGS as readonly string[]).includes(key)) throw new Refused("not a setting that moves");
    if (request.method === "move.setting.put") {
      const raw = this.#d.config.raw() ?? {};
      if (this.#former[key] === undefined) this.#former[key] = { had: raw[key] !== undefined, ...(raw[key] !== undefined ? { value: structuredClone(raw[key]) } : {}), from: peer };
      await this.#save();
      this.#d.config.update((r) => void (r[key] = structuredClone(request.value)));
      return { ok: true };
    }
    if (request.method === "move.setting.back") {
      const f = this.#former[key];
      if (f === undefined) return { ok: true };
      this.#d.config.update((r) => {
        if (f.had) r[key] = f.value;
        else delete r[key];
      });
      delete this.#former[key];
      await this.#save();
      return { ok: true };
    }
    throw new Refused("no such setting request");
  }
}
