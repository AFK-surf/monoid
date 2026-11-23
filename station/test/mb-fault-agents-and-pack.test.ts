// Faults and edges of the station's agents, its own processes and what it sends another station, as the MoonBit
// program runs them (station/mb src/station_main), held through the program itself and never the TypeScript station:
// `stillfail-reader run` with the launcher's descriptors, its agents under the real `stillfail-runner` (a fake Claude
// Code of /bin/sh and curl), two stations on loopback iroh, every program run with a PATH that names no Node. What the
// TypeScript's own tests hold of these, held here of the program: a conversation whose resume fails for a limit kept
// and resumed once that passes, and what is said while it compacts held until it is done, given once
// (agent-start-errors.test.ts, context.test.ts); idle processes beyond the warm limit ended past warmMs, their groups
// gone, the newest kept (warm-evict.test.ts); a job's memory counted under the station's programs and its runaway log
// held to its bound with the station serving throughout (self-memory.test.ts); hundreds of small files synced to
// another station byte for byte, again after edits, nothing left in the landing places, and that station gone said in
// words at once by its tasks, its files and a grant's commands to run there (sending-pack.test.ts,
// vault-elsewhere.test.ts).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { createSocket } from "node:dgram";
import {
  chmodSync, closeSync, existsSync, lstatSync, mkdirSync, mkdtempSync, openSync, readFileSync, readSync, readdirSync, readlinkSync, rmSync, statSync,
  symlinkSync, unlinkSync, writeFileSync,
} from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors and signals are Unix's"
  : false;
const skipRunner = skip !== false ? skip
  : runner === "" || !existsSync(runner) ? "no stillfail-runner (run under scripts/native.ts run runner)"
  : !existsSync("/usr/bin/curl") ? "no /usr/bin/curl for the fake runtime"
  : false;

