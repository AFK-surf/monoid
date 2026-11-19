// The sessions hub in MoonBit (station/mb/src/session_hub, the reader's `--builder harness-session-hub`) against the
// TypeScript it is moved from, each asked the same and compared: the hub's pure parts (args.ts, model-choice.ts,
// run-change.ts, context-cap.ts, pool.ts and what they stand on, the words of i18n.ts) on many inputs, what they give
// or the words they refuse with; and the hub itself (hub.ts) on two databases made alike, A the TypeScript `Hub`'s, B
// the program's, driven through the same scenarios on one clock: what each method gives, what it did of what is
// outside it (its actors told and asked, the chats posted to, the drivers, the live view) in order, the clock's
// deadlines as it moves, and at the end every table of the two databases, row by row. What the hub asks of the world
// (an account picked, a post's ts, a file read) the test answers for B with fakes alike to A's.
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { createRequire, syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { sharedTranscripts } from "../src/read/transcript.ts";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import * as args from "../src/sessions/args.ts";
import * as choice from "../src/sessions/model-choice.ts";
import * as runChange from "../src/sessions/run-change.ts";
import * as contextCap from "../src/sessions/context-cap.ts";
import * as pool from "../src/sessions/pool.ts";
import { allowedIn, runs, sameModel, spelling } from "../src/sessions/config.ts";
import { billedPerUse } from "../src/agents/profiles.ts";
import { modelName } from "../src/ops/model-name.ts";
import { chosenSpeed, ultrafastModel } from "../../client/core-ts/src/model-speed.ts";
import { parseDeclared, retryable, timed, withSaid, personRef, failureNotice, shownLimitOf, limitShownNotice, compactFailedNotice, cannotStartWords, compactFailed, codexTooOld, SPENT_BEFORE, FALLBACK_MOST } from "../src/sessions/actor.ts";
import { modelLimitOf, runtimeLabel } from "../src/agents/runtime.ts";
import { chars } from "../src/agents/live.ts";
import { Said } from "../src/ops/i18n.ts";
import { tr } from "../src/ops/i18n.ts";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { STILLFAIL, branded } from "../../client/i18n/brand.ts";
import { alnumMbt } from "../mb/src/session_hub/gen-alnum.ts";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { runnerId } from "../src/agents/process.ts";
import { Store } from "../src/store/store.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { type HubConfig, hubConfig, runtimeNamed } from "../src/sessions/config.ts";
import { Accounts } from "../src/sessions/accounts.ts";
import { SandboxNameBuilder } from "../src/sessions/sandbox-name-builder.ts";
import { Places, PlaceRefused } from "../src/ops/places.ts";
import { DISK_LOW_BYTES } from "../src/ops/disk.ts";
import * as lifecycle from "../src/sessions/lifecycle.ts";
import * as afresh from "../src/sessions/afresh.ts";
import { usageNow } from "../src/read/usage.ts";
import { UsageCounter } from "../src/usage/counter.ts";
import { LiveHub } from "../src/sessions/live.ts";
import { MbUsageCounter } from "../src/usage/counter-mb.ts";
import { keepCounted, keepUsage } from "../src/usage/module.ts";
import { shownFactsSoon } from "../src/sessions/image-size.ts";
import { given, settle, testClock } from "./hub-fakes.ts";
import { latest as latestNote } from "../src/agents/migrations.ts";

type Json = any;

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

/// The catalog's texts as the station says them (branded with its product's name).
function brandedCatalog(words: Record<string, Json>): Record<string, Json> {
  const out: Record<string, Json> = {};
  for (const [k, v] of Object.entries(words)) {
    out[k] = typeof v === "string" ? branded(v, STILLFAIL) : Object.fromEntries(Object.entries(v as Record<string, string>).map(([f, t]) => [f, branded(t, STILLFAIL)]));
  }
  return out;
}

/// What a value is said as on the line: undefined as `{$undefined: true}`, a Map its entries.
export function said(v: unknown): unknown {
  if (v === undefined) return { $undefined: true };
  // (undefined in an array is said so; in an object, left out as JSON leaves it out)
  return JSON.parse(JSON.stringify(v, function (this: unknown, _, x) {
    return x instanceof Map ? [...x.entries()] : x instanceof Set ? [...x] : x === undefined && Array.isArray(this) ? { $undefined: true } : x;
  }));
}

/// The program, a line each way.
export class Program {
  readonly child: ChildProcess;
  #id = 0;
  #answers = new Map<number, (v: Json) => void>();
  readonly ready: Promise<void>;
  /// What the hub asks of the world, answered by whoever drives it.
  onAsk: (what: string, args: Json) => Promise<Json> | Json = () => null;
  /// What the hub tells of the world.
  onTell: (what: string, args: Json) => void = () => {};
  constructor(bin: string) {
    this.child = spawn(bin, ["--builder", "harness-session-hub"], { stdio: ["pipe", "pipe", "inherit"] });
    let readied!: () => void;
    this.ready = new Promise((r) => (readied = r));
    createInterface({ input: this.child.stdout! }).on("line", (text) => {
      const line = JSON.parse(text);
      if (line.ready) readied();
      else if (typeof line.ask === "number") void this.#answer(line);
      else if (typeof line.tell === "string") this.onTell(line.tell, line.args);
      else if (typeof line.id === "number") this.#answers.get(line.id)?.(line);
    });
  }
  async #answer(line: Json) {
    try {
      const value = await this.onAsk(line.what, line.args);
      this.write({ op: "hub", hub: "answer", ask: line.ask, value: value === undefined ? null : value });
    } catch (error) {
      this.write({ op: "hub", hub: "answer", ask: line.ask, error: (error as Error).message });
    }
  }
  write(line: Json) {
    this.child.stdin!.write(`${JSON.stringify(line)}\n`);
  }
  ask(line: Json): Promise<Json> {
    const id = ++this.#id;
    const answered = new Promise<Json>((resolve) => this.#answers.set(id, resolve));
    this.write({ id, ...line });
    return answered.then((a) => (this.#answers.delete(id), a));
  }
  close(): Promise<void> {
    return ended(this.child);
  }
}

/// A child let go: its stdin ended, and waited for until it is gone (killed 2 s after where it is not).
function ended(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const gone = new Promise<void>((r) => child.once("exit", () => r()));
  child.stdin?.end();
  setTimeout(() => child.kill("SIGKILL"), 2000).unref();
  return gone;
}

/// A function of both, given the same arguments: what each gives, or the words it refuses with.
async function both(p: Program, name: string, ts: (...a: Json[]) => Json, ...given: Json[]) {
  let want: Json;
  try {
    want = { result: said(ts(...structuredClone(given))) };
  } catch (error) {
    want = { error: (error as Error).message };
  }
  const got = await p.ask({ op: "call", fn: name, args: said(given) as Json[] });
  const answer = got.error !== undefined ? { error: got.error } : { result: got.result };
  assert.deepEqual(answer, want, `${name}(${JSON.stringify(given).slice(0, 400)})`);
}

let program: Program | null = null;
// (the program waited for till it is gone: one still running at the file's end is a leftover)
after(async () => {
  await program?.close();
});
async function opened(): Promise<Program> {
  if (program) return program;
  program = new Program(binary!);
  await program.ready;
  await program.ask({ op: "words", zh: brandedCatalog(zhStation), en: brandedCatalog(enStation), lang: "zh" });
  return program;
}

/// The Unicode alnum.mbt was made of (its head says it).
const alnumFile = readFileSync(new URL("../mb/src/session_hub/alnum.mbt", import.meta.url), "utf8");
const alnumUnicode = /\(Unicode\s*\/\/ ([0-9.]+)\)/.exec(alnumFile)?.[1] ?? null;

test("alnum.mbt is what gen-alnum.ts makes, on a Node of its Unicode", {
  skip: alnumUnicode !== process.versions.unicode ? `alnum.mbt is of Unicode ${alnumUnicode}, this Node's ${process.versions.unicode} (the station's Node, .node-version, makes it)` : false,
}, () => {
  assert.equal(alnumFile, alnumMbt());
});

test("a turn's state and what goes with it, as args.ts reads them", { skip }, async () => {
  const p = await opened();
  const kinds = [undefined, null, "", "all_done", "final", "need_human", "need_help", "block", "need_decision", "waiting", "nope", 3, true, { kind: "all_done" }, ["x"]];
  for (const k of kinds) await both(p, "stateArg", args.stateArg, k);
  for (const k of ["all_done", "final", "need_human", "need_help", "block", "need_decision", "waiting", "x", ""]) await both(p, "parseDeclared", parseDeclared, k, 42);
  const reasons = ["done", "Done!", "做完了", "已完成。", "ok ok", "all done", "已合进 main 82f108a5", "finished", "ALL FINISHED", "abc", "abcdef", "  12 34 56 ", "İİİ", "ⅫⅫⅫⅫⅫⅫ", "KelvinK", "😀😀😀😀😀😀", "ab-cd-ef", "测试版 1389 已发"];
  for (const r of reasons) await both(p, "isReason", args.isReason, r);
  const states: [Json, string][] = [[{ kind: "all_done" }, "now"], [{ kind: "need_help" }, "now"], [{ kind: "waiting", seconds: 30 }, "now"], [{ kind: "all_done" }, "before"], [{ kind: "need_help" }, "decision"]];
  const givens: Json[] = [{}, { need: "a key" }, { done: "已合进 main 82f108a5，测试版已发" }, { done: "done" }, { need: "  " }, { need: 42 }, { done: null }, { need: "x", done: "y" }, { done: { a: 1 } }];
  for (const [kind, s] of states) for (const g of givens) await both(p, "needArg", args.needArg, g, kind, s);
  for (const a of [{}, { about: null }, { about: " 123.4 " }, { about: 17 }, { about: "" }, { about: ["a"] }]) await both(p, "aboutTs", args.aboutTs, a);
  for (const k of [{ kind: "all_done" }, { kind: "need_help" }, { kind: "waiting", seconds: 3 }]) await both(p, "saidAs", args.saidAs, k);
  for (const t of ["", "\n\n  # Title **bold** here", "> quote `code` __u__", "- item", "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三", "a".repeat(39) + " b c", "  * * * spaced   ", "😀".repeat(45)]) {
    await both(p, "firstLine", args.firstLine, t);
  }
  for (const v of ["3", " 3.5 ", "-inf", "+Infinity", "nan", "1e3", ".5", "5.", "1e", "abc", 7, null, "", "0x10", "1_000"]) await both(p, "jsNumber", (x: Json) => {
    const n = args.jsNumber(x);
    return n === null ? null : Number.isNaN(n) ? "NaN" : n === Infinity ? "Infinity" : n === -Infinity ? "-Infinity" : n;
  }, v);
  for (const v of ["a", null, 1, 1.5, true, [1, "a"], { a: { b: [null] } }, -0, 1e21, 0.1]) await both(p, "jsString", args.jsString, v);
});

/// mb-actor.ts `#words`: what the actors are told in the station's words, by name (its switch, of actor.ts's).
function wordsTs(name: string, ...args: Json[]): Json {
  const errorBack = (error: Json): Error => {
    const message = typeof error?.message === "string" ? error.message : String(error);
    return error?.said === true ? new Said(message) : new Error(message);
  };
  switch (name) {
    case "shownLimitOf": {
      const model = shownLimitOf(args[0] ?? null);
      return model === undefined ? null : { model };
    }
    case "runtimeLabel": return runtimeLabel(args[0]);
    case "compactFailed": return compactFailed(errorBack(args[0]));
    case "cannotStartWords": return cannotStartWords(errorBack(args[0]));
    case "compactFailedNotice": return compactFailedNotice(args[0]);
    case "failureNotice": return failureNotice(args[0]);
    case "limitShownNotice": return limitShownNotice(args[0], args[1]);
    case "codexStillOld": return `⚠️ ${withSaid(tr("zh", "station.notice.codexStillOld"), args[0])}`;
    case "codexTooOld": return codexTooOld(args[0]);
    case "modelLimitOf": return modelLimitOf(args[0]);
    case "spentBefore": return SPENT_BEFORE;
    case "quoted": return chars(args[0], FALLBACK_MOST).split("\n").map((line) => `> ${line}`).join("\n");
  }
  throw new Error(`no words named ${name}`);
}

test("what the actors are told in the station's words, as actor.ts says it", { skip }, async () => {
  const p = await opened();
  const messages = ["", "  boom  ", "You've hit your Opus limit · resets 5pm", "You have reached your gpt-6-astra limit.", "you've hit your usage limit", "hit your 5-hour limit", "reached your weekly limit",
    "Error 401 Unauthorized", "403 Forbidden: request not allowed", "403 <html>Attention Required</html>", "429 Too Many Requests", "529 overloaded", "stream disconnected before completion", "prompt is too long",
    "The model requires a newer version of Codex.  Please upgrade to the latest app or CLI and try again.", "amodel requires a newer version of Codex. Please upgrade to the latest app or CLI and try again.",
    "line one\nline two ```code```", "x".repeat(250), "一".repeat(220) + "\nmore", "Not enough messages to compact"];
  for (const m of messages) {
    for (const reason of ["auth", "refused", "blocked", "denied", "rate_limit", "overloaded", "network", "context", "model", "exited", "other"]) {
      await both(p, "words", wordsTs, "failureNotice", { kind: "failed", reason, message: m });
      await both(p, "words", wordsTs, "compactFailedNotice", { kind: "failed", reason, message: m });
    }
    await both(p, "words", wordsTs, "failureNotice", { kind: "completed" });
    for (const said of [true, false]) {
      await both(p, "words", wordsTs, "cannotStartWords", { message: m, said });
      await both(p, "words", wordsTs, "compactFailed", { message: m, said });
    }
    await both(p, "words", wordsTs, "codexTooOld", m);
    await both(p, "words", wordsTs, "modelLimitOf", m);
    await both(p, "words", wordsTs, "codexStillOld", m);
    await both(p, "words", wordsTs, "quoted", m);
    await both(p, "words", wordsTs, "limitShownNotice", "claude-opus-5-5", m);
    await both(p, "words", wordsTs, "limitShownNotice", null, m);
    await both(p, "withSaid", withSaid, "Words", m);
  }
  for (const d of [null, "", "limit:", "limit:: x", "limit:opus: said", "limit:opus", "rate_limit: x"]) await both(p, "words", wordsTs, "shownLimitOf", d);
  for (const r of ["claude", "codex", "agy", "pi", "x"]) await both(p, "words", wordsTs, "runtimeLabel", r);
  await both(p, "words", wordsTs, "spentBefore");
  await both(p, "words", wordsTs, "quoted", "a\n".repeat(3000));
  await both(p, "words", wordsTs, "nope");
  for (const turn of [{ outcome: "failed", declared: null, detail: "network: x" }, { outcome: "failed", declared: "waiting", detail: "network: x" }, { outcome: "failed", declared: null, detail: "auth: x" },
    { outcome: "completed", declared: null, detail: null }, { outcome: "completed", declared: "all_done", detail: null }, { outcome: "failed", declared: null, detail: null }, { outcome: "aborted", declared: null, detail: "other:" }]) {
    await both(p, "retryable", retryable, turn);
  }
  for (const at of [0, 1_800_000_000_123, -1, 253_402_300_799_999]) await both(p, "timed", timed, "hello", at);
  for (const m of [{ surface: "chat", connect: "chat", message: { author: "a@x.com" } }, { surface: "slack:T1", connect: "cl", message: { author: "U1" } }]) await both(p, "personRef", personRef, m);
});

test("cards and their options, as args.ts keeps them and refuses them", { skip }, async () => {
  const p = await opened();
  const options: Json[] = [
    undefined, null, "", "  ", "nope", "[]", '["a","b"]', '[{"label":"x","recommended":"true"}]', "{bad", [], ["a"], ["a", "a"], [" a ", "b "],
    [{ label: "a", detail: " d ", recommended: true }, { label: "b", recommended: true }], [{ label: "" }], [{}], [1], [{ label: "a", action: "close" }],
    [{ label: "a", action: "maybe" }], ["1", "2", "3", "4", "5", "6", "7"], [{ label: 5, detail: 6 }], { label: "a" }, 7,
  ];
  for (const o of options) await both(p, "optionsArg", args.optionsArg, o);
  const cards: Json[] = [
    undefined, null, "", "{}", "null", '{"type":"text"}', { type: "text", placeholder: " hint " }, { type: "text", placeholder: "x".repeat(81) },
    { type: "options", options: ["a", "b"] }, { type: "options" }, { type: "login", login: "abc123" }, { type: "login", login: "ABC" },
    { type: "login", login: "abc", station: "f".repeat(64) }, { type: "login", login: "abc", station: "zz" }, { type: "login", login: "abc", station: "" },
    { type: "x" }, { type: "" }, {}, [1], 5, "garbage", { type: "text", assignee: " Someone@Example.com " }, { type: "text", assignee: "Bob" },
    { type: "text", assignee: "a b@c" }, { type: "text", assignee: 5 }, { type: "text", assignee: "a@b@c" }, { type: " options ", options: '["x"]' },
  ];
  for (const c of cards) {
    await both(p, "cardArg", args.cardArg, c, undefined);
    await both(p, "cardArg", args.cardArg, c, ["a", "b"]);
  }
  for (const o of [[{ label: "a" }, { label: "b", recommended: true }, { label: "c" }], [], null, "x", [{ label: 3 }]]) await both(p, "optionsSaid", args.optionsSaid, o);
  for (const c of [{ type: "options", options: [{ label: "y" }] }, { type: "login", login: "a" }, { type: "text" }, null]) await both(p, "cardSaid", args.cardSaid, c);
  const files = [[], [{ name: "a.png", path: "/a", size: 1 }], [{ name: "Chart.HTML", path: "/c", size: 2 }, { name: "b.htm", path: "/b", size: 3 }], [{ name: "x y?.html", path: "/x", size: 1 }]];
  for (const f of files) {
    for (const text of ["", "see [Chart.HTML](Chart.HTML)", "plain"]) {
      await both(p, "placeFigures", args.placeFigures, text, f);
      await both(p, "slackWithFiles", args.slackWithFiles, text, f, "https://ember.test/o/ws/st/k");
    }
  }
  for (const t of ["-stop", " <@U1> -STOP ", "<@U1><@U2> -compact", "<@U1> -clear now", "<@> -stop", "<@U-1> -stop", "-clear", "hello", "<@U1 -stop", " -stop "]) await both(p, "threadCommand", args.threadCommand, t);
  for (const m of ["chat.postMessage", "chat", "Chat.post", "a.b.c", "a.b1", "conversations.history", "a.", ".b"]) await both(p, "isSlackMethod", args.isSlackMethod, m);
});

/// Profiles as config.ts makes them, of several runtimes, accesses and workspaces.
const PROFILES: Json[] = [
  { id: "cc", name: "Claude A", runtime: "claude", runtimes: ["claude"], models: ["claude-opus-5-5", "claude-sonnet-5-5"], model: "claude-opus-5-5", access: { kind: "subscription" }, home: "/h/cc" },
  { id: "cc2", name: "Claude B", runtime: "claude", runtimes: ["claude"], models: ["anthropic/claude-opus-5-5"], access: { kind: "anthropic-api" }, home: "/h/cc2", withheld: ["ws2"] },
  { id: "cx", name: "Codex", runtime: "codex", runtimes: ["codex"], models: ["gpt-6-astra", "gpt-6.1-sol"], access: { kind: "subscription" }, home: "/h/cx", named: ["gpt-6.1-sol"] },
  { id: "agy", name: "Antigravity", runtime: "agy", runtimes: ["agy"], models: ["gemini-4-carbon", "gemini-4-hydrogen-high"], access: { kind: "api-provider", provider: "google" }, home: "/h/agy" },
  { id: "dv", name: "Devin", runtime: "devin", runtimes: ["devin"], models: ["swe-2", "fusion-claude-opus-5-5-sidekick-swe-2"], access: { kind: "api-provider", provider: "kimi-code" }, home: "/h/dv" },
  { id: "kimi", name: "Kimi", runtime: "claude", runtimes: ["claude"], models: [], access: { kind: "api-provider", provider: "kimi-code" }, home: "/h/k", enabled: false },
  { id: "shared", name: "Borrowed", runtime: "claude", runtimes: ["claude"], models: ["claude-opus-5-5"], share: { borrowed: true, workspaces: ["ws1"] }, home: "/h/s" },
];

test("models, profiles and the words of a run changed, as the TypeScript has them", { skip }, async () => {
  const p = await opened();
  const models = ["claude-opus-5-5", "anthropic/claude-opus-5-5", "claude-opus-5-5[1m]", "Claude-Opus-5-5", "gemini-4-hydrogen", "gemini-4-hydrogen-high", "gemini-4-carbon-low",
    "fusion-claude-opus-5-5-high-sidekick-swe-2", "fusion-claude-opus-5-5-sidekick-swe-2-medium", "swe-2", "gpt-6-astra", "openai/gpt-6.1-sol", "gpt-6.2-astra", "openai/gpt-6.2-sol", "gpt-5", "o4-mini", "deepseek-v4-pro",
    "qwen3-coder-480b", "llama-3.1-70b", "unknown-model", "claude-fable-5-2-20261101", "glm-4.6", "kimi-k2", "grok-5", "fusion-swe-2-sidekick-claude-sonnet-5-5-high", ""];
  for (const m of models) {
    await both(p, "modelName", modelName, m);
    await both(p, "ultrafastModel", ultrafastModel, m);
    await both(p, "ultrafastModel", ultrafastModel, m, ["gpt-6.2-astra", "gpt-6.2-sol"]);
    for (const prof of PROFILES) {
      await both(p, "spelling", spelling, prof, m);
      await both(p, "runs", runs, prof, m);
    }
    for (const o of models.slice(0, 8)) await both(p, "sameModel", sameModel, m, o);
  }
  for (const prof of PROFILES) {
    await both(p, "billedPerUse", billedPerUse, prof);
    for (const ws of [null, "ws1", "ws2"]) for (const home of [null, "ws1", "ws2"]) await both(p, "allowedIn", allowedIn, prof, ws, home);
  }
  for (const v of [{}, { speed: "fast" }, { speed: "nope", fast: true }, { fast: false }, { speed: "ultrafast" }, null]) await both(p, "chosenSpeed", chosenSpeed, v);
  // model-choice.ts
  for (const rt of [null, "claude", "codex", "agy"]) {
    await both(p, "candidates", choice.candidates, PROFILES, rt);
    await both(p, "candidates", choice.candidates, PROFILES, rt, true);
  }
  const cands = choice.candidates(PROFILES, null);
  const uses: Json[][] = [[], [{ runtime: "claude", model: "claude-opus-5-5", n: 4 }], [{ runtime: "claude", model: "anthropic/claude-opus-5-5", n: 3 }, { runtime: "codex", model: "gpt-6-astra", n: 2 }],
    [{ runtime: "codex", model: null, n: 5 }, { runtime: "codex", model: "nope", n: 1 }], [{ runtime: "agy", model: "gemini-4-carbon", n: 1 }, { runtime: "agy", model: "gemini-4-hydrogen-high", n: 1 }]];
  for (const u of uses) {
    await both(p, "choose", choice.choose, cands, u);
    await both(p, "choose", choice.choose, cands, u, cands.slice(0, 1));
    await both(p, "choose", choice.choose, cands.slice(0, 1), u);
  }
  const many = Array.from({ length: 20 }, (_, i) => ({ runtime: i % 2 === 0 ? "claude" : "codex", model: i === 3 ? null : `m-${i}` }));
  for (const u of uses) {
    await both(p, "few", choice.few, many, [...u, { runtime: "codex", model: "m-7", n: 9 }, { runtime: "claude", model: "M-8", n: 2 }], [{ runtime: "codex", model: "m-19", n: 0 }, { runtime: "claude", model: null }]);
    await both(p, "few", choice.few, many.slice(0, 5), u, []);
  }
  await both(p, "askWhich", choice.askWhich, [{ candidate: { runtime: "claude", model: null }, n: 0 }, { candidate: { runtime: "codex", model: "gpt-6-astra" }, n: 1 }, { candidate: { runtime: "codex", model: "x" }, n: 3 }], "this station");
  // run-change.ts, context-cap.ts
  const row = (o: Json) => ({ runtime: "claude", model: "claude-opus-5-5", effort: "high", fast: null, speed: null, profile: "cc", profilePinned: false, context: null, ...o });
  const names = { cc: "Claude A", cx: "Codex" };
  const rows = [row({}), row({ model: null }), row({ effort: null }), row({ fast: true }), row({ speed: "ultrafast" }), row({ tui: true }), row({ profile: "cx" }), row({ runtime: "codex", model: "gpt-6-astra", profile: "cx" }), row({ profile: "gone" }), row({ runtime: "nope" })];
  for (const r of rows) await both(p, "runShown", (x: Json, n: Json) => runChange.runShown(x, (id) => n[id] ?? null), r, names);
  for (const a of rows) {
    for (const b of rows) {
      const change = { was: runChange.runShown(a, (id) => (names as Json)[id] ?? null), now: runChange.runShown(b, (id) => (names as Json)[id] ?? null) };
      await both(p, "runChanged", runChange.runChanged, change);
      await both(p, "runChangeWords", runChange.runChangeWords, change, "zh");
      await both(p, "runChangeWords", runChange.runChangeWords, change, "en");
    }
  }
  for (const v of [undefined, null, 100_000, 99_999, 10_000_000, 10_000_001, 150_000.5, "200000", true]) {
    await both(p, "contextAsked", contextCap.contextAsked, v, "zh");
    await both(p, "contextAsked", contextCap.contextAsked, v, "en");
  }
  for (const rt of ["claude", "codex", "dsh", "agy"]) for (const c of [undefined, null, 200_000]) await both(p, "checkContext", contextCap.checkContext, rt, c, "en");
  for (const [key, a] of [["station.notice.runChanged", { was: "A", now: "B" }], ["station.session.badContext", { least: 100000 }], ["station.nope", {}], ["station.slack.viewSession", {}]] as const) {
    await both(p, "tr", tr, "zh", key, a);
    await both(p, "tr", tr, "en", key, a);
  }
});

test("the account pool picks as pool.ts does", { skip }, async () => {
  const p = await opened();
  const NOW = 1_800_000_000_000;
  const HOUR = 3_600_000;
  const quotas: Json[] = [
    null, undefined, { state: "error" }, { state: "ok", windows: [] },
    { state: "ok", windows: [{ minutes: 300, usedPercent: 40, resetsAt: NOW + HOUR }, { minutes: 10080, usedPercent: 30, resetsAt: NOW + 3 * 24 * HOUR }] },
    { state: "ok", windows: [{ minutes: 300, usedPercent: 85, resetsAt: NOW + HOUR }, { minutes: 10080, usedPercent: 10, resetsAt: NOW + 6 * 24 * HOUR }] },
    { state: "ok", windows: [{ minutes: 300, usedPercent: 100, resetsAt: NOW - 1 }, { minutes: 10080, usedPercent: 90, resetsAt: NOW + 2 * HOUR }] },
    { state: "ok", windows: [{ minutes: 300, usedPercent: 100, resetsAt: NOW + HOUR }] },
    { state: "ok", windows: [{ minutes: 300, usedPercent: "50" }, { minutes: 0, usedPercent: 10 }] },
    { state: "ok", windows: [{ minutes: 10080, usedPercent: 99 }] },
  ];
  for (const q of quotas) {
    await both(p, "urgency", pool.urgency, q, NOW);
    for (const h of [{ quota: q }, { quota: q, spent: true }, { quota: q, check: { state: "login" } }, { quota: q, check: { state: "ok" } }]) {
      await both(p, "usable", pool.usable, h, NOW);
      await both(p, "usable", pool.usable, h, undefined);
      await both(p, "signsIn", pool.signsIn, h);
    }
  }
  const calls = (ctx: (number | null)[], turns: (string | null)[], model = "claude-opus-5-5") => ctx.map((c, i) => ({ turn: turns[i] ?? null, profile: "cc", model, context: c }));
  const points: [string, number][] = [["claude-opus-5-5", 160_000]];
  for (const c of [calls([], []), calls([130_000], ["t1"]), calls([100_000], ["t1"]), calls([90_000, 30_000], ["t1", "t1"]), calls([90_000, 30_000, 40_000, 41_000], ["t1", "t1", "t2", "t3"]), calls([40_000, 10_000], ["a", "a"]), calls([null, 10], ["a", "b"])]) {
    await both(p, "cheapToLeave", (x: Json, pts: Json) => pool.cheapToLeave(x, new Map(pts)), c, points);
  }
  const healths = (i: number): Record<string, Json> => Object.fromEntries(PROFILES.map((pr, j) => [pr.id, { quota: quotas[(i + j) % quotas.length] ?? null, ...(j === i % 3 ? { check: { state: "failed" } } : {}) }]));
  for (let i = 0; i < 12; i++) {
    const s = { health: healths(i), load: Object.fromEntries(PROFILES.map((pr, j) => [pr.id, (i * j) % 3])), lastPicked: Object.fromEntries(PROFILES.map((pr, j) => [pr.id, (i + j) % 2 === 0 ? 0 : NOW - j])), now: NOW };
    const signals = { health: (id: string) => s.health[id] ?? {}, load: (id: string) => s.load[id] ?? 0, lastPicked: (id: string) => s.lastPicked[id] ?? 0, now: () => s.now };
    for (const model of [null, "claude-opus-5-5", "gpt-6-astra", "nope"]) {
      for (const strict of [false, true]) {
        await both(p, "pickProfile", (c: Json, m: Json) => pool.pickProfile(c, m, signals, strict), PROFILES, model, s, strict);
        await both(p, "pickProfile", (c: Json, m: Json) => pool.pickProfile(c, m, signals, strict), PROFILES.slice(0, 2), model, s, strict);
      }
    }
  }
  await both(p, "pickProfile", (c: Json) => pool.pickProfile(c, null, { health: () => ({}), load: () => 0, lastPicked: () => 0, now: () => 0 }, false), [], null, {}, false);
  const catalog = { claude: { "claude-opus-5-5": ["low", "high"], x: null }, agy: { "gemini-4-hydrogen": ["low", "high"] }, devin: { "claude-opus-5-5": ["max"] } };
  for (const rt of ["claude", "codex", "dsh", "grok", "cursor", "hermes", "agy", "devin", "pi"]) {
    await both(p, "fallbackEfforts", pool.fallbackEfforts, rt);
    for (const m of [null, "claude-opus-5-5", "anthropic/claude-opus-5-5", "gemini-4-hydrogen-high", "fusion-claude-opus-5-5-high-sidekick-swe-2", "x"]) {
      await both(p, "reportedEfforts", pool.reportedEfforts, rt, m, catalog);
      await both(p, "availableEfforts", pool.availableEfforts, rt, m, catalog);
    }
    for (const lists of [[], [["low", "high", "max"], ["high", "low"]], [["a"]]]) await both(p, "commonEfforts", pool.commonEfforts, lists, rt);
  }
  for (const prof of PROFILES) for (const m of [null, "claude-opus-5-5", "gpt-6-astra"]) await both(p, "serves", pool.serves, prof, m);
});

// ── the hub, on two databases alike ──

/// node:crypto's randomBytes made the test's, as the program's harness makes them (hub_harness.mbt `test_random_hex`):
/// byte `i` of the `k`th ask. The hub's keys and tokens are then the same on both.
let randomAsks = 0;
const testRandom = (n: number) => Buffer.from(Array.from({ length: n }, (_, i) => ((randomAsks + 1) * 37 + i * 11 + 5) & 255));
{
  const crypto = createRequire(import.meta.url)("node:crypto");
  const real = crypto.randomBytes;
  crypto.randomBytes = (n: number, ...rest: unknown[]) => {
    if (rest.length > 0) return real(n, ...rest);
    const b = testRandom(n);
    randomAsks++;
    return b;
  };
  syncBuiltinESMExports();
}

/// An actor as the hub holds it, recording what it is told: the same on both sides (A's in the TypeScript hub, B's
/// answering the program's asks).
class FakeActor {
  readonly key: string;
  readonly runtime: string;
  readonly side: Side;
  constructor(key: string, runtime: string, side: Side) {
    this.key = key;
    this.runtime = runtime;
    this.side = side;
  }
  processState() {
    return this.side.states[this.key]?.state ?? "cold";
  }
  /// What it holds that a snapshot keeps (a wait, a notice): what the test says.
  holdsState() {
    return this.side.states[this.key]?.holds === true;
  }
  async flushed() {}
  settled() {
    return true;
  }
  idleMs(now: number) {
    const s = this.side.states[this.key];
    return s?.idleSince === undefined ? null : now - s.idleSince;
  }
}
/// What an actor answers when asked (the rest answer nothing).
const ANSWERS: Record<string, unknown> = { compact: "compacted", clear: null, snapshot: null };
const ACTOR_CALLS = ["kick", "recover", "release", "suspend", "stop", "compact", "clear", "evict", "changed", "toolsAt", "takeRefill", "takeWait", "allowanceReset", "stopFromSlack",
  "notify", "warm", "cancelRetry", "retryFailed", "reassign", "runChanged", "putAway", "cleanArchive", "compactToCap", "goOn", "dispose", "close", "adopt", "snapshot"];
for (const call of ACTOR_CALLS) {
  (FakeActor.prototype as Json)[call] = function (this: FakeActor, ...a: unknown[]) {
    this.side.log.push(["actor", this.key, call, said(a)]);
    if (call === "snapshot") return Promise.resolve({ key: this.key, runtime: this.runtime, agent: null, turn: null, workingFor: [], notices: [], waitingMs: null, waitingSeconds: 0, nudges: 0, stopRequested: false, idleMs: 0 });
    return Promise.resolve(ANSWERS[call] === undefined ? undefined : ANSWERS[call]);
  };
}

/// A chat surface recording what is posted (hub-fakes' FakeChat's ways, alike on both sides).
class Surface {
  readonly connect: string;
  readonly bot: string;
  readonly side: Side;
  constructor(connect: string, bot: string, side: Side) {
    this.connect = connect;
    this.bot = bot;
    this.side = side;
  }
  botUserId() { return this.bot; }
  botName() { return "chat"; }
  workspace() { return "T1"; }
  async post(thread: Json, message: string, files: Json[]) {
    this.side.log.push(["post", this.connect, `${thread.channel}/${thread.threadTs}`, message, files.map((f: Json) => f.name)]);
    return `${9_000_000 + this.side.log.length}.000200`;
  }
  async download(file: Json) {
    if (file.id === "missing") throw new Error("missing_scope");
    return new TextEncoder().encode(`bytes of ${file.id}`);
  }
  history(thread: Json, before: string, limit: number) {
    const all: Json[] = EARLIER.get(thread.threadTs) ?? [];
    const earlier = all.filter((m) => Number(m.ts) < Number(before));
    return Promise.resolve(earlier.slice(Math.max(0, earlier.length - limit)));
  }
}
const EARLIER = new Map<string, Json[]>([["5000.000001", [{ ts: "4999.000001", user: "U9", text: "before the bot came" }, { ts: "4999.500001", user: "U8", text: "and more", files: [{ id: "F1", name: "a.txt", size: 3 }] }]]]);
const CHATS: [string, string][] = [["cl", "UBOT"], ["gpt", "UGPT"], ["team", "UTEAM"], ["w2", "UW2"]];

/// One side's records: what it did of the world, in order, and its actors' states as the test sets them.
type Side = { log: Json[]; states: Record<string, { state: string; idleSince?: number; holds?: boolean }>; actors: Map<string, FakeActor> };

/// Every table of a database, row by row (with its rowid where it has one), in one order.
function dump(store: Store): Record<string, unknown[]> {
  const out: Record<string, unknown[]> = {};
  const tables = store.db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").all() as { name: string }[];
  for (const { name } of tables) {
    const q = `"${name.replaceAll('"', '""')}"`;
    let all: unknown[];
    try { all = store.db.prepare(`SELECT rowid AS "#rowid", * FROM ${q}`).all(); }
    catch { all = store.db.prepare(`SELECT * FROM ${q}`).all(); }
    // (a store's epoch is made as each opens: the two were opened apart)
    if (name === "archive_last_meta") all = all.map((r) => ({ ...(r as Json), epoch: "" }));
    out[name] = all.map((r) => JSON.stringify(r)).sort();
  }
  return out;
}

/// The pair a scenario runs on, where A's calls need it.
let PAIR: HubPair | null = null;

/// The usage counter of A's hub, where the test started one.
const COUNTERS = new WeakMap<Hub, UsageCounter>();
const counterOf = (hub: Hub) => COUNTERS.get(hub);
/// What the usage counter's program finds as it reads, the same for both (the sessions it recorded calls of).
let usageFound: string[] = [];
/// A's reads, recorded as B's are: the program's read of A's counter made the test's.
let usageReadsTo: Json[] | null = null;
(MbUsageCounter.prototype as Json).read = async function (ask: Json) {
  usageReadsTo?.push(["usage.read", ask.only, ask.started, ask.last]);
  return { sessions: usageFound, added: usageFound.length, hints: { elsewhere: [], rollouts: [], said: [] }, from: null };
};

/// What the live view's program answers when asked (`now`, `carried`), the same for both.
const LIVE_ANSWERS: Record<string, Json> = {
  now: { "k": [{ type: "timeline", start: 0, entries: [], usage: null }, { type: "rate", tokensPerSecond: 3 }] },
  carried: { plans: [{ key: "k", at: 1, items: [], creating: [] }] },
};
const LOCATED = { runtime: "claude", paths: [{ path: "/t/a.jsonl", runtime: "claude" }] };
/// Where A's live view's shell records what it did (the scenario's A side's log).
const LIVE_LOG: { log: Json[] } = { log: [] };
/// A's live view's shell, over a program the test answers for (its calls recorded as B's are).
const LIVES = new WeakMap<Hub, { live: LiveHub; spec: Json }>();
function liveOf(hub: Hub, log: Json[]): { live: LiveHub; spec: Json } {
  let had = LIVES.get(hub);
  if (had) return had;
  const held: { live: LiveHub; spec: Json } = { live: null as never, spec: null };
  const program = {
    shell: (spec: Json) => void (held.spec = spec),
    call: (_key: string, method: string, args: Json[]) => (log.push(["live.call", method, said(args)]), Promise.resolve(LIVE_ANSWERS[method] ?? null)),
    busy: () => false,
  };
  const live = new LiveHub((key) => (log.push(["live.locate", key]), LOCATED as Json), undefined, () => program as Json);
  live.countWith({ of: (key) => hub.store.sessionUsage(key), ask: () => {} });
  live.heldTold = (key, message) => log.push(["live.heldTold", key, said(message)]);
  live.lengths = (key, n) => (hub as Json).noteLength(key, n);
  live.tailRead = async () => ({ start: 0, entries: [], state: { path: "/t" } }) as Json;
  live.history = { state: async () => [{ path: "/t" }] as Json, page: async () => ({ start: 1, entries: [{ i: 1 }] as Json, end: 3 }) };
  held.live = live;
  LIVES.set(hub, held);
  return held;
}

/// What the harness names that the TypeScript hub does with a field, not a method.
const A_CALLS: Record<string, (hub: Hub, ...x: Json[]) => unknown> = {
  told: (hub, station: string, bots: string[]) => void hub.toldBots.set(station, new Set(bots)),
  held: (hub, key: string) => hub.deps.held(key),
  moveOn: (hub) => hub.deps.moveOn?.(),
  dropActor: (hub, key: string) => hub.dropActor(key) !== undefined,
  bindSingle: (hub, connect: string, target: string | null, title: string | null, by: string | null) => lifecycle.bindSingle(hub, connect, target, title, by),
  openChat: (hub, session: string, by: string, title: string | null) => lifecycle.openChat(hub, session, by, title),
  addToThread: (hub, thread: number, session: string) => lifecycle.addToThread(hub, thread, session),
  say: (hub, thread: number, user: string, text: string, attachments?: Json[], quotes?: Json[], client?: string) => lifecycle.say(hub, thread, user, text, attachments, quotes, client ?? null),
  newSession: (hub, options: Json, lang?: Json) => lifecycle.newSession(hub, options, lang),
  archive: (hub, key: string, archived: boolean) => lifecycle.archive(hub, key, archived),
  archiveBy: (hub, key: string, archived: boolean, by: string) => lifecycle.archiveBy(hub, key, archived, by),
  archiveChat: (hub, thread: number, archived: boolean) => lifecycle.archiveChat(hub, thread, archived),
  deleteSession: (hub, key: string) => lifecycle.deleteSession(hub, key),
  configure: (hub, key: string, change: Json, lang?: Json) => lifecycle.configure(hub, key, change, lang),
  expireArchived: (hub, now: number) => lifecycle.expireArchived(hub, now),
  relieveArchived: (hub) => lifecycle.relieveArchived(hub, () => PAIR!.free("a")),
  continueMachineSession: (hub, roots: Json, found: Json, by: string, lang?: Json, ws?: string) => lifecycle.continueMachineSession(hub, roots, found, by, lang, ws ?? null),
  autoArchive: (hub, now: number, look?: Json) => {
    const missing = { unread: [] as number[], bindings: false, jobs: [] as string[], marks: false, last: [] as number[] };
    const next = lifecycle.autoArchive(hub, now, (t) => missing.unread.push(t), () => void (missing.bindings = true), (s) => missing.jobs.push(s), () => void (missing.marks = true), (t) => missing.last.push(t), look);
    return { next, missing };
  },
  usageNow: (hub, key: string) => usageNow(hub.store, key),
  threadsToldOf: (hub, key: string) => afresh.threadsToldOf(hub, key),
  startsAfresh: (hub, key: string, id: string, to: string, was: string | null) => afresh.startsAfresh(hub, key, id, hub.config().profiles.find((pr) => pr.id === to)!, was),
  toldCleared: (hub, key: string, readBack?: boolean) => afresh.toldCleared(hub, key, readBack),
  goesAfresh: (hub, key: string, now: number) => afresh.goesAfresh(hub, key, now),
  toldLongChat: (hub, key: string) => afresh.toldLongChat(hub, key),
  toldResumeLost: (hub, key: string) => afresh.toldResumeLost(hub, key),
  keepUsage: (hub, key: string, quiet?: boolean) => keepUsage(hub.store, key, quiet),
  usageSoon: (hub, key: string) => counterOf(hub)?.soon(key),
  readingAll: (hub) => counterOf(hub)?.readingAll() ?? true,
  usageStop: (hub) => void counterOf(hub)?.stop(),
  storeCall: (hub, name: string, ...x: Json[]) => (hub.store as Json)[name](...x),
  "live.subscribe": (hub, key: string, from: number, last: number | null, brief: boolean) => {
    let id = 0;
    id = liveOf(hub, LIVE_LOG.log).live.subscribe(key, from, last, (m) => LIVE_LOG.log.push(["live.listener", id, said(m)]), brief);
    return id;
  },
  "live.unsubscribe": (hub, key: string, id: number) => liveOf(hub, LIVE_LOG.log).live.unsubscribe(key, id),
  "live.forget": (hub, key: string) => liveOf(hub, LIVE_LOG.log).live.forget(key),
  "live.running": (hub, key: string, on: boolean) => liveOf(hub, LIVE_LOG.log).live.running(key, on),
  "live.event": (hub, key: string, event: Json) => liveOf(hub, LIVE_LOG.log).live.event(key, event),
  "live.soon": (hub, key: string) => liveOf(hub, LIVE_LOG.log).live.soon(key),
  "live.moved": (hub, key: string) => liveOf(hub, LIVE_LOG.log).live.moved(key),
  "live.turnEnded": (hub, key: string) => liveOf(hub, LIVE_LOG.log).live.turnEnded(key),
  "live.usageCounted": (hub) => liveOf(hub, LIVE_LOG.log).live.usageCounted(),
  "live.held": (hub) => liveOf(hub, LIVE_LOG.log).live.held(),
  "live.nowOf": (hub, keys: string[]) => liveOf(hub, LIVE_LOG.log).live.nowOf(keys),
  "live.carried": (hub) => liveOf(hub, LIVE_LOG.log).live.carried(),
  "live.takePlans": (hub, c: Json) => liveOf(hub, LIVE_LOG.log).live.takePlans(c),
  "live.takeTails": (hub, c: Json) => liveOf(hub, LIVE_LOG.log).live.takeTails(c),
  "live.told": (hub, f: string, args: Json[]) => liveOf(hub, LIVE_LOG.log).spec.told(f, args),
  "live.asked": (hub, f: string, args: Json[]) => liveOf(hub, LIVE_LOG.log).spec.asked(f, args),
  followAccounts: (hub, keys: string[], map: [string, string][]) => hub.followAccounts(keys, new Map(map)),
  holdChat: (hub, key: string, why: string, notice?: string) => hub.holdChat(key, why, notice === undefined ? undefined : () => notice),
  stoppedNotice: (hub, key: string) => hub.deps.stoppedNotice?.(key),
};

/// The TypeScript hub over A and the program's over B, on one clock, driven alike.
class HubPair {
  readonly dir = mkdtempSync(join(tmpdir(), "mb-session-hub-"));
  readonly dataDir = join(this.dir, "data");
  readonly raw: Json = {
    profiles: [
      { id: "cc", runtime: "claude", home: "homes/cc", models: ["claude-opus-5-5", "claude-sonnet-5-5"] },
      { id: "cc2", runtime: "claude", home: "homes/cc2", models: ["claude-opus-5-5"], access: { kind: "anthropic-api" } },
      { id: "cx", runtime: "codex", home: "homes/cx", models: ["gpt-6-astra"] },
    ],
    connects: [
      { id: "cl", slack: { botName: "Claude bot" }, bind: { runtime: "claude", model: "claude-opus-5-5", effort: "high" } },
      { id: "gpt", bind: { runtime: "codex" } },
      { id: "team", mode: "single-session", requireMention: true, bind: { runtime: "claude" } },
      { id: "pinned", bind: { runtime: "claude", profiles: ["cc2"] } },
      { id: "w2", bind: { runtime: "claude" }, workspace: "ws2" },
    ],
    askToName: false,
    maxWarmClaude: 1,
  };
  config: HubConfig = hubConfig(this.raw, this.dataDir);
  readonly t = testClock();
  now = 0;
  readonly a: Side = { log: [], states: {}, actors: new Map() };
  readonly b: Side = { log: [], states: {}, actors: new Map() };
  /// What the program asked of the world as it handed over (hub.ts `handOver`: settled, frozen, settled again), with
  /// the limit it gave each.
  readonly handoverAsks: Json[] = [];
  readonly tsA: Store;
  readonly tsB: Store;
  hub: Hub;
  readonly accountsB: Accounts;
  readonly surfacesA = new Map<string, Surface>();
  readonly surfacesB = new Map<string, Surface>();
  workspaces = ["ws"];

  readonly p: Program;
  constructor(p: Program) {
    this.p = p;
    this.tsA = Store.open(join(this.dir, "a", "stillfail.db"), null, this.t.clock);
    this.tsB = Store.open(join(this.dir, "b", "stillfail.db"), null, this.t.clock);
    for (const [id, bot] of CHATS) {
      this.surfacesA.set(id, new Surface(id, bot, this.a));
      this.surfacesB.set(id, new Surface(id, bot, this.b));
    }
    this.hub = this.newHub();
    const wsOfB = (key: string) => this.tsB.getSession(key)?.ws ?? this.workspaces[0] ?? null;
    this.accountsB = new Accounts({
      config: () => this.config,
      store: this.tsB,
      running: (except) => [...this.b.actors.values()].filter((x) => x.key !== except && x.processState() !== "cold").flatMap((x) => this.tsB.getSession(x.key)?.profile ?? []),
      clock: this.t.clock,
      allows: (key, profile) => allowedIn(profile, wsOfB(key), this.workspaces[0] ?? null),
    });
    p.onTell = (what, x) => (this.#told(what, x), this.#bHeard());
    p.onAsk = async (what, x) => {
      this.#answering++;
      try {
        const answer = this.#asked(what, x);
        this.#bHeard();
        return await answer;
      } finally {
        this.#answering--;
      }
    };
    // What B's own parts the test answers with (its accounts) write to B is heard by the program's hub as its store
    // tells it (a session changed: the live view told whether it runs), as A's hub hears A's.
    this.tsB.subscribe((change) => {
      if (this.#answering === 0) return;
      if (change.type === "session") this.b.log.push(["live", change.key, this.tsB.getSession(change.key)?.running === true]);
      else if (change.type === "sessionRemoved") this.b.log.push(["live", change.key, false]);
    });
  }

  /// The TypeScript hub over A (made again for the station that takes up from the one before).
  newHub(): Hub {
    const driver = (side: Side): Json => ({
      runtime: () => "claude",
      shutdown: async (...a: unknown[]) => void side.log.push(["drivers", "shutdown", said(a)]),
      evictIdle: async () => (side.log.push(["drivers", "evictIdle", []]), 0),
      detach: () => side.log.push(["drivers", "detach", []]),
    });
    const made = new Hub({
      config: () => this.config,
      store: this.tsA,
      chats: (id) => this.surfacesA.get(id) as Json,
      drivers: [driver(this.a)],
      mcpUrl: "http://127.0.0.1:1/mcp",
      internal: new InternalChat(),
      link: (key) => `https://ember.test/o/${made.wsOf(key) ?? "ws"}/st/${key.replaceAll(":", "%3A")}`,
      workspaces: () => this.workspaces,
      station: () => "st",
      runners: () => this.runners,
      endRunner: async (info) => void this.a.log.push(["runners.end", info.id]),
      clock: this.t.clock,
      cold: this.coldOf(this.a),
      // (as agents.ts makes it: the station's own data directory its own)
      places: new Places({ own: this.dataDir }),
      ...(this.moveOn === undefined ? {} : { moveOn: () => this.moveOn! }),
    });
    const hub = made as Json;
    hub.live.counted = async () => 7;
    hub.live.running = (key: string, on: boolean) => this.a.log.push(["live", key, on]);
    hub.live.forget = (key: string) => this.a.log.push(["live.forget", key]);
    hub.live.usageCounted = () => this.a.log.push(["live.usageCounted"]);
    this.a.actors.clear();
    hub.actor = (row: Json) => {
      const had = this.a.actors.get(row.key);
      if (had) return had;
      const runtime = runtimeNamed(row.runtime);
      if (!runtime) throw new Error(`session ${row.key} runs an unknown runtime ${row.runtime}`);
      const actor = new FakeActor(row.key, runtime, this.a);
      this.a.actors.set(row.key, actor);
      made.actors.set(row.key, actor as Json);
      this.a.log.push(["made", row.key, runtime]);
      return actor;
    };
    return made;
  }
  /// Cold storage that records what it is asked (alike on both sides): each archived session holds more.
  coldOf(side: Side): Json {
    return {
      isCold: async () => false,
      restore: () => {},
      pack: () => {},
      holdsMore: async (key: string) => (side.log.push(["cold.holdsMore", key]), true),
      expire: async (key: string, before: number) => void side.log.push(["cold.expire", key, before]),
    };
  }
  /// How many times more the disk says it is low, on each side (`relieveArchived`'s `free`).
  lowFor = { a: 0, b: 0 };
  free(side: "a" | "b"): number {
    (side === "a" ? this.a : this.b).log.push(["disk.free"]);
    return this.lowFor[side]-- > 0 ? 0 : Number.MAX_SAFE_INTEGER;
  }
  /// What the world answers B's asks of a name with, in turn (the store's steps the program is driven by).
  scripted: Record<string, Json[]> = {};
  /// Whether moving to another station is on (features.ts stationMoveOn), as hub.ts is given it; undefined: not said.
  moveOn: boolean | undefined = undefined;
  /// The runners alive on the machine, as both are told.
  runners: string[] = [];
  /// Where B's side keeps the files the program writes and reads (A's are the data directory's).
  shadow(path: string): string {
    return path.startsWith(this.dataDir) ? join(this.dir, "b-data", path.slice(this.dataDir.length)) : path;
  }
  /// The next station: a hub made anew on each side over the same databases.
  async next() {
    this.hub = this.newHub();
    this.b.actors.clear();
    await this.open();
  }

  #answering = 0;
  #sandboxNamesB: SandboxNameBuilder | null = null;

  /// What the program told of the world, done on B's side.
  #told(what: string, x: Json) {
    const b = this.b;
    if (what === "actor.made") {
      const actor = new FakeActor(x.key, x.runtime, b);
      b.actors.set(x.key, actor);
      b.log.push(["made", x.key, x.runtime]);
    } else if (what === "actor") void (b.actors.get(x.key) as Json)[x.call](...x.args);
    else if (what === "live.running") b.log.push(["live", x.key, x.running]);
    else if (what === "chat.post") void this.surfacesB.get(x.connect)?.post(x.thread, x.text, x.files).catch(() => {});
    else if (what === "drivers") b.log.push(["drivers", x.call, x.args]);
    else if (what === "live.forget") b.log.push(["live.forget", x]);
    else if (what === "live.usageCounted") b.log.push(["live.usageCounted"]);
    else if (what === "live.call") b.log.push(["live.call", x.method, x.args]);
    else if (what.startsWith("usageCheck.")) b.log.push([what, x]);
    else if (what === "live.listener") b.log.push(["live.listener", x.id, x.message]);
    else if (what === "live.heldTold") b.log.push(["live.heldTold", x.key, x.message]);
  }

  /// What the program asked of the world, answered from B's side.
  async #asked(what: string, x: Json): Promise<Json> {
    const b = this.b;
    switch (what) {
      case "actor": return (b.actors.get(x.key) as Json)[x.call](...x.args);
      case "chat.post": {
        const s = this.surfacesB.get(x.connect);
        if (!s) throw new Error(`connect ${x.connect} is not connected`);
        return s.post(x.thread, x.text, x.files);
      }
      case "chat.history": return this.surfacesB.get(x.connect)!.history(x.thread, x.before, x.limit);
      case "chat.downloadTo": {
        try {
          const bytes = await this.surfacesB.get(x.connect)!.download(x.file);
          await mkdir(this.shadow(x.dir), { recursive: true });
          await writeFile(this.shadow(x.path), bytes);
          return { size: bytes.length, facts: await shownFactsSoon(this.shadow(x.path)) };
        } catch (error) {
          return { error: (error as Error).message };
        }
      }
      case "drivers.evictIdle": return (b.log.push(["drivers", "evictIdle", []]), 0);
      case "accounts.pick": {
        const profiles = x.candidates.map((id: string) => this.config.profiles.find((pr) => pr.id === id)!);
        try {
          return this.accountsB.pick(profiles, x.model, x.strict);
        } catch (error) {
          return { error: (error as Error).message };
        }
      }
      case "accounts.goesOnWith": return this.accountsB.goesOnWith(x.row, x.profile);
      case "accounts.resetAllowance": return this.accountsB.resetAllowance(x), null;
      case "accounts.runOn": return x.holding === undefined ? (this.accountsB.runOn(x.key), true) : (this.accountsB.runOn(x.key, x.holding, x.quiet), true);
      case "fs.mkdirs": for (const d of x) await mkdir(this.shadow(d), { recursive: true }); return null;
      case "fs.write": await mkdir(join(this.shadow(x.path), ".."), { recursive: true }); await writeFile(this.shadow(x.path), x.text); return null;
      case "fs.read": return readFile(this.shadow(x.path), "utf8").catch(() => null);
      case "fs.rm": await rm(this.shadow(x.path), { force: true }); return null;
      case "actors.settled": case "drivers.freeze": this.handoverAsks.push([what, x.limitMs]); return {};
      case "runners.allLeft": return {};
      case "runners": return this.runners;
      case "runnerId": return runnerId(x.runtime, x.key);
      case "sandboxNames.takeUp": {
        // (the builder of the lookup of sessions by their runners' names, the station's readers', made on B as on A)
        this.#sandboxNamesB ??= new SandboxNameBuilder(this.tsB, Promise.resolve(), () => false);
        const found = this.#sandboxNamesB.takeUp(x);
        return found === "fallback" ? null : found;
      }
      case "drivers.adopt": return null;
      case "drivers.owns": return x.startsWith("claude-");
      case "runners.end": b.log.push(["runners.end", x.id]); return null;
      case "accounts.change": {
        try {
          return this.accountsB.change(x.key, x.change, x.lang);
        } catch (error) {
          return { error: (error as Error).message };
        }
      }
      case "accounts.repick": return this.accountsB.repick(x), null;
      case "machine.transcriptOf": return null;
      case "live.call": b.log.push(["live.call", x.method, x.args]); return LIVE_ANSWERS[x.method] ?? null;
      case "live.locate": b.log.push(["live.locate", x.key]); return LOCATED;
      case "live.tailRead": return { start: 0, entries: [], state: { path: "/t" } };
      case "live.page": return { start: 1, entries: [{ i: 1 }], end: 3 };
      case "live.state": return [{ path: "/t" }];
      case "live.handedOver": return null;
      case "cold.expires": return true;
      case "cold.holdsMore": b.log.push(["cold.holdsMore", x]); return true;
      case "cold.expire": b.log.push(["cold.expire", x.key, x.before]); return null;
      case "disk.low": return this.free("b") < DISK_LOW_BYTES;
      case "places.directory": {
        try {
          await new Places({ own: x.own }).directory(x.path, { lang: x.lang });
          return null;
        } catch (error) {
          return error instanceof PlaceRefused ? { refused: error.code, message: error.message } : { refused: "other", message: (error as Error).message };
        }
      }
      case "machine.copyTranscript": {
        // (lifecycle.ts `copyTranscript`, its main file: what the machine keeps copied where the station's runtimes keep theirs)
        const root = x.runtime === "claude" ? x.roots.claude : x.roots.codex;
        const rel = relative(root, x.found.path);
        if (rel.startsWith("..") || rel === "") return { error: `${x.found.path} is not the machine's` };
        const to = join(sharedTranscripts(this.dataDir, x.runtime), rel);
        await mkdir(join(this.shadow(to), ".."), { recursive: true });
        await writeFile(this.shadow(to), await readFile(x.found.path));
        return to;
      }
      case "live.counted": return 7;
      case "agents.along": case "agents.jobsRelaunch": case "agents.jobsStopAll": case "agents.becomeRig": b.log.push([what, x]); return null;
      case "usage.drainStep": case "usage.stopIndexes": case "usage.inMemory": case "usage.retireStep": {
        b.log.push([what, x]);
        const next = this.scripted[what]?.shift();
        if (next instanceof Error) throw next;
        return next ?? null;
      }
      case "agents.openDoor": b.log.push([what]); return "http://127.0.0.1:4750/mcp";
      case "usage.read": b.log.push(["usage.read", x.only, x.started, x.last]); return { sessions: usageFound, added: usageFound.length, from: null };
      case "accounts.modelEfforts": return this.accountsB.modelEfforts(x.runtime, x.model, x.pinned, (pr) => x.allowed.includes(pr.id));
      case "cold.restore": return null;
      case "store.archiveDir": return this.tsB.archiveDir();
      case "transcripts.of": case "marks.forget": return [];
      case "fs.rmRoom": await rm(this.shadow(x.home), { recursive: true, force: true }); return null;
      case "waitForWorkspaceActivity.has": case "prepareLegacyEdits.has": case "logins.has": return false;
      default: throw new Error(`no world call ${what}`);
    }
  }

  async open() {
    await this.p.ask({ op: "hub", hub: "open", db: join(this.dir, "b", "stillfail.db"), latestNote: latestNote(), ...this.#world() });
  }
  #world() {
    const chats: Record<string, Json> = Object.fromEntries(CHATS.map(([id, bot]) => [id, { botUserId: bot, workspace: "T1", has: ["download", "history"] }]));
    chats.chat = { botUserId: "UEMBER", workspace: null, has: [] };
    return { config: this.config, workspaces: this.workspaces, station: "st", links: true, chats, states: this.a.states, now: this.now, moveOn: this.moveOn ?? null };
  }
  /// The config, the workspaces or the actors' states changed, alike on both.
  async set(change: () => void) {
    change();
    this.config = hubConfig(this.raw, this.dataDir);
    this.b.states = this.a.states;
    await this.p.ask({ op: "hub", hub: "set", ...this.#world() });
  }
  /// The clock moved on by `ms`: what was due runs on both.
  async advance(ms: number, compare = true) {
    this.now += ms;
    await this.t.adjust(ms);
    await settle();
    await this.p.ask({ op: "hub", hub: "advance", now: this.now });
    await settle();
    // (B's alone, where a scenario looks at what the program did by itself: left for it)
    if (compare) this.compareLogs(`after ${ms} ms more`);
  }
  /// A write alike on both stores (what the scenario stands on).
  both(write: (s: Store) => void) {
    write(this.tsA);
    write(this.tsB);
    // (what A's hub heard of its store meanwhile is the scenario's, not a step's: B's hears nothing of writes to B)
    this.a.log.length = 0;
  }
  compareLogs(where: string) {
    if (process.env.HUB_DEBUG) console.log(where, JSON.stringify(this.a.log), JSON.stringify(this.b.log), this.t.clock.currentTimeMillisUnsafe(), this.now, JSON.stringify(this.a.states));
    assert.deepEqual(this.b.log, this.a.log, `what each did of the world: ${where}`);
    this.a.log.length = 0;
    this.b.log.length = 0;
  }
  /// One of the hub's methods on both, compared: what it gives (or the words it is refused with) and what it did.
  async call(name: string, ...given: Json[]): Promise<Json> {
    const randomBefore = randomAsks;
    let want: Json;
    try {
      const hub = this.hub as Json;
      const run = A_CALLS[name] ? (...x: Json[]) => A_CALLS[name]!(this.hub, ...x) : (...x: Json[]) => hub[name](...x);
      want = { result: said(await run(...structuredClone(given))) };
    } catch (error) {
      want = { error: (error as Error).message };
    }
    await settle();
    const randomA = randomAsks - randomBefore;
    const got = await this.p.ask({ op: "hub", hub: "call", fn: name, args: said(given) });
    await settle();
    const answer = got.error !== undefined ? { error: got.error } : { result: got.result };
    const where = `${name}(${JSON.stringify(given).slice(0, 300)})`;
    if (process.env.HUB_DEBUG) console.log("=>", where.slice(0, 120), JSON.stringify(want).slice(0, 300));
    assert.deepEqual(answer, want, `${where} gives alike`);
    this.compareLogs(where);
    void randomA;
    return want.result;
  }
  /// The lookups of sessions by their runners' names, prepared as each side took up (a program of their own each),
  /// once both are done.
  async sandboxNamesPrepared() {
    for (const builder of [(this.hub as Json).sandboxNames, this.#sandboxNamesB]) {
      while (builder?.pending) await builder.pending;
    }
  }
  /// Once B's world has seen what `seen` waits for (each thing the program tells or asks is looked at as it comes).
  async untilB(seen: (log: Json[]) => boolean, why: string): Promise<void> {
    if (seen(this.b.log)) return;
    const waited = new Promise<void>((resolve) => this.#bWaits.push(() => (seen(this.b.log) ? (resolve(), true) : false)));
    // (what was sent the program before is taken, and what it told of it heard here, once a call of its own sent after it
    // is answered: it runs the calls' fibers in turn and says all on one stdout. `given` counts this process's work
    // alone, not the program's: on a busy runner what it told came after `given` gave up, 2026-11-17)
    await this.askB("moveOn");
    return given(waited, why);
  }
  #bWaits: (() => boolean)[] = [];
  #bHeard() {
    this.#bWaits = this.#bWaits.filter((w) => !w());
  }
  /// One of the program's alone, its answer only (one waited on while others go: what it did stays in B's log).
  async askB(name: string, ...given: Json[]): Promise<Json> {
    const got = await this.p.ask({ op: "hub", hub: "call", fn: name, args: said(given) });
    return got.error !== undefined ? { error: got.error } : { result: got.result };
  }
  /// One of the program's alone (what has no TypeScript to be held to but its reading: agents.ts's closures), and
  /// what it did of the world.
  async callB(name: string, ...given: Json[]): Promise<{ answer: Json; did: Json[] }> {
    const got = await this.p.ask({ op: "hub", hub: "call", fn: name, args: said(given) });
    await settle();
    const did = this.b.log.splice(0);
    if (process.env.HUB_DEBUG) console.log("B", name, JSON.stringify(given).slice(0, 120), JSON.stringify(did));
    return { answer: got.error !== undefined ? { error: got.error } : { result: got.result }, did };
  }
  compareStores(where: string) {
    assert.deepEqual(dump(this.tsB), dump(this.tsA), `the databases alike: ${where}`);
  }
  async close() {
    await this.hub.shutdown().catch(() => {});
    this.tsA.close();
    this.tsB.close();
    rmSync(this.dir, { recursive: true, force: true });
  }
}

const msg = (o: Json): Json => ({ channel: "C1", user: "U1", text: "<@UBOT> hello", addressed: true, ...o });

test("messages in: sessions made, threads followed, delivered and commanded, as hub.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  // A new thread, addressed: its session made, its link said, the message recorded and delivered.
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000001" }));
  // The same message again (Slack sends a mention twice): nothing new.
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000001" }));
  // A reply not addressed: delivered to the thread's session.
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000002", text: "more", addressed: false }));
  // Commands of the thread's sessions.
  for (const [i, t] of ["-stop", "<@UBOT> -compact", "-clear", "-CLEAR now"].entries()) await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: `1000.00001${i}`, text: t, addressed: false }));
  // Chatter in a thread nobody takes part in.
  await pair.call("accept", "cl", msg({ threadTs: "2000.000001", ts: "2000.000001", addressed: false, text: "hi all" }));
  // Its own bot, and another station's notice: not messages.
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000100", user: "UGPT", text: "posted" }));
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000101", user: "UOTHER", text: "⚠️ notice⁣" }));
  await pair.call("told", "st2", ["UOTHER"]);
  // A thread joined mid-way: what was said before recorded first, its files fetched (one cannot be).
  await pair.call("accept", "cl", msg({ threadTs: "5000.000001", ts: "5000.000009", files: [{ id: "F2", name: "pic/../x.png", size: 9 }, { id: "missing", name: "gone.pdf", size: 1 }, { id: "F3", name: "big.bin", size: 60 * 1024 * 1024 }] }));
  // Another connect's bot in the same channel, a model chosen with the message, and one no profile runs.
  await pair.call("accept", "gpt", msg({ threadTs: "1000.000001", ts: "1000.000200", user: "U2", text: "<@UGPT> look" }));
  await pair.call("accept", "cl", msg({ threadTs: "3000.000001", ts: "3000.000001", model: { runtime: "codex", model: "gpt-6-astra" } }));
  await pair.call("accept", "cl", msg({ threadTs: "3100.000001", ts: "3100.000001", model: { runtime: "codex", model: "nope" } }));
  await pair.call("accept", "cl", msg({ threadTs: "3200.000001", ts: "3200.000001", model: { runtime: "nobody", model: "x" } }));
  await pair.call("accept", "pinned", msg({ threadTs: "3300.000001", ts: "3300.000001", text: "<@UPIN> go" }));
  // A single-session connect: needs a mention, then takes every thread into its one session.
  await pair.call("accept", "team", msg({ threadTs: "4000.000001", ts: "4000.000001", addressed: false, text: "unaddressed" }));
  await pair.call("accept", "team", msg({ threadTs: "4000.000001", ts: "4000.000002", text: "<@UTEAM> start" }));
  await pair.call("accept", "team", msg({ threadTs: "4000.000001", ts: "4000.000003", addressed: false, text: "go on" }));
  await pair.call("accept", "team", msg({ threadTs: "4100.000001", ts: "4100.000001", text: "<@UTEAM> elsewhere" }));
  // A connect that is not there.
  await pair.call("accept", "nope", msg({ threadTs: "4200.000001", ts: "4200.000001" }));
  // Events: a stop from Slack, an edit, a login code on no card.
  await pair.call("receive", "cl", { type: "stop", channel: "C1", threadTs: "1000.000001", ts: "1000.000300" });
  await pair.call("receive", "cl", { type: "edit", channel: "C1", threadTs: "1000.000001", ts: "1000.000002", text: "more, edited" });
  await pair.call("receive", "cl", { type: "loginCode", channel: "C1", threadTs: "1000.000001", ts: "1000.000002", code: "123", user: "U1" });
  await pair.call("receive", "cl", { type: "message", message: msg({ threadTs: "1000.000001", ts: "1000.000400", text: "via receive", addressed: false }) });
  // Archived by hand: told so once a message, nothing delivered.
  const thread = pair.tsA.threadAt("slack:T1", "C1", "3000.000001")!;
  pair.both((s) => s.setThreadHidden(thread.id, true, "manual"));
  pair.both((s) => s.setArchived("cl:C1:3000.000001", true, "manual"));
  await pair.call("accept", "cl", msg({ threadTs: "3000.000001", ts: "3000.000002", text: "anyone?" }));
  await pair.call("accept", "cl", msg({ threadTs: "3000.000001", ts: "3000.000002", text: "anyone?" }));
  // Delivered by the hub's own calls: a letter, an agent's post shared, a delivery tried again.
  const t1 = pair.tsA.threadAt("slack:T1", "C1", "1000.000001")!;
  await pair.call("deliver", t1.id, 2, ["cl:C1:1000.000001", "gpt:C1:1000.000001", "nobody"], "again", { retryPending: true });
  await pair.call("shared", t1.id, 2, "gpt:C1:1000.000001", "-stop");
  pair.both((s) => s.insertLetter({ thread: t1.id, ts: "1000.000500", authorKind: "agent", author: "chat:c-x", text: "a letter", letter: { from: "chat:c-x" } as Json }));
  await pair.call("deliverLetter", t1.id, 1, ["cl:C1:1000.000001", "gpt:C1:1000.000001"]);
  pair.compareStores("after the messages");
});

test("holds, workspaces, held chats, recovery, idle processes and the pages' commands, as hub.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  // Sessions of two workspaces, one running, one with a message waiting.
  await pair.set(() => (pair.workspaces = ["ws", "ws2"]));
  for (const [i, ts] of ["1000.000001", "1200.000001"].entries()) {
    await pair.call("accept", "cl", msg({ threadTs: ts, ts, user: `U${i}` }));
  }
  await pair.call("accept", "w2", msg({ threadTs: "1100.000001", ts: "1100.000001", text: "<@UW2> there" }));
  await pair.call("accept", "gpt", msg({ threadTs: "1300.000001", ts: "1300.000001", text: "<@UGPT> hi" }));
  pair.both((s) => s.setRunning("cl:C1:1200.000001", true));
  // Holds: none starts while any stands; let go, the actors are released and what waits kicked.
  await pair.call("hold", "starting");
  await pair.call("hold", "drain");
  await pair.call("holds", "drain");
  await pair.call("held", "cl:C1:1000.000001");
  await pair.call("release", "drain");
  await pair.call("release", "drain");
  await pair.call("release", "starting");
  await pair.call("held", "cl:C1:1000.000001");
  // Workspaces: one quiet (its chats go to another station), then not; one left and come back to.
  for (const key of ["cl:C1:1000.000001", "w2:C1:1100.000001", "nobody"]) {
    await pair.call("ofWorkspace", key, "ws");
    await pair.call("ofWorkspace", key, "ws2");
    await pair.call("handedOver", key);
  }
  await pair.call("quiet", "ws2");
  await pair.call("quietIn", "ws2");
  await pair.call("handedOver", "w2:C1:1100.000001");
  await pair.call("held", "w2:C1:1100.000001");
  await pair.call("accept", "w2", msg({ threadTs: "1100.000001", ts: "1100.000002", text: "while quiet" }));
  await pair.call("unquiet", "ws2");
  await pair.call("unquiet", "ws2");
  await pair.call("quiet", "ws");
  await pair.call("unquiet", "ws");
  await pair.call("leftWorkspace", "ws2");
  await pair.call("backIn", "ws2");
  // Chats held one at a time: what they say once a person speaks, let go, woken.
  await pair.call("holdChat", "cl:C1:1000.000001", "moving", "it moves to st2");
  await pair.call("chatHeld", "cl:C1:1000.000001");
  await pair.call("handedOver", "cl:C1:1000.000001");
  await pair.call("stoppedNotice", "cl:C1:1000.000001");
  await pair.call("stoppedNotice", "cl:C1:1000.000001");
  await pair.call("releaseChat", "cl:C1:1000.000001");
  await pair.call("releaseChat", "cl:C1:1000.000001");
  await pair.call("stoppedNotice", "cl:C1:1000.000001");
  await pair.call("wakeChat", "cl:C1:1200.000001");
  await pair.call("wakeChat", "nobody");
  await pair.call("movedTo", "cl", "C1", "1000.000001");
  // Restarted: cut-off turns resume, what waits goes on; a runtime installed.
  await pair.call("recover");
  await pair.call("installed", "claude");
  await pair.call("installed", "codex");
  await pair.call("toolsAt", "http://127.0.0.1:2/mcp");
  await pair.call("suspendAll");
  // Processes: idle ones past the warm limit evicted, oldest first, at their deadlines.
  await pair.set(() => {
    pair.a.states = {
      "cl:C1:1000.000001": { state: "warm", idleSince: pair.now - 60_000 },
      "w2:C1:1100.000001": { state: "warm", idleSince: pair.now - 10_000 },
      "cl:C1:1200.000001": { state: "running" },
      "gpt:C1:1300.000001": { state: "warm", idleSince: pair.now - 5_000_000 },
    };
  });
  await pair.call("busy", "cl:C1:1200.000001");
  await pair.call("running");
  await pair.call("anyRunning");
  await pair.call("processState", "cl:C1:1000.000001");
  await pair.call("processState", "nobody");
  await pair.call("processes");
  await pair.call("idleNow", "cl:C1:1000.000001");
  await pair.call("idleNow", "w2:C1:1100.000001");
  await pair.advance(1_000_000);
  await pair.advance(1_000_000);
  await pair.call("idleNow", "w2:C1:1100.000001");
  await pair.advance(30 * 60_000);
  await pair.call("evictAllIdle");
  await pair.call("evict", "cl:C1:1000.000001");
  await pair.call("evict", "nobody");
  await pair.call("changed", "cl:C1:1000.000001", true);
  await pair.call("everyChanged");
  await pair.call("runtimeUpdated", "codex");
  await pair.call("profileLoginChanged", "cc");
  await pair.call("allowanceReset", "cc");
  await pair.call("followAccounts", ["cl:C1:1000.000001", "nobody"], [["cc", "cc2"]]);
  // The pages' commands.
  for (const call of ["warm", "stop", "compact", "notify"]) {
    await pair.call(call, "cl:C1:1000.000001", ...(call === "notify" ? ["a word"] : []));
    await pair.call(call, "nobody", ...(call === "notify" ? ["a word"] : []));
  }
  await pair.call("clear", "cl:C1:1000.000001", true);
  await pair.call("cancelRetry", "cl:C1:1000.000001", 1, 2);
  await pair.call("retryFailed", "cl:C1:1000.000001", 1, 2);
  await pair.call("reassign", "nobody", 1, 2);
  // Transcripts' lengths: the first written at once, the rest gathered for five seconds.
  await pair.call("noteLength", "cl:C1:1000.000001", 10);
  await pair.call("noteLength", "cl:C1:1000.000001", 20);
  await pair.call("noteLength", "w2:C1:1100.000001", 5);
  await pair.call("noteLength", "w2:C1:1100.000001", 7);
  pair.compareStores("lengths gathered");
  await pair.advance(5_000);
  pair.compareStores("lengths written");
  // What the station reads of its connects and workspaces.
  for (const c of ["cl", "gpt", "team", "chat", "pinned", "nope"]) {
    await pair.call("surface", c);
    await pair.call("modelsFor", c);
    await pair.call("modelsFirst", c, "U1");
  }
  for (const key of ["cl:C1:1000.000001", "w2:C1:1100.000001", "nobody"]) {
    await pair.call("wsOf", key);
    await pair.call("inWorkspace", key, "ws2");
  }
  await pair.call("wsOf", null);
  await pair.call("profilesIn", null);
  await pair.call("profilesIn", "ws2");
  // One archived going idle: what it left in the background ended, then its archive cleaned, one call after the other
  // (the program once asked its actor for a call it has not, `evictThenCleanArchive`)
  // (no process idle meanwhile: what else idleNow lets go comes in an order of each side's own scheduling)
  await pair.set(() => {
    pair.a.states = {};
  });
  pair.both((s) => s.setArchived("w2:C1:1100.000001", true, "manual"));
  const compareLogs = pair.compareLogs.bind(pair);
  const idleArchived: Json[] = [];
  pair.compareLogs = (where) => (idleArchived.push(...pair.a.log), compareLogs(where));
  await pair.call("idleNow", "w2:C1:1100.000001");
  pair.compareLogs = compareLogs;
  assert.deepEqual(idleArchived.filter((e) => e[0] === "actor" && e[1] === "w2:C1:1100.000001"), [["actor", "w2:C1:1100.000001", "evict", [true]], ["actor", "w2:C1:1100.000001", "cleanArchive", []]]);
  await pair.call("dropActor", "w2:C1:1100.000001");
  await pair.call("dropActor", "w2:C1:1100.000001");
  await pair.call("shutdown");
  pair.compareStores("at the end");
});

test("a handover and its taking up, runners nobody holds, a profile gone, as hub.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000001" }));
  await pair.call("accept", "cl", msg({ threadTs: "1100.000001", ts: "1100.000001" }));
  await pair.call("accept", "cl", msg({ threadTs: "1300.000001", ts: "1300.000001" }));
  await pair.call("accept", "gpt", msg({ threadTs: "1200.000001", ts: "1200.000001", text: "<@UGPT> go" }));
  pair.both((s) => s.setRunning("gpt:C1:1200.000001", true));
  pair.both((s) => s.startTurn("t-1", "gpt:C1:1200.000001", "normal"));
  await pair.set(() => {
    pair.a.states = {
      "cl:C1:1000.000001": { state: "warm", idleSince: pair.now - 1000 },
      "cl:C1:1100.000001": { state: "cold", holds: true },
      "cl:C1:1300.000001": { state: "running" },
      "gpt:C1:1200.000001": { state: "running" },
    };
  });
  // A profile gone under its sessions (#6948): only the one with a turn under way moved where another runs it; the idle
  // one's process ended, the cold one left as it is.
  await pair.call("profileGone", "cc");
  pair.compareStores("a profile gone");
  // Handed over: held, every actor's snapshot taken (those cold and holding nothing closed), the drivers let go.
  await pair.call("handOver");
  // What the drivers took in as they froze settled too before the snapshots, as hub.ts does.
  assert.deepEqual(pair.handoverAsks, [["actors.settled", 30_000], ["drivers.freeze", 30_000], ["actors.settled", 30_000]]);
  await pair.call("holds", "drain");
  // The next station takes up the snapshots, and of the runners it finds, those of sessions running.
  pair.runners = ["claude-zz", "term-1"];
  await pair.next();
  await pair.call("takeUp");
  await pair.call("recover");
  for (const [id, startedAt] of [["claude-x", 0], ["codex-y", 0], ["term-2", 0], ["claude-z", pair.now - 1000]] as const) {
    await pair.call("endOrphan", { id, startedAt }, pair.now);
  }
  await pair.call("adopt", { sessions: [{ key: "nobody", runtime: "claude", agent: null, turn: null, workingFor: [], notices: [], waitingMs: null, waitingSeconds: 0, nudges: 0, stopRequested: false, idleMs: 0 },
    { key: "cl:C1:1000.000001", runtime: "claude", agent: null, turn: null, workingFor: [], notices: ["n"], waitingMs: null, waitingSeconds: 0, nudges: 0, stopRequested: false, idleMs: 0 }] });
  // (the lookup of sessions by their runners' names, prepared by a program of its own as each side took up: its end
  // waited for on both before the tables are looked at)
  await pair.sandboxNamesPrepared();
  pair.compareStores("taken up");
});

