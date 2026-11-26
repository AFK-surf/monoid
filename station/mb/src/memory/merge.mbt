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
/// Marks every line that opens, closes, or lies inside a CommonMark fenced code block (0-3 leading spaces + >= 3
/// repeated '`' or '~'; backtick opening fences forbid '`' in the info string; closing fences require matching char,
/// length >= opening, and only spaces/tabs/optional CR after).
fn fence_flags(lines : Array[String]) -> Array[Bool] {
  let flags : Array[Bool] = []
  let mut in_fence = false
  let mut fence_char = 0
  let mut fence_len = 0
  for line in lines {
    let n = line.length()
    let mut sp = 0
    while sp < n && line[sp] == ' ' {
      sp += 1
    }
    if !in_fence {
      if sp <= 3 && sp + 3 <= n && (line[sp] == '`' || line[sp] == '~') {
        let ch = line[sp].to_int()
        let mut run = 0
        while sp + run < n && line[sp + run].to_int() == ch {
          run += 1
        }
        if run >= 3 {
          let mut ok = true
          if ch == '`' {
            let mut end = n
            if end > sp + run && line[end - 1] == '\r' {
              end -= 1
            }
            for k = sp + run; k < end; k = k + 1 {
              if line[k] == '`' {
                ok = false
                break
              }
            }
          }
          if ok {
            in_fence = true
            fence_char = ch
            fence_len = run
            flags.push(true)
            continue
          }
        }
      }
      flags.push(false)
    } else {
      flags.push(true)
      if sp <= 3 && sp + fence_len <= n && line[sp].to_int() == fence_char {
        let mut run = 0
        while sp + run < n && line[sp + run].to_int() == fence_char {
          run += 1
        }
        if run >= fence_len {
          let mut end = n
          if end > sp + run && line[end - 1] == '\r' {
            end -= 1
          }
          let mut only_ws = true
          for k = sp + run; k < end; k = k + 1 {
            let c = line[k]
            if c != ' ' && c != '\t' {
              only_ws = false
              break
            }
          }
          if only_ws {
            in_fence = false
          }
        }
      }
    }
  }
  flags
}

///|
struct Hunk {
  bs : Int
  be : Int
  ss : Int
  se : Int
}

///|
fn extract_hunks(b_len : Int, s_len : Int, pairs : Array[(Int, Int)]) -> Array[Hunk] {
  let hunks : Array[Hunk] = []
  let mut pb = 0
  let mut ps = 0
  for p in pairs {
    let (bi, si) = p
    if pb < bi || ps < si {
      hunks.push({ bs: pb, be: bi, ss: ps, se: si })
    }
    pb = bi + 1
    ps = si + 1
  }
  if pb < b_len || ps < s_len {
    hunks.push({ bs: pb, be: b_len, ss: ps, se: s_len })
  }
  hunks
}

///|
fn hunks_overlap(a_bs : Int, a_be : Int, b_bs : Int, b_be : Int) -> Bool {
  if a_bs == a_be && b_bs == b_be {
    a_bs == b_bs
  } else {
    a_bs < b_be && b_bs < a_be
  }
}

