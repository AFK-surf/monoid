// The workspace sheet's rows (sfpages workspace.mbt workspaces_list): the workspaces in the core's order, the one in use
// checked where it stands, 登录其他账号 and 新建 workspace: their marks in one column and their words on one line
// (2026-11-07: the card's row stood 16 further in, an action's words 4 less far than a workspace's), each row where it
// was whichever is in use (2026-11-21: 「workspace 会到处跑」).

///|
test "the workspace sheet: every row's mark in one column and its words on one line, checked or not" {
  let t = native_chat(466.0, 678.0, true, side=70.0)
  @sfpages.open_workspaces(fixture("chat"), At(32.0, 16.0, 150.0, 38.0))
  t.run_for(@ui.move_most_ms)
  guard t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == @ui.Role::Dialog }) is Some(sheet) else {
    fail("no sheet")
  }
  let (sx, sy, sw, sh) = sheet.rect
  let within = fn(x : Double, y : Double) { x >= sx && x <= sx + sw && y >= sy && y <= sy + sh }
  let names = ["星火工作室", "个人", @sf.t("android-misc.workspace.addAccount"), @sf.t("android-misc.workspace.new")]
  let xs : Array[Double] = []
  for n in names {
    guard t.words().iter().find_first(fn(w) { w.0 == n && within(w.1, w.2) }) is Some(w) else { fail("no \{n} in the sheet") }
    xs.push(w.1)
  }
  for i, x in xs {
    assert_eq(x, xs[0], msg="\{names[i]} at \{x}, \{names[0]} at \{xs[0]}")
  }
  // their marks: the squares before them, one column
  let leads = t.boxes_held().filter(fn(b) { b.w == 24.0 && b.h == 24.0 && within(b.x, b.y) })
  assert_eq(leads.length(), names.length(), msg="\{leads.length()} marks")
  for b in leads {
    assert_eq(b.x, leads[0].x)
  }
}

///|
/// The fixture's core (`mode`'s) as it tells the workspaces: 安娜's invitation to 开源 waiting for its account while
/// `invited` says so, the workspaces `left` names gone from its list; told anew as either changes. The calls the
/// list makes (`invitation.accept`, `invitation.decline`) kept in `calls`, unanswered; 登录其他账号 counted in
/// `signed`; the rest the fixture's.
fn ws_told(
  calls : Array[Made],
  invited : @signals.Signal[Bool],
  left : @signals.Signal[Array[String]],
  signed? : Ref[Int] = Ref(0),
  mode? : String = "home",
) -> Source {
  let base = fixture(mode)
  {
    ..base,
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard name == "workspaces" && t.value is Some(Array(a)) else { return t }
      let inv = invited.get()
      let out = left.get()
      {
        ..t,
        version: t.version * 100 + (if inv { 1 } else { 0 }) + 2 * out.length(),
        value: Some(
          Json::array(
            a.map(fn(e) {
              let ws = items(Some(e), "workspaces").filter(fn(w) { !out.contains(text(Some(w), "id")) })
              let invitations : Json = if inv {
                [{ "id": "inv2", "name": "开源", "inviter": "安娜", "role": "member" }]
              } else {
                []
              }
              with_fields(e, [("workspaces", Json::array(ws)), ("invitations", invitations)])
            }),
          ),
        ),
      }
    },
    call: fn(name, params, done) {
      match name {
        "invitation.accept" | "invitation.decline" => calls.push({ name, params, bytes: None, done })
        _ => (base.call)(name, params, done)
      }
    },
    sign_in: fn() { signed.val += 1 },
  }
}

///|
/// Home over `src` on a window 390 by 844 with the input `platform` (`wide`: made 1200 by 800 first), the workspaces
/// opened from a point at its top (`compact`: as tall as what they hold), at the frame that opened them.
fn ws_list_over(src : Source, platform~ : Int, wide~ : Bool, compact? : Bool = false) -> @ui.Tester {
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w=390.0, h=844.0, platform~)
  if wide {
    t.resize(1200.0, 800.0)
  }
  t.run_for(@ui.move_most_ms)
  @sfpages.open_workspaces(src, At(32.0, 16.0, 150.0, 38.0), compact~)
  t.frame()
  t
}

