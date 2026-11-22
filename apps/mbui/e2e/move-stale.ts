// What the move drill's part 6 (e2e/move.ts) leaves on a stopped station of a chat that went back from it, by hand, as a
// failed retirement left the real target on 2026-11-14: its session row marked as the old flow marks a retired one
// (sessions/hub.ts `retiredWs`), two entries said only there after what it has of the chat's thread (the station's
// store, `insertMessage`), and its room older than the chat's own (a file only it has, one that differs, one it
// lacks). Its transcript is what the chat left there, older already. What it did, printed.
// Beside it, what the real target holds of the retirement that took that workspace's chats (replica/retire.ts): its
// `replica/taken.json` naming the retired station, `formerly.json` empty, `taking/` and `carry/<ws>/` empty.
//   node e2e/move-stale.ts <the station's checkout> <data> <session key> <workspace> <tag> <file that differs> <file it lacks> <retired station's id> <its name>
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { openMoveDb } from "./move-db.ts";

const [_src, data, key, ws, tag, differs, lacks, origin, originName] = process.argv.slice(2);
const store = openMoveDb(join(data!, "stillfail.db"));
const row = store.db.prepare("SELECT ws, workspace FROM sessions WHERE key = ?").get(key) as { ws: string | null; workspace: string } | undefined;
if (row === undefined) throw new Error(`no session ${key} in ${data}`);
store.db.prepare("UPDATE sessions SET ws = ? WHERE key = ?").run(`retired:${ws}`, key);
const thread = (store.db.prepare("SELECT thread FROM thread_sessions WHERE session = ? ORDER BY joined_at DESC LIMIT 1").get(key) as { thread: number } | undefined)?.thread;
if (thread === undefined) throw new Error(`no thread of ${key} in ${data}`);
const now = Date.now();
// (said there before the chat came back from it: just after the last entry it has, not at the time of seeding, which is
// after what A had said since)
const last = (store.db.prepare("SELECT ts FROM entries WHERE thread = ? AND ts IS NOT NULL ORDER BY n DESC LIMIT 1").get(thread) as { ts: string } | undefined)?.ts ?? `${Math.floor(now / 1000)}.000000`;
const [secs, frac = "0"] = last.split(".");
for (let i = 1; i <= 2; i++) store.insertMessage({ thread, ts: `${secs}.${String(Number(frac.padEnd(6, "0").slice(0, 6)) + i).padStart(6, "0")}`, authorKind: "person", author: "alice@example.test", text: `drill-stale only on this station ${tag} ${i}` });
mkdirSync(row.workspace, { recursive: true });
writeFileSync(join(row.workspace, "only-here.txt"), `left by a retirement ${tag}\n`);
writeFileSync(join(row.workspace, differs!), `an older copy ${tag}\n`);
rmSync(join(row.workspace, lacks!), { force: true });
store.close();
const replica = join(data!, "replica");
mkdirSync(join(replica, "taking"), { recursive: true });
mkdirSync(join(replica, "carry", ws!), { recursive: true });
writeFileSync(join(replica, "taken.json"), JSON.stringify([{ origin, name: originName, workspace: ws, at: now, chats: 0, jobs: [] }]));
writeFileSync(join(replica, "formerly.json"), "[]");
console.log(`STALE ${key}: ws ${row.ws} -> retired:${ws}, thread ${thread} +2 entries, room ${row.workspace}: only-here.txt, ${differs} older, ${lacks} gone; replica/taken.json naming ${originName} (${origin!.slice(0, 8)}), formerly.json [], taking/ and carry/${ws}/ empty`);
