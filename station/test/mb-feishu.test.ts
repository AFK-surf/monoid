// Feishu in MoonBit (station/mb src/feishu: `stillfail-reader-harness --builder harness-feishu`) held to the TypeScript it replaces
// (src/feishu/) on the same inputs: the long connection's frames byte for byte (encoded, decoded, refused, put together
// from parts), what each kind of event says, the cards and rich text posted, the connects as config.json says them,
// the OpenAPI client against a stand-in (its token, its retries, its files and its refusals), the surface (what it
// gives the station of each event and answers Feishu, what it posts, uploads, edits, reads back and asks, its status
// card through a turn, its threads' file), the apps made by a scan (the device flow, its file, its saves) and
// feishu_api. Each case is given both whole, on the same clock and the same stand-in; their outcomes must be the same.
import assert from "node:assert/strict";
import { type ChildProcess, type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import crypto from "node:crypto";
import fsp from "node:fs/promises";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { extname, join } from "node:path";
import { createInterface } from "node:readline";
import { gunzipSync } from "node:zlib";
import { after, mock, test } from "node:test";
import { Effect, Exit, Scope } from "effect";
import { TestClock } from "effect/testing";
import { endedWords } from "../src/connects/card-ends.ts";
import type { SocketHooks } from "../src/connects/surface.ts";
import { answeredCard, doneCard, endedCard, entity, inline, questionCard, textPosts, took, workingCard } from "../src/feishu/cards.ts";
import { Parts, decode, encode, type Frame } from "../src/feishu/frame.ts";
import { feishuConnects, maskSecret, makeFeishu } from "../src/feishu/index.ts";
import { cardAnswerOf, listedAsEvent, messageOf, resourceOf, resourceUrl } from "../src/feishu/parse.ts";
import { ADDONS, Registrations, encodeAddons, shownRegistration } from "../src/feishu/register.ts";
import { FeishuSurface, verifyFeishuApp } from "../src/feishu/surface.ts";
import { FeishuThreads } from "../src/feishu/threads.ts";
import { FEISHU_API, feishuTools } from "../src/feishu/tool.ts";
import { FeishuClient, FeishuFile, domainOf } from "../src/feishu/web.ts";
import { wall } from "../src/ops/fibers.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { log } from "../src/ops/log.ts";
import { mbHarnessBinary } from "./mb-harness.ts";

type Json = any;

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
const ROOT = join(import.meta.dirname, "..", "..");

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `mb-feishu-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-feishu", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  child.on("exit", (code) => {
    for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` }));
  });
  program = {
    child,
    next: (line) =>
      new Promise((resolve) => {
        waiting.push((answer) => resolve(JSON.parse(answer)));
        child.stdin.write(`${line}\n`);
      }),
  };
  return program;
}
// (the program waited for till it is gone, its directories after: one still running at the file's end is a leftover)
after(async () => {
  if (program !== null) await ended(program.child);
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

/// What MoonBit says of `c` (its `ok`), failing on what it could not work out.
async function mb(c: unknown): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
const outcome = (f: () => unknown) => {
  try {
    return { ok: plain(f()) };
  } catch (e) {
    return { error: (e as Error).message };
  }
};
const hex = (b: Uint8Array) => Buffer.from(b).toString("hex");
const unhex = (s: string) => new Uint8Array(Buffer.from(s, "hex"));

/// A pure function of both, by its TypeScript name: the same outcome, or the same refusal.
async function same(fn: string, args: unknown[], ts: () => unknown, what = `${fn}(${JSON.stringify(args).slice(0, 200)})`) {
  const theirs = await harness().next(JSON.stringify({ op: "pure", fn, args }));
  assert.deepEqual(theirs, outcome(ts), what);
}

const ZH = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/zh/station.json"), "utf8"));
const EN = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/en/station.json"), "utf8"));
/// Both on the station's language `lang`.
async function stationIn(lang: "zh" | "en") {
  setStationLang(lang);
  await mb({ op: "catalog", zh: ZH, en: EN, lang });
}

const testClock = () => {
  const scope = Effect.runSync(Scope.make());
  const clock = Effect.runSync(Scope.provide(TestClock.make(), scope));
  return { clock, adjust: (ms: number) => Effect.runPromise(clock.adjust(`${ms} millis`)), close: () => Effect.runPromise(Scope.close(scope, Exit.void)) };
};

/// A deterministic stream of numbers (mulberry32).
function random(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ── frame.ts ──

const frameJson = (f: Frame) => ({
  seqId: f.seqId.toString(),
  logId: f.logId.toString(),
  service: f.service,
  method: f.method,
  headers: f.headers,
  ...(f.payloadEncoding !== undefined ? { payloadEncoding: f.payloadEncoding } : {}),
  ...(f.payloadType !== undefined ? { payloadType: f.payloadType } : {}),
  ...(f.payload !== undefined ? { payload: hex(f.payload) } : {}),
  ...(f.logIdNew !== undefined ? { logIdNew: f.logIdNew } : {}),
});
const frameOf = (j: Json): Frame => ({
  seqId: BigInt(j.seqId ?? "0"),
  logId: BigInt(j.logId ?? "0"),
  service: j.service ?? 0,
  method: j.method ?? 0,
  headers: j.headers ?? [],
  ...(j.payloadEncoding !== undefined ? { payloadEncoding: j.payloadEncoding } : {}),
  ...(j.payloadType !== undefined ? { payloadType: j.payloadType } : {}),
  ...(j.payload !== undefined ? { payload: unhex(j.payload) } : {}),
  ...(j.logIdNew !== undefined ? { logIdNew: j.logIdNew } : {}),
});

const FRAMES: Json[] = [
  { seqId: "0", logId: "0", service: 0, method: 0, headers: [] },
  { seqId: "12345678901234", logId: "7", service: -3, method: 1, headers: [["type", "event"], ["message_id", "m1"]], payload: "010203", logIdNew: "x" },
  { seqId: "18446744073709551615", logId: "18446744073709551616", service: 2147483647, method: -2147483648, headers: [["", ""]] },
  { seqId: "-1", logId: "-9223372036854775808", service: -1, method: 1, headers: [["键", "值 🙂"], ["type", "card"]], payloadEncoding: "", payloadType: "json", payload: "" },
  { seqId: "1", logId: "2", service: 99, method: 1, headers: [["lone", "\ud800x"], ["x\udc00", "y"]], payloadType: "﻿bom", payload: "ff00" },
  { seqId: "300", logId: "16384", service: 128, method: 0, headers: [["type", "ping"]], logIdNew: "日志" },
];

test("frames: what each encodes is the same bytes; what each reads of any bytes the same frame or the same refusal", { skip }, async () => {
  for (const f of FRAMES) await same("encode", [f], () => hex(encode(frameOf(f))));
  const decodes = (h: string) => same("decode", [h], () => frameJson(decode(unhex(h))));
  for (const f of FRAMES) await decodes(hex(encode(frameOf(f))));
  for (const h of [
    "", "08", "0880", "08ffffffffffffffffffffff01", "08ffffffffffffffffffff7f", "08ffffffffffffffffffffff7f", "088080808080808080808001",
    // unknown fields of each wire type, a wire type with no meaning, a field cut short
    "0801" + "5101020304050607080900" + "5d01020304" + "6205616263646500", "0801" + "13", "0801" + "1f", "0801" + "6203", "0801" + "51010203",
    // a header with fields of its own and its key and value twice; a BOM; bytes no UTF-8 reads
    "2a0e0a01611201620a0163120164180120", "2a080a03efbbbf6b1201ff", "32056162c3a8ff", "3a00", "42" + "02" + "ffff", "4a03e282", "2a020803",
    // a tag of a field past 2^28, its varint long; the same field said twice
    "f8ffffff0f01", "80808080800101", "0801" + "0802", "180318ffffffffffffffffff01", "2003" + "2080808080f0ffffffff01",
    // a length past what is there, a huge one
    "42ffffffff0f", "42ffffffffffffffff7f00",
  ]) await decodes(h);
  const next = random(1);
  for (let i = 0; i < 400; i++) {
    const n = Math.floor(next() * 24);
    const bytes = Array.from({ length: n }, () => (next() < 0.3 ? [0x08, 0x10, 0x18, 0x20, 0x2a, 0x32, 0x3a, 0x42, 0x4a, 0x80, 0xff][Math.floor(next() * 11)]! : Math.floor(next() * 256)));
    await decodes(hex(new Uint8Array(bytes)));
  }
});

test("frames: parts are put together once all are in, in their order, and dropped once old", { skip }, async () => {
  const part = (id: string, sum: string | undefined, seq: string | undefined, payload: string) => ({
    seqId: "0", logId: "0", service: 1, method: 1, payload,
    headers: [["message_id", id], ...(sum !== undefined ? [["sum", sum]] : []), ...(seq !== undefined ? [["seq", seq]] : [])],
  });
  const runs: Json[][] = [
    [{ add: part("a", "2", "1", "0304"), now: 0 }, { add: part("a", "2", "0", "0102"), now: 5 }],
    [{ add: part("a", undefined, undefined, "aa"), now: 0 }, { add: part("b", "1", "0", "bb"), now: 0 }, { add: { ...part("c", "0", "0", ""), payload: undefined }, now: 0 }],
    [{ add: part("a", "3", "0", "01"), now: 0 }, { add: part("b", "2", "1", "02"), now: 10 }, { drop: 5 }, { add: part("a", "3", "1", "03"), now: 20 }, { add: part("b", "2", "0", "04"), now: 30 }],
    [{ add: part("a", "2", "0", "01"), now: 0 }, { add: part("a", "5", "1", "02"), now: 0 }],
    [{ add: part("x", "2", "0.5", "01"), now: 0 }, { add: part("x", "2", "-1", "02"), now: 0 }, { add: part("x", "2", "2", "03"), now: 0 }, { add: part("x", "2", "NaN", "04"), now: 0 }, { add: part("x", "2", " 1 ", "05"), now: 0 }, { add: part("x", "2", "0x0", "06"), now: 0 }],
    [{ add: part("y", "2.5", "0", "01"), now: 0 }, { add: part("y", "1e10", "0", "01"), now: 0 }, { add: part("y", "Infinity", "0", "01"), now: 0 }, { add: part("y", "", "0", "09"), now: 0 }, { add: part("y", "abc", "0", "09"), now: 0 }],
    [{ add: part("z", "2", "0", "01"), now: 0 }, { add: part("z", "2", "0", "02"), now: 0 }, { add: part("z", "2", "1", "03"), now: 0 }],
  ];
  for (const steps of runs) {
    const parts = new Parts();
    const ts: Json[] = [];
    for (const s of steps) {
      if ("drop" in s) {
        parts.drop(s.drop);
        ts.push(null);
      } else ts.push(outcome(() => { const w = parts.add(frameOf(s.add), s.now); return w === null ? null : hex(w); }));
    }
    assert.deepEqual(await mb({ op: "parts", steps }), { steps: ts, open: (parts as any).open.size }, JSON.stringify(steps));
  }
});

// ── parse.ts ──

const sender = (type = "user", open = "ou_ann") => ({ sender_type: type, sender_id: { open_id: open } });
const msg = (fields: Json) => ({ message_id: "om_1", chat_id: "oc_g", chat_type: "group", create_time: "1700000000123", ...fields });
const EVENTS: Json[] = [
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "hello" }) }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "@_user_1 新会话" }), mentions: [{ key: "@_user_1", name: "Codex 机器人", id: { open_id: "ou_bot" } }] }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "@_user_1  /NEW " }), mentions: [{ key: "@_user_1", name: "Bot", id: { open_id: "ou_bot" } }, { key: "@_user_2", id: { open_id: "ou_bo" } }] }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "New Session" }), chat_type: "p2p" }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "new session @someone x" }), chat_type: "p2p" }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "@_user_1 a @_user_1 b" }), mentions: [{ key: "@_user_1", name: "", id: { open_id: "ou_x" } }, { key: "", name: "skip" }, null, "str"] }) },
  { sender: sender(), message: msg({ message_type: "text", content: "not json", thread_id: "omt_1", root_id: "om_r", parent_id: "om_p" }) },
  { sender: sender(), message: msg({ message_type: "text", content: "", thread_id: "", create_time: "abc" }) },
  { sender: sender(), message: msg({ message_type: "text", content: JSON.stringify({ text: "x" }), create_time: " 0x10 " }) },
  { sender: sender("app"), message: msg({ message_type: "text", content: JSON.stringify({ text: "mine" }) }) },
  { sender: sender("user", ""), message: msg({}) },
  { sender: sender(), message: msg({ message_id: "" }) },
  { sender: sender(), message: msg({ chat_id: "" }) },
  null, {}, { sender: null, message: null }, "str", [1, 2],
  { sender: sender(), message: msg({ message_type: "image", content: JSON.stringify({ image_key: "img_1" }), mentions: [{ key: "@_user_1", id: { open_id: "ou_bot" } }] }) },
  { sender: sender(), message: msg({ message_type: "image", content: JSON.stringify({}) }) },
  { sender: sender(), message: msg({ message_type: "file", content: JSON.stringify({ file_key: "f_1", file_name: "a.pdf" }) }) },
  { sender: sender(), message: msg({ message_type: "file", content: JSON.stringify({ file_key: "f_1" }) }) },
  { sender: sender(), message: msg({ message_type: "audio", content: JSON.stringify({ file_key: "f_2" }) }) },
  { sender: sender(), message: msg({ message_type: "media", content: JSON.stringify({ file_key: "f_3", file_name: "" }) }) },
  { sender: sender(), message: msg({ message_type: "sticker", content: "{}" }) },
  { sender: sender(), message: msg({ message_type: "", content: "{}" }) },
  { sender: sender(), message: msg({ message_type: "interactive", content: "{}", mentions: [{ id: { open_id: "ou_bot" } }] }) },
  {
    sender: sender(),
    message: msg({
      message_type: "post",
      content: JSON.stringify({
        title: "  Title ",
        content: [
          [{ tag: "text", text: "bold", style: ["bold", "italic"] }, { tag: "text", text: "strike", style: ["lineThrough"] }, { tag: "a", text: "", href: "https://x" }, { tag: "a", text: "t", href: "h" }],
          [{ tag: "at", user_id: "ou_bot", user_name: "Bot" }, { tag: "at", open_id: "ou_x" }, { tag: "img", image_key: "ik" }, { tag: "img" }, { tag: "media", file_key: "mk", file_name: "v.mov" }, { tag: "media", file_key: "mk2" }],
          [{ tag: "code_block", language: "TypeScript", text: "let a = 1\n\n" }, { tag: "md", text: "**md**" }, { tag: "emotion", emoji_type: "SMILE" }, { tag: "hr" }, { tag: "unknown" }, null, 5],
          "not an array",
        ],
      }),
    }),
  },
  { sender: sender(), message: msg({ message_type: "post", content: JSON.stringify({ zh_cn: { title: "", content: [[{ tag: "text", text: "  新会话  " }]] } }), chat_type: "p2p" }) },
  { sender: sender(), message: msg({ message_type: "post", content: JSON.stringify({ "2": { content: [[{ tag: "text", text: "two" }]] }, "1": { content: [[{ tag: "text", text: "one" }]] }, en_us: { content: [] } }) }) },
  { sender: sender(), message: msg({ message_type: "post", content: JSON.stringify([{ content: [[{ tag: "text", text: "in an array" }]] }]), mentions: [{ id: { open_id: "ou_bot" } }] }) },
  { sender: sender(), message: msg({ message_type: "post", content: "\"just a string\"" }) },
  { sender: sender(), message: msg({ message_type: "post", content: "null" }) },
  { sender: sender(), message: msg({ message_type: "post", content: JSON.stringify({ content: [[{ tag: "code_block", language: "İSTANBUL", text: "x" }]] }) }) },
];

