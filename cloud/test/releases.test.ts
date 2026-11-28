import assert from "node:assert/strict";
import test from "node:test";
import { harness } from "./harness.ts";
import { releaseType, sharedRelease } from "../src/install.ts";
import { VERSIONED, groupReads, latestDownload, parseRanges, serveRelease, upstreamRelease, type ReleaseBucket } from "../src/releases.ts";

// The releases bucket's files at /releases/<file>: whole, or the ranges asked for (one, or many as
// multipart/byteranges, as the desktop app's updater asks for what changed between two zips).

/** The parts of a multipart/byteranges answer: each one's content-range and bytes. */
function parts(body: Uint8Array, boundary: string): { range: string; bytes: Uint8Array }[] {
  const text = Buffer.from(body).toString("latin1");
  const out: { range: string; bytes: Uint8Array }[] = [];
  // As electron-updater's DataSplitter reads it: starting with the boundary, each part's bytes followed by CRLF and the next.
  assert.ok(text.startsWith(`--${boundary}\r\n`), "starts with the boundary");
  assert.ok(text.endsWith(`\r\n--${boundary}--\r\n`), "ends with the closing boundary");
  let at = 0;
  for (;;) {
    at = text.indexOf(`--${boundary}`, at) + boundary.length + 2;
    if (text.startsWith("--", at)) return out;
    const headEnd = text.indexOf("\r\n\r\n", at);
    const range = /content-range: bytes (\d+)-(\d+)\/\d+/i.exec(text.slice(at, headEnd))!;
    const start = headEnd + 4;
    const length = Number(range[2]) - Number(range[1]) + 1;
    out.push({ range: `${range[1]}-${range[2]}`, bytes: body.subarray(start, start + length) });
    at = start + length;
    assert.equal(text.slice(at, at + 2), "\r\n");
  }
}

test("a release is served whole or by ranges, the versioned builds cached for good", async () => {
  const h = await harness();
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: Uint8Array | string): Promise<unknown> };
    // 5 MB of bytes that say where they are.
    const zip = new Uint8Array(5 * 1024 * 1024).map((_, i) => (i * 7 + (i >> 11)) & 255);
    const name = "desktop/stillfail-0.1.1200-arm64-mac.zip";
    await bucket.put(name, zip);
    await bucket.put("desktop/stillfail-mac.yml", "version: 0.1.1200\n");

    const whole = await h.fetch(`/releases/${name}`);
    assert.equal(whole.status, 200);
    assert.equal(whole.headers.get("accept-ranges"), "bytes");
    assert.equal(whole.headers.get("cache-control"), "public, max-age=31536000, immutable");
    assert.deepEqual(new Uint8Array(await whole.arrayBuffer()), zip);
    const feed = await h.fetch("/releases/desktop/stillfail-mac.yml");
    assert.equal(feed.headers.get("cache-control"), "no-store");
    assert.equal(await feed.text(), "version: 0.1.1200\n");

    const one = await h.fetch(`/releases/${name}`, { headers: { range: "bytes=100-199" } });
    assert.equal(one.status, 206);
    assert.equal(one.headers.get("content-range"), `bytes 100-199/${zip.length}`);
    assert.deepEqual(new Uint8Array(await one.arrayBuffer()), zip.subarray(100, 200));
    const suffix = await h.fetch(`/releases/${name}`, { headers: { range: "bytes=-10" } });
    assert.deepEqual(new Uint8Array(await suffix.arrayBuffer()), zip.subarray(zip.length - 10));
    const outside = await h.fetch(`/releases/${name}`, { headers: { range: `bytes=${zip.length}-` } });
    assert.equal(outside.status, 416);
    assert.equal(outside.headers.get("content-range"), `bytes */${zip.length}`);
    await outside.arrayBuffer();

    // As the updater asks: many ranges, near each other and far apart, some next to each other.
    const asked: [number, number][] = [];
    for (let i = 0; i < 300; i++) {
      const start = i * 17_000 + (i % 3) * 5;
      asked.push([start, start + 1 + (i % 50) * 31]);
    }
    asked.push([4_000_000, 4_000_099], [4_000_100, 4_000_199], [5 * 1024 * 1024 - 5, 5 * 1024 * 1024 - 1]);
    const many = await h.fetch(`/releases/${name}`, { headers: { range: "bytes=" + asked.map(([a, b]) => `${a}-${b}`).join(", ") } });
    assert.equal(many.status, 206);
    const boundary = /^multipart\/byteranges; boundary=(\S+)$/.exec(many.headers.get("content-type") ?? "")?.[1];
    assert.ok(boundary);
    const body = new Uint8Array(await many.arrayBuffer());
    assert.equal(Number(many.headers.get("content-length")), body.length);
    const got = parts(body, boundary);
    assert.equal(got.length, asked.length);
    got.forEach((part, i) => {
      const [a, b] = asked[i]!;
      assert.equal(part.range, `${a}-${b}`);
      assert.deepEqual(part.bytes, zip.subarray(a, b + 1));
    });

    assert.equal((await h.fetch("/releases/desktop/stillfail-0.1.1199-arm64-mac.zip", { headers: { range: "bytes=0-1" } })).status, 404);
  } finally {
    await h.close();
  }
});

