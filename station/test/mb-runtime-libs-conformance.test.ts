// Upstream conformance vectors and real Node stdlib interop tests for the pure MoonBit station's
// Node runtime replacements (Track 6):
//   1. node:tls + node:crypto (`live_p5_4_tls.mbt`, `live_p5_4_crypto.mbt`, `vault_service/x509.mbt`)
//   2. node:http (`station_main/http.mbt`, `host/http.mbt`)
//   3. node:fs + node:child_process (`live_dispatch.mbt` `host_fs_op`, `sys.c`, `sys.mbt`)
import assert from "node:assert/strict";
import { type ChildProcess, spawn } from "node:child_process";
import {
  X509Certificate,
  createCipheriv,
  createECDH,
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  randomBytes,
  verify as verifySignature,
} from "node:crypto";
import {
  chmodSync,
  constants as fsConstants,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { createServer as httpServer, request as httpRequest } from "node:http";
import { connect as netConnect, createServer as netServer, type Server, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { connect as tlsConnect } from "node:tls";
import { after, test } from "node:test";
import { mbHarnessBinary, mbStationBinary } from "./mb-harness.ts";

const readerBin = mbStationBinary();
const harnessBin = mbHarnessBinary();
const skipHarness =
  harnessBin === null
    ? "the MoonBit test harness (stillfail-reader-harness) is not built here"
    : process.platform === "win32"
      ? "Unix-only conformance tests"
      : false;
const skipReader =
  readerBin === null
    ? "the MoonBit program (stillfail-reader) is not built here"
    : process.platform === "win32"
      ? "the launcher's descriptors are Unix's"
      : false;

const dirs: string[] = [];
const fresh = (what: string) => {
  const dir = mkdtempSync(join(tmpdir(), `sf-conf-${what}-`));
  dirs.push(dir);
  return dir;
};

const children: ChildProcess[] = [];
after(async () => {
  const left = children.filter((c) => c.exitCode === null && c.signalCode === null);
  for (const c of left) c.kill("SIGKILL");
  await Promise.all(
    left.map((c) =>
      c.exitCode === null && c.signalCode === null
        ? new Promise<void>((r) => c.once("exit", () => r()))
        : undefined,
    ),
  );
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

type HarnessClient = {
  call: (op: string, payload?: Record<string, unknown>) => Promise<{ ok?: any; error?: string }>;
  ok: (op: string, payload?: Record<string, unknown>) => Promise<any>;
  close: () => Promise<void>;
};

function startHarness(): HarnessClient {
  const child = spawn(harnessBin!, ["--builder", "harness-station-main", "--shell-dir", fresh("shell")], {
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.push(child);
  let stderr = "";
  child.stderr!.on("data", (d) => (stderr += d));
  let nextId = 0;
  const pending = new Map<number, (msg: any) => void>();
  createInterface({ input: child.stdout! }).on("line", (line) => {
    const msg = JSON.parse(line);
    const resolve = pending.get(msg.id);
    if (resolve) {
      pending.delete(msg.id);
      resolve(msg);
    }
  });
  child.on("exit", (code, signal) => {
    for (const [, resolve] of pending) {
      resolve({ error: `harness exited prematurely (code=${code}, signal=${signal}): ${stderr}` });
    }
    pending.clear();
  });
  const call = (op: string, payload: Record<string, unknown> = {}) =>
    new Promise<{ ok?: any; error?: string }>((resolve) => {
      const id = ++nextId;
      pending.set(id, resolve);
      child.stdin!.write(`${JSON.stringify({ id, op, ...payload })}\n`);
    });
  const ok = async (op: string, payload: Record<string, unknown> = {}) => {
    const r = await call(op, payload);
    assert.equal(r.error, undefined, `${op} failed: ${r.error}`);
    return r.ok;
  };
  const close = async () => {
    child.stdin!.end();
    if (child.exitCode === null && child.signalCode === null) {
      await new Promise<void>((r) => child.once("exit", () => r()));
    }
  };
  return { call, ok, close };
}

// ═══════════════════════════════════════════════════════════════════════════════
// 1. node:tls + node:crypto conformance & real Node tls.connect interop
// ═══════════════════════════════════════════════════════════════════════════════

test("crypto conformance: NIST SP 800-38D AES-128-GCM official vectors (TC1-TC6) & 1-bit tamper rejection", { skip: skipHarness }, async () => {
  const h = startHarness();
  try {
    // Official NIST SP 800-38D / GCM Spec Test Cases 1..4 (96-bit IV, 128-bit key)
    const nistVectors: Array<{ name: string; key: string; nonce: string; aad: string; plain: string; ct: string; tag: string }> = [
      {
        name: "NIST TC1: empty plaintext, empty AAD",
        key: "00000000000000000000000000000000",
        nonce: "000000000000000000000000",
        aad: "",
        plain: "",
        ct: "",
        tag: "58e2fccefa7e3061367f1d57a4e7455a",
      },
      {
        name: "NIST TC2: 16-byte zero plaintext, empty AAD",
        key: "00000000000000000000000000000000",
        nonce: "000000000000000000000000",
        aad: "",
        plain: "00000000000000000000000000000000",
        ct: "0388dace60b6a392f328c2b971b2fe78",
        tag: "ab6e47d42cec13bdf53a67b21257bddf",
      },
      {
        name: "NIST TC3: 64-byte plaintext, empty AAD",
        key: "feffe9928665731c6d6a8f9467308308",
        nonce: "cafebabefacedbaddecaf888",
        aad: "",
        plain:
          "d9313225f88406e5a55909c5aff5269a" +
          "86a7a9531534f7da2e4c303d8a318a72" +
          "1c3c0c95956809532fcf0e2449a6b525" +
          "b16aedf5aa0de657ba637b391aafd255",
        ct:
          "42831ec2217774244b7221b784d0d49c" +
          "e3aa212f2c02a4e035c17e2329aca12e" +
          "21d514b25466931c7d8f6a5aac84aa05" +
          "1ba30b396a0aac973d58e091473f5985",
        tag: "4d5c2af327cd64a62cf35abd2ba6fab4",
      },
      {
        name: "NIST TC4: 60-byte non-aligned plaintext, 20-byte non-aligned AAD",
        key: "feffe9928665731c6d6a8f9467308308",
        nonce: "cafebabefacedbaddecaf888",
        aad: "feedfacedeadbeeffeedfacedeadbeefabaddad2",
        plain:
          "d9313225f88406e5a55909c5aff5269a" +
          "86a7a9531534f7da2e4c303d8a318a72" +
          "1c3c0c95956809532fcf0e2449a6b525" +
          "b16aedf5aa0de657ba637b39",
        ct:
          "42831ec2217774244b7221b784d0d49c" +
          "e3aa212f2c02a4e035c17e2329aca12e" +
          "21d514b25466931c7d8f6a5aac84aa05" +
          "1ba30b396a0aac973d58e091",
        tag: "5bc94fbc3221a5db94fae95ae7121a47",
      },
    ];

    for (const v of nistVectors) {
      const sealed: string = await h.ok("gcmSeal", { key: v.key, nonce: v.nonce, aad: v.aad, plain: v.plain });
      assert.equal(sealed, v.ct + v.tag, `${v.name}: seal mismatch`);
      const opened = await h.ok("gcmOpen", { key: v.key, nonce: v.nonce, aad: v.aad, sealed });
      assert.equal(opened, v.plain, `${v.name}: open mismatch`);

      // Cross-check with Node's OpenSSL AES-128-GCM
      const cipher = createCipheriv("aes-128-gcm", Buffer.from(v.key, "hex"), Buffer.from(v.nonce, "hex"));
      if (v.aad.length > 0) cipher.setAAD(Buffer.from(v.aad, "hex"));
      const nodeCt = Buffer.concat([cipher.update(Buffer.from(v.plain, "hex")), cipher.final()]);
      const nodeTag = cipher.getAuthTag();
      assert.equal(sealed, Buffer.concat([nodeCt, nodeTag]).toString("hex"), `${v.name}: Node interop mismatch`);
    }

    // TC5: AAD-only (empty plaintext, non-16-byte AAD) & TC6: long plaintext (> 16 KiB)
    const extraCases = [
      { name: "TC5: AAD-only (empty PT, 37-byte AAD)", key: randomBytes(16), nonce: randomBytes(12), aad: randomBytes(37), plain: Buffer.alloc(0) },
      { name: "TC6: long plaintext (20003 bytes) + 19-byte AAD", key: randomBytes(16), nonce: randomBytes(12), aad: randomBytes(19), plain: randomBytes(20003) },
    ];
    for (const c of extraCases) {
      const cipher = createCipheriv("aes-128-gcm", c.key, c.nonce);
      cipher.setAAD(c.aad);
      const nodeSealed = Buffer.concat([cipher.update(c.plain), cipher.final(), cipher.getAuthTag()]).toString("hex");
      const mbSealed: string = await h.ok("gcmSeal", {
        key: c.key.toString("hex"),
        nonce: c.nonce.toString("hex"),
        aad: c.aad.toString("hex"),
        plain: c.plain.toString("hex"),
      });
      assert.equal(mbSealed, nodeSealed, `${c.name}: MoonBit vs Node AES-128-GCM mismatch`);
      const opened = await h.ok("gcmOpen", {
        key: c.key.toString("hex"),
        nonce: c.nonce.toString("hex"),
        aad: c.aad.toString("hex"),
        sealed: mbSealed,
      });
      assert.equal(opened, c.plain.toString("hex"), `${c.name}: round-trip open mismatch`);

      // Flip 1 bit in tag -> MUST return null
      const sealedBuf = Buffer.from(mbSealed, "hex");
      const badTag = Buffer.from(sealedBuf);
      badTag[badTag.length - 1] ^= 0x01;
      assert.equal(
        await h.ok("gcmOpen", { key: c.key.toString("hex"), nonce: c.nonce.toString("hex"), aad: c.aad.toString("hex"), sealed: badTag.toString("hex") }),
        null,
        `${c.name}: 1-bit flipped tag must fail auth`,
      );

      // Flip 1 bit in AAD -> MUST return null
      const badAad = Buffer.from(c.aad);
      badAad[0] ^= 0x80;
      assert.equal(
        await h.ok("gcmOpen", { key: c.key.toString("hex"), nonce: c.nonce.toString("hex"), aad: badAad.toString("hex"), sealed: mbSealed }),
        null,
        `${c.name}: 1-bit flipped AAD must fail auth`,
      );

      // Flip 1 bit in ciphertext (if non-empty) -> MUST return null
      if (c.plain.length > 0) {
        const badCt = Buffer.from(sealedBuf);
        badCt[Math.floor(c.plain.length / 2)] ^= 0x04;
        assert.equal(
          await h.ok("gcmOpen", { key: c.key.toString("hex"), nonce: c.nonce.toString("hex"), aad: c.aad.toString("hex"), sealed: badCt.toString("hex") }),
          null,
          `${c.name}: 1-bit flipped ciphertext must fail auth`,
        );
      }
    }
  } finally {
    await h.close();
  }
});

test("crypto conformance: P-256 ECDHE, P-256 ECDSA, RSA PKCS#1 v1.5, and X.509 leaf cross-verified with Node", { skip: skipHarness }, async () => {
  const h = startHarness();
  try {
    // 1. P-256 ECDHE shared secret cross-check with Node createECDH("prime256v1")
    const mbKey = await h.ok("p256Keygen");
    const nodeEcdh = createECDH("prime256v1");
    nodeEcdh.generateKeys();
    const nodePubHex = nodeEcdh.getPublicKey("hex", "uncompressed");
    const mbSharedHex: string = await h.ok("p256Shared", { d: mbKey.d, peer: nodePubHex });
    const nodeSharedHex = nodeEcdh.computeSecret(Buffer.from(mbKey.pub, "hex")).toString("hex");
    assert.equal(mbSharedHex, nodeSharedHex, "P-256 ECDH shared secret must match Node");

    // Invalid off-curve P-256 point must be rejected
    const badPoint = Buffer.from(nodePubHex, "hex");
    badPoint[badPoint.length - 1] ^= 0x01;
    const badShared = await h.call("p256Shared", { d: mbKey.d, peer: badPoint.toString("hex") });
    assert.ok(badShared.error, "off-curve P-256 point must be rejected");

    // 2. P-256 ECDSA signature verified by Node crypto.verify
    const msg = Buffer.from("stillfail-p256-conformance-payload");
    const sig = await h.ok("p256Sign", { d: mbKey.d, message: msg.toString("hex") });
    const nodePriv = createPrivateKey(mbKey.pem);
    const nodePub = createPublicKey(nodePriv);
    const derSig = Buffer.from(sig.der, "hex");
    assert.equal(verifySignature("sha256", msg, nodePub, derSig), true, "Node must verify MoonBit P-256 ECDSA signature");
    // Flip 1 bit in signature -> must fail
    const tamperedSig = Buffer.from(derSig);
    tamperedSig[tamperedSig.length - 1] ^= 0x01;
    assert.equal(verifySignature("sha256", msg, nodePub, tamperedSig), false, "1-bit flipped P-256 signature must fail");
    // Flip 1 bit in message -> must fail
    const tamperedMsg = Buffer.from(msg);
    tamperedMsg[0] ^= 0x01;
    assert.equal(verifySignature("sha256", tamperedMsg, nodePub, derSig), false, "1-bit flipped message must fail P-256 verify");

    // 3. RSA PKCS#1 v1.5 (sha1, sha256, sha512) cross-verified with Node
    const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const jwk = rsa.privateKey.export({ format: "jwk" });
    for (const hash of ["sha1", "sha256", "sha512"]) {
      const rsaSigHex: string = await h.ok("rsaSign", { jwk, hash, message: msg.toString("hex") });
      const rsaSig = Buffer.from(rsaSigHex, "hex");
      assert.equal(verifySignature(hash, msg, rsa.publicKey, rsaSig), true, `RSA ${hash} signature must verify in Node`);
      const badRsa = Buffer.from(rsaSig);
      badRsa[0] ^= 0x01;
      assert.equal(verifySignature(hash, msg, rsa.publicKey, badRsa), false, `tampered RSA ${hash} signature must fail`);
    }
    // A 1032-bit key: 129-byte n and d, never a multiple of 8, the misaligned u64be read of BigInt::from_octets.
    const rsa1032 = generateKeyPairSync("rsa", { modulusLength: 1032 });
    const jwk1032 = rsa1032.privateKey.export({ format: "jwk" });
    const sig1032 = Buffer.from(await h.ok("rsaSign", { jwk: jwk1032, hash: "sha256", message: msg.toString("hex") }), "hex");
    assert.equal(verifySignature("sha256", msg, rsa1032.publicKey, sig1032), true, "1032-bit RSA sha256 signature must verify in Node");

    // 4. X.509 CA + leaf certificate validated by Node X509Certificate
    const now = Date.UTC(2026, 10, 19, 12, 0, 0);
    const x509 = await h.ok("x509Make", { caName: "still.fail Conformance CA", host: "api.conformance.test", now });
    const caCert = new X509Certificate(x509.caPem);
    const leafCert = new X509Certificate(x509.leafPem);
    assert.equal(caCert.ca, true, "CA cert must have CA:TRUE");
    assert.equal(leafCert.ca, false, "leaf cert must have CA:FALSE");
    assert.match(leafCert.subject, /CN=api\.conformance\.test/);
    assert.match(leafCert.issuer, /CN=still\.fail Conformance CA/);
    assert.equal(leafCert.subjectAltName, "DNS:api.conformance.test");
    assert.equal(leafCert.checkHost("api.conformance.test"), "api.conformance.test");
    assert.equal(leafCert.checkHost("other.conformance.test"), undefined);
    assert.ok(leafCert.validFromDate.getTime() <= now && now <= leafCert.validToDate.getTime(), "validity window covers now");
    assert.equal(leafCert.checkIssued(caCert), true, "leaf issued by CA");
    assert.equal(leafCert.verify(caCert.publicKey), true, "leaf signature verified by CA public key");
  } finally {
    await h.close();
  }
});

// Helper to launch real MoonBit station for TLS proxy interop
const PROXY_TOKEN = "conformance-tls-door";
async function launchStation(data: string, app: string, more: Record<string, string> = {}) {
  const listener = () =>
    new Promise<Server>((resolve) => {
      const s = netServer();
      s.listen(0, "127.0.0.1", () => resolve(s));
    });
  const [mcp, loop] = [await listener(), await listener()];
  const fd = (s: Server) => (s as any)._handle.fd as number;
  const child = spawn(
    readerBin!,
    ["run", "--app", app, "--data", data, "--launcher-fds", "3,4,5", "--launcher-carries", "--launcher-heartbeat"],
    {
      stdio: ["ignore", "pipe", "pipe", fd(mcp), fd(loop), "pipe"],
      env: { PATH: fresh("path"), HOME: process.env.HOME ?? tmpdir(), TMPDIR: tmpdir(), STILLFAIL_TEST_UI_ASK: PROXY_TOKEN, STILLFAIL_HELD_EVERY_MS: "300", ...more },
    },
  );
  children.push(child);
  mcp.close();
  loop.close();
  const said: any[] = [];
  const waiters: (() => void)[] = [];
  const channel = (child.stdio as readonly unknown[])[5] as Socket;
  createInterface({ input: channel }).on("line", (line) => {
    said.push(JSON.parse(line));
    for (const w of waiters.splice(0)) w();
  });
  let err = "";
  child.stderr!.on("data", (d) => (err += d));
  const next = (what: string, pred: (m: any) => boolean) =>
    new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`never said ${what}; said=${JSON.stringify(said)}; stderr=${err}`)), 15_000);
      const look = () => {
        const found = said.find(pred);
        if (found !== undefined) {
          clearTimeout(timer);
          resolve(found);
        } else waiters.push(look);
      };
      look();
    });
  const ended = new Promise<number | null>((resolve) => child.on("exit", (code) => resolve(code)));
  return { child, next, tell: (m: unknown) => channel.write(`${JSON.stringify(m)}\n`), ended };
}

function httpPostJson(port: number, path: string, body: unknown, headers: Record<string, string> = {}): Promise<any> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      { host: "127.0.0.1", port, path, method: "POST", headers: { "content-type": "application/json", ...headers } },
      (res) => {
        let text = "";
        res.on("data", (d) => (text += d));
        res.on("end", () => resolve(JSON.parse(text)));
      },
    );
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

