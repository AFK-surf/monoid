// What of the package runs without a host or a database, as JavaScript has it (the rest is held to the TypeScript by
// station/test/mb-session-hub.test.ts, through the program).

///|
test "iso as toISOString writes it" {
  assert_eq(iso(0.0), "1970-01-01T00:00:00.000Z")
  assert_eq(iso(1_800_000_000_123.0), "2027-01-15T08:00:00.123Z")
  assert_eq(iso(-1.0), "1969-12-31T23:59:59.999Z")
}

///|
test "numbers as String() writes them" {
  assert_eq(js_number_text(1.0), "1")
  assert_eq(js_number_text(0.5), "0.5")
  assert_eq(js_number_text(-0.0), "0")
  assert_eq(js_number_text(@double.not_a_number), "NaN")
  assert_eq(js_string(Json::null()), "null")
  assert_eq(js_string([1, "a"]), "[1,\"a\"]")
}

///|
test "a ts given only goes up" {
  let a = next_ts_at(1_800_000_000_000.0)
  let b = next_ts_at(1_800_000_000_000.0)
  assert_true(a < b)
  assert_eq(next_ts_at(1_900_000_000_000.5).length(), 17)
}

///|
test "bytes as base64url, unpadded" {
  assert_eq(base64url([]), "")
  assert_eq(base64url([0xfb, 0xff]), "-_8")
  assert_eq(base64url([104, 105, 33]), "aGkh")
}

///|
test "a thread's commands and a reason given" {
  assert_eq(thread_command(" <@U1> -STOP "), Some("stop"))
  assert_eq(thread_command("<@U-1> -stop"), None)
  assert_true(is_reason("已合进 main 82f108a5"))
  assert_true(!is_reason("Done!"))
  assert_eq(model_name("anthropic/claude-opus-5-5"), "Opus 5.5")
}

///|
test "a stable sort keeps ties in order" {
  let xs = [(1, "a"), (0, "b"), (1, "c"), (0, "d")]
  assert_eq(stable_sort(xs, (a, b) => a.0 - b.0).map(x => x.1), ["b", "d", "a", "c"])
}
