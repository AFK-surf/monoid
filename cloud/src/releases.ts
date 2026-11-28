// A file of the releases bucket, served at /releases/<file> (install.ts releaseType says which): whole, or the byte
// ranges asked for. The desktop app's updater (electron-updater) downloads an update differentially: it compares the
// blockmaps of the zip it has and the new one, and asks for what changed as up to a thousand ranges in a request,
// answered as multipart/byteranges. The bucket reads one range at a time, so ranges near each other are read as one.

/** The part of R2Bucket this needs. */
export interface ReleaseBucket {
  head(key: string): Promise<{ size: number; httpEtag: string } | null>;
  get(key: string, options?: { range?: { offset: number; length: number } }): Promise<{ body: ReadableStream<Uint8Array>; size: number; httpEtag: string } | null>;
}

/** A range asked for: the first byte and the one after the last. */
type Range = { start: number; end: number };

/** Reads that would be more than this many are made from ranges further apart, reading the bytes between. */
const MAX_READS = 40;

/** A file named by its version (a build's zip or installer and its blockmap, raw form and deltas, an apk and its deltas, a Linux build's deltas, a Node, a module's package, a face's, the site's film) or by its content (the station's archives kept under their own names, their deltas) never changes; the rest do (the feeds, the station's). */
export const VERSIONED = /^fonts\/|-[0-9.]+-(arm64-mac\.zip|x64-win\.exe)(\.blockmap|\.raw\.zst|\.from-[0-9]+\.delta)?$|^desktop\/web\/stillfail-beta-web-[0-9.]+\.tar\.gz$|-[0-9]+\.apk(\.from-[0-9]+\.delta)?$|^linux\/stillfail-mbui-[0-9]+-(x64|arm64)-linux\.tar\.gz\.from-[0-9]+\.delta$|^station\/archive\/(stable|beta)\/[0-9]+-[0-9a-f]{64}-|^node\/node-v[0-9.]+-[a-z0-9-]+\.tar\.gz(\.sha256)?$|^modules\/[a-z][a-z0-9]*\/[a-z][a-z0-9]*-0\.1\.[0-9]+(-[a-z0-9-]+)?\.tar\.gz$|^site\/film-[a-z]+-[0-9]+\.mp4$/;

/** What the response of another cloud's releases (RELEASES_UPSTREAM) says that is passed on. */
const PASSED = ["content-type", "content-length", "content-range", "accept-ranges", "etag", "cache-control"];

/**
 * A read of the bucket or of another cloud's releases, which only reads: tried once more when it fails. R2 fails a
 * read now and then for a moment (10001, 10043; 10058 when many read one object at once, as at a release), and the
 * next read gets it. Its null (no such file) is an answer, not a failure. Failing twice, it is unavailable: a 503 that
 * tells the client to come back (`unavailable`), never a 404 that would say there is none. A write of the same bytes
 * (in memory, never a stream) under the same key is as safe to try again (icons.ts, move.ts).
 */
export async function retryRead<T>(run: () => Promise<T>): Promise<{ ok: true; value: T } | { ok: false; error: unknown }> {
  try {
    return { ok: true, value: await run() };
  } catch {
    try {
      return { ok: true, value: await run() };
    } catch (error) {
      return { ok: false, error };
    }
  }
}

/** The answer while a release cannot be read (`retryRead` failed twice): the 5xx stays seen (index.ts answer), the cause in the log. */
export function unavailable(file: string, error: unknown): Response {
  console.error(`release ${file} unavailable:`, error);
  return Response.json({ error: "release_unavailable" }, { status: 503, headers: { "cache-control": "no-store", "retry-after": "5" } });
}

/** Thrown where an answer cannot be given yet (icons.ts keptIcon): answered `unavailable` (api.ts directory). */
export class Unavailable extends Error {
  readonly file: string;
  constructor(file: string, cause: unknown) {
    super("release_unavailable", { cause });
    this.file = file;
  }
}

/** `file` from another cloud's releases (`upstream`, its /releases), the range asked for passed on; its 404 when it has none. */
export async function upstreamRelease(request: Request, upstream: string, file: string): Promise<Response> {
  const range = request.headers.get("range");
  const condition = request.headers.get("if-range");
  const got = await retryRead(async () => {
    const answer = await fetch(`${upstream.replace(/\/+$/, "")}/${file}`, { headers: range ? { range, ...(condition !== null ? { "if-range": condition } : {}) } : {} });
    if (answer.status >= 500) {
      await answer.body?.cancel().catch(() => {});
      throw new Error(`upstream answered ${answer.status}`);
    }
    return answer;
  });
  if (!got.ok) return unavailable(file, got.error);
  const answer = got.value;
  if (answer.status !== 200 && answer.status !== 206 && answer.status !== 416) {
    await answer.body?.cancel().catch(() => {});
    return notFound();
  }
  const headers = new Headers();
  for (const name of PASSED) {
    const value = answer.headers.get(name);
    if (value !== null) headers.set(name, value);
  }
  if (file.startsWith("fonts/")) headers.set("access-control-allow-origin", "*");
  return new Response(answer.body, { status: answer.status, headers });
}

