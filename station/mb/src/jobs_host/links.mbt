// What a web link in a message is, for its preview card (station/src/links/preview.ts, GET /link-preview): a GitHub
// pull request or issue as GitHub says it (through `gh` where it is signed in, else GitHub's public API), a video as
// its site's oEmbed says it (YouTube, Vimeo), any other page by its title, description, icon and picture (og:image).
// Only public addresses are fetched (a link in a chat is no way into the station's own network: each name resolved and
// checked, the connection pinned to what was checked, each redirect checked again), a little of each, and what was
// found is kept a while.

///|
let link_timeout_ms : Int = 6000

///|
let page_bytes : Int = 2 * 1024 * 1024

///|
let icon_bytes : Int = 48 * 1024

///|
let picture_bytes : Int = 4 * 1024 * 1024

///|
let picture_inline : Int = 192 * 1024

///|
let link_keep_ms : Double = 300_000.0

///|
let link_kept : Int = 300

///|
let user_agent : String = "stillfail-station (link preview)"

// ── text out of HTML ──

///|
fn is_word_unit(c : Int) -> Bool {
  is_alpha_unit(c) || is_digit(c) || c == '_'
}

///|
fn lower_unit(c : Int) -> Int {
  if c >= 'A' && c <= 'Z' {
    c + 32
  } else {
    c
  }
}

///|
/// Whether `s` has `word` (lowercase ASCII) at `i`, case aside.
fn at_ci(s : String, i : Int, word : String) -> Bool {
  if i < 0 || i + word.length() > s.length() {
    return false
  }
  for k in 0..<word.length() {
    if lower_unit(s.unsafe_charcode_at(i + k)) != word.unsafe_charcode_at(k) {
      return false
    }
  }
  true
}

///|
/// `s.search(/word/i)`.
fn index_ci(s : String, word : String, at? : Int = 0) -> Int {
  let mut i = at
  while i + word.length() <= s.length() {
    if at_ci(s, i, word) {
      return i
    }
    i += 1
  }
  -1
}

///|
fn entity(name : String) -> String? {
  match name {
    "amp" => Some("&")
    "lt" => Some("<")
    "gt" => Some(">")
    "quot" => Some("\"")
    "apos" => Some("'")
    "nbsp" => Some("\u{a0}")
    _ => None
  }
}

///|
fn write_point(out : StringBuilder, code : Int) -> Unit {
  if code < 0x10000 {
    out.write_char(Int::unsafe_to_char(code))
  } else {
    let v = code - 0x10000
    out.write_char(Int::unsafe_to_char(0xd800 + (v >> 10)))
    out.write_char(Int::unsafe_to_char(0xdc00 + (v & 0x3ff)))
  }
}

///|
/// Text out of HTML: its entities read, its spaces made one (preview.ts `htmlText`).
pub fn html_text(s : String) -> String {
  let out = StringBuilder::new()
  let n = s.length()
  let mut i = 0
  while i < n {
    let c = s.unsafe_charcode_at(i)
    if c != '&' {
      out.write_char(Int::unsafe_to_char(c))
      i += 1
      continue
    }
    // &(#x[0-9a-f]+|#[0-9]+|[a-z]+);  (case aside)
    let mut j = i + 1
    let mut kind = 0 // 1: hex, 2: decimal, 3: a name
    if j < n && s.unsafe_charcode_at(j) == '#' {
      if j + 1 < n && lower_unit(s.unsafe_charcode_at(j + 1)) == 'x' {
        let start = j + 2
        let mut k = start
        while k < n && @codec.hex_digit(s.unsafe_charcode_at(k)) is Some(_) {
          k += 1
        }
        if k > start && k < n && s.unsafe_charcode_at(k) == ';' {
          kind = 1
          j = k
        }
      }
      if kind == 0 {
        let start = j + 1
        let mut k = start
        while k < n && is_digit(s.unsafe_charcode_at(k)) {
          k += 1
        }
        if k > start && k < n && s.unsafe_charcode_at(k) == ';' {
          kind = 2
          j = k
        }
      }
    } else {
      let start = j
      let mut k = start
      while k < n && is_alpha_unit(s.unsafe_charcode_at(k)) {
        k += 1
      }
      if k > start && k < n && s.unsafe_charcode_at(k) == ';' {
        kind = 3
        j = k
      }
    }
    if kind == 0 {
      out.write_char('&')
      i += 1
      continue
    }
    let whole = slice(s, i, j + 1)
    let e = slice(s, i + 1, j)
    match kind {
      1 | 2 => {
        let mut code = 0.0
        let digits = if kind == 1 { from(e, 2) } else { from(e, 1) }
        for k in 0..<digits.length() {
          let d = @codec.hex_digit(digits.unsafe_charcode_at(k)).unwrap_or(0)
          code = code * (if kind == 1 { 16.0 } else { 10.0 }) + d.to_double()
        }
        if code > 0.0 && code < 1114112.0 {
          write_point(out, code.to_int())
        } else {
          out.write_string(whole)
        }
      }
      _ =>
        match entity(lower_ascii(e)) {
          Some(t) => out.write_string(t)
          None => out.write_string(whole)
        }
    }
    i = j + 1
  }
  // /\s+/g → " ", then trimmed
  let spaced = StringBuilder::new()
  let t = out.to_string()
  let mut k = 0
  while k < t.length() {
    let c = t.unsafe_charcode_at(k)
    if @jscase.is_space(c) {
      spaced.write_char(' ')
      while k < t.length() && @jscase.is_space(t.unsafe_charcode_at(k)) {
        k += 1
      }
    } else {
      spaced.write_char(Int::unsafe_to_char(c))
      k += 1
    }
  }
  trim(spaced.to_string())
}

///|
/// `s` cut to `n` code points, an ellipsis after where it was longer.
fn cut(s : String, n : Int) -> String {
  let points = s.to_array()
  if points.length() > n {
    String::from_array(points[0:n].to_array()) + "…"
  } else {
    s
  }
}

///|
/// Every `<tag\b[^>]*>` of `html`, case aside.
fn tags_of(html : String, tag : String) -> Array[String] {
  let out = []
  let open = "<" + tag
  let mut i = 0
  while true {
    let at = index_ci(html, open, at=i)
    if at < 0 {
      break
    }
    let after = at + open.length()
    if after < html.length() && is_word_unit(html.unsafe_charcode_at(after)) {
      i = at + 1
      continue
    }
    let end = index_of(html, ">", at=after)
    if end < 0 {
      break
    }
    out.push(slice(html, at, end + 1))
    i = end + 1
  }
  out
}

///|
/// `\bname\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))` of a tag, case aside: its value.
fn attr(tag : String, name : String) -> String? {
  let n = tag.length()
  let mut i = 0
  while i + name.length() <= n {
    if at_ci(tag, i, name) && (i == 0 || !is_word_unit(tag.unsafe_charcode_at(i - 1))) {
      let mut j = i + name.length()
      while j < n && @jscase.is_space(tag.unsafe_charcode_at(j)) {
        j += 1
      }
      if j < n && tag.unsafe_charcode_at(j) == '=' {
        j += 1
        while j < n && @jscase.is_space(tag.unsafe_charcode_at(j)) {
          j += 1
        }
        if j < n {
          let q = tag.unsafe_charcode_at(j)
          if q == '"' || q == '\'' {
            let close = index_of(tag, String::from_array([Int::unsafe_to_char(q)]), at=j + 1)
            if close >= 0 {
              return Some(slice(tag, j + 1, close))
            }
          }
          let start = j
          while j < n &&
                !@jscase.is_space(tag.unsafe_charcode_at(j)) &&
                tag.unsafe_charcode_at(j) != '>' {
            j += 1
          }
          if j > start {
            return Some(slice(tag, start, j))
          }
        }
      }
    }
    i += 1
  }
  None
}

///|
/// What a page's head says of it (preview.ts `headOf`): its title (og:title, else <title>), description, site, and
/// its icon's and picture's addresses.
pub fn head_of(html : String, base : @cloud_net.Url) -> Json {
  let end = index_ci(html, "</head>")
  let head = if end < 0 { html } else { slice(html, 0, end) }
  let metas = tags_of(head, "meta")
  let meta = (names : Array[String]) => {
    let mut found : String? = None
    for name in names {
      let tag = metas.search_by(t => match attr(t, "property") {
        Some(p) => @jscase.lower(p) == name
        None =>
          match attr(t, "name") {
            Some(p) => @jscase.lower(p) == name
            None => false
          }
      })
      match tag {
        Some(k) =>
          match attr(metas[k], "content") {
            Some(c) if c != "" => {
              found = Some(html_text(c))
              break
            }
            _ => ()
          }
        None => ()
      }
    }
    found
  }
  // /<title\b[^>]*>([^<]*)<\/title>/i
  let mut title_tag : String? = None
  let mut i = 0
  while title_tag is None {
    let at = index_ci(head, "<title", at=i)
    if at < 0 {
      break
    }
    i = at + 1
    let after = at + 6
    if after < head.length() && is_word_unit(head.unsafe_charcode_at(after)) {
      continue
    }
    let gt = index_of(head, ">", at=after)
    if gt < 0 {
      break
    }
    let lt = index_of(head, "<", at=gt + 1)
    if lt >= 0 && at_ci(head, lt, "</title>") {
      title_tag = Some(slice(head, gt + 1, lt))
    }
  }
  let title = match meta(["og:title", "twitter:title"]) {
    Some(t) => Some(t)
    None =>
      match title_tag {
        Some(t) if t != "" => Some(html_text(t))
        _ => None
      }
  }
  let description = meta(["og:description", "description", "twitter:description"])
  let site = meta(["og:site_name"])
  let links = tags_of(head, "link")
  let rel_of = (t : String) => attr(t, "rel").unwrap_or("")
  let icon_tag = match
    links.search_by(t => {
      let r = lower_ascii(rel_of(t))
      r == "icon" || r == "shortcut icon"
    }) {
    Some(k) => Some(links[k])
    None =>
      match links.search_by(t => index_ci(rel_of(t), "apple-touch-icon") >= 0) {
        Some(k) => Some(links[k])
        None => None
      }
  }
  let icon_at = match icon_tag {
    Some(t) => attr(t, "href").unwrap_or("/favicon.ico")
    None => "/favicon.ico"
  }
  let icon = resolve_url(icon_at, base).map(u => u.href())
  let image = match meta(["og:image:secure_url", "og:image", "og:image:url", "twitter:image", "twitter:image:src"]) {
    Some(at) =>
      match resolve_url(at, base) {
        Some(u) if u.scheme == "https" || u.scheme == "http" => Some(u.href())
        _ => None
      }
    None => None
  }
  let m : Map[String, Json] = Map([])
  match title {
    Some(t) if t != "" => m["title"] = jstr(cut(t, 200))
    _ => ()
  }
  match description {
    Some(t) if t != "" => m["description"] = jstr(cut(t, 300))
    _ => ()
  }
  match site {
    Some(t) if t != "" => m["site"] = jstr(cut(t, 60))
    _ => ()
  }
  match icon {
    Some(t) if t != "" => m["icon"] = jstr(t)
    _ => ()
  }
  match image {
    Some(t) if t != "" => m["image"] = jstr(t)
    _ => ()
  }
  Json::object(m)
}