test("chats made, said in, bound, archived and deleted, as lifecycle.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  // Sessions of their own: picked by the pool, given profiles, a model no profile runs, an effort not offered, a client
  // key that finds what it made again.
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", title: " First " });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", model: "claude-sonnet-5-5", effort: "high", clientKey: "ck-1" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", model: "claude-sonnet-5-5", effort: "high", clientKey: "ck-1" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", profiles: ["cc2", " cc2 ", ""], model: "claude-opus-5-5" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", profiles: ["cc", "cc2"], context: 200_000, fast: true });
  await pair.call("newSession", { runtime: "codex", createdBy: "a@x.com", speed: "ultrafast", model: "gpt-6-astra" });
  await pair.call("newSession", { runtime: "codex", createdBy: "a@x.com", speed: "warp" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", profile: "cc2", model: "claude-sonnet-5-5" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", profile: "nope" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", effort: "ludicrous" });
  await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", context: 5 });
  await pair.call("newSession", { runtime: "dsh", createdBy: "a@x.com" });
  await pair.call("newSession", { runtime: "codex", createdBy: "a@x.com", context: 200_000 });
  // Chats: one opened with a session, another joined to it, said in, archived by hand and shown again.
  const first = pair.tsA.listSessions().find((r) => r.title === "First")!;
  const second = pair.tsA.listSessions().find((r) => r.key !== first.key && r.connect === "chat")!;
  const chat: Json = await pair.call("openChat", first.key, "a@x.com", "A chat of its own");
  await pair.call("openChat", "nobody", "a@x.com", null);
  await pair.call("addToThread", chat.id, second.key);
  await pair.call("addToThread", chat.id, "nobody");
  await pair.call("addToThread", 999, second.key);
  await pair.call("say", chat.id, "a@x.com", "hello both", [], [], "web");
  await pair.call("say", chat.id, "a@x.com", "-stop");
  await pair.call("archiveChat", chat.id, true);
  await pair.call("say", chat.id, "a@x.com", "anyone?");
  await pair.call("archiveChat", chat.id, false);
  const home = pair.tsA.homeChat(first.key)!;
  await pair.call("archiveChat", home.id, true);
  await pair.call("archive", first.key, false);
  await pair.call("archiveBy", second.key, true, "auto");
  await pair.call("archive", "nobody", true);
  // A single-session connect bound: anew, to a session of its runtime, to one of another.
  await pair.call("bindSingle", "team", null, " Team ", "slack:team:U1");
  await pair.call("bindSingle", "team", first.key, null, null);
  await pair.call("bindSingle", "team", "nobody", null, null);
  const codex = pair.tsA.listSessions().find((r) => r.runtime === "codex")!;
  await pair.call("bindSingle", "team", codex.key, null, null);
  await pair.call("bindSingle", "cl", null, null, null);
  // Deleted.
  await pair.call("deleteSession", second.key);
  await pair.call("deleteSession", second.key);
  pair.compareStores("after the chats");
});

test("how a session runs changed, its usage now, and going on afresh, as lifecycle.ts and afresh.ts do", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  const made: Json = await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", model: "claude-opus-5-5" });
  const key = made[0] as string;
  await pair.call("newSession", { runtime: "codex", createdBy: "a@x.com" });
  // Its calls as the usage counter records them: two on a model with a price, the last writing the cache for an hour.
  pair.both((s) => s.setRuntimeSessionId(key, "rs-1"));
  const call = (id: string, at: number, context: number, long: number): Json => ({ id, at, model: "claude-opus-5-5", subagent: false, fast: false, input: 10, cacheRead: 1000, cacheWrite: long ? 0 : 50, cacheWriteLong: long, output: 20, calls: 1, context, window: 1_000_000 });
  pair.both((s) => s.recordUsage("/t/a.jsonl", { session: key, offset: 0, model: null }, "claude", [[call("c1", pair.now - 10_000, 60_000, 0), { turn: "t1", person: null, thread: null, profile: "cc" }], [call("c2", pair.now - 5_000, 120_000, 30)as Json, { turn: "t1", person: null, thread: null, profile: "cc" }]]));
  for (const k of [key, "nobody"]) {
    await pair.call("usageNow", k);
    await pair.call("threadsToldOf", k);
    await pair.call("toldCleared", k, false);
    await pair.call("toldCleared", k, true);
    await pair.call("toldLongChat", k);
    await pair.call("toldResumeLost", k);
    await pair.call("startsAfresh", k, "rs-1", "cc", null);
    await pair.call("startsAfresh", k, "rs-1", "cc2", "cc");
    await pair.call("startsAfresh", k, "rs-2", "cc2", null);
    for (const at of [pair.now, pair.now + 2 * 3_600_000]) await pair.call("goesAfresh", k, at);
  }
  for (let i = 0; i < 22; i++) await pair.call("say", made[1].id, "a@x.com", `message ${i}`);
  await pair.call("toldLongChat", key);
  await pair.call("configure", key, { tui: true });
  await pair.call("configure", key, { effort: "high" });
  await pair.call("configure", key, { tui: false });
  // Changed: going on afresh alone, another model and effort, a profile pinned, back to the pool, another runtime, a
  // most context under what it holds, a speed, refused ones.
  await pair.call("configure", key, { afresh: true });
  await pair.call("goesAfresh", key, pair.now + 2 * 3_600_000);
  await pair.call("configure", "nobody", { afresh: false });
  await pair.call("configure", key, { model: "claude-sonnet-5-5", effort: "low" });
  await pair.call("configure", key, { profile: "cc2" });
  await pair.call("configure", key, { profile: null, profiles: ["cc", "cc2"] });
  await pair.call("configure", key, { repick: true });
  await pair.call("configure", key, { context: 100_000 });
  await pair.call("configure", key, { context: null, fast: true });
  await pair.call("configure", key, { speed: "ultrafast" });
  await pair.call("configure", key, { runtime: "codex", model: "gpt-6-astra" });
  await pair.call("configure", key, { model: "nope" });
  await pair.call("configure", "nobody", { model: "x" });
  pair.compareStores("after the changes");
});