test("a release's ranges resume only the representation named by If-Range", async () => {
  const h = await harness();
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    const name = "stillfail-station-linux-x64.tar.gz";
    await bucket.put(name, "old archive");
    const before = await h.fetch(`/releases/${name}`);
    const oldTag = before.headers.get("etag")!;
    await before.arrayBuffer();
    await bucket.put(name, "new archive");
    const whole = await h.fetch(`/releases/${name}`);
    const tag = whole.headers.get("etag")!;
    await whole.arrayBuffer();
    assert.notEqual(tag, oldTag);

    const same = await h.fetch(`/releases/${name}`, { headers: { range: "bytes=4-", "if-range": tag } });
    assert.equal(same.status, 206);
    assert.equal(same.headers.get("content-range"), "bytes 4-10/11");
    assert.equal(await same.text(), "archive");
    // No Last-Modified is advertised, so an HTTP-date cannot validate a resumed copy here.
    for (const validator of [oldTag, `W/${tag}`, "Mon, 16 Nov 2026 00:00:00 GMT"]) {
      for (const range of ["bytes=4-", "bytes=0-1,4-5", "bytes=100-"]) {
        const changed = await h.fetch(`/releases/${name}`, { headers: { range, "if-range": validator } });
        assert.equal(changed.status, 200, `${validator}: ${range}`);
        assert.equal(changed.headers.get("content-range"), null);
        assert.equal(changed.headers.get("etag"), tag);
        assert.equal(await changed.text(), "new archive");
      }
    }
    const noRange = await h.fetch(`/releases/${name}`, { headers: { "if-range": oldTag } });
    assert.equal(noRange.status, 200);
    assert.equal(await noRange.text(), "new archive");
  } finally {
    await h.close();
  }
});

/** Node has no FixedLengthStream (workerd's): a TransformStream that keeps no count stands in for it. */
function withFixedLengthStream(t: { after(fn: () => void): void }) {
  const previous = Object.getOwnPropertyDescriptor(globalThis, "FixedLengthStream");
  Object.defineProperty(globalThis, "FixedLengthStream", { configurable: true, value: class extends TransformStream<Uint8Array, Uint8Array> {
    constructor(_length: number) { super(); }
  } });
  t.after(() => { if (previous) Object.defineProperty(globalThis, "FixedLengthStream", previous); else Reflect.deleteProperty(globalThis, "FixedLengthStream"); });
}

// The object is replaced at a chosen read, without relying on requests racing on a real bucket.
function changingRelease(changeAt: number): ReleaseBucket {
  let reads = 0;
  return {
    head: async () => ({ size: 100_000, httpEtag: '"old"' }),
    get: async (_file, options) => {
      const changed = !options?.range || ++reads >= changeAt;
      const bytes = new Uint8Array(100_000).fill(changed ? 2 : 1);
      const range = options?.range;
      const part = range ? bytes.subarray(range.offset, range.offset + range.length) : bytes;
      return { body: new Response(part).body!, size: bytes.length, httpEtag: changed ? '"new"' : '"old"' };
    },
  };
}

