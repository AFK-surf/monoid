// Layout, context extraction, and single-card / multi-card pagination for selected-text share cards.
// Ported from Comma's text-selection share image layout (AFK-surf/Cue #5786) to pure MoonBit.

///|
/// How surrounding context attaches to the selected passage.
#derive(Eq, Debug)
pub(all) enum ExcerptJoin {
  Inline
  InlineSpace
  Paragraph
}

///|
/// Extracted selection and surrounding context ready to be planned into one or more share cards.
#derive(Eq, Debug)
pub(all) struct ExcerptPayload {
  before_context : String
  before_join : ExcerptJoin
  selected_text : String
  after_context : String
  after_join : ExcerptJoin
  source_title : String
  date_label : String
}

///|
/// Whether an oversized selection renders as one truncated excerpt or a numbered series.
#derive(Eq, Debug)
pub(all) enum ExcerptMode {
  Excerpt
  Pages
}

///|
/// One rendered card in a single-card or multi-card share plan.
#derive(Eq, Debug)
pub(all) struct ExcerptSlice {
  page_index : Int
  page_count : Int
  before_context : String
  before_join : ExcerptJoin
  selected_text : String
  after_context : String
  after_join : ExcerptJoin
  continued_from_prev : Bool
  continues_to_next : Bool
  truncated_end : Bool
}

///|
/// Planned share cards and length metadata for a selection.
#derive(Eq, Debug)
pub(all) struct ExcerptPlan {
  mode : ExcerptMode
  exceeds_single_limit : Bool
  total_chars : Int
  shown_chars : Int
  was_truncated : Bool
  total_possible_pages : Int
  cards : Array[ExcerptSlice]
}

///|
let excerpt_single_max_units : Double = 600.0

///|
let excerpt_page_max_units : Double = 500.0

///|
let excerpt_max_pages : Int = 9

///|
let excerpt_context_max_units : Double = 42.0

///|
let excerpt_para_break_units : Double = 22.0

///|
let excerpt_single_break_units : Double = 10.0

///|
fn excerpt_is_wide(cp : Int) -> Bool {
  (cp >= 0x1100 && cp <= 0x115f) ||
  (cp >= 0x2e80 && cp <= 0xa4cf) ||
  (cp >= 0xac00 && cp <= 0xd7a3) ||
  (cp >= 0xf900 && cp <= 0xfaff) ||
  (cp >= 0xfe10 && cp <= 0xfe6f) ||
  (cp >= 0xff00 && cp <= 0xff60) ||
  (cp >= 0x20000 && cp <= 0x3ffff)
}

///|
fn excerpt_is_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{00a0}' || c == '\u{3000}'
}

///|
fn excerpt_is_latin_word(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '\'' ||
  c == '-'
}

///|
fn excerpt_is_strong_break(c : Char) -> Bool {
  c == '。' || c == '！' || c == '？' || c == '.' || c == '!' || c == '?' || c == '\n'
}

///|
fn excerpt_is_soft_break(c : Char) -> Bool {
  c == '，' ||
  c == '；' ||
  c == '：' ||
  c == '、' ||
  c == ',' ||
  c == ';' ||
  c == ':' ||
  excerpt_is_space(c)
}

///|
fn excerpt_is_leading_punct(c : Char) -> Bool {
  excerpt_is_space(c) ||
  c == '，' ||
  c == '。' ||
  c == '！' ||
  c == '？' ||
  c == '；' ||
  c == '：' ||
  c == '、' ||
  c == '.' ||
  c == ',' ||
  c == '!' ||
  c == '?' ||
  c == ';' ||
  c == ':'
}

///|
fn excerpt_ends_sentence(s : String) -> Bool {
  let cs = s.to_array()
  if cs.is_empty() {
    return false
  }
  let last = cs[cs.length() - 1]
  last == '。' || last == '！' || last == '？' || last == '.' || last == '!' || last == '?' || last == '…'
}

///|
fn excerpt_char_units(c : Char) -> Double {
  if c == '\n' {
    return excerpt_single_break_units
  }
  if excerpt_is_wide(c.to_int()) {
    return 1.0
  }
  if excerpt_is_space(c) {
    return 0.35
  }
  0.55
}

