// A station's apps as an open widget follows them (station/src/apps/registry.ts): `app.watch {station, id}` stays open
// while the widget is shown and gives as its progress each change the station tells of that app on its event stream
// (`app`: a new version or another made current; `app-doc`: one of its documents written or deleted), and `opened`
// as it starts and as the link to the station opens again after an absence (what was missed is read again by the
// widget). Nothing is read on a timer; cancelling the call lets it go.
import { Effect } from "effect";
import type { Inner } from "../core.ts";
import type { Call } from "../core/calls.ts";
import { handlers } from "../core/execute.ts";
import type { Progress } from "../core.ts";
import { StationAddr } from "../station/addr.ts";
import { CoreError, asCoreError } from "../error.ts";
import { t } from "../i18n.ts";
import { featureOn } from "../prefs.ts";
import { get } from "../util.ts";

type Of = Extract<Call, { kind: "appWatch" }>;
type Watch = { id: string; progress: Progress };

/// A station's apps' calls (ops.ts `app.*` and `app.watch`; not the app's own, `app.update` and the like).
export const APP_CALLS: ReadonlySet<string> = new Set(["app.list", "app.get", "app.versions", "app.publish", "app.docs", "app.putDoc", "app.deleteDoc", "app.llm", "app.watch"]);

/// Why call `name` is refused here: a station app's call while 实验性功能's 站点应用 (features.ts `apps`) is off on
/// this device, saying where to turn it on; null for any other call, or with it on.
export function appsRefusal(inner: Inner, name: string): CoreError | null {
  if (!APP_CALLS.has(name) || featureOn(inner.data, "apps")) return null;
  return new CoreError("feature_off", t("core-misc.apps.off"));
}

/// A station's address as one key, however it was written.
const keyOf = (address: string): string => {
  try {
    return StationAddr.parse(address).toString();
  } catch {
    return address;
  }
};

/// What an `app` or `app-doc` event of the station says for watchers of app `id`, or null where it is not of it.
export function told(name: string, data: unknown, id: string): Record<string, unknown> | null {
  if (name === "app" && get(data, "id") === id) {
    return { type: "app", id, rev: get(data, "rev") ?? null, current: get(data, "current") ?? null };
  }
  if (name === "app-doc" && get(data, "app") === id) {
    return { type: "app-doc", app: id, collection: get(data, "collection") ?? "", id: get(data, "id") ?? "", rev: get(data, "rev") ?? null, deleted: get(data, "deleted") === true };
  }
  return null;
}

export function install(inner: Inner): void {
  // Each station's watchers, by its address.
  const watching = new Map<string, Set<Watch>>();
  handlers.appWatch = (_inner, call, progress) => {
    const c = call as Of;
    return Effect.flatMap(
      Effect.try({ try: () => StationAddr.parse(c.station), catch: asCoreError }),
      (addr) =>
        Effect.callback<never>(() => {
          const at = addr.toString();
          const w: Watch = { id: c.id, progress };
          let set = watching.get(at);
          if (set === undefined) watching.set(at, (set = new Set()));
          set.add(w);
          progress({ type: "opened" });
          return Effect.sync(() => {
            set!.delete(w);
            if (set!.size === 0) watching.delete(at);
          });
        }),
    );
  };
  inner.stations.also.push({
    // The link opened (again): changes may have gone by unheard.
    read: (address) =>
      Effect.sync(() => {
        for (const w of watching.get(keyOf(address)) ?? []) w.progress({ type: "opened" });
      }),
    event: (address, name, data) => {
      if (name !== "app" && name !== "app-doc") return;
      for (const w of watching.get(keyOf(address)) ?? []) {
        const said = told(name, data, w.id);
        if (said !== null) w.progress(said);
      }
    },
    // (a stream that came back resumed says each change it missed)
  });
}
