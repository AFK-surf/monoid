// A runtime's 卸载 in its row of a station's 软件与更新 (software_row_node): in its ⋯ after 停用/启用, in red, only
// where it is installed and its station says it can remove it (none from a station older than that), for the
// station's managers; asked first, then the station asked to remove it (`software.uninstall`).

///|
/// A runtime's row (`row`) as its station's page has it for someone (`manager`), its station saying which runtimes it
/// turned off where `turns_off`; and what the core was asked.
fn uninstall_rig(row : Json, turns_off : Bool, manager~ : Bool = true, w~ : Double = 390.0, platform~ : Int = 2) -> (@ui.Tester, Array[(String, Json)]) {
  @sfbase.reset()
  reset()
  @settings.reset()
  @sffixture.fixture_reset()
  @sf.presenters_reset()
  @sf.set_words(@sfbase.fill)
  let calls : Array[(String, Json)] = []
  let base = @sffixture.fixture("settings")
  let src : Source = {
    ..base,
    call: fn(name, params, done) {
      calls.push((name, params))
      done(Ok(Json::null()))
    },
  }
  let core = @sfbase.settings_core(src, rig_workspace)
  let t = station_part_tester(fn(p) {
    software_row_node(p, core, "ws1/st1", fn() { Some(row) }, manager, fn() { false }, fn() { false }, fn() { true }, @sf.TipLayer::new(fn() { None }),
      supports_disable=fn() { turns_off },
    )
  }, w~, h=600.0, platform~)
  (t, calls)
}

///|
/// Claude Code installed, removable from here (`uninstallable`: none where the station says nothing of it).
fn claude_row(installed~ : Bool = true, uninstallable~ : Bool? = Some(true)) -> Json {
  let fields : Map[String, Json] = {
    "id": "claude",
    "name": "Claude Code",
    "installed": Json::boolean(installed),
    "updatable": Json::boolean(true),
    "state": "idle",
    "shownText": if installed { "2.1.4" } else { "未安装" },
  }
  if uninstallable is Some(u) {
    fields["uninstallable"] = Json::boolean(u)
  }
  Json::object(fields)
}

///|
/// The runtime's ⋯ pressed and its menu at rest: the labels of its items, top to bottom.
fn uninstall_menu(t : @ui.Tester) -> Array[String] {
  t.run_for(@ui.move_most_ms)
  t.click(Button, label="更多")
  t.draw()
  presented_in(t)
  ["停用", "启用", "卸载"].filter(fn(label) { t.query(MenuItem, label~) is Some(_) })
}

///|
test "a runtime's ⋯ offers 卸载 after 停用, in red, only where its station can remove it" {
  for (w, platform) in page_cases {
    let at = "\{w} platform \{platform}"
    // Its station turns runtimes off and can remove this one: 停用, then 卸载 under it.
    let (t, _) = uninstall_rig(claude_row(), true, w~, platform~)
    assert_eq(uninstall_menu(t), ["停用", "卸载"], msg=at)
    let (_, off_y, _, _) = t.get(MenuItem, label="停用").rect
    let (_, out_y, _, _) = t.get(MenuItem, label="卸载").rect
    assert_true(out_y > off_y, msg="\{at}: 卸载 at \{out_y} under 停用 at \{off_y}")
  }
  // A station that says nothing of turning runtimes off, but can remove it: ⋯ with 卸载 alone.
  let (alone, _) = uninstall_rig(claude_row(), false)
  assert_eq(uninstall_menu(alone), ["卸载"])
  // A station older than 卸载 (no `uninstallable`): 停用 alone.
  let (old, _) = uninstall_rig(claude_row(uninstallable=None), true)
  assert_eq(uninstall_menu(old), ["停用"])
  // Nothing in it to offer: no ⋯ at all.
  for case in [
    (claude_row(uninstallable=Some(false)), true, "not removable from here"),
    (claude_row(installed=false, uninstallable=Some(true)), true, "not installed"),
    (claude_row(), false, "not a manager"),
  ] {
    let (row, manager, why) = case
    let (t, _) = uninstall_rig(row, false, manager~)
    t.run_for(@ui.move_most_ms)
    assert_true(t.query(Button, label="更多") is None, msg=why)
  }
}

///|
test "卸载 asks first, then asks the station to remove it" {
  let (t, calls) = uninstall_rig(claude_row(), true)
  assert_eq(uninstall_menu(t), ["停用", "卸载"])
  t.click(MenuItem, label="卸载")
  t.draw()
  presented_in(t)
  assert_true(t.query(Dialog, label="卸载运行时") is Some(_) || t.query(AlertDialog, label="卸载运行时") is Some(_), msg=t.words().map(fn(x) { x.0 }).join("|"))
  assert_true(t.find("Claude Code") is Some(_), msg=t.words().map(fn(x) { x.0 }).join("|"))
  assert_true(
    t.find("将从本机移除，使用中的对话无法发消息；账号与记录保留，之后可重装。") is Some(_),
    msg=t.words().map(fn(x) { x.0 }).join("|"),
  )
  assert_eq(calls.filter(fn(c) { c.0 == "software.uninstall" }).length(), 0, msg="not before it is confirmed")
  t.click(Button, label="卸载")
  t.draw()
  let asked = calls.filter(fn(c) { c.0 == "software.uninstall" })
  assert_eq(asked.length(), 1)
  assert_eq(text(Some(asked[0].1), "id"), "claude")
  assert_eq(text(Some(asked[0].1), "station"), "ws1/st1")
}
