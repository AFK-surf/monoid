// The agent-home module (move/AGENTS.md): an item is a workspace's agent home here (its memory, presets and the skills
// people or agents made: carry-worker.ts `homeFiles`), `home:<ws>`. Moved: its files sent as a chat's are (sending.ts)
// and merged into the agent home there as a retirement merges it (replica/agent-carry.ts), nothing there overwritten;
// what the merge added is kept there (`move/homes.json`). Moved back: exactly that taken out again (the skills it put,
// the presets it added, the memory as it was before).
import { KeptSet } from "./kept.ts";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Refused, withBytes, type Bytes } from "../mesh/bus.ts";
import { mergeAgentHome, type HomeMerged } from "../replica/agent-carry.ts";
import type { CarryIndex, Gathered } from "../replica/carry-worker.ts";
import { lackingIn, receiveFile, sendGathered } from "../replica/sending.ts";
import type { Item, ItemState, Module, Progress } from "./module.ts";

type Json = any;

export type AgentHomeDeps = {
  data: string;
  /// The agent home of `ws` here (a path; it may not be made yet).
  homeOf: (ws: string) => string;
  /// carry-worker.ts's gathering of an agent home alone (no session), in its own thread.
  gather: (agent: string, scratch: string) => Promise<Gathered>;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  name: (station: string, ws: string) => string;
  now: () => number;
  lackMost: number;
};

/// What a move merged here, by workspace (and the station it came from).
type Merged = Record<string, { from: string; merged: HomeMerged }>;

export class AgentHomeModule implements Module {
  readonly id = "agent-home";
  readonly needs = [] as const;
  /// What a move copies stays here too: moving it stops nothing here (scheduler `stops`, `wouldStop`).
  usableHere(): boolean {
    return true;
  }
  readonly #d: AgentHomeDeps;
  readonly #moved: KeptSet;
  readonly #moving = new Map<string, Progress>();
  #merged: Merged;

  constructor(d: AgentHomeDeps) {
    this.#d = d;
    this.#moved = new KeptSet(join(d.data, "move", "agent-home-moved.json"));
    try {
      this.#merged = JSON.parse(readFileSync(join(d.data, "move", "homes.json"), "utf8")) as Merged; // sync: read once, before the station serves
    } catch {
      this.#merged = {};
    }
  }

  async plan(ws: string): Promise<Item[]> {
    return [{ module: "agent-home", id: `home:${ws}`, label: "the agents' memory, presets and skills", needs: [] }];
  }

  async move(item: Item, to: string, progress: (p: Progress) => void): Promise<void> {
    const ws = item.id.slice(5);
    const scratch = join(this.#d.data, "move", "out", `home-${randomBytes(4).toString("hex")}`);
    const p = { done: 0, total: 0, unit: "bytes" };
    this.#moving.set(item.id, p);
    try {
      const g = await this.#d.gather(this.#d.homeOf(ws), scratch);
      const ask = (r: Json) => this.#d.ask(to, { ...r, workspace: ws, ws });
      const index = await sendGathered(g, {
        lacking: (hashes) => ask({ method: "move.home.lacking", hashes }),
        put: (hash, bytes) => this.#d.ask(to, withBytes({ method: "move.home.put", workspace: ws, ws, name: hash }, bytes)),
        most: this.#d.lackMost,
        stopping: () => false,
        total: (bytes) => (p.total = bytes, progress({ ...p })),
        done: (bytes) => (p.done += bytes, progress({ ...p })),
      }, true);
      await ask({ method: "move.home.merge", index });
      await this.#moved.add(item.id);
    } finally {
      this.#moving.delete(item.id);
      await rm(scratch, { recursive: true, force: true });
    }
  }

  async back(item: Item, from: string): Promise<void> {
    const ws = item.id.slice(5);
    await this.#d.ask(from, { method: "move.home.back", workspace: ws, ws });
    await this.#moved.delete(item.id);
  }

  state(item: Item): ItemState {
    const p = this.#moving.get(item.id);
    if (p !== undefined) return { state: "moving", progress: p };
    return { state: this.#moved.has(item.id) ? "there" : "here" };
  }

  async #save(): Promise<void> {
    const path = join(this.#d.data, "move", "homes.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#merged));
    await rename(tmp, path);
  }

  /// What another station asks of this one's agent home (`move.home.*`).
  async answer(peer: string, request: Json, bytes: Bytes | null): Promise<Json> {
    const ws = typeof request.ws === "string" ? request.ws : "";
    const files = join(this.#d.data, "move", "in", "home", ws.replace(/[^A-Za-z0-9_-]/g, "-"), "files");
    switch (request.method) {
      case "move.home.lacking":
        return { lacking: await lackingIn(files, (Array.isArray(request.hashes) ? request.hashes : []).slice(0, this.#d.lackMost)) };
      case "move.home.put":
        if (bytes === null) throw new Refused("no bytes");
        await receiveFile(files, String(request.name ?? ""), bytes);
        return { ok: true };
      case "move.home.merge": {
        const index = JSON.parse(await readFile(join(files, String(request.index ?? "")), "utf8")) as CarryIndex;
        if (!index.agent) return { ok: true };
        if (this.#merged[ws] !== undefined) return { ok: true, merged: this.#merged[ws]!.merged };
        const to = this.#d.homeOf(ws);
        await mkdir(to, { recursive: true });
        const merged = await mergeAgentHome(to, index.agent, join(files, index.agent.list), files, { origin: peer, name: this.#d.name(peer, ws), at: this.#d.now() });
        this.#merged[ws] = { from: peer, merged };
        await this.#save();
        await rm(dirname(files), { recursive: true, force: true });
        return { ok: true, merged };
      }
      case "move.home.back": {
        const m = this.#merged[ws];
        if (m === undefined) return { ok: true };
        const to = this.#d.homeOf(ws);
        for (const name of m.merged.skills) await rm(join(to, "skills", name), { recursive: true, force: true });
        if ((m.merged.presetIds ?? []).length > 0) {
          const text = await readFile(join(to, "presets.json"), "utf8").catch(() => null);
          if (text !== null) {
            const v = JSON.parse(text);
            const gone = new Set(m.merged.presetIds);
            v.presets = (Array.isArray(v.presets) ? v.presets : []).filter((x: Json) => !gone.has(x?.id));
            await writeFile(join(to, "presets.json"), `${JSON.stringify(v, null, 2)}\n`);
          }
        }
        if ((m.merged.memory === "put" || m.merged.memory === "appended") && typeof m.merged.memoryBefore === "string") await writeFile(join(to, "MEMORY.md"), m.merged.memoryBefore);
        delete this.#merged[ws];
        await this.#save();
        return { ok: true };
      }
    }
    throw new Refused("no such agent-home request");
  }
}