///|
/// Measures visual length in CJK-equivalent units, accounting for paragraph gaps.
pub fn measure_excerpt_units(text : String) -> Double {
  if text.is_empty() {
    return 0.0
  }
  let cs = text.to_array()
  let mut total = 0.0
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '\n' && i + 1 < cs.length() && cs[i + 1] == '\n' {
      total += excerpt_para_break_units
      while i < cs.length() && cs[i] == '\n' {
        i += 1
      }
      continue
    }
    total += excerpt_char_units(cs[i])
    i += 1
  }
  total
}

///|
/// Counts visible non-whitespace characters (code points) for length notices.
pub fn count_excerpt_chars(text : String) -> Int {
  let mut n = 0
  for c in text.to_array() {
    if !excerpt_is_space(c) {
      n += 1
    }
  }
  n
}

///|
fn excerpt_trim_end(chars : Array[Char], end : Int) -> String {
  let mut e = end
  while e > 0 && excerpt_is_space(chars[e - 1]) {
    e -= 1
  }
  String::from_array(chars[0:e].to_owned())
}

///|
fn excerpt_trim_start(chars : Array[Char], start : Int) -> String {
  let mut s = start
  while s < chars.length() && excerpt_is_space(chars[s]) {
    s += 1
  }
  String::from_array(chars[s:].to_owned())
}

///|
fn excerpt_take_prefix(text : String, max_units : Double) -> (String, String) {
  let chars = text.to_array()
  let n = chars.length()
  let mut units = 0.0
  let mut cut = n
  let mut idx = 0
  while idx < n {
    let ch = chars[idx]
    let next = if ch == '\n' && idx + 1 < n && chars[idx + 1] == '\n' {
      units + excerpt_para_break_units
    } else {
      units + excerpt_char_units(ch)
    }
    if next > max_units && idx > 0 {
      cut = idx
      break
    }
    units = next
    idx += 1
  }
  if cut >= n {
    return (text, "")
  }
  let min_window = {
    let w = (cut.to_double() * 0.72).floor().to_int()
    if w < 1 { 1 } else { w }
  }
  let mut best_para = -1
  let mut best_sentence = -1
  let mut best_soft = -1
  let mut i = cut
  while i >= min_window {
    let prev = chars[i - 1]
    let curr = if i < n { chars[i] } else { ' ' }
    if i >= 2 && prev == '\n' && chars[i - 2] == '\n' && best_para == -1 {
      best_para = i
    }
    if excerpt_is_strong_break(prev) && best_sentence == -1 {
      best_sentence = i
    }
    if excerpt_is_soft_break(prev) && best_soft == -1 {
      best_soft = i
    }
    if best_soft == -1 && excerpt_is_latin_word(prev) && !excerpt_is_latin_word(curr) {
      best_soft = i
    }
    i -= 1
  }
  let mut resolved = if best_para != -1 {
    best_para
  } else if best_sentence != -1 {
    best_sentence
  } else if best_soft != -1 {
    best_soft
  } else {
    cut
  }
  if resolved > 1 && resolved < n && excerpt_is_latin_word(chars[resolved - 1]) && excerpt_is_latin_word(chars[resolved]) {
    let mut walk = resolved
    while walk > min_window && excerpt_is_latin_word(chars[walk - 1]) {
      walk -= 1
    }
    if walk > min_window {
      resolved = walk
    }
  }
  (excerpt_trim_end(chars, resolved), excerpt_trim_start(chars, resolved))
}

///|
/// Keeps the trailing ~`max_units` of preceding context, snapping cleanly on the left.
pub fn trim_before_context(before : String, max_units? : Double = excerpt_context_max_units) -> String {
  let trimmed = before.trim(chars=" \n\t\r").to_owned()
  if trimmed.is_empty() {
    return ""
  }
  if measure_excerpt_units(trimmed) <= max_units {
    return trimmed
  }
  let chars = trimmed.to_array()
  let n = chars.length()
  let mut units = 0.0
  let mut start = 0
  let mut i = n - 1
  while i >= 0 {
    let ch = chars[i]
    units += if ch == '\n' && i > 0 && chars[i - 1] == '\n' {
      excerpt_para_break_units
    } else {
      excerpt_char_units(ch)
    }
    if units >= max_units {
      start = i
      break
    }
    i -= 1
  }
  if start > 0 && excerpt_is_latin_word(chars[start - 1]) && excerpt_is_latin_word(chars[start]) {
    let mut walk = start
    let limit = if n - 1 < start + 18 { n - 1 } else { start + 18 }
    while walk < limit && excerpt_is_latin_word(chars[walk]) {
      walk += 1
    }
    while walk < limit && chars[walk] == ' ' {
      walk += 1
    }
    if walk < n {
      start = walk
    }
  }
  while start < n - 1 && excerpt_is_leading_punct(chars[start]) {
    start += 1
  }
  excerpt_trim_start(chars, start)
}

