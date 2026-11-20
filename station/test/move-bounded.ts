// What one item's trip costs of what a station keeps (move/, replica/handover.ts): the bytes written under a
// directory, by file, and the rows read of the stores, by table, counted while a trip goes and not while a plan does
// (a plan reads its workspace whole, once a turn; move-plan-bounded.test.ts holds it). The tests hold each kind of
// trip to the same counts with 30 and with 300 other items kept, so that what grows with them is found by a test.
// Import it before any store is opened: the rows are counted where every statement runs.
import { createRequire, syncBuiltinESMExports } from "node:module";
import { basename } from "node:path";
import { StatementSync } from "node:sqlite";

type Json = any;
const require = createRequire(import.meta.url);

const on = { files: false, rows: false };
const bytes: Record<string, number> = {};
const rows: Record<string, number> = {};
let dir = "";

{
  // (each statement's rows, to the first table its text names)
  const table = (sql: string) => /\b(?:FROM|INTO|UPDATE|JOIN)\s+([A-Za-z_][\w]*)/i.exec(sql)?.[1] ?? "?";
  for (const m of ["all", "get", "iterate"] as const) {
    const f = (StatementSync.prototype as Json)[m];
    (StatementSync.prototype as Json)[m] = function (this: StatementSync, ...args: unknown[]) {
      const r = f.apply(this, args);
      if (!on.rows) return r;
      const t = table(this.sourceSQL);
      if (m === "iterate") return (function* () { for (const x of r as Iterable<unknown>) { rows[t] = (rows[t] ?? 0) + 1; yield x; } })();
      rows[t] = (rows[t] ?? 0) + (m === "all" ? (r as unknown[]).length : r === undefined ? 0 : 1);
      return r;
    };
  }
  const fsp = require("node:fs/promises") as Record<string, Json>;
  for (const x of ["writeFile", "appendFile"]) {
    const was = fsp[x];
    fsp[x] = (path: unknown, data: unknown, ...rest: unknown[]) => {
      if (on.files && typeof path === "string" && dir !== "" && path.startsWith(dir)) {
        const name = basename(path).replace(/\.[0-9a-f]{8}\.tmp$/, "");
        // (the chats' sizes, measured in the background a plan read starts (move/sizes.ts), and the accounts known,
        // written behind the `accounts.of` a plan reads (move/station.ts): no trip's)
        if (name === "sizes.log" || name === "accounts-known.json") return was(path, data, ...rest);
        bytes[name] = (bytes[name] ?? 0) + Buffer.byteLength(typeof data === "string" ? data : String(data ?? ""));
      }
      return was(path, data, ...rest);
    };
  }
  syncBuiltinESMExports();
}

/// What a trip costs, counted from `start` to `stop`: bytes written under `under` by file, rows read by table.
export type Cost = { bytes: Record<string, number>; rows: Record<string, number> };

/// Counts from now on what is written under `under` and read of the stores, but while `plans` plan (each scheduler's
/// `plan` wrapped: what it does is not counted).
export function counting(under: string, plans: { plan: (...a: any[]) => Promise<any> }[]): { stop: () => Cost } {
  for (const k of Object.keys(bytes)) delete bytes[k];
  for (const k of Object.keys(rows)) delete rows[k];
  dir = under;
  on.files = on.rows = true;
  const kept = plans.map((s) => [s, s.plan] as const);
  for (const [s, plan] of kept) {
    s.plan = async (...args: any[]) => {
      const was = { ...on };
      on.files = on.rows = false;
      try {
        return await plan.apply(s, args);
      } finally {
        Object.assign(on, was);
      }
    };
  }
  return {
    stop: () => {
      on.files = on.rows = false;
      for (const [s, plan] of kept) s.plan = plan;
      return { bytes: { ...bytes }, rows: { ...rows } };
    },
  };
}
