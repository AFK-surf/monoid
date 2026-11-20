// station/src/ops/command-output.ts and loopback.ts: what a command's output and the page it opens say (the pages it
// names, a loopback callback, a device code, a prompt), and what the old loopback port answers.

///|
/// `/[@-~]/`: what ends a CSI sequence.
fn csi_final(c : Int) -> Bool {
  c >= 0x40 && c <= 0x7e
}

///|
/// command-output.ts `plainText`.
pub fn plain_text(text : String) -> String {
  let b = StringBuilder()
  let n = text.length()
  let mut i = 0
  while i < n {
    let c = cu(text, i)
    if c == 0x1b {
      let next = if i + 1 < n { cu(text, i + 1) } else { -1 }
      if next == 91 {
        i += 2
        while i < n && !csi_final(cu(text, i)) {
          i += 1
        }
      } else if next == 93 {
        i += 2
        while i < n && cu(text, i) != 7 && !(cu(text, i) == 0x1b && i + 1 < n && cu(text, i + 1) == 92) {
          i += 1
        }
        if i < n && cu(text, i) == 0x1b {
          i += 1
        }
      } else {
        i += 1
      }
      i += 1
      continue
    }
    if c == 13 {
      let mut j = i + 1
      while j < n && cu(text, j) == 13 {
        j += 1
      }
      if !(j < n && cu(text, j) == 10) {
        b.write_char('\n')
      }
      i = j
      continue
    }
    if c == 8 || c == 7 || c == 0x0f || c == 0x0e {
      i += 1
      continue
    }
    b.write_char(Int::unsafe_to_char(c))
    i += 1
  }
  b.to_string()
}

///|
/// `[^\s"'<>`]`: what a URL in some text is made of.
fn url_unit(c : Int) -> Bool {
  !js_space(c) && c != 34 && c != 39 && c != 60 && c != 62 && c != 96
}

///|
/// Where `/https?:\/\/[^\s"'<>`]+/` matches at or after `from`: its start and end.
fn next_url(text : String, from : Int) -> (Int, Int)? {
  let n = text.length()
  let mut i = from
  while i < n {
    let rest = sub(text, i, @cmp.minimum(n, i + 8))
    let scheme = if starts(rest, "https://") {
      8
    } else if starts(rest, "http://") {
      7
    } else {
      0
    }
    if scheme > 0 {
      let mut e = i + scheme
      while e < n && url_unit(cu(text, e)) {
        e += 1
      }
      if e > i + scheme {
        return Some((i, e))
      }
    }
    i += 1
  }
  None
}

///|
/// Whether `/https?:\/\/[^\s"'<>`]+$/` matches `s`.
fn ends_in_url(s : String) -> Bool {
  let mut from = 0
  while next_url(s, from) is Some((a, e)) {
    if e == s.length() {
      return true
    }
    from = a + 1
  }
  false
}

///|
/// command-output.ts `unwrapped`.
pub fn unwrapped(text : String, cols : Int) -> String {
  let lines = split_on(text, "\n")
  let full = (line : String) => js_trim_end(line).length() >= cols - 4
  let out = []
  let mut i = 0
  while i < lines.length() {
    let mut line = lines[i]
    let mut wide = full(line)
    while wide && i + 1 < lines.length() && ends_in_url(js_trim_end(line)) {
      let next = lines[i + 1]
      // `/^\s*[^\s"'<>`]/`
      let k = spaces_from(next, 0)
      if !(k < next.length() && url_unit(cu(next, k))) {
        break
      }
      line = js_trim_end(line) + js_trim_start(next)
      i += 1
      wide = full(next)
    }
    out.push(line)
    i += 1
  }
  out.join("\n")
}

///|
/// `/[.,;:!?)\]}'"…]$/`.
fn sentence_end(c : Int) -> Bool {
  c == 46 ||
  c == 44 ||
  c == 59 ||
  c == 58 ||
  c == 33 ||
  c == 63 ||
  c == 41 ||
  c == 93 ||
  c == 125 ||
  c == 39 ||
  c == 34 ||
  c == 0x2026
}

