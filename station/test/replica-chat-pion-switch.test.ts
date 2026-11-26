// Dual-engine parity for one chat read from a copy (`--builder replica-chat`, replica/chat.ts): the MoonBit
// `stillfail-reader` and the Pion `stillfail-pion` read the same copy to the same JSON, byte for byte (multi-byte texts
// cut at a character's end, older entries left out past CHAT_BYTES, `earlier` counted, sessions that left ordered last,
// a chat the copy does not hold, a copy that is none, a `--thread` that is no number), each removing its scratch fold;
// and `STILLFAIL_READER_REPLICA_CHAT=pion` makes `readChatSoon` spawn the Pion program through the reader selection.
// Each reading is counted (ops, errors, time) as its engine's, a MoonBit one asked as Pion a fallback, which runs with
// no Pion built. The rest skips when no Pion binary is built here; strictly 0-skip with distinct binaries when
// STILLFAIL_REQUIRE_DUAL_READER=1.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { chmodSync, createReadStream, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, sep } from "node:path";
import { after, test } from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mbReaderBinary, pionBinary, resetReaderSelectionStateForTest, resolveReaderSelectionAsync } from "../src/read/mb-reader.ts";
import { readerTelemetry } from "../src/read/reader-telemetry.ts";
import { CHAT_BYTES, CHAT_ENTRIES, CHAT_READ_TIMEOUT, CHAT_SESSIONS, CHAT_TEXT, readChatSoon } from "../src/replica/chat.ts";
import { nothingTold } from "../src/replica/export.ts";
import { Store } from "../src/store/store.ts";
import { InlineRunner } from "./reference/replica-work.ts";
import { HOME, ORIGIN, attach, chat, dataDir } from "./replica-fakes.ts";
import { pinnedPion } from "./pion-pinned.ts";

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
    if (requireDual || pinnedPion()) assert.fail(`STILLFAIL_PION_READER is required (${pinnedPion() ?? "unset"}) but resolved to null`);
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

