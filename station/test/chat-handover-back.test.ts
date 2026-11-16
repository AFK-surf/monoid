// A chat handed over and back (replica/handover.ts, move/): what was said on each side is in its log once and in order, a
// hand-back is a mirror by difference, a retired copy there is taken up, a start at rest changes nothing, the records of
// its trips are ended and bounded, its transcript is carried, a key live there keeps it here. Split from
// chat-handover.test.ts by subject; its stations are move-world.ts's.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, renameSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { newSession, say } from "../src/sessions/lifecycle.ts";
import { moveView } from "../src/move/routes.ts";
import { tell } from "../src/replica/copies.ts";
import { given, message, reply } from "./hub-fakes.ts";
import { claudeProject } from "../src/read/transcript.ts";
import { Readers } from "../src/read/pool.ts";
import { RETRY_MS } from "../src/replica/retire.ts";
import { transcriptAt } from "../src/agents/claude.ts";
import { WS, A, B, type Station, world, endTurn, stillfailChat, filesOf, entries, homeThread, retiredCopy, startedAgainChangesNothing } from "./move-world.ts";

type Json = any;

test("handed over, then back: what was said there is in its log here once, in order; it goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = homeThread(b, key);
  say(b.rig.hub, there, "p@x", "said there");
  await w.quiet();
  await b.rig.call(key, "chat_post", { to: `CHAT/${b.rig.store.getThread(there)!.threadTs}`, text: "answered there" });
  await endTurn(b, key);
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(b.rig.store.handedTo(key)?.station, A);
  assert.deepEqual(entries(a, thread), entries(b, there), "the same log, once");
  assert.ok(entries(a, thread).includes("person:said there"));
  assert.equal(entries(a, thread).filter((e) => e === "person:said there").length, 1);
  assert.equal(a.rig.session(key).ws, null);
  assert.equal(a.rig.session(key).profile, "cc");
  say(a.rig.hub, thread, "p@x", "home again");
  await w.quiet();
  assert.equal(a.rig.claude.last().options.resume, "claude-1");
});

test("a message sent while the chat is held is delivered once, there: answered there, it is not handed to its agent again as the chat comes back, and what is said after is handed alone", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  a.onFail = (step) => {
    if (step === "held") say(a.rig.hub, thread, "p@x", "while it moves");
  };
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  a.onFail = null;
  assert.equal(a.rig.claude.count(), 1, "not taken here");
  const prompts = b.rig.claude.sessions.flatMap((s) => s.prompts).join("\n");
  assert.equal(prompts.split("while it moves").length - 1, 1, prompts);
  await endTurn(b, key);
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  const before = a.rig.claude.sessions.flatMap((s) => s.prompts).length;
  say(a.rig.hub, thread, "p@x", "home again");
  await w.quiet();
  const handed = a.rig.claude.sessions.flatMap((s) => s.prompts).slice(before).join("\n");
  assert.match(handed, /home again/, "the new one handed");
  assert.doesNotMatch(handed, /while it moves/, "the one answered there not handed again");
});

test("a hand-back is a mirror by difference: what changed there is sent, what went there is removed here, nothing else sent", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  const room = a.rig.session(key).workspace;
  writeFileSync(join(room, "stays.txt"), "the same both ways");
  writeFileSync(join(room, "goes.txt"), "deleted there");
  writeFileSync(join(room, "edited.txt"), "before");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const there = b.rig.session(key).workspace;
  writeFileSync(join(there, "edited.txt"), "after, edited there");
  utimesSync(join(there, "edited.txt"), 1_700_000_000, 1_700_000_000);
  rmSync(join(there, "goes.txt"));
  writeFileSync(join(there, "added.txt"), "added there");
  // (a file of the chat's here outside its room, which the lists there do not name: no prune touches it)
  const transcript = join(a.rig.dir, "transcripts", "claude", claudeProject(room)!, "claude-1.jsonl");
  mkdirSync(join(transcript, ".."), { recursive: true });
  writeFileSync(transcript, '{"type":"user"}\n');
  const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.deepEqual(filesOf(room), filesOf(there), "the room here is the one there");
  assert.ok(existsSync(transcript), "what is outside its room stays");
  const out = b.moves.handover.outs()[0]!;
  assert.equal(out.sentBytes, Buffer.byteLength("after, edited there") + Buffer.byteLength("added there"), "only what changed was sent");
});

test("entries with no ts on a hand-back are neither doubled nor lost", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const t = a.rig.store.getThread(thread)!;
  const first = a.rig.store.entriesAfter(thread, 0).find((e) => e.kind === "message" && e.ts !== null)!;
  a.rig.store.editMessage(t.surface, t.channel, t.threadTs, first.ts!, "edited here");
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const tb = b.rig.store.getThread(homeThread(b, key))!;
  b.rig.store.editMessage(tb.surface, tb.channel, tb.threadTs, first.ts!, "edited there");
  await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
  await w.quiet();
  const edits = a.rig.store.entriesAfter(thread, 0).filter((e) => e.kind === "edit").map((e) => e.text);
  assert.deepEqual(edits, ["edited here", "edited there"]);
  assert.deepEqual(entries(a, thread), entries(b, tb.id));
});

