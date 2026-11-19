// JavaScript's ways with strings the TypeScript goes by: `trim`, `trimEnd`, `toLowerCase`, `encodeURIComponent`,
// `startsWith`, `\s`.

///|
pub fn is_js_space(c : Int) -> Bool {
  @jscase.is_space(c)
}

///|
pub fn trim(s : String) -> String {
  @jscase.trim(s)
}

///|
pub fn trim_end(s : String) -> String {
  let mut end = s.length()
  while end > 0 && is_js_space(s.unsafe_charcode_at(end - 1)) {
    end -= 1
  }
  s.unsafe_substring(start=0, end~)
}

///|
pub fn trim_start(s : String) -> String {
  let mut start = 0
  while start < s.length() && is_js_space(s.unsafe_charcode_at(start)) {
    start += 1
  }
  s.unsafe_substring(start~, end=s.length())
}

///|
pub fn lower(s : String) -> String {
  @jscase.lower(s)
}

///|
pub fn starts(s : String, p : String) -> Bool {
  s.has_prefix(p)
}

///|
pub fn ends(s : String, p : String) -> Bool {
  s.has_suffix(p)
}

///|
/// `s.slice(a, b)` in UTF-16 units, as JavaScript clamps it.
pub fn slice(s : String, a : Int, b? : Int) -> String {
  let n = s.length()
  let norm = (x : Int) => if x < 0 { @cmp.maximum(0, n + x) } else { @cmp.minimum(x, n) }
  let start = norm(a)
  let end = match b {
    Some(e) => norm(e)
    None => n
  }
  if start >= end {
    ""
  } else {
    s.unsafe_substring(start~, end~)
  }
}

///|
/// `s.indexOf(t, from)`.
pub fn index_of(s : String, t : String, from? : Int = 0) -> Int {
  let n = s.length()
  let m = t.length()
  let mut i = @cmp.maximum(0, from)
  while i + m <= n {
    if s.unsafe_substring(start=i, end=i + m) == t {
      return i
    }
    i += 1
  }
  -1
}

///|
pub fn last_index_of(s : String, t : String) -> Int {
  let n = s.length()
  let m = t.length()
  let mut i = n - m
  while i >= 0 {
    if s.unsafe_substring(start=i, end=i + m) == t {
      return i
    }
    i -= 1
  }
  -1
}

///|
/// `s.split(sep)` for a sep that is not empty.
pub fn split(s : String, sep : String) -> Array[String] {
  let out = []
  let mut start = 0
  while true {
    let i = index_of(s, sep, from=start)
    if i < 0 {
      out.push(slice(s, start))
      break
    }
    out.push(slice(s, start, b=i))
    start = i + sep.length()
  }
  out
}

///|
pub fn replace_all(s : String, from : String, to : String) -> String {
  split(s, from).join(to)
}

///|
/// The UTF-8 bytes of a string (lone surrogates as U+FFFD, as Buffer.from does).
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
}

///|
/// `Buffer.byteLength(s)`.
pub fn byte_length(s : String) -> Int {
  utf8(s).length()
}

///|
/// `encodeURIComponent`.
pub fn encode_uri_component(s : String) -> String {
  @url.encode_uri_component(s)
}

///|
/// Two strings compared as JavaScript compares them (`<`): by their UTF-16 code units, the first that differs.
pub fn js_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = a.unsafe_charcode_at(i)
    let y = b.unsafe_charcode_at(i)
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  a.length() - b.length()
}

///|
/// The same of strings as code units (`Array[Int]`).
pub fn units_compare(a : Array[Int], b : Array[Int]) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    if a[i] != b[i] {
      return if a[i] < b[i] { -1 } else { 1 }
    }
  }
  a.length() - b.length()
}