function tlsProxyRequest(
  proxyUrl: string,
  bundle: string,
  host: string,
  method: string,
  path: string,
  authHeader: string,
  reqBody: Buffer,
  tlsOptions: Record<string, unknown> = {},
): Promise<{ statusLine: string; body: Buffer; cipher: string; group: string; version: string }> {
  const u = new URL(proxyUrl);
  return new Promise((resolve, reject) => {
    const raw = netConnect(Number(u.port), "127.0.0.1", () => {
      raw.write(
        `CONNECT ${host}:443 HTTP/1.1\r\nhost: ${host}:443\r\nproxy-authorization: Basic ${Buffer.from(`${u.username}:${u.password}`).toString("base64")}\r\n\r\n`,
      );
    });
    let head = "";
    const onHead = (d: Buffer) => {
      head += d.toString("latin1");
      if (!head.includes("\r\n\r\n")) return;
      raw.off("data", onHead);
      if (!head.startsWith("HTTP/1.1 200")) return reject(new Error(`proxy CONNECT refused: ${head}`));
      const tls = tlsConnect(
        { socket: raw as Socket, servername: host, ca: readFileSync(bundle), minVersion: "TLSv1.3", ...tlsOptions },
        () => {
          const reqHead =
            `${method} ${path} HTTP/1.1\r\nhost: ${host}\r\nauthorization: ${authHeader}\r\n` +
            `content-length: ${reqBody.length}\r\nconnection: close\r\n\r\n`;
          tls.write(reqHead);
          if (reqBody.length > 0) tls.write(reqBody);
        },
      );
      const chunks: Buffer[] = [];
      let cipher = "";
      let group = "";
      let version = "";
      let settled = false;
      const done = () => {
        if (settled) return;
        settled = true;
        const full = Buffer.concat(chunks);
        const sep = full.indexOf("\r\n\r\n");
        const statusLine = sep >= 0 ? full.subarray(0, full.indexOf("\r\n")).toString("latin1") : "";
        const body = sep >= 0 ? full.subarray(sep + 4) : full;
        resolve({ statusLine, body, cipher, group, version });
      };
      tls.on("secureConnect", () => {
        cipher = tls.getCipher().name;
        version = tls.getProtocol() ?? "";
        group = String((tls.getEphemeralKeyInfo() as any)?.name ?? "");
      });
      tls.on("data", (b) => chunks.push(b));
      tls.on("end", done);
      tls.on("close", done);
      tls.on("error", (e) => {
        if (!settled) {
          settled = true;
          reject(e);
        }
      });
    };
    raw.on("data", onHead);
    raw.on("error", reject);
  });
}

