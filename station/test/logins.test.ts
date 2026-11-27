// The station's logins to command-line tools (src/logins/): what a login command's output and
// page say, and logins run for real with stand-in login commands in a temp HOME (shell and Node scripts in a pseudo-
// terminal, as the station runs them), the browser's callback relayed to a loopback port the stand-in listens on (only
// [::1], only 127.0.0.1, a form posted), and refused when it is not the one it waits for. Time is a TestClock: what waits
// on output going quiet waits for the test to move it. Every command is ended and every server closed before a test
// ends.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { type Again, Logins, type Login, Refused, slackPage } from "../src/logins/index.ts";
import type { Callback } from "../src/logins/relay.ts";
import { asksEnter, commandWords, deviceCodeIn, deviceUrls, loopbackOf, plainText, programOf, prompts, saysDone, storesSecret, unwrapped, urlsIn } from "../src/ops/command-output.ts";
import { COLS, LoginRun, QUIET_MS, STALL_MS, TIMEOUT_MS } from "../src/logins/run.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { routes } from "../src/api/routes/logins.ts";
import { act, againNotice, endedNotice, loginTools, promptNotice, screenFor } from "../src/logins/tool.ts";
import { WINDOWS, platform } from "../src/platform/index.ts";
import { approval, fakeBrowser, script, temp, upon } from "./accounts-fakes.ts";
import type { LoginPages } from "../src/logins/pages.ts";
import { given, settle, testClock } from "./hub-fakes.ts";
import { holding } from "../src/updates/holds.ts";

type Json = any;

// ── what output and pages say ──

test("pages, loopback callbacks and device codes are read as the CLIs say them", () => {
  assert.equal(plainText("\u001b]11;?\u001b\\\u001b[0;1;92m? \u001b[0mAuthenticate\r\nok\rnext"), "? Authenticate\nok\nnext");
  assert.equal(plainText("a\r\r\nb\r\r\rc"), "a\nb\nc");
  assert.deepEqual(urlsIn("Login at:\nhttps://www.npmjs.com/login?next=/login/cli/abc.\nPress ENTER (see https://x.io/a))"), ["https://www.npmjs.com/login?next=/login/cli/abc", "https://x.io/a"]);
  // gcloud: localhost, a port, the root path; its state.
  const g = loopbackOf("https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=x&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&scope=openid&state=Ab1&code_challenge=c");
  assert.deepEqual(g, { host: "localhost", port: 8085, path: "/", state: "Ab1", post: false });
  // codex and aws: 127.0.0.1 with a path; Claude Code: [::1] is said as localhost; az: a form posted to the root.
  assert.deepEqual(loopbackOf("https://auth.openai.com/oauth/authorize?redirect_uri=http://127.0.0.1:1455/auth/callback&state=s"), { host: "127.0.0.1", port: 1455, path: "/auth/callback", state: "s", post: false });
  assert.deepEqual(loopbackOf("https://login.microsoftonline.com/x/oauth2/v2.0/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A41234&response_mode=form_post&state=q"), { host: "localhost", port: 41234, path: "/", state: "q", post: true });
  assert.deepEqual(loopbackOf("https://x.com/a?redirect_uri=http://[::1]:9/cb&state=z")?.host, "[::1]");
  // One level inside another page's parameter (a sign-in page handing on).
  assert.equal(loopbackOf(`https://sso.example.com/login?next=${encodeURIComponent("https://idp.example.com/authorize?redirect_uri=http://localhost:9005&state=7")}`)?.port, 9005);
  // Not a loopback: another host, no port, https.
  for (const u of ["https://x.com/a?redirect_uri=https://sdk.cloud.google.com/authcode.html", "https://x.com/a?redirect_uri=http://localhost/cb", "https://x.com/a?redirect_uri=http://example.com:80/cb", "not a url"]) assert.equal(loopbackOf(u), null, u);
  // Device codes as each tool says them; a described pattern's group first.
  assert.equal(deviceCodeIn("! First copy your one-time code: 1A2B-C3D4\nPress Enter to open https://github.com/login/device"), "1A2B-C3D4");
  assert.equal(deviceCodeIn("Your one-time device confirmation code is: WXYZ-1234"), "WXYZ-1234");
  assert.equal(deviceCodeIn("open the page https://login.microsoft.com/device and enter the code GQGFJ2QXM to authenticate."), "GQGFJ2QXM");
  assert.equal(deviceCodeIn("Visit https://vercel.com/oauth/device?user_code=ABCD-EFGH"), "ABCD-EFGH");
  assert.equal(deviceCodeIn("To finish, open https://login.example.org/activate and enter code: WDJB-MJHT"), "WDJB-MJHT");
  assert.equal(deviceCodeIn("Then enter the code:\n\nKXQB-RMTD\n"), "KXQB-RMTD");
  // Wrangler's (4.x, --device): eight letters and digits of both cases, on a line of its own under "enter the code:",
  // and in the page it opens (?user_code=); the case kept.
  const wrangler = "Attempting to login via OAuth Device Authorization Grant...\nTo authorize Wrangler, please visit:\n\n  https://dash.cloudflare.com/oauth2/device\n\nand enter the code:\n\n  vFA9uVPF\n\nYou have 3 minutes to approve this request.\n";
  assert.equal(deviceCodeIn(`${wrangler}\nOpening a link in your default browser: https://dash.cloudflare.com/oauth2/device?user_code=vFA9uVPF\n`), "vFA9uVPF");
  assert.equal(deviceCodeIn(wrangler), "vFA9uVPF", "--no-browser: only the line under it");
  assert.equal(deviceCodeIn(wrangler.replace("vFA9uVPF", "kRtPmWzQ")), "kRtPmWzQ", "letters alone, of both cases");
  assert.equal(deviceCodeIn("To authorize Wrangler, please visit the page.", ["https://dash.cloudflare.com/oauth2/device?user_code=vFA9uVPF"]), "vFA9uVPF", "from the page it opened alone");
  assert.equal(deviceCodeIn("Visit https://x.example/device?user_code=ab12CD34&state=Zz9"), "ab12CD34");
  assert.equal(deviceCodeIn("then enter the code vFA9uVPF there"), "vFA9uVPF");
  assert.equal(deviceCodeIn("Your code: kRtPmWzQ"), "kRtPmWzQ");
  // Not a code: Devin's masked field, words after "code", a prompt with nothing after it.
  assert.equal(deviceCodeIn("Open this page to sign in to Devin:\n https://app.devin.ai/auth/cli?x=1\n Code:\n ❭ ••••"), null);
  assert.equal(deviceCodeIn("copy the code from GitHub and OpenAI"), null);
  assert.equal(deviceCodeIn("and enter the code:\n\n  Continue\n"), null);
  assert.equal(deviceCodeIn("Once finished, enter the verification code provided in your browser: "), null);
  assert.equal(deviceCodeIn("Press ENTER to open in the browser..."), null);
  assert.equal(deviceCodeIn("Authenticate Git with your GitHub credentials? (Y/n)"), null);
  assert.deepEqual(deviceUrls(["https://vercel.com/oauth/device?user_code=ABCD-EFGH"], "ABCD-EFGH"), { url: "https://vercel.com/oauth/device?user_code=ABCD-EFGH", codeUrl: "https://vercel.com/oauth/device?user_code=ABCD-EFGH" });
  assert.deepEqual(deviceUrls(["https://docs.github.com/x", "https://github.com/login/device"], "AB12-CD34"), { url: "https://github.com/login/device", codeUrl: null });
  // Only Enter to open a page is pressed for the person; a question is theirs.
  assert.ok(asksEnter("Press Enter to open https://github.com/login/device in your browser... "));
  assert.ok(asksEnter("Press ENTER to open in the browser..."));
  assert.ok(asksEnter("Press ENTER to open your browser or submit your device code here: https://login.docker.com/activate"));
  assert.ok(!asksEnter("? Authenticate Git with your GitHub credentials? (Y/n) "));
  assert.ok(!asksEnter("Press Enter to continue"));
  // What says the person's step is over, and what keeps a secret where the OS may ask.
  for (const done of ["✓ Authentication complete.", "Logged in as octocat", "You are now logged in as a@x.com.", "Successfully authenticated", "Authenticated as octocat"]) assert.ok(saysDone(done), done);
  for (const not of ["Opening github.com/login/device in your browser.", "Waiting for the browser", "! First copy your one-time code: 1A2B-C3D4", "✓ Opened"]) assert.ok(!saysDone(not), not);
  for (const name of ["git-credential-osxkeychain", "/opt/homebrew/libexec/git-core/git-credential-osxkeychain", "pinentry-mac", "ssh-askpass", "secret-tool"]) assert.ok(storesSecret(name), name);
  for (const name of ["gh", "git", "python3", "sh", "script"]) assert.ok(!storesSecret(name), name);
  assert.ok(prompts("? Authenticate Git with your GitHub credentials? (Y/n) "));
  assert.deepEqual(commandWords(`vercel login --scope "my team" 'a b' c\\ d`), ["vercel", "login", "--scope", "my team", "a b", "c d"]);
  assert.equal(commandWords(`gh "open`), null);
  assert.deepEqual(commandWords("  "), []);
});

/// Devin's sign-in page (Devin CLI 3000.11.92, `devin auth login --force-manual-token-flow`): longer than the terminal is
/// wide, its PKCE challenge with a run of capitals and digits in it that reads like a code.
const DEVIN_PAGE = "https://app.devin.ai/auth/cli/continue?state=Zr8wq1VbN0cT5yHk2LmP9sXa4Jd7Ue0RtWo6Gi3Ny5Bf1Mh8Kl2Sp9Qc&prompt=select_account&code_challenge=xQ2-K9ZTRW4P_vb7Hq0nLm3cYt8sWe1aD5fGj6kU4rI&code_challenge_method=S256&cli_pkce_marker=1";

