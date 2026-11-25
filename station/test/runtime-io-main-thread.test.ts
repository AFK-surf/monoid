// What the station's main thread waits on as it runs a command with a grant (src/vault/run.ts `runWith`, its proxy's
// CA: src/vault/proxy.ts), makes a drive file's thumbnail (src/drive/thumbs.ts `thumbnail`, `kept`), answers the
// overview (src/api/overview.ts, the disk's room), hands its streams' events over to the next process and takes them up
// (src/api/events.ts `handOver`, `takeUp`), and finds, starts and ends the station's Chrome and keeps whose its tabs are
// (src/browser/chrome.ts, src/browser/owners.ts), posts through another station's connect and learns of it
// (src/connects/remote.ts), runs a login of the machine's or a profile's sign-in (src/logins/, src/accounts/login.ts)
// and follows a Feishu app made by a scan (src/feishu/register.ts), opens a session of every runtime (src/agents/), finds
// the runners alive (src/agents/runner.ts) and makes or drops a profile (src/accounts/index.ts): none of node:fs's or
// node:zlib's synchronous calls (station/AGENTS.md, the main thread waits on nothing). Each ran on every secret_run,
// drive preview, overview, update, tab opened or closed, file posted to a chat of another station's connect, login,
// scan, session opened and profile added.
import { niced } from "../src/ops/nice.ts";
import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { readFile, readdir, readlink, rm, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { after, test } from "node:test";
import { Events } from "../src/api/events.ts";
import { overview } from "../src/api/overview.ts";
import { BrowserState, type Running, chromeHost, readState } from "../src/browser/chrome.ts";
import { Owners } from "../src/browser/owners.ts";
import { checkConfig } from "../src/accounts/check.ts";
import { CONSOLE_FILE, readConsole } from "../src/accounts/console.ts";
import { Accounts } from "../src/accounts/index.ts";
import { KIMI_FILE, KIMI_TOKEN_FILE, readKimi } from "../src/accounts/kimi.ts";
import { type LoginJob, LoginManager } from "../src/accounts/login.ts";
import { MachineLogins } from "../src/accounts/machine.ts";
import { checkProfile, devinEmail, URLS } from "../src/accounts/profiles.ts";
import { codexUsage, lentCodexUsage } from "../src/accounts/quota.ts";
import { AgyDriver } from "../src/agents/agy.ts";
import { ClaudeDriver } from "../src/agents/claude.ts";
import { CodexDriver } from "../src/agents/codex.ts";
import { CursorDriver, cursorHome, findSdk } from "../src/agents/cursor.ts";
import { DevinDriver, devinData } from "../src/agents/devin.ts";
import { DshDriver } from "../src/agents/dsh.ts";
import { GrokDriver } from "../src/agents/grok.ts";
import { HermesDriver } from "../src/agents/hermes.ts";
import { linkCodexAuthSoon, readClaudeCredentials } from "../src/agents/machine-logins.ts";
import { liveRunners, startRunner } from "../src/agents/runner.ts";
import type { OpenOptions } from "../src/agents/runtime.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { fingerprint } from "../src/sessions/decision.ts";
import { type Described, RemoteConnects, answerCall } from "../src/connects/remote.ts";
import { Registrations } from "../src/feishu/register.ts";
import { type Login, Logins } from "../src/logins/index.ts";
import { WINDOWS } from "../src/platform/index.ts";
import type { ChatSurface, ThreadRef } from "../src/sessions/chat.ts";
import type { Attachment } from "../src/store/rows.ts";
import { idOf, kept, thumbnail } from "../src/drive/thumbs.ts";
import { Store } from "../src/store/store.ts";
import type { Held } from "../src/vault/keeper.ts";
import { Proxy } from "../src/vault/proxy.ts";
import { runWith } from "../src/vault/run.ts";
import { exe, fakeBrowser, fakeLogin, idToken, machine, provider, script, upon } from "./accounts-fakes.ts";
import { settle, testClock } from "./hub-fakes.ts";
import { syncCalls } from "./main-thread-sync.ts";

type Json = any;

const dirs: string[] = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});
function scratch(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), `${name}-`));
  dirs.push(dir);
  return dir;
}

/// A grant held for a run: of `mode`, its secret `fields` of `kind`.
const held = (mode: string, kind: string, fields: Record<string, string>, hosts: string[] = []): Held =>
  ({ request: { id: `r_${mode}` }, grant: { mode, hosts }, secret: { kind, name: mode, fields }, uses: 0 }) as unknown as Held;

