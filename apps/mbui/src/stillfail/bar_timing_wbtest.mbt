///|
fn parse_bar_json(s : String?) -> Map[String, Json] raise {
  guard s is Some(raw) else { fail("expected bar_switch JSON") }
  let parsed = @json.parse(raw) catch { _ => Json::null() }
  guard parsed is Object(m) else { fail("expected JSON object") }
  m
}

///|
test "normal switch with no topics settles immediately on built" {
  let tr = BarSwitchTracker::new()
  assert_eq(tr.placed("", "chats", 100.0), None)
  let m = parse_bar_json(tr.built("chats", 112.345))
  assert_eq(m.get("from"), Some(Json::null()))
  assert_eq(m.get("to"), Some(Json::string("chats")))
  assert_eq(m.get("first"), Some(Json::boolean(true)))
  assert_eq(m.get("away_ms"), None)
  assert_eq(m.get("composed_ms"), Some(Json::number(12.35)))
  assert_eq(m.get("cut"), Some(Json::boolean(false)))
  assert_eq(m.get("topics_count"), Some(Json::number(0.0)))
  assert_eq(m.get("topics"), Some(Json::array([])))
  assert_eq(tr.has_pending(), false)
}

///|
test "first open vs revisit records away_ms and first=false" {
  let tr = BarSwitchTracker::new()
  assert_eq(tr.placed("chats", "stations", 1000.0), None)
  let first = parse_bar_json(tr.built("stations", 1020.0))
  assert_eq(first.get("from"), Some(Json::string("chats")))
  assert_eq(first.get("to"), Some(Json::string("stations")))
  assert_eq(first.get("first"), Some(Json::boolean(true)))
  assert_eq(first.get("away_ms"), None)
  // Switch back to chats after 2500 ms away (chats was left at 1000.0)
  assert_eq(tr.placed("stations", "chats", 3500.0), None)
  let back = parse_bar_json(tr.built("chats", 3510.0))
  assert_eq(back.get("from"), Some(Json::string("stations")))
  assert_eq(back.get("to"), Some(Json::string("chats")))
  assert_eq(back.get("first"), Some(Json::boolean(false)))
  assert_eq(back.get("away_ms"), Some(Json::number(2500.0)))
}

///|
test "multi-topic aggregation with parts and failure settles when all arrive" {
  let tr = BarSwitchTracker::new()
  assert_eq(tr.placed("chats", "files", 500.0), None)
  assert_eq(tr.followed(1, "drive.list", 502.0), true)
  assert_eq(tr.followed(1, "drive.list", 503.0), false)
  assert_eq(tr.followed(2, "station", 505.0), true)
  // Built before topics arrive: does not settle yet
  assert_eq(tr.built("files", 515.0), None)
  // Topic followed within 500ms of built is tracked; topic after 500ms is ignored
  assert_eq(tr.followed(3, "profile", 520.0), true)
  assert_eq(tr.followed(4, "late.topic", 1016.0), false)
  assert_eq(tr.decoded(1, 40960, "{\"items\":38000}", 540.0), None)
  assert_eq(tr.decoded(2, -1, "", 550.0), None)
  // Final topic arrives -> settles
  let m = parse_bar_json(tr.decoded(3, 512, "", 560.0))
  assert_eq(m.get("cut"), Some(Json::boolean(false)))
  assert_eq(m.get("composed_ms"), Some(Json::number(15.0)))
  assert_eq(m.get("topics_count"), Some(Json::number(3.0)))
  guard m.get("topics") is Some(Array(topics)) else { fail("expected topics array") }
  assert_eq(topics.length(), 3)
  guard topics[0] is Object(t0) else { fail("expected topic 0") }
  assert_eq(t0.get("topic"), Some(Json::string("drive.list")))
  assert_eq(t0.get("core_ms"), Some(Json::number(38.0)))
  assert_eq(t0.get("tap_shown_ms"), Some(Json::number(40.0)))
  assert_eq(t0.get("bytes"), Some(Json::number(40960.0)))
  assert_eq(t0.get("parts"), Some({ "items": 38000.0 }))
  assert_eq(t0.get("failed"), None)
  guard topics[1] is Object(t1) else { fail("expected topic 1") }
  assert_eq(t1.get("topic"), Some(Json::string("station")))
  assert_eq(t1.get("bytes"), None)
  assert_eq(t1.get("failed"), Some(Json::boolean(true)))
  guard topics[2] is Object(t2) else { fail("expected topic 2") }
  assert_eq(t2.get("topic"), Some(Json::string("profile")))
  assert_eq(t2.get("core_ms"), Some(Json::number(40.0)))
  assert_eq(t2.get("tap_shown_ms"), Some(Json::number(60.0)))
  assert_eq(t2.get("bytes"), Some(Json::number(512.0)))
}

///|
test "interrupted switch emits cut=true when a new switch starts" {
  let tr = BarSwitchTracker::new()
  assert_eq(tr.placed("chats", "stations", 100.0), None)
  assert_eq(tr.followed(10, "stations", 105.0), true)
  // Interrupted before built and before topic arrives
  let cut = parse_bar_json(tr.placed("stations", "files", 250.0))
  assert_eq(cut.get("to"), Some(Json::string("stations")))
  assert_eq(cut.get("composed_ms"), Some(Json::null()))
  assert_eq(cut.get("cut"), Some(Json::boolean(true)))
  assert_eq(cut.get("topics_count"), Some(Json::number(1.0)))
  // New switch settles cleanly
  let next = parse_bar_json(tr.built("files", 265.0))
  assert_eq(next.get("to"), Some(Json::string("files")))
  assert_eq(next.get("cut"), Some(Json::boolean(false)))
}

///|
test "tick flushes pending switch with cut=true at 3000ms timeout" {
  let tr = BarSwitchTracker::new()
  assert_eq(tr.placed("chats", "usage", 1000.0), None)
  assert_eq(tr.followed(7, "usage", 1010.0), true)
  assert_eq(tr.built("usage", 1025.0), None)
  assert_eq(tr.tick(3999.0), None)
  assert_eq(tr.has_pending(), true)
  let timed_out = parse_bar_json(tr.tick(4000.0))
  assert_eq(timed_out.get("to"), Some(Json::string("usage")))
  assert_eq(timed_out.get("composed_ms"), Some(Json::number(25.0)))
  assert_eq(timed_out.get("cut"), Some(Json::boolean(true)))
  assert_eq(timed_out.get("topics_count"), Some(Json::number(1.0)))
  assert_eq(tr.has_pending(), false)
  assert_eq(tr.tick(5000.0), None)
}