const ITEMS: Json[] = [
  { message_id: "om_1", msg_type: "text", body: { content: JSON.stringify({ text: "@_user_1 hi" }) }, sender: { id: "ou_ann", sender_type: "user" }, mentions: [{ key: "@_user_1", name: "Bot", id: "ou_bot" }, { key: "@_user_2", id: { open_id: "ou_x" } }], chat_id: "oc_g", create_time: "1" },
  { message_id: "om_2", msg_type: "interactive", body: {}, sender: { id: "cli_x", sender_type: "app" }, chat_id: "oc_g" },
  { message_id: "om_3", content: "kept", message_type: "x", mentions: "not an array", sender: "str" },
  { "1": "a", "0": "b", message_id: "om_4" },
  null, "str", [1, 2], 5, {},
];

test("parse: what each event, listed message and card answer says is the same", { skip }, async () => {
  for (const bot of ["ou_bot", ""]) for (const e of EVENTS) await same("messageOf", [e, bot], () => messageOf(e, bot));
  for (const item of ITEMS) {
    await same("listedAsEvent", [item], () => listedAsEvent(item));
    await same("messageOf", [listedAsEvent(item), "ou_bot"], () => messageOf(listedAsEvent(item), "ou_bot"));
  }
  const answers: Json[] = [
    { operator: { open_id: "ou_ann" }, context: { open_chat_id: "oc_g", open_message_id: "om_c" }, action: { value: { sf: "answer", t: "om_t", l: "A" }, form_value: { answer: "x" } } },
    { operator: { open_id: "ou_ann" }, context: { open_chat_id: "oc_g" }, action: {} },
    { operator: { open_id: "" }, context: { open_chat_id: "oc_g" } },
    { operator: { open_id: "ou" }, context: {} },
    { operator: { open_id: "ou" }, context: { open_chat_id: "c" }, action: { value: null, form_value: null } },
    null, {},
  ];
  for (const a of answers) await same("cardAnswerOf", [a, "ev_1"], () => cardAnswerOf(a, "ev_1"));
  for (const [m, k, t] of [["om_1", "img_1", "image"], ["om:2", "k:3", "file"]] as const) await same("resourceUrl", [m, k, t], () => resourceUrl(m, k, t));
  for (const url of ["feishu:image:om_1:img_1", "feishu:file:om_1:a:b:c", "feishu:file::k", "feishu:file:m:", "feishu:video:m:k", "feishu:file:m:k\nx", "feishu:file:m\n:k", "feishu:image:om:k ", "x", ""]) {
    await same("resourceOf", [url], () => resourceOf(url));
  }
});

// ── cards.ts ──

const QUESTIONS: Json[] = [
  { type: "options", options: [{ label: "A", detail: "first" }, { label: "B", recommended: true, detail: "  " }, { label: 3 }, { recommended: "yes" }, null, { label: null, detail: 5 }] },
  { type: "options" },
  { type: "text", placeholder: "  sk_test_...  " },
  { type: "text", placeholder: "   " },
  { type: "text" },
  { type: "login" },
  null,
];

test("cards: the rich text, the question, answered and ended cards, the status cards and their words are the same", { skip }, async () => {
  for (const lang of ["zh", "en"] as const) {
    await stationIn(lang);
    const long = Array.from({ length: 900 }, (_, i) => `line ${i} <at id="ou_${i}"></at> <at id='x'> <at id=ou_z> <at id=bad` + (i % 7 === 0 ? "\n\n" : "\n")).join("");
    for (const t of ["", "  \n ", "hi <at id=ou_1></at>", "<at id=\"ou_2\" ><at id=ou_3'>", long, "中".repeat(6001), "🙂".repeat(3001), "a\n\n".repeat(4000)]) {
      await same("textPosts", [t], () => textPosts(t));
    }
    for (const q of QUESTIONS) for (const t of ["", "Pick one", "  "]) await same("questionCard", [t, q, "om_t", lang], () => questionCard(t, q, "om_t", lang));
    await same("answeredCard", ["Which?", "Ann", "B", lang], () => answeredCard("Which?", "Ann", "B", lang));
    await same("answeredCard", [" ", "", "", lang], () => answeredCard(" ", "", "", lang));
    await same("endedCard", ["Which?", "closed"], () => endedCard("Which?", "closed"));
    await same("endedCard", ["", "closed"], () => endedCard("", "closed"));
    for (const ms of [0, 499, 500, 1499, 1500, 59_499, 59_500, 61_000, 3_600_000, 3_599_499]) await same("took", [ms, lang], () => took(ms, lang));
    await same("workingCard", ["正在思考"], () => workingCard("正在思考"));
    await same("workingCard", [""], () => workingCard(""));
    for (const page of [null, "https://still.fail/s/x"]) await same("doneCard", [12_345, page, lang], () => doneCard(12_345, page, lang));
    for (const card of [{ type: "text" }, { type: "options" }, null]) {
      for (const end of [{ why: "message", by: "ou_a", byTs: "om_1" }, { why: "replaced" }, { why: "withdrawn" }, { why: "closed" }] as Json[]) {
        for (const name of [null, "", "Ann"]) await same("endedWords", [card, end, name, lang], () => endedWords(card, end, name, lang));
      }
    }
  }
  await stationIn("zh");
  await same("inline", [{ b: 1, a: [1, "x"], "1": null }], () => inline({ b: 1, a: [1, "x"], "1": null }));
  await same("entity", ["card_1"], () => entity("card_1"));
});

// ── index.ts, web.ts's pure parts, register.ts's addons, tool.ts's declaration and file names ──

const CONFIG: Json = {
  connects: [
    { id: "f1", kind: "feishu", feishu: { appId: "cli_a", appSecret: "sec", domain: "lark", threads: true, botName: "B", botImage: "https://i", botOpenId: "ou_b", tenant: { key: "t", name: "Co" } }, workspace: "w" },
    { id: 2, kind: "feishu", enabled: false, mode: "single-session", feishu: { threads: true, tenant: { key: "" }, botName: "" } },
    { kind: "feishu", enabled: 0, feishu: "nope", workspace: "" },
    { id: "s", kind: "slack" },
    { id: "f3", kind: "feishu", feishu: { appId: 5, appSecret: null, domain: "feishu", tenant: { key: "k", name: 7 } } },
    null,
    { id: null, kind: "feishu", feishu: { tenant: [] } },
  ],
};

test("index: the connects as config.json says them, their secrets masked, what tells their connections apart, what the overview shows and what is written of a bot seen", { skip }, async () => {
  for (const raw of [CONFIG, {}, null, { connects: "x" }]) await same("feishuConnects", [raw], () => feishuConnects(raw));
  for (const s of ["", "a", "abcd", "abcde", "密钥很长很长🙂"]) await same("maskSecret", [s], () => maskSecret(s));
  for (const v of ["lark", "feishu", "LARK", null, 1]) await same("domainOf", [v], () => domainOf(v));

  delete process.env.STILLFAIL_CONFIG;
  const { ConfigFile } = await import("../src/ops/config.ts");
  const { Store } = await import("../src/store/store.ts");
  const identities: Json[] = [
    { team: "Co", teamId: "t", url: "", botUserId: "ou_b", botName: "B", botImage: "https://i", botId: "" },
    { team: "New", teamId: "t2", url: "", botUserId: "ou_c", botName: "C", botImage: null, botId: "" },
    { team: "", teamId: "", url: "", botUserId: "ou_b", botName: "B", botImage: "https://i", botId: "" },
  ];
  const entries: Json[] = [
    CONFIG.connects[0],
    { id: "f1", kind: "feishu", feishu: { appId: "cli_a", appSecret: "sec", botImage: "https://old" } },
    { id: "f1", kind: "feishu", feishu: { appId: "cli_a", appSecret: "sec", botName: "B", botImage: "https://i", botOpenId: "ou_b" } },
    { id: "f1", kind: "feishu", feishu: null, mode: "single-session" },
  ];
  for (const entry of entries) {
    for (const identity of identities) {
      const t = testClock();
      const data = fresh("index");
      writeFileSync(join(data, "config.json"), JSON.stringify({ connects: [entry] }));
      const config = new ConfigFile(data);
      const store = Store.open(":memory:", null);
      const fake: Json = {
        cards: true, identity: () => identity, socket: () => ({ connected: true, lastError: null }), botUserId: () => identity.botUserId,
        listeners: [] as (() => void)[],
        onChange(l: () => void) { this.listeners.push(l); return () => {}; },
        async start() { for (const l of this.listeners) l(); },
        async stop() {},
        async refreshIdentity() {},
      };
      const feishu = makeFeishu({ data, store, config, clock: t.clock, receive: async () => {}, bound: () => true, create: () => fake });
      try {
        const connect = feishuConnects({ connects: [entry] })[0];
        const credentials = connect === undefined ? null : (feishu.connections as any).credentials(connect);
        assert.deepEqual(await mb({ op: "pure", fn: "credentials", args: [{ connects: [entry] }] }), credentials, "credentials");
        await feishu.reconcile();
        await new Promise((r) => setImmediate(r));
        await config.written();
        const written = config.raw().connects[0];
        const theirs = await mb({ op: "pure", fn: "seen", args: [{ connects: [entry] }, identity, entry] });
        if (credentials === null) assert.deepEqual(written, plain(entry), "a connect with no app is never connected");
        else assert.deepEqual(theirs === null ? plain(entry) : theirs, plain(written), `seen ${JSON.stringify([entry, identity])}`);
        const live = credentials === null ? null : identity;
        assert.deepEqual(await mb({ op: "pure", fn: "shown", args: [entry, live] }), plain(feishu.shown(entry)), "shown");
      } finally {
        await feishu.close();
        store.close();
        await t.close();
      }
    }
  }
});

