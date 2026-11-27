///|
test "station_info_card_node adapts shown facets per scenario and passes audit, corners, and dark contrast" {
  @sf.set_words(@sfbase.fill)
  let willow : Json = {
    "station": "ws1/st1",
    "id": "st1",
    "name": "Willow",
    "icon": "glyph:desktop",
    "online": false,
    "stateText": "18 分钟前在线",
    "version": "0.1.4765",
    "host": {
      "identity": "MacBook Pro · Apple M1 Pro",
    },
  }
  let maple : Json = {
    "station": "ws1/st2",
    "id": "st2",
    "name": "Maple",
    "emoji": "🍁",
    "online": true,
    "version": "0.1.4765",
    "host": {
      "identity": "Mac Studio · Apple M2 Max",
      "meters": [
        { "short": "CPU", "left": 84, "level": "ok", "remaining": "空闲 84%", "big": "84", "unit": "%" },
        { "short": "内存", "left": 66, "level": "ok", "remaining": "剩 42 G", "big": "42", "unit": "GB" },
      ],
    },
    "net": {
      "via": "direct",
      "path": "直连",
      "rtt": { "text": "24 ms", "level": "ok" },
    },
  }
  let make_item = fn(role : String, addr : String, name : String, row : Json, show : StationInfoShow, note : String) -> StationInfoItem {
    { role, address: addr, name, row: fn() { Some(row) }, net: None, cpu_busy: None, show, note }
  }
  for case in [(1280.0, 800.0, 0, false), (1280.0, 800.0, 0, true), (390.0, 844.0, 2, false), (390.0, 844.0, 2, true)] {
    let (w, h, platform, dark) = case
    let at = "\{w}x\{h} dark=\{dark}"
    @sf.presenters_reset()
    let t = @ui.Tester::new(
      fn(c) { @sf.begin(c) |> ignore },
      tree=fn(root) {
        @ui.set_tree_theme(@sf.ui_theme_now)
        root.ground(By(fn() { @sf.theme().p.bg })) |> ignore
        @sf.presented_nodes(root)
      },
      w~,
      h~,
      dark~,
      platform~,
    )
    @sf.set_dark(Some(dark))
    @sf.panel_nodes(
      "切换 Station",
      from=Unanchored,
      fn(v, _) {
        station_info_card_node(v, [
          make_item("来源 Station", "ws1/st1", "Willow", willow, StationInfoShow::compact(), ""),
          make_item("目标 Station", "ws1/st2", "Maple", maple, StationInfoShow::target(), ""),
        ])
      },
      foot=fn(f, shut) {
        @sf.button_node(f, fn() { "取消" }, shut, tone=Ghost) |> ignore
        @sf.button_node(f, fn() { "接着做" }, shut, tone=Primary) |> ignore
      },
    )
    t.run_for(@ui.move_most_ms)
    for expected in [
      "来源 Station",
      "Willow",
      "18 分钟前在线",
      "MacBook Pro · Apple M1 Pro",
      "目标 Station",
      "Maple",
      "直连 · 24 ms",
      "Mac Studio · Apple M2 Max",
      "CPU 空闲 84% · 内存 剩 42 G",
    ] {
      assert_true(t.find(expected) is Some(_), msg="\{at}: missing \{expected}")
    }
    // compact/target do not include version unless requested
    assert_true(t.find("Station 0.1.4765") is None, msg="\{at}: version should stay hidden")
    let af = t.audit()
    assert_true(af.is_empty(), msg="\{at} audit: " + af.join(" | "))
    let cr = t.corner_faults()
    assert_true(cr.is_empty(), msg="\{at} corners: " + cr.join(" | "))
    let cf = t.contrast_faults()
    assert_true(cf.is_empty(), msg="\{at} contrast: " + cf.join(" | "))
  }
  // detail mode includes version + note; brief mode hides host & meters
  @sf.set_dark(Some(false))
  @sf.presenters_reset()
  let t_det = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) { @sf.presented_nodes(root) }, w=1280.0, h=800.0, platform=0)
  @sf.panel_nodes(
    "Station 详情",
    from=Unanchored,
    fn(v, _) {
      station_info_card_node(v, [
        make_item("", "ws1/st2", "Maple", maple, StationInfoShow::detail(), "额外说明"),
      ])
    },
    foot=fn(f, shut) {
      @sf.button_node(f, fn() { "关闭" }, shut, tone=Ghost) |> ignore
    },
  )
  t_det.run_for(@ui.move_most_ms)
  assert_true(t_det.find("Mac Studio · Apple M2 Max · Station 0.1.4765") is Some(_))
  assert_true(t_det.find("额外说明") is Some(_))
  assert_eq(t_det.audit(), [])
  assert_eq(t_det.corner_faults(), [])
  @sf.presenters_reset()
  let t_brief = @ui.Tester::new(fn(c) { @sf.begin(c) |> ignore }, tree=fn(root) { @sf.presented_nodes(root) }, w=1280.0, h=800.0, platform=0)
  @sf.panel_nodes(
    "简略",
    from=Unanchored,
    fn(v, _) {
      station_info_card_node(v, [
        make_item("", "ws1/st2", "Maple", maple, StationInfoShow::brief(), ""),
      ])
    },
    foot=fn(f, shut) {
      @sf.button_node(f, fn() { "关闭" }, shut, tone=Ghost) |> ignore
    },
  )
  t_brief.run_for(@ui.move_most_ms)
  assert_true(t_brief.find("Maple") is Some(_))
  assert_true(t_brief.find("在线") is Some(_))
  assert_true(t_brief.find("Mac Studio") is None)
  assert_true(t_brief.find("CPU") is None)
  assert_eq(t_brief.audit(), [])
  // Long station names on 小屏: status wraps to next line so names aren't truncated, and multi-word names wrap cleanly
  let long_name = "tokyo-mac-studio-build-01"
  let long_multi = "Tokyo Mac Studio Production Build Host"
  let long_row : Json = {
    "station": "ws1/st3",
    "id": "st3",
    "name": long_name,
    "icon": "glyph:desktop",
    "online": true,
    "host": { "identity": "Mac Studio · Apple M2 Ultra" },
    "net": { "via": "direct", "path": "直连", "rtt": { "text": "24 ms", "level": "ok" } },
  }
  let long_multi_row : Json = {
    "station": "ws1/st4",
    "id": "st4",
    "name": long_multi,
    "icon": "glyph:desktop",
    "online": true,
    "host": { "identity": "Mac Studio · Apple M2 Ultra" },
    "net": { "via": "direct", "path": "直连", "rtt": { "text": "24 ms", "level": "ok" } },
  }
  @sf.presenters_reset()
  let t_long = @ui.Tester::new(
    fn(c) { @sf.begin(c) |> ignore },
    tree=fn(root) {
      @ui.set_tree_theme(@sf.ui_theme_now)
      root.ground(By(fn() { @sf.theme().p.bg })) |> ignore
      @sf.presented_nodes(root)
    },
    w=390.0,
    h=844.0,
    dark=true,
    platform=2,
  )
  @sf.set_dark(Some(true))
  @sf.confirm(
    "全部迁移",
    "9 项 · 1 项无法迁移",
    "全部迁移",
    fn() {  },
    facts=[("来源 Station", long_name), ("目标 Station", long_multi)],
    body=fn(w) {
      station_info_card_node(
        w,
        [
          make_item("来源 Station", "ws1/st3", long_name, long_row, StationInfoShow::target(), ""),
          make_item("目标 Station", "ws1/st4", long_multi, long_multi_row, StationInfoShow::target(), ""),
        ],
        inset_out=false,
      )
    },
  )
  t_long.run_for(@ui.move_most_ms)
  assert_true(t_long.find(long_name) is Some(_))
  assert_true(t_long.find(long_multi) is Some(_))
  assert_true(t_long.find("直连 · 24 ms") is Some(_))
  assert_eq(t_long.audit(), [])
  assert_eq(t_long.corner_faults(), [])
  assert_eq(t_long.contrast_faults(), [])
  @sf.presenters_reset()
  @sf.set_dark(None)
}
