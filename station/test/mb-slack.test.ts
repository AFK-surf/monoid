// Slack's parts in MoonBit (station/mb src/slack: reader `--builder harness-slack`) held to the TypeScript they are
// written from (src/slack/*.ts, with connects/card-ends.ts' `endedWords`): each case run by both, its answer (or what it
// threw) the same. The functions of no connection on the same inputs: Block Kit's cards, the `/sf` form, the manifest
// and its permissions, the overview, mrkdwn's tables, a Socket Mode event as a chat's. The rest against a stand-in for
// Slack of each side's own (its Web API over HTTP and Socket Mode over a WebSocket on 127.0.0.1), the same answers
// given both: what each asked of it (each call's method, token, form or multipart body, as sent) and what each
// acknowledged on the socket compared, and what each handed the station: 429s waited out, the app API's errors, files
// up and down, token rotation, the surface's posting, cards pressed, the `/sf` form, status lines, and the connects'
// apps brought up to date.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { type IncomingMessage, type ServerResponse, createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { endedWords } from "../src/connects/card-ends.ts";
import { NameBook } from "../src/connects/names.ts";
import { maskValue } from "../src/ops/agent-env.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import {
  SLACK_GROUPS, SlackApps, SlackWords, appIdOf, applySettings, botScopes, createAppUrl, exchangeInstallCode, ownerOfConfigToken,
  rotateConfigToken, settingsOf, shapeOf, slackAppLinks, slackError, slackManifest, upgraded, upsertToken, withCommand, withSocketMode, withStopEvent,
} from "../src/slack/apps.ts";
import { answerOf, answeredBlocks, endedBlocks, loginBlocks, loginCodeOf, loginEnteredBlocks, markdown, questionBlocks, standsBlock, standsText } from "../src/slack/cards.ts";
import { configTokens, connectName, madeApps, makeConnections, slackConnects, slackOverview, slackShown } from "../src/slack/index.ts";
import { modelLabel, modelOf, modelOptions, modelValue, newChatBlocks, newChatView, submittedChat } from "../src/slack/new-chat.ts";
import { SlackSurface, answerFiles, filesToLookUp, identityOf, messageFiles, messageText, personOf, toEvent, verifySlackTokens } from "../src/slack/surface.ts";
import { SlackApiError, SlackClient, apiBase, field } from "../src/slack/web.ts";
import { connectBlocked, zipOne } from "../src/slack/zip.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;

type Json = any;
const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `mb-slack-${what}-`));
  dirs.push(dir);
  return dir;
};
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

/// Something told on an emitter: `until` waits for what is to be, or fails saying what it waited for.
const told = new EventEmitter();
told.setMaxListeners(0);
/// What a failure says of where things stood (the stand-ins' logs, as a case sets it).
let standing: () => string = () => "";
async function until(what: string, ok: () => boolean, ms = 15_000): Promise<void> {
  if (ok()) return;
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      told.off("change", check);
      reject(new Error(`never came: ${what} ${standing()}`));
    }, ms);
    const check = () => {
      if (!ok()) return;
      clearTimeout(timer);
      told.off("change", check);
      resolve();
    };
    told.on("change", check);
  });
}

// ── the program ──

type Asked = (name: string, of: string, args: Json[]) => Promise<Json> | Json;
let program: { child: ChildProcessWithoutNullStreams; send: (c: Json) => Promise<Json> } | null = null;
/// What the program asks of the test (a surface's handler, onWorking, a token saved) and what it tells (a name learned).
let asked: Asked = () => null;
const tells: { name: string; of: string }[] = [];

function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-slack", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
  let seq = 0;
  const waiting = new Map<number, (answer: Json) => void>();
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  createInterface({ input: child.stdout }).on("line", (line) => {
    const m = JSON.parse(line);
    if (typeof m.ask === "number") {
      void (async () => {
        try {
          const result = await asked(m.name, m.of, m.args);
          child.stdin.write(`${JSON.stringify({ answer: m.ask, result: result ?? null })}\n`);
        } catch (e) {
          child.stdin.write(`${JSON.stringify({ answer: m.ask, threw: (e as Error).message })}\n`);
        }
      })();
      return;
    }
    if (typeof m.tell === "string") {
      tells.push({ name: m.tell, of: m.of });
      told.emit("change");
      return;
    }
    waiting.get(m.re)?.(m);
    waiting.delete(m.re);
  });
  child.on("exit", (code) => {
    for (const w of waiting.values()) w({ error: `the program ended (${code}): ${stderr}`, kind: "exit" });
  });
  program = {
    child,
    send: (c) =>
      new Promise((resolve) => {
        seq += 1;
        waiting.set(seq, resolve);
        child.stdin.write(`${JSON.stringify({ ...c, seq })}\n`);
      }),
  };
  return program;
}
/// What a test started, ended however it ends.
const closers: (() => Promise<void>)[] = [];
after(async () => {
  for (const c of closers.splice(0)) await c().catch(() => {});
  program?.child.stdin.end();
  for (const s of servers) s.close();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// An outcome as both say it: `{ok}`, or the error's words, its kind and (Slack's app API's) code and details.
function outcomeOf(m: Json): Json {
  if (m.kind === "exit") throw new Error(m.error);
  if (!("error" in m)) return { ok: m.ok };
  const out: Json = { error: m.kind === "SyntaxError" ? "(JSON)" : m.error, kind: m.kind };
  for (const k of ["method", "code", "details", "key"]) if (k in m) out[k] = m[k];
  return out;
}
async function ts(f: () => unknown): Promise<Json> {
  try {
    return { ok: plain(await f()) };
  } catch (e) {
    const out: Json = { error: (e as Error).message, kind: "" };
    if (e instanceof SlackApiError) Object.assign(out, { kind: "SlackApiError", method: e.method, code: e.code, details: e.details });
    else if (e instanceof SlackWords) Object.assign(out, { kind: "SlackWords", key: e.key });
    else if (e instanceof SyntaxError) Object.assign(out, { kind: "SyntaxError", error: "(JSON)" });
    return out;
  }
}
const mbFn = async (name: string, ...args: Json[]) => outcomeOf(await harness().send({ op: "fn", name, args }));
const mbNew = async (spec: Json) => {
  await harness().send({ op: "wall", now: Date.now() });
  const m = await harness().send({ op: "new", ...spec });
  if ("error" in m) throw new Error(`MoonBit: ${m.error}`);
};
const mbCall = async (id: string, name: string, ...args: Json[]) => outcomeOf(await harness().send({ op: "call", id, name, args }));

let worded = false;
async function words(lang: "zh" | "en" = "zh") {
  if (!worded) {
    await harness().send({ op: "wall", now: Date.now() });
    await harness().send({ op: "words", zh: zhStation, en: enStation });
    worded = true;
  }
  setStationLang(lang);
  await harness().send({ op: "lang", lang });
}

// ── a stand-in for Slack, one each side ──

type Req = { m: string; auth: string | null; type: string; raw?: string; p?: [string, string][]; parts?: Json[]; bytes?: string };
type Answer = { status?: number; headers?: Record<string, string>; body?: Json; raw?: Buffer | string };
type Respond = (req: Req, slack: Stand) => Answer;
const servers: { close: () => void }[] = [];

class Stand {
  readonly log: Req[] = [];
  readonly acks: Json[] = [];
  readonly sockets: WebSocket[] = [];
  base = "";
  origin = "";
  respond: Respond = () => ({ body: { ok: true } });
  static async make(): Promise<Stand> {
    const s = new Stand();
    const server = createServer((req, res) => void s.serve(req, res));
    const wss = new WebSocketServer({ server, path: "/socket" });
    wss.on("connection", (socket) => {
      s.sockets.push(socket);
      socket.on("message", (data) => {
        s.acks.push(JSON.parse(data.toString()));
        told.emit("change");
      });
      told.emit("change");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const port = (server.address() as AddressInfo).port;
    s.origin = `http://127.0.0.1:${port}`;
    s.base = `${s.origin}/api`;
    servers.push({ close: () => { for (const c of wss.clients) c.terminate(); wss.close(); server.closeAllConnections(); server.close(); } });
    return s;
  }
  /// The newest socket opened to it.
  get socket(): WebSocket {
    return this.sockets[this.sockets.length - 1]!;
  }
  send(envelope: Json) {
    this.socket.send(JSON.stringify(envelope));
  }
  private async serve(req: IncomingMessage, res: ServerResponse) {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const body = Buffer.concat(chunks);
    const path = (req.url ?? "").split("?")[0]!;
    const type = String(req.headers["content-type"] ?? "");
    const entry: Req = { m: path.startsWith("/api/") ? path.slice(5) : path, auth: (req.headers.authorization as string | undefined) ?? null, type: type.split(";")[0]! };
    if (type.startsWith("application/x-www-form-urlencoded")) {
      entry.raw = body.toString();
      entry.p = [...new URLSearchParams(entry.raw)];
    } else if (type.startsWith("multipart/form-data")) entry.parts = multipartOf(body, type.split("boundary=")[1]!);
    else if (body.length > 0) entry.bytes = body.toString("base64");
    this.log.push(entry);
    const a = this.respond(entry, this);
    const headers = { "content-type": "application/json", ...(a.headers ?? {}) };
    res.writeHead(a.status ?? 200, headers);
    res.end(a.raw ?? JSON.stringify(a.body ?? { ok: true }));
    told.emit("change");
  }
}

/// A multipart body's parts as a server reads them: each one's name, its file's name and type, its value.
function multipartOf(body: Buffer, boundary: string): Json[] {
  const text = body.toString("latin1");
  return text
    .split(`--${boundary}`)
    .slice(1, -1)
    .map((part) => {
      const at = part.indexOf("\r\n\r\n");
      const head = part.slice(2, at);
      const value = part.slice(at + 4, part.length - 2);
      const name = /name="([^"]*)"/.exec(head)?.[1] ?? null;
      const filename = /filename="([^"]*)"/.exec(head)?.[1] ?? null;
      const ctype = /Content-Type: (.*)/i.exec(head)?.[1]?.trim() ?? null;
      return { name, filename, type: ctype, value: filename === null ? Buffer.from(value, "latin1").toString("utf8") : Buffer.from(value, "latin1").toString("base64") };
    });
}

/// Two stand-ins answering alike (`respond` made for each), the TypeScript's and the program's.
async function pair(respond: () => Respond): Promise<[Stand, Stand]> {
  const [a, b] = [await Stand.make(), await Stand.make()];
  a.respond = respond();
  b.respond = respond();
  return [a, b];
}
const strip = (log: Req[]) => log.map((r) => ({ ...r }));
let made = 0;
const idOf = (what: string) => `${what}${++made}`;

