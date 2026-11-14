// The connects module (move/AGENTS.md): an item is one connect of this station's (`<id>@<origin>`, as the workspace
// knows it). One of a routed kind (Slack, Feishu) moves by connects/workspace.ts `move` once the chats that came through
// it are there: until then each of its threads is routed to where its chat is. One that is not routed (Comma, a
// single-session connect) runs its chats where it runs: it cannot be moved apart from them, and moving the two as one is
// not built (its plan says so).
import type { Item, ItemState, Module } from "./module.ts";

type Json = any;

export type ConnectsDeps = {
  /// This station's connects of `ws`: id, name, kind, mode.
  own: (ws: string) => { id: string; name: string; kind: string; mode: string }[];
  /// The chat items whose sessions came through connect `id` here (at most a plan's).
  chatsOf: (id: string) => string[];
  /// Where connect `id` (as this station names it) runs now (null: here or not known).
  runsOn: (id: string) => string | null;
  move: (id: string, to: string) => Promise<void>;
  ask: (station: string, request: Json) => Promise<Json>;
  here: () => string;
};

/// A connect's item id: as the workspace knows it.
const itemOf = (id: string, here: string) => (id.includes("@") ? id : `${id}@${here}`);
const localOf = (item: string, here: string) => (item.endsWith(`@${here}`) ? item.slice(0, -here.length - 1) : item);

export function connectsModule(d: ConnectsDeps): Module {
  const moved = new Map<string, string>();
  return {
    id: "connects",
    needs: ["chats"],
    async plan(ws) {
      const here = d.here();
      return d.own(ws).map((c): Item => {
        const routed = (c.kind === "slack" || c.kind === "feishu") && c.mode !== "single-session";
        return {
          module: "connects", id: itemOf(c.id, here), label: c.name, needs: routed ? d.chatsOf(c.id).map((id) => ({ module: "chats", id })) : [],
          ...(routed ? {} : { cannot: `${c.name} (${c.mode === "single-session" ? "one session for all its messages" : c.kind}) runs its chats where it runs: moving it together with its chats is not built yet; move it by hand in the app with its chats paused` }),
        };
      });
    },
    async move(item, to) {
      await d.move(localOf(item.id, d.here()), to);
      moved.set(item.id, to);
    },
    async back(item, from) {
      await d.ask(from, { method: "move.back", module: "connects", id: item.id, to: d.here() });
      moved.delete(item.id);
    },
    state(item): ItemState {
      const on = moved.get(item.id) ?? d.runsOn(localOf(item.id, d.here()));
      return { state: on !== null && on !== d.here() ? "there" : "here" };
    },
  };
}
