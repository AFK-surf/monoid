// Proleptic Gregorian calendar & ECMA-262 Date ISO 8601 conformance tests for @time.

///|
test "conformance: leap years (1900 non-leap, 2000 leap, 2024 leap, 2100 non-leap, 0 leap) and Y2038" {
  // 1900 is NOT a leap year: 1900-02-28 + 1 day == 1900-03-01
  let d1900 = @time.days_from_civil(1900, 2, 28)
  assert_eq(@time.civil_from_days(d1900 + 1L), (1900, 3, 1))
  assert_eq(@time.parse_iso_ms("1900-02-29"), None)
  assert_eq(@time.parse_iso_ms("1900-02-28"), Some(-2203977600000L))
  // 2000 IS a leap year (divisible by 400)
  let d2000 = @time.days_from_civil(2000, 2, 28)
  assert_eq(@time.civil_from_days(d2000 + 1L), (2000, 2, 29))
  assert_eq(@time.civil_from_days(d2000 + 2L), (2000, 3, 1))
  assert_eq(@time.parse_iso_ms("2000-02-29"), Some(951782400000L))
  // 2024 IS a leap year
  assert_eq(@time.civil_from_days(@time.days_from_civil(2024, 2, 28) + 1L), (2024, 2, 29))
  assert_eq(@time.parse_iso_ms("2024-02-29"), Some(1709164800000L))
  // 2100 is NOT a leap year (divisible by 100 but not 400)
  assert_eq(@time.civil_from_days(@time.days_from_civil(2100, 2, 28) + 1L), (2100, 3, 1))
  assert_eq(@time.parse_iso_ms("2100-02-29"), None)
  // Astronomical year 0 (1 BC) IS a leap year (0 % 400 == 0); year -1 (2 BC) is NOT
  assert_eq(@time.civil_from_days(@time.days_from_civil(0, 2, 28) + 1L), (0, 2, 29))
  assert_eq(@time.parse_iso_ms("0000-02-29"), Some(-62162121600000L))
  assert_eq(@time.parse_iso_ms("-000001-02-29"), None)
  assert_eq(@time.parse_iso_ms("-000004-02-29") is Some(_), true)
  // Y2038 signed 32-bit Unix timestamp overflow boundary: 2038-01-19T03:14:07Z and +1s
  assert_eq(@time.format_iso_ms(2147483647000L), "2038-01-19T03:14:07.000Z")
  assert_eq(@time.format_iso_ms(2147483648000L), "2038-01-19T03:14:08.000Z")
  assert_eq(@time.parse_iso_ms("2038-01-19T03:14:08.000Z"), Some(2147483648000L))
}

///|
test "conformance: negative timestamps before 1970-01-01 and sub-day floor semantics" {
  // -1ms, -999ms, -1000ms, -1001ms, -86400000ms, -86400001ms
  let cases : Array[(Int64, String)] = [
    (-1L, "1969-12-31T23:59:59.999Z"),
    (-999L, "1969-12-31T23:59:59.001Z"),
    (-1000L, "1969-12-31T23:59:59.000Z"),
    (-1001L, "1969-12-31T23:59:58.999Z"),
    (-86400000L, "1969-12-31T00:00:00.000Z"),
    (-86400001L, "1969-12-30T23:59:59.999Z"),
    (-31536000000L, "1969-01-01T00:00:00.000Z"),
    (-63158400000L, "1968-01-01T00:00:00.000Z"),
  ]
  for c in cases {
    assert_eq(@time.format_iso_ms(c.0), c.1)
    assert_eq(@time.parse_iso_ms(c.1), Some(c.0))
  }
}

///|
test "conformance: extreme ECMA-262 Date boundaries and utc_ms overflow/underflow normalization" {
  // ECMA-262 TimeClip bounds: ±8,640,000,000,000,000 ms
  assert_eq(@time.format_iso_ms(8640000000000000L), "+275760-09-13T00:00:00.000Z")
  assert_eq(@time.parse_iso_ms("+275760-09-13T00:00:00.000Z"), Some(8640000000000000L))
  assert_eq(@time.format_iso_ms(-8640000000000000L), "-271821-04-20T00:00:00.000Z")
  assert_eq(@time.parse_iso_ms("-271821-04-20T00:00:00.000Z"), Some(-8640000000000000L))
  // Year 0000 and +000000
  assert_eq(@time.format_iso_ms(-62167219200000L), "0000-01-01T00:00:00.000Z")
  assert_eq(@time.parse_iso_ms("0000-01-01T00:00:00.000Z"), Some(-62167219200000L))
  assert_eq(@time.parse_iso_ms("+000000-01-01T00:00:00.000Z"), Some(-62167219200000L))
  assert_eq(@time.parse_iso_ms("-000000-01-01T00:00:00.000Z"), None)
  // utc_ms normalization: month underflow/overflow, day 0, negative ms
  assert_eq(@time.utc_ms(1970, 1, 0), -86400000L)
  assert_eq(@time.utc_ms(1970, 0, 1), @time.utc_ms(1969, 12, 1))
  assert_eq(@time.utc_ms(1970, -11, 1), @time.utc_ms(1969, 1, 1))
  assert_eq(@time.utc_ms(1970, 1, 1, ms=-1), -1L)
  assert_eq(@time.utc_ms(2024, 1, 1, hour=0, minute=0, second=0, ms=86400000), @time.utc_ms(2024, 1, 2))
  // ISO offsets across date boundary (e.g. +23:59 and -23:59)
  assert_eq(@time.parse_iso_ms("1970-01-01T23:59:00+23:59"), Some(0L))
  assert_eq(@time.parse_iso_ms("1969-12-31T00:01:00-23:59"), Some(0L))
  // Fractional seconds truncation (not rounding)
  assert_eq(@time.parse_iso_ms("1970-01-01T00:00:00.999999999Z"), Some(999L))
  assert_eq(@time.parse_iso_ms("1970-01-01T00:00:00.1Z"), Some(100L))
  assert_eq(@time.parse_iso_ms("1970-01-01T00:00:00.01Z"), Some(10L))
  assert_eq(@time.parse_iso_ms("1970-01-01T00:00:00.001Z"), Some(1L))
}
