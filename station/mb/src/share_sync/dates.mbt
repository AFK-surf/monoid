// Dates as JavaScript writes and reads them: `new Date(ms).toISOString()` and `Date.parse` of an ISO 8601 date and time.

///|
fn days_from_civil(y : Int64, m : Int64, d : Int64) -> Int64 {
  let y = if m <= 2L { y - 1L } else { y }
  let era = (if y >= 0L { y } else { y - 399L }) / 400L
  let yoe = y - era * 400L
  let mp = (m + 9L) % 12L
  let doy = (153L * mp + 2L) / 5L + d - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
fn civil_from_days(z : Int64) -> (Int64, Int64, Int64) {
  let z = z + 719468L
  let era = (if z >= 0L { z } else { z - 146096L }) / 146097L
  let doe = z - era * 146097L
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L
  let y = yoe + era * 400L
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L)
  let mp = (5L * doy + 2L) / 153L
  let d = doy - (153L * mp + 2L) / 5L + 1L
  let m = if mp < 10L { mp + 3L } else { mp - 9L }
  (if m <= 2L { y + 1L } else { y }, m, d)
}

///|
fn pad(n : Int64, width : Int) -> String {
  let s = n.abs().to_string()
  let p = if s.length() < width { "0".repeat(width - s.length()) + s } else { s }
  if n < 0L {
    "-" + p
  } else {
    p
  }
}

///|
/// `new Date(ms).toISOString()`.
pub fn iso_string(ms : Double) -> String {
  let t = ms.to_int64()
  let days = (if t >= 0L { t } else { t - 86399999L }) / 86400000L
  let rest = t - days * 86400000L
  let (y, m, d) = civil_from_days(days)
  let year = if y >= 0L && y <= 9999L {
    pad(y, 4)
  } else if y < 0L {
    "-" + pad(-y, 6)
  } else {
    "+" + pad(y, 6)
  }
  "\{year}-\{pad(m, 2)}-\{pad(d, 2)}T\{pad(rest / 3600000L, 2)}:\{pad(rest / 60000L % 60L, 2)}:\{pad(rest / 1000L % 60L, 2)}.\{pad(rest % 1000L, 3)}Z"
}

///|
/// `Date.parse` of an ISO 8601 date (and time): its ms, NaN where it is none. A date and time with no offset is taken
/// as UTC (JavaScript takes it as the machine's local time; the sign-ins read here always say their offset).
pub fn date_parse(s : String) -> Double {
  let cs = s.to_array()
  let n = cs.length()
  let pos = Ref(0)
  let digits = fn(count : Int) -> Int64? {
    if pos.val + count > n {
      return None
    }
    let mut v = 0L
    for k in 0..<count {
      let c = cs[pos.val + k]
      guard c >= '0' && c <= '9' else { return None }
      v = v * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    pos.val += count
    Some(v)
  }
  let at = fn(c : Char) -> Bool {
    if pos.val < n && cs[pos.val] == c {
      pos.val += 1
      true
    } else {
      false
    }
  }
  let nan = @double.not_a_number
  let sign = if pos.val < n && (cs[pos.val] == '+' || cs[pos.val] == '-') {
    let neg = cs[pos.val] == '-'
    pos.val += 1
    Some(neg)
  } else {
    None
  }
  let year = match sign {
    Some(neg) =>
      match digits(6) {
        Some(y) => if neg { -y } else { y }
        None => return nan
      }
    None =>
      match digits(4) {
        Some(y) => y
        None => return nan
      }
  }
  let mut month = 1L
  let mut day = 1L
  if at('-') {
    guard digits(2) is Some(m) else { return nan }
    month = m
    if at('-') {
      guard digits(2) is Some(d) else { return nan }
      day = d
    }
  }
  let mut hour = 0L
  let mut minute = 0L
  let mut second = 0L
  let mut ms = 0L
  let mut offset = 0L
  if pos.val < n && (cs[pos.val] == 'T' || cs[pos.val] == 't' || cs[pos.val] == ' ') {
    pos.val += 1
    guard digits(2) is Some(h) else { return nan }
    guard at(':') else { return nan }
    guard digits(2) is Some(mi) else { return nan }
    hour = h
    minute = mi
    if at(':') {
      guard digits(2) is Some(se) else { return nan }
      second = se
      if at('.') || at(',') {
        let start = pos.val
        let mut frac = 0L
        let mut taken = 0
        while pos.val < n && cs[pos.val] >= '0' && cs[pos.val] <= '9' {
          if taken < 3 {
            frac = frac * 10L + (cs[pos.val].to_int() - '0'.to_int()).to_int64()
            taken += 1
          }
          pos.val += 1
        }
        if pos.val == start {
          return nan
        }
        while taken < 3 {
          frac = frac * 10L
          taken += 1
        }
        ms = frac
      }
    }
    if at('Z') || at('z') {
      ()
    } else if pos.val < n && (cs[pos.val] == '+' || cs[pos.val] == '-') {
      let neg = cs[pos.val] == '-'
      pos.val += 1
      guard digits(2) is Some(oh) else { return nan }
      ignore(at(':'))
      guard digits(2) is Some(om) else { return nan }
      offset = (oh * 60L + om) * 60000L
      if neg {
        offset = -offset
      }
    }
  }
  if pos.val != n || month < 1L || month > 12L || day < 1L || day > 31L || hour > 24L || minute > 59L || second > 59L {
    return nan
  }
  if hour == 24L && (minute != 0L || second != 0L || ms != 0L) {
    return nan
  }
  let days = days_from_civil(year, month, day)
  let (_, m2, _) = civil_from_days(days)
  if m2 != month {
    // (the 31st of a month of 30: JavaScript's ISO parse refuses it)
    return nan
  }
  (days * 86400000L + hour * 3600000L + minute * 60000L + second * 1000L + ms - offset).to_double()
}
