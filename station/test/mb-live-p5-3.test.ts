// P5-3 of the station as the MoonBit program composes it (station/mb src/station_main/live_p5_3*.mbt), held through
// the program itself: `stillfail-reader run` under a launcher of the test's, every program run with a PATH that names
// no directory with a Node in it. Its agents' tools through `/mcp` (job_start, job_list, job_log, job_stop and a web
// service's start, preview and stop leaving no process behind; station_list, search), `stillfail-job notify` on the
// agents' door (`/jobs/notify`), and what the station keeps of them (the store's jobs and notices, its config's
// profiles, the agents' memory kept for its workspaces) read back with the TypeScript's own readers.
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { type AddressInfo, createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { createSocket } from "node:dgram";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
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

/// The commands a job of the test runs (and its wrapper: mv), each linked into a directory of its own: what is on the
/// station's PATH, so no Node is.
const TOOLS = ["sh", "mv", "cat", "curl", "sleep", "echo", "printf", "env", "python3", "git", "ls", "find", "sort", "rm", "mkdir", "cp", "dirname", "basename", "sed", "tr", "head", "wc", "uname", "ssh"];
/// Where a command is on this machine: the first of the test's own PATH's directories, then the system's, that has it
/// (no `which`, which a system need not have where the test expects it).
function binOf(name: string): string {
  const dirs = [...(process.env.PATH ?? "").split(":").filter((d) => d !== ""), "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"];
  for (const d of dirs) {
    const at = join(d, name);
    if (existsSync(at)) return at;
  }
  return "";
}
function toolsPath(): string {
  const dir = fresh("path");
  for (const t of TOOLS) {
    const found = binOf(t);
    if (found !== "" && !found.includes("node")) symlinkSync(found, join(dir, t));
  }
  assert.equal(existsSync(join(dir, "node")), false);
  return dir;
}

/// An environment with no Node: a PATH of its own with only TOOLS, HOME and TMPDIR as given.
const noNode = (more: Record<string, string> = {}) => ({ PATH: toolsPath(), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), ...more });

