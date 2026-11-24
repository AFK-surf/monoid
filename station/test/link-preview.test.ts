// A web link's preview (src/links/preview.ts): what a page's head says, and which addresses are fetched at all.
import assert from "node:assert/strict";
import http, { createServer } from "node:http";
import { syncBuiltinESMExports } from "node:module";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import { brotliCompressSync, crc32, deflateSync } from "node:zlib";
import { bodyUpTo, getAt, headOf, htmlText, inlinePicture, isPublic, linkPreview, oembedOf } from "../src/links/preview.ts";

test("a page's head: og first, else its title; its icon, else /favicon.ico", () => {
  const base = new URL("https://ex.am/docs/page");
  const html = `<html><head><title>Plain &amp; simple</title><meta property="og:title" content="The &quot;real&quot; title">
    <meta name=description content='What it is'><meta property="og:site_name" content="Example"><link rel="icon" href="/i.png"></head><body><title>no</title></body>`;
  assert.deepEqual(headOf(html, base), { title: 'The "real" title', description: "What it is", site: "Example", icon: "https://ex.am/i.png" });
  assert.deepEqual(headOf("<title> A&#x26;B  &#169; </title>", base), { title: "A&B ©", icon: "https://ex.am/favicon.ico" });
  assert.equal(htmlText("a&nbsp;b &bogus; c"), "a b &bogus; c");
});

test("a page's picture: og:image (its &amp; read), else twitter:image, by the page's address; only a web one", () => {
  const base = new URL("https://ex.am/docs/page");
  const og = `<head><title>T</title><meta property="og:image" content="https://cdn.ex.am/p.jpg?a=1&amp;b=2"><meta name="twitter:image" content="/t.png"></head>`;
  assert.equal(headOf(og, base).image, "https://cdn.ex.am/p.jpg?a=1&b=2");
  assert.equal(headOf(`<title>T</title><meta name="twitter:image" content="../t.png">`, base).image, "https://ex.am/t.png");
  assert.equal(headOf(`<title>T</title><meta property="og:image" content="javascript:alert(1)">`, base).image, undefined);
  assert.equal(headOf(`<head><title>T</title></head><meta property="og:image" content="/after.png">`, base).image, undefined);
});

test("a video link is asked of its site's oEmbed; any other is not", () => {
  const of = (s: string) => oembedOf(new URL(s));
  for (const s of ["https://www.youtube.com/watch?v=7YiXO6twfXk", "https://m.youtube.com/watch?v=x", "https://youtu.be/7YiXO6twfXk", "https://www.youtube.com/shorts/abc"]) {
    assert.equal(of(s), `https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(s)}`, s);
  }
  assert.equal(of("https://vimeo.com/76979871"), `https://vimeo.com/api/oembed.json?url=${encodeURIComponent("https://vimeo.com/76979871")}`);
  for (const s of ["https://www.youtube.com/", "https://www.youtube.com/@channel", "https://youtu.be/", "https://vimeo.com/about", "https://notyoutube.com/watch?v=x"]) assert.equal(of(s), null, s);
});

test("a page is read up to its head's end, even when the tag is cut between chunks", async () => {
  const chunks = ["<html><head><title>T</title></he", "ad><body>", "x".repeat(1000)];
  let pulled = 0;
  const body = new ReadableStream<Uint8Array>({
    pull(c) {
      if (pulled < chunks.length) c.enqueue(new TextEncoder().encode(chunks[pulled++]!));
      else c.close();
    },
  });
  const read = (await bodyUpTo(new Response(body), 1 << 20, /<\/head>/i)).toString("utf8");
  assert.equal(read, chunks[0]! + chunks[1]!);
});

test("only the internet's addresses are fetched", async () => {
  for (const a of ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.20.0.1", "169.254.1.1", "100.64.0.1", "0.0.0.0", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1"]) assert.equal(isPublic(a), false, a);
  for (const a of ["1.1.1.1", "140.82.112.3", "2606:4700::1111"]) assert.equal(isPublic(a), true, a);
  assert.equal(await linkPreview("http://127.0.0.1:1/"), null);
  assert.equal(await linkPreview("http://localhost:1/x"), null);
  assert.equal(await linkPreview("file:///etc/passwd"), null);
});

