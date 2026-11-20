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

///|
test "entry state machine helpers" {
  let open : Array[(String, String)] = []
  @live_wire.set_entry(open, "a#0", "text")
  @live_wire.set_entry(open, "t1", "tool")
  @live_wire.set_entry(open, "a#0", "thinking")
  assert_eq(@live_wire.find_entry(open, "a#0"), Some(0))
  assert_true(@live_wire.has_open_tool(open))
  let out : Array[@jsjson.JValue] = []
  @live_wire.end_non_tool_prefix(open, "a#", out)
  assert_eq(out.length(), 1)
  assert_eq(said(out[0]), "{\"kind\":\"end\",\"id\":\"a#0\"}")
  assert_eq(@live_wire.find_entry(open, "a#0"), None)
  let phase = @live_wire.transition(None, "requesting", out)
  assert_eq(phase, Some("requesting"))
  assert_eq(@live_wire.transition(phase, "requesting", out), Some("requesting"))
  assert_eq(out.length(), 2)
  let ended = @live_wire.end_open(open)
  assert_eq(ended.length(), 1)
  assert_false(@live_wire.has_open_tool(open))
  let loaded : Array[(String, String)] = []
  let state = @live_wire.obj([("open", @live_wire.entries_json([("k1", "v1"), ("k2", "v2")]))])
  @live_wire.load_entries(state, "open", loaded)
  assert_eq(loaded, [("k1", "v1"), ("k2", "v2")])
  assert_eq(said(@live_wire.opt_str_json(None)), "null")
  assert_eq(said(@live_wire.opt_str_json(Some("ok"))), "\"ok\"")
  assert_eq(said(@live_wire.turn_started()), "{\"type\":\"turnStarted\"}")
  assert_eq(said(@live_wire.turn_ended(@live_wire.completed())), "{\"type\":\"turnEnded\",\"outcome\":{\"kind\":\"completed\"}}")
  assert_eq(said(@live_wire.aborted()), "{\"kind\":\"aborted\"}")
  assert_eq(said(@live_wire.tools_lost_event("err")), "{\"type\":\"toolsLost\",\"why\":\"err\"}")
  assert_true(@live_wire.station_tool("mcp__stillfail__post"))
  assert_true(@live_wire.station_tool("stillfail__post"))
  assert_false(@live_wire.station_tool("bash"))
  assert_eq(@live_wire.str_or_js(None), "")
  assert_eq(@live_wire.str_or_js(Some(Num(42.0))), "42")
  assert_eq(@live_wire.content_text(Some(@live_wire.jstr("hi"))), "hi")
  assert_eq(@live_wire.content_text(Some(@live_wire.jstr("hi")), allow_str=false), "")
}