///|
/// The workspaces' panel as a screen reader finds it, if it is up.
fn ws_panel(t : @ui.Tester) -> @ui.SemNode? {
  t.semantics().iter().find_first(fn(s) { !s.hidden && s.role == @ui.Role::Dialog })
}

///|
/// Where `words` are said in the workspaces' panel (none: not in it, or it is not up).
fn ws_in_panel(t : @ui.Tester, words : String) -> (Double, Double)? {
  guard ws_panel(t) is Some(p) else { return None }
  let (sx, sy, sw, sh) = p.rect
  match t.words().iter().find_first(fn(w) { w.0 == words && w.1 >= sx && w.1 <= sx + sw && w.2 >= sy && w.2 <= sy + sh && w.5 > 0.0 }) {
    Some(w) => Some((w.1, w.2))
    None => None
  }
}

///|
/// Where `words` are said in the workspaces' panel; the test fails where they are not (`at`: which screen), saying
/// what is.
fn ws_at(t : @ui.Tester, words : String, at : String) -> (Double, Double) raise {
  match ws_in_panel(t, words) {
    Some(p) => p
    None => {
      let said = match ws_panel(t) {
        Some(p) => "panel at \{Repr(p.rect)}: " + t.words().map(fn(w) { "\{w.0}@\{w.1},\{w.2} a\{w.5}" }).join("|")
        None => "no panel"
      }
      fail("\{at}: no \{words} in the panel; \{said}")
    }
  }
}

///|
/// The three screens the workspaces open on: a sheet with a finger, a small window with a mouse, a wide one (beside
/// what opened them).
let ws_screens : Array[(Int, Bool)] = [(2, false), (0, false), (0, true)]

///|
test "the workspaces: an invitation that comes while they are up shows over the workspaces; answered, it goes" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    let invited = @signals.signal(false, same=fn(a, b) { a == b })
    let left : @signals.Signal[Array[String]] = @signals.signal([])
    let calls : Array[Made] = []
    let t = ws_list_over(ws_told(calls, invited, left), platform~, wide~)
    t.run_for(@ui.move_most_ms)
    assert_true(ws_in_panel(t, "安娜邀请你加入「开源」") is None, msg=at)
    invited.set(true)
    t.frame()
    t.run_for(@ui.move_most_ms)
    let (_, iy) = ws_at(t, "安娜邀请你加入「开源」", at)
    let (_, cy) = ws_at(t, "星火工作室", at)
    let (_, oy) = ws_at(t, "个人", at)
    assert_true(iy < cy && cy < oy, msg="\{at}: \{iy} \{cy} \{oy}")
    assert_true(ws_in_panel(t, "邀请") is Some(_), msg=at)
    // 忽略: asked, then answered and told so: gone
    let (x, y) = ws_at(t, "忽略", at)
    t.tap(x, y)
    t.frame()
    assert_eq(calls.length(), 1, msg=at)
    assert_eq(calls[0].name, "invitation.decline", msg=at)
    (calls[0].done)(Ok({}))
    invited.set(false)
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_true(ws_in_panel(t, "安娜邀请你加入「开源」") is None, msg=at)
    assert_true(ws_in_panel(t, "邀请") is None, msg=at)
    assert_true(ws_in_panel(t, "个人") is Some(_), msg=at)
  }
}