test("a command run with a grant, by its file, its SSH agent or the proxy, waits on no file", async () => {
  const dir = scratch("run-main-thread");
  const proxy = new Proxy(join(dir, "vault"), () => 0);
  const key = generateKeyPairSync("ed25519").privateKey.export({ format: "pem", type: "pkcs8" }).toString();
  const env = { PATH: process.env.PATH ?? "" };
  const ask = (command: string) => ({ command, cwd: dir, env: "GIVEN", timeoutMs: 60_000 });
  const ran: string[] = [];
  const calls = await syncCalls(async () => {
    const file = await runWith(held("file", "file", { content: Buffer.from("kept\n").toString("base64"), filename: "k.txt" }), ask('cat "$GIVEN"; echo "$GIVEN"'), proxy, env, () => {});
    ran.push(file.output);
    const ssh = await runWith(held("ssh", "ssh_key", { private_key: key }), ask('test -S "$SSH_AUTH_SOCK" && echo "$SSH_AUTH_SOCK"'), proxy, env, () => {});
    ran.push(ssh.output);
    // Two at once: the CA read or made once.
    const both = await Promise.all([1, 2].map(() => runWith(held("proxy", "token", { value: "t0ken" }, ["api.example.com"]), ask('echo "$HTTPS_PROXY" "$GIVEN"'), proxy, env, () => {})));
    ran.push(...both.map((r) => r.output));
  });
  proxy.close();
  assert.deepEqual(calls, []);
  const [file, ssh, ...proxied] = ran;
  // (What it printed of the file hidden, as a secret in the environment is.)
  assert.match(file!, /^[^\n]+\n(.*k\.txt)\n$/, "the file written for it, its path given");
  assert.ok(!file!.includes("kept"), file);
  const path = /\n(.*)\n$/.exec(file!)![1]!;
  await assert.rejects(stat(path), /ENOENT/, "and taken away after");
  assert.match(ssh!, /agent\.sock\n$/, "the agent's socket there while it ran");
  await assert.rejects(stat(ssh!.trim()), /ENOENT/, "and its directory taken away after");
  for (const p of proxied) assert.match(p, /^http:\/\/run:[^@]+@127\.0\.0\.1:\d+ stillfail-secret:r_proxy\n$/);
  assert.ok((await readFile(proxy.bundle, "utf8")).includes("-----BEGIN CERTIFICATE-----"), "the bundle a command trusts written");
  // Started again (another process), the CA is read, not made again.
  const ca = await readFile(join(dir, "vault", "ca.pem"), "utf8");
  const again = new Proxy(join(dir, "vault"), () => 0);
  assert.deepEqual(await syncCalls(async () => void (await again.start())), []);
  again.close();
  assert.equal(await readFile(join(dir, "vault", "ca.pem"), "utf8"), ca);
});

test("a drive file's thumbnail made again once the file is newer waits on no file", async () => {
  const dir = scratch("thumbs-main-thread");
  const thumbs = join(dir, "thumbs");
  mkdirSync(thumbs);
  const image = join(dir, "a.png");
  const old = join(thumbs, `${idOf(image)}.jpg`);
  writeFileSync(old, "old");
  utimesSync(old, 1, 1);
  const made: string[] = [];
  const codecs = {
    thumbnail: async (from: string, to: string) => (made.push(from), { path: join(to, `${idOf(from)}.jpg`), type: "image/jpeg" }),
    thumbhash: async () => null,
  };
  let gone: unknown;
  const calls = await syncCalls(async () => {
    await thumbnail(image, thumbs, codecs, 5_000);
    gone = await kept(thumbs, idOf(image));
    assert.equal(await kept(thumbs, idOf(join(dir, "none.png"))), null);
  });
  assert.deepEqual(calls, []);
  assert.deepEqual(made, [image]);
  assert.equal(gone, null, "the one of what it was taken away");
});

test("the overview's disk room waits on no file", async () => {
  const was = process.env.STILLFAIL_TEST_HOST;
  delete process.env.STILLFAIL_TEST_HOST;
  const store = Store.open(":memory:");
  try {
    const dataDir = scratch("overview-main-thread");
    const hub: any = { processes: () => [], config: () => ({ dataDir }) };
    const viewer = { sub: "s", email: "person@example.test", name: "P", role: "member", workspace: "mine", device: "d", home: false };
    let seen: any;
    const calls = await syncCalls(async () => void (seen = await overview({ store, hub, cloud: { state: null } as any, config: () => ({ connects: [] }) }, viewer, "en")));
    assert.deepEqual(calls, []);
    assert.ok(seen.disk.totalBytes > 0 && seen.disk.freeBytes >= 0, JSON.stringify(seen.disk));
  } finally {
    store.close();
    if (was !== undefined) process.env.STILLFAIL_TEST_HOST = was;
  }
});

/// A station process's events, handing over in `file`.
function events(file: string, clock: ReturnType<typeof testClock>["clock"], gone: Promise<void> = Promise.resolve()) {
  return new Events({
    readers: { read: async (op: string) => { if (op === "sharedOf") return JSON.stringify({ rows: [], scope: null }); throw new Error("nothing read"); } } as any,
    said: (_thread, entries) => entries.map((e) => ({ n: e.n, text: "hi" })),
    subscribe: () => () => {},
    host: async () => ({ cpu: 1 }),
    jobLog: () => null,
    logNow: async () => null,
    sessionExists: () => true,
    clock,
    handover: { file, previous: { pid: process.pid, gone } },
  });
}

