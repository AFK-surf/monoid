// The steps src/store/legacy-agent-build.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-agent-build.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, hasLegacyAgent, installLegacyAgent, type Entry, meta, limitOf } from "../../../src/store/legacy-agent-build.ts";

export * from "../../../src/store/legacy-agent-build.ts";

export function legacyAgentStep(db: DatabaseSync, limit = BATCH): { ready: boolean; visited: number } {
  limitOf(limit);
  installLegacyAgent(db);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error(`legacy agent version ${m.version} is incompatible with ${VERSION}`);
    if (m.scanned) { db.exec("COMMIT"); return { ready: true,visited: 0 }; }
    const columns = "CAST(e.thread AS TEXT) thread,CAST(e.n AS TEXT) n,CAST(e.at AS TEXT) at,e.kind,e.author_kind";
    const rows: Entry[] = [];
    if (m.end_thread !== null) {
      if (m.cursor_thread !== null) {
        const same = m.cursor_thread === m.end_thread;
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread=CAST(?1 AS INTEGER) AND e.n>CAST(?2 AS INTEGER)
          ${same ? "AND e.n<=CAST(?3 AS INTEGER) ORDER BY e.n LIMIT ?4" : "ORDER BY e.n LIMIT ?3"}`;
        rows.push(...(same ? db.prepare(sql).all(m.cursor_thread,m.cursor_n,m.end_n,limit)
          : db.prepare(sql).all(m.cursor_thread,m.cursor_n,limit)) as Entry[]);
      }
      if (rows.length < limit && m.cursor_thread !== m.end_thread) {
        const sql = `SELECT ${columns} FROM entries e WHERE e.thread<CAST(?1 AS INTEGER)
          ${m.cursor_thread === null ? "" : "AND e.thread>CAST(?2 AS INTEGER)"}
          ORDER BY e.thread,e.n LIMIT ?${m.cursor_thread === null ? 2 : 3}`;
        rows.push(...(m.cursor_thread === null ? db.prepare(sql).all(m.end_thread,limit-rows.length)
          : db.prepare(sql).all(m.end_thread,m.cursor_thread,limit-rows.length)) as Entry[]);
        if (rows.length < limit) rows.push(...db.prepare(`SELECT ${columns} FROM entries e
          WHERE e.thread=CAST(?1 AS INTEGER) AND e.n<=CAST(?2 AS INTEGER) ORDER BY e.n LIMIT ?3`)
          .all(m.end_thread,m.end_n,limit-rows.length) as Entry[]);
      }
    }
    const put = db.prepare(`INSERT INTO legacy_agent_build(thread,at,n)
      SELECT CAST(?1 AS INTEGER),CAST(?2 AS INTEGER),CAST(?3 AS INTEGER)
      WHERE NOT EXISTS (SELECT 1 FROM legacy_agent_dirty WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?3 AS INTEGER))
      ON CONFLICT(thread,at,n) DO NOTHING`);
    for (const row of rows) if (row.kind === "message" && row.author_kind === "agent") put.run(row.thread,row.at,row.n);
    const last = rows.at(-1), ready = rows.length < limit;
    db.prepare("UPDATE legacy_agent_meta SET scanned=?,cursor_thread=CAST(? AS INTEGER),cursor_n=CAST(? AS INTEGER) WHERE id=1")
      .run(ready ? 1 : 0,last?.thread ?? m.cursor_thread,last?.n ?? m.cursor_n);
    db.exec("COMMIT");
    return { ready,visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacyAgentDrain(db: DatabaseSync, limit = BATCH): number {
  limitOf(limit);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = meta(db);
    if (m.version !== VERSION) throw new Error(`legacy agent version ${m.version} is incompatible with ${VERSION}`);
    // Before the scan has passed a key, folding it could make the scanner stage an older time for the same key.
    if (!m.scanned) { db.exec("COMMIT"); return 0; }
    const first = db.prepare(`SELECT CAST(d.thread AS TEXT) thread,CAST(d.n AS TEXT) n,CAST(d.old_at AS TEXT) old_at
      FROM legacy_agent_dirty d ORDER BY d.thread,d.n LIMIT 1`);
    const current = db.prepare(`SELECT CAST(at AS TEXT) at FROM entries WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)
      AND kind='message' AND author_kind='agent'`);
    const extras = db.prepare(`SELECT CAST(at AS TEXT) at FROM legacy_agent_times INDEXED BY legacy_agent_times_by_key
      WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER) AND (?3 IS NULL OR at != CAST(?3 AS INTEGER))
      ORDER BY legacy_agent_times.at LIMIT ?4`);
    const dropTime = db.prepare("DELETE FROM legacy_agent_times WHERE thread=CAST(? AS INTEGER) AND at=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)");
    const drop = db.prepare("DELETE FROM legacy_agent_build WHERE thread=CAST(? AS INTEGER) AND at=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)");
    const put = db.prepare(`INSERT INTO legacy_agent_build(thread,at,n)
      SELECT thread,at,n FROM entries WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)
        AND kind='message' AND author_kind='agent' ON CONFLICT(thread,at,n) DO NOTHING`);
    const done = db.prepare("DELETE FROM legacy_agent_dirty WHERE thread=CAST(? AS INTEGER) AND n=CAST(? AS INTEGER)");
    let visited = 0;
    while (visited < limit) {
      const key = first.get() as { thread: string; n: string; old_at: string | null } | undefined;
      if (!key) break;
      const now = (current.get(key.thread,key.n) as { at: string } | undefined)?.at ?? null;
      const oldTimes = extras.all(key.thread,key.n,now,limit-visited) as { at: string }[];
      for (const time of oldTimes) { dropTime.run(key.thread,time.at,key.n); visited++; }
      if (visited === limit) break;
      if (key.old_at !== null) drop.run(key.thread,key.old_at,key.n);
      put.run(key.thread,key.n);
      if (now !== null) dropTime.run(key.thread,now,key.n);
      done.run(key.thread,key.n);
      visited++;
    }
    db.exec("COMMIT");
    return visited;
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacyAgentMaintenanceStep(db: DatabaseSync): { done: boolean; visited: number } {
  if (!hasLegacyAgent(db)) return { done: true,visited: 0 };
  if (!meta(db).scanned) {
    const result = legacyAgentStep(db);
    return { done: false,visited: result.visited };
  }
  const visited = legacyAgentDrain(db);
  return { done: visited < BATCH,visited };
}
