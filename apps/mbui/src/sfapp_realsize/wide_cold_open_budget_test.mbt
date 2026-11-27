// Full-set Place cold-open 5-dimension benchmark & regression budget gates on real-size workspace payloads
// (RealSizeChanging) for Large (1280x800) and Medium (600x900).
//
// Measures every Place and key cold-open target on 5 dimensions:
//   (sum_made, sum_let_go, peak_laid, peak_measured, peak_bindings)
// together with post-open `alive` live node count (% of 7,500 redline), `delta_alive`,
// lasting-lists `last_said` cache bytes (KB/MB), and cumulative fixture payload bytes (KB/MB).
// Also asserts `at_rest() == true`, `unasked_faults() == []`, and
// `tree.due_count() == t.subtree_timeline_count(tree.root())` (0 parked timeline leaks).

///|
/// Open a fresh wide/medium Tester on the real-size workspace (constructed in this file so its host image decode bar
/// is tracked independently from `wide_switch_budget_test.mbt`) and return the 5-dim cold-open metrics
/// `(sum_made, sum_let_go, peak_laid, peak_measured, peak_bindings)` of the initial opening itself from journal index 0.
fn wide_cold_open_init(
  w : Double,
  h : Double,
  platform : Int,
  a11y? : Bool = false,
) -> (
  @ui.Tester,
  @sfrealsize.RealSizeChanging,
  @sfbase.Source,
  String,
  @sfbase.ChatRef,
  (Int, Int, Int, Int, Int),
) {
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
  if a11y {
    t.set_a11y(true)
  }
  t.run_for(@sfapptest.squeeze_opening)
  t.run_for(@sfapptest.kept_switch_over_ms)
  let mut init_m = (0, 0, 0, 0, 0)
  for e in @ui.journal() {
    match e {
      Work({ what: Frame(f), .. }) =>
        init_m = (
          init_m.0 + f.made,
          init_m.1 + f.let_go,
          @cmp.maximum(init_m.2, f.laid),
          @cmp.maximum(init_m.3, f.measured),
          @cmp.maximum(init_m.4, f.bindings),
        )
      _ => ()
    }
  }
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
  (t, c, src, ws, chat_ref, init_m)
}

///|
fn wide_cold_open(
  w : Double,
  h : Double,
  platform : Int,
  a11y? : Bool = false,
) -> (@ui.Tester, @sfrealsize.RealSizeChanging, @sfbase.Source, String, @sfbase.ChatRef) {
  let (t, c, src, ws, chat_ref, _) = wide_cold_open_init(w, h, platform, a11y~)
  (t, c, src, ws, chat_ref)
}

///|
/// Tight ~1.20x per-target 5-dim regression ceilings `(made, let_go, laid, measured, bindings)` locked to post-PR-B4
/// real-size measurements (strictly 0 when measured is 0; +4 floor for tiny non-zero counts). Only lowered, never raised.
let wide_cold_open_budgets : Map[String, (Int, Int, Int, Int, Int)] = {
  // Large (1280x800) full Place & Settings subpage sweep (29 targets)
  "large/chats(init)": (1632, 5, 1067, 102, 1554),
  "large/chats/mine": (1145, 694, 786, 99, 1024),
  "large/chats/watching": (38, 734, 66, 5, 75),
  "large/chats/hidden": (38, 21, 66, 5, 75),
  "large/archive": (1310, 694, 1092, 155, 1661),
  "large/board": (1655, 65, 1860, 207, 2039),
  // Hotspot #1 (PR-B4): virtualized attention_rows_node + flattened attention_item_node (was 1756/0/1479/287/2294)
  "large/attention": (281, 0, 207, 39, 494),
  "large/new_chat": (194, 0, 132, 18, 216),
  "large/files": (608, 28, 503, 84, 975),
  "large/drive": (179, 0, 179, 15, 274),
  "large/remote": (365, 0, 310, 35, 473),
  // Hotspot #2 (PR-B4): shared QuotaMeasCache + flattened fill_chip_node / quota_chips_node (was 766/0/645/139/1048)
  "large/stations(list+st1)": (905, 0, 760, 167, 1229),
  "large/station_detail(st2)": (430, 0, 348, 78, 512),
  // Hotspot #2 (PR-B4): shared QuotaMeasCache + flattened fill_chip_node / quota_chips_node (was 870/0/698/254/1034)
  "large/profiles(overview)": (996, 0, 790, 305, 1164),
  "large/profile_detail(p1)": (39, 0, 68, 7, 41),
  "large/connects": (744, 69, 783, 120, 770),
  "large/usage": (606, 69, 783, 221, 924),
  "large/vault": (378, 69, 783, 57, 508),
  "large/settings(home/Me)": (476, 0, 408, 82, 563),
  "large/settings/appearance": (323, 191, 262, 78, 504),
  "large/settings/workspace": (430, 323, 305, 66, 350),
  "large/settings/security": (285, 430, 231, 38, 287),
  "large/settings/memories": (244, 285, 188, 75, 238),
  "large/settings/mcp": (536, 244, 393, 123, 486),
  "large/settings/projects": (171, 536, 159, 22, 189),
  "large/settings/changelog": (359, 171, 290, 101, 377),
  "large/settings/notifications": (210, 359, 182, 56, 240),
  "large/settings/shortcuts": (234, 210, 186, 63, 281),
  "large/settings/about": (123, 234, 114, 13, 105),
  // Medium (600x900) key Place sweep (12 targets)
  "medium/chats(init)": (1576, 5, 1064, 98, 1583),
  "medium/archive": (1410, 790, 1030, 188, 1930),
  "medium/files": (576, 28, 492, 78, 972),
  "medium/remote": (368, 6, 327, 35, 550),
  "medium/stations(list+st1)": (910, 6, 790, 164, 1293),
  "medium/station_detail(st2)": (420, 0, 358, 74, 513),
  "medium/profiles(overview)": (957, 6, 800, 282, 1212),
  "medium/profile_detail(p1)": (23, 0, 70, 6, 35),
  "medium/connects": (1817, 2283, 1190, 156, 1816),
  "medium/usage": (1865, 2283, 1284, 244, 2105),
  "medium/vault": (1730, 2283, 1120, 135, 1780),
  "medium/settings(home/Me)": (461, 6, 407, 75, 564),
}

