// The accounts' sign-ins and checks in MoonBit (station/mb src/accounts_oauth: `stillfail-reader-harness --builder harness-accounts-oauth`)
// held to the TypeScript they replace (src/accounts/oauth.ts, login.ts, console.ts, profiles.ts, models.ts, catalog.ts,
// machine.ts, src/models/module.ts) on the same inputs. A pure function is given the same arguments on both sides; a
// flow that does IO is given one world on both: the TypeScript a temp directory, a provider on 127.0.0.1 (accounts-
// fakes.ts) and stand-in commands, the program the same files, the same answers in the same order and the same
// commands' outputs in a world of its own. What each asked (the requests, the commands), what it left on disk and what it
// came to must be the same.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { createServer, type IncomingMessage } from "node:http";
import { createInterface } from "node:readline";
import { after, before, mock, test } from "node:test";
import { fileURLToPath } from "node:url";
import { agyBaseModel } from "../src/agents/agy.ts";
import { devinCatalog, devinFusionBase } from "../src/agents/devin.ts";
import { parseClaudeCredentials } from "../src/agents/machine-logins.ts";
import { endpoints, find } from "../src/agents/providers.ts";
import { catalog as catalogNow, facts, learn, named } from "../src/accounts/catalog.ts";
import { consoleIn, deviceToken, pollAnswer, postForm, readConsole, renewAnswer, renewToken, startDevice, whoIs, writeConsole } from "../src/accounts/console.ts";
import { agyCallbackCode, claudeCodeOf, deviceCode, LoginManager, parse, stripAnsi, type LoginJob } from "../src/accounts/login.ts";
import { capitalized, claudePlan, codexAccountIdentity, codexClaimsIn, MachineLogins } from "../src/accounts/machine.ts";
import { lineOf, newerOf, seesImages, uncheckOutdated } from "../src/accounts/models.ts";
import { claudeOAuthToken } from "../src/accounts/oauth.ts";
import { accessKinds, checkProfile, devinEmailIn, devinNotedIn, grokEmailIn, grokModels, keyed, loginCommand, runtimesOf } from "../src/accounts/profiles.ts";
import { ModelCatalog } from "../src/models/module.ts";
import { urlsIn } from "../src/ops/command-output.ts";
import { wall } from "../src/ops/fibers.ts";
import { platform, WINDOWS } from "../src/platform/index.ts";
import { mbHarnessBinary } from "./mb-harness.ts";
import { exe, fakeLogin, idToken, machine, script, upon, type Asked } from "./accounts-fakes.ts";
import { testClock } from "./hub-fakes.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : WINDOWS ? "the stand-ins are POSIX shell scripts" : false;
const catalogDir = fileURLToPath(new URL("../../client/i18n/catalog", import.meta.url));

// The keychain is the machine's: neither side reads it here (the files are what both read).
(platform as { hasKeychain: boolean }).hasKeychain = false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `mb-accounts-${what}-`));
  dirs.push(dir);
  return dir;
};