test("the usage counter's reads and the usage kept, as usage/counter.ts and module.ts do", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  after(() => void (usageReadsTo = null, usageFound = []));
  await pair.open();
  await pair.advance(1_800_000_000_000);
  const made: Json = await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com", model: "claude-opus-5-5" });
  const key = made[0] as string;
  // Started on both: read at once, then as the store says turns end, as sessions at work write, and every ten minutes.
  usageReadsTo = pair.a.log;
  A_CALLS.usageStart = (hub) => {
    const counter = new UsageCounter({ store: hub.store, config: () => ({ dataDir: pair.dataDir, profiles: pair.config.profiles }), clock: pair.t.clock, mb: "/nonexistent", dbPath: "/nonexistent.db" });
    COUNTERS.set(hub, counter);
    counter.start();
    keepCounted(hub.store, hub.live, counter);
  };
  await pair.call("usageStart");
  await pair.call("readingAll");
  // A session changes (a message): woken, settled, no turn ended: nothing read.
  await pair.call("say", made[1].id, "a@x.com", "hi");
  await pair.advance(1_000);
  await pair.advance(1_500);
  // A turn ends: read shortly after.
  await pair.call("storeCall", "startTurn", "t-1", key, "normal");
  await pair.advance(500);
  await pair.call("storeCall", "endTurn", "t-1", "completed", null, "all_done", null);
  await pair.advance(1_999);
  // What it read recorded calls of the session: its usage kept, the live view told.
  pair.both((s) => s.recordUsage("/t/a.jsonl", { session: key, offset: 0, model: null }, "claude", [[{ id: "c1", at: pair.now - 1000, model: "claude-opus-5-5", subagent: false, fast: false, input: 10, cacheRead: 100, cacheWrite: 5, cacheWriteLong: 0, output: 7, calls: 1, context: 70_000, window: 200_000 }, { turn: "t-1", person: null, thread: null, profile: "cc" }]]));
  usageFound = [key];
  await pair.call("usageSoon", key);
  await pair.advance(2_000);
  usageFound = [];
  pair.compareStores("usage recorded and kept");
  // A session at work wrote more: read alone, shortly.
  await pair.call("usageSoon", key);
  await pair.call("usageSoon", "other");
  await pair.advance(2_000);
  // Nothing more: the safety read ten minutes after the last.
  await pair.advance(599_000);
  await pair.advance(5_000);
  await pair.call("keepUsage", key, true);
  await pair.call("keepUsage", "nobody");
  await pair.call("storeCall", "usageChanged", [key], undefined, true);
  await pair.call("readingAll");
  await pair.call("usageStop");
  await pair.advance(700_000);
  pair.compareStores("usage kept");
});

