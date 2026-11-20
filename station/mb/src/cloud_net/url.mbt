// A URL as the WHATWG URL Standard parses one with no base (what Node's `new URL(raw)` and `URL.canParse(raw)` do), as
// far as the station's relays, cloud origins and marks' pictures need: the special schemes (http, https, ws, wss, ftp,
// file) parsed whole (hosts lowercased, IPv4 and IPv6 hosts normalised, default ports dropped, dot segments resolved,
// what is percent-encoded encoded), any other scheme's rest kept as its opaque path or authority. A non-ASCII domain is
// made ASCII by Punycode over its labels lowercased (no further UTS #46 mapping: what a relay's or a cloud's address
// never holds).

///|
/// A URL parsed: `href` is what `URL.href` serialises, `origin` what `URL.origin` does.
pub struct Url {
  scheme : String
  username : String
  password : String
  /// None: no host (an opaque path); Some(""): an empty host (`file:///x`).
  host : String?
  port : Int?
  /// The path serialised (`URL.pathname`).
  path : String
  /// Without its `?`; None where there is none (an empty one still shows in `href`).
  query : String?
  fragment : String?
}

///|
fn special_port(scheme : String) -> Int? {
  match scheme {
    "http" | "ws" => Some(80)
    "https" | "wss" => Some(443)
    "ftp" => Some(21)
    _ => None
  }
}

///|
fn is_special(scheme : String) -> Bool {
  special_port(scheme) is Some(_) || scheme == "file"
}

///|
fn is_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn lower_ascii(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    (c.to_int() + 32).unsafe_to_char()
  } else {
    c
  }
}

///|
fn utf8_of(c : Char) -> Array[Int] {
  let n = c.to_int()
  if n < 0x80 {
    [n]
  } else if n < 0x800 {
    [0xC0 | (n >> 6), 0x80 | (n & 0x3F)]
  } else if n < 0x10000 {
    [0xE0 | (n >> 12), 0x80 | ((n >> 6) & 0x3F), 0x80 | (n & 0x3F)]
  } else {
    [
      0xF0 | (n >> 18),
      0x80 | ((n >> 12) & 0x3F),
      0x80 | ((n >> 6) & 0x3F),
      0x80 | (n & 0x3F),
    ]
  }
}

///|
/// The percent-encode sets (URL Standard 1.3), by which.
priv enum EncodeSet {
  C0
  Fragment
  Query
  SpecialQuery
  Path
  Userinfo
}

///|
fn in_set(set : EncodeSet, c : Char) -> Bool {
  let n = c.to_int()
  if n < 0x20 || n > 0x7E {
    return true
  }
  let fragment = c == ' ' || c == '"' || c == '<' || c == '>' || c == '`'
  let query = c == ' ' || c == '"' || c == '#' || c == '<' || c == '>'
  let path = query || c == '?' || c == '^' || c == '`' || c == '{' || c == '}'
  match set {
    C0 => false
    Fragment => fragment
    Query => query
    SpecialQuery => query || c == '\''
    Path => path
    Userinfo =>
      path ||
      c == '/' ||
      c == ':' ||
      c == ';' ||
      c == '=' ||
      c == '@' ||
      (c >= '[' && c <= ']') ||
      c == '|'
  }
}

///|
fn encode_char(sb : StringBuilder, set : EncodeSet, c : Char) -> Unit {
  if in_set(set, c) {
    sb.write_string(@url.percent_encode(c.to_string(), _ => false))
  } else {
    sb.write_char(c)
  }
}

///|
fn encode_chars(cs : ArrayView[Char], set : EncodeSet) -> String {
  @url.percent_encode(String::from_array(cs), n => !in_set(set, n.unsafe_to_char()))
}

///|
/// The bytes `cs` percent-decode to (its characters' UTF-8, each `%XX` the byte it says).
fn pct_decode(cs : ArrayView[Char]) -> Array[Int] {
  let out = []
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if c == '%' && i + 2 < cs.length() {
      match (@codec.hex_digit(cs[i + 1].to_int()), @codec.hex_digit(cs[i + 2].to_int())) {
        (Some(a), Some(b)) => {
          out.push(a * 16 + b)
          i += 3
          continue
        }
        _ => ()
      }
    }
    for b in utf8_of(c) {
      out.push(b)
    }
    i += 1
  }
  out
}