let program: { child: ChildProcessWithoutNullStreams; next: (line: string) => Promise<any> } | null = null;
/// The program, started once: a case a line, its answer a line.
function harness() {
  if (program !== null) return program;
  const shell = fresh("shell");
  const child = spawn(binary!, ["--builder", "harness-accounts-oauth", "--shell-dir", shell], { stdio: ["pipe", "pipe", "pipe"] });
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
before(async () => {
  if (skip) return;
  await mb({ op: "words", zh: join(catalogDir, "zh", "station.json"), en: join(catalogDir, "en", "station.json") });
});
after(() => {
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
/// An outcome as the harness says it: `{ok}`, or `{error, kind}` (a RenewRefused's status too).
async function outcome(f: () => unknown): Promise<any> {
  try {
    return { ok: plain(await f()) };
  } catch (e) {
    const err = e as Error & { status?: number | null };
    if (err.constructor.name === "RenewRefused") return { error: err.message, kind: "renewRefused", status: err.status ?? null };
    if (err.constructor.name === "Said") return { error: err.message, kind: "said" };
    return { error: err.message, kind: "error" };
  }
}

const pure = (fn: string, ...args: unknown[]) => mb({ op: "pure", fn, args });

/// The files under `root`, by path from there (what the program's world says of its own).
function filesUnder(root: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (dir: string) => {
    for (const name of readdirSync(dir).sort()) {
      const path = join(dir, name);
      if (statSync(path).isDirectory()) walk(path);
      else out[relative(root, path)] = readFileSync(path, "utf8");
    }
  };
  walk(root);
  return Object.fromEntries(Object.entries(out).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
}

/// Files written for both sides: on disk for the TypeScript, as paths and texts for the program.
function lay(files: Record<string, string>): Record<string, string> {
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, text);
  }
  return files;
}

/// A provider answering each path in turn, as the program's world does: the last answer again once the rest are given
/// (accounts-fakes.ts `provider`, with an answer's headers).
type Answer = { status?: number; body?: unknown; headers?: Record<string, string> };
async function serve(routes: Record<string, Answer[]>) {
  const left = Object.fromEntries(Object.entries(routes).map(([k, v]) => [k, [...v]]));
  const asked: Asked[] = [];
  const server = createServer(async (req: IncomingMessage, res) => {
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(chunk as Buffer);
    const text = Buffer.concat(chunks).toString("utf8");
    let body: any = null;
    try {
      body = text === "" ? null : JSON.parse(text);
    } catch {}
    const form = Object.fromEntries(new URLSearchParams(String(req.headers["content-type"] ?? "").startsWith("application/x-www-form-urlencoded") ? text : ""));
    asked.push({ method: req.method ?? "", url: req.url ?? "", headers: Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)])), body, form });
    const queue = left[(req.url ?? "").split("?")[0]!];
    const a: Answer = queue === undefined || queue.length === 0 ? { status: 404, body: { error: "no route" } } : queue.length > 1 ? queue.shift()! : queue[0]!;
    const out = a.body === undefined ? "" : typeof a.body === "string" ? a.body : JSON.stringify(a.body);
    res.writeHead(a.status ?? 200, { "content-type": "application/json", connection: "close", ...a.headers });
    res.end(a.status === 304 ? undefined : out);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  const base = `http://127.0.0.1:${typeof address === "object" && address ? address.port : 0}`;
  return { base, asked, close: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

/// What was asked, as both sides are compared: method, path, the headers that say something and the body.
const SAID_HEADERS = ["content-type", "accept", "authorization", "x-api-key", "anthropic-version", "anthropic-beta", "if-none-match"];
function askedTs(asked: Asked[]) {
  return asked.map((a) => ({
    method: a.method,
    path: a.url,
    // (what fetch says of itself where nothing else is said: its `accept`, its `user-agent`)
    headers: Object.fromEntries(SAID_HEADERS.filter((h) => a.headers[h] !== undefined && !(h === "accept" && a.headers[h] === "*/*")).map((h) => [h, a.headers[h]])),
    agent: a.headers["user-agent"] === "node" ? null : (a.headers["user-agent"] ?? null),
    session: a.headers["x-opencode-session"] !== undefined,
    body: a.body === null ? (a.form && Object.keys(a.form).length > 0 ? a.form : null) : a.body,
  }));
}
function askedMb(requests: any[]) {
  return requests.map((r) => {
    const url = new URL(r.url);
    let body: unknown = r.body;
    if (typeof body === "string") {
      if (body === "") body = null;
      else if ((r.headers["content-type"] ?? "").startsWith("application/x-www-form-urlencoded")) body = Object.fromEntries(new URLSearchParams(body));
      else {
        try {
          body = JSON.parse(body);
        } catch {}
      }
    }
    return {
      method: r.method,
      path: `${url.pathname}${url.search}`,
      headers: Object.fromEntries(SAID_HEADERS.filter((h) => r.headers[h] !== undefined).map((h) => [h, r.headers[h]])),
      agent: r.headers["user-agent"] ?? null,
      session: r.headers["x-opencode-session"] !== undefined,
      body,
    };
  });
}

const NOW = 1_800_000_000_000;
/// Both sides on one wall clock: the TypeScript's Date held at `NOW`.
function frozen() {
  mock.timers.enable({ apis: ["Date"], now: NOW });
  return () => mock.timers.reset();
}

test("the pure parts say what the TypeScript says", { skip }, async () => {
  const ansi = ["plain", "\u001b[94mblue\u001b[0m", "\u001b]8;;https://x.example\u0007link\u001b]8;;\u0007", "a\u001b[?25lb", "\u001b[", "x\u001b]unended", "😀\u001b[1;31m😀", "\u001b]0;t\u001b\\after"];
  for (const t of ansi) assert.deepEqual(await pure("stripAnsi", t), stripAnsi(t), JSON.stringify(t));
  const codes = ["Enter ABCD-12345 now", "abcd-12345", "AB-CD", "X ABCD-1234567 Y", "WXYZ-1234", "A_BC-DEFG ABCD-EFGH", "", "--ABCD-1234--"];
  for (const t of codes) assert.deepEqual(await pure("deviceCode", t), deviceCode(t), t);
  const outputs = [
    "visit: https://claude.com/cai/oauth/authorize?code=true&state=y\nPaste code here > ",
    "visit https://claude.com/cai/oauth/authorize? paste code",
    "Open https://auth.openai.com/codex/device then enter ABCD-12345",
    "https://accounts.x.ai/device?x WXYZ-98765",
    "Paste it: https://app.devin.ai/auth/cli/x?code_challenge=1",
    "Authorization code: https://accounts.google.com/o/oauth2/auth?redirect_uri=https%3A%2F%2Fantigravity.google%2Foauth-callback",
    "nothing here",
  ];
  for (const runtime of ["claude", "codex", "grok", "devin", "agy"]) {
    for (const out of outputs) {
      const job = { profile: "p", runtime, state: "starting", url: null, userCode: null, error: null, startedAt: 0, expiresAt: 0 } as LoginJob;
      const changed = parse(job, out);
      assert.deepEqual(await pure("parse", { profile: "p", runtime, state: "starting", url: null, userCode: null, error: null }, out), { changed, job: plain(job) }, `${runtime} ${out}`);
    }
  }
  const auth = "https://claude.com/cai/oauth/authorize?code=true&state=abc";
  const pasted = ["code#abc", " c#abc ", "nohash", "a#b#c", "#abc", "code#", "code#other", "https://platform.claude.com/oauth/code/callback?code=k1&state=abc", "https://x/callback?code=k1&state=zz", auth, "HTTPS://X/cb?code=a%20b&state=abc"];
  for (const lang of ["zh", "en"] as const) {
    for (const p of pasted) {
      for (const a of [auth, null, "not a url"]) {
        assert.deepEqual(await outcome(() => pure("claudeCodeOf", p, a, lang).catch((e) => Promise.reject(new Error(String(e.message).replace(/^MoonBit: /, ""))))), await outcome(() => claudeCodeOf(p, a, lang)), `${p} ${a}`);
      }
    }
  }
  const tabs = [null, "https://antigravity.google/oauth-callback?code=c1&state=s", "https://antigravity.google/oauth-callback/?code=c1", "https://antigravity.google/oauth-callback?code=c1&state=t", "https://evil.example/oauth-callback?code=c1", "https://antigravity.google/other?code=c1", "https://antigravity.google/oauth-callback?code=", "nope"];
  for (const t of tabs) for (const a of [null, "https://accounts.google.com/o/oauth2/auth?state=s", "https://accounts.google.com/o/oauth2/auth"]) assert.deepEqual(await pure("agyCallbackCode", t, a), agyCallbackCode(t, a), `${t} ${a}`);
  const said = ["see https://x.example/a.", "(https://x.example/a(b)) and https://y.example/p?q=1,", "https://z.example/...", "http://127.0.0.1:5555/callback?code=1\"", "https://", "x https://a.b/c… y"];
  for (const t of said) assert.deepEqual(await pure("urlsIn", t), urlsIn(t), t);
});

test("models: lines, newer ones, images and what is unchecked, as the TypeScript says", { skip }, async () => {
  const names = ["claude-fable-5-1", "claude-3-5-sonnet", "gpt-6.1-sol", "kimi-k3", "deepseek-v4-flash-0731", "anthropic/claude-opus-5-5[1m]", "glm-5.3-flash", "x-2024-01-01", "1.2.3", "a..b", "qwen3.8-flash", "Claude-Fable-5-2"];
  for (const n of names) assert.deepEqual(await pure("lineOf", n), plain(lineOf(n)), n);
  const offered = ["claude-fable-5-2", "claude-fable-5-1[1m]", "gpt-6.2-sol", "kimi-k4", "claude-opus-5-5", "anthropic/claude-opus-5-6"];
  for (const n of names) assert.deepEqual(await pure("newerOf", n, offered), newerOf(n, offered), n);
  for (const n of ["gemini-4-carbon-high", "gemini-3.5-flash", " x-max ", "-max", "fusion-a-high-sidekick-b"]) {
    assert.deepEqual(await pure("agyBaseModel", n), { effort: null, ...plain(agyBaseModel(n)) }, n);
    assert.deepEqual(await pure("devinFusionBase", n), { effort: null, ...plain(devinFusionBase(n)) }, n);
  }
  const told = { "omen-beta": { input: ["text", "image"] }, "Some/Model-X": { input: ["text"] }, "gemini-4-hydrogen": { input: ["image"] } };
  learn(told);
  try {
    for (const m of ["claude-anything", "kimi-k3", "omen-beta", "model-x", "gemini-4-hydrogen-high", "unknown", "openrouter/qwen3.8-flash[1m]"]) {
      assert.equal(await pure("seesImages", told, m), seesImages(m), m);
    }
  } finally {
    learn({});
  }
  const raw = () => ({
    profiles: [
      { id: "a", runtime: "claude", access: { kind: "subscription" }, models: ["claude-fable-5-1", "claude-opus-5-5", "old-model"], model: "claude-fable-5-1" },
      { id: "b", runtime: "agy", access: { kind: "api-provider" }, models: ["gemini-4-carbon-high", "gemini-4-carbon"] },
      { id: "c", runtime: "claude", access: { kind: "subscription" }, models: ["only-one"], model: "only-one" },
      { id: "d", runtime: "devin", models: ["fusion-x-high-sidekick-y"], share: { borrowed: true } },
      { id: "e", runtime: "devin", models: ["fusion-x-high-sidekick-y", 7] },
      { id: 9, runtime: "codex", models: ["gpt-6.1-sol"] },
      "not a profile",
    ],
    connects: [{ bind: { model: "claude-fable-5-1" } }, { bind: { model: "old-model" } }, { bind: {} }],
  });
  const found: Record<string, string[] | null> = { a: ["claude-fable-5-2", "claude-opus-5-5"], b: null, c: ["something-else"], e: ["fusion-x-sidekick-y"], "9": ["gpt-6.2-sol"] };
  for (const done of [[], ["claude-fable-5-1"]]) {
    const ts = raw();
    const out = uncheckOutdated(ts, (id) => found[id] ?? null, new Set(done));
    const got = await pure("uncheckOutdated", raw(), found, done);
    assert.deepEqual(got, { changes: plain(out.changes), unchecked: [...out.unchecked], raw: plain(ts) }, JSON.stringify(done));
  }
});

test("the catalog: what it learns, names and says of a model", { skip }, async () => {
  const models = {
    "Anthropic/Claude-Opus-5-5": { name: "Opus", maker: "anthropic", makerName: "", family: 3, input: ["text", 1, "image"], reasoning: true, efforts: ["low", "max"], context: 200000, output: -1, cost: { input: 5, output: 25, cacheRead: 0.5, cacheWrite: "x" } },
    "gemini-4-hydrogen": { cost: { input: 1 }, reasoning: "yes", context: 1e6 },
    broken: "not an object",
    "kimi-k3": {},
  };
  learn(models);
  try {
    const asked = ["claude-opus-5-5", "anthropic/claude-opus-5-5[1m]", "gemini-4-hydrogen-high", "gemini-4-hydrogen", "kimi-k3", "broken", "none"];
    const got = await pure("catalog", models, asked);
    assert.deepEqual(got.named, named());
    assert.deepEqual(got.snapshot.models, plain(catalogNow().models));
    assert.deepEqual(got.facts, asked.map((m) => plain(facts(m))));
    assert.equal(got.learned, named().length);
  } finally {
    learn({});
  }
});

test("profiles' pure rules, the machine's and the console's: as the TypeScript says", { skip }, async () => {
  for (const r of ["claude", "codex", "dsh", "pi", "hermes", "agy", "grok", "cursor", "devin", "other"]) {
    assert.deepEqual(await pure("accessKinds", r), accessKinds(r as never), r);
    for (const k of ["subscription", "opencode-go", "anthropic-api", "api-provider", "env"]) assert.deepEqual(await pure("runtimesOf", k, r), runtimesOf(k as never, r as never), `${k} ${r}`);
    for (const m of [false, true]) assert.equal(await pure("loginCommand", r, "/h/p/", m), loginCommand(r as never, "/h/p/", m), r);
  }
  assert.deepEqual(await pure("runtimesOf", "subscription", null), runtimesOf("subscription", undefined));
  for (const k of ["subscription", "opencode-go", "anthropic-api", "api-provider", "env"]) assert.equal(await pure("keyed", k), keyed(k as never), k);
  const statuses = ["Logged in\n  Email: a@b.c\n", "Email: a@b\r\nx", "Email:\n  a@b.c", "Email: a@b c", "Email: @b", "Email: a@", "  Email:   x@y.z   ", "nothing"];
  for (const t of statuses) assert.deepEqual(await pure("devinEmailIn", t), devinEmailIn(t), JSON.stringify(t));
  const lists = ["* grok-4 (default)\n- grok-4-mini\n-nogap\n  * x", "", "  -   spaced  "];
  for (const t of lists) assert.deepEqual(await pure("grokModels", t), grokModels(t), t);
  const auths = ['{"a":{"email":"x@y"}}', '{"a":{"email":""},"b":{"email":"z@w"}}', '"text"', "[1,{\"email\":\"q@r\"}]", "null", "{bad", "5"];
  for (const t of auths) {
    const ts = await outcome(() => grokEmailIn(t));
    const got = await pure("grokEmailIn", t);
    assert.equal("error" in got, "error" in ts, t);
    if ("ok" in ts) assert.deepEqual(got.ok, ts.ok, t);
  }
  for (const t of ['{"email":"a@b"}', '{"email":""}', "null", "{bad"]) {
    const ts = await outcome(() => devinNotedIn(t));
    const got = await pure("devinNotedIn", t);
    assert.equal("error" in got, "error" in ts, t);
    if ("ok" in ts) assert.deepEqual(got.ok, ts.ok, t);
  }
  const plans = [["max", "default_claude_max_20x"], ["max", null], [" Pro ", ""], ["claude_max_20x", null], ["", "x"], [null, null], [5, "x"], ["ULTRA", "MAX_20X"]];
  for (const [s, t] of plans) assert.deepEqual(await pure("claudePlan", s, t), claudePlan(s, t), JSON.stringify([s, t]));
  const tokens = [
    JSON.stringify({ tokens: { id_token: idToken({ email: "a@b", "https://api.openai.com/auth": { chatgpt_plan_type: "plus" } }) } }),
    JSON.stringify({ tokens: { id_token: `x.${Buffer.from('{"sub":"u1"}').toString("base64")}==.y` } }),
    JSON.stringify({ tokens: { id_token: "nodots" } }),
    JSON.stringify({ tokens: { id_token: 5 } }),
    JSON.stringify({ tokens: {} }),
    "{bad",
    JSON.stringify({ tokens: { id_token: "a.!!!.c" } }),
  ];
  for (const t of tokens) {
    const ts = codexClaimsIn(t);
    assert.deepEqual(await pure("codexClaimsIn", t), ts === undefined ? { none: true } : { claims: plain(ts) }, t);
  }
  for (const p of ["plus", "", "pro max", "édition"]) assert.equal(await pure("capitalized", p), capitalized(p), p);
  const files = ['{"access":"a","refresh":"r","expiresAt":1.5,"org":"","email":"e","workspace":null}', '{"access":"a","refresh":"r"}', "{bad", '{"access":1,"refresh":"r","expiresAt":1}'];
  for (const f of files) assert.deepEqual(await pure("consoleIn", f), plain(consoleIn(f)), f);
  for (const [token, e] of [[{ access: "a", refresh: "r", expiresInMs: 5, org: null }, "x"], [null, "authorization_pending"], [null, "slow_down"], [null, "access_denied"]] as const) {
    assert.deepEqual(await pure("pollAnswer", token, e), plain(pollAnswer(token, () => e)), String(e));
  }
  for (const [status, token, e] of [[200, { access: "a", refresh: "r", expiresInMs: 5, org: "o" }, "x"], [400, null, "invalid_grant"], [401, null, "u"], [403, null, "f"], [500, null, "HTTP 500"]] as const) {
    assert.deepEqual(await pure("renewAnswer", status, token, e), await outcome(() => renewAnswer(status, token, () => e)), String(status));
  }
});

test("the Console's device grant: the same asks of the same server, the same answers", { skip }, async () => {
  const cases: { fn: string; args: unknown[]; routes: Record<string, Answer[]> }[] = [
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ body: { device_code: "d", user_code: "U-1", verification_uri_complete: "/device?code=U-1", expires_in: 300, interval: 2 } }] } },
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ body: { device_code: "d", user_code: "U-1", verification_uri_complete: "https://other.example/x?y=1" } }] } },
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ body: { device_code: "d", user_code: "U-1", verification_uri_complete: "page", expires_in: -1, interval: "x" } }] } },
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ status: 400, body: { error: "invalid_client" } }] } },
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ status: 503, body: { _tag: "Busy" } }] } },
    { fn: "startDevice", args: [], routes: { "/auth/device/code": [{ status: 200, body: "not json" }] } },
    { fn: "deviceToken", args: ["d1"], routes: { "/auth/device/token": [{ status: 400, body: { error: "authorization_pending" } }] } },
    { fn: "deviceToken", args: ["d1"], routes: { "/auth/device/token": [{ status: 400, body: { error: "slow_down" } }] } },
    { fn: "deviceToken", args: ["d1"], routes: { "/auth/device/token": [{ body: { access_token: "a", refresh_token: "r", expires_in: 2592000, org_id: "o1" } }] } },
    { fn: "deviceToken", args: ["d1"], routes: { "/auth/device/token": [{ status: 400, body: { error: "expired_token" } }] } },
    { fn: "renewToken", args: ["r1"], routes: { "/auth/device/token": [{ body: { access_token: "a2", refresh_token: "r2", expires_in: 10 } }] } },
    { fn: "renewToken", args: ["r1"], routes: { "/auth/device/token": [{ status: 401, body: { error: "invalid_grant" } }] } },
    { fn: "renewToken", args: ["r1"], routes: { "/auth/device/token": [{ status: 502, body: "" }] } },
    { fn: "whoIs", args: ["tok", "o2"], routes: { "/api/user": [{ body: { email: "me@x" } }], "/api/orgs": [{ body: [{ id: "o1", name: "One" }, { id: "o2", name: "Two" }] }] } },
    { fn: "whoIs", args: ["tok", null], routes: { "/api/user": [{ status: 401, body: {} }], "/api/orgs": [{ body: [{ id: "o1", name: "One" }] }] } },
    { fn: "whoIs", args: ["tok", "o9"], routes: { "/api/user": [{ body: "bad" }], "/api/orgs": [{ body: { not: "a list" } }] } },
    { fn: "postForm", args: [{ a: "x y", b: "ü&=" }, { accept: "text/plain", "x-extra": "1" }, "/form"], routes: { "/form": [{ status: 201, body: { ok: 1 } }] } },
  ];
  for (const c of cases) {
    const server = await serve(c.routes);
    try {
      const run = async () => {
        if (c.fn === "startDevice") return startDevice(server.base);
        if (c.fn === "deviceToken") return deviceToken(server.base, c.args[0] as string);
        if (c.fn === "renewToken") return renewToken(server.base, c.args[0] as string);
        if (c.fn === "whoIs") return whoIs(server.base, c.args[0] as string, c.args[1] as string | null);
        return postForm(`${server.base}${c.args[2]}`, c.args[0] as Record<string, string>, c.args[1] as Record<string, string>);
      };
      const ts = await outcome(run);
      const got = await mb({ op: "console", fn: c.fn, args: c.args, base: server.base, routes: c.routes });
      if ("ok" in ts && c.fn === "startDevice") ts.ok.url = ts.ok.url.replace(server.base, "BASE");
      if ("ok" in got.result && c.fn === "startDevice") got.result.ok.url = got.result.ok.url.replace(server.base, "BASE");
      assert.deepEqual(got.result, ts, `${c.fn} ${JSON.stringify(c.routes)}`);
      assert.deepEqual(askedMb(got.requests), askedTs(server.asked), `${c.fn} asked`);
    } finally {
      await server.close();
    }
  }
  // Kept in the profile's home and read back.
  const root = fresh("console");
  const home = join(root, "home");
  const login = { access: "a", refresh: "r", expiresAt: NOW + 0.5, org: "o", email: null, workspace: "W" };
  await writeConsole(home, login);
  const got = await mb({ op: "console", fn: "writeConsole", args: [home, login], root });
  assert.deepEqual(got.files, filesUnder(root));
  assert.deepEqual((await mb({ op: "console", fn: "readConsole", args: [home], files: Object.fromEntries(Object.entries(filesUnder(root)).map(([k, v]) => [join(root, k), v])), root })).result, { ok: plain(await readConsole(home)) });
  assert.deepEqual((await mb({ op: "console", fn: "readConsole", args: [join(root, "none")] })).result, { ok: null });
});

