// The chats module (move/AGENTS.md): an item is one chat, its session and those that share its still.fail home chat
// (replica/handover.ts `together`), by its session key. It needs the accounts its sessions run on (accounts.ts, by the
// share or key they are known by). Moved by the hand-over (replica/handover.ts); moved back by the same the other way,
// asked of the station it is on (`move.back`). Stopped here, it is held as one being handed over is.
import type { Handover } from "../replica/handover.ts";
import type { Store } from "../store/store.ts";
import { comingWs, handedWs } from "../store/rows.ts";
import type { Item, ItemState, Module, Need, Progress } from "./module.ts";
import { accountItemId } from "./accounts.ts";
import { connectItemId } from "./connects.ts";

type Json = any;

/// The chats a plan reads of a workspace at a time: it reads them all, a page at a time (Office-VM-1 had 2,384, of
/// which a bound of 2,000 left 384 never moved, and its done of total wrong).
export const PLAN_PAGE = 500;

export type ChatsDeps = {
  store: Store;
  handover: Handover;
  hub: { holdChat(key: string, why: string): Promise<void>; releaseChat(key: string): boolean };
  /// Its jobs stopped and kept as one being handed over has them (jobs.ts `keep`), and started again here.
  jobs: { keep(keys: string[], why: string): Promise<void>; startKept(keys: string[]): void };
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  /// How connect `id` goes (connects/workspace.ts `kindOf`; null: not known).
  kindOf: (id: string) => { kind: string; mode: string } | null;
  /// The repos items (repos.ts) the linked worktrees of sessions `keys` hang on, and the vault items (vault.ts) of the
  /// owners whose grants they hold.
  reposOf: (keys: string[]) => Promise<string[]>;
  vaultsOf: (keys: string[], ws: string) => string[];
  /// Whether a busy chat's turn is waited for as it moves (station_move `wait`; none: it is).
  wait?: () => boolean;
  /// The sessions of `ws` here (null: the home one's), after `after`, at most `limit`.
  sessionsIn: (ws: string, after: string, limit: number) => string[];
  /// A page's size (`PLAN_PAGE`; a test's smaller).
  page?: number;
};

export function chatsModule(d: ChatsDeps): Module {
  const keysOf = (item: Item) => d.handover.together(item.id);
  return {
    id: "chats",
    needs: ["accounts", "connects", "repos", "vault"],
    async plan(ws, to) {
      const items: Item[] = [];
      const seen = new Set<string>();
      const page = d.page ?? PLAN_PAGE;
      const keys: string[] = [];
      for (let after = ""; ; ) {
        const got = d.sessionsIn(ws, after, page);
        keys.push(...got);
        if (got.length < page) break;
        after = got.at(-1)!;
      }
      for (const key of keys) {
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
        // (one of a connect that is not routed needs that connect there: it runs where its connect runs)
        for (const k of keys) {
          const c = d.store.getSession(k)?.connect ?? "";
          if (c === "" || c === "ember" || c === "chat") continue;
          const kind = d.kindOf(c);
          if (kind !== null && (kind.mode === "single-session" || (kind.kind !== "slack" && kind.kind !== "feishu"))) {
            const id = connectItemId(c, d.here());
            if (!needs.some((n) => n.id === id)) needs.push({ module: "connects", id });
          }
        }
        // (the repositories its linked worktrees hang on; its owner's secrets where it holds a grant of them)
        for (const id of await d.reposOf(keys)) needs.push({ module: "repos", id });
        for (const id of d.vaultsOf(keys, ws)) needs.push({ module: "vault", id });
        const handed = d.store.handedTo(key);
        const why = handed !== null ? null : d.handover.check(key, to, { planning: true });
        items.push({ module: "chats", id: keys[0]!, label: row.title ?? key, needs, ...(why !== null ? { cannot: why } : {}) });
      }
      return items;
    },
    abandon() {
      d.handover.abandon();
    },
    async move(item, to, progress: (p: Progress) => void, opts) {
      await d.handover.handOver(item.id, to, { wait: d.wait?.() ?? true, progress, stoppedFor: opts?.stoppedFor });
    },
    async back(item, from, opts) {
      await d.ask(from, { method: "move.back", module: "chats", id: item.id, to: d.here(), ...(opts?.stoppedFor ? { stoppedFor: opts.stoppedFor } : {}) });
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
