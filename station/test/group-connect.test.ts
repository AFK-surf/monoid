// The group connect (src/group): the station as a member of an IM community of AFK-surf/group (`im/2`), against an
// anchor of its protocol built of the mesh's own door and wire (test/group-im.ts), on a mesh in memory (and once on the
// addon's endpoints on 127.0.0.1, where it is here), through a hub with scripted runtimes: its events byte for byte
// the IM's (event.ts, held to vectors of canon.mbt's); joined by a code that is then taken out of config.json; a
// direct space's every message and a space's mentions waking its agent, each topic a session of its own, the rest
// going to the session that follows that stream until chat_leave; its answers, files and cards (decisions) going there,
// a decision's answer coming back; what it does said as the stream's live state, Stop stopping it; a secret handed end
// to end reaching the session as a file alone; and what was said while the link was down (or the station stopped)
// taken once.
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { mkdirSync, readFileSync, truncateSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";
import { ConfigFile } from "../src/ops/config.ts";
import type { Endpoints } from "../src/mesh/endpoint.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { type GroupParts, codeHash, makeGroup } from "../src/group/index.ts";
import { codeOf, groupEntryIn } from "../src/api/routes/group.ts";
import { showEnded } from "../src/connects/card-ends.ts";
import { fingerprint } from "../src/connects/workspace.ts";
import { canonicalJson, deviceOfKey, directId, eventId, moonOrder, signEvent, signedText, signingKey, stampedOf, verified } from "../src/group/event.ts";
import { FILE_MOST, type GroupSurface, PIECE, cardWords, decisionBody, imageSize, mentions, topicTitle } from "../src/group/surface.ts";
import { relay, relayPlaces } from "../src/sessions/relay.ts";
import { titleOf } from "../src/read/views.ts";
import { GroupThreads } from "../src/group/threads.ts";
import { parseThreadAddress } from "../src/agents/instructions.ts";
import type { ChatEvent } from "../src/sessions/chat.ts";
import { sessionKey } from "../src/sessions/hub.ts";
import { ImServer } from "./group-im.ts";
import { memoryMesh } from "./memory-mesh.ts";
import { Rig, settle, testClock } from "./hub-fakes.ts";

type Json = any;

/// Once `f` holds, the station and the anchor going on meanwhile; fails saying `what` if it never does.
async function until(what: string, f: () => boolean) {
  for (let i = 0; i < 4000; i++) {
    if (f()) return;
    await settle(2);
  }
  throw new Error(`never: ${what}`);
}

/// Once the surface has heard of `space` (it offers it to relay to).
async function known(surface: GroupSurface, space: string) {
  let ids: string[] = [];
  await until(`${space} heard`, () => {
    void surface.places().then((p) => (ids = p.map((x) => x.id)));
    return ids.includes(space);
  });
}

/// A station's hub and its group connect `g` to an anchor of the test's, joined by a code.
async function world(mesh: Endpoints = memoryMesh(), more: { threads?: Json } = {}) {
  const t = testClock();
  const rig = new Rig();
  const server = new ImServer(await mesh.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/2")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" }));
  const ada = server.member("Ada", true);
  const bo = server.member("Bo");
  const code = server.code();
  const key = randomBytes(32).toString("hex");
  if (more.threads !== undefined) writeFileSync(join(rig.dir, "group-threads.json"), JSON.stringify(more.threads));
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
  const threadOf = (space: string, topic?: string) => rig.store.threadAt("group:g", space, topic ?? space);
  return {
    t, rig, server, ada, bo, code, key, config, heard, me, mesh,
    group: () => group,
    start,
    texts: (space: string, topic?: string) => rig.store.messagesBefore(threadOf(space, topic)!.id, null, 50).map((m) => m.text),
    told: (text: string) => heard.filter((e) => e.type === "message" && e.message.text === text).length,
    close: async () => {
      unshown();
      await group.close();
      await rig.close();
      await server.close();
    },
  };
}

