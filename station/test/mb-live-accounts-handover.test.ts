// The station as the MoonBit program composes it (station/mb src/station_main), held where it fell short of the
// TypeScript: what the event streams told goes over to the next process whichever program wrote it (run/events.json,
// api/events.ts `eventsHandoverFile`), Node's to the program's and back; the launcher asked to start the front again
// (`restartFront`, ops/launcher.ts) where it hands its sockets down and hears the heartbeat; a profile's sign-in for a
// new profile run by the program's own sign-ins (login.ts's LoginManager: `codex login --device-auth`, its page and
// code in the overview, its end making the profile); the machine's own logins (machine.ts) read and a profile made on
// one (POST /profiles/machine); and a machine that only runs tasks answering `stillfail update --beta` (SIGHUP, its
// channel in run/channel-ask) as rig/main.ts does. Each through `stillfail-reader run` under a launcher of the test's,
// with a PATH that names no Node, a runtime's command a script of the test's.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import { Events } from "../src/api/events.ts";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-${what}-`));
  dirs.push(dir);
  return dir;
};
const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(left.map((c) => (c.exitCode === null && c.signalCode === null ? new Promise<void>((r) => c.once("exit", () => r())) : undefined)));
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

const TOOLS = ["sh", "mv", "cat", "sleep", "echo", "printf", "env", "ls", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "ps", "stty", "script", "id", "kill"];
function binOf(name: string): string {
  const found = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin"].map((d) => join(d, name)).find((p) => existsSync(p));
  return found ?? "";
}
/// A PATH of the test's own: TOOLS, and `more` (a runtime's script), no Node.
function toolsPath(more: Record<string, string> = {}): string {
  const dir = fresh("path");
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  for (const [name, script] of Object.entries(more)) {
    writeFileSync(join(dir, name), script);
    chmodSync(join(dir, name), 0o755);
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fifth's pipe.
async function launch(data: string, app: string, env: Record<string, string>, flags: string[] = []): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat", ...flags], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: { HOME: fresh("home"), TMPDIR: tmpdir(), STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_LOCAL_ADMIN: "1", STILLFAIL_NO_DISCOVERY: "1", ...env, PATH: env.PATH ?? toolsPath() },
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 20_000);
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
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

function ask(port: number, path: string, o: { method?: string; body?: string } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json" } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

type Told = { id?: string; event?: string; data?: any };
/// Events as a stream's text says them.
function toldIn(text: string): Told[] {
  return text.split("\n\n").filter((b) => b.trim() !== "").map((block) => {
    const t: Told = {};
    for (const line of block.split("\n")) {
      const at = line.indexOf(": ");
      if (at < 0) continue;
      const k = line.slice(0, at);
      const v = line.slice(at + 2);
      if (k === "id") t.id = v;
      else if (k === "event") t.event = v;
      else if (k === "data") t.data = (() => { try { return JSON.parse(v); } catch { return v; } })();
    }
    return t;
  });
}

/// An event stream of the admin API (GET /events): its headers, what it said so far, its end.
function events(port: number, path: string) {
  const heard: string[] = [];
  let close = () => {};
  const opened = new Promise<{ status: number; headers: Record<string, unknown> }>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (d: string) => heard.push(d));
      res.on("error", () => {});
      resolve({ status: res.statusCode!, headers: res.headers });
    });
    req.on("error", () => {});
    close = () => req.destroy();
    req.end();
  });
  return { opened, close: () => close(), told: () => toldIn(heard.join("")) };
}

