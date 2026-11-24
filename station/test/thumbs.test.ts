// Thumbnails and ThumbHashes (src/drive/thumbs.ts, the addon's native/mesh/src/thumbs.rs): tests for thumbnail
// sizing, caching, ThumbHashes, and GET /sessions/:key/files?thumb=1 against test/fixtures/thumbs/golden.json
// (the JPEG and WebP fixtures live beside it; the PNGs are generated deterministically here).
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { crc32, deflateSync } from "node:zlib";
import { Admin } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { Jobs } from "../src/jobs/jobs.ts";
import { loadMesh } from "../src/mesh/native.ts";
import { Readers } from "../src/read/pool.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { sizeOf } from "../src/sessions/image-size.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { SMALL, dir, idOf, keep, kept, preview, thumbnail, wanted } from "../src/drive/thumbs.ts";
import { Store } from "../src/store/store.ts";
import type { Attachment } from "../src/store/rows.ts";
import { FakeDriver } from "./hub-fakes.ts";
import { fileURLToPath } from "node:url";

const fixtures = fileURLToPath(new URL("./fixtures/thumbs/", import.meta.url));
const golden = JSON.parse(readFileSync(join(fixtures, "golden.json"), "utf8")) as Record<
  string,
  { thumbnail: { type: string; sha256: string; bytes: number; width: number; height: number } | null; thumbhash: string | null }
>;
const codecs = loadMesh();

/// A PNG of `w`×`h` pixels, RGB or RGBA (what `pixel` gives), unfiltered; `level`, its deflate's (0: stored, as large
/// as a screenshot a careless program wrote).
function png(w: number, h: number, pixel: (x: number, y: number) => number[], level = 6): Buffer {
  const channels = pixel(0, 0).length;
  const raw = Buffer.alloc(h * (1 + w * channels));
  let at = 0;
  for (let y = 0; y < h; y++) {
    raw[at++] = 0;
    for (let x = 0; x < w; x++) for (const v of pixel(x, y)) raw[at++] = v & 255;
  }
  const chunk = (type: string, data: Buffer) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, "latin1");
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
    return Buffer.concat([head, data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = channels === 4 ? 6 : 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level })), chunk("IEND", Buffer.alloc(0))]);
}

/// thumbs.rs's tests' `noisy`.
const noisy = (w: number, h: number) => png(w, h, (x, y) => [x * 7 + y * 13, x ^ y, x * y]);

/// The images thumbs_golden.rs makes, made here; the rest are its fixtures.
function testImages(into: string) {
  mkdirSync(into, { recursive: true });
  writeFileSync(join(into, "shot.png"), noisy(1200, 800));
  writeFileSync(join(into, "tall.png"), noisy(500, 1500));
  writeFileSync(join(into, "cut.png"), png(1000, 1000, (x, y) => [x * 7, y * 3, x ^ y, x < 500 ? 0 : 255]));
  writeFileSync(join(into, "icon.png"), noisy(64, 64));
  writeFileSync(join(into, "clear.png"), png(80, 40, (x) => [200, 60, 20, x < 40 ? 0 : 255]));
  writeFileSync(join(into, "broken.png"), Buffer.alloc(200 * 1024, 7));
  writeFileSync(join(into, "moving.gif"), Buffer.alloc(200 * 1024, 0));
  writeFileSync(join(into, "notes.txt"), "hi");
  for (const name of ["photo.jpg", "photo-small.jpg", "icon.webp", "wide.webp"]) copyFileSync(join(fixtures, name), join(into, name));
}

/// What the whole-window viewer is shown before an image itself (thumbs.rs `preview`): a photo, smooth and large; a
/// screenshot, few colours with sharp edges, stored as it came.
const photo = () => png(4000, 3000, (x, y) => [x >> 4, y >> 4, (x * y) >> 12]);
const screenshot = () => png(1000, 600, (x, y) => (((x >> 1) ^ (y >> 1)) % 7 < 2 ? [0, 90, 200] : [255, 255, 255]), 0);

/// thumbhash's `thumb_hash_to_approximate_aspect_ratio`.
function aspect(hash: Buffer): number {
  const header = hash[3]!;
  const alpha = (hash[2]! & 0x80) !== 0;
  const landscape = (hash[4]! & 0x80) !== 0;
  const lx = landscape ? (alpha ? 5 : 7) : header & 7;
  const ly = landscape ? header & 7 : alpha ? 5 : 7;
  return lx / ly;
}

