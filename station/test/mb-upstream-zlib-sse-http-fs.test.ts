// Upstream official test suites cross-checked live against MoonBit implementations:
// 1. WPT `eventsource/format-*.htm` parsing vectors → `libs/base/src/wire/sse.mbt` vs `client/core-ts/src/sse.ts`
// 2. `nodejs/node` `test/parallel/test-zlib-*.js` matrix → `libs/base/src/flate` vs real `node:zlib`
// 3. `nodejs/node` `test-http-parser-*` boundary matrix → `station/mb/src/station_main/http.mbt` (real TCP)
// 4. `nodejs/node` `test-fs-*` boundary & errno matrix → `station/mb/src/station_main/live_dispatch.mbt` vs real `node:fs`
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import fsp from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createInterface } from "node:readline";
import { after, describe, it } from "node:test";
import zlib from "node:zlib";
import { SseParser } from "../../client/core-ts/src/sse.ts";
import { harnessBinary, noHarness } from "./mb-harness.ts";

class UpstreamHarness {
  readonly #proc;
  readonly #rl;
  readonly #pending = new Map<number, (v: unknown) => void>();
  #nextId = 1;

  constructor() {
    this.#proc = spawn(harnessBinary(), ["--builder", "harness-upstream"], {
      stdio: ["pipe", "pipe", "inherit"],
    });
    this.#rl = createInterface({ input: this.#proc.stdout });
    this.#rl.on("line", (line) => {
      const msg = JSON.parse(line) as { id: number; value: unknown };
      const resolve = this.#pending.get(msg.id);
      if (resolve) {
        this.#pending.delete(msg.id);
        resolve(msg.value);
      }
    });
  }

  ask<T>(req: Record<string, unknown>): Promise<T> {
    const id = this.#nextId++;
    return new Promise((resolve) => {
      this.#pending.set(id, resolve as (v: unknown) => void);
      this.#proc.stdin.write(`${JSON.stringify({ id, ...req })}\n`);
    });
  }

  close(): void {
    this.#rl.close();
    this.#proc.stdin.end();
    this.#proc.kill();
  }
}

function sendRawHttp(port: number, raw: Buffer | Buffer[]): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const sock = net.connect(port, "127.0.0.1");
    const chunks: Buffer[] = [];
    sock.on("data", (d) => chunks.push(d));
    sock.on("end", () => resolve(Buffer.concat(chunks)));
    sock.on("close", () => resolve(Buffer.concat(chunks)));
    sock.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ECONNRESET" || err.code === "EPIPE") resolve(Buffer.concat(chunks));
      else reject(err);
    });
    sock.on("connect", () => {
      if (Array.isArray(raw)) {
        let i = 0;
        const next = () => {
          if (i >= raw.length) return;
          sock.write(raw[i++]!, () => setImmediate(next));
        };
        next();
      } else {
        sock.write(raw);
      }
    });
  });
}

function prngBuf(len: number, seed: number): Buffer {
  const out = Buffer.allocUnsafe(len);
  let s = seed >>> 0;
  for (let i = 0; i < len; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    out[i] = (s >>> 16) & 0xff;
  }
  return out;
}

