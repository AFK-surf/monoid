// Dual-engine parity for one chat read from a copy (`--builder replica-chat`, replica/chat.ts): the MoonBit
// `stillfail-reader` and the Pion `stillfail-pion` read the same copy to the same JSON, byte for byte (multi-byte texts
// cut at a character's end, older entries left out past CHAT_BYTES, `earlier` counted, sessions that left ordered last,
// a chat the copy does not hold, a copy that is none, a `--thread` that is no number), each removing its scratch fold;
// and `STILLFAIL_READER_REPLICA_CHAT=pion` makes `readChatSoon` spawn the Pion program through the reader selection.
// Skips when no Pion binary is built here; strictly 0-skip with distinct binaries when STILLFAIL_REQUIRE_DUAL_READER=1.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { after, test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mbReaderBinary, pionBinary, resetReaderSelectionStateForTest, resolveReaderSelectionAsync } from "../src/read/mb-reader.ts";
import { readerTelemetry } from "../src/read/reader-telemetry.ts";
import { CHAT_BYTES, CHAT_ENTRIES, CHAT_SESSIONS, CHAT_TEXT, readChatSoon } from "../src/replica/chat.ts";
import { nothingTold } from "../src/replica/export.ts";
import { Store } from "../src/store/store.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, ORIGIN, attach, chat, dataDir } from "./replica-fakes.ts";

type Json = any;
const cleanup: string[] = [];
after(() => {
  for (const d of cleanup) rmSync(d, { recursive: true, force: true });
});

/// MoonBit's `fail()` puts where in its source it failed before what (`src/…mbt:l:c-l:c@pkg FAILED: `), a prefix of
/// MoonBit's own; Pion says only what, and does not make up `.mbt` places. So Pion's errors are held to the contract's
/// words exactly, and MoonBit's to the same words once that prefix is taken out.
const MB_FAIL_PREFIX = /^\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;
const MB_FAIL_IN_LINE = /^\{"error":"\S+:\d+:\d+-\d+:\d+@\S+ FAILED: /;
const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e));

function binaries(t: { skip: (msg: string) => void }): { mb: string; pion: string } | null {
  const requireDual = process.env.STILLFAIL_REQUIRE_DUAL_READER === "1";
  const mb = mbReaderBinary();
  if (mb === null) {
    if (process.env.CI || requireDual) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here (station/mb/build.sh)");
    return null;
  }
  const pion = pionBinary();
  if (pion === null) {
    if (requireDual || process.env.STILLFAIL_PION_READER?.trim()) assert.fail(`STILLFAIL_PION_READER is required (${process.env.STILLFAIL_PION_READER ?? "unset"}) but resolved to null`);
    t.skip("STILLFAIL_PION_READER / built stillfail-pion binary not present in this environment");
    return null;
  }
  assert.notEqual(realpathSync(mb), realpathSync(pion), "MB and Pion binaries must be distinct files");
  const ver = execFileSync(pion, ["--version"], { encoding: "utf8" });
  const modes = new Set(ver.match(/modes:(\S+)/)?.[1]?.split(",") ?? []);
  assert.ok(modes.has("replica-chat"), `Pion --version must advertise exact mode replica-chat: ${ver}`);
  return { mb, pion };
}