/// A Claude login's credentials file.
const credentials = (oauth: Record<string, unknown> | null, extra: Record<string, unknown> = {}) => JSON.stringify({ ...extra, ...(oauth === null ? {} : { claudeAiOauth: oauth }) });

test("Claude's renewal: the same login renewed, kept or refused, the same file left", { skip }, async () => {
  const later = NOW + 3_600_000;
  const soon = NOW + 60_000;
  const token = (body: unknown, status = 200): Answer[] => [{ status, body }];
  const cases: { what: string; file?: string | null; routes?: Record<string, Answer[]>; rejected?: string | null; margin?: number; bound?: number; machine?: boolean; lockAgo?: number }[] = [
    { what: "a token that lasts is given as it is", file: credentials({ accessToken: "t1", expiresAt: later, refreshToken: "r1" }) },
    { what: "one that says no end lasts", file: credentials({ accessToken: "t1", refreshToken: "r1" }) },
    { what: "one about to run out is renewed and saved", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1", scopes: ["user:inference", 5, "user:profile"], clientId: "own" }, { other: { kept: true } }), routes: { "/token": token({ access_token: "t2", expires_in: 28800, refresh_token: "r2", scope: "  a  b ", refresh_token_expires_in: 100 }) } },
    { what: "one refused by a 401 is renewed", file: credentials({ accessToken: "t1", expiresAt: later, refreshToken: "r1" }), rejected: "t1", routes: { "/token": token({ access_token: "t2", expires_in: 60 }) } },
    { what: "a renewal that keeps the refresh token", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1", scopes: [] }), routes: { "/token": token({ access_token: "t2", expires_in: 3600, refresh_token: "", scope: 5 }) } },
    { what: "no refresh token: over", file: credentials({ accessToken: "t1", expiresAt: soon }) },
    { what: "its refresh token refused (401): over", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token({ error: "invalid_grant" }, 401) } },
    { what: "refused for now (500)", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token({}, 500) } },
    { what: "an answer that is not JSON", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token("<html>") } },
    { what: "no access token in it", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token({ expires_in: 10 }) } },
    { what: "no sane expiry in it", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token({ access_token: "t2", expires_in: 1.5 }) } },
    { what: "no file", file: null },
    { what: "a file that is not JSON", file: "{nope" },
    { what: "a file with no token", file: credentials({ refreshToken: "r1" }) },
    { what: "renewed early and refused: the token it has, while it lasts the usual margin", file: credentials({ accessToken: "t1", expiresAt: NOW + 20 * 60_000, refreshToken: "r1" }), margin: 30 * 60_000, routes: { "/token": token({}, 500) } },
    { what: "renewed early and not renewed: the token given", file: credentials({ accessToken: "t1", expiresAt: NOW + 20 * 60_000, refreshToken: "r1" }), margin: 30 * 60_000, routes: { "/token": token({ access_token: "t1", expires_in: 600 }) } },
    { what: "lent within its bound, renewed", file: credentials({ accessToken: "t1", expiresAt: NOW + 20 * 60_000, refreshToken: "r1" }), margin: 30 * 60_000, bound: 60_000, routes: { "/token": token({ access_token: "t3", expires_in: 7200 }) } },
    { what: "lent within its bound, its renewal refused", file: credentials({ accessToken: "t1", expiresAt: NOW + 20 * 60_000, refreshToken: "r1" }), margin: 30 * 60_000, bound: 60_000, routes: { "/token": token({ error: "x" }, 400) } },
    { what: "the machine's own login (~/.claude)", machine: true, file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), routes: { "/token": token({ access_token: "m2", expires_in: 100 }) } },
    { what: "a stale lock is taken", file: credentials({ accessToken: "t1", expiresAt: soon, refreshToken: "r1" }), lockAgo: 120_000, routes: { "/token": token({ access_token: "t2", expires_in: 100 }) } },
  ];
  for (const c of cases) {
    const root = fresh("oauth");
    const home = c.machine ? join(root, ".claude") : join(root, "home");
    const files: Record<string, string> = {};
    if (c.file !== undefined && c.file !== null) files[join(home, ".credentials.json")] = c.file;
    lay(files);
    const dirsGiven: Record<string, number> = {};
    if (c.lockAgo !== undefined) {
      const lock = join(home, ".oauth_refresh.lock");
      mkdirSync(lock, { recursive: true });
      utimesSync(lock, (NOW - c.lockAgo) / 1000, (NOW - c.lockAgo) / 1000);
      dirsGiven[lock] = NOW - c.lockAgo;
    }
    const server = await serve(c.routes ?? {});
    const env = { HOME: root };
    const endpoint = `${server.base}/token`;
    const unfreeze = frozen();
    let ts;
    try {
      const bound = c.bound === undefined ? undefined : { ms: c.bound, after: wall.after };
      ts = await outcome(() => claudeOAuthToken(env, c.machine ? null : home, c.rejected ?? null, endpoint, "zh", c.margin, bound));
    } finally {
      unfreeze();
      await server.close();
    }
    const got = await mb({ op: "oauth", now: NOW, wall: NOW, files, dirs: dirsGiven, routes: c.routes ?? {}, env, home: c.machine ? null : home, rejected: c.rejected ?? null, endpoint, margin: c.margin, bound: c.bound, lang: "zh", root });
    assert.deepEqual(got.result, ts, c.what);
    assert.deepEqual(askedMb(got.requests), askedTs(server.asked), `${c.what}: asked`);
    assert.deepEqual(got.files, filesUnder(root), `${c.what}: files`);
  }
});