test("a release replaced after its head was read restarts a single range as the whole file", async () => {
  const answer = await serveRelease(new Request("https://releases.test/file", { headers: { range: "bytes=4-9", "if-range": '"old"' } }), changingRelease(1), "file", "application/octet-stream");
  assert.equal(answer.status, 200);
  assert.equal(answer.headers.get("content-range"), null);
  assert.equal(answer.headers.get("etag"), '"new"');
  assert.deepEqual(new Uint8Array(await answer.arrayBuffer()), new Uint8Array(100_000).fill(2));
});

test("a release replaced between multipart reads cannot complete a mixed response", async (t) => {
  // The integration test above holds the byte count in workerd; this test controls the bucket's changes and needs
  // only the stream's write/abort behavior.
  withFixedLengthStream(t);
  const answer = await serveRelease(new Request("https://releases.test/file", { headers: { range: "bytes=0-1,70000-70001", "if-range": '"old"' } }), changingRelease(2), "file", "application/octet-stream");
  assert.equal(answer.status, 206);
  await assert.rejects(answer.arrayBuffer(), /changed while reading/);
});

// R2 fails a read now and then for a moment (as on 2026-11-25, `get: ... (10043)` while every station updated at once):
// each read is tried once more, and a release that cannot be read twice is unavailable for now (503), never missing (404).
const r2Down = () => new Error("get: Please look at https://www.cloudflarestatus.com for issues or contact customer support. (10043)");

/** A bucket of one 100 000-byte file whose reads of each kind (head, whole, range) fail the first `fails[kind]` times. */
function flakyRelease(fails: { head?: number; whole?: number; range?: number }): ReleaseBucket & { calls: string[] } {
  const bytes = new Uint8Array(100_000).map((_, i) => i & 255);
  const left = { head: 0, whole: 0, range: 0, ...fails };
  const calls: string[] = [];
  const fail = (kind: "head" | "whole" | "range") => {
    calls.push(kind);
    if (left[kind] > 0) {
      left[kind]--;
      throw r2Down();
    }
  };
  return {
    calls,
    head: async () => (fail("head"), { size: bytes.length, httpEtag: '"v"' }),
    get: async (_file, options) => {
      const range = options?.range;
      fail(range ? "range" : "whole");
      return { body: new Response(range ? bytes.slice(range.offset, range.offset + range.length) : bytes).body!, size: bytes.length, httpEtag: '"v"' };
    },
  };
}

const ask = (range?: string) => new Request("https://releases.test/file", { headers: range ? { range } : {} });

async function assertUnavailable(answer: Response) {
  assert.equal(answer.status, 503);
  assert.equal(answer.headers.get("retry-after"), "5");
  assert.equal(answer.headers.get("cache-control"), "no-store");
  assert.deepEqual(await answer.json(), { error: "release_unavailable" });
}

test("a release whose read fails once is read again; failing twice, it is unavailable, not missing", async () => {
  const whole = flakyRelease({ whole: 1 });
  const once = await serveRelease(ask(), whole, "file", "application/octet-stream");
  assert.equal(once.status, 200);
  assert.equal((await once.arrayBuffer()).byteLength, 100_000);
  assert.deepEqual(whole.calls, ["whole", "whole"]);
  await assertUnavailable(await serveRelease(ask(), flakyRelease({ whole: 2 }), "file", "application/octet-stream"));

  for (const fails of [{ head: 1 }, { range: 1 }]) {
    const answer = await serveRelease(ask("bytes=10-19"), flakyRelease(fails), "file", "application/octet-stream");
    assert.equal(answer.status, 206, JSON.stringify(fails));
    assert.deepEqual(new Uint8Array(await answer.arrayBuffer()), new Uint8Array(10).map((_, i) => 10 + i));
  }
  for (const fails of [{ head: 2 }, { range: 2 }]) {
    await assertUnavailable(await serveRelease(ask("bytes=10-19"), flakyRelease(fails), "file", "application/octet-stream"));
  }
  // none there is still none, read once
  const none: ReleaseBucket = { head: async () => null, get: async () => null };
  assert.equal((await serveRelease(ask(), none, "file", "application/octet-stream")).status, 404);
  assert.equal((await serveRelease(ask("bytes=0-1"), none, "file", "application/octet-stream")).status, 404);
});