const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");
const sent = (path: string): Attachment => ({ name: path.split("/").at(-1)!, path, size: 0 });

/// Looks every 20 ms until `f` holds: a thumbnail is made in the background, on the file system. No deadline (it
/// comes, however slow the machine, or the test hangs).
async function until(_what: string, f: () => Promise<boolean>) {
  while (!(await f())) await new Promise((r) => setTimeout(r, 20));
}

test("which files: png, jpg, jpeg and webp, by name", () => {
  assert.deepEqual(["a.PNG", "b.jpg", "c.Jpeg", "d.webp", "e.gif", "f.svg", "png"].map(wanted), [true, true, true, true, false, false, false]);
  assert.equal(dir("/d"), join("/d", "thumbs"));
  assert.equal(SMALL, 24 * 1024);
  // The first 16 bytes of the SHA-256 of the path.
  assert.equal(idOf("/w/uploads/a.png"), sha256(Buffer.from("/w/uploads/a.png")).slice(0, 32));
});

test("makes a small jpeg of a big screenshot once", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "shot.png");
    writeFileSync(src, noisy(2400, 1600));
    const thumbs = join(tmp, "thumbs");
    const made = await thumbnail(src, thumbs, codecs);
    assert.equal(made?.type, "image/jpeg");
    assert.equal(made.path, join(thumbs, `${idOf(src)}.jpg`));
    assert.deepEqual(sizeOf(readFileSync(made.path)), [720, 480]);
    assert.ok(statSync(made.path).size < statSync(src).size);
    // Kept: asked again, the same file.
    const modified = statSync(made.path).mtimeMs;
    assert.equal((await thumbnail(src, thumbs, codecs))?.path, made.path);
    assert.equal(statSync(made.path).mtimeMs, modified);
    assert.deepEqual(await kept(thumbs, idOf(src)), made);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("keeps clear parts clear", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "cut.png");
    writeFileSync(src, png(1600, 1600, (x, y) => [x * 7, y * 3, x ^ y, x < 800 ? 0 : 255]));
    const made = await thumbnail(src, join(tmp, "thumbs"), codecs);
    assert.equal(made?.type, "image/png");
    // RGBA (colour type 6).
    assert.equal(readFileSync(made.path)[25], 6);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("leaves small images and others alone", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const thumbs = join(tmp, "thumbs");
    writeFileSync(join(tmp, "icon.png"), noisy(64, 64));
    assert.equal(await thumbnail(join(tmp, "icon.png"), thumbs, codecs), null);
    writeFileSync(join(tmp, "moving.gif"), Buffer.alloc(200 * 1024));
    assert.equal(await thumbnail(join(tmp, "moving.gif"), thumbs, codecs), null);
    writeFileSync(join(tmp, "broken.png"), Buffer.alloc(200 * 1024, 7));
    assert.equal(await thumbnail(join(tmp, "broken.png"), thumbs, codecs), null);
    assert.equal(await thumbnail(join(tmp, "missing.png"), thumbs, codecs), null);
    // Without the codecs, every image is shown itself.
    writeFileSync(join(tmp, "shot.png"), noisy(400, 400));
    assert.equal(await thumbnail(join(tmp, "shot.png"), thumbs, null), null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("a preview of a big photo: at most 2048 across, a JPEG at half the image or less, made once", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "photo.png");
    writeFileSync(src, photo());
    const thumbs = join(tmp, "thumbs");
    const made = await preview(src, thumbs, codecs);
    assert.equal(made?.type, "image/jpeg");
    assert.equal(made.path, join(thumbs, `${idOf(src)}.p.jpg`));
    assert.deepEqual(sizeOf(readFileSync(made.path)), [2048, 1536]);
    assert.ok(statSync(made.path).size * 2 <= statSync(src).size);
    // Kept: asked again, the same file; and beside the thumbnail, not it.
    const modified = statSync(made.path).mtimeMs;
    assert.equal((await preview(src, thumbs, codecs))?.path, made.path);
    assert.equal(statSync(made.path).mtimeMs, modified);
    assert.equal(await kept(thumbs, idOf(src)), null);
    assert.deepEqual(sizeOf(readFileSync((await thumbnail(src, thumbs, codecs))!.path)), [720, 540]);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("a preview of a screenshot under 2048 across: its pixels as they are, a lossless WebP smaller than a JPEG", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const src = join(tmp, "shot.png");
    writeFileSync(src, screenshot());
    const made = await preview(src, join(tmp, "thumbs"), codecs);
    assert.equal(made?.type, "image/webp");
    assert.equal(made.path, join(tmp, "thumbs", `${idOf(src)}.p.webp`));
    // Never made larger; VP8L, lossless.
    const bytes = readFileSync(made.path);
    assert.deepEqual(sizeOf(bytes), [1000, 600]);
    assert.equal(bytes.toString("latin1", 12, 16), "VP8L");
    assert.ok(bytes.length * 2 <= statSync(src).size);
    assert.equal((await preview(src, join(tmp, "thumbs"), codecs))?.path, made.path);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("no preview of an image of 300 KiB or less, or of one no copy halves", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const thumbs = join(tmp, "thumbs");
    // Large to look at, small to read: read whole at once.
    const flat = png(3000, 2000, (x, y) => (((x >> 6) + (y >> 6)) % 2 ? [255, 255, 255] : [20, 20, 20]));
    assert.ok(flat.length <= 300 * 1024);
    writeFileSync(join(tmp, "flat.png"), flat);
    assert.equal(await preview(join(tmp, "flat.png"), thumbs, codecs), null);
    // Over 300 KiB, but within 2048 and dense: no copy comes to half of it.
    const dense = noisy(1200, 800);
    assert.ok(dense.length > 300 * 1024);
    writeFileSync(join(tmp, "dense.png"), dense);
    assert.equal(await preview(join(tmp, "dense.png"), thumbs, codecs), null);
    // Nothing kept of either, and so asked again it is made again and not found.
    assert.deepEqual(existsSync(thumbs) ? readdirSync(thumbs) : [], []);
    // Not an image by name, unreadable, missing, or no codecs: none.
    writeFileSync(join(tmp, "moving.gif"), Buffer.alloc(400 * 1024));
    assert.equal(await preview(join(tmp, "moving.gif"), thumbs, codecs), null);
    writeFileSync(join(tmp, "broken.png"), Buffer.alloc(400 * 1024, 7));
    assert.equal(await preview(join(tmp, "broken.png"), thumbs, codecs), null);
    assert.equal(await preview(join(tmp, "missing.png"), thumbs, codecs), null);
    writeFileSync(join(tmp, "photo.png"), photo());
    assert.equal(await preview(join(tmp, "photo.png"), thumbs, null), null);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("gives images a thumbhash and makes their thumbnails", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-"));
  try {
    const [big, small, clear] = [join(tmp, "shot.png"), join(tmp, "icon.webp"), join(tmp, "cut.png")];
    writeFileSync(big, noisy(2400, 1600));
    copyFileSync(join(fixtures, "icon.webp"), small);
    writeFileSync(clear, png(80, 40, (x) => [200, 60, 20, x < 40 ? 0 : 255]));
    const notes = join(tmp, "notes.txt");
    writeFileSync(notes, "hi");
    const broken = join(tmp, "broken.jpg");
    writeFileSync(broken, Buffer.alloc(1024, 7));
    const thumbs = join(tmp, "thumbs");
    const files = await keep([sent(big), sent(small), sent(clear), sent(notes), sent(broken)], thumbs, codecs);
    for (const file of files.slice(0, 3)) {
      const bytes = Buffer.from(file.thumbhash!, "base64");
      assert.ok(bytes.length < 40, `${file.name}: ${bytes.length} bytes`);
      // Its shape comes with it, roughly (more roughly with clear parts).
      const [w, h] = sizeOf(readFileSync(file.path))!;
      assert.ok(Math.abs(aspect(bytes) / (w / h) - 1) < 0.25, `${file.name}: ${aspect(bytes)}`);
    }
    assert.deepEqual([files[3]!.thumbhash, files[4]!.thumbhash], [undefined, undefined]);
    assert.deepEqual(files[3], sent(notes));
    // The big one's thumbnail comes after, as if asked for.
    await until("the big one's thumbnail", async () => (await kept(thumbs, idOf(big))) !== null);
    assert.equal((await kept(thumbs, idOf(big)))!.type, "image/jpeg");
    assert.equal(await kept(thumbs, idOf(small)), null);
    // None wanted, or no codecs: as they came.
    const plain = [sent(notes)];
    assert.equal(await keep(plain, thumbs, codecs), plain);
    assert.deepEqual(await keep([sent(big)], thumbs, null), [sent(big)]);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test("turns a photo as its camera says", async () => {
  // A 40×20 JPEG whose EXIF says it is seen turned a quarter (orientation 6): 20×40.
  const seen = await codecs.thumbhash(join(fixtures, "photo-small.jpg"));
  assert.deepEqual([seen?.width, seen?.height], [20, 40]);
  assert.equal(seen!.hash, golden["photo-small.jpg"]!.thumbhash);
});

test("the files route and a message give what the Rust station gives", async () => {
  const data = mkdtempSync(join(tmpdir(), "thumbs-r-"));
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const config = hubConfig({ profiles: [{ id: "cc", runtime: "claude", home: "homes/cc" }] }, data);
  const hub = new Hub({ config: () => config, store, chats: () => undefined, drivers: [new FakeDriver("claude")], mcpUrl: "http://127.0.0.1:1/mcp", internal: new InternalChat(), runners: () => [] });
  const jobs = new Jobs({ store, data, notify: () => {}, link: () => null });
  hub.setJobs(jobs);
  const readers = new Readers(data, 1);
  readers.processes = () => hub.processes();
  const admin = new Admin(readers, { store, agents: { hub, jobs } as any });
  const viewer = { sub: "u", email: "a@x", name: "A", role: "member", workspace: "w", device: "d" };
  const ask = (method: string, path: string, body = "", query: [string, string][] = []) =>
    admin.handle({ method, path, query, headers: {}, body: Buffer.from(body), viewer, lang: "en" } satisfies Request);
  try {
    const made = JSON.parse(String((await ask("POST", "/sessions", JSON.stringify({ runtime: "claude" }))).body));
    const uploads = join(store.getSession(made.key)!.workspace, "uploads");
    testImages(uploads);
    const names = Object.keys(golden);
    const thumbs = join(data, "thumbs");
    const kinds: Record<string, string> = { png: "image/png", jpg: "image/jpeg", webp: "image/webp", gif: "image/gif", txt: "text/plain; charset=utf-8" };
    const fileOf = async (name: string, thumb: boolean) => {
      const a = await ask("GET", `/sessions/${encodeURIComponent(made.key)}/files`, "", thumb ? [["name", name], ["thumb", "1"]] : [["name", name]]);
      assert.equal(a.status, 200, name);
      assert.equal(a.headers["cache-control"], "private, max-age=3600", name);
      return [a.headers["content-type"], a.body as Buffer] as const;
    };
    for (const name of names) {
      const want = golden[name]!.thumbnail;
      const original = readFileSync(join(uploads, name));
      // Made on first asking (an image kept before thumbnails were made), then as kept.
      for (const time of ["made", "kept"]) {
        const [type, body] = await fileOf(name, true);
        if (want === null) assert.deepEqual([type, sha256(body)], [kinds[name.split(".").at(-1)!], sha256(original)], `${name} (${time}): the image itself`);
        else assert.deepEqual([type, sha256(body), body.length, sizeOf(body)], [want.type, want.sha256, want.bytes, [want.width, want.height]], `${name} (${time})`);
      }
      // Without thumb=1, the image itself.
      assert.equal(sha256((await fileOf(name, false))[1]), sha256(original), name);
    }

    // A message keeps each image's ThumbHash; an image's thumbnail is made after (the files route made them all above,
    // so they go first).
    rmSync(thumbs, { recursive: true, force: true });
    const attachments = names.map((name) => ({ path: join(uploads, name), name }));
    const posted = await ask("POST", `/threads/${made.thread.id}/messages`, JSON.stringify({ text: "look", attachments }));
    assert.equal(posted.status, 200, String(posted.body));
    const message = store.messagesBefore(made.thread.id, null, 10).find((m) => m.n === JSON.parse(String(posted.body)).n)!;
    assert.deepEqual(
      message.attachments.map((a) => [a.name, a.thumbhash ?? null]),
      names.map((name) => [name, golden[name]!.thumbhash]),
    );
    for (const name of names) {
      const want = golden[name]!.thumbnail;
      const id = idOf(join(uploads, name));
      if (want === null) continue;
      await until(`${name}'s thumbnail`, async () => (await kept(thumbs, id)) !== null);
      const got = (await kept(thumbs, id))!;
      assert.deepEqual([got.type, sha256(readFileSync(got.path))], [want.type, want.sha256], name);
    }
    // Small, other or unreadable images get none.
    for (const name of names.filter((n) => golden[n]!.thumbnail === null)) assert.equal(await kept(thumbs, idOf(join(uploads, name))), null, name);

    // thumb=2: an image's preview where it has one, else the image itself (which a station from before answers too:
    // a core tells them apart by the bytes, the image's size).
    writeFileSync(join(uploads, "big.png"), photo());
    const preview2 = async (name: string) => {
      const a = await ask("GET", `/sessions/${encodeURIComponent(made.key)}/files`, "", [["name", name], ["thumb", "2"]]);
      assert.equal(a.status, 200, name);
      return [a.headers["content-type"], a.body as Buffer] as const;
    };
    const [type, body] = await preview2("big.png");
    assert.equal(type, "image/jpeg");
    assert.deepEqual(sizeOf(body), [2048, 1536]);
    assert.ok(body.length * 2 <= statSync(join(uploads, "big.png")).size);
    for (const name of ["shot.png", "photo.jpg", "moving.gif", "notes.txt"]) {
      assert.equal(sha256((await preview2(name))[1]), sha256(readFileSync(join(uploads, name))), `${name}: the file itself`);
    }
  } finally {
    await hub.shutdown();
    await jobs.shutdown();
    readers.close();
    store.close();
    rmSync(data, { recursive: true, force: true });
  }
});

/// Fast striped PNG for tall or wide test images (level 0 stored deflate keeps encoding fast and larger than JPEG).
function fastStripedPng(w: number, h: number, alpha = false): Buffer {
  const channels = alpha ? 4 : 3;
  const rowLen = 1 + w * channels;
  const rowA = Buffer.alloc(rowLen);
  const rowB = Buffer.alloc(rowLen);
  for (let x = 0; x < w; x++) {
    const o = 1 + x * channels;
    rowA[o] = (x * 17) & 255;
    rowA[o + 1] = (x * 31) & 255;
    rowA[o + 2] = (x * 53) & 255;
    if (alpha) rowA[o + 3] = x < w / 2 ? 0 : 255;
    rowB[o] = (x * 43 + 90) & 255;
    rowB[o + 1] = (x * 19 + 40) & 255;
    rowB[o + 2] = (x * 7 + 120) & 255;
    if (alpha) rowB[o + 3] = 255;
  }
  const raw = Buffer.allocUnsafe(h * rowLen);
  for (let y = 0; y < h; y++) {
    const src = (y & 7) < 4 ? rowA : rowB;
    src.copy(raw, y * rowLen);
  }
  const chunk = (type: string, data: Buffer) => {
    const head = Buffer.alloc(8);
    head.writeUInt32BE(data.length, 0);
    head.write(type, 4, "latin1");
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])) >>> 0, 0);
    return Buffer.concat([head, data, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = alpha ? 6 : 2;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

/// Extract the EXIF APP1 segment (orientation 6: 90 deg CW) from fixtures/photo-small.jpg and splice it after SOI.
function withOrientation6(jpeg: Buffer): Buffer {
  const sample = readFileSync(join(fixtures, "photo-small.jpg"));
  assert.equal(sample[0], 0xff);
  assert.equal(sample[1], 0xd8);
  let pos = 2;
  let app1: Buffer | null = null;
  while (pos + 4 <= sample.length && sample[pos] === 0xff) {
    const marker = sample[pos + 1]!;
    if (marker === 0xda) break;
    const len = sample.readUInt16BE(pos + 2);
    if (marker === 0xe1) {
      app1 = sample.subarray(pos, pos + 2 + len);
      break;
    }
    pos += 2 + len;
  }
  assert.ok(app1, "photo-small.jpg should contain EXIF APP1");
  return Buffer.concat([jpeg.subarray(0, 2), app1, jpeg.subarray(2)]);
}

test("preserves short side for extreme tall and wide thumbnails without upscaling", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "thumbs-extreme-"));
  try {
    const thumbs = join(tmp, "thumbs");
    const cases: Array<[string, number, number, [number, number]]> = [
      ["tall15.png", 500, 7500, [320, 4800]],
      ["tall30.png", 400, 12000, [273, 8192]],
      ["narrow.png", 200, 3000, [200, 3000]],
      ["wide15.png", 7500, 500, [4800, 320]],
      // Around 1.875 / 2.25 thresholds: below threshold fits 720x600; above preserves 320px short side.
      ["below-tall.png", 500, 900, [333, 600]],
      ["above-tall.png", 500, 1000, [320, 640]],
      ["at-wide.png", 1350, 600, [720, 320]],
      ["above-wide.png", 1500, 600, [800, 320]],
      // Ultra-thin 1x50000: width stays >= 1, height capped at 8192.
      ["thin.png", 1, 50000, [1, 8192]],
    ];
    for (const [name, w, h, want] of cases) {
      const src = join(tmp, name);
      writeFileSync(src, fastStripedPng(w, h));
      const made = await thumbnail(src, thumbs, codecs);
      assert.ok(made, `${name}: expected thumbnail`);
      assert.equal(made.type, "image/jpeg", name);
      assert.deepEqual(sizeOf(readFileSync(made.path)), want, name);
    }

    // Transparent tall PNG keeps alpha and emits image/png with 320px short side.
    const alphaSrc = join(tmp, "tall-alpha.png");
    writeFileSync(alphaSrc, fastStripedPng(500, 1500, true));
    const alphaMade = await thumbnail(alphaSrc, thumbs, codecs);
    assert.ok(alphaMade);
    assert.equal(alphaMade.type, "image/png");
    const alphaBytes = readFileSync(alphaMade.path);
    assert.equal(alphaBytes[25], 6);
    assert.deepEqual(sizeOf(alphaBytes), [320, 960]);

    // boxed=true strictly fits 720x600 (keeps link-preview inline thumbnails under 192 KiB),
    // and uses the `.b` cache suffix so default THUMB in the same directory is never poisoned.
    const boxedSrc = join(tmp, "tall-boxed.png");
    writeFileSync(boxedSrc, noisy(500, 1500));
    const sameDir = join(tmp, "shared-thumbs");
    const boxedMade = await thumbnail(boxedSrc, sameDir, codecs, undefined, true);
    assert.ok(boxedMade);
    assert.equal(boxedMade.type, "image/jpeg");
    const boxedBytes = readFileSync(boxedMade.path);
    assert.deepEqual(sizeOf(boxedBytes), [200, 600]);
    assert.ok(boxedBytes.length < 192 * 1024, `boxed tall.png should stay under 192 KiB, got ${boxedBytes.length}`);
    const unboxedMade = await thumbnail(boxedSrc, sameDir, codecs);
    assert.ok(unboxedMade);
    assert.equal(unboxedMade.type, "image/jpeg");
    assert.notEqual(unboxedMade.path, boxedMade.path, "boxed and default thumbnails must use distinct cache paths");
    assert.deepEqual(sizeOf(readFileSync(unboxedMade.path)), [320, 960]);

    // EXIF-rotated tall JPEG (stored 1800x600 with orientation 6 -> seen as 600x1800 -> thumbnail 320x960).
    const rawWide = join(tmp, "raw-wide.png");
    writeFileSync(rawWide, png(1800, 600, (x, y) => [(x >> 3) + (y & 7), (y >> 2) + (x & 7), ((x * y) >> 10) & 255], 0));
    const baseJpegMade = await preview(rawWide, join(tmp, "rot-base"), codecs);
    assert.ok(baseJpegMade && baseJpegMade.type === "image/jpeg");
    const rotSrc = join(tmp, "exif-tall.jpg");
    const rotBytes = withOrientation6(readFileSync(baseJpegMade.path));
    writeFileSync(rotSrc, Buffer.concat([rotBytes, Buffer.alloc(200 * 1024)]));
    const rotMade = await thumbnail(rotSrc, thumbs, codecs);
    assert.ok(rotMade, "EXIF-rotated tall JPEG should produce thumbnail");
    assert.equal(rotMade.type, "image/jpeg");
    assert.deepEqual(sizeOf(readFileSync(rotMade.path)), [320, 960]);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
