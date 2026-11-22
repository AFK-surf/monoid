// Official upstream test corpora cross-checked directly against MoonBit replacements:
// 1. nst/JSONTestSuite (318 y_/n_/i_ parsing vectors) vs Node JSON.parse/JSON.stringify
// 2. nodejs/node test/parallel/test-path-*.js (POSIX + Win32) vs node:path.{posix,win32}
// 3. WPT url/resources/urltestdata.json (562 base=null absolute URLs) vs Node new URL()
// 4. Project Wycheproof (AES-128-GCM, ECDH secp256r1, ECDSA secp256r1 SHA-256, RSA PKCS#1 v1.5)
// 5. Willem van Schaik's official PNGSuite (176 valid + corrupt PNGs) + malformed PNG corpus
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createInterface } from "node:readline";
import { after, describe, it } from "node:test";
import zlib from "node:zlib";
import { harnessBinary, noHarness } from "./mb-harness.ts";

const FIXTURES_DIR = path.join(import.meta.dirname, "fixtures", "upstream-corpora");

function loadGz<T>(name: string): T {
  const gz = fs.readFileSync(path.join(FIXTURES_DIR, name));
  return JSON.parse(zlib.gunzipSync(gz).toString("utf8")) as T;
}

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

function toU16(s: string): number[] {
  const out = new Array<number>(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

function nodeWithExtension(pApi: typeof path.posix, p: string, ext: string): string {
  const name = pApi.basename(p);
  const dot = name.lastIndexOf(".");
  const stem = dot > 0 ? name.slice(0, dot) : name;
  return pApi.join(pApi.dirname(p), `${stem}.${ext}`);
}

function nodeRelativeParts(win: boolean, p: string): string[] | null {
  if (p === "" || p.startsWith("/") || (win && (p.startsWith("\\") || p.includes(":")))) {
    return null;
  }
  const parts = win ? p.split(/[\\/]/) : p.split("/");
  if (parts.includes("..")) return null;
  return parts;
}

function makePngChunk(type: string, body: Buffer): Buffer {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(body.length, 0);
  const typed = Buffer.concat([Buffer.from(type, "ascii"), body]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(typed) >>> 0, 0);
  return Buffer.concat([len, typed, crc]);
}

function buildSyntheticPng(opts: {
  w: number;
  h: number;
  depth: number;
  ctype: number;
  idat?: Buffer;
  plte?: Buffer;
  extraChunks?: Buffer[];
}): Buffer {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(opts.w, 0);
  ihdr.writeUInt32BE(opts.h, 4);
  ihdr[8] = opts.depth;
  ihdr[9] = opts.ctype;
  const parts: Buffer[] = [sig, makePngChunk("IHDR", ihdr)];
  if (opts.plte) parts.push(makePngChunk("PLTE", opts.plte));
  if (opts.extraChunks) parts.push(...opts.extraChunks);
  if (opts.idat) parts.push(makePngChunk("IDAT", opts.idat));
  parts.push(makePngChunk("IEND", Buffer.alloc(0)));
  return Buffer.concat(parts);
}

describe("MoonBit official upstream test corpora", { skip: noHarness() }, () => {
  let h: UpstreamHarness | null = null;
  const harness = () => (h ??= new UpstreamHarness());
  after(() => h?.close());

  it("1. nst/JSONTestSuite (all 318 y_/n_/i_ vectors) vs Node JSON.parse", async () => {
    type Corpus = {
      count: number;
      cases: Array<{ name: string; b64: string }>;
    };
    const corpus = loadGz<Corpus>("jsontestsuite.json.gz");
    assert.equal(corpus.count, 318);
    const client = harness();
    const failures: string[] = [];

    for (const c of corpus.cases) {
      const str = Buffer.from(c.b64, "base64").toString("utf8");
      let nodeOk = false;
      let nodeOut: string | null = null;
      try {
        nodeOut = JSON.stringify(JSON.parse(str));
        nodeOk = true;
      } catch {
        nodeOk = false;
      }

      const mb = await client.ask<{ ok: boolean; out?: string; err?: string }>({
        op: "json.parse_u16",
        u16: toU16(str),
      });

      if (c.name.startsWith("y_")) {
        if (!mb.ok) {
          failures.push(`${c.name}: y_ rejected by MB (${mb.err})`);
        } else if (nodeOk && mb.out !== nodeOut) {
          failures.push(`${c.name}: y_ output mismatch MB=${mb.out?.slice(0, 80)} Node=${nodeOut?.slice(0, 80)}`);
        }
      } else if (c.name.startsWith("n_")) {
        if (mb.ok) {
          failures.push(`${c.name}: n_ accepted by MB (out=${mb.out?.slice(0, 80)})`);
        }
      } else if (c.name.startsWith("i_")) {
        // Implementation-defined: must not crash; where both accept, outputs must match Node.
        if (mb.ok && nodeOk && mb.out !== nodeOut) {
          failures.push(`${c.name}: i_ both accepted but mismatch MB=${mb.out?.slice(0, 80)} Node=${nodeOut?.slice(0, 80)}`);
        }
        if (mb.ok !== nodeOk) {
          failures.push(`${c.name}: i_ accept mismatch MB=${mb.ok} Node=${nodeOk}`);
        }
      }
    }
    assert.equal(failures.length, 0, `JSONTestSuite failures (${failures.length}):\n${failures.slice(0, 30).join("\n")}`);
  });

  it("2. nodejs/node test-path-*.js full matrix (POSIX + Win32) vs node:path", async () => {
    type PathCorpus = {
      posix: {
        join: string[][];
        dirname: string[];
        basename: string[];
        isAbsolute: string[];
        extPaths: string[];
        relativePairs: [string, string][];
      };
      win32: {
        join: string[][];
        dirname: string[];
        basename: string[];
        isAbsolute: string[];
        extPaths: string[];
        relativePairs: [string, string][];
      };
    };
    const corpus = loadGz<PathCorpus>("node-path.json.gz");
    const client = harness();
    const failures: string[] = [];

    for (const [label, sep, pApi, data] of [
      ["posix", "/", path.posix, corpus.posix],
      ["win32", "\\", path.win32, corpus.win32],
    ] as const) {
      const win = sep === "\\";
      for (const parts of data.join) {
        const got = await client.ask<string>({ op: "path.join", sep, parts });
        const exp = pApi.join(...parts);
        if (got !== exp) failures.push(`${label}.join(${JSON.stringify(parts)}): got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
      }
      for (const p of data.dirname) {
        const got = await client.ask<string>({ op: "path.dirname", sep, path: p });
        const exp = pApi.dirname(p);
        if (got !== exp) failures.push(`${label}.dirname(${JSON.stringify(p)}): got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
      }
      for (const p of data.basename) {
        const got = await client.ask<string>({ op: "path.basename", sep, path: p });
        const exp = pApi.basename(p);
        if (got !== exp) failures.push(`${label}.basename(${JSON.stringify(p)}): got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
      }
      for (const p of data.isAbsolute) {
        const got = await client.ask<boolean>({ op: "path.is_absolute", sep, path: p });
        const exp = pApi.isAbsolute(p);
        if (got !== exp) failures.push(`${label}.isAbsolute(${JSON.stringify(p)}): got=${got} exp=${exp}`);
      }
      for (const p of data.extPaths) {
        const got = await client.ask<string>({ op: "path.with_extension", sep, path: p, ext: "bak" });
        const exp = nodeWithExtension(pApi, p, "bak");
        if (got !== exp) failures.push(`${label}.with_extension(${JSON.stringify(p)}): got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
      }
      for (const [from, to] of data.relativePairs) {
        const rel = pApi.relative(from, to);
        for (const sample of [from, to, rel]) {
          const got = await client.ask<string[] | null>({ op: "path.relative_parts", sep, path: sample });
          const exp = nodeRelativeParts(win, sample);
          if (JSON.stringify(got) !== JSON.stringify(exp)) {
            failures.push(`${label}.relative_parts(${JSON.stringify(sample)}): got=${JSON.stringify(got)} exp=${JSON.stringify(exp)}`);
          }
        }
      }
    }
    assert.equal(failures.length, 0, `Node path failures (${failures.length}):\n${failures.slice(0, 30).join("\n")}`);
  });

  it("3. WPT urltestdata.json (562 base=null absolute URLs) vs Node new URL()", async () => {
    type WptCase =
      | { input: string; failure: true }
      | {
          input: string;
          failure?: false;
          href: string;
          origin?: string;
          protocol: string;
          username: string;
          password: string;
          hostname: string;
          port: string;
          pathname: string;
          search: string;
          hash: string;
        };
    const corpus = loadGz<{ count: number; cases: WptCase[] }>("wpt-urltestdata.json.gz");
    assert.equal(corpus.count, 562);
    const client = harness();
    const failures: string[] = [];

    // Documented scope boundary in station/mb/src/cloud_net/url.mbt:4-6:
    // "A non-ASCII domain is made ASCII by Punycode over its labels lowercased (no further UTS #46 mapping)".
    // Only 1 of 562 WPT base=null cases relies on full UTS #46 NFKC mapping (Mathematical Bold letters -> "localhost").
    const documentedUts46Scope = new Set(["file://loC𝐀𝐋𝐇𝐨𝐬𝐭/usr/bin"]);

    for (const c of corpus.cases) {
      if (documentedUts46Scope.has(c.input)) continue;
      let nodeUrl: URL | null = null;
      try {
        nodeUrl = new URL(c.input);
      } catch {
        nodeUrl = null;
      }

      const mb = await client.ask<{
        href: string;
        origin: string;
        protocol: string;
        username: string;
        password: string;
        hostname: string;
        port: string;
        pathname: string;
        search: string;
        hash: string;
      } | null>({ op: "url.parse", raw: c.input });

      if (nodeUrl === null) {
        if (mb !== null) {
          failures.push(`URL(${JSON.stringify(c.input)}): Node rejected, MB accepted href=${JSON.stringify(mb.href)}`);
        }
      } else {
        if (mb === null) {
          failures.push(`URL(${JSON.stringify(c.input)}): Node accepted href=${JSON.stringify(nodeUrl.href)}, MB rejected`);
        } else {
          const fields = ["href", "origin", "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash"] as const;
          for (const f of fields) {
            if (mb[f] !== nodeUrl[f]) {
              failures.push(`URL(${JSON.stringify(c.input)}).${f}: MB=${JSON.stringify(mb[f])} Node=${JSON.stringify(nodeUrl[f])}`);
              break;
            }
          }
        }
      }
    }
    assert.equal(failures.length, 0, `WPT URL failures (${failures.length}):\n${failures.slice(0, 40).join("\n")}`);
  });

  it("4. Project Wycheproof (AES-128-GCM, ECDH secp256r1, ECDSA secp256r1 SHA-256, RSA PKCS#1 v1.5)", async () => {
    type Wycheproof = {
      aes_gcm: {
        count: number;
        cases: Array<{
          tcId: number;
          comment: string;
          keySize: number;
          ivSize: number;
          tagSize: number;
          key: string;
          iv: string;
          aad: string;
          msg: string;
          ct: string;
          tag: string;
          result: "valid" | "invalid" | "acceptable";
          flags: string[];
        }>;
      };
      ecdh_secp256r1: {
        count: number;
        cases: Array<{
          tcId: number;
          comment: string;
          public: string;
          private: string;
          shared: string;
          result: "valid" | "invalid" | "acceptable";
          flags: string[];
        }>;
      };
      ecdsa_secp256r1_sha256: {
        count: number;
        groups: Array<{
          uncompressed: string;
          tests: Array<{
            tcId: number;
            comment: string;
            msg: string;
            sig: string;
            result: "valid" | "invalid" | "acceptable";
            flags: string[];
          }>;
        }>;
      };
      rsa_2048_sha256: {
        count: number;
        groups: Array<{
          n: string;
          e: string;
          sha: string;
          tests: Array<{
            tcId: number;
            comment: string;
            msg: string;
            sig: string;
            result: "valid" | "invalid" | "acceptable";
            flags: string[];
          }>;
        }>;
      };
    };
    const corpus = loadGz<Wycheproof>("wycheproof.json.gz");
    const client = harness();
    const failures: string[] = [];

    // 4a. AES-128-GCM
    for (const t of corpus.aes_gcm.cases) {
      const open = await client.ask<{ ok: boolean; plain?: string }>({
        op: "crypto.gcm_open",
        key: t.key,
        iv: t.iv,
        aad: t.aad,
        ct: t.ct,
        tag: t.tag,
      });
      // p54_gcm_open is AES-128-GCM with 96-bit IV and 128-bit tag only (TLS 1.3 RFC 8446).
      const supportedParams = t.keySize === 128 && t.ivSize === 96 && t.tagSize === 128;
      if (t.result === "valid" && supportedParams) {
        if (!open.ok || open.plain !== t.msg) {
          failures.push(`AES-GCM tcId=${t.tcId} (${t.comment}): valid open failed`);
        }
        const seal = await client.ask<{ ok: boolean; ct?: string; tag?: string }>({
          op: "crypto.gcm_seal",
          key: t.key,
          iv: t.iv,
          aad: t.aad,
          plain: t.msg,
        });
        if (!seal.ok || seal.ct !== t.ct || seal.tag !== t.tag) {
          failures.push(`AES-GCM tcId=${t.tcId} (${t.comment}): valid seal mismatch`);
        }
      } else if (t.result === "invalid" || !supportedParams) {
        if (open.ok) {
          failures.push(`AES-GCM tcId=${t.tcId} (${t.comment}): invalid/unsupported accepted!`);
        }
      }
    }

    // 4b. ECDH secp256r1
    // Note: Wycheproof ecdh_secp256r1_test.json encodes `public` as ASN.1 SubjectPublicKeyInfo (DER).
    // Extract the BIT STRING public key bytes when SPKI-wrapped, or pass raw bytes for malformed inputs.
    function extractSpkiBitString(spkiHex: string): { rawHex: string; validSpki: boolean } {
      const buf = Buffer.from(spkiHex, "hex");
      try {
        // Parse SPKI DER: SEQUENCE { AlgorithmIdentifier, BIT STRING (0x00 || point) }
        const keyObj = crypto.createPublicKey({ key: buf, format: "der", type: "spki" });
        const jwk = keyObj.export({ format: "jwk" });
        if (jwk.kty === "EC" && jwk.crv === "P-256" && jwk.x && jwk.y) {
          const x = Buffer.from(jwk.x, "base64url");
          const y = Buffer.from(jwk.y, "base64url");
          if (x.length === 32 && y.length === 32) {
            return { rawHex: Buffer.concat([Buffer.from([0x04]), x, y]).toString("hex"), validSpki: true };
          }
        }
      } catch {
        // Malformed SPKI / off-curve / infinity / wrong curve -> try to locate trailing BIT STRING if present
      }
      // Best-effort scan for 0x03 <len> 0x00 <point> at tail so we also exercise raw point validation
      const idx = buf.lastIndexOf(Buffer.from([0x03, 0x42, 0x00]));
      if (idx >= 0 && idx + 3 + 65 === buf.length) {
        return { rawHex: buf.subarray(idx + 3).toString("hex"), validSpki: false };
      }
      return { rawHex: spkiHex, validSpki: false };
    }

    for (const t of corpus.ecdh_secp256r1.cases) {
      const { rawHex, validSpki } = extractSpkiBitString(t.public);
      // Normalize private key to 32-byte big-endian when valid
      let privHex = t.private;
      if (privHex.length > 64 && privHex.startsWith("00")) {
        privHex = privHex.slice(privHex.length - 64);
      } else if (privHex.length < 64) {
        privHex = privHex.padStart(64, "0");
      }
      const res = await client.ask<{ ok: boolean; shared?: string; err?: string }>({
        op: "crypto.p256_shared",
        d: privHex,
        peer: rawHex,
      });
      if (t.result === "valid" && validSpki) {
        if (!res.ok || res.shared !== t.shared) {
          failures.push(`ECDH tcId=${t.tcId} (${t.comment}): valid failed got=${JSON.stringify(res)} exp=${t.shared}`);
        }
      } else if (t.result === "invalid") {
        // Wycheproof ecdh_secp256r1_test.json wraps public keys in ASN.1 SPKI; p54_p256_shared
        // takes raw 65-byte uncompressed TLS 1.3 KeyShare points (no SPKI curve parameters).
        // Skip the 5 SPKI-curve-parameter-only vectors whose embedded raw point is a valid P-256 point.
        const spkiCurveParamOnly =
          t.flags.includes("WrongCurve") ||
          t.flags.includes("WrongOrder") ||
          t.flags.includes("NegativeCofactor") ||
          t.flags.includes("ModifiedPrime");
        if (res.ok && !validSpki && !spkiCurveParamOnly) {
          failures.push(`ECDH tcId=${t.tcId} (${t.comment}): invalid point accepted! flags=${t.flags.join(",")}`);
        }
      }
    }

    // Explicit raw-point boundary tests for p54_p256_shared:
    // infinity, all-zero pubkey, compressed prefix 02/03, coordinate wrap (x0 + p < 2^256 on valid curve point!),
    // out-of-range x>=p / y>=p, off-curve, d=0, d=n.
    const pHex = "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff";
    const gxHex = "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296";
    const gyHex = "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5";
    const x0Hex = "0000000000000000000000000000000000000000000000000000000000000005";
    const y0Hex = "459243b9aa581806fe913bce99817ade11ca503c64d9a3c533415c083248fbcc";
    const x0PlusPHex = "ffffffff00000001000000000000000000000001000000000000000000000004";
    const validPriv = "0000000000000000000000000000000000000000000000000000000000000001";
    // Control: (x0, y0) IS a valid P-256 point and must succeed.
    const ctrlOk = await client.ask<{ ok: boolean; shared?: string }>({
      op: "crypto.p256_shared",
      d: validPriv,
      peer: "04" + x0Hex + y0Hex,
    });
    if (!ctrlOk.ok || ctrlOk.shared !== x0Hex) {
      failures.push(`ECDH control (x0, y0) failed: ${JSON.stringify(ctrlOk)}`);
    }
    const badEcdh: Array<[string, string, string]> = [
      ["all-zero pub", validPriv, "04" + "00".repeat(64)],
      ["infinity 00", validPriv, "00"],
      ["compressed 02", validPriv, "02" + gxHex],
      ["compressed 03", validPriv, "03" + gxHex],
      ["coordinate wrap x = x0 + p (mod p on curve!)", validPriv, "04" + x0PlusPHex + y0Hex],
      ["x = p (out of range)", validPriv, "04" + pHex + gyHex],
      ["y = p (out of range)", validPriv, "04" + gxHex + pHex],
      ["x = 0xffffffff...ffff (> p)", validPriv, "04" + "ff".repeat(32) + gyHex],
      ["off-curve point", validPriv, "04" + gxHex + "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f6"],
      ["zero private scalar", "00".repeat(32), "04" + gxHex + gyHex],
      ["private scalar == n", "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551", "04" + gxHex + gyHex],
    ];
    for (const [label, d, peer] of badEcdh) {
      const res = await client.ask<{ ok: boolean }>({ op: "crypto.p256_shared", d, peer });
      if (res.ok) failures.push(`ECDH boundary (${label}): should have been rejected!`);
    }

    // 4c. ECDSA secp256r1 SHA-256 (DER verification)
    for (const g of corpus.ecdsa_secp256r1_sha256.groups) {
      for (const t of g.tests) {
        const res = await client.ask<{ ok: boolean }>({
          op: "crypto.p256_verify_der",
          pub: g.uncompressed,
          sig: t.sig,
          msg: t.msg,
        });
        if (t.result === "valid" && !res.ok) {
          failures.push(`ECDSA tcId=${t.tcId} (${t.comment}): valid rejected`);
        } else if (t.result === "invalid" && res.ok) {
          failures.push(`ECDSA tcId=${t.tcId} (${t.comment}): invalid accepted flags=${t.flags.join(",")}`);
        }
      }
    }

    // 4d. RSA PKCS#1 v1.5 2048 SHA-256 (verify + sign roundtrip)
    for (const g of corpus.rsa_2048_sha256.groups) {
      for (const t of g.tests) {
        const res = await client.ask<{ ok: boolean }>({
          op: "crypto.rsa_verify",
          n: g.n,
          e: g.e,
          hash: "sha256",
          msg: t.msg,
          sig: t.sig,
        });
        if (t.result === "valid" && !res.ok) {
          failures.push(`RSA-PKCS1 tcId=${t.tcId} (${t.comment}): valid rejected`);
        } else if (t.result === "invalid" && res.ok) {
          failures.push(`RSA-PKCS1 tcId=${t.tcId} (${t.comment}): invalid accepted flags=${t.flags.join(",")}`);
        }
      }
    }

    // Also test p54_rsa_sign live against Node crypto.verify (SHA-1, SHA-256, SHA-512)
    const { privateKey, publicKey } = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
    const jwk = privateKey.export({ format: "jwk" });
    const nHex = Buffer.from(jwk.n!, "base64url").toString("hex");
    const eHex = Buffer.from(jwk.e!, "base64url").toString("hex");
    const dHex = Buffer.from(jwk.d!, "base64url").toString("hex");
    for (const hash of ["sha1", "sha256", "sha512"]) {
      const msg = Buffer.from(`wycheproof-rsa-sign-${hash}`);
      const signed = await client.ask<{ ok: boolean; sig?: string; err?: string }>({
        op: "crypto.rsa_sign",
        n: nHex,
        e: eHex,
        d: dHex,
        hash,
        msg: msg.toString("hex"),
      });
      if (!signed.ok || !signed.sig) {
        failures.push(`RSA sign (${hash}) failed: ${signed.err}`);
      } else {
        const verified = crypto.verify(hash, msg, publicKey, Buffer.from(signed.sig, "hex"));
        if (!verified) failures.push(`RSA sign (${hash}) did not verify in Node!`);
      }
    }

    assert.equal(failures.length, 0, `Wycheproof failures (${failures.length}):\n${failures.slice(0, 40).join("\n")}`);
  });

  it("5. Official PNGSuite (all 176 valid + corrupt PNGs) + malformed PNGs", async () => {
    type PngCorpus = {
      count: number;
      cases: Array<{ name: string; corrupt: boolean; b64: string }>;
    };
    const corpus = loadGz<PngCorpus>("pngsuite.json.gz");
    assert.equal(corpus.count, 176);
    const client = harness();
    const failures: string[] = [];

    for (const c of corpus.cases) {
      const buf = Buffer.from(c.b64, "base64");
      const res = await client.ask<{ ok: boolean; w?: number; h?: number; sha256?: string }>({
        op: "png.decode",
        hex: buf.toString("hex"),
      });
      if (c.corrupt) {
        if (res.ok) {
          failures.push(`PNGSuite corrupt ${c.name}: accepted (w=${res.w}, h=${res.h})!`);
        }
      } else {
        // Read expected dimensions from IHDR (bytes 16..24)
        const expW = buf.readUInt32BE(16);
        const expH = buf.readUInt32BE(20);
        if (!res.ok) {
          failures.push(`PNGSuite valid ${c.name}: rejected (expected ${expW}x${expH})`);
        } else if (res.w !== expW || res.h !== expH) {
          failures.push(`PNGSuite valid ${c.name}: dims got=${res.w}x${res.h} exp=${expW}x${expH}`);
        }
      }
    }

    // Synthetic malformed PNGs: invalid filter byte, bad zlib header, bad adler32, missing PLTE, out-of-range palette index, truncated IDAT, zlib bomb
    const badPngs: Array<[string, Buffer]> = [
      [
        "invalid-filter-5",
        buildSyntheticPng({ w: 2, h: 2, depth: 8, ctype: 2, idat: zlib.deflateSync(Buffer.from([5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])) }),
      ],
      [
        "invalid-filter-255",
        buildSyntheticPng({ w: 1, h: 1, depth: 8, ctype: 0, idat: zlib.deflateSync(Buffer.from([255, 42])) }),
      ],
      [
        "corrupt-zlib-header",
        buildSyntheticPng({ w: 1, h: 1, depth: 8, ctype: 0, idat: Buffer.from([0x78, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) }),
      ],
      [
        "missing-plte-for-ctype-3",
        buildSyntheticPng({ w: 1, h: 1, depth: 8, ctype: 3, idat: zlib.deflateSync(Buffer.from([0, 0])) }),
      ],
      [
        "truncated-idat-rows",
        buildSyntheticPng({ w: 4, h: 4, depth: 8, ctype: 6, idat: zlib.deflateSync(Buffer.from([0, 1, 2, 3])) }),
      ],
      [
        "no-idat-chunk",
        buildSyntheticPng({ w: 1, h: 1, depth: 8, ctype: 0 }),
      ],
      [
        "zlib-bomb-oversized-idat",
        buildSyntheticPng({
          w: 1,
          h: 1,
          depth: 8,
          ctype: 0,
          // 1 MiB of zeros in a 1x1 PNG (expects only 2 bytes)
          idat: zlib.deflateSync(Buffer.alloc(1024 * 1024, 0)),
        }),
      ],
    ];
    for (const [label, buf] of badPngs) {
      const res = await client.ask<{ ok: boolean; w?: number; h?: number }>({
        op: "png.decode",
        hex: buf.toString("hex"),
      });
      if (res.ok) {
        failures.push(`Malformed PNG (${label}): accepted!`);
      }
    }

    assert.equal(failures.length, 0, `PNGSuite failures (${failures.length}):\n${failures.slice(0, 40).join("\n")}`);
  });
});
