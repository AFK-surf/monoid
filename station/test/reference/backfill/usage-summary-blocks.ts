// The steps src/store/usage-summary-blocks.ts built its lookup by before the MoonBit builder took them over, kept to
// compare the program with: the station has no step in TypeScript to fall back to. What it still runs is
// src/store/usage-summary-blocks.ts's.
import type { DatabaseSync } from "node:sqlite";
import { key, dimensions, values } from "../../../src/store/usage-summary-blocks.ts";
import type { UsageSummaryKey, UsageSummaryRange } from "../../../src/store/usage-summary-blocks.ts";

export * from "../../../src/store/usage-summary-blocks.ts";

type Key = UsageSummaryKey;
type Snapshot = Key & { scope: string; calls: bigint; input: bigint; cache_read: bigint; cache_write: bigint; cache_write_long: bigint; output: bigint };
type Progress = { done: bigint; after_session: string | null; after_minute: bigint | null; after_thread: bigint | null;
  after_person: string | null; after_profile: string | null; after_runtime: string | null; after_model: string | null; after_fast: bigint | null };
type Change = { scope: string; level: bigint; bucket: bigint; dimensions: (string | bigint)[]; parts: bigint } & Record<typeof values[number], bigint>;

const scopedKey = ["minute", "session", "thread", "person", "profile", "runtime", "model", "fast"] as const;
const BATCH = 32;
const floorDiv = (n: bigint, d: bigint) => n >= 0n ? n / d : -1n - ((-1n - n) / d);
const argsOf = (row: Key): (string | bigint)[] => key.map((name) => row[name]);
const dimensionArgs = (row: Key): (string | bigint)[] => dimensions.map((name) => row[name]);
const serialize = (row: (string | bigint)[]) => JSON.stringify(row.map((v) => typeof v === "bigint" ? v.toString() : v));
const indexed = (db: DatabaseSync, sql: string) => { const stmt = db.prepare(sql); stmt.setReadBigInts(true); return stmt; };
/// The global cursor follows the primary key; a requested workspace seeks its own time index.
export function usageSummaryBlocksScan(scoped: boolean, after: boolean): string {
  const order = scoped ? scopedKey : key;
  const where = scoped ? "WHERE scope = ?" : "";
  const afterCursor = !after ? "" : `${scoped ? " AND" : "WHERE"} (${order.join(", ")}) > (${order.map(() => "?").join(", ")})`;
  return `SELECT ${key.join(", ")} FROM usage_compact ${scoped ? "INDEXED BY usage_compact_scope_time" : ""}
    ${where} ${afterCursor} ORDER BY ${order.join(", ")} LIMIT ?`;
}
/// Only the requested minutes, in the same order as their scope/time index.
export function usageSummaryBlocksRangeScan(scoped: boolean, after: boolean): string {
  const scope = scoped ? "scope = ? AND " : "";
  const cursor = after ? ` AND (${scopedKey.join(", ")}) > (${scopedKey.map(() => "?").join(", ")})` : "";
  return `SELECT ${key.join(", ")} FROM usage_compact INDEXED BY usage_compact_${scoped ? "scope_time" : "time"}
    WHERE ${scope}minute >= ? AND minute < ?${cursor} ORDER BY ${scopedKey.join(", ")} LIMIT ?`;
}
/// A scope can finish before the station-wide conversion. A missing cursor means it has not yet been requested.
export function usageSummaryBlocksReady(db: DatabaseSync, scope?: string): boolean {
  const progress = db.prepare("SELECT done FROM usage_summary_blocks_progress WHERE id = 1").get() as { done: number };
  if (progress.done === 1) return true;
  if (scope === undefined || scope === "G") return false;
  const scoped = db.prepare("SELECT done FROM usage_summary_blocks_scope_progress WHERE scope = ?").get(scope) as { done: number } | undefined;
  return scoped?.done === 1;
}
/// The queue is indexed for either side of a scope change. No other workspace's pending rows need be enumerated.
export function usageSummaryBlocksPending(db: DatabaseSync, scope?: string, range?: UsageSummaryRange): boolean {
  if (!usageSummaryBlocksReady(db, scope) && (range === undefined || !range.converted)) return true;
  const bounds = range === undefined ? "" : " AND minute >= ? AND minute < ?";
  const times = range === undefined ? [] : [range.from, range.to];
  if (scope === undefined || scope === "G") return range === undefined
    ? db.prepare("SELECT 1 FROM usage_summary_blocks_dirty LIMIT 1").get() !== undefined
    : db.prepare("SELECT 1 FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_time WHERE minute >= ? AND minute < ? LIMIT 1")
      .get(...times) !== undefined;
  return db.prepare(`SELECT 1 FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_old WHERE old_scope = ?${bounds} LIMIT 1`).get(scope, ...times) !== undefined
    || db.prepare(`SELECT 1 FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_new WHERE new_scope = ?${bounds} LIMIT 1`).get(scope, ...times) !== undefined;
}
/// One bounded transaction converts existing compact rows or reconciles changed ones. Shadow rows record precisely
/// what has reached the blocks, including scope and zero-valued groups; they make replacement and deletion exact.
export function usageSummaryBlocksStep(db: DatabaseSync, batch = BATCH, scope?: string, range?: UsageSummaryRange):
  { done: boolean; processed: number; after?: Key; converted?: boolean } {
  if (!Number.isSafeInteger(batch) || batch < 1) throw new RangeError("usage summary batch must be positive");
  batch = Math.min(batch, BATCH);
  db.exec("BEGIN IMMEDIATE");
  try {
    const progress = indexed(db, "SELECT * FROM usage_summary_blocks_progress WHERE id = 1").get() as Progress;
    const scoped = range === undefined && progress.done === 0n && scope !== undefined && scope !== "G";
    let cursor = progress;
    if (scoped) {
      db.prepare("INSERT OR IGNORE INTO usage_summary_blocks_scope_progress (scope, done) VALUES (?, 0)").run(scope);
      cursor = indexed(db, "SELECT * FROM usage_summary_blocks_scope_progress WHERE scope = ?").get(scope) as Progress;
    }
    const converting = range === undefined ? cursor.done === 0n : !range.converted && !usageSummaryBlocksReady(db, scope);
    const order = scoped ? scopedKey : key;
    const after = cursor.after_session === null ? [] : order.map((name) => cursor[`after_${name}`]!);
    let rows: Key[];
    if (converting && range !== undefined) {
      const onlyScope = scope !== undefined && scope !== "G";
      const afterRange = range.after === undefined ? [] : scopedKey.map((name) => range.after![name]);
      rows = indexed(db, usageSummaryBlocksRangeScan(onlyScope, range.after !== undefined))
        .all(...(onlyScope ? [scope!] : []), range.from, range.to, ...afterRange, batch) as Key[];
    } else if (converting) {
      rows = indexed(db, usageSummaryBlocksScan(scoped, cursor.after_session !== null))
        .all(...(scoped ? [scope!] : []), ...after, batch) as Key[];
    } else if (scope === undefined || scope === "G") {
      rows = range === undefined
        ? indexed(db, `SELECT ${key.join(", ")} FROM usage_summary_blocks_dirty ORDER BY ${key.join(", ")} LIMIT ?`).all(batch) as Key[]
        : indexed(db, `SELECT ${key.join(", ")} FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_time
          WHERE minute >= ? AND minute < ? LIMIT ?`).all(range.from, range.to, batch) as Key[];
    } else {
      const bounds = range === undefined ? "" : " AND minute >= ? AND minute < ?";
      const times = range === undefined ? [] : [range.from, range.to];
      rows = indexed(db, `SELECT ${key.join(", ")} FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_old
        WHERE old_scope = ?${bounds} LIMIT ?`).all(scope, ...times, batch) as Key[];
      if (rows.length < batch) {
        const seen = new Set(rows.map((row) => serialize(argsOf(row))));
        const next = indexed(db, `SELECT ${key.join(", ")} FROM usage_summary_blocks_dirty INDEXED BY usage_summary_blocks_dirty_new
          WHERE new_scope = ?${bounds} LIMIT ?`).all(scope, ...times, batch + rows.length) as Key[];
        for (const row of next) {
          const id = serialize(argsOf(row));
          if (!seen.has(id)) { rows.push(row); seen.add(id); }
          if (rows.length === batch) break;
        }
      }
    }
    const where = key.map((name) => `${name} = ?`).join(" AND ");
    const old = indexed(db, `SELECT ${key.join(", ")}, scope, ${values.join(", ")} FROM usage_summary_blocks_shadow WHERE ${where}`);
    const current = indexed(db, `SELECT ${key.join(", ")}, scope, ${values.join(", ")} FROM usage_compact WHERE ${where} AND records > 0`);
    const forget = db.prepare(`DELETE FROM usage_summary_blocks_shadow WHERE ${where}`);
    const clear = db.prepare(`DELETE FROM usage_summary_blocks_dirty WHERE ${where}`);
    const save = db.prepare(`INSERT INTO usage_summary_blocks_shadow (${key.join(", ")}, scope, ${values.join(", ")})
      VALUES (${[...key, "scope", ...values].map(() => "?").join(", ")}) ON CONFLICT (${key.join(", ")}) DO UPDATE SET
      scope = excluded.scope, ${values.map((name) => `${name} = excluded.${name}`).join(", ")}`);
    const changed = new Map<string, Change>();
    const add = (row: Snapshot, sign: bigint) => {
      for (const size of [15n, 60n]) {
        const bucket = floorDiv(row.minute, size);
        const dims = dimensionArgs(row);
        const id = serialize([row.scope, size, bucket, ...dims]);
        let delta = changed.get(id);
        if (delta === undefined) {
          delta = { scope: row.scope, level: size, bucket, dimensions: dims, parts: 0n,
            calls: 0n, input: 0n, cache_read: 0n, cache_write: 0n, cache_write_long: 0n, output: 0n };
          changed.set(id, delta);
        }
        delta.parts += sign;
        for (const name of values) delta[name] += sign * row[name];
      }
    };
    for (const row of rows) {
      const args = argsOf(row);
      const previous = old.get(...args) as Snapshot | undefined;
      const now = current.get(...args) as Snapshot | undefined;
      if (previous !== undefined) add(previous, -1n);
      if (now !== undefined) {
        add(now, 1n);
        save.run(...args, now.scope, ...values.map((name) => now[name]));
      } else if (previous !== undefined) forget.run(...args);
      clear.run(...args);
    }
    const columns = ["scope", "level", "bucket", ...dimensions, "parts", ...values];
    const pk = ["scope", "level", "bucket", ...dimensions];
    const put = db.prepare(`INSERT INTO usage_summary_blocks (${columns.join(", ")}) VALUES (${columns.map(() => "?").join(", ")})
      ON CONFLICT (${pk.join(", ")}) DO UPDATE SET ${["parts", ...values].map((name) => `${name} = ${name} + excluded.${name}`).join(", ")}`);
    const clean = db.prepare(`DELETE FROM usage_summary_blocks WHERE ${pk.map((name) => `${name} = ?`).join(" AND ")} AND parts = 0`);
    for (const delta of changed.values()) {
      if (delta.parts === 0n && values.every((name) => delta[name] === 0n)) continue;
      const id = [delta.scope, delta.level, delta.bucket, ...delta.dimensions];
      put.run(...id, delta.parts, ...values.map((name) => delta[name]));
      clean.run(...id);
    }
    if (range !== undefined) {
      if (converting && rows.length === batch) {
        db.exec("COMMIT");
        return { done: false, processed: rows.length, after: rows[rows.length - 1]! };
      }
      const complete = !usageSummaryBlocksPending(db, scope, { ...range, converted: true });
      db.exec("COMMIT");
      return complete ? { done: true, processed: rows.length } : { done: false, processed: rows.length, converted: true };
    }
    if (converting) {
      const table = scoped ? "usage_summary_blocks_scope_progress" : "usage_summary_blocks_progress";
      const condition = scoped ? "scope = ?" : "id = 1";
      const scopeArgs = scoped ? [scope!] : [];
      if (rows.length < batch) db.prepare(`UPDATE ${table} SET done = 1 WHERE ${condition}`).run(...scopeArgs);
      else {
        const last = rows[rows.length - 1]!;
        db.prepare(`UPDATE ${table} SET ${key.map((name) => `after_${name} = ?`).join(", ")} WHERE ${condition}`)
          .run(...argsOf(last), ...scopeArgs);
      }
    }
    const complete = !usageSummaryBlocksPending(db, scope);
    db.exec("COMMIT");
    return { done: complete, processed: rows.length };
  } catch (error) { db.exec("ROLLBACK"); throw error; }
}