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
/// Format a percentage `part / total` with 1 decimal place (Int64-safe above 2 MB).
fn wide_fmt_pct(part : Int, total : Int) -> String {
  if total <= 0 {
    return "0.0%"
  }
  let p = part.to_int64()
  let t = total.to_int64()
  let p10 = (p * 1000L + t / 2L) / t
  "\{p10 / 10L}.\{p10 % 10L}%"
}

///|
/// Open a wide/medium Tester on the real-size workspace, settled on a Chat page.
fn wide_budget_open(
  w : Double,
  h : Double,
  platform : Int,
  a11y? : Bool = false,
  local_station? : String = "",
) -> (@ui.Tester, @sfrealsize.RealSizeChanging, @sfbase.Source, String, @sfbase.ChatRef) {
  let c = @sfrealsize.RealSizeChanging::new()
  let src_ref : Ref[@sfbase.Source?] = Ref(None)
  let made = fn() {
    match src_ref.val {
      Some(s) => s
      None => {
        @sfapp.reset()
        let s = {
          ..c.source(@sffixture.fixture("home")),
          reads_ahead: fn() { true },
          gates_opens: fn() { true },
        }
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
  if local_station != "" {
    t.set_app_said("local_station", local_station)
  }
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
/// Pick a profile route (or overview `Route::Profiles("")`) in the profiles place via `show_answered`,
/// verifying that `hand_over_shown` registers `shown_handed(at)` on entry and `make`/`on_take` releases it after draw.
fn wide_pick_profile(
  t : @ui.Tester,
  src : @sfbase.Source,
  ws : String,
  route : @settings.Route,
) -> (Int, Int, Int, Int, Int) {
  let at = match route {
    Profile(a, id) => @sfbase.profile_shown_at(a, id)
    Profiles("") => @sfbase.profile_shown_at("", "")
    _ => ""
  }
  let asks = @sfbase.route_asks(ws, route)
  let handed_on_open = Ref(false)
  let res = wide_budget_step(t, fn() {
    if at != "" {
      @sfbase.show_answered(src, asks, at, fn() {
        handed_on_open.val = @sfbase.shown_handed(at)
        @sfbase.place_pick[@sfbase.place_key(ws, "profiles")] = route
        @sfbase.show_chosen()
      })
    } else {
      @sfbase.place_pick[@sfbase.place_key(ws, "profiles")] = route
      @sfbase.show_chosen()
    }
  })
  if at != "" {
    if asks.length() > 0 && !handed_on_open.val {
      @halt.saying("expected show_answered to hand over ahead-read for \{at}")
    }
    if @sfbase.shown_handed(at) {
      @halt.saying("ahead-read for \{at} leaked in handed_shown after drawn frame")
    }
  }
  res
}

///|
/// Pick a station route in the stations place via the real sidebar click path
/// (`route_open_asks` + `route_open_then` + `show_answered`), verifying ahead-read handoff and release.
fn wide_pick_station(
  t : @ui.Tester,
  src : @sfbase.Source,
  ws : String,
  address : String,
) -> (Int, Int, Int, Int, Int) {
  let route = @settings.Route::Station(address)
  let at = @sfpages.station_shown_at(address)
  let w = @signals.untracked(fn() { @sfbase.workspace_in_view(src).0.unwrap() })
  let handed_on_open = Ref(false)
  let res = wide_budget_step(t, fn() {
    @sfbase.show_answered(
      src,
      @sfbase.route_open_asks(src, w, route),
      at,
      fn() {
        handed_on_open.val = @sfbase.shown_handed(at)
        @sfbase.place_pick[@sfbase.place_key(ws, "stations")] = route
        @sfbase.show_chosen()
      },
      then?=@sfbase.route_open_then(src, w, route),
    )
  })
  if !handed_on_open.val {
    @halt.saying("expected show_answered to hand over ahead-read for station \{address}")
  }
  if @sfbase.shown_handed(at) {
    @halt.saying("ahead-read for station \{address} leaked in handed_shown after drawn frame")
  }
  res
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
/// Sum serialized UTF-8 payload bytes across all cumulative real-size fixture ways read so far
/// (with `naming_too=["job"]` matching `RealSizeChanging::held_of`).
fn wide_cumulative_fixture_bytes(c : @sfrealsize.RealSizeChanging) -> (Int, Int) {
  let mut total = 0
  let ways = c.ways()
  for way in ways {
    match @sfrealsize.real_size_value(way.0, way.1, naming_too=["job"]) {
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
    // Measured baseline identical across 60/120/24/7 fps:
    //   1280x800: laid <= 368, measured == 0, bindings <= 395
    //   1440x900: laid <= 406, measured == 0, bindings <= 487
    // Ceilings tightened to ~1.35x peak measured baseline.
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
      assert_true(m.2 <= 550, msg="\{label} hot \{name}: peak laid \{m.2} exceeded budget 550")
      assert_true(m.3 <= 16, msg="\{label} hot \{name}: peak measured \{m.3} exceeded budget 16")
      assert_true(m.4 <= 650, msg="\{label} hot \{name}: peak bindings \{m.4} exceeded budget 650")
    }
    // Dimension 1b: first warm-up (1280x800 profiles overview virtualized slot settle after initial sidebar layout)
    // and cross-sidebar-width hot switches (pane width toggles between ~950 px with sidebar and ~1220 px without).
    // Measured baseline identical across 60/120/24/7 fps:
    //   made <= 128, let_go <= 112, peak_laid <= 431, peak_measured <= 64, peak_bindings <= 453.
    // Ceilings tightened to ~1.35x peak measured baseline.
    for row in [
      ("same-profiles-warmup", hot_prof_same),
      ("rot-chats-1", hot_chats_1),
      ("rot-connects", hot_connects),
      ("rot-chats-2", hot_chats_2),
    ] {
      let (name, m) = row
      assert_true(m.0 <= 160, msg="\{label} cross-width \{name}: made \{m.0} exceeded budget 160")
      assert_true(m.1 <= 145, msg="\{label} cross-width \{name}: let_go \{m.1} exceeded budget 145")
      assert_true(m.2 <= 600, msg="\{label} cross-width \{name}: peak laid \{m.2} exceeded budget 600")
      assert_true(m.3 <= 85, msg="\{label} cross-width \{name}: peak measured \{m.3} exceeded budget 85")
      assert_true(m.4 <= 600, msg="\{label} cross-width \{name}: peak bindings \{m.4} exceeded budget 600")
    }
    // Dimension 2: settled at rest, 0 unasked faults, retired garbage drained, and 0 parked timers across the whole tree.
    // `tree.due_count()` counts all live timeline entries (including parked `parent == -1` subtrees and `later=true` timers),
    // while `subtree_timeline_count(tree.root())` counts only mounted entries; equality proves parked subtrees own 0 timers.
    t.run_for(@sfapptest.kept_glide_over_ms)
    assert_true(t.at_rest(), msg="\{label}: expected at_rest() == true, why=\{t.rest_why()}")
    assert_eq(t.unasked_faults(), [], msg="\{label}: unasked faults")
    let tree = @ui.view_tree().unwrap()
    assert_eq(tree.parked_retired_count(), 0, msg="\{label}: retired garbage drained")
    let mounted_timelines = t.subtree_timeline_count(tree.root())
    let total_timelines = tree.due_count()
    assert_eq(
      total_timelines,
      mounted_timelines,
      msg="\{label}: parked subtrees must own 0 timeline entries (total=\{total_timelines}, mounted=\{mounted_timelines})",
    )
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
  let med_tree = @ui.view_tree().unwrap()
  assert_eq(
    med_tree.due_count(),
    tm.subtree_timeline_count(med_tree.root()),
    msg="medium-600x900 parked subtrees must own 0 timeline entries",
  )
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
/// Dimension 5: Stations hot return (made == 0), >4 station LRU eviction, and parked local-station poller timeline == 0.
test "wide switch budget (dim 5): stations hot-returns within 4 quota, evicts 5th, and clears parked poller timeline" {
  // Bind stations[0] ("ws1/st1") as `this_machine()` so station_node installs its `while_active_every` poller.
  let local_json = "{\"data\":\"~/.stillfail\",\"runner\":\"service\",\"workspace\":{\"id\":\"ws1\",\"station\":\"st1\",\"stationName\":\"Maple\"}}"
  let (t, _, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0, local_station=local_json)
  wide_go_place(t, "stations", chat_ref) |> ignore
  let stations = wide_real_stations(src, ws)
  assert_true(stations.length() >= 5, msg="real-size fixture needs >= 5 stations, got \{stations.length()}")
  assert_eq(stations[0], "ws1/st1", msg="first real-size station must match local_station binding")
  let tree = @ui.view_tree().unwrap()
  // Positive control: active local station (ws/maple) owns a live `station_node.mbt` poller on Tree::timeline.
  let active_bys = t.subtree_timeline_bys(tree.root())
  assert_true(
    active_bys.iter().any(fn(b) { b.contains("station_node.mbt") }),
    msg="active local station ws/maple must own while_active_every poller, got \{Repr(active_bys)}",
  )
  let active_due = tree.due_count()
  assert_eq(active_due, t.subtree_timeline_count(tree.root()), msg="no parked timers on initial stations open")
  // Switch to S2 (ws1/st2): S1 is parked (parent == -1); whole-tree due_count must still equal mounted count
  // (if parked S1 leaked its poller, due_count would jump to active_due + 1 > mounted).
  let c2 = wide_pick_station(t, src, ws, stations[1])
  assert_true(c2.0 > 0, msg="S2 cold open must build")
  let parked_due = tree.due_count()
  let parked_mounted = t.subtree_timeline_count(tree.root())
  assert_eq(
    parked_due,
    parked_mounted,
    msg="parked S1 must own 0 entries in Tree::timeline (total=\{parked_due}, mounted=\{parked_mounted})",
  )
  // Parking the entire stations place (switch to connects) must drop whole-tree due_count by 1 and clear all station_node pollers.
  wide_go_place(t, "connects", chat_ref) |> ignore
  let away_due = tree.due_count()
  let away_mounted = t.subtree_timeline_count(tree.root())
  let away_bys = t.subtree_timeline_bys(tree.root())
  assert_eq(away_due, away_mounted, msg="parked stations place must own 0 entries in Tree::timeline")
  assert_eq(away_due, active_due - 1, msg="parking stations place must drop whole-tree due_count by 1")
  assert_false(
    away_bys.iter().any(fn(b) { b.contains("station_node.mbt") }),
    msg="no station_node poller may remain when stations place is parked: \{Repr(away_bys)}",
  )
  // Return to stations place, then hot-return to S1 (ws1/st1): 0 nodes made/dropped, ahead-read released, poller resumes.
  wide_go_place(t, "stations", chat_ref) |> ignore
  let h1 = wide_pick_station(t, src, ws, stations[0])
  assert_eq((h1.0, h1.1), (0, 0), msg="S1 hot return must build/drop 0 nodes")
  assert_eq(t.unasked_faults(), [], msg="no parked raw read faults on S1 hot return")
  assert_eq(tree.due_count(), active_due, msg="woken ws1/st1 must resume its while_active_every poller")
  assert_true(
    t.subtree_timeline_bys(tree.root()).iter().any(fn(b) { b.contains("station_node.mbt") }),
    msg="woken ws1/st1 poller must reappear on Tree::timeline",
  )
  // Visit S3 and S4 (4 stations total: S2, S1, S3, S4 -> all within keeps_max=4).
  let c3 = wide_pick_station(t, src, ws, stations[2])
  let c4 = wide_pick_station(t, src, ws, stations[3])
  assert_true(c3.0 > 0 && c4.0 > 0, msg="S3 and S4 cold opens must build")
  // Hot-revisit S1 (LRU order now: S2 oldest, S3, S4, S1 active).
  let h1_again = wide_pick_station(t, src, ws, stations[0])
  assert_eq((h1_again.0, h1_again.1), (0, 0), msg="S1 hot return within 4-station quota")
  // Open 5th station S5: evicts oldest S2, parks S1 (no leaked timers in parked pool).
  let c5 = wide_pick_station(t, src, ws, stations[4])
  assert_true(c5.0 > 0, msg="S5 first open must build")
  assert_true(c5.1 > 0, msg="opening 5th station must evict and recycle oldest station (S2)")
  assert_eq(tree.parked_retired_count(), 0, msg="evicted S2 must be recycled after idle frames")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="parked stations own 0 timers after S5 open")
  // Revisiting evicted S2 must rebuild.
  let r2 = wide_pick_station(t, src, ws, stations[1])
  assert_true(r2.0 > 0, msg="evicted S2 must rebuild on revisit")
  t.run_for(@sfapptest.kept_glide_over_ms)
  assert_true(t.at_rest(), msg="dim 5 at_rest")
  assert_eq(t.unasked_faults(), [], msg="dim 5 unasked faults")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="dim 5 parked timeline count == 0 at rest")
  println(
    "wide-budget dim5 stations: active_due=\{active_due} parked_s1_due=\{parked_due} away_place_due=\{away_due} hot_s1=\{Repr(h1)} hot_s1_again=\{Repr(h1_again)} open_s5=\{Repr(c5)} rebuild_s2=\{Repr(r2)}",
  )
}

///|
/// Dimension 6: Live node count and lasting-lists `last_said` cache bytes redline after full wide rotation + eviction.
/// Note: `last_said_stats()` measures only the client's lasting lists `last_said` cache (places SWR lists);
/// parked pages release their own station/profile topic holds via `rest(drop_holds=true)` and are outside this cache.
/// Budgets tightened to ~1.3x measured peak (60/120/24/7 fps identical).
test "wide switch budget (dim 6): full wide rotation stays within live node and retained payload byte budgets" {
  let wide_alive_nodes_budget = 7500
  let wide_last_said_bytes_budget = 256 * 1024 // 256.00 KB (0.250 MB) lasting lists last_said cache ceiling
  let wide_fixture_cum_bytes_budget = 768 * 1024 // 768.00 KB (0.750 MB) cumulative fixture reference ceiling
  let (t, c, src, ws, chat_ref) = wide_budget_open(1280.0, 800.0, 0)
  let tree = @ui.view_tree().unwrap()
  let alive_init = tree.alive()
  let (ls_init_n, ls_init_b) = @sfbase.last_said_stats()
  let (ways_init, cum_init) = wide_cumulative_fixture_bytes(c)
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
  // stations[0] is already active by default; visit stations[1..4] so 4 distinct stations are populated.
  for i in 1..<4 {
    wide_pick_station(t, src, ws, stations[i]) |> ignore
  }
  let alive_after_stations = tree.alive()
  wide_go_place(t, "connects", chat_ref) |> ignore
  wide_go_place(t, "usage", chat_ref) |> ignore
  wide_go_place(t, "chats", chat_ref) |> ignore
  let alive_peak = tree.alive()
  let (ls_peak_n, ls_peak_b) = @sfbase.last_said_stats()
  let (ways_peak, cum_peak) = wide_cumulative_fixture_bytes(c)
  // Trigger eviction on both 5th profile and 5th station, then settle back on chats.
  wide_go_place(t, "profiles", chat_ref) |> ignore
  wide_pick_profile(t, src, ws, @settings.Route::Profile(profiles[4].0, profiles[4].1)) |> ignore
  wide_go_place(t, "stations", chat_ref) |> ignore
  wide_pick_station(t, src, ws, stations[4]) |> ignore
  wide_go_place(t, "chats", chat_ref) |> ignore
  t.run_for(@sfapptest.kept_glide_over_ms)
  let alive_after_evict = tree.alive()
  let (ls_evict_n, ls_evict_b) = @sfbase.last_said_stats()
  let (ways_evict, cum_evict) = wide_cumulative_fixture_bytes(c)
  let img_bytes = t.host_image_bytes_most()
  println("wide-budget dim6 memory & lasting lists last_said cache table:")
  println(
    "  init:         alive=\{alive_init} (\{wide_fmt_pct(alive_init, wide_alive_nodes_budget)} of \{wide_alive_nodes_budget}), lasting_last_said=\{ls_init_n} entries / \{wide_fmt_kb_mb(ls_init_b)} (\{wide_fmt_pct(ls_init_b, wide_last_said_bytes_budget)}), cum_fixture=\{ways_init} topics / \{wide_fmt_kb_mb(cum_init)} (\{wide_fmt_pct(cum_init, wide_fixture_cum_bytes_budget)})",
  )
  println(
    "  after_4prof:  alive=\{alive_after_profiles} (\{wide_fmt_pct(alive_after_profiles, wide_alive_nodes_budget)})",
  )
  println(
    "  after_4sta:   alive=\{alive_after_stations} (\{wide_fmt_pct(alive_after_stations, wide_alive_nodes_budget)})",
  )
  println(
    "  full_peak:    alive=\{alive_peak} (\{wide_fmt_pct(alive_peak, wide_alive_nodes_budget)}), lasting_last_said=\{ls_peak_n} entries / \{wide_fmt_kb_mb(ls_peak_b)} (\{wide_fmt_pct(ls_peak_b, wide_last_said_bytes_budget)}), cum_fixture=\{ways_peak} topics / \{wide_fmt_kb_mb(cum_peak)} (\{wide_fmt_pct(cum_peak, wide_fixture_cum_bytes_budget)})",
  )
  println(
    "  after_evict:  alive=\{alive_after_evict} (\{wide_fmt_pct(alive_after_evict, wide_alive_nodes_budget)}), lasting_last_said=\{ls_evict_n} entries / \{wide_fmt_kb_mb(ls_evict_b)} (\{wide_fmt_pct(ls_evict_b, wide_last_said_bytes_budget)}), cum_fixture=\{ways_evict} topics / \{wide_fmt_kb_mb(cum_evict)} (\{wide_fmt_pct(cum_evict, wide_fixture_cum_bytes_budget)}), host_img_peak=\{wide_fmt_kb_mb(img_bytes)}",
  )
  assert_true(
    alive_peak <= wide_alive_nodes_budget,
    msg="full rotation live nodes \{alive_peak} exceeded budget \{wide_alive_nodes_budget}",
  )
  assert_true(
    alive_after_evict <= wide_alive_nodes_budget,
    msg="post-eviction live nodes \{alive_after_evict} exceeded budget \{wide_alive_nodes_budget}",
  )
  // Relative eviction check: opening 5th profile & 5th station must recycle old branches rather than growing unboundedly.
  assert_true(
    alive_after_evict <= alive_peak + 100,
    msg="post-eviction live nodes \{alive_after_evict} grew past full_peak \{alive_peak} + 100 (eviction did not reclaim)",
  )
  assert_true(
    ls_evict_b <= wide_last_said_bytes_budget,
    msg="lasting lists last_said cache bytes \{wide_fmt_kb_mb(ls_evict_b)} exceeded budget \{wide_fmt_kb_mb(wide_last_said_bytes_budget)}",
  )
  assert_true(
    cum_evict <= wide_fixture_cum_bytes_budget,
    msg="cumulative fixture payload bytes \{wide_fmt_kb_mb(cum_evict)} exceeded budget \{wide_fmt_kb_mb(wide_fixture_cum_bytes_budget)}",
  )
  assert_eq(tree.parked_retired_count(), 0, msg="dim 6 parked_retired_count must be 0")
  assert_true(t.at_rest(), msg="dim 6 at_rest")
  assert_eq(t.unasked_faults(), [], msg="dim 6 unasked faults")
  assert_eq(tree.due_count(), t.subtree_timeline_count(tree.root()), msg="dim 6 parked timeline count == 0")
}
