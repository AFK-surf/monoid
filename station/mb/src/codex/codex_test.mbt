// What the program makes of a Codex thread's notifications (live.mbt, outcome.mbt) against what the TypeScript station
// made of the same ones (as_typescript_said_test.mbt): the same events, written the same, the same live steps after
// each, the same reason for each failure.

///|
fn same(said : String) -> String {
  @jsjson.stringify(@jsjson.parse(said)) catch { _ => "(not JSON: \{said})" }
}

///|
test "each notification's events and live steps, as the TypeScript station said them" {
  let live = Live::new()
  for i, n in notices_said {
    let (method, params, said, state) = n
    let got = events(live, method, @jsjson.parse(params))
    assert_eq(@jsjson.stringify(Arr(got)), same(said), msg="notice \{i} (\{method}): its events")
    assert_eq(@jsjson.stringify(live.state()), same(state), msg="notice \{i} (\{method}): the live steps after it")
    // (what a station taking it up goes on from is the same)
    assert_eq(@jsjson.stringify(Live::of_state(live.state()).state()), same(state))
  }
}

///|
test "each failure's reason, as the TypeScript station said it" {
  for i, e in errors_said {
    let (info, message, reason) = e
    let message = match @jsjson.parse(message) {
      Str(m) => m
      _ => abort("a message is a string")
    }
    assert_eq(classify_error(Some(@jsjson.parse(info)), message), reason, msg="error \{i}: \{info} \{message}")
  }
}

///|
test "the live steps of a station from before, and none" {
  let live = Live::of_state(@jsjson.parse("{\"open\":[\"a\",\"b\",\"a\"],\"phase\":\"working\"}"))
  assert_eq(@jsjson.stringify(live.state()), "{\"open\":[\"a\",\"b\"],\"phase\":\"working\"}")
  assert_eq(@jsjson.stringify(Live::of_state(Null).state()), "{\"open\":[],\"phase\":null}")
}
