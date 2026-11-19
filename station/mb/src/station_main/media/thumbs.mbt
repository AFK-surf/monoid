// The images sent in chats, made small and hashed as the mesh addon did for Node (native/mesh/src/thumbs.rs, the Rust
// station's mesh/app/src/thumbs.rs), in MoonBit on mbui's pixels: decoded (PNG, JPEG, WebP), turned as its EXIF says,
// fitted in 720×600 with Catmull-Rom (image's `resize`), kept as a PNG where any of it is clear and as a JPEG of quality
// 88 otherwise, written whole beside before it is there to be read; and its ThumbHash (evanw/thumbhash's
// `rgba_to_thumb_hash` of it at most 100px across). Given the drive as its `Codecs` (drive/thumbs.mbt). Not the same
// bytes as the Rust crates make (another JPEG encoder, another deflate): the same sizes, orientation and choices.

///|
/// The largest a chat shows an image (its box is at most 360×300), at twice that for sharp screens.
let thumb_max_w : Int = 720

///|
let thumb_max_h : Int = 600

///|
/// An image decoded: its width, height and RGBA (straight, rows from the top).
pub(all) struct Image {
  w : Int
  h : Int
  px : FixedArray[Byte]
}

// ── EXIF's orientation ──

///|
fn be16(b : Bytes, i : Int) -> Int {
  (b[i].to_int() << 8) | b[i + 1].to_int()
}

///|
fn be32(b : Bytes, i : Int) -> Int {
  (b[i].to_int() << 24) | (b[i + 1].to_int() << 16) | (b[i + 2].to_int() << 8) | b[i + 3].to_int()
}

///|
fn le32(b : Bytes, i : Int) -> Int {
  b[i].to_int() | (b[i + 1].to_int() << 8) | (b[i + 2].to_int() << 16) | (b[i + 3].to_int() << 24)
}

///|
/// The orientation a TIFF block of EXIF (from `start`, `len` bytes) says in its first IFD (tag 0x0112), 1 where none.
fn tiff_orientation(b : Bytes, start : Int, len : Int) -> Int {
  let end = start + len
  guard len >= 8 && end <= b.length() else { 1 }
  let little = b[start] == b'I' && b[start + 1] == b'I'
  let big = b[start] == b'M' && b[start + 1] == b'M'
  guard little || big else { 1 }
  let u16 = (i : Int) => if little { b[i].to_int() | (b[i + 1].to_int() << 8) } else { be16(b, i) }
  let u32 = (i : Int) => if little { le32(b, i) } else { be32(b, i) }
  guard u16(start + 2) == 42 else { 1 }
  let ifd = start + u32(start + 4)
  guard ifd >= start && ifd + 2 <= end else { 1 }
  let n = u16(ifd)
  for k = 0; k < n; k = k + 1 {
    let e = ifd + 2 + k * 12
    if e + 12 > end {
      break
    }
    if u16(e) == 0x0112 && u16(e + 2) == 3 {
      let v = u16(e + 8)
      return if v >= 1 && v <= 8 { v } else { 1 }
    }
  }
  1
}

///|
fn starts(b : Bytes, at : Int, s : String) -> Bool {
  guard at + s.length() <= b.length() else { false }
  for i = 0; i < s.length(); i = i + 1 {
    if b[at + i].to_int() != s[i].to_int() {
      return false
    }
  }
  true
}

