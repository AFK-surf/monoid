// The proleptic Gregorian calendar at UTC, of no dependency, on every target: days and milliseconds since
// 1970-01-01T00:00:00Z both ways (Howard Hinnant's `days_from_civil` and `civil_from_days`, exact for any year an
// Int holds), and ISO 8601 text as JavaScript's `Date` writes it (`toISOString`) and reads it (`Date.parse`'s
// date-time form). What a program on this library tells time in, never a copy of its own.

///|
let ms_per_day : Int64 = 86_400_000L

///|
/// A moment's fields at UTC: `month` 1 to 12, `day` 1 to 31, `hour` 0 to 23, `minute` and `second` 0 to 59, `ms` 0 to
/// 999. `year` is astronomical: 0 is 1 BC, -1 is 2 BC. Shown as `toISOString` writes it.
#derive(Eq, Debug)
pub(all) struct UtcParts {
  year : Int
  month : Int
  day : Int
  hour : Int
  minute : Int
  second : Int
  ms : Int
}

///|
pub impl Show for UtcParts with output(self, logger) {
  let out = StringBuilder(capacity=24)
  write_date(out, self)
  write_time(out, self)
  out.write_char('.')
  pad(out, self.ms, 3)
  out.write_char('Z')
  logger.write_string(out.to_string())
}

///|
/// `a` divided by `b` (positive), rounded toward minus infinity.
fn floor_div(a : Int64, b : Int64) -> Int64 {
  let q = a / b
  if a % b < 0L {
    q - 1L
  } else {
    q
  }
}

///|
/// The date `z` days after 1970-01-01 (before it where negative): `(year, month 1..12, day 1..31)`.
pub fn civil_from_days(z : Int64) -> (Int, Int, Int) {
  let z = z + 719468L
  let era = floor_div(z, 146097L)
  let doe = z - era * 146097L // 0 to 146096
  let yoe = (doe - doe / 1460L + doe / 36524L - doe / 146096L) / 365L // 0 to 399
  let doy = doe - (365L * yoe + yoe / 4L - yoe / 100L) // 0 to 365, from March 1st
  let mp = (5L * doy + 2L) / 153L // 0 to 11, from March
  let day = doy - (153L * mp + 2L) / 5L + 1L
  let month = if mp < 10L { mp + 3L } else { mp - 9L }
  let year = yoe + era * 400L + (if month <= 2L { 1L } else { 0L })
  (year.to_int(), month.to_int(), day.to_int())
}

///|
/// How many days `year-month-day` is after 1970-01-01 (negative before it): `civil_from_days`'s inverse for every
/// date there is. A `day` past its month's end counts on into the next (`day` 0 is the day before the 1st), as
/// `Date.UTC` does; `month` must be 1 to 12.
pub fn days_from_civil(year : Int, month : Int, day : Int) -> Int64 {
  let y = year.to_int64() - (if month <= 2 { 1L } else { 0L })
  let era = floor_div(y, 400L)
  let yoe = y - era * 400L // 0 to 399
  let mp = (if month > 2 { month - 3 } else { month + 9 }).to_int64() // 0 to 11, from March
  let doy = (153L * mp + 2L) / 5L + day.to_int64() - 1L
  let doe = yoe * 365L + yoe / 4L - yoe / 100L + doy
  era * 146097L + doe - 719468L
}

///|
/// The fields at UTC of the moment `ms` milliseconds after 1970-01-01T00:00:00Z (before it where negative): what
/// `Date`'s `getUTC*` say.
pub fn utc_parts(ms : Int64) -> UtcParts {
  let days = floor_div(ms, ms_per_day)
  let of_day = (ms - days * ms_per_day).to_int()
  let (year, month, day) = civil_from_days(days)
  {
    year,
    month,
    day,
    hour: of_day / 3_600_000,
    minute: of_day / 60_000 % 60,
    second: of_day / 1000 % 60,
    ms: of_day % 1000,
  }
}

///|
/// The milliseconds since 1970-01-01T00:00:00Z of the moment given at UTC, as `Date.UTC(year, month - 1, …)` (but
/// with `month` from 1): a field past its range counts on into the next (month 13 is the next year's January, hour
/// 24 the next day's midnight, `minute` -1 the minute before), never refused.
pub fn utc_ms(
  year : Int,
  month : Int,
  day : Int,
  hour? : Int = 0,
  minute? : Int = 0,
  second? : Int = 0,
  ms? : Int = 0,
) -> Int64 {
  let months = year.to_int64() * 12L + month.to_int64() - 1L
  let y = floor_div(months, 12L)
  let m = (months - y * 12L).to_int() + 1
  days_from_civil(y.to_int(), m, day) * ms_per_day +
  hour.to_int64() * 3_600_000L +
  minute.to_int64() * 60_000L +
  second.to_int64() * 1000L +
  ms.to_int64()
}

///|
/// `n` (not negative) in `width` digits at least, zeros before it.
fn pad(out : StringBuilder, n : Int, width : Int) -> Unit {
  let digits = n.to_string()
  for _ in digits.length()..<width {
    out.write_char('0')
  }
  out.write_string(digits)
}

///|
/// The date's part, as `toISOString` writes its year: four digits from 0 to 9999, a sign and six past them.
fn write_date(out : StringBuilder, p : UtcParts) -> Unit {
  if p.year >= 0 && p.year <= 9999 {
    pad(out, p.year, 4)
  } else {
    out.write_char(if p.year < 0 { '-' } else { '+' })
    pad(out, p.year.abs(), 6)
  }
  out.write_char('-')
  pad(out, p.month, 2)
  out.write_char('-')
  pad(out, p.day, 2)
}

