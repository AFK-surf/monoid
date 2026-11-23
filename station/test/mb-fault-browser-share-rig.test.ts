// Faults and edges of Farview's release, of a profile shared between stations, of an API key's provider failing, and of
// a rig's grants and device tunnels, as the MoonBit program runs them (station/mb src/station_main), held through the
// program itself and never the TypeScript station: `stillfail-reader run` with the launcher's descriptors, every
// program run with a PATH that names no Node. What the TypeScript's own tests hold of these, held here of the program:
// Farview's release asked of each source in turn, a `gh:` one not to be had passed over, one not answering or
// redirected to nothing passed over, a tarball whose SHA-256 is not the release's refused (one reached through a 302
// too) with nothing unpacked or left half way, said in words with what to do where none is to be had, asked again the
// next time a chat asks, and one already in the cache taken with nothing downloaded (farview-release.test.ts,
// browser.test.ts); a key profile shared over loopback iroh to another station, its key never shown there, an edit
// reaching the copy, and the copy taken away when the share stops with the borrower's own profile untouched
// (share.test.ts); an Anthropic key and an OpenAI-compatible provider's refused (401), limited (429) or failing (500),
// each said as it is with nothing of the profile changed, then working again (accounts-quota.test.ts,
// accounts-routes.test.ts); and a rig asked by a station of the workspace over real iroh: a device not attached or
// not granted refused in words, grants brought with another person's lock, a key not on the lock, a signature or body
// that does not hold, an expired one or one brought by another station each refused, a good one letting a chat's
// tunnels to its device through, and its revoke cutting them at once with nothing left open (rig-grants.test.ts,
// rig-requests.test.ts, rig-transport.test.ts).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { createHash, generateKeyPairSync, randomBytes, sign as nodeSign } from "node:crypto";
import { createSocket } from "node:dgram";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer as httpServer, type IncomingMessage, request } from "node:http";
import { type AddressInfo, createServer as tcpServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { type DeviceBody, type GrantBody, type Kind, type RevokeBody, type Timeout, latest, signedBytes as rigSignedBytes } from "../../client/core-ts/src/rig-form.ts";
import { type Entry, entryHash } from "../../shared/lock.ts";
import { loadMesh, type Stream as MeshStream } from "../src/mesh/native.ts";
import { Reader } from "../src/mesh/wire.ts";
import { mbStationBinary } from "./mb-harness.ts";
import { Store } from "../src/store/store.ts";

const binary = mbStationBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here"
  : process.platform === "win32" ? "the launcher's descriptors and signals are Unix's"
  : false;
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();
const skipMesh = skip !== false ? skip : addon === null ? "the mesh addon is not built here (scripts/native.ts run mesh)" : false;

const dirs: string[] = [];
// (short: the status's Unix socket is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(process.platform === "darwin" ? "/tmp" : tmpdir(), `sfb-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
const closers: (() => void | Promise<void>)[] = [];
after(async () => {
  for (const c of closers.splice(0).reverse()) {
    try { await c(); } catch {}
  }
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.race([
    Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined))),
    new Promise((r) => setTimeout(r, 5_000).unref()),
  ]);
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

/// What comes true within `ms` (a file the station writes, a socket's close, another station's copy: nothing here is
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

/// The commands the station runs, each linked into a directory of its own: its PATH, so no Node is (and no `gh`).
const TOOLS = ["sh", "ps", "mv", "cat", "sleep", "echo", "printf", "env", "kill", "sed", "tr", "head", "rm", "mkdir", "ls", "uname", "lsof", "id", "tar", "gzip"];
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
const sha256 = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");

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
    env: { PATH: toolsPath(), HOME: data, TMPDIR: tmpdir(), STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_AGENT_NICE: "0", STILLFAIL_NO_DISCOVERY: "1", ...env },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    try { said.push(JSON.parse(line)); } catch {}
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stdout!.resume();
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
  return { text: r.json.result.content.map((c: any) => c.text).join("\n"), error: r.json.result.isError === true };
}

/// A session of the agents' side, its door's bearer `token` (written beside the running station, as a chat is made).
function session(data: string, key: string, token: string) {
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key, connect: "ember", runtime: "claude", profile: "cc", workspace: fresh("ws"), token, createdAt: Date.now(), lastActiveAt: Date.now() });
  } finally {
    store.close();
  }
}

/// A station's data directory in workspace `w1`, as the control plane last said it.
function enrolled(data: string, place: Record<string, unknown> = {}) {
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9/", station: "abc", workspace: "w1", workspace_name: "Dev", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [], ...place,
  }));
}

