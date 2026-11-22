// The stations' list (stations_list.mbt) gives the page a block each station, by its address, so the page's list
// (page_node, View::scrolls_window) makes only the cards in sight and near it as it opens, not every station's at once
// (a phone's Place stations, 2026-11-22: one touch-up 21.5 ms on Android, 28.1 ms on iOS, 690 nodes made in it, the
// workspace's stations all one block).

///|
/// The workspace's station `i` of the made-up core: up, its name and what is said of it its own.
fn sl_window_station(i : Int) -> Json {
  {
    "station": Json::string("ws1/s\{i}"),
    "id": Json::string("s\{i}"),
    "name": Json::string("站点 \{i}"),
    "online": true,
    "summary": Json::string("机器 \{i} 的说明"),
  }
}

///|
/// The list over a made-up core of `n` stations, opened in a phone's window (390 by 844) after it is drawn without
/// it: the tester, and the nodes its opening made.
fn sl_window_open(n : Int) -> (@ui.Tester, Int) {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let stations = Array::makei(n, sl_window_station)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" => Some(Json::array(stations))
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let open = @signals.signal(false)
  let t = station_part_tester(
    fn(p) {
      p.show(fn() { open.get() }, at_once=true, fn(x) {
        x.grow(Is(1.0)) |> ignore
        stations_list_node(x, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame })
      })
    },
    w=390.0,
    h=844.0,
    platform=2,
  )
  t.tree_frames_from_now()
  open.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let made = t.tree_frames().fold(init=0, fn(s, f) { s + f.made })
  (t, made)
}

///|
test "stations_list: opening makes only the cards in sight, as many nodes for 24 stations as for 60; the rest made as scrolled to" {
  let (_, few) = sl_window_open(3)
  let (t, made) = sl_window_open(24)
  assert_true(t.find("站点 0") is Some(_), msg="the first station shown")
  assert_true(t.find("机器 0 的说明") is Some(_), msg="what is said of the first shown")
  assert_true(t.find("站点 23") is None, msg="the last station, far out of sight, not made as the page opens")
  // (the cards past the window and its margin not made: as many made for 24 as for 60, more than for 3)
  let (_, many) = sl_window_open(60)
  assert_true(made > few, msg="24 stations make more than 3: \{made}, \{few}")
  assert_eq(made, many, msg="24 stations make as many as 60: \{made}, \{many}")
  // (scrolled down by a hand's wheel, a screen at a time, to its foot: the last ones made as they come near, their
  // words as the core says them, the first let go of)
  let (t, _) = sl_window_open(24)
  let mut steps = 0
  while t.find("站点 23") is None && steps < 20 {
    t.wheel(195.0, 422.0, 600.0)
    t.run_for(@ui.move_most_ms)
    steps = steps + 1
  }
  assert_true(t.find("站点 23") is Some(_), msg="the last station shown at the foot")
  assert_true(t.find("机器 23 的说明") is Some(_), msg="what is said of the last shown")
  assert_true(t.find("站点 0") is None, msg="the first, far above, let go of")
}