test("an event byte for byte as the IM's canon.mbt and event.mbt make it: keys in MoonBit's order, its escapes, its id, a direct space's id", () => {
  // (what core/src/im/canon.mbt and event.mbt print for the same event, AFK-surf/group 032e2b8)
  const body = JSON.parse('{"text":"@Claude 看看 \\"CI\\"\\n\\ttab\\u0001 😀","input":"options","options":[{"label":"合并","detail":"现在","recommended":true},{"label":"先不"}],"placeholder":"","assignee":"","files":[],"reply_to":""}');
  const e = { space: "s_0123456789abcdef01234567", author: "m_00112233aabbccdd", device: "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c", dseq: 7, hlc: [1794882529815, 2] as [number, number], prev: "5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9", topic: "t_0011223344556677", kind: "decision.ask", body, v: 2 as const, enc: 0 as const };
  assert.equal(
    signedText(e),
    '{"v":2,"enc":0,"hlc":[1794882529815,2],"body":{"text":"@Claude 看看 \\"CI\\"\\n\\ttab\\u0001 😀","files":[],"input":"options","options":[{"label":"合并","detail":"现在","recommended":true},{"label":"先不"}],"assignee":"","reply_to":"","placeholder":""},"dseq":7,"kind":"decision.ask","prev":"5feceb66ffc86f38d952786c6d696c79c2dbc239dd4e91b46729d73a27fb57e9","space":"s_0123456789abcdef01234567","topic":"t_0011223344556677","author":"m_00112233aabbccdd","device":"8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c"}',
  );
  assert.equal(eventId(e), "b8b9ecd23e14a8a18f1df89c0a8660b577fd60a47ca4fd081f6a0ec10ed55950");
  assert.equal(directId("m_00112233aabbccdd", "m_ffeeddccbbaa9988"), "d_2518d7ef7594305b0568a1c0");
  assert.equal(directId("m_ffeeddccbbaa9988", "m_00112233aabbccdd"), "d_2518d7ef7594305b0568a1c0", "whoever asks first");
  // (MoonBit's order of strings: by length first, then by UTF-16 unit; what its canon printed of these keys)
  assert.equal(canonicalJson(JSON.parse('{"\\uffff\\uffff":1,"\\ud83d\\ude00":2,"ab":3,"B":4,"a":5,"\\u00e9":6}')), '{"B":4,"a":5,"é":6,"ab":3,"😀":2,"￿￿":1}');
  assert.equal(canonicalJson({ x: [1000, 0, -0, 12345678901234, 0.1], b: "\b\f\u001f\u007f" }), '{"b":"\\u0008\\u000c\\u001f\u007f","x":[1000,0,0,12345678901234,0.1]}');
  assert.ok(moonOrder("v", "body") < 0 && moonOrder("enc", "author") < 0);

  // signed by a device's key, checked as the anchor checks it; anything changed is not its signature, nor its id
  const key = signingKey(randomBytes(32).toString("hex"));
  assert.equal(verified(signEvent(key, { ...e, device: "8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c" })), false, "a device that is not the key's");
  const own = signEvent(key, { ...e, device: deviceOfKey(key) });
  assert.equal(verified(own), true);
  assert.equal(verified({ ...own, body: { ...own.body, text: "改过" } }), false);
  const stamped = { id: eventId(own), event: own, aseq: 3, n: 2, at: 9 };
  assert.deepEqual(stampedOf(JSON.parse(JSON.stringify(stamped))), stamped, "read off the wire as it was signed");
  assert.equal(stampedOf({ ...stamped, id: "0".repeat(64) }), null, "an id not its own");
});