test("a multipart read that fails once is read again and the parts come whole; failing twice ends the response", async (t) => {
  withFixedLengthStream(t);
  const once = flakyRelease({ range: 1 });
  const answer = await serveRelease(ask("bytes=0-1,90000-90001"), once, "file", "application/octet-stream");
  assert.equal(answer.status, 206);
  const boundary = /boundary=(\S+)$/.exec(answer.headers.get("content-type")!)![1]!;
  const got = parts(new Uint8Array(await answer.arrayBuffer()), boundary);
  assert.deepEqual(got.map((part) => [part.range, [...part.bytes]]), [["0-1", [0, 1]], ["90000-90001", [90000 & 255, 90001 & 255]]]);
  assert.deepEqual(once.calls, ["head", "range", "range", "range"]);

  const twice = await serveRelease(ask("bytes=0-1,90000-90001"), flakyRelease({ range: 2 }), "file", "application/octet-stream");
  assert.equal(twice.status, 206);
  await assert.rejects(twice.arrayBuffer(), /10043/);
});

test("an app's latest build is found though its feed's read fails once; failing twice, it is unavailable", async () => {
  const feed = (fails: number): ReleaseBucket => {
    let left = fails;
    return {
      head: async () => null,
      get: async (key) => {
        if (left-- > 0) throw r2Down();
        return key === "mac/latest.json" ? { body: new Response(JSON.stringify({ file: "desktop/stillfail-0.1.1200-arm64-mac.zip" })).body!, size: 0, httpEtag: '"f"' } : null;
      },
    };
  };
  assert.deepEqual(await latestDownload(feed(0), "mac"), { kind: "ok", file: "desktop/stillfail-0.1.1200-arm64-mac.zip" });
  assert.deepEqual(await latestDownload(feed(1), "mac"), { kind: "ok", file: "desktop/stillfail-0.1.1200-arm64-mac.zip" });
  const down = await latestDownload(feed(2), "mac");
  assert.equal(down.kind, "unavailable");
  assert.deepEqual(await latestDownload(feed(0), "android"), { kind: "missing" });
  assert.deepEqual(await latestDownload(feed(0), "windows"), { kind: "missing" });
  assert.deepEqual(await latestDownload(undefined, "mac"), { kind: "missing" });
});

test("a release read upstream is asked again after a failure or a 5xx; failing twice, it is unavailable, its 404 still none", async (t) => {
  const previous = globalThis.fetch;
  t.after(() => { globalThis.fetch = previous; });
  const answering = (...answers: (number | "error")[]) => {
    let asked = 0;
    globalThis.fetch = (async () => {
      const answer = answers[Math.min(asked++, answers.length - 1)]!;
      if (answer === "error") throw new TypeError("Network connection lost.");
      return new Response(answer === 200 ? "station" : "no", { status: answer });
    }) as typeof fetch;
    return () => asked;
  };
  for (const first of ["error", 502] as const) {
    const asked = answering(first, 200);
    const answer = await upstreamRelease(ask(), "https://upstream.test/releases", "station.json");
    assert.equal(answer.status, 200, String(first));
    assert.equal(await answer.text(), "station");
    assert.equal(asked(), 2);
    answering(first, first);
    await assertUnavailable(await upstreamRelease(ask(), "https://upstream.test/releases", "station.json"));
  }
  const asked = answering(404);
  assert.equal((await upstreamRelease(ask(), "https://upstream.test/releases", "station.json")).status, 404);
  assert.equal(asked(), 1);
});