///|
/// The orientation an image's EXIF says (JPEG's APP1, PNG's eXIf, WebP's EXIF), 1 (as it is) where it says none.
fn exif_orientation(b : Bytes) -> Int {
  if b.length() > 4 && b[0] == b'\xFF' && b[1] == b'\xD8' {
    let mut i = 2
    while i + 4 <= b.length() && b[i] == b'\xFF' {
      let marker = b[i + 1].to_int()
      if marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01 {
        i += 2
        continue
      }
      if marker == 0xDA || marker == 0xD9 {
        break
      }
      let len = be16(b, i + 2)
      if marker == 0xE1 && starts(b, i + 4, "Exif\u{0}\u{0}") {
        return tiff_orientation(b, i + 10, len - 8)
      }
      i += 2 + len
    }
    return 1
  }
  if starts(b, 0, "\u{89}PNG") {
    let mut i = 8
    while i + 12 <= b.length() {
      let len = be32(b, i)
      if len < 0 || i + 12 + len > b.length() {
        break
      }
      if starts(b, i + 4, "eXIf") {
        return tiff_orientation(b, i + 8, len)
      }
      if starts(b, i + 4, "IDAT") {
        break
      }
      i += 12 + len
    }
    return 1
  }
  if starts(b, 0, "RIFF") && starts(b, 8, "WEBP") {
    let mut i = 12
    while i + 8 <= b.length() {
      let len = le32(b, i + 4)
      if len < 0 || i + 8 + len > b.length() {
        break
      }
      if starts(b, i, "EXIF") {
        let at = if starts(b, i + 8, "Exif\u{0}\u{0}") { i + 14 } else { i + 8 }
        return tiff_orientation(b, at, len - (at - i - 8))
      }
      i += 8 + len + (len % 2)
    }
  }
  1
}

///|
/// The image turned as orientation `o` says (image's `apply_orientation`).
fn oriented(img : Image, o : Int) -> Image {
  guard o >= 2 && o <= 8 else { img }
  let (w, h) = (img.w, img.h)
  let swap = o >= 5
  let (nw, nh) = if swap { (h, w) } else { (w, h) }
  let out = FixedArray::make(nw * nh * 4, b'\x00')
  for y = 0; y < nh; y = y + 1 {
    for x = 0; x < nw; x = x + 1 {
      // (where the destination's pixel comes from)
      let (sx, sy) = match o {
        2 => (w - 1 - x, y)
        3 => (w - 1 - x, h - 1 - y)
        4 => (x, h - 1 - y)
        5 => (y, x) // rotate90 then flip: the transpose
        6 => (y, h - 1 - x) // rotate90 clockwise
        7 => (w - 1 - y, h - 1 - x) // rotate270 then flip: the transverse
        _ => (w - 1 - y, x) // rotate270 clockwise
      }
      let s = (sy * w + sx) * 4
      let d = (y * nw + x) * 4
      out[d] = img.px[s]
      out[d + 1] = img.px[s + 1]
      out[d + 2] = img.px[s + 2]
      out[d + 3] = img.px[s + 3]
    }
  }
  { w: nw, h: nh, px: out }
}

///|
/// The image as it is seen (turned as its camera says), None where it is not one of PNG, JPEG or WebP this reads.
pub fn decode_image(b : Bytes) -> Image? {
  let decoded = if starts(b, 0, "\u{89}PNG") {
    @pixels.decode_png(b)
  } else if b.length() > 2 && b[0] == b'\xFF' && b[1] == b'\xD8' {
    @pixels.decode_jpeg(b)
  } else if starts(b, 0, "RIFF") && starts(b, 8, "WEBP") {
    @pixels.decode_webp(b)
  } else {
    None
  }
  guard decoded is Some((w, h, px)) && w > 0 && h > 0 else { None }
  Some(oriented({ w, h, px }, exif_orientation(b)))
}

// ── resizing ──

///|
/// Rust's `f64::round`: half away from zero.
fn round_half_away(x : Double) -> Double {
  if x >= 0.0 {
    (x + 0.5).floor()
  } else {
    -(-x + 0.5).floor()
  }
}

///|
/// image's `resize_dimensions`: the size within `nw`×`nh` that keeps the ratio.
fn fit_within(w : Int, h : Int, nw : Int, nh : Int) -> (Int, Int) {
  let wratio = nw.to_double() / w.to_double()
  let hratio = nh.to_double() / h.to_double()
  let ratio = if wratio < hratio { wratio } else { hratio }
  let fw = round_half_away(w.to_double() * ratio).to_int()
  let fh = round_half_away(h.to_double() * ratio).to_int()
  (if fw < 1 { 1 } else { fw }, if fh < 1 { 1 } else { fh })
}