const dirs: string[] = [];
// (short: a runner's and the status's Unix sockets are at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfa-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
const groups: number[] = [];
after(async () => {
  for (const c of closers.splice(0)) {
    try { c(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const g of groups) try { process.kill(-g, "SIGKILL"); } catch {}
  // (what a failed run left: the station, its front and runners, by what their files say)
  for (const d of dirs) {
    for (const f of ["run/station.json", "run/front.pid"]) {
      try {
        const text = readFileSync(join(d, f), "utf8");
        const pid = Number(text.trim().startsWith("{") ? JSON.parse(text).pid : text.trim());
        if (pid > 0 && pid !== process.pid) process.kill(pid, "SIGKILL");
      } catch {}
    }
    const runners = join(d, "run", "runners");
    if (existsSync(runners)) {
      for (const f of readdirSync(runners).filter((n) => n.endsWith(".json"))) {
        try {
          const info = JSON.parse(readFileSync(join(runners, f), "utf8"));
          try { process.kill(-info.pgid, "SIGKILL"); } catch {}
          try { process.kill(info.runner, "SIGKILL"); } catch {}
        } catch {}
      }
    }
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const alive = (pid: number, group = false) => {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// What comes true within `ms` (a real process's end, a file the station writes, a peer's answer: nothing here is told
/// of them).
async function within<T>(what: string, ms: number, look: () => Promise<T | null | undefined | false> | T | null | undefined | false, detail: () => string = () => ""): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const got = await look();
      if (got !== null && got !== undefined && got !== false) return got;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}${last ? ` (${(last as Error).message})` : ""}; ${detail()}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

/// The commands the station and its jobs run, each linked into a directory of its own: its PATH, so no Node is.
const TOOLS = ["sh", "ps", "mv", "cat", "sleep", "echo", "printf", "env", "kill", "sed", "tr", "head", "rm", "mkdir", "ls", "uname", "lsof", "id", "curl", "dd", "true"];
function toolsPath(): string {
  const dir = fresh("path");
  const look = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  for (const t of TOOLS) {
    const found = look.map((d) => join(d, t)).find((p) => existsSync(p));
    if (found !== undefined && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}
const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

const freeUdpPort = async () => {
  const s = createSocket("udp4");
  await new Promise<void>((r) => s.bind(0, "127.0.0.1", () => r()));
  const port = s.address().port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
};

type Launched = { child: ChildProcess; door: number; ended: Promise<number | null>; err: () => string; stop: () => Promise<void> };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe, ready
/// and serving its agents' door.
async function launch(data: string, env: Record<string, string> = {}, build = "9800"): Promise<Launched> {
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), `${build}\n`);
  const listener = () => new Promise<Server>((resolve) => {
    const s = tcpServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { PATH: toolsPath(), HOME: data, TMPDIR: tmpdir(), STILLFAIL_RUNNER: runner, STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1", ...env },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const next = (what: string, ok: (m: any) => boolean) => new Promise<any>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err.slice(-4000)}`)), 30_000);
    const look = () => {
      const found = said.find(ok);
      if (found !== undefined) {
        clearTimeout(timer);
        resolve(found);
      } else waiters.push(look);
    };
    look();
  });
  await next("ready", (m) => m.ready === true);
  const door = (await next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const stop = async () => {
    if (child.exitCode !== null || child.signalCode !== null) return;
    channel.write(`${JSON.stringify({ op: "stop" })}\n`);
    assert.equal(await ended, 0, err.slice(-4000));
  };
  return { child, door, ended, err: () => err, stop };
}

type Answer = { status: number; body: Buffer; json: any };
function http(port: number, path: string, o: { method?: string; body?: unknown; headers?: Record<string, string> } = {}): Promise<Answer> {
  return new Promise((resolve, reject) => {
    const body = o.body === undefined ? undefined : Buffer.from(JSON.stringify(o.body));
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json", ...(o.headers ?? {}) }, agent: false }, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (d) => chunks.push(d));
      res.on("end", () => {
        const all = Buffer.concat(chunks);
        let json: any = null;
        try { json = JSON.parse(all.toString()); } catch {}
        resolve({ status: res.statusCode!, body: all, json });
      });
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end(body);
  });
}

/// A tool of the agents' door, as session `token`'s agent calls it.
async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { body: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body.toString());
  assert.equal(r.json.error, undefined, r.body.toString());
  return { text: r.json.result.content[0].text, error: r.json.result.isError === true };
}

function openStore(data: string) {
  return Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
}

/// The live store written on a connection of its own (the station writes it meanwhile).
function write(data: string, sql: string, ...args: (string | number | null)[]) {
  const db = new DatabaseSync(join(data, "stillfail.db"));
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    db.prepare(sql).run(...args);
  } finally {
    db.close();
  }
}

/// A value of the live store, read on a connection of its own (the station writes it meanwhile).
function one(data: string, sql: string, ...args: (string | number)[]): unknown {
  const db = new DatabaseSync(join(data, "stillfail.db"));
  try {
    db.exec("PRAGMA busy_timeout = 5000;");
    const r = db.prepare(sql).get(...args) as Record<string, unknown> | undefined;
    return r === undefined ? undefined : Object.values(r)[0];
  } finally {
    db.close();
  }
}

/// A station's data directory in workspace `W1`, as the control plane last said it.
function enrolled(data: string) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9/", station: "abc", workspace: "W1", workspace_name: "Dev", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [],
  }));
}

/// runnerId (agents/process.ts): the runtime and the key's part (sandbox-name.ts `keyPart`).
function runnerId(kind: string, key: string): string {
  const clean = key.replace(/[^A-Za-z0-9_-]/g, "_").slice(0, 24);
  return `${kind}-${clean === key ? clean : `${clean}-${createHash("sha256").update(key).digest("hex").slice(0, 10)}`}`;
}

/// What the runner of session `key`'s agent says of itself: its pid and its agent's group.
function runnerOf(data: string, key: string): { runner: number; pid: number; pgid: number } | null {
  try {
    const info = JSON.parse(readFileSync(join(data, "run", "runners", `${runnerId("claude", key)}.json`), "utf8"));
    return typeof info.runner === "number" && typeof info.pgid === "number" ? info : null;
  } catch {
    return null;
  }
}

// ── agents: a resume failing for a limit, and a compaction (agent-start-errors.test.ts, context.test.ts) ──

/// A fake Claude Code of /bin/sh and curl. Each start is logged (`start new|resume <id>`), each user line it reads
/// (`user <its tag> <busy|idle>`); each prompt is written to its transcript where `--resume` finds it, and answered by
/// a chat_post of all_done naming its tag. Resumed while `<ctl>/limit` is there, it reads its prompt (`limited <tag>`),
/// says Anthropic's rate limit and ends. `/compact` is compacted only once `<ctl>/release` is there, what it reads meanwhile
/// logged as `busy`.
function fakeClaude(bin: string, log: string, ctl: string) {
  const [sed, grep, tr] = ["sed", "grep", "tr"].map((t) => ["/usr/bin", "/bin"].map((d) => join(d, t)).find((p) => existsSync(p)) ?? t);
  const claude = `#!/bin/sh
case " $* " in *" -p "*) ;; *) exit 9 ;; esac
sid=""; cfg=""; how=new
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) sid="$2"; shift ;;
    --resume) sid="$2"; how=resume; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
printf 'start %s %s\\n' "$how" "$sid" >> '${log}'
if [ "$how" = resume ] && [ -f '${ctl}/limit' ]; then
  # (the prompt read first: it ends during its turn, whenever the station wrote it)
  IFS= read -r line
  printf 'limited %s\\n' "$(printf '%s' "$line" | ${grep} -o 'tag-[a-z0-9]*' | ${tr} '\\n' ',' | ${sed} 's/,$//')" >> '${log}'
  printf '%s\\n' 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization"}}' >&2
  exit 1
fi
proj=$(pwd -P | ${sed} 's/[^A-Za-z0-9]/-/g')
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$proj"
transcript="$CLAUDE_CONFIG_DIR/projects/$proj/$sid.jsonl"
url=$(printf '%s' "$cfg" | ${sed} -n 's/.*"url":"\\([^"]*\\)".*/\\1/p')
say() { printf '%s\\n' "$1"; }
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  tag=$(printf '%s' "$line" | ${grep} -o 'tag-[a-z0-9]*' | ${tr} '\\n' ',' | ${sed} 's/,$//')
  if [ -f '${ctl}/compacting' ]; then state=busy; else state=idle; fi
  case "$line" in *'"/compact"'*) tag=compact ;; esac
  printf 'user %s %s\\n' "\${tag:-none}" "$state" >> '${log}'
  printf '%s\\n' "$line" >> "$transcript"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  if [ "$tag" = compact ]; then
    : > '${ctl}/compacting'
    (
      while [ ! -f '${ctl}/release' ]; do sleep 0.05; done
      rm -f '${ctl}/release' '${ctl}/compacting'
      printf 'compacted\\n' >> '${log}'
      say '{"type":"system","subtype":"compact_boundary","session_id":"'"$sid"'","compact_metadata":{"trigger":"manual","pre_tokens":1000}}'
      say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":""}'
    ) &
    continue
  fi
  to=$(printf '%s' "$line" | ${sed} -n 's/.*thread=\\\\"\\([^\\\\]*\\)\\\\".*/\\1/p')
  /usr/bin/curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \\
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","text":"answered '"$tag"'","kind":"all_done","done":"answered '"$tag"'"}}}' > /dev/null
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"posted"}'
done
`;
  writeFileSync(join(bin, "claude"), claude);
  chmodSync(join(bin, "claude"), 0o755);
}

/// A station with profile `cc` of Claude Code (the fake on its PATH), `extra` in its config.json.
function claudeStation(extra: Record<string, unknown> = {}) {
  const data = fresh("ag");
  const bin = toolsPath();
  const ctl = fresh("ctl");
  const log = join(ctl, "log");
  writeFileSync(log, "");
  enrolled(data);
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }], maxNudges: 0, ...extra }));
  fakeClaude(bin, log, ctl);
  return { data, bin, ctl, log, lines: () => readFileSync(log, "utf8").split("\n").filter((l) => l !== "") };
}