///|
fn write_time(out : StringBuilder, p : UtcParts) -> Unit {
  out.write_char('T')
  pad(out, p.hour, 2)
  out.write_char(':')
  pad(out, p.minute, 2)
  out.write_char(':')
  pad(out, p.second, 2)
}

///|
/// The moment `ms` as `new Date(ms).toISOString()` writes it: `YYYY-MM-DDTHH:MM:SS.sssZ`, the year as `±YYYYYY`
/// outside 0 to 9999. (Where `Date` throws, past ±8.64e15, this writes on all the same.)
pub fn format_iso_ms(ms : Int64) -> String {
  let p = utc_parts(ms)
  let out = StringBuilder(capacity=24)
  write_date(out, p)
  write_time(out, p)
  out.write_char('.')
  pad(out, p.ms, 3)
  out.write_char('Z')
  out.to_string()
}

///|
/// The moment `ms` to the second, its milliseconds left out (not rounded): `YYYY-MM-DDTHH:MM:SSZ`.
pub fn format_iso_sec(ms : Int64) -> String {
  let p = utc_parts(ms)
  let out = StringBuilder(capacity=20)
  write_date(out, p)
  write_time(out, p)
  out.write_char('Z')
  out.to_string()
}

///|
/// The day of the moment `ms` at UTC: `YYYY-MM-DD`.
pub fn format_ymd(ms : Int64) -> String {
  let out = StringBuilder(capacity=10)
  write_date(out, utc_parts(ms))
  out.to_string()
}

///|
/// A reader of ISO 8601 text, a code unit at a time.
priv struct Reader {
  text : String
  mut at : Int
}

///|
fn Reader::peek(self : Reader) -> Int {
  if self.at < self.text.length() {
    self.text.unsafe_get(self.at).to_int()
  } else {
    -1
  }
}

///|
/// Takes `c` where it is next.
fn Reader::take(self : Reader, c : Char) -> Bool {
  if self.peek() == c.to_int() {
    self.at += 1
    true
  } else {
    false
  }
}

///|
/// Exactly `n` decimal digits' value.
fn Reader::digits(self : Reader, n : Int) -> Int? {
  let mut v = 0
  for _ in 0..<n {
    let c = self.peek()
    if c < '0'.to_int() || c > '9'.to_int() {
      return None
    }
    v = v * 10 + (c - '0'.to_int())
    self.at += 1
  }
  Some(v)
}

///|
fn leap(year : Int) -> Bool {
  (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

///|
fn month_days(year : Int, month : Int) -> Int {
  match month {
    2 => if leap(year) { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
}

///|
/// The milliseconds since 1970-01-01T00:00:00Z of an ISO 8601 date or date-time, the forms `Date.parse` reads alike
/// on every engine: `YYYY-MM-DD` (midnight at UTC), or `YYYY-MM-DDTHH:MM`, with `:SS` and a fraction of any number
/// of digits after it optional (past milliseconds cut off, not rounded), then `Z`, `±HH:MM` or `±HHMM`; the year
/// four digits or, as `toISOString` writes it past them, a sign and six (`-000000` refused). Every field is held to
/// its range, February 29th to leap years, and `24:00` taken only as the next day's midnight (`24:00:00.000`).
/// `None` for anything else, a date-time with no zone too (`Date.parse` takes that for local time, which this does
/// not know).
pub fn parse_iso_ms(text : String) -> Int64? {
  let r : Reader = { text, at: 0 }
  let year = if r.take('+') {
    r.digits(6)
  } else if r.take('-') {
    match r.digits(6) {
      Some(0) | None => None
      Some(y) => Some(-y)
    }
  } else {
    r.digits(4)
  }
  guard year is Some(year) else { return None }
  guard r.take('-') && r.digits(2) is Some(month) && month >= 1 && month <= 12 else { return None }
  guard r.take('-') && r.digits(2) is Some(day) && day >= 1 && day <= month_days(year, month) else { return None }
  let days = days_from_civil(year, month, day)
  if r.at == text.length() {
    return Some(days * ms_per_day)
  }
  guard r.take('T') && r.digits(2) is Some(hour) && hour <= 24 else { return None }
  guard r.take(':') && r.digits(2) is Some(minute) && minute <= 59 else { return None }
  let mut second = 0
  let mut ms = 0
  if r.take(':') {
    guard r.digits(2) is Some(s) && s <= 59 else { return None }
    second = s
    if r.take('.') {
      let from = r.at
      let mut scale = 100
      while r.peek() >= '0'.to_int() && r.peek() <= '9'.to_int() {
        ms += (r.peek() - '0'.to_int()) * scale
        scale /= 10
        r.at += 1
      }
      if r.at == from {
        return None
      }
    }
  }
  if hour == 24 && (minute != 0 || second != 0 || ms != 0) {
    return None
  }
  let offset = if r.take('Z') {
    0
  } else {
    let sign = if r.take('+') {
      1
    } else if r.take('-') {
      -1
    } else {
      return None
    }
    guard r.digits(2) is Some(oh) && oh <= 23 else { return None }
    let _ = r.take(':')
    guard r.digits(2) is Some(om) && om <= 59 else { return None }
    sign * (oh * 60 + om)
  }
  if r.at != text.length() {
    return None
  }
  Some(
    days * ms_per_day +
    hour.to_int64() * 3_600_000L +
    (minute - offset).to_int64() * 60_000L +
    second.to_int64() * 1000L +
    ms.to_int64(),
  )
}
