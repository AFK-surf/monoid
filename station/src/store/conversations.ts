// Conversations: grouping multi-session platform threads (e.g. multiple bots mentioned in the same Slack thread)
// into a single conversation identified by an anchor session key (`sessions.conv`).
// Design spec: slack-thread-merge-design-v3.md §3.1, §3.2.
import type { DatabaseSync } from "node:sqlite";
import { AUTO, MANUAL, STILLFAIL_CONNECT, comingWs, handedWs } from "./rows.ts";

export const OWNED_WS_SQL = "(ws IS NULL OR (ws NOT LIKE 'handed:%' AND ws NOT LIKE 'coming:%'))";

export function isOwnedWs(ws: string | null | undefined): boolean {
  if (ws === null || ws === undefined) return true;
  return !ws.startsWith(handedWs("")) && !ws.startsWith(comingWs(""));
}

/// The anchor session key for `key`'s conversation (`conv ?? key`).
export function conversationOf(db: DatabaseSync, key: string): string {
  const row = db.prepare("SELECT conv FROM sessions WHERE key = ?").get(key) as { conv: string | null } | undefined;
  return typeof row?.conv === "string" && row.conv !== "" ? row.conv : key;
}

/// All owned sessions belonging to conversation `anchor` (`conv = anchor OR key = anchor`).
/// Read paths may pass `limit`; write paths (archive, handover, delete) omit it.
export function membersOf(db: DatabaseSync, anchor: string, limit?: number): string[] {
  const sql = `SELECT key FROM sessions WHERE conv = ?1 AND ${OWNED_WS_SQL}
    UNION
    SELECT key FROM sessions WHERE key = ?1 AND ${OWNED_WS_SQL}${limit !== undefined ? " LIMIT ?2" : ""}`;
  const rows = (limit !== undefined ? db.prepare(sql).all(anchor, limit) : db.prepare(sql).all(anchor)) as { key: string }[];
  return rows.map((r) => r.key);
}

type SessionMeta = {
  key: string;
  conv: string | null;
  created_at: number;
  archived_at: number | null;
  archived_by: string | null;
  ws: string | null;
};

type HomeRow = { id: number; hidden_at: number | null; hidden_by: string | null };

type Group = {
  anchor: string;
  members: SessionMeta[];
  home: HomeRow | null;
  hasShare: boolean;
  isBorn: boolean;
  isManual: boolean;
  earliestAt: number;
  earliestKey: string;
};

function compareEarliest(aAt: number, aKey: string, bAt: number, bKey: string): number {
  if (aAt !== bAt) return aAt < bAt ? -1 : 1;
  return aKey < bKey ? -1 : aKey > bKey ? 1 : 0;
}

function loadGroupMembers(db: DatabaseSync, anchor: string): SessionMeta[] {
  return db.prepare(
    `SELECT key, conv, created_at, archived_at, archived_by, ws FROM sessions WHERE conv = ?1 AND ${OWNED_WS_SQL}
     UNION
     SELECT key, conv, created_at, archived_at, archived_by, ws FROM sessions WHERE key = ?1 AND ${OWNED_WS_SQL}`,
  ).all(anchor) as SessionMeta[];
}

const MEMBER_JOIN_IF_NEEDED = `INSERT INTO thread_sessions (thread, session, connect, joined_at) VALUES (?1, ?2, ?3, ?4)
  ON CONFLICT (thread, session) DO UPDATE SET left_at = NULL WHERE thread_sessions.left_at IS NOT NULL`;

