// A station's drive's files kept on the device once read (drive-kept.ts, `drive.read`'s `keep`), as Android's
// DriveCache.kt keeps them: read again, answered from what is kept without asking the station; read anew once it
// changed there; the least lately read let go past their bound; counted with what else the device keeps, and let go.
import assert from "node:assert/strict";
import { test } from "node:test";
import { Effect, Fiber } from "effect";
import type { Inner } from "../src/core.ts";
import { Core } from "../src/core.ts";
import { DriveKept, chatKeptId, keptId, outboxKeptId, sentKeptId } from "../src/drive-kept.ts";
import { keptFirst } from "../src/station/calls.ts";
import { HostWire } from "../src/station/wire.ts";
import { SqlError, type Sql, type SqlValue } from "../src/host.ts";
import { FakeHost } from "../src/testing.ts";
import { answers, call } from "./helpers.ts";
import { Raw, started, stationReplies, status } from "./station-fixture.ts";

const ST = "ws/st";
const ROOT = "/Users/a/Books";

type File = { bytes: Uint8Array; mtime: number };

/// The station's drive as `files` (by path): `/drive/read` answers a part of one with its whole size and time.
function drive(host: FakeHost, files: Map<string, File>): void {
  stationReplies(host, (req) => {
    if (!req.url.includes("/drive/read?")) return undefined;
    const q = new URL(req.url).searchParams;
    const f = files.get(q.get("path") ?? "");
    if (f === undefined) return status(404, { error: "文件或文件夹不存在", code: "not_found" });
    const offset = Number(q.get("offset"));
    const body = f.bytes.slice(offset, offset + Number(q.get("length")));
    return new Raw({ status: 200, headers: [["content-type", "text/plain"], ["stillfail-total", String(f.bytes.length)], ["stillfail-mtime", String(f.mtime)]], body });
  });
}

const reads = (host: FakeHost) => host.requests.filter((r) => r.url.includes("/drive/read?")).length;
const bytesOf = (n: number, from = 0) => Uint8Array.from({ length: n }, (_, i) => (from + i) % 251);

/// `drive.read` of `path` from `offset`, kept as `keep` with the file as its folder says it is; its answer, bytes and all.
async function read(t: Awaited<ReturnType<typeof started>>, ui: number, id: number, path: string, offset: number, length: number, file: { mtime: number; size: number } | null, keep = "file") {
  call(t.core, ui, id, "drive.read", { station: ST, root: ROOT, path, offset, length, ...(file ? { keep, mtime: file.mtime, size: file.size } : {}) });
  await t.host.settle();
  const a = answers(t.host.takeEmitted(), id) as { ok: { type: string; total: number; mtime: number }; bytes: Uint8Array } | undefined;
  assert.ok(a?.ok, `drive.read ${id} answered`);
  return a;
}

test("a file read whole is kept: read again, it is answered from the device; changed on the station, read anew", async () => {
  const t = await started();
  const files = new Map<string, File>([["notes.txt", { bytes: bytesOf(10), mtime: 1000 }]]);
  drive(t.host, files);
  const ui = t.core.connect();
  const said = { mtime: 1000, size: 10 };
  const first = await read(t, ui, 1, "notes.txt", 0, 6, said);
  const second = await read(t, ui, 2, "notes.txt", 6, 6, said);
  assert.equal(reads(t.host), 2);
  assert.deepEqual([...first.bytes, ...second.bytes], [...bytesOf(10)]);
  // Read again, from its start and from inside it: the station not asked
  const again = await read(t, ui, 3, "notes.txt", 0, 6, said);
  const inside = await read(t, ui, 4, "notes.txt", 4, 4, said);
  assert.equal(reads(t.host), 2);
  assert.deepEqual([...again.bytes], [...bytesOf(6)]);
  assert.deepEqual([...inside.bytes], [...bytesOf(4, 4)]);
  assert.deepEqual(again.ok, { type: "text/plain", total: 10, mtime: 1000 });
  // Not asked to keep it: the station asked, as before
  await read(t, ui, 5, "notes.txt", 0, 6, null);
  assert.equal(reads(t.host), 3);
  // Changed on the station: its folder says so, and it is read anew, as it is now
  files.set("notes.txt", { bytes: bytesOf(8, 100), mtime: 2000 });
  const now = await read(t, ui, 6, "notes.txt", 0, 6, { mtime: 2000, size: 8 });
  assert.equal(reads(t.host), 4);
  assert.deepEqual([...now.bytes], [...bytesOf(6, 100)]);
  await read(t, ui, 7, "notes.txt", 0, 6, { mtime: 2000, size: 8 });
  assert.equal(reads(t.host), 4, "as it is now, kept");
  t.core.close();
});