/// Stand-in commands for both sides: a script a name in `bin` for the TypeScript, the outputs by command line for the
/// program.
type Said = { code: number; stdout?: string; stderr?: string };
function commands(bin: string, said: Record<string, Said>) {
  const q = (s: string) => `'${s.replaceAll("'", "'\\''")}'`;
  const byName = new Map<string, [string, Said][]>();
  for (const [line, s] of Object.entries(said)) {
    const [name, ...args] = line.split(" ");
    byName.set(name!, [...(byName.get(name!) ?? []), [args.join(" "), s]]);
  }
  for (const [name, lines] of byName) {
    const cases = lines.map(([args, s]) => `  ${q(args)}) printf '%s' ${q(s.stdout ?? "")}; printf '%s' ${q(s.stderr ?? "")} >&2; exit ${s.code};;`).join("\n");
    script(join(bin, name), `#!/bin/sh\ncase "$*" in\n${cases}\nesac\nexit 2\n`);
  }
  return said;
}

test("a profile's check: the same asks, the same commands' words read the same way", { skip }, async () => {
  const models = { data: [{ id: "m-b" }, { id: "m-a" }, { id: 5 }, { id: "x:batch" }] };
  type Case = { what: string; options: Record<string, unknown>; routes?: Record<string, Answer[]>; said?: Record<string, Said>; files?: (home: string) => Record<string, string>; deps?: Record<string, unknown> };
  const cases: Case[] = [
    { what: "an OpenCode Go key that works", options: { kind: "opencode-go", runtime: "claude", key: "k" }, routes: { "/v1/usage": [{ body: {} }], "/v1/models": [{ body: models }] } },
    { what: "an OpenCode Go sign-in refused", options: { kind: "opencode-go", runtime: "claude", key: "k", login: true }, routes: { "/v1/usage": [{ status: 401, body: {} }] } },
    { what: "an OpenCode Go key refused", options: { kind: "opencode-go", runtime: "claude", key: "k" }, routes: { "/v1/usage": [{ status: 403, body: {} }] } },
    { what: "its models unread", options: { kind: "opencode-go", runtime: "claude", key: "k" }, routes: { "/v1/usage": [{ body: {} }], "/v1/models": [{ status: 500, body: {} }] } },
    { what: "an Anthropic key", options: { kind: "anthropic-api", runtime: "claude", key: "sk" }, routes: { "/v1/models": [{ body: models }] } },
    { what: "an Anthropic key refused", options: { kind: "anthropic-api", runtime: "claude", key: "sk" }, routes: { "/v1/models": [{ status: 401, body: {} }] } },
    { what: "a provider's key", options: { kind: "api-provider", runtime: "codex", key: "or", via: { provider: "custom", endpoint: "BASE/v1", protocol: "chat" } }, routes: { "/v1/models": [{ body: models }] } },
    { what: "a provider's key refused", options: { kind: "api-provider", runtime: "codex", key: "or", via: { provider: "custom", endpoint: "BASE/v1", protocol: "chat" } }, routes: { "/v1/models": [{ status: 403, body: {} }] } },
    { what: "a provider with no list", options: { kind: "api-provider", runtime: "codex", key: "", via: { provider: "custom", endpoint: "BASE/v1", protocol: "chat" } }, routes: { "/v1/models": [{ status: 404, body: {} }] } },
    { what: "Kimi signed out", options: { kind: "api-provider", runtime: "codex", key: "", login: true, via: { provider: "custom", endpoint: "BASE/v1" } } },
    { what: "a provider not known", options: { kind: "api-provider", runtime: "codex", key: "k", via: { provider: "nobody" } } },
    { what: "a provider's address needed", options: { kind: "api-provider", runtime: "codex", key: "k", via: { provider: "custom" } } },
    { what: "the environment's", options: { kind: "env", runtime: "claude", key: "" } },
    { what: "Claude signed in", options: { kind: "subscription", runtime: "claude" }, said: { "claude auth status": { code: 0, stdout: JSON.stringify({ loggedIn: true, email: "a@b", subscriptionType: "max" }) } }, files: (home) => ({ [join(home, ".credentials.json")]: credentials({ accessToken: "t1", expiresAt: NOW + 3_600_000, refreshToken: "r", rateLimitTier: "default_claude_max_20x" }) }), routes: { "/v1/models": [{ body: models }] } },
    { what: "Claude signed out", options: { kind: "subscription", runtime: "claude" }, said: { "claude auth status": { code: 1, stdout: ' {"loggedIn":false}' } } },
    { what: "Claude's status failing", options: { kind: "subscription", runtime: "claude" }, said: { "claude auth status": { code: 3, stdout: "", stderr: "boom" } } },
    { what: "Claude's login over", options: { kind: "subscription", runtime: "claude" }, said: { "claude auth status": { code: 0, stdout: '{"loggedIn":true}' } }, files: (home) => ({ [join(home, ".credentials.json")]: credentials({ accessToken: "t1", expiresAt: NOW + 1000 }) }) },
    { what: "Claude on the machine's login", options: { kind: "subscription", runtime: "claude", machine: true, machineToken: "mt" }, said: { "claude auth status": { code: 0, stdout: '{"loggedIn":true,"email":"m@x"}' } }, routes: { "/v1/models": [{ status: 403, body: {} }] } },
    { what: "Codex signed in", options: { kind: "subscription", runtime: "codex" }, said: { "codex login status": { code: 0, stdout: "", stderr: "Logged in using ChatGPT\nmore" } }, files: (home) => ({ [join(home, "auth.json")]: JSON.stringify({ tokens: { id_token: idToken({ "https://api.openai.com/auth": { chatgpt_plan_type: " team " } }) } }) }) },
    { what: "Codex signed out", options: { kind: "subscription", runtime: "codex" }, said: { "codex login status": { code: 1, stdout: "Not logged in" } } },
    { what: "Codex failing", options: { kind: "subscription", runtime: "codex" }, said: { "codex login status": { code: 2, stdout: "", stderr: "x" } } },
    { what: "Grok signed in", options: { kind: "subscription", runtime: "grok" }, said: { "grok models": { code: 0, stdout: "* grok-5 (default)\n- grok-5-mini\n" } }, files: (home) => ({ [join(home, "grok", "auth.json")]: '{"x":{"email":"g@x"}}' }) },
    { what: "Grok signed out", options: { kind: "subscription", runtime: "grok" }, said: { "grok models": { code: 1, stdout: "Please Sign In" } } },
    { what: "Devin signed in", options: { kind: "subscription", runtime: "devin" }, said: { "devin auth status": { code: 0, stdout: "Logged in\nEmail: d@x\n" }, "devin models list --format json": { code: 0, stdout: "[]" } }, deps: { devinCatalog: plain(devinCatalog([])) } },
    { what: "Devin signed out", options: { kind: "subscription", runtime: "devin" }, said: { "devin auth status": { code: 1, stdout: "Not logged in" } } },
  ];
  for (const c of cases) {
    const m = machine();
    const home = join(m.home, "profile");
    mkdirSync(home, { recursive: true });
    const files = lay(c.files?.(home) ?? {});
    commands(m.bin, c.said ?? {});
    const server = await serve(c.routes ?? {});
    const via = c.options.via as Record<string, string> | undefined;
    const resolvedVia: { provider?: string; endpoint?: string; protocol?: string } = via === undefined ? {} : { ...via, ...(via.endpoint !== undefined ? { endpoint: via.endpoint.replace("BASE", server.base) } : {}) };
    const urls = { opencode: server.base, anthropic: server.base, chatgpt: server.base, claudeToken: `${server.base}/token`, console: server.base };
    const options = { runtime: c.options.runtime, kind: c.options.kind, key: c.options.key ?? "", via: resolvedVia, home, env: m.env, machine: c.options.machine === true, login: c.options.login === true, urls, lang: "zh" as const };
    const machineToken = typeof c.options.machineToken === "string" ? async () => ({ token: c.options.machineToken as string }) : undefined;
    const unfreeze = frozen();
    let ts;
    try {
      ts = await checkProfile({ ...options, machineToken } as never);
    } finally {
      unfreeze();
      await server.close();
    }
    const source = resolvedVia.provider === undefined ? null : (find(resolvedVia.provider) ?? null);
    const ends = source === null ? null : (endpoints(source, resolvedVia.endpoint, resolvedVia.protocol) ?? null);
    const got = await mb({
      op: "check",
      now: NOW,
      wall: NOW,
      files,
      routes: c.routes ?? {},
      commands: c.said ?? {},
      options: { ...options, machineToken: c.options.machineToken },
      deps: { source, endpoints: ends, ...c.deps },
      root: m.home,
    });
    assert.deepEqual(got.result, plain(ts), c.what);
    assert.deepEqual(askedMb(got.requests), askedTs(server.asked), `${c.what}: asked`);
    const left = filesUnder(m.home);
    for (const k of Object.keys(left)) if (k.startsWith("bin/")) delete left[k];
    assert.deepEqual(got.files, left, `${c.what}: files`);
    rmSync(m.home, { recursive: true, force: true });
  }
});