test("a login's program by its name, past env, its variables and what only runs it; a link broken at the terminal's width put together; no device code read from a page's parameters", () => {
  assert.equal(programOf(["env", "HOME=/x/home", "XDG_DATA_HOME=/x/home/.local/share", "XDG_CONFIG_HOME=/x/home/.config", "/x/bin/devin", "auth", "login", "--force-manual-token-flow"]), "devin");
  assert.equal(programOf(["GH_HOST=github.com", "gh", "auth", "login"]), "gh");
  assert.equal(programOf(["env", "-i", "-u", "TOKEN", "A=b", "gcloud", "auth", "login"]), "gcloud");
  assert.equal(programOf(["sudo", "-u", "bob", "-E", "/usr/local/bin/az", "login"]), "az");
  assert.equal(programOf(["npx", "-y", "vercel@latest", "login"]), "vercel");
  assert.equal(programOf(["pnpm", "dlx", "@azure/static-web-apps-cli@2", "login"]), "static-web-apps-cli");
  assert.equal(programOf(["uvx", "--from", "azure-cli", "az", "login"]), "az");
  assert.equal(programOf(["pnpm", "login"]), "pnpm");
  assert.equal(programOf(["env"]), "env");
  // Broken at 200 columns by the program itself (no box, so the line is as wide as a 200-column terminal): put together
  // again, read at that width or at the login terminal's.
  const line = `Visit ${DEVIN_PAGE} to sign in, then copy the code and paste it below.`;
  assert.ok(DEVIN_PAGE.length > 200);
  const broken = `${line.slice(0, 200)}\n${line.slice(200)}\n\n Code:\n ❭ ••••`;
  assert.deepEqual(urlsIn(broken), [DEVIN_PAGE.slice(0, 200 - "Visit ".length)], "as it is said, the link ends where the line does");
  for (const cols of [200, COLS]) {
    assert.deepEqual(urlsIn(unwrapped(broken, cols)), [DEVIN_PAGE], `${cols}`);
    assert.ok(unwrapped(broken, cols).endsWith(`${DEVIN_PAGE} to sign in, then copy the code and paste it below.\n\n Code:\n ❭ ••••`), `${cols}`);
  }
  // Over three lines; a short line ending in a link is left as it is.
  const long = `https://x.example/${"a".repeat(400)}`;
  assert.deepEqual(urlsIn(unwrapped(`${long.slice(0, 200)}\n${long.slice(200, 400)}\n${long.slice(400)}\nnext`, 200)), [long]);
  // Longer than the login terminal is wide: broken at its width, put together.
  const longer = `https://x.example/a?b=${"c".repeat(2 * COLS)}`;
  assert.deepEqual(urlsIn(unwrapped(`${longer.slice(0, COLS)}\n${longer.slice(COLS, 2 * COLS)}\n${longer.slice(2 * COLS)}\nnext`, COLS)), [longer]);
  assert.equal(unwrapped("open https://github.com/login/device\nand enter the code", COLS), "open https://github.com/login/device\nand enter the code");
  assert.equal(unwrapped("open https://github.com/login/device\nand/enter=x", COLS), "open https://github.com/login/device\nand/enter=x", "a short link goes on with nothing");
  // A PKCE challenge's capitals are no device code.
  assert.equal(deviceCodeIn(`${line}\n\n Code:`), null);
  assert.equal(deviceCodeIn("open https://login.microsoft.com/device?x=ABCD-1234 and enter the code GQGFJ2QXM"), "GQGFJ2QXM");
});

/// A Keycloak sign-in page of 330 characters (scopes, state, a PKCE challenge), and one of 315 whose last line comes
/// to three characters broken at 80 columns.
const KEYCLOAK_PAGE = "https://sso.acme-corp.example/realms/engineering/protocol/openid-connect/auth?client_id=acme-cli&redirect_uri=https%3A%2F%2Fsso.acme-corp.example%2Fcli%2Fdone&response_type=code&scope=openid+profile+email&state=Hq3Vt8Lm2Xw9Rz4Nc7Bp1Fy6Dj5Gk0Tsa&code_challenge=K7xQ2mZpL9vR4tY8wB3nC6hJ1fD5gS0aE2iU7oP4kM9&code_challenge_method=S256";
const KEYCLOAK_SHORTER = KEYCLOAK_PAGE.replace("Hq3Vt8Lm2Xw9Rz4", "");
/// Longer than the login terminal is wide.
const KEYCLOAK_LONGER = KEYCLOAK_PAGE.replace("state=", `state=${"Zq9".repeat(250)}`);
/// A link broken by its program every `width` columns, each line indented.
const brokenAt = (url: string, width: number, indent = "") => {
  const lines: string[] = [];
  for (let i = 0; i < url.length; i += width - indent.length) lines.push(indent + url.slice(i, i + width - indent.length));
  return lines;
};

test("a long sign-in page broken by its program at 200 or 80 columns is put together; a code, a rule, a prompt, a second link or a sentence after a link is not", () => {
  assert.equal(KEYCLOAK_PAGE.length, 330);
  assert.equal(KEYCLOAK_SHORTER.length, 315);
  assert.ok(KEYCLOAK_LONGER.length > COLS);
  // At 200 columns, the line's end said after the link.
  const line = `Visit ${KEYCLOAK_PAGE} to sign in, then paste the code below.`;
  const at200 = `${line.slice(0, 200)}\n${line.slice(200)}\n\nCode:`;
  for (const cols of [200, COLS]) assert.deepEqual(urlsIn(unwrapped(at200, cols)), [KEYCLOAK_PAGE], `${cols}`);
  // At 80 columns, indented: five lines, the last a short end (S256's 256 alone, for the shorter page).
  for (const page of [KEYCLOAK_PAGE, KEYCLOAK_SHORTER]) {
    const lines = brokenAt(page, 80, "  ");
    assert.equal(lines.length, 5);
    const said = `Open this page in your browser:\n${lines.join("\n")}\n\nEnter the code:`;
    assert.deepEqual(urlsIn(unwrapped(said, COLS)), [page]);
    assert.ok(unwrapped(said, COLS).endsWith(`  ${page}\n\nEnter the code:`));
  }
  assert.equal(brokenAt(KEYCLOAK_SHORTER, 80, "  ").at(-1), "  256");
  // Unbroken, or longer than the terminal is wide and broken at its width.
  assert.deepEqual(urlsIn(unwrapped(`Visit ${KEYCLOAK_PAGE} to sign in.`, COLS)), [KEYCLOAK_PAGE]);
  const longer = `Visit ${KEYCLOAK_LONGER} to sign in.`;
  assert.deepEqual(urlsIn(unwrapped(`${longer.slice(0, COLS)}\n${longer.slice(COLS)}`, COLS)), [KEYCLOAK_LONGER]);
  // What follows a whole link is no more of it.
  for (const next of ["ABCD-1234", "vFA9uVPF", "Code:", "================", "https://github.com/login/device", "Then press Enter to continue.", "(Y/n)"]) {
    const said = `  ${KEYCLOAK_PAGE}\n  ${next}`;
    assert.equal(unwrapped(said, COLS), said, next);
  }
});

// ── logins run for real ──

