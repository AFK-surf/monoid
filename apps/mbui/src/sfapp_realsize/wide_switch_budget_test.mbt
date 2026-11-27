// Wide-layout (Large 1280x800, 1440x900; Medium 600x900) 6-dimension switch budget and memory gates
// on real-size workspace payloads (RealSizeChanging):
//   1. Hot switch node construction / layout / measure / binding budgets (made == 0, let_go == 0).
//   2. Parked subtree timeline zeroing (Tester::subtree_timeline_count == 0, including later=true), at_rest, no unasked faults.
//   3. Accessibility / focus / input isolation for parked subtrees.
//   4. Profiles exact 4 non-pin quota + overview pin + deferred eviction + ahead-read shown_read release.
//   5. Stations hot return + >4 eviction + parked poller timeline zeroing.
//   6. Live node count and retained topic payload bytes upper bounds with full breakdown table.

///|
/// Format bytes as "XX.XX KB (Y.YYY MB)" for deterministic budget reports.
fn wide_fmt_kb_mb(bytes : Int) -> String {
  let b = bytes.to_int64()
  let kb100 = (b * 100L + 512L) / 1024L
  let kb_i = kb100 / 100L
  let kb_f = kb100 % 100L
  let kb_f_s = if kb_f < 10L { "0\{kb_f}" } else { "\{kb_f}" }
  let mb1000 = (b * 1000L + 524288L) / 1048576L
  let mb_i = mb1000 / 1000L
  let mb_f = mb1000 % 1000L
  let mb_f_s = if mb_f < 10L { "00\{mb_f}" } else if mb_f < 100L { "0\{mb_f}" } else { "\{mb_f}" }
  "\{kb_i}.\{kb_f_s} KB (\{mb_i}.\{mb_f_s} MB)"
}

///|
/// Format a percentage `part / total` with 1 decimal place.
fn wide_fmt_pct(part : Int, total : Int) -> String {
  if total <= 0 {
    return "0.0%"
  }
  let p10 = (part * 1000 + total / 2) / total
  "\{p10 / 10}.\{p10 % 10}%"
}

///|
/// Open a wide/medium Tester on the real-size workspace, settled on a Chat page.
fn wide_budget_open(
  w : Double,
  h : Double,
  platform : Int,
  a11y? : Bool = false,
) -> (@ui.Tester, @sfrealsize.RealSizeChanging, @sfbase.Source, String, @sfbase.ChatRef) {
  let c = @sfrealsize.RealSizeChanging::new()
  let src_ref : Ref[@sfbase.Source?] = Ref(None)
  let made = fn() {
    match src_ref.val {
      Some(s) => s
      None => {
        @sfapp.reset()
        let s = c.source(@sffixture.fixture("home"))
        @sfapp.open_fixture_over("home", s)
        src_ref.val = Some(s)
        s
      }
    }
  }
  let t = @ui.Tester::new(
    fn(x) { @sfapp.view(x, made()) },
    tree=fn(root) { @sfapp.app_tree(made())(root) },
    w~,
    h~,
    platform~,
    window_corner=@sfapptest.test_window_corner(platform),
    corners_held=false,
    words_over_held=false,
    env=[("MBUI_LOCALE", "zh")],
  )
  t.motion_unjudged(true)
  if a11y {
    t.set_a11y(true)
  }
  t.run_for(@sfapptest.squeeze_opening)
  t.run_for(@sfapptest.kept_switch_over_ms)
  let src = made()
  let ws = @signals.untracked(fn() { @sfbase.workspace_in_view(src).0.unwrap().id })
  let chat_ref = match @sfbase.app.nav.top() {
    Chat(r) => r
    _ => {
      let first = @signals.untracked(fn() { @sfbase.chats_of(src, ws, "all").0.unwrap().days[0].items[0] })
      let r : @sfbase.ChatRef = {
        station: first.station,
        session: first.session,
        title: first.title,
        station_name: first.station_name,
      }
      @ui.view_tree().unwrap().event(t.time(), fn() { @sfbase.nav_over_home([Chat(r)]) })
      t.run_for(@sfapptest.kept_switch_over_ms)
      r
    }
  }
  (t, c, src, ws, chat_ref)
}