test("the machine's own logins: read the same, told the same", { skip }, async () => {
  const claudeIn = (status: unknown, code = 0): Said => ({ code, stdout: typeof status === "string" ? status : JSON.stringify(status) });
  const auth = JSON.stringify({ tokens: { id_token: idToken({ email: "c@x", "https://api.openai.com/auth": { chatgpt_plan_type: "pro" } }) } });
  const cases: { what: string; said: Record<string, Said>; claude?: string; codex?: string; usage?: Record<string, unknown> }[] = [
    { what: "both signed in", said: { "claude auth status": claudeIn({ loggedIn: true, email: "a@b", subscriptionType: "max" }), "codex login status": { code: 0, stdout: "Logged in using ChatGPT" } }, claude: credentials({ accessToken: "t", rateLimitTier: "max_20x", subscriptionType: "x" }), codex: auth, usage: { claude: { state: "ok", windows: [], signedOut: true, checkedAt: 1 }, codex: [1, 2] } },
    { what: "Claude in the keychain only", said: { "claude auth status": claudeIn({ loggedIn: true }), "codex login status": { code: 1, stdout: "Not logged in" } } },
    { what: "signed out and unreadable", said: { "claude auth status": claudeIn("garbage", 1), "codex login status": { code: 0, stdout: "logged in" } } },
    { what: "Claude signed out, usage failing", said: { "claude auth status": claudeIn({ loggedIn: false }, 1), "codex login status": { code: 0, stdout: "Logged in" } }, codex: JSON.stringify({ tokens: {} }), usage: { codex: "throw" } },
  ];
  for (const c of cases) {
    const m = machine();
    commands(m.bin, c.said);
    const files: Record<string, string> = {};
    if (c.claude !== undefined) files[join(m.home, ".claude", ".credentials.json")] = c.claude;
    if (c.codex !== undefined) files[join(m.home, ".codex", "auth.json")] = c.codex;
    lay(files);
    const usage = c.usage === undefined ? undefined : async (runtime: "claude" | "codex") => {
      const q = c.usage![runtime];
      if (q === "throw") throw new Error("usage failed");
      return (q ?? null) as never;
    };
    const ts = new MachineLogins(m.env, usage, () => "zh");
    let heard = 0;
    ts.changes(() => heard++);
    const readings = [];
    for (let i = 0; i < 2; i++) {
      await ts.refresh();
      readings.push(plain(ts.get()));
    }
    const strip = (v: unknown): unknown => (Array.isArray(v) ? v.map(strip) : v !== null && typeof v === "object" ? Object.fromEntries(Object.entries(v).filter(([k]) => k !== "checkedAt").map(([k, x]) => [k, strip(x)])) : v);
    const credentials = c.claude === undefined ? null : (parseClaudeCredentials(c.claude) ?? null);
    const got = await mb({ op: "machine", files, commands: c.said, env: m.env, deps: { credentials, usage: c.usage }, reads: 2, lang: "zh" });
    assert.deepEqual(got.readings, strip(readings), c.what);
    assert.equal(got.heard, heard, `${c.what}: told`);
    rmSync(m.home, { recursive: true, force: true });
  }
});