test("TLS 1.3 real Node node:tls interop matrix: X25519/P-256, ChaCha20/AES-128-GCM, >16KiB fragmentation, unsupported suite/curve alerts", { skip: skipReader }, async () => {
  const upstream = httpServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (d) => chunks.push(d));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      res.writeHead(200, { "content-type": "application/octet-stream", "x-seen-auth": String(req.headers.authorization ?? "") });
      if (req.url === "/echo-large") {
        res.end(body);
      } else {
        res.end(`ok:${req.url}:${req.headers.authorization}`);
      }
    });
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", () => r()));
  const upPort = (upstream.address() as any).port as number;
  try {
    const data = fresh("tls-data");
    const app = fresh("tls-app");
    writeFileSync(join(app, "BUILD"), "9500\n");
    const st = await launchStation(data, app, { STILLFAIL_TEST_PROXY_UPSTREAM: String(upPort) });
    await st.next("ready", (m) => m.ready === true);
    const door = (await st.next("mcp", (m) => m.serving === "mcp")).port as number;
    const proxy = (
      await httpPostJson(
        door,
        "/ui-ask/",
        { op: "test.proxy", args: [["api.tls-matrix.test"], "stillfail-secret:m1", "real-token-xyz"] },
        { authorization: `Bearer ${PROXY_TOKEN}` },
      )
    ).answer;

    // 1. Explicit cipher + curve interop matrix
    const matrix: Array<[Record<string, unknown>, string, string]> = [
      [{ ecdhCurve: "X25519", ciphers: "TLS_CHACHA20_POLY1305_SHA256" }, "TLS_CHACHA20_POLY1305_SHA256", "X25519"],
      [{ ecdhCurve: "X25519", ciphers: "TLS_AES_128_GCM_SHA256" }, "TLS_AES_128_GCM_SHA256", "X25519"],
      [{ ecdhCurve: "prime256v1", ciphers: "TLS_AES_128_GCM_SHA256" }, "TLS_AES_128_GCM_SHA256", "prime256v1"],
    ];
    for (const [opts, expectedCipher, expectedGroup] of matrix) {
      const r = await tlsProxyRequest(
        proxy.url,
        proxy.bundle,
        "api.tls-matrix.test",
        "GET",
        "/ping",
        "Bearer stillfail-secret:m1",
        Buffer.alloc(0),
        opts,
      );
      assert.equal(r.version, "TLSv1.3");
      assert.equal(r.cipher, expectedCipher);
      assert.equal(r.group, expectedGroup);
      assert.equal(r.statusLine, "HTTP/1.1 200 OK");
      assert.equal(r.body.toString("utf8"), "ok:/ping:Bearer real-token-xyz");
    }

    // 2. Large payload (> 16 KiB TLS 1.3 max record length: 100 KiB request + 100 KiB response)
    const bigPayload = randomBytes(100 * 1024);
    const bigRes = await tlsProxyRequest(
      proxy.url,
      proxy.bundle,
      "api.tls-matrix.test",
      "POST",
      "/echo-large",
      "Bearer stillfail-secret:m1",
      bigPayload,
      { ecdhCurve: "X25519", ciphers: "TLS_AES_128_GCM_SHA256" },
    );
    assert.equal(bigRes.statusLine, "HTTP/1.1 200 OK");
    assert.equal(bigRes.body.length, bigPayload.length, "100 KiB response length must match");
    assert.equal(
      createHash("sha256").update(bigRes.body).digest("hex"),
      createHash("sha256").update(bigPayload).digest("hex"),
      "100 KiB payload across TLS 1.3 records must be byte-identical",
    );

    // 3. Unsupported cipher suite (TLS_AES_256_GCM_SHA384 only) -> TLS alert + clean close, server survives
    await assert.rejects(
      () =>
        tlsProxyRequest(
          proxy.url,
          proxy.bundle,
          "api.tls-matrix.test",
          "GET",
          "/bad-cipher",
          "Bearer stillfail-secret:m1",
          Buffer.alloc(0),
          { ciphers: "TLS_AES_256_GCM_SHA384" },
        ),
      /handshake failure|alert|ECONNRESET|socket hang up/i,
    );

    // 4. Unsupported curve (secp384r1 only) -> TLS alert + clean close, server survives
    await assert.rejects(
      () =>
        tlsProxyRequest(
          proxy.url,
          proxy.bundle,
          "api.tls-matrix.test",
          "GET",
          "/bad-curve",
          "Bearer stillfail-secret:m1",
          Buffer.alloc(0),
          { ecdhCurve: "secp384r1" },
        ),
      /handshake failure|alert|ECONNRESET|socket hang up/i,
    );

    // 5. Subsequent normal connection still succeeds immediately
    const afterBad = await tlsProxyRequest(
      proxy.url,
      proxy.bundle,
      "api.tls-matrix.test",
      "GET",
      "/after-alerts",
      "Bearer stillfail-secret:m1",
      Buffer.alloc(0),
    );
    assert.equal(afterBad.statusLine, "HTTP/1.1 200 OK");
    assert.equal(afterBad.body.toString("utf8"), "ok:/after-alerts:Bearer real-token-xyz");

    st.tell({ op: "stop" });
    assert.equal(await st.ended, 0);
  } finally {
    upstream.close();
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// 2. node:http (`station_main/http.mbt` + `host/http.mbt`) conformance
// ═══════════════════════════════════════════════════════════════════════════════

function rawTcpExchange(port: number, payload: Buffer | string): Promise<string> {
  return new Promise((resolve, reject) => {
    const s = netConnect(port, "127.0.0.1", () => {
      s.write(payload);
    });
    let out = "";
    s.on("data", (d) => (out += d.toString("latin1")));
    s.on("end", () => resolve(out));
    s.on("close", () => resolve(out));
    s.on("error", (e: any) => {
      if (e.code === "ECONNRESET") resolve(out);
      else reject(e);
    });
  });
}

function httpGetJson(port: number, path: string): Promise<{ status: number; json: any }> {
  return new Promise((resolve, reject) => {
    const req = httpRequest({ host: "127.0.0.1", port, path, method: "GET" }, (res) => {
      let body = "";
      res.on("data", (d) => (body += d));
      res.on("end", () => resolve({ status: res.statusCode!, json: JSON.parse(body) }));
    });
    req.on("error", reject);
    req.end();
  });
}

test("HTTP server conformance (`station_main/http.mbt`): headers, bodies, malformed requests, half-open RST/FIN survival", { skip: skipHarness }, async () => {
  const h = startHarness();
  try {
    const { port } = await h.ok("httpServe");

    // 1. Mixed-case headers, multi-value duplicate headers, empty POST body
    const raw1 = await rawTcpExchange(
      port,
      "POST /echo?k=1 HTTP/1.1\r\n" +
        "Host: 127.0.0.1\r\n" +
        "X-MiXeD-CaSe: VaLuE\r\n" +
        "X-Multi: first\r\n" +
        "x-multi: second\r\n" +
        "Content-Length: 0\r\n\r\n",
    );
    assert.match(raw1, /^HTTP\/1\.1 200 OK\r\n/);
    const parsed1 = JSON.parse(raw1.slice(raw1.indexOf("\r\n\r\n") + 4));
    assert.equal(parsed1.method, "POST");
    assert.equal(parsed1.target, "/echo?k=1");
    assert.equal(parsed1.bodyLen, 0);
    assert.deepEqual(
      parsed1.headers.filter(([k]: [string, string]) => k === "x-mixed-case" || k === "x-multi"),
      [
        ["x-mixed-case", "VaLuE"],
        ["x-multi", "first"],
        ["x-multi", "second"],
      ],
    );

    // 2. Large body (64 KiB)
    const body64k = randomBytes(64 * 1024);
    const req64k = Buffer.concat([
      Buffer.from(`POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: ${body64k.length}\r\n\r\n`),
      body64k,
    ]);
    const raw64k = await rawTcpExchange(port, req64k);
    assert.match(raw64k, /^HTTP\/1\.1 200 OK\r\n/);
    const parsed64k = JSON.parse(raw64k.slice(raw64k.indexOf("\r\n\r\n") + 4));
    assert.equal(parsed64k.bodyLen, 64 * 1024);
    assert.equal(parsed64k.bodySha256, createHash("sha256").update(body64k).digest("hex"));

    // 3. Missing Content-Length on POST -> treated as 0-byte body
    const rawNoCl = await rawTcpExchange(port, "POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
    assert.match(rawNoCl, /^HTTP\/1\.1 200 OK\r\n/);
    assert.equal(JSON.parse(rawNoCl.slice(rawNoCl.indexOf("\r\n\r\n") + 4)).bodyLen, 0);

    // 4. Over-limit body (> 8 MiB request_most) -> rejected cleanly without crashing
    const overLimit = await rawTcpExchange(
      port,
      `POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: ${9 * 1024 * 1024}\r\n\r\nabc`,
    );
    assert.equal(overLimit, "", "over-limit request must be closed without 200");

    // 5. Malformed request lines & negative / non-numeric / overflowing Content-Length
    const malformedInputs = [
      "GARBAGE\r\n\r\n",
      "   \r\n\r\n",
      "POST /echo HTTP/1.1\r\nContent-Length: -10\r\n\r\n",
      "POST /echo HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
      "POST /echo HTTP/1.1\r\nContent-Length: 2147483647\r\n\r\n",
    ];
    for (const bad of malformedInputs) {
      const resp = await rawTcpExchange(port, bad);
      assert.equal(resp, "", `malformed request ${JSON.stringify(bad)} must be rejected/closed cleanly`);
    }

    // 6. Half-sent headers then RST/FIN, and half-sent body then RST/FIN
    await new Promise<void>((resolve) => {
      const s = netConnect(port, "127.0.0.1", () => {
        s.write("GET /echo HTTP/1.1\r\nHost: 127.0.0.1\r\n");
        s.resetAndDestroy();
        resolve();
      });
      s.on("error", () => resolve());
    });
    await new Promise<void>((resolve) => {
      const s = netConnect(port, "127.0.0.1", () => {
        s.write("POST /echo HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1000\r\n\r\npartial-body");
        s.end();
        s.on("close", () => resolve());
      });
      s.on("error", () => resolve());
    });

    // 7. Immediate subsequent valid request succeeds & no leaked active connections
    const health = await httpGetJson(port, "/health");
    assert.equal(health.status, 200);
    assert.equal(health.json.ok, true);
    assert.equal(health.json.active, 1, "no leaked in-flight handlers after RST/FIN disconnects");
  } finally {
    await h.close();
  }
});

test("HTTP client conformance (`host/http.mbt` `Host::fetch`): timeout cancels remote, 3xx manual redirect, non-UTF-8 bytes lossless", { skip: skipHarness }, async () => {
  let remoteClosed = false;
  let resolveRemoteClosed!: () => void;
  const remoteClosedPromise = new Promise<void>((r) => (resolveRemoteClosed = r));
  let targetHit = false;
  const rawBinary = Buffer.from([0x00, 0x80, 0xfe, 0xff, 0xc0, 0xaf, 0x01, 0x7f, 0xed, 0xa0, 0x80]);

  const srv = httpServer((req, res) => {
    if (req.url === "/hang") {
      req.on("close", () => {
        remoteClosed = true;
        resolveRemoteClosed();
      });
      // intentionally never respond
      return;
    }
    if (req.url === "/redir") {
      res.writeHead(302, { location: "/target" });
      res.end("redirecting");
      return;
    }
    if (req.url === "/target") {
      targetHit = true;
      res.writeHead(200);
      res.end("reached target");
      return;
    }
    if (req.url === "/binary") {
      res.writeHead(200, { "content-type": "application/octet-stream" });
      res.end(rawBinary);
      return;
    }
    res.writeHead(404);
    res.end();
  });
  await new Promise<void>((r) => srv.listen(0, "127.0.0.1", () => r()));
  const port = (srv.address() as any).port as number;
  const h = startHarness();
  try {
    // 1. Timeout triggers FetchTimeout AND cancels remote pending connection
    const timed = await h.ok("hostFetch", { url: `http://127.0.0.1:${port}/hang`, timeoutMs: 150 });
    assert.equal(timed.isTimeout, true, `expected FetchTimeout, got ${JSON.stringify(timed)}`);
    await Promise.race([
      remoteClosedPromise,
      new Promise<never>((_, rej) => setTimeout(() => rej(new Error("remote hanging request was never cancelled")), 3000)),
    ]);
    assert.equal(remoteClosed, true, "remote server must observe connection close on FetchTimeout");

    // 2. 3xx redirect manual mode: returns 302 with Location header and does NOT follow
    const redir = await h.ok("hostFetch", { url: `http://127.0.0.1:${port}/redir` });
    assert.equal(redir.status, 302);
    const loc = (redir.headers as [string, string][]).find(([k]) => k.toLowerCase() === "location")?.[1];
    assert.equal(loc, "/target");
    assert.equal(targetHit, false, "Host::fetch must not auto-follow 3xx redirects");

    // 3. Non-UTF-8 binary response body preserved losslessly
    const bin = await h.ok("hostFetch", { url: `http://127.0.0.1:${port}/binary` });
    assert.equal(bin.status, 200);
    assert.deepEqual(Buffer.from(bin.bodyBase64, "base64"), rawBinary);
  } finally {
    await h.close();
    srv.close();
  }
});

// ═══════════════════════════════════════════════════════════════════════════════
// 3. node:fs + node:child_process (`host_fs_op`, `sys.c`, `sys.mbt`) conformance
// ═══════════════════════════════════════════════════════════════════════════════

test("FS conformance (`live_dispatch.mbt` `host_fs_op`): copyFile/EXCL, wx, appendFile, stat vs lstat, readdir, rm, errno parity", { skip: skipHarness }, async () => {
  const h = startHarness();
  try {
    const dir = fresh("fs-conf");
    const extDir = fresh("fs-ext");
    const at = (n: string) => join(dir, n);
    const fsOp = (name: string, ...args: unknown[]) => h.ok("fsOp", { name, args });

    // 1. writeFile & flag: "wx" atomic exclusion -> EEXIST
    assert.deepEqual(await fsOp("writeFile", at("src.txt"), "hello-v1"), { ok: null });
    assert.equal((await fsOp("writeFile", at("src.txt"), "hello-v2", { flag: "wx" })).code, "EEXIST");
    assert.equal(readFileSync(at("src.txt"), "utf8"), "hello-v1");

    // 2. copyFile default overwrites existing target vs COPYFILE_EXCL -> EEXIST
    writeFileSync(at("dst.txt"), "old-target-longer-content");
    assert.equal((await fsOp("copyFile", at("src.txt"), at("dst.txt"), fsConstants.COPYFILE_EXCL)).code, "EEXIST");
    assert.equal(readFileSync(at("dst.txt"), "utf8"), "old-target-longer-content");
    assert.deepEqual(await fsOp("copyFile", at("src.txt"), at("dst.txt")), { ok: null });
    assert.equal(readFileSync(at("dst.txt"), "utf8"), "hello-v1");

    // 3. appendFile auto-creates new file and appends
    assert.deepEqual(await fsOp("appendFile", at("log.txt"), "line1\n"), { ok: null });
    assert.deepEqual(await fsOp("appendFile", at("log.txt"), "line2\n"), { ok: null });
    assert.equal(readFileSync(at("log.txt"), "utf8"), "line1\nline2\n");

    // 4. stat (follows symlink, dangling -> ENOENT) vs lstat (does NOT follow symlink)
    mkdirSync(at("sub"));
    symlinkSync(at("src.txt"), at("link-file"));
    symlinkSync(at("sub"), at("link-dir"));
    symlinkSync(at("does-not-exist"), at("dangling"));

    const stFile = (await fsOp("stat", at("link-file"))).ok;
    assert.equal(stFile.isFile, true);
    assert.equal(stFile.isDirectory, false);
    assert.equal(stFile.size, 8);
    assert.equal((await fsOp("stat", at("dangling"))).code, "ENOENT");

    const lstLink = (await fsOp("lstat", at("link-file"))).ok;
    assert.equal(lstLink.isSymbolicLink, true);
    assert.equal(lstLink.isFile, false);
    assert.equal(lstLink.isDirectory, false);
    const lstDangling = (await fsOp("lstat", at("dangling"))).ok;
    assert.equal(lstDangling.isSymbolicLink, true);
    assert.equal((await fsOp("lstat", at("truly-missing"))).code, "ENOENT");

    // 5. readdir({ withFileTypes: true }) / readdirTypes distinguishes file / dir / symlink
    const entries = (await fsOp("readdirTypes", dir)).ok as Array<{ name: string; isFile: boolean; isDirectory: boolean }>;
    const byName = new Map(entries.map((e) => [e.name, e]));
    assert.deepEqual(byName.get("src.txt"), { name: "src.txt", isFile: true, isDirectory: false });
    assert.deepEqual(byName.get("sub"), { name: "sub", isFile: false, isDirectory: true });
    assert.deepEqual(byName.get("link-file"), { name: "link-file", isFile: false, isDirectory: false });
    assert.deepEqual(byName.get("dangling"), { name: "dangling", isFile: false, isDirectory: false });

    // 6. Error code parity with Node node:fs: ENOENT, EEXIST, EISDIR, ENOTDIR
    assert.equal((await fsOp("readText", at("missing"))).code, "ENOENT");
    assert.equal((await fsOp("readText", at("sub"))).code, "EISDIR", "readText on directory must return EISDIR");
    assert.equal((await fsOp("writeFile", at("sub"), "x")).code, "EISDIR", "writeFile on directory must return EISDIR");
    assert.equal((await fsOp("readdir", at("src.txt"))).code, "ENOTDIR", "readdir on regular file must return ENOTDIR");
    assert.equal((await fsOp("readdirTypes", at("src.txt"))).code, "ENOTDIR", "readdirTypes on regular file must return ENOTDIR");

    // 7. rm({ recursive: true, force: true }) removes nested tree including read-only file & symlink without following external dir
    writeFileSync(join(extDir, "keep.txt"), "must-survive");
    mkdirSync(at("tree/nested"), { recursive: true });
    writeFileSync(at("tree/nested/ro.txt"), "readonly");
    chmodSync(at("tree/nested/ro.txt"), 0o444);
    symlinkSync(extDir, at("tree/ext-link"));
    assert.deepEqual(await fsOp("rm", at("tree"), { recursive: true, force: true }), { ok: null });
    assert.equal(existsSync(at("tree")), false);
    assert.equal(readFileSync(join(extDir, "keep.txt"), "utf8"), "must-survive", "rm must not follow symlinks into external dir");
    // rm on non-existent path with force: true does not error
    assert.deepEqual(await fsOp("rm", at("never-existed"), { recursive: true, force: true }), { ok: null });
  } finally {
    await h.close();
  }
});

test("child_process & fileLock conformance (`sys.c` / `sys.mbt`): process group kill, >256KiB stdout, exit/signal, lock mutual exclusion", { skip: skipHarness }, async () => {
  const h1 = startHarness();
  const h2 = startHarness();
  try {
    const dir = fresh("proc-conf");

    // 1. Exit code accuracy
    const rExit = await h1.ok("spawn", { program: "/bin/sh", args: ["-c", "exit 42"] });
    assert.equal(rExit.code, 42);
    assert.equal(rExit.signal, null);

    // 2. Large stdout (> 256 KiB: 512 KiB) without pipe deadlock
    const rBig = await h1.ok("spawn", {
      program: "/bin/sh",
      args: ["-c", "dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\0' 'A'"],
    });
    assert.equal(rBig.code, 0);
    assert.equal(rBig.stdout.length, 512 * 1024, "512 KiB stdout must arrive intact without deadlock");
    assert.equal(rBig.stdout[0], "A");
    assert.equal(rBig.stdout[512 * 1024 - 1], "A");

    // 3. Process group kill cleans up both child AND grandchild (no orphan left alive)
    const pidFile = join(dir, "grandchild.pid");
    const detached = await h1.ok("spawn", {
      program: "/bin/sh",
      args: ["-c", `sleep 60 & echo $! > "${pidFile}"; wait`],
      group: true,
      detach: true,
    });
    const childPid = detached.pid as number;
    // Wait until grandchild pid file is written
    let grandchildPid = 0;
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      if (existsSync(pidFile)) {
        const raw = readFileSync(pidFile, "utf8").trim();
        if (/^\d+$/.test(raw)) {
          grandchildPid = Number(raw);
          break;
        }
      }
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.ok(grandchildPid > 0, "grandchild pid must be recorded");
    assert.equal(await h1.ok("pidAlive", { pid: grandchildPid }), true, "grandchild alive before group kill");
    assert.equal(await h1.ok("kill", { pid: childPid, signal: "SIGKILL", group: true }), true);
    // Poll briefly until kernel reaps both
    const reapDeadline = Date.now() + 3000;
    while (Date.now() < reapDeadline) {
      const aliveChild = await h1.ok("pidAlive", { pid: childPid });
      const aliveGrand = await h1.ok("pidAlive", { pid: grandchildPid });
      if (!aliveChild && !aliveGrand) break;
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.equal(await h1.ok("pidAlive", { pid: childPid }), false, "child must be dead after group SIGKILL");
    assert.equal(await h1.ok("pidAlive", { pid: grandchildPid }), false, "grandchild must be dead (no orphan) after group SIGKILL");

    // 4. Signal reporting on non-detached child killed with SIGTERM
    const sigPidFile = join(dir, "sig.pid");
    const sigPromise = h1.ok("spawn", {
      program: "/bin/sh",
      args: ["-c", `echo $$ > "${sigPidFile}"; exec sleep 60`],
    });
    let sigPid = 0;
    const sigDeadline = Date.now() + 5000;
    while (Date.now() < sigDeadline) {
      if (existsSync(sigPidFile)) {
        const raw = readFileSync(sigPidFile, "utf8").trim();
        if (/^\d+$/.test(raw)) {
          sigPid = Number(raw);
          break;
        }
      }
      await new Promise((r) => setTimeout(r, 25));
    }
    assert.ok(sigPid > 0, "target pid recorded");
    assert.equal(await h2.ok("kill", { pid: sigPid, signal: "SIGTERM", group: false }), true);
    const sigRes = await sigPromise;
    assert.equal(sigRes.code, null);
    assert.equal(sigRes.signal, "SIGTERM");

    // 5. Two separate processes competing for the same fileLock are mutually exclusive
    const lockPath = join(dir, "shared.lock");
    const l1 = await h1.ok("fileLock", { path: lockPath });
    let h2Acquired = false;
    const l2Promise = h2.ok("fileLock", { path: lockPath }).then((res) => {
      h2Acquired = true;
      return res;
    });
    // Give h2 enough time to attempt flock; it MUST stay blocked while h1 holds it
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(h2Acquired, false, "second process must block while first holds fileLock");
    assert.equal(await h1.ok("fileUnlock", { handle: l1.handle }), true);
    const l2 = await l2Promise;
    assert.equal(h2Acquired, true, "second process acquires fileLock once first releases it");
    assert.equal(await h2.ok("fileUnlock", { handle: l2.handle }), true);
  } finally {
    await h1.close();
    await h2.close();
  }
});
