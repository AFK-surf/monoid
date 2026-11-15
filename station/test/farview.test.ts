// A chat's Farview (src/browser/farview.ts) without Farview: the switch read from config.json and whose chats it is for,
// what a host writes once it listens, a view's pictures and input over a frame port served here (pictures only as the
// host says one changed), the `browser` tool giving Farview to the chats it is for and Chrome to the others, and a
// chat's tabs (one profile, a page's new tab opened beside it, taken up by the next station process, gone with the
// chat) over a made-up host program that listens and says what it was started with. Farview's own host is not run.
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { groupAlive } from "../src/ops/group.ts";
import type { ScreenSource, Screens } from "../src/screens/source.ts";
import { FarviewTabs, chatDir, farviewConfig, farviewFor, farviewHowTo, hostFileOf } from "../src/browser/farview.ts";
import { DEFAULT_SIZE, FarviewScreen, FrameLink, inputOf, sizeFor } from "../src/browser/farview-screen.ts";
import { decodeAnswer, encodeAsk } from "../src/browser/farview-agent.ts";
import { browserTools, type ToolBrowsers } from "../src/browser/tool.ts";

test("Farview is on only where config.json says where it is, every chat's browser by its engine, else the chats it lists", () => {
  assert.equal(farviewConfig({}), null);
  assert.equal(farviewConfig({ browser: { engine: "chrome" } }), null);
  assert.equal(farviewConfig({ browser: { engine: "farview" } }), null);
  const all = { dir: "/opt/fv", host: "/opt/fv/bin/host.exe", agent: "/opt/fv/bin/agent.exe", engine: "farview", sessions: [] };
  assert.deepEqual(farviewConfig({ browser: { engine: "farview", farview: "/opt/fv" } }), all);
  const some = farviewConfig({ browser: { farview: "/opt/fv", sessions: ["chat:a", 3, ""] } });
  assert.deepEqual(some, { ...all, engine: "chrome", sessions: ["chat:a"] });
  // every chat's; the listed and those that chose it of the rest; a listed chat's own choice of Chrome is kept too
  assert.equal(farviewFor(farviewConfig({ browser: { engine: "farview", farview: "/opt/fv" } }), "chat:x", undefined), true);
  assert.equal(farviewFor(some, "chat:a", undefined), true);
  assert.equal(farviewFor(some, "chat:b", undefined), false);
  assert.equal(farviewFor(some, "chat:b", "farview"), true);
  assert.equal(farviewFor(some, "chat:b", "chrome"), false);
  // a chat the config gives Farview goes back to Chrome by choosing it: one it lists, and every chat's
  assert.equal(farviewFor(some, "chat:a", "chrome"), false);
  assert.equal(farviewFor(farviewConfig({ browser: { engine: "farview", farview: "/opt/fv" } }), "chat:x", "chrome"), false);
  assert.equal(farviewFor(null, "chat:a", "farview"), false);
});

test("a host's file is taken only with its process and three ports", () => {
  assert.deepEqual(hostFileOf({ pid: 12, port: 4000, agent: 4001, frame: 4002 }), { pid: 12, port: 4000, agent: 4001, frame: 4002 });
  assert.equal(hostFileOf({ pid: 12, port: 4000, agent: 4001 }), null);
  assert.equal(hostFileOf({ pid: 0, port: 4000, agent: 4001, frame: 4002 }), null);
  assert.equal(hostFileOf({ pid: 12, port: 70000, agent: 4001, frame: 4002 }), null);
  assert.equal(hostFileOf("x"), null);
});

test("a chat's directory is named by its session, not as it", () => {
  assert.match(chatDir("chat:c-1/2"), /^[0-9a-f]{24}$/);
  assert.notEqual(chatDir("chat:a"), chatDir("chat:b"));
});

test("a view lays the tab out for its viewer's screen, else within its bounds", () => {
  assert.deepEqual(sizeFor({ maxWidth: 4000, maxHeight: 4000, codecs: ["jpeg"] }), DEFAULT_SIZE);
  assert.deepEqual(sizeFor({ maxWidth: 640, maxHeight: 800, codecs: ["jpeg"] }), { width: 1280, height: 800, scale: 0.5 });
  assert.deepEqual(sizeFor({ maxWidth: 4000, maxHeight: 4000, codecs: ["jpeg"], fit: { width: 412, height: 915, scale: 2.6 } }), { width: 412, height: 915, scale: 2.6 });
});