///|
/// Run `act` inside a tree event, advance to settled rest, and return
/// `(sum_made, sum_let_go, peak_laid, peak_measured, peak_bindings)` across all frames
/// (peak per-frame layout/measure/bindings are frame-rate invariant across 60/120/24/7 fps).
fn wide_budget_step(t : @ui.Tester, act : () -> Unit) -> (Int, Int, Int, Int, Int) {
  t.tree_frames_from_now()
  @ui.view_tree().unwrap().event(t.time(), act)
  t.run_for(@sfapptest.kept_switch_over_ms)
  t.tree_frames().fold(init=(0, 0, 0, 0, 0), fn(a, f) {
    (
      a.0 + f.made,
      a.1 + f.let_go,
      @cmp.maximum(a.2, f.laid),
      @cmp.maximum(a.3, f.measured),
      @cmp.maximum(a.4, f.bindings),
    )
  })
}

///|
/// Switch to a rail place (`kept=true`), returning to `chat_ref` when `place == "chats"`.
fn wide_go_place(t : @ui.Tester, place : String, chat_ref : @sfbase.ChatRef) -> (Int, Int, Int, Int, Int) {
  wide_budget_step(t, fn() {
    @sfbase.go_place(place, kept=true) |> ignore
    if place == "chats" {
      @sfbase.nav_over_home([Chat(chat_ref)])
    }
  })
}

///|
/// Pick a profile route (or overview `Route::Profiles("")`) in the profiles place.
fn wide_pick_profile(
  t : @ui.Tester,
  src : @sfbase.Source,
  ws : String,
  route : @settings.Route,
) -> (Int, Int, Int, Int, Int) {
  wide_budget_step(t, fn() {
    match route {
      Profile(a, id) =>
        @sfbase.show_answered(src, @sfbase.route_asks(ws, route), @sfbase.profile_shown_at(a, id), fn() {
          @sfbase.place_pick[@sfbase.place_key(ws, "profiles")] = route
          @sfbase.show_chosen()
        })
      _ => {
        @sfbase.place_pick[@sfbase.place_key(ws, "profiles")] = route
        @sfbase.show_chosen()
      }
    }
  })
}

///|
/// Pick a station route in the stations place.
fn wide_pick_station(
  t : @ui.Tester,
  src : @sfbase.Source,
  ws : String,
  address : String,
) -> (Int, Int, Int, Int, Int) {
  let route = @settings.Route::Station(address)
  wide_budget_step(t, fn() {
    @sfbase.show_answered(src, @sfbase.route_asks(ws, route), @sfpages.station_shown_at(address), fn() {
      @sfbase.place_pick[@sfbase.place_key(ws, "stations")] = route
      @sfbase.show_chosen()
    })
  })
}

///|
/// Collect real-size profiles `(station, id)` pairs from the workspace's `profiles` topic.
fn wide_real_profiles(src : @sfbase.Source, ws : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let v = @signals.untracked(fn() { src.topic("profiles", { "scope": Json::string(ws) }).get().value })
  match v {
    Some(Object(m)) =>
      match m.get("items") {
        Some(Array(items)) =>
          for item in items {
            match item {
              Object(e) =>
                match (e.get("station"), e.get("profile")) {
                  (Some(String(st)), Some(Object(pm))) =>
                    match pm.get("id") {
                      Some(String(id)) => out.push((st, id))
                      _ => ()
                    }
                  _ => ()
                }
              _ => ()
            }
          }
        _ => ()
      }
    _ => ()
  }
  out
}