test("a hand-back keeps by number what its log here already has: a letter written there under a ts the log has (another machine's clock) is put in, not taken for that one", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const letter = (st: Station, t: number, text: string) => st.rig.store.insertLetter({ thread: t, ts: "1700000000.000100", authorKind: "agent", author: key, text, letter: { way: "out", title: "another chat", link: null } });
  const letters = (st: Station, t: number) => (st.rig.store.db.prepare("SELECT n, ts, text FROM letters WHERE thread = ? ORDER BY n").all(t) as { n: number; ts: string; text: string }[]).map((r) => `${r.n} ${r.ts} ${r.text}`);
  letter(a, thread, "written here");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const there = homeThread(b, key);
  letter(b, there, "written there");
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.deepEqual(letters(a, thread), ["1 1700000000.000100 written here", "2 1700000000.000100 written there"]);
  assert.deepEqual(letters(a, thread), letters(b, there));
});

test("two still.fail chats of the same ts, one here and one there: handed over, each stays its own", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const [other, ot] = await newSession(b.rig.hub, { runtime: "claude", profile: "ccb", createdBy: "q@x" });
  say(b.rig.hub, ot.id, "q@x", "b's own chat");
  await endTurn(b, other);
  // (the same ts as A's chat: each station mints its own)
  b.rig.store.db.prepare("UPDATE threads SET thread_ts = ?, channel = ? WHERE id = ?").run(a.rig.store.getThread(thread)!.threadTs, a.rig.store.getThread(thread)!.channel, ot.id);
  const before = entries(b, ot.id);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  const moved = homeThread(b, key);
  assert.notEqual(moved, ot.id, "a thread of its own");
  assert.deepEqual(entries(b, ot.id), before, "b's own chat untouched");
  assert.deepEqual(entries(b, moved), entries(a, thread));
});

/// The files of a room, by name, with their words.
const roomOf = (dir: string) => Object.fromEntries(readdirSync(dir).filter((n) => statSync(join(dir, n)).isFile()).sort().map((n) => [n, readFileSync(join(dir, n), "utf8")]));

/// An edit of message `target` with no ts, as the store writes one (store.ts #editMessage).
function edit(st: Station, thread: number, target: number, text: string) {
  const n = ((st.rig.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(thread) as { n: number }).n ?? 0) + 1;
  st.rig.store.db.prepare("INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, at) VALUES (?, ?, 'edit', ?, NULL, 'person', 'p@x', ?, ?)").run(thread, n, target, text, 1_000 + n);
}
const edits = (st: Station, thread: number) => (st.rig.store.db.prepare("SELECT text FROM entries WHERE thread = ? AND kind = 'edit' ORDER BY n").all(thread) as { text: string }[]).map((r) => r.text);

test("a chat handed forth, back and forth again, its log with entries of no ts (edits), something said on each side between: every entry once on both", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const n = (st: Station, t: number, text: string) => (st.rig.store.db.prepare("SELECT n FROM entries WHERE thread = ? AND text = ? AND kind = 'message'").get(t, text) as { n: number }).n;
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const there = homeThread(b, key);
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  // (its copy there left with something of its own since: the logs are not one any more, so they are matched by ts)
  b.rig.store.db.prepare("INSERT INTO entries (thread, n, kind, ts, author_kind, author, text, at) VALUES (?, ?, 'message', '9999.000001', 'person', 'p@x', 'late there', 1)")
    .run(there, ((b.rig.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(there) as { n: number }).n ?? 0) + 1);
  say(a.rig.hub, thread, "p@x", "said here");
  await w.quiet();
  await endTurn(a, key);
  edit(a, thread, n(a, thread, "said here"), "edited here");
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  say(b.rig.hub, there, "p@x", "said there");
  await w.quiet();
  await endTurn(b, key);
  edit(b, there, n(b, there, "said there"), "edited there");
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  for (const [st, t] of [[a, thread], [b, there]] as const) {
    assert.deepEqual(edits(st, t), ["edited here", "edited there"], `edits on ${st.id.slice(0, 1)}`);
    const said = entries(st, t);
    for (const x of ["person:look at the build", "person:said here", "person:said there", "person:late there"]) assert.equal(said.filter((e) => e === x).length, 1, `${x} on ${st.id.slice(0, 1)}: ${said.join(" | ")}`);
  }
});

test("a station holding a retired copy of the chat (older log, same thread keys, its files in place): handed over, shown once with the whole log, no entry twice, its files A's; a failed hand-over leaves the copy as it was", async () => {
  for (const failing of [true, false]) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key, thread } = await stillfailChat(a);
    const room = a.rig.session(key).workspace;
    writeFileSync(join(room, "kept.md"), "the same on both");
    writeFileSync(join(room, "gone.md"), "removed here since");
    retiredCopy(a, b, key);
    const copy = b.rig.store.getSession(key)!;
    assert.equal(copy.ws, `retired:${WS}`);
    const there = homeThread(b, key);
    const copied = entries(b, there);
    // Since: more said here, a file changed, one removed.
    say(a.rig.hub, thread, "p@x", "after the retirement");
    await w.quiet();
    await endTurn(a, key);
    writeFileSync(join(room, "notes.md"), "what I am doing now");
    rmSync(join(room, "gone.md"));
    const roomThere = b.rig.session(key).workspace;
    const filesBefore = roomOf(roomThere);
    if (failing) a.fails.add("counts");
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    if (failing) {
      assert.ok((out.failed?.error ?? "").includes(tr(stationLang(), "station.move.why.failedHere")) && !(out.failed?.error ?? "").includes("the test failed"), `in the station's words, the error the log's: ${out.failed?.error}`);
      assert.equal(b.rig.store.getSession(key)!.ws, `retired:${WS}`, "the copy as it was");
      assert.deepEqual(entries(b, there), copied);
      assert.deepEqual(roomOf(roomThere), filesBefore, "its files as they were");
      assert.equal(a.rig.store.handedTo(key), null);
      continue;
    }
    assert.equal(out.failed, null, JSON.stringify(out));
    assert.equal(homeThread(b, key), there, "the same thread");
    assert.equal(b.rig.session(key).ws, null, "shown");
    assert.deepEqual(entries(b, there), entries(a, thread), "the whole log, once");
    assert.deepEqual(roomOf(b.rig.session(key).workspace), roomOf(room), "its files A's");
    const o = a.moves.handover.outOf(key)!;
    assert.equal(o.sentBytes, "what I am doing now".length, "what was in place not sent again");
  }
});

