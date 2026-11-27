// 连接 and a connect's page (connects.mbt, connect.mbt, slack_app.mbt) alone, at each width, with a finger and with a
// mouse: the connects with how they run, one's page with how it runs and what is done to it
// less often (its ⋯, the presenters' menu).

///|
test "连接, at each width and with either hand: the connects, each with how it runs; one pressed, its page" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Connects(""), w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("星火助手") is Some(_), msg=at)
    assert_true(t.find("值班机器人") is Some(_), msg=at)
    let (x, y) = t.find_last("值班机器人").unwrap()
    t.tap(x, y)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(app.nav.pages().iter().any(fn(p) { p is Setting(Connect(_, _)) }), msg=at)
  }
}

///|
test "连接 with a waiting Slack app and pictured and unpictured connects: cards apart, titles lined up, its controls on its first line (by the whole row's side, wide under a finger)" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Connects(""), w, platform~, mode="settings-connects")
    let at = "\{w} platform \{platform}"
    assert_eq(t.corner_faults(), [], msg=at)
    assert_eq(t.gap_faults(), [], msg=at)
    let waiting_title = drawn(t, "Gemini-Monoid")
    let pictured_title = drawn(t, "星火助手")
    let unpictured_title = drawn(t, "值班机器人")
    // (every row's lead is 28 wide, so pictured, unpictured and waiting titles start at the same x)
    assert_true((pictured_title.0 - unpictured_title.0).abs() <= 0.5, msg="\{at}: \{Repr(pictured_title)} vs \{Repr(unpictured_title)}")
    assert_true((pictured_title.0 - waiting_title.0).abs() <= 0.5, msg="\{at}: \{Repr(pictured_title)} vs \{Repr(waiting_title)}")
    let wait_card = ground_round(t, waiting_title)
    let list_card = ground_round(t, pictured_title)
    assert_true(list_card.1 - (wait_card.1 + wait_card.3) >= 20.0, msg="\{at}: \{Repr(wait_card)} over \{Repr(list_card)}")
    let more = t.query(Button, label=@sf.t("web-pages.connects.removeHere")).unwrap().rect
    // (beside a block of lines, on its first line (apps/mbui/AGENTS.md): its title's; wide under a finger by the whole
    // row's side, in its middle)
    let by_side = laid_wide(w) && platform == 2
    let wait_mid = if by_side {
      wait_card.1 + wait_card.3 / 2.0
    } else {
      waiting_title.1 + waiting_title.3 / 2.0
    }
    assert_true(((more.1 + more.3 / 2.0) - wait_mid).abs() <= 1.0, msg="\{at}: more \{Repr(more)} at \{wait_mid} in \{Repr(wait_card)}")
    if laid_wide(w) {
      let cont = t.query(Button, label="继续").unwrap().rect
      assert_true(((cont.1 + cont.3 / 2.0) - wait_mid).abs() <= 1.0, msg="\{at}: continue \{Repr(cont)} at \{wait_mid} in \{Repr(wait_card)}")
      if w >= 1100.0 {
        let owner = drawn(t, "林（你）")
        let mode_short = t.words().filter(fn(word) { word.0 == "多会话" && (word.2 - owner.1).abs() < 8.0 })[0]
        assert_true(mode_short.1 > owner.0 + owner.2 + 4.0, msg="\{at}: owner \{Repr(owner)} before modeShort \{Repr(mode_short)}")
        let sub = drawn(t, "Claude Code")
        assert_true(((owner.1 + owner.3 / 2.0) - (sub.1 + sub.3 / 2.0)).abs() <= 2.0, msg="\{at}: owner \{Repr(owner)} aligned with line 2 \{Repr(sub)}")
      }
    }
  }
}