test("the words: a mention of the bot by its name, a card as a decision and as words, a code and a stream's address as written", () => {
  assert.equal(mentions("@Claude 看看", "Claude"), true);
  assert.equal(mentions("hi @claude, look", "Claude"), true, "in any case");
  assert.equal(mentions("@Claudette 看看", "Claude"), false, "not the start of a longer name");
  assert.equal(mentions("mail claude@x.test", "Claude"), false);
  assert.equal(mentions("@机器人帮忙", "机器人"), true);
  const { words, options } = cardWords("合并吗？", { type: "options", options: [{ label: "合并" }, { label: "先不", detail: "留着" }] }, "zh");
  assert.deepEqual(options, ["合并", "先不"]);
  assert.equal(words, "合并吗？\n\n1. 合并\n2. 先不\n\n回复编号或选项文字即可回答。");
  assert.deepEqual(decisionBody("合并吗？", { type: "options", options: [{ label: "合并", recommended: true }, { label: "先不", detail: "留着" }, { label: " " }] }), {
    text: "合并吗？", input: "options", options: [{ label: "合并", recommended: true }, { label: "先不", detail: "留着" }], files: [],
  });
  assert.deepEqual(decisionBody("要 key", { type: "text", placeholder: "sk_test_..." }), { text: "要 key", input: "text", options: [], placeholder: "sk_test_...", files: [] });
  assert.equal(codeOf("abcd efgh-jkmn-pqrs"), "ABCD-EFGH-JKMN-PQRS");
  assert.equal(codeOf("ABCD-EFGH-JKMN-PQR1"), null, "1 is none of a code's letters");
  const space = "s_0123456789abcdef01234567";
  assert.deepEqual(parseThreadAddress(`${space}/${space}`), [space, space], "a space's lobby");
  assert.deepEqual(parseThreadAddress(`${space}/t_0011223344556677`), [space, "t_0011223344556677"], "one of its topics");
  assert.deepEqual(parseThreadAddress("d_0123456789abcdef01234567/d_0123456789abcdef01234567"), ["d_0123456789abcdef01234567", "d_0123456789abcdef01234567"]);
  assert.equal(parseThreadAddress(`${space}/s_fedcba9876543210fedcba98`), null);
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

test("what group-threads.json keeps: each space's place and this device's count, each stream's last; a file of im/1's read as nothing heard", async () => {
  const dir = new Rig().dir;
  const path = join(dir, "group-threads.json");
  writeFileSync(path, JSON.stringify({ g: { since: "41", last: { "0123456789abcdef": 7 } } }));
  const old = new GroupThreads(path);
  assert.deepEqual(old.spaces("g"), {}, "im/1's conversations are none of im/2's spaces");
  old.took("g", "s_1", 5, "s_1/t_1");
  old.said("g", "s_1", 3, "e3");
  old.said("g", "s_1", 3, "");
  old.said("g", "s_1", 2, "e2");
  old.said("g", "s_2", 4, "");
  await old.flushed();
  const again = new GroupThreads(path);
  assert.deepEqual(again.space("g", "s_1"), { aseq: 5, dseq: 3, prev: "e3" }, "never back, an id kept where none was said");
  assert.deepEqual(again.space("g", "s_2"), { aseq: 0, dseq: 4, prev: "" });
  assert.equal(again.last("g", "s_1/t_1"), 5);
  again.forget("g", "s_1");
  assert.equal(again.last("g", "s_1/t_1"), 0, "a space left takes its streams with it");
  await again.flushed();
});

test("joined by its code, then as its key alone; a direct space's every message and a space's mentions wake its agent, the rest follows the session until chat_leave; its answers and files go there, a person's files come; a member taken out is let go", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    // ── joined: the code said once, as the name asked; then out of config.json, its hash kept, the key as it was
    assert.deepEqual(w.server.hellos[0], { credential: w.code, name: "Claude" });
    const me = w.me();
    assert.ok(me.startsWith("m_") && w.server.members.get(me)?.name === "Claude");
    await until("its code out of config.json", () => w.config.raw().connects[0].group.code === undefined);
    const part = w.config.raw().connects[0].group;
    assert.deepEqual([part.bound, part.key, part.name], [codeHash(w.code), w.key, "Claude"]);
    assert.equal(w.group().state("g")?.state, "connected", "not connected again for its code going");
    assert.equal(w.server.hellos.length, 1);

    // ── a direct space: every message calls the agent; what it says is an event signed by its own device
    const dm = w.server.direct(w.ada, me);
    w.server.say(dm, w.ada, "帮我看下 CI");
    const dmKey = sessionKey("g", dm, dm);
    await until("the direct space's session", () => w.rig.store.getSession(dmKey) !== null);
    await w.rig.quiet();
    assert.ok(w.rig.claude.last().prompts[0]!.includes("帮我看下 CI"));
    assert.match(w.rig.claude.last().prompts[0]!, new RegExp(`<message via="group" connect="g"[^>]* thread="${dm}/${dm}"`));
    w.rig.claude.last().reads();
    assert.ok((await w.rig.call(dmKey, "chat_post", { to: `${dm}/${dm}`, text: "在看了", kind: "all_done", done: "已在私聊里回复：在看了" })).startsWith(`Posted to ${dm}/${dm}`));
    assert.deepEqual(w.server.messages(dm).map((m) => [m.author === me, m.text]), [[false, "帮我看下 CI"], [true, "在看了"]]);
    const mine = w.server.spaces.get(dm)!.events.at(-1)!;
    assert.equal(mine.event.device, await (w.group().chat("g") as unknown as { device(): Promise<string> }).device(), "signed by the connect's key");
    assert.deepEqual([mine.event.dseq, mine.event.prev], [1, ""], "its first in this space");
    w.rig.claude.last().complete();
    await w.rig.quiet();

    // ── a space: chatter wakes nothing; a mention does; what follows goes to that session
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    w.server.say(team, w.bo, "今天吃什么");
    await until("the chatter heard", () => w.told("今天吃什么") === 1);
    await w.rig.quiet();
    assert.equal(w.rig.store.threadAt("group:g", team, team), null, "no session follows a space nobody mentioned it in");
    w.server.say(team, w.ada, "@Claude 发布卡住了");
    const key = sessionKey("g", team, team);
    await until("the space's session", () => w.rig.store.getSession(key) !== null);
    await w.rig.quiet();
    const agent = w.rig.claude.last();
    assert.ok(agent.prompts[0]!.includes("@Claude 发布卡住了"));
    w.server.say(team, w.bo, "日志在这");
    await until("what follows reached it", () => w.texts(team).includes("日志在这"));
    await w.rig.quiet();
    assert.ok([...agent.prompts, ...agent.steers].some((p) => p.includes("日志在这")), "the session that follows it has it");

    // ── its answer with a file, a second message signed after the first
    agent.reads();
    const room = w.rig.session(key).workspace;
    mkdirSync(room, { recursive: true });
    writeFileSync(join(room, "report.txt"), "all green\n");
    writeFileSync(join(room, "wide.png"), pngOf(120, 60));
    assert.ok((await w.rig.call(key, "chat_post", { to: `${team}/${team}`, text: "日志看完了", files: [join(room, "report.txt"), join(room, "wide.png")] })).startsWith(`Posted to ${team}/${team}`));
    const answer = w.server.messages(team).at(-1)!;
    assert.deepEqual([answer.author, answer.text, answer.files.map((f: Json) => [f.name, f.width, f.height])], [me, "日志看完了", [["report.txt", undefined, undefined], ["wide.png", 120, 60]]]);
    assert.equal(w.server.spaces.get(team)!.files.get(answer.files[0].sha256)!.bytes.toString(), "all green\n");
    agent.complete();
    await w.rig.quiet();

    // ── a person's file is fetched into the session's uploads; an answer to the bot's message calls it too
    const shot = w.server.upload(team, w.ada, "shot.png", "image/png", Buffer.from("png-bytes"));
    w.server.say(team, w.ada, "截图", { files: [shot.sha256] });
    await until("the file's message", () => w.texts(team).includes("截图"));
    const withFile = w.rig.store.messagesBefore(w.rig.store.threadAt("group:g", team, team)!.id, null, 50).find((m) => m.text === "截图")!;
    assert.equal(withFile.attachments.length, 1);
    assert.equal(readFileSync(withFile.attachments[0]!.path, "utf8"), "png-bytes");

    // ── chat_leave: the rest no longer reaches it, until it is mentioned (or answered) again; the space keeps it
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
    assert.ok(w.server.spaces.get(team)!.members.includes(me), "never left on the anchor");
    w.server.say(team, w.bo, "这个结论对吗", { replyTo: answer.id });
    await until("back", () => [...agent.prompts, ...agent.steers].some((p) => p.includes("这个结论对吗")));
    const reply = w.heard.find((e) => e.type === "message" && e.message.text === "这个结论对吗");
    assert.deepEqual(reply?.type === "message" && [reply.message.addressed, reply.message.quoted], [true, String(w.server.spaces.get(team)!.msgs.get(answer.id)!.aseq)], "an answer to its message calls it, naming what it answers");
    await w.rig.quiet();
    agent.complete();
    await w.rig.quiet();

    // ── chat_history reads what was said before the station was brought in
    const old = w.server.group("Old", w.ada, [me]);
    w.server.say(old, w.ada, "以前的讨论");
    w.server.say(old, w.ada, "@Claude 接着看");
    const oldKey = sessionKey("g", old, old);
    await until("the old space's session", () => w.rig.store.getSession(oldKey) !== null);
    assert.ok((await w.rig.call(oldKey, "chat_history", { to: `${old}/${old}` })).includes("以前的讨论"));

    // ── the member taken out: its connections closed, its key let in no more
    w.server.remove(me);
    await until("let go", () => w.group().state("g")?.state !== "connected");
    assert.equal(w.server.hellos.at(-1)?.credential ?? "", "", "its key alone: the code was used");
  } finally {
    await w.close();
  }
});

