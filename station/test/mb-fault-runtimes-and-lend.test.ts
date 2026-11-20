// The MoonBit station (`stillfail-reader run`, no Node on its PATH) through the faults the TypeScript's own tests hold
// for its runtimes, its lent logins and its chats' hand-overs (hub-codex-bad-request, agy, move-accounts,
// lend-renews-behind, chat-handover-usage, chat-handover-flush): a Codex turn refused with a bare `{"detail":"Bad
// Request"}` never tried again by itself, its thread let go and taken up again from its rollout as it is asked to go
// on, and started afresh (its jobs kept, the account's other thread untouched) where the one taken up again is refused
// too; an Antigravity CLI conversation the station kept but its CLI no longer has never loaded, the chat going on
// afresh; a chat moved to another station with what it needs lending its Claude login there (shared with the two
// stations alone, hosted here still, the other chats on it going on), taken back as it comes home; a Codex login lent
// in its early-renewal window renewed first by the Codex running on it here, and lent as it is once that renewal
// outlasts the lend's bound (10 s), the renewal going on behind; and a chat's calls going with it to another station
// and back over real iroh, each once on each side, a hand-over the station it goes to cannot write taking nothing
// there and leaving the chat here working. Fake runtimes are `/bin/sh` and `/usr/bin/curl` alone; under
// scripts/native.ts run (mesh runner archive-rs reader launcher).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createSocket } from "node:dgram";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors and the fake runtimes are Unix's"
      : runner === "" || !existsSync(runner)
        ? "no stillfail-runner (run under scripts/native.ts run runner)"
        : !existsSync("/usr/bin/curl")
          ? "no /usr/bin/curl for the fake runtimes"
          : false;

