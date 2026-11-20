// The MoonBit station (`stillfail-reader run`, no Node on its PATH) through the faults of the world around it that the
// TypeScript's own tests hold (presence-conflict, connect-refusal, comma-held-reconnect, feishu, release-feed-again,
// signed, chat-handover, chat-handover-back): the control plane closing the presence socket as `4004` (removed: nothing
// asked again until it is enrolled again) and as `4000` (replaced) three times in a row before it held (another station
// on this key: said so, a minute's wait, no storm); a Comma connect refused with 409 saying Comma's words in its state
// and asked again on a backoff, then connected, and connected again once its socket is cut; a Feishu connect whose token
// is answered 503 asked again, and its long connection cut connected again, each time taking events; the release feed
// read by `stillfail update` again past a gateway's 502 and a broken connection, a refusal and a release whose signature
// does not verify never taken (and the running station not offering it); and a chat moved between two stations over
// real iroh, its files byte for byte and its runtime session taken up there, read and sent to from the station it left,
// moved back with nothing said twice, and a move to a station that is down refused with the chat and its files
// untouched here. Under scripts/native.ts run (mesh runner archive-rs reader launcher); the Comma refusal's words need
// the shell's handshake answer (client/shell net.rs `ws_error`).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, createPublicKey, randomBytes, sign } from "node:crypto";
import { createSocket } from "node:dgram";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { type WebSocket, WebSocketServer } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { FakeFeishu, RawAnswer } from "./feishu-fake.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : false;
const skipAgents =
  skip !== false
    ? skip
    : runner === "" || !existsSync(runner)
      ? "no stillfail-runner (run under scripts/native.ts run runner)"
      : !existsSync("/usr/bin/curl")
        ? "no /usr/bin/curl for the fake runtime"
        : false;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfmc-${what}-`));
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
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
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

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

const TOOLS = ["sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "lsof"];

/// A PATH of the tools a station runs, Node not among them.
function toolsPath(): string {
  const dir = fresh("path");
  const search = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = search.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false, "no Node on PATH");
  return dir;
}

/// A fake Claude Code (stream-json in and out, /bin/sh and curl alone): each prompt posts `<prefix>-<n>` and all_done
/// to the thread it was asked in, through the agents' door; `n` counts a session's prompts across its processes (one
/// started again as the chat comes back counts on).
function fakeClaude(bin: string, prefix: string) {
  const claude = `#!/bin/sh
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
# (its transcript where Claude Code keeps one, so the session can be taken up again: claude.ts transcriptAt)
if [ -n "$CLAUDE_CONFIG_DIR" ]; then /bin/mkdir -p "$CLAUDE_CONFIG_DIR/projects/fake" && printf '{"sessionId":"%s"}\\n' "$sid" >> "$CLAUDE_CONFIG_DIR/projects/fake/$sid.jsonl"; fi
url=$(printf '%s' "$cfg" | /usr/bin/sed -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
say() { printf '%s\\n' "$1"; }
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$(( $(/bin/cat "$FAKE_OUT/n-$sid" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" > "$FAKE_OUT/n-$sid"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  to=$(printf '%s' "$line" | /usr/bin/sed -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(/bin/cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Moved chat","text":"${prefix}-'"$n"'","kind":"all_done","done":"replied turn '"$n"'"}}}' > "$FAKE_OUT/post-$sid-$n.json"
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"posted"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(bin, "claude"), claude);
  chmodSync(join(bin, "claude"), 0o755);
}

/// A data directory (its key made by the program), its release `app` (BUILD as given), config.json as given.
function stationDir(config: object, build = "9400"): { data: string; app: string; id: string } {
  const data = fresh("data");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), `${build}\n`);
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

type Launched = { child: ChildProcess; door: number; said: any[]; stop: () => Promise<void>; kill: () => Promise<void>; err: () => string; alive: () => boolean };

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
      PATH: env.PATH ?? toolsPath(), HOME: fresh("home"), TMPDIR: tmpdir(),
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
  const tail = () => err.slice(-3000);
  await given("the station ready", () => said.some((m) => m.ready === true), () => `said=${JSON.stringify(said)}; ${tail()}`);
  const door = (await given("the agents' door", () => said.find((m) => m.serving === "mcp"), tail)).port as number;
  const alive = () => child.exitCode === null && child.signalCode === null;
  const stop = async () => {
    if (!alive()) return;
    channel.write(`${JSON.stringify({ op: "stop" })}\n`);
    assert.equal(await ended, 0, tail());
  };
  const kill = async () => {
    if (!alive()) return;
    child.kill("SIGKILL");
    await ended;
  };
  return { child, door, said, stop, kill, err: tail, alive };
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

