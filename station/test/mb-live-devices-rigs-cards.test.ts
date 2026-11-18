// What the devices, the rigs and the vault ask of one another as the MoonBit program runs the station (station/mb
// src/station_main live_p5_1_rigs.mbt, live_p5_2_*.mbt, live_p5_4*.mbt), in `run` under a launcher of the test's with no
// Node on its PATH: where an accepted socket comes from (`net.remotePort`, what the adb door and a chat's adb server
// tell who asks by); a chat's station_use card posted in its chat, denied by the rig's person, closed and restated
// with its outcome by the cards' outbox worker (agents.ts `cardOutcomes`) and told on the event stream; and a station
// that only runs tasks running a command another station sends with a secret (rig/main.ts `Incoming`, `vault.`).
import assert from "node:assert/strict";
import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createConnection, createServer, type Server } from "node:net";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { DatabaseSync } from "node:sqlite";
import { after, test } from "node:test";
import { mbReaderBinary } from "../src/read/mb-reader.ts";
import { Store } from "../src/store/store.ts";

const binary = mbReaderBinary();
const skip = binary === null ? "the MoonBit program (stillfail-reader) is not built here" : process.platform === "win32" ? "the launcher's descriptors are Unix's" : false;

const dirs: string[] = [];
// (short: a Unix socket's path is at most 104 bytes on macOS)
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sfd-${what}-`));
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

const TOKEN = "devices-rigs-cards";

/// An environment with no Node: an empty PATH of its own, HOME and TMPDIR as given, the test's doors opened.
const noNode = (more: Record<string, string> = {}) => ({ PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), STILLFAIL_TEST_UI_ASK: TOKEN, ...more });

type Launched = { child: ChildProcess; next: (what: string, ok: (m: any) => boolean) => Promise<any>; tell: (m: unknown) => void; ended: Promise<number | null>; err: () => string };

/// The program's `run` with the launcher's descriptors (ops/launcher.ts), its control channel the fourth's pipe.
async function launch(data: string, app: string, more: Record<string, string> = {}): Promise<Launched> {
  const listener = () => new Promise<Server>((resolve) => {
    const s = createServer();
    s.listen(0, "127.0.0.1", () => resolve(s));
  });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(binary!, ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"], {
    stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
    env: noNode({ STILLFAIL_HELD_EVERY_MS: "300", STILLFAIL_NO_DISCOVERY: "1", ...more }),
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
  return { child, next, tell: (m) => channel.write(`${JSON.stringify(m)}\n`), ended, err: () => err };
}

/// What `f` comes to as the program goes on: there within `ms`, or the test fails saying what it waited for.
async function given<T>(what: string, f: () => T | null | undefined | false | Promise<T | null | undefined | false>, ms = 20_000): Promise<T> {
  const until = Date.now() + ms;
  let last: unknown = null;
  for (;;) {
    try {
      const v = await f();
      if (v !== null && v !== undefined && v !== false) return v as T;
    } catch (e) {
      last = e;
    }
    if (Date.now() > until) throw new Error(`never came: ${what}${last ? ` (${(last as Error).message})` : ""}`);
    await new Promise((r) => setTimeout(r, 50));
  }
}

function http(port: number, path: string, o: { method?: string; body?: string; headers?: Record<string, string> } = {}): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method: o.method ?? (o.body === undefined ? "GET" : "POST"), headers: { "content-type": "application/json", ...o.headers } }, (res) => {
      let text = "";
      res.on("data", (d) => (text += d));
      res.on("end", () => resolve({ status: res.statusCode!, body: text }));
    });
    req.on("error", reject);
    req.end(o.body);
  });
}

/// What the parts answer by name, through the test's door (`ui_ask`).
async function uiAsk(port: number, op: string, args: unknown[] = []): Promise<{ answer?: any; error?: any; kind?: string }> {
  const got = await http(port, "/ui-ask/", { body: JSON.stringify({ op, args }), headers: { authorization: `Bearer ${TOKEN}` } });
  return JSON.parse(got.body);
}

/// A tool of the agents' door, as the session whose bearer `token` is calls it: its text.
async function tool(port: number, token: string, name: string, args: unknown): Promise<{ text: string; error: boolean }> {
  const r = await http(port, "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }), headers: { authorization: `Bearer ${token}` } });
  assert.equal(r.status, 200, r.body);
  const result = JSON.parse(r.body).result;
  return { text: result.content.map((c: any) => c.text).join("\n"), error: result.isError === true };
}

/// An event stream of the admin API (GET /events): what it said so far, as it comes.
function events(port: number, path: string) {
  const heard: string[] = [];
  let close = () => {};
  const opened = new Promise<number>((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path }, (res) => {
      res.setEncoding("utf8");
      res.on("data", (d: string) => heard.push(d));
      resolve(res.statusCode!);
    });
    req.on("error", reject);
    close = () => req.destroy();
    req.end();
  });
  return { opened, close: () => close(), text: () => heard.join("") };
}

/// The program's id of a data directory (`stillfail-reader id`): its key made there.
function stationId(data: string): string {
  const r = spawnSync(binary!, ["id", "--data", data], { env: noNode(), encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout.trim();
}

const store = (data: string) => Store.open(join(data, "stillfail.db"), join(data, "archive"), { currentTimeMillisUnsafe: () => Date.now() } as never);

test("an accepted socket says the port it comes from (net.remotePort): who asks the adb door is told by it", { skip }, async () => {
  const data = fresh("port");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const a = await launch(data, app);
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;

  const listening = await uiAsk(door, "devices.net.listen", [{ port: 0 }]);
  assert.equal(typeof listening.answer?.port, "number", JSON.stringify(listening));
  // (the accept waits for the connection made after it is asked)
  const accepting = uiAsk(door, "devices.net.accept", [listening.answer.id]);
  const client = createConnection({ host: "127.0.0.1", port: listening.answer.port });
  await new Promise<void>((r) => client.once("connect", () => r()));
  const accepted = await accepting;
  assert.equal(typeof accepted.answer, "number", JSON.stringify(accepted));
  const remote = await uiAsk(door, "devices.net.remotePort", [accepted.answer]);
  assert.deepEqual(remote, { answer: client.localPort }, "the port the test's end connects from, as Node's socket.remotePort says it");
  // a socket this station opened itself comes from no port it accepted
  const opened = await uiAsk(door, "devices.net.connect", [{ host: "127.0.0.1", port: listening.answer.port }]);
  assert.equal(typeof opened.answer, "number", JSON.stringify(opened));
  assert.deepEqual(await uiAsk(door, "devices.net.remotePort", [opened.answer]), { answer: null });
  client.destroy();
  for (const s of [accepted.answer, opened.answer]) await uiAsk(door, "devices.net.destroy", [s]);
  await uiAsk(door, "devices.net.close", [listening.answer.id]);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("station_use: the card posted in the chat, denied by the rig's person, closed and restated by the outbox worker and told", { skip }, async () => {
  const data = fresh("rigs");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  const rig = "cd".repeat(32);
  mkdirSync(join(data, "mesh"), { recursive: true });
  // (the rig's person is the admin API's local owner, `local`, who decides it here)
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
    rigs: [{ id: rig, name: "box", owner: "local", owner_email: "o@example.com", owner_name: "O" }],
  }));
  const before = store(data);
  before.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  const thread = before.openThread("ember", "local", "t1", "the chat", null).id;
  before.joinThread(thread, "s1", "ember");
  before.close();

  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const stream = events(door, "/admin-api/events");
  assert.equal(await stream.opened, 200);

  // the chat asks for the rig: its card posted in its chat (dep.postCard), the request kept (rig_requests)
  const asked = await tool(door, "t1", "station_use", { station: "box", reason: "build the release there" });
  assert.equal(asked.error, false, `${asked.text}\n${a.err()}`);
  const db = new DatabaseSync(join(data, "stillfail.db"), { readOnly: true });
  try {
    const row = await given("the request kept", () => db.prepare("SELECT id, status, body FROM rig_requests WHERE session = 's1'").get() as { id: string; status: string; body: string } | undefined);
    assert.equal(row.status, "pending");
    const request = JSON.parse(row.body);
    assert.equal(request.thread, thread, `its card's chat: ${row.body}\n${a.err()}`);
    assert.equal(typeof request.cardTs, "string", row.body);
    const card = () => db.prepare("SELECT n, card FROM entries WHERE thread = ? AND ts = ? AND kind = 'message' AND author_kind = 'agent'").get(thread, request.cardTs) as { n: number; card: string } | undefined;
    const posted = card();
    assert.ok(posted, "the card is a message of the session's agent in its chat");
    assert.equal(JSON.parse(posted.card).rig.request, row.id);
    assert.equal(JSON.parse(posted.card).rig.outcome, undefined, "not decided yet");

    // denied by the rig's person: the request saved, its outcome queued with the card closed in the same write, then
    // restated by the worker, nothing left in the queue, and the stream told of the chat
    const decided = await http(door, `/admin-api/rigs/requests/${row.id}/decide`, { body: JSON.stringify({ allow: false }) });
    assert.equal(decided.status, 200, `${decided.body}\n${a.err()}`);
    assert.equal(JSON.parse(decided.body).request.status, "denied");
    assert.equal((db.prepare("SELECT status FROM rig_requests WHERE id = ?").get(row.id) as { status: string }).status, "denied");
    const closed = await given("the card closed", () => db.prepare("SELECT viewer FROM closed_cards WHERE thread = ? AND n = ?").get(thread, posted.n) as { viewer: string } | undefined);
    assert.equal(closed.viewer, "s1");
    const restated = await given("the card restated with its outcome", () => {
      // (an edit of the message: its card as last restated)
      const edit = db.prepare("SELECT card FROM entries WHERE thread = ? AND kind = 'edit' AND card IS NOT NULL ORDER BY n DESC LIMIT 1").get(thread) as { card: string } | undefined;
      const c = edit ? JSON.parse(edit.card) : null;
      return c?.rig?.outcome?.status === "denied" ? c : null;
    });
    assert.equal(restated.rig.request, row.id, "the same card, its fields kept");
    await given("the outbox emptied", () => (db.prepare("SELECT COUNT(*) AS n FROM card_outbox").get() as { n: number }).n === 0);
    await given("the stream told of the chat", () => stream.text().includes(JSON.stringify({ thread })) || stream.text().includes(`"thread":${thread}`));
    assert.doesNotMatch(a.err(), /SQLITE_BUSY|database is locked|unknown op|no hub call/i);
  } finally {
    db.close();
    stream.close();
  }
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a station that only runs tasks runs what another station sends with a secret (vault.)", { skip }, async () => {
  const data = fresh("rig");
  const app = fresh("app");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  const peer = "ef".repeat(32);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: "w1", workspace_name: "W", name: "rig", relay_url: "", relay_urls: [], grant_keys: {}, peers: [{ id: peer, name: "there" }], revocations: [],
    rig: { owner: "u1", owner_email: "a@b.c", owner_name: "A", person: "ab".repeat(32) },
  }));
  const a = await launch(data, app, { STILLFAIL_PARTS_DOOR: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;
  const peerAsk = async (method: string, body: unknown) => {
    const r = await http(door, `/parts/peer/${method}?from=${peer}`, { body: JSON.stringify(body) });
    return { status: r.status, body: JSON.parse(r.body) };
  };

  // what it takes of the vault's (incoming.ts): asked first by the station that sends one
  assert.deepEqual(await peerAsk("vault.capabilities", { method: "vault.capabilities", workspace: "w1" }), { status: 200, body: { timeouts: true } });
  // a command run with a secret given in its environment, in the directory the chat's tasks share here
  const run = "x_" + "0123456789ABCDEFGHJKMNPQRS";
  const started = await peerAsk("vault.run", {
    method: "vault.run", workspace: "w1", id: run, session: "chat:s1", command: "printf %s \"$TOKEN_X\" > got.txt",
    mode: "env", env: "TOKEN_X", grant: "g1", hosts: [], secret: { kind: "api_key", name: "k", fields: { value: "s3cret" } },
  });
  assert.equal(started.status, 200, `${JSON.stringify(started.body)}\n${a.err()}`);
  const got = join(data, "remote", "w1", peer, "chat:s1", "got.txt");
  await given("the command ran with the secret", () => existsSync(got) && readFileSync(got, "utf8") === "s3cret", 20_000);
  // one not its own refused, as a whole station's vault refuses it
  const bad = await peerAsk("vault.run", { method: "vault.run", workspace: "w1", id: "nope", session: "", command: "" });
  assert.equal(bad.status, 400, JSON.stringify(bad.body));
  assert.match(bad.body.error, /id, session and command are required/);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});