/// What comes true within `ms` (a real process's doing, which nothing here can be told of).
async function given<T>(what: string, look: () => Promise<T | null | false | undefined> | T | null | false | undefined, ms = 20_000): Promise<T> {
  const until = Date.now() + ms;
  for (;;) {
    const got = await look();
    if (got !== null && got !== false && got !== undefined) return got;
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}`);
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

/// A station's data directory with a chat of its own, there before it starts.
function stationData(): { data: string; app: string; thread: number } {
  const data = fresh("data");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9600\n");
  writeFileSync(join(data, "config.json"), `${JSON.stringify({ language: "en" })}\n`);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  const thread = store.openThread("ember", "local", "t1", "first", null).id;
  store.close();
  return { data, app, thread };
}

/// Node's event streams (api/events.ts) on `data`, as main.ts makes them, taking up what the process `before` handed over.
function nodeEvents(data: string, before: number | null) {
  let listener: (change: any) => void = () => {};
  const events = new Events({
    readers: { read: async (op: string) => (op === "sharedOf" ? JSON.stringify({ rows: [], scope: null }) : "null") } as never,
    said: () => [],
    subscribe: (l) => ((listener = l), () => {}),
    host: async () => ({}),
    jobLog: () => null,
    logNow: async () => null,
    sessionExists: () => true,
    handover: { file: join(data, "run", "events.json"), previous: { pid: before, gone: Promise.resolve() } },
  });
  return { events, change: (c: unknown) => listener(c) };
}
const owner = { sub: "owner", email: "owner@x", name: "Owner", role: "owner", workspace: "w", device: "d" };
async function nodeStream(events: Events, since: string | null) {
  const answer = await events.open(owner as never, "en", false, [], [], since);
  const heard: string[] = [];
  const body = answer.body as AsyncIterable<Buffer>;
  const it = body[Symbol.asyncIterator]();
  void (async () => {
    for (;;) {
      const n = await it.next().catch(() => ({ done: true, value: undefined }));
      if (n.done) return;
      heard.push(String(n.value));
    }
  })();
  return { resumed: (answer.headers as Record<string, string>)["stillfail-resumed"] === "1", told: () => toldIn(heard.join("")), close: () => it.return?.() };
}

test("the event streams' handover: the program's to the program's, to Node's, and Node's to the program's, each stream resumed with nothing missed", { skip }, async () => {
  const { data, app, thread } = stationData();
  // ── the program, then the program again ──
  const a = await launch(data, app, {});
  await a.next("ready", (m) => m.ready === true);
  const doorA = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const streamA = events(doorA, "/admin-api/events");
  assert.equal((await streamA.opened).status, 200);
  assert.equal((await ask(doorA, `/admin-api/threads/${thread}/title`, { method: "PUT", body: JSON.stringify({ title: "renamed once" }) })).status, 200);
  const first = await given("the chat renamed, told", () => streamA.told().find((t) => t.event === "chat-changed" && t.data?.thread === thread && t.id));
  // A second change after what the device heard: what a stream coming back from `first` is told again.
  assert.equal((await ask(doorA, `/admin-api/threads/${thread}/title`, { method: "PUT", body: JSON.stringify({ title: "renamed twice" }) })).status, 200);
  await given("the second, told", () => streamA.told().filter((t) => t.event === "chat-changed" && t.id).length >= 2);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
  const handed = readJson(join(data, "run", "events.json"));
  assert.ok(handed !== null, `run/events.json written (${a.err()})`);
  assert.equal(handed.pid, a.child.pid, "written by the process that stopped");
  assert.equal(existsSync(join(data, "run", "events-handover.json")), false);

  const b = await launch(data, app, {});
  await b.next("ready", (m) => m.ready === true);
  const doorB = (await b.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const streamB = events(doorB, `/admin-api/events?since=${encodeURIComponent(first.id!)}`);
  const openedB = await streamB.opened;
  assert.equal(openedB.status, 200);
  assert.equal(openedB.headers["stillfail-resumed"], "1", `resumed from ${first.id}: ${JSON.stringify(streamB.told())}`);
  await given("the second change told again", () => streamB.told().some((t) => t.event === "chat-changed" && t.data?.thread === thread));
  assert.equal(streamB.told().some((t) => t.event === "missed"), false, JSON.stringify(streamB.told()));
  assert.equal(existsSync(join(data, "run", "events.json")), false, "taken up, then removed");
  // what B tells goes on from A's numbers
  assert.equal((await ask(doorB, `/admin-api/threads/${thread}/title`, { method: "PUT", body: JSON.stringify({ title: "renamed by B" }) })).status, 200);
  const third = await given("B's own change", () => streamB.told().filter((t) => t.event === "chat-changed" && t.id).at(-1)?.id !== first.id && streamB.told().filter((t) => t.event === "chat-changed" && t.id).at(-1));
  assert.equal(third.id!.split(".")[0], first.id!.split(".")[0], "the same run");
  b.tell({ op: "stop" });
  assert.equal(await b.ended, 0, b.err());

  // ── the program's, taken up by Node's ──
  const { events: node, change } = nodeEvents(data, b.child.pid!);
  const fromNode = await nodeStream(node, first.id!);
  assert.equal(fromNode.resumed, true, `Node resumed the program's log: ${JSON.stringify(fromNode.told())}`);
  await given("Node told again what came after", () => fromNode.told().filter((t) => t.event === "chat-changed").length >= 2);
  assert.equal(fromNode.told().some((t) => t.event === "missed"), false, JSON.stringify(fromNode.told()));
  // ── Node's, taken up by the program ──
  // (a chat's rows changed in Node's store: told as `chat-changed`, as the program tells it)
  const heardBefore = new Set(fromNode.told().map((t) => t.id));
  change({ type: "thread", id: thread, entries: [] });
  const nodeSaid = await given("Node's own change", () => fromNode.told().find((t) => t.event === "chat-changed" && t.id && !heardBefore.has(t.id))?.id);
  await node.handOver();
  fromNode.close();
  assert.equal(readJson(join(data, "run", "events.json"))?.pid, process.pid, "Node wrote run/events.json");
  const c = await launch(data, app, {});
  await c.next("ready", (m) => m.ready === true);
  const doorC = (await c.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const streamC = events(doorC, `/admin-api/events?since=${encodeURIComponent(third.id!)}`);
  const openedC = await streamC.opened;
  assert.equal(openedC.headers["stillfail-resumed"], "1", `the program resumed Node's log: ${JSON.stringify(streamC.told())}`);
  await given(`Node's change (${nodeSaid}) told again`, () => streamC.told().some((t) => t.event === "chat-changed" && t.id === nodeSaid)).catch((e) => {
    throw new Error(`${e.message}: ${JSON.stringify(streamC.told())}`);
  });
  assert.equal(streamC.told().some((t) => t.event === "missed"), false, JSON.stringify(streamC.told()));
  streamC.close();
  c.tell({ op: "stop" });
  assert.equal(await c.ended, 0, c.err());
});