/// A machine for logins: a temp HOME, a bin/ for the stand-ins, Node on PATH (for the stand-ins written in it), the
/// system's tools; a Logins on a TestClock.
function machine(pages?: LoginPages) {
  const home = temp("logins");
  const bin = join(home, "bin");
  mkdirSync(bin, { recursive: true });
  const env = { HOME: home, PATH: `${bin}:${dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: "en_US.UTF-8" };
  const time = testClock();
  const logins = new Logins({ data: join(home, "data"), env: () => env, clock: time.clock, lang: () => "zh", ...(pages ? { pages } : {}) });
  const changed = (wake: () => void) => logins.changes(wake);
  /// Waits until the login is so (each change looked at).
  const until = (id: string, ok: (l: Login) => boolean, what: string) => upon(changed, () => { const l = logins.get(id); return l && ok(l) ? l : undefined; }, what);
  /// Waits until its screen shows `text` on the cursor's line; then its output has gone quiet (the clock moved on).
  const quietAt = async (id: string, text: string) => {
    await upon((wake) => logins.follow(id, wake), () => {
      let shown = "";
      const stop = logins.follow(id, (s) => (shown = s.rows[s.cursor.y] ?? ""));
      stop();
      return shown.includes(text);
    }, text);
    await settle(5);
    await time.adjust(QUIET_MS);
  };
  const screen = (id: string) => {
    let rows: string[] = [];
    logins.follow(id, (s) => (rows = s.rows))();
    return rows.join("\n");
  };
  /// Waits until its screen shows `text` anywhere; then its output has gone quiet (the clock moved on).
  const quietShowing = async (id: string, text: string) => {
    await upon((wake) => logins.follow(id, wake), () => screen(id).includes(text), text);
    await settle(5);
    await time.adjust(QUIET_MS);
  };
  const by = { by: { email: "a@x.com", name: "张三" }, workspace: "w1" };
  return { home, bin, env, time, logins, until, quietAt, quietShowing, screen, by };
}

// A command's output comes in chunks as its pipe gives them: its answer's echo in one, the page and the code in the next,
// which may come as the first is drawn and its pages read again (43866525344: logins.test.ts's "answered [n]" missing
// from the screen as the device step was told). What it said is read no further than the emulator has drawn it: the
// next chunk given here just after a chunk's draw, before that draw's reading of its pages ends, each round.
test("a login's step, page and code are told only once its screen shows them, its output in chunks", async () => {
  const home = temp("logins-chunks");
  const time = testClock();
  const fibers = new Fibers("logins-chunks", time.clock);
  const chunks = ["n\r\n", "answered [n]\r\n! First copy your one-time code: 1A2B-C3D4\r\nPress Enter to open https://github.com/login/device in your browser... "];
  try {
    for (let round = 0; round < 40; round++) {
      let fed = 1;
      const ahead: string[] = [];
      let run!: LoginRun;
      let allDrawn!: () => void;
      const drawnAll = new Promise<void>((done) => (allDrawn = done));
      const told = new Promise<void>((done) => {
        run = new LoginRun({
          id: `r${round}`, command: ["fakegh", "auth", "login"], env: {}, cwd: home, shims: home,
          opened: join(home, `r${round}.opened`), fibers, lang: "en",
          changed: () => {
            if (run.step !== "device") return;
            const shown = run.screen().rows.join("\n");
            if (!shown.includes("answered [n]") || !shown.includes("1A2B-C3D4")) ahead.push(shown);
            done();
          },
          // (the next chunk as this one is drawn: before its draw's reading of the pages it opened has ended)
          drawn: () => {
            if (fed < chunks.length) {
              const next = chunks[fed++]!;
              queueMicrotask(() => run.output(next));
            } else if (run.screen().rows.join("\n").includes("Press Enter")) allDrawn();
          },
        });
      });
      run.output(chunks[0]!);
      // (the emulator draws what it is given as its own timer comes round: once it drew all of it, what that set going,
      // its pages read again, is what is waited for)
      await drawnAll;
      await given(told, `round ${round}: the device step told`);
      assert.deepEqual(ahead, [], `round ${round}: told before its screen showed it`);
      assert.deepEqual([run.code, run.url], ["1A2B-C3D4", "https://github.com/login/device"]);
      run.cancel();
    }
  } finally {
    await fibers.close();
  }
});

const skipped = WINDOWS && "logins run in a pseudo-terminal: script is Unix's";

test("a device-code login, as any tool runs it: its question left to the person, Enter pressed only to open its page, the page and the code told", { skip: skipped }, async () => {
  const m = machine();
  const approved = approval(m.home);
  script(join(m.bin, "fakegh"), `#!/bin/sh
printf '? Authenticate Git with your GitHub credentials? (Y/n) '
read answer
echo "answered [$answer]"
echo "! First copy your one-time code: 1A2B-C3D4"
printf "Press Enter to open https://github.com/login/device in your browser... "
read go
"$BROWSER" https://github.com/login/device
echo "Waiting for the browser"
read ok < '${approved.path}'
echo "Logged in as octocat"
`);
  try {
    const started = await m.logins.start("fakegh auth login", m.by);
    assert.deepEqual([started.name, started.command, started.by], ["fakegh", ["fakegh", "auth", "login"], m.by.by]);
    // The same command under way is given rather than another.
    assert.equal((await m.logins.start(["fakegh", "auth", "login"], m.by)).id, started.id);
    // Its question is the person's: it waits for them, in the terminal.
    await m.quietAt(started.id, "Authenticate Git");
    const asks = await m.until(started.id, (l) => l.waiting, "waiting");
    assert.deepEqual([asks.state, asks.step], ["input", "terminal"]);
    assert.ok(!m.screen(started.id).includes("answered"), "not answered for them");
    m.logins.input(started.id, { text: "n" });
    m.logins.input(started.id, { key: "Enter" });
    const device = await m.until(started.id, (l) => l.step === "device" && l.url !== undefined, "device");
    assert.equal(device.code, "1A2B-C3D4");
    assert.ok(m.screen(started.id).includes("answered [n]"));
    await m.quietAt(started.id, "Press Enter to open");
    // Enter pressed: the page goes to the station's BROWSER, not a browser on this machine.
    await upon((w) => m.logins.follow(started.id, w), () => m.screen(started.id).includes("Waiting for the browser"), "opened");
    const opened = m.logins.get(started.id)!;
    assert.deepEqual([opened.state, opened.step, opened.url, opened.domain, opened.code, opened.waiting], ["code", "device", "https://github.com/login/device", "github.com", "1A2B-C3D4", false]);
    await approved.approve();
    await m.until(started.id, (l) => l.state === "done", "done");
    // A read-only member sees how it stands, not its page or code.
    const limited = Logins.limited(opened);
    assert.deepEqual([limited.url, limited.code, limited.domain, limited.state], [undefined, undefined, "github.com", "code"]);
  } finally {
    await m.logins.close();
  }
});

test("a login whose page gives a code to paste back (gcloud --no-launch-browser): its agent says so, not the station; the person's to enter from the card, typed with Enter", { skip: skipped }, async () => {
  const m = machine();
  const page = "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1.apps.googleusercontent.com&redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html&state=s1";
  script(join(m.bin, "fakegcloud"), `#!/bin/sh
echo "Go to the following link in your browser, and complete the sign-in prompts:"
echo
echo "    ${page}"
echo
printf "Once finished, enter the verification code provided in your browser: "
read code
echo "got [$code]"
echo "You are now logged in as [a@x.com]."
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  try {
    // Waiting on its prompt is told in the answer of its agent's call, the call waiting on it then (no notice besides).
    const heard: boolean[] = [];
    const stop = m.logins.changes(({ login }) => {
      if (m.logins.get(login)?.waiting) heard.push(m.logins.heard(login));
    });
    const starting = tool!.run("chat:c-1", { command: "fakegcloud auth login --no-launch-browser" });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    await m.quietAt(id, "enter the verification code");
    const first = await starting;
    stop();
    assert.deepEqual(heard, [true]);
    assert.ok(!m.logins.heard(id));
    // The station does not decide it waits for the page's code: its agent, from the screen.
    const asks = m.logins.get(id)!;
    assert.deepEqual([asks.step, asks.url, asks.waiting, asks.paste], ["open", page, true, undefined]);
    assert.match(first, /unless it asks for what the page it gave hands out \(a code to paste back\): then do not answer it; login \{id, paste: true\}/);
    // Not before its agent says so: nothing is to be entered on the card yet.
    assert.throws(() => m.logins.answer(id, "4/abc"), /does not wait for a code/);
    const told = await tool!.run("chat:c-1", { id, paste: true });
    assert.equal(m.logins.get(id)!.paste, true);
    assert.match(told, /enter what it gives \(a code\) in the login card's field/);
    assert.match(told, /do not answer its prompt yourself/);
    assert.throws(() => m.logins.answer(id, "  "), /text/);
    assert.throws(() => m.logins.answer(id, "a\nb"), /one line/);
    const answered = m.logins.answer(id, " 4/0AXlq-code ", { email: "b@x.com", name: "李四" });
    assert.deepEqual([answered.doneBy?.name, answered.paste, answered.state], ["李四", true, "verifying"], "entered: the field stays, what was entered checked in place");
    assert.throws(() => m.logins.answer(id, "4/again"), /being checked/);
    await m.until(id, (l) => l.state === "done", "done");
    assert.ok(m.screen(id).includes("got [4/0AXlq-code]"), m.screen(id));
  } finally {
    await m.logins.close();
  }
});

test("a loopback login with its code-pasting one (byCode): a person who cannot take its callback switches from the card; the new one's field given as its page shows, the card following it, its agent told, the old one cancelled without its ended notice", { skip: skipped }, async () => {
  const m = machine();
  const back = "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1.apps.googleusercontent.com&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&state=s1";
  const page = "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1.apps.googleusercontent.com&redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html&state=s2";
  script(join(m.bin, "fakegcloud"), `#!/bin/sh
if [ "$3" = "--no-launch-browser" ]; then
  echo "Go to the following link in your browser, and complete the sign-in prompts:"
  echo
  echo "    ${page}"
  echo
  printf "Once finished, enter the verification code provided in your browser: "
  read code
  echo "got [$code]"
  exit 0
fi
echo "Your browser has been opened to visit:"
echo
echo "    ${back}"
echo
read forever
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  const agains: Again[] = [];
  const ended: Login[] = [];
  const stops = [m.logins.onAgain((a) => agains.push(a)), m.logins.onEnded((l) => ended.push(l))];
  try {
    // Without one: nothing to switch to.
    const plain = await m.logins.start("fakegcloud auth login --plain", m.by);
    await m.until(plain.id, (l) => l.step === "loopback", "loopback");
    assert.equal(m.logins.get(plain.id)!.byCode, undefined);
    await assert.rejects(m.logins.toCode(plain.id, { email: "b@x.com", name: "李四" }), (e: unknown) => e instanceof Refused && e.status === 409);
    m.logins.cancel(plain.id);
    ended.length = 0;
    const starting = tool!.run("chat:c-1", { command: "fakegcloud auth login", byCode: "fakegcloud auth login --no-launch-browser" });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins().find((l) => l.endedAt === undefined)?.id, "started");
    await m.until(id, (l) => l.step === "loopback", "loopback");
    // (its agent's call waits for the command to go quiet: the clock moved on)
    await settle(5);
    await m.time.adjust(QUIET_MS);
    await starting;
    assert.equal(m.logins.get(id)!.byCode, true, "offered while its browser step waits");
    const switched = await m.logins.toCode(id, { email: "b@x.com", name: "李四" });
    assert.notEqual(switched.id, id);
    assert.equal(switched.from, id);
    const was = m.logins.get(id)!;
    assert.deepEqual([was.state, was.again, was.byCode, was.doneBy?.name], ["cancelled", switched.id, undefined, "李四"]);
    // Asked again (a second press, another device): the one it switched to.
    assert.equal((await m.logins.toCode(id, { email: "c@x.com", name: "王五" })).id, switched.id);
    assert.deepEqual(agains.map((a) => [a.from.id, a.login.id, a.byCode, a.by.name]), [[id, switched.id, true, "李四"]]);
    assert.match(againNotice(agains[0]!.from, agains[0]!.login, agains[0]!.by, null, true), /switched the login on this station fakegcloud auth login \(login [^)]+\) to its code-pasting login/);
    // Its field given once its page shows, with no agent's word: the person enters the code there.
    const pasting = await m.until(switched.id, (l) => l.paste === true, "its field");
    assert.deepEqual([pasting.step, pasting.url], ["open", page]);
    m.logins.answer(switched.id, "4/0AX-code", { email: "b@x.com", name: "李四" });
    await m.until(switched.id, (l) => l.state === "done", "done");
    assert.ok(m.screen(switched.id).includes("got [4/0AX-code]"), m.screen(switched.id));
    assert.deepEqual(ended.map((l) => [l.id, l.state, l.again]), [[id, "cancelled", switched.id], [switched.id, "done", undefined]]);
  } finally {
    stops.forEach((s) => s());
    await m.logins.close();
  }
});

test("Devin's sign-in (env and its variables before it, a page longer than the terminal is wide, then a masked field read key by key): named devin, the whole page given, and a field on the card once its agent says so", { skip: skipped }, async () => {
  const m = machine();
  // As Devin draws it: the line broken at the terminal's width by the program, the code read in raw mode with no echo,
  // a dot drawn for each key. Raw before the field is drawn, as a program reading keys is: switched after, the code
  // typed once the field showed could reach the terminal still in line mode, its Enter turned into a newline the field
  // never ends on (a station run waited minutes on it).
  script(join(m.bin, "fakedevin"), `#!/usr/bin/env node
const out = (s) => process.stdout.write(s);
const line = ${JSON.stringify(`Visit ${DEVIN_PAGE} to sign in, then copy the code and paste it below.`)};
const cols = Number(process.env.COLUMNS) || 80;
process.stdin.setRawMode(true);
out(line.slice(0, cols) + "\\r\\n" + line.slice(cols) + "\\r\\n\\r\\n Code:\\r\\n ❭ " + "•".repeat(42) + "\\r\\n ↵ submit · esc cancel\\u001b[1A\\r\\u001b[3C");
let code = "";
process.stdin.on("data", (d) => {
  for (const c of d.toString()) {
    if (c === "\\r") {
      out("\\r\\n\\r\\n\\r\\ngot [" + code + "] for " + process.env.XDG_CONFIG_HOME + "\\r\\n");
      process.exit(0);
    }
    code += c;
    out("•");
  }
});
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  const home = join(m.home, "devin");
  try {
    const command = `env HOME=${home} XDG_DATA_HOME=${home}/.local/share XDG_CONFIG_HOME=${home}/.config ${join(m.bin, "fakedevin")} auth login --force-manual-token-flow`;
    const starting = tool!.run("chat:c-1", { command });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    await m.quietAt(id, "❭");
    const first = await starting;
    const login = m.logins.get(id)!;
    assert.equal(login.name, "fakedevin");
    // The whole page, past the line's end; no code read from its challenge; nothing the station decides it waits for.
    assert.deepEqual([login.step, login.state, login.url, login.code, login.paste], ["open", "browser", DEVIN_PAGE, undefined, undefined]);
    assert.match(first, /if the screen says the page gives a code to paste back here, first login \{id, paste: true\}/);
    assert.ok(first.includes("copy the code and paste it below") && !first.includes("app.devin.ai"), first);
    assert.throws(() => m.logins.answer(id, "abc"), /does not wait for a code/);
    // Its agent says so: the card's field, and what the person enters typed at its masked field with Enter.
    assert.match(await tool!.run("chat:c-1", { id, paste: true }), /in the login card's field/);
    assert.equal(m.logins.get(id)!.paste, true);
    const answered = m.logins.answer(id, "dvn_code-123", { email: "b@x.com", name: "李四" });
    assert.deepEqual([answered.paste, answered.state], [true, "verifying"]);
    await m.until(id, (l) => l.state === "done", "done");
    assert.ok(m.screen(id).includes(`got [dvn_code-123] for ${home}/.config`), m.screen(id));
  } finally {
    await m.logins.close();
  }
});

test("the agent drives the command through its tool: it sees the screen without the page or code, answers the Y/n itself, and is told when the person's step is ready", { skip: skipped }, async () => {
  const m = machine();
  const approved = approval(m.home);
  script(join(m.bin, "fakegh"), `#!/bin/sh
printf '? Authenticate Git with your GitHub credentials? (Y/n) '
read answer
echo "answered [$answer]"
echo "! First copy your one-time code: 1A2B-C3D4"
printf "Press Enter to open https://github.com/login/device in your browser... "
read go
"$BROWSER" https://github.com/login/device
echo "Waiting for the browser"
read ok < '${approved.path}'
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1", chatTitle: "部署" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  try {
    const starting = tool!.run("chat:c-1", { command: "fakegh auth login" });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    await m.quietAt(id, "Authenticate Git");
    const asked = await starting;
    assert.match(asked, /\? Authenticate Git with your GitHub credentials\? \(Y\/n\)/);
    assert.match(asked, /It waits on the prompt above: answer it with login/);
    assert.ok(!asked.includes("card"), "no card yet: nothing is the person's to do");
    // Its default, as the agent takes it: Enter.
    const answering = tool!.run("chat:c-1", { id, key: "enter" });
    await m.quietAt(id, "Press Enter to open");
    await upon((w) => m.logins.follow(id, w), () => m.screen(id).includes("Waiting for the browser"), "opened");
    // Quiet again (its cursor on the line after what it said).
    await settle(5);
    await m.time.adjust(QUIET_MS);
    const ready = await answering;
    assert.ok(m.screen(id).includes("answered []"));
    assert.match(ready, /The person's browser step is ready: chat_post with card \{"type": "login", "login": "/);
    assert.ok(ready.includes("<code>") && ready.includes("<link>"), ready);
    assert.ok(!ready.includes("1A2B-C3D4") && !ready.includes("github.com/login/device"), "neither the code nor the page");
    // the card with a sentence, never the login's link beside it (it only shows its raw address); in Slack and Feishu
    // the link with the card (the chat and Home keep the card, Slack shows its button when it can)
    assert.match(ready, /why, without the link in still\.fail chats \(the card opens the page\); in Slack or Feishu, include the link https:\/\/still\.fail\/w\/w1\/s\/st\/login\/\S+ in the text with that same card; end need_human\./);
    assert.equal(m.logins.get(id)!.chatTitle, "部署");
    await approved.approve();
    await m.until(id, (l) => l.state === "done", "done");
    assert.match(await tool!.run("chat:c-1", { id }), /It finished/);
    await assert.rejects(tool!.run("chat:c-1", { id, key: "f13" }), /key: one of/);
  } finally {
    await m.logins.close();
  }
});

test("a login another station's agent started (its tool's station): told where it runs and the card's station, its own logins only, told as it ends", { skip: skipped }, async () => {
  const m = machine();
  const approved = approval(m.home);
  script(join(m.bin, "fakegh"), `#!/bin/sh
echo "! First copy your one-time code: 1A2B-C3D4"
"$BROWSER" https://github.com/login/device
echo "Waiting for the browser"
read ok < '${approved.path}'
`);
  const here = { station: "b".repeat(64), name: "TestStation" };
  const peer = (station: string) => ({ starter: () => ({ ...m.by, chat: null, chatTitle: "部署", peer: { station, session: "chat:c-a" } }), link: (id: string) => `https://still.fail/w/w1/s/${here.station}/login/${id}`, where: here, mine: (id: string) => m.logins.starterOf(id)?.peer?.station === station });
  // The agent's tool hands a call naming a station to the station transport (logins/module.ts), as it was given.
  const asked: unknown[] = [];
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: () => null, remote: async (station, session, args) => (asked.push({ station, session, args }), "told there") });
  try {
    assert.equal(await tool!.run("chat:c-1", { station: "TestStation", command: "gh auth login" }), "told there");
    assert.deepEqual(asked, [{ station: "TestStation", session: "chat:c-1", args: { station: "TestStation", command: "gh auth login" } }]);
    // On the station it runs on: started for the other station's agent, its chat none here.
    const starting = act(m.logins, { command: "fakegh auth login" }, peer("a".repeat(64)));
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    await upon((w) => m.logins.follow(id, w), () => m.screen(id).includes("Waiting for the browser"), "opened");
    await settle(5);
    await m.time.adjust(QUIET_MS);
    const ready = await starting;
    assert.ok(ready.includes(`card {"type": "login", "login": "${id}", "station": "${here.station}"}`), ready);
    assert.match(ready, /who should log in to what on TestStation and why/);
    assert.match(ready, /"stationName": "TestStation"/);
    assert.equal(m.logins.get(id)!.chat, undefined, "no chat of this station's");
    assert.deepEqual(m.logins.starterOf(id)!.peer, { station: "a".repeat(64), session: "chat:c-a" });
    // Another station acts only on the logins it started.
    await assert.rejects(act(m.logins, { id }, peer("c".repeat(64))), /no login/);
    assert.match(await act(m.logins, { id }, peer("a".repeat(64))), /The person's browser step is ready/);
    assert.match(promptNotice(m.logins, m.logins.get(id)!, null, here), /^The login on TestStation you started/);
    await approved.approve();
    const done = await m.until(id, (l) => l.state === "done", "done");
    assert.match(endedNotice(done, null, here), /^The login on TestStation you started or posted a card for, fakegh auth login/);
  } finally {
    await m.logins.close();
  }
});

test("the screen as the agent reads it: the page and the code hidden, the cursor's line marked, nothing past the last line", () => {
  const login = { code: "1A2B-C3D4" } as Login;
  const rows = ["! First copy your one-time code: 1A2B-C3D4", "Press Enter to open https://github.com/login/device in your browser... ", "", "", ""];
  assert.equal(screenFor({ rows, cursor: { x: 70, y: 1 }, echo: true, live: true }, login), "! First copy your one-time code: <code>\nPress Enter to open <link> in your browser...▏");
  assert.equal(screenFor(null, login), "");
});

test("the screen as the agent reads it: a long page wrapped by the terminal or broken by its program is hidden whole, the cursor's line marked where it is", () => {
  const login = {} as Login;
  const blank = (n: number) => Array.from({ length: n }, () => "");
  // Longer than the terminal is wide: wrapped onto the next row.
  const line = `Visit ${KEYCLOAK_LONGER} to sign in.`;
  const rows = [line.slice(0, COLS), line.slice(COLS), "", "Enter the code: ", ...blank(4)];
  const wrapped = [false, true, ...blank(6).map(() => false)];
  assert.equal(screenFor({ rows, wrapped, cursor: { x: 16, y: 3 }, echo: true, live: true }, login), "Visit <link> to sign in.\n\nEnter the code:▏");
  assert.equal(screenFor({ rows, wrapped, cursor: { x: 3, y: 1 }, echo: true, live: true }, login), "Visit <link> to sign in.▏\n\nEnter the code:", "the cursor on the wrapped row: on its line");
  assert.equal(screenFor({ rows, wrapped, cursor: { x: 3, y: 0 }, echo: true, live: true }, login), "Visit <link> to sign in.▏\n\nEnter the code:");
  assert.equal(screenFor({ rows, cursor: { x: 16, y: 3 }, echo: true, live: true }, login), "Visit <link> to sign in.\n\nEnter the code:▏", "older screens without the marks: the link broken at the terminal's width");
  // Broken by its program at 200 and at 80 columns: no part of the page left to read.
  const said = `Visit ${KEYCLOAK_PAGE} to sign in, then paste the code below.`;
  const at200 = [said.slice(0, 200), said.slice(200), "", "Enter the code: "];
  assert.equal(screenFor({ rows: at200, wrapped: at200.map(() => false), cursor: { x: 16, y: 3 }, echo: true, live: true }, login), "Visit <link> to sign in, then paste the code below.\n\nEnter the code:▏");
  for (const page of [KEYCLOAK_PAGE, KEYCLOAK_SHORTER]) {
    const at80 = ["Open this page in your browser:", ...brokenAt(page, 80, "  "), "", "Enter the code: ", ...blank(3)];
    const shown = screenFor({ rows: at80, cursor: { x: 16, y: 7 }, echo: true, live: true }, login);
    assert.equal(shown, "Open this page in your browser:\n  <link>\n\nEnter the code:▏");
    assert.equal(screenFor({ rows: at80, cursor: { x: 10, y: 3 }, echo: true, live: true }, login), "Open this page in your browser:\n  <link>▏\n\nEnter the code:", "the cursor on a broken line: on the link's");
  }
});

test("a sign-in page of 330 characters or longer than the terminal is wide, said whole, broken at 200 columns, or wrapped by the terminal: the whole page told, none of it on the agent's screen", { skip: skipped }, async () => {
  for (const [mode, page] of [["plain", KEYCLOAK_PAGE], ["at200", KEYCLOAK_PAGE], ["longer", KEYCLOAK_LONGER]] as const) {
    const m = machine();
    script(join(m.bin, "fakekeycloak"), `#!/usr/bin/env node
const line = ${JSON.stringify(`Visit ${page} to sign in, then paste the code below.`)};
const said = process.argv[2] === "at200" ? line.slice(0, 200) + "\\r\\n" + line.slice(200) : line;
process.stdout.write("Signing in to Acme SSO\\r\\n" + said + "\\r\\n\\r\\nEnter the code: ");
process.stdin.resume();
`);
    const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
    try {
      const starting = tool!.run("chat:c-1", { command: `fakekeycloak ${mode}` });
      const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
      await m.quietAt(id, "Enter the code");
      const told = await starting;
      const login = m.logins.get(id)!;
      assert.deepEqual([login.step, login.url], ["open", page], mode);
      const screen = told.slice(told.indexOf("Screen:"));
      assert.match(screen, /Visit <link> to sign in, then paste the code below\./, mode);
      for (const part of ["state=", "code_challenge", "sso.acme-corp", "S256"]) assert.ok(!screen.includes(part), `${mode}: ${part} in ${screen}`);
    } finally {
      await m.logins.close();
    }
  }
});

test("a tool nobody described: its device code and page read from what it says", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "acme"), `#!/bin/sh\necho "Acme CLI 3.1"\necho "To finish, open https://login.acme.example/activate and enter code: WDJB-MJHT"\necho "(the code lasts 10 minutes)"\nread forever\n`);
  try {
    const login = await m.logins.start("acme login --device", m.by);
    const device = await m.until(login.id, (l) => l.step === "device", "device");
    assert.deepEqual([device.code, device.url, device.domain, device.state], ["WDJB-MJHT", "https://login.acme.example/activate", "login.acme.example", "code"]);
  } finally {
    await m.logins.close();
  }
});

