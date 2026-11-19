// The terminals and the logins in MoonBit (station/mb src/terminals_logins: `stillfail-reader-harness --builder harness-terminals-logins`)
// held to the TypeScript they are a port of (src/terminals/, src/logins/): the same cases given to both, and what each
// answered, told, wrote and was asked compared. What @xterm/headless made of a login's output is held on random writes;
// a terminal's views on runners and members' streams of the test's; one login's run on its command's output given a
// chunk at a time; the logins on stand-in commands, a station browser and a callback's server of the test's. Time is
// the test's clock on both sides (a TestClock here, the program's own clock there), moved by the cases alone; what the
// TypeScript sets going on the machine (its terminal's timer, a file's read) is waited for by what it does, never for
// a while.
import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import childProcess from "node:child_process";
import { EventEmitter } from "node:events";
import http from "node:http";
import { mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { stripTypeScriptTypes, syncBuiltinESMExports } from "node:module";
import net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { StringDecoder } from "node:string_decoder";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";
import xterm from "@xterm/headless";
import { mbHarnessBinary } from "./mb-harness.ts";
import { frame } from "../src/mesh/screens.ts";
import { Fibers } from "../src/ops/fibers.ts";
import { programOf } from "../src/ops/command-output.ts";
import { setStationLang } from "../src/ops/i18n.ts";
import { platform } from "../src/platform/index.ts";
import { featureOnChannel } from "../src/features.ts";
import { channelFrom } from "../src/updates/versions.ts";
import { TerminalLink, pastScreen, runnerWire, type Wire } from "../src/terminals/link.ts";
import { Terminals, asked, controlOf, sizeOf } from "../src/terminals/terminals.ts";
import { Logins, slackPage } from "../src/logins/index.ts";
import { LoginRun, keychainOutOfGit, lastLines } from "../src/logins/run.ts";
import { check, stateOf, type Callback } from "../src/logins/relay.ts";
import { LOGIN, endedNotice, promptNotice, screenFor, told } from "../src/logins/tool.ts";
import { Effect, Exit, Layer, Scope } from "effect";
import { Refused as RequestRefused } from "../src/api/request.ts";
import { Browser } from "../src/browser/service.ts";
import { Refused as BusRefused } from "../src/mesh/bus.ts";
import { LoginsLive } from "../src/logins/module.ts";
import { Agents } from "../src/sessions/agents.ts";
import { ControlPlane, Events, Parts, Paths, Peers, Readers, ScreenRegistry, Store } from "../src/services.ts";
import { testClock } from "./hub-fakes.ts";
import { childGone } from "./child-gone.ts";

type Json = any;

setStationLang("en");

const binary = mbHarnessBinary();
const skip = binary === null ? "the tests' MoonBit program (stillfail-reader-harness) is not built here" : false;
const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const ZH = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/zh/station.json"), "utf8"));
const EN = JSON.parse(readFileSync(join(ROOT, "client/i18n/catalog/en/station.json"), "utf8"));

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.env.STILLFAIL_TEST_TMP ?? tmpdir(), `mbterm-${what}-`));
  dirs.push(dir);
  return dir;
};

/// A JSON round trip: what both sides are compared as.
const plain = (v: unknown) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));
const b64 = (s: string | Buffer) => (typeof s === "string" ? Buffer.from(s) : s).toString("base64");

