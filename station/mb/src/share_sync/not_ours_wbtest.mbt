// A host's refusals said apart, and what a borrower takes from each (index.ts NOT_FOR_IT, NOT_THERE,
// STATIONS_UNKNOWN, NOT_SHARED, `notOurs`, `sameStations`): only the host's own word that its `allow` leaves a
// station out takes a copy away.

///|
fn stations(names : Array[String]) -> Json {
  Json::array(names.map(n => Json::string(n)))
}

///|
test "two allows let the same stations use a share, in whatever order" {
  assert_true(same_stations(None, Some(Json::null())))
  assert_true(same_stations(Some(Json::null()), Some(Json::null())))
  assert_true(same_stations(Some(stations(["a", "b"])), Some(stations(["b", "a"]))))
  assert_false(same_stations(Some(stations(["a", "b"])), Some(stations(["a"]))))
  assert_false(same_stations(Some(stations(["a", "b"])), Some(stations(["a", "c"]))))
  assert_false(same_stations(Some(Json::null()), Some(stations(["a"]))))
  assert_false(same_stations(Some(stations([])), None))
}

///|
test "only the host's own word that its allow leaves a station out is not ours" {
  assert_true(not_ours(Refused(not_for_it)))
  assert_true(not_ours(Failed(not_for_it)))
  assert_false(not_ours(Refused(not_there)))
  assert_false(not_ours(Refused(stations_unknown)))
  assert_false(not_ours(Refused(not_shared)))
  assert_false(not_ours(Failed("connection refused")))
}

///|
test "a host's refusal, each said apart in its order" {
  let rosters : Map[String, Array[String]] = Map([("b", ["w"]), ("c", ["w"])])
  let reach_w = (r : Map[String, Array[String]]) => if r.contains("b") { Some("w") } else { None }
  // Its allow leaves it out: said so first, whatever is known of the stations.
  assert_eq(refusal_of(stations(["a"]), "b", None, reach_w), Some(not_for_it))
  assert_eq(refusal_of(stations(["a"]), "b", Some(rosters), reach_w), Some(not_for_it))
  // Allowed, the stations not known yet.
  assert_eq(refusal_of(Json::null(), "b", None, reach_w), Some(stations_unknown))
  assert_eq(refusal_of(stations(["b"]), "b", None, reach_w), Some(stations_unknown))
  // Allowed, the cloud's list leaving it out.
  assert_eq(refusal_of(Json::null(), "b", Some(rosters), _ => None), Some(not_there))
  // Allowed and reached.
  assert_eq(refusal_of(Json::null(), "b", Some(rosters), reach_w), None)
  assert_eq(refusal_of(stations(["b"]), "b", Some(rosters), reach_w), None)
}

///|
test "as who may use a share changes, every station it leaves out is to be told, down as told or not" {
  let rosters : Map[String, Array[String]] = Map([("b", ["w"]), ("c", ["w"]), ("d", ["w"]), ("r", ["w"])])
  let none = (_ : String) => false
  // Every station to only c: b (told of it) is told as before; d, never down as told (forgotten a while), is told too.
  let told : Map[String, Json] = Map([("b", Json::number(3.0)), ("c", Json::number(3.0))])
  let out = left_out(told, Some(Json::null()), stations(["c"]), rosters, none)
  out.sort()
  assert_eq(out, ["d", "r"])
  // A station retired into this one is not told.
  let out = left_out(told, Some(Json::null()), stations(["c"]), rosters, s => s == "r")
  assert_eq(out, ["d"])
  // The same stations in another order: nobody.
  assert_eq(left_out(Map([]), Some(stations(["c", "b"])), stations(["b", "c"]), rosters, none), [])
  // Widened to every station: nobody left out.
  assert_eq(left_out(Map([]), Some(stations(["b"])), Json::null(), rosters, none), [])
  // One already to be told (-1) is not counted again.
  let told : Map[String, Json] = Map([("d", Json::number(-1.0))])
  let out = left_out(told, Some(Json::null()), stations(["b", "c"]), rosters, none)
  assert_eq(out, ["r"])
}