///|
/// Collect real-size station addresses from the workspace's `stations` topic.
fn wide_real_stations(src : @sfbase.Source, ws : String) -> Array[String] {
  let out : Array[String] = []
  let v = @signals.untracked(fn() { @sfbase.station_rows(src, ws).value })
  match v {
    Some(Array(items)) =>
      for item in items {
        match item {
          Object(e) =>
            match e.get("station") {
              Some(String(st)) => out.push(st)
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
/// Exact UTF-8 byte length of a string (avoids deprecated `String::to_bytes`).
fn wide_utf8_len(s : String) -> Int {
  let mut n = 0
  for ch in s {
    let cp = ch.to_int()
    if cp <= 0x7F {
      n += 1
    } else if cp <= 0x7FF {
      n += 2
    } else if cp <= 0xFFFF {
      n += 3
    } else {
      n += 4
    }
  }
  n
}

///|
/// Sum serialized UTF-8 payload bytes across all retained real-size topic ways.
fn wide_retained_topic_bytes(c : @sfrealsize.RealSizeChanging) -> (Int, Int) {
  let mut total = 0
  let ways = c.ways()
  for way in ways {
    match @sfrealsize.real_size_value(way.0, way.1) {
      Some(v) => total += wide_utf8_len(v.stringify())
      None => ()
    }
  }
  (ways.length(), total)
}

///|
/// Dimension 1 & 2: Hot rail switch budgets on Large (1280x800, 1440x900) and Medium (600x900).
test "wide switch budget (dim 1 & 2): rail hot switches build 0 nodes within layout/binding budgets and settle at rest" {
  let large_windows : Array[(String, Double, Double, Int)] = [
    ("large-1280x800", 1280.0, 800.0, 0),
    ("large-1440x900", 1440.0, 900.0, 0),
  ]
  for win in large_windows {
    let (label, w, h, platform) = win
    let (t, _, _, _, chat_ref) = wide_budget_open(w, h, platform)
    // Cold-visit every rail place once so each is parked on the shelf.
    let cold_profiles = wide_go_place(t, "profiles", chat_ref)
    let cold_stations = wide_go_place(t, "stations", chat_ref)
    // Same-width sidebar hot pair: stations <-> profiles.
    let hot_prof_same = wide_go_place(t, "profiles", chat_ref)
    let hot_sta_same = wide_go_place(t, "stations", chat_ref)
    let cold_connects = wide_go_place(t, "connects", chat_ref)
    let cold_usage = wide_go_place(t, "usage", chat_ref)
    // Same-width full-pane hot pair: usage <-> connects must build 0 / drop 0 nodes.
    let hot_conn_same = wide_go_place(t, "connects", chat_ref)
    let hot_use_same = wide_go_place(t, "usage", chat_ref)
    // Full rotation back through chats -> profiles -> stations -> connects -> usage -> chats.
    let hot_chats_1 = wide_go_place(t, "chats", chat_ref)
    let hot_profiles = wide_go_place(t, "profiles", chat_ref)
    let hot_stations = wide_go_place(t, "stations", chat_ref)
    let hot_connects = wide_go_place(t, "connects", chat_ref)
    let hot_usage = wide_go_place(t, "usage", chat_ref)
    let hot_chats_2 = wide_go_place(t, "chats", chat_ref)
    println(
      "wide-budget \{label}: cold(prof=\{cold_profiles.0}, sta=\{cold_stations.0}, conn=\{cold_connects.0}, use=\{cold_usage.0}) same_w(prof=\{Repr(hot_prof_same)}, sta=\{Repr(hot_sta_same)}, conn=\{Repr(hot_conn_same)}, use=\{Repr(hot_use_same)}) rot(chats=\{Repr(hot_chats_1)}, prof=\{Repr(hot_profiles)}, sta=\{Repr(hot_stations)}, conn=\{Repr(hot_connects)}, use=\{Repr(hot_usage)}, chats2=\{Repr(hot_chats_2)})",
    )
    // Dimension 1a: settled same-width hot switches strictly build 0 and drop 0 nodes.
    for row in [
      ("same-stations", hot_sta_same),
      ("same-connects", hot_conn_same),
      ("same-usage", hot_use_same),
      ("rot-profiles", hot_profiles),
      ("rot-stations", hot_stations),
      ("rot-usage", hot_usage),
    ] {
      let (name, m) = row
      assert_eq((m.0, m.1), (0, 0), msg="\{label} hot \{name}: made/let_go must be (0, 0), got \{Repr(m)}")
      assert_true(m.2 <= 600, msg="\{label} hot \{name}: laid \{m.2} exceeded budget 600")
      assert_true(m.3 <= 50, msg="\{label} hot \{name}: measured \{m.3} exceeded budget 50")
      assert_true(m.4 <= 700, msg="\{label} hot \{name}: bindings \{m.4} exceeded budget 700")
    }
    // Dimension 1b: first warm-up / cross-sidebar-width hot switches stay within tight bounded budgets.
    for row in [
      ("same-profiles-warmup", hot_prof_same),
      ("rot-chats-1", hot_chats_1),
      ("rot-connects", hot_connects),
      ("rot-chats-2", hot_chats_2),
    ] {
      let (name, m) = row
      assert_true(m.0 <= 160, msg="\{label} cross-width \{name}: made \{m.0} exceeded budget 160")
      assert_true(m.1 <= 160, msg="\{label} cross-width \{name}: let_go \{m.1} exceeded budget 160")
      assert_true(m.2 <= 2600, msg="\{label} cross-width \{name}: laid \{m.2} exceeded budget 2600")
      assert_true(m.3 <= 200, msg="\{label} cross-width \{name}: measured \{m.3} exceeded budget 200")
      assert_true(m.4 <= 1500, msg="\{label} cross-width \{name}: bindings \{m.4} exceeded budget 1500")
    }
    // Dimension 2: settled at rest, 0 unasked faults, retired garbage drained, no parked place/station/profile timers.
    t.run_for(@sfapptest.kept_glide_over_ms)
    assert_true(t.at_rest(), msg="\{label}: expected at_rest() == true, why=\{t.rest_why()}")
    assert_eq(t.unasked_faults(), [], msg="\{label}: unasked faults")
    let tree = @ui.view_tree().unwrap()
    assert_eq(tree.parked_retired_count(), 0, msg="\{label}: retired garbage drained")
    for by in t.subtree_timeline_bys(tree.root()) {
      assert_false(
        by.contains("station_node") || by.contains("profile") || by.contains("places.mbt"),
        msg="\{label}: parked place/station/profile timer leaked on timeline: \{by}",
      )
    }
  }
  // Medium (600x900, tape layout): hot full-pane switches (connects <-> usage) and in-place profile/station hot switches build 0 nodes.
  let (tm, _, sm, wsm, cm) = wide_budget_open(600.0, 900.0, 2)
  wide_go_place(tm, "connects", cm) |> ignore
  wide_go_place(tm, "usage", cm) |> ignore
  let med_hot_conn = wide_go_place(tm, "connects", cm)
  let med_hot_use = wide_go_place(tm, "usage", cm)
  assert_eq((med_hot_conn.0, med_hot_conn.1), (0, 0), msg="medium-600x900 hot connects: \{Repr(med_hot_conn)}")
  assert_eq((med_hot_use.0, med_hot_use.1), (0, 0), msg="medium-600x900 hot usage: \{Repr(med_hot_use)}")
  wide_go_place(tm, "profiles", cm) |> ignore
  let med_profs = wide_real_profiles(sm, wsm)
  wide_pick_profile(tm, sm, wsm, @settings.Route::Profile(med_profs[0].0, med_profs[0].1)) |> ignore
  let med_hot_ov = wide_pick_profile(tm, sm, wsm, @settings.Route::Profiles(""))
  let med_hot_p1 = wide_pick_profile(tm, sm, wsm, @settings.Route::Profile(med_profs[0].0, med_profs[0].1))
  assert_eq((med_hot_ov.0, med_hot_ov.1), (0, 0), msg="medium-600x900 hot profiles overview: \{Repr(med_hot_ov)}")
  assert_eq((med_hot_p1.0, med_hot_p1.1), (0, 0), msg="medium-600x900 hot profile P1: \{Repr(med_hot_p1)}")
  wide_go_place(tm, "stations", cm) |> ignore
  let med_stas = wide_real_stations(sm, wsm)
  wide_pick_station(tm, sm, wsm, med_stas[1]) |> ignore
  let med_hot_s1 = wide_pick_station(tm, sm, wsm, med_stas[0])
  assert_eq((med_hot_s1.0, med_hot_s1.1), (0, 0), msg="medium-600x900 hot station S1: \{Repr(med_hot_s1)}")
  tm.run_for(@sfapptest.kept_glide_over_ms)
  assert_true(tm.at_rest(), msg="medium-600x900 at_rest")
  assert_eq(tm.unasked_faults(), [], msg="medium-600x900 unasked faults")
  println(
    "wide-budget medium-600x900: hot_conn=\{Repr(med_hot_conn)} hot_use=\{Repr(med_hot_use)} hot_ov=\{Repr(med_hot_ov)} hot_p1=\{Repr(med_hot_p1)} hot_s1=\{Repr(med_hot_s1)}",
  )
}

///|
/// Dimension 3: Parked subtree is excluded from a11y_dump, Tab focus ring, and pointer/keyboard input.
test "wide switch budget (dim 3): parked place is isolated from a11y, focus ring, and input" {
  let (t, _, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0, a11y=true)
  let profiles = wide_real_profiles(src, ws)
  assert_true(profiles.length() >= 2, msg="real-size fixture must have >= 2 profiles")
  wide_go_place(t, "profiles", chat_ref) |> ignore
  wide_pick_profile(t, src, ws, @settings.Route::Profile(profiles[0].0, profiles[0].1)) |> ignore
  let (prof_a11y, prof_tabs, prof_nodes) = kept_reachable(t, 24)
  t.run_for(@sfapptest.kept_switch_over_ms)
  assert_false(prof_a11y.is_empty(), msg="active profiles a11y must be populated")
  assert_true(prof_tabs.length() > 0, msg="active profiles must have Tab-reachable controls")
  let prof_only_nodes : Array[(String, @view.NodeId)] = []
  for e in prof_nodes {
    if e.0 == "添加账号" || e.0.contains("概览") || e.0.contains("zhao.min") {
      prof_only_nodes.push((e.0, e.1))
    }
  }
  assert_true(prof_only_nodes.length() > 0, msg="active profiles must have page-specific focusable nodes, got \{Repr(prof_tabs)}")
  // Switch away to stations: profiles place is now parked.
  wide_go_place(t, "stations", chat_ref) |> ignore
  let tree = @ui.view_tree().unwrap()
  for e in prof_only_nodes {
    assert_false(tree.takes_keys(e.1), msg="parked profiles node \{e.0} must not take keys")
  }
  let (sta_a11y, sta_tabs, _) = kept_reachable(t, 24)
  t.run_for(@sfapptest.kept_switch_over_ms)
  assert_false(sta_a11y.contains("添加账号\n"), msg="parked profiles button must not leak into stations a11y_dump")
  assert_false(
    sta_tabs.iter().any(fn(l) { l == "添加账号" }),
    msg="parked profiles button must not appear in stations Tab ring: \{Repr(sta_tabs)}",
  )
  // Clicking and typing over the main pane while on stations must not mutate the parked profiles route.
  let saved_route = @sfbase.place_pick.get(@sfbase.place_key(ws, "profiles"))
  t.tap(700.0, 300.0)
  t.run_for(@sfapptest.kept_tab_gap_ms)
  t.type_text("parked-isolation-probe")
  t.run_for(@sfapptest.kept_switch_over_ms)
  assert_true(
    @sfbase.place_pick.get(@sfbase.place_key(ws, "profiles")) == saved_route,
    msg="input on stations must not mutate parked profiles route",
  )
  // Hot return to profiles restores a11y; subsequent stations -> profiles return builds/drops 0 nodes.
  wide_go_place(t, "profiles", chat_ref) |> ignore
  assert_true(t.a11y_dump().contains("添加账号"), msg="profiles a11y restored on hot return")
  wide_go_place(t, "stations", chat_ref) |> ignore
  let back = wide_go_place(t, "profiles", chat_ref)
  assert_eq((back.0, back.1), (0, 0), msg="settled hot return to profiles must build/drop 0 nodes, got \{Repr(back)}")
  assert_true(t.a11y_dump().contains("添加账号"), msg="profiles a11y restored on second hot return")
  assert_eq(t.unasked_faults(), [], msg="dim 3 unasked faults")
}

///|
/// Dimension 4: Profiles exact 4 non-pin quota + overview pin + 5th-profile eviction + ahead-read shown_read release.
test "wide switch budget (dim 4): profiles enforces 4 non-pin quota, pins overview, evicts 5th, and releases ahead-reads" {
  let (t, _, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0)
  wide_go_place(t, "profiles", chat_ref) |> ignore
  let profiles = wide_real_profiles(src, ws)
  assert_true(profiles.length() >= 5, msg="real-size fixture needs >= 5 profiles, got \{profiles.length()}")
  let p1 = @settings.Route::Profile(profiles[0].0, profiles[0].1)
  let p2 = @settings.Route::Profile(profiles[1].0, profiles[1].1)
  let p3 = @settings.Route::Profile(profiles[2].0, profiles[2].1)
  let p4 = @settings.Route::Profile(profiles[3].0, profiles[3].1)
  let p5 = @settings.Route::Profile(profiles[4].0, profiles[4].1)
  let overview = @settings.Route::Profiles("")
  // Cold-open P1..P4.
  let c1 = wide_pick_profile(t, src, ws, p1)
  let c2 = wide_pick_profile(t, src, ws, p2)
  let c3 = wide_pick_profile(t, src, ws, p3)
  let c4 = wide_pick_profile(t, src, ws, p4)
  assert_true(c1.0 > 0 && c2.0 > 0 && c3.0 > 0 && c4.0 > 0, msg="initial opens of P1..P4 must build")
  // Return to overview (pinned): hot return with 0 rebuilds, and all 4 non-pin profiles stay parked.
  let h_ov_1 = wide_pick_profile(t, src, ws, overview)
  assert_eq((h_ov_1.0, h_ov_1.1), (0, 0), msg="overview is pinned and must hot-return")
  // Revisit P1 from overview: still parked (overview holds 4 parked profiles).
  let h_p1 = wide_pick_profile(t, src, ws, p1)
  assert_eq((h_p1.0, h_p1.1), (0, 0), msg="P1 must still be parked while on overview (quota=4)")
  // Active on P1 (1 active + 3 parked P2..P4 = 4 non-pin): revisit P2, P3, P4 hot.
  let h_p2 = wide_pick_profile(t, src, ws, p2)
  let h_p3 = wide_pick_profile(t, src, ws, p3)
  let h_p4 = wide_pick_profile(t, src, ws, p4)
  assert_eq((h_p2.0, h_p2.1), (0, 0), msg="P2 hot revisit")
  assert_eq((h_p3.0, h_p3.1), (0, 0), msg="P3 hot revisit")
  assert_eq((h_p4.0, h_p4.1), (0, 0), msg="P4 hot revisit")
  // LRU order is now P1 (oldest), P2, P3, P4 (active). Open 5th profile P5: evicts P1.
  let c5 = wide_pick_profile(t, src, ws, p5)
  assert_true(c5.0 > 0, msg="P5 first open must build")
  assert_true(c5.1 > 0, msg="opening 5th profile must evict and recycle oldest non-pin profile (P1)")
  let tree = @ui.view_tree().unwrap()
  assert_eq(tree.parked_retired_count(), 0, msg="evicted P1 must be recycled after idle frames")
  // Overview must still be pinned and hot-return with 0 rebuilds after eviction.
  let h_ov_2 = wide_pick_profile(t, src, ws, overview)
  assert_eq((h_ov_2.0, h_ov_2.1), (0, 0), msg="pinned overview must never be evicted by LRU")
  // P1 was evicted, so revisiting P1 must rebuild.
  let r_p1 = wide_pick_profile(t, src, ws, p1)
  assert_true(r_p1.0 > 0, msg="evicted P1 must rebuild on revisit")
  // Hot revisit P5 via show_answered: exercises on_take -> after_drawn_frame(shown_read) path cleanly.
  let h_p5 = wide_pick_profile(t, src, ws, p5)
  assert_eq((h_p5.0, h_p5.1), (0, 0), msg="P5 hot revisit via show_answered must build/drop 0 nodes")
  t.run_for(@sfapptest.kept_glide_over_ms)
  assert_true(t.at_rest(), msg="dim 4 at_rest")
  assert_eq(t.unasked_faults(), [], msg="dim 4 unasked faults")
  println(
    "wide-budget dim4 profiles: hot_ov=\{Repr(h_ov_1)} hot_p1=\{Repr(h_p1)} hot_p2=\{Repr(h_p2)} open_p5=\{Repr(c5)} rebuild_p1=\{Repr(r_p1)} hot_p5=\{Repr(h_p5)}",
  )
}

///|
/// Dimension 5: Stations hot return (made == 0), >4 station LRU eviction, and parked station timeline == 0.
test "wide switch budget (dim 5): stations hot-returns within 4 quota, evicts 5th, and clears parked poller timeline" {
  let (t, _, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0)
  wide_go_place(t, "stations", chat_ref) |> ignore
  let stations = wide_real_stations(src, ws)
  assert_true(stations.length() >= 5, msg="real-size fixture needs >= 5 stations, got \{stations.length()}")
  // S1 is already active by default; visit S2, then hot-return to S1.
  let c2 = wide_pick_station(t, src, ws, stations[1])
  assert_true(c2.0 > 0, msg="S2 cold open must build")
  let h1 = wide_pick_station(t, src, ws, stations[0])
  assert_eq((h1.0, h1.1), (0, 0), msg="S1 hot return must build/drop 0 nodes")
  assert_eq(t.unasked_faults(), [], msg="no parked raw read faults on S1 hot return")
  // Visit S3 and S4 (4 stations total: S2, S1, S3, S4 -> all within keeps_max=4).
  let c3 = wide_pick_station(t, src, ws, stations[2])
  let c4 = wide_pick_station(t, src, ws, stations[3])
  assert_true(c3.0 > 0 && c4.0 > 0, msg="S3 and S4 cold opens must build")
  // Hot-revisit S1 (LRU order now: S2 oldest, S3, S4, S1 active).
  let h1_again = wide_pick_station(t, src, ws, stations[0])
  assert_eq((h1_again.0, h1_again.1), (0, 0), msg="S1 hot return within 4-station quota")
  // Open 5th station S5: evicts oldest S2.
  let c5 = wide_pick_station(t, src, ws, stations[4])
  assert_true(c5.0 > 0, msg="S5 first open must build")
  assert_true(c5.1 > 0, msg="opening 5th station must evict and recycle oldest station (S2)")
  let tree = @ui.view_tree().unwrap()
  assert_eq(tree.parked_retired_count(), 0, msg="evicted S2 must be recycled after idle frames")
  // Revisiting evicted S2 must rebuild.
  let r2 = wide_pick_station(t, src, ws, stations[1])
  assert_true(r2.0 > 0, msg="evicted S2 must rebuild on revisit")
  t.run_for(@sfapptest.kept_glide_over_ms)
  assert_true(t.at_rest(), msg="dim 5 at_rest")
  assert_eq(t.unasked_faults(), [], msg="dim 5 unasked faults")
  println("  dim5 timeline_bys=\{Repr(t.subtree_timeline_bys(tree.root()))}")
  println(
    "wide-budget dim5 stations: hot_s1=\{Repr(h1)} hot_s1_again=\{Repr(h1_again)} open_s5=\{Repr(c5)} rebuild_s2=\{Repr(r2)}",
  )
}

///|
/// Dimension 6: Live node count and retained topic payload bytes redline after full wide rotation + eviction.
test "wide switch budget (dim 6): full wide rotation stays within live node and retained payload byte budgets" {
  let wide_alive_nodes_budget = 8000
  let wide_retained_bytes_budget = 1024 * 1024 // 1.000 MB
  let (t, c, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0)
  let tree = @ui.view_tree().unwrap()
  let alive_init = tree.alive()
  let (ways_init, bytes_init) = wide_retained_topic_bytes(c)
  // Full rotation across all wide rail places + 4 profiles + 4 stations.
  wide_go_place(t, "profiles", chat_ref) |> ignore
  let profiles = wide_real_profiles(src, ws)
  for i in 0..<4 {
    wide_pick_profile(t, src, ws, @settings.Route::Profile(profiles[i].0, profiles[i].1)) |> ignore
  }
  wide_pick_profile(t, src, ws, @settings.Route::Profiles("")) |> ignore
  let alive_after_profiles = tree.alive()
  wide_go_place(t, "stations", chat_ref) |> ignore
  let stations = wide_real_stations(src, ws)
  for i in 0..<4 {
    wide_pick_station(t, src, ws, stations[i]) |> ignore
  }
  let alive_after_stations = tree.alive()
  wide_go_place(t, "connects", chat_ref) |> ignore
  wide_go_place(t, "usage", chat_ref) |> ignore
  wide_go_place(t, "chats", chat_ref) |> ignore
  let alive_peak = tree.alive()
  let (ways_peak, bytes_peak) = wide_retained_topic_bytes(c)
  // Trigger eviction on both 5th profile and 5th station, then settle back on chats.
  wide_go_place(t, "profiles", chat_ref) |> ignore
  wide_pick_profile(t, src, ws, @settings.Route::Profile(profiles[4].0, profiles[4].1)) |> ignore
  wide_go_place(t, "stations", chat_ref) |> ignore
  wide_pick_station(t, src, ws, stations[4]) |> ignore
  wide_go_place(t, "chats", chat_ref) |> ignore
  t.run_for(@sfapptest.kept_glide_over_ms)
  let alive_after_evict = tree.alive()
  let (ways_evict, bytes_evict) = wide_retained_topic_bytes(c)
  let img_bytes = t.host_image_bytes_most()
  println("wide-budget dim6 memory & retained bytes table:")
  println(
    "  init:         alive=\{alive_init} (\{wide_fmt_pct(alive_init, wide_alive_nodes_budget)} of \{wide_alive_nodes_budget}), topics=\{ways_init}, retained=\{wide_fmt_kb_mb(bytes_init)} (\{wide_fmt_pct(bytes_init, wide_retained_bytes_budget)} of \{wide_fmt_kb_mb(wide_retained_bytes_budget)})",
  )
  println(
    "  after_4prof:  alive=\{alive_after_profiles} (\{wide_fmt_pct(alive_after_profiles, wide_alive_nodes_budget)})",
  )
  println(
    "  after_4sta:   alive=\{alive_after_stations} (\{wide_fmt_pct(alive_after_stations, wide_alive_nodes_budget)})",
  )
  println(
    "  full_peak:    alive=\{alive_peak} (\{wide_fmt_pct(alive_peak, wide_alive_nodes_budget)}), topics=\{ways_peak}, retained=\{wide_fmt_kb_mb(bytes_peak)} (\{wide_fmt_pct(bytes_peak, wide_retained_bytes_budget)})",
  )
  println(
    "  after_evict:  alive=\{alive_after_evict} (\{wide_fmt_pct(alive_after_evict, wide_alive_nodes_budget)}), topics=\{ways_evict}, retained=\{wide_fmt_kb_mb(bytes_evict)} (\{wide_fmt_pct(bytes_evict, wide_retained_bytes_budget)}), host_img_peak=\{wide_fmt_kb_mb(img_bytes)}",
  )
  assert_true(
    alive_peak <= wide_alive_nodes_budget,
    msg="full rotation live nodes \{alive_peak} exceeded budget \{wide_alive_nodes_budget}",
  )
  assert_true(
    alive_after_evict <= wide_alive_nodes_budget,
    msg="post-eviction live nodes \{alive_after_evict} exceeded budget \{wide_alive_nodes_budget}",
  )
  assert_true(
    bytes_evict <= wide_retained_bytes_budget,
    msg="retained topic payload bytes \{wide_fmt_kb_mb(bytes_evict)} exceeded budget \{wide_fmt_kb_mb(wide_retained_bytes_budget)}",
  )
  assert_eq(tree.parked_retired_count(), 0, msg="dim 6 parked_retired_count must be 0")
  assert_true(t.at_rest(), msg="dim 6 at_rest")
  assert_eq(t.unasked_faults(), [], msg="dim 6 unasked faults")
}
