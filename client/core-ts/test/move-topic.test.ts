// What of a station moves to another (the `stationMove` topic, move.ts; the station's move/routes.ts): read as its page
// shows it and again as its station tells `move`, shaped to what the page draws (a module's items only for the module
// open, each row's state and why in words, the stations it may go to); `move.start` and `move.back` answered at once,
// what they do shown through the topic, a refusal in its words.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { HttpRequest } from "../src/host.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import type { StationAddr } from "../src/station/addr.ts";
import type { FakeHost } from "../src/testing.ts";
import { apply as applyOps } from "../src/delta.ts";
import { moveWhy } from "../src/move.ts";
import { call, subscribe } from "./helpers.ts";
import { overview, started, stationReplies, status } from "./station-fixture.ts";

// deno-lint-ignore no-explicit-any
type J = any;

/// Which station a request is for, as the wire says it (all answer at the same origin here).
const AT = "x-test-station";
const S = "ws/st";
const GB = 1024 ** 3;

const item = (id: string, label: string, state: string, more: Record<string, unknown> = {}) => ({ id, label, state, needs: [], ...more });
/// What a station's GET /move says: accounts (one there), chats (four, in each state), jobs (none).
const moved = (over: Record<string, unknown> = {}): J => ({
  ws: "ws", to: "st2",
  modules: [
    { id: "accounts", needs: [], done: 1, total: 2, items: [item("p-work", "Claude 工作", "there"), item("p-me", "本机登录", "here", { cannot: "这台机器自己的登录不迁：在那台上登录" })], more: null },
    {
      id: "chats", needs: ["accounts", "connects"], done: 1, total: 5,
      items: [
        item("k1", "修复登录", "moving", { progress: { done: 12 * 1024 ** 2, total: 40 * 1024 ** 2, unit: "bytes" } }),
        item("k2", "发版", "stopped", { waitsFor: "accounts p-work" }),
        item("k3", "整理文档", "failed", { error: "盘满了：在 mini 上腾出 2 GB 再试" }),
        item("k4", "周报", "there"),
        item("k5", "草稿", "here"),
      ],
      more: null,
    },
    { id: "jobs", needs: ["chats"], done: 0, total: 0, items: [], more: null },
  ],
  moving: { module: "chats", id: "k1", label: "修复登录", progress: { done: 12 * 1024 ** 2, total: 40 * 1024 ** 2, unit: "bytes" } },
  stopped: [{ item: "chats k2", waitsFor: "accounts p-work" }],
  last: { at: 1, by: "a@x.com", done: ["accounts p-work"], refused: [{ item: "chats k5", why: "它要的连接还没迁过去：先迁连接" }], stopped: [], resumed: [], failed: null },
  ...over,
});

/// A core reaching `ws/st` (studio, the one moved from), `ws/st2` (mini, offering moving) and `ws/st3` (lab, which
/// does not); each answers `answer(station, key, body)` for /move, and its overview as given.
async function rig(answer: (station: string, key: string, body: J) => unknown, role = "owner") {
  const asked: { station: string; key: string; body: J }[] = [];
  const reads: string[] = [];
  const wire = (host: FakeHost) => {
    const inner = new HostWire(host);
    return { request: (station: StationAddr, head: RequestHead, body: Uint8Array) => inner.request(station, { ...head, headers: [...head.headers, [AT, station.station]] }, body) } as StationWire;
  };
  const s = await started(undefined, 0, wire, (x) => {
    x.cloud.role = role;
    x.cloud.also = { stations: [{ id: "st", name: "studio", online: true, last_seen: null }, { id: "st2", name: "mini", online: true, last_seen: null }, { id: "st3", name: "lab", online: true, last_seen: null }] };
    stationReplies(x.host, (req: HttpRequest) => {
      const station = req.headers.find(([k]) => k === AT)?.[1] ?? "st";
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (path === "/overview") return { ...overview, move: { offered: station !== "st3" }, disk: { freeBytes: (station === "st2" ? 120 : 30) * GB, totalBytes: 500 * GB } };
      if (!/^\/move(\/|\?|$)/.test(path)) return undefined;
      const key = `${req.method} ${path}`;
      const body = req.body && req.body.length ? JSON.parse(new TextDecoder().decode(req.body)) : null;
      if (req.method === "GET") reads.push(`${station} ${path}`);
      else asked.push({ station, key, body });
      return answer(station, key, body);
    });
  });
  const ui = s.core.connect();
  const values = new Map<number, J>();
  const done = new Map<number, J>();
  const take = () => {
    for (const [, m] of s.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if ("value" in msg) values.set(msg.id as number, msg.value);
      else if ("delta" in msg) values.set(msg.id as number, applyOps(values.get(msg.id as number), msg.delta as never));
      else if ("ok" in msg || "error" in msg) done.set(msg.id as number, msg);
    }
  };
  let n = 100;
  const ask = async (name: string, params: Record<string, unknown>) => {
    const id = ++n;
    call(s.core, ui, id, name, params);
    await s.host.time.passUntil(2000, () => (take(), done.has(id)));
    await s.host.time.pass(100);
    take();
    return done.get(id);
  };
  const show = async (id: number, topic: Record<string, unknown>) => {
    subscribe(s.core, ui, id, { topic: "stationMove", station: S, ...topic } as never);
    await s.host.time.pass(500);
    take();
    return values.get(id);
  };
  return { ...s, ui, asked, reads, ask, show, view: (id: number) => (take(), values.get(id)) };
}