test("a file over a piece goes a piece at a time, from what the anchor has of it on, none of it held whole; one of a piece whole in one ask; more than 512 MiB refused before it is read; an anchor from before pieces takes 32 MiB whole", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    const surface = w.group().chat("g") as unknown as GroupSurface;
    await known(surface, team);
    const room = join(w.rig.dir, "files");
    mkdirSync(room, { recursive: true });
    const lobby = { channel: team, threadTs: team };
    const sha = (b: Buffer) => createHash("sha256").update(b).digest("hex");
    const putAsks = () => w.server.asked.filter((a) => a.startsWith(`POST /spaces/${team}/files`) || a.startsWith(`GET /spaces/${team}/uploads/`));
    const fromOf = (a: string) => new URL(a.split(" ")[1]!, "im://a").searchParams.get("from");
    const posted = (name: string) => w.server.messages(team).at(-1)!.files.find((f: Json) => f.name === name);

    // ── one piece at most: whole, in one ask, as before
    const small = randomBytes(PIECE);
    writeFileSync(join(room, "small.bin"), small);
    await surface.post(lobby, "small", [{ name: "small.bin", path: join(room, "small.bin") } as Json]);
    assert.deepEqual(putAsks(), [`POST /spaces/${team}/files?name=small.bin&mime=application%2Foctet-stream`]);
    assert.equal(posted("small.bin").sha256, sha(small));

    // ── two and a half pieces: hashed, asked what the anchor has (none), put a piece at a time; a picture's sides kept
    const big = Buffer.concat([pngOf(320, 200), randomBytes(PIECE * 2 + PIECE / 2)]);
    writeFileSync(join(room, "big.png"), big);
    let before = putAsks().length;
    w.server.largestPut = 0;
    await surface.post(lobby, "big", [{ name: "big.png", path: join(room, "big.png") } as Json]);
    const bigAsks = putAsks().slice(before);
    assert.equal(bigAsks[0], `GET /spaces/${team}/uploads/${sha(big)}`);
    assert.deepEqual(bigAsks.slice(1).map(fromOf), ["0", String(PIECE), String(PIECE * 2)]);
    assert.ok(bigAsks.slice(1).every((a) => a.includes(`&sha256=${sha(big)}&size=${big.length}&`) && a.endsWith("&width=320&height=200")), bigAsks.join("\n"));
    assert.equal(w.server.largestPut, PIECE, "no ask carried more than a piece");
    assert.deepEqual([posted("big.png").sha256, posted("big.png").size, posted("big.png").width, posted("big.png").height], [sha(big), big.length, 320, 200]);
    assert.ok(w.server.spaces.get(team)!.files.get(sha(big))!.bytes.equals(big));
    assert.equal(w.server.parts.size, 0);

    // ── put before as far as a piece and a little: gone on from there
    const resumed = randomBytes(PIECE * 3);
    writeFileSync(join(room, "resumed.bin"), resumed);
    w.server.parts.set(`${sha(resumed)}.part.${me}`, resumed.subarray(0, PIECE + 100));
    before = putAsks().length;
    await surface.post(lobby, "resumed", [{ name: "resumed.bin", path: join(room, "resumed.bin") } as Json]);
    assert.deepEqual(putAsks().slice(before + 1).map(fromOf), [String(PIECE + 100), String(PIECE * 2 + 100)]);
    assert.ok(w.server.spaces.get(team)!.files.get(sha(resumed))!.bytes.equals(resumed));

    // ── one the anchor has whole already (put by another): taken at the first piece's ask, nothing more sent
    before = putAsks().length;
    await surface.post(lobby, "again", [{ name: "again.bin", path: join(room, "resumed.bin") } as Json]);
    assert.deepEqual(putAsks().slice(before).map(fromOf), [null, "0"]);
    assert.equal(posted("again.bin").sha256, sha(resumed));

    // ── more than 512 MiB: refused before a byte of it is read or asked (a sparse file of that size)
    writeFileSync(join(room, "huge.bin"), "");
    truncateSync(join(room, "huge.bin"), FILE_MOST + 1);
    before = putAsks().length;
    await assert.rejects(surface.post(lobby, "huge", [{ name: "huge.bin", path: join(room, "huge.bin") } as Json]), /huge\.bin is 536870913 bytes, more than the anchor takes \(536870912\)/);
    assert.equal(putAsks().length, before);

    // ── an anchor from before pieces: what it takes whole (32 MiB) in one ask, a larger one refused with what to do
    w.server.noPieces = true;
    const older = randomBytes(PIECE * 2);
    writeFileSync(join(room, "older.bin"), older);
    before = putAsks().length;
    await surface.post(lobby, "older", [{ name: "older.bin", path: join(room, "older.bin") } as Json]);
    assert.deepEqual(putAsks().slice(before), [`GET /spaces/${team}/uploads/${sha(older)}`, `POST /spaces/${team}/files?name=older.bin&mime=application%2Foctet-stream`]);
    assert.ok(w.server.spaces.get(team)!.files.get(sha(older))!.bytes.equals(older));
    writeFileSync(join(room, "large.bin"), "");
    truncateSync(join(room, "large.bin"), 32 * 1024 * 1024 + 1);
    await assert.rejects(surface.post(lobby, "large", [{ name: "large.bin", path: join(room, "large.bin") } as Json]), /more than this anchor takes \(33554432\): it takes larger files once it is updated/);
  } finally {
    await w.close();
  }
});

