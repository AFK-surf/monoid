// The calendar against what JavaScript's `Date` says (node 22's `toISOString` and `Date.parse`, each value below
// taken from it): the epoch and the millisecond before it, leap days, years before 1 and past 9999, `Date`'s own
// ends, offsets and fractions read; and days both ways over thousands of years. On both targets.

///|
/// [ms, `new Date(ms).toISOString()`]
let js_iso : Array[(Int64, String)] = [
  (0L, "1970-01-01T00:00:00.000Z"),
  (-1L, "1969-12-31T23:59:59.999Z"),
  (951782400000L, "2000-02-29T00:00:00.000Z"),
  (1709164800000L, "2024-02-29T00:00:00.000Z"),
  (1795080013798L, "2026-11-19T09:20:13.798Z"),
  (-2208988800001L, "1899-12-31T23:59:59.999Z"),
  (-62135596800000L, "0001-01-01T00:00:00.000Z"),
  (-62198755200000L, "-000001-01-01T00:00:00.000Z"),
  (253402300799999L, "9999-12-31T23:59:59.999Z"),
  (253402300800000L, "+010000-01-01T00:00:00.000Z"),
  (8640000000000000L, "+275760-09-13T00:00:00.000Z"),
  (-8640000000000000L, "-271821-04-20T00:00:00.000Z"),
]

///|
test "format_iso_ms writes what toISOString writes, and parse_iso_ms reads it back" {
  for one in js_iso {
    let (ms, iso) = one
    assert_eq(@time.format_iso_ms(ms), iso)
    assert_eq(@time.parse_iso_ms(iso), Some(ms))
    assert_eq("\{@time.utc_parts(ms)}", iso)
  }
}

///|
test "the seconds' and the day's forms cut the moment off, never round it" {
  assert_eq(@time.format_iso_sec(1795080013798L), "2026-11-19T09:20:13Z")
  assert_eq(@time.format_iso_sec(-1L), "1969-12-31T23:59:59Z")
  assert_eq(@time.format_ymd(1795080013798L), "2026-11-19")
  assert_eq(@time.format_ymd(-1L), "1969-12-31")
  assert_eq(@time.format_ymd(0L), "1970-01-01")
  assert_eq(@time.format_ymd(-62198755200000L), "-000001-01-01")
}

///|
test "utc_parts floors before the epoch" {
  assert_eq(@time.utc_parts(-1L), {
    year: 1969,
    month: 12,
    day: 31,
    hour: 23,
    minute: 59,
    second: 59,
    ms: 999,
  })
  assert_eq(@time.utc_parts(-86_400_000L), {
    year: 1969,
    month: 12,
    day: 31,
    hour: 0,
    minute: 0,
    second: 0,
    ms: 0,
  })
  assert_eq(@time.utc_parts(1795080013798L), {
    year: 2026,
    month: 11,
    day: 19,
    hour: 9,
    minute: 20,
    second: 13,
    ms: 798,
  })
}

///|
test "utc_ms is Date.UTC with months from 1, counting a field past its range on" {
  assert_eq(@time.utc_ms(1970, 1, 1), 0L)
  assert_eq(@time.utc_ms(2026, 11, 19, hour=9, minute=20, second=13, ms=798), 1795080013798L)
  assert_eq(@time.utc_ms(1969, 12, 31, hour=23, minute=59, second=59, ms=999), -1L)
  assert_eq(@time.utc_ms(2000, 2, 29), 951782400000L)
  // Date.UTC(2025, 12, 1), Date.UTC(2024, -1, 1), Date.UTC(2023, 1, 29), Date.UTC(2026, 10, 19, 24)
  assert_eq(@time.utc_ms(2025, 13, 1), 1767225600000L)
  assert_eq(@time.utc_ms(2024, 0, 1), 1701388800000L)
  assert_eq(@time.utc_ms(2023, 2, 29), 1677628800000L)
  assert_eq(@time.utc_ms(2026, 11, 19, hour=24), 1795132800000L)
  assert_eq(@time.utc_ms(2026, 11, 19, minute=-1), 1795046340000L)
}