///|
/// command-output.ts `urlsIn`.
pub fn urls_in(text : String) -> Array[String] {
  let found = []
  let mut from = 0
  while next_url(text, from) is Some((a, e)) {
    from = e
    let mut url = sub(text, a, e)
    while url != "" &&
      sentence_end(cu(url, url.length() - 1)) &&
      !(ends(url, ")") && has(url, "(")) {
      url = sub(url, 0, url.length() - 1)
    }
    if ends(url, "...") {
      url = sub(url, 0, url.length() - 3)
    }
    if url.length() > 8 {
      found.push(url)
    }
  }
  found
}

// ── URLs and their parameters, as `new URL` and URLSearchParams read them ──

///|
/// Percent-decoding as URLSearchParams does it (`+` a space), UTF-8 with what does not decode replaced.
fn form_decode(s : String) -> String {
  @url.percent_decode_lossy(s, plus_space=true)
}

///|
/// URLSearchParams of a query (`?` left out): its pairs in order.
fn search_params(query : String) -> Array[(String, String)] {
  let out = []
  for part in split_on(query, "&") {
    if part == "" {
      continue
    }
    let eq = index_of(part, "=")
    if eq < 0 {
      out.push((form_decode(part), ""))
    } else {
      out.push((form_decode(sub(part, 0, eq)), form_decode(sub(part, eq + 1, part.length()))))
    }
  }
  out
}

///|
fn param(ps : Array[(String, String)], name : String) -> String? {
  for p in ps {
    if p.0 == name {
      return Some(p.1)
    }
  }
  None
}

///|
fn url_params(u : @cloud_net.Url) -> Array[(String, String)] {
  match u.query {
    Some(q) => search_params(q)
    None => []
  }
}

///|
/// `url.host`: its hostname, and port where it has one.
fn url_host(u : @cloud_net.Url) -> String {
  match u.port {
    Some(p) => u.hostname() + ":" + p.to_string()
    None => u.hostname()
  }
}

///|
/// command-output.ts `Loopback`.
pub(all) struct Loopback {
  host : String
  port : Int
  path : String
  state : String?
  post : Bool
}

///|
pub fn Loopback::to_json(self : Loopback) -> Json {
  {
    "host": js(self.host),
    "port": ji(self.port),
    "path": js(self.path),
    "state": opt_s(self.state),
    "post": jb(self.post),
  }
}

///|
let redirects : Array[String] = [
  "redirect_uri", "redirect_url", "redirecturi", "redirect", "callback", "callback_url", "return_to",
]

///|
/// command-output.ts `loopbackOf`.
pub fn loopback_of(url : String, depth? : Int = 0) -> Loopback? {
  guard @cloud_net.parse_url(url) is Some(page) else { return None }
  let ps = url_params(page)
  let post = param(ps, "response_mode") == Some("form_post")
  let state = param(ps, "state")
  for p in ps {
    if !redirects.contains(lower(p.0)) {
      continue
    }
    guard @cloud_net.parse_url(p.1) is Some(back) else { continue }
    let hostname = back.hostname()
    if back.scheme != "http" ||
      !["localhost", "127.0.0.1", "[::1]", "::1"].contains(hostname) {
      continue
    }
    let port = match back.port {
      Some(port) => port
      None => continue
    }
    if port <= 0 || port > 65535 {
      continue
    }
    return Some({
      host: if hostname == "::1" { "[::1]" } else { hostname },
      port,
      path: if back.path == "" { "/" } else { back.path },
      state,
      post,
    })
  }
  if depth > 0 {
    return None
  }
  for p in ps {
    let v = p.1
    if !(starts(v, "http://") || starts(v, "https://")) {
      continue
    }
    match loopback_of(v, depth=depth + 1) {
      Some(inner) =>
        return Some({
          ..inner,
          state: match inner.state {
            Some(s) => Some(s)
            None => state
          },
          post: inner.post || post,
        })
      None => ()
    }
  }
  None
}

///|
/// command-output.ts `domainOf`.
pub fn domain_of(url : String) -> String? {
  @cloud_net.parse_url(url).map(url_host)
}

///|
/// `/^[A-Za-z0-9]{a,b}$/`.
fn alnum_run(s : String, a : Int, b : Int) -> Bool {
  s.length() >= a && s.length() <= b && all_units(s, is_alnum)
}

