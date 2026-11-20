// What the tools work out alone.

///|
test "a bearer's arguments typed by the tool's schema" {
  let schema = @api_routes.parse(
    "{\"properties\":{\"watch\":{\"type\":\"boolean\"},\"port\":{\"type\":\"integer\"},\"name\":{\"type\":\"string\"}}}",
  )
  let args = @api_routes.parse(
    "{\"watch\":\"true\",\"port\":\" 3000 \",\"name\":\"1\",\"other\":\"false\"}",
  )
  assert_eq(
    stringify(typed(args, schema)),
    "{\"watch\":true,\"port\":3000,\"name\":\"1\",\"other\":\"false\"}",
  )
  assert_eq(
    stringify(typed(@api_routes.parse("{\"port\":\"3e3\"}"), schema)),
    "{\"port\":\"3e3\"}",
  )
}

///|
test "a /peer URL's parts" {
  match peer_target("/peer/To%20kyo/3000?x=1") {
    Some(t) => {
      assert_eq(t.station, "To kyo")
      assert_eq(t.port, 3000)
      assert_eq(t.path, "/?x=1")
    }
    None => fail("not read")
  }
  assert_true(peer_target("/peer/x/65536/") is None)
  assert_true(peer_target("/peer/x/80x/") is None)
  match peer_target("/peer/x/00080/a") {
    Some(t) => assert_eq(t.port, 80)
    None => fail("not read")
  }
}

///|
test "who may reach another station through the door" {
  assert_true(not_from_here([("host", "127.0.0.1:4000")], [4000]) is None)
  assert_true(not_from_here([("host", "evil.example:4000")], [4000]) is Some(_))
  assert_true(
    not_from_here([("host", "[::1]:4000"), ("origin", "null")], [4000]) is None,
  )
  assert_true(
    not_from_here(
      [("host", "localhost:4000"), ("origin", "https://evil.example")],
      [4000],
    )
    is Some(_),
  )
}

///|
test "keys as the screen contract's events" {
  let events = key_presses("cmd+shift+t")
  assert_eq(events.length(), 6)
  assert_eq(
    stringify(events[2]),
    "{\"t\":\"key\",\"kind\":\"down\",\"key\":\"T\",\"code\":\"KeyT\",\"mods\":12}",
  )
  assert_eq(
    stringify(key_presses("?")[1]),
    "{\"t\":\"key\",\"kind\":\"down\",\"key\":\"?\",\"code\":\"Slash\",\"mods\":8}",
  )
  let refused = try {
    ignore(key_presses("hyper+x"))
    ""
  } catch {
    e => message_of(e)
  }
  assert_eq(refused, "key: \"hyper\" is no modifier (cmd, ctrl, alt, shift)")
}

///|
test "dates as Date.parse and toISOString have them" {
  assert_eq(parse_iso("2026-11-17T02:39:41.107Z"), 1794883181107.0)
  assert_eq(parse_iso("2026-11-17T10:39:41+08:00"), 1794883181000.0)
  assert_eq(parse_iso("2026-02-29T00:00:00Z"), 1772323200000.0)
  assert_true(parse_iso("nope").is_nan())
  assert_eq(iso_string(1794883181032.0), "2026-11-17T02:39:41.032Z")
  assert_eq(iso_string(-1.0), "1969-12-31T23:59:59.999Z")
}

///|
test "a move's outcome in words" {
  let out = @api_routes.parse(
    "{\"done\":[{\"module\":\"chats\",\"id\":\"s1\"}],\"refused\":[],\"stopped\":[],\"resumed\":[],\"failed\":null}",
  )
  assert_eq(outcome_words(out, "moved to", "Tokyo"), "Moved to Tokyo (1): chats s1.")
}

///|
test "a scale as toFixed(3) says it" {
  assert_eq(fixed_number(1366.0 / 1280.0, 3), 1.067)
  assert_eq(fixed_number(2.0, 3), 2.0)
  assert_eq(fixed_number(1.0005, 3), 1.0)
}