/// Idempotent grouping entry point (`settle(thread)` in §3.2). Must be called inside a write transaction.
/// `born`: the session key being born right now (allowed to merge into a group with `chat_shares`).
export function settleConversationInTx(
  db: DatabaseSync,
  threadId: number,
  now: number,
  born: string | null = null,
): { sessions: string[]; threads: number[] } {
  const thread = db.prepare("SELECT id, surface, channel, thread_ts FROM threads WHERE id = ?").get(threadId) as
    | { id: number; surface: string; channel: string; thread_ts: string }
    | undefined;
  if (thread === undefined) return { sessions: [], threads: [] };

  const suffix = `:${thread.channel}:${thread.thread_ts}`;
  const raw = db.prepare(
    `SELECT s.key, s.conv, s.scope, s.created_at, s.archived_at, s.archived_by, s.ws, ts.left_at
     FROM thread_sessions ts
     JOIN sessions s ON s.key = ts.session
     WHERE ts.thread = ?`,
  ).all(threadId) as (SessionMeta & { scope: string; left_at: number | null })[];

  const birth = raw.filter((r) => r.scope === "thread" && isOwnedWs(r.ws) && r.key.endsWith(suffix));
  if (birth.length < 2) {
    if (birth.length === 1 && birth[0]!.conv === null) {
      db.prepare("UPDATE sessions SET conv = key WHERE key = ? AND conv IS NULL").run(birth[0]!.key);
    }
    return { sessions: [], threads: [] };
  }

  const leftByKey = new Map<string, number | null>();
  const anchorSet = new Set<string>();
  for (const b of birth) {
    leftByKey.set(b.key, b.left_at);
    anchorSet.add(typeof b.conv === "string" && b.conv !== "" ? b.conv : b.key);
  }

  const groups: Group[] = [];
  const hasShareStmt = db.prepare("SELECT 1 FROM chat_shares WHERE session = ? LIMIT 1");
  const homeStmt = db.prepare("SELECT id, hidden_at, hidden_by FROM threads WHERE home = ? ORDER BY id LIMIT 1");
  for (const anchor of anchorSet) {
    const members = loadGroupMembers(db, anchor);
    if (members.length === 0) continue;
    let earliestAt = members[0]!.created_at;
    let earliestKey = members[0]!.key;
    let hasShare = false;
    let isManual = false;
    for (const m of members) {
      if (compareEarliest(m.created_at, m.key, earliestAt, earliestKey) < 0) {
        earliestAt = m.created_at;
        earliestKey = m.key;
      }
      if (!hasShare && hasShareStmt.get(m.key) !== undefined) hasShare = true;
      if (m.archived_at !== null && m.archived_by === MANUAL) isManual = true;
    }
    const home = (homeStmt.get(anchor) as HomeRow | undefined) ?? null;
    const isBorn = born !== null && members.length === 1 && members[0]!.key === born && !hasShare;
    groups.push({ anchor, members, home, hasShare, isBorn, isManual, earliestAt, earliestKey });
  }

  const touchedSessions = new Set<string>();
  const touchedThreads = new Set<number>();

  const finalGroups: Group[] = [];
  for (const manualBucket of [true, false]) {
    const bucket = groups.filter((g) => g.isManual === manualBucket);
    if (bucket.length < 2) {
      for (const g of bucket) finalGroups.push(g);
      continue;
    }
    const homeGroups = bucket.filter((g) => g.home !== null);
    let target: Group;
    if (homeGroups.length === 1) {
      target = homeGroups[0]!;
    } else {
      target = bucket[0]!;
      for (let i = 1; i < bucket.length; i++) {
        const g = bucket[i]!;
        if (compareEarliest(g.earliestAt, g.earliestKey, target.earliestAt, target.earliestKey) < 0) target = g;
      }
    }

    const accepted: Group[] = [];
    const keptSeparate: Group[] = [];
    for (const g of bucket) {
      if (g === target) continue;
      if (g.home !== null) {
        keptSeparate.push(g);
        continue;
      }
      if ((target.hasShare || g.hasShare) && !g.isBorn) {
        keptSeparate.push(g);
        continue;
      }
      accepted.push(g);
    }

    if (accepted.length > 0) {
      const mergedMembers: SessionMeta[] = [...target.members];
      for (const g of accepted) {
        for (const m of g.members) {
          if (!mergedMembers.some((x) => x.key === m.key)) mergedMembers.push(m);
        }
      }
      const anchor = target.anchor;
      const setConv = db.prepare("UPDATE sessions SET conv = ? WHERE key = ?");
      for (const m of mergedMembers) {
        if (m.conv !== anchor) {
          setConv.run(anchor, m.key);
          m.conv = anchor;
          touchedSessions.add(m.key);
        }
      }

      // Converge archive state across mergedMembers and home chat.
      if (manualBucket) {
        let maxAt = 0;
        for (const m of mergedMembers) {
          if (m.archived_at !== null && m.archived_at > maxAt) maxAt = m.archived_at;
        }
        const setArch = db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?");
        for (const m of mergedMembers) {
          if (m.archived_at !== maxAt || m.archived_by !== MANUAL) {
            setArch.run(maxAt, MANUAL, m.key);
            m.archived_at = maxAt;
            m.archived_by = MANUAL;
            touchedSessions.add(m.key);
          }
        }
        if (target.home !== null && (target.home.hidden_at !== maxAt || target.home.hidden_by !== MANUAL)) {
          db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?").run(maxAt, MANUAL, target.home.id);
          target.home.hidden_at = maxAt;
          target.home.hidden_by = MANUAL;
          touchedThreads.add(target.home.id);
        }
      } else {
        const anyLive = mergedMembers.some((m) => m.archived_at === null);
        if (anyLive) {
          const unarch = db.prepare("UPDATE sessions SET archived_at = NULL, archived_by = NULL WHERE key = ?");
          for (const m of mergedMembers) {
            if (m.archived_at !== null || m.archived_by !== null) {
              unarch.run(m.key);
              m.archived_at = null;
              m.archived_by = null;
              touchedSessions.add(m.key);
            }
          }
          if (target.home !== null && (target.home.hidden_at !== null || target.home.hidden_by !== null)) {
            db.prepare("UPDATE threads SET hidden_at = NULL, hidden_by = NULL WHERE id = ?").run(target.home.id);
            target.home.hidden_at = null;
            target.home.hidden_by = null;
            touchedThreads.add(target.home.id);
          }
        } else {
          let maxAt = 0;
          for (const m of mergedMembers) {
            if (m.archived_at !== null && m.archived_at > maxAt) maxAt = m.archived_at;
          }
          const setArch = db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?");
          for (const m of mergedMembers) {
            if (m.archived_at !== maxAt || m.archived_by !== AUTO) {
              setArch.run(maxAt, AUTO, m.key);
              m.archived_at = maxAt;
              m.archived_by = AUTO;
              touchedSessions.add(m.key);
            }
          }
          if (target.home !== null && (target.home.hidden_at !== maxAt || target.home.hidden_by !== AUTO)) {
            db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE id = ?").run(maxAt, AUTO, target.home.id);
            target.home.hidden_at = maxAt;
            target.home.hidden_by = AUTO;
            touchedThreads.add(target.home.id);
          }
        }
      }
      target.members = mergedMembers;
    }

    finalGroups.push(target);
    for (const g of keptSeparate) finalGroups.push(g);
  }

  // Step 5: For every conversation that already has a home chat (whether hidden or not),
  // ensure all members that have not left the birth thread (left_at IS NULL) are in it.
  const joinHome = db.prepare(MEMBER_JOIN_IF_NEEDED);
  for (const g of finalGroups) {
    if (g.home === null) continue;
    if (g.members.length < 2 && !g.members.some((m) => m.conv !== null)) continue;
    for (const m of g.members) {
      if (!leftByKey.has(m.key) || leftByKey.get(m.key) !== null) continue;
      if (Number(joinHome.run(g.home.id, m.key, STILLFAIL_CONNECT, now).changes) > 0) {
        touchedSessions.add(m.key);
        touchedThreads.add(g.home.id);
      }
    }
  }

  if (touchedSessions.size > 0 || touchedThreads.size > 0) touchedThreads.add(threadId);
  return { sessions: [...touchedSessions], threads: [...touchedThreads] };
}

