// A chat's files downloaded to this device by the core (views/downloads.ts): fetched a part at a time whatever page
// asked, how far each has come told to every page (`downloads`), kept with its chat as it comes, so the app that takes
// it reads it from the device; saved, called off or given up, what came stays kept (never asked of the station again),
// but where the app can read the copy saved back. One read in part before (a preview) goes on from there; one stopped
// by the app's end goes on as it starts again; one whose station is not reached waits for it; one that failed starts
// again when asked again.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Deferred, Effect } from "effect";
import type { FakeHost } from "../src/testing.ts";
import { Core } from "../src/core.ts";
import { handlers } from "../src/core/execute.ts";
import { Kind } from "../src/trace.ts";
import { AGAIN_MS, titleOf } from "../src/views/downloads.ts";
import { chatKeptId, sentKeptId } from "../src/drive-kept.ts";
import { RECONNECT_MS } from "../src/station/sync.ts";
import { HostError } from "../src/error.ts";
import { HostWire, type StationWire } from "../src/station/wire.ts";
import { BULK_LANE } from "../src/station/requests.ts";
import { apply as applyOps } from "../src/delta.ts";
import { call, subscribe } from "./helpers.ts";
import { Raw, started, stationReplies, status } from "./station-fixture.ts";

const ST = "ws/st";
const MB = 1024 * 1024;
const bytesOf = (n: number, from = 0) => Uint8Array.from({ length: n }, (_, i) => (from + i) % 251);

/// A station's drive as the tests have it: its files by root and path (`root\npath`), each as it is now (its mtime);
/// its folders zipped, where each zip is (a file of `drive` too).
type Drive = { files: Map<string, { bytes: Uint8Array; mtime: number }>; zips: Map<string, { root: string; path: string; name: string }> };

/// The session `k1`'s files (by name): their parts answered with the whole size; `broken` names answer 500, `away`
/// ones are not reached. `drive`: the station's drive, read a part at a time (`/drive/read`), a folder zipped
/// (`/drive/zip`).
function files(host: FakeHost, all: Map<string, Uint8Array>, broken: Set<string> = new Set(), away: Set<string> = new Set(), drive?: Drive): void {
  stationReplies(host, (req) => {
    const u = new URL(req.url);
    if (drive && u.pathname.endsWith("/drive/read")) {
      const f = drive.files.get(`${u.searchParams.get("root")}\n${u.searchParams.get("path")}`);
      if (f === undefined) return status(404, { error: "文件不存在" });
      const offset = Number(u.searchParams.get("offset"));
      const body = f.bytes.slice(offset, offset + Number(u.searchParams.get("length")));
      return new Raw({ status: 200, headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(f.bytes.length)], ["stillfail-mtime", String(f.mtime)]], body });
    }
    if (drive && u.pathname.endsWith("/drive/zip")) {
      const asked = JSON.parse(new TextDecoder().decode(req.body ?? new Uint8Array())) as { root: string; path: string };
      const z = drive.zips.get(`${asked.root}\n${asked.path}`);
      const f = z && drive.files.get(`${z.root}\n${z.path}`);
      return z && f ? status(200, { ...z, size: f.bytes.length }) : status(404, { error: "文件夹不存在" });
    }
    if (!u.pathname.endsWith("/sessions/k1/parts")) return undefined;
    const name = u.searchParams.get("name") ?? "";
    if (away.has(name)) throw new HostError("没连上");
    if (broken.has(name)) return status(500, { error: "磁盘读不出来" });
    const f = all.get(name);
    if (f === undefined) return status(404, { error: "文件不存在" });
    const offset = Number(u.searchParams.get("offset"));
    const body = f.slice(offset, offset + Number(u.searchParams.get("length")));
    return new Raw({ status: 200, headers: [["content-type", "application/zip"], ["stillfail-total", String(f.length)]], body });
  });
}

async function rig(all: Map<string, Uint8Array>, broken: Set<string> = new Set(), away: Set<string> = new Set()) {
  const t = await started();
  files(t.host, all, broken, away);
  return watch(t);
}

/// The core's downloads watched: its calls asked and answered, its list as it is told.
async function watch<T extends { host: FakeHost; core: Core }>(t: T) {
  const ui = t.core.connect();
  let list: any;
  const done = new Map<number, any>();
  const take = () => {
    for (const [, m] of t.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if (msg.id === 1 && "value" in msg) list = msg.value;
      else if (msg.id === 1 && "delta" in msg) list = applyOps(list, msg.delta as never);
      else if ("ok" in msg || "error" in msg) done.set(msg.id as number, msg);
    }
  };
  subscribe(t.core, ui, 1, { topic: "downloads" } as never);
  await t.host.settle();
  take();
  let n = 100;
  const ask = async (name: string, params: Record<string, unknown>) => {
    const id = ++n;
    call(t.core, ui, id, name, params);
    await t.host.settle();
    take();
    return done.get(id);
  };
  const parts = (name: string) => t.host.requests.filter((r) => r.url.includes("/sessions/k1/parts") && r.url.includes(`name=${name}&`)).length;
  const view = async () => { await t.host.settle(); take(); return list.downloads as any[]; };
  return { ...t, ask, parts, view };
}

test("a chat's file downloaded a part at a time, ready for the page that takes it, then read from the device", async () => {
  const zip = bytesOf(10 * MB, 3);
  const r = await rig(new Map([["build.zip", zip]]));
  // (a device's clock says fractions of a millisecond: the list says when in whole ones, as its shape has it)
  r.host.advance(0.387);
  const started = await r.ask("download.start", { station: ST, key: "k1", name: "build.zip", size: zip.length });
  const id = started.ok.download.id as string;
  assert.equal(started.ok.download.state, "going");
  const [d] = await r.view();
  assert.deepEqual([d.id, d.name, d.state, d.loaded, d.progress], [id, "build.zip", "ready", zip.length, 1]);
  assert.ok(Number.isSafeInteger(d.startedAt), String(d.startedAt));
  assert.equal(r.parts("build.zip"), 3, "three parts of 4 MB");
  // asked again while ready: the same one, nothing fetched again
  assert.equal((await r.ask("download.start", { station: ST, key: "k1", name: "build.zip", size: zip.length })).ok.download.id, id);
  assert.equal(r.parts("build.zip"), 3);
  // taken once, to be saved; a second page taking it gets nothing
  assert.deepEqual((await r.ask("download.take", { id })).ok, { taken: true });
  assert.deepEqual((await r.ask("download.take", { id })).ok, { taken: false });
  const [saving] = await r.view();
  assert.deepEqual([saving.state, saving.active], ["saving", true]);
  // what the app reads to save it comes off the device
  const read = await r.ask("station.file.part", { station: ST, key: "k1", name: "build.zip", offset: 4 * MB, length: 4 * MB, keep: true, size: zip.length });
  assert.deepEqual([...read.bytes.slice(0, 4)], [...zip.slice(4 * MB, 4 * MB + 4)]);
  assert.equal(r.parts("build.zip"), 3, "not asked of the station again");
  // saved where the app cannot read it back: out of the list, what came kept, read from the device after
  await r.ask("download.done", { id });
  assert.deepEqual(await r.view(), []);
  assert.equal(await Effect.runPromise(r.core.inner.driveKept.whole(id, zip.length)), true);
  await r.ask("station.file.part", { station: ST, key: "k1", name: "build.zip", offset: 0, length: 4 * MB, keep: true, size: zip.length });
  assert.equal(r.parts("build.zip"), 3);
  r.core.close();
});

