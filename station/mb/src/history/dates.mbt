///|
/// Date.parse of a timestamp as transcripts write it (ECMAScript's date time string format: a date, a time, `Z` or an
/// offset), its milliseconds; none for anything else (V8 reads some other forms too: no transcript writes them).
/// A date and time without an offset is read as UTC (JavaScript reads it in the machine's zone: no transcript writes
/// one).
pub fn date_parse(s : String) -> Double? {
  @jsjson.js_parse_iso(s, strict_day=true)
}