test("a file changed since its folder was read: what was kept goes, what is read is not kept", async () => {
  const t = await started();
  const files = new Map<string, File>([["a.txt", { bytes: bytesOf(10), mtime: 1000 }]]);
  drive(t.host, files);
  const ui = t.core.connect();
  const was = { mtime: 1000, size: 10 };
  await read(t, ui, 1, "a.txt", 0, 6, was);
  // Changed on the station, its folder not read again: what is kept of it as it was is what it is here (as Android's)
  files.set("a.txt", { bytes: bytesOf(12, 50), mtime: 3000 });
  await read(t, ui, 2, "a.txt", 0, 6, was);
  assert.equal(reads(t.host), 1);
  // until a part not kept is read, and the station says it is another now
  const changed = await read(t, ui, 3, "a.txt", 6, 4, was);
  assert.equal(reads(t.host), 2);
  assert.deepEqual(changed.ok, { type: "text/plain", total: 12, mtime: 3000 });
  assert.deepEqual([...changed.bytes], [...bytesOf(4, 56)]);
  await read(t, ui, 4, "a.txt", 0, 6, was);
  assert.equal(reads(t.host), 3, "what was kept of it gone");
  t.core.close();
});

test("a video's parts are kept as played, a stream's too; the page of what the device keeps counts them and lets them go", async () => {
  const t = await started();
  const files = new Map<string, File>([["film.mp4", { bytes: bytesOf(64), mtime: 7 }]]);
  drive(t.host, files);
  const ui = t.core.connect();
  const said = { mtime: 7, size: 64 };
  await read(t, ui, 1, "film.mp4", 16, 16, said, "played");
  call(t.core, ui, 2, "drive.read", { station: ST, root: ROOT, path: "film.mp4", offset: 40, length: 8, stream: true, keep: "played", ...said });
  await t.host.settle();
  const streamed = t.host.takeEmitted().map(([, m]) => m as { id?: number; bytes?: Uint8Array }).filter((m) => m.id === 2 && m.bytes !== undefined);
  assert.deepEqual(streamed.flatMap((m) => [...m.bytes!]), [...bytesOf(8, 40)]);
  assert.equal(reads(t.host), 2);
  // what was played, again (a stream's in one piece): from the device
  await read(t, ui, 3, "film.mp4", 20, 8, said, "played");
  call(t.core, ui, 4, "drive.read", { station: ST, root: ROOT, path: "film.mp4", offset: 40, length: 8, stream: true, keep: "played", ...said });
  await t.host.settle();
  const again = t.host.takeEmitted().map(([, m]) => m as { id?: number; bytes?: Uint8Array }).filter((m) => m.id === 4 && m.bytes !== undefined);
  assert.deepEqual(again.flatMap((m) => [...m.bytes!]), [...bytesOf(8, 40)]);
  assert.equal(reads(t.host), 2);
  // what was not played: from the station, only the stretch between what was played (32 to 40: 30 and 31 kept
  // before it, 40 and 41 after)
  const got = await read(t, ui, 5, "film.mp4", 30, 12, said, "played");
  assert.deepEqual([...got.bytes], [...bytesOf(12, 30)]);
  assert.equal(reads(t.host), 3);
  const asked = new URL(t.host.requests.filter((r) => r.url.includes("/drive/read")).at(-1)!.url).searchParams;
  assert.deepEqual([asked.get("offset"), asked.get("length")], ["32", "8"]);
  call(t.core, ui, 6, "cache.usage", {});
  await t.host.settle();
  assert.equal((answers(t.host.takeEmitted(), 6)?.ok as { drive: number }).drive, 16 + 8 + 8);
  call(t.core, ui, 7, "drive.kept.clear", {});
  await t.host.settle();
  assert.ok(answers(t.host.takeEmitted(), 7)?.ok === null);
  call(t.core, ui, 8, "cache.usage", {});
  await t.host.settle();
  assert.equal((answers(t.host.takeEmitted(), 8)?.ok as { drive: number }).drive, 0);
  assert.equal([...t.host.storage.keys()].filter((k) => k.startsWith("drive-kept-")).length, 0, "their bytes let go");
  await read(t, ui, 9, "film.mp4", 16, 16, said, "played");
  assert.equal(reads(t.host), 4);
  t.core.close();
});

test("a part partly kept: what is kept goes first, only the rest of it is asked of the station", async () => {
  const t = await started();
  drive(t.host, new Map<string, File>([["film.mp4", { bytes: bytesOf(64), mtime: 7 }]]));
  const ui = t.core.connect();
  const said = { mtime: 7, size: 64 };
  const asked = () =>
    t.host.requests.filter((r) => r.url.includes("/drive/read?")).map((r) => {
      const q = new URL(r.url).searchParams;
      return [Number(q.get("offset")), Number(q.get("length"))];
    });
  await read(t, ui, 1, "film.mp4", 16, 16, said, "played");
  // on from what was played: the station asked from where what is kept stops
  const on = await read(t, ui, 2, "film.mp4", 16, 32, said, "played");
  assert.deepEqual(asked(), [[16, 16], [32, 16]]);
  assert.deepEqual([...on.bytes], [...bytesOf(32, 16)]);
  assert.deepEqual(on.ok, { type: "text/plain", total: 64, mtime: 7 });
  // as it streams: what is kept handed on first, then what the station brings
  call(t.core, ui, 3, "drive.read", { station: ST, root: ROOT, path: "film.mp4", offset: 40, length: 16, stream: true, keep: "played", ...said });
  await t.host.settle();
  const streamed = t.host.takeEmitted().map(([, m]) => m as { id?: number; bytes?: Uint8Array }).filter((m) => m.id === 3 && m.bytes !== undefined);
  assert.deepEqual(streamed.flatMap((m) => [...m.bytes!]), [...bytesOf(16, 40)]);
  assert.deepEqual(asked().at(-1), [48, 8]);
  // all of it kept now: the station not asked again
  await read(t, ui, 4, "film.mp4", 16, 40, said, "played");
  assert.equal(asked().length, 3);
  t.core.close();
});