test("what a retirement left of a chat there (its rows retired, a log with entries only it has, a room that differs both ways, an older transcript) is taken over as an older copy: moved there and back three times, shown once, every entry once on each side (what only it had kept, after or before A's later ones as each log has them; nothing renumbered), what hangs on a number pointing at the same entry, no row added by a trip; the room and transcript A's, its runtime session taken up; never a chat of its own there", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  const old = await stillfailChat(a);
  a.rig.store.setArchived(old.key, true, "manual");
  const room = a.rig.session(key).workspace;
  writeFileSync(join(room, "same.md"), "the same on both");
  writeFileSync(join(room, "differs.md"), "A's words");
  writeFileSync(join(room, "missing.md"), "only A has it");
  const transcript = (st: Station) => join(st.rig.dir, "transcripts", "claude", claudeProject(realpathSync(st.rig.session(key).workspace))!, "claude-1.jsonl");
  mkdirSync(dirname(transcript(a)), { recursive: true });
  writeFileSync(transcript(a), '{"type":"user","said":"before"}\n');
  retiredCopy(a, b, key);
  retiredCopy(a, b, old.key);
  const there = homeThread(b, key);
  const copied = entries(b, there);
  // There, after the retirement and before it was taken back by hand: something said, its room refilled by hand.
  // (one older than what A said since, one newer: each log's order of them is its own, every entry once)
  b.rig.store.insertMessage({ thread: there, ts: b.rig.hub.nextTs(), authorKind: "person", author: "p@x", text: "said only there" });
  const roomThere = b.rig.session(key).workspace;
  writeFileSync(join(roomThere, "stale.md"), "only there");
  writeFileSync(join(roomThere, "differs.md"), "B's older words");
  utimesSync(join(roomThere, "differs.md"), new Date(1_000_000), new Date(1_000_000));
  rmSync(join(roomThere, "missing.md"));
  mkdirSync(dirname(transcript(b)), { recursive: true });
  writeFileSync(transcript(b), '{"type":"user"}\n');
  // Here, after it was taken back: more said, the transcript grown.
  say(a.rig.hub, thread, "p@x", "said here after the return");
  await w.quiet();
  await endTurn(a, key);
  b.rig.store.insertMessage({ thread: there, ts: b.rig.hub.nextTs(), authorKind: "person", author: "p@x", text: "said only there, later" });
  // (a viewer's read mark, a reply's target: each by a number, through the collision)
  const lastHere = a.rig.store.db.prepare("SELECT MAX(n) AS n FROM entries WHERE thread = ?").get(thread) as { n: number };
  a.rig.store.db.prepare("INSERT OR REPLACE INTO reads (viewer, thread, n, at) VALUES ('p@x', ?, ?, 0)").run(thread, lastHere.n);
  writeFileSync(transcript(a), '{"type":"user","said":"before"}\n{"type":"user","said":"after"}\n');
  // B's plan and its page never take the leftover for a chat of its own: nothing of it to move from B.
  assert.deepEqual((await b.moves.scheduler.plan(WS, A)).items.filter((x) => x.module === "chats"), [], "not B's own");
  const view = await b.ask("GET", "/move", null, "owner", [["to", A]]);
  assert.equal(view.body.modules.find((m: Json) => m.id === "chats").total, 0);
  // Moved there: taken over as an older copy of the same chat.
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  const out2 = await a.moves.scheduler.move(WS, B, { module: "chats", item: old.key });
  await w.quiet();
  assert.equal(out.failed, null, JSON.stringify(out));
  assert.equal(out2.failed, null, JSON.stringify(out2));
  assert.equal(homeThread(b, key), there, "the same thread there");
  assert.equal(b.rig.session(key).ws, null, "shown under the workspace");
  assert.equal(b.rig.session(old.key).ws, null);
  assert.notEqual(b.rig.session(old.key).archivedAt, null, "archived as it was");
  assert.deepEqual(entries(b, homeThread(b, old.key)), entries(a, old.thread));
  const once = (xs: string[]) => [...xs].sort();
  const whole = once([...entries(a, thread), "person:said only there", "person:said only there, later"]);
  assert.deepEqual(once(entries(b, there)), whole, "every entry once there: A's and what only it had");
  assert.deepEqual(entries(b, there).slice(0, copied.length), copied, "nothing renumbered there");
  const markThere = b.rig.store.db.prepare("SELECT n FROM reads WHERE viewer = 'p@x' AND thread = ?").get(there) as { n: number } | undefined;
  const textAt = (st: Station, t: number, n: number) => (st.rig.store.db.prepare("SELECT kind || ':' || author || ':' || COALESCE(ts, '') || ':' || COALESCE(text, '') AS text FROM entries WHERE thread = ? AND n = ?").get(t, n) as { text: string } | undefined)?.text;
  assert.equal(textAt(b, there, markThere!.n), textAt(a, thread, lastHere.n), "the read mark at the same entry there");
  assert.deepEqual(roomOf(roomThere), roomOf(room), "the room A's: the stale file gone, the differing one A's, the missing one there");
  assert.equal(readFileSync(transcript(b), "utf8"), readFileSync(transcript(a), "utf8"), "the transcript A's");
  // A device's reads of its page there, by the station's readers as it serves them: the session, its place in the
  // list, its thread.
  const viewer = { sub: "u", email: "p@x", name: "P", role: "owner", workspace: WS, device: "d", home: true } as Json;
  const readers = new Readers(b.rig.dir, 1);
  try {
    const page = JSON.parse(await readers.read("session", { key, viewer, lang: "en", turns: null, jobs: null }, "en"));
    assert.equal(page.session?.key, key, "its page there");
    const list = JSON.parse(await readers.read("sessions", { connect: null, archived: false, lang: "en", viewer }, "en"));
    assert.ok((Array.isArray(list) ? list : list.sessions ?? []).some((x: Json) => x.key === key), "in the list there");
    const view = JSON.parse(await readers.read("thread", { id: String(there), viewer, lang: "en" }, "en"));
    assert.ok(view !== null, "its thread there");
  } finally {
    await readers.close();
  }
  say(b.rig.hub, there, "p@x", "and now?");
  await w.quiet();
  assert.equal(b.rig.claude.last().options.resume, "claude-1", "its runtime session taken up");
  await endTurn(b, key);
  // And back, and forth and back twice more: each log keeps its numbers, no row added by a trip.
  const rows = (st: Station, t: number) => (st.rig.store.db.prepare("SELECT COUNT(*) AS n FROM entries WHERE thread = ?").get(t) as { n: number }).n;
  let counts: [number, number] | null = null;
  for (let trip = 0; trip < 3; trip++) {
    const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(back.failed, null, JSON.stringify(back));
    assert.equal(a.rig.session(key).ws, null);
    assert.equal(a.rig.store.handedTo(key), null);
    assert.deepEqual(once(entries(a, thread)), once(entries(b, there)), `the same entries here as there, each once (trip ${trip})`);
    assert.deepEqual(roomOf(room), roomOf(roomThere));
    const now: [number, number] = [rows(a, thread), rows(b, there)];
    if (counts !== null) assert.deepEqual(now, counts, `no row added by trip ${trip}`);
    counts = now;
    if (trip === 2) break;
    const forth = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(forth.failed, null, JSON.stringify(forth));
  }
});

