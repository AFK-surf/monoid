// URLs as Node's `new URL(ref, base)` resolves them, over the WHATWG parser the cloud's network has
// (station/mb src/cloud_net `parse_url`): a reference made absolute against its base, then parsed whole.

///|
fn is_alpha_unit(c : Int) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn special_scheme(s : String) -> Bool {
  s == "http" || s == "https" || s == "ws" || s == "wss" || s == "ftp" || s == "file"
}

///|
/// What comes before a URL's path in its href: its scheme and authority.
fn url_prefix(u : @cloud_net.Url) -> String {
  let href = u.href()
  let tail = u.path.length() +
    (match u.query {
      Some(q) => q.length() + 1
      None => 0
    }) +
    (match u.fragment {
      Some(f) => f.length() + 1
      None => 0
    })
  slice(href, 0, href.length() - tail)
}

///|
/// `new URL(ref, base)`: None where it throws. A base that is not special is taken only for an absolute reference.
pub fn resolve_url(reference : String, base : @cloud_net.Url) -> @cloud_net.Url? {
  // (what the parser takes away first: C0 controls and spaces at either end, tabs and newlines anywhere)
  let units = []
  let raw = reference
  let mut a = 0
  let mut b = raw.length()
  while a < b && raw.unsafe_charcode_at(a) <= 0x20 {
    a += 1
  }
  while b > a && raw.unsafe_charcode_at(b - 1) <= 0x20 {
    b -= 1
  }
  for i in a..<b {
    let c = raw.unsafe_charcode_at(i)
    if c != '\t' && c != '\n' && c != '\r' {
      units.push(c)
    }
  }
  let r = String::from_array(units.map(c => Int::unsafe_to_char(c)))
  // A scheme of its own.
  let mut i = 0
  if r.length() > 0 && is_alpha_unit(r.unsafe_charcode_at(0)) {
    i = 1
    while i < r.length() {
      let c = r.unsafe_charcode_at(i)
      if is_alpha_unit(c) || is_digit(c) || c == '+' || c == '-' || c == '.' {
        i += 1
      } else {
        break
      }
    }
    if i < r.length() && r.unsafe_charcode_at(i) == ':' {
      let scheme = lower_ascii(slice(r, 0, i))
      let rest = from(r, i + 1)
      let slashed = rest.length() > 0 &&
        (rest.unsafe_charcode_at(0) == '/' || rest.unsafe_charcode_at(0) == '\\')
      if scheme == base.scheme && special_scheme(scheme) && !slashed {
        // "http:foo" against an http base: relative.
        return resolve_url(rest, base)
      }
      return @cloud_net.parse_url(r)
    }
  }
  if !special_scheme(base.scheme) || base.host is None {
    return None
  }
  let slash = (k : Int) => k < r.length() &&
    (r.unsafe_charcode_at(k) == '/' || r.unsafe_charcode_at(k) == '\\')
  let absolute = if slash(0) && slash(1) {
    base.scheme + ":" + r
  } else if slash(0) {
    url_prefix(base) + r
  } else if r.length() > 0 && r.unsafe_charcode_at(0) == '?' {
    url_prefix(base) + base.path + r
  } else if r.length() > 0 && r.unsafe_charcode_at(0) == '#' {
    url_prefix(base) +
    base.path +
    (match base.query {
      Some(q) => "?" + q
      None => ""
    }) +
    r
  } else if r.length() == 0 {
    url_prefix(base) +
    base.path +
    (match base.query {
      Some(q) => "?" + q
      None => ""
    })
  } else {
    let dir = match base.path.rev_find("/") {
      Some(k) => slice(base.path, 0, k + 1)
      None => "/"
    }
    url_prefix(base) + dir + r
  }
  @cloud_net.parse_url(absolute)
}

///|
/// `encodeURIComponent`.
pub fn encode_uri_component(s : String) -> String {
  @url.encode_uri_component(s)
}
