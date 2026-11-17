// What the Router's writes made, as the station kept it before comma_router_once (comma-stats.db's `said`), kept in
// step for a station downgraded to one that knows only this (chats.ts routerSaysOnce): one table, asked and written in
// the store's write transaction, so on the station's thread. The old unscoped indexes beside it in that file are
// neither built nor sent (workspace-index.ts).
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { wall } from "../ops/fibers.ts";
import { BUILD_DAYS, BUSY_MS } from "./stats.ts";

const DAY_MS = 24 * 60 * 60_000;

export class LegacySaid {
  readonly #db: DatabaseSync;

  /// `busyMs`: how long a statement waits for another process's write (a handover's) before it is refused.
  constructor(path: string, busyMs = BUSY_MS) {
    this.#db = new DatabaseSync(path, { timeout: busyMs });
    this.#db.exec("CREATE TABLE IF NOT EXISTS said (key TEXT PRIMARY KEY, n INTEGER NOT NULL, at INTEGER NOT NULL)");
  }

  /// The station's: `<data>/comma-stats.db`.
  static at(data: string, busyMs?: number): LegacySaid {
    return new LegacySaid(join(data, "comma-stats.db"), busyMs);
  }

  /// The message the Router's write `key` made here, if it made one: asked again, it is the same one.
  said(key: string): number | null {
    return (this.#db.prepare("SELECT n FROM said WHERE key = ?").get(key) as { n: number } | undefined)?.n ?? null;
  }

  /// Remembers what `key` made, for BUILD_DAYS (a write asked again later than that is not one Comma retries).
  remember(key: string, n: number): void {
    const now = wall.now();
    this.#db.prepare("INSERT INTO said (key, n, at) VALUES (?, ?, ?) ON CONFLICT (key) DO NOTHING").run(key, n, now);
    this.#db.prepare("DELETE FROM said WHERE at < ?").run(now - BUILD_DAYS * DAY_MS);
  }

  close(): void { this.#db.close(); }
}
