// A post's local Markdown links made into its attachments (native/mesh/src/local.rs `prepare_local_links`, the Rust
// station's local_links.rs `prepare`), word for word in its refusals: a link to a file on this machine (a file: URL, a
// path from a familiar root or one that names a file, a drive's path on Windows, a path where the agent works) is
// refused unless it is an inline link written without escapes, else its file is added to the message's and the link
// made to name it by its name, percent-encoded. The Markdown is read as src/sessions/local-links.ts `links` reads what
// pulldown-cmark finds of links (inline links and images, `<…>` destinations, nested ones, outside code spans and
// fenced code blocks; reference links; autolinks of file: URLs); what is on the disk is the caller's `LinkWorld`.

///|
/// What the links are read against: the machine's paths (`sep` "\\" on Windows) and its files.
pub(all) struct LinkWorld {
  sep : String
  /// Whether `path` names a file (not a folder).
  is_file : (String) -> Bool
  /// realpath(3); None where it is not there.
  realpath : (String) -> String?
}

///|
/// A link or image found: whether it is inline, its destination (escapes resolved) and where it is, [start, end).
#derive(Debug, Eq)
pub(all) struct Found {
  inline : Bool
  destination : String
  start : Int
  end : Int
}

///|
pub(all) suberror LinkRefused {
  LinkRefused(String)
}

///|
/// Its words where it is said (`to_string`, a notice, a log): not its type's name (`station/<package>.<Type>`).
pub impl Show for LinkRefused with output(self, logger) {
  match self {
    LinkRefused(m) => logger.write_string(m)
  }
}

///|
fn ch(s : String, i : Int) -> Int {
  if i >= 0 && i < s.length() {
    s.unsafe_charcode_at(i)
  } else {
    -1
  }
}

///|
fn sub(s : String, from : Int, to : Int) -> String {
  let n = s.length()
  let a = if from < 0 { 0 } else if from > n { n } else { from }
  let b = if to < a { a } else if to > n { n } else { to }
  s[a:b].to_owned()
}

///|
/// JavaScript's whitespace (`\s`, `trim`).
fn js_space(c : Int) -> Bool {
  c == 0x20 ||
  (c >= 0x09 && c <= 0x0D) ||
  c == 0xA0 ||
  c == 0x1680 ||
  (c >= 0x2000 && c <= 0x200A) ||
  c == 0x2028 ||
  c == 0x2029 ||
  c == 0x202F ||
  c == 0x205F ||
  c == 0x3000 ||
  c == 0xFEFF
}

///|
fn trim_end_js(s : String) -> String {
  let mut n = s.length()
  while n > 0 && js_space(ch(s, n - 1)) {
    n -= 1
  }
  sub(s, 0, n)
}

///|
fn trim_js(s : String) -> String {
  let mut a = 0
  while a < s.length() && js_space(ch(s, a)) {
    a += 1
  }
  trim_end_js(sub(s, a, s.length()))
}

///|
/// `label.trim().toLowerCase().replace(/\s+/g, " ")`.
fn label_key(label : String) -> String {
  let t = trim_js(label).to_lower()
  let out = StringBuilder()
  let mut space = false
  for c in t {
    if js_space(c.to_int()) {
      if !space {
        out.write_char(' ')
      }
      space = true
    } else {
      out.write_char(c)
      space = false
    }
  }
  out.to_string()
}

