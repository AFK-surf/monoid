// The accounts module (move/AGENTS.md): an item is one account's login, known across the workspace by the share it is
// (`share:<id>`) or the key it runs with (`key:<hash>`); this machine's own login (`machine:<id>`) cannot go. Moved by
// share/index.ts `moveProfile` (one shared is borrowed here after it, so the chats still here keep it: `usableHere`;
// one not shared is gone from here, and what needs it here is stopped first); moved back by the same, asked of the
// station it went to. There once the other station has a profile of it (`move.accounts`, asked as a plan is made).
import type { AccountOf } from "../replica/handover.ts";
import type { Item, ItemState, Module } from "./module.ts";

type Json = any;

/// The item an account of profile `id` is (as handover.ts `accountsOf` knows it).
export const accountItemId = (id: string, a: AccountOf | null) => (a?.share !== undefined ? `share:${a.share}` : a?.key !== undefined ? `key:${a.key}` : a?.own !== undefined ? `own:${a.own}` : `machine:${id}`);

export type AccountsDeps = {
  /// The profiles here that `ws`'s chats run on, each with what it is known by (handover.ts `accountsOf`).
  used: (ws: string) => Map<string, AccountOf | null>;
  /// Whether profile `id` here is shared (a copy of it is borrowed here once it moved).
  shared: (id: string) => boolean;
  /// Its login moved to `to` (share/index.ts `moveProfile`, which refuses in words).
  moveProfile: (id: string, to: string) => Promise<unknown>;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
};

export function accountsModule(d: AccountsDeps): Module {
  /// What the other station said it has, as each plan asked it: by item id, its profile there (null: none).
  const there = new Map<string, string | null>();
  const local = new Map<string, string>();
  const moving = new Set<string>();
  return {
    id: "accounts",
    needs: [],
    async plan(ws, to) {
      const items: Item[] = [];
      const asked: Record<string, AccountOf> = {};
      for (const [pid, a] of d.used(ws)) {
        const id = accountItemId(pid, a);
        if (items.some((x) => x.id === id)) continue;
        local.set(id, pid);
        if (a !== null) asked[id] = a;
        items.push({ module: "accounts", id, label: a?.name ?? pid, needs: [], ...(a === null ? { cannot: `this machine's own login cannot go to another station: sign in there with the login tool` } : {}) });
      }
      const answer = Object.keys(asked).length === 0 ? null : await d.ask(to, { method: "move.accounts", accounts: asked }).catch(() => null);
      for (const id of Object.keys(asked)) there.set(id, typeof answer?.here?.[id] === "string" ? answer.here[id] : null);
      return items;
    },
    async move(item, to) {
      const pid = local.get(item.id);
      if (pid === undefined) throw new Error(`account ${item.label} is not on this station`);
      moving.add(item.id);
      try {
        const answer = (await d.moveProfile(pid, to)) as Json;
        there.set(item.id, typeof answer?.id === "string" ? answer.id : pid);
      } finally {
        moving.delete(item.id);
      }
    },
    async back(item, from) {
      await d.ask(from, { method: "move.back", module: "accounts", id: item.id, to: d.here() });
      there.set(item.id, null);
    },
    state(item): ItemState {
      if (moving.has(item.id)) return { state: "moving" };
      return { state: typeof there.get(item.id) === "string" ? "there" : "here" };
    },
    usableHere(item) {
      const pid = local.get(item.id);
      return pid !== undefined && d.shared(pid);
    },
  };
}