///|
/// Keeps the leading ~`max_units` of following context, snapping cleanly on the right.
pub fn trim_after_context(after : String, max_units? : Double = excerpt_context_max_units) -> String {
  let trimmed = after.trim(chars=" \n\t\r").to_owned()
  if trimmed.is_empty() {
    return ""
  }
  if measure_excerpt_units(trimmed) <= max_units {
    return trimmed
  }
  excerpt_take_prefix(trimmed, max_units).0
}

///|
/// Returns at most `max_chars` Unicode scalar values from `s` without allocating an array over the full string.
fn excerpt_bounded_head(s : String, max_chars : Int) -> (String, Bool) {
  let out = StringBuilder()
  let mut count = 0
  let mut truncated = false
  for c in s {
    if count >= max_chars {
      truncated = true
      break
    }
    out.write_char(c)
    count += 1
  }
  (out.to_string(), truncated)
}

///|
/// Measures both non-whitespace character count and weighted visual units in one linear O(N) pass with no allocation.
fn measure_excerpt_stats(s : String) -> (Int, Double) {
  let mut chars = 0
  let mut units = 0.0
  let mut prev_nl = false
  for c in s {
    if c == '\n' {
      if prev_nl {
        // Second newline of a paragraph break: upgrade single break to paragraph break.
        units += excerpt_para_break_units - excerpt_single_break_units
        prev_nl = false
      } else {
        units += excerpt_single_break_units
        prev_nl = true
      }
    } else if c == '\r' {
      ()
    } else {
      prev_nl = false
      if !excerpt_is_space(c) {
        chars += 1
      }
      units += excerpt_char_units(c)
    }
  }
  (chars, units)
}