///|
/// `/^[A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{3,8})?$/`.
fn whole_code(s : String) -> Bool {
  let dash = index_of(s, "-")
  if dash < 0 {
    alnum_run(s, 4, 12)
  } else {
    alnum_run(sub(s, 0, dash), 4, 12) && alnum_run(sub(s, dash + 1, s.length()), 3, 8)
  }
}

///|
/// No word of prose: letters (and digits), not all small, not a capitalised word.
fn code_word(w : String) -> Bool {
  alnum_run(w, 6, 12) &&
  any_unit(w, is_alpha) &&
  !all_units(w, is_lower) &&
  !(w.length() >= 2 && is_upper(cu(w, 0)) && all_units(sub(w, 1, w.length()), is_lower))
}

///|
fn upper_digits(s : String) -> Bool {
  s != "" && all_units(s, c => is_upper(c) || is_digit(c))
}

///|
/// `\b` before `at`: a word character on one side only.
fn boundary(s : String, at : Int) -> Bool {
  let before = at > 0 && is_word(cu(s, at - 1))
  let after = at < s.length() && is_word(cu(s, at))
  before != after
}

///|
/// Each place `code` (case aside) starts a word in `line` (`\bcode`).
fn code_at(line : String) -> Array[Int] {
  let low = lower(line)
  let out = []
  let mut from = 0
  while true {
    let at = index_of(low, "code", from~)
    if at < 0 {
      break
    }
    out.push(at)
    from = at + 1
  }
  out
}

///|
/// After `code` at `at`: `(?:\s+is)?` taken where it can be, `then` given where it goes on from.
fn after_code_is(line : String, at : Int) -> Array[Int] {
  let e = at + 4
  let out = []
  // With ` is` (one or more spaces before it) first, as the greedy optional group tries it.
  let s = spaces_from(line, e)
  if s > e && lower(sub(line, s, s + 2)) == "is" {
    out.push(s + 2)
  }
  out.push(e)
  out
}

///|
/// The run of `[A-Za-z0-9]` from `i`, at most `most` long, and whether `\b` holds after it.
fn alnum_from(line : String, i : Int, least : Int, most : Int) -> String? {
  let mut e = i
  while e < line.length() && is_alnum(cu(line, e)) && e - i < most {
    e += 1
  }
  // Backtracking: the longest run of `least..most` followed by `\b`.
  let mut k = e
  while k - i >= least {
    if boundary(line, k) || k == line.length() {
      if k == line.length() || !is_word(cu(line, k)) || !is_word(cu(line, k - 1)) {
        return Some(sub(line, i, k))
      }
    }
    k -= 1
  }
  None
}

///|
/// `/\bcode(?:\s+is)?\s*[:=]\s*([A-Za-z0-9]{6,12})\b/i`.
fn marked_code(line : String) -> String? {
  for at in code_at(line) {
    if !boundary(line, at) {
      continue
    }
    for e in after_code_is(line, at) {
      let k = spaces_from(line, e)
      if k < line.length() && (cu(line, k) == 58 || cu(line, k) == 61) {
        let v = spaces_from(line, k + 1)
        match alnum_from(line, v, 6, 12) {
          Some(w) => return Some(w)
          None => ()
        }
      }
    }
  }
  None
}

///|
/// `/\bcode(?:\s+is)?\s+([A-Za-z0-9]{6,12})\b/i`.
fn spaced_code(line : String) -> String? {
  for at in code_at(line) {
    if !boundary(line, at) {
      continue
    }
    for e in after_code_is(line, at) {
      let k = spaces_from(line, e)
      if k > e {
        match alnum_from(line, k, 6, 12) {
          Some(w) => return Some(w)
          None => ()
        }
      }
    }
  }
  None
}

///|
/// `/code[^A-Za-z0-9]{1,3}([A-Z0-9]{6,10})\b/i`: the case aside, so `[A-Z0-9]` is any letter or digit.
fn after_code(line : String) -> String? {
  for at in code_at(line) {
    let e = at + 4
    let mut k = e
    while k < line.length() && !is_alnum(cu(line, k)) {
      k += 1
    }
    if k - e < 1 || k - e > 3 {
      continue
    }
    match alnum_from(line, k, 6, 10) {
      Some(w) => return Some(w)
      None => ()
    }
  }
  None
}

