// A person's drafts of 待派发 as their devices carry them (sessions/board-drafts.ts): GET /board/drafts gives the
// asker's own, deleted ones too, and the ids of the files of theirs this station keeps; PUT /board/drafts `{drafts}`
// merges what their device brings, the newer of each kept, and answers what is kept now, told to that person's devices
// alone as it changed (`boardDrafts`, `{workspace}`). POST /board/files `{draft, file, path}` keeps an upload (POST
// /uploads) as a file of one of their drafts here; GET /board/files?draft=&file= gives its bytes; POST /board/stage
// `{draft, file, name}` copies it among the uploads for a message to take, answered as POST /uploads answers. A station
// from before answers 404 `no route …`. What is brought that does not check is answered 400 (a DraftRefusal); what
// fails here (the disk) 500, with its words.
import { type Answer, type Request, error, json, param } from "../request.ts";
import type { Route } from "../admin.ts";
import { DraftRefusal } from "../../../../client/core-ts/src/board-drafts.ts";
import type { BoardDrafts } from "../../sessions/board-drafts.ts";

export type BoardDeps = { drafts: BoardDrafts; told?: (ws: string, sub: string) => void };

/// A PUT /board/drafts body is so large at most (DRAFTS_MOST drafts of TITLE_MOST characters, and their deletions).
const BODY_MOST = 4 * 1024 * 1024;

const own = "drafts are a person's own";

function body(r: Request): Record<string, unknown> | null {
  try {
    const v = JSON.parse(r.body.toString("utf8") || "{}") as unknown;
    return v !== null && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

const text = (v: unknown) => (typeof v === "string" ? v : "");

export function routes({ drafts, told }: BoardDeps): Route[] {
  return [
    {
      method: "GET",
      pattern: /^\/board\/drafts$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, own);
        return json(200, JSON.stringify(await drafts.said(r.viewer.workspace, r.viewer.sub)));
      },
    },
    {
      method: "PUT",
      pattern: /^\/board\/drafts$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, own);
        if (r.body.length > BODY_MOST) return error(413, "request too large");
        const b = body(r);
        if (b === null) return error(400, "invalid JSON");
        try {
          const { changed, ...said } = await drafts.carry(r.viewer.workspace, r.viewer.sub, b.drafts);
          if (changed) told?.(r.viewer.workspace, r.viewer.sub);
          return json(200, JSON.stringify(said));
        } catch (e) {
          if (e instanceof DraftRefusal) return error(400, e.message);
          return error(500, (e as Error)?.message ?? String(e));
        }
      },
    },
    {
      method: "POST",
      pattern: /^\/board\/files$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, own);
        const b = body(r);
        if (b === null) return error(400, "invalid JSON");
        try {
          return json(200, JSON.stringify(await drafts.keep(r.viewer.workspace, r.viewer.sub, text(b.draft), text(b.file), text(b.path))));
        } catch (e) {
          if (e instanceof DraftRefusal) return error(400, e.message);
          return error(500, (e as Error)?.message ?? String(e));
        }
      },
    },
    {
      method: "GET",
      pattern: /^\/board\/files$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, own);
        const got = await drafts.bytes(r.viewer.workspace, r.viewer.sub, param(r, "draft") ?? "", param(r, "file") ?? "");
        if (got === null) return error(404, "no such file");
        return { status: 200, headers: { "content-type": got.type, "cache-control": "no-store" }, body: got.bytes };
      },
    },
    {
      method: "POST",
      pattern: /^\/board\/stage$/,
      handle: async (r: Request): Promise<Answer> => {
        if (!r.viewer.sub) return error(403, own);
        const b = body(r);
        if (b === null) return error(400, "invalid JSON");
        const staged = await drafts.stage(r.viewer.workspace, r.viewer.sub, text(b.draft), text(b.file), text(b.name));
        if (staged === null) return error(404, "no such file");
        return json(200, JSON.stringify(staged));
      },
    },
  ];
}