for (const first of ["download", "preview"] as const) test(`a save and installer share outstanding parts, ${first} first`, async () => {
  const name = "2026-11-17T19-15-04-build.apk";
  const file = new Uint8Array(9 * MB).fill(7);
  const r = await rig(new Map([[name, file]]));
  const params = { station: ST, key: "k1", name, size: file.length, from: { session: "k1", file: { name: "build.apk", path: "uploads/" + name, size: file.length } } };
  const hold = r.host.hold(`offset=${4 * MB}&length=${4 * MB}`);
  const install = () => r.ask("station.file", { ...params, progress: true, keep: true });
  const save = () => r.ask("download.start", params);
  try {
    if (first === "download") { await save(); await install(); }
    else { await install(); await save(); }
    const view = r.core.inner.downloads.view();
    assert.equal(view.downloads.length + view.keeping.length, 1, "only one transfer of the file is listed");
    hold();
    await r.host.settle();
    assert.equal(r.parts(name), 3, "the same missing bytes never requested twice");
    assert.deepEqual((await install()).bytes, file);
    assert.equal(r.parts(name), 3);
  } finally {
    hold();
    r.core.close();
  }
});

for (const drive of [false, true]) test(`overlapping ${drive ? "drive" : "attachment"} ranges share only their intersection when a save is cancelled`, async () => {
  const file = Uint8Array.from({ length: 96 }, (_, i) => i);
  const t = await started();
  const name = "data.bin";
  const stationFile = { root: "/docs", path: name, mtime: 8 };
  const source = drive ? stationFile : { key: "k1" };
  files(t.host, new Map([[name, file]]), new Set(), new Set(), {
    files: new Map([["/docs\n" + name, { bytes: file, mtime: 8 }]]), zips: new Map(),
  });
  const r = await watch(t);
  const params = { station: ST, ...source, name, size: file.length };
  const ui = t.core.connect();
  const release = t.host.hold("offset=32&length=32");
  try {
    call(t.core, ui, 10, drive ? "drive.read" : "station.file.part", { ...params, offset: 32, length: 32, keep: drive ? "file" : true });
    await t.host.settle();
    const { ok } = await r.ask("download.start", params);
    // The player owns the middle of the range; the download only fetches the gap before it, then waits for it.
    const endpoint = drive ? "/drive/read?" : "/sessions/k1/parts?";
    const ranges = () => t.host.requests.filter((q) => q.url.includes(endpoint)).map((q) => {
      const p = new URL(q.url).searchParams;
      return [Number(p.get("offset")), Number(p.get("length"))];
    });
    assert.deepEqual(ranges(), [[32, 32], [0, 32]]);
    await r.ask("download.cancel", { id: ok.download.id });
    release();
    await t.host.settle();
    const got = await r.ask(drive ? "drive.read" : "station.file.part", { ...params, offset: 32, length: 32, keep: drive ? "file" : true });
    assert.deepEqual(got.bytes, file.slice(32, 64));
    assert.equal(ranges().length, 2, "the player completed even though the save stopped");
  } finally {
    release();
    t.core.close();
  }
});

test("cancelling the save that started a range leaves its installer reading", async () => {
  const file = new Uint8Array(16384).fill(2);
  const name = "tiny.apk";
  const r = await rig(new Map([[name, file]]));
  const params = { station: ST, key: "k1", name, size: file.length };
  const release = r.host.hold(`offset=0&length=${file.length}`);
  try {
    const { ok } = await r.ask("download.start", params);
    await r.ask("station.file", { ...params, keep: true });
    await r.ask("download.cancel", { id: ok.download.id });
    release();
    await r.host.settle();
    assert.deepEqual((await r.ask("station.file", { ...params, keep: true })).bytes, file);
    assert.equal(r.parts(name), 1);
  } finally {
    release();
    r.core.close();
  }
});

test("an installer with no listed size shares and reuses the bytes of the download", async () => {
  const file = new Uint8Array(65536).fill(3);
  const name = "old.apk";
  const r = await rig(new Map([[name, file]]));
  const params = { station: ST, key: "k1", name, size: 0 };
  const release = r.host.hold(`offset=0&length=${4 * MB}`);
  try {
    await r.ask("download.start", params);
    await r.ask("station.file", { ...params, keep: true });
    release();
    await r.host.settle();
    assert.deepEqual((await r.ask("station.file", { ...params, keep: true })).bytes, file);
    assert.equal(r.parts(name), 1);
  } finally {
    release();
    r.core.close();
  }
});

test("a second reader takes a completed range while the device is still writing it", async () => {
  const file = new Uint8Array(32768).fill(9);
  const name = "pending.apk";
  const r = await rig(new Map([[name, file]]));
  const write = Deferred.makeUnsafe<void>();
  const put = r.host.storageSet.bind(r.host);
  r.host.storageSet = (key, value) => key.startsWith("drive-kept-") ? Effect.andThen(Deferred.await(write), put(key, value)) : put(key, value);
  const params = { station: ST, key: "k1", name, size: file.length };
  try {
    await r.ask("download.start", params);
    assert.deepEqual((await r.ask("station.file", { ...params, keep: true })).bytes, file);
    assert.equal(r.parts(name), 1);
  } finally {
    Deferred.doneUnsafe(write, Effect.void);
    await r.host.settle();
    r.core.close();
  }
});

