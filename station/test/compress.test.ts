// Answers compressed for a client that asks so (src/mesh/compress.ts): JSON and text, whole or an event stream flushed
// after each event; nothing for one that does not ask, for a preview, for pictures, or for what is too small to gain.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createZstdDecompress, zstdDecompressSync } from "node:zlib";
import type { Answer } from "../src/api/request.ts";
import { ZSTD, compressed } from "../src/mesh/compress.ts";
import type { Stream } from "../src/mesh/native.ts";
import { send } from "../src/mesh/serve.ts";

const asks = { "accept-encoding": `gzip, ${ZSTD}` };
const json = (body: unknown): Answer => ({ status: 200, headers: { "content-type": "application/json" }, body: Buffer.from(JSON.stringify(body)) });
const rows = Array.from({ length: 200 }, (_, i) => ({ id: String(i), title: `部署 station ${i}`, agents: [], lastActiveAt: 1791478600000 + i }));

test("a whole JSON answer is compressed for a client that asks so, and only then", async () => {
  const answer = json(rows);
  const sent = await compressed(answer, asks, "/chats");
  assert.equal(sent.headers["content-encoding"], ZSTD);
  assert.deepEqual(JSON.parse(zstdDecompressSync(sent.body as Buffer).toString()), rows);
  assert.ok((sent.body as Buffer).length < (answer.body as Buffer).length / 5);
  // Not asked, a preview's, a picture, or small: as it is.
  assert.equal(await compressed(answer, {}, "/chats"), answer);
  assert.equal(await compressed(answer, { "accept-encoding": "gzip" }, "/chats"), answer);
  const page = { ...answer, headers: { "content-type": "text/html" } };
  assert.equal(await compressed(page, asks, "/preview/5173/index.html"), page);
  const picture = { ...answer, headers: { "content-type": "image/png" } };
  assert.equal(await compressed(picture, asks, "/sessions/k/files"), picture);
  const small = json({ ok: true });
  assert.equal(await compressed(small, asks, "/threads/1"), small);
});

const pages = Array.from({ length: 40 }, (_, p) => ({ status: 200, body: { last: 50, entries: Array.from({ length: 50 }, (_, i) => ({ n: i + 1, thread: p, kind: "message", authorKind: i % 2 ? "agent" : "person", author: i % 2 ? "chat:c-00be6a2584" : "a@x.com", text: `第 ${p}.${i} 条：${"部署 station 之后看日志 ".repeat(1 + ((p * 7 + i) % 5))}${(p * 131 + i * 17) % 997}`, attachments: [], quotes: [], at: 1791478600000 + p * 1000 + i })) } }));

test("several reads in one are compressed whole at the fast level, as any answer", async () => {
  const answer = json({ answers: pages });
  const batch = await compressed(answer, asks, "/batch");
  const one = await compressed(answer, asks, "/threads/1/entries");
  assert.deepEqual(JSON.parse(zstdDecompressSync(batch.body as Buffer).toString()), { answers: pages });
  assert.deepEqual(batch.body, one.body);
  assert.ok((batch.body as Buffer).length < (answer.body as Buffer).length / 5);
});

