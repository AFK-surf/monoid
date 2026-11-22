// A person's drafts of 待派发 carried by their devices (src/sessions/board-drafts.ts, src/api/routes/board.ts; the rule
// both sides keep by, client/core-ts/src/board-drafts.ts): stations that never talk to each other, each keeping what
// a device brings it, and a draft's files kept by the station it is to run on until it is started or deleted.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type KeptDraft, DRAFTS_MOST, draftOf, isGoneDraft, mergeDrafts, newerDraft } from "../../client/core-ts/src/board-drafts.ts";
import { BoardDrafts, GONE_FILES_MS } from "../src/sessions/board-drafts.ts";
import { routes } from "../src/api/routes/board.ts";

type Viewer = { sub: string; email: string };
const ME: Viewer = { sub: "u-me", email: "me@x.io" };
const YOU: Viewer = { sub: "u-you", email: "you@x.io" };

/// A station: its data in a directory of its own, its store a map, its routes asked as a device asks.
function station(clock: { now: number }) {
  const data = mkdtempSync(join(tmpdir(), "board-drafts-"));
  const rows = new Map<string, string>();
  const store = { boardDrafts: (ws: string, sub: string) => rows.get(`${ws}/${sub}`) ?? null, putBoardDrafts: (ws: string, sub: string, d: string) => void rows.set(`${ws}/${sub}`, d) };
  const drafts = new BoardDrafts({ store: () => store, dir: () => join(data, "board-files"), uploads: () => join(data, "uploads"), now: () => clock.now });
  const told: string[] = [];
  const list = routes({ drafts, told: (ws, sub) => told.push(`${ws}/${sub}`) });
  const ask = async (method: string, path: string, who: Viewer, body?: unknown, query: [string, string][] = []) => {
    const route = list.find((r) => r.method === method && r.pattern.test(path))!;
    const r = { method, path, query, headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer: { ...who, name: "", role: "member", workspace: "ws", device: "d" } as never, lang: "en" as const };
    const answer = await route.handle(r as never, []);
    const raw = answer.body as Buffer;
    return { status: answer.status, raw, body: answer.headers["content-type"] === "application/json" ? JSON.parse(raw.toString()) : null };
  };
  /// A file put among the uploads, as POST /uploads leaves one.
  const upload = (name: string, bytes: string) => {
    mkdirSync(join(data, "uploads"), { recursive: true });
    const path = join(data, "uploads", `2026-11-18T00-00-00-abcdef-${name}`);
    writeFileSync(path, bytes);
    return path;
  };
  return { data, rows, ask, told, upload };
}

const draft = (n: number, more: Partial<Record<string, unknown>> = {}) => draftOf({ id: `new:board-${n}`, owner: ME.sub, rev: 1, at: n, updatedAt: n, title: `task ${n}`, station: "ws/sa", stationName: "A", files: [], ...more });

/// Every order of `xs`.
function orders<T>(xs: T[]): T[][] {
  if (xs.length <= 1) return [xs];
  return xs.flatMap((x, i) => orders([...xs.slice(0, i), ...xs.slice(i + 1)]).map((rest) => [x, ...rest]));
}

test("of the same drafts the newer is one, whatever order they are folded in; a deletion wins its rev", () => {
  const records: KeptDraft[] = [draft(1, { rev: 2, title: "b" }), draft(1, { rev: 2, title: "a", updatedAt: 9 }), { id: "new:board-1", owner: ME.sub, rev: 2, gone: true, updatedAt: 3 }, draft(1, { rev: 1 })];
  assert.equal(new Set(orders(records).map((o) => JSON.stringify(o.reduce((a, b) => newerDraft(a, b))))).size, 1);
  assert.equal(isGoneDraft(records.reduce((a, b) => newerDraft(a, b))), true);
  const merged = orders(records).map((o) => JSON.stringify(Object.entries(mergeDrafts({}, o)).sort()));
  assert.equal(new Set(merged).size, 1);
});

test("past the most kept, the oldest drafts are deleted, the same on every keeper", () => {
  const many = Array.from({ length: DRAFTS_MOST + 3 }, (_, i) => draft(i + 1));
  const kept = mergeDrafts({}, many);
  const live = Object.values(kept).filter((r) => !isGoneDraft(r));
  assert.equal(live.length, DRAFTS_MOST);
  assert.deepEqual(["new:board-1", "new:board-2", "new:board-3"].map((id) => isGoneDraft(kept[id]!)), [true, true, true]);
  assert.deepEqual(mergeDrafts(kept, many), kept);
});

