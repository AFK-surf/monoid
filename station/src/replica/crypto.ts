// SFB1 streaming end-to-end encryption for S3/R2 backups (ChaCha20-Poly1305 + HMAC-SHA256 nonces).
// Binary layout (100% byte-identical with station/mb/src/replica_coord/s3_crypto.mbt):
//   Header (20 bytes): "SFB1" (4 bytes) || salt (16 bytes)
//   Frames (i = 0, 1, ...):
//     plainLen (uint32 BE, 4 bytes) || flags (1 byte: 0x00 non-final, 0x01 final) || ciphertext (plainLen) || tag (16)
//   Empty input encodes as 1 frame with plainLen = 0, flags = 0x01.
//   Frame i nonce (12 bytes): HMAC-SHA256(key32, salt || uint32be(i))[0..12]
//   Frame i AAD (UTF-8): `${ws}\n${origin}\n${logicalPath}\n${i}\n${isFinal ? "1" : "0"}`
import { createCipheriv, createDecipheriv, createHmac, randomBytes } from "node:crypto";

export const SFB1_MAGIC = Buffer.from("SFB1", "ascii");
export const SFB1_SALT_LEN = 16;
export const SFB1_HEADER_LEN = SFB1_MAGIC.length + SFB1_SALT_LEN;
export const SFB1_TAG_LEN = 16;
export const SFB1_FRAME_HEADER_LEN = 5;
export const FRAME_PLAIN_MAX = 4 * 1024 * 1024;
export const FLAG_MORE = 0x00;
export const FLAG_FINAL = 0x01;

export type Sfb1Context = {
  ws: string;
  origin: string;
  logicalPath: string;
};

export function parseEncryptionKey(hex: string): Buffer {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new Error("encryptionKey must be a 64-character lowercase hex string");
  return Buffer.from(hex, "hex");
}

export function frameNonce(key: Buffer, salt: Buffer, index: number): Buffer {
  const idx = Buffer.allocUnsafe(4);
  idx.writeUInt32BE(index >>> 0, 0);
  return createHmac("sha256", key).update(salt).update(idx).digest().subarray(0, 12);
}

export function frameAad(ctx: Sfb1Context, index: number, isFinal: boolean): Buffer {
  return Buffer.from(`${ctx.ws}\n${ctx.origin}\n${ctx.logicalPath}\n${index}\n${isFinal ? "1" : "0"}`, "utf8");
}

function sealFrame(key: Buffer, salt: Buffer, ctx: Sfb1Context, index: number, plain: Buffer, isFinal: boolean): Buffer {
  const nonce = frameNonce(key, salt, index);
  const aad = frameAad(ctx, index, isFinal);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: SFB1_TAG_LEN });
  cipher.setAAD(aad, { plaintextLength: plain.length });
  const enc = cipher.update(plain);
  const fin = cipher.final();
  const tag = cipher.getAuthTag();
  const header = Buffer.allocUnsafe(SFB1_FRAME_HEADER_LEN);
  header.writeUInt32BE(plain.length >>> 0, 0);
  header[4] = isFinal ? FLAG_FINAL : FLAG_MORE;
  return Buffer.concat([header, enc, fin, tag]);
}

function openFrame(key: Buffer, salt: Buffer, ctx: Sfb1Context, index: number, sealed: Buffer, isFinal: boolean): Buffer {
  if (sealed.length < SFB1_TAG_LEN) throw new Error("SFB1 frame truncated");
  const cipherLen = sealed.length - SFB1_TAG_LEN;
  const ciphertext = sealed.subarray(0, cipherLen);
  const tag = sealed.subarray(cipherLen);
  const nonce = frameNonce(key, salt, index);
  const aad = frameAad(ctx, index, isFinal);
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: SFB1_TAG_LEN });
  decipher.setAuthTag(tag);
  decipher.setAAD(aad, { plaintextLength: cipherLen });
  const a = decipher.update(ciphertext);
  const b = decipher.final();
  return b.length === 0 ? a : Buffer.concat([a, b]);
}

