// The MoonBit station (`stillfail-reader run`, no Node on its PATH) through what the TypeScript's own copy tests hold
// (replica-stations, replica-export, sending-pack), two real stations over real loopback iroh each: a station's chats
// copied to the other as it keeps them (their rows and attached files, a copy a fresh station takes back as they were),
// the keeper stopped while chats change, a chat is made and one deleted, and once it is back the copy caught up by its
// coming back alone (the deleted chat and its file gone from it too). Its retirement and whole-station move are
// mb-fault-replica-retire-move.test.ts, a hand-over's faults mb-fault-replica-retire-faults.test.ts (split so each
// runs in a slice of its own). Under scripts/native.ts run (mesh runner archive-rs reader launcher).
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { Store } from "../src/store/store.ts";
import { setupRetireHarness, binary, skip, fresh, given, readJson, sha, binOf, http, rows, pair, texts, chat, attach } from "./mb-fault-replica-retire-harness.ts";

setupRetireHarness();

// ── 1. a station's copies: kept by the other, caught up after it was away, a deleted chat gone from them ──

/// The newest generation of `origin`'s copy kept at `data` (`replicas/w1/<origin>/<gen>/head.json`), or of the
/// station's own (`replica/own/w1/<gen>`).
function newestHead(dir: string): { gen: string; dir: string; head: any } | null {
  if (!existsSync(dir)) return null;
  let best: { gen: string; dir: string; head: any } | null = null;
  for (const gen of readdirSync(dir)) {
    const head = readJson(join(dir, gen, "head.json"));
    if (head === null || typeof head.gen !== "string") continue;
    if (best === null || (head.made ?? 0) > (best.head.made ?? 0) || ((head.made ?? 0) === (best.head.made ?? 0) && head.to > best.head.to)) best = { gen, dir: join(dir, gen), head };
  }
  return best;
}