test("a whole station with no rig still offers station_use, and its owner's overview carries the decisions' policy", { skip }, async () => {
  const data = fresh("whole");
  const app = fresh("app");
  const work = fresh("work");
  writeFileSync(join(app, "BUILD"), "9500\n");
  const id = stationId(data);
  mkdirSync(join(data, "mesh"), { recursive: true });
  writeFileSync(join(data, "mesh", "cloud.json"), JSON.stringify({
    origin: "http://127.0.0.1:9", station: id, workspace: "w1", workspace_name: "W", name: "here", relay_url: "", relay_urls: [], grant_keys: {}, peers: [], revocations: [],
  }));
  const before = store(data);
  before.insertSession({ key: "s1", connect: "ember", runtime: "claude", profile: "cc", workspace: work, token: "t1", createdAt: Date.now(), lastActiveAt: Date.now() });
  before.close();
  const a = await launch(data, app, { STILLFAIL_LOCAL_ADMIN: "1" });
  await a.next("ready", (m) => m.ready === true);
  const door = (await a.next("the agents' door", (m) => m.serving === "mcp")).port as number;

  // rigs/module.ts gives the tool whether or not the workspace has a rig: its call says there is none
  const listed = await http(door, "/mcp", { body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }), headers: { authorization: "Bearer t1" } });
  assert.equal(listed.status, 200, listed.body);
  const names = (JSON.parse(listed.body).result.tools as { name: string }[]).map((t) => t.name);
  assert.ok(names.includes("station_use"), names.join(","));
  const used = await tool(door, "t1", "station_use", { station: "box", reason: "build there" });
  assert.equal(used.error, true, used.text);

  // the overview's automatic decisions as an owner sees them: the policy's view (storage's policyView asks the store's now)
  const overview = await http(door, "/admin-api/overview");
  assert.equal(overview.status, 200, overview.body);
  const decisions = JSON.parse(overview.body).automaticDecisions;
  assert.ok(decisions !== null && decisions !== undefined, overview.body);
  assert.notEqual(decisions.policy ?? null, null, `${JSON.stringify(decisions)}\n${a.err()}`);
  a.tell({ op: "stop" });
  assert.equal(await a.ended, 0, a.err());
});