test("idle sessions and chats archived by themselves, as lifecycle.ts autoArchive does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  const a: Json = await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com" });
  const b: Json = await pair.call("newSession", { runtime: "claude", createdBy: "b@x.com" });
  const c: Json = await pair.call("newSession", { runtime: "claude", createdBy: "c@x.com" });
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000001" }));
  const own: Json = await pair.call("openChat", a[0], "a@x.com", "Its own");
  await pair.call("say", b[1].id, "b@x.com", "unanswered for now");
  await pair.call("say", own.id, "a@x.com", "in its own");
  pair.both((s) => s.setRead("a@x.com", a[1].id, s.lastEntry(a[1].id)));
  pair.both((s) => s.setRead("c@x.com", c[1].id, s.lastEntry(c[1].id)));
  pair.both((s) => s.setPin("b@x.com", b[0], true));
  await pair.call("autoArchive", pair.now);
  for (const days of [0.5, 0.6, 2, 4]) {
    await pair.advance(days * 86_400_000);
    await pair.call("autoArchive", pair.now);
    pair.compareStores(`after ${days} days more`);
  }
  await pair.set(() => (pair.raw.autoArchiveDays = 0, pair.raw.slackArchiveDays = 0));
  await pair.call("autoArchive", pair.now);
});

test("the live view's shell: what it says the program, what it gives its listeners, what it answers, as live.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  LIVE_LOG.log = pair.a.log;
  await pair.open();
  await pair.advance(1_800_000_000_000);
  const made: Json = await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com" });
  const key = made[0] as string;
  const one = await pair.call("live.subscribe", key, 0, null, false);
  const two = await pair.call("live.subscribe", key, 5, 2, true);
  await pair.call("live.subscribe", "other", 0, null, false);
  await pair.call("live.running", key, true);
  await pair.call("live.event", key, { kind: "start", id: "s1", step: "text" });
  await pair.call("live.soon", key);
  await pair.call("live.moved", key);
  await pair.call("live.turnEnded", key);
  // What the program tells: a timeline to each listener, whole or in brief, with the session's usage; to the sessions
  // the station follows; the sessions it follows; a transcript's length; what it watches.
  const entries = [{ i: 1, text: "whole one", "~brief": { i: 1, text: "brief" } }, { i: 2, text: "only whole" }];
  await pair.call("live.told", "told", [key, [[one, false, false], [two, true, false], [99, false, false], [0, false, true]], { type: "timeline", start: 0, entries }, false]);
  await pair.call("live.told", "told", [key, [[one, false, false], [two, true, false]], { type: "timeline", start: 0, entries }, true]);
  await pair.call("live.told", "told", [key, [[one, false, false], [0, false, true]], { type: "rate", tokensPerSecond: 12 }, false]);
  await pair.call("live.told", "held", [[key, "other"]]);
  await pair.call("live.held");
  await pair.call("live.told", "length", [key, 42]);
  await pair.call("live.told", "watching", [key, true]);
  await pair.call("live.told", "watching", ["other", true]);
  await pair.call("live.usageCounted");
  pair.both((s) => s.recordUsage("/t/a.jsonl", { session: key, offset: 0, model: null }, "claude", [[{ id: "c1", at: pair.now, model: "claude-opus-5-5", subagent: false, fast: false, input: 1, cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: 1, calls: 1, context: 10, window: 100 }, { turn: null, person: null, thread: null, profile: "cc" }]]));
  await pair.call("keepUsage", key);
  await pair.call("live.usageCounted");
  await pair.call("live.usageCounted");
  await pair.call("live.told", "watching", ["other", false]);
  await pair.call("live.told", "begun", [key]);
  await pair.call("live.told", "pending", [true]);
  // What it asks: where a session's transcripts are, a page of its past, where its reading stands.
  await pair.call("live.asked", "locate", [key, false]);
  await pair.call("live.asked", "page", [key, 10, 5, true]);
  await pair.call("live.asked", "state", [key]);
  await pair.call("live.asked", "state", [key]);
  await pair.call("live.asked", "nothing", []);
  await pair.call("live.nowOf", [key]);
  await pair.call("live.carried");
  await pair.call("live.takePlans", [{ key, at: 1, items: [], creating: [] }]);
  await pair.call("live.takeTails", []);
  await pair.call("live.unsubscribe", key, two);
  await pair.call("live.unsubscribe", key, two);
  await pair.call("live.forget", key);
  await pair.call("live.told", "told", [key, [[one, false, false]], { type: "clear" }, false]);
  pair.compareStores("the live view's lengths");
});

