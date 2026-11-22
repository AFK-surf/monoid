// A person's drafts of 待派发 carried between a workspace's stations by their own devices (src/views/board-drafts.ts,
// src/board-drafts.ts), on the stations' own MoonBit code (station/mb/src/api_routes/board.mbt,
// station/mb/src/session_chats/board_drafts.mbt via `harness-core-routes`):
// what one device writes shows on another; a draft's picture is put up to the station it is to run on, shown on the
// other device and sent by it as an upload; a draft started on one is let go of on the other and not brought back; a
// station away is brought what it missed as its stream comes back; the drafts kept on the device before are taken in.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import { Effect } from "effect";
import type { Inner } from "../src/core.ts";
import { handlers } from "../src/core/execute.ts";
import { CoreError } from "../src/error.ts";
import { isGoneDraft } from "../src/board-drafts.ts";
import { type BoardDraftViews, draftKey, heldOf, install } from "../src/views/board-drafts.ts";
import { startHarness } from "./mb-harness.ts";

const WS = "ws";
const ME = { sub: "s1", email: "a@x.com", name: "阿一" };
const clock = { now: 1_800_000_000_000 };

const harness = startHarness("harness-core-routes");
after(() => harness.close());

type Viewer = { sub: string; email: string; name: string; role: string; workspace: string; device: string };
type Answer = { status: number; headers: Record<string, string>; body: Buffer };
type Rig = { id: string; address: string; data: string; handle: Promise<number>; told: string[] };

function station(id: string): Rig {
  const data = mkdtempSync(join(tmpdir(), "bdc-"));
  const told: string[] = [];
  const handle = harness.call<{ handle: number }>("createBoard", { data, nowMs: clock.now }).then((r) => r.handle);
  return { id, address: `${WS}/${id}`, data, handle, told };
}

async function answer(s: Rig, viewer: Viewer, method: string, path: string, body: Uint8Array | null): Promise<Answer> {
  const handle = await s.handle;
  const res = await harness.call<{ status: number; headers: Record<string, string>; bodyBase64: string; told: string[] }>("request", {
    handle,
    method,
    path,
    bodyBase64: body === null ? "" : Buffer.from(body).toString("base64"),
    viewer,
    nowMs: clock.now,
  });
  for (const t of res.told) s.told.push(t);
  return { status: res.status, headers: res.headers, body: Buffer.from(res.bodyBase64, "base64") };
}