///|
/// Plans single-card or paginated share cards for any selection length (including 1 MB+ logs) in O(N) time.
pub fn plan_excerpt_cards(payload : ExcerptPayload, requested : ExcerptMode) -> ExcerptPlan {
  let selected = payload.selected_text.trim(chars=" \n\t\r").to_owned()
  let (total_chars, total_units) = measure_excerpt_stats(selected)
  let exceeds = total_units > excerpt_single_max_units
  let before_snip = trim_before_context(payload.before_context)
  let after_snip = trim_after_context(payload.after_context)
  if !exceeds {
    return {
      mode: Excerpt,
      exceeds_single_limit: false,
      total_chars,
      shown_chars: total_chars,
      was_truncated: false,
      total_possible_pages: 1,
      cards: [
        {
          page_index: 0,
          page_count: 1,
          before_context: before_snip,
          before_join: if before_snip != "" { payload.before_join } else { Paragraph },
          selected_text: selected,
          after_context: after_snip,
          after_join: if after_snip != "" { payload.after_join } else { Paragraph },
          continued_from_prev: false,
          continues_to_next: false,
          truncated_end: false,
        },
      ],
    }
  }
  // Only split up to `excerpt_max_pages` chunks on a bounded prefix so huge selections (e.g. 1 MB logs) stay instant.
  // Worst-case narrow ASCII is ~0.52 units/char, so 2.5x unit budget in chars always covers the full page budget.
  let max_prefix_chars = ((excerpt_max_pages + 1).to_double() * excerpt_page_max_units * 2.5).to_int()
  let (work_str, had_more_beyond_window) = excerpt_bounded_head(selected, max_prefix_chars)
  let chunks : Array[String] = []
  let mut remaining = work_str
  let mut used_units = 0.0
  let mut more_chunks = had_more_beyond_window
  while remaining != "" && chunks.length() < excerpt_max_pages {
    let (_, rem_units) = measure_excerpt_stats(remaining)
    if rem_units <= excerpt_page_max_units && !had_more_beyond_window {
      chunks.push(remaining)
      used_units += rem_units
      remaining = ""
      break
    }
    let (head, tail) = excerpt_take_prefix(remaining, excerpt_page_max_units)
    if head.is_empty() {
      chunks.push(remaining)
      used_units += rem_units
      remaining = ""
      break
    }
    let (_, head_units) = measure_excerpt_stats(head)
    chunks.push(head)
    used_units += head_units
    remaining = tail
  }
  if remaining != "" {
    more_chunks = true
  }
  let total_possible = if !more_chunks {
    if chunks.length() < 2 { 2 } else { chunks.length() }
  } else {
    let left_units = if total_units > used_units { total_units - used_units } else { excerpt_page_max_units }
    let extra = (left_units / excerpt_page_max_units).ceil().to_int()
    let est = chunks.length() + (if extra < 1 { 1 } else { extra })
    if est < 2 { 2 } else { est }
  }
  if requested == Excerpt {
    let single_window = (excerpt_single_max_units * 2.5).to_int()
    let (single_src, _) = excerpt_bounded_head(selected, single_window)
    let (head, _) = excerpt_take_prefix(single_src, excerpt_single_max_units)
    let excerpt_text = if head != "" { head } else { single_src }
    let shown_chars = count_excerpt_chars(excerpt_text)
    return {
      mode: Excerpt,
      exceeds_single_limit: true,
      total_chars,
      shown_chars,
      was_truncated: true,
      total_possible_pages: total_possible,
      cards: [
        {
          page_index: 0,
          page_count: 1,
          before_context: before_snip,
          before_join: if before_snip != "" { payload.before_join } else { Paragraph },
          selected_text: excerpt_text,
          after_context: "",
          after_join: Paragraph,
          continued_from_prev: false,
          continues_to_next: false,
          truncated_end: true,
        },
      ],
    }
  }
  let capped_len = chunks.length()
  let was_capped = more_chunks
  let mut shown_chars = 0
  let cards : Array[ExcerptSlice] = []
  for i in 0..<capped_len {
    let chunk = chunks[i]
    shown_chars += count_excerpt_chars(chunk)
    let is_first = i == 0
    let is_last = i == capped_len - 1
    cards.push({
      page_index: i,
      page_count: capped_len,
      before_context: if is_first { before_snip } else { "" },
      before_join: if is_first && before_snip != "" { payload.before_join } else { Paragraph },
      selected_text: chunk,
      after_context: if is_last && !was_capped { after_snip } else { "" },
      after_join: if is_last && !was_capped && after_snip != "" { payload.after_join } else { Paragraph },
      continued_from_prev: !is_first,
      continues_to_next: !is_last,
      truncated_end: is_last && was_capped,
    })
  }
  {
    mode: Pages,
    exceeds_single_limit: true,
    total_chars,
    shown_chars,
    was_truncated: was_capped,
    total_possible_pages: total_possible,
    cards,
  }
}

// ── Markdown AST plain-text extraction & context matching ──────────────────

///|
fn excerpt_md_span(j : Json, text : String) -> String? {
  match j {
    String(s) => Some(s)
    Array([Number(a, ..), Number(b, ..)]) if a >= 0.0 && b >= a && b <= text.length().to_double() =>
      Some(text.clamped_view(start=a.to_int(), end=b.to_int()).to_owned())
    _ => None
  }
}

///|
fn excerpt_md_inlines(nodes : Array[Json], text : String, out : StringBuilder) -> Unit {
  for j in nodes {
    if excerpt_md_span(j, text) is Some(w) {
      out.write_string(w)
      continue
    }
    match j {
      Array(a) if a.length() >= 1 => {
        let name = match a[0] {
          String(s) => s
          _ => ""
        }
        let (kids, attrs) = if a.length() > 1 && a[1] is Array(ch) {
          (ch, if a.length() > 2 { a[2] } else { Json::null() })
        } else {
          ([], if a.length() > 1 { a[1] } else { Json::null() })
        }
        let attr_str = fn(k : String) -> String {
          match field(Some(attrs), k) {
            Some(v) => excerpt_md_span(v, text).unwrap_or("")
            None => ""
          }
        }
        match name {
          "code" => {
            let shown = attr_str("shown")
            let content = attr_str("content")
            out.write_string(if shown != "" { shown } else { content })
          }
          "b" | "i" | "s" | "a" => excerpt_md_inlines(kids, text, out)
          "br" => out.write_char('\n')
          "img" => out.write_string(attr_str("alt"))
          _ => excerpt_md_inlines(kids, text, out)
        }
      }
      _ => ()
    }
  }
}

