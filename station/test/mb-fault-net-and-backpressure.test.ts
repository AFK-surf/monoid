// The network's faults and a child's stalled stdin as the MoonBit program runs the station (station/mb
// src/station_main), held through `stillfail-reader run` itself with the launcher's descriptors, never the TypeScript
// station, every program run with a PATH that names no Node:
// - a config.json whose `cloudEntry` is not right refused in presence.json's words, no socket dialed past it
//   (cloud-transport.test.ts's "public presence reports an invalid entry and connects after its config is corrected";
//   its recovery, which here would dial still.fail cloud itself, is cloud_net presence_wbtest.mbt's);
// - two stations on loopback iroh keeping one workspace's ways (mesh/ways.ts): a relay of its own added and still.fail's
//   turned off by a member's device, kept in mesh/ways.json and brought level on the other station over the peers'
//   `ways.get`/`ways.put`, the last relay never turned off, the two stations still reaching each other with still.fail's
//   relays off (ways-relays.test.ts, keep-relays.test.ts);
// - a child that stops reading its stdin (a device tool's process, written to by `process.write`): the station's loop
//   never waits on its pipe, and past STDIN_MOST (64 MiB, sys.c) the child is killed and the station serves on (#7777).
// The storms of empty packets (storms.test.ts) are held where they are made: mb/src/mesh_door/gate/storms_wbtest.mbt.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, request } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { loadMesh, type Connection } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { GrantKey } from "./fake-control-plane.ts";

const binary = mbReaderBinary();
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors and signals are Unix's"
  : false;
const skipMesh = skip !== false ? skip : addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false;

