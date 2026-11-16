// The group connect (src/group): the station as a member of an IM server of AFK-surf/group, against a server of its
// protocol built of the mesh's own door, wire and event log (test/group-im.ts), on a mesh in memory (and once on the
// addon's endpoints on 127.0.0.1, where it is here), through a hub with scripted runtimes: joined by a code that is
// then taken out of config.json, a private chat's every message and a group's mentions waking its agent, the rest of a
// group going to the session that follows it until chat_leave, its answers and files going there, a person's files
// fetched, and what was said while the link was down (or the station stopped) taken once.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import type { Endpoints } from "../src/mesh/endpoint.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { type GroupParts, codeHash, makeGroup } from "../src/group/index.ts";
import { codeOf, groupEntryIn } from "../src/api/routes/group.ts";
import { showEnded } from "../src/connects/card-ends.ts";
import { fingerprint } from "../src/connects/workspace.ts";
import { cardWords, imageSize, mentions } from "../src/group/surface.ts";
import { parseThreadAddress } from "../src/agents/instructions.ts";
import type { ChatEvent } from "../src/sessions/chat.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { ImServer } from "./group-im.ts";
import { memoryMesh } from "./memory-mesh.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

type Json = any;

/// Once `f` holds, the station and the server going on meanwhile; fails saying `what` if it never does.
async function until(what: string, f: () => boolean) {
  for (let i = 0; i < 4000; i++) {
    if (f()) return;
    await settle(2);
  }
  throw new Error(`never: ${what}`);
}