type Launched = { child: ChildProcess; said: any[]; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe.
async function launch(data: string, app: string, env: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", ...env }),
  });
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  createInterface({ input: (child.stdio as readonly unknown[])[5] as import("node:net").Socket }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, ok: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said: ${what}; said ${JSON.stringify(said)}; stderr ${err}`)), 15_000);
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
  const channel = (child.stdio as readonly unknown[])[5] as import("node:net").Socket;
  return { child, said, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

function http(port: number, path: string, o: { method?: string; body?: string; headers?: Record<string, string> } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json", ...(o.headers ?? {}) } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

/// An MCP call of the agents' door, as session `token`'s agent.
async function mcp(port: number, token: string, method: string, params: unknown = {}): Promise<any> {
  const r = await http(port, "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }), headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body);
  return JSON.parse(r.body);
}

/// A tool's text, as its agent reads it.
async function tool(port: number, token: string, name: string, args: unknown = {}): Promise<{ text: string; error: boolean }> {
  const said = await mcp(port, token, "tools/call", { name, arguments: args });
  assert.equal(said.error, undefined, JSON.stringify(said));
  return { text: said.result.content[0].text, error: said.result.isError === true };
}

/// What comes true within `ms` (a real process's end, which nothing here can be told of).
async function within<T>(what: string, ms: number, look: () => Promise<T | null> | T | null): Promise<T> {
  const until = Date.now() + ms;
  for (;;) {
    const got = await look();
    if (got !== null) return got;
    if (Date.now() > until) throw new Error(`not within ${ms} ms: ${what}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

const alive = (pid: number, group = false) => {
  try {
    process.kill(group ? -pid : pid, 0);
    return true;
  } catch {
    return false;
  }
};

const freePort = () => new Promise<number>((resolve) => {
  const s = createServer();
  s.listen(0, "127.0.0.1", () => {
    const port = (s.address() as AddressInfo).port;
    s.close(() => resolve(port));
  });
});

const python = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"].find((p) => existsSync(p) && spawnSync(p, ["-c", "import http.server"]).status === 0) ?? null;

test("jobs: job_start, stillfail-job notify, job_list, job_log, job_stop and a web service through the agents' door, under a PATH with no Node", { skip }, async () => {
  const data = fresh("p53");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  // (in a workspace: a station in none refuses what goes out of it, a job's start too)
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "http://127.0.0.1:9", station: "st-here", workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [] }));
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    store.insertSession({ key: "s2", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t2", createdAt: Date.now(), lastActiveAt: Date.now() });

    const names = (await mcp(door, "t1", "tools/list")).result.tools.map((t: any) => t.name);
    for (const n of ["job_start", "job_list", "job_log", "job_stop"]) assert.ok(names.includes(n), `${n} in ${names}`);
    assert.equal((await tool(door, "t1", "job_list")).text, "No jobs.");

    // A job: its output in its log, a word on the way told through the agents' door, its end taken in.
    const started = await tool(door, "t1", "job_start", {
      name: "greet",
      command: `echo hello; stillfail-job notify half way there; echo "$STILLFAIL_JOB_ID" > id.txt; echo done`,
    });
    assert.equal(started.error, false, started.text);
    const job = JSON.parse(started.text);
    assert.equal(job.session, "s1");
    assert.equal(job.name, "greet");
    assert.equal(job.cwd, work);
    assert.match(job.id, /^job_[0-9a-f]{8}$/);
    const ended = await within("the job ended", 15_000, () => {
      const row = store.getJob(job.id);
      return row !== null && row.state !== "running" ? row : null;
    });
    assert.equal(ended.state, "exited");
    assert.equal(ended.exitCode, 0);
    assert.equal(readFileSync(join(work, "id.txt"), "utf8").trim(), job.id, "its id in its environment, run where its session works");
    assert.deepEqual(store.jobNotices(job.id, 5).map((n) => n.text), ["half way there"], "stillfail-job notify reached /jobs/notify");
    assert.equal((await tool(door, "t1", "job_log", { id: job.id })).text, "hello\ndone");
    assert.equal((await tool(door, "t1", "job_log", { id: job.id, lines: 1 })).text, "done");
    const listed = JSON.parse((await tool(door, "t1", "job_list")).text);
    assert.deepEqual(listed.map((j: any) => [j.id, j.state, j.exitCode]), [[job.id, "exited", 0]]);
    // another session's job is not this one's
    const theirs = await tool(door, "t2", "job_log", { id: job.id });
    assert.equal(theirs.error, true);
    assert.equal(theirs.text, `job ${job.id} is another session's`);
    // /jobs/notify with no job's token is refused
    const refused = await http(door, "/jobs/notify", { body: "words", headers: { authorization: "Bearer nobody", "content-type": "text/plain" } });
    assert.deepEqual([refused.status, JSON.parse(refused.body)], [400, { error: "unknown job token" }]);
    // a start's checks
    assert.equal((await tool(door, "t1", "job_start", { command: "  " })).text, "command is empty");
    assert.equal((await tool(door, "t1", "job_start", { command: "true", cwd: "nowhere" })).text, `no such directory: ${join(work, "nowhere")}`);
    assert.equal((await tool(door, "t1", "job_start", { command: "true", port: 80 })).text, "a service's port is 1024 or above");

    // A job stopped while it runs: its whole group ended.
    const long = JSON.parse((await tool(door, "t1", "job_start", { name: "sleeper", command: "sleep 600 & sleep 600; wait" })).text);
    const pgid = await within("its group recorded", 5_000, () => store.getJob(long.id)?.pgid ?? null);
    assert.ok(alive(pgid, true));
    assert.equal((await tool(door, "t1", "job_stop", { id: long.id })).text, `Job "sleeper" (${long.id}) is stopped.`);
    await within("its group ended", 10_000, () => (alive(pgid, true) ? null : true));
    assert.equal(store.getJob(long.id)!.state, "stopped");

    // A web service: given PORT, ready once its port answers, seen through its preview's path, stopped leaving nothing.
    if (python !== null) {
      const port = await freePort();
      writeFileSync(join(work, "index.html"), "<h1>served here</h1>\n");
      const svc = JSON.parse((await tool(door, "t1", "job_start", { name: "site", command: `exec ${python} -m http.server "$PORT" --bind 127.0.0.1`, port })).text);
      assert.equal(svc.port, port);
      const up = await within("the service answers", 15_000, async () => {
        const v = JSON.parse((await tool(door, "t1", "job_list")).text).find((j: any) => j.id === svc.id);
        return v?.ready === true ? v : null;
      });
      assert.equal(up.state, "running");
      const page = await http(door, `/preview/${port}/index.html`);
      assert.equal(page.status, 200);
      assert.equal(page.body, "<h1>served here</h1>\n");
      const taken = await tool(door, "t1", "job_start", { command: "true", port });
      assert.equal(taken.text, `port ${port} is Service "site" (${svc.id}, port ${port})'s already`);
      const servicePgid = store.getJob(svc.id)!.pgid!;
      assert.equal((await tool(door, "t1", "job_stop", { id: svc.id })).text, `Service "site" (${svc.id}, port ${port}) is stopped.`);
      await within("the service's group ended", 10_000, () => (alive(servicePgid, true) ? null : true));
      assert.equal((await http(door, `/preview/${port}/`)).status >= 500, true, "nothing listens there any more");
    }
  } finally {
    store.close();
  }
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
  assert.equal(alive(a.child.pid!), false);
});