test("the page's value is what the station's GET /move says, a module's items only for the module open, each row in words", async () => {
  let said = moved();
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  assert.equal(r.reads.length, 0, "not read until a page shows it");
  const v = await r.show(1, { to: "st2", module: "chats" });
  assert.deepEqual(r.reads, ["st /move?to=st2&module=chats&limit=50"]);
  // (the other stations, each with its room, those it may go to first; lab offers none: why, and what makes it one)
  assert.deepEqual(v.targets, [
    { station: "st2", name: "mini", free: "空闲 120 GB", why: "" },
    { station: "st3", name: "lab", free: "空闲 30 GB", why: "正式版：在它的「软件与更新」里打开「测试版」后可选" },
  ]);
  assert.equal(v.toName, "mini");
  assert.equal(v.canMove, true);
  assert.equal(v.moving.line, "聊天 · 修复登录 · 12 MB / 40 MB");
  assert.equal(v.active, true);
  // (the modules that have items in the station's order, their needs, done of total; jobs, empty, not shown; while
  // a turn runs no action anywhere, the station answering any a 409: 停止 is the action then)
  assert.deepEqual(v.modules.map((m: J) => [m.id, m.needs, m.count, m.action, m.opens, m.items.length]), [
    ["accounts", [], "1 / 2", "", false, 0],
    ["chats", ["accounts", "connects"], "1 / 5", "", true, 5],
  ]);
  assert.equal(v.nothing, "");
  // (each row: where it stands at its end, why under it)
  assert.deepEqual(v.modules[1].items.map((x: J) => [x.label, x.state, x.stateText, x.note, x.progress?.text ?? null, x.action]), [
    ["修复登录", "moving", "迁移中", "", "12 MB / 40 MB", ""],
    ["发版", "stopped", "已停 · 等「Claude 工作」", "", null, ""],
    ["整理文档", "failed", "失败", "盘满了：在 mini 上腾出 2 GB 再试", null, ""],
    ["周报", "there", "已迁移", "", null, ""],
    ["草稿", "here", "", "它要的连接还没迁过去：先迁连接", null, ""],
  ]);
  assert.equal(v.allMove ?? null, null, "a turn runs: no 全部迁移");
  assert.equal(v.allBack ?? null, null, "a turn runs: no 全部迁回");
  // (its station's page's one row: where, done of total of all of it, what stands out the worst first)
  assert.deepEqual([v.title, v.count, v.note], ["迁移到 mini", "2 / 7", "1 项失败 · 1 项已停 · 迁移中 · 聊天「修复登录」"]);
  assert.equal(v.allThere, false);

  // The turn ended: each row's action back at its end (迁移 here, 迁回 there, 重试 failed; none stopped or where it
  // cannot move), each module's, 全部迁移 with how many cannot move on its line, 全部迁回.
  said = moved({ moving: null, modules: moved().modules.map((m: J) => (m.id === "chats" ? { ...m, items: m.items.map((x: J) => (x.id === "k1" ? item("k1", "修复登录", "here") : x)) } : m)) });
  r.pushOn([AT, "st"], "move", { changed: true });
  await r.host.time.pass(500);
  const idle = r.view(1);
  assert.deepEqual(idle.modules.map((m: J) => m.action), ["move", "move"]);
  assert.deepEqual(idle.modules[1].items.map((x: J) => [x.label, x.action]), [["修复登录", "move"], ["发版", ""], ["整理文档", "retry"], ["周报", "back"], ["草稿", "move"]]);
  assert.deepEqual([idle.allMove.n, idle.allMove.title, idle.allMove.text], [5, "全部迁移到 mini", "5 项 · 1 项无法迁移"]);
  assert.deepEqual([idle.allBack.n, idle.allBack.title], [2, "从 mini 全部迁回"]);

  // Another module open: its items alone, what cannot move said so.
  const a = await r.show(2, { to: "st2", module: "accounts" });
  assert.deepEqual(a.modules[0].items.map((x: J) => [x.label, x.state, x.stateText, x.note, x.action]), [
    ["Claude 工作", "there", "已迁移", "", "back"],
    ["本机登录", "cannot", "无法迁移", "这台机器自己的登录不迁：在那台上登录", ""],
  ]);
  assert.equal(a.modules[1].items.length, 0);

  // Every module empty: none shown, the card's one line.
  said = moved({ modules: [{ id: "jobs", needs: [], done: 0, total: 0, items: [], more: null }], moving: null, stopped: [], last: null });
  const none = await r.show(5, { to: "st2", module: "jobs" });
  assert.deepEqual([none.modules, none.nothing, none.allMove ?? null], [[], "没有要迁移的", null]);

  // A module all of which is there offers moving it back; the station's page, no target, says only whether it shows.
  said = moved({ modules: [{ id: "accounts", needs: [], done: 2, total: 2, items: [], more: null }], moving: null, stopped: [], last: null });
  const back = await r.show(3, { to: "st2" });
  assert.equal(back.modules[0].action, "back");
  const page = await r.show(4, {});
  assert.equal(page.active, false, "something of it there alone: no 迁移 on its page");
  assert.equal(page.title, "迁移", "no move said where it went");
  assert.equal(page.allMove ?? null, null, "no target: nothing offered");
  said = moved({ modules: [{ id: "accounts", needs: [], done: 0, total: 2, items: [item("p", "x", "here")], more: null }], moving: null, stopped: [], last: null });
  r.pushOn([AT, "st"], "move", { changed: true });
  await r.host.time.pass(500);
  assert.equal(r.view(4).active, false, "all of it here: no 迁移 on its page");
  r.core.close();
});

