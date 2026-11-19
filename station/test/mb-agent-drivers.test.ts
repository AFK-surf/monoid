// The agents' drivers in MoonBit (station/mb src/agent_drivers: reader `--builder harness-agent-drivers`) held to the
// TypeScript they replace on the same inputs: the seam's words (runtime.ts), a runner's files, its connection and
// what a station reads again of it (runner.ts, process.ts), and Claude Code's, Codex's and Antigravity CLI's drivers
// (claude.ts, codex.ts, agy.ts over own-process.ts and acp.ts) through the same steps: what each process is started
// with (its arguments, environment, working directory), what is written to it and told the program reading it, its
// requests answered as a case says, the events its sessions say, what each step returns or fails with, what a next
// station takes it up from, and the files it leaves. Each side is given the same world: files (the TypeScript's real,
// in a directory of its own, the MoonBit's in memory, a copy of them), the processes said alive, runners' sockets that
// say what the case scripts, the program as a fake of mb-agents.ts's `AgentsHost`, one clock.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, realpathSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { createServer, type Socket } from "node:net";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { after, mock, test } from "node:test";
import { Effect } from "effect";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { wall, liveClock } from "../src/ops/fibers.ts";
import { platform } from "../src/platform/index.ts";
import { agentEnv, readAgentEnvFrom } from "../src/ops/agent-env.ts";
import { stationLang, tr } from "../src/ops/i18n.ts";
import { AGY_REPO_RULES_COMMAND, REPO_RULES_COMMAND, hookCommand } from "../src/agents/repo-rules.ts";
import { SLACK_SPOKEN, SPEAKS, SPEAKS_WRITING } from "../src/tools/mcp.ts";
import { HostedProcess } from "../src/agents/mb-agents.ts";
import { Lines, RunnerConnection, isTerminalRunner, liveRunner, liveRunners, runnerOf, sweepRunners, type RunnerInfo } from "../src/agents/runner.ts";
import { ackedOffset, bytesWithin, describeExit, endRunner, findRunner, runnerId } from "../src/agents/process.ts";
import { chars } from "../src/agents/live.ts";
import { failureOf, failureRest, modelLimitOf, runtimeKind, runtimeLabel, stationTool, unreachable } from "../src/agents/runtime.ts";
import { keyPart } from "../src/agents/sandbox-name.ts";
import { peerHttpBase } from "../src/tools/http.ts";
import { claudeProject } from "../src/read/transcript.ts";
import { ClaudeDriver, SUBAGENT_HOOK, backgroundOf, hooksOf, mcpUrlOf, toolsLostIn, userMessage } from "../src/agents/claude.ts";
import { CodexDriver, ModelCatalog, hostSkillsOff, userAgentVersion } from "../src/agents/codex.ts";
import { versionIn } from "../src/updates/versions.ts";
import { AgyDriver, agyBaseModel, agyBringIn, agyCatalog, agyCompany, agyEmailIn, agyExpiryIn, agyHooks, agyLentFile, agyModels, agyOpening, agyPlan, agyPlanIn, agySkills, agyTierIn, agyTokenReady, agyVariant, classifyFailure, goKeyringValue, noteAgyEmail, noticeFailure, turnUsage } from "../src/agents/agy.ts";
import { errorText, mcpServers, rpc } from "../src/agents/acp.ts";
import { codexOverrides, accessKind, profileEnv, profileModel, profileVia } from "../src/agents/profiles.ts";

type Json = any;

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the runners' sockets here are Unix sockets" : false;

