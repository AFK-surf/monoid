// Deflate's two wrappings: zlib's (RFC 1950: a head of two bytes, the Adler-32 of what was deflated after it) and
// gzip's (RFC 1952: a head with what it may say of the file, the CRC-32 and length after it), made and undone, the
// checks each says checked. The CRC-32 is the base's (`@codec.crc32`).

///|
/// Adler-32's modulus.
let adler_base : UInt = 65521

///|
/// The Adler-32 of what gave `adler` followed by `data`: start from 1 (the Adler-32 of nothing) and give each piece in
/// turn, as zlib's `adler32(adler, buf, len)`.
pub fn adler32_update(adler : UInt, data : BytesView) -> UInt {
  let mut a = adler & 0xFFFFU
  let mut b = adler >> 16
  let mut at = 0
  while at < data.length() {
    // 5552 bytes at most before the sums are taken modulo, as zlib's NMAX: they stay within 32 bits
    let end = if data.length() - at < 5552 { data.length() } else { at + 5552 }
    for i in at..<end {
      a += data[i].to_uint()
      b += a
    }
    a = a % adler_base
    b = b % adler_base
    at = end
  }
  (b << 16) | a
}

///|
/// The Adler-32 of `data` (RFC 1950).
pub fn adler32(data : BytesView) -> UInt {
  adler32_update(1U, data)
}

///|
/// `data` deflated in zlib's wrapping (Node's `zlib.deflateSync` reads it back).
pub fn zlib_compress(data : BytesView) -> Bytes {
  let out = Buffer()
  // deflate, a 32 KiB window, no dictionary; the level said is the default (which only tells, and checks to 31)
  out.write_byte(b'\x78')
  out.write_byte(b'\x9C')
  out.write_bytesview(deflate(data))
  out.write_uint_be(adler32(data))
  out.to_bytes()
}

///|
/// What `data`, deflated in zlib's wrapping, holds; `None` where its head is not one (another method, a window past
/// 32 KiB, a preset dictionary, a check that fails), its deflate is damaged, or its Adler-32 is missing or not that of
/// what it holds. What follows the Adler-32 is let be.
pub fn zlib_decompress(data : BytesView) -> Bytes? {
  if data.length() < 2 {
    return None
  }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  if (cmf & 0x0F) != 8 || cmf >> 4 > 7 || (cmf * 256 + flg) % 31 != 0 || (flg & 0x20) != 0 {
    return None
  }
  guard inflate_at(data, 2) is Some((out, end)) else { return None }
  if end + 4 > data.length() || be32(data, end) != adler32(out) {
    return None
  }
  Some(out)
}

///|
/// `data` gzipped: one piece, no name, time or comment, said to be made on Unix (as Node's `zlib.gzipSync` heads it).
pub fn gzip(data : BytesView) -> Bytes {
  let out = Buffer()
  out.write_bytesview(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03")
  out.write_bytesview(deflate(data))
  out.write_uint_le(@codec.crc32(data))
  out.write_uint_le(data.length().reinterpret_as_uint())
  out.to_bytes()
}

///|
/// What `data`, gzipped, holds: each piece in turn, as Node's `zlib.gunzipSync` reads them (what follows one is let be
/// where it begins with a zero byte, padding, and read as the next otherwise). A piece's head may say a file's extra
/// field, name, comment and its own CRC-16, each checked as far as it is said. `None` where it is not gzip (another
/// method, flags not of RFC 1952), its head or deflate is cut short or damaged, or its CRC-32 or length is not that
/// of what it holds.
pub fn gunzip(data : BytesView) -> Bytes? {
  let out = Buffer()
  let mut at = 0
  while true {
    if at + 10 > data.length() ||
      data[at] != b'\x1f' ||
      data[at + 1] != b'\x8b' ||
      data[at + 2] != b'\x08' {
      return None
    }
    let flg = data[at + 3].to_int()
    if (flg & 0xE0) != 0 {
      return None
    }
    let mut p = at + 10
    if (flg & 0x04) != 0 {
      // FEXTRA: its length, then that many bytes
      if p + 2 > data.length() {
        return None
      }
      p += 2 + (data[p].to_int() | (data[p + 1].to_int() << 8))
    }
    for flag in [0x08, 0x10] {
      // FNAME, FCOMMENT: to a zero byte
      if (flg & flag) != 0 {
        while p < data.length() && data[p] != b'\x00' {
          p += 1
        }
        p += 1
      }
    }
    if (flg & 0x02) != 0 {
      // FHCRC: the low 16 bits of the CRC-32 of the head before it
      if p + 2 > data.length() {
        return None
      }
      let crc16 = data[p].to_uint() | (data[p + 1].to_uint() << 8)
      if crc16 != (@codec.crc32(data[at:p]) & 0xFFFFU) {
        return None
      }
      p += 2
    }
    if p > data.length() {
      return None
    }
    guard inflate_at(data, p) is Some((piece, end)) else { return None }
    if end + 8 > data.length() ||
      le32(data, end) != @codec.crc32(piece) ||
      le32(data, end + 4) != piece.length().reinterpret_as_uint() {
      return None
    }
    out.write_bytesview(piece)
    at = end + 8
    // past the last, nothing or a zero byte (padding); anything else is to be the next
    if at == data.length() || data[at] == b'\x00' {
      break
    }
  }
  Some(out.to_bytes())
}

///|
/// The 32 bits at `at`, the highest byte first.
fn be32(data : BytesView, at : Int) -> UInt {
  (data[at].to_uint() << 24) |
  (data[at + 1].to_uint() << 16) |
  (data[at + 2].to_uint() << 8) |
  data[at + 3].to_uint()
}

///|
/// The 32 bits at `at`, the lowest byte first.
fn le32(data : BytesView, at : Int) -> UInt {
  data[at].to_uint() |
  (data[at + 1].to_uint() << 8) |
  (data[at + 2].to_uint() << 16) |
  (data[at + 3].to_uint() << 24)
}