/// Chats `keys` of the station (each a session with its thread), and a session `chat:c-from` (token t0) that sends
/// them messages.
function chats(store: Store, data: string, keys: string[]) {
  const made = (key: string, token: string, ts: string) => {
    const workspace = join(data, "sessions", "chat", key.slice(5), "workspace");
    mkdirSync(workspace, { recursive: true });
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace, token, createdAt: Date.now(), lastActiveAt: Date.now(), title: key } as never);
    const thread = store.openThread("ember", "CHAT", ts, key, "ada@x.com");
    store.joinThread(thread.id, key, "ember");
    return thread;
  };
  made("chat:c-from", "t0", "1790000000.000001");
  return keys.map((k, i) => made(k, `t-${k}`, `1790000000.00010${i}`));
}

test("a resume failing for the account's limit keeps its conversation, resumed as it was once the limit passes; what is said while it compacts waits for it and is given once, after", { skip: skipRunner, timeout: 60_000 }, async () => {
  const s = claudeStation();
  const a = await launch(s.data, { PATH: s.bin, STILLFAIL_LOCAL_ADMIN: "1" });
  const store = openStore(s.data);
  try {
    const [thread] = chats(store, s.data, ["chat:c-to"]);
    const agentSaid = () => store.messagesBefore(thread!.id, null, 50).filter((m) => m.authorKind === "agent").map((m) => m.text);
    const notices = () => store.messagesBefore(thread!.id, null, 50).filter((m) => m.authorKind === "station").map((m) => m.text);
    const detail = () => `${JSON.stringify(s.lines())}; agent ${JSON.stringify(agentSaid())}; notices ${JSON.stringify(notices())}; ${a.err().slice(-3000)}`;
    const send = async (text: string) => {
      const sent = await tool(a.door, "t0", "session_send", { to: "chat:c-to", text });
      assert.equal(sent.error, false, sent.text);
    };
    const pending = () => one(s.data, "SELECT COUNT(*) FROM letter_deliveries WHERE session = ? AND delivered_at IS NULL", "chat:c-to");
    const settled = () => store.getSession("chat:c-to")!.running !== true && store.listTurns("chat:c-to").every((t) => t.summary.endedAt != null);

    // Its first turn: a conversation of its own, answered.
    await send("first tag-one");
    await within("tag-one answered", 20_000, () => agentSaid().includes("answered tag-one") && settled(), detail);
    const first = store.getSession("chat:c-to")!.runtimeSessionId!;
    assert.ok(typeof first === "string" && first.length > 0, detail());
    assert.deepEqual(s.lines().filter((l) => l.startsWith("start")), [`start new ${first}`]);

    // Its process let go (as warmMs or the machine's pressure lets it go): the next turn resumes it.
    const evicted = await http(a.door, `/admin-api/sessions/${encodeURIComponent("chat:c-to")}/evict`, { method: "POST", body: {} });
    assert.equal(evicted.status, 200, evicted.body.toString());
    await within("its process gone", 15_000, () => runnerOf(s.data, "chat:c-to") === null, detail);

    // Resumed while the account is limited: the runtime takes the prompt and ends saying so. Said in its chat as an
    // agent that ended in its turn, with why; the conversation stays the session's, no new one opened.
    writeFileSync(join(s.ctl, "limit"), "");
    await send("limited tag-two");
    await within("the limited resume tried, said, and its turn over", 20_000, () => s.lines().includes("limited tag-two") && notices().length > 0 && settled(), detail);
    assert.deepEqual(s.lines().filter((l) => l.startsWith("start")), [`start new ${first}`, `start resume ${first}`], detail());
    assert.equal(notices().length, 1, detail());
    assert.ok(notices()[0]!.startsWith("⚠️ agent 进程意外退出") && notices()[0]!.includes("rate_limit_error"), detail());
    assert.equal(store.getSession("chat:c-to")!.runtimeSessionId, first, `the conversation is still the session's: ${detail()}`);
    assert.equal(pending(), 0, detail());

    // The limit passed: the next message resumes the same conversation, given once.
    unlinkSync(join(s.ctl, "limit"));
    await send("again tag-three");
    await within("tag-three answered", 20_000, () => agentSaid().some((t) => t.includes("tag-three")) && settled(), detail);
    assert.deepEqual(s.lines().filter((l) => l.startsWith("start")), [`start new ${first}`, `start resume ${first}`, `start resume ${first}`], `no new conversation opened: ${detail()}`);
    assert.equal(store.getSession("chat:c-to")!.runtimeSessionId, first, detail());
    assert.deepEqual(s.lines().filter((l) => l.startsWith("user ")), ["user tag-one idle", "user tag-three idle"], detail());
    assert.equal(pending(), 0);

    // Compacted by hand between turns; a message said meanwhile is not steered into the compaction, it is given once
    // the compaction is done, once.
    const compact = await http(a.door, `/admin-api/sessions/${encodeURIComponent("chat:c-to")}/compact`, { method: "POST", body: {} });
    assert.equal(compact.status, 200, compact.body.toString());
    await within("the compaction under way", 15_000, () => existsSync(join(s.ctl, "compacting")) && s.lines().includes("user compact idle"), detail);
    assert.equal(store.getSession("chat:c-to")!.running, true, "shown at work while it compacts");
    await send("meanwhile tag-four");
    // (sent: kept for the session, not written to the runtime while it compacts)
    assert.equal(pending(), 1, detail());
    assert.deepEqual(s.lines().filter((l) => l.includes("tag-four")), [], detail());
    writeFileSync(join(s.ctl, "release"), "");
    await within("tag-four answered after the compaction", 20_000, () => agentSaid().includes("answered tag-four") && settled(), detail);
    const lines = s.lines();
    assert.deepEqual(lines.filter((l) => l.includes("tag-four")), ["user tag-four idle"], `given once, after: ${detail()}`);
    assert.ok(lines.indexOf("compacted") < lines.indexOf("user tag-four idle"), detail());
    assert.deepEqual(agentSaid().filter((t) => t === "answered tag-four"), ["answered tag-four"]);
    assert.equal(pending(), 0);
    assert.ok(notices().some((n) => n.includes("压缩")), detail());
    assert.equal(store.getSession("chat:c-to")!.runtimeSessionId, first);
  } finally {
    store.close();
  }
  await a.stop();
});