/// The data's station key, as the program says it.
const stationId = (data: string) => {
  const r = spawnSync(binary!, ["id", "--data", data], { env: { PATH: "/usr/bin:/bin", HOME: data }, encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
};

const readJson = (p: string) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : null);

/// The control plane of the test's, its presence socket saying each station's place.
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

/// A local HTTP server of the test's, answered by `answer`, every request it was asked kept.
async function serve(answer: (req: IncomingMessage, body: Buffer, res: import("node:http").ServerResponse) => void) {
  const asked: { path: string; headers: IncomingMessage["headers"] }[] = [];
  const server = httpServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (d) => chunks.push(d));
    req.on("end", () => {
      asked.push({ path: req.url ?? "", headers: req.headers });
      answer(req, Buffer.concat(chunks), res);
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  closers.push(() => {
    server.closeAllConnections();
    server.close();
  });
  return { origin: `http://127.0.0.1:${(server.address() as AddressInfo).port}`, asked };
}

// ── Farview's release (farview-release.test.ts, browser.test.ts) ──

/// This system's release name and the release this program takes for it (farview_release.mbt `farview_releases`).
const FV_TARGET = `${process.platform}-${process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "x64" : "other"}`;
const FV_RELEASE = (() => {
  const src = readFileSync(join(import.meta.dirname, "..", "mb", "src", "browser", "farview_release.mbt"), "utf8");
  const m = new RegExp(`"${FV_TARGET}",\\s*\\{\\s*rev: "([0-9a-f]+)",\\s*sha256: "([0-9a-f]{64})"`).exec(src);
  return m === null ? null : { rev: m[1]!, sha256: m[2]! };
})();

/// Every file under `root` whose name is `name`.
function found(root: string, name: string): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    let names: string[];
    try { names = readdirSync(dir); } catch { return; }
    for (const n of names) {
      const at = join(dir, n);
      let st;
      try { st = statSync(at); } catch { continue; }
      if (st.isDirectory()) walk(at);
      else if (n === name) out.push(at);
    }
  };
  walk(root);
  return out;
}

