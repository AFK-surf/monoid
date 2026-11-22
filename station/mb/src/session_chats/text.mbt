// JavaScript's ways with strings the TypeScript goes by: `trim`, `trimEnd`, `toLowerCase`, `encodeURIComponent`,
// `startsWith`, `\s`.

///|
pub using @jscase {is_space as is_js_space, trim, trim_end, trim_start, lower}

///|
pub using @jsjson {
  js_starts as starts, js_ends as ends, js_index_of as index_of, js_last_index_of as last_index_of,
  js_split as split, js_replace_all as replace_all, js_utf8_len as byte_length, js_compare,
}

///|
pub using @url {encode_uri_component}

///|
/// `s.slice(a, b)` in UTF-16 units, as JavaScript clamps it.
pub fn slice(s : String, a : Int, b? : Int) -> String {
  @jsjson.js_slice(s, a, end?=b)
}

///|
/// The UTF-8 bytes of a string (lone surrogates as U+FFFD, as Buffer.from does).
pub fn utf8(s : String) -> Bytes {
  @utf8.encode(s)
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