///|
/// command-output.ts `deviceCodeIn`.
pub fn device_code_in(said : String, opened : Array[String]) -> String? {
  for u in [..opened, ..urls_in(said)] {
    match @cloud_net.parse_url(u) {
      Some(p) =>
        match param(url_params(p), "user_code") {
          Some(given) if given != "" && whole_code(given) => return Some(given)
          _ => ()
        }
      None => ()
    }
  }
  // `/[?&]user_code=([A-Za-z0-9]{4,12}(?:-[A-Za-z0-9]{3,8})?)(?![A-Za-z0-9_-])/`
  let mut from = 0
  while true {
    let at = index_of(said, "user_code=", from~)
    if at < 0 {
      break
    }
    from = at + 1
    if at == 0 || (cu(said, at - 1) != 63 && cu(said, at - 1) != 38) {
      continue
    }
    let v = at + 10
    match given_code(said, v) {
      Some(c) => return Some(c)
      None => ()
    }
  }
  // URLs out of it.
  let text = {
    let b = StringBuilder()
    let mut i = 0
    while next_url(said, i) is Some((a, e)) {
      b.write_string(sub(said, i, a))
      b.write_string(" ")
      i = e
    }
    b.write_string(sub(said, i, said.length()))
    b.to_string()
  }
  for word in split_by(text, c => !(is_alnum(c) || c == 95 || c == 45)) {
    let parts = split_on(word, "-")
    let code = (s : String, min : Int, max : Int) => s.length() >= min && s.length() <= max && upper_digits(s)
    for i in 0..<(parts.length() - 1) {
      if code(parts[i], 4, 4) && code(parts[i + 1], 4, 6) {
        return Some(parts[i] + "-" + parts[i + 1])
      }
    }
  }
  let lines = split_on(text, "\n")
  for i, l in lines {
    if !ends_code_colon(l) {
      continue
    }
    let next = if i + 1 < lines.length() && js_trim(lines[i + 1]) == "" { lines.get(i + 2) } else { lines.get(i + 1) }
    match next {
      Some(nx) => {
        let t = js_trim(nx)
        // `/^\s*([A-Za-z0-9]{6,12})\s*$/`
        if alnum_run(t, 6, 12) && code_word(t) && js_trim(nx) == t {
          return Some(t)
        }
      }
      None => ()
    }
  }
  for line in lines {
    if !has(lower(line), "code") {
      continue
    }
    match marked_code(line) {
      Some(m) if code_word(m) => return Some(m)
      _ => ()
    }
    match spaced_code(line) {
      Some(s) if (upper_digits(s) && s.length() >= 6 && s.length() <= 10) ||
        (any_unit(s, is_digit) && code_word(s)) => return Some(s)
      _ => ()
    }
    match after_code(line) {
      Some(a) if upper_digits(a) => return Some(a)
      _ => ()
    }
    for word in split_runs(line, c => !is_alnum(c)) {
      if word.length() >= 6 &&
        word.length() <= 10 &&
        upper_digits(word) &&
        any_unit(word, is_digit) &&
        any_unit(word, is_upper) {
        return Some(word)
      }
    }
  }
  None
}

///|
/// A code given after `user_code=` at `v`: as long as its pattern takes, nothing of a code after it.
fn given_code(s : String, v : Int) -> String? {
  let n = s.length()
  let mut e = v
  while e < n && is_alnum(cu(s, e)) && e - v < 12 {
    e += 1
  }
  let not_more = (k : Int) => k >= n || !(is_alnum(cu(s, k)) || cu(s, k) == 95 || cu(s, k) == 45)
  // The first part's length, longest first; then an optional `-` part, longest first.
  let mut a = e
  while a - v >= 4 {
    if a < n && cu(s, a) == 45 {
      let mut b = a + 1
      while b < n && is_alnum(cu(s, b)) && b - a - 1 < 8 {
        b += 1
      }
      while b - a - 1 >= 3 {
        if not_more(b) {
          return Some(sub(s, v, b))
        }
        b -= 1
      }
    }
    if not_more(a) {
      return Some(sub(s, v, a))
    }
    a -= 1
  }
  None
}