test("a part partly kept of a file changed on the station: read whole again from it, not put after what was kept", async () => {
  const t = await started();
  const files = new Map<string, File>([["a.txt", { bytes: bytesOf(10), mtime: 1000 }]]);
  drive(t.host, files);
  const ui = t.core.connect();
  const was = { mtime: 1000, size: 10 };
  await read(t, ui, 1, "a.txt", 0, 6, was);
  files.set("a.txt", { bytes: bytesOf(12, 50), mtime: 3000 });
  const got = await read(t, ui, 2, "a.txt", 0, 10, was);
  assert.deepEqual([...got.bytes], [...bytesOf(10, 50)]);
  assert.deepEqual(got.ok, { type: "text/plain", total: 12, mtime: 3000 });
  assert.equal(reads(t.host), 3, "the rest, then the part whole again");
  await read(t, ui, 3, "a.txt", 0, 6, was);
  assert.equal(reads(t.host), 4, "what was kept of it gone");
  t.core.close();
});

test("cached parts transferred to a web player advance once and finish, including a gap fetched from the station", async () => {
  for (const gap of [false, true]) {
    const offsets: number[] = [];
    const taken: number[] = [];
    const fetched: number[] = [];
    const kept: number[] = [];
    const progress: number[] = [];
    const inner = { runner: { fork: (e: Effect.Effect<void>) => Effect.runFork(e) } } as unknown as Inner;
    const result = await Effect.runPromise(keptFirst(
      inner,
      { offset: 10, length: 12, quiet: true },
      22,
      (at) => Effect.sync(() => {
        assert.ok(offsets.length === 0 || at > offsets.at(-1)!, "a transferred cached part must not be read again");
        offsets.push(at);
        return gap && at === 14 ? null : { type: "video/mp4", bytes: bytesOf(4, at) };
      }),
      () => Effect.succeed(18),
      (loaded) => progress.push(loaded),
      (piece) => {
        const received = structuredClone(piece, { transfer: [piece.buffer as ArrayBuffer] });
        taken.push(...received);
      },
      (at, length, _before, take, said) => Effect.sync(() => {
        fetched.push(at);
        const head = { type: "video/mp4", total: 22 };
        said(head);
        take(bytesOf(length, at));
        return head;
      }),
      (_head, _at, bytes) => Effect.sync(() => { kept.push(...bytes); }),
      (head) => head.total === 22,
    ));
    assert.deepEqual(offsets, [10, 14, 18]);
    assert.deepEqual(taken, [...bytesOf(12, 10)]);
    assert.deepEqual(fetched, gap ? [14] : []);
    assert.deepEqual(kept, gap ? [...bytesOf(4, 14)] : []);
    assert.deepEqual(progress, gap ? [4, 12] : [4, 8, 12]);
    assert.equal(result.type, "video/mp4");
    assert.equal(result.bytes.length, 0, "streamed bytes are not sent again in the final answer");
  }
});

test("a part read stopped short (let go of, or broken off) keeps what came of it", async () => {
  const kept: [number, number[]][] = [];
  const taken: number[][] = [];
  const inner = { runner: { fork: (e: Effect.Effect<void>) => Effect.runFork(e) } } as unknown as Inner;
  const reading = keptFirst<{ type: string; total: number }, { type: string; total: number; bytes: Uint8Array }>(
    inner,
    { offset: 10, length: 20 },
    100,
    (at) => Effect.succeed(at === 10 ? { type: "video/mp4", bytes: bytesOf(4, 10) } : null),
    (_at, end) => Effect.succeed(end),
    undefined,
    (piece) => taken.push([...piece]),
    (at, _length, _before, take, said) =>
      Effect.gen(function* () {
        said({ type: "video/mp4", total: 100 });
        take(bytesOf(5, at));
        return yield* Effect.never;
      }),
    (_head, at, bytes) => Effect.sync(() => void kept.push([at, [...bytes]])),
    (head) => head.total === 100,
  );
  await Effect.runPromise(
    Effect.gen(function* () {
      const fiber = yield* Effect.forkChild(reading);
      yield* Effect.yieldNow;
      yield* Fiber.interrupt(fiber);
    }),
  );
  // what was kept went first, then the station's first piece; that piece kept where it is in the file
  assert.deepEqual(taken, [[...bytesOf(4, 10)], [...bytesOf(5, 14)]]);
  assert.deepEqual(kept, [[14, [...bytesOf(5, 14)]]]);
});

