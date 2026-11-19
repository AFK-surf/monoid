// GET /events's query (station/src/api/routes/events.ts): what a stream is asked to follow.

///|
/// `Number(s)` of a string, as JavaScript reads one.
pub fn js_number(s : String) -> Double {
  let t = @jscase.trim(s)
  if t == "" {
    return 0.0
  }
  if t == "Infinity" || t == "+Infinity" {
    return @double.infinity
  }
  if t == "-Infinity" {
    return @double.neg_infinity
  }
  let radix = if t.has_prefix("0x") || t.has_prefix("0X") {
    16
  } else if t.has_prefix("0o") || t.has_prefix("0O") {
    8
  } else if t.has_prefix("0b") || t.has_prefix("0B") {
    2
  } else {
    10
  }
  if radix != 10 {
    let digits = t.view(start_offset=2)
    if digits.length() == 0 {
      return @double.not_a_number
    }
    let mut n = 0.0
    for c in digits {
      let d = hex_value(c.to_int())
      if d < 0 || d >= radix {
        return @double.not_a_number
      }
      n = n * radix.to_double() + d.to_double()
    }
    return n
  }
  // [+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)?
  let n = t.length()
  let mut i = 0
  let mut sign = ""
  if t.unsafe_charcode_at(0) == '+'.to_int() ||
    t.unsafe_charcode_at(0) == '-'.to_int() {
    if t.unsafe_charcode_at(0) == '-'.to_int() {
      sign = "-"
    }
    i = 1
  }
  let digit = (k : Int32) => {
    k < n &&
    t.unsafe_charcode_at(k) >= '0'.to_int() &&
    t.unsafe_charcode_at(k) <= '9'.to_int()
  }
  let int_start = i
  while digit(i) {
    i += 1
  }
  let mut int_part = t.view(start_offset=int_start, end_offset=i).to_string()
  let mut frac = ""
  if i < n && t.unsafe_charcode_at(i) == '.'.to_int() {
    i += 1
    let f = i
    while digit(i) {
      i += 1
    }
    frac = t.view(start_offset=f, end_offset=i).to_string()
  }
  if int_part == "" && frac == "" {
    return @double.not_a_number
  }
  let mut exp = ""
  if i < n &&
    (
      t.unsafe_charcode_at(i) == 'e'.to_int() ||
      t.unsafe_charcode_at(i) == 'E'.to_int()
    ) {
    let e = i
    i += 1
    if i < n &&
      (
        t.unsafe_charcode_at(i) == '+'.to_int() ||
        t.unsafe_charcode_at(i) == '-'.to_int()
      ) {
      i += 1
    }
    let d = i
    while digit(i) {
      i += 1
    }
    if i == d {
      return @double.not_a_number
    }
    exp = "e" + t.view(start_offset=e + 1, end_offset=i).to_string()
  }
  if i != n {
    return @double.not_a_number
  }
  while int_part.length() > 1 && int_part.has_prefix("0") {
    int_part = int_part.view(start_offset=1).to_string()
  }
  if int_part == "" {
    int_part = "0"
  }
  let text = sign + int_part + (if frac == "" { "" } else { "." + frac }) + exp
  match (Some(@jsjson.parse(text)) catch { _ => None }) {
    Some(Num(d)) => d
    _ => {
      // (past what a double holds: JSON's reading says null)
      if sign == "-" {
        @double.neg_infinity
      } else {
        @double.infinity
      }
    }
  }
}

///|
/// Rust's `parse::<usize>()`: digits only, a leading + too.
fn usize(v : String?) -> Double? {
  guard v is Some(v) else { return None }
  let digits = if v.has_prefix("+") {
    v.view(start_offset=1).to_string()
  } else {
    v
  }
  if digits.length() == 0 || !digits.iter().all(c => c >= '0' && c <= '9') {
    return None
  }
  Some(js_number(v))
}

///|
fn all_of(query : Array[(String, String)], name : String) -> Array[String] {
  query.filter(p => p.0 == name).map(p => p.1)
}

///|
fn param(query : Array[(String, String)], name : String) -> String? {
  query.iter().find_first(p => p.0 == name).map(p => p.1)
}

///|
/// `^[0-9a-z]{1,40}$`: a login's id.
fn login_id(id : String) -> Bool {
  id.length() >= 1 &&
  id.length() <= 40 &&
  id.iter().all(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'))
}

///|
/// routes/events.ts: what a request's query asks a stream to follow, of the viewer's workspace only
/// (`session_seen`, `job_seen`; none: every one).
pub fn asked_of(
  query : Array[(String, String)],
  viewer : Viewer,
  session_exists : (String) -> Bool,
  store : SeenStore?,
) -> (Asked, String?) {
  let froms = all_of(query, "from")
  let lasts = all_of(query, "last")
  let live = []
  for i, key in all_of(query, "live") {
    let f = if i < froms.length() { Some(froms[i]) } else { None }
    let n = match f {
      Some(f) => js_number(f)
      None => @double.not_a_number
    }
    let from = match f {
      Some(f) if @jscase.trim(f) != "" && !n.is_nan() => {
        let m = if n > 0.0 { n } else { 0.0 }
        if m.is_inf() {
          m
        } else {
          m.floor()
        }
      }
      _ => 0.0
    }
    let last = usize(if i < lasts.length() { Some(lasts[i]) } else { None })
    let from = if from.is_inf() { 9007199254740991.0 } else { from }
    let last = match last {
      Some(l) if l > 0.0 => Some(l)
      _ => None
    }
    if session_exists(key) &&
      (store is None || session_seen(store.unwrap(), viewer, key)) {
      live.push((key, from, last))
    }
  }
  let lines = all_of(query, "lines")
  let logs = []
  for i, id in all_of(query, "job") {
    let asked = usize(if i < lines.length() { Some(lines[i]) } else { None }).unwrap_or(
      200.0,
    )
    let n = @cmp.minimum(1000.0, @cmp.maximum(1.0, asked))
    if store is None || job_seen(store.unwrap(), viewer, id) {
      logs.push((id, n.to_int()))
    }
  }
  let logins = if read_only(viewer.role) {
    []
  } else {
    all_of(query, "login").filter(login_id)
  }
  (
    {
      host: param(query, "host") == Some("1"),
      live,
      logs,
      since: param(query, "since"),
      brief: param(query, "brief") == Some("1"),
      logins,
      running: param(query, "running") == Some("1"),
    },
    None,
  )
}
