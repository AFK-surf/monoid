// Local Markdown destinations are files to deliver, not routes on the web client (station/src/sessions/local-links.ts):
// what pulldown-cmark finds of links, read as the TypeScript reads it: inline links and images (`[x](d)`, `![x](d)`,
// `<…>` destinations, nested ones), outside code spans and fenced code blocks, and reference links, for what is read
// of a link by its name alone (`named_local_paths`). What is posted is prepared by the station's native reading
// (`prepare`, native/mesh/src/local.rs), which the station gives.

///|
pub struct Found {
  inline : Bool
  destination : String
  start : Int
  end : Int
} derive(Eq, Show)

///|
pub fn Found::to_j(self : Found) -> J {
  jo([("inline", jb(self.inline)), ("destination", js(self.destination)), ("start", ji(self.start)), ("end", ji(self.end))])
}

///|
/// percent_decode_str(..).decode_utf8_lossy().
pub fn percent_decode(text : String) -> String {
  let decoded = @url.percent_decode_lossy(text)
  // TextDecoder takes a leading BOM away.
  if decoded.has_prefix("\u{feff}") {
    decoded.unsafe_substring(start=1, end=decoded.length())
  } else {
    decoded
  }
}

///|
fn is_punct(c : Int) -> Bool {
  "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains_char(c.unsafe_to_char())
}

///|
fn line_end(c : Int) -> Bool {
  c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029
}

///|
/// A destination as pulldown-cmark gives it: backslash escapes of punctuation resolved.
fn unescape(raw : String) -> String {
  let out = StringBuilder::new()
  let mut i = 0
  while i < raw.length() {
    let c = raw.unsafe_charcode_at(i)
    if c == '\\' && i + 1 < raw.length() && !line_end(raw.unsafe_charcode_at(i + 1)) {
      let d = raw.unsafe_charcode_at(i + 1)
      if !is_punct(d) {
        out.write_char('\\')
      }
      out.write_char(d.unsafe_to_char())
      i += 2
      continue
    }
    out.write_char(c.unsafe_to_char())
    i += 1
  }
  out.to_string()
}

///|
fn code_at(text : String, i : Int) -> Int {
  if i >= 0 && i < text.length() {
    text.unsafe_charcode_at(i)
  } else {
    -1
  }
}

///|
/// `/^ {0,3}(`{3,}|~{3,})/` on a line: (the whole of it, the fence).
fn fence_of(line : String) -> (Int, String)? {
  let mut i = 0
  while i < 3 && code_at(line, i) == ' ' {
    i += 1
  }
  let c = code_at(line, i)
  if c != '`' && c != '~' {
    return None
  }
  let mut j = i
  while code_at(line, j) == c {
    j += 1
  }
  if j - i < 3 {
    return None
  }
  Some((j, slice(line, i, b=j)))
}

