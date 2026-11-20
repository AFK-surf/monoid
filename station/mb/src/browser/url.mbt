// Web addresses a person opens in the station's browser (src/browser/url.ts): bare hosts (`mail.proton.me`,
// `localhost:3000`) or full `http(s)://` links (including the first link inside pasted prose or an email), checked so
// non-web schemes and bare email addresses (`alice@proton.me`) are refused. Parsed as Node's `new URL` parses them
// (cloud_net's WHATWG parser).

///|
let max_url_length : Int = 8192

///|
/// The blank page a new tab opens on (what a browser's ＋ opens), its address bar waiting.
pub let blank_page : String = "about:blank"

///|
/// `new URL(raw)`: None where it throws.
pub fn url_of(raw : String) -> @cloud_net.Url? {
  @cloud_net.parse_url(raw)
}

///|
/// `URL.host`: its hostname and its port where it says one.
pub fn url_host(u : @cloud_net.Url) -> String {
  match u.port {
    Some(p) => u.hostname() + ":" + p.to_string()
    None => u.hostname()
  }
}

///|
fn valid_http_url(raw : String) -> @cloud_net.Url? {
  match url_of(raw) {
    Some(u) =>
      if (u.scheme != "http" && u.scheme != "https") || u.hostname() == "" {
        None
      } else if u.username != "" || u.password != "" {
        None
      } else {
        Some(u)
      }
    None => None
  }
}

///|
/// `/^\d{1,3}(?:\.\d{1,3}){3}$/`.
fn dotted_quad(h : String) -> Bool {
  let parts = h.split(".").map(v => v.to_string()).collect()
  if parts.length() != 4 {
    return false
  }
  parts.iter().all(p => p.length() >= 1 && p.length() <= 3 && all_digits(p))
}

///|
fn plausible_bare_host(hostname : String) -> Bool {
  let h = lower(hostname)
  if h == "localhost" || h.has_suffix(".localhost") || h.has_prefix("[") {
    return true
  }
  if dotted_quad(h) {
    return true
  }
  if h.has_prefix(".") || h.has_suffix(".") || h.contains("..") {
    return false
  }
  let dot = last_index_of(h, ".")
  dot > 0 && h.length() - dot - 1 >= 2
}

///|
/// What ends a link in prose (`[^\s<>"'`)\]}]`).
fn link_stop(c : Int) -> Bool {
  @jscase.is_space(c) ||
  c == '<'.to_int() ||
  c == '>'.to_int() ||
  c == '"'.to_int() ||
  c == '\''.to_int() ||
  c == '`'.to_int() ||
  c == ')'.to_int() ||
  c == ']'.to_int() ||
  c == '}'.to_int()
}

///|
fn unit_lower(c : Int) -> Int {
  if c >= 'A'.to_int() && c <= 'Z'.to_int() {
    c + 32
  } else {
    c
  }
}

///|
/// Where `/https?:\/\//i` matches at `i` in `s`: the end of its `://`, else -1.
fn scheme_at(s : String, i : Int) -> Int {
  let n = s.length()
  let word = "http"
  if i + 4 > n {
    return -1
  }
  for j in 0..<4 {
    if unit_lower(s.unsafe_charcode_at(i + j)) != word.unsafe_charcode_at(j) {
      return -1
    }
  }
  let mut k = i + 4
  let tail = fn(at : Int) -> Bool {
    at + 3 <= n &&
    s.unsafe_charcode_at(at) == ':'.to_int() &&
    s.unsafe_charcode_at(at + 1) == '/'.to_int() &&
    s.unsafe_charcode_at(at + 2) == '/'.to_int()
  }
  if k < n && unit_lower(s.unsafe_charcode_at(k)) == 's'.to_int() && tail(k + 1) {
    k = k + 4
  } else if tail(k) {
    k = k + 3
  } else {
    return -1
  }
  k
}

///|
/// `s.replace(/[.,;:!?]+$/, "")`.
fn strip_trailing_punct(s : String) -> String {
  let mut end = s.length()
  while end > 0 {
    let c = s.unsafe_charcode_at(end - 1)
    if c == '.'.to_int() ||
      c == ','.to_int() ||
      c == ';'.to_int() ||
      c == ':'.to_int() ||
      c == '!'.to_int() ||
      c == '?'.to_int() {
      end -= 1
    } else {
      break
    }
  }
  slice(s, 0, b=end)
}