test("a chat relayed to a group space goes on in a topic of its own there, called as the chat is: its first message the station's, what people say there the agent's", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    assert.equal(topicTitle("  发布\n慢\u200b了  "), "发布 慢了");
    assert.equal(topicTitle("\u0007"), "");
    assert.equal(Array.from(topicTitle("长".repeat(80))).length, 60);
    const dm = w.server.direct(w.ada, me);
    w.server.say(dm, w.ada, "帮我看下 CI");
    const dmKey = sessionKey("g", dm, dm);
    await until("the direct space's session", () => w.rig.store.getSession(dmKey) !== null);
    await w.rig.quiet();
    w.rig.claude.last().complete();
    await w.rig.quiet();
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    w.server.direct(w.bo, me);
    await known(w.group().chat("g") as unknown as GroupSurface, team);
    await w.rig.quiet();

    // ── where it can go: its spaces (no direct one), each a new topic
    const from = w.rig.store.threadAt("group:g", dm, dm)!;
    let places: Json[] = [];
    await until("its spaces offered", () => {
      void relayPlaces(w.rig.hub, from).then((p) => (places = p));
      return places.length > 0 && places[0].places.length > 0;
    });
    assert.deepEqual(places.map((c) => [c.id, c.kind, c.places]), [["g", "group", [{ id: team, name: "Team", kind: "space" }]]]);

    // ── relayed: a topic opened, called as the chat is, the station's first message in it, the session following it
    const relayed = await relay(w.rig.hub, from, { name: "Ada", email: "ada@x" }, { connect: "g", channel: team }, "");
    const topics = [...w.server.spaces.get(team)!.topics.entries()];
    assert.equal(topics.length, 1);
    const [topic, opened] = topics[0]!;
    assert.match(topic, /^t_[0-9a-f]{16}$/);
    assert.equal(opened.title, topicTitle(titleOf(from, null, null)));
    assert.notEqual(opened.title, "");
    assert.deepEqual([relayed.to, relayed.link], [`${team}/${topic}`, null]);
    const first = w.server.messages(team, topic);
    assert.equal(first.length, 1);
    assert.ok(first[0]!.author === me && first[0]!.text.includes("Ada"), first[0]!.text);
    assert.deepEqual(w.server.messages(team), [], "nothing said in the lobby");
    const there = w.rig.store.threadAt("group:g", team, topic)!;
    assert.deepEqual(w.rig.store.threadSessions(there.id).map((m) => m.session), [dmKey]);
    await w.rig.quiet();
    const agent = w.rig.claude.last();
    assert.ok([...agent.prompts, ...agent.steers].some((p) => p.includes(`relayed the chat`) && p.includes(`a new topic in the group space Team`) && p.includes(`to=${team}/${topic}`)));

    // ── what people say in the topic, mentioning it or not, goes to the chat's agent
    w.server.say(team, w.bo, "我接着说：CI 红在 lint", { topic });
    await until("heard in the topic", () => w.texts(team, topic).includes("我接着说：CI 红在 lint"));
    await w.rig.quiet();
    assert.ok([...w.rig.claude.last().prompts, ...w.rig.claude.last().steers].some((p) => p.includes("CI 红在 lint")));
  } finally {
    await w.close();
  }
});