/// What the parts said to the station (StationParts, LiveBus), asked through the place a station run alone opens for a
/// program of this machine (`STILLFAIL_PARTS_DOOR`): a route of the admin API, `jobs_ask`, an overview's field, a
/// peer's request as the mesh hands it.
async function parts(door: number, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  const r = await http(door, `/parts${path}`, { method, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  return { status: r.status, body: r.body === "" ? null : JSON.parse(r.body) };
}

test("resources, accounts, search, the memory and the shares: on StationParts and the LiveBus of `stillfail-reader run`, under a PATH with no Node", { skip }, async () => {
  const data = fresh("p53b");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9501\n");
  mkdirSync(join(data, "mesh"), { recursive: true });
  // (the workspace's roster as the control plane gives it: this station among its stations)
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "http://127.0.0.1:9", station: "st-here", workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [{ id: "st-here", name: "here" }], revocations: [] }));
  const profiles = [
    { id: "sub", name: "Claude", home: "homes/sub", runtime: "claude", access: { kind: "subscription" } },
    { id: "key", name: "Go", home: "homes/key", access: { kind: "opencode-go", key: "sk-own" } },
  ];
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles }));
  mkdirSync(join(data, "agent"), { recursive: true });
  writeFileSync(join(data, "agent", "MEMORY.md"), "- one rule a line\n");
  // (a home of its own: the machine's files a search walks)
  const home = fresh("home");
  mkdirSync(join(home, "notes"), { recursive: true });
  writeFileSync(join(home, "notes", "zqxfilename.txt"), "nothing here\n");
  writeFileSync(join(home, "notes", "plain.md"), "a line with zqxcontent in it\n");
  writeFileSync(join(home, "notes", "big.bin"), "zqxcontent\n");
  // (what the upkeep holds to its bounds: old copies of the config, a half-done download, a reading of a transcript gone)
  for (let i = 0; i < 5; i++) {
    writeFileSync(join(data, `config.json.bak-${i}`), "{}");
    utimesSync(join(data, `config.json.bak-${i}`), new Date(Date.now() - (10 - i) * 60_000), new Date(Date.now() - (10 - i) * 60_000));
  }
  mkdirSync(join(data, "node"), { recursive: true });
  writeFileSync(join(data, "node", ".part-1"), "half");
  utimesSync(join(data, "node", ".part-1"), new Date(Date.now() - 2 * 86_400_000), new Date(Date.now() - 2 * 86_400_000));
  mkdirSync(join(data, "transcript-marks"), { recursive: true });
  writeFileSync(join(data, "transcript-marks", "gone.json"), JSON.stringify({ state: { path: join(data, "nowhere.jsonl") } }));
  writeFileSync(join(data, "transcript-marks", "kept.json"), JSON.stringify({ state: { path: join(data, "config.json") } }));
  const a = await launch(data, app, { STILLFAIL_PARTS_DOOR: "1", HOME: home });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "sub", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });

    // ── Accounts: config.json's profiles read, the view of them, its every change checked ──
    const viewed = await within("the accounts made", 15_000, async () => {
      const r = await parts(door, "GET", "/route/profiles");
      return r.status === 200 ? r.body : null;
    });
    const ids = JSON.stringify(viewed);
    for (const id of ["sub", "key"]) assert.ok(ids.includes(`"${id}"`), `${id} in ${ids}`);
    assert.ok(!ids.includes("sk-own"), "a profile's key is never shown");
    const refused = await parts(door, "POST", "/ask/config.put", { profiles, tools: { access: "nope" } });
    assert.equal(refused.status, 400);
    assert.match(refused.body.error, /tools\.access/);
    assert.deepEqual(JSON.parse(readFileSync(join(data, "config.json"), "utf8")).profiles, profiles, "what the check refused is not written");
    const state = await parts(door, "POST", "/ask/accounts.state");
    assert.equal(state.status, 200);
    assert.equal(typeof state.body, "object");

    // ── Resources: the machine, and a chat's job's processes put to its chat ──
    const machine = await parts(door, "GET", "/overview/machine");
    assert.equal(machine.status, 200);
    assert.ok(machine.body.cpus > 0 && machine.body.totalmem > 0, JSON.stringify(machine.body));
    assert.equal(machine.body.station.pid, a.child.pid);
    const sleeper = JSON.parse((await tool(door, "t1", "job_start", { name: "uniquesleeper", command: "sleep 30" })).text);
    const looked = await parts(door, "GET", "/route/resources");
    assert.equal(looked.status, 200);
    assert.equal(looked.body.everyMs, 5000);
    if (process.platform === "darwin") {
      assert.equal(looked.body.counted, true, JSON.stringify(looked.body));
      const chat = looked.body.groups.find((g: any) => g.key === "chat:s1");
      assert.ok(chat, JSON.stringify(looked.body.groups.map((g: any) => g.key)));
      assert.ok(chat.processes.some((p: any) => p.name === "sleep" && p.endable === true), JSON.stringify(chat.processes));
      assert.ok(looked.body.groups.some((g: any) => g.key === "station"));
    }

    // ── Search: the jobs table looked through by `--builder search`, through the agents' tool ──
    const found = await tool(door, "t1", "search", { query: "uniquesleeper", kinds: ["job"] });
    assert.equal(found.error, false, found.text);
    assert.match(found.text, /^Search for "uniquesleeper":/);
    assert.ok(found.text.includes(sleeper.id), found.text);
    assert.equal((await tool(door, "t1", "job_stop", { id: sleeper.id })).error, false);
    // the machine's files: walked from the home, by a name or by what a text says (a file not a text's kind not read)
    const files = await tool(door, "t1", "search", { query: "zqxfilename", kinds: ["file"] });
    assert.ok(files.text.includes(join(home, "notes", "zqxfilename.txt")), files.text);
    const said = await tool(door, "t1", "search", { query: "zqxcontent", kinds: ["file"] });
    assert.ok(said.text.includes(join(home, "notes", "plain.md")), said.text);
    assert.equal(said.text.includes("big.bin"), false, said.text);
    // the network's counters each look, and the station's own memory sampled
    assert.equal((await parts(door, "GET", "/route/resources")).body.net, true);
    const mem = await parts(door, "POST", "/ask/memory.sample");
    assert.equal(mem.status, 200, JSON.stringify(mem.body));
    assert.ok(mem.body.wholeRssMb > 0, JSON.stringify(mem.body));
    // the upkeep's round
    const kept = await parts(door, "POST", "/ask/upkeep");
    assert.equal(kept.status, 200, JSON.stringify(kept.body));
    assert.deepEqual(readdirSync(data).filter((n) => n.startsWith("config.json.bak-")).sort(), ["config.json.bak-2", "config.json.bak-3", "config.json.bak-4"]);
    assert.equal(existsSync(join(data, "node", ".part-1")), false);
    assert.deepEqual(readdirSync(join(data, "transcript-marks")), ["kept.json"]);

    // ── Remote: station_list, this station from its load ──
    const listed = JSON.parse((await tool(door, "t1", "station_list")).text);
    const here = (listed.stations ?? []).find((s: any) => s.here === true);
    assert.ok(here, JSON.stringify(listed));
    assert.equal(here.id, "st-here");
    assert.equal(here.version, "0.1.9501");
    const nokey = await tool(door, "t1", "station_task", { station: "st-other", action: "start" });
    assert.equal(nokey.text, "station and key are required (list, mirrors and clean need only station)");

    // ── Remote: a task asked of a station over the peers' bus (here this one itself, the mesh's transport being
    // P5-1's): prepared, its input uploaded, started through the queue as a job of its own, read back, its output
    // downloaded into the session's workspace ──
    writeFileSync(join(work, "in.txt"), "input here\n");
    const prep = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "k1", action: "prepare", name: "rt", command: "cat in.txt; echo made > out.txt" })).text);
    assert.deepEqual(prep, { key: "k1", prepared: true });
    const up = await tool(door, "t1", "station_file", { station: "self", key: "k1", direction: "upload", path: "in.txt", local: "in.txt" });
    assert.equal(up.error, false, up.text);
    const begun = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "k1", action: "start" })).text);
    assert.equal(begun.key, "k1");
    assert.match(begun.job.id, /^remote_[0-9a-f]+$/);
    assert.equal(begun.push, true);
    const got = await within("the task ended", 15_000, async () => {
      const g = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "k1", action: "get" })).text);
      return g.job?.state === "exited" ? g : null;
    });
    assert.equal(got.job.exitCode, 0);
    assert.equal(got.log, "input here");
    assert.equal(got.job.session.startsWith("remote:w1:"), true, got.job.session);
    const again = await tool(door, "t1", "station_task", { station: "self", key: "k1", action: "prepare", name: "rt", command: "something else" });
    assert.equal(again.text, "task key already used with different inputs; choose a new key for new work");
    const listedTasks = JSON.parse((await tool(door, "t1", "station_task", { station: "self", action: "list" })).text);
    assert.deepEqual(listedTasks.tasks.map((t: any) => [t.key, t.job.state]), [["k1", "exited"]]);
    const down = await tool(door, "t1", "station_file", { station: "self", key: "k1", direction: "download", path: "out.txt", local: "back/out.txt" });
    assert.equal(down.error, false, down.text);
    assert.equal(readFileSync(join(work, "back", "out.txt"), "utf8"), "made\n");

    // ── Remote with a directory: a Git repository with a local submodule synced to a mirror there (the sessions'
    // program's dirsync, its submodules too), the task run in it, the mirrors listed, one cleaned ──
    const git = (cwd: string, ...args: string[]) => {
      const r = spawnSync("git", ["-c", "user.email=t@t", "-c", "user.name=t", "-c", "protocol.file.allow=always", ...args], { cwd, encoding: "utf8" });
      assert.equal(r.status, 0, `git ${args.join(" ")}: ${r.stderr}`);
      return r.stdout;
    };
    const repos = fresh("repos");
    const sub = join(repos, "sub");
    const main = join(repos, "main");
    mkdirSync(sub);
    mkdirSync(main);
    git(sub, "init", "-q");
    writeFileSync(join(sub, "s.txt"), "from the submodule\n");
    git(sub, "add", ".");
    git(sub, "commit", "-qm", "sub");
    git(main, "init", "-q");
    writeFileSync(join(main, "m.txt"), "from the repository\n");
    git(main, "add", ".");
    git(main, "commit", "-qm", "main");
    git(main, "submodule", "add", "-q", sub, "sub");
    git(main, "commit", "-qm", "with its submodule");
    writeFileSync(join(main, "untracked.txt"), "added but not committed\n");
    const dprep = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "d1", action: "prepare", name: "in dir", command: "cat m.txt untracked.txt sub/s.txt", dir: main })).text);
    assert.equal(dprep.prepared, true, JSON.stringify(dprep));
    assert.equal(typeof dprep.dir, "string");
    const dstart = await within("the directory synced and the task started", 30_000, async () => {
      const r = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "d1", action: "start" })).text);
      return r.syncing === true ? null : r;
    });
    assert.match(dstart.job?.id ?? "", /^remote_/, JSON.stringify(dstart));
    const dgot = await within("the task in the mirror ended", 30_000, async () => {
      const g = JSON.parse((await tool(door, "t1", "station_task", { station: "self", key: "d1", action: "get" })).text);
      return g.job?.state === "exited" || g.job?.state === "failed" ? g : null;
    });
    assert.equal(dgot.job.exitCode, 0, dgot.log);
    // (the submodule checked out in the mirror first: dirsync.mbt `with_submodules`, #7015)
    assert.match(dgot.log, /^still\.fail: submodule sub checked out at [0-9a-f]{40}\n/);
    assert.equal(dgot.log.split("\n").slice(1).join("\n"), "from the repository\nadded but not committed\nfrom the submodule");
    // (its results brought back by the station that asked, which follows it: then its mirror is no task's)
    const mirrors = await within("the task's results taken and its mirror let go", 30_000, async () => {
      const m = JSON.parse((await tool(door, "t1", "station_task", { station: "self", action: "mirrors" })).text).mirrors;
      return m.length === 1 && m[0].busy === false ? m : null;
    });
    assert.equal(mirrors.length, 1, JSON.stringify(mirrors));
    assert.equal(existsSync(join(mirrors[0].path, "sub", "s.txt")), true);
    const cleaned = JSON.parse((await tool(door, "t1", "station_task", { station: "self", action: "clean", mirror: mirrors[0].name })).text);
    assert.deepEqual(cleaned, { mirror: mirrors[0].name, removed: true });
    assert.equal(existsSync(mirrors[0].path), false);
    assert.deepEqual(JSON.parse((await tool(door, "t1", "station_task", { station: "self", action: "mirrors" })).text).mirrors, []);

    // ── MemorySync: the workspace's memory read and kept (blobs by hash), answered to a peer of the workspace ──
    assert.equal((await parts(door, "POST", "/ask/memory.level")).status, 200);
    const keptMemory = await within("the memory kept", 15_000, async () => {
      const r = await parts(door, "POST", "/ask/memory.kept", { workspace: "w1" });
      return r.status === 200 && r.body !== null && JSON.stringify(r.body).includes("MEMORY.md") ? r.body : null;
    });
    assert.ok(keptMemory.clock >= 1, JSON.stringify(keptMemory));
    const asked = await parts(door, "POST", "/peer/memory.get?from=st-other", { method: "memory.get" });
    assert.equal(asked.status, 200, JSON.stringify(asked.body));
    assert.ok(JSON.stringify(asked.body).includes("MEMORY.md"), JSON.stringify(asked.body));

    // ── Sharing and the chats shared: on the bus, what a peer asks reaching them ──
    const shares = await parts(door, "POST", "/ask/share.state");
    assert.equal(shares.status, 200);
    assert.ok(shares.body.sharing !== null && shares.body.xshare !== null, JSON.stringify(shares.body));
    const lend = await parts(door, "POST", "/peer/share.status?from=st-other", { method: "share.status", id: "nothing-shared" });
    assert.notEqual(lend.body?.error, "unknown peer method: share.status", "share.* reaches the shared profiles");
    assert.equal((await parts(door, "POST", "/ask/xshare.reaches", { target: "st-far", workspace: "w9" })).body, false);
  } finally {
    store.close();
  }
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
});