const connectionOf = async (port: number, cid: string) => (await http(port, "/admin-api/overview")).json?.connects?.find((c: any) => c.id === cid)?.connection;

// ── 1. the control plane's close codes ──

/// The control plane of the test's: its HTTP answered `{}`, its presence socket given the station's state and then, as
/// `mode` says, kept (`hold`), closed at once as another of the same key's took its place (`replaced`: 4000) or as the
/// station's removal (`removed`: 4004). Each upgrade is counted with its time.
async function closingPlane(stateOf: (station: string) => object) {
  const sockets: WebSocket[] = [];
  const upgrades: { at: number; mode: string }[] = [];
  const plane = { mode: "hold" as "hold" | "replaced" | "removed" };
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const mode = plane.mode;
    upgrades.push({ at: Date.now(), mode });
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateOf(String(req.headers["x-stillfail-station"] ?? "")) }));
      if (mode === "replaced") ws.close(4000, "replaced");
      if (mode === "removed") ws.close(4004, "removed");
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, sockets, upgrades, plane };
}

test("the plane's presence socket closed as 4004 (removed): said so, asked nothing until enrolled again, then online; closed as 4000 (replaced) three times before it held: another station on this key said, a minute's wait, no storm", { skip, timeout: 60_000 }, async () => {
  const st = stationDir({ language: "en" });
  const peers = [{ id: st.id, name: "mac" }];
  const p = await closingPlane(() => ({ workspace: "w1", workspace_name: "团队", name: "mac", peers }));
  cloudJson(st.data, { origin: p.origin, id: st.id, name: "mac", peers });
  const s = await launch(st.data, st.app, {});
  const presence = () => readJson(join(st.data, "run", "presence.json"));
  const cloud = () => readJson(join(st.data, "mesh", "cloud.json"));
  const said = () => `presence=${JSON.stringify(presence())}; upgrades=${JSON.stringify(p.upgrades)}; ${s.err()}`;
  await given("online at the plane", () => presence()?.online === true, said);

  // ── removed (4004): marked in cloud.json, said in presence.json, nothing asked of the plane until enrolled again ──
  p.plane.mode = "removed";
  const before = p.upgrades.length;
  for (const ws of p.sockets) ws.close(4004, "removed");
  const removed = await given("cloud.json says removed (4004)", () => (cloud()?.removed_code === 4004 ? cloud() : null), said);
  assert.equal(typeof removed.removed_at, "number", JSON.stringify(removed));
  await given("presence.json says removed, and what brings it back", () => presence()?.online === false && /removed from its workspace; enroll it again/.test(String(presence()?.error)), said);
  // (`conflict` said only while it holds, as presence.ts writes it)
  assert.equal(presence().conflict, undefined, said());
  const overview = await http(s.door, "/admin-api/overview");
  assert.equal(overview.status, 200, overview.text);
  // (the presence socket's backoff starts at a second: two of them asked nothing)
  const quiet = Date.now();
  await given("two seconds of the station's own time", () => Date.now() - quiet >= 2_000);
  assert.equal(p.upgrades.length, before, `asked the plane again while removed: ${said()}`);
  assert.equal(s.alive(), true, said());

  // ── enrolled again (cloud.json written anew, as `enroll` writes it): back at the plane, the mark gone ──
  p.plane.mode = "hold";
  cloudJson(st.data, { origin: p.origin, id: st.id, name: "mac", peers });
  await given("online at the plane once enrolled again", () => presence()?.online === true && presence()?.error === null, said);
  assert.equal(cloud().removed_at, undefined, JSON.stringify(cloud()));
  assert.equal(p.upgrades.length, before + 1, said());

  // ── replaced (4000) before it held, three times in a row: another station on this key, said once, a minute's wait ──
  p.plane.mode = "replaced";
  const held = p.upgrades.length;
  for (const ws of p.sockets) ws.close(4000, "replaced");
  const conflict = await given("presence.json says another station uses this key", () => (presence()?.conflict === true ? presence() : null), said);
  assert.equal(conflict.online, false, JSON.stringify(conflict));
  assert.match(String(conflict.error), /another station is using this station's key/);
  // the first close and two more sockets each replaced at once: three in a row, backed off 1 s and 2 s between
  const replaced = p.upgrades.slice(held);
  assert.equal(replaced.length, 2, said());
  assert.ok(replaced[1]!.at - replaced[0]!.at >= 1_500, `the second retry ${replaced[1]!.at - replaced[0]!.at} ms after the first: ${said()}`);
  const since = Date.now();
  await given("three seconds of the station's own time", () => Date.now() - since >= 3_000);
  assert.equal(p.upgrades.length, held + 2, `connected again within the minute's wait: ${said()}`);
  assert.equal(presence().conflict, true, said());
  // the station serving meanwhile, the same process
  assert.equal((await http(s.door, "/admin-api/host")).status, 200);
  assert.equal(s.alive(), true);
  await s.stop();
});

// ── 2. Comma's and Feishu's sockets refused and cut ──

/// Comma, of the test's: its socket refused in the handshake with 409 and Comma's words while `refuse` holds; taken
/// otherwise, told `connected`, its requests answered (`task.post`, the indexes), its own requests' answers kept.
async function commaStandIn() {
  const sockets: WebSocket[] = [];
  const upgrades: { at: number; refused: boolean }[] = [];
  const asked: any[] = [];
  const replies = new Map<string, any>();
  const state = { refuse: true };
  const why = "this still.fail workspace is connected to this Comma workspace already, as mini; disconnect that one in Comma's still.fail plugin first";
  const server = httpServer((_req, res) => res.writeHead(404).end());
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    upgrades.push({ at: Date.now(), refused: state.refuse });
    if (state.refuse) {
      const body = JSON.stringify({ error: why });
      socket.end(`HTTP/1.1 409 Conflict\r\ncontent-type: application/json\r\ncontent-length: ${Buffer.byteLength(body)}\r\nconnection: close\r\n\r\n${body}`);
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (data) => {
        const f = JSON.parse(String(data));
        if (f.type === "request") {
          asked.push(f);
          const result = f.method === "task.post" ? { seq: asked.length } : f.method === "stats.index" || f.method === "task.index" ? { epoch: f.params?.epoch ?? null, through: f.params?.through ?? 0 } : {};
          ws.send(JSON.stringify({ id: f.id, type: "response", result }));
        } else if (f.type === "response" || f.type === "error") replies.set(f.id, f);
      });
      ws.send(JSON.stringify({ type: "connected", connector_run_id: `run_${sockets.length}`, device_id: "dev_1" }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  let n = 0;
  const open = () => sockets.filter((s) => s.readyState === s.OPEN).at(-1);
  return {
    base: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, why, sockets, upgrades, asked, state, open,
    /// One of Comma's requests down the open socket, and the station's answer.
    async request(method: string, params: Record<string, unknown>) {
      const ws = open();
      assert.ok(ws !== undefined, "no Comma socket open");
      const id = `req-${++n}`;
      ws.send(JSON.stringify({ id, type: "request", method, params }));
      return given(`Comma's ${method} answered`, () => replies.get(id));
    },
  };
}

test("Comma's socket refused with 409 says Comma's words in its state, asked again on a backoff, then connected; cut, connected again; Feishu's token answered 503, then its long connection cut: connected again each time, its events taken; the station serving throughout", { skip, timeout: 60_000 }, async () => {
  const comma = await commaStandIn();
  const feishu = await FakeFeishu.start();
  closers.push(() => void feishu.close());
  // the app's token unavailable (a gateway's 503) twice before Feishu answers it
  let tokenRefusals = 2;
  feishu.answer("POST /open-apis/auth/v3/tenant_access_token/internal", (seen: any) =>
    tokenRefusals-- > 0
      ? new RawAnswer(Buffer.from('{"code":99991400,"msg":"service unavailable"}'), { "content-type": "application/json" }, 503)
      : { code: 0, tenant_access_token: `t-${seen.body?.app_id}`, expire: 7200 });
  const st = stationDir({
    language: "en",
    connects: [
      { id: "cm", kind: "comma", enabled: true, bind: { runtime: "claude" }, comma: { server: comma.base, token: "salix_conn_fault_1234" } },
      { id: "f1", kind: "feishu", enabled: true, bind: { runtime: "claude" }, feishu: { appId: "cli_test", appSecret: "sec-1", domain: "feishu" } },
    ],
  });
  const peers = [{ id: st.id, name: "mac" }];
  const p = await closingPlane(() => ({ workspace: "w1", workspace_name: "团队", name: "mac", peers }));
  cloudJson(st.data, { origin: p.origin, id: st.id, name: "mac", peers });
  const s = await launch(st.data, st.app, { STILLFAIL_FEISHU_API: feishu.base });
  let seen: unknown = null;
  const look = async (cid: string) => {
    const c = await connectionOf(s.door, cid);
    seen = c;
    return c;
  };
  const said = () => `connection=${JSON.stringify(seen)}; comma=${JSON.stringify(comma.upgrades)}; feishu=${JSON.stringify(feishu.seen.map((x) => x.path))}; ${s.err()}`;

  // ── Comma: refused with 409, its words said, asked again a backoff apart ──
  await given("Comma asked a third time", () => comma.upgrades.length >= 3, said);
  const refused = await given("cm's state says Comma's 409 and its words", async () => {
    const c = await look("cm");
    return c !== undefined && c.state !== "connected" && /409/.test(JSON.stringify(c)) && JSON.stringify(c).includes(comma.why) ? c : null;
  }, said);
  assert.notEqual(refused.state, "connected", JSON.stringify(refused));
  const gaps = comma.upgrades.slice(1).map((u, i) => u.at - comma.upgrades[i]!.at);
  assert.ok(gaps[0]! >= 800, `the first retry ${gaps[0]} ms after the refusal: ${said()}`);
  for (let i = 1; i < gaps.length; i++) assert.ok(gaps[i]! >= gaps[i - 1]! * 1.5, `retries backing off: ${JSON.stringify(gaps)}`);
  assert.equal((await http(s.door, "/admin-api/host")).status, 200, "the station serving while Comma refuses it");

  // ── taken once Comma lets it: connected, its requests answered ──
  comma.state.refuse = false;
  await given("cm connected once Comma takes it", async () => (await look("cm"))?.state === "connected", said, 30_000);
  const status1 = await comma.request("task.status", { task: "cnv_fault_1" });
  assert.equal(status1.type, "response", JSON.stringify(status1));

  // ── its socket cut (no close frame): connected again on its own ──
  const sockets = comma.sockets.length;
  comma.open()!.terminate();
  await given("a Comma socket again after the cut", () => comma.sockets.length > sockets && comma.open() !== undefined, said);
  await given("cm connected again after the cut", async () => (await look("cm"))?.state === "connected", said);
  const status2 = await comma.request("task.status", { task: "cnv_fault_1" });
  assert.equal(status2.type, "response", JSON.stringify(status2));
  assert.equal(comma.upgrades.filter((u) => !u.refused).length, 2, said());

  // ── Feishu: its token's 503s asked again, then its long connection opened, an event taken ──
  const tokens = () => feishu.calls("POST", "/open-apis/auth/v3/tenant_access_token/internal");
  await given("the Feishu socket open past the token's 503s", () => feishu.sockets.length >= 1, said, 30_000);
  assert.ok(tokens().length >= 3, `the token asked ${tokens().length} times: ${said()}`);
  await given("f1 connected", async () => (await look("f1"))?.state === "connected", said);
  const first = feishu.message({ id: "om_fault_1", text: "before the cut" });
  await given("Feishu's event taken", () => feishu.ack(first) !== undefined, said);

  // ── its long connection cut: connected again, the next event taken on the new socket ──
  const open = feishu.sockets.length;
  feishu.sockets.at(-1)!.terminate();
  await given("a Feishu socket again after the cut", () => feishu.sockets.length > open && feishu.sockets.at(-1)!.readyState === 1, said, 30_000);
  await given("f1 connected again after the cut", async () => (await look("f1"))?.state === "connected", said);
  const second = feishu.message({ id: "om_fault_2", text: "after the cut" });
  await given("Feishu's event taken after the cut", () => feishu.ack(second) !== undefined, said);

  // the station the same process throughout, serving
  assert.equal((await http(s.door, "/admin-api/host")).status, 200);
  assert.equal(s.alive(), true);
  await s.stop();
});

// ── 3. the release feed: read again past a gateway, never taken unsigned ──

// The tests' release key, another no station takes, and feeds signed as scripts/release-sign.ts signs them.
const releaseKey = () => {
  const { privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
  return { privateKey, raw, id: createHash("sha256").update(Buffer.from(raw, "base64")).digest("hex").slice(0, 16) };
};
const KEY = releaseKey();
const OTHER = releaseKey();
const ARCHIVE = "a".repeat(64);
const releaseWords = (build: number) => ({
  kind: "stillfail-station-release", version: `0.1.${build}`, build, commit: "0".repeat(40), node: "24.21.0",
  builds: Object.fromEntries(["darwin-arm64", "darwin-x64", "linux-x64", "linux-arm64"].map((p) => [p, { sha256: ARCHIVE, size: 1000, nodeSha256: "b".repeat(64) }])),
});
/// The feed of release `build`: signed by `key`; `tampered`, its words changed after they were signed.
const feedOf = (build: number, o: { key?: typeof KEY; tampered?: boolean } = {}) => {
  const words = Buffer.from(JSON.stringify(releaseWords(build)));
  const signature = sign(null, words, (o.key ?? KEY).privateKey).toString("base64");
  const given = o.tampered ? Buffer.from(JSON.stringify({ ...releaseWords(build), builds: { ...releaseWords(build).builds, "darwin-arm64": { sha256: "e".repeat(64), size: 1000, nodeSha256: "b".repeat(64) }, "linux-x64": { sha256: "e".repeat(64), size: 1000, nodeSha256: "b".repeat(64) } } })) : words;
  return { version: `0.1.${build}`, build, commit: "0".repeat(40), release: given.toString("base64"), signature, key: (o.key ?? KEY).id };
};

type Said = { status: number; body: unknown } | "cut";

/// The control plane of the test's with its releases: /releases/station.json answered as `next` says in turn (a
/// status and body, or `cut`: the connection destroyed before an answer), the last of it after; its presence socket
/// held.
async function releasePlane(stateOf: () => object) {
  const asked: { url: string; at: number }[] = [];
  const feed = { next: [] as Said[], last: { status: 200, body: feedOf(9500) } as Said };
  const sockets: WebSocket[] = [];
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => {
      const url = req.url ?? "";
      if (url.startsWith("/releases/")) {
        asked.push({ url, at: Date.now() });
        const now = url === "/releases/station.json" ? (feed.next.shift() ?? feed.last) : { status: 404, body: { error: "no" } };
        if (now === "cut") return void req.socket.destroy();
        return void res.writeHead(now.status, { "content-type": "application/json" }).end(JSON.stringify(now.body));
      }
      res.writeHead(200, { "content-type": "application/json" }).end("{}");
    });
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...stateOf() }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked, feed };
}

/// `stillfail-reader update --app … --data …` run to its end (not blocking this process, which serves its feed).
function updateCommand(app: string, data: string): Promise<{ code: number | null; out: string; err: string }> {
  return new Promise((resolve) => {
    const child = spawn(binary!, ["update", "--app", app, "--data", data], { env: { PATH: fresh("empty"), HOME: data, TMPDIR: tmpdir(), STILLFAIL_RELEASE_KEYS: KEY.raw }, stdio: ["ignore", "pipe", "pipe"] });
    children.push(child);
    let out = "";
    let err = "";
    child.stdout!.on("data", (d) => (out += d));
    child.stderr!.on("data", (d) => (err += d));
    child.on("exit", (code) => resolve({ code, out, err }));
  });
}

test("the release feed: `stillfail update` reads it again past a gateway's 502 and a cut connection, a refusal not asked again; a release whose signature does not verify, or by a key not taken, refused by the command and not offered by the running station", { skip, timeout: 60_000 }, async () => {
  const st = stationDir({ language: "en", updateChannel: "stable" });
  mkdirSync(join(st.app, "bin"), { recursive: true });
  writeFileSync(join(st.app, "bin", "install.en.sh"), "#!/bin/sh\nexit 0\n");
  chmodSync(join(st.app, "bin", "install.en.sh"), 0o755);
  const peers = [{ id: st.id, name: "mac" }];
  const p = await releasePlane(() => ({ workspace: "w1", workspace_name: "团队", name: "mac", peers }));
  cloudJson(st.data, { origin: p.origin, id: st.id, name: "mac", peers });
  const feedAsks = () => p.asked.filter((a) => a.url === "/releases/station.json");

  // ── a gateway's 502 and a cut connection, then the feed: read again after a second and two, the release planned ──
  p.feed.next = [{ status: 502, body: { error: "bad gateway" } }, "cut"];
  let asked = feedAsks().length;
  const again = await updateCommand(st.app, st.data);
  assert.equal(again.code, 0, `${again.out}\n${again.err}`);
  const lines = again.out.trim().split("\n");
  assert.equal(lines[0], `script=${join(st.app, "bin", "install.en.sh")}`, again.out);
  assert.ok(lines.includes(`STILLFAIL_RELEASE_SHA256=${ARCHIVE}`), again.out);
  assert.ok(lines.includes("STILLFAIL_CHANNEL=stable"), again.out);
  const reads = feedAsks().slice(asked);
  assert.equal(reads.length, 3, JSON.stringify(reads));
  assert.ok(reads[1]!.at - reads[0]!.at >= 900, `read again ${reads[1]!.at - reads[0]!.at} ms after the 502`);
  assert.ok(reads[2]!.at - reads[1]!.at >= 1_900, `read again ${reads[2]!.at - reads[1]!.at} ms after the cut`);

  // ── a refusal (404): failed at once, not asked again ──
  p.feed.next = [{ status: 404, body: { error: "no" } }];
  asked = feedAsks().length;
  const refused = await updateCommand(st.app, st.data);
  assert.equal(refused.code, 1, refused.out);
  assert.match(refused.err, /station\.json: 404/);
  assert.equal(feedAsks().length - asked, 1, "a refusal is not asked again");

  // ── words changed after they were signed, and words signed by a key the station does not take: refused, once each ──
  for (const [what, feed, words] of [
    ["tampered", feedOf(9500, { tampered: true }), /signature/i],
    ["another key's", feedOf(9500, { key: OTHER }), /does not take/],
  ] as const) {
    p.feed.next = [{ status: 200, body: feed }];
    asked = feedAsks().length;
    const r = await updateCommand(st.app, st.data);
    assert.equal(r.code, 1, `${what}: ${r.out}`);
    assert.equal(r.out, "", `${what}: nothing to run said`);
    assert.match(r.err, words, `${what}: ${r.err}`);
    assert.equal(feedAsks().length - asked, 1, `${what}: read once`);
  }

  // ── the running station: a release that does not verify not offered, the station serving; a verified one offered ──
  p.feed.last = { status: 200, body: feedOf(9500, { tampered: true }) };
  const s = await launch(st.data, st.app, { STILLFAIL_RELEASE_KEYS: KEY.raw });
  const check = async () => {
    const r = await http(s.door, "/admin-api/updates/check", { method: "POST" });
    assert.equal(r.status, 200, r.text);
    return r.json.find((x: any) => x.id === "station");
  };
  const unverified = await check();
  // (no latest: left out of the answer, as JSON.stringify leaves the TypeScript's undefined)
  assert.deepEqual([unverified.version, unverified.latest, unverified.newer], ["0.1.9400", undefined, false], JSON.stringify(unverified));
  await given("the station says why it was not offered", () => /does not verify: not offered/.test(s.err()), s.err);
  assert.equal((await http(s.door, "/admin-api/host")).status, 200);
  // a gateway's 502 for the station's own read: not offered this time (it is read again at the next check), nothing
  // broken by it
  p.feed.next = [{ status: 502, body: { error: "bad gateway" } }];
  p.feed.last = { status: 200, body: feedOf(9500) };
  assert.equal((await check()).latest, undefined);
  const verified = await check();
  assert.deepEqual([verified.version, verified.latest, verified.newer], ["0.1.9400", "0.1.9500", true], JSON.stringify(verified));
  assert.equal(s.alive(), true);
  await s.stop();
});

// ── 4. a chat moved between two stations, and a move to one that is down ──

/// Where the store of `data` says chat `key` was handed (its `handed_over` row, read now: the Store keeps it in memory).
function handedTo(data: string, key: string): { station: string } | null {
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    return (db.prepare("SELECT station FROM handed_over WHERE session = ?").get(key) as { station: string } | undefined) ?? null;
  } finally {
    db.close();
  }
}

