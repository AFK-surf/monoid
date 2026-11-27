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

///|
fn place_station_row(ws : String, id : String, name : String) -> Json {
  let addr = ws + "/" + id
  {
    "station": Json::string(addr),
    "id": Json::string(id),
    "name": Json::string(name),
    "online": Json::boolean(true),
    "face": "idle",
    "line": "Linux",
    "summary": "Idle",
    "stateText": "Idle",
    "stateBusy": Json::boolean(false),
    "problems": [],
    "overview": {
      "viewer": { "email": "me@x.com", "role": "owner", "workspace": Json::string(ws) },
      "counts": { "sessions": 0, "running": 0, "warm": 0 },
    },
  }
}

///|
test "stations_place_node parks up to 4 stations via pick_kept, zeroes parked poller timelines, and drops Reading/First without parking" {
  @sfbase.reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let ws_id = "ws-sta-kept"
  let ws : @sfbase.Workspace = { id: ws_id, name: "W", emoji: "", icon: "", email: "" }
  let rows : @signals.Signal[Json?] = @signals.signal(None)
  let src = @sfbase.made_source(
    topic=fn(name, params) {
      match name {
        "workspaces" =>
          Some(
            Json::array([
              {
                "loaded": Json::boolean(true),
                "account": { "email": "me@x.com" },
                "workspaces": [{ "id": Json::string(ws_id), "name": "W", "emoji": "", "icon": "" }],
              },
            ]),
          )
        "prefs" => Some({ "workspace": Json::string(ws_id) })
        "stations" => rows.get()
        "station" =>
          match params.get("station") {
            Some(String(a)) => {
              let id = if a.has_prefix(ws_id + "/") { a.exact_view(start=ws_id.length() + 1).to_owned() } else { a }
              Some(place_station_row(ws_id, id, id))
            }
            _ => None
          }
        "workspace" => Some({ "id": Json::string(ws_id), "name": "W", "rigs": [] })
        _ => None
      }
    },
  )
  let core = settings_core(src, ws)
  let here = fn() { @settings.here_of(core, ws_id, "W") }
  let place_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      root.box(fn(box) {
        box.width(Is(Some(900.0))).height(Is(Some(700.0))) |> ignore
        place_root.val = Some(box)
        stations_place_node(box, src, core, here, fn() { 0 }, fn() { @sf.no_frame }, fn() { 900.0 })
      })
      |> ignore
    },
    w=1280.0,
    h=800.0,
    platform=0,
    keeps_sources=true,
    before=fn() { @hostapi.app_said("local_station") |> ignore },
  )
  // Mark ws-sta-kept/st1 as this_machine() so station_node installs its while_active_every poller.
  t.set_app_said(
    "local_station",
    "{\"data\":\"~/.stillfail\",\"runner\":\"service\",\"workspace\":{\"id\":\"ws-sta-kept\",\"station\":\"st1\",\"stationName\":\"st1\"}}",
  )
  // 1. Starts in Reading (no rows yet); leaving Reading must drop it rather than parking it.
  t.draw()
  let pr = place_root.val.unwrap()
  assert_eq(t.subtree_timeline_count(pr), 0, msg="Reading skeleton has 0 timeline entries")
  // 2. Empty rows -> First; leaving First must also drop it without parking.
  rows.set(Some(Json::array([])))
  t.draw()
  assert_eq(t.subtree_timeline_count(pr), 0, msg="First empty view has 0 timeline entries")
  // 3. Populate 5 stations -> defaults to st1 (this_machine), poller active (> 0).
  rows.set(
    Some(
      Json::array([
        place_station_row(ws_id, "st1", "st1"),
        place_station_row(ws_id, "st2", "st2"),
        place_station_row(ws_id, "st3", "st3"),
        place_station_row(ws_id, "st4", "st4"),
        place_station_row(ws_id, "st5", "st5"),
      ]),
    ),
  )
  t.draw()
  assert_true(t.subtree_timeline_count(pr) > 0, msg="active this_machine station must own while_active_every poller")
  // 4. Switch to st2: st1 is parked and its poller timeline drops to 0.
  place_pick_station(ws_id, ws_id + "/st2")
  t.draw()
  assert_eq(t.subtree_timeline_count(pr), 0, msg="parked st1 must clear its poller timeline to 0")
  // 5. Hot-return to st1: 0 nodes made, poller resumes (> 0).
  t.tree_frames_from_now()
  place_pick_station(ws_id, ws_id + "/st1")
  t.draw()
  let back_made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_eq(back_made, 0, msg="hot return to parked st1 must build 0 nodes")
  assert_true(t.subtree_timeline_count(pr) > 0, msg="woken st1 must resume its poller")
  // 6. Visit st3, st4, then st5 (> keeps_max=4): evicts oldest st2; revisiting st2 rebuilds.
  place_pick_station(ws_id, ws_id + "/st3")
  t.draw()
  place_pick_station(ws_id, ws_id + "/st4")
  t.draw()
  t.tree_frames_from_now()
  place_pick_station(ws_id, ws_id + "/st5")
  t.draw()
  t.run_for(@ui.frame_period_default * 2.0)
  let evict_let_go = t.tree_frames().fold(init=0, fn(n, f) { n + f.let_go })
  assert_true(evict_let_go > 0, msg="opening 5th station must evict oldest parked station")
  assert_eq(t.subtree_timeline_count(pr), 0, msg="all parked stations (including st1) have 0 timeline entries")
  t.tree_frames_from_now()
  place_pick_station(ws_id, ws_id + "/st2")
  t.draw()
  let rebuild_made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_true(rebuild_made > 0, msg="evicted st2 must rebuild on revisit")
  @sfbase.place_pick.remove(@sfbase.place_key(ws_id, "stations"))
  @ui.run_let_go()
}