test("Farview's release: a gh: source not to be had, one not answering and one redirected to nothing passed over and said in words with what to do; a tarball not the release's refused, one reached through a 302 too, nothing unpacked or left half way; asked again the next time; one in the cache taken with nothing downloaded", { skip: skip !== false ? skip : FV_RELEASE === null ? `no Farview release for ${FV_TARGET}` : false, timeout: 60_000 }, async () => {
  const release = FV_RELEASE!;
  const name = `farview-${FV_TARGET}-${release.rev.slice(0, 12)}.tar.gz`;
  // A release's tarball as Farview's tools/package.sh makes one (its directory, bin/host.exe in it), not this release's.
  const src = fresh("fvsrc");
  mkdirSync(join(src, "farview-x", "bin"), { recursive: true });
  writeFileSync(join(src, "farview-x", "bin", "host.exe"), "#!/bin/sh\n", { mode: 0o755 });
  writeFileSync(join(src, "farview-x", "bin", "agent.exe"), "#!/bin/sh\n", { mode: 0o755 });
  const made = spawnSync("tar", ["-czf", join(src, "release.tar.gz"), "-C", src, "farview-x"]);
  assert.equal(made.status, 0, String(made.stderr));
  const tarball = readFileSync(join(src, "release.tar.gz"));
  const forged = randomBytes(4096);
  assert.notEqual(sha256(tarball), release.sha256);
  let phase: "none" | "forged" = "none";
  const sources = await serve((req, _body, res) => {
    const url = req.url ?? "";
    if (url.startsWith("/a/")) return void res.writeHead(404).end("not here");
    if (url.startsWith("/b/")) return void (phase === "none" ? res.writeHead(500).end("broken") : res.writeHead(200, { "content-type": "application/octet-stream" }).end(forged));
    if (url.startsWith("/c/")) return void res.writeHead(302, { location: phase === "none" ? `/missing/${name}` : `/tar/${name}` }).end();
    if (url.startsWith("/tar/")) return void res.writeHead(200, { "content-type": "application/gzip" }).end(tarball);
    res.writeHead(404).end("no such release");
  });
  const asked = () => sources.asked.map((a) => a.path);
  const home = fresh("fvhome");
  const cache = process.platform === "darwin" ? join(home, "Library", "Caches", "stillfail-native") : join(home, ".cache", "stillfail-native");
  const dir = join(cache, "farview", `${release.rev.slice(0, 12)}-${FV_TARGET}`);
  const data = fresh("fv");
  enrolled(data);
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [] }));
  const gh = "gh:sf-nobody-test/none@nope";
  const a = await launch(data, {
    HOME: home, XDG_CACHE_HOME: join(home, ".cache"),
    STILLFAIL_FARVIEW_SOURCES: `${gh}, ${sources.origin}/a,${sources.origin}/b , ${sources.origin}/c`,
  });
  session(data, "chat:c-fv", "t-fv");
  const choose = () => tool(a.door, "t-fv", "browser", { engine: "farview", action: "status" });
  const nothingLeft = (what: string) => {
    assert.equal(existsSync(dir), false, `${what}: nothing where the release is looked for`);
    assert.deepEqual(existsSync(join(cache, "farview")) ? readdirSync(join(cache, "farview")) : [], [], `${what}: nothing half unpacked beside it`);
    assert.deepEqual(found(home, "host.exe"), [], `${what}: nothing of a tarball unpacked anywhere`);
  };

  // ── none to be had: the gh: source passed over (no gh here), one refusing, one failing, one redirected to nothing;
  // said so, naming each, with what to do instead ──
  const none = await choose();
  assert.equal(none.error, true, none.text);
  assert.match(none.text, /could not be downloaded/, none.text);
  assert.match(none.text, /browser\.farview/, `what to do instead: ${none.text}`);
  for (const s of [gh, `${sources.origin}/a`, `${sources.origin}/b`, `${sources.origin}/c`]) assert.ok(none.text.includes(`${s}/${name}`), `${s} named: ${none.text}`);
  assert.deepEqual(asked(), [`/a/${name}`, `/b/${name}`, `/c/${name}`, `/missing/${name}`], "each asked in turn, the redirect followed");
  nothingLeft("none to be had");

  // ── the same chat asks again (a failed download is not kept): one source's bytes not the release's, another's reached
  // through a 302 not either: both refused with their SHA-256, nothing of them unpacked ──
  phase = "forged";
  sources.asked.length = 0;
  const refused = await choose();
  assert.equal(refused.error, true, refused.text);
  assert.ok(refused.text.includes(`Farview's release ${name} was refused: ${sources.origin}/b/${name} (SHA-256 ${sha256(forged)}, not ${release.sha256}); ${sources.origin}/c/${name} (SHA-256 ${sha256(tarball)}, not ${release.sha256})`), refused.text);
  assert.ok(!refused.text.includes(gh), `a source passed over is not among those refused: ${refused.text}`);
  assert.deepEqual(asked(), [`/a/${name}`, `/b/${name}`, `/c/${name}`, `/tar/${name}`], "asked again, every source in turn");
  nothingLeft("refused");
  assert.equal(existsSync(join(data, "browser", "farview")) ? found(join(data, "browser", "farview"), "engine").length : 0, 0, "the chat's choice not kept while its release is not there");

  // ── the release already in the cache (another station process unpacked it): taken as it is, nothing downloaded ──
  mkdirSync(join(dir, "bin"), { recursive: true });
  writeFileSync(join(dir, "bin", "host.exe"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  writeFileSync(join(dir, "bin", "agent.exe"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
  sources.asked.length = 0;
  const cached = await choose();
  assert.equal(cached.error, false, `${cached.text}\n${a.err().slice(-3000)}`);
  assert.match(cached.text, /Not running/, cached.text);
  assert.deepEqual(asked(), [], "nothing downloaded");
  assert.equal(readFileSync(join(dir, "bin", "host.exe"), "utf8"), "#!/bin/sh\nexit 1\n", "the cache's left as it was");
  assert.equal(a.child.exitCode, null, a.err().slice(-3000));
  await a.stop();
});

// ── a profile shared between stations (share.test.ts) ──

test("a shared key profile: copied over loopback iroh to the other station, its key never shown there, an edit reaching the copy; taken away as the share stops, the borrower's own profile untouched", { skip, timeout: 90_000 }, async () => {
  const anthropic = await serve((_req, _body, res) => void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ data: [{ id: "claude-x" }] })));
  const [dataA, dataB] = [fresh("sha"), fresh("shb")];
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  const placeOf = (st: string) => ({ workspace: "w1", workspace_name: "Team", name: st === idA ? "alpha" : "beta", peers, grant_keys: null });
  const origin = await controlPlane(placeOf);
  for (const [data, id] of [[dataA, idA], [dataB, idB]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin, station: id, relay_url: "", relay_urls: [], revocations: [], ...placeOf(id) }));
  }
  const TEAM = "sk-team-secret-0123";
  const MINE = "sk-mine-only-4567";
  writeFileSync(join(dataA, "config.json"), JSON.stringify({ profiles: [{ id: "team-key", name: "Team key", runtime: "claude", access: { kind: "anthropic-api", key: TEAM }, home: "homes/team-key" }] }));
  writeFileSync(join(dataB, "config.json"), JSON.stringify({ profiles: [{ id: "mine", name: "Mine", runtime: "claude", access: { kind: "anthropic-api", key: MINE }, home: "homes/mine" }] }));
  const env = (port: number) => ({ STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}`, STILLFAIL_ANTHROPIC_API: anthropic.origin });
  const a = await launch(dataA, env(portA));
  const b = await launch(dataB, env(portB));
  const detail = () => `A: ${a.err().slice(-2000)}\nB: ${b.err().slice(-2000)}`;
  for (const d of [dataA, dataB]) await within("online at the plane", 20_000, () => readJson(join(d, "run", "presence.json"))?.online === true, detail);
  const cfg = (data: string) => JSON.parse(readFileSync(join(data, "config.json"), "utf8")) as { profiles: any[] };
  const views = async (port: number) => {
    const r = await http(port, "/admin-api/profiles");
    assert.equal(r.status, 200, r.body.toString());
    return { list: r.json as any[], text: r.body.toString() };
  };
  const mineBefore = cfg(dataB).profiles.find((p) => p.id === "mine");

  // ── shared (its sharing part answers once it has started) ──
  const shared = await within("the profile shared", 20_000, async () => {
    const r = await http(a.door, "/admin-api/profiles/team-key/share", { body: { on: true } });
    return r.status === 503 ? null : r;
  }, detail);
  assert.equal(shared.status, 200, `${shared.body}\n${detail()}`);
  const sid = cfg(dataA).profiles.find((p) => p.id === "team-key")?.share?.id as string;
  assert.match(sid, /^sh-[0-9a-f]{20}$/, JSON.stringify(cfg(dataA)));
  const copy = await within("the copy on beta", 30_000, () => cfg(dataB).profiles.find((p) => p.share?.id === sid), detail);
  assert.equal(copy.id, sid);
  assert.equal(copy.share.borrowed, true, JSON.stringify(copy));
  assert.equal(copy.access.key, TEAM, "the key goes with the copy (stations keep it as their own config)");
  // Shown on beta, as its owner sees it: the copy and whose it is, no key of either profile.
  const onB = await within("the copy listed on beta", 15_000, async () => {
    const v = await views(b.door);
    return v.list.some((p) => p.id === sid) ? v : null;
  }, detail);
  assert.ok(!onB.text.includes(TEAM), `the shared key shown on beta: ${onB.text}`);
  assert.ok(!onB.text.includes(MINE), `beta's own key shown: ${onB.text}`);
  assert.ok(onB.list.some((p) => p.id === "mine"), "its own beside it");
  assert.ok(!(await views(a.door)).text.includes(TEAM), "nor on alpha");

  // ── an edit on its host reaches the copy ──
  assert.equal((await http(a.door, "/admin-api/profiles/team-key", { method: "PUT", body: { name: "Team key 2" } })).status, 200);
  await within("the edit on beta's copy", 30_000, () => cfg(dataB).profiles.find((p) => p.id === sid)?.name === "Team key 2", () => `${JSON.stringify(cfg(dataB))}\n${detail()}`);

  // ── the share stops: the copy taken away on beta, its own profile as it was; the host's kept, key and all ──
  const stopped = await http(a.door, "/admin-api/profiles/team-key/share", { body: { on: false } });
  assert.equal(stopped.status, 200, `${stopped.body}\n${detail()}`);
  await within("the copy gone from beta", 30_000, () => !cfg(dataB).profiles.some((p) => p.id === sid || p.share?.id === sid), () => `${JSON.stringify(cfg(dataB))}\n${detail()}`);
  assert.deepEqual(cfg(dataB).profiles.find((p) => p.id === "mine"), mineBefore, "beta's own profile untouched");
  await within("gone from beta's list", 10_000, async () => !(await views(b.door)).list.some((p) => p.id === sid));
  const host = cfg(dataA).profiles.find((p) => p.id === "team-key");
  assert.equal(host.share, undefined, JSON.stringify(host));
  assert.equal(host.access.key, TEAM);
  assert.equal(host.name, "Team key 2");
  for (const s of [a, b]) assert.equal(s.child.exitCode, null, detail());
  await Promise.all([a.stop(), b.stop()]);
});