test("a person's pointer reaches the host in the pictures' pixels, the wheel in CSS pixels", () => {
  const size = { width: 400, height: 800, scale: 2 };
  assert.deepEqual(inputOf({ t: "pointer", kind: "down", x: 0.5, y: 0.25, buttons: 1 }, size), { pointer: { type: "down", x: 400, y: 400, button: 0, buttons: 1 } });
  assert.deepEqual(inputOf({ t: "wheel", x: 0, y: 1, dx: 0, dy: 120 }, size), { wheel: { x: 0, y: 800, dx: 0, dy: 120 } });
  assert.deepEqual(inputOf({ t: "key", kind: "down", key: "Enter", code: "Enter", mods: 8 }, size), { key: { type: "down", key: "Enter", code: "Enter", mods: 8 } });
  assert.deepEqual(inputOf({ t: "text", text: "你好" }, size), { text: "你好" });
  assert.equal(inputOf({ t: "pose", name: "open" }, size), null);
});

/// A frame port: every line a connection sends is heard; a picture asked for is answered with `picture`.
async function framePort(picture: Buffer) {
  const heard: any[] = [];
  const sockets: Socket[] = [];
  const server = createServer((s) => {
    sockets.push(s);
    let buf = "";
    s.on("data", (d) => {
      buf += d.toString("latin1");
      let nl;
      while ((nl = buf.indexOf("\n")) >= 0) {
        const m = JSON.parse(buf.slice(0, nl));
        buf = buf.slice(nl + 1);
        heard.push(m);
        if (m.frame) {
          s.write(`${JSON.stringify({ frame: { seq: 3, width: 640, height: 450, format: "jpeg", bytes: picture.length } })}\n`);
          // the bytes in two pieces, the line after them in the same write as the second
          s.write(picture.subarray(0, 2));
          s.write(Buffer.concat([picture.subarray(2), Buffer.from(`${JSON.stringify({ page: { url: "https://a.test/", title: "A" } })}\n`)]));
        }
      }
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = (server.address() as { port: number }).port;
  const said = (m: object) => {
    for (const s of sockets) s.write(`${JSON.stringify(m)}\n`);
  };
  const close = () => {
    for (const s of sockets) s.destroy();
    server.close();
  };
  return { port, heard, said, close, sockets };
}

/// Until `f` holds, turning the loop (what the sockets carry comes in its own time).
async function until(f: () => boolean) {
  for (let i = 0; i < 2000 && !f(); i++) await new Promise((r) => setImmediate(r));
  assert.ok(f(), "it did not come");
}

test("a picture's bytes are read whole after the line that says them, and the lines after them heard", async () => {
  const picture = Buffer.from([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);
  const port = await framePort(picture);
  const link = new FrameLink(port.port);
  const heard: any[] = [];
  link.heard = (m) => heard.push(m);
  const got = await link.picture();
  assert.deepEqual(got?.data, picture);
  assert.equal(got?.header.seq, 3);
  await until(() => heard.length > 0);
  assert.deepEqual(heard[0], { page: { url: "https://a.test/", title: "A" } });
  link.close();
  assert.equal(await link.picture(), null);
  port.close();
});

test("a view sends its size, a picture first and then only once the host says the tab changed; its input goes to the host", async () => {
  const picture = Buffer.from([0xff, 0xd8, 9, 0xff, 0xd9]);
  const port = await framePort(picture);
  const screen = new FarviewScreen({ session: "chat:c-1", port: port.port });
  assert.match(screen.id, /^browser:fv_[0-9a-f]{24}$/);
  // (an app that draws Farview itself reads it by a stream of its own: the list says it can)
  assert.equal(screen.farview, true);
  assert.equal(screen.openedBy(), "chat:c-1");
  const view = await screen.open({ maxWidth: 4000, maxHeight: 4000, codecs: ["jpeg"], fit: { width: 400, height: 800, scale: 2 } });
  assert.equal(screen.viewing(), 1);
  const first = await view.next();
  assert.deepEqual(first?.config, { codec: "jpeg", width: 640, height: 450 });
  assert.deepEqual(first?.data, picture);
  assert.deepEqual(port.heard[0], { size: { width: 400, height: 800, scale: 2 } });
  await until(() => screen.page().url === "https://a.test/");
  assert.equal(screen.title(), "A");
  assert.equal(screen.site(), "a.test");
  // nothing changed: no picture is asked for until the host says one
  let second: unknown = undefined;
  const asking = view.next().then((f) => (second = f));
  await until(() => port.heard.length >= 2);
  assert.equal(port.heard.filter((m) => m.frame).length, 1);
  assert.equal(second, undefined);
  port.said({ changed: 4 });
  await asking;
  assert.equal(port.heard.filter((m) => m.frame).length, 2);
  assert.equal((second as any).config, undefined);
  await view.input({ t: "pointer", kind: "down", x: 0.5, y: 0.5, buttons: 1 });
  await until(() => port.heard.some((m) => m.pointer));
  assert.deepEqual(port.heard.find((m) => m.pointer), { pointer: { type: "down", x: 400, y: 800, button: 0, buttons: 1 } });
  // the host tells the tab's viewport (no scale): the view's pictures, and so its pointer, keep its own 2x
  port.said({ size: { width: 400, height: 800 } });
  await until(() => port.heard.length > 0);
  await new Promise((r) => setImmediate(r));
  await view.input({ t: "pointer", kind: "up", x: 0.5, y: 0.5, buttons: 0 });
  await until(() => port.heard.some((m) => m.pointer?.type === "up"));
  assert.deepEqual(port.heard.find((m) => m.pointer?.type === "up"), { pointer: { type: "up", x: 400, y: 800, button: 0, buttons: 0 } });
  view.close();
  assert.equal(await view.next(), null);
  assert.equal(screen.viewing(), 0);
  screen.close();
  port.close();
});

test("a person's paste goes to the tab as typed, and what they copy there reaches their clipboard", async () => {
  const port = await framePort(Buffer.from([0xff, 0xd8, 9, 0xff, 0xd9]));
  const screen = new FarviewScreen({ session: "chat:c-1", port: port.port });
  try {
    assert.deepEqual(screen.clipboard(), ["text"]);
    const view = await screen.open({ maxWidth: 4000, maxHeight: 4000, codecs: ["jpeg"] });
    // (heard once the server took it: the size the view sends first, then the paste, on one connection in order)
    const pasted = new Promise<void>((resolve) => {
      const look = () => (port.heard.some((m) => m.text === "pasted") ? resolve() : setImmediate(look));
      look();
    });
    await view.setClipboard!({ type: "text", text: "pasted" }, true);
    await pasted;
    const copied = new Promise<unknown>((resolve) => view.watchClipboard!((clip) => resolve(clip)));
    await until(() => port.sockets.length > 0);
    port.said({ copied: "copied words" });
    assert.deepEqual(await copied, { type: "text", text: "copied words" });
    view.close();
  } finally {
    screen.close();
    port.close();
  }
});

test("the browser tool gives Farview to the chats it is for and Chrome to the others, its tabs opened, listed and closed", async () => {
  const chromeStopped: string[] = [];
  const chrome: ToolBrowsers = {
    endpoint: async () => ({ running: true, http: "http://127.0.0.1:9222", ws: "ws://127.0.0.1:9222/devtools/browser/x" }),
    tabs: () => [],
    status: () => ({ running: false }),
    stop: async (s: string) => void chromeStopped.push(s),
  };
  const config = { dir: "/opt/fv", host: "/opt/fv/bin/host.exe", agent: "/opt/fv/bin/agent.exe", engine: "chrome" as const, sessions: ["chat:c-1"] };
  const chosen = new Map<string, string>();
  const started: string[] = [];
  const stopped: string[] = [];
  const tabs = [{ id: "fv_x", title: "A", url: "https://a.test/", attached: false, session: "chat:c-1", agent: 41234 }];
  const farview = {
    active: () => config,
    activeFor: (s: string) => (chosen.get(s) ?? (config.sessions.includes(s) ? "farview" : "chrome")) === "farview",
    choose: async (s: string, e: string) => void chosen.set(s, e),
    endpoint: async (s: string) => (started.push(s), { running: true }),
    agentPort: (_s: string, id?: string) => (id === undefined || id === "" || id === "fv_x" ? 41234 : id === "fv_x_1" ? 41240 : null),
    tabs: () => tabs,
    open: async (s: string, url: string) => {
      const t = { id: "fv_x_1", title: "", url, attached: false, session: s, agent: 41240 };
      tabs.push(t);
      return t;
    },
    closeTab: async (_s: string, id: string) => void tabs.splice(tabs.findIndex((t) => t.id === id), 1),
    status: () => ({ running: true, viewing: 0, tabs: tabs.length }),
    stop: async (s: string) => void stopped.push(s),
  } as unknown as FarviewTabs;
  const [tool] = browserTools(chrome, () => null, farview);
  // a chat the config lists: Farview, each tab with its agent port
  const told = String(await tool!.run("chat:c-1", {}));
  assert.equal(told, farviewHowTo(config, tabs));
  assert.match(told, /\/opt\/fv\/bin\/agent\.exe 127\.0\.0\.1 41234/);
  assert.match(told, /- fv_x "A" https:\/\/a\.test\/ — agent port 41234/);
  assert.deepEqual(started, ["chat:c-1"]);
  const opened = String(await tool!.run("chat:c-1", { action: "open", url: "https://b.test/" }));
  assert.match(opened, /Opened fv_x_1 on https:\/\/b\.test\/.*127\.0\.0\.1 41240/);
  const listed = String(await tool!.run("chat:c-1", { action: "tabs" }));
  assert.match(listed, /fv_x "A" https:\/\/a\.test\/ \(agent port 41234\)/);
  assert.match(listed, /fv_x_1 https:\/\/b\.test\/ \(agent port 41240\)/);
  assert.match(String(await tool!.run("chat:c-1", { action: "status", tab: "fv_x_1" })), /2 tab\(s\), agent port 41240/);
  await tool!.run("chat:c-1", { action: "close", tab: "fv_x_1" });
  assert.equal(tabs.length, 1);
  await tool!.run("chat:c-1", { action: "stop" });
  assert.deepEqual(stopped, ["chat:c-1"]);
  // another chat: Chrome, till its agent chooses Farview (and back)
  assert.match(String(await tool!.run("chat:c-2", {})), /DevTools for this chat: http:\/\/127\.0\.0\.1:9222/);
  await assert.rejects(tool!.run("chat:c-2", { action: "open", url: "https://b.test/" }), /Farview's/);
  assert.match(String(await tool!.run("chat:c-2", { engine: "farview" })), /This chat's browser runs: Farview/);
  assert.equal(chosen.get("chat:c-2"), "farview");
  // (its Chrome closed as it chose Farview, as choosing Chrome ends its Farview)
  assert.deepEqual(chromeStopped, ["chat:c-2"]);
  assert.match(String(await tool!.run("chat:c-2", { engine: "chrome" })), /DevTools for this chat/);
});

/// A made-up Farview host: listens on 127.0.0.1 (its client, agent and frame ports), writes host.json and what it was
/// started with (said.json) where FV_STATE_DIR says, keeps its page there as Farview's does, and on a page of
/// opener.test says to the first frame connection that opens that the page asked for a new tab (once, as a page asks).
const FAKE_HOST = `#!/usr/bin/env node
const net = require("node:net");
const fs = require("node:fs");
const dir = process.env.FV_STATE_DIR;
const url = process.argv[process.argv.length - 1];
fs.writeFileSync(dir + "/url", url);
const listen = (on) => new Promise((r) => { const s = net.createServer(on); s.listen(0, "127.0.0.1", () => r(s.address().port)); });
(async () => {
  const port = await listen(() => {});
  const agent = await listen((s) => s.on("error", () => {}));
  let asked = false;
  const frame = await listen((s) => {
    s.on("error", () => {});
    if (url.startsWith("https://opener.test/") && !asked) asked = true, s.write(JSON.stringify({ openTab: "https://opened.test/" }) + "\\n");
  });
  fs.writeFileSync(dir + "/said.json", JSON.stringify({ url, profile: process.env.FV_PROFILE_DIR, newTabs: process.env.FV_NEW_TABS }));
  fs.writeFileSync(dir + "/host.json", JSON.stringify({ pid: process.pid, port, agent, frame }));
})();
process.on("SIGTERM", () => process.exit(0));
`;

async function fakeFarview() {
  const root = await mkdtemp(join(tmpdir(), "fv-tabs-"));
  await mkdir(join(root, "release", "bin"), { recursive: true });
  await writeFile(join(root, "release", "bin", "host.exe"), FAKE_HOST);
  await chmod(join(root, "release", "bin", "host.exe"), 0o755);
  let raw: any = { browser: { farview: join(root, "release"), sessions: ["chat:listed"] } };
  const shown: ScreenSource[] = [];
  const waits: { n: number; done: () => void }[] = [];
  const screens = {
    add: (s: ScreenSource) => {
      shown.push(s);
      for (const w of waits.filter((w) => shown.length >= w.n)) waits.splice(waits.indexOf(w), 1), w.done();
      return () => void shown.splice(shown.indexOf(s), 1);
    },
  } as unknown as Screens;
  /// Once `n` screens are shown (a tab a page asked for is started by its host's word, in its own time).
  const shownAt = (n: number) => (shown.length >= n ? Promise.resolve() : new Promise<void>((done) => void waits.push({ n, done })));
  const make = () => new FarviewTabs({ dir: join(root, "data"), config: () => farviewConfig(raw), screens });
  return { root, shown, shownAt, make, set: (r: any) => (raw = r) };
}

const said = async (dir: string) => JSON.parse(await readFile(join(dir, "said.json"), "utf8"));
const gone = async (path: string) => stat(path).then(() => false, () => true);

test("a chat's Farview is for it as the config lists it or its agent chose it, the choice kept for the next station process", { skip: process.platform === "win32" && "a made-up host is a script with a #! line" }, async () => {
  const fv = await fakeFarview();
  try {
    const tabs = fv.make();
    assert.equal(tabs.activeFor("chat:listed"), true);
    assert.equal(tabs.activeFor("chat:other"), false);
    await tabs.choose("chat:other", "farview");
    assert.equal(tabs.activeFor("chat:other"), true);
    // (the next station process reads what was chosen as it starts)
    const next = fv.make();
    assert.equal(next.activeFor("chat:other"), false);
    await next.resume();
    assert.equal(next.activeFor("chat:other"), true);
    await next.choose("chat:other", "chrome");
    assert.equal(next.activeFor("chat:other"), false);
    // every chat's where the config says so
    fv.set({ browser: { farview: join(fv.root, "release"), engine: "farview" } });
    assert.equal(next.activeFor("chat:third"), true);
    fv.set({});
    assert.equal(next.activeFor("chat:listed"), false);
    await assert.rejects(next.choose("chat:listed", "farview"), /not on this station/);
  } finally {
    await rm(fv.root, { recursive: true, force: true });
  }
});

test("a chat the config lists goes back to Chrome by choosing it, its Farview ended", { skip: process.platform === "win32" && "a made-up host is a script with a #! line" }, async () => {
  const fv = await fakeFarview();
  const session = "chat:listed";
  const tabs = fv.make();
  try {
    await tabs.endpoint(session);
    const chat = join(fv.root, "data", chatDir(session));
    const pid = JSON.parse(await readFile(join(chat, "tabs", "0", "host.json"), "utf8")).pid;
    assert.equal(groupAlive(pid), true);
    await tabs.choose(session, "chrome");
    assert.equal(tabs.activeFor(session), false);
    assert.equal(groupAlive(pid), false);
    assert.deepEqual(tabs.tabs(session), []);
    // (and Farview again by choosing it)
    await tabs.choose(session, "farview");
    assert.equal(tabs.activeFor(session), true);
  } finally {
    await tabs.closeOf(session).catch(() => {});
    await rm(fv.root, { recursive: true, force: true });
  }
});

test("a chat's tabs: one profile, each a host and a screen of its own, a page's new tab opened beside it, taken up by the next station process, gone with the chat", { skip: process.platform === "win32" && "a made-up host is a script with a #! line" }, async () => {
  const fv = await fakeFarview();
  const session = "chat:listed";
  const chat = join(fv.root, "data", chatDir(session));
  let tabs = fv.make();
  try {
    // a chat's directory as a station from before kept it: its profile and page moved where they go now
    await mkdir(chat, { recursive: true });
    await writeFile(join(chat, "cookies.txt"), "# cookies\n");
    await writeFile(join(chat, "url"), "https://kept.test/");
    await tabs.endpoint(session);
    const first = await said(join(chat, "tabs", "0"));
    assert.deepEqual(first, { url: "https://kept.test/", profile: join(chat, "profile"), newTabs: "1" });
    assert.equal(await readFile(join(chat, "profile", "cookies.txt"), "utf8"), "# cookies\n");
    assert.equal(await gone(join(chat, "cookies.txt")), true);
    const id = `fv_${chatDir(session)}`;
    assert.deepEqual(tabs.tabs(session).map((t) => t.id), [id]);
    assert.deepEqual(fv.shown.map((s) => s.id), [`browser:${id}`]);
    // the agent's new tab: the same profile, a screen of its own
    const b = await tabs.open(session, "https://b.test/");
    assert.equal(b.id, `${id}_1`);
    assert.deepEqual(await said(join(chat, "tabs", "1")), { url: "https://b.test/", profile: join(chat, "profile"), newTabs: "1" });
    assert.notEqual(b.agent, tabs.agentPort(session));
    assert.equal(tabs.agentPort(session, b.id), b.agent);
    assert.equal(tabs.clientPort(`browser:${b.id}`) !== null, true);
    // a page that asks for a new tab: opened beside it, once (said to every frame connection, heard on the watch's)
    await tabs.open(session, "https://opener.test/");
    await fv.shownAt(4);
    assert.equal(tabs.tabs(session).length, 4);
    const urls = await Promise.all(tabs.tabs(session).map((t) => said(join(chat, "tabs", t.id.split("_")[2] ?? "0")).then((x) => x.url)));
    assert.deepEqual(urls, ["https://kept.test/", "https://b.test/", "https://opener.test/", "https://opened.test/"]);
    assert.equal(fv.shown.length, 4);
    assert.equal(tabs.status(session).tabs, 4);
    // a tab closed: its host ends and its directory goes; the first one stays
    const pid = JSON.parse(await readFile(join(chat, "tabs", "1", "host.json"), "utf8")).pid;
    await tabs.closeTab(session, b.id);
    assert.equal(groupAlive(pid), false);
    assert.equal(await gone(join(chat, "tabs", "1")), true);
    await assert.rejects(tabs.closeTab(session, id), /first tab stays/);
    // the station process ends, the hosts go on; the next one takes every tab up, each a screen again
    const before = tabs.tabs(session).map((t) => [t.id, t.agent]);
    tabs.close();
    assert.equal(fv.shown.length, 0);
    tabs = fv.make();
    await tabs.resume();
    assert.deepEqual(tabs.tabs(session).map((t) => [t.id, t.agent]), before);
    assert.equal(fv.shown.length, 3);
    // the chat archived: every host ends, its directory goes
    const pids = await Promise.all(["0", "2", "3"].map(async (n) => JSON.parse(await readFile(join(chat, "tabs", n, "host.json"), "utf8")).pid));
    await tabs.closeOf(session);
    assert.deepEqual(pids.map((p) => groupAlive(p)), [false, false, false]);
    assert.equal(await gone(chat), true);
    assert.equal(fv.shown.length, 0);
  } finally {
    await tabs.closeOf(session).catch(() => {});
    await rm(fv.root, { recursive: true, force: true });
  }
});

test("the station's asks of a Farview tab are its wire's messages, and its answers read", () => {
  // (Farview's src/proto: a 4-byte length, the kind, each string its length and UTF-8 bytes, zigzag varints)
  assert.deepEqual([...encodeAsk({ kind: "look" })], [0, 0, 0, 1, 38]);
  assert.deepEqual([...encodeAsk({ kind: "cookies", verb: "get", arg: "é" })], [0, 0, 0, 8, 70, 6, ...Buffer.from("get"), 4, 0xc3, 0xa9]);
  const body = (kind: number, ...strs: string[]) => {
    const out = [kind * 2];
    for (const s of strs) out.push(Buffer.byteLength(s) * 2, ...Buffer.from(s));
    return Buffer.from(out);
  };
  assert.deepEqual(decodeAnswer(body(33, "[1]")), { kind: "value", value: "[1]" });
  assert.deepEqual(decodeAnswer(body(20, "https://a.test/", "A", "outline")), { kind: "seen", url: "https://a.test/", title: "A", outline: "outline" });
  assert.deepEqual(decodeAnswer(body(21)), { kind: "taken" });
  assert.equal(decodeAnswer(body(12)), null);
});