///|
/// Assert rest, zero unasked faults, zero parked timeline leaks, 5-dim regression budgets, and print one report row.
fn wide_cold_record(
  label : String,
  m : (Int, Int, Int, Int, Int),
  t : @ui.Tester,
  c : @sfrealsize.RealSizeChanging,
  alive_before : Int,
) -> Unit raise {
  let redline_nodes = 7500
  let redline_ls = 256 * 1024
  let redline_cum = 768 * 1024
  t.run_for(@sfapptest.kept_glide_over_ms)
  let tree = @ui.view_tree().unwrap()
  let alive = tree.alive()
  let delta_alive = alive - alive_before
  let (ls_n, ls_b) = @sfbase.last_said_stats()
  let (ways_n, cum_b) = wide_cumulative_fixture_bytes(c)
  println(
    "cold-open | \{label} | made=\{m.0} let_go=\{m.1} laid=\{m.2} measured=\{m.3} bindings=\{m.4} | alive=\{alive} (\{wide_fmt_pct(alive, redline_nodes)}) delta=\{delta_alive} | last_said=\{ls_n}/\{wide_fmt_kb_mb(ls_b)} (\{wide_fmt_pct(ls_b, redline_ls)}) | cum_fixture=\{ways_n}/\{wide_fmt_kb_mb(cum_b)} (\{wide_fmt_pct(cum_b, redline_cum)})",
  )
  assert_true(t.at_rest(), msg="\{label}: expected at_rest() == true, why=\{t.rest_why()}")
  assert_eq(t.unasked_faults(), [], msg="\{label}: unasked faults")
  assert_eq(
    tree.due_count(),
    t.subtree_timeline_count(tree.root()),
    msg="\{label}: parked subtrees must own 0 timeline entries (total=\{tree.due_count()}, mounted=\{t.subtree_timeline_count(tree.root())})",
  )
  assert_true(alive <= redline_nodes, msg="\{label}: alive \{alive} exceeded redline \{redline_nodes}")
  match wide_cold_open_budgets.get(label) {
    Some((b_made, b_let_go, b_laid, b_meas, b_bind)) => {
      assert_true(m.0 <= b_made, msg="\{label}: made \{m.0} > budget \{b_made}")
      assert_true(m.1 <= b_let_go, msg="\{label}: let_go \{m.1} > budget \{b_let_go}")
      assert_true(m.2 <= b_laid, msg="\{label}: laid \{m.2} > budget \{b_laid}")
      assert_true(m.3 <= b_meas, msg="\{label}: measured \{m.3} > budget \{b_meas}")
      assert_true(m.4 <= b_bind, msg="\{label}: bindings \{m.4} > budget \{b_bind}")
    }
    None => fail("\{label}: missing entry in wide_cold_open_budgets")
  }
}

