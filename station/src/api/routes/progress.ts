// How a person's agents are asked for progress (进度汇报), carried by their own devices as their stars are (stars.ts).
// GET /progress gives the asker's own (`progress`, null before any); PUT /progress `{progress}` keeps the newer of what
// is kept and what their device brings (client/core-ts/src/progress-prefs.ts `newerProgress`) and answers it. A change is
// told to that person's devices alone (`progress`, `{workspace}`). The sessions they started read it as they are woken
// (store.ts `progressOf`). A station from before answers 404 `no route …`.
import { type Answer, type Request, error, json } from "../request.ts";
import type { Route } from "../admin.ts";
import { log } from "../../ops/log.ts";
import { RecordRefusal, canonical } from "../../../../client/core-ts/src/preset-records.ts";
import { type ProgressPrefs, newerProgress, progressOf } from "../../../../client/core-ts/src/progress-prefs.ts";

export type ProgressKept = { progressPrefs(ws: string, sub: string): string | null; putProgressPrefs(ws: string, sub: string, email: string, json: string): void };

const BODY_MOST = 4096;

export function routes({ kept, told }: { kept: ProgressKept; told?: (ws: string, sub: string) => void }): Route[] {
  const read = (ws: string, sub: string): ProgressPrefs | null => {
    const text = kept.progressPrefs(ws, sub);
    try {
      return text === null ? null : progressOf(JSON.parse(text));
    } catch (e) {
      log.warn("progress", "how a person's agents are asked for progress does not read; taken as not set", { error: (e as Error).message });
      return null;
    }
  };
  return [
    {
      method: "GET",
      pattern: /^\/progress$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, "progress settings are a person's own");
        return json(200, JSON.stringify({ progress: read(r.viewer.workspace, r.viewer.sub) }));
      },
    },
    {
      method: "PUT",
      pattern: /^\/progress$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, "progress settings are a person's own");
        if (r.body.length > BODY_MOST) return error(413, "request too large");
        let given: ProgressPrefs;
        try {
          given = progressOf((JSON.parse(r.body.toString("utf8") || "{}") as { progress?: unknown } | null)?.progress);
        } catch (e) {
          return error(400, e instanceof RecordRefusal ? e.message : "invalid JSON");
        }
        const { workspace: ws, sub, email } = r.viewer;
        const was = read(ws, sub);
        const now = was === null ? given : newerProgress(was, given);
        if (was === null || canonical(now) !== canonical(was)) {
          kept.putProgressPrefs(ws, sub, email, JSON.stringify(now));
          told?.(ws, sub);
        }
        return json(200, JSON.stringify({ progress: now }));
      },
    },
  ];
}