test("a part streamed to a player stops as the player lets go of it, or its page goes: nothing more of it comes", async () => {
  const t = await started();
  drive(t.host, new Map<string, File>([["film.mp4", { bytes: bytesOf(64), mtime: 7 }]]));
  const said = { mtime: 7, size: 64 };
  const part = (ui: number, id: number) => call(t.core, ui, id, "drive.read", { station: ST, root: ROOT, path: "film.mp4", offset: 0, length: 64, stream: true, keep: "played", ...said });
  const of = (id: number) => t.host.takeEmitted().map(([, m]) => m as { id: number; error?: { code: string }; bytes?: Uint8Array }).filter((m) => m.id === id);
  // The station slow to answer it, the player gone elsewhere meanwhile: it says so, and nothing of it comes after.
  const ui = t.core.connect();
  const release = t.host.hold("&length=64");
  part(ui, 1);
  await t.host.settle();
  t.core.receive(ui, { kind: "cancel", id: 1, cancel: true });
  await t.host.settle();
  release();
  await t.host.settle();
  assert.deepEqual(of(1).map((m) => m.error?.code ?? (m.bytes ? "bytes" : "answer")), ["cancelled"]);
  assert.equal(t.core.inner.calls.size, 0);
  // Its page gone: the same.
  const other = t.core.connect();
  const again = t.host.hold("&length=64");
  part(other, 2);
  await t.host.settle();
  t.core.disconnect(other);
  await t.host.settle();
  again();
  await t.host.settle();
  assert.deepEqual(of(2).map((m) => m.error?.code ?? (m.bytes ? "bytes" : "answer")), ["cancelled"]);
  assert.equal(t.core.inner.calls.size, 0);
  // One not let go of brings all of it.
  part(ui, 3);
  await t.host.settle();
  assert.deepEqual(of(3).flatMap((m) => [...(m.bytes ?? [])]), [...bytesOf(64)]);
  t.core.close();
});

test("past their bound the least lately read go, never the one just read nor one being written", async () => {
  const host = new FakeHost();
  const kept = new DriveKept(host, { file: 10, played: 100, chat: Number.POSITIVE_INFINITY, sent: 100, outbox: Number.POSITIVE_INFINITY });
  const run = <A>(e: Effect.Effect<A>) => Effect.runPromise(e);
  const ids = ["one", "two", "three"].map((n) => keptId(ST, ROOT, n));
  for (const id of ids) {
    await run(kept.keep(id, "file", 1, 4, "application/pdf", 0, bytesOf(4)));
    host.advance(61_000);
  }
  // 12 bytes of files past 10: the least lately read, the first, gone
  assert.equal(await run(kept.read(ids[0], 1, 4, 0, 4)), null);
  assert.deepEqual([...(await run(kept.read(ids[1], 1, 4, 0, 4)))!.bytes], [...bytesOf(4)]);
  assert.equal(await run(kept.usage()), 8);
  // the second read just now: a fourth lets the third go
  host.advance(61_000);
  await run(kept.keep(keptId(ST, ROOT, "four"), "file", 1, 4, "application/pdf", 0, bytesOf(4)));
  assert.equal(await run(kept.read(ids[2], 1, 4, 0, 4)), null);
  assert.notEqual(await run(kept.read(ids[1], 1, 4, 0, 4)), null);
  // one read past the bound alone is kept (never the one just read); what was played is counted apart
  await run(kept.keep(keptId(ST, ROOT, "five"), "file", 1, 12, "application/pdf", 0, bytesOf(12)));
  assert.notEqual(await run(kept.read(keptId(ST, ROOT, "five"), 1, 12, 0, 12)), null);
  await run(kept.keep(keptId(ST, ROOT, "film"), "played", 1, 400, "video/mp4", 0, bytesOf(50)));
  assert.notEqual(await run(kept.read(keptId(ST, ROOT, "film"), 1, 400, 0, 50)), null);
  assert.equal([...host.storage.keys()].filter((k) => k.startsWith("drive-kept-")).length, 2, "the bytes of those let go, gone");
});

test("a file kept whole is kept on under another name, its bytes where they are; one kept in part is not", async () => {
  const host = new FakeHost();
  const kept = new DriveKept(host, { file: 10, played: 100, chat: Number.POSITIVE_INFINITY, sent: 100, outbox: Number.POSITIVE_INFINITY });
  const run = <A>(e: Effect.Effect<A>) => Effect.runPromise(e);
  const [going, sent] = [outboxKeptId("clip"), sentKeptId(ST, "clip.mp4")];
  await run(kept.keep(going, "outbox", 0, 8, "video/mp4", 0, bytesOf(4)));
  assert.equal(await run(kept.rename(going, sent, "sent", 8)), false, "half of it kept");
  await run(kept.keep(going, "outbox", 0, 8, "video/mp4", 4, bytesOf(4, 4)));
  const before = [...host.storage.keys()].filter((k) => k.startsWith("drive-kept-")).sort();
  assert.equal(await run(kept.rename(going, sent, "sent", 8)), true);
  assert.equal(await run(kept.has(going)), false);
  assert.deepEqual(await run(kept.held(sent)), { type: "video/mp4", size: 8, bytes: bytesOf(8) });
  assert.deepEqual([...host.storage.keys()].filter((k) => k.startsWith("drive-kept-")).sort(), before, "nothing written again");
});

