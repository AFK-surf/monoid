// Copies into a station's drive in the core (views/transfers.ts): the
// person's transfers on every station of the workspace, read as each stream opens and told as they change, in words; a
// copy from another station asked of the one the files are on first (its grant), then of the one they go to; one
// within a station asked of it alone; a transfer stopped or taken up again.
import assert from "node:assert/strict";
import { test } from "node:test";
import type { HttpRequest } from "../src/host.ts";
import { HostWire, type RequestHead, type StationWire } from "../src/station/wire.ts";
import type { StationAddr } from "../src/station/addr.ts";
import { type FakeHost, jsonResponse } from "../src/testing.ts";
import { apply as applyOps } from "../src/delta.ts";
import { apply, call, subscribe, v } from "./helpers.ts";
import { base, started, stationLater, stationReplies, status } from "./station-fixture.ts";

/// Which station a request is for, as the wire says it (both answer at the same origin here).
const AT = "x-test-station";

const transfer = (over: Record<string, unknown> = {}) => ({
  id: "t1", by: "a@x.com", workspace: "ws", home: true, anywhere: true, move: false,
  from: { station: "st", stationName: "studio", root: "/Users/lin", path: "Documents", names: ["首页截图.png", "设置页.png"] },
  to: { root: "/Users/me", path: "照片" }, conflicts: {}, state: "copying", done: 0, at: 0, total: 2 * 1024 * 1024, copied: 1024 * 1024, count: 2, files: 2,
  current: "首页截图.png", createdAt: 5, ...over,
});

/// A core reaching `ws/st` (studio) and `ws/st2` (mini); each answers `answer(station, method, path, body)`.
async function rig(answer: (station: string, key: string, body: any) => unknown) {
  const asked: { station: string; key: string; body: any }[] = [];
  const wire = (host: FakeHost) => {
    const inner = new HostWire(host);
    return { request: (station: StationAddr, head: RequestHead, body: Uint8Array) => inner.request(station, { ...head, headers: [...head.headers, [AT, station.station]] }, body) } as StationWire;
  };
  const s = await started(undefined, 0, wire, (x) => {
    x.cloud.also = { stations: [{ id: "st", name: "studio", online: true, last_seen: null }, { id: "st2", name: "mini", online: true, last_seen: null }] };
    stationReplies(x.host, (req: HttpRequest) => {
      const station = req.headers.find(([k]) => k === AT)?.[1] ?? "st";
      const path = req.url.replace("https://stillfail.test/admin/api", "");
      if (!path.startsWith("/drive/transfers") && !path.startsWith("/drive/grant")) return undefined;
      const key = `${req.method} ${path}`;
      const body = req.body && req.body.length ? JSON.parse(new TextDecoder().decode(req.body)) : null;
      if (req.method !== "GET") asked.push({ station, key, body });
      return answer(station, key, body);
    });
  });
  const ui = s.core.connect();
  const values = new Map<number, any>();
  const done = new Map<number, any>();
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
  subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
  await s.host.time.pass(500);
  take();
  return { ...s, asked, ask, view: () => (take(), values.get(1)) };
}

test("the person's transfers on every station, in words; told as they change", async () => {
  const r = await rig((station, key) => {
    if (key !== "GET /drive/transfers") return undefined;
    return station === "st2" ? { transfers: [transfer()] } : status(404, { error: "no route" });
  });
  const v = r.view();
  assert.equal(v.supported, true);
  assert.equal(v.loaded, true);
  const [t] = v.transfers;
  assert.deepEqual(
    [t.station, t.stationName, t.fromStation, t.fromStationName, t.title, t.toText, t.statusText, t.progress, t.active, t.current],
    ["ws/st2", "mini", "ws/st", "studio", "首页截图.png 等 2 项", "mini › 照片", "1.0 MB / 2.0 MB", 0.5, true, "首页截图.png"],
  );
  // Done, as a station tells it.
  r.push("drive-transfers", { transfer: transfer({ id: "t9", from: { station: null, root: "/a", path: "", names: ["b.txt"] }, to: { root: "/a", path: "" }, state: "done", copied: 3, total: 3, endedAt: 9, createdAt: 9 }) });
  await r.host.time.pass(100);
  const after = r.view();
  assert.deepEqual(after.transfers.map((x: any) => x.id), ["t9", "t1"], "newest first");
  // From the station's own drive (the stream it came on is the one it runs on).
  const nine = after.transfers[0];
  const name = nine.station === "ws/st" ? "studio" : "mini";
  assert.deepEqual([nine.fromStation, nine.title, nine.statusText, nine.progress, nine.active, nine.toText], [nine.station, "b.txt", "已完成 · 3 B", 1, false, `${name} › a`]);
  r.core.close();
});