///|
test "a connect's page, at each width and with either hand: who it is, how it runs; its ⋯ a menu of what is done less often" {
  for case in page_cases {
    let (w, platform) = case
    let t = setting_tester(Connect("ws1/st1", "k1"), w, platform~)
    let at = "\{w} platform \{platform}"
    assert_true(t.find("星火助手") is Some(_), msg=at)
    assert_false(@sf.presenting(), msg=at)
    let (x, y, bw, bh) = t.query(Button, label="更多").unwrap().rect
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.frame()
    assert_true(@sf.presenting(), msg=at)
  }
}

///|
test "a connect's Slack app, at a phone's width: its fold opened, the buddies and the makers to pick from, a picture to upload" {
  let calls : Array[String] = []
  let t = setting_tester(Connect("ws1/st1", "k1"), 390.0, platform=2, over=fn(s) {
    { ..s, call: fn(name, params, done) { calls.push(name); (s.call)(name, params, done) } }
  })
  t.add_pixels("https://app.still.fail/avatars/backend.webp", 2, 2, FixedArray::make(16, b'\xFF'))
  t.draw()
  let (x, y, w, h) = t.query(Link, label="Slack app").unwrap().rect
  t.tap(x + w / 2.0, y + h / 2.0)
  t.frame()
  // the core's buddies asked for once, then the makers after them
  assert_eq(calls.filter(fn(m) { m == "buddies" }).length(), 1)
  for a in ["后端接口", "移动应用", "写文档", "Anthropic", "OpenAI"] {
    assert_true(t.query(Button, label=a) is Some(_), msg=a)
  }
  // a picture of one's own: its icon's button
  assert_true(t.query(Button, label="上传图片") is Some(_))
}

///|
test "a connect's Slack app's permissions opened: each section's 全选 at its line's end, its title at its start" {
  for case in [(390.0, 2), (1280.0, 0)] {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let t = setting_tester(Connect("ws1/st1", "k1"), w, platform~)
    t.draw()
    let (x, y, bw, bh) = t.query(Link, label="Slack app").unwrap().rect
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.frame()
    t.run_for(@ui.move_most_ms)
    let (x, y, bw, bh) = drawn(t, "权限 · 已开启 4 / 16 项")
    t.tap(x + bw / 2.0, y + bh / 2.0)
    t.draw()
    t.run_for(@ui.move_most_ms)
    // (as far in from the card's right as its title from its left)
    let title = drawn(t, "消息")
    let all = drawn(t, "全选")
    let card = ground_round(t, title)
    let start = title.0 - card.0
    let end = card.0 + card.2 - (all.0 + all.2)
    assert_true((start - end).abs() < 0.5, msg="\{at}: the title \{start} in at the start, 全选 \{end} at the end")
  }
}

