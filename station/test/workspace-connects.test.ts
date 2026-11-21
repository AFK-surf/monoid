// A connect is its workspace's (connects/remote.ts, connects/workspace.ts): it runs on one station, and its chats on any
// station of the workspace. Two stations here, H (the connect's) and S, over a transport of the test's that carries
// what the mesh does (a JSON head, bytes after it).
import assert from "node:assert/strict";
import { readdirSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { PeerBus, bytesOf, withBytes } from "../src/mesh/bus.ts";
import { WorkspaceConnects, fingerprint } from "../src/connects/workspace.ts";
import { connectEdits } from "../src/api/routes/connects.ts";
import { overview } from "../src/api/overview.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import type { ChatSurface } from "../src/sessions/chat.ts";
import { FeishuSurface } from "../src/feishu/surface.ts";
import { FeishuThreads } from "../src/feishu/threads.ts";
import { feishuTools } from "../src/feishu/tool.ts";
import { FeishuClient } from "../src/feishu/web.ts";
import { FakeFeishu, RawAnswer } from "./feishu-fake.ts";
import { Rig, message, reply, settle } from "./hub-fakes.ts";

type Json = any;

const H = "aaaa1111";
const S = "bbbb2222";
const roster = [
  { id: H, name: "laptop" },
  { id: S, name: "desktop" },
];

/// What crosses the mesh: its JSON (a copy, as a stream's head is), and the bytes after it as they are.
function across(v: Json): Json {
  const bytes = bytesOf(v);
  const copy = JSON.parse(JSON.stringify(v));
  return bytes === null ? copy : withBytes(copy, bytes);
}

type Station = { rig: Rig; bus: PeerBus; connects: WorkspaceConnects; up: boolean; restart(): void; local: Map<string, ChatSurface> };

/// Two stations of workspace "ws", each a hub of its own whose connects are config.json's and the other's it was told
/// of; H has the Slack connect `cl`.
function workspace(): { h: Station; s: Station; close(): Promise<void> } {
  const stations = new Map<string, Station>();
  const make = (id: string): Station => {
    const rig = new Rig({ place: { workspace: "ws", station: id } });
    const station = { rig, up: true } as Station;
    const wire = () => {
      const bus = new PeerBus({ sleep: async () => {} });
      bus.attach(async (to, ws, request) => {
        const there = stations.get(to);
        if (there === undefined || !there.up || !station.up) throw new Error("station unreachable");
        const answer = across(await there.bus.handle(ws ?? "ws", id, across(request)));
        // (stopped as it answered: the answer lost)
        if (!there.up) throw new Error("station unreachable");
        return answer;
      });
      station.bus = bus;
      station.connects = new WorkspaceConnects({
        data: rig.dir,
        hub: () => rig.hub,
        store: rig.store,
        config: { raw: () => rig.raw, updateSoon: async (f) => f(rig.raw) },
        bus,
        here: () => id,
        home: () => "ws",
        stations: (ws) => (ws === "ws" ? roster : []),
        names: () => null,
      });
    };
    // (started again: a new bus and connects over the same data and config.json; what was under way in memory gone)
    station.restart = () => {
      station.up = true;
      wire();
    };
    const config = () => {
      const read = hubConfig(rig.raw, rig.dir);
      read.connects.push(...station.connects.remote.connects());
      return read;
    };
    Object.defineProperty(rig, "config", { get: config, configurable: true });
    const local = new Map<string, ChatSurface>([["cl", rig.chat], ["gpt", rig.gptChat], ["team", rig.teamChat]]);
    station.local = local;
    rig.hub = rig.newHub({ chats: (c) => (rig.raw.connects.some((e: Json) => e.id === c) ? local.get(c) : undefined) ?? station.connects.remote.surface(c) });
    wire();
    stations.set(id, station);
    return station;
  };
  const h = make(H);
  const s = make(S);
  // S runs no connect of its own: `cl` is H's.
  s.rig.raw.connects = [];
  return { h, s, close: async () => (await h.rig.close(), await s.rig.close()) };
}

test("a new conversation of a connect that names another station runs there; what follows in its thread goes there too, and what its agent says goes out through the connect", async () => {
  const { h, s, close } = workspace();
  h.rig.raw.connects.find((c: Json) => c.id === "cl").station = S;
  const first = message({ text: "<@UBOT> look at the build" });
  await h.connects.receive("cl", { type: "message", message: first });
  await settle();
  const id = `cl@${H}`;
  const key = sessionKey(id, first.channel, first.threadTs);
  assert.ok(s.rig.store.getSession(key), "the session is S's");
  assert.equal(h.rig.store.threadAt("slack:T1", first.channel, first.threadTs), null, "H keeps no thread of it");
  assert.equal(h.rig.store.connectThreadStation("cl", first.channel, first.threadTs), S);
  // Its runtime and model are the connect's; no profile of H's.
  assert.deepEqual([s.rig.session(key).runtime, s.rig.session(key).connect], ["claude", id]);

  // A reply that does not mention the bot: S's session hears it all the same.
  await h.connects.receive("cl", { type: "message", message: reply(first, "1700.9", "and the tests", { addressed: false }) });
  await settle();
  const thread = s.rig.store.threadAt("slack:T1", first.channel, first.threadTs)!;
  assert.deepEqual(s.rig.said(thread.id).map((m) => m.text), ["<@UBOT> look at the build", "and the tests"]);

  // What the agent says, and a file with it, are posted by H's bot.
  s.rig.claude.last().reads();
  const file = join(s.rig.dir, "report.txt");
  writeFileSync(file, "all green");
  const answer = await s.rig.call(key, "chat_post", { to: `${first.channel}/${first.threadTs}`, text: "done", files: [file] });
  assert.ok(answer.startsWith("Posted"), answer);
  assert.equal(h.rig.chat.lastText(), "done");
  assert.deepEqual(h.rig.chat.files.at(-1), ["report.txt"]);
  assert.deepEqual(readdirSync(join(h.rig.dir, "run", "connect-uploads")), [], "the file is not kept after it is posted");
  // The bot S's hub knows is H's bot.
  assert.equal(s.rig.hub.chatOf(id)?.botUserId(), "UBOT");
  await close();
});

test("feishu_api of a chat whose Feishu connect runs on another station: its JSON with and without to=, and a message's image saved in that chat's own uploads", async () => {
  const { h, s, close } = workspace();
  const fake = await FakeFeishu.start();
  const surface = new FeishuSurface({
    connect: "fs", appId: "cli_test", appSecret: "s", domain: "feishu",
    threads: new FeishuThreads(join(h.rig.dir, "threads.json")),
    client: new FeishuClient("cli_test", "s", "feishu", fake.base),
  });
  try {
    h.rig.raw.connects.push({ id: "fs", kind: "feishu", feishu: { appId: "cli_test", appSecret: "s" }, bind: { runtime: "claude" }, station: S });
    h.local.set("fs", surface);
    await h.connects.receive("fs", { type: "message", message: { channel: "oc_g", threadTs: "om_a", ts: "om_a", user: "ou_ada", text: "@Bot 帮忙", addressed: true } });
    await settle();
    const key = sessionKey(`fs@${H}`, "oc_g", "om_a");
    assert.ok(s.rig.store.getSession(key), "the session is S's");
    // S has no Feishu connect of its own: the one it knows is H's.
    const tool = feishuTools(() => s.rig.hub, (id) => s.rig.raw.connects.some((c: Json) => c.id === id && c.kind === "feishu"))[0]!;

    fake.answer("GET /open-apis/im/v1/chats/oc_g", { code: 0, data: { name: "团队" } });
    assert.deepEqual(JSON.parse(await tool.run(key, { method: "GET /open-apis/im/v1/chats/oc_g" })), { code: 0, data: { name: "团队" } });
    fake.answer("GET /open-apis/im/v1/messages", { code: 0, data: { items: [] } });
    assert.deepEqual(JSON.parse(await tool.run(key, { method: "GET /open-apis/im/v1/messages", to: "oc_g/om_a" })), { code: 0, data: { items: [] } });

    const resource = "/open-apis/im/v1/messages/om_other/resources/file_key";
    const bytes = Buffer.from([0xff, 0xd8, 0xff, 0x00, 0x80, 0xfe]);
    fake.answer(`GET ${resource}`, new RawAnswer(bytes, { "content-type": "image/jpeg", "content-disposition": 'attachment; filename="photo.jpg"' }));
    const saved = JSON.parse(await tool.run(key, { method: `GET ${resource}`, params: { type: "image" } }));
    assert.equal(dirname(saved.path), join(s.rig.session(key).workspace, "uploads"));
    assert.deepEqual({ content_type: saved.content_type, size: saved.size }, { content_type: "image/jpeg", size: bytes.length });
    assert.deepEqual(await readFile(saved.path), bytes);
    assert.deepEqual(fake.calls("GET", resource).map((c) => c.query), [{ type: "image" }]);
  } finally {
    await close();
    await surface.stop();
    await fake.close();
  }
});

test("chat_post to a Feishu chat_id from a chat whose Feishu connect runs on another station: its file and card go through that station, which keeps no file after and routes the new thread's messages back here (FB-43)", async () => {
  const { h, s, close } = workspace();
  const fake = await FakeFeishu.start();
  const surface = new FeishuSurface({
    connect: "fs", appId: "cli_test", appSecret: "s", domain: "feishu",
    threads: new FeishuThreads(join(h.rig.dir, "threads.json")),
    client: new FeishuClient("cli_test", "s", "feishu", fake.base),
  });
  try {
    h.rig.raw.connects.push({ id: "fs", kind: "feishu", feishu: { appId: "cli_test", appSecret: "s" }, bind: { runtime: "claude" }, station: S });
    h.local.set("fs", surface);
    await h.connects.receive("fs", { type: "message", message: { channel: "oc_g", threadTs: "om_a", ts: "om_a", user: "ou_ada", text: "@Bot 建个群", addressed: true } });
    await settle();
    const id = `fs@${H}`;
    const key = sessionKey(id, "oc_g", "om_a");
    assert.ok(s.rig.store.getSession(key), "the session is S's");
    s.rig.claude.last().reads();
    const file = join(s.rig.dir, "report.pdf");
    writeFileSync(file, "pdf");
    const answer = await s.rig.call(key, "chat_post", { to: "oc_remote", text: "选哪个", files: [file], card: { type: "options", options: [{ label: "A" }, { label: "B" }] }, kind: "need_human", need: "选 A 或 B" });
    const ts = /^Posted to oc_remote\/(om_bot\d+) \(now one of your conversations\), and recorded state need_human\./.exec(answer)?.[1];
    assert.ok(ts, answer);
    // H's bot posted it: the file uploaded there first, the card first in the chat, its buttons answering in the thread.
    assert.deepEqual(fake.calls("POST", /^\/open-apis\/im\/v1\/(files|messages)$/).map((c) => [c.path, c.body.msg_type ?? c.body.file_type]), [
      ["/open-apis/im/v1/files", "pdf"],
      ["/open-apis/im/v1/messages", "interactive"],
      ["/open-apis/im/v1/messages", "file"],
    ]);
    assert.equal(JSON.parse(fake.calls("PATCH", `/open-apis/im/v1/messages/${ts}`)[0]!.body.content).body.elements.find((e: Json) => e.tag === "button").behaviors[0].value.t, ts);
    assert.deepEqual(readdirSync(join(h.rig.dir, "run", "connect-uploads")), [], "the file is not kept after it is posted");
    // The thread is S's: H routes what is said in it there.
    assert.equal(h.rig.store.connectThreadStation("fs", "oc_remote", ts!), S);
    const thread = s.rig.store.threadAt(s.rig.hub.surface(id), "oc_remote", ts!)!;
    assert.equal(s.rig.store.sessionThread(key, "oc_remote", ts!)?.connect, id);
    await h.connects.receive("fs", { type: "message", message: { channel: "oc_remote", threadTs: ts!, ts: "om_y", user: "ou_ada", text: "收到", addressed: false } });
    await settle();
    assert.deepEqual(s.rig.said(thread.id).map((m) => m.text), ["选哪个", "收到"]);
    assert.equal(h.rig.store.threadAt(h.rig.hub.surface("fs"), "oc_remote", ts!), null, "H keeps no thread of it");
    // H as a station from before describes it (no beginPost): files or a card are refused before anything is asked of
    // H; words alone go, and S routes the thread it began to itself with connect.route.
    const was = s.connects.describedFor(id)!;
    const { beginPost: _given, ...old } = was.described;
    s.connects.remote.learn(id, was.station, old);
    const asked: string[] = [];
    const handle = h.bus.handle.bind(h.bus);
    h.bus.handle = ((ws: Json, peer: Json, request: Json) => {
      // (what begins, uploads or routes: the status lines a turn shows go on beside them)
      if (request?.method !== "connect.call" || ["begin", "upload", "post"].includes(request?.op)) asked.push(request?.op ?? request?.method);
      return handle(ws, peer, request);
    }) as typeof h.bus.handle;
    const update = "the station that runs this connect needs an update before chat_post can attach files or a card to a new conversation's first message";
    s.rig.claude.last().reads();
    assert.equal(await s.rig.refused(key, "chat_post", { to: "oc_old", text: "附件", files: [file] }), update);
    assert.equal(await s.rig.refused(key, "chat_post", { to: "oc_old", text: "选哪个", card: { type: "options", options: [{ label: "A" }] } }), update);
    assert.deepEqual(asked, [], "nothing uploaded to or begun on H");
    assert.deepEqual(readdirSync(join(h.rig.dir, "run", "connect-uploads")), []);
    const plain = await s.rig.call(key, "chat_post", { to: "oc_old", text: "大家好" });
    const oldTs = /^Posted to oc_old\/(om_bot\d+) \(now one of your conversations\)\./.exec(plain)?.[1];
    assert.ok(oldTs, plain);
    assert.deepEqual(asked, ["begin", "connect.route"]);
    assert.equal(h.rig.store.connectThreadStation("fs", "oc_old", oldTs!), S);
    await h.connects.receive("fs", { type: "message", message: { channel: "oc_old", threadTs: oldTs!, ts: "om_z", user: "ou_ada", text: "收到了", addressed: false } });
    await settle();
    const oldThread = s.rig.store.threadAt(s.rig.hub.surface(id), "oc_old", oldTs!)!;
    assert.deepEqual(s.rig.said(oldThread.id).map((m) => m.text), ["大家好", "收到了"]);
  } finally {
    await close();
    await surface.stop();
    await fake.close();
  }
});

test("a conversation that began before stays where it is; one the station named cannot take runs on the connect's own", async () => {
  const { h, s, close } = workspace();
  const before = message({ text: "<@UBOT> hi" });
  await h.connects.receive("cl", { type: "message", message: before });
  await settle();
  const local = sessionKey("cl", before.channel, before.threadTs);
  assert.ok(h.rig.store.getSession(local), "with no station named: here");

  h.rig.raw.connects.find((c: Json) => c.id === "cl").station = S;
  await h.connects.receive("cl", { type: "message", message: reply(before, "1701.1", "<@UBOT> more") });
  await settle();
  assert.equal(h.rig.said(h.rig.thread(before.channel, before.threadTs).id).length, 2, "its thread goes on here");

  s.up = false;
  const fresh = message({ text: "<@UBOT> new" });
  await h.connects.receive("cl", { type: "message", message: fresh });
  await settle();
  assert.ok(h.rig.store.getSession(sessionKey("cl", fresh.channel, fresh.threadTs)), "S off: it runs here");
  assert.equal(h.rig.store.connectThreadStation("cl", fresh.channel, fresh.threadTs), null);
  await close();
});

test("a message for a chat on a station that is off is not lost silently: the thread is told", async () => {
  const { h, s, close } = workspace();
  h.rig.raw.connects.find((c: Json) => c.id === "cl").station = S;
  const first = message({ text: "<@UBOT> go" });
  await h.connects.receive("cl", { type: "message", message: first });
  await settle();
  s.up = false;
  await h.connects.receive("cl", { type: "message", message: reply(first, "1702.1", "still there?", { addressed: false }) });
  assert.match(h.rig.chat.lastText(), /desktop/);
  await close();
});

test("a connect moved to another station runs there, under the id the workspace knows it by; the chats here go on through it", async () => {
  const { h, s, close } = workspace();
  const here = message({ text: "<@UBOT> hi" });
  await h.connects.receive("cl", { type: "message", message: here });
  await settle();
  const key = sessionKey("cl", here.channel, here.threadTs);

  await h.connects.move("cl", S, "ws");
  assert.equal(h.rig.raw.connects.some((c: Json) => c.id === "cl"), false);
  const moved = s.rig.raw.connects.find((c: Json) => c.id === `cl@${H}`);
  assert.equal(moved?.kind ?? "slack", "slack");
  assert.equal(moved.workspace, undefined, "of S's home workspace: none said");
  assert.equal(s.rig.store.connectThreadStation(`cl@${H}`, here.channel, here.threadTs), H, "H's chat stays H's");

  // S runs the connect now (its own surface, as its Slack part would connect it).
  const local = new Map([[`cl@${H}`, s.rig.chat]]);
  s.rig.hub = s.rig.newHub({ chats: (c) => local.get(c) ?? s.connects.remote.surface(c) });
  // What H's chat says goes out through S's connection.
  const answer = await h.rig.call(key, "chat_post", { to: `${here.channel}/${here.threadTs}`, text: "from H" });
  assert.ok(answer.startsWith("Posted"), answer);
  assert.equal(s.rig.chat.lastText(), "from H");
  // And what comes in its thread reaches H's session.
  await s.connects.receive(`cl@${H}`, { type: "message", message: reply(here, "1703.1", "thanks", { addressed: false }) });
  await settle();
  assert.deepEqual(h.rig.said(h.rig.thread(here.channel, here.threadTs).id).map((m) => m.text).at(-1), "thanks");
  await close();
});

test("across a connect's move every event is handled once, by the station that holds it: one its leaving socket gives as the other takes it, and one after, go to the other; nothing begins on the station it left", async () => {
  const { h, s, close } = workspace();
  // (S runs it once taken, under the id the workspace knows it by)
  s.rig.hub = s.rig.newHub({ chats: (c) => (c === `cl@${H}` ? s.rig.chat : s.connects.remote.surface(c)) });
  const before = h.rig.store.listSessions().length;
  const during = message({ text: "<@UBOT> as it moves", threadTs: "1800.1", ts: "1800.1" });
  const after = message({ text: "<@UBOT> just after", threadTs: "1800.2", ts: "1800.2" });
  /// (what handling it came to: null, or why it was not)
  let late: Promise<string | null> | null = null;
  // (an event H's socket gives at the last moment: as S is taking it, before H heard it was taken)
  const ask = s.bus.handle.bind(s.bus);
  s.bus.handle = async (ws: string, from: string, request: Json) => {
    if (request?.method === "connect.take" && late === null) {
      late = h.connects.receive("cl", { type: "message", message: during }).then(() => null, (e: Error) => e.message);
      // (what it set going done before S takes it: an event sent on at once would reach S before its entry)
      await new Promise<void>((r) => setImmediate(r));
    }
    return ask(ws, from, request);
  };
  await h.connects.move("cl", S, "ws");
  assert.ok(late !== null, "the event came as S took it");
  assert.equal(await late, null, "taken where it went");
  // (and one its socket gives after the hand-off, before it closed)
  await h.connects.receive("cl", { type: "message", message: after });
  await settle();
  assert.equal(h.rig.store.listSessions().length, before, "nothing began on the station it left");
  for (const m of [during, after]) {
    assert.equal(h.rig.store.threadAt(h.rig.hub.surface("cl"), m.channel, m.threadTs), null, `${m.text}: not here`);
    assert.notEqual(s.rig.store.getSession(sessionKey(`cl@${H}`, m.channel, m.threadTs)), null, `${m.text}: begun on S, once`);
  }
  assert.equal(s.rig.store.listSessions().filter((x) => x.key.includes("1800.")).length, 2, "each once");
  await close();
});

test("a connect moved away and added here again by a person: what its socket here gives is this station's again, not sent where it went", async () => {
  const { h, s, close } = workspace();
  s.rig.hub = s.rig.newHub({ chats: (c) => (c === `cl@${H}` ? s.rig.chat : s.connects.remote.surface(c)) });
  const entry = structuredClone(h.rig.raw.connects.find((c: Json) => c.id === "cl"));
  await h.connects.move("cl", S, "ws");
  // (a person adds the same bot here again, as config.json had it)
  h.rig.raw.connects.push(entry);
  const again = message({ text: "<@UBOT> here again", threadTs: "2000.1", ts: "2000.1" });
  await h.connects.receive("cl", { type: "message", message: again });
  await settle();
  assert.equal(s.rig.store.listSessions().some((x) => x.key.includes("2000.1")), false, "not sent to where it went");
  assert.equal(h.rig.store.listSessions().filter((x) => x.key.includes("2000.1")).length, 1, "taken here, once");
  await close();
});

/// What station `st` keeps of connects' moves under way.
const kept = (st: Station) => {
  try {
    return readdirSync(join(st.rig.dir, "replica", "connects-moving"));
  } catch {
    return [];
  }
};
/// Who holds `cl` (its entry in config.json): H, S, both or neither.
const holders = (h: Station, s: Station) => [h.rig.raw.connects.some((c: Json) => c.id === "cl") ? "H" : "", s.rig.raw.connects.some((c: Json) => c.id === `cl@${H}`) ? "S" : ""].filter((x) => x !== "");

test("a connect's move cut as the station it leaves stops after the other took it, before it dropped its own: both started again, the other holds it alone, the move said done, what the old socket gives goes there", async () => {
  const { h, s, close } = workspace();
  s.rig.hub = s.rig.newHub({ chats: (c) => (c === `cl@${H}` ? s.rig.chat : s.connects.remote.surface(c)) });
  // (H stops right after S's answer, before its own config.json is written: what it would write next fails, as a
  // process gone writes nothing)
  let cut = false;
  const handle = s.bus.handle.bind(s.bus);
  s.bus.handle = async (ws: string, from: string, request: Json) => {
    const answer = await handle(ws, from, request);
    if (request?.method === "connect.take") (cut = true), Object.freeze(h.rig.raw);
    return answer;
  };
  await assert.rejects(h.connects.move("cl", S, "ws"));
  assert.ok(cut);
  assert.deepEqual(holders(h, s), ["H", "S"], "cut: both say they hold it");
  (h.rig as Json).raw = { ...h.rig.raw };
  h.restart();
  s.bus.handle = handle;
  await h.connects.settleMoving();
  assert.deepEqual(holders(h, s), ["S"], "started again: S alone");
  assert.equal(h.connects.runsOn("cl"), S, "the move's item says it is there");
  assert.deepEqual(kept(h), [], "nothing of the move kept");
  const late = message({ text: "<@UBOT> late on the old socket", threadTs: "1900.1", ts: "1900.1" });
  await h.connects.receive("cl", { type: "message", message: late });
  await settle();
  assert.notEqual(s.rig.store.getSession(sessionKey(`cl@${H}`, late.channel, late.threadTs)), null, "handled there");
  assert.equal(h.rig.store.listSessions().some((x) => x.key.includes("1900.1")), false, "not here");
  await close();
});

test("a connect's move cut as the station it goes to stops after it took it, before it answered: the one it leaves hears no answer; both started again, the other holds it alone; one that never took it leaves it here", async () => {
  for (const tookIt of [true, false]) {
    const { h, s, close } = workspace();
    const handle = s.bus.handle.bind(s.bus);
    s.bus.handle = async (ws: string, from: string, request: Json) => {
      if (request?.method !== "connect.take") return handle(ws, from, request);
      const answer = tookIt ? await handle(ws, from, request) : null;
      s.up = false;
      return answer;
    };
    await assert.rejects(h.connects.move("cl", S, "ws"));
    assert.deepEqual(holders(h, s), tookIt ? ["H", "S"] : ["H"], "cut");
    s.restart();
    // (S heard from again: what was under way with it asked)
    await h.connects.settleMoving(S);
    assert.deepEqual(holders(h, s), tookIt ? ["S"] : ["H"], `${tookIt ? "took it" : "never took it"}: one holder`);
    assert.equal(h.connects.runsOn("cl"), tookIt ? S : null);
    // (nothing left to settle: asked again, the same; nothing of the move kept)
    await h.connects.settleMoving();
    assert.deepEqual(holders(h, s), tookIt ? ["S"] : ["H"]);
    assert.deepEqual(kept(h), [], "nothing of the move kept");
    await close();
  }
});

test("a connect is added on one station of the workspace: the same bot on another is refused, named by where it is", async () => {
  const { h, s, close } = workspace();
  h.rig.raw.connects.find((c: Json) => c.id === "cl").slack = { botToken: "xoxb-1", appToken: "xapp-1" };
  assert.equal(await s.connects.heldBy("ws", "slack", { botToken: "xoxb-1" }), "laptop");
  assert.equal(await s.connects.heldBy("ws", "slack", { botToken: "xoxb-2" }), null);
  assert.equal(fingerprint("slack", {}), null, "one with no token yet is not asked about");
  await close();
});

const S2 = "cccc3333";
const RIG = "dddd4444";
const UNCHECKED = "eeee5555";

function multiWorkspace(loads: Record<string, () => Promise<Json> | Json>) {
  const fullRoster = [
    { id: H, name: "host-h" },
    { id: S, name: "worker-s1" },
    { id: S2, name: "worker-s2" },
    { id: RIG, name: "rig-gpu", mode: "tasks" },
    { id: UNCHECKED, name: "unchecked-s3" },
  ];
  const stations = new Map<string, Station>();
  const make = (id: string): Station => {
    const rig = new Rig({ place: { workspace: "ws", station: id } });
    const station = { rig, up: true } as Station;
    const wire = () => {
      const bus = new PeerBus({ sleep: async () => {} });
      bus.attach(async (to, ws, request) => {
        const there = stations.get(to);
        if (there === undefined || !there.up || !station.up) throw new Error("station unreachable");
        const answer = across(await there.bus.handle(ws ?? "ws", id, across(request)));
        if (!there.up) throw new Error("station unreachable");
        return answer;
      });
      bus.on("describe", async () => {
        const fn = loads[id];
        return fn ? await fn() : { sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 50 } } };
      });
      station.bus = bus;
      station.connects = new WorkspaceConnects({
        data: rig.dir,
        hub: () => rig.hub,
        store: rig.store,
        config: { raw: () => rig.raw, updateSoon: async (f) => f(rig.raw) },
        bus,
        here: () => id,
        home: () => "ws",
        stations: (ws) => (ws === "ws" ? fullRoster : []),
        names: () => null,
        selfLoad: async () => {
          const fn = loads[id];
          return fn ? await fn() : { sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 50 } } };
        },
        // Non-resolving test timer so synchronous/microtask describe answers always settle before deadline.
        sleep: () => new Promise<void>(() => {}),
        describeTimeoutMs: 1500,
      });
    };
    station.restart = () => {
      station.up = true;
      wire();
    };
    const config = () => {
      const read = hubConfig(rig.raw, rig.dir);
      read.connects.push(...station.connects.remote.connects());
      return read;
    };
    Object.defineProperty(rig, "config", { get: config, configurable: true });
    const local = new Map<string, ChatSurface>([["cl", rig.chat], ["gpt", rig.gptChat], ["team", rig.teamChat]]);
    station.local = local;
    rig.hub = rig.newHub({ chats: (c) => (rig.raw.connects.some((e: Json) => e.id === c) ? local.get(c) : undefined) ?? station.connects.remote.surface(c) });
    wire();
    stations.set(id, station);
    return station;
  };
  const h = make(H);
  const s1 = make(S);
  const s2 = make(S2);
  const rigSt = make(RIG);
  const unchecked = make(UNCHECKED);
  for (const st of [s1, s2, rigSt, unchecked]) st.rig.raw.connects = [];
  return {
    h, s1, s2, rigSt, unchecked,
    close: async () => {
      for (const st of [h, s1, s2, rigSt, unchecked]) await st.rig.close();
    },
  };
}