// ── which addresses are fetched ──

///|
/// Node's `isIPv4`: four decimal parts, each 0-255 with no leading zero.
pub fn is_ipv4(s : String) -> Bool {
  let parts = split(s, ".")
  if parts.length() != 4 {
    return false
  }
  for p in parts {
    if !all_digits(p) || p.length() > 3 || (p.length() > 1 && p.unsafe_charcode_at(0) == '0') {
      return false
    }
    if digits_number(p) > 255.0 {
      return false
    }
  }
  true
}

///|
/// Node's `isIPv6`: up to eight groups of one to four hex digits, one `::`, an IPv4 address in the last two's place,
/// a zone after `%`.
pub fn is_ipv6(s : String) -> Bool {
  let addr = match s.find("%") {
    Some(i) => {
      let zone = from(s, i + 1)
      if zone.length() == 0 {
        return false
      }
      for k in 0..<zone.length() {
        let c = zone.unsafe_charcode_at(k)
        if !(is_alpha_unit(c) || is_digit(c) || c == '-' || c == '.' || c == ':' || c == '_') {
          return false
        }
      }
      slice(s, 0, i)
    }
    None => s
  }
  let halves = split(addr, "::")
  if halves.length() > 2 {
    return false
  }
  let groups = (part : String) => if part == "" { [] } else { split(part, ":") }
  let all = []
  for h in halves {
    all.push(groups(h))
  }
  let mut count = 0
  for gi, gs in all {
    for k, g in gs {
      let last = gi == all.length() - 1 && k == gs.length() - 1
      if last && g.find(".") is Some(_) {
        if !is_ipv4(g) {
          return false
        }
        count += 2
        continue
      }
      if g.length() < 1 || g.length() > 4 {
        return false
      }
      for c in 0..<g.length() {
        if @codec.hex_digit(g.unsafe_charcode_at(c)) is None {
          return false
        }
      }
      count += 1
    }
  }
  if halves.length() == 2 {
    count < 8
  } else {
    count == 8
  }
}

///|
/// Node's `isIP`: 4, 6, or 0.
pub fn ip_kind(s : String) -> Int {
  if is_ipv4(s) {
    4
  } else if is_ipv6(s) {
    6
  } else {
    0
  }
}

///|
/// Whether an address is one of the internet's, not a private, loopback or link-local one.
pub fn is_public(address : String) -> Bool {
  let kind = ip_kind(address)
  if kind == 0 {
    return false
  }
  // As URL canonicalizes dotted IPv4 inside IPv6 to hex, normalize DNS answers too. A zone changes the interface,
  // not whether the address is public.
  let v6 = if kind == 6 {
    let bare = split(address, "%")[0]
    guard @cloud_net.parse_url("http://[" + bare + "]/") is Some(url) else { return false }
    let host = url.hostname()
    slice(host, 1, host.length() - 1)
  } else {
    ""
  }
  let v4 = if kind == 4 {
    let parts = split(address, ".").map(digits_number)
    Some((parts[0].to_int(), parts[1].to_int()))
  } else if starts(v6, "::ffff:") && split(from(v6, 7), ":").length() == 2 {
    let high = split(from(v6, 7), ":")[0]
    let mut value = 0
    for i in 0..<high.length() {
      value = value * 16 + @codec.hex_digit(high.unsafe_charcode_at(i)).unwrap_or(0)
    }
    Some((value >> 8, value & 255))
  } else {
    None
  }
  match v4 {
    Some((a, b)) => {
      !(a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b < 128) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b < 32) ||
      (a == 192 && b == 168) ||
      a >= 224)
    }
    None => {
      !(v6 == "::" ||
      v6 == "::1" ||
      starts(v6, "fc") ||
      starts(v6, "fd") ||
      starts(v6, "fe8") ||
      starts(v6, "fe9") ||
      starts(v6, "fea") ||
      starts(v6, "feb") ||
      starts(v6, "ff"))
    }
  }
}