/// A stand-in `ssh` in `dir` (side/sandbox.test.ts `fakeSsh`, as sh): to the front door (`_…`) it answers as l4es does
/// a `create`, writing the command to `<dir>/made`; to a sandbox it runs the remote command as sshd would, on this
/// machine with a Node of its own (a sandbox's: the station's PATH has none), its runtime directory and its files the
/// destination's own (STILLFAIL_SANDBOX_PREFIX), writing the destination to `<dir>/destinations`.
function fakeSsh(dir: string): void {
  const program = join(dir, "ssh");
  writeFileSync(
    program,
    `#!/bin/sh
dest=""; cmd=""
for a in "$@"; do
  if [ -n "$dest" ]; then cmd="$cmd\${cmd:+ }$a"; continue; fi
  case "$a" in *@*) dest="$a";; esac
done
case "$dest" in _*) echo "$dest $cmd" >> "${dir}/made"; exit 0;; esac
echo "$dest" >> "${dir}/destinations"
own="${dir}/run-$dest"
mkdir -p "$own"
export XDG_RUNTIME_DIR="$own" STILLFAIL_SANDBOX_PREFIX="$own/fs" PATH="${join(process.execPath, "..")}:/usr/bin:/bin"
exec /bin/sh -c "$cmd"
`,
  );
  chmodSync(program, 0o755);
  const keygen = binOf("ssh-keygen");
  if (keygen !== "") symlinkSync(keygen, join(dir, "ssh-keygen"));
}