test("a chat file without a recorded size is read before it is ready, including an empty or missing file", async () => {
  const content = bytesOf(5 * MB, 7);
  const r = await rig(new Map([["old.zip", content], ["empty.zip", new Uint8Array()]]));
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "old.zip", size: 0 })).ok.download.id;
  const [d] = await r.view();
  assert.deepEqual([d.state, d.size, d.loaded], ["ready", content.length, content.length]);
  assert.equal(r.parts("old.zip"), 2);
  await r.ask("download.take", { id });
  const read = await r.ask("download.read", { id, offset: 0, length: 4 * MB });
  assert.deepEqual(read.bytes, content.subarray(0, 4 * MB));
  assert.equal(r.parts("old.zip"), 2, "the first part was kept, not fetched twice");

  await r.ask("download.start", { station: ST, key: "k1", name: "empty.zip", size: 0 });
  const empty = (await r.view()).find((entry) => entry.name === "empty.zip");
  assert.deepEqual([empty.state, empty.size], ["ready", 0]);
  assert.equal(r.parts("empty.zip"), 1);

  await r.ask("download.start", { station: ST, key: "k1", name: "missing.zip", size: 0 });
  const missing = (await r.view()).find((entry) => entry.name === "missing.zip");
  assert.equal(missing.state, "failed");
  r.core.close();
});

test("a file sent up is called as its sender named it, not as the station keeps it", () => {
  assert.equal(titleOf("2026-10-24T21-59-13-dc7ed5-e2e-tune.m4a"), "e2e-tune.m4a");
  assert.equal(titleOf("build.zip"), "build.zip");
  // (nothing after the mark: kept as it is)
  assert.equal(titleOf("2026-10-24T21-59-13-dc7ed5-"), "2026-10-24T21-59-13-dc7ed5-");
});

test("a chat download keeps the attachment's original name, including for agent files", async () => {
  const stored = "2026-11-14T04-39-37-report.zip";
  const r = await rig(new Map([[stored, bytesOf(4)]]));
  await r.ask("download.start", { station: ST, key: "k1", name: stored, size: 4, from: { session: "k1", file: { name: "report.zip", path: `C:\\station\\uploads\\${stored}`, size: 4 } } });
  const [download] = await r.view();
  assert.equal(download.name, stored);
  assert.equal(download.title, "report.zip");
  assert.equal(download.state, "ready");
  r.core.close();
});

test("saved, a file a viewer kept before stays kept: the device keeps what it kept before the download", async () => {
  const film = bytesOf(9 * MB, 5);
  const r = await rig(new Map([["film.mp4", film]]));
  await r.ask("station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 0, length: 4 * MB, keep: true, size: film.length });
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "film.mp4", size: film.length })).ok.download.id;
  assert.equal((await r.view())[0].state, "ready");
  await r.ask("download.take", { id });
  await r.ask("download.done", { id });
  assert.equal(await Effect.runPromise(r.core.inner.driveKept.has(id)), true);
  // read again: off the device
  await r.ask("station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 0, length: 4 * MB, keep: true, size: film.length });
  assert.equal(r.parts("film.mp4"), 3);
  r.core.close();
});

test("a download stopped by the app's end goes on as the core starts again, from what it had fetched; one taken and not saved is taken again", async () => {
  const big = bytesOf(12 * MB, 2);
  const small = bytesOf(MB, 4);
  const t = await started();
  files(t.host, new Map([["big.zip", big], ["small.zip", small]]));
  const r = await watch(t);
  const held = t.host.hold(`name=big.zip&offset=${4 * MB}&length=${4 * MB}`);
  await r.ask("download.start", { station: ST, key: "k1", name: "big.zip", size: big.length });
  const small1 = (await r.ask("download.start", { station: ST, key: "k1", name: "small.zip", size: small.length })).ok.download.id;
  assert.equal((await r.ask("download.take", { id: small1 })).ok.taken, true);
  const before = await r.view();
  assert.deepEqual(before.map((d) => [d.name, d.state, d.loaded]).sort(), [["big.zip", "going", 4 * MB], ["small.zip", "saving", MB]]);
  r.core.close();
  held();
  // started again over the same device
  const core = await Core.create(t.host, { clock: t.host.time.clock, sample: 0, wire: () => new HostWire(t.host) });
  await t.host.time.pass(500);
  const again = await watch({ host: t.host, core });
  const after = await again.view();
  assert.deepEqual(after.map((d) => [d.name, d.state, d.loaded]).sort(), [["big.zip", "ready", big.length], ["small.zip", "ready", MB]]);
  assert.equal(r.parts("big.zip"), 4, "its first part not fetched again (one asked and let go as the core stopped)");
  core.close();
});

test("a video's load written down as a download before fill.ts brought those goes on as fill.ts's, from what is kept", async () => {
  const film = bytesOf(9 * MB, 8);
  const t = await started();
  files(t.host, new Map([["film.mp4", film]]));
  const r = await watch(t);
  await r.ask("station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 0, length: 4 * MB, keep: true, size: film.length });
  const id = chatKeptId(ST, "k1", "film.mp4");
  await Effect.runPromise(r.core.inner.driveKept.noteDownload(id, { id, station: ST, from: { kind: "chat", key: "k1", file: "film.mp4" }, name: "film.mp4", size: film.length, keptBefore: true, startedAt: 1, keep: true }));
  r.core.close();
  const core = await Core.create(t.host, { clock: t.host.time.clock, sample: 0, wire: () => new HostWire(t.host) });
  await t.host.time.pass(500);
  const again = await watch({ host: t.host, core });
  assert.deepEqual(await again.view(), []);
  assert.equal(await Effect.runPromise(core.inner.driveKept.whole(id, film.length)), true);
  assert.equal(r.parts("film.mp4"), 3, "its first part not fetched again");
  assert.deepEqual(await Effect.runPromise(core.inner.driveKept.downloads()), []);
  core.close();
});

test("a download whose station is not reached waits for it, and goes on once it is", async () => {
  const zip = bytesOf(6 * MB, 9);
  const away = new Set(["far.zip"]);
  // (its link down too: its events stream not reached)
  const t = await started(undefined, 0, undefined, (s) => (s.gate.stream = "fail"));
  files(t.host, new Map([["far.zip", zip]]), new Set(), away);
  const r = await watch(t);
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "far.zip", size: zip.length })).ok.download.id;
  const [waiting] = await r.view();
  assert.deepEqual([waiting.state, waiting.active], ["waiting", true]);
  assert.ok(waiting.statusText.length > 0);
  // its station reached again: the link back online
  away.delete("far.zip");
  t.gate.stream = "open";
  await t.host.time.pass(RECONNECT_MS * 2 + 50, 50);
  const [back] = await r.view();
  assert.deepEqual([back.id, back.state], [id, "ready"]);
  r.core.close();
});

test("a part not answered while its station's link is up (a slow network's time out) is asked again, not left waiting for a station that never went", async () => {
  const zip = bytesOf(6 * MB, 9);
  const away = new Set(["slow.zip"]);
  const r = await rig(new Map([["slow.zip", zip]]), new Set(), away);
  assert.equal(r.core.inner.stations.online(ST), true);
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "slow.zip", size: zip.length })).ok.download.id;
  const [trying] = await r.view();
  assert.equal(trying.state, "going", "not said to wait for its station");
  const tried = r.parts("slow.zip");
  away.delete("slow.zip");
  await r.host.time.pass(AGAIN_MS + 50, 50);
  const [back] = await r.view();
  assert.deepEqual([back.id, back.state], [id, "ready"]);
  assert.ok(r.parts("slow.zip") > tried);
  r.core.close();
});

