// Wave 3 Track H: Share-Sync (MEMORY.md, team skills, conflict files, presets), Group (IM) Connect,
// Terminals (PTY), Updates / station_version, Feedback, and Orphan Runner Sweep parity tests on real
// pure-MoonBit stations (`stillfail-reader run`) under a PATH containing no Node.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, createPublicKey, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket } from "node:dgram";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { createServer as httpServer, request as httpRequest } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { loadMesh, type Connection, type Stream as MeshStream } from "../src/mesh/native.ts";
import { frame } from "../src/mesh/screens.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";
import { KIND, TERMINAL_TYPE } from "../src/terminals/terminals.ts";
import { GrantKey } from "./fake-control-plane.ts";
import { ImServer } from "./group-im.ts";

const binary = mbReaderBinary();
const runner = process.env.STILLFAIL_RUNNER ?? "";
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skip =
  binary === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : addon === null
      ? "the mesh addon is not built here (scripts/native.ts run mesh)"
      : runner === "" || !existsSync(runner)
        ? "no stillfail-runner (run under scripts/native.ts run runner)"
        : !existsSync("/usr/bin/curl")
          ? "no /usr/bin/curl for the fake runtime"
          : process.platform === "win32"
            ? "the launcher's descriptors are Unix's"
            : false;

const dirs: string[] = [];
// Short paths so Unix sockets (runner, status.sock) stay within macOS's 104-byte limit.
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfh-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
const cleanups: (() => void | Promise<void>)[] = [];
after(async () => {
  for (const fn of cleanups.splice(0).reverse()) {
    try {
      await fn();
    } catch {
      // best effort
    }
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(
      left.map((c) =>
        c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined,
      ),
    ),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const d of dirs) {
    const runners = join(d, "run", "runners");
    if (!existsSync(runners)) continue;
    for (const name of readdirSync(runners)) {
      if (!name.endsWith(".json")) continue;
      try {
        const info = JSON.parse(readFileSync(join(runners, name), "utf8"));
        if (typeof info.pgid === "number") try { process.kill(-info.pgid, "SIGKILL"); } catch {}
        if (typeof info.runner === "number") try { process.kill(info.runner, "SIGKILL"); } catch {}
      } catch {}
    }
  }
  for (const d of dirs) rmSync(d, { recursive: true, force: true, maxRetries: 3, retryDelay: 50 });
});

const TOOLS = [
  "sh", "ps", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3",
  "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename",
  "sed", "tr", "head", "tail", "wc", "uname", "stty", "lsof",
];

function binOf(name: string): string {
  const search = [
    ...(process.env.PATH ?? "").split(":").filter((d) => d !== ""),
    "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin",
  ];
  for (const d of search) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}

function makeNoNodeBin(dir: string): string {
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node") && !existsSync(join(dir, t))) {
      symlinkSync(found, join(dir, t));
    }
  }
  assert.equal(existsSync(join(dir, "node")), false, "no node on test PATH");
  return dir;
}

const noNode = (more: Record<string, string> = {}) => ({
  PATH: makeNoNodeBin(fresh("path")),
  HOME: process.env.HOME ?? tmpdir(),
  TMPDIR: tmpdir(),
  STILLFAIL_RUNNER: runner,
  ...more,
});

function installFakeClaude(binDir: string): void {
  makeNoNodeBin(binDir);
  const claude = String.raw`#!/bin/sh
case " $* " in *" -p "*) ;; *) printf 'claude 2.0.0\n'; exit 0 ;; esac
sid=""; cfg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id|--resume) sid="$2"; shift ;;
    --mcp-config) cfg="$2"; shift ;;
  esac
  shift
done
url=$(printf '%s' "$cfg" | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')
say() { printf '%s\n' "$1"; }
n=0
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*) ;; *) continue ;; esac
  n=$((n+1))
  printf '%s\n' "$line" >> "$FAKE_OUT/in-$sid.log"
  say '{"type":"system","subtype":"init","session_id":"'"$sid"'","model":"default","tools":[],"mcp_servers":[]}'
  say '{"type":"system","subtype":"status","status":"requesting","session_id":"'"$sid"'"}'
  to=$(printf '%s' "$line" | sed -n 's/.*thread=\\"\([^\\]*\)\\".*/\1/p')
  if [ -n "$to" ]; then printf '%s' "$to" > "$FAKE_OUT/to-$sid"; else to=$(cat "$FAKE_OUT/to-$sid" 2>/dev/null); fi
  case "$line" in
    *LEAVE_NOW*)
      curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Group Room","text":"leaving group","kind":"all_done","done":"left group"}}}' > "$FAKE_OUT/post-$sid-$n.json"
      curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"chat_leave","arguments":{"to":"'"$to"'"}}}' > "$FAKE_OUT/leave-$sid-$n.json"
      ;;
    *)
      curl -s -X POST "$url" -H 'content-type: application/json' -H "authorization: Bearer $STILLFAIL_MCP_TOKEN" \
        -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"chat_post","arguments":{"to":"'"$to"'","title":"Group Room","text":"group-reply-'"$n"'","kind":"all_done","done":"replied"}}}' > "$FAKE_OUT/post-$sid-$n.json"
      ;;
  esac
  say '{"type":"assistant","message":{"id":"m'$n'","role":"assistant","content":[{"type":"text","text":"ok"}]},"session_id":"'"$sid"'"}'
  say '{"type":"result","subtype":"success","is_error":false,"duration_ms":1,"num_turns":1,"session_id":"'"$sid"'","result":"ok"}'
done
`;
  writeFileSync(join(binDir, "claude"), claude);
  chmodSync(join(binDir, "claude"), 0o755);
}