test("a chat at a third station says where it is, a stopped one where what it waits for is", async () => {
  // (the station names them: `at` of one on another station than the two this page is between, `waitsAt` of what a
  // stopped one waits for)
  const said = moved({
    moving: null,
    modules: [
      { id: "accounts", needs: [], done: 1, total: 1, items: [item("p-kimi", "Kimi Code", "there")], more: null },
      {
        id: "chats", needs: ["accounts"], done: 1, total: 3,
        items: [
          item("k1", "周报", "there", { at: "lab" }),
          item("k2", "发版", "stopped", { waitsFor: "accounts p-kimi", waitsAt: "mini" }),
          item("k3", "草稿", "stopped", { waitsFor: "accounts p-kimi" }),
        ],
        more: null,
      },
    ],
    stopped: [], last: null,
  });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  const v = await r.show(1, { to: "st2", module: "chats" });
  assert.deepEqual(v.modules[1].items.map((x: J) => [x.label, x.state, x.stateText]), [
    ["周报", "there", "在「lab」"],
    ["发版", "stopped", "已停，等「Kimi Code」（在「mini」）"],
    ["草稿", "stopped", "已停 · 等「Kimi Code」"],
  ]);
  r.core.close();
});

test("a chat moving says what it waits for: its turn's end, or the station it comes from", async () => {
  const said = moved({
    moving: null,
    modules: [
      {
        id: "chats", needs: [], done: 0, total: 3,
        items: [
          item("k1", "修复登录", "moving", { waits: "turn" }),
          item("k2", "发版", "moving", { waits: "station", from: "mini", waitsAt: "mini" }),
          item("k3", "草稿", "moving"),
        ],
        more: null,
      },
    ],
    stopped: [], last: null,
  });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  const v = await r.show(1, { to: "st2", module: "chats" });
  assert.deepEqual(v.modules[0].items.map((x: J) => [x.label, x.state, x.stateText]), [
    ["修复登录", "moving", "正在等这一轮对话结束"],
    ["发版", "moving", "正在从「mini」迁来，等「mini」应答"],
    ["草稿", "moving", "迁移中"],
  ]);
  r.core.close();
});