export async function serveRelease(request: Request, bucket: ReleaseBucket | undefined, file: string, type: string): Promise<Response> {
  const headers: Record<string, string> = {
    "content-type": type,
    "accept-ranges": "bytes",
    "cache-control": VERSIONED.test(file) ? "public, max-age=31536000, immutable" : "no-store",
  };
  // A face is fetched by pages of other origins too: the desktop app's (app://), the test channel's.
  if (file.startsWith("fonts/")) headers["access-control-allow-origin"] = "*";
  const asked = request.headers.get("range");
  if (!asked) {
    const got = await retryRead(async () => bucket?.get(file));
    if (!got.ok) return unavailable(file, got.error);
    const object = got.value;
    if (!object) return notFound();
    return new Response(object.body, { headers: { ...headers, etag: object.httpEtag, "content-length": String(object.size) } });
  }
  const gotHead = await retryRead(async () => bucket?.head(file));
  if (!gotHead.ok) return unavailable(file, gotHead.error);
  const head = gotHead.value;
  if (!head) return notFound();
  // If-Range resumes only the same representation (RFC 9110 13.1.5). We advertise an ETag, not a
  // Last-Modified date: only an exact strong tag matches; a date or a weak tag needs the whole file.
  const condition = request.headers.get("if-range");
  if (condition !== null && (!condition.startsWith('"') || condition !== head.httpEtag)) return serveRelease(new Request(request.url), bucket, file, type);
  const size = head.size;
  const ranges = parseRanges(asked, size);
  // Not a range this understands: the whole file, as for a request without one.
  if (ranges === null) return serveRelease(new Request(request.url), bucket, file, type);
  if (!ranges.length) return new Response(null, { status: 416, headers: { ...headers, "content-range": `bytes */${size}` } });
  const etag = { etag: head.httpEtag };
  if (ranges.length === 1) {
    const [{ start, end }] = ranges as [Range];
    const got = await retryRead(() => bucket!.get(file, { range: { offset: start, length: end - start } }));
    if (!got.ok) return unavailable(file, got.error);
    const object = got.value;
    if (!object) return notFound();
    if (object.httpEtag !== head.httpEtag) {
      await object.body.cancel();
      return serveRelease(new Request(request.url), bucket, file, type);
    }
    return new Response(object.body, { status: 206, headers: { ...headers, ...etag, "content-range": `bytes ${start}-${end - 1}/${size}`, "content-length": String(end - start) } });
  }
  const boundary = crypto.randomUUID().replaceAll("-", "");
  const encoder = new TextEncoder();
  // As electron-updater's DataSplitter reads it: the first boundary with no line before it, each part's bytes, then
  // the next boundary on a line of its own.
  const partHead = (range: Range, first: boolean) => encoder.encode(
    `${first ? "" : "\r\n"}--${boundary}\r\ncontent-type: ${type}\r\ncontent-range: bytes ${range.start}-${range.end - 1}/${size}\r\n\r\n`,
  );
  const tail = encoder.encode(`\r\n--${boundary}--\r\n`);
  const length = ranges.reduce((sum, range, i) => sum + partHead(range, i === 0).length + range.end - range.start, tail.length);
  const reads = groupReads(ranges);
  const { readable, writable } = new FixedLengthStream(length);
  const write = async () => {
    const out = writable.getWriter();
    try {
      let part = 0;
      for (const read of reads) {
        // (only the read is tried again: once its bytes have gone out, a failure ends the response)
        const got = await retryRead(() => bucket!.get(file, { range: { offset: read.start, length: read.end - read.start } }));
        if (!got.ok) throw got.error;
        const object = got.value;
        if (!object) throw new Error(`${file} went away`);
        // The headers (and perhaps earlier parts) have gone: a replacement cannot finish this response.
        if (object.httpEtag !== head.httpEtag) {
          await object.body.cancel();
          throw new Error(`${file} changed while reading`);
        }
        // The parts in this read (ascending, apart), cut out of its bytes as they come.
        let at = read.start;
        for await (const chunk of object.body as unknown as AsyncIterable<Uint8Array>) {
          let offset = 0;
          while (offset < chunk.length && part <= read.last) {
            const range = ranges[part]!;
            if (at < range.start) {
              const skip = Math.min(range.start - at, chunk.length - offset);
              offset += skip;
              at += skip;
              continue;
            }
            if (at === range.start) await out.write(partHead(range, part === 0));
            const take = Math.min(range.end - at, chunk.length - offset);
            await out.write(chunk.subarray(offset, offset + take));
            offset += take;
            at += take;
            if (at === range.end) part++;
          }
        }
        if (part !== read.last + 1) throw new Error(`${file} ended early`);
      }
      await out.write(tail);
      await out.close();
    } catch (error) {
      await out.abort(error);
    }
  };
  // The Worker is done with the request once the answer is written out; the writing goes on while it is read.
  void write();
  return new Response(readable, {
    status: 206,
    headers: { ...headers, ...etag, "content-type": `multipart/byteranges; boundary=${boundary}`, "content-length": String(length) },
  });
}