/// Startup repair (§3.2): scan only truly grouped sessions (`conv IS NOT NULL AND conv != key`) via
/// `sessions_conv_grouped`, and converge any conversation whose members have inconsistent archive state.
/// Takes no write lock when nothing needs repair.
export function repairConversations(db: DatabaseSync): void {
  const rows = db.prepare(
    `SELECT key, conv, created_at, archived_at, archived_by, ws
     FROM sessions INDEXED BY sessions_conv_grouped
     WHERE conv IS NOT NULL AND conv != key`,
  ).all() as SessionMeta[];
  const owned = rows.filter((r) => isOwnedWs(r.ws));
  if (owned.length === 0) return;

  const byConv = new Map<string, SessionMeta[]>();
  for (const r of owned) {
    const c = r.conv!;
    let list = byConv.get(c);
    if (list === undefined) byConv.set(c, (list = []));
    list.push(r);
  }

  const homeStmt = db.prepare("SELECT id, hidden_at, hidden_by FROM threads WHERE home = ? ORDER BY id LIMIT 1");
  const anchorStmt = db.prepare(`SELECT key, conv, created_at, archived_at, archived_by, ws FROM sessions WHERE key = ? AND ${OWNED_WS_SQL}`);
  const dirty: string[] = [];

  for (const [anchor, list] of byConv) {
    if (!list.some((m) => m.key === anchor)) {
      const a = anchorStmt.get(anchor) as SessionMeta | undefined;
      if (a !== undefined) list.push(a);
    }
    const home = (homeStmt.get(anchor) as HomeRow | undefined) ?? null;
    const first = list[0]!;
    const membersMatch = list.every((m) => m.archived_at === first.archived_at && m.archived_by === first.archived_by);
    const homeMatch = home === null || (home.hidden_at === first.archived_at && home.hidden_by === first.archived_by);
    const anchorConvOk = list.every((m) => m.conv === anchor);
    if (!membersMatch || !homeMatch || !anchorConvOk) dirty.push(anchor);
  }

  if (dirty.length === 0) return;

  db.exec("BEGIN IMMEDIATE");
  try {
    for (const anchor of dirty) {
      const members = loadGroupMembers(db, anchor);
      if (members.length === 0) continue;
      const live = members.filter((m) => m.archived_at === null);
      const auto = members.filter((m) => m.archived_at !== null && m.archived_by !== MANUAL);
      const manual = members.filter((m) => m.archived_at !== null && m.archived_by === MANUAL);

      const reanchor = (remaining: SessionMeta[]): string => {
        if (remaining.length === 0) return anchor;
        if (remaining.some((m) => m.key === anchor)) {
          for (const m of remaining) {
            if (m.conv !== anchor) db.prepare("UPDATE sessions SET conv = ? WHERE key = ?").run(anchor, m.key);
          }
          return anchor;
        }
        let best = remaining[0]!;
        for (let i = 1; i < remaining.length; i++) {
          const m = remaining[i]!;
          if (compareEarliest(m.created_at, m.key, best.created_at, best.key) < 0) best = m;
        }
        const nextAnchor = best.key;
        for (const m of remaining) {
          db.prepare("UPDATE sessions SET conv = ? WHERE key = ?").run(nextAnchor, m.key);
        }
        db.prepare("UPDATE threads SET home = ? WHERE home = ?").run(nextAnchor, anchor);
        return nextAnchor;
      };

      if (live.length > 0) {
        for (const m of auto) db.prepare("UPDATE sessions SET archived_at = NULL, archived_by = NULL WHERE key = ?").run(m.key);
        for (const m of manual) db.prepare("UPDATE sessions SET conv = NULL WHERE key = ?").run(m.key);
        const eff = reanchor([...live, ...auto]);
        db.prepare("UPDATE threads SET hidden_at = NULL, hidden_by = NULL WHERE home = ?").run(eff);
      } else if (auto.length > 0 && manual.length > 0) {
        for (const m of manual) db.prepare("UPDATE sessions SET conv = NULL WHERE key = ?").run(m.key);
        const eff = reanchor(auto);
        let maxAt = 0;
        for (const m of auto) if (m.archived_at! > maxAt) maxAt = m.archived_at!;
        for (const m of auto) db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?").run(maxAt, AUTO, m.key);
        db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?").run(maxAt, AUTO, eff);
      } else if (auto.length > 0) {
        let maxAt = 0;
        for (const m of auto) if (m.archived_at! > maxAt) maxAt = m.archived_at!;
        const eff = reanchor(auto);
        for (const m of auto) db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?").run(maxAt, AUTO, m.key);
        db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?").run(maxAt, AUTO, eff);
      } else if (manual.length > 0) {
        let maxAt = 0;
        for (const m of manual) if (m.archived_at! > maxAt) maxAt = m.archived_at!;
        const eff = reanchor(manual);
        for (const m of manual) db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?").run(maxAt, MANUAL, m.key);
        db.prepare("UPDATE threads SET hidden_at = ?, hidden_by = ? WHERE home = ?").run(maxAt, MANUAL, eff);
      }
    }
    db.exec("COMMIT");
  } catch (e) {
    try { db.exec("ROLLBACK"); } catch {}
    throw e;
  }
}