test("pure: addresses, file names and types, the addons the link carries and feishu_api's declaration are the same", { skip }, async () => {
  const urls: [string, [string, string][]][] = [
    ["https://fake.test/open-apis/x", [["a", "b c"], ["中", "✓&="], ["a", "again"]]],
    ["https://fake.test/open-apis/x?keep=1&a=old&a=two#frag", [["a", "new"]]],
    ["https://fake.test/open-apis/x?k=a+b%20c", [["z", "1"]]],
    ["https://fake.test/open-apis/x?k=a+b%20c", []],
    ["https://Fake.Test:443/a/../b/./c d", [["*-._~!'()", "\ud800"]]],
    ["not a url", [["a", "b"]]],
    ["https://fake.test/open-apis/x?", [["e", ""]]],
  ];
  for (const [raw, query] of urls) {
    await same("urlWith", [raw, query], () => {
      const url = new URL(raw);
      for (const [k, v] of query) url.searchParams.set(k, v);
      return url.toString();
    });
  }
  for (const p of ["a.png", "a.tar.gz", ".bashrc", "..", "a.", "dir.d/file", "a/b.c/", "/x/y.JPG", "", ".", "...", "a..b", "é.日本"]) await same("extname", [p], () => extname(p));
  const dispositions = [
    "", "attachment", "attachment; filename=\"report.pdf\"", "attachment; filename=report.pdf", "attachment;filename=\"a\\\"b\\\\c.txt\"",
    "attachment; filename*=UTF-8''%E6%8A%A5%E5%91%8A.pdf", "attachment; filename=\"x.pdf\"; filename*=utf-8''%E2%9C%93.PDF",
    "attachment; filename*=UTF-8''%E6%8A%A5%E5", "attachment; filename=\"unterminated.txt", "filename=\"a\\\"", "attachment; FILENAME = \"spaced.docx\"",
    "attachment; filename=\"../../etc/passwd\"", "attachment; filename=\"con<>:|?*.txt. . \"", "attachment; filename=\"" + "长".repeat(40) + ".verylongextension123456\"",
    "attachment; filename=\"🙂🙂.png\"", "attachment; filename=\"no-ext\"", "attachment; filename=\".hidden\"", "attachment; filename=\"a\nb.txt\"", "inline;filename=x;filename=y",
    "attachment; filename*=UTF-8''", "attachment; filename*=UTF-8''%C0%AF.txt", "attachment; filename*=UTF-8''%ED%A0%80.txt", "; filename=semi.txt",
  ];
  const types = ["image/png", "IMAGE/JPEG; charset=x", "application/zip", "text/plain;q=1", "application/octet-stream", "", "Text/CSV"];
  // fileName is the tool's own: what it names a file is read off what the tool writes (below); here as the same text
  for (const d of dispositions) for (const t of types) {
    const theirs = await harness().next(JSON.stringify({ op: "pure", fn: "fileName", args: [t, d] }));
    assert.ok("ok" in theirs, d);
    dispositionCases.push([t, d, theirs.ok]);
  }
  const addons = await mb({ op: "pure", fn: "encodeAddons", args: [] });
  assert.deepEqual(JSON.parse(gunzipSync(Buffer.from(addons, "base64url")).toString()), ADDONS);
  assert.deepEqual(gunzipSync(Buffer.from(await encodeAddons(ADDONS), "base64url")).toString(), gunzipSync(Buffer.from(addons, "base64url")).toString());
  const next = random(7);
  for (let i = 0; i < 60; i++) {
    const s = Array.from({ length: Math.floor(next() * 3000) }, () => (next() < 0.6 ? "abcab "[Math.floor(next() * 6)] : String.fromCharCode(32 + Math.floor(next() * 3000)))).join("");
    assert.equal(gunzipSync(Buffer.from(await mb({ op: "pure", fn: "gzip", args: [s] }), "hex")).toString(), Buffer.from(s).toString(), "gzip");
  }
  assert.deepEqual(await mb({ op: "pure", fn: "toolDeclaration", args: [] }), plain(FEISHU_API));
});

/// File names the program gave (content type, disposition, name): held to what the tool writes, in the tool's test.
const dispositionCases: [string, string, string][] = [];

// ── a stand-in for Feishu, as both sides have it ──

let activity = 0;
const logs: Json[] = [];
/// What the TypeScript asked of the disk and is not yet answered: a case settles only once each is (the disk's turns
/// are the machine's, not the loop's).
const onDisk = new Set<Promise<unknown>>();
/// `p` kept in `onDisk` until it is answered.
function watched<T>(p: Promise<T>): Promise<T> {
  const kept = p.then(
    () => {},
    () => {},
  );
  onDisk.add(kept);
  void kept.then(() => {
    onDisk.delete(kept);
    activity++;
  });
  return p;
}
/// The TypeScript's reads and writes of files, each one awaited by `settle`: a file opened too (a private file is
/// written through its handle, then renamed into place), and what is done with its handle.
function watchDisk() {
  for (const name of ["readFile", "writeFile", "mkdir", "rename"] as const) {
    const real = fsp[name] as (...args: unknown[]) => Promise<unknown>;
    mock.method(fsp, name, (...args: unknown[]) => watched(real(...args)));
  }
  const open = fsp.open;
  mock.method(fsp, "open", (...args: Parameters<typeof fsp.open>) =>
    watched(
      open(...args).then((fh) => {
        for (const name of ["writeFile", "sync", "close"] as const) {
          const real = (fh[name] as (...a: unknown[]) => Promise<unknown>).bind(fh);
          (fh as unknown as Record<string, unknown>)[name] = (...a: unknown[]) => watched(real(...a));
        }
        return fh;
      }),
    ),
  );
  syncBuiltinESMExports();
}
for (const level of ["info", "warn", "error"] as const) {
  mock.method(log, level, (area: string, words: string) => {
    if (area === "feishu") {
      logs.push([level, area, words]);
      activity++;
    }
  });
}

/// Feishu's OpenAPI and accounts as the case says (`routes`: each `METHOD /path`'s answers, the last again), and the
/// machine's time (`wall`) moved only by what sleeps on it.
class World {
  routes: Record<string, Json[]>;
  used = new Map<string, number>();
  seen: Json[] = [];
  sleeps: number[] = [];
  wall: number;
  constructor(c: Json) {
    this.routes = c.routes ?? {};
    this.wall = c.wall ?? 0;
  }
  async fetch(input: string | URL | Request, init?: RequestInit): Promise<Response> {
    const req = new Request(input, init);
    const body = init?.body === undefined || init?.body === null ? null : hex(new Uint8Array(await req.arrayBuffer()));
    this.seen.push({ method: req.method, url: req.url, headers: [...req.headers], body });
    activity++;
    const route = `${req.method} ${new URL(req.url).pathname}`;
    const list = this.routes[route] ?? [];
    let spec: Json;
    if (list.length === 0) spec = route === "POST /open-apis/auth/v3/tenant_access_token/internal" ? { json: { code: 0, tenant_access_token: "t-1", expire: 7200 } } : { json: { code: 0, data: {} } };
    else {
      const n = this.used.get(route) ?? 0;
      this.used.set(route, n + 1);
      spec = list[Math.min(n, list.length - 1)];
    }
    if (typeof spec.fail === "string") throw new TypeError(spec.fail);
    const headers: [string, string][] = Object.entries(spec.headers ?? {}).map(([k, v]) => [k.toLowerCase(), String(v)]);
    let bytes: Uint8Array;
    if (spec.json !== undefined) {
      if (!headers.some(([k]) => k === "content-type")) headers.push(["content-type", "application/json"]);
      bytes = new TextEncoder().encode(JSON.stringify(spec.json));
    } else if (typeof spec.hex === "string") bytes = unhex(spec.hex);
    else {
      if (!headers.some(([k]) => k === "content-type") && spec.text !== undefined) headers.push(["content-type", "text/plain;charset=UTF-8"]);
      bytes = new TextEncoder().encode(spec.text ?? "");
    }
    return new Response(bytes as Uint8Array<ArrayBuffer>, { status: spec.status ?? 200, headers });
  }
  install() {
    mock.method(globalThis, "fetch", (input: string | URL | Request, init?: RequestInit) => this.fetch(input, init));
    mock.method(wall, "now", () => this.wall);
    mock.method(wall, "sleep", async (ms: number) => {
      this.sleeps.push(ms);
      this.wall += ms;
    });
    watchDisk();
  }
}

/// A multipart body's parts: each one's head lines and its bytes.
function partsOf(bytes: Buffer, boundary: string) {
  const delim = Buffer.from(`--${boundary}`);
  const out: Json[] = [];
  let at = bytes.indexOf(delim);
  while (at >= 0) {
    const start = at + delim.length;
    if (bytes.subarray(start, start + 2).toString() === "--") break;
    const next = bytes.indexOf(delim, start);
    const part = bytes.subarray(start + 2, next - 2);
    const split = part.indexOf("\r\n\r\n");
    out.push({ head: part.subarray(0, split).toString(), body: hex(part.subarray(split + 4)) });
    at = next;
  }
  return out;
}

/// A request as both are compared: its method, its whole address, its bearer, its body's type and the body (JSON and
/// forms as their text, a multipart body as its parts).
function request(r: Json) {
  const headers = new Map<string, string>(r.headers.map(([k, v]: [string, string]) => [k.toLowerCase(), v]));
  const type = headers.get("content-type") ?? null;
  const bytes = r.body === null ? null : Buffer.from(r.body, "hex");
  let body: Json = null;
  if (bytes !== null) body = type?.startsWith("multipart/form-data") ? partsOf(bytes, /boundary=(.*)$/.exec(type)![1]!) : bytes.toString("utf8");
  return { method: r.method, url: r.url, auth: headers.get("authorization") ?? null, type: type === null ? null : type.replace(/; ?boundary=.*$/, ""), body };
}

/// What the stand-in saw, as both are compared.
const requests = (seen: Json[]) => seen.map(request);

/// Waits till what was set going has gone as far as it goes on the case's clock: three turns in a row with nothing
/// new asked, said or written.
async function settle(t: ReturnType<typeof testClock>, extra: () => Promise<unknown> = async () => {}) {
  let quiet = 0;
  for (let round = 0; quiet < 3; round++) {
    if (round > 2000) throw new Error("the case never settled");
    const before = activity;
    await t.adjust(0);
    await new Promise((r) => setImmediate(r));
    await extra();
    while (onDisk.size > 0) await Promise.all([...onDisk]);
    quiet = activity === before ? quiet + 1 : 0;
  }
}

/// A step's outcome once settled: what it gave, what it threw, or that it still waits.
async function step(t: ReturnType<typeof testClock>, f: () => unknown, extra?: () => Promise<unknown>): Promise<Json> {
  let done = false;
  let value: unknown;
  let error: unknown;
  void (async () => f())().then(
    (v) => ((done = true), (value = v)),
    (e) => ((done = true), (error = e)),
  );
  await settle(t, extra);
  if (!done) return { pending: true };
  return error !== undefined ? { error: (error as Error).message } : { ok: plain(value) };
}

// ── web.ts ──

