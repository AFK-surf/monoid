// The accounts in MoonBit (station/mb src/accounts_pool, `stillfail-reader-harness --builder harness-accounts-pool`) held to the
// TypeScript they are the MoonBit of: src/accounts/{index,quota,agy-quota,claude-reset,cursor,kimi,check,pace}.ts,
// src/sessions/accounts.ts and the pool (src/sessions/pool.ts). Each side is given the same world and asked the same:
// the functions on the same values (seeded random ones too), what reads a provider or a file against the same local
// providers and files (the program's requests and reads made by this test as Node makes them), and the accounts and the
// session accounts run in lockstep on the same asks (their stores, config.json, the hub and the other parts each its
// own of the same kind, their clocks moved together), their answers, their refusals, what they kept and what they
// told compared.
import assert from "node:assert/strict";
import { type ChildProcessWithoutNullStreams, spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { mkdir, readFile, rename, rm, stat, access, readdir } from "node:fs/promises";
import { arch, hostname, release, tmpdir, type } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { randomBytes, randomUUID } from "node:crypto";
import { after, before, describe, test } from "node:test";
import zhStation from "../../client/i18n/catalog/zh/station.json" with { type: "json" };
import enStation from "../../client/i18n/catalog/en/station.json" with { type: "json" };
import { mbHarnessBinary } from "./mb-harness.ts";
import { wall } from "../src/ops/fibers.ts";
import { Store } from "../src/store/store.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hubConfig, spelling, allowedIn, sameModel } from "../src/sessions/config.ts";
import { availableEfforts, cheapToLeave, commonEfforts, fallbackEfforts, pickProfile, reportedEfforts, urgency, usable } from "../src/sessions/pool.ts";
import { Accounts as SessionAccounts } from "../src/sessions/accounts.ts";
import { Accounts, checkLabel, mask, secretKey, slug, unique } from "../src/accounts/index.ts";
import { checkAutomaticDecisions, checkConfig } from "../src/accounts/check.ts";
import { paceView, spendScopes, spendWeight } from "../src/accounts/pace.ts";
import { price, modelKey } from "../src/read/usage.ts";
import {
  at, blocked, checkQuota, claudeUsage, claudeWithRefresh, codexQuota, codexUsage, codexWindows, grokQuotaOf, kimiWindows, lentCodexUsage, percent, windowLabel,
} from "../src/accounts/quota.ts";
import { claimOutcome, claudeClaim, claudeHeaders, claudeResets, claudeResetWith, grantKind } from "../src/accounts/claude-reset.ts";
import { agyAllowance, agyQuota, agyScopeForModel } from "../src/accounts/agy-quota.ts";
import { cursorHandshake, cursorIn, cursorMe, cursorModels, mintCursorKey, pollCursor, readCursor, writeCursor } from "../src/accounts/cursor.ts";
import { kimiDeviceToken, kimiDue, kimiHeaders, readKimi, renewKimiToken, startKimiDevice, writeKimi } from "../src/accounts/kimi.ts";
import { codexQuotaFailure } from "../../client/core-ts/src/codex-quota.ts";
import { profileRuntimes, billedPerUse, takesFast } from "../src/agents/profiles.ts";
import { cleanEndpoint } from "../src/agents/providers.ts";
import { agyBaseModel, agyCompany, agyPlan, classifyFailure, agyTakeBack } from "../src/agents/agy.ts";
import { expandDevinFusion } from "../src/agents/devin.ts";
import { claudeOAuthToken } from "../src/accounts/oauth.ts";
import { codexAccountIdentity, codexClaimsIn } from "../src/accounts/machine.ts";
import { consoleIn } from "../src/accounts/console.ts";
import { uncheckOutdated } from "../src/accounts/models.ts";
import { catalog as catalogNow, learn } from "../src/accounts/catalog.ts";
import { platform } from "../src/platform/index.ts";
import { fingerprint, resolvedModel } from "../src/sessions/decision.ts";
import { withShellCommand } from "../src/ops/shell-path.ts";
import { provider, temp } from "./accounts-fakes.ts";
import { rng } from "./lock-chains.ts";
import { settle, testClock } from "./hub-fakes.ts";

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
const SEEDS = Number(process.env.ACCOUNTS_POOL_SEEDS ?? 300);
const TZ = -new Date(Date.UTC(2026, 10, 16)).getTimezoneOffset() * 60_000;

const dirs: string[] = [];
const tmp = (name = "mb-accounts-pool") => {
  const d = mkdtempSync(join(tmpdir(), `${name}-`));
  dirs.push(d);
  return d;
};
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

type Json = any;
type Handler = (name: string, args: Json[]) => unknown;

/// What a failure is as the program is told it: its class, words, status and code.
function thrown(e: unknown): Json {
  const err = e as any;
  const out: Json = { kind: err?.constructor?.name ?? "Error", message: err?.message ?? String(e) };
  if (err?.name && err.name !== out.kind) out.name = err.name;
  if (typeof err?.status === "number") out.status = err.status;
  if (typeof err?.code === "string") out.code = err.code;
  return out;
}

/// The program, asked a line at a time; what it calls is answered by `handle`.
class Program {
  readonly #p: ChildProcessWithoutNullStreams;
  readonly #waiting = new Map<string, { ok: (v: any) => void; no: (e: any) => void }>();
  #next = 0;
  handle: Handler = (name) => {
    throw new Error(`no part ${name}`);
  };
  readonly ready: Promise<void>;
  constructor(setup: Json) {
    this.#p = spawn(binary!, ["--builder", "harness-accounts-pool", "--shell-dir", tmp("mb-ap-shell")], { stdio: ["pipe", "pipe", "pipe"] });
    let ready!: () => void;
    this.ready = new Promise((r) => (ready = r));
    createInterface({ input: this.#p.stdout }).on("line", (line) => {
      const m = JSON.parse(line);
      if (m.ready) return ready();
      if (process.env.ACCOUNTS_POOL_TRACE) process.stderr.write(`mb> ${line.slice(0, 300)}\n`);
      if ("call" in m) return void this.#answer(m.call, m.name, m.args);
      const key = "ans" in m ? `a${m.ans}` : "advanced" in m ? "advance" : "settled" in m ? `s${m.settled}` : "";
      const w = this.#waiting.get(key);
      this.#waiting.delete(key);
      if ("error" in m) w?.no(m.error);
      else w?.ok(m.value);
    });
    this.#p.stderr.on("data", (d) => process.stderr.write(d));
    this.#p.on("exit", (code, signal) => {
      for (const w of this.#waiting.values()) w.no({ kind: "Exit", message: `the program ended (${code ?? signal})` });
      this.#waiting.clear();
    });
    this.#p.stdin.write(`${JSON.stringify({ setup })}\n`);
  }
  async #answer(n: number, name: string, args: Json[]) {
    let line: Json;
    try {
      const value = await this.handle(name, args.map(undef));
      line = { ret: n, value: value === undefined ? { $undef: 1 } : value };
    } catch (e) {
      line = { ret: n, throw: thrown(e) };
    }
    this.#p.stdin.write(`${JSON.stringify(line)}\n`);
  }
  #send(key: string, line: Json): Promise<any> {
    return new Promise((ok, no) => {
      this.#waiting.set(key, { ok, no });
      this.#p.stdin.write(`${JSON.stringify(line)}\n`);
    });
  }
  ask(op: string, ...args: Json[]): Promise<any> {
    const id = ++this.#next;
    return this.#send(`a${id}`, { ask: id, op, args: args.map((a) => (a === undefined ? { $undef: 1 } : a)) }).then(undef);
  }
  /// What the ask answers, or its failure as `{error}`.
  async said(op: string, ...args: Json[]): Promise<any> {
    try {
      return { value: await this.ask(op, ...args) };
    } catch (e) {
      return { error: e };
    }
  }
  advance(ms: number): Promise<void> {
    return this.#send("advance", { advance: ms });
  }
  settle(): Promise<void> {
    const id = ++this.#next;
    return this.#send(`s${id}`, { settle: id });
  }
  close() {
    this.#p.stdin.end();
  }
}

/// JavaScript's undefined as the program says it.
function undef(v: any): any {
  if (v !== null && typeof v === "object" && !Array.isArray(v)) {
    const keys = Object.keys(v);
    if (keys.length === 1 && keys[0] === "$undef") return undefined;
  }
  return v;
}

/// What the TypeScript gives, or its failure as the program says one.
async function tsSaid(f: () => unknown): Promise<any> {
  try {
    return { value: JSON.parse(JSON.stringify((await f()) ?? null)) };
  } catch (e) {
    return { error: thrown(e) };
  }
}

/// A failure compared by what people are told of it: its words and status.
function sameError(mb: any, ts: any, what: string) {
  assert.ok(mb.error !== undefined && ts.error !== undefined, `${what}: both refuse (mb ${JSON.stringify(mb)}, ts ${JSON.stringify(ts)})`);
  assert.equal(mb.error.message, ts.error.message, `${what}: the same words`);
  assert.equal(mb.error.status, ts.error.status, `${what}: the same status`);
}

function same(mb: any, ts: any, what: string) {
  if (ts.error !== undefined || mb.error !== undefined) return sameError(mb, ts, what);
  assert.deepEqual(mb.value ?? null, ts.value ?? null, what);
}

const baseSetup = (more: Json = {}) => ({ zh: zhStation, en: enStation, product: "still.fail", stationLang: "zh", tzOffsetMs: TZ, now: 0, ...more });

/// The parts every IO function asks: HTTP as Node's fetch makes it, the files as node:fs reads them.
function ioHandler(extra: Handler = () => undefined): Handler {
  return async (name, args) => {
    switch (name) {
      case "fetch": {
        const r = args[0];
        const response = await fetch(r.url, { method: r.method ?? "GET", headers: r.headers, body: r.body, signal: AbortSignal.timeout(r.timeoutMs) });
        return { status: response.status, text: await response.text() };
      }
      case "fs.readFile":
        return readFile(args[0], "utf8");
      case "fs.writePrivate":
        mkdirSync(join(args[0], ".."), { recursive: true });
        writeFileSync(args[0], args[1], { mode: 0o600 });
        return null;
      case "fs.mkdir":
        await mkdir(args[0], { recursive: true });
        return null;
      case "fs.rm":
        await rm(args[0], { recursive: true, force: true });
        return null;
      case "fs.rename":
        await rename(args[0], args[1]);
        return null;
      case "fs.readdir":
        return readdir(args[0]);
      case "fs.exists":
        return access(args[0]).then(() => true, () => false);
      case "fs.stamp": {
        const st = await stat(args[0]);
        return `${st.size}:${st.mtimeMs}`;
      }
      case "os.info":
        return { hostname: hostname(), type: type(), arch: arch(), release: release() };
      case "crypto.randomHex":
        return randomBytes(args[0]).toString("hex");
      case "crypto.randomUUID":
        return randomUUID();
      default: {
        const v = await extra(name, args);
        if (v === undefined) throw new Error(`no part ${name}`);
        return v;
      }
    }
  };
}

