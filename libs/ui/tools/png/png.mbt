// A PNG's pixels, as the checks of pictures read them: an 8-bit RGB or RGBA picture, its rows unfiltered.
// Also provides pure MoonBit image scaling and PNG, Windows ICO, and macOS ICNS encoding.

///|
pub struct Picture {
  w : Int
  h : Int
  /// bytes a pixel: 3 RGB, 4 RGBA
  bpp : Int
  rows : Array[Bytes]
}

///|
/// Build an RGBA (bpp = 4) picture from flat RGBA byte rows (length >= w * h * 4).
pub fn Picture::new(w : Int, h : Int, rgba_bytes : Bytes) -> Picture {
  if w <= 0 || h <= 0 {
    return { w: 0, h: 0, bpp: 4, rows: [] }
  }
  let stride = w * 4
  let total = rgba_bytes.length()
  let rows : Array[Bytes] = []
  for y in 0..<h {
    let start = y * stride
    let end = start + stride
    if end <= total {
      rows.push(rgba_bytes[start:end].to_owned())
    } else {
      let line = FixedArray::make(stride, b'\x00')
      for i in 0..<stride {
        let idx = start + i
        if idx < total {
          line[i] = rgba_bytes[idx]
        }
      }
      rows.push(Bytes::from_array(line[:]))
    }
  }
  { w, h, bpp: 4, rows }
}

///|
/// The pixel at (x, y): its red, green and blue
pub fn Picture::rgb(self : Picture, x : Int, y : Int) -> (Int, Int, Int) {
  let r = self.rows[y]
  let i = x * self.bpp
  (r[i].to_int(), r[i + 1].to_int(), r[i + 2].to_int())
}

///|
/// The pixel at (x, y): its red, green, blue and alpha (255 for RGB pictures)
pub fn Picture::rgba(self : Picture, x : Int, y : Int) -> (Int, Int, Int, Int) {
  let r = self.rows[y]
  let i = x * self.bpp
  let a = if self.bpp == 4 { r[i + 3].to_int() } else { 255 }
  (r[i].to_int(), r[i + 1].to_int(), r[i + 2].to_int(), a)
}

///|
fn be32(d : Bytes, i : Int) -> Int {
  (d[i].to_int() << 24) |
  (d[i + 1].to_int() << 16) |
  (d[i + 2].to_int() << 8) |
  d[i + 3].to_int()
}

///|
fn write_be32(buf : Buffer, v : Int) -> Unit {
  buf.write_byte(((v >> 24) & 0xFF).to_byte())
  buf.write_byte(((v >> 16) & 0xFF).to_byte())
  buf.write_byte(((v >> 8) & 0xFF).to_byte())
  buf.write_byte((v & 0xFF).to_byte())
}