test("a download goes on from bytes received within a part when its connection cuts out", async () => {
  for (const source of ["chat", "chat-without-size", "drive"] as const) {
    const file = bytesOf(4 * MB, 9);
    const offsets: number[] = [];
    let transferred = 0;
    const t = await started(undefined, 0, (host) => {
      const fallback = new HostWire(host);
      return {
        request: (station, head, body) => {
          const u = new URL(head.path, "https://stillfail.test");
          if (!u.pathname.endsWith(source === "drive" ? "/drive/read" : "/sessions/k1/parts")) return fallback.request(station, head, body);
          const offset = Number(u.searchParams.get("offset"));
          const length = Number(u.searchParams.get("length"));
          offsets.push(offset);
          const cut = offsets.length <= 3;
          const size = Math.min(length, file.length - offset, cut ? MB : file.length);
          const data = file.slice(offset, offset + size);
          let sent = false;
          return Effect.succeed({
            status: 200,
            headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(file.length)], ...(source === "drive" ? [["stillfail-mtime", "7"] as [string, string]] : [])] as [string, string][],
            via: null,
            body: { take: Effect.suspend(() => {
              if (!sent) { sent = true; transferred += data.length; return Effect.succeed(data); }
              return cut ? Effect.fail(new HostError("connection lost")) : Effect.succeed(null);
            }) },
          });
        },
      };
    });
    const r = await watch(t);
    const params = source === "drive"
      ? { station: ST, root: "/drive", path: "film.mp4", name: "film.mp4", size: file.length, mtime: 7 }
      : { station: ST, key: "k1", name: "film.mp4", size: source === "chat" ? file.length : 0 };
    const id = (await r.ask("download.start", params)).ok.download.id;
    for (let i = 0; i < 3; i++) await t.host.time.pass(AGAIN_MS + 50, 50);
    assert.equal((await r.view())[0].state, "ready", source);
    assert.deepEqual(offsets, [0, MB, 2 * MB, 3 * MB], source);
    assert.equal(transferred, file.length, `${source}: no received bytes sent twice`);
    const read = await r.ask("download.read", { id, offset: 0, length: file.length });
    assert.deepEqual(read.bytes, file, source);
    t.core.close();
  }
});

test("a download cancelled during a part keeps the bytes already received", async () => {
  const file = bytesOf(2 * MB, 3);
  const first = 1024; // smaller than the streaming hand-off batch
  let requests = 0;
  const offsets: number[] = [];
  const t = await started(undefined, 0, (host) => {
    const fallback = new HostWire(host);
    return { request: (station, head, body) => {
      const u = new URL(head.path, "https://stillfail.test");
      if (!u.pathname.endsWith("/sessions/k1/parts")) return fallback.request(station, head, body);
      const offset = Number(u.searchParams.get("offset"));
      offsets.push(offset);
      const hold = ++requests === 1;
      let sent = false;
      return Effect.succeed({
        status: 200,
        headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(file.length)]] as [string, string][],
        via: null,
        body: { take: Effect.suspend(() => {
          if (!sent) { sent = true; return Effect.succeed(file.slice(offset, hold ? first : file.length)); }
          return hold ? Effect.never : Effect.succeed(null);
        }) },
      });
    } };
  });
  const r = await watch(t);
  const params = { station: ST, key: "k1", name: "film.mp4", size: file.length };
  const id = (await r.ask("download.start", params)).ok.download.id;
  await r.ask("download.cancel", { id });
  assert.equal(await Effect.runPromise(t.core.inner.driveKept.keptUntil(id, 0, file.length, 0, file.length)), first);
  await r.ask("download.start", params);
  assert.equal((await r.view())[0].state, "ready");
  assert.deepEqual(offsets, [0, first]);
  assert.deepEqual((await r.ask("download.read", { id, offset: 0, length: file.length })).bytes, file);
  t.core.close();
});

for (const sizeKnown of [true, false]) test(`restarting a download with ${sizeKnown ? "known" : "unknown"} size while cancellation saves a part keeps the new download resumable`, async () => {
  const file = bytesOf(2 * MB, 3);
  const t = await started(undefined, 0, (host) => {
    const fallback = new HostWire(host);
    return { request: (station, head, body) => {
      const u = new URL(head.path, "https://stillfail.test");
      if (!u.pathname.endsWith("/sessions/k1/parts")) return fallback.request(station, head, body);
      const offset = Number(u.searchParams.get("offset"));
      let sent = false;
      return Effect.succeed({
        status: 200,
        headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(file.length)]] as [string, string][],
        via: null,
        body: { take: Effect.suspend(() => {
          if (!sent) { sent = true; return Effect.succeed(file.slice(offset, offset + 1024)); }
          return Effect.never;
        }) },
      });
    } };
  });
  const r = await watch(t);
  const params = { station: ST, key: "k1", name: "film.mp4", size: sizeKnown ? file.length : 0 };
  const id = (await r.ask("download.start", params)).ok.download.id;
  const saved = Deferred.makeUnsafe<void>();
  const store = t.host.storageSet.bind(t.host);
  let saving = false;
  t.host.storageSet = (key, bytes) => {
    if (!saving && key.startsWith("drive-kept-")) {
      saving = true;
      return Effect.andThen(Deferred.await(saved), store(key, bytes));
    }
    return store(key, bytes);
  };
  await r.ask("download.cancel", { id });
  assert.equal(saving, true, "cancellation waits for the received part's write");
  assert.deepEqual(await r.view(), []);
  t.host.advance(1);
  const restarted = (await r.ask("download.start", params)).ok.download;
  assert.equal((await r.view())[0].id, id);
  Deferred.doneUnsafe(saved, Effect.void);
  await t.host.settle();
  assert.equal((await r.view())[0].id, id, "the restarted download stays visible");
  const noted = await Effect.runPromise(t.core.inner.driveKept.downloads());
  assert.equal(noted.length, 1, "the old cancellation cannot remove the restarted download's recovery record");
  assert.equal((noted[0] as { startedAt: number }).startedAt, restarted.startedAt, "the old cancellation cannot overwrite the restarted download's record");
  t.core.close();
  files(t.host, new Map([["film.mp4", file]]));
  const core = await Core.create(t.host, { clock: t.host.time.clock, sample: 0, wire: () => new HostWire(t.host) });
  await t.host.time.pass(500);
  const again = await watch({ host: t.host, core });
  assert.equal((await again.view())[0].state, "ready", "the new download resumes after the app restarts");
  core.close();
});