// ── warm processes let go (warm-evict.test.ts) ──

test("idle processes beyond the warm limit end once idle past warmMs, oldest first, each with its whole group; the one used last is kept, and one let go is resumed as it was", { skip: skipRunner, timeout: 60_000 }, async () => {
  // warmMinutes 0.05: warmMs of 3 s; one kept warm.
  const s = claudeStation({ warmMinutes: 0.05, maxWarmClaude: 1 });
  const a = await launch(s.data, { PATH: s.bin });
  const store = openStore(s.data);
  try {
    const keys = ["chat:c-a", "chat:c-b", "chat:c-c"];
    const threads = chats(store, s.data, keys);
    const answered = (i: number, tag: string) => store.messagesBefore(threads[i]!.id, null, 50).some((m) => m.authorKind === "agent" && m.text === `answered ${tag}`);
    const idle = (key: string) => store.getSession(key)!.running !== true && store.listTurns(key).every((t) => t.summary.endedAt != null);
    const runners = () => Object.fromEntries(keys.map((k) => [k, runnerOf(s.data, k)]));
    const detail = () => `${JSON.stringify(runners())}; ${JSON.stringify(s.lines())}; ${a.err().slice(-3000)}`;
    const gone = (r: { runner: number; pid: number; pgid: number }) => !alive(r.runner) && !alive(r.pid) && !alive(r.pgid, true);

    // Each answers a message and is left idle, its process kept warm, a after b after c.
    const held: Record<string, { runner: number; pid: number; pgid: number }> = {};
    for (const [i, key] of keys.entries()) {
      const sent = await tool(a.door, "t0", "session_send", { to: key, text: `hello tag-${i}` });
      assert.equal(sent.error, false, sent.text);
      await within(`${key} answered and idle`, 20_000, () => answered(i, `tag-${i}`) && idle(key) && runnerOf(s.data, key) !== null, detail);
      held[key] = runnerOf(s.data, key)!;
      groups.push(held[key]!.pgid);
      assert.ok(alive(held[key]!.pid), `${key}'s process runs, idle`);
    }

    // Past warmMs, the two idle longest go, their runners and groups with them; the one idle least is kept.
    await within("a and b let go", 15_000, () => gone(held["chat:c-a"]!) && gone(held["chat:c-b"]!), detail);
    await within("their runners' files gone", 5_000, () => runnerOf(s.data, "chat:c-a") === null && runnerOf(s.data, "chat:c-b") === null, detail);
    assert.ok(alive(held["chat:c-c"]!.pid) && alive(held["chat:c-c"]!.pgid, true), `within the limit: kept warm; ${detail()}`);
    assert.deepEqual(runnerOf(s.data, "chat:c-c"), held["chat:c-c"]);

    // a used again: resumed (its conversation), its new process now the one used last; c, idle longer, goes past warmMs
    // and a is kept.
    const sid = store.getSession("chat:c-a")!.runtimeSessionId;
    const again = await tool(a.door, "t0", "session_send", { to: "chat:c-a", text: "back tag-again" });
    assert.equal(again.error, false, again.text);
    await within("a answered again and idle", 20_000, () => answered(0, "tag-again") && idle("chat:c-a") && runnerOf(s.data, "chat:c-a") !== null, detail);
    assert.ok(s.lines().includes(`start resume ${sid}`), detail());
    const back = runnerOf(s.data, "chat:c-a")!;
    groups.push(back.pgid);
    await within("c let go", 15_000, () => gone(held["chat:c-c"]!) && runnerOf(s.data, "chat:c-c") === null, detail);
    assert.ok(alive(back.pid) && alive(back.pgid, true), `the one used last kept: ${detail()}`);
    assert.equal(store.getSession("chat:c-a")!.runtimeSessionId, sid);
    assert.equal((a.err().match(/evicting idle session process/g) ?? []).length, 3, detail());
  } finally {
    store.close();
  }
  await a.stop();
});

