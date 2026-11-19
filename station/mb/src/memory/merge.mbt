// Two versions of one file of the agents' memory made apart, put together (station/src/share/memory.ts, which asks
// this program as `--builder memory`): what each station of a workspace computes alike from the same two, so they
// come to one without a station to decide. Line for line what the TypeScript of before computed
// (station/test/reference/memory-merge.ts), which station/test/mb-memory-merge.test.ts holds it to byte for byte: its
// strings are JavaScript's (UTF-16 code units, compared and cut as such), its regular expressions' classes as V8 has
// them (`\s` and `trim` JavaScript's white space and line ends, `\p{L}\p{N}` this package's tables.mbt).
//
// - With the version both were made from (`base`): a three-way merge by lines, as `git merge-file` makes one, where a
//   place both changed keeps both, the newer's lines first (git's `union`).
// - Without one: MEMORY.md's lines both, each once, a line only one of them had marked with that station's name
//   (`[ccvm] `); another file is the newer's, the other kept beside it (`conflict_path`).

///|
/// The most lines a side of a merge may have past what the two share at their start and end: beyond it no merge is
/// tried (memory-merge.ts MOST_LINES).
let most_lines = 3000

///|
/// Whether `bytes` are text a merge by lines may read: UTF-8 with no NUL, as
/// `Buffer.from(bytes.toString("utf8"), "utf8").equals(bytes)` says it (no surrogate, no longer form than needed, no
/// sequence cut short, nothing past U+10FFFF: each would come back as U+FFFD's bytes).
pub fn is_text(bytes : BytesView) -> Bool {
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b = bytes[i].to_int()
    if b == 0 {
      return false
    }
    if b < 0x80 {
      i += 1
      continue
    }
    let (len, lo, hi) = if b >= 0xc2 && b <= 0xdf {
      (2, 0x80, 0xbf)
    } else if b == 0xe0 {
      (3, 0xa0, 0xbf)
    } else if (b >= 0xe1 && b <= 0xec) || b == 0xee || b == 0xef {
      (3, 0x80, 0xbf)
    } else if b == 0xed {
      (3, 0x80, 0x9f)
    } else if b == 0xf0 {
      (4, 0x90, 0xbf)
    } else if b >= 0xf1 && b <= 0xf3 {
      (4, 0x80, 0xbf)
    } else if b == 0xf4 {
      (4, 0x80, 0x8f)
    } else {
      return false
    }
    if i + len > n {
      return false
    }
    let first = bytes[i + 1].to_int()
    if first < lo || first > hi {
      return false
    }
    for k = 2; k < len; k = k + 1 {
      let c = bytes[i + k].to_int()
      if c < 0x80 || c > 0xbf {
        return false
      }
    }
    i += len
  }
  true
}

///|
/// `bytes` as Buffer.toString("utf8") reads them: what is not UTF-8 replaced (each maximal part by one U+FFFD), a
/// byte order mark kept.
pub fn text_of(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}

///|
/// `s.split("\n")`: "" is [""].
pub fn lines_of(s : String) -> Array[String] {
  let out = []
  let mut from = 0
  for i = 0; i < s.length(); i = i + 1 {
    if s[i] == '\n' {
      out.push(s.unsafe_substring(start=from, end=i))
      from = i + 1
    }
  }
  out.push(s.unsafe_substring(start=from, end=s.length()))
  out
}

///|
/// `lines.join("\n")`.
fn joined(lines : Array[String]) -> String {
  let sb = StringBuilder()
  for i, line in lines {
    if i > 0 {
      sb.write_char('\n')
    }
    sb.write_string(line)
  }
  sb.to_string()
}

///|
/// Whether code unit `c` is JavaScript's white space or a line's end (`\s`, what `trim` takes off).
fn js_space(c : Int) -> Bool {
  @jsjson.is_js_space(c)
}

///|
/// `s.trim()`.
fn js_trim(s : String) -> String {
  @jsjson.trim_js(s)
}

///|
/// `s.trimStart()`.
fn js_trim_start(s : String) -> String {
  let mut start = 0
  while start < s.length() && js_space(s[start].to_int()) {
    start += 1
  }
  s.unsafe_substring(start~, end=s.length())
}

///|
/// Whether `a > b` as JavaScript compares strings: by their code units, the shorter first where one begins the other
/// (MoonBit's own compares their lengths first).
pub fn js_after(a : String, b : String) -> Bool {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i = 0; i < n; i = i + 1 {
    let x = a[i]
    let y = b[i]
    if x != y {
      return x > y
    }
  }
  a.length() > b.length()
}