test("a cut reply for a different file version is not kept beside the old one", async () => {
  for (const source of ["chat", "drive"] as const) {
    const file = bytesOf(2 * MB);
    const t = await started(undefined, 0, (host) => {
      const fallback = new HostWire(host);
      return { request: (station, head, body) => {
        const u = new URL(head.path, "https://stillfail.test");
        if (!u.pathname.endsWith(source === "drive" ? "/drive/read" : "/sessions/k1/parts")) return fallback.request(station, head, body);
        let sent = false;
        return Effect.succeed({
          status: 200,
          headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(source === "chat" ? file.length + 1 : file.length)], ...(source === "drive" ? [["stillfail-mtime", "8"] as [string, string]] : [])] as [string, string][],
          via: null,
          body: { take: Effect.suspend(() => {
            if (!sent) { sent = true; return Effect.succeed(file.slice(0, MB)); }
            return Effect.fail(new HostError("connection lost"));
          }) },
        });
      } };
    });
    const r = await watch(t);
    const params = source === "drive"
      ? { station: ST, root: "/drive", path: "film.mp4", name: "film.mp4", size: file.length, mtime: 7 }
      : { station: ST, key: "k1", name: "film.mp4", size: file.length };
    const id = (await r.ask("download.start", params)).ok.download.id;
    assert.equal(await Effect.runPromise(t.core.inner.driveKept.has(id)), false, source);
    await r.ask("download.cancel", { id });
    t.core.close();
  }
});

test("a download goes on from what a preview kept of it; one that failed starts again when asked again; one called off is gone", async () => {
  const film = bytesOf(9 * MB, 7);
  const broken = new Set(["bad.zip"]);
  const r = await rig(new Map([["film.mp4", film], ["bad.zip", bytesOf(MB)]]), broken);
  // its first part read (and kept) by a preview
  await r.ask("station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 0, length: 4 * MB, keep: true, size: film.length });
  assert.equal(r.parts("film.mp4"), 1);
  await r.ask("download.start", { station: ST, key: "k1", name: "film.mp4", size: film.length });
  assert.equal((await r.view()).find((d) => d.name === "film.mp4").state, "ready");
  assert.equal(r.parts("film.mp4"), 3, "only the two parts not kept");
  // failed: said so, with why
  await r.ask("download.start", { station: ST, key: "k1", name: "bad.zip", size: MB });
  const bad = (await r.view()).find((d) => d.name === "bad.zip");
  assert.deepEqual([bad.state, bad.active], ["failed", false]);
  assert.ok(bad.error && bad.statusText.includes(bad.error), bad.statusText);
  // asked again once the station can: fetched again
  broken.delete("bad.zip");
  await r.ask("download.start", { station: ST, key: "k1", name: "bad.zip", size: MB });
  assert.equal((await r.view()).find((d) => d.name === "bad.zip").state, "ready");
  // called off: out of the list
  await r.ask("download.cancel", { id: bad.id });
  assert.equal((await r.view()).some((d) => d.name === "bad.zip"), false);
  r.core.close();
});

test("a download called off while it comes stops there, what came kept; asked again, only the rest is fetched", async () => {
  const big = bytesOf(12 * MB, 1);
  const t = await rig(new Map([["big.zip", big]]));
  const release = t.host.hold(`name=big.zip&offset=${4 * MB}&length=${4 * MB}`);
  const id = (await t.ask("download.start", { station: ST, key: "k1", name: "big.zip", size: big.length })).ok.download.id;
  const [going] = await t.view();
  assert.deepEqual([going.state, going.loaded], ["going", 4 * MB]);
  await t.ask("download.cancel", { id });
  release();
  assert.deepEqual(await t.view(), []);
  assert.equal(t.parts("big.zip"), 2, "the third part never asked");
  // what came of it kept: asked again, only what did not come
  assert.equal(await Effect.runPromise(t.core.inner.driveKept.has(id)), true);
  await t.ask("download.start", { station: ST, key: "k1", name: "big.zip", size: big.length });
  assert.equal((await t.view())[0].state, "ready");
  const asked = t.host.requests.filter((q) => q.url.includes("name=big.zip&")).map((q) => new URL(q.url).searchParams.get("offset"));
  // (the second never came: it was held as it was called off)
  assert.deepEqual(asked.slice(2), [String(4 * MB), String(8 * MB)], "the first part not asked again");
  t.core.close();
});

test("saved where the app can read it back, that is the file's copy on the device: what was kept of it goes, it is read from there; gone from there, read from the station and kept again", async () => {
  const zip = bytesOf(6 * MB, 11);
  const r = await rig(new Map([["build.zip", zip]]));
  const kept = () => [...r.host.storage.keys()].filter((k) => k.startsWith("drive-kept-")).length;
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "build.zip", size: zip.length })).ok.download.id;
  assert.equal((await r.view())[0].state, "ready");
  assert.equal(kept(), 2);
  await r.ask("download.take", { id });
  const at = "/Users/lin/Downloads/build.zip";
  r.host.saved.set(at, zip);
  await r.ask("download.done", { id, at });
  assert.deepEqual(await r.view(), []);
  assert.equal(kept(), 0, "no second copy kept beside the one saved");
  // opened again: read from where it was saved, not from the station
  const before = r.parts("build.zip");
  const read = await r.ask("station.file.part", { station: ST, key: "k1", name: "build.zip", offset: 4 * MB, length: 4 * MB, keep: true, size: zip.length });
  assert.deepEqual([...read.bytes], [...zip.slice(4 * MB)]);
  assert.equal(r.parts("build.zip"), before);
  const again = (await r.ask("download.start", { station: ST, key: "k1", name: "build.zip", size: zip.length })).ok.download.id;
  assert.equal((await r.view())[0].state, "ready");
  assert.equal(r.parts("build.zip"), before, "a second save reuses the same system copy as the preview");
  await r.ask("download.cancel", { id: again });
  // deleted from there: read from the station again, and kept as any other
  r.host.saved.delete(at);
  await r.ask("station.file.part", { station: ST, key: "k1", name: "build.zip", offset: 0, length: 4 * MB, keep: true, size: zip.length });
  assert.equal(r.parts("build.zip"), before + 1);
  assert.equal(kept(), 1);
  r.core.close();
});