///|
/// The oEmbed endpoint that says what a video link is; None for any other link.
pub fn oembed_of(url : @cloud_net.Url) -> String? {
  let host = @jscase.lower(url.hostname())
  let path = url.path
  let youtube_host = host == "youtube.com" ||
    host == "www.youtube.com" ||
    host == "m.youtube.com" ||
    host == "music.youtube.com"
  let youtube = (youtube_host &&
    (path == "/watch" ||
    starts(path, "/shorts/") ||
    starts(path, "/live/") ||
    starts(path, "/embed/"))) ||
    (host == "youtu.be" && path.length() > 1)
  if youtube {
    return Some(
      "https://www.youtube.com/oembed?format=json&url=\{encode_uri_component(url.href())}",
    )
  }
  let vimeo_host = host == "vimeo.com" || host == "www.vimeo.com" || host == "player.vimeo.com"
  // /\/\d+(?:\/|$)/
  let mut numbered = false
  for i in 0..<path.length() {
    if path.unsafe_charcode_at(i) == '/' {
      let mut j = i + 1
      while j < path.length() && is_digit(path.unsafe_charcode_at(j)) {
        j += 1
      }
      if j > i + 1 && (j == path.length() || path.unsafe_charcode_at(j) == '/') {
        numbered = true
      }
    }
  }
  if vimeo_host && numbered {
    return Some("https://vimeo.com/api/oembed.json?url=\{encode_uri_component(url.href())}")
  }
  None
}

// ── fetching ──

///|
/// An answer being read (preview.ts's `Response`): its status, its headers by lowercase name, its body a chunk at a
/// time (None at its end), and the address it is of.
pub(all) struct Answer {
  status : Int
  headers : Array[(String, String)]
  next : async () -> Bytes?
  close : async () -> Unit
  url : String
}

///|
/// A header's values joined as `Headers.get` joins them; None where there is none.
pub fn Answer::header(self : Answer, name : String) -> String? {
  let values = self.headers.filter(h => lower_ascii(h.0) == name).map(h => h.1)
  if values.is_empty() {
    None
  } else {
    Some(join(values, ", "))
  }
}

///|
fn Answer::ok(self : Answer) -> Bool {
  self.status >= 200 && self.status <= 299
}

///|
/// What a preview asks of the world: a name's addresses, one GET pinned to an address, GitHub's API, a thumbnail.
pub(all) struct LinkIo {
  lookup : async (String) -> Array[String]
  get_at : async (@cloud_net.Url, Array[String], String) -> Answer?
  github_api : async (String) -> Json
  thumbnail : async (String, Bytes) -> (String, Bytes)?
}

///|
/// A name's addresses, as the system resolves them (getent on Linux, the directory service on a Mac); none where it
/// cannot say.
pub async fn lookup_on(host : @host.Host, name : String) -> Array[String] {
  let out = []
  match run_program(host, "getent", ["ahosts", name], timeout_ms=link_timeout_ms) {
    Some(text) => {
      for line in split(text, "\n") {
        let address = trim(split(trim(line), " ")[0])
        if address != "" && !out.contains(address) && ip_kind(address) != 0 {
          out.push(address)
        }
      }
      return out
    }
    None => ()
  }
  match
    run_program(host, "dscacheutil", ["-q", "host", "-a", "name", name], timeout_ms=link_timeout_ms) {
    Some(text) =>
      for line in split(text, "\n") {
        for prefix in ["ip_address:", "ipv6_address:"] {
          if starts(line, prefix) {
            let address = trim(from(line, prefix.length()))
            if address != "" && !out.contains(address) {
              out.push(address)
            }
          }
        }
      }
    None => ()
  }
  out
}