async function given<T>(
  what: string,
  f: () => T | null | undefined | false | Promise<T | null | undefined | false>,
  ms = 25_000,
  detail: () => string = () => "",
): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) {
      throw new Error(`never came (${ms}ms): ${what}${last ? ` (${(last as Error).message})` : ""}${detail() ? `; ${detail()}` : ""}`);
    }
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

function alive(pid: number, group = false): boolean {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function freeUdpPort(): Promise<number> {
  const socket = createSocket("udp4");
  await new Promise<void>((r) => socket.bind(0, "127.0.0.1", () => r()));
  const port = socket.address().port;
  await new Promise<void>((r) => socket.close(() => r()));
  return port;
}

function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

type Launched = {
  child: ChildProcess;
  said: any[];
  next: (what: string, ok: (m: any) => boolean) => Promise<any>;
  tell: (m: unknown) => void;
  ended: Promise<number | null>;
  err: () => string;
  stop: () => Promise<void>;
};

async function launch(data: string, app: string, env: Record<string, string> = {}): Promise<Launched> {
  const listener = () =>
    new Promise<Server>((resolve) => {
      const s = tcpServer();
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
  const [mcpSrv, loopSrv] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(
    binary!,
    ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"],
    {
      stdio: ["ignore", "pipe", "pipe", fd(mcpSrv), fd(loopSrv), "pipe"],
      env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
    },
  );
  children.push(child);
  mcpSrv.close();
  loopSrv.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)),
        25_000,
      );
      const look = () => {
        const found = said.find(ok);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  const tell = (m: unknown) => channel.write(`${JSON.stringify(m)}\n`);
  const stop = async () => {
    if (child.exitCode === null && child.signalCode === null) {
      tell({ op: "stop" });
      assert.equal(await ended, 0, err);
    }
  };
  return { child, said, next, tell, ended, err: () => err, stop };
}

function httpRaw(
  port: number,
  path: string,
  o: { method?: string; body?: string | Buffer; headers?: Record<string, string> } = {},
): Promise<{ status: number; headers: Record<string, unknown>; body: Buffer }> {
  return new Promise((resolve, reject) => {
    const headers: Record<string, string> = { ...(o.headers ?? {}) };
    if (o.body !== undefined && !Object.keys(headers).some((k) => k.toLowerCase() === "content-type")) {
      headers["content-type"] = "application/json";
    }
    const req = httpRequest(
      {
        host: "127.0.0.1",
        port,
        path,
        method: o.method ?? (o.body === undefined ? "GET" : "POST"),
        headers,
        agent: false,
      },
      (res) => {
        const parts: Buffer[] = [];
        res.on("data", (d: Buffer) => parts.push(d));
        res.on("end", () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(parts) }));
      },
    );
    req.on("error", reject);
    req.end(o.body);
  });
}