test("what is told handed over to the next process and taken up there waits on no file", async () => {
  const time = testClock();
  const file = join(scratch("events-main-thread"), "run", "events.json");
  const before = events(file, time.clock);
  before.follow({ overview: async () => ({ running: 0 }) });
  await settle();
  const answer = await before.open({ sub: "a", email: "a@x", name: "a", role: "member", workspace: "w", device: "d" }, "zh", false, [], []);
  const body = (answer.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  await body.next();
  const gone = Promise.withResolvers<void>();
  let next: Events | null = null;
  const calls = await syncCalls(async () => {
    await before.handOver();
    assert.ok((await stat(file)).isFile(), "handed over");
    next = events(file, time.clock, gone.promise);
    gone.resolve();
    await settle();
    // Answered once taken up, from what was handed over.
    await next.open({ sub: "a", email: "a@x", name: "a", role: "member", workspace: "w", device: "d" }, "zh", false, [], []);
  });
  await body.return?.();
  assert.deepEqual(calls, []);
  await assert.rejects(stat(file), /ENOENT/, "taken up, and taken away");
});

test("the station's Chrome found, started and ended, and whose its tabs are, wait on no file", async () => {
  const dir = scratch("chrome-main-thread");
  // A port nothing answers on: what Chrome said of itself there is stale.
  const port = await new Promise<number>((resolve) => {
    const s = createServer().listen(0, "127.0.0.1", () => {
      const p = (s.address() as { port: number }).port;
      s.close(() => resolve(p));
    });
  });
  mkdirSync(join(dir, "profile"), { recursive: true });
  const host = chromeHost({ dir, binary: join(dir, "no-chrome"), headless: true });
  const running: Running = { pid: null, started: null, port, ws: `ws://127.0.0.1:${port}/devtools/browser/x`, binary: "x", headless: true, userAgent: "" };
  await new BrowserState(dir).change((s) => ({ ...s, running, port, lastUse: 7 }));
  writeFileSync(join(dir, "profile", "DevToolsActivePort"), `${port}\n/devtools/browser/x\n`);
  let found: unknown;
  let failed: unknown;
  // Whether nice is here is looked at once for the process (platform/unix.ts `niceThere`), by the first runner or job
  // a station starts; Chrome started under it finds it known.
  niced("true", []);
  const calls = await syncCalls(async () => {
    found = await host.find();
    await host.kill(running);
    // A program that is not there: it ends as it starts.
    failed = await host.launch().catch((e: Error) => e.message);
    const owners = new Owners(dir);
    await owners.ready();
    owners.set("A", "chat-1");
    owners.set("B", "chat-2");
    owners.drop("B");
    await owners.written();
  });
  assert.deepEqual(calls, []);
  assert.equal(found, null, "nothing answers where it said it is");
  assert.match(String(failed), /ended as it started/);
  const state = await readState(dir);
  assert.equal(state.running, undefined, "its record taken away as it was ended");
  assert.equal(state.lastUse, 7, "the rest kept");
  await assert.rejects(stat(join(dir, "profile", "DevToolsActivePort")), /ENOENT/);
  const owners = new Owners(dir);
  await owners.ready();
  assert.equal(owners.of("A"), "chat-1");
  assert.equal(owners.of("B"), undefined);
});

test("a chat's post through another station's connect, its file kept there and taken away, and what is learned of the connect, wait on no file", async () => {
  const dir = scratch("connects-main-thread");
  const uploads = join(dir, "run", "connect-uploads");
  const file = join(dir, "a.txt");
  writeFileSync(file, "hello");
  const there: string[] = [];
  const surface = {
    post: async (_thread: ThreadRef, _message: string, files: Attachment[]) => {
      for (const f of files) there.push(await readFile(f.path, "utf8"));
      return "ts-1";
    },
  } as unknown as ChatSurface;
  const answer = answerCall(() => surface, uploads);
  const ask = (_station: string, request: Json) => answer("there", request, "w");
  const described: Described = {
    kind: "slack", workspace: "w", mode: "multi-session", requireMention: true, bind: { runtime: "claude" }, botUserId: "B1", botName: "bot", identity: null,
    platform: "slack", team: "T1", cards: false, loginCards: false, mention: ["<@", ">"], link: null, has: [],
  };
  let posted: string | null = null;
  let left: string[] = [];
  const calls = await syncCalls(async () => {
    const remote = new RemoteConnects(dir, () => "here", ask, () => null);
    await remote.ready();
    remote.learn("c1@there", "there", described);
    posted = await remote.surface("c1@there")!.post({ channel: "C1", threadTs: "1.0" }, "hi", [{ name: "a.txt", path: file, size: 5 }]);
    left = await readdir(uploads);
    remote.moved("c1@there", "elsewhere");
    await remote.written();
  });
  assert.deepEqual(calls, []);
  assert.equal(posted, "ts-1");
  assert.deepEqual(there, ["hello"], "the file came whole");
  assert.deepEqual(left, [], "and was taken away once posted");
  // Started again: what it learned, read before it serves.
  const again = new RemoteConnects(dir, () => "here", ask, () => null);
  await again.ready();
  assert.deepEqual(again.connects().map((c) => c.id), ["c1@there"]);
  assert.equal(again.surface("c1@there")!.station, "elsewhere");
});

test("a login of the machine's started, its page read as it opens it, and its end recorded, wait on no file", { skip: WINDOWS && "logins run in a pseudo-terminal: script is Unix's" }, async () => {
  const home = scratch("logins-main-thread");
  const bin = join(home, "bin");
  mkdirSync(bin, { recursive: true });
  script(join(bin, "fakeopen"), `#!/bin/sh\nopen "https://example.com/device?user_code=WXYZ-1234"\necho "Open https://example.com/device and enter WXYZ-1234"\nread forever\n`);
  const env = { HOME: home, PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: "en_US.UTF-8" };
  const time = testClock();
  const by = { by: { email: "a@x.com", name: "A" }, workspace: "w1" };
  let listed: Login[] = [];
  let shown: Login | null = null;
  const calls = await syncCalls(async () => {
    const logins = new Logins({ data: join(home, "data"), env: () => env, clock: time.clock, lang: () => "en" });
    await logins.ready();
    const started = await logins.start("fakeopen", by);
    shown = await upon((wake) => logins.changes(wake), () => { const l = logins.get(started.id); return l?.step === "device" && l.url?.includes("user_code") ? l : undefined; }, "its page");
    logins.cancel(started.id);
    listed = logins.logins();
    await logins.close();
  });
  assert.deepEqual(calls, []);
  assert.equal(shown!.code, "WXYZ-1234");
  assert.deepEqual(listed.map((l) => [l.name, l.state]), [["fakeopen", "cancelled"]]);
  const again = new Logins({ data: join(home, "data"), env: () => env, lang: () => "en" });
  await again.ready();
  assert.deepEqual(again.logins().map((l) => [l.name, l.state, l.by.name]), [["fakeopen", "cancelled", "A"]]);
  await again.close();
});

test("a profile's sign-in started, and the page its command opened read for the station's browser, wait on no file", { skip: WINDOWS && "the stand-in browser writes nothing down on Windows" }, async () => {
  const dir = scratch("sign-in-main-thread");
  const fake = join(dir, "fake-login");
  const loopback = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=y";
  script(fake, fakeLogin().replace('echo "Opening browser to sign in…"', `open '${loopback}'\necho "Opening browser to sign in…"`));
  const visited: string[] = [];
  const b = fakeBrowser((url) => visited.push(url));
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) });
  logins.attach(b.pages);
  let job: LoginJob | null = null;
  const calls = await syncCalls(async () => {
    await logins.start({ id: "sub", runtime: "claude", home: join(dir, "homes", "sub") }, "en");
    job = await upon((wake) => logins.changes(wake), () => { const j = logins.get("sub"); return j?.state === "needs_code" ? j : undefined; }, "needs_code");
    await logins.openPage("sub", "en");
    logins.cancel("sub");
  });
  await logins.close();
  assert.deepEqual(calls, []);
  assert.equal(job!.browser, true);
  assert.deepEqual([...b.tabs.values()], [], "its tab closed as it ended");
  assert.deepEqual(visited, [loopback], "the page it opened, which comes back to it here");
});

