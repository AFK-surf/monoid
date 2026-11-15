// The profiles' place with none picked shows the first that needs a look, and keeps showing it while the list still has
// it: the list sorted anew under it takes nothing the person reads away from them.

///|
fn profiles_listed(ids : Array[String], look : String) -> Json {
  {
    "items": Json::array(
      ids.map(fn(id) { { "station": "st", "profile": { "id": Json::string(id) }, "look": Json::boolean(id == look) } }),
    ),
  }
}

///|
test "the profiles' place keeps the profile it shows as the list is sorted anew under it" {
  let list : @signals.Signal[Json] = @signals.signal(profiles_listed(["p2", "p0", "p1"], "p2"))
  let src = @sfbase.made_source(topic=fn(name, _) { if name == "profiles" { Some(list.get()) } else { None } })
  let w : @sfbase.Workspace = { id: "ws-kept", name: "W", emoji: "", icon: "", email: "" }
  let shown : Ref[@settings.Route?] = Ref(None)
  let stop = @signals.effect(fn() { shown.val = place_route(src, w, "profiles") })
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p2")), msg="the first that needs a look")
  // another comes to need a look, first in the list: the one shown stays
  list.set(profiles_listed(["p0", "p1", "p2"], "p0"))
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p2")), msg="kept while the list has it")
  // gone from the list: the first that needs a look
  list.set(profiles_listed(["p0", "p1"], "p0"))
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p0")), msg="the first once it is gone")
  stop()
}