/// Every file under `dir` (its links not followed): its path, mode and SHA-256.
function treeOf(dir: string): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (at: string) => {
    for (const name of readdirSync(at)) {
      const full = join(at, name);
      const st = statSync(full);
      if (st.isDirectory()) walk(full);
      else out[relative(dir, full)] = `${(st.mode & 0o777).toString(8)} ${createHash("sha256").update(readFileSync(full)).digest("hex")}`;
    }
  };
  walk(dir);
  return out;
}

test("a chat moved to another station over real iroh: its files there byte for byte, the station it left saying where it went, read and sent to from there; moved back with nothing said twice; a move to a station that is down refused, the chat and its files untouched and answering here", { skip: skipAgents, timeout: 120_000 }, async () => {
  const profiles = [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc", access: { kind: "anthropic-api", key: "sk-ant-move-test" }, models: ["claude-opus-5-5"] }];
  // (both on the test channel, where moving is offered)
  const [a, b] = [stationDir({ language: "en", updateChannel: "beta", profiles, maxNudges: 0 }), stationDir({ language: "en", updateChannel: "beta", profiles, maxNudges: 0 })];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: a.id, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: b.id, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const p = await closingPlane((station) => ({ workspace: "w1", workspace_name: "团队", name: station === a.id ? "alpha" : "beta", peers }));
  cloudJson(a.data, { origin: p.origin, id: a.id, name: "alpha", peers });
  cloudJson(b.data, { origin: p.origin, id: b.id, name: "beta", peers });
  const binOf = (prefix: string) => {
    const bin = toolsPath();
    fakeClaude(bin, prefix);
    return bin;
  };
  // (one place for both fakes' notes: a session's prompts counted across the stations it runs on)
  const out = fresh("out");
  const alpha = await launch(a.data, a.app, { PATH: binOf("alpha-reply"), FAKE_OUT: out, FAKE_STATION: "alpha", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` });
  const beta = await launch(b.data, b.app, { PATH: binOf("beta-reply"), FAKE_OUT: out, FAKE_STATION: "beta", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}` });
  /// How each runtime process began, in order: its station, `new` or `resume`, its runtime session.
  const started = () => (existsSync(join(out, "started")) ? readFileSync(join(out, "started"), "utf8").trim().split("\n") : []);
  for (const d of [a.data, b.data]) await given("online at the plane", () => readJson(join(d, "run", "presence.json"))?.online === true, () => `${alpha.err()}\n${beta.err()}`);
  const both = () => `alpha: ${alpha.err()}\nbeta: ${beta.err()}`;
  const storeA = Store.open(join(a.data, "stillfail.db"), join(a.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const storeB = Store.open(join(b.data, "stillfail.db"), join(b.data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  closers.push(() => storeA.close(), () => storeB.close());
  const texts = async (port: number, thread: number): Promise<string[]> => {
    const r = await http(port, `/admin-api/threads/${thread}/entries`);
    assert.equal(r.status, 200, r.text);
    return (r.json.entries as any[]).filter((e) => e.kind === "message").map((e) => String(e.text));
  };
  const ended = (store: Store, key: string, n: number) => store.listTurns(key).filter((t) => t.summary.endedAt != null).length >= n;

  // a chat on alpha: a message, its turn answered, files in its workspace (text, binary, nested, an executable)
  const made = await http(alpha.door, "/admin-api/sessions", { body: { runtime: "claude", profile: "cc" } });
  assert.equal(made.status, 200, made.text);
  const key: string = made.json.key;
  const threadA: number = made.json.thread?.id ?? made.json.thread?.thread?.id;
  assert.equal((await http(alpha.door, `/admin-api/threads/${threadA}/messages`, { body: { text: "the first message, on alpha" } })).status < 300, true);
  await given("alpha's turn answered", () => ended(storeA, key, 1), both);
  await given("alpha's answer in the chat", async () => (await texts(alpha.door, threadA)).includes("alpha-reply-1"), both);
  const ws = storeA.getSession(key)!.workspace;
  writeFileSync(join(ws, "notes.md"), "# notes\nwritten on alpha\n");
  mkdirSync(join(ws, "deep", "er"), { recursive: true });
  writeFileSync(join(ws, "deep", "er", "blob.bin"), randomBytes(300_000));
  writeFileSync(join(ws, "run.sh"), "#!/bin/sh\necho moved\n");
  chmodSync(join(ws, "run.sh"), 0o755);
  const files = treeOf(ws);
  // another chat on alpha, whose agent reads and writes to the moved one
  const other = await http(alpha.door, "/admin-api/sessions", { body: { runtime: "claude", profile: "cc" } });
  assert.equal(other.status, 200, other.text);
  const otherToken = storeA.getSession(other.json.key)!.token;

  const movePage = async () => (await http(alpha.door, `/admin-api/move?to=${b.id}`)).json;
  const itemOf = (page: any) => page?.modules?.find((m: any) => m.id === "chats")?.items?.find((x: any) => x.id === key);
  await given("the chat movable to beta", async () => {
    const i = itemOf(await movePage());
    return i?.state === "here" && i.cannot === undefined;
  }, async () => `${JSON.stringify(await movePage())}; ${both()}`, 30_000);

  // ── moved to beta ──
  const moved = await http(alpha.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: key, withNeeds: true } });
  assert.equal(moved.status, 202, moved.text);
  await given("the chat there", async () => {
    const page = await movePage();
    return page?.moving === null && itemOf(page)?.state === "there";
  }, async () => `${JSON.stringify(await movePage())}; ${both()}`, 45_000);
  // alpha says where it went; beta holds it, its files byte for byte (and their modes)
  assert.equal(handedTo(a.data, key)?.station, b.id, JSON.stringify(handedTo(a.data, key)));
  const there = await given("the session on beta", () => storeB.getSession(key), both);
  assert.deepEqual(treeOf(there.workspace), files);
  const threadB = storeB.sessionThreads(key)[0]!.thread.id;
  assert.deepEqual(await texts(beta.door, threadB), ["the first message, on alpha", "alpha-reply-1"]);

  // ── read and sent to from alpha, by another chat's agent: answered on beta ──
  const read = await tool(alpha.door, otherToken, "chat_read", { chat: key });
  assert.equal(read.error, false, read.text);
  assert.match(read.text, /the first message, on alpha/);
  assert.match(read.text, /alpha-reply-1/);
  const sent = await tool(alpha.door, otherToken, "session_send", { to: key, text: "sent from alpha's other chat" });
  assert.equal(sent.error, false, sent.text);
  await given("beta's turn on what alpha sent", () => ended(storeB, key, 2), both);
  await given("beta's answer in the chat", async () => (await texts(beta.door, threadB)).includes("beta-reply-2"), both);
  // beta took up the chat's runtime session (its transcript carried), not one of its own
  const [first] = started();
  const sid = first!.split(" ")[2]!;
  assert.deepEqual(started(), [`alpha new ${sid}`, `beta resume ${sid}`]);
  assert.equal(storeA.listTurns(key).length, 1, "nothing more ran on alpha");

  // ── moved back: everything once, the files as they were ──
  const back = await http(alpha.door, "/admin-api/move/back", { body: { from: b.id, module: "chats", item: key } });
  assert.equal(back.status, 202, back.text);
  await given("the chat here again", async () => {
    const page = await movePage();
    return page?.moving === null && itemOf(page)?.state === "here";
  }, async () => `${JSON.stringify(await movePage())}; ${both()}`, 45_000);
  assert.equal(handedTo(a.data, key), null);
  const home = storeA.getSession(key)!;
  assert.deepEqual(treeOf(home.workspace), files);
  const said = await texts(alpha.door, threadA);
  for (const t of ["the first message, on alpha", "alpha-reply-1", "beta-reply-2"]) assert.equal(said.filter((x) => x === t).length, 1, `${t} once: ${JSON.stringify(said)}`);
  // (a session_send stays out of the chat's conversation: its agent took it, nobody sees it there, here or there)
  assert.deepEqual(said, ["the first message, on alpha", "alpha-reply-1", "beta-reply-2"]);

  // ── beta down: a move to it refused in words saying what to do (its station not reached: asked for an answer
  // ANSWER_MS, mesh/peer.ts's 30 s, as the TypeScript asks it), nothing held, the chat here as it was and answering ──
  await beta.stop();
  const turns = storeA.listTurns(key).length;
  const tried = await http(alpha.door, "/admin-api/move", { body: { to: b.id, module: "chats", item: key, withNeeds: true } });
  assert.equal(tried.status, 409, tried.text);
  assert.match(String(tried.json?.error), /beta/);
  assert.equal(handedTo(a.data, key), null, tried.text);
  const row = (() => {
    const db = new DatabaseSync(join(a.data, "stillfail.db"), { readOnly: true });
    try {
      db.exec("PRAGMA busy_timeout = 5000;");
      return db.prepare("SELECT ws FROM sessions WHERE key = ?").get(key) as { ws: string | null };
    } finally {
      db.close();
    }
  })();
  assert.equal(row.ws, null, "in sight here, of the home workspace: not held as handed or coming");
  assert.deepEqual(treeOf(storeA.getSession(key)!.workspace), files);
  assert.deepEqual(await texts(alpha.door, threadA), said);
  assert.equal((await http(alpha.door, `/admin-api/threads/${threadA}/messages`, { body: { text: "still here" } })).status < 300, true);
  await given("alpha answers the chat after the failed move", () => ended(storeA, key, turns + 1), both);
  await given("alpha's answer after the failed move", async () => (await texts(alpha.door, threadA)).includes("alpha-reply-3"), async () => `${JSON.stringify(await texts(alpha.door, threadA))}; ${both()}`);
  // the same runtime session taken up again here, once back
  assert.deepEqual(started(), [`alpha new ${sid}`, `beta resume ${sid}`, `alpha resume ${sid}`]);
  assert.deepEqual(await texts(alpha.door, threadA), [...said, "still here", "alpha-reply-3"]);
  await alpha.stop();
});
