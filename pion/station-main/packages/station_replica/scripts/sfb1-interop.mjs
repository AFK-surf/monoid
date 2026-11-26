#!/usr/bin/env node
// Cross-engine byte-for-byte interop test between real Node `station/src/replica/crypto.ts`
// and Pion `pion/station-main/packages/station_replica/src/crypto.pion`.
//
// Verifies:
//   1. Node sfb1Seal -> Pion sfb1_open (empty, single-frame, multi-frame, exact-boundary, binary)
//   2. Pion sfb1_seal -> Node sfb1Open (byte-for-byte ciphertext equality + Node decryption)
//   3. Pion Sfb1StreamSealer -> Node sfb1Open

import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseEncryptionKey, sfb1Open, sfb1Seal } from "../../../../../station/src/replica/crypto.ts";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "../../../../..");
const pkgDir = resolve(__dirname, "..");

const ensureRes = spawnSync("bash", [join(repoRoot, "pion/station/scripts/ensure-pionc.sh")], {
  encoding: "utf8",
});
const ensureOut = `${ensureRes.stdout ?? ""}\n${ensureRes.stderr ?? ""}`;
const pioncMatch = /pionc=(\S+)/.exec(ensureOut);
if (!pioncMatch) {
  throw new Error(`Could not locate pionc from ensure-pionc.sh output: ${ensureOut}`);
}
const pionc = pioncMatch[1];

const keyHex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const key = parseEncryptionKey(keyHex);
const ctx = {
  ws: "ws_interop_01",
  origin: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  logicalPath: "files/00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
};

const cases = [
  { name: "empty", saltHex: "00112233445566778899aabbccddeeff", frameMax: 16, plain: Buffer.alloc(0) },
  { name: "single_ascii", saltHex: "102132435465768798a9bacbdcedfe0f", frameMax: 64, plain: Buffer.from("hello still.fail SFB1!", "utf8") },
  {
    name: "multi_frame_utf8",
    saltHex: "ffeeddccbbaa99887766554433221100",
    frameMax: 16,
    plain: Buffer.from("SFB1 cross-engine ChaCha20-Poly1305: 你好世界 0123456789abcdef!", "utf8"),
  },
  {
    name: "exact_boundary_32",
    saltHex: "cafebabedeadbeef0123456789abcdef",
    frameMax: 16,
    plain: Buffer.from(Array.from({ length: 32 }, (_, i) => (i * 17 + 3) & 0xff)),
  },
];

// 1. Seal every case with REAL Node `station/src/replica/crypto.ts`.
const nodeVectors = cases.map((c) => {
  const salt = Buffer.from(c.saltHex, "hex");
  const sealed = sfb1Seal(key, ctx, c.plain, { salt, frameMax: c.frameMax });
  // Sanity-check Node self-roundtrip.
  const opened = sfb1Open(key, ctx, sealed);
  if (!opened.equals(c.plain)) {
    throw new Error(`Node self-roundtrip failed for ${c.name}`);
  }
  return {
    ...c,
    plainHex: c.plain.toString("hex"),
    sealedHex: sealed.toString("hex"),
  };
});

