// The move drill's chats of a real station's size (e2e/move.ts, part 5), put into a stopped station's database by
// e2e/move-db.ts (insertSession, openThread, joinThread, insertMessage, matching how the station's hub makes a chat),
// each with a room of its own: a live one's a small file in its working directory, an archived one's
// its packed workspace (`workspace.tar.zst` in its room, a tar compressed with zstd, as sessions/archive.ts keeps it)
// and no working directory. What is not made: transcripts, turns, usage (a chat of these has never had its agent run).
//   node e2e/move-seed.ts <the station's checkout> <data> <home workspace> <live> <archived> <tag>
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { zstdCompressSync } from "node:zlib";
import { openMoveDb } from "./move-db.ts";

const [_src, data, ws, live, archived, tag] = process.argv.slice(2);
const store = openMoveDb(join(data!, "stillfail.db"));
const scratch = join(data!, `.seed-${tag}`);
mkdirSync(scratch, { recursive: true });
writeFileSync(join(scratch, "notes.txt"), "an archived chat's file\n");
const packed = zstdCompressSync(execFileSync("tar", ["-cf", "-", "-C", scratch, "notes.txt"]));
rmSync(scratch, { recursive: true, force: true });
const now = Date.now();
const n = Number(live) + Number(archived);
for (let i = 0; i < n; i++) {
  const key = `chat:c-${randomBytes(16).toString("hex")}`;
  const room = join(data!, "sessions", "chat", key.slice(5));
  const workspace = join(room, "workspace");
  const old = i >= Number(live);
  const at = now - (n - i) * 60_000;
  store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace, token: randomBytes(16).toString("hex"), createdAt: at, lastActiveAt: at, ws, title: `seeded ${tag} ${i}` });
  const ts = `${Math.floor(at / 1000)}.${String(i % 1000000).padStart(6, "0")}`;
  const thread = store.openThread("ember", "CHAT", ts, `seeded ${tag} ${i}`, "alice@example.test").id;
  store.joinThread(thread, key, "ember");
  for (let m = 0; m < 3; m++) store.insertMessage({ thread, ts: `${ts}${m}`, authorKind: "person", author: "alice@example.test", text: `seeded ${tag} ${i} message ${m}` });
  mkdirSync(room, { recursive: true });
  if (old) {
    writeFileSync(join(room, "workspace.tar.zst"), packed);
    store.db.prepare("UPDATE sessions SET archived_at = ?, archived_by = ? WHERE key = ?").run(at + 1000, "alice@example.test", key);
  } else {
    mkdirSync(workspace, { recursive: true });
    writeFileSync(join(workspace, "mine.txt"), `${key}\n`);
  }
}
store.close();
console.log(`SEEDED ${n} (${live} live, ${archived} archived) in ${Date.now() - now} ms`);