///|
/// The pairs of lines `a` and `b` have alike (indexes, both rising), a longest such sequence; None when the lines that
/// differ are too many to compare (memory-merge.ts `matches`: its ties broken as it breaks them, so that every station
/// comes to the same pairs).
pub fn matches(a : Array[String], b : Array[String]) -> Array[(Int, Int)]? {
  let mut start = 0
  while start < a.length() && start < b.length() && a[start] == b[start] {
    start += 1
  }
  let mut end_a = a.length()
  let mut end_b = b.length()
  while end_a > start && end_b > start && a[end_a - 1] == b[end_b - 1] {
    end_a -= 1
    end_b -= 1
  }
  let n = end_a - start
  let m = end_b - start
  if n > most_lines || m > most_lines {
    return None
  }
  let out = []
  for i = 0; i < start; i = i + 1 {
    out.push((i, i))
  }
  if n > 0 && m > 0 {
    // Each line of the part between made a number, alike lines the same one: compared as numbers.
    let ids : Map[String, Int] = Map([])
    let id = fn(line : String) -> Int {
      match ids.get(line) {
        Some(k) => k
        None => {
          let k = ids.length()
          ids[line] = k
          k
        }
      }
    }
    let xa = FixedArray::make(n, 0)
    for i = 0; i < n; i = i + 1 {
      xa[i] = id(a[start + i])
    }
    let xb = FixedArray::make(m, 0)
    for j = 0; j < m; j = j + 1 {
      xb[j] = id(b[start + j])
    }
    // lcs[i][j]: the longest of a[start+i..end_a) and b[start+j..end_b).
    let width = m + 1
    let lcs : FixedArray[UInt16] = FixedArray::make((n + 1) * width, 0)
    for i = n - 1; i >= 0; i = i - 1 {
      for j = m - 1; j >= 0; j = j - 1 {
        lcs[i * width + j] = if xa[i] == xb[j] {
          lcs[(i + 1) * width + j + 1] + 1
        } else {
          let down = lcs[(i + 1) * width + j]
          let right = lcs[i * width + j + 1]
          if down >= right {
            down
          } else {
            right
          }
        }
      }
    }
    let mut i = 0
    let mut j = 0
    while i < n && j < m {
      if xa[i] == xb[j] {
        out.push((start + i, start + j))
        i += 1
        j += 1
      } else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
  }
  for k = 0; end_a + k < a.length(); k = k + 1 {
    out.push((end_a + k, end_b + k))
  }
  Some(out)
}

///|
/// Whether `xs[a..ea)` and `ys[b..eb)` are the same lines.
fn same(xs : Array[String], a : Int, ea : Int, ys : Array[String], b : Int, eb : Int) -> Bool {
  if ea - a != eb - b {
    return false
  }
  for k = 0; a + k < ea; k = k + 1 {
    if xs[a + k] != ys[b + k] {
      return false
    }
  }
  true
}

///|
/// `newer` and `older` made from `base`, merged by lines: what one changed and the other did not is taken, a place both
/// changed apart keeps both, the newer's first. None when they are too far apart to compare.
pub fn merge3(base : String, newer : String, older : String) -> String? {
  let b = lines_of(base)
  let w = lines_of(newer)
  let l = lines_of(older)
  guard matches(b, w) is Some(bw) else { return None }
  guard matches(b, l) is Some(bl) else { return None }
  let in_w : Map[Int, Int] = Map([])
  for p in bw {
    in_w[p.0] = p.1
  }
  let in_l : Map[Int, Int] = Map([])
  for p in bl {
    in_l[p.0] = p.1
  }
  let out = []
  let mut pb = 0
  let mut pw = 0
  let mut pl = 0
  let chunk = fn(eb : Int, ew : Int, el : Int) {
    let push = fn(xs : Array[String], from : Int, to : Int) {
      for k = from; k < to; k = k + 1 {
        out.push(xs[k])
      }
    }
    if same(w, pw, ew, b, pb, eb) {
      push(l, pl, el)
    } else if same(l, pl, el, b, pb, eb) || same(w, pw, ew, l, pl, el) {
      push(w, pw, ew)
    } else {
      push(w, pw, ew)
      push(l, pl, el)
    }
  }
  for i = 0; i < b.length(); i = i + 1 {
    guard in_w.get(i) is Some(iw) && in_l.get(i) is Some(il) else { continue }
    if iw < pw || il < pl {
      continue
    }
    chunk(i, iw, il)
    out.push(b[i])
    pb = i + 1
    pw = iw + 1
    pl = il + 1
  }
  chunk(b.length(), w.length(), l.length())
  Some(joined(out))
}

///|
/// Where `line`'s lead ends: `/^(\s*(?:[-*+]|\d+\.)\s+|)/`'s match, a bullet's or a number's and the space after it (0:
/// none).
fn lead_of(line : String) -> Int {
  let n = line.length()
  let mut i = 0
  while i < n && js_space(line[i].to_int()) {
    i += 1
  }
  if i >= n {
    return 0
  }
  let c = line[i].to_int()
  let mut j = i
  if c == '-' || c == '*' || c == '+' {
    j = i + 1
  } else if c >= '0' && c <= '9' {
    while j < n && line[j].to_int() >= '0' && line[j].to_int() <= '9' {
      j += 1
    }
    if j >= n || line[j] != '.' {
      return 0
    }
    j += 1
  } else {
    return 0
  }
  let mut k = j
  while k < n && js_space(line[k].to_int()) {
    k += 1
  }
  if k == j {
    0
  } else {
    k
  }
}

///|
/// Where `[<station>] ` at `at` of `line` ends (`\[[^\]\n]{1,80}\] `), if it is there.
fn tag_end(line : String, at : Int) -> Int? {
  let n = line.length()
  if at >= n || line[at] != '[' {
    return None
  }
  let mut q = at + 1
  while q < n && line[q] != ']' && line[q] != '\n' {
    q += 1
  }
  let len = q - at - 1
  if len < 1 || len > 80 || q + 1 >= n || line[q] != ']' || line[q + 1] != ' ' {
    return None
  }
  Some(q + 2)
}

///|
/// A bullet's or a line's mark of the station it came from (memory-merge.ts MARK, `- [ccvm] …`): where its lead
/// ends and where the mark does.
fn mark_of(line : String) -> (Int, Int)? {
  let lead = lead_of(line)
  if lead > 0 {
    if tag_end(line, lead) is Some(end) {
      return Some((lead, end))
    }
  }
  match tag_end(line, 0) {
    Some(end) => Some((0, end))
    None => None
  }
}

///|
/// `line` without its station's mark.
fn unmarked(line : String) -> String {
  match mark_of(line) {
    Some((lead, end)) => line.unsafe_substring(start=0, end=lead) + line.unsafe_substring(start=end, end=line.length())
    None => line
  }
}

///|
/// A line worth marking: one that says something (not blank, not a heading, not the front matter's fence).
fn says(line : String) -> Bool {
  let t = js_trim(line)
  t != "" && !js_trim_start(line).has_prefix("#") && t != "---"
}

///|
/// `line` marked as `station`'s, unless it says nothing or is marked already.
fn marked(line : String, station : String) -> String {
  if !says(line) || unmarked(line) != line {
    return line
  }
  let lead = lead_of(line)
  line.unsafe_substring(start=0, end=lead) +
  "[" +
  station +
  "] " +
  line.unsafe_substring(start=lead, end=line.length())
}

///|
/// Two MEMORY.md kept apart (no version both were made from) as one: their lines in the newer's order, the other's
/// woven in after the line before them there, each line once. A line only one had is marked with that one's station
/// (`newer_name`, `older_name`; None: not marked).
pub fn union_lines(newer : String, older : String, newer_name : String?, older_name : String?) -> String {
  let w = lines_of(newer)
  let l = lines_of(older)
  let pairs = matches(w.map(unmarked), l.map(unmarked)).unwrap_or([])
  let out = []
  let mut pw = 0
  let mut pl = 0
  let take = fn(ew : Int, el : Int) {
    for k = pw; k < ew; k = k + 1 {
      out.push(
        match newer_name {
          Some(name) => marked(w[k], name)
          None => w[k]
        },
      )
    }
    for k = pl; k < el; k = k + 1 {
      out.push(
        match older_name {
          Some(name) => marked(l[k], name)
          None => l[k]
        },
      )
    }
  }
  for p in pairs {
    let (iw, il) = p
    take(iw, il)
    // Had by both: no station's alone, so unmarked.
    out.push(unmarked(w[iw]))
    pw = iw + 1
    pl = il + 1
  }
  take(w.length(), l.length())
  joined(out)
}

///|
/// Whether code point `c` is a letter or a digit of any script (`\p{L}\p{N}`).
fn word_char(c : Int) -> Bool {
  let mut lo = 0
  let mut hi = word_ranges.length() / 2
  while lo < hi {
    let mid = (lo + hi) / 2
    if c < word_ranges[mid * 2] {
      hi = mid
    } else if c > word_ranges[mid * 2 + 1] {
      lo = mid + 1
    } else {
      return true
    }
  }
  false
}

///|
/// A station's name as a part of a file's or a skill's name: letters, digits, `_` and `-` alone (memory-merge.ts
/// `stationTag`: each run of anything else one `-`, none at either end, 40 code units at most, "station" for none).
pub fn station_tag(station : String) -> String {
  let sb = StringBuilder()
  let n = station.length()
  let mut i = 0
  let mut run = false
  while i < n {
    let c = station[i].to_int()
    let (cp, len) = if c >= 0xd800 &&
      c <= 0xdbff &&
      i + 1 < n &&
      station[i + 1].to_int() >= 0xdc00 &&
      station[i + 1].to_int() <= 0xdfff {
      (((c - 0xd800) << 10) + (station[i + 1].to_int() - 0xdc00) + 0x10000, 2)
    } else {
      (c, 1)
    }
    // (a surrogate alone is no letter)
    let kept = cp == '_' || cp == '-' || (!(cp >= 0xd800 && cp <= 0xdfff) && word_char(cp))
    if kept {
      sb.write_string(station.unsafe_substring(start=i, end=i + len))
      run = false
    } else if !run {
      sb.write_char('-')
      run = true
    }
    i += len
  }
  let s = sb.to_string()
  let mut start = 0
  let mut end = s.length()
  while start < end && s[start] == '-' {
    start += 1
  }
  while end > start && s[end - 1] == '-' {
    end -= 1
  }
  if end - start > 40 {
    end = start + 40
  }
  let tag = s.unsafe_substring(start~, end~)
  if tag == "" {
    "station"
  } else {
    tag
  }
}

///|
/// Where a station's version of `path` is kept beside it when it could not be merged: `SKILL.md` →
/// `SKILL.conflict-<station>.md`.
pub fn conflict_path(path : String, station : String) -> String {
  let slash = match path.rev_find("/") {
    Some(k) => k
    None => -1
  }
  let dir = path.unsafe_substring(start=0, end=slash + 1)
  let name = path.unsafe_substring(start=slash + 1, end=path.length())
  let dot = match name.rev_find(".") {
    Some(k) => k
    None => -1
  }
  let tag = station_tag(station)
  if dot > 0 {
    "\{dir}\{name.unsafe_substring(start=0, end=dot)}.conflict-\{tag}\{name.unsafe_substring(start=dot, end=name.length())}"
  } else {
    "\{dir}\{name}.conflict-\{tag}"
  }
}

///|
/// Where `text`'s front matter ends (`/^---\n[\s\S]*?\n---/`: the first `\n---` after its opening fence), the
/// index past its closing `---`, and what it holds; None where it has none.
fn front_of(text : String) -> (Int, String)? {
  if !text.has_prefix("---\n") {
    return None
  }
  let n = text.length()
  for k = 4; k + 4 <= n; k = k + 1 {
    if text[k] == '\n' && text[k + 1] == '-' && text[k + 2] == '-' && text[k + 3] == '-' {
      return Some((k + 4, text.unsafe_substring(start=4, end=k)))
    }
  }
  None
}

///|
/// `text` past its front matter (`/^---\n[\s\S]*?\n---\n?/` taken off).
pub fn body_of(text : String) -> String {
  match front_of(text) {
    Some((end, _)) => {
      let past = if end < text.length() && text[end] == '\n' { end + 1 } else { end }
      text.unsafe_substring(start=past, end=text.length())
    }
    None => text
  }
}

///|
/// Whether two versions made apart with none both came from are of one file still (a skill two stations each kept on):
/// half the lines of the shorter, at least, the other has too, in order, past their front matter.
pub fn alike(a : String, b : String) -> Bool {
  let la = lines_of(body_of(a))
  let lb = lines_of(body_of(b))
  guard matches(la, lb) is Some(pairs) else { return false }
  let mut said = 0
  for p in pairs {
    if js_trim(la[p.0]) != "" {
      said += 1
    }
  }
  let count = fn(xs : Array[String]) {
    let mut k = 0
    for x in xs {
      if js_trim(x) != "" {
        k += 1
      }
    }
    k
  }
  let ca = count(la)
  let cb = count(lb)
  let least = if ca < cb { ca } else { cb }
  least > 0 && said * 2 >= least
}

///|
/// What `#mend` reads of a skill kept apart (station/src/share/memory.ts): the station `[<name>] ` its front matter's
/// description says it is of, when that front matter names it `skill` too.
pub fn aside_of(text : String, skill : String) -> String? {
  guard front_of(text) is Some((_, front)) else { return None }
  // /^description: \[([^\]\n]{1,80})\] /m: at the start or after a line's end (\n, \r, U+2028, U+2029).
  let n = front.length()
  let mut said : String? = None
  for p = 0; p < n; p = p + 1 {
    if p > 0 {
      let c = front[p - 1].to_int()
      if c != '\n' && c != '\r' && c != 0x2028 && c != 0x2029 {
        continue
      }
    }
    if !front.unsafe_substring(start=p, end=n).has_prefix("description: ") {
      continue
    }
    match tag_end(front, p + 13) {
      Some(end) => {
        said = Some(front.unsafe_substring(start=p + 14, end=end - 2))
        break
      }
      None => continue
    }
  }
  guard said is Some(name) else { return None }
  if !lines_of(front).contains("name: \{skill}") {
    return None
  }
  Some(name)
}
