// Dates as JavaScript writes and reads them: `new Date(ms).toISOString()` and `Date.parse` of an ISO 8601 date and time.

///|
/// `new Date(ms).toISOString()`.
pub fn iso_string(ms : Double) -> String {
  @jsjson.js_iso(ms)
}

///|
/// `Date.parse` of an ISO 8601 date (and time): its ms, NaN where it is none. A date and time with no offset is taken
/// as UTC (JavaScript takes it as the machine's local time; the sign-ins read here always say their offset).
pub fn date_parse(s : String) -> Double {
  @jsjson.js_parse_iso(s, strict_day=true, space_sep=true).unwrap_or(@double.not_a_number)
}