test("Wrangler's device login (a code of both cases on a line of its own, the page opened with it): the code and page told on the card, hidden from its agent", { skip: skipped }, async (t) => {
  const m = machine();
  t.after(() => m.logins.close());
  const page = "https://dash.cloudflare.com/oauth2/device?user_code=vFA9uVPF";
  script(join(m.bin, "wrangler"), `#!/bin/sh
echo "Attempting to login via OAuth Device Authorization Grant..."
echo "To authorize Wrangler, please visit:"
echo
echo "  https://dash.cloudflare.com/oauth2/device"
echo
echo "and enter the code:"
echo
echo "  vFA9uVPF"
echo
echo "You have 3 minutes to approve this request."
echo
echo "Opening a link in your default browser: ${page}"
"$BROWSER" "${page}"
read forever
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  try {
    const starting = tool!.run("chat:c-1", { command: "wrangler login --device" });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    const device = await m.until(id, (l) => l.step === "device" && l.url === page && l.codeUrl === page, "device");
    assert.deepEqual([device.state, device.code, device.domain, device.url, device.codeUrl], ["code", "vFA9uVPF", "dash.cloudflare.com", page, page]);
    await m.quietShowing(id, "Opening a link");
    const told = await starting;
    assert.ok(told.includes("<code>") && told.includes("<link>"), told);
    assert.ok(!told.includes("vFA9uVPF") && !told.includes("dash.cloudflare.com"), told);
  } finally {
    await m.logins.close();
  }
});

test("a login whose code the person pastes (paste on): what looks like a device code said after it leaves the card's field as it is", { skip: skipped }, async (t) => {
  const m = machine();
  t.after(() => m.logins.close());
  const approved = approval(m.home);
  const page = "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=1.apps.googleusercontent.com&redirect_uri=https%3A%2F%2Fsdk.cloud.google.com%2Fauthcode.html&state=s1";
  script(join(m.bin, "fakegcloud"), `#!/bin/sh
echo "Go to the following link in your browser, and complete the sign-in prompts:"
echo
echo "    ${page}"
echo
printf "Once finished, enter the verification code provided in your browser: "
read ok < '${approved.path}'
echo
echo "That code was refused. Enter the code: 4ZQ7PX2KM"
read code
`);
  const [tool] = loginTools({ logins: () => m.logins, starter: () => ({ ...m.by, chat: "chat:c-1" }), link: (_s, id) => `https://still.fail/w/w1/s/st/login/${id}` });
  try {
    const starting = tool!.run("chat:c-1", { command: "fakegcloud auth login --no-launch-browser" });
    const id = await upon((w) => m.logins.changes(w), () => m.logins.logins()[0]?.id, "started");
    await m.quietAt(id, "enter the verification code");
    await starting;
    await tool!.run("chat:c-1", { id, paste: true });
    await approved.approve();
    await m.quietShowing(id, "4ZQ7PX2KM");
    const after = m.logins.get(id)!;
    assert.deepEqual([after.step, after.paste, after.code, after.url], ["open", true, undefined, page]);
  } finally {
    await m.logins.close();
  }
});

test("a login waiting on prompts: its terminal answers the program's queries, its agent types a name, and nothing is typed at a password prompt", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakeprompt"), `#!/usr/bin/env node
const { execFileSync } = require("node:child_process");
const out = (s) => process.stdout.write(s);
// What gh does first: ask the terminal where its cursor is, and wait for the answer.
process.stdin.setRawMode(true);
out("\\u001b]11;?\\u001b\\\\\\u001b[6n");
let buf = "";
const lines = [];
let want = null;
process.stdin.on("data", (d) => {
  buf += d.toString();
  if (want === null) {
    if (!buf.includes("R")) return;
    out("cursor " + JSON.stringify(buf.slice(buf.indexOf("\\u001b["), buf.indexOf("R") + 1)) + "\\r\\n");
    buf = "";
    process.stdin.setRawMode(false);
    want = "user";
    out("Username: ");
    return;
  }
  if (!buf.includes("\\n")) return;
  const line = buf.slice(0, buf.indexOf("\\n")).trim();
  buf = "";
  if (want === "user") {
    lines.push(line);
    want = "password";
    execFileSync("stty", ["-echo"], { stdio: ["inherit", "ignore", "ignore"] });
    out("Password: ");
  } else {
    execFileSync("stty", ["echo"], { stdio: ["inherit", "ignore", "ignore"] });
    out("\\r\\nwelcome " + lines[0] + "\\r\\n");
    process.exit(lines[0] === "alice" && line === "s3cret" ? 0 : 1);
  }
});
`);
  try {
    const login = await m.logins.start("fakeprompt --user", m.by);
    assert.deepEqual(login.command, ["fakeprompt", "--user"]);
    await m.quietAt(login.id, "Username:");
    const waiting = await m.until(login.id, (l) => l.waiting, "waiting");
    assert.deepEqual([waiting.state, waiting.step], ["input", "terminal"]);
    assert.match(m.screen(login.id), /cursor "\\u001b\[\d+;\d+R"/, "the cursor's place was answered");
    let echo: boolean | null = null;
    const stop = m.logins.follow(login.id, (s) => (echo = s.echo));
    assert.equal(echo, true);
    m.logins.input(login.id, { text: "alice" });
    m.logins.input(login.id, { key: "Enter" });
    await m.quietAt(login.id, "Password:");
    await upon((w) => m.logins.follow(login.id, w), () => echo === false, "no echo");
    // A secret is nobody's to type here: refused, nothing sent.
    assert.throws(() => m.logins.input(login.id, { text: "s3cret" }), (e: unknown) => e instanceof Refused && e.status === 409 && /secret/.test(e.message));
    assert.throws(() => m.logins.input(login.id, { key: "Enter" }), (e: unknown) => e instanceof Refused && /secret/.test(e.message));
    assert.ok(m.screen(login.id).trimEnd().endsWith("Password:"), "nothing reached it");
    assert.equal(m.logins.get(login.id)!.state, "input");
    stop();
    m.logins.cancel(login.id);
    assert.throws(() => m.logins.input(login.id, { text: "x" }), (e: unknown) => e instanceof Refused && e.status === 409);
  } finally {
    await m.logins.close();
  }
});

/// A stand-in that logs in by a loopback callback, as gcloud, aws, Claude Code and az do: it listens on `host` (only
/// there), names the port in the page it opens (BROWSER), and takes one callback: the right state ends it 0, a wrong one
/// ends it 1 (as most real ones do). `mode` post: the callback is a form posted to its root (az).
const LOOPBACK = `#!/usr/bin/env node
const http = require("node:http");
const { execFileSync } = require("node:child_process");
const [host, mode] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const url = new URL(req.url, "http://x");
    const state = mode === "post" ? new URLSearchParams(body).get("state") : url.searchParams.get("state");
    process.stdout.write("got " + req.method + " " + req.url + " " + body + " host=" + req.headers.host + "\\r\\n");
    if (state !== "s3cret") { res.writeHead(400); res.end("bad state"); server.close(); return process.exit(1); }
    res.writeHead(200, { "content-type": "text/html", "x-fake": "1" });
    res.end("<h1>signed in</h1>", () => server.close(() => process.exit(0)));
  });
});
server.listen(0, host, () => {
  const port = server.address().port;
  const back = "http://localhost:" + port + (mode === "post" ? "" : "/callback");
  const page = "https://accounts.example.com/o/oauth2/auth?client_id=x&redirect_uri=" + encodeURIComponent(back) + "&state=s3cret" + (mode === "post" ? "&response_mode=form_post" : "");
  execFileSync(process.env.BROWSER, [page]);
  process.stdout.write("Your browser has been opened to visit:\\r\\n\\r\\n    " + page.replace("s3cret", "printed") + "\\r\\n");
});
`;

for (const [host, mode] of [["::1", "get"], ["127.0.0.1", "get"], ["127.0.0.1", "post"]] as const) {
  test(`a loopback login listening on ${host} only: its callback (${mode === "post" ? "a form posted" : "GET"}) relayed once, the right one only`, { skip: skipped }, async () => {
    const m = machine();
    script(join(m.bin, "fakeloop"), LOOPBACK);
    try {
      const login = await m.logins.start(["fakeloop", host, mode], m.by);
      const waiting = await m.until(login.id, (l) => l.step === "loopback", "loopback");
      // The page it opened, not the one it printed.
      assert.ok(waiting.url!.includes("state=s3cret"), waiting.url);
      const back = waiting.callback!;
      assert.deepEqual([back.host, back.path, back.state, back.post, waiting.domain, waiting.state], ["localhost", mode === "post" ? "/" : "/callback", "s3cret", mode === "post", "accounts.example.com", "browser"]);
      const form = (state: string) => Buffer.from(`code=c0de&state=${state}`).toString("base64");
      const request = (state: string): Callback =>
        mode === "post"
          ? { method: "POST", path: "/", headers: { host: `localhost:${back.port}`, "content-type": "application/x-www-form-urlencoded" }, body: form(state) }
          : { method: "GET", path: `/callback?code=c0de&state=${state}`, headers: { host: `localhost:${back.port}` } };
      // Not the one it waits for: refused here, never sent (one wrong request ends the command).
      for (const wrong of [request("guess"), { ...request("s3cret"), path: mode === "post" ? "/other" : "/other?state=s3cret" }, { ...request("s3cret"), method: mode === "post" ? "GET" : "POST" }]) {
        await assert.rejects(m.logins.callback(login.id, wrong), (e: unknown) => e instanceof Refused && e.status === 400, JSON.stringify(wrong));
      }
      assert.ok(!m.screen(login.id).includes("got "), "nothing reached the command");
      const answered = await m.logins.callback(login.id, request("s3cret"));
      assert.equal(answered.status, 200);
      assert.equal(Buffer.from(answered.body, "base64").toString(), "<h1>signed in</h1>");
      assert.equal(answered.headers["x-fake"], "1");
      // Once only.
      await assert.rejects(m.logins.callback(login.id, request("s3cret")), (e: unknown) => e instanceof Refused && e.status === 409);
      await m.until(login.id, (l) => l.state === "done", "done");
      assert.match(m.screen(login.id), mode === "post" ? /got POST \/ code=c0de&state=s3cret host=localhost:\d+/ : /got GET \/callback\?code=c0de&state=s3cret  host=localhost:\d+/);
    } finally {
      await m.logins.close();
    }
  });
}

test("a login's page opened in the station's browser: the page its command opened, one tab however often asked, its browser back to the command here with nothing relayed, the tab closed as it ends", { skip: skipped }, async () => {
  const b = fakeBrowser();
  const m = machine(b.pages);
  script(join(m.bin, "fakeloop"), LOOPBACK);
  const by = { email: "b@x.com", name: "李四" };
  try {
    const login = await m.logins.start(["fakeloop", "127.0.0.1", "get"], m.by);
    const waiting = await m.until(login.id, (l) => l.step === "loopback", "loopback");
    assert.deepEqual([waiting.browser, waiting.screen], [true, undefined]);
    assert.equal(await m.logins.openPage(login.id, by), "browser:T1");
    assert.deepEqual([...b.tabs.values()], [waiting.url], "the page it opened, which comes back to it here");
    await m.until(login.id, (l) => l.screen === "browser:T1", "its tab told");
    // Asked again (from another device): the same tab.
    assert.equal(await m.logins.openPage(login.id), "browser:T1");
    assert.deepEqual([...b.tabs.keys()], ["T1"]);
    // A read-only member is not told of it.
    const limited = Logins.limited(m.logins.get(login.id)!);
    assert.deepEqual([limited.browser, limited.screen], [undefined, undefined]);
    // Closed by a person: told, and opened again when asked.
    b.gone("T1");
    await m.until(login.id, (l) => l.screen === undefined, "its tab gone");
    assert.equal(await m.logins.openPage(login.id, by), "browser:T2");
    // The station's browser comes back to the command on this machine itself.
    const back = waiting.callback!;
    await fetch(`http://127.0.0.1:${back.port}${back.path}?code=c0de&state=s3cret`);
    const done = await m.until(login.id, (l) => l.state === "done", "done");
    assert.deepEqual([done.screen, done.browser, done.doneBy], [undefined, undefined, by], "who finished it: whose browser step it was");
    assert.equal(b.tabs.size, 0, "its tab closed as it ended");
    await assert.rejects(m.logins.openPage(login.id), (e: unknown) => e instanceof Refused && e.status === 409);
  } finally {
    await m.logins.close();
  }
});

