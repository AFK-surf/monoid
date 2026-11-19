// The words and names these modules make as station/src makes them: a thread's address (agents/instructions.ts), a
// time in ISO (read/transcript.ts `iso`), a link's percent-decoding (api/request.ts), an argument read as a number or
// a string (sessions/args.ts), JavaScript's `\s`.

///|
let stillfail_surface = "chat"

///|
let manual = "manual"

///|
let station_author = "station"

///|
let lapsed = "that chat's share with your workspace lapsed, unused for 6 hours: a person of its workspace must share it again (by @-mentioning it in a message to you, or in its chat info)"

///|
let notice_mark = "\u{2063}"

///|
fn mark_notice(text : String) -> String {
  if text.has_suffix(notice_mark) {
    text
  } else {
    text + notice_mark
  }
}

///|
pub fn thread_address(channel : String, ts : String) -> String {
  "\{channel}/\{ts}"
}

///|
fn all_of(s : String, ok : (Char) -> Bool) -> Bool {
  s != "" && s.iter().all(ok)
}

///|
fn alnum(c : Char) -> Bool {
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
}

///|
fn digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// agents/instructions.ts `parseThreadAddress`.
pub fn parse_thread_address(value : String) -> (String, String)? {
  let v = js_trim(value)
  guard v.find("/") is Some(at) else { return None }
  let channel = cut(v, 0, end=at)
  let ts = cut(v, at + 1)
  if channel.has_prefix("oc_") && all_of(cut(channel, 3), alnum) {
    let rest = if ts.has_prefix("omt_") { Some(cut(ts, 4)) } else if ts.has_prefix("om_") { Some(cut(ts, 3)) } else { None }
    if rest is Some(r) && all_of(r, alnum) {
      return Some((channel, ts))
    }
  }
  // A group connect's: its space's id, twice for its lobby, or with a topic's (src/group: a space's stream is a thread).
  let hex = (c : Char) => digit(c) || (c >= 'a' && c <= 'f')
  let space = channel.length() == 26 &&
    (channel.has_prefix("d_") || channel.has_prefix("s_")) &&
    all_of(cut(channel, 2), hex)
  let topic = ts.length() == 18 && ts.has_prefix("t_") && all_of(cut(ts, 2), hex)
  if space && (ts == channel || topic) {
    return Some((channel, ts))
  }
  guard ts.find(".") is Some(dot) else { return None }
  let secs = cut(ts, 0, end=dot)
  let micros = cut(ts, dot + 1)
  let ok = all_of(channel, c => (c >= 'A' && c <= 'Z') || digit(c)) && all_of(secs, digit) && all_of(micros, digit)
  if ok {
    Some((channel, ts))
  } else {
    None
  }
}

///|
/// read/transcript.ts `iso`: an ISO timestamp of milliseconds since the epoch, as toISOString writes it.
pub fn iso(ms : Double) -> String {
  @time.format_iso_ms(ms.to_int64())
}

///|
using @codec {hex_digit as hex_value}

///|
using @jscase {trim as js_trim}

///|
using @jsjson {js_compare}

///|
/// api/request.ts `percentDecode`: %XX a byte, `+` a space, the rest as it is (UTF-8, lossy).
pub fn percent_decode(s : String) -> String {
  @url.percent_decode_lossy(s, plus_space=true)
}

///|
/// What JavaScript's `\s` matches.
fn js_space(c : Char) -> Bool {
  @jscase.is_space(c.to_int())
}

///|
/// sessions/args.ts `jsString`.
fn js_string(v : Json) -> String {
  match v {
    String(s) => s
    Null => "null"
    v => v.stringify()
  }
}

///|
/// sessions/args.ts `jsNumber`: a number, or a string holding one.
fn js_number(v : Json) -> Double? {
  match v {
    Number(n, ..) => Some(n)
    String(s) => {
      let t = js_trim(s)
      let low = t.to_lower()
      let body = if low.has_prefix("+") || low.has_prefix("-") { cut(low, 1) } else { low }
      let neg = low.has_prefix("-")
      if body == "inf" || body == "infinity" {
        return Some(if neg { @double.neg_infinity } else { @double.infinity })
      }
      if body == "nan" {
        return Some(@double.not_a_number)
      }
      if !decimal(body) {
        return None
      }
      let digits = if body.has_suffix(".") { body + "0" } else { body }
      let digits = if digits.has_prefix(".") { "0" + digits } else { digits }
      let v = @string.parse_double(digits) catch { _ => return None }
      Some(if neg { -v } else { v })
    }
    _ => None
  }
}

///|
/// `^(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$`.
fn decimal(s : String) -> Bool {
  let c = s.to_array()
  let n = c.length()
  let mut i = 0
  let mut int = 0
  while i < n && digit(c[i]) {
    i += 1
    int += 1
  }
  let mut frac = 0
  if i < n && c[i] == '.' {
    i += 1
    while i < n && digit(c[i]) {
      i += 1
      frac += 1
    }
  }
  if int == 0 && frac == 0 {
    return false
  }
  if i < n && (c[i] == 'e' || c[i] == 'E') {
    i += 1
    if i < n && (c[i] == '+' || c[i] == '-') {
      i += 1
    }
    let mut exp = 0
    while i < n && digit(c[i]) {
      i += 1
      exp += 1
    }
    if exp == 0 {
      return false
    }
  }
  i == n
}

///|
/// Math.trunc(Math.min(high, Math.max(low, n))).
fn clamp_trunc(n : Double, low : Double, high : Double) -> Double {
  let x = if n < low { low } else { n }
  let y = if x > high { high } else { x }
  if y < 0.0 {
    y.ceil()
  } else {
    y.floor()
  }
}