test("a space's topics are sessions of their own: one branched from a mention calls the agent with the message it came from; the lobby and each topic keep their own history and followers", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    w.server.say(team, w.bo, "lobby 里先聊点别的");
    const ask = w.server.say(team, w.ada, "@Claude 这次发布为什么慢");
    const lobbyKey = sessionKey("g", team, team);
    await until("the lobby's session", () => w.rig.store.getSession(lobbyKey) !== null);
    await w.rig.quiet();
    w.rig.claude.last().complete();
    await w.rig.quiet();

    // a topic branched from the mention: its first message wakes a session of its own, the mention quoted
    const topic = w.server.topic(team, w.ada, "发布慢", ask.id);
    w.server.say(team, w.ada, "在这个议题里继续", { topic });
    const topicKey = sessionKey("g", team, topic);
    await until("the topic's session", () => w.rig.store.getSession(topicKey) !== null);
    await w.rig.quiet();
    const inTopic = w.rig.claude.last();
    assert.notEqual(topicKey, lobbyKey);
    assert.match(inTopic.prompts[0]!, new RegExp(`thread="${team}/${topic}"`));
    assert.ok(inTopic.prompts[0]!.includes("在这个议题里继续"));
    assert.ok(inTopic.prompts[0]!.includes("这次发布为什么慢"), "the message it was branched from, quoted");
    assert.ok(w.texts(team, topic).some((t) => t.includes("这次发布为什么慢") && t.includes("在这个议题里继续")), "where it came from, kept with its first message");
    assert.ok(!w.texts(team, topic).includes("lobby 里先聊点别的"), "the lobby's chatter is the lobby's");

    // the agent answers in the topic: posted there, not in the lobby
    inTopic.reads();
    await w.rig.call(topicKey, "chat_post", { to: `${team}/${topic}`, text: "看了，是缓存没命中" });
    assert.deepEqual(w.server.messages(team, topic).map((m) => m.text), ["在这个议题里继续", "看了，是缓存没命中"]);
    assert.ok(!w.server.messages(team).some((m) => m.text === "看了，是缓存没命中"));
    inTopic.complete();
    await w.rig.quiet();

    // the topic's chatter follows its session; the lobby's does not reach it, nor the topic's the lobby's
    w.server.say(team, w.bo, "我补一句：CDN 也慢", { topic });
    await until("the topic's chatter", () => w.texts(team, topic).includes("我补一句：CDN 也慢"));
    w.server.say(team, w.bo, "午饭去哪");
    await until("the lobby's chatter", () => w.texts(team).includes("午饭去哪"));
    await w.rig.quiet();
    assert.ok([...inTopic.prompts, ...inTopic.steers].some((p) => p.includes("CDN 也慢")));
    assert.ok(![...inTopic.prompts, ...inTopic.steers].some((p) => p.includes("午饭去哪")));
    assert.ok(!w.texts(team).includes("我补一句：CDN 也慢"));

    // a topic opened on its own, about nothing of the bot's: no session until mentioned
    const other = w.server.topic(team, w.bo, "团建");
    w.server.say(team, w.bo, "周五去哪", { topic: other });
    await until("heard", () => w.told("周五去哪") === 1);
    await w.rig.quiet();
    assert.equal(w.rig.store.threadAt("group:g", team, other), null);
  } finally {
    await w.close();
  }
});

test("a card is a decision: its options or its field go native, the answer comes back as the person's message; a message before it closes it; an anchor without decisions gets the words", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    const dm = w.server.direct(w.ada, me);
    const key = sessionKey("g", dm, dm);
    const to = `${dm}/${dm}`;
    w.server.say(dm, w.ada, "开始");
    await until("its session", () => w.rig.store.getSession(key) !== null);
    const turn = async (f: () => Promise<unknown>) => {
      await w.rig.quiet();
      const agent = w.rig.claude.last();
      agent.reads();
      await f();
      agent.complete();
      await w.rig.quiet();
    };
    const lastAsk = () => [...w.server.spaces.get(dm)!.msgs.values()].filter((m) => m.kind === "decision.ask").at(-1)!;

    // ── options: a decision of their labels, details and the one recommended
    await turn(() => w.rig.call(key, "chat_post", { to, text: "合并吗？", card: { type: "options", options: [{ label: "合并", detail: "现在就合", recommended: true }, { label: "先不" }] }, kind: "need_human", need: "选一个" }));
    const ask = lastAsk();
    const event = w.server.spaces.get(dm)!.events.find((s) => s.id === ask.id)!.event;
    assert.deepEqual(event.body, { text: "合并吗？", input: "options", options: [{ label: "合并", detail: "现在就合", recommended: true }, { label: "先不" }], files: [] });
    assert.equal(w.server.resolve(dm, w.ada, ask.id, "改天").why, "choice", "only one of its options");
    const resolved = w.server.resolve(dm, w.ada, ask.id, "先不");
    assert.equal(typeof resolved.aseq, "number");
    await until("the answer handed over", () => w.heard.some((e) => e.type === "message" && e.message.ts === String(resolved.aseq)));
    const answered = w.heard.find((e) => e.type === "message" && e.message.ts === String(resolved.aseq))!;
    assert.deepEqual(answered.type === "message" && [answered.message.text, answered.message.user, answered.message.addressed], ["先不", w.ada, true]);
    await until("recorded", () => w.texts(dm).includes("先不"));

    // ── a field: its placeholder; typed into, the words come back
    await turn(() => w.rig.call(key, "chat_post", { to, text: "要哪个分支？", card: { type: "text", placeholder: "main" }, kind: "need_human", need: "写分支" }));
    const field = lastAsk();
    assert.deepEqual([field.input, field.text], ["text", "要哪个分支？"]);
    const typed = w.server.resolve(dm, w.ada, field.id, "release/1.2");
    await until("the typed answer", () => w.heard.some((e) => e.type === "message" && e.message.ts === String(typed.aseq) && e.message.text === "release/1.2"));

    // ── a message before an answer closes the card: its answer after is no word to the agent, a number a number
    await turn(() => w.rig.call(key, "chat_post", { to, text: "要重跑吗？", card: { type: "options", options: [{ label: "重跑" }, { label: "先不" }] }, kind: "need_human", need: "选" }));
    const rerun = lastAsk();
    const wait = w.server.say(dm, w.ada, "先等等");
    await until("heard", () => w.told("先等等") === 1);
    const one = w.server.say(dm, w.ada, "1");
    await until("heard", () => w.heard.some((e) => e.type === "message" && e.message.ts === String(one.aseq)));
    assert.equal(w.heard.filter((e) => e.type === "message" && e.message.ts === String(one.aseq)).map((e) => e.type === "message" && e.message.text)[0], "1");
    const late = w.server.resolve(dm, w.ada, rerun.id, "重跑");
    await settle();
    assert.ok(!w.heard.some((e) => e.type === "message" && e.message.ts === String(late.aseq)), "its card closed by the message before");
    void wait;

    // ── an anchor from before decisions: the question and its numbered options as words, a number its option
    w.server.noDecisions = true;
    await turn(() => w.rig.call(key, "chat_post", { to, text: "选环境", card: { type: "options", options: [{ label: "测试" }, { label: "正式" }] }, kind: "need_human", need: "选" }));
    assert.equal(w.server.messages(dm).at(-1)!.text, "选环境\n\n1. 测试\n2. 正式\n\n回复编号或选项文字即可回答。");
    assert.ok(w.server.refusals.includes("kind"));
    const two = w.server.say(dm, w.ada, "2");
    await until("heard", () => w.heard.some((e) => e.type === "message" && e.message.ts === String(two.aseq)));
    assert.equal(w.heard.filter((e) => e.type === "message" && e.message.ts === String(two.aseq)).map((e) => e.type === "message" && e.message.text)[0], "正式");
  } finally {
    await w.close();
  }
});