///|
/// `bytes` as UTF-8 without BOM handling, each malformed sequence U+FFFD (as the Encoding Standard's decoder).
fn utf8_decode(bytes : Array[Int]) -> Array[Char] {
  let out = []
  let mut i = 0
  let n = bytes.length()
  while i < n {
    let b = bytes[i]
    if b < 0x80 {
      out.push(b.unsafe_to_char())
      i += 1
      continue
    }
    let (need, lo, hi, init) = if b >= 0xC2 && b <= 0xDF {
      (1, 0x80, 0xBF, b & 0x1F)
    } else if b == 0xE0 {
      (2, 0xA0, 0xBF, b & 0xF)
    } else if b == 0xED {
      (2, 0x80, 0x9F, b & 0xF)
    } else if b >= 0xE1 && b <= 0xEF {
      (2, 0x80, 0xBF, b & 0xF)
    } else if b == 0xF0 {
      (3, 0x90, 0xBF, b & 7)
    } else if b == 0xF4 {
      (3, 0x80, 0x8F, b & 7)
    } else if b >= 0xF1 && b <= 0xF3 {
      (3, 0x80, 0xBF, b & 7)
    } else {
      (0, 0, 0, 0)
    }
    if need == 0 {
      out.push('\u{FFFD}')
      i += 1
      continue
    }
    let mut cp = init
    let mut j = 1
    let mut ok = true
    while j <= need {
      if i + j >= n {
        ok = false
        break
      }
      let c = bytes[i + j]
      let (l, h) = if j == 1 { (lo, hi) } else { (0x80, 0xBF) }
      if c < l || c > h {
        ok = false
        break
      }
      cp = (cp << 6) | (c & 0x3F)
      j += 1
    }
    if ok {
      out.push(cp.unsafe_to_char())
      i += need + 1
    } else {
      out.push('\u{FFFD}')
      i += j
    }
  }
  out
}

///|
fn forbidden_host(c : Char) -> Bool {
  c == '\u{0}' ||
  c == '\t' ||
  c == '\n' ||
  c == '\r' ||
  c == ' ' ||
  c == '#' ||
  c == '/' ||
  c == ':' ||
  c == '<' ||
  c == '>' ||
  c == '?' ||
  c == '@' ||
  c == '[' ||
  c == '\\' ||
  c == ']' ||
  c == '^' ||
  c == '|'
}

///|
fn forbidden_domain(c : Char) -> Bool {
  let n = c.to_int()
  forbidden_host(c) || (n >= 0 && n <= 0x1F) || c == '%' || n == 0x7F
}

///|
/// One part of an IPv4 address (decimal, `0x` hex or `0` octal); None where it is none.
fn ipv4_number(s : ArrayView[Char]) -> Int64? {
  if s.length() == 0 {
    return None
  }
  let mut radix = 10
  let mut start = 0
  if s.length() >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
    radix = 16
    start = 2
  } else if s.length() >= 2 && s[0] == '0' {
    radix = 8
    start = 1
  }
  if start == s.length() {
    return Some(0L)
  }
  let mut v = 0L
  for i in start..<s.length() {
    let c = s[i]
    let d = match @codec.hex_digit(c.to_int()) {
      Some(d) if d < radix => d
      _ => return None
    }
    v = v * radix.to_int64() + d.to_int64()
    if v > 0xFFFFFFFFFFL {
      // (past what any part may be: failure follows; kept from overflowing)
      v = 0xFFFFFFFFFFL
    }
  }
  Some(v)
}

///|
fn split_dots(s : ArrayView[Char]) -> Array[ArrayView[Char]] {
  let parts = []
  let mut from = 0
  for i in 0..<s.length() {
    if s[i] == '.' {
      parts.push(s[from:i])
      from = i + 1
    }
  }
  parts.push(s[from:])
  parts
}

///|
/// Whether a domain ends in a number (URL Standard's "ends in a number checker"): it is then an IPv4 address.
fn ends_in_number(s : ArrayView[Char]) -> Bool {
  let parts = split_dots(s)
  if parts[parts.length() - 1].length() == 0 {
    if parts.length() == 1 {
      return false
    }
    ignore(parts.pop())
  }
  let last = parts[parts.length() - 1]
  if last.length() > 0 && last.iter().all(is_digit) {
    return true
  }
  ipv4_number(last) is Some(_)
}

