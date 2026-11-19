// Signing in from the pages, and the machine's own logins: with stand-in CLIs in
// temp homes.
import assert from "node:assert/strict";
import { test } from "node:test";
import { chmodSync, mkdirSync, readlinkSync, lstatSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { claudeCodeOf, deviceCode, LoginManager, type LoginState, stripAnsi, VERIFY_WAIT_MS } from "../src/accounts/login.ts";
import { MachineLogins } from "../src/accounts/machine.ts";
import { linkCodexAuthSoon } from "../src/agents/machine-logins.ts";
import { approval, exe, fakeBrowser, fakeLogin, idToken, machine, sameAs, script, temp, upon } from "./accounts-fakes.ts";
import { WINDOWS } from "../src/platform/index.ts";
import { tr } from "../src/ops/i18n.ts";
import { testClock } from "./hub-fakes.ts";

test("a subscription sign-in relays the link, the code and the result", async () => {
  const dir = temp("login");
  const fake = join(dir, "fake-login");
  const approved = approval(dir);
  script(fake, fakeLogin(approved.path));
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) });
  const heard: string[] = [];
  logins.changes((id) => heard.push(id));
  const wait = (profile: string, state: LoginState) =>
    upon((wake) => logins.changes(wake), () => (logins.get(profile)?.state === state ? logins.get(profile) : undefined), `${profile} ${state}`);
  try {
    const sub = { id: "sub", runtime: "claude" as const, home: join(dir, "homes", "sub") };
    await logins.start(sub, "zh");
    const job = await wait("sub", "needs_code");
    assert.ok(job.url!.startsWith("https://claude.com/cai/oauth/authorize?"), JSON.stringify(job));
    assert.equal(heard[0], "sub");
    await logins.submitCode("sub", "wrong#y", "zh");
    assert.ok((await wait("sub", "failed")).error!.includes("invalid code"));
    await assert.rejects(logins.submitCode("sub", "x", "zh"), /未在等待授权码/);
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    await assert.rejects(logins.submitCode("sub", "  ", "zh"), /空/);
    await logins.submitCode("sub", " good-code#y ", "zh");
    await wait("sub", "done");

    const cxs = { id: "cxs", runtime: "codex" as const, home: join(dir, "homes", "cxs") };
    await logins.start(cxs, "zh");
    const device = await wait("cxs", "needs_approval");
    assert.deepEqual([device.url, device.userCode], ["https://auth.openai.com/codex/device", "ABCD-12345"]);
    await approved.approve();
    await wait("cxs", "done");

    // A cancelled sign-in stops its command and says so.
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    logins.cancel("sub");
    assert.equal(logins.get("sub")!.state, "cancelled");

    // A command that cannot run is a failed sign-in that says why.
    const none = new LoginManager(dir, { claude: join(dir, "no-such-command"), codex: "x" });
    const failed = await none.start(sub, "zh");
    assert.equal(failed.state, "failed");
    assert.ok(failed.error!.startsWith("无法运行登录命令"), failed.error!);
    await none.close();
  } finally {
    await logins.close();
  }
});