///|
/// `/\bcode\s*:\s*$/i`.
fn ends_code_colon(line : String) -> Bool {
  let t = js_trim_end(line)
  if !ends(t, ":") {
    return false
  }
  let before = js_trim_end(sub(t, 0, t.length() - 1))
  if !ends(lower(before), "code") {
    return false
  }
  let at = before.length() - 4
  boundary(before, at)
}

///|
/// command-output.ts `deviceUrls`.
pub fn device_urls(urls : Array[String], code : String) -> (String?, String?) {
  let pages = urls.filter(u => starts(u, "https://") && loopback_of(u) is None)
  let with_code = pages
    .search_by(u => has(u, code) || has(u, "?user_code=") || has(u, "&user_code=") || has(u, "?code=") || has(u, "&code="))
    .map(i => pages[i])
  let verify = match pages.search_by(u => {
      let path = match @cloud_net.parse_url(u) {
        Some(p) => lower(p.path)
        None => ""
      }
      has(path, "device") || has(path, "activate") || has(path, "verif")
    }) {
    Some(i) => Some(pages[i])
    None => pages.get(0)
  }
  (verify, with_code)
}

///|
/// command-output.ts `asksEnter`: `/press\s+(enter|return)\b[^?]*\b(open|browser)/i`, and no (y/n).
pub fn asks_enter(line : String) -> Bool {
  let low = lower(line)
  let mut ok = false
  let mut from = 0
  while !ok {
    let at = index_of(low, "press", from~)
    if at < 0 {
      break
    }
    from = at + 1
    let s = spaces_from(low, at + 5)
    if s == at + 5 {
      continue
    }
    let key_end = if starts(sub(low, s, low.length()), "enter") {
      s + 5
    } else if starts(sub(low, s, low.length()), "return") {
      s + 6
    } else {
      continue
    }
    if !boundary(low, key_end) && key_end < low.length() {
      continue
    }
    // `[^?]*\b(open|browser)`: up to the first `?`.
    let q = index_of(low, "?", from=key_end)
    let span = sub(low, key_end, if q < 0 { low.length() } else { q })
    let mut k = 0
    while k <= span.length() && !ok {
      let rest = sub(span, k, span.length())
      if (starts(rest, "open") || starts(rest, "browser")) && boundary(low, key_end + k) {
        ok = true
      }
      k += 1
    }
  }
  ok && !yn_choice(low)
}

///|
/// `/\([yn]\/[yn]\)|\[[yn]\/[yn]\]/i` (lower case given).
fn yn_choice(low : String) -> Bool {
  let n = low.length()
  for i in 0..<n {
    if i + 4 < n {
      let o = cu(low, i)
      let c = cu(low, i + 4)
      let yn = (x : Int) => x == 121 || x == 110
      if ((o == 40 && c == 41) || (o == 91 && c == 93)) && yn(cu(low, i + 1)) && cu(low, i + 2) == 47 && yn(cu(low, i + 3)) {
        return true
      }
    }
  }
  false
}

///|
/// command-output.ts `saysDone`.
pub fn says_done(text : String) -> Bool {
  let low = lower(text)
  // `\b(authentication|authorization|login|sign[- ]?in)\s+(is\s+)?(complete|completed|succeeded|successful)\b`
  for first in ["authentication", "authorization", "login", "signin", "sign-in", "sign in"] {
    let mut from = 0
    while true {
      let at = word_start(low, first, from)
      if at < 0 {
        break
      }
      from = at + 1
      let mut k = spaces_from(low, at + first.length())
      if k == at + first.length() {
        continue
      }
      let is_k = if starts(sub(low, k, low.length()), "is") && spaces_from(low, k + 2) > k + 2 {
        Some(spaces_from(low, k + 2))
      } else {
        None
      }
      for start in [is_k, Some(k)] {
        match start {
          Some(s) => {
            k = s
            for w in ["completed", "complete", "succeeded", "successful"] {
              if starts(sub(low, k, low.length()), w) && boundary(low, k + w.length()) {
                return true
              }
            }
          }
          None => ()
        }
      }
    }
  }
  // `\b(logged|signed)\s+in\b`
  for w in ["logged", "signed"] {
    let mut from = 0
    while true {
      let at = word_start(low, w, from)
      if at < 0 {
        break
      }
      from = at + 1
      let k = spaces_from(low, at + w.length())
      if k > at + w.length() && starts(sub(low, k, low.length()), "in") && boundary(low, k + 2) {
        return true
      }
    }
  }
  // `\bsuccessfully\s+(authenticated|logged|signed|authorized)\b`
  let mut from = 0
  while true {
    let at = word_start(low, "successfully", from)
    if at < 0 {
      break
    }
    from = at + 1
    let k = spaces_from(low, at + 12)
    if k > at + 12 {
      for w in ["authenticated", "logged", "signed", "authorized"] {
        if starts(sub(low, k, low.length()), w) && boundary(low, k + w.length()) {
          return true
        }
      }
    }
  }
  // `\bauthenticated\s+(as|to|with)\b`
  from = 0
  while true {
    let at = word_start(low, "authenticated", from)
    if at < 0 {
      break
    }
    from = at + 1
    let k = spaces_from(low, at + 13)
    if k > at + 13 {
      for w in ["as", "to", "with"] {
        if starts(sub(low, k, low.length()), w) && boundary(low, k + w.length()) {
          return true
        }
      }
    }
  }
  false
}