async function httpJson(
  port: number,
  path: string,
  o: { method?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<{ status: number; body: any }> {
  const r = await httpRaw(port, path, {
    method: o.method,
    body: o.body === undefined ? undefined : JSON.stringify(o.body),
    headers: o.headers,
  });
  return { status: r.status, body: JSON.parse(r.body.toString() || "null") };
}

async function mcp(port: number, token: string, method: string, params: unknown = {}): Promise<any> {
  const r = await httpRaw(port, "/mcp", {
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(r.status, 200, r.body.toString());
  return JSON.parse(r.body.toString());
}

async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const said = await mcp(port, token, "tools/call", { name, arguments: args });
  assert.equal(said.error, undefined, JSON.stringify(said));
  return { text: said.result.content[0].text, error: said.result.isError === true };
}

const writeLine = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

async function memberAdmit(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await writeLine(first, { credential, protocol: 2 });
  return new Reader(first).line();
}

// ── 1. Dual-Station Share-Sync: MEMORY.md, skills, *.conflict-<station>.*, and presets sync ──────────────────────────

test("dual-station share-sync: MEMORY.md and team skills level across loopback iroh mesh, concurrent non-base edits produce *.conflict-<station>.*, and presets carry across stations", { skip, timeout: 90_000 }, async () => {
  const [dataA, dataB, app] = [fresh("sha"), fresh("shb"), fresh("app")];
  writeFileSync(join(app, "BUILD"), "9520\n");
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peerA = { id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] };
  const peerB = { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] };

  // Pre-seed independent conflicting `skills/shared-tool/notes.md` on both stations before first sync (no common base).
  const homeA = join(dataA, "agent");
  const homeB = join(dataB, "agent");
  mkdirSync(join(homeA, "skills", "shared-tool"), { recursive: true });
  mkdirSync(join(homeB, "skills", "shared-tool"), { recursive: true });
  const baseSkill = "---\nname: shared-tool\ndescription: Shared tool skill\n---\n- base line\n";
  writeFileSync(join(homeA, "skills", "shared-tool", "SKILL.md"), baseSkill, { mode: 0o644 });
  writeFileSync(join(homeB, "skills", "shared-tool", "SKILL.md"), baseSkill, { mode: 0o644 });
  writeFileSync(join(homeA, "skills", "shared-tool", "notes.md"), "alpha-only note content\n", { mode: 0o644 });
  writeFileSync(join(homeB, "skills", "shared-tool", "notes.md"), "beta-only note content\n", { mode: 0o644 });
  // Ensure deterministic mtime separation (beta newer than alpha -> alpha becomes conflict file).
  const tOld = Date.now() / 1000 - 30;
  const tNew = Date.now() / 1000 - 5;
  utimesSync(join(homeA, "skills", "shared-tool", "notes.md"), tOld, tOld);
  utimesSync(join(homeB, "skills", "shared-tool", "notes.md"), tNew, tNew);

  const sockets: { station: string; socket: WebSocket }[] = [];
  const planeSrv = httpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  planeSrv.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    const st = String(req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push({ station: st, socket: ws });
      ws.on("message", (m) => { if (String(m) === "ping") ws.send("pong"); });
      ws.send(JSON.stringify({
        type: "state",
        workspace: "w-share",
        workspace_name: "ShareTeam",
        name: st === idA ? "alpha" : "beta",
        peers: [peerA, peerB],
        relay_urls: [],
        revocations: [],
      }));
    });
  });
  await new Promise<void>((r) => planeSrv.listen(0, "127.0.0.1", () => r()));
  const origin = `http://127.0.0.1:${(planeSrv.address() as AddressInfo).port}`;
  cleanups.push(() => {
    for (const s of sockets) s.socket.terminate();
    wss.close();
    planeSrv.close();
  });

  for (const [data, id, name] of [[dataA, idA, "alpha"], [dataB, idB, "beta"]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(
      join(data, "mesh", "cloud.json"),
      JSON.stringify({
        origin, station: id, workspace: "w-share", workspace_name: "ShareTeam", name,
        relay_url: "", relay_urls: [], grant_keys: null, peers: [peerA, peerB], revocations: [],
      }),
    );
  }

  const [a, b] = [
    await launch(dataA, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` }),
    await launch(dataB, app, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}` }),
  ];
  await a.next("alpha ready", (m) => m.ready === true);
  await b.next("beta ready", (m) => m.ready === true);
  const doorA = (await a.next("alpha mcp", (m) => m.serving === "mcp")).port as number;
  const doorB = (await b.next("beta mcp", (m) => m.serving === "mcp")).port as number;
  for (const d of [dataA, dataB]) {
    await given("online at control plane", () => readJson(join(d, "run", "presence.json"))?.online === true);
  }

  // 1a. Concurrent non-base file creates `*.conflict-<station>.*` and preserves both sides' contents on both stations.
  const conflictCheck = (home: string) => {
    const dir = join(home, "skills", "shared-tool");
    if (!existsSync(dir)) return null;
    const names = readdirSync(dir);
    const conflict = names.find((n) => /^notes\.conflict-.+\.md$/.test(n));
    if (!conflict) return null;
    const main = readFileSync(join(dir, "notes.md"), "utf8");
    const beside = readFileSync(join(dir, conflict), "utf8");
    const combined = `${main}\n${beside}`;
    if (!combined.includes("alpha-only note content") || !combined.includes("beta-only note content")) return null;
    return { conflict, main, beside };
  };
  const confA = await given("alpha has notes.conflict-<station>.md with both contents", () => conflictCheck(homeA), 25_000, () => `A=${a.err()} B=${b.err()}`);
  const confB = await given("beta has notes.conflict-<station>.md with both contents", () => conflictCheck(homeB), 25_000, () => `A=${a.err()} B=${b.err()}`);
  assert.equal(confA.conflict, confB.conflict, "both stations converge to the same conflict filename");
  assert.equal(confA.main, confB.main);
  assert.equal(confA.beside, confB.beside);

  // 1b. Live MEMORY.md edit on alpha syncs to beta, and subsequent edit on beta syncs back to alpha.
  writeFileSync(join(homeA, "MEMORY.md"), "# Team Memory\n- synced-from-alpha\n", { mode: 0o644 });
  await given(
    "beta receives alpha MEMORY.md edit",
    () => existsSync(join(homeB, "MEMORY.md")) && readFileSync(join(homeB, "MEMORY.md"), "utf8").includes("synced-from-alpha"),
    25_000,
    () => `A=${a.err()} B=${b.err()}`,
  );
  const memOnB = readFileSync(join(homeB, "MEMORY.md"), "utf8");
  writeFileSync(join(homeB, "MEMORY.md"), `${memOnB}- synced-from-beta\n`, { mode: 0o644 });
  await given(
    "alpha receives beta MEMORY.md edit",
    () => {
      const t = readFileSync(join(homeA, "MEMORY.md"), "utf8");
      return t.includes("synced-from-alpha") && t.includes("synced-from-beta");
    },
    25_000,
    () => `A=${a.err()} B=${b.err()}`,
  );

  // 1c. Live team skill SKILL.md edit syncs across stations; 0o600 private file beside it stays local.
  const newSkillDir = join(homeA, "skills", "deploy-guide");
  mkdirSync(newSkillDir, { recursive: true });
  const skillBody = "---\nname: deploy-guide\ndescription: Team deploy guide\n---\n- run checks before release\n";
  writeFileSync(join(newSkillDir, "SKILL.md"), skillBody, { mode: 0o644 });
  writeFileSync(join(newSkillDir, "local-secret.key"), "do-not-sync\n", { mode: 0o600 });
  chmodSync(join(newSkillDir, "local-secret.key"), 0o600);
  await given(
    "beta receives skills/deploy-guide/SKILL.md",
    () => {
      const p = join(homeB, "skills", "deploy-guide", "SKILL.md");
      return existsSync(p) && readFileSync(p, "utf8") === skillBody;
    },
    25_000,
    () => `A=${a.err()} B=${b.err()}`,
  );
  assert.equal(existsSync(join(homeB, "skills", "deploy-guide", "local-secret.key")), false, "0o600 private file must not sync");

  // 1d. Presets cross-station sync via /presets/kept (create on A -> carry to B -> update on A -> carry -> delete tombstone -> carry).
  const created = await httpJson(doorA, "/admin-api/presets", {
    method: "POST",
    body: { name: "Work Preset", dirs: [], instructions: "Be concise." },
  });
  assert.equal(created.status, 200, JSON.stringify(created));
  const presetId = created.body.id as string;
  assert.equal(created.body.rev, 1);

  const keptA1 = await httpJson(doorA, "/admin-api/presets/kept");
  assert.equal(keptA1.status, 200);
  assert.ok(keptA1.body.records.some((r: any) => r.id === presetId && r.rev === 1), JSON.stringify(keptA1.body));

  const putB1 = await httpJson(doorB, "/admin-api/presets/kept", {
    method: "PUT",
    body: { records: keptA1.body.records },
  });
  assert.equal(putB1.status, 200, JSON.stringify(putB1));
  assert.deepEqual(putB1.body.refused, []);
  const keptB1 = await httpJson(doorB, "/admin-api/presets/kept");
  assert.ok(keptB1.body.records.some((r: any) => r.id === presetId && r.name === "Work Preset" && r.rev === 1), JSON.stringify(keptB1.body));

  // Update on A (rev 2) and carry to B.
  const updatedA = await httpJson(doorA, `/admin-api/presets/${presetId}`, {
    method: "PUT",
    body: { name: "Work Preset v2", dirs: [], instructions: "Updated." },
  });
  assert.equal(updatedA.status, 200);
  assert.equal(updatedA.body.rev, 2);
  const keptA2 = await httpJson(doorA, "/admin-api/presets/kept");
  const putB2 = await httpJson(doorB, "/admin-api/presets/kept", {
    method: "PUT",
    body: { records: keptA2.body.records },
  });
  assert.equal(putB2.status, 200);
  const keptB2 = await httpJson(doorB, "/admin-api/presets/kept");
  assert.ok(keptB2.body.records.some((r: any) => r.id === presetId && r.name === "Work Preset v2" && r.rev === 2), JSON.stringify(keptB2.body));

  // Delete on A (tombstone rev 3) and carry to B.
  const delA = await httpJson(doorA, `/admin-api/presets/${presetId}`, { method: "DELETE" });
  assert.equal(delA.status, 200);
  const keptA3 = await httpJson(doorA, "/admin-api/presets/kept");
  const putB3 = await httpJson(doorB, "/admin-api/presets/kept", {
    method: "PUT",
    body: { records: keptA3.body.records },
  });
  assert.equal(putB3.status, 200);
  const keptB3 = await httpJson(doorB, "/admin-api/presets/kept");
  const tomb = keptB3.body.records.find((r: any) => r.id === presetId);
  assert.equal(tomb?.gone, true, JSON.stringify(keptB3.body));
  assert.equal(tomb?.rev, 3);

  await a.stop();
  await b.stop();
});