// ── a runaway job and the station's own memory (self-memory.test.ts) ──

test("a runaway job: its output past the log's bound cut where it is on upkeep, its last 64 MiB kept in .1; the station's own memory not grown by it, its door answering throughout, its programs counted; the job's group ended on stop", { skip, timeout: 60_000 }, async () => {
  const data = fresh("mem");
  const work = fresh("work");
  enrolled(data);
  const a = await launch(data, { STILLFAIL_PARTS_DOOR: "1" });
  const store = openStore(data);
  const MiB = 1024 * 1024;
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const sample = async () => {
      const r = await http(a.door, "/parts/ask/memory.sample", { body: {} });
      assert.equal(r.status, 200, r.body.toString());
      return r.json as { wholeRssMb: number; mbChildrenRssMb: number };
    };
    // (its helpers started as a station's first jobs and upkeep start them, before it is measured: what they take is
    // theirs, not the runaway job's)
    const warm = JSON.parse((await tool(a.door, "t1", "job_start", { name: "warm", command: "true" })).text);
    await within("the warm-up job ended", 10_000, () => store.getJob(warm.id)?.state === "exited");
    assert.equal((await tool(a.door, "t1", "job_list")).error, false);
    assert.equal((await http(a.door, "/parts/ask/upkeep", { method: "POST", body: {} })).status, 200);
    const before = await sample();

    // 96 MiB written to its log as fast as dd writes, then it idles.
    const job = JSON.parse((await tool(a.door, "t1", "job_start", { name: "flood", command: "dd if=/dev/zero bs=1048576 count=96 2>/dev/null; echo done-flooding; exec sleep 600" })).text);
    const pgid = await within("its group recorded", 5_000, () => store.getJob(job.id)?.pgid ?? null);
    groups.push(pgid);
    const log = store.getJob(job.id)!.log as string;
    let slowest = 0;
    await within("its 96 MiB written, the door asked meanwhile", 30_000, async () => {
      const t0 = Date.now();
      const listed = await tool(a.door, "t1", "job_list");
      slowest = Math.max(slowest, Date.now() - t0);
      assert.equal(listed.error, false, listed.text);
      return existsSync(log) && statSync(log).size === 96 * MiB + "done-flooding\n".length;
    }, () => `${existsSync(log) ? statSync(log).size : "no log"}; ${a.err().slice(-2000)}`);
    assert.ok(slowest < 2_000, `the door answered within 2 s while the job flooded its log: ${slowest} ms`);
    const inode = statSync(log).ino;

    // Upkeep: the log cut where it is (the job's shell appends to it still), its last 64 MiB in .1, nothing half-made.
    const up = await http(a.door, "/parts/ask/upkeep", { method: "POST", body: {} });
    assert.equal(up.status, 200, up.body.toString());
    await within("the log held to its bound", 15_000, () => existsSync(`${log}.1`) && statSync(log).size === 0, () => `${statSync(log).size}; ${up.body}`);
    assert.equal(statSync(log).ino, inode, "the same file the job writes to");
    assert.equal(statSync(`${log}.1`).size, 64 * MiB);
    const tail = Buffer.alloc(14);
    const fd = openSync(`${log}.1`, "r");
    readSync(fd, tail, 0, 14, 64 * MiB - 14);
    closeSync(fd);
    assert.equal(tail.toString(), "done-flooding\n", "its last bytes kept");
    assert.equal(existsSync(`${log}.1.tmp`), false);
    // (what it writes after goes on into the same log)
    assert.ok(alive(pgid, true));

    // Its memory not the log's: the station and its programs within 64 MiB of where they were.
    const after = await sample();
    const own = (m: { wholeRssMb: number; mbChildrenRssMb: number }) => m.wholeRssMb - m.mbChildrenRssMb;
    assert.ok(after.wholeRssMb - before.wholeRssMb < 64, `the station grew by ${after.wholeRssMb - before.wholeRssMb} MiB (its own process by ${own(after) - own(before)} MiB, its programs by ${after.mbChildrenRssMb - before.mbChildrenRssMb} MiB): ${JSON.stringify({ before, after })}`);
    assert.ok(after.wholeRssMb >= after.mbChildrenRssMb && after.mbChildrenRssMb > 0, JSON.stringify(after));
    // its programs counted: each alive, the station's own child
    const trimmed = await http(a.door, "/parts/ask/memory.trimIdle", { body: {} });
    assert.equal(trimmed.status, 200, trimmed.body.toString());
    const kids = spawnSync("ps", ["-axo", "pid=,ppid="], { encoding: "utf8" }).stdout.split("\n").map((l) => l.trim().split(/\s+/).map(Number)).filter(([, pp]) => pp === a.child.pid).map(([p]) => p);
    assert.ok(trimmed.json.programs.length >= 1 && trimmed.json.programs.every((p: number) => kids.includes(p) && alive(p)), `${trimmed.body} (children ${kids.join(",")})`);

    assert.equal((await tool(a.door, "t1", "job_stop", { id: job.id })).error, false);
    await within("its group ended", 10_000, () => !alive(pgid, true));
    assert.equal(store.getJob(job.id)!.state, "stopped");
  } finally {
    store.close();
  }
  await a.stop();
});