// 2. Build a tiny temporary Pion executable importing `station_replica` to run Pion open & seal.
const work = mkdtempSync(join(tmpdir(), "sfb1-interop-"));
try {
  copyFileSync(join(repoRoot, "pion/station-main/pion.lock"), join(work, "pion.lock"));
  writeFileSync(
    join(work, "pion.toml"),
    `[workspace]
members = ["app"]

[workspace.dependencies]
base64 = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "base64-v0.1.0", subdir = "packages/base64" }
crypto = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "crypto-v0.4.1", subdir = "packages/crypto" }
effect = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "effect-v0.1.0", subdir = "packages/effect" }
flate = { git = "https://github.com/AFK-surf/pion-packages.git", tag = "flate-v0.1.0", subdir = "packages/flate" }
base_codec = { path = "${join(repoRoot, "pion/base/packages/base_codec")}" }
host_shim = { path = "${join(repoRoot, "pion/station/packages/host_shim")}" }
sqlite_ffi = { path = "${join(repoRoot, "pion/station/packages/sqlite_ffi")}" }
sql_db = { path = "${join(repoRoot, "pion/station/packages/sql_db")}" }
js_json = { path = "${join(repoRoot, "pion/station/packages/js_json")}" }
nodepath = { path = "${join(repoRoot, "pion/station/packages/nodepath")}" }
station_conv = { path = "${join(repoRoot, "pion/station/packages/station_conv")}" }
builders_core = { path = "${join(repoRoot, "pion/station/packages/builders_core")}" }
station_sys = { path = "${join(repoRoot, "pion/station-main/packages/station_sys")}" }
memory = { path = "${join(repoRoot, "pion/station/packages/memory")}" }
station_replica = { path = "${pkgDir}" }
`,
  );
  const appDir = join(work, "app");
  const srcDir = join(appDir, "src");
  execFileSync("mkdir", ["-p", srcDir]);
  writeFileSync(
    join(appDir, "pion.toml"),
    `[package]
name = "sfb1_interop_harness"
version = "0.1.0"

[dependencies]
crypto = { workspace = true }
station_replica = { workspace = true }
`,
  );

  // Build Pion assertions verifying Node->Pion open AND emitting Pion-sealed hex for Node->open.
  const pionCases = nodeVectors
    .map(
      (v) => `  {
    let plain = match crypto::hex_to_bytes("${v.plainHex}") { Some(b) => b, None => Bytes::new(0) }
    let salt = match crypto::hex_to_bytes("${v.saltHex}") { Some(b) => b, None => Bytes::new(0) }
    let node_sealed = match crypto::hex_to_bytes("${v.sealedHex}") { Some(b) => b, None => Bytes::new(0) }
    // Direction A: Node-sealed -> Pion sfb1_open
    let opened = match station_replica::sfb1_open(key, ctx, node_sealed) {
      Ok(b) => b
      Err(e) => panic("Pion failed to open Node ciphertext for ${v.name}: " + e)
    }
    if crypto::bytes_to_hex(opened) != "${v.plainHex}" {
      panic("Plaintext mismatch on Node->Pion for ${v.name}")
    }
    // Direction B: Pion sfb1_seal -> exact byte-for-byte parity with Node sfb1Seal
    let pion_sealed = match station_replica::sfb1_seal(key, ctx, plain, salt, frame_max=${v.frameMax}) {
      Ok(b) => b
      Err(e) => panic("Pion failed to seal ${v.name}: " + e)
    }
    if crypto::bytes_to_hex(pion_sealed) != "${v.sealedHex}" {
      panic("Ciphertext mismatch on Pion->Node for ${v.name}")
    }
    // Direction C: Pion Sfb1StreamSealer -> exact byte-for-byte parity with Node sfb1Seal
    let sealer = match station_replica::Sfb1StreamSealer::new(key, ctx, salt, frame_max=${v.frameMax}) {
      Ok(s) => s
      Err(e) => panic(e)
    }
    let parts : Array[Bytes] = []
    match sealer.push(plain) {
      Ok(ps) => {
        for i in 0..<ps.length() {
          parts.push(ps[i])
        }
      }
      Err(e) => panic(e)
    }
    match sealer.finish() {
      Ok(ps) => {
        for i in 0..<ps.length() {
          parts.push(ps[i])
        }
      }
      Err(e) => panic(e)
    }
    let mut total = 0
    for i in 0..<parts.length() {
      total = total + parts[i].length()
    }
    let joined = Bytes::new(total)
    let mut off = 0
    for i in 0..<parts.length() {
      let p = parts[i]
      for j in 0..<p.length() {
        joined[off + j] = p[j]
      }
      off = off + p.length()
    }
    if crypto::bytes_to_hex(joined) != "${v.sealedHex}" {
      panic("Streaming ciphertext mismatch on Pion->Node for ${v.name}")
    }
  }`,
    )
    .join("\n");

  writeFileSync(
    join(srcDir, "interop_test.pion"),
    `import "crypto"
import "station_replica"

test "sfb1 cross-engine node <-> pion byte-for-byte parity" {
  let key = match station_replica::parse_encryption_key("${keyHex}") {
    Ok(k) => k
    Err(e) => panic(e)
  }
  let ctx = station_replica::Sfb1Context::{
    ws: "${ctx.ws}",
    origin: "${ctx.origin}",
    logical_path: "${ctx.logicalPath}",
  }
${pionCases}
}
`,
  );

  const testOut = execFileSync(pionc, ["test", "--json", "--package", "sfb1_interop_harness", work], {
    encoding: "utf8",
  });
  const parsed = JSON.parse(testOut.trim().split("\n").pop());
  if (!parsed.ok) {
    throw new Error(`Pion interop test failed: ${testOut}`);
  }
  for (const vec of nodeVectors) {
    const nodeOpened = sfb1Open(key, ctx, Buffer.from(vec.sealedHex, "hex"));
    if (!nodeOpened.equals(vec.plain)) {
      throw new Error(`Node failed to decrypt Pion-matched ciphertext for ${vec.name}`);
    }
    console.log(`OK [Node<->Pion SFB1] ${vec.name}: ${vec.sealedHex.length / 2} bytes byte-identical & mutually decrypted (one-shot + streaming)`);
  }
  console.log(`ALL ${nodeVectors.length} SFB1 CROSS-ENGINE INTEROP VECTORS PASSED!`);
} finally {
  rmSync(work, { recursive: true, force: true });
}