///|
/// Where code is (fenced blocks and code spans), as [start, end) ranges.
fn code_ranges(text : String) -> Array[(Int, Int)] {
  let ranges = []
  let lines = split(text, "\n")
  let mut at_ = 0
  let mut open : (Int, String)? = None
  for line in lines {
    let fence = fence_of(line)
    match (open, fence) {
      (None, Some((whole, f))) =>
        if !(code_at(f, 0) == '`' && slice(line, whole).contains("`")) {
          open = Some((at_, f))
        }
      (Some((start, of)), Some((whole, f))) =>
        if code_at(f, 0) == code_at(of, 0) && f.length() >= of.length() && trim(slice(line, whole)) == "" {
          ranges.push((start, at_ + line.length()))
          open = None
        }
      _ => ()
    }
    at_ += line.length() + 1
  }
  if open is Some((start, _)) {
    ranges.push((start, text.length()))
  }
  let in_block = (i : Int) => ranges.iter().any(r => i >= r.0 && i < r.1)
  let spans = []
  let mut i = 0
  while i < text.length() {
    if code_at(text, i) == '\\' {
      i += 2
      continue
    }
    if code_at(text, i) != '`' || in_block(i) {
      i += 1
      continue
    }
    let mut n = 0
    while code_at(text, i + n) == '`' {
      n += 1
    }
    let run = String::make(n, '`')
    let mut close = -1
    let mut j = i + n
    while j < text.length() {
      let k = index_of(text, run, from=j)
      if k < 0 {
        break
      }
      let mut m = 0
      while code_at(text, k + m) == '`' {
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
fn closing(text : String, open : Int, code : (Int) -> Bool) -> Int {
  let mut depth = 0
  let mut i = open
  while i < text.length() {
    if code_at(text, i) == '\\' {
      i += 2
      continue
    }
    if code(i) {
      i += 1
      continue
    }
    if code_at(text, i) == '[' {
      depth += 1
    } else if code_at(text, i) == ']' {
      depth -= 1
      if depth == 0 {
        return i
      }
    }
    i += 1
  }
  -1
}

///|
fn sp(c : Int) -> Bool {
  c == ' ' || c == '\t' || c == '\n'
}

///|
fn inline_destination(text : String, at_ : Int) -> (Int, Int, Int)? {
  let len = text.length()
  let mut i = at_
  while sp(code_at(text, i)) {
    i += 1
  }
  let mut start = 0
  let mut end = 0
  if code_at(text, i) == '<' {
    start = i + 1
    let mut j = start
    while j < len && code_at(text, j) != '>' && code_at(text, j) != '\n' && code_at(text, j) != '<' {
      j += if code_at(text, j) == '\\' { 2 } else { 1 }
    }
    if code_at(text, j) != '>' {
      return None
    }
    end = j
    i = j + 1
  } else {
    start = i
    let mut depth = 0
    let mut j = i
    while j < len {
      let c = code_at(text, j)
      if c == '\\' {
        j += 2
        continue
      }
      if is_js_space(c) {
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
    end = j
    i = j
  }
  while sp(code_at(text, i)) {
    i += 1
  }
  let quote = code_at(text, i)
  if quote == '"' || quote == '\'' || quote == '(' {
    let shut : Int = if quote == '(' { ')' } else { quote }
    let mut j = i + 1
    while j < len && code_at(text, j) != shut {
      j += if code_at(text, j) == '\\' { 2 } else { 1 }
    }
    if code_at(text, j) != shut {
      return None
    }
    i = j + 1
    while sp(code_at(text, i)) {
      i += 1
    }
  }
  if code_at(text, i) == ')' {
    Some((start, end, i + 1))
  } else {
    None
  }
}

///|
fn label_key(label : String) -> String {
  lower(trim(label)) |> @jscase.split_by(is_js_space) |> join_spaces
}

///|
fn join_spaces(parts : Array[String]) -> String {
  parts.join(" ")
}

///|
/// The reference definitions of `text` (`[label]: destination` at a line's start, outside code): by label, and
/// where each is.
fn definitions_of(text : String, in_code : (Int) -> Bool) -> (Map[String, String], Array[(Int, Int)]) {
  let defs : Map[String, String] = {}
  let defined = []
  let len = text.length()
  let mut last_end = 0
  let mut p = 0
  while p <= len {
    let line_start = p == 0 || line_end(code_at(text, p - 1))
    if p >= last_end && line_start {
      match definition_at(text, p) {
        Some((end, label, raw)) => {
          last_end = end
          if !in_code(p) {
            let key = label_key(label)
            if !defs.contains(key) {
              let inner = if starts(raw, "<") { slice(raw, 1, b=-1) } else { raw }
              defs[key] = unescape(inner)
            }
            defined.push((p, end))
          }
          p = end
          continue
        }
        None => ()
      }
    }
    p += 1
  }
  (defs, defined)
}

///|
/// `/^ {0,3}\[([^\]\n]+)\]:[ \t]*(<[^>\n]*>|\S+)[^\n]*$/m` at `p`: (its end, the label, the raw destination).
fn definition_at(text : String, p : Int) -> (Int, String, String)? {
  let len = text.length()
  let mut i = p
  let mut n = 0
  while n < 3 && code_at(text, i) == ' ' {
    i += 1
    n += 1
  }
  if code_at(text, i) != '[' {
    return None
  }
  let ls = i + 1
  let mut j = ls
  while j < len && code_at(text, j) != ']' && code_at(text, j) != '\n' {
    j += 1
  }
  if j == ls || code_at(text, j) != ']' || code_at(text, j + 1) != ':' {
    return None
  }
  let label = slice(text, ls, b=j)
  let mut k = j + 2
  while code_at(text, k) == ' ' || code_at(text, k) == '\t' {
    k += 1
  }
  let mut dest_end = -1
  if code_at(text, k) == '<' {
    let mut q = k + 1
    while q < len && code_at(text, q) != '>' && code_at(text, q) != '\n' {
      q += 1
    }
    if code_at(text, q) == '>' {
      dest_end = q + 1
    }
  }
  if dest_end < 0 {
    let mut q = k
    while q < len && !is_js_space(code_at(text, q)) {
      q += 1
    }
    if q == k {
      return None
    }
    dest_end = q
  }
  let raw = slice(text, k, b=dest_end)
  let mut e = dest_end
  while e < len && code_at(text, e) != '\n' {
    e += 1
  }
  Some((e, label, raw))
}

///|
/// The links and images Markdown finds in `text`, in order of where they start.
pub fn links(text : String) -> Array[Found] {
  let code = code_ranges(text)
  let in_code = (i : Int) => code.iter().any(r => i >= r.0 && i < r.1)
  let (definitions, defined) = definitions_of(text, in_code)
  let found : Array[Found] = []
  let mut i = 0
  while i < text.length() {
    if code_at(text, i) == '\\' {
      i += 2
      continue
    }
    if code_at(text, i) != '[' || in_code(i) || defined.iter().any(r => i >= r.0 && i < r.1) {
      i += 1
      continue
    }
    let start = if i > 0 && code_at(text, i - 1) == '!' && !(i > 1 && code_at(text, i - 2) == '\\') { i - 1 } else { i }
    let close = closing(text, i, in_code)
    if close < 0 {
      i += 1
      continue
    }
    if code_at(text, close + 1) == '(' {
      match inline_destination(text, close + 2) {
        Some((s, e, end)) => {
          found.push({ inline: true, destination: unescape(slice(text, s, b=e)), start, end })
          i += 1
          continue
        }
        None => ()
      }
    }
    let mut label = slice(text, i + 1, b=close)
    if code_at(text, close + 1) == '[' {
      let end = index_of(text, "]", from=close + 2)
      if end >= 0 && end > close + 2 {
        label = slice(text, close + 2, b=end)
      }
    }
    match definitions.get(label_key(label)) {
      Some(d) => found.push({ inline: false, destination: d, start, end: close + 1 })
      None => ()
    }
    i += 1
  }
  // Autolinks naming a file: <file:///…>.
  let mut p = 0
  while p < text.length() {
    let at_ = index_of(text, "<file:", from=p)
    if at_ < 0 {
      break
    }
    let mut q = at_ + 1
    while q < text.length() &&
      {
        let c = code_at(text, q)
        !is_js_space(c) && c != '<' && c != '>'
      } {
      q += 1
    }
    if code_at(text, q) == '>' {
      let i0 = at_
      if !in_code(i0) && !found.iter().any(f => i0 >= f.start && i0 < f.end) {
        found.push({ inline: false, destination: slice(text, at_ + 1, b=q), start: at_, end: q + 1 })
      }
      p = q + 1
    } else {
      p = at_ + 1
    }
  }
  // (stable: Array.prototype.sort)
  let indexed = found.mapi((k, f) => (k, f))
  indexed.sort_by((a, b) => if a.1.start != b.1.start { a.1.start - b.1.start } else { a.0 - b.0 })
  indexed.map(x => x.1)
}

///|
/// The local paths `text`'s links name (file URLs, absolute paths), read by name only, each with its destination as
/// the link has it. A file URL's path is the platform's reading of it (`fileURLToPath(new URL(…))`, None where that
/// throws), which the station gives.
pub async fn named_local_paths(w : World, text : String) -> Array[(String, String)] {
  let named = []
  for link in links(text) {
    let mut path : String? = None
    if starts(link.destination, "file:") {
      path = str_of(Some(w.dep("fileURLToPath", [js(link.destination)])))
    } else {
      let decoded = percent_decode(link.destination)
      if starts(decoded, "/") && !starts(decoded, "//") {
        path = Some(decoded)
      }
    }
    if path is Some(p) {
      named.push((link.destination, p))
    }
  }
  named
}

///|
/// Makes local links refer to the message's attachments, adding their files to `paths` (the station's native reading
/// of the Markdown, `prepareLocalLinks`): the text to post.
pub async fn prepare(w : World, text : String, paths : Array[String], workspace : String) -> String {
  let prepared = w.dep("prepareLocalLinks", [js(text), jsa(paths), js(workspace)])
  let given = arr_of(at(Some(prepared), "paths")).unwrap_or([])
  paths.clear()
  for p in given {
    paths.push(str_of(Some(p)).unwrap_or(""))
  }
  str_of(at(Some(prepared), "text")).unwrap_or("")
}