///|
/// The first valid `http(s)://` URL inside `raw` (a copied link or a block of email text), or None.
pub fn extract_first_http_url(raw : String) -> String? {
  if raw.length() == 0 {
    return None
  }
  let text = slice(raw, 0, b=max_url_length * 2)
  let n = text.length()
  let mut i = 0
  while i < n {
    let k = scheme_at(text, i)
    if k < 0 {
      i += 1
      continue
    }
    let mut e = k
    while e < n && !link_stop(text.unsafe_charcode_at(e)) {
      e += 1
    }
    if e == k {
      // (`https?://` with nothing after it: no match here)
      i += 1
      continue
    }
    let candidate = strip_trailing_punct(slice(text, i, b=e))
    i = e
    if candidate.length() > max_url_length {
      continue
    }
    match valid_http_url(candidate) {
      Some(u) => return Some(u.href())
      None => ()
    }
  }
  None
}

///|
/// `/[\s\p{Cc}]/u`.
fn has_space_or_control(s : String) -> Bool {
  for i in 0..<s.length() {
    let c = s.unsafe_charcode_at(i)
    if @jscase.is_space(c) || c <= 0x1f || (c >= 0x7f && c <= 0x9f) {
      return true
    }
  }
  false
}

///|
fn has_space(s : String) -> Bool {
  for i in 0..<s.length() {
    if @jscase.is_space(s.unsafe_charcode_at(i)) {
      return true
    }
  }
  false
}

///|
/// A web address normalized to `http(s)://…`: accepts a full URL, text containing an `http(s)://` link, or a bare host
/// (`mail.proton.me`, `localhost:3000/app`); None for empty strings, non-HTTP schemes or email addresses.
pub fn normalize_browser_url(raw : String) -> String? {
  let trimmed = trim(raw)
  if trimmed == "" || trimmed.length() > max_url_length {
    return None
  }
  if scheme_at(trimmed, 0) >= 0 && !has_space(trimmed) {
    return valid_http_url(trimmed).map(u => u.href())
  }
  match extract_first_http_url(trimmed) {
    Some(e) => return Some(e)
    None => ()
  }
  if has_space_or_control(trimmed) {
    return None
  }
  // Reject non-HTTP schemes (`javascript:`, `mailto:`, `file:`, `about:`, `chrome://`); allow `host:port` where `:` is
  // followed by digits.
  if trimmed.contains("://") {
    return None
  }
  let mut slash = -1
  for i in 0..<trimmed.length() {
    let c = trimmed.unsafe_charcode_at(i)
    if c == '/'.to_int() || c == '?'.to_int() || c == '#'.to_int() {
      slash = i
      break
    }
  }
  let authority = if slash < 0 { trimmed } else { slice(trimmed, 0, b=slash) }
  if authority == "" || authority.contains("@") {
    return None
  }
  if !authority.has_prefix("[") {
    let colon = index_of(authority, ":")
    if colon >= 0 && !all_digits(slice(authority, colon + 1)) {
      return None
    }
  }
  let host_only = if authority.has_prefix("[") {
    slice(authority, 0, b=index_of(authority, "]") + 1)
  } else {
    let colon = index_of(authority, ":")
    if colon < 0 {
      authority
    } else {
      slice(authority, 0, b=colon)
    }
  }
  let lh = lower(host_only)
  let local = lh == "localhost" ||
    lh.has_suffix(".localhost") ||
    host_only == "127.0.0.1" ||
    host_only == "[::1]"
  let scheme = if local { "http" } else { "https" }
  match valid_http_url("\{scheme}://\{trimmed}") {
    Some(u) => if plausible_bare_host(u.hostname()) { Some(u.href()) } else { None }
    None => None
  }
}

///|
/// `encodeURIComponent(s)` (a lone surrogate, where JavaScript throws, written as U+FFFD's bytes).
pub fn encode_uri_component(s : String) -> String {
  @url.encode_uri_component(s)
}

///|
/// Where an address bar's words go, as a browser's own bar takes them: a web address as `normalize_browser_url` reads
/// one, else the words searched for (Google's search, Chrome's default); None for none.
pub fn address_or_search(raw : String) -> String? {
  let trimmed = trim(raw)
  if trimmed == "" || trimmed.length() > max_url_length {
    return None
  }
  match normalize_browser_url(trimmed) {
    Some(u) => Some(u)
    None => Some("https://www.google.com/search?q=" + encode_uri_component(trimmed))
  }
}

///|
/// The site (`hostname[:port]`) of a browser tab's URL, without path, query or hash; None for `about:blank`.
pub fn site_of_browser_url(raw : String) -> String? {
  valid_http_url(raw).map(u => lower(url_host(u)))
}

///|
/// A URL worth persisting for a sleeping user tab (`http:` or `https:`, never `about:blank` or `chrome-error://`).
pub fn persistable_browser_url(raw : String) -> String? {
  valid_http_url(raw).map(u => u.href())
}