///|
test "wide cold-open budget: Large (1280x800) full Place and key sub-page cold-open 5-dim sweep" {
  // 1. Initial cold open: chats (Home + rail + chats sidebar + first chat)
  let (t0, c0, src0, ws0, chat0, init_m) = wide_cold_open_init(1280.0, 800.0, 0)
  wide_cold_record("large/chats(init)", init_m, t0, c0, 0)

  // 2. Chat list filter places: mine, watching, hidden, archive
  let alive0 = @ui.view_tree().unwrap().alive()
  let m_mine = wide_budget_step(t0, fn() { @sfbase.app.filters[ws0] = "mine" })
  wide_cold_record("large/chats/mine", m_mine, t0, c0, alive0)

  let alive_pre_watch = @ui.view_tree().unwrap().alive()
  let m_watching = wide_budget_step(t0, fn() { @sfbase.app.filters[ws0] = "watching" })
  wide_cold_record("large/chats/watching", m_watching, t0, c0, alive_pre_watch)

  let alive_pre_hidden = @ui.view_tree().unwrap().alive()
  let m_hidden = wide_budget_step(t0, fn() { @sfbase.app.filters[ws0] = "hidden" })
  wide_cold_record("large/chats/hidden", m_hidden, t0, c0, alive_pre_hidden)

  // Reset filter back to all, then open archive
  let (t_arch, c_arch, _, _, _) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_arch = @ui.view_tree().unwrap().alive()
  let m_arch = wide_budget_step(t_arch, fn() { @sfbase.app.nav.replace_above(1, [Archived]) })
  wide_cold_record("large/archive", m_arch, t_arch, c_arch, alive_pre_arch)

  // 3. Board (experimental board place)
  let (t_board, c_board, src_board, _, _) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_board = @ui.view_tree().unwrap().alive()
  let m_board = wide_budget_step(t_board, fn() {
    @sfbase.board_feature.set(true)
    @sfbase.board_set(src_board, true)
    @sfbase.go_place("chats", kept=true) |> ignore
  })
  wide_cold_record("large/board", m_board, t_board, c_board, alive_pre_board)

  // 3b. Attention (bell panel beside rail)
  let (t_att, c_att, _, _, _) = wide_cold_open(1280.0, 800.0, 0, a11y=true)
  let bell_btn = t_att
    .semantics()
    .iter()
    .find_first(fn(s) { s.role == Button && s.label == @sf.t("web-main.attention.entry") })
  match bell_btn {
    Some(b) => {
      let alive_pre_att = @ui.view_tree().unwrap().alive()
      t_att.tree_frames_from_now()
      t_att.tap(b.rect.0 + b.rect.2 / 2.0, b.rect.1 + b.rect.3 / 2.0)
      t_att.run_for(@sfapptest.kept_switch_over_ms)
      let m_att = t_att.tree_frames().fold(init=(0, 0, 0, 0, 0), fn(a, f) {
        (
          a.0 + f.made,
          a.1 + f.let_go,
          @cmp.maximum(a.2, f.laid),
          @cmp.maximum(a.3, f.measured),
          @cmp.maximum(a.4, f.bindings),
        )
      })
      wide_cold_record("large/attention", m_att, t_att, c_att, alive_pre_att)
      assert_eq(t_att.audit(), [])
      // Scroll inside the virtualized attention panel and verify off-screen items materialize cleanly with 0 audit faults.
      let att_scroll_x = b.rect.0 + b.rect.2 + 140.0
      let att_scroll_y = 260.0
      t_att.wheel(att_scroll_x, att_scroll_y, 260.0)
      t_att.run_for(@sfapptest.kept_glide_over_ms)
      assert_eq(t_att.audit(), [])
      assert_true(t_att.at_rest(), msg="large/attention after scroll: expected at_rest()")
    }
    None => fail("rail attention bell button not found in semantics")
  }

  // 4. NewChat
  let (t_new, c_new, _, _, _) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_new = @ui.view_tree().unwrap().alive()
  let m_new = wide_budget_step(t_new, fn() { @sfbase.open_page(NewChat) })
  wide_cold_record("large/new_chat", m_new, t_new, c_new, alive_pre_new)

  // 5. Files + Drive
  let (t_files, c_files, src_files, ws_files, chat_files) = wide_cold_open(1280.0, 800.0, 0)
  let stations_f = wide_real_stations(src_files, ws_files)
  let alive_pre_files = @ui.view_tree().unwrap().alive()
  let m_files = wide_go_place(t_files, "files", chat_files)
  wide_cold_record("large/files", m_files, t_files, c_files, alive_pre_files)
  let alive_pre_drive = @ui.view_tree().unwrap().alive()
  let m_drive = wide_budget_step(t_files, fn() {
    @sfbase.open_page(Drive({ station: stations_f[0], root: None, path: "" }))
  })
  wide_cold_record("large/drive", m_drive, t_files, c_files, alive_pre_drive)

  // 6. Remote
  let (t_rem, c_rem, _, _, chat_rem) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_rem = @ui.view_tree().unwrap().alive()
  let m_rem = wide_go_place(t_rem, "remote", chat_rem)
  wide_cold_record("large/remote", m_rem, t_rem, c_rem, alive_pre_rem)

  // 7. Stations (sidebar + default st1) + Station Detail (st2)
  let (t_sta, c_sta, src_sta, ws_sta, chat_sta) = wide_cold_open(1280.0, 800.0, 0)
  let stations = wide_real_stations(src_sta, ws_sta)
  let alive_pre_sta = @ui.view_tree().unwrap().alive()
  let m_sta = wide_go_place(t_sta, "stations", chat_sta)
  wide_cold_record("large/stations(list+st1)", m_sta, t_sta, c_sta, alive_pre_sta)
  assert_eq(t_sta.audit().filter(fn(s) { !s.contains("edge_node.mbt") }), [])
  let alive_pre_sta2 = @ui.view_tree().unwrap().alive()
  let m_sta2 = wide_pick_station(t_sta, src_sta, ws_sta, stations[1])
  wide_cold_record("large/station_detail(st2)", m_sta2, t_sta, c_sta, alive_pre_sta2)

  // 8. Profiles (sidebar + overview) + Profile Detail (p1)
  let (t_prof, c_prof, src_prof, ws_prof, chat_prof) = wide_cold_open(1280.0, 800.0, 0)
  let profiles = wide_real_profiles(src_prof, ws_prof)
  let alive_pre_prof = @ui.view_tree().unwrap().alive()
  let m_prof = wide_go_place(t_prof, "profiles", chat_prof)
  wide_cold_record("large/profiles(overview)", m_prof, t_prof, c_prof, alive_pre_prof)
  assert_eq(t_prof.audit().filter(fn(s) { !s.contains("edge_node.mbt") }), [])
  let alive_pre_p1 = @ui.view_tree().unwrap().alive()
  let m_p1 = wide_pick_profile(t_prof, src_prof, ws_prof, @settings.Route::Profile(profiles[0].0, profiles[0].1))
  wide_cold_record("large/profile_detail(p1)", m_p1, t_prof, c_prof, alive_pre_p1)

  // 9. Bare full-pane rail places: connects, usage, vault
  let (t_conn, c_conn, _, _, chat_conn) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_conn = @ui.view_tree().unwrap().alive()
  let m_conn = wide_go_place(t_conn, "connects", chat_conn)
  wide_cold_record("large/connects", m_conn, t_conn, c_conn, alive_pre_conn)

  let (t_use, c_use, _, _, chat_use) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_use = @ui.view_tree().unwrap().alive()
  let m_use = wide_go_place(t_use, "usage", chat_use)
  wide_cold_record("large/usage", m_use, t_use, c_use, alive_pre_use)

  let (t_vault, c_vault, _, _, chat_vault) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_vault = @ui.view_tree().unwrap().alive()
  let m_vault = wide_go_place(t_vault, "vault", chat_vault)
  wide_cold_record("large/vault", m_vault, t_vault, c_vault, alive_pre_vault)

  // 10. Settings home (sidebar + Me) & typical Settings subpages
  let (t_set, c_set, _, _, _) = wide_cold_open(1280.0, 800.0, 0)
  let alive_pre_set = @ui.view_tree().unwrap().alive()
  let m_set = wide_budget_step(t_set, fn() { @sfbase.open_page(Settings) })
  wide_cold_record("large/settings(home/Me)", m_set, t_set, c_set, alive_pre_set)

  let subpages : Array[(String, @settings.Route)] = [
    ("large/settings/appearance", Appearance),
    ("large/settings/workspace", Workspace),
    ("large/settings/security", Security),
    ("large/settings/memories", Memories),
    ("large/settings/mcp", McpServers),
    ("large/settings/projects", Projects),
    ("large/settings/changelog", Changelog),
    ("large/settings/notifications", Notifications),
    ("large/settings/shortcuts", Shortcuts),
    ("large/settings/about", About),
  ]
  for sub in subpages {
    let alive_pre = @ui.view_tree().unwrap().alive()
    let m_sub = wide_budget_step(t_set, fn() { @sfbase.app.nav.replace_above(1, [Setting(sub.1)]) })
    wide_cold_record(sub.0, m_sub, t_set, c_set, alive_pre)
  }
  ignore((src0, chat0))
}

