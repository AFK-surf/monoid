///|
test "the devices seen, read in each person's order, their latest first" {
  let seen = @gate.SeenDevices::new(None, _ => ())
  seen.saw(2000L, "w", "bob", "b@x", "d2", None, Json::null())
  seen.saw(1000L, "w", "alice", "a@x", "d1", None, Json::null())
  seen.saw(2200L, "w", "alice", "a@x", "d4", None, Json::null())
  seen.saw(900L, "w", "zed", "z@x", "d0", None, Json::null())
  assert_eq(seen.of("w", 5000L, "", true).map(r => r.device), ["d4", "d1", "d2", "d0"])
}
