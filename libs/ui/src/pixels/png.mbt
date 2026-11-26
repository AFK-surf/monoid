// Pixels made here written as a PNG (a picture to hand to the host, as @ui.add_image takes it, or to a clipboard): its
// rows in stored deflate blocks, nothing compressed (what is made here is small; every decoder reads it).

///|
// kept across runs: a table, never written
let png_crc_table : FixedArray[UInt] = {
  let t = FixedArray::make(256, 0U)
  for n in 0..<256 {
    let mut c = n.reinterpret_as_uint()
    for _ in 0..<8 {
      c = if (c & 1U) != 0U { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
    t[n] = c
  }
  t
}

///|
priv struct PngOut {
  buf : Array[Byte]
}

///|
fn PngOut::byte(self : PngOut, v : Int) -> Unit {
  self.buf.push((v & 0xFF).to_byte())
}

///|
fn PngOut::u32(self : PngOut, v : UInt) -> Unit {
  self.byte((v >> 24).reinterpret_as_int())
  self.byte((v >> 16).reinterpret_as_int())
  self.byte((v >> 8).reinterpret_as_int())
  self.byte(v.reinterpret_as_int())
}

///|
fn PngOut::chunk(self : PngOut, kind : String, data : Array[Byte]) -> Unit {
  self.u32(data.length().reinterpret_as_uint())
  let start = self.buf.length()
  for ch in kind {
    self.byte(ch.to_int())
  }
  for b in data {
    self.buf.push(b)
  }
  let mut c = 0xFFFFFFFFU
  for i in start..<self.buf.length() {
    c = png_crc_table[((c ^ self.buf[i].to_uint()) & 0xFFU).reinterpret_as_int()] ^
      (c >> 8)
  }
  self.u32(c ^ 0xFFFFFFFFU)
}

///|
fn png_stored_idat(raw : Array[Byte]) -> Array[Byte] {
  let z : PngOut = { buf: [] }
  z.byte(0x78)
  z.byte(0x01)
  let mut at = 0
  while at < raw.length() || at == 0 {
    let n = if raw.length() - at > 65535 { 65535 } else { raw.length() - at }
    z.byte(if at + n >= raw.length() { 1 } else { 0 })
    z.byte(n & 0xFF)
    z.byte(n >> 8)
    z.byte(n.lnot() & 0xFF)
    z.byte((n.lnot() >> 8) & 0xFF)
    for i in at..<(at + n) {
      z.buf.push(raw[i])
    }
    at = at + n
    if n == 0 {
      break
    }
  }
  let mut a = 1U
  let mut b = 0U
  for v in raw {
    a = (a + v.to_uint()) % 65521U
    b = (b + a) % 65521U
  }
  z.u32((b << 16) | a)
  z.buf
}

///|
fn png_imin(a : Int, b : Int) -> Int {
  if a < b {
    a
  } else {
    b
  }
}

///|
/// `v` written big-endian into `out` at `at`.
fn png_u32(out : FixedArray[Byte], at : Int, v : Int) -> Unit {
  out[at] = ((v >> 24) & 0xFF).to_byte()
  out[at + 1] = ((v >> 16) & 0xFF).to_byte()
  out[at + 2] = ((v >> 8) & 0xFF).to_byte()
  out[at + 3] = (v & 0xFF).to_byte()
}

///|
/// A chunk's CRC written after its kind and body (`out` from `from` to `until`).
fn png_crc(out : FixedArray[Byte], from : Int, until : Int) -> Unit {
  let mut c = 0xFFFFFFFFU
  for i in from..<until {
    c = png_crc_table[((c ^ out[i].to_uint()) & 0xFFU).reinterpret_as_int()] ^ (c >> 8)
  }
  png_u32(out, until, (c ^ 0xFFFFFFFFU).reinterpret_as_int())
}

///|
/// A chunk's length and kind (its four letters as one number, big-endian) written into `out` at `at`.
fn png_chunk_head(out : FixedArray[Byte], at : Int, length : Int, kind : Int) -> Unit {
  png_u32(out, at, length)
  png_u32(out, at + 4, kind)
}

///|
/// RGBA pixels (`w` × `h`, straight alpha, rows from the top) as a PNG (stored, not compressed: small pictures made
/// here, decoded anywhere), to hand to @ui.add_image. Written into one buffer of the size it comes to, each row copied
/// whole; its checks (CRC-32 by a table, Adler-32 with the remainder taken every 5552 bytes, as zlib does, the most
/// before its sums can pass 32 bits) worked out over it.
pub fn png(w : Int, h : Int, rgba : FixedArray[Byte]) -> Bytes {
  let stride = w * 4
  // the rows, each after its filter byte (none), in stored deflate blocks of 65535 bytes at most (one, empty, for none)
  let raw = h * (stride + 1)
  let blocks = if raw == 0 { 1 } else { (raw + 65534) / 65535 }
  let zlen = 2 + 5 * blocks + raw + 4
  let out = FixedArray::make(8 + 25 + (12 + zlen) + 12, b'\x00')
  for i, b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
    out[i] = b.to_byte()
  }
  // (IHDR)
  png_chunk_head(out, 8, 13, 0x49484452)
  png_u32(out, 16, w)
  png_u32(out, 20, h)
  out[24] = b'\x08'
  out[25] = b'\x06'
  png_crc(out, 12, 29)
  // (IDAT)
  png_chunk_head(out, 33, zlen, 0x49444154)
  out[41] = b'\x78'
  out[42] = b'\x01'
  let mut o = 43
  // raw bytes written, and left in the block being written
  let mut done = 0
  let mut left = 0
  let block = fn() {
    let n = png_imin(raw - done, 65535)
    out[o] = (if done + n >= raw { 1 } else { 0 }).to_byte()
    out[o + 1] = (n & 0xFF).to_byte()
    out[o + 2] = (n >> 8).to_byte()
    out[o + 3] = (n.lnot() & 0xFF).to_byte()
    out[o + 4] = ((n.lnot() >> 8) & 0xFF).to_byte()
    o = o + 5
    left = n
  }
  if raw == 0 {
    block()
  }
  // Adler-32's sums, and how many bytes were added since their remainder was last taken
  let mut a = 1U
  let mut b = 0U
  let mut summed = 0
  for y in 0..<h {
    if left == 0 {
      block()
    }
    // (its filter byte, 0, as the buffer was made)
    o = o + 1
    left = left - 1
    done = done + 1
    b = b + a
    summed = summed + 1
    if summed == 5552 {
      a = a % 65521U
      b = b % 65521U
      summed = 0
    }
    let mut s = y * stride
    let mut rest = stride
    while rest > 0 {
      if left == 0 {
        block()
      }
      let c = png_imin(rest, left)
      rgba.blit_to(out, len=c, src_offset=s, dst_offset=o)
      // (summed in runs up to the next remainder)
      let mut i = s
      while i < s + c {
        let run = png_imin(s + c - i, 5552 - summed)
        for j in i..<(i + run) {
          a = a + rgba[j].to_uint()
          b = b + a
        }
        i = i + run
        summed = summed + run
        if summed == 5552 {
          a = a % 65521U
          b = b % 65521U
          summed = 0
        }
      }
      o = o + c
      s = s + c
      rest = rest - c
      left = left - c
      done = done + c
    }
  }
  a = a % 65521U
  b = b % 65521U
  png_u32(out, o, ((b << 16) | a).reinterpret_as_int())
  o = o + 4
  png_crc(out, 37, o)
  o = o + 4
  // (IEND)
  png_chunk_head(out, o, 0, 0x49454E44)
  png_crc(out, o + 4, o + 8)
  Bytes::from_array(out[:])
}

///|
/// 4-bit indexed-colour pixels (`w` × `h`, `indices` 0..15 per pixel, `palette` 3 bytes per colour, `alphas` 1 byte per
/// colour) as a PNG (color type 3, bit depth 4, PLTE + tRNS, stored deflate blocks).
pub fn png_indexed(
  w : Int,
  h : Int,
  palette : FixedArray[Byte],
  alphas : FixedArray[Byte],
  indices : FixedArray[Byte],
) -> Bytes {
  let o : PngOut = { buf: [] }
  for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
    o.byte(b)
  }
  let ihdr : PngOut = { buf: [] }
  ihdr.u32(w.reinterpret_as_uint())
  ihdr.u32(h.reinterpret_as_uint())
  for b in [4, 3, 0, 0, 0] {
    ihdr.byte(b)
  }
  o.chunk("IHDR", ihdr.buf)
  let plte : Array[Byte] = Array(capacity=palette.length())
  for b in palette {
    plte.push(b)
  }
  o.chunk("PLTE", plte)
  if alphas.length() > 0 {
    let trns : Array[Byte] = Array(capacity=alphas.length())
    for b in alphas {
      trns.push(b)
    }
    o.chunk("tRNS", trns)
  }
  let stride = (w + 1) / 2
  let raw : Array[Byte] = Array(capacity=h * (stride + 1))
  for y in 0..<h {
    raw.push(b'\x00')
    let row = y * w
    let mut x = 0
    while x < w {
      let hi = indices[row + x].to_int() & 0x0F
      let lo = if x + 1 < w { indices[row + x + 1].to_int() & 0x0F } else { 0 }
      raw.push(((hi << 4) | lo).to_byte())
      x += 2
    }
  }
  o.chunk("IDAT", png_stored_idat(raw))
  o.chunk("IEND", [])
  Bytes::from_array(o.buf)
}