/// One device of the person's, reaching `stations`: its kept records, its composer's files by id, a queue run by
/// `settle`.
function device(stations: Rig[]) {
  const records = new Map<string, unknown>();
  const up = new Set(stations.map((s) => s.address));
  const queue: Effect.Effect<unknown, unknown>[] = [];
  const byAddress = new Map(stations.map((s) => [s.address, s]));
  const viewer = { ...ME, role: "member", workspace: WS, device: "d" } as Viewer;
  const asked: string[] = [];
  const files = new Map<string, Uint8Array>();
  const removed: string[] = [];
  let prefs: Record<string, unknown> = {};
  const json = (a: Answer) => {
    const text = a.body.toString("utf8");
    return a.status >= 400 ? Effect.fail(new CoreError(`http_${a.status}`, (JSON.parse(text) as { error: string }).error, a.status)) : Effect.succeed(JSON.parse(text) as unknown);
  };
  const exchange = (address: string, method: string, path: string, body: Uint8Array | null) => {
    asked.push(`${method} ${address} ${path.split("?")[0]}`);
    if (!up.has(address)) return Effect.fail(new CoreError("offline", "not reached"));
    return Effect.promise(() => answer(byAddress.get(address)!, viewer, method, path, body));
  };
  const inner = {
    provider: { kind: "stillfail" },
    data: {
      record: (table: string, key: string) => records.get(`${table}:${key}`),
      put: (table: string, key: string, value: unknown) => void records.set(`${table}:${key}`, value),
      shared: (topic: { topic: string; workspace?: string }) =>
        topic.topic === "prefs" ? prefs : topic.workspace === WS ? { name: "W", stations: stations.map((s) => ({ id: s.id, name: s.id.toUpperCase() })), members: [ME] } : undefined,
      set: (topic: { topic: string }, value: Record<string, unknown>) => void (topic.topic === "prefs" && (prefs = value)),
    },
    stations: {
      also: [] as { read: (a: string) => Effect.Effect<void, CoreError>; event: (a: string, n: string, d: unknown) => void; resumed?: (a: string) => Effect.Effect<void, CoreError> }[],
      link: (address: string) => (byAddress.has(address) ? { addr: { toString: () => address } } : undefined),
      reachable: (address: string) => up.has(address),
      requests: {
        call: (addr: { toString(): string }, method: string, path: string, body: unknown) => Effect.flatMap(exchange(addr.toString(), method, path, body === null ? null : Buffer.from(JSON.stringify(body))), json),
        // (POST /uploads, as the station's routes/hub.ts keeps one: among its uploads, in no chat)
        upload: (addr: { toString(): string }, name: string, bytes: Uint8Array) => {
          asked.push(`POST ${addr} /uploads`);
          const s = byAddress.get(addr.toString())!;
          mkdirSync(join(s.data, "uploads"), { recursive: true });
          const path = join(s.data, "uploads", `up-${name}`);
          writeFileSync(path, bytes);
          return Effect.succeed({ name, path, size: bytes.length });
        },
        boardFile: (addr: { toString(): string }, draft: string, file: string) =>
          Effect.map(exchange(addr.toString(), "GET", `/board/files?draft=${encodeURIComponent(draft)}&file=${encodeURIComponent(file)}`, null), (a) => (a.status === 200 ? { type: a.headers["content-type"]!, bytes: new Uint8Array(a.body) } : null)),
      },
    },
    composers: {
      bytesOf: async (id: string) => files.get(id) ?? null,
      sizeHeld: (id: string) => files.get(id)?.length ?? 0,
      remove: (key: string, id: string) => void removed.push(`${key} ${id}`),
    },
    scheduler: { enqueue: (_l: string, _k: string, _p: number, e: Effect.Effect<unknown, unknown>) => void queue.push(e) },
    workspaces: { owner: () => ME.sub },
    accounts: { list: () => [ME] },
    host: { nowMs: () => clock.now },
    router: { owners: [] as unknown[] },
  } as unknown as Inner;
  const views: BoardDraftViews = install(inner);
  (inner as { boardDrafts: BoardDraftViews }).boardDrafts = views;
  const settle = async () => {
    while (queue.length > 0) await Effect.runPromise(Effect.ignore(queue.shift()!));
  };
  const also = () => (inner.stations as unknown as { also: { read: (a: string) => Effect.Effect<void, CoreError>; event: (a: string, n: string, d: unknown) => void; resumed?: (a: string) => Effect.Effect<void, CoreError> }[] }).also;
  return {
    inner,
    views,
    asked,
    files,
    removed,
    up,
    setPrefs: (p: Record<string, unknown>) => void (prefs = p),
    prefs: () => prefs,
    settle,
    open: async (s: Rig) => {
      up.add(s.address);
      for (const part of also()) await Effect.runPromise(Effect.ignore(part.read(s.address)));
      await settle();
    },
    away: (s: Rig) => void up.delete(s.address),
    resumed: async (s: Rig) => {
      up.add(s.address);
      for (const part of also()) if (part.resumed) await Effect.runPromise(Effect.ignore(part.resumed(s.address)));
      await settle();
    },
    tell: async (s: Rig) => {
      for (const part of also()) part.event(s.address, "boardDrafts", { workspace: WS });
      await settle();
    },
    put: async (drafts: unknown[]) => {
      const done = await Effect.runPromise(Effect.result(handlers.boardDrafts!(inner, { kind: "boardDrafts", workspace: WS, drafts }, (() => {}) as never, ["c", 1] as never, null as never)));
      await settle();
      return done;
    },
    shown: () => (views.compute({ topic: "boardDrafts", scope: WS }) as { ok: { drafts: { id: string; title: string; files?: { id: string; name: string }[] }[] } }).ok.drafts,
  };
}

const task = (id: string, title: string, more: Record<string, unknown> = {}) => ({ id, title, station: `${WS}/sa`, stationName: "SA", ...more });