/// When `deleteSession` deletes an anchor, move remaining members' `conv` and `threads.home` to the earliest
/// `(created_at, key)` remaining member. Must run inside `deleteSession`'s transaction.
export function reanchorOnDeleteInTx(db: DatabaseSync, deletedKey: string): { sessions: string[]; threads: number[] } {
  const rest = db.prepare(
    `SELECT key, created_at FROM sessions
     WHERE conv = ?1 AND key != ?1 AND ${OWNED_WS_SQL}
     ORDER BY created_at, key`,
  ).all(deletedKey) as { key: string; created_at: number }[];
  if (rest.length === 0) return { sessions: [], threads: [] };
  const newAnchor = rest[0]!.key;
  db.prepare(`UPDATE sessions SET conv = ?1 WHERE conv = ?2 AND key != ?2 AND ${OWNED_WS_SQL}`).run(newAnchor, deletedKey);
  const homeRows = db.prepare("SELECT id FROM threads WHERE home = ?").all(deletedKey) as { id: number }[];
  if (homeRows.length > 0) {
    db.prepare("UPDATE threads SET home = ? WHERE home = ?").run(newAnchor, deletedKey);
  }
  return { sessions: rest.map((r) => r.key), threads: homeRows.map((r) => r.id) };
}

/// Extracts `(channel, threadTs)` from a `scope = 'thread'` session key (`<connect>:<channel>:<threadTs>`).
function splitSessionThread(key: string): [string, string] | null {
  const last = key.lastIndexOf(":");
  if (last <= 0 || last === key.length - 1) return null;
  const prev = key.lastIndexOf(":", last - 1);
  if (prev < 0 || prev + 1 >= last) return null;
  return [key.slice(prev + 1, last), key.slice(last + 1)];
}

