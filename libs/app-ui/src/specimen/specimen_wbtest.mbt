// The specimen's pages, as src/shots draws them, held to mbui's audit at rest: wide light and dark, narrow light and
// dark; and as its film runs, each change looked at once it is over.

///|
fn page_case(wide : Bool, dark : Bool) -> @ui.Tester {
  let (w, h) = if wide { (960.0, 720.0) } else { (360.0, 780.0) }
  let t = @ui.Tester::new(fn(_c) {  }, w~, h~, platform=0)
  @appui.set_dark(Some(dark))
  @appui.set_type_root()
  @ui.set_view_app(fn(root) { page(root, wide~) })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
test "the specimen's pages at rest hold to mbui's audit" {
  let faults = []
  for wide in [true, false] {
    for dark in [false, true] {
      let t = page_case(wide, dark)
      for f in t.audit() {
        faults.push((wide, dark, f))
      }
    }
  }
  debug_inspect(faults, content="[]")
}

///|
test "the film's steps: a period chosen, drafts hidden and shown again, each at rest held to the audit" {
  let t = page_case(true, false)
  t.act(Radio, Activate, label="Month")
  t.run_for(@ui.move_most_ms)
  let chosen = t.get(Radio, label="Month").check
  t.act(Switch, Activate, label="Show drafts")
  t.run_for(@ui.move_most_ms)
  let hidden = (lines(t), t.audit())
  t.act(Switch, Activate, label="Show drafts")
  t.run_for(@ui.move_most_ms)
  let back = (lines(t), t.audit())
  debug_inspect((chosen, hidden, back), content="(Some(On), (1, []), (2, []))")
}

///|
/// The lines the frame draws between parts.
fn lines(t : @ui.Tester) -> Int {
  t.locate("icon:divider").length()
}