test("a stopped chat offers 迁移 where what it waits for is, its note the other way; one whose need is on a third station says where to go", async () => {
  const said = moved({
    moving: null,
    modules: [
      { id: "accounts", needs: [], done: 1, total: 1, items: [item("p-kimi", "Kimi Code", "there")], more: null },
      {
        id: "chats", needs: ["accounts"], done: 0, total: 3,
        items: [
          item("k1", "发版", "stopped", { waitsFor: "accounts p-kimi", waitsAt: "mini" }),
          item("k2", "周报", "stopped", { waitsFor: "accounts p-kimi", waitsAt: "lab" }),
          item("k3", "草稿", "stopped", { waitsFor: "accounts p-kimi" }),
        ],
        more: null,
      },
    ],
    stopped: [], last: null,
  });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  // (the page toward mini: Kimi Code is there)
  const v = await r.show(1, { to: "st2", module: "chats" });
  assert.equal(v.toName, "mini");
  assert.deepEqual(v.modules[1].items.map((x: J) => [x.label, x.action, x.note]), [
    ["发版", "move", "把「Kimi Code」迁回这里：在账号那一行"],
    ["周报", "", "在「lab」的迁移页上迁回「Kimi Code」，或把这个对话迁到「lab」"],
    ["草稿", "", ""],
  ]);
  r.core.close();
});

test("a login here that the other station borrows says so, and can still be moved", async () => {
  const said = moved({
    moving: null,
    modules: [
      { id: "accounts", needs: [], done: 0, total: 2, items: [item("p-work", "Claude 工作", "here", { lentTo: "mini" }), item("p-me", "本机登录", "here")], more: null },
    ],
    stopped: [], last: null,
  });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  const v = await r.show(1, { to: "st2", module: "accounts" });
  assert.deepEqual(v.modules[0].items.map((x: J) => [x.label, x.state, x.stateText, x.action]), [
    ["Claude 工作", "here", "在这里，「mini」可借用", "move"],
    ["本机登录", "here", "", "move"],
  ]);
  r.core.close();
});

test("its station's page shows 迁移 while a move runs, something is stopped waiting or a module's last turn failed, each with its words; something of it there alone shows none", async () => {
  // (no module open, no station named: the station's page's own read)
  const elsewhere = { modules: [{ id: "accounts", needs: [], done: 2, total: 2, items: [], more: null }, { id: "chats", needs: [], done: 1, total: 5, items: [], more: null }] };
  let said = moved({ ...elsewhere, moving: null, stopped: [], last: null });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  const shown = async (over: Record<string, unknown>) => {
    said = moved({ ...elsewhere, ...over });
    r.pushOn([AT, "st"], "move", { changed: true });
    await r.host.time.pass(500);
    const v = r.view(1);
    return [v.active, v.title, v.count, v.note];
  };
  const first = await r.show(1, {});
  assert.deepEqual([first.active, first.count], [false, "3 / 7"], "three of seven there, nothing else: no 迁移");
  assert.deepEqual(await shown({ stopped: [], last: null }), [true, "迁移", "3 / 7", "迁移中 · 聊天「修复登录」"]);
  assert.deepEqual(await shown({ moving: null, last: null }), [true, "迁移", "3 / 7", "1 项已停"]);
  const failed = { at: 2, by: "a@x.com", done: [], refused: [], stopped: [], resumed: [], failed: { item: "chats k3", error: "盘满了：在 mini 上腾出 2 GB 再试" } };
  assert.deepEqual(await shown({ moving: null, stopped: [], last: failed }), [true, "迁移", "3 / 7", "1 项失败"]);
  assert.deepEqual(await shown({ moving: null, stopped: [], last: null }), [false, "迁移", "3 / 7", ""], "back to there alone: none again");
  r.core.close();
});

test("the modules in the page's order whatever order the station answers them in: what the chats need, the station's settings, the chats, their jobs; one not known last", async () => {
  // (as a station answers them, move/station.ts `modules`: accounts, chats, jobs, connects, repos, vault, settings; and
  // one this core does not know)
  const one = (id: string, needs: string[] = []) => ({ id, needs, done: 0, total: 1, items: [], more: null });
  const said = moved({
    modules: [one("accounts"), one("chats", ["accounts", "connects", "repos", "vault"]), one("later"), one("jobs", ["chats"]), one("connects"), one("repos"), one("vault"), one("settings")],
    moving: null, stopped: [], last: null,
  });
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  const v = await r.show(1, { to: "st2" });
  assert.deepEqual(v.modules.map((m: J) => m.id), ["accounts", "connects", "repos", "vault", "settings", "chats", "jobs", "later"]);
  r.core.close();
});