test("where a chat's file was saved is said while it is still there (在访达中显示), and none once it is gone or was never saved", async () => {
  const pic = bytesOf(3 * MB, 5);
  const r = await rig(new Map([["shot.png", pic]]));
  const asked = { station: ST, key: "k1", name: "shot.png", size: pic.length };
  assert.deepEqual((await r.ask("download.saved", asked)).ok, { at: "" });
  const id = (await r.ask("download.start", asked)).ok.download.id;
  await r.view();
  await r.ask("download.take", { id });
  const at = "/Users/lin/Downloads/shot.png";
  r.host.saved.set(at, pic);
  await r.ask("download.done", { id, at });
  assert.deepEqual((await r.ask("download.saved", asked)).ok, { at });
  assert.deepEqual((await r.ask("download.saved", { ...asked, name: "other.png" })).ok, { at: "" });
  r.host.saved.delete(at);
  assert.deepEqual((await r.ask("download.saved", asked)).ok, { at: "" });
  r.core.close();
});

test("saving an attachment sent from this device reads the uploaded bytes locally", async () => {
  const r = await rig(new Map());
  const name = "posted.apk";
  const bytes = bytesOf(300, 9);
  await Effect.runPromise(r.core.inner.driveKept.keep(sentKeptId(ST, name), "sent", 0, bytes.length, "application/octet-stream", 0, bytes));
  const id = (await r.ask("download.start", { station: ST, key: "k1", name, size: 0 })).ok.download.id;
  const [d] = await r.view();
  assert.deepEqual([d.state, d.size], ["ready", bytes.length]);
  const read = await r.ask("download.read", { id, offset: 0, length: bytes.length });
  assert.deepEqual(read.bytes, bytes);
  assert.equal(r.parts(name), 0);
  r.core.close();
});

test("a saved drive copy is reused only for the same version, even at the same size", async () => {
  const old = bytesOf(32, 1), fresh = bytesOf(32, 9);
  const drive: Drive = { files: new Map([["docs\nlog", { bytes: old, mtime: 1 }]]), zips: new Map() };
  const r = await started();
  files(r.host, new Map(), new Set(), new Set(), drive);
  const t = await watch(r);
  const save = (mtime: number) => t.ask("download.start", { station: ST, root: "docs", path: "log", name: "log", size: old.length, mtime });
  const id = (await save(1)).ok.download.id;
  assert.equal((await t.view())[0].state, "ready");
  const at = "/Downloads/log";
  r.host.saved.set(at, old);
  await t.ask("download.done", { id, at });
  const reads = () => r.host.requests.filter((q) => q.url.includes("/drive/read")).length;
  await save(1);
  assert.equal((await t.view())[0].state, "ready");
  assert.equal(reads(), 1);
  await t.ask("download.done", { id });
  drive.files.set("docs\nlog", { bytes: fresh, mtime: 2 });
  await save(2);
  assert.equal((await t.view())[0].state, "ready");
  assert.equal(reads(), 2);
  assert.deepEqual((await t.ask("download.read", { id, offset: 0, length: old.length })).bytes, fresh);
  r.core.close();
});

test("saved where the app cannot read it back (the web's, iOS's): what came stays kept", async () => {
  const zip = bytesOf(MB, 13);
  const r = await rig(new Map([["notes.zip", zip]]));
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "notes.zip", size: zip.length })).ok.download.id;
  await r.view();
  await r.ask("download.take", { id });
  await r.ask("download.done", { id, at: "notes.zip" });
  assert.equal(await Effect.runPromise(r.core.inner.driveKept.whole(id, zip.length)), true);
  r.core.close();
});

test("a drive's file downloaded as its folder lists it, read off the device to be saved; changed on the station since, fetched as it is now", async () => {
  const doc = bytesOf(5 * MB, 17);
  const drive: Drive = { files: new Map([["docs\n报告/年报.pdf", { bytes: doc, mtime: 1700 }]]), zips: new Map() };
  const t = await started();
  files(t.host, new Map(), new Set(), new Set(), drive);
  const r = await watch(t);
  const reads = () => t.host.requests.filter((q) => q.url.includes("/drive/read")).length;
  const id = (await r.ask("download.start", { station: ST, root: "docs", path: "报告/年报.pdf", name: "年报.pdf", size: doc.length, mtime: 1700 })).ok.download.id;
  const [d] = await r.view();
  assert.deepEqual([d.root, d.path, d.name, d.state, d.key], ["docs", "报告/年报.pdf", "年报.pdf", "ready", undefined]);
  assert.equal(reads(), 2);
  await r.ask("download.take", { id });
  const part = await r.ask("download.read", { id, offset: 4 * MB, length: 4 * MB });
  assert.deepEqual([...part.bytes], [...doc.slice(4 * MB)]);
  assert.equal(reads(), 2, "off the device");
  await r.ask("download.done", { id });
  // changed on the station since (its folder read again: another mtime, the size not yet known): what was kept of it
  // as it was let go, fetched as it is now, from its start
  const now = bytesOf(3 * MB, 19);
  drive.files.set("docs\n报告/年报.pdf", { bytes: now, mtime: 1800 });
  const again = (await r.ask("download.start", { station: ST, root: "docs", path: "报告/年报.pdf", name: "年报.pdf", size: doc.length, mtime: 1800 })).ok.download.id;
  const [d2] = await r.view();
  assert.deepEqual([d2.state, d2.size], ["ready", now.length]);
  await r.ask("download.take", { id: again });
  const whole = await r.ask("download.read", { id: again, offset: 0, length: 4 * MB });
  assert.deepEqual([...whole.bytes], [...now]);
  r.core.close();
});

test("a drive's file whose size nobody said is read before it is ready, an empty one too", async () => {
  const movie = bytesOf(5 * MB, 23);
  const drive: Drive = { files: new Map([["/tmp/rec\nmovie.mp4", { bytes: movie, mtime: 1800 }], ["/tmp/rec\nempty.mp4", { bytes: new Uint8Array(), mtime: 1801 }]]), zips: new Map() };
  const t = await started();
  files(t.host, new Map(), new Set(), new Set(), drive);
  const r = await watch(t);
  const id = (await r.ask("download.start", { station: ST, root: "/tmp/rec", path: "movie.mp4", name: "recording.mp4", size: 0, mtime: 0 })).ok.download.id;
  const [d] = await r.view();
  assert.deepEqual([d.state, d.size, d.loaded], ["ready", movie.length, movie.length]);
  await r.ask("download.take", { id });
  const read = await r.ask("download.read", { id, offset: 0, length: 4 * MB });
  assert.deepEqual(read.bytes, movie.subarray(0, 4 * MB));
  await r.ask("download.start", { station: ST, root: "/tmp/rec", path: "empty.mp4", name: "empty.mp4", size: 0, mtime: 0 });
  const empty = (await r.view()).find((entry) => entry.name === "empty.mp4");
  assert.deepEqual([empty.state, empty.size], ["ready", 0]);
  r.core.close();
});