///|
/// One GET of `url` pinned to the first of `addresses` (what its name was checked to resolve to, not asked again), its
/// body as sent: one in any encoding is not read at all (None).
pub async fn get_at_on(
  host : @host.Host,
  url : @cloud_net.Url,
  addresses : Array[String],
  accept : String,
) -> Answer? {
  let port = match url.port {
    Some(p) => p
    None => if url.scheme == "https" { 443 } else { 80 }
  }
  let args : Map[String, Json] = {
    "url": jstr(url.href()),
    "method": jstr("GET"),
    "headers": Json::array([
      Json::array([jstr("user-agent"), jstr(user_agent)]),
      Json::array([jstr("accept"), jstr(accept)]),
      Json::array([jstr("accept-encoding"), jstr("identity")]),
    ]),
  }
  if addresses.length() > 0 {
    let a = addresses[0]
    args["entry"] = obj([("host", jstr(a)), ("port", jint(port))])
  }
  let opened = @effect.timeout(link_timeout_ms, async fn() {
    ask(host, "stream.open", Json::object(args))
  })
  guard opened is Some(answer) else { raise HostError("The operation was aborted due to timeout") }
  let status = num(field(answer, "status")).unwrap_or(0.0).to_int()
  let headers = match field(answer, "headers") {
    Some(Array(a)) =>
      a.filter_map(p => match p {
        [String(k), String(v)] => Some((lower_ascii(k), v))
        _ => None
      })
    _ => []
  }
  let id = field_or_null(answer, "id")
  let encoding = headers.search_by(h => h.0 == "content-encoding").map(k => lower_ascii(trim(headers[k].1)))
  match encoding {
    Some(e) if e != "" && e != "identity" => return None
    _ => ()
  }
  if status < 200 || status > 599 {
    return None
  }
  let empty = status == 204 || status == 205 || status == 304
  let ended = Ref(empty)
  Some({
    status,
    headers,
    url: url.href(),
    close: async fn() {
      ended.val = true
      ignore(try_ask(host, "stream.close", { "id": id }))
    },
    next: async fn() {
      if ended.val {
        return None
      }
      let (said, bytes) = host.shell("stream.read", { "id": id })
      match (field(said, "end"), bytes) {
        (Some(True), _) => {
          ended.val = true
          None
        }
        (_, Some(b)) => Some(b)
        _ => {
          ended.val = true
          None
        }
      }
    },
  })
}

///|
/// A GitHub API path's answer: through `gh` (signed in, private repositories too), else the public API.
pub async fn github_api_on(host : @host.Host, path : String) -> Json {
  match run_program(host, "gh", ["api", path], timeout_ms=link_timeout_ms, max_bytes=4 << 20) {
    Some(out) =>
      match (try { Some(@json.parse(out)) } catch { _ => None }) {
        Some(v) => return v
        None => ()
      }
    None => ()
  }
  let got = host.fetch(
    "https://api.github.com/\{path}",
    headers=[("user-agent", user_agent), ("accept", "application/vnd.github+json")],
    timeout_ms=link_timeout_ms,
    // (as preview.ts's `fetch`: a renamed repository's 301 followed)
    redirect="follow",
  ) catch {
    @host.FetchTimeout => raise HostError(@host.fetch_timed_out)
    e => raise e
  }
  if got.status < 200 || got.status > 299 {
    raise HostError("GitHub answered \{got.status}")
  }
  @json.parse(got.text())
}

///|
/// The machine's own: the system's names, the shell's HTTP, gh, and no thumbnails (those are the station's codecs').
pub fn LinkIo::shell(host : @host.Host) -> LinkIo {
  {
    lookup: async fn(name) { lookup_on(host, name) },
    get_at: async fn(url, addresses, accept) { get_at_on(host, url, addresses, accept) },
    github_api: async fn(path) { github_api_on(host, path) },
    thumbnail: async fn(_, _) { None },
  }
}

///|
/// A fetch of a public address only, each redirect checked again; None for any other.
pub async fn fetch_public(io : LinkIo, start : @cloud_net.Url, accept : String) -> Answer? {
  let mut url = start
  for hop in 0..<4 {
    ignore(hop)
    if url.scheme != "https" && url.scheme != "http" {
      return None
    }
    let h = url.hostname()
    let host = if starts(h, "[") && ends(h, "]") { slice(h, 1, h.length() - 1) } else { h }
    let addresses = if ip_kind(host) != 0 {
      [host]
    } else {
      (io.lookup)(host) catch {
        _ => []
      }
    }
    if addresses.is_empty() || !addresses.iter().all(is_public) {
      return None
    }
    guard (io.get_at)(url, addresses, accept) is Some(res) else { return None }
    let next = if res.status >= 300 && res.status < 400 { res.header("location") } else { None }
    match next {
      None => return Some(res)
      Some(n) => {
        (res.close)()
        match resolve_url(n, url) {
          Some(u) => url = u
          None => raise HostError("Invalid URL")
        }
      }
    }
  }
  None
}

///|
/// The start of a body, at most `max` bytes; with `until_head`, no more once what was read has `</head>`.
pub async fn body_up_to(res : Answer, max : Int, until_head? : Bool = false) -> Bytes {
  let parts = @buffer.new()
  let mut got = 0
  let mut tail = ""
  while got < max {
    guard (res.next)() is Some(chunk) else { break }
    parts.write_bytes(chunk)
    got += chunk.length()
    if until_head {
      let latin = StringBuilder::new()
      latin.write_string(tail)
      for b in chunk {
        latin.write_char(Int::unsafe_to_char(b.to_int()))
      }
      let seen = latin.to_string()
      if index_ci(seen, "</head>") >= 0 {
        break
      }
      tail = from(seen, seen.length() - 16)
    }
  }
  (res.close)()
  let all = parts.to_bytes()
  if all.length() > max {
    all[0:max].to_bytes()
  } else {
    all
  }
}