/// Encrypts a whole buffer in SFB1 format.
export function sfb1Seal(
  key: Buffer,
  ctx: Sfb1Context,
  plain: Buffer,
  opts?: { salt?: Buffer; frameMax?: number },
): Buffer {
  if (key.length !== 32) throw new Error("SFB1 key must be 32 bytes");
  const frameMax = opts?.frameMax ?? FRAME_PLAIN_MAX;
  if (frameMax <= 0 || frameMax > FRAME_PLAIN_MAX) throw new Error("invalid SFB1 frameMax");
  const salt = opts?.salt ?? randomBytes(SFB1_SALT_LEN);
  if (salt.length !== SFB1_SALT_LEN) throw new Error("SFB1 salt must be 16 bytes");

  const parts: Buffer[] = [SFB1_MAGIC, salt];
  if (plain.length === 0) {
    parts.push(sealFrame(key, salt, ctx, 0, Buffer.alloc(0), true));
    return Buffer.concat(parts);
  }
  let offset = 0;
  let index = 0;
  while (offset < plain.length) {
    const end = Math.min(offset + frameMax, plain.length);
    const isFinal = end >= plain.length;
    parts.push(sealFrame(key, salt, ctx, index, plain.subarray(offset, end), isFinal));
    offset = end;
    index++;
  }
  return Buffer.concat(parts);
}

/// Decrypts a whole SFB1 buffer, verifying magic, all frame tags, final flag, and no trailing bytes.
export function sfb1Open(key: Buffer, ctx: Sfb1Context, data: Buffer): Buffer {
  if (key.length !== 32) throw new Error("SFB1 key must be 32 bytes");
  if (data.length < SFB1_HEADER_LEN) throw new Error("SFB1 data too short");
  if (!data.subarray(0, 4).equals(SFB1_MAGIC)) throw new Error("invalid SFB1 magic");
  const salt = data.subarray(4, SFB1_HEADER_LEN);

  const out: Buffer[] = [];
  let offset = SFB1_HEADER_LEN;
  let index = 0;
  let sawFinal = false;
  while (offset < data.length) {
    if (sawFinal) throw new Error("trailing bytes after final SFB1 frame");
    if (offset + SFB1_FRAME_HEADER_LEN > data.length) throw new Error("truncated SFB1 frame header");
    const plainLen = data.readUInt32BE(offset);
    const flags = data[offset + 4]!;
    if (flags !== FLAG_MORE && flags !== FLAG_FINAL) throw new Error(`invalid SFB1 frame flags: ${flags}`);
    if (plainLen > FRAME_PLAIN_MAX) throw new Error(`SFB1 frame too large: ${plainLen}`);
    offset += SFB1_FRAME_HEADER_LEN;
    const sealedLen = plainLen + SFB1_TAG_LEN;
    if (offset + sealedLen > data.length) throw new Error("truncated SFB1 frame payload");
    const isFinal = flags === FLAG_FINAL;
    out.push(openFrame(key, salt, ctx, index, data.subarray(offset, offset + sealedLen), isFinal));
    offset += sealedLen;
    index++;
    if (isFinal) sawFinal = true;
  }
  if (!sawFinal) throw new Error("truncated SFB1 stream: missing final frame");
  return out.length === 1 ? out[0]! : Buffer.concat(out);
}