///|
/// image's Catmull-Rom (a BC cubic of B 0, C 0.5).
fn catmull_rom(x : Double) -> Double {
  let a = x.abs()
  let (b, c) = (0.0, 0.5)
  let k = if a < 1.0 {
    (12.0 - 9.0 * b - 6.0 * c) * a * a * a + (-18.0 + 12.0 * b + 6.0 * c) * a * a + (6.0 - 2.0 * b)
  } else if a < 2.0 {
    (-b - 6.0 * c) * a * a * a + (6.0 * b + 30.0 * c) * a * a + (-12.0 * b - 48.0 * c) * a + (8.0 * b + 24.0 * c)
  } else {
    0.0
  }
  k / 6.0
}

///|
/// For each of `n` places out of `len` in: where its taps start and their weights (image's `sample`).
fn taps(len : Int, n : Int) -> Array[(Int, Array[Double])] {
  let ratio = len.to_double() / n.to_double()
  let sratio = if ratio < 1.0 { 1.0 } else { ratio }
  let support = 2.0 * sratio
  let out = []
  for o = 0; o < n; o = o + 1 {
    let input = (o.to_double() + 0.5) * ratio
    let mut left = (input - support).floor().to_int()
    if left < 0 {
      left = 0
    }
    if left > len - 1 {
      left = len - 1
    }
    let mut right = (input + support).ceil().to_int()
    if right < left + 1 {
      right = left + 1
    }
    if right > len {
      right = len
    }
    let centre = input - 0.5
    let ws = []
    let mut sum = 0.0
    for i = left; i < right; i = i + 1 {
      let wt = catmull_rom((i.to_double() - centre) / sratio)
      ws.push(wt)
      sum += wt
    }
    if sum != 0.0 {
      for k = 0; k < ws.length(); k = k + 1 {
        ws[k] = ws[k] / sum
      }
    }
    out.push((left, ws))
  }
  out
}

///|
fn clamp_byte(v : Double) -> Byte {
  let r = round_half_away(v)
  if r <= 0.0 {
    b'\x00'
  } else if r >= 255.0 {
    b'\xFF'
  } else {
    r.to_int().to_byte()
  }
}

///|
/// image's `resize` with Catmull-Rom: its rows sampled down (or up) first, then its columns.
fn resize(img : Image, nw : Int, nh : Int) -> Image {
  // vertical: w × nh, in doubles
  let vt = taps(img.h, nh)
  let mid = FixedArray::make(img.w * nh * 4, 0.0)
  for y = 0; y < nh; y = y + 1 {
    let (left, ws) = vt[y]
    for x = 0; x < img.w; x = x + 1 {
      let mut r = 0.0
      let mut g = 0.0
      let mut b = 0.0
      let mut a = 0.0
      for k = 0; k < ws.length(); k = k + 1 {
        let s = ((left + k) * img.w + x) * 4
        let wt = ws[k]
        r += img.px[s].to_double() * wt
        g += img.px[s + 1].to_double() * wt
        b += img.px[s + 2].to_double() * wt
        a += img.px[s + 3].to_double() * wt
      }
      let d = (y * img.w + x) * 4
      mid[d] = r
      mid[d + 1] = g
      mid[d + 2] = b
      mid[d + 3] = a
    }
  }
  let ht = taps(img.w, nw)
  let out = FixedArray::make(nw * nh * 4, b'\x00')
  for y = 0; y < nh; y = y + 1 {
    for x = 0; x < nw; x = x + 1 {
      let (left, ws) = ht[x]
      let mut r = 0.0
      let mut g = 0.0
      let mut b = 0.0
      let mut a = 0.0
      for k = 0; k < ws.length(); k = k + 1 {
        let s = (y * img.w + left + k) * 4
        let wt = ws[k]
        r += mid[s] * wt
        g += mid[s + 1] * wt
        b += mid[s + 2] * wt
        a += mid[s + 3] * wt
      }
      let d = (y * nw + x) * 4
      out[d] = clamp_byte(r)
      out[d + 1] = clamp_byte(g)
      out[d + 2] = clamp_byte(b)
      out[d + 3] = clamp_byte(a)
    }
  }
  { w: nw, h: nh, px: out }
}