test("what is left of those kept in part: the first of each not kept, the most lately read first, but one whose rest its kind has no room for", async () => {
  const host = new FakeHost();
  const kept = new DriveKept(host, { file: 10, played: 100, chat: Number.POSITIVE_INFINITY, sent: 100, outbox: Number.POSITIVE_INFINITY });
  const run = <A>(e: Effect.Effect<A>) => Effect.runPromise(e);
  const [film, song, big, whole] = ["film", "song", "big", "whole"].map((n) => keptId(ST, ROOT, n));
  // its start and a part further on: what is between first
  await run(kept.keep(film, "played", 1, 40, "video/mp4", 0, bytesOf(10)));
  await run(kept.keep(film, "played", 1, 40, "video/mp4", 20, bytesOf(5)));
  host.advance(61_000);
  await run(kept.keep(song, "played", 1, 30, "audio/mp4", 0, bytesOf(10)));
  // all of it kept: nothing left of it
  await run(kept.keep(whole, "played", 1, 5, "audio/mp4", 0, bytesOf(5)));
  host.advance(61_000);
  // its rest past what videos keep beside the others
  await run(kept.keep(big, "played", 1, 90, "video/mp4", 0, bytesOf(10)));
  const left = await run(kept.unfinished(["played"]));
  assert.deepEqual(left.map((f) => [f.id, f.at, f.length]), [[song, 10, 20], [film, 10, 10]]);
  // a chat's not asked for: none of it
  await run(kept.keep(chatKeptId(ST, "k1", "a.mp4"), "chat", 0, 50, "video/mp4", 0, bytesOf(10)));
  assert.equal((await run(kept.unfinished(["played"]))).length, 2);
  assert.deepEqual((await run(kept.unfinished(["chat"]))).map((f) => [f.at, f.length]), [[10, 40]]);
  // only those read since a time: the song and the big one read after the film was
  assert.deepEqual((await run(kept.unfinished(["played"], host.nowMs() - 61_000))).map((f) => f.id), [song]);
});

test("what is left of those read since a time is found without reading every file ever kept, nor its parts", async () => {
  const host = new FakeHost();
  // (the rows each statement gives back, counted: what the core's thread is held for, each of them decoded there)
  const read = { rows: 0 };
  const open = host.openDb.bind(host);
  host.openDb = (name) =>
    Effect.map(open(name), (sql) => ({
      exec: (q) => sql.exec(q),
      run: (q, p) => sql.run(q, p),
      all: (q, p) => {
        const rows = sql.all(q, p);
        read.rows += rows.length;
        return rows;
      },
      close: () => sql.close(),
    }));
  const kept = new DriveKept(host);
  const run = <A>(e: Effect.Effect<A>) => Effect.runPromise(e);
  // a chat's files opened long ago, never let go by themselves: each whole, in two parts; one of them in part
  const old = Array.from({ length: 40 }, (_, i) => chatKeptId(ST, "k1", `old-${i}.png`));
  for (const id of old) {
    await run(kept.keep(id, "chat", 0, 20, "image/png", 0, bytesOf(10)));
    if (id !== old[7]) await run(kept.keep(id, "chat", 0, 20, "image/png", 10, bytesOf(10)));
  }
  host.advance(4 * 24 * 3600_000);
  // a film opened now, its start kept; and one of the old ones asked to be loaded
  const film = chatKeptId(ST, "k1", "film.mp4");
  await run(kept.keep(film, "chat", 0, 50, "video/mp4", 0, bytesOf(10)));
  const since = host.nowMs() - 3 * 24 * 3600_000;
  read.rows = 0;
  assert.deepEqual((await run(kept.unfinished(["chat", "played"], since))).map((f) => [f.id, f.at, f.length]), [[film, 10, 40]]);
  assert.ok(read.rows <= 4, `${read.rows} rows read for one file in part`);
  await run(kept.want(old[7]!, "chat", 20));
  read.rows = 0;
  assert.deepEqual((await run(kept.unfinished(["chat", "played"], since))).map((f) => [f.id, f.at, f.length, f.wanted]), [[old[7], 10, 10, true], [film, 10, 40, false]]);
  assert.ok(read.rows <= 8, `${read.rows} rows read for two files in part`);
  // (with no time said: every one in part, as before)
  await run(kept.unwant(old[7]!));
  assert.deepEqual((await run(kept.unfinished(["chat"]))).map((f) => f.id), [film, old[7]]);
});