test("the page's restart asks the launcher to start the front again where it hands its sockets down and hears the heartbeat", { skip }, async () => {
  const { data, app } = stationData();
  // The launcher's record (run/station.json): a process of the test's in its place, which a SIGUSR2 would end.
  const stand = spawn("/bin/sleep", ["60"], { stdio: "ignore" });
  children.push(stand);
  mkdirSync(join(data, "run"), { recursive: true });
  const a = await launch(data, app, {}, ["--launcher-installer"]);
  await a.next("ready", (m) => m.ready === true);
  writeFileSync(join(data, "run", "station.json"), JSON.stringify({ pid: stand.pid, handoff: 1 }));
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const asked = await ask(door, "/admin-api/station/restart", { body: "{}" });
  assert.equal(asked.status, 202, `${asked.status} ${asked.body}`);
  assert.deepEqual(await a.next("restartFront", (m) => m.restartFront !== undefined), { restartFront: true });
  assert.equal(stand.exitCode === null && stand.signalCode === null, true, "the launcher's process is not signalled");
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

/// A Codex id token naming `email` (its signature not checked here).
const idToken = (email: string) => `${Buffer.from(JSON.stringify({ alg: "none" })).toString("base64url")}.${Buffer.from(JSON.stringify({ email, "https://api.openai.com/auth": { chatgpt_plan_type: "plus", chatgpt_account_id: "acct-1" } })).toString("base64url")}.sig`;
const authJson = (email: string) => JSON.stringify({ OPENAI_API_KEY: null, tokens: { id_token: idToken(email), access_token: "at", refresh_token: "rt", account_id: "acct-1" }, last_refresh: new Date().toISOString() });

/// `codex` as the sign-ins and the machine's logins run it: `login --device-auth` says its page and code, then signs in
/// once `approve` is there; `login status` says how CODEX_HOME's login is.
const fakeCodex = (approve: string, email: string) => `#!/bin/sh
home="\${CODEX_HOME:-$HOME/.codex}"
if [ "$1" = "login" ] && [ "$2" = "--device-auth" ]; then
  echo "Follow these steps to sign in with ChatGPT using device code authorization:"
  echo "1. Open this link in your browser and sign in to your account"
  echo "   https://auth.openai.com/codex/device"
  echo "2. Enter this one-time code (expires in 15 minutes)"
  echo "   ABCD-EFGH1"
  while [ ! -f ${JSON.stringify(approve)} ]; do sleep 0.05; done
  rm -f ${JSON.stringify(approve)}
  mkdir -p "$home"
  printf '%s' '${authJson(email)}' > "$home/auth.json"
  echo "Successfully logged in"
  exit 0
fi
if [ "$1" = "login" ] && [ "$2" = "status" ]; then
  if [ -f "$home/auth.json" ]; then echo "Logged in using ChatGPT"; exit 0; fi
  echo "Not logged in"; exit 1
fi
if [ "$1" = "--version" ]; then echo "codex-cli 0.200.0"; exit 0; fi
exit 0
`;

test("a sign-in for a new profile run by the program's own sign-ins: its page and code in the overview, its end making the profile", { skip }, async () => {
  const { data, app } = stationData();
  const approve = join(fresh("approve"), "approved");
  const path = toolsPath({ codex: fakeCodex(approve, "new@example.com") });
  const a = await launch(data, app, { PATH: path });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const started = await given("POST /logins answered", async () => {
    const r = await ask(door, "/admin-api/logins", { body: JSON.stringify({ runtime: "codex" }) });
    return r.status === 503 ? null : r;
  });
  assert.equal(started.status, 200, started.body);
  const { id } = JSON.parse(started.body);
  assert.match(id, /^login-[0-9a-f]{8}$/);
  const waiting = await given("the sign-in's page and code in the overview", async () => {
    const o = JSON.parse((await ask(door, "/admin-api/overview")).body);
    const l = (o.logins ?? []).find((x: any) => x.id === id);
    return l?.job?.state === "needs_approval" ? l : null;
  });
  assert.equal(waiting.runtime, "codex");
  assert.equal(waiting.job.url, "https://auth.openai.com/codex/device");
  assert.equal(waiting.job.userCode, "ABCD-EFGH1");
  // the person approves on their device: the command ends signed in, and the profile is made of it
  writeFileSync(approve, "");
  const profile = await given("the profile made of the sign-in", () => (readJson(join(data, "config.json"))?.profiles ?? []).find((p: any) => p.runtime === "codex"));
  assert.equal(profile.name, "new@example.com");
  assert.equal(profile.home, `homes/${profile.id}`, "its home kept relative to the data directory");
  assert.ok(existsSync(join(data, profile.home, "auth.json")), "its home the sign-in's, moved");
  const listed = await given("the overview lists it and no sign-in pending", async () => {
    const o = JSON.parse((await ask(door, "/admin-api/overview")).body);
    return (o.profiles ?? []).some((p: any) => p.id === profile.id) && !(o.logins ?? []).some((x: any) => x.id === id && x.created === null) ? o : null;
  });
  assert.ok(listed);

  // a second sign-in, dropped before it ends: its command stopped, its home gone
  const again = JSON.parse((await ask(door, "/admin-api/logins", { body: JSON.stringify({ runtime: "codex" }) })).body);
  await given("the second sign-in waits", async () => (JSON.parse((await ask(door, "/admin-api/overview")).body).logins ?? []).find((x: any) => x.id === again.id)?.job?.state === "needs_approval");
  const dropped = await ask(door, `/admin-api/logins/${again.id}`, { method: "DELETE" });
  assert.equal(dropped.status, 200, dropped.body);
  await given("dropped from the overview", async () => !(JSON.parse((await ask(door, "/admin-api/overview")).body).logins ?? []).some((x: any) => x.id === again.id));
  await given("its home removed", () => !existsSync(join(data, "homes", again.id)));
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("the machine's own logins read, and a profile made on the machine's Codex login", { skip }, async () => {
  const { data, app } = stationData();
  const home = fresh("home");
  mkdirSync(join(home, ".codex"), { recursive: true });
  writeFileSync(join(home, ".codex", "auth.json"), authJson("machine@example.com"));
  const path = toolsPath({ codex: fakeCodex(join(home, "never"), "unused@example.com") });
  const a = await launch(data, app, { PATH: path, HOME: home });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const login = await given("the overview's machine logins", async () => {
    const o = JSON.parse((await ask(door, "/admin-api/overview")).body);
    return (o.machineLogins ?? []).find((l: any) => l.runtime === "codex" && l.loggedIn === true);
  });
  assert.equal(login.email, "machine@example.com");
  assert.equal(login.usable, true);
  const made = await ask(door, "/admin-api/profiles/machine", { body: JSON.stringify({ runtime: "codex" }) });
  assert.equal(made.status, 200, made.body);
  assert.equal(JSON.parse(made.body).id, "machine-codex");
  const profile = (readJson(join(data, "config.json"))?.profiles ?? []).find((p: any) => p.id === "machine-codex");
  assert.equal(profile?.machine, true, JSON.stringify(readJson(join(data, "config.json"))));
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a machine that only runs tasks keeps its own release: `stillfail update --beta` answered by SIGHUP", { skip }, async () => {
  const data = fresh("rig");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9601\n");
  const id = spawnSync(binary!, ["id", "--data", data], { env: { PATH: toolsPath(), HOME: fresh("home") }, encoding: "utf8" }).stdout.trim();
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: "w1", workspace_name: "W", name: "rig", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
    rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) },
  }));
  const a = await launch(data, app, {});
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  assert.equal((await ask(door, "/admin-api/overview")).status, 404, "a rig serves no member");
  writeFileSync(join(data, "run", "channel-ask"), "beta\n");
  a.tell({ op: "hup" });
  const answer = await given("run/channel-answer", () => {
    try {
      return readFileSync(join(data, "run", "channel-answer"), "utf8");
    } catch {
      return null;
    }
  });
  assert.equal(answer, "ok beta\n");
  assert.equal(readJson(join(data, "config.json"))?.updateChannel ?? readJson(join(data, "config.json"))?.channel, "beta", JSON.stringify(readJson(join(data, "config.json"))));
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

/// What the parts said to the station, asked through `STILLFAIL_PARTS_DOOR`'s place (live_p5_3.mbt `/parts/…`).
async function parts(door: number, path: string, body: unknown): Promise<{ status: number; body: any }> {
  const r = await ask(door, `/parts${path}`, { body: JSON.stringify(body) });
  return { status: r.status, body: r.body === "" ? null : JSON.parse(r.body) };
}

test("a session archived keeps its jobs that ended and their logs, and a hand-over's kept sends are kept and given under the thread's id there", { skip }, async () => {
  const { data, app } = stationData();
  const work = fresh("work");
  // (in a workspace: a station in none refuses a job's start)
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "http://127.0.0.1:9", station: "st-here", workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [] }));
  const a = await launch(data, app, { STILLFAIL_PARTS_DOOR: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const over = await parts(door, "/ask/jobs.start", ["s1", "over", "echo done", work, null, false, false]);
    assert.equal(over.status, 200, JSON.stringify(over.body));
    await given("the first job ended", () => {
      const row = store.getJob(over.body.id);
      return row !== null && row.state !== "running";
    });
    const long = await parts(door, "/ask/jobs.start", ["s1", "long", "sleep 30", work, null, false, false]);
    assert.equal(long.status, 200, JSON.stringify(long.body));
    assert.equal((await parts(door, "/ask/jobs.sessionEnded", ["s1"])).status, 200);
    await given("the running job no longer running", () => store.getJob(long.body.id)?.state !== "running");
    assert.equal(store.getJob(over.body.id)?.state, "exited", "the job that ended is still on the session's record");
    assert.equal(store.getJob(long.body.id)?.state, "stopped", "and the one it stopped");
    assert.ok(existsSync(over.body.log), "with its log");
    assert.match(readFileSync(over.body.log, "utf8"), /done/);

    // move/live.ts `keepSends`, then `keptSends` (replica_coord's `w.part`, as the moves ask the admin API on the bus)
    const send = { viewer: "owner", thread: 77, key: "k1", at: 1_000, status: 201, headers: { "content-type": "application/json" }, body: Buffer.from('{"ok":true}').toString("base64") };
    assert.equal((await parts(door, "/peer/$admin.keepSends?from=self", { sends: [send] })).status, 200);
    const kept = await parts(door, "/peer/$admin.keptSends?from=self", { threads: [[77, 5]] });
    assert.equal(kept.status, 200, JSON.stringify(kept.body));
    assert.deepEqual(kept.body, [{ ...send, thread: 5 }]);
    assert.deepEqual((await parts(door, "/peer/$admin.keptSends?from=self", { threads: [[78, 5]] })).body, [], "none of a thread not named");
  } finally {
    store.close();
  }
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});