test("replica-chat: 20 large sessions exceeding --bytes (65536) stay within budget and 0-diff across MB and Pion", async (t) => {
  const bins = binaries(t);
  if (bins === null) return;
  const data = dataDir("chatsw-big-sessions");
  cleanup.push(data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const tid = chat(store, data, "chat:s0", null, 5);
  const longPath = "/" + "路径".repeat(320);
  const longTitle = "标".repeat(320);
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
  assert.equal(gens.length, 1);
  const dir = join(own, gens[0]!);
  const budget = 65536;
  const lines = raw(bins, { data, dir }, String(tid), { entries: CHAT_ENTRIES, text: CHAT_TEXT, bytes: budget });
  sameLines(lines, "20 large sessions at --bytes 65536");
  assert.ok(Buffer.byteLength(lines.pion, "utf8") <= budget, `stdout ${Buffer.byteLength(lines.pion, "utf8")} > ${budget}`);
  const parsed = JSON.parse(lines.pion).chat;
  assert.ok(parsed.sessions.length > 0 && parsed.sessions.length < CHAT_SESSIONS, `expected trimmed sessions, got ${parsed.sessions.length}`);
});

test("replica-chat: oversized head.name (65536 ASCII) and U+2028/U+2029 escaped sessions stay <= 65536 raw stdout bytes and 0-diff across MB and Pion", async (t) => {
  const bins = binaries(t);
  if (bins === null) return;
  const data = dataDir("chatsw-head-u2028");
  cleanup.push(data);
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
  assert.equal(gens.length, 1);
  const dir = join(own, gens[0]!);
  const headPath = join(dir, "head.json");
  const head = JSON.parse(readFileSync(headPath, "utf8"));
  head.name = "N".repeat(65536);
  head.made = "M".repeat(65536);
  writeFileSync(headPath, JSON.stringify(head));

  const budget = 65536;
  const present = raw(bins, { data, dir }, String(tid), { entries: CHAT_ENTRIES, text: CHAT_TEXT, bytes: budget });
  sameLines(present, "oversized head.name + non-numeric head.made + U+2028/U+2029 sessions (present thread)");
  assert.ok(Buffer.byteLength(present.pion, "utf8") <= budget, `present stdout ${Buffer.byteLength(present.pion, "utf8")} > ${budget}`);
  assert.ok(present.pion.includes("\\u2028") && present.pion.includes("\\u2029"));
  const parsedPresent = JSON.parse(present.pion).chat;
  assert.equal(parsedPresent.name.length, 400);
  assert.equal(parsedPresent.made, 0);
  assert.ok(parsedPresent.sessions.length > 0 && parsedPresent.sessions.length < CHAT_SESSIONS);

  const missing = raw(bins, { data, dir }, "987654", { entries: CHAT_ENTRIES, text: CHAT_TEXT, bytes: budget });
  sameLines(missing, "oversized head.name + non-numeric head.made (missing thread)");
  assert.ok(Buffer.byteLength(missing.pion, "utf8") <= budget, `missing stdout ${Buffer.byteLength(missing.pion, "utf8")} > ${budget}`);
  const parsedMissing = JSON.parse(missing.pion).chat;
  assert.equal(parsedMissing.thread, null);
  assert.equal(parsedMissing.name.length, 400);
  assert.equal(parsedMissing.made, 0);
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
    const count = (engine: string, k: "spawns" | "fallbacks" | "ops" | "errors") => counted.filter((b) => b.engine === engine).reduce((n, b) => n + b[k], 0);
    assert.equal(count("pion", "spawns"), 1, `one Pion spawn: ${JSON.stringify(counted)}`);
    assert.equal(count("mb", "spawns"), 0, "no MoonBit spawn");
    assert.equal(count("pion", "fallbacks") + count("mb", "fallbacks"), 0, "no fallback");
    // (the reading counted as Pion's, once, timed, and none an error)
    assert.equal(count("pion", "ops"), 1, `one Pion reading counted: ${JSON.stringify(counted)}`);
    assert.equal(count("pion", "errors"), 0, "none an error");
    assert.equal(count("mb", "ops"), 0, "none counted as MoonBit's");
    assert.ok(counted.some((b) => b.engine === "pion" && b.maxMs !== undefined), `its time counted: ${JSON.stringify(counted)}`);
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

test("replica-chat: Pion asked for and none there reads with MoonBit, counted as a fallback, each reading and refusal counted", async (t) => {
  const mb = mbReaderBinary();
  if (mb === null) {
    if (process.env.CI) assert.fail("stillfail-reader binary is required in CI");
    t.skip("stillfail-reader not built here (station/mb/build.sh)");
    return;
  }
  const c = await copied();
  const names = ["STILLFAIL_PION_READER", "STILLFAIL_MB_READER", "STILLFAIL_READER_REPLICA_CHAT", "STILLFAIL_READER_ENGINE"] as const;
  const saved = names.map((k) => [k, process.env[k]] as const);
  try {
    process.env.STILLFAIL_PION_READER = join(c.data, "no-pion-here");
    process.env.STILLFAIL_MB_READER = mb;
    process.env.STILLFAIL_READER_REPLICA_CHAT = "pion";
    delete process.env.STILLFAIL_READER_ENGINE;
    resetReaderSelectionStateForTest();
    const chosen = await resolveReaderSelectionAsync("replica-chat", { logAt: "replica" });
    assert.equal(chosen.engine, "mb");
    assert.equal(chosen.selection.fallback, true);
    readerTelemetry.flushWindow();
    const work = join(c.data, "replica", "chat-fallback.db");
    const read = await readChatSoon({ dir: c.dir, work, thread: c.big, shellDir: join(c.data, "shell") });
    assert.equal(read.thread?.id, c.big);
    // (a copy that is none: refused, and that reading counted as an error)
    const empty = join(c.data, "no-copy-fallback");
    mkdirSync(empty, { recursive: true });
    writeFileSync(join(empty, "head.json"), JSON.stringify({ v: 1, origin: ORIGIN }));
    await assert.rejects(readChatSoon({ dir: empty, work, thread: c.big, shellDir: join(c.data, "shell") }), /no copy here/);
    const counted = readerTelemetry.flushWindow().filter((b) => b.mode === "replica-chat");
    const count = (engine: string, k: "spawns" | "fallbacks" | "ops" | "errors") => counted.filter((b) => b.engine === engine).reduce((n, b) => n + b[k], 0);
    assert.equal(count("mb", "spawns"), 2, `two MoonBit spawns: ${JSON.stringify(counted)}`);
    assert.equal(count("pion", "spawns"), 0, "no Pion spawn");
    assert.equal(count("pion", "fallbacks"), 2, `each spawn a fallback from Pion: ${JSON.stringify(counted)}`);
    assert.equal(count("mb", "ops"), 2, "both readings counted as MoonBit's");
    assert.equal(count("mb", "errors"), 1, "the refusal an error");
    assert.equal(existsSync(work), false, "the fold is gone after");
  } finally {
    for (const [k, v] of saved) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
    resetReaderSelectionStateForTest();
  }
});

test("replica-chat: a reading called off is not counted; one called off as taking too long is a failed reading, timed", { skip: process.platform === "win32" && "a shell script stands in for the program" }, async () => {
  // (a program that never answers, by the MoonBit reader's name: the reading is settled only by its calling off)
  const dir = dataDir("chat-stops");
  cleanup.push(dir);
  const hangs = join(dir, "stillfail-reader");
  writeFileSync(hangs, "#!/bin/sh\nexec sleep 600\n");
  chmodSync(hangs, 0o755);
  const calledOff = async (reason?: unknown) => {
    const stop = new AbortController();
    const reading = readChatSoon({ dir, work: join(dir, "chat.db"), thread: 1, shellDir: join(dir, "shell"), binary: hangs, signal: stop.signal });
    // (past the selection's microtasks: the program is spawned, its reading under way)
    await new Promise<void>((r) => setImmediate(r));
    stop.abort(reason);
    await assert.rejects(reading, /called off/);
    return readerTelemetry.flushWindow().filter((b) => b.mode === "replica-chat" && b.engine === "mb");
  };
  readerTelemetry.flushWindow();
  const plain = await calledOff();
  assert.equal(plain.reduce((n, b) => n + b.spawns, 0), 1, `spawned once: ${JSON.stringify(plain)}`);
  assert.equal(plain.reduce((n, b) => n + b.ops + b.errors, 0), 0, `called off: no reading counted: ${JSON.stringify(plain)}`);
  const late = await calledOff(CHAT_READ_TIMEOUT);
  assert.equal(late.reduce((n, b) => n + b.ops, 0), 1, `took too long: one reading counted: ${JSON.stringify(late)}`);
  assert.equal(late.reduce((n, b) => n + b.errors, 0), 1, "a failed one");
  assert.ok(late.some((b) => b.maxMs !== undefined), `its time counted: ${JSON.stringify(late)}`);
});

test("replica-chat: a program that answered and does not end, called off as taking too long, is a failed reading; called off otherwise, its answer", { skip: process.platform === "win32" && "a shell script stands in for the program" }, async () => {
  // (a program by the MoonBit reader's name that answers a chat, then says so on a FIFO the test reads, then stays: its
  // answer read by the time the FIFO's word is, as it came first on a pipe already read)
  const dir = dataDir("chat-answered");
  cleanup.push(dir);
  const said = join(dir, "said");
  execFileSync("mkfifo", [said]);
  const answer = JSON.stringify({ chat: { origin: ORIGIN, workspace: HOME, gen: "g1", name: "n", made: 1, to: 2, thread: null, entries: [], earlier: 0, sessions: [] } });
  const stays = join(dir, "stillfail-reader");
  writeFileSync(stays, `#!/bin/sh\nprintf '%s\\n' '${answer}'\nprintf x > ${JSON.stringify(said)}\nexec sleep 600\n`);
  chmodSync(stays, 0o755);
  const calledOff = async (reason?: unknown) => {
    const heard = new Promise<void>((resolve, reject) => {
      const s = createReadStream(said);
      s.once("data", () => {
        s.destroy();
        resolve();
      });
      s.once("error", reject);
    });
    const stop = new AbortController();
    const reading = readChatSoon({ dir, work: join(dir, "chat.db"), thread: 1, shellDir: join(dir, "shell"), binary: stays, signal: stop.signal });
    await heard;
    await new Promise<void>((r) => setImmediate(r));
    stop.abort(reason);
    const got = await reading.then((chat) => ({ chat }), (e: unknown) => ({ error: messageOf(e) }));
    return { got, counted: readerTelemetry.flushWindow().filter((b) => b.mode === "replica-chat" && b.engine === "mb") };
  };
  readerTelemetry.flushWindow();
  const plain = await calledOff();
  assert.equal("chat" in plain.got && plain.got.chat.gen, "g1", `called off after its answer: the answer: ${JSON.stringify(plain.got)}`);
  assert.equal(plain.counted.reduce((n, b) => n + b.ops, 0), 1, `one reading counted: ${JSON.stringify(plain.counted)}`);
  assert.equal(plain.counted.reduce((n, b) => n + b.errors, 0), 0, "not a failed one");
  const late = await calledOff(CHAT_READ_TIMEOUT);
  assert.match("error" in late.got ? late.got.error : "", /called off/, `took too long: refused: ${JSON.stringify(late.got)}`);
  assert.equal(late.counted.reduce((n, b) => n + b.ops, 0), 1, `took too long: one reading counted: ${JSON.stringify(late.counted)}`);
  assert.equal(late.counted.reduce((n, b) => n + b.errors, 0), 1, "a failed one, though it had answered");
  assert.ok(late.counted.some((b) => b.maxMs !== undefined), `its time counted: ${JSON.stringify(late.counted)}`);
});