test("client: its token, kept and taken again; its retries of a limit; its answers, files and refusals; a file's download; the long connection's address", { skip }, async () => {
  const token = (code: number, expire?: number, value = "t-1") => ({ json: { code, tenant_access_token: value, ...(expire !== undefined ? { expire } : {}) } });
  const cases: Json[] = [
    {
      routes: {
        "GET /open-apis/x": [{ status: 429, headers: { "retry-after": "2" } }, { status: 429, headers: { "x-ogw-ratelimit-reset": "100" } }, { json: { code: 99991400 } }, { status: 429, headers: { "retry-after": "abc" } }, { status: 429 }, { json: { code: 0, data: { a: 1 } } }],
        "POST /open-apis/y": [{ json: { code: 230020, msg: "slow" }, headers: { "x-ogw-ratelimit-reset": "-1" } }, { json: { code: 1, msg: "bad" } }],
      },
      steps: [{ call: "api", method: "GET", path: "/open-apis/x", query: { a: "b c", n: 5 } }, { call: "api", method: "POST", path: "/open-apis/y", body: { k: "v", "1": [true] } }],
    },
    {
      routes: { "POST /open-apis/auth/v3/tenant_access_token/internal": [token(0, 700, "t-a"), token(0, undefined, "t-b"), token(0, 7200, "t-c")] },
      steps: [{ call: "tenantToken" }, { call: "tenantToken" }, { call: "pass", ms: 59_999 }, { call: "tenantToken" }, { call: "pass", ms: 1 }, { call: "tenantToken" }, { call: "pass", ms: 6_600_000 }, { call: "tenantToken" }],
    },
    {
      routes: { "POST /open-apis/auth/v3/tenant_access_token/internal": [{ json: { code: 0 } }, { json: { code: 0, tenant_access_token: "" } }, { json: { code: 10003, msg: "invalid app" } }, { text: "not json", status: 500 }, { fail: "fetch failed" }] },
      steps: [{ call: "tenantToken" }, { call: "tenantToken" }, { call: "tenantToken" }, { call: "tenantToken" }, { call: "tenantToken" }],
    },
    {
      routes: {
        "POST /open-apis/auth/v3/tenant_access_token/internal": [token(0, 7200, "t-1"), token(0, 7200, "t-2")],
        "GET /open-apis/z": [{ json: { code: 99991663, msg: "token invalid" } }, { json: { code: 0, data: "again" } }],
        "GET /open-apis/w": [{ json: { code: 99991661, msg: "token invalid" } }, { json: { code: 99991661, msg: "still" } }],
      },
      steps: [{ call: "api", method: "GET", path: "/open-apis/z" }, { call: "api", method: "GET", path: "/open-apis/w" }],
    },
    {
      routes: {
        "GET /open-apis/f": [
          { hex: "89504e47", headers: { "content-type": "image/png", "content-disposition": "attachment; filename=\"a.png\"" } },
          { hex: "00", headers: { "content-type": "application/octet-stream" }, status: 404 },
          { json: { code: 0, data: 1 }, headers: { "content-type": "application/problem+json; charset=utf-8" } },
          { json: { code: 0 }, headers: { "content-type": "Application/JSON" } },
          { hex: "efbbbf7b22636f6465223a307d", headers: { "content-type": "application/vnd+json+x" } },
          { hex: "efbbbf7b22636f6465223a307d", headers: { "content-type": "text/json" } },
          { text: "", headers: {} },
          { text: "<html>", status: 502, headers: { "content-type": "text/html" } },
          { text: "", status: 503, headers: { "content-type": "application/json" } },
          { text: "{\"code\":\"7\"}", status: 400, headers: { "content-type": "application/json" } },
          { text: "{\"msg\":5}", status: 401, headers: { "content-type": "application/json ;x" } },
          { text: "x".repeat(300) + "🙂", status: 200, headers: { "content-type": "a+json" } },
        ],
      },
      steps: Array.from({ length: 12 }, () => ({ call: "api", method: "GET", path: "/open-apis/f", takeFile: true })),
    },
    {
      steps: [
        { call: "api", method: "POST", path: "/open-apis/im/v1/images", body: { image_type: "message", n: 1, o: { a: "b\r\nc" }, "line": "a\nb\rc\r\nd" }, files: [{ field: "image", hex: "0102", name: "a\"b\n.png", mime: "application/octet-stream" }, { field: "f\"x", hex: "", name: "名.txt", mime: "" }] },
        { call: "api", method: "DELETE", path: "/open-apis/d" },
        { call: "api", method: "GET", path: "/open-apis/g", body: { ignored: true } },
        { call: "api", method: "GET", path: "/open-apis/bad path", query: { q: "1" } },
      ],
    },
    {
      routes: {
        "GET /open-apis/im/v1/messages/om%201/resources/k%2F2": [
          { hex: "cafe", headers: { "content-type": "image/png" } },
          { json: { code: 234, msg: "no such" } },
          { text: "{}", status: 404, headers: { "content-type": "text/plain" } },
          { text: "nope", status: 500 },
          { text: "{\"msg\":\"m\",\"code\":{}}", status: 400 },
        ],
      },
      steps: Array.from({ length: 5 }, () => ({ call: "resource", message: "om 1", key: "k/2", type: "image" })),
    },
    {
      routes: { "POST /callback/ws/endpoint": [{ json: { code: 0, data: { URL: "wss://x/ws?service_id=5", ClientConfig: { PingInterval: 90 } } } }, { json: { code: 0, data: { URL: "wss://y" } } }, { json: { code: 0, data: { URL: "" } } }, { json: { code: 0, data: { URL: "u", ClientConfig: { PingInterval: -1 } } } }] },
      steps: [{ call: "endpoint" }, { call: "endpoint" }, { call: "endpoint" }, { call: "endpoint" }],
    },
  ];
  for (const c of cases) {
    const t = testClock();
    const world = new World({ wall: 1_700_000_000_000, ...c });
    world.install();
    const client = new FeishuClient("cli_a", "sec", "feishu", "https://fake.test//");
    const results: Json[] = [];
    try {
      for (const s of c.steps) {
        if (s.call === "pass") {
          world.wall += s.ms;
          results.push(null);
          continue;
        }
        results.push(
          await step(t, async () => {
            if (s.call === "tenantToken") return client.tenantToken();
            if (s.call === "resource") return hex(await client.resource(s.message, s.key, s.type));
            if (s.call === "endpoint") return client.endpoint();
            const files = (s.files ?? []).map((f: Json) => ({ field: f.field, bytes: unhex(f.hex), name: f.name, mime: f.mime }));
            const got = await client.api(s.method, s.path, s.body ?? null, s.query === undefined ? undefined : Object.fromEntries(Object.entries(s.query).map(([k, v]) => [k, String(v)])), files.length > 0 ? files : undefined, s.takeFile === true);
            return got instanceof FeishuFile ? { file: { hex: hex(got.bytes), contentType: got.contentType, disposition: got.disposition } } : { data: got };
          }),
        );
      }
    } finally {
      mock.restoreAll();
      reinstallLogs();
      await t.close();
    }
    const theirs = await mb({ op: "client", base: "https://fake.test//", appId: "cli_a", appSecret: "sec", domain: "feishu", wall: 1_700_000_000_000, ...c });
    assert.deepEqual(theirs.results, results, JSON.stringify(c.steps).slice(0, 300));
    assert.deepEqual(requests(theirs.requests), requests(world.seen), "what Feishu was asked");
    assert.deepEqual(theirs.sleeps, world.sleeps, "how long each limit was waited out");
  }
});

/// The log's mock again, after a case's mocks were let go.
function reinstallLogs() {
  for (const level of ["info", "warn", "error"] as const) {
    mock.method(log, level, (area: string, words: string) => {
      if (area === "feishu") {
        logs.push([level, area, words]);
        activity++;
      }
    });
  }
}

// ── surface.ts, status.ts, threads.ts ──

const ME = { team: "", teamId: "", url: "", botUserId: "ou_bot", botName: "Bot", botImage: null, botId: "" };
const dataFrame = (type: string, payload: unknown, headers: [string, string][] = []) => ({
  seqId: "9", logId: "3", service: 5, method: 1, headers: [["type", type], ...headers], payload: hex(new TextEncoder().encode(typeof payload === "string" ? payload : JSON.stringify(payload))),
});
const received = (message: Json, extra: Json = {}) => ({ header: { event_type: "im.message.receive_v1", tenant_key: "tk", ...extra }, event: { sender: sender(), message } });
const cardPressed = (value: Json, form: Json = null, message = "om_q") => ({ header: { event_type: "card.action.trigger", event_id: "ev_9" }, event: { operator: { open_id: "ou_ann" }, context: { open_chat_id: "oc_g", open_message_id: message }, action: { value, form_value: form } } });

/// A case of the surface's run by the TypeScript: the same steps, the same stand-in, the same clock.
async function tsSurface(c: Json, dir: string) {
  const t = testClock();
  const world = new World(c);
  world.install();
  logs.length = 0;
  const path = join(dir, `threads-${Math.random().toString(36).slice(2)}.json`);
  if (typeof c.threadsFile === "string") writeFileSync(path, c.threadsFile);
  const threads = new FeishuThreads(path);
  const people = new Map<string, Json>(Object.entries(c.people ?? {}));
  const channels = new Map<string, string | null>();
  const book = c.book
    ? {
        person(key: string, fetch: () => Promise<Json>, stale: (k: Json, age: number) => boolean) {
          const known = people.get(key) ?? null;
          if (known !== null && !stale(known, c.bookAge ?? 0)) return known;
          void fetch().catch(() => null).then((p) => {
            if (p) people.set(key, p);
            logs.push(["book", "person", key]);
            activity++;
          });
          return known;
        },
        channel(key: string, fetch: () => Promise<string | null>) {
          if (channels.has(key)) return channels.get(key)!;
          void fetch().catch(() => null).then((n) => {
            channels.set(key, n);
            logs.push(["book", "channel", key]);
            activity++;
          });
          return null;
        },
      }
    : null;
  let hooks: SocketHooks | null = null;
  class Probe extends FeishuSurface {
    protected override socketTo(_url: string, h: SocketHooks) {
      hooks = h;
      return Effect.void;
    }
  }
  const surface = new Probe({ connect: c.connect, appId: c.appId, appSecret: c.appSecret, domain: c.domain, threads, threadMode: c.threadMode === true, directThreads: c.directThreads === true, book: book as Json, client: new FeishuClient(c.appId, c.appSecret, c.domain, "https://fake.test"), clock: t.clock });
  if (c.me) (surface as Json).me = { ...c.me };
  const events: Json[] = [];
  const handler = async (event: Json) => {
    events.push(event);
    activity++;
    if ((c.handlerFails ?? []).includes(event?.message?.ts)) throw new Error("the store refused it");
  };
  const sent: string[] = [];
  const results: Json[] = [];
  const extra = () => threads.written();
  try {
    for (const s of c.steps) {
      const thread = s.thread;
      let r: Json;
      switch (s.call) {
        case "advance":
          await t.adjust(s.ms);
          r = null;
          break;
        case "take": r = await step(t, () => surface.take(s.envelope, handler), extra); break;
        case "post": r = await step(t, () => surface.post(thread, s.message, s.files ?? [], s.card ?? null), extra); break;
        case "places": r = await step(t, () => surface.places(), extra); break;
        case "peopleIn": r = await step(t, () => surface.peopleIn(s.chat), extra); break;
        case "permalink": r = await step(t, () => surface.permalink(thread), extra); break;
        case "begin": r = await step(t, () => surface.begin(s.chat, s.message), extra); break;
        case "cardEnded": r = await step(t, async () => { await surface.cardEnded(thread, s.ts, s.said, s.card, s.end); return null; }, extra); break;
        case "edit": r = await step(t, () => surface.edit(thread, s.ts, s.message), extra); break;
        case "download": r = await step(t, async () => hex(await surface.download({ id: s.file.id, name: s.file.name, size: 0, url: s.file.url ?? null } as Json)), extra); break;
        case "userName": r = await step(t, () => surface.userName(s.user), extra); break;
        case "userEmail": r = await step(t, () => surface.userEmail(s.user), extra); break;
        case "userOf": r = await step(t, () => surface.userOf(s.email), extra); break;
        case "knownPerson": r = await step(t, () => surface.knownPerson(s.user), extra); break;
        case "knownChannel": r = await step(t, () => surface.knownChannel(s.channel), extra); break;
        case "channelName": r = await step(t, () => surface.channelName(s.channel), extra); break;
        case "history": r = await step(t, () => surface.history(thread, s.before, s.limit), extra); break;
        case "quoted": r = await step(t, () => surface.quoted(thread, s.ts), extra); break;
        case "api":
          r = await step(t, async () => {
            const got = await surface.api(s.method, s.params ?? {});
            return got instanceof FeishuFile ? { file: { hex: hex(got.bytes), contentType: got.contentType, disposition: got.disposition } } : { data: got };
          }, extra);
          break;
        case "catchUp": r = await step(t, async () => { await surface.catchUp(handler); return null; }, extra); break;
        case "identify": r = await step(t, async () => { const i = await (surface as Json).identify(); (surface as Json).usable(i); return i; }, extra); break;
        case "address": r = await step(t, () => (surface as Json).address(), extra); break;
        case "verify": r = await step(t, () => verifyFeishuApp(s.appId, s.appSecret, s.domain, s.lang), extra); break;
        case "mention": r = { ok: surface.mention(s.user) }; break;
        case "platform": r = { ok: surface.platform() }; break;
        case "me": r = { ok: plain((surface as Json).me) }; break;
        case "socket":
          r = await step(t, async () => {
            hooks = null;
            await Effect.runPromise(surface.runSocket(s.url, handler));
            const socket: Json = { readyState: 1, send: (b: Uint8Array) => { sent.push(hex(b)); activity++; }, ping() {} };
            const h = hooks as unknown as SocketHooks;
            if (s.open !== false) h.opened?.(socket);
            for (const f of s.frames ?? []) {
              const bytes = f.hex !== undefined ? unhex(f.hex) : encode(frameOf(f.frame));
              h.message(socket, Buffer.from(bytes), { binary: true, now: f.now ?? 0, end: () => {} });
              if (f.close === true) socket.readyState = 3;
            }
            if (s.ping === true) h.ping?.(socket);
            return null;
          }, extra);
          break;
        case "working":
          surface.working(thread, s.ts ?? null, s.status, s.page ?? null);
          await settle(t, extra);
          r = null;
          break;
        default:
          throw new Error(`no such call: ${s.call}`);
      }
      results.push(r);
      await settle(t, extra);
    }
    await threads.written();
    return { results, events: plain(events), requests: world.seen, sleeps: world.sleeps, sent, logs: [...logs], threadsFile: existsSync(path) ? readFileSync(path, "utf8") : null };
  } finally {
    await surface.stop();
    mock.restoreAll();
    reinstallLogs();
    await t.close();
  }
}