/// The program, started once: a case a line, its answer a line, in turn.
class Program {
  readonly child: ChildProcessWithoutNullStreams;
  readonly #waiting: ((line: string) => void)[] = [];
  #stderr = "";
  constructor() {
    this.child = spawn(binary!, ["--builder", "harness-terminals-logins", "--shell-dir", fresh("shell")], { stdio: ["pipe", "pipe", "pipe"] });
    createInterface({ input: this.child.stdout }).on("line", (line) => this.#waiting.shift()?.(line));
    this.child.stderr.on("data", (d) => (this.#stderr += d));
    this.child.on("exit", (code) => {
      for (const w of this.#waiting.splice(0)) w(JSON.stringify({ error: `the program ended (${code}): ${this.#stderr}` }));
    });
  }
  async ask(c: Json): Promise<Json> {
    const line = await new Promise<string>((resolve) => {
      this.#waiting.push(resolve);
      this.child.stdin.write(`${JSON.stringify(c)}\n`);
    });
    const answer = JSON.parse(line);
    if ("error" in answer) throw new Error(`the program: ${answer.error}`);
    return answer.ok;
  }
}

let program: Program | null = null;
async function mb(c: Json): Promise<Json> {
  if (program === null) {
    program = new Program();
    await program.ask({ op: "words", zh: ZH, en: EN });
  }
  return program.ask(c);
}
after(async () => {
  await childGone(program?.child);
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

/// What the TypeScript set going on the machine run to rest: turns of the loop with no file request out and no
/// timer of the machine's pending (@xterm/headless takes its writes a timer away).
async function drain(rounds = 30) {
  for (let quiet = 0; quiet < rounds; ) {
    await new Promise((r) => setImmediate(r));
    const busy = process.getActiveResourcesInfo().some((r) => r === "FSReqPromise" || r === "FSReqCallback" || r === "CloseReq" || r === "Timeout");
    quiet = busy ? 0 : quiet + 1;
  }
}

/// A private function of a module, taken from its source as it is and given what it reads.
function privateFn(file: string, name: string, given: Record<string, unknown>): (...args: any[]) => any {
  const source = readFileSync(join(ROOT, "station/src", file), "utf8");
  const at = source.search(new RegExp(`^(const ${name} =|function ${name}\\()`, "m"));
  assert.ok(at >= 0, `${name} in ${file}`);
  let end = source.indexOf("\n\n", at);
  if (end < 0) end = source.length;
  const js = stripTypeScriptTypes(source.slice(at, end));
  const names = Object.keys(given);
  return new Function(...names, `${js}\nreturn ${name};`)(...names.map((n) => given[n]));
}

// ── what depends on nothing but what it is given ──

test("a view's asks, frames, runners' offsets, meta, shells and channels: as the TypeScript says", { skip }, async () => {
  const metaOf = privateFn("terminals/module.ts", "metaOf", {});
  const shellOn = (os: string, shell: string | null) =>
    privateFn("terminals/module.ts", "shell", { platform: { os }, process: { env: shell === null ? {} : { SHELL: shell } } })();
  const views = [null, 5, "x", [], { cols: 80, rows: 24 }, { cols: 0, rows: 24 }, { cols: 1000, rows: 500 }, { cols: 1001, rows: 1 }, { cols: 80.5, rows: 24 }, { cols: 80, rows: 24, control: false, taken: true, cwd: "/a", chat: "c1" }, { cols: 80, rows: 24, control: 0, taken: "yes", cwd: "", chat: "x".repeat(4097) }, { cols: 2, rows: 1, cwd: "x".repeat(4096) }, { cols: "80", rows: 24 }];
  for (const v of views) assert.deepEqual(await mb({ op: "pure", fn: "asked", args: [v] }), plain(asked(v)), JSON.stringify(v));
  for (const p of ["nope", "", "null", "[]", '{"cols":10,"rows":5}', '{"cols":1,"rows":5}', '{"cols":10.0,"rows":500}', '{"control":true}', '{"control":false,"taken":true}', '{"control":true,"taken":true,"cols":120,"rows":40}', '{"control":"yes"}', '{"control":true,"cols":120}', "ÿ{"]) {
    assert.deepEqual(await mb({ op: "pure", fn: "sizeOf", args: [p] }), plain(sizeOf(Buffer.from(p))), p);
    assert.deepEqual(await mb({ op: "pure", fn: "controlOf", args: [p] }), plain(controlOf(Buffer.from(p))), p);
  }
  for (const [at, text, past] of [[0, "abc", 3], [0, "abcdef", 3], [5, "xy", 3], [3, "", 3], [2, "abc", 2.5], [10, "x", 0]] as const) {
    const ts = pastScreen({ at, bytes: Buffer.from(text) }, past);
    assert.deepEqual(await mb({ op: "pure", fn: "pastScreen", args: [at, b64(text), past] }), ts === null ? null : b64(ts));
  }
  for (const m of [null, "x", { by: "a", at: 1, cwd: "/w", workspace: "w1" }, { by: "a", at: 1, cwd: "/w", workspace: "w1", chat: "c" }, { by: "a", at: "1", cwd: "/w", workspace: "w1" }, { by: "a", at: 1, cwd: "/w" }, { workspace: "w", chat: 5, by: "b", cwd: "/", at: 0 }]) {
    assert.deepEqual(await mb({ op: "pure", fn: "metaOf", args: [m] }), plain(metaOf(m)), JSON.stringify(m));
  }
  for (const [os, sh] of [["darwin", "/bin/zsh"], ["linux", null], ["linux", ""], ["windows", "/bin/bash"]] as const) {
    assert.deepEqual(await mb({ op: "pure", fn: "shell", args: [os, sh] }), plain(shellOn(os, sh)));
  }
  for (const raw of [null, {}, { updateChannel: "beta" }, { updateChannel: " stable " }, { updateChannel: "nightly" }, { updateChannel: 5 }]) {
    for (const release of [null, "beta", "stable", "x"]) {
      assert.equal(await mb({ op: "pure", fn: "channelFrom", args: [raw, release] }), channelFrom(raw, release as never), `${JSON.stringify(raw)} ${release}`);
    }
  }
  for (const [stage, station, channel] of [["beta", true, "beta"], ["beta", true, "stable"], ["beta", false, "beta"], ["stable", true, "beta"], [null, true, "beta"]] as const) {
    const registry = stage === null ? {} : { terminal: { stage, station } };
    assert.equal(await mb({ op: "pure", fn: "featureOn", args: [stage, station, channel] }), featureOnChannel("terminal" as never, channel, registry as never));
  }
  for (const kind of [0, 1, 3, 16, 17, 18, 255]) for (const payload of ["", "x", "x".repeat(300)]) {
    assert.equal(await mb({ op: "pure", fn: "frame", args: [kind, b64(payload)] }), b64(frame(kind, Buffer.from(payload))));
  }
  // Buffer's base64 (either alphabet, what is not of it passed over), a StringDecoder across chunks
  for (const s of ["", "aGVsbG8=", "aGVsbG8", "aGV sbG8", "a-_b", "YQ==YQ==", "!!!", "aGVsbG8\n", "ab=c", "QUJD\r\nREVG"]) {
    assert.deepEqual(await mb({ op: "pure", fn: "fromBase64", args: [s] }), [...Buffer.from(s, "base64")], s);
  }
  const bytes = Buffer.from("héllo 中文 🎉 x", "utf8");
  for (const cuts of [[1], [2, 3], [9, 10, 11], [13, 14, 15, 16], [bytes.length]]) {
    const chunks: Buffer[] = [];
    let at = 0;
    for (const c of [...cuts, bytes.length]) { chunks.push(bytes.subarray(at, c)); at = c; }
    const d = new StringDecoder("utf8");
    assert.deepEqual(await mb({ op: "pure", fn: "decode", args: [chunks.map((c) => b64(c))] }), chunks.map((c) => d.write(c)), String(cuts));
  }
  for (const s of ["abc", "a b", "中", "é", "-_.!~*'()", "a/b?c=d&e", "🎉"]) {
    assert.equal(await mb({ op: "pure", fn: "encodeURIComponent", args: [s] }), encodeURIComponent(s));
  }
});

/// Logins as their agents and clients are told them, of each kind.
const LOGINS: Json[] = [
  { id: "a1", name: "gh", command: ["gh", "auth", "login"], state: "code", step: "device", waiting: false, by: { email: "a@x", name: "Ann" }, workspace: "w1", chat: "c1", chatTitle: "Deploy", startedAt: 1000, expiresAt: 901000, domain: "github.com", url: "https://github.com/login/device", code: "AB12-CD34", codeUrl: "https://github.com/login/device?user_code=AB12-CD34" },
  { id: "a2", name: "gcloud", command: ["gcloud", "auth", "login"], state: "browser", step: "loopback", waiting: false, by: { email: "a@x", name: "" }, startedAt: 1, expiresAt: 2, url: "https://accounts.google.com/o?redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&state=s", callback: { host: "localhost", port: 8085, path: "/", state: "s", post: false }, browser: true, screen: "browser:t1" },
  { id: "a3", name: "devin", command: ["devin", "auth", "login"], state: "browser", step: "open", waiting: true, paste: true, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, url: "https://app.devin.ai/auth/cli?x=1" },
  { id: "a4", name: "az", command: ["az", "login"], state: "input", step: "terminal", waiting: true, by: { email: "", name: "" }, startedAt: 1, expiresAt: 2 },
  { id: "a5", name: "npm", command: ["npm", "login"], state: "failed", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, endedAt: 3, timedOut: true, error: "line one\nhttps://x.example/a b\nAB12-CD34 again" },
  { id: "a6", name: "x", command: ["x", "login"], state: "done", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, endedAt: 3 },
  { id: "a7", name: "x", command: ["x", "login"], state: "cancelled", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, endedAt: 3, doneBy: { email: "b@x", name: "Bo" } },
  { id: "a8", name: "x", command: ["x"], state: "verifying", step: "open", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, url: "https://x.example/p" },
  { id: "a9", name: "x", command: ["x"], state: "browser", step: "open", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, url: "https://x.example/p" },
  { id: "b1", name: "x", command: ["x"], state: "failed", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, endedAt: 3 },
  { id: "b2", name: "x", command: ["x"], state: "code", step: "device", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2, url: "http://localhost:3000/x" },
  { id: "b3", name: "x", command: ["x"], state: "starting", waiting: false, by: { email: "a@x", name: "Ann" }, startedAt: 1, expiresAt: 2 },
];
const SCREENS: Json[] = [
  null,
  { rows: ["", "! First copy your one-time code: AB12-CD34", "Press Enter to open https://github.com/login/device in your browser...   ", "", "", ""], cursor: { x: 0, y: 3 }, echo: true, live: true },
  { rows: ["Password: ", "", ""], cursor: { x: 10, y: 0 }, echo: false, live: true },
  { rows: Array.from({ length: 40 }, (_, i) => (i % 3 === 0 ? "" : `line ${i} https://x.example/${i}`)), cursor: { x: 0, y: 39 }, echo: true, live: false },
];

test("what agents and clients are told of a login: as the TypeScript tells it", { skip }, async () => {
  for (const login of LOGINS) {
    assert.deepEqual(await mb({ op: "pure", fn: "slackPage", args: [login] }), plain(slackPage(login)), login.id);
    assert.deepEqual(await mb({ op: "pure", fn: "limited", args: [login] }), plain(Logins.limited(login)), login.id);
    for (const [link, where] of [[null, null], ["https://app.still.fail/w/w1/s/s1/login/a1", null], ["https://app/l", { station: "s2", name: "Box" }]] as const) {
      for (const screen of SCREENS) {
        const logins = { screen: () => screen } as never;
        assert.equal(await mb({ op: "pure", fn: "told", args: [login, link, where, screen] }), told(logins, login, link, where), `${login.id} ${link} ${JSON.stringify(where)}`);
        assert.equal(await mb({ op: "pure", fn: "promptNotice", args: [login, link, where, screen] }), promptNotice(logins, login, link, where));
        assert.equal(await mb({ op: "pure", fn: "screenFor", args: [screen, login] }), screenFor(screen, login));
      }
      assert.equal(await mb({ op: "pure", fn: "endedNotice", args: [login, link, where] }), endedNotice(login, link, where));
    }
  }
  assert.deepEqual(await mb({ op: "pure", fn: "loginTool", args: [] }), plain(LOGIN));
  for (const said of ["", "one", "  a  \n\n b \n", Array.from({ length: 12 }, (_, i) => `line ${i}   `).join("\n"), "x".repeat(900), "🎉".repeat(801), "\r\n\t x \t"]) {
    assert.equal(await mb({ op: "pure", fn: "lastLines", args: [said] }), lastLines(said));
  }
  for (const env of [{}, { GIT_CONFIG_COUNT: "2" }, { GIT_CONFIG_COUNT: "-1" }, { GIT_CONFIG_COUNT: "x" }, { GIT_CONFIG_COUNT: " 3abc" }, { GIT_CONFIG_COUNT: "1e3" }, { PATH: "/b", GIT_CONFIG_COUNT: "0", GIT_CONFIG_KEY_0: "x" }] as Record<string, string>[]) {
    const e: Record<string, string> = { ...env };
    keychainOutOfGit(e);
    assert.deepEqual(await mb({ op: "pure", fn: "keychain", args: [env] }), e, JSON.stringify(env));
  }
  for (const words of [["gh", "auth", "login"], ["env", "HOME=/x", "/x/bin/devin", "auth"], ["npx", "-y", "vercel@latest", "login"]]) {
    assert.equal(await mb({ op: "pure", fn: "programOf", args: [words] }), programOf(words));
  }
  // a callback's state, by its query or its form
  for (const [s, name] of [["state=abc", "state"], ["?a=1&state=x%20y+z", "state"], ["a=1&a=2", "a"], ["state=%zz&state=2", "state"], ["x", "x"], ["=v", ""], ["state=%E4%B8%AD", "state"], ["state=%E4", "state"]] as const) {
    assert.deepEqual(await mb({ op: "pure", fn: "formGet", args: [s, name] }), new URLSearchParams(s).get(name), s);
  }
  for (const cb of [
    { method: "GET", path: "/cb?state=s1&code=c", headers: {} },
    { method: "GET", path: "/cb", headers: {} },
    { method: "POST", path: "/?state=q", headers: {}, body: b64("code=1&state=f") },
    { method: "POST", path: "/?state=q", headers: {}, body: b64("code=1") },
    { method: "post", path: "/?state=q", headers: {}, body: b64("state=f") },
  ] as Callback[]) {
    assert.deepEqual(await mb({ op: "pure", fn: "stateOf", args: [cb] }), stateOf(cb), JSON.stringify(cb));
  }
});

// ── the terminal a login's output is drawn on ──

/// Random writes, as login commands and what they run write to a terminal (seeded: the same cases each run).
function vtCases(seed: number, n: number): Json[] {
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const pick = <T>(a: readonly T[]) => a[Math.floor(rnd() * a.length)]!;
  const int = (k: number) => Math.floor(rnd() * k);
  const E = "\x1b";
  const params = () => Array.from({ length: int(4) }, () => pick(["", String(int(5)), String(int(30)), String(int(300)), "0", "1", "2", "3"])).join(pick([";", ";", ";", ":"]));
  const toks: (() => string)[] = [
    () => pick(["hello", "a", "word ", "  ", "xyz", "Login", "https://x.example/a?b=c", "#", "q", "~"]),
    () => "x".repeat(int(30)),
    () => pick(["中文", "한", "ｱ", "🎉", "é", "é", "́", "​", "가", "𠀀", "﻿", "­", "̀̀"]),
    () => pick(["\r", "\n", "\r\n", "\b", "\t", "\x07", "\x0b", "\x0c", "\x0e", "\x0f", "\x00", "\x7f", "\x18", "\x1a", "\x84", "\x85", "\x88", "\x9b2J", "\x9c"]),
    () => E + "[" + params() + pick("@ABCDEFGHIJKLMPSTXZ`abcdefghlmnrsu".split("")),
    () => E + "[" + pick(["?", ">", "=", "<"]) + params() + pick("hlJKnc".split("")),
    () => E + "[" + pick(["?1049h", "?1049l", "?47h", "?47l", "?1047h", "?1047l", "?6h", "?6l", "?7h", "?7l", "?45h", "?45l", "4h", "4l", "20h", "20l", "?25l", "?1048h", "?1048l", "!p", "?2h", '1"q', '2"q', '0"q', "?1J", "?2K", "?0J", "38;5;0m", "38;2;1;0;3m", "0m", "m", "1;0m", "48:5:0m", "2$p", "?1049$p", "?7$p", "4$p", "?25$p", "?1000h", "?1000$p", " @", " A", "2'}", "1'~", "5n", "6n", "?6n", "c", ">c", "0c", "1c", "18t", "s", "u", "3J", "3;5r", "r", "2;99r", "10;3r"]),
    () => E + pick(["7", "8", "D", "E", "H", "M", "c", "=", ">", "(0", "(B", ")0", "(A", "*0", "+0", "-0", ".0", "/0", "%@", "%G", "#8", "n", "o", "|", "}", "~", "(X", "Z", "\\"]),
    () => E + "]" + pick(["10;?", "11;?", "10;rgb:1/2/3", "0;title", "11", "12;?", "4;1;?", "x;?", "10;?;?"]) + pick(["\x07", E + "\\", "\x9c", "\x18"]),
    () => E + "P" + pick(["$qm", "$qr", "$q q", '$q"q', '$q"p', "$qz", "1$qm", "+q544e"]) + pick([E + "\\", "\x9c", "\x18"]),
    () => E + pick(["^", "_", "X"]) + "junk" + pick([E + "\\", "\x9c"]),
    () => `${E}[${int(50)};${int(250)}H`,
  ];
  return Array.from({ length: n }, () => {
    const [cols, rows, scrollback] = pick([[200, 40, 200], [20, 6, 10], [10, 4, 0], [30, 8, 3]] as const);
    const writes = Array.from({ length: 1 + int(5) }, () => Array.from({ length: 1 + int(25) }, () => pick(toks)()).join(""));
    if (rnd() < 0.2) writes.push("a\ud83c", "\udf89b");
    return { cols, rows, scrollback, writes };
  });
}

/// What @xterm/headless makes of a case's writes, with the colours a login's run answers.
async function xtermOf(c: Json): Promise<Json> {
  const term = new xterm.Terminal({ cols: c.cols, rows: c.rows, scrollback: c.scrollback, allowProposedApi: true, logLevel: "off" });
  const replies: string[] = [];
  term.onData((d) => replies.push(d));
  term.parser.registerOscHandler(10, (data) => (data === "?" ? (replies.push("\u001b]10;rgb:0000/0000/0000\u001b\\"), true) : false));
  term.parser.registerOscHandler(11, (data) => (data === "?" ? (replies.push("\u001b]11;rgb:ffff/ffff/ffff\u001b\\"), true) : false));
  for (const w of c.writes) term.write(w);
  await new Promise<void>((r) => term.write("", r));
  const b = term.buffer.active;
  const rows = Array.from({ length: c.rows }, (_, i) => b.getLine(b.baseY + i)?.translateToString(true) ?? "");
  term.dispose();
  return { rows, x: b.cursorX, y: b.cursorY, replies };
}

test("the terminal shows and answers what @xterm/headless does on the same writes", { skip }, async () => {
  const cases = [
    ...vtCases(20261117, 400),
    // what login commands print: gh's device code and its prompt, a box drawn, a wrapped link, a menu redrawn
    { cols: 200, rows: 40, scrollback: 200, writes: ["\u001b]11;?\u001b\\\u001b[?25l\u001b[0;1;92m? \u001b[0mAuthenticate Git with your GitHub credentials? \u001b[0;36m(Y/n) \u001b[0m\u001b[?25h", "\r\n! First copy your one-time code: \u001b[0;1;39m1A2B-C3D4\u001b[0m\r\nPress \u001b[0;1;39mEnter\u001b[0m to open https://github.com/login/device in your browser... "] },
    { cols: 200, rows: 40, scrollback: 200, writes: ["╭" + "─".repeat(198) + "╮\r\n│ " + "https://x.example/" + "a".repeat(300) + " │\r\n╰" + "─".repeat(198) + "╯\r\n"] },
    { cols: 200, rows: 40, scrollback: 200, writes: Array.from({ length: 60 }, (_, i) => `line ${i}\r\n`).concat(["\u001b[6n\u001b[c\u001b[>c\u001b[5n"]) },
    { cols: 200, rows: 40, scrollback: 200, writes: ["? Pick one\r\n> a\r\n  b\r\n", "\u001b[2A\u001b[2K  a\r\n\u001b[2K> b\r\n"] },
  ];
  for (const [i, c] of cases.entries()) assert.deepEqual(await mb({ op: "vt", ...c }), await xtermOf(c), `case ${i}: ${JSON.stringify(c)}`);
});

// ── a runner's socket ──

test("a runner's socket: its lines read, contiguous output put together, what is written and how it ends", { skip }, async () => {
  const lines = (...ms: Json[]) => ms.map((m) => (typeof m === "string" ? m : JSON.stringify(m))).join("\n") + "\n";
  const out = (at: number, text: string) => ({ op: "out", stream: "out", at, data: b64(text) });
  const cases: { reads: string[]; writes?: string[]; end?: boolean; close?: boolean; writable?: boolean; saysLeave?: boolean }[] = [
    { reads: [lines(out(0, "ab"), out(2, "cd"), out(4, "e"))] },
    { reads: [lines(out(0, "ab"), out(5, "cd"), { op: "screen", at: 7, data: b64("s") }, out(7, "x"))] },
    { reads: [lines(out(0, "ab")).slice(0, 10), lines(out(0, "ab")).slice(10), lines({ op: "exit", code: 0 })] },
    { reads: [lines("not json", '{"op":"error","error":"no"}', out(0, "a"), "", out(1, "b"), '{"op":"out","stream":"err","at":0,"data":"eA=="}', out(2, "c"))] },
    { reads: [lines({ op: "out", stream: "out", at: "1", data: "eA==" }, { op: "out", stream: "out", at: 1, data: 5 }, 5, null, [1])], writes: ['{"op":"ack"}\n'], end: true, close: true },
    { reads: [], writes: ["a\n"], end: true, writable: false },
    { reads: [], writes: ["a\n"], end: true, saysLeave: true },
    { reads: [Buffer.from(lines(out(0, "é"))).subarray(0, 3).toString("latin1"), Buffer.from(lines(out(0, "é"))).subarray(3).toString("latin1")] },
  ];
  const realConnect = net.createConnection;
  const leave = platform.runnerSaysLeave;
  try {
    for (const [i, c] of cases.entries()) {
      const written: string[] = [];
      const socket = Object.assign(new EventEmitter(), {
        writable: c.writable !== false,
        write: (line: string) => void written.push(line),
        end: () => void written.push("<end>"),
      });
      (net as any).createConnection = () => socket;
      syncBuiltinESMExports();
      (platform as any).runnerSaysLeave = c.saysLeave === true;
      const wire = runnerWire({ socket: "/x" } as never);
      const toldTs: Json[] = [];
      wire.on("line", (m) => void toldTs.push(Buffer.isBuffer(m?.bytes) ? { out: { at: m.at, bytes: b64(m.bytes) } } : { line: m }));
      let closed = 0;
      wire.on("close", () => void closed++);
      // (a read's bytes as they came: the cases' latin1 strings are bytes, the rest UTF-8)
      const reads = c.reads.map((r) => (i === 7 ? Buffer.from(r, "latin1") : Buffer.from(r)));
      for (const r of reads) socket.emit("data", r);
      for (const w of c.writes ?? []) wire.write(w);
      if (c.end) wire.end();
      if (c.close) socket.emit("close");
      const got = await mb({ op: "wire", reads: reads.map((r) => r.toString("base64")), writes: c.writes ?? [], end: c.end === true, close: c.close === true, writable: c.writable !== false, saysLeave: c.saysLeave === true });
      assert.deepEqual(got, { told: plain(toldTs), written, closed }, `case ${i}`);
    }
  } finally {
    (net as any).createConnection = realConnect;
    syncBuiltinESMExports();
    (platform as any).runnerSaysLeave = leave;
  }
});

// ── a station's terminals ──

/// A runner as its link sees it: what it was sent, and what it says.
class FakeRunner {
  sent: string[] = [];
  readonly #lines: ((m: any) => void)[] = [];
  readonly closes: (() => void)[] = [];
  at = 0;
  readonly wire: Wire = {
    write: (line) => void this.sent.push(line),
    end: () => void this.sent.push("<end>"),
    on: (event: "line" | "close", f: any) => void (event === "line" ? this.#lines.push(f) : this.closes.push(f)),
  };
  say(m: any) {
    for (const f of [...this.#lines]) f(m);
  }
}

/// A member's stream: what the client sends, what it is answered.
class FakeStream {
  written: Buffer[] = [];
  readonly #in: (Buffer | null)[] = [];
  #wait: ((b: Buffer | null) => void) | null = null;
  finished = false;
  done = false;
  error: string | null = null;
  async read() {
    const next = this.#in.shift();
    if (next !== undefined) return next;
    return new Promise<Buffer | null>((resolve) => (this.#wait = resolve));
  }
  async write(bytes: Buffer) {
    this.written.push(bytes);
  }
  async finish() {
    this.finished = true;
  }
  async stopped() {
    return null;
  }
  async reset() {}
  send(b: Buffer | null) {
    if (this.#wait) {
      const w = this.#wait;
      this.#wait = null;
      w(b);
    } else this.#in.push(b);
  }
  json() {
    return { written: Buffer.concat(this.written).toString("base64"), finished: this.finished, done: this.done, error: this.error };
  }
}

const viewerOf = (v: Json = {}) => {
  const name = v.name ?? "";
  return { sub: name, email: v.email ?? `${name}@x`, name, role: v.role ?? "member", workspace: v.workspace ?? "w1", device: v.device ?? `${name}-device` };
};

/// A case's steps on the TypeScript's terminals, as the harness takes them on the program's.
async function terminalsTs(c: Json): Promise<Json> {
  const realNow = Date.now;
  Date.now = () => c.wall ?? 0;
  try {
    const runners: FakeRunner[] = [];
    const starts: Json[] = [];
    const gone: string[] = [];
    let changes = 0;
    let n = 0;
    const terminals = new Terminals({
      home: c.home ?? "/home/a",
      chatDir: (chat) => c.chats?.[chat],
      newId: () => `term-${++n}`,
      changed: () => void changes++,
      gone: (id) => void gone.push(id),
      ...(typeof c.offered === "boolean" ? { offered: () => c.offered } : {}),
      async start(id, o, meta) {
        starts.push({ id, cwd: o.cwd, cols: o.cols, rows: o.rows, meta: plain(meta) });
        const fail = c.startFails?.[String(starts.length)];
        if (fail !== undefined) throw new Error(fail);
        const r = new FakeRunner();
        runners.push(r);
        return new TerminalLink(r.wire);
      },
    });
    const streams: Record<string, FakeStream> = {};
    const results: Json[] = [];
    for (const s of c.steps) {
      let result: Json = null;
      switch (s.do) {
        case "view": {
          const fs = new FakeStream();
          streams[s.stream] = fs;
          const head = s.head ?? { method: "POST", path: `/admin/api/terminals/${s.id ?? "new"}/view`, terminal: s.terminal ?? null };
          terminals.answer(fs, Buffer.from(s.carry ?? "", "base64"), head, viewerOf(s.viewer)).then(
            () => void (fs.done = true),
            (e) => void ((fs.error = (e as Error).message), (fs.done = true)),
          );
          break;
        }
        case "out": {
          const r = runners[s.runner]!;
          const data = Buffer.from(s.text);
          r.say({ op: "out", stream: "out", at: r.at, data: data.toString("base64") });
          r.at += data.length;
          break;
        }
        case "screen": {
          const r = runners[s.runner]!;
          r.say({ op: "screen", at: s.at ?? r.at, data: b64(s.text), ...("cols" in s ? { cols: s.cols } : {}), ...("rows" in s ? { rows: s.rows } : {}) });
          break;
        }
        case "say":
          runners[s.runner]!.say(s.message);
          break;
        case "close":
          for (const f of [...runners[s.runner]!.closes]) f();
          break;
        case "send":
          streams[s.stream]!.send(s.end ? null : s.raw !== undefined ? Buffer.from(s.raw, "base64") : frame(s.kind, Buffer.from(s.payload ?? "")));
          break;
        case "end":
          result = terminals.end(s.id, s.by, s.workspace ?? "w1");
          break;
        case "keep": {
          const r = new FakeRunner();
          runners.push(r);
          const meta = privateFn("terminals/module.ts", "metaOf", {})(s.meta);
          if (meta) terminals.keep(s.id, new TerminalLink(r.wire), meta, { cols: s.cols, rows: s.rows });
          break;
        }
        case "detach":
          terminals.detach();
          break;
        case "list":
          result = plain(terminals.list(s.workspace ?? "w1"));
          break;
        case "workspaces":
          result = terminals.workspaces();
          break;
      }
      await drain();
      results.push(result);
    }
    return { results, starts, gone, changes, runners: runners.map((r) => r.sent), streams: Object.fromEntries(Object.entries(streams).map(([k, v]) => [k, v.json()])), defects: [] };
  } finally {
    Date.now = realNow;
  }
}

const K = { screen: 1, out: 2, state: 3, input: 16, resize: 17, control: 18 };
const sz = (cols: number, rows: number, more: Json = {}) => ({ cols, rows, ...more });

const TERMINAL_CASES: { what: string; c: Json }[] = [
  {
    what: "the screen first, then what came after it; the typing view's resize; a watcher given the screen again",
    c: { wall: 5000, chats: { c1: "/work/c1" }, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24, { chat: "c1" }), viewer: { name: "ann" } },
      { do: "out", runner: 0, text: "hello " }, { do: "out", runner: 0, text: "world" }, { do: "screen", runner: 0, text: "[screen:hello]", at: 6 }, { do: "out", runner: 0, text: "!" },
      { do: "list" },
      { do: "view", stream: "w", id: "term-1", terminal: sz(80, 24, { control: false }), viewer: { name: "bob" } },
      { do: "screen", runner: 0, text: "[screen:bob]" },
      { do: "send", stream: "a", kind: K.input, payload: "ls\r" }, { do: "send", stream: "a", kind: K.resize, payload: JSON.stringify({ cols: 100, rows: 30 }) },
      { do: "screen", runner: 0, text: "[screen:resized]", cols: 100, rows: 30 },
      { do: "out", runner: 0, text: "after" },
      { do: "send", stream: "a", kind: K.resize, payload: "nope" }, { do: "send", stream: "a", kind: K.resize, payload: JSON.stringify({ cols: 100, rows: 30 }) },
      { do: "send", stream: "a", end: true }, { do: "send", stream: "w", end: true }, { do: "list" }, { do: "workspaces" },
    ] },
  },
  {
    what: "只看 and 接管 in band; a look-only view's typing reaches nothing; a read-only member opens none",
    c: { wall: 1, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" } }, { do: "screen", runner: 0, text: "s1" },
      { do: "view", stream: "b", id: "term-1", terminal: sz(90, 28, { control: false }), viewer: { name: "bob" } }, { do: "screen", runner: 0, text: "s2" },
      { do: "send", stream: "a", kind: K.control, payload: JSON.stringify({ control: false }) },
      { do: "send", stream: "b", kind: K.input, payload: "x" },
      { do: "send", stream: "b", kind: K.control, payload: JSON.stringify({ control: true, taken: true, cols: 90, rows: 28 }) },
      { do: "screen", runner: 0, text: "s-90x28" },
      { do: "send", stream: "b", kind: K.input, payload: "y" }, { do: "send", stream: "a", kind: K.input, payload: "z" },
      { do: "send", stream: "a", kind: K.control, payload: JSON.stringify({ control: true }) },
      { do: "send", stream: "a", kind: K.control, payload: JSON.stringify({ control: true, taken: true }) },
      { do: "send", stream: "b", kind: K.control, payload: "nope" },
      { do: "view", stream: "v", id: "term-1", terminal: sz(80, 24, { taken: true }), viewer: { name: "vic", role: "viewer" } }, { do: "screen", runner: 0, text: "s3" },
      { do: "send", stream: "v", kind: K.input, payload: "rm -rf /\r" }, { do: "send", stream: "v", kind: K.control, payload: JSON.stringify({ control: true, taken: true }) },
      { do: "view", stream: "r", terminal: sz(80, 24), viewer: { name: "vic", role: "viewer" } },
      { do: "list" },
      { do: "send", stream: "a", end: true }, { do: "send", stream: "b", end: true }, { do: "send", stream: "v", end: true },
    ] },
  },
  {
    what: "接管 at the head: the one before only looks, its typing reaches nothing; the others given the screen at the new size",
    c: { wall: 2, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" } }, { do: "screen", runner: 0, text: "s1" },
      { do: "view", stream: "b", id: "term-1", terminal: sz(60, 20), viewer: { name: "bob" } }, { do: "screen", runner: 0, text: "s2" },
      { do: "send", stream: "b", kind: K.input, payload: "x" },
      { do: "view", stream: "c", id: "term-1", terminal: sz(70, 22, { taken: true }), viewer: { name: "carol" } },
      { do: "screen", runner: 0, text: "s3" }, { do: "screen", runner: 0, text: "s4" }, { do: "screen", runner: 0, text: "s5" },
      { do: "send", stream: "a", kind: K.input, payload: "a" }, { do: "send", stream: "c", kind: K.input, payload: "c" },
      { do: "list" },
      { do: "send", stream: "a", end: true }, { do: "send", stream: "b", end: true }, { do: "send", stream: "c", end: true },
    ] },
  },
  {
    what: "ending one: its program killed, its views told how it ended; it leaves once none looks; workspaces apart",
    c: { wall: 3, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" } }, { do: "screen", runner: 0, text: "s" },
      { do: "end", id: "term-1", by: "eve", workspace: "w2" },
      { do: "view", stream: "e", id: "term-1", terminal: sz(80, 24), viewer: { name: "eve", workspace: "w2" } },
      { do: "end", id: "term-1", by: "bob" },
      { do: "say", runner: 0, message: { op: "exit", code: null, signal: "KILL" } },
      { do: "list" }, { do: "end", id: "term-1", by: "bob" },
      { do: "send", stream: "a", end: true }, { do: "list" }, { do: "end", id: "term-1", by: "bob" },
    ] },
  },
  {
    what: "a runner gone without an exit; a screen asked of an ended one; an error answered for the oldest ask",
    c: { wall: 4, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" } },
      { do: "say", runner: 0, message: { op: "error", error: { why: 1 } } },
      { do: "view", stream: "b", id: "term-1", terminal: sz(80, 24, { control: false }), viewer: { name: "bob" } },
      { do: "say", runner: 0, message: { op: "screen", at: "x", data: 5 } },
      { do: "out", runner: 0, text: "kept?" },
      { do: "close", runner: 0 },
      { do: "view", stream: "c", id: "term-1", terminal: sz(80, 24), viewer: { name: "cy" } },
      { do: "list" },
      { do: "send", stream: "a", end: true }, { do: "send", stream: "b", end: true }, { do: "send", stream: "c", end: true }, { do: "list" },
    ] },
  },
  {
    what: "what a view asks is checked: method, path, size; frames too large, a stream ended inside one, what came with the head",
    c: { wall: 5, offered: true, steps: [
      { do: "view", stream: "g", head: { method: "GET", path: "/admin/api/terminals/new/view", terminal: sz(80, 24) }, viewer: { name: "ann" } },
      { do: "view", stream: "p", head: { method: "post", path: "/admin/api/terminals/new/view?x", terminal: sz(80, 24) }, viewer: { name: "ann" } },
      { do: "view", stream: "s", terminal: sz(1, 24), viewer: { name: "ann" } },
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" }, carry: frame(K.input, Buffer.from("early")).toString("base64") },
      { do: "screen", runner: 0, text: "s" },
      { do: "send", stream: "a", raw: Buffer.concat([Buffer.from([K.input, 0, 1, 0, 1]), Buffer.alloc(10)]).toString("base64") },
      { do: "view", stream: "b", id: "term-1", terminal: sz(80, 24), viewer: { name: "bo" } }, { do: "screen", runner: 0, text: "s2" },
      { do: "send", stream: "b", raw: Buffer.from([K.input, 0, 0, 0, 9, 65]).toString("base64") },
      { do: "send", stream: "b", end: true },
      { do: "view", stream: "u", id: "%E4", terminal: sz(80, 24), viewer: { name: "bo" } },
      { do: "view", stream: "q", id: "term%2D1", terminal: sz(80, 24, { control: false }), viewer: { name: "qi" } }, { do: "screen", runner: 0, text: "s3" },
      { do: "send", stream: "q", end: true }, { do: "list" },
    ] },
  },
  {
    what: "not offered on a stable station; so many at most; a start that fails",
    c: { wall: 6, offered: false, steps: [
      { do: "view", stream: "a", terminal: sz(80, 24), viewer: { name: "ann" } }, { do: "list" },
    ] },
  },
  {
    what: "so many at most, and a start that fails",
    c: { wall: 7, startFails: { "2": "no runner" }, steps: [
      ...Array.from({ length: 18 }, (_, i) => ({ do: "view", stream: `v${i}`, terminal: sz(80, 24), viewer: { name: "ann" } })),
      { do: "list" },
      { do: "say", runner: 0, message: { op: "exit", code: 3, signal: null } },
      { do: "view", stream: "again", terminal: sz(80, 24), viewer: { name: "ann" } },
      { do: "workspaces" },
    ] },
  },
  {
    what: "taken up from before: its size as its runner said it, kept apart by workspace; detached as the station goes",
    c: { wall: 8, steps: [
      { do: "keep", id: "term-a", meta: { by: "ann", at: 100, cwd: "/w", workspace: "w1" }, cols: 120, rows: 40 },
      { do: "keep", id: "term-b", meta: { by: "bob", at: 101, cwd: "/x", workspace: "w2", chat: "c9" }, cols: 5000, rows: 40 },
      { do: "list" }, { do: "list", workspace: "w2" }, { do: "workspaces" },
      { do: "view", stream: "a", id: "term-a", terminal: sz(80, 24, { control: false }), viewer: { name: "cy" } },
      { do: "screen", runner: 0, text: "s", cols: 132, rows: 43 },
      { do: "view", stream: "b", id: "term-b", terminal: sz(80, 24), viewer: { name: "dee", workspace: "w2" } },
      { do: "screen", runner: 1, text: "s", cols: 132, rows: 43 },
      { do: "list" }, { do: "list", workspace: "w2" },
      { do: "detach" },
      { do: "send", stream: "a", end: true }, { do: "send", stream: "b", end: true },
    ] },
  },
];

test("a station's terminals: views, screens, typing and 接管, ending and taking up, as the TypeScript does them", { skip }, async () => {
  for (const { what, c } of TERMINAL_CASES) assert.deepEqual(await mb({ op: "terminals", ...c }), plain(await terminalsTs(c)), what);
});

// ── one login's run ──

/// A case's steps on the TypeScript's run of one login, its command's output given (no command started).
async function runTs(c: Json): Promise<Json> {
  const t = testClock();
  await t.adjust(c.now ?? 0);
  const fibers = new Fibers("mb-run", t.clock);
  const dir = fresh("run");
  const opened = join(dir, "l1.opened");
  let changed = 0;
  let drawn = 0;
  const run = new LoginRun({ id: "l1", command: c.command ?? ["gh", "auth", "login"], env: {}, cwd: "/home/a", shims: "/data/run/login-shims", opened, fibers, lang: c.lang ?? "en", changed: () => void changed++, drawn: () => void drawn++ });
  const snapshot = () => plain({
    state: run.state, step: run.step, url: run.url, loopback: run.loopback, code: run.code, codeUrl: run.codeUrl, waiting: run.waiting, paste: run.paste, echo: run.echo,
    error: run.error, endedAt: run.endedAt, timedOut: run.timedOut, hadBrowserStep: run.hadBrowserStep, relayed: run.relayed, secret: run.secret, active: run.active,
    startedAt: run.startedAt, expiresAt: run.expiresAt, screen: run.screen(), changed, drawn,
  });
  const results: Json[] = [];
  try {
    for (const s of c.steps) {
      let result: Json = null;
      switch (s.do) {
        case "say": run.output(s.text); break;
        case "file": writeFileSync(opened, s.text); break;
        case "advance": await t.adjust(s.ms); break;
        case "input": run.input(s.key !== undefined ? { key: s.key } : s.text !== undefined ? { text: s.text } : {}); break;
        case "cancel": run.cancel(); break;
        case "close": run.close(); break;
        case "paste": result = run.askPaste(s.on === true); break;
        case "answered": run.answeredNow(); break;
        case "relayed": run.relayedNow(); break;
        case "check":
          try {
            check(run, s.callback);
            result = "ok";
          } catch (e) {
            result = { status: (e as { status: number }).status, message: (e as Error).message };
          }
          break;
        case "quiet": {
          let got = false;
          void run.nextQuiet().then(() => void (got = true));
          await drain();
          result = got;
          break;
        }
        case "snapshot": result = snapshot(); break;
      }
      await drain();
      results.push(result);
    }
    return { results, final: snapshot(), log: [], defects: [] };
  } finally {
    run.close();
    await fibers.close();
  }
}

/// A run's case with the opened file at its place for the program (the TypeScript's own temp file stands for it).
const runCase = (c: Json) => ({ op: "run", opened: "/data/run/logins/l1.opened", ...c });

const RUN_CASES: { what: string; c: Json }[] = [
  {
    what: "gh's device code: Enter pressed for the person, its page opened, the code read; done said; then the browser came back",
    c: { now: 1000, steps: [
      { do: "say", text: "\u001b]11;?\u001b\\\u001b[6n" }, { do: "snapshot" },
      { do: "say", text: "! First copy your one-time code: 1A2B-C3D4\r\nPress Enter to open https://github.com/login/device in your browser... " },
      { do: "advance", ms: 499 }, { do: "snapshot" }, { do: "advance", ms: 1 }, { do: "snapshot" },
      { do: "file", text: "https://github.com/login/device\n" }, { do: "say", text: "\r\n" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "paste", on: true },
      { do: "say", text: "✓ Authentication complete.\r\n" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "relayed" }, { do: "snapshot" }, { do: "advance", ms: 180000 }, { do: "snapshot" },
    ] },
  },
  {
    what: "a question waits for the person; a secret asked is told; saying more stops the waiting",
    c: { steps: [
      { do: "say", text: "? Authenticate Git with your GitHub credentials? (Y/n) " }, { do: "quiet" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "say", text: "y\r\n" }, { do: "snapshot" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "say", text: "Password: " }, { do: "advance", ms: 500 }, { do: "snapshot" }, { do: "paste", on: true },
      { do: "input", text: "nope" }, { do: "cancel" }, { do: "snapshot" }, { do: "quiet" }, { do: "paste", on: false },
    ] },
  },
  {
    what: "a loopback page opened, the callback checked by method, path and state; relayed once",
    c: { steps: [
      { do: "file", text: "https://accounts.google.com/o/oauth2/auth?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&state=Ab1\n" },
      { do: "say", text: "Your browser has been opened to visit:\r\n\r\n    https://accounts.google.com/o/oauth2/auth?x=1\r\n" },
      { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "check", callback: { method: "POST", path: "/?state=Ab1", headers: {} } },
      { do: "check", callback: { method: "get", path: "/cb?state=Ab1", headers: {} } },
      { do: "check", callback: { method: "GET", path: "?state=Ab2", headers: {} } },
      { do: "check", callback: { method: "GET", path: "?state=Ab1", headers: {} } },
      { do: "relayed" }, { do: "check", callback: { method: "GET", path: "/?state=Ab1", headers: {} } }, { do: "snapshot" },
      { do: "say", text: "still waiting\r\n" }, { do: "advance", ms: 180000 }, { do: "snapshot" },
    ] },
  },
  {
    what: "a page to open and a code to paste: its card's field asked for, entered, refused and asked again",
    c: { now: 7, steps: [
      { do: "paste", on: true },
      { do: "say", text: "Visit https://app.devin.ai/auth/cli?state=x to sign in, then copy the code and paste it below.\r\n\r\n Code:\r\n ❭ " },
      { do: "advance", ms: 500 }, { do: "snapshot" }, { do: "paste", on: true }, { do: "paste", on: true }, { do: "snapshot" },
      { do: "answered" }, { do: "snapshot" }, { do: "paste", on: true }, { do: "snapshot" },
      { do: "say", text: "Code ABCD-EFGH\r\n" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "paste", on: false }, { do: "say", text: "enter the code ABCD-EFGH\r\n" }, { do: "advance", ms: 500 }, { do: "snapshot" },
    ] },
  },
  {
    what: "out of time; a link wrapped at the terminal's width; a line's \\r at a chunk's end",
    c: { now: 50, steps: [
      { do: "say", text: `Visit https://x.example/${"a".repeat(250)} now\r` }, { do: "say", text: "\nand more\r" }, { do: "say", text: "\r\n" },
      { do: "advance", ms: 500 }, { do: "snapshot" }, { do: "advance", ms: 900000 }, { do: "snapshot" },
    ] },
  },
  {
    what: "a stall where it said it is done (its overall time stands); a close ends it",
    c: { steps: [
      { do: "say", text: "Open https://x.example/login\r\n" }, { do: "advance", ms: 500 },
      { do: "say", text: "Logged in as octocat\r\n" }, { do: "advance", ms: 179999 }, { do: "snapshot" }, { do: "advance", ms: 1 }, { do: "snapshot" },
      { do: "close" }, { do: "say", text: "after\r\n" }, { do: "snapshot" },
    ] },
  },
  {
    what: "a menu redrawn in place: what it waits on read from the cursor's line",
    c: { lang: "zh", steps: [
      { do: "say", text: "? What account do you want to log into?  [Use arrows to move, type to filter]\r\n> GitHub.com\r\n  GitHub Enterprise Server\r\n\u001b[3A\u001b[0G" },
      { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "say", text: "\u001b[1B\u001b[2K  GitHub.com\r\n\u001b[2K> GitHub Enterprise Server\u001b[2A" }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "say", text: "\u001b[?1049h\u001b[H\u001b[2JPress ENTER to open in the browser..." }, { do: "advance", ms: 500 }, { do: "snapshot" },
      { do: "advance", ms: 500 }, { do: "snapshot" }, { do: "say", text: "x" }, { do: "advance", ms: 500 }, { do: "snapshot" },
    ] },
  },
];

test("one login's run on its command's output: what it reads of it, waits on, answers and how it ends, as the TypeScript", { skip }, async () => {
  for (const { what, c } of RUN_CASES) assert.deepEqual(await mb(runCase(c)), await runTs(c), what);
});

// ── the logins and their part of the station ──

/// A child of a login's as the fake `spawn` makes it: what it is written, its output and its close the case's.
type FakeChild = EventEmitter & { pid: number; stdout: EventEmitter; stderr: EventEmitter; stdin: Json; typed: string; closed: boolean };

/// A case's steps on the TypeScript's logins (index.ts) and their part (module.ts, the Layer itself on fakes of the
/// station's other parts), as the harness takes them on the program's.
async function loginsTs(c: Json): Promise<Json> {
  const t = testClock();
  await t.adjust(c.now ?? 0);
  const data: string = c.data;
  if (typeof c.history === "string") {
    mkdirSync(join(data, "logins"), { recursive: true });
    writeFileSync(join(data, "logins", "history.json"), c.history);
  }
  // the machine's: its commands spawned as fakes, the signals they are sent, the callback's server, the randoms
  const children: FakeChild[] = [];
  const spawned: Json[] = [];
  const signals: Json[] = [];
  const requests: Json[] = [];
  const real = { spawn: childProcess.spawn, request: http.request, random: Math.random, timeout: AbortSignal.timeout };
  const realPlatform = { terminalSoon: platform.terminalSoon, echoes: platform.echoes, descendants: platform.descendants, commands: platform.commands, listening: platform.listening, signalChildGroup: platform.signalChildGroup };
  const randoms = [...(c.randomNumbers ?? [])];
  (childProcess as any).spawn = (file: string, args: string[], options: Json) => {
    if (c.platform?.spawnFails) throw new Error(c.platform.spawnFails);
    const child = Object.assign(new EventEmitter(), { pid: 4000 + children.length, stdout: new EventEmitter(), stderr: new EventEmitter(), typed: "", closed: false }) as FakeChild;
    child.stdin = { destroyed: false, on: () => child.stdin, end: () => undefined, write: (text: string) => void (child.typed += text) };
    children.push(child);
    spawned.push({ file, args, cwd: options.cwd, env: options.env });
    process.nextTick(() => (c.platform?.startedFails ? child.emit("error", new Error(c.platform.startedFails)) : child.emit("spawn")));
    return child;
  };
  (http as any).request = (o: Json, answered: (res: EventEmitter) => void) => {
    const req = new EventEmitter() as EventEmitter & { end: (body: Buffer) => void };
    req.end = (body: Buffer) => {
      requests.push({ host: o.host, port: o.port, method: o.method, path: o.path, headers: o.headers, body: body.toString("base64") });
      setImmediate(() => {
        const a = c.answers?.[o.host] ?? {};
        if (a.code) return void req.emit("error", Object.assign(new Error(a.message ?? a.code), { code: a.code }));
        const res = Object.assign(new EventEmitter(), { statusCode: a.status, headers: a.headers ?? {} });
        answered(res);
        if (a.body) res.emit("data", Buffer.from(a.body, "base64"));
        res.emit("end");
      });
    };
    return req;
  };
  syncBuiltinESMExports();
  Math.random = () => randoms.shift() ?? 0.5;
  (AbortSignal as any).timeout = () => new AbortController().signal;
  Object.assign(platform, {
    terminalSoon: async () => c.platform?.terminal ?? null,
    echoes: async () => c.platform?.echoes ?? null,
    descendants: async () => [],
    commands: async () => c.platform?.commands ?? [],
    listening: async () => c.platform?.listening ?? null,
    signalChildGroup: (child: FakeChild, signal: string) => {
      signals.push({ child: child.pid - 4000, signal });
      process.nextTick(() => {
        if (child.closed) return;
        child.closed = true;
        child.emit("close", null, signal);
      });
    },
  });
  const realEnv = process.env;
  process.env = { ...c.env };
  // the station's other parts
  const notes: Json[] = [];
  const events: Json[] = [];
  const seen = new Set<string>();
  const cardsClosed: string[] = [];
  const asks: Json[] = [];
  const watchers: (() => void)[] = [];
  const tabs = new Map<string, string | null>();
  const openedTabs: Json[] = [];
  const closedTabs: string[] = [];
  let tabN = 0;
  let busHandler: (peer: string, request: Json, workspace: string | undefined) => Promise<Json> = async () => ({});
  let tools: Json[] = [];
  const hub: Json = {
    clock: t.clock,
    notify: (session: string, text: string) => {
      if ((c.notifyFails ?? []).includes(session)) throw new Error("no such session");
      notes.push([session, text]);
    },
    logins: null,
    store: { getSession: () => undefined },
  };
  const cloud = { memberships: () => [{ workspace: "w1", name: "W", peers: c.stations ?? [] }], rigs: () => [], rigOf: () => null, home: () => null, membership: () => null, unprotected: () => [], peersCurrent: true, state: { station: c.place?.station } };
  const browserOn = c.browser !== undefined && c.browser.available !== false;
  const services = Layer.mergeAll(
    Layer.succeed(Paths, { data, app: "" } as never),
    Layer.succeed(Store, {
      sessionWs: (s: string) => c.sessions?.[s]?.ws,
      getSession: (s: string) => c.sessions?.[s],
      closeLoginCards: (id: string) => {
        cardsClosed.push(id);
        const cards = c.cards?.[id];
        if (typeof cards === "string") throw new Error("the cards could not be closed");
        return cards ?? [];
      },
    } as never),
    Layer.succeed(Events, {
      machineLogins: (full: Json, lim: Json, key: string) => {
        const e = plain([key, full, lim]);
        const k = JSON.stringify(e);
        if (!seen.has(k)) (seen.add(k), events.push(e));
      },
      follow: () => undefined,
    } as never),
    Layer.succeed(Readers, { names: new Map(Object.entries(c.names ?? {})) } as never),
    Layer.succeed(ControlPlane, { state: cloud } as never),
    Layer.succeed(Parts, { routes: () => undefined, tools: (list: Json[]) => void (tools = list), streams: () => undefined } as never),
    Layer.succeed(Peers, {
      ask: async (station: string, request: Json) => {
        asks.push(plain([station, request]));
        const a = (c.bus ?? [])[asks.length - 1];
        if (a?.refused !== undefined) throw new BusRefused(a.refused);
        if (a?.error !== undefined) throw new Error(a.error);
        return a?.answer ?? null;
      },
      on: (_prefix: string, h: typeof busHandler) => void (busHandler = h),
    } as never),
    Layer.succeed(Agents, { hub, place: () => c.place ?? null, pages: () => c.pages ?? null, accounts: { logins: { attach: () => undefined } } } as never),
    Layer.succeed(Browser, {
      station: {
        available: () => browserOn,
        openTab: async (url: string) => {
          if (c.browser?.openFails) throw new Error(c.browser.openFails);
          const id = `t${++tabN}`;
          openedTabs.push([id, url]);
          tabs.set(id, null);
          return id;
        },
        hasTab: (id: string) => tabs.has(id),
        closeTab: async (id: string) => void (closedTabs.push(id), tabs.delete(id)),
        tabUrl: (id: string) => tabs.get(id) ?? null,
      },
    } as never),
    Layer.succeed(ScreenRegistry, { watch: (f: () => void) => (watchers.push(f), () => undefined) } as never),
  );
  let logins: Logins | null = null;
  const ready = Logins.prototype.ready;
  Logins.prototype.ready = function (this: Logins) {
    logins = this;
    return ready.call(this);
  };
  const scope = Effect.runSync(Scope.make());
  try {
    await Effect.runPromise(Layer.buildWithScope(LoginsLive.pipe(Layer.provide(services)), scope));
    Logins.prototype.ready = ready;
    const l = logins!;
    const tool = tools[0];
    // the logins by the order they were first told (`of: k`, `IDOF<k>` in what a step gives)
    const started: string[] = [];
    l.changes(({ login }) => void (started.includes(login) || started.push(login)));
    const put = (v: Json): Json =>
      typeof v === "string" ? v.replace(/IDOF(\d+)/g, (_, k) => started[Number(k)] ?? "") : Array.isArray(v) ? v.map(put) : v !== null && typeof v === "object" ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, put(x)])) : v;
    const asyncs: Record<string, Json> = {};
    const follows: Record<string, { seen: Json[]; stop: () => void }> = {};
    const idOf = (s: Json): string => s.id ?? started[s.of] ?? "";
    const outcome = (e: unknown): Json =>
      e instanceof RequestRefused ? { refused: [e.status, e.message] } : e instanceof BusRefused ? { busRefused: (e as Error).message } : { error: (e as Error).message };
    const later = (s: Json, f: () => Promise<Json>) => void f().then((ok) => void (asyncs[s.as] = { ok: plain(ok) }), (e) => void (asyncs[s.as] = outcome(e)));
    const results: Json[] = [];
    for (const given of c.steps) {
      const s = put(given);
      let result: Json = null;
      try {
        switch (s.do) {
          case "start": result = plain(await l.start(s.command, s.starter)); break;
          case "say": {
            if (s.opened !== undefined) {
              mkdirSync(join(data, "run", "logins"), { recursive: true });
              writeFileSync(join(data, "run", "logins", `${idOf(s)}.opened`), s.opened);
            }
            const child = children[s.child]!;
            (s.stream === 1 ? child.stderr : child.stdout).emit("data", Buffer.from(s.text));
            break;
          }
          case "exit": {
            const child = children[s.child]!;
            if (!child.closed) {
              child.closed = true;
              child.emit("close", s.code ?? null, s.signal ?? null);
            }
            break;
          }
          case "advance": await t.adjust(s.ms); break;
          case "get": result = plain(l.get(idOf(s))); break;
          case "logins": result = plain(l.logins()); break;
          case "history": result = plain(l.history()); break;
          case "starter": {
            const st = l.starterOf(idOf(s));
            result = st === null ? null : { by: st.by, workspace: st.workspace ?? null, chat: st.chat ?? null, chatTitle: st.chatTitle ?? null };
            break;
          }
          case "cancel": result = plain(l.cancel(idOf(s), s.by)); break;
          case "input": l.input(idOf(s), { text: s.text, key: s.key }); result = "ok"; break;
          case "answer": result = plain(l.answer(idOf(s), s.text, s.by)); break;
          case "paste": result = plain(l.paste(idOf(s), s.on === true)); break;
          case "openPage": { const id = idOf(s); later(s, () => l.openPage(id, s.by)); break; }
          case "callback": { const id = idOf(s); later(s, () => l.callback(id, s.callback, s.by)); break; }
          case "tool": later(s, () => tool.run(s.session, s.args)); break;
          case "peer": later(s, () => busHandler(s.peer, s.request, s.workspace ?? undefined)); break;
          case "await": result = asyncs[s.as] ?? { pending: true }; break;
          case "follow": {
            const seenScreens: Json[] = [];
            follows[s.as] = { seen: seenScreens, stop: l.follow(idOf(s), (screen) => void seenScreens.push(plain(screen))) };
            break;
          }
          case "unfollow": follows[s.as]?.stop(); break;
          case "slackPage": result = plain(hub.logins.page(idOf(s))); break;
          case "slackAnswer": hub.logins.answer(idOf(s), s.code, s.by); result = "ok"; break;
          case "tabGone": tabs.delete(s.tab); for (const f of [...watchers]) f(); break;
          case "tabUrl": tabs.set(s.tab, s.url ?? null); for (const f of [...watchers]) f(); break;
          case "heard": result = l.heard(idOf(s)); break;
          case "close": await l.close(); break;
        }
      } catch (e) {
        result = outcome(e);
      }
      await drain();
      results.push(result);
    }
    await l.written();
    await drain();
    const shimsDir = join(data, "run", "login-shims");
    const shims: Record<string, string> = {};
    for (const name of ["browser", "open", "xdg-open", "osascript"]) {
      try {
        shims[join(shimsDir, name).slice(shimsDir.length + 1)] = readFileSync(join(shimsDir, name), "utf8");
      } catch {}
    }
    let history: string | null = null;
    try {
      history = readFileSync(join(data, "logins", "history.json"), "utf8");
    } catch {}
    return plain({
      results,
      children: children.map((ch, k) => ({ spawned: spawned[k], typed: ch.typed })),
      signals,
      requests,
      tabs: { opened: openedTabs, closed: closedTabs },
      notes,
      events,
      cardsClosed,
      asks,
      follows: Object.fromEntries(Object.entries(follows).map(([k, v]) => [k, v.seen])),
      history,
      shims,
      defects: [],
    });
  } finally {
    Logins.prototype.ready = ready;
    await Effect.runPromise(Scope.close(scope, Exit.void));
    process.env = realEnv;
    (childProcess as any).spawn = real.spawn;
    (http as any).request = real.request;
    syncBuiltinESMExports();
    Math.random = real.random;
    (AbortSignal as any).timeout = real.timeout;
    Object.assign(platform, realPlatform);
  }
}

