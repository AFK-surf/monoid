// Shared JS collation (`String.prototype.localeCompare` in ICU root collation) and Slack mention stripping.

///|
/// Where a code unit sorts in ICU's root collation: white space, punctuation/symbols, digits, letters (case aside),
/// then non-ASCII by code point.
fn collation_weight(c : Int) -> Int {
  let order = "\t\n\u{0b}\u{0c}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$0123456789"
  if c >= 'a' && c <= 'z' {
    return 1000 + (c - 'a')
  }
  if c >= 'A' && c <= 'Z' {
    return 1000 + (c - 'A')
  }
  for i in 0..<order.length() {
    if order.unsafe_get(i).to_int() == c {
      return i
    }
  }
  if is_js_space(c) {
    return 5
  }
  2000 + c
}

///|
/// `a.localeCompare(b)` in ICU's root collation: primary weight (space < punctuation < symbols < digits < letters <
/// non-ASCII), then shorter first, then tertiary lower-case before upper-case. Returns -1, 0, or 1.
pub fn locale_compare(a : String, b : String) -> Int {
  let n = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<n {
    let x = collation_weight(a.unsafe_get(i).to_int())
    let y = collation_weight(b.unsafe_get(i).to_int())
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  if a.length() != b.length() {
    return if a.length() < b.length() { -1 } else { 1 }
  }
  for i in 0..<n {
    let x = a.unsafe_get(i).to_int()
    let y = b.unsafe_get(i).to_int()
    if x != y {
      let lx = x >= 'a' && x <= 'z'
      let ly = y >= 'a' && y <= 'z'
      if lx != ly {
        return if lx { -1 } else { 1 }
      }
      return if x < y { -1 } else { 1 }
    }
  }
  0
}

///|
/// `titles.ts` `withoutMentions`: text without Slack's `<@U123>` mentions (`[A-Z0-9]+`).
pub fn without_mentions(text : String) -> String {
  let out = StringBuilder()
  let mut rest = text
  while rest.find("<@") is Some(at) {
    out.write_string(rest.exact_view(end=at).to_owned())
    let after = rest.exact_view(start=at + 2).to_owned()
    match after.find(">") {
      Some(end) if end > 0 &&
        after
        .exact_view(end~)
        .iter()
        .all(c => (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) =>
        rest = after.exact_view(start=end + 1).to_owned()
      _ => {
        out.write_string("<@")
        rest = after
      }
    }
  }
  out.write_string(rest)
  out.to_string()
}