test("what the agent does is the stream's live state, taken back as its turn ends and said again while it stands; Stop pressed there stops the turn", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    const team = w.server.group("Team", w.ada, [w.bo, me]);
    const topic = w.server.topic(team, w.ada, "发布");
    const said = w.server.say(team, w.ada, "@Claude 跑一下全量测试", { topic });
    const key = sessionKey("g", team, topic);
    await until("its session", () => w.rig.store.getSession(key) !== null);
    await until("live", () => w.server.lives.some((l) => l.state === "working"));
    const live = w.server.lives.find((l) => l.state === "working")!;
    assert.deepEqual([live.space, live.topic, live.author, live.stoppable, live.message_ts], [team, topic, me, true, String(said.aseq)]);
    assert.ok(live.text !== "");

    // said again before the anchor's 90 s let it go
    const n = w.server.lives.length;
    await w.t.adjust(60_000);
    await until("said again", () => w.server.lives.length > n);
    assert.equal(w.server.lives.at(-1)!.state, "working");

    // Stop, pressed by someone else's device in another topic: nothing; in its own: the turn stopped
    const agent = w.rig.claude.last();
    w.server.stop(team, w.bo, "lobby");
    await w.rig.quiet();
    assert.equal(agent.aborts, 0, "another stream's Stop");
    w.server.stop(team, w.bo, topic, w.bo);
    await w.rig.quiet();
    assert.equal(agent.aborts, 0, "a Stop meant for another agent");
    w.server.stop(team, w.bo, topic);
    await until("stopped", () => agent.aborts === 1);
    agent.end({ kind: "aborted" } as Json);
    await w.rig.quiet();
    await w.t.adjust(2_000);
    await until("taken back", () => w.server.lives.at(-1)!.state === "done");
    assert.equal(w.server.lives.at(-1)!.stoppable, false);
  } finally {
    await w.close();
  }
});

test("a secret handed end to end (its own connection, or the anchor's in passing) reaches the session as a file alone: never in a message's words or the station's store; one from a device not the member's is refused", { timeout: 60_000 }, async () => {
  const w = await world();
  try {
    const me = w.me();
    const dm = w.server.direct(w.ada, me);
    const key = sessionKey("g", dm, dm);
    w.server.say(dm, w.ada, "部署要用 Stripe 的 key");
    await until("its session", () => w.rig.store.getSession(key) !== null);
    await w.rig.quiet();
    w.rig.claude.last().reads();
    await w.rig.call(key, "chat_post", { to: `${dm}/${dm}`, text: "请把 STRIPE_KEY 发我", card: { type: "text", placeholder: "sk_test_..." }, kind: "need_human", need: "发 key" });
    w.rig.claude.last().complete();
    await w.rig.quiet();
    const device = await (w.group().chat("g") as unknown as { device(): Promise<string> }).device();

    // ── a device that is not Ada's says it is hers: refused, nothing handed over
    const forged = await w.server.secretDirect(w.mesh, dm, w.ada, device, "STRIPE_KEY", "sk_forged", "lobby", randomBytes(32));
    assert.equal(forged?.ok, false);

    // ── her own device dials the bot's: taken, the session told by its label, its value in a file of its uploads
    const value = `sk_test_${randomBytes(12).toString("hex")}`;
    const ok = await w.server.secretDirect(w.mesh, dm, w.ada, device, "STRIPE_KEY", value);
    assert.deepEqual(ok, { ok: true });
    await until("its message", () => w.heard.some((e) => e.type === "message" && e.message.files?.some((f) => f.url?.startsWith("secret:"))));
    await w.rig.quiet();
    const row = w.rig.store.messagesBefore(w.rig.store.threadAt("group:g", dm, dm)!.id, null, 50).find((m) => m.attachments.some((a) => a.name === "STRIPE_KEY.secret"))!;
    assert.ok(row.text.includes("STRIPE_KEY") && !row.text.includes(value));
    assert.equal(readFileSync(row.attachments[0]!.path, "utf8"), value);
    assert.ok(![...w.rig.claude.last().prompts, ...w.rig.claude.last().steers].some((p) => p.includes(value)), "never in what the agent is told");
    assert.equal(w.rig.store.pendingMessages(key).length, 0);
    const db = w.rig.store.db;
    for (const { name } of db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").all() as { name: string }[]) {
      const columns = (db.prepare(`PRAGMA table_info("${name}")`).all() as { name: string }[]).map((c) => `CAST("${c.name}" AS TEXT) LIKE ?`);
      if (columns.length === 0) continue;
      const found = db.prepare(`SELECT count(*) AS n FROM "${name}" WHERE ${columns.join(" OR ")}`).get(...columns.map(() => `%${value}%`)) as { n: number };
      assert.equal(found.n, 0, `nothing of it in the station's store (${name})`);
    }
    assert.ok(!w.server.messages(dm).some((m) => m.text.includes(value)), "nor said back in the space");

    // ── the same again (by its id) is taken once; one through the anchor in passing comes the same way
    const passed = w.server.secretThrough(dm, w.ada, me, "DB_URL", "postgres://x");
    await until("the second", () => w.heard.filter((e) => e.type === "message" && e.message.files?.some((f) => f.url?.startsWith("secret:"))).length === 2);
    assert.ok(passed !== "");
  } finally {
    await w.close();
  }
});

