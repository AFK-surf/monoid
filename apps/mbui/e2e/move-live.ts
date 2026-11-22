// The move drill's part 6b (e2e/move.ts): a chat moved A→B put back in sight on A by hand, through A's own store while A
// is stopped, so that both stations hold its key live, as the real case is (a chat brought back by hand, or a row a
// failed retirement left). `live`: its row's ws, came_from and where it was handed to, kept in `<keep>` and cleared, and
// its hand-overs out set aside beside `<keep>` (A's start marks again as gone every chat a finished hand-over out names
// whose row is in sight, replica/handover.ts `#notOff` and `start`: drill 21's seed was undone by it); `restore`: all
// put back as `<keep>` says. What it did, printed.
//   node e2e/move-live.ts <the station's checkout> <data> <session key> live|restore <keep file>
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { openMoveDb } from "./move-db.ts";

const [_src, data, key, mode, keep] = process.argv.slice(2);
const store = openMoveDb(join(data!, "stillfail.db"));
const db = store.db;
if (mode === "live") {
  const row = db.prepare("SELECT ws, came_from FROM sessions WHERE key = ?").get(key) as { ws: string | null; came_from: string | null } | undefined;
  if (row === undefined) throw new Error(`no session ${key} in ${data}`);
  const handed = db.prepare("SELECT * FROM handed_over WHERE session = ?").all(key);
  writeFileSync(keep!, JSON.stringify({ row, handed }));
  const out = join(data!, "replica", "handover", "out");
  const aside = `${keep}.out`;
  mkdirSync(aside, { recursive: true });
  let moved = 0;
  for (const f of existsSync(out) ? readdirSync(out) : []) {
    if (!f.endsWith(".json")) continue;
    try {
      if (!(JSON.parse(readFileSync(join(out, f), "utf8")).keys ?? []).includes(key)) continue;
    } catch {
      continue;
    }
    renameSync(join(out, f), join(aside, f));
    moved++;
  }
  console.log(`  ${moved} hand-over(s) out of it set aside in ${aside}`);
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
  const aside = `${keep}.out`;
  const out = join(data!, "replica", "handover", "out");
  let back = 0;
  for (const f of existsSync(aside) ? readdirSync(aside) : []) (renameSync(join(aside, f), join(out, f)), back++);
  console.log(`RESTORED ${key}: ws ${row.ws}, handed_over ${handed.length} row(s) put back, ${back} hand-over(s) out put back`);
}
store.close();
