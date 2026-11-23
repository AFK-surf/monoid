// What of the station's chats a viewer sees: those of their own workspace. A request that names
// a session, a chat or a job of another workspace is answered as one naming what is not there.
import { percentDecode } from "./request.ts";
import { type InWorkspace, handedWs, sees, seesMissing } from "../store/rows.ts";
import type { Store } from "../store/store.ts";

/// Whether `viewer` sees a session (one not there: the home workspace's, but another station's task its workspace's:
/// rows.ts `seesMissing`).
export const sessionSeen = (store: Store, viewer: InWorkspace, key: string) => {
  const ws = store.sessionWs(key);
  return ws === undefined ? seesMissing(viewer, key) : sees(viewer, ws);
};

/// Whether `viewer` sees a thread: one of its sessions is in their workspace (a thread with none: the home one's).
export function threadSeen(store: Store, viewer: InWorkspace, id: number): boolean {
  const members = store.threadSessions(id);
  return members.length === 0 ? sees(viewer, null) : members.some((m) => sessionSeen(store, viewer, m.session));
}

/// Whether `viewer` sees a job: its session is theirs.
export const jobSeen = (store: Store, viewer: InWorkspace, id: string) => {
  const job = store.getJob(id);
  return job === null || sessionSeen(store, viewer, job.sessionKey);
};

/// Whether each viewer sees a session, a thread or a job (as `sessionSeen`, `threadSeen`, `jobSeen`), its workspaces
/// looked up once: an event is asked of every stream (events.ts `seer`), one lookup each held a busy station's thread.
export function seerOf(store: Store, of: { session: string } | { thread: number } | { job: string }): (viewer: InWorkspace) => boolean {
  if ("session" in of) {
    const ws = store.sessionWs(of.session);
    return ws === undefined ? (viewer) => seesMissing(viewer, of.session) : (viewer) => sees(viewer, ws);
  }
  if ("thread" in of) {
    const members = store.threadSessions(of.thread);
    if (members.length === 0) return (viewer) => sees(viewer, null);
    const each = members.map((m) => seerOf(store, { session: m.session }));
    return (viewer) => each.some((seen) => seen(viewer));
  }
  const job = store.getJob(of.job);
  return job === null ? () => true : seerOf(store, { session: job.sessionKey });
}

/// What names one of them: `/sessions/:key…`, `/threads/:id…`, `/jobs/:id…`.
const NAMED = /^\/*(sessions|threads|jobs)\/+([^/]+)/;
/// admin/mod.rs `segment_decode`, as the routes read a key.
const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));

/// The 404 a request is answered with when what its path names is there but of another workspace than the viewer's;
/// null otherwise (what is not there at all is the route's to say).
export function elsewhere(store: Store, path: string, viewer: InWorkspace): string | null {
  const named = NAMED.exec(path);
  if (named === null) return null;
  const [, kind, raw] = named;
  const id = segment(raw!);
  switch (kind) {
    case "sessions":
      return store.getSession(id) !== null && !sessionSeen(store, viewer, id) ? `unknown session ${id}` : null;
    case "threads": {
      const n = /^[+-]?\d+$/.test(id) ? Number(id) : NaN;
      return Number.isSafeInteger(n) && store.getThread(n) !== null && !threadSeen(store, viewer, n) ? `unknown thread ${id}` : null;
    }
    default:
      return jobSeen(store, viewer, id) ? null : `no job ${id}`;
  }
}

/// Where a chat a write's path names went (replica/handover.ts), for a viewer it is not seen by here: one of its sessions
/// handed to another station of the viewer's workspace and shown there (its `ws` here `handed:`), so that the write is
/// answered as a message to it is (409, `moved`: routes/hub.ts `movedAnswer`) and a device aims it there; null for
/// anything else (a chat of another workspace, one still coming here, one not there), which stays not there. Only for
/// what `elsewhere` said not seen: a thread with a session still here is written here.
export function went(store: Store, path: string, viewer: InWorkspace): { session: string; station: string; thread: number | null; there: number | null } | null {
  const named = NAMED.exec(path);
  if (named === null) return null;
  const [, kind, raw] = named;
  const id = segment(raw!);
  const keys = kind === "sessions" ? [id]
    : kind === "threads" && /^[+-]?\d+$/.test(id) && Number.isSafeInteger(Number(id)) ? store.threadSessions(Number(id)).map((m) => m.session)
    : [];
  for (const key of keys) {
    const h = store.handedTo(key);
    if (h === null || store.sessionWs(key)?.startsWith(handedWs("")) !== true || !sees(viewer, h.ws)) continue;
    return { session: key, station: h.station, thread: h.thread, there: h.there };
  }
  return null;
}