test("archived workspaces emptied, the disk relieved, a machine's session continued, as lifecycle.ts does", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  PAIR = pair;
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  const made: Json[] = [];
  for (let i = 0; i < 3; i++) made.push(await pair.call("newSession", { runtime: "claude", createdBy: "a@x.com" }));
  await pair.call("expireArchived", pair.now);
  for (const [i, m] of made.entries()) {
    await pair.call("archive", m[0], true);
    await pair.advance(86_400_000 * (i + 1));
  }
  for (const days of [0, 3, 8]) {
    await pair.advance(days * 86_400_000);
    await pair.call("expireArchived", pair.now);
  }
  pair.lowFor = { a: 3, b: 3 };
  await pair.call("relieveArchived");
  pair.lowFor = { a: 0, b: 0 };
  await pair.call("relieveArchived");
  // A session of the machine's own Claude Code: continued in a chat, once.
  const cwd = mkdtempSync(join(tmpdir(), "mb-session-hub-cwd-"));
  after(() => rmSync(cwd, { recursive: true, force: true }));
  const roots = { claude: join(pair.dir, "machine", "claude"), codex: join(pair.dir, "machine", "codex") };
  const path = join(roots.claude, "projects", "p", "m-1.jsonl");
  await mkdir(join(roots.claude, "projects", "p"), { recursive: true });
  await writeFile(path, "{}\n");
  const found = { runtime: "claude", id: "m-1", cwd, title: null, first: "what was asked in the terminal, a long first line".repeat(3), model: "claude-sonnet-5-5", updatedAt: 1, size: 3, session: null, path };
  await pair.call("continueMachineSession", roots, found, "a@x.com");
  await pair.call("continueMachineSession", roots, found, "a@x.com");
  await pair.call("continueMachineSession", roots, { ...found, id: "m-2", cwd: join(cwd, "gone") }, "a@x.com");
  await pair.call("continueMachineSession", roots, { ...found, id: "m-3", runtime: "codex", model: null, path }, "a@x.com", "en", "ws2");
  pair.compareStores("after the machine's sessions");
});

