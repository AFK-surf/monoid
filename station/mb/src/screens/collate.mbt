// `String.prototype.localeCompare` as these parts use it (an app's name, a bundle id): ICU's root collation in what it
// says of the names they compare: white space before punctuation, then symbols, digits and letters; letters by their
// letter whatever their case (a before B), then lower case before upper; what is still alike by its code points.

///|
fn collation_class(c : Char) -> Int {
  if is_js_space(c) {
    1
  } else if (c >= '0' && c <= '9') {
    4
  } else if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c.to_int() >= 0x80 {
    5
  } else if c == '_' || c == '-' || c == ',' || c == ';' || c == ':' || c == '!' || c == '?' || c == '.' || c == '\'' ||
    c == '"' || c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}' || c == '@' || c == '*' ||
    c == '/' || c == '\\' || c == '&' || c == '#' || c == '%' {
    2
  } else {
    3
  }
}

///|
fn lower_char(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    Int::unsafe_to_char(c.to_int() + 32)
  } else {
    c
  }
}

///|
/// `a.localeCompare(b)`: below, at or above 0.
pub fn locale_compare(a : String, b : String) -> Int {
  let x = a.to_array()
  let y = b.to_array()
  let n = if x.length() < y.length() { x.length() } else { y.length() }
  // Primary: the class, then the letter as lower case.
  for i in 0..<n {
    let (cx, cy) = (collation_class(x[i]), collation_class(y[i]))
    if cx != cy {
      return if cx < cy { -1 } else { 1 }
    }
    let (lx, ly) = (lower_char(x[i]), lower_char(y[i]))
    if lx != ly {
      return if lx < ly { -1 } else { 1 }
    }
  }
  if x.length() != y.length() {
    return if x.length() < y.length() { -1 } else { 1 }
  }
  // Tertiary: lower case first.
  for i in 0..<n {
    if x[i] != y[i] {
      let ux = x[i] >= 'A' && x[i] <= 'Z'
      let uy = y[i] >= 'A' && y[i] <= 'Z'
      if ux != uy {
        return if ux { 1 } else { -1 }
      }
      return if x[i] < y[i] { -1 } else { 1 }
    }
  }
  0
}
