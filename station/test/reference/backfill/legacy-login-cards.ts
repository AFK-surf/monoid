// The steps src/store/legacy-login-cards.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/legacy-login-cards.ts's.
import type { DatabaseSync } from "node:sqlite";

import { VERSION, BATCH, exists, hasLegacyLoginCards, type Row, fields, readMeta, installLegacyLoginCards } from "../../../src/store/legacy-login-cards.ts";

export * from "../../../src/store/legacy-login-cards.ts";

export function legacyLoginCardsStep(db: DatabaseSync, limit = 64): { ready: boolean; visited: number; tokens: number } {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > BATCH) throw new RangeError("login card batch must be 1–64");
  installLegacyLoginCards(db);
  db.exec("BEGIN IMMEDIATE");
  try {
    const m = readMeta(db);
    if (m.version !== VERSION || (m.scanned !== 0 && m.scanned !== 1)) {
      throw new Error("unsupported login card preparation");
    }
    if (m.scanned) { db.exec("COMMIT"); return { ready: true, visited: 0, tokens: 0 }; }
    // Qualify the sort keys: the selected aliases are text for lossless JS transport, but SQLite must sort integers.
    // Recheck under the writer lock: an older connection may have installed or removed the native index since the last
    // batch. Its partial predicate is a superset of the cards we need; triggers keep newer writes current.
    const from = exists(db,"index","entries_login_cards")
      ? `FROM entries INDEXED BY entries_login_cards WHERE card LIKE '%"login"%'` : "FROM entries WHERE 1";
    const first = db.prepare(`SELECT ${fields} ${from} AND thread<=CAST(?1 AS INTEGER) ORDER BY entries.thread,entries.n LIMIT 1`);
    const same = db.prepare(`SELECT ${fields} ${from} AND thread=CAST(?1 AS INTEGER) AND n>CAST(?2 AS INTEGER) ORDER BY entries.n LIMIT 1`);
    const later = db.prepare(`SELECT ${fields} ${from} AND thread>CAST(?1 AS INTEGER) AND thread<=CAST(?2 AS INTEGER) ORDER BY entries.thread,entries.n LIMIT 1`);
    // A partially scanned card can have changed since the previous batch, even so it no longer matches the index.
    const exact = db.prepare(`SELECT ${fields} FROM entries WHERE thread=CAST(?1 AS INTEGER) AND n=CAST(?2 AS INTEGER)`);
    const put = db.prepare(`INSERT INTO login_card_keys(login,thread,n,entry_rowid,ts)
      SELECT ?1,CAST(?2 AS INTEGER),CAST(?3 AS INTEGER),CAST(?4 AS INTEGER),?5
      WHERE NOT EXISTS (SELECT 1 FROM login_card_keys WHERE login=?1 AND thread=CAST(?2 AS INTEGER) AND n=CAST(?3 AS INTEGER))`);
    let visited = 0, tokens = 0, ready = m.end_thread === null;
    while (!ready && visited < limit && tokens < limit) {
      let row: Row | undefined;
      if (m.offset !== null) {
        row = exact.get(m.cursor_thread!,m.cursor_n!) as Row | undefined;
        if (!row) { m.offset = null; continue; }
      } else {
        row = (m.cursor_thread === null ? first.get(m.end_thread!) : same.get(m.cursor_thread,m.cursor_n!)) as Row | undefined;
        if (!row && m.cursor_thread !== null) row = later.get(m.cursor_thread,m.end_thread!) as Row | undefined;
        if (!row || BigInt(row.thread) > BigInt(m.end_thread!) || (row.thread === m.end_thread && BigInt(row.n) > BigInt(m.end_n!))) {
          ready = true; break;
        }
        m.cursor_thread = row.thread; m.cursor_n = row.n; m.offset = 0;
      }
      visited++;
      if (row.kind !== "message" || row.author_kind !== "agent" || typeof row.card !== "string") { m.offset = null; continue; }
      // SQLite's default LIKE folds only ASCII. LIKE also stops at NUL, so no candidate after it can match.
      let text = row.card.replace(/[A-Z]/g, (c) => c.toLowerCase());
      const nul = text.indexOf("\0"); if (nul !== -1) text = text.slice(0,nul);
      const prefix = '"login":"';
      let offset = m.offset!;
      while (tokens < limit) {
        const start = text.indexOf(prefix,offset);
        if (start === -1) { m.offset = null; break; }
        offset = start + prefix.length;
        const end = text.indexOf('"',offset);
        const login = end === -1 ? "" : text.slice(offset,end);
        if (/^[0-9a-z]{1,40}$/.test(login)) put.run(login,row.thread,row.n,row.entry_rowid,row.ts);
        tokens++;
        m.offset = offset;
      }
    }
    db.prepare(`UPDATE login_card_meta SET scanned=?,cursor_thread=CAST(? AS INTEGER),cursor_n=CAST(? AS INTEGER),offset=? WHERE id=1`)
      .run(ready ? 1 : 0,m.cursor_thread,m.cursor_n,m.offset);
    db.exec("COMMIT");
    return { ready,visited,tokens };
  } catch (error) { try { db.exec("ROLLBACK"); } catch {} throw error; }
}

export function legacyLoginCardsMaintenanceStep(db: DatabaseSync): { done: boolean; visited: number } {
  if (!hasLegacyLoginCards(db)) return { done: true,visited: 0 };
  const result = legacyLoginCardsStep(db);
  return { done: result.ready,visited: result.visited };
}