test("a device's drafts kept and given back to that person alone, told to them as they change; another's refused", async () => {
  const clock = { now: 1_800_000_000_000 };
  const s = station(clock);
  assert.deepEqual((await s.ask("GET", "/board/drafts", ME)).body, { drafts: [], files: [] });
  const put = await s.ask("PUT", "/board/drafts", ME, { drafts: [draft(1), draft(2)] });
  assert.equal(put.status, 200);
  assert.deepEqual(put.body.drafts.map((d: KeptDraft) => d.id), ["new:board-1", "new:board-2"]);
  assert.deepEqual(s.told, ["ws/u-me"]);
  // (the same again tells nothing)
  await s.ask("PUT", "/board/drafts", ME, { drafts: [draft(1)] });
  assert.deepEqual(s.told, ["ws/u-me"]);
  assert.deepEqual((await s.ask("GET", "/board/drafts", YOU)).body, { drafts: [], files: [] });
  assert.equal((await s.ask("PUT", "/board/drafts", YOU, { drafts: [draft(3)] })).status, 400);
  assert.equal((await s.ask("PUT", "/board/drafts", ME, { drafts: [{ id: "x" }] })).status, 400);
  // an older copy brought back changes nothing; a deletion stays
  await s.ask("PUT", "/board/drafts", ME, { drafts: [{ id: "new:board-2", owner: ME.sub, rev: 2, gone: true, updatedAt: 5 }] });
  await s.ask("PUT", "/board/drafts", ME, { drafts: [draft(2)] });
  const now = (await s.ask("GET", "/board/drafts", ME)).body.drafts;
  assert.equal(now.find((d: KeptDraft) => d.id === "new:board-2").gone, true);
});

test("a draft's picture kept by its station: given to the person's other devices, staged for the message that starts it, put aside a day once it goes", async () => {
  const clock = { now: 1_800_000_000_000 };
  const s = station(clock);
  const pictured = draft(1, { files: [{ id: "f1", name: "shot.png", size: 3 }] });
  await s.ask("PUT", "/board/drafts", ME, { drafts: [pictured] });
  // only an upload of the draft's own, of a file it names
  const path = s.upload("shot.png", "png");
  assert.equal((await s.ask("POST", "/board/files", ME, { draft: "new:board-1", file: "f9", path })).status, 400);
  assert.equal((await s.ask("POST", "/board/files", ME, { draft: "new:board-1", file: "f1", path: join(s.data, "stillfail.db") })).status, 400);
  assert.equal((await s.ask("POST", "/board/files", YOU, { draft: "new:board-1", file: "f1", path })).status, 400);
  assert.deepEqual((await s.ask("POST", "/board/files", ME, { draft: "new:board-1", file: "f1", path })).body, { files: ["f1"] });
  assert.deepEqual(readdirSync(join(s.data, "uploads")), []);
  assert.deepEqual((await s.ask("GET", "/board/drafts", ME)).body.files, ["f1"]);
  const got = await s.ask("GET", "/board/files", ME, undefined, [["draft", "new:board-1"], ["file", "f1"]]);
  assert.equal(got.status, 200);
  assert.equal(got.raw.toString(), "png");
  assert.equal((await s.ask("GET", "/board/files", YOU, undefined, [["draft", "new:board-1"], ["file", "f1"]])).status, 404);
  // started on another device: the draft gone, its picture still staged for its message, then dropped after a day
  await s.ask("PUT", "/board/drafts", ME, { drafts: [{ id: "new:board-1", owner: ME.sub, rev: 2, gone: true, updatedAt: clock.now }] });
  assert.deepEqual((await s.ask("GET", "/board/drafts", ME)).body.files, []);
  const staged = await s.ask("POST", "/board/stage", ME, { draft: "new:board-1", file: "f1", name: "shot.png" });
  assert.equal(staged.status, 200);
  assert.equal(staged.body.name, "shot.png");
  assert.equal(staged.body.size, 3);
  assert.equal(readdirSync(join(s.data, "uploads")).length, 1);
  clock.now += GONE_FILES_MS + 60_000;
  await s.ask("PUT", "/board/drafts", ME, { drafts: [] });
  assert.equal((await s.ask("POST", "/board/stage", ME, { draft: "new:board-1", file: "f1", name: "shot.png" })).status, 404);
});

test("a file a draft no longer names is dropped", async () => {
  const clock = { now: 1_800_000_000_000 };
  const s = station(clock);
  await s.ask("PUT", "/board/drafts", ME, { drafts: [draft(1, { files: [{ id: "f1", name: "a.png", size: 1 }, { id: "f2", name: "b.png", size: 1 }] })] });
  await s.ask("POST", "/board/files", ME, { draft: "new:board-1", file: "f1", path: s.upload("a.png", "a") });
  await s.ask("POST", "/board/files", ME, { draft: "new:board-1", file: "f2", path: s.upload("b.png", "b") });
  await s.ask("PUT", "/board/drafts", ME, { drafts: [draft(1, { rev: 2, files: [{ id: "f2", name: "b.png", size: 1 }] })] });
  assert.deepEqual((await s.ask("GET", "/board/drafts", ME)).body.files, ["f2"]);
});