const notFound = () => Response.json({ error: "release_not_found" }, { status: 404, headers: { "cache-control": "no-store" } });

/**
 * The ranges of a Range header, in the order asked (RFC 9110 14.1.2: first-last, first-, -suffix), within a file of
 * `size` bytes: none if none of them is in it (416), null if the header is not one this reads (answered with the whole file).
 */
export function parseRanges(header: string, size: number): Range[] | null {
  const spec = /^\s*bytes\s*=\s*(.+)$/i.exec(header)?.[1];
  if (!spec) return null;
  const ranges: Range[] = [];
  for (const item of spec.split(",")) {
    const m = /^\s*(\d*)\s*-\s*(\d*)\s*$/.exec(item);
    if (!m || (m[1] === "" && m[2] === "")) return null;
    if (m[1] === "") {
      const suffix = Number(m[2]);
      if (suffix > 0 && size > 0) ranges.push({ start: Math.max(0, size - suffix), end: size });
      continue;
    }
    const start = Number(m[1]);
    if (m[2] !== "" && Number(m[2]) < start) return null;
    if (start < size) ranges.push({ start, end: m[2] === "" ? size : Math.min(Number(m[2]) + 1, size) });
  }
  return ranges;
}

/**
 * The reads of the bucket that give the ranges, in order: runs of ranges read as one, each ending at range `last`,
 * so there are at most MAX_READS of them (reading the bytes between, which stay in Cloudflare) — fewer where ranges
 * are asked out of order.
 */
export function groupReads(ranges: Range[]): { start: number; end: number; last: number }[] {
  for (let gap = 64 * 1024; ; gap *= 2) {
    const reads: { start: number; end: number; last: number }[] = [];
    ranges.forEach((range, i) => {
      const read = reads.at(-1);
      if (read && range.start >= read.end && range.start - read.end <= gap) {
        read.end = range.end;
        read.last = i;
      } else {
        reads.push({ start: range.start, end: range.end, last: i });
      }
    });
    if (reads.length <= MAX_READS || gap > 2 ** 40) return reads;
  }
}

/** Each app's feed: the released builds', and the beta apps' (fail.still.*.beta, for testers: /releases/latest/<app>-beta). */
const FEEDS: Record<string, string> = {
  // (the apps' own updaters' feeds, which every product's apps have: monoid's never had electron-updater's .yml)
  mac: "mac/latest.json",
  android: "android/latest.json",
  "mac-beta": "mac/beta/latest.json",
  "android-beta": "android/beta/latest.json",
  win: "win/latest.json",
  "win-beta": "win/beta/latest.json",
  // still.fail mbui (apps/mbui), the test app in mbui
  "android-mbui": "android/mbui/latest.json",
  "mac-mbui": "mac/mbui/latest.json",
  "win-mbui": "win/mbui/latest.json",
  "linux-mbui": "linux/mbui/latest.json",
  "linux-arm64-mbui": "linux-arm64/mbui/latest.json",
};

/**
 * The latest build of an app, for a link that does not change (the site's downloads, /releases/latest/<app>): where its
 * updater's feed says it is, as a path under /releases/; missing while there is none, unavailable while its feed
 * cannot be read (`retryRead`).
 */
export async function latestDownload(bucket: ReleaseBucket | undefined, app: string): Promise<{ kind: "ok"; file: string } | { kind: "missing" } | { kind: "unavailable"; error: unknown }> {
  const feed = FEEDS[app];
  if (!feed || !bucket) return { kind: "missing" };
  const got = await retryRead(async () => {
    const object = await bucket.get(feed);
    return object ? await new Response(object.body).text() : null;
  });
  if (!got.ok) return { kind: "unavailable", error: got.error };
  const file = got.value === null ? null : feedFile(feed, got.value);
  return file === null ? { kind: "missing" } : { kind: "ok", file };
}

/** The file a feed names. */
function feedFile(feed: string, text: string): string | null {
  // electron-updater's feeds (the desktop app's) are YAML; the rest are an AppRelease's JSON
  if (feed.endsWith(".yml")) {
    const file = /^path:\s*(\S+)\s*$/m.exec(text)?.[1];
    return file ? `desktop/${file}` : null;
  }
  try {
    const file = (JSON.parse(text) as { file?: unknown }).file;
    return typeof file === "string" ? file : null;
  } catch {
    return null;
  }
}