///|
/// An image's type and bytes; None when it is not an image, or is over `max`.
async fn fetch_image(io : LinkIo, href : String, max : Int) -> (String, Bytes)? {
  try {
    guard @cloud_net.parse_url(href) is Some(u) else { return None }
    guard fetch_public(io, u, "image/*") is Some(res) else { return None }
    let t = match res.header("content-type") {
      Some(c) => lower_ascii(trim(split(c, ";")[0]))
      None => ""
    }
    if !res.ok() || !starts(t, "image/") {
      (res.close)()
      return None
    }
    let bytes = body_up_to(res, max + 1)
    if bytes.length() > max || bytes.length() == 0 {
      None
    } else {
      Some((t, bytes))
    }
  } catch {
    _ => None
  }
}

///|
fn data_url(t : String, bytes : Bytes) -> String {
  "data:\{t};base64,\{@base64.encode(bytes)}"
}

///|
/// An icon or an avatar as a data: URL (it goes across inline), small ones only.
async fn icon_of(io : LinkIo, href : String) -> String? {
  fetch_image(io, href, icon_bytes).map(f => data_url(f.0, f.1))
}

///|
/// A page's picture as a data: URL: itself when it is small, else its thumbnail; None when it is neither.
async fn picture(io : LinkIo, href : String) -> String? {
  guard fetch_image(io, href, picture_bytes) is Some((t, bytes)) else { return None }
  let ext = match t {
    "image/jpeg" | "image/jpg" | "image/png" | "image/webp" => true
    _ => false
  }
  if ext && bytes.length() > picture_inline {
    let made = (io.thumbnail)(t, bytes) catch { _ => None }
    match made {
      Some((small_type, small)) =>
        return if small.length() > picture_inline {
          None
        } else {
          Some(data_url(small_type, small))
        }
      None => ()
    }
  }
  if bytes.length() > picture_inline {
    None
  } else {
    Some(data_url(t, bytes))
  }
}

// ── GitHub ──

///|
/// Whether a JSON value is truthy as JavaScript has it.
fn truthy(v : Json?) -> Bool {
  @jsjson.json_truthy(v)
}

///|
/// `Date.parse` of an ISO 8601 time (as GitHub writes them: `YYYY-MM-DDTHH:MM:SS(.sss)Z` or with an offset; a date
/// alone is UTC); None where it is not one.
pub fn iso_time(s : String) -> Double? {
  guard s.length() >= 10 &&
    s.unsafe_get(4).to_int() == '-' &&
    s.unsafe_get(7).to_int() == '-' &&
    (s.length() == 10 || s.unsafe_get(10).to_int() == 'T') else {
    return None
  }
  @jsjson.js_parse_iso(s)
}

///|
fn when_of(v : Json?) -> Json {
  match v {
    Some(String(s)) =>
      match iso_time(s) {
        Some(t) => jnum(t)
        None => Json::null()
      }
    _ => Json::null()
  }
}

///|
fn count_of(v : Json?) -> Json {
  match v {
    Some(Number(d, ..)) => jnum(d)
    _ => Json::null()
  }
}

///|
async fn person(io : LinkIo, user : Json?) -> Json {
  guard user is Some(u) && field(u, "login") is Some(String(login)) else { return Json::null() }
  let avatar = match field(u, "avatar_url") {
    Some(String(a)) => icon_of(io, a + (if a.find("?") is Some(_) { "&" } else { "?" }) + "s=48")
    _ => None
  }
  match avatar {
    Some(a) => obj([("login", jstr(login)), ("avatar", jstr(a))])
    None => obj([("login", jstr(login))])
  }
}

///|
/// A commit's check runs counted: passed, failed, still going; None when it has none.
pub fn checks_counted(runs : Json?) -> Json? {
  guard runs is Some(Array(rs)) && rs.length() > 0 else { return None }
  let mut passed = 0
  let mut failed = 0
  let mut pending = 0
  for r in rs {
    if !(field(r, "status") is Some(String("completed"))) {
      pending += 1
    } else {
      match field(r, "conclusion") {
        Some(String("success" | "neutral" | "skipped")) => passed += 1
        _ => failed += 1
      }
    }
  }
  Some(obj([("passed", jint(passed)), ("failed", jint(failed)), ("pending", jint(pending))]))
}