/// A surface's case run by both: the same in every way.
async function sameSurface(name: string, c: Json) {
  const dir = fresh("surface");
  const base = { connect: "fs", appId: "cli_test", appSecret: "s", domain: "feishu", wall: 1_700_000_000_000, me: ME, ...c };
  // (a file it posts is where the TypeScript reads it: given the program as the same path)
  const files: Record<string, string> = {};
  for (const [p, h] of Object.entries((c.files ?? {}) as Record<string, string>)) {
    const at = join(dir, p);
    mkdirSync(join(at, ".."), { recursive: true });
    writeFileSync(at, Buffer.from(h, "hex"));
    files[at] = h;
  }
  const steps = base.steps.map((s: Json) => (s.files ? { ...s, files: s.files.map((f: Json) => ({ ...f, path: f.path.startsWith("/") ? f.path : join(dir, f.path) })) } : s));
  const mine = await tsSurface({ ...base, steps }, dir);
  const theirs = await mb({ op: "surface", ...base, steps, files });
  assert.deepEqual(theirs.results, mine.results, `${name}: what each step gave`);
  assert.deepEqual(theirs.events, mine.events, `${name}: what the station was given`);
  assert.deepEqual(requests(theirs.requests), requests(mine.requests), `${name}: what Feishu was asked`);
  assert.deepEqual(theirs.sent, mine.sent, `${name}: what was sent on the socket`);
  assert.deepEqual(theirs.logs, mine.logs, `${name}: what was said in the log`);
  assert.deepEqual(theirs.threadsFile === null ? null : JSON.parse(theirs.threadsFile), mine.threadsFile === null ? null : JSON.parse(mine.threadsFile), `${name}: the threads' file`);
  assert.equal(theirs.threadsFile, mine.threadsFile, `${name}: the threads' file, byte for byte`);
  return mine;
}

test("surface: each event heard on the socket, its thread, its acknowledgement and what Feishu is answered", { skip }, async () => {
  await stationIn("zh");
  const group = (fields: Json) => msg({ message_type: "text", content: JSON.stringify({ text: "hi" }), ...fields });
  const atBot = { content: JSON.stringify({ text: "@_user_1 go" }), mentions: [{ key: "@_user_1", name: "Bot", id: { open_id: "ou_bot" } }] };
  const url = "wss://fake.test/ws?device_id=d&service_id=42";
  const frame = (envelope: Json, now = 1000, headers: [string, string][] = []) => ({ frame: dataFrame("event", envelope, headers), now });
  await sameSurface("socket", {
    me: { ...ME, teamId: "" },
    steps: [
      { call: "socket", url, ping: true, frames: [frame(received(group({ message_id: "om_a", ...atBot })))] },
      { call: "me" },
      { call: "socket", url, open: false, frames: [frame(received(group({ message_id: "om_b" })))] },
      { call: "socket", url, open: false, frames: [frame(received(group({ message_id: "om_c", ...atBot, content: JSON.stringify({ text: "@_user_1 新会话" }) })))] },
      { call: "socket", url, open: false, frames: [frame(received(msg({ message_id: "om_d", chat_id: "oc_dm", chat_type: "p2p", message_type: "text", content: JSON.stringify({ text: "/new" }) })))] },
      { call: "socket", url, open: false, frames: [{ frame: { ...dataFrame("event", "{}"), method: 0 }, now: 1 }, { frame: dataFrame("pong", "{}"), now: 1 }, { hex: "08", now: 1 }, frame("not json"), frame({ header: { event_type: "other" } })] },
      { call: "socket", url, open: false, frames: [frame(received(group({ message_id: "om_fail" })))] },
      { call: "socket", url, open: false, frames: [{ ...frame(received(group({ message_id: "om_closed" }))), close: true }] },
      // a big event in parts, one part old enough to be dropped
      {
        call: "socket", url, open: false,
        frames: (() => {
          const whole = new TextEncoder().encode(JSON.stringify(received(group({ message_id: "om_big", ...atBot }))));
          const half = Math.floor(whole.length / 2);
          const part = (seq: number, bytes: Uint8Array, now: number, id = "big") => ({ frame: { ...dataFrame("event", ""), headers: [["type", "event"], ["message_id", id], ["sum", "2"], ["seq", String(seq)]], payload: hex(bytes) }, now });
          return [part(0, whole.subarray(0, half), 0, "old"), part(1, whole.subarray(half), 1_000), part(0, whole.subarray(0, half), 2_000), part(1, whole.subarray(half), 400_000, "old"), part(0, whole.subarray(0, half), 400_001, "old")];
        })(),
      },
      { call: "socket", url, open: false, frames: [{ frame: { ...dataFrame("event", ""), headers: [["type", "event"], ["sum", "1.5"]] }, now: 1 }] },
      { call: "socket", url: "wss://fake.test/ws?service_id=1.5", ping: true, frames: [] },
      { call: "socket", url: "wss://fake.test/ws?service_id=-7&service_id=8", ping: true, frames: [] },
      { call: "socket", url: "wss://fake.test/ws", ping: true, frames: [] },
      { call: "socket", url: "not a url", frames: [] },
    ],
    handlerFails: ["om_fail"],
  });
  await sameSurface("card answers", {
    steps: [
      { call: "post", thread: { channel: "oc_g", threadTs: "om_t" }, message: "Which?", files: [], card: { type: "options", options: [{ label: "A" }, { label: "B", recommended: true }] } },
      { call: "socket", url, frames: [{ frame: dataFrame("card", cardPressed({ sf: "answer", t: "om_t", l: "B" }, null, "om_1")), now: 5 }] },
      { call: "socket", url, open: false, frames: [{ frame: dataFrame("card", cardPressed({ sf: "answer", t: "om_t", l: "A" }, null, "om_1")), now: 6 }] },
      { call: "take", envelope: cardPressed({ sf: "answer", t: "om_t" }, { answer: "  typed  " }, "om_unknown") },
      { call: "take", envelope: cardPressed({ sf: "answer", t: "om_t" }, { answer: "  " }) },
      { call: "take", envelope: cardPressed({ sf: "answer", t: 5 }) },
      { call: "take", envelope: cardPressed({ sf: "other", t: "om_t", l: "x" }) },
      { call: "take", envelope: cardPressed(null) },
      { call: "take", envelope: { header: { event_type: "card.action.trigger" }, event: { operator: {}, context: {} } } },
      { call: "take", envelope: null },
      { call: "take", envelope: { header: { event_type: "im.message.receive_v1", tenant_key: "tk2" }, event: { sender: sender("app"), message: group({}) } } },
      { call: "me" },
    ],
  });
});

test("surface: which thread each message is in, by chat, topic group, thread mode, a direct chat's threads and what was kept before", { skip }, async () => {
  await stationIn("zh");
  const chats = {
    "GET /open-apis/im/v1/chats/oc_topics": [{ json: { code: 0, data: { chat_mode: "topic", name: "Topics" } } }],
    "GET /open-apis/im/v1/chats/oc_thread": [{ json: { code: 0, data: { chat_mode: "group", group_message_type: "thread", name: "" } } }],
    "GET /open-apis/im/v1/chats/oc_g": [{ json: { code: 0, data: { chat_mode: "group", name: "G" } } }],
    "GET /open-apis/im/v1/chats/oc_bad": [{ json: { code: 403, msg: "no" } }, { json: { code: 0, data: { chat_mode: "group", group_message_type: "thread" } } }],
  };
  const text = (fields: Json) => msg({ message_type: "text", content: JSON.stringify({ text: "hi" }), ...fields });
  const atBot = { content: JSON.stringify({ text: "@_user_1 go" }), mentions: [{ key: "@_user_1", name: "Bot", id: { open_id: "ou_bot" } }] };
  const steps = (prefix: string) => [
    { call: "take", envelope: received(text({ message_id: `${prefix}1`, chat_id: "oc_g" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}2`, chat_id: "oc_g", ...atBot })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}3`, chat_id: "oc_g" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}4`, chat_id: "oc_g", ...atBot, content: JSON.stringify({ text: "@_user_1 新对话" }) })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}5`, chat_id: "oc_g", thread_id: "omt_x", root_id: `${prefix}2` })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}6`, chat_id: "oc_topics", thread_id: "omt_t", root_id: "om_root" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}7`, chat_id: "oc_topics", thread_id: "omt_t2" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}8`, chat_id: "oc_thread", thread_id: "omt_u", root_id: "om_ur", parent_id: "om_q" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}9`, chat_id: "oc_bad", thread_id: "omt_b" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}10`, chat_id: "oc_bad", thread_id: "omt_b" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}11`, chat_id: "oc_dm", chat_type: "p2p", thread_id: "omt_p" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}12`, chat_id: "oc_g", create_time: "1600000000000" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}13`, chat_id: "oc_g", create_time: "0" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}14`, chat_id: "oc_dm", chat_type: "p2p" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}15`, chat_id: "oc_dm", chat_type: "p2p" })) },
    { call: "take", envelope: received(text({ message_id: `${prefix}16`, chat_id: "oc_dm", chat_type: "p2p", thread_id: "omt_d", root_id: `${prefix}14` })) },
  ];
  for (const [threadMode, directThreads] of [[false, false], [true, false], [false, true], [true, true]]) {
    await sameSurface(`threads ${threadMode} ${directThreads}`, { threadMode, directThreads, routes: chats, steps: steps("om_") });
    await sameSurface(`threads kept ${threadMode} ${directThreads}`, {
      threadMode, directThreads, routes: chats, steps: steps("om_k"),
      threadsFile: JSON.stringify({ fs: { chats: { oc_g: "om_old" }, topics: { om_old: "om_old" }, seen: { oc_g: 1800000000000 } }, other: { chats: {} } }),
    });
  }
  for (const file of ["not json", "[1]", "null", JSON.stringify({ fs: { chats: null, seen: 5 } }), JSON.stringify({ fs: "str" }), JSON.stringify({ fs: { chats: { oc_g: 7 }, seen: { oc_g: "1700000000000" } } })]) {
    await sameSurface(`threads file ${file}`, { routes: chats, threadsFile: file, steps: steps("om_f").slice(0, 5) });
  }
});