///|
test "wide cold-open budget: Medium (600x900) key Place cold-open 5-dim sweep" {
  let (t0, c0, _, _, _, init_m) = wide_cold_open_init(600.0, 900.0, 2)
  wide_cold_record("medium/chats(init)", init_m, t0, c0, 0)

  let (t_arch, c_arch, _, _, _) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_arch = @ui.view_tree().unwrap().alive()
  let m_arch = wide_budget_step(t_arch, fn() { @sfbase.app.nav.replace_above(1, [Archived]) })
  wide_cold_record("medium/archive", m_arch, t_arch, c_arch, alive_pre_arch)

  let (t_files, c_files, _, _, chat_files) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_files = @ui.view_tree().unwrap().alive()
  let m_files = wide_go_place(t_files, "files", chat_files)
  wide_cold_record("medium/files", m_files, t_files, c_files, alive_pre_files)

  let (t_rem, c_rem, _, _, chat_rem) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_rem = @ui.view_tree().unwrap().alive()
  let m_rem = wide_go_place(t_rem, "remote", chat_rem)
  wide_cold_record("medium/remote", m_rem, t_rem, c_rem, alive_pre_rem)

  let (t_sta, c_sta, src_sta, ws_sta, chat_sta) = wide_cold_open(600.0, 900.0, 2)
  let stations = wide_real_stations(src_sta, ws_sta)
  let alive_pre_sta = @ui.view_tree().unwrap().alive()
  let m_sta = wide_go_place(t_sta, "stations", chat_sta)
  wide_cold_record("medium/stations(list+st1)", m_sta, t_sta, c_sta, alive_pre_sta)
  let alive_pre_sta2 = @ui.view_tree().unwrap().alive()
  let m_sta2 = wide_pick_station(t_sta, src_sta, ws_sta, stations[1])
  wide_cold_record("medium/station_detail(st2)", m_sta2, t_sta, c_sta, alive_pre_sta2)

  let (t_prof, c_prof, src_prof, ws_prof, chat_prof) = wide_cold_open(600.0, 900.0, 2)
  let profiles = wide_real_profiles(src_prof, ws_prof)
  let alive_pre_prof = @ui.view_tree().unwrap().alive()
  let m_prof = wide_go_place(t_prof, "profiles", chat_prof)
  wide_cold_record("medium/profiles(overview)", m_prof, t_prof, c_prof, alive_pre_prof)
  let alive_pre_p1 = @ui.view_tree().unwrap().alive()
  let m_p1 = wide_pick_profile(t_prof, src_prof, ws_prof, @settings.Route::Profile(profiles[0].0, profiles[0].1))
  wide_cold_record("medium/profile_detail(p1)", m_p1, t_prof, c_prof, alive_pre_p1)

  let (t_conn, c_conn, _, _, chat_conn) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_conn = @ui.view_tree().unwrap().alive()
  let m_conn = wide_go_place(t_conn, "connects", chat_conn)
  wide_cold_record("medium/connects", m_conn, t_conn, c_conn, alive_pre_conn)

  let (t_use, c_use, _, _, chat_use) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_use = @ui.view_tree().unwrap().alive()
  let m_use = wide_go_place(t_use, "usage", chat_use)
  wide_cold_record("medium/usage", m_use, t_use, c_use, alive_pre_use)

  let (t_vault, c_vault, _, _, chat_vault) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_vault = @ui.view_tree().unwrap().alive()
  let m_vault = wide_go_place(t_vault, "vault", chat_vault)
  wide_cold_record("medium/vault", m_vault, t_vault, c_vault, alive_pre_vault)

  let (t_set, c_set, _, _, _) = wide_cold_open(600.0, 900.0, 2)
  let alive_pre_set = @ui.view_tree().unwrap().alive()
  let m_set = wide_budget_step(t_set, fn() { @sfbase.open_page(Settings) })
  wide_cold_record("medium/settings(home/Me)", m_set, t_set, c_set, alive_pre_set)
}
