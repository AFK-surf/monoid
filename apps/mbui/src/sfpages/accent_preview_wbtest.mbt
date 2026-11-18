// 外观's 主题色 (appearance.mbt over @sf.accent_pick_node): a dot the pointer comes over shows the window in its colours
// a moment, the one set again as the pointer leaves it unchosen or the page goes; one chosen is set (prefs.set) and kept
// as the pointer leaves it.

///|
/// The pointer moved over the middle of the dot read out as `name`.
fn over_dot(t : @ui.Tester, name : String) -> Unit raise {
  let (x, y, w, h) = t.get(Radio, label=name).rect
  t.move_to(x + w / 2.0, y + h / 2.0)
  t.draw()
}

///|
test "外观's colour dots: the pointer over one shows its colours a moment, off it the one set again" {
  for w in [390.0, 1280.0] {
    let at = "\{w}"
    let sets : Array[Json] = []
    let t = setting_tester(Appearance, w, platform=0, over=fn(s) {
      { ..s, call: fn(name, params, done) { if name == "prefs.set" { sets.push(params) }; (s.call)(name, params, done) } }
    })
    assert_eq(@sf.accent_key(), "", msg=at)
    over_dot(t, "蓝色")
    assert_eq(@sf.accent_key(), "blue", msg="\{at}: shown over blue")
    // (from one dot to the next: the next one's, never the one set between them)
    over_dot(t, "紫色")
    assert_eq(@sf.accent_key(), "purple", msg="\{at}: shown over purple")
    t.move_to(4.0, 4.0)
    t.draw()
    assert_eq(@sf.accent_key(), "", msg="\{at}: the one set again")
    assert_true(sets.is_empty(), msg="\{at}: nothing set by pointing")
    // chosen: set, and kept as the pointer leaves it
    over_dot(t, "青色")
    t.click(Radio, label="青色")
    t.draw()
    assert_eq(sets.map(fn(s) { s.stringify() }), ["{\"accent\":\"teal\"}"], msg=at)
    t.move_to(4.0, 4.0)
    t.draw()
    assert_eq(@sf.accent_key(), "teal", msg="\{at}: kept once chosen")
    let faults = t.audit()
    assert_true(faults.is_empty(), msg="\{at}: \{faults.join("\n")}")
  }
}

///|
test "外观 let go while a dot shows its colours: the one set again" {
  let t = setting_tester(Appearance, 1280.0, platform=0)
  over_dot(t, "粉色")
  assert_eq(@sf.accent_key(), "pink")
  app.nav.pop() |> ignore
  t.run_for(@ui.move_most_ms)
  assert_eq(@sf.accent_key(), "")
}
