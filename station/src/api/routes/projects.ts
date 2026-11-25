// Member HTTP routes for chat classification (project & tags), inline project-creation proposal resolution,
// and workspace-shared project metadata (`PROJECTS.jsonl`).
// None of these write routes are in `OWN_MARKS`, so `admin.ts` automatically rejects read-only members (403).
import { join } from "node:path";
import type { Route, Tools } from "../admin.ts";
import { type Answer, type Request, Refused, error, json } from "../request.ts";
import {
  applyProposalInfoSync,
  checkProposalInfoApplied,
  ensureProjectRegistered,
  normalizeNote,
  normalizeRefs,
  pruneAppliedOpIds,
  readProjectsInfoLenient,
  stripInternalProjectInfo,
  updateProjectInfo,
} from "../../projects/info.ts";
import { normalizeProject, normalizeTags } from "../../store/rows.ts";
import { renameOrMergeProject } from "../../sessions/projects.ts";
import type { Cloud } from "../../cloud/state.ts";

const BODY_MOST = 256 * 1024;

function parseBody(r: Request): Record<string, unknown> | null {
  if (r.body.length > BODY_MOST) return null;
  try {
    const parsed = JSON.parse(r.body.toString("utf8") || "{}");
    return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

function agentHomeOf(tools: Tools): string | null {
  const fromHub = tools.agents?.hub.config().agentHome;
  if (typeof fromHub === "string" && fromHub !== "") return fromHub;
  if (typeof tools.data === "string" && tools.data !== "") return join(tools.data, "agent");
  return null;
}

function validateNoteArg(raw: unknown): { ok: true; value: string | null | undefined } | { ok: false; error: string } {
  if (raw === undefined || raw === null) return { ok: true, value: raw };
  if (typeof raw !== "string") return { ok: false, error: "note must be a string or null" };
  return { ok: true, value: raw };
}

function validateRefsArg(raw: unknown): { ok: true; value: string[] | null | undefined } | { ok: false; error: string } {
  if (raw === undefined || raw === null) return { ok: true, value: raw };
  if (!Array.isArray(raw) || raw.some((x) => typeof x !== "string")) {
    return { ok: false, error: "refs must be an array of strings or null" };
  }
  return { ok: true, value: raw as string[] };
}

export function routes(tools: Tools, cloud?: Cloud, syncProposalInfo = applyProposalInfoSync): Route[] {
  const homeWs = () => cloud?.home() ?? tools.agents?.cloud?.home() ?? null;
  const viewerWs = (r: Request): string | null => r.viewer.workspace || homeWs();
  const notifyProjectsChanged = (ws: string | null) => {
    tools.events?.projectsChanged(ws);
    tools.agents?.hub.invalidateProjectsCache(ws);
  };
  // Serialize resolve -> PROJECTS.jsonl sync -> markProposalInfoSynced per `(thread, entry)` so concurrent
  // resolve requests on the same proposal can never interleave DB replacement with stale sync completion.
  const proposalLocks = new Map<string, Promise<void>>();
  const withProposalLock = async <T>(lockKey: string, fn: () => Promise<T>): Promise<T> => {
    const prev = proposalLocks.get(lockKey) ?? Promise.resolve();
    let release!: () => void;
    const next = new Promise<void>((resolve) => { release = resolve; });
    const tail = prev.then(() => next);
    proposalLocks.set(lockKey, tail);
    await prev;
    try {
      return await fn();
    } finally {
      release();
      if (proposalLocks.get(lockKey) === tail) proposalLocks.delete(lockKey);
    }
  };

  return [
    {
      method: "POST",
      pattern: /^\/threads\/([^/]+)\/proposals\/([^/]+)\/resolve$/,
      handle: async (r: Request, [rawThread, rawEntry]: string[]): Promise<Answer> => {
        if (!tools.store) return error(503, "station store is not ready");
        if (!/^\d+$/.test(rawThread!) || !/^\d+$/.test(rawEntry!)) return error(400, "thread and entry must be positive integers");
        const threadId = Number(rawThread);
        const entryN = Number(rawEntry);
        if (!Number.isSafeInteger(threadId) || threadId <= 0 || !Number.isSafeInteger(entryN) || entryN <= 0) {
          return error(400, "thread and entry must be positive integers");
        }
        const body = parseBody(r);
        if (body === null) return error(r.body.length > BODY_MOST ? 413 : 400, r.body.length > BODY_MOST ? "request too large" : "invalid JSON body");
        const action = body.action;
        if (action !== "accept" && action !== "reassign" && action !== "dismiss") {
          return error(400, 'action must be "accept", "reassign" or "dismiss"');
        }
        if (body.name !== undefined && typeof body.name !== "string") return error(400, "name must be a string");
        if (body.target !== undefined && typeof body.target !== "string") return error(400, "target must be a string");
        const noteCheck = validateNoteArg(body.note);
        if (!noteCheck.ok) return error(400, noteCheck.error);
        const refsCheck = validateRefsArg(body.refs);
        if (!refsCheck.ok) return error(400, refsCheck.error);
        const name = body.name as string | undefined;
        const target = body.target as string | undefined;
        // Distinguish omitted (`undefined` -> inherit proposal's value) from explicit clear (`null` / "" / []).
        let normalizedNote: string | null | undefined;
        let normalizedRefs: string[] | null | undefined;
        try {
          if ("note" in body && body.note !== undefined) {
            if (body.note === null) {
              normalizedNote = null;
            } else {
              normalizedNote = normalizeNote(body.note, true) ?? null;
            }
          }
          if ("refs" in body && body.refs !== undefined) {
            if (body.refs === null) {
              normalizedRefs = null;
            } else {
              normalizedRefs = normalizeRefs(body.refs, true) ?? null;
            }
          }
        } catch (e) {
          return error(400, (e as Error).message);
        }
        const markCross = body.markCross === true;
        const resolvedBy = r.viewer.email || r.viewer.sub || "member";

        const agentHome = agentHomeOf(tools);
        if (action === "accept" && agentHome === null) {
          return error(503, "agent home is not configured");
        }

        return withProposalLock(`${threadId}:${entryN}`, async () => {
          const ws = viewerWs(r);
          // Crash-recovery reconciliation: if a previous `accept` persisted its receipt `opId` in `PROJECTS.jsonl`
          // before a crash/restart left `info_synced = 0` in SQLite, verify against `PROJECTS.jsonl` BEFORE allowing
          // any follow-up decision to replace or dismiss it. If `agentHome` is missing or `PROJECTS.jsonl` cannot be
          // read right now, return a retryable 503 instead of guessing `false` and overwriting an on-disk registration.
          const unsynced = tools.store!.getUnsyncedAcceptOutcome(threadId, entryN);
          if (unsynced !== null) {
            if (agentHome === null) {
              const ans = error(503, "agent home is not configured; cannot verify pending project registration");
              ans.noCache = true;
              return ans;
            }
            let receiptState: "applied" | "absent" | "uncertain";
            try {
              receiptState = await checkProposalInfoApplied(agentHome, ws, homeWs(), unsynced.opId);
            } catch (e) {
              const ans = error(503, `cannot verify pending project registration: ${(e as Error).message}`);
              ans.noCache = true;
              return ans;
            }
            if (receiptState === "applied") {
              const marked = tools.store!.markProposalInfoSynced(threadId, entryN, {
                status: "accepted",
                project: unsynced.project,
                resolvedAt: unsynced.resolvedAt,
                opId: unsynced.opId,
              });
              if (marked) {
                const keepOpIds = tools.store!.listPendingRenameInfoOpIds(ws ?? homeWs() ?? "");
                await pruneAppliedOpIds(agentHome, ws, homeWs(), [unsynced.opId], keepOpIds).catch(() => {});
              }
            } else if (receiptState === "uncertain") {
              const sameIntent = tools.store!.isSameUnsyncedAcceptIntent(threadId, entryN, {
                action,
                ...(name !== undefined ? { name } : {}),
                ...(normalizedNote !== undefined ? { note: normalizedNote } : {}),
                ...(normalizedRefs !== undefined ? { refs: normalizedRefs } : {}),
              });
              if (!sameIntent) {
                const ans = error(503, "PROJECTS.jsonl contains unparseable lines; cannot verify pending project registration before replacing it");
                ans.noCache = true;
                return ans;
              }
            }
          }

          let res;
          try {
            res = tools.store!.resolveProposal(threadId, entryN, {
              action,
              ...(name !== undefined ? { name } : {}),
              ...(target !== undefined ? { target } : {}),
              ...(normalizedNote !== undefined ? { note: normalizedNote } : {}),
              ...(normalizedRefs !== undefined ? { refs: normalizedRefs } : {}),
              markCross,
              resolvedBy,
            });
          } catch (e) {
            const msg = (e as Error).message;
            const status = /^unknown (thread|entry)|has no project proposal/.test(msg) ? 404 : 400;
            return error(status, msg);
          }

          // Persist project registration/metadata into shared PROJECTS.jsonl atomically inside file lock
          // using DB-recorded intent (`proposal_outcomes.info_note`, `info_refs`, `info_synced`, `info_op_id`).
          // On file write failure after DB commit, keep `info_synced = 0` and return 200 with `infoError`
          // (matching PUT /classification) so retries can reconcile without losing the DB decision.
          let infoError: string | undefined;
          if (res.infoSync.needed) {
            const targetProject = res.proposal.resolvedProject;
            if (targetProject !== undefined && targetProject !== "") {
              if (agentHome === null) {
                infoError = "agent home is not configured";
              } else {
                try {
                  const resolvedAt = typeof res.proposal.resolvedAt === "number" ? res.proposal.resolvedAt : tools.store!.now();
                  const synced = await syncProposalInfo(agentHome, ws, homeWs(), {
                    name: targetProject,
                    ...(res.infoSync.note !== undefined ? { note: res.infoSync.note } : {}),
                    ...(res.infoSync.refs !== undefined ? { refs: res.infoSync.refs } : {}),
                    resolvedAt,
                    isReplay: res.alreadyResolved,
                    ...(res.infoSync.opId !== undefined ? { opId: res.infoSync.opId } : {}),
                  });
                  if (synced.changed) notifyProjectsChanged(ws);
                  const marked = tools.store!.markProposalInfoSynced(threadId, entryN, {
                    status: res.proposal.status,
                    project: targetProject,
                    ...(typeof res.proposal.resolvedAt === "number" ? { resolvedAt: res.proposal.resolvedAt } : {}),
                    ...(res.infoSync.opId !== undefined ? { opId: res.infoSync.opId } : {}),
                  });
                  if (!marked) {
                    const curEntry = tools.store!.getEntry(threadId, entryN);
                    const curThread = tools.store!.getThread(threadId);
                    if (curEntry?.proposal !== undefined && curThread !== null) {
                      res = { ...res, proposal: curEntry.proposal, thread: curThread, alreadyResolved: true };
                    }
                  } else if (res.infoSync.opId !== undefined) {
                    const keepOpIds = tools.store!.listPendingRenameInfoOpIds(ws ?? homeWs() ?? "");
                    await pruneAppliedOpIds(agentHome, ws, homeWs(), [res.infoSync.opId], keepOpIds).catch(() => {});
                  }
                } catch (e) {
                  infoError = (e as Error).message;
                }
              }
            }
          }

          const clientProposal =
            infoError !== undefined && res.proposal.status === "accepted"
              ? { ...res.proposal, status: "pending" as const }
              : res.proposal;
          const answer = json(200, JSON.stringify({
            proposal: clientProposal,
            thread: res.thread,
            alreadyResolved: res.alreadyResolved,
            ...(infoError !== undefined ? { infoError } : {}),
          }));
          if (infoError !== undefined) answer.noCache = true;
          return answer;
        });
      },
    },
    {
      method: "PUT",
      pattern: /^\/threads\/([^/]+)\/classification$/,
      handle: async (r: Request, [rawThread]: string[]): Promise<Answer> => {
        if (!tools.store) return error(503, "station store is not ready");
        if (!/^\d+$/.test(rawThread!)) return error(400, "thread must be a positive integer");
        const body = parseBody(r);
        if (body === null) return error(r.body.length > BODY_MOST ? 413 : 400, r.body.length > BODY_MOST ? "request too large" : "invalid JSON body");

        const change: { project?: string | null; tags?: string[] | null; lock: boolean; force: boolean } = { lock: true, force: true };
        try {
          if ("project" in body) {
            if (body.project !== null && typeof body.project !== "string") return error(400, "project must be a string or null");
            change.project = body.project === null ? null : normalizeProject(body.project);
          }
          if ("tags" in body) {
            if (body.tags !== null && !Array.isArray(body.tags)) return error(400, "tags must be an array of strings or null");
            change.tags = body.tags === null ? null : normalizeTags(body.tags, true);
          }
        } catch (e) {
          return error(400, (e as Error).message);
        }

        let res;
        try {
          res = tools.store.setThreadClassification(Number(rawThread), change);
        } catch (e) {
          const msg = (e as Error).message;
          return error(msg.startsWith("unknown thread") ? 404 : 400, msg);
        }

        let infoError: string | undefined;
        if (typeof change.project === "string" && change.project !== "") {
          const agentHome = agentHomeOf(tools);
          if (agentHome !== null) {
            const ws = viewerWs(r);
            try {
              const reg = await ensureProjectRegistered(agentHome, ws, homeWs(), {
                name: change.project,
                now: tools.store.now(),
                keepOpIds: tools.store.listPendingRenameInfoOpIds(ws ?? homeWs() ?? ""),
              });
              if (reg.changed) notifyProjectsChanged(ws);
            } catch (e) {
              infoError = (e as Error).message;
            }
          }
        }

        const answer = json(200, JSON.stringify({ thread: res.thread, changed: res.changed, ...(infoError !== undefined ? { infoError } : {}) }));
        if (infoError !== undefined) answer.noCache = true;
        return answer;
      },
    },
    {
      method: "GET",
      pattern: /^\/projects\/info$/,
      handle: async (r: Request): Promise<Answer> => {
        const agentHome = agentHomeOf(tools);
        if (agentHome === null) return json(200, JSON.stringify({ projects: {} }));
        try {
          const { projects, corruptLines } = await readProjectsInfoLenient(agentHome, viewerWs(r), homeWs());
          return json(200, JSON.stringify({ projects, ...(corruptLines > 0 ? { corruptLines } : {}) }));
        } catch (e) {
          return error(500, (e as Error).message);
        }
      },
    },
    {
      method: "PUT",
      pattern: /^\/projects\/info$/,
      handle: async (r: Request): Promise<Answer> => {
        const agentHome = agentHomeOf(tools);
        if (agentHome === null) return error(503, "station agent home is not configured");
        const body = parseBody(r);
        if (body === null) return error(r.body.length > BODY_MOST ? 413 : 400, r.body.length > BODY_MOST ? "request too large" : "invalid JSON body");
        if (typeof body.name !== "string") return error(400, "provide name (single project update)");
        const noteCheck = validateNoteArg(body.note);
        if (!noteCheck.ok) return error(400, noteCheck.error);
        const refsCheck = validateRefsArg(body.refs);
        if (!refsCheck.ok) return error(400, refsCheck.error);
        const ws = viewerWs(r);
        const now = tools.store?.now() ?? 0;
        const keepOpIds = tools.store?.listPendingRenameInfoOpIds(ws ?? homeWs() ?? "");
        try {
          const { doc } = await updateProjectInfo(agentHome, ws, homeWs(), {
            name: body.name,
            ...(noteCheck.value !== undefined ? { note: noteCheck.value } : {}),
            ...(refsCheck.value !== undefined ? { refs: refsCheck.value } : {}),
            ...(body.delete === true ? { delete: true } : {}),
            now,
            ...(keepOpIds !== undefined ? { keepOpIds } : {}),
          });
          notifyProjectsChanged(ws);
          return json(200, JSON.stringify(stripInternalProjectInfo(doc)));
        } catch (e) {
          const msg = (e as Error).message;
          const status = /corrupt|invalid PROJECTS\.jsonl|exceeds/i.test(msg) ? 500 : 400;
          return error(status, msg);
        }
      },
    },
    {
      method: "POST",
      pattern: /^\/projects\/(rename|merge)$/,
      handle: async (r: Request, [action]: string[]): Promise<Answer> => {
        const hub = tools.agents?.hub;
        if (!hub) return error(503, "station hub is not ready");
        const ws = viewerWs(r);
        if (ws === null || ws === "") return error(400, "workspace is required");
        if (hub.isRigIn(ws)) return error(403, "a rig does not manage workspace projects");
        if (hub.quietIn(ws)) return error(409, "this station is retiring from this workspace");
        const body = parseBody(r);
        if (body === null) return error(r.body.length > BODY_MOST ? 413 : 400, r.body.length > BODY_MOST ? "request too large" : "invalid JSON body");
        if (typeof body.from !== "string" || typeof body.to !== "string") {
          return error(400, "from and to must be strings");
        }
        const rawKey = Object.entries(r.headers ?? {}).find(([k]) => k.toLowerCase() === "idempotency-key")?.[1]?.trim() || "";
        const opKey = rawKey !== "" ? `${r.viewer.sub || r.viewer.email || ""}\0${action}\0${rawKey}` : undefined;
        try {
          const res = await renameOrMergeProject(hub, ws, action as "rename" | "merge", body.from, body.to, { checkKnown: true, skipPrivate: false, ...(opKey ? { opKey } : {}) });
          const answer = json(200, JSON.stringify(res));
          if (
            res.infoError !== undefined ||
            res.rosterError !== undefined ||
            res.peers.some((p) => p.status !== "ok" && p.status !== "rig")
          ) {
            answer.noCache = true;
          }
          return answer;
        } catch (e) {
          if (e instanceof Refused) {
            const ans = error(e.status, e.message);
            if (e.noCache === true) ans.noCache = true;
            return ans;
          }
          return error(500, (e as Error).message);
        }
      },
    },
  ];
}