test("a face's files: a page's stylesheet and slices, the Android app's file, cached for good and fetched from any origin", async () => {
  const h = await harness();
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: Uint8Array | string): Promise<unknown> };
    await bucket.put("fonts/noto-sans-sc/2.004/font.css", "@font-face{}");
    await bucket.put("fonts/noto-sans-sc/2.004/var-12.woff2", new Uint8Array([1, 2, 3]));
    await bucket.put("fonts/lxgw-wenkai/1.530/400.ttf.gz", new Uint8Array([4, 5]));
    await bucket.put("fonts/lxgw-wenkai/1.530/preview-0a1b2c3d.ttf", new Uint8Array([6]));
    for (const [path, type] of [["fonts/noto-sans-sc/2.004/font.css", "text/css; charset=utf-8"], ["fonts/noto-sans-sc/2.004/var-12.woff2", "font/woff2"], ["fonts/lxgw-wenkai/1.530/400.ttf.gz", "application/gzip"], ["fonts/lxgw-wenkai/1.530/preview-0a1b2c3d.ttf", "font/ttf"]] as const) {
      const got = await h.fetch(`/releases/${path}`);
      assert.equal(got.status, 200, path);
      assert.equal(got.headers.get("content-type"), type);
      assert.equal(got.headers.get("cache-control"), "public, max-age=31536000, immutable");
      assert.equal(got.headers.get("access-control-allow-origin"), "*");
      await got.arrayBuffer();
    }
    for (const path of ["fonts/noto-sans-sc/font.css", "fonts/noto-sans-sc/2.004/../x.css", "fonts/Noto/2.004/font.css", "fonts/noto-sans-sc/2.004/font.js", "fonts/noto-sans-sc/2.004/preview.ttf"]) {
      const got = await h.fetch(`/releases/${path}`);
      assert.equal(got.status, 404, path);
      await got.arrayBuffer();
    }
    // Only a face's files are for any origin.
    assert.equal((await h.fetch("/releases/station.json")).headers.get("access-control-allow-origin"), null);
  } finally {
    await h.close();
  }
});

test("ranges are read from the bucket in a few reads", () => {
  assert.deepEqual(parseRanges("bytes=0-9, 20-, -5", 100), [{ start: 0, end: 10 }, { start: 20, end: 100 }, { start: 95, end: 100 }]);
  assert.deepEqual(parseRanges("bytes=200-300", 100), []);
  assert.equal(parseRanges("bytes=9-1", 100), null);
  assert.equal(parseRanges("items=0-1", 100), null);
  const ranges = Array.from({ length: 1000 }, (_, i) => ({ start: i * 1_000_000, end: i * 1_000_000 + 10 }));
  const reads = groupReads(ranges);
  assert.ok(reads.length <= 40, `${reads.length} reads`);
  assert.equal(reads.at(-1)!.last, 999);
  // Out of order: a read never goes back.
  assert.deepEqual(groupReads([{ start: 50, end: 60 }, { start: 0, end: 10 }]).map((r) => r.last), [0, 1]);
});

test("/releases/latest/<app> goes to the app's latest build, as its updater's feed names it", async () => {
  const h = await harness();
  try {
    assert.equal((await h.fetch("/releases/latest/mac", { redirect: "manual" })).status, 404, "none released yet");
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: Uint8Array | string): Promise<unknown> };
    await bucket.put("mac/latest.json", JSON.stringify({ versionCode: 1200, file: "desktop/stillfail-0.1.1200-arm64-mac.zip" }));
    await bucket.put("android/latest.json", JSON.stringify({ versionCode: 1200, file: "android/stillfail-1200.apk" }));
    const mac = await h.fetch("/releases/latest/mac", { redirect: "manual" });
    assert.equal(mac.status, 302);
    assert.equal(new URL(mac.headers.get("location")!, "http://x").pathname, "/releases/desktop/stillfail-0.1.1200-arm64-mac.zip");
    const android = await h.fetch("/releases/latest/android", { redirect: "manual" });
    assert.equal(new URL(android.headers.get("location")!, "http://x").pathname, "/releases/android/stillfail-1200.apk");
    assert.equal((await h.fetch("/releases/latest/windows", { redirect: "manual" })).status, 404);
    assert.equal((await h.fetch("/releases/latest/win", { redirect: "manual" })).status, 404, "no Windows app released yet");
    await bucket.put("win/latest.json", JSON.stringify({ versionCode: 1200, file: "desktop/stillfail-0.1.1200-x64-win.exe" }));
    await bucket.put("win/beta/latest.json", JSON.stringify({ versionCode: 1201, file: "desktop/stillfail-beta-0.1.1201-x64-win.exe" }));
    const win = await h.fetch("/releases/latest/win", { redirect: "manual" });
    assert.equal(new URL(win.headers.get("location")!, "http://x").pathname, "/releases/desktop/stillfail-0.1.1200-x64-win.exe");
    const winBeta = await h.fetch("/releases/latest/win-beta", { redirect: "manual" });
    assert.equal(new URL(winBeta.headers.get("location")!, "http://x").pathname, "/releases/desktop/stillfail-beta-0.1.1201-x64-win.exe");
  } finally {
    await h.close();
  }
});