test("a batch's answers a line at a time are compressed line by line, each whole as it arrives, and let go of at once", async () => {
  // (admin.ts `batchLines`: one page read, one line given; the next page not read yet)
  const lines = pages.map((p) => `${JSON.stringify(p)}\n`);
  let at = 0;
  let let_go = false;
  const source: AsyncIterableIterator<Buffer> = {
    [Symbol.asyncIterator]: () => source,
    next: async () => (at < lines.length ? { done: false, value: Buffer.from(lines[at++]!) } : new Promise(() => {})),
    return: async () => {
      let_go = true;
      return { done: true, value: undefined };
    },
  };
  const sent = await compressed({ status: 200, headers: { "content-type": "application/x-ndjson", "cache-control": "no-store" }, body: source }, asks, "/batch");
  assert.equal(sent.headers["content-encoding"], ZSTD);
  const it = (sent.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  const read = createZstdDecompress();
  // (as bytes: a page's Chinese is split across the pieces it is decompressed in)
  const got: Buffer[] = [];
  read.on("data", (part: Buffer) => got.push(part));
  let sentBytes = 0;
  let raw = 0;
  for (let i = 0; i < lines.length; i++) {
    const next = await it.next();
    assert.equal(next.done, false);
    sentBytes += next.value.length;
    raw += Buffer.byteLength(lines[i]!);
    await new Promise((resolve) => read.write(next.value, resolve));
    // Each line reads whole as it comes, none waiting for the next page.
    const text = Buffer.concat(got).toString();
    assert.equal(text, lines.slice(0, i + 1).join(""));
    assert.deepEqual(JSON.parse(text.trimEnd().split("\n").at(-1)!), pages[i]);
  }
  // (each page against the pages before it)
  assert.ok(sentBytes < raw / 5, `${sentBytes} < ${raw} / 5`);
  read.close();
  await it.return?.();
  assert.equal(let_go, true);
});

test("an event stream is compressed event by event, each whole as it arrives, and let go of at once", async () => {
  const events = [
    ...Array.from({ length: 50 }, (_, i) => `id: 1f2e3d4c.${i}\nevent: session\ndata: ${JSON.stringify({ key: `chat:c-${i % 5}`, turns: i, process: "warm" })}\n\n`),
    // One far bigger than what a stream holds back unread.
    `event: live\ndata: ${JSON.stringify({ entries: Array.from({ length: 4000 }, (_, i) => ({ kind: "tool_call", text: `step ${i} ${"x".repeat(200)}` })) })}\n\n`,
    "event: session\ndata: {}\n\n",
  ];
  let at = 0;
  let let_go = false;
  const source: AsyncIterableIterator<Buffer> = {
    [Symbol.asyncIterator]: () => source,
    next: async () => (at < events.length ? { done: false, value: Buffer.from(events[at++]!) } : new Promise(() => {})),
    return: async () => {
      let_go = true;
      return { done: true, value: undefined };
    },
  };
  const sent = await compressed({ status: 200, headers: { "content-type": "text/event-stream" }, body: source }, asks, "/events");
  assert.equal(sent.headers["content-encoding"], ZSTD);
  const it = (sent.body as AsyncIterable<Buffer>)[Symbol.asyncIterator]();
  // As a client reads it: each piece as it comes.
  const read = createZstdDecompress();
  let got = "";
  read.on("data", (part: Buffer) => (got += part.toString()));
  let sentBytes = 0;
  let raw = 0;
  for (let i = 0; i < events.length; i++) {
    const next = await it.next();
    assert.equal(next.done, false);
    sentBytes += next.value.length;
    raw += Buffer.byteLength(events[i]!);
    await new Promise((resolve) => read.write(next.value, resolve));
    // All that came so far reads as all the events so far: none waits for the next.
    assert.equal(got, events.slice(0, i + 1).join(""));
  }
  assert.ok(sentBytes < raw / 5);
  read.close();
  await it.return?.();
  assert.equal(let_go, true);
});

test("an answer whose head cannot be written lets go of the stream it would have sent", async () => {
  // The caller went while its answer was being made (GET /events reads the sidebar first): the events' follower made
  // for it is let go of, not kept and told everything for good.
  let let_go = 0;
  const source: AsyncIterableIterator<Buffer> = {
    [Symbol.asyncIterator]: () => source,
    next: () => new Promise(() => {}),
    return: async () => {
      let_go++;
      return { done: true, value: undefined };
    },
  };
  const gone: Stream = {
    read: async () => null,
    write: async () => {
      throw new Error("Cannot call write after a stream was destroyed");
    },
    finish: async () => {},
    stopped: () => new Promise(() => {}),
    reset: async () => {},
  };
  await assert.rejects(send(gone, { status: 200, headers: { "content-type": "text/event-stream" }, body: source }), /destroyed/);
  assert.equal(let_go, 1);
});

test("a whole answer says its length, so a picture shows how far it has come; a compressed one does not", async () => {
  const written: Buffer[] = [];
  const to: Stream = {
    read: async () => null,
    write: async (b: Buffer) => void written.push(b),
    finish: async () => {},
    stopped: () => new Promise(() => {}),
    reset: async () => {},
  };
  const head = async (answer: Answer) => {
    written.length = 0;
    await send(to, answer);
    return JSON.parse(written[0]!.toString()).headers as Record<string, string>;
  };
  const picture = Buffer.alloc(170 * 1024, 1);
  assert.equal((await head({ status: 200, headers: { "content-type": "image/png" }, body: picture }))["content-length"], String(picture.length));
  assert.equal(written[1], picture);
  const zipped = await compressed(json(rows), asks, "/chats");
  assert.equal((await head(zipped))["content-length"], undefined);
});
