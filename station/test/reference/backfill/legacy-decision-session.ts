// The steps src/store/legacy-decision-session.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-decision-session.ts's.
import type { DatabaseSync } from "node:sqlite";
import { VERSION, BATCH, type SessionTable, sessionState, hasSessionLookup, SCHEMA, meta, decisionSessionRepairNeedsWork } from "../../../src/store/legacy-decision-session.ts";

export * from "../../../src/store/legacy-decision-session.ts";

const REPAIR_TRIGGERS = SCHEMA.slice(SCHEMA.indexOf("CREATE TRIGGER")).replaceAll("legacy_decision_session", "legacy_decision_session_repair");
const REPAIR_INDEX = "CREATE INDEX legacy_decision_session_repair_by_session ON legacy_decision_session_repair(session)";

function sessionIndexStep(db: DatabaseSync, table: SessionTable, limit: number): { done: boolean; visited: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("decision-session batch must be 1–64");
  if (table === "legacy_decision_session_repair" ? !decisionSessionRepairNeedsWork(db) : !hasSessionLookup(db, table))
    return { done: true, visited: 0 };
  db.exec("BEGIN IMMEDIATE");
  try {
    if (table === "legacy_decision_session_repair" && sessionState(db, table) === 2) {
      const removed = db.prepare(`DELETE FROM ${table} WHERE id IN (SELECT id FROM ${table} ORDER BY id LIMIT ?)`).run(limit).changes;
      if (db.prepare(`SELECT 1 FROM ${table} LIMIT 1`).get() === undefined) {
        db.exec(`${REPAIR_INDEX}; ${REPAIR_TRIGGERS}`);
        db.exec(`UPDATE ${table}_meta SET complete=0,cursor=NULL,end_id=(SELECT MAX(id) FROM decision_checks) WHERE id=1`);
      }
      db.exec("COMMIT");
      return { done: false, visited: Number(removed) };
    }
    // Another connection can remove the index between the initial check and this writer lock.
    if (!hasSessionLookup(db, table)) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const m = meta(db, table);
    if (m.version !== VERSION) throw new Error("unsupported legacy decision-session preparation");
    if (m.complete === 1) { db.exec("COMMIT"); return { done: true, visited: 0 }; }
    const rows = m.end_id === null ? [] : (m.cursor === null
      ? db.prepare(`SELECT CAST(id AS TEXT) id FROM decision_checks WHERE id<=CAST(?1 AS INTEGER)
          ORDER BY decision_checks.id LIMIT ?2`).all(m.end_id, limit)
      : db.prepare(`SELECT CAST(id AS TEXT) id FROM decision_checks WHERE id>CAST(?1 AS INTEGER) AND id<=CAST(?2 AS INTEGER)
          ORDER BY decision_checks.id LIMIT ?3`).all(m.cursor, m.end_id, limit)) as { id: string }[];
    const put = db.prepare(`INSERT INTO ${table}(id,session)
      SELECT id,session FROM decision_checks d WHERE d.id=CAST(?1 AS INTEGER)
        AND NOT EXISTS (SELECT 1 FROM ${table} l WHERE l.id=d.id)`);
    for (const row of rows) put.run(row.id);
    const done = rows.length < limit;
    db.prepare(`UPDATE ${table}_meta SET cursor=CAST(? AS INTEGER),complete=? WHERE id=1`)
      .run(rows.at(-1)?.id ?? m.cursor, done ? 1 : 0);
    db.exec("COMMIT");
    return { done, visited: rows.length };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export const decisionSessionIndexStep = (db: DatabaseSync, limit = BATCH) => sessionIndexStep(db, "legacy_decision_session", limit);
export const decisionSessionRepairStep = (db: DatabaseSync, limit = BATCH) => sessionIndexStep(db, "legacy_decision_session_repair", limit);
