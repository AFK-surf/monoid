// Answers compressed for a client that asks so (`accept-encoding: zstd`, client/core-ts/src/station/requests.ts): on a
// slow link the bytes are the wait, and JSON goes to a fifth or less. zstd: a whole answer as small as deflate makes it,
// an event stream far smaller, as each event is compressed against the last megabyte of the stream (what a stream
// tells again, a session's summary, a sidebar row, the overview, is a few bytes the next time; deflate looks back 32 KB
// only, and on a station that is busy the last time is further back than that): of a real station's stream, 7% of it
// rather than 24%. The stream is flushed after each event, so every one comes out whole as it arrives; so is a batch's
// answers given a line at a time (admin.ts `batchLines`), each page against the pages before it. Every answer at the
// fast level (a batch at level 9 was 8% smaller for some 7 ms more a batch). JSON and text only (pictures and
// archives are as small as they get), and nothing of a preview: its page reads it as the service sent it. A client from before asks nothing, and gets every answer as it was.
import { constants, createZstdCompress, zstdCompress } from "node:zlib";
import { promisify } from "node:util";
import type { Answer } from "./wire.ts";

export const ZSTD = "zstd";
/// A whole answer smaller than this goes as it is: compressed it would hardly be smaller.
const SMALL = 512;
/// zstd's fast level, and how far back a stream's events are compressed against (2^20: a megabyte; each end holds that
/// much for each stream).
const LEVEL = 3;
const WINDOW_LOG = 20;
const params = { [constants.ZSTD_c_compressionLevel]: LEVEL, [constants.ZSTD_c_windowLog]: WINDOW_LOG };
const compressWhole = promisify(zstdCompress);

const header = (headers: Record<string, string>, name: string) => Object.entries(headers).find(([k]) => k.toLowerCase() === name)?.[1];

/// `answer` as it goes to a client that asked with `headers` for `path` (after /admin/api): compressed where it can be.
export async function compressed(answer: Answer, headers: Record<string, string>, path: string, extraTypes: readonly string[] = []): Promise<Answer> {
  const asked = (header(headers, "accept-encoding") ?? "").split(",").some((e) => e.trim() === ZSTD);
  if (!asked || path.startsWith("/preview/") || header(answer.headers, "content-encoding") !== undefined) return answer;
  const type = (header(answer.headers, "content-type") ?? "").split(";", 1)[0]!.trim().toLowerCase();
  if (type !== "application/json" && type !== "application/x-ndjson" && !type.startsWith("text/") && !extraTypes.includes(type)) return answer;
  // A length said was of what it says, not of what is sent (a file's progress would go by it): none is said.
  const sent = Object.fromEntries(Object.entries(answer.headers).filter(([k]) => k.toLowerCase() !== "content-length"));
  sent["content-encoding"] = ZSTD;
  if (Buffer.isBuffer(answer.body)) {
    if (answer.body.length < SMALL) return answer;
    return { ...answer, headers: sent, body: await compressWhole(answer.body, { params }) };
  }
  return { ...answer, headers: sent, body: compressedStream(answer.body) };
}

/// A stream's chunks compressed, each flushed as it goes. On normal EOF the encoder finishes its zstd frame once
/// (including an empty source); let go of (`return`) or on a source error it closes without faking a trailer and lets
/// go of the stream at once (written by hand: an async generator's would wait for the stream's next chunk).
function compressedStream(body: AsyncIterable<Buffer>): AsyncIterableIterator<Buffer> {
  const source = body[Symbol.asyncIterator]();
  const z = createZstdCompress({ params });
  // What it gives as it is written and flushed (flowing: a big chunk's output is never held back for want of a reader).
  const out: Buffer[] = [];
  let cancelled = false;
  let closed = false;
  let finished = false;
  let cancelPending: (() => void) | null = null;
  z.on("data", (part: Buffer) => out.push(part));
  // Keep an idle error listener so destroying/closing never surfaces as an uncaught stream error.
  z.on("error", () => {});
  const close = () => {
    if (closed) return;
    closed = true;
    const cancel = cancelPending;
    cancelPending = null;
    z.close();
    cancel?.();
  };
  const compress = (chunk: Buffer) =>
    new Promise<Buffer>((resolve, reject) => {
      if (cancelled || closed) return resolve(Buffer.alloc(0));
      let settled = false;
      const done = (err: Error | null) => {
        if (settled) return;
        settled = true;
        if (cancelPending === onCancel) cancelPending = null;
        z.off("error", onError);
        z.off("close", onClose);
        if (err) {
          cancelled = true;
          close();
          reject(err);
        } else resolve(cancelled ? Buffer.alloc(0) : Buffer.concat(out.splice(0)));
      };
      const onError = (err: Error) => done(err);
      const onClose = () => done(null);
      const onCancel = () => done(null);
      cancelPending = onCancel;
      z.once("error", onError);
      z.once("close", onClose);
      z.write(chunk, (error) => {
        if (error) done(error);
      });
      z.flush(constants.ZSTD_e_flush, () => done(null));
    });
  const finish = () =>
    new Promise<Buffer>((resolve, reject) => {
      if (cancelled || closed || finished) return resolve(Buffer.alloc(0));
      finished = true;
      let settled = false;
      const done = (err: Error | null) => {
        if (settled) return;
        settled = true;
        if (cancelPending === onCancel) cancelPending = null;
        z.off("error", onError);
        z.off("end", onEnd);
        z.off("close", onClose);
        close();
        if (err) reject(err);
        else resolve(cancelled ? Buffer.alloc(0) : Buffer.concat(out.splice(0)));
      };
      const onError = (err: Error) => done(err);
      const onEnd = () => done(null);
      const onClose = () => done(null);
      const onCancel = () => done(null);
      cancelPending = onCancel;
      z.once("error", onError);
      z.once("end", onEnd);
      z.once("close", onClose);
      z.end();
    });
  const it: AsyncIterableIterator<Buffer> = {
    [Symbol.asyncIterator]: () => it,
    next: async () => {
      if (cancelled || finished) return { done: true, value: undefined };
      let next: IteratorResult<Buffer>;
      try {
        next = await source.next();
      } catch (err) {
        cancelled = true;
        close();
        throw err;
      }
      if (cancelled) return { done: true, value: undefined };
      if (next.done) {
        const tail = await finish();
        if (cancelled) return { done: true, value: undefined };
        return tail.length > 0 ? { done: false, value: tail } : { done: true, value: undefined };
      }
      const chunk = await compress(next.value);
      if (cancelled) return { done: true, value: undefined };
      return { done: false, value: chunk };
    },
    return: async () => {
      cancelled = true;
      close();
      await source.return?.();
      return { done: true, value: undefined };
    },
  };
  return it;
}
