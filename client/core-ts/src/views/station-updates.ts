// The newer releases of a workspace's stations that wait for a person (the `stationUpdates` view; the user,
// 2026-11-14: 「用户有 station 要更新并且没有开自动更新的情况下，应该也像客户端更新一样提示，点击有弹窗列出需要更新的
// station，可以分别决定更新」): the app's sidebar and Home offer them as they offer its own newer build, and their dialog
// lists them, each updated on its own (`software.update` {station, id: "station"}). Only what this person can do
// something about: an owner's or an admin's, of a station that can be updated from here and does not update itself.
import { t } from "../i18n.ts";
import { isBuildStale } from "../station/oldest.ts";
import { get as getU, isObject } from "../util.ts";

// deno-lint-ignore no-explicit-any
type J = any;
const get = (v: unknown, k: string): J => getU(v, k);
const str = (v: unknown): string | null => (typeof v === "string" && v !== "" ? v : null);

/// A station of the workspace as this view reads it: its address and name, whether it is up (and reached), and its own
/// software as its overview lists it (db/schema.ts overviewSoftwareOf; undefined while none is read), and the version
/// of it let be on a chat's notice of it (looks.ts stationUpdate's `version`, `<channel>:<latest>`; null none).
export type StationSoftware = { station: string; name: string; online: boolean; software: unknown; dismissed: string | null };

/// Of each station `stations` (none where the viewer does not manage the workspace), the one waiting for a person to
/// update it: a newer release out (`offered`), a build older than 7 days (`stale: true`, surfaced even when auto-update
/// is on or a release was dismissed), its update under way (`updating`, how far where said) or one that failed
/// (`failed`, what it said), shown till it is done. One that updates itself (自动更新 on) is omitted unless stale, as
/// is one that cannot be updated from here (the desktop app's own station, a clone), or a non-stale version let be
/// (不再提醒此版本); one away is none while nothing goes on (it cannot be updated till it is back), one away as it
/// updates (its handover) kept. `offered` counts what waits for a press (those offered or failed): the app's key shows
/// while any is listed, its words say these.
export function stationUpdates(stations: StationSoftware[], nowMs = 0): J {
  const items: J[] = [];
  for (const s of stations) {
    const u = s.software;
    if (!isObject(u) || get(u, "updatable") !== true) continue;
    const builtAt = get(u, "builtAt");
    const stale = typeof builtAt === "number" && isBuildStale(builtAt, nowMs);
    if (get(u, "auto") === true && !stale) continue;
    const state = get(u, "state") === "updating" ? "updating" : get(u, "state") === "failed" ? "failed" : get(u, "newer") === true || stale ? "offered" : null;
    if (state === null || (!s.online && state !== "updating")) continue;
    if (state === "offered" && !stale && s.dismissed !== null && s.dismissed === `${str(get(u, "channel")) ?? ""}:${str(get(u, "latest")) ?? ""}`) continue;
    const from = str(get(u, "version"));
    const to = str(get(u, "latest"));
    const versionText = from !== null && to !== null && to !== from ? t("core-views.stationUpdates.version", { from, to }) : (to ?? from ?? "");
    const percent = get(u, "percent");
    const detail = state === "failed"
      ? (str(get(u, "message")) ?? t("core-views.software.update_failed"))
      : state === "updating"
        ? (str(get(u, "progress")) ?? t("core-views.software.updating"))
        : stale
          ? t("core-views.stationUpdates.stale")
          : null;
    items.push({
      station: s.station,
      name: s.name,
      state,
      versionText,
      ...(detail !== null ? { detail } : {}),
      ...(stale ? { stale: true } : {}),
      ...(state === "updating" && typeof percent === "number" ? { percent: Math.max(0, Math.min(100, Math.round(percent))) } : {}),
      canUpdate: s.online && state !== "updating",
    });
  }
  const offered = items.filter((i) => i.state !== "updating").length;
  const going = items.length - offered;
  const anyStale = items.some((i) => i.state !== "updating" && i.stale === true);
  return {
    items,
    offered,
    labelText: offered > 0
      ? t(anyStale ? "core-views.stationUpdates.staleOffered" : "core-views.stationUpdates.offered", { n: offered })
      : going > 0
        ? t("core-views.stationUpdates.going", { n: going })
        : "",
    titleText: t("core-views.stationUpdates.title"),
  };
}