// ── another station: a directory of hundreds of small files synced to it, and it gone (sending-pack.test.ts,
// vault-elsewhere.test.ts) ──

/// The control plane of the test's, its presence socket saying both stations are of one workspace.
async function controlPlane(state: (station: string) => Record<string, unknown>) {
  const sockets: WebSocket[] = [];
  const server = httpServer((_req, res) => void res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const st = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        if (String(m) === "ping") ws.send("pong");
      });
      ws.send(JSON.stringify({ type: "state", relay_urls: [], revocations: [], ...state(st) }));
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    for (const s of sockets) s.terminate();
    wss.close();
    server.closeAllConnections();
    server.close();
  });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

/// The data's station key, as the program says it.
const stationId = (data: string) => {
  const r = spawnSync(binary!, ["id", "--data", data], { env: { PATH: "/usr/bin:/bin", HOME: data }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
};

/// The whole of a tree as bytes, modes and links (none of `skip`'s names): what a sync must give there as it is here.
function tree(root: string, skipNames: string[] = []): Record<string, string> {
  const out: Record<string, string> = {};
  const walk = (rel: string) => {
    for (const name of readdirSync(join(root, rel)).sort()) {
      if (rel === "" && skipNames.includes(name)) continue;
      const r = rel === "" ? name : join(rel, name);
      const st = lstatSync(join(root, r));
      if (st.isSymbolicLink()) out[r] = `link ${readlinkSync(join(root, r))}`;
      else if (st.isDirectory()) walk(r);
      else out[r] = `file ${(st.mode & 0o111) !== 0 ? "x" : "-"} ${sha256(readFileSync(join(root, r)))}`;
    }
  };
  walk("");
  return out;
}

/// Every file under `dir` (none if it is not there).
function filesUnder(dir: string): string[] {
  if (!existsSync(dir)) return [];
  return (readdirSync(dir, { recursive: true }) as string[]).filter((f) => !lstatSync(join(dir, f)).isDirectory());
}

/// Two stations of workspace `w1` on loopback iroh, alpha and beta, a session `s1` (token t1) on alpha; `before`
/// runs on alpha's data once its tables are made, before it serves.
async function pair(before: (dataA: string, idB: string) => void = () => {}) {
  const W = "w1";
  const [dataA, dataB] = [fresh("pa"), fresh("pb")];
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const placeOf = (st: string) => ({ workspace: W, workspace_name: "Team", name: st === idA ? "alpha" : "beta", peers, grant_keys: null });
  const origin = await controlPlane(placeOf);
  for (const [data, id] of [[dataA, idA], [dataB, idB]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin, station: id, relay_url: "", relay_urls: [], revocations: [], ...placeOf(id) }));
  }
  const env = (port: number) => ({ STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}` });
  const work = fresh("wa");
  // (alpha once, for its store's and vault's tables)
  await (await launch(dataA, env(portA), "9810")).stop();
  const store = openStore(dataA);
  try {
    store.insertSession({ key: "s1", connect: "chat", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdBy: "bob@x.com", ws: W, createdAt: Date.now(), lastActiveAt: Date.now() } as never);
    const thread = store.openThread("chat", "CHAT", "1795000000.001000", "elsewhere", "bob@x.com").id;
    store.joinThread(thread, "s1", "chat");
  } finally {
    store.close();
  }
  before(dataA, idB);
  const p = {
    W, dataA, dataB, idB, work,
    a: await launch(dataA, env(portA), "9810"),
    b: await launch(dataB, env(portB), "9810"),
    startBeta: async () => (p.b = await launch(dataB, env(portB), "9810")),
    both: () => `${p.a.err().slice(-2500)}\n---beta---\n${p.b.err().slice(-2500)}`,
    reached: () => within("alpha reaches beta", 30_000, async () => {
      const r = await tool(p.a.door, "t1", "station_list", { station: "beta" });
      return !r.error && JSON.parse(r.text).tasks === true;
    }, p.both),
    /// `dir` synced to beta for task `key` and `command` run there in its mirror: how it went.
    run: async (key: string, dir: string, command: string) => {
      const prep = await tool(p.a.door, "t1", "station_task", { station: "beta", key, action: "prepare", name: key, dir, command });
      assert.equal(prep.error, false, prep.text);
      // (a start refused is said at once, not asked again: a sync refused is refused the same way each time)
      const started = await within(`${key} synced and started`, 60_000, async () => {
        const r = await tool(p.a.door, "t1", "station_task", { station: "beta", key, action: "start" });
        if (r.error) return { refused: r.text };
        const parsed = JSON.parse(r.text);
        return parsed.syncing === true ? null : parsed;
      }, p.both);
      assert.equal(started.refused, undefined, `${key} refused: ${started.refused}`);
      assert.match(started.job.id, /^remote_/, JSON.stringify(started));
      const got = await within(`${key} ended`, 30_000, async () => {
        const g = JSON.parse((await tool(p.a.door, "t1", "station_task", { station: "beta", key, action: "get" })).text);
        return g.job?.state === "exited" || g.job?.state === "failed" ? g : null;
      }, p.both);
      assert.equal(got.job.exitCode, 0, JSON.stringify(got));
      return got;
    },
    /// The one mirror on beta, idle: where it is.
    mirror: async () => {
      const m = await within("the mirror idle", 30_000, async () => {
        const ms = JSON.parse((await tool(p.a.door, "t1", "station_task", { station: "beta", action: "mirrors" })).text).mirrors;
        return ms.length === 1 && ms[0].busy === false ? ms[0] : null;
      }, p.both);
      return m.path as string;
    },
  };
  await p.reached();
  return p;
}

test("another station: 600 small files synced there byte for byte and again after edits, nothing left where they landed; a grant's commands run there; that station killed, its tasks, its files and a grant's commands to run there refused in words at once, this station serving throughout, and taken up again once it is back", { skip, timeout: 120_000 }, async () => {
  const TOKEN = "tok-elsewhere-0123456789abcdef";
  const GRANT = "r_01HZZZZZZZZZZZZZZZZZZEL1";
  // (a plain secret of bob's and its grant asked for commands on beta, as the vault keeps them)
  const p = await pair((dataA, idB) => {
    const now = Math.floor(Date.now() / 1000);
    write(dataA, "INSERT INTO vault_plain (ws, id, owner, version, body) VALUES (?, ?, ?, ?, ?)", "w1", "ip1", "bob@x.com", 0, JSON.stringify({
      ws: "w1", id: "ip1", owner: "bob@x.com", version: 0, kind: "token", name: "Router", fields: { value: TOKEN }, notes: "the router's counters",
      listing: { name: "Router", kind: "token", modes: ["env"], hosts: [], env: "ROUTER_TOKEN" }, at: now - 10,
    }));
    const request = { id: GRANT, ws: "w1", vault: "plain", item: "ip1", session: "s1", chat: "CHAT/1795000000.001000", owner: "bob@x.com", mode: "env", reason: "read the router's counters", box: "", at: now - 10, status: "granted", runOn: { id: idB, name: "beta" } };
    const grant = { v: 1, ws: "w1", request: GRANT, vault: "plain", item: "ip1", mode: "env", hosts: [], scope: "hour", exp: now + 3600, at: now - 10 };
    write(dataA, "INSERT INTO vault_grants (ws, id, session, body) VALUES (?, ?, ?, ?)", "w1", GRANT, "s1", JSON.stringify({ request, grant, uses: 0 }));
  });
  const { a, dataA, dataB, work } = p;

  // ── a directory of 600 small files (some empty, some executable, a link), synced to beta and run there ──
  const src = fresh("src");
  const files: string[] = [];
  for (let i = 0; i < 600; i++) {
    const rel = join(`d${i % 24}`, `e${i % 5}`, `f${i}.txt`);
    mkdirSync(join(src, rel, ".."), { recursive: true });
    writeFileSync(join(src, rel), i % 50 === 0 ? "" : createHash("sha512").update(`f${i}`).digest().toString("base64").repeat(1 + (i % 7)));
    if (i % 37 === 0) chmodSync(join(src, rel), 0o755);
    files.push(rel);
  }
  symlinkSync("d1/e1/f1.txt", join(src, "link"));
  // (where packed pieces land and are made, on either side: nothing left once a sync is over but the tasks' own
  // records, a task's task.json there and the one followed here)
  const leftOver = () => [dataA, dataB].flatMap((d) => ["landing", "incoming", "outgoing"].flatMap((w) => filesUnder(join(d, "remote", w))
    .filter((f) => !(w === "incoming" && /^[0-9a-f]{64}\/task\.json$/.test(f)) && !(w === "outgoing" && /^[0-9a-f]{64}\.json$/.test(f)))
    .map((f) => `${d}/remote/${w}/${f}`)));
  const got1 = await p.run("k-pack1", src, "ls -R . > /dev/null && cat link > /dev/null && echo ran");
  assert.equal(got1.log.trim(), "ran");
  const path1 = await p.mirror();
  assert.deepEqual(tree(path1), tree(src), "the mirror is the directory, byte for byte, its modes and its link");
  await within("nothing left where the sync's pieces landed", 10_000, () => leftOver().length === 0, () => leftOver().join("\n"));

  // Edited: 100 removed, 100 rewritten (other sizes), 50 added, modes changed; synced again into the same mirror.
  for (const rel of files.slice(2, 102)) unlinkSync(join(src, rel));
  for (const rel of files.slice(102, 202)) writeFileSync(join(src, rel), `rewritten ${rel}\n`.repeat(3));
  for (let i = 0; i < 50; i++) {
    mkdirSync(join(src, "new", `n${i % 4}`), { recursive: true });
    writeFileSync(join(src, "new", `n${i % 4}`, `g${i}.bin`), createHash("sha256").update(`g${i}`).digest());
  }
  for (const rel of files.slice(202, 212)) chmodSync(join(src, rel), 0o755);
  for (const rel of files.slice(212, 222).filter((_, i) => i % 37 !== 0)) chmodSync(join(src, rel), 0o644);
  await p.run("k-pack2", src, `test -f new/n0/g0.bin && test ! -e ${files[2]} && echo ran`);
  const path2 = await p.mirror();
  assert.equal(path2, path1, "the same mirror, synced again");
  assert.deepEqual(tree(path2), tree(src), "after the edits: what was removed gone there, what changed changed, what was added there");
  await within("nothing left where the second sync's pieces landed", 10_000, () => leftOver().length === 0, () => leftOver().join("\n"));

  // ── a grant's commands to run on beta: run there, in the chat's directory on it, the value hidden ──
  const ran = await tool(a.door, "t1", "secret_run", { grant: GRANT, command: 'pwd; echo "token=$ROUTER_TOKEN"; printf %s "$ROUTER_TOKEN" > got.txt' });
  assert.equal(ran.error, false, ran.text);
  assert.match(ran.text, /^exit code 0/, ran.text);
  assert.ok(!ran.text.includes(TOKEN), ran.text);
  const room = ran.text.split("\n").find((l) => l.startsWith("/"))!;
  assert.ok(room.startsWith(dataB) || room.startsWith(`/private${dataB}`), `run in beta's room for the chat: ${ran.text}`);
  assert.equal(readFileSync(join(room, "got.txt"), "utf8"), TOKEN);

  // ── beta killed (gone without a word): the first ask of it found gone by its check at once; those after, dialing a
  // station not there, given up at the answer's bound (peer.ts ANSWER_MS, 30 s, as the TypeScript's), each in words,
  // nothing hung, the value never in them; alpha serving its own meanwhile ──
  p.b.child.kill("SIGKILL");
  await p.b.ended;
  const timed = async (what: string, call: () => Promise<{ text: string; error: boolean }>) => {
    const t0 = Date.now();
    const r = await call();
    const took = Date.now() - t0;
    assert.equal(r.error, true, `${what} answered as if beta were there: ${r.text}`);
    assert.match(r.text, /reach|offline|gone|answer|connect|timed out|not start/i, `${what}: ${r.text}`);
    return { what, took, text: r.text };
  };
  const first = await timed("a task's prepare", () => tool(a.door, "t1", "station_task", { station: "beta", key: "k-gone", action: "prepare", name: "gone", command: "true" }));
  assert.ok(first.took < 15_000, `the first ask after beta was killed came back ${first.took} ms after it was asked: ${first.text}`);
  writeFileSync(join(work, "in.txt"), "x");
  const asking = Promise.all([
    timed("a task's get", () => tool(a.door, "t1", "station_task", { station: "beta", key: "k-pack2", action: "get" })),
    timed("a file sent", () => tool(a.door, "t1", "station_file", { station: "beta", key: "k-pack2", direction: "upload", path: "in.txt", local: "in.txt" })),
    timed("a grant's command", () => tool(a.door, "t1", "secret_run", { grant: GRANT, command: "true" })),
  ]);
  // (alpha the same process, serving its own while they wait)
  const t0 = Date.now();
  const local = await tool(a.door, "t1", "job_start", { name: "here", command: "echo here" });
  assert.equal(local.error, false, local.text);
  assert.ok(Date.now() - t0 < 2_000, `alpha's own tool waited ${Date.now() - t0} ms on beta's`);
  const later = await asking;
  for (const r of later) assert.ok(r.took < 40_000, `${r.what} came back ${r.took} ms after it was asked: ${r.text}`);
  assert.equal(a.child.exitCode, null, a.err().slice(-3000));
  assert.ok(![first, ...later].some((r) => r.text.includes(TOKEN)));

  // ── beta back with its key: dialed anew, its mirror as it was, a grant's command run there again ──
  await p.startBeta();
  await p.reached();
  assert.deepEqual(tree(await p.mirror()), tree(src));
  const again = await tool(a.door, "t1", "secret_run", { grant: GRANT, command: "true" });
  assert.equal(again.error, false, again.text);
  assert.match(again.text, /^exit code 0/);
  await Promise.all([p.a.stop(), p.b.stop()]);
});

test("links changed between two syncs: one pointing elsewhere, one made a file, one removed, each so in the mirror after the next sync", { skip, timeout: 90_000 }, async () => {
  const p = await pair();
  const src = fresh("lsrc");
  writeFileSync(join(src, "a"), "A\n");
  writeFileSync(join(src, "b"), "B\n");
  symlinkSync("a", join(src, "moved"));
  symlinkSync("a", join(src, "made-file"));
  symlinkSync("a", join(src, "gone"));
  await p.run("k-l1", src, "cat moved made-file gone > /dev/null && echo ran");
  const path = await p.mirror();
  assert.deepEqual(tree(path), tree(src));
  rmSync(join(src, "moved"));
  symlinkSync("b", join(src, "moved"));
  rmSync(join(src, "made-file"));
  writeFileSync(join(src, "made-file"), "now a file\n");
  rmSync(join(src, "gone"));
  const got = await p.run("k-l2", src, "cat moved made-file && test ! -e gone && test ! -L gone && echo ran");
  assert.equal(got.log.trim(), "B\nnow a file\nran");
  assert.deepEqual(tree(await p.mirror()), tree(src), "the mirror as the directory now is");
  await Promise.all([p.a.stop(), p.b.stop()]);
});