///|
fn ipv4_parse(s : ArrayView[Char]) -> String? {
  let parts = split_dots(s)
  if parts[parts.length() - 1].length() == 0 && parts.length() > 1 {
    ignore(parts.pop())
  }
  if parts.length() > 4 {
    return None
  }
  let nums = []
  for p in parts {
    match ipv4_number(p) {
      Some(n) => nums.push(n)
      None => return None
    }
  }
  for i in 0..<(nums.length() - 1) {
    if nums[i] > 255L {
      return None
    }
  }
  let last = nums[nums.length() - 1]
  let limit = 1L << (8 * (5 - nums.length()))
  if last >= limit {
    return None
  }
  let mut v = last
  for i in 0..<(nums.length() - 1) {
    v = v + (nums[i] << (8 * (3 - i)))
  }
  Some(
    "\{(v >> 24) & 255L}.\{(v >> 16) & 255L}.\{(v >> 8) & 255L}.\{v & 255L}",
  )
}

///|
fn ipv6_parse(s : ArrayView[Char]) -> String? {
  let a : FixedArray[Int] = FixedArray::make(8, 0)
  let mut piece = 0
  let mut compress = -1
  let mut i = 0
  let n = s.length()
  if n > 0 && s[0] == ':' {
    if n < 2 || s[1] != ':' {
      return None
    }
    i = 2
    piece = 1
    compress = 1
  }
  while i < n {
    if piece == 8 {
      return None
    }
    if s[i] == ':' {
      if compress != -1 {
        return None
      }
      i += 1
      piece += 1
      compress = piece
      continue
    }
    let mut value = 0
    let mut len = 0
    while len < 4 && i < n && @codec.hex_digit(s[i].to_int()) is Some(_) {
      value = value * 16 + @codec.hex_digit(s[i].to_int()).unwrap()
      i += 1
      len += 1
    }
    if i < n && s[i] == '.' {
      if len == 0 {
        return None
      }
      i -= len
      if piece > 6 {
        return None
      }
      let mut seen = 0
      while i < n {
        let mut v4 = -1
        if seen > 0 {
          if s[i] == '.' && seen < 4 {
            i += 1
          } else {
            return None
          }
        }
        if i >= n || !is_digit(s[i]) {
          return None
        }
        while i < n && is_digit(s[i]) {
          let d = s[i].to_int() - '0'.to_int()
          if v4 == -1 {
            v4 = d
          } else if v4 == 0 {
            return None
          } else {
            v4 = v4 * 10 + d
          }
          if v4 > 255 {
            return None
          }
          i += 1
        }
        a[piece] = a[piece] * 0x100 + v4
        seen += 1
        if seen == 2 || seen == 4 {
          piece += 1
        }
      }
      if seen != 4 {
        return None
      }
      break
    } else if i < n && s[i] == ':' {
      i += 1
      if i >= n {
        return None
      }
    } else if i < n {
      return None
    }
    a[piece] = value
    piece += 1
  }
  if compress != -1 {
    let mut swaps = piece - compress
    piece = 7
    while piece != 0 && swaps > 0 {
      let t = a[piece]
      a[piece] = a[compress + swaps - 1]
      a[compress + swaps - 1] = t
      piece -= 1
      swaps -= 1
    }
  } else if piece != 8 {
    return None
  }
  // The longest run of zeros (two or more) compressed, the first of equal ones.
  let mut best = -1
  let mut best_len = 1
  let mut j = 0
  while j < 8 {
    if a[j] == 0 {
      let mut k = j
      while k < 8 && a[k] == 0 {
        k += 1
      }
      if k - j > best_len {
        best = j
        best_len = k - j
      }
      j = k
    } else {
      j += 1
    }
  }
  let sb = StringBuilder()
  sb.write_char('[')
  let mut ignore0 = false
  for p in 0..<8 {
    if ignore0 && a[p] == 0 {
      continue
    }
    ignore0 = false
    if best == p {
      sb.write_string(if p == 0 { "::" } else { ":" })
      ignore0 = true
      continue
    }
    sb.write_string(a[p].to_string(radix=16))
    if p != 7 {
      sb.write_char(':')
    }
  }
  sb.write_char(']')
  Some(sb.to_string())
}