test("Codex's account identity follows its auth file", { skip }, async () => {
  const root = fresh("identity");
  const home = join(root, "codex");
  mkdirSync(home);
  const file = join(home, "auth.json");
  const steps = [
    { write: JSON.stringify({ tokens: { account_id: "acc", id_token: idToken({ sub: "u1" }) } }) },
    {},
    { write: JSON.stringify({ tokens: { account_id: "acc2", id_token: idToken({ sub: "user-2" }) } }) },
    { write: JSON.stringify({ tokens: { account_id: "  ", id_token: idToken({ sub: "user-2" }) } }) },
    { remove: true },
    { write: "{bad json at all" },
  ];
  const ts: (string | null)[] = [];
  for (const s of steps) {
    if (s.write !== undefined) writeFileSync(file, s.write);
    if (s.remove) rmSync(file);
    ts.push(await codexAccountIdentity(home));
  }
  assert.deepEqual(await mb({ op: "identity", home, steps }), ts);
});

test("the model catalog's part: the same asks of the cloud, the same file kept, the same models told", { skip }, async () => {
  const first = { models: { "model-a": { input: ["text"] } } };
  const second = { models: { "model-a": { input: ["text"] }, "Vendor/Model-B": { input: ["image"] } } };
  const cases: { what: string; kept?: unknown; routes: Record<string, Answer[]>; steps: { etag?: string }[]; origin?: boolean }[] = [
    { what: "read, then a new model told", routes: { "/v1/models": [{ body: first, headers: { etag: "e1" } }, { body: second }] }, steps: [{}, { etag: "e2" }] },
    { what: "kept, unchanged (304), then failing", kept: { etag: "e0", models: first.models }, routes: { "/v1/models": [{ status: 304, body: "" }, { status: 500, body: "" }] }, steps: [{}, { etag: "e0" }, { etag: "x y/ü" }] },
    { what: "no cloud", routes: {}, steps: [{}], origin: false },
    { what: "an answer that is not JSON", routes: { "/v1/models": [{ body: "nope" }] }, steps: [{}] },
  ];
  for (const c of cases) {
    const root = fresh("catalog");
    const file = join(root, "model-catalog.json");
    const files = c.kept === undefined ? {} : lay({ [file]: JSON.stringify(c.kept) });
    const server = await serve(c.routes);
    learn({});
    const origin = c.origin === false ? null : server.base;
    const added: string[][] = [];
    const tsSteps: unknown[] = [];
    try {
      const cat = new ModelCatalog(file, () => origin, () => 0, undefined, (keys) => added.push(keys));
      tsSteps.push({ named: named() });
      for (const s of c.steps) {
        await cat.refresh(s.etag);
        tsSteps.push({ named: named() });
      }
      await cat.written();
    } finally {
      await server.close();
      learn({});
    }
    const got = await mb({ op: "module", files, file, origin, routes: c.routes, steps: c.steps, root });
    assert.deepEqual(got.steps, tsSteps, c.what);
    assert.deepEqual(got.added, added, `${c.what}: told`);
    assert.deepEqual(askedMb(got.requests), askedTs(server.asked), `${c.what}: asked`);
    assert.deepEqual(got.files, filesUnder(root), `${c.what}: kept`);
  }
});

