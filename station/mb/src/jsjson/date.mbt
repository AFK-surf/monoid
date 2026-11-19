// JavaScript `Date` formatting (`toISOString`) and parsing (`Date.parse` for ISO 8601 and HTTP/RFC 2822 dates),
// built on `base/time`.

///|
/// `new Date(ms).toISOString()` for a valid JS time value (`|trunc(ms)| <= 8.64e15`).
pub fn js_iso(ms : Double) -> String {
  @time.format_iso_ms(js_trunc(ms).to_int64())
}

///|
/// `new Date(ms).toISOString()`: `None` for NaN, ±Inf, or values past ±8.64e15 where JS throws RangeError.
pub fn js_iso_checked(ms : Double) -> String? {
  if !is_finite(ms) {
    return None
  }
  let t = js_trunc(ms)
  if t.abs() > 8.64e15 {
    return None
  }
  Some(@time.format_iso_ms(t.to_int64()))
}

///|
/// `Date.parse` of an ISO 8601 date or date-time string: `YYYY`, `YYYY-MM`, `YYYY-MM-DD`, or `±YYYYYY…`, with
/// optional `T`/`t` (or space when `space_sep=true`) time `HH:MM[:SS[(.|,)frac]]` and optional `Z`/`z`/`±HH[:]MM`.
/// When a time has no zone, `tz_offset_ms` supplies the local offset (default UTC).
/// When `strict_day=true`, out-of-month days (e.g. Feb 30) are rejected; otherwise V8 rollover (day 1..31) applies.
pub fn js_parse_iso(
  s : String,
  tz_offset_ms? : (Double) -> Double,
  strict_day? : Bool = false,
  space_sep? : Bool = false,
) -> Double? {
  let n = s.length()
  let mut i = 0
  let digits = (count : Int) => {
    if i + count > n {
      return None
    }
    let mut v = 0
    for k in 0..<count {
      let c = s.unsafe_get(i + k).to_int()
      if c < '0' || c > '9' {
        return None
      }
      v = v * 10 + (c - '0')
    }
    i += count
    Some(v)
  }
  let at = (c : Int) => i < n && s.unsafe_get(i).to_int() == c
  let year = if at('+') || at('-') {
    let neg = at('-')
    i += 1
    guard digits(6) is Some(y) else { return None }
    if neg && y == 0 {
      return None
    }
    if neg { -y } else { y }
  } else {
    guard digits(4) is Some(y) else { return None }
    y
  }
  let mut month = 1
  let mut day = 1
  if at('-') {
    i += 1
    guard digits(2) is Some(m) else { return None }
    month = m
    if at('-') {
      i += 1
      guard digits(2) is Some(d) else { return None }
      day = d
    }
  }
  let mut hour = 0
  let mut minute = 0
  let mut second = 0
  let mut ms = 0
  let mut offset_ms = 0.0
  let mut has_time = false
  let mut has_zone = false
  if at('T') || at('t') || (space_sep && at(' ')) {
    has_time = true
    i += 1
    guard digits(2) is Some(h) else { return None }
    guard at(':') else { return None }
    i += 1
    guard digits(2) is Some(mi) else { return None }
    hour = h
    minute = mi
    if at(':') {
      i += 1
      guard digits(2) is Some(sec) else { return None }
      second = sec
      if at('.') || at(',') {
        i += 1
        let start = i
        let mut frac = 0
        let mut count = 0
        while i < n && s.unsafe_get(i).to_int() >= '0' && s.unsafe_get(i).to_int() <= '9' {
          if count < 3 {
            frac = frac * 10 + (s.unsafe_get(i).to_int() - '0')
            count += 1
          }
          i += 1
        }
        if i == start {
          return None
        }
        while count < 3 {
          frac *= 10
          count += 1
        }
        ms = frac
      }
    }
    if at('Z') || at('z') {
      has_zone = true
      i += 1
    } else if at('+') || at('-') {
      has_zone = true
      let sg = if at('-') { -1 } else { 1 }
      i += 1
      guard digits(2) is Some(oh) else { return None }
      if at(':') {
        i += 1
      }
      guard digits(2) is Some(om) else { return None }
      if oh > 23 || om > 59 {
        return None
      }
      offset_ms = (sg * (oh * 60 + om)).to_double() * 60_000.0
    }
  }
  if i != n {
    return None
  }
  if month < 1 || month > 12 || day < 1 || day > 31 || hour > 24 || minute > 59 || second > 59 {
    return None
  }
  if hour == 24 && (minute != 0 || second != 0 || ms != 0) {
    return None
  }
  let days = @time.days_from_civil(year, month, day)
  if strict_day {
    let (_, m2, _) = @time.civil_from_days(days)
    if m2 != month {
      return None
    }
  }
  let local_ms = days.to_double() * 86_400_000.0 +
    hour.to_double() * 3_600_000.0 +
    minute.to_double() * 60_000.0 +
    second.to_double() * 1000.0 +
    ms.to_double()
  let t = if has_time && !has_zone {
    match tz_offset_ms {
      Some(f) => local_ms - f(local_ms)
      None => local_ms
    }
  } else {
    local_ms - offset_ms
  }
  if t.abs() > 8.64e15 {
    None
  } else {
    Some(t)
  }
}

///|
fn parse_small_uint(s : String) -> Int? {
  if s == "" || s.length() > 6 || !js_all_digits(s) {
    return None
  }
  let mut n = 0
  for i in 0..<s.length() {
    n = n * 10 + (s.unsafe_get(i).to_int() - '0')
  }
  Some(n)
}

///|
/// `Date.parse` of an HTTP / IMF-fixdate string (`Tue, 17 Nov 2026 04:22:23 GMT`): its milliseconds, or `None`.
pub fn js_parse_http_date(s : String) -> Double? {
  let parts = trim_js(s).split(" ").filter(p => p != "").map(p => p.to_owned()).to_array()
  let p = if parts.length() > 0 && parts[0].has_suffix(",") { parts[1:].to_owned() } else { parts }
  if p.length() < 4 {
    return None
  }
  let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
  let month = match months.search(p[1].to_lower()) {
    Some(m) => m + 1
    None => return None
  }
  let hms = p[3].split(":").map(x => x.to_owned()).to_array()
  if hms.length() < 2 || hms.length() > 3 {
    return None
  }
  let zone = if p.length() > 4 { p[4] } else { "GMT" }
  guard zone is ("GMT" | "UTC" | "UT" | "Z") else { return None }
  match (
    parse_small_uint(p[0]),
    parse_small_uint(p[2]),
    parse_small_uint(hms[0]),
    parse_small_uint(hms[1]),
    if hms.length() == 3 { parse_small_uint(hms[2]) } else { Some(0) },
  ) {
    (Some(d), Some(y), Some(hh), Some(mm), Some(ss)) if d >= 1 && d <= 31 && hh < 24 && mm < 60 && ss < 60 =>
      Some(@time.utc_ms(y, month, d, hour=hh, minute=mm, second=ss).to_double())
    _ => None
  }
}

///|
/// `Date.parse` covering ISO 8601 (with space separator) and HTTP/RFC 2822 dates.
pub fn js_date_parse(
  s : String,
  tz_offset_ms? : (Double) -> Double,
  strict_day? : Bool = false,
) -> Double? {
  match js_parse_iso(s, tz_offset_ms?, strict_day~, space_sep=true) {
    Some(t) => Some(t)
    None => js_parse_http_date(s)
  }
}
