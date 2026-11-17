// The earliest recorded usage is one statistic, not a query over the calls each time the usage page is read. SQLite
// answers MIN from the first entry of usage_at, so installing and maintaining it need no history scan.
import type { DatabaseSync } from "node:sqlite";

const FIRST = "(SELECT MIN(at) FROM usage INDEXED BY usage_at)";
const TABLE = `
CREATE TABLE IF NOT EXISTS usage_span (id INTEGER PRIMARY KEY CHECK (id = 1), first_at INTEGER);
INSERT OR REPLACE INTO usage_span VALUES (1, ${FIRST});`;
const TRIGGERS = `
CREATE TRIGGER usage_span_add AFTER INSERT ON usage WHEN
  (SELECT first_at FROM usage_span WHERE id = 1) IS NULL
  OR NEW.at < (SELECT first_at FROM usage_span WHERE id = 1)
  OR NOT EXISTS (SELECT 1 FROM usage INDEXED BY usage_at WHERE at = (SELECT first_at FROM usage_span WHERE id = 1)) BEGIN
  -- REPLACE can remove the earliest conflicting row without firing its delete trigger. Check that it still exists.
  UPDATE usage_span SET first_at = ${FIRST} WHERE id = 1;
END;
CREATE TRIGGER usage_span_drop AFTER DELETE ON usage WHEN OLD.at = (SELECT first_at FROM usage_span WHERE id = 1) BEGIN
  UPDATE usage_span SET first_at = ${FIRST} WHERE id = 1;
END;
CREATE TRIGGER usage_span_move AFTER UPDATE OF at ON usage WHEN OLD.at <> NEW.at AND
  (OLD.at = (SELECT first_at FROM usage_span WHERE id = 1) OR NEW.at < (SELECT first_at FROM usage_span WHERE id = 1)) BEGIN
  UPDATE usage_span SET first_at = ${FIRST} WHERE id = 1;
END;
`;

/// Install under the same short write lock as the triggers so a concurrent old writer cannot fall between them. A
/// station whose minute statistics stopped its triggers (they kept the first call themselves; usage-retire.ts drops
/// them) has them again, the first call found again by its index.
export function installUsageSpan(db: DatabaseSync): void {
  const installed = () => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = 'usage_span_add'").get() !== undefined;
  if (installed()) return;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (!installed()) db.exec(`DROP TRIGGER IF EXISTS usage_span_drop; DROP TRIGGER IF EXISTS usage_span_move; ${TABLE} ${TRIGGERS}`);
    db.exec("COMMIT");
  } catch (error) {
    db.exec("ROLLBACK");
    throw error;
  }
}
