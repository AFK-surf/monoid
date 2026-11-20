// Names in the order the drive lists them: `new Intl.Collator(undefined, { numeric: true, sensitivity: "base" })`, as
// ICU's root collation orders them (the station runs Node with no locale of its own): case and accents aside, a run
// of digits by its value (E2 before E10), spaces before punctuation before symbols before digits before letters, the
// Latin letters before every other script's. What is not Latin, a digit, a space or ASCII's punctuation is ordered by
// its code point after them (ICU orders the other scripts and symbols by tables of its own, which no name of the
// drive's tests uses); a control character is passed over, as ICU passes it over. And JavaScript's `<` on strings
// (their UTF-16 code units), MoonBit's own comparison being by length first.

///|
/// ASCII's spaces, punctuation and symbols in the root collation's order.
let ascii_order : String = "\t\n\u{b}\u{c}\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"

///|
/// A letter with an accent (Latin-1 and Latin Extended-A) as its letter: what `sensitivity: "base"` takes it for.
fn base_letter(c : Int) -> String? {
  let table : Array[(Int, String)] = [
    (0xC0, "a"),
    (0xC1, "a"),
    (0xC2, "a"),
    (0xC3, "a"),
    (0xC4, "a"),
    (0xC5, "a"),
    (0xC6, "ae"),
    (0xC7, "c"),
    (0xC8, "e"),
    (0xC9, "e"),
    (0xCA, "e"),
    (0xCB, "e"),
    (0xCC, "i"),
    (0xCD, "i"),
    (0xCE, "i"),
    (0xCF, "i"),
    (0xD0, "d"),
    (0xD1, "n"),
    (0xD2, "o"),
    (0xD3, "o"),
    (0xD4, "o"),
    (0xD5, "o"),
    (0xD6, "o"),
    (0xD8, "o"),
    (0xD9, "u"),
    (0xDA, "u"),
    (0xDB, "u"),
    (0xDC, "u"),
    (0xDD, "y"),
    (0xDF, "ss"),
    (0xE0, "a"),
    (0xE1, "a"),
    (0xE2, "a"),
    (0xE3, "a"),
    (0xE4, "a"),
    (0xE5, "a"),
    (0xE6, "ae"),
    (0xE7, "c"),
    (0xE8, "e"),
    (0xE9, "e"),
    (0xEA, "e"),
    (0xEB, "e"),
    (0xEC, "i"),
    (0xED, "i"),
    (0xEE, "i"),
    (0xEF, "i"),
    (0xF0, "d"),
    (0xF1, "n"),
    (0xF2, "o"),
    (0xF3, "o"),
    (0xF4, "o"),
    (0xF5, "o"),
    (0xF6, "o"),
    (0xF8, "o"),
    (0xF9, "u"),
    (0xFA, "u"),
    (0xFB, "u"),
    (0xFC, "u"),
    (0xFD, "y"),
    (0xFF, "y"),
  ]
  for p in table {
    if p.0 == c {
      return Some(p.1)
    }
  }
  if c >= 0x100 && c <= 0x17F {
    // Latin Extended-A: pairs of capital and small, each a letter with an accent.
    let letters = "aaaaaaccccccccddddeeeeeeeeeegggggggghhhhiiiiiiiiii##jjkkkllllllllllnnnnnnnnnoooooo%%rrrrrrssssssssttttttuuuuuuuuuuuuwwyyyzzzzzzs"
    let i = c - 0x100
    let l = letters.unsafe_charcode_at(i)
    return Some(
      if l == '#' {
        "ij"
      } else if l == '%' {
        "oe"
      } else {
        letters.unsafe_substring(start=i, end=i + 1)
      },
    )
  }
  None
}

///|
/// One element of a name's key: a weight, or a run of digits (its value's digits, no leading zeros).
priv enum Elem {
  W(Int)
  Num(String)
}

///|
fn letter_weight(c : Int) -> Int {
  5000 + (c - 'a'.to_int()) * 2
}

