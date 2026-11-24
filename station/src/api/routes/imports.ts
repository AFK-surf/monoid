// Admin HTTP routes for Settings > Import: discovering external session sources, listing candidates, and running imports.
import { findImportSource, listImportCandidates, listImportSources, runImport } from "../../imports/service.ts";
import type { ImportOptions } from "../../imports/types.ts";
import { tr } from "../../ops/i18n.ts";
import type { Route, Tools } from "../admin.ts";
import { type Answer, error, input, ok, param, Refused, type Request, segment } from "../request.ts";

export function routes(tools: Tools, options?: ImportOptions): Route[] {
  const workspaceOf = (r: Request): string | null => (r.viewer.home === false ? r.viewer.workspace : null);

  const guarded = (fn: (r: Request, args: string[]) => Promise<Answer>) => async (r: Request, args: string[]): Promise<Answer> => {
    try {
      return await fn(r, args);
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      return error(500, (e as Error).message);
    }
  };

  const requireHub = () => {
    const hub = tools.agents?.hub;
    if (!hub) throw new Refused(503, "station starting");
    return hub;
  };

  return [
    // GET /imports: probe available external session sources on this station (e.g. T3 Code).
    {
      method: "GET",
      pattern: /^\/imports$/,
      handle: guarded(async (r: Request) => {
        const hub = requireHub();
        const sources = await listImportSources(hub, workspaceOf(r), options);
        return ok({ sources });
      }),
    },
    // GET /imports/:source/sessions: list importable conversations for a source.
    {
      method: "GET",
      pattern: /^\/imports\/([^/]+)\/sessions$/,
      handle: guarded(async (r: Request, [rawSource]: string[]) => {
        const hub = requireHub();
        const sourceId = segment(rawSource!);
        if (findImportSource(sourceId) === null) {
          return error(404, tr(r.lang, "station.import.unknownSource", { source: sourceId }));
        }
        const includeArchived = param(r, "includeArchived") === "1" || param(r, "includeArchived") === "true";
        const sessions = await listImportCandidates(hub, sourceId, workspaceOf(r), { includeArchived }, options);
        return ok({ source: sourceId, sessions });
      }),
    },
    // POST /imports/:source/run: import selected external conversations, or one-click import all unimported active ones.
    {
      method: "POST",
      pattern: /^\/imports\/([^/]+)\/run$/,
      handle: guarded(async (r: Request, [rawSource]: string[]) => {
        const hub = requireHub();
        const sourceId = segment(rawSource!);
        if (findImportSource(sourceId) === null) {
          return error(404, tr(r.lang, "station.import.unknownSource", { source: sourceId }));
        }
        const body = input(r);
        const ids = Array.isArray(body.ids) ? body.ids.filter((x): x is string => typeof x === "string") : undefined;
        const includeArchived = body.includeArchived === true;
        const result = await runImport(hub, sourceId, { ids, includeArchived }, r.viewer.email, r.lang, workspaceOf(r), options);
        return ok(result);
      }),
    },
  ];
}
