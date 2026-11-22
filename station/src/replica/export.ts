// What the export is told and says (replica/AGENTS.md). The export is the MoonBit program's (station/mb src/replica,
// started by runner.ts `exportThread`); the TypeScript it is held to is the tests' (test/reference/replica-export.ts).
import type { Head, Row } from "./format.ts";

/// What the store said changed since the last pass (store/rows.ts StoreChange, gathered by module.ts).
export type Told = {
  sessions: string[];
  threads: number[];
  removedSessions: { key: string; ws: string | null }[];
  removedThreads: { id: number; ws: string | null }[];
  marks: { table: string; key: Row }[];
  transcripts?: boolean;
};
export const nothingTold = (): Told => ({ sessions: [], threads: [], removedSessions: [], removedThreads: [], marks: [] });

/// The workspaces this station is in: the home one (a session's `ws` NULL), and what the station is called in each.
export type Places = { home: string | null; workspaces: { workspace: string; name: string }[] };

/// What a pass did: each workspace's head now, whether there is more for the next, how many batches it wrote, how many
/// rows it read of stillfail.db.
export type Passed = { heads: Record<string, Head>; more: boolean; wrote: number; read: number };