test("a Feishu app made by a scan, followed and kept until it is saved, waits on no file", async () => {
  const dir = scratch("feishu-main-thread");
  const t = testClock();
  const post = async (_domain: string, form: Record<string, string>): Promise<Json> =>
    form.action === "init" ? { supported_auth_methods: ["client_secret"] }
      : form.action === "begin" ? { device_code: "dc", verification_uri_complete: "https://accounts.feishu.cn/x?user_code=AB", interval: 5, expires_in: 600 }
      : { client_id: "cli_new", client_secret: "sec" };
  let saved: string | null = null;
  const calls = await syncCalls(async () => {
    const reg = new Registrations({ clock: t.clock, post, file: join(dir, "feishu-registrations.json") });
    await reg.ready();
    reg.start(async () => "unused");
    const r = await reg.begin("a@x.test", "feishu", "bot");
    await t.adjust(5000);
    await upon((wake) => reg.onChange(wake), () => reg.get(r.id)?.state === "done", "done");
    saved = await reg.complete(r.id, "a@x.test", "", async () => "connect-1");
    await reg.close();
  });
  assert.deepEqual(calls, []);
  assert.equal(saved, "connect-1");
  const kept = JSON.parse(await readFile(join(dir, "feishu-registrations.json"), "utf8"));
  assert.deepEqual(kept.map((r: Json) => [r.state, r.connectId, r.app]), [["done", "connect-1", null]], "its secret not kept once saved");
});

/// A fake runtime's directory first on a profile's PATH (test/fake).
const fakes = join(dirname(fileURLToPath(import.meta.url)), "fake");