test("a cloud of its own reads the station's releases from still.fail's when its bucket has none, never an app's", async () => {
  const asked: string[] = [];
  const h = await harness({
    upstream: (file, request): { status: number; body?: string; headers?: Record<string, string> } => {
      asked.push(`${file} ${request.headers.range ?? ""}`.trim());
      if (file === "station.json") return { status: 200, body: '{"version":"0.1.9"}', headers: { "content-type": "application/json" } };
      if (file === "stillfail-station-linux-x64.tar.gz") return { status: 206, body: "tion", headers: { "content-range": "bytes 3-6/10", "content-type": "application/gzip" } };
      return { status: 404 };
    },
  });
  try {
    const bucket = (await h.mf.getR2Bucket("RELEASES", "api")) as unknown as { put(key: string, value: string): Promise<unknown> };
    await bucket.put("fonts/noto-sans-sc/2.004/font.css", "/* own */");

    const feed = await h.fetch("/releases/station.json");
    assert.equal(feed.status, 200);
    assert.equal(await feed.text(), '{"version":"0.1.9"}');
    const part = await h.fetch("/releases/stillfail-station-linux-x64.tar.gz", { headers: { range: "bytes=3-6" } });
    assert.equal(part.status, 206);
    assert.equal(part.headers.get("content-range"), "bytes 3-6/10");
    assert.equal(await part.text(), "tion");
    // its own bucket's first
    assert.equal(await (await h.fetch("/releases/fonts/noto-sans-sc/2.004/font.css")).text(), "/* own */");
    // none there either: none
    assert.equal((await h.fetch("/releases/station-beta.json")).status, 404);
    // an app's feed is its own alone, even when it has none
    assert.equal((await h.fetch("/releases/android/latest.json")).status, 404);
    assert.deepEqual(asked, ["station.json", "stillfail-station-linux-x64.tar.gz bytes=3-6", "station-beta.json"]);
  } finally {
    await h.close();
  }
});

test("a release read upstream keeps the client's If-Range condition", async () => {
  const asked: Record<string, string>[] = [];
  const h = await harness({
    upstream: (_file, request): { status: number; body: string; headers: Record<string, string> } => {
      asked.push(request.headers);
      return request.headers["if-range"] === '"old"'
        ? { status: 200, body: "new archive", headers: { etag: '"new"' } }
        : { status: 206, body: "archive", headers: { "content-range": "bytes 4-10/11", etag: '"new"' } };
    },
  });
  try {
    for (const tag of ['"old"', '"new"']) {
      const answer = await h.fetch("/releases/stillfail-station-linux-x64.tar.gz", { headers: { range: "bytes=4-", "if-range": tag } });
      assert.equal(answer.status, tag === '"old"' ? 200 : 206);
      assert.equal(answer.headers.get("etag"), '"new"');
      assert.equal(await answer.text(), tag === '"old"' ? "new archive" : "archive");
    }
    assert.deepEqual(asked.map((headers) => [headers.range, headers["if-range"]]), [["bytes=4-", '"old"'], ["bytes=4-", '"new"']]);
  } finally {
    await h.close();
  }
});