///|
/// Where `w` starts a word (`\b` before it) at or after `from`.
fn word_start(low : String, w : String, from : Int) -> Int {
  let mut f = from
  while true {
    let at = index_of(low, w, from=f)
    if at < 0 {
      return -1
    }
    if boundary(low, at) {
      return at
    }
    f = at + 1
  }
  -1
}

///|
/// command-output.ts `storesSecret`.
pub fn stores_secret(name : String) -> Bool {
  let last = split_on(name, "/").last().unwrap_or(name)
  let low = lower(last)
  ["credential", "keychain", "keyring", "pinentry", "askpass", "secret-tool", "kwallet"].iter().any(w => has(low, w))
}

///|
/// command-output.ts `prompts`.
pub fn prompts(line : String) -> Bool {
  let t = js_trim(line)
  let ends_mark = t != "" && {
    let c = cu(t, t.length() - 1)
    c == 63 || c == 58 || c == 62 || c == 41 || c == 93 || c == 0xff1e || c == 0xff1a || c == 0xff1f
  }
  if ends_mark {
    return true
  }
  // `/\([yY]\/[nN]\)|\[[yY]\/[nN]\]/`
  let n = line.length()
  for i in 0..<n {
    if i + 4 < n {
      let o = cu(line, i)
      let c = cu(line, i + 4)
      if ((o == 40 && c == 41) || (o == 91 && c == 93)) &&
        (cu(line, i + 1) == 121 || cu(line, i + 1) == 89) &&
        cu(line, i + 2) == 47 &&
        (cu(line, i + 3) == 110 || cu(line, i + 3) == 78) {
        return true
      }
    }
  }
  // `/^\s*[>❯]\s/`
  let k = spaces_from(line, 0)
  k + 1 < n && (cu(line, k) == 62 || cu(line, k) == 0x276f) && js_space(cu(line, k + 1))
}

///|
/// command-output.ts `secretAsked`.
pub fn secret_asked(line : String) -> Bool {
  let low = lower(line)
  ["password", "passphrase", "token", "secret", "密码"].iter().any(w => has(low, w))
}

///|
/// command-output.ts `assignmentsOf`.
pub fn assignments_of(words : Array[String], home : String?) -> (Array[(String, String)], Array[String]) {
  let env : Array[(String, String)] = []
  let mut i = 0
  while i < words.length() {
    let w = words[i]
    let eq = index_of(w, "=")
    if eq <= 0 || !env_name(sub(w, 0, eq)) {
      break
    }
    let value = sub(w, eq + 1, w.length())
    let v = match home {
      Some(h) if value == "~" || starts(value, "~/") => h + sub(value, 1, value.length())
      _ => value
    }
    env_set(env, sub(w, 0, eq), v)
    i += 1
  }
  (env, words[i:].to_owned())
}