///|
/// `newer` and `older` made from `base`, merged by lines using lossless hunk-based diff3: non-overlapping edits
/// (including adjacent edits) merge cleanly without reviving deleted lines; overlapping conflicts keep both sides
/// (newer first, once if identical) without dropping any lines. None when too far apart to compare.
pub fn merge3(base : String, newer : String, older : String) -> String? {
  let b = lines_of(base)
  let w = lines_of(newer)
  let l = lines_of(older)
  guard matches(b, w) is Some(bw) else { return None }
  guard matches(b, l) is Some(bl) else { return None }
  let wh = extract_hunks(b.length(), w.length(), bw)
  let lh = extract_hunks(b.length(), l.length(), bl)
  let out : Array[String] = []
  let push = fn(xs : Array[String], from : Int, to : Int) {
    for k = from; k < to; k = k + 1 {
      out.push(xs[k])
    }
  }
  let mut wi = 0
  let mut li = 0
  let mut pos = 0
  while wi < wh.length() || li < lh.length() {
    if li >= lh.length() {
      let h = wh[wi]
      push(b, pos, h.bs)
      push(w, h.ss, h.se)
      pos = h.be
      wi += 1
    } else if wi >= wh.length() {
      let h = lh[li]
      push(b, pos, h.bs)
      push(l, h.ss, h.se)
      pos = h.be
      li += 1
    } else {
      let hw = wh[wi]
      let hl = lh[li]
      if !hunks_overlap(hw.bs, hw.be, hl.bs, hl.be) {
        if hw.be <= hl.bs {
          push(b, pos, hw.bs)
          push(w, hw.ss, hw.se)
          pos = hw.be
          wi += 1
        } else {
          push(b, pos, hl.bs)
          push(l, hl.ss, hl.se)
          pos = hl.be
          li += 1
        }
      } else {
        let wi_start = wi
        let li_start = li
        let bs_min = if hw.bs < hl.bs { hw.bs } else { hl.bs }
        let mut be_max = if hw.be > hl.be { hw.be } else { hl.be }
        wi += 1
        li += 1
        let mut changed = true
        while changed {
          changed = false
          if wi < wh.length() && hunks_overlap(wh[wi].bs, wh[wi].be, bs_min, be_max) {
            if wh[wi].be > be_max {
              be_max = wh[wi].be
            }
            wi += 1
            changed = true
          }
          if li < lh.length() && hunks_overlap(lh[li].bs, lh[li].be, bs_min, be_max) {
            if lh[li].be > be_max {
              be_max = lh[li].be
            }
            li += 1
            changed = true
          }
        }
        push(b, pos, bs_min)
        let fw = wh[wi_start]
        let lw = wh[wi - 1]
        let w_lo = fw.ss - (fw.bs - bs_min)
        let w_hi = lw.se + (be_max - lw.be)
        let fl = lh[li_start]
        let ll = lh[li - 1]
        let l_lo = fl.ss - (fl.bs - bs_min)
        let l_hi = ll.se + (be_max - ll.be)
        if same(w, w_lo, w_hi, l, l_lo, l_hi) {
          push(w, w_lo, w_hi)
        } else {
          push(w, w_lo, w_hi)
          push(l, l_lo, l_hi)
        }
        pos = be_max
      }
    }
  }
  push(b, pos, b.length())
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
/// Where `[<station>] ` at `at` of `line` ends (`\[[^\]\n]{1,80}\] `), excluding Markdown task checkboxes (`[ ] `,
/// `[x] `, `[X] `), if it is there.
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
  if len == 1 {
    let ch = line[at + 1]
    if ch == ' ' || ch == 'x' || ch == 'X' {
      return None
    }
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
/// Two files kept apart (no version both were made from) as one: their lines in the newer's order, the other's woven in
/// after the line before them there, lossless across all file types (fenced lines untouched; shared non-fence lines on
/// `newer` unmarked even when reordered; `MEMORY.md` deduplication runs in `decide` via `dedup_memory_lines`).
pub fn union_lines(newer : String, older : String, newer_name : String?, older_name : String?) -> String {
  let w = lines_of(newer)
  let l = lines_of(older)
  let wu = w.map(unmarked)
  let lu = l.map(unmarked)
  let in_fence_w = fence_flags(w)
  let in_fence_l = fence_flags(l)
  let l_keys : Map[String, Bool] = Map([])
  for j = 0; j < l.length(); j = j + 1 {
    if !in_fence_l[j] && says(lu[j]) {
      l_keys[js_trim(lu[j])] = true
    }
  }
  let pairs = matches(wu, lu).unwrap_or([])
  let out : Array[String] = []
  let mut pw = 0
  let mut pl = 0
  let take = fn(ew : Int, el : Int) {
    for k = pw; k < ew; k = k + 1 {
      if in_fence_w[k] {
        out.push(w[k])
      } else if says(wu[k]) && l_keys.contains(js_trim(wu[k])) {
        out.push(wu[k])
      } else {
        out.push(
          match newer_name {
            Some(name) => marked(w[k], name)
            None => w[k]
          },
        )
      }
    }
    for k = pl; k < el; k = k + 1 {
      if in_fence_l[k] {
        out.push(l[k])
      } else if pairs.length() == 0 && w.length() > 0 && js_trim(lu[k]) == "" {
        let is_trailing_nl = k == l.length() - 1 && l[k] == ""
        if is_trailing_nl || out.length() == 0 || js_trim(out[out.length() - 1]) != "" {
          out.push(l[k])
        }
      } else {
        out.push(
          match older_name {
            Some(name) => marked(l[k], name)
            None => l[k]
          },
        )
      }
    }
  }
  for p in pairs {
    let (iw, il) = p
    take(iw, il)
    // Had by both: no station's alone, so unmarked unless inside a code fence.
    out.push(if in_fence_w[iw] { w[iw] } else { wu[iw] })
    pw = iw + 1
    pl = il + 1
  }
  take(w.length(), l.length())
  joined(out)
}

///|
fn is_thematic_break(line : String) -> Bool {
  let t = js_trim(line)
  let n = t.length()
  if n < 3 {
    return false
  }
  let ch = t[0]
  if ch != '-' && ch != '*' && ch != '_' {
    return false
  }
  let mut count = 0
  for i = 0; i < n; i = i + 1 {
    let c = t[i]
    if c == ch {
      count += 1
    } else if c != ' ' && c != '\t' {
      return false
    }
  }
  count >= 3
}

///|
fn is_table_line(u : String) -> Bool {
  let t = js_trim(u)
  let n = t.length()
  if n == 0 {
    return false
  }
  if t[0] == '|' {
    return true
  }
  let mut has_pipe = false
  for i = 0; i < n; i = i + 1 {
    let c = t[i]
    if c == '|' {
      has_pipe = true
    } else if c != '-' && c != ':' && c != ' ' && c != '\t' {
      return false
    }
  }
  has_pipe
}

///|
fn is_html_line(line : String) -> Bool {
  let t = js_trim_start(line)
  t.length() > 0 && t[0] == '<'
}

///|
fn is_indented_code(line : String) -> Bool {
  if js_trim(line) == "" || lead_of(line) > 0 {
    return false
  }
  let n = line.length()
  if n == 0 {
    return false
  }
  if line[0] == '\t' {
    return true
  }
  n >= 4 && line[0] == ' ' && line[1] == ' ' && line[2] == ' ' && line[3] == ' '
}

///|
fn heading_of(line : String) -> (Int, String)? {
  let t = js_trim(line)
  let n = t.length()
  if n == 0 || t[0] != '#' {
    return None
  }
  let mut level = 0
  while level < n && level < 7 && t[level] == '#' {
    level += 1
  }
  if level < 1 || level > 6 {
    return None
  }
  if level == n {
    return Some((level, t))
  }
  let next = t[level]
  if next == ' ' || next == '\t' {
    return Some((level, t))
  }
  None
}

///|
fn push_heading(stack : Array[(Int, String)], level : Int, ht : String) -> Unit {
  while stack.length() > 0 && stack[stack.length() - 1].0 >= level {
    let _ = stack.pop()
  }
  stack.push((level, ht))
}

///|
fn scope_path(stack : Array[(Int, String)]) -> String {
  if stack.length() == 0 {
    return ""
  }
  let sb = StringBuilder()
  for i = 0; i < stack.length(); i = i + 1 {
    if i > 0 {
      sb.write_char('\n')
    }
    sb.write_string(stack[i].1)
  }
  sb.to_string()
}

///|
/// Deterministic exact-line deduplication for merged `MEMORY.md` content. Scopes deduplication by Markdown heading path,
/// never modifies lines inside fenced code blocks or structural Markdown lines (tables, thematic breaks, HTML, indented
/// code), prefers unmarked copies when both marked and unmarked exist within a scope, drops duplicate heading subtrees
/// that contain no exempt structure and no unseen content, and collapses redundant blank lines left by dropped lines.
fn dedup_memory_lines(text : String) -> String {
  let had_trailing_nl = text.length() > 0 && text[text.length() - 1] == '\n'
  let lines = lines_of(text)
  let body_len = if had_trailing_nl { lines.length() - 1 } else { lines.length() }
  let in_fence = fence_flags(lines)
  let has_unmarked : Map[String, Bool] = Map([])
  let stack1 : Array[(Int, String)] = []
  for i = 0; i < body_len; i = i + 1 {
    if in_fence[i] || is_indented_code(lines[i]) || is_html_line(lines[i]) || is_thematic_break(lines[i]) {
      continue
    }
    match heading_of(lines[i]) {
      Some((lvl, ht)) => {
        push_heading(stack1, lvl, ht)
        continue
      }
      None => ()
    }
    let u = unmarked(lines[i])
    if is_table_line(u) {
      continue
    }
    if says(u) && u == lines[i] {
      has_unmarked[scope_path(stack1) + "\n" + js_trim(u)] = true
    }
  }
  let seen_content : Map[String, Bool] = Map([])
  let seen_heading_paths : Map[String, Bool] = Map([])
  let heading_stack : Array[(Int, String)] = []
  let out : Array[String] = []
  let mut dropped_since_last_kept = false
  for i = 0; i < body_len; i = i + 1 {
    if in_fence[i] || is_indented_code(lines[i]) || is_html_line(lines[i]) || is_thematic_break(lines[i]) {
      out.push(lines[i])
      dropped_since_last_kept = false
      continue
    }
    match heading_of(lines[i]) {
      Some((lvl, ht)) => {
        push_heading(heading_stack, lvl, ht)
        let path = scope_path(heading_stack)
        if seen_heading_paths.contains(path) {
          let sim_stack = heading_stack.copy()
          let mut has_new = false
          for j = i + 1; j < body_len; j = j + 1 {
            if in_fence[j] || is_indented_code(lines[j]) || is_html_line(lines[j]) {
              has_new = true
              break
            }
            if is_thematic_break(lines[j]) {
              continue
            }
            match heading_of(lines[j]) {
              Some((jlvl, jht)) => {
                if jlvl <= lvl {
                  break
                }
                push_heading(sim_stack, jlvl, jht)
                continue
              }
              None => ()
            }
            let uj = unmarked(lines[j])
            if is_table_line(uj) {
              has_new = true
              break
            }
            if says(uj) {
              if !seen_content.contains(scope_path(sim_stack) + "\n" + js_trim(uj)) {
                has_new = true
                break
              }
            }
          }
          if !has_new {
            dropped_since_last_kept = true
            continue
          }
        }
        seen_heading_paths[path] = true
        out.push(lines[i])
        dropped_since_last_kept = false
        continue
      }
      None => ()
    }
    let u = unmarked(lines[i])
    if is_table_line(u) {
      out.push(lines[i])
      dropped_since_last_kept = false
      continue
    }
    if says(u) {
      let scoped_key = scope_path(heading_stack) + "\n" + js_trim(u)
      if seen_content.contains(scoped_key) {
        dropped_since_last_kept = true
      } else {
        seen_content[scoped_key] = true
        out.push(if has_unmarked.contains(scoped_key) { u } else { lines[i] })
        dropped_since_last_kept = false
      }
      continue
    }
    if js_trim(lines[i]) == "" {
      if dropped_since_last_kept && (out.length() == 0 || js_trim(out[out.length() - 1]) == "") {
        continue
      }
      out.push(lines[i])
    } else {
      out.push(lines[i])
      dropped_since_last_kept = false
    }
  }
  if dropped_since_last_kept {
    while out.length() > 0 && js_trim(out[out.length() - 1]) == "" {
      let _ = out.pop()
    }
  }
  if had_trailing_nl {
    joined(out) + "\n"
  } else {
    joined(out)
  }
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