test("a Claude Code session opened, and a Hermes Agent session started and resumed, wait on no file", async () => {
  const data = mkdtempSync(WINDOWS ? join(tmpdir(), "io-") : "/tmp/io-");
  dirs.push(data);
  const PATH = `${fakes}${delimiter}${process.env.PATH}`;
  const claude = new ClaudeDriver({ data });
  const hermes = new HermesDriver({ data });
  try {
    const home = join(data, "cc");
    const claudeOptions: OpenOptions = {
      key: "slack:T1:C1:1700000000.0001",
      profile: { id: "cc", runtime: "claude", home, access: { kind: "opencode-go", key: "k1" }, env: { PATH, FAKE_DUMP: join(data, "cc-dump") } },
      cwd: data,
      instructions: "be brief",
      mcpToken: "tok",
      mcpUrl: "http://127.0.0.1:4750/mcp",
      route: "r1",
    };
    const hermesOptions: OpenOptions = {
      key: "hermes-io",
      profile: { id: "hm", runtime: "hermes", home: join(data, "hm"), access: { kind: "env" }, env: { PATH, FAKE_DUMP: join(data, "hm-dump") } },
      cwd: data,
      instructions: "be brief",
      mcpToken: "tok",
      mcpUrl: "http://127.0.0.1:4750/mcp",
      route: "r2",
      model: "openrouter:test",
    };
    // (the keychain's stand-in made once before, as a running station has it)
    await claude.open(claudeOptions, () => {}).then((s) => s.dispose());
    let id = "";
    const calls = await syncCalls(async () => {
      const opened = await claude.open({ ...claudeOptions, profile: { ...claudeOptions.profile, home: join(data, "cc2") } }, () => {});
      await opened.dispose();
      const started = await hermes.open(hermesOptions, () => {});
      id = started.id();
      await started.dispose();
      const resumed = await hermes.open({ ...hermesOptions, resume: id }, () => {});
      assert.equal(resumed.id(), id);
      await resumed.dispose();
      await assert.rejects(hermes.open({ ...hermesOptions, resume: "never-kept" }, () => {}), /no Hermes session never-kept/);
    });
    // What is left is the runner's start (agents/runner.ts: finding its binary and the command) and the agents' program
    // (agents/mb-program.ts), not the drivers' own.
    assert.deepEqual(
      calls.filter((c) => !/< (startRunner|SessionsProgram\.of)\b/.test(c)),
      [],
    );
  } finally {
    await Promise.all([claude.shutdown(), hermes.shutdown()]);
  }
});

test("a profile checked (Claude Code, Cursor, Devin, Grok Build) and a Codex login's allowance read wait on no file", { skip: WINDOWS && "the stand-in commands are shell scripts" }, async () => {
  const m = machine({
    claude: `echo '{"loggedIn":true,"email":"a@x.com","subscriptionType":"max"}'`,
    devin: `case "$1" in auth) printf 'User:\\n  Email:             d@example.com\\n' ;; *) echo '[]' ;; esac`,
    grok: `echo 'Available models:'; echo '  * grok-4.7 (default)'`,
  });
  const homes = (name: string) => {
    const home = join(m.home, name);
    mkdirSync(home, { recursive: true });
    return home;
  };
  const claudeHome = homes("claude");
  writeFileSync(join(claudeHome, ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "tok", expiresAt: Date.now() + 3_600_000, subscriptionType: "max" } }));
  const cursorHome = homes("cursor");
  mkdirSync(join(cursorHome, "cursor"), { recursive: true });
  writeFileSync(join(cursorHome, "cursor", "auth.json"), JSON.stringify({ apiKey: "crsr_1", email: "cu@example.com", keyName: "k", createdAt: 0 }));
  const devinHome = homes("devin");
  const grokHome = homes("grok");
  mkdirSync(join(grokHome, "grok"), { recursive: true });
  writeFileSync(join(grokHome, "grok", "auth.json"), JSON.stringify({ x: { email: "g@example.com" } }));
  const codexHome = homes("codex");
  const exp = Math.floor(Date.now() / 1000) + 3600;
  writeFileSync(join(codexHome, "auth.json"), JSON.stringify({ tokens: { access_token: idToken({ exp }), account_id: "acc" } }));
  const p = await provider((a) => {
    if (a.url === "/v1/models") return { status: 200, body: { data: [{ id: "claude-opus-5-5" }] } };
    if (a.url === "/cursor/v1/me") return { status: 200, body: { apiKeyName: "k", userEmail: "cu@example.com" } };
    if (a.url === "/cursor/v1/models") return { status: 200, body: { items: [{ id: "default" }] } };
    if (a.url === "/backend-api/wham/usage") return { status: 200, body: { rate_limit: { primary_window: { used_percent: 1, limit_window_seconds: 18_000, reset_at: 1_900_000_000 } } } };
    return { status: 404, body: {} };
  });
  const urls = { ...URLS, anthropic: p.base, chatgpt: p.base, cursor: { website: p.base, backend: p.base, api: `${p.base}/cursor` } };
  const base = { kind: "subscription" as const, key: "", via: {}, env: m.env, machine: false, urls, lang: "en" as const };
  try {
    const checked: string[] = [];
    const calls = await syncCalls(async () => {
      for (const [runtime, home] of [["claude", claudeHome], ["cursor", cursorHome], ["devin", devinHome], ["grok", grokHome]] as const) {
        const check = await checkProfile({ ...base, runtime, home });
        checked.push(`${runtime} ${check.state} ${check.detail}`);
      }
      assert.ok((await codexUsage(join(codexHome, "auth.json"), urls)) !== null);
      assert.ok((await lentCodexUsage(codexHome, Date.now(), urls)) !== null);
    });
    assert.deepEqual(calls, []);
    assert.deepEqual(checked, ["claude ok Signed in, a@x.com, max", "cursor ok Signed in, cu@example.com", "devin ok Signed in, d@example.com", "grok ok Signed in, g@example.com"]);
    assert.equal(await devinEmail(devinHome), "d@example.com", "noted for naming the account");
  } finally {
    await p.close();
  }
});