// ── 2. Group (IM) Connect live process loop ──────────────────────────────────────────────────────────────────────────

test("group (IM) connect live loop: connects over im/2, consumes join code, inbound message triggers turn, outbound reply lands, chat_leave stops following", { skip, timeout: 90_000 }, async () => {
  const data = fresh("grp");
  const app = fresh("app");
  const binDir = fresh("bin");
  const outDir = fresh("out");
  writeFileSync(join(app, "BUILD"), "9520\n");
  installFakeClaude(binDir);

  const imEndpoint = await addon!.bind({
    secretKey: randomBytes(32),
    alpns: [Buffer.from("im/2")],
    relayUrls: [],
    discovery: false,
    bindAddr: "127.0.0.1:0",
  });
  const server = new ImServer(imEndpoint);
  cleanups.push(() => server.close());

  const ada = server.member("Ada", true);
  const code = server.code();
  const groupKey = randomBytes(32).toString("hex");
  const loopbackIps = imEndpoint.sockets().filter((s) => s.startsWith("127.0.0.1:"));
  assert.ok(loopbackIps.length > 0, `expected loopback socket for ImServer, got ${JSON.stringify(imEndpoint.sockets())}`);

  const id = stationId(data);
  const planeSrv = httpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  planeSrv.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("message", (m) => { if (String(m) === "ping") ws.send("pong"); });
      ws.send(JSON.stringify({
        type: "state",
        workspace: "w-grp",
        workspace_name: "GroupTeam",
        name: "grp-box",
        peers: [{ id, name: "grp-box" }],
        relay_urls: [],
        revocations: [],
      }));
    });
  });
  await new Promise<void>((r) => planeSrv.listen(0, "127.0.0.1", () => r()));
  const origin = `http://127.0.0.1:${(planeSrv.address() as AddressInfo).port}`;
  cleanups.push(() => {
    wss.close();
    planeSrv.close();
  });
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin, station: id, workspace: "w-grp", workspace_name: "GroupTeam", name: "grp-box",
      relay_url: "", relay_urls: [], grant_keys: null, peers: [{ id, name: "grp-box" }], revocations: [],
    }),
  );

  const workDir = fresh("work");
  mkdirSync(join(data, "homes", "cc"), { recursive: true });
  writeFileSync(join(data, "homes", "cc", ".credentials.json"), "{}");
  writeFileSync(
    join(data, "config.json"),
    JSON.stringify({
      defaultWorkspace: workDir,
      profiles: [{ id: "cc", name: "Claude", runtime: "claude", home: "homes/cc" }],
      connects: [
        {
          id: "g1",
          kind: "group",
          enabled: true,
          bind: { runtime: "claude", profile: "cc" },
          group: {
            server: imEndpoint.id(),
            relays: ["https://relay.test"],
            key: groupKey,
            code,
            botName: "Claude",
          },
        },
      ],
    }),
  );

  const st = await launch(data, app, {
    PATH: binDir,
    FAKE_OUT: outDir,
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_GROUP_IPS: loopbackIps.join(","),
  });
  await st.next("ready", (m) => m.ready === true);
  const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
  await given("online at control plane", () => readJson(join(data, "run", "presence.json"))?.online === true);

  // 2a. Group connect connects to ImServer, overview reports connected, join code removed from config.json.
  await given(
    "group connect g1 connected in overview",
    async () => {
      const ov = await httpJson(door, "/admin-api/overview");
      const g = ov.body?.connects?.find((c: any) => c.id === "g1");
      return g?.connection?.state === "connected" ? g : null;
    },
    25_000,
    () => st.err(),
  );
  await given(
    "join code removed from config.json and memberId persisted",
    () => {
      const cfg = readJson(join(data, "config.json"));
      const g = cfg?.connects?.[0]?.group;
      return g && g.code === undefined && typeof g.memberId === "string" && g.memberId.startsWith("m_") ? g : null;
    },
    15_000,
  );
  const botMemberId = readJson(join(data, "config.json")).connects[0].group.memberId as string;
  assert.equal(server.members.get(botMemberId)?.name, "Claude");

  // 2b. Ada creates a space with the bot and mentions @Claude -> fake claude runs turn & posts outbound reply.
  const space = server.group("dev-room", ada, [botMemberId]);
  server.say(space, ada, "@Claude hello from group");
  await given(
    "outbound group reply 1 delivered to ImServer",
    () => server.messages(space).some((m) => m.author === botMemberId && m.text.includes("group-reply-1")),
    30_000,
    () => `msgs=${JSON.stringify(server.messages(space))}; stderr=${st.err()}`,
  );
  await given(
    "session turn 1 idle before sending follow-up",
    async () => (await httpJson(door, "/admin-api/overview")).body?.counts?.running === 0,
    15_000,
    () => st.err(),
  );

  // 2c. Follow-up message without @Claude in the followed space still triggers the session turn.
  server.say(space, ada, "follow-up without mention");
  await given(
    "outbound group reply 2 delivered to ImServer",
    () => server.messages(space).some((m) => m.author === botMemberId && m.text.includes("group-reply-2")),
    30_000,
    () => `msgs=${JSON.stringify(server.messages(space))}; stderr=${st.err()}`,
  );
  await given(
    "session turn 2 idle before sending LEAVE_NOW",
    async () => (await httpJson(door, "/admin-api/overview")).body?.counts?.running === 0,
    15_000,
    () => st.err(),
  );

  // 2d. Trigger `chat_leave` via LEAVE_NOW -> bot posts farewell and leaves; subsequent unmentioned message is ignored.
  server.say(space, ada, "LEAVE_NOW");
  await given(
    "bot posts leaving group message",
    () => server.messages(space).some((m) => m.author === botMemberId && m.text.includes("leaving group")),
    30_000,
    () => `msgs=${JSON.stringify(server.messages(space))}; stderr=${st.err()}`,
  );
  await given(
    "chat_leave MCP call succeeded",
    () => {
      const files = readdirSync(outDir).filter((f) => f.startsWith("leave-"));
      if (files.length === 0) return false;
      const body = readFileSync(join(outDir, files[0]!), "utf8");
      return body.includes('"result"') && !body.includes('"isError":true');
    },
    15_000,
  );
  await given(
    "session turn idle after chat_leave",
    async () => (await httpJson(door, "/admin-api/overview")).body?.counts?.running === 0,
    15_000,
    () => st.err(),
  );
  const botCountAfterLeave = server.messages(space).filter((m) => m.author === botMemberId).length;
  server.say(space, ada, "unmentioned message after leave");
  // Wait briefly and verify no new bot reply arrives and thread is no longer followed.
  await new Promise((r) => setTimeout(r, 1_500));
  assert.equal(
    server.messages(space).filter((m) => m.author === botMemberId).length,
    botCountAfterLeave,
    `unmentioned message after chat_leave must not trigger a reply; msgs=${JSON.stringify(server.messages(space))}`,
  );

  await st.stop();
});