const GH = "/opt/cli/gh";
const who = { email: "ann@x", name: "Ann" };
const starter = (more: Json = {}) => ({ by: who, workspace: "w1", chat: "c1", chatTitle: "Deploy", ...more });
/// The station around the logins: its sessions, their workspaces and cards, its place and pages, the workspace's stations.
const STATION: Json = {
  sessions: { c1: { createdBy: "ann@x", ws: "w1" }, c2: { createdBy: "bob@x", ws: "w2" }, c3: { createdBy: "cy@x" } },
  names: { "ann@x": "Ann", "bob@x": "Bob" },
  place: { station: "s1", workspace: "w1" },
  pages: { origin: "https://app.still.fail", workspace: "w1", station: "s1" },
  stations: [{ id: "s2", name: "Box" }, { id: "s3", name: "" }],
  cards: { },
};
const GH_DEVICE = "! First copy your one-time code: 1A2B-C3D4\r\nPress Enter to open https://github.com/login/device in your browser... ";

const LOGIN_CASES: { what: string; c: Json }[] = [
  {
    what: "gh's device code: started for its chat, Enter pressed for the person, its page and code read, followed, done; its chat and the carded ones told",
    c: { now: 1_700_000_000_000, randomNumbers: [0.123456789], cards: { CARDS: ["c2"] }, steps: [
      { do: "start", command: [GH, "auth", "login", "--web"], starter: starter() },
      { do: "follow", of: 0, as: "f" },
      { do: "say", of: 0, child: 0, text: "\u001b]11;?\u001b\\\u001b[6n" },
      { do: "say", of: 0, child: 0, text: GH_DEVICE }, { do: "advance", ms: 500 },
      { do: "say", of: 0, child: 0, text: "\r\n", opened: "https://github.com/login/device\n" }, { do: "advance", ms: 500 },
      { do: "get", of: 0 }, { do: "slackPage", of: 0 }, { do: "logins" }, { do: "starter", of: 0 },
      { do: "tool", session: "c1", args: { id: "IDOF0" }, as: "look" }, { do: "await", as: "look" },
      { do: "say", of: 0, child: 0, text: "✓ Authentication complete.\r\n" }, { do: "advance", ms: 100 },
      { do: "exit", child: 0, code: 0 }, { do: "get", of: 0 }, { do: "unfollow", as: "f" }, { do: "history" },
      { do: "cancel", of: 0 }, { do: "input", of: 0, text: "x" },
    ] },
  },
  {
    what: "one command at a time; what is no command refused; the tool starts one, answers its prompt and waits for it to settle",
    c: { now: 5_000, randomNumbers: [0.25, 0.75, 0.33], steps: [
      { do: "start", command: `${GH} auth login`, starter: starter() },
      { do: "start", command: [GH, "auth", "login"], starter: starter({ chat: "c2" }) },
      { do: "start", command: `${GH} "open`, starter: starter() }, { do: "start", command: [], starter: starter() }, { do: "start", command: [GH, ""], starter: starter() },
      { do: "start", command: "x".repeat(2001), starter: starter() }, { do: "start", command: ["FOO=1"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "? Authenticate Git with your GitHub credentials? (Y/n) " }, { do: "advance", ms: 500 }, { do: "get", of: 0 },
      { do: "tool", session: "c1", args: { id: "IDOF0", key: "Enter" }, as: "key" }, { do: "heard", of: 0 }, { do: "await", as: "key" },
      { do: "say", of: 0, child: 0, text: "y\r\n? What is your preferred protocol? HTTPS\r\n> " }, { do: "advance", ms: 500 }, { do: "await", as: "key" },
      { do: "tool", session: "c1", args: { id: "IDOF0", key: "esc" }, as: "bad" }, { do: "tool", session: "c1", args: { id: "nope" }, as: "none" },
      { do: "tool", session: "c1", args: { id: "IDOF0", input: "ssh" }, as: "typed" }, { do: "advance", ms: 5000 }, { do: "await", as: "typed" },
      { do: "await", as: "bad" }, { do: "await", as: "none" },
      { do: "tool", session: "c1", args: {}, as: "nothing" }, { do: "await", as: "nothing" },
      { do: "tool", session: "c1", args: { command: [GH, "auth", "refresh"] }, as: "new" }, { do: "advance", ms: 15000 }, { do: "await", as: "new" },
      { do: "input", of: 0, key: "Esc" }, { do: "input", of: 0 }, { do: "input", of: 0, text: "x".repeat(10001) }, { do: "input", of: 0, key: "Up" },
      { do: "tool", session: "c1", args: { id: "IDOF0", cancel: true }, as: "cancel" }, { do: "await", as: "cancel" },
      { do: "logins" },
    ] },
  },
  {
    what: "a secret asked: nothing typed; a code to paste from the page: the card's field, entered, refused, asked again; failed with what it said",
    c: { now: 9, randomNumbers: [0.5, 0.6], platform: { echoes: false }, steps: [
      { do: "start", command: ["/opt/cli/vault", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "Password: " }, { do: "advance", ms: 500 }, { do: "get", of: 0 },
      { do: "input", of: 0, text: "hunter2" }, { do: "paste", of: 0, on: true },
      { do: "tool", session: "c1", args: { id: "IDOF0" }, as: "look" }, { do: "await", as: "look" },
      { do: "cancel", of: 0, by: { email: "bob@x", name: "Bob" } },
      { do: "start", command: ["/opt/cli/devin", "auth", "login"], starter: starter({ chat: "c3" }) },
      { do: "answer", of: 1, text: "abc" },
      { do: "say", of: 1, child: 1, text: "Visit https://app.devin.ai/auth/cli?state=x to sign in, then copy the code and paste it below.\r\n\r\n Code:\r\n ❭ " },
      { do: "advance", ms: 500 },
      { do: "tool", session: "c3", args: { id: "IDOF1", paste: true }, as: "paste" }, { do: "await", as: "paste" },
      { do: "slackPage", of: 1 },
      { do: "answer", of: 1, text: "  " }, { do: "answer", of: 1, text: "a\nb" }, { do: "answer", of: 1, text: " CODE-123 ", by: { email: "cy@x", name: "Cy" } },
      { do: "answer", of: 1, text: "again" }, { do: "paste", of: 1, on: true }, { do: "get", of: 1 },
      { do: "slackAnswer", of: 1, code: "CODE-456", by: { email: "cy@x", name: "Cy" } },
      { do: "say", of: 1, child: 1, text: "Error: that code was not right\r\n" },
      { do: "exit", child: 1, code: 1 }, { do: "get", of: 1 }, { do: "logins" },
    ] },
  },
  {
    what: "a loopback page: the callback checked, relayed once to where the command listens, its answer given back",
    c: { now: 10, randomNumbers: [0.1], platform: { listening: ["::1"] }, answers: { "::1": { code: "ECONNREFUSED", message: "connect ECONNREFUSED ::1:8085" }, "127.0.0.1": { status: 200, headers: { "content-type": "text/html", connection: "close", "x-a": "b" }, body: b64("<p>done</p>") } }, steps: [
      { do: "start", command: ["/opt/cli/gcloud", "auth", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "Your browser has been opened to visit:\r\n\r\n    https://accounts.google.com/o/oauth2/auth?x=1\r\n", opened: "https://accounts.google.com/o/oauth2/auth?response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&state=Ab1\n" },
      { do: "advance", ms: 500 }, { do: "get", of: 0 },
      { do: "callback", of: 0, callback: { method: "GET", path: "/?state=nope", headers: {} }, as: "wrong" },
      { do: "callback", of: 0, callback: { method: "GET", path: "/?state=Ab1&code=c", headers: { Host: "localhost:8085", Connection: "keep-alive", "Content-Length": "3", Cookie: "a=b" }, body: b64("xyz") }, by: who, as: "right" },
      { do: "await", as: "wrong" }, { do: "await", as: "right" },
      { do: "callback", of: 0, callback: { method: "GET", path: "/?state=Ab1", headers: {} }, as: "again" }, { do: "await", as: "again" },
      { do: "get", of: 0 }, { do: "exit", child: 0, code: 0 }, { do: "get", of: 0 },
    ] },
  },
  {
    what: "a callback where the machine cannot tell, or nothing listens; a request that broke",
    c: { now: 11, randomNumbers: [0.1, 0.2], platform: { listening: [] }, answers: { "127.0.0.1": { code: "ECONNRESET", message: "socket hang up" } }, steps: [
      { do: "start", command: ["/opt/cli/gcloud", "auth", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "go\r\n", opened: "https://accounts.google.com/o/oauth2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A9%2Fcb&state=s&response_mode=form_post\n" },
      { do: "advance", ms: 500 },
      { do: "callback", of: 0, callback: { method: "GET", path: "/cb", headers: {} }, as: "method" },
      { do: "callback", of: 0, callback: { method: "POST", path: "/cb", headers: {}, body: b64("state=s") }, as: "none" },
      { do: "await", as: "method" }, { do: "await", as: "none" },
    ] },
  },
  {
    what: "its page in the station's browser: opened once, followed as it comes and goes, closed as it ends; refused where it cannot be",
    c: { now: 12, randomNumbers: [0.1, 0.2, 0.3], browser: {}, steps: [
      { do: "start", command: [GH, "auth", "login"], starter: starter() },
      { do: "openPage", of: 0, as: "early" }, { do: "await", as: "early" },
      { do: "say", of: 0, child: 0, text: GH_DEVICE }, { do: "advance", ms: 500 },
      { do: "say", of: 0, child: 0, text: "\r\n", opened: "https://github.com/login/device\n" }, { do: "advance", ms: 500 },
      { do: "get", of: 0 }, { do: "openPage", of: 0, by: who, as: "open" }, { do: "await", as: "open" }, { do: "get", of: 0 },
      { do: "openPage", of: 0, as: "again" }, { do: "await", as: "again" },
      { do: "tabUrl", tab: "t1", url: "https://github.com/login/device/success" }, { do: "get", of: 0 },
      { do: "tabGone", tab: "t1" }, { do: "get", of: 0 },
      { do: "openPage", of: 0, as: "third" }, { do: "await", as: "third" },
      { do: "exit", child: 0, code: 0 }, { do: "openPage", of: 0, as: "ended" }, { do: "await", as: "ended" },
      { do: "start", command: [GH, "auth", "status"], starter: starter() }, { do: "openPage", of: 1, as: "nothing" }, { do: "await", as: "nothing" },
    ] },
  },
  {
    what: "no browser here; one whose tabs do not open",
    c: { now: 13, randomNumbers: [0.4, 0.4], browser: { openFails: "Chrome went away" }, steps: [
      { do: "start", command: [GH, "auth", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "Open https://x.example/login\r\n" }, { do: "advance", ms: 500 },
      { do: "openPage", of: 0, as: "fails" }, { do: "await", as: "fails" }, { do: "get", of: 0 },
    ] },
  },
  {
    what: "out of time, stalled once nobody is needed, put away after a while and past so many; the history kept and read back",
    c: { now: 20, randomNumbers: Array.from({ length: 26 }, (_, i) => (i + 1) / 64), platform: { commands: ["git-credential-osxkeychain"] },
      history: JSON.stringify([{ id: "old1", name: "env", command: ["env", "HOME=/x", "/x/bin/devin", "auth"], state: "done", waiting: false, by: who, startedAt: 1, expiresAt: 2, endedAt: 3 }, { name: "no id" }, 5, null, { id: "old2", command: "not words", state: "failed" }]),
      steps: [
        { do: "history" },
        { do: "start", command: [GH, "auth", "login"], starter: starter() }, { do: "advance", ms: 900000 }, { do: "get", of: 0 },
        { do: "start", command: ["/opt/cli/npm", "login"], starter: starter() },
        { do: "say", of: 1, child: 1, text: "Open https://x.example/login\r\n" }, { do: "advance", ms: 180000 }, { do: "get", of: 1 },
        { do: "advance", ms: 600000 }, { do: "get", of: 0 }, { do: "logins" },
        ...Array.from({ length: 22 }, (_, i) => ({ do: "start", command: ["/opt/cli/x", `n${i}`], starter: starter() })),
        ...Array.from({ length: 22 }, (_, i) => ({ do: "cancel", of: i + 2 })),
        { do: "logins" }, { do: "get", of: 2 },
      ] },
  },
  {
    what: "a command that cannot be started, and one that failed to",
    c: { now: 30, randomNumbers: [0.9], platform: { spawnFails: "spawn EACCES" }, steps: [{ do: "start", command: [GH, "auth", "login"], starter: starter() }, { do: "history" }] },
  },
  {
    what: "run in a terminal of its own; a callback whose request broke",
    c: { now: 32, randomNumbers: [0.3], platform: { terminal: ["/usr/bin/script", ["-q", "/dev/null", GH, "auth", "login"]], listening: ["127.0.0.1", "::1"] }, answers: { "127.0.0.1": { code: "ECONNRESET", message: "socket hang up" } }, steps: [
      { do: "start", command: ["GH_HOST=github.com", "TERM=dumb", GH, "auth", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "go\r\n", opened: "https://github.com/login/oauth/authorize?redirect_uri=http://127.0.0.1:4321/cb&state=st\n" }, { do: "advance", ms: 500 },
      { do: "callback", of: 0, callback: { method: "GET", path: "/cb?state=st", headers: {} }, as: "broke" }, { do: "await", as: "broke" }, { do: "get", of: 0 },
    ] },
  },
  {
    what: "one that did not start",
    c: { now: 31, randomNumbers: [0.9], platform: { startedFails: "spawn /opt/cli/gh ENOENT" }, steps: [{ do: "start", command: [GH, "auth", "login"], starter: starter() }] },
  },
  {
    what: "asking again after the person's browser step: its agent told once a time, not where its call waits; ended told to another station's agent",
    c: { now: 40, randomNumbers: [0.2, 0.3], bus: [{ answer: {} }, { refused: "no such session" }], notifyFails: ["c9"], steps: [
      { do: "start", command: ["/opt/cli/az", "login"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code GQGFJ2QXM to authenticate.\r\n" },
      { do: "advance", ms: 500 },
      { do: "say", of: 0, child: 0, text: "Select a subscription [1]: " }, { do: "advance", ms: 500 },
      { do: "say", of: 0, child: 0, text: "\r\n" }, { do: "advance", ms: 500 },
      { do: "say", of: 0, child: 0, text: "Select a tenant [1]: " }, { do: "advance", ms: 500 },
      { do: "start", command: ["/opt/cli/az", "account", "show"], starter: { by: who, workspace: "w1", chat: null, chatTitle: "Their chat", peer: { station: "s2", session: "p1" } } },
      { do: "say", of: 1, child: 1, text: "Open https://x.example/a\r\n" }, { do: "advance", ms: 500 },
      { do: "say", of: 1, child: 1, text: "Pick one (y/n): " }, { do: "advance", ms: 500 },
      { do: "exit", child: 1, code: 2 },
      { do: "start", command: ["/opt/cli/az", "logout"], starter: starter({ chat: "c9" }) }, { do: "exit", child: 2, code: 0 },
    ] },
  },
  {
    what: "another station's agent logging this one in, and this one's told of a login there; the transport's refusals",
    c: { now: 50, randomNumbers: [0.7], steps: [
      { do: "peer", peer: "s2", request: { method: "login.call", session: "p1", by: { email: "zed@x", name: 7 }, chatTitle: "There", args: { command: [GH, "auth", "login"] } }, workspace: "w1", as: "call" },
      { do: "say", of: 0, id: "IDOF0", child: 0, text: GH_DEVICE }, { do: "advance", ms: 500 },
      { do: "say", child: 0, text: "\r\n" }, { do: "advance", ms: 500 }, { do: "await", as: "call" },
      { do: "peer", peer: "s3", request: { method: "login.call", session: "q", args: { id: "IDOF0" } }, as: "notMine" }, { do: "await", as: "notMine" },
      { do: "peer", peer: "s2", request: { method: "login.call", session: "p1", args: { id: "IDOF0", cancel: true } }, as: "mine" }, { do: "await", as: "mine" },
      { do: "peer", peer: "s2", request: { method: "login.call", args: "x" }, as: "noCommand" }, { do: "await", as: "noCommand" },
      { do: "peer", peer: "s2", request: { method: "login.told", session: "c1", login: "L9", ended: true, text: "ended there" }, as: "told" }, { do: "await", as: "told" },
      { do: "peer", peer: "s2", request: { method: "login.told", session: "zz", text: "x" }, as: "noSession" }, { do: "await", as: "noSession" },
      { do: "peer", peer: "s2", request: { method: "login.what" }, as: "what" }, { do: "await", as: "what" },
      { do: "peer", peer: "s2", request: null, as: "nothing" }, { do: "await", as: "nothing" },
    ] },
  },
  {
    what: "the tool on another station: asked over the transport, its answer told; one from before; one not named",
    c: { now: 60, bus: [{ answer: { text: "there it is" } }, { refused: "unknown method login.call" }, { refused: "busy" }, { answer: { nope: 1 } }, { error: "timed out" }], steps: [
      { do: "tool", session: "c1", args: { station: " Box ", command: [GH, "auth", "login"] }, as: "a" }, { do: "await", as: "a" },
      { do: "tool", session: "c2", args: { station: "s3", id: "x" }, as: "b" }, { do: "await", as: "b" },
      { do: "tool", session: "c1", args: { station: "box", id: "x" }, as: "c" }, { do: "await", as: "c" },
      { do: "tool", session: "zz", args: { station: "s2", id: "x" }, as: "d" }, { do: "await", as: "d" },
      { do: "tool", session: "c1", args: { station: "s2", id: "x" }, as: "e" }, { do: "await", as: "e" },
      { do: "tool", session: "c1", args: { station: "Nowhere", id: "x" }, as: "f" }, { do: "await", as: "f" },
      { do: "tool", session: "c1", args: { station: "  " }, as: "g" }, { do: "await", as: "g" },
    ] },
  },
  {
    what: "the logins closing with the station: each ended, its command stopped, the record written",
    c: { now: 70, randomNumbers: [0.1, 0.2], steps: [
      { do: "start", command: [GH, "auth", "login"], starter: starter() }, { do: "start", command: ["/opt/cli/x"], starter: starter() },
      { do: "say", of: 0, child: 0, text: "working\r\n" }, { do: "close" }, { do: "advance", ms: 5000 }, { do: "logins" },
    ] },
  },
];

test("the logins and their part: commands run and read, prompts answered, pages, callbacks, cards and notices, as the TypeScript", { skip }, async () => {
  const scrubbed = privateFn("logins/index.ts", "SCRUBBED", {}) as unknown as string[];
  const { startEnv } = await import("../src/ops/agent-env.ts");
  for (const { what, c } of LOGIN_CASES) {
    const data = realpathSync(fresh("logins"));
    const home = join(data, "home");
    mkdirSync(home);
    const given = { HOME: home, PATH: "/usr/bin:/bin", LANG: "en_US.UTF-8", SSH_TTY: "/dev/ttys9", CODEX_HOME: "/x" };
    const realEnv = process.env;
    process.env = { ...given };
    const env = startEnv(scrubbed);
    process.env = realEnv;
    const randoms = (c.randomNumbers ?? []).map((n: number) => n.toString(36).slice(2, 6));
    const full = { ...STATION, ...c, data, env: given };
    const ts = await loginsTs(full);
    const said = await mb({ op: "logins", ...full, env, randoms });
    assert.deepEqual(said, ts, what);
  }
});
