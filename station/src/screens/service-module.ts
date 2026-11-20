// Optional Windows LocalSystem screen service (`stillfail-screen-svc.exe`) as a station part: exposes the overview's
// `screenService` to any member and `PUT /screen-service {on}` to workspace owners and admins. Windows only.
import { Effect, Layer } from "effect";
import type { Route } from "../api/admin.ts";
import { type Answer, type Request, error, json } from "../api/request.ts";
import { managesStation } from "../mesh/credential.ts";
import { wall } from "../ops/fibers.ts";
import { tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { platform } from "../platform/index.ts";
import { Events, Parts, Paths } from "../services.ts";
import { ChangeRefused, ScreenService } from "./service.ts";

export function screenServiceRoutes(service: ScreenService): Route[] {
  return [
    {
      method: "PUT",
      pattern: /^\/screen-service$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!managesStation(r.viewer)) return error(403, tr(r.lang, "station.screenService.managersOnly"));
        let on: unknown;
        try {
          on = JSON.parse(r.body.toString("utf8") || "{}")?.on;
        } catch {
          return error(400, "invalid JSON");
        }
        if (typeof on !== "boolean") return error(400, "on is true or false");
        try {
          await service.change(on);
        } catch (e) {
          if (e instanceof ChangeRefused) return error(409, tr(r.lang, `station.screenService.${e.key}`));
          throw e;
        }
        log.info("screen-service", "Windows screen service change asked", { on, by: r.viewer.email });
        return json(200, JSON.stringify(service.view(true)));
      },
    },
  ];
}

export const ScreenServiceLive = Layer.effectDiscard(
  Effect.gen(function* () {
    if (platform.os !== "windows") return;
    const { app } = yield* Paths;
    const events = yield* Events;
    const parts = yield* Parts;
    const service = new ScreenService({ app, now: wall.now, after: wall.after, changed: () => events.overviewChanged() });
    yield* Effect.acquireRelease(
      Effect.sync(() => void service.start().catch((e) => log.warn("screen-service", "status probe failed", { error: (e as Error).message }))),
      () => Effect.promise(() => service.stop()),
    );
    parts.routes(screenServiceRoutes(service));
    parts.overview("screenService", (viewer) => service.view(managesStation(viewer)));
  }),
);
