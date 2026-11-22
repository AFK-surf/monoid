// SFB1 streaming end-to-end encryption for S3/R2 backups (byte-identical with station/src/replica/crypto.ts).
// Header (20 bytes): "SFB1" || salt (16 bytes)
// Frames (i = 0, 1, ...):
//   plainLen (uint32 BE) || flags (0x00 non-final, 0x01 final) || ciphertext (plainLen) || tag (16)
// Empty input encodes as 1 frame with plainLen = 0, flags = 0x01.
// Frame i nonce (12 bytes): HMAC-SHA256(key32, salt || uint32be(i))[0..12]
// Frame i AAD (UTF-8): `${ws}\n${origin}\n${logicalPath}\n${i}\n${isFinal ? "1" : "0"}`

///|
pub let sfb1_magic : Bytes = b"SFB1"

///|
pub let sfb1_salt_len : Int = 16

///|
pub let sfb1_header_len : Int = 20

///|
pub let sfb1_tag_len : Int = 16

///|
pub let sfb1_frame_header_len : Int = 5

///|
pub let sfb1_frame_plain_max : Int = 4194304

///|
pub let sfb1_flag_more : Byte = b'\x00'

///|
pub let sfb1_flag_final : Byte = b'\x01'

///|
pub fn parse_encryption_key(hex : String) -> Bytes raise {
  if !is_enc_key(hex) {
    raise failed("encryptionKey must be a 64-character lowercase hex string")
  }
  match @hash.hex_decode(hex) {
    Some(b) if b.length() == 32 => b
    _ => raise failed("encryptionKey must be a 64-character lowercase hex string")
  }
}

///|
fn u32_be(n : Int) -> Bytes {
  let u = n.reinterpret_as_uint()
  Bytes::from_array([
    ((u >> 24) & 0xFFU).to_byte(),
    ((u >> 16) & 0xFFU).to_byte(),
    ((u >> 8) & 0xFFU).to_byte(),
    (u & 0xFFU).to_byte(),
  ])
}

///|
fn read_u32_be(b : BytesView, off : Int) -> Int {
  let v : UInt = (b[off].to_uint() << 24) |
    (b[off + 1].to_uint() << 16) |
    (b[off + 2].to_uint() << 8) |
    b[off + 3].to_uint()
  v.reinterpret_as_int()
}

///|
pub fn sfb1_frame_nonce(key : Bytes, salt : Bytes, index : Int) -> Bytes {
  let msg = @buffer.new(size_hint=20)
  msg.write_bytes(salt)
  msg.write_bytes(u32_be(index))
  let mac = @hash.hmac_sha256(key[:], msg.to_bytes()[:])
  mac[0:12].to_bytes()
}

///|
pub fn sfb1_frame_aad(ws : String, origin : String, logical_path : String, index : Int, is_final : Bool) -> Bytes {
  let f = if is_final { "1" } else { "0" }
  @utf8.encode("\{ws}\n\{origin}\n\{logical_path}\n\{index}\n\{f}")
}

///|
fn sfb1_seal_frame(
  crypto : @vault_crypto.Crypto,
  key : Bytes,
  salt : Bytes,
  ws : String,
  origin : String,
  logical_path : String,
  index : Int,
  plain : BytesView,
  is_final : Bool,
) -> Bytes raise {
  let nonce = sfb1_frame_nonce(key, salt, index)
  let aad = sfb1_frame_aad(ws, origin, logical_path, index, is_final)
  let sealed = crypto.chacha_seal(key[:], nonce[:], aad[:], plain) catch {
    e => raise failed("SFB1 seal failed: \{e}")
  }
  let out = @buffer.new(size_hint=sfb1_frame_header_len + sealed.length())
  out.write_bytes(u32_be(plain.length()))
  out.write_byte(if is_final { sfb1_flag_final } else { sfb1_flag_more })
  out.write_bytes(sealed)
  out.to_bytes()
}

///|
fn sfb1_open_frame(
  crypto : @vault_crypto.Crypto,
  key : Bytes,
  salt : Bytes,
  ws : String,
  origin : String,
  logical_path : String,
  index : Int,
  sealed : BytesView,
  is_final : Bool,
) -> Bytes raise {
  if sealed.length() < sfb1_tag_len {
    raise failed("SFB1 frame truncated")
  }
  let nonce = sfb1_frame_nonce(key, salt, index)
  let aad = sfb1_frame_aad(ws, origin, logical_path, index, is_final)
  let opened = crypto.chacha_open(key[:], nonce[:], aad[:], sealed) catch {
    e => raise failed("SFB1 open failed: \{e}")
  }
  match opened {
    Some(plain) => plain
    None => raise failed("SFB1 authentication failed")
  }
}