///|
fn excerpt_md_blocks(nodes : Array[Json], text : String, paras : Array[String]) -> Unit {
  for j in nodes {
    match j {
      Array(a) if a.length() >= 1 => {
        let name = match a[0] {
          String(s) => s
          _ => ""
        }
        let (kids, attrs) = if a.length() > 1 && a[1] is Array(ch) {
          (ch, if a.length() > 2 { a[2] } else { Json::null() })
        } else {
          ([], if a.length() > 1 { a[1] } else { Json::null() })
        }
        match name {
          "p" | "h" => {
            let sb = StringBuilder()
            excerpt_md_inlines(kids, text, sb)
            let s = sb.to_string().trim(chars=" \t\r").to_owned()
            if s != "" {
              paras.push(s)
            }
          }
          "blockquote" | "ul" | "ol" | "li" => excerpt_md_blocks(kids, text, paras)
          "pre" =>
            match field(Some(attrs), "content") {
              Some(v) => {
                let s = excerpt_md_span(v, text).unwrap_or("").trim(chars="\n\r").to_owned()
                if s != "" {
                  paras.push(s)
                }
              }
              None => ()
            }
          "table" => {
            for row in kids {
              match row {
                Array(cells) => {
                  let parts : Array[String] = []
                  for cell in cells {
                    match cell {
                      Array(inlines) => {
                        let sb = StringBuilder()
                        excerpt_md_inlines(inlines, text, sb)
                        let s = sb.to_string().trim(chars=" \t\r").to_owned()
                        if s != "" {
                          parts.push(s)
                        }
                      }
                      _ => ()
                    }
                  }
                  if !parts.is_empty() {
                    paras.push(parts.join("  "))
                  }
                }
                _ => ()
              }
            }
          }
          _ => ()
        }
      }
      _ => ()
    }
  }
}

///|
/// Extracts plain-text paragraphs from a message's parsed Markdown AST, falling back to its raw text.
pub fn message_plain_paragraphs(m : Message) -> Array[String] {
  match m.md {
    Some(Array(blocks)) => {
      let paras : Array[String] = []
      excerpt_md_blocks(blocks, m.text, paras)
      if !paras.is_empty() {
        return paras
      }
    }
    _ => ()
  }
  let out : Array[String] = []
  let cur = StringBuilder()
  let mut blank = false
  for line_view in m.text.split("\n") {
    let line = line_view.to_owned().trim(chars="\r").to_owned()
    if line.trim(chars=" \t") == "" {
      if !blank && !cur.is_empty() {
        out.push(cur.to_string())
        cur.reset()
      }
      blank = true
    } else {
      if !cur.is_empty() {
        cur.write_char('\n')
      }
      cur.write_string(line)
      blank = false
    }
  }
  if !cur.is_empty() {
    out.push(cur.to_string())
  }
  out
}

///|
fn excerpt_join_kind(adjacent_edge_space : Bool) -> ExcerptJoin {
  if adjacent_edge_space {
    InlineSpace
  } else {
    Inline
  }
}

///|
/// Finds `(paragraph_index, utf16_offset)` of `needle` across `paragraphs`, disambiguating duplicates with `before_hint`.
/// Priority:
/// 1. Exact paragraph prefix match (`para` starts with `before_hint + needle`, since `WordsPicked.first_before` is the
///    prefix within the start paragraph).
/// 2. Longest suffix of `before_hint` (outer loop descending 24..1, inner loop across all paragraphs).
/// 3. When `before_hint` is empty, prefer a paragraph that starts with `needle` before scanning mid-paragraph matches.
fn excerpt_locate_start(paragraphs : Array[String], before_hint : String, needle : String) -> (Int, Int)? {
  if needle.is_empty() {
    return None
  }
  if before_hint != "" {
    // 1. Exact paragraph-start match: `before_hint` + `needle` at offset 0 of a paragraph.
    let exact_prefix = before_hint + needle
    for pi in 0..<paragraphs.length() {
      if paragraphs[pi].has_prefix(exact_prefix) {
        return Some((pi, before_hint.length()))
      }
    }
    // 2. Hint length outer loop (descending), paragraph inner loop, so a later paragraph matching a longer hint beats
    //    an earlier paragraph that only contains `needle` without matching context.
    let cs = before_hint.to_array()
    let max_n = if cs.length() < 24 { cs.length() } else { 24 }
    for n = max_n; n >= 1; n = n - 1 {
      let tail = String::from_array(cs[cs.length() - n:].to_owned())
      let pat = tail + needle
      for pi in 0..<paragraphs.length() {
        if paragraphs[pi].find(pat) is Some(i) {
          return Some((pi, i + tail.length()))
        }
      }
    }
  } else {
    // Empty `before_hint`: selection began at paragraph start; prefer start-of-paragraph matches first.
    for pi in 0..<paragraphs.length() {
      if paragraphs[pi].has_prefix(needle) {
        return Some((pi, 0))
      }
    }
  }
  // 3. Fallback: first occurrence anywhere.
  for pi in 0..<paragraphs.length() {
    if paragraphs[pi].find(needle) is Some(i) {
      return Some((pi, i))
    }
  }
  None
}