test("a device code's page opens with its code where the service gives one; a station with no Chrome offers none", { skip: skipped }, async () => {
  const b = fakeBrowser();
  const m = machine(b.pages);
  script(join(m.bin, "fakecode"), `#!/bin/sh\necho "Visit https://vercel.com/oauth/device?user_code=ABCD-EFGH"\nread forever\n`);
  const none = machine(fakeBrowser(() => {}, false).pages);
  script(join(none.bin, "fakecode"), `#!/bin/sh\necho "Visit https://vercel.com/oauth/device?user_code=ABCD-EFGH"\nread forever\n`);
  try {
    const login = await m.logins.start("fakecode", m.by);
    await m.until(login.id, (l) => l.step === "device" && l.browser === true, "device");
    await m.logins.openPage(login.id);
    assert.deepEqual([...b.tabs.values()], ["https://vercel.com/oauth/device?user_code=ABCD-EFGH"]);
    m.logins.cancel(login.id);
    assert.equal(b.tabs.size, 0);
    const there = await none.logins.start("fakecode", none.by);
    const device = await none.until(there.id, (l) => l.step === "device", "device");
    assert.equal(device.browser, undefined);
    await assert.rejects(none.logins.openPage(there.id), (e: unknown) => e instanceof Refused && e.status === 501);
  } finally {
    await m.logins.close();
    await none.logins.close();
  }
});