///|
fn key_of(s : String) -> Array[Elem] {
  let out : Array[Elem] = []
  let cs = s.to_array()
  let mut i = 0
  while i < cs.length() {
    let c = cs[i].to_int()
    if c >= '0'.to_int() && c <= '9'.to_int() {
      let digits = StringBuilder::new()
      let mut j = i
      while j < cs.length() &&
            cs[j].to_int() >= '0'.to_int() &&
            cs[j].to_int() <= '9'.to_int() {
        digits.write_char(cs[j])
        j += 1
      }
      let d = digits.to_string()
      let mut z = 0
      while z < d.length() - 1 && d.unsafe_charcode_at(z) == '0' {
        z += 1
      }
      out.push(Num(d.unsafe_substring(start=z, end=d.length())))
      i = j
      continue
    }
    if c >= 'a'.to_int() && c <= 'z'.to_int() {
      out.push(W(letter_weight(c)))
    } else if c >= 'A'.to_int() && c <= 'Z'.to_int() {
      out.push(W(letter_weight(c + 32)))
    } else if c < 0x80 {
      let mut found = -1
      for k = 0; k < ascii_order.length(); k = k + 1 {
        if ascii_order.unsafe_charcode_at(k) == c {
          found = k
          break
        }
      }
      if found >= 0 {
        out.push(W(1000 + found))
      }
      // (a control character: passed over)
    } else {
      match base_letter(c) {
        Some(b) =>
          for k = 0; k < b.length(); k = k + 1 {
            out.push(W(letter_weight(b.unsafe_charcode_at(k))))
          }
        None =>
          if c >= 0x80 && c < 0xA0 {
            ()
          } else if c == 0xA0 {
            out.push(W(1000 + 5))
          } else {
            out.push(W(100000 + c))
          }
      }
    }
    i += 1
  }
  out
}

///|
/// Two runs of digits by their value.
fn num_compare(a : String, b : String) -> Int {
  if a.length() != b.length() {
    return if a.length() < b.length() { -1 } else { 1 }
  }
  units_compare(a, b)
}

///|
/// The collator's `compare`: below 0, 0 (the same at base strength) or above 0.
pub fn collate(a : String, b : String) -> Int {
  let x = key_of(a)
  let y = key_of(b)
  let n = if x.length() < y.length() { x.length() } else { y.length() }
  for i in 0..<n {
    let d = match (x[i], y[i]) {
      (W(p), W(q)) => p - q
      (Num(p), Num(q)) => num_compare(p, q)
      // digits come before letters, after spaces, punctuation and symbols
      (Num(_), W(q)) => if q >= 5000 { -1 } else { 1 }
      (W(p), Num(_)) => if p >= 5000 { 1 } else { -1 }
    }
    if d != 0 {
      return if d < 0 { -1 } else { 1 }
    }
  }
  if x.length() == y.length() {
    0
  } else if x.length() < y.length() {
    -1
  } else {
    1
  }
}

///|
/// JavaScript's comparison of strings: by their UTF-16 code units.
pub fn units_compare(a : String, b : String) -> Int {
  let d = @jsjson.js_compare(a, b)
  if d < 0 { -1 } else if d > 0 { 1 } else { 0 }
}

///|
/// Array.prototype.sort with `cmp`: stable, as V8's is.
pub fn[T] stable_sort(items : Array[T], cmp : (T, T) -> Int) -> Array[T] {
  let n = items.length()
  if n < 2 {
    return items.copy()
  }
  let mid = n / 2
  let left = stable_sort(items[0:mid].to_array(), cmp)
  let right = stable_sort(items[mid:n].to_array(), cmp)
  let out = []
  let mut i = 0
  let mut j = 0
  while i < left.length() && j < right.length() {
    if cmp(right[j], left[i]) < 0 {
      out.push(right[j])
      j += 1
    } else {
      out.push(left[i])
      i += 1
    }
  }
  while i < left.length() {
    out.push(left[i])
    i += 1
  }
  while j < right.length() {
    out.push(right[j])
    j += 1
  }
  out
}