describe("MoonBit upstream suites: WPT SSE, Node zlib, Node http-parser, Node fs", { skip: noHarness() }, () => {
  let h: UpstreamHarness | null = null;
  const harness = () => (h ??= new UpstreamHarness());
  after(() => h?.close());

  it("1. WPT eventsource/format-*.htm full parsing vectors vs client/core-ts/src/sse.ts", async () => {
    type SseEvent = { name: string; data: string; id: string | null };
    const vectors: { name: string; raw: Buffer; note?: string }[] = [
      { name: "format-bom", raw: Buffer.from("\uFEFFdata:1\n\ndata:2\n\ndata:3\n\n", "utf8") },
      { name: "format-bom-2 (double BOM)", raw: Buffer.from("\uFEFF\uFEFFdata:1\n\ndata:2\n\ndata:3\n\n", "utf8") },
      { name: "format-comments", raw: Buffer.from(`data:1\n:${"x".repeat(2050)}\n:comment\ndata:2\n\n:only\n\ndata:3\n\n`, "utf8") },
      { name: "format-data-before-final-empty-line", raw: Buffer.from("retry:1000\ndata:test1\n\nid:test\ndata:test2", "utf8") },
      { name: "format-field-data (empty + colon-less + multi-line)", raw: Buffer.from("data:\n\ndata\ndata\n\ndata:test\n\ndata: a:b:c\n\ndata: 1\ndata:\ndata: 3\n\n", "utf8") },
      { name: "format-field-event", raw: Buffer.from("event: test\ndata: x\n\ndata: y\n\n", "utf8") },
      { name: "format-field-event-empty", raw: Buffer.from("event: \ndata: data\n\nevent:\ndata: data2\n\n", "utf8") },
      { name: "format-field-id & id-only cursor", raw: Buffer.from("id: 1\ndata: one\n\ndata: two\n\nid: cursor-99\n\nid:\n\n", "utf8") },
      { name: "format-field-id-null (core-ts subset keeps NUL)", raw: Buffer.from("id: a\0b\ndata: ok\n\n", "utf8") },
      { name: "format-field-parsing & case-sensitivity", raw: Buffer.from("DATA: upper\nEvent: cap\nID: 9\n data: leading\nfoo: bar\ndata: kept\n\n", "utf8") },
      { name: "format-field-retry & bogus & empty", raw: Buffer.from("retry: 300\nretry: 1000x\nretry:\ndata: after-retry\n\n", "utf8") },
      { name: "format-leading-space (single U+0020 rule)", raw: Buffer.from("data:\t\ndata: \ndata:  \ndata:   abc\ndata:\tdef\n\n", "utf8") },
      { name: "format-newlines (LF, CRLF, mixed, bare CR stripped per core-ts)", raw: Buffer.from("data: test\r\n\r\ndata: test2\n\ndata: test3\r\n\ndata: a\rb\n\n", "utf8") },
      { name: "format-null-character", raw: Buffer.from("data: a\0b\n\n", "utf8") },
      { name: "format-utf-8 (BMP + CJK + astral emoji)", raw: Buffer.from("event: café\nid: 编号-1\ndata: 你好 🚀\ndata: 世界\n\n", "utf8") },
      { name: "format-utf-8-invalid-lossy", raw: Buffer.concat([Buffer.from("data: a"), Buffer.from([0x80, 0xc0, 0xfe, 0xff]), Buffer.from("b\n\n")]) },
      { name: "empty-blocks-and-repeated-overrides", raw: Buffer.from("\n\n\nevent: a\nevent:  b \t\nid: 1\nid:  2 \ndata: v\n\n\n", "utf8") },
    ];

    for (const v of vectors) {
      // One-shot parity
      const tsOne = new SseParser().feed(v.raw).map(([name, data, id]) => ({ name, data, id: id ?? null }));
      const mbOne = await harness().ask<{ events: SseEvent[]; tooLong: boolean }>({
        op: "sse.feed",
        hex: v.raw.toString("hex"),
      });
      assert.equal(mbOne.tooLong, false, `${v.name}: unexpected tooLong`);
      assert.deepEqual(mbOne.events, tsOne, `${v.name}: one-shot mismatch vs core-ts SseParser`);

      // Chunked parity (1-byte splits for short vectors, 3-byte splits for long)
      const step = v.raw.length > 512 ? 37 : 1;
      const chunks: Buffer[] = [];
      for (let i = 0; i < v.raw.length; i += step) chunks.push(v.raw.subarray(i, Math.min(i + step, v.raw.length)));
      const tsParser = new SseParser();
      const tsChunked: SseEvent[] = [];
      for (const ch of chunks) {
        for (const [name, data, id] of tsParser.feed(ch)) tsChunked.push({ name, data, id: id ?? null });
      }
      const mbChunked = await harness().ask<{ events: SseEvent[]; tooLong: boolean }>({
        op: "sse.feed",
        chunks_hex: chunks.map((c) => c.toString("hex")),
      });
      assert.equal(mbChunked.tooLong, false, `${v.name}: chunked unexpected tooLong`);
      assert.deepEqual(mbChunked.events, tsChunked, `${v.name}: chunked mismatch vs core-ts SseParser`);
    }

    // Intentional MoonBit safety bound (`TooLong`) beyond unbounded core-ts
    const mbBound = await harness().ask<{ events: SseEvent[]; tooLong: boolean }>({
      op: "sse.feed",
      most: 12,
      chunks_hex: [Buffer.from("data: ok\n\ndata: 0123456789abcdef\n\n").toString("hex"), Buffer.from("data: x\n\n").toString("hex")],
    });
    assert.equal(mbBound.tooLong, true);
    assert.deepEqual(mbBound.events, [{ name: "message", data: "ok", id: null }]);
  });

  it("2. nodejs/node test-zlib-*.js full matrix vs real node:zlib (raw deflate, zlib, gzip)", async () => {
    const payloads: { name: string; buf: Buffer }[] = [
      { name: "empty", buf: Buffer.alloc(0) },
      { name: "single-zero", buf: Buffer.from([0]) },
      { name: "single-ff", buf: Buffer.from([0xff]) },
      { name: "all-256-bytes", buf: Buffer.from(Array.from({ length: 256 }, (_, i) => i)) },
      { name: "highly-repetitive-rle-128k", buf: Buffer.alloc(131072, 0x41) },
      { name: "incompressible-140k-multi-stored", buf: prngBuf(140000, 0xdeadbeef) },
      { name: "mixed-32k-window-boundary", buf: Buffer.concat([Buffer.from("MARKER-64-".repeat(8)), prngBuf(32768 - 80, 0x12345678), Buffer.from("MARKER-64-".repeat(8))]) },
      { name: "json-corpus", buf: Buffer.from(JSON.stringify({ items: Array.from({ length: 400 }, (_, i) => ({ id: i, text: `line-${i % 17}` })) })) },
    ];

    // Bidirectional interop across all 3 formats
    for (const p of payloads) {
      const hex = p.buf.toString("hex");
      // MB -> Node
      const mbRaw = Buffer.from(await harness().ask<string>({ op: "flate.deflate", hex }), "hex");
      assert.deepEqual(zlib.inflateRawSync(mbRaw), p.buf, `${p.name}: MB deflate -> Node inflateRawSync`);
      const mbZ = Buffer.from(await harness().ask<string>({ op: "flate.zlib_compress", hex }), "hex");
      assert.deepEqual(zlib.inflateSync(mbZ), p.buf, `${p.name}: MB zlib -> Node inflateSync`);
      const mbGz = Buffer.from(await harness().ask<string>({ op: "flate.gzip", hex }), "hex");
      assert.deepEqual(zlib.gunzipSync(mbGz), p.buf, `${p.name}: MB gzip -> Node gunzipSync`);

      // Node -> MB
      const nodeRaw = zlib.deflateRawSync(p.buf);
      const mbInf = await harness().ask<string | null>({ op: "flate.inflate", hex: nodeRaw.toString("hex") });
      assert.equal(mbInf, hex, `${p.name}: Node deflateRawSync -> MB inflate`);

      const nodeZ = zlib.deflateSync(p.buf);
      const mbZDec = await harness().ask<string | null>({ op: "flate.zlib_decompress", hex: nodeZ.toString("hex") });
      assert.equal(mbZDec, hex, `${p.name}: Node deflateSync -> MB zlib_decompress`);

      const nodeGz = zlib.gzipSync(p.buf);
      const mbGzDec = await harness().ask<string | null>({ op: "flate.gunzip", hex: nodeGz.toString("hex") });
      assert.equal(mbGzDec, hex, `${p.name}: Node gzipSync -> MB gunzip`);
    }

    // All Node zlib levels (0..9) and strategies (exercises stored, fixed Huffman, dynamic Huffman, RLE)
    const sample = Buffer.from("The quick brown fox jumps over the lazy dog. ".repeat(120) + prngBuf(4096, 0x42).toString("latin1"), "latin1");
    for (const level of [0, 1, 3, 6, 9]) {
      for (const strategy of [
        zlib.constants.Z_DEFAULT_STRATEGY,
        zlib.constants.Z_FILTERED,
        zlib.constants.Z_HUFFMAN_ONLY,
        zlib.constants.Z_RLE,
        zlib.constants.Z_FIXED,
      ]) {
        const zBuf = zlib.deflateSync(sample, { level, strategy });
        const dec = await harness().ask<string | null>({ op: "flate.zlib_decompress", hex: zBuf.toString("hex") });
        assert.equal(dec, sample.toString("hex"), `Node level=${level} strategy=${strategy} -> MB zlib_decompress`);
      }
    }

    // Streaming multi-flush Deflater -> Node inflateRawSync
    const streamChunks = [
      Buffer.alloc(0),
      Buffer.from("header-"),
      Buffer.alloc(8192, 0x62),
      prngBuf(70000, 0x7777),
      Buffer.from("header-").subarray(0),
      Buffer.from("repeat-".repeat(300)),
    ];
    const mbStreamRaw = Buffer.from(
      await harness().ask<string>({ op: "flate.deflate_stream", chunks_hex: streamChunks.map((c) => c.toString("hex")) }),
      "hex",
    );
    assert.deepEqual(zlib.inflateRawSync(mbStreamRaw), Buffer.concat(streamChunks), "MB Deflater multi-flush -> Node inflateRawSync");

    // Concatenated gzip streams + zero padding vs trailing garbage
    const catGz = Buffer.concat([zlib.gzipSync(Buffer.from("alpha-")), zlib.gzipSync(Buffer.alloc(0)), zlib.gzipSync(Buffer.from("omega")), Buffer.alloc(8, 0)]);
    const catDec = await harness().ask<string | null>({ op: "flate.gunzip", hex: catGz.toString("hex") });
    assert.equal(catDec, Buffer.from("alpha-omega").toString("hex"));

    const trailingGarbage = Buffer.concat([zlib.gzipSync(Buffer.from("alpha")), Buffer.from("JUNK")]);
    assert.equal(await harness().ask<string | null>({ op: "flate.gunzip", hex: trailingGarbage.toString("hex") }), null);

    // Truncation and corruption (bad Adler32, bad FCHECK, bad CRC32, bad ISIZE)
    const validZ = zlib.deflateSync(Buffer.from("checksum-verify-payload"));
    for (const cut of [0, 1, 2, Math.floor(validZ.length / 2), validZ.length - 1]) {
      assert.equal(await harness().ask<string | null>({ op: "flate.zlib_decompress", hex: validZ.subarray(0, cut).toString("hex") }), null);
    }
    const badAdler = Buffer.from(validZ);
    badAdler[badAdler.length - 1]! ^= 0x01;
    assert.equal(await harness().ask<string | null>({ op: "flate.zlib_decompress", hex: badAdler.toString("hex") }), null);
    const badFcheck = Buffer.from(validZ);
    badFcheck[1]! ^= 0x01;
    assert.equal(await harness().ask<string | null>({ op: "flate.zlib_decompress", hex: badFcheck.toString("hex") }), null);

    const validGz = zlib.gzipSync(Buffer.from("gzip-checksum-verify"));
    const badCrc = Buffer.from(validGz);
    badCrc[badCrc.length - 6]! ^= 0x80;
    assert.equal(await harness().ask<string | null>({ op: "flate.gunzip", hex: badCrc.toString("hex") }), null);
    const badIsize = Buffer.from(validGz);
    badIsize[badIsize.length - 1]! ^= 0x01;
    assert.equal(await harness().ask<string | null>({ op: "flate.gunzip", hex: badIsize.toString("hex") }), null);
  });

  it("3. nodejs/node test-http-parser-* boundary matrix against station_main/http.mbt (real TCP)", async () => {
    const { port } = await harness().ask<{ port: number }>({ op: "http.serve_start" });
    assert.ok(port > 0, `expected valid port, got ${port}`);

    // Valid HTTP/1.1 & HTTP/1.0 requests (including chunked TCP delivery, binary body, mixed-case headers)
    const body = Buffer.from("hello-http-body-123");
    const okRes = await sendRawHttp(port, [
      Buffer.from("POST /echo?a=1&b=2 HTTP/1.1\r\nHost: 127.0.0.1\r\n"),
      Buffer.from(`X-Custom-Header:  val-with-spaces  \r\nContent-Length: ${body.length}\r\n\r\n`),
      body.subarray(0, 7),
      body.subarray(7),
    ]);
    const okStr = okRes.toString("utf8");
    assert.ok(okStr.startsWith("HTTP/1.1 200 OK\r\n"), `expected 200 OK, got: ${okStr}`);
    const parsed = JSON.parse(okStr.slice(okStr.indexOf("\r\n\r\n") + 4)) as {
      method: string;
      target: string;
      headers: [string, string][];
      bodyLen: number;
      bodyText: string;
    };
    assert.equal(parsed.method, "POST");
    assert.equal(parsed.target, "/echo?a=1&b=2");
    assert.equal(parsed.bodyLen, body.length);
    assert.equal(parsed.bodyText, body.toString("utf8"));
    assert.deepEqual(parsed.headers.find(([k]) => k === "x-custom-header"), ["x-custom-header", "val-with-spaces"]);

    // Valid HTTP/1.0
    const ok10 = (await sendRawHttp(port, Buffer.from("GET /health HTTP/1.0\r\nHost: localhost\r\n\r\n"))).toString("utf8");
    assert.ok(ok10.startsWith("HTTP/1.1 200 OK\r\n"), `expected HTTP/1.0 accepted, got: ${ok10}`);

    // Upstream test-http-parser-* malformed / smuggling vectors: server must reject (close with empty response)
    const invalidRequests: { name: string; raw: Buffer }[] = [
      { name: "missing HTTP version", raw: Buffer.from("GET /health\r\nHost: localhost\r\n\r\n") },
      { name: "extra token on request line", raw: Buffer.from("GET /health HTTP/1.1 EXTRA\r\nHost: localhost\r\n\r\n") },
      { name: "invalid HTTP version 9.9", raw: Buffer.from("GET /health HTTP/9.9\r\nHost: localhost\r\n\r\n") },
      { name: "invalid HTTP version 1.2", raw: Buffer.from("GET /health HTTP/1.2\r\nHost: localhost\r\n\r\n") },
      { name: "invalid method with space/tab", raw: Buffer.from("G\tT /health HTTP/1.1\r\nHost: localhost\r\n\r\n") },
      { name: "invalid method with delimiter", raw: Buffer.from("GET(1) /health HTTP/1.1\r\nHost: localhost\r\n\r\n") },
      { name: "header name whitespace before colon (RFC 9112 §5.1)", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length : 4\r\n\r\ntest") },
      { name: "header name internal whitespace", raw: Buffer.from("GET /health HTTP/1.1\r\nBad Header: 1\r\n\r\n") },
      { name: "obs-fold continuation line", raw: Buffer.from("GET /health HTTP/1.1\r\nX-Foo: a\r\n b\r\n\r\n") },
      { name: "empty header name", raw: Buffer.from("GET /health HTTP/1.1\r\n: val\r\n\r\n") },
      { name: "header line without colon", raw: Buffer.from("GET /health HTTP/1.1\r\nMalformedHeaderLine\r\n\r\n") },
      { name: "duplicate Content-Length (same value)", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\ntest") },
      { name: "duplicate Content-Length (smuggling diff values)", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length: 4\r\nContent-Length: 8\r\n\r\ntesttest") },
      { name: "Transfer-Encoding chunked rejected", raw: Buffer.from("POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntest\r\n0\r\n\r\n") },
      { name: "Transfer-Encoding + Content-Length smuggling", raw: Buffer.from("POST /echo HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\ntest") },
      { name: "malformed chunked / bad TE", raw: Buffer.from("POST /echo HTTP/1.1\r\nTransfer-Encoding: bogus\r\n\r\n") },
      { name: "non-numeric Content-Length", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length: 12abc\r\n\r\n") },
      { name: "negative Content-Length", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length: -1\r\n\r\n") },
      { name: "empty Content-Length", raw: Buffer.from("POST /echo HTTP/1.1\r\nContent-Length: \r\n\r\n") },
      { name: "bare LF inside head", raw: Buffer.from("GET /health HTTP/1.1\nHost: localhost\r\n\r\n") },
      { name: "NUL byte in header value", raw: Buffer.from("GET /health HTTP/1.1\r\nX-Nul: a\x00b\r\n\r\n") },
      { name: "oversized header (>64 KiB)", raw: Buffer.from(`GET /health HTTP/1.1\r\nX-Big: ${"a".repeat(70000)}\r\n\r\n`) },
    ];

    for (const inv of invalidRequests) {
      const res = await sendRawHttp(port, inv.raw);
      assert.equal(res.length, 0, `${inv.name}: expected rejection (empty close), got: ${res.toString("utf8").slice(0, 120)}`);
    }

    // Server must remain healthy after all malformed requests
    const afterRes = (await sendRawHttp(port, Buffer.from("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"))).toString("utf8");
    assert.ok(afterRes.startsWith("HTTP/1.1 200 OK\r\n"), `server unhealthy after malformed requests: ${afterRes}`);
  });

  it("4. nodejs/node test-fs-* boundary & errno matrix against station_main/live_dispatch.mbt vs real node:fs", async () => {
    type FsRes = { ok: true; value: unknown } | { ok: false; code: string; message: string };
    const fsOp = (fs_op: string, args: unknown[], extra?: { strict_rm?: boolean }) =>
      harness().ask<FsRes>({ op: "fs.op", fs_op, args, ...extra });

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mb-upstream-fs-"));
    try {
      const fileA = path.join(tmp, "a.txt");
      const dirB = path.join(tmp, "dirB");
      const missing = path.join(tmp, "does-not-exist");

      // writeFile + readFile + appendFile + sha256 + readHead
      assert.equal((await fsOp("writeFile", [fileA, "hello"])).ok, true);
      assert.equal((await fsOp("appendFile", [fileA, "-world"])).ok, true);
      const readRes = await fsOp("readFile", [fileA]);
      assert.deepEqual(readRes, { ok: true, value: "hello-world" });
      assert.equal(fs.readFileSync(fileA, "utf8"), "hello-world");

      const shaRes = await fsOp("sha256", [fileA]);
      assert.deepEqual(shaRes, { ok: true, value: crypto.createHash("sha256").update("hello-world").digest("hex") });

      const headRes = await fsOp("readHead", [fileA, 5, 5]);
      assert.deepEqual(headRes, { ok: true, value: { text: "hello", got: 5 } });

      // writeFile with flag "wx" on existing file -> EEXIST (matches node:fs)
      let nodeWxCode = "";
      try {
        await fsp.writeFile(fileA, "dup", { flag: "wx" });
      } catch (e) {
        nodeWxCode = (e as NodeJS.ErrnoException).code ?? "";
      }
      const mbWx = await fsOp("writeFile", [fileA, "dup", { flag: "wx" }]);
      assert.equal(mbWx.ok, false);
      assert.equal(!mbWx.ok && mbWx.code, nodeWxCode);
      assert.equal(nodeWxCode, "EEXIST");

      // readFile on missing -> ENOENT; readFile on directory -> EISDIR
      await fsp.mkdir(dirB);
      for (const [label, target, expectedCode] of [
        ["readFile missing", missing, "ENOENT"],
        ["readFile dir", dirB, "EISDIR"],
      ] as const) {
        let nodeCode = "";
        try {
          await fsp.readFile(target, "utf8");
        } catch (e) {
          nodeCode = (e as NodeJS.ErrnoException).code ?? "";
        }
        const mb = await fsOp("readFile", [target]);
        assert.equal(mb.ok, false, `${label}: expected error`);
        assert.equal(nodeCode, expectedCode);
        assert.equal(!mb.ok && mb.code, nodeCode, `${label}: errno mismatch`);
      }

      // readdir on file -> ENOTDIR; readdir on missing -> ENOENT
      for (const [label, target, expectedCode] of [
        ["readdir file", fileA, "ENOTDIR"],
        ["readdir missing", missing, "ENOENT"],
      ] as const) {
        let nodeCode = "";
        try {
          await fsp.readdir(target);
        } catch (e) {
          nodeCode = (e as NodeJS.ErrnoException).code ?? "";
        }
        const mb = await fsOp("readdir", [target]);
        assert.equal(mb.ok, false, `${label}: expected error`);
        assert.equal(nodeCode, expectedCode);
        assert.equal(!mb.ok && mb.code, nodeCode, `${label}: errno mismatch`);
      }

      // symlink: valid, EEXIST on existing path, ENOENT on missing parent (regression check!)
      const linkOk = path.join(tmp, "link-a");
      assert.equal((await fsOp("symlink", [fileA, linkOk])).ok, true);
      const linkDup = await fsOp("symlink", [fileA, linkOk]);
      assert.equal(linkDup.ok, false);
      assert.equal(!linkDup.ok && linkDup.code, "EEXIST");

      const linkBadParent = path.join(tmp, "no-such-dir", "link");
      let nodeSymlinkErr = "";
      try {
        await fsp.symlink(fileA, linkBadParent);
      } catch (e) {
        nodeSymlinkErr = (e as NodeJS.ErrnoException).code ?? "";
      }
      const mbSymlinkErr = await fsOp("symlink", [fileA, linkBadParent]);
      assert.equal(mbSymlinkErr.ok, false);
      assert.equal(nodeSymlinkErr, "ENOENT");
      assert.equal(!mbSymlinkErr.ok && mbSymlinkErr.code, nodeSymlinkErr, "symlink missing parent must return ENOENT, not EEXIST");

      // Dangling symlink: lstat succeeds (isSymbolicLink: true), stat fails with ENOENT
      const dangling = path.join(tmp, "dangling");
      assert.equal((await fsOp("symlink", [missing, dangling])).ok, true);
      const lstatD = await fsOp("lstat", [dangling]);
      assert.equal(lstatD.ok, true);
      assert.equal((lstatD.ok && (lstatD.value as { isSymbolicLink: boolean }).isSymbolicLink), true);
      const statD = await fsOp("stat", [dangling]);
      assert.equal(statD.ok, false);
      assert.equal(!statD.ok && statD.code, "ENOENT");

      // Symlink loop -> realpath fails with ELOOP (matches node:fs)
      const loopA = path.join(tmp, "loopA");
      const loopB = path.join(tmp, "loopB");
      await fsp.symlink(loopB, loopA);
      await fsp.symlink(loopA, loopB);
      let nodeLoopCode = "";
      try {
        await fsp.realpath(loopA);
      } catch (e) {
        nodeLoopCode = (e as NodeJS.ErrnoException).code ?? "";
      }
      const mbLoop = await fsOp("realpath", [loopA]);
      assert.equal(mbLoop.ok, false);
      assert.equal(nodeLoopCode, "ELOOP");
      assert.equal(!mbLoop.ok && mbLoop.code, nodeLoopCode);

      // copyFile with COPYFILE_EXCL (1) on existing target -> EEXIST
      const copyDst = path.join(tmp, "copy.txt");
      assert.equal((await fsOp("copyFile", [fileA, copyDst, 1])).ok, true);
      const copyAgain = await fsOp("copyFile", [fileA, copyDst, 1]);
      assert.equal(copyAgain.ok, false);
      assert.equal(!copyAgain.ok && copyAgain.code, "EEXIST");

      // rm strict_rm=true without force -> ENOENT; with force: true -> ok
      const rmMissing = await fsOp("rm", [missing], { strict_rm: true });
      assert.equal(rmMissing.ok, false);
      assert.equal(!rmMissing.ok && rmMissing.code, "ENOENT");
      const rmForce = await fsOp("rm", [missing, { force: true }], { strict_rm: true });
      assert.equal(rmForce.ok, true);

      // rename missing -> ENOENT
      const renMissing = await fsOp("rename", [missing, path.join(tmp, "x")]);
      assert.equal(renMissing.ok, false);
      assert.equal(!renMissing.ok && renMissing.code, "ENOENT");
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });
});
