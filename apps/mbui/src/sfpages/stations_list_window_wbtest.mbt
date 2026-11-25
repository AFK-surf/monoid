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

///|
test "stations_list: compact grouped rows keep fixed order, preserve edge states, and fit 7 stations on a phone screen" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let mk_online = fn(i : Int, name : String, running : Int, cpu_left : Int, cpu_lvl : String) -> Json {
    {
      "station": Json::string("ws1/s\{i}"),
      "id": Json::string("s\{i}"),
      "name": Json::string(name),
      "online": true,
      "summary": Json::string("主机 \{i}"),
      "overview": { "counts": { "running": Json::number(running.to_double()) } },
      "host": {
        "meters": [
          { "short": "CPU", "big": Json::string(cpu_left.to_string()), "unit": "%", "left": Json::number(cpu_left.to_double()), "level": Json::string(cpu_lvl), "remaining": Json::string("空闲 \{cpu_left}%") },
          { "short": "内存", "big": "8.0", "unit": "GB", "left": 50, "level": "ok", "remaining": "剩 8.0 G" },
          { "short": "磁盘", "big": "200", "unit": "GB", "left": 50, "level": "ok", "remaining": "剩 200 G" },
        ],
      },
    }
  }
  // Interleaved offline stations stay in their original workspace order without jumping to the bottom.
  let stations : Array[Json] = [
    mk_online(0, "Office-Host-2", 14, 69, "ok"),
    {
      "station": "ws1/s1",
      "id": "s1",
      "name": "zwg-Macbook-580",
      "online": false,
      "summary": "离线 · 2 天前",
    },
    mk_online(2, "tokyo-mac-studio-0", 7, 62, "ok"),
    mk_online(3, "pvg-office-2", 2, 11, "red"),
    mk_online(4, "pvg-office-1", 0, 36, "ok"),
    mk_online(5, "afkprover", 3, 63, "ok"),
    {
      "station": "ws1/s6",
      "id": "s6",
      "name": "home-mini",
      "online": false,
      "summary": "安全模式未放行",
      "blocked": "此 station 尚未加入安全模式",
    },
  ]
  let src = @sfbase.made_source(topic=fn(name, params) {
    match name {
      "stations" => Some(Json::array(stations))
      "stationNet" =>
        match params.get("station") {
          Some(String("ws1/s0")) => Some({ "path": "直连", "rtt": { "text": "38 ms", "level": "ok" } })
          _ => Some({ "path": "东京中继", "rtt": { "text": "42 ms", "level": "ok" } })
        }
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=844.0,
    platform=2,
  )
  // All 7 stations stay in fixed order and fit without scrolling on a 390x844 phone screen.
  let names = ["Office-Host-2", "zwg-Macbook-580", "tokyo-mac-studio-0", "pvg-office-2", "pvg-office-1", "afkprover", "home-mini"]
  let mut prev_y = -1.0
  for name in names {
    let pos = t.find(name)
    assert_true(pos is Some(_), msg="expected \{name} visible on first screen")
    let y = pos.unwrap().1
    assert_true(y > prev_y, msg="expected \{name} below previous row: \{y} <= \{prev_y}")
    assert_true(y < 760.0, msg="expected \{name} above bottom bar, got y=\{y}")
    prev_y = y
  }
  assert_true(sl_said(t, "14 个运行中"), msg="running count on line 1, read out whole")
  assert_true(sl_said(t, "CPU 空闲 69%"), msg="the CPU's icon read out with its idle wording")
  assert_true(t.find("38 ms") is Some(_) && sl_said(t, "直连 38 ms"), msg="latency on line 2, its way read out")
  assert_true(t.find("离线 · 2 天前") is Some(_), msg="offline summary shown on line 2")
  assert_true(t.find("此 station 尚未加入安全模式") is Some(_), msg="offline block reason preserved")
}

///|
test "stations_list: online/offline flapping updates in place without reordering, long offline tail keeps name visible, and protect button disables while joining" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let online = @signals.signal(true)
  let protect = @signals.signal(true)
  let joining = @signals.signal(false)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" => {
        let up = online.get()
        Some(
          Json::array([
            {
              "station": "ws1/s0",
              "id": "s0",
              "name": "Alpha-Workstation",
              "online": Json::boolean(up),
              "summary": Json::string(if up { "主机 0" } else { "Blocked by security mode" }),
              "protect": Json::boolean(protect.get()),
              "overview": { "counts": { "running": 2 } },
            },
            {
              "station": "ws1/s1",
              "id": "s1",
              "name": "Beta-Node",
              "online": true,
              "summary": "主机 1",
              "overview": { "counts": { "running": 0 } },
            },
          ]),
        )
      }
      "doing" =>
        Some(
          Json::object({
            "doing": if joining.get() {
              Json::array([
                {
                  "call": "lock.joinStation",
                  "stage": "running",
                  "params": { "workspace": "ws1", "station": "s0" },
                },
              ])
            } else {
              Json::array([])
            },
          }),
        )
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=320.0,
    h=568.0,
    platform=2,
  )
  // Protect action is exposed as a pressable Button in the accessibility tree when idle.
  t.set_a11y(true)
  t.draw()
  let join_label = @sf.t("web-pages.security.joinShort")
  let has_join_btn = fn() {
    t
    .a11y_said()
    .split("\n")
    .any(fn(v) {
      let l = v.to_owned()
      l.contains("\u{1F}Button\u{1F}") && l.contains(join_label)
    })
  }
  assert_true(has_join_btn(), msg="protect button exposed in a11y tree when idle: \{t.a11y_said()}")
  let y0_online = t.find("Alpha-Workstation").unwrap().1
  let y1_online = t.find("Beta-Node").unwrap().1
  assert_true(y0_online < y1_online, msg="Alpha above Beta initially")
  // While joining, protect row stops being a pressable Button in the accessibility tree.
  joining.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_true(!has_join_btn(), msg="protect button not pressable while joining: \{t.a11y_said()}")
  // Without protect action, flapping online <-> offline keeps Beta-Node at the exact same y coordinate (zero row jump).
  joining.set(false)
  protect.set(false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y1_steady = t.find("Beta-Node").unwrap().1
  online.set(false)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y0_off = t.find("Alpha-Workstation").unwrap().1
  let y1_off = t.find("Beta-Node").unwrap().1
  assert_true(y0_off < y1_off, msg="Alpha stays above Beta when offline: \{y0_off} vs \{y1_off}")
  assert_eq(y1_off, y1_steady, msg="Beta-Node does not shift vertically when Alpha goes offline")
  assert_true(t.find("Blocked by security mode") is Some(_), msg="offline summary shown cleanly on line 2")
  assert_true(t.audit().is_empty(), msg="no layout/contrast/corner faults on 320px long offline summary: " + t.audit().join(" | "))
  // Flapping back online keeps Beta-Node at the exact same y coordinate.
  online.set(true)
  t.draw()
  t.run_for(@ui.move_most_ms)
  let y0_back = t.find("Alpha-Workstation").unwrap().1
  let y1_back = t.find("Beta-Node").unwrap().1
  assert_true(y0_back < y1_back, msg="Alpha stays above Beta after reconnecting")
  assert_eq(y1_back, y1_steady, msg="Beta-Node does not shift vertically when Alpha reconnects")
}

