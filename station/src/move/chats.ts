// The chats module (move/AGENTS.md): an item is one chat, its session and those that share its still.fail home chat
// (replica/handover.ts `together`), by its session key. It needs the accounts its sessions run on (accounts.ts, by the
// share or key they are known by). Moved by the hand-over (replica/handover.ts); moved back by the same the other way,
// asked of the station it is on (`move.back`). Stopped here, it is held as one being handed over is.
import type { Handover } from "../replica/handover.ts";
import type { Store } from "../store/store.ts";
import { comingWs, handedWs } from "../store/rows.ts";
import type { Item, ItemState, Module, Need, Progress } from "./module.ts";
import { accountItemId } from "./accounts.ts";

type Json = any;

/// The most chats a plan lists of a workspace.
export const PLAN_MOST = 2_000;

export type ChatsDeps = {
  store: Store;
  handover: Handover;
  hub: { holdChat(key: string, why: string): Promise<void>; releaseChat(key: string): boolean };
  /// Its jobs stopped and kept as one being handed over has them (jobs.ts `keep`), and started again here.
  jobs: { keep(keys: string[], why: string): Promise<void>; startKept(keys: string[]): void };
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  /// The sessions of `ws` here (null: the home one's), after `after`, at most `limit`.
  sessionsIn: (ws: string, after: string, limit: number) => string[];
};

export function chatsModule(d: ChatsDeps): Module {
  const keysOf = (item: Item) => d.handover.together(item.id);
  return {
    id: "chats",
    needs: ["accounts"],
    async plan(ws, to) {
      const items: Item[] = [];
      const seen = new Set<string>();
      for (const key of d.sessionsIn(ws, "", PLAN_MOST)) {
        if (seen.has(key)) continue;
        const row = d.store.getSession(key);
        if (row === null || row.ws?.startsWith(comingWs("")) === true) continue;
        const keys = row.ws?.startsWith(handedWs("")) === true ? [key] : d.handover.together(key);
        for (const k of keys) seen.add(k);
        const needs: Need[] = [];
        for (const [pid, a] of d.handover.accountsOf(keys)) {
          const id = accountItemId(pid, a);
          if (!needs.some((n) => n.id === id)) needs.push({ module: "accounts", id });
        }
        const handed = d.store.handedTo(key);
        const why = handed !== null ? null : d.handover.check(key, to);
        items.push({ module: "chats", id: keys[0]!, label: row.title ?? key, needs, ...(why !== null ? { cannot: why } : {}) });
      }
      return items;
    },
    async move(item, to, progress: (p: Progress) => void) {
      await d.handover.handOver(item.id, to, { wait: true, progress });
    },
    async back(item, from) {
      await d.ask(from, { method: "move.back", module: "chats", id: item.id, to: d.here() });
    },
    state(item): ItemState {
      if (d.store.handedTo(item.id) !== null) return { state: "there" };
      const o = d.handover.outOf(item.id);
      if (o === null) return { state: "here" };
      if (o.step === "held" || o.step === "files" || o.step === "rows") return { state: "moving", progress: { done: o.done, total: o.total, unit: "bytes" } };
      if (o.step === "gone") return { state: "there" };
      if (o.step === "failed") return { state: "failed", error: o.error ?? "" };
      return { state: "here" };
    },
    async stop(item, waitsFor) {
      const keys = keysOf(item);
      for (const k of keys) await d.hub.holdChat(k, `stopped: waits for ${waitsFor.module} ${waitsFor.id}, moved away`);
      await d.jobs.keep(keys, `its chat waits for ${waitsFor.module} ${waitsFor.id}, which moved to another station`);
    },
    async resume(item) {
      const keys = keysOf(item);
      for (const k of keys) d.hub.releaseChat(k);
      d.jobs.startKept(keys);
    },
  };
}