///|
/// Builds an `ExcerptPayload` with surrounding inline/paragraph context from a message's plain paragraphs.
pub fn build_excerpt_payload(
  paragraphs : Array[String],
  raw_selected : String,
  first_before : String,
  whole : Bool,
  source_title : String,
  date_label : String,
) -> ExcerptPayload {
  let trimmed_sel = raw_selected.trim(chars=" \n\t\r").to_owned()
  if whole || trimmed_sel.is_empty() || paragraphs.is_empty() {
    return {
      before_context: "",
      before_join: Paragraph,
      selected_text: if whole && !paragraphs.is_empty() { paragraphs.join("\n\n") } else { trimmed_sel },
      after_context: "",
      after_join: Paragraph,
      source_title,
      date_label,
    }
  }
  // Normalize selection paragraphs (selection joins block paragraphs with '\n', card uses '\n\n').
  let sel_lines : Array[String] = []
  for part in trimmed_sel.split("\n") {
    let s = part.to_owned().trim(chars=" \t\r").to_owned()
    if s != "" {
      sel_lines.push(s)
    }
  }
  if sel_lines.is_empty() {
    return {
      before_context: "",
      before_join: Paragraph,
      selected_text: trimmed_sel,
      after_context: "",
      after_join: Paragraph,
      source_title,
      date_label,
    }
  }
  // Locate the first selected line in `paragraphs` using `first_before` to disambiguate duplicates.
  let first_line = sel_lines[0]
  let (start_p, start_off) = match excerpt_locate_start(paragraphs, first_before, first_line) {
    Some(pos) => pos
    None =>
      return {
        before_context: first_before.trim(chars=" \n\t\r").to_owned(),
        before_join: if first_before.has_suffix(" ") { InlineSpace } else { Inline },
        selected_text: sel_lines.join("\n\n"),
        after_context: "",
        after_join: Paragraph,
        source_title,
        date_label,
      }
  }
  // Determine end paragraph and offset.
  let mut end_p = start_p
  let mut end_off = start_off + first_line.length()
  let mut matched_all = true
  if sel_lines.length() > 1 {
    // Walk forward matching subsequent lines across paragraphs.
    let mut cur_p = start_p
    let mut cur_pos = end_off
    let mut li = 1
    while li < sel_lines.length() {
      let needle = sel_lines[li]
      // First check remainder of current paragraph (e.g. soft line break inside same paragraph).
      let rest = paragraphs[cur_p].clamped_view(start=cur_pos).to_owned()
      if rest.find(needle) is Some(rel) {
        cur_pos = cur_pos + rel + needle.length()
        end_p = cur_p
        end_off = cur_pos
        li += 1
        continue
      }
      // Otherwise scan following paragraphs.
      let mut found_next = false
      let mut p_scan = cur_p + 1
      while p_scan < paragraphs.length() {
        if paragraphs[p_scan].find(needle) is Some(off) {
          cur_p = p_scan
          cur_pos = off + needle.length()
          end_p = cur_p
          end_off = cur_pos
          found_next = true
          break
        }
        p_scan += 1
      }
      if !found_next {
        matched_all = false
        break
      }
      li += 1
    }
  }
  // Build selected text preserving exact paragraph breaks. If any subsequent line could not be matched in AST
  // paragraphs (e.g. table cell spacing / inline code normalization), fall back to full `sel_lines` so no tail text
  // is ever silently dropped.
  let selected_out = if !matched_all {
    sel_lines.join("\n\n")
  } else if start_p == end_p {
    paragraphs[start_p].clamped_view(start=start_off, end=end_off).to_owned().trim(chars=" \n\t\r").to_owned()
  } else {
    let parts : Array[String] = []
    let first_part = paragraphs[start_p].clamped_view(start=start_off).to_owned().trim(chars=" \t\r").to_owned()
    if first_part != "" {
      parts.push(first_part)
    }
    for pi in (start_p + 1)..<end_p {
      let mid = paragraphs[pi].trim(chars=" \t\r").to_owned()
      if mid != "" {
        parts.push(mid)
      }
    }
    let last_part = paragraphs[end_p].clamped_view(end=end_off).to_owned().trim(chars=" \t\r").to_owned()
    if last_part != "" {
      parts.push(last_part)
    }
    parts.join("\n\n")
  }
  // Extract beforeContext: inline prefix of `start_p`, supplemented by preceding paragraph when short.
  let raw_before_inline = paragraphs[start_p].clamped_view(end=start_off).to_owned()
  let trimmed_before_inline = raw_before_inline.trim(chars=" \n\t\r").to_owned()
  let (before_context, before_join) = if trimmed_before_inline != "" {
    let edge_space = raw_before_inline.has_suffix(" ") || raw_before_inline.has_suffix("\t")
    let combined = if start_p > 0 && measure_excerpt_units(trimmed_before_inline) < excerpt_context_max_units * 0.7 {
      paragraphs[start_p - 1] + "\n\n" + trimmed_before_inline
    } else {
      trimmed_before_inline
    }
    (combined, excerpt_join_kind(edge_space))
  } else if start_p > 0 {
    (paragraphs[start_p - 1], Paragraph)
  } else {
    ("", Paragraph)
  }
  // Extract afterContext: inline suffix of `end_p`, supplemented by following paragraph when short (omitted on partial match).
  let (after_context, after_join) = if !matched_all {
    ("", Paragraph)
  } else {
    let raw_after_inline = paragraphs[end_p].clamped_view(start=end_off).to_owned()
    let trimmed_after_inline = raw_after_inline.trim(chars=" \n\t\r").to_owned()
    if trimmed_after_inline != "" {
      let edge_space = raw_after_inline.has_prefix(" ") || raw_after_inline.has_prefix("\t")
      let combined = if end_p + 1 < paragraphs.length() && measure_excerpt_units(trimmed_after_inline) < excerpt_context_max_units * 0.7 {
        trimmed_after_inline + "\n\n" + paragraphs[end_p + 1]
      } else {
        trimmed_after_inline
      }
      (combined, excerpt_join_kind(edge_space))
    } else if end_p + 1 < paragraphs.length() {
      (paragraphs[end_p + 1], Paragraph)
    } else {
      ("", Paragraph)
    }
  }
  {
    before_context,
    before_join,
    selected_text: if selected_out != "" { selected_out } else { trimmed_sel },
    after_context,
    after_join,
    source_title,
    date_label,
  }
}

