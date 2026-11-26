// The Comma connect: the station takes part in Comma's Tasks as a Comma station does, against a stand-in for Comma's
// connector socket on a local port (the frames of SalixWeb.ConnectorSocket: `connected`, heartbeats, requests and their
// answers both ways), through a hub with scripted runtimes. Nothing reaches the real Comma.
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { WebSocketServer, type WebSocket } from "ws";
import { commaConnects, commaLine } from "../src/comma/index.ts";
import { type CommaWorkspaceMeta, CommaSurface, OwnerActivity, connectUrl, questionOf, workspaceMetaOf } from "../src/comma/surface.ts";
import { CommaTasks, threadTsOf } from "../src/comma/tasks.ts";
import { Rig, settle } from "./hub-fakes.ts";

type Json = any;

/// Comma's connector socket: who dialed with what, the frames that came up, the requests the station asked (answered
/// by `answer`), and requests sent down with their answers.
class FakeComma {
  readonly server: Server;
  readonly wss = new WebSocketServer({ noServer: true });
  base = "";
  socket: WebSocket | null = null;
  auth = "";
  frames: Json[] = [];
  asked: Json[] = [];
  answer: (request: Json) => Json = () => ({});
  private replies = new Map<string, Json>();
  private waiters: (() => void)[] = [];
  private n = 0;

  constructor() {
    this.server = createServer((_req, res) => res.writeHead(404).end());
    this.server.on("upgrade", (req, socket, head) => {
      this.auth = String(req.headers.authorization ?? "");
      this.wss.handleUpgrade(req, socket, head, (ws) => {
        this.socket = ws;
        ws.on("message", (data) => {
          const f = JSON.parse(String(data));
          this.frames.push(f);
          if (f.type === "request") {
            this.asked.push(f);
            ws.send(JSON.stringify({ id: f.id, type: "response", result: this.answer(f) }));
          } else if (f.type === "response" || f.type === "error") this.replies.set(f.id, f);
          this.tell();
        });
        ws.send(JSON.stringify({ type: "connected", connector_run_id: "run_1", device_id: "dev_1" }));
        this.tell();
      });
    });
  }

  static async start(): Promise<FakeComma> {
    const fake = new FakeComma();
    await new Promise<void>((resolve) => fake.server.listen(0, "127.0.0.1", resolve));
    fake.base = `http://127.0.0.1:${(fake.server.address() as AddressInfo).port}`;
    return fake;
  }

  /// Asks the station, as Salix does over the socket: its answer frame.
  async request(method: string, params: Json): Promise<Json> {
    const id = `req-${++this.n}`;
    this.socket!.send(JSON.stringify({ id, type: "request", method, params }));
    await this.until(method, () => this.replies.has(id));
    return this.replies.get(id);
  }

  posts(): Json[] {
    return this.asked.filter((f) => f.method === "task.post").map((f) => f.params);
  }

  async until(_what: string, f: () => boolean) {
    while (!f()) {
      await new Promise<void>((resolve) => {
        this.waiters.push(resolve);
        setTimeout(resolve, 20);
      });
    }
  }

  private tell() {
    for (const w of this.waiters.splice(0)) w();
  }

  async close() {
    this.socket?.terminate();
    this.wss.close();
    await new Promise<void>((resolve) => this.server.close(() => resolve()));
  }
}

