// The settings module (move/AGENTS.md): an item is one setting of config.json that is a person's choice, not a fact of
// this machine (`SETTINGS`), `setting:<name>`. What the other station has already is not overwritten (the owner's
// rule: 「不好搬但有其它办法规避的部分直接规避，避免脚本乱改改错」; it has chats of its own that rely on it): a setting it
// lacks it takes; one it has the same is left; a map (`sandboxes`, `agentEnv`) takes the keys it lacks and keeps its
// own for the rest; another value of its own it keeps, and the item cannot move, saying so. What it added is kept
// there (`move/settings.json`), so moving back takes out exactly that. The machine's
// facts (its data directory, ports, profiles' homes, its connects, accounts) are not settings here: each moves by its
// own module or stays.
import { KeptSet } from "./kept.ts";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Refused } from "../mesh/bus.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { type Item, type ItemState, type Module, unanswered, notAnswered } from "./module.ts";

type Json = any;

/// The settings that are a person's choice (config.json, as sessions/config.ts and agents/sandbox.ts read them).
export const SETTINGS = ["sandboxes", "agentEnv", "askToName", "maxNudges", "warmMinutes", "maxWarmClaude", "maxConcurrentTurns", "afreshAbove", "afreshWhenCold", "autoArchiveDays", "autoArchiveKeep", "autoArchiveReviewed", "archivedWorkspaceDays", "slackArchiveDays", "automaticDecisions", "acceptAutoChats"] as const;

export type SettingsDeps = {
  data: string;
  config: { raw(): Json; updateSoon(f: (raw: Json) => void): Promise<unknown> };
  ask: (station: string, request: Json) => Promise<Json>;
};

/// What a move added here, by setting: the whole setting (`whole`), or the keys of a map (`keys`). (`had`/`value`: one
/// written by a station from before this, its former value.)
type Former = Record<string, { from: string; whole?: boolean; keys?: string[]; had?: boolean; value?: Json }>;

const isMap = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

export class SettingsModule implements Module {
  readonly id = "settings";
  readonly needs = [] as const;
  /// What a move copies stays here too: moving it stops nothing here (scheduler `stops`, `wouldStop`).
  usableHere(): boolean {
    return true;
  }
  readonly #d: SettingsDeps;
  readonly #moved: KeptSet;
  #former: Former;

  constructor(d: SettingsDeps) {
    this.#d = d;
    this.#moved = new KeptSet(join(d.data, "move", "settings-moved.json"));
    try {
      this.#former = JSON.parse(readFileSync(join(d.data, "move", "settings.json"), "utf8")) as Former; // sync: read once, before the station serves
    } catch {
      this.#former = {};
    }
  }

  /// Its settings, each asked of `to` once (one request): one there of another value of its own cannot move.
  async plan(_ws: string, to: string): Promise<Item[]> {
    const raw = this.#d.config.raw() ?? {};
    const keys = SETTINGS.filter((k) => raw[k] !== undefined);
    // (not answered: whether it has its own is not guessed, nothing of them goes this turn)
    let failed: unknown = null;
    const there = to === "" || keys.length === 0 ? null : ((await this.#d.ask(to, { method: "move.setting.values", key: "agentEnv", keys }).catch((e) => ((failed = notAnswered("move.setting.values", to, e)), null)))?.values as Record<string, Json> | undefined) ?? null;
    return keys.map((k) => {
      const theirs = there?.[k];
      const cannot = failed !== null ? unanswered(failed) : theirs === undefined || theirs === null || same(theirs, raw[k]) || (isMap(theirs) && isMap(raw[k])) || this.#moved.has(`setting:${k}`)
        ? undefined
        : tr(stationLang(), "station.move.sched.settingThere", { key: k, value: JSON.stringify(theirs).slice(0, 80) });
      return { module: "settings", id: `setting:${k}`, label: k, needs: [], ...(cannot !== undefined ? { cannot, ...(failed !== null ? { again: true as const } : {}) } : {}) };
    });
  }

  async move(item: Item, to: string): Promise<void> {
    const key = item.id.slice("setting:".length);
    await this.#d.ask(to, { method: "move.setting.put", key, value: this.#d.config.raw()?.[key] ?? null });
    await this.#moved.add(item.id);
  }

  async back(item: Item, from: string): Promise<void> {
    await this.#d.ask(from, { method: "move.setting.back", key: item.id.slice("setting:".length) });
    await this.#moved.delete(item.id);
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
    if (request.method === "move.setting.values") {
      const raw = this.#d.config.raw() ?? {};
      const asked: string[] = Array.isArray(request.keys) ? request.keys.filter((k: unknown): k is string => typeof k === "string" && (SETTINGS as readonly string[]).includes(k)) : [];
      return { values: Object.fromEntries(asked.map((k) => [k, raw[k] ?? null])) };
    }
    if (request.method === "move.setting.put") {
      const raw = this.#d.config.raw() ?? {};
      const mine = raw[key];
      const value = request.value;
      if (this.#former[key] !== undefined) return { ok: true };
      if (mine === undefined || mine === null) {
        this.#former[key] = { from: peer, whole: true };
        await this.#save();
        await this.#d.config.updateSoon((r) => void (r[key] = structuredClone(value)));
        return { ok: true };
      }
      if (same(mine, value)) return { ok: true };
      if (isMap(mine) && isMap(value)) {
        const keys = Object.keys(value).filter((k) => !(k in mine));
        if (keys.length === 0) return { ok: true };
        this.#former[key] = { from: peer, keys };
        await this.#save();
        await this.#d.config.updateSoon((r) => {
          r[key] = { ...(isMap(r[key]) ? r[key] : {}) };
          for (const k of keys) r[key][k] = structuredClone(value[k]);
        });
        return { ok: true };
      }
      throw new Refused(tr(stationLang(), "station.move.sched.settingHere", { key }));
    }
    if (request.method === "move.setting.back") {
      const f = this.#former[key];
      if (f === undefined) return { ok: true };
      await this.#d.config.updateSoon((r) => {
        if (f.whole === true) delete r[key];
        else if (f.keys !== undefined) {
          if (isMap(r[key])) {
            r[key] = { ...r[key] };
            for (const k of f.keys) delete r[key][k];
          }
        } else if (f.had === true) r[key] = f.value;
        else delete r[key];
      });
      delete this.#former[key];
      await this.#save();
      return { ok: true };
    }
    throw new Refused("no such setting request");
  }
}
