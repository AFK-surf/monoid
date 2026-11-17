// The profiles' place with none picked opens on 概览 (Profiles("")) once any profile is listed, and keeps a picked
// profile while the list still has it, falling back to 概览 once a deleted profile leaves the list and to None once empty.

///|
fn profiles_listed(ids : Array[String], look : String) -> Json {
  {
    "items": Json::array(
      ids.map(fn(id) { { "station": "st", "profile": { "id": Json::string(id) }, "look": Json::boolean(id == look) } }),
    ),
  }
}

///|
test "the profiles' place defaults to overview, keeps a picked profile across re-sorting, and falls back to overview when deleted" {
  let list : @signals.Signal[Json] = @signals.signal(profiles_listed(["p2", "p0", "p1"], "p2"))
  let src = @sfbase.made_source(topic=fn(name, _) { if name == "profiles" { Some(list.get()) } else { None } })
  let w : @sfbase.Workspace = { id: "ws-kept", name: "W", emoji: "", icon: "", email: "" }
  let shown : Ref[@settings.Route?] = Ref(None)
  let stop = @signals.effect(fn() { shown.val = place_route(src, w, "profiles") })
  assert_true(shown.val == Some(@settings.Route::Profiles("")), msg="defaults to overview")
  // list re-sorted under it: stays on overview
  list.set(profiles_listed(["p0", "p1", "p2"], "p0"))
  assert_true(shown.val == Some(@settings.Route::Profiles("")), msg="stays on overview across re-sort")
  // one picked in the sidebar stays while listed, then falls back to overview once deleted
  @sfbase.place_pick[@sfbase.place_key("ws-kept", "profiles")] = @settings.Route::Profile("st", "p1")
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p1")), msg="picked while listed")
  list.set(profiles_listed(["p1", "p0"], "p1"))
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p1")), msg="picked kept across re-sort")
  list.set(profiles_listed(["p0"], "p0"))
  assert_true(shown.val == Some(@settings.Route::Profiles("")), msg="overview once picked is deleted")
  list.set(profiles_listed([], ""))
  assert_true(shown.val is None, msg="none once all are deleted")
  @sfbase.place_pick.remove(@sfbase.place_key("ws-kept", "profiles"))
  stop()
}
