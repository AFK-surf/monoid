// Live cross-checks of pure MoonBit stdlib/Node replacements against real Node.js built-ins:
// node:path (posix & win32), node:zlib (raw deflate, zlib, gzip bidirectional), JSON,
// encodeURIComponent/encodeURI/decodeURIComponent, node:crypto (SHA-1, SHA-256, HMAC-SHA-256),
// Buffer (base64/base64url/hex), zlib.crc32, and Date.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import path from "node:path";
import { createInterface } from "node:readline";
import { after, describe, it } from "node:test";
import zlib from "node:zlib";
import { harnessBinary, noHarness } from "./mb-harness.ts";

class StdlibHarness {
  readonly #proc;
  readonly #rl;
  readonly #pending = new Map<number, (v: unknown) => void>();
  #nextId = 1;

  constructor() {
    this.#proc = spawn(harnessBinary(), ["--builder", "harness-stdlib"], {
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

function deterministicBytes(len: number, seed: number): Buffer {
  const out = Buffer.allocUnsafe(len);
  let s = seed >>> 0;
  for (let i = 0; i < len; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    out[i] = (s >>> 24) & 0xff;
  }
  return out;
}

describe("MoonBit stdlib conformance against real Node.js built-ins", { skip: noHarness() }, () => {
  let h: StdlibHarness | null = null;
  const harness = () => (h ??= new StdlibHarness());
  after(() => h?.close());

  it("node:path.posix & node:path.win32 cross-check (join, dirname, basename, isAbsolute)", async () => {
    const client = harness();
    const posixJoinCases: string[][] = [
      [], [""], ["", ""], ["."], ["./"], [".", "./"], [".", "./", "."], ["/", "..", "x"],
      ["/foo", "../../../bar"], ["foo", "../../../bar"], ["foo/", "../../../bar"],
      ["/a//b", "./c"], ["/a/b", "c/"], ["a", ".bashrc"], ["a", "..b"], ["a", ".a."],
      [" /foo"], [" ", "foo"], [" ", "."], [" ", "/"], ["/", "//foo"],
    ];
    for (const parts of posixJoinCases) {
      const got = await client.ask<string>({ op: "path.join", sep: "/", parts });
      assert.equal(got, path.posix.join(...parts), `posix.join(${JSON.stringify(parts)})`);
    }

    const winJoinCases: string[][] = [
      [], [""], ["", ""], ["."], [".\\"], ["C:"], ["C:", ""], ["C:", "."], ["C:", ".."],
      ["C:", "a"], ["C:a", ".."], ["C:a", "..\\..\\b"], ["C:\\", ".."], ["C:\\a", "..\\..\\b"],
      ["C:\\a\\b\\", ".."], ["C:\\a\\"], ["c:/a/b/", "c"],
      ["\\\\srv\\share"], ["\\\\srv\\share\\"], ["\\\\srv\\share", ".."], ["\\\\srv\\share", "..", "x"],
      ["\\\\srv\\share\\a", "..\\..\\b"], ["//srv/share", "a/b"],
      ["\\", "a"], ["\\\\", "a"], ["\\", "\\a"], ["/", "a"], ["//", "a"], ["///", "a"],
      ["1:\\foo", "bar"], ["1:", "bar"], [":\\foo", "bar"], ["a:b", "c"],
      ["a", "..", ".."], ["a\\b", "c\\"], ["a/b/", ""],
    ];
    for (const parts of winJoinCases) {
      const got = await client.ask<string>({ op: "path.join", sep: "\\", parts });
      assert.equal(got, path.win32.join(...parts), `win32.join(${JSON.stringify(parts)})`);
    }

    const singlePaths = [
      "", ".", "..", "/", "\\", "//", "\\\\", "///", "\\\\\\",
      "a", "/a", "\\a", "/a/", "\\a\\", "///a", "//a/b", "a/b", "a//b", "a\\b", "a\\\\b",
      "C:", "C:\\", "C:/", "C:a", "C:\\a", "C:\\a\\b", "C:a\\b", "C:a\\b\\",
      "1:", "1:\\a", "1:\\a\\b", ":a", ":\\a",
      "\\\\srv", "\\\\srv\\", "\\\\srv\\share", "\\\\srv\\share\\", "\\\\srv\\share\\a", "\\\\srv\\share\\a\\b",
      "//srv/share", "//srv/share/", "//srv/share/a",
      ".bashrc", "/.bashrc", "a/.bashrc", "a/..b", "a/.a.", "a/.", "a/..",
    ];
    for (const p of singlePaths) {
      assert.equal(await client.ask<string>({ op: "path.dirname", sep: "/", path: p }), path.posix.dirname(p), `posix.dirname(${JSON.stringify(p)})`);
      assert.equal(await client.ask<string>({ op: "path.basename", sep: "/", path: p }), path.posix.basename(p), `posix.basename(${JSON.stringify(p)})`);
      assert.equal(await client.ask<boolean>({ op: "path.is_absolute", sep: "/", path: p }), path.posix.isAbsolute(p), `posix.isAbsolute(${JSON.stringify(p)})`);
      assert.equal(await client.ask<string>({ op: "path.dirname", sep: "\\", path: p }), path.win32.dirname(p), `win32.dirname(${JSON.stringify(p)})`);
      assert.equal(await client.ask<string>({ op: "path.basename", sep: "\\", path: p }), path.win32.basename(p), `win32.basename(${JSON.stringify(p)})`);
      assert.equal(await client.ask<boolean>({ op: "path.is_absolute", sep: "\\", path: p }), path.win32.isAbsolute(p), `win32.isAbsolute(${JSON.stringify(p)})`);
    }
  });

  it("node:zlib bidirectional cross-check (raw deflate, zlib, gzip: Node->MB and MB->Node)", async () => {
    const client = harness();
    const marker = Buffer.from("THE_QUICK_BROWN_FOX_JUMPS_OVER_THE_LAZY_DOG_0123456789_WINDOW_EDGE");
    const winBoundary = Buffer.concat([marker, deterministicBytes(32768 - marker.length, 0x11223344), marker]);
    const payloads: Array<[string, Buffer]> = [
      ["empty", Buffer.alloc(0)],
      ["1-byte", Buffer.from([0x42])],
      ["ascii-text", Buffer.from("The quick brown fox jumps over the lazy dog. ".repeat(40))],
      ["all-zeros-128k", Buffer.alloc(131072, 0)],
      ["incompressible-70k", deterministicBytes(70000, 0xdeadbeef)],
      ["window-32k-boundary", winBoundary],
    ];

    for (const [label, buf] of payloads) {
      const hex = buf.toString("hex");
      // 1. MB compresses -> Node decompresses
      const mbRaw = Buffer.from(await client.ask<string>({ op: "flate.deflate", hex }), "hex");
      assert.deepEqual(zlib.inflateRawSync(mbRaw), buf, `MB deflate -> Node inflateRaw (${label})`);

      const mbZlib = Buffer.from(await client.ask<string>({ op: "flate.zlib_compress", hex }), "hex");
      assert.deepEqual(zlib.inflateSync(mbZlib), buf, `MB zlib_compress -> Node inflate (${label})`);

      const mbGzip = Buffer.from(await client.ask<string>({ op: "flate.gzip", hex }), "hex");
      assert.deepEqual(zlib.gunzipSync(mbGzip), buf, `MB gzip -> Node gunzip (${label})`);

      // 2. Node compresses (levels 0=stored, 1=fast, 6=default, 9=best, plus Z_FIXED) -> MB decompresses
      for (const opts of [{ level: 0 }, { level: 1 }, { level: 6 }, { level: 9 }, { strategy: zlib.constants.Z_FIXED }]) {
        const nodeRaw = zlib.deflateRawSync(buf, opts);
        const gotRaw = await client.ask<string | null>({ op: "flate.inflate", hex: nodeRaw.toString("hex") });
        assert.equal(gotRaw, hex, `Node deflateRaw(${JSON.stringify(opts)}) -> MB inflate (${label})`);

        const nodeZlib = zlib.deflateSync(buf, opts);
        const gotZlib = await client.ask<string | null>({ op: "flate.zlib_decompress", hex: nodeZlib.toString("hex") });
        assert.equal(gotZlib, hex, `Node deflate(${JSON.stringify(opts)}) -> MB zlib_decompress (${label})`);

        const nodeGzip = zlib.gzipSync(buf, opts);
        const gotGzip = await client.ask<string | null>({ op: "flate.gunzip", hex: nodeGzip.toString("hex") });
        assert.equal(gotGzip, hex, `Node gzip(${JSON.stringify(opts)}) -> MB gunzip (${label})`);
      }
    }

    // Concatenated Node gzip streams -> MB gunzip
    const catGzip = Buffer.concat([zlib.gzipSync(Buffer.from("part1-")), zlib.gzipSync(Buffer.alloc(0)), zlib.gzipSync(Buffer.from("part3"))]);
    const gotCat = await client.ask<string | null>({ op: "flate.gunzip", hex: catGzip.toString("hex") });
    assert.equal(gotCat, Buffer.from("part1-part3").toString("hex"));
  });

  it("JSON, encodeURI*, node:crypto, Buffer base64, CRC-32, and Date cross-check", async () => {
    const client = harness();
    // JSON.parse -> JSON.stringify parity
    const jsonCases = [
      "{}", "[]", "null", "true", "false", "0", "-0", "1e-7", "1e+21", "1e400", "-1e400", "0e999999",
      "{\"b\":1,\"10\":2,\"2\":3,\"4294967294\":4,\"4294967295\":5,\"a\":6,\"b\":7}",
      "\"hello\\u0000\\n\\t\\uD83D\\uDE00\\uD800\"",
    ];
    for (const raw of jsonCases) {
      const got = await client.ask<string | null>({ op: "json.roundtrip", raw });
      assert.equal(got, JSON.stringify(JSON.parse(raw)), `JSON roundtrip(${raw})`);
    }
    for (const bad of ["", "{", "[1,]", "01", "+1", "'a'", "{\"a\":1,}"]) {
      const got = await client.ask<string | null>({ op: "json.roundtrip", raw: bad });
      assert.equal(got, null, `JSON reject(${bad})`);
    }

    // encodeURIComponent / encodeURI / decodeURIComponent
    for (const s of ["", "abc-_.!~*'()", ";,/?:@&=+$#", " %\"<>\\^`{}[]", "中文 é 🚀"]) {
      assert.equal(await client.ask<string>({ op: "url.encode_uri_component", s }), encodeURIComponent(s));
      assert.equal(await client.ask<string>({ op: "url.encode_uri", s }), encodeURI(s));
      assert.equal(await client.ask<string | null>({ op: "url.decode_uri_component", s: encodeURIComponent(s) }), s);
    }

    // SHA-1, SHA-256, HMAC-SHA-256, Base64/Base64URL, CRC-32
    const key = Buffer.from("super-secret-key-longer-than-64-bytes-".repeat(3));
    for (const len of [0, 1, 55, 56, 63, 64, 65, 257]) {
      const data = deterministicBytes(len, 0x55aa0000 + len);
      const hex = data.toString("hex");
      assert.equal(await client.ask<string>({ op: "hash.sha1", hex }), crypto.createHash("sha1").update(data).digest("hex"));
      assert.equal(await client.ask<string>({ op: "hash.sha256", hex }), crypto.createHash("sha256").update(data).digest("hex"));
      assert.equal(await client.ask<string>({ op: "hash.hmac_sha256", key_hex: key.toString("hex"), hex }), crypto.createHmac("sha256", key).update(data).digest("hex"));
      assert.equal(await client.ask<string>({ op: "codec.base64_encode", hex }), data.toString("base64"));
      assert.equal(await client.ask<string>({ op: "codec.base64url_encode", hex }), data.toString("base64url"));
      assert.equal(await client.ask<string | null>({ op: "codec.base64_decode", s: data.toString("base64") }), hex);
      assert.equal(await client.ask<string | null>({ op: "codec.base64url_decode", s: data.toString("base64url") }), hex);
      assert.equal(await client.ask<number>({ op: "codec.crc32", hex }), zlib.crc32(data));
    }

    // Date.prototype.toISOString & Date.parse
    const timestamps = [
      0, -1, -86400000, -2208988800000, 951782400000, 1709164800000, 2147483647000, 2147483648000,
      -62167219200000, -62135596800000, 253402300799999, 253402300800000, 8640000000000000, -8640000000000000,
    ];
    for (const ms of timestamps) {
      const iso = new Date(ms).toISOString();
      assert.equal(await client.ask<string>({ op: "time.format_iso_ms", ms: String(ms) }), iso, `format_iso_ms(${ms})`);
      assert.equal(await client.ask<string | null>({ op: "time.parse_iso_ms", s: iso }), String(Date.parse(iso)), `parse_iso_ms(${iso})`);
    }
  });
});