/// A client of each side on its stand-in.
async function clients(respond: () => Respond, timeoutMs?: number): Promise<{ a: Stand; b: Stand; t: SlackClient; id: string }> {
  const [a, b] = await pair(respond);
  const id = idOf("client");
  await mbNew({ kind: "client", id, base: `${b.base}/`, timeoutMs });
  return { a, b, t: new SlackClient(`${a.base}/`, timeoutMs), id };
}

// ── what has no connection ──

const OPTIONS = {
  type: "options",
  options: [
    { label: "按今天累计", detail: "从零点算" },
    { label: "先不改", recommended: true },
    { label: "x".repeat(80), detail: "long label" },
  ],
};
const PAYLOAD = (values: Json, actions: Json[] = [{ action_id: "sf_answer", value: JSON.stringify({ l: ["甲", "乙"] }) }]) => ({ actions, state: { values } });
const MODELS = [{ runtime: "claude", model: "opus" }, { runtime: "codex", model: null }, { runtime: "who", model: "m1" }];
const MANIFEST = {
  display_information: { name: "bot", description: "  my bot  " },
  features: { bot_user: { display_name: "Bot" }, slash_commands: [{ command: "/other" }, { command: "/sf" }] },
  oauth_config: { scopes: { bot: ["chat:write", "files:read", "custom:scope", 3] } },
  settings: { socket_mode_enabled: true, event_subscriptions: { bot_events: ["app_mention", "custom_event", "file_shared"] } },
};
const TOKENS = [
  { accessToken: "xoxe-1", refreshToken: "r1", expiresAt: 1, teamId: "T1", by: "a@x", owner: { team: "Acme", teamDomain: null, teamIcon: null, user: "A", email: null, image: null } },
  { accessToken: "xoxe-2", refreshToken: "r2", expiresAt: 2, teamId: "T2", by: "a@x" },
  { accessToken: "xoxe-3", refreshToken: "", expiresAt: 2, teamId: "T3", by: "b@x" },
  null,
];
const RAW = {
  connects: [
    { id: "c1", slack: { appToken: "xapp-1-abcdefghijk", botToken: "xoxb-12345", appId: "A1", team: { id: "T1", name: "Acme" }, botName: "Bot", botImage: "https://i" }, createdBy: { id: "a@x" } },
    { id: "c2", kind: "slack", enabled: false, slack: { team: { id: "" } }, workspace: "w2" },
    { id: "c3", kind: "feishu" },
    { id: 4, kind: null, slack: null },
  ],
  slackConfigTokens: TOKENS,
  slackApps: [
    { appId: "A9", name: "made", teamId: "T1", by: "a@x", created: 5, oauth: { state: "s", clientId: "c", clientSecret: "x", redirectUri: "r", install: "https://install", botToken: "xoxb-9", installedTeam: "Acme" } },
    { appId: "A8", teamId: "T9", by: "a@x" },
    { appId: "", by: "a@x" },
  ],
};
const TABLE = {
  text: "hello <@U1>",
  blocks: [
    { type: "table", rows: [[{ type: "raw_text", text: "a|b" }, { type: "rich_text", elements: [{ type: "rich_text_section", elements: [{ type: "link", url: "https://x", text: "l|x" }, { type: "user", user_id: "U2" }] }] }], [{ type: "raw_number", number: 3 }]] },
    { type: "section" },
  ],
  attachments: [{ blocks: [{ type: "table", rows: [[{ type: "rich_text", elements: [{ type: "rich_text_list", elements: [{ type: "rich_text_section", elements: [{ type: "text", text: "one\n  two" }, { type: "emoji", name: "x" }] }] }] }]] }] }],
  files: [{ id: "F1", name: "a.png", size: 3, url_private_download: "https://files/a" }, { id: "F2", title: "t", mode: "tombstone", url_private: "https://u" }, { id: "" }, { id: "F3" }],
};

test("Block Kit's cards, the /sf form and the stands line, as the TypeScript makes them", { skip }, async () => {
  for (const lang of ["zh", "en"] as const) {
    await words(lang);
    const cases: [string, Json[], () => unknown][] = [
      ["markdown", ["**x**"], () => markdown("**x**")],
      ["questionBlocks", ["Which?", OPTIONS], () => questionBlocks("Which?", OPTIONS, lang)],
      ["questionBlocks", ["  ", { type: "options", options: [{ label: "a" }, { label: 5, detail: 7 }] }], () => questionBlocks("  ", { type: "options", options: [{ label: "a" }, { label: 5, detail: 7 }] }, lang)],
      ["questionBlocks", ["w", { type: "options", options: Array.from({ length: 6 }, (_, i) => ({ label: "长".repeat(60) + i })) }], () => questionBlocks("w", { type: "options", options: Array.from({ length: 6 }, (_, i) => ({ label: "长".repeat(60) + i })) }, lang)],
      ["questionBlocks", ["Name?", { type: "text", placeholder: " sk_test <x> & " }], () => questionBlocks("Name?", { type: "text", placeholder: " sk_test <x> & " }, lang)],
      ["questionBlocks", ["x".repeat(13_000), { type: "text" }], () => questionBlocks("x".repeat(13_000), { type: "text" }, lang)],
      ["questionBlocks", ["n", { type: "login" }], () => questionBlocks("n", { type: "login" }, lang)],
      ["loginBlocks", ["Sign in", null], () => loginBlocks("Sign in", lang, null)],
      ["loginBlocks", ["Sign in", { url: "https://a.b/c", domain: "a.b", paste: true }], () => loginBlocks("Sign in", lang, { url: "https://a.b/c", domain: "a.b", paste: true })],
      ["loginBlocks", ["", { url: "https://a.b/c", domain: "a.b", code: "AB<1>", paste: false }], () => loginBlocks("", lang, { url: "https://a.b/c", domain: "a.b", code: "AB<1>", paste: false })],
      ["loginBlocks", ["x", { url: "https://a.b/c", domain: "a.b", paste: false }, false], () => loginBlocks("x", lang, { url: "https://a.b/c", domain: "a.b", paste: false }, false)],
      ["loginBlocks", ["x", { url: `https://a.b/${"u".repeat(3000)}`, domain: "a.b", paste: true }], () => loginBlocks("x", lang, { url: `https://a.b/${"u".repeat(3000)}`, domain: "a.b", paste: true })],
      ["loginEnteredBlocks", [{ markdown: "said" }, "Ann <a>"], () => loginEnteredBlocks({ markdown: "said" }, "Ann <a>", lang)],
      ["loginEnteredBlocks", [{ blocks: [{ type: "markdown", text: "m" }, { type: "actions" }, { type: "input" }, { x: 1 }] }, "B"], () => loginEnteredBlocks({ blocks: [{ type: "markdown", text: "m" }, { type: "actions" }, { type: "input" }, { x: 1 }] }, "B", lang)],
      ["answeredBlocks", [{ markdown: "  " }, "Ann", "a & b"], () => answeredBlocks({ markdown: "  " }, "Ann", "a & b", lang)],
      ["endedBlocks", ["t", "closed <now>"], () => endedBlocks("t", "closed <now>")],
      ["standsBlock", [{ kind: "done", words: " all good " }], () => standsBlock({ kind: "done", words: " all good " }, lang)],
      ["standsText", [{ kind: "need", words: "x".repeat(600) }], () => standsText({ kind: "need", words: "x".repeat(600) }, lang)],
      ["standsText", [{ kind: "need", words: null }], () => standsText({ kind: "need", words: null }, lang)],
      ["standsText", [{ kind: "done", words: "" }], () => standsText({ kind: "done", words: "" }, lang)],
      ["standsText", [{ kind: "left", words: "x" }], () => standsText({ kind: "left", words: "x" }, lang)],
      ["modelLabel", [MODELS[0]], () => modelLabel(MODELS[0]!, lang)],
      ["modelLabel", [MODELS[1]], () => modelLabel(MODELS[1]!, lang)],
      ["modelLabel", [MODELS[2]], () => modelLabel(MODELS[2]!, lang)],
      ["modelValue", [MODELS[1]], () => modelValue(MODELS[1]!)],
      ["modelOptions", [MODELS, ""], () => modelOptions(MODELS, "", lang)],
      ["modelOptions", [MODELS, "  CLAUDE   op "], () => modelOptions(MODELS, "  CLAUDE   op ", lang)],
      ["modelOptions", [MODELS, "m1 who"], () => modelOptions(MODELS, "m1 who", lang)],
      ["newChatView", [MODELS, "C1", "  hello  "], () => newChatView(MODELS, "C1", "  hello  ", lang)],
      ["newChatView", [[], "C1", ""], () => newChatView([], "C1", "", lang)],
      ["newChatBlocks", ["U1", MODELS[0], "do it"], () => newChatBlocks("U1", MODELS[0]!, "do it", lang)],
      ["endedWords", [{ type: "text" }, { why: "message", by: "U1", byTs: "1" }, "Ann"], () => endedWords({ type: "text" }, { why: "message", by: "U1", byTs: "1" }, "Ann", lang)],
      ["endedWords", [{ type: "options" }, { why: "message", by: "U1", byTs: "1" }, null], () => endedWords({ type: "options" }, { why: "message", by: "U1", byTs: "1" }, null, lang)],
      ["endedWords", [{}, { why: "replaced" }, null], () => endedWords({}, { why: "replaced" }, null, lang)],
      ["endedWords", [{}, { why: "withdrawn" }, null], () => endedWords({}, { why: "withdrawn" }, null, lang)],
      ["endedWords", [{}, { why: "closed" }, null], () => endedWords({}, { why: "closed" }, null, lang)],
    ];
    for (const [name, args, f] of cases) assert.deepEqual(await mbFn(name, ...args), await ts(f), `${lang} ${name} ${JSON.stringify(args).slice(0, 120)}`);
  }
  const payloads: Json[] = [
    null,
    { actions: "x" },
    PAYLOAD({ b1: { sf_pick: { selected_option: { value: "1", text: { text: "shown" } } } } }),
    PAYLOAD({ b1: { sf_pick: { selected_option: { value: "7", text: { text: "shown" } } } } }),
    PAYLOAD({ b1: { sf_pick: { selected_option: null } }, b2: { sf_pick: { selected_option: { value: " 0 " } } } }),
    PAYLOAD({ b1: { sf_pick: { selected_option: { value: "0", text: { text: "start…" } } } } }, [{ action_id: "sf_answer", value: "not json" }]),
    PAYLOAD({ b1: { sf_pick: { selected_option: { value: "0" } } } }, [{ action_id: "sf_answer", value: "null" }]),
    PAYLOAD({ "2": { sf_text: { value: "  typed  " } }, "1": { other: 1 } }),
    PAYLOAD({ b: { sf_text: { value: 5 } } }),
    PAYLOAD({}, [{ action_id: "sf_pick" }]),
    PAYLOAD({ code: { sf_code: { value: "  123  " } } }, [{ action_id: "sf_login" }]),
    PAYLOAD({ code: { sf_code: {} } }, [{ action_id: "sf_login" }]),
    { actions: [{ action_id: "sf_login" }], state: { values: "abc" } },
  ];
  for (const p of payloads) {
    assert.deepEqual(await mbFn("answerOf", p), await ts(() => answerOf(p)), `answerOf ${JSON.stringify(p)}`);
    assert.deepEqual(await mbFn("loginCodeOf", p), await ts(() => loginCodeOf(p)), `loginCodeOf ${JSON.stringify(p)}`);
  }
  const values: Json[] = ['["claude","opus"]', '["claude",null]', '["",null]', '["a",3]', "[1]", "nope", 7, null, ["codex", null]];
  for (const v of values) assert.deepEqual(await mbFn("modelOf", v), await ts(() => modelOf(v)), `modelOf ${JSON.stringify(v)}`);
  const view = (meta: Json, values: Json, user: Json = { id: "U1" }) => ({ user, view: { callback_id: "stillfail-new-chat", private_metadata: meta, state: { values } } });
  const submissions: Json[] = [
    view(JSON.stringify({ channel: "C1" }), { model: { model: { selected_option: { value: '["claude","opus"]' } } }, words: { words: { value: "  hi  " } } }),
    view(JSON.stringify({ channel: "C1" }), {}),
    view("not json", {}),
    view(JSON.stringify({ channel: 5 }), {}, {}),
    view(JSON.stringify(null), {}),
    { view: { callback_id: "other" } },
    null,
  ];
  for (const s of submissions) assert.deepEqual(await mbFn("submittedChat", s), await ts(() => submittedChat(s)), `submittedChat ${JSON.stringify(s)}`);
});