test("multi-station allowlist: balances by running.turns, memory ratio, round-robin tie-break, and strictly excludes unchecked and mode=tasks stations", async () => {
  let s1Turns = 2;
  let s2Turns = 0;
  let s1Avail = 80;
  let s2Avail = 40;
  const { h, s1, s2, rigSt, unchecked, close } = multiWorkspace({
    [S]: () => ({ sessions: true, load: { running: { turns: s1Turns }, memory: { totalBytes: 100, availableBytes: s1Avail } } }),
    [S2]: () => ({ sessions: true, load: { running: { turns: s2Turns }, memory: { totalBytes: 100, availableBytes: s2Avail } } }),
    [RIG]: () => ({ mode: "tasks", sessions: false, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 99 } } }),
    [UNCHECKED]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 99 } } }),
  });
  // Allowlist includes S, S2, RIG (must be excluded), and does NOT include UNCHECKED or H.
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [S, S2, RIG];

  // 1. Lowest turns wins: S2 (0) beats S1 (2); RIG and UNCHECKED never chosen.
  const m1 = message({ text: "<@UBOT> task 1", threadTs: "3001.1", ts: "3001.1" });
  await h.connects.receive("cl", { type: "message", message: m1 });
  await settle();
  assert.equal(h.rig.store.connectThreadStation("cl", m1.channel, m1.threadTs), S2);
  assert.equal(rigSt.rig.store.listSessions().length, 0);
  assert.equal(unchecked.rig.store.listSessions().length, 0);

  // 2. Equal turns (0 == 0): higher available memory ratio wins (S1 80% > S2 40%).
  s1Turns = 0;
  s2Turns = 0;
  const m2 = message({ text: "<@UBOT> task 2", threadTs: "3001.2", ts: "3001.2" });
  await h.connects.receive("cl", { type: "message", message: m2 });
  await settle();
  assert.equal(h.rig.store.connectThreadStation("cl", m2.channel, m2.threadTs), S);

  // 3. Equal turns AND equal memory: round-robin alternates S2 -> S1 -> S2.
  s1Avail = 50;
  s2Avail = 50;
  const m3 = message({ text: "<@UBOT> task 3", threadTs: "3001.3", ts: "3001.3" });
  await h.connects.receive("cl", { type: "message", message: m3 });
  await settle();
  const m4 = message({ text: "<@UBOT> task 4", threadTs: "3001.4", ts: "3001.4" });
  await h.connects.receive("cl", { type: "message", message: m4 });
  await settle();
  const m5 = message({ text: "<@UBOT> task 5", threadTs: "3001.5", ts: "3001.5" });
  await h.connects.receive("cl", { type: "message", message: m5 });
  await settle();
  assert.deepEqual(
    [
      h.rig.store.connectThreadStation("cl", m3.channel, m3.threadTs),
      h.rig.store.connectThreadStation("cl", m4.channel, m4.threadTs),
      h.rig.store.connectThreadStation("cl", m5.channel, m5.threadTs),
    ],
    [S2, S, S2],
  );
  assert.equal(unchecked.rig.store.listSessions().length, 0, "unchecked station must never receive a session");
  assert.equal(rigSt.rig.store.listSessions().length, 0, "tasks-only rig must never receive a session");
  await close();
});