test("a callback is refused when the port is not the command's, or the command has ended", { skip: skipped }, async () => {
  const m = machine();
  // Another program on the port the page names (the stand-in itself listens nowhere).
  let reached = 0;
  const other = createServer((_req, res) => (reached++, res.end("not the login")));
  await new Promise<void>((resolve) => other.listen(0, "127.0.0.1", resolve));
  const port = (other.address() as AddressInfo).port;
  script(join(m.bin, "fakeport"), `#!/bin/sh\n"$BROWSER" "https://idp.example.com/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A${port}%2Fcb&state=s1"\necho waiting\nread forever\n`);
  script(join(m.bin, "fakegone"), `#!/bin/sh\n"$BROWSER" "https://idp.example.com/auth?redirect_uri=http%3A%2F%2F127.0.0.1%3A${port}%2Fcb&state=s1"\necho bye\nexit 3\n`);
  try {
    const taken = await m.logins.start(["fakeport"], m.by);
    await m.until(taken.id, (l) => l.step === "loopback", "loopback");
    await assert.rejects(
      m.logins.callback(taken.id, { method: "GET", path: "/cb?state=s1&code=x", headers: { host: `127.0.0.1:${port}` } }),
      (e: unknown) => e instanceof Refused && e.status === 409 && e.message.includes(`does not listen on port ${port}`),
    );
    assert.equal(reached, 0, "the code never went to the other program");
    const cancelled = m.logins.cancel(taken.id);
    assert.equal(cancelled.state, "cancelled");
    const gone = await m.logins.start(["fakegone"], m.by);
    const failed = await m.until(gone.id, (l) => l.state === "failed", "failed");
    assert.ok(failed.error!.includes("bye"), failed.error);
    await assert.rejects(m.logins.callback(gone.id, { method: "GET", path: "/cb?state=s1", headers: {} }), (e: unknown) => e instanceof Refused && e.status === 409);
    assert.equal(reached, 0);
    await assert.rejects(m.logins.callback("nope", { method: "GET", path: "/", headers: {} }), (e: unknown) => e instanceof Refused && e.status === 404);
  } finally {
    await m.logins.close();
    await new Promise<void>((resolve) => other.close(() => resolve()));
  }
});