test("the manifest, its permissions, the app API's words and the overview, as the TypeScript has them", { skip }, async () => {
  await words("zh");
  const manifests: Json[] = [MANIFEST, {}, null, { settings: { socket_mode_enabled: true }, features: { agent_view: {} }, oauth_config: { scopes: { bot: ["commands"] } } }, { settings: { socket_mode_enabled: true, event_subscriptions: { bot_events: ["agent_session_stopped"] } }, features: { assistant_view: {} } }, { features: 3, settings: "x" }];
  const edits: Json[] = [{}, { name: " New ", displayName: " Shown ", description: " ", longDescription: "long", backgroundColor: "#fff", groups: { files: false, dm: true, base: false } }, { name: "only" }, { groups: { files: null } }];
  for (const m of manifests) {
    for (const [name, f] of [["settingsOf", () => settingsOf(m)], ["withStopEvent", () => withStopEvent(m)], ["withSocketMode", () => withSocketMode(m, true)]] as const)
      assert.deepEqual(await mbFn(name, m, true), await ts(f), `${name} ${JSON.stringify(m)}`);
    assert.deepEqual(await mbFn("withSocketMode", m, false), await ts(() => withSocketMode(m, false)), `withSocketMode off ${JSON.stringify(m)}`);
    if (m !== null && typeof m === "object" && typeof m.features !== "number") {
      assert.deepEqual(await mbFn("withCommand", m), await ts(() => withCommand(m)), `withCommand ${JSON.stringify(m)}`);
      assert.deepEqual(await mbFn("upgraded", m), await ts(() => upgraded(m)), `upgraded ${JSON.stringify(m)}`);
    }
    for (const e of edits) assert.deepEqual(await mbFn("applySettings", m, e), await ts(() => applySettings(m, e)), `applySettings ${JSON.stringify([m, e])}`);
  }
  assert.deepEqual(await mbFn("SLACK_GROUPS"), await ts(() => SLACK_GROUPS));
  assert.deepEqual(await mbFn("botScopes"), await ts(() => botScopes()));
  for (const args of [["n"], ["n", " desc "], ["n", "", "https://r"], ["n", "x".repeat(400)]] as [string, string?, string?][])
    assert.deepEqual(await mbFn("slackManifest", ...args.map((a) => a ?? null)), await ts(() => slackManifest(args[0], args[1] ?? null, args[2] ?? null)), `slackManifest ${args}`);
  assert.deepEqual(await mbFn("createAppUrl", "still fail & co"), await ts(() => createAppUrl("still fail & co")));
  const errors: [Json, () => unknown][] = [
    [{ api: ["apps.manifest.update", "invalid_manifest", [{ pointer: "/a", message: "bad" }, { message: "worse" }, 5]] }, () => slackError(new SlackApiError("apps.manifest.update", "invalid_manifest", [{ pointer: "/a", message: "bad" }, { message: "worse" }, 5]))],
    [{ api: ["m", "token_expired", null] }, () => slackError(new SlackApiError("m", "token_expired", null))],
    [{ api: ["m", "odd_code", "x"] }, () => slackError(new SlackApiError("m", "odd_code", "x"))],
    [{ api: ["m", "", [{ pointer: "/p" }]] }, () => slackError(new SlackApiError("m", "", [{ pointer: "/p" }]))],
    [{ words: "station.slackApi.noConfigToken" }, () => slackError(new SlackWords("station.slackApi.noConfigToken"))],
    [{ message: "plain" }, () => slackError(new Error("plain"))],
  ];
  for (const lang of ["zh", "en"] as const) {
    await words(lang);
    for (const [e, f] of errors) assert.deepEqual(await mbFn("slackError", e), await ts(f), `slackError ${lang} ${JSON.stringify(e)}`);
  }
  await words("zh");
  assert.deepEqual(await mbFn("slackAppLinks", "A1", "T1"), await ts(() => slackAppLinks("A1", "T1")));
  assert.deepEqual(await mbFn("slackAppLinks", "A1", null), await ts(() => slackAppLinks("A1", null)));
  const kept = TOKENS.filter((t) => t !== null) as Json[];
  for (const t of [{ ...kept[0], accessToken: "new", owner: undefined }, { accessToken: "n", refreshToken: "r", expiresAt: 9, teamId: "T7", by: "a@x" }, { ...kept[1], owner: { team: "B" } }])
    assert.deepEqual(await mbFn("upsertToken", kept, plain(t)), await ts(() => upsertToken(kept, plain(t))), `upsertToken ${JSON.stringify(t)}`);
  for (const v of [{ a: "xoxb-123", b: ["xapp-1", "text", 3, true, null], c: { d: "xAbc-1" } }, "xoxe-xyz", null, 1])
    assert.deepEqual(await mbFn("shapeOf", v), await ts(() => shapeOf(v)), `shapeOf ${JSON.stringify(v)}`);
  for (const r of [RAW, {}, null, { connects: "x", slackConfigTokens: {}, slackApps: [1] }]) {
    assert.deepEqual(await mbFn("slackConnects", r), await ts(() => slackConnects(r)), `slackConnects ${JSON.stringify(r)}`);
    assert.deepEqual(await mbFn("configTokens", r), await ts(() => configTokens(r)));
    assert.deepEqual(await mbFn("madeApps", r), await ts(() => madeApps(r)));
    for (const by of ["a@x", "b@x", "z"]) assert.deepEqual(await mbFn("slackOverview", r, by), await ts(() => slackOverview(r, by)), `slackOverview ${by}`);
  }
  for (const c of RAW.connects) {
    assert.deepEqual(await mbFn("slackShown", c), await ts(() => slackShown(c)), `slackShown ${JSON.stringify(c)}`);
    if (c.kind !== "feishu") assert.deepEqual(await mbFn("connectName", c), await ts(() => connectName(slackConnects({ connects: [c] })[0]!)));
  }
  for (const v of ["", "short", "12345678", "123456789", "xoxb-1234-5678-abcdef", "长长长长长长长长长长"]) assert.deepEqual(await mbFn("maskValue", v), await ts(() => maskValue(v)), `mask ${v}`);
});

test("Slack's messages, files and Socket Mode's events as the station takes them", { skip }, async () => {
  const events: Json[] = [
    { type: "message", channel: "C1", user: "U1", text: "hi <@UB>", ts: "1.1", channel_type: "channel", files: TABLE.files },
    { type: "app_mention", channel: "C1", user: "U1", text: "x", ts: "1.2", thread_ts: "1.0" },
    { type: "message", channel: "D1", bot_id: "B2", subtype: "bot_message", text: "from a bot", ts: "1.3", channel_type: "im" },
    { type: "message", channel: "C1", user: "UB", text: "mine", ts: "1.4" },
    { type: "message", channel: "C1", bot_id: "BB", text: "mine too", ts: "1.4" },
    { type: "message", subtype: "channel_join", user: "U1", ts: "1" },
    { type: "message", subtype: "message_deleted", ts: "1" },
    { type: "message", subtype: "message_changed", channel: "C1", message: { ...TABLE, ts: "2.0", thread_ts: "1.0", user: "U1" } },
    { type: "message", subtype: "message_changed", channel: "C1", message: { text: "x", ts: "2.0", user: "UB" } },
    { type: "message", subtype: "message_changed", channel: "C1", message: null },
    { type: "agent_session_stopped", channel: "C1", thread_ts: "1.0", event_ts: "1700000000.000100" },
    { type: "agent_session_stopped", channel: "C1", thread_ts: "1.0", event_ts: "1e5" },
    { type: "agent_session_stopped", channel: "", thread_ts: "1.0", event_ts: "1" },
    { type: "agent_session_stopped", channel: "C1", thread_ts: "1.0", event_ts: "9".repeat(400) },
    { type: "message", channel: "C1", text: "nobody", ts: "1" },
    { type: "reaction_added" },
    null,
  ];
  for (const e of events) assert.deepEqual(await mbFn("toEvent", e, "UB", "BB"), await ts(() => toEvent(e, "UB", "BB")), `toEvent ${JSON.stringify(e)}`);
  assert.deepEqual(await mbFn("toEvent", events[3], "", ""), await ts(() => toEvent(events[3], "", "")));
  for (const m of [TABLE, { text: "x" }, null, { blocks: [{ type: "table", rows: [] }] }, { blocks: [{ type: "table", rows: [[], [{ type: "raw_text", text: "a\n \nb  | <x|y> <unclosed" }]] }] }]) {
    assert.deepEqual(await mbFn("messageText", m), await ts(() => messageText(m)), `messageText ${JSON.stringify(m)}`);
    assert.deepEqual(await mbFn("messageFiles", m), await ts(() => messageFiles(m)));
  }
  for (const m of [{ files: [{ id: "F1", file_access: "check_file_info" }, { id: "F2" }, { id: "F1", file_access: "check_file_info" }, { id: "", file_access: "check_file_info" }, { id: "F3", file_access: "visible" }] }, { files: "x" }, {}, null])
    assert.deepEqual(await mbFn("filesToLookUp", m), await ts(() => [...filesToLookUp(m)]), `filesToLookUp ${JSON.stringify(m)}`);
  for (const a of [{ messages: [TABLE, null], message: { files: [{ id: "F9", size: "big" }] }, file: { id: "F10", name: "n" } }, {}, null])
    assert.deepEqual(await mbFn("answerFiles", a), await ts(() => answerFiles(a)), `answerFiles ${JSON.stringify(a)}`);
  for (const a of [{ user: { name: "n", profile: { display_name: "", email: "A@B.C", image_72: "https://p" }, real_name: "Real" } }, { user: { name: "handle" } }, {}, null])
    assert.deepEqual(await mbFn("personOf", a), await ts(() => personOf(a)), `personOf ${JSON.stringify(a)}`);
  for (const v of ["s", 3, [1, { a: 2 }], { b: null }, true, null]) assert.deepEqual(await mbFn("field", v), await ts(() => field(v)), `field ${JSON.stringify(v)}`);
  const params: [string, string][] = [["text", "a b&c=d+é 中 ~*'()!"], ["blocks", JSON.stringify([{ t: "x\ny" }])], ["e", ""], ["s", "\ud800 lone"]];
  assert.deepEqual(await mbFn("formEncoded", params), await ts(() => new URLSearchParams(params).toString()));
  for (const d of ["Tue, 17 Nov 2026 04:22:23 GMT", "Sun, 06 Nov 1994 08:49:37 GMT", "17 Nov 2026 04:22:23 GMT", "nonsense"])
    assert.deepEqual(await mbFn("httpDate", d), await ts(() => (Number.isFinite(Date.parse(d)) ? Date.parse(d) : null)), `httpDate ${d}`);
  assert.deepEqual(await mbFn("apiBase", null), await ts(() => apiBase()));
});