///|
/// image's `thumbnail` (imageops/sample.rs, in f32 as it works): fitted in `nw`×`nh` (made larger too, as it is), each
/// pixel the rounded mean of the source pixels it covers by their whole indices, or, where it covers less than one
/// across or down, those beside it mixed by the fraction, truncated to a byte.
fn thumbnail_sized(img : Image, nw : Int, nh : Int) -> Image {
  let (tw, th) = fit_within(img.w, img.h, nw, nh)
  let (w, h) = (img.w, img.h)
  let out = FixedArray::make(tw * th * 4, b'\x00')
  let px = (x : Int, y : Int, k : Int) => img.px[(y * w + x) * 4 + k].to_int()
  let x_ratio = Float::from_int(w) / Float::from_int(tw)
  let y_ratio = Float::from_int(h) / Float::from_int(th)
  let clamp = (v : Int, lo : Int, hi : Int) => if v < lo { lo } else if v > hi { hi } else { v }
  let ceil_f = (f : Float) => f.ceil().to_int()
  let fract = (f : Float) => f - f.trunc()
  let byte_of = (f : Float) => {
    // (NumCast's: truncated toward zero)
    let i = f.to_int()
    if i < 0 { 0 } else if i > 255 { 255 } else { i }
  }
  for outy = 0; outy < th; outy = outy + 1 {
    let bottomf = Float::from_int(outy) * y_ratio
    let topf = bottomf + y_ratio
    let bottom = clamp(ceil_f(bottomf), 0, h - 1)
    let top = clamp(ceil_f(topf), bottom, h)
    for outx = 0; outx < tw; outx = outx + 1 {
      let leftf = Float::from_int(outx) * x_ratio
      let rightf = leftf + x_ratio
      let left = clamp(ceil_f(leftf), 0, w - 1)
      let right = clamp(ceil_f(rightf), left, w)
      let d = (outy * tw + outx) * 4
      for k = 0; k < 4; k = k + 1 {
        let v = if bottom != top && left != right {
          let mut sum = 0
          for x = left; x < right; x = x + 1 {
            for y = bottom; y < top; y = y + 1 {
              sum += px(x, y, k)
            }
          }
          let n = (right - left) * (top - bottom)
          (sum + n / 2) / n
        } else if bottom != top {
          // (left == right: the columns right - 1 and right, by the fraction of where it starts)
          let l = right - 1
          let mut sl = 0
          let mut sr = 0
          for y = bottom; y < top; y = y + 1 {
            sl += px(l, y, k)
            sr += px(l + 1, y, k)
          }
          let f = (fract(leftf) + fract(rightf)) / 2.0
          let rows = Float::from_int(top - bottom)
          byte_of((1.0 - f) / rows * Float::from_int(sl) + f / rows * Float::from_int(sr))
        } else if left != right {
          let b = top - 1
          let mut sb = 0
          let mut st = 0
          for x = left; x < right; x = x + 1 {
            sb += px(x, b, k)
            st += px(x, b + 1, k)
          }
          let f = (fract(topf) + fract(bottomf)) / 2.0
          let cols = Float::from_int(right - left)
          byte_of((1.0 - f) / cols * Float::from_int(sb) + f / cols * Float::from_int(st))
        } else {
          let l = right - 1
          let b = top - 1
          // (sample.rs `thumbnail_sample_fraction_both`, its sum in its order)
          let fv = (fract(topf) + fract(bottomf)) / 2.0
          let fh = (fract(leftf) + fract(rightf)) / 2.0
          let one : Float = 1.0
          let fact_tr = fv * fh
          let fact_tl = fv * (one - fh)
          let fact_br = (one - fv) * fh
          let fact_bl = (one - fv) * (one - fh)
          let bl = Float::from_int(px(l, b, k))
          let tl = Float::from_int(px(l, b + 1, k))
          let br = Float::from_int(px(l + 1, b, k))
          let tr = Float::from_int(px(l + 1, b + 1, k))
          byte_of(fact_br * br + fact_tr * tr + fact_bl * bl + fact_tl * tl)
        }
        out[d + k] = v.to_byte()
      }
    }
  }
  { w: tw, h: th, px: out }
}