test("the agents' side takes the sessions up and follows its workspaces, as agents.ts start and follow do", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  await pair.set(() => (pair.workspaces = ["ws", "ws2"]));
  await pair.call("accept", "cl", msg({ threadTs: "1000.000001", ts: "1000.000001" }));
  await pair.call("accept", "w2", msg({ threadTs: "1100.000001", ts: "1100.000001", text: "<@UW2> hi" }));
  await pair.call("hold", "starting");
  const place = (o: Json = {}) => ({ bound: true, joined: ["ws2"], home: "ws", first: "ws", removed: false, rigDue: false, ...o });
  // Started in its workspace: taken up, the door opened, its processes told it, turns let go, what was cut off resumed.
  const started = await pair.callB("agents.start", place());
  assert.deepEqual(started.answer, { result: { $undefined: true } });
  const url = "http://127.0.0.1:4750/mcp";
  const both2 = (call: string, args: Json[] = []) => [["actor", "cl:C1:1000.000001", call, args], ["actor", "w2:C1:1100.000001", call, args]];
  assert.deepEqual(started.did, [["agents.openDoor"], ...both2("toolsAt", [url]), ...both2("release"), ...both2("kick"), ["agents.along", "taken"], ...both2("kick"), ["agents.jobsRelaunch", null]]);
  // Out of a workspace it joined: its sessions end; back in it: they resume, and the parts are told each time.
  const left = await pair.callB("agents.follow", place({ joined: [] }));
  assert.deepEqual(left.did, [["actor", "w2:C1:1100.000001", "suspend", ["the station left its workspace"]], ["agents.along", "changed"]]);
  const back = await pair.callB("agents.follow", place());
  assert.deepEqual(back.did, [["actor", "w2:C1:1100.000001", "kick", []], ["agents.along", "changed"]]);
  // Out of every workspace: turns held, every process ended, the jobs stopped; in again: recovered, let go.
  const out = await pair.callB("agents.follow", place({ bound: false, removed: true }));
  assert.deepEqual(out.did, [["actor", "cl:C1:1000.000001", "suspend", []], ["actor", "w2:C1:1100.000001", "suspend", []], ["drivers", "shutdown", [true]], ["agents.along", "left"], ["agents.jobsStopAll", "the station was removed from its workspace"]]);
  assert.deepEqual((await pair.callB("held", "cl:C1:1000.000001")).answer, { result: true });
  const inAgain = await pair.callB("agents.follow", place());
  assert.deepEqual(inAgain.did, [["agents.along", "joined"], ...both2("kick"), ["agents.jobsRelaunch", null], ...both2("release"), ...both2("kick")]);
  assert.deepEqual((await pair.callB("held", "cl:C1:1000.000001")).answer, { result: false });
  // A new home: one it had joined took over (the old home's chats said to be that one's).
  assert.deepEqual((await pair.callB("agents.follow", place({ home: "ws2", joined: [], first: "ws2" }))).did, [["live", "cl:C1:1000.000001", false]]);
  assert.equal(pair.tsB.getSession("cl:C1:1000.000001")?.ws, "ws");
  // Due to only run tasks: what it runs as a station ended, then it is one.
  const rig = await pair.callB("agents.follow", place({ rigDue: true, rigPending: { owner: "o" } }));
  assert.deepEqual(rig.did, [["actor", "cl:C1:1000.000001", "suspend", []], ["actor", "w2:C1:1100.000001", "suspend", []], ["drivers", "shutdown", [true]], ["agents.along", "left"], ["agents.jobsStopAll", "this station only runs tasks now"], ["agents.becomeRig", { owner: "o" }]]);
  const dropped = await pair.callB("agents.follow", place({ rigDue: true }));
  assert.deepEqual(dropped.did, []);
  pair.a.log.length = 0;
});

