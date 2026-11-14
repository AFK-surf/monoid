// The move drill's part 6b (e2e/move.ts): a chat moved A→B put back in sight on A by hand, through A's own store while A
// is stopped, so that both stations hold its key live, as the real case is (a chat brought back by hand, or a row a
// failed retirement left). `live`: its row's ws, came_from and where it was handed to, kept in `<keep>` and cleared;
// `restore`: put back as `<keep>` says. What it did, printed.
//   node e2e/move-live.ts <the station's checkout> <data> <session key> live|restore <keep file>
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const [src, data, key, mode, keep] = process.argv.slice(2);
const { Store } = await import(pathToFileURL(join(src!, "station/src/store/store.ts")).href);
const store = Store.open(join(data!, "stillfail.db"));
const db = store.db;
if (mode === "live") {
  const row = db.prepare("SELECT ws, came_from FROM sessions WHERE key = ?").get(key) as { ws: string | null; came_from: string | null } | undefined;
  if (row === undefined) throw new Error(`no session ${key} in ${data}`);
  const handed = db.prepare("SELECT * FROM handed_over WHERE session = ?").all(key);
  writeFileSync(keep!, JSON.stringify({ row, handed }));
  db.prepare("UPDATE sessions SET ws = NULL, came_from = NULL WHERE key = ?").run(key);
  db.prepare("DELETE FROM handed_over WHERE session = ?").run(key);
  console.log(`LIVE ${key}: ws ${row.ws} -> none (in sight), handed_over ${handed.length} row(s) taken out, kept in ${keep}`);
} else {
  if (!existsSync(keep!)) throw new Error(`nothing kept at ${keep}`);
  const { row, handed } = JSON.parse(readFileSync(keep!, "utf8"));
  db.prepare("UPDATE sessions SET ws = ?, came_from = ? WHERE key = ?").run(row.ws, row.came_from, key);
  for (const h of handed) {
    const cols = Object.keys(h);
    db.prepare(`INSERT OR REPLACE INTO handed_over (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`).run(...cols.map((c) => h[c]));
  }
  console.log(`RESTORED ${key}: ws ${row.ws}, handed_over ${handed.length} row(s) put back`);
}
store.close();
