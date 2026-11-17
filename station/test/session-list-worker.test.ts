import assert from "node:assert/strict";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { SessionListBuilder } from "../src/read/session-list-builder.ts";
import { installSessionListIndex, sessionListReady } from "../src/store/session-list-index.ts";
import { Store } from "../src/store/store.ts";
import { endsOnce } from "./programs.ts";

test("a stopped session list worker retries and resumes its pending index", async () => {
  const dir = mkdtempSync(join(tmpdir(), "session-list-worker-")), path = join(dir, "station.db"), store = Store.open(path), db = store.db;
  const file = join(dir, "worker.mjs"), marker = join(dir, "exited");
  try {
    for (const row of db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'session_list_%'").all() as { name: string }[])
      db.exec(`DROP TRIGGER ${row.name}`);
    db.exec("DROP TABLE session_list_rows; DROP TABLE session_list_replaced; DROP TABLE session_list_meta");
    for (let i = 0; i < 3; i++) store.insertSession({ key: `old-${i}`, connect: "ember", runtime: "claude", profile: "cc",
      workspace: "/work", token: `old-${i}`, createdAt: i, lastActiveAt: i, ws: "mine" });
    installSessionListIndex(db);
    endsOnce(file, marker);
    const builder = new SessionListBuilder(path, {}, file);
    try {
      await builder.readyIndex();
      assert.ok(existsSync(marker));
      assert.equal(sessionListReady(db), true);
      assert.equal(db.prepare("SELECT COUNT(*) AS n FROM session_list_rows").get()!.n, 3);
    } finally { await builder.close(); }
  } finally { store.close(); rmSync(dir, { recursive: true, force: true }); }
});