///|
/// A label's Punycode (RFC 3492), `xn--` in front; None where it overflows.
fn punycode(label : Array[Char]) -> String? {
  let base = 36
  let tmin = 1
  let tmax = 26
  let out = StringBuilder()
  let mut basic = 0
  for c in label {
    if c.to_int() < 0x80 {
      out.write_char(c)
      basic += 1
    }
  }
  let digit = (d : Int) => if d < 26 {
    (d + 'a'.to_int()).unsafe_to_char()
  } else {
    (d - 26 + '0'.to_int()).unsafe_to_char()
  }
  let adapt = (delta : Int, points : Int, first : Bool) => {
    let mut d = if first { delta / 700 } else { delta / 2 }
    d = d + d / points
    let mut k = 0
    while d > (base - tmin) * tmax / 2 {
      d = d / (base - tmin)
      k += base
    }
    k + (base - tmin + 1) * d / (d + 38)
  }
  if basic > 0 {
    out.write_char('-')
  }
  let mut n = 128
  let mut delta = 0
  let mut bias = 72
  let mut h = basic
  let total = label.length()
  while h < total {
    let mut m = 0x7FFFFFFF
    for c in label {
      let v = c.to_int()
      if v >= n && v < m {
        m = v
      }
    }
    if (m - n).to_int64() * (h + 1).to_int64() + delta.to_int64() > 0x7FFFFFFFL {
      return None
    }
    delta += (m - n) * (h + 1)
    n = m
    for c in label {
      let v = c.to_int()
      if v < n {
        delta += 1
      }
      if v == n {
        let mut q = delta
        let mut k = base
        while true {
          let t = if k <= bias {
            tmin
          } else if k >= bias + tmax {
            tmax
          } else {
            k - bias
          }
          if q < t {
            break
          }
          out.write_char(digit(t + (q - t) % (base - t)))
          q = (q - t) / (base - t)
          k += base
        }
        out.write_char(digit(q))
        bias = adapt(delta, h + 1, h == basic)
        delta = 0
        h += 1
      }
    }
    delta += 1
    n += 1
  }
  Some("xn--" + out.to_string())
}

///|
/// A domain made ASCII: each label lowercased, a non-ASCII one by Punycode. None where it is none.
fn domain_to_ascii(cs : Array[Char]) -> String? {
  let labels = []
  let mut cur = []
  let flush = (cur : Array[Char]) => {
    if cur.iter().all(c => c.to_int() < 0x80) {
      Some(String::from_array(cur.map(lower_ascii)))
    } else {
      // (lowercased as far as a plain case mapping does: what the relays' addresses hold)
      punycode(cur.map(c => lower_ascii(c)))
    }
  }
  for c in cs {
    let cp = c.to_int()
    if c == '\u{FFFD}' || (cp >= 0xFDD0 && cp <= 0xFDEF) || (cp & 0xFFFE) == 0xFFFE {
      return None
    }
    // (U+3002, U+FF0E and U+FF61 are full stops too, by UTS #46)
    if c == '.' || c == '\u{3002}' || c == '\u{FF0E}' || c == '\u{FF61}' {
      match flush(cur) {
        Some(l) => labels.push(l)
        None => return None
      }
      cur = []
    } else if c == '\u{AD}' || c == '\u{200B}' || c == '\u{2060}' || c == '\u{FEFF}' || c == '\u{200C}' || c == '\u{200D}' {
      // (mapped to nothing by UTS #46)
      continue
    } else {
      cur.push(c)
    }
  }
  match flush(cur) {
    Some(l) => labels.push(l)
    None => return None
  }
  let out = labels.join(".")
  if out.length() == 0 {
    return None
  }
  Some(out)
}

///|
/// A special URL's host (URL Standard's host parser, not opaque); None where it fails.
fn host_parse(cs : ArrayView[Char]) -> String? {
  if cs.length() > 0 && cs[0] == '[' {
    if cs[cs.length() - 1] != ']' {
      return None
    }
    return ipv6_parse(cs[1:cs.length() - 1])
  }
  let decoded = utf8_decode(pct_decode(cs))
  let ascii = match domain_to_ascii(decoded) {
    Some(a) => a
    None => return None
  }
  let chars = ascii.to_array()
  for c in chars {
    if forbidden_domain(c) {
      return None
    }
  }
  if ends_in_number(chars[:]) {
    return ipv4_parse(chars[:])
  }
  Some(ascii)
}