/// The program's id of a data directory (`stillfail-reader id`): its key made there.
function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

/// A UDP port free on 127.0.0.1 (a station's mesh bound there).
const freeUdpPort = () => new Promise<number>((resolve) => {
  const s = createSocket("udp4");
  s.bind(0, "127.0.0.1", () => {
    const port = s.address().port;
    s.close(() => resolve(port));
  });
});

test("a task another station refuses: its words told the agent as that station said them, over the mesh", { skip }, async () => {
  const [dataA, dataB] = [fresh("p53ra"), fresh("p53rb")];
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9503\n");
  const [idA, idB] = [stationId(dataA), stationId(dataB)];
  const [portA, portB] = [await freeUdpPort(), await freeUdpPort()];
  const peers = [{ id: idA, name: "alpha", ips: [`127.0.0.1:${portA}`] }, { id: idB, name: "beta", ips: [`127.0.0.1:${portB}`] }];
  for (const [data, id, name] of [[dataA, idA, "alpha"], [dataB, idB, "beta"]] as const) {
    mkdirSync(join(data, "mesh"), { recursive: true });
    writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "http://127.0.0.1:9", station: id, workspace: "w1", workspace_name: "W", name, relay_url: "", relay_urls: [], grant_keys: null, peers, revocations: [] }));
  }
  const env = (port: number) => ({ STILLFAIL_NO_DISCOVERY: "1", STILLFAIL_MESH_BIND_ADDR: `127.0.0.1:${port}` });
  const [a, b] = [await launch(dataA, app, env(portA)), await launch(dataB, app, env(portB))];
  await a.next("ready", (m) => m.ready === true);
  await b.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;
  const store = Store.open(join(dataA, "stillfail.db"), join(dataA, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const task = { station: idB, key: "k1", action: "prepare", name: "rt" };
    await within("beta prepared the task", 30_000, async () => {
      const r = await tool(door, "t1", "station_task", { ...task, command: "echo one" });
      return r.error ? null : r;
    });
    // The same key for other work: beta refuses it, and says why; the agent is told those words, not the error's name.
    const refused = await tool(door, "t1", "station_task", { ...task, command: "echo two" });
    assert.equal(refused.error, true, refused.text);
    assert.match(refused.text, /task key already used with different inputs; choose a new key for new work/);
    assert.doesNotMatch(refused.text, /PeerRefused|mesh_door/);
  } finally {
    store.close();
  }
  for (const s of [a, b]) s.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
  assert.equal(await b.ended, 0, b.err());
});