///|
fn runner_options(name : String) -> Array[String]? {
  match name {
    "env" => Some(["-u", "--unset", "-C", "--chdir", "-S", "--split-string", "-P"])
    "sudo" =>
      Some([
        "-u", "--user", "-g", "--group", "-C", "--close-from", "-D", "--chdir", "-h", "--host", "-p", "--prompt", "-r", "--role",
        "-t", "--type", "-T", "--command-timeout", "-U", "--other-user",
      ])
    "doas" => Some(["-u", "-C"])
    "nohup" => Some([])
    "command" => Some([])
    "exec" => Some(["-a"])
    "npx" => Some(["-p", "--package", "-c", "--call"])
    "pnpx" => Some(["-p", "--package"])
    "bunx" => Some(["-p", "--package"])
    "uvx" => Some(["--from", "--with", "-p", "--python", "--index", "--index-url"])
    "npm exec" => Some(["-p", "--package", "-c", "--call"])
    "pnpm dlx" => Some(["-p", "--package"])
    "pnpm exec" => Some([])
    "yarn dlx" => Some(["-p", "--package"])
    "pipx run" => Some(["--spec", "--python"])
    _ => None
  }
}

///|
/// command-output.ts `programOf`.
pub fn program_of(words : Array[String]) -> String {
  let mut i = 0
  let skip = (valued : Array[String]) => {
    while i < words.length() && starts(words[i], "-") && words[i] != "-" {
      let option = words[i]
      i += 1
      if option == "--" {
        break
      }
      if valued.contains(option) {
        i += 1
      }
    }
  }
  while true {
    while i < words.length() && assignment_word(words[i]) {
      i += 1
    }
    guard words.get(i) is Some(word) else { break }
    let base = split_by(word, wsep).last().unwrap()
    let two = runner_options(base + " " + words.get(i + 1).unwrap_or(""))
    let one = runner_options(base)
    if two is None && one is None {
      break
    }
    i += if two is Some(_) { 2 } else { 1 }
    skip(match two {
      Some(t) => t
      None => one.unwrap()
    })
  }
  let word = match words.get(i) {
    Some(w) => w
    None => words.get(0).unwrap_or("")
  }
  let base = split_by(word, wsep).last().unwrap()
  // `.replace(/(.)@.*$/, "$1")`: from the first `@` past the first character.
  let at = index_of(base, "@", from=1)
  if at >= 1 && !any_unit(sub(base, at, base.length()), c => c == 10 || c == 13 || c == 0x2028 || c == 0x2029) {
    sub(base, 0, at)
  } else {
    base
  }
}

///|
/// `/^[A-Za-z_][A-Za-z0-9_]*=/`.
fn assignment_word(w : String) -> Bool {
  let eq = index_of(w, "=")
  eq > 0 && env_name(sub(w, 0, eq))
}

///|
/// command-output.ts `commandWords`.
pub fn command_words(line : String) -> Array[String]? {
  let words = []
  let word = StringBuilder()
  let mut has_word = false
  let mut quote = 0
  let n = line.length()
  let mut i = 0
  while i < n {
    let c = cu(line, i)
    if quote == 39 {
      if c == 39 {
        quote = 0
      } else {
        word.write_char(Int::unsafe_to_char(c))
      }
    } else if quote == 34 {
      if c == 34 {
        quote = 0
      } else if c == 92 && i + 1 < n && (cu(line, i + 1) == 34 || cu(line, i + 1) == 92 || cu(line, i + 1) == 36 || cu(line, i + 1) == 96) {
        i += 1
        word.write_char(Int::unsafe_to_char(cu(line, i)))
      } else {
        word.write_char(Int::unsafe_to_char(c))
      }
    } else if c == 39 || c == 34 {
      quote = c
      has_word = true
    } else if c == 92 && i + 1 < n {
      i += 1
      word.write_char(Int::unsafe_to_char(cu(line, i)))
      has_word = true
    } else if js_space(c) {
      let w = word.to_string()
      if has_word || w != "" {
        words.push(w)
      }
      word.reset()
      has_word = false
    } else {
      word.write_char(Int::unsafe_to_char(c))
    }
    i += 1
  }
  if quote != 0 {
    return None
  }
  let w = word.to_string()
  if has_word || w != "" {
    words.push(w)
  }
  Some(words)
}

///|
/// command-output.ts `webPage`.
pub fn web_page(url : String?) -> Bool {
  match url {
    Some(u) => {
      let low = lower(sub(u, 0, 8))
      starts(low, "http://") || starts(low, "https://")
    }
    None => false
  }
}

// ── loopback.ts ──────────────────────────────────────────────────────────────────────────────────────────────────