test("a start at rest changes nothing of a chat that moved: there; there and back; there, back and there; over a retired copy; a hand-over that failed", async () => {
  for (const how of ["there", "there and back", "there, back and there", "over a retired copy", "failed"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    if (how === "over a retired copy") retiredCopy(a, b, key);
    if (how === "failed") a.fails.add("counts");
    const forth = () => a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    const back = () => a.moves.scheduler.back(WS, B, { module: "chats", item: key });
    await forth();
    await w.quiet();
    if (how === "there and back" || how === "there, back and there") {
      assert.equal((await back()).failed, null, how);
      await w.quiet();
    }
    if (how === "there, back and there") {
      assert.equal((await forth()).failed, null, how);
      await w.quiet();
    }
    await startedAgainChangesNothing(w, key, how);
    // (and moved on after: back from there where it is there, forth from here where it is here)
    const here = a.rig.store.handedTo(key) === null;
    const next = here ? await forth() : await back();
    await w.quiet();
    assert.equal(next.failed, null, `${how}: its next move succeeds: ${JSON.stringify(next)}`);
  }
});

test("a chat that came back ends every record here of its trips before: none of them asks anything of the station it went to after, nor says it is there, however it stood (one whose last telling there failed), across starts; a record of it cut at gone is not replayed over it", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  // There, the telling after its show failing once (a message taken as it was shown, sent after it, refused): its
  // record here stays at gone, its telling owed.
  let shows = 0;
  w.tamper((to, r) => {
    if (to !== B || r.method !== "handover.show") return r;
    shows++;
    if (shows === 1) say(a.rig.hub, thread, "p@x", "said as it was shown");
    if (shows === 2) throw new Error("not this time");
    return r;
  });
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  const first = a.moves.handover.outOf(key)!;
  assert.equal(first.step, "gone", "its telling owed");
  // Back before that telling is tried again.
  w.tamper((to, r) => r);
  assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  // Here again: in a turn, something said that waits for it to end (not given to the turn under way).
  say(a.rig.hub, thread, "p@x", "home again");
  await w.quiet();
  a.rig.claude.sessions.filter((x) => x.options.key === key).at(-1)!.unsteerable = true;
  say(a.rig.hub, thread, "p@x", "while it works");
  await w.quiet();
  const asked: string[] = [];
  w.tamper((to, r) => {
    if (r.id === first.id) asked.push(`${to.slice(0, 1)} ${r.method}`);
    return r;
  });
  await w.t.adjust(RETRY_MS * 8);
  await w.quiet();
  assert.deepEqual(asked, [], "the trip before asks nothing more");
  await endTurn(a, key);
  await w.quiet();
  assert.ok(a.rig.claude.sessions.filter((x) => x.options.key === key).flatMap((x) => x.prompts).join("\n").includes("while it works"), "what waited here is handed to its agent here: nothing of the trip before marked it handed");
  assert.deepEqual(a.moves.handover.outs().filter((o) => o.keys.includes(key)).map((o) => o.step), ["done"], "its record here ended");
  assert.equal((await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === key)?.state, "here");
  await startedAgainChangesNothing(w, key, "back before its telling");
  // A record of it as a station from before this kept one, cut at gone: not replayed over the chat that came back
  // since, nor told again.
  const file = join(a.rig.dir, "replica", "handover", "out", `${first.id}.json`);
  const kept = JSON.parse(readFileSync(file, "utf8"));
  delete kept.v;
  delete kept.ended;
  kept.step = "gone";
  writeFileSync(file, JSON.stringify(kept));
  await startedAgainChangesNothing(w, key, "a record cut at gone");
  await w.t.adjust(RETRY_MS * 8);
  await w.quiet();
  assert.deepEqual(asked, [], "nor, started again, does a record of it cut at gone");
});