/// Streaming SFB1 encryption: yields header followed by sealed frames of at most `frameMax` plaintext bytes.
/// Keeps memory bounded to ~1 frame regardless of input size.
export async function* sfb1SealStream(
  key: Buffer,
  ctx: Sfb1Context,
  chunks: AsyncIterable<Buffer>,
  opts?: { salt?: Buffer; frameMax?: number },
): AsyncIterable<Buffer> {
  if (key.length !== 32) throw new Error("SFB1 key must be 32 bytes");
  const frameMax = opts?.frameMax ?? FRAME_PLAIN_MAX;
  if (frameMax <= 0 || frameMax > FRAME_PLAIN_MAX) throw new Error("invalid SFB1 frameMax");
  const salt = opts?.salt ?? randomBytes(SFB1_SALT_LEN);
  if (salt.length !== SFB1_SALT_LEN) throw new Error("SFB1 salt must be 16 bytes");

  yield Buffer.concat([SFB1_MAGIC, salt]);

  let pending: Buffer[] = [];
  let pendingLen = 0;
  let index = 0;

  const take = (n: number): Buffer => {
    if (pending.length === 1 && pending[0]!.length === n) {
      const b = pending[0]!;
      pending = [];
      pendingLen = 0;
      return b;
    }
    const all = Buffer.concat(pending, pendingLen);
    const head = all.subarray(0, n);
    const rest = all.subarray(n);
    pending = rest.length > 0 ? [rest] : [];
    pendingLen = rest.length;
    return head;
  };

  for await (const chunk of chunks) {
    if (chunk.length === 0) continue;
    pending.push(chunk);
    pendingLen += chunk.length;
    // Always keep at least 1 byte buffered until EOF so we know whether the current frame is final.
    while (pendingLen > frameMax) {
      yield sealFrame(key, salt, ctx, index++, take(frameMax), false);
    }
  }

  const last = pendingLen === 0 ? Buffer.alloc(0) : pending.length === 1 ? pending[0]! : Buffer.concat(pending, pendingLen);
  yield sealFrame(key, salt, ctx, index, last, true);
}

/// Streaming SFB1 decryption: verifies header, every frame's Poly1305 tag, final flag, and rejects trailing bytes.
export async function* sfb1OpenStream(
  key: Buffer,
  ctx: Sfb1Context,
  chunks: AsyncIterable<Buffer>,
): AsyncIterable<Buffer> {
  if (key.length !== 32) throw new Error("SFB1 key must be 32 bytes");
  let buf: Buffer<ArrayBufferLike> = Buffer.alloc(0);
  let salt: Buffer | null = null;
  let index = 0;
  let sawFinal = false;

  for await (const chunk of chunks) {
    if (chunk.length === 0) continue;
    if (sawFinal) throw new Error("trailing bytes after final SFB1 frame");
    buf = buf.length === 0 ? chunk : Buffer.concat([buf, chunk]);

    if (salt === null) {
      if (buf.length < SFB1_HEADER_LEN) continue;
      if (!buf.subarray(0, 4).equals(SFB1_MAGIC)) throw new Error("invalid SFB1 magic");
      salt = Buffer.from(buf.subarray(4, SFB1_HEADER_LEN));
      buf = buf.subarray(SFB1_HEADER_LEN);
    }

    while (buf.length >= SFB1_FRAME_HEADER_LEN) {
      if (sawFinal) throw new Error("trailing bytes after final SFB1 frame");
      const plainLen = buf.readUInt32BE(0);
      const flags = buf[4]!;
      if (flags !== FLAG_MORE && flags !== FLAG_FINAL) throw new Error(`invalid SFB1 frame flags: ${flags}`);
      if (plainLen > FRAME_PLAIN_MAX) throw new Error(`SFB1 frame too large: ${plainLen}`);
      const frameTotal = SFB1_FRAME_HEADER_LEN + plainLen + SFB1_TAG_LEN;
      if (buf.length < frameTotal) break;
      const isFinal = flags === FLAG_FINAL;
      const plain = openFrame(key, salt, ctx, index++, buf.subarray(SFB1_FRAME_HEADER_LEN, frameTotal), isFinal);
      buf = buf.subarray(frameTotal);
      if (isFinal) sawFinal = true;
      if (plain.length > 0) yield plain;
    }
  }

  if (salt === null || !sawFinal || buf.length > 0) {
    throw new Error("truncated SFB1 stream");
  }
}
