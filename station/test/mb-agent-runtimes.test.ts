// The agents' runtimes in MoonBit (station/mb src/agent_runtimes: reader `--builder harness-agent-runtimes`) held to
// the TypeScript they move (src/agents: instructions, migrations, profiles, providers, sandbox, sandbox-name,
// no-keychain, machine-logins, repo-rules, rules-folder, the drivers of DeepSeek Harness, Cursor, Pi, Devin, Grok
// Build and Hermes Agent with acp.ts; src/agenthome/module.ts) on the same inputs: every text word for word under each
// setting, what each profile's runtime is started with, what a session writes to its process, says and tells the
// program and gives on as its events through its turns (a fake process under the real sessions here), what it keeps
// on the disk, a session opened on its process (the real drivers, their process a fake that answers each request), and
// when the agents' home's rounds run. Each case is given both whole; their outcomes must be the same.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, before, describe, mock, test } from "node:test";
import { Effect, Exit, Layer, Scope } from "effect";
import { facts } from "../src/accounts/catalog.ts";
import { seesImages } from "../src/accounts/models.ts";
import { AgentHomeLive } from "../src/agenthome/module.ts";
import * as acp from "../src/agents/acp.ts";
import * as cursor from "../src/agents/cursor.ts";
import * as devin from "../src/agents/devin.ts";
import * as dsh from "../src/agents/dsh.ts";
import * as grok from "../src/agents/grok.ts";
import * as hermes from "../src/agents/hermes.ts";
import * as I from "../src/agents/instructions.ts";
import * as logins from "../src/agents/machine-logins.ts";
import * as migrations from "../src/agents/migrations.ts";
import * as keychain from "../src/agents/no-keychain.ts";
import * as pi from "../src/agents/pi.ts";
import * as P from "../src/agents/profiles.ts";
import * as providers from "../src/agents/providers.ts";
import * as rules from "../src/agents/repo-rules.ts";
import { rulesFolder } from "../src/agents/rules-folder.ts";
import { runtimeKind, runtimeLabel, type OpenOptions } from "../src/agents/runtime.ts";
import * as sandbox from "../src/agents/sandbox.ts";
import { keyPart, sandboxName } from "../src/agents/sandbox-name.ts";
import { startEnv } from "../src/ops/agent-env.ts";
import { wall } from "../src/ops/fibers.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { platform } from "../src/platform/index.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Agents } from "../src/sessions/agents.ts";
import { ControlPlane, StationConfig } from "../src/services.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : false;
const posix = process.platform !== "win32";

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `agent-runtimes-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const child = spawn(binary!, ["--builder", "harness-agent-runtimes", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"] });
  const waiting: ((line: string) => void)[] = [];
  createInterface({ input: child.stdout }).on("line", (line) => waiting.shift()?.(line));
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  child.on("exit", (code) => { for (const w of waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${stderr}` })); });
  program = {
    child,
    next: (line) => new Promise((resolve) => {
      waiting.push((answer) => resolve(JSON.parse(answer)));
      child.stdin.write(`${line}\n`);
    }),
  };
  return program;
}
after(() => {
  program?.child.stdin.end();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit answers of `c`: its `ok`, or the words it failed with.
async function mb(c: unknown): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}
const call = (fn: string, ...args: unknown[]) => mb({ op: "call", fn, args });
/// What MoonBit says of what reads or writes the disk: `{ok}`, or `{refused}` with the words it failed with.
const io = (fn: string, ...args: unknown[]) => harness().next(JSON.stringify({ op: "io", fn, args }));

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
/// An outcome as the harness says it: `{ok}` or `{error}` with the words.
const outcome = (f: () => unknown) => {
  try {
    return { ok: plain(f()) };
  } catch (e) {
    return { error: (e as Error).message };
  }
};
/// Each case of `cases`, MoonBit's `fn` against the TypeScript's `ts`, on the same arguments.
async function same(fn: string, cases: unknown[][], ts: (...args: any[]) => unknown) {
  for (const args of cases) assert.deepStrictEqual(await call(fn, ...args), plain(ts(...args)), `${fn}(${JSON.stringify(args).slice(0, 300)})`);
}

/// Every file and link under `dir`, as [path below it, what it holds or "-> target", its mode].
function tree(dir: string): [string, string, number][] {
  const out: [string, string, number][] = [];
  const walk = (at: string, rel: string) => {
    for (const name of readdirSync(at).sort()) {
      const path = join(at, name), r = rel === "" ? name : `${rel}/${name}`;
      const st = lstatSync(path);
      if (st.isSymbolicLink()) out.push([r, `-> ${readlinkSync(path)}`, 0]);
      else if (st.isDirectory()) walk(path, r);
      else out.push([r, readFileSync(path, "utf8"), st.mode & 0o777]);
    }
  };
  if (existsSync(dir)) walk(dir, "");
  return out;
}

// ── The texts and what is made of them ───────────────────────────────────────────────────────────────────────────

const MESSAGES = (() => {
  const base = { thread: 7, n: 1, ts: "1794883188.902000", text: "hello", author: "U1", authorKind: "person", client: null, createdAt: 1794883189000, quotes: [] as any[], attachments: [] as any[] };
  const files = [
    { name: "shot.png", path: "/up/shot.png", size: 1200 },
    { name: "clip.mp4", path: "/up/clip.mp4", size: 99 },
    { name: "pasted-text-0123abcd-0123-4567-89ab-0123456789ab.txt", path: "/up/p.txt", size: 5 },
    { name: "pasted-text-short.txt", path: "/up/q.txt", size: 7 },
  ];
  return [
    base,
    { ...base, n: 3, text: "", client: "mbui \"7\" & co" },
    { ...base, ts: "abc", createdAt: 0, authorKind: "agent", author: "chat:c-1" },
    { ...base, ts: "1794883188", createdAt: 1.5e16 },
    { ...base, ts: "17948831889", createdAt: 1794883189123.75 },
    {
      ...base,
      attachments: files,
      quotes: [
        { role: "agent", author: "me", ts: "1.2", file: "clip.mp4", text: "line one\nline two", comment: "" },
        { role: "page", author: "https://x.test", ts: null, file: "shot.png", text: "#3", comment: "this one" },
        { role: "page", author: "https://y.test", file: "", text: "#1", comment: "" },
        { role: "image", author: "Ann", ts: "9", file: "shot.png", text: "pin 2", comment: "zoom" },
        { role: "person", author: "Bo", ts: 12, file: "missing.png", text: "", comment: "c" },
        { role: "person", author: "Cy", text: "no ts" },
      ],
    },
  ];
})();

const PENDING = MESSAGES.flatMap((m, i) => ["ember", "slack", "feishu:x", "comma:y", "group:z"].map((surface) => ({
  message: { ...m, thread: i % 3 },
  surface,
  channel: surface === "ember" ? "CHAT" : "C123",
  threadTs: i % 2 === 0 ? m.ts : "1794883100.000100",
  connect: i % 2 === 0 ? "ember" : "slack:T1",
})));

describe("instructions.ts, migrations.ts: every text word for word", { skip }, () => {
  test("the instructions under each setting, and the texts as they are", async () => {
    const cases: unknown[][] = [];
    for (const project of [null, "/Users/x/proj"])
      for (const memory of ["", "- a rule\n- another"])
        for (const site of ["", "Read skill site-x."])
          for (const station of ["", "tokyo-mac-studio-0", "名前 \"q\""])
            for (const move of [true, false]) cases.push(["/ws/chat-1", project, "/repos", "/agent/MEMORY.md", memory, site, station, move]);
    await same("sessionInstructions", cases, I.sessionInstructions);
    const texts = await call("texts");
    assert.deepStrictEqual(texts, plain({
      NUDGE: I.NUDGE, RESUME_AFTER_RESTART: I.RESUME_AFTER_RESTART, GO_ON_AFTER_AUTH: I.GO_ON_AFTER_AUTH, GO_ON_AFTER_CODEX_UPDATE: I.GO_ON_AFTER_CODEX_UPDATE,
      GO_ON_AFTER_SPENT: I.GO_ON_AFTER_SPENT, GO_ON_AFTER_OVERLOADED: I.GO_ON_AFTER_OVERLOADED, GO_ON_AFTER_FAILED: I.GO_ON_AFTER_FAILED,
      GO_ON_AFTER_UNANSWERED: I.GO_ON_AFTER_UNANSWERED, GO_ON_AFTER_REFILL: I.GO_ON_AFTER_REFILL, TOOLS_LOST: I.TOOLS_LOST, UNDECIDED: I.UNDECIDED,
      BACKGROUND_STOPPED_WAITING: I.BACKGROUND_STOPPED_WAITING, SITE_INSTRUCTIONS_MAX: I.SITE_INSTRUCTIONS_MAX, MEMORY_MOST: I.MEMORY_MOST,
      SKILL_MOST: I.SKILL_MOST, LINE_MOST: I.LINE_MOST, LONG_CHAT: I.LONG_CHAT, REWRITTEN: migrations.REWRITTEN, NOTES: migrations.NOTES,
      latest: migrations.latest(), STUB: readFileSync(new URL("../src/agents/no-keychain.ts", import.meta.url), "utf8").match(/const STUB = `([^`]*)`/)![1]!.replaceAll("\\\\", "\\"),
      CLAUDE_TOKEN_MARGIN_MS: logins.CLAUDE_TOKEN_MARGIN_MS, SANDBOX: sandbox.SANDBOX, CONNECTION_LOST: sandbox.CONNECTION_LOST, LOST_EXIT: sandbox.LOST_EXIT,
      CONFIG: devin.CONFIG, LEVELS: devin.LEVELS, HERMES_MODEL_LIMIT: hermes.HERMES_MODEL_LIMIT, FAST_RUNTIMES: P.FAST_RUNTIMES, OPENCODE: P.OPENCODE,
      OPENCODE_SMALL: P.OPENCODE_SMALL, DSH_KEY: P.DSH_KEY, PI_KEY: P.PI_KEY, KIMI_CODE: P.KIMI_CODE, SOURCES: providers.SOURCES,
    }));
  });

  test("what a session is told picking up again, and the notes it has not heard", async () => {
    await same("nameUntitled", [["CHAT/1.2"], ["C1/2.3"]], I.nameUntitled);
    await same("resumeLost", [["chat:c-1", []], ["chat:c-1", ["CHAT/1.2", "C/3.4"]], ["k", [], "/t.jsonl"], ["k", ["a"], "/t.jsonl"]], I.resumeLost);
    await same("afresh", [["k", []], ["k", ["x", "y"]]], I.afresh);
    await same("longChat", [[20, []], [1234.5, ["a/b"]]], I.longChat);
    await same("cleared", [["k", []], ["k", ["a/b", "c/d"]]], I.cleared);
    await same("backgroundStopped", [[[{ id: "a1", kind: "agent", description: "" }, { id: "c2", kind: "command", description: "npm test" }, { id: "a3", kind: "agent", description: "review" }], ["a3"]], [[], []]], I.backgroundStopped);
    await same("waitOver", [[60], [0.5], [3600]], I.waitOver);
    await same("continuedHere", [["the instructions\nwhole"]], I.continuedHere);
    const told = [0, 1, 50, 120, 121, 140, migrations.latest(), migrations.latest() + 3, 140.5];
    await same("untold", told.map((n) => [n, "/ws/.stillfail-instructions.md"]), migrations.untold);
  });

  test("what of the memory has grown past what an agent can use", async () => {
    const long = "x".repeat(1501), wide = "中".repeat(600), pair = "😀".repeat(400);
    await same("overgrown", [
      [[]],
      [[["MEMORY.md", "short"]]],
      [[["MEMORY.md", "a".repeat(8 * 1024 + 1)], ["skills/x/SKILL.md", "b".repeat(24 * 1024)]]],
      [[["MEMORY.md", `${long}\nok\n${long}`], ["skills/y/SKILL.md", `${wide}\n${pair}\n\ud800${"z".repeat(1498)}`]]],
      [[["skills/z/SKILL.md", `${"c".repeat(30_000)}\n${long}`]]],
    ], I.overgrown);
  });

  test("a message as the agent reads it, each kind of quote and file", async () => {
    await same("messageForAgent", MESSAGES.map((m) => [m]), I.messageForAgent);
  });

  test("messages handed over in each surface, with a thread new to it, names, selves, posts before and cards", async () => {
    const names = [["U1", "Ann"], ["chat:c-1", "Builder"]];
    const selves = [["slack:T1", "bot-self"]];
    const posts: [number, string][] = [[0, "1794883190.000001"], [7, "a\"b"]];
    const cards: [number, any][] = [
      [1, { ended: { author: "chat:me", ts: "1.1" }, current: null, special: null }],
      [2, { ended: { author: "chat:me", ts: "2.2" }, current: { ts: "3.3" }, special: "Call secret_reask." }],
      [3, { ended: { author: "chat:other", ts: "4\"4" }, current: null, special: "x" }],
      [4, { ended: { author: "chat:me", ts: "5" }, current: { ts: "6" }, special: null }],
    ];
    const ts = (messages: any[], newThreads: number[], n: [string, string][], s: [string, string][], p: [number, string][], c: [number, any][], selfKey: string) =>
      I.formatInbound(messages, new Set(newThreads), new Map(n), new Map(s), new Map(p.map(([i, v]) => [messages[i], v])), new Map(c.map(([i, v]) => [messages[i], v])), selfKey);
    await same("formatInbound", [
      [PENDING, [0, 1], names, selves, posts, cards, "chat:me"],
      [PENDING.slice(0, 3), [], [], [], [], [], ""],
      [PENDING.slice(10, 20), [2], names, [], [], cards, "chat:other"],
    ], ts);
  });

  test("choices on cards, widgets' state, and a thread's history", async () => {
    const choices = [
      { thread: 1, n: 2, ts: "1794883188.1", where: ["CHAT", "1794883100.000100"], question: "  Merge\n\n the   branch?  ", by: "a@x", option: "合并", at: 1794883188902 },
      { thread: 1, n: 3, ts: null, where: null, question: null, by: "b@x", option: "no", at: 1794883188902.5 },
      { thread: 1, n: 4, ts: "x\"y", where: null, question: "q".repeat(250) + "😀".repeat(3), by: "a@x", option: "later", at: 0 },
      { thread: 1, n: 5, ts: "1", where: null, question: "   ", by: "c@x", option: "o", at: 1794883188902.1234 },
    ];
    const nowTs = (c: any[], n: [string, string][], now: number) => I.formatCardChoices(c, new Map(n), now);
    await same("formatCardChoices", [[[], [], 0], [choices, [["a@x", "Ann"]], 1794883188902 + 3_600_000 * 26 + 61_000], [choices, [], 1794883188902 + 59_999], [choices, [], 1794883188902 + 3_600_000 * 2], [choices, [], 1794883188902 - 5]], nowTs);
    await same("formatWidgetModels", [[[]], [[{ path: "/w/a.html", name: "pick", thread: ["CHAT", "1.2"], model: "{\"a\":1}" }, { path: "/w/b", name: "b", thread: null, model: "x" }]]], I.formatWidgetModels);
    const history = MESSAGES.map((m, i) => ({ ...m, n: i + 1, authorKind: ["person", "agent", "ember", "agent", "person", "person"][i]!, author: ["U1", "chat:me", "ember", "chat:x", "U9", "U1"][i]! }));
    const cards: [number, any][] = [
      [1, { card: { type: "options", options: [{ label: "A" }], placeholder: 3 }, pending: true }],
      [2, { card: { type: "text", placeholder: "sk_", vault: { request: "r1" }, adb: { request: "p1" }, signin: { site: "x.com" }, login: "l1", station: "s" }, pending: false, chose: { by: "Ann", option: "A \"b\"" } }],
      [3, { card: null, pending: false }],
      [4, { card: { options: "no" }, pending: true }],
    ];
    const hist = (m: any[], surface: string, address: string, selfKey: string, n: [string, string][], c: [number, any][]) => I.formatHistory(m, surface, address, selfKey, new Map(n), new Map(c));
    await same("formatHistory", [[history, "ember", "CHAT/1.2", "chat:me", [["U1", "Ann"]], cards], [history, "feishu:x", "oc_1/om_2", "chat:x", [], []], [history, "slack", "C1/1794883100.000100", "", [], cards]], hist);
  });

  test("a conversation's address read back", async () => {
    const values = ["CHAT/1794883188.900000", " C12/1.2 ", "oc_abc123/om_x9", "oc_abc/omt_9", "oc_/om_1", "0123456789abcdef/0123456789abcdef", "d_0123456789abcdef01234567/d_0123456789abcdef01234567", "s_0123456789abcdef01234567/t_0123456789abcdef", "s_0123456789abcdef01234567/t_0123456789abcdeF", "x_0123456789abcdef01234567/x_0123456789abcdef01234567", "0123456789abcdef/x", "c1/1.2", "C1/1", "C1/.1", "C1/1.", "nothing", "/1.2", "C-1/1.2", "C1/1.2/3"];
    await same("parseThreadAddress", values.map((v) => [v]), I.parseThreadAddress);
    await same("threadAddress", [["C", "1.2"]], I.threadAddress);
  });
});

// ── Providers and profiles ───────────────────────────────────────────────────────────────────────────────────────

const PROFILES: any[] = (() => {
  const home = "/homes/p";
  const out: any[] = [];
  const runtimes = ["claude", "codex", "dsh", "pi", "grok", "devin", "cursor", "hermes", "agy", "nope"];
  for (const runtime of runtimes) {
    out.push({ id: `${runtime}-sub`, runtime, home, access: { kind: "subscription" } });
    out.push({ id: `${runtime}-env`, runtime, home, env: { CUSTOM: "1", ANTHROPIC_API_KEY: "mine", HERMES_HOME: "~/hh" } });
    out.push({ id: `${runtime}-machine`, runtime, home, machine: true, fast: true, model: "" });
  }
  for (const kind of ["opencode-go", "anthropic-api"]) for (const model of [undefined, "kimi-k2.6"]) out.push({ id: `${kind}-${model}`, runtime: "claude", home, model, access: { kind, key: "  k-1 " } });
  for (const s of providers.SOURCES) {
    out.push({ id: `api-${s.id}`, runtime: "claude", home, model: "m-1", access: { kind: "api-provider", provider: s.id, key: "pk" } });
    out.push({ id: `api-${s.id}-nokey`, runtime: "codex", home, access: { kind: "api-provider", provider: s.id } });
    if (s.endpointRequired) for (const endpoint of ["https://gw.example/v1/acct/gw/", "http://localhost:11434/v1", "https://cf.example/v1/a/b/anthropic", "ftp://x", "  "]) for (const protocol of [undefined, "chat_completions", "responses", "anthropic", "other"])
      out.push({ id: `api-${s.id}-${endpoint}-${protocol}`, runtime: "pi", home, model: "m", env: { X: "{route}-y" }, access: { kind: "api-provider", provider: s.id, endpoint, protocol, key: "" } });
  }
  out.push({ id: "kimi-login", runtime: "claude", home, access: { kind: "api-provider", provider: "kimi-code", login: true, key: "t" } });
  out.push({ id: "openrouter-fast", runtime: "claude", home, access: { kind: "api-provider", provider: "openrouter" } });
  // A proxy of the profile's own, and one a borrowed profile brought from its host's machine (left out).
  const proxied = { HTTPS_PROXY: "http://127.0.0.1:7890", no_proxy: "corp.example", All_Proxy: "socks5://h:1", KEEP: "1", MY_HTTP_PROXY: "y" };
  out.push({ id: "own-proxied", runtime: "codex", home, access: { kind: "subscription" }, env: proxied });
  out.push({ id: "borrowed-proxied", runtime: "codex", home, access: { kind: "subscription" }, env: proxied, share: { id: "sh-1", borrowed: true, host: "h" } });
  out.push({ id: "hosted-proxied", runtime: "claude", home, access: { kind: "subscription" }, env: proxied, share: { id: "sh-2", allow: [] } });
  out.push({ id: "odd", runtime: 5, home, access: "nope" });
  out.push({ id: "odd2", runtime: "claude", home, access: { kind: null, provider: "" } });
  return out;
})();

describe("providers.ts, profiles.ts: where each profile's account speaks and what its runtimes are given", { skip }, () => {
  test("each provider found, grouped and at its endpoints", async () => {
    const ids = [...providers.SOURCES.map((s) => s.id), "nope"];
    await same("find", ids.map((i) => [i]), (i) => providers.find(i) ?? null);
    await same("legacy", ids.map((i) => [i]), (i) => providers.LEGACY[i] ?? null);
    await same("groupOf", ids.map((i) => [i]), providers.groupOf);
    const addresses = ["https://a.test/v1/", " http://b.test ", "https://", "ftp://c", "https://a b", "https://x.test/v1///", "http://h:1/"];
    await same("cleanEndpoint", addresses.map((a) => [a]), (a) => providers.cleanEndpoint(a) ?? null);
    await same("anthropicRoot", [["https://a/v1"], ["https://a"]], providers.anthropicRoot);
    const ep: unknown[][] = [];
    for (const s of providers.SOURCES) for (const e of [undefined, "https://gw.test/v1/a/b/compat", "https://gw.test/v1", "nope"]) for (const p of [undefined, "chat_completions", "responses", "anthropic", "x"]) ep.push([s.id, e, p]);
    await same("endpoints", ep, (id, e, p) => providers.endpoints(providers.find(id)!, e, p) ?? null);
    await same("runtimesOf", [[{}], [{ chat: "c" }], [{ anthropic: "a", responses: "r" }], [{ responses: "r" }]], providers.runtimesOf);
  });

  test("each profile's kind, model, Fast, provider, routes, runtimes and environment", async () => {
    const each = PROFILES.map((p) => [p]);
    for (const [fn, ts] of [["accessKind", P.accessKind], ["billedPerUse", P.billedPerUse], ["kimiSignedIn", P.kimiSignedIn], ["keyFile", (p: any) => P.keyFile(p) ?? null], ["profileModel", (p: any) => P.profileModel(p) ?? null], ["isMachine", P.isMachine], ["profileFast", P.profileFast], ["takesFast", P.takesFast], ["fastNeedsCredits", P.fastNeedsCredits], ["profileVia", P.profileVia], ["dshRoute", P.dshRoute], ["piRoute", P.piRoute], ["profileRuntimes", P.profileRuntimes]] as const)
      await same(fn, each.filter(([p]) => fn !== "accessKind" || typeof p.access?.kind !== "number"), ts as any);
    const runtimes = ["claude", "codex", "dsh", "pi", "grok", "agy", "devin", "cursor", "hermes"];
    await same("profileEnv", PROFILES.flatMap((p) => runtimes.map((r) => [p, r])), P.profileEnv);
    const byId = (id: string) => PROFILES.find((p) => p.id === id);
    assert.deepEqual(P.profileEnv(byId("own-proxied"), "codex"), { HTTPS_PROXY: "http://127.0.0.1:7890", no_proxy: "corp.example", All_Proxy: "socks5://h:1", KEEP: "1", MY_HTTP_PROXY: "y" }, "its own proxy kept");
    assert.deepEqual(P.profileEnv(byId("borrowed-proxied"), "codex"), { KEEP: "1", MY_HTTP_PROXY: "y" }, "the host's machine's proxy left there");
    await same("apiSource", PROFILES.map((p) => [P.profileVia(p)]), (via) => P.apiSource(via) ?? null);
    const kinds = ["subscription", "opencode-go", "anthropic-api", "env", "api-provider"];
    const vias = [{}, { provider: "xai" }, { provider: "google" }, { provider: "openrouter" }, { provider: "opencode" }, { provider: "deepseek" }, { provider: "custom", endpoint: "https://c.test/v1" }, { provider: "custom", endpoint: "https://c.test/v1", protocol: "responses" }];
    const envCases: unknown[][] = [];
    const overrides: unknown[][] = [];
    for (const kind of kinds) for (const via of vias) {
      for (const model of [undefined, "m"]) overrides.push([kind, model, via]);
      for (const r of runtimes) envCases.push([r, kind, "key", undefined, via], [r, kind, "", "m", via]);
    }
    await same("accessEnv", envCases, P.accessEnv);
    await same("codexOverrides", overrides, P.codexOverrides);
    await same("expandRoute", [[{ A: "x-{route}-{route}", B: "y" }, "r1"], [{}, "r"]], P.expandRoute);
    await same("runtimeKind", [["dsh"], ["x"], [3], [null]], (v) => runtimeKind(v) ?? null);
    await same("runtimeLabel", ["claude", "codex", "dsh", "grok", "cursor", "hermes", "agy", "pi", "devin"].map((r) => [r]), runtimeLabel);
  });
});

// ── Sandboxes, the keychain, machine logins, the hooks ───────────────────────────────────────────────────────────

describe("sandbox.ts, sandbox-name.ts, no-keychain.ts, machine-logins.ts, repo-rules.ts", { skip }, () => {
  test("config.json's sandboxes taken, refused and described; a job's command there", async () => {
    const good = [{ name: "big", target: "{name}.WS@l4es.test" }, { name: "Gpu.1_x-y", target: "pre-{name}-post.ws@h", size: "gpu-l4", identity: "/keys/id" }];
    const raws = [
      undefined, null, {}, { sandboxes: "x" }, { sandboxes: [] }, { sandboxes: good },
      { sandboxes: [...good, { name: "BIG", target: "{name}@h" }] },
      { sandboxes: [null] }, { sandboxes: [{ name: "-x", target: "{name}@h" }] }, { sandboxes: [{ name: "a".repeat(64), target: "{name}@h" }] },
      { sandboxes: [{ name: "a", target: "nameless@h" }] }, { sandboxes: [{ name: "a", target: "{name}@h@i" }] }, { sandboxes: [{ name: "a", target: "{name}@" }] }, { sandboxes: [{ name: "a", target: "{name} x@h" }] },
      { sandboxes: [{ name: "a", target: "{name}@h", size: "Big" }] }, { sandboxes: [{ name: "a", target: "{name}@h", size: null }] }, { sandboxes: [{ name: "a", target: "{name}@h", identity: "rel/key" }] },
    ];
    await same("sandboxesOf", raws.map((r) => [r]), sandbox.sandboxesOf);
    await same("checkSandboxes", raws.map((r) => [r]), (r) => { try { sandbox.checkSandboxes(r); return null; } catch (e) { return (e as Error).message; } });
    await same("sandboxDescribed", good.map((g) => [g]), sandbox.sandboxDescribed);
    await same("identityOf", [["/data"]], sandbox.identityOf);
    await same("sandboxOf", good.map((g) => [g, "chat:c-1 ü"]), sandbox.sandboxOf);
    const keys = ["chat:c-1", "CHAT/1.2", "", "---", "K İ ß 😀", "x".repeat(40)];
    await same("sandboxName", keys.map((k) => [k]), sandboxName);
    await same("keyPart", keys.map((k) => [k]), keyPart);
    const commands: unknown[][] = [];
    for (const d of good) for (const back of [[], ["out", "dist/x.tar"]]) commands.push(["/data dir", d, { sandbox: d.name, session: "chat:c-9", back }, "make 'all' && echo \"ok\"", "/work/it's", [8080, 9000], "/data/lost", "/usr/bin/node", sandbox.BRIDGE]);
    await same("sandboxCommand", commands, (data, d, place, command, cwd, ports, lost, node) => sandbox.sandboxCommand(data, d, place, command, cwd, ports, lost, node));
  });

  test("Claude Code kept off the keychain; a machine's own login read and its token taken or refused", async () => {
    await same("keychainItem", [["/homes/a"], ["/h/ü 😀"]], keychain.keychainItem);
    await same("claudeCredentialsFile", [[{ HOME: "/u" }, false], [{}, false]], (env) => logins.claudeCredentialsFile(env));
    await same("codexHome", [[{ HOME: "/u" }, false], [{ HOME: "/u", CODEX_HOME: "/c" }, false], [{ CODEX_HOME: "" }, false]], (env) => logins.codexHome(env));
    await same("codexAuthFile", [[{ HOME: "/u" }, false]], (env) => logins.codexAuthFile(env));
    const creds = [
      JSON.stringify({ claudeAiOauth: { accessToken: "t1", expiresAt: 1794883188902, subscriptionType: "max", rateLimitTier: "x" } }),
      JSON.stringify({ claudeAiOauth: { accessToken: "t2" } }), JSON.stringify({ claudeAiOauth: { accessToken: "" } }), JSON.stringify({ claudeAiOauth: { accessToken: 3 } }),
      JSON.stringify({ claudeAiOauth: { accessToken: "t", expiresAt: "1", subscriptionType: 2 } }), "not json", "null", "[]",
    ];
    await same("parseClaudeCredentials", creds.map((c) => [c]), (c) => logins.parseClaudeCredentials(c) ?? null);
    // What the station would give from a login of each kind, at a time a token runs out after and before its margin.
    const now = 1_794_883_188_902;
    const tokens = [{ accessToken: "t", expiresAt: 0 }, { accessToken: "t", expiresAt: now + logins.CLAUDE_TOKEN_MARGIN_MS + 1 }, { accessToken: "t", expiresAt: now + logins.CLAUDE_TOKEN_MARGIN_MS }, null];
    const home = fresh("login");
    for (const oauth of tokens) {
      mkdirSync(join(home, ".claude"), { recursive: true });
      rmSync(join(home, ".claude", ".credentials.json"), { force: true });
      if (oauth !== null) writeFileSync(join(home, ".claude", ".credentials.json"), JSON.stringify({ claudeAiOauth: oauth }));
      const restore = mock.method(wall, "now", () => now);
      // (the keychain is this Mac's own: only the file is read here, as on a machine without one)
      const ts = platform.hasKeychain ? null : await logins.machineClaudeToken({ HOME: home }).then((t) => ({ ok: plain(t) }), (e) => ({ error: e.message }));
      restore.mock.restore();
      const said = await call("machineClaudeToken", oauth, now);
      if (ts !== null) assert.deepStrictEqual(said, ts);
      // (read off the station's thread too: the file, where there is no keychain)
      assert.deepStrictEqual((await io("machineClaudeToken", { HOME: home }, false, now)).ok, said);
      assert.deepStrictEqual(said, oauth === null ? { error: "the machine's Claude Code login could not be read" } : oauth.expiresAt !== 0 && oauth.expiresAt - now <= logins.CLAUDE_TOKEN_MARGIN_MS ? { error: "the machine's Claude Code token runs out and is not renewed here" } : { ok: plain(logins.parseClaudeCredentials(JSON.stringify({ claudeAiOauth: oauth }))) });
    }
    // security's ends as readClaudeKeychain takes them, and which store is read then.
    assert.deepStrictEqual(await call("keychainRead", { code: 0, out: "x" }), { kind: "found", text: "x" });
    assert.deepStrictEqual(await call("keychainRead", { code: 44, out: "" }), { kind: "missing" });
    assert.deepStrictEqual(await call("keychainRead", { code: 51, out: "" }), { kind: "unreadable" });
    assert.deepStrictEqual(await call("keychainRead", null), { kind: "unreadable" });
    assert.deepStrictEqual(await call("claudeCredentialsOf", true, { kind: "unreadable" }, creds[0]), null);
    assert.deepStrictEqual(await call("claudeCredentialsOf", true, { kind: "missing" }, creds[0]), plain(logins.parseClaudeCredentials(creds[0]!)));
    assert.deepStrictEqual(await call("claudeCredentialsOf", true, { kind: "found", text: creds[1] }, creds[0]), plain(logins.parseClaudeCredentials(creds[1]!)));
    assert.deepStrictEqual(await call("claudeCredentialsOf", false, { kind: "unreadable" }, creds[0]), plain(logins.parseClaudeCredentials(creds[0]!)));
    // What of the keychain is moved back into a profile's file: a login only.
    assert.deepStrictEqual(await call("loginOfKeychain", true, ` ${creds[0]}\n`), creds[0]);
    assert.deepStrictEqual(await call("loginOfKeychain", true, "{\"other\":1}"), null);
    assert.deepStrictEqual(await call("loginOfKeychain", false, creds[0]), null);
    // The stand-in first on PATH, where the platform has a keychain.
    const env: Record<string, string> = { PATH: "/usr/bin:/bin" };
    await keychain.fileCredentialsSoon(env);
    const dir = join(tmpdir(), `stillfail-no-keychain-${process.getuid?.() ?? 0}`);
    assert.deepStrictEqual(await call("credentialsPath", { PATH: "/usr/bin:/bin" }, platform.hasKeychain, dir, process.env.PATH), env);
    assert.deepStrictEqual(await call("credentialsPath", {}, true, dir, "/p"), { PATH: `${dir}:/p` });
    assert.equal(await call("stubDir", tmpdir(), process.getuid?.() ?? 0), dir);
  });

  test("a hook's command, as each runtime runs it", async () => {
    const file = "/app/station/repo-rules-hook.mjs";
    for (const has of [[], ["/app/node/bin/node"], ["/app/node/node.exe"], ["/app/node/bin/node", "/app/node/node.exe"]]) {
      const node = rules.hookNode(file, (p) => has.includes(p));
      assert.equal(await call("hookNode", file, has, process.execPath), node);
      for (const args of [[], ["--x", "it's"]]) assert.equal(await call("hookCommand", rules.hookNode(file), file, args), rules.hookCommand(file, ...args));
      for (const os of ["windows", "macos", "linux"]) assert.equal(await call("agyHookCommand", rules.hookNode(file), "/a \"b\"/hook.mjs", os), rules.agyHookCommand("/a \"b\"/hook.mjs", os));
    }
    // A release with no Node: the station's own program beside the hook runs it (a release with Node keeps its Node).
    for (const [has, node] of [
      [["/app/station/stillfail-reader"], "/app/station/stillfail-reader"],
      [["/app/station/stillfail-reader.exe"], "/app/station/stillfail-reader.exe"],
      [["/app/node/bin/node", "/app/station/stillfail-reader"], "/app/node/bin/node"],
      [["/elsewhere/station/stillfail-reader"], process.execPath],
    ] as const) assert.equal(await call("hookNode", file, has, process.execPath), node, `hookNode with ${has.join(", ")}`);
    assert.equal(await call("hookCommand", rules.hookNode(rules.REPO_RULES_HOOK), rules.REPO_RULES_HOOK, []), rules.REPO_RULES_COMMAND);
    await same("peerHttpBase", [["http://127.0.0.1:1/mcp"], ["http://x/mcp/y"], ["http://x/mcpx"]], (u) => u.replace(/\/mcp$/, "/peer"));
  });
});

// ── What each driver makes of its profile ────────────────────────────────────────────────────────────────────────

const ROUTES = [null, { kind: "deepseek" }, { kind: "pi", name: "OpenCode Go", api: "openai-completions", baseURL: "https://opencode.ai/zen/go/v1", headers: { "x-opencode-session": "stillfail-{route}" } }, { kind: "pi", name: "Anthropic", api: "anthropic-messages", baseURL: "https://api.anthropic.com" }, { kind: "pi", name: "OpenAI", api: "openai-responses", baseURL: "https://API.openai.com:443/v1" }, { kind: "pi", name: "X", api: "openai-completions", baseURL: "not a url" }];
const MODELS = [undefined, "claude-opus-5-5", "deepseek-v4-flash", "gpt-6", "unknown-model-x", "kimi-k2.6"];
const factsOf = (model: string | undefined) => (model === undefined ? null : { context: facts(model)?.context, output: facts(model)?.output, seesImages: seesImages(model) });

describe("each driver's setup, its failures told apart and its catalog", { skip }, () => {
  test("dsh: its patch and the route its agent asks for", async () => {
    const cases: unknown[][] = [];
    for (const route of ROUTES) for (const model of MODELS) for (const effort of [undefined, "low", "medium", "high", "max", "xhigh", "nope"]) cases.push([route, model, effort, "be {{good}} {{", "/h", "r-1", "http://127.0.0.1:9/mcp", dsh.BRIDGE, factsOf(model)]);
    await same("dshSetup", cases, (route, model, effort, instr, home, sr, url, bridge) => outcome(() => dsh.dshSetup(route, model, effort, instr, home, sr, url, bridge)));
    for (const route of ROUTES) {
      const setup = dsh.dshSetup(route as any, "claude-opus-5-5", "high", "x", "/h", "r", "u", dsh.BRIDGE);
      assert.equal(await call("patchText", setup.patch), dsh.patchText(setup.patch));
    }
    for (const [code, text] of [["AUTH", "x"], ["", "insufficient balance"], ["RATE_LIMIT", "429"], ["", "context overflow"], ["x", "y"]]) assert.equal(await call("dshClassifyFailure", code, text), dsh.classifyFailure(code!, text!));
    for (const reason of [{ kind: "aborted" }, { kind: "error", error: { code: "AUTH", message: "bad key" } }, { kind: "error", error: { x: 1 } }, { kind: "error" }, { kind: "done" }, null]) assert.deepStrictEqual(await call("dshOutcomeOf", reason), plain(dsh.outcomeOf(reason)));
  });

  test("Pi: its provider, arguments and setup", async () => {
    const cases: unknown[][] = [];
    const piRoutes = ROUTES.filter((r) => r === null || r.kind === "pi").map((r) => (r === null ? null : { name: (r as any).name, api: (r as any).api, baseURL: (r as any).baseURL, ...((r as any).headers ? { headers: (r as any).headers } : {}) }));
    for (const route of piRoutes) for (const model of MODELS) for (const effort of [undefined, "minimal", "max", "nope"]) for (const skills of [undefined, "/ws/skills"]) for (const instructions of [null, "/h/pi/stillfail/x.md"]) {
      const options = { key: "k", profile: { id: "p", runtime: "pi", home: "/h" }, cwd: "/w", instructions: "", mcpToken: "t", mcpUrl: "http://127.0.0.1:9/mcp", route: "r-2", effort, skills };
      cases.push([route, model, options, "/h/pi/sessions/s.jsonl", instructions, pi.BRIDGE, factsOf(model)]);
      if (route !== null && model !== undefined) assert.deepStrictEqual(await call("piProvider", route, model, effort, "r-2", factsOf(model)), plain(pi.piProvider(route as any, model, effort, "r-2")));
    }
    await same("piSetup", cases, (route, model, options, file, instructions, bridge) => outcome(() => pi.piSetup(route, model, options, file, instructions, bridge)));
    assert.equal(await call("piSessionFile", "/h", "id-1"), pi.sessionFile("/h", "id-1"));
  });

  test("Devin: its models and levels, Fusion's pairings, a call's counts, its arguments and environment", async () => {
    const ids = ["swe-2", "fusion-claude-opus-5-5-high-sidekick-swe-2-medium", "FUSION-claude-opus-5-5-sidekick-swe-2", "fusion--sidekick-x", "fusion-a-sidekick-", "fusion-high-sidekick-x", "fusion-x-max-sidekick-y-low", " fusion-a-sidekick-b "];
    await same("splitDevinFusion", ids.map((i) => [i]), (i) => devin.splitDevinFusion(i));
    await same("devinFusionBase", ids.map((i) => [i]), devin.devinFusionBase);
    await same("variant", ids.flatMap((i) => [undefined, "low", "xhigh", "bogus"].map((e) => [i, e])), devin.variant);
    const listed = {
      families: [
        { slug: "swe-2", variants: [{ model_uid: "swe-2-high" }, { model_uid: "swe-2-medium" }, { model_uid: "swe-2-max" }, { model_uid: "swe-2-medium-lightning" }] },
        { slug: "claude", variants: [{ model_uid: "claude-opus-5-5-medium" }, { model_uid: "claude-opus-5-5-low" }, { model_uid: "claude-opus-5-5-high-fast" }, { model_uid: "claude-opus-4-6-thinking" }] },
        { slug: "kimi", variants: [{ model_uid: "kimi-k2-6" }] },
        { slug: "glm", variants: [{ model_uid: "glm-5-2" }, { model_uid: "glm-5-2-max" }, { model_uid: "glm-5-2-1m" }] },
        { slug: "fusion", variants: [{ model_uid: "fusion-claude-opus-5-5-high-sidekick-swe-2-medium" }, { model_uid: "fusion-claude-opus-5-5-low-sidekick-swe-2-medium" }, { model_uid: "fusion-gpt-6-sidekick-swe-2-medium" }, { model_uid: "fusion-gpt-6-fast-sidekick-x" }, { model_uid: "x-sidekick-y" }, { model_uid: "fusion-gpt-6-sidekick-kimi" }] },
        { slug: "again", variants: [{ model_uid: "swe-2-low" }] },
        { slug: "none", variants: [{ model_uid: "" }, { model_uid: 3 }, {}] },
      ],
    };
    await same("devinCatalog", [[listed], [{}], [null], [{ families: "x" }]], devin.devinCatalog);
    const fusion = devin.devinCatalog(listed).fusion;
    await same("expandDevinFusion", [[fusion], [null], [{ leads: { "a-high": [0, 1, 5], b: [1] }, sides: ["s1", "", "s3"] }]], (f) => devin.expandDevinFusion(f ?? undefined));
    await same("callOf", [[{ _meta: { "cognition.ai/inputTokens": 100, "cognition.ai/cachedReadTokens": 30, "cognition.ai/outputTokens": 7 } }], [{ _meta: { "cognition.ai/inputTokens": 10, "cognition.ai/cachedReadTokens": 30 } }], [{}], [null]], devin.callOf);
    await same("devinArgs", [["/c.json", undefined, undefined], ["/c.json", "swe-2", "high"], ["/c.json", "fusion-a-sidekick-b", undefined]], devin.devinArgs);
    await same("devinRules", [[""], ["x"]], devin.devinRules);
    for (const [text] of [["bad key"], ["401 unauthorized"], ["rate limit"], ["context window"]]) {
      assert.equal(await call("devinClassifyFailure", text), devin.classifyFailure(text!));
      assert.deepStrictEqual(await call("devinOutcomeOf", { error: { message: `Internal error: ${text}`, data: { details: "d" } } }), plain(devin.outcomeOf({ error: { message: `Internal error: ${text}`, data: { details: "d" } } })));
    }
    for (const answer of [{ result: { stopReason: "end_turn" } }, { result: { stopReason: "cancelled" } }, { result: { stopReason: "refusal" } }, { error: { code: 1 } }, { error: { message: "m", data: "why" } }]) {
      assert.deepStrictEqual(await call("devinOutcomeOf", answer), plain(devin.outcomeOf(answer)));
      assert.deepStrictEqual(await call("hermesOutcomeOf", answer), plain(hermes.outcomeOf(answer)));
      assert.deepStrictEqual(await call("errorText", answer.error ?? { message: 3 }), acp.errorText(answer.error ?? { message: 3 }));
    }
  });

  test("Grok Build: its effort, a turn's usage line, its rules and arguments; Cursor's failures", async () => {
    await same("grokEffort", ["low", "medium", "high", "xhigh", "max", "minimal", undefined].map((e) => [e]), (e) => grok.grokEffort(e) ?? null);
    const answers = [
      { result: { _meta: { promptId: "p1", modelId: "grok-5", totalTokens: 900, usage: { inputTokens: 1000, cachedReadTokens: 200, cacheCreationTokens: 50, outputTokens: 30, modelCalls: 3 } } } },
      { result: { _meta: { requestId: "r1", usage: { inputTokens: 10, cachedReadTokens: 200 } } } },
      { result: { _meta: { usage: { inputTokens: 1 } } } }, { result: { _meta: { promptId: "p", usage: null } } }, { result: {} }, null,
    ];
    await same("usageLine", answers.flatMap((a) => [[a, 1794883188902, null], [a, 1, 262144]]), grok.usageLine);
    await same("grokRules", [[""], ["be good"]], grok.grokRules);
    await same("grokArgs", [[undefined, undefined], ["grok-5", "high"], ["grok-5", "minimal"]], grok.grokArgs);
    for (const text of ["access token expired", "subscription required", "429", "x"]) assert.equal(await call("grokClassifyFailure", text), grok.classifyFailure(text));
    for (const [code, text] of [["", "unauthorized"], ["resource_exhausted", "x"], ["", "fetch failed"]]) assert.equal(await call("cursorClassifyFailure", code, text), cursor.classifyFailure(code!, text!));
    for (const end of [{ status: "finished" }, { status: "cancelled" }, { status: "error", error: { code: "x", message: "401" } }, { status: 3 }, {}, null]) assert.deepStrictEqual(await call("cursorOutcomeOf", end), plain(cursor.outcomeOf(end)));
    await same("cursorRule", [["x"], [""]], (i) => `---\ndescription: still.fail station\nalwaysApply: true\n---\n${i}\n`);
  });

  test("Hermes: its catalog bounded, its home chosen, its version", async () => {
    const many = Array.from({ length: 80 }, (_, i) => ({ modelId: `m${i}` }));
    const catalogs = [{ availableModels: [...many, { modelId: " " }, { modelId: 3 }, {}], currentModelId: "m70" }, { availableModels: [{ modelId: "a" }], currentModelId: "z" }, null, {}];
    const profiles = [{ id: "p", runtime: "hermes", home: "/h" }, { id: "p", runtime: "hermes", home: "/h", model: "m75", models: ["m79", "m1", "nope", 3] }];
    await same("hermesCatalog", catalogs.flatMap((c) => profiles.map((p) => [c, p])), hermes.hermesCatalog);
    for (const version of ["0.21.7", "v0.21.8-rc1", "0.21.6", "0.20.99", "1.0.0", "0.22.0+x", "0.21", "x", ""]) {
      const answer = { result: { agentInfo: { version } } };
      const ts = await (new hermes.HermesDriver({ data: fresh("hv") }) as any).initialized(null, answer).then(() => null, (e: Error) => e.message);
      assert.equal(await call("hermesVersionRefusal", answer), ts, version);
    }
    assert.equal(await call("hermesVersionRefusal", {}), "Hermes Agent 需要 0.21.7 或更新版本；请先更新 Hermes，再重试。");
  });

  test("ACP's own requests", async () => {
    await same("rpc", [["init", "initialize", { a: [1, "x"] }]], acp.rpc);
    await same("mcpServers", [["http://127.0.0.1:1/mcp", "tok"]], acp.mcpServers);
    // The last line of a type since a turn's end, of a kept transcript's whole and of a long one's end.
    const lines = ["{\"type\":\"session\"}", "{\"type\":\"usage\",\"run\":\"r\"}", "garbage", "{\"type\":\"end\"}", "{\"type\":\"usage\",\"run\":\"r2\",\"usage\":{}}", ""];
    const dir = fresh("kept");
    writeFileSync(join(dir, "short.jsonl"), lines.join("\n"));
    writeFileSync(join(dir, "ended.jsonl"), [...lines.slice(0, 5), "{\"type\":\"end\"}"].join("\n"));
    writeFileSync(join(dir, "long.jsonl"), `{"type":"usage","run":"${"z".repeat(1 << 20)}"}\n${lines.join("\n")}`);
    const kept = new acp.KeptTranscript("devin", dir);
    for (const id of ["short", "ended", "long", "none", ""]) for (const type of ["usage", "session", "end", "x"])
      assert.deepStrictEqual(await io("lastOfTurnIn", dir, id, type), { ok: plain(kept.lastOfTurn(id, type)) }, `${id} ${type}`);
    for (const type of ["usage", "session"]) for (const cut of [false, true]) assert.deepStrictEqual(await call("lastOfTurn", lines.join("\n"), cut, type), plain(cut ? (type === "usage" ? { type: "usage", run: "r2", usage: {} } : null) : kept.lastOfTurn("short", type)));
  });
});

// ── Sessions through their turns ─────────────────────────────────────────────────────────────────────────────────

const NOW = 1_794_883_188_902;
const UUIDS = Array.from({ length: 40 }, (_, i) => `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`);
const MCP = "http://127.0.0.1:4100/mcp";

/// The station's runtimes' drivers on a data directory of their own (their program is not started: nothing runs).
function driversOn(data: string) {
  return {
    dsh: new dsh.DshDriver({ data, command: "dsh" }),
    cursor: new cursor.CursorDriver({ data, node: "/usr/bin/node", sdk: "/sdk/cursor" }),
    pi: new pi.PiDriver({ data, command: "pi" }),
    devin: new devin.DevinDriver({ data, command: "devin" }),
    grok: new grok.GrokDriver({ data, command: "grok" }),
    hermes: new hermes.HermesDriver({ data, command: "hermes" }),
  } as Record<string, any>;
}

/// A process as the program reads it, faked: what is written to it, said and told the program, in order.
function fakeProc(rig: { trace: any[]; frozen: any }, runner: string, answer?: (line: string) => void) {
  return {
    info: { id: runner },
    write: (line: string) => {
      rig.trace.push({ write: line });
      answer?.(line);
    },
    say: (name: string, args?: unknown) => rig.trace.push({ say: [name, args ?? null] }),
    tell: (what: string) => rig.trace.push({ tell: what }),
    freeze: () => rig.trace.push({ freeze: true }),
    frozenState: () => rig.frozen,
    kill: async (ms: number) => void rig.trace.push({ kill: ms }),
    detach: () => rig.trace.push({ detach: true }),
    route: () => {},
  };
}

const optionsFor = (kind: string, home: string, more: Partial<OpenOptions> = {}): OpenOptions => ({
  key: `chat:c-${kind}`, profile: { id: `p-${kind}`, runtime: kind as any, home, model: kind === "devin" ? "fusion-claude-opus-5-5-high-sidekick-swe-2-medium" : undefined }, cwd: "/work/repo",
  instructions: "the station's instructions", mcpToken: "tok-1", mcpUrl: MCP, route: "route-1", skills: undefined, ...more,
});

/// Runs `f` with the TypeScript's clock and uuids the case's.
async function withRig<T>(f: () => Promise<T>): Promise<T> {
  const queue = [...UUIDS];
  const now = mock.method(wall, "now", () => NOW);
  const uuid = mock.method(globalThis.crypto, "randomUUID", () => queue.shift() as any);
  try {
    return await f();
  } finally {
    now.mock.restore();
    uuid.mock.restore();
  }
}

/// A session of `c.kind` the TypeScript's way, through `c.steps`: each step's trace.
async function tsSession(c: any, home: string): Promise<any[][]> {
  return withRig(async () => {
    const data = fresh("drivers");
    const driver = driversOn(data)[c.kind];
    const rig = { trace: [] as any[], frozen: null as any };
    driver.forget = () => rig.trace.push({ forget: true });
    const events = (e: unknown) => rig.trace.push({ event: e });
    const options = { ...optionsFor(c.kind, home), ...(c.options ?? {}), profile: { ...optionsFor(c.kind, home).profile, ...(c.options?.profile ?? {}), home } };
    const info = { id: c.runner };
    let session: any;
    if (c.how === "handed") session = driver.handedOver(options, c.snapshot, info, events);
    else if (c.how === "crashed") session = await driver.crashed(options, c.replayed, info, events);
    else if (c.kind === "dsh") session = new dsh.DshSession(driver, c.sessionId, { busy: false, prompted: false, aborting: false, ...(c.turn ?? {}), closed: false }, c.live ?? null, events);
    else if (c.kind === "cursor") session = new cursor.CursorSession(driver, c.sessionId, { busy: false, aborting: false, ...(c.turn ?? {}), closed: false }, c.live ?? null, events, c.model ?? null);
    else if (c.kind === "pi") session = new pi.PiSession(driver, c.sessionId, { busy: false, prompted: false, aborting: false, ...(c.turn ?? {}), closed: false }, c.live ?? null, events);
    else session = driver.session(options, events);
    if (c.how !== "handed" && c.how !== "crashed") session.toolsUrl = c.tools ?? null;
    session.attach(fakeProc(rig, c.runner));
    rig.trace.length = 0;
    const out: any[][] = [];
    const settle = (op: string, p: Promise<unknown>) => p.then((v) => rig.trace.push({ resolved: [op, v ?? null] }), (e) => rig.trace.push({ rejected: [op, e.message] }));
    const flush = async () => {
      for (let i = 0; i < 8; i++) await new Promise((r) => setImmediate(r));
      await session.settled?.();
    };
    for (const step of c.steps) {
      const result = (f: () => unknown) => {
        try {
          rig.trace.push({ result: plain(f()) });
        } catch (e) {
          rig.trace.push({ threw: (e as Error).message });
        }
      };
      switch (step.op) {
        case "heard": await session.heardHosted(step.heard); break;
        case "prompt": settle("prompt", session.prompt(step.text)); break;
        case "steer": settle("steer", session.steer(step.text)); break;
        case "takeover": result(() => session.promptTakeover(step.text)); break;
        case "abort": settle("abort", session.abort()); break;
        case "exited": await session.exited(step.said, step.stderr); break;
        case "snapshot": rig.frozen = step.frozen ?? null; result(() => session.snapshot()); break;
        case "retune": result(() => session.retune({ ...options, ...step.options, profile: { ...options.profile, ...(step.options?.profile ?? {}) } })); break;
        case "attached": session.attached(); break;
        case "named": result(() => session.named(step.id)); break;
        case "opened": session.opened(step.result); break;
        case "began": session.began(step.cwd); break;
        case "dispose": settle("dispose", session.dispose()); break;
        case "detach": session.detach(); break;
        case "busy": result(() => session.busy()); break;
        case "id": result(() => session.id()); break;
        case "models": result(() => session.availableModels); break;
      }
      await flush();
      out.push(plain(rig.trace.splice(0)));
    }
    return out;
  });
}

/// The same session MoonBit's way.
async function mbSession(c: any, home: string): Promise<any[][]> {
  const options = { ...optionsFor(c.kind, home), ...(c.options ?? {}), profile: { ...optionsFor(c.kind, home).profile, ...(c.options?.profile ?? {}), home } };
  const steps = c.steps.map((s: any) => (s.op === "retune" ? { ...s, options: { ...options, ...s.options, profile: { ...options.profile, ...(s.options?.profile ?? {}) } } } : s));
  const said = await mb({ op: "session", ...c, steps, options, uuids: UUIDS, now: NOW, userHome: homedir() });
  return said.steps;
}

/// Both ways, each in a home of its own: the same steps' traces, and the same files kept there.
async function sameSession(c: any) {
  const tsHome = fresh(`ts-${c.kind}`), mbHome = fresh(`mb-${c.kind}`);
  for (const home of [tsHome, mbHome]) for (const dir of c.dirs ?? []) mkdirSync(join(home, dir), { recursive: true });
  for (const home of [tsHome, mbHome]) for (const [file, text] of c.files ?? []) {
    mkdirSync(join(home, file, ".."), { recursive: true });
    writeFileSync(join(home, file), text);
  }
  const ts = await tsSession(c, tsHome);
  const said = JSON.parse(JSON.stringify(await mbSession(c, mbHome)).replaceAll(mbHome, tsHome));
  for (let i = 0; i < ts.length; i++) assert.deepStrictEqual(said[i], ts[i], `${c.name ?? c.kind}: step ${i} (${JSON.stringify(c.steps[i]).slice(0, 200)})`);
  assert.equal(said.length, ts.length);
  const files = (home: string) => tree(home).map(([p, t, m]) => [p, t.replaceAll(mbHome, tsHome), m]);
  assert.deepStrictEqual(files(mbHome), files(tsHome), `${c.name ?? c.kind}: the files kept`);
}

const line = (v: unknown) => ({ text: JSON.stringify(v) });
const T = (busy: boolean, more: Record<string, unknown> = {}) => ({ busy, aborting: false, ...more });

describe("the sessions through their turns: what each writes, says, tells and gives on", { skip }, () => {
  test("DeepSeek Harness", async () => {
    const turn = { busy: true, prompted: false, aborting: false };
    await sameSession({
      kind: "dsh", runner: "dsh-r1", sessionId: "s-1", tools: MCP, live: { open: [], calls: [], phase: null },
      steps: [
        { op: "busy" }, { op: "steer", text: "early" }, { op: "abort" },
        { op: "prompt", text: "hi" }, { op: "busy" }, { op: "prompt", text: "again" },
        { op: "steer", text: "more" },
        { op: "heard", heard: { lines: [line({ id: `steer:${UUIDS[1]}`, ok: true }), { text: "not json" }, line({ id: "x", error: "refused" }), line({ id: "open", session: "late" })], events: [{ type: "turnStarted", turn }, { type: "live", event: { kind: "phase", phase: "requesting" } }], turn, routed: true } },
        { op: "abort" }, { op: "abort" },
        { op: "heard", heard: { events: [{ type: "turnEnded", outcome: { kind: "aborted" }, turn: { busy: false, prompted: false, aborting: false } }, { type: "toolsLost", why: "x" }] } },
        { op: "steer", text: "late" }, { op: "id" },
        { op: "snapshot" }, { op: "prompt", text: "after" }, { op: "detach" },
      ],
    });
    await sameSession({
      kind: "dsh", name: "dsh exits", runner: "dsh-r2", sessionId: "s-2", tools: null,
      steps: [{ op: "prompt", text: "go" }, { op: "heard", heard: { events: [{ type: "turnStarted" }], turn } }, { op: "snapshot", frozen: { turn: { busy: true, prompted: true }, live: { open: [["a", "text"]], calls: [], phase: "working" } } }, { op: "exited", said: "code 1", stderr: "boom" }, { op: "dispose" }],
    });
    await sameSession({ kind: "dsh", name: "dsh handed", how: "handed", runner: "dsh-r3", snapshot: { runtime: "dsh", id: "s-3", runner: "dsh-r3", turn: { busy: true, prompted: false, aborting: true }, tools: MCP, live: { open: [], calls: [], phase: "responding" } }, steps: [{ op: "busy" }, { op: "abort" }, { op: "exited", said: "signal SIGKILL", stderr: "" }, { op: "snapshot" }] });
    for (const replayed of [{ session: "s-4", turn: { busy: true, prompted: false }, live: { open: [], calls: [], phase: null } }, { session: null, turn: null }, {}])
      await sameSession({ kind: "dsh", name: "dsh crashed", how: "crashed", runner: "dsh-r4", replayed, options: { resume: "s-resumed" }, steps: [{ op: "id" }, { op: "busy" }, { op: "snapshot" }] });
  });

  test("Cursor", async () => {
    await sameSession({
      kind: "cursor", runner: "cur-r1", sessionId: "agent-1", tools: MCP, model: "gpt-6[reasoning=high]",
      steps: [
        { op: "retune", options: { model: "claude-opus-5-5" } }, { op: "prompt", text: "hi" },
        { op: "retune", options: { model: "x" } }, { op: "steer", text: "into it" },
        { op: "heard", heard: { lines: [line({ id: `steer:${UUIDS[1]}`, delivered: true })], events: [{ type: "live", event: { kind: "start", id: "t1", step: "text" } }], turn: { busy: true, aborting: false } } },
        { op: "steer", text: "again" },
        { op: "heard", heard: { lines: [line({ id: `steer:${UUIDS[2]}`, error: "the run ended" })], events: [] } },
        { op: "steer", text: "third" }, { op: "heard", heard: { lines: [line({ id: `steer:${UUIDS[3]}`, delivered: "yes" })], events: [] } },
        { op: "abort" }, { op: "steer", text: "while aborting" },
        { op: "heard", heard: { events: [{ type: "turnEnded", outcome: { kind: "aborted" }, turn: { busy: false, aborting: false } }] } },
        { op: "retune", options: { profile: { model: "from-profile" } } }, { op: "snapshot" },
      ],
    });
    await sameSession({ kind: "cursor", name: "cursor unnamed", runner: "cur-r2", sessionId: "", steps: [{ op: "retune", options: { model: "m" } }, { op: "prompt", text: "x" }, { op: "steer", text: "y" }, { op: "exited", said: "code 3", stderr: "" }, { op: "snapshot", frozen: { turn: null, live: null } }] });
    await sameSession({ kind: "cursor", name: "cursor handed", how: "handed", runner: "cur-r3", snapshot: { runtime: "cursor", id: "a-3", runner: "cur-r3", turn: { busy: false, aborting: false }, tools: MCP, live: { open: [], said: null, n: 2, phase: null }, model: "m-3" }, steps: [{ op: "prompt", text: "z" }, { op: "snapshot" }] });
    await sameSession({ kind: "cursor", name: "cursor crashed", how: "crashed", runner: "cur-r4", replayed: { session: "a-4", turn: { busy: true }, live: { open: [] } }, options: { model: "m-4" }, steps: [{ op: "steer", text: "s" }, { op: "heard", heard: { lines: [line({ id: `steer:${UUIDS[0]}`, delivered: true })], events: [] } }, { op: "snapshot" }] });
  });

  test("Pi", async () => {
    const turn = { busy: true, prompted: false, aborting: false };
    await sameSession({
      kind: "pi", runner: "pi-r1", sessionId: "pi-s1", tools: MCP,
      steps: [
        { op: "prompt", text: "hi" }, { op: "steer", text: "more" },
        { op: "heard", heard: { lines: [line({ type: "extension_ui_request", id: "d1", method: "select" }), line({ type: "extension_ui_request", id: "d2", method: "notify" }), line({ type: "extension_ui_request", id: 7, method: "confirm" }), line({ type: "response", id: "x", success: false, error: "no" }), line({ type: "response", id: "y", success: true })], events: [{ type: "turnStarted", turn }], turn } },
        { op: "abort" },
        { op: "heard", heard: { events: [{ type: "turnEnded", outcome: { kind: "aborted" }, turn: { busy: false, prompted: false, aborting: false, error: "stopped" } }], turn: { busy: false, prompted: false, aborting: false, error: "stopped" } } },
        { op: "snapshot" },
      ],
    });
    await sameSession({ kind: "pi", name: "pi handed", how: "handed", runner: "pi-r2", snapshot: { runtime: "pi", id: "pi-s2", runner: "pi-r2", turn: { prompted: true }, tools: MCP, live: { open: [] } }, steps: [{ op: "busy" }, { op: "steer", text: "s" }, { op: "exited", said: "code 0", stderr: "" }] });
    await sameSession({ kind: "pi", name: "pi crashed", how: "crashed", runner: "pi-r3", replayed: { session: "ignored", turn: { busy: true, error: 3 }, live: { a: 1 } }, options: { resume: "pi-resumed" }, steps: [{ op: "id" }, { op: "snapshot" }] });
  });

  test("Devin: its transcript kept, its calls counted once, a message into the turn, another model between turns", async () => {
    const opened = { configOptions: [{ id: "mode", currentValue: "default" }, { id: "model", currentValue: "swe-2-high", options: [{ value: "swe-2-high" }, { value: "swe-2" }, { value: 3 }, { value: "fusion-claude-opus-5-5-high-sidekick-swe-2-medium" }] }] };
    const usage = (input: number, out: number) => ({ sessionUpdate: "usage_update", used: input * 2, size: 200000, _meta: { "cognition.ai/inputTokens": input, "cognition.ai/cachedReadTokens": 10, "cognition.ai/outputTokens": out } });
    const busy = T(true, { owner: `prompt:${UUIDS[0]}`, steering: [] });
    await sameSession({
      kind: "devin", runner: "dv-r1", dirs: ["devin/sessions"],
      steps: [
        { op: "named", id: "dv-1" }, { op: "began", cwd: "/work/repo" }, { op: "opened", result: opened }, { op: "attached" },
        { op: "prompt", text: "hi" },
        { op: "heard", heard: { lines: [line({ jsonrpc: "2.0", id: 9, method: "session/request_permission", params: { options: [{ kind: "allow_always", optionId: "a" }, { kind: "allow_once", optionId: "o" }] } }), line({ jsonrpc: "2.0", id: 10, method: "session/request_permission", params: { options: [] } }), line({ jsonrpc: "2.0", id: "q", method: "_cognition/ask", params: {} }), line({ jsonrpc: "2.0", method: "_note" })], events: [{ type: "turnStarted", turn: busy }, { type: "kept", line: { type: "assistant", text: "hello" } }, { type: "usage", update: usage(100, 5), owner: `prompt:${UUIDS[0]}` }, { type: "usage", update: usage(100, 5), owner: `prompt:${UUIDS[0]}` }, { type: "usage", update: usage(150, 9), owner: `prompt:${UUIDS[0]}` }, { type: "usage", update: { sessionUpdate: "other" } }], turn: busy } },
        { op: "steer", text: "into the turn" }, { op: "takeover", text: "take it" },
        { op: "retune", options: { model: "swe-2" } },
        { op: "heard", heard: { events: [{ type: "answered", id: `steer:${UUIDS[1]}`, answer: { result: { stopReason: "end_turn" } } }, { type: "answered", id: `steer:${UUIDS[2]}`, outcome: { kind: "completed" }, answer: { result: { stopReason: "end_turn" } } }, { type: "kept", line: { type: "end", status: "finished" } }, { type: "turnEnded", outcome: { kind: "completed" }, turn: T(false, { owner: null, steering: [] }) }] } },
        { op: "retune", options: { model: "swe-2", effort: "max" } }, { op: "retune", options: { model: "fusion-claude-opus-5-5-low-sidekick-swe-2-medium" } }, { op: "retune", options: { model: "unknown" } },
        { op: "prompt", text: "second" },
        { op: "heard", heard: { events: [{ type: "usage", update: usage(5, 1), owner: null }], turn: T(true, { owner: `prompt:${UUIDS[6]}` }) } },
        { op: "abort" }, { op: "steer", text: "no" },
        { op: "snapshot", frozen: { turn: T(true, { aborting: true, owner: "o", steering: ["s"] }), live: { live: { open: ["x"], said: "t", n: 3, phase: "working" }, said: { type: "assistant", text: "partial" }, calls: [["c1", { name: "mcp__stillfail__chat_post", input: {} }]], saidLast: "partial", children: [] } } },
        { op: "exited", said: "code 1", stderr: "" },
      ],
    });
    await sameSession({
      kind: "devin", name: "devin exits in a turn", runner: "dv-r2", dirs: ["devin/sessions"],
      steps: [{ op: "named", id: "dv-2" }, { op: "prompt", text: "x" }, { op: "heard", heard: { events: [{ type: "usage", update: usage(10, 1), owner: `prompt:${UUIDS[0]}` }], turn: T(true) } }, { op: "exited", said: "signal SIGTERM", stderr: "gone" }, { op: "prompt", text: "y" }],
    });
    const handed = { runtime: "devin", id: "dv-3", runner: "dv-r3", turn: { busy: true, aborting: false }, tools: MCP, live: { open: [], said: null, n: 0, phase: null }, model: "swe-2", owner: `prompt:${UUIDS[5]}`, steering: [], families: ["swe-2-high", 4], usage: { run: "run-1", calls: 2, lastCall: JSON.stringify(devin.callOf(usage(100, 5))), context: 10, window: 20 } };
    await sameSession({ kind: "devin", name: "devin handed", how: "handed", runner: "dv-r3", snapshot: handed, steps: [{ op: "heard", heard: { events: [{ type: "usage", update: usage(100, 5), owner: `prompt:${UUIDS[5]}` }, { type: "usage", update: usage(7, 7), owner: `prompt:${UUIDS[5]}` }] } }, { op: "snapshot" }] });
    await sameSession({ kind: "devin", name: "devin handed bare", how: "handed", runner: "dv-r3", snapshot: { id: "dv-4", turn: { busy: false }, live: null, usage: { run: 3 } }, steps: [{ op: "snapshot" }] });
    // After a crash: the usage its transcript has already is not counted again; the next call goes on from it.
    const kept = [{ type: "session", id: "dv-5" }, { type: "usage", run: "old", usage: {} }, { type: "end", status: "finished" }, { type: "usage", run: "run-5:2", model: "swe-2", usage: devin.callOf(usage(100, 5)), calls: 1, context: 200, window: 200000 }].map((l) => JSON.stringify(l)).join("\n");
    for (const replayed of [
      { session: "dv-5", turn: { busy: true }, live: { live: { open: [], said: null, n: 0, phase: null } }, opened, usages: [usage(100, 5)] },
      { session: "dv-5", turn: { busy: false }, live: null, opened: null },
      { session: "", turn: { busy: true } },
    ])
      await sameSession({
        kind: "devin", name: "devin crashed", how: "crashed", runner: "dv-r5", replayed, options: { resume: "dv-5", model: "swe-2" }, files: [["devin/sessions/dv-5.jsonl", `${kept}\n`]],
        steps: [{ op: "id" }, { op: "busy" }, { op: "heard", heard: { events: [{ type: "usage", update: usage(100, 5), owner: null }, { type: "usage", update: usage(300, 5), owner: null }] } }, { op: "snapshot" }],
      });
  });

  test("Grok Build: a message interjected into its turn, a turn's usage kept beside its transcript, another model", async () => {
    const answer = { result: { stopReason: "end_turn", _meta: { promptId: "p1", modelId: "grok-5", totalTokens: 900, usage: { inputTokens: 1000, cachedReadTokens: 200, cacheCreationTokens: 50, outputTokens: 30, modelCalls: 3 } } } };
    await sameSession({
      kind: "grok", runner: "gk-r1", dirs: ["grok/sessions/-work-repo/gk-1"], options: { model: "grok-4" },
      steps: [
        { op: "named", id: "gk-1" }, { op: "opened", result: { models: { currentModelId: "grok-5", availableModels: [{ modelId: "grok-5", _meta: { totalContextTokens: 262144 } }, { modelId: "grok-4", _meta: {} }] } } },
        { op: "steer", text: "idle" }, { op: "prompt", text: "hi" }, { op: "steer", text: "into it" },
        { op: "heard", heard: { lines: [line({ jsonrpc: "2.0", id: `steer:${UUIDS[1]}`, result: { status: "queued" } })], events: [] } },
        { op: "steer", text: "refused" },
        { op: "heard", heard: { lines: [line({ jsonrpc: "2.0", id: `steer:${UUIDS[2]}`, error: { message: "Internal error: busy", data: "x" } })], events: [] } },
        { op: "steer", text: "empty" }, { op: "heard", heard: { lines: [line({ jsonrpc: "2.0", id: `steer:${UUIDS[3]}`, result: {} })], events: [] } },
        { op: "heard", heard: { events: [{ type: "answered", id: `prompt:${UUIDS[0]}`, outcome: { kind: "completed" }, answer }, { type: "turnEnded", outcome: { kind: "completed" }, turn: T(false) }] } },
        { op: "retune", options: { model: "grok-5", effort: "high" } }, { op: "retune", options: { model: undefined, effort: "minimal", profile: {} } },
        { op: "prompt", text: "two" },
        { op: "heard", heard: { events: [{ type: "answered", id: "x", outcome: { kind: "completed" }, answer: { result: { _meta: { requestId: "r2", usage: { inputTokens: 3 } } } } }, { type: "answered", id: "y", answer: {} }, { type: "turnEnded", outcome: { kind: "completed" }, turn: T(false) }] } },
        { op: "snapshot" },
      ],
    });
  });

  test("Hermes Agent: its instructions with each prompt, its home said as its session begins, its models", async () => {
    await sameSession({
      kind: "hermes", runner: "hm-r1", dirs: ["hermes/sessions"], options: { model: "gpt-6", profile: { env: { HERMES_HOME: "~/hermes-x" }, models: ["m2"] } },
      steps: [
        { op: "named", id: "bad id!" }, { op: "named", id: "hm_1-x" }, { op: "began", cwd: "/work/repo" },
        { op: "opened", result: { models: { currentModelId: "m1", availableModels: [{ modelId: "m1" }, { modelId: "m2" }, { modelId: "m3" }] } } }, { op: "models" },
        { op: "prompt", text: "hi" }, { op: "steer", text: "waits" }, { op: "takeover", text: "takes" },
        { op: "heard", heard: { events: [{ type: "kept", line: { type: "thinking", text: "hm" } }, { type: "answered", id: `prompt:${UUIDS[0]}`, outcome: { kind: "failed" }, answer: { error: { message: "429" } } }, { type: "turnEnded", outcome: { kind: "failed", reason: "rate_limit", message: "429" }, turn: T(false) }, { type: "closed", why: "after" }] } },
        { op: "prompt", text: "two" }, { op: "exited", said: "code 2", stderr: "" }, { op: "snapshot" },
      ],
    });
    await sameSession({ kind: "hermes", name: "hermes no instructions", runner: "hm-r2", options: { instructions: "" }, steps: [{ op: "named", id: "hm-2" }, { op: "prompt", text: "plain" }] });
  });
});

/// What an ACP runtime answers each of the station's requests with, by its method.
const acpReplies: Record<string, unknown> = {
  initialize: { result: { protocolVersion: 1, agentInfo: { version: "0.22.1" } } },
  authenticate: { result: {} },
  "session/new": { result: { sessionId: "new-1", models: { currentModelId: "m1", availableModels: [{ modelId: "m1", _meta: { totalContextTokens: 1000 } }, { modelId: "m2" }] }, configOptions: [{ id: "model", currentValue: "swe-2-high", options: [{ value: "swe-2-high" }] }] } },
  "session/load": { result: { models: { currentModelId: "m2" } } },
  "session/set_config_option": { result: {} },
  "session/set_model": { result: {} },
};

// ── A session opened on its process ──────────────────────────────────────────────────────────────────────────────

/// The TypeScript's driver opening a session: its process a fake (what it was started with taken, each request
/// answered from `answers` by its method, Pi's `type` or the bridge's `op`).
async function tsOpen(c: any, home: string, data: string) {
  return withRig(async () => {
    const driver = driversOn(data)[c.kind];
    if (c.kind === "dsh") driver.bridge = c.bridge;
    if (c.kind === "pi") driver.bridge = c.bridge;
    if (c.kind === "cursor") Object.assign(driver, { bridge: c.bridge, node: c.node, sdk: c.sdk });
    const rig = { trace: [] as any[], frozen: null };
    driver.forget = () => rig.trace.push({ forget: true });
    let started: any = null;
    driver.start = async (session: any, _options: unknown, command: string, args: string[], env: Record<string, string>) => {
      started = { command, args, env, turn: session.turnNow() };
      session.attach(fakeProc(rig, c.runner, (text) => {
        const m = JSON.parse(text);
        const method = m.method ?? m.op ?? m.type;
        const reply = c.answers[method];
        if (m.id === undefined || reply === undefined) return;
        const answer = m.jsonrpc !== undefined ? { jsonrpc: "2.0", id: m.id, ...reply } : { id: m.id, ...reply };
        queueMicrotask(() => void session.heardHosted({ lines: [{ text: JSON.stringify(answer) }], events: [] }));
      }));
    };
    const options = { ...optionsFor(c.kind, home), ...c.options, profile: { ...optionsFor(c.kind, home).profile, ...(c.options?.profile ?? {}), home } };
    try {
      const s = await driver.open(options, (e: unknown) => rig.trace.push({ event: e }));
      return { started, trace: plain(rig.trace), failed: null, id: s.id(), tools: s.mcpUrl(), model: s.model ?? null, models: s.availableModels ?? [] };
    } catch (e) {
      for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r));
      return { started, trace: plain(rig.trace), failed: (e as Error).message };
    }
  });
}

async function sameOpen(c: any) {
  const data = fresh("open-data");
  const tsHome = fresh(`open-ts-${c.kind}`), mbHome = fresh(`open-mb-${c.kind}`);
  for (const home of [tsHome, mbHome]) for (const [file, text] of c.files ?? []) {
    mkdirSync(join(home, file, ".."), { recursive: true });
    writeFileSync(join(home, file), text);
  }
  const ts = await tsOpen(c, tsHome, data);
  const options = { ...optionsFor(c.kind, mbHome), ...c.options, profile: { ...optionsFor(c.kind, mbHome).profile, ...(c.options?.profile ?? {}), home: mbHome } };
  const keychainDir = platform.hasKeychain ? join(tmpdir(), `stillfail-no-keychain-${process.getuid?.() ?? 0}`) : null;
  const said = JSON.parse(JSON.stringify(await mb({
    op: "open", ...c, options, base: startEnv(), data, uuids: UUIDS, now: NOW, userHome: homedir(), keychainDir,
    id: options.resume ?? UUIDS[0], facts: factsOf(options.model ?? options.profile.model), noTools: tr(stationLang(), "station.dsh.noTools"),
  })).replaceAll(mbHome, tsHome));
  const name = c.name ?? c.kind;
  if ("refused" in said) {
    assert.equal(ts.started, null, `${name}: started though MoonBit refused (${said.refused})`);
    assert.equal(said.refused, ts.failed, `${name}: refused`);
  } else {
    assert.ok(ts.started !== null, `${name}: the TypeScript did not start (${ts.failed})`);
    assert.deepStrictEqual({ command: said.start.command, args: said.start.args, env: said.start.env, turn: said.told.turn }, plain(ts.started), `${name}: started with`);
    assert.deepStrictEqual(said.trace, ts.trace, `${name}: what it wrote and said`);
    assert.equal(said.failed, ts.failed, `${name}: failed`);
    if (ts.failed === null) {
      assert.equal(said.id, ts.id, `${name}: its id`);
      assert.equal(said.tools, ts.tools, `${name}: its tools`);
      if (c.kind !== "dsh" && c.kind !== "cursor" && c.kind !== "pi") assert.deepStrictEqual([said.model, said.models], [ts.model, plain(ts.models)], `${name}: its model`);
    }
  }
  const files = (home: string) => tree(home).map(([p, t, m]) => [p, t.replaceAll(mbHome, tsHome), m]);
  assert.deepStrictEqual(files(mbHome), files(tsHome), `${name}: the files written`);
  return ts;
}

describe("a session opened on its process: what it is started with and asked first", { skip }, () => {
  test("how the program reads each runtime's processes", async () => {
    const drivers = driversOn(fresh("hosting"));
    for (const kind of Object.keys(drivers)) assert.deepStrictEqual(await call("hostingOf", kind), plain(drivers[kind].hosting()));
  });

  test("Hermes' models: a session opened only to ask, again while another launch holds its update", async () => {
    const home = fresh("hermes-models");
    const profile = { id: "hp", runtime: "hermes", home, models: ["m2"] };
    const busy = "the update is not done: an update is still running and no dependency environment is committed yet";
    for (const [refusals, final] of [[[], null], [[busy, busy], null], [["bad key"], null], [[busy, busy], "late"]] as const) {
      const said = await withRig(async () => {
        const driver = driversOn(fresh("hm-data")).hermes;
        let at = NOW, tries = 0;
        const asked: any[] = [];
        const now = mock.method(wall, "now", () => at);
        const sleep = mock.method(wall, "sleep", async (ms: number) => void (at += final === "late" ? 200_000 : ms));
        const begin = driver.begin.bind(driver);
        driver.begin = (options: any, events: any, probe: boolean) => (asked.push({ ...options, probe }), begin(options, events, probe));
        const rig = { trace: [] as any[], frozen: null };
        driver.forget = () => {};
        driver.start = async (session: any) => {
          const refused = refusals[tries++];
          session.attach(fakeProc(rig, "hm-m", (text) => {
            const m = JSON.parse(text);
            const reply = m.method === "initialize" && refused !== undefined ? { error: { message: refused } } : acpReplies[m.method];
            if (m.id !== undefined && reply !== undefined) queueMicrotask(() => void session.heardHosted({ lines: [{ text: JSON.stringify({ jsonrpc: "2.0", id: m.id, ...reply }) }], events: [] }));
          }));
        };
        try {
          return { models: await driver.models(profile), asked: plain(asked), tries };
        } catch (e) {
          return { error: (e as Error).message, asked: plain(asked), tries };
        } finally {
          now.mock.restore();
          sleep.mock.restore();
        }
      });
      // What the TypeScript asked each time, MoonBit's probe asks: the same options, and again for the same refusals.
      for (const [i, options] of said.asked.entries()) {
        assert.deepStrictEqual(await call("hermesModelsOptions", profile, UUIDS[i]), { key: options.key, cwd: options.cwd, instructions: options.instructions, mcpToken: options.mcpToken, mcpUrl: options.mcpUrl, route: options.route });
        assert.equal(options.probe, true);
      }
      let tries = 0;
      for (const refused of refusals) {
        tries++;
        if (!(await call("hermesModelsAgain", `hermes initialize: ${refused}`, NOW + (final === "late" ? 200_000 : 2_000) * (tries - 1), NOW + 120_000, false))) break;
      }
      if ("models" in said) tries++;
      assert.equal(tries, said.tries, JSON.stringify(refusals));
      if (final === "late") assert.equal((said as any).error, `hermes initialize: ${busy}`);
      if ("models" in said) {
        const opened = await mb({ op: "open", kind: "hermes", runner: "hm-m", command: "hermes", probe: true, options: { ...said.asked.at(-1), profile }, base: startEnv(), uuids: UUIDS, now: NOW, userHome: homedir(), keychainDir: null, answers: acpReplies });
        assert.deepStrictEqual(opened.models, said.models);
      }
    }
    assert.equal(await call("hermesModelsAgain", busy, NOW, NOW + 1, true), false);
  });
  const was = { ...process.env };
  // Inherited, and not to reach the agents.
  before(() => void Object.assign(process.env, { DEEPSEEK_API_KEY: "leaked", CURSOR_API_KEY: "leaked", PI_SESSION_ID: "leaked", WINDSURF_API_KEY: "leaked", XAI_API_KEY: "leaked", GROK_HOME: "/elsewhere", DSH_TELEMETRY_MODE: "ON", GROK_TELEMETRY_ENABLED: "1", LC_ALL: "C", HERMES_HOME: "/ambient" }));
  after(() => {
    for (const k of Object.keys(process.env)) if (!(k in was)) delete process.env[k];
    Object.assign(process.env, was);
  });

  test("DeepSeek Harness: its patch, environment and opening; refusals", async () => {
    const profiles = [{ access: { kind: "api-provider", provider: "opencode", key: "k" }, model: "claude-opus-5-5" }, { access: { kind: "api-provider", provider: "deepseek", key: "k" } }, { env: { DEEPSEEK_API_KEY: "mine" } }, { access: { kind: "opencode-go", key: "k" } }];
    for (const profile of profiles) for (const effort of [undefined, "high"])
      await sameOpen({ kind: "dsh", name: `dsh ${JSON.stringify(profile)} ${effort}`, runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: { profile, effort }, answers: { open: { session: "dsh-new" } } });
    await sameOpen({ kind: "dsh", name: "dsh no tools", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: {}, answers: { open: { error: "no tools", lacks: "tools" } } });
    await sameOpen({ kind: "dsh", name: "dsh refused", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: {}, answers: { open: { error: "bad" } } });
    await sameOpen({ kind: "dsh", name: "dsh unnamed", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: {}, answers: { open: { session: "" } } });
    await sameOpen({ kind: "dsh", name: "dsh resumed", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: { resume: "old-1" }, files: [["dsh-sessions/-work/old-1/session.v2.jsonl", "{}"]], answers: { open: { session: "old-1" } } });
    await sameOpen({ kind: "dsh", name: "dsh not kept", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: { resume: "gone" }, answers: {} });
    await sameOpen({ kind: "dsh", name: "dsh no model", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", options: { profile: { access: { kind: "api-provider", provider: "groq", key: "k" } } }, answers: {} });
  });

  test("Cursor: its rules' folder, key, environment and opening", async () => {
    const skills = fresh("skills");
    await sameOpen({ kind: "cursor", runner: "cur-o", bridge: cursor.BRIDGE, node: "/usr/bin/node", sdk: "/sdk/cursor", options: { model: "gpt-6", skills }, files: [["cursor/auth.json", JSON.stringify({ apiKey: "ck-1" })], ["cursor/station/x/AGENTS.md", "old"]], answers: { open: { session: "agent-9" } } });
    await sameOpen({ kind: "cursor", name: "cursor own key", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", options: { profile: { env: { CURSOR_API_KEY: "own" } }, skills: "/not/there" }, files: [["cursor/auth.json", JSON.stringify({ apiKey: "ck-1" })]], answers: { open: { session: "agent-9" } } });
    await sameOpen({ kind: "cursor", name: "cursor refused", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", options: {}, answers: { open: { error: "not signed in" } } });
    await sameOpen({ kind: "cursor", name: "cursor unnamed", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", options: {}, answers: { open: {} } });
    await sameOpen({ kind: "cursor", name: "cursor resumed", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", options: { resume: "a-1" }, files: [["cursor/sessions/a-1.jsonl", ""]], answers: { open: { session: "a-1" } } });
    await sameOpen({ kind: "cursor", name: "cursor not kept", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", options: { resume: "a-2" }, answers: {} });
  });

  test("Pi: its arguments, instructions' file, setup and environment", async () => {
    await sameOpen({ kind: "pi", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", options: { profile: { access: { kind: "api-provider", provider: "openrouter", key: "k" }, model: "claude-opus-5-5" }, effort: "high", skills: "/ws/skills" }, answers: { get_state: { type: "response", success: true } } });
    await sameOpen({ kind: "pi", name: "pi own", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", options: { instructions: "", model: "x" }, answers: { get_state: { success: true } } });
    await sameOpen({ kind: "pi", name: "pi refused", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", options: {}, answers: { get_state: { success: false, error: { why: 1 } } } });
    await sameOpen({ kind: "pi", name: "pi resumed", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", options: { resume: "p-1" }, files: [["pi/sessions/p-1.jsonl", ""]], answers: { get_state: { success: true } } });
    await sameOpen({ kind: "pi", name: "pi not kept", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", options: { resume: "p-2" }, answers: {} });
  });

  const acpAnswers = (more: Record<string, unknown> = {}) => ({ ...acpReplies, ...more });
  test("Devin: its configuration, sign-in, instructions' folder and Bypass Permissions", async () => {
    const creds = ["devin/data/devin/credentials.toml", "[auth]\n  windsurf_api_key = \"wk-1\"\nother = 1\n"];
    await sameOpen({ kind: "devin", runner: "dv-o", command: "devin", options: { effort: "max", skills: fresh("dskills") }, files: [creds], answers: acpAnswers() });
    await sameOpen({ kind: "devin", name: "devin no key", runner: "dv-o", command: "devin", options: { profile: { model: undefined } }, answers: acpAnswers() });
    await sameOpen({ kind: "devin", name: "devin sign-in refused", runner: "dv-o", command: "devin", options: {}, files: [creds], answers: acpAnswers({ authenticate: { error: { code: -32000, message: "Internal error: not signed in", data: { message: "expired" } } } }) });
    await sameOpen({ kind: "devin", name: "devin unnamed", runner: "dv-o", command: "devin", options: {}, answers: acpAnswers({ "session/new": { result: {} } }) });
    await sameOpen({ kind: "devin", name: "devin resumed", runner: "dv-o", command: "devin", options: { resume: "dv-9" }, files: [["devin/sessions/dv-9.jsonl", "{}\n"]], answers: acpAnswers() });
    await sameOpen({ kind: "devin", name: "devin not kept", runner: "dv-o", command: "devin", options: { resume: "dv-8" }, answers: acpAnswers() });
  });

  test("Grok Build: its flags, rules and environment", async () => {
    await sameOpen({ kind: "grok", runner: "gk-o", command: "grok", options: { model: "grok-5", effort: "xhigh", profile: { access: { kind: "api-provider", provider: "xai", key: "xk" } } }, answers: acpAnswers() });
    await sameOpen({ kind: "grok", name: "grok resumed", runner: "gk-o", command: "grok", options: { resume: "gk-9", instructions: "" }, files: [["grok/sessions/-w/gk-9/chat_history.jsonl", ""]], answers: acpAnswers() });
    await sameOpen({ kind: "grok", name: "grok not kept", runner: "gk-o", command: "grok", options: { resume: "gk-8" }, answers: acpAnswers() });
    await sameOpen({ kind: "grok", name: "grok refused", runner: "gk-o", command: "grok", options: {}, answers: acpAnswers({ initialize: { error: { message: "nope" } } }) });
  });

  test("Hermes Agent: its home, inherited environment, version and model", async () => {
    const hermesProfile = { env: { HERMES_HOME: "~/.hermes-t", OPENAI_API_KEY: "ok" }, model: "gpt-6", models: ["m1"] };
    await sameOpen({ kind: "hermes", runner: "hm-o", command: "hermes", options: { profile: hermesProfile }, answers: acpAnswers() });
    await sameOpen({ kind: "hermes", name: "hermes old", runner: "hm-o", command: "hermes", options: {}, answers: acpAnswers({ initialize: { result: { agentInfo: { version: "0.21.6" } } } }) });
    await sameOpen({ kind: "hermes", name: "hermes bad id", runner: "hm-o", command: "hermes", options: { resume: "../x" }, answers: acpAnswers() });
    await sameOpen({ kind: "hermes", name: "hermes named badly", runner: "hm-o", command: "hermes", options: {}, answers: acpAnswers({ "session/new": { result: { sessionId: "a b" } } }) });
    await sameOpen({ kind: "hermes", name: "hermes resumed", runner: "hm-o", command: "hermes", options: { resume: "hm-9", model: "m9" }, files: [["hermes/sessions/hm-9.jsonl", `${JSON.stringify({ type: "session", id: "hm-9", hermesHome: "/srv/hermes-old/" })}\n{}`]], answers: acpAnswers() });
    await sameOpen({ kind: "hermes", name: "hermes relative home", runner: "hm-o", command: "hermes", options: { profile: { env: { HERMES_HOME: "rel" } } }, answers: acpAnswers() });
  });

  test("a profile's own proxy leaves this machine out of it, for every runtime: its tools are on 127.0.0.1", async () => {
    const env = { HTTPS_PROXY: "http://127.0.0.1:7890", NO_PROXY: "corp.example" };
    const kept = "corp.example,localhost,127.0.0.1,::1";
    const cases = [
      { kind: "dsh", runner: "dsh-o", bridge: dsh.BRIDGE, command: "dsh", answers: { open: { session: "dsh-new" } } },
      { kind: "cursor", runner: "cur-o", bridge: cursor.BRIDGE, node: "/n", sdk: "/sdk", answers: { open: { session: "agent-9" } } },
      { kind: "pi", runner: "pi-o", bridge: pi.BRIDGE, command: "pi", answers: { get_state: { success: true } } },
      { kind: "devin", runner: "dv-o", command: "devin", answers: acpAnswers() },
      { kind: "grok", runner: "gk-o", command: "grok", answers: acpAnswers() },
      { kind: "hermes", runner: "hm-o", command: "hermes", answers: acpAnswers() },
    ];
    for (const c of cases) {
      const ts = await sameOpen({ ...c, name: `${c.kind} proxied`, options: { profile: { env } } });
      assert.deepEqual([ts.started?.env.NO_PROXY, ts.started?.env.no_proxy], [kept, kept], `${c.kind}: this machine left out of the profile's proxy`);
    }
  });
});

// ── The disk ─────────────────────────────────────────────────────────────────────────────────────────────────────

describe("what reads and writes the disk", { skip }, () => {
  test("the memory read with what has grown past its bounds, and the deployment's instructions", async () => {
    const dir = fresh("memory");
    const path = join(dir, "MEMORY.md");
    for (const [memory, skills] of [[null, []], ["  - a\n- b  \n", [["stillfail", "x"], ["big", "y".repeat(30_000)], ["long", `${"z".repeat(1600)}\nok`]]], ["m".repeat(9000), [["zz", "short"]]]] as const) {
      rmSync(dir, { recursive: true, force: true });
      mkdirSync(join(dir, "skills", "not-a-skill"), { recursive: true });
      writeFileSync(join(dir, "skills", "loose.md"), "loose");
      if (memory !== null) writeFileSync(path, memory);
      for (const [name, text] of skills) {
        mkdirSync(join(dir, "skills", name), { recursive: true });
        writeFileSync(join(dir, "skills", name, "SKILL.md"), text);
      }
      if (posix) symlinkSync(join(dir, "skills", "big"), join(dir, "skills", "linked"));
      assert.deepStrictEqual(await io("readMemory", path), { ok: await I.readMemory(path) });
    }
    const site = join(dir, "site.md");
    for (const text of [null, "  read skill x  ", "s".repeat(5000)]) {
      rmSync(site, { force: true });
      if (text !== null) writeFileSync(site, text);
      assert.deepStrictEqual(await io("readSiteInstructions", site), { ok: await I.readSiteInstructions({ STILLFAIL_SITE_INSTRUCTIONS: site }) });
    }
    assert.deepStrictEqual(await io("readSiteInstructions", null), { ok: await I.readSiteInstructions({}) });
  });

  test("a rules' folder, the stand-in security, a runtime's sessions found, its keys and SDK", async () => {
    const skills = fresh("rf-skills");
    for (const withSkills of [undefined, skills, "/not/there"]) {
      const a = fresh("rf-ts"), b = fresh("rf-mb");
      mkdirSync(join(a, "station"), { recursive: true });
      const ts = await rulesFolder(a, "chat:c-1", ".cursor", { file: "r.mdc", text: "rule" }, "Cursor", withSkills);
      const said = await io("rulesFolder", b, "chat:c-1", ".cursor", "r.mdc", "rule", withSkills);
      assert.deepStrictEqual(said, { ok: ts.replace(a, b) });
      assert.deepStrictEqual(tree(b), tree(a));
    }
    // The stand-in written where none (or an older one) is, as fileCredentialsSoon writes it.
    if (platform.hasKeychain) {
      const env: Record<string, string> = {};
      await keychain.fileCredentialsSoon(env);
      const at = join(tmpdir(), `stillfail-no-keychain-${process.getuid?.() ?? 0}`);
      const t2 = fresh("stub"), dir = join(t2, `stillfail-no-keychain-7`);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "security"), "old");
      assert.deepStrictEqual(await io("stubDirSoon", t2, 7, "x1"), { ok: dir });
      assert.deepStrictEqual(tree(dir), tree(at).filter(([p]) => p === "security"));
    }
    const home = fresh("found");
    mkdirSync(join(home, "dsh-sessions", "-w", "s-1"), { recursive: true });
    writeFileSync(join(home, "dsh-sessions", "-w", "s-file"), "");
    mkdirSync(join(home, "grok", "sessions", "-w", "g-1"), { recursive: true });
    for (const id of ["s-1", "s-file", "none"]) assert.deepStrictEqual(await io("dshSessionDir", home, id), { ok: await dsh.sessionDir(home, id) });
    for (const id of ["g-1", "", "none"]) assert.deepStrictEqual(await io("grokSessionAt", home, id), { ok: await grok.sessionAt(home, id) });
    assert.deepStrictEqual(await io("dshSessionDir", fresh("empty"), "x"), { ok: null });
    for (const text of [null, JSON.stringify({ apiKey: "ck" }), JSON.stringify({ apiKey: "" }), "nope"]) {
      rmSync(join(home, "cursor"), { recursive: true, force: true });
      if (text !== null) { mkdirSync(join(home, "cursor"), { recursive: true }); writeFileSync(join(home, "cursor", "auth.json"), text); }
      assert.deepStrictEqual(await io("cursorKey", home), { ok: await cursor.cursorKey(home) });
    }
    for (const text of [null, "windsurf_api_key = \"a\"", "x = 1\n  windsurf_api_key=\"b\" # c", "windsurf_api_key = \"\"\nwindsurf_api_key = \"d\"", "windsurf_api_key = c", "\n\n  \twindsurf_api_key  =  \"e\"", "xwindsurf_api_key = \"f\""]) {
      rmSync(join(home, "devin"), { recursive: true, force: true });
      if (text !== null) { mkdirSync(join(home, "devin", "data", "devin"), { recursive: true }); writeFileSync(join(home, "devin", "data", "devin", "credentials.toml"), text); }
      assert.deepStrictEqual(await io("devinKey", home), { ok: await devin.devinKey(home) }, String(text));
    }
    const data = fresh("sdk");
    for (const [where, pkg] of [[null, null], ["lib/node_modules", "{\"version\":\"1.0.3\"}"], ["node_modules", "{\"version\":2}"], ["lib/node_modules", "not json"]] as const) {
      rmSync(join(data, "runtimes"), { recursive: true, force: true });
      if (where !== null) { mkdirSync(join(cursor.sdkPrefix(data), where, "@cursor", "sdk"), { recursive: true }); writeFileSync(join(cursor.sdkPrefix(data), where, "@cursor", "sdk", "package.json"), pkg!); }
      assert.deepStrictEqual(await io("cursorFindSdk", data), { ok: await cursor.findSdk(data) });
      assert.deepStrictEqual(await io("cursorSdkVersion", data), { ok: await cursor.sdkVersionSoon(data) });
    }
  });

  test("a machine profile's Codex home linked to the machine's login; the station's key for its sandboxes", { skip: !posix && "no links to share a file by" }, async () => {
    const machine = fresh("machine"), a = fresh("codex-ts"), b = fresh("codex-mb");
    const env = { HOME: machine };
    for (const before of ["none", "file", "other link", "link"]) {
      for (const home of [a, b]) {
        rmSync(join(home, "auth.json"), { force: true });
        if (before === "file") writeFileSync(join(home, "auth.json"), "{}");
        if (before === "other link") symlinkSync("/elsewhere", join(home, "auth.json"));
        if (before === "link") symlinkSync(logins.codexAuthFile(env), join(home, "auth.json"));
      }
      await logins.linkCodexAuthSoon(a, env);
      assert.deepStrictEqual(await io("linkCodexAuthSoon", b, env), { ok: null });
      assert.deepStrictEqual(tree(b), tree(a), before);
    }
    const data = fresh("identity");
    assert.deepStrictEqual(await io("ensureIdentity", data), { ok: null });
    assert.ok(statSync(sandbox.identityOf(data)).isFile());
    const kept = readFileSync(sandbox.identityOf(data), "utf8");
    await sandbox.ensureIdentity(data);
    assert.deepStrictEqual(await io("ensureIdentity", data), { ok: null });
    assert.equal(readFileSync(sandbox.identityOf(data), "utf8"), kept, "a key there is kept");
    chmodSync(sandbox.identityOf(data), 0o600);
  });
});