// A release's deltas (scripts/release-deltas.ts), the Windows installer's raw form and the station's archives kept under
// names of their own: served by those names alone, each with its type, cached for good (named by version or content).
test("the deltas, raw installers and kept station archives are served by their names, for good", () => {
  const sha = "0123456789abcdef".repeat(4);
  const served: [string, string][] = [
    ["desktop/stillfail-beta-0.1.8147-arm64-mac.zip.from-8142.delta", "application/octet-stream"],
    ["desktop/stillfail-0.1.8147-x64-win.exe.from-8146.delta", "application/octet-stream"],
    ["desktop/monoid-beta-0.1.8147-x64-win.exe.raw.zst", "application/zstd"],
    ["android/stillfail-beta-8147.apk.from-8146.delta", "application/octet-stream"],
    ["win/stillfail-mbui-8147-x64-win.exe.from-8146.delta", "application/octet-stream"],
    ["win/stillfail-mbui-8147-x64-win.exe.raw.zst", "application/zstd"],
    ["linux/stillfail-mbui-8147-arm64-linux.tar.gz.from-8146.delta", "application/octet-stream"],
    [`station/archive/beta/8164-${sha}-linux-x64.tar.gz`, "application/gzip"],
    [`station/archive/stable/8100-${sha}-win32-x64.zip`, "application/zip"],
    [`station/archive/beta/8164-${sha}-darwin-arm64.from-8163-${sha.slice(0, 16)}.delta`, "application/octet-stream"],
  ];
  for (const [file, type] of served) {
    assert.equal(releaseType(file), type, file);
    assert.ok(VERSIONED.test(file), `${file}: cached for good`);
  }
  // still.fail's stations' files: another cloud's (monoid's) reads them from still.fail's, its apps' never
  assert.ok(sharedRelease(`station/archive/beta/8164-${sha}-linux-x64.tar.gz`));
  assert.ok(!sharedRelease("desktop/monoid-beta-0.1.8147-x64-win.exe.raw.zst"));
  for (const file of [
    "desktop/stillfail-beta-0.1.8147-arm64-mac.zip.from-x.delta",
    "desktop/stillfail-beta-0.1.8147-arm64-mac.zip.raw.zst",
    "android/stillfail-beta-8147.apk.from-8146.delta.sig",
    "win/stillfail-mbui-8147-x64-win.exe.sig",
    "linux/stillfail-mbui-8147-x64-linux.tar.gz.raw.zst",
    `station/archive/beta/8164-${sha.slice(1)}-linux-x64.tar.gz`,
    `station/archive/nightly/8164-${sha}-linux-x64.tar.gz`,
    `station/archive/beta/8164-${sha}-linux-x64.zip`,
    `station/archive/beta/8164-${sha}-linux-x64.from-8163.delta`,
    `station/archive/beta/../8164-${sha}-linux-x64.tar.gz`,
    `station/8164-${sha}-linux-x64.tar.gz`,
  ]) assert.equal(releaseType(file), null, file);
  // what changes stays uncached
  for (const file of ["station-beta.json", "mac/beta/latest.json", "beta/stillfail-station-linux-x64.tar.gz"]) assert.ok(!VERSIONED.test(file), file);
});

test("upstreamRelease cancels unread response bodies on non-200/206/416 answers", async () => {
  const originalFetch = globalThis.fetch;
  let cancelled = 0;
  try {
    for (const status of [404, 403, 429]) {
      globalThis.fetch = async () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(new TextEncoder().encode("unused"));
            },
            cancel() {
              cancelled++;
            },
          }),
          { status },
        );
      const answer = await upstreamRelease(new Request("https://cloud.example/releases/station.json"), "https://upstream.test/releases", "station.json");
      assert.equal(answer.status, 404);
      assert.deepEqual(await answer.json(), { error: "release_not_found" });
    }
    assert.equal(cancelled, 3);
  } finally {
    globalThis.fetch = originalFetch;
  }
});