/// What a fresh station takes back of `origin`'s copy kept at `keeper` (`--builder replica-restore`, as a new station
/// restores a lost one before its store opens): its database's sessions and their messages, and the attached files
/// where its messages say. The keeper goes on writing while it is read (a newer head put, batches folded, files
/// dropped): the head is read once and only what it names is taken, and null is answered when that is gone already
/// (a newer head took its place; asked again, it is taken).
function restoreFrom(keeper: string, origin: string, name: string, from: string, bin: string) {
  const kept = join(keeper, "replicas", "w1", origin);
  const newest = newestHead(kept);
  assert.ok(newest !== null, `no copy of ${origin} kept at ${keeper}`);
  let headRaw: string;
  const taken = new Map<string, Buffer>();
  try {
    headRaw = readFileSync(join(newest.dir, "head.json"), "utf8");
    const head = JSON.parse(headRaw);
    for (const b of head.batches as string[]) taken.set(join(newest.gen, "log", b), readFileSync(join(newest.dir, "log", b)));
    for (const h of [...Object.keys(head.files ?? {}), ...Object.keys(head.transcriptFiles ?? {})]) taken.set(join("files", h), readFileSync(join(kept, "files", h)));
    newest.head = head;
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT" || e instanceof SyntaxError) return null;
    throw e;
  }
  const to = fresh("restore");
  const copy = join(to, "restore", "copy");
  mkdirSync(join(copy, newest.gen, "log"), { recursive: true });
  mkdirSync(join(copy, "files"), { recursive: true });
  writeFileSync(join(copy, newest.gen, "head.json"), headRaw);
  for (const [p, bytes] of taken) writeFileSync(join(copy, p), bytes);
  writeFileSync(join(to, "restore", "ready.json"), JSON.stringify({ origin, workspace: "w1", gen: newest.gen, name, from }));
  Store.open(join(to, "stillfail.db"), join(to, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never).close();
  const r = spawnSync(binary!, ["--builder", "replica-restore", "--db", join(to, "stillfail.db"), "--data", to, "--now", "1000", "--sep", "/"], { encoding: "utf8", env: { PATH: bin, HOME: to, TMPDIR: tmpdir() } });
  assert.equal(r.status, 0, r.stderr);
  const said = JSON.parse(r.stdout.trim().split("\n").at(-1)!);
  assert.equal(said.error, undefined, JSON.stringify(said));
  assert.equal(said.ready?.origin, origin, JSON.stringify(said));
  const sessions = rows<{ key: string }>(to, "SELECT key FROM sessions ORDER BY key").map((x) => x.key);
  const said_ = (key: string) => rows<{ text: string }>(to, "SELECT e.text AS text FROM entries e JOIN thread_sessions t ON t.thread = e.thread WHERE t.session = ? AND e.kind = 'message' ORDER BY e.n", key).map((x) => x.text);
  const files = rows<{ attachments: string }>(to, "SELECT attachments FROM entries WHERE attachments IS NOT NULL AND attachments != '[]'")
    .flatMap((x) => JSON.parse(x.attachments) as { path: string; name: string }[])
    .map((f) => ({ name: f.name, path: f.path, sha: existsSync(f.path) ? sha(readFileSync(f.path)) : null }));
  return { to, gen: newest.gen, head: newest.head, sessions, said: said_, files };
}

test("a station's chats copied to the other as it keeps them, their files with them; the keeper away while a chat is said to, one made and one deleted; back, its copy caught up by its coming back alone, the deleted chat and its file gone from it", { skip, timeout: 240_000 }, async () => {
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-copies-test" }, models: ["claude-opus-5-5"] }];
  const config = { language: "en", updateChannel: "beta", profiles, maxNudges: 0 };
  const { a, b, stations, start, store } = await pair(["alpha", "beta"], [config, config]);
  let [alpha, beta] = stations;
  const both = () => `alpha: ${alpha.err()}\nbeta: ${beta.err()}`;
  const storeA = store(a.data);
  const kept = join(b.data, "replicas", "w1", a.id);
  const own = join(a.data, "replica", "own", "w1");
  const bin = binOf("restore");

  // three chats on alpha, two with a file sent in them
  const one = await chat(alpha.door, storeA, "cc", "the first chat, on alpha", both);
  const two = await chat(alpha.door, storeA, "cc", "the second chat, on alpha", both);
  const gone = await chat(alpha.door, storeA, "cc", "the chat to be deleted", both);
  const oneFile = randomBytes(40_000);
  const goneFile = Buffer.from("the deleted chat's file, nothing else has these bytes\n");
  const oneSha = await attach(alpha.door, one.thread, "plan.bin", oneFile, "the first chat's file");
  const goneSha = await attach(alpha.door, gone.thread, "gone.txt", goneFile, "the deleted chat's file");

  // (each message sent with a file is a turn of its chat: both answered, every chat idle, before what alpha says is read)
  const ended = (key: string) => storeA.listTurns(key).filter((t) => t.summary.endedAt != null).length;
  await given("the turns on the files sent ended", () => ended(one.key) >= 2 && ended(gone.key) >= 2, both);
  const wantBefore = new Map<string, string[]>();
  for (const c of [one, two, gone]) wantBefore.set(c.key, await texts(alpha.door, c.thread));

  // ── kept on beta: a head naming the three chats and both files, what a fresh station takes back of it the chats as
  // they are on alpha (each head taken back once) ──
  const tried = new Map<string, NonNullable<ReturnType<typeof restoreFrom>>>();
  const first = await given("alpha's copy kept on beta with its three chats as they are, and both files", () => {
    const h = newestHead(kept);
    if (h === null || h.head.chats !== 3 || !(oneSha in h.head.files) || !(goneSha in h.head.files) || !existsSync(join(kept, "files", oneSha)) || !existsSync(join(kept, "files", goneSha))) return null;
    const at = `${h.gen}:${h.head.to}`;
    if (!tried.has(at)) {
      const r = restoreFrom(b.data, a.id, "alpha", b.id, bin);
      if (r === null) return null;
      tried.set(at, r);
    }
    const r = tried.get(at)!;
    return [one, two, gone].every((c) => JSON.stringify(r.said(c.key)) === JSON.stringify(wantBefore.get(c.key))) ? { ...h, restored: r } : null;
  }, () => `kept=${JSON.stringify(newestHead(kept)?.head)}; ${both()}`, 60_000);
  assert.deepEqual(readFileSync(join(kept, "files", oneSha)), oneFile);
  assert.deepEqual(readFileSync(join(kept, "files", goneSha)), goneFile);
  // what a fresh station takes back of it is the chats as they were on alpha, their files where their messages say
  const before = first.restored;
  assert.deepEqual(before.sessions, [one.key, two.key, gone.key].sort());
  for (const c of [one, two, gone]) assert.deepEqual(before.said(c.key), await texts(alpha.door, c.thread), c.key);
  assert.deepEqual(before.files.map((f) => [f.name, f.sha]).sort(), [["gone.txt", goneSha], ["plan.bin", oneSha]]);
  for (const f of before.files) assert.ok(f.path.startsWith(before.to), `${f.path} under the restored station`);

  // ── beta away: alpha's chats change meanwhile (said to, one made, one deleted with its file), its own copy goes on ──
  await beta.stop();
  const keptAtStop = newestHead(kept)!;
  const ownBefore = newestHead(own)!;
  const turnsBefore = ended(one.key);
  const sent = await http(alpha.door, `/admin-api/threads/${one.thread}/messages`, { body: { text: "said while beta was away" } });
  assert.ok(sent.status < 300, sent.text);
  await given("the first chat's turn on it ended", () => ended(one.key) >= turnsBefore + 1, both);
  const three = await chat(alpha.door, storeA, "cc", "a chat made while beta was away", both);
  const deleted = await http(alpha.door, `/admin-api/sessions/${encodeURIComponent(gone.key)}`, { method: "DELETE" });
  assert.ok(deleted.status < 300, deleted.text);
  await given("the chat deleted on alpha", () => rows(a.data, "SELECT key FROM sessions WHERE key = ?", gone.key).length === 0, both);
  const ownAfter = await given("alpha's own copy past what beta holds: three chats, the deleted one's file not in it", () => {
    const h = newestHead(own);
    return h !== null && h.head.chats === 3 && !(goneSha in h.head.files) && oneSha in h.head.files && (h.gen !== ownBefore.gen || h.head.to > ownBefore.head.to) ? h : null;
  }, () => `own=${JSON.stringify(newestHead(own)?.head)}; ${alpha.err()}`, 60_000);
  // nothing reached beta while it was away: its copy as it was
  assert.deepEqual(newestHead(kept)!.head, keptAtStop.head);
  assert.ok(existsSync(join(kept, "files", goneSha)));

  // ── beta back: told by nobody but its coming back, its copy level with alpha's own, the deleted file gone ──
  beta = await start(1);
  const caught = await given("beta's copy caught up with alpha's own", () => {
    const h = newestHead(kept);
    return h !== null && h.gen === ownAfter.gen && h.head.to >= ownAfter.head.to && !existsSync(join(kept, "files", goneSha)) ? h : null;
  }, () => `kept=${JSON.stringify(newestHead(kept)?.head)}; own=${JSON.stringify(newestHead(own)?.head)}; files=${JSON.stringify(existsSync(join(kept, "files")) ? readdirSync(join(kept, "files")) : [])}; ${both()}`, 60_000);
  assert.equal(caught.head.chats, 3);
  assert.deepEqual(Object.keys(caught.head.files), [oneSha]);
  assert.deepEqual(readFileSync(join(kept, "files", oneSha)), oneFile);
  const now = await given("beta's copy taken back whole", () => restoreFrom(b.data, a.id, "alpha", b.id, bin), both);
  assert.deepEqual(now.sessions, [one.key, two.key, three.key].sort(), "the deleted chat not in what is taken back, the one made is");
  for (const c of [one, two, three]) assert.deepEqual(now.said(c.key), await texts(alpha.door, c.thread), c.key);
  assert.ok(now.said(one.key).includes("said while beta was away"), JSON.stringify(now.said(one.key)));
  assert.deepEqual(now.files.map((f) => [f.name, f.sha]), [["plan.bin", oneSha]], "the deleted chat's file not in it");
  assert.equal(rows(now.to, "SELECT key FROM sessions WHERE key = ?", gone.key).length, 0);
  await Promise.all([alpha.stop(), beta.stop()]);
});