test("gh's Enter to open its page, the cursor on the empty line under it: pressed by the station, and the login finishes with nobody typing", { skip: skipped }, async () => {
  const m = machine();
  // As gh prints it: the code, then its Enter line ended by a newline, so the cursor waits on the line under it.
  script(join(m.bin, "fakegh"), `#!/bin/sh
echo "! First copy your one-time code: 1A2B-C3D4"
echo "Press Enter to open https://github.com/login/device in your browser... "
read go
"$BROWSER" https://github.com/login/device
echo "✓ Authentication complete."
`);
  try {
    const started = await m.logins.start("fakegh auth login", m.by);
    await m.until(started.id, (l) => l.step === "device" && l.code === "1A2B-C3D4", "device");
    await m.quietShowing(started.id, "Press Enter to open");
    const done = await m.until(started.id, (l) => l.state === "done", "done");
    assert.equal(done.url, "https://github.com/login/device");
  } finally {
    await m.logins.close();
  }
});

test("a login silent once nothing is left for anyone (it said it is logged in) ends after a while, saying so with its last screen; silent while the person signs in, it goes on", { skip: skipped }, async () => {
  const m = machine();
  const approved = approval(m.home);
  const stuck = approval(m.home);
  script(join(m.bin, "fakestuck"), `#!/bin/sh
echo "! First copy your one-time code: 1A2B-C3D4"
printf "Press Enter to open https://github.com/login/device in your browser... "
read go
"$BROWSER" https://github.com/login/device
echo "Waiting for the browser"
read ok < '${approved.path}'
echo "✓ Authentication complete."
echo "- gh config set -h github.com git_protocol https"
read never < '${stuck.path}'
`);
  try {
    const started = await m.logins.start(["fakestuck"], m.by);
    await m.quietShowing(started.id, "Press Enter to open");
    await m.quietShowing(started.id, "Waiting for the browser");
    // The person takes their time: silence then is theirs, not the command's.
    await m.time.adjust(STALL_MS);
    await settle(20);
    assert.equal(m.logins.get(started.id)!.state, "code");
    await approved.approve();
    await m.quietShowing(started.id, "git_protocol");
    await m.time.adjust(STALL_MS);
    const ended = await m.until(started.id, (l) => l.state === "failed", "stalled");
    assert.equal(ended.timedOut, true);
    assert.match(ended.error!, /^登录命令在不需要人的时候 3 分钟没有动静/);
    assert.match(ended.error!, /✓ Authentication complete\.\n- gh config set -h github\.com git_protocol https$/);
    // Its agent is told why, with the screen, the page and code hidden.
    const told = endedNotice(ended, null);
    assert.match(told, /failed: 登录命令在不需要人的时候 3 分钟没有动静.* \/ ✓ Authentication complete\. \/ - gh config set/);
    assert.ok(!told.includes("1A2B-C3D4") && !told.includes("https://"), told);
  } finally {
    await m.logins.close();
  }
});

test("git's credential helpers are kept out of a login's command (no keychain to wait on), ~/.gitconfig left as it was but for what the command writes", { skip: skipped }, async () => {
  const m = machine();
  const ran = join(m.home, "helper-ran");
  script(join(m.bin, "keychain-helper"), `#!/bin/sh
echo "$@" >> '${ran}'
cat > /dev/null
`);
  const gitconfig = join(m.home, ".gitconfig");
  writeFileSync(gitconfig, `[user]\n\tname = Someone\n[credential]\n\thelper = ${join(m.bin, "keychain-helper")}\n`);
  // As gh does when told to authenticate git: asks git for its helper, has git store the token through it, and (none
  // set) adds its own for github.com.
  script(join(m.bin, "fakegit"), `#!/bin/sh
echo "helper [$(git config --get credential.helper)]"
printf 'protocol=https\nhost=github.com\nusername=octocat\npassword=t0ken\n\n' | git credential approve
git config --global --add credential.https://github.com.helper '!fakegh auth git-credential'
echo "Logged in as octocat"
`);
  try {
    const started = await m.logins.start(["fakegit"], m.by);
    await m.until(started.id, (l) => l.state === "done", "done");
    assert.ok(m.screen(started.id).includes("helper []"), m.screen(started.id));
    assert.equal(existsSync(ran), false, "the file's helper was not run");
    const after = readFileSync(gitconfig, "utf8");
    assert.ok(after.startsWith(`[user]\n\tname = Someone\n[credential]\n\thelper = ${join(m.bin, "keychain-helper")}\n`), after);
    assert.match(after, /helper = !fakegh auth git-credential/);
  } finally {
    await m.logins.close();
  }
});

test("a login not finished in time ends, its command with it; one that cannot run says why", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakeslow"), `#!/bin/sh\necho "Visit https://example.com/activate"\nread forever\n`);
  try {
    const slow = await m.logins.start(["fakeslow"], m.by);
    await m.until(slow.id, (l) => l.step === "open", "open");
    await m.time.adjust(TIMEOUT_MS);
    const ended = await m.until(slow.id, (l) => l.state === "failed", "timed out");
    assert.equal(ended.error, "15 分钟内没有完成登录，已结束");
    assert.equal(m.logins.logins()[0]!.id, slow.id);
    // The environment a line gives before its program, as a shell takes it (`~/` its home), not a program to run.
    script(join(m.bin, "fakeenv"), `#!/bin/sh\necho "dir=$FAKE_DIR mode=$FAKE_MODE"\n`);
    const given = await m.logins.start("FAKE_DIR=~/x FAKE_MODE='a b' fakeenv", m.by);
    const ran = await m.until(given.id, (l) => l.endedAt !== undefined, "ended");
    assert.equal(ran.state, "done", JSON.stringify(ran));
    assert.equal(ran.name, "fakeenv");
    // The process can close before xterm has drawn its final output.
    const output = await upon((wake) => m.logins.follow(given.id, wake), () => {
      const screen = m.logins.screen(given.id);
      return screen && screen.cursor.y > 0 ? screen.rows.join("\n") : undefined;
    }, "final output drawn");
    assert.ok(output.includes(`dir=${m.home}/x mode=a b`), output);
    const none = await m.logins.start(["no-such-login-command"], m.by);
    const failed = await m.until(none.id, (l) => l.state === "failed", "cannot run");
    assert.ok(failed.error !== undefined && failed.error !== "", JSON.stringify(failed));
    await assert.rejects(m.logins.start("gh 'open", m.by), (e: unknown) => e instanceof Refused && e.status === 400);
    await assert.rejects(m.logins.start("  ", m.by), (e: unknown) => e instanceof Refused && e.status === 400);
    const bare = await m.logins.start("FAKE_DIR=x", m.by);
    assert.equal((await m.until(bare.id, (l) => l.state === "failed", "nothing to run")).error, "要一条登录命令，用工具自己的，比如 gh auth login");
  } finally {
    await m.logins.close();
  }
});

test("a login under way keeps the station from updating itself until it ends: done, cancelled or out of time", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakeslow"), `#!/bin/sh\necho "Visit https://example.com/activate"\nread forever\n`);
  script(join(m.bin, "fakequick"), `#!/bin/sh\necho "Logged in as octocat"\n`);
  const before = holding();
  try {
    const slow = await m.logins.start(["fakeslow"], m.by);
    await m.until(slow.id, (l) => l.step === "open", "open");
    assert.equal(holding(), before + 1, "held while the person signs in");
    m.logins.cancel(slow.id);
    await m.until(slow.id, (l) => l.state === "cancelled", "cancelled");
    assert.equal(holding(), before, "let go once cancelled");
    const late = await m.logins.start(["fakeslow"], m.by);
    await m.until(late.id, (l) => l.step === "open", "open again");
    assert.equal(holding(), before + 1);
    await m.time.adjust(TIMEOUT_MS);
    await m.until(late.id, (l) => l.state === "failed", "timed out");
    assert.equal(holding(), before, "let go once out of time");
    const quick = await m.logins.start(["fakequick"], m.by);
    await m.until(quick.id, (l) => l.endedAt !== undefined, "ended");
    assert.equal(holding(), before, "let go once done");
    await m.logins.start(["fakeslow"], m.by);
    assert.equal(holding(), before + 1);
  } finally {
    await m.logins.close();
  }
  assert.equal(holding(), before, "let go as the station stops");
});