test("multi-station allowlist: simultaneous arrivals spread across pool via inflight count", async () => {
  const gate = Promise.withResolvers<void>();
  const { h, s1, s2, close } = multiWorkspace({
    // S1 has strictly higher memory so without inflight tracking both simultaneous messages would hit S1.
    [S]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 90 } } }),
    [S2]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 50 } } }),
  });
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [S, S2];
  // Hold the first forward to S1 until the second message has already picked its station.
  const origHandle = s1.bus.handle.bind(s1.bus);
  let heldOnce = false;
  s1.bus.handle = async (ws, from, req) => {
    if (req?.method === "connect.event" && !heldOnce) {
      heldOnce = true;
      await gate.promise;
    }
    return origHandle(ws, from, req);
  };
  const m1 = message({ text: "<@UBOT> burst 1", threadTs: "3002.1", ts: "3002.1" });
  const m2 = message({ text: "<@UBOT> burst 2", threadTs: "3002.2", ts: "3002.2" });
  const p1 = h.connects.receive("cl", { type: "message", message: m1 });
  const p2 = h.connects.receive("cl", { type: "message", message: m2 });
  await new Promise<void>((r) => setImmediate(r));
  gate.resolve();
  await Promise.all([p1, p2]);
  await settle();
  const picked = [
    h.rig.store.connectThreadStation("cl", m1.channel, m1.threadTs),
    h.rig.store.connectThreadStation("cl", m2.channel, m2.threadTs),
  ].sort();
  assert.deepEqual(picked, [S, S2].sort(), "simultaneous messages must spread across S1 and S2");
  await close();
});