///|
/// A non-special URL's host (opaque); None where it fails.
fn opaque_host(cs : ArrayView[Char]) -> String? {
  if cs.length() > 0 && cs[0] == '[' {
    if cs[cs.length() - 1] != ']' {
      return None
    }
    return ipv6_parse(cs[1:cs.length() - 1])
  }
  for c in cs {
    if forbidden_host(c) {
      return None
    }
  }
  Some(encode_chars(cs, C0))
}

///|
fn single_dot(seg : String) -> Bool {
  seg == "." || seg.to_lower() == "%2e"
}

///|
fn double_dot(seg : String) -> Bool {
  let l = seg.to_lower()
  l == ".." || l == ".%2e" || l == "%2e." || l == "%2e%2e"
}

///|
fn windows_letter(seg : String, normalized : Bool) -> Bool {
  let cs = seg.to_array()
  cs.length() == 2 &&
  is_alpha(cs[0]) &&
  (cs[1] == ':' || (!normalized && cs[1] == '|'))
}

///|
/// A path's segments as parsed (path state), `special` taking `\` as `/`.
fn path_segments(
  cs : ArrayView[Char],
  special : Bool,
  file : Bool,
) -> Array[String] {
  let segs : Array[String] = []
  let mut cur = StringBuilder()
  let mut raw = []
  let n = cs.length()
  let mut i = 0
  // (a path given starts at its first segment: its leading slash already taken)
  while true {
    let at_end = i >= n
    let c = if at_end { '\u{0}' } else { cs[i] }
    if at_end || c == '/' || (special && c == '\\') {
      let seg = cur.to_string()
      if double_dot(seg) {
        if segs.length() > 0 &&
          !(file && segs.length() == 1 && windows_letter(segs[0], true)) {
          ignore(segs.pop())
        }
        if at_end {
          segs.push("")
        }
      } else if single_dot(seg) {
        if at_end {
          segs.push("")
        }
      } else {
        let seg = if file &&
          segs.length() == 0 &&
          windows_letter(String::from_array(raw), false) {
          let r = raw.copy()
          r[1] = ':'
          String::from_array(r)
        } else {
          seg
        }
        segs.push(seg)
      }
      cur = StringBuilder()
      raw = []
      if at_end {
        break
      }
    } else {
      encode_char(cur, Path, c)
      raw.push(c)
    }
    i += 1
  }
  segs
}