///|
/// A pull request as GitHub said it (preview.ts `github`), its author and checks found.
pub fn pull_preview(href : String, repository : String, number : Double, pr : Json, author : Json, checks : Json?) -> Json {
  let state = if truthy(field(pr, "merged_at")) {
    "merged"
  } else if field(pr, "state") is Some(String("closed")) {
    "closed"
  } else if truthy(field(pr, "draft")) {
    "draft"
  } else {
    "open"
  }
  let m : Map[String, Json] = {
    "kind": jstr("github_pull_request"),
    "url": jstr(href),
    "repository": jstr(repository),
    "number": jnum(number),
    "title": jstr(js_text_or_empty(field(pr, "title"))),
    "state": jstr(state),
    "author": author,
    "additions": count_of(field(pr, "additions")),
    "deletions": count_of(field(pr, "deletions")),
    "changedFiles": count_of(field(pr, "changed_files")),
    "updatedAt": when_of(field(pr, "updated_at")),
  }
  match checks {
    Some(c) => m["checks"] = c
    None => ()
  }
  Json::object(m)
}

///|
/// `String(v ?? "")`.
fn js_text_or_empty(v : Json?) -> String {
  match v {
    None | Some(Null) => ""
    Some(x) => js_text(x)
  }
}

///|
/// An issue as GitHub said it.
pub fn issue_preview(href : String, repository : String, number : Double, issue : Json, author : Json) -> Json {
  let state = if field(issue, "state") is Some(String("open")) {
    "open"
  } else {
    match field(issue, "state_reason") {
      Some(String("completed")) => "completed"
      Some(String("not_planned")) => "not_planned"
      _ => "closed"
    }
  }
  let labels = match field(issue, "labels") {
    Some(Array(ls)) =>
      ls.filter_map(l => match field(l, "name") {
        Some(String(n)) => Some(jstr(n))
        _ => None
      })
    _ => []
  }
  obj([
    ("kind", jstr("github_issue")),
    ("url", jstr(href)),
    ("repository", jstr(repository)),
    ("number", jnum(number)),
    ("title", jstr(js_text_or_empty(field(issue, "title")))),
    ("state", jstr(state)),
    ("author", author),
    ("comments", count_of(field(issue, "comments"))),
    ("labels", Json::array(if labels.length() > 3 { labels[0:3].to_array() } else { labels })),
    ("updatedAt", when_of(field(issue, "updated_at"))),
  ])
}

///|
async fn github(
  io : LinkIo,
  owner : String,
  repo : String,
  pull : Bool,
  number : Double,
  href : String,
) -> Json {
  let repository = "\{owner}/\{repo}"
  let n = js_number(number)
  if pull {
    let pr = (io.github_api)("repos/\{repository}/pulls/\{n}")
    let author = person(io, field(pr, "user"))
    let checks = match field(pr, "head") {
      Some(head) =>
        match field(head, "sha") {
          Some(String(sha)) =>
            try {
              checks_counted(
                field(
                  (io.github_api)("repos/\{repository}/commits/\{sha}/check-runs?per_page=100"),
                  "check_runs",
                ),
              )
            } catch {
              _ => None
            }
          _ => None
        }
      None => None
    }
    return pull_preview(href, repository, number, pr, author, checks)
  }
  let issue = (io.github_api)("repos/\{repository}/issues/\{n}")
  issue_preview(href, repository, number, issue, person(io, field(issue, "user")))
}

///|
/// `^\/([\w.-]+)\/([\w.-]+)\/(pull|issues)\/(\d+)(?:[/?#]|$)` of a path: owner, repository, whether a pull, number.
pub fn github_path(path : String) -> (String, String, Bool, Double)? {
  let parts = split(path, "/")
  if parts.length() < 5 || parts[0] != "" {
    return None
  }
  let named = (p : String) => p.length() > 0 &&
    p.iter().all(c => is_word_unit(c.to_int()) || c == '.' || c == '-')
  if !named(parts[1]) || !named(parts[2]) {
    return None
  }
  let pull = match parts[3] {
    "pull" => true
    "issues" => false
    _ => return None
  }
  if !all_digits(parts[4]) {
    return None
  }
  Some((parts[1], parts[2], pull, digits_number(parts[4])))
}

// ── a page, a video ──

///|
async fn oembed(io : LinkIo, endpoint : String, url : @cloud_net.Url) -> Json? {
  guard @cloud_net.parse_url(endpoint) is Some(e) else { raise HostError("Invalid URL") }
  guard fetch_public(io, e, "application/json") is Some(res) else { return None }
  if !res.ok() {
    (res.close)()
    return None
  }
  let said = @json.parse(@utf8.decode_lossy(body_up_to(res, 64 * 1024)))
  let title = match field(said, "title") {
    Some(String(t)) => html_text(t)
    _ => ""
  }
  if title == "" {
    return None
  }
  let site = match field(said, "provider_name") {
    Some(String(t)) => html_text(t)
    _ => ""
  }
  let icon_at = match field(said, "provider_url") {
    Some(String(p)) =>
      match @cloud_net.parse_url(p) {
        Some(base) =>
          match resolve_url("/favicon.ico", base) {
            Some(u) => Some(u.href())
            None => raise HostError("Invalid URL")
          }
        None => raise HostError("Invalid URL")
      }
    _ => None
  }
  let icon = match icon_at {
    Some(i) => icon_of(io, i)
    None => None
  }
  let image = match field(said, "thumbnail_url") {
    Some(String(t)) => picture(io, t)
    _ => None
  }
  let m : Map[String, Json] = {
    "kind": jstr("page"),
    "url": jstr(url.href()),
    "title": jstr(cut(title, 200)),
  }
  if site != "" {
    m["site"] = jstr(cut(site, 60))
  }
  match icon {
    Some(i) => m["icon"] = jstr(i)
    None => ()
  }
  match image {
    Some(i) => m["image"] = jstr(i)
    None => ()
  }
  Some(Json::object(m))
}