// ── ThumbHash ──

///|
/// Rust's `f32::round`: half away from zero.
fn round_f(x : Float) -> Float {
  let half : Float = 0.5
  if x >= Float::from_int(0) {
    (x + half).floor()
  } else {
    -(-x + half).floor()
  }
}

///|
/// Rust's `as u8` / `as u32` of a float: truncated, saturated at 0.
fn uint_of(x : Float) -> Int {
  if x <= Float::from_int(0) || x != x {
    0
  } else {
    x.to_int()
  }
}

///|
/// thumbhash 0.1's `rgba_to_thumb_hash` (`w`, `h` at most 100), in f32 as it works.
pub fn rgba_to_thumb_hash(w : Int, h : Int, rgba : FixedArray[Byte]) -> Bytes {
  let f = (i : Int) => Float::from_int(i)
  let zero = f(0)
  let one = f(1)
  let c255 = f(255)
  let n = w * h
  let mut avg_r = zero
  let mut avg_g = zero
  let mut avg_b = zero
  let mut avg_a = zero
  for i = 0; i < n; i = i + 1 {
    let j = i * 4
    let alpha = f(rgba[j + 3].to_int()) / c255
    avg_r = avg_r + alpha / c255 * f(rgba[j].to_int())
    avg_g = avg_g + alpha / c255 * f(rgba[j + 1].to_int())
    avg_b = avg_b + alpha / c255 * f(rgba[j + 2].to_int())
    avg_a = avg_a + alpha
  }
  if avg_a > zero {
    avg_r = avg_r / avg_a
    avg_g = avg_g / avg_a
    avg_b = avg_b / avg_a
  }
  let has_alpha = avg_a < f(n)
  let l_limit = if has_alpha { 5 } else { 7 }
  let wh = if w > h { w } else { h }
  let lx0 = uint_of(round_f(f(l_limit * w) / f(wh)))
  let ly0 = uint_of(round_f(f(l_limit * h) / f(wh)))
  let lx = if lx0 < 1 { 1 } else { lx0 }
  let ly = if ly0 < 1 { 1 } else { ly0 }
  let l = FixedArray::make(n, zero)
  let p = FixedArray::make(n, zero)
  let q = FixedArray::make(n, zero)
  let a = FixedArray::make(n, zero)
  let two = f(2)
  let three = f(3)
  for i = 0; i < n; i = i + 1 {
    let j = i * 4
    let alpha = f(rgba[j + 3].to_int()) / c255
    let r = avg_r * (one - alpha) + alpha / c255 * f(rgba[j].to_int())
    let g = avg_g * (one - alpha) + alpha / c255 * f(rgba[j + 1].to_int())
    let b = avg_b * (one - alpha) + alpha / c255 * f(rgba[j + 2].to_int())
    l[i] = (r + g + b) / three
    p[i] = (r + g) / two - b
    q[i] = r - g
    a[i] = alpha
  }
  let pi = Float::from_double(3.141592653589793)
  let half = one / two
  let encode = (channel : FixedArray[Float], nx : Int, ny : Int) => {
    let mut dc = zero
    let ac : Array[Float] = []
    let mut scale = zero
    let fx = FixedArray::make(w, zero)
    for cy = 0; cy < ny; cy = cy + 1 {
      let mut cx = 0
      while cx * ny < nx * (ny - cy) {
        let mut sum = zero
        for x = 0; x < w; x = x + 1 {
          fx[x] = @math.cosf(pi / f(w) * f(cx) * (f(x) + half))
        }
        for y = 0; y < h; y = y + 1 {
          let fy = @math.cosf(pi / f(h) * f(cy) * (f(y) + half))
          for x = 0; x < w; x = x + 1 {
            sum = sum + channel[x + y * w] * fx[x] * fy
          }
        }
        sum = sum / f(n)
        if cx > 0 || cy > 0 {
          ac.push(sum)
          let m = sum.abs()
          if m > scale {
            scale = m
          }
        } else {
          dc = sum
        }
        cx += 1
      }
    }
    if scale > zero {
      for k = 0; k < ac.length(); k = k + 1 {
        ac[k] = half + half / scale * ac[k]
      }
    }
    (dc, ac, scale)
  }
  let (l_dc, l_ac, l_scale) = encode(l, if lx > 3 { lx } else { 3 }, if ly > 3 { ly } else { 3 })
  let (p_dc, p_ac, p_scale) = encode(p, 3, 3)
  let (q_dc, q_ac, q_scale) = encode(q, 3, 3)
  let (a_dc, a_ac, a_scale) = if has_alpha { encode(a, 5, 5) } else { (one, [], one) }
  let landscape = w > h
  let r = (x : Float) => uint_of(round_f(x))
  let c = (d : Double) => Float::from_double(d)
  let header24 = r(c(63.0) * l_dc) |
    (r(c(31.5) + c(31.5) * p_dc) << 6) |
    (r(c(31.5) + c(31.5) * q_dc) << 12) |
    (r(c(31.0) * l_scale) << 18) |
    (if has_alpha { 1 << 23 } else { 0 })
  let header16 = (if landscape { ly } else { lx }) |
    ((r(c(63.0) * p_scale) & 0xFFFF) << 3) |
    ((r(c(63.0) * q_scale) & 0xFFFF) << 9) |
    (if landscape { 1 << 15 } else { 0 })
  let hash : Array[Int] = [
    header24 & 255,
    (header24 >> 8) & 255,
    (header24 >> 16) & 255,
    header16 & 255,
    (header16 >> 8) & 255,
  ]
  let u8 = (x : Float) => {
    let v = r(x)
    if v > 255 { 255 } else { v }
  }
  if has_alpha {
    hash.push((u8(c(15.0) * a_dc) | (u8(c(15.0) * a_scale) << 4)) & 255)
  }
  let mut odd = false
  let put = (x : Float) => {
    let u = u8(c(15.0) * x)
    if odd {
      hash[hash.length() - 1] = (hash[hash.length() - 1] | (u << 4)) & 255
    } else {
      hash.push(u)
    }
    odd = !odd
  }
  for x in l_ac {
    put(x)
  }
  for x in p_ac {
    put(x)
  }
  for x in q_ac {
    put(x)
  }
  if has_alpha {
    for x in a_ac {
      put(x)
    }
  }
  Bytes::makei(hash.length(), i => hash[i].to_byte())
}

