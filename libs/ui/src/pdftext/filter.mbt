// What a PDF's streams are packed with, undone: each bounded, what is damaged read as nothing.

///|
fn flate(data : Bytes, most : Int) -> Bytes? {
  if data.length() < 2 {
    return None
  }
  // (a zlib head is two bytes; a few writers leave it off)
  let head = data[0].to_int() * 256 + data[1].to_int()
  let zlib = (data[0].to_int() & 15) == 8 && head % 31 == 0
  @zip.inflate_most(data, most, start=if zlib { 2 } else { 0 })
}

///|
fn ascii85(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let group = FixedArray::make(5, 0)
  let mut n = 0
  for i in 0..<data.length() {
    let c = data[i].to_int()
    if is_space(c) {
      continue
    }
    if c == 126 {
      break
    }
    if c == 122 && n == 0 {
      for _ in 0..<4 {
        out.push(b'\x00')
      }
      continue
    }
    if c < 33 || c > 117 {
      break
    }
    group[n] = c - 33
    n += 1
    if n == 5 {
      push85(out, group, 4)
      n = 0
    }
  }
  if n > 1 {
    for k in n..<5 {
      group[k] = 84
    }
    push85(out, group, n - 1)
  }
  Bytes::from_array(out)
}

///|
fn push85(out : Array[Byte], group : FixedArray[Int], count : Int) -> Unit {
  let mut v = 0UL
  for k in 0..<5 {
    v = v * 85UL + group[k].to_uint64()
  }
  for k in 0..<count {
    out.push(((v >> (24 - 8 * k)) & 255UL).to_int().to_byte())
  }
}

///|
fn ascii_hex(data : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut high = -1
  for i in 0..<data.length() {
    let c = data[i].to_int()
    if c == 62 {
      break
    }
    let v = hex_value(c)
    if v < 0 {
      continue
    }
    if high < 0 {
      high = v
    } else {
      out.push((high * 16 + v).to_byte())
      high = -1
    }
  }
  if high >= 0 {
    out.push((high * 16).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn lzw(data : Bytes, most : Int) -> Bytes? {
  let out : Array[Byte] = []
  // (each entry past the first 258: the entry it adds to, and the byte it adds)
  let prev : Array[Int] = []
  let last : Array[Int] = []
  let mut width = 9
  let mut buf = 0
  let mut bits = 0
  let mut was = -1
  let scratch : Array[Int] = []
  let first_of = fn(code : Int) {
    let mut c = code
    while c >= 258 {
      c = prev[c - 258]
    }
    c
  }
  let emit = fn(code : Int) {
    scratch.clear()
    let mut c = code
    while c >= 258 {
      scratch.push(last[c - 258])
      c = prev[c - 258]
    }
    scratch.push(c)
    for k = scratch.length() - 1; k >= 0; k = k - 1 {
      out.push(scratch[k].to_byte())
    }
  }
  for i in 0..<data.length() {
    buf = ((buf << 8) | data[i].to_int()) & 0xFFFFFF
    bits += 8
    while bits >= width {
      let code = (buf >> (bits - width)) & ((1 << width) - 1)
      bits -= width
      if code == 256 {
        prev.clear()
        last.clear()
        width = 9
        was = -1
        continue
      }
      if code == 257 {
        return Some(Bytes::from_array(out))
      }
      let next = 258 + prev.length()
      if was < 0 {
        if code > 255 {
          return None
        }
        emit(code)
      } else if code < next {
        emit(code)
        prev.push(was)
        last.push(first_of(code))
      } else if code == next {
        prev.push(was)
        last.push(first_of(was))
        emit(code)
      } else {
        return None
      }
      if out.length() > most {
        return None
      }
      was = code
      let size = 258 + prev.length()
      width = if size >= 2047 {
        12
      } else if size >= 1023 {
        11
      } else if size >= 511 {
        10
      } else {
        9
      }
      if size >= 4096 {
        return None
      }
    }
  }
  Some(Bytes::from_array(out))
}

///|
/// `data` with the predictor of `parms` undone (PNG's and TIFF's for bytes of one colour component a pixel).
fn Objects::predictor(self : Objects, data : Bytes, parms : Obj) -> Bytes? {
  guard parms is Dict(p) else { return Some(data) }
  let pred = self.int_of(p.get("Predictor"), 1)
  if pred <= 1 {
    return Some(data)
  }
  let colors = self.int_of(p.get("Colors"), 1)
  let bpc = self.int_of(p.get("BitsPerComponent"), 8)
  let cols = self.int_of(p.get("Columns"), 1)
  guard colors > 0 && colors <= 32 && bpc > 0 && bpc <= 16 && cols > 0 && cols <= 1048576 else { return None }
  let bpp = imax((colors * bpc + 7) / 8, 1)
  let row = (colors * bpc * cols + 7) / 8
  if pred == 2 {
    if bpc != 8 {
      return Some(data)
    }
    let out = data.to_array()
    let rows = out.length() / row
    for r in 0..<rows {
      for x in bpp..<row {
        let at = r * row + x
        out[at] = ((out[at].to_int() + out[at - bpp].to_int()) & 255).to_byte()
      }
    }
    return Some(Bytes::from_array(out))
  }
  let rows = (data.length() + row) / (row + 1)
  let out : FixedArray[Byte] = FixedArray::make(rows * row, b'\x00')
  for r in 0..<rows {
    let from = r * (row + 1)
    let kind = data[from].to_int()
    let have = imin(row, data.length() - from - 1)
    for x in 0..<have {
      let at = r * row + x
      let left = if x >= bpp { out[at - bpp].to_int() } else { 0 }
      let up = if r > 0 { out[at - row].to_int() } else { 0 }
      let corner = if r > 0 && x >= bpp { out[at - row - bpp].to_int() } else { 0 }
      let add = match kind {
        1 => left
        2 => up
        3 => (left + up) / 2
        4 => paeth(left, up, corner)
        _ => 0
      }
      out[at] = ((data[from + 1 + x].to_int() + add) & 255).to_byte()
    }
  }
  Some(Bytes::makei(out.length(), fn(i) { out[i] }))
}

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