test("a transfer list read keeps changes told while its answer was on the way", async () => {
  const answers = { ...base(), "GET /drive/transfers": { transfers: [transfer(), transfer({ id: "old", createdAt: 1 })] } };
  const held: (() => void)[] = [];
  const s = await started(answers, 0, undefined, ({ host }) => {
    stationLater(host, (req) => {
      if (req.method !== "GET" || !req.url.endsWith("/drive/transfers")) return undefined;
      const response = jsonResponse(200, answers["GET /drive/transfers"]);
      return new Promise((resolve) => held.push(() => resolve(response)));
    });
  });
  try {
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    await s.host.settle();
    assert.ok(held.length > 0, "the station's list has not arrived yet");
    const done = transfer({ state: "done", copied: 2 * 1024 * 1024, endedAt: 10 });
    const added = transfer({ id: "new", createdAt: 11 });
    s.push("drive-transfers", { transfer: transfer({ copied: 1536 * 1024 }) });
    s.push("drive-transfers", { transfer: done });
    s.push("drive-transfers", { transfer: added });
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), [["new", "copying"], ["t1", "done"]]);
    for (const answer of held.splice(0)) answer();
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), [["new", "copying"], ["t1", "done"], ["old", "copying"]], "the read adds old rows without losing the new transfer or rolling back completion");
    // A later read with no intervening event still replaces the list, including transfers the station no longer keeps.
    answers["GET /drive/transfers"] = { transfers: [added] };
    stationLater(s.host, () => undefined);
    s.core.inner.stations.snapshot("ws/st");
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => t.id), ["new"]);
  } finally { s.core.close(); }
});

test("a transfer list read keeps new events first without moving updated rows", async () => {
  // Transfers created in the same millisecond keep the order established by their events.
  const answers = { ...base(), "GET /drive/transfers": { transfers: [transfer(), transfer({ id: "old" })] } };
  const s = await started(answers);
  const held: (() => void)[] = [];
  try {
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => t.id), ["t1", "old"]);
    stationLater(s.host, (req) => {
      if (req.method !== "GET" || !req.url.endsWith("/drive/transfers")) return undefined;
      const response = jsonResponse(200, answers["GET /drive/transfers"]);
      return new Promise((resolve) => held.push(() => resolve(response)));
    });
    s.core.inner.stations.snapshot("ws/st");
    await s.host.settle();
    assert.equal(held.length, 1);
    s.push("drive-transfers", { transfer: transfer({ id: "new-1" }) });
    s.push("drive-transfers", { transfer: transfer({ id: "new-2" }) });
    s.push("drive-transfers", { transfer: transfer({ id: "old", state: "done" }) });
    s.push("drive-transfers", { transfer: transfer({ id: "new-1", state: "done" }) });
    await s.host.settle();
    const expected = [["new-2", "copying"], ["new-1", "done"], ["t1", "copying"], ["old", "done"]];
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), expected, "updates keep existing rows in place");
    held[0]!();
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), expected,
      "the delayed list keeps multiple new events newest first and updates old rows in place");
  } finally { s.core.close(); }
});