// ── a provider failing and recovering (accounts-quota.test.ts, accounts-routes.test.ts) ──

test("an Anthropic key and an OpenAI-compatible provider refused (401), limited (429) or failing (500): each said as it is, nothing of the profile changed, the station serving; working again once the provider is", { skip, timeout: 60_000 }, async () => {
  let mode: 200 | 401 | 429 | 500 = 200;
  const provider = await serve((req, _body, res) => {
    const anthropic = (req.url ?? "").startsWith("/anthropic/");
    if (mode === 200) {
      const data = anthropic ? [{ id: "claude-b" }, { id: "claude-a" }] : [{ id: "gpt-z" }, { id: "gpt-y" }, { id: "gpt-y:batch" }];
      return void res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ data }));
    }
    const said = mode === 401 ? { type: "authentication_error", message: "invalid x-api-key" }
      : mode === 429 ? { type: "rate_limit_error", message: "Number of requests has exceeded your rate limit" }
      : { type: "api_error", message: "Internal server error" };
    res.writeHead(mode, { "content-type": "application/json", ...(mode === 429 ? { "retry-after": "30" } : {}) }).end(JSON.stringify({ type: "error", error: said }));
  });
  const data = fresh("acc");
  enrolled(data);
  writeFileSync(join(data, "config.json"), JSON.stringify({
    profiles: [
      { id: "ak", name: "Anthropic key", runtime: "claude", access: { kind: "anthropic-api", key: "sk-ant-test-1" }, home: "homes/ak" },
      { id: "oai", name: "Compatible", access: { kind: "api-provider", provider: "custom", endpoint: `${provider.origin}/openai/v1`, protocol: "chat_completions", key: "sk-oai-test-2" }, home: "homes/oai" },
    ],
  }));
  const a = await launch(data, { STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_ANTHROPIC_API: `${provider.origin}/anthropic` });
  const config = () => readFileSync(join(data, "config.json"), "utf8");
  const profiles = () => JSON.parse(config()).profiles;
  await within("the accounts ready", 15_000, async () => (await http(a.door, "/admin-api/profiles")).status === 200, () => a.err().slice(-2000));
  const before = profiles();
  const check = async (id: string) => {
    const r = await http(a.door, `/admin-api/profiles/${id}/check`, { body: {}, headers: { "stillfail-lang": "en" } });
    assert.equal(r.status, 200, `${id}: ${r.body}\n${a.err().slice(-2000)}`);
    return r.json as { state: string; detail: string; models: string[] | null };
  };
  const shown = async (id: string) => ((await http(a.door, "/admin-api/profiles", { headers: { "stillfail-lang": "en" } })).json as any[]).find((p) => p.id === id);

  for (const status of [401, 429, 500] as const) {
    mode = status;
    provider.asked.length = 0;
    const ak = await check("ak");
    assert.equal(ak.state, "failed", `anthropic ${status}: ${JSON.stringify(ak)}`);
    assert.equal(ak.detail, `Anthropic refused this key (${status})`, `anthropic ${status}`);
    assert.equal(ak.models, null);
    const oai = await check("oai");
    if (status === 401) {
      assert.equal(oai.state, "failed", `custom 401: ${JSON.stringify(oai)}`);
      assert.equal(oai.detail, "Custom refused this key (401)");
    } else {
      // (a provider that does not list its models now is not held against its key: unchecked, not failed)
      assert.equal(oai.state, "unknown", `custom ${status}: ${JSON.stringify(oai)}`);
      assert.match(oai.detail, /accepted this key but doesn't list models/, `custom ${status}`);
    }
    assert.equal(oai.models, null);
    // asked of the provider each with its own key, as each provider takes it
    const anth = provider.asked.find((q) => q.path.startsWith("/anthropic/v1/models"));
    assert.equal(anth?.headers["x-api-key"], "sk-ant-test-1", JSON.stringify(provider.asked));
    assert.equal(anth?.headers["anthropic-version"], "2023-06-01");
    const compat = provider.asked.find((q) => q.path === "/openai/v1/models");
    assert.equal(compat?.headers.authorization, "Bearer sk-oai-test-2", JSON.stringify(provider.asked));
    // what is shown says so; nothing of either profile changed (no key dropped, nothing paused), the station serving
    assert.equal((await shown("ak"))?.check?.state, "failed", `shown after ${status}`);
    assert.deepEqual(profiles(), before, `config.json's profiles after ${status}`);
    assert.ok(!(await http(a.door, "/admin-api/profiles")).body.toString().includes("sk-ant-test-1"), "a key is never shown");
    assert.equal(a.child.exitCode, null, a.err().slice(-3000));
  }

  // ── the provider back: both work again, their models as listed ──
  mode = 200;
  const ak = await check("ak");
  assert.equal(ak.state, "ok", JSON.stringify(ak));
  assert.deepEqual([...(ak.models ?? [])].sort(), ["claude-a", "claude-b"]);
  const oai = await check("oai");
  assert.equal(oai.state, "ok", JSON.stringify(oai));
  assert.deepEqual(oai.models, ["gpt-y", "gpt-z"], "sorted, the batch-only entry left out");
  assert.equal((await shown("ak"))?.check?.state, "ok");
  assert.equal((await shown("oai"))?.check?.state, "ok");
  assert.deepEqual(profiles(), before);
  await a.stop();
});