test("what a station keeps of a chat's trips is bounded: three times there and back leave one record of them here, and a start at rest after changes nothing", async () => {
  const w = world();
  const a = w.get(A);
  const { key } = await stillfailChat(a);
  for (let i = 0; i < 3; i++) {
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
    await w.quiet();
    assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
    await w.quiet();
  }
  assert.deepEqual(a.moves.handover.outs().filter((o) => o.keys.includes(key)).map((o) => [o.step, o.ended]), [["done", true]], "one record, ended");
  await startedAgainChangesNothing(w, key, "three times there and back");
});

test("what a station keeps of a chat's arrivals is bounded: three times there and back leave one record of them on each station, and a start at rest after changes nothing", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  for (let i = 0; i < 3; i++) {
    assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
    await w.quiet();
    assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
    await w.quiet();
  }
  for (const st of [a, b]) assert.deepEqual(st.moves.handover.ins().filter((i) => i.keys.includes(key)).map((i) => i.step), ["shown"], `${st.id.slice(0, 1)}: one record of its arrivals`);
  await startedAgainChangesNothing(w, key, "three arrivals each side");
});

test("a chat that comes back is started with the transcript of what was said where it was: it is put under the project of its room's real path here, in place of the one it had here before, which a drop puts back; the data directory behind a symlink or not", async () => {
  const was = process.env.TMPDIR;
  try {
    for (const how of ["through a symlink", "plainly"] as const) {
      const real = realpathSync(tmpdir());
      const base = mkdtempSync(join(real, "transcripts-"));
      if (how === "through a symlink") {
        mkdirSync(join(base, "target"));
        symlinkSync(join(base, "target"), join(base, "via"));
        process.env.TMPDIR = join(base, "via");
      } else process.env.TMPDIR = base;
      const w = world();
      process.env.TMPDIR = was;
      const a = w.get(A);
      const b = w.get(B);
      const { key } = await stillfailChat(a);
      const id = a.rig.session(key).runtimeSessionId!;
      const at = (st: Station) => join(st.rig.dir, "transcripts", "claude", claudeProject(realpathSync(st.rig.session(key).workspace))!, `${id}.jsonl`);
      const all = (st: Station) => readdirSync(join(st.rig.dir, "transcripts", "claude")).filter((p) => existsSync(join(st.rig.dir, "transcripts", "claude", p, `${id}.jsonl`)));
      mkdirSync(dirname(at(a)), { recursive: true });
      writeFileSync(at(a), '{"said":"here before"}\n');
      // (each file sent, by its hash)
      const sha = (text: string) => createHash("sha256").update(text).digest("hex");
      const puts: string[] = [];
      w.tamper((_to, r) => {
        if (r.method === "handover.put") puts.push(String(r.name));
        return r;
      });
      assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
      await w.quiet();
      assert.ok(existsSync(at(b)), `${how}: there under its room's project; its files there: ${JSON.stringify(all(b))}`);
      assert.equal(readFileSync(at(b), "utf8"), '{"said":"here before"}\n', `${how}: there under its room's project`);
      assert.equal(puts.filter((h) => h === sha('{"said":"here before"}\n')).length, 1, `${how}: sent once, its held pass sending nothing of it unchanged`);
      writeFileSync(at(b), '{"said":"here before"}\n{"said":"said there"}\n');
      // (there, an older copy under the project of the room as its row names it, through the link: not the one resumed)
      const named = (st: Station) => join(st.rig.dir, "transcripts", "claude", claudeProject(st.rig.session(key).workspace)!, `${id}.jsonl`);
      if (how === "through a symlink") {
        assert.notEqual(named(b), at(b));
        mkdirSync(dirname(named(b)), { recursive: true });
        writeFileSync(named(b), '{"said":"an older copy"}\n');
      }
      // Back, failing once at its counts (dropped here): the one it had here before as it was.
      b.fails.add("counts");
      assert.notEqual((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
      await w.quiet();
      assert.equal(readFileSync(at(a), "utf8"), '{"said":"here before"}\n', `${how}: a drop puts back the one it had here`);
      // Back.
      assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
      await w.quiet();
      assert.equal(readFileSync(at(a), "utf8"), '{"said":"here before"}\n{"said":"said there"}\n', `${how}: here under its room's project, what was said there`);
      assert.deepEqual(all(a), [claudeProject(realpathSync(a.rig.session(key).workspace))], `${how}: no other file of it here`);
      // There again, unchanged: it is in place there, nothing of it sent.
      puts.length = 0;
      assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
      await w.quiet();
      assert.equal(puts.filter((h) => h === sha('{"said":"here before"}\n{"said":"said there"}\n')).length, 0, `${how}: in place there, not sent again`);
      assert.equal((await a.moves.scheduler.back(WS, B, { module: "chats", item: key })).failed, null);
      await w.quiet();
      // What its agent is started with (agents/claude.ts): that one, by the room as given and by its real path alike.
      const home = mkdtempSync(join(real, "home-"));
      symlinkSync(join(a.rig.dir, "transcripts", "claude"), join(home, "projects"));
      if (how === "through a symlink") {
        mkdirSync(dirname(named(a)), { recursive: true });
        writeFileSync(named(a), '{"said":"an older copy"}\n');
      }
      assert.equal(await transcriptAt(home, id, a.rig.session(key).workspace), join(home, "projects", claudeProject(realpathSync(a.rig.session(key).workspace))!, `${id}.jsonl`), how);
    }
  } finally {
    process.env.TMPDIR = was;
  }
});

test("a chat handed to the other, then put back in sight here by hand (its row here again, where it went and its trip's records set aside), so live on both: the plan toward the other says it cannot go, in its words; asked anyway, refused there", async () => {
  // (its rows saying no workspace, or the workspace's id, as a station enrolled in it writes them)
  for (const named of [false, true]) {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key } = await stillfailChat(a);
  assert.equal((await a.moves.scheduler.move(WS, B, { module: "chats", item: key })).failed, null);
  await w.quiet();
  assert.equal(b.rig.store.liveOf([key]).length, 1, "live there");
  // (by hand, this station stopped: its row in sight again, where it went forgotten, its trip's records moved aside)
  await a.moves.close();
  a.rig.store.db.prepare("UPDATE sessions SET ws = ? WHERE key = ?").run(named ? WS : null, key);
  if (named) w.get(B).rig.store.db.prepare("UPDATE sessions SET ws = ? WHERE key = ? AND ws IS NULL").run(WS, key);
  a.rig.store.db.prepare("DELETE FROM handed_over WHERE session = ?").run(key);
  const out = join(a.rig.dir, "replica", "handover", "out");
  if (existsSync(out)) renameSync(out, `${out}.aside`);
  a.moves = a.make();
  await a.moves.start();
  assert.deepEqual(a.rig.store.liveOf([key]), [key], "live here too");
  // (the first ask of B after a start not answered: whether it has the chat is not guessed)
  let lost = true;
  w.tamper((to, r) => {
    if (to === B && r.method === "move.chats.live" && lost) {
      lost = false;
      throw new Error("the station was not reached");
    }
    return r;
  });
  const first = (await a.moves.scheduler.plan(WS, B)).items.find((x) => x.id === key);
  assert.match(first?.cannot ?? "", /the other station did not answer whether it has it: ask again|另一台 station 没有回答它那边有没有这一项：再试一次/, `not answered: it cannot go this turn: ${JSON.stringify(first)}`);
  w.tamper(null);
  const plan = await a.moves.scheduler.plan(WS, B);
  const item = plan.items.find((x) => x.id === key);
  assert.equal(item?.state, "here", JSON.stringify(item));
  assert.match(item?.cannot ?? "", /a chat of this key is live on B|在「B」上还有一个在继续的副本/i, `the plan says it cannot go: ${JSON.stringify(item)}`);
  const view = moveView(plan, a.moves.modules.map((m) => m.id), a.moves.scheduler.stopped(), { limit: 50 }, null, false, (id) => id.slice(0, 1).toUpperCase());
  const row = view.modules.find((m: Json) => m.id === "chats").items.find((x: Json) => x.id === key);
  assert.match(row?.cannot ?? "", /a chat of this key is live on B|在「B」上还有一个在继续的副本/i, `GET /move's row says so: ${JSON.stringify(row)}`);
  await assert.rejects(a.moves.handover.handOver(key, B, { wait: true }), /a chat of this key is live on B|在「B」上还有一个在继续的副本/i);
  }
});

test("a chat whose key is live where it would go (one that went on there apart from it, as a retirement taken back leaves one) cannot go: the plan says so, the station asked refuses it before anything is written, and the chat goes on here", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  const { key, thread } = await stillfailChat(a);
  retiredCopy(a, b, key, null);
  // (it went on there: said something of its own)
  const there = homeThread(b, key);
  b.rig.store.insertMessage({ thread: there, ts: b.rig.hub.nextTs(), authorKind: "person", author: "p@x", text: "going on there" });
  say(a.rig.hub, thread, "p@x", "going on here");
  await w.quiet();
  await endTurn(a, key);
  const before = { row: b.rig.store.getSession(key), log: entries(b, there), sessions: b.rig.store.db.prepare("SELECT COUNT(*) AS n FROM sessions").get() };
  const plan = await a.moves.scheduler.plan(WS, B);
  assert.match(plan.items.find((x) => x.id === key)?.cannot ?? "", /a chat of this key is live on B|在「B」上还有一个在继续的副本/i);
  const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
  assert.match(out.refused[0]?.why ?? "", /a chat of this key is live on B|在「B」上还有一个在继续的副本/i);
  // (asked anyway, past the plan: refused there before anything is written)
  await assert.rejects(a.moves.handover.handOver(key, B, { wait: true }), /a chat of this key is live on B|在「B」上还有一个在继续的副本/i);
  await w.quiet();
  assert.deepEqual(b.moves.handover.ins(), [], "nothing begun there");
  assert.deepEqual({ row: b.rig.store.getSession(key), log: entries(b, there), sessions: b.rig.store.db.prepare("SELECT COUNT(*) AS n FROM sessions").get() }, before, "nothing written there");
  assert.equal(a.rig.store.handedTo(key), null);
  assert.equal(a.rig.hub.chatHeld(key), null, "it goes on here");
  assert.equal(a.rig.session(key).ws, null);
});

