// The station's and its runtimes' versions read again, one of them updated, or a runtime removed: the station's own business, for a
// workspace's owner or admin (admin/mod.rs `updates_for`). Each answers the versions as they are after it (the
// overview's `updates` says them too). A station with nothing to update (tests, a part not made) answers 404.
import { type Request, type Answer, error, ok, Refused, input } from "../request.ts";
import type { Route } from "../admin.ts";
import { managesStation } from "../../mesh/credential.ts";
import { tr } from "../../ops/i18n.ts";
import type { Updates } from "../../updates/updates.ts";
import { parseWaitSpec, type WaitCondition } from "../../updates/override.ts";
import { channelOfId } from "../../updates/versions.ts";

export type UpdatesDeps = { updates?: Updates | null };



/// Whether they manage the workspace (its owner or an admin).
const manages = (r: Request) => managesStation(r.viewer);

export const routes = ({ updates }: UpdatesDeps): Route[] => {
  /// The updates, for someone who may update what runs on the machine; what `f` refuses is a 400 with its words.
  const answer = (f: (u: Updates, r: Request) => Promise<void>) => async (r: Request): Promise<Answer> => {
    try {
      if (!manages(r)) throw new Refused(403, tr(r.lang, "station.admin.updatesManagersOnly"));
      if (!updates) throw new Refused(404, tr(r.lang, "station.admin.updatesUnavailable"));
      try {
        await f(updates, r);
      } catch (e) {
        if (e instanceof Refused) throw e;
        throw new Refused(400, (e as Error).message);
      }
      return ok(updates.get(r.lang));
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      return error(500, (e as Error).message);
    }
  };

  return [
    { method: "POST", pattern: /^\/updates\/check$/, handle: answer((u) => u.check()) },
    // The station's update channel (stable or beta), set as someone asked.
    {
      method: "POST",
      pattern: /^\/updates\/channel$/,
      handle: answer(async (u, r) => {
        const asked = input(r).channel;
        const channel = channelOfId(typeof asked === "string" ? asked : "");
        if (channel === null) throw new Refused(400, tr(r.lang, "station.admin.badChannel"));
        await u.setChannel(channel, r.lang);
      }),
    },
    // The station updating itself or not, as someone asked: { on }.
    {
      method: "POST",
      pattern: /^\/updates\/auto$/,
      handle: answer(async (u, r) => {
        const on = input(r).on;
        if (typeof on !== "boolean") throw new Refused(400, tr(r.lang, "station.admin.badOn"));
        await u.setAuto(on, r.lang);
      }),
    },
    // Conditional auto-update wait rules: { wait: string[] | null }.
    {
      method: "POST",
      pattern: /^\/updates\/wait$/,
      handle: answer(async (u, r) => {
        const raw = input(r).wait;
        if (raw === null) {
          await u.setWait(null, r.lang);
          return;
        }
        if (!Array.isArray(raw) || !raw.every((x) => typeof x === "string")) {
          throw new Refused(400, "wait: string[] or null");
        }
        const parsed: WaitCondition[] = [];
        for (const s of raw) {
          try {
            parsed.push(parseWaitSpec(s));
          } catch (e) {
            throw new Refused(400, (e as Error).message);
          }
        }
        await u.setWait(parsed, r.lang);
      }),
    },
    // A runtime removed from the machine, the way it was installed: { id }. Its accounts and chats stay.
    {
      method: "POST",
      pattern: /^\/updates\/uninstall$/,
      handle: answer(async (u, r) => {
        const asked = input(r);
        await u.uninstall(typeof asked.id === "string" ? asked.id : "", r.lang);
      }),
    },
    // One of them updated (or a runtime installed): { id }; the station put back to a release before it: { id, to }.
    {
      method: "POST",
      pattern: /^\/updates$/,
      handle: answer(async (u, r) => {
        const asked = input(r);
        const id = typeof asked.id === "string" ? asked.id : "";
        if (asked.to !== undefined && typeof asked.to !== "string") throw new Refused(400, tr(r.lang, "station.updates.badVersion"));
        if (asked.repair === true && id === "codex") await u.repairCodex(r.lang);
        else if (asked.repair !== undefined && asked.repair !== false) throw new Refused(400, tr(r.lang, "station.updates.codexRepairUnavailable"));
        else if (asked.to === undefined) await u.update(id, r.lang);
        else await u.update(id, r.lang, asked.to);
      }),
    },
  ];
};