///|
/// loopback.ts `langOfBrowser`: `stillfail-lang`, else Accept-Language's first (`*` names none).
pub fn lang_of_browser(said : String?, accept : String?) -> String {
  match said {
    Some(s) => lang_of(Some(s))
    None => {
      let first = js_trim(split_by(accept.unwrap_or(""), c => c == 44 || c == 59)[0])
      lang_of(Some(if first == "*" { "" } else { first }))
    }
  }
}

///|
/// loopback.ts `moved`: where a page of the station's old page is in the cloud's web app.
pub fn moved(path : String, query : String?, origin : String, workspace : String, station : String) -> String {
  let mut o = origin
  while ends(o, "/") {
    o = sub(o, 0, o.length() - 1)
  }
  let w = o + "/w/" + workspace
  let s = station
  let parts = split_on(path, "/").filter(p => p != "")
  let a = parts.get(0).unwrap_or("")
  let b = parts.get(1).unwrap_or("")
  let c = parts.get(2).unwrap_or("")
  let n = parts.length()
  let to = if n == 2 && a == "chats" {
    "\{w}/s/\{s}/chats/\{b}"
  } else if n == 2 && a == "services" {
    "\{w}/s/\{s}/services/\{b}"
  } else if n == 2 && (a == "connects" || a == "bots") {
    "\{w}/s/\{s}/connects/\{b}"
  } else if n == 2 && a == "settings" && b == "accounts" {
    "\{w}/s/\{s}/settings/accounts"
  } else if n == 3 && a == "settings" && b == "accounts" {
    "\{w}/s/\{s}/settings/accounts/\{c}"
  } else if n == 2 && a == "settings" && ["connects", "memory", "appearance", "shortcuts"].contains(b) {
    "\{w}/settings/\{b}"
  } else if n == 2 && a == "settings" && b == "device" {
    "\{w}/settings/stations"
  } else if n == 1 && a == "settings" {
    "\{w}/settings"
  } else if n == 1 && a == "new" {
    "\{w}/new"
  } else if n == 1 && a == "archive" {
    "\{w}/archive"
  } else {
    "\{w}/"
  }
  match query {
    Some(q) if q != "" => to + "?" + q
    _ => to
  }
}

///|
/// loopback.ts `answer`: the status, headers and body the port answers `path`?`query` with. `place` is cloud.json's
/// (origin, workspace, workspace_name, station, removed_at?).
pub fn loopback_answer(
  catalog : Catalog,
  path : String,
  query : String?,
  ready : Bool,
  place : Json?,
  lang : String,
) -> Json {
  fn plain(status : Int, body : String) -> Json {
    { "status": ji(status), "headers": { "content-type": "text/plain; charset=utf-8" }, "body": js(body) }
  }
  if path == "/healthz" {
    return plain(if ready { 200 } else { 503 }, "")
  }
  if starts(path, "/admin/api/") || path == "/admin/api" {
    let body : Json = { "error": js(tr(catalog, lang, "station.local.noAdminApi", Map([]))) }
    return { "status": 404, "headers": { "content-type": "application/json" }, "body": js(js_stringify(body)) }
  }
  if path != "/" && path != "/admin" && !starts(path, "/admin/") {
    return plain(404, "")
  }
  match place {
    Some(p) if field(p, "removed_at") is None &&
      str_or(p, "origin", "") != "" &&
      str_or(p, "workspace", "") != "" => {
      let rest = if starts(path, "/admin") { sub(path, 6, path.length()) } else { path }
      let to = moved(rest, query, str_or(p, "origin", ""), str_or(p, "workspace", ""), str_or(p, "station", ""))
      return { "status": 302, "headers": { "location": js(to), "cache-control": "no-store" }, "body": "" }
    }
    _ => ()
  }
  let body = match place {
    Some(p) if field(p, "removed_at") is Some(_) =>
      tr(catalog, lang, "station.local.removed", {
        "workspace": field(p, "workspace_name").unwrap_or(Json::null()),
        "at": js(iso_time(num_field(p, "removed_at").unwrap_or(0.0) * 1000.0)),
      })
    _ => tr(catalog, lang, "station.local.unjoined", Map([]))
  }
  plain(404, body)
}
