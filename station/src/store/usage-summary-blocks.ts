// Coarser, grouped usage statistics. They are made only from usage_compact, never from the original calls.
import type { DatabaseSync } from "node:sqlite";

export const key = ["session", "minute", "thread", "person", "profile", "runtime", "model", "fast"] as const;
export const dimensions = ["session", "thread", "person", "profile", "runtime", "model", "fast"] as const;
export const values = ["calls", "input", "cache_read", "cache_write", "cache_write_long", "output"] as const;
const keyDecl = `session TEXT NOT NULL, minute INTEGER NOT NULL, thread INTEGER NOT NULL, person TEXT NOT NULL,
  profile TEXT NOT NULL, runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL`;
const dimensionsDecl = `session TEXT NOT NULL, thread INTEGER NOT NULL, person TEXT NOT NULL, profile TEXT NOT NULL,
  runtime TEXT NOT NULL, model TEXT NOT NULL, fast INTEGER NOT NULL`;
const valuesDecl = values.map((name) => `${name} INTEGER NOT NULL`).join(", ");
const sameKey = (table: string, row: string) => key.map((name) => `${table}.${name} = ${row}.${name}`).join(" AND ");
const fields = (row: string, names: readonly string[]) => names.map((name) => `${row}.${name}`).join(", ");
export const USAGE_SUMMARY_PENDING = "usage summary statistics are being prepared";
export const hasUsageSummaryBlocks = (db: DatabaseSync): boolean =>
  db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'usage_summary_blocks_progress'").get() !== undefined;

/// Install empty structures and a change queue. The existence check seeks one compact row; no old calls or summaries
/// are traversed in this transaction. Updates coalesce until a worker applies their latest state.
export function installUsageSummaryBlocks(db: DatabaseSync): void {
  const has = (name: string) => db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(name) !== undefined;
  if (!has("usage_compact") || hasUsageSummaryBlocks(db)) return;
  const mark = (row: string, when = "1") => `INSERT INTO usage_summary_blocks_dirty (${key.join(", ")}, old_scope, new_scope)
    SELECT ${fields(row, key)},
      (SELECT scope FROM usage_summary_blocks_shadow s WHERE ${sameKey("s", row)}),
      (SELECT scope FROM usage_compact c WHERE ${sameKey("c", row)} AND c.records > 0)
    WHERE ${when}
    ON CONFLICT (${key.join(", ")}) DO UPDATE SET old_scope = excluded.old_scope, new_scope = excluded.new_scope
      WHERE usage_summary_blocks_dirty.old_scope IS NOT excluded.old_scope OR usage_summary_blocks_dirty.new_scope IS NOT excluded.new_scope;`;
  db.exec("BEGIN IMMEDIATE");
  try {
    if (has("usage_summary_blocks_progress")) { db.exec("COMMIT"); return; }
    db.exec(`
      CREATE TABLE usage_summary_blocks_progress (id INTEGER PRIMARY KEY CHECK (id = 1), done INTEGER NOT NULL,
        after_session TEXT, after_minute INTEGER, after_thread INTEGER, after_person TEXT, after_profile TEXT,
        after_runtime TEXT, after_model TEXT, after_fast INTEGER);
      INSERT INTO usage_summary_blocks_progress (id, done) VALUES (1, NOT EXISTS (SELECT 1 FROM usage_compact LIMIT 1));
      CREATE TABLE usage_summary_blocks_scope_progress (scope TEXT PRIMARY KEY, done INTEGER NOT NULL,
        after_session TEXT, after_minute INTEGER, after_thread INTEGER, after_person TEXT, after_profile TEXT,
        after_runtime TEXT, after_model TEXT, after_fast INTEGER) WITHOUT ROWID;
      CREATE TABLE usage_summary_blocks_shadow (${keyDecl}, scope TEXT NOT NULL, ${valuesDecl},
        PRIMARY KEY (${key.join(", ")})) WITHOUT ROWID;
      CREATE INDEX usage_summary_blocks_shadow_time ON usage_summary_blocks_shadow (minute, ${dimensions.join(", ")});
      CREATE INDEX usage_summary_blocks_shadow_scope_time ON usage_summary_blocks_shadow (scope, minute, ${dimensions.join(", ")});
      CREATE TABLE usage_summary_blocks_dirty (${keyDecl}, old_scope TEXT, new_scope TEXT,
        PRIMARY KEY (${key.join(", ")})) WITHOUT ROWID;
      CREATE INDEX usage_summary_blocks_dirty_time ON usage_summary_blocks_dirty (minute, ${dimensions.join(", ")});
      CREATE INDEX usage_summary_blocks_dirty_old ON usage_summary_blocks_dirty (old_scope, minute, ${dimensions.join(", ")});
      CREATE INDEX usage_summary_blocks_dirty_new ON usage_summary_blocks_dirty (new_scope, minute, ${dimensions.join(", ")});
      CREATE TABLE usage_summary_blocks (scope TEXT NOT NULL, level INTEGER NOT NULL, bucket INTEGER NOT NULL,
        ${dimensionsDecl}, parts INTEGER NOT NULL, ${valuesDecl},
        PRIMARY KEY (scope, level, bucket, ${dimensions.join(", ")})) WITHOUT ROWID;
      CREATE INDEX usage_summary_blocks_time ON usage_summary_blocks (level, bucket, scope, ${dimensions.join(", ")});
      CREATE TRIGGER usage_summary_blocks_add AFTER INSERT ON usage_compact BEGIN ${mark("NEW")} END;
      CREATE TRIGGER usage_summary_blocks_change AFTER UPDATE OF ${[...key, "scope", "records", ...values].join(", ")} ON usage_compact
        WHEN ${[...key, "scope", "records", ...values].map((name) => `OLD.${name} IS NOT NEW.${name}`).join(" OR ")} BEGIN
          ${mark("OLD")} ${mark("NEW", key.map((name) => `OLD.${name} IS NOT NEW.${name}`).join(" OR "))}
      END;
      CREATE TRIGGER usage_summary_blocks_drop AFTER DELETE ON usage_compact BEGIN ${mark("OLD")} END;
    `);
    db.exec("COMMIT");
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}

export type UsageSummaryKey = { session: string; minute: bigint; thread: bigint; person: string; profile: string; runtime: string; model: string; fast: bigint };
export type UsageSummaryRange = { from: bigint; to: bigint; after?: UsageSummaryKey; converted?: boolean };