test("the line Comma shows reads as its server and token; anything else does not", () => {
  assert.deepEqual(commaLine("  comma https://api.comma.surf/ salix_conn_abcdef123  "), { server: "https://api.comma.surf", token: "salix_conn_abcdef123" });
  assert.deepEqual(commaLine("comma wss://salix.comma.surf salix_conn_abcdef123"), { server: "https://salix.comma.surf", token: "salix_conn_abcdef123" });
  assert.deepEqual(commaLine("comma ws://localhost:4000 salix_conn_abcdef123"), { server: "http://localhost:4000", token: "salix_conn_abcdef123" });
  assert.equal(commaLine("tailcat 100.1.2.3 4750"), null);
  assert.equal(commaLine("comma ftp://x salix_conn_abcdef123"), null);
  assert.equal(commaLine("comma https://api.comma.surf short"), null);
  assert.equal(connectUrl("https://api.comma.surf", "mac").replace(/&os=.*/, ""), "wss://api.comma.surf/v1/connect?name=mac");
  assert.equal(new URL(connectUrl("https://api.comma.surf", "mac", "ws_1")).searchParams.get("stillfail_workspace"), "ws_1");
  assert.deepEqual(
    commaConnects({
      connects: [
        { id: "c1", kind: "comma", comma: { server: "https://api.comma.surf", token: "tok123456" }, createdBy: { id: "  Peng@Example.COM ", name: "Peng" } },
        { id: "c2", kind: "comma", comma: { server: "https://api.comma.surf", token: "tok123456" }, createdBy: { id: "local", name: "local" } },
      ],
    }).map((c) => [c.id, c.ownerEmail]),
    [["c1", "peng@example.com"], ["c2", null]],
  );
});

test("an options card is Comma's question card, the recommended one marked; a text card or one option is words alone", () => {
  const q = questionOf({ type: "options", options: [{ label: "先不合", detail: "留着" }, { label: "合并", recommended: true }] }, "合不合？");
  assert.deepEqual(q, {
    type: "question", prompt: "合不合？", multi_select: false, allow_other: true,
    choices: [{ id: "o1", label: "先不合", description: "留着" }, { id: "o2", label: "合并", recommended: true }],
  });
  assert.equal(questionOf({ type: "options", options: [{ label: "好" }] }, "x"), null);
  assert.equal(questionOf({ type: "text" }, "x"), null);
});

