// One chat read from a copy (`--builder replica-chat`, replica/chat.ts) gives at most what its bounds say, however big
// the chat and the copy: its last CHAT_ENTRIES entries of people and agents, each text cut to CHAT_TEXT bytes, the
// whole at most CHAT_BYTES (older entries left out first), at most CHAT_SESSIONS sessions; the station's notices and
// other chats left out.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { test } from "node:test";
import { mbReaderBinary, pionBinary } from "../src/read/mb-reader.ts";
import { CHAT_BYTES, CHAT_ENTRIES, CHAT_SESSIONS, CHAT_TEXT, readChatSoon } from "../src/replica/chat.ts";
import { nothingTold } from "../src/replica/export.ts";
import { Store } from "../src/store/store.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, ORIGIN, chat, dataDir } from "./replica-fakes.ts";
import { pinnedPion } from "./pion-pinned.ts";

const binary = mbReaderBinary();
/// Asked for Pion (`STILLFAIL_READER_REPLICA_CHAT` or `STILLFAIL_READER_ENGINE`), the readings go through the reader
/// selection (no binary given), so they are the Pion program's; else the MoonBit program's.
const viaSelection = (process.env.STILLFAIL_READER_REPLICA_CHAT ?? process.env.STILLFAIL_READER_ENGINE)?.trim() === "pion";
const chosen = viaSelection ? undefined : binary ?? undefined;
/// (each asks only for the program it reads with: Pion's alone where it is asked for, a MoonBit one missing then too)
const skip = viaSelection
  ? pionBinary() === null
    ? "Pion asked for, but no stillfail-pion is built here (STILLFAIL_PION_READER)"
    : false
  : binary === null
    ? "the MoonBit program is not built here (station/mb/build.sh)"
    : false;
// (a run given a Pion reader that is not there fails rather than skips: pion-pinned.ts)
if (viaSelection && pionBinary() === null && pinnedPion() !== undefined) throw new Error(`STILLFAIL_PION_READER=${pinnedPion()} given but not there`);

/// A station's copy of HOME written by the export, its generation's directory.
async function copied(data: string, store: Store): Promise<string> {
  const runner = new InlineRunner({ db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: ORIGIN, now: () => 1_700_000_000_000 });
  await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "big" }] });
  for (let i = 0; i < 20; i++) {
    const passed = await runner.pass(nothingTold());
    if (!passed.more) break;
  }
  await runner.close();
  store.close();
  const own = join(data, "replica", "own", HOME);
  const gens = readdirSync(own).filter((g) => existsSync(join(own, g, "head.json")));
  assert.equal(gens.length, 1, "one generation of the copy");
  return join(own, gens[0]!);
}

