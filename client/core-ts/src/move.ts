// Moving a station's things to another station of its workspace, module by module (the station's move/: GET /move),
// as its page draws it (the `stationMove` topic): the stations it may go to, what moves now, each module in the order
// the station gives (their needs first) with its needs, done of total and the one action at its first line, and, of
// the module asked, its items a row each with where it stands in words (the owner, 2026-11-14: 「字太多了，应该用更结构化
// 更所见即所得的方式设计 UI」: no sentence about it, the rows and counts say it). Why something did not move (the
// station's `last`: refused, failed) is said on the row it is about, never in a dialog. Everything said is made here;
// the page only draws it.
import * as format from "./format.ts";
import { t } from "./i18n.ts";
import { isObject } from "./util.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// A page of a module's items as the station gives it (station move/routes.ts MOVE_PAGE), and the most the page shows
/// of one module, a page at a time as its list is scrolled to its end (what keeps the topic under its bar).
export const MOVE_PAGE = 50;
export const MOVE_SHOWN_MOST = 200;

/// The modules the station names (move/AGENTS.md), each as people call it; one the app does not know by its id.
const MODULES = ["accounts", "vault", "agent-home", "settings", "repos", "chats", "jobs", "connects"];

const arr = (v: unknown): J[] => (Array.isArray(v) ? v : []);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);
const str = (v: unknown): string => (typeof v === "string" ? v : "");

/// A module as people call it.
export function moduleName(id: string): string {
  return MODULES.includes(id) ? t(`core-views.move.module.${id}`) : id;
}

/// An item named as the station names it (`<module> <id>`, scheduler `named`; or `{module, id}`).
function nameOf(v: unknown): string {
  if (typeof v === "string") return v;
  if (isObject(v)) return `${str(v.module)} ${str(v.id)}`;
  return "";
}

const moduleOf = (named: string) => named.slice(0, Math.max(0, named.indexOf(" ")));

/// How far one item has gone inside it, in its unit: bytes as bytes, the rest counted.
function progressOf(p: unknown): J | null {
  if (!isObject(p)) return null;
  const done = num(p.done);
  const total = num(p.total);
  const text = p.unit === "bytes" ? `${format.bytes(done)} / ${format.bytes(total)}` : t("core-views.move.count", { done: String(done), total: String(total) });
  return { done, total, text };
}

/// The bound a page of items is asked with: a page at least, `MOVE_SHOWN_MOST` at most.
export function moveLimit(limit: unknown): number {
  return Math.min(Math.max(typeof limit === "number" && Number.isInteger(limit) ? limit : MOVE_PAGE, 1), MOVE_SHOWN_MOST);
}

/// A station the things may go to, as its row offers it.
export type MoveTarget = { station: string; name: string; free: string };