test("a folder downloaded: zipped on the station first (正在打包), then fetched as a file of the drive", async () => {
  const zip = bytesOf(2 * MB, 23);
  const drive: Drive = {
    files: new Map([[".stillfail-zips\n设计稿.zip", { bytes: zip, mtime: 99 }]]),
    zips: new Map([["docs\n设计稿", { root: ".stillfail-zips", path: "设计稿.zip", name: "设计稿.zip" }]]),
  };
  const t = await started();
  files(t.host, new Map(), new Set(), new Set(), drive);
  const r = await watch(t);
  const held = t.host.hold("/drive/zip");
  const id = (await r.ask("download.start", { station: ST, root: "docs", path: "设计稿", name: "设计稿.zip", zip: true })).ok.download.id;
  const [zipping] = await r.view();
  assert.deepEqual([zipping.root, zipping.path, zipping.zip, zipping.state], ["docs", "设计稿", true, "going"]);
  assert.ok(zipping.statusText.length > 0);
  held();
  const [d] = await r.view();
  assert.deepEqual([d.id, d.state, d.size, d.name], [id, "ready", zip.length, "设计稿.zip"]);
  await r.ask("download.take", { id });
  const part = await r.ask("download.read", { id, offset: 0, length: 4 * MB });
  assert.deepEqual([...part.bytes], [...zip]);
  r.core.close();
});

for (const source of ["chat", "drive"] as const) test(`multi-way striped download fetches ${source} parts concurrently across lanes`, async () => {
  const file = bytesOf(12 * MB, source === "chat" ? 11 : 17);
  let inflight = 0;
  let maxInflight = 0;
  let count = 0;
  const lanes: (string | undefined)[] = [];
  const gates: Deferred.Deferred<void>[] = [];
  let hold = true;
  const t = await started(undefined, 0, (host): StationWire => {
    const fallback = new HostWire(host);
    return {
      bulkLanes: () => 2,
      request: (station, head, body) => {
        const u = new URL(head.path, "https://stillfail.test");
        if (!u.pathname.endsWith(source === "drive" ? "/drive/read" : "/sessions/k1/parts")) return fallback.request(station, head, body);
        return Effect.suspend(() => {
          count++;
          lanes.push(head.headers.find(([k]) => k.toLowerCase() === BULK_LANE)?.[1]);
          inflight++;
          maxInflight = Math.max(maxInflight, inflight);
          const gate = hold && gates.length < 2 ? Deferred.makeUnsafe<void>() : null;
          if (gate !== null) gates.push(gate);
          return (gate !== null ? Effect.andThen(Deferred.await(gate), fallback.request(station, head, body)) : fallback.request(station, head, body)).pipe(
            Effect.ensuring(Effect.sync(() => { inflight--; })),
          );
        });
      },
    };
  });
  files(t.host, new Map([["big.bin", file]]), new Set(), new Set(), {
    files: new Map([["docs\nbig.bin", { bytes: file, mtime: 42 }]]),
    zips: new Map(),
  });
  const r = await watch(t);
  const params = source === "drive"
    ? { station: ST, root: "docs", path: "big.bin", name: "big.bin", size: file.length, mtime: 42 }
    : { station: ST, key: "k1", name: "big.bin", size: file.length };
  const id = (await r.ask("download.start", params)).ok.download.id as string;
  assert.equal(gates.length, 2, `${source}: expected 2 concurrent parts in flight`);
  assert.equal(maxInflight, 2, `${source}: maxInflight should be 2`);
  hold = false;
  for (const g of gates) Deferred.doneUnsafe(g, Effect.void);
  const [d] = await r.view();
  assert.deepEqual([d.state, d.loaded], ["ready", file.length]);
  assert.equal(count, 3, `${source}: no duplicate part requests`);
  assert.deepEqual([...lanes].sort(), ["0", "1", "2"], `${source}: parts assigned distinct lanes`);
  await r.ask("download.take", { id });
  const out = new Uint8Array(file.length);
  for (let off = 0; off < file.length; off += 4 * MB) {
    const got = await r.ask("download.read", { id, offset: off, length: 4 * MB });
    out.set(got.bytes, off);
  }
  assert.deepEqual(out, file);
  t.core.close();
});

test("cancelling a multi-way download preserves received bytes from concurrent parts and resumes only missing ranges", async () => {
  const file = bytesOf(12 * MB, 29);
  const prefix = 64 * 1024;
  let phase: "cut" | "full" = "cut";
  let inflight = 0;
  let maxInflight = 0;
  const resumed: [number, number][] = [];
  const t = await started(undefined, 0, (host): StationWire => {
    const fallback = new HostWire(host);
    return {
      bulkLanes: () => 2,
      request: (station, head, body) => {
        const u = new URL(head.path, "https://stillfail.test");
        if (!u.pathname.endsWith("/sessions/k1/parts")) return fallback.request(station, head, body);
        const offset = Number(u.searchParams.get("offset"));
        const length = Number(u.searchParams.get("length"));
        if (phase === "full") {
          resumed.push([offset, length]);
          return fallback.request(station, head, body);
        }
        return Effect.gen(function* () {
          inflight++;
          maxInflight = Math.max(maxInflight, inflight);
          yield* Effect.addFinalizer(() => Effect.sync(() => { inflight--; }));
          let sent = false;
          return {
            status: 200,
            headers: [["content-type", "application/octet-stream"], ["stillfail-total", String(file.length)]] as [string, string][],
            via: null,
            body: {
              take: Effect.suspend(() => {
                if (!sent) {
                  sent = true;
                  return Effect.succeed(file.slice(offset, offset + prefix));
                }
                return Effect.never;
              }),
            },
          };
        });
      },
    };
  });
  files(t.host, new Map([["big.bin", file]]));
  const r = await watch(t);
  const params = { station: ST, key: "k1", name: "big.bin", size: file.length };
  const id = (await r.ask("download.start", params)).ok.download.id as string;
  assert.equal(maxInflight, 2);
  await r.ask("download.cancel", { id });
  assert.equal(await Effect.runPromise(t.core.inner.driveKept.keptUntil(id, 0, file.length, 0, file.length)), prefix);
  assert.equal(await Effect.runPromise(t.core.inner.driveKept.keptUntil(id, 0, file.length, 4 * MB, file.length)), 4 * MB + prefix);
  phase = "full";
  await r.ask("download.start", params);
  const [d] = await r.view();
  assert.equal(d.state, "ready");
  assert.deepEqual([...resumed].sort((a, b) => a[0] - b[0]), [[prefix, 4 * MB - prefix], [4 * MB + prefix, 4 * MB], [8 * MB + prefix, 4 * MB - prefix]]);
  await r.ask("download.take", { id });
  const out = new Uint8Array(file.length);
  for (let off = 0; off < file.length; off += 4 * MB) {
    const got = await r.ask("download.read", { id, offset: off, length: 4 * MB });
    out.set(got.bytes, off);
  }
  assert.deepEqual(out, file);
  t.core.close();
});

