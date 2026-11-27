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
  assert_true(shown.val == Some(@settings.Route::ProfilesOverview), msg="defaults to overview")
  // list re-sorted under it: stays on overview
  list.set(profiles_listed(["p0", "p1", "p2"], "p0"))
  assert_true(shown.val == Some(@settings.Route::ProfilesOverview), msg="stays on overview across re-sort")
  // one picked in the sidebar stays while listed, then falls back to overview once deleted
  @sfbase.place_pick[@sfbase.place_key("ws-kept", "profiles")] = @settings.Route::Profile("st", "p1")
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p1")), msg="picked while listed")
  list.set(profiles_listed(["p1", "p0"], "p1"))
  assert_true(shown.val == Some(@settings.Route::Profile("st", "p1")), msg="picked kept across re-sort")
  list.set(profiles_listed(["p0"], "p0"))
  assert_true(shown.val == Some(@settings.Route::ProfilesOverview), msg="overview once picked is deleted")
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
  let ws_sig : @signals.Signal[String] = @signals.signal(ws_id)
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
                "workspaces": [
                  { "id": Json::string(ws_id), "name": "W", "emoji": "", "icon": "" },
                  { "id": "ws-other", "name": "W2", "emoji": "", "icon": "" },
                ],
              },
            ]),
          )
        "prefs" => Some({ "workspace": Json::string(ws_sig.get()) })
        "stations" => if ws_sig.get() == ws_id { rows.get() } else { Some(Json::array([])) }
        "station" =>
          match params.get("station") {
            Some(String(a)) => {
              let id = if a.has_prefix(ws_id + "/") { a.exact_view(start=ws_id.length() + 1).to_owned() } else { a }
              Some(place_station_row(ws_id, id, id))
            }
            _ => None
          }
        "workspace" => Some({ "id": Json::string(ws_sig.get()), "name": "W", "rigs": [] })
        _ => None
      }
    },
  )
  let core = settings_core(src, ws)
  let here = fn() { @settings.here_of(core, ws_sig.get(), "W") }
  let place_root : Ref[@view.View?] = Ref(None)
  let t = @ui.Tester::tree(
    fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      @sf.look_lent(root, @sf.look_for(1280.0))
      // Outer switch_by keyed by workspace (mirroring pane_view/nav shelf clear on workspace switch).
      root.switch_by(fn() { ws_sig.get() }, fn(box, _) {
        box.width(Is(Some(900.0))).height(Is(Some(700.0))) |> ignore
        place_root.val = Some(box)
        stations_place_node(box, src, core, here, fn() { 0 }, fn() { @sf.no_frame }, fn() { 900.0 })
      })
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
  let tree = @ui.view_tree().unwrap()
  let pr = place_root.val.unwrap()
  assert_eq(tree.due_count(), 0, msg="Reading skeleton has 0 timeline entries across whole tree")
  // 2. Empty rows -> First; leaving Reading must drop its nodes (let_go > 0).
  t.tree_frames_from_now()
  rows.set(Some(Json::array([])))
  t.draw()
  let reading_let_go = t.tree_frames().fold(init=0, fn(n, f) { n + f.let_go })
  assert_true(reading_let_go > 0, msg="leaving Reading must drop skeleton without parking (let_go=\{reading_let_go})")
  assert_eq(tree.due_count(), 0, msg="First empty view has 0 timeline entries across whole tree")
  // 3. Populate 5 stations -> defaults to st1 (this_machine); leaving First must drop it (let_go > 0), poller active (> 0).
  t.tree_frames_from_now()
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
  let first_let_go = t.tree_frames().fold(init=0, fn(n, f) { n + f.let_go })
  assert_true(first_let_go > 0, msg="leaving First must drop empty view without parking (let_go=\{first_let_go})")
  let active_timelines = t.subtree_timeline_count(pr)
  assert_true(active_timelines > 0, msg="active this_machine station must own while_active_every poller")
  assert_eq(tree.due_count(), active_timelines, msg="whole-tree due_count matches active st1 timelines")
  // 4. Switch to st2: st1 is parked (parent == -1) and whole-tree due_count drops to 0 (proving parked st1 cleared its poller).
  place_pick_station(ws_id, ws_id + "/st2")
  t.draw()
  assert_eq(tree.due_count(), 0, msg="parked st1 must remove its poller from Tree::timeline (due_count == 0)")
  assert_eq(t.next_wake(), None, msg="no timer wake pending while st1 is parked")
  // 5. Hot-return to st1: 0 nodes made, poller resumes (> 0) and matches whole-tree due_count.
  t.tree_frames_from_now()
  place_pick_station(ws_id, ws_id + "/st1")
  t.draw()
  let back_made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_eq(back_made, 0, msg="hot return to parked st1 must build 0 nodes")
  assert_true(t.subtree_timeline_count(pr) > 0, msg="woken st1 must resume its poller")
  assert_eq(tree.due_count(), t.subtree_timeline_count(pr), msg="woken st1 whole-tree due_count matches mounted count")
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
  assert_eq(tree.due_count(), 0, msg="all parked stations (including st1) must own 0 entries in Tree::timeline")
  t.tree_frames_from_now()
  place_pick_station(ws_id, ws_id + "/st2")
  t.draw()
  let rebuild_made = t.tree_frames().fold(init=0, fn(n, f) { n + f.made })
  assert_true(rebuild_made > 0, msg="evicted st2 must rebuild on revisit")
  // 7. Returning to Reading parks the current station without leaking timers.
  rows.set(None)
  t.draw()
  assert_eq(tree.due_count(), 0, msg="no timers remain while on Reading")
  // 8. Switching workspace disposes the entire stations_place_node and releases all parked station branches.
  t.tree_frames_from_now()
  ws_sig.set("ws-other")
  t.draw()
  let ws_let_go = t.tree_frames().fold(init=0, fn(n, f) { n + f.let_go })
  assert_true(ws_let_go > 0, msg="workspace switch must dispose all parked station branches (let_go=\{ws_let_go})")
  assert_eq(tree.due_count(), 0, msg="no timers remain after workspace switch disposal")
  @sfbase.place_pick.remove(@sfbase.place_key(ws_id, "stations"))
  @ui.run_let_go()
}