// ── The agents' home ─────────────────────────────────────────────────────────────────────────────────────────────

describe("agenthome/module.ts: when the agents' home's rounds run", { skip }, () => {
  /// The part built on fakes of what it is given; `script` fires the config's changes and waits, then it closes:
  /// how many rounds ran (each reads the hub's config twice).
  async function rounds(script: (change: () => void, flush: () => Promise<void>, roundsDone: (n: number) => Promise<void>) => Promise<void>) {
    const agentHome = fresh("agent-home"), dataDir = fresh("agent-data");
    let reads = 0;
    const listeners: (() => void)[] = [];
    const parts = Layer.mergeAll(
      Layer.succeed(ControlPlane, { spec: () => ({}) } as any),
      Layer.succeed(StationConfig, { listen: (f: () => void) => (listeners.push(f), () => {}) } as any),
      Layer.succeed(Agents, { updates: { channel: () => "beta" }, hub: { config: () => (reads++, { agentHome, dataDir, profiles: [] }) } } as any),
    );
    const scope = Effect.runSync(Scope.make());
    await Effect.runPromise(Layer.buildWithScope(AgentHomeLive.pipe(Layer.provide(parts)), scope));
    const flush = async () => { for (let i = 0; i < 3; i++) await Promise.resolve(); };
    // (a round's end, in the loop's own time: its reads are each round's first act and its last's start)
    const roundsDone = async (n: number) => { while (reads < 2 * n) await new Promise((r) => setImmediate(r)); };
    await script(() => listeners.forEach((f) => f()), flush, roundsDone);
    await Effect.runPromise(Scope.close(scope, Exit.void));
    return reads / 2;
  }

  test("one round at the start; changes while one runs make one more after it, none once it closes", async () => {
    const scripts: [string[], (change: () => void, flush: () => Promise<void>, done: (n: number) => Promise<void>) => Promise<void>][] = [
      [["close"], async () => {}],
      // (the part closes a step of Effect's after it is asked: a round asked for just before has begun by then)
      [["ended", "change", "change", "flush", "close"], async (change) => { change(); change(); }],
      [["ended", "change", "flush", "change", "change", "ended", "ended", "close"], async (change, flush, done) => { change(); await flush(); change(); change(); await done(3); }],
    ];
    for (const [events, script] of scripts) {
      const ts = await rounds(script);
      const said = await mb({ op: "agentHome", events });
      assert.equal(said.rounds, ts, events.join(" "));
    }
    for (const [channel, spec] of [["stable", { feedback: true }], ["stable", {}], ["beta", { feedback: true }], ["stable", null]] as const)
      assert.equal(await call("agentHomeFeedback", channel, spec), channel === "stable" && (spec as any)?.feedback === true);
  });
});