///|
test "the workspaces: one taken out while they are up goes from the list" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    let invited = @signals.signal(false, same=fn(a, b) { a == b })
    let left : @signals.Signal[Array[String]] = @signals.signal([])
    let t = ws_list_over(ws_told([], invited, left), platform~, wide~)
    t.run_for(@ui.move_most_ms)
    assert_true(ws_in_panel(t, "个人") is Some(_), msg=at)
    let (_, foot_was) = ws_at(t, "登录其他账号", at)
    left.set(["ws2"])
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_true(ws_in_panel(t, "个人") is None, msg=at)
    assert_true(ws_in_panel(t, "星火工作室") is Some(_), msg=at)
    // its foot under what is left of the list, no further down than it was: the panel as tall as what it holds
    let (_, foot) = ws_at(t, "登录其他账号", at)
    let (_, first) = ws_at(t, "星火工作室", at)
    assert_true(first < foot && foot <= foot_was, msg="\{at}: 登录其他账号 at \{foot}, was \{foot_was}")
  }
}

///|
test "the workspaces: the one in use changed while they are up is the one checked, every row where it was" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    let invited = @signals.signal(false, same=fn(a, b) { a == b })
    let left : @signals.Signal[Array[String]] = @signals.signal([])
    let t = ws_list_over(ws_told([], invited, left), platform~, wide~)
    t.run_for(@ui.move_most_ms)
    let was = (ws_at(t, "星火工作室", at), ws_at(t, "个人", at))
    assert_true(ws_selected(t, "星火工作室") && !ws_selected(t, "个人"), msg=at)
    // (switched as a press switches it: a cause, what it changes making its way)
    @view.transition(fn() { app.picked.set("ws2") })
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_eq((ws_at(t, "星火工作室", at), ws_at(t, "个人", at)), was, msg=at)
    assert_true(ws_selected(t, "个人") && !ws_selected(t, "星火工作室"), msg=at)
  }
}

///|
/// Whether the workspaces' panel's row named `name` is read out as the one chosen.
fn ws_selected(t : @ui.Tester, name : String) -> Bool {
  t.semantics().iter().any(fn(s) { !s.hidden && s.role == @ui.Role::Button && s.label == name && s.selected == Some(true) })
}

///|
test "the workspaces: 加入 pressed, both its buttons wait, a second press nothing; joined, they close, its workspace in view" {
  new_run()
  let invited = @signals.signal(true, same=fn(a, b) { a == b })
  let left : @signals.Signal[Array[String]] = @signals.signal([])
  let calls : Array[Made] = []
  let t = ws_list_over(ws_told(calls, invited, left), platform=2, wide=false)
  t.run_for(@ui.move_most_ms)
  let at = "a sheet"
  let (x, y) = ws_at(t, "加入", at)
  t.tap(x, y)
  t.frame()
  assert_eq(calls.length(), 1)
  assert_eq(calls[0].name, "invitation.accept")
  let (x, y) = ws_at(t, "忽略", at)
  t.tap(x, y)
  t.frame()
  assert_eq(calls.length(), 1)
  (calls[0].done)(Ok({ "id": "ws2" }))
  t.frame()
  t.run_for(@ui.move_most_ms)
  assert_true(ws_panel(t) is None)
  assert_eq(app.picked.get(), "ws2")
}

///|
test "the workspaces: the one in use pressed closes them; 登录其他账号 closes them and signs in another" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    let invited = @signals.signal(false, same=fn(a, b) { a == b })
    let left : @signals.Signal[Array[String]] = @signals.signal([])
    let signed = Ref(0)
    let src = ws_told([], invited, left, signed~)
    let t = ws_list_over(src, platform~, wide~)
    t.run_for(@ui.move_most_ms)
    let (x, y) = ws_at(t, "星火工作室", at)
    t.tap(x, y)
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_true(ws_panel(t) is None, msg=at)
    assert_eq(app.picked.get() == "ws2", false, msg=at)
    @sfpages.open_workspaces(src, At(32.0, 16.0, 150.0, 38.0))
    t.frame()
    t.run_for(@ui.move_most_ms)
    let (x, y) = ws_at(t, "登录其他账号", at)
    t.tap(x, y)
    t.frame()
    t.run_for(@ui.move_most_ms)
    assert_true(ws_panel(t) is None, msg=at)
    assert_eq(signed.val, 1, msg=at)
  }
}