test("multi-station allowlist: primary forward failure falls over to next allowlisted station; if all unreachable and here is not allowlisted, refuses local fallback", async () => {
  const { h, s1, s2, close } = multiWorkspace({
    [S]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 90 } } }),
    [S2]: () => ({ sessions: true, load: { running: { turns: 1 }, memory: { totalBytes: 100, availableBytes: 50 } } }),
  });
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [S, S2];

  // Primary (S1) fails on connect.event -> must fail over to S2.
  const origHandle = s1.bus.handle.bind(s1.bus);
  s1.bus.handle = async (ws, from, req) => {
    if (req?.method === "connect.event") throw new Error("forward failed");
    return origHandle(ws, from, req);
  };
  const m1 = message({ text: "<@UBOT> failover", threadTs: "3003.1", ts: "3003.1" });
  await h.connects.receive("cl", { type: "message", message: m1 });
  await settle();
  assert.equal(h.rig.store.connectThreadStation("cl", m1.channel, m1.threadTs), S2);

  // All allowlisted stations offline and H is NOT in allowlist -> MUST NOT fall back to H!
  s1.up = false;
  s2.up = false;
  const beforeSessions = h.rig.store.listSessions().length;
  const m2 = message({ text: "<@UBOT> nobody home", threadTs: "3003.2", ts: "3003.2" });
  await h.connects.receive("cl", { type: "message", message: m2 });
  await settle();
  assert.equal(h.rig.store.listSessions().length, beforeSessions, "must never start session on non-allowlisted H");
  assert.equal(h.rig.store.connectThreadStation("cl", m2.channel, m2.threadTs), null);
  assert.match(h.rig.chat.lastText(), /worker-s1/);
  assert.match(h.rig.chat.lastText(), /worker-s2/);

  // When H IS explicitly in the allowlist and remote peers are offline -> falls back to H.
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [S, H];
  const m3 = message({ text: "<@UBOT> local allowed", threadTs: "3003.3", ts: "3003.3" });
  await h.connects.receive("cl", { type: "message", message: m3 });
  await settle();
  assert.ok(h.rig.store.getSession(sessionKey("cl", m3.channel, m3.threadTs)), "H is in allowlist so local fallback is allowed");
  await close();
});