///|
fn write_be32_uint(buf : Buffer, v : UInt) -> Unit {
  buf.write_byte(((v >> 24) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte(((v >> 16) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte(((v >> 8) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte((v & 0xFFU).reinterpret_as_int().to_byte())
}

///|
fn write_le16(buf : Buffer, v : Int) -> Unit {
  buf.write_byte((v & 0xFF).to_byte())
  buf.write_byte(((v >> 8) & 0xFF).to_byte())
}

///|
fn write_le32(buf : Buffer, v : Int) -> Unit {
  buf.write_byte((v & 0xFF).to_byte())
  buf.write_byte(((v >> 8) & 0xFF).to_byte())
  buf.write_byte(((v >> 16) & 0xFF).to_byte())
  buf.write_byte(((v >> 24) & 0xFF).to_byte())
}

///|
let png_signature : Bytes = b"\x89PNG\r\n\x1a\n"

///|
/// Decode an 8-bit RGB or RGBA PNG from bytes.
pub fn decode_png(d : Bytes, label? : String = "<bytes>") -> Result[Picture, String] {
  if d.length() < 8 || d[0:8].to_owned() != png_signature {
    return Err("\{label}: not a PNG")
  }
  let mut i = 8
  let mut w = 0
  let mut h = 0
  let mut depth = 0
  let mut ct = 0
  let idat = Buffer()
  while i + 8 <= d.length() {
    let n = be32(d, i)
    if n < 0 || i + 12 + n > d.length() {
      return Err("\{label}: truncated PNG chunk")
    }
    let t = d[i + 4:i + 8].to_owned()
    if t == b"IHDR" {
      if n < 13 {
        return Err("\{label}: invalid IHDR")
      }
      w = be32(d, i + 8)
      h = be32(d, i + 12)
      depth = d[i + 16].to_int()
      ct = d[i + 17].to_int()
    } else if t == b"IDAT" {
      idat.write_bytesview(d[i + 8:i + 8 + n])
    } else if t == b"IEND" {
      break
    }
    i += 12 + n
  }
  if w <= 0 || h <= 0 || depth != 8 || (ct != 2 && ct != 6) {
    return Err("\{label}: not an 8-bit RGB(A) PNG")
  }
  let bpp = if ct == 6 { 4 } else { 3 }
  let idat_bytes = idat.to_bytes()
  if idat_bytes.length() < 2 {
    return Err("\{label}: empty IDAT")
  }
  // (zlib's stream: its 2 bytes of head, then deflate's)
  let raw = match inflate(idat_bytes, start=2) {
    Some(r) => r
    None => return Err("\{label}: its pixels do not inflate")
  }
  let stride = w * bpp
  if raw.length() < h * (stride + 1) {
    return Err("\{label}: fewer pixels than its size")
  }
  let rows = []
  let mut prev = FixedArray::make(stride, b'\x00')
  for y in 0..<h {
    let at = y * (stride + 1)
    let f = raw[at].to_int()
    let line = FixedArray::make(stride, b'\x00')
    for x in 0..<stride {
      let v = raw[at + 1 + x].to_int()
      let a = if x >= bpp { line[x - bpp].to_int() } else { 0 }
      let b = prev[x].to_int()
      let c = if x >= bpp { prev[x - bpp].to_int() } else { 0 }
      let o = match f {
        1 => v + a
        2 => v + b
        3 => v + (a + b) / 2
        4 => {
          let p = a + b - c
          let pa = (p - a).abs()
          let pb = (p - b).abs()
          let pc = (p - c).abs()
          v + (if pa <= pb && pa <= pc { a } else if pb <= pc { b } else { c })
        }
        _ => v
      }
      line[x] = (o & 255).to_byte()
    }
    rows.push(Bytes::from_array(line[:]))
    prev = line
  }
  Ok({ w, h, bpp, rows })
}

///|
/// The PNG at `path`, or why not
pub fn read(path : String) -> Result[Picture, String] {
  match @sys.read_bytes(path) {
    Some(d) => decode_png(d, label=path)
    None => Err("\{path}: cannot be read")
  }
}

///|
fn clamp_u8(v : Double) -> Byte {
  let n = (v + 0.5).to_int()
  if n <= 0 {
    b'\x00'
  } else if n >= 255 {
    b'\xff'
  } else {
    n.to_byte()
  }
}

///|
/// Resize a picture to `dst_w` x `dst_h` (RGBA) using separable premultiplied-alpha
/// area-average (box filter) for downsampling and bilinear interpolation for upsampling.
pub fn Picture::resize(self : Picture, dst_w : Int, dst_h : Int) -> Picture {
  if dst_w <= 0 || dst_h <= 0 {
    return { w: 0, h: 0, bpp: 4, rows: [] }
  }
  if self.w <= 0 || self.h <= 0 {
    return Picture::new(dst_w, dst_h, Bytes::make(dst_w * dst_h * 4, b'\x00'))
  }
  let src_w = self.w
  let src_h = self.h
  // Pass 1: horizontal resample src_w -> dst_w into premultiplied Double buffer (src_h x dst_w x 4)
  let horiz = FixedArray::make(src_h * dst_w * 4, 0.0)
  let sw_f = src_w.to_double()
  let dw_f = dst_w.to_double()
  for y in 0..<src_h {
    let row = self.rows[y]
    let bpp = self.bpp
    let h_row = y * dst_w * 4
    if dst_w < src_w {
      let scale = sw_f / dw_f
      for dx in 0..<dst_w {
        let x0 = dx.to_double() * scale
        let x1 = (dx + 1).to_double() * scale
        let ix0 = x0.to_int()
        let mut ix1 = x1.to_int()
        if ix1.to_double() < x1 {
          ix1 += 1
        }
        if ix1 > src_w {
          ix1 = src_w
        }
        let mut sr = 0.0
        let mut sg = 0.0
        let mut sb = 0.0
        let mut sa = 0.0
        let mut wsum = 0.0
        for sx in ix0..<ix1 {
          let lo = if sx.to_double() > x0 { sx.to_double() } else { x0 }
          let hi = if (sx + 1).to_double() < x1 { (sx + 1).to_double() } else { x1 }
          let w = hi - lo
          if w > 0.0 {
            let off = sx * bpp
            let a = if bpp == 4 { row[off + 3].to_int().to_double() / 255.0 } else { 1.0 }
            let wa = w * a
            sr += row[off].to_int().to_double() * wa
            sg += row[off + 1].to_int().to_double() * wa
            sb += row[off + 2].to_int().to_double() * wa
            sa += wa
            wsum += w
          }
        }
        let dst_off = h_row + dx * 4
        if wsum > 0.0 {
          horiz[dst_off] = sr / wsum
          horiz[dst_off + 1] = sg / wsum
          horiz[dst_off + 2] = sb / wsum
          horiz[dst_off + 3] = sa / wsum
        }
      }
    } else {
      for dx in 0..<dst_w {
        let fx = (dx.to_double() + 0.5) * sw_f / dw_f - 0.5
        let clamped = if fx < 0.0 {
          0.0
        } else if fx > sw_f - 1.0 {
          sw_f - 1.0
        } else {
          fx
        }
        let x0 = clamped.to_int()
        let x1 = if x0 + 1 < src_w { x0 + 1 } else { x0 }
        let t = clamped - x0.to_double()
        let w0 = 1.0 - t
        let w1 = t
        let o0 = x0 * bpp
        let o1 = x1 * bpp
        let a0 = if bpp == 4 { row[o0 + 3].to_int().to_double() / 255.0 } else { 1.0 }
        let a1 = if bpp == 4 { row[o1 + 3].to_int().to_double() / 255.0 } else { 1.0 }
        let dst_off = h_row + dx * 4
        horiz[dst_off] = row[o0].to_int().to_double() * a0 * w0 + row[o1].to_int().to_double() * a1 * w1
        horiz[dst_off + 1] = row[o0 + 1].to_int().to_double() * a0 * w0 + row[o1 + 1].to_int().to_double() * a1 * w1
        horiz[dst_off + 2] = row[o0 + 2].to_int().to_double() * a0 * w0 + row[o1 + 2].to_int().to_double() * a1 * w1
        horiz[dst_off + 3] = a0 * w0 + a1 * w1
      }
    }
  }
  // Pass 2: vertical resample src_h -> dst_h and un-premultiply into output RGBA rows
  let sh_f = src_h.to_double()
  let dh_f = dst_h.to_double()
  let rows : Array[Bytes] = []
  for dy in 0..<dst_h {
    let line = FixedArray::make(dst_w * 4, b'\x00')
    if dst_h < src_h {
      let scale = sh_f / dh_f
      let y0 = dy.to_double() * scale
      let y1 = (dy + 1).to_double() * scale
      let iy0 = y0.to_int()
      let mut iy1 = y1.to_int()
      if iy1.to_double() < y1 {
        iy1 += 1
      }
      if iy1 > src_h {
        iy1 = src_h
      }
      for dx in 0..<dst_w {
        let mut sr = 0.0
        let mut sg = 0.0
        let mut sb = 0.0
        let mut sa = 0.0
        let mut wsum = 0.0
        for sy in iy0..<iy1 {
          let lo = if sy.to_double() > y0 { sy.to_double() } else { y0 }
          let hi = if (sy + 1).to_double() < y1 { (sy + 1).to_double() } else { y1 }
          let w = hi - lo
          if w > 0.0 {
            let off = (sy * dst_w + dx) * 4
            sr += horiz[off] * w
            sg += horiz[off + 1] * w
            sb += horiz[off + 2] * w
            sa += horiz[off + 3] * w
            wsum += w
          }
        }
        let out_off = dx * 4
        if wsum > 0.0 {
          let a = sa / wsum
          if a > 0.000001 {
            line[out_off] = clamp_u8(sr / wsum / a)
            line[out_off + 1] = clamp_u8(sg / wsum / a)
            line[out_off + 2] = clamp_u8(sb / wsum / a)
            line[out_off + 3] = clamp_u8(a * 255.0)
          }
        }
      }
    } else {
      let fy = (dy.to_double() + 0.5) * sh_f / dh_f - 0.5
      let clamped = if fy < 0.0 {
        0.0
      } else if fy > sh_f - 1.0 {
        sh_f - 1.0
      } else {
        fy
      }
      let y0 = clamped.to_int()
      let y1 = if y0 + 1 < src_h { y0 + 1 } else { y0 }
      let t = clamped - y0.to_double()
      let w0 = 1.0 - t
      let w1 = t
      for dx in 0..<dst_w {
        let o0 = (y0 * dst_w + dx) * 4
        let o1 = (y1 * dst_w + dx) * 4
        let pr = horiz[o0] * w0 + horiz[o1] * w1
        let pg = horiz[o0 + 1] * w0 + horiz[o1 + 1] * w1
        let pb = horiz[o0 + 2] * w0 + horiz[o1 + 2] * w1
        let a = horiz[o0 + 3] * w0 + horiz[o1 + 3] * w1
        let out_off = dx * 4
        if a > 0.000001 {
          line[out_off] = clamp_u8(pr / a)
          line[out_off + 1] = clamp_u8(pg / a)
          line[out_off + 2] = clamp_u8(pb / a)
          line[out_off + 3] = clamp_u8(a * 255.0)
        }
      }
    }
    rows.push(Bytes::from_array(line[:]))
  }
  { w: dst_w, h: dst_h, bpp: 4, rows }
}

///|
fn write_png_chunk(out : Buffer, tag : Bytes, payload : Bytes) -> Unit {
  write_be32(out, payload.length())
  out.write_bytesview(tag)
  out.write_bytesview(payload)
  let crc_buf = Buffer(capacity=4 + payload.length())
  crc_buf.write_bytesview(tag)
  crc_buf.write_bytesview(payload)
  write_be32_uint(out, crc32(crc_buf.to_bytes()))
}

///|
fn adler32(data : Bytes) -> UInt {
  let mut s1 = 1U
  let mut s2 = 0U
  for i in 0..<data.length() {
    s1 = (s1 + data[i].to_uint()) % 65521U
    s2 = (s2 + s1) % 65521U
  }
  (s2 << 16) | s1
}

///|
fn zlib_stored(raw : Bytes) -> Bytes {
  let n = raw.length()
  let out = Buffer(capacity=n + (n / 65535 + 1) * 5 + 6)
  // zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01 (check bits: (0x7801 % 31) == 0)
  out.write_byte(b'\x78')
  out.write_byte(b'\x01')
  if n == 0 {
    out.write_byte(b'\x01')
    write_le16(out, 0)
    write_le16(out, 0xFFFF)
  } else {
    let mut off = 0
    while off < n {
      let rem = n - off
      let blk = if rem > 65535 { 65535 } else { rem }
      let is_last = off + blk == n
      out.write_byte(if is_last { b'\x01' } else { b'\x00' })
      write_le16(out, blk)
      write_le16(out, blk ^ 0xFFFF)
      out.write_bytesview(raw[off:off + blk])
      off += blk
    }
  }
  write_be32_uint(out, adler32(raw))
  out.to_bytes()
}

///|
/// Encode a Picture as an 8-bit RGBA PNG using uncompressed (stored) zlib blocks.
pub fn encode_png(pic : Picture) -> Bytes {
  let out = Buffer()
  out.write_bytesview(png_signature)
  // IHDR (13 bytes)
  let ihdr = Buffer(capacity=13)
  write_be32(ihdr, pic.w)
  write_be32(ihdr, pic.h)
  ihdr.write_byte(b'\x08') // bit depth: 8
  ihdr.write_byte(b'\x06') // color type: RGBA
  ihdr.write_byte(b'\x00') // compression: deflate
  ihdr.write_byte(b'\x00') // filter: adaptive
  ihdr.write_byte(b'\x00') // interlace: none
  write_png_chunk(out, b"IHDR", ihdr.to_bytes())
  // Raw scanlines (filter byte 0 + RGBA pixels per row)
  let raw = Buffer(capacity=pic.h * (1 + pic.w * 4))
  for y in 0..<pic.h {
    raw.write_byte(b'\x00')
    let row = pic.rows[y]
    if pic.bpp == 4 {
      raw.write_bytesview(row)
    } else {
      for x in 0..<pic.w {
        let i = x * 3
        raw.write_byte(row[i])
        raw.write_byte(row[i + 1])
        raw.write_byte(row[i + 2])
        raw.write_byte(b'\xff')
      }
    }
  }
  write_png_chunk(out, b"IDAT", zlib_stored(raw.to_bytes()))
  write_png_chunk(out, b"IEND", b"")
  out.to_bytes()
}

///|
/// Encode a list of Pictures into a Windows `.ico` container (PNG-in-ICO payloads).
pub fn encode_ico(sizes : Array[Picture]) -> Bytes {
  let count = sizes.length()
  let payloads : Array[Bytes] = []
  for pic in sizes {
    payloads.push(encode_png(pic))
  }
  let out = Buffer()
  // ICONDIR (6 bytes)
  write_le16(out, 0) // reserved
  write_le16(out, 1) // type = 1 (icon)
  write_le16(out, count)
  let mut offset = 6 + count * 16
  for i in 0..<count {
    let pic = sizes[i]
    let png = payloads[i]
    out.write_byte(if pic.w >= 256 { b'\x00' } else { (pic.w & 0xFF).to_byte() })
    out.write_byte(if pic.h >= 256 { b'\x00' } else { (pic.h & 0xFF).to_byte() })
    out.write_byte(b'\x00') // color count (0 for >= 8bpp)
    out.write_byte(b'\x00') // reserved
    write_le16(out, 1) // color planes
    write_le16(out, 32) // bits per pixel
    write_le32(out, png.length())
    write_le32(out, offset)
    offset += png.length()
  }
  for png in payloads {
    out.write_bytesview(png)
  }
  out.to_bytes()
}

///|
/// Encode a Picture into a macOS `.icns` container with standard PNG-in-ICNS OSType chunks:
/// icp4(16), icp5(32), icp6(64), ic07(128), ic08(256), ic09(512), ic10(1024),
/// ic11(32@2x=16x16@2x), ic12(64=32x32@2x), ic13(256=128x128@2x), ic14(512=256x256@2x).
pub fn encode_icns(pic : Picture) -> Bytes {
  let p16 = encode_png(pic.resize(16, 16))
  let p32 = encode_png(pic.resize(32, 32))
  let p64 = encode_png(pic.resize(64, 64))
  let p128 = encode_png(pic.resize(128, 128))
  let p256 = encode_png(pic.resize(256, 256))
  let p512 = encode_png(pic.resize(512, 512))
  let p1024 = encode_png(pic.resize(1024, 1024))
  let entries : Array[(Bytes, Bytes)] = [
    (b"icp4", p16),
    (b"icp5", p32),
    (b"icp6", p64),
    (b"ic07", p128),
    (b"ic08", p256),
    (b"ic09", p512),
    (b"ic10", p1024),
    (b"ic11", p32),
    (b"ic12", p64),
    (b"ic13", p256),
    (b"ic14", p512),
  ]
  let mut total = 8
  for e in entries {
    total += 8 + e.1.length()
  }
  let out = Buffer(capacity=total)
  out.write_bytesview(b"icns")
  write_be32(out, total)
  for e in entries {
    out.write_bytesview(e.0)
    write_be32(out, 8 + e.1.length())
    out.write_bytesview(e.1)
  }
  out.to_bytes()
}