///|
/// `raw` parsed as an absolute URL; None where `new URL(raw)` throws.
pub fn parse_url(raw : String) -> Url? {
  // Leading and trailing C0 controls and spaces go, and every tab and newline.
  let all = raw.to_array()
  let mut from = 0
  let mut to = all.length()
  while from < to && all[from].to_int() <= 0x20 {
    from += 1
  }
  while to > from && all[to - 1].to_int() <= 0x20 {
    to -= 1
  }
  let cs : Array[Char] = []
  for i in from..<to {
    let c = all[i]
    if c != '\t' && c != '\n' && c != '\r' {
      cs.push(c)
    }
  }
  // The scheme.
  if cs.length() == 0 || !is_alpha(cs[0]) {
    return None
  }
  let mut i = 0
  let scheme_b = StringBuilder()
  while i < cs.length() &&
        (is_alpha(cs[i]) ||
        is_digit(cs[i]) ||
        cs[i] == '+' ||
        cs[i] == '-' ||
        cs[i] == '.') {
    scheme_b.write_char(lower_ascii(cs[i]))
    i += 1
  }
  if i >= cs.length() || cs[i] != ':' {
    return None
  }
  let scheme = scheme_b.to_string()
  i += 1
  let rest = cs[i:]
  // Where the fragment and the query start (never inside each other).
  let mut hash = -1
  for j in 0..<rest.length() {
    if rest[j] == '#' {
      hash = j
      break
    }
  }
  let before_hash = if hash >= 0 { rest[:hash] } else { rest }
  let fragment = if hash >= 0 {
    Some(encode_chars(rest[hash + 1:], Fragment))
  } else {
    None
  }
  let special = is_special(scheme)
  if scheme == "file" {
    return parse_file(before_hash, fragment)
  }
  if !special &&
    !(before_hash.length() >= 2 &&
    before_hash[0] == '/' &&
    before_hash[1] == '/') {
    // An opaque path (or a path with no host).
    let mut q = -1
    for j in 0..<before_hash.length() {
      if before_hash[j] == '?' {
        q = j
        break
      }
    }
    let p = if q >= 0 { before_hash[:q] } else { before_hash }
    let query = if q >= 0 {
      Some(encode_chars(before_hash[q + 1:], Query))
    } else {
      None
    }
    if p.length() > 0 && p[0] == '/' {
      let segs = path_segments(p[1:], false, false)
      let path = "/" + segs.join("/")
      return Some({
        scheme,
        username: "",
        password: "",
        host: None,
        port: None,
        path,
        query,
        fragment,
      })
    }
    // (an opaque path: C0 encoded; a trailing space before `?`/`#` is percent-encoded per WHATWG URL §4.3)
    let path = if p.length() > 0 && p[p.length() - 1] == ' ' {
      encode_chars(p[:p.length() - 1], C0) + "%20"
    } else {
      encode_chars(p, C0)
    }
    return Some({
      scheme,
      username: "",
      password: "",
      host: None,
      port: None,
      path,
      query,
      fragment,
    })
  }
  // An authority: special URLs skip any slashes (and backslashes) before it.
  let mut k = 0
  if special {
    while k < before_hash.length() &&
          (before_hash[k] == '/' || before_hash[k] == '\\') {
      k += 1
    }
  } else {
    k = 2
  }
  let after = before_hash[k:]
  let mut end = after.length()
  for j in 0..<after.length() {
    let c = after[j]
    if c == '/' || c == '?' || (special && c == '\\') {
      end = j
      break
    }
  }
  let authority = after[:end]
  let tail = after[end:]
  // Credentials: before the last `@`.
  let mut at = -1
  for j in 0..<authority.length() {
    if authority[j] == '@' {
      at = j
    }
  }
  let mut username = ""
  let mut password = ""
  let hostport = if at >= 0 {
    let cred = authority[:at]
    let mut colon = -1
    for j in 0..<cred.length() {
      if cred[j] == ':' {
        colon = j
        break
      }
    }
    if colon >= 0 {
      username = encode_chars(cred[:colon], Userinfo)
      password = encode_chars(cred[colon + 1:], Userinfo)
    } else {
      username = encode_chars(cred, Userinfo)
    }
    authority[at + 1:]
  } else {
    authority
  }
  // The port: after the last `:` outside brackets.
  let mut colon = -1
  let mut inside = false
  for j in 0..<hostport.length() {
    let c = hostport[j]
    if c == '[' {
      inside = true
    } else if c == ']' {
      inside = false
    } else if c == ':' && !inside {
      colon = j
      break
    }
  }
  let host_chars = if colon >= 0 { hostport[:colon] } else { hostport }
  let port_chars = if colon >= 0 { hostport[colon + 1:] } else { hostport[0:0] }
  if host_chars.length() == 0 {
    if special || at >= 0 || colon >= 0 {
      return None
    }
  }
  let host = if special {
    match host_parse(host_chars) {
      Some(h) => h
      None => return None
    }
  } else if host_chars.length() == 0 {
    ""
  } else {
    match opaque_host(host_chars) {
      Some(h) => h
      None => return None
    }
  }
  let mut port : Int? = None
  if port_chars.length() > 0 {
    let mut v = 0
    for c in port_chars {
      if !is_digit(c) {
        return None
      }
      v = v * 10 + (c.to_int() - '0'.to_int())
      if v > 65535 {
        return None
      }
    }
    if special_port(scheme) != Some(v) {
      port = Some(v)
    }
  }
  // The path and the query.
  let mut q = -1
  for j in 0..<tail.length() {
    if tail[j] == '?' {
      q = j
      break
    }
  }
  let p = if q >= 0 { tail[:q] } else { tail }
  let query = if q >= 0 {
    Some(encode_chars(tail[q + 1:], if special { SpecialQuery } else { Query }))
  } else {
    None
  }
  let path = if p.length() == 0 {
    if special {
      "/"
    } else {
      ""
    }
  } else {
    "/" + path_segments(p[1:], special, false).join("/")
  }
  Some({ scheme, username, password, host: Some(host), port, path, query, fragment })
}