test("an OpenCode Console and a Kimi sign-in renewed wait on no file of their own", async () => {
  const data = scratch("renew-main-thread");
  const s = { console: "rt_1", kimi: "kr_1" };
  const p = await provider((a) => {
    if (a.url === "/console/auth/device/token" && a.form.refresh_token === s.console) {
      s.console = "rt_2";
      return { status: 200, body: { access_token: "st_2", refresh_token: s.console, expires_in: 2_592_000, org_id: "wrk_1" } };
    }
    if (a.url === "/api/oauth/token" && a.form.refresh_token === s.kimi) {
      s.kimi = "kr_2";
      return { status: 200, body: { access_token: "kt_2", refresh_token: s.kimi, expires_in: 900 } };
    }
    return { status: 400, body: { error: "invalid_grant" } };
  });
  const due = Date.now() + 60_000;
  for (const [id, file, login] of [
    ["go", CONSOLE_FILE, { access: "st_1", refresh: "rt_1", expiresAt: due, org: "wrk_1", email: "go@example.com", workspace: null }],
    ["kimi-code", KIMI_FILE, { access: "kt_1", refresh: "kr_1", expiresAt: due, lifeMs: 900_000, deviceId: "dev" }],
  ] as const) {
    mkdirSync(join(data, "homes", id), { recursive: true });
    writeFileSync(join(data, "homes", id, file), JSON.stringify(login));
  }
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      profiles: [
        { id: "go", name: "Go", access: { kind: "opencode-go", key: "st_1", login: true }, home: "homes/go", env: {} },
        { id: "kimi-code", name: "Kimi Code", access: { kind: "api-provider", provider: "kimi-code", login: true }, home: "homes/kimi-code", env: {} },
      ],
    }),
  );
  // Watched, as the station's own is (services.ts StationConfig): read and written off the main thread.
  const config = new ConfigFile(data);
  config.check = checkConfig;
  config.watch();
  const accounts = new Accounts({
    data,
    store: Store.open(":memory:", null),
    config,
    urls: { ...URLS, console: `${p.base}/console`, kimi: p.base },
    machine: null,
    checkOnStart: false,
    quota: null,
    resetQuota: null,
    check: async () => ({ state: "ok", detail: "", models: null, checkedAt: 0 }),
    discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
  });
  try {
    const calls = await syncCalls(async () => {
      await accounts.renewKimi("kimi-code");
      await accounts.renewConsole("go");
    });
    assert.deepEqual(calls, []);
    assert.deepEqual([(await readKimi(join(data, "homes", "kimi-code")))?.access, (await readConsole(join(data, "homes", "go")))?.refresh], ["kt_2", "rt_2"]);
    assert.equal(await readFile(join(data, "homes", "kimi-code", KIMI_TOKEN_FILE), "utf8"), "kt_2");
  } finally {
    await accounts.close();
    await p.close();
    config.unwatch();
    await config.written();
  }
});

test("a new profile made from a Cursor sign-in reads its home with no synchronous call", async () => {
  const data = scratch("new-login-main-thread");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [] }));
  const p = await provider((a) => {
    if (a.url === "/backend/auth/poll") return { status: 200, body: { accessToken: "session-token", refreshToken: "refresh" } };
    if (a.url === "/backend/aiserver.v1.DashboardService/CreateUserApiKey") return { status: 200, body: { apiKey: "crsr_1" } };
    if (a.url === "/backend/aiserver.v1.DashboardService/GetMe") return { status: 200, body: { email: "cu@example.com" } };
    return { status: 404, body: {} };
  });
  // Watched, as the station's own is (services.ts StationConfig): read and written off the main thread.
  const config = new ConfigFile(data);
  config.check = checkConfig;
  config.watch();
  const accounts = new Accounts({
    data,
    store: Store.open(":memory:", null),
    config,
    urls: { ...URLS, cursor: { website: `${p.base}/site`, backend: `${p.base}/backend`, api: `${p.base}/api` } },
    machine: null,
    checkOnStart: false,
    quota: null,
    resetQuota: null,
    check: async () => ({ state: "ok", detail: "", models: null, checkedAt: 0 }),
    discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
  });
  accounts.start();
  const owner = { sub: "s", email: "o@example.com", name: "", role: "owner", workspace: "ws", device: "d" };
  try {
    let made = "";
    const calls = await syncCalls(async () => {
      const { id } = await accounts.newLogin({ runtime: "cursor" }, owner, "en");
      made = await upon((wake) => accounts.onChange(wake), () => accounts.loginsView().find((l) => l.id === id)?.created, "profile");
    });
    assert.equal(made, "cu-example-com");
    // The homes listed for the ids taken and the new home moved to its name off the thread too, config.json's edit too.
    assert.deepEqual(calls, []);
  } finally {
    await accounts.close();
    await p.close();
    config.unwatch();
    await config.written();
  }
});

