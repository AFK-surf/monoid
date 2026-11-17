// Strings as JavaScript holds them (UTF-16 code units, a lone surrogate kept), and what the TypeScript station did to
// them: compared, cut by code points, trimmed, lowercased, and encoded as node:sqlite binds them and Buffer counts them.

///|
fn units(s : String) -> Array[Int32] {
  @jsjson.units(s)
}

///|
/// `a < b`, `a == b`, `a > b` as JavaScript compares two strings: by code units.
fn compare_units(a : Array[Int32], b : Array[Int32]) -> Int32 {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return if a[i] < b[i] { -1 } else { 1 }
    }
  }
  a.length() - b.length()
}

///|
fn equal_units(a : Array[Int32], b : Array[Int32]) -> Bool {
  compare_units(a, b) == 0
}

///|
fn high(c : Int32) -> Bool {
  c >= 0xd800 && c <= 0xdbff
}

///|
fn low(c : Int32) -> Bool {
  c >= 0xdc00 && c <= 0xdfff
}

///|
/// The code points of `s` as `[...s]` gives them: a pair one, a lone surrogate one of its own.
fn points(s : Array[Int32]) -> Array[Int32] {
  let out = []
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s[i]
    if high(c) && i + 1 < n && low(s[i + 1]) {
      out.push(0x10000 + ((c - 0xd800) << 10) + (s[i + 1] - 0xdc00))
      i += 2
    } else {
      out.push(c)
      i += 1
    }
  }
  out
}

///|
fn push_point(out : Array[Int32], cp : Int32) -> Unit {
  if cp >= 0x10000 {
    let v = cp - 0x10000
    out.push(0xd800 + (v >> 10))
    out.push(0xdc00 + (v & 0x3ff))
  } else {
    out.push(cp)
  }
}

///|
/// `[...value].slice(0, max).join("")`.
fn cut_points(value : Array[Int32], max : Int32) -> Array[Int32] {
  let out = []
  for i, cp in points(value) {
    if i >= max {
      break
    }
    push_point(out, cp)
  }
  out
}

///|
/// What JavaScript's `\s` and `trim` take as white space.
fn white(c : Int32) -> Bool {
  match c {
    0x09
    | 0x0a
    | 0x0b
    | 0x0c
    | 0x0d
    | 0x20
    | 0xa0
    | 0x1680
    | 0x2028
    | 0x2029
    | 0x202f
    | 0x205f
    | 0x3000
    | 0xfeff => true
    _ => c >= 0x2000 && c <= 0x200a
  }
}

///|
/// `s.trim()`.
fn trim(s : Array[Int32]) -> Array[Int32] {
  let mut start = 0
  let mut end = s.length()
  while start < end && white(s[start]) {
    start += 1
  }
  while end > start && white(s[end - 1]) {
    end -= 1
  }
  s[start:end].to_owned()
}

///|
fn in_ranges(table : FixedArray[(Int32, Int32)], cp : Int32) -> Bool {
  let mut lo = 0
  let mut hi = table.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (start, end) = table[mid]
    if cp < start {
      hi = mid
    } else if cp > end {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// One code point's lowercase as Node's toLowerCase gives it (lower_table.mbt), the capital sigma's aside.
fn lower_point(out : Array[Int32], cp : Int32) -> Unit {
  for m in lower_more {
    if m.0 == cp {
      for c in m.1 {
        push_point(out, c)
      }
      return
    }
  }
  let mut lo = 0
  let mut hi = lower_ranges.length()
  while lo < hi {
    let mid = (lo + hi) / 2
    let (start, end, step, delta) = lower_ranges[mid]
    if cp < start {
      hi = mid
    } else if cp > end {
      lo = mid + 1
    } else {
      push_point(out, if (cp - start) % step == 0 { cp + delta } else { cp })
      return
    }
  }
  push_point(out, cp)
}

///|
/// `s.toLowerCase()`: each code point's lowercase, and a capital sigma final (ς) where Unicode's Final_Sigma says, as
/// V8 does: after a cased letter and not before one, case-ignorable ones between skipped.
fn lower(s : Array[Int32]) -> Array[Int32] {
  let cps = points(s)
  let out = []
  for i, cp in cps {
    if cp != 0x3a3 {
      lower_point(out, cp)
      continue
    }
    let mut before = false
    for j = i - 1; j >= 0; j = j - 1 {
      if in_ranges(ignorable_ranges, cps[j]) {
        continue
      }
      before = in_ranges(cased_ranges, cps[j])
      break
    }
    let mut after = false
    for j = i + 1; j < cps.length(); j = j + 1 {
      if in_ranges(ignorable_ranges, cps[j]) {
        continue
      }
      after = in_ranges(cased_ranges, cps[j])
      break
    }
    out.push(if before && !after { 0x3c2 } else { 0x3c3 })
  }
  out
}

///|
/// The UTF-8 node:sqlite binds and Buffer.from gives of a string: a lone surrogate as U+FFFD's.
fn utf8_of(s : Array[Int32]) -> Bytes {
  let out = @buffer.Buffer()
  for cp in points(s) {
    let c = if cp >= 0xd800 && cp <= 0xdfff { 0xfffd } else { cp }
    if c < 0x80 {
      out.write_byte(c.to_byte())
    } else if c < 0x800 {
      out.write_byte((0xc0 | (c >> 6)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    } else if c < 0x10000 {
      out.write_byte((0xe0 | (c >> 12)).to_byte())
      out.write_byte((0x80 | ((c >> 6) & 0x3f)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    } else {
      out.write_byte((0xf0 | (c >> 18)).to_byte())
      out.write_byte((0x80 | ((c >> 12) & 0x3f)).to_byte())
      out.write_byte((0x80 | ((c >> 6) & 0x3f)).to_byte())
      out.write_byte((0x80 | (c & 0x3f)).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// How many bytes of UTF-8 a well-formed string is (Buffer.byteLength).
fn utf8_length(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    let v = c.to_int()
    n += if v < 0x80 {
      1
    } else if v < 0x800 {
      2
    } else if v < 0x10000 {
      3
    } else {
      4
    }
  }
  n
}

///|
fn hex_of(b : Bytes) -> String {
  let digits = "0123456789abcdef"
  let out = StringBuilder()
  for x in b {
    let v = x.to_int()
    out.write_char(digits.unsafe_charcode_at(v >> 4).unsafe_to_char())
    out.write_char(digits.unsafe_charcode_at(v & 0xf).unsafe_to_char())
  }
  out.to_string()
}

///|
/// Bytes as Buffer's `toString("utf8")` reads them: what is not UTF-8 as U+FFFD.
fn decoded(b : Bytes) -> Array[Int32] {
  units(@utf8.decode_lossy(b))
}