test("the station stopped in the middle of a turn: started again, what waited for an item that never left goes on, and the turn's outcome says the station restarted", async () => {
  const w = world();
  const a = w.get(A);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  a.profileHangs = true;
  void a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.deepEqual(a.moves.scheduler.stopped().map((x) => x.item.id), [key], "stopped as its account began to move");
  // (the process stops here: its account never left)
  await a.moves.close();
  a.profileHangs = false;
  a.rig.hub.releaseChat(key);
  a.moves = a.make();
  await a.moves.start();
  await w.quiet();
  assert.deepEqual(a.moves.scheduler.stopped(), [], "its account is here: it goes on");
  assert.equal(a.rig.hub.chatHeld(key), null);
  const last = a.moves.scheduler.last(WS);
  assert.ok(last !== null, "the turn the restart cut is kept as the last, its outcome said");
  assert.equal(last.how, "move");
  assert.match(last.failed?.error ?? "", /restarted during the move|迁移进行中这台 station 重启了/);
  say(a.rig.hub, t.id, "p@x", "still here");
  await w.quiet();
  assert.ok(a.rig.claude.last().prompts.join("\n").includes("still here"), "it works here");
});

test("the tell that an item came is lost: the station it came from heard again, what waited there for it goes on", async () => {
  const w = world();
  const a = w.get(A);
  const b = w.get(B);
  a.rig.raw.profiles.push({ id: "solo", runtime: "claude", home: "homes/solo" });
  const [key, t] = await newSession(a.rig.hub, { runtime: "claude", profile: "solo", createdBy: "p@x" });
  say(a.rig.hub, t.id, "p@x", "hi");
  await endTurn(a, key);
  await a.moves.scheduler.move(WS, B, { module: "chats", item: key, arriveStopped: true });
  await w.quiet();
  assert.match(b.rig.hub.chatHeld(key) ?? "", /waits for accounts own:solo@/);
  w.tamper((to, r) => {
    if (r.method === "move.arrived") throw new Error("lost on the way");
    return r;
  });
  await a.moves.scheduler.move(WS, B, { module: "accounts", item: `own:solo@${A}` });
  await w.quiet();
  assert.notEqual(b.rig.hub.chatHeld(key), null, "the tell lost: still waiting");
  w.tamper(null);
  // (the connection opened again: B hears from A)
  await a.bus.ask(B, { method: "move.open", workspace: WS });
  await w.quiet();
  assert.equal(b.rig.hub.chatHeld(key), null, "it goes on there");
  assert.deepEqual(b.moves.scheduler.stopped(), []);
});