// ── PNG, compressed ──

///|
fn paeth(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = (p - a).abs()
  let pb = (p - b).abs()
  let pc = (p - c).abs()
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// A byte as PNG's filter `f` makes it of the byte, the one left of it, above it and above-left.
fn filtered_byte(f : Int, cur : Int, left : Int, up : Int, ul : Int) -> Int {
  let v = match f {
    0 => cur
    1 => cur - left
    2 => cur - up
    3 => cur - (left + up) / 2
    _ => cur - paeth(left, up, ul)
  }
  v & 255
}

///|
/// RGBA as a PNG compressed: each row filtered by whichever of PNG's five sums smallest.
fn png_compressed(img : Image) -> Bytes {
  let stride = img.w * 4
  let filtered = FixedArray::make((stride + 1) * img.h, b'\x00')
  let row = FixedArray::make(stride, 0)
  for y = 0; y < img.h; y = y + 1 {
    let mut best = 0
    let mut best_sum = -1
    for f = 0; f < 5; f = f + 1 {
      let mut sum = 0
      for x = 0; x < stride; x = x + 1 {
        let cur = img.px[y * stride + x].to_int()
        let left = if x >= 4 { img.px[y * stride + x - 4].to_int() } else { 0 }
        let up = if y > 0 { img.px[(y - 1) * stride + x].to_int() } else { 0 }
        let ul = if y > 0 && x >= 4 { img.px[(y - 1) * stride + x - 4].to_int() } else { 0 }
        let v = filtered_byte(f, cur, left, up, ul)
        sum += if v < 128 { v } else { 256 - v }
      }
      if best_sum < 0 || sum < best_sum {
        best_sum = sum
        best = f
      }
    }
    for x = 0; x < stride; x = x + 1 {
      let cur = img.px[y * stride + x].to_int()
      let left = if x >= 4 { img.px[y * stride + x - 4].to_int() } else { 0 }
      let up = if y > 0 { img.px[(y - 1) * stride + x].to_int() } else { 0 }
      let ul = if y > 0 && x >= 4 { img.px[(y - 1) * stride + x - 4].to_int() } else { 0 }
      row[x] = filtered_byte(best, cur, left, up, ul)
    }
    let at = y * (stride + 1)
    filtered[at] = best.to_byte()
    for x = 0; x < stride; x = x + 1 {
      filtered[at + 1 + x] = row[x].to_byte()
    }
  }
  let out = @buffer.Buffer()
  for b in [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
    out.write_byte(b.to_byte())
  }
  let chunk = (kind : String, body : Bytes) => {
    let n = body.length()
    for s in [24, 16, 8, 0] {
      out.write_byte(((n >> s) & 255).to_byte())
    }
    let typed = @buffer.Buffer()
    for i = 0; i < 4; i = i + 1 {
      typed.write_byte(kind[i].to_int().to_byte())
    }
    typed.write_bytes(body)
    let all = typed.to_bytes()
    out.write_bytes(all)
    let crc = @zip.crc32(all).reinterpret_as_int()
    for s in [24, 16, 8, 0] {
      out.write_byte(((crc >> s) & 255).to_byte())
    }
  }
  let ihdr = @buffer.Buffer()
  for v in [img.w, img.h] {
    for s in [24, 16, 8, 0] {
      ihdr.write_byte(((v >> s) & 255).to_byte())
    }
  }
  for b in [8, 6, 0, 0, 0] {
    ihdr.write_byte(b.to_byte())
  }
  chunk("IHDR", ihdr.to_bytes())
  chunk("IDAT", @flate.zlib_compress(Bytes::from_array(filtered)))
  chunk("IEND", b"")
  out.to_bytes()
}

///|
/// What a thumbnail is made of an image as it is seen: its type ("image/png" or "image/jpeg"), extension and bytes;
/// None where it would be no smaller than the image's `len`.
pub fn made_small(img : Image, len : Double) -> (String, String, Bytes)? {
  let small = if img.w > thumb_max_w || img.h > thumb_max_h {
    let (nw, nh) = fit_within(img.w, img.h, thumb_max_w, thumb_max_h)
    resize(img, nw, nh)
  } else {
    img
  }
  let mut clear = false
  for i = 3; i < small.px.length(); i = i + 4 {
    if small.px[i] != b'\xFF' {
      clear = true
      break
    }
  }
  let (ext, kind, bytes) = if clear {
    ("png", "image/png", png_compressed(small))
  } else {
    ("jpg", "image/jpeg", @pixels.jpeg(small.w, small.h, small.px, quality=88))
  }
  if bytes.length().to_double() >= len {
    return None
  }
  Some((ext, kind, bytes))
}

///|
/// The image's ThumbHash (base64), taken of it at most 100px across (thumbs.rs `hash`).
pub fn hash_of(img : Image) -> String {
  let small = thumbnail_sized(img, 100, 100)
  @codec.base64(rgba_to_thumb_hash(small.w, small.h, small.px))
}

///|
/// An image this small (or smaller) is shown itself.
pub let small_len : Double = 24576.0