///|
async fn page(io : LinkIo, url : @cloud_net.Url) -> Json? {
  guard fetch_public(io, url, "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1") is Some(res) else {
    return None
  }
  if !res.ok() {
    (res.close)()
    return None
  }
  let t = res.header("content-type").unwrap_or("")
  if index_ci(t, "html") < 0 {
    (res.close)()
    return None
  }
  let html = @utf8.decode_lossy(body_up_to(res, page_bytes, until_head=true))
  let base = match @cloud_net.parse_url(if res.url != "" { res.url } else { url.href() }) {
    Some(b) => b
    None => url
  }
  let found = head_of(html, base)
  guard field(found, "title") is Some(String(title)) else { return None }
  let icon = match field(found, "icon") {
    Some(String(i)) => icon_of(io, i)
    _ => None
  }
  let image = match field(found, "image") {
    Some(String(i)) => picture(io, i)
    _ => None
  }
  let m : Map[String, Json] = { "kind": jstr("page"), "url": jstr(url.href()), "title": jstr(title) }
  for k in ["description", "site"] {
    match field(found, k) {
      Some(v) => m[k] = v
      None => ()
    }
  }
  match icon {
    Some(i) => m["icon"] = jstr(i)
    None => ()
  }
  match image {
    Some(i) => m["image"] = jstr(i)
    None => ()
  }
  Some(Json::object(m))
}

///|
async fn find_preview(io : LinkIo, href : String) -> Json? {
  guard @cloud_net.parse_url(href) is Some(url) else { return None }
  if url.scheme != "https" && url.scheme != "http" {
    return None
  }
  if url.hostname() == "github.com" && actions_target(url.path) is Some((repo, id, attempt)) {
    let found = try { Some(actions_preview(io, href, repo, id, attempt)) } catch { _ => None }
    if found is Some(value) { return Some(value) }
  }
  match github_path(url.path) {
    Some((owner, repo, pull, number)) if url.hostname() == "github.com" => {
      let found = try {
        Some(github(io, owner, repo, pull, number, href))
      } catch {
        _ => None
      }
      match found {
        Some(f) => return Some(f)
        None => ()
      }
    }
    _ => ()
  }
  match oembed_of(url) {
    Some(endpoint) => {
      let found = try {
        oembed(io, endpoint, url)
      } catch {
        _ => None
      }
      match found {
        Some(f) => return Some(f)
        None => ()
      }
    }
    None => ()
  }
  page(io, url)
}

///|
/// The previews found lately, by link (preview.ts `kept`): a card opened again shows at once.
pub struct LinkPreviews {
  priv io : LinkIo
  priv order : Array[String]
  priv kept : Map[String, (Double, @effect.Deferred[Json?])]
}

///|
pub fn LinkPreviews::new(io : LinkIo) -> LinkPreviews {
  { io, order: [], kept: Map([]) }
}

///|
/// The preview of `href`, None when there is none to give (not a page, not reachable, not allowed).
pub async fn LinkPreviews::preview(self : LinkPreviews, href : String, now : Double) -> Json? {
  match self.kept.get(href) {
    Some((at, value)) if now - at < link_keep_ms => return value.wait() catch { _ => None }
    _ => ()
  }
  let value : @effect.Deferred[Json?] = @effect.Deferred::new()
  self.kept.remove(href)
  match self.order.search(href) {
    Some(k) => ignore(self.order.remove(k))
    None => ()
  }
  self.kept[href] = (now, value)
  self.order.push(href)
  while self.order.length() > link_kept {
    let oldest = self.order.remove(0)
    self.kept.remove(oldest)
  }
  let found = find_preview(self.io, href) catch { _ => None }
  // A run or its attempt can change between two hovers. Coalesce only its in-flight reads.
  if @cloud_net.parse_url(href) is Some(url) && url.hostname() == "github.com" && actions_target(url.path) is Some(_) &&
    self.kept.get(href) is Some((_, current)) && physical_equal(current, value) {
    self.kept.remove(href)
    if self.order.search(href) is Some(i) { ignore(self.order.remove(i)) }
  }
  ignore(value.succeed(found))
  found
}