const dirs: string[] = [];
// (short, and real: a runner's Unix socket is at most 104 bytes on macOS, and Claude's project of a workspace is its
// path as given, which on macOS /tmp is not)
const base = process.platform === "darwin" ? realpathSync("/tmp") : realpathSync(tmpdir());
const fresh = (what: string) => {
  const dir = mkdtempSync(join(base, `sfrl-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
after(async () => {
  for (const c of closers.splice(0).reverse()) {
    try {
      c();
    } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  // (what a run left: its agents' runners and their process groups, by what their files say)
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
      try {
        const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
        if (typeof info.pgid === "number") try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (typeof info.runner === "number") try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) {
    try { chmodSync(d, 0o755); } catch {}
    rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
  }
});

/// Looked at until `look` gives something (real processes: every 50 ms), or failing with `what` after `ms`.
async function given<T>(
  what: string,
  look: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  detail: () => string | Promise<string> = () => "",
  ms = 20_000,
): Promise<T> {
  const end = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await look();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > end) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}; ${await detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

/// `ms` of the processes' own time gone by: what a real process would have done by itself meanwhile, it has.
const passed = (ms: number) => {
  const since = Date.now();
  return given(`${ms} ms gone by`, () => Date.now() - since >= ms, () => "", ms + 5_000);
};

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};
const linesOf = (p: string): string[] => (existsSync(p) ? readFileSync(p, "utf8").split("\n").filter((l) => l !== "") : []);

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "lsof", "pwd", "touch", "date"];

/// A PATH of the tools a station runs and `scripts` (the fake runtimes), Node not among them.
function toolsPath(scripts: Record<string, string> = {}): string {
  const dir = fresh("path");
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = search.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  for (const [name, script] of Object.entries(scripts)) {
    writeFileSync(join(dir, name), script);
    chmodSync(join(dir, name), 0o755);
  }
  assert.equal(existsSync(join(dir, "node")), false, "no Node on PATH");
  return dir;
}

// ── the fake runtimes: /bin/sh and curl, what each was asked noted in FAKE_OUT ──

/// `chat_post` through the agents' door, as the session `$tok` names: `$1` its text (all_done).
const POST_SH = `post() {
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $tok" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Fault chat","text":"'"$1"'","kind":"all_done","done":"replied '"$1"'"}}}' >> "$FAKE_OUT/posts.log"
  printf '\\n' >> "$FAKE_OUT/posts.log"
}
next() { n=$(( $(/bin/cat "$FAKE_OUT/$1" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAKE_OUT/$1"; }
`;

/// A fake Claude Code (stream-json in and out): each prompt posts `<FAKE_STATION>-reply-<n>` to the thread it was
/// asked in, `n` counting the session's prompts across its processes and stations, and writes a call of its own to its
/// transcript where Claude Code keeps one (the cwd's project of CLAUDE_CONFIG_DIR): its id `<FAKE_STATION>-<sid>-<n>`,
/// `n`·100 tokens in and `n` out. The token it was started with is noted (`tokens`).
const fakeClaude = `#!/bin/sh
${POST_SH}
mode=new; case " $* " in *" --resume "*) mode=resume ;; esac
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
[ -n "$sid" ] && printf '%s %s %s\\n' "$FAKE_STATION" "$mode" "$sid" >> "$FAKE_OUT/started"
[ -n "$sid" ] && printf '%s %s %s\\n' "$FAKE_STATION" "$sid" "\${CLAUDE_CODE_OAUTH_TOKEN:-none}" >> "$FAKE_OUT/tokens"
project=$(pwd -P | /usr/bin/sed 's/[^A-Za-z0-9]/-/g')
transcript="$CLAUDE_CONFIG_DIR/projects/$project/$sid.jsonl"
/bin/mkdir -p "$CLAUDE_CONFIG_DIR/projects/$project"
url=$(printf '%s' "$cfg" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
tok="$STILLFAIL_MCP_TOKEN"
say() { printf '%s\\n' "$1"; }
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  next "n-$sid"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(/bin/cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  at=$(/bin/date -u +%Y-%m-%dT%H:%M:%S.000Z)
  printf '{"type":"assistant","timestamp":"%s","isSidechain":false,"sessionId":"%s","message":{"id":"%s-%s-%s","model":"claude-sonnet-4-5","usage":{"input_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":%s}}}\\n' "$at" "$sid" "$FAKE_STATION" "$sid" "$n" "$((n * 100))" "$n" >> "$transcript"
  post "$FAKE_STATION-reply-$n"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;

/// A fake Codex app-server (`codex app-server`, its JSON-RPC a line each): what it is asked noted in `codex.log` (its
/// pid, the method, the thread), each turn's request kept (`turn-<k>.json`). A turn posts `codex-reply-<k>` unless
/// `refuse` is there (taken: that turn alone), which Codex's backend refuses with a bare `{"detail":"Bad Request"}`.
/// `account/read` with refreshToken renews the login: `renewed-auth.json` put in CODEX_HOME, at once, or once
/// `renew-release` is there while `renew-hold` is.
const fakeCodex = `#!/bin/sh
${POST_SH}
case "$1" in
  --version) echo "codex-cli 0.200.0"; exit 0 ;;
  app-server) ;;
  *) exit 0 ;;
esac
pid=$$
note() { printf '%s %s\\n' "$pid" "$1" >> "$FAKE_OUT/codex.log"; }
note "start \${CODEX_HOME:-none}"
say() { printf '%s\\n' "$1"; }
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/^{"id":\\([^,]*\\),"method".*/\\1/p')
  m=$(printf '%s' "$line" | /usr/bin/sed -n 's/^{\\("id":[^,]*,\\)\\{0,1\\}"method":"\\([^"]*\\)".*/\\2/p')
  tid=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"threadId":"\\([^"]*\\)".*/\\1/p')
  case "$m" in
    initialize) say '{"id":'"$id"',"result":{"userAgent":"fake-codex/0.200.0 (fake)"}}' ;;
    thread/start|thread/resume)
      if [ "$m" = thread/start ]; then next threads; tid="th-$n"; fi
      note "$m $tid"
      printf '%s' "$line" | /usr/bin/sed -n 's/.*"mcp_servers.stillfail.url":"\\([^"]*\\)".*/\\1/p' > "$FAKE_OUT/url-$tid"
      printf '%s' "$line" | /usr/bin/sed -n 's/.*"Authorization":"Bearer \\([^"]*\\)".*/\\1/p' > "$FAKE_OUT/tok-$tid"
      say '{"id":'"$id"',"result":{"thread":{"id":"'"$tid"'"}}}' ;;
    turn/start)
      next turns; k=$n
      note "turn/start $tid tu-$k"
      printf '%s\\n' "$line" > "$FAKE_OUT/turn-$k.json"
      say '{"id":'"$id"',"result":{"turn":{"id":"tu-'"$k"'","status":"inProgress","items":[]}}}'
      say '{"method":"turn/started","params":{"threadId":"'"$tid"'","turn":{"id":"tu-'"$k"'","status":"inProgress","items":[]}}}'
      if [ -f "$FAKE_OUT/refuse" ]; then
        /bin/rm -f "$FAKE_OUT/refuse"
        note "refused $tid tu-$k"
        say '{"method":"turn/completed","params":{"threadId":"'"$tid"'","turn":{"id":"tu-'"$k"'","status":"failed","items":[],"error":{"message":"{\\"detail\\":\\"Bad Request\\"}","codexErrorInfo":"other"}}}}'
        continue
      fi
      to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
      if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$tid"; else to=$(/bin/cat "$FAKE_OUT/to-$tid" 2>/dev/null); fi
      url=$(/bin/cat "$FAKE_OUT/url-$tid"); tok=$(/bin/cat "$FAKE_OUT/tok-$tid")
      say '{"method":"item/started","params":{"threadId":"'"$tid"'","turnId":"tu-'"$k"'","item":{"type":"agentMessage","id":"it-'"$k"'","text":""}}}'
      post "codex-reply-$k"
      say '{"method":"item/completed","params":{"threadId":"'"$tid"'","turnId":"tu-'"$k"'","item":{"type":"agentMessage","id":"it-'"$k"'","text":"posted"}}}'
      say '{"method":"turn/completed","params":{"threadId":"'"$tid"'","turn":{"id":"tu-'"$k"'","status":"completed","items":[]}}}' ;;
    thread/unsubscribe) note "thread/unsubscribe $tid"; say '{"id":'"$id"',"result":{"status":"unsubscribed"}}' ;;
    mcpServerStatus/list)
      if [ -n "$tid" ]; then say '{"id":'"$id"',"result":{"data":[{"name":"stillfail","runtimeStatus":"connected","tools":{}}],"nextCursor":null}}'
      else say '{"id":'"$id"',"result":{"data":[],"nextCursor":null}}'; fi ;;
    model/list) say '{"id":'"$id"',"result":{"data":[{"id":"gpt-6.2-sol","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]}],"nextCursor":null}}' ;;
    account/read)
      case "$line" in
        *'"refreshToken":true'*)
          note "renew asked"
          (
            if [ -f "$FAKE_OUT/renew-hold" ]; then while [ ! -f "$FAKE_OUT/renew-release" ]; do /bin/sleep 0.05; done; fi
            /bin/cp "$FAKE_OUT/renewed-auth.json" "$CODEX_HOME/auth.json"
            note "renewed"
            say '{"id":'"$id"',"result":{"account":{"type":"chatgpt","email":"plus@example.com","planType":"plus"},"requiresOpenaiAuth":true}}'
          ) & ;;
        *) say '{"id":'"$id"',"result":{"account":{"type":"chatgpt","email":"plus@example.com","planType":"plus"},"requiresOpenaiAuth":true}}' ;;
      esac ;;
    *) if [ -n "$id" ]; then say '{"id":'"$id"',"result":{}}'; fi ;;
  esac
done
wait
`;

/// A fake Antigravity CLI (`agy acp --gemini-dir …`, ACP's JSON-RPC a line each): each conversation it opens kept in
/// its store (`<gemini-dir>/antigravity-cli/conversations/<id>.db`), one it does not keep refused to load; what it is
/// asked noted in `agy.log`, each prompt posting `agy-reply-<k>`.
const fakeAgy = `#!/bin/sh
${POST_SH}
printf '%s %s\\n' "$$" "argv $*" >> "$FAKE_OUT/agy.log"
[ "$1" = acp ] || { echo "gemini-3.5-flash"; exit 0; }
gem=""
while [ $# -gt 0 ]; do [ "$1" = --gemini-dir ] && gem="$2"; shift; done
convs="$gem/antigravity-cli/conversations"
/bin/mkdir -p "$convs"
pid=$$
note() { printf '%s %s\\n' "$pid" "$1" >> "$FAKE_OUT/agy.log"; }
note "start"
say() { printf '%s\\n' "$1"; }
models='{"currentModelId":"gemini-3.5-flash","availableModels":[{"modelId":"gemini-3.5-flash","name":"Gemini 3.5 Flash"}]}'
sid=""
while IFS= read -r line; do
  id=$(printf '%s' "$line" | /usr/bin/sed -n 's/^{"jsonrpc":"2.0","id":\\([^,]*\\),"method".*/\\1/p')
  m=$(printf '%s' "$line" | /usr/bin/sed -n 's/^{"jsonrpc":"2.0",\\("id":[^,]*,\\)\\{0,1\\}"method":"\\([^"]*\\)".*/\\2/p')
  case "$m" in
    initialize) say '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"_meta":{"antigravity":{"tier":true,"systemPrompt":{"append":true}}}},"agentInfo":{"name":"Antigravity ACP Server","version":"1.5.9"}}}' ;;
    session/new|session/load)
      url=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
      tok=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"value":"Bearer \\([^"]*\\)".*/\\1/p')
      if [ "$m" = session/new ]; then
        next convs; sid="conv-$pid-$n"; printf 'conversation' > "$convs/$sid.db"
        note "session/new $sid"
        say '{"jsonrpc":"2.0","id":'"$id"',"result":{"sessionId":"'"$sid"'","models":'"$models"'}}'
      else
        sid=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*"sessionId":"\\([^"]*\\)".*/\\1/p')
        if [ -f "$convs/$sid.db" ]; then note "session/load $sid"; say '{"jsonrpc":"2.0","id":'"$id"',"result":{"models":'"$models"'}}'
        else note "session/load-missing $sid"; say '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32603,"message":"conversation not found"}}'; fi
      fi ;;
    session/set_model) say '{"jsonrpc":"2.0","id":'"$id"',"result":{}}' ;;
    session/prompt)
      next prompts; k=$n
      note "session/prompt $sid $k"
      printf '%s\\n' "$line" > "$FAKE_OUT/prompt-$k.json"
      to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
      if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-agy"; else to=$(/bin/cat "$FAKE_OUT/to-agy" 2>/dev/null); fi
      post "agy-reply-$k"
      say '{"jsonrpc":"2.0","id":'"$id"',"result":{"stopReason":"end_turn"}}' ;;
    session/cancel) ;;
    *) if [ -n "$id" ]; then say '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32601,"message":"Method not found: '"$m"'"}}'; fi ;;
  esac
done
`;

// ── a station under a launcher of the test's ──

/// A data directory (its key made by the program), its release `app`, config.json as given.
function stationDir(config: object): { data: string; app: string; id: string } {
  const data = fresh("data");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9400\n");
  const made = spawnSync(binary!, ["id", "--data", data], { env: { PATH: fresh("empty"), HOME: data, TMPDIR: tmpdir() }, encoding: "utf8" });
  assert.equal(made.status, 0, made.stderr);
  const id = made.stdout.trim();
  assert.match(id, /^[0-9a-f]{64}$/);
  writeFileSync(join(data, "config.json"), JSON.stringify(config));
  return { data, app, id };
}

const cloudJson = (data: string, o: { origin: string; id: string; name: string; peers: unknown[] }) => {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: o.origin, station: o.id, workspace: "w1", workspace_name: "团队", name: o.name, relay_url: "", relay_urls: [], grant_keys: null, peers: o.peers, revocations: [],
  }));
};

/// The control plane of the test's: its HTTP answered `{}`, its presence socket given each station's state and held.
async function plane(stateOf: (station: string) => object) {
  const sockets: WebSocket[] = [];
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateOf(String(req.headers["x-stillfail-station"] ?? "")) }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}` };
}

type Launched = { child: ChildProcess; door: number; stop: () => Promise<void>; err: () => string; alive: () => boolean };

/// `stillfail-reader run` under a launcher of the test's (its descriptors: the agents' door, the loopback port and its
/// channel), ready and its door open.
async function launch(data: string, app: string, env: Record<string, string>): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = netServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: {
      HOME: fresh("home"), TMPDIR: tmpdir(),
      STILLFAIL_RUNNER: runner, STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_AGENT_NICE: "0", STILLFAIL_HELD_EVERY_MS: "200",
      ...env,
    },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try { said.push(JSON.parse(line)); } catch {}
  });
  let err = "";
  child.stdout!.on("data", (d) => (err += d));
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const tail = () => err.slice(-4000);
  await given("the station ready", () => said.some((m) => m.ready === true), () => `said=${JSON.stringify(said)}; ${tail()}`);
  const door = (await given("the agents' door", () => said.find((m) => m.serving === "mcp"), tail)).port as number;
  const alive = () => child.exitCode === null && child.signalCode === null;
  const stop = async () => {
    if (!alive()) return;
    channel.write(`${JSON.stringify({ op: "stop" })}\n`);
    assert.equal(await ended, 0, tail());
  };
  return { child, door, stop, err: tail, alive };
}

type Answer = { status: number; text: string; json: any };

function http(port: number, path: string, o: { method?: string; body?: unknown; token?: string } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = {};
    if (o.body !== undefined) headers["content-type"] = "application/json";
    if (o.token !== undefined) headers.authorization = `Bearer ${o.token}`;
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers, agent: false }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d as Buffer));
      res.on("end", () => {
        const text = Buffer.concat(chunks).toString("utf8");
        let json: any = null;
        try { json = text === "" ? null : JSON.parse(text); } catch {}
        resolve({ status: res.statusCode!, text, json });
      });
    });
    req.on("error", reject);
    req.end(o.body === undefined ? undefined : JSON.stringify(o.body));
  });
}

/// An agent's tool through the agents' door, as the session the bearer names: its text and whether it is an error.
async function tool(port: number, token: string, name: string, args: Record<string, unknown>): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { token, body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } } });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.error, undefined, r.text);
  return { text: r.json.result.content.map((c: any) => c.text ?? "").join("\n"), error: r.json.result.isError === true };
}

/// A chat of the station's on `profile`: its session's key and its thread.
async function chatOn(port: number, runtime: string, profile: string): Promise<{ key: string; thread: number }> {
  const made = await http(port, "/admin-api/sessions", { body: { runtime, profile } });
  assert.equal(made.status, 200, made.text);
  return { key: made.json.key, thread: made.json.thread?.id ?? made.json.thread?.thread?.id };
}

async function send(port: number, thread: number, text: string): Promise<void> {
  const r = await http(port, `/admin-api/threads/${thread}/messages`, { body: { text } });
  assert.ok(r.status < 300, `${r.status} ${r.text}`);
}

/// What a thread says, each entry's text: its messages (`kind` message) or everything (notices too).
async function said(port: number, thread: number, all = false): Promise<string[]> {
  const r = await http(port, `/admin-api/threads/${thread}/entries`);
  assert.equal(r.status, 200, r.text);
  return (r.json.entries as any[]).filter((e) => all || e.kind === "message").map((e) => String(e.text ?? ""));
}

const openStore = (data: string) => {
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => store.close());
  return store;
};

/// A read of `data`'s store now (the Store keeps some rows in memory), closed at once.
function readDb<T>(data: string, f: (db: DatabaseSync) => T): T {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    return f(db);
  } finally {
    db.close();
  }
}

const turnsEnded = (data: string, key: string) =>
  readDb(data, (db) => (db.prepare("SELECT COUNT(*) AS n FROM turns WHERE session_key = ? AND ended_at IS NOT NULL").get(key) as { n: number }).n);
/// No turn of session `key` open in `data`'s store: the one that answered is over (its runtime's result read, not only
/// its post seen), so what is sent next begins a turn of its own rather than being steered into that one.
const idle = (data: string, key: string) =>
  given(`${key}'s turn over`, () => readDb(data, (db) => (db.prepare("SELECT COUNT(*) AS n FROM turns WHERE session_key = ? AND ended_at IS NULL").get(key) as { n: number }).n === 0));
const runtimeSessionOf = (data: string, key: string) =>
  readDb(data, (db) => (db.prepare("SELECT runtime_session_id AS id FROM sessions WHERE key = ?").get(key) as { id: string | null } | undefined)?.id ?? null);

/// The Codex app-servers a station started (`codex.log`'s starts in its data directory).
const appServersOf = (out: string, data: string) =>
  [...new Set(linesOf(join(out, "codex.log")).filter((l) => l.includes(` start ${data}`)).map((l) => Number(l.split(" ")[0])))];
const running = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// The station stopped (not handing over) well within the 10 s its agents' side is given, its Codex app-servers ended
/// with it, none left behind under their runners.
async function stopsCleanly(s: Launched, appServers: number[]) {
  assert.ok(appServers.length > 0 && appServers.every(running), `its app-servers running before: ${JSON.stringify(appServers)}`);
  const began = Date.now();
  await s.stop();
  const took = Date.now() - began;
  assert.ok(took < 5_000, `stopped in ${took} ms, not cut off by the agents' side's 10 s`);
  await given("its Codex app-servers ended with it", () => !appServers.some(running), () => `left: ${JSON.stringify(appServers.filter(running))}`, 3_000);
}

// ── 1. Codex's bare Bad Request ──

test("a Codex turn refused with a bare Bad Request is not tried again by itself; a message takes its thread up again from its rollout, then starts afresh where that is refused too: its job kept, the account's other thread untouched", { skip, timeout: 120_000 }, async () => {
  const st = stationDir({
    language: "en", maxNudges: 0,
    profiles: [{ id: "cx", runtime: "codex", home: "homes/cx", access: { kind: "opencode-go", key: "k-test" }, models: ["gpt-6.2-sol"] }],
  });
  mkdirSync(join(st.data, "homes", "cx"), { recursive: true });
  // (in a workspace: a station in none refuses a job's start)
  cloudJson(st.data, { origin: "http://127.0.0.1:9", id: st.id, name: "here", peers: [] });
  const out = fresh("out");
  const s = await launch(st.data, st.app, { PATH: toolsPath({ codex: fakeCodex }), FAKE_OUT: out });
  const log = () => linesOf(join(out, "codex.log"));
  /// What Codex was asked of `thread` (or of any), the pid that was asked dropped.
  const asked = (what: RegExp) => log().map((l) => l.slice(l.indexOf(" ") + 1)).filter((l) => what.test(l));
  const turnText = (k: number) => {
    const line = JSON.parse(readFileSync(join(out, `turn-${k}.json`), "utf8"));
    return (line.params.input as any[]).map((i) => i.text ?? "").join("");
  };
  const turnsAsked = () => asked(/^turn\/start /).length;
  const detail = () => `codex=${JSON.stringify(log())}; ${s.err()}`;

  // the account's other chat, its thread open on the same app-server
  const sibling = await chatOn(s.door, "codex", "cx");
  await send(s.door, sibling.thread, "the other chat");
  await given("the other chat answered", async () => (await said(s.door, sibling.thread)).includes("codex-reply-1"), detail);
  await idle(st.data, sibling.key);
  const siblingThread = runtimeSessionOf(st.data, sibling.key)!;
  assert.equal(siblingThread, "th-1", detail());

  // ── refused with a bare Bad Request: said, and not tried again by itself ──
  const chat = await chatOn(s.door, "codex", "cx");
  const token = readDb(st.data, (db) => (db.prepare("SELECT token FROM sessions WHERE key = ?").get(chat.key) as { token: string }).token);
  writeFileSync(join(out, "refuse"), "");
  await send(s.door, chat.thread, "the first ask");
  await given("its turn refused and ended", () => turnsEnded(st.data, chat.key) === 1, detail);
  const thread = runtimeSessionOf(st.data, chat.key)!;
  assert.equal(thread, "th-2", detail());
  await given("the refusal said in the chat", async () => (await said(s.door, chat.thread, true)).some((t) => t.includes('{"detail":"Bad Request"}')), async () => `${JSON.stringify(await said(s.door, chat.thread, true))}; ${detail()}`);
  // (a job of the chat's, which nothing here stops)
  const job = await tool(s.door, token, "job_start", { name: "watch CI", command: "sleep 600" });
  assert.equal(job.error, false, job.text);
  const jobId = readDb(st.data, (db) => (db.prepare("SELECT id FROM jobs WHERE session_key = ?").get(chat.key) as { id: string } | undefined)?.id);
  assert.ok(jobId, `its job kept: ${job.text}`);
  await passed(2_000);
  assert.equal(turnsAsked(), 2, `not tried again by itself: ${detail()}`);
  assert.deepEqual(asked(new RegExp(`^thread/(resume|unsubscribe) ${thread}$`)), [], "nothing done with its thread by itself");

  // ── a message: its thread let go and taken up again from its rollout, never asked on as it was loaded ──
  await send(s.door, chat.thread, "继续");
  await given("answered on the thread taken up again", async () => (await said(s.door, chat.thread)).includes("codex-reply-3"), detail);
  await idle(st.data, chat.key);
  assert.deepEqual(asked(new RegExp(`^thread/(start|resume|unsubscribe) ${thread}$`)), [`thread/start ${thread}`, `thread/unsubscribe ${thread}`, `thread/resume ${thread}`], detail());
  assert.deepEqual(asked(/^turn\/start /), ["turn/start th-1 tu-1", `turn/start ${thread} tu-2`, `turn/start ${thread} tu-3`]);
  assert.match(turnText(3), /继续/);
  assert.equal(runtimeSessionOf(st.data, chat.key), thread, "its context kept");

  // the thread taken up again works: refused later, it is taken up again first, not started afresh
  writeFileSync(join(out, "refuse"), "");
  await send(s.door, chat.thread, "下一步");
  await given("refused again later", () => turnsEnded(st.data, chat.key) === 3, detail);
  await send(s.door, chat.thread, "继续吧");
  await given("answered on the thread taken up again, again", async () => (await said(s.door, chat.thread)).includes("codex-reply-5"), detail);
  await idle(st.data, chat.key);
  assert.deepEqual(asked(new RegExp(`^thread/(start|resume) ${thread}$`)), [`thread/start ${thread}`, `thread/resume ${thread}`, `thread/resume ${thread}`], detail());
  assert.equal(runtimeSessionOf(st.data, chat.key), thread);
  assert.equal(asked(/^thread\/start /).length, 2, "nothing afresh");

  // ── refused again as soon as it is taken up again: the next message starts afresh, its job kept ──
  writeFileSync(join(out, "refuse"), "");
  await send(s.door, chat.thread, "再来");
  await given("refused once more", () => turnsEnded(st.data, chat.key) === 5, detail);
  writeFileSync(join(out, "refuse"), "");
  await send(s.door, chat.thread, "继续一下");
  await given("refused as soon as taken up again", () => turnsEnded(st.data, chat.key) === 6, detail);
  assert.deepEqual(asked(new RegExp(`^thread/resume ${thread}$`)).length, 3, detail());
  await send(s.door, chat.thread, "再试一次");
  const afresh = await given("answered on a new thread", async () => {
    const fresh = runtimeSessionOf(st.data, chat.key);
    return fresh !== thread && (await said(s.door, chat.thread)).includes("codex-reply-8") ? fresh : null;
  }, detail);
  await idle(st.data, chat.key);
  assert.equal(afresh, "th-3", detail());
  assert.ok(asked(/^thread\/start th-3$/).length === 1, detail());
  assert.ok((await said(s.door, chat.thread, true)).some((t) => t.includes("Codex still refused the conversation (Bad Request), so the context started afresh")), JSON.stringify(await said(s.door, chat.thread, true)));
  const begun = turnText(8);
  for (const w of ["This is a new conversation", `session_history with chat ${chat.key}`, "再试一次"]) assert.ok(begun.includes(w), `${w}: ${begun}`);
  assert.equal(readDb(st.data, (db) => (db.prepare("SELECT state FROM jobs WHERE id = ?").get(jobId) as { state: string }).state), "running", "its job not stopped");

  // the account's other thread never let go, and answers on as it was
  assert.deepEqual(asked(new RegExp(`^thread/(resume|unsubscribe) ${siblingThread}$`)), [], detail());
  await send(s.door, sibling.thread, "the other chat again");
  await given("the other chat answered again", async () => (await said(s.door, sibling.thread)).includes("codex-reply-9"), detail);
  await idle(st.data, sibling.key);
  assert.equal(runtimeSessionOf(st.data, sibling.key), siblingThread);
  assert.equal(new Set(log().map((l) => l.split(" ")[0])).size, 1, `one app-server throughout: ${detail()}`);
  await stopsCleanly(s, appServersOf(out, st.data));
});

// ── 2. an Antigravity CLI conversation its CLI no longer keeps ──

test("an Antigravity CLI conversation the station kept but its CLI no longer has is never loaded: the chat goes on afresh, answered, and on the new one after", { skip, timeout: 90_000 }, async () => {
  const st = stationDir({
    language: "en", maxNudges: 0,
    profiles: [{ id: "ag", runtime: "agy", home: "homes/ag", access: { kind: "api-provider", provider: "google", key: "gemini-key" }, models: ["gemini-3.5-flash"] }],
  });
  mkdirSync(join(st.data, "homes", "ag"), { recursive: true });
  cloudJson(st.data, { origin: "http://127.0.0.1:9", id: st.id, name: "here", peers: [] });
  const out = fresh("out");
  const path = toolsPath({ agy: fakeAgy });
  let s = await launch(st.data, st.app, { PATH: path, FAKE_OUT: out });
  const log = () => linesOf(join(out, "agy.log")).map((l) => l.slice(l.indexOf(" ") + 1));
  const chat = await chatOn(s.door, "agy", "ag");
  const detail = () => `agy=${JSON.stringify(linesOf(join(out, "agy.log")))}; ${s.err()}`;
  const chatDetail = async () => `chat=${JSON.stringify(await said(s.door, chat.thread, true).catch((e) => [String(e)]))}; ${detail()}`;
  await send(s.door, chat.thread, "hello");
  await given("answered", async () => (await said(s.door, chat.thread)).includes("agy-reply-1"), chatDetail);
  await idle(st.data, chat.key);
  const first = runtimeSessionOf(st.data, chat.key)!;
  assert.match(first, /^conv-\d+-1$/, detail());
  const conversations = join(st.data, "homes", "ag", "agy", ".gemini", "antigravity-cli", "conversations");
  assert.ok(existsSync(join(conversations, `${first}.db`)), detail());
  await given("its turn ended", () => turnsEnded(st.data, chat.key) === 1, detail);
  await s.stop();

  // its CLI's conversation gone (a chat moved here with the station's transcript alone): the station still names it
  rmSync(join(conversations, `${first}.db`));
  assert.equal(runtimeSessionOf(st.data, chat.key), first);
  s = await launch(st.data, st.app, { PATH: path, FAKE_OUT: out });
  await send(s.door, chat.thread, "still there?");
  const next = await given("answered afresh", async () => {
    const id = runtimeSessionOf(st.data, chat.key);
    return id !== first && (await said(s.door, chat.thread)).includes("agy-reply-2") ? id : null;
  }, chatDetail, 30_000);
  await idle(st.data, chat.key);
  assert.match(next!, /^conv-\d+-2$/, detail());
  assert.deepEqual(log().filter((l) => l.includes(first)), [`session/new ${first}`, `session/prompt ${first} 1`], `the conversation gone never loaded nor asked: ${detail()}`);
  assert.ok(log().includes(`session/prompt ${next} 2`), detail());
  // not stuck: the next message on the new conversation, as it is
  await send(s.door, chat.thread, "and now?");
  await given("answered on the new conversation", async () => (await said(s.door, chat.thread)).includes("agy-reply-3"), detail);
  await idle(st.data, chat.key);
  assert.equal(runtimeSessionOf(st.data, chat.key), next);
  assert.equal(log().filter((l) => l.startsWith("session/new ")).length, 2, detail());
  await s.stop();
});

// ── two stations over real iroh ──

type Two = {
  a: ReturnType<typeof stationDir>; b: ReturnType<typeof stationDir>; alpha: Launched; beta: Launched; out: string; both: () => string;
  page: (to?: string) => Promise<any>;
};

/// Stations alpha (A) and beta (B) of one workspace on loopback iroh, their PATHs the fake runtimes `scripts`, their notes
/// in one FAKE_OUT; both on the test channel, where moving is offered.
async function twoStations(profilesA: object[], profilesB: object[], scripts: Record<string, string>, before: (a: string, b: string) => void = () => {}): Promise<Two> {
  const [a, b] = [stationDir({ language: "en", updateChannel: "beta", profiles: profilesA, maxNudges: 0 }), stationDir({ language: "en", updateChannel: "beta", profiles: profilesB, maxNudges: 0 })];
  before(a.data, b.data);
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: a.id, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: b.id, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const p = await plane((station) => ({ workspace: "w1", workspace_name: "团队", name: station === a.id ? "alpha" : "beta", peers }));
  cloudJson(a.data, { origin: p.origin, id: a.id, name: "alpha", peers });
  cloudJson(b.data, { origin: p.origin, id: b.id, name: "beta", peers });
  const out = fresh("out");
  const alpha = await launch(a.data, a.app, { PATH: toolsPath(scripts), FAKE_OUT: out, FAKE_STATION: "alpha", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` });
  const beta = await launch(b.data, b.app, { PATH: toolsPath(scripts), FAKE_OUT: out, FAKE_STATION: "beta", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}` });
  const both = () => `alpha: ${alpha.err()}\nbeta: ${beta.err()}`;
  for (const d of [a.data, b.data]) await given("online at the plane", () => readJson(join(d, "run", "presence.json"))?.online === true, both);
  const page = async (to = b.id) => (await http(alpha.door, `/admin-api/move?to=${to}`)).json;
  return { a, b, alpha, beta, out, both, page };
}

const itemOf = (page: any, module: string, id: string) => page?.modules?.find((m: any) => m.id === module)?.items?.find((x: any) => x.id === id);

/// A move of alpha's (`/move`, or `/move/back` from beta) to its end: what the page says of it last.
async function moved(w: Two, how: "move" | "back", body: object): Promise<any> {
  const was = (await w.page())?.last?.at ?? null;
  const r = await http(w.alpha.door, how === "move" ? "/admin-api/move" : "/admin-api/move/back", { body: how === "move" ? { to: w.b.id, ...body } : { from: w.b.id, ...body } });
  assert.equal(r.status, 202, r.text);
  // (a turn after the last one, over)
  return given(`the ${how} over`, async () => {
    const p = await w.page();
    return p?.moving === null && p?.last != null && p.last.at !== was && p.last.how === how ? p.last : null;
  }, async () => `${JSON.stringify(await w.page())}; ${w.both()}`, 60_000);
}

const configOf = (data: string) => readJson(join(data, "config.json"));
const handedTo = (data: string, key: string) => readDb(data, (db) => (db.prepare("SELECT station FROM handed_over WHERE session = ?").get(key) as { station: string } | undefined) ?? null);

/// A Claude subscription's login file, lasting `ms`.
const claudeLogin = (ms: number) => JSON.stringify({ claudeAiOauth: { accessToken: "at-alpha", refreshToken: "rt-alpha", expiresAt: Date.now() + ms, scopes: ["user:inference"], subscriptionType: "max" } });

// ── 3. a chat moved with its login: lent, not moved ──

test("an own Claude login of three chats, one chat moved with what it needs: the login lent, not moved (hosted here, shared with the two stations alone, borrowed there, its token used there); the other two chats go on; the chat back alone, the lending undone", { skip, timeout: 180_000 }, async () => {
  const MAX = { id: "max", name: "Claude Max", runtime: "claude", access: { kind: "subscription" }, home: "homes/max", models: ["claude-opus-5-5"] };
  const w = await twoStations([MAX], [], { claude: fakeClaude }, (a) => {
    mkdirSync(join(a, "homes", "max"), { recursive: true });
    writeFileSync(join(a, "homes", "max", ".credentials.json"), claudeLogin(7 * 24 * 3_600_000), { mode: 0o600 });
  });
  const { a, b, alpha, beta, out, both } = w;
  const tokens = () => linesOf(join(out, "tokens"));
  const chats = [await chatOn(alpha.door, "claude", "max"), await chatOn(alpha.door, "claude", "max"), await chatOn(alpha.door, "claude", "max")];
  for (const [i, c] of chats.entries()) {
    await send(alpha.door, c.thread, `chat ${i} on alpha`);
    await given(`chat ${i} answered on alpha`, async () => (await said(alpha.door, c.thread)).includes("alpha-reply-1"), both);
    await idle(a.data, c.key);
  }
  assert.ok(tokens().every((t) => t.startsWith("alpha ") && t.endsWith(" at-alpha")), JSON.stringify(tokens()));
  const [one, two, three] = chats as [typeof chats[0], typeof chats[0], typeof chats[0]];
  const account = `own:max@${a.id}`;
  const plan = await given("its login an item of the move", async () => itemOf(await w.page(), "accounts", account), async () => `${JSON.stringify(await w.page())}; ${both()}`, 30_000);
  assert.equal(plan.state, "here", JSON.stringify(plan));
  await given("the chat movable to beta", async () => itemOf(await w.page(), "chats", one.key)?.state === "here", async () => JSON.stringify(await w.page()));

  // ── moved with what it needs ──
  const last = await moved(w, "move", { module: "chats", item: one.key, withNeeds: true });
  assert.equal(last.failed, null, JSON.stringify(last));
  assert.deepEqual(last.done, [`chats ${one.key}`], `the chat alone moved: ${JSON.stringify(last)}`);
  assert.deepEqual(last.lent, [`accounts ${account}`], `its login lent for it: ${JSON.stringify(last)}`);
  assert.deepEqual(last.stopped, [], "nothing stopped");
  assert.equal(handedTo(a.data, one.key)?.station, b.id);
  // hosted here, shared with the two stations alone; borrowed there, no login file there
  const here = (configOf(a.data).profiles as any[]).find((p) => p.id === "max");
  assert.ok(here?.share?.id, JSON.stringify(here));
  assert.equal(here.share.borrowed, undefined, "hosted here");
  assert.deepEqual([...here.share.allow].sort(), [a.id, b.id].sort(), "the two stations alone");
  assert.equal(JSON.parse(readFileSync(join(a.data, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "rt-alpha", "its login here");
  const share = here.share.id as string;
  const copy = await given("beta borrows it", () => (configOf(b.data).profiles as any[] | undefined)?.find((p) => p.share?.id === share), both);
  assert.equal(copy.share.borrowed, true, JSON.stringify(copy));
  assert.equal(copy.share.host, a.id);
  assert.equal(existsSync(join(b.data, copy.home ?? "", ".credentials.json")), false, "no login file there");
  const lentItem = itemOf(await w.page(), "accounts", `share:${share}`);
  assert.deepEqual([lentItem?.state, lentItem?.lentTo], ["here", "beta"], JSON.stringify(lentItem));

  // the chat answers there on the token lent; the two here go on, nothing said in them of the move
  const storeB = openStore(b.data);
  const threadB = (await given("the chat on beta", () => storeB.sessionThreads(one.key)[0], both)).thread.id;
  await send(beta.door, threadB, "there now?");
  await given("answered on beta", async () => (await said(beta.door, threadB)).includes("beta-reply-2"), both);
  await idle(b.data, one.key);
  assert.ok(tokens().some((t) => t.startsWith("beta ") && t.endsWith(" at-alpha")), `beta's runtime on alpha's token, lent: ${JSON.stringify(tokens())}`);
  for (const c of [two, three]) {
    await send(alpha.door, c.thread, "and now?");
    await given("a chat left here answered", async () => (await said(alpha.door, c.thread)).includes("alpha-reply-2"), both);
    await idle(a.data, c.key);
    assert.ok(!(await said(alpha.door, c.thread, true)).some((t) => /moved|stopped/i.test(t)), "nothing said of the move");
  }

  // ── the chat back alone, the last it was lent for: the login this station's own again, beta keeping no copy ──
  const back = await moved(w, "back", { module: "chats", item: one.key });
  assert.equal(back.failed, null, JSON.stringify(back));
  assert.equal(handedTo(a.data, one.key), null);
  await given("not shared any more", () => (configOf(a.data).profiles as any[]).find((p) => p.id === "max")?.share === undefined, () => `${JSON.stringify(configOf(a.data).profiles)}; ${both()}`);
  await given("beta keeps no copy", () => !((configOf(b.data).profiles ?? []) as any[]).some((p) => p.share?.id === share), () => `${JSON.stringify(configOf(b.data).profiles)}; ${both()}`);
  assert.equal(JSON.parse(readFileSync(join(a.data, "homes", "max", ".credentials.json"), "utf8")).claudeAiOauth.refreshToken, "rt-alpha");
  await send(alpha.door, one.thread, "home again");
  await given("answered home again", async () => (await said(alpha.door, one.thread)).includes("alpha-reply-3"), both);
  await idle(a.data, one.key);
  await beta.stop();
  await alpha.stop();
});

// ── 4. a Codex login lent in its early-renewal window ──

/// A Codex access token (its signature not checked) running out `ms` from now.
const jwt = (ms: number) => ["{}", JSON.stringify({ exp: Math.floor((Date.now() + ms) / 1000) }), "s"].map((p) => Buffer.from(p).toString("base64url")).join(".");
const codexLogin = (access: string) => JSON.stringify({ OPENAI_API_KEY: null, tokens: { id_token: jwt(30 * 86_400_000), access_token: access, account_id: "acct-1", refresh_token: "rt-codex" }, last_refresh: new Date().toISOString() });
const accessOf = (file: string) => readJson(file)?.tokens?.access_token as string | undefined;

/// Alpha's Codex login (two hours left: in the window it is renewed early in) shared with beta, the Codex running on it
/// here; a chat on beta's copy, which lends it. `hold`: the renewal held until the test lets it go.
async function codexLend(hold: boolean) {
  const PLUS = { id: "plus", name: "ChatGPT Plus", runtime: "codex", access: { kind: "subscription" }, home: "homes/plus", models: ["gpt-6.2-sol"] };
  const old = jwt(2 * 3_600_000);
  const renewed = jwt(10 * 86_400_000);
  const w = await twoStations([PLUS], [], { codex: fakeCodex }, (a) => {
    mkdirSync(join(a, "homes", "plus"), { recursive: true });
    writeFileSync(join(a, "homes", "plus", "auth.json"), codexLogin(old), { mode: 0o600 });
  });
  writeFileSync(join(w.out, "renewed-auth.json"), codexLogin(renewed));
  if (hold) writeFileSync(join(w.out, "renew-hold"), "");
  const log = () => linesOf(join(w.out, "codex.log"));
  const detail = () => `codex=${JSON.stringify(log())}; ${w.both()}`;
  // the Codex running on it here: a chat of alpha's answered
  const mine = await chatOn(w.alpha.door, "codex", "plus");
  await send(w.alpha.door, mine.thread, "on alpha");
  await given("alpha's chat answered", async () => (await said(w.alpha.door, mine.thread)).includes("codex-reply-1"), detail);
  await idle(w.a.data, mine.key);
  const shared = await http(w.alpha.door, "/admin-api/profiles/plus/share", { body: { shared: true } });
  assert.equal(shared.status, 200, shared.text);
  const copy = await given("beta borrows it", () => ((configOf(w.b.data).profiles ?? []) as any[]).find((p) => p.share?.host === w.a.id), detail, 30_000);
  assert.equal(copy.share.borrowed, true);
  const copyAuth = join(w.b.data, copy.home, "auth.json");
  assert.equal(log().some((l) => l.endsWith(" renew asked")), false, "nothing renewed before it is lent");
  const theirs = await chatOn(w.beta.door, "codex", copy.id);
  const asked = Date.now();
  await send(w.beta.door, theirs.thread, "on beta, lent");
  return { ...w, old, renewed, log, detail, copy, copyAuth, theirs, asked };
}

test("a Codex login lent in its early-renewal window is renewed first by the Codex running on it at its host: the fresh one lent, the chat there answered on it", { skip, timeout: 120_000 }, async () => {
  const c = await codexLend(false);
  await given("beta's chat answered", async () => (await said(c.beta.door, c.theirs.thread)).includes("codex-reply-2"), c.detail, 30_000);
  await idle(c.b.data, c.theirs.key);
  assert.equal(c.log().filter((l) => l.endsWith(" renew asked")).length, 1, c.detail());
  assert.equal(accessOf(join(c.a.data, "homes", "plus", "auth.json")), c.renewed, "renewed at its host");
  assert.equal(accessOf(c.copyAuth), c.renewed, `the fresh one lent: ${c.detail()}`);
  assert.doesNotMatch(c.alpha.err(), /outlasted the lend's bound/);
  await stopsCleanly(c.beta, appServersOf(c.out, c.b.data));
  await stopsCleanly(c.alpha, appServersOf(c.out, c.a.data));
});

test("a Codex login whose renewal outlasts the lend's bound is lent as it is at the bound, never held: the chat there answered on it, the renewal going on behind and done at its host once it answers", { skip, timeout: 120_000 }, async () => {
  const c = await codexLend(true);
  await given("its renewal asked at its host", () => c.log().some((l) => l.endsWith(" renew asked")), c.detail, 30_000);
  await given("beta's chat answered while the renewal is held", async () => (await said(c.beta.door, c.theirs.thread)).includes("codex-reply-2"), c.detail, 40_000);
  await idle(c.b.data, c.theirs.key);
  const waited = Date.now() - c.asked;
  assert.ok(waited >= 9_000, `lent at the bound (10 s), not before: ${waited} ms`);
  assert.equal(c.log().some((l) => l.endsWith(" renewed")), false, "the renewal still held");
  assert.equal(accessOf(c.copyAuth), c.old, `the login it has, lent: ${c.detail()}`);
  assert.match(c.alpha.err(), /renewal outlasted the lend's bound/, "said");
  // the renewal let go: done at its host, behind the lend; nothing asked of it twice
  writeFileSync(join(c.out, "renew-release"), "");
  await given("renewed at its host", () => accessOf(join(c.a.data, "homes", "plus", "auth.json")) === c.renewed, c.detail);
  assert.equal(c.log().filter((l) => l.endsWith(" renew asked")).length, 1, c.detail());
  // the chat there goes on
  await send(c.beta.door, c.theirs.thread, "again");
  await given("beta's chat answered again", async () => (await said(c.beta.door, c.theirs.thread)).includes("codex-reply-3"), c.detail);
  await idle(c.b.data, c.theirs.key);
  await stopsCleanly(c.beta, appServersOf(c.out, c.b.data));
  await stopsCleanly(c.alpha, appServersOf(c.out, c.a.data));
});

// ── 5. a chat's calls handed over and back; a hand-over the other cannot write ──

/// The calls of session `key` kept by `data`'s store, by id: their tokens; and the session's usage as kept.
const callsOf = (data: string, key: string): Record<string, string> =>
  Object.fromEntries(readDb(data, (db) => db.prepare("SELECT id, input, output FROM usage WHERE session = ? ORDER BY id").all(key) as { id: string; input: number; output: number }[]).map((r) => [r.id, `${r.input}/${r.output}`]));
const keptOf = (data: string, key: string): { modelCalls: number; inputTokens: number; outputTokens: number } | null => readDb(data, (db) => {
  const row = db.prepare("SELECT usage FROM session_usage WHERE session = ?").get(key) as { usage: string } | undefined;
  if (row === undefined) return null;
  const u = JSON.parse(row.usage);
  return { modelCalls: u.modelCalls, inputTokens: u.inputTokens, outputTokens: u.outputTokens };
});
const totalsOf = (data: string, key: string) => readDb(data, (db) => ({ ...(db.prepare("SELECT COALESCE(SUM(calls), 0) AS calls, COALESCE(SUM(input), 0) AS input FROM usage_totals WHERE session = ?").get(key) as { calls: number; input: number }) }));

test("a chat's calls go with it to another station and back, its agent working there between: each call once on each side, the counts as made; a hand-over the other station cannot write fails whole, nothing of it there, the chat answering here", { skip, timeout: 180_000 }, async () => {
  const CC = { id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-usage-test" }, models: ["claude-opus-5-5"] };
  const w = await twoStations([CC], [CC], { claude: fakeClaude });
  const { a, b, alpha, beta, both } = w;
  const chat = await chatOn(alpha.door, "claude", "cc");
  for (const [n, text] of ["first", "second"].entries()) {
    await send(alpha.door, chat.thread, text);
    await given(`alpha's answer ${n + 1}`, async () => (await said(alpha.door, chat.thread)).includes(`alpha-reply-${n + 1}`), both);
    await idle(a.data, chat.key);
  }
  const sid = runtimeSessionOf(a.data, chat.key)!;
  const id = (station: string, n: number) => `${station}-${sid}-${n}`;
  const mine = { [id("alpha", 1)]: "100/1", [id("alpha", 2)]: "200/2" };
  await given("alpha's calls counted", () => isDeepStrictEqual(callsOf(a.data, chat.key), mine), () => `${JSON.stringify(callsOf(a.data, chat.key))}; ${both()}`);
  await given("alpha's usage kept", () => keptOf(a.data, chat.key) !== null, both);
  await given("the chat movable to beta", async () => itemOf(await w.page(), "chats", chat.key)?.state === "here", async () => JSON.stringify(await w.page()), 30_000);

  // ── handed over: its calls there as they were made, once ──
  const there = await moved(w, "move", { module: "chats", item: chat.key, withNeeds: true });
  assert.equal(there.failed, null, JSON.stringify(there));
  assert.equal(handedTo(a.data, chat.key)?.station, b.id);
  assert.deepEqual(callsOf(b.data, chat.key), mine, "its calls there");
  // ── its agent working there: a call of its own, counted there once, the calls it came with not again ──
  const storeB = openStore(b.data);
  const threadB = (await given("the chat on beta", () => storeB.sessionThreads(chat.key)[0], both)).thread.id;
  await send(beta.door, threadB, "on beta");
  await given("beta's answer", async () => (await said(beta.door, threadB)).includes("beta-reply-3"), both);
  await idle(b.data, chat.key);
  const all = { ...mine, [id("beta", 3)]: "300/3" };
  await given("beta's call counted", () => isDeepStrictEqual(callsOf(b.data, chat.key), all), () => `${JSON.stringify(callsOf(b.data, chat.key))}; ${both()}`);
  await given("beta's usage kept with its call", () => keptOf(b.data, chat.key)?.modelCalls === 3, () => `${JSON.stringify(keptOf(b.data, chat.key))}; ${both()}`);
  // (read again by the counter there after a while: still each once)
  assert.deepEqual(keptOf(b.data, chat.key), { modelCalls: 3, inputTokens: 600, outputTokens: 6 });
  await passed(2_500);
  assert.deepEqual(callsOf(b.data, chat.key), all);
  assert.deepEqual(totalsOf(b.data, chat.key), { calls: 3, input: 600 }, "counted once there");

  // ── back: every call once here, as made, the counts as there ──
  const home = await moved(w, "back", { module: "chats", item: chat.key });
  assert.equal(home.failed, null, JSON.stringify(home));
  assert.equal(handedTo(a.data, chat.key), null);
  await given("its calls back here, each once", () => isDeepStrictEqual(callsOf(a.data, chat.key), all), () => `${JSON.stringify(callsOf(a.data, chat.key))}; ${both()}`);
  assert.deepEqual(totalsOf(a.data, chat.key), { calls: 3, input: 600 }, "counted once here");
  await given("its usage kept here as there", () => keptOf(a.data, chat.key)?.modelCalls === 3, () => `${JSON.stringify(keptOf(a.data, chat.key))}; ${both()}`);
  assert.deepEqual(keptOf(a.data, chat.key), { modelCalls: 3, inputTokens: 600, outputTokens: 6 });
  // another call here, after it came home
  await send(alpha.door, chat.thread, "home");
  await given("alpha's answer at home", async () => (await said(alpha.door, chat.thread)).includes("alpha-reply-4"), both);
  await idle(a.data, chat.key);
  const four = { ...all, [id("alpha", 4)]: "400/4" };
  await given("alpha's call at home counted", () => isDeepStrictEqual(callsOf(a.data, chat.key), four), () => `${JSON.stringify(callsOf(a.data, chat.key))}; ${both()}`);

  // ── handed over to a station that cannot write what it takes: failed whole, nothing of it there, the chat here ──
  const rowThere = () => readDb(b.data, (db) => ({ ...(db.prepare("SELECT ws, runtime_session_id AS rid FROM sessions WHERE key = ?").get(chat.key) as object) }));
  const before = { calls: callsOf(b.data, chat.key), kept: keptOf(b.data, chat.key), totals: totalsOf(b.data, chat.key), row: rowThere(), handed: handedTo(b.data, chat.key) };
  const inbox = join(b.data, "replica", "handover", "in");
  assert.ok(existsSync(inbox), "where hand-overs come in there");
  const inBefore = readdirSync(inbox).sort();
  chmodSync(inbox, 0o555);
  closers.push(() => chmodSync(inbox, 0o755));
  const refused = await moved(w, "move", { module: "chats", item: chat.key, withNeeds: true });
  chmodSync(inbox, 0o755);
  assert.notEqual(refused.failed, null, `refused: ${JSON.stringify(refused)}`);
  assert.equal(handedTo(a.data, chat.key), null, "it goes on here");
  // (failed this turn, as the TypeScript's page says it: here still, where it can be moved again)
  assert.equal(itemOf(await w.page(), "chats", chat.key)?.state, "failed");
  assert.match(String(refused.failed.error), /try again/, "said, with what to do");
  assert.deepEqual({ calls: callsOf(b.data, chat.key), kept: keptOf(b.data, chat.key), totals: totalsOf(b.data, chat.key), row: rowThere(), handed: handedTo(b.data, chat.key) }, before, "nothing of it put in there, nothing doubled");
  assert.deepEqual(readdirSync(inbox).sort(), inBefore, "nothing left half there");
  assert.deepEqual(callsOf(a.data, chat.key), four, "here as it was");
  await send(alpha.door, chat.thread, "still here?");
  await given("answered here after the failed hand-over", async () => (await said(alpha.door, chat.thread)).includes("alpha-reply-5"), both);
  await idle(a.data, chat.key);
  await beta.stop();
  await alpha.stop();
});