test("a chat's file opened is kept with its chat: read again from the device, listed with it, let go one at a time or with it", async () => {
  const t = await started();
  const pdf = bytesOf(40, 7);
  const film = bytesOf(64, 30);
  stationReplies(t.host, (req) => {
    const u = new URL(req.url);
    const name = u.searchParams.get("name");
    // (one read whole is read a part at a time as any other, kept as each comes)
    const f = name === "plan.pdf" ? { bytes: pdf, type: "application/pdf" } : name === "film.mp4" ? { bytes: film, type: "video/mp4" } : null;
    if (u.pathname.endsWith("/sessions/k1/parts") && f !== null) {
      const offset = Number(u.searchParams.get("offset"));
      const body = f.bytes.slice(offset, offset + Number(u.searchParams.get("length")));
      return new Raw({ status: 200, headers: [["content-type", f.type], ["stillfail-total", String(f.bytes.length)]], body });
    }
    return undefined;
  });
  const asked = () => t.host.requests.filter((r) => r.url.includes("/sessions/k1/")).length;
  // the chat its session is in, with what is kept of its messages
  t.core.inner.data.putThread(ST, { id: 7, title: "季度计划", sessions: [{ session: "k1" }] });
  t.core.inner.data.putItems("entry", ST, "7", [[1, { text: "看一下附件" }]]);
  const ui = t.core.connect();
  const whole = async (id: number) => {
    call(t.core, ui, id, "station.file", { station: ST, key: "k1", name: "plan.pdf", keep: true, size: 40 });
    await t.host.settle();
    return answers(t.host.takeEmitted(), id) as { ok: { type: string }; bytes: Uint8Array };
  };
  assert.deepEqual([...(await whole(1)).bytes], [...pdf]);
  const again = await whole(2);
  assert.equal(asked(), 1, "read again from the device");
  assert.deepEqual([again.ok, [...again.bytes]], [{ type: "application/pdf" }, [...pdf]]);
  // a video's parts, as played
  const part = async (id: number, offset: number, length: number) => {
    call(t.core, ui, id, "station.file.part", { station: ST, key: "k1", name: "film.mp4", offset, length, keep: true, size: 64 });
    await t.host.settle();
    return answers(t.host.takeEmitted(), id) as { ok: { type: string; total: number }; bytes: Uint8Array };
  };
  await part(3, 0, 32);
  const played = await part(4, 8, 16);
  assert.equal(asked(), 2);
  assert.deepEqual([played.ok, [...played.bytes]], [{ type: "video/mp4", total: 64 }, [...bytesOf(16, 38)]]);
  // listed with its chat (the film a part of it), not counted with the drives'
  call(t.core, ui, 5, "cache.usage", {});
  await t.host.settle();
  const usage = answers(t.host.takeEmitted(), 5)?.ok as { chats: { thread: number; files: { name: string; size: number; bytes: number }[] }[]; drive: number; loose: unknown[] };
  const chat = usage.chats.find((c) => c.thread === 7)!;
  assert.deepEqual(chat.files.map((f) => [f.name, f.size, f.bytes]).sort(), [["film.mp4", 64, 32], ["plan.pdf", 40, 40]]);
  assert.deepEqual([usage.drive, usage.loose], [0, []]);
  // one let go: read from the station again
  call(t.core, ui, 6, "cache.file.clear", { station: ST, key: "k1", name: "plan.pdf" });
  await t.host.settle();
  await whole(7);
  assert.equal(asked(), 3);
  // the chat's let go: its files with it
  call(t.core, ui, 8, "cache.clear", { station: ST, thread: 7 });
  await t.host.settle();
  await part(9, 0, 32);
  await whole(10);
  assert.equal(asked(), 5);
  t.core.close();
});

test("a chat picture opened again after the core restarts is read from the device", async () => {
  const t = await started();
  const picture = bytesOf(40, 7);
  const params = { station: ST, key: "k1", name: "picture.png", keep: true, size: picture.length };
  stationReplies(t.host, (req) => {
    if (!new URL(req.url).pathname.endsWith("/sessions/k1/parts")) return undefined;
    return new Raw({ status: 200, headers: [["content-type", "image/png"], ["stillfail-total", String(picture.length)]], body: picture });
  });
  const asked = () => t.host.requests.filter((r) => r.url.includes("/sessions/k1/parts")).length;
  const ui = t.core.connect();
  call(t.core, ui, 1, "station.file", params);
  await t.host.settle();
  const first = answers(t.host.takeEmitted(), 1) as { bytes: Uint8Array };
  assert.deepEqual(first.bytes, picture);
  assert.equal(asked(), 1);
  t.core.close();
  // The station has gone away; the copy remains in the host's storage across a new core.
  stationReplies(t.host, (req) => new URL(req.url).pathname.endsWith("/sessions/k1/parts") ? status(503, { error: "offline" }) : undefined);
  const again = await Core.create(t.host, { clock: t.host.time.clock, sample: 0, wire: () => new HostWire(t.host) });
  try {
    call(again, again.connect(), 2, "station.file", params);
    await t.host.settle();
    const reopened = answers(t.host.takeEmitted(), 2) as { bytes: Uint8Array };
    assert.deepEqual(reopened.bytes, picture);
    assert.equal(asked(), 1, "the reopened picture did not ask the station again");
  } finally {
    again.close();
  }
});