///|
test "the workspaces, compact or as a sheet: a few as tall as what they hold, no room left empty under them" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    let tall = fn(compact : Bool) raise {
      new_run()
      let invited = @signals.signal(false, same=fn(a, b) { a == b })
      let left : @signals.Signal[Array[String]] = @signals.signal([])
      let t = ws_list_over(ws_told([], invited, left), platform~, wide~, compact~)
      t.run_for(@ui.move_most_ms)
      let p = ws_panel(t).unwrap()
      // its foot under its list, in it
      let (_, foot) = ws_at(t, "新建 workspace", at)
      let (_, others) = ws_at(t, "个人", at)
      assert_true(foot > others, msg=at)
      p.rect.3
    }
    // (less than the share of the window a long list takes: 0.7 of 800, the shortest window here; beside what opened
    // them, not compact, the popover its share as ever, panel_node's)
    let kinds = if wide { [true] } else { [true, false] }
    for compact in kinds {
      let h = tall(compact)
      assert_true(h < 0.7 * 800.0 - 100.0, msg="\{at}: compact \{compact}, \{h} tall")
    }
  }
}

///|
test "the workspaces on each screen: 邀请 and its invitation, the workspaces in their order, then 登录其他账号 and 新建 workspace at its foot, all in it" {
  for screen in ws_screens {
    let (platform, wide) = screen
    let at = "platform \{platform} wide \{wide}"
    new_run()
    let invited = @signals.signal(true, same=fn(a, b) { a == b })
    let left : @signals.Signal[Array[String]] = @signals.signal([])
    let t = ws_list_over(ws_told([], invited, left), platform~, wide~)
    t.run_for(@ui.move_most_ms)
    let ys = ["邀请", "安娜邀请你加入「开源」", "星火工作室", "个人", "登录其他账号", "新建 workspace"].map(fn(w) {
      ws_in_panel(t, w).map(fn(p) { p.1 }).unwrap_or(-1.0)
    })
    for i in 1..<ys.length() {
      assert_true(ys[i - 1] >= 0.0 && ys[i - 1] < ys[i], msg="\{at}: \{Repr(ys)}")
    }
    // the invitation's buttons beside its words, 加入 before 忽略
    let (jx, jy) = ws_in_panel(t, "加入").unwrap()
    let (ix, iy) = ws_in_panel(t, "忽略").unwrap()
    assert_true(jy == iy && jx < ix, msg=at)
    // the one in use checked
    assert_true(ws_selected(t, "星火工作室"), msg=at)
  }
}

///|
/// The others of ws_many, in their order, after 星火工作室 in use.
let ws_many_others : Array[String] = ["设计系统", "云端基建", "客户端研发", "算法实验组", "开源社区", "数据平台", "运营支持", "市场增长"]

///|
/// The fixture's core (home's) telling nine workspaces: 星火工作室 in use, then ws_many_others.
fn ws_many() -> Source {
  let base = fixture("home")
  {
    ..base,
    topic_read: fn(name, params) {
      let t = (base.topic_read)(name, params)
      guard name == "workspaces" && t.value is Some(Array(a)) else { return t }
      let ws : Array[Json] = [{ "id": "ws1", "name": "星火工作室", "stations": 2, "members": 3 }]
      for i, n in ws_many_others {
        ws.push({ "id": "ws\{i + 2}", "name": Json::string(n), "stations": 1, "members": 1 })
      }
      { ..t, value: Some(Json::array(a.map(fn(e) { with_fields(e, [("workspaces", Json::array(ws))]) }))) }
    },
  }
}