test("connect move preserves stations allowlist; PUT /connects/:id and overview handle single/multi/empty/preserve cleanly", async () => {
  const { h, s, close } = workspace();
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [H, S];
  await h.connects.move("cl", S, "ws");
  const moved = s.rig.raw.connects.find((c: Json) => c.id === `cl@${H}`);
  assert.deepEqual(moved.stations, [H, S], "stations allowlist moves intact with connect entry");

  // Exercise PUT /connects/:id and overview startsOn / startsOnStations directly.
  const viewer = { sub: "u1", email: "a@example.com", name: "Ada", role: "owner" as const, workspace: "ws", home: true, device: "d1" };
  const edits = connectEdits({
    config: { raw: () => s.rig.raw, updateSoon: async (f: (r: Json) => void) => f(s.rig.raw) } as never,
    data: s.rig.dir,
    hub: () => s.rig.hub,
    overview: (v, lang) => overview({ store: s.rig.store, hub: s.rig.hub, cloud: { state: null, membership: () => null, reached: true } as never, config: () => s.rig.raw }, v, lang),
    entry: () => undefined,
  });
  const req = { viewer, lang: "en" as const, path: "/connects/cl2" } as never;
  const ovMulti: any = await edits.putConnect(req, "cl2", { bind: { runtime: "claude" }, stations: [" s1 ", "s2", "s1", ""] });
  const cMulti = ovMulti.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cMulti.startsOn, "s1");
  assert.deepEqual(cMulti.startsOnStations, ["s1", "s2"]);
  assert.deepEqual(s.rig.raw.connects.find((c: Json) => c.id === "cl2").stations, ["s1", "s2"]);

  // Partial update omitting station/stations preserves both.
  const ovKept: any = await edits.putConnect(req, "cl2", { enabled: false });
  const cKept = ovKept.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cKept.startsOn, "s1");
  assert.deepEqual(cKept.startsOnStations, ["s1", "s2"]);

  // Single station via stations: ["s2"] writes station="s2" and drops stations.
  const ovOne: any = await edits.putConnect(req, "cl2", { stations: ["s2"] });
  const cOne = ovOne.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cOne.startsOn, "s2");
  assert.deepEqual(cOne.startsOnStations, ["s2"]);
  assert.equal(s.rig.raw.connects.find((c: Json) => c.id === "cl2").stations, undefined);

  // Empty stations: [] clears both.
  const ovEmpty: any = await edits.putConnect(req, "cl2", { stations: [] });
  const cEmpty = ovEmpty.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cEmpty.startsOn, null);
  assert.equal(cEmpty.startsOnStations, null);

  // Legacy single `station` clears old `stations`.
  await edits.putConnect(req, "cl2", { stations: ["s1", "s2"] });
  const ovLegacy: any = await edits.putConnect(req, "cl2", { station: "s3" });
  const cLegacy = ovLegacy.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cLegacy.startsOn, "s3");
  assert.deepEqual(cLegacy.startsOnStations, ["s3"]);
  assert.equal(s.rig.raw.connects.find((c: Json) => c.id === "cl2").stations, undefined);

  // Workspace-prefixed addresses from older clients ("ws1/s1", "ws1/s2") are normalized to bare station ids.
  const ovPrefixed: any = await edits.putConnect(req, "cl2", { stations: ["ws1/s1", "ws1/s2", "s1"] });
  const cPrefixed = ovPrefixed.connects.find((c: Json) => c.id === "cl2");
  assert.equal(cPrefixed.startsOn, "s1");
  assert.deepEqual(cPrefixed.startsOnStations, ["s1", "s2"]);
  assert.deepEqual(s.rig.raw.connects.find((c: Json) => c.id === "cl2").stations, ["s1", "s2"]);
  await close();
});