/// The stand-in login (accounts-fakes.ts `fakeLogin`) as the program's world has it, by command and first argument.
function fakeSpecs(path: string) {
  const invalid = { out: "Invalid code. Please make sure the full code was copied\n" };
  return {
    [`${path} auth`]: {
      start: { out: "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y\nPaste code here if prompted > " },
      lines: [{ is: "good-code#y", out: "Login successful\n", exit: 0 }, { is: "refused#y", ...invalid }, { is: "silent#y" }, { out: "OAuth error: invalid code\n", exit: 1 }],
    },
    [`${path} login`]: {
      start: { out: "1. Open this link\n   \u001b[94mhttps://auth.openai.com/codex/device\u001b[0m\n2. Enter this one-time code\n   \u001b[94mABCD-12345\u001b[0m\n" },
      approved: { out: "Successfully logged in\n", exit: 0 },
    },
  };
}

test("a sign-in from the pages: the same states, the same refusals, the same files", { skip }, async () => {
  type Step = { do: string; profile?: string; login?: Record<string, unknown>; code?: string; state?: string; ms?: number; home?: string; command?: string; lang?: string };
  const root = fresh("login");
  const fake = join(root, "fake-login");
  const approvalPath = join(root, "approved");
  script(fake, fakeLogin(approvalPath));
  const homes = join(root, "homes");
  const consoleRoutes: Record<string, Answer[]> = {
    "/auth/device/code": [{ body: { device_code: "dc", user_code: "WXYZ-1234", verification_uri_complete: "/device?c=1", expires_in: 600, interval: 1 } }],
    "/auth/device/token": [{ status: 400, body: { error: "authorization_pending" } }, { status: 400, body: { error: "slow_down" } }, { body: { access_token: "ta", refresh_token: "tr", expires_in: 100, org_id: "o" } }],
    "/api/user": [{ body: { email: "me@x" } }],
    "/api/orgs": [{ body: [{ id: "o", name: "Org" }] }],
  };
  const claude = { id: "sub", runtime: "claude", home: join(homes, "sub"), email: " who@x " };
  const codex = { id: "cxs", runtime: "codex", home: join(homes, "cxs") };
  const scenarios: { what: string; steps: Step[]; routes?: Record<string, Answer[]> }[] = [
    {
      what: "Claude: a code refused, then one taken",
      steps: [
        { do: "start", login: claude },
        { do: "until", profile: "sub", state: "needs_code" },
        { do: "submit", profile: "sub", code: "nohash" },
        { do: "submit", profile: "sub", code: "x#other" },
        { do: "submit", profile: "sub", code: "   " },
        { do: "submit", profile: "sub", code: "wrong#y" },
        { do: "until", profile: "sub", state: "failed" },
        { do: "submit", profile: "sub", code: "x#y" },
        { do: "start", login: claude },
        { do: "until", profile: "sub", state: "needs_code" },
        { do: "submit", profile: "sub", code: " https://platform.claude.com/oauth/code/callback?code=good-code&state=y " },
        { do: "until", profile: "sub", state: "done" },
      ],
    },
    {
      what: "Claude: a code it would not take ends the sign-in",
      steps: [
        { do: "start", login: claude },
        { do: "until", profile: "sub", state: "needs_code" },
        { do: "submit", profile: "sub", code: "refused#y", lang: "en" },
        { do: "until", profile: "sub", state: "failed" },
      ],
    },
    {
      what: "Codex: a device code, approved",
      steps: [
        { do: "start", login: codex },
        { do: "until", profile: "cxs", state: "needs_approval" },
        { do: "approve", profile: "cxs", command: `${exe(fake)} login` },
        { do: "until", profile: "cxs", state: "done" },
      ],
    },
    {
      what: "a sign-in cancelled",
      steps: [
        { do: "start", login: codex },
        { do: "until", profile: "cxs", state: "needs_approval" },
        { do: "cancel", profile: "cxs" },
        { do: "get", profile: "cxs" },
        { do: "get", profile: "nobody" },
      ],
    },
    {
      what: "OpenCode's Console: asked until approved, its tokens kept",
      routes: consoleRoutes,
      steps: [
        { do: "startConsole", profile: "oc", home: join(homes, "oc") },
        { do: "get", profile: "oc" },
        { do: "advance", ms: 1000 },
        { do: "until", profile: "oc", state: "needs_approval" },
        { do: "advance", ms: 1000 },
        { do: "until", profile: "oc", state: "needs_approval" },
        { do: "advance", ms: 6000 },
        { do: "until", profile: "oc", state: "done" },
      ],
    },
    {
      what: "OpenCode's Console refusing",
      routes: { "/auth/device/code": [{ body: { device_code: "dc", user_code: "U", verification_uri_complete: "https://x.example/d" } }], "/auth/device/token": [{ status: 400, body: { error: "access_denied" } }] },
      steps: [
        { do: "startConsole", profile: "oc", home: join(homes, "oc2") },
        { do: "advance", ms: 5000 },
        { do: "until", profile: "oc", state: "failed" },
      ],
    },
  ];
  for (const s of scenarios) {
    const data = join(root, `data-${scenarios.indexOf(s)}`);
    rmSync(homes, { recursive: true, force: true });
    rmSync(approvalPath, { force: true });
    const server = await serve(s.routes ?? {});
    const clock = testClock();
    const env = { PATH: "/usr/bin:/bin", HOME: root };
    const logins = new LoginManager(data, { claude: exe(fake), codex: exe(fake) }, () => ({ ...env }), clock.clock, server.base);
    const unfreeze = frozen();
    const ts: unknown[] = [];
    // A timer of a sign-in's is armed once what it asked is answered: the clock is moved on only after it is.
    let armed = 0;
    try {
      for (const step of s.steps) {
        const lang = (step.lang ?? "zh") as "zh" | "en";
        if (step.do === "start") ts.push(await outcome(() => logins.start(step.login as never, lang)));
        else if (step.do === "startConsole") {
          ts.push(await outcome(() => logins.startConsole({ id: step.profile!, home: step.home! }, lang)));
          armed = clock.asked();
        }
        else if (step.do === "submit") ts.push(await outcome(() => logins.submitCode(step.profile!, step.code!, lang)));
        else if (step.do === "cancel") ts.push((logins.cancel(step.profile!), null));
        else if (step.do === "approve") ts.push((writeFileSync(approvalPath, "approved\n"), null));
        else if (step.do === "advance") {
          await clock.begun(armed);
          await clock.adjust(step.ms!);
          armed = clock.asked() + 1;
          ts.push(null);
        }
        else if (step.do === "until") ts.push(plain(await upon((wake) => logins.changes(wake), () => (logins.get(step.profile!)?.state === step.state ? logins.get(step.profile!) : undefined), `${step.profile} ${step.state}`)));
        else ts.push(plain(logins.get(step.profile!)));
      }
    } finally {
      unfreeze();
      await logins.close();
      await server.close();
    }
    const specs = fakeSpecs(exe(fake));
    const got = await mb({ op: "login", now: 0, wall: NOW, data, commands: specs, names: { claude: exe(fake), codex: exe(fake) }, env, console: server.base, routes: s.routes ?? {}, steps: s.steps, root: homes });
    const shown = (v: any) => JSON.parse(JSON.stringify(v).replaceAll(server.base, "BASE"));
    assert.deepEqual(shown(got.steps), shown(ts), s.what);
    assert.deepEqual(askedMb(got.requests), askedTs(server.asked), `${s.what}: asked`);
    let left: Record<string, string> = {};
    try {
      left = filesUnder(homes);
    } catch {}
    assert.deepEqual(got.files, left, `${s.what}: files`);
  }
});