/// What drives the stand-in runtimes of test/fake: a driver's own work is what is held, not the runner's start
/// (agents/runner.ts: finding its binary and the command) or the agents' program (agents/mb-program.ts).
const ownCalls = (calls: string[]) => calls.filter((c) => !/< (startRunner|SessionsProgram\.of)\b/.test(c));

test("Cursor, DeepSeek Harness, Devin, Grok Build, Antigravity CLI and Codex sessions opened, and one not kept refused, wait on no file", { skip: WINDOWS && "the stand-in runtimes are shell scripts" }, async () => {
  const data = mkdtempSync("/tmp/io-");
  dirs.push(data);
  const PATH = `${fakes}${delimiter}${process.env.PATH}`;
  const cursor = new CursorDriver({ data, sdk: join(fakes, "cursor-sdk") });
  const dsh = new DshDriver({ data });
  const devin = new DevinDriver({ data });
  const grok = new GrokDriver({ data });
  const agy = new AgyDriver({ data });
  const codex = new CodexDriver({ data, caBundle: join(data, "cert.pem"), env: { ...process.env, PATH } });
  writeFileSync(join(data, "cert.pem"), "");
  const skills = join(data, "skills");
  mkdirSync(join(skills, "s1"), { recursive: true });
  let n = 0;
  const options = (runtime: string, access: Record<string, unknown>, extra: Partial<OpenOptions> = {}): OpenOptions => {
    const i = ++n;
    return {
      key: `slack:T1:C${i}:1700000000.000${i}`,
      profile: { id: `${runtime}${i}`, runtime, home: join(data, `h${i}`), access, env: { PATH, FAKE_DUMP: join(data, `dump${i}`) } } as OpenOptions["profile"],
      cwd: data,
      instructions: "be brief",
      skills,
      mcpToken: "tok",
      mcpUrl: "http://127.0.0.1:4750/mcp",
      route: `r${i}`,
      ...extra,
    };
  };
  const cursorOptions = options("cursor", { kind: "subscription" });
  mkdirSync(cursorHome(cursorOptions.profile.home), { recursive: true });
  writeFileSync(join(cursorHome(cursorOptions.profile.home), "auth.json"), JSON.stringify({ apiKey: "crsr_k1", email: "a@b.c", keyName: "still.fail", createdAt: 1 }));
  const devinOptions = options("devin", { kind: "subscription" }, { model: "swe-2" });
  mkdirSync(join(devinData(devinOptions.profile.home), "devin"), { recursive: true });
  writeFileSync(join(devinData(devinOptions.profile.home), "devin", "credentials.toml"), `windsurf_api_key = "devin-k1"\n`);
  const opened: [{ open: (o: OpenOptions, e: () => void) => Promise<{ dispose: () => Promise<void> }> }, OpenOptions, RegExp][] = [
    [cursor, cursorOptions, /no Cursor session/],
    [dsh, options("dsh", { kind: "opencode-go", key: "k1" }, { model: "m1" }), /no dsh session/],
    [devin, devinOptions, /no Devin session/],
    [grok, options("grok", { kind: "subscription" }, { model: "grok-4.7" }), /no Grok Build session/],
    [agy, options("agy", { kind: "api-provider", provider: "google", key: "gemini-key" }), /no Antigravity conversation/],
    [codex, options("codex", { kind: "opencode-go", key: "k2" }), /./],
  ];
  try {
    // (the program reading the agents started once before, as a running station has it)
    await dsh.open(options("dsh", { kind: "opencode-go", key: "k1" }, { model: "m1" }), () => {}).then((s) => s.dispose());
    const calls = await syncCalls(async () => {
      for (const [driver, o, refused] of opened) {
        const session = await driver.open(o, () => {});
        await session.dispose();
        // Codex opens a thread it was not given anew, as its app-server keeps them: no refusal of its own to look at.
        if (driver !== codex) await assert.rejects(driver.open({ ...o, key: `${o.key}-again`, resume: "0198c0de-0000-7000-8000-00000000dead" }, () => {}), refused);
      }
      assert.equal(await findSdk(data), null, "not installed under the station's data");
    });
    assert.deepEqual(ownCalls(calls), []);
    // Each one's instructions in the folder of the session's own (Cursor's, Devin's), its skills linked in.
    assert.ok((await readdir(join(cursorHome(cursorOptions.profile.home), "station"))).length === 1);
  } finally {
    await Promise.all([cursor, dsh, devin, grok, agy, codex].map((d) => d.shutdown()));
  }
});

