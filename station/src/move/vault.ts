// The vault module (move/AGENTS.md): an item is one owner's secrets kept on this station (`vault:<email>`): their plain
// library's items (vault/plain.ts) and the vaults they own with their items (vault/store.ts: ciphertext only). Moved:
// the other station holds them too, sent station to station inside the workspace (`move.vault.put`, a page at a time):
// no weaker than here, as the plain library is the station's to read wherever it is, and a vault's rows are opaque to
// every station. Moved back: the other lets go of exactly what this move put there (`move/vaults.json` there), never
// what it had. Grants are not moved: a vault's is sealed to this station's keeper (its request's `box`) and lives in
// its memory, a plain one is taken up only as a station starts (vault/secrets.ts `#restore`), so a chat that holds one
// asks its owner again where it goes; it needs its owner's item there for that (chats.ts).
import { KeptSet } from "./kept.ts";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Refused } from "../mesh/bus.ts";
import type { PlainItem } from "../vault/plain.ts";
import type { Item, ItemState, Module } from "./module.ts";

type Json = any;
const PAGE = 200;

export const vaultItemId = (owner: string) => `vault:${owner}`;

export type VaultDeps = {
  data: string;
  /// The owners with secrets of `ws` here (at most a plan's).
  owners: (ws: string) => string[];
  plain: { items(ws: string, owner: string): PlainItem[]; item(ws: string, id: string): PlainItem | null; put(i: PlainItem): void; forget(ws: string, id: string): void };
  vaults: {
    vaults(ws: string): Json[]; vault(ws: string, id: string): Json | null; items(ws: string, vault: string): Json[]; item(ws: string, vault: string, id: string): Json | null;
    putVault(v: Json): void; putItem(i: Json): void; forgetItem(ws: string, vault: string, id: string): void; forgetVault(ws: string, id: string): void;
  };
  ask: (station: string, request: Json) => Promise<Json>;
};

/// What moves put here, by workspace and owner: the plain items, vaults and vault items there were none of before.
type Put = Record<string, { plain: string[]; vaults: string[]; items: [string, string][] }>;

export class VaultModule implements Module {
  readonly id = "vault";
  readonly needs = [] as const;
  /// What a move copies stays here too: moving it stops nothing here (scheduler `stops`, `wouldStop`).
  usableHere(): boolean {
    return true;
  }
  readonly #d: VaultDeps;
  readonly #moved: KeptSet;
  #put: Put;

  constructor(d: VaultDeps) {
    this.#d = d;
    this.#moved = new KeptSet(join(d.data, "move", "vault-moved.json"));
    try {
      this.#put = JSON.parse(readFileSync(join(d.data, "move", "vaults.json"), "utf8")) as Put; // sync: read once, before the station serves
    } catch {
      this.#put = {};
    }
  }

  async plan(ws: string): Promise<Item[]> {
    return this.#d.owners(ws).map((owner) => ({ module: "vault", id: `${vaultItemId(owner)}@${ws}`, label: `${owner}'s secrets`, needs: [] }));
  }

  #of(item: Item): { owner: string; ws: string } {
    const rest = item.id.slice("vault:".length);
    const at = rest.lastIndexOf("@");
    return { owner: rest.slice(0, at), ws: rest.slice(at + 1) };
  }

  async move(item: Item, to: string): Promise<void> {
    const { owner, ws } = this.#of(item);
    const plain = this.#d.plain.items(ws, owner);
    for (let i = 0; i < plain.length || i === 0; i += PAGE) await this.#d.ask(to, { method: "move.vault.put", workspace: ws, ws, owner, plain: plain.slice(i, i + PAGE) });
    for (const v of this.#d.vaults.vaults(ws).filter((x) => x?.owner === owner)) {
      const items = this.#d.vaults.items(ws, v.id);
      for (let i = 0; i < items.length || i === 0; i += PAGE) await this.#d.ask(to, { method: "move.vault.put", workspace: ws, ws, owner, vault: v, items: items.slice(i, i + PAGE) });
    }
    await this.#moved.add(item.id);
  }

  async back(item: Item, from: string): Promise<void> {
    const { owner, ws } = this.#of(item);
    await this.#d.ask(from, { method: "move.vault.back", workspace: ws, ws, owner });
    await this.#moved.delete(item.id);
  }

  state(item: Item): ItemState {
    return { state: this.#moved.has(item.id) ? "there" : "here" };
  }

  async #save(): Promise<void> {
    const path = join(this.#d.data, "move", "vaults.json");
    await mkdir(dirname(path), { recursive: true });
    const tmp = `${path}.${randomBytes(4).toString("hex")}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#put));
    await rename(tmp, path);
  }

  /// What another station asks of this one's vaults (`move.vault.*`).
  async answer(request: Json): Promise<Json> {
    const ws = typeof request.ws === "string" ? request.ws : "";
    const owner = typeof request.owner === "string" ? request.owner : "";
    if (ws === "" || owner === "") throw new Refused("no owner named");
    const key = `${ws}\u0000${owner}`;
    const put = (this.#put[key] ??= { plain: [], vaults: [], items: [] });
    if (request.method === "move.vault.put") {
      for (const i of (Array.isArray(request.plain) ? request.plain : []).slice(0, PAGE) as PlainItem[]) {
        if (i?.ws !== ws || i.owner !== owner) continue;
        const had = this.#d.plain.item(ws, i.id);
        if (had !== null && had.version >= i.version) continue;
        if (had === null && !put.plain.includes(i.id)) put.plain.push(i.id);
        this.#d.plain.put(i);
      }
      const v = request.vault;
      if (v !== undefined && v?.ws === ws && v.owner === owner) {
        const had = this.#d.vaults.vault(ws, v.id);
        if (had === null) {
          if (!put.vaults.includes(v.id)) put.vaults.push(v.id);
          this.#d.vaults.putVault(v);
        } else if ((had.seq ?? 0) < (v.seq ?? 0)) this.#d.vaults.putVault(v);
        for (const i of (Array.isArray(request.items) ? request.items : []).slice(0, PAGE)) {
          if (i?.ws !== ws || i.vault !== v.id) continue;
          const was = this.#d.vaults.item(ws, v.id, i.id);
          if (was !== null && (was.version ?? 0) >= (i.version ?? 0)) continue;
          if (was === null && !put.items.some(([a, b]) => a === v.id && b === i.id)) put.items.push([v.id, i.id]);
          this.#d.vaults.putItem(i);
        }
      }
      await this.#save();
      return { ok: true };
    }
    if (request.method === "move.vault.back") {
      for (const id of put.plain) this.#d.plain.forget(ws, id);
      for (const [vault, id] of put.items) this.#d.vaults.forgetItem(ws, vault, id);
      for (const id of put.vaults) this.#d.vaults.forgetVault(ws, id);
      delete this.#put[key];
      await this.#save();
      return { ok: true };
    }
    throw new Refused("no such vault request");
  }
}