/// A copy of HOME as the export writes it: a big chat (texts of three and four bytes a character far longer than
/// CHAT_TEXT, station notices among them, an edit, attached files, more sessions than CHAT_SESSIONS, one left), chats whose
/// numbers begin as another's does, and an archived one. Its generation's directory, and the chats.
async function copied(): Promise<{ data: string; dir: string; big: number; small: number[]; archived: number; odd: number }> {
  const data = dataDir("chatsw");
  cleanup.push(data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const big = chat(store, data, "chat:big", null, 0);
  const total = 260;
  for (let i = 0; i < total; i++) {
    const text = i % 3 === 2 ? `said ${i} 😀` : i % 3 === 1 ? `long ${i} ${"😀".repeat(CHAT_TEXT / 2)}` : `long ${i} ${"字".repeat(CHAT_TEXT)}`;
    store.insertMessage({ thread: big, ts: `big.${i}`, authorKind: i % 2 === 0 ? "person" : "agent", author: i % 2 === 0 ? "p@x" : "chat:big", text });
    if (i % 40 === 0) store.insertMessage({ thread: big, ts: `note.${i}`, authorKind: "station", author: "station", text: `notice ${i}` });
  }
  const files = Array.from({ length: 12 }, (_, i) => attach(data, "chat:big", `文件-${i}.txt`, `file ${i}`));
  store.insertMessage({ thread: big, ts: "big.files", authorKind: "person", author: "p@x", text: "看附件", attachments: files });
  store.editMessage("ember", "C", "ts-chat:big", `big.${total - 1}`, `edited ${"字".repeat(10)}`);
  for (let s = 0; s < CHAT_SESSIONS + 3; s++) {
    const key = `chat:extra${s}`;
    store.insertSession({ key, connect: "chat", runtime: "codex", profile: "cx", workspace: join(data, "sessions", "chat", key, "workspace"), token: `t-${key}`, createdAt: 1, lastActiveAt: 1, ws: null });
    store.joinThread(big, key, "chat");
  }
  store.leaveThread(big, `chat:extra${CHAT_SESSIONS + 2}`);
  store.leaveThread(big, "chat:big");
  const small: number[] = [];
  for (let i = 1; i <= 11; i++) small.push(chat(store, data, `chat:n${i}`, null, 3));
  const archived = chat(store, data, "chat:arch", null, 4);
  store.setArchived("chat:arch", true, "p@x");
  // (a chat whose entry's attachments are no JSON, and that names a session the copy has no row of)
  const odd = chat(store, data, "chat:odd", null, 2);
  const raw = new DatabaseSync(join(data, "stillfail.db"));
  try {
    raw.prepare("UPDATE entries SET attachments = ? WHERE thread = ?").run('[{"name":"half', odd);
    raw.prepare("INSERT INTO thread_sessions (thread, session, connect, joined_at, left_at) VALUES (?, ?, 'chat', 5, NULL)").run(odd, "chat:ghost");
  } finally {
    raw.close();
  }
  const runner = new InlineRunner({ db: join(data, "stillfail.db"), replica: join(data, "replica"), dataDir: data, origin: ORIGIN, now: () => 1_700_000_000_000 });
  await runner.places({ home: HOME, workspaces: [{ workspace: HOME, name: "大站 😀" }] });
  for (let i = 0; i < 20; i++) {
    const passed = await runner.pass(nothingTold());
    if (!passed.more) break;
  }
  await runner.close();
  store.close();
  const own = join(data, "replica", "own", HOME);
  const gens = readdirSync(own).filter((g) => existsSync(join(own, g, "head.json")));
  assert.equal(gens.length, 1, "one generation of the copy");
  return { data, dir: join(own, gens[0]!), big, small, archived, odd };
}

type Bounds = { entries: number; text: number; bytes: number };
const ASKED: Bounds = { entries: CHAT_ENTRIES, text: CHAT_TEXT, bytes: CHAT_BYTES };

/// What each program writes for chat `thread` of the copy, as it writes it (readChatSoon's arguments, or `bounds`),
/// each removing its fold.
function raw(bins: { mb: string; pion: string }, c: { data: string; dir: string }, thread: string, bounds: Bounds = ASKED): { mb: string; pion: string } {
  const out: Record<string, string> = {};
  for (const [engine, binary] of [["mb", bins.mb], ["pion", bins.pion]] as const) {
    const work = join(c.data, "replica", `chat-raw-${engine}.db`);
    const args = ["--builder", "replica-chat", "--dir", c.dir, "--work", work, "--thread", thread, "--entries", String(bounds.entries), "--text", String(bounds.text), "--bytes", String(bounds.bytes), "--sep", sep, "--shell-dir", join(c.data, "shell")];
    out[engine] = execFileSync(binary, args, { encoding: "utf8", maxBuffer: 64 << 20 });
    assert.equal(existsSync(work), false, `${engine}: the fold is gone after`);
  }
  return { mb: out.mb!, pion: out.pion! };
}

/// The same lines from both, or, where they say an error, Pion's the contract's words exactly and MoonBit's the same
/// once its `fail()` prefix is out.
function sameLines(r: { mb: string; pion: string }, what: string, error?: string) {
  if (error === undefined) {
    assert.equal(r.pion, r.mb, `${what}: the programs' lines 0-diff`);
    assert.ok(r.pion.includes('{"chat":'), `${what}: ${r.pion.slice(0, 200)}`);
    return;
  }
  const expected = `${JSON.stringify({ error })}\n`;
  assert.equal(r.pion, expected, `${what}: Pion writes the exact single error line`);
  assert.ok(!MB_FAIL_IN_LINE.test(r.pion), `${what}: Pion makes up no MoonBit source place`);
  assert.equal(r.mb.replace(MB_FAIL_IN_LINE, '{"error":"'), expected, `${what}: MoonBit's line, its fail() prefix out, is Pion's`);
}

async function readBoth(bins: { mb: string; pion: string }, o: { data: string; dir: string; thread: number }): Promise<{ mb: Json; pion: Json }> {
  const out: Record<string, Json> = {};
  for (const [engine, binary] of [["mb", bins.mb], ["pion", bins.pion]] as const) {
    const work = join(o.data, "replica", `chat-${engine}.db`);
    out[engine] = await readChatSoon({ dir: o.dir, work, thread: o.thread, shellDir: join(o.data, "shell"), binary }).then(
      (chat) => ({ chat }),
      (e) => ({ error: messageOf(e) }),
    );
    assert.equal(existsSync(work), false, `${engine}: the fold is gone after`);
  }
  return { mb: out.mb, pion: out.pion };
}

/// Both refused alike: Pion's error the contract's words (`error`, or matching `pattern`), MoonBit's the same once its
/// `fail()` prefix is out.
function sameRefusal(r: { mb: Json; pion: Json }, what: string, error: string | RegExp) {
  assert.equal(typeof r.pion.error, "string", `${what}: Pion refused: ${JSON.stringify(r.pion)}`);
  if (typeof error === "string") assert.equal(r.pion.error, error, `${what}: Pion's words exactly`);
  else assert.match(r.pion.error, error, what);
  assert.ok(!MB_FAIL_PREFIX.test(r.pion.error), `${what}: Pion makes up no MoonBit source place`);
  assert.equal(String(r.mb.error).replace(MB_FAIL_PREFIX, ""), r.pion.error, `${what}: MoonBit's, its fail() prefix out, is Pion's`);
}

test("replica-chat: MoonBit and Pion read every chat of a copy to the same JSON (0-diff)", async (t) => {
  const bins = binaries(t);
  if (bins === null) return;
  const c = await copied();

  // (what the programs write, byte for byte, before the station reads it)
  for (const thread of [c.big, c.small[0]!, c.small[9]!, c.odd, 987_654]) sameLines(raw(bins, c, String(thread)), `chat ${thread}`);
  // (bounds asked below the least: each held to its least, as both clamp)
  sameLines(raw(bins, c, String(c.big), { entries: 0, text: 5, bytes: 10 }), "the big chat, bounds below the least");
  sameLines(raw(bins, c, String(c.big), { entries: 100_000, text: 10_000_000, bytes: 100_000_000 }), "the big chat, bounds past the most");
  // (`--thread` as both read a number: a negative one and not-a-number read (no such chat); one past a double's range,
  // a word and nothing are refused)
  for (const thread of ["-1", "nan"]) sameLines(raw(bins, c, thread), `--thread ${thread}`);
  for (const thread of ["1e309", "seven", ""]) sameLines(raw(bins, c, thread), `--thread ${JSON.stringify(thread)}`, "--thread is a chat's id");
  const big = await readBoth(bins, { ...c, thread: c.big });
  assert.equal(JSON.stringify(big.pion), JSON.stringify(big.mb), "the big chat: 0-diff");
  const read = big.mb.chat;
  assert.ok(read !== undefined, `the big chat read: ${JSON.stringify(big.mb)}`);
  assert.equal(read.thread?.id, c.big);
  assert.ok(read.entries.length > 0 && read.entries.length < CHAT_ENTRIES, `${read.entries.length} entries: the bytes' bound reached first`);
  assert.ok(Buffer.byteLength(JSON.stringify(read)) <= CHAT_BYTES);
  assert.ok(read.earlier > 200, `earlier ${read.earlier}: the entries left out counted`);
  assert.ok(read.entries.some((e: Json) => e.cut), "a long text cut");
  for (const e of read.entries) {
    assert.ok(Buffer.byteLength(e.text) <= CHAT_TEXT, `entry ${e.n}: ${Buffer.byteLength(e.text)} bytes`);
    assert.ok(!e.text.includes("�"), `entry ${e.n}: never half a character`);
  }
  assert.ok(read.entries.some((e: Json) => e.kind === "edit"), "the edit read");
  const withFiles = read.entries.find((e: Json) => e.text === "看附件");
  assert.ok(withFiles !== undefined && withFiles.files.length === 10, `files bounded: ${JSON.stringify(withFiles)}`);
  assert.equal(read.sessions.length, CHAT_SESSIONS);
  // (those that left come last; the newest to join first)
  assert.equal(read.sessions[0].key, `chat:extra${CHAT_SESSIONS + 1}`);

  for (const id of [...c.small, c.archived]) {
    const one = await readBoth(bins, { ...c, thread: id });
    assert.equal(JSON.stringify(one.pion), JSON.stringify(one.mb), `chat ${id}: 0-diff`);
    assert.equal(one.mb.chat?.thread?.id, id);
    assert.equal(one.mb.chat?.entries.length, id === c.archived ? 4 : 3);
  }

  // (attachments that are no JSON: no files; a session the copy has no row of: its key alone)
  const odd = await readBoth(bins, { ...c, thread: c.odd });
  assert.equal(JSON.stringify(odd.pion), JSON.stringify(odd.mb), "the odd chat: 0-diff");
  assert.ok(odd.mb.chat.entries.length === 2 && odd.mb.chat.entries.every((e: Json) => e.files.length === 0), JSON.stringify(odd.mb.chat.entries));
  const ghost = odd.mb.chat.sessions.find((x: Json) => x.key === "chat:ghost");
  assert.deepEqual(ghost, { key: "chat:ghost", runtime: null, model: null, effort: null, title: null, cwd: null, workspace: null, archived_at: null, left_at: null });

  // (a chat the copy does not hold: the copy, no thread)
  const none = await readBoth(bins, { ...c, thread: 987_654 });
  assert.equal(JSON.stringify(none.pion), JSON.stringify(none.mb), "a missing chat: 0-diff");
  assert.equal(none.mb.chat?.thread, null);
  assert.deepEqual(none.mb.chat?.entries, []);

  // (no copy there, a head that is none: the same refusal)
  const empty = join(c.data, "no-copy");
  mkdirSync(empty, { recursive: true });
  writeFileSync(join(empty, "head.json"), JSON.stringify({ v: 1, origin: ORIGIN }));
  sameRefusal(await readBoth(bins, { data: c.data, dir: empty, thread: c.big }), "a head that is none", "no copy here, or one of a newer station's");
  sameRefusal(await readBoth(bins, { data: c.data, dir: join(c.data, "nowhere"), thread: c.big }), "no head there", /^ENOENT: no such file or directory, open '.*head\.json'$/);
});

test("replica-chat: STILLFAIL_READER_REPLICA_CHAT=pion spawns stillfail-pion through the reader selection", async (t) => {
  const bins = binaries(t);
  if (bins === null) return;
  const c = await copied();
  const names = ["STILLFAIL_PION_READER", "STILLFAIL_MB_READER", "STILLFAIL_READER_REPLICA_CHAT", "STILLFAIL_READER_ENGINE"] as const;
  const saved = names.map((k) => [k, process.env[k]] as const);
  const use = (pion: string) => {
    process.env.STILLFAIL_PION_READER = pion;
    process.env.STILLFAIL_MB_READER = bins.mb;
    process.env.STILLFAIL_READER_REPLICA_CHAT = "pion";
    delete process.env.STILLFAIL_READER_ENGINE;
    resetReaderSelectionStateForTest();
  };
  const work = join(c.data, "replica", "chat-selected.db");
  const read = () => readChatSoon({ dir: c.dir, work, thread: c.big, shellDir: join(c.data, "shell") });
  try {
    const mb = await readChatSoon({ dir: c.dir, work, thread: c.big, shellDir: join(c.data, "shell"), binary: bins.mb });
    // (on every platform: the selection names the Pion program, and the reading is one spawn of it, none of MoonBit's,
    // no fallback, by the readers' own counts)
    use(bins.pion);
    const chosen = await resolveReaderSelectionAsync("replica-chat", { logAt: "replica" });
    assert.equal(chosen.engine, "pion");
    assert.equal(chosen.selection.fallback, false);
    assert.equal(realpathSync(chosen.primaryBinary), realpathSync(bins.pion));
    readerTelemetry.flushWindow();
    const selected = await read();
    const counted = readerTelemetry.flushWindow().filter((b) => b.mode === "replica-chat");
    const count = (engine: string, k: "spawns" | "fallbacks") => counted.filter((b) => b.engine === engine).reduce((n, b) => n + b[k], 0);
    assert.equal(count("pion", "spawns"), 1, `one Pion spawn: ${JSON.stringify(counted)}`);
    assert.equal(count("mb", "spawns"), 0, "no MoonBit spawn");
    assert.equal(count("pion", "fallbacks") + count("mb", "fallbacks"), 0, "no fallback");
    assert.equal(existsSync(work), false, "the fold is gone after");
    assert.equal(JSON.stringify(selected), JSON.stringify(mb), "the selected Pion reading is MoonBit's");
    // (where a shell script runs: the very arguments it was spawned with)
    if (process.platform !== "win32") {
      const log = join(c.data, "pion-spawns.log");
      const wrapper = join(c.data, "pion-wrap.sh");
      writeFileSync(wrapper, `#!/bin/sh\nprintf '%s\\n' "$*" >> ${JSON.stringify(log)}\nexec ${JSON.stringify(bins.pion)} "$@"\n`);
      chmodSync(wrapper, 0o755);
      use(wrapper);
      assert.equal(JSON.stringify(await read()), JSON.stringify(mb), "through the wrapper: the same reading");
      const spawns = readFileSync(log, "utf8").split("\n").filter((l) => l.includes("--builder replica-chat"));
      assert.deepEqual(spawns, [
        `--builder replica-chat --dir ${c.dir} --work ${work} --thread ${c.big} --entries ${CHAT_ENTRIES} --text ${CHAT_TEXT} --bytes ${CHAT_BYTES} --sep ${sep} --shell-dir ${join(c.data, "shell")}`,
      ]);
    }
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
});