/// Birth thread id(s) of a `scope = 'thread'` session, looked up in O(1) via `threads_at (channel, thread_ts)`
/// and the `thread_sessions (thread, session)` primary key (bounded by `LIMIT 8`).
export function birthThreadsOf(db: DatabaseSync, key: string): number[] {
  const s = db.prepare("SELECT scope, ws FROM sessions WHERE key = ?").get(key) as { scope: string; ws: string | null } | undefined;
  if (s === undefined || s.scope !== "thread" || !isOwnedWs(s.ws)) return [];
  const parts = splitSessionThread(key);
  if (parts === null) return [];
  const rows = db.prepare(
    `SELECT t.id FROM threads t INDEXED BY threads_at
       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1
       WHERE t.channel = ?2 AND t.thread_ts = ?3
       LIMIT 8`,
  ).all(key, parts[0], parts[1]) as { id: number }[];
  return rows.map((r) => r.id);
}

/// Members of conversation `anchor` that have not left their birth thread (`left_at IS NULL`);
/// if all have left, falls back to `[fallbackSession]` so a chat is never created empty (§3.3).
/// Each member's birth thread is checked in O(1) via `threads_at` + `thread_sessions` PK (`LIMIT 8`).
export function activeConversationMembers(db: DatabaseSync, anchor: string, fallbackSession: string): string[] {
  const members = membersOf(db, anchor);
  const active: string[] = [];
  const birthStmt = db.prepare(
    `SELECT ts.left_at FROM threads t INDEXED BY threads_at
       JOIN thread_sessions ts ON ts.thread = t.id AND ts.session = ?1
       WHERE t.channel = ?2 AND t.thread_ts = ?3
       LIMIT 8`,
  );
  const scopeStmt = db.prepare("SELECT scope FROM sessions WHERE key = ?");
  for (const m of members) {
    const row = scopeStmt.get(m) as { scope: string } | undefined;
    if (row?.scope === "thread") {
      const parts = splitSessionThread(m);
      if (parts !== null) {
        const birth = birthStmt.all(m, parts[0], parts[1]) as { left_at: number | null }[];
        if (birth.length > 0 && birth.every((t) => t.left_at !== null)) continue;
      }
    }
    active.push(m);
  }
  return active.length > 0 ? active : [fallbackSession];
}