test("a login out of time started again from its card: the same command for the same chat, its agent told, the card following the new one; once, and only one that did not log in", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakeslow"), `#!/bin/sh\necho "Visit https://example.com/activate"\nread forever\n`);
  script(join(m.bin, "fakeok"), `#!/bin/sh\necho done\n`);
  const agains: { from: string; login: string; chat: string | null | undefined; by: string }[] = [];
  m.logins.onAgain((a) => agains.push({ from: a.from.id, login: a.login.id, chat: a.starter.chat, by: a.by.email }));
  try {
    const slow = await m.logins.start(["fakeslow"], { ...m.by, chat: "chat:c-1", chatTitle: "部署" });
    await m.until(slow.id, (l) => l.step === "open", "open");
    assert.equal(m.logins.deadline(slow.id), slow.startedAt + TIMEOUT_MS);
    // Not while it is under way.
    await assert.rejects(m.logins.again(slow.id, { email: "b@x.com", name: "李四" }), (e: unknown) => e instanceof Refused && e.status === 409);
    await m.time.adjust(TIMEOUT_MS);
    await m.until(slow.id, (l) => l.state === "failed" && l.timedOut === true, "timed out");
    assert.equal(m.logins.deadline(slow.id), null);
    const next = await m.logins.again(slow.id, { email: "b@x.com", name: "李四" });
    assert.notEqual(next.id, slow.id);
    assert.deepEqual([next.command, next.chat, next.chatTitle, next.from, next.endedAt], [["fakeslow"], "chat:c-1", "部署", slow.id, undefined]);
    assert.equal(m.logins.get(slow.id)!.again, next.id, "its card follows the new one");
    assert.deepEqual(agains, [{ from: slow.id, login: next.id, chat: "chat:c-1", by: "b@x.com" }]);
    // Pressed again (another device, a press twice): the same one, nobody told again.
    assert.equal((await m.logins.again(slow.id, { email: "b@x.com", name: "李四" })).id, next.id);
    assert.equal(agains.length, 1);
    // One that logged in is not started again.
    const ok = await m.logins.start("fakeok", m.by);
    await m.until(ok.id, (l) => l.state === "done", "done");
    await assert.rejects(m.logins.again(ok.id, m.by.by), (e: unknown) => e instanceof Refused && e.status === 409);
    m.logins.cancel(next.id);
    await m.until(next.id, (l) => l.endedAt !== undefined, "cancelled");
    await m.logins.written();
    // A station started again: what was started again from what is kept, and one let go from memory started again
    // from its record, for the same chat.
    const later = new Logins({ data: join(m.home, "data"), env: () => m.env, clock: m.time.clock, lang: () => "zh" });
    await later.ready();
    assert.deepEqual([later.get(slow.id)!.again, later.get(next.id)!.from], [next.id, slow.id]);
    await assert.rejects(later.again(next.id, m.by.by), (e: unknown) => e instanceof Refused && e.status === 409, "cancelled: not started again");
    await later.close();
  } finally {
    await m.logins.close();
  }
});

test("the logins done here are kept: command, who, when and how each ended, without its page, code or output; each named by its program, one kept before that too", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakeok"), `#!/bin/sh\necho "Open https://example.com/device and enter WXYZ-1234"\necho done\n`);
  script(join(m.bin, "fakewait"), `#!/bin/sh\necho "Open https://example.com/device and enter WXYZ-5678"\nread forever\n`);
  try {
    const ok = await m.logins.start("fakeok", m.by);
    await m.until(ok.id, (l) => l.state === "done", "done");
    const waits = await m.logins.start("fakewait", { ...m.by, chat: "chat:c-1", chatTitle: "部署" });
    await m.until(waits.id, (l) => l.step === "device", "device");
    m.logins.cancel(waits.id, { email: "b@x.com", name: "李四" });
    await m.logins.written();
    // One kept before names were the program's (named env, its first word): named by its program now.
    const file = join(m.home, "data", "logins", "history.json");
    const old = { id: "old", name: "env", command: ["env", "XDG_DATA_HOME=/tmp/x", "/x/bin/devin", "auth", "login"], state: "done", waiting: false, by: m.by.by, startedAt: 1, expiresAt: 2, endedAt: 2 };
    writeFileSync(file, JSON.stringify([...JSON.parse(readFileSync(file, "utf8")), old]));
    // A station started again: what it kept.
    const again = new Logins({ data: join(m.home, "data"), env: () => m.env, clock: m.time.clock, lang: () => "zh" });
    await again.ready();
    const kept = again.logins();
    assert.deepEqual(kept.map((l) => [l.name, l.command.join(" "), l.state, l.by.name]), [["fakewait", "fakewait", "cancelled", "张三"], ["fakeok", "fakeok", "done", "张三"], ["devin", old.command.join(" "), "done", "张三"]]);
    assert.ok(kept.every((l) => l.url === undefined && l.code === undefined && l.error === undefined && typeof l.endedAt === "number"));
    assert.equal(again.get(ok.id)!.state, "done");
    assert.deepEqual([kept[0]!.chat, kept[0]!.chatTitle, kept[0]!.doneBy?.name], ["chat:c-1", "部署", "李四"]);
    await again.close();
  } finally {
    await m.logins.close();
  }
});

test("the routes: a read-only member's list has no pages or codes; no route starts a login, or types into one but a page's code while it waits for one", { skip: skipped }, async () => {
  const m = machine();
  script(join(m.bin, "fakecode"), `#!/bin/sh\necho "Open https://example.com/device and enter WXYZ-1234"\nread forever\n`);
  const all = routes(() => m.logins);
  assert.deepEqual(all.map((r) => r.method), ["GET", "GET", "DELETE", "POST", "POST", "POST", "POST"], "list, one, cancel, a page's code, again, switch to its code, callback: starting one is an agent's (again and the code: one an agent started)");
  const [list, , cancel, answer, , toCode] = all;
  const ask = (route: (typeof list), role: string, body: Json = {}, args: string[] = []) =>
    route!.handle({ method: route!.method, path: "/machine-logins", query: [], headers: {}, body: Buffer.from(JSON.stringify(body)), viewer: { sub: "s", email: "a@x.com", name: "张三", role, workspace: "w1", device: "d" }, lang: "zh" }, args);
  const read = async (answer: Promise<{ status: number; body: unknown }>) => {
    const a = await answer;
    return { status: a.status, body: JSON.parse((a.body as Buffer).toString()) };
  };
  try {
    const started = await m.logins.start("fakecode", m.by);
    await m.until(started.id, (l) => l.step === "device", "device");
    const member = await read(ask(list, "member"));
    const viewer = await read(ask(list, "viewer"));
    const mine = member.body.logins.find((l: Json) => l.id === started.id);
    const theirs = viewer.body.logins.find((l: Json) => l.id === started.id);
    assert.deepEqual([mine.code, mine.url], ["WXYZ-1234", "https://example.com/device"]);
    assert.deepEqual([theirs.code, theirs.url, theirs.step, theirs.domain], [undefined, undefined, "device", "example.com"]);
    // A page's code: not a read-only member's, and only while it waits for one (this one waits for nothing typed).
    assert.equal((await read(ask(answer!, "viewer", { text: "x" }, [started.id]))).status, 403);
    const typed = await read(ask(answer!, "member", { text: "x" }, [started.id]));
    assert.deepEqual([typed.status, typed.body.error], [409, "this login does not wait for a code from its page"]);
    // Nor may its agent say it does, with a device code and no page to sign in on and come back from.
    assert.throws(() => m.logins.paste(started.id, true), /only once it has given a page to open/);
    // Switching to its code-pasting login: not a read-only member's, and only for one its agent gave one for.
    assert.equal((await read(ask(toCode!, "viewer", {}, [started.id]))).status, 403);
    assert.equal((await read(ask(toCode!, "member", {}, [started.id]))).status, 409);
    const cancelled = (await read(ask(cancel!, "member", {}, [started.id]))).body;
    assert.deepEqual([cancelled.state, cancelled.doneBy], ["cancelled", { email: "a@x.com", name: "张三" }], "who finished it: who cancelled it");
  } finally {
    await m.logins.close();
  }
});

test("a machine's lsof says where a process listens", { skip: WINDOWS && "lsof is Unix's" }, async () => {
  const server = createServer(() => {});
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as AddressInfo).port;
  try {
    assert.deepEqual(await platform.listening([process.pid], port), ["127.0.0.1"]);
    assert.deepEqual(await platform.listening([process.pid], port + 1 > 65535 ? 1 : port + 1), []);
  } finally {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});

test("what a Slack login card shows: a device code's page and code, or a page that gives a code to paste; nothing else", () => {
  const base: Login = { id: "l", name: "gh", command: ["gh"], state: "browser", waiting: false, by: { email: "", name: "" }, startedAt: 0, expiresAt: 1 };
  assert.deepEqual(slackPage({ ...base, step: "device", url: "https://github.com/login/device", code: "ABCD-1234" }), { url: "https://github.com/login/device", domain: "github.com", code: "ABCD-1234", paste: false });
  assert.deepEqual(slackPage({ ...base, step: "device", url: "https://x.dev/d", codeUrl: "https://x.dev/d?user_code=AB", code: "AB" })?.url, "https://x.dev/d?user_code=AB");
  assert.deepEqual(slackPage({ ...base, step: "open", url: "https://accounts.google.com/o/oauth2/auth?x=1", paste: true }), { url: "https://accounts.google.com/o/oauth2/auth?x=1", domain: "accounts.google.com", paste: true });
  // A page to open that gives no code back, a loopback one, a device step without its code, one being checked or ended.
  assert.equal(slackPage({ ...base, step: "open", url: "https://www.npmjs.com/login" }), null);
  assert.equal(slackPage({ ...base, step: "loopback", url: "https://accounts.google.com/o/oauth2/auth?redirect_uri=http://localhost:8085/" }), null);
  assert.equal(slackPage({ ...base, step: "device", url: "https://github.com/login/device" }), null);
  assert.equal(slackPage({ ...base, step: "open", url: "https://accounts.google.com/x", paste: true, state: "verifying" }), null);
  assert.equal(slackPage({ ...base, step: "device", url: "https://github.com/login/device", code: "ABCD-1234", endedAt: 2 }), null);
});