///|
test "days_from_civil and civil_from_days are each other's inverse over 4,000 years either side" {
  // From 2,000 BC or so to 6,000 AD, every day, each the one after the day before.
  let mut prev = @time.civil_from_days(-1_500_001L)
  for z in -1_500_000L..<1_500_000L {
    let (y, m, d) = @time.civil_from_days(z)
    assert_true(m >= 1 && m <= 12 && d >= 1 && d <= 31)
    if @time.days_from_civil(y, m, d) != z {
      fail("\{z} is \{y}-\{m}-\{d}, which is \{@time.days_from_civil(y, m, d)}")
    }
    let (py, pm, pd) = prev
    let next = (y == py && m == pm && d == pd + 1) ||
      (y == py && m == pm + 1 && d == 1) ||
      (y == py + 1 && m == 1 && pm == 12 && d == 1)
    if !next {
      fail("\{py}-\{pm}-\{pd} is followed by \{y}-\{m}-\{d}")
    }
    prev = (y, m, d)
  }
  assert_eq(@time.civil_from_days(0L), (1970, 1, 1))
  assert_eq(@time.civil_from_days(-1L), (1969, 12, 31))
  assert_eq(@time.civil_from_days(11016L), (2000, 2, 29))
  assert_eq(@time.days_from_civil(2000, 3, 1), 11017L)
  // Far years, where Int holds them.
  for y in [-2_000_000_000, -1_000_000, -400, 0, 1_000_000, 2_000_000_000] {
    assert_eq(@time.civil_from_days(@time.days_from_civil(y, 2, 29 - (if y % 4 == 0 { 0 } else { 1 }))).0, y)
  }
}

///|
test "parse_iso_ms reads Date.parse's forms: dates, offsets and fractions of any length" {
  let cases : Array[(String, Int64)] = [
    ("2000-02-29", 951782400000L),
    ("2024-02-29T12:34Z", 1709210040000L),
    ("2026-11-19T18:20:13.798+09:00", 1795080013798L),
    ("2026-11-19T03:50:13.798-05:30", 1795080013798L),
    ("2026-11-19T18:20:13.798+0900", 1795080013798L),
    ("2026-11-19T09:20:13.5Z", 1795080013500L),
    ("2026-11-19T09:20:13.12Z", 1795080013120L),
    ("2026-11-19T09:20:13.123456Z", 1795080013123L),
    ("2026-11-19T24:00:00Z", 1795132800000L),
    ("2026-11-19T24:00Z", 1795132800000L),
    ("2026-11-19T24:00:00.000Z", 1795132800000L),
    ("-000001-01-01T00:00:00.000Z", -62198755200000L),
    ("1969-12-31T23:59:59.999Z", -1L),
  ]
  for one in cases {
    assert_eq(@time.parse_iso_ms(one.0), Some(one.1))
  }
}

///|
test "parse_iso_ms refuses what is out of range or not the form" {
  for text in [
    "", "2026", "2026-11", "1900-02-29", "2023-02-29", "2026-04-31", "2026-13-01", "2026-00-10", "2026-11-00",
    "2026-11-19T", "2026-11-19T09:20", "2026-11-19T09:20:13", "2026-11-19T25:00Z", "2026-11-19T09:60Z",
    "2026-11-19T09:20:60Z", "2026-11-19T24:00:01Z", "2026-11-19T24:00:00.001Z", "2026-11-19T09:20:13.Z",
    "2026-11-19T09:20:13.5", "2026-11-19T09:20:13+24:00", "2026-11-19T09:20:13+09:60", "2026-11-19T09:20:13+9:00",
    "2026-11-19T09:20:13Zjunk", "2026-11-19 09:20:13Z", "26-11-19", "+26-11-19", "-000000-01-01", "2026-1-19",
    " 2026-11-19", "2026-11-19Z",
  ] {
    assert_eq(@time.parse_iso_ms(text), None)
  }
}
