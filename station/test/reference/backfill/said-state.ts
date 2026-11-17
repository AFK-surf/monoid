// The steps src/store/said-state.ts built its lookup by before the MoonBit builder took them over, kept to compare the
// program with: the station has no step in TypeScript to fall back to. What it still runs is src/store/said-state.ts's.
import { randomBytes } from "node:crypto";
import type { DatabaseSync } from "node:sqlite";
import { hasLegacySaid, legacySaidDrainThread, legacySaidReadHead, legacySaidThreadNeedsDrain, LEGACY_SAID_SCAN } from "../../../src/store/legacy-said-build.ts";
import { SAID_LATEST, SAID_STATE, SAID_SCAN, SAID_BATCH_SIZE, saidBoundary } from "../../../src/store/said-state.ts";
import type { Latest, State } from "../../../src/store/said-state.ts";

export * from "../../../src/store/said-state.ts";

export type SaidScan = { thread: number; author: string; token: string; before: number;
  found?: { other: number | null } };
type SaidStep = { done: boolean; visited: number; scan: SaidScan | null };

/// Read at most one small slice of a requested old chat. No lock is held between slices. A guard is invalidated by
/// writes that can change the result, so the last transaction can either publish this answer or safely start again.
export function saidScanStep(db: DatabaseSync, thread: number, scan: SaidScan | null, limit = SAID_BATCH_SIZE,
  mayWrite?: () => boolean): SaidStep {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > SAID_BATCH_SIZE) throw new RangeError("said scan batch must be between 1 and 64");
  if (scan !== null && scan.thread !== thread) throw new Error("said scan belongs to another chat");
  const legacy = hasLegacySaid(db);
  const latest = () => legacy ? legacySaidReadHead(db,thread)
    : { known: true, row: db.prepare(SAID_LATEST).get(thread) as Latest | undefined };
  const state = () => db.prepare(SAID_STATE).get(thread) as State | undefined;
  const done = (): SaidStep => ({ done: true, visited: 0, scan: null });
  const drain = (): SaidStep => {
    if (mayWrite && !mayWrite()) return { done: false, visited: 0, scan };
    return { done: false, visited: legacySaidDrainThread(db,thread,limit), scan };
  };
  // A concurrent old writer may add changed keys between statements. Keep the check and the bounded read in one
  // snapshot, then recheck under the write lock before publishing a boundary.
  const snapshot = <T>(read: () => T): T => {
    db.exec("SAVEPOINT said_scan");
    try { return read(); } finally { db.exec("RELEASE said_scan"); }
  };
  if (legacy && legacySaidThreadNeedsDrain(db,thread)) return drain();
  if (scan === null) {
    const initial = snapshot(() => {
      const head = latest();
      return { head, boundary: head.row ? saidBoundary(state(),head.row) : null };
    });
    if (!initial.head.known) return drain();
    if (initial.head.row === undefined || initial.boundary?.known) return done();
    if (mayWrite && !mayWrite()) return { done: false, visited: 0, scan: null };
    db.exec("BEGIN IMMEDIATE");
    try {
      const current = latest();
      if (!current.known || (legacy && legacySaidThreadNeedsDrain(db,thread))) {
        db.exec("COMMIT"); return { done: false, visited: 0, scan: null };
      }
      if (current.row === undefined || saidBoundary(state(), current.row).known) { db.exec("COMMIT"); return done(); }
      const token = randomBytes(16).toString("hex");
      db.prepare(`INSERT INTO said_state_guard(thread,token,author,other_n,ready) VALUES (?,?,?,NULL,0)
        ON CONFLICT(thread) DO UPDATE SET token=excluded.token,author=excluded.author,other_n=NULL,ready=0`)
        .run(thread, token, current.row.author);
      db.exec("COMMIT");
      return { done: false, visited: 0, scan: { thread, token, author: current.row.author, before: current.row.n } };
    } catch (error) {
      try { db.exec("ROLLBACK"); } catch {}
      throw error;
    }
  }
  const chunk = snapshot((): { kind: "lost" } | { kind: "drain" } | { kind: "rows"; rows: Latest[] } => {
    const guard = db.prepare("SELECT token FROM said_state_guard WHERE thread=?").get(thread) as { token: string } | undefined;
    if (guard?.token !== scan!.token) return { kind: "lost" };
    if (legacy && legacySaidThreadNeedsDrain(db,thread)) return { kind: "drain" };
    return { kind: "rows", rows: scan!.found === undefined
      ? db.prepare(legacy ? LEGACY_SAID_SCAN : SAID_SCAN).all(thread,scan!.before,limit) as Latest[] : [] };
  });
  if (chunk.kind === "lost") return { done: false, visited: 0, scan: null };
  if (chunk.kind === "drain") return drain();
  let visited = 0;
  if (scan.found === undefined) {
    const rows = chunk.rows;
    visited = rows.length;
    const other = rows.find((row) => row.author_kind !== "person" || row.author !== scan!.author);
    if (other !== undefined) scan.found = { other: other.n };
    else if (rows.length < limit) scan.found = { other: null };
    else scan.before = rows.at(-1)!.n;
  }
  if (scan.found === undefined || (mayWrite && !mayWrite())) return { done: false, visited, scan };
  db.exec("BEGIN IMMEDIATE");
  try {
    const currentGuard = db.prepare("SELECT token FROM said_state_guard WHERE thread=?").get(thread) as { token: string } | undefined;
    if (currentGuard?.token !== scan.token) {
      db.exec("COMMIT");
      return { done: false, visited, scan: null };
    }
    const current = latest();
    if (!current.known || (legacy && legacySaidThreadNeedsDrain(db,thread))) {
      db.exec("COMMIT");
      return { done: false, visited, scan };
    }
    if (current.row !== undefined && (current.row.author_kind !== "person" || current.row.author !== scan.author)) {
      db.exec("COMMIT");
      return { done: false, visited, scan: null };
    }
    if (current.row === undefined) {
      db.prepare("DELETE FROM said_state_guard WHERE thread=? AND token=?").run(thread, scan.token);
    } else {
      const wrote = db.prepare("UPDATE thread_state SET said_other_n=?, said_other_known=1 WHERE thread=? AND said_n=?")
        .run(scan.found.other, thread, current.row.n).changes;
      if (wrote) db.prepare("DELETE FROM said_state_guard WHERE thread=? AND token=?").run(thread, scan.token);
      else db.prepare("UPDATE said_state_guard SET author=?, other_n=?, ready=1 WHERE thread=? AND token=?")
        .run(scan.author, scan.found.other, thread, scan.token);
    }
    db.exec("COMMIT");
    return { done: true, visited, scan: null };
  } catch (error) {
    try { db.exec("ROLLBACK"); } catch {}
    throw error;
  }
}