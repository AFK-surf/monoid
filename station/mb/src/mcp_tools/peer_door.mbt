///|
/// A /peer/<station>/<port>/<path> request's parts.
pub(all) struct PeerTarget {
  station : String
  given : String
  port : Int
  path : String
}

///|
/// The parts of a /peer/<station>/<port>/<path> URL; None when it is not one.
pub fn peer_target(url : String) -> PeerTarget? {
  if !url.has_prefix("/peer/") {
    return None
  }
  let rest = slice(url, 6)
  let at = index_of(rest, "/")
  if at <= 0 {
    return None
  }
  let given = slice(rest, 0, to=at)
  guard @api_routes.decode_uri_component(given) is Some(station) else {
    return None
  }
  let after = slice(rest, at + 1)
  let mut n = 0
  while n < after.length() &&
        n < 6 &&
        after.unsafe_charcode_at(n) >= '0' &&
        after.unsafe_charcode_at(n) <= '9' {
    n += 1
  }
  // /^[0-9]{1,5}(?=$|[/?])/
  if n == 0 || n > 5 {
    return None
  }
  if n < after.length() {
    let c = after.unsafe_charcode_at(n)
    if c != '/' && c != '?' {
      return None
    }
  }
  let mut port = 0
  for k in 0..<n {
    port = port * 10 + (after.unsafe_charcode_at(k) - '0')
  }
  if port < 1 || port > 65535 {
    return None
  }
  let tail = slice(after, n)
  let path = if tail == "" {
    "/"
  } else if tail.has_prefix("?") {
    "/" + tail
  } else {
    tail
  }
  Some({ station, given, port, path })
}

///|
fn header(headers : Array[(String, String)], name : String) -> String? {
  for h in headers {
    if h.0 == name {
      return Some(h.1)
    }
  }
  None
}

///|
/// Why a /peer request is not taken (None: it is): only programs on this machine, by a loopback name and the door's
/// port, and not a web page.
pub fn not_from_here(
  headers : Array[(String, String)],
  ports : Array[Int],
) -> String? {
  let host = header(headers, "host").unwrap_or("")
  let lowered = lower(host)
  let port = {
    let names = ["127.0.0.1:", "localhost:", "[::1]:"]
    let mut found : Int? = None
    for name in names {
      if lowered.has_prefix(name) {
        let digits = slice(host, name.length())
        let ok = digits.length() >= 1 &&
          digits.length() <= 5 &&
          digits.iter().all(c => c >= '0' && c <= '9')
        if ok {
          found = Some(@api_routes.js_number(digits).to_int())
        }
      }
    }
    found
  }
  let first = match ports.get(0) {
    Some(p) => p.to_string()
    None => "undefined"
  }
  match port {
    Some(p) if ports.contains(p) => ()
    _ =>
      return Some(
        "only programs on this machine reach other stations here, by http://127.0.0.1:\{first}/peer/…",
      )
  }
  let origin = header(headers, "origin")
  let site = header(headers, "sec-fetch-site")
  match origin {
    Some(o) if o != "null" || (site is Some(s) && s != "none") =>
      Some("web pages do not reach other stations through this one")
    _ => None
  }
}