/// What GET /move said (`raw`, the asked module's items as many as were read, `more` whether its list goes on) as the
/// page draws it. `module`: the one whose items are open ("" none); `targets`: the workspace's other whole stations
/// online that offer moving (their overview's `move.offered`); `canMove`: the viewer may move (an owner or admin).
export function moveShown(raw: J, o: { to: string; toName: string; module: string; targets: MoveTarget[]; canMove: boolean }): J {
  const modules = arr(raw?.modules);
  const stopped = arr(raw?.stopped);
  const last = isObject(raw?.last) ? raw.last : null;
  // (each item's label by its name, of those the answer holds: what a stopped one waits for)
  const labels = new Map<string, string>();
  for (const m of modules) for (const x of arr(m?.items)) labels.set(`${str(m?.id)} ${str(x?.id)}`, str(x?.label));
  const refused = new Map<string, string>();
  for (const r of arr(last?.refused)) refused.set(nameOf(r?.item), str(r?.why));
  const failed = isObject(last?.failed) ? { item: nameOf(last.failed.item), error: str(last.failed.error) } : null;
  const moving = isObject(raw?.moving) ? raw.moving : null;
  const movingIn = moving === null ? "" : str(moving.module);
  const waitsFor = (named: string) => labels.get(named) || moduleName(moduleOf(named));
  const itemOf = (module: string, x: J): J => {
    const named = `${module} ${str(x?.id)}`;
    const state = str(x?.state) || "here";
    const cannot = typeof x?.cannot === "string" ? x.cannot : null;
    const stateText = state === "moving"
      ? t("core-views.move.state.moving")
      : state === "there"
        ? t("core-views.move.state.there")
        : state === "stopped"
          ? t("core-views.move.state.stopped", { what: waitsFor(nameOf(x?.waitsFor)) })
          : state === "failed"
            ? t("core-views.move.state.failed")
            : cannot !== null
              ? t("core-views.move.state.cannot")
              : "";
    // (why, under it: its failure, why it cannot move, else why the last move or move back left it out)
    const note = state === "failed"
      ? str(x?.error) || (failed?.item === named ? failed.error : "")
      : cannot !== null && state !== "there"
        ? cannot
        : failed?.item === named && state !== "there"
          ? failed.error
          : refused.get(named) ?? "";
    const action = !o.canMove || state === "moving" ? "" : state === "there" ? "back" : cannot !== null ? "" : "move";
    return {
      id: str(x?.id),
      label: str(x?.label) || str(x?.id),
      state: cannot !== null && state === "here" ? "cannot" : state,
      stateText,
      note,
      progress: state === "moving" ? progressOf(x?.progress) : null,
      action,
    };
  };
  const shown = modules.map((m) => {
    const id = str(m?.id);
    const done = num(m?.done);
    const total = num(m?.total);
    const page = arr(m?.items);
    const stoppedHere = stopped.some((s) => moduleOf(nameOf(s?.item)) === id) || page.some((x) => x?.state === "stopped");
    const failedHere = page.some((x) => x?.state === "failed") || (failed !== null && moduleOf(failed.item) === id);
    const mark = movingIn === id ? "moving" : failedHere ? "failed" : stoppedHere ? "stopped" : "";
    const open = o.module === id;
    const action = !o.canMove || total === 0 || movingIn === id ? "" : done >= total ? "back" : "move";
    return {
      id,
      // (what it needs, by the modules' ids: the page names them, as it names the module, in its own words)
      needs: arr(m?.needs).map(str).filter((n) => n !== ""),
      done,
      total,
      count: total === 0 ? t("core-views.move.empty") : t("core-views.move.count", { done: String(done), total: String(total) }),
      mark,
      markText: mark === "" ? "" : t(`core-views.move.mark.${mark}`),
      // (opens by itself: something of it moving, failed or stopped)
      opens: mark !== "",
      action,
      items: open ? page.map((x) => itemOf(id, x)) : [],
      more: open && typeof m?.more === "string" && m.more !== "",
    };
  });
  const toMove = shown.reduce((n, m) => n + Math.max(0, m.total - m.done), 0);
  const toBack = shown.reduce((n, m) => n + m.done, 0);
  const movingShown = moving === null
    ? null
    : (() => {
      const progress = progressOf(moving.progress);
      const parts = [moduleName(movingIn), str(moving.label) || str(moving.id)];
      if (progress !== null) parts.push(progress.text);
      return { module: movingIn, item: str(moving.id), line: parts.join(" · "), progress };
    })();
  return {
    to: o.to,
    toName: o.toName,
    targets: o.targets,
    canMove: o.canMove,
    moving: movingShown,
    // (its station's page shows 迁移: something of it moved, moving, stopped or failed)
    active: moving !== null || stopped.length > 0 || toBack > 0 || shown.some((m) => m.mark !== ""),
    allMove: !o.canMove || toMove === 0 || o.to === "" ? null : { n: toMove, title: t("core-views.move.all.title", { name: o.toName }), text: t("core-views.move.all.text", { n: String(toMove) }) },
    allBack: !o.canMove || toBack === 0 || o.to === "" ? null : { n: toBack, title: t("core-views.move.back.title", { name: o.toName }), text: t("core-views.move.back.text", { n: String(toBack) }) },
    modules: shown,
  };
}

/// A station's room as its target row says it.
export function freeText(overview: J): string {
  const free = overview?.disk?.freeBytes;
  return typeof free === "number" ? t("core-views.move.free", { size: format.bytes(free) }) : "";
}