test("download dynamically upgrades from 1 lane to 2 concurrent lanes when bulkLanes increases mid-download", async () => {
  const file = bytesOf(12 * MB, 37);
  let lanesNow = 1;
  let inflight = 0;
  let maxInflightAfterUpgrade = 0;
  const partLanes: { offset: number; lane: string | undefined }[] = [];
  let firstGate: Deferred.Deferred<void> | null = null;
  const upgradedGates: Deferred.Deferred<void>[] = [];
  const t = await started(undefined, 0, (host): StationWire => {
    const fallback = new HostWire(host);
    return {
      bulkLanes: () => lanesNow,
      request: (station, head, body) => {
        const u = new URL(head.path, "https://stillfail.test");
        if (!u.pathname.endsWith("/sessions/k1/parts")) return fallback.request(station, head, body);
        const offset = Number(u.searchParams.get("offset"));
        return Effect.suspend(() => {
          const lane = head.headers.find(([k]) => k.toLowerCase() === BULK_LANE)?.[1];
          partLanes.push({ offset, lane });
          inflight++;
          if (lanesNow > 1) maxInflightAfterUpgrade = Math.max(maxInflightAfterUpgrade, inflight);
          let gate: Deferred.Deferred<void> | null = null;
          if (offset === 0 && firstGate === null) {
            firstGate = gate = Deferred.makeUnsafe<void>();
          } else if (lanesNow > 1 && upgradedGates.length < 2) {
            gate = Deferred.makeUnsafe<void>();
            upgradedGates.push(gate);
          }
          return (gate !== null ? Effect.andThen(Deferred.await(gate), fallback.request(station, head, body)) : fallback.request(station, head, body)).pipe(
            Effect.ensuring(Effect.sync(() => { inflight--; })),
          );
        });
      },
    };
  });
  files(t.host, new Map([["grow.bin", file]]));
  const r = await watch(t);
  const id = (await r.ask("download.start", { station: ST, key: "k1", name: "grow.bin", size: file.length })).ok.download.id as string;
  assert.equal(partLanes.length, 1, "starts single-lane when bulkLanes() === 1");
  assert.deepEqual(partLanes[0], { offset: 0, lane: undefined });
  // Fast relays discovered while first part is in flight.
  lanesNow = 2;
  Deferred.doneUnsafe(firstGate!, Effect.void);
  await t.host.settle();
  assert.equal(upgradedGates.length, 2, "remaining 2 parts must launch concurrently after bulkLanes rises to 2");
  assert.equal(maxInflightAfterUpgrade, 2);
  const upgraded = partLanes.slice(1).map((p) => p.lane).sort();
  assert.deepEqual(upgraded, ["0", "1"], "concurrent parts must carry distinct BULK_LANE headers");
  for (const g of upgradedGates) Deferred.doneUnsafe(g, Effect.void);
  const [d] = await r.view();
  assert.deepEqual([d.state, d.loaded], ["ready", file.length]);
  await r.ask("download.take", { id });
  const out = new Uint8Array(file.length);
  for (let off = 0; off < file.length; off += 4 * MB) {
    const got = await r.ask("download.read", { id, offset: off, length: 4 * MB });
    out.set(got.bytes, off);
  }
  assert.deepEqual(out, file);
  t.core.close();
});

test("concurrent foreground station.file.part >= 256 KiB auto-stripes across bulk lanes without explicit lane", async () => {
  const file = bytesOf(2 * MB, 53);
  const seen: { offset: number; length: number; lane: string | undefined }[] = [];
  const gates: Deferred.Deferred<void>[] = [];
  const t = await started(undefined, 0, (host): StationWire => {
    const fallback = new HostWire(host);
    return {
      bulkLanes: () => 2,
      request: (station, head, body) => {
        const u = new URL(head.path, "https://stillfail.test");
        if (!u.pathname.endsWith("/sessions/k1/parts")) return fallback.request(station, head, body);
        return Effect.suspend(() => {
          const offset = Number(u.searchParams.get("offset"));
          const length = Number(u.searchParams.get("length"));
          const lane = head.headers.find(([k]) => k.toLowerCase() === BULK_LANE)?.[1];
          seen.push({ offset, length, lane });
          if (length >= 256 * 1024 && gates.length < 2) {
            const gate = Deferred.makeUnsafe<void>();
            gates.push(gate);
            return Effect.andThen(Deferred.await(gate), fallback.request(station, head, body));
          }
          return fallback.request(station, head, body);
        });
      },
    };
  });
  files(t.host, new Map([["video.mp4", file]]));
  const ui = t.core.connect();
  const done = new Map<number, any>();
  const take = () => {
    for (const [, m] of t.host.takeEmitted()) {
      const msg = m as Record<string, unknown>;
      if ("ok" in msg || "error" in msg) done.set(msg.id as number, msg);
    }
  };
  // Two concurrent foreground >= 256 KiB parts without explicit lane must auto-assign distinct lanes.
  call(t.core, ui, 201, "station.file.part", { station: ST, key: "k1", name: "video.mp4", offset: 0, length: 512 * 1024, keep: true, size: file.length });
  call(t.core, ui, 202, "station.file.part", { station: ST, key: "k1", name: "video.mp4", offset: 512 * 1024, length: 512 * 1024, keep: true, size: file.length });
  await t.host.settle();
  assert.equal(gates.length, 2, "both large video parts must be in flight concurrently");
  assert.deepEqual(seen.map((s) => s.lane), ["0", "1"], "concurrent large parts must auto-stripe across distinct lanes");
  for (const g of gates) Deferred.doneUnsafe(g, Effect.void);
  await t.host.settle();
  take();
  assert.deepEqual(done.get(201)?.bytes, file.slice(0, 512 * 1024));
  assert.deepEqual(done.get(202)?.bytes, file.slice(512 * 1024, MB));

  // Small (< 256 KiB) or quiet part reads must NOT auto-assign a lane.
  seen.length = 0;
  call(t.core, ui, 203, "station.file.part", { station: ST, key: "k1", name: "video.mp4", offset: MB, length: 64 * 1024, keep: true, size: file.length });
  await t.host.settle();
  await t.core.inner.runner.run(
    handlers.stationFilePart!(
      t.core.inner,
      { kind: "stationFilePart", station: ST, key: "k1", name: "video.mp4", offset: MB + 64 * 1024, length: 512 * 1024, progress: false, stream: false, keep: file.length, quiet: true },
      () => {},
      [ui, 204],
      t.core.inner.tracer.span("test", Kind.Internal).context,
    ),
  );
  assert.deepEqual(seen.map((s) => s.lane), [undefined, undefined], "small and quiet reads must not auto-assign bulk lanes");
  t.core.close();
});