test("the usage checker asked, the moved chats counted again, the old statistics retired, as minute-reader.ts and module.ts do", { skip }, async () => {
  const p = await opened();
  const pair = new HubPair(p);
  after(() => pair.close());
  await pair.open();
  await pair.advance(1_800_000_000_000);
  // The checker (minute-reader.ts `MinuteReader`): started by an ask, each ask posted once, answered by its id; let go
  // a minute after nothing is asked; complete, every ask answered and the checker let go, later asks answered at once.
  const remote = pair.askB("usageCheck", "remote");
  await pair.untilB((l) => l.length >= 2, "the first ask posted");
  assert.deepEqual(pair.b.log.splice(0), [["usageCheck.start", null], ["usageCheck.post", { id: 1, remote: true }]]);
  await pair.askB("usageCheck", "heard", { id: 1 });
  assert.deepEqual(await remote, { result: { $undefined: true } });
  await pair.advance(59_999, false);
  assert.deepEqual(pair.b.log.splice(0), []);
  await pair.advance(1, false);
  assert.deepEqual(pair.b.log.splice(0), [["usageCheck.terminate", null]]);
  const chats = pair.askB("usageCheck", "chats", { ws: "ws", viewer: "a@x.com" });
  const refused = pair.askB("usageCheck", "remote");
  await pair.untilB((l) => l.length >= 3, "both asks posted");
  assert.deepEqual(pair.b.log.splice(0), [["usageCheck.start", null], ["usageCheck.post", { id: 2, chats: { ws: "ws", viewer: "a@x.com" } }], ["usageCheck.post", { id: 3, remote: true }]]);
  assert.deepEqual(await pair.askB("usageCheck", "trim"), { result: 0 });
  await pair.askB("usageCheck", "heard", { id: 3, error: "no such table" });
  assert.deepEqual(await refused, { error: "no such table" });
  await pair.askB("usageCheck", "heard", { complete: true });
  assert.deepEqual(await chats, { result: { $undefined: true } });
  assert.deepEqual(pair.b.log.splice(0), [["usageCheck.terminate", null]]);
  assert.deepEqual((await pair.callB("usageCheck", "remote")).did, []);
  // A checker that ended under its asks: they are refused with how it ended.
  const lost = pair.askB("usageCheck", "chats", null);
  await pair.untilB((l) => l.some((d) => d[0] === "usageCheck.post" && d[1].id === 4), "the ask posted");
  await pair.askB("usageCheck", "exited", 9);
  assert.deepEqual(await lost, { error: "the minute summary worker stopped (exit 9)" });
  await pair.askB("usageCheck", "close");
  assert.deepEqual((await pair.callB("usageCheck", "remote")).answer, { error: "station stopping" });
  pair.b.log.length = 0;
  // The moved chats (module.ts `drainUsageChats`): a batch at a time till done, pages told once something moved.
  pair.scripted["usage.drainStep"] = [{ done: false, processed: 32 }, { done: false, processed: 32 }, { done: true, processed: 3 }];
  const drained = await pair.callB("usageDrain");
  assert.deepEqual(drained.did, [["usage.drainStep", 32], ["usage.drainStep", 32], ["usage.drainStep", 32]]);
  // The old statistics (module.ts `retireUntilComplete`): writers stopped (50 ms apart while another writes), freed,
  // the old calls taken in (pausing nine times what each took, 200 ms at least), tried again from the start, the pause
  // doubling, where it failed.
  pair.scripted["usage.stopIndexes"] = [false, true, true];
  pair.scripted["usage.inMemory"] = [false, false];
  pair.scripted["usage.retireStep"] = [{ done: false }, new Error("busy"), { done: true }, { done: false, ms: 50 }, { done: true }];
  const retiring = pair.askB("retireUsage");
  for (const ms of [50, 250, 450]) {
    await pair.askB("untilTimer");
    await pair.advance(ms, false);
  }
  assert.deepEqual(await retiring, { result: { $undefined: true } });
  assert.deepEqual(pair.b.log.splice(0).map((d) => [d[0], d[1]]), [
    ["usage.stopIndexes", null], ["usage.stopIndexes", null], ["usage.inMemory", null], ["usage.retireStep", { drop: true }], ["usage.retireStep", { drop: true }],
    ["usage.stopIndexes", null], ["usage.inMemory", null], ["usage.retireStep", { drop: true }], ["usage.retireStep", {}], ["usage.retireStep", {}],
  ]);
  pair.a.log.length = 0;
});

test("whether moving to another station is on, as hub.ts gives its sessions it", { skip }, async () => {
  const p = await opened();
  // Not said (an older config, a test's): on. Then as features.ts says it, off and on.
  for (const moveOn of [undefined, false, true]) {
    const pair = new HubPair(p);
    after(() => pair.close());
    pair.moveOn = moveOn;
    pair.hub = pair.newHub();
    await pair.open();
    assert.equal(await pair.call("moveOn"), moveOn ?? true);
    await pair.set(() => (pair.moveOn = !(moveOn ?? true)));
    (pair.hub as Json).options.moveOn = () => pair.moveOn!;
    assert.equal(await pair.call("moveOn"), !(moveOn ?? true));
  }
});