/// The import's look-ups of an entry or a letter by its ts on `st`'s database while it runs (store/handover.ts).
function countByTs(st: Station) {
  // (the store's database is timed.ts's proxy over it: its own prepare, set on what it stands for, called by it)
  const db = st.rig.store.db as unknown as { prepare?(sql: string): unknown };
  const real = DatabaseSync.prototype.prepare;
  const counted = { n: 0, stop: () => void delete db.prepare };
  db.prepare = function (this: DatabaseSync, sql: string) {
    if (/FROM entries WHERE thread = \? AND ts = \?/.test(sql)) counted.n++;
    return real.call(this, sql);
  };
  return counted;
}

test("a thread found there that has an arriving entry already, at a lower number of its own (heard there itself, a retirement's leftover): found by its ts, not numbered on; the rest numbered on, every entry once, a turn's and an edit's number following it; forth and back again, every entry once on each side", async () => {
  // (the real run, 2026-11-16: Office-Host-2 had heard the Slack message itself at its n=1, Office-VM-1's thread had it
  // alone at n=2: "UNIQUE constraint failed: entries.thread, entries.ts")
  const X = "1794627297.417069";
  for (const shape of ["alone", "among others"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const [key, made] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
    const thread = made.id;
    mkdirSync(a.rig.session(key).workspace, { recursive: true });
    // B's leftover of it (a retirement's): the session and its thread, found there by what it is
    retiredCopy(a, b, key);
    const there = homeThread(b, key);
    const put = (st: Station, t: number, n: number, ts: string | null, author: string, at: number, text: string, target: number | null = null) =>
      st.rig.store.db.prepare("INSERT INTO entries (thread, n, kind, target, ts, author_kind, author, text, at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(t, n, target === null ? "message" : "edit", target, ts, target === null && author !== "U0C4CNJMRP1" ? "ember" : "person", author, text, at);
    put(b, there, 1, X, "U0C4CNJMRP1", 1794627313642, "heard there itself");
    if (shape === "alone") put(a, thread, 2, X, "gpt-ember", 1794627297648, "the message");
    else {
      put(a, thread, 1, "1794627290.000001", "gpt-ember", 1794627290000, "before it");
      put(a, thread, 2, X, "gpt-ember", 1794627297648, "the message");
      put(a, thread, 3, "1794627299.000003", "gpt-ember", 1794627299000, "after it");
      put(a, thread, 4, null, "gpt-ember", 1794627300000, "the message, edited", 2);
    }
    // (a turn about the message, by its number here)
    a.rig.store.db.prepare("INSERT INTO turns (id, session_key, kind, started_at, ended_at, about_thread, about_n, about_ts) VALUES ('turn-x', ?, 'message', 1, 2, ?, 2, ?)").run(key, thread, X);
    const once = (st: Station, t: number, how: string) => {
      const rows = st.rig.store.db.prepare("SELECT n, kind, target, ts, text FROM entries WHERE thread = ? ORDER BY n").all(t) as { n: number; kind: string; target: number | null; ts: string | null; text: string }[];
      const tss = rows.filter((r) => r.ts !== null).map((r) => r.ts);
      assert.equal(new Set(tss).size, tss.length, `${shape}, ${how}: every entry once by its ts: ${JSON.stringify(rows)}`);
      const edits = rows.filter((r) => r.kind === "edit");
      assert.equal(edits.length, shape === "alone" ? 0 : 1, `${shape}, ${how}: the edit once`);
      const at = rows.find((r) => r.ts === X)!.n;
      for (const e of edits) assert.equal(e.target, at, `${shape}, ${how}: the edit's target the message`);
      const turn = st.rig.store.db.prepare("SELECT about_n FROM turns WHERE id = 'turn-x'").get() as { about_n: number } | undefined;
      if (turn !== undefined) assert.equal(turn.about_n, at, `${shape}, ${how}: the turn about the message`);
      return rows;
    };
    // (what the import looks up by ts there, counted: a fresh thread's own log pays none)
    const byTs = countByTs(b);
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    byTs.stop();
    assert.equal(out.failed, null, `${shape}: it went: ${JSON.stringify(out.failed)}`);
    console.log(`# ${shape}: looked up by ts there: ${byTs.n}`);
    if (shape === "alone") {
      // A chat whose thread is put in fresh there, three entries: none looked up by its ts.
      const [fresh, freshThread] = await newSession(a.rig.hub, { runtime: "claude", profile: "cc", createdBy: "p@x" });
      mkdirSync(a.rig.session(fresh).workspace, { recursive: true });
      for (let k = 1; k <= 3; k++) put(a, freshThread.id, k, `1794627400.00000${k}`, "gpt-ember", 1794627400000 + k, `fresh ${k}`);
      const freshByTs = countByTs(b);
      const went = await a.moves.scheduler.move(WS, B, { module: "chats", item: fresh });
      await w.quiet();
      freshByTs.stop();
      assert.equal(went.failed, null, JSON.stringify(went.failed));
      assert.equal(entries(b, homeThread(b, fresh)).length, 3);
      assert.equal(freshByTs.n, 0, "a fresh thread's entries looked up by ts: none");
    }
    assert.equal(homeThread(b, key), there, `${shape}: the thread found there`);
    const rows = once(b, there, "there");
    assert.deepEqual(rows.map((r) => [r.n, r.ts]), shape === "alone" ? [[1, X]] : [[1, X], [2, "1794627290.000001"], [3, "1794627299.000003"], [4, null]],
      `${shape}: the message where it was there, the rest numbered on`);
    assert.equal(rows[0]!.text, "heard there itself", `${shape}: what was there kept`);
    // forth and back again, twice
    for (let i = 0; i < 2; i++) {
      const back = await a.moves.scheduler.back(WS, B, { module: "chats", item: key });
      await w.quiet();
      assert.equal(back.failed, null, `${shape}: back ${i}: ${JSON.stringify(back.failed)}`);
      once(a, thread, `back ${i}`);
      const forth = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
      await w.quiet();
      assert.equal(forth.failed, null, `${shape}: forth ${i}: ${JSON.stringify(forth.failed)}`);
      once(b, there, `forth ${i}`);
    }
  }
});

test("the same bytes at two paths of a room, one of them in place there already (a retirement's leftover): the bytes are sent all the same and both are placed, not sharing a file; so too where the second path comes between the first pass and the held one", async () => {
  // (the real run, 2026-11-16: two pairs of uploads of the same bytes, Office-Host-2's leftover room holding one of
  // each pair: "发过去的文件有 2 个在那边不见了")
  const bytesH = Buffer.alloc(300_000, 7);
  for (const when of ["at once", "between the passes"] as const) {
    const w = world();
    const a = w.get(A);
    const b = w.get(B);
    const { key } = await stillfailChat(a);
    const room = a.rig.session(key).workspace;
    writeFileSync(join(room, "B.webm"), bytesH);
    if (when === "at once") writeFileSync(join(room, "A.webm"), bytesH);
    writeFileSync(join(room, "C.txt"), "only here");
    // B's leftover of it: its room with B.webm alone, written there at another time
    retiredCopy(a, b, key);
    const roomThere = b.rig.session(key).workspace;
    for (const n of ["A.webm", "C.txt"]) rmSync(join(roomThere, n), { force: true });
    utimesSync(join(roomThere, "B.webm"), new Date(1_000_000), new Date(1_000_000));
    // (between the passes: A.webm made here as the first pass's files are placed there)
    let made = false;
    w.tamper((to, r) => {
      if (when === "between the passes" && to === B && r.method === "handover.place" && !made) {
        made = true;
        writeFileSync(join(room, "A.webm"), bytesH);
      }
      return r;
    });
    const out = await a.moves.scheduler.move(WS, B, { module: "chats", item: key });
    await w.quiet();
    assert.equal(out.failed, null, `${when}: it went: ${JSON.stringify(out.failed)}`);
    if (when === "between the passes") assert.ok(made, "the duplicate came between the passes");
    assert.equal(b.rig.session(key).ws, null, `${when}: shown there`);
    for (const n of ["A.webm", "B.webm"]) assert.ok(readFileSync(join(roomThere, n)).equals(bytesH), `${when}: ${n} there with its bytes`);
    assert.equal(readFileSync(join(roomThere, "C.txt"), "utf8"), "only here", `${when}: C.txt there`);
    assert.notEqual(statSync(join(roomThere, "A.webm")).ino, statSync(join(roomThere, "B.webm")).ino, `${when}: A and B not one file`);
  }
});
