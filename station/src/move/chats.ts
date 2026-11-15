// The chats module (move/AGENTS.md): an item is one chat, its session and those that share its still.fail home chat
// (replica/handover.ts `together`), by its session key. It needs the accounts its sessions run on (accounts.ts, by the
// share or key they are known by). Moved by the hand-over (replica/handover.ts); moved back by the same the other way,
// asked of the station it is on (`move.back`). Stopped here, it is held as one being handed over is.
import { type Handover, liveHereWords } from "../replica/handover.ts";
import type { Store } from "../store/store.ts";
import { type SessionRow, comingWs, handedWs } from "../store/rows.ts";
import { type Item, type ItemState, type Module, type Need, type PlanReads, type Progress, Said, unanswered, notAnswered } from "./module.ts";
import { repoItemId } from "./repos.ts";
import { stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { accountItemId } from "./accounts.ts";
import { connectItemId } from "./connects.ts";

/// The most a move back waits for the chat it brings to be shown here once the other answered it went: twice an answer's
/// bound (mesh/peer.ts, 30 s), what the other's word told again takes where it is up.
export const ARRIVE_WAIT_MS = 60_000;

/// A chat as people call it where it has no title: its key without still.fail's own prefix.
export const shortKey = (key: string) => key.replace(/^chat:/, "");

type Json = any;

/// The chats a plan reads of a workspace at a time: it reads them all, a page at a time (Office-VM-1 had 2,384, of
/// which a bound of 2,000 left 384 never moved, and its done of total wrong), each page in a few statements whatever
/// its chats (store.ts `SessionPage`), the loop given back between pages (`giveBack`).
export const PLAN_PAGE = 200;

/// The main thread given back between a plan's pages: what waits behind it goes first, so that no hold of it grows
/// with the chats.
export const giveBack = () => new Promise<void>((resolve) => setImmediate(resolve));

export type ChatsDeps = {
  store: Store;
  handover: Handover;
  hub: { holdChat(key: string, why: string, notice?: () => string): Promise<void>; releaseChat(key: string): boolean; busy?(key: string): boolean };
  /// What people call station `id` (its id's start where the roster has no name).
  name?: (id: string) => string;
  /// Its jobs stopped and kept as one being handed over has them (jobs.ts `keep`), and started again here.
  jobs: { keep(keys: string[], why: string): Promise<void>; startKept(keys: string[]): void };
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
  /// How connect `id` goes (connects/workspace.ts `kindOf`; null: not known).
  kindOf: (id: string) => { kind: string; mode: string } | null;
  /// The vault items (vault.ts) of the owners whose grants each of sessions `keys` holds (one read for them all).
  vaultsOf: (keys: string[], ws: string) => Map<string, string[]>;
  /// Whether a busy chat's turn is waited for as it moves (station_move `wait`; none: it is).
  wait?: () => boolean;
  /// What a plan of `ws` reads once (move/station.ts), where the scheduler gave none.
  reads: (ws: string) => PlanReads;
};

export function chatsModule(d: ChatsDeps): Module {
  const keysOf = (item: Item) => d.handover.together(item.id);
  return {
    id: "chats",
    needs: ["accounts", "connects", "repos", "vault"],
    async plan(ws, to, given) {
      const items: Item[] = [];
      const seen = new Set<string>();
      const plan = given ?? d.reads(ws);
      /// What the other station was asked of its live chats in this plan, and what it named live (one line a plan).
      let askedLive = 0;
      let saidLive = 0;
      for await (const reads of plan.pages()) {
        const kept: { key: string; row: SessionRow; keys: string[] }[] = [];
        for (const row of reads.rows()) {
          const key = row.key;
          if (seen.has(key)) continue;
          if (row.ws?.startsWith(comingWs("")) === true) continue;
          const keys = row.ws?.startsWith(handedWs("")) === true ? [key] : d.handover.together(key, reads);
          for (const k of keys) seen.add(k);
          kept.push({ key, row, keys });
        }
        const grants = d.vaultsOf([...new Set(kept.flatMap((x) => x.keys))], ws);
        // (a chat of a key live there already went on there apart from this one: it cannot go, never merged into;
        // asked once a page; not answered, whether it has them is not guessed: the page's chats here cannot go this turn,
        // nothing of them tried (the hand-over asks it again at its begin all the same))
        const asking = kept.filter((x) => d.store.handedTo(x.key) === null).flatMap((x) => x.keys);
        let failed: unknown = null;
        const there = asking.length === 0 || to === "" ? null : await d.ask(to, { method: "move.chats.live", keys: asking }).catch((e) => ((failed = notAnswered("move.chats.live", to, e)), null));
        const liveThere = new Set<string>(Array.isArray(there?.live) ? there.live.filter((k: unknown): k is string => typeof k === "string") : []);
        if (there !== null) (askedLive += asking.length), (saidLive += liveThere.size);
        const thereName = typeof there?.name === "string" && there.name !== "" ? there.name : to.slice(0, 12);
        for (const { key, row, keys } of kept) {
          const needs: Need[] = [];
          for (const [pid, a] of d.handover.accountsOf(keys, reads)) {
            const id = accountItemId(pid, a);
            if (!needs.some((n) => n.id === id)) needs.push({ module: "accounts", id });
          }
          // (one of a connect that is not routed needs that connect there: it runs where its connect runs)
          for (const k of keys) {
            const c = reads.session(k)?.connect ?? "";
            if (c === "" || c === "ember" || c === "chat") continue;
            const kind = d.kindOf(c);
            if (kind !== null && (kind.mode === "single-session" || (kind.kind !== "slack" && kind.kind !== "feishu"))) {
              const id = connectItemId(c, d.here());
              if (!needs.some((n) => n.id === id)) needs.push({ module: "connects", id });
            }
          }
          // (the repositories its linked worktrees hang on; its owner's secrets where it holds a grant of them)
          const repos = new Set<string>();
          for (const k of keys) {
            const s = reads.session(k);
            if (s !== null) for (const r of await plan.worktrees(s.workspace)) repos.add(repoItemId(r.url));
          }
          for (const id of repos) needs.push({ module: "repos", id });
          for (const id of new Set(keys.flatMap((k) => grants.get(k) ?? []))) needs.push({ module: "vault", id });
          const handed = d.store.handedTo(key);
          const live = handed !== null ? [] : keys.filter((k) => liveThere.has(k));
          const unknown = handed === null && failed !== null;
          const why = handed !== null ? null : unknown ? unanswered(failed) : live.length > 0 ? liveHereWords(live, thereName) : d.handover.check(key, to, { planning: true, reads });
          items.push({ module: "chats", id: keys[0]!, label: row.title ?? key, needs, ...(why !== null ? { cannot: why } : {}), ...(unknown ? { again: true as const } : {}) });
        }
      }
      if (askedLive > 0) log.info("move", "the other station asked which chats are live there", { station: to.slice(0, 12), asked: askedLive, live: saidLive });
      // (a chat coming here, not shown yet, is out of the pages (its rows `coming:`): listed by its arrival's record,
      // moving, by the row it had here where it had one)
      for (const keys of d.handover.comingIn(ws)) {
        if (keys.some((k) => seen.has(k))) continue;
        for (const k of keys) seen.add(k);
        items.push({ module: "chats", id: keys[0]!, label: d.store.getSession(keys[0]!)?.title ?? keys[0]!, needs: [] });
      }
      return items;
    },
    abandon() {
      d.handover.abandon();
    },
    async ready(item) {
      // (one in a turn, not to be waited for: refused as its hand-over would refuse it, before anything moves for it)
      if (d.wait?.() !== false) return null;
      const busy = keysOf(item).find((k) => d.hub.busy?.(k) === true);
      return busy === undefined ? null : tr(stationLang(), "station.move.why.inTurn", { chat: d.store.getSession(busy)?.title ?? shortKey(busy) });
    },
    async move(item, to, progress: (p: Progress) => void, opts) {
      await d.handover.handOver(item.id, to, { wait: d.wait?.() ?? true, progress, stoppedFor: opts?.stoppedFor });
    },
    async back(item, from, opts) {
      await d.ask(from, { method: "move.back", module: "chats", id: item.id, to: d.here(), ...(opts?.stoppedFor ? { stoppedFor: opts.stoppedFor } : {}) });
      // (back once shown here, not before: the other may answer having gone on without our word that it is shown; one
      // that does not come in the time the other is told again, the other gone since, is on its way, said so)
      for (const k of keysOf(item)) {
        if (await d.handover.arrived(k, ARRIVE_WAIT_MS)) continue;
        throw new Said(tr(stationLang(), "station.move.onItsWay", { station: d.name?.(from) ?? from.slice(0, 12) }));
      }
    },
    state(item): ItemState {
      const o = d.handover.outOf(item.id);
      // (gone, not shown there yet: still moving, its page served here as it went)
      if (o !== null && o.step === "gone" && !o.shown) return { state: "moving", progress: { done: o.done, total: o.total, unit: "bytes" } };
      // (coming here: moving until it is shown here, whatever its row's `handed_over` still says; it waits for the
      // station it comes from to go on with it)
      const from = d.handover.comingFrom(item.id);
      if (from !== null) return { state: "moving", waits: "station", from };
      const handed = d.store.handedTo(item.id);
      if (handed !== null) return { state: "there", at: handed.station };
      // (where it went is no longer said here: here, whatever a record of an older trip says)
      if (o === null) return { state: "here" };
      if (o.step === "held" || o.step === "files" || o.step === "rows") return { state: "moving", progress: { done: o.done, total: o.total, unit: "bytes" }, ...(d.handover.waitsForTurn(o) ? { waits: "turn" as const } : {}) };
      if (o.step === "failed") return { state: "failed", error: o.error ?? "" };
      return { state: "here" };
    },
    async stop(item, waitsFor) {
      const keys = keysOf(item);
      // (said once in the chat as a person next speaks in it, not by the stop: station's words, in its language)
      const name = (id: string) => d.name?.(id) ?? id.slice(0, 12);
      const notice = () => tr(stationLang(), waitsFor.at === undefined ? "station.move.stoppedChatHere" : "station.move.stoppedChat", { here: name(d.here()), item: waitsFor.label ?? `${waitsFor.module} ${waitsFor.id}`, there: waitsFor.at === undefined ? "" : name(waitsFor.at) });
      for (const k of keys) await d.hub.holdChat(k, `stopped: waits for ${waitsFor.module} ${waitsFor.id}, moved away`, notice);
      await d.jobs.keep(keys, `its chat waits for ${waitsFor.module} ${waitsFor.id}, which moved to another station`);
    },
    async resume(item) {
      const keys = keysOf(item);
      for (const k of keys) d.hub.releaseChat(k);
      d.jobs.startKept(keys);
    },
  };
}