describe("accounts_pool: functions", { skip }, () => {
  let p: Program;
  before(async () => {
    p = new Program(baseSetup());
    await p.ready;
  });
  after(() => p?.close());

  const MODELS = [
    "claude-opus-5-5", "anthropic/claude-opus-5-5[1m]", "Claude-Opus-5-5-20251101", "us.anthropic.claude-sonnet-5-5-v1:0", "gpt-6.1-terra",
    "openai/gpt-6.1-terra@2026-11-01", "gemini-4-carbon-high", "gemini-4-argon", "fusion-claude-opus-5-5-high-sidekick-swe-2-medium",
    "fusion-gpt-6-sol-sidekick-glm-5-2", "claude-fable-5-2", "claude-mythos-5-1", "gemma-3", "glm-5-2", "kimi-k3-2026-01-01", "", " spaced ",
    "a.b.c.model", "deepseek-v4", "gpt-oss-120b-medium", "swe-2-high", "Gemini-4-Carbon-Max", "x/y/z", "claude-opus-4-8-20250601",
  ];

  test("model keys, spellings and a profile's runtimes", async () => {
    for (const m of MODELS) assert.equal(await p.ask("modelKey", m), modelKey(m), m);
    for (const a of MODELS) for (const b of MODELS.slice(0, 8)) assert.equal(await p.ask("sameModel", a, b), sameModel(a, b), `${a} ~ ${b}`);
    for (const m of MODELS) assert.equal(await p.ask("agyBaseModel", m), agyBaseModel(m).model, m);
    for (const e of ["https://x.test/", "http://a b", "ftp://x", " https://y.test/v1// ", "https://", "http://ok"]) assert.equal(await p.ask("cleanEndpoint", e), cleanEndpoint(e) ?? null, e);
  });

  /// A random config.json's profiles and connects (shapes a person writes, and some they would not).
  function randomRaw(r: ReturnType<typeof rng>): Json {
    const kinds = ["subscription", "opencode-go", "anthropic-api", "env", "api-provider", undefined, "nonsense"];
    const runtimes = ["claude", "codex", "dsh", "grok", "cursor", "devin", "hermes", "agy", "pi", undefined];
    const providers = ["openai", "anthropic", "google", "xai", "kimi-code", "openrouter", "custom", "cloudflare-ai-gateway", "ollama", "azure-openai", "nope", undefined];
    const profiles = Array.from({ length: 1 + r.int(5) }, (_, i) => {
      const kind = r.pick(kinds);
      const p: Json = { id: r.next() < 0.1 ? `P_${i}` : `p${i}`, home: r.next() < 0.1 ? "" : r.next() < 0.5 ? `homes/p${i}` : `/abs/p${i}` };
      const runtime = r.pick(runtimes);
      if (runtime !== undefined) p.runtime = runtime;
      if (kind !== undefined) {
        p.access = { kind };
        if (r.next() < 0.6) p.access.key = r.next() < 0.2 ? "  " : `k-${r.int(1000)}-secretvalue`;
        if (kind === "api-provider") {
          const pv = r.pick(providers);
          if (pv !== undefined) p.access.provider = pv;
          if (r.next() < 0.5) p.access.endpoint = r.pick(["https://gw.test/v1", "https://gw.test/compat", "nope", "http://local:11434/"]);
          if (r.next() < 0.3) p.access.protocol = r.pick(["chat_completions", "responses", "anthropic", "x"]);
          if (r.next() < 0.3) p.access.login = r.next() < 0.5;
        }
        if (kind === "opencode-go" && r.next() < 0.3) p.access.login = true;
      }
      if (r.next() < 0.5) p.models = r.next() < 0.1 ? [1, "a"] : Array.from({ length: r.int(4) }, () => r.pick(MODELS));
      if (r.next() < 0.3) p.model = r.pick(MODELS);
      if (r.next() < 0.3) p.name = r.pick(["Work", "  ", "b@x.com（本机）", "Local Codex", "本机 a", "x (local)"]);
      if (r.next() < 0.2) p.machine = r.next() < 0.7;
      if (r.next() < 0.2) p.enabled = r.next() < 0.5;
      if (r.next() < 0.2) p.backgroundOnMessage = false;
      if (r.next() < 0.2) p.withheld = ["ws2", "", 3].slice(0, r.int(3));
      if (r.next() < 0.2) p.env = r.next() < 0.1 ? { A: 1 } : { API_KEY: "abcdefghijklmn", PLAIN: "v" };
      if (r.next() < 0.1) p.share = { borrowed: true, workspaces: ["ws1"], email: "lent@x.com" };
      return p;
    });
    const connects = Array.from({ length: r.int(3) }, (_, i) => {
      const c: Json = { id: r.next() < 0.1 ? `C${i}` : `c${i}`, bind: { runtime: r.pick(["claude", "codex", "agy", "cursor", "pi", "x", undefined]) } };
      if (r.next() < 0.5) c.bind.model = r.pick(MODELS);
      if (r.next() < 0.3) c.bind.effort = r.pick(["none", "minimal", "low", "high", "max", "xhigh", "weird", ""]);
      if (r.next() < 0.3) c.bind.profiles = r.next() < 0.1 ? [1] : ["p0", " p1 ", ""];
      if (r.next() < 0.3) c.mode = r.pick(["single-session", "multi-session", "other"]);
      if (r.next() < 0.3) c.kind = r.pick(["slack", "feishu", "comma", "group", "irc"]);
      if (r.next() < 0.3) c.workspace = r.pick(["ws1", "ws2", ""]);
      if (r.next() < 0.2) c.slack = { botName: "Bot" };
      return c;
    });
    const raw: Json = { profiles, connects };
    if (r.next() < 0.2) raw.automaticDecisions = r.pick([{ completion: { enabled: true, model: "m" } }, { completion: { enabled: null } }, { other: 1 }, { completion: { x: 1 } }, 3]);
    if (r.next() < 0.1) raw.tools = r.pick([{ access: "read" }, { access: "bad" }, 1]);
    if (r.next() < 0.1) raw.agentEnv = r.pick([{ A_B: "x" }, { "1A": "x" }, { A: 1 }, "x"]);
    if (r.next() < 0.1) raw.network = r.pick([{ congestion: "bbr" }, { congestion: "x" }, []]);
    if (r.next() < 0.1) raw.sandboxes = r.pick([[{ name: "s1", target: "{name}.ws@host" }], [{ name: "s1", target: "bad" }], "x", [{ name: "a", target: "{name}@h" }, { name: "A", target: "{name}@h" }]]);
    if (r.next() < 0.1) raw.drive = r.pick([{ roots: ["/a"] }, { roots: [1] }, { workspaces: { w: ["/a"] } }, { workspaces: { w: "x" } }]);
    return raw;
  }

  test("config.json: what hubConfig makes of it, and what checkConfig refuses, in the same words", async () => {
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(seed);
      const raw = randomRaw(r);
      const found: Record<string, string[]> = r.next() < 0.5 ? { p0: ["claude-opus-5-5", "gpt-6.1-terra", ""], p1: ["gemini-4-carbon"] } : {};
      const ts = hubConfig(raw, "/data", (id) => found[id] ?? null);
      const mb = await p.ask("hubConfig", raw, "/data", found);
      assert.deepEqual(mb.profiles, JSON.parse(JSON.stringify(ts.profiles)), `seed ${seed}: profiles`);
      assert.deepEqual(mb.connects, ts.connects.map((c) => c.id), `seed ${seed}: connects`);
      assert.equal(mb.completion, ts.automaticDecisions.completion.enabled, `seed ${seed}: decisions`);
      same(await p.said("checkConfig", raw, "/data"), await tsSaid(() => checkConfig(raw, "/data")), `seed ${seed}: checkConfig`);
      if (raw.automaticDecisions !== undefined) same(await p.said("checkAutomaticDecisions", raw.automaticDecisions), await tsSaid(() => checkAutomaticDecisions(raw.automaticDecisions)), `seed ${seed}: decisions`);
      for (const pr of ts.profiles) {
        for (const m of MODELS.slice(0, 12)) assert.equal(await p.ask("spelling", pr, m), spelling(pr, m), `seed ${seed}: ${pr.id} spells ${m}`);
        for (const [ws, home] of [[null, "ws1"], ["ws2", "ws1"], ["ws1", "ws1"], ["ws3", null]] as const) assert.equal(await p.ask("allowedIn", pr, ws, home), allowedIn(pr, ws, home), `seed ${seed}: allowed ${ws}`);
        const plain = raw.profiles.find((x: Json) => x?.id === pr.id) ?? {};
        assert.deepEqual(await p.ask("profileRuntimes", plain), profileRuntimes(plain), `seed ${seed}: runtimes`);
        assert.equal(await p.ask("billedPerUse", plain), billedPerUse(plain), `seed ${seed}: billed`);
        assert.equal(await p.ask("takesFast", pr), takesFast(pr), `seed ${seed}: fast`);
      }
    }
    for (const raw of [
      { connects: [{ id: "c", bind: { runtime: "agy", effort: "high" } }] },
      { connects: [{ id: "c", bind: { runtime: "agy", effort: "ultra" } }] },
      { connects: [{ id: "c", bind: { runtime: "cursor", effort: "high" } }] },
    ]) {
      same(await p.said("checkConfig", raw, "/data"), await tsSaid(() => checkConfig(raw, "/data")), JSON.stringify(raw));
    }
  });

  /// A random allowance as providers give them (windows with and without lengths and refills, due or not).
  function randomQuota(r: ReturnType<typeof rng>, now: number): Json {
    if (r.next() < 0.1) return r.pick([null, undefined, { state: "unavailable", windows: [], detail: "x" }]);
    const windows = Array.from({ length: r.int(4) }, () => {
      const w: Json = { label: "w", usedPercent: r.pick([0, 12, 50, 79, 80, 95, 100, 120, "77", null]) };
      if (r.next() < 0.8) w.minutes = r.pick([300, 10080, 1440, 43200, 0, null]);
      if (r.next() < 0.7) w.resetsAt = r.pick([now - 1000, now + 3600_000, now + 6 * 86_400_000, now + 10, null]);
      if (r.next() < 0.3) w.scope = r.pick(["gemini", "3p", null]);
      return w;
    });
    const q: Json = { state: "ok", windows, detail: null, checkedAt: now - r.int(4000_000) };
    if (r.next() < 0.3) q.scoped = [{ label: "每周 · Fable", usedPercent: r.pick([10, 100]), resetsAt: r.pick([null, now + 1000]), minutes: 10080, scope: r.pick(["Fable", "Argon"]) }];
    return q;
  }

  test("the pool: urgency, usable, the pick, leaving cheaply, reasoning levels", async () => {
    const raw = { profiles: [
      { id: "a", home: "a", runtime: "claude", access: { kind: "subscription" }, models: ["claude-opus-5-5"] },
      { id: "b", home: "b", runtime: "claude", access: { kind: "anthropic-api", key: "k" }, models: ["claude-opus-5-5", "claude-sonnet-5-5"] },
      { id: "c", home: "c", runtime: "codex", access: { kind: "subscription" }, models: ["gpt-6.1-terra"] },
      { id: "d", home: "d", runtime: "agy", access: { kind: "subscription" }, models: ["gemini-4-carbon"] },
      { id: "e", home: "e", runtime: "devin", access: { kind: "subscription" }, models: ["swe-2", "claude-opus-5-5"] },
    ] };
    const profiles = hubConfig(raw, "/d").profiles;
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(1000 + seed);
      const now = 1_800_000_000_000;
      const q = randomQuota(r, now);
      assert.deepEqual(await p.ask("urgency", q ?? null, now), urgency(q, now), `seed ${seed}: urgency`);
      const health: Json = { check: r.pick([null, { state: "ok" }, { state: "login" }, { state: "failed" }]), quota: q ?? null };
      if (r.next() < 0.2) health.spent = true;
      assert.equal(await p.ask("usable", health, now), usable(health, now), `seed ${seed}: usable`);
      const healths: Record<string, Json> = {};
      const loads: Record<string, number> = {};
      const picked: Record<string, number> = {};
      for (const pr of profiles) {
        healths[pr.id] = { check: r.pick([null, { state: "ok" }, { state: "login" }]), quota: randomQuota(r, now) ?? null, ...(r.next() < 0.1 ? { spent: true } : {}) };
        loads[pr.id] = r.int(4);
        picked[pr.id] = r.pick([0, now - 1000, now - 5000]);
      }
      const candidates = profiles.filter(() => r.next() < 0.8);
      const model = r.pick([null, "claude-opus-5-5", "gpt-6.1-terra", "gemini-4-carbon-high", "nope"]);
      const strict = r.next() < 0.5;
      const ts = await tsSaid(() => pickProfile(candidates, model, { health: (id) => healths[id]!, load: (id) => loads[id]!, lastPicked: (id) => picked[id]!, now: () => now }, strict).id);
      same(await p.said("pickProfile", candidates, model, healths, loads, picked, now, strict), ts, `seed ${seed}: pick`);
      const calls = Array.from({ length: r.int(6) }, () => ({ turn: r.pick(["t1", "t2", "t3", null]), profile: r.pick(["a", "b"]), model: r.pick(["m", null]), context: r.pick([null, 10_000, 60_000, 120_000, 20_000]) }));
      const points = r.next() < 0.5 ? { m: 100_000 } : {};
      assert.equal(await p.ask("cheapToLeave", calls, points), cheapToLeave(calls, new Map(Object.entries(points))), `seed ${seed}: cheap`);
      const catalog: Json = r.pick([null, { codex: { "gpt-6.1-terra": ["low", "high"] } }, { agy: { "gemini-4-carbon": ["low"] } }, { devin: { "claude-opus-5-5": ["max"] } }, { codex: { "openai/gpt-6.1-terra": ["medium"] } }]);
      for (const rt of ["codex", "agy", "devin", "claude", "dsh", "grok", "hermes"]) {
        const m = r.pick([null, "gpt-6.1-terra", "gemini-4-carbon-high", "fusion-claude-opus-5-5-sidekick-swe-2-medium"]);
        assert.deepEqual(await p.ask("reportedEfforts", rt, m, catalog), reportedEfforts(rt, m, catalog), `seed ${seed}: reported ${rt}`);
        assert.deepEqual(await p.ask("availableEfforts", rt, m, catalog), availableEfforts(rt, m, catalog), `seed ${seed}: available ${rt}`);
        assert.deepEqual(await p.ask("fallbackEfforts", rt), fallbackEfforts(rt));
      }
      const lists = Array.from({ length: r.int(3) }, () => ["low", "medium", "high", "max"].filter(() => r.next() < 0.6));
      assert.deepEqual(await p.ask("commonEfforts", lists, "codex"), commonEfforts(lists, "codex"), `seed ${seed}: common`);
    }
  });

  test("pace: an hour's weight, the windows it counts against, the view", async () => {
    learn({ "claude-opus-5-5": { cost: { input: 4, output: 20, cacheRead: 0.2 }, maker: "anthropic" }, "kimi-k3": { cost: { input: 1, output: 3 } } });
    const cat = catalogNow().models;
    try {
      for (let seed = 1; seed <= SEEDS; seed++) {
        const r = rng(2000 + seed);
        const s = { hour: 490_000 + r.int(5), profile: r.pick(["a", "b", "c"]), runtime: r.pick(["claude", "agy", "codex"]), model: r.pick([null, "claude-opus-5-5", "anthropic/claude-fable-5-2[1m]", "gemini-4-argon-high", "gpt-6.1-terra", "kimi-k3", "unknown-x", "google/gemma-3", "vertex.claude-mythos-5"]), fast: r.next() < 0.3, calls: 1, input: r.int(100000), cacheRead: r.int(10000), cacheWrite: r.int(1000), cacheWriteLong: r.int(100), output: r.int(5000) };
        assert.equal(await p.ask("spendWeight", s, cat), spendWeight(s), `seed ${seed}: weight`);
        assert.deepEqual(await p.ask("spendScopes", s.runtime, s.model), spendScopes(s.runtime, s.model), `seed ${seed}: scopes`);
        if (s.model !== null) assert.deepEqual(await p.ask("price", s.model, cat), price(s.model), `seed ${seed}: price`);
      }
      const r = rng(77);
      const read = {
        quotas: [{ profile: "a", hour: 490_000, at: 1, windows: [] }, { profile: "x", hour: 490_001, at: 2, windows: [{ label: "w" }] }],
        spend: Array.from({ length: 40 }, () => ({ hour: 490_000 + r.int(3), profile: r.pick(["a", "b", "x", "10"]), runtime: r.pick(["claude", "agy"]), model: r.pick(["claude-fable-5-2", "gemini-4-argon", null, "claude-opus-5-5"]), fast: false, calls: 1, input: r.int(1000), cacheRead: 0, cacheWrite: 0, cacheWriteLong: 0, output: r.int(1000) })),
      };
      const shown = ["a", "b", "10"];
      assert.deepEqual(await p.ask("paceView", 490_002 * 3_600_000 + 5, read, shown, cat), paceView(490_002 * 3_600_000 + 5, read as any, (id) => shown.includes(id)));
    } finally {
      learn({});
    }
  });

  test("allowances read of providers' answers: times, percentages, labels, Codex's, Kimi's, Grok's, refusals", async () => {
    for (const v of [1794830399, 1794830399936, "2026-11-16T11:59:59.936566+00:00", "2026-11-16T11:59:59", "2026-11-16T11:59:59Z", "2026-11-16T11:59", "2026-11-16", "", null, "2026-02-30T00:00:00Z", "2026-11-16T24:00:00Z", "2026-11-16T11:59:59+0000", "2026-11-16T11:59:59z", "2026-13-01T00:00:00Z", 1.5]) {
      assert.equal(await p.ask("at", v), at(v), JSON.stringify(v));
    }
    for (const v of [0, 0.5, 1.5, -1.5, 99.5, 100.4, 120, "42.5", " 7 ", "", "x", null, true, -0]) assert.equal(await p.ask("percent", v), percent(v), JSON.stringify(v));
    for (const m of [null, 0, -5, 60, 90, 300, 360, 361, 1440, 2880, 8640, 10080, 11520, 11521, 38880, 43200, 1e9]) assert.equal(await p.ask("windowLabel", m, "fb"), windowLabel(m, "fb"), String(m));
    for (const t of ["Account on hold", "fine", "SUSPENDED", "Violation of terms", ""]) assert.equal(await p.ask("blocked", t), blocked(t), t);
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(3000 + seed);
      const w = () => (r.next() < 0.2 ? r.pick([null, 3, "x"]) : { usedPercent: r.pick([5, 50.5, "33", null]), resetsAt: r.pick([1794830399, "2026-11-16T11:59:59Z", null]), ...(r.next() < 0.5 ? { windowDurationMins: r.pick([300, 10080, 0, 1440]) } : {}) });
      const limits: Json = { primary: w(), secondary: w() };
      if (r.next() < 0.5) limits.credits = { hasCredits: r.next() < 0.5, unlimited: r.next() < 0.2, balance: r.pick(["5", 3, null]) };
      if (r.next() < 0.3) limits.planType = r.pick([" plus ", "", 3]);
      const result: Json = r.next() < 0.5 ? { rateLimits: limits } : limits;
      if (r.next() < 0.5) result.rateLimitResetCredits = { availableCount: r.pick([0, 1, 2, 2.5, -1]), credits: [{ status: "available", expiresAt: r.pick(["2026-11-20T00:00:00Z", 1794830399, null]) }, { status: "used", expiresAt: 1 }, { status: "available", expires_at: 1794830499 }] };
      assert.deepEqual(await p.ask("codexWindows", result), JSON.parse(JSON.stringify(codexWindows(result))), `seed ${seed}: codex windows`);
      assert.deepEqual(await p.ask("codexQuota", result, "zh"), JSON.parse(JSON.stringify(codexQuota(result, "zh"))), `seed ${seed}: codex quota`);
      const item = () => ({ window: r.next() < 0.5 ? { duration: r.pick([300, 5, "1", null]), timeUnit: r.pick(["TIME_UNIT_MINUTE", "TIME_UNIT_HOUR", "TIME_UNIT_DAY", "", null]) } : undefined, detail: r.next() < 0.5 ? { limit: r.pick([100, "200", 0, null]), used: r.pick([10, null]), remaining: r.pick([50, "x"]), resetTime: r.pick(["2026-11-16T11:59:59Z", null]) } : undefined, limit: 10, used: 3 });
      const body: Json = { limits: Array.from({ length: r.int(3) }, item), usage: r.pick([null, { limit: 100, used: 40, reset_at: 1794830399 }, { limit: "50", remaining: 10 }]) };
      assert.deepEqual(await p.ask("kimiWindows", body), JSON.parse(JSON.stringify(kimiWindows(body))), `seed ${seed}: kimi`);
      const said: Json = r.pick([null, {}, { subscription_tier: " SuperGrok ", config: { creditUsagePercent: 42, currentPeriod: { start: "2026-11-01T00:00:00Z", end: "2026-12-01T00:00:00Z", type: "MONTHLY" } } }, { config: { currentPeriod: { type: "WEEKLY" } } }, { subscription_tier: "x", config: {} }]);
      assert.deepEqual(await p.ask("grokQuotaOf", said, "en"), JSON.parse(JSON.stringify(grokQuotaOf(said, "en"))), `seed ${seed}: grok`);
    }
    for (const d of [
      'codex {"code":-32603,"message":"failed to fetch codex rate limits: request failed: 401 Unauthorized"}',
      "failed to fetch codex rate limits: token_revoked", "failed to fetch codex rate limits: Your account has been suspended",
      "failed to fetch codex rate limits: request failed: 503", "failed to fetch codex rate limits: request failed:429 x", "operation timed out", "dns error", "else",
      "Failed To Fetch Codex Rate Limits: organization was deactivated today",
    ]) assert.deepEqual(await p.ask("codexQuotaFailure", d), codexQuotaFailure(d), d);
  });

  test("a Claude subscription's resets: kinds, claims, outcomes", async () => {
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(4000 + seed);
      const grant = () => ({ id: r.pick(["g1", "g2", "g3", 4]), resets_left: r.pick([0, 1, 2, 1.5]), usable_now: r.next() < 0.5, ends_at: r.pick(["2026-11-20T00:00:00Z", "2026-11-18T00:00:00Z", null, "bad"]), paused: r.next() < 0.1, type: r.pick([undefined, "fable", "session", "weekly", "full", "other"]), clears: r.pick([undefined, ["five_hour"], ["seven_day"], ["five_hour", "seven_day"]]), gives_back_weekly: r.next() < 0.1 });
      const body: Json = {
        juniper_tide: r.pick([null, { eligible: true, arm: "reset", available: true }, { eligible: true, arm: "reset", available: false }, { eligible: false }]),
        cedar_ember: r.pick([null, { eligible: true, grants: Array.from({ length: r.int(4) }, grant), next_grant_id: r.pick(["g2", undefined]) }, { eligible: false, grants: [grant()] }]),
      };
      const model = r.pick([null, "Argon"]);
      assert.deepEqual(await p.ask("claudeResets", body, model), JSON.parse(JSON.stringify(claudeResets(body, model))), `seed ${seed}: resets`);
      for (const kind of [null, "session", "weekly", "model", "full"]) assert.deepEqual(await p.ask("claudeClaim", body, `key-${seed}`, kind), claudeClaim(body, `key-${seed}`, kind), `seed ${seed}: claim ${kind}`);
      for (const g of body.cedar_ember?.grants ?? []) assert.equal(await p.ask("grantKind", g), grantKind(g));
    }
    for (const o of ["reset", "already_used", "not_limited", "cooldown", "ineligible", "x", null]) assert.equal(await p.ask("claimOutcome", o), claimOutcome(o));
    assert.deepEqual(await p.ask("claudeHeaders", "t", "2.1.0"), claudeHeaders("t", "2.1.0"));
    assert.deepEqual(await p.ask("claudeHeaders", "t", null), claudeHeaders("t", null));
  });

  test("an Antigravity account's allowance and which of its groups a model counts against", async () => {
    const groupNames = ["Gemini Models", "Claude and GPT models", "Gemini 3 Pro", "Gemini Argon", "Claude Opus 4.5", "", "Gemini", "claude / gpt", "Custom Thing", "Gemini 3.1 Flash Lite", "Gemini  Models"];
    for (let seed = 1; seed <= SEEDS; seed++) {
      const r = rng(5000 + seed);
      const groups = Array.from({ length: 1 + r.int(3) }, () => ({ [r.next() < 0.5 ? "displayName" : "name"]: r.pick(groupNames), buckets: Array.from({ length: r.int(3) }, () => ({ remainingFraction: r.pick([0.25, 0.9, 0, undefined]), ...(r.next() < 0.2 ? { disabled: true } : {}), bucketId: r.pick(["gemini-5h", "3p-weekly", "gemini-argon-weekly", "", "x-daily", "3p-monthly"]), refreshWindowLabel: r.pick(["5h", "weekly", "Daily", "", "12 h", "odd"]), resetTime: r.pick(["2026-11-19T09:14:38Z", null]) })) }));
      const body = r.pick([{ status: "SUCCESS", command: { data: { groups } } }, { quotaSummary: { groups } }, { groups }, {}]);
      assert.deepEqual(await p.ask("agyAllowance", body), JSON.parse(JSON.stringify(agyAllowance(body))), `seed ${seed}`);
    }
    for (const m of [...MODELS, null, "vertex.gemini-4", "Google/Gemma-2@001", "models/gemini-4[x]"]) assert.equal(await p.ask("agyScopeForModel", m), agyScopeForModel(m), String(m));
  });

  test("the accounts' own: slugs, ids, secrets, labels, providers, Kimi's due, Cursor's file", async () => {
    for (const t of ["Me@Example.com", "---", "", "  a  b  ", "日本語テキスト", "x".repeat(60), "a-b--c", "Ünïcode Näme"]) assert.equal(await p.ask("slug", t, 40), slug(t, 40), t);
    for (const [b, taken] of [["p", []], ["p", ["p", "p-2"]], ["x", ["x", "x-3"]]] as const) assert.equal(await p.ask("unique", b, taken), unique(b, new Set(taken)));
    for (const k of ["API_KEY", "token", "Path", "MY_SECRET_X", "auth_header", "HOME"]) assert.equal(await p.ask("secretKey", k), secretKey(k));
    for (const v of ["", "short", "12345678", "123456789", "sk-abcdefghijklmnop", "日本語のとても長い秘密です"]) assert.equal(await p.ask("mask", v), mask(v));
    for (const d of [null, {}, { result: { selected: "complete" }, accepted: true }, { result: { selected: "x" }, option: { name: "Own" } }, { result: { selected: "uncertain" } }]) {
      for (const lang of ["zh", "en"] as const) assert.equal(await p.ask("checkLabel", d, lang), checkLabel(d, lang));
    }
    for (const login of [{ access: "a", refresh: "r", expiresAt: 1000_000, lifeMs: 900_000, deviceId: "d" }, { access: "a", refresh: "r", expiresAt: 1000_000, deviceId: "d" }]) {
      for (const now of [0, 500_000, 700_000, 999_000]) assert.equal(await p.ask("kimiDue", login, now), kimiDue({ lifeMs: 0, ...login }, now));
    }
    for (const t of ['{"apiKey":"k","email":"e@x","keyName":"n","createdAt":5}', '{"apiKey":""}', '{"apiKey":"k","email":""}', "[]"]) assert.deepEqual(await p.ask("cursorIn", t), cursorIn(t));
    assert.deepEqual(await p.ask("expandDevinFusion", { leads: { "claude-opus-5-5-high": [0, 1], "gpt-6-sol": [1, 5] }, sides: ["swe-2-medium", "glm-5-2"] }), expandDevinFusion({ leads: { "claude-opus-5-5-high": [0, 1], "gpt-6-sol": [1, 5] }, sides: ["swe-2-medium", "glm-5-2"] } as any));
  });
});