// ── a rig's grants and device tunnels on the mesh (rig-grants.test.ts, rig-requests.test.ts, rig-transport.test.ts) ──

function ed() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const hex = (publicKey.export({ format: "der", type: "spki" }) as Buffer).subarray(-32).toString("hex");
  return { hex, id: `ed25519:${hex}`, sign: (bytes: Uint8Array) => nodeSign(null, bytes, privateKey).toString("hex") };
}
type Key = ReturnType<typeof ed>;
const digest = (b: Uint8Array) => createHash("sha256").update(b).digest();

/// A person's own lock: its genesis, and a statement signed by a key (on it, or not).
function person(sub: string) {
  const first = ed();
  const e = { v: 1 as const, ws: `person:${sub}`, seq: 0, prev: null, at: 1000, kind: "genesis", body: { sub, device: { key: first.id, id: ed().hex, label: "first" } } };
  const hash = entryHash(e as Entry);
  const chain: Entry[] = [{ ...e, sig: { key: first.id, alg: "Ed25519", sig: first.sign(Buffer.concat([Buffer.from("stillfail-lock/1 sig\0"), Buffer.from(hash, "hex")])) } }];
  const says = <B>(kind: Kind, body: B, by: Key = first) => ({ body, sig: { key: by.id, sig: by.sign(rigSignedBytes(kind, body, digest)) } });
  return { sub, chain, says, genesis: hash };
}