test("a chat read from a copy is held to its bounds, its newest entries kept", { skip }, async () => {
  const data = dataDir("chatb");
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  // (the chat: many messages, two of three far longer than CHAT_TEXT, so that CHAT_ENTRIES of them are more than
  // CHAT_BYTES; the station's notices among them; more sessions than CHAT_SESSIONS)
  const big = chat(store, data, "chat:big", null, 0);
  const total = 400;
  for (let i = 0; i < total; i++) {
    const text = i % 3 === 2 ? `said ${i}` : `long ${i} ${"字".repeat(CHAT_TEXT)}`;
    store.insertMessage({ thread: big, ts: `big.${i}`, authorKind: i % 2 === 0 ? "person" : "agent", author: i % 2 === 0 ? "p@x" : "chat:big", text });
    if (i % 50 === 0) store.insertMessage({ thread: big, ts: `note.${i}`, authorKind: "station", author: "station", text: `notice ${i}` });
  }
  for (let s = 0; s < CHAT_SESSIONS + 5; s++) {
    const key = `chat:extra${s}`;
    store.insertSession({ key, connect: "chat", runtime: "codex", profile: "cx", workspace: join(data, "sessions", "chat", key, "workspace"), token: `t-${key}`, createdAt: 1, lastActiveAt: 1, ws: null });
    store.joinThread(big, key, "chat");
  }
  // (the last to join left again: those still in the chat come first)
  store.leaveThread(big, `chat:extra${CHAT_SESSIONS + 4}`);
  // (another chat of the copy: none of it in the reading)
  chat(store, data, "chat:other", null, 50);
  const dir = await copied(data, store);
  const work = join(data, "replica", "chat-read.db");
  const read = await readChatSoon({ dir, work, thread: big, shellDir: join(data, "shell"), binary: chosen });
  assert.equal(read.origin, ORIGIN);
  assert.equal(read.thread?.id, big);
  assert.equal(read.thread?.title, "Chat chat:big");
  // (the bytes' bound reached before the entries' one: older entries left out)
  assert.ok(read.entries.length > 0 && read.entries.length < CHAT_ENTRIES, `${read.entries.length} entries`);
  assert.ok(Buffer.byteLength(JSON.stringify(read)) <= CHAT_BYTES, `${Buffer.byteLength(JSON.stringify(read))} bytes`);
  for (const e of read.entries) {
    assert.ok(Buffer.byteLength(e.text) <= CHAT_TEXT, `entry ${e.n}: ${Buffer.byteLength(e.text)} bytes`);
    assert.notEqual(e.author_kind, "station", "no station notice");
    assert.ok(!e.text.includes("chat:other says"), "no entry of the other chat");
  }
  assert.ok(read.entries.some((e) => e.cut), "a long text cut");
  // (the newest, in order: the last message said is the last entry)
  assert.ok(read.entries.at(-1)!.text.startsWith(`long ${total - 1} `), "the last said last");
  const ns = read.entries.map((e) => e.n);
  assert.deepEqual(ns, [...ns].sort((a, b) => a - b), "oldest first");
  assert.equal(read.earlier, total - read.entries.length, "the entries left out counted");
  assert.equal(read.sessions.length, CHAT_SESSIONS, `${read.sessions.length} sessions`);
  // (those still in the chat, the newest to join first: the one that left and the first to join left out)
  assert.ok(read.sessions.every((s) => s.left_at === null), "only sessions still in the chat");
  assert.equal(read.sessions[0]!.key, `chat:extra${CHAT_SESSIONS + 3}`);
  assert.ok(read.sessions.every((s) => s.runtime === "codex"), "the newest sessions, not the first");
  assert.equal(existsSync(work), false, "the fold is gone after");

  // A chat the copy does not hold: the copy, and no thread.
  const none = await readChatSoon({ dir, work, thread: 987_654, shellDir: join(data, "shell"), binary: chosen });
  assert.equal(none.thread, null);
  assert.deepEqual(none.entries, []);
});

test("a chat read from a copy is its own, whole, beside chats whose numbers begin as its does", { skip }, async () => {
  const data = dataDir("chatn");
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  // (chats 1 to 12: chat 1 beside 10, 11 and 12, each with its own words, sessions and a later edit)
  const threads: number[] = [];
  for (let i = 1; i <= 12; i++) threads.push(chat(store, data, `chat:n${i}`, null, 3));
  assert.ok(threads.includes(1) && threads.includes(10) && threads.includes(11), `threads ${threads.join(",")}`);
  const dir = await copied(data, store);
  const work = join(data, "replica", "chat-read.db");
  for (const id of [1, 10, 11]) {
    const read = await readChatSoon({ dir, work, thread: id, shellDir: join(data, "shell"), binary: chosen });
    const key = `chat:n${threads.indexOf(id) + 1}`;
    assert.equal(read.thread?.id, id);
    assert.equal(read.thread?.title, `Chat ${key}`);
    assert.deepEqual(read.entries.map((e) => e.text), [0, 1, 2].map((i) => `${key} says ${i}`), `chat ${id}: its own entries, all of them`);
    assert.deepEqual(read.sessions.map((s) => s.key), [key], `chat ${id}: its own session`);
  }
});