describe("accounts_pool: what reads a provider or a file", { skip }, () => {
  test("allowances asked of local providers, as checkQuota asks them, both ways alike", async () => {
    let reply: (path: string) => { status: number; body: unknown } = () => ({ status: 200, body: {} });
    const prov = await provider((a) => reply(a.url));
    const home = temp("mb-quota");
    const urls = { opencode: prov.base, anthropic: prov.base, chatgpt: prov.base, claudeToken: `${prov.base}/token`, console: prov.base, kimiApi: `${prov.base}/kimi`, kimi: prov.base };
    const p = new Program(baseSetup({ urls }));
    const env = { HOME: home };
    p.handle = ioHandler(async (name, args) => {
      if (name === "oauth.claudeOAuthToken") return await claudeOAuthToken(env, args[0], args[1], args[2], args[3], args[4] === undefined ? undefined : args[4]);
      if (name === "codex.rateLimits") return codexAnswer();
      if (name === "machine.codexAuthFile") return join(home, ".codex", "auth.json");
      if (name === "station.env") return env;
      return undefined;
    });
    let codexAnswer: () => Json = () => ({ rateLimits: { primary: { usedPercent: 10, windowDurationMins: 300, resetsAt: 1794830399 } } });
    await p.ready;
    try {
      const profile = (raw: Json) => hubConfig({ profiles: [{ home, ...raw }] }, "/x").profiles[0]!;
      const claudeHome = join(home, "claude");
      mkdirSync(join(claudeHome), { recursive: true });
      writeFileSync(join(claudeHome, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "at", refreshToken: "rt", expiresAt: Date.now() + 10 * 3600_000 } }));
      const cases: [string, Json, (path: string) => { status: number; body: unknown }][] = [
        ["opencode-go", { id: "o", access: { kind: "opencode-go", key: " k " } }, () => ({ status: 200, body: { usage: { rolling: { percent: 12, resetsAt: 1794830399 }, weekly: { percent: "40" }, other: {} } } })],
        ["opencode-go refused", { id: "o", access: { kind: "opencode-go", key: "k" } }, () => ({ status: 500, body: "x" })],
        ["kimi key", { id: "k", access: { kind: "api-provider", provider: "kimi-code", key: "k" } }, () => ({ status: 200, body: { usage: { limit: 100, used: 30 }, limits: [{ window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" }, detail: { limit: 10, remaining: 4 } }] } })],
        ["kimi none", { id: "k", access: { kind: "api-provider", provider: "kimi-code", key: "k" } }, () => ({ status: 200, body: {} })],
        ["kimi 403", { id: "k", access: { kind: "api-provider", provider: "kimi-code", key: "k" } }, () => ({ status: 403, body: { error: { message: "account suspended" } } })],
        ["kimi not JSON", { id: "k", access: { kind: "api-provider", provider: "kimi-code", key: "k" } }, () => ({ status: 200, body: "<html>" })],
        ["anthropic key", { id: "a", access: { kind: "anthropic-api", key: "k" } }, () => ({ status: 200, body: {} })],
        ["env", { id: "e", runtime: "claude" }, () => ({ status: 200, body: {} })],
        ["cursor", { id: "c", runtime: "cursor", access: { kind: "subscription" } }, () => ({ status: 200, body: {} })],
        ["devin", { id: "d", runtime: "devin", access: { kind: "subscription" } }, () => ({ status: 200, body: {} })],
        ["claude", { id: "cl", runtime: "claude", access: { kind: "subscription" }, home: claudeHome }, (path) => (path.startsWith("/api/oauth/usage") ? { status: 200, body: { five_hour: { utilization: 22, resets_at: "2026-11-16T11:59:59Z" }, seven_day: { utilization: 5, resets_at: null }, extra_usage: { is_enabled: true }, limits: [{ group: "weekly", percent: 9, scope: { model: { display_name: "Fable" } } }] } } : { status: 404, body: {} })],
        ["claude 401", { id: "cl", runtime: "claude", access: { kind: "subscription" }, home: claudeHome }, (path) => (path === "/token" ? { status: 400, body: { error: "invalid_grant" } } : { status: 401, body: { error: { message: "token expired" } } })],
        ["claude 429", { id: "cl", runtime: "claude", access: { kind: "subscription" }, home: claudeHome }, () => ({ status: 429, body: {} })],
        ["codex", { id: "cx", runtime: "codex", access: { kind: "subscription" } }, () => ({ status: 200, body: {} })],
        ["opencode-go not JSON", { id: "o", access: { kind: "opencode-go", key: "k" } }, () => ({ status: 200, body: "Not Found" })],
        ["claude an HTML page", { id: "cl", runtime: "claude", access: { kind: "subscription" }, home: claudeHome }, () => ({ status: 200, body: "<!DOCTYPE html><html><body>maintenance</body></html>" })],
      ];
      for (const [what, raw, answer] of cases) {
        reply = answer;
        const pr = profile(raw);
        const codex = { rateLimits: async () => codexAnswer() } as any;
        const ts = await tsSaid(() => checkQuota(pr, env, (pp) => codex.rateLimits(pp), urls, "zh", null));
        const mb = await p.said("checkQuota", pr, true, "zh", null);
        same(mb, ts, what);
      }
      // A Codex count with fewer expiries than it says: its details read of ChatGPT's backend with the profile's login.
      const codexHome = join(home, "cx");
      mkdirSync(codexHome, { recursive: true });
      const claims = Buffer.from(JSON.stringify({ exp: Math.floor(Date.now() / 1000) + 3600, email: "me@x.com" })).toString("base64url");
      writeFileSync(join(codexHome, "auth.json"), JSON.stringify({ tokens: { access_token: `h.${claims}.s`, account_id: "acc", id_token: `h.${claims}.s` } }));
      codexAnswer = () => ({ rateLimits: { primary: { usedPercent: 10 } }, rateLimitResetCredits: { availableCount: 2 } });
      reply = (path) => (path.endsWith("/wham/usage") ? { status: 200, body: { rate_limit: { primary_window: { used_percent: 33, limit_window_seconds: 18000, reset_at: 1794830399 } }, rate_limit_reset_credits: { available_count: 2 }, plan_type: "pro" } } : { status: 200, body: { available_count: 2, credits: [{ status: "available", expires_at: 1794830399 }, { status: "available", expiresAt: "2026-11-20T00:00:00Z" }] } });
      const cx = profile({ id: "cx", runtime: "codex", access: { kind: "subscription" }, home: codexHome });
      same(await p.said("checkQuota", cx, true, "zh", null), await tsSaid(() => checkQuota(cx, env, async () => codexAnswer(), urls, "zh", null)), "codex details");
      same(await p.said("codexUsage", join(codexHome, "auth.json"), "en"), await tsSaid(() => codexUsage(join(codexHome, "auth.json"), urls, "en")), "codexUsage");
      same(await p.said("lentCodexUsage", codexHome, Date.now(), "zh"), await tsSaid(() => lentCodexUsage(codexHome, Date.now(), urls, "zh")), "lent");
      same(await p.said("lentCodexUsage", codexHome, Date.now() + 7200_000, "zh"), await tsSaid(() => lentCodexUsage(codexHome, Date.now() + 7200_000, urls, "zh")), "lent, run out");
      for (const failing of ["failed to fetch codex rate limits: request failed: 401", "boom"]) {
        codexAnswer = () => {
          throw new Error(failing);
        };
        same(await p.said("checkQuota", cx, true, "zh", null), await tsSaid(() => checkQuota(cx, env, async () => codexAnswer(), urls, "zh", null)), failing);
      }
      same(await p.said("checkQuota", cx, false, "zh", null), await tsSaid(() => checkQuota(cx, env, undefined, urls, "zh", null)), "no app-server");
      // Claude's usage read as the installed Claude Code reads it, with its resets.
      reply = () => ({ status: 200, body: { five_hour: { utilization: 100, resets_at: 1794830399 }, juniper_tide: { eligible: true, arm: "reset", available: true }, cedar_ember: { eligible: true, grants: [{ id: "g", resets_left: 2, usable_now: true, type: "fable", ends_at: "2026-11-20T00:00:00Z" }] }, limits: [{ group: "weekly", percent: 100, scope: { model: { display_name: "Argon" } } }] } });
      same(await p.said("claudeUsage", prov.base, "tok", "zh", "2.1.300"), await tsSaid(() => claudeUsage(prov.base, "tok", "zh", "2.1.300")), "claude usage with resets");
      same(await p.said("claudeWithRefresh", claudeHome, "en", "2.1.300"), await tsSaid(() => claudeWithRefresh(env, claudeHome, urls, "en", "2.1.300")), "claude with refresh");
      // A reset redeemed: the usage read, the account's organization, the claim posted.
      for (const [what, answer] of [
        ["reset", (path: string) => (path.startsWith("/api/oauth/usage") ? { status: 200, body: { juniper_tide: { eligible: true, arm: "reset", available: true } } } : path === "/api/oauth/profile" ? { status: 200, body: { organization: { uuid: "org-1" } } } : { status: 200, body: { result: "reset" } })],
        ["none to use", () => ({ status: 200, body: { juniper_tide: { eligible: true, arm: "reset", available: false } } })],
        ["no credit", () => ({ status: 200, body: {} })],
        ["unauthorized", () => ({ status: 401, body: {} })],
        ["bad organization", (path: string) => (path.startsWith("/api/oauth/usage") ? { status: 200, body: { juniper_tide: { eligible: true, arm: "reset", available: true } } } : { status: 200, body: { organization: { uuid: "bad org!" } } })],
        ["cooldown", (path: string) => (path.startsWith("/api/oauth/usage") ? { status: 200, body: { cedar_ember: { eligible: true, grants: [{ id: "g", resets_left: 1, usable_now: true }] } } } : path === "/api/oauth/profile" ? { status: 200, body: { organization: { uuid: "o" } } } : { status: 429, body: {} })],
        ["usage 500", () => ({ status: 500, body: {} })],
      ] as const) {
        reply = answer as any;
        const before = prov.asked.length;
        const ts = await tsSaid(() => claudeResetWith(prov.base, "tok", "2.1.300", "idem-key", "session"));
        const tsAsked = prov.asked.slice(before).map((a) => [a.method, a.url, a.body]);
        const mid = prov.asked.length;
        const mb = await p.said("claudeResetWith", prov.base, "tok", "2.1.300", "idem-key", "session");
        const mbAsked = prov.asked.slice(mid).map((a) => [a.method, a.url, a.body]);
        same(mb, ts, `reset: ${what}`);
        assert.deepEqual(mbAsked, tsAsked, `reset: ${what}: the same requests`);
      }
    } finally {
      p.close();
      await prov.close();
    }
  });

  test("Kimi's sign-in and Cursor's: files, forms, the same requests", async () => {
    let reply: (path: string, form: Json, body: Json) => { status: number; body: unknown } = () => ({ status: 200, body: {} });
    const prov = await provider((a) => reply(a.url, a.form, a.body));
    const home = temp("mb-kimi");
    const p = new Program(baseSetup());
    p.handle = ioHandler();
    await p.ready;
    const urls = { website: "https://cursor.test", backend: prov.base, api: prov.base };
    try {
      const login = { access: "acc", refresh: "ref", expiresAt: 123, lifeMs: 900_000, deviceId: "dev" };
      await writeKimi(home, login);
      assert.deepEqual(await p.ask("readKimi", home), await readKimi(home));
      const mbHome = temp("mb-kimi-mb");
      await p.ask("writeKimi", mbHome, login);
      assert.equal(readFileSync(join(mbHome, "kimi-code.json"), "utf8"), readFileSync(join(home, "kimi-code.json"), "utf8"));
      assert.equal(readFileSync(join(mbHome, "kimi-code.token"), "utf8"), readFileSync(join(home, "kimi-code.token"), "utf8"));
      assert.deepEqual(await p.ask("kimiHeaders", "dev"), kimiHeaders("dev"));
      for (const [what, answer] of [
        ["device", () => ({ status: 200, body: { device_code: "dc", user_code: "UC", verification_uri: "https://v", expires_in: 30 } })],
        ["device refused", () => ({ status: 400, body: { message: "nope" } })],
        ["pending", () => ({ status: 400, body: { error: "authorization_pending" } })],
        ["token", () => ({ status: 200, body: { access_token: "a", refresh_token: "r", expires_in: 0 } })],
        ["renew refused", () => ({ status: 401, body: { error: "invalid_grant" } })],
        ["renew down", () => ({ status: 502, body: "x" })],
      ] as const) {
        reply = answer as any;
        for (const [op, ts] of [
          ["startKimiDevice", () => startKimiDevice(prov.base, "dev")],
          ["kimiDeviceToken", () => kimiDeviceToken(prov.base, "dc", "dev")],
          ["renewKimiToken", () => renewKimiToken(prov.base, "ref", "dev")],
        ] as const) {
          const before = prov.asked.length;
          const t = await tsSaid(ts);
          const tsAsked = prov.asked.slice(before).map((a) => [a.method, a.url, a.form, a.headers["x-msh-device-id"]]);
          const mid = prov.asked.length;
          const m = op === "startKimiDevice" ? await p.said(op, prov.base, "dev") : op === "kimiDeviceToken" ? await p.said(op, prov.base, "dc", "dev") : await p.said(op, prov.base, "ref", "dev");
          const mbAsked = prov.asked.slice(mid).map((a) => [a.method, a.url, a.form, a.headers["x-msh-device-id"]]);
          same(m, t, `${what}: ${op}`);
          assert.deepEqual(mbAsked, tsAsked, `${what}: ${op}: the same requests`);
        }
      }
      // Cursor: its file, its poll, its key minted, whose a key is, its models.
      const c = { apiKey: "key", email: "e@x.com", keyName: "still.fail · m", createdAt: 9 };
      await writeCursor(home, c);
      assert.deepEqual(await p.ask("readCursor", home), await readCursor(home));
      await p.ask("writeCursor", mbHome, c);
      assert.equal(readFileSync(join(mbHome, "cursor", "auth.json"), "utf8"), readFileSync(join(home, "cursor", "auth.json"), "utf8"));
      const hs = await p.ask("cursorHandshake", urls);
      const challenge = new URL(hs.url).searchParams.get("challenge");
      const { createHash } = await import("node:crypto");
      assert.equal(challenge, createHash("sha256").update(hs.verifier).digest("base64url"), "the challenge is the verifier's hash");
      assert.ok(/^[A-Za-z0-9_-]{43}$/.test(hs.verifier));
      assert.ok(hs.url.startsWith(`${urls.website}/loginDeepControl?challenge=`) && hs.url.endsWith(`&uuid=${hs.uuid}&mode=login&redirectTarget=cli`));
      const ts0 = cursorHandshake(urls);
      assert.deepEqual(Object.keys(hs), Object.keys(ts0));
      for (const [what, answer] of [
        ["pending", () => ({ status: 404, body: {} })],
        ["approved", (path: string) => (path.includes("GetMe") ? { status: 200, body: { email: "me@x.com" } } : path.includes("CreateUserApiKey") ? { status: 200, body: { apiKey: "minted" } } : path === "/v1/models" ? { status: 200, body: { models: [{ id: "composer-2" }, "gpt", { id: "" }] } } : path === "/v1/me" ? { status: 200, body: { userEmail: "me@x.com", apiKeyName: "n" } } : { status: 200, body: { accessToken: "at" } })],
        ["refused", (path: string) => (path.includes("Dashboard") ? { status: 403, body: { message: "no" } } : { status: 401, body: {} })],
        ["down", () => ({ status: 500, body: "oops" })],
      ] as const) {
        reply = answer as any;
        same(await p.said("pollCursor", urls, hs), await tsSaid(() => pollCursor(urls, hs)), `${what}: poll`);
        same(await p.said("mintCursorKey", urls, "at", "still.fail · m"), await tsSaid(() => mintCursorKey(urls, "at", "still.fail · m")), `${what}: mint`);
        same(await p.said("cursorMe", urls, "key"), await tsSaid(() => cursorMe(urls, "key")), `${what}: me`);
        same(await p.said("cursorModels", urls, "key"), await tsSaid(() => cursorModels(urls, "key")), `${what}: models`);
      }
    } finally {
      p.close();
      await prov.close();
    }
  });

  test("an Antigravity account's allowance asked of `agy`: what it says made the same allowance or refusal", async () => {
    const home = temp("mb-agy");
    mkdirSync(join(home, "agy", ".gemini", "antigravity-cli"), { recursive: true });
    writeFileSync(join(home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"), JSON.stringify({ token: { access_token: "x" }, auth_method: "oauth", id_token_email: "me@gmail.com" }));
    const bin = temp("mb-agy-bin");
    const said = (out: string, err = "", code = 0) => writeFileSync(join(bin, "agy"), `#!/bin/sh\ncat <<'EOF'\n${out}\nEOF\necho '${err}' >&2\nexit ${code}\n`, { mode: 0o755 });
    const env = { PATH: `${bin}:/usr/bin:/bin`, HOME: home, GEMINI_API_KEY: "machine" };
    const p = new Program(baseSetup({ urls: { agyQuota: "https://aicode.test" } }));
    p.handle = ioHandler(async (name, args) => {
      if (name === "agy.takeBack") return agyTakeBack(args[0]);
      if (name === "platform.hasKeychain") return platform.hasKeychain;
      if (name === "shell.withShellCommand") return withShellCommand(args[0], args[1], args[2]);
      if (name === "agy.company") return agyCompany(args[0]);
      if (name === "agy.run") return runAgy(args[0], args[1], args[2]);
      return undefined;
    });
    await p.ready;
    try {
      const groups = [{ displayName: "Gemini Models", buckets: [{ remainingFraction: 0.75, bucketId: "gemini-weekly", refreshWindowLabel: "weekly", resetTime: "2026-11-19T09:14:38Z" }] }, { displayName: "Gemini Argon", buckets: [{ remainingFraction: 0.5, bucketId: "gemini-argon-weekly" }] }];
      for (const [what, out, err, code] of [
        ["success", JSON.stringify({ status: "SUCCESS", command: { data: { groups } } }), "", 0],
        ["success, nothing", JSON.stringify({ status: "SUCCESS", command: { data: { groups: [] } } }), "", 0],
        ["signed out", "Authentication required. Please sign in", "", 1],
        ["network", JSON.stringify({ status: "ERROR", error: "dial tcp: connection refused" }), "", 1],
        ["busy", "", "HTTP 503 Service Unavailable", 1],
        ["other", "", "something odd", 3],
        ["auth word", JSON.stringify({ error: "invalid_grant: token revoked" }), "", 1],
      ] as const) {
        said(out, err, code);
        same(await p.said("agyQuota", home, env, "zh"), await tsSaid(() => agyQuota(home, env, { agyQuota: "https://aicode.test" } as any, "zh")), what);
      }
      rmSync(join(home, "agy", ".gemini", "antigravity-cli", "antigravity-oauth-token"));
      if (!platform.hasKeychain) same(await p.said("agyQuota", home, env, "zh"), await tsSaid(() => agyQuota(home, env, { agyQuota: "https://aicode.test" } as any, "zh")), "never signed in");
    } finally {
      p.close();
    }
  });
});

/// `agy -p /usage` run as agy-quota.ts `runAgyUsage` runs it: its output, and whether it asked to be signed in.
function runAgy(command: string, env: Json, cwd: string): Promise<Json> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, ["--log-file", "/dev/null", "-p", "/usage", "--output-format", "json"], { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let authPrompted = false;
    let settled = false;
    const done = (code: number | null) => {
      if (settled) return;
      settled = true;
      child.kill("SIGKILL");
      resolve({ code, stdout, stderr, authPrompted });
    };
    const look = (s: string) => {
      if (!authPrompted && (s.includes("Authentication required.") || s.includes("Waiting for authentication"))) {
        authPrompted = true;
        done(1);
      }
    };
    child.once("error", reject);
    child.stdout.on("data", (d) => look((stdout += d.toString("utf8"))));
    child.stderr.on("data", (d) => look((stderr = (stderr + d.toString("utf8")).slice(-4000))));
    child.once("close", (code) => done(code));
  });
}

/// One side's world for the accounts: its store, its config.json, its hub's account pool and what its parts were told.
type Side = { store: Store; config: ConfigFile; told: Json[]; data: string };

function side(raw: Json, clock?: Json): Side {
  const data = tmp("mb-ap-data");
  mkdirSync(join(data, "homes"), { recursive: true });
  const config = new ConfigFile(data);
  config.check = checkConfig;
  config.update((r) => Object.assign(r, structuredClone(raw)));
  return { store: Store.open(":memory:", null, clock), config, told: [], data };
}

/// A fixed clock both sides read and move together.
function clockAt(start: number) {
  let now = start;
  const clock = { currentTimeMillisUnsafe: () => now, unsafeCurrentTimeMillis: () => now } as any;
  return { clock, now: () => now, set: (t: number) => void (now = t) };
}

describe("accounts_pool: the accounts in lockstep", { skip }, () => {
  test("profiles edited, checked, their allowances read, reset, a sign-in's console key, the views", async () => {
    const START = 1_800_000_000_000;
    const raw = {
      profiles: [
        { id: "cl", name: "Claude", runtime: "claude", access: { kind: "subscription" }, home: "homes/cl", env: { API_TOKEN: "abcdefghijkl", PLAIN: "p" }, models: ["claude-opus-5-5"] },
        { id: "cx", runtime: "codex", access: { kind: "subscription" }, home: "homes/cx" },
        { id: "og", name: "Go", access: { kind: "opencode-go", key: "go-key-123456789", login: true }, home: "homes/og" },
        { id: "or", access: { kind: "api-provider", provider: "openrouter", key: "or-key-123456789" }, home: "homes/or" },
        { id: "off", runtime: "claude", access: { kind: "anthropic-api", key: "k" }, home: "homes/off", enabled: false },
      ],
      connects: [{ id: "c1", bind: { runtime: "claude", model: "claude-opus-5-5" }, slack: { botName: "Bot" } }],
      automaticDecisions: { completion: { enabled: false, model: null } },
    };
    const tc = testClock();
    await tc.adjust(START);
    const t = { clock: tc.clock };
    const ts = side(raw, t.clock);
    const mb = side(raw, t.clock);
    const viewer = { sub: "u", email: "o@x.com", name: "Owner", role: "owner", workspace: "ws1", device: "d", home: true };
    const member = { ...viewer, role: "member" };
    // What each side's parts answer: the same, kept apart.
    let used = 30;
    let checkState = "ok";
    const checkOf = (req: Json) => ({ state: req.kind === "anthropic-api" && req.key === "" ? "failed" : checkState, detail: `checked ${req.runtime}`, models: req.runtime === "claude" ? ["claude-opus-5-5", "claude-sonnet-5-5"] : req.runtime === "codex" ? null : ["x-model"], checkedAt: 0 });
    const quotaOf = (pr: Json) => (pr.id === "or" ? { state: "unsupported", windows: [], detail: "pay", checkedAt: 0 } : { state: "ok", windows: [{ label: "5 小时", usedPercent: used, resetsAt: START + 3600_000, minutes: 300 }], detail: null, checkedAt: 0, ...(pr.id === "cl" ? { extraUsage: true } : {}) });
    const resetOf = async (pr: Json, key: string) => (pr.id === "cx" && key !== "bad" ? ((used = 0), { outcome: "reset" }) : { outcome: key === "bad" ? "unavailable" : "nothingToReset" });
    const unhomed = (pr: Json) => JSON.parse(JSON.stringify(pr).replaceAll(ts.data, "<data>").replaceAll(mb.data, "<data>"));
    const fp = (pr: Json) => fingerprint(pr);
    const discoverOf = (pr: Json) => ({ state: "ready", provider: pr.access?.provider ?? "openrouter", model: "claude-sonnet-5-5", models: ["claude-sonnet-5-5"], fingerprint: fp(pr) });
    const shared = { view: (pr: Json, ws: string | null) => (pr.id === "cl" ? { shared: true, workspace: ws } : null) };
    const consoleLogins = new Map<string, Json>();
    const hubTold: Json[] = [];
    const tsAccounts = new Accounts({
      data: ts.data, store: ts.store, config: ts.config, machine: null, checkOnStart: false, clock: t.clock, workspaces: () => ["ws1", "ws2"],
      check: async (req) => checkOf(req) as any, quota: async (pr) => quotaOf(pr) as any, resetQuota: resetOf as any, discover: async (pr) => discoverOf(pr) as any,
      shared: shared as any, reviewUndecided: () => 3,
      hub: { accounts: { setHealth() {}, healthOf: (id: string) => tsAccounts.health(id), setRecheck() {}, setQuotaAgain() {} }, profileGone: async (id: string) => void hubTold.push(["gone", id]), allowanceReset: async (id: string) => void hubTold.push(["reset", id]) } as any,
    });
    const mbHubTold: Json[] = [];
    const p = new Program(baseSetup({
      data: mb.data, now: START, config: mb.config.raw(), urls: {},
      given: { check: "given", quota: "given", resetQuota: "given", discover: "given", machine: false, checkOnStart: false, workspaces: true, shared: true, reviewUndecided: true, hubProfileGone: true, hubAllowanceReset: true, hub: false, configChecked: true },
    }));
    let mbChanged = 0;
    p.handle = ioHandler(async (name, args) => {
      switch (name) {
        case "store.profileStatus": return [...mb.store.profileStatus().entries()];
        case "store.setProfileCheck": mb.store.setProfileCheck(args[0], args[1]); return null;
        case "store.setProfileQuota": mb.store.setProfileQuota(args[0], args[1]); return null;
        case "store.forgetProfileHours": mb.store.forgetProfileHours(args[0]); return null;
        case "store.now": return mb.store.now();
        case "store.profileHours": return mb.store.profileHours(args[0]);
        case "store.recentDecisions": return mb.store.recentDecisions();
        case "store.archivePolicy": return mb.store.archivePolicy() ?? null;
        case "store.latestDecisionsSince": return mb.store.latestDecisionsSince(args[0]);
        case "config.put": await mb.config.updateSoon((r) => { for (const k of Object.keys(r)) delete r[k]; Object.assign(r, args[0]); }); return null;
        case "check": return checkOf(args[0]);
        case "quota": return quotaOf(args[0]);
        case "resetQuota": return resetOf(args[0], args[1]);
        case "discover": return discoverOf(args[0]);
        case "decision.fingerprint": return fp(args[0]);
        case "decision.resolvedModel": return resolvedModel(args[0], args[1], args[2]) !== undefined;
        case "modelName": return (await import("../src/ops/model-name.ts")).modelName(args[0]);
        case "workspaces": return ["ws1", "ws2"];
        case "reviewUndecided": return 3;
        case "shared.view": return shared.view(args[0], args[1] ?? null) ?? { $undef: 1 };
        case "share.shareRefusal": return (await import("../src/share/index.ts")).shareRefusal(args[0]);
        case "profiles.loginCommand": return (await import("../src/accounts/profiles.ts")).loginCommand(args[0], args[1], args[2]);
        case "logins.get": return null;
        case "logins.close": return null;
        case "hub.profileGone": mbHubTold.push(["gone", args[0]]); return null;
        case "hub.allowanceReset": mbHubTold.push(["reset", args[0]]); return null;
        case "changed": mbChanged++; return null;
        case "models.uncheckOutdated": {
          const r = structuredClone(args[0]);
          const found = args[1];
          const { changes, unchecked } = uncheckOutdated(r, (id) => found[id] ?? null, new Set(args[2]));
          return { raw: r, changes, unchecked: [...unchecked] };
        }
        case "console.read": return consoleLogins.get(args[0]) ?? null;
        case "codex.accountIdentity": return codexAccountIdentity(args[0]);
        case "codex.claimsIn": return codexClaimsIn(args[0]) ?? { $undef: 1 };
        case "console.in": return consoleIn(args[0]);
        case "policy.policyFrom": return (await import("../src/sessions/archive-policy.ts")).policyFrom(args[0]);
        case "log.info": case "log.warn": return null;
        case "wall.now": return wall.now();
        default: return undefined;
      }
    });
    await p.ready;
    tsAccounts.start();
    await p.ask("accounts.start");
    // (each side's homes are its own, and so are the fingerprints made of them)
    const norm = (v: Json) => (v === undefined ? v : JSON.parse(JSON.stringify(v).replaceAll(ts.data, "<data>").replaceAll(mb.data, "<data>").replace(/"fingerprint":"[0-9a-f]{64}"/g, '"fingerprint":"<fp>"')));
    const both = async (what: string, tsf: () => unknown, op: string, ...args: Json[]) => {
      const tr = norm(await tsSaid(tsf));
      const mr = norm(await p.said(`accounts.${op}`, ...args));
      await settle();
      await p.settle();
      await settle();
      same(mr, tr, what);
      return tr.value;
    };
    const statesAlike = async (what: string) => {
      await settle();
      await p.settle();
      await settle();
      const state = await p.ask("accounts.state");
      const priv = tsAccounts as any;
      assert.deepEqual(norm(state.checks), norm(Object.fromEntries(priv.checks)), `${what}: checks`);
      assert.deepEqual(norm(state.quotas), norm(Object.fromEntries(priv.quotas)), `${what}: allowances`);
      assert.deepEqual(state.config, ts.config.raw(), `${what}: config.json held`);
      assert.deepEqual(mb.config.raw(), ts.config.raw(), `${what}: config.json written`);
      assert.deepEqual(norm([...mb.store.profileStatus().entries()]), norm([...ts.store.profileStatus().entries()]), `${what}: the store`);
      assert.deepEqual(mbHubTold, hubTold, `${what}: the hub told`);
    };
    try {
      await statesAlike("start");
      for (const id of ["cl", "cx", "og", "or", "off", "nope"]) await both(`check ${id}`, () => tsAccounts.check(id, "zh"), "check", id, "zh");
      await statesAlike("checked");
      for (const id of ["cl", "cx", "og", "or", "off", "nope"]) await both(`quota ${id}`, () => tsAccounts.refreshQuota(id), "refreshQuota", id);
      await statesAlike("allowances");
      for (const id of ["cl", "cx", "og"]) assert.deepEqual(norm(await p.ask("accounts.health", id)), norm(tsAccounts.health(id)), `health ${id}`);
      // Edits: a model named, a key replaced, a workspace withheld, refusals.
      const edits: [string, string, Json, Json][] = [
        ["model", "cl", { model: " claude-opus-5-5 ", models: ["claude-opus-5-5", " ", "claude-sonnet-5-5", "claude-opus-5-5"], fast: true }, viewer],
        ["env", "cl", { env: { PLAIN: null, NEW_KEY: "v", "bad name": "x" } }, viewer],
        ["env ok", "cl", { env: { PLAIN: null, NEW_KEY: "v" }, backgroundOnMessage: false }, viewer],
        ["key", "or", { access: { kind: "api-provider", key: " new-key ", endpoint: "https://x.test/" }, name: " OR ", addModel: " custom/model " }, viewer],
        ["bad endpoint", "or", { access: { kind: "api-provider", endpoint: "nope" } }, viewer],
        ["workspaces", "cx", { workspaces: [] }, viewer],
        ["workspaces by a member", "cx", { workspaces: ["ws2"] }, member],
        ["bad workspaces", "cx", { workspaces: ["no spaces allowed"] }, viewer],
        ["pause", "og", { enabled: false }, viewer],
        ["bad enabled", "og", { enabled: "no" }, viewer],
        ["bad fast", "cl", { fast: "yes" }, viewer],
        ["new", "fresh", { runtime: "codex", access: { kind: "subscription" } }, viewer],
        ["last of runtime", "cl", { runtime: "codex", access: { kind: "subscription" } }, viewer],
      ];
      for (const [what, id, given, who] of edits) {
        await both(`edit ${what}`, () => tsAccounts.putProfile(id, given, who as any, "zh"), "putProfile", id, given, who, "zh");
        await statesAlike(`edit ${what}`);
      }
      await both("delete", () => tsAccounts.deleteProfile("fresh", viewer as any, "zh"), "deleteProfile", "fresh", viewer, "zh");
      await both("delete again", () => tsAccounts.deleteProfile("fresh", viewer as any, "zh"), "deleteProfile", "fresh", viewer, "zh");
      await statesAlike("deleted");
      // A keyed profile made once its key works (and not when it does not).
      for (const input of [{ access: { kind: "anthropic-api", key: "sk-live" } }, { access: { kind: "anthropic-api", key: "" } }, { access: { kind: "api-provider", provider: "custom", endpoint: "https://llm.test/v1", protocol: "chat_completions" } }, { access: { kind: "subscription" } }, { access: { kind: "api-provider", provider: "anthropic", key: "k" } }, { access: { kind: "env" }, runtime: "pi" }, { access: { kind: "x" } }]) {
        await both(`new keyed ${JSON.stringify(input)}`, () => tsAccounts.newKeyedProfile(input, viewer as any, "zh"), "newKeyedProfile", input, viewer, "zh");
        await statesAlike(`new keyed ${JSON.stringify(input)}`);
      }
      // Allowances read again after a while, an unanswered question standing, a reset redeemed.
      await tc.adjust(400_000);
      await p.advance(START + 400_000);
      used = 100;
      for (const id of ["cl", "cx"]) await both(`quota again ${id}`, () => tsAccounts.refreshQuota(id), "refreshQuota", id);
      await both("asked quota", () => tsAccounts.askedQuota("cx"), "askedQuota", "cx");
      for (const [id, key] of [["cx", "k1"], ["cx", "bad"], ["cl", "k2"], ["or", "k"], ["nope", "k"]] as const) {
        await both(`reset ${id} ${key}`, () => tsAccounts.resetQuota(id, key, "zh"), "resetQuota", id, key, "zh");
        await statesAlike(`reset ${id} ${key}`);
      }
      // The decisions' models and settings, the archiving, the views.
      await both("decision models", () => tsAccounts.decisionModels(), "decisionModels");
      for (const [input, who] of [[{ completion: { enabled: true, model: "claude-sonnet-5-5" } }, viewer], [{ completion: { enabled: true, model: "nope" } }, viewer], [{ completion: { enabled: true } }, member], [{ completion: 3 }, viewer], [{ completion: { enabled: false, model: null } }, viewer]] as const) {
        await both(`decisions ${JSON.stringify(input)}`, () => tsAccounts.putAutomaticDecisions(input as any, who as any, "zh"), "putAutomaticDecisions", input, who, "zh");
      }
      for (const input of [{ days: 3, slackDays: 1, reviewed: true }, { days: -1, slackDays: 1, reviewed: true }, { days: 3, slackDays: 400, reviewed: false }]) {
        await both(`archiving ${JSON.stringify(input)}`, () => tsAccounts.putArchiving(input, viewer as any, "en"), "putArchiving", input, viewer, "en");
      }
      await both("review undecided (off)", () => tsAccounts.reviewUndecided(viewer as any, "zh"), "reviewUndecided", viewer, "zh");
      await both("review by a member", () => tsAccounts.reviewUndecided(member as any, "zh"), "reviewUndecided", member, "zh");
      await statesAlike("settings");
      await tsAccounts.homesReadSoon();
      await p.ask("accounts.homesReadSoon");
      for (const v of [viewer, { ...viewer, home: false, workspace: "ws2" }, undefined]) {
        await both(`profiles view ${v?.workspace}`, () => tsAccounts.profilesView(v as any), "profilesView", v);
      }
      await both("pace view", () => tsAccounts.paceView(viewer as any), "paceView", viewer);
      await both("fusion view", () => tsAccounts.fusionView("cl"), "fusionView", "cl");
      await both("fusion view unknown", () => tsAccounts.fusionView("nope"), "fusionView", "nope");
      await both("decisions view", () => tsAccounts.automaticDecisionsView(viewer as any, { includePolicy: false }), "automaticDecisionsView", viewer, false);
      await both("decisions view, a member", () => tsAccounts.automaticDecisionsView(member as any), "automaticDecisionsView", member);
      await both("logins view", () => tsAccounts.loginsView(), "loginsView");
      // An OpenCode Console token renewed when it runs out within a week: its key is the new token.
      consoleLogins.set(join(ts.data, "homes", "og"), { access: "old", refresh: "r", expiresAt: wall.now() + 3600_000, org: null, email: "go@x.com", workspace: null });
      consoleLogins.set(join(mb.data, "homes", "og"), consoleLogins.get(join(ts.data, "homes", "og")));
      await statesAlike("before console");
      // The rounds: the allowances asked every five minutes while someone follows (none follows here).
      await tc.adjust(600_000);
      await p.advance(START + 1_000_000);
      await statesAlike("rounds");
      assert.ok(mbChanged > 0, "the program told what changed");
    } finally {
      await tsAccounts.close();
      await p.ask("accounts.close");
      p.close();
    }
  });
});

describe("accounts_pool: the session accounts in lockstep", { skip }, () => {
  test("a session's account kept, moved off one spent, across runtimes, picked again, its changes checked", async () => {
    const START = 1_800_000_000_000;
    const raw = {
      profiles: [
        { id: "a", runtime: "claude", access: { kind: "subscription" }, home: "a", models: ["claude-opus-5-5", "claude-fable-5-2"] },
        { id: "b", runtime: "claude", access: { kind: "subscription" }, home: "b", models: ["claude-opus-5-5"] },
        { id: "k", runtime: "claude", access: { kind: "anthropic-api", key: "k" }, home: "k", models: ["claude-opus-5-5", "claude-fable-5-2"] },
        { id: "x", runtime: "codex", access: { kind: "subscription" }, home: "x", models: ["gpt-6.1-terra", "claude-opus-5-5"] },
        { id: "g", runtime: "agy", access: { kind: "subscription" }, home: "g", models: ["gemini-4-carbon", "claude-opus-5-5"] },
        { id: "w", runtime: "claude", access: { kind: "subscription" }, home: "w", models: ["claude-opus-5-5"], withheld: ["ws2"] },
      ],
    };
    const cfg = () => hubConfig(raw, "/d");
    const t = clockAt(START);
    const quota = (used: number, extra: Json = {}) => ({ state: "ok", windows: [{ label: "5 小时", usedPercent: used, resetsAt: START + 3600_000, minutes: 300 }, { label: "每周", usedPercent: Math.min(used, 60), resetsAt: START + 5 * 86_400_000, minutes: 10080 }], detail: null, checkedAt: START - 1000, ...extra });
    let healths: Record<string, Json> = {
      a: { check: { state: "ok", modelEfforts: { claude: { "claude-opus-5-5": ["low", "high", "max"] } } }, quota: quota(20, { scoped: [{ label: "每周 · Fable", usedPercent: 100, resetsAt: START + 86_400_000, minutes: 10080, scope: "Fable" }] }) },
      b: { check: { state: "ok", modelEfforts: { claude: { "claude-opus-5-5": ["low", "high"] } } }, quota: quota(85) },
      k: { check: { state: "ok" }, quota: null },
      x: { check: { state: "ok" }, quota: quota(10), account: "codex:acct" },
      g: { check: { state: "ok" }, quota: { state: "ok", windows: [{ label: "5 小时 · Gemini", usedPercent: 10, resetsAt: START + 3600_000, minutes: 300, scope: "gemini" }, { label: "5 小时 · Claude / GPT", usedPercent: 100, resetsAt: START + 3600_000, minutes: 300, scope: "3p" }], detail: null, checkedAt: START - 1000 } },
      w: { check: { state: "login" }, quota: null },
    };
    /// A side's store of sessions: what the session accounts read and write of it, kept as rows.
    const sessionsStore = () => {
      const rows = new Map<string, Json>();
      const told: Json[] = [];
      return {
        rows, told,
        getSession: (k: string) => (rows.has(k) ? structuredClone(rows.get(k)) : null),
        setSessionProfile: (k: string, profile: string, pinned: boolean, profiles: string[] | null) => { told.push(["profile", k, profile, pinned, profiles]); Object.assign(rows.get(k), { profile, profilePinned: pinned, profiles }); },
        recentlyCompacted: (k: string) => k === "compacted",
        compactionsReady: () => true,
        lastContexts: () => [{ turn: "t1", profile: "a", model: "claude-opus-5-5", context: 90_000 }, { turn: "t2", profile: "a", model: "claude-opus-5-5", context: 20_000 }],
        compactionPoints: () => new Map([["claude-opus-5-5", 150_000]]),
        lastTurn: () => ({ endedAt: START - 5000 }),
        ranIn: (k: string, rs: string, p: string) => void told.push(["ranIn", k, rs, p]),
        setSessionRuntime: (k: string, runtime: string, profile: string, pinned: boolean, model: string, effort: string | null, fast: boolean | null, context: number | null) => { told.push(["runtime", k, runtime, profile, pinned, model, effort, fast, context]); Object.assign(rows.get(k), { runtime, profile, profilePinned: pinned, model, effort, fast, context }); },
        setSessionContextBefore: (k: string) => void told.push(["contextBefore", k]),
      };
    };
    const row = (key: string, more: Json) => ({ key, runtime: "claude", profile: "a", profiles: null, profilePinned: false, model: "claude-opus-5-5", effort: null, fast: null, context: null, runtimeSessionId: `rs-${key}`, ...more });
    const SESSIONS = [
      row("s1", {}), row("s2", { profile: "b" }), row("s3", { profile: "a", model: "claude-fable-5-2" }), row("s4", { profilePinned: true, profile: "b" }),
      row("s5", { profiles: ["a", "b"] }), row("s6", { runtime: "agy", profile: "g", model: "claude-opus-5-5" }), row("s7", { runtime: "codex", profile: "x", model: "gpt-6.1-terra" }),
      row("compacted", { profile: "b" }), row("ws2-s", { profile: "w" }), row("s8", { profile: "k" }), row("s9", { runtime: "nope" }),
    ];
    const tsStore = sessionsStore();
    const mbStore = sessionsStore();
    for (const s of SESSIONS) {
      tsStore.rows.set(s.key, structuredClone(s));
      mbStore.rows.set(s.key, structuredClone(s));
    }
    const running = ["a", "a", "b", "x"];
    const allows = (key: string, pr: Json) => !(key.startsWith("ws2") && (pr.withheld ?? []).includes("ws2"));
    const tsMoved: Json[] = [];
    const tsSa = new SessionAccounts({ config: cfg, store: tsStore as any, running: (except) => running.filter((_, i) => except === undefined || i > 0), clock: t.clock, allows, moved: (k, was) => void tsMoved.push([k, was.profile]) });
    tsSa.setHealth((id) => healths[id] ?? {});
    tsSa.setQuotaAgain(async () => {});
    tsSa.setRecheck(async () => {});
    const mbMoved: Json[] = [];
    const p = new Program(baseSetup({ now: START, sessions: true, data: "/d" }));
    after(() => p.close());
    p.handle = async (name, args) => {
      switch (name) {
        case "config.raw": return raw;
        case "store.getSession": return mbStore.getSession(args[0]);
        case "store.setSessionProfile": mbStore.setSessionProfile(args[0], args[1], args[2], args[3]); return null;
        case "store.recentlyCompacted": return mbStore.recentlyCompacted(args[0]);
        case "store.compactionsReady": return true;
        case "store.lastContexts": return mbStore.lastContexts();
        case "store.compactionPoints": return [...mbStore.compactionPoints().entries()];
        case "store.lastTurn": return mbStore.lastTurn();
        case "store.ranIn": mbStore.ranIn(args[0], args[1], args[2]); return null;
        case "store.setSessionRuntime": mbStore.setSessionRuntime(args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]); return null;
        case "store.setSessionContextBefore": mbStore.setSessionContextBefore(args[0]); return null;
        case "sessions.running": return running.filter((_, i) => args[0] === undefined || i > 0);
        case "sessions.allows": return allows(args[0], args[1]);
        case "sessions.moved": mbMoved.push([args[0], args[1].profile]); return null;
        case "sessions.quotaAgain": case "sessions.checkAgain": return null;
        case "log.info": return null;
        default: throw new Error(`no part ${name}`);
      }
    };
    await p.ready;
    await p.ask("sessions.setHealth", healths);
    await p.ask("sessions.wireAgain");
    const both = async (what: string, tsf: () => unknown, op: string, ...args: Json[]) => {
      const tr = await tsSaid(tsf);
      const mr = await p.said(`sessions.${op}`, ...args);
      same(mr, tr, what);
      assert.deepEqual([...mbStore.rows.entries()], [...tsStore.rows.entries()], `${what}: the sessions as kept`);
      assert.deepEqual(mbStore.told, tsStore.told, `${what}: what the store was told`);
      assert.deepEqual(mbMoved, tsMoved, `${what}: the moves told`);
    };
    const runOnTs = (k: string, holding = false, quiet = false, across = false) => {
      const r = tsSa.runOn(k, holding, quiet, across);
      return { id: r.id, profile: JSON.parse(JSON.stringify({ ...r, spelling: undefined })) };
    };
    for (const k of SESSIONS.map((s) => s.key)) {
      await both(`health ${k}`, () => tsSa.healthOf(tsStore.rows.get(k)?.profile ?? k), "healthOf", tsStore.rows.get(k)?.profile ?? k);
      await both(`run on ${k}`, () => runOnTs(k), "runOn", k);
      await both(`run on ${k}, across`, () => runOnTs(k, false, false, true), "runOn", k, false, false, true);
      await both(`refills ${k}`, () => tsSa.refillsAt(k), "refillsAt", k);
      const id = tsStore.rows.get(k)?.profile ?? "a";
      const model = tsStore.rows.get(k)?.model ?? null;
      const limit = await tsSa.limitAfter(id, model);
      const mbLimit = await p.ask("sessions.limitAfter", id, model);
      assert.deepEqual(mbLimit === undefined ? "<undefined>" : mbLimit, limit === undefined ? "<undefined>" : limit, `limit after ${k}`);
    }
    for (const [k, ranOn, model] of [["s1", null, null], ["s2", "b", null], ["s3", null, "Fable"], ["s6", null, null], ["s4", null, null], ["s5", "a", null], ["s7", null, null], ["s8", null, null]] as const) {
      await both(`spend ${k}`, () => tsSa.spend(k, ranOn, model), "spend", k, ranOn, model);
      for (const id of ["a", "b", "x", "g", "k"]) await both(`health after spend ${k} ${id}`, () => tsSa.healthOf(id), "healthOf", id);
      await both(`run on after spend ${k}`, () => runOnTs(k, false, false, true), "runOn", k, false, false, true);
      await both(`refills after spend ${k}`, () => tsSa.refillsAt(k), "refillsAt", k);
    }
    for (const k of ["s1", "s5", "s4"]) await both(`repick ${k}`, () => tsSa.repick(k), "repick", k);
    for (const id of ["a", "x"]) await both(`reset allowance ${id}`, () => tsSa.resetAllowance(id), "resetAllowance", id);
    await both("same account", () => tsSa.sameAccount("a", "b"), "sameAccount", "a", "b");
    for (const [rt, model, pinned] of [["claude", "claude-opus-5-5", null], ["claude", null, "a"], ["claude", "claude-opus-5-5", ["a", "b"]], ["codex", "gpt-6.1-terra", null], ["agy", null, null]] as const) {
      await both(`efforts ${rt} ${model} ${pinned}`, () => tsSa.modelEfforts(rt as any, model, pinned as any), "modelEfforts", rt, model, pinned);
    }
    const changes: [string, Json][] = [
      ["s1", { profile: "b" }], ["s1", { profiles: ["a", " b ", "a", ""] }], ["s1", { profile: null, repick: true }], ["s1", { model: "claude-fable-5-2" }],
      ["s1", { model: "nope" }], ["s1", { effort: "max" }], ["s1", { effort: "weird" }], ["s1", { fast: true }], ["s1", { context: 200_000 }],
      ["s7", { context: 300_000 }], ["s6", { fast: true }], ["s1", { runtime: "codex", model: "gpt-6.1-terra" }], ["s1", { runtime: "codex", model: "nope" }],
      ["s1", { runtime: "codex", profiles: ["x"], effort: "high" }], ["s1", { runtime: "bogus" }], ["s1", { profile: "x" }], ["s1", { profile: "nope" }],
      ["s4", { repick: true }], ["s5", { model: "claude-fable-5-2" }], ["ws2-s", { profile: "w" }], ["s1", { profile: "off-runtime", repick: true }], ["nope", {}],
    ];
    for (const [k, change] of changes) {
      await both(`change ${k} ${JSON.stringify(change)}`, () => { const r: Json = tsSa.change(k, change, "zh"); return { ...r }; }, "change", k, change, "zh");
    }
    // A while later: what was passed over comes back, an allowance read again after a spend counts.
    t.set(START + 2 * 3600_000);
    await p.advance(START + 2 * 3600_000);
    healths = { ...healths, b: { ...healths.b, quota: quota(10, { checkedAt: START + 3600_000 }) } };
    tsSa.setHealth((id) => healths[id] ?? {});
    await p.ask("sessions.setHealth", healths);
    for (const k of ["s1", "s2", "s3", "s6"]) {
      await both(`later run on ${k}`, () => runOnTs(k), "runOn", k);
      await both(`later refills ${k}`, () => tsSa.refillsAt(k), "refillsAt", k);
    }
    for (const id of ["a", "b", "g", "x"]) await both(`later health ${id}`, () => tsSa.healthOf(id), "healthOf", id);
    // (what was compared did happen: sessions moved, one to another runtime, the store told)
    assert.ok(tsMoved.length >= 3, `moves: ${JSON.stringify(tsMoved)}`);
    assert.ok(tsStore.told.some((x) => x[0] === "runtime"), "a session taken on by another runtime's profile");
    p.close();
  });
});

/// The sign-ins' manager as the accounts ask it (login.ts `LoginManager`): jobs a test moves on, its listeners told.
function fakeLogins() {
  const jobs = new Map<string, Json>();
  const listeners = new Set<(id: string) => void>();
  const asked: Json[] = [];
  const begin = (how: string) => async (o: Json) => {
    asked.push([how, o.id, o.runtime ?? null, o.email ?? null, o.enterprise ?? null]);
    const job = { id: o.id, state: "running", provider: how === "console" ? "opencode" : how, startedAt: 7 };
    jobs.set(o.id, job);
    return job;
  };
  return {
    jobs, asked, listeners,
    get: (id: string) => jobs.get(id) ?? null,
    start: begin("cli"), startConsole: begin("console"), startKimi: begin("kimi"), startCursor: begin("cursor"),
    cancel: (id: string) => void asked.push(["cancel", id]),
    changes: (l: (id: string) => void) => (listeners.add(l), () => listeners.delete(l)),
    setStateFile() {},
    close: async () => {},
  };
}

describe("accounts_pool: sign-ins, renewals, borrowed profiles, the machine's logins, in lockstep", { skip }, () => {
  test("a sign-in makes its profile; Kimi's and the Console's tokens renewed; a borrowed Codex read with its lent login; runtimes checked", async () => {
    const START = 1_800_000_000_000;
    const WALL = 1_900_000_000_000;
    const wallNow = wall.now;
    wall.now = () => WALL;
    let reply: (url: string, form: Json) => { status: number; body: unknown } = () => ({ status: 404, body: {} });
    const prov = await provider((a) => reply(a.url, a.form));
    const urls = { opencode: prov.base, anthropic: prov.base, chatgpt: prov.base, claudeToken: `${prov.base}/token`, console: prov.base, kimi: prov.base, kimiApi: prov.base };
    const raw = {
      profiles: [
        { id: "km", name: "Kimi", access: { kind: "api-provider", provider: "kimi-code", login: true }, home: "homes/km" },
        { id: "og", name: "Go", access: { kind: "opencode-go", key: "old-token-123456", login: true }, home: "homes/og" },
        { id: "bx", name: "Borrowed", runtime: "codex", access: { kind: "subscription" }, home: "homes/bx", share: { borrowed: true, workspaces: ["ws1"], email: "lent@x.com" } },
        { id: "cx", runtime: "codex", access: { kind: "subscription" }, home: "homes/cx" },
        { id: "he", runtime: "hermes", access: { kind: "env" }, home: "homes/he" },
        { id: "ag", runtime: "agy", access: { kind: "subscription", enterprise: true }, home: "homes/ag" },
      ],
    };
    const tc = testClock();
    await tc.adjust(START);
    const t = { clock: tc.clock };
    const ts = side(raw, t.clock);
    const mb = side(raw, t.clock);
    for (const s of [ts, mb]) {
      for (const p of raw.profiles) mkdirSync(join(s.data, p.home), { recursive: true });
      writeFileSync(join(s.data, "homes/km/kimi-code.json"), JSON.stringify({ access: "kimi-old", refresh: "kimi-r", expiresAt: WALL + 60_000, lifeMs: 900_000, deviceId: "dev" }));
      writeFileSync(join(s.data, "homes/og/opencode-console.json"), JSON.stringify({ access: "old-token-123456", refresh: "console-r", expiresAt: WALL + 86_400_000, org: "o1", email: "go@x.com", workspace: null }));
    }
    const viewer = { sub: "u", email: "o@x.com", name: "Owner", role: "owner", workspace: "ws1", device: "d", home: true };
    const lentClaims = Buffer.from(JSON.stringify({ exp: Math.floor(WALL / 1000) + 3600, email: "lent@x.com", sub: "user-1" })).toString("base64url");
    const parts = (s: Side) => {
      const told: Json[] = [];
      return {
        told,
        shared: {
          status: async (pr: Json) => (told.push(["status", pr.id]), { check: { state: "ok", detail: "host says", models: ["gpt-6.1-terra"], checkedAt: 5 }, quota: { state: "ok", windows: [{ label: "5 小时", usedPercent: 40, resetsAt: null }], detail: null, checkedAt: START - 10, resetCount: 2 } }),
          view: () => null,
          lendCodex: async (pr: Json) => {
            told.push(["lendCodex", pr.id]);
            writeFileSync(join(pr.home, "auth.json"), JSON.stringify({ tokens: { access_token: `h.${lentClaims}.s`, account_id: "acc-1", id_token: `h.${lentClaims}.s` } }));
            return 1;
          },
          loginUpdated: (id?: string) => void told.push(["loginUpdated", id ?? null]),
          hostName: () => "host-1",
        },
        codex: { rateLimits: async () => ({ rateLimits: { primary: { usedPercent: 3 } } }), resetQuota: async () => ({ outcome: "reset" }), models: async () => ({ models: ["gpt-6.1-terra", "gpt-6-luna"], efforts: new Map([["gpt-6.1-terra", ["low", "high"]]]), defaults: new Map([["gpt-6.1-terra", "high"]]), ultrafastModels: ["gpt-6-luna"] }), loginChanged: async (id: string) => void told.push(["codexLoginChanged", id]) },
        hermes: { models: async () => ["h1", "h2"] },
        agy: { models: async () => ["gemini-4-carbon"], catalog: async () => ({ models: ["gemini-4-carbon", "claude-opus-5-5"], efforts: { "gemini-4-carbon": ["low", "high"] }, defaults: { "gemini-4-carbon": "high" }, tier: "gcp-ge-plus-tier" }) },
        hub: { accounts: { setHealth() {}, healthOf: () => ({}), setRecheck() {}, setQuotaAgain() {} }, profileGone: async (id: string) => void told.push(["gone", id]), allowanceReset: async (id: string) => void told.push(["reset", id]), profileLoginChanged: async (id: string) => void told.push(["loginChanged", id]) },
        logins: fakeLogins(),
        changed: 0,
      };
    };
    const tsParts = parts(ts);
    const mbParts = parts(mb);
    const checkOf = (req: Json) => ({ state: "ok", detail: `checked ${req.runtime} ${req.kind} ${req.key ? "keyed" : "unkeyed"}`, models: req.runtime === "codex" || req.runtime === "hermes" ? null : ["m1"], checkedAt: 0 });
    const tsAccounts = new Accounts({
      data: ts.data, store: ts.store, config: ts.config, machine: null, checkOnStart: false, clock: t.clock, workspaces: () => ["ws1"], urls: urls as any,
      check: async (req) => checkOf(req) as any, discover: async () => ({ state: "unsupported" }) as any, resetQuota: null, quota: async () => ({ state: "ok", windows: [], detail: null, checkedAt: 0 }) as any,
      shared: tsParts.shared as any, codex: () => tsParts.codex as any, hermes: () => tsParts.hermes, agy: () => tsParts.agy as any, hub: tsParts.hub as any,
    });
    (tsAccounts as any).logins = tsParts.logins;
    const p = new Program(baseSetup({
      data: mb.data, now: START, config: mb.config.raw(), urls,
      given: { check: "given", quota: "given", resetQuota: "none", discover: "given", machine: false, checkOnStart: false, workspaces: true, shared: true, sharedLendCodex: true, sharedLoginUpdated: true, sharedHostName: true, codex: true, codexLoginChanged: true, hermes: true, agy: true, agyCatalog: true, hubProfileGone: true, hubAllowanceReset: true, hubProfileLoginChanged: true, configChecked: true },
    }));
    const m = mbParts;
    p.handle = ioHandler(async (name, args) => {
      switch (name) {
        case "store.profileStatus": return [...mb.store.profileStatus().entries()];
        case "store.setProfileCheck": mb.store.setProfileCheck(args[0], args[1]); return null;
        case "store.setProfileQuota": mb.store.setProfileQuota(args[0], args[1]); return null;
        case "config.put": await mb.config.updateSoon((r) => { for (const k of Object.keys(r)) delete r[k]; Object.assign(r, args[0]); }); return null;
        case "check": return checkOf(args[0]);
        case "quota": return { state: "ok", windows: [], detail: null, checkedAt: 0 };
        case "discover": return { state: "unsupported" };
        case "decision.fingerprint": return fingerprint(args[0]);
        case "workspaces": return ["ws1"];
        case "shared.status": return m.shared.status(args[0]);
        case "shared.lendCodex": return m.shared.lendCodex(args[0]);
        case "shared.loginUpdated": m.shared.loginUpdated(args[0]); return null;
        case "shared.hostName": return m.shared.hostName();
        case "shared.view": return m.shared.view() ?? { $undef: 1 };
        case "share.shareRefusal": return (await import("../src/share/index.ts")).shareRefusal(args[0]);
        case "profiles.loginCommand": return (await import("../src/accounts/profiles.ts")).loginCommand(args[0], args[1], args[2]);
        case "codex.rateLimits": return m.codex.rateLimits();
        case "codex.models": { const c = await m.codex.models(); return { models: c.models, efforts: Object.fromEntries(c.efforts), defaults: Object.fromEntries(c.defaults), ultrafastModels: c.ultrafastModels }; }
        case "codex.loginChanged": await m.codex.loginChanged(args[0]); return null;
        case "codex.accountIdentity": return codexAccountIdentity(args[0]);
        case "codex.claimsIn": return codexClaimsIn(args[0]) ?? { $undef: 1 };
        case "hermes.models": return m.hermes.models();
        case "agy.catalog": return m.agy.catalog();
        case "agy.plan": return agyPlan(args[0], args[1]);
        case "agy.classifyFailure": return classifyFailure(args[0]);
        case "agy.company": return agyCompany(args[0]);
        case "hub.profileGone": await m.hub.profileGone(args[0]); return null;
        case "hub.allowanceReset": await m.hub.allowanceReset(args[0]); return null;
        case "hub.profileLoginChanged": await m.hub.profileLoginChanged(args[0]); return null;
        case "logins.get": return m.logins.get(args[0]);
        case "logins.start": return m.logins.start(args[0]);
        case "logins.startConsole": return m.logins.startConsole(args[0]);
        case "logins.startKimi": return m.logins.startKimi(args[0]);
        case "logins.startCursor": return m.logins.startCursor(args[0]);
        case "logins.cancel": m.logins.cancel(args[0]); return null;
        case "logins.close": return null;
        case "console.read": return (await import("../src/accounts/console.ts")).readConsole(args[0]);
        case "console.renew": return (await import("../src/accounts/console.ts")).renewToken(args[0], args[1]);
        case "console.write": await (await import("../src/accounts/console.ts")).writeConsole(args[0], args[1]); return null;
        case "console.in": return consoleIn(args[0]);
        case "models.uncheckOutdated": { const r = structuredClone(args[0]); const { changes, unchecked } = uncheckOutdated(r, (id) => args[1][id] ?? null, new Set(args[2])); return { raw: r, changes, unchecked: [...unchecked] }; }
        case "wall.now": return wall.now();
        case "changed": m.changed++; return null;
        case "log.info": case "log.warn": return null;
        default: return undefined;
      }
    });
    await p.ready;
    const norm = (v: Json) => (v === undefined ? v : JSON.parse(JSON.stringify(v).replaceAll(ts.data, "<data>").replaceAll(mb.data, "<data>").replace(/"fingerprint":"[0-9a-f]{64}"/g, '"fingerprint":"<fp>"').replace(/login-[0-9a-f]{8}/g, "login-*")));
    const quiet = async () => {
      for (let i = 0; i < 3; i++) {
        await settle();
        await p.settle();
      }
    };
    const both = async (what: string, tsf: () => unknown, op: string, ...args: Json[]) => {
      const tr = norm(await tsSaid(tsf));
      const mr = norm(await p.said(`accounts.${op}`, ...args));
      await quiet();
      same(mr, tr, what);
      return tr.value;
    };
    const fileOf = (s: Side, path: string) => (existsSync(join(s.data, path)) ? readFileSync(join(s.data, path), "utf8") : null);
    const alike = async (what: string, files: string[] = []) => {
      await quiet();
      const state = await p.ask("accounts.state");
      const priv = tsAccounts as any;
      assert.deepEqual(norm(state.checks), norm(Object.fromEntries(priv.checks)), `${what}: checks`);
      assert.deepEqual(norm(state.quotas), norm(Object.fromEntries(priv.quotas)), `${what}: allowances`);
      assert.deepEqual(norm(state.pending), norm(Object.fromEntries([...priv.pending].map(([id, x]: any) => [id, { runtime: x.runtime, access: x.access ?? null, home: x.home, created: x.created, error: x.error }]))), `${what}: sign-ins`);
      assert.deepEqual(mb.config.raw(), ts.config.raw(), `${what}: config.json`);
      assert.deepEqual(norm([...mb.store.profileStatus().entries()]), norm([...ts.store.profileStatus().entries()]), `${what}: the store`);
      assert.deepEqual(norm(mbParts.told), norm(tsParts.told), `${what}: what the parts were told`);
      assert.deepEqual(norm(mbParts.logins.asked), norm(tsParts.logins.asked), `${what}: the sign-ins asked`);
      for (const f of files) assert.equal(fileOf(mb, f), fileOf(ts, f), `${what}: ${f}`);
    };
    tsAccounts.start();
    await p.ask("accounts.start");
    try {
      // Kimi's token due: renewed of its sign-in server, its file and token file written alike.
      reply = (url, form) => (url === "/api/oauth/token" && form.refresh_token === "kimi-r" ? { status: 200, body: { access_token: "kimi-new", refresh_token: "kimi-r2", expires_in: 600 } } : { status: 404, body: {} });
      await both("kimi renewed", () => tsAccounts.renewKimi("km"), "renewKimi", "km");
      await alike("kimi renewed", ["homes/km/kimi-code.json", "homes/km/kimi-code.token"]);
      await both("kimi not due", () => tsAccounts.renewKimi("km"), "renewKimi", "km");
      // Refused: signed out, its refresh token dropped, its check says so.
      writeFileSync(join(ts.data, "homes/km/kimi-code.json"), JSON.stringify({ access: "kimi-new", refresh: "kimi-r2", expiresAt: WALL + 1000, lifeMs: 600_000, deviceId: "dev" }));
      writeFileSync(join(mb.data, "homes/km/kimi-code.json"), JSON.stringify({ access: "kimi-new", refresh: "kimi-r2", expiresAt: WALL + 1000, lifeMs: 600_000, deviceId: "dev" }));
      reply = () => ({ status: 401, body: { error: "invalid_grant" } });
      await both("kimi refused", () => tsAccounts.renewKimi("km"), "renewKimi", "km");
      await alike("kimi refused", ["homes/km/kimi-code.json", "homes/km/kimi-code.token"]);
      await both("kimi checked signed out", () => tsAccounts.check("km", "zh"), "check", "km", "zh");
      // The Console's token renewed: its file written, its key the new token.
      reply = (url, form) => (url === "/auth/device/token" && form.refresh_token === "console-r" ? { status: 200, body: { access_token: "new-token-654321", refresh_token: "console-r2", expires_in: 2_592_000 } } : { status: 404, body: {} });
      await both("console renewed", () => tsAccounts.renewConsole("og"), "renewConsole", "og");
      await alike("console renewed", ["homes/og/opencode-console.json"]);
      reply = () => ({ status: 400, body: { error: "invalid_grant" } });
      await both("console refused", () => tsAccounts.renewConsole("og"), "renewConsole", "og");
      await alike("console refused");
      // Runtimes checked: Codex's levels listed, Hermes' models, an Antigravity company account's plan.
      for (const id of ["cx", "he", "ag"]) await both(`check ${id}`, () => tsAccounts.check(id, "zh"), "check", id, "zh");
      tsParts.codex.models = async () => { throw new Error("app-server gone"); };
      mbParts.codex.models = tsParts.codex.models;
      tsParts.hermes.models = async () => { throw new Error("hermes down"); };
      mbParts.hermes.models = tsParts.hermes.models;
      tsParts.agy.catalog = async () => { throw new Error("Authentication required"); };
      mbParts.agy.catalog = tsParts.agy.catalog;
      for (const id of ["cx", "he", "ag"]) await both(`check ${id} again, failing`, () => tsAccounts.check(id, "en"), "check", id, "en");
      await alike("runtimes checked");
      // A borrowed Codex subscription: its host's status, then its allowance read with the login lent.
      await both("borrowed check", () => tsAccounts.check("bx", "zh"), "check", "bx", "zh");
      reply = (url) => (url.endsWith("/wham/usage") ? { status: 200, body: { rate_limit: { primary_window: { used_percent: 12, limit_window_seconds: 18000 } }, plan_type: "plus" } } : { status: 404, body: {} });
      await both("borrowed allowance", () => tsAccounts.refreshQuota("bx"), "refreshQuota", "bx");
      await both("borrowed changed", () => tsAccounts.sharedChanged("bx", true), "sharedChanged", "bx", true);
      reply = () => ({ status: 401, body: { error: { message: "token revoked" } } });
      await both("borrowed allowance refused", () => tsAccounts.refreshQuota("bx"), "refreshQuota", "bx");
      await alike("borrowed");
      // Listed to the workspaces its host lends it in alone (ws1 here), and to no viewer all of them.
      for (const v of [viewer, { ...viewer, home: false, workspace: "ws2" }, undefined]) {
        const seen = (await both(`profiles view ${v?.workspace}`, () => tsAccounts.profilesView(v as any), "profilesView", v)) as Json[];
        assert.equal(seen.some((x) => x.id === "bx"), v?.workspace !== "ws2", `bx listed to ${v?.workspace}`);
      }
      // Sign-ins: one for a new profile made once it is done, named by its account; one dropped; one of a profile.
      const tsNew = await tsAccounts.newLogin({ runtime: "claude" }, viewer as any, "zh");
      const mbNew = await p.ask("accounts.newLogin", { runtime: "claude" }, viewer, "zh");
      await quiet();
      assert.deepEqual(norm(mbNew), norm(tsNew), "new login");
      for (const [s, id] of [[ts, tsNew.id], [mb, mbNew.id]] as const) {
        mkdirSync(join(s.data, "homes", id), { recursive: true });
        writeFileSync(join(s.data, "homes", id, ".claude.json"), JSON.stringify({ oauthAccount: { emailAddress: "Signed.In@Example.com" } }));
      }
      tsParts.logins.jobs.get(tsNew.id).state = "done";
      mbParts.logins.jobs.get(mbNew.id).state = "done";
      for (const l of tsParts.logins.listeners) l(tsNew.id);
      await p.ask("accounts.loginChanged", mbNew.id);
      await quiet();
      const tsPending = (tsAccounts as any).pending.get(tsNew.id);
      const mbState = await p.ask("accounts.state");
      assert.equal(mbState.pending[mbNew.id].created, tsPending.created, "the profile made of the sign-in");
      assert.deepEqual(mb.config.raw(), ts.config.raw(), "config.json with the new profile");
      assert.ok(existsSync(join(mb.data, "homes", tsPending.created, ".claude.json")), "its home moved");
      await both("login state file", () => (tsAccounts as any).loginStateFile(tsNew.id), "loginStateFile", mbNew.id);
      const tsDrop = await tsAccounts.newLogin({ access: "kimi-code" }, viewer as any, "zh");
      const mbDrop = await p.ask("accounts.newLogin", { access: "kimi-code" }, viewer, "zh");
      await tsAccounts.dropLogin(tsDrop.id);
      await p.ask("accounts.dropLogin", mbDrop.id);
      for (const [id, who] of [["cx", viewer], ["og", viewer], ["km", viewer], ["bx", viewer], ["he", viewer], ["ag", viewer], ["nope", viewer]] as const) {
        await both(`start login ${id}`, () => tsAccounts.startLogin(id, who as any, "zh"), "startLogin", id, who, "zh");
      }
      await both("new login, unknown runtime", () => tsAccounts.newLogin({ runtime: "x" }, viewer as any, "zh"), "newLogin", { runtime: "x" }, viewer, "zh");
      await alike("sign-ins");
      // A pending sign-in kept a while for its page, then let go.
      await tc.adjust(16 * 60_000);
      await p.advance(START + 16 * 60_000);
      await quiet();
      assert.equal((tsAccounts as any).pending.size, Object.keys((await p.ask("accounts.state")).pending).length, "the pending sign-ins let go");
      // Kept on a timer: the Kimi round (every minute) and the Console's (every six hours), both ways alike.
      reply = () => ({ status: 503, body: {} });
      await tc.adjust(6 * 3600_000 + 1000 - 16 * 60_000);
      await p.advance(START + 6 * 3600_000 + 1000);
      await alike("rounds");
      assert.ok(mbParts.changed > 0);
    } finally {
      wall.now = wallNow;
      await tsAccounts.close();
      await p.ask("accounts.close").catch(() => {});
      p.close();
      await prov.close();
    }
  });
});