const line = (stream: MeshStream, value: unknown) => stream.write(Buffer.from(JSON.stringify(value) + "\n"));

test("a rig asked over iroh: a device not attached or not granted refused in words; grants with another's lock, a key not on the lock, a signature or body that does not hold, expired, or brought by another station refused; a good one lets a chat's tunnels to its device through, its revoke cuts them at once with nothing left open", { skip: skipMesh !== false ? skipMesh : spawnSync("lsof", ["-v"]).error ? "no lsof here" : false, timeout: 90_000 }, async () => {
  // (a station of the workspace's, by real iroh, its key the test's)
  const station = await addon!.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("client/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" });
  closers.push(() => station.close());
  const alpha = station.id();
  const data = fresh("rig");
  const id = stationId(data);
  const port = await freeUdpPort();
  const owner = person("pat");
  const peers = [{ id: alpha, name: "alpha", ips: [] }];
  const origin = await controlPlane(() => ({ workspace: "w1", workspace_name: "Team", name: "box", peers, grant_keys: {}, rig: { owner: "pat" } }));
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin, station: id, workspace: "w1", workspace_name: "Team", name: "box", relay_url: "", relay_urls: [], grant_keys: {}, peers, revocations: [],
    rig: { owner: "pat", owner_email: "pat@example.com", owner_name: "Pat", person: owner.genesis },
  }));
  const r = await launch(data, { STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}` });
  await within("the rig online at the plane", 20_000, () => readJson(join(data, "run", "presence.json"))?.online === true, () => r.err().slice(-2000));
  const at = { id, ips: [`127.0.0.1:${port}`] };

  // What the rig answers a station (peer.ts: one request a stream, `{workspace, request}`, answered `{result}` or `{error}`).
  const peerConn = await within("connected to the rig", 20_000, () => station.connect(at, Buffer.from("stillfail/station/2")), () => r.err().slice(-2000));
  const ask = async (request: Record<string, unknown>) => {
    const s = await peerConn.openBi();
    await line(s, { workspace: "w1", request });
    await s.finish();
    return (await new Reader(s).line()) as { result?: any; error?: string };
  };
  assert.equal((await within("the rig answers", 20_000, async () => {
    const d = await ask({ method: "rig.describe" });
    return d.result !== undefined ? d : null;
  }, () => r.err().slice(-2000))).error, undefined);

  // The device a person attached to it: an echo service on this machine's network.
  const echo = { open: 0, closed: 0 };
  const service = tcpServer((socket) => {
    echo.open++;
    socket.on("error", () => {});
    socket.on("close", () => echo.closed++);
    socket.pipe(socket);
  });
  await new Promise<void>((res) => service.listen(0, "127.0.0.1", () => res()));
  closers.push(() => void service.close());
  const servicePort = (service.address() as AddressInfo).port;
  const DEVICE = "0123456789abcdef";
  const now = () => Math.floor(Date.now() / 1000);
  const device: DeviceBody = { v: 1, sub: "pat", ws: "w1", rig: id, device: { id: DEVICE, name: "bench", kind: "tcp", target: `127.0.0.1:${servicePort}` }, removed: false, at: now() };
  const stranger = ed();
  const notOnLock = await ask({ method: "rig.device", workspace: "w1", signed: owner.says("device", device, stranger), chain: owner.chain });
  assert.match(String(notOnLock.error), /not on this rig's person's own lock/, JSON.stringify(notOnLock));
  const attached = await ask({ method: "rig.device", workspace: "w1", signed: owner.says("device", device), chain: owner.chain });
  assert.deepEqual(attached, { result: { ok: true } });

  // A chat's tunnel to the device (peer-http.ts `tunnelDevice`): `{workspace, device, session, tcp}`, answered 200 then
  // its bytes, or its refusal's status and words.
  type Tunnel = { stream: MeshStream; carry: Buffer };
  const tunnel = async (sessionKey: string, dev = DEVICE, probe = false): Promise<{ status: number; said: string; t: Tunnel | null }> => {
    const conn = await station.connect(at, Buffer.from("stillfail/http/1"));
    const s = await conn.openBi();
    await line(s, { workspace: "w1", device: dev, session: sessionKey, tcp: true, ...(probe ? { probe: true } : {}) });
    if (probe) await s.finish();
    const reader = new Reader(s);
    const head = await reader.line();
    if (head?.status === 200) {
      if (probe) return { status: 200, said: "", t: null };
      closers.push(() => void s.reset(0).catch(() => {}));
      return { status: 200, said: "", t: { stream: s, carry: reader.carry } };
    }
    return { status: head?.status ?? 0, said: (await reader.rest()).toString(), t: null };
  };
  const echoed = async (t: Tunnel, text: string) => {
    await t.stream.write(Buffer.from(text));
    let got = t.carry;
    while (got.length < text.length) {
      const more = await t.stream.read();
      if (more === null) throw new Error(`the tunnel ended before its echo: ${got}`);
      got = Buffer.concat([got, more]);
    }
    t.carry = got.subarray(text.length);
    return got.subarray(0, text.length).toString();
  };
  const refusedDevice = async (what: string, sessionKey: string) => {
    for (const probe of [true, false]) {
      const got = await tunnel(sessionKey, DEVICE, probe);
      assert.equal(got.status, 403, `${what} (probe ${probe}): ${JSON.stringify(got)}`);
      assert.match(got.said, /no grant of this device.*device_use/, `${what} (probe ${probe})`);
    }
  };

  // ── nothing granted: a device not attached is none (404), the one attached refused (403), a task refused, each saying
  // why and what to do ──
  const unknown = await tunnel("s1", "fedcba9876543210");
  assert.equal(unknown.status, 404, JSON.stringify(unknown));
  assert.match(unknown.said, /no such device on this rig/);
  await refusedDevice("no grant yet", "s1");
  const task = await ask({ method: "task.prepare", session: "s1", key: "k1", spec: { command: "echo hi", name: "t" } });
  assert.match(String(task.error), /no grant of this station.*station_use/, JSON.stringify(task));

  // ── grants that do not hold, each refused as the rig checks it against the lock it pinned ──
  const timeout: Timeout = { kind: "idle", seconds: 3600 };
  const grantBody = (request: string, more: Partial<GrantBody> = {}): GrantBody => {
    const t = now();
    return { v: 1, sub: "pat", ws: "w1", rig: id, station: alpha, session: "s1", chat: "CHAT/1795100000.000001", request, title: "the chat", by: "pat@example.com", timeout, at: t, exp: latest(t, timeout), ...more };
  };
  const other = person("pat");
  const flip = (hex: string) => (hex[0] === "0" ? "1" : "0") + hex.slice(1);
  const signedOk = owner.says("grant", grantBody("rq-x"));
  const expiredAt = now() - 7200;
  const forged: [string, unknown, unknown, RegExp][] = [
    ["another person's lock", other.says("grant", grantBody("rq-x")), other.chain, /not the one this rig's person pinned/],
    ["a key not on the lock", owner.says("grant", grantBody("rq-x"), stranger), owner.chain, /not on this rig's person's own lock/],
    ["a signature altered", { ...signedOk, sig: { ...signedOk.sig, sig: flip(signedOk.sig.sig) } }, owner.chain, /signature does not hold/],
    ["a body altered after it was signed", { ...signedOk, body: { ...signedOk.body, session: "s2" } }, owner.chain, /signature does not hold/],
    ["expired", owner.says("grant", grantBody("rq-x", { at: expiredAt, timeout: { kind: "fixed", seconds: 3600 }, exp: expiredAt + 3600 })), owner.chain, /expired/],
    ["brought for another station", owner.says("grant", grantBody("rq-x", { station: "cd".repeat(32) })), owner.chain, /brought by its chat's own station/],
    ["not a grant", owner.says("revoke", { v: 1, sub: "pat", ws: "w1", rig: id, request: "rq-x", at: now() } satisfies RevokeBody), owner.chain, /not a rig's grant/],
  ];
  for (const [what, signed, chain, why] of forged) {
    const got = await ask({ method: "rig.grant", workspace: "w1", signed, chain });
    assert.equal(got.result, undefined, `${what}: taken: ${JSON.stringify(got)}`);
    assert.match(String(got.error), why, `${what}: ${JSON.stringify(got)}`);
  }
  await refusedDevice("after the grants refused", "s1");
  assert.equal(r.child.exitCode, null, r.err().slice(-3000));

  // ── a good grant: the chat's tunnels through, both ways; another chat of the same station still refused ──
  const granted = await ask({ method: "rig.grant", workspace: "w1", signed: owner.says("grant", grantBody("rq-1")), chain: owner.chain });
  assert.equal(typeof granted.result?.until, "number", JSON.stringify(granted));
  const one = await tunnel("s1");
  assert.equal(one.status, 200, JSON.stringify(one));
  const two = await tunnel("s1");
  assert.equal(two.status, 200, JSON.stringify(two));
  assert.equal(await echoed(one.t!, "hello through one"), "hello through one");
  assert.equal(await echoed(two.t!, "hello through two"), "hello through two");
  await within("both connections to the device open", 5_000, () => echo.open === 2, () => JSON.stringify(echo));
  await refusedDevice("another chat", "s2");
  // a revoke its person did not sign: refused, nothing cut
  const notRevoked = await ask({ method: "rig.revoke", workspace: "w1", signed: owner.says("revoke", { v: 1, sub: "pat", ws: "w1", rig: id, request: "rq-1", at: now() } satisfies RevokeBody, stranger), chain: owner.chain });
  assert.match(String(notRevoked.error), /not on this rig's person's own lock/, JSON.stringify(notRevoked));
  assert.equal(await echoed(one.t!, "still here"), "still here");

  // ── taken back: both tunnels cut at once, the device's side of them closed, nothing of them left open on the rig ──
  const ends = [one.t!, two.t!].map((t) => (async () => {
    try {
      for (let more = await t.stream.read(); more !== null; more = await t.stream.read()) {}
      return "ended";
    } catch (e) {
      return `failed ${(e as Error).message}`;
    }
  })());
  const revokedAt = Date.now();
  const revoked = await ask({ method: "rig.revoke", workspace: "w1", signed: owner.says("revoke", { v: 1, sub: "pat", ws: "w1", rig: id, request: "rq-1", at: now() } satisfies RevokeBody), chain: owner.chain });
  assert.deepEqual(revoked, { result: { ok: true } });
  const CUT_MS = 5_000;
  const how = await Promise.race([Promise.all(ends), new Promise<null>((res) => setTimeout(() => res(null), CUT_MS))]);
  assert.notEqual(how, null, `the tunnels not cut within ${CUT_MS} ms of the revoke`);
  await within("the device's side of both closed", CUT_MS, () => echo.closed === 2, () => JSON.stringify(echo));
  const rigTcp = () => spawnSync("lsof", ["-nP", "-a", "-p", String(r.child.pid), `-iTCP:${servicePort}`], { encoding: "utf8" }).stdout.split("\n").slice(1).filter((l) => /ESTABLISHED/.test(l));
  await within("nothing of them left open on the rig", CUT_MS, () => rigTcp().length === 0, () => rigTcp().join("\n"));
  const tookMs = Date.now() - revokedAt;
  assert.ok(tookMs < CUT_MS, `cut ${tookMs} ms after the revoke`);
  await refusedDevice("after the revoke", "s1");
  const again = await ask({ method: "rig.grant", workspace: "w1", signed: owner.says("grant", grantBody("rq-1")), chain: owner.chain });
  assert.match(String(again.error), /taken back/, `a grant taken back is not brought again: ${JSON.stringify(again)}`);
  const afterTask = await ask({ method: "task.prepare", session: "s1", key: "k2", spec: { command: "echo hi", name: "t" } });
  assert.match(String(afterTask.error), /no grant of this station/, JSON.stringify(afterTask));
  assert.equal(r.child.exitCode, null, r.err().slice(-3000));
  peerConn.close(0, "done");
  await r.stop();
});