///|
/// Formats epoch milliseconds as local `YYYY.MM.DD` (Swiss poster date) using `offset_min` (`@ui.utc_offset_min`).
/// Returns `""` for invalid/zero timestamps.
pub fn format_excerpt_date(at_ms : Double, offset_min? : Int = 0) -> String {
  // Reject unset/fixture-ordinal timestamps prior to year 2000.
  if at_ms < 946684800000.0 {
    return ""
  }
  let local_ms = at_ms + offset_min.to_double() * 60000.0
  let days = (local_ms / 86400000.0).floor().to_int64()
  let z = days + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y0 = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = (doy - (153L * mp + 2L) / 5L + 1L).to_int()
  let m = (mp + (if mp < 10L { 3L } else { -9L })).to_int()
  let y = (y0 + (if m <= 2 { 1L } else { 0L })).to_int()
  let pad2 = fn(n : Int) { if n < 10 { "0" + n.to_string() } else { n.to_string() } }
  y.to_string() + "." + pad2(m) + "." + pad2(d)
}

///|
/// Formats an integer with ASCII thousands separators (e.g. `10000` -> `"10,000"`).
pub fn format_excerpt_count(n : Int) -> String {
  let s = n.to_string()
  let cs = s.to_array()
  if cs.length() <= 3 {
    return s
  }
  let out = StringBuilder()
  let len = cs.length()
  for i in 0..<len {
    if i > 0 && (len - i) % 3 == 0 {
      out.write_char(',')
    }
    out.write_char(cs[i])
  }
  out.to_string()
}