///|
test "stations_list: 390px keeps all three low-headroom warning meters alongside latency by dropping network path first" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let src = @sfbase.made_source(topic=fn(name, _) {
    match name {
      "stations" =>
        Some(
          Json::array([
            {
              "station": "ws1/st1",
              "id": "st1",
              "name": "Willow",
              "online": true,
              "summary": "主机",
              "overview": { "counts": { "running": 1 } },
              "host": {
                "meters": [
                  { "short": "CPU", "big": "8", "unit": "%", "left": 8, "level": "red", "remaining": "空闲 8%" },
                  { "short": "内存", "big": "5.8", "unit": "GB", "left": 18, "level": "amber", "remaining": "剩 5.8 G" },
                  { "short": "磁盘", "big": "19.4", "unit": "GB", "left": 9, "level": "amber", "remaining": "剩 19.4 G" },
                ],
              },
            },
          ]),
        )
      "stationNet" => Some({ "path": "直连", "rtt": { "text": "38 ms", "level": "ok" } })
      "workspace" => Some({ "role": "owner" })
      "rigs" => Some({ "rigs": [] })
      "devices" => Some({ "devices": [] })
      _ => None
    }
  })
  let core = @sfbase.settings_core(src, rig_workspace)
  let here = fn() { @settings.here_of(core, rig_workspace.id, rig_workspace.name) }
  let t = station_part_tester(
    fn(p) { stations_list_node(p, core, here, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=844.0,
    platform=2,
  )
  assert_true(sl_said(t, "CPU 空闲 8%"), msg="red CPU warning read out on 390px")
  assert_true(t.find("5.8G") is Some(_) && sl_said(t, "内存剩 5.8 G"), msg="amber memory warning visible on 390px")
  assert_true(t.find("19.4G") is Some(_) && sl_said(t, "磁盘剩 19.4 G"), msg="amber disk warning visible on 390px")
  assert_true(t.find("38 ms") is Some(_), msg="latency preserved alongside all three warnings on 390px")
}

///|
/// Whether what is read out as `label` shows in `t` (an icon's words, a count beside its icon).
fn sl_said(t : @ui.Tester, label : String) -> Bool {
  t.semantics().iter().any(fn(n) { n.label == label && !n.hidden })
}

///|
/// Horizontal hairline dividers drawn in `t` (`h == rule_w`, non-clear): `(y, color)` sorted top-to-bottom.
fn sl_seps_drawn(t : @ui.Tester) -> Array[(Double, Int64)] {
  let out = t
    .drawn_rects()
    .filter(fn(r) { (r.3 - @sf.rule_w).abs() < 0.01 && (r.4 & 0xFFL) != 0L })
    .map(fn(r) { (r.1, r.4) })
  out.sort_by(fn(a, b) { a.0.compare(b.0) })
  out
}

///|
/// Alpha byte (`0..255`) of the hairline divider closest to `y`, or `0` if fully faded/not drawn.
fn sl_sep_alpha_at(t : @ui.Tester, y : Double) -> Int {
  for r in sl_seps_drawn(t) {
    if (r.0 - y).abs() < 1.0 {
      return (r.1 & 0xFFL).to_int()
    }
  }
  0
}

///|
test "stations_list: hairline dividers fade smoothly on mouse hover, finger press-hold, protect button, rigs and devices" {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let joining : @signals.Signal[Bool] = @signals.signal(false)
  let make_src = fn() {
    @sfbase.made_source(topic=fn(name, _) {
      match name {
        "stations" =>
          Some(
            Json::array([
              { "station": "ws1/st0", "id": "st0", "name": "Station-A", "online": true, "summary": "A", "protect": true },
              { "station": "ws1/st1", "id": "st1", "name": "Station-B", "online": true, "summary": "B" },
              { "station": "ws1/st2", "id": "st2", "name": "Station-C", "online": false, "summary": "离线 · 1 天前" },
              { "station": "ws1/st3", "id": "st3", "name": "Station-D", "online": false, "summary": "离线 · 2 天前" },
            ]),
          )
        "stationNet" => Some({ "path": "直连", "rtt": { "text": "20 ms", "level": "ok" } })
        "workspace" => Some({ "role": "owner", "rigs": [{ "id": "rig1" }, { "id": "rig2" }] })
        "rigs" =>
          Some({
            "rigs": [
              { "id": "rig1", "name": "Rig-One", "reached": true, "vouched": true },
              { "id": "rig2", "name": "Rig-Two", "reached": true, "vouched": true },
            ],
          })
        "devices" =>
          Some({
            "devices": [
              { "station": "ws1/st0", "id": "dev1", "name": "Phone-One", "online": true, "kind": "phone" },
              { "station": "ws1/st0", "id": "dev2", "name": "Phone-Two", "online": true, "kind": "phone" },
            ],
          })
        "doing" =>
          Some(
            Json::object({
              "doing": if joining.get() {
                Json::array([
                  {
                    "call": "lock.joinStation",
                    "stage": "running",
                    "params": { "workspace": "ws1", "station": "st0" },
                  },
                ])
              } else {
                Json::array([])
              },
            }),
          )
        _ => None
      }
    })
  }

  // 1. Mouse hover (platform=0): smooth fade out and back, adjacent-only, protect button, rig & device cards
  let src0 = make_src()
  let core0 = @sfbase.settings_core(src0, rig_workspace)
  let here0 = fn() { @settings.here_of(core0, rig_workspace.id, rig_workspace.name) }
  let tm = station_part_tester(
    fn(p) { stations_list_node(p, core0, here0, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=900.0,
    platform=0,
  )
  let rest_color = @sf.rule_color()
  let rest_alpha = (rest_color & 0xFFL).to_int()
  let rest_seps = sl_seps_drawn(tm)
  // 3 station separators (A|B, B|C, C|D) + 1 rig separator (Rig-One|Rig-Two) + 1 device separator (Phone-One|Phone-Two)
  assert_eq(rest_seps.length(), 5, msg="expected 5 grouped hairlines at rest, got \{rest_seps.length()}")
  for s in rest_seps {
    assert_eq(s.1, rest_color, msg="rest hairline colour must match rule_color")
  }
  let y_ab = rest_seps[0].0
  let y_bc = rest_seps[1].0
  let y_cd = rest_seps[2].0
  let y_rig = rest_seps[3].0
  let y_dev = rest_seps[4].0

  // Hover Station-B: both A|B and B|C fade smoothly; C|D stays at rest alpha
  let (bx, by, bw, bh) = tm.rect_of("Station-B").unwrap()
  tm.move_to(bx + bw / 2.0, by + bh / 2.0)
  tm.run_for(@sf.dur_ms / 2.0)
  let mid_ab = sl_sep_alpha_at(tm, y_ab)
  let mid_bc = sl_sep_alpha_at(tm, y_bc)
  assert_true(mid_ab > 0 && mid_ab < rest_alpha, msg="A|B should fade smoothly mid-hover, got \{mid_ab} of \{rest_alpha}")
  assert_true(mid_bc > 0 && mid_bc < rest_alpha, msg="B|C should fade smoothly mid-hover, got \{mid_bc} of \{rest_alpha}")
  assert_eq(sl_sep_alpha_at(tm, y_cd), rest_alpha, msg="non-adjacent C|D stays opaque while hovering B")
  tm.run_for(@sf.dur_ms)
  assert_eq(sl_sep_alpha_at(tm, y_ab), 0, msg="A|B fully faded on hover B")
  assert_eq(sl_sep_alpha_at(tm, y_bc), 0, msg="B|C fully faded on hover B")
  assert_eq(sl_sep_alpha_at(tm, y_cd), rest_alpha, msg="C|D untouched on hover B")

  // Move mouse straight from Station-B to Station-C: shared B|C stays faded, A|B fades back, C|D fades out
  let (cx, cy, cw, ch) = tm.rect_of("Station-C").unwrap()
  tm.move_to(cx + cw / 2.0, cy + ch / 2.0)
  tm.run_for(@sf.dur_ms / 2.0)
  assert_eq(sl_sep_alpha_at(tm, y_bc), 0, msg="shared B|C stays faded with no flicker across adjacent hover")
  let back_ab = sl_sep_alpha_at(tm, y_ab)
  assert_true(back_ab > 0 && back_ab < rest_alpha, msg="A|B fades back smoothly, got \{back_ab}")
  tm.run_for(@sf.dur_ms)
  assert_eq(sl_sep_alpha_at(tm, y_ab), rest_alpha, msg="A|B restored")
  assert_eq(sl_sep_alpha_at(tm, y_bc), 0, msg="B|C still faded")
  assert_eq(sl_sep_alpha_at(tm, y_cd), 0, msg="C|D faded on hover C")

  // Hover unprotected Station-A's protect button (加入安全模式): fades A|B directly below it and restores B|C & C|D
  let (px, py, pw, ph) = tm.rect_of(@sf.t("web-pages.security.joinShort")).unwrap()
  tm.move_to(px + pw / 2.0, py + ph / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), 0, msg="A|B fades when hovering protect button above it")
  assert_eq(sl_sep_alpha_at(tm, y_bc), rest_alpha, msg="B|C restored when hovering protect button")
  assert_eq(sl_sep_alpha_at(tm, y_cd), rest_alpha, msg="C|D restored when hovering protect button")

  // Hover Station-A's main row while protect button sits below it: A|B must NOT fade
  let (ax, ay, aw, ah) = tm.rect_of("Station-A").unwrap()
  tm.move_to(ax + aw / 2.0, ay + ah / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), rest_alpha, msg="A|B stays opaque when hovering Station-A main row above protect")

  // While protect is joining (non-interactive spinner), hovering the spinner row must NOT fade A|B
  joining.set(true)
  tm.draw()
  tm.run_for(@ui.move_most_ms)
  tm.move_to(px + pw / 2.0, py + ph / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), rest_alpha, msg="A|B stays opaque when hovering non-interactive joining spinner")
  joining.set(false)
  tm.draw()
  tm.run_for(@ui.move_most_ms)

  // Hover Rig-One and Phone-One: rig & device group hairlines also fade out
  let (rx, ry, rw, rh) = tm.rect_of("Rig-One").unwrap()
  tm.move_to(rx + rw / 2.0, ry + rh / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_rig), 0, msg="rig divider fades on hover")
  let (dx, dy, dw, dh) = tm.rect_of("Phone-One").unwrap()
  tm.move_to(dx + dw / 2.0, dy + dh / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_dev), 0, msg="device divider fades on hover")
  assert_eq(sl_sep_alpha_at(tm, y_rig), rest_alpha, msg="rig divider restored")

  // Leave all rows: every divider restores to exact rest_color
  tm.move_to(4.0, 4.0)
  tm.run_for(@sf.dur_ms + 30.0)
  let restored = sl_seps_drawn(tm)
  assert_eq(restored.length(), 5, msg="all 5 dividers restored after mouse leaves")
  for s in restored {
    assert_eq(s.1, rest_color, msg="restored hairline colour must match rest_color")
  }

  // Keyboard focus on Station-B fades both adjacent dividers (A|B and B|C)
  let mut focused_b = false
  for _ in 0..<10 {
    tm.key(@ui.key_tab)
    if tm.focused() is Some(node) && node.label == "Station-B" {
      focused_b = true
      break
    }
  }
  assert_true(focused_b, msg="expected Tab to focus Station-B")
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, y_ab), 0, msg="keyboard focus on B fades A|B")
  assert_eq(sl_sep_alpha_at(tm, y_bc), 0, msg="keyboard focus on B fades B|C")
  assert_eq(sl_sep_alpha_at(tm, y_cd), rest_alpha, msg="keyboard focus on B leaves C|D intact")

  // Wide layout (1200x800, platform=0): hover on middle row fades both adjacent dividers
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let src_w = make_src()
  let core_w = @sfbase.settings_core(src_w, rig_workspace)
  let here_w = fn() { @settings.here_of(core_w, rig_workspace.id, rig_workspace.name) }
  let tw = station_part_tester(
    fn(p) { stations_list_node(p, core_w, here_w, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=1200.0,
    h=900.0,
    platform=0,
  )
  let w_seps = sl_seps_drawn(tw)
  assert_eq(w_seps.length(), 5, msg="wide rest dividers")
  let (wbx, wby, wbw, wbh) = tw.rect_of("Station-B").unwrap()
  tw.move_to(wbx + wbw / 2.0, wby + wbh / 2.0)
  tw.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tw, w_seps[0].0), 0, msg="wide hover B fades A|B")
  assert_eq(sl_sep_alpha_at(tw, w_seps[1].0), 0, msg="wide hover B fades B|C")
  assert_eq(sl_sep_alpha_at(tw, w_seps[2].0), rest_alpha, msg="wide hover B keeps C|D")

  // 2. Touch press-and-hold (platform=2, Finger): smooth fade out while held and smooth fade back on release
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let src2 = make_src()
  let core2 = @sfbase.settings_core(src2, rig_workspace)
  let here2 = fn() { @settings.here_of(core2, rig_workspace.id, rig_workspace.name) }
  let tf = station_part_tester(
    fn(p) { stations_list_node(p, core2, here2, on_back=fn() {  }, frame=fn() { @sf.no_frame }) },
    w=390.0,
    h=900.0,
    platform=2,
  )
  let f_seps = sl_seps_drawn(tf)
  assert_eq(f_seps.length(), 5, msg="touch rest dividers")
  let fy_ab = f_seps[0].0
  let fy_bc = f_seps[1].0
  let fy_cd = f_seps[2].0
  let (fbx, fby, fbw, fbh) = tf.rect_of("Station-B").unwrap()
  tf.press_at(fbx + fbw / 2.0, fby + fbh / 2.0)
  tf.run_for(@sf.dur_ms / 2.0)
  let fmid_ab = sl_sep_alpha_at(tf, fy_ab)
  let fmid_bc = sl_sep_alpha_at(tf, fy_bc)
  assert_true(fmid_ab > 0 && fmid_ab < rest_alpha, msg="touch hold: A|B fades smoothly, got \{fmid_ab}")
  assert_true(fmid_bc > 0 && fmid_bc < rest_alpha, msg="touch hold: B|C fades smoothly, got \{fmid_bc}")
  assert_eq(sl_sep_alpha_at(tf, fy_cd), rest_alpha, msg="touch hold: non-adjacent C|D stays opaque")
  tf.run_for(@sf.dur_ms)
  assert_eq(sl_sep_alpha_at(tf, fy_ab), 0, msg="touch hold: A|B fully faded while pressed")
  assert_eq(sl_sep_alpha_at(tf, fy_bc), 0, msg="touch hold: B|C fully faded while pressed")
  // Release finger off-row so page does not push; dividers fade back smoothly
  tf.release(4.0, 4.0)
  tf.run_for(@sf.dur_ms / 2.0)
  let fret_ab = sl_sep_alpha_at(tf, fy_ab)
  assert_true(fret_ab > 0 && fret_ab < rest_alpha, msg="touch release: A|B fades back smoothly, got \{fret_ab}")
  tf.run_for(@sf.dur_ms)
  assert_eq(sl_sep_alpha_at(tf, fy_ab), rest_alpha, msg="touch release: A|B restored")
  assert_eq(sl_sep_alpha_at(tf, fy_bc), rest_alpha, msg="touch release: B|C restored")
}
