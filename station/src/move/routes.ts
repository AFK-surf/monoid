// What the app shows of a migration (move/AGENTS.md): `GET /move?to=<station>` answers, for the asker's workspace and
// that station, the modules in order with their needs, each module's done of total and a page of its items (label,
// state, what it needs and waits for, why it cannot move, its error, the moving one's progress inside it). `module` and
// `after` page one module's items further; `limit` (at most 200) is a page's. Told changed as `move` on the event
// stream (move/live.ts), which a device reads it again on; it is never asked again on a timer.
import type { Route } from "../api/admin.ts";
import { error, ok, param } from "../api/request.ts";
import { named } from "./module.ts";
import type { Plan, Scheduler } from "./scheduler.ts";

type Json = any;

export const MOVE_PAGE = 50;
export const MOVE_PAGE_MOST = 200;

/// The answer of GET /move for `plan`: `module`/`after` the page of one module that goes on from `after`.
export function moveView(plan: Plan, order: string[], stopped: { item: { module: string; id: string }; waitsFor: { module: string; id: string } }[], o: { module?: string; after?: string; limit?: number } = {}): Json {
  const limit = Math.min(Math.max(o.limit ?? MOVE_PAGE, 1), MOVE_PAGE_MOST);
  const moving = plan.items.find((x) => x.state === "moving") ?? null;
  return {
    ws: plan.ws,
    to: plan.to,
    modules: order.map((id) => {
      const mine = plan.items.filter((x) => x.module === id);
      const from = o.module === id && o.after !== undefined ? mine.findIndex((x) => x.id === o.after) + 1 : 0;
      const page = mine.slice(from, from + limit);
      return {
        id,
        needs: plan.modules.find((m) => m.id === id)?.needs ?? [],
        done: mine.filter((x) => x.state === "there").length,
        total: mine.length,
        items: page.map((x) => ({
          id: x.id, label: x.label, state: x.state, needs: x.needs.map(named),
          ...(x.waitsFor ? { waitsFor: named(x.waitsFor) } : {}),
          ...(x.cannot !== undefined ? { cannot: x.cannot } : {}),
          ...(x.error ? { error: x.error } : {}),
          ...(x.progress ? { progress: x.progress } : {}),
          ...(x.wouldStop.length > 0 ? { wouldStop: x.wouldStop.map(named) } : {}),
        })),
        more: from + limit < mine.length ? page.at(-1)?.id ?? null : null,
      };
    }),
    moving: moving === null ? null : { module: moving.module, id: moving.id, label: moving.label, progress: moving.progress ?? null },
    stopped: stopped.map((s) => ({ item: named(s.item), waitsFor: named(s.waitsFor) })),
  };
}

export function moveRoutes(d: { scheduler: Scheduler; order: () => string[]; home: () => string | null; station: (ws: string, v: string) => string | null }): Route[] {
  return [
    {
      method: "GET",
      pattern: /^\/move\/?$/,
      handle: async (r) => {
        const ws = r.viewer.workspace ?? d.home();
        if (ws === null) return error(404, "this station is in no workspace");
        const given = param(r, "to") ?? "";
        const to = given === "" ? "" : d.station(ws, given);
        if (to === null) return error(400, `no station ${given} in this workspace`);
        try {
          const plan = await d.scheduler.plan(ws, to);
          const limit = Number(param(r, "limit") ?? MOVE_PAGE);
          return ok(moveView(plan, d.order(), d.scheduler.stopped(), { module: param(r, "module") ?? undefined, after: param(r, "after") ?? undefined, limit: Number.isFinite(limit) ? limit : MOVE_PAGE }));
        } catch (e) {
          return error(409, (e as Error).message);
        }
      },
    },
  ];
}