test("what is said while the link is down, and while the station is stopped, is taken once; a space it is put in later keeps its past as history; a file of im/1's starts it afresh", { timeout: 60_000 }, async () => {
  const w = await world(memoryMesh(), { threads: { g: { since: "41", last: { "0123456789abcdef": 7 } } } });
  try {
    const me = w.me();
    const dm = w.server.direct(w.ada, me);
    w.server.say(dm, w.ada, "一");
    await until("one", () => w.told("一") === 1);

    // the link cut: what is said meanwhile comes as the next sync goes on from where it was
    w.server.cut();
    w.server.say(dm, w.ada, "二");
    await until("two", () => w.told("二") === 1);
    assert.ok(w.server.asked.filter((a) => a === "POST /sync").length >= 2);

    // the station stopped and started again: from what it kept on the disk
    await w.group().close();
    w.server.say(dm, w.ada, "三");
    await w.start();
    await until("three", () => w.told("三") === 1);
    await settle();
    assert.deepEqual(["一", "二", "三"].map(w.told), [1, 1, 1], "each once");
    assert.equal(w.server.hellos.at(-1)!.credential, "", "its key alone, the code long used");
    const kept = JSON.parse(readFileSync(join(w.rig.dir, "group-threads.json"), "utf8")).g;
    assert.equal(kept.v, 2);
    assert.equal(kept.spaces[dm].aseq, w.server.spaces.get(dm)!.lastAseq);

    // what it says after a start again is signed after what it said before
    const dmKey = sessionKey("g", dm, dm);
    await w.rig.quiet();
    w.rig.claude.last().reads();
    await w.rig.call(dmKey, "chat_post", { to: `${dm}/${dm}`, text: "收到" });
    await w.rig.call(dmKey, "chat_post", { to: `${dm}/${dm}`, text: "再说一句" });
    const mine = w.server.spaces.get(dm)!.events.filter((s) => s.event.author === me);
    assert.deepEqual(mine.map((s) => s.event.dseq), [1, 2]);
    assert.equal(mine[1]!.event.prev, mine[0]!.id);

    // a card asked before a start again, answered after it: still the person's message, to the session that follows
    await w.rig.call(dmKey, "chat_post", { to: `${dm}/${dm}`, text: "合并吗？", card: { type: "options", options: [{ label: "合并" }, { label: "先不" }] }, kind: "need_human", need: "选" });
    w.rig.claude.last().complete();
    await w.rig.quiet();
    const ask = [...w.server.spaces.get(dm)!.msgs.values()].filter((m) => m.kind === "decision.ask").at(-1)!;
    await w.group().close();
    await w.start();
    const picked = w.server.resolve(dm, w.ada, ask.id, "合并");
    await until("the answer after the start", () => w.texts(dm).includes("合并"));
    const after = w.heard.find((e) => e.type === "message" && e.message.ts === String(picked.aseq));
    assert.equal(after?.type === "message" && after.message.addressed, true, "a direct space's every message calls it");
    await w.rig.quiet();
    w.rig.claude.last().complete();
    await w.rig.quiet();

    // put in a space with a past: the past is not a request, what comes after is
    const old = w.server.group("Old", w.ada, [w.bo]);
    w.server.say(old, w.ada, "@Claude 早先的话");
    w.server.add(old, w.ada, me);
    w.server.say(old, w.bo, "@Claude 现在的话");
    await until("now", () => w.told("@Claude 现在的话") === 1);
    assert.equal(w.told("@Claude 早先的话"), 0);
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

test("over the mesh addon's own endpoints: joined, a direct space's message heard and answered", { timeout: 60_000, skip: addon === null && "no mesh addon here (node ../scripts/native.ts run mesh)" }, async () => {
  const mesh = addon!;
  // (dialled at the anchor's addresses on this machine: the relays in config.json are none the test runs)
  const t = testClock();
  const rig = new Rig();
  const server = new ImServer(await mesh.bind({ secretKey: randomBytes(32), alpns: [Buffer.from("im/2")], relayUrls: [], discovery: false, bindAddr: "127.0.0.1:0" }));
  const ada = server.member("Ada", true);
  const { GroupSurface } = await import("../src/group/surface.ts");
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
    const dm = server.direct(ada, me);
    const said = server.say(dm, ada, "你好");
    await firstHeard;
    assert.deepEqual(heard[0], { type: "message", message: { channel: dm, threadTs: dm, ts: String(said.aseq), user: ada, text: "你好", addressed: true } });
    assert.equal(await surface.post({ channel: dm, threadTs: dm }, "你好，我在", []), String(said.aseq + 1));
    assert.equal(server.messages(dm)[1]!.text, "你好，我在");
  } finally {
    await surface.stop();
    await threads.flushed();
    await rig.close();
    await server.close();
  }
});