const dirs: string[] = [];
// (short: the status's Unix socket is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfn-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void)[] = [];
const pids: number[] = [];
after(async () => {
  for (const c of closers.splice(0)) {
    try { c(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => new Promise<void>((r) => c.once("exit", () => r())))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
  for (const p of pids) {
    try { process.kill(-p, "SIGKILL"); } catch {}
    try { process.kill(p, "SIGKILL"); } catch {}
  }
  for (const d of dirs) {
    try {
      const pid = Number(JSON.parse(readFileSync(join(d, "run", "station.json"), "utf8")).pid);
      if (pid > 0 && pid !== process.pid) process.kill(pid, "SIGKILL");
    } catch {}
  }
  if (process.env.STATION_KEEP !== "1") for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

/// What comes true within `ms` (a real process's end, a file the station writes, a socket's message: nothing here is
/// told of them).
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

const readJson = (p: string) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

/// The commands the station runs, each linked into a directory of its own: its PATH, so no Node is.
const TOOLS = ["sh", "ps", "cat", "sleep", "echo", "printf", "env", "kill", "sed", "tr", "head", "rm", "mkdir", "ls", "uname", "lsof", "id"];
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

const freeUdpPort = async () => {
  const s = createSocket("udp4");
  await new Promise<void>((r) => s.bind(0, "127.0.0.1", () => r()));
  const port = s.address().port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
};

/// The data's station key, as the program says it.
const stationId = (data: string) => {
  const r = spawnSync(binary!, ["id", "--data", data], { env: { PATH: "/usr/bin:/bin", HOME: data }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
};

type Launched = { child: ChildProcess; door: number; ended: Promise<number | null>; err: () => string; stop: () => Promise<void> };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe, ready
/// and serving its agents' door.
async function launch(data: string, env: Record<string, string> = {}): Promise<Launched> {
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9820\n");
  const listener = () => new Promise<Server>((resolve) => {
    const s = tcpServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { PATH: toolsPath(), HOME: fresh("home"), SHELL: "/bin/sh", TMPDIR: tmpdir(), STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1", ...env },
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
  child.stdout!.on("data", (d) => (err += d));
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

/// One GET of the station's status socket (api/status.ts): its status, its JSON and how long it took.
function statusAsk(data: string): Promise<{ status: number; json: any; ms: number }> {
  const start = performance.now();
  return new Promise((resolve, reject) => {
    const req = request({ socketPath: join(data, "run", "status.sock"), path: "/v1/status", method: "GET", agent: false }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => {
        let json: any = null;
        try { json = JSON.parse(text); } catch {}
        resolve({ status: res.statusCode!, json, ms: performance.now() - start });
      });
      res.on("error", reject);
    });
    req.on("error", reject);
    req.end();
  });
}

/// A control plane of the test's for `provider`: its presence socket, each socket's state frame `state(station)`, and
/// what the stations said on it (`heard`: tool results); `upgrades` every Upgrade asked, by path.
async function controlPlane(provider: "stillfail" | "comma", state: (station: string) => Record<string, unknown>) {
  const sockets: WebSocket[] = [];
  const upgrades: string[] = [];
  const heard: any[] = [];
  const told: (() => void)[] = [];
  const connect = provider === "comma" ? "/v1/comma/stations/connect" : "/v1/stations/connect";
  const server = httpServer((req, res) => {
    req.resume();
    req.on("end", () => void res.writeHead(200, { "content-type": "application/json" }).end("{}"));
  });
  const wss = new WebSocketServer({ noServer: true });
  server.on("upgrade", (req, socket, head) => {
    upgrades.push(req.url ?? "");
    if (!req.url?.startsWith(connect)) return void socket.destroy();
    const st = String(req.headers[`x-${provider}-station`] ?? req.headers["x-stillfail-station"] ?? "");
    wss.handleUpgrade(req, socket, head, (ws) => {
      sockets.push(ws);
      ws.on("message", (m) => {
        const text = String(m);
        if (text === "ping") return void ws.send("pong");
        try { heard.push(JSON.parse(text)); } catch {}
        for (const t of told.splice(0)) t();
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
  let next = 0;
  /// A device tool asked on the newest socket (`{type: "tool", id, request}`), and what the station answered.
  const tool = (op: string, args: Record<string, unknown>, workspace: string, ms = 30_000): Promise<any> => {
    const id = `t${++next}`;
    const ws = sockets.at(-1);
    assert.ok(ws !== undefined, "no presence socket");
    ws.send(JSON.stringify({ type: "tool", id, request: { op, args, context: { workspace } } }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`no tool_result for ${op} (${id}) within ${ms} ms`)), ms);
      const look = () => {
        const r = heard.find((h) => h?.type === "tool_result" && h.id === id);
        if (r !== undefined) {
          clearTimeout(timer);
          resolve(r.response);
        } else told.push(look);
      };
      look();
    });
  };
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, sockets, upgrades, heard, tool };
}

// ── 1. cloudEntry ──

const CLOUD_ORIGIN = "https://app.still.fail";

test("config.json's cloudEntry not right: presence.json says so and no socket is dialed past it", { skip, timeout: 60_000 }, async () => {
  // (corrected, presence goes on from it to online without a restart: cloud_net presence_wbtest.mbt, on a dial of its
  // own; here, at still.fail's own origin, it would dial still.fail cloud itself)
  const data = fresh("ce");
  const id = stationId(data);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: CLOUD_ORIGIN, station: id, workspace: "w1", workspace_name: "Team", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [],
  }));
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en", cloudEntry: { origin: CLOUD_ORIGIN, host: "127.0.0.1", port: 0 } }));
  const meshPort = await freeUdpPort();
  const s = await launch(data, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
  const presence = () => readJson(join(data, "run", "presence.json"));
  // (the station's log is its stderr, as the launcher keeps it)
  const log = () => s.err();
  const detail = () => `presence ${JSON.stringify(presence())}; log ${log().split("\n").filter((l) => /cloud|presence/i.test(l)).slice(-12).join("\n")}`;
  try {
    const refused = await within("presence.json written offline", 20_000, () => {
      const p = presence();
      return p !== null && p.online === false && typeof p.error === "string" ? p : null;
    }, detail);
    assert.equal(refused.online, false);
    assert.match(refused.error, /cloudEntry.*TCP port.*correct config\.json/, `invalid configuration must be said in presence.json: ${detail()}`);
    // no socket dialed in its place
    assert.doesNotMatch(log(), /cloudEntry not taken/, `invalid configuration must not silently use a direct socket: ${detail()}`);
    assert.doesNotMatch(log(), /no presence socket to still\.fail cloud: (websocket|error sending)/, `invalid configuration must not silently use a direct socket: ${detail()}`);
    assert.equal(s.child.exitCode, null);
  } finally {
    await s.stop();
  }
});

// ── 2. ways and relays, two stations ──

const ADMIN = Buffer.from("stillfail/admin/1");
const OWN = "https://127.0.0.1:9";
const OTHER = "https://127.0.0.1:7";

/// A device's hello on a connection's first stream: what the station answers it.
async function hello(conn: Connection, credential: string) {
  const first = await conn.openBi();
  await first.write(Buffer.from(JSON.stringify({ credential, protocol: 2 }) + "\n"));
  return new Reader(first).line();
}

/// A member's request on the mesh, its status and JSON.
async function memberAsk(conn: Connection, method: string, path: string, body?: unknown): Promise<[number, any]> {
  const stream = await conn.openBi();
  await stream.write(Buffer.from(JSON.stringify({ method, path, headers: { "content-type": "application/json" } }) + "\n"));
  if (body !== undefined) await stream.write(Buffer.from(JSON.stringify(body)));
  await stream.finish();
  const reader = new Reader(stream);
  const head = await reader.line();
  const rest = (await reader.rest()).toString();
  let json: any = rest;
  try { json = JSON.parse(rest || "null"); } catch {}
  return [head.status, json];
}

test("two stations keep one workspace's ways: a relay of its own and still.fail's turned off, kept in ways.json and brought level on the other; the last relay never off; the stations reach each other throughout", { skip: skipMesh, timeout: 90_000 }, async () => {
  const [dataA, dataB] = [fresh("wa"), fresh("wb")];
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const grant = new GrantKey();
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const placeOf = (st: string) => ({ workspace: "w1", workspace_name: "Team", name: st === idA ? "alpha" : "beta", peers, grant_keys: { keys: [grant.jwk] } });
  const plane = await controlPlane("stillfail", placeOf);
  for (const [data, id] of [[dataA, idA], [dataB, idB]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: plane.origin, station: id, relay_url: "", relay_urls: [], revocations: [], ...placeOf(id) }));
    writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en" }));
  }
  const [a, b] = await Promise.all([
    launch(dataA, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` }),
    launch(dataB, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portB}` }),
  ]);
  const detail = () => `A ${a.err().slice(-2000)}\nB ${b.err().slice(-2000)}`;
  const client = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => void client.close());
  const credential = () => {
    const now = Math.floor(Date.now() / 1000);
    return grant.credential({ typ: "stillfail-member+jwt" }, { iss: "stillfail-cloud", sub: "u1", email: "ada@x.com", name: "Ada", ws: "w1", role: "owner", device: client.id(), sid: "s1", iat: now, exp: now + 3600 });
  };
  const member = async (id: string, port: number) => {
    const conn = await within(`connected to ${id.slice(0, 8)}`, 30_000, () => client.connect({ id, ips: [`127.0.0.1:${port}`] }, ADMIN), detail);
    const welcome = await hello(conn, credential());
    assert.equal(welcome.ok, true, JSON.stringify(welcome));
    return conn;
  };
  try {
    const [toA, toB] = await Promise.all([member(idA, portA), member(idB, portB)]);
    const kept = (data: string) => readJson(join(data, "mesh", "ways.json"));
    /// ways.json as it is on the disk (what a failed wait shows: a file that is not one record whole).
    const raw = (data: string) => {
      try { return readFileSync(join(data, "mesh", "ways.json"), "utf8"); } catch (e) { return String(e); }
    };
    const keptOf = (data: string) => {
      const k = kept(data);
      return k?.w1 ?? k?.workspaces?.w1 ?? null;
    };
    const levelOn = (conn: Connection, at: number, station: string) => within("brought level", 20_000, async () => {
      const [status, view] = await memberAsk(conn, "GET", "/admin/api/ways");
      return status === 200 && view.at === at && view.station === station ? view : null;
    }, detail);

    // as the cloud said them: none of its own, none off
    const [s0, v0] = await memberAsk(toA, "GET", "/admin/api/ways");
    assert.equal(s0, 200, JSON.stringify(v0));
    assert.deepEqual([v0.relays, v0.off], [[], []]);

    // a relay of its own, added on A by a member's device: A's answer, its file, and B brought level
    const [s1, r1] = await memberAsk(toA, "POST", "/admin/api/ways", { relays: [OWN] });
    assert.equal(s1, 200, JSON.stringify(r1));
    assert.deepEqual(r1.relays, [{ url: OWN, by: "Ada" }]);
    assert.equal(r1.station, idA);
    assert.ok(r1.at > 0);
    await within("A's ways.json", 10_000, () => keptOf(dataA)?.at === r1.at, () => raw(dataA));
    const onB1 = await levelOn(toB, r1.at, idA);
    assert.deepEqual(onB1.relays, r1.relays);
    await within("B's ways.json", 10_000, () => keptOf(dataB)?.at === r1.at, () => raw(dataB));

    // still.fail's relays turned off: kept by both
    const [s2, r2] = await memberAsk(toA, "POST", "/admin/api/ways", { way: "ours", on: false });
    assert.equal(s2, 200, JSON.stringify(r2));
    assert.deepEqual(r2.off, ["ours"]);
    assert.ok(r2.at >= r1.at);
    const onB2 = await levelOn(toB, r2.at, idA);
    assert.deepEqual(onB2.off, ["ours"]);
    assert.deepEqual(onB2.relays, r1.relays);

    // the last relay on never turned off: refused on either station, nothing changed on either
    const [s3, r3] = await memberAsk(toA, "POST", "/admin/api/ways", { way: OWN, on: false });
    assert.equal(s3, 409, JSON.stringify(r3));
    assert.match(r3.error, /the last relay stays on/);
    const [s3b, r3b] = await memberAsk(toB, "POST", "/admin/api/ways", { way: OWN, on: false });
    assert.equal(s3b, 409, JSON.stringify(r3b));
    for (const conn of [toA, toB]) {
      const [, v] = await memberAsk(conn, "GET", "/admin/api/ways");
      assert.deepEqual([v.relays, v.off, v.at, v.station], [r2.relays, r2.off, r2.at, r2.station]);
    }
    for (const data of [dataA, dataB]) {
      await within("ways.json as the last taken", 10_000, () => keptOf(data)?.at === r2.at && keptOf(data)?.off?.[0] === "ours", () => raw(data));
    }
    // a way that is none refused
    const [s4, r4] = await memberAsk(toA, "POST", "/admin/api/ways", { way: "https://nowhere.example", on: false });
    assert.equal(s4, 400, JSON.stringify(r4));

    // with still.fail's relays off the stations still reach each other (loopback, no relay): a change on B, the newer,
    // brought level on A
    const [s5, r5] = await memberAsk(toB, "POST", "/admin/api/ways", { relays: [OWN, OTHER] });
    assert.equal(s5, 200, JSON.stringify(r5));
    assert.equal(r5.station, idB);
    assert.deepEqual(r5.off, ["ours"], "still.fail's stay off");
    assert.deepEqual(r5.relays.map((r: any) => r.url), [OWN, OTHER]);
    const onA5 = await levelOn(toA, r5.at, idB);
    assert.deepEqual(onA5.relays, r5.relays);
    await within("A's ways.json from B", 10_000, () => keptOf(dataA)?.station === idB && keptOf(dataA)?.at === r5.at, () => raw(dataA));

    // A restarted with B gone keeps what it was brought to: from its own ways.json, no peer to bring it level
    await b.stop();
    await a.stop();
    const a2 = await launch(dataA, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${portA}` });
    const toA2 = await member(idA, portA);
    const [s6, v6] = await memberAsk(toA2, "GET", "/admin/api/ways");
    assert.equal(s6, 200);
    assert.deepEqual([v6.relays, v6.off, v6.at, v6.station], [r5.relays, r5.off, r5.at, r5.station]);
    await a2.stop();
  } finally {
    await Promise.all([a.stop(), b.stop()]);
  }
});

// ── 3. a child that stops reading its stdin ──

const MiB = 1024 * 1024;
const STDIN_MOST = 64 * MiB;

test("a device tool's process that stops reading its stdin: the station's loop never waits on it, past STDIN_MOST it is killed and the station serves on", { skip, timeout: 90_000 }, async () => {
  const data = fresh("sb");
  const id = stationId(data);
  const plane = await controlPlane("comma", () => ({ workspace: "w1", workspace_name: "Team", name: "here", peers: [], grant_keys: null }));
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: plane.origin, provider: "comma", station: id, workspace: "w1", workspace_name: "Team", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [],
  }));
  writeFileSync(join(data, "config.json"), JSON.stringify({ language: "en", tools: { access: "full" } }));
  const meshPort = await freeUdpPort();
  const s = await launch(data, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${meshPort}` });
  const detail = () => `upgrades ${JSON.stringify(plane.upgrades)}; stderr ${s.err().slice(-3000)}`;
  try {
    await within("the device tools on the presence socket", 30_000, async () => {
      if (plane.sockets.length === 0) return null;
      const r = await plane.tool("process.list", {}, "w1", 5_000);
      return r?.ok === true ? r : null;
    }, detail);
    const work = fresh("work");
    const pidFile = join(work, "pid");
    // (its pid said, then `sleep` in its place: a process that never reads fd 0)
    const started = await plane.tool("process.start", { command: `echo $$ > ${pidFile}; exec sleep 600`, cwd: work }, "w1");
    assert.equal(started.ok, true, JSON.stringify(started));
    const pid = await within("the process's pid", 10_000, () => {
      const t = existsSync(pidFile) ? Number(readFileSync(pidFile, "utf8").trim()) : 0;
      return t > 0 ? t : null;
    });
    pids.push(pid);
    assert.ok(alive(pid));
    const process_id = started.result.process_id;
    const chunk = randomBytes(MiB).toString("base64");
    const slowest: number[] = [];
    let written = 0;
    let refused: any = null;
    const begun = Date.now();
    // Written a MiB at a time, its pipe long full: each write answered at once, the station's status asked between.
    for (let i = 0; i < STDIN_MOST / MiB + 8; i++) {
      const r = await plane.tool("process.write", { process_id, data_base64: chunk }, "w1");
      if (r.ok !== true) {
        refused = r;
        break;
      }
      written += MiB;
      if (i % 8 === 7) {
        const st = await statusAsk(data);
        assert.equal(st.status, 200);
        slowest.push(st.ms);
      }
    }
    const took = Date.now() - begun;
    assert.ok(refused !== null, `never refused after ${written / MiB} MiB; ${detail()}`);
    assert.equal(refused.error?.code, "failed", JSON.stringify(refused));
    assert.match(refused.error?.message ?? "", /input is closed|exited/);
    // what the pipe and the queue held: STDIN_MOST, give or take the pipe's own buffer and the one write refused
    assert.ok(written >= STDIN_MOST - 2 * MiB && written <= STDIN_MOST + MiB, `refused after ${written / MiB} MiB`);
    assert.ok(slowest.length >= 7, `the status asked ${slowest.length} times`);
    assert.ok(Math.max(...slowest) < 1_000, `the status socket waited on the stalled pipe: ${slowest.map((m) => m.toFixed(0)).join(", ")} ms`);
    assert.ok(took < 60_000, `${took} ms to write ${written / MiB} MiB`);

    // killed, its end seen by the station, nothing of it left
    await within("the stalled process killed", 5_000, () => !alive(pid), detail);
    const tail = await within("its end told the device tools", 10_000, async () => {
      const t = await plane.tool("process.tail", { process_id }, "w1");
      return t.ok === true && t.result.exited === true ? t : null;
    }, detail);
    assert.equal(tail.result.exited, true);
    const again = await plane.tool("process.write", { process_id, data_base64: "eA==" }, "w1");
    assert.equal(again.ok, false);
    assert.match(again.error.message, /has exited|input is closed/);

    // the station serves on: its status, a process of the device tools started and fed anew
    const st = await statusAsk(data);
    assert.equal(st.status, 200);
    assert.ok(st.ms < 1_000, `${st.ms} ms`);
    const cat = await plane.tool("process.start", { command: "cat", cwd: work }, "w1");
    assert.equal(cat.ok, true, JSON.stringify(cat));
    const fed = await plane.tool("process.write", { process_id: cat.result.process_id, data_base64: Buffer.from("still here\n").toString("base64") }, "w1");
    assert.equal(fed.ok, true, JSON.stringify(fed));
    await within("cat said it back", 10_000, async () => {
      const t = await plane.tool("process.tail", { process_id: cat.result.process_id }, "w1");
      return t.ok === true && Buffer.from(t.result.data_base64, "base64").toString() === "still here\n";
    }, detail);
    assert.equal(s.child.exitCode, null);
  } finally {
    await s.stop();
  }
});