test("20 large sessions exceeding --bytes are trimmed in priority order so total JSON strictly fits --bytes", { skip }, async () => {
  const data = dataDir("chat-big-sessions");
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const tid = chat(store, data, "chat:s0", null, 3);
  const longPath = "/" + "a".repeat(1950);
  const longTitle = "t".repeat(950);
  for (let s = 0; s < CHAT_SESSIONS; s++) {
    const key = `chat:huge-${String(s).padStart(2, "0")}`;
    store.insertSession({
      key,
      connect: "chat",
      runtime: "codex",
      profile: "cx",
      model: "m".repeat(180),
      title: `${key}-${longTitle}`,
      cwd: longPath,
      workspace: longPath,
      token: `t-${key}`,
      createdAt: 1,
      lastActiveAt: 1,
      ws: null,
    });
    store.joinThread(tid, key, "chat");
  }
  const dir = await copied(data, store);
  const work = join(data, "replica", "chat-read.db");
  const budget = 65536;
  const bin = viaSelection ? pionBinary()! : binary!;
  const out = execFileSync(
    bin,
    [
      "--builder",
      "replica-chat",
      "--dir",
      dir,
      "--work",
      work,
      "--thread",
      String(tid),
      "--entries",
      String(CHAT_ENTRIES),
      "--text",
      String(CHAT_TEXT),
      "--bytes",
      String(budget),
      "--sep",
      sep,
      "--shell-dir",
      join(data, "shell"),
    ],
    { encoding: "utf8", maxBuffer: 64 << 20 },
  );
  const read = JSON.parse(out).chat;
  assert.ok(Buffer.byteLength(out, "utf8") <= budget, `stdout ${Buffer.byteLength(out, "utf8")} > ${budget}`);
  assert.ok(read.sessions.length > 0 && read.sessions.length < CHAT_SESSIONS, `expected trimmed sessions, got ${read.sessions.length}`);
  assert.equal(read.sessions[0]!.key, `chat:huge-${String(CHAT_SESSIONS - 1).padStart(2, "0")}`);
  assert.equal(existsSync(work), false, "the fold is gone after");
});

test("replica-chat bounds oversized head.name (65536 ASCII) and U+2028/U+2029 escaped sessions strictly within --bytes stdout", { skip }, async () => {
  const data = dataDir("chat-head-u2028");
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const tid = chat(store, data, "chat:u0", null, 3);
  const sepChunk = "\u2028\u2029".repeat(160);
  for (let s = 0; s < CHAT_SESSIONS; s++) {
    const key = `chat:sep-${String(s).padStart(2, "0")}`;
    store.insertSession({
      key,
      connect: "chat",
      runtime: "codex",
      profile: "cx",
      model: "m".repeat(180),
      title: `${key}-${sepChunk}`,
      cwd: "/" + sepChunk + "x".repeat(400),
      workspace: "/" + sepChunk + "y".repeat(400),
      token: `t-${key}`,
      createdAt: 1,
      lastActiveAt: 1,
      ws: null,
    });
    store.joinThread(tid, key, "chat");
  }
  const dir = await copied(data, store);
  const headPath = join(dir, "head.json");
  const head = JSON.parse(readFileSync(headPath, "utf8"));
  head.name = "N".repeat(65536);
  writeFileSync(headPath, JSON.stringify(head));

  const work = join(data, "replica", "chat-read.db");
  const budget = 65536;
  const bin = viaSelection ? pionBinary()! : binary!;
  const runRaw = (threadId: number) =>
    execFileSync(
      bin,
      [
        "--builder", "replica-chat",
        "--dir", dir,
        "--work", work,
        "--thread", String(threadId),
        "--entries", String(CHAT_ENTRIES),
        "--text", String(CHAT_TEXT),
        "--bytes", String(budget),
        "--sep", sep,
        "--shell-dir", join(data, "shell"),
      ],
      { encoding: "utf8", maxBuffer: 64 << 20 },
    );

  // (a) Existing thread with 65536-char head.name + 20 sessions full of U+2028/U+2029
  const outPresent = runRaw(tid);
  assert.ok(Buffer.byteLength(outPresent, "utf8") <= budget, `present stdout ${Buffer.byteLength(outPresent, "utf8")} > ${budget}`);
  assert.ok(outPresent.includes("\\u2028") && outPresent.includes("\\u2029"), "line separators must be escaped on stdout");
  const parsedPresent = JSON.parse(outPresent).chat;
  assert.equal(parsedPresent.name.length, 400);
  assert.ok(parsedPresent.sessions.length > 0 && parsedPresent.sessions.length < CHAT_SESSIONS);

  // (b) Missing thread with 65536-char head.name
  const outMissing = runRaw(987_654);
  assert.ok(Buffer.byteLength(outMissing, "utf8") <= budget, `missing stdout ${Buffer.byteLength(outMissing, "utf8")} > ${budget}`);
  const parsedMissing = JSON.parse(outMissing).chat;
  assert.equal(parsedMissing.thread, null);
  assert.equal(parsedMissing.name.length, 400);
});