test("mapped IPv4 addresses keep their public-address decision in every IPv6 spelling and after URL parsing", () => {
  const privateAddresses = ["0.0.0.0", "10.1.2.3", "127.0.0.1", "100.64.0.1", "100.127.255.255", "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "224.0.0.1", "255.255.255.255"];
  const publicAddresses = ["1.1.1.1", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1", "192.169.1.1", "223.255.255.255"];
  for (const [addresses, allowed] of [[privateAddresses, false], [publicAddresses, true]] as const) {
    for (const address of addresses) {
      const bytes = address.split(".").map(Number);
      const high = ((bytes[0]! << 8) | bytes[1]!).toString(16);
      const low = ((bytes[2]! << 8) | bytes[3]!).toString(16);
      for (const mapped of [`::ffff:${address}`, `::ffff:${high}:${low}`, `::FFFF:${high.toUpperCase()}:${low.toUpperCase()}`, `0:0:0:0:0:ffff:${high.padStart(4, "0")}:${low.padStart(4, "0")}`, `0:0::ffff:${address}`]) {
        assert.equal(isPublic(mapped), allowed, mapped);
        // fetchPublic receives URL's canonical hostname, including when the link was written with dotted IPv4.
        const host = new URL(`http://[${mapped}]/`).hostname.slice(1, -1);
        assert.equal(isPublic(host), allowed, `${mapped} parsed as ${host}`);
      }
    }
  }
  for (const address of ["0:0:0:0:0:0:0:1", "0:0:0:0:0:0:0:0", "::1%lo0", "not-an-address"]) assert.equal(isPublic(address), false, address);
  assert.equal(isPublic("::ffff:0:0:1"), true, "an IPv6 address outside the mapped /96 is not an IPv4 address");
});

test("mapped local links are refused before opening a connection", async (t) => {
  let asked = 0;
  const request = t.mock.method(http, "request", () => {
    asked++;
    throw new Error("test transport: no network request is made");
  });
  syncBuiltinESMExports();
  try {
    for (const address of ["::ffff:127.0.0.1", "::ffff:7f00:1", "0:0:0:0:0:FFFF:7F00:0001", "::ffff:192.168.1.1"]) {
      assert.equal(await linkPreview(`http://[${address}]/private`), null, address);
    }
    assert.equal(asked, 0, "a private mapped address must not reach the HTTP transport");
  } finally {
    request.mock.restore();
    syncBuiltinESMExports();
  }
});

test("a page's body is read as sent, from the address checked; one in any encoding is not read (no decoder reached)", async () => {
  const asked: { name?: string; encoding?: string }[] = [];
  const server = createServer((req, res) => {
    asked.push({ name: req.headers.host, encoding: req.headers["accept-encoding"] });
    if (req.url === "/br") res.writeHead(200, { "content-type": "text/html", "content-encoding": "br" }).end(brotliCompressSync("<title>T</title>"));
    else if (req.url === "/moved") res.writeHead(302, { location: "/plain" }).end();
    else res.writeHead(200, { "content-type": "text/html", "set-cookie": ["a=1", "b=2"] }).end("<title>T</title>");
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const { port } = server.address() as AddressInfo;
  try {
    // A name nothing resolves: the addresses given are the ones tried (nothing listens on ::1).
    const at = (path: string) => getAt(new URL(`http://page.invalid:${port}${path}`), ["::1", "127.0.0.1"], "text/html");
    const plain = await at("/plain");
    assert.equal(plain?.status, 200);
    assert.equal(plain?.url, `http://page.invalid:${port}/plain`);
    assert.equal(plain?.headers.get("set-cookie"), "a=1, b=2");
    assert.equal((await bodyUpTo(plain!, 1024)).toString("utf8"), "<title>T</title>");
    assert.equal(await at("/br"), null);
    const moved = await at("/moved");
    assert.equal(moved?.status, 302);
    assert.equal(moved?.headers.get("location"), "/plain");
    await moved?.body?.cancel();
    assert.deepEqual(asked, Array(3).fill({ name: `page.invalid:${port}`, encoding: "identity" }));
  } finally {
    server.close();
    server.closeAllConnections();
  }
});

test("inlinePicture boxes tall images so link-preview thumbnails stay within 192 KiB", async () => {
  // 500x2000 noisy PNG: unboxed 320x1280 JPEG exceeds 192 KiB, while boxed 150x600 stays well under 192 KiB.
  const w = 500;
  const h = 2000;
  const rowLen = 1 + w * 3;
  const raw = Buffer.allocUnsafe(h * rowLen);
  let state = 0x12345678;
  for (let y = 0; y < h; y++) {
    const base = y * rowLen;
    raw[base] = 0;
    for (let x = 0; x < w; x++) {
      state ^= state << 13;
      state ^= state >>> 17;
      state ^= state << 5;
      const o = base + 1 + x * 3;
      raw[o] = state & 255;
      raw[o + 1] = (state >>> 8) & 255;
      raw[o + 2] = (state >>> 16) & 255;
    }
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
  ihdr[9] = 2;
  const bytes = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 0 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  assert.ok(bytes.length > 192 * 1024);

  const url = await inlinePicture({ type: "image/png", bytes });
  assert.ok(url !== null, "expected inlinePicture to box tall image instead of dropping it");
  assert.ok(url.startsWith("data:image/jpeg;base64,"), `expected JPEG data URL, got ${url.slice(0, 40)}`);
  const decoded = Buffer.from(url.slice("data:image/jpeg;base64,".length), "base64");
  assert.ok(decoded.length > 0 && decoded.length <= 192 * 1024, `expected <= 192 KiB, got ${decoded.length}`);
});