for (const newerFirst of [false, true]) test(`overlapping transfer reads keep the newer list (${newerFirst ? "newer" : "older"} answer first)`, async () => {
  const answers = { ...base(), "GET /drive/transfers": { transfers: [transfer(), transfer({ id: "old", createdAt: 1 })] } };
  const s = await started(answers);
  const held: (() => void)[] = [];
  try {
    stationLater(s.host, (req) => {
      if (req.method !== "GET" || !req.url.endsWith("/drive/transfers")) return undefined;
      const response = jsonResponse(200, answers["GET /drive/transfers"]);
      return new Promise((resolve) => held.push(() => resolve(response)));
    });
    s.core.inner.stations.snapshot("ws/st");
    await s.host.settle();
    assert.equal(held.length, 1);
    answers["GET /drive/transfers"] = { transfers: [transfer({ state: "done", copied: 2 * 1024 * 1024, endedAt: 10 })] };
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    await s.host.settle();
    assert.equal(held.length, 2, "the sync and shown-topic reads use separate scheduler keys");
    held[newerFirst ? 1 : 0]!();
    await s.host.settle();
    held[newerFirst ? 0 : 1]!();
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), [["t1", "done"]], "the newer read supplies progress and removes expired rows, in either arrival order");
  } finally { s.core.close(); }
});

test("a late 404 cannot clear transfers told while the read was in flight", async () => {
  const held: (() => void)[] = [];
  const s = await started(undefined, 0, undefined, ({ host }) => {
    stationLater(host, (req) => {
      if (req.method !== "GET" || !req.url.endsWith("/drive/transfers")) return undefined;
      return new Promise((resolve) => held.push(() => resolve(jsonResponse(404, { error: "no route" }))));
    });
  });
  try {
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    await s.host.settle();
    assert.ok(held.length > 0);
    s.push("drive-transfers", { transfer: transfer({ state: "done" }) });
    await s.host.settle();
    assert.equal(now().supported, true);
    for (const answer of held.splice(0)) answer();
    await s.host.settle();
    assert.equal(now().supported, true);
    assert.deepEqual(now().transfers.map((t: any) => [t.id, t.state]), [["t1", "done"]]);
  } finally { s.core.close(); }
});

test("a transfer read from a removed link cannot replace the same station's new link", async () => {
  const s = await started({ ...base(), "GET /drive/transfers": { transfers: [] } });
  const held: (() => void)[] = [];
  try {
    stationLater(s.host, (req) => {
      if (req.method !== "GET" || !req.url.endsWith("/drive/transfers")) return undefined;
      const response = jsonResponse(200, { transfers: [transfer({ id: "old" })] });
      return new Promise((resolve) => held.push(() => resolve(response)));
    });
    s.core.inner.stations.snapshot("ws/st");
    await s.host.settle();
    assert.equal(held.length, 1);
    const old = s.core.inner.stations.link("ws/st");
    const topic = { topic: "workspace", workspace: "ws" } as const;
    const workspace = s.core.inner.data.shared(topic);
    s.core.inner.data.update(topic, (w) => ({ ...(w as object), stations: [] }));
    s.core.inner.stations.reconcile();
    await s.host.settle();
    assert.equal(s.core.inner.stations.link("ws/st"), undefined);
    s.core.inner.data.set(topic, workspace);
    s.core.inner.stations.reconcile();
    await s.host.settle();
    assert.notEqual(s.core.inner.stations.link("ws/st"), old);
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    s.push("drive-transfers", { transfer: transfer({ id: "new", state: "done" }) });
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => t.id), ["new"]);
    held[0]!();
    await s.host.settle();
    assert.deepEqual(now().transfers.map((t: any) => t.id), ["new"]);
  } finally { s.core.close(); }
});