// ── the Web API ──

const ok = (body: Json = {}, headers: Record<string, string> = {}): Answer => ({ body: { ok: true, ...body }, headers });

test("the Web API's calls: their form, 429s waited out, Slack's errors, the scopes and Slack's time", { skip }, async () => {
  const respond = (): Respond => {
    let limited = 0;
    return (r) => {
      switch (r.m) {
        case "auth.test":
          return ok({ user_id: "UB" }, { "x-oauth-scopes": "chat:write, channels:join,,files:read", date: "Tue, 17 Nov 2026 04:22:23 GMT" });
        case "limited":
          return ++limited <= 2 ? { status: 429, headers: { "retry-after": "0" }, body: { ok: false } } : ok({ after: limited });
        case "limitedOdd":
          return ++limited <= 1 ? { status: 429, headers: { "retry-after": "soon" }, body: { ok: false } } : ok({ after: limited });
        case "never":
          return { status: 429, headers: { "retry-after": "0" }, body: { ok: false, error: "ratelimited" } };
        case "errString":
          return { body: { ok: false, error: "channel_not_found" } };
        case "errObject":
          return { body: { ok: false, error: { why: [1] } } };
        case "errNone":
          return { status: 500, body: { ok: false } };
        case "errNull":
          return { status: 503, body: null };
        case "errDetails":
          return { body: { ok: false, error: "invalid_manifest", errors: [{ pointer: "/x", message: "no" }] } };
        case "notJson":
          return { raw: "<html>" };
        case "empty":
          return { raw: "" };
        default:
          return ok({ echo: r.p ?? null });
      }
    };
  };
  const { a, b, t, id } = await clients(respond);
  const both = async (name: string, f: () => unknown, ...args: Json[]) => {
    const [x, y] = [await ts(f), await mbCall(id, name, ...args)];
    assert.deepEqual(y, x, `${name} ${JSON.stringify(args)}`);
    return x;
  };
  const params: [string, string][] = [["channel", "C1"], ["text", "a b & 中"], ["blocks", "[]"]];
  const before = Date.now();
  await both("api", () => t.api("auth.test", [], "xoxb-1"), "auth.test", [], "xoxb-1");
  const afterAt = Date.now();
  // Slack's time: its Date header against the machine's as each heard it (auth.test's stand-in says a fixed one)
  const server = Date.parse("Tue, 17 Nov 2026 04:22:23 GMT");
  const heard = (upper: number) => upper - 1794889343500 + server;
  const upper = (await mbCall(id, "localTimeUpper", "1794889343.5")).ok as number;
  assert.ok(heard(upper) >= before - 1 && heard(upper) <= afterAt + 1, `Slack's time ${upper}`);
  const tsUpper = t.localTimeUpper("1794889343.5")!;
  assert.ok(heard(tsUpper) >= before - 1 && heard(tsUpper) <= afterAt + 1, `Slack's time (TypeScript) ${tsUpper}`);
  await both("api", () => t.api("chat.postMessage", params, "xoxb-1"), "chat.postMessage", params, "xoxb-1");
  for (const m of ["limited", "limitedOdd", "never", "errString", "errObject", "errNone", "errNull", "notJson", "empty"]) {
    a.respond = respond();
    b.respond = respond();
    await both("api", () => t.api(m, [], "xoxb-1"), m, [], "xoxb-1");
  }
  for (const m of ["errString", "errObject", "errNone", "errNull", "errDetails", "auth.test"]) {
    await both("app", () => t.app(m, null, [["x", "1"]]), m, null, [["x", "1"]]);
    await both("app", () => t.app(m, "xoxe-1", []), m, "xoxe-1", []);
  }
  await both("app", () => t.app("apps.icon.set", "xoxe-1", [["app_id", "A1"], ["n\"a\nme", "v\r\nw"]], { bytes: new Uint8Array([0, 1, 2, 255]), name: "icon.png", mime: "image/png" }), "apps.icon.set", "xoxe-1", [["app_id", "A1"], ["n\"a\nme", "v\r\nw"]], { bytes: Buffer.from([0, 1, 2, 255]).toString("base64"), name: "icon.png", mime: "image/png" });
  assert.deepEqual(strip(b.log), strip(a.log), "what each asked of Slack");
  for (const [token, scope] of [["xoxb-1", "channels:join"], ["xoxb-1", "files:read"], ["xoxb-1", "chat:write.public"], ["xoxb-2", "chat:write"]])
    await both("hasScope", () => t.hasScope(token!, scope!), token, scope);
  // and later answers' Date (the stand-in's own, its second) taken over it, on each side
  const later = (await mbCall(id, "localTimeUpper", "1794889343.5")).ok as number;
  const tsLater = t.localTimeUpper("1794889343.5")!;
  for (const u of [later, tsLater]) assert.ok(u >= 1794889343500 && u <= 1794889343500 + 1000 + (Date.now() - before), `Slack's later time ${u}`);
  const fresh = await clients(respond);
  assert.deepEqual(await mbCall(fresh.id, "localTimeUpper", "1.0"), { ok: fresh.t.localTimeUpper("1.0") });
});

test("a file down from Slack and up to where it says, only to Slack's own hosts", { skip }, async () => {
  const respond = (): Respond => (r) => {
    if (r.m === "/files/a.png") return { raw: Buffer.from([1, 2, 3]), headers: { "content-type": "image/png" } };
    if (r.m === "/files/page.txt" || r.m === "/files/page.html") return { raw: "<html>sign in</html>", headers: { "content-type": "text/html; charset=utf-8" } };
    if (r.m === "/files/gone") return { status: 404, raw: "" };
    if (r.m === "/upload/ok") return { raw: "OK" };
    if (r.m === "/upload/bad") return { status: 500, raw: "" };
    if (r.m === "/upload/odd") return { status: 418, raw: "" };
    return ok();
  };
  const { a, b, t, id } = await clients(respond);
  const both = async (name: string, f: () => unknown, ...args: Json[]) => assert.deepEqual(await mbCall(id, name, ...args), await ts(f), `${name} ${JSON.stringify(args)}`);
  for (const [path, name] of [["/files/a.png", "a.png"], ["/files/page.txt", "page.txt"], ["/files/page.html", "page.HTML"], ["/files/gone", "g"]]) {
    await both("download", async () => Buffer.from(await t.download(`${a.origin}${path}`, name, "xoxb-1")).toString("base64"), `${b.origin}${path}`, name, "xoxb-1");
  }
  for (const url of ["not a url", "https://evil.example/x", "http://slack.com/x", "https://files.slack.com.evil/x"])
    await both("download", () => t.download(url, "n", "xoxb-1"), url, "n", "xoxb-1");
  for (const path of ["/upload/ok", "/upload/bad", "/upload/odd"])
    await both("upload", () => t.upload(`${a.origin}${path}`, new Uint8Array([9, 8, 7]), "f.txt"), `${b.origin}${path}`, Buffer.from([9, 8, 7]).toString("base64"), "f.txt");
  assert.deepEqual(strip(b.log), strip(a.log));
});