test("multi-station allowlist: workspace-prefixed station addresses in config are normalized to bare ids before dispatch", async () => {
  const { h, s1, s2, close } = multiWorkspace({
    [S]: () => ({ sessions: true, load: { running: { turns: 1 }, memory: { totalBytes: 100, availableBytes: 50 } } }),
    [S2]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 50 } } }),
  });
  h.rig.raw.connects.find((c: Json) => c.id === "cl").stations = [`ws/${S}`, `ws/${S2}`];
  const m = message({ text: "<@UBOT> prefixed config", threadTs: "3004.1", ts: "3004.1" });
  await h.connects.receive("cl", { type: "message", message: m });
  await settle();
  assert.equal(h.rig.store.connectThreadStation("cl", m.channel, m.threadTs), S2);
  assert.ok(s2.rig.store.getSession(sessionKey(`cl@${H}`, m.channel, m.threadTs)));
  assert.equal(s1.rig.store.listSessions().length, 0);
  await close();
});

test("PUT /connects/:id restricts station routing changes to workspace owners/admins (403) and supports autoStation", async () => {
  const { s, close } = workspace();
  const owner = { sub: "u1", email: "owner@example.com", name: "Owner", role: "owner" as const, workspace: "ws", home: true, device: "d1" };
  const member = { sub: "u2", email: "member@example.com", name: "Member", role: "member" as const, workspace: "ws", home: true, device: "d2" };
  const edits = connectEdits({
    config: { raw: () => s.rig.raw, updateSoon: async (f: (r: Json) => void) => f(s.rig.raw) } as never,
    data: s.rig.dir,
    hub: () => s.rig.hub,
    overview: (v, lang) => overview({ store: s.rig.store, hub: s.rig.hub, cloud: { state: null, membership: () => null, reached: true } as never, config: () => s.rig.raw }, v, lang),
    entry: () => undefined,
  });
  const ownerReq = { viewer: owner, lang: "en" as const, path: "/connects/c-perm" } as never;
  const memberReq = { viewer: member, lang: "en" as const, path: "/connects/c-perm" } as never;

  // Owner creates connect with autoStation: true -> overview emits startsOnAuto: true, startsOn/startsOnStations null.
  const ovAuto: any = await edits.putConnect(ownerReq, "c-perm", { bind: { runtime: "claude" }, autoStation: true });
  const cAuto = ovAuto.connects.find((c: Json) => c.id === "c-perm");
  assert.equal(cAuto.startsOnAuto, true);
  assert.equal(cAuto.startsOn, null);
  assert.equal(cAuto.startsOnStations, null);
  assert.equal(s.rig.raw.connects.find((c: Json) => c.id === "c-perm").autoStation, true);

  // Member editing non-routing field (enabled) succeeds and preserves autoStation: true.
  const ovNonRoute: any = await edits.putConnect(memberReq, "c-perm", { enabled: false });
  const cNonRoute = ovNonRoute.connects.find((c: Json) => c.id === "c-perm");
  assert.equal(cNonRoute.enabled, false);
  assert.equal(cNonRoute.startsOnAuto, true);

  // Member changing autoStation / stations / station is refused with 403.
  await assert.rejects(() => edits.putConnect(memberReq, "c-perm", { autoStation: false }), (e: any) => e?.status === 403);
  await assert.rejects(() => edits.putConnect(memberReq, "c-perm", { stations: ["s1", "s2"] }), (e: any) => e?.status === 403);
  await assert.rejects(() => edits.putConnect(memberReq, "c-perm", { station: "s1" }), (e: any) => e?.status === 403);

  // Member creating a new connect with non-default routing is refused with 403.
  await assert.rejects(() => edits.putConnect(memberReq, "c-member-new", { bind: { runtime: "claude" }, autoStation: true }), (e: any) => e?.status === 403);

  // Invalid autoStation type returns 400.
  await assert.rejects(() => edits.putConnect(ownerReq, "c-perm", { autoStation: "yes" }), (e: any) => e?.status === 400);

  // Owner switching from autoStation: true to manual stations clears autoStation.
  const ovManual: any = await edits.putConnect(ownerReq, "c-perm", { stations: ["s1", "s2"] });
  const cManual = ovManual.connects.find((c: Json) => c.id === "c-perm");
  assert.equal(cManual.startsOnAuto, undefined);
  assert.deepEqual(cManual.startsOnStations, ["s1", "s2"]);
  assert.equal(s.rig.raw.connects.find((c: Json) => c.id === "c-perm").autoStation, undefined);
  await close();
});