test("a Comma Task is a thread its agent works in: invited, its Messages heard from the people who said them, what the agent says and asks written into it, where the turn stands, the Task left", async () => {
  const fake = await FakeComma.start();
  const rig = new Rig();
  const dir = mkdtempSync(join(tmpdir(), "comma-"));
  const tasks = new CommaTasks(join(dir, "tasks.json"));
  let seq = 10;
  fake.answer = (f) => (f.method === "task.post" ? { seq: ++seq } : {});
  const surface = new CommaSurface({
    connect: "cm", server: fake.base, token: "salix_conn_test123", name: "mac", ownerEmail: "Ada@Example.Test", tasks, store: rig.store,
    models: () => rig.hub.modelsFor("cm"),
  });
  try {
    rig.edit((raw) => raw.connects.push({ id: "cm", kind: "comma", comma: { server: fake.base, token: "salix_conn_test123" }, bind: { runtime: "claude" } }));
    await rig.hub.shutdown();
    rig.hub = rig.newHub({ chats: (id) => (id === "cm" ? surface : undefined) });
    await surface.start((e) => rig.hub.receive("cm", e));
    // Connected: it says it takes Tasks on its models, and that it is here.
    await fake.until("hello", () => fake.asked.some((f) => f.method === "task.hello"));
    assert.equal(fake.auth, "Bearer salix_conn_test123");
    const meta = fake.frames.find((f) => f.type === "metadata");
    assert.equal(meta.capabilities.tasks, 2);
    assert.equal(meta.capabilities.stillfail_owner_email, "ada@example.test");
    assert.ok("claude" in meta.capabilities.task_models);
    // Comma's heartbeat is answered.
    fake.socket!.send(JSON.stringify({ type: "heartbeat" }));
    await fake.until("heartbeat", () => fake.frames.some((f) => f.type === "heartbeat"));

    const invited = await fake.request("task.invite", { task: "cnv_1", start: { requester: "u_ada", runtime: "claude", model: "opus" } });
    const ts = threadTsOf("cnv_1");
    const key = `cm:TASK:${ts}`;
    assert.deepEqual(invited.result, { session: key, thread: `TASK/${ts}` });
    assert.match((await fake.request("task.invite", { task: "cnv_2", start: { requester: "u_ada", runtime: "dsh" } })).error, /dsh/);
    assert.deepEqual((await fake.request("task.status", { task: "cnv_1" })).result.state, "idle");

    const put = await fake.request("task.put", {
      task: "cnv_1", through: 2,
      messages: [
        { seq: 1, author: { kind: "agent", id: "router", name: "Router" }, text: "请看下登录页" },
        { seq: 2, author: { kind: "person", id: "u_ada", name: "Ada", email: "ada@example.test", picture: "https://example.test/ada.png" }, text: "顺便截个图" },
      ],
    });
    assert.deepEqual(put.result, { through: 2 });
    await settle();
    assert.ok(rig.store.getSession(key));
    // (a model the station's profiles do not run: the runtime's default)
    assert.deepEqual([rig.session(key).runtime, rig.session(key).model], ["claude", null]);
    const thread = rig.store.threadAt("comma:cm", "TASK", ts)!;
    assert.deepEqual(rig.said(thread.id).map((m) => [m.author, m.text]), [["agent:router", "请看下登录页"], ["u_ada", "顺便截个图"]]);
    assert.equal(surface.knownPerson("u_ada")?.name, "Ada");

    // What the agent says, and a card, go into the Task; the card as Comma's question.
    rig.claude.last().reads();
    const answer = await rig.call(key, "chat_post", { to: `TASK/${ts}`, text: "用哪个分支？", card: { type: "options", options: [{ label: "main" }, { label: "dev", recommended: true }] }, kind: "need_human", need: "选分支" });
    assert.ok(answer.startsWith(`Posted to TASK/${ts}`), answer);
    const post = fake.posts().at(-1);
    assert.deepEqual([post.task, post.session, post.text, post.question.choices.map((c: Json) => c.label)], ["cnv_1", key, "用哪个分支？", ["main", "dev"]]);
    assert.equal(rig.store.messageAt(thread.id, "11.000000")?.text, "用哪个分支？");

    // Where its turn stands goes into the Task with it.
    surface.standsAt({ channel: "TASK", threadTs: ts }, { kind: "need", words: "选分支" });
    await fake.until("need_help", () => fake.posts().some((p) => p.declared === "need_help"));
    assert.equal(fake.posts().find((p) => p.declared === "need_help").text, "选分支");

    // Given again with what it said itself and what it answered: only what is new is heard.
    await fake.request("task.put", {
      task: "cnv_1", through: 13, answered: 12,
      messages: [
        { seq: 11, author: { kind: "agent", id: "w", session: key }, text: "用哪个分支？" },
        { seq: 13, author: { kind: "person", id: "u_ada", name: "Ada" }, text: "dev" },
      ],
    });
    await settle();
    assert.deepEqual(rig.said(thread.id).map((m) => m.text).filter((t) => t === "dev"), ["dev"]);

    // Left: it runs elsewhere now; its session leaves the thread and Comma hears it is gone.
    await fake.request("task.leave", { task: "cnv_1" });
    assert.equal((await fake.request("task.status", { task: "cnv_1" })).result.state, "gone");
    assert.deepEqual((await fake.request("task.put", { task: "cnv_1", messages: [] })).result, { gone: true });
    assert.deepEqual((await fake.request("task.put", { task: "cnv_9", messages: [] })).result, { unknown: true, gone: true });
    assert.match((await fake.request("exec", { cmd: "ls" })).error, /not something a still\.fail station does/);
  } finally {
    await surface.stop();
    await rig.close();
    await fake.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("workspaceMetaOf includes self, deduplicates, omits empty marks, and caps at 100 stations while keeping self", () => {
  const peers = Array.from({ length: 120 }, (_, i) => ({ id: `peer_${i}`, name: `Station ${i}` }));
  peers.push({ id: "peer_0", name: "Duplicate" });
  const meta = workspaceMetaOf(
    { workspace: "ws_1", workspace_name: "Team", name: "SelfHost", peers },
    "self_id",
    "fallback-host",
  );
  assert.equal(meta.id, "ws_1");
  assert.equal(meta.name, "Team");
  assert.equal(meta.station, "SelfHost");
  assert.equal("emoji" in meta, false);
  assert.equal("icon" in meta, false);
  assert.equal(meta.stations.length, 100);
  assert.equal(meta.stations.filter((s) => s.id === "peer_0").length, 1);
  assert.deepEqual(meta.stations.find((s) => s.id === "self_id"), { id: "self_id", name: "SelfHost" });

  // When self is already in peers with an outdated name, its name is normalized to selfName (or fallbackHost).
  const withSelf = workspaceMetaOf(
    {
      workspace: "ws_2",
      workspace_name: "Lab",
      workspace_emoji: "🧪",
      workspace_icon: "glyph:beaker",
      name: "",
      peers: [{ id: "self_id", name: "old-name" }, { id: "other", name: "" }],
    },
    "self_id",
    "my-mac",
  );
  assert.deepEqual(withSelf, {
    id: "ws_2",
    name: "Lab",
    station: "my-mac",
    emoji: "🧪",
    icon: "glyph:beaker",
    stations: [
      { id: "self_id", name: "my-mac" },
      { id: "other", name: "other" },
    ],
  });
});

test("CommaSurface sends capabilities.stillfail_workspace on connect and pushes updates on the same socket without duplicates", async () => {
  const fake = await FakeComma.start();
  const rig = new Rig();
  const dir = mkdtempSync(join(tmpdir(), "comma-meta-"));
  const tasks = new CommaTasks(join(dir, "tasks.json"));
  let currentMeta: CommaWorkspaceMeta | null = {
    id: "ws_1",
    name: "Alpha",
    station: "mac-1",
    emoji: "🚀",
    icon: "glyph:rocket",
    stations: [{ id: "st_1", name: "mac-1" }, { id: "st_2", name: "linux-1" }],
  };
  let notify: (() => void) | null = null;
  let unsubscribed = 0;
  const surface = new CommaSurface({
    connect: "cm",
    server: fake.base,
    token: "salix_conn_test123",
    name: "Alpha · mac-1",
    workspace: "ws_1",
    tasks,
    store: rig.store,
    models: () => [],
    workspaceMeta: () => currentMeta,
    onWorkspaceMetaChange: (changed) => {
      notify = changed;
      return () => {
        notify = null;
        unsubscribed++;
      };
    },
  });
  try {
    await surface.start(async () => {});
    await fake.until("first metadata", () => fake.frames.some((f) => f.type === "metadata"));
    const firstSocket = fake.socket;
    const metas = () => fake.frames.filter((f) => f.type === "metadata");
    assert.equal(metas().length, 1);
    assert.deepEqual(metas()[0].capabilities.stillfail_workspace, currentMeta);

    // Firing with unchanged metadata sends nothing.
    notify!();
    await settle();
    assert.equal(metas().length, 1);

    // Updating metadata pushes a new metadata frame on the exact same open socket.
    currentMeta = {
      id: "ws_1",
      name: "Alpha Renamed",
      station: "mac-1",
      stations: [{ id: "st_1", name: "mac-1" }],
    };
    notify!();
    await fake.until("second metadata", () => metas().length === 2);
    assert.equal(fake.socket, firstSocket);
    assert.deepEqual(metas()[1].capabilities.stillfail_workspace, currentMeta);
    assert.equal("emoji" in metas()[1].capabilities.stillfail_workspace, false);
    assert.equal("icon" in metas()[1].capabilities.stillfail_workspace, false);

    // Stopping unsubscribes the listener cleanly.
    await surface.stop();
    assert.equal(unsubscribed, 1);
    assert.equal(notify, null);
  } finally {
    await surface.stop();
    await rig.close();
    await fake.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("CommaSurface quantizes capabilities.stillfail_owner_active_at to 30s buckets and pushes updates on bucket change", async () => {
  const fake = await FakeComma.start();
  const rig = new Rig();
  const dir = mkdtempSync(join(tmpdir(), "comma-active-"));
  const tasks = new CommaTasks(join(dir, "tasks.json"));
  let activeAt: number | null = 1_795_200_012_345;
  let notify: (() => void) | null = null;
  let unsubscribed = 0;
  const surface = new CommaSurface({
    connect: "cm-active",
    server: fake.base,
    token: "salix_conn_test123",
    name: "Alpha · mac-1",
    workspace: "ws_1",
    ownerEmail: "ada@example.test",
    tasks,
    store: rig.store,
    models: () => [],
    lang: "en",
    ownerActiveAt: () => activeAt,
    onOwnerActiveChange: (cb) => {
      notify = cb;
      return () => {
        notify = null;
        unsubscribed++;
      };
    },
  });
  try {
    await surface.start(async () => {});
    const metas = () => fake.frames.filter((f) => f.type === "metadata");
    await fake.until("first metadata", () => metas().length >= 1);
    assert.equal(metas().length, 1);
    assert.equal(metas()[0].capabilities.stillfail_owner_active_at, 1_795_200_000_000);

    // Same 30s bucket sends no duplicate frame.
    activeAt = 1_795_200_029_999;
    notify!();
    await settle();
    assert.equal(metas().length, 1);

    // Next 30s bucket sends an updated metadata frame on the same socket.
    activeAt = 1_795_200_035_000;
    notify!();
    await fake.until("second metadata", () => metas().length === 2);
    assert.equal(metas()[1].capabilities.stillfail_owner_active_at, 1_795_200_030_000);

    await surface.stop();
    assert.equal(unsubscribed, 1);
    assert.equal(notify, null);
  } finally {
    await surface.stop();
    await rig.close();
    await fake.close();
    rmSync(dir, { recursive: true, force: true });
  }
});

test("OwnerActivity merges cross-station peer reads monotonically without re-gossiping or leaking other workspaces", () => {
  const peer = new OwnerActivity();
  const host = new OwnerActivity();

  // No local reads yet: nothing to attach to comma.changed.
  assert.equal(peer.localPayload(), null);

  // Local read on peer station (e.g. Windows desktop) quantizes to 30s and exports only allowed workspace viewers.
  assert.equal(peer.recordLocal("Peng@Example.com", 1_795_200_012_345), true);
  assert.equal(peer.recordLocal("other@workspace.test", 1_795_200_045_000), true);
  assert.deepEqual(peer.localPayload(new Set(["peng@example.com"])), {
    at: 1_795_200_000_000,
    byViewer: { "peng@example.com": 1_795_200_000_000 },
  });

  // Host station (holding the Comma socket) merges peer activity and reports it for the owner without re-exporting it.
  const wire = peer.localPayload(new Set(["peng@example.com"]));
  assert.equal(host.mergePeer(wire, 1_795_200_020_000), true);
  assert.equal(host.get("peng@example.com"), 1_795_200_000_000);
  assert.equal(host.get("someone-else@example.com"), null);
  assert.equal(host.get(null), 1_795_200_000_000);
  assert.equal(host.localPayload(), null);

  // Duplicate or older peer buckets do not advance state or regress newer timestamps.
  assert.equal(host.mergePeer(wire, 1_795_200_025_000), false);
  assert.equal(host.mergePeer({ at: 1_795_199_970_000, byViewer: { "peng@example.com": 1_795_199_970_000 } }, 1_795_200_025_000), false);
  assert.equal(host.get("peng@example.com"), 1_795_200_000_000);

  // Wildly future peer clocks (>5m ahead) and malformed payloads are ignored.
  assert.equal(host.mergePeer({ at: 1_795_201_000_000, byViewer: { "peng@example.com": 1_795_201_000_000 } }, 1_795_200_025_000), false);
  assert.equal(host.mergePeer(null, 1_795_200_025_000), false);
  assert.equal(host.mergePeer("bad", 1_795_200_025_000), false);
  assert.equal(host.get("peng@example.com"), 1_795_200_000_000);

  // Unattributed peer payload (e.g. MoonBit station without per-viewer read info) advances single-owner lookups.
  assert.equal(host.mergePeer({ at: 1_795_200_065_000 }, 1_795_200_070_000), true);
  assert.equal(host.get("peng@example.com"), 1_795_200_060_000);
});

test("validTaskLinks accepts https web and comma*://task app links and rejects untrusted schemes", async () => {
  const { validTaskLinks } = await import("../src/comma/tasks.ts");
  assert.deepEqual(
    validTaskLinks({
      web: "https://app.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3",
      app: "comma://task?workspace=wsp_1&group=grp1_2&task=cnv_3",
    }),
    {
      web: "https://app.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3",
      app: "comma://task?workspace=wsp_1&group=grp1_2&task=cnv_3",
    },
  );
  assert.deepEqual(
    validTaskLinks({
      web: "https://app-staging.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3",
      app: "comma-staging://task?workspace=wsp_1&group=grp1_2&task=cnv_3",
    }),
    {
      web: "https://app-staging.comma.surf/#/tasks/wsp_1/grp1_2/cnv_3",
      app: "comma-staging://task?workspace=wsp_1&group=grp1_2&task=cnv_3",
    },
  );
  assert.equal(validTaskLinks({ web: "http://app.comma.surf/x", app: "file:///etc/passwd" }), null);
  assert.equal(validTaskLinks({ web: "javascript:alert(1)", app: "comma://evil?x=1" }), null);
  assert.equal(validTaskLinks({ app: "comma://task" }), null);
  assert.equal(validTaskLinks({ app: "comma://task?x=1#frag" }), null);
});

test("CommaSurface.ask cancels its timeout timer immediately when answered or closed, and rejects on timeout", async () => {
  const realSetTimeout = globalThis.setTimeout;
  const realClearTimeout = globalThis.clearTimeout;
  const activeLong = new Set<ReturnType<typeof setTimeout>>();
  globalThis.setTimeout = ((fn: (...args: any[]) => void, delay?: number, ...args: any[]) => {
    const handle = realSetTimeout((...cbArgs: any[]) => {
      activeLong.delete(handle);
      fn(...cbArgs);
    }, delay, ...args);
    if (typeof delay === "number" && delay >= 60_000) activeLong.add(handle);
    return handle;
  }) as typeof setTimeout;
  globalThis.clearTimeout = ((handle?: ReturnType<typeof setTimeout>) => {
    if (handle !== undefined) activeLong.delete(handle);
    return realClearTimeout(handle);
  }) as typeof clearTimeout;

  try {
    const surface = new CommaSurface({
      connect: "cm-timer",
      server: "http://127.0.0.1:1",
      token: "tok",
      name: "st-timer",
      tasks: { byThread: () => null, get: () => null, setLinks: () => {}, given: () => {} } as any,
      store: {} as any,
      models: () => ({}),
      lang: "en",
    } as any);

    // 1. Answered via response frame: long timeout must be scheduled then cleared immediately.
    let respond!: () => void;
    (surface as any).socket_ = {
      send: (raw: string) => {
        const f = JSON.parse(raw);
        respond = () => (surface as any).frame((surface as any).socket_, { type: "response", id: f.id, result: { ok: true } }, () => {});
      },
    };
    const p1 = (surface as any).ask("task.post", { text: "hi" }, 60_000);
    await settle();
    assert.equal(activeLong.size, 1, "pending ask() should hold one timeout timer");
    respond();
    assert.deepEqual(await p1, { ok: true });
    await settle();
    assert.equal(activeLong.size, 0, "answering ask() must cancel its pending timeout timer");

    // 2. Rejected via closed(): long timeout must also be cleared immediately.
    (surface as any).socket_ = { send: () => {} };
    const p2 = (surface as any).ask("task.post", { text: "bye" }, 60_000);
    await settle();
    assert.equal(activeLong.size, 1, "pending ask() should hold one timeout timer before close");
    (surface as any).closed();
    await assert.rejects(() => p2, /Comma is not connected/);
    await settle();
    assert.equal(activeLong.size, 0, "closed() rejecting ask() must cancel its pending timeout timer");

    // 3. Unanswered request still rejects when its timeout expires.
    (surface as any).socket_ = { send: () => {} };
    await assert.rejects(() => (surface as any).ask("task.post", { text: "late" }, 20), /Comma did not answer task\.post in time/);
  } finally {
    globalThis.setTimeout = realSetTimeout;
    globalThis.clearTimeout = realClearTimeout;
  }
});