test("surface: what it posts (rich text, a question's card, images and files), begins, edits, ends and downloads", { skip }, async () => {
  await stationIn("en");
  const routes = {
    "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: { message_id: "om_p1" } } }, { json: { code: 0, data: { message_id: "om_p2" } } }, { json: { code: 0, data: { message_id: "om_p3" } } }, { json: { code: 0, data: { message_id: "om_p4", thread_id: "omt_new" } } }, { json: { code: 0, data: { message_id: "om_p5" } } }, { json: { code: 0, data: {} } }],
    "POST /open-apis/im/v1/messages/om_root/reply": [{ json: { code: 0, data: { message_id: "om_r1" } } }],
    "POST /open-apis/im/v1/images": [{ json: { code: 0, data: { image_key: "img_up" } } }, { json: { code: 0, data: {} } }],
    "POST /open-apis/im/v1/files": [{ json: { code: 0, data: { file_key: "file_up" } } }],
    "GET /open-apis/im/v1/chats/oc_topics": [{ json: { code: 0, data: { chat_mode: "topic" } } }],
    "GET /open-apis/im/v1/messages/om_p5": [{ json: { code: 0, data: { items: [{ thread_id: "omt_read" }] } } }],
    "GET /open-apis/im/v1/messages/om_r/resources/img_k": [{ hex: "abcd", headers: { "content-type": "image/png" } }],
  };
  await sameSurface("posts", {
    routes,
    threadsFile: JSON.stringify({ fs: { topics: { omt_t: "om_root" } } }),
    files: { "a.png": "89504e470d0a", "doc.PDF": "25504446", "big.jpg": "00", "v.MOV": "00", "t.xlsx": "00", "s.pptx": "00", "o.opus": "00", "x.bin": "00", "dir.png/noext": "00", ".png": "00" },
    steps: [
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "hello <at id=ou_ann></at>", files: [] },
      { call: "post", thread: { channel: "oc_g", threadTs: "omt_t" }, message: "in the topic", files: [{ path: "a.png", name: "a.png" }, { path: "doc.PDF", name: "doc.PDF" }] },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "", files: [{ path: "v.MOV", name: "v.MOV" }, { path: "t.xlsx", name: "t.xlsx" }, { path: "s.pptx", name: "s.pptx" }, { path: "o.opus", name: "o.opus" }, { path: "x.bin", name: "x.bin" }, { path: "dir.png/noext", name: "noext" }, { path: ".png", name: ".png" }] },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "", files: [] },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "missing", files: [{ path: "/nowhere/gone.txt", name: "gone.txt" }] },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "Say?", files: [], card: { type: "text", placeholder: "a name" } },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "x", files: [], card: { type: "login" } },
      { call: "begin", chat: "oc_g", message: "a new conversation" },
      { call: "begin", chat: "oc_topics", message: "a topic" },
      { call: "begin", chat: "oc_topics", message: "read back" },
      { call: "begin", chat: "oc_g", message: "" },
      { call: "begin", chat: "oc_g", message: "no id" },
      { call: "edit", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_p1", message: "changed" },
      { call: "edit", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_p1", message: "x".repeat(7000) },
      { call: "edit", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_p1", message: "" },
      { call: "download", file: { id: "img_k", name: "img_k.png", url: "feishu:image:om_r:img_k" } },
      { call: "download", file: { id: "x", name: "x", url: "https://elsewhere" } },
      { call: "download", file: { id: "x", name: "x" } },
      { call: "permalink", thread: { channel: "oc_g/x", threadTs: "om_x" } },
      { call: "permalink", thread: { channel: "\ud800", threadTs: "om_x" } },
      { call: "mention", user: "ou_ann" },
      { call: "platform" },
    ],
  });
  for (const directThreads of [false, true]) {
    await sameSurface(`begins in a direct chat ${directThreads}`, {
      directThreads,
      routes: {
        "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: { message_id: "om_b1" } } }, { json: { code: 0, data: { message_id: "om_b3" } } }],
        "GET /open-apis/im/v1/chats/oc_dm": [{ json: { code: 0, data: { chat_mode: "p2p" } } }],
        "POST /open-apis/im/v1/messages/om_b1/reply": [{ json: { code: 0, data: { message_id: "om_b2" } } }],
      },
      steps: [
        { call: "begin", chat: "oc_dm", message: "a new conversation" },
        { call: "post", thread: { channel: "oc_dm", threadTs: "om_b1" }, message: "after it", files: [] },
      ],
    });
  }
  await sameSurface("lark", { domain: "lark", steps: [{ call: "permalink", thread: { channel: "oc_g", threadTs: "om_x" } }, { call: "platform" }] });
  await sameSurface("cards ended", {
    routes: { "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: { message_id: "om_q1" } } }, { json: { code: 0, data: { message_id: "om_q2" } } }] },
    people: {},
    steps: [
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "Pick", files: [], card: { type: "options", options: [{ label: "A" }] } },
      { call: "post", thread: { channel: "oc_g", threadTs: "om_x" }, message: "Write", files: [], card: { type: "text" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_q1", said: "kept text", card: { type: "options" }, end: { why: "message", by: "ou_ann", byTs: "om_9" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_q1", said: "again", card: { type: "options" }, end: { why: "replaced" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_q2", said: "s", card: { type: "text" }, end: { why: "message", by: "ou_ann", byTs: "card-ev" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_q2", said: "s", card: { type: "text" }, end: { why: "withdrawn" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_gone", said: "from the store", card: { type: "options" }, end: { why: "closed" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_gone2", said: "s", card: { type: "login" }, end: { why: "closed" } },
      { call: "cardEnded", thread: { channel: "oc_g", threadTs: "om_x" }, ts: "om_gone3", said: "s", card: null, end: { why: "closed" } },
    ],
  });
});

test("surface: the groups it is in, their people, a person's name and email, a chat's name, as Feishu says and the book keeps them", { skip }, async () => {
  await stationIn("zh");
  const routes = {
    "GET /open-apis/im/v1/chats": [{ json: { code: 0, data: { items: [{ chat_id: "oc_a", name: "A" }, { chat_id: "" }, { chat_id: "oc_dm" }, { chat_id: "oc_t", name: "" }], has_more: true, page_token: "p2" } } }, { json: { code: 0, data: { items: [{ chat_id: "oc_b" }], has_more: false } } }],
    "GET /open-apis/im/v1/chats/oc_a": [{ json: { code: 0, data: { chat_mode: "group", name: "A now" } } }],
    "GET /open-apis/im/v1/chats/oc_dm": [{ json: { code: 0, data: { chat_mode: "p2p", name: "secret" } } }],
    "GET /open-apis/im/v1/chats/oc_t": [{ json: { code: 0, data: { chat_mode: "topic" } } }],
    "GET /open-apis/im/v1/chats/oc_b": [{ json: { code: 500, msg: "down" } }],
    "GET /open-apis/im/v1/chats/oc_g/members": [{ json: { code: 0, data: { items: [{ member_id: "ou_ann", name: "Ann" }, { member_id: "ou_bo", name: "" }, { member_id: "", name: "x" }], has_more: true, page_token: "n" } } }, { json: { code: 0, data: { items: [{ member_id: "ou_cy", name: "Cy" }], has_more: true, page_token: "" } } }],
    "GET /open-apis/contact/v3/users/ou_ann": [{ json: { code: 0, data: { user: { name: "Ann", enterprise_email: "Ann@Corp.COM", email: "x@y" } } } }],
    "GET /open-apis/contact/v3/users/ou_bo": [{ json: { code: 0, data: { user: { en_name: "Bo", email: "BO@x.io" } } } }],
    "GET /open-apis/contact/v3/users/ou_cy": [{ json: { code: 403, msg: "no permission" } }],
    "GET /open-apis/contact/v3/users/ou_dd": [{ json: { code: 0, data: { user: {} } } }],
    "POST /open-apis/contact/v3/users/batch_get_id": [{ json: { code: 0, data: { user_list: [{ email: "other@x", user_id: "ou_o" }, { email: "ANN@corp.com", user_id: "ou_ann" }] } } }, { json: { code: 0, data: { user_list: [{ email: "z@z" }] } } }, { json: { code: 1, msg: "x" } }],
  };
  const take = (id: string, user: string) => ({ call: "take", envelope: { header: { event_type: "im.message.receive_v1" }, event: { sender: sender("user", user), message: msg({ message_id: id, chat_id: "oc_g", message_type: "text", content: "{}" }) } } });
  const steps = [
    { call: "places" },
    { call: "peopleIn", chat: "oc_g" },
    { call: "peopleIn", chat: "oc_g" },
    { call: "advance", ms: 60_000 },
    { call: "peopleIn", chat: "oc_g" },
    take("om_1", "ou_cy"), take("om_2", "ou_dd"),
    { call: "userName", user: "ou_ann" }, { call: "userEmail", user: "ou_ann" }, { call: "userName", user: "ou_bo" }, { call: "userEmail", user: "ou_bo" },
    { call: "userName", user: "ou_cy" }, { call: "userEmail", user: "ou_cy" }, { call: "userName", user: "ou_dd" }, { call: "userName", user: "ou_zz" },
    { call: "userOf", email: "  Ann@Corp.com " }, { call: "userOf", email: "ann@corp.com" }, { call: "userOf", email: "z@z" }, { call: "userOf", email: "q@q" }, { call: "userOf", email: "  " },
    { call: "knownPerson", user: "ou_ann" }, { call: "knownPerson", user: "ou_cy" }, { call: "knownPerson", user: "ou_new" }, { call: "knownPerson", user: "ou_new" },
    { call: "knownChannel", channel: "oc_a" }, { call: "knownChannel", channel: "oc_zz" }, { call: "knownChannel", channel: "oc_zz" },
    { call: "channelName", channel: "oc_dm" }, { call: "channelName", channel: "oc_b" },
  ];
  await sameSurface("people", { routes, steps });
  await sameSurface("people with a book", { routes, steps, book: true, people: { "u:fs:ou_cy": { name: "Cy kept", email: "" }, "u:fs:ou_ann": { name: "Ann kept", email: "ann@kept" } }, bookAge: 86_400_000 });
  await sameSurface("people with a fresh book", { routes, steps, book: true, people: { "u:fs:ou_cy": { name: "Cy kept", email: "" } }, bookAge: 5 });
});

test("surface: a thread's past, a quoted message, what was said while away, feishu_api's calls, who the bot is and an app checked", { skip }, async () => {
  await stationIn("zh");
  const item = (id: string, fields: Json = {}) => ({ message_id: id, msg_type: "text", body: { content: JSON.stringify({ text: `said ${id}` }) }, sender: { id: "ou_ann", sender_type: "user" }, chat_id: "oc_g", create_time: "1700000001000", ...fields });
  const routes = {
    "GET /open-apis/im/v1/messages": [
      { json: { code: 0, data: { items: [item("om_1"), item("om_2", { sender: { id: "cli_x", sender_type: "app" } }), item("om_img", { msg_type: "image", body: { content: JSON.stringify({ image_key: "ik" }) } })], has_more: true, page_token: "p" } } },
      { json: { code: 0, data: { items: [item("om_3"), item("om_before"), item("om_4")], has_more: false } } },
      { json: { code: 0, data: { items: [item("om_5", { create_time: "1699999999999" }), item("om_6", { create_time: "1700000005000" })], has_more: false } } },
      { json: { code: 0, data: { items: [], has_more: true, page_token: "" } } },
    ],
    "GET /open-apis/im/v1/messages/om_root": [{ json: { code: 0, data: { items: [{ thread_id: "omt_r" }] } } }, { json: { code: 0, data: { items: [] } } }],
    "GET /open-apis/im/v1/messages/om_q": [{ json: { code: 0, data: { items: [item("om_q", { msg_type: "post", body: { content: JSON.stringify({ title: "T", content: [[{ tag: "img", image_key: "k" }]] }) } })] } } }, { json: { code: 0, data: { items: [item("om_q", { sender: { sender_type: "app" } })] } } }, { json: { code: 0, data: { items: [null] } } }, { json: { code: 0, data: {} } }, { json: { code: 230002, msg: "gone" } }],
    "GET /open-apis/bot/v3/info": [{ json: { code: 0, bot: { open_id: "ou_bot2", app_name: "Bot 2", avatar_url: "http://not-https" } } }, { json: { code: 0, data: { bot: { open_id: "", avatar_url: "https://a" } } } }, { json: { code: 99991672, msg: "scope" } }],
    "GET /open-apis/tenant/v2/tenant/query": [{ json: { code: 0, data: { tenant: { name: "Corp", tenant_key: "tk" } } } }, { json: { code: 1, msg: "no" } }],
    "POST /callback/ws/endpoint": [{ json: { code: 0, data: { URL: "wss://e/ws?service_id=3" } } }, { json: { code: 1, msg: "no long connection" } }],
    "GET /open-apis/docx/v1/documents/d/raw_content": [{ json: { code: 0, data: { content: "doc" } } }, { hex: "0001", headers: { "content-type": "application/pdf", "content-disposition": "attachment; filename=\"d.pdf\"" } }],
    "POST /open-apis/im/v1/messages/om_1/reactions": [{ json: { code: 0, data: { reaction_id: "r" } } }],
  };
  await sameSurface("reading", {
    routes,
    threadsFile: JSON.stringify({ fs: { chats: { oc_g: "om_c", oc_none: "om_n" }, topics: { om_root: "om_root" }, seen: { oc_g: 1700000000000 } } }),
    steps: [
      { call: "history", thread: { channel: "oc_g", threadTs: "omt_t" }, before: "om_before", limit: 3 },
      { call: "history", thread: { channel: "oc_g", threadTs: "om_root" }, before: "none", limit: 0 },
      { call: "history", thread: { channel: "oc_g", threadTs: "om_root" }, before: "none", limit: -1 },
      { call: "history", thread: { channel: "oc_g", threadTs: "om_unknown" }, before: "x", limit: 5 },
      { call: "quoted", thread: { channel: "oc_g", threadTs: "x" }, ts: "om_q" },
      { call: "quoted", thread: { channel: "oc_g", threadTs: "x" }, ts: "om_q" },
      { call: "quoted", thread: { channel: "oc_g", threadTs: "x" }, ts: "om_q" },
      { call: "quoted", thread: { channel: "oc_g", threadTs: "x" }, ts: "om_q" },
      { call: "quoted", thread: { channel: "oc_g", threadTs: "x" }, ts: "om_q" },
      { call: "catchUp" },
      { call: "identify" }, { call: "identify" }, { call: "identify" },
      { call: "address" }, { call: "address" },
      { call: "api", method: " get  /open-apis/docx/v1/documents/d/raw_content ", params: { lang: 0, opts: { a: 1 }, none: null, s: "x" } },
      { call: "api", method: "GET /open-apis/docx/v1/documents/d/raw_content", params: {} },
      { call: "api", method: "post /open-apis/im/v1/messages/om_1/reactions", params: { reaction_type: { emoji_type: "OK" }, query: { a: 1, b: "x" } } },
      { call: "api", method: "POST /OPEN-APIS/x", params: { query: null } },
      { call: "api", method: "FETCH /open-apis/x", params: {} },
      { call: "api", method: "GET /open-apis/a b", params: {} },
      { call: "api", method: "GET/open-apis/x", params: {} },
      { call: "api", method: "GET /open-apis/", params: {} },
    ],
  });
  for (const lang of ["zh", "en"]) {
    await sameSurface(`verify ${lang}`, {
      routes: {
        "POST /open-apis/auth/v3/tenant_access_token/internal": [{ json: { code: 0, tenant_access_token: "t", expire: 7200 } }, { json: { code: 10014, msg: "app secret invalid" } }],
        "GET /open-apis/bot/v3/info": [{ json: { code: 0, bot: { open_id: "" } } }],
        "POST /callback/ws/endpoint": [{ json: { code: 0, data: {} } }],
      },
      steps: [
        { call: "verify", appId: "cli_9abc", appSecret: "s", domain: "feishu", lang },
        { call: "verify", appId: "CLI_X", appSecret: "s", domain: "lark", lang },
        { call: "verify", appId: "cli_", appSecret: "s", domain: "feishu", lang },
        { call: "verify", appId: "cli_a-b", appSecret: "s", domain: "feishu", lang },
        { call: "verify", appId: "cli_ok", appSecret: "  ", domain: "feishu", lang },
      ],
    });
  }
});

test("surface: the status card through a turn: made as an entity or a message, changed at most once a second, ended with its time or taken back", { skip }, async () => {
  for (const lang of ["zh", "en"] as const) {
    await stationIn(lang);
    const thinking = lang === "zh" ? ZH["station.status.thinking"] : EN["station.status.thinking"];
    const reading = lang === "zh" ? ZH["station.status.readingChat"] : EN["station.status.readingChat"];
    const thread = { channel: "oc_g", threadTs: "om_t" };
    const turn = (ts: string) => [
      { call: "working", thread, ts, status: thinking, page: "https://still.fail/s/1" },
      { call: "working", thread, ts, status: reading },
      { call: "advance", ms: 300 },
      { call: "working", thread, ts, status: "Running ls" },
      { call: "working", thread, ts, status: "Editing a.ts" },
      { call: "advance", ms: 1000 },
      { call: "working", thread, ts, status: "Editing b.ts" },
      { call: "advance", ms: 2500 },
      { call: "working", thread, ts, status: "" },
      { call: "advance", ms: 1000 },
    ];
    const called = { call: "take", envelope: received(msg({ message_id: "om_called", chat_id: "oc_g", message_type: "text", content: JSON.stringify({ text: "@_user_1 go" }), mentions: [{ key: "@_user_1", name: "Bot", id: { open_id: "ou_bot" } }] })) };
    await sameSurface(`status entity ${lang}`, {
      routes: { "POST /open-apis/cardkit/v1/cards": [{ json: { code: 0, data: { card_id: "card_1" } } }], "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: { message_id: "om_card" } } }] },
      steps: [called, ...turn("om_called"), ...turn("om_other"), { call: "working", thread, ts: "om_called", status: "Working" }, { call: "post", thread, message: "said", files: [] }, { call: "working", thread, status: "" }, { call: "advance", ms: 5000 }],
    });
    await sameSurface(`status messages ${lang}`, {
      routes: {
        "POST /open-apis/cardkit/v1/cards": [{ json: { code: 99991672, msg: "no cardkit:card:write" } }],
        "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: { message_id: "om_card" } } }, { json: { code: 0, data: { message_id: "om_card2" } } }],
        "DELETE /open-apis/im/v1/messages/om_card": [{ json: { code: 230054, msg: "too old" } }],
        "PATCH /open-apis/im/v1/messages/om_card": [{ json: { code: 0 } }, { json: { code: 1, msg: "patch refused" } }],
      },
      steps: [called, { call: "working", thread, ts: "om_called", status: "Running" }, { call: "advance", ms: 1000 }, { call: "working", thread, ts: "om_called", status: "Again" }, { call: "advance", ms: 1000 }, { call: "working", thread, status: "" }, { call: "advance", ms: 1000 }, ...turn("om_called")],
    });
    await sameSurface(`status entity id missing ${lang}`, {
      routes: { "POST /open-apis/cardkit/v1/cards": [{ json: { code: 0, data: { card_id: "" } } }], "POST /open-apis/im/v1/messages": [{ json: { code: 0, data: {} } }, { json: { code: 0, data: { message_id: "om_m" } } }] },
      steps: [called, { call: "working", thread, ts: "om_called", status: "Running" }, { call: "advance", ms: 1000 }, { call: "working", thread, ts: "om_called", status: "Running 2" }, { call: "advance", ms: 1000 }, { call: "working", thread, status: "" }, { call: "advance", ms: 10 }],
    });
  }
  await stationIn("zh");
});

// ── threads.ts ──

test("threads: what each chat and topic is kept as, and the file it is written to", { skip }, async () => {
  const steps: Json[] = [
    { call: "current", connect: "fs", chat: "oc_g" },
    { call: "begin", connect: "fs", chat: "oc_g", message: "om_1" },
    { call: "current", connect: "fs", chat: "oc_g" },
    { call: "heard", connect: "fs", chat: "oc_g", when: 5 },
    { call: "heard", connect: "fs", chat: "oc_g", when: 3 },
    { call: "heard", connect: "fs", chat: "1", when: 1 },
    { call: "heard", connect: "fs", chat: "0", when: 2 },
    { call: "heardTopic", connect: "fs", topic: "omt_1", root: "om_r" },
    { call: "heardTopic", connect: "fs", topic: "omt_1", root: "om_r" },
    { call: "topicRoot", connect: "fs", topic: "omt_1" },
    { call: "topicRoot", connect: "other", topic: "omt_1" },
    { call: "conversations", connect: "fs" },
    { call: "conversations", connect: "none" },
    { call: "begin", connect: "2", chat: "c", message: "m" },
  ];
  for (const file of [null, "", "garbage", "[]", "5", JSON.stringify({ fs: { chats: { oc_g: "om_0", "7": "x" }, seen: { oc_g: 10 } } }), JSON.stringify({ fs: { chats: 5, topics: null } }), JSON.stringify({ fs: "abc" }), JSON.stringify({ fs: { chats: "abc" } }), JSON.stringify({ fs: { seen: { oc_g: "9" } } }), JSON.stringify({ fs: true })]) {
    const t = testClock();
    const dir = fresh("threads");
    const path = join(dir, "feishu-threads.json");
    if (file !== null) writeFileSync(path, file);
    logs.length = 0;
    const threads = new FeishuThreads(path);
    const results: Json[] = [];
    for (const s of steps) {
      results.push(
        await step(t, () => {
          if (s.call === "current") return threads.current(s.connect, s.chat);
          if (s.call === "begin") return threads.begin(s.connect, s.chat, s.message);
          if (s.call === "conversations") return threads.conversations(s.connect);
          if (s.call === "heard") return threads.heard(s.connect, s.chat, s.when);
          if (s.call === "topicRoot") return threads.topicRoot(s.connect, s.topic);
          return threads.heardTopic(s.connect, s.topic, s.root);
        }, () => threads.written()),
      );
    }
    await threads.written();
    await t.close();
    const theirs = await mb({ op: "threads", path, file, steps });
    assert.deepEqual(theirs.results, results, `threads from ${file}`);
    assert.equal(theirs.file, existsSync(path) ? readFileSync(path, "utf8") : null, `the file from ${file}`);
    assert.deepEqual(theirs.logs.map((l: Json) => l.slice(0, 3)), logs.map((l: Json) => l.slice(0, 3)), `the log from ${file}`);
  }
});

// ── register.ts ──

/// A registration's link and its file as both are compared: the addons it carries as what they unpack to (each side's
/// gzip is its own).
const unpacked = (s: string | null) => (s === null ? null : s.replace(/addons=([A-Za-z0-9_-]+)/g, (_, b64) => `addons=${encodeURIComponent(gunzipSync(Buffer.from(b64, "base64url")).toString())}`));
const unpackedJson = (v: Json) => (v === null || v === undefined ? v : JSON.parse(unpacked(JSON.stringify(v))!));

test("registrations: an app made by a scan, asked after until it comes, saved, kept across a restart, cancelled and let go", { skip }, async () => {
  await stationIn("zh");
  const was = process.env.STILLFAIL_FEISHU_API;
  process.env.STILLFAIL_FEISHU_API = "https://fake.test";
  const flow = (answers: Json[]) => ({ "POST /oauth/v1/app/registration": answers.map((json) => (typeof json.fail === "string" ? json : { json })) });
  const init = { supported_auth_methods: ["client_secret", "x"] };
  const begun = (code = "dc", extra: Json = {}) => ({ device_code: code, verification_uri_complete: "https://accounts.fake.test/verify?code=1&from=x", expires_in: 300, interval: 2, ...extra });
  const cases: [string, Json][] = [
    ["done, saved by the worker", {
      routes: flow([init, begun(), { error: "authorization_pending" }, {}, { error: "slow_down" }, { user_info: { tenant_brand: "lark" } }, { client_id: "cli_new", client_secret: "sec", user_info: { open_id: "ou_me" } }]),
      ids: ["0a0b0c0d0e0f"],
      steps: [
        { call: "start" },
        { call: "begin", by: "a@x", domain: "feishu", name: "My Bot", context: { viewer: { email: "a@x" }, lang: "zh", input: { threads: true } }, workspace: "w1" },
        { call: "of", by: "a@x" }, { call: "of", by: "a@x", workspace: "w2" }, { call: "of", by: "b@x" },
        { call: "advance", ms: 2000 }, { call: "advance", ms: 2000 }, { call: "advance", ms: 2000 }, { call: "advance", ms: 7000 }, { call: "advance", ms: 7000 }, { call: "advance", ms: 7000 },
        { call: "get", id: "0a0b0c0d0e0f" },
        { call: "complete", id: "0a0b0c0d0e0f", by: "a@x", workspace: "w1" },
        { call: "advance", ms: 86_400_000 + 300_000 },
        { call: "get", id: "0a0b0c0d0e0f" },
      ],
      saves: [{ fail: "config not written" }, { ok: "c-1" }],
    }],
    ["denied, expired, failed, cancelled", {
      routes: flow([init, begun("d1"), init, begun("d2", { expires_in: 3 }), init, begun("d3"), init, begun("d4"), { error: "access_denied" }, { error: "weird", error_description: "it broke" }, { fail: "fetch failed" }, { error: "expired_token" }]),
      ids: ["000000000001", "000000000002", "000000000003", "000000000004"],
      steps: [
        { call: "begin", by: "a@x", domain: "feishu", name: "" }, { call: "begin", by: "a@x", domain: "lark", name: null, workspace: "w" }, { call: "begin", by: "a@x", domain: "feishu" }, { call: "begin", by: "b@x", domain: "feishu" },
        { call: "cancel", id: "000000000004", by: "a@x" }, { call: "cancel", id: "000000000004", by: "b@x", workspace: "w" }, { call: "cancel", id: "000000000004", by: "b@x" }, { call: "cancel", id: "nope", by: "a@x" },
        { call: "advance", ms: 2000 }, { call: "advance", ms: 2000 }, { call: "advance", ms: 2000 }, { call: "advance", ms: 2000 },
        { call: "of", by: "a@x", workspace: "w" },
        { call: "advance", ms: 86_400_000 + 400_000 }, { call: "of", by: "a@x" }, { call: "written" },
      ],
    }],
    ["refused at the start", {
      routes: flow([{ supported_auth_methods: ["other"] }, init, { error: "x", error_description: "no app for you" }, init, { error: "only error" }, init, {}, { fail: "fetch failed" }, init, begun("d", { verification_uri_complete: "not a url" })]),
      ids: [],
      steps: [{ call: "begin", by: "a", domain: "feishu" }, { call: "begin", by: "a", domain: "feishu" }, { call: "begin", by: "a", domain: "feishu" }, { call: "begin", by: "a", domain: "feishu" }, { call: "begin", by: "a", domain: "feishu" }, { call: "begin", by: "a", domain: "feishu" }],
    }],
    ["resumed from the file", {
      file: JSON.stringify([
        { id: "w1", by: "a", url: "u", expiresAt: 100_000, state: "waiting", error: null, domain: "feishu", app: null, appId: null, deviceCode: "dcw", interval: 5, workspace: null, context: null, connectId: null },
        { id: "d1", by: "a", url: "u", expiresAt: 0, state: "done", error: null, domain: "feishu", app: { appId: "cli_d", appSecret: "s", openId: null }, appId: "cli_d", deviceCode: null, interval: 5, workspace: "w", context: { input: {} }, connectId: null },
        { id: "x1", by: "a", url: "u", expiresAt: 0, state: "denied", error: null, domain: "feishu", app: null, appId: null, deviceCode: null, interval: 5, workspace: null, context: null, connectId: null, extra: "kept" },
        { id: "s1", by: "a", url: "", expiresAt: 0, state: "done", error: null, domain: "feishu", app: null, appId: "cli_s", deviceCode: null, interval: 5, workspace: null, context: null, connectId: "c-s" },
        { id: "w1", by: "dup" },
      ]),
      routes: flow([{ client_id: "cli_w", client_secret: "sw" }]),
      ids: [],
      steps: [
        { call: "ready" }, { call: "of", by: "a" }, { call: "start" }, { call: "advance", ms: 5000 }, { call: "get", id: "w1" }, { call: "get", id: "d1" },
        { call: "complete", id: "s1", by: "a", workspace: "any" }, { call: "complete", id: "x1", by: "a", workspace: "" }, { call: "complete", id: "w1", by: "a", workspace: "" },
        { call: "advance", ms: 86_400_000 }, { call: "of", by: "a" }, { call: "close" },
      ],
      saves: [{ ok: "c-d" }, { ok: "c-w" }],
    }],
    ["a file that cannot be read", { file: "not json", routes: flow([init, begun()]), ids: ["0000000000aa"], steps: [{ call: "ready" }, { call: "start" }, { call: "begin", by: "a", domain: "feishu" }, { call: "written" }, { call: "of", by: "a" }] }],
    ["a file of something else", { file: "{\"a\":1}", routes: flow([init, begun()]), ids: ["0000000000ab"], steps: [{ call: "start" }, { call: "begin", by: "a", domain: "feishu" }] }],
    ["no file", { noFile: true, routes: flow([init, begun(), { client_id: "c", client_secret: "s" }]), ids: ["0000000000ac"], steps: [{ call: "begin", by: "a", domain: "feishu", context: { k: 1 } }, { call: "advance", ms: 2000 }, { call: "start" }, { call: "get", id: "0000000000ac" }, { call: "close" }] }],
  ];
  try {
    for (const [name, c] of cases) {
      const t = testClock();
      const world = new World(c);
      world.install();
      const ids = [...(c.ids ?? [])];
      mock.method(crypto, "randomBytes", (n: number) => Buffer.from(ids.shift() ?? "", "hex").subarray(0, n));
      syncBuiltinESMExports();
      logs.length = 0;
      const dir = fresh("registrations");
      const path = join(dir, "feishu-registrations.json");
      if (typeof c.file === "string") writeFileSync(path, c.file);
      const reg = new Registrations({ clock: t.clock, ...(c.noFile ? {} : { file: path }) });
      let changes = 0;
      reg.onChange(() => changes++);
      const saves = [...(c.saves ?? [])];
      let n = 0;
      const save = async (r: Json) => {
        const at = n++;
        logs.push(["save", r.id]);
        activity++;
        const s = saves[at];
        if (s?.fail) throw new Error(s.fail);
        return s?.ok ?? `connect-${at}`;
      };
      const extra = () => reg.written().catch(() => {});
      // (none of these waits on the case's clock, only on gzip, the stand-in and the disk: each is awaited to its end,
      // never judged still waiting after some turns of the loop)
      const done = async (f: () => unknown): Promise<Json> => {
        let r: Json;
        try {
          r = { ok: plain(await f()) };
        } catch (e) {
          r = { error: (e as Error).message };
        }
        await settle(t, extra);
        return r;
      };
      const results: Json[] = [];
      const files: (string | null)[] = [];
      try {
        for (const s of c.steps) {
          let r: Json;
          if (s.call === "advance") {
            await t.adjust(s.ms);
            r = null;
          } else if (s.call === "begin") r = await done(async () => shownRegistration(await reg.begin(s.by, s.domain, s.name ?? null, s.context ?? null, s.workspace ?? null)));
          else if (s.call === "cancel") r = await done(() => reg.cancel(s.id, s.by, s.workspace));
          else if (s.call === "complete") r = await done(() => reg.complete(s.id, s.by, s.workspace, save));
          else if (s.call === "start") {
            reg.start(save);
            await settle(t, extra);
            r = null;
          } else if (s.call === "of") r = { ok: plain(reg.of(s.by, s.workspace).map(shownRegistration)) };
          else if (s.call === "get") r = { ok: plain(reg.get(s.id) ?? null) };
          else if (s.call === "ready") r = await done(async () => { await reg.ready(); return null; });
          else if (s.call === "written") r = await done(async () => { await reg.written(); return null; });
          else r = await done(async () => { await reg.close(); return null; });
          results.push(r);
          await settle(t, extra);
          files.push(existsSync(path) ? readFileSync(path, "utf8") : null);
        }
      } finally {
        await reg.close().catch(() => {});
        mock.restoreAll();
        reinstallLogs();
        syncBuiltinESMExports();
        await t.close();
      }
      const theirs = await mb({ op: "registrations", path, execPath: process.execPath, ...c });
      assert.deepEqual(unpackedJson(theirs.results), unpackedJson(results), `${name}: what each step gave`);
      assert.deepEqual(theirs.files.map(unpacked), files.map(unpacked), `${name}: the file after each step`);
      assert.equal(theirs.changes, changes, `${name}: how often it told of a change`);
      assert.deepEqual(requests(theirs.requests), requests(world.seen), `${name}: what Feishu was asked`);
      assert.deepEqual(theirs.logs, logs.map((l) => l.slice(0, 3)), `${name}: what was said in the log`);
    }
  } finally {
    if (was === undefined) delete process.env.STILLFAIL_FEISHU_API;
    else process.env.STILLFAIL_FEISHU_API = was;
  }
});

// ── tool.ts ──

test("feishu_api: its refusals, the bot it calls as, what it answers and the files it saves in the session's uploads", { skip }, async () => {
  const workspace = fresh("tool");
  const other = fresh("tool-other");
  const file = (contentType: string, disposition: string, bytes = "0102") => ({ file: { hex: bytes, contentType, disposition } });
  const c: Json = {
    feishu: ["f1", "f2", "f3", "f4"],
    sessions: { s1: { connect: "f1", workspace }, s2: { connect: "slack", workspace: other }, s3: { connect: null, workspace: other }, s4: { connect: "f3", workspace }, s5: { connect: "f4", workspace } },
    recent: { s2: ["slack", "f2", "f1"], s3: ["slack"] },
    threads: [{ key: "s1", to: "oc_a/om_b", connect: "f2" }],
    connected: {
      f1: [{ data: { code: 0, data: { a: "😀".repeat(30_001) } } }, { data: { code: 0, data: { ok: true } } }, { fail: "feishu GET /x: 403 no" }, file("text/plain", "attachment; filename=\"same.txt\"")],
      f2: [{ data: { from: "f2" } }],
      // (a connect of their own: the nth of them is the nth disposition's)
      f4: dispositionCases.map(([t, d]) => file(t, d)),
    },
    now: 1_700_000_000_123,
    uuids: Array.from({ length: dispositionCases.length + 2 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`),
  };
  const steps: Json[] = [
    { key: "s1", args: {} },
    { key: "s1", args: { method: null } },
    { key: "s1", args: { method: { x: 1 } } },
    { key: "s1", args: { method: "POST /open-apis/auth/v3/app_access_token" } },
    { key: "s1", args: { method: "get /open-apis/application/v6/applications/x" } },
    { key: "s1", args: { method: "POST /open-apis/im/v1/messages" } },
    { key: "s1", args: { method: "PATCH /open-apis/im/v1/messages/om_1" } },
    { key: "s1", args: { method: "DELETE /open-apis/im/v1/messages/om_1/reactionsX" } },
    { key: "s1", args: { method: "  GET   /open-apis/im/v1/chats  " } },
    { key: "s1", args: { method: "POST /open-apis/im/v1/messages/om_1/reactions", params: { reaction_type: { emoji_type: "OK" } } } },
    { key: "s1", args: { method: "GET /x", to: "oc_a/om_b" } },
    { key: "s2", args: { method: "GET /x" } },
    { key: "s3", args: { method: "GET /x" } },
    { key: "s4", args: { method: "GET /x", params: [1] } },
    ...dispositionCases.map(() => ({ key: "s5", args: { method: "GET /open-apis/file" } })),
    { key: "s1", args: { method: "GET /open-apis/file" } },
    { key: "s1", args: { method: "GET /open-apis/file" } },
    { key: "gone", args: { method: "GET /x" } },
  ];
  // the tool's TypeScript, through a hub of the case's sessions
  const asked: Json[] = [];
  const used = new Map<string, number>();
  const uuids = [...c.uuids];
  // (the last one again once the others are used: two files of one name then meet, as the second is refused)
  mock.method(crypto, "randomUUID", () => (uuids.length > 1 ? uuids.shift() : uuids[0]));
  syncBuiltinESMExports();
  const hub: Json = {
    store: {
      getSession: (key: string) => c.sessions[key] ?? null,
      recentSessionThreads: (key: string) => ({ threads: (c.recent[key] ?? []).map((connect: string) => ({ connect })) }),
      sessionThread: (key: string, channel: string, ts: string) => {
        const found = c.threads.find((t: Json) => t.key === key && t.to === `${channel}/${ts}`);
        return found ? { connect: found.connect } : null;
      },
    },
    chat: (connect: string) => ({
      api: c.connected[connect]
        ? async (method: string, params: Json) => {
            asked.push([connect, method, params]);
            const n = used.get(connect) ?? 0;
            used.set(connect, n + 1);
            const list = c.connected[connect];
            const spec = list[Math.min(n, list.length - 1)];
            if (spec.fail) throw new Error(spec.fail);
            if (spec.file) return new FeishuFile(unhex(spec.file.hex), spec.file.contentType, spec.file.disposition);
            return spec.data;
          }
        : undefined,
    }),
    now: () => c.now,
  };
  const results: Json[] = [];
  try {
    const [tool] = feishuTools(() => hub, (connect) => c.feishu.includes(connect));
    for (const s of steps) {
      try {
        results.push({ ok: await tool!.run(s.key, s.args) });
      } catch (e) {
        results.push({ error: (e as Error).message });
      }
    }
    const [starting] = feishuTools(() => undefined, () => true);
    try {
      await starting!.run("s1", { method: "GET /x" });
    } catch (e) {
      assert.deepEqual((await mb({ op: "tool", ...c, starting: true, steps: [{ key: "s1", args: { method: "GET /x" } }] })).results, [{ error: (e as Error).message }]);
    }
  } finally {
    mock.restoreAll();
    reinstallLogs();
    syncBuiltinESMExports();
  }
  const written: Record<string, string> = {};
  for (const dir of [workspace, other]) {
    const uploads = join(dir, "uploads");
    if (existsSync(uploads)) for (const name of readdirSync(uploads)) written[join(uploads, name)] = hex(readFileSync(join(uploads, name)));
  }
  const theirs = await mb({ op: "tool", ...c, steps });
  assert.deepEqual(theirs.results, results, "what the tool answered");
  assert.deepEqual(theirs.asked, plain(asked), "what each connect was asked");
  assert.deepEqual(theirs.files, written, "the files saved");
  // each disposition's name, as the program names it alone, is the name the tool gave its file
  dispositionCases.forEach(([, , name], i) => {
    const path = JSON.parse(results[14 + i].ok).path as string;
    assert.ok(path.endsWith(`-${name}`), `${path} ends in ${name}`);
  });
});