test("the runners alive found, a machine profile's Codex home linked and the machine's Claude login read wait on no file", { skip: WINDOWS && "the runner's stand-in is a shell script" }, async () => {
  const data = mkdtempSync("/tmp/io-");
  dirs.push(data);
  const info = await startRunner(data, "io-runner", "/bin/sh", ["-c", "sleep 30"], { PATH: process.env.PATH ?? "" }, data);
  const m = machine();
  mkdirSync(join(m.home, ".codex"), { recursive: true });
  writeFileSync(join(m.home, ".codex", "auth.json"), "{}");
  mkdirSync(join(m.home, ".claude"), { recursive: true });
  writeFileSync(join(m.home, ".claude", ".credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "tok", expiresAt: Date.now() + 3_600_000 } }));
  try {
    let found: string[] = [];
    let token: string | undefined;
    const home = join(data, "machine-codex");
    const calls = await syncCalls(async () => {
      found = (await liveRunners(data)).map((r) => r.id);
      await linkCodexAuthSoon(home, m.env);
      // Made again once something replaced it.
      await rm(join(home, "auth.json"));
      await writeFile(join(home, "auth.json"), "{}");
      await linkCodexAuthSoon(home, m.env);
      token = (await readClaudeCredentials({ ...m.env, STILLFAIL_NO_KEYCHAIN: "1" }))?.token;
    });
    assert.deepEqual(calls, []);
    assert.deepEqual(found, ["io-runner"]);
    assert.equal(await readlink(join(home, "auth.json")), join(m.home, ".codex", "auth.json"));
    assert.equal(token, "tok");
  } finally {
    process.kill(-info.pgid, "SIGKILL");
  }
});

test("a profile made of a key, one on the machine's login, and a sign-in for a new one dropped wait on no file of their own", { skip: WINDOWS && "the stand-in commands are shell scripts" }, async () => {
  const data = scratch("profiles-main-thread");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [] }));
  const s = { confirmed: false };
  const p = await provider((a) => {
    if (a.url === "/backend/auth/poll") return s.confirmed ? { status: 200, body: { accessToken: "session-token", refreshToken: "refresh" } } : { status: 404, body: "Not found" };
    return { status: 404, body: {} };
  });
  const m = machine({ codex: "echo 'Logged in using ChatGPT'" });
  mkdirSync(join(m.home, ".codex"), { recursive: true });
  writeFileSync(join(m.home, ".codex", "auth.json"), JSON.stringify({ tokens: { access_token: "at", account_id: "acc" } }));
  // Watched, as the station's own is (services.ts StationConfig): read and written off the main thread.
  const config = new ConfigFile(data);
  config.check = checkConfig;
  config.watch();
  const accounts = new Accounts({
    data,
    store: Store.open(":memory:", null),
    config,
    urls: { ...URLS, cursor: { website: `${p.base}/site`, backend: `${p.base}/backend`, api: `${p.base}/api` } },
    machine: new MachineLogins(m.env, undefined, () => "en"),
    checkOnStart: false,
    quota: null,
    resetQuota: null,
    check: async () => ({ state: "ok", detail: "", models: null, checkedAt: 0 }),
    discover: async (profile) => ({ state: "unsupported", detail: "", model: null, provider: null, models: [], fingerprint: fingerprint(profile) }),
  });
  accounts.start();
  const owner = { sub: "s", email: "o@example.com", name: "", role: "owner", workspace: "ws", device: "d" };
  try {
    const made: string[] = [];
    let dropped = "";
    const calls = await syncCalls(async () => {
      made.push(await accounts.newKeyedProfile({ access: { kind: "opencode-go", key: "k1" } }, owner, "en"));
      // Two at once: each its own id.
      // (which of the two takes which id is the disk's: put in order)
      made.push(...(await Promise.all([1, 2].map(() => accounts.newKeyedProfile({ access: { kind: "anthropic-api", key: "k2" } }, owner, "en")))).sort());
      made.push(await accounts.newMachineProfile({ runtime: "codex" }, owner, "en"));
      ({ id: dropped } = await accounts.newLogin({ runtime: "cursor" }, owner, "en"));
      await accounts.dropLogin(dropped);
    });
    assert.deepEqual(calls, []);
    assert.deepEqual(made, ["opencode-go", "anthropic-api", "anthropic-api-2", "machine-codex"]);
    assert.deepEqual((await readdir(join(data, "homes"))).sort(), [...made].sort(), "the dropped sign-in's home taken away");
    assert.equal(await readlink(join(data, "homes", "machine-codex", "auth.json")), join(m.home, ".codex", "auth.json"));
    assert.equal(accounts.hasPending(dropped), false);
  } finally {
    await accounts.close();
    await p.close();
    config.unwatch();
    await config.written();
  }
});