// ── 3. Terminals live process loop (PTY create, write, read, resize, close, no residual child) ───────────────────────

test("terminals live loop: opens real PTY via mesh stream, writes command, reads output, resizes, closes via Admin API with no residual child", { skip, timeout: 90_000 }, async () => {
  const data = fresh("term");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9520\n");
  // Terminals are a beta feature: enable on test channel.
  writeFileSync(join(data, "config.json"), JSON.stringify({ updateChannel: "beta" }));

  const id = stationId(data);
  const udpPort = await freeUdpPort();
  const grant = new GrantKey();
  const planeSrv = httpServer((_req, res) => {
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  planeSrv.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on("message", (m) => { if (String(m) === "ping") ws.send("pong"); });
      ws.send(JSON.stringify({
        type: "state",
        workspace: "w-term",
        workspace_name: "TermTeam",
        name: "term-box",
        peers: [{ id, name: "term-box", ips: [`127.0.0.1:${udpPort}`] }],
        grant_keys: { keys: [grant.jwk] },
        relay_urls: [],
        revocations: [],
      }));
    });
  });
  await new Promise<void>((r) => planeSrv.listen(0, "127.0.0.1", () => r()));
  const origin = `http://127.0.0.1:${(planeSrv.address() as AddressInfo).port}`;
  cleanups.push(() => {
    wss.close();
    planeSrv.close();
  });

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin, station: id, workspace: "w-term", workspace_name: "TermTeam", name: "term-box",
      relay_url: "", relay_urls: [], grant_keys: { keys: [grant.jwk] },
      peers: [{ id, name: "term-box", ips: [`127.0.0.1:${udpPort}`] }], revocations: [],
    }),
  );

  const st = await launch(data, app, {
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_NO_DISCOVERY: "1",
    STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${udpPort}`,
    SHELL: "/bin/sh",
  });
  await st.next("ready", (m) => m.ready === true);
  const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
  await given("online at control plane", () => readJson(join(data, "run", "presence.json"))?.online === true);

  // Verify `terminal` feature is enabled in overview.
  const ov = await httpJson(door, "/admin-api/overview");
  assert.ok(Array.isArray(ov.body.features) && ov.body.features.includes("terminal"), `expected terminal feature in ${JSON.stringify(ov.body.features)}`);

  // Connect as a real mesh member and open a terminal view stream.
  const clientEp = await addon!.bind({ secretKey: randomBytes(32), alpns: [], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  cleanups.push(() => clientEp.close());
  const conn = await clientEp.connect({ id, relays: [], ips: [`127.0.0.1:${udpPort}`] }, Buffer.from("stillfail/admin/1"));
  cleanups.push(() => conn.close(0, "done"));
  const nowSec = Math.floor(Date.now() / 1000);
  const admitted = await memberAdmit(
    conn,
    grant.credential(
      { typ: "stillfail-member+jwt" },
      { iss: "stillfail-cloud", sub: "u1", email: "owner@x.test", name: "Owner", role: "owner", ws: "w-term", device: clientEp.id(), sid: "sid-u1", iat: nowSec - 10, exp: nowSec + 3600 },
    ),
  );
  assert.equal(admitted?.ok, true, JSON.stringify(admitted));

  const stream = await conn.openBi();
  await writeLine(stream, {
    method: "POST",
    path: "/admin/api/terminals/new/view",
    terminal: { cols: 80, rows: 24 },
  });

  // Read response head and framed screen/state/out events in background loop.
  let rawBuf = Buffer.alloc(0);
  let head: any = null;
  const states: any[] = [];
  let termOutput = "";
  let streamEnded = false;
  const readerLoop = (async () => {
    for (;;) {
      const chunk = await stream.read();
      if (chunk === null) {
        streamEnded = true;
        break;
      }
      rawBuf = Buffer.concat([rawBuf, chunk]);
      if (head === null) {
        const nl = rawBuf.indexOf(10);
        if (nl === -1) continue;
        head = JSON.parse(rawBuf.subarray(0, nl).toString("utf8"));
        rawBuf = rawBuf.subarray(nl + 1);
      }
      while (rawBuf.length >= 5) {
        const len = rawBuf.readUInt32BE(1);
        if (rawBuf.length < 5 + len) break;
        const kind = rawBuf[0]!;
        const payload = rawBuf.subarray(5, 5 + len);
        rawBuf = rawBuf.subarray(5 + len);
        if (kind === KIND.state) {
          try { states.push(JSON.parse(payload.toString("utf8"))); } catch {}
        } else if (kind === KIND.screen || kind === KIND.out) {
          termOutput += payload.toString("utf8");
        }
      }
    }
  })();

  await given("terminal stream response head 200", () => head !== null, 15_000, () => st.err());
  assert.equal(head.status, 200, JSON.stringify(head));
  assert.equal(head.headers["content-type"], TERMINAL_TYPE);
  await given("initial terminal state with types=true and 80x24", () => states.some((s) => s.types === true && s.cols === 80 && s.rows === 24), 15_000, () => JSON.stringify(states));

  // Verify terminal is listed via Admin API and grab its runner/child PIDs.
  const listed = await httpJson(door, "/admin-api/terminals");
  assert.equal(listed.status, 200, JSON.stringify(listed));
  assert.equal(listed.body.terminals.length, 1, JSON.stringify(listed.body));
  const termId = listed.body.terminals[0].id as string;
  assert.ok(termId.startsWith("term-"), termId);
  const runnerInfo = readJson(join(data, "run", "runners", `${termId}.json`));
  assert.ok(runnerInfo && typeof runnerInfo.runner === "number" && typeof runnerInfo.pid === "number", JSON.stringify(runnerInfo));
  assert.equal(alive(runnerInfo.runner), true);
  assert.equal(alive(runnerInfo.pid), true);

  // Write command to PTY and verify output + initial size.
  await stream.write(frame(KIND.input, Buffer.from("echo TERM_PARITY_OK_12345; stty size\r")));
  await given(
    "PTY echoes command output and 24 80 size",
    () => termOutput.includes("TERM_PARITY_OK_12345") && termOutput.includes("24 80"),
    15_000,
    () => `out=${JSON.stringify(termOutput)}`,
  );

  // Resize PTY to 100x32 and verify both state update and `stty size` reflect 32 100.
  await stream.write(frame(KIND.resize, Buffer.from(JSON.stringify({ cols: 100, rows: 32 }))));
  await given(
    "terminal state resized to 100x32",
    () => states.some((s) => s.cols === 100 && s.rows === 32),
    10_000,
    () => JSON.stringify(states),
  );
  await stream.write(frame(KIND.input, Buffer.from("echo RESIZED_CHECK; stty size\r")));
  await given(
    "PTY reports 32 100 after resize",
    () => termOutput.includes("RESIZED_CHECK") && termOutput.includes("32 100"),
    15_000,
    () => `out=${JSON.stringify(termOutput)}`,
  );

  // Close terminal via Admin API: runner + PTY child exit cleanly, view receives ended state, and list empties once view closes.
  const endedRes = await httpJson(door, `/admin-api/terminals/${termId}/end`, { method: "POST", body: {} });
  assert.equal(endedRes.status, 200, JSON.stringify(endedRes));
  await given(
    "terminal runner and PTY child processes exited with no residue",
    () => !alive(runnerInfo.pid) && !alive(runnerInfo.runner),
    15_000,
  );
  await given(
    "open view receives ended state",
    () => states.some((s) => Object.prototype.hasOwnProperty.call(s, "ended")),
    10_000,
    () => JSON.stringify(states),
  );
  await stream.finish();
  await given("terminal stream ended", () => streamEnded, 10_000);
  await readerLoop;
  await given(
    "terminal removed from Admin API list once view closed",
    async () => (await httpJson(door, "/admin-api/terminals")).body.terminals.length === 0,
    10_000,
  );

  await st.stop();
});

// ── 4. Updates / station_version / Feedback / Orphan Runner Sweep ────────────────────────────────────────────────────

test("updates, station_version MCP, feedback submit/reply/fixed flow, and startup orphan runner sweep", { skip, timeout: 90_000 }, async () => {
  const data = fresh("ops");
  const app = join(data, "app");
  mkdirSync(app, { recursive: true });
  writeFileSync(join(app, "BUILD"), "9400\n");
  writeFileSync(join(data, "config.json"), JSON.stringify({ updateChannel: "stable" }));

  const id = stationId(data);

  // 4a. Pre-spawn a real orphan `stillfail-runner` process not belonging to any session in stillfail.db.
  const orphanId = "claude-orphan-999";
  const runnersDir = join(data, "run", "runners");
  mkdirSync(runnersDir, { recursive: true });
  const orphanProc = spawn(
    runner,
    [
      "--id", orphanId,
      "--dir", runnersDir,
      "--cwd", data,
      "--",
      binOf("sleep"), "300",
    ],
    { stdio: "ignore", detached: true },
  );
  orphanProc.unref();
  const orphanInfo = await given(
    "orphan runner info file written",
    () => {
      const info = readJson(join(runnersDir, `${orphanId}.json`));
      return info && typeof info.runner === "number" && typeof info.pid === "number" ? info : null;
    },
    10_000,
  );
  assert.equal(alive(orphanInfo.runner), true, "orphan runner alive before station start");
  assert.equal(alive(orphanInfo.pid), true, "orphan child alive before station start");
  cleanups.push(() => {
    try { process.kill(-orphanInfo.pgid, "SIGKILL"); } catch {}
    try { process.kill(orphanInfo.runner, "SIGKILL"); } catch {}
  });

  // Pre-seed a session and a thread with a failure notice entry for feedback tests.
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), {
    currentTimeMillisUnsafe: () => Date.now(),
  } as never);
  const workDir = fresh("fbws");
  store.insertSession({
    key: "s-fb",
    connect: "chat",
    runtime: "claude",
    profile: "cc",
    workspace: workDir,
    token: "t-fb",
    createdBy: "alice@x.test",
    ws: "w-ops",
    createdAt: Date.now(),
    lastActiveAt: Date.now(),
  });
  const thread = store.openThread("chat", "CHAT", "1795000000.000100", null, "alice@x.test");
  store.joinThread(thread.id, "s-fb", "chat");
  const [noticeN] = store.insertMessage({
    thread: thread.id,
    ts: "1795000000.000200",
    authorKind: "station",
    author: "station",
    text: "⚠️ runtime failed unexpectedly",
  });
  store.close();

  // Signed release feed + feedback endpoints + presence WS stand-in.
  const { privateKey } = generateKeyPairSync("ed25519");
  const rawPub = Buffer.from(createPublicKey(privateKey).export({ format: "jwk" }).x as string, "base64url").toString("base64");
  const keyId = createHash("sha256").update(Buffer.from(rawPub, "base64")).digest("hex").slice(0, 16);
  const feedOf = (build: number) => {
    const words = Buffer.from(JSON.stringify({
      kind: "stillfail-station-release",
      version: `0.1.${build}`,
      build,
      commit: "0".repeat(40),
      node: "24.21.0",
      builds: {
        "darwin-arm64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) },
        "linux-x64": { sha256: "a".repeat(64), size: 1000, nodeSha256: "b".repeat(64) },
      },
    }));
    return {
      version: `0.1.${build}`,
      build,
      commit: "0".repeat(40),
      release: words.toString("base64"),
      signature: nodeSign(null, words, privateKey).toString("base64"),
      key: keyId,
    };
  };

  const feedAsked: string[] = [];
  const feedbackPosts: { path: string; body: any }[] = [];
  const fixedCalls: string[][] = [];
  const wsClients: WebSocket[] = [];
  const planeSrv = httpServer(async (req, res) => {
    const url = req.url ?? "";
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const raw = Buffer.concat(chunks).toString("utf8");
    let jsonBody: any = null;
    try { jsonBody = raw ? JSON.parse(raw) : null; } catch {}

    if (url === "/releases/station.json") {
      feedAsked.push(url);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feedOf(9500)));
      return;
    }
    if (url === "/releases/station-beta.json") {
      feedAsked.push(url);
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(feedOf(9600)));
      return;
    }
    if (url === "/v1/feedback") {
      feedbackPosts.push({ path: url, body: jsonBody });
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ number: 77 }));
      return;
    }
    if (url === "/v1/feedback/reply") {
      feedbackPosts.push({ path: url, body: jsonBody });
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ok: true }));
      return;
    }
    if (url === "/v1/feedback/fixed") {
      const told: string[] = Array.isArray(jsonBody?.told) ? jsonBody.told : [];
      fixedCalls.push(told);
      const body =
        told.length === 0
          ? {
              fixed: [
                {
                  id: "fix-77",
                  number: 77,
                  title: "Live parity bug",
                  version: 9500,
                  parts: ["station"],
                  session: "s-fb",
                  thread: "CHAT/1795000000.000100",
                },
              ],
            }
          : { fixed: [] };
      res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(body));
      return;
    }
    res.writeHead(200, { "content-type": "application/json" }).end("{}");
  });
  const wss = new WebSocketServer({ noServer: true });
  planeSrv.on("upgrade", (req, socket, head) => {
    if (!req.url?.startsWith("/v1/stations/connect")) return void socket.destroy();
    wss.handleUpgrade(req, socket, head, (ws) => {
      wsClients.push(ws);
      ws.on("message", (m) => { if (String(m) === "ping") ws.send("pong"); });
      ws.send(JSON.stringify({
        type: "state",
        workspace: "w-ops",
        workspace_name: "OpsTeam",
        name: "ops-box",
        peers: [{ id, name: "ops-box" }],
        relay_urls: [],
        revocations: [],
      }));
    });
  });
  await new Promise<void>((r) => planeSrv.listen(0, "127.0.0.1", () => r()));
  const origin = `http://127.0.0.1:${(planeSrv.address() as AddressInfo).port}`;
  cleanups.push(() => {
    for (const ws of wsClients) ws.terminate();
    wss.close();
    planeSrv.close();
  });

  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(
    join(data, "mesh", "cloud.json"),
    JSON.stringify({
      origin, station: id, workspace: "w-ops", workspace_name: "OpsTeam", name: "ops-box",
      relay_url: "", relay_urls: [], grant_keys: null, peers: [{ id, name: "ops-box" }], revocations: [],
    }),
  );

  const st = await launch(data, app, {
    STILLFAIL_LOCAL_ADMIN: "1",
    STILLFAIL_RELEASE_KEYS: rawPub,
  });
  await st.next("ready", (m) => m.ready === true);
  const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
  await given("online at control plane", () => readJson(join(data, "run", "presence.json"))?.online === true);

  // 4b. Verify startup orphan runner sweep terminated the unowned `claude-orphan-999` runner & child.
  await given(
    "startup endOrphan/takeUp killed orphan runner and its child",
    () => !alive(orphanInfo.pid) && !alive(orphanInfo.runner),
    20_000,
    () => st.err(),
  );

  // 4c. Feedback (on stable channel, before switching channel to beta):
  // overview.feedback === true, MCP feedback_send & feedback_reply, Admin API POST /threads/:id/report (even without stillfail.log), and fixed notification flow.
  await given(
    "overview.feedback becomes true after startup take_handover",
    async () => (await httpJson(door, "/admin-api/overview")).body?.feedback === true,
    20_000,
    () => st.err(),
  );

  const sent = await tool(door, "t-fb", "feedback_send", {
    title: "Live parity bug",
    body: "Reproduced in Wave 3 Track H",
    area: "station",
  });
  assert.equal(sent.error, false, sent.text);
  assert.ok(sent.text.includes("FB-77"), sent.text);
  assert.ok(feedbackPosts.some((p) => p.path === "/v1/feedback" && p.body?.title === "Live parity bug"));

  const replied = await tool(door, "t-fb", "feedback_reply", {
    number: 77,
    text: "Additional diagnostics from live test",
  });
  assert.equal(replied.error, false, replied.text);
  assert.ok(feedbackPosts.some((p) => p.path === "/v1/feedback/reply" && p.body?.number === 77));

  const reported = await httpJson(door, `/admin-api/threads/${thread.id}/report`, {
    method: "POST",
    body: { n: noticeN },
  });
  assert.equal(reported.status, 200, JSON.stringify(reported));
  assert.equal(reported.body.number, 77);

  // Push a `release` event on the presence WS -> station fetches `/v1/feedback/fixed`, notifies s-fb, and acks `told: ["fix-77"]`.
  assert.ok(wsClients.length > 0, "station connected to presence WS");
  wsClients[wsClients.length - 1]!.send(JSON.stringify({ type: "release" }));
  await given(
    "fixed bug reports fetched and acknowledged with told=['fix-77']",
    () => fixedCalls.some((t) => t.includes("fix-77")),
    20_000,
    () => `fixedCalls=${JSON.stringify(fixedCalls)}; stderr=${st.err()}`,
  );

  // 4d. Updates & `station_version` MCP tool: initial stable feed, channel switch to beta and back, auto toggle, check.
  await given("stable release feed read", () => feedAsked.includes("/releases/station.json"), 20_000, () => st.err());
  const svStable = await tool(door, "t-fb", "station_version", { action: "list" });
  assert.equal(svStable.error, false, svStable.text);
  const svStableJson = JSON.parse(svStable.text);
  assert.equal(svStableJson.version, "0.1.9400", svStable.text);
  assert.equal(svStableJson.latest, "0.1.9500", svStable.text);
  assert.equal(svStableJson.newer, true);
  assert.equal(svStableJson.channel, "stable");

  // Switch channel to beta via Admin API POST /updates/channel.
  const chBeta = await httpJson(door, "/admin-api/updates/channel", { method: "POST", body: { channel: "beta" } });
  assert.equal(chBeta.status, 200, JSON.stringify(chBeta));
  await given("beta release feed read", () => feedAsked.includes("/releases/station-beta.json"), 20_000, () => st.err());
  const svBeta = await tool(door, "t-fb", "station_version", { action: "list" });
  const svBetaJson = JSON.parse(svBeta.text);
  assert.equal(svBetaJson.channel, "beta", svBeta.text);
  assert.equal(svBetaJson.latest, "0.1.9600", svBeta.text);

  // Toggle auto-update off and on via POST /updates/auto, and trigger POST /updates/check.
  const autoOff = await httpJson(door, "/admin-api/updates/auto", { method: "POST", body: { on: false } });
  assert.equal(autoOff.status, 200);
  const svAutoOff = JSON.parse((await tool(door, "t-fb", "station_version", { action: "list" })).text);
  assert.equal(svAutoOff.auto, false);
  const autoOn = await httpJson(door, "/admin-api/updates/auto", { method: "POST", body: { on: true } });
  assert.equal(autoOn.status, 200);
  const chk = await httpJson(door, "/admin-api/updates/check", { method: "POST", body: {} });
  assert.equal(chk.status, 200);

  // Switch channel back to stable.
  const chStable = await httpJson(door, "/admin-api/updates/channel", { method: "POST", body: { channel: "stable" } });
  assert.equal(chStable.status, 200);

  await st.stop();
});