test("a sandbox's task through the program's own bridge, skill_read and skill.read, workspace_limit, and jobs_ask as the other slices ask it: under a PATH with no Node", { skip }, async () => {
  const data = fresh("p53c");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9502\n");
  // the bridge where a release puts it (package.json `build`: beside the program in <app>/station/), wherever the
  // program the test runs was built
  mkdirSync(join(app, "station"), { recursive: true });
  copyFileSync(fileURLToPath(new URL("../src/agents/sandbox-bridge.mjs", import.meta.url)), join(app, "station", "sandbox-bridge.mjs"));
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({ origin: "http://127.0.0.1:9", station: "st-here", workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: null, peers: [], revocations: [] }));
  writeFileSync(join(data, "config.json"), JSON.stringify({ profiles: [], sandboxes: [{ name: "box", target: "{name}.ws@host", size: "large" }] }));
  // (a skill of the workspace's agents, with a file of its own)
  mkdirSync(join(data, "agent", "skills", "demo"), { recursive: true });
  writeFileSync(join(data, "agent", "skills", "demo", "SKILL.md"), "---\nname: demo\ndescription: a demo skill\n---\nthe demo's words\n");
  writeFileSync(join(data, "agent", "skills", "demo", "more.md"), "more words\n");
  const fake = fresh("ssh");
  fakeSsh(fake);
  const a = await launch(data, app, { STILLFAIL_PARTS_DOOR: "1", PATH: `${fake}:${noNode().PATH}` });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("mcp", (m) => m.serving === "mcp")).port as number;
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);
  try {
    store.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
    const names = (await mcp(door, "t1", "tools/list")).result.tools.map((t: any) => t.name);
    for (const n of ["skill_read", "workspace_limit"]) assert.ok(names.includes(n), `${n} in ${names}`);

    // ── skill_read: this station's catalog, a file of the skill, one not there said so ──
    const read = await tool(door, "t1", "skill_read", { name: "demo" });
    assert.equal(read.error, false, read.text);
    assert.match(read.text, /^Skill "demo", file "SKILL.md"\nAvailable files: "SKILL.md", "more.md"\n\n/);
    assert.ok(read.text.includes("the demo's words"), read.text);
    assert.match((await tool(door, "t1", "skill_read", { name: "demo", file: "more.md" })).text, /more words/);
    const none = await tool(door, "t1", "skill_read", { name: "nothing" });
    assert.deepEqual(none, { text: 'No skill "nothing" in this workspace on this station', error: true });
    assert.equal((await tool(door, "t1", "skill_read", { name: "demo", station: "nowhere" })).text, "No such station in this workspace");
    // another station of the workspace reading it here (`skill.read` on the peers' bus)
    const peer = await parts(door, "POST", "/peer/skill.read?from=st-other", { method: "skill.read", name: "demo", file: "more.md" });
    assert.equal(peer.status, 200, JSON.stringify(peer.body));
    assert.match(peer.body.text, /^Skill "demo", file "more.md"/);

    // ── workspace_limit: read, set, refused where the chat has used no remote workspace ──
    assert.deepEqual(JSON.parse((await tool(door, "t1", "workspace_limit", {})).text), { station: "this station", limit_gib: 10 });
    assert.deepEqual(JSON.parse((await tool(door, "t1", "workspace_limit", { limit_gib: 3 })).text), { station: "this station", limit_gib: 3 });
    assert.deepEqual(await tool(door, "t1", "workspace_limit", { station: "st-other" }), { text: "this chat has no remote workspace on that station", error: true });
    assert.equal((await parts(door, "POST", "/ask/workspaceWatch.limit", ["s1", ""])).body, 3 * 1024 ** 3);

    // ── describe: how busy, the CPUs over the last while and the GPUs (as station_list says this one) ──
    const described = await parts(door, "POST", "/ask/remote.describe", { workspace: "w1" });
    assert.equal(described.status, 200, JSON.stringify(described.body));
    assert.equal(described.body.sessions, true);
    assert.ok("gpus" in described.body.load, JSON.stringify(described.body.load));
    const busy = await within("the CPUs' busy share", 10_000, async () => (await parts(door, "POST", "/ask/remote.describe", { workspace: "w1" })).body.load.cpuBusy ?? null);
    assert.ok(busy.share >= 0 && busy.share <= 1, JSON.stringify(busy));

    // ── a sandbox: listed, its task's directory copied there, run there by the far side's own Node, what it brings
    // back here; the station's side of the bridge being this program (`<…>/sandbox-bridge.mjs host '<json>'`) ──
    const listed = JSON.parse((await tool(door, "t1", "station_list")).text);
    assert.ok(listed.stations.some((s: any) => s.id === "sandbox:box" && s.kind === "sandbox"), JSON.stringify(listed));
    const src = join(work, "src");
    mkdirSync(src);
    writeFileSync(join(src, "a.txt"), "from here\n");
    const task = { station: "box", key: "k1" };
    const prep = await tool(door, "t1", "station_task", { ...task, action: "prepare", command: "cat a.txt > out.txt; echo built", dir: src, back: ["out.txt"] });
    assert.equal(prep.error, false, prep.text);
    await within("the sandbox's task started", 30_000, async () => {
      const r = JSON.parse((await tool(door, "t1", "station_task", { ...task, action: "start" })).text);
      return r.syncing === true ? null : r;
    });
    const got = await within("the sandbox's task ended", 60_000, async () => {
      const g = JSON.parse((await tool(door, "t1", "station_task", { ...task, action: "get" })).text);
      return g.job?.state === "exited" || g.job?.state === "failed" ? g : null;
    });
    assert.equal(got.job.exitCode, 0, JSON.stringify(got));
    assert.match(got.log, /built/);
    const made = readFileSync(join(fake, "made"), "utf8");
    assert.match(made, /^_\.ws@host create \S+ --size large$/m);
    assert.ok(readFileSync(join(fake, "destinations"), "utf8").trim().split("\n").every((d) => d.endsWith(".ws@host") && !d.startsWith("_")));
    const back = join(work, "station-back", "k1", "out.txt");
    await within("its results here", 30_000, () => (existsSync(back) ? true : null)).catch((e) => {
      throw new Error(`${e.message}; the job ${JSON.stringify(got.job)}; its cwd ${existsSync(got.job.cwd) ? readdirSync(got.job.cwd) : "gone"}; its log ${readFileSync(got.job.log, "utf8")}; the work ${readdirSync(work)}`);
    });
    assert.equal(readFileSync(back, "utf8"), "from here\n");

    // ── jobs_ask as the agents' tools and the admin API ask it (their arguments in order) and a rig's main (an object) ──
    const started = await parts(door, "POST", "/ask/jobs.start", ["s1", "named", "sleep 30", work, null, false, false]);
    assert.equal(started.status, 200, JSON.stringify(started.body));
    const listedJobs = await parts(door, "POST", "/ask/jobs.store.listJobs", ["s1"]);
    assert.ok(listedJobs.body.some((j: any) => j.id === started.body.id), JSON.stringify(listedJobs.body));
    assert.equal((await parts(door, "POST", "/ask/jobs/jobs.named", [started.body])).body, `Job "named" (${started.body.id})`);
    assert.equal((await parts(door, "POST", "/ask/jobs.workspace", ["s1"])).body, work);
    assert.deepEqual((await parts(door, "POST", "/ask/searchDeps.workspaceOf", ["s1"])).body, { workspace: "w1", home: true });
    assert.match((await parts(door, "POST", "/ask/searchDeps.readSkill", [null, "demo", "more.md"])).body, /more words/);
    const up = (await parts(door, "POST", "/ask/jobs.upIn", [["s1"]])).body;
    assert.deepEqual(up.map((j: any) => [j.session, j.name]), [["s1", "named"]]);
    const stopped = await parts(door, "POST", "/ask/stopAll", { why: "the rig is in no workspace" });
    assert.equal(stopped.status, 200, JSON.stringify(stopped.body));
    assert.ok(stopped.body.includes(started.body.id), JSON.stringify(stopped.body));
    assert.match(readFileSync(started.body.log, "utf8"), /\[still\.fail\] stopped: the rig is in no workspace/);
    assert.equal((await parts(door, "POST", "/ask/setNotifyUrl", { url: "http://127.0.0.1:1/jobs/notify" })).status, 200);
  } finally {
    store.close();
  }
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0);
});