///|
/// Home over ws_many on a window `w` by `h` with the input `platform` (`wide`: made 1200 by 800 first; `lang`: the
/// device's language; `scale`: its words'), the workspaces opened from a point at its top, at rest.
fn ws_many_over(
  w : Double,
  h : Double,
  platform~ : Int,
  wide? : Bool = false,
  lang? : String = "zh",
  scale? : Double = 1.0,
) -> @ui.Tester {
  new_run()
  let src = ws_many()
  let t = @ui.Tester::new(fn(c) { view(c, src) }, tree=app_tree(src), w~, h~, platform~, env=[("MBUI_LOCALE", lang)])
  if scale != 1.0 {
    t.set_font_scale(scale)
  }
  if wide {
    t.resize(1200.0, 800.0)
  }
  t.run_for(@ui.move_most_ms)
  @sfpages.open_workspaces(src, At(32.0, 16.0, 150.0, 38.0))
  t.frame()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// A fling's glide and a finger's pull past an end come back, all over by then.
let ws_flung_ms : Double = 3000.0

///|
/// How far what the workspaces' panel draws fades out towards its top and its foot, at most of all it draws there.
fn ws_softs(t : @ui.Tester) -> (Double, Double) {
  guard ws_panel(t) is Some(p) else { return (0.0, 0.0) }
  let (_, sy, _, sh) = p.rect
  let mut top = 0.0
  let mut foot = 0.0
  for f in t.drawn_fades() {
    if f.1 >= sy && f.1 < sy + sh {
      if f.4 > top {
        top = f.4
      }
      if f.6 > foot {
        foot = f.6
      }
    }
  }
  (top, foot)
}

///|
/// The lines (rule_w high) drawn across the workspaces' panel: their tops.
fn ws_rules(t : @ui.Tester) -> Array[Double] {
  guard ws_panel(t) is Some(p) else { return [] }
  let (sx, sy, sw, sh) = p.rect
  t
  .drawn_rects()
  .filter(fn(r) { r.3 == @sf.rule_w && r.2 > sw / 2.0 && r.0 >= sx && r.0 < sx + sw && r.1 >= sy && r.1 < sy + sh })
  .map(fn(r) { r.1 })
}

///|
/// Drags the workspaces' list up by `by` from its middle, slowly, and lets it come to rest.
fn ws_dragged(t : @ui.Tester, by : Double) -> Unit raise {
  let (x, y) = ws_at(t, "云端基建", "dragged")
  t.drag(x, y, x, y - by, steps=30)
  t.run_for(ws_flung_ms)
}

///|
test "the workspaces, nine on a phone: more than the list's share, a line at its foot, faded towards it; scrolled, faded at both ends; at its end, the last whole" {
  for win in [(390.0, 844.0), (393.0, 852.0)] {
    let at = "\{win.0}x\{win.1}"
    let t = ws_many_over(win.0, win.1, platform=2)
    // one line, between the list and 登录其他账号
    let rules = ws_rules(t)
    assert_eq(rules.length(), 1, msg="\{at}: lines \{Repr(rules)}")
    let rule = rules[0]
    let (_, add) = ws_at(t, "登录其他账号", at)
    assert_true(rule < add, msg="\{at}: line \{rule}, 登录其他账号 \{add}")
    // the fourth other's words and mark show over it: there is more
    let (_, fourth) = ws_at(t, ws_many_others[3], at)
    assert_true(fourth < rule, msg="\{at}: \{ws_many_others[3]} at \{fourth}, the line at \{rule}")
    let mark = t.boxes_held().filter(fn(b) { b.w == 24.0 && b.h == 24.0 && (b.y - fourth).abs() < 24.0 })
    assert_true(mark.length() == 1 && mark[0].y < rule, msg="\{at}: its mark \{Repr(mark.map(fn(b) { b.y }))}")
    assert_eq(ws_softs(t), (0.0, 24.0), msg="\{at}: at its top")
    assert_eq(t.audit(), [], msg="\{at}: at its top")
    // in its middle: faded at both ends
    ws_dragged(t, 80.0)
    let (top, foot) = ws_softs(t)
    assert_true(top > 0.0 && foot > 0.0, msg="\{at}: in its middle \{top} \{foot}")
    // at its end: the last whole over the line, faded at its top alone
    ws_dragged(t, 600.0)
    assert_eq(ws_softs(t), (24.0, 0.0), msg="\{at}: at its end")
    let last_name = ws_many_others[ws_many_others.length() - 1]
    let (_, last) = ws_at(t, last_name, at)
    assert_true(last < rule - 24.0, msg="\{at}: \{last_name} at \{last}, the line at \{rule}")
    assert_eq(ws_rules(t), [rule], msg="\{at}: at its end")
  }
}

///|
/// Fails where the square before `words` in the workspaces' panel (its mark or icon, 24 across) does not stand on their
/// line, its middle on theirs (`at`: which screen).
fn ws_on_first_line(t : @ui.Tester, words : String, at : String) -> Unit raise {
  guard ws_panel(t) is Some(p) else { fail("\{at}: no panel") }
  let (sx, sy, sw, sh) = p.rect
  guard t.words().iter().find_first(fn(w) { w.0 == words && w.1 >= sx && w.1 <= sx + sw && w.2 >= sy && w.2 <= sy + sh })
    is Some(w) else {
    fail("\{at}: no \{words} in the panel")
  }
  let line = w.2 + w.4 / 2.0
  // (its own the nearest: a row of the list scrolled under the line over the foot may stand close over it)
  let lead = t
    .boxes_held()
    .filter(fn(b) { b.w == 24.0 && b.h == 24.0 && b.x < w.1 && b.x > w.1 - 60.0 && (b.y + 12.0 - line).abs() < 24.0 })
  assert_true(lead.length() > 0, msg="\{at}: no square before \{words}")
  let off = lead.fold(init=lead[0].y + 12.0 - line, fn(o, b) { if (b.y + 12.0 - line).abs() < o.abs() { b.y + 12.0 - line } else { o } })
  assert_true(off.abs() <= 1.5, msg="\{at}: the square before \{words} \{off} off its line's middle")
}

///|
/// Fails where the workspaces' panel of `t` breaks a rule or cuts words short, or lacks one of them (`at`: which screen).
fn ws_kept(t : @ui.Tester, at : String) -> Unit raise {
  let faults = t.audit()
  assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
  guard ws_panel(t) is Some(p) else { fail("\{at}: no panel") }
  let (sx, sy, sw, sh) = p.rect
  for w in t.words() {
    if w.1 >= sx && w.1 <= sx + sw && w.2 >= sy && w.2 <= sy + sh && w.5 > 0.0 {
      assert_true(!w.0.contains("…"), msg="\{at}: \{w.0} cut short")
    }
  }
  assert_true(ws_in_panel(t, ws_many_others[0]) is Some(_), msg=at)
  assert_eq(ws_rules(t).length(), 1, msg="\{at}: lines")
  // (beside a name and the line under it, its mark or icon on the name's line)
  ws_on_first_line(t, "星火工作室", at)
  ws_on_first_line(t, @sf.t("android-misc.workspace.addAccount"), at)
}

///|
test "the workspaces, nine: on each screen, narrow, in large words and in English, every rule kept and no words cut short" {
  // (the app's run started before its words are read: each screen's own again, ws_many_over)
  new_run()
  for screen in ws_screens {
    let (platform, wide) = screen
    ws_kept(ws_many_over(390.0, 844.0, platform~, wide~), "platform \{platform} wide \{wide}")
  }
  ws_kept(ws_many_over(320.0, 680.0, platform=2), "320x680")
  ws_kept(ws_many_over(390.0, 844.0, platform=2, scale=1.3), "words at 1.3")
  ws_kept(ws_many_over(390.0, 844.0, platform=2, lang="en"), "English")
}