for (const eventBeforeRead of [true, false]) test(`a delayed start response is not a new event (${eventBeforeRead ? "before" : "during"} the list read)`, async () => {
  const s = await started({ ...base(), "GET /drive/transfers": { transfers: [] } });
  try {
    const ui = s.core.connect();
    const values = new Map();
    const now = () => (apply(s.host, values), v(values, 1));
    subscribe(s.core, ui, 1, { topic: "driveTransfers", workspace: "ws" } as never);
    await s.host.settle();
    let startResponse: (() => void) | undefined;
    let listResponse: (() => void) | undefined;
    const done = transfer({ state: "done", copied: 2 * 1024 * 1024, endedAt: 10 });
    stationLater(s.host, (req) => {
      if (!req.url.endsWith("/drive/transfers")) return undefined;
      if (req.method === "POST") {
        const response = jsonResponse(200, { transfer: transfer({ state: "queued", copied: 0 }) });
        return new Promise((resolve) => { startResponse = () => resolve(response); });
      }
      if (req.method === "GET") {
        const response = jsonResponse(200, { transfers: [done] });
        return new Promise((resolve) => { listResponse = () => resolve(response); });
      }
      return undefined;
    });
    call(s.core, ui, 100, "drive.transfer", {
      from: { station: "ws/st", root: "/from", path: "", names: ["a.txt"] },
      to: { station: "ws/st", root: "/to", path: "" },
    });
    await s.host.settle();
    assert.ok(startResponse);
    if (eventBeforeRead) s.push("drive-transfers", { transfer: done });
    await s.host.settle();
    s.core.inner.stations.snapshot("ws/st");
    await s.host.settle();
    assert.ok(listResponse);
    if (!eventBeforeRead) s.push("drive-transfers", { transfer: done });
    await s.host.settle();
    assert.equal(now().transfers[0].state, "done");
    startResponse();
    await s.host.settle();
    listResponse();
    await s.host.settle();
    assert.equal(now().transfers[0].state, "done", "a delayed operation result must not override the completed snapshot or its event");
  } finally { s.core.close(); }
});

test("a copy from another station: granted where the files are, then copied where they go; within one, asked of it alone", async () => {
  const r = await rig((_station, key, body) => {
    if (key === "GET /drive/transfers") return { transfers: [] };
    if (key === "POST /drive/grant") return { grant: "g.sig", expires: 1 };
    if (key === "POST /drive/transfers") return { transfer: transfer({ id: "t2", state: "queued", copied: 0, from: { ...body.from, station: body.from.station ?? null } }) };
    if (key === "POST /drive/transfers/t2/cancel") return { transfer: transfer({ id: "t2", state: "cancelled", endedAt: 7 }) };
    return undefined;
  });
  const from = { station: "ws/st", root: "/Users/lin", path: "Documents", names: ["首页截图.png"] };
  const got = await r.ask("drive.transfer", { from, to: { station: "ws/st2", root: "/Users/me", path: "照片" }, conflicts: { "首页截图.png": "keep" } });
  assert.ok("ok" in got, JSON.stringify(got));
  assert.deepEqual(r.asked, [
    { station: "st", key: "POST /drive/grant", body: { root: "/Users/lin", path: "Documents", names: ["首页截图.png"], move: false } },
    { station: "st2", key: "POST /drive/transfers", body: { from: { station: "st", grant: "g.sig", root: "/Users/lin", path: "Documents", names: ["首页截图.png"] }, to: { root: "/Users/me", path: "照片" }, move: false, conflicts: { "首页截图.png": "keep" } } },
  ]);
  assert.equal(got.ok.transfer.statusText, "排队中");
  // Shown at once, before its station tells it.
  assert.deepEqual(r.view().transfers.map((x: any) => [x.id, x.station]), [["t2", "ws/st2"]]);
  const cancelled = await r.ask("drive.transfer.cancel", { station: "ws/st2", id: "t2" });
  assert.equal(cancelled.ok.transfer.statusText, "已取消");
  assert.equal(r.view().transfers[0].active, false);

  r.asked.length = 0;
  await r.ask("drive.transfer", { from: { ...from, station: "ws/st2" }, to: { station: "ws/st2", root: "/Users/me", path: "" }, move: true });
  assert.deepEqual(r.asked.map((a) => [a.station, a.key, a.body?.from?.station, a.body?.move]), [["st2", "POST /drive/transfers", undefined, true]]);

  const other = await r.ask("drive.transfer", { from: { ...from, station: "elsewhere/st" }, to: { station: "ws/st2", root: "/", path: "" } });
  assert.equal(other.error.code, "invalid_params");
  r.core.close();
});