test("Claude's code is checked before it goes in: one it would not take is refused saying what to paste, the sign-in still waiting for a code", async () => {
  const dir = temp("login");
  const fake = join(dir, "fake-login");
  script(fake, fakeLogin());
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) });
  const wait = (profile: string, state: LoginState) =>
    upon((wake) => logins.changes(wake), () => (logins.get(profile)?.state === state ? logins.get(profile) : undefined), `${profile} ${state}`);
  try {
    const sub = { id: "sub", runtime: "claude" as const, home: join(dir, "homes", "sub") };
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    // Only what precedes `#`: refused, the same sign-in still waiting; its command still running.
    await assert.rejects(logins.submitCode("sub", "good-code", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    await assert.rejects(logins.submitCode("sub", "good-code#", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    await assert.rejects(logins.submitCode("sub", "#y", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    await assert.rejects(logins.submitCode("sub", "a#b#y", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    // Another sign-in's: refused, saying where the new one is.
    await assert.rejects(logins.submitCode("sub", "good-code#other", "en"), { message: tr("en", "station.login.claudeWrongState") });
    assert.equal(logins.get("sub")!.state, "needs_code");
    // The whole code then signs in on the same sign-in, with no new link.
    await logins.submitCode("sub", "good-code#y", "zh");
    await wait("sub", "done");

    // The address its page was at, pasted: its code and state taken out of it.
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    await assert.rejects(logins.submitCode("sub", "https://platform.claude.com/oauth/code/callback?code=good-code", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    await assert.rejects(logins.submitCode("sub", "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=y", "zh"), { message: tr("zh", "station.login.claudeIncompleteCode") });
    await assert.rejects(logins.submitCode("sub", "https://platform.claude.com/oauth/code/callback?code=good-code&state=other", "zh"), { message: tr("zh", "station.login.claudeWrongState") });
    await logins.submitCode("sub", " https://platform.claude.com/oauth/code/callback?code=good-code&state=y ", "zh");
    await wait("sub", "done");
  } finally {
    await logins.close();
  }
});

test("a code Claude's command says it would not take, or one it says nothing of, ends the sign-in saying to start again", async () => {
  const dir = temp("login");
  const fake = join(dir, "fake-login");
  script(fake, fakeLogin());
  const time = testClock();
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) }, undefined, time.clock);
  const wait = (profile: string, state: LoginState) =>
    upon((wake) => logins.changes(wake), () => (logins.get(profile)?.state === state ? logins.get(profile) : undefined), `${profile} ${state}`);
  try {
    const sub = { id: "sub", runtime: "claude" as const, home: join(dir, "homes", "sub") };
    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    await logins.submitCode("sub", "refused#y", "zh");
    assert.equal((await wait("sub", "failed")).error, tr("zh", "station.login.claudeIncompleteCode"));

    await logins.start(sub, "zh");
    await wait("sub", "needs_code");
    await logins.submitCode("sub", "silent#y", "zh");
    assert.equal(logins.get("sub")!.state, "verifying");
    await time.adjust(VERIFY_WAIT_MS - 1);
    assert.equal(logins.get("sub")!.state, "verifying");
    await time.adjust(1);
    assert.equal((await wait("sub", "failed")).error, tr("zh", "station.login.verifyTimedOut"));
  } finally {
    await logins.close();
  }
});

test("Claude's pasted code is read as its command takes it", () => {
  const auth = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&state=st8";
  assert.equal(claudeCodeOf("abc#st8", auth, "en"), "abc#st8");
  assert.equal(claudeCodeOf("abc # st8", auth, "en"), "abc#st8");
  assert.equal(claudeCodeOf("abc#anything", null, "en"), "abc#anything");
  assert.equal(claudeCodeOf("https://platform.claude.com/oauth/code/callback?code=abc&state=st8", auth, "en"), "abc#st8");
  assert.throws(() => claudeCodeOf("abc", auth, "en"), { message: tr("en", "station.login.claudeIncompleteCode") });
  assert.throws(() => claudeCodeOf("abc#other", auth, "en"), { message: tr("en", "station.login.claudeWrongState") });
});

test("a sign-in's page opens in the station's browser: Claude's loopback page (no code to paste), a device code's page; its tab closed as it ends", { skip: WINDOWS && "the stand-in browser writes nothing down on Windows" }, async () => {
  const dir = temp("login");
  const fake = join(dir, "fake-login");
  const approved = approval(dir);
  // Claude Code opens its loopback page and prints the one to paste a code from.
  const loopback = "https://claude.com/cai/oauth/authorize?code=true&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A54545%2Fcallback&state=y";
  script(fake, fakeLogin(approved.path).replace('echo "Opening browser to sign in…"', `open '${loopback}'\necho "Opening browser to sign in…"`));
  const b = fakeBrowser();
  const logins = new LoginManager(dir, { claude: exe(fake), codex: exe(fake) });
  logins.attach(b.pages);
  const until = (profile: string, ok: (j: NonNullable<ReturnType<typeof logins.get>>) => boolean, what: string) =>
    upon((wake) => logins.changes(wake), () => { const j = logins.get(profile); return j && ok(j) ? j : undefined; }, what);
  try {
    const sub = { id: "sub", runtime: "claude" as const, home: join(dir, "homes", "sub") };
    await logins.start(sub, "zh");
    const job = await until("sub", (j) => j.state === "needs_code", "needs_code");
    assert.deepEqual([job.browser, job.screen], [true, undefined]);
    assert.notEqual(job.url, loopback, "the page to paste a code from is still the one shown");
    assert.equal(await logins.openPage("sub", "zh"), "browser:T1");
    assert.deepEqual([...b.tabs.values()], [loopback], "the page it opened, which comes back to it here");
    await until("sub", (j) => j.screen === "browser:T1", "its tab told");
    // Started again: the old tab goes with the old sign-in.
    await logins.start(sub, "zh");
    assert.equal(b.tabs.size, 0);
    await until("sub", (j) => j.state === "needs_code", "needs_code again");
    await logins.openPage("sub", "zh");
    logins.cancel("sub");
    assert.deepEqual([b.tabs.size, logins.get("sub")!.screen, logins.get("sub")!.browser], [0, undefined, undefined]);
    await assert.rejects(logins.openPage("sub", "zh"), /没有需要在浏览器中打开的页面/);

    const cxs = { id: "cxs", runtime: "codex" as const, home: join(dir, "homes", "cxs") };
    await logins.start(cxs, "zh");
    await until("cxs", (j) => j.state === "needs_approval", "needs_approval");
    assert.equal(await logins.openPage("cxs", "zh"), "browser:T3");
    assert.equal(b.tabs.get("T3"), "https://auth.openai.com/codex/device");
    await approved.approve();
    await until("cxs", (j) => j.state === "done", "done");
    assert.equal(b.tabs.size, 0);
  } finally {
    await logins.close();
  }
});

test("device codes and escapes are read", () => {
  assert.equal(deviceCode("enter\n   ABCD-12345\n"), "ABCD-12345");
  assert.equal(deviceCode("a one-time code"), null);
  assert.equal(stripAnsi("\u001b[94mhttps://x\u001b[0m"), "https://x");
});

test("the machine's own logins are read from the machine's own homes", async () => {
  const m = machine({
    // Only answers for the machine's own home: no CLAUDE_CONFIG_DIR may reach it.
    claude: `[ -n "$CLAUDE_CONFIG_DIR" ] && exit 3; echo '{"loggedIn":true,"authMethod":"claude.ai","email":"a@x.com","subscriptionType":"max"}'`,
    codex: `${sameAs("CODEX_HOME", ".codex")} || exit 3; echo "Logged in using ChatGPT"`,
  });
  mkdirSync(join(m.home, ".codex"));
  mkdirSync(join(m.home, ".claude"));
  writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "at", expiresAt: Date.now() + 3_600_000 } }));
  writeFileSync(join(m.home, ".codex/auth.json"), JSON.stringify({ tokens: { id_token: idToken({ email: "b@x.com", "https://api.openai.com/auth": { chatgpt_plan_type: "plus" } }) } }));
  const logins = new MachineLogins({ ...m.env, CLAUDE_CONFIG_DIR: "/elsewhere" }, async (runtime) => ({ state: "ok", detail: runtime === "claude" ? "Claude" : "Codex" }), () => "zh");
  let heard = 0;
  logins.changes(() => heard++);
  await logins.refresh();
  await logins.refresh();
  assert.equal(heard, 1, "the pages hear of the first reading, and not of one that says the same");
  const got = logins.get();
  assert.equal(got[0]!.text, "Claude Code 已登录 a@x.com（Max）");
  assert.deepEqual([got[0]!.usable, got[0]!.quota.detail], [true, "Claude"]);
  assert.deepEqual([got[1]!.email, got[1]!.plan, got[1]!.text], ["b@x.com", "plus", "Codex 已登录 b@x.com（Plus）"]);
});

test("the machine's Claude login distinguishes Ultra from Max using its tier metadata", async () => {
  const m = machine({ claude: `echo '{"loggedIn":true,"subscriptionType":"max"}'` });
  mkdirSync(join(m.home, ".claude"));
  const credentials = (tier: string) => writeFileSync(join(m.home, ".claude/.credentials.json"), JSON.stringify({ claudeAiOauth: { accessToken: "at", expiresAt: Date.now() + 3_600_000, subscriptionType: "max", rateLimitTier: tier } }));
  const logins = new MachineLogins(m.env, undefined, () => "zh");
  credentials("default_claude_max_20x");
  await logins.refresh();
  assert.equal(logins.get()[0]!.plan, "ultra");
  credentials("default_claude_max_5x");
  await logins.refresh();
  assert.equal(logins.get()[0]!.plan, "max");
});

test("signed out, not installed and keychain only are said as such", async () => {
  let m = machine({ claude: `echo '{"loggedIn":false}'; exit 1` });
  let logins = new MachineLogins(m.env, undefined, () => "zh");
  await logins.refresh();
  let got = logins.get();
  assert.deepEqual([got[0]!.installed, got[0]!.loggedIn, got[0]!.text], [true, false, "Claude Code 未登录"]);
  assert.deepEqual([got[1]!.installed, got[1]!.text], [false, "未安装 Codex"]);
  m = machine({ claude: `echo '{"loggedIn":true,"email":"a@x.com","subscriptionType":"pro"}'`, codex: `echo "Logged in using ChatGPT"` });
  logins = new MachineLogins(m.env, undefined, () => "zh");
  await logins.refresh();
  got = logins.get();
  assert.deepEqual([got[0]!.usable, got[0]!.text], [false, "Claude Code 已登录 a@x.com（Pro），登录信息在钥匙串中，station 无法读取"]);
  assert.deepEqual([got[1]!.usable, got[1]!.text], [false, "Codex 已登录，登录信息保存在钥匙串中"]);
});

test("a machine profile's codex home links the machine's auth.json", async () => {
  const m = machine();
  const profile = join(m.home, "profile");
  await linkCodexAuthSoon(profile, m.env);
  assert.equal(readlinkSync(join(profile, "auth.json")), join(m.home, ".codex/auth.json"));
  unlinkSync(join(profile, "auth.json"));
  writeFileSync(join(profile, "auth.json"), "{}");
  await linkCodexAuthSoon(profile, m.env);
  assert.ok(lstatSync(join(profile, "auth.json")).isSymbolicLink());
});

test("an unexecutable claude stub does not crash MachineLogins or LoginManager", async () => {
  const m = machine();
  const stubText = 'echo "Error: claude native binary not installed." >&2\nexit 1\n';
  let claudePath: string;
  if (WINDOWS) {
    const stubBin = join(m.bin, "node_modules", "@anthropic-ai", "claude-code", "bin");
    mkdirSync(stubBin, { recursive: true });
    writeFileSync(join(stubBin, "claude.exe"), stubText);
    claudePath = join(m.bin, "claude.cmd");
    writeFileSync(claudePath, '@ECHO off\r\n"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe" %*\r\n');
  } else {
    claudePath = join(m.bin, "claude");
    writeFileSync(claudePath, stubText);
    chmodSync(claudePath, 0o755);
  }
  const unhandled: unknown[] = [];
  const onUnhandled = (reason: unknown) => unhandled.push(reason);
  process.on("unhandledRejection", onUnhandled);
  try {
    const logins = new MachineLogins(m.env, undefined, () => "zh");
    const done = upon((wake) => logins.changes(wake), () => {
      const got = logins.get();
      return got.length > 0 ? got : undefined;
    }, "machine logins read");
    // Triggers the background refresh from get() (where an uncaught sync execFile throw crashed Node).
    assert.deepEqual(logins.get(), []);
    const got = await done;
    assert.deepEqual([got[0]!.runtime, got[0]!.installed, got[0]!.loggedIn, got[0]!.text], ["claude", true, false, "无法读取 Claude Code 的登录信息"]);
    assert.deepEqual(unhandled, []);

    const dir = temp("login-unexec");
    const mgr = new LoginManager(dir, { claude: claudePath, codex: "x" });
    try {
      const waitFailed = upon((wake) => mgr.changes(wake), () => (mgr.get("sub")?.state === "failed" ? mgr.get("sub") : undefined), "stub login failed");
      const startedJob = await mgr.start({ id: "sub", runtime: "claude", home: join(dir, "homes", "sub") }, "zh");
      // macOS/Windows fail spawn synchronously; Linux execvp falls back to /bin/sh and exits 1.
      const failed = startedJob.state === "failed" ? startedJob : await waitFailed;
      assert.equal(failed.state, "failed");
      assert.ok(failed.error!.startsWith("无法运行登录命令") || failed.error!.includes("claude native binary not installed"), failed.error!);
      assert.equal(mgr.get("sub")?.state, "failed");
    } finally {
      await mgr.close();
    }

    // A synchronous spawn throw (on every OS, including Linux) fails the login cleanly.
    const syncFail = new LoginManager(dir, { claude: join(dir, "bad\0claude"), codex: "x" });
    try {
      const failed = await syncFail.start({ id: "sub2", runtime: "claude", home: join(dir, "homes", "sub2") }, "zh");
      assert.equal(failed.state, "failed");
      assert.ok(failed.error!.startsWith("无法运行登录命令"), failed.error!);
      assert.equal(syncFail.get("sub2")?.state, "failed");
    } finally {
      await syncFail.close();
    }
  } finally {
    process.off("unhandledRejection", onUnhandled);
  }
});