///|
fn is_hex(c : Int) -> Bool {
  (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f')
}

///|
fn hex_value(c : Int) -> Int {
  if c >= '0' && c <= '9' {
    c - '0'
  } else if c >= 'A' && c <= 'F' {
    c - 'A' + 10
  } else {
    c - 'a' + 10
  }
}

///|
/// percent_decode_str(..).decode_utf8_lossy().
pub fn percent_decode(text : String) -> String {
  let raw = @utf8.encode(text)
  let out = @buffer.Buffer()
  let mut i = 0
  while i < raw.length() {
    let b = raw[i].to_int()
    if b == 0x25 && i + 2 < raw.length() && is_hex(raw[i + 1].to_int()) && is_hex(raw[i + 2].to_int()) {
      out.write_byte((hex_value(raw[i + 1].to_int()) * 16 + hex_value(raw[i + 2].to_int())).to_byte())
      i += 3
    } else {
      out.write_byte(raw[i])
      i += 1
    }
  }
  @utf8.decode_lossy(out.to_bytes())
}

///|
/// utf8_percent_encode(.., NON_ALPHANUMERIC): every byte but ASCII letters and digits as %XX.
pub fn percent_encode(text : String) -> String {
  @url.percent_encode(text, v => (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122))
}

///|
fn is_punct(c : Int) -> Bool {
  "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains_char(c.unsafe_to_char())
}

///|
/// A destination as pulldown-cmark gives it: backslash escapes resolved.
fn unescape(raw : String) -> String {
  let out = StringBuilder()
  let mut i = 0
  while i < raw.length() {
    let c = ch(raw, i)
    if c == '\\' && i + 1 < raw.length() && is_punct(ch(raw, i + 1)) {
      out.write_char(ch(raw, i + 1).unsafe_to_char())
      i += 2
    } else {
      out.write_char(c.unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// Where code is (fenced blocks and code spans), as [start, end) ranges: nothing in them is a link.
fn code_ranges(text : String) -> Array[(Int, Int)] {
  let ranges = []
  let mut at = 0
  let mut open : (Int, Int, Int)? = None // (start, fence char, fence length)
  let lines = text.split("\n").map(l => l.to_owned()).to_array()
  for line in lines {
    // /^ {0,3}(`{3,}|~{3,})/
    let mut i = 0
    while i < 3 && ch(line, i) == ' ' {
      i += 1
    }
    let f = ch(line, i)
    let mut n = 0
    if f == '`' || f == '~' {
      while ch(line, i + n) == f {
        n += 1
      }
    }
    let fenced = n >= 3
    let after = sub(line, i + n, line.length())
    match open {
      None =>
        if fenced && !(f == '`' && after.contains("`")) {
          open = Some((at, f, n))
        }
      Some((start, of, on)) =>
        if fenced && f == of && n >= on && trim_js(after) == "" {
          ranges.push((start, at + line.length()))
          open = None
        }
    }
    at += line.length() + 1
  }
  if open is Some((start, _, _)) {
    ranges.push((start, text.length()))
  }
  let in_block = (i : Int) => ranges.iter().any(r => i >= r.0 && i < r.1)
  let spans = []
  let mut i = 0
  while i < text.length() {
    if ch(text, i) == '\\' {
      i += 2
      continue
    }
    if ch(text, i) != '`' || in_block(i) {
      i += 1
      continue
    }
    let mut n = 0
    while ch(text, i + n) == '`' {
      n += 1
    }
    let mut close = -1
    let mut j = i + n
    while j < text.length() {
      // text.indexOf(run, j)
      let mut k = j
      while k < text.length() {
        let mut m = 0
        while m < n && ch(text, k + m) == '`' {
          m += 1
        }
        if m == n {
          break
        }
        k += 1
      }
      if k >= text.length() {
        break
      }
      let mut m = 0
      while ch(text, k + m) == '`' {
        m += 1
      }
      if m == n {
        close = k
        break
      }
      j = k + m
    }
    if close < 0 {
      i += n
      continue
    }
    spans.push((i, close + n))
    i = close + n
  }
  ranges + spans
}

///|
/// The `]` closing the bracket that opens at `open`, nested brackets counted, escapes and code skipped.
fn closing(text : String, open : Int, code : (Int) -> Bool) -> Int {
  let mut depth = 0
  let mut i = open
  while i < text.length() {
    let c = ch(text, i)
    if c == '\\' {
      i += 2
      continue
    }
    if !code(i) {
      if c == '[' {
        depth += 1
      } else if c == ']' {
        depth -= 1
        if depth == 0 {
          return i
        }
      }
    }
    i += 1
  }
  -1
}

///|
fn blank(c : Int) -> Bool {
  c == ' ' || c == '\t' || c == '\n'
}

///|
/// An inline link's destination after its `](`: the raw destination's [start, end), and where the link ends.
fn inline_destination(text : String, at : Int) -> (Int, Int, Int)? {
  let mut i = at
  while blank(ch(text, i)) {
    i += 1
  }
  let mut start = 0
  let mut end = 0
  if ch(text, i) == '<' {
    start = i + 1
    let mut j = start
    while j < text.length() && ch(text, j) != '>' && ch(text, j) != '\n' && ch(text, j) != '<' {
      j += if ch(text, j) == '\\' { 2 } else { 1 }
    }
    if ch(text, j) != '>' {
      return None
    }
    end = j
    i = j + 1
  } else {
    start = i
    let mut depth = 0
    let mut j = i
    while j < text.length() {
      let c = ch(text, j)
      if c == '\\' {
        j += 2
        continue
      }
      if js_space(c) {
        break
      }
      if c == '(' {
        depth += 1
      } else if c == ')' {
        if depth == 0 {
          break
        }
        depth -= 1
      }
      j += 1
    }
    // (an escape at the very end steps past it, as `j++` then the loop's `j++` do)
    end = if j > text.length() { text.length() } else { j }
    i = end
  }
  while blank(ch(text, i)) {
    i += 1
  }
  let quote = ch(text, i)
  if quote == '"' || quote == '\'' || quote == '(' {
    let shut = if quote == '(' { ')'.to_int() } else { quote }
    let mut j = i + 1
    while j < text.length() && ch(text, j) != shut {
      j += if ch(text, j) == '\\' { 2 } else { 1 }
    }
    if ch(text, j) != shut {
      return None
    }
    i = j + 1
    while blank(ch(text, i)) {
      i += 1
    }
  }
  if ch(text, i) == ')' {
    Some((start, end, i + 1))
  } else {
    None
  }
}

///|
/// A reference definition at a line's start (`/^ {0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|\S+)[^\n]*$/m`): its label and
/// raw destination, and where its line ends.
fn definition_at(text : String, line_start : Int) -> (String, String, Int)? {
  let mut i = line_start
  let mut k = 0
  while k < 3 && ch(text, i) == ' ' {
    i += 1
    k += 1
  }
  guard ch(text, i) == '[' else { None }
  let label_start = i + 1
  let mut j = label_start
  while j < text.length() && ch(text, j) != ']' && ch(text, j) != '\n' {
    j += 1
  }
  guard j > label_start && ch(text, j) == ']' && ch(text, j + 1) == ':' else { None }
  let label = sub(text, label_start, j)
  let mut d = j + 2
  while ch(text, d) == ' ' || ch(text, d) == '\t' {
    d += 1
  }
  let mut line_end = d
  while line_end < text.length() && ch(text, line_end) != '\n' {
    line_end += 1
  }
  let raw = if ch(text, d) == '<' {
    let mut e = d + 1
    while e < text.length() && ch(text, e) != '>' && ch(text, e) != '\n' {
      e += 1
    }
    if ch(text, e) == '>' {
      Some(sub(text, d, e + 1))
    } else {
      None
    }
  } else {
    None
  }
  let raw = match raw {
    Some(r) => r
    None => {
      // \S+ (backtracking into `[^\n]*$` makes any run of non-space at least one long do)
      let mut e = d
      while e < text.length() && !js_space(ch(text, e)) {
        e += 1
      }
      guard e > d else { return None }
      sub(text, d, e)
    }
  }
  Some((label, raw, line_end))
}

///|
/// The links and images Markdown finds in `text`, in order of where they start (local-links.ts `links`).
pub fn links(text : String) -> Array[Found] {
  let code = code_ranges(text)
  let in_code = (i : Int) => code.iter().any(r => i >= r.0 && i < r.1)
  let definitions : Map[String, String] = Map([])
  let defined = []
  let mut line_start = 0
  while line_start <= text.length() {
    if !in_code(line_start) && definition_at(text, line_start) is Some((label, raw, end)) {
      let key = label_key(label)
      if !definitions.contains(key) {
        definitions[key] = unescape(if raw.has_prefix("<") { sub(raw, 1, raw.length() - 1) } else { raw })
      }
      defined.push((line_start, end))
    }
    let mut next = line_start
    while next < text.length() && ch(text, next) != '\n' {
      next += 1
    }
    line_start = next + 1
  }
  let found : Array[Found] = []
  let mut i = 0
  while i < text.length() {
    if ch(text, i) == '\\' {
      i += 2
      continue
    }
    if ch(text, i) != '[' || in_code(i) || defined.iter().any(r => i >= r.0 && i < r.1) {
      i += 1
      continue
    }
    let start = if i > 0 && ch(text, i - 1) == '!' && !(i > 1 && ch(text, i - 2) == '\\') { i - 1 } else { i }
    let close = closing(text, i, in_code)
    if close < 0 {
      i += 1
      continue
    }
    if ch(text, close + 1) == '(' {
      if inline_destination(text, close + 2) is Some((ds, de, end)) {
        found.push({ inline: true, destination: unescape(sub(text, ds, de)), start, end })
        i += 1
        continue
      }
    }
    let mut label = sub(text, i + 1, close)
    if ch(text, close + 1) == '[' {
      let mut e = close + 2
      while e < text.length() && ch(text, e) != ']' {
        e += 1
      }
      if e < text.length() && e > close + 2 {
        label = sub(text, close + 2, e)
      }
    }
    if definitions.get(label_key(label)) is Some(destination) {
      found.push({ inline: false, destination, start, end: close + 1 })
    }
    i += 1
  }
  // Autolinks naming a file: <file:///…> (/<(file:[^\s<>]*)>/g)
  let mut a = 0
  while a < text.length() {
    if ch(text, a) == '<' && sub(text, a + 1, a + 6) == "file:" {
      let mut e = a + 6
      while e < text.length() && !js_space(ch(text, e)) && ch(text, e) != '<' && ch(text, e) != '>' {
        e += 1
      }
      if ch(text, e) == '>' {
        let at = a
        if !in_code(at) && !found.iter().any(f => at >= f.start && at < f.end) {
          found.push({ inline: false, destination: sub(text, a + 1, e), start: a, end: e + 1 })
        }
        a = e + 1
        continue
      }
    }
    a += 1
  }
  found.sort_by((x, y) => x.start - y.start)
  found
}

///|
/// `C:\…` or `C:/…`: a path on a Windows drive.
fn is_drive_path(text : String) -> Bool {
  let c = ch(text, 0)
  text.length() >= 3 &&
  ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) &&
  ch(text, 1) == ':' &&
  (ch(text, 2) == '\\' || ch(text, 2) == '/')
}

///|
/// url's `to_file_path` of a file: URL (as Node's fileURLToPath of `new URL(…)`): None where it names no local file.
fn file_url_path(url : String, windows : Bool) -> String? {
  let rest = sub(url, 5, url.length())
  let (host, path) = if rest.has_prefix("//") {
    let after = sub(rest, 2, rest.length())
    let mut k = 0
    while k < after.length() && ch(after, k) != '/' && ch(after, k) != '?' && ch(after, k) != '#' {
      k += 1
    }
    (sub(after, 0, k), sub(after, k, after.length()))
  } else {
    ("", rest)
  }
  // (a query or a fragment is no part of the path)
  let mut cut = path.length()
  for k = 0; k < path.length(); k = k + 1 {
    if ch(path, k) == '?' || ch(path, k) == '#' {
      cut = k
      break
    }
  }
  let path = sub(path, 0, cut)
  if !windows {
    guard host == "" || host.to_lower() == "localhost" else { None }
    guard path.has_prefix("/") else { None }
    guard !path.contains("%2F") && !path.contains("%2f") else { None }
    Some(percent_decode(path))
  } else {
    let decoded = percent_decode(path)
    if host != "" && host.to_lower() != "localhost" {
      return Some("\\\\\{host}\{decoded.replace_all(old="/", new="\\")}")
    }
    // /C:/x → C:\x
    let p = if decoded.has_prefix("/") { sub(decoded, 1, decoded.length()) } else { decoded }
    guard is_drive_path(p) || (p.length() == 2 && ch(p, 1) == ':') else { None }
    Some(p.replace_all(old="/", new="\\"))
  }
}

///|
/// Resolve only file URLs, familiar machine roots, or paths that actually name a local file.
fn local_path(w : LinkWorld, destination : String) -> String? raise LinkRefused {
  let windows = w.sep == "\\"
  let decoded = percent_decode(destination)
  let path = if destination.has_prefix("file:") {
    match file_url_path(destination, windows) {
      Some(p) => p
      None => raise LinkRefused("invalid local file link: \{destination}; use an absolute path in files")
    }
  } else if windows && is_drive_path(decoded) {
    decoded
  } else {
    if !decoded.has_prefix("/") || decoded.has_prefix("//") {
      return None
    }
    let known = [
      "/Users/", "/home/", "/tmp/", "/private/", "/var/", "/Volumes/", "/mnt/", "/workspace/", "/etc/", "/opt/",
    ]
    if !known.iter().any(r => decoded.has_prefix(r)) && !(w.is_file)(decoded) {
      return None
    }
    decoded
  }
  if (w.is_file)(path) {
    return Some(path)
  }
  let mut base = path
  for _ in 0..<2 {
    let mut at = -1
    for k = base.length() - 1; k >= 0; k = k - 1 {
      if ch(base, k) == ':' {
        at = k
        break
      }
    }
    if at < 0 {
      break
    }
    let tail = sub(base, at + 1, base.length())
    if tail == "" || !tail.iter().all(c => c >= '0' && c <= '9') {
      break
    }
    base = sub(base, 0, at)
    if (w.is_file)(base) {
      return Some(base)
    }
  }
  raise LinkRefused(
    "local file link does not name a readable file: \{destination}; correct the path or write it as code instead of a link",
  )
}

///|
/// A destination with no scheme that is neither from a root nor a fragment or a query: a path where the agent works.
fn is_relative(destination : String) -> Bool {
  guard destination != "" else { false }
  let first = ch(destination, 0)
  if first == '/' || first == '\\' || first == '#' || first == '?' {
    return false
  }
  // a scheme: /^[A-Za-z][A-Za-z0-9+.-]*:/
  if (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z') {
    let mut k = 1
    while k < destination.length() {
      let c = ch(destination, k)
      if c == ':' {
        return false
      }
      if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '+' || c == '.' || c == '-') {
        break
      }
      k += 1
    }
  }
  true
}

///|
/// Rust's `Path::join`: `path` where it is absolute, else after `base` and a separator, nothing made normal.
fn joined(w : LinkWorld, base : String, path : String) -> String {
  if @nodepath.is_absolute(w.sep, path) || (w.sep == "\\" && is_drive_path(path)) {
    path
  } else if base == "" || base.has_suffix("/") || (w.sep == "\\" && base.has_suffix("\\")) {
    base + path
  } else {
    base + w.sep + path
  }
}

///|
/// A relative link's file: none when it names one of the message's files, else the one it names in the workspace.
fn in_workspace(w : LinkWorld, destination : String, paths : Array[String], workspace : String) -> String? raise LinkRefused {
  let decoded = percent_decode(destination)
  let mut slash = -1
  for k = decoded.length() - 1; k >= 0; k = k - 1 {
    if ch(decoded, k) == '/' {
      slash = k
      break
    }
  }
  let name = sub(decoded, slash + 1, decoded.length())
  if paths.iter().any(p => @nodepath.basename(w.sep, p) == name) {
    return None
  }
  let path = joined(w, workspace, decoded)
  if (w.is_file)(path) {
    return Some(path)
  }
  raise LinkRefused(
    "local file link \{destination} names no file in the workspace (\{workspace}) nor one of the message's files; give its absolute path or attach it with files, use a full URL (https://…), or write it as code",
  )
}

///|
/// local.rs `prepare_local_links`: `text` with its local links made to name the message's attachments, and those
/// (`paths` with the files they name added).
pub fn prepare_local_links(
  w : LinkWorld,
  text : String,
  paths : Array[String],
  workspace : String,
) -> (String, Array[String]) raise LinkRefused {
  let paths = paths.copy()
  let replacements : Array[(Int, Int, String)] = []
  for link in links(text) {
    let path = match local_path(w, link.destination) {
      Some(p) => p
      None =>
        if is_relative(link.destination) {
          match in_workspace(w, link.destination, paths, workspace) {
            Some(p) => p
            None => continue
          }
        } else {
          continue
        }
    }
    if !link.inline {
      raise LinkRefused(
        "local file link \{link.destination} must use inline Markdown: [label](path); it will be attached automatically",
      )
    }
    let source = sub(text, link.start, link.end)
    let dest = link.destination
    let mut start = -1
    let mut at = source.length() - dest.length()
    while at >= 0 {
      if sub(source, at, at + dest.length()) == dest {
        let mut before = trim_end_js(sub(source, 0, at))
        let mut n = before.length()
        while n > 0 && ch(before, n - 1) == '<' {
          n -= 1
        }
        before = trim_end_js(sub(before, 0, n))
        if before.has_suffix("](") {
          start = at
          break
        }
      }
      at -= 1
    }
    if start < 0 {
      raise LinkRefused(
        "write local file link \{dest} without Markdown escapes (use <…> around paths with spaces)",
      )
    }
    guard (w.realpath)(path) is Some(real) else { raise LinkRefused("no such file: \{path}") }
    if !paths.iter().any(p => (w.realpath)(joined(w, workspace, p)) == Some(real)) {
      paths.push(path)
    }
    let name = percent_encode(@nodepath.basename(w.sep, path))
    replacements.push((link.start + start, link.start + start + dest.length(), name))
  }
  let names : Map[String, String] = Map([])
  for p in paths {
    let path = joined(w, workspace, p)
    guard (w.realpath)(path) is Some(real) else { raise LinkRefused("no such file: \{path}") }
    let name = @nodepath.basename(w.sep, path)
    if name == "" {
      continue
    }
    let previous = names.get(name)
    names[name] = real
    if previous is Some(prev) && prev != real {
      raise LinkRefused("attachments have the same name: \{name}; rename the files before posting")
    }
  }
  replacements.sort_by((a, b) => a.0 - b.0)
  let mut result = text
  for k = replacements.length() - 1; k >= 0; k = k - 1 {
    let (from, to, name) = replacements[k]
    result = sub(result, 0, from) + name + sub(result, to, result.length())
  }
  (result, paths)
}