///|
/// Encrypts a whole buffer in SFB1 format.
pub fn sfb1_seal(
  crypto : @vault_crypto.Crypto,
  key : Bytes,
  ws : String,
  origin : String,
  logical_path : String,
  plain : Bytes,
  salt? : Bytes,
  frame_max? : Int = sfb1_frame_plain_max,
) -> Bytes raise {
  if key.length() != 32 {
    raise failed("SFB1 key must be 32 bytes")
  }
  if frame_max <= 0 || frame_max > sfb1_frame_plain_max {
    raise failed("invalid SFB1 frame_max")
  }
  let salt_bytes = match salt {
    Some(s) => s
    None =>
      crypto.random(sfb1_salt_len) catch {
        e => raise failed("SFB1 random failed: \{e}")
      }
  }
  if salt_bytes.length() != sfb1_salt_len {
    raise failed("SFB1 salt must be 16 bytes")
  }
  let out = @buffer.new(size_hint=sfb1_header_len + plain.length() + 32)
  out.write_bytes(sfb1_magic)
  out.write_bytes(salt_bytes)
  if plain.length() == 0 {
    out.write_bytes(sfb1_seal_frame(crypto, key, salt_bytes, ws, origin, logical_path, 0, b""[:], true))
    return out.to_bytes()
  }
  let mut offset = 0
  let mut index = 0
  while offset < plain.length() {
    let end = if offset + frame_max < plain.length() { offset + frame_max } else { plain.length() }
    let is_final = end >= plain.length()
    out.write_bytes(sfb1_seal_frame(crypto, key, salt_bytes, ws, origin, logical_path, index, plain[offset:end], is_final))
    offset = end
    index += 1
  }
  out.to_bytes()
}

///|
/// Decrypts a whole SFB1 buffer, verifying magic, all frame tags, final flag, and no trailing bytes.
pub fn sfb1_open(
  crypto : @vault_crypto.Crypto,
  key : Bytes,
  ws : String,
  origin : String,
  logical_path : String,
  data : Bytes,
) -> Bytes raise {
  if key.length() != 32 {
    raise failed("SFB1 key must be 32 bytes")
  }
  if data.length() < sfb1_header_len {
    raise failed("SFB1 data too short")
  }
  if data[0:4].to_bytes() != sfb1_magic {
    raise failed("invalid SFB1 magic")
  }
  let salt = data[4:sfb1_header_len].to_bytes()
  let out = @buffer.new()
  let mut offset = sfb1_header_len
  let mut index = 0
  let mut saw_final = false
  while offset < data.length() {
    if saw_final {
      raise failed("trailing bytes after final SFB1 frame")
    }
    if offset + sfb1_frame_header_len > data.length() {
      raise failed("truncated SFB1 frame header")
    }
    let plain_len = read_u32_be(data[:], offset)
    let flags = data[offset + 4]
    if flags != sfb1_flag_more && flags != sfb1_flag_final {
      raise failed("invalid SFB1 frame flags")
    }
    if plain_len < 0 || plain_len > sfb1_frame_plain_max {
      raise failed("SFB1 frame too large")
    }
    offset += sfb1_frame_header_len
    let sealed_len = plain_len + sfb1_tag_len
    if offset + sealed_len > data.length() {
      raise failed("truncated SFB1 frame payload")
    }
    let is_final = flags == sfb1_flag_final
    let plain = sfb1_open_frame(crypto, key, salt, ws, origin, logical_path, index, data[offset:offset + sealed_len], is_final)
    out.write_bytes(plain)
    offset += sealed_len
    index += 1
    if is_final {
      saw_final = true
    }
  }
  if !saw_final {
    raise failed("truncated SFB1 stream: missing final frame")
  }
  out.to_bytes()
}

///|
/// Streaming SFB1 encryption over a chunk reader (returns a chunk reader yielding header + sealed frames).
pub fn sfb1_seal_stream(
  crypto : @vault_crypto.Crypto,
  key : Bytes,
  ws : String,
  origin : String,
  logical_path : String,
  next_plain : async () -> Bytes?,
  salt? : Bytes,
  frame_max? : Int = sfb1_frame_plain_max,
) -> (async () -> Bytes?) raise {
  if key.length() != 32 {
    raise failed("SFB1 key must be 32 bytes")
  }
  if frame_max <= 0 || frame_max > sfb1_frame_plain_max {
    raise failed("invalid SFB1 frame_max")
  }
  let salt_bytes = match salt {
    Some(s) => s
    None =>
      crypto.random(sfb1_salt_len) catch {
        e => raise failed("SFB1 random failed: \{e}")
      }
  }
  if salt_bytes.length() != sfb1_salt_len {
    raise failed("SFB1 salt must be 16 bytes")
  }
  let sent_header = Ref(false)
  let eof = Ref(false)
  let done = Ref(false)
  let index = Ref(0)
  let pending : Ref[Bytes] = Ref(b"")

  async fn() {
    if done.val {
      return None
    }
    if !sent_header.val {
      sent_header.val = true
      let h = @buffer.new(size_hint=sfb1_header_len)
      h.write_bytes(sfb1_magic)
      h.write_bytes(salt_bytes)
      return Some(h.to_bytes())
    }
    while !eof.val && pending.val.length() <= frame_max {
      match next_plain() {
        Some(chunk) =>
          if chunk.length() > 0 {
            let b = @buffer.new(size_hint=pending.val.length() + chunk.length())
            b.write_bytes(pending.val)
            b.write_bytes(chunk)
            pending.val = b.to_bytes()
          }
        None => eof.val = true
      }
    }
    if pending.val.length() > frame_max {
      let cur = pending.val
      let frame_plain = cur[0:frame_max]
      pending.val = cur[frame_max:].to_bytes()
      let i = index.val
      index.val = i + 1
      return Some(sfb1_seal_frame(crypto, key, salt_bytes, ws, origin, logical_path, i, frame_plain, false))
    }
    done.val = true
    let last = pending.val
    pending.val = b""
    let i = index.val
    index.val = i + 1
    Some(sfb1_seal_frame(crypto, key, salt_bytes, ws, origin, logical_path, i, last[:], true))
  }
}
