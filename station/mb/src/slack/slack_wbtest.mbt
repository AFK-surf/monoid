// The package's own pieces where station/test/mb-slack.test.ts does not reach them one by one: a form as
// URLSearchParams writes it, a header as `Headers.get` reads it, an HTTP date as `Date.parse` takes it, and a socket's
// stop. (Nothing here reaches the shell: a test of the package links no shell.) The values are Node's (`new
// URLSearchParams(…).toString()`, `Date.parse`).

///|
test "a form is written as URLSearchParams writes it" {
  assert_eq(
    form_encoded([("a b", "x*y~z!"), ("k", "中\n&=")]),
    "a+b=x*y%7Ez%21&k=%E4%B8%AD%0A%26%3D",
  )
  assert_eq(form_encoded([]), "")
}

///|
test "a header is read by its name in any case, several joined" {
  let h = [("Date", "one"), ("x-oauth-scopes", "a"), ("date", "two")]
  assert_eq(header(h, "DATE"), Some("one, two"))
  assert_eq(header(h, "X-OAuth-Scopes"), Some("a"))
  assert_eq(header(h, "retry-after"), None)
}

///|
test "an HTTP date is taken as Date.parse takes it" {
  assert_eq(http_date("Tue, 17 Nov 2026 04:22:23 GMT"), Some(1794889343000.0))
  assert_eq(http_date("Sun, 06 Nov 1994 08:49:37 GMT"), Some(784111777000.0))
  assert_eq(http_date("nonsense"), None)
}

///|
test "an agent session's stop is taken only with its thread and a plain time" {
  let stop = (ts : String) => to_event(
    Some(
      jo([
        ("type", js("agent_session_stopped")),
        ("channel", js("C1")),
        ("thread_ts", js("10.0")),
        ("event_ts", js(ts)),
      ]),
    ),
    "UB",
    "B1",
  )
  assert_eq(
    stop("1794889343.000100").map(stringify),
    Some(
      "{\"type\":\"stop\",\"channel\":\"C1\",\"threadTs\":\"10.0\",\"ts\":\"1794889343.000100\"}",
    ),
  )
  assert_eq(stop("soon").map(stringify), None)
  assert_eq(stop("").map(stringify), None)
}

///|
test "chat.update's text is cut to 3,500 bytes as Slack counts them at a whole character, \"…\" after it" {
  assert_eq(update_text("短"), "短")
  let fits = "长".repeat(1166) + "aa"
  assert_eq(update_text(fits), fits)
  // (the rocket's four bytes after 3,495 would cross the 3,497 kept before "…")
  let long = "长".repeat(1165) + "🚀" + "长".repeat(1267)
  assert_eq(update_text(long), "长".repeat(1165) + "…")
  assert_eq(update_text("a".repeat(3501)), "a".repeat(3497) + "…")
  assert_eq(update_text("a".repeat(3496) + "🚀" + "b"), "a".repeat(3496) + "…")
  assert_eq(update_text("a".repeat(3493) + "🚀" + "b".repeat(9)), "a".repeat(3493) + "🚀" + "…")
  // `&`, `<` and `>` counted as Slack escapes them: five bytes and four
  assert_eq(update_text("&".repeat(700)), "&".repeat(700))
  assert_eq(update_text("&".repeat(701)), "&".repeat(699) + "…")
  assert_eq(update_text("<".repeat(875)), "<".repeat(875))
  assert_eq(update_text("<".repeat(876)), "<".repeat(874) + "…")
  assert_eq(update_text(">".repeat(876)), ">".repeat(874) + "…")
  // the shorter cut of a second try
  assert_eq(update_text("a".repeat(200), max_bytes=200), "a".repeat(200))
  assert_eq(update_text("a".repeat(201), max_bytes=200), "a".repeat(197) + "…")
  assert_eq(update_text("&".repeat(41), max_bytes=200), "&".repeat(39) + "…")
}