test("what one device writes in 待派发 shows on another, its picture put up to the station it runs on, shown and sent there", async () => {
  const sa = station("sa");
  const sb = station("sb");
  const a = device([sa, sb]);
  const b = device([sa, sb]);
  a.files.set("f1", new TextEncoder().encode("png!"));
  assert.equal((await a.put([task("new:board-1", "整理发布清单", { files: [{ id: "f1", name: "shot.png" }] }), task("new:board-2", "看 CI")]))._tag, "Success");
  assert.deepEqual(a.shown().map((d) => d.id), ["new:board-1", "new:board-2"]);
  // (the picture only to the station the draft runs on)
  assert.equal(a.asked.filter((x) => x.endsWith("/uploads")).join(), "POST ws/sa /uploads");
  assert.ok(a.asked.includes("POST ws/sa /board/files"));
  assert.deepEqual(heldOf(a.inner.data, WS).files, { sa: ["f1"] });
  await b.open(sa);
  await b.open(sb);
  assert.deepEqual(b.shown(), a.shown());
  const picture = await Effect.runPromise(b.views.picture(draftKey(WS, "new:board-1"), "f1"));
  assert.equal(new TextDecoder().decode(picture!.bytes), "png!");
  assert.equal(picture!.type, "image/png");
  assert.deepEqual(b.views.held(draftKey(WS, "new:board-1")), { station: `${WS}/sa`, files: [{ id: "f1", name: "shot.png", size: 4 }] });
  const staged = await Effect.runPromise(b.views.stage(draftKey(WS, "new:board-1"), `${WS}/sa`, { id: "f1", name: "shot.png" }));
  assert.equal(readFileSync(staged.path, "utf8"), "png!");
  // started on b: gone everywhere, let go of on a, and an older copy brings it back nowhere
  await b.put([task("new:board-2", "看 CI")]);
  await a.tell(sa);
  assert.deepEqual(a.shown().map((d) => d.id), ["new:board-2"]);
  assert.deepEqual(a.removed, [`${draftKey(WS, "new:board-1")} f1`]);
  const c = device([sa, sb]);
  await c.put([task("new:board-1", "整理发布清单")]);
  // (a new record of that id, its first change, loses to the deletion the stations keep)
  assert.equal(isGoneDraft(heldOf(c.inner.data, WS).drafts["new:board-1"]!), true);
  await a.open(sa);
  assert.deepEqual(a.shown().map((d) => d.id), ["new:board-2"]);
});

test("a change made with a station away reaches it as its stream comes back; words edited count a change", async () => {
  const sa = station("sa");
  const sb = station("sb");
  const a = device([sa, sb]);
  await a.put([task("new:board-1", "一")]);
  a.away(sb);
  await a.put([task("new:board-1", "一（改）")]);
  assert.deepEqual(heldOf(a.inner.data, WS).owed, ["sb"]);
  const rev = (heldOf(a.inner.data, WS).drafts["new:board-1"] as { rev: number }).rev;
  assert.equal(rev, 2);
  await a.resumed(sb);
  assert.deepEqual(heldOf(a.inner.data, WS).owed, []);
  const b = device([sb]);
  await b.open(sb);
  assert.deepEqual(b.shown().map((d) => d.title), ["一（改）"]);
  // (the same list again changes nothing)
  const before = a.asked.length;
  await a.put([task("new:board-1", "一（改）")]);
  assert.equal(a.asked.length, before);
});

test("the drafts this device kept before are taken in as the person's once, and left out of its prefs", async () => {
  const sa = station("sa");
  const a = device([sa]);
  a.setPrefs({ boardDrafts: { [WS]: [task("new:board-7", "旧的一条"), task("new:board-6", "更旧")], other: [task("new:board-9", "别的")] } });
  a.views.start({ topic: "boardDrafts", scope: WS });
  await a.settle();
  assert.deepEqual(a.shown().map((d) => d.title), ["旧的一条", "更旧"]);
  assert.deepEqual(Object.keys((a.prefs().boardDrafts as object) ?? {}), ["other"]);
  const b = device([sa]);
  await b.open(sa);
  assert.deepEqual(b.shown().map((d) => d.title), ["旧的一条", "更旧"]);
  // (taken in once: what is in the prefs later stays there)
  a.setPrefs({ boardDrafts: { [WS]: [task("new:board-8", "又一条")] } });
  a.views.start({ topic: "boardDrafts", scope: WS });
  assert.equal(a.shown().length, 2);
});