test("a chat's video streamed to a page that takes its bytes away (the web's worker moves them to the page): played, and kept all the same", async () => {
  const t = await started();
  const film = bytesOf(64, 30);
  stationReplies(t.host, (req) => {
    const u = new URL(req.url);
    if (!u.pathname.endsWith("/sessions/k1/parts")) return undefined;
    const offset = Number(u.searchParams.get("offset"));
    return new Raw({ status: 200, headers: [["content-type", "video/mp4"], ["stillfail-total", "64"]], body: film.slice(offset, offset + Number(u.searchParams.get("length"))) });
  });
  const asked = () => t.host.requests.filter((r) => r.url.includes("/sessions/k1/")).length;
  // (what the page is given is the page's: its buffer moved there, nothing of it left here)
  const emit = t.host.emit.bind(t.host);
  t.host.emit = (client, message) => {
    emit(client, message);
    if ("bytes" in message && message.bytes !== undefined) structuredClone(message.bytes.buffer, { transfer: [message.bytes.buffer as ArrayBuffer] });
  };
  const ui = t.core.connect();
  call(t.core, ui, 1, "station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 0, length: 32, stream: true, keep: true, size: 64 });
  await t.host.settle();
  const said = t.host.takeEmitted().map(([, m]) => m as { id?: number; bytes?: Uint8Array; ok?: unknown; error?: unknown }).filter((m) => m.id === 1);
  assert.deepEqual(said.flatMap((m) => (m.bytes ? [...m.bytes] : [])), [...film.subarray(0, 32)], "played");
  assert.equal(said.find((m) => m.error !== undefined)?.error, undefined, "no error");
  assert.ok(said.some((m) => m.ok !== undefined), "answered");
  // read again: from the device
  call(t.core, ui, 2, "station.file.part", { station: ST, key: "k1", name: "film.mp4", offset: 8, length: 16, stream: true, keep: true, size: 64 });
  await t.host.settle();
  const replayed = t.host.takeEmitted().map(([, m]) => m as { id?: number; bytes?: Uint8Array; ok?: unknown; error?: unknown }).filter((m) => m.id === 2);
  assert.deepEqual(replayed.flatMap((m) => (m.bytes ? [...m.bytes] : [])), [...film.subarray(8, 24)], "played from cache once");
  assert.ok(replayed.some((m) => m.ok !== undefined), "cached stream answered");
  assert.ok(replayed.every((m) => m.error === undefined), "cached stream has no error");
  assert.equal(asked(), 1, "kept as it was played");
  t.core.close();
});

test("the page of what the device keeps calls each chat as the chats' list does, the one keeping most first", async () => {
  const t = await started();
  const data = t.core.inner.data;
  // named by its agent; of still.fail's own, never named; a Slack thread, by its first line
  data.putThread(ST, { id: 1, surface: "ember", title: null, autoTitle: "处理构建问题", sessions: [{ session: "k1" }] });
  data.putThread(ST, { id: 2, surface: "ember", title: null, sessions: [{ session: "k2" }] });
  data.putThread(ST, { id: 3, surface: "slack:T1", channel: "C1", title: null, firstText: "<@U1> 看下构建", sessions: [{ session: "k3" }] });
  data.putItems("entry", ST, "1", [[1, { text: "a" }]]);
  data.putItems("entry", ST, "2", [[1, { text: "b".repeat(500) }]]);
  data.putItems("entry", ST, "3", [[1, { text: "c".repeat(50) }]]);
  const ui = t.core.connect();
  call(t.core, ui, 1, "cache.usage", {});
  await t.host.settle();
  const usage = answers(t.host.takeEmitted(), 1)?.ok as { chats: { thread: number; title: string | null }[] };
  assert.deepEqual(usage.chats.filter((c) => c.thread <= 3).map((c) => [c.thread, c.title]), [[2, "新对话"], [3, "看下构建"], [1, "处理构建问题"]]);
  t.core.close();
});

test("what each file's parts take is kept as they are put, fail, move and go, counted from a database from before, and summed where it cannot be written", async () => {
  const host = new FakeHost();
  // (a statement it matches fails as SQLite's does with no room)
  let full: RegExp | null = null;
  host.openDbHook = (name) => {
    const inner = (host.openDbHook = null, Effect.runSync(host.openDb(name)));
    host.openDbHook = (n) => (n === name ? wrapped : null);
    const room = (q: string) => {
      if (full?.test(q)) throw new SqlError("database or disk is full", "full");
    };
    const wrapped: Sql = {
      exec: (q: string) => (room(q), inner.exec(q)),
      run: (q: string, p?: readonly SqlValue[]) => (room(q), inner.run(q, p)),
      all: (q: string, p?: readonly SqlValue[]) => (room(q), inner.all(q, p)),
      close: () => {},
    };
    return wrapped;
  };
  const most = { file: 30, played: 1000, chat: Number.POSITIVE_INFINITY, sent: 1000, outbox: Number.POSITIVE_INFINITY };
  let kept = new DriveKept(host, most);
  const run = <A>(e: Effect.Effect<A>) => Effect.runPromise(e);
  const sql = () => host.sqls.get("drive-kept")!;
  const same = (label: string) => {
    const counted = sql().all("SELECT id, bytes FROM part_bytes ORDER BY id").map((r) => `${r[0]} ${r[1]}`);
    const summed = sql().all("SELECT id, sum(length) FROM part GROUP BY id HAVING sum(length) <> 0 ORDER BY id").map((r) => `${r[0]} ${r[1]}`);
    assert.deepEqual(counted, summed, label);
  };
  /// What the page of what the device keeps says, as summing the parts says it.
  const page = async () => [await run(kept.usage()), (await run(kept.chatFiles())).map((f) => `${f.key}/${f.name} ${f.bytes}`)];
  const summedPage = () => [
    Number(sql().all("SELECT coalesce(sum(p.length), 0) FROM part p JOIN kept k ON k.id = p.id WHERE k.kind != 'chat'")[0]![0]),
    sql().all("SELECT k.id, coalesce(sum(p.length), 0) FROM kept k LEFT JOIN part p ON p.id = k.id WHERE k.kind = 'chat' GROUP BY k.id ORDER BY k.used DESC, k.id")
      .map((r) => `${String(r[0]).split("\n")[2]}/${String(r[0]).split("\n").slice(3).join("\n")} ${r[1]}`),
  ];
  // Put: a file's parts, a chat's, one put again (as a core from before would, replacing it).
  const book = keptId(ST, ROOT, "book");
  await run(kept.keep(book, "file", 1, 20, "application/pdf", 0, bytesOf(8)));
  await run(kept.keep(book, "file", 1, 20, "application/pdf", 8, bytesOf(6)));
  for (const [key, name, n] of [["k1", "a.png", 5], ["k1", "b.mp4", 9], ["k2", "c.png", 3], ["k10", "d.png", 4]] as const) {
    await run(kept.keep(chatKeptId(ST, key, name), "chat", 1, 40, "image/png", 0, bytesOf(n)));
    host.advance(61_000);
  }
  sql().run("INSERT OR REPLACE INTO part (id, at, length, key) SELECT id, at, length, key FROM part WHERE id = ? AND at = 0", [book]);
  same("put");
  assert.deepEqual(await page(), summedPage());
  // A part whose bytes could not be kept: its row goes.
  const set = host.storageSet;
  host.storageSet = () => Effect.fail(new Error("no room") as never);
  await run(kept.keep(book, "file", 1, 20, "application/pdf", 14, bytesOf(6)));
  host.storageSet = set;
  same("a part that failed");
  // Moved to another name, and past the bound of its kind: the least lately read let go.
  const going = outboxKeptId("clip");
  await run(kept.keep(going, "outbox", 0, 10, "video/mp4", 0, bytesOf(10)));
  assert.equal(await run(kept.rename(going, sentKeptId(ST, "clip.mp4"), "sent", 10)), true);
  same("renamed");
  host.advance(61_000);
  await run(kept.keep(keptId(ST, ROOT, "big"), "file", 1, 25, "application/pdf", 0, bytesOf(25)));
  assert.equal(await run(kept.has(book)), false, "the book let go past the bound");
  same("let go");
  // A file changed on the station: what was kept of it goes as it is kept anew.
  await run(kept.keep(chatKeptId(ST, "k2", "c.png"), "chat", 2, 41, "image/png", 0, bytesOf(7)));
  same("changed");
  // A chat's files let go with it: its sessions' alone (k1, not k10 though it starts the same).
  await run(kept.forgetChat(ST, ["k1"]));
  assert.deepEqual((await run(kept.chatFiles())).map((f) => f.key).sort(), ["k10", "k2"]);
  same("a chat's let go");
  assert.deepEqual(await page(), summedPage());
  // The page read of the counts: no part summed.
  const read: string[] = [];
  const all = sql().all.bind(sql());
  sql().all = (q: string, p?: readonly SqlValue[]) => (read.push(q), all(q, p));
  await page();
  sql().all = all;
  assert.deepEqual(read.filter((q) => /\bFROM part\b|\bJOIN part\b/.test(q)), [], "no part read for the page");
  // A database a core from before kept: counted as it opens.
  for (const r of sql().all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'part'")) sql().exec(`DROP TRIGGER ${r[0]}`);
  sql().exec("DROP TABLE part_bytes");
  sql().run("INSERT INTO part (id, at, length, key) VALUES (?, 0, 11, 'drive-kept-old')", [chatKeptId(ST, "k3", "old.png")]);
  sql().run("INSERT INTO kept (id, kind, mtime, size, type, used) VALUES (?, 'chat', 1, 11, 'image/png', 0)", [chatKeptId(ST, "k3", "old.png")]);
  kept = new DriveKept(host, most);
  assert.deepEqual(await page(), summedPage());
  same("counted from before");
  // The same with no room to count it: nothing of it written, the parts summed, and kept and let go as before.
  for (const r of sql().all("SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'part'")) sql().exec(`DROP TRIGGER ${r[0]}`);
  sql().exec("DROP TABLE part_bytes");
  full = /^INSERT INTO part_bytes/;
  kept = new DriveKept(host, most);
  assert.deepEqual(await page(), summedPage());
  assert.equal(sql().all("SELECT count(*) FROM sqlite_master WHERE name = 'part_bytes' OR (type = 'trigger' AND tbl_name = 'part')")[0]![0], 0, "nothing of it made");
  await run(kept.keep(chatKeptId(ST, "k3", "new.png"), "chat", 1, 6, "image/png", 0, bytesOf(6)));
  await run(kept.forgetChat(ST, ["k10"]));
  assert.deepEqual(await page(), summedPage());
  assert.ok(((await page())[1] as string[]).length > 0);
  // Room again: counted as it next opens.
  full = null;
  kept = new DriveKept(host, most);
  assert.deepEqual(await page(), summedPage());
  same("room again");
});