test("who a token is, its pair checked, an install's code, a configuration token rotated and its owner", { skip }, async () => {
  await words("en");
  const respond = (): Respond => (r) => {
    const tok = r.auth?.slice(7) ?? "";
    switch (r.m) {
      case "auth.test":
        if (tok === "xoxb-bad") return { body: { ok: false, error: "invalid_auth" } };
        if (tok === "xoxe-none") return { body: { ok: false, error: "not_authed" } };
        return ok({ team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" });
      case "users.info":
        if (tok === "xoxb-nouser" || tok === "xoxe-2") return { body: { ok: false, error: "user_not_found" } };
        return ok({ user: { real_name: "Real", profile: { display_name: " ", real_name: "P", image_72: "http://no", image_48: "https://yes", email: "e@x", image_48x: 1 } } });
      case "apps.connections.open":
        return tok === "xapp-bad" ? { body: { ok: false, error: "invalid_auth" } } : ok({ url: "ws://x" });
      case "oauth.v2.access":
        return ok({ access_token: "xoxb-new", team: { name: r.p?.[2]?.[1] === "c2" ? "" : "Acme" } });
      case "tooling.tokens.rotate":
        return r.p?.[0]?.[1] === "bad" ? { body: { ok: false, error: "invalid_refresh_token" } } : ok({ token: "xoxe-n", refresh_token: "r-n", exp: r.p?.[0]?.[1] === "float" ? 1.5 : 1700000000, team_id: "T1" });
      case "bots.info":
        return ok({ bot: { app_id: "A1" } });
      case "team.info":
        return tok === "xoxe-2" ? { body: { ok: false } } : ok({ team: { name: "", domain: "acme", icon: { image_68: "https://icon" } } });
      default:
        return ok();
    }
  };
  const { a, b, t, id } = await clients(respond);
  const both = async (name: string, f: () => unknown, ...args: Json[]) => assert.deepEqual(await mbCall(id, name, ...args), await ts(f), `${name} ${JSON.stringify(args)}`);
  for (const tok of ["xoxb-1", "xoxb-nouser", "xoxb-bad"]) await both("identityOf", () => identityOf(t, tok), tok);
  for (const [app, bot] of [["xapp-1", "xoxb-1"], ["xapp-bad", "xoxb-bad"], ["nope", "nope"], ["xapp-1", "xoxb-nouser"]])
    await both("verifySlackTokens", () => verifySlackTokens(t, app!, bot!, "en"), app, bot);
  await both("exchangeInstallCode", () => exchangeInstallCode(t, "c", "s", "code", "https://r"), "c", "s", "code", "https://r");
  await both("exchangeInstallCode", () => exchangeInstallCode(t, "c", "c2", "code", "https://r"), "c", "c2", "code", "https://r");
  for (const r of [" r1 ", "bad", "float"]) await both("rotateConfigToken", () => rotateConfigToken(t, r), r);
  await both("appIdOf", () => appIdOf(t, "xoxb-1"), "xoxb-1");
  for (const tok of ["xoxe-1", "xoxe-2", "xoxe-none"]) await both("ownerOfConfigToken", () => ownerOfConfigToken(t, tok), tok);
  // (users.info and team.info asked at once: each side in its own order)
  const sorted = (log: Req[]) => strip(log).sort((x, y) => JSON.stringify(x).localeCompare(JSON.stringify(y)));
  assert.deepEqual(sorted(b.log), sorted(a.log));
});

test("the app API with a person's configuration tokens: the one that owns an app found, a token rotated once, manifests edited in order", { skip }, async () => {
  await words("zh");
  const respond = (): Respond => (r) => {
    const tok = r.auth?.slice(7) ?? "";
    switch (r.m) {
      case "tooling.tokens.rotate":
        return ok({ token: `xoxe-rot-${r.p?.[0]?.[1]}`, refresh_token: `${r.p?.[0]?.[1]}+`, exp: 4_000_000_000, team_id: { r1: "T1", r2: "T2", r3: "T3" }[r.p?.[0]?.[1] ?? ""] ?? "" });
      case "apps.manifest.export":
        return tok.includes("T1") || tok === "xoxe-rot-r1" ? { body: { ok: false, error: "app_not_found" } } : ok({ manifest: MANIFEST });
      case "apps.manifest.validate":
        return ok();
      case "apps.manifest.update":
        return ok({ permissions_updated: true });
      case "apps.manifest.create":
        return ok({ app_id: "A5", credentials: { client_id: "cid", client_secret: "sec" }, extra: "xoxb-zzz" });
      case "apps.icon.set":
        return ok();
      default:
        return ok();
    }
  };
  const tokens = () => [
    { accessToken: "xoxe-T1", refreshToken: "r1", expiresAt: 0, teamId: "T1", by: "a@x", owner: { team: "Acme" } },
    { accessToken: "xoxe-T2", refreshToken: "r2", expiresAt: 4_000_000_000_000, teamId: "T2", by: "a@x" },
    { accessToken: "xoxe-T3", refreshToken: "r3", expiresAt: 0, teamId: "T3", by: "c@x" },
  ];
  const { a, b, t, id: client } = await clients(respond);
  const id = idOf("apps");
  await mbNew({ kind: "apps", id, client, tokens: tokens() });
  let kept: Json[] = tokens();
  const savedTs: Json[] = [];
  const savedMb: Json[] = [];
  asked = (name, of, args) => {
    if (name === "save" && of === id) savedMb.push(args[0]);
    return null;
  };
  const apps = new SlackApps({ client: t, load: () => kept, save: (token) => { savedTs.push(plain(token)); kept = upsertToken(kept, token); } });
  const both = async (name: string, f: () => unknown, ...args: Json[]) => assert.deepEqual(await mbCall(id, name, ...args), await ts(f), `${name} ${JSON.stringify(args)}`);
  await both("configured", () => apps.configured("a@x"), "a@x");
  await both("configured", () => apps.configured("z@x"), "z@x");
  // T1's token is spent (rotated first) and does not own A1; T2's does
  await both("exportManifest", () => apps.exportManifest("a@x", "A1"), "a@x", "A1");
  await both("exportManifest", () => apps.exportManifest("a@x", "A1"), "a@x", "A1");
  await both("updateManifest", () => apps.updateManifest("a@x", "A1", { x: 1 }), "a@x", "A1", { x: 1 });
  await both("editManifest", () => apps.editManifest("a@x", "A1", (m) => upgraded(m)), "a@x", "A1", "upgraded");
  await both("editManifest", () => apps.editManifest("a@x", "A1", () => null), "a@x", "A1", "none");
  await both("exportManifest", () => apps.exportManifest("z@x", "A1"), "z@x", "A1");
  await both("createApp", () => apps.createApp("a@x", "T2", { n: 1 }), "a@x", "T2", { n: 1 });
  await both("createApp", () => apps.createApp("a@x", "T9", { n: 1 }), "a@x", "T9", { n: 1 });
  await both("setIcon", () => apps.setIcon("a@x", "A5", new Uint8Array([1, 2]), "image/jpeg"), "a@x", "A5", Buffer.from([1, 2]).toString("base64"), "image/jpeg");
  await both("setIcon", () => apps.setIcon("a@x", "A5", new Uint8Array([3]), "image/gif"), "a@x", "A5", Buffer.from([3]).toString("base64"), "image/gif");
  // two at once with an expired token: rotated once, the second taking the pair the first made
  const twice = await mbCall(id, "all", [["createApp", ["c@x", "T3", { n: 2 }]], ["createApp", ["c@x", "T3", { n: 3 }]]]);
  const tsTwice = await Promise.all([ts(() => apps.createApp("c@x", "T3", { n: 2 })), ts(() => apps.createApp("c@x", "T3", { n: 3 }))]);
  assert.deepEqual(twice, { ok: tsTwice });
  // (the two creations after the one rotation go out together: which reaches Slack first is the sockets')
  const settled = (log: Json[]) => [...log.slice(0, -2), ...log.slice(-2).sort((x, y) => JSON.stringify(x).localeCompare(JSON.stringify(y)))];
  assert.deepEqual(settled(strip(b.log)), settled(strip(a.log)), "what each asked of Slack");
  assert.equal(a.log.filter((r) => r.m === "tooling.tokens.rotate").length, 2, "each spent token rotated once");
  assert.deepEqual(savedMb, savedTs, "what each kept of a rotation");
  assert.deepEqual((await mbCall(id, "tokens")).ok, plain(kept));
});

test("an installer Slack Connect refuses: which names, and its zip of one stored entry, byte for byte", { skip }, async () => {
  for (const name of ["app.apk", "APP.AAB", "x.Exe", "a.msi", "b.bat", "c.cmd", "d.com", "e.scr", "f.dmg", "g.pkg", "a.b.apk", ".apk", "apk", "a.apk.txt", "log.txt", "dir.apk/x", "", "a."])
    assert.deepEqual(await mbFn("connectBlocked", name), { ok: connectBlocked(name) }, `connectBlocked ${name}`);
  const sized = (n: number, seed: number) => Uint8Array.from({ length: n }, (_, i) => (i * 131 + seed * 7 + (i >> 3)) & 0xff);
  const cases: [string, Uint8Array][] = [
    ["app.apk", sized(0, 1)],
    ["app.apk", sized(1, 2)],
    ["build/out/Setup 安装.exe", sized(4099, 3)],
    ["C:\\dist\\tool.msi", sized(65_537, 4)],
    ["dir/", sized(10, 5)],
    ["x", sized(300_000, 6)],
  ];
  for (const [name, bytes] of cases) {
    const want = Buffer.from(await zipOne(name, bytes)).toString("base64");
    assert.deepEqual(await mbFn("zipOne", name, Buffer.from(bytes).toString("base64")), { ok: want }, `zipOne ${name} ${bytes.length}`);
  }
});

// ── the surface ──

const IDENTITY = { team: "Acme", team_id: "T1", url: "https://acme.slack.com/", user_id: "UB", user: "bot", bot_id: "BB" };
/// Slack as the surfaces' stand-in answers: who the bot is, the socket's address, posts given ts in order, and what
/// each case asks for besides (`more`).
function slackFor(more: (r: Req, slack: Stand, n: number) => Answer | null = () => null): () => Respond {
  return () => {
    let posted = 0;
    let n = 0;
    return (r, slack) => {
      n += 1;
      // (Slack's own limit: chat.update refuses a `text` over 4,000 UTF-8 bytes, though chat.postMessage takes it)
      if (r.m === "chat.update" && Buffer.byteLength(r.p?.find((p) => p[0] === "text")?.[1] ?? "", "utf8") > 4_000)
        return { body: { ok: false, error: "msg_too_long" } };
      const said = more(r, slack, n);
      if (said !== null) return said;
      switch (r.m) {
        case "auth.test":
          return ok(IDENTITY);
        case "users.info":
          return r.p?.[0]?.[1] === "UB" ? ok({ user: { profile: { display_name: "Agent", image_72: "https://bot" } } }) : ok({ user: { name: `n-${r.p?.[0]?.[1]}`, profile: { display_name: `Person ${r.p?.[0]?.[1]}`, email: "P@X.Y", image_72: "https://p" } } });
        case "apps.connections.open":
          return ok({ url: `ws://${slack.origin.slice(7)}/socket` });
        case "chat.postMessage":
          posted += 1;
          return ok({ ts: `100.00000${posted}` });
        case "conversations.info":
          return r.p?.[0]?.[1] === "CX" ? ok({ channel: { is_ext_shared: true, name: "ext" } }) : r.p?.[0]?.[1] === "D1" ? ok({ channel: { is_im: true } }) : ok({ channel: { name: `name-${r.p?.[0]?.[1]}` } });
        case "files.getUploadURLExternal":
          return ok({ upload_url: `${slack.origin}/upload/${r.p?.[0]?.[1]}`, file_id: `F-${r.p?.[0]?.[1]}` });
        case "files.completeUploadExternal":
          return ok({ files: [{ shares: { private: { [r.p?.find((p) => p[0] === "channel_id")?.[1] ?? ""]: [{ ts: "200.000001" }] } } }] });
        default:
          return ok();
      }
    };
  };
}

type Side = { stand: Stand; events: Json[]; acks: () => Json[] };
/// A surface of each side, started on its stand-in, its socket open.
async function surfaces(respond: () => Respond, options: { handler?: (event: Json) => void; models?: Json[]; first?: Json[]; onWorking?: () => boolean; book?: boolean } = {}) {
  await words("zh");
  const [a, b] = await pair(respond);
  const tsEvents: Json[] = [];
  const mbEvents: Json[] = [];
  const handler = options.handler ?? (() => {});
  const book = options.book ? new NameBook(join(fresh("names"), "slack-names.json")) : null;
  let learned = 0;
  book?.onLearn(() => {
    learned += 1;
    told.emit("change");
  });
  const id = idOf("surface");
  const client = idOf("client");
  await mbNew({ kind: "client", id: client, base: b.base });
  await mbNew({ kind: "surface", id, client, appToken: "xapp-1", botToken: "xoxb-1", connect: "c1", models: options.models ?? MODELS, first: options.first ?? null, pingMs: 600_000, staleMs: 600_000, book: options.book ?? false });
  const previous = asked;
  asked = (name, of, args) => {
    if (of !== id) return previous(name, of, args);
    if (name === "handler") {
      mbEvents.push(args[0]);
      told.emit("change");
      return handler(args[0]);
    }
    if (name === "onWorking") return options.onWorking?.() ?? false;
    return null;
  };
  const surface = new SlackSurface({
    appToken: "xapp-1", botToken: "xoxb-1", client: new SlackClient(a.base), connect: "c1", book, pingMs: 600_000, staleMs: 600_000,
    models: () => (options.models ?? MODELS) as Json, modelsFirst: options.first ? () => options.first as Json : undefined, onWorking: () => options.onWorking?.() ?? false,
  });
  await surface.start(async (event) => {
    tsEvents.push(plain(event));
    told.emit("change");
    handler(event);
  });
  assert.deepEqual(await mbCall(id, "start"), { ok: null });
  await until("both sockets open", () => a.sockets.length === 1 && b.sockets.length === 1);
  // each side says itself connected once its socket opened on its side (the MoonBit tells each change of it)
  const changed = () => tells.filter((t) => t.name === "changed" && t.of === id).length;
  surface.onChange(() => told.emit("change"));
  await until("the TypeScript connected", () => surface.socket().connected);
  await until("the MoonBit told a change", () => changed() >= 1);
  assert.deepEqual(await mbCall(id, "socket"), { ok: { connected: true, lastError: null } });
  const mb = (name: string, ...args: Json[]) => mbCall(id, name, ...args);
  const both = async (name: string, f: () => unknown, ...args: Json[]) => {
    const [x, y] = [await ts(f), await mb(name, ...args)];
    assert.deepEqual(y, x, `${name} ${JSON.stringify(args).slice(0, 200)}`);
    return x;
  };
  const same = (what: string) => assert.deepEqual(strip(b.log), strip(a.log), what);
  standing = () => JSON.stringify({ ts: a.log.slice(-4), mb: b.log.slice(-4), tsEvents: tsEvents.length, mbEvents: mbEvents.length });
  let closed = false;
  const close = async () => {
    if (closed) return;
    closed = true;
    await surface.stop();
    await book?.close();
    await mb("stop");
  };
  closers.push(close);
  return { a, b, surface, tsEvents, mbEvents, mb, both, same, close, learned: () => learned, id };
}

test("the surface: who it is, the socket's events taken and acknowledged, edits, stops and a reconnect", { skip }, async () => {
  const s = await surfaces(
    slackFor((r) => {
      if (r.m !== "files.info") return null;
      const id = r.p?.[0]?.[1];
      if (id === "F9") return ok({ file: { id: "F9", name: "image.png", size: 108054, mode: "hosted", url_private_download: "https://files.slack.com/files-pri/T-F9/download/image.png" } });
      if (id === "F6") return ok({});
      return { body: { ok: false, error: "file_not_found" } };
    }),
    { handler: (e) => { if (e?.message?.text === "refuse") throw new Error("not kept"); } },
  );
  await s.both("identity", () => s.surface.identity(), );
  await s.both("socket", () => s.surface.socket());
  for (const name of ["botUserId", "botName", "workspace", "platform"] as const) await s.both(name, () => (s.surface as Json)[name]());
  const envelopes: Json[] = [
    { type: "hello" },
    { type: "events_api", envelope_id: "e1", payload: { event: { type: "message", channel: "C1", user: "U1", text: "hi <@UB>", ts: "10.1" } } },
    { type: "events_api", envelope_id: "e2", payload: { event: { type: "message", channel: "C1", user: "U1", text: "refuse", ts: "10.2" } } },
    { type: "events_api", envelope_id: "e3", payload: { event: { type: "message", subtype: "message_changed", channel: "C1", message: { ts: "10.1", user: "U1", text: "edited" } } } },
    { type: "events_api", envelope_id: "e4", payload: { event: { type: "reaction_added" } } },
    { type: "events_api", payload: { event: { type: "app_mention", channel: "C1", user: "U1", text: "x", ts: "10.3" } } },
    "not json",
  ];
  for (const e of envelopes) {
    for (const side of [s.a, s.b]) side.socket.send(typeof e === "string" ? e : JSON.stringify(e));
  }
  await until("the events taken", () => s.tsEvents.length === 4 && s.mbEvents.length === 4 && s.a.acks.length === 4 && s.b.acks.length === 4);
  const order = (xs: Json[]) => [...xs].sort((x, y) => JSON.stringify(x).localeCompare(JSON.stringify(y)));
  assert.deepEqual(order(s.mbEvents), order(s.tsEvents));
  assert.deepEqual(order(s.b.acks), order(s.a.acks), "acknowledged, the one refused not");
  // a stop of the agent's session: when, in the machine's time, at the latest
  const before = Date.now();
  for (const side of [s.a, s.b]) side.send({ type: "events_api", envelope_id: "e5", payload: { event: { type: "agent_session_stopped", channel: "C1", thread_ts: "10.0", event_ts: "1794889343.000100" } } });
  await until("the stop taken", () => s.tsEvents.length === 5 && s.mbEvents.length === 5);
  // (each side's stand-in says its own Date, rounded down to its second, as Slack's does)
  const [tsAt, mbAt] = [s.tsEvents[4].localAt, s.mbEvents[4].localAt];
  assert.ok(typeof tsAt === "number" && typeof mbAt === "number" && Math.abs(tsAt - mbAt) <= 1000 + (Date.now() - before), `the stop's time ${tsAt} ${mbAt}`);
  assert.deepEqual({ ...s.mbEvents[4], localAt: 0 }, { ...s.tsEvents[4], localAt: 0 });
  // files given by their id alone, looked up with files.info before the message is handed on: one found (beside one
  // given whole, not looked up), one Slack answers with no file and one it refuses (both kept as given); one message at
  // a time, so each side asks Slack in one order
  const shared: Json[][] = [
    [{ id: "F9", file_access: "check_file_info" }, { id: "F7", name: "a.txt", size: 3, url_private: "https://files.slack.com/a" }],
    [{ id: "F6", file_access: "check_file_info" }],
    [{ id: "F8", file_access: "check_file_info" }],
  ];
  for (const [i, files] of shared.entries()) {
    for (const side of [s.a, s.b]) side.send({ type: "events_api", envelope_id: `f${i}`, payload: { event: { type: "message", subtype: "file_share", channel: "C1", user: "U1", ts: `10.${5 + i}`, text: "see", files } } });
    await until(`the files of f${i} looked up`, () => s.tsEvents.length === 6 + i && s.mbEvents.length === 6 + i && s.a.acks.length === 6 + i && s.b.acks.length === 6 + i);
    assert.deepEqual(s.mbEvents[5 + i], s.tsEvents[5 + i], `f${i}`);
  }
  assert.deepEqual(s.tsEvents[5].message.files[0], { id: "F9", name: "image.png", size: 108054, url: "https://files.slack.com/files-pri/T-F9/download/image.png" });
  // Slack asks for another socket
  for (const side of [s.a, s.b]) side.send({ type: "disconnect", reason: "refresh_requested" });
  await until("both connected again", () => s.a.sockets.length === 2 && s.b.sockets.length === 2);
  await until("both say connected", () => s.surface.socket().connected);
  s.same("what each asked of Slack");
  await s.close();
});

test("the surface posts: parts, a question's card, a login's, files shared, a new thread, an edit and where the thread stands", { skip }, async () => {
  const file = join(fresh("files"), "log.txt");
  writeFileSync(file, "the log\n");
  const s = await surfaces(slackFor((r) => (r.m === "files.info" ? ok({ file: { shares: { public: { C2: [{ ts: "300.1" }] } } } }) : r.m === "files.completeUploadExternal" && r.p?.find((p) => p[0] === "channel_id")?.[1] === "C2" ? ok({ files: [{}] }) : null)));
  const T = { channel: "C1", threadTs: "10.0" };
  const long = Array.from({ length: 30 }, (_, i) => `paragraph ${i} ${"word ".repeat(40)}`).join("\n\n");
  await s.both("post", () => s.surface.post(T, "short **md**", []), T, "short **md**", []);
  await s.both("post", () => s.surface.post(T, long, []), T, long, []);
  await s.both("post", () => s.surface.post(T, "Which?", [], OPTIONS), T, "Which?", [], OPTIONS);
  await s.both("post", () => s.surface.post(T, "x".repeat(9000), [], { type: "text" }), T, "x".repeat(9000), [], { type: "text" });
  const login = { type: "login", page: { url: "https://login.example/x", domain: "login.example", paste: true } };
  await s.both("post", () => s.surface.post(T, "Sign in", [], login), T, "Sign in", [], login);
  await s.both("post", () => s.surface.post({ channel: "CX", threadTs: "1.0" }, "Sign in", [], login), { channel: "CX", threadTs: "1.0" }, "Sign in", [], login);
  const att = [{ name: "log.txt", path: file, size: 8 }];
  await s.both("post", () => s.surface.post(T, "with a file", att), T, "with a file", att);
  await s.both("post", () => s.surface.post({ channel: "C2", threadTs: "1.0" }, "", att), { channel: "C2", threadTs: "1.0" }, "", att);
  await s.both("post", () => s.surface.post(T, "", []), T, "", []);
  // an installer: zipped in a channel shared with another organization (CX), as it is in the workspace's own (C1); a
  // text file beside it goes as it is in both
  const apk = join(fresh("apk"), "app.apk");
  writeFileSync(apk, Buffer.from(Array.from({ length: 5000 }, (_, i) => (i * 37) & 0xff)));
  const installer = [{ name: "app.apk", path: apk, size: 5000 }, ...att];
  await s.both("post", () => s.surface.post({ channel: "CX", threadTs: "2.0" }, "the build", installer), { channel: "CX", threadTs: "2.0" }, "the build", installer);
  await s.both("post", () => s.surface.post(T, "the build", installer), T, "the build", installer);
  s.same("installers zipped where Slack Connect refuses them");
  const named = s.a.log.filter((r) => r.m === "files.getUploadURLExternal").map((r) => r.p?.[0]?.[1]);
  assert.ok(named.includes("app.apk.zip") && named.includes("app.apk"), `uploaded as ${named.join(", ")}`);
  await s.both("post", () => s.surface.post(T, "x", [{ name: "gone", path: join(fresh("none"), "gone"), size: 1 }]), T, "x", [{ name: "gone", path: join(fresh("none2"), "gone"), size: 1 }]).catch(() => {});
  await s.both("begin", () => s.surface.begin("C3", long), "C3", long);
  await s.both("edit", () => s.surface.edit(T, "100.000001", "changed"), T, "100.000001", "changed");
  await s.both("edit", () => s.surface.edit(T, "100.000001", long), T, "100.000001", long);
  // where the thread stands: under the bot's own newest message, then moved off it, then a message of its own
  const stands = async (thread: Json, st: Json, count: number) => {
    s.surface.standsAt(thread, st);
    await s.mb("standsAt", thread, st);
    await until(`stands ${JSON.stringify(st)}`, () => s.a.log.length === count && s.b.log.length === count);
  };
  let n = s.a.log.length;
  await stands(T, { kind: "done", words: "all set" }, n + 1);
  n = s.a.log.length;
  await stands(T, { kind: "need", words: "a key" }, n + 2);
  n = s.a.log.length;
  await stands(T, null, n + 1);
  n = s.a.log.length;
  await stands({ channel: "C9", threadTs: "9.0" }, { kind: "left", words: null }, n + 1);
  n = s.a.log.length;
  await stands({ channel: "C9", threadTs: "9.0" }, { kind: "done", words: null }, n + 2);
  await s.both("edit", () => s.surface.edit(T, "100.000001", "again"), T, "100.000001", "again");
  s.same("what each asked of Slack");
  await s.close();
});

test("cards pressed and closed, the /sf form, a login's code, status lines and what is asked of Slack's lists", { skip }, async () => {
  let refuse = false;
  // each side's first status refused as Slack refuses an agent session before the app is set up, then taken
  const refusedOnce = new Set<Stand>();
  const s = await surfaces(
    slackFor((r, slack) => {
      if (r.m === "agents.sessions.setStatus") {
        if (refusedOnce.has(slack)) return ok();
        refusedOnce.add(slack);
        return { body: { ok: false, error: "not_authorized" } };
      }
      if (r.m === "assistant.threads.setStatus") return { body: { ok: false, error: "missing_scope" } };
      if (r.m === "users.conversations") return r.p?.some((p) => p[0] === "cursor") ? ok({ channels: [{ id: "C3", name: "" }] }) : ok({ channels: [{ id: "C1", name: "one", is_private: true }, { id: "" }], response_metadata: { next_cursor: "n2" } });
      if (r.m === "conversations.list") return ok({ channels: [{ id: "C1", is_member: true }, { id: "C4", name: "four" }] });
      if (r.m === "conversations.members") return ok({ members: ["U1", "U2", "U1", "UX", 5] });
      if (r.m === "users.list")
        return ok({ members: [{ id: "U1", profile: { display_name: "ann", real_name: "Ann  Lee", image_72: "https://a" } }, { id: "U2", name: "bob", real_name: "Bob" }, { id: "UBOT", is_bot: true }, { id: "USLACKBOT" }, { id: "U3", profile: { real_name: "A N N" }, name: "" }] });
      if (r.m === "conversations.replies")
        return r.p?.some((p) => p[0] === "cursor") ? ok({ messages: [{ ts: "12.0", user: "U2", text: "late" }] }) : ok({ messages: [{ ts: "10.0", user: "U1", text: "root", files: TABLE.files }, { ts: "11.0", bot_id: "B9", text: "bot" }, { ts: "11.5", user: "UB", text: "me" }, { ts: "x" }], response_metadata: { next_cursor: "c2" } });
      if (r.m === "users.lookupByEmail") return r.p?.[0]?.[1] === "gone@x" ? ok({ user: { id: "U7", deleted: true } }) : r.p?.[0]?.[1] === "none@x" ? { body: { ok: false, error: "users_not_found" } } : ok({ user: { id: "U8" } });
      if (r.m === "views.open" || r.m === "chat.update" || r.m === "chat.postEphemeral") return ok();
      if (r.m === "/files/a") return { raw: "abc", headers: { "content-type": "text/plain" } };
      return null;
    }),
    {
      handler: (e) => {
        if (e?.type === "loginCode" && e.code === "bad") throw new Error("the login ended");
        if (refuse && e?.type === "message") throw new Error("busy");
      },
      first: [MODELS[1]],
      onWorking: () => true,
      book: true,
    },
  );
  const T = { channel: "C1", threadTs: "10.0" };
  await s.both("post", () => s.surface.post(T, "Which?", [], OPTIONS), T, "Which?", [], OPTIONS);
  const press = (values: Json, extra: Json = {}) => ({
    type: "block_actions",
    user: { id: "U1" },
    channel: { id: "C1" },
    message: { ts: "100.000001", thread_ts: "10.0", text: "Which?", blocks: [{ type: "markdown", text: "Which?" }, { type: "actions" }] },
    actions: [{ action_id: "sf_answer", value: JSON.stringify({ l: ["按今天累计", "x".repeat(80), "先不改"] }), action_ts: "100.5" }],
    state: { values },
    ...extra,
  });
  const interact = async (payload: Json, wait: () => boolean, what: string) => {
    for (const side of [s.a, s.b]) side.send({ type: "interactive", envelope_id: `i-${what}`, payload });
    await until(what, wait);
  };
  let n = s.a.log.length;
  // nothing chosen: only they are told
  await interact(press({}), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "nothing chosen");
  n = s.a.log.length;
  await interact(press({ b: { sf_pick: { selected_option: { value: "2" } } } }), () => s.a.log.length === n + 2 && s.b.log.length === n + 2, "answered");
  n = s.a.log.length;
  await interact(press({ b: { sf_pick: { selected_option: { value: "0" } } } }), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "answered before");
  // a card the station posted before a restart: its words read from the press
  refuse = true;
  n = s.a.log.length;
  await interact(press({ b: { sf_pick: { selected_option: { value: "0" } } } }, { message: { ts: "77.0", thread_ts: "10.0", text: "old", blocks: [] } }), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "refused answer");
  refuse = false;
  n = s.a.log.length;
  await interact(press({ b: { sf_pick: { selected_option: { value: "0" } } } }, { message: { ts: "77.0", thread_ts: "10.0", text: "old", blocks: [] } }), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "answered after a restart");
  // a login's code
  await s.both("post", () => s.surface.post(T, "Sign in", [], { type: "login" }), T, "Sign in", [], { type: "login" });
  const code = (value: Json) => ({ type: "block_actions", user: { id: "U2" }, container: { channel_id: "C1", message_ts: "100.000002", thread_ts: "10.0" }, actions: [{ action_id: "sf_login" }], state: { values: { sf_code: { sf_code: { value } } } } });
  n = s.a.log.length;
  await interact(code("  "), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "no code");
  n = s.a.log.length;
  await interact(code("bad"), () => s.a.log.length === n + 1 && s.b.log.length === n + 1, "code refused");
  n = s.a.log.length;
  await interact(code("123"), () => s.a.log.length === n + 2 && s.b.log.length === n + 2, "code entered");
  // a card closed otherwise
  await s.both("post", () => s.surface.post(T, "Name?", [], { type: "text" }), T, "Name?", [], { type: "text" });
  await s.both("cardEnded", () => s.surface.cardEnded(T, "100.000003", "Name?", { type: "text" }, { why: "message", by: "U1", byTs: "1" }), T, "100.000003", "Name?", { type: "text" }, { why: "message", by: "U1", byTs: "1" });
  await s.both("cardEnded", () => s.surface.cardEnded(T, "100.000003", "Name?", { type: "text" }, { why: "closed" }), T, "100.000003", "Name?", { type: "text" }, { why: "closed" });
  await s.both("cardEnded", () => s.surface.cardEnded(T, "55.0", "x", { type: "options" }, { why: "replaced" }), T, "55.0", "x", { type: "options" }, { why: "replaced" });
  await s.both("cardEnded", () => s.surface.cardEnded(T, "56.0", "x", { type: "other" }, { why: "replaced" }), T, "56.0", "x", { type: "other" }, { why: "replaced" });
  // `/sf`: its form, its model field's options, the form sent
  n = s.a.log.length;
  // each envelope waited for by its acknowledgement on both sides
  const acked = (envelope: string) => () => [s.a, s.b].every((side) => side.acks.some((x: Json) => x?.envelope_id === envelope));
  await interact({ type: "block_suggestion", value: "", user: { id: "U1" } }, acked("i-options for nothing typed"), "options for nothing typed");
  await interact({ type: "block_suggestion", value: "claude" }, acked("i-options for what is typed"), "options for what is typed");
  for (const side of [s.a, s.b]) side.send({ type: "slash_commands", envelope_id: "sc", payload: { command: "/sf", trigger_id: "tr", channel_id: "C1", text: " do it " } });
  await until("the form opened", () => s.a.log.length === n + 1 && s.b.log.length === n + 1 && acked("sc")());
  const submit = (model: Json, w: string) => ({ type: "view_submission", user: { id: "U1" }, view: { callback_id: "stillfail-new-chat", private_metadata: JSON.stringify({ channel: "C5" }), state: { values: { model: { model: { selected_option: { value: model } } }, words: { words: { value: w } } } } } });
  await interact(submit('["nobody",null]', "x"), acked("i-no such model"), "no such model");
  await interact(submit('["claude","opus"]', " "), acked("i-no words"), "no words");
  const events = s.tsEvents.length;
  await interact(submit('["claude","opus"]', "start this"), () => acked("i-a chat started")() && s.tsEvents.length === events + 1 && s.mbEvents.length === s.tsEvents.length, "a chat started");
  const order = (xs: Json[]) => [...xs].sort((x, y) => JSON.stringify(x).localeCompare(JSON.stringify(y)));
  assert.deepEqual(order(s.b.acks), order(s.a.acks), "what each acknowledged");
  assert.deepEqual(s.mbEvents, s.tsEvents, "what each handed the station");
  s.same("what each asked of Slack, the cards and the form");
  // a status line: the agent session refused until the app is set up (onWorking), then shown; cleared at the end
  n = s.a.log.length;
  s.surface.working(T, "10.0", "读取文件");
  await s.mb("working", T, "10.0", "读取文件");
  await until("the status shown", () => s.a.log.length === n + 2 && s.b.log.length === n + 2);
  n = s.a.log.length;
  s.surface.working(T, null, "");
  await s.mb("working", T, null, "");
  await until("the status cleared", () => s.a.log.length === n + 1 && s.b.log.length === n + 1);
  s.same("the status line");
  // the lists
  await s.both("places", () => s.surface.places());
  await s.both("openPlaces", () => s.surface.openPlaces());
  await s.both("join", () => s.surface.join("C4"), "C4");
  await s.both("joins", () => s.surface.joins());
  await s.both("peopleIn", () => s.surface.peopleIn("C1"), "C1");
  await s.both("peopleIn", () => s.surface.peopleIn("C1"), "C1");
  await s.both("history", () => s.surface.history(T, "11.5", 2), T, "11.5", 2);
  await s.both("history", () => s.surface.history(T, "nope", 10), T, "nope", 10);
  for (const c of ["C1", "D1", "CX"]) {
    await s.both("channelName", () => s.surface.channelName(c), c);
    await s.both("sharedOut", () => s.surface.sharedOut(c), c);
  }
  for (const u of ["U1", "U1"]) {
    await s.both("userName", () => s.surface.userName(u), u);
    await s.both("userEmail", () => s.surface.userEmail(u), u);
  }
  for (const e of [" P@X.Y ", "p@x.y", "gone@x", "none@x", ""]) await s.both("userOf", () => s.surface.userOf(e), e);
  await s.both("permalink", () => s.surface.permalink(T), T);
  for (const link of ["https://acme.slack.com/archives/C1/p1700000000000100", "https://acme.slack.com/archives/C1/p1700000000000100/?thread_ts=1699999999.000001&x=1", "https://acme.slack.com/archives/C1/p1700000000000100?thread_ts=bad", "https://other.slack.com/archives/C1/p1700000000000100", "https://acme.slack.com/archives/c1/p1700000000000100", "nope"])
    await s.both("threadOf", () => s.surface.threadOf(link), link);
  await s.both("api", () => s.surface.api("chat.postMessage", { channel: "C1", blocks: [{ a: 1 }], none: null, n: 3 }), "chat.postMessage", { channel: "C1", blocks: [{ a: 1 }], none: null, n: 3 });
  await s.both("download", async () => Buffer.from(await s.surface.download({ id: "F", name: "a", size: 3, url: `${s.a.origin}/files/a` })).toString("base64"), { id: "F", name: "a", size: 3, url: `${s.b.origin}/files/a` });
  await s.both("download", () => s.surface.download({ id: "F", name: "a", size: 3, url: null }), { id: "F", name: "a", size: 3, url: null });
  // names known without waiting: none at first, learned in the background
  // (each looked up in the background: the person asked only once the channel's lookup reached Slack on both sides, or
  // the two lookups reach it in either order)
  const asked = (m: string) => [s.a, s.b].map((x) => x.log.filter((r: Json) => r.m === m).length);
  const before = asked("conversations.info");
  await s.both("knownChannel", () => s.surface.knownChannel("C1"), "C1");
  await until("the channel looked up on both sides", () => asked("conversations.info").every((n, i) => n > before[i]!));
  await s.both("knownPerson", () => s.surface.knownPerson("U2"), "U2");
  await until("names learned", () => s.learned() >= 1 && tells.some((t) => t.of === s.id));
  await s.both("knownChannel", () => s.surface.knownChannel("C1"), "C1");
  await s.both("knownPerson", () => s.surface.knownPerson("U2"), "U2");
  s.same("what each asked of Slack");
  await s.close();
});

test("a message over chat.update's 4,000 bytes of text changed in place: a card answered, a login's code, a card closed, an edit, where the thread stands", { skip }, async () => {
  // 2,600 characters of Chinese, 7,800 bytes: one message as posted, and its text cut at a whole character (the rocket
  // after the first 3,996 bytes would cross the 3,997 the cut keeps)
  const long = `${"长".repeat(1332)}🚀${"长".repeat(1267)}`;
  const s = await surfaces(slackFor(), { handler: () => {} });
  const T = { channel: "C1", threadTs: "10.0" };
  const interact = async (payload: Json, count: number, what: string) => {
    for (const side of [s.a, s.b]) side.send({ type: "interactive", envelope_id: `i-${what}`, payload });
    await until(what, () => s.a.log.length === count && s.b.log.length === count);
  };
  await s.both("post", () => s.surface.post(T, long, [], OPTIONS), T, long, [], OPTIONS);
  await interact(
    {
      type: "block_actions", user: { id: "U1" }, channel: { id: "C1" }, message: { ts: "100.000001", thread_ts: "10.0", text: long },
      actions: [{ action_id: "sf_answer", value: JSON.stringify({ l: OPTIONS.options.map((o: Json) => o.label) }), action_ts: "100.5" }],
      state: { values: { b: { sf_pick: { selected_option: { value: "0" } } } } },
    },
    s.a.log.length + 2,
    "answered",
  );
  await s.both("post", () => s.surface.post(T, long, [], { type: "login" }), T, long, [], { type: "login" });
  await interact(
    { type: "block_actions", user: { id: "U2" }, container: { channel_id: "C1", message_ts: "100.000002", thread_ts: "10.0" }, actions: [{ action_id: "sf_login" }], state: { values: { sf_code: { sf_code: { value: "123" } } } } },
    s.a.log.length + 2,
    "code entered",
  );
  await s.both("post", () => s.surface.post(T, long, [], { type: "text" }), T, long, [], { type: "text" });
  await s.both("cardEnded", () => s.surface.cardEnded(T, "100.000003", long, { type: "text" }, { why: "closed" }), T, "100.000003", long, { type: "text" }, { why: "closed" });
  await s.both("post", () => s.surface.post(T, long, []), T, long, []);
  const stands = async (st: Json, count: number) => {
    s.surface.standsAt(T, st);
    await s.mb("standsAt", T, st);
    await until(`stands ${JSON.stringify(st)}`, () => s.a.log.length === count && s.b.log.length === count);
  };
  await stands({ kind: "done", words: "all set" }, s.a.log.length + 1);
  await s.both("edit", () => s.surface.edit(T, "100.000004", `${long}。`), T, "100.000004", `${long}。`);
  await stands(null, s.a.log.length + 1);
  s.same("what each asked of Slack");
  const updates = s.a.log.filter((r) => r.m === "chat.update");
  assert.equal(updates.length, 6);
  for (const u of updates) {
    const text = u.p!.find((p) => p[0] === "text")![1];
    assert.equal(text, `${"长".repeat(1332)}…`);
    assert.ok(Buffer.byteLength(text, "utf8") <= 4_000);
    assert.ok(JSON.parse(u.p!.find((p) => p[0] === "blocks")![1])[0].text.startsWith(long), "the message itself whole");
  }
  await s.close();
});

// ── the connects' apps kept up to date ──

test("a connected connect's app brought up to date once per configuration, and tried again as a turn begins", { skip }, async () => {
  await words("zh");
  let fail = true;
  const respond = (): Respond => (r) => {
    switch (r.m) {
      case "auth.test":
        return ok({ bot_id: "BB" });
      case "bots.info":
        return ok({ bot: { app_id: "A2" } });
      case "apps.manifest.export":
        return fail ? { body: { ok: false, error: "app_not_found" } } : ok({ manifest: { settings: { socket_mode_enabled: true }, oauth_config: { scopes: { bot: ["commands"] } } } });
      case "apps.manifest.update":
        return ok({ permissions_updated: false });
      default:
        return ok();
    }
  };
  const raw = () => ({
    connects: [
      { id: "c1", slack: { appToken: "xapp-1", botToken: "xoxb-1", team: { id: "T1", name: "Acme" } }, createdBy: { id: "a@x" } },
      { id: "c2", slack: { appToken: "xapp-2", botToken: "xoxb-2", appId: "A3" }, createdBy: { id: "b@x" } },
      { id: "c3", enabled: false, slack: { appToken: "xapp-3", botToken: "xoxb-3" }, createdBy: { id: "a@x" } },
    ],
    slackConfigTokens: [
      { accessToken: "xoxe-a", refreshToken: "r", expiresAt: 4_000_000_000_000, teamId: "T1", by: "a@x" },
      { accessToken: "xoxe-b", refreshToken: "r", expiresAt: 4_000_000_000_000, teamId: "T2", by: "b@x" },
    ],
  });
  const { a, b, t, id: client } = await clients(respond);
  // the TypeScript's: its connects connected by a stand-in connection, config.json in memory
  let config: Json = raw();
  const listeners: (() => void)[] = [];
  const identity = { team: "Acme", teamId: "T1", url: "", botUserId: "UB", botName: "b", botImage: null, botId: "BB" };
  const connection = (): Json => ({
    start: async () => {}, stop: async () => {}, socket: () => ({ connected: true, lastError: null }), identity: () => identity, onChange: () => () => {},
    refreshIdentity: async () => {}, botUserId: () => "UB", workspace: () => "T1", platform: () => "slack", post: async () => "1",
  });
  const parts = makeConnections({
    data: fresh("connects"), store: { liveSessions: () => [], notify: () => {} } as Json, receive: async () => {}, bound: () => true,
    config: { raw: () => config, listen: (f: () => void) => { listeners.push(f); return () => {}; }, updateSoon: async (f: (raw: Json) => void) => { f(config); }, written: async () => {} } as Json,
    client: t, create: () => connection(),
  });
  const id = idOf("upgrades");
  await mbNew({ kind: "upgrades", id, client, raw: raw(), identity: { teamId: "T1", botUserId: "UB" } });
  const sorted = (log: Req[]) => strip(log).sort((x, y) => JSON.stringify(x).localeCompare(JSON.stringify(y)));
  const settled = async (what: string) => {
    await mbCall(id, "settled");
    await until(what, () => a.log.length === b.log.length);
    assert.deepEqual(sorted(b.log), sorted(a.log), what);
  };
  await parts.reconcile();
  await mbCall(id, "upgradeApps");
  await until("both tried", () => a.log.length >= 3 && b.log.length >= 3);
  await settled("the first try, failing");
  const tried = a.log.length;
  // nothing changed: not tried again
  for (const f of listeners) f();
  await mbCall(id, "upgradeApps");
  await settled("not tried again");
  assert.equal(a.log.length, tried);
  // a token changed (config.json's edit told): tried again, and now it works; then nothing more
  fail = false;
  config = { ...raw(), slackConfigTokens: raw().slackConfigTokens.map((x) => ({ ...x, expiresAt: 4_100_000_000_000 })) };
  await mbCall(id, "set", config);
  for (const f of listeners) f();
  await mbCall(id, "upgradeApps");
  await until("tried again", () => a.log.filter((r) => r.m === "apps.manifest.update").length === 2);
  await settled("brought up to date");
  for (const f of listeners) f();
  await mbCall(id, "upgradeApps");
  await settled("done once");
  // a turn begins where it is up to date: whether it is, without asking Slack again but the one try a turn makes
  assert.deepEqual(await mbCall(id, "onWorking", "c1"), { ok: true });
  assert.deepEqual(await mbCall(id, "onWorking", "c3"), { ok: false });
  await parts.close();
  await mbCall(id, "close");
});