/// A station's hub and its group connect `g` to a server of the test's, joined by a code.
async function world(mesh: Endpoints) {
  const t = testClock();
  const rig = new Rig();
  const server = new ImServer(await mesh.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" }));
  const ada = server.member("Ada", true);
  const bo = server.member("Bo");
  const code = server.code();
  const key = randomBytes(32).toString("hex");
  writeFileSync(join(rig.dir, "config.json"), JSON.stringify({ connects: [{ id: "g", kind: "group", group: { server: server.endpoint.id(), relays: ["https://relay.test"], key, code, botName: "Claude" }, bind: { runtime: "claude" } }] }));
  const config = new ConfigFile(rig.dir);
  rig.edit((raw) => raw.connects.push({ id: "g", kind: "group", bind: { runtime: "claude" } }));
  const heard: ChatEvent[] = [];
  let group: GroupParts;
  const start = async () => {
    group = makeGroup({
      data: rig.dir, store: rig.store, config, bound: () => true, clock: t.clock, endpoints: () => mesh,
      receive: (c, e) => (heard.push(e), rig.hub.receive(c, e)),
    });
    await rig.hub.shutdown();
    rig.hub = rig.newHub({ chats: (id) => (id === "g" ? group.chats(id) : undefined) });
    await group.reconcile();
    await until("connected", () => group.state("g")?.state === "connected");
  };
  await start();
  // (a card that stopped waiting changed where it shows, as the connects' part does: connects/part.ts)
  const unshown = rig.store.subscribe((change) => showEnded(rig.store, (id) => (id === "g" ? group.chats(id) : undefined), change));
  const me = () => String((config.raw().connects[0].group ?? {}).memberId ?? "");
  return {
    t, rig, server, ada, bo, code, key, config, heard, me,
    group: () => group,
    start,
    texts: (conv: string) => rig.store.messagesBefore(rig.store.threadAt("group:g", conv, conv)!.id, null, 50).map((m) => m.text),
    close: async () => {
      unshown();
      await group.close();
      await rig.close();
      await server.close();
    },
  };
}

test("the words: a mention of the bot by its name, a card's question as words, a code and a thread's address as written", () => {
  assert.equal(mentions("@Claude 看看", "Claude"), true);
  assert.equal(mentions("hi @claude, look", "Claude"), true, "in any case");
  assert.equal(mentions("@Claudette 看看", "Claude"), false, "not the start of a longer name");
  assert.equal(mentions("mail claude@x.test", "Claude"), false);
  assert.equal(mentions("@机器人帮忙", "机器人"), true);
  const { words, options } = cardWords("合并吗？", { type: "options", options: [{ label: "合并" }, { label: "先不", detail: "留着" }] }, "zh");
  assert.deepEqual(options, ["合并", "先不"]);
  assert.equal(words, "合并吗？\n\n1. 合并\n2. 先不\n\n回复编号或选项文字即可回答。");
  assert.equal(codeOf("abcd efgh-jkmn-pqrs"), "ABCD-EFGH-JKMN-PQRS");
  assert.equal(codeOf("ABCD-EFGH-JKMN-PQR1"), null, "1 is none of a code's letters");
  assert.deepEqual(parseThreadAddress("0123456789abcdef/0123456789abcdef"), ["0123456789abcdef", "0123456789abcdef"]);
  assert.equal(parseThreadAddress("0123456789abcdef/fedcba9876543210"), null);
});

/// A PNG's head of so many pixels (its signature and IHDR: all a size is read of).
function pngOf(width: number, height: number): Buffer {
  const b = Buffer.alloc(33);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(b, 0);
  b.writeUInt32BE(13, 8);
  b.write("IHDR", 12, "ascii");
  b.writeUInt32BE(width, 16);
  b.writeUInt32BE(height, 20);
  b[24] = 8;
  b[25] = 6;
  return b;
}

test("a picture's size read of its head (PNG, GIF, JPEG, WebP), none of what is not one; a group connect known across the workspace by its key", () => {
  assert.deepEqual(imageSize(pngOf(120, 60)), { width: 120, height: 60 });
  const gif = Buffer.alloc(13);
  gif.write("GIF89a", 0, "ascii");
  gif.writeUInt16LE(31, 6);
  gif.writeUInt16LE(17, 8);
  assert.deepEqual(imageSize(gif), { width: 31, height: 17 });
  // (a JPEG: SOI, an APP0 of 16, then SOF2, progressive: its height before its width)
  const app0 = [0xff, 0xe0, 0x00, 0x10, ...Buffer.from("JFIF\0"), 1, 1, 0, 0, 1, 0, 1, 0, 0];
  const jpeg = Buffer.from([0xff, 0xd8, ...app0, 0xff, 0xc2, 0x00, 0x11, 0x08, 0x01, 0xe0, 0x02, 0x80, 0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
  assert.deepEqual(imageSize(jpeg), { width: 640, height: 480 });
  const webp = (chunk: string, body: number[]) => {
    const b = Buffer.alloc(40);
    b.write("RIFF", 0, "ascii");
    b.writeUInt32LE(32, 4);
    b.write("WEBP", 8, "ascii");
    b.write(chunk, 12, "ascii");
    Buffer.from(body).copy(b, 20);
    return b;
  };
  // (VP8: a key frame's tag, its start code, 14 bits a side)
  assert.deepEqual(imageSize(webp("VP8 ", [0, 0, 0, 0x9d, 0x01, 0x2a, 0x90, 0x01, 0xc8, 0x00])), { width: 400, height: 200 });
  // (VP8L: its signature, then width-1 and height-1 in 14 bits each)
  const lossless = ((100 - 1) | ((50 - 1) << 14)) >>> 0;
  assert.deepEqual(imageSize(webp("VP8L", [0x2f, lossless & 0xff, (lossless >> 8) & 0xff, (lossless >> 16) & 0xff, (lossless >>> 24) & 0xff])), { width: 100, height: 50 });
  // (VP8X: flags, three bytes kept, then width-1 and height-1 in 24 bits each)
  assert.deepEqual(imageSize(webp("VP8X", [0, 0, 0, 0, 0x1f, 0x4e, 0x00, 0x0f, 0x27, 0x00])), { width: 20000, height: 10000 });
  assert.equal(imageSize(Buffer.from("png-bytes")), null);
  assert.equal(imageSize(pngOf(0, 60)), null, "a side of none is no size");
  assert.equal(imageSize(Buffer.from([0xff, 0xd8, 0xff, 0xd9])), null, "a JPEG with no frame");

  const one = fingerprint("group", { server: "a".repeat(64), key: "k1" });
  assert.match(one ?? "", /^[0-9a-f]{64}$/);
  assert.equal(fingerprint("group", { server: "b".repeat(64), key: "k1" }), one, "by its key alone");
  assert.notEqual(fingerprint("group", { key: "k2" }), one);
  assert.equal(fingerprint("group", { server: "a".repeat(64) }), null, "none before it has a key");
});

test("a card's numbers stand only while it waits: a person's next message closes it, so does its end on the station, and a card posted since keeps its own; a picture the agent posts goes with its size", { timeout: 60_000 }, async () => {
  const w = await world(memoryMesh());
  try {
    const me = w.me();
    const dm = w.server.private_(w.ada, me);
    const key = sessionKey("g", dm, dm);
    const to = `${dm}/${dm}`;
    const heardAs = (n: number) => {
      const m = w.heard.find((e) => e.type === "message" && e.message.ts === String(n));
      return m?.type === "message" ? m.message.text : undefined;
    };
    const said = (text: string) => w.server.say(dm, w.ada, text).n;
    const turn = async (f: () => Promise<unknown>) => {
      await w.rig.quiet();
      const agent = w.rig.claude.last();
      agent.reads();
      await f();
      agent.complete();
      await w.rig.quiet();
    };
    const card = (text: string, labels: string[]) =>
      w.rig.call(key, "chat_post", { to, text, card: { type: "options", options: labels.map((label) => ({ label })) }, kind: "need_human", need: "选一个" });
    said("开始");
    await until("its session", () => w.rig.store.getSession(key) !== null);

    // ── answered by something else first: the next "1" is a "1"
    await turn(() => card("要重跑吗？", ["重跑", "先不"]));
    const wait = said("先等等");
    await until("heard", () => heardAs(wait) !== undefined);
    assert.equal(heardAs(wait), "先等等");
    const late = said("1");
    await until("heard", () => heardAs(late) !== undefined);
    assert.equal(heardAs(late), "1", "the card was closed by the message before");

    // ── a number right after it is its option
    await turn(() => card("要重跑吗？", ["重跑", "先不"]));
    const now = said("2");
    await until("heard", () => heardAs(now) !== undefined);
    assert.equal(heardAs(now), "先不");

    // ── withdrawn on the station: a number after is a number
    let ts = "";
    await turn(async () => {
      await card("合并吗？", ["合并", "先不"]);
      ts = String(w.server.conversations.get(dm)!.messages.at(-1)!.n);
      await w.rig.call(key, "chat_post", { to, withdraw: ts });
    });
    const after = said("1");
    await until("heard", () => heardAs(after) !== undefined);
    assert.equal(heardAs(after), "1", "the withdrawn card's numbers are gone");

    // ── a card replaced by another: the old one's end leaves the new one's numbers
    await turn(async () => {
      await card("先选环境", ["测试", "正式"]);
      await card("再选分支", ["main", "beta"]);
    });
    const picked = said("2");
    await until("heard", () => heardAs(picked) !== undefined);
    assert.equal(heardAs(picked), "beta");

    // ── a picture the agent posts: its size said to the server as it is uploaded
    await turn(async () => {
      const room = w.rig.session(key).workspace;
      mkdirSync(room, { recursive: true });
      writeFileSync(join(room, "wide.png"), pngOf(120, 60));
      writeFileSync(join(room, "notes.txt"), "not a picture\n");
      await w.rig.call(key, "chat_post", { to, text: "截图", files: [join(room, "wide.png"), join(room, "notes.txt")] });
    });
    const shot = w.server.conversations.get(dm)!.messages.at(-1)!;
    assert.equal(shot.text, "截图");
    assert.deepEqual(shot.files?.map((f) => [f.name, f.width, f.height]), [["wide.png", 120, 60], ["notes.txt", undefined, undefined]]);
  } finally {
    await w.close();
  }
});

test("a connect's part as the pages edit it: its key made once, a new server forgetting who it was there, what is wrong refused", () => {
  const entry = groupEntryIn("en");
  const server = "a".repeat(64);
  const made = entry({ server, relays: "https://r1.test\nhttps://r2.test", code: "abcd-efgh-jkmn-pqrs", botName: " Claude " }, null)!;
  assert.match(made.key, /^[0-9a-f]{64}$/);
  assert.deepEqual({ ...made, key: "k" }, { server, relays: ["https://r1.test", "https://r2.test"], code: "ABCD-EFGH-JKMN-PQRS", botName: "Claude", key: "k" });
  const joined = { ...made, memberId: "m1", name: "Claude", bound: codeHash(made.code) };
  delete (joined as Json).code;
  assert.deepEqual(entry({ botName: "Codex" }, joined), { ...joined, botName: "Codex" }, "the key and who it is kept");
  const moved = entry({ server: "b".repeat(64), code: "ABCDEFGHJKMNPQRS" }, joined)!;
  assert.equal(moved.key, made.key);
  assert.equal(moved.memberId, undefined, "another server: who it was there goes");
  assert.throws(() => entry({ server: "nope", relays: ["https://r.test"], code: "ABCDEFGHJKMNPQRS" }, null), /64-character hex/);
  assert.throws(() => entry({ server, relays: ["ftp://r.test"], code: "ABCDEFGHJKMNPQRS" }, null), /https:\/\//);
  assert.throws(() => entry({ server, relays: ["https://r.test"] }, null), /join code/);
  assert.throws(() => entry({ server, relays: ["https://r.test"], code: "ABC" }, null), /16 letters/);
});

test("joined by its code, then as its key alone; a private chat's every message and a group's mentions wake its agent, the rest of the group follows the session until chat_leave; its answers, cards and files go there, a person's files come", { timeout: 60_000 }, async () => {
  const w = await world(memoryMesh());
  try {
    // ── joined: the code said once, as the name asked; then out of config.json, its hash kept, the key as it was
    assert.deepEqual(w.server.hellos[0], { credential: w.code, name: "Claude" });
    const me = w.me();
    assert.ok(me !== "" && w.server.members.get(me)?.name === "Claude");
    await until("its code out of config.json", () => w.config.raw().connects[0].group.code === undefined);
    const part = w.config.raw().connects[0].group;
    assert.deepEqual([part.bound, part.key, part.name], [codeHash(w.code), w.key, "Claude"]);
    assert.equal(w.group().state("g")?.state, "connected", "not connected again for its code going");
    assert.equal(w.server.hellos.length, 1);

    // ── a private chat: every message calls the agent
    const dm = w.server.private_(w.ada, me);
    w.server.say(dm, w.ada, "帮我看下 CI");
    await until("the private chat's session", () => w.rig.store.getSession(sessionKey("g", dm, dm)) !== null);
    const dmKey = sessionKey("g", dm, dm);
    await w.rig.quiet();
    assert.ok(w.rig.claude.last().prompts[0]!.includes("帮我看下 CI"));
    assert.match(w.rig.claude.last().prompts[0]!, new RegExp(`<message via="group" connect="g"[^>]* thread="${dm}/${dm}"`));
    w.rig.claude.last().reads();
    assert.ok((await w.rig.call(dmKey, "chat_post", { to: `${dm}/${dm}`, text: "在看了", kind: "all_done", done: "已在私聊里回复：在看了" })).startsWith(`Posted to ${dm}/${dm}`));
    const dmConv = w.server.conversations.get(dm)!;
    assert.deepEqual(dmConv.messages.map((m) => [m.from === me, m.text]), [[false, "帮我看下 CI"], [true, "在看了"]]);
    w.rig.claude.last().complete();
    await w.rig.quiet();

    // ── a group: chatter wakes nothing; a mention does; what follows goes to that session
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    w.server.say(team, w.bo, "今天吃什么");
    await until("the chatter heard", () => w.heard.some((e) => e.type === "message" && e.message.text === "今天吃什么"));
    await w.rig.quiet();
    assert.equal(w.rig.store.threadAt("group:g", team, team), null, "no session follows a group nobody mentioned it in");
    w.server.say(team, w.ada, "@Claude 发布卡住了");
    const key = sessionKey("g", team, team);
    await until("the group's session", () => w.rig.store.getSession(key) !== null);
    await w.rig.quiet();
    const agent = w.rig.claude.last();
    assert.ok(agent.prompts[0]!.includes("@Claude 发布卡住了"));
    w.server.say(team, w.bo, "日志在这");
    await until("what follows reached it", () => w.texts(team).includes("日志在这"));
    await w.rig.quiet();
    assert.ok([...agent.prompts, ...agent.steers].some((p) => p.includes("日志在这")), "the session that follows it has it");

    // ── its answer with a file, and a card as words, answered by its number
    agent.reads();
    const room = w.rig.session(key).workspace;
    mkdirSync(room, { recursive: true });
    writeFileSync(join(room, "report.txt"), "all green\n");
    assert.ok((await w.rig.call(key, "chat_post", { to: `${team}/${team}`, text: "日志看完了", files: [join(room, "report.txt")] })).startsWith(`Posted to ${team}/${team}`));
    const teamConv = w.server.conversations.get(team)!;
    const answer = teamConv.messages.at(-1)!;
    assert.deepEqual([answer.from, answer.text, answer.files?.map((f) => f.name)], [me, "日志看完了", ["report.txt"]]);
    assert.equal(teamConv.files.get(answer.files![0]!.id)!.bytes.toString(), "all green\n");
    await w.rig.call(key, "chat_post", { to: `${team}/${team}`, text: "要重跑吗？", card: { type: "options", options: [{ label: "重跑" }, { label: "先不" }] }, kind: "need_human", need: "选重跑或先不" });
    assert.equal(teamConv.messages.at(-1)!.text, "要重跑吗？\n\n1. 重跑\n2. 先不\n\n回复编号或选项文字即可回答。");
    agent.complete();
    await w.rig.quiet();
    w.server.say(team, w.ada, "1");
    await until("the answer recorded", () => w.texts(team).includes("重跑"));

    // ── a person's file is fetched into the session's uploads
    const shot = w.server.upload(team, "shot.png", "image/png", Buffer.from("png-bytes"));
    w.server.say(team, w.ada, "截图", { files: [shot.id] });
    await until("the file's message", () => w.texts(team).includes("截图"));
    const withFile = w.rig.store.messagesBefore(w.rig.store.threadAt("group:g", team, team)!.id, null, 50).find((m) => m.text === "截图")!;
    assert.equal(withFile.attachments.length, 1);
    assert.equal(readFileSync(withFile.attachments[0]!.path, "utf8"), "png-bytes");

    // ── chat_leave: the rest no longer reaches it, until it is mentioned again; the server still has it in the group
    await w.rig.quiet();
    assert.ok((await w.rig.call(key, "chat_leave", { to: `${team}/${team}` })).startsWith(`Left ${team}/${team}`));
    agent.complete();
    await w.rig.quiet();
    const before = [...agent.prompts, ...agent.steers].length;
    w.server.say(team, w.bo, "不用管了");
    await until("recorded", () => w.texts(team).includes("不用管了"));
    await w.rig.quiet();
    assert.equal(w.rig.store.pendingMessages(key).length, 0);
    assert.equal([...agent.prompts, ...agent.steers].length, before, "not handed to it");
    assert.ok(teamConv.members.includes(me), "never left on the server");
    assert.ok(!w.server.asked.some((a) => a.endsWith("/leave")));
    w.server.say(team, w.bo, "@claude 还得看一下");
    await until("back", () => [...agent.prompts, ...agent.steers].some((p) => p.includes("还得看一下")));

    // ── chat_history reads what was said before the station was brought in
    const old = w.server.group("Old", w.ada, [me]);
    w.server.say(old, w.ada, "以前的讨论");
    w.server.say(old, w.ada, "@Claude 接着看");
    const oldKey = sessionKey("g", old, old);
    await until("the old group's session", () => w.rig.store.getSession(oldKey) !== null);
    assert.ok((await w.rig.call(oldKey, "chat_history", { to: `${old}/${old}` })).includes("以前的讨论"));
  } finally {
    await w.close();
  }
});

test("what is said while the link is down, while the server forgot where the stream was, and while the station is stopped, is taken once; a group it is put in later keeps its history as history", { timeout: 60_000 }, async () => {
  const w = await world(memoryMesh());
  try {
    const me = w.me();
    const dm = w.server.private_(w.ada, me);
    w.server.say(dm, w.ada, "一");
    await until("one", () => w.heard.length === 1);
    const told = (text: string) => w.heard.filter((e) => e.type === "message" && e.message.text === text).length;

    // the link cut: what is said meanwhile comes as the stream goes on from where it was
    w.server.cut();
    w.server.say(dm, w.ada, "二");
    await until("two", () => told("二") === 1);
    assert.match(w.server.asked.filter((a) => a.startsWith("GET /events")).at(-1)!, /since=/);

    // the server's log let go: read again from the last message taken
    w.server.forget();
    w.server.cut();
    w.server.say(dm, w.ada, "三");
    await until("three", () => told("三") === 1);
    assert.ok(w.server.asked.some((a) => a.startsWith(`GET /conversations/${dm}/messages?after=2`)));

    // the station stopped and started again: from what it kept on the disk
    await w.group().close();
    w.server.say(dm, w.ada, "四");
    await w.start();
    await until("four", () => told("四") === 1);
    await settle();
    assert.deepEqual(["一", "二", "三", "四"].map(told), [1, 1, 1, 1], "each once");
    assert.equal(w.server.hellos.at(-1)!.credential, "", "its key alone, the code long used");

    // put in a group with a past: the past is not a request, what comes after is
    const old = w.server.group("Old", w.ada, [w.bo]);
    w.server.say(old, w.ada, "@Claude 早先的话");
    w.server.add(old, me);
    w.server.say(old, w.bo, "@Claude 现在的话");
    await until("now", () => told("@Claude 现在的话") === 1);
    assert.equal(told("@Claude 早先的话"), 0);
  } finally {
    await w.close();
  }
});

// The same over iroh itself: the addon's endpoints on this machine, dialled by address.
const addon = (() => {
  try {
    return loadMesh();
  } catch {
    return null;
  }
})();

test("over the mesh addon's own endpoints: joined, a private chat's message heard and answered", { timeout: 60_000, skip: addon === null && "no mesh addon here (node ../scripts/native.ts run mesh)" }, async () => {
  const mesh = addon!;
  // (dialled at the server's addresses on this machine: the relays in config.json are none the test runs)
  const t = testClock();
  const rig = new Rig();
  const server = new ImServer(await mesh.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/1")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" }));
  const ada = server.member("Ada", true);
  const { GroupSurface } = await import("../src/group/surface.ts");
  const { GroupThreads } = await import("../src/group/threads.ts");
  const threads = new GroupThreads(join(rig.dir, "group-threads.json"));
  const surface = new GroupSurface({
    connect: "g", server: server.endpoint.id(), relays: [], ips: server.endpoint.sockets().filter((s) => s.startsWith("127.0.0.1")),
    key: randomBytes(32).toString("hex"), code: server.code(), botName: "Claude", threads, endpoints: mesh, clock: t.clock,
  });
  try {
    const heard: ChatEvent[] = [];
    let first!: () => void;
    const firstHeard = new Promise<void>((resolve) => (first = resolve));
    let connected!: () => void;
    const up = new Promise<void>((resolve) => (connected = resolve));
    surface.onChange(() => surface.socket().connected && connected());
    await surface.start(async (e) => {
      heard.push(e);
      first();
    });
    await up;
    const me = surface.botUserId();
    assert.equal(server.members.get(me)?.name, "Claude");
    const dm = server.private_(ada, me);
    server.say(dm, ada, "你好");
    await firstHeard;
    assert.deepEqual(heard[0], { type: "message", message: { channel: dm, threadTs: dm, ts: "1", user: ada, text: "你好", addressed: true } });
    assert.equal(await surface.post({ channel: dm, threadTs: dm }, "你好，我在", []), "2");
    assert.equal(server.conversations.get(dm)!.messages[1]!.text, "你好，我在");
  } finally {
    await surface.stop();
    await threads.flushed();
    await rig.close();
    await server.close();
  }
});