test("autoStation: dispatches only to online stations with acceptAutoChats===true && mode!=='tasks' by live load, and refuses fallback when 0 allowlisted are online", async () => {
  const { h, s1, s2, rigSt, close } = multiWorkspace({
    [H]: () => ({ sessions: true, acceptAutoChats: false, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 95 } } }),
    [S]: () => ({ sessions: true, acceptAutoChats: true, load: { running: { turns: 2 }, memory: { totalBytes: 100, availableBytes: 50 } } }),
    [S2]: () => ({ sessions: true, acceptAutoChats: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 60 } } }),
    [RIG]: () => ({ sessions: true, mode: "tasks", acceptAutoChats: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 99 } } }),
  });
  const entry = h.rig.raw.connects.find((c: Json) => c.id === "cl");
  entry.autoStation = true;
  delete entry.station;
  delete entry.stations;

  // S2 has acceptAutoChats: true and lowest load (0 turns); H has acceptAutoChats: false and RIG is mode: "tasks".
  const m1 = message({ text: "<@UBOT> auto balance 1", threadTs: "4001.1", ts: "4001.1" });
  await h.connects.receive("cl", { type: "message", message: m1 });
  await settle();
  assert.equal(h.rig.store.connectThreadStation("cl", m1.channel, m1.threadTs), S2);
  assert.ok(s2.rig.store.getSession(sessionKey(`cl@${H}`, m1.channel, m1.threadTs)));
  assert.equal(h.rig.store.listSessions().length, 0, "must not route to H when H.acceptAutoChats is false");
  assert.equal(rigSt.rig.store.listSessions().length, 0, "must not route to tasks-only RIG");
  await close();

  // Hard invariant: when 0 stations return acceptAutoChats: true, refuse dispatch and NEVER fall back to H.
  const none = multiWorkspace({
    [H]: () => ({ sessions: true, acceptAutoChats: false, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 95 } } }),
    [S]: () => ({ sessions: true, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 90 } } }),
    [S2]: () => ({ sessions: true, acceptAutoChats: false, load: { running: { turns: 0 }, memory: { totalBytes: 100, availableBytes: 90 } } }),
  });
  none.h.rig.raw.connects.find((c: Json) => c.id === "cl").autoStation = true;
  const m2 = message({ text: "<@UBOT> auto none", threadTs: "4002.1", ts: "4002.1" });
  await none.h.connects.receive("cl", { type: "message", message: m2 });
  await settle();
  assert.equal(none.h.rig.store.listSessions().length, 0, "must NOT fall back to local H when 0 allowlisted stations are online");
  assert.equal(none.s1.rig.store.listSessions().length, 0);
  assert.equal(none.s2.rig.store.listSessions().length, 0);
  assert.match(none.h.rig.chat.lastText(), /⚠️/, "should post away notice when no allowlisted station is reachable");
  await none.close();
});