const dirs: string[] = [];
/// A directory of a case's own, by its real path (what a runtime is told; macOS's /tmp is /private/tmp), short enough
/// for a socket's path under it.
const fresh = () => {
  const dir = realpathSync(mkdtempSync("/tmp/ad-"));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const child = spawn(binary!, ["--builder", "harness-agent-drivers", "--shell-dir", fresh()], { stdio: ["pipe", "pipe", "pipe"] });
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
after(async () => {
  // A runner's socket a case left open (it threw before closing it) would keep this file's process from ending.
  for (const close of [...openSockets]) await close();
  program?.child.stdin.end();
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What MoonBit says of `c` (its `ok`, or the words it failed with).
async function mb(c: unknown): Promise<any> {
  const answer = await harness().next(JSON.stringify(c));
  if ("error" in answer) throw new Error(`MoonBit: ${answer.error}`);
  return answer.ok;
}

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

// ── one world for both sides: the clock, the processes, the ids ──

/// What `until` waits on, woken whenever what it looks at may have changed: a timer set, a line a runner's socket was told.
const waiters: (() => void)[] = [];
const wake = () => {
  for (const w of waiters.splice(0)) w();
};

/// The machine's clock (`wall`) as the case has it: its timers run as it is moved on.
const time = {
  now: 0,
  seq: 0,
  timers: [] as { at: number; seq: number; f: () => void }[],
  after(ms: number, f: () => void) {
    const t = { at: time.now + Math.max(0, ms), seq: ++time.seq, f };
    time.timers.push(t);
    wake();
    return () => void (time.timers = time.timers.filter((x) => x !== t));
  },
  async advance(ms: number) {
    const to = time.now + ms;
    await settle();
    for (;;) {
      const due = time.timers.filter((t) => t.at <= to).sort((a, b) => a.at - b.at || a.seq - b.seq)[0];
      if (due === undefined) break;
      time.timers = time.timers.filter((t) => t !== due);
      if (due.at > time.now) time.now = due.at;
      due.f();
      await settle();
    }
    time.now = Math.max(time.now, to);
  },
};
mock.method(wall, "now", () => time.now);
mock.method(wall, "after", (ms: number, f: () => void) => time.after(ms, f));
mock.method(wall, "sleep", (ms: number) => new Promise<void>((resolve) => void time.after(ms, resolve)));

/// The processes alive (a group by its pgid negated) and when each started, as the case says.
const alive = new Set<number>();
const startTimes = new Map<number, number>();
const realKill = process.kill.bind(process);
mock.method(process, "kill", (pid: number, signal?: string | number) => {
  if (signal !== 0 && signal !== undefined) return realKill(pid, signal);
  if (alive.has(pid)) return true;
  throw Object.assign(new Error("kill ESRCH"), { code: "ESRCH" });
});
mock.method(platform, "startTimeOf", async (pid: number) => startTimes.get(pid) ?? null);
platform.hasKeychain = false;

/// The ids the drivers take in turn.
let ids: string[] = [];
let idAt = 0;
mock.method(globalThis.crypto, "randomUUID", () => (idAt < ids.length ? ids[idAt++] : `id-${idAt++}`) as never);

const AGENT_ENV = { HTTPS_PROXY: "http://proxy.example:3128", NO_PROXY: "corp.example" };
readAgentEnvFrom(() => ({ agentEnv: AGENT_ENV }));

/// Turns of the loop with nothing written to or read from the disk in between: what the drivers set going is done.
async function settle(rounds = 40) {
  for (let i = 0; i < rounds; i++) await new Promise((resolve) => setImmediate(resolve));
}

/// Until `ready` holds: what real I/O sets going (a read on libuv's threads, a line on a real socket) is waited for by
/// what it does, woken by `wake` where that lands, never by a time or a count of turns. What never comes is the test's
/// `timeout`, which ends it and leaves its sockets to the file's after().
async function until(ready: () => boolean, _what: string) {
  while (!ready()) await new Promise<void>((resolve) => waiters.push(resolve));
}

function world(c: { now?: number; alive?: number[]; startTimes?: Record<string, number>; ids?: string[] }) {
  time.now = c.now ?? 0;
  time.timers = [];
  alive.clear();
  for (const p of c.alive ?? []) alive.add(p);
  startTimes.clear();
  for (const [p, t] of Object.entries(c.startTimes ?? {})) startTimes.set(Number(p), t);
  ids = c.ids ?? [];
  idAt = 0;
}

// ── files: a case's directory as both sides have it ──

type FileEntry = { path: string; kind: "file" | "dir" | "link"; data?: string; target?: string; mtime?: number; ino?: number; dev?: number };

/// What is under `root` (its ancestors as directories too), each with its time and inode: the MoonBit's files.
function snap(root: string): FileEntry[] {
  const out: FileEntry[] = [];
  for (let d = dirname(root); ; d = dirname(d)) {
    out.push({ path: d, kind: "dir" });
    if (d === "/") break;
  }
  const walk = (p: string) => {
    const st = lstatSync(p);
    const base = { path: p, mtime: st.mtimeMs, ino: st.ino, dev: st.dev };
    if (st.isSymbolicLink()) out.push({ ...base, kind: "link", target: readlinkSync(p) });
    else if (st.isDirectory()) {
      out.push({ ...base, kind: "dir" });
      for (const name of readdirSync(p).sort()) walk(join(p, name));
    } else out.push({ ...base, kind: "file", data: st.isFile() ? readFileSync(p).toString("base64") : "" });
  };
  walk(root);
  return out.map((e) => (e.path === "/" ? { ...e, path: "/" } : e));
}

/// What is under `root` as it stands: each path, its kind, a file's contents, a link's target.
function dump(root: string) {
  return snap(root)
    .filter((e) => e.path === root || e.path.startsWith(`${root}/`))
    .map(({ path, kind, data, target }) => (kind === "file" ? { path, kind, data } : kind === "link" ? { path, kind, target } : { path, kind }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function put(path: string, text: string | Buffer, mtimeMs?: number) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  if (mtimeMs !== undefined) utimesSync(path, mtimeMs / 1000, mtimeMs / 1000);
}

/// The runner's sockets a case has not closed yet: closed after the file if a case threw first.
const openSockets = new Set<() => Promise<void>>();

/// A runner's socket that says `script` once it is told its first line, and keeps what it is told. `close` ends the
/// connections it took and then stops listening: a server's own close waits for its connections, which a case that
/// failed half way leaves open, and with them the file's process.
async function runnerSocket(path: string, script: string[]): Promise<{ told: Json[]; close: () => Promise<void> }> {
  const told: Json[] = [];
  const sockets = new Set<Socket>();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    let carry = "";
    let said = false;
    socket.on("data", (chunk) => {
      carry += chunk.toString("utf8");
      for (let i = carry.indexOf("\n"); i >= 0; i = carry.indexOf("\n")) {
        const line = carry.slice(0, i);
        carry = carry.slice(i + 1);
        if (line !== "") {
          told.push(JSON.parse(line));
          wake();
        }
        if (!said) {
          said = true;
          for (const l of script) socket.write(`${l}\n`);
        }
      }
    });
    socket.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  let closed: Promise<void> | undefined;
  const close = () =>
    (closed ??= (async () => {
      // what the station's side ended closes by itself within a few turns; what is left is ended here
      for (let i = 0; i < 20 && sockets.size > 0; i++) await new Promise((resolve) => setImmediate(resolve));
      for (const s of sockets) s.destroy();
      if (server.listening) await new Promise<void>((resolve) => server.close(() => resolve()));
      openSockets.delete(close);
    })());
  openSockets.add(close);
  return { told, close };
}

// ── the seam's words, a function at a time ──

const TEXTS = [
  "", "API Error: 401 Unauthorized", "403 Forbidden: request not allowed", "403 <html>Attention Required! | Cloudflare", "403", "429 Too Many Requests",
  "529 overloaded", "You've reached your Fable limit. Switch to another model", "You've hit your weekly limit · resets 3pm", "You've hit your Fable 4 limit",
  "you reached your 5-hour limit", "Prompt is too long", "stream disconnected before completion", "ECONNRESET", "connect ETIMEDOUT 1.2.3.4",
  "the model said no", "RESOURCE_EXHAUSTED: quota", "Not logged in · Please run /login", "Hit your opus-4.5 limit", "reached your  limit",
  "⚠ Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 56m33s.", "⚠ Agent execution terminated due to error.",
  "partial text\n⚠ Agent executor error: 401 unauthenticated", "⚠ something else", "trajectory not found", "invalid_grant", "Timeout waiting",
  "😀 emoji 𝄞 surrogate", "x".repeat(400),
];

const PURE: [string, unknown[], (...a: any[]) => unknown][] = [
  ...TEXTS.map((t) => ["failureOf", [t, {}], (x: string) => failureOf(x)] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["failureOf", [t, { authCodes: ["UNAUTHENTICATED"], limit: ["quota"] }], (x: string, w: Json) => failureOf(x, w)] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["failureRest", [t], failureRest] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["modelLimitOf", [t], modelLimitOf] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["unreachable", [t], unreachable] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["noticeFailure", [t], noticeFailure] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["classifyFailure", [t], classifyFailure] as [string, unknown[], (...a: any[]) => unknown]),
  ...TEXTS.map((t) => ["chars", [t, 5], chars] as [string, unknown[], (...a: any[]) => unknown]),
  ...["claude", "codex", "agy", "pi", "nope", 3, null].map((k) => ["runtimeKind", [k], runtimeKind] as [string, unknown[], (...a: any[]) => unknown]),
  ...["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi"].map((k) => ["runtimeLabel", [k], runtimeLabel] as [string, unknown[], (...a: any[]) => unknown]),
  ...["mcp__stillfail__chat_post", "stillfail__x", "mcp__other__x", "Bash"].map((k) => ["stationTool", [k], stationTool] as [string, unknown[], (...a: any[]) => unknown]),
  ...["slack:T1:C1:1700000000.0001", "chat_abc", "a/b c", "x".repeat(30), "über", "😀"].map((k) => ["keyPart", [k], keyPart] as [string, unknown[], (...a: any[]) => unknown]),
  ...["slack:T1:C1:1700000000.0001", "cc"].map((k) => ["runnerId", ["claude", k], runnerId] as [string, unknown[], (...a: any[]) => unknown]),
  ...["http://127.0.0.1:4750/mcp", "http://127.0.0.1:4750/mcp/", "http://x/mcpx"].map((k) => ["peerHttpBase", [k], peerHttpBase] as [string, unknown[], (...a: any[]) => unknown]),
  ...["term-1", "claude-x"].map((k) => ["isTerminalRunner", [k], isTerminalRunner] as [string, unknown[], (...a: any[]) => unknown]),
  ...[{ code: 0, signal: null }, { code: 3, signal: null }, { code: null, signal: "TERM" }, { code: null, signal: "SEGV" }, { code: null, signal: null }].map(
    (e) => ["describeExit", [e], describeExit] as [string, unknown[], (...a: any[]) => unknown],
  ),
  ...[
    ["--mcp-config", JSON.stringify({ mcpServers: { stillfail: { url: "http://h/mcp" } } })],
    ["--mcp-config", "{"],
    ["--mcp-config"],
    ["--mcp-config", JSON.stringify({ mcpServers: { stillfail: {} } })],
  ].map((a) => ["mcpUrlOf", [a], mcpUrlOf] as [string, unknown[], (...a: any[]) => unknown]),
  ...["hello", "line\nbreak \"quoted\" ✓"].map((t) => ["userMessage", [t], userMessage] as [string, unknown[], (...a: any[]) => unknown]),
  ["hooksOf", [[{ A: [1], B: [2] }, { B: [3], C: [4] }, {}]], (sets: Json[]) => hooksOf(...sets)],
  [
    "backgroundOf",
    [{ busy: true, tasks: { t1: { id: "t1", kind: "agent", description: "d", background: true, startedAt: 5 }, t2: { id: "t2", kind: "command", description: "e", background: false }, t3: { id: "t3", kind: "command", description: "f", background: true } } }],
    backgroundOf,
  ],
  ...["/Users/a/b.c", "/tmp/x y", "/" + "a".repeat(250)].map((c) => ["claudeProject", [c], claudeProject] as [string, unknown[], (...a: any[]) => unknown]),
  ...["stillfail/0.162.1 (Mac OS 15) x", "codex/v0.1.2", "bad", "a/b/c", 5].map((u) => ["userAgentVersion", [u], userAgentVersion] as [string, unknown[], (...a: any[]) => unknown]),
  ...["codex-cli 0.169.0", "v1.2.3", "(1.2) x", "1.a.2 3.4", "none"].map((u) => ["versionIn", [u], versionIn] as [string, unknown[], (...a: any[]) => unknown]),
  ...['{"id_token_email":"a@b.c"}', '{"id_token_email":""}', "nope"].map((t) => ["agyEmailIn", [t], agyEmailIn] as [string, unknown[], (...a: any[]) => unknown]),
  ...["go-keyring-base64:eyJhIjoxfQ==", "go-keyring-encoded:7b2261223a317d", "plain"].map((t) => ["goKeyringValue", [t], goKeyringValue] as [string, unknown[], (...a: any[]) => unknown]),
  ...[
    ['{"token":{"access_token":"t"}}', false],
    ['{"token":{"access_token":"t"},"auth_method":"gcp"}', false],
    ['{"token":{"access_token":"t"},"auth_method":"gcp","project_id":"p"}', false],
    ['{"token":{"access_token":"t"}}', true],
    ["{}", false],
  ].map((a) => ["agyTokenReady", a, agyTokenReady] as [string, unknown[], (...a: any[]) => unknown]),
  ...['{"auth_method":"gcp"}', '{"auth_method":"consumer"}', "x"].map((t) => ["agyCompany", [t], agyCompany] as [string, unknown[], (...a: any[]) => unknown]),
  ...[["g1-pro-tier", false], [" G1-ULTRA-TIER ", false], ["gcp-x", false], ["other", true], [null, false]].map((a) => ["agyPlan", a, agyPlan] as [string, unknown[], (...a: any[]) => unknown]),
  ...[['{"user_tier":"free-tier"}', false], ["bad", true], ['{"auth_method":"gcp"}', false]].map((a) => ["agyPlanIn", a, agyPlanIn] as [string, unknown[], (...a: any[]) => unknown]),
  ...[
    '{"token":{"expiry":"2026-11-16T12:34:56Z"}}',
    '{"token":{"expiry":"2026-11-16T12:34:56.789123+08:00"}}',
    '{"token":{"expiry":"2026-11-16"}}',
    '{"token":{"expiry":"soon"}}',
    "{}",
  ].map((t) => ["agyExpiryIn", [t], agyExpiryIn] as [string, unknown[], (...a: any[]) => unknown]),
  ...[
    { token: { access_token: "a", refresh_token: "r", expiry: "x" }, email: "e@x", stored: { project_id: "p", auth_method: "gcp" } },
    { token: { access_token: "a" }, auth_method: null },
    { token: null, stored: [1] },
  ].map((l) => ["agyLentFile", [l], agyLentFile] as [string, unknown[], (...a: any[]) => unknown]),
  ...["gemini-4-carbon-high", "gemini-3.5-flash", " claude-opus-5-5-medium ", "-high", "x-max"].map((m) => ["agyBaseModel", [m], agyBaseModel] as [string, unknown[], (...a: any[]) => unknown]),
  ...[{ _meta: { antigravity: { tier: { id: "g1-pro-tier" } } } }, {}, null].map((r) => ["agyTierIn", [r], agyTierIn] as [string, unknown[], (...a: any[]) => unknown]),
  ...[
    [["gemini-4-carbon-low", "gemini-4-carbon-high", "gemini-3.5-flash", "gpt-oss-120b-medium"], "gemini-4-carbon-high"],
    [["a-low", "a-medium", "a-high"], null],
    [["a-low", "a-xhigh"], "a-low"],
  ].map((a) => ["agyCatalog", a, agyCatalog] as [string, unknown[], (...a: any[]) => unknown]),
  ...[
    ["gemini-4-carbon", "high", ["gemini-4-carbon-low", "gemini-4-carbon-high"], "gemini-4-carbon-low"],
    ["gemini-4-carbon", undefined, ["gemini-4-carbon-low", "gemini-4-carbon-high"], "gemini-4-carbon-low"],
    ["gemini-4-carbon", "medium", [], null],
    ["gemini-4-carbon-high", undefined, [], null],
    ["x", undefined, ["y"], null],
    ["a", "weird", ["a-high", "a-medium"], null],
    ["a", undefined, ["a-low", "a-zz"], null],
  ].map((a) => ["agyVariant", a, agyVariant] as [string, unknown[], (...a: any[]) => unknown]),
  ...[{ models: { currentModelId: "m1", availableModels: [{ modelId: "m2" }, { modelId: "m1" }, { modelId: " " }] } }, {}].map((r) => ["agyModels", [r], agyModels] as [string, unknown[], (...a: any[]) => unknown]),
  ...[{ result: { usage: { inputTokens: 100, cachedReadTokens: 30, cachedWriteTokens: 10, outputTokens: 5, thoughtTokens: 7 } } }, { result: { usage: { inputTokens: 1, cachedReadTokens: 30 } } }, { result: { usage: { inputTokens: 409896, outputTokens: 621, cachedReadTokens: 404509, cachedWriteTokens: 0, thoughtTokens: 315, totalTokens: 815026 } } }, { result: { usage: { inputTokens: -5, outputTokens: "x" } } }, {}].map(
    (r) => ["turnUsage", [r], turnUsage] as [string, unknown[], (...a: any[]) => unknown],
  ),
  ...["", "be brief"].map((t) => ["agyOpening", [t], agyOpening] as [string, unknown[], (...a: any[]) => unknown]),
  ["rpc", ["init", "initialize", { a: 1 }], rpc],
  ["mcpServers", ["http://h/mcp", "tok"], mcpServers],
  ...[{ message: "Internal error: boom", data: "why" }, { message: "m", data: { message: "dm" } }, { message: "m", data: { details: "dd" } }, { code: 1 }].map(
    (e) => ["errorText", [e], errorText] as [string, unknown[], (...a: any[]) => unknown],
  ),
];

test("the seam's words, the drivers' pure functions: as the TypeScript says them", { skip }, async () => {
  for (const [fn, args, f] of PURE) assert.deepEqual(await mb({ op: "pure", fn, args }), plain(f(...args)), `${fn}(${JSON.stringify(args)})`);
});

test("Codex's model list and the user's skills turned off, in the TypeScript's order", { skip }, async () => {
  const pages = [
    { data: [{ id: "b", supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "low" }, { reasoningEffort: "" }], defaultReasoningEffort: "low" }, { model: "a", serviceTiers: [{ id: "ultrafast" }] }, { id: "h", hidden: true, serviceTiers: [{ id: "ultrafast" }] }] },
    { data: [{ id: "c", defaultReasoningEffort: "", additionalSpeedTiers: ["ultrafast"] }, { id: "d", serviceTiers: [], additionalSpeedTiers: ["ultrafast"] }] },
  ];
  const catalog = new ModelCatalog();
  for (const p of pages) catalog.extend(p);
  const said = await mb({ op: "pure", fn: "modelCatalog", args: [pages] });
  assert.deepEqual(said, { models: catalog.models, efforts: Object.fromEntries(catalog.efforts), defaults: Object.fromEntries(catalog.defaults), ultrafastModels: ["a", "c"] });
  assert.deepEqual(catalog.ultrafastModels, ["a", "c"]);
  const root = fresh();
  const paths = ["z/SKILL.md", "a/b/SKILL.md", "a/SKILL.md", "a-b/SKILL.md", "node_modules/x/SKILL.md", ".git/SKILL.md"].map((p) => join(root, p));
  for (const p of paths) put(p, "x");
  const off = await hostSkillsOff(root);
  const found = paths.filter((p) => !p.includes("node_modules") && !p.includes(".git"));
  assert.deepEqual(await mb({ op: "pure", fn: "hostSkillsOff", args: [found] }), off);
});

test("a runner's lines come whole however they are cut, and its ready line read", { skip }, async () => {
  const cuts = [["ab", "c\nde", "f\n\ng", "h\n"], ["\n\n"], ["x".repeat(70000), "y\n"], ["αβ\nγ"]].map((parts) => parts.map((p) => Buffer.from(p).toString("base64")));
  for (const chunks of cuts) {
    const lines = new Lines();
    const ts = chunks.map((c) => lines.take(Buffer.from(c, "base64")).map((l) => l.toString("base64")));
    assert.deepEqual(await mb({ op: "pure", fn: "lines", args: [chunks] }), ts);
  }
});

// ── runners ──

test("runners found alive, by their files and their processes, and those gone swept", { skip }, async () => {
  const data = fresh();
  const dir = join(data, "run", "runners");
  const info = (id: string, runner: number, startedAt: number) => ({ id, runner, pid: runner + 1, pgid: runner + 2, startedAt, program: "claude", args: ["-p"], socket: join(dir, `${id}.sock`) });
  put(join(dir, "claude-a.json"), JSON.stringify(info("claude-a", 7001, 1000)), 5_000);
  put(join(dir, "claude-a.sock"), "", 5_000);
  put(join(dir, "claude-a.out"), "out", 5_000);
  put(join(dir, "codex-b.json"), JSON.stringify(info("codex-b", 7002, 1000)), 5_000);
  put(join(dir, "codex-b.out"), "x", 5_000);
  put(join(dir, "term-c.json"), JSON.stringify(info("term-c", 7003, 1000)), 5_000);
  put(join(dir, "half.json"), "{", 5_000);
  put(join(dir, "fresh.json"), "{", 900_000);
  put(join(dir, "left.out"), "x", 5_000);
  put(join(dir, "left.err"), "x", 900_000);
  put(join(dir, "left.tmp"), "x", 5_000);
  put(join(dir, "claude-d.json"), JSON.stringify(info("claude-d", 7004, 1000)), 5_000);
  put(join(dir, "claude-e.json"), JSON.stringify(info("claude-e", 7005, 1000)), 5_000);
  const c = { now: 1_000_000, alive: [7001, 7003, 7004, 7005], startTimes: { 7001: 1500, 7004: 999_999, 7005: 1200 }, data, fs: snap(data), dump: data };
  world(c);
  const runners = await liveRunners(data);
  const one = await runnerOf(data, "claude-a");
  const found = await findRunner(data, "claude-a");
  const live = await liveRunner(info("claude-d", 7004, 1000) as RunnerInfo);
  assert.deepEqual(new Set((await mb({ ...c, op: "liveRunners" })).map((r: Json) => r.id)), new Set(runners.map((r) => r.id)));
  assert.deepEqual(await mb({ ...c, op: "runnerOf", id: "claude-a" }), plain(one));
  assert.deepEqual(await mb({ ...c, op: "findRunner", id: "claude-a" }), plain(found));
  assert.deepEqual(await mb({ ...c, op: "liveRunner", info: info("claude-d", 7004, 1000) }), live);
  assert.deepEqual(await mb({ ...c, op: "findRunner", id: "codex-b" }), null);
  const asked: string[] = [];
  const gone = await sweepRunners(data, c.now, async (i) => {
    asked.push(i.id);
    return i.id === "claude-e";
  });
  const said = await harness().next(JSON.stringify({ ...c, op: "sweep", orphans: ["claude-e"] }));
  assert.deepEqual(new Set(said.ok.gone), new Set(gone), "the same runners swept");
  assert.deepEqual(new Set(said.ok.asked), new Set(asked), "the same asked whether nobody holds them");
  assert.deepEqual(said.fs, dump(data), "the same files left");
});

test("a runner's connection: its lines handed on in order and acknowledged, its exit, what is written and signalled", { skip }, async () => {
  const root = fresh();
  const out = (stream: string, at: number, text: string) => JSON.stringify({ op: "out", stream, at, data: Buffer.from(text).toString("base64") });
  const script = [out("out", 100, "first\nsec"), out("err", 0, "oops\n"), out("out", 109, "ond\nthird\n"), JSON.stringify({ op: "exit", code: null, signal: "TERM" })];
  const path = join(root, "r.sock");
  const { told, close } = await runnerSocket(path, script);
  const info = { id: "r", runner: 1, pid: 2, pgid: 3, startedAt: 0, program: "x", args: [], socket: path };
  world({});
  const lines: Json[] = [];
  let exit!: Awaited<RunnerConnection["exited"]>;
  try {
    const conn = new RunnerConnection(info as RunnerInfo, async (stream, text, from, to) => void lines.push([stream, text, from, to]));
    conn.keep = 42;
    exit = await conn.exited;
    await settle();
    conn.write("hello ✓\n");
    conn.closeStdin();
    conn.signal("INT", false);
    conn.signal("KILL");
    conn.done();
    await settle();
  } finally {
    await close();
  }
  const said = await mb({
    op: "runnerConn",
    info,
    keep: 42,
    sockets: { [path]: script },
    acts: [{ do: "write", text: "hello ✓\n" }, { do: "closeStdin" }, { do: "signal", signal: "INT", group: false }, { do: "signal", signal: "KILL" }, { do: "done" }],
  });
  assert.deepEqual(said, { lines, exit: plain(exit), told });
});

test("where a runner left off: its attach answered, its output's size where it says nothing, and its output read again", { skip, timeout: 15_000 }, async () => {
  const root = fresh();
  const file = join(root, "o.out");
  put(file, Buffer.concat([Buffer.alloc(5, 0), Buffer.from("cut\nline one\r\n"), Buffer.from("x".repeat(30)), Buffer.from("\nlast")]));
  const scripts: [string, string[]][] = [
    ["attached", [JSON.stringify({ op: "attached", out: 40, keep: 60 })]],
    ["attached-low", [JSON.stringify({ op: "attached", out: 40, keep: 12 })]],
    ["out", [JSON.stringify({ op: "out", stream: "err", at: 1, data: "" }), JSON.stringify({ op: "out", stream: "out", at: 33, data: "" })]],
    ["exit", [JSON.stringify({ op: "exit", code: 0, signal: null })]],
    ["quiet", []],
  ];
  for (const [name, script] of scripts) {
    const path = join(root, `${name}.sock`);
    const { told, close } = await runnerSocket(path, script);
    const info = { id: name, runner: 1, pid: 2, pgid: 3, startedAt: 0, program: "x", args: [], socket: path };
    world({});
    let ts: Awaited<ReturnType<typeof ackedOffset>>;
    try {
      const answer = ackedOffset(info as RunnerInfo, file);
      if (name === "quiet") {
        // The socket's attach and the output's stat are real I/O: the clock is moved on only once each has landed.
        await until(() => told.length > 0, "the attach");
        await time.advance(400);
        await until(() => time.timers.length > 0, "the quiet timer after the output's size");
        await time.advance(150);
      }
      ts = await answer;
    } finally {
      await close();
    }
    const said = await harness().next(JSON.stringify({ op: "ackedOffset", info, out: file, sockets: { [path]: script }, fs: snap(root) }));
    assert.deepEqual(said.ok, [ts.at, ts.keep], name);
    assert.deepEqual(said.told[0].told, told, `${name}: what it was told`);
  }
  // None listening there: the output's size.
  world({});
  const none = { id: "n", runner: 1, pid: 2, pgid: 3, startedAt: 0, program: "x", args: [], socket: join(root, "none.sock") };
  const ts = await ackedOffset(none as RunnerInfo, file);
  assert.deepEqual(await mb({ op: "ackedOffset", info: none, out: file, fs: snap(root) }), [ts.at, ts.keep]);
  for (const [start, end, chunk] of [[0, 60, 1 << 20], [0, 60, 7], [9, 60, 4], [0, 3, 1 << 20], [5, 5, 10]] as const) {
    const lines: Json[] = [];
    for await (const l of bytesWithin(file, start, end, chunk)) lines.push([l.bytes.toString("base64"), l.at]);
    assert.deepEqual(await mb({ op: "bytesWithin", file, start, end, chunk, fs: snap(root) }), lines, `${start}..${end} by ${chunk}`);
  }
});

test("a runner an earlier station left ended: asked to stop, killed where its group goes on, waited for", { skip, timeout: 15_000 }, async () => {
  const data = fresh();
  const dir = join(data, "run", "runners");
  const sock = join(dir, "claude-x.sock");
  const info = { id: "claude-x", runner: 8001, pid: 8002, pgid: 8003, startedAt: 1000, program: "claude", args: [], socket: sock };
  mkdirSync(dir, { recursive: true });
  put(join(dir, "claude-x.json"), JSON.stringify(info));
  for (const [name, script, others] of [
    ["exits", [JSON.stringify({ op: "exit", code: null, signal: "TERM" })], [8001]],
    ["holds", [], [8001, -8003]],
  ] as const) {
    const { told, close } = await runnerSocket(sock, [...script]);
    const c = { alive: [...others], data, fs: snap(data), sockets: { [sock]: script } };
    world(c);
    let ts: Awaited<ReturnType<typeof endRunner>>;
    try {
      const ended = endRunner(data, "claude-x", "label");
      let done = false;
      void ended.then(() => (done = true));
      // What it reads of the runner's files and says on its socket is real I/O: the clock is moved on only once what it
      // waits for has landed. Its TERM and attach first; a runner that holds is waited for (2 s), then KILLed (1 s more).
      await until(() => told.length >= 2, "the TERM and the attach");
      if (script.length === 0) {
        await time.advance(2000);
        await until(() => told.length >= 3, "the KILL");
        await time.advance(1000);
      }
      await until(() => told.some((m) => m.op === "done"), "the done");
      // (its process goes once it was told to: the case's runner leaves it)
      alive.clear();
      while (!done) await time.advance(10);
      ts = await ended;
    } finally {
      await close();
    }
    const said = await harness().next(JSON.stringify({ ...c, op: "endRunner", id: "claude-x" }));
    assert.equal(said.ok, ts, name);
    assert.deepEqual(said.told[0].told, told, `${name}: what it was told`);
    rmSync(sock, { force: true });
  }
  world({ alive: [8001] });
  assert.equal(await endRunner(data, "claude-x", "label", { ...info, startedAt: 5 } as RunnerInfo), await mb({ op: "endRunner", alive: [8001], data, fs: snap(data), id: "claude-x", only: { ...info, startedAt: 5 } }));
});

// ── the drivers: the program as a fake of mb-agents.ts, both sides through the same steps ──

/// The program as a case has it: what it is told, a process started as recorded, each request answered by the
/// case's replies a turn of the loop later, a process ending on TERM.
class Program {
  posts: Json[] = [];
  starts: Json[] = [];
  replays: Json[] = [];
  procs = new Map<number, HostedProcess>();
  tos = new Map<number, number>();
  replies: Map<string, Json[]>;
  replayed: Json;
  #n = 0;
  constructor(c: Json) {
    this.replies = new Map(Object.entries(structuredClone(c.replies ?? {})) as [string, Json[]][]);
    this.replayed = c.replayOwn ?? {};
  }
  use() {}
  get closed() {
    return false;
  }
  number() {
    return this.#n++;
  }
  program() {
    return null;
  }
  attach(p: HostedProcess) {
    this.procs.set(p.n, p);
  }
  forget() {}
  async freeze() {}
  thaw() {}
  async close() {}
  replay() {
    const runs: Json[][][] = [];
    return { feed: (notices: Json[][]) => void runs.push(notices), done: async () => (this.replays.push({ runs }), this.replayed), close: () => {} };
  }
  async replayOwn(kind: string, file: string, at: number, extra: Json) {
    this.replays.push(plain({ kind, file, at, extra }));
    return this.replayed;
  }
  post(m: Json) {
    this.posts.push(plain(m));
    const p = this.procs.get(m.write ?? m.signal ?? -1);
    if (p === undefined) return;
    if (m.signal !== undefined && m.name === "TERM") setImmediate(() => void p.exited_(null, "TERM", ""));
    if (m.write === undefined) return;
    let msg: Json;
    try {
      msg = JSON.parse(m.line);
    } catch {
      return;
    }
    if (typeof msg?.method !== "string" || msg.id === undefined || msg.id === null) return;
    const queue = this.replies.get(msg.method);
    if (queue === undefined || queue.length === 0) return;
    const reply = queue.length > 1 ? queue.shift() : queue[0];
    const text = JSON.stringify({ ...(p.kind === "acp" ? { jsonrpc: "2.0", id: msg.id } : { id: msg.id }), ...reply });
    setImmediate(() => {
      const from = this.tos.get(p.n) ?? 0;
      const to = from + Buffer.byteLength(text) + 1;
      this.tos.set(p.n, to);
      p.heard({ events: [], to, lines: [{ text, from, to }] } as never);
    });
  }
}

const realAdopt = HostedProcess.adopt.bind(HostedProcess);
let current: Program | null = null;
mock.method(HostedProcess, "start", async (host: never, _data: string, id: string, program: string, args: string[], env: Record<string, string>, cwd: string, options: Json, turn: Json) => {
  const k = current!.procs.size;
  current!.starts.push(plain({ id, program, args, env, cwd, label: options.label, kind: options.kind ?? "claude", turn: turn ?? null }));
  const info = { id, runner: 900000 + k, pid: 910000 + k, pgid: 920000 + k, startedAt: 0, program, args, socket: "" };
  return realAdopt(host, info as RunnerInfo, options, turn, null);
});
mock.method(HostedProcess, "adopt", (host: never, info: RunnerInfo, options: Json, turn: Json, live: Json) => {
  current!.starts.push(plain({ adopt: info.id, label: options.label, kind: options.kind ?? "claude", turn: turn ?? null, live: live ?? null }));
  return realAdopt(host, info, options, turn, live);
});

const WORDS = { repoRules: REPO_RULES_COMMAND, agyRepoRules: AGY_REPO_RULES_COMMAND, subagentHook: hookCommand(SUBAGENT_HOOK, SLACK_SPOKEN.join(",")), speaks: SPEAKS, speaksWriting: SPEAKS_WRITING };

/// What a case says of its profiles: each one's variables for each runtime, and Codex's overrides of it.
function profilesOf(profiles: Json[]) {
  return Object.fromEntries(
    profiles.map((p) => [
      p.id,
      {
        env: Object.fromEntries(["claude", "codex", "agy"].map((r) => [r, profileEnv(p, r as never)])),
        codexOverrides: codexOverrides(accessKind(p), profileModel(p), profileVia(p)),
      },
    ]),
  );
}

/// A step's outcome as the harness says it.
const outcome = async (f: () => unknown): Promise<Json> => {
  let r: Json;
  try {
    r = { ok: plain(await f()) };
  } catch (e) {
    r = { error: (e as Error).message };
  }
  await settle();
  return r;
};

/// The TypeScript's driver through a case's steps: what each returned, the events of each session, the program's.
async function runTs(c: Json, make: (program: Program) => Json, step: (driver: Json, st: Json, sessions: Json[], k: number, events: (e: Json) => void) => unknown) {
  world(c);
  const program = new Program(c);
  current = program;
  const driver = make(program);
  const sessions: Json[] = [];
  const results: Json[] = [];
  const events: Json[] = [];
  let opened = 0;
  for (const st of c.steps) {
    if (st.do === "hear") {
      const p = program.procs.get(st.proc)!;
      results.push(await outcome(async () => {
        p.heard(structuredClone(st.heard));
        await p.drained();
        return null;
      }));
    } else if (st.do === "exit") results.push(await outcome(() => program.procs.get(st.proc)!.exited_(st.code ?? null, st.signal ?? null, st.stderr ?? "")).then((r) => ("ok" in r ? { ok: null } : r)));
    else if (st.do === "advance") {
      await time.advance(st.ms);
      results.push({ ok: null });
    } else {
      const k = opened;
      if (["open", "adopt", "catalog"].includes(st.do)) opened++;
      results.push(await outcome(() => step(driver, st, sessions, k, (e) => events.push({ s: k, e: plain(e) }))));
    }
  }
  await settle();
  return { driver, trace: { results, events, starts: program.starts, posts: program.posts, replays: program.replays, fs: c.dump === undefined ? null : dump(c.dump) } };
}

/// MoonBit's: its trace, a said key as the station's words say it.
async function runMb(c: Json) {
  const said = await mb(c);
  said.results = said.results.map((r: Json) => ("said" in r ? { error: tr(stationLang(), r.said) } : r));
  return said;
}

function compare(name: string, mbTrace: Json, ts: Json) {
  for (const k of ["results", "starts", "posts", "events", "replays", "fs"]) assert.deepEqual(mbTrace[k], ts[k], `${name}: ${k}`);
}

/// A case's common parts: its profiles, environment, words.
function common(extra: Json) {
  return { env: Object.fromEntries(Object.entries({ ...process.env, ...agentEnv() }).filter(([, v]) => v !== undefined)), words: WORDS, now: 1_800_000_000_000, ...extra };
}

// ── Claude Code ──

function claudeOptions(data: string, profile: Json, extra: Json = {}) {
  return { key: "slack:T1:C1:1700000000.0001", profile, cwd: data, instructions: "be brief", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r1", ...extra };
}

async function claudeCase(name: string, setup: (data: string) => { profiles: Json[]; steps: Json[]; logins?: Json; replayOwn?: Json; alive?: number[]; sockets?: Record<string, string[]> }) {
  const data = fresh();
  const s = setup(data);
  const servers = await Promise.all(Object.entries(s.sockets ?? {}).map(([p, script]) => runnerSocket(p, script)));
  const c = { ...common({ data, dump: data, ids: ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"] }), op: "claude", profiles: profilesOf(s.profiles), steps: s.steps, logins: s.logins ?? {}, replayOwn: s.replayOwn, alive: s.alive, sockets: s.sockets ?? {}, fs: snap(data) };
  const asked: Json[] = [];
  const renewer = (name: string) => {
    let at = 0;
    return async (rejected?: string) => {
      asked.push({ renewer: name, rejected: rejected ?? null });
      const list: Json[] = c.logins[name] ?? [];
      const g = list[Math.min(at++, list.length - 1)] ?? { error: "no token" };
      if (g.error !== undefined) {
        const { RenewRefused } = await import("../src/accounts/console.ts");
        throw g.refused ? new RenewRefused(401, g.error) : new Error(g.error);
      }
      return { token: g.token, expiresAt: g.expiresAt ?? 0 };
    };
  };
  const machine = renewer("machine");
  const subscription = renewer("subscription");
  const lent = renewer("lent");
  const { trace } = await runTs(
    c,
    (program) => {
      return new ClaudeDriver({
        data,
        machineToken: (_env, rejected) => machine(rejected),
        subscriptionToken: c.logins.subscription === undefined ? undefined : (_p, rejected) => subscription(rejected),
        lent: { borrowed: (p) => (c.logins.borrowed ?? []).includes(p.id), token: (_p, rejected) => lent(rejected) },
        agents: program as never,
      });
    },
    async (driver, st, sessions, _k, events) => {
      const session = sessions[st.s];
      switch (st.do) {
        case "open": {
          const x = await driver.open(st.options, events);
          sessions.push(x);
          return x.id();
        }
        case "adopt": {
          const x = await driver.adopt(st.options, st.snapshot ?? null, events);
          sessions.push(x);
          return { id: x.id(), busy: x.busy(), mcpUrl: x.mcpUrl() };
        }
        case "prompt":
          return session.prompt(st.text).then(() => null);
        case "compact":
          return session.compact().then(() => null);
        case "steer":
          return session.steer(st.text);
        case "backgroundTools":
          return session.backgroundTools().then(() => null);
        case "abort":
          return session.abort().then(() => null);
        case "retune":
          return session.retune(st.options);
        case "background":
          return session.background();
        case "snapshot":
          return session.snapshot();
        case "dispose":
          return session.dispose().then(() => null);
        case "detach":
          return (session.detach(), null);
        case "busy":
          return session.busy();
        case "ownedRunners":
          return [...driver.ownedRunners()];
        case "shutdown":
          return driver.shutdown().then(() => null);
      }
      throw new Error(`no such step: ${st.do}`);
    },
  );
  // (a case that threw before here leaves them to the file's after())
  for (const s of servers) await s.close();
  const said = await runMb(c);
  compare(name, said, trace);
  assert.deepEqual(said.asked, asked, `${name}: the logins asked`);
  return trace;
}

const cc = (home: string, extra: Json = {}) => ({ id: "cc", runtime: "claude", home, access: { kind: "opencode-go", key: "k1" }, env: { EXTRA: "1" }, ...extra });

test("Claude Code: its process's arguments, settings and environment, a turn, a steer, an interrupt, a compaction, its model, Ctrl+B, its end", { skip }, async () => {
  await claudeCase("claude turns", (data) => {
    const home = join(data, "h1");
    const p = cc(home, { model: "claude-sonnet-5-5" });
    const o = claudeOptions(data, p, { effort: "high", context: 300000 });
    return {
      profiles: [p],
      steps: [
        { do: "open", options: o },
        { do: "steer", s: 0, text: "not yet" },
        { do: "prompt", s: 0, text: "hello" },
        { do: "prompt", s: 0, text: "again" },
        { do: "steer", s: 0, text: "and this" },
        { do: "backgroundTools", s: 0 },
        { do: "abort", s: 0 },
        { do: "abort", s: 0 },
        { do: "hear", proc: 0, heard: { events: [{ type: "live", event: { kind: "phase", phase: "working" } }, { type: "turnEnded", outcome: { kind: "aborted" }, turn: { busy: false, aborting: false, authFailure: null, renews: false } }], turn: { busy: false, aborting: false, authFailure: null, renews: false }, to: 10 } },
        { do: "busy", s: 0 },
        { do: "retune", s: 0, options: { ...o, model: "claude-opus-5-5" } },
        { do: "retune", s: 0, options: { ...o, effort: "low" } },
        { do: "compact", s: 0 },
        { do: "hear", proc: 0, heard: { events: [{ type: "compacted" }, { type: "turnEnded", outcome: { kind: "completed" } }], turn: { busy: false, aborting: false, authFailure: null, tasks: { t: { id: "t", kind: "agent", description: "d", background: true } } }, to: 20 } },
        { do: "background", s: 0 },
        { do: "snapshot", s: 0 },
        { do: "prompt", s: 0, text: "after a snapshot" },
        { do: "ownedRunners" },
      ],
    };
  });
});

test("Claude Code: a text-only session, a session continued from a terminal, a Kimi key read from its file, Fast", { skip }, async () => {
  await claudeCase("claude kinds", (data) => {
    const kimi = { id: "kimi", runtime: "claude", home: join(data, "h2"), access: { kind: "api-provider", provider: "kimi-code", login: true, key: "k" } };
    const anth = { id: "anth", runtime: "claude", home: join(data, "h3"), access: { kind: "anthropic-api", key: "sk" }, fast: true };
    return {
      profiles: [kimi, anth],
      steps: [
        { do: "open", options: claudeOptions(data, kimi, { textOnly: true, key: "k-text" }) },
        { do: "open", options: claudeOptions(data, anth, { instructions: "", key: "k-term" }) },
        { do: "open", options: claudeOptions(data, anth, { fast: false, key: "k-slow" }) },
        { do: "retune", s: 2, options: claudeOptions(data, anth, { fast: true, model: "m" }) },
        { do: "retune", s: 2, options: claudeOptions(data, anth, { fast: false, model: "m" }) },
        { do: "exit", proc: 1, code: 1, signal: null, stderr: "boom" },
        { do: "prompt", s: 1, text: "closed" },
        { do: "dispose", s: 0 },
      ],
    };
  });
});

test("Claude Code: a machine login's token handed over and renewed as it asks; a subscription that fails to renew; a lent one", { skip }, async () => {
  await claudeCase("claude tokens", (data) => {
    const machine = { id: "m", runtime: "claude", home: join(data, "hm"), machine: true };
    const sub = { id: "sub", runtime: "claude", home: join(data, "hs"), access: { kind: "subscription" } };
    const sub2 = { id: "sub2", runtime: "claude", home: join(data, "hs2"), access: { kind: "subscription" } };
    const borrowed = { id: "lent", runtime: "claude", home: join(data, "hl"), access: { kind: "subscription" } };
    put(join(sub.home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "kept-sub" } }));
    put(join(sub2.home, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "kept-sub2" } }));
    return {
      profiles: [machine, sub, sub2, borrowed],
      logins: {
        machine: [{ token: "m1", expiresAt: 5 }, { token: "m2", expiresAt: 9 }, { token: "m2", expiresAt: 9 }],
        subscription: [{ error: "refused", refused: true }, { error: "network" }],
        lent: [{ token: "l1" }, { error: "gone" }],
        borrowed: ["lent"],
      },
      steps: [
        { do: "open", options: claudeOptions(data, machine, { key: "km" }) },
        { do: "prompt", s: 0, text: "go" },
        { do: "hear", proc: 0, heard: { events: [{ type: "renew", requestId: "r1" }], turn: { busy: true, aborting: false, authFailure: null, renews: true }, to: 5 } },
        { do: "hear", proc: 0, heard: { events: [{ type: "renew", requestId: "r2" }], to: 9 } },
        { do: "open", options: claudeOptions(data, sub, { key: "ks" }) },
        { do: "open", options: claudeOptions(data, sub2, { key: "ks2" }) },
        { do: "open", options: claudeOptions(data, borrowed, { key: "kl" }) },
        { do: "hear", proc: 3, heard: { events: [{ type: "renew", requestId: "r3" }], to: 3 } },
      ],
    };
  });
});

test("Claude Code: a session resumed, its transcript brought to where --resume looks, one missing refused; taken up handed over and after a crash", { skip }, async () => {
  await claudeCase("claude resume", (data) => {
    const home = join(data, "hr");
    const p = cc(home);
    const id = "44444444-4444-4444-8444-444444444444";
    put(join(home, "projects", "-elsewhere", `${id}.jsonl`), "{}\n");
    const runners = join(data, "run", "runners");
    const keyA = "slack:T1:C9:1";
    const idA = `claude-${keyPart(keyA)}`;
    const sockA = join(runners, `${idA}.sock`);
    const infoA = { id: idA, runner: 7100, pid: 7101, pgid: 7102, startedAt: 0, program: "claude", args: ["-p", "--resume", id, "--effort", "low", "--mcp-config", JSON.stringify({ mcpServers: { stillfail: { url: "http://old/mcp" } } }), "--settings", JSON.stringify({ fastMode: true })], socket: sockA };
    put(join(runners, `${idA}.json`), JSON.stringify(infoA));
    const keyB = "slack:T1:C9:2";
    const idB = `claude-${keyPart(keyB)}`;
    const sockB = join(runners, `${idB}.sock`);
    const infoB = { ...infoA, id: idB, runner: 7200, args: ["-p", "--session-id", "sess-b"], socket: sockB };
    put(join(runners, `${idB}.json`), JSON.stringify(infoB));
    const snapshot = { runtime: "claude", id, runner: idA, turn: { busy: true, aborting: false, authFailure: null, renews: true }, machineExpires: null, live: { message: "m", blocks: [], tools: [] } };
    return {
      profiles: [p],
      alive: [7100, 7200],
      sockets: { [sockA]: [], [sockB]: [JSON.stringify({ op: "attached", out: 77 })] },
      replayOwn: { turn: { busy: true, tasks: {} }, live: { message: "x", blocks: [], tools: [] } },
      steps: [
        { do: "open", options: claudeOptions(data, p, { resume: id, key: "k1" }) },
        { do: "open", options: claudeOptions(data, p, { resume: "55555555-5555-4555-8555-555555555555", key: "k2" }) },
        { do: "adopt", options: claudeOptions(data, p, { key: keyA }), snapshot },
        { do: "adopt", options: claudeOptions(data, p, { key: keyB }) },
        { do: "adopt", options: claudeOptions(data, p, { key: "slack:none" }) },
        { do: "snapshot", s: 1 },
      ],
    };
  });
});

/// A profile's own proxy, its NO_PROXY naming only what it knows: this machine, where the station's tools are, left out.
const PROFILE_PROXY = { HTTPS_PROXY: "http://127.0.0.1:7890", NO_PROXY: "corp.example" };
const KEPT_LOCAL = "corp.example,localhost,127.0.0.1,::1";
const keptLocal = (trace: Json, name: string) => {
  const started = trace.starts.filter((st: Json) => st.env !== undefined);
  assert.ok(started.length > 0, `${name}: a process started`);
  for (const st of started) assert.deepEqual([st.env.NO_PROXY, st.env.no_proxy], [KEPT_LOCAL, KEPT_LOCAL], `${name}: this machine left out of the profile's proxy`);
};

test("Claude Code: a profile's own proxy leaves this machine out of it", { skip }, async () => {
  const trace = await claudeCase("claude proxied", (data) => {
    const p = cc(join(data, "hp"), { env: { EXTRA: "1", ...PROFILE_PROXY } });
    return { profiles: [p], steps: [{ do: "open", options: claudeOptions(data, p) }] };
  });
  keptLocal(trace, "claude proxied");
});

// ── Codex ──

const codexProfile = (home: string, extra: Json = {}) => ({ id: "cx", runtime: "codex", home, access: { kind: "subscription" }, ...extra });
const thread = (id: string, path?: string) => ({ result: { thread: { id, ...(path === undefined ? {} : { path }) } } });
const INIT = { initialize: [{ result: { userAgent: "stillfail/0.169.0 (Mac OS 15; arm64) x" } }] };

async function codexCase(name: string, setup: (data: string) => { profiles: Json[]; steps: Json[]; replies: Json; world?: Json; alive?: number[]; sockets?: Record<string, string[]>; replayOwn?: Json }) {
  const data = fresh();
  const s = setup(data);
  const hostSkills = join(data, "skills");
  const w = { hostSkills, caBundle: join(data, "ca.pem"), installed: "0.169.0", warmMs: 1_800_000, ...(s.world ?? {}) };
  const skills = (w.skills ?? []).map((p: string) => join(hostSkills, p));
  for (const p of skills) put(p, "skill");
  const servers = await Promise.all(Object.entries(s.sockets ?? {}).map(([p, script]) => runnerSocket(p, script)));
  const c = { ...common({ data, ids: [] }), op: "codex", profiles: profilesOf(s.profiles), steps: s.steps, replies: s.replies, world: { ...w, skills, agentEnv: AGENT_ENV }, alive: s.alive, sockets: s.sockets ?? {}, replayOwn: s.replayOwn, fs: snap(data) };
  const asked: Json[] = [];
  const clock = { ...liveClock, currentTimeMillisUnsafe: () => time.now, sleep: () => Effect.never } as never;
  const { trace, driver } = await runTs(
    c,
    (program) => {
      return new CodexDriver({
        data,
        hostSkills,
        caBundle: w.caBundle,
        fast: (t) => w.fasts?.[t],
        speed: (t) => w.speeds?.[t] ?? null,
        currentProfile: w.currentProfiles === undefined ? undefined : (id) => w.currentProfiles[id],
        lent: { borrowed: (p) => (w.borrowed ?? []).includes(p.id), write: async (p) => (asked.push({ lentWrite: p.id }), w.lentUntil ?? 0) },
        installedVersion: async () => (asked.push({ installed: true }), w.installed ?? null),
        missingHost: async (command: string, env: Json) => (asked.push({ missingHost: command, CODEX_HOME: env.CODEX_HOME ?? null }), w.missingHost === true ? ("x" as never) : null),
        incompleteInstallation: () => void asked.push({ incomplete: true }),
        agents: program as never,
        outputLimit: w.outputLimit,
        takeUpBytes: w.takeUpBytes,
        taking: () => void asked.push({ taking: true }),
        clock,
        warmMs: w.warmMs,
      });
    },
    async (driver, st, sessions, _k, events) => {
      const session = sessions[st.s];
      switch (st.do) {
        case "open": {
          const x = await driver.open(st.options, events);
          sessions.push(x);
          return x.id();
        }
        case "adopt": {
          const x = await driver.adopt(st.options, st.snapshot ?? null, events);
          sessions.push(x);
          return { id: x.id(), busy: x.busy(), mcpUrl: x.mcpUrl() };
        }
        case "prompt":
          return session.prompt(st.text).then(() => null);
        case "compact":
          return session.compact().then(() => null);
        case "steer":
          return session.steer(st.text);
        case "abort":
          return session.abort().then(() => null);
        case "retune":
          return session.retune(st.options);
        case "snapshot":
          return session.snapshot();
        case "dispose":
          return session.dispose().then(() => null);
        case "detach":
          return (session.detach(), null);
        case "busy":
          return session.busy();
        case "version":
          return session.runtimeVersion();
        case "models":
          return driver.models(st.profile).then((m: ModelCatalog) => ({ models: m.models, efforts: Object.fromEntries(m.efforts), defaults: Object.fromEntries(m.defaults) }));
        case "rateLimits":
          return driver.rateLimits(st.profile);
        case "resetQuota":
          return driver.resetQuota(st.profile, st.key);
        case "renewLogin":
          return driver.renewLogin(st.profileId);
        case "loginChanged":
          return driver.loginChanged(st.profileId).then(() => null);
        case "runtimeChanged":
          return driver.runtimeChanged(st.replaced === true, st.drainBusy === true).then(() => null);
        case "evictIdle":
          return driver.evictIdle();
        case "ownedRunners":
          return [...driver.ownedRunners()];
        case "shutdown":
          return driver.shutdown(st.again === true).then(() => null);
      }
      throw new Error(`no such step: ${st.do}`);
    },
  );
  void driver;
  // (a case that threw before here leaves them to the file's after())
  for (const s of servers) await s.close();
  const said = await runMb(c);
  compare(name, said, trace);
  assert.deepEqual(said.asked, asked, `${name}: what the driver asked`);
  return trace;
}

test("Codex: an app-server started and initialized, a thread started with the station's tools, a turn on a subscription's speeds, steer, interrupt, compact, retune, its end", { skip }, async () => {
  await codexCase("codex turns", (data) => {
    const home = join(data, "cx");
    const p = codexProfile(home, { model: "gpt-6", fast: true });
    const o = { key: "chat:1", profile: p, cwd: data, instructions: "be brief", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r", effort: "high", context: 200000 };
    return {
      profiles: [p],
      world: { skills: ["a/SKILL.md", "b/c/SKILL.md"], speeds: { t1: "fast" }, fasts: {} },
      replies: {
        ...INIT,
        "thread/start": [thread("t1", join(home, "sessions", "2026", "rollout-x-t1.jsonl")), thread("t2", "/elsewhere/rollout-t2.jsonl")],
        "mcpServerStatus/list": [{ result: { data: [{ name: "stillfail", runtimeStatus: "ready" }] } }],
        "turn/start": [{ result: { turn: { id: "turn-1" } } }, { error: { code: 1, message: "busy" } }, { result: { turn: { id: "turn-3" } } }],
        "turn/steer": [{ result: {} }, { error: { message: "no" } }],
        "turn/interrupt": [{ result: {} }],
        "thread/compact/start": [{ result: {} }],
        "thread/unsubscribe": [{ result: {} }],
        "model/list": [{ result: { data: [{ id: "gpt-6", supportedReasoningEfforts: [{ reasoningEffort: "high" }] }], nextCursor: "c2" } }, { result: { data: [{ id: "gpt-5" }], nextCursor: "" } }],
        "account/rateLimits/read": [{ result: { primary: { usedPercent: 5 } } }],
        "account/rateLimitResetCredit/consume": [{ error: { message: "none left" } }],
        "account/read": [{ result: {} }],
      },
      steps: [
        { do: "open", options: o },
        { do: "version", s: 0 },
        { do: "prompt", s: 0, text: "hi" },
        { do: "steer", s: 0, text: "more" },
        { do: "steer", s: 0, text: "refused" },
        { do: "abort", s: 0 },
        { do: "prompt", s: 0, text: "while busy" },
        { do: "hear", proc: 0, heard: { events: [], to: 4000, threads: [{ thread: "t1", events: [{ type: "live", event: { kind: "phase", phase: "working" } }, { type: "turnEnded", outcome: { kind: "aborted" }, from: 100, to: 3000 }], live: { open: [], phase: null } }], marks: [["other", 1, 50, 60]] } },
        { do: "retune", s: 0, options: { ...o, model: "gpt-6", effort: "high" } },
        { do: "retune", s: 0, options: { ...o, model: "gpt-5", effort: "low" } },
        { do: "prompt", s: 0, text: "failing start" },
        { do: "prompt", s: 0, text: "on gpt-5" },
        { do: "hear", proc: 0, heard: { events: [], to: 5000, threads: [{ thread: "t1", events: [{ type: "turnStarted", turnId: "turn-3", from: 4100, to: 4200 }, { type: "turnEnded", outcome: { kind: "completed" }, from: 4300, to: 4900 }], live: { open: [], phase: null } }] } },
        { do: "compact", s: 0 },
        { do: "open", options: { ...o, key: "chat:2", effort: undefined, instructions: "" } },
        { do: "models", profile: p },
        { do: "rateLimits", profile: p },
        { do: "resetQuota", profile: p, key: "idem" },
        { do: "renewLogin", profileId: "cx" },
        { do: "renewLogin", profileId: "none" },
        { do: "snapshot", s: 1 },
        { do: "ownedRunners" },
      ],
    };
  });
});

test("Codex: Ultrafast refused off a subscription; standard and the profile's Fast as the service tier; a thread whose tools failed resumed again; one missing its host", { skip }, async () => {
  await codexCase("codex speeds", (data) => {
    const sub = codexProfile(join(data, "cs"));
    const key = { id: "ck", runtime: "codex", home: join(data, "ck"), access: { kind: "opencode-go", key: "k" }, model: "kimi" };
    const o = (p: Json, extra: Json = {}) => ({ key: `chat:${p.id}`, profile: p, cwd: data, instructions: "be brief", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r", ...extra });
    return {
      profiles: [sub, key],
      world: { speeds: { t1: "standard", t2: "ultrafast", t3: "ultrafast" }, fasts: {} },
      replies: {
        ...INIT,
        "thread/start": [thread("t2"), thread("t3")],
        "thread/resume": [thread("t1"), thread("t1")],
        "thread/unsubscribe": [{ result: {} }],
        "mcpServerStatus/list": [{ result: { data: [{ name: "stillfail", runtimeStatus: "failed" }] } }, { result: { data: [] } }],
        "turn/start": [{ result: { turn: { id: "x" } } }],
      },
      steps: [
        { do: "open", options: o(sub, { resume: "t1" }) },
        { do: "prompt", s: 0, text: "standard" },
        { do: "open", options: o(sub) },
        { do: "prompt", s: 1, text: "ultrafast on a subscription" },
        { do: "open", options: o(key) },
        { do: "prompt", s: 2, text: "ultrafast on a key" },
      ],
    };
  });
  await codexCase("codex missing host", (data) => {
    const p = codexProfile(join(data, "cm"));
    return { profiles: [p], world: { missingHost: true }, replies: {}, steps: [{ do: "open", options: { key: "k", profile: p, cwd: data, instructions: "x", mcpToken: "t", mcpUrl: "http://h/mcp", route: "r" } }] };
  });
});

test("Codex: an app-server whose thread could not reach the station's tools is replaced for a thread opened again with the same address, kept for another", { skip }, async () => {
  await codexCase("codex tools unreachable", (data) => {
    const p = codexProfile(join(data, "cu"));
    const o = (key: string, mcpUrl: string) => ({ key, profile: p, cwd: data, instructions: "x", mcpToken: "t", mcpUrl, route: "r" });
    const failed = { result: { data: [{ name: "stillfail", runtimeStatus: "failed" }] } };
    return {
      profiles: [p],
      replies: {
        ...INIT,
        "thread/start": [thread("t1"), thread("t2"), thread("t3"), thread("t4")],
        "thread/unsubscribe": [{ result: {} }],
        "mcpServerStatus/list": [failed, { result: { data: [] } }, failed, { result: { data: [] } }],
        "turn/start": [{ result: { turn: { id: "u1" } } }],
      },
      steps: [
        // The door not yet open at its first address: another address is opened on the same app-server.
        { do: "open", options: o("k1", "http://127.0.0.1:1/mcp") },
        { do: "prompt", s: 0, text: "x" },
        { do: "dispose", s: 0 },
        { do: "open", options: o("k1", "http://h/mcp") },
        { do: "prompt", s: 1, text: "x" },
        // That app-server fails the open door's address: opened again with it, the thread goes to a new one.
        { do: "open", options: o("k2", "http://h/mcp") },
        { do: "prompt", s: 2, text: "x" },
        { do: "dispose", s: 2 },
        { do: "open", options: o("k2", "http://h/mcp") },
        { do: "prompt", s: 3, text: "x" },
      ],
    };
  });
});

test("Codex: a text-only thread with every MCP server off, opened again where its directory adds one", { skip }, async () => {
  await codexCase("codex text only", (data) => {
    const p = codexProfile(join(data, "ct"));
    const o = { key: "k", profile: p, cwd: data, instructions: "", mcpToken: "", mcpUrl: "", route: "r", textOnly: true };
    return {
      profiles: [p],
      replies: {
        ...INIT,
        "mcpServerStatus/list": [
          { result: { data: [{ name: "github", runtimeStatus: "ready" }], nextCursor: "n" } },
          { result: { data: [{ name: "linear", runtimeStatus: "ready" }] } },
          { result: { data: [{ name: "github", runtimeStatus: "disabled" }, { name: "extra", runtimeStatus: "ready" }] } },
          { result: { data: [{ name: "github", runtimeStatus: "disabled" }, { name: "extra", runtimeStatus: "disabled" }] } },
        ],
        "thread/start": [thread("t-a"), thread("t-b")],
        "thread/unsubscribe": [{ result: {} }],
      },
      steps: [{ do: "open", options: o }],
    };
  });
});

test("Codex: the app-server asks something (refused), says a turn's error, exits under a turn; a sign-in changed; Codex updated; idle ended", { skip }, async () => {
  await codexCase("codex host", (data) => {
    const p = codexProfile(join(data, "ch"));
    const o = { key: "k", profile: p, cwd: data, instructions: "x", mcpToken: "t", mcpUrl: "http://h/mcp", route: "r" };
    return {
      profiles: [p],
      world: { warmMs: 60_000 },
      replies: {
        ...INIT,
        "thread/start": [thread("t1"), thread("t2"), thread("t3"), thread("t4")],
        "mcpServerStatus/list": [{ result: { data: [] } }],
        "turn/start": [{ result: { turn: { id: "u1" } } }],
        "thread/unsubscribe": [{ result: {} }],
      },
      steps: [
        { do: "open", options: o },
        { do: "prompt", s: 0, text: "go" },
        { do: "hear", proc: 0, heard: { events: [], to: 900, lines: [{ text: JSON.stringify({ id: 77, method: "item/commandExecution/requestApproval", params: {} }), from: 0, to: 10 }, { text: JSON.stringify({ method: "error", params: { threadId: "t1", error: { message: "x" } } }), from: 10, to: 20 }, { text: JSON.stringify({ id: 999, result: {} }), from: 20, to: 30 }, { text: "garbage", from: 30, to: 40 }] } },
        { do: "exit", proc: 0, code: 1, signal: null, stderr: "panic" },
        { do: "open", options: { ...o, key: "k2" } },
        { do: "loginChanged", profileId: "cx" },
        { do: "open", options: { ...o, key: "k3" } },
        { do: "runtimeChanged", replaced: true },
        { do: "open", options: { ...o, key: "k4" } },
        { do: "evictIdle" },
        { do: "shutdown" },
        { do: "open", options: { ...o, key: "k5" } },
      ],
    };
  });
});

test("Codex: a thread taken up handed over, and after a crash from what the station before had handled of the app-server's output", { skip }, async () => {
  await codexCase("codex adopt", (data) => {
    const p = codexProfile(join(data, "ca"));
    const runners = join(data, "run", "runners");
    const id = runnerId("codex", "cx");
    const sock = join(runners, `${id}.sock`);
    const info = { id, runner: 7300, pid: 7301, pgid: 7302, startedAt: 10, program: "codex", args: ["app-server", "--listen", "stdio://"], socket: sock, keeps: true };
    put(join(runners, `${id}.json`), JSON.stringify(info));
    const lines = [
      JSON.stringify({ id: 1, result: { userAgent: "stillfail/0.168.0 x" } }),
      JSON.stringify({ method: "turn/started", params: { threadId: "t1", turn: { id: "u1" } } }),
      JSON.stringify({ method: "item/started", params: { threadId: "t1", item: { type: "agentMessage", id: "i1" } } }),
      JSON.stringify({ method: "item/agentMessage/delta", params: { threadId: "t1" } }),
      JSON.stringify({ method: "item/agentMessage/delta", params: { threadId: "t1" } }),
      JSON.stringify({ method: "turn/diff/updated", params: { threadId: "t1" } }),
      JSON.stringify({ method: "turn/started", params: { threadId: "t2", turn: { id: "u2" } } }),
      JSON.stringify({ method: "turn/completed", params: { threadId: "t2" } }),
    ].join("\n") + "\n";
    put(join(runners, `${id}.out`), lines);
    const snapshot = { runtime: "codex", threadId: "t9", profile: "cx", busy: true, turnId: "u9", live: { open: ["i9"], phase: "working" }, host: { runner: id, signature: "sig", nextId: 40, ready: true, keep: 5 }, tuned: { model: "m", effort: "e" }, mcpUrl: "http://old/mcp" };
    const o = { key: "k", profile: p, cwd: data, instructions: "x", mcpToken: "t", mcpUrl: "http://h/mcp", route: "r" };
    return {
      profiles: [p],
      alive: [7300],
      sockets: { [sock]: [JSON.stringify({ op: "attached", out: Buffer.byteLength(lines), keep: 0 })] },
      replayOwn: { t1: { open: ["i1"], phase: "responding" } },
      replies: { "thread/read": [{ result: { thread: { path: join(p.home, "sessions", "rollout-1-t1.jsonl") } } }] },
      steps: [
        { do: "adopt", options: { ...o, resume: "t1" } },
        { do: "busy", s: 0 },
        { do: "adopt", options: { ...o, resume: "t2" } },
        { do: "adopt", options: { ...o, key: "k9" }, snapshot },
        { do: "snapshot", s: 0 },
      ],
    };
  });
});

test("Codex: a profile's own proxy leaves this machine out of its app-server's", { skip }, async () => {
  const trace = await codexCase("codex proxied", (data) => {
    const p = codexProfile(join(data, "cp"), { env: PROFILE_PROXY });
    const o = { key: "chat:1", profile: p, cwd: data, instructions: "x", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r" };
    return {
      profiles: [p],
      replies: { ...INIT, "thread/start": [thread("t1")], "mcpServerStatus/list": [{ result: { data: [{ name: "stillfail", runtimeStatus: "ready" }] } }] },
      steps: [{ do: "open", options: o }],
    };
  });
  keptLocal(trace, "codex proxied");
});

// ── Antigravity CLI ──

const agyProfile = (home: string, extra: Json = {}) => ({ id: "ag", runtime: "agy", home, access: { kind: "subscription" }, ...extra });
const MODELS = { models: { currentModelId: "gemini-4-carbon-low", availableModels: [{ modelId: "gemini-4-carbon-low" }, { modelId: "gemini-4-carbon-high" }, { modelId: "gemini-3.5-flash" }] }, _meta: { antigravity: { tier: { id: "g1-pro-tier" } } } };

async function agyCase(name: string, setup: (data: string) => { profiles: Json[]; steps: Json[]; replies: Json; world?: Json; alive?: number[]; sockets?: Record<string, string[]>; replayOwn?: Json }) {
  const data = fresh();
  const s = setup(data);
  const w = s.world ?? {};
  const servers = await Promise.all(Object.entries(s.sockets ?? {}).map(([p, script]) => runnerSocket(p, script)));
  const c = { ...common({ data, dump: data, ids: ["u1", "u2", "u3", "u4", "u5", "u6", "u7", "u8"] }), op: "agy", profiles: profilesOf(s.profiles), steps: s.steps, replies: s.replies, world: w, alive: s.alive, sockets: s.sockets ?? {}, replayOwn: s.replayOwn, fs: snap(data) };
  const asked: Json[] = [];
  let lentAt = 0;
  const { trace } = await runTs(
    c,
    (program) => {
      const driver = new AgyDriver({
        data,
        clock: { ...liveClock, sleep: () => Effect.void } as never,
        lent: {
          borrowed: (p: Json) => (w.borrowed ?? []).includes(p.id),
          write: async (p: Json) => {
            asked.push({ lentWrite: p.id });
            const g = (w.lent ?? [])[lentAt++] ?? { error: "none lent" };
            if (g.error !== undefined) throw new Error(g.error);
            mkdirSync(join(p.home, "agy", ".gemini", "antigravity-cli"), { recursive: true });
            writeFileSync(join(p.home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"), g.file);
            return g.until;
          },
        },
      } as never);
      // (its program is the case's: AcpDriver does not take one of its own)
      (driver as Json).agents = program;
      program.use();
      return driver;
    },
    async (driver, st, sessions, _k, events) => {
      const session = sessions[st.s];
      switch (st.do) {
        case "open": {
          const x = await driver.open(st.options, events);
          sessions.push(x);
          return x.id();
        }
        case "adopt": {
          const x = await driver.adopt(st.options, st.snapshot ?? null, events);
          sessions.push(x);
          return { id: x.id(), busy: x.busy(), mcpUrl: x.mcpUrl() };
        }
        case "catalog":
          return driver.catalog(st.profile);
        case "prompt":
          return session.prompt(st.text).then(() => null);
        case "steer":
          return session.steer(st.text);
        case "abort":
          return session.abort().then(() => null);
        case "retune":
          return session.retune(st.options);
        case "snapshot":
          return session.snapshot();
        case "dispose":
          return session.dispose().then(() => null);
        case "detach":
          return (session.detach(), null);
        case "outlived":
          return session.outlived();
        case "signInExpired":
          return session.signInExpired();
        case "model":
          return { model: session.model, current: session.currentModelId };
        case "bringIn":
          return agyBringIn(st.home, st.id);
        case "noteEmail":
          return noteAgyEmail(st.profile.home, st.text);
        case "hooks":
          return agyHooks(st.profile.home).then(() => null);
        case "skills":
          return agySkills(st.cwd, st.skills).then(() => null);
        case "ownedRunners":
          return [...driver.ownedRunners()];
      }
      throw new Error(`no such step: ${st.do}`);
    },
  );
  // (a case that threw before here leaves them to the file's after())
  for (const s of servers) await s.close();
  const said = await runMb(c);
  compare(name, said, trace);
  assert.deepEqual(said.asked, asked, `${name}: what the driver asked`);
  return trace;
}

test("Antigravity CLI: opened in ACP with its files, hooks, skills and model; a turn, a steer that takes it over, a permission, a request refused, its usage kept, an interrupt, retuned", { skip }, async () => {
  await agyCase("agy turns", (data) => {
    const home = join(data, "ag");
    const p = agyProfile(home, { model: "gemini-4-carbon" });
    const skills = join(data, "shared-skills");
    put(join(skills, "one", "SKILL.md"), "# one");
    put(join(skills, "one", "run.sh"), "echo");
    put(join(data, ".agents", "skills", "two", "SKILL.md"), "# two");
    put(join(data, ".agent", "skills", "stale", "SKILL.md"), "old");
    const o = { key: "chat:9", profile: p, cwd: data, instructions: "be brief", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r", effort: "high", skills };
    return {
      profiles: [p],
      replies: { initialize: [{ result: { authMethods: [] } }], "session/new": [{ result: { sessionId: "conv1", ...MODELS } }], "session/set_model": [{ result: {} }] },
      steps: [
        { do: "open", options: o },
        { do: "model", s: 0 },
        { do: "prompt", s: 0, text: "hi" },
        { do: "steer", s: 0, text: "take over" },
        { do: "hear", proc: 0, heard: { events: [{ type: "usage", update: { sessionUpdate: "usage_update", used: 1000, size: 200000 } }, { type: "kept", line: { type: "assistant", text: "said" } }, { type: "answered", id: "prompt:u2", answer: { result: { stopReason: "end_turn" } } }], to: 50, lines: [{ text: JSON.stringify({ jsonrpc: "2.0", id: 5, method: "session/request_permission", params: { options: [{ kind: "allow_always", optionId: "a" }, { kind: "allow_once", optionId: "o" }] } }), from: 0, to: 10 }, { text: JSON.stringify({ jsonrpc: "2.0", id: 6, method: "fs/read_text_file", params: {} }), from: 10, to: 20 }] } },
        { do: "hear", proc: 0, heard: { events: [{ type: "answered", id: "steer:u3", outcome: { kind: "completed" }, answer: { result: { stopReason: "end_turn", usage: { inputTokens: 100, cachedReadTokens: 20, outputTokens: 7, thoughtTokens: 3 } } } }, { type: "turnEnded", outcome: { kind: "completed" } }], turn: { busy: false, aborting: false, owner: null, steering: [] }, to: 90 } },
        { do: "retune", s: 0, options: { ...o, effort: "low", model: "gemini-4-carbon" } },
        { do: "retune", s: 0, options: { ...o, model: "unknown-model" } },
        { do: "prompt", s: 0, text: "again" },
        { do: "abort", s: 0 },
        { do: "abort", s: 0 },
        { do: "snapshot", s: 0 },
        { do: "outlived", s: 0 },
      ],
    };
  });
});

test("Antigravity CLI: a process with no models opened again after its waits; one resumed brought in from another home; a borrowed sign-in lent again; a catalog", { skip }, async () => {
  await agyCase("agy openings", (data) => {
    const homes = join(data, "homes");
    const p = agyProfile(join(homes, "P2"), { model: "gemini-3.5-flash" });
    const other = join(homes, "P1");
    put(join(other, "agy", ".gemini", "antigravity-cli", "conversations", "conv7.db"), "db of P1", 1_700_000_100_000);
    put(join(other, "agy", ".gemini", "antigravity-cli", "conversations", "conv7.db-wal"), "wal of P1", 1_700_000_200_000);
    put(join(other, "agy", ".gemini", "antigravity-cli", "brain", "conv7", "note.md"), "brain");
    put(join(p.home, "agy", "sessions", "conv7.jsonl"), '{"type":"session"}\n');
    const lentP = agyProfile(join(homes, "L"), { id: "lent" });
    const o = (pr: Json, extra: Json = {}) => ({ key: `chat:${pr.id}`, profile: pr, cwd: data, instructions: "", mcpToken: "tok", mcpUrl: "http://h/mcp", route: "r", ...extra });
    return {
      profiles: [p, lentP],
      world: { borrowed: ["lent"], lent: [{ file: JSON.stringify({ token: { access_token: "a", expiry: "2027-01-15T08:00:00Z" } }), until: 1_800_000_900_000 }] },
      replies: {
        initialize: [{ result: {} }],
        "session/load": [{ result: { models: null } }, { result: { models: null } }, { result: MODELS }],
        "session/new": [{ result: { sessionId: "lent-conv", ...MODELS } }, { result: { sessionId: "probe", ...MODELS } }],
        "session/set_model": [{ result: {} }],
      },
      steps: [
        { do: "open", options: o(p, { resume: "conv7" }) },
        { do: "open", options: o(p, { resume: "bad id" }) },
        { do: "open", options: o(p, { resume: "conv8" }) },
        { do: "open", options: o(lentP) },
        { do: "outlived", s: 1 },
        { do: "signInExpired", s: 1 },
        { do: "catalog", profile: p },
        { do: "ownedRunners" },
      ],
    };
  });
});

test("Antigravity CLI: a profile's own proxy leaves this machine out of it", { skip }, async () => {
  const trace = await agyCase("agy proxied", (data) => {
    const p = agyProfile(join(data, "ap"), { env: PROFILE_PROXY });
    const o = { key: "chat:p", profile: p, cwd: data, instructions: "x", mcpToken: "tok", mcpUrl: "http://127.0.0.1:4750/mcp", route: "r" };
    return {
      profiles: [p],
      replies: { initialize: [{ result: { authMethods: [] } }], "session/new": [{ result: { sessionId: "conv1", ...MODELS } }] },
      steps: [{ do: "open", options: o }],
    };
  });
  keptLocal(trace, "agy proxied");
});

test("Antigravity CLI: taken up handed over and after a crash, its conversation looked for; its email noted; its hooks kept", { skip }, async () => {
  const trace = await agyCase("agy adopt", (data) => {
    const p = agyProfile(join(data, "ag"));
    const conv = join(p.home, "agy", ".gemini", "antigravity-cli", "conversations");
    put(join(conv, "conv1.db"), "db");
    put(join(conv, "conv2.db"), "db");
    put(join(p.home, "agy", ".gemini", "config", "hooks.json"), JSON.stringify({ mine: { x: 1 } }));
    const runners = join(data, "run", "runners");
    const key1 = "chat:a";
    const id1 = `agy-${keyPart(key1)}`;
    const sock1 = join(runners, `${id1}.sock`);
    put(join(runners, `${id1}.json`), JSON.stringify({ id: id1, runner: 7400, pid: 7401, pgid: 7402, startedAt: 0, program: "agy", args: [], socket: sock1 }));
    const key2 = "chat:b";
    const id2 = `agy-${keyPart(key2)}`;
    const sock2 = join(runners, `${id2}.sock`);
    put(join(runners, `${id2}.json`), JSON.stringify({ id: id2, runner: 7500, pid: 7501, pgid: 7502, startedAt: 0, program: "agy", args: [], socket: sock2 }));
    // (one taken up after a crash before the station's door opened: no address of its tools known, mcpUrl "")
    const key3 = "chat:c";
    const id3 = `agy-${keyPart(key3)}`;
    const sock3 = join(runners, `${id3}.sock`);
    put(join(runners, `${id3}.json`), JSON.stringify({ id: id3, runner: 7600, pid: 7601, pgid: 7602, startedAt: 0, program: "agy", args: [], socket: sock3 }));
    // (one whose station went before it had said anything: stuck on initialize, no session open)
    const key4 = "chat:d";
    const id4 = `agy-${keyPart(key4)}`;
    const sock4 = join(runners, `${id4}.sock`);
    put(join(runners, `${id4}.json`), JSON.stringify({ id: id4, runner: 7700, pid: 7701, pgid: 7702, startedAt: 0, program: "agy", args: [], socket: sock4 }));
    const snapshot = { runtime: "agy", id: "conv1", runner: id1, turn: { busy: true, aborting: false }, tools: "http://old/mcp", live: { open: [], said: null, n: 2, phase: "working" }, model: "gemini-4-carbon", owner: "prompt:x", steering: [], said: null, calls: [], saidLast: "", children: [], availableModels: ["gemini-4-carbon-low"], currentModelId: "gemini-4-carbon-low", defaultModelId: null, context: { used: 5, size: 9 }, signInUntil: null };
    const o = (extra: Json = {}) => ({ key: key1, profile: p, cwd: data, instructions: "x", mcpToken: "t", mcpUrl: "http://h/mcp", route: "r", ...extra });
    return {
      profiles: [p],
      alive: [7400, 7500, 7600, 7700],
      sockets: { [sock1]: [], [sock2]: [JSON.stringify({ op: "attached", out: 30 })], [sock3]: [JSON.stringify({ op: "attached", out: 30 })], [sock4]: [JSON.stringify({ op: "attached", out: 0 })] },
      replayOwn: { session: "conv2", turn: { busy: true }, live: { live: { open: [], said: null, n: 0, phase: null } }, opened: MODELS, usages: [{ sessionUpdate: "usage_update", used: 7, size: 70 }] },
      replies: {},
      steps: [
        { do: "adopt", options: o(), snapshot },
        { do: "snapshot", s: 0 },
        { do: "adopt", options: o({ key: key2, resume: "conv2", model: "gemini-4-carbon" }) },
        { do: "snapshot", s: 1 },
        { do: "adopt", options: o({ key: "chat:none", resume: "conv3" }) },
        { do: "adopt", options: o({ key: key3, resume: "conv2", mcpUrl: "" }) },
        { do: "noteEmail", profile: p, text: JSON.stringify({ id_token_email: "a@b.c" }) },
        { do: "noteEmail", profile: p, text: "[1]" },
        { do: "hooks", profile: p },
        { do: "adopt", options: o({ key: key4 }) },
      ],
    };
  });
  // One taken up after a crash that had not opened its session is refused, its runner left for `endOrphans`.
  assert.deepEqual(trace.results.at(-1), { error: "agy process for chat:d had not opened a session" });
  // After a crash a process keeps the address it was told unless the station's door was not open yet: then none is known,
  // and the door opening on its port is no other address to end it for (hub.ts `toolsAt`).
  assert.equal(trace.results[2].ok.mcpUrl, "http://h/mcp");
  assert.equal(trace.results[5].ok.mcpUrl, null);
});
