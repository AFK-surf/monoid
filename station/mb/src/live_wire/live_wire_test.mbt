///|
fn said(v : @jsjson.JValue) -> String {
  @jsjson.stringify(v)
}

///|
test "reads as JSON.parse reads" {
  let v = Some(
    @jsjson.JValue::Obj([
      ("a", @live_wire.jstr("x")),
      ("e", @live_wire.jstr("")),
      ("n", Null),
    ]),
  )
  assert_eq(@live_wire.str(@live_wire.field(v, "a")), Some("x"))
  assert_eq(
    @live_wire.str(@live_wire.field(Some(@live_wire.jstr("a")), "a")),
    None,
  )
  assert_eq(@live_wire.non_empty(@live_wire.field(v, "e")), None)
  assert_eq(
    @live_wire.non_empty(@live_wire.field(v, "a")),
    Some("x"),
  )
  assert_true(@live_wire.is_str(@live_wire.field(v, "a"), "x"))
  assert_false(@live_wire.is_str(@live_wire.field(v, "n"), "x"))
  assert_eq(
    said(@live_wire.or_else(@live_wire.field(v, "n"), @live_wire.jstr("f"))),
    "\"f\"",
  )
  assert_eq(
    said(
      @live_wire.or_else(@live_wire.field(v, "missing"), @live_wire.jstr("f")),
    ),
    "\"f\"",
  )
  assert_eq(
    said(@live_wire.or_else(@live_wire.field(v, "e"), @live_wire.jstr("f"))),
    "\"\"",
  )
  assert_true(@live_wire.has_prefix("mcp__x", "mcp__"))
  assert_false(@live_wire.has_prefix("mc", "mcp__"))
}

///|
test "pretty and joined" {
  assert_eq(@live_wire.pretty(None), "{}")
  assert_eq(@live_wire.pretty(Some(Null)), "{}")
  assert_eq(
    @live_wire.pretty(Some(@live_wire.obj([("a", Num(1.0))]))),
    "{\n  \"a\": 1\n}",
  )
  assert_eq(
    @live_wire.joined(["a", "", "b"], ", "),
    "a, , b",
  )
  assert_eq(@live_wire.joined([], ","), "")
}

///|
test "live events" {
  assert_eq(
    said(@live_wire.start("1", "tool", None, None)),
    "{\"kind\":\"start\",\"id\":\"1\",\"step\":\"tool\"}",
  )
  assert_eq(
    said(@live_wire.start("1", "tool", Some("Bash"), Some("ls"))),
    "{\"kind\":\"start\",\"id\":\"1\",\"step\":\"tool\",\"tool\":\"Bash\",\"input\":\"ls\"}",
  )
  assert_eq(
    said(@live_wire.delta("1", "text", "hi")),
    "{\"kind\":\"delta\",\"id\":\"1\",\"field\":\"text\",\"text\":\"hi\"}",
  )
  assert_eq(
    said(@live_wire.live(@live_wire.end_event("1"))),
    "{\"type\":\"live\",\"event\":{\"kind\":\"end\",\"id\":\"1\"}}",
  )
  assert_eq(
    said(@live_wire.failed("model", "x")),
    "{\"kind\":\"failed\",\"reason\":\"model\",\"message\":\"x\"}",
  )
  assert_eq(@live_wire.INPUT_MOST, 262144)
}