test("told `move` changed, what is shown is read again and changes by its rows", async () => {
  let said = moved();
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  await r.show(1, { to: "st2", module: "chats" });
  const before = r.reads.length;
  said = moved({
    modules: moved().modules.map((m: J) => (m.id === "chats" ? { ...m, done: 2, items: m.items.map((x: J) => (x.id === "k1" ? item("k1", "修复登录", "there") : x)) } : m)),
    moving: null,
  });
  r.pushOn([AT, "st"], "move", { changed: true });
  await r.host.time.pass(500);
  assert.equal(r.reads.length, before + 1, "read once again");
  const v = r.view(1);
  assert.equal(v.moving ?? null, null);
  assert.deepEqual([v.modules[1].count, v.modules[1].items[0].stateText, v.modules[1].items[0].action], ["2 / 5", "已迁移", "back"]);
  r.core.close();
});

test("told `move` changed, only the pages shown are read again; one let go of is read as it is shown again", async () => {
  let said = moved();
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? said : undefined));
  await r.show(1, { to: "st2", module: "chats" });
  // (another size of the same page, shown and let go of: kept a while by the store, not shown)
  await r.show(2, { to: "st2", module: "chats", limit: 7 });
  r.core.receive(r.ui, { kind: "unsubscribe", id: 2, unsubscribe: true } as never);
  await r.host.time.pass(500);
  const before = r.reads.length;
  said = moved({ moving: null });
  r.pushOn([AT, "st"], "move", { changed: true });
  await r.host.time.pass(500);
  assert.deepEqual(r.reads.slice(before), ["st /move?to=st2&module=chats&limit=50"], "the page shown alone");
  // Shown again while still kept: read then, not left as it was.
  const again = r.reads.length;
  await r.show(3, { to: "st2", module: "chats", limit: 7 });
  assert.deepEqual(r.reads.slice(again), ["st /move?to=st2&module=chats&limit=7"], "read as it is shown again");
  r.core.close();
});

test("a module's items a page after another, as far as the page asked", async () => {
  const many = Array.from({ length: 120 }, (_, i) => item(`k${i}`, `聊天 ${i}`, "here"));
  const r = await rig((_station, key) => {
    if (!key.startsWith("GET /move")) return undefined;
    const q = new URLSearchParams(key.slice(key.indexOf("?") + 1));
    const after = q.get("after");
    const from = after === null ? 0 : many.findIndex((x) => x.id === after) + 1;
    const page = many.slice(from, from + Number(q.get("limit") ?? 50));
    return moved({ modules: [{ id: "chats", needs: [], done: 0, total: 120, items: page, more: from + page.length < many.length ? page.at(-1)!.id : null }], moving: null, stopped: [], last: null });
  });
  const v = await r.show(1, { to: "st2", module: "chats", limit: 100 });
  assert.deepEqual(r.reads, ["st /move?to=st2&module=chats&limit=50", "st /move?to=st2&module=chats&limit=50&after=k49"]);
  assert.equal(v.modules[0].items.length, 100);
  assert.equal(v.modules[0].more, true);
  const all = await r.show(2, { to: "st2", module: "chats", limit: 200 });
  assert.equal(all.modules[0].items.length, 120);
  assert.equal(all.modules[0].more, false);
  r.core.close();
});