///|
/// A connect's Slack app open `w` wide, pointed at as `platform` says, its picture's room's own drawn.
fn slack_app_tester(w : Double, platform : Int) -> @ui.Tester {
  let t = setting_tester(Connect("ws1/st1", "k1"), w, platform~)
  t.add_pixels("https://app.still.fail/avatars/backend.webp", 2, 2, FixedArray::make(16, b'\xFF'))
  t.draw()
  let (x, y, bw, bh) = t.query(Link, label="Slack app").unwrap().rect
  t.tap(x + bw / 2.0, y + bh / 2.0)
  t.frame()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// The middle of what a screen reader finds as `role` named `label`.
fn middle_of(t : @ui.Tester, role : @view.Role, label : String) -> (Double, Double) raise {
  guard t.query(role, label~) is Some(n) else { fail("no \{label}") }
  let (x, y, w, h) = n.rect
  (x + w / 2.0, y + h / 2.0)
}

///|
test "a connect's Slack app: its picture's room edged in a hairline of the line's colour" {
  let t = slack_app_tester(390.0, 2)
  let (x, y) = middle_of(t, Button, "上传图片")
  assert_eq(edge_round(t, x, y), (0.5, edge_shown(t, x, y, @ui.tree_theme().color(Line))), msg="at \{x},\{y}: \{edges_at(t, x, y)}")
}

///|
test "a connect's Slack app: its colour's swatch edged in a hairline of the line's colour" {
  let t = slack_app_tester(390.0, 2)
  // (the swatch: the one square drawn 28 across, beside the colour's field)
  let swatches = t.drawn_rects().filter(fn(r) { r.2 == 28.0 && r.3 == 28.0 })
  assert_eq(swatches.length(), 1, msg="\{Repr(swatches)}")
  let (sx, sy, _, _, _) = swatches[0]
  let (x, y) = (sx + 14.0, sy + 14.0)
  // (the line's translucent colour as it is: drawn over the swatch's own colour, as a host draws it)
  assert_eq(edge_round(t, x, y), (0.5, @ui.tree_theme().color(Line)), msg="at \{x},\{y}: \{edges_at(t, x, y)}")
}

///|
test "a connect's Slack app's buddies to pick from, with a mouse: the picked edged 2 in the words' colour, the rest a hairline of the line's, one under the pointer a hairline of the border's" {
  let t = slack_app_tester(1280.0, 0)
  let th = @ui.tree_theme()
  // (移动应用 picked by a press; 后端接口 not)
  let (px, py) = middle_of(t, Button, "移动应用")
  t.tap(px, py)
  t.run_for(@ui.move_most_ms)
  assert_true(t.query(Button, label="移动应用").unwrap().selected == Some(true))
  let (ox, oy) = middle_of(t, Button, "后端接口")
  assert_eq(edge_round(t, px, py), (2.0, edge_shown(t, px, py, th.color(Fg))), msg="picked at \{px},\{py}: \{edges_at(t, px, py)}")
  assert_eq(edge_round(t, ox, oy), (0.5, edge_shown(t, ox, oy, th.color(Line))), msg="not picked: \{edges_at(t, ox, oy)}")
  t.move_to(ox, oy)
  t.run_for(@ui.move_most_ms)
  assert_eq(edge_round(t, ox, oy), (0.5, edge_shown(t, ox, oy, th.color(Border))), msg="under the pointer: \{edges_at(t, ox, oy)}")
  t.move_to(1.0, 1.0)
  t.run_for(@ui.move_most_ms)
  assert_eq(edge_round(t, ox, oy), (0.5, edge_shown(t, ox, oy, th.color(Line))), msg="the pointer gone")
}

///|
/// The edge drawn round (x, y) (its width, its colour RRGGBBAA), of the least rect drawn there with one: none, (0, 0).
/// One on its own ground is drawn over it (as a host draws a translucent edge, mbui's view_host): what it shows as.
fn edge_round(t : @ui.Tester, x : Double, y : Double) -> (Double, Int64) {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  let mut best : (Double, Double, Int64)? = None
  for a in t.drawn_instances() {
    if a[5] == 0.0 && a[6] > 0.0 && a[15] > 0.0 && x >= a[0] && x <= a[0] + a[2] && y >= a[1] && y <= a[1] + a[3] {
      let color = (ch(a[12]) << 24) | (ch(a[13]) << 16) | (ch(a[14]) << 8) | ch(a[15])
      match best {
        Some((area, _, _)) if area <= a[2] * a[3] => ()
        _ => best = Some((a[2] * a[3], a[6], color))
      }
    }
  }
  match best {
    Some((_, w, c)) => (w, c)
    None => (0.0, 0L)
  }
}

///|
/// Colour `c` as an edge shows it on the ground drawn round (x, y) (the least ground there: @ui.over), or as it is
/// where none is.
fn edge_shown(t : @ui.Tester, x : Double, y : Double, c : Int64) -> Int64 {
  let ch = fn(v : Double) { (v * 255.0).round().to_int64() }
  let mut best : (Double, Int64)? = None
  for a in t.drawn_instances() {
    if a[5] == 0.0 && a[11] > 0.0 && x >= a[0] && x <= a[0] + a[2] && y >= a[1] && y <= a[1] + a[3] {
      let g = (ch(a[8]) << 24) | (ch(a[9]) << 16) | (ch(a[10]) << 8) | ch(a[11])
      match best {
        Some((area, _)) if area <= a[2] * a[3] => ()
        _ => best = Some((a[2] * a[3], g))
      }
    }
  }
  match best {
    Some((_, g)) => @ui.over(g, c)
    None => c
  }
}

///|
test "a connect's startsOn dialog: explicit manual checklist (no auto-all), disables save when empty or unchanged, saves stations array and shows multi-station summary" {
  for case in [(390.0, 2), (1280.0, 0)] {
    let (w, platform) = case
    let at = "\{w} platform \{platform}"
    let puts : Array[Json] = []
    let t = setting_tester(Connect("ws1/st1", "k1"), w, platform~, over=fn(s) {
      {
        ..s,
        call: fn(name, params, done) {
          if name == "connect.put" {
            puts.push(params)
          }
          (s.call)(name, params, done)
        },
      }
    })
    t.draw()
    assert_true(t.find("新对话开在") is Some(_), msg=at)
    let (sx, sy) = t.find("新对话开在").unwrap()
    t.tap(sx, sy)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(@sf.presenting(), msg=at)
    assert_eq(t.corner_faults(), [], msg=at)
    assert_eq(t.gap_faults(), [], msg=at)
    // Must not offer any automatic all-stations option.
    assert_true(t.find("自动选择") is None, msg=at)
    assert_true(t.find("所有 station") is None, msg=at)
    // Initially unchanged -> Save disabled.
    assert_true(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: save initially disabled")
    // Unchecking the only checked station (Willow) leaves 0 selected -> Save stays disabled.
    let (wx, wy) = middle_of(t, Button, "Willow（connect 所在的这台）")
    t.tap(wx, wy)
    t.draw()
    assert_true(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: save disabled when empty")
    // Re-check Willow and also check Maple -> Save enabled.
    t.tap(wx, wy)
    t.draw()
    let (mx, my) = middle_of(t, Button, "Maple")
    t.tap(mx, my)
    t.draw()
    assert_false(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: save enabled with 2 stations")
    let (bx, by) = middle_of(t, Button, "保存")
    t.tap(bx, by)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_eq(puts.length(), 1, msg=at)
    assert_eq(strings(field(Some(puts[0]), "input"), "stations"), ["st1", "st2"], msg=at)
    assert_true(t.find("Willow、Maple") is Some(_), msg="\{at}: multi-station label shown from bare station ids")
    // Re-opening dialog with bare startsOnStations ["st1", "st2"] restores both checkboxes as checked.
    let (sx2, sy2) = t.find("新对话开在").unwrap()
    t.tap(sx2, sy2)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: reopened dialog matches saved bare ids")
    let (mx2, my2) = middle_of(t, Button, "Maple")
    t.tap(mx2, my2)
    t.draw()
    assert_false(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: unchecking Maple enables save")
    // Toggle "跟随工作区白名单（自动分配）" ON -> manual checklist hides, save sends { autoStation: true }, detail shows "跟随工作区白名单".
    assert_true(t.find("跟随工作区白名单（自动分配）") is Some(_), msg="\{at}: auto allowlist switch shown")
    assert_true(t.find("1 台") is Some(_), msg="\{at}: allowlist count shown")
    let (ax, ay) = middle_of(t, Switch, "跟随工作区白名单（自动分配）")
    t.tap(ax, ay)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_true(t.find("Willow（connect 所在的这台）") is None, msg="\{at}: manual checklist collapses when auto is on")
    assert_false(t.query(Button, label="保存").unwrap().disabled, msg="\{at}: save enabled when switching to auto")
    let (bx2, by2) = middle_of(t, Button, "保存")
    t.tap(bx2, by2)
    t.draw()
    t.run_for(@ui.move_most_ms)
    assert_eq(puts.length(), 2, msg=at)
    assert_true(flag(field(Some(puts[1]), "input"), "autoStation"), msg="\{at}: submits autoStation: true")
    assert_true(t.find("跟随工作区白名单") is Some(_), msg="\{at}: detail displays auto allowlist summary")
  }
}

///|
test "a connect's startsOn row: non-admin member sees read-only row and cannot open routing dialog" {
  let t = setting_tester(Connect("ws1/st1", "k1"), 1280.0, platform=0, over=fn(s) {
    let base_read = s.topic_read
    {
      ..s,
      topic_read: fn(topic, params) {
        if topic == "workspace" {
          { value: Some({ "role": "member", "name": "星火", "members": [] }), error: None, version: 1 }
        } else {
          base_read(topic, params)
        }
      },
    }
  })
  t.draw()
  assert_true(t.find("新对话开在") is Some(_))
  let (sx, sy) = t.find("新对话开在").unwrap()
  t.tap(sx, sy)
  t.draw()
  t.run_for(@ui.move_most_ms)
  assert_false(@sf.presenting(), msg="non-admin tapping startsOn must not open dialog")
}

///|
/// Every rect drawn round (x, y), with its edge: what a failure says.
fn edges_at(t : @ui.Tester, x : Double, y : Double) -> String {
  t.drawn_instances().filter(fn(a) { a[5] == 0.0 && x >= a[0] && x <= a[0] + a[2] && y >= a[1] && y <= a[1] + a[3] }).map(fn(a) {
    "\{a[0]},\{a[1]} \{a[2]}x\{a[3]} e\{a[6]} a\{a[15]}"
  }).join("; ")
}

///|
fn cn_compact_item(station : String, station_name : String, id : String, name : String, presence : String, status : String, sessions : Int) -> Json {
  {
    "station": Json::string(station),
    "stationName": Json::string(station_name),
    "connect": {
      "id": Json::string(id),
      "name": Json::string(name),
      "team": "Acme",
      "kind": "slack",
      "mode": "multi-session",
      "presence": Json::string(presence),
      "statusText": Json::string(status),
      "sessions": Json::number(sessions.to_double()),
      "runtimeText": "Claude Code",
      "modelName": "Opus 5.5",
      "bind": { "runtime": "claude", "model": "claude-opus-5-5" },
      "modeShort": "多会话",
      "modeText": "每个 thread 一个会话",
    },
  }
}

///|
fn cn_compact_tester(items : Array[Json], w~ : Double, h~ : Double, platform~ : Int, words_scale? : Double = 1.0) -> @ui.Tester {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let ws : Workspace = { id: "ws-cn-compact", name: "W", emoji: "", icon: "", email: "" }
  let stations : Array[Json] = [
    { "station": "ws1/s1", "id": "s1", "name": "Willow", "online": true },
    { "station": "ws1/s2", "id": "s2", "name": "Maple", "online": true },
  ]
  let src = @sfbase.made_source(
    topic=fn(name, _) {
      match name {
        "connects" => Some({ "items": Json::array(items), "slackApps": [], "wait": { "reading": false, "failing": [] }, "noProfile": false })
        "stations" => Some(Json::array(stations))
        _ => None
      }
    },
  )
  let core = @sfbase.settings_core(src, ws)
  let here = fn() { @settings.here_of(core, ws.id, ws.name) }
  let frame = fn() -> PageFrame { { back: None, top: 0.0, foot: 0.0, named: false } }
  let t = @ui.Tester::new(fn(ctx) { @sf.begin(ctx) |> ignore }, w~, h~, platform~)
  t.set_font_scale(words_scale)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(@sf.ui_theme_now)
    root.box(fn(p) {
      p.width(Is(Some(w))).height(Is(Some(h))) |> ignore
      connects_node(p, src, core, here, "", on_back=fn() {  }, frame~, stint=fn() { 1 }, width=fn() { w })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "connects_node: 390x844 unified single card fits >= 7 connects, no middot, shows station/runtime/model/modeShort, passes 320pt and 1.3x audit" {
  let items : Array[Json] = [
    cn_compact_item("ws1/s1", "Willow", "c1", "Bot-One", "online", "在线", 4),
    cn_compact_item("ws1/s1", "Willow", "c2", "Bot-Two", "online", "在线", 0),
    cn_compact_item("ws1/s2", "Maple", "c3", "Bot-Three", "busy", "连接中", 1),
    cn_compact_item("ws1/s2", "Maple", "c4", "Bot-Four", "error", "认证失败", 0),
    cn_compact_item("ws1/s1", "Willow", "c5", "Bot-Five", "offline", "离线", 0),
    cn_compact_item("ws1/s2", "Maple", "c6", "Bot-Six", "online", "在线", 12),
    cn_compact_item("ws1/s1", "Willow", "c7", "Bot-Seven", "online", "在线", 2),
  ]
  let t = cn_compact_tester(items, w=390.0, h=844.0, platform=2)
  assert_eq(t.audit(), [], msg="390x844 connects audit failed")

  // >= 7 connects visible on first screen without scrolling, inside one unified card (6 hairlines for 7 rows)
  let names = ["Bot-One", "Bot-Two", "Bot-Three", "Bot-Four", "Bot-Five", "Bot-Six", "Bot-Seven"]
  let mut visible = 0
  for name in names {
    match t.find(name) {
      Some((_, y)) if y < 820.0 => visible += 1
      _ => ()
    }
  }
  assert_true(visible >= 7, msg="expected >= 7 connects visible on 390x844, got \{visible}")
  assert_eq(sl_seps_drawn(t).length(), 6, msg="expected single unified card with 6 hairlines for 7 connects")

  // Line 2 shows station, runtime, model, modeShort as independent nodes without `" · "`
  assert_true(t.find("Willow") is Some(_), msg="station name shown")
  assert_true(t.find("Maple") is Some(_), msg="second station name shown")
  assert_true(t.find("Claude Code") is Some(_), msg="runtime shown")
  assert_true(t.find("Opus 5.5") is Some(_), msg="model shown")
  assert_true(t.find("多会话") is Some(_), msg="modeShort shown")
  let middots = t.words().filter(fn(w) { w.0.contains(" · ") }).map(fn(w) { w.0 })
  assert_eq(middots, [], msg="unexpected middot concatenation: \{Repr(middots)}")

  // Screen-reader a11y label includes both online status and session count when sessions > 0
  t.set_a11y(true)
  t.draw()
  let said = t.a11y_said()
  assert_true(
    said.contains("在线") && said.contains("4") && said.contains("会话"),
    msg="expected online connect a11y_said to include status and session count, got \{said}",
  )

  // 320pt narrow and 1.3x font scale audit
  let t320 = cn_compact_tester(items, w=320.0, h=640.0, platform=2)
  assert_eq(t320.audit(), [], msg="320pt connects audit failed")
  let t13 = cn_compact_tester(items, w=390.0, h=844.0, platform=2, words_scale=1.3)
  assert_eq(t13.audit(), [], msg="390pt 1.3x connects audit failed")
}

///|
test "connects_node: 320pt truncates super-long station, runtime, and model names without audit faults" {
  let long_item : Json = {
    "station": "ws1/s1",
    "stationName": "tokyo-studio-production-build-host-01",
    "connect": {
      "id": "c-long",
      "kind": "slack",
      "name": "Super-Long-Deployment-Monitor-Bot",
      "team": "Acme Engineering Workspace",
      "presence": "online",
      "statusText": "在线",
      "sessions": 18,
      "runtimeText": "Antigravity CLI Runtime",
      "modelName": "Claude Opus 5.5 Extended Thinking",
      "bind": { "runtime": "claude", "model": "claude-opus-5-5" },
      "modeShort": "多会话",
      "modeText": "每个 thread 一个会话",
    },
  }
  let t = cn_compact_tester([long_item], w=320.0, h=640.0, platform=2)
  assert_eq(t.audit(), [], msg="320pt long station/runtime/model connects audit failed")
  let t13 = cn_compact_tester([long_item], w=320.0, h=640.0, platform=2, words_scale=1.3)
  assert_eq(t13.audit(), [], msg="320pt 1.3x long station/runtime/model connects audit failed")
}

///|
test "connects_node: English online a11y label uses singular '1 session' when sessions == 1" {
  let items : Array[Json] = [
    cn_compact_item("ws1/s1", "Willow", "c-one", "Solo-Bot", "online", "Online", 1),
    cn_compact_item("ws1/s1", "Willow", "c-many", "Many-Bot", "online", "Online", 3),
  ]
  let t = cn_compact_tester(items, w=390.0, h=844.0, platform=2)
  @sf.set_language(Some("en"))
  t.set_a11y(true)
  t.draw()
  let said = t.a11y_said()
  @sf.set_language(None)
  assert_true(said.contains("Online, 1 session"), msg="expected singular 'Online, 1 session', got \{said}")
  assert_true(!said.contains("1 sessions"), msg="unexpected plural '1 sessions' in \{said}")
  assert_true(said.contains("Online, 3 sessions"), msg="expected plural 'Online, 3 sessions', got \{said}")
}

///|
test "connects_node: unified card hairlines fade smoothly on mouse hover and touch press-and-hold" {
  let items : Array[Json] = [
    cn_compact_item("ws1/s1", "Willow", "c1", "Conn-A", "online", "在线", 3),
    cn_compact_item("ws1/s1", "Willow", "c2", "Conn-B", "online", "在线", 0),
    cn_compact_item("ws1/s2", "Maple", "c3", "Conn-C", "offline", "离线", 0),
  ]
  let rest_color = @sf.rule_color()
  let rest_alpha = (rest_color & 0xFFL).to_int()

  // Mouse hover on middle row fades both adjacent hairlines
  let tm = cn_compact_tester(items, w=390.0, h=844.0, platform=0)
  let seps = sl_seps_drawn(tm)
  assert_eq(seps.length(), 2, msg="expected 2 connects hairlines at rest, got \{seps.length()}")
  let (bx, by, bw, bh) = tm.rect_of("Conn-B").unwrap()
  tm.move_to(bx + bw / 2.0, by + bh / 2.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, seps[0].0), 0, msg="hover Conn-B fades A|B")
  assert_eq(sl_sep_alpha_at(tm, seps[1].0), 0, msg="hover Conn-B fades B|C")
  tm.move_to(4.0, 4.0)
  tm.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tm, seps[0].0), rest_alpha, msg="leaving Conn-B restores A|B")
  assert_eq(sl_sep_alpha_at(tm, seps[1].0), rest_alpha, msg="leaving Conn-B restores B|C")

  // Touch press-and-hold fades both adjacent hairlines and restores on release
  let tf = cn_compact_tester(items, w=390.0, h=844.0, platform=2)
  let fseps = sl_seps_drawn(tf)
  assert_eq(fseps.length(), 2, msg="touch expected 2 connects hairlines")
  let (fbx, fby, fbw, fbh) = tf.rect_of("Conn-B").unwrap()
  tf.press_at(fbx + fbw / 2.0, fby + fbh / 2.0)
  tf.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tf, fseps[0].0), 0, msg="touch hold Conn-B fades A|B")
  assert_eq(sl_sep_alpha_at(tf, fseps[1].0), 0, msg="touch hold Conn-B fades B|C")
  tf.release(4.0, 4.0)
  tf.run_for(@sf.dur_ms + 30.0)
  assert_eq(sl_sep_alpha_at(tf, fseps[0].0), rest_alpha, msg="touch release restores A|B")
  assert_eq(sl_sep_alpha_at(tf, fseps[1].0), rest_alpha, msg="touch release restores B|C")
}