///|
fn parse_file(rest : ArrayView[Char], fragment : String?) -> Url? {
  let mut q = -1
  for j in 0..<rest.length() {
    if rest[j] == '?' {
      q = j
      break
    }
  }
  let body = if q >= 0 { rest[:q] } else { rest }
  let query = if q >= 0 {
    Some(encode_chars(rest[q + 1:], SpecialQuery))
  } else {
    None
  }
  let slash = (c : Char) => c == '/' || c == '\\'
  let mut host = ""
  let mut path_from = body
  if body.length() >= 2 && slash(body[0]) && slash(body[1]) {
    let after = body[2:]
    let mut end = after.length()
    for j in 0..<after.length() {
      if slash(after[j]) {
        end = j
        break
      }
    }
    let h = after[:end]
    if windows_letter(String::from_array(h.to_owned()), false) {
      path_from = after
    } else {
      if h.length() > 0 {
        host = match host_parse(h) {
          Some("localhost") => ""
          Some(x) => x
          None => return None
        }
      }
      path_from = after[end:]
    }
  }
  let segs = if path_from.length() > 0 && slash(path_from[0]) {
    path_segments(path_from[1:], true, true)
  } else {
    path_segments(path_from, true, true)
  }
  Some({
    scheme: "file",
    username: "",
    password: "",
    host: Some(host),
    port: None,
    path: "/" + segs.join("/"),
    query,
    fragment,
  })
}

///|
/// The URL serialised (`URL.href`).
pub fn Url::href(self : Url) -> String {
  let sb = StringBuilder()
  sb.write_string(self.scheme)
  sb.write_char(':')
  match self.host {
    Some(h) => {
      sb.write_string("//")
      if self.username != "" || self.password != "" {
        sb.write_string(self.username)
        if self.password != "" {
          sb.write_char(':')
          sb.write_string(self.password)
        }
        sb.write_char('@')
      }
      sb.write_string(h)
      if self.port is Some(p) {
        sb.write_char(':')
        sb.write_string(p.to_string())
      }
    }
    None =>
      // (a path of none with a host of none that starts `//`: `/.` before it)
      if self.path.has_prefix("//") {
        sb.write_string("/.")
      }
  }
  sb.write_string(self.path)
  if self.query is Some(q) {
    sb.write_char('?')
    sb.write_string(q)
  }
  if self.fragment is Some(f) {
    sb.write_char('#')
    sb.write_string(f)
  }
  sb.to_string()
}

///|
/// `URL.origin`: `scheme://host[:port]` for http, https, ws, wss, ftp; inner origin for `blob:` of http/https; "null" otherwise.
pub fn Url::origin(self : Url) -> String {
  if self.scheme == "blob" {
    match parse_url(self.path) {
      Some(inner) if inner.scheme == "http" || inner.scheme == "https" => return inner.origin()
      _ => return "null"
    }
  }
  match (special_port(self.scheme), self.host) {
    (Some(_), Some(h)) =>
      match self.port {
        Some(p) => "\{self.scheme}://\{h}:\{p}"
        None => "\{self.scheme}://\{h}"
      }
    _ => "null"
  }
}

///|
/// `URL.hostname`.
pub fn Url::hostname(self : Url) -> String {
  self.host.unwrap_or("")
}

///|
/// `URL.search`: "" where the query is none or empty, else `?` and it.
pub fn Url::search(self : Url) -> String {
  match self.query {
    Some(q) if q != "" => "?" + q
    _ => ""
  }
}

///|
/// `URL.hash`: "" where the fragment is none or empty, else `#` and it.
pub fn Url::hash(self : Url) -> String {
  match self.fragment {
    Some(f) if f != "" => "#" + f
    _ => ""
  }
}

///|
/// `URL.canParse(raw)`.
pub fn can_parse(raw : String) -> Bool {
  parse_url(raw) is Some(_)
}