test("move and move back go to the station at once, what they did read again; a refusal is said in its words", async () => {
  let said = moved();
  const r = await rig((_station, key) => {
    if (key.startsWith("GET /move")) return said;
    if (key === "POST /move" || key === "POST /move/back") return { started: true };
    return undefined;
  });
  await r.show(1, { to: "st2", module: "chats" });
  const before = r.reads.length;
  said = moved({ moving: { module: "chats", id: "k5", label: "草稿", progress: null } });
  const ok = await r.ask("move.start", { station: S, to: "st2", module: "chats", item: "k5", withNeeds: true });
  assert.ok("ok" in ok, JSON.stringify(ok));
  assert.deepEqual(r.asked.at(-1), { station: "st", key: "POST /move", body: { to: "st2", module: "chats", item: "k5", withNeeds: true } });
  assert.ok(r.reads.length > before, "what it does read again");
  assert.equal(r.view(1).moving.line, "聊天 · 草稿");
  await r.ask("move.back", { station: S, from: "st2", module: "accounts" });
  assert.deepEqual(r.asked.at(-1), { station: "st", key: "POST /move/back", body: { from: "st2", module: "accounts" } });
  await r.ask("move.start", { station: S, to: "st2", all: true });
  assert.deepEqual(r.asked.at(-1)?.body, { to: "st2", all: true });
  r.core.close();

  // Refused (moving switched off there): the call says why, as the station says it.
  const off = await rig((_station, key) => {
    if (key.startsWith("GET /move")) return moved();
    if (key === "POST /move") return status(409, { error: "这台 station 还没开放在 station 之间迁移聊天：没有迁移任何内容。" });
    return undefined;
  });
  const refused = await off.ask("move.start", { station: S, to: "st2", module: "chats", item: "k5" });
  assert.equal(refused.error?.message, "这台 station 还没开放在 station 之间迁移聊天：没有迁移任何内容。");
  off.core.close();
});

test("one who is not an owner or admin is offered no action", async () => {
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? moved({ moving: null }) : undefined), "member");
  const v = await r.show(1, { to: "st2", module: "chats" });
  assert.equal(v.canMove, false);
  assert.deepEqual(v.modules.map((m: J) => m.action), ["", ""]);
  assert.deepEqual([...new Set(v.modules[1].items.map((x: J) => x.action))], [""]);
  assert.equal(v.allMove ?? null, null);
  r.core.close();
});

test("the station a station's things go to is kept on this device, by that station", async () => {
  const r = await rig((_station, key) => (key.startsWith("GET /move") ? moved() : undefined));
  subscribe(r.core, r.core.connect(), 9, { topic: "prefs" } as never);
  const done = await r.ask("prefs.set", { moveTo: { [S]: "st2" } });
  assert.ok("ok" in done, JSON.stringify(done));
  assert.equal(r.view(9)?.moveTo?.[S], "st2");
  await r.ask("prefs.set", { moveTo: { [S]: null } });
  assert.equal(r.view(9)?.moveTo?.[S], undefined);
  r.core.close();
});

test("the turn under way stopped: move.stop at once, stopping said till it ends; its station's page names where the last move went; all of it there", async () => {
  let said = moved({ last: { at: 1, by: "a@x.com", station: "st2", done: [], refused: [], stopped: [], resumed: [], failed: null } });
  const r = await rig((_station, key) => {
    if (key.startsWith("GET /move")) return said;
    if (key === "POST /move/stop") return { stopping: true };
    return undefined;
  });
  const page = await r.show(1, {});
  assert.equal(page.title, "迁移到 mini");
  await r.show(2, { to: "st2" });
  said = moved({ moving: { ...moved().moving, stopping: true } });
  const ok = await r.ask("move.stop", { station: S });
  assert.ok("ok" in ok, JSON.stringify(ok));
  assert.deepEqual(r.asked.at(-1), { station: "st", key: "POST /move/stop", body: {} });
  assert.equal(r.view(2).moving.stopping, true);
  said = moved({ modules: [{ id: "accounts", needs: [], done: 2, total: 2, items: [], more: null }], moving: null, stopped: [], last: null });
  r.pushOn([AT, "st"], "move", { changed: true });
  await r.host.time.pass(500);
  assert.equal(r.view(2).allThere, true);
  assert.equal(r.view(2).allMove ?? null, null);
  r.core.close();
});

test("a station it may not go to says why and what makes it one", () => {
  const stable = { move: { offered: false }, updates: [{ id: "station", channel: "stable" }] };
  assert.equal(moveWhy(true, { move: { offered: true } }), "");
  assert.equal(moveWhy(false, { move: { offered: true } }), "离线：它上线后可选");
  assert.equal(moveWhy(true, undefined), "正在读取…");
  assert.equal(moveWhy(true, { disk: {} }), "版本太旧：更新后可选");
  assert.equal(moveWhy(true, stable), "正式版：在它的「软件与更新」里打开「测试版」后可选");
  assert.equal(moveWhy(true, { move: { offered: false } }), "正式版：在它的「软件与更新」里打开「测试版」后可选");
  assert.equal(moveWhy(true, { ...stable, updates: [{ id: "station", channel: "beta" }] }), "它的 config.json 关掉了迁移（move: false）：去掉后可选");
});
