// What the library keeps across runs is each run's own (mbui's on_reset, as presented_each_run_wbtest has the
// presenters): a run that leaves a menu open, a mark tapped open, a page's rows as drawn, a text read and
// the reader's layout changed, the system's bars said, has none of it as the next run begins. Each failed before these
// were put back as a run begins: only the app's reset (sfapp's) put them back, so a run without the app (a Tester of
// sfpages' or of this library's) was given what the run before it left.

///|
/// A run of its own: a window with nothing in it.
fn ker_run() -> @ui.Tester {
  set_words(fn(key, _) { key })
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  t.draw()
  t
}

///|
test "a run begins with no menu open, none going: what the run before left is not the next one's" {
  ker_run() |> ignore
  menu_set("甲")
  menu_open_at.val = (10.0, 20.0)
  menu_going.set(["乙"])
  ker_run() |> ignore
  assert_eq(menu_open.untracked(), "")
  assert_false(menu_open_by.peek("甲"))
  assert_eq(menu_going.count(), 0)
  assert_eq(menu_open_at.val, (0.0, 0.0))
}

///|
test "a run begins with no text read, the reader's layout as at first and its panel shut, whatever the run before left" {
  ker_run() |> ignore
  reading_for("甲") |> ignore
  layout_open.set(Some("甲"))
  style_here.set({ ..reader_style_default, size: reader_style_default.size + 2 })
  ker_run() |> ignore
  assert_true(readings.is_empty())
  assert_true(layout_open.untracked() is None)
  assert_true(style_here.untracked() == reader_style_default, msg="the reader's layout as at first")
}

///|
test "a run begins with none of the system's bars said, nothing said over the window, whatever the run before said" {
  ker_run() |> ignore
  native_bars.on.set(true)
  native_bars.side.set(30.0)
  native_foot_made.set(Some(12.0))
  native_foot_rest.val = Some(12.0)
  native_over_up("屏幕", alive=fn() { true }) |> ignore
  ker_run() |> ignore
  assert_false(native_bars.on.untracked())
  assert_eq(native_bars.side.untracked(), 0.0)
  assert_true(native_foot_made.untracked() is None)
  assert_true(native_foot_rest.val is None)
  assert_false(native_over.up)
  assert_true(native_claims.is_empty())
}

///|
test "a run begins with no active transient overlay state and transient_seq reset, whatever the run before left" {
  ker_run() |> ignore
  let id = transient_next_id()
  transient_claim(id, fn() { None }, fn() { false }, fn() {  })
  assert_true(transient_seq.val > 0)
  assert_true(transient_active.val is Some(_))
  ker_run() |> ignore
  assert_eq(transient_seq.val, 0)
  assert_true(transient_active.val is None)
  assert_true(transient_tip_active.val is None)
  assert_true(window_hover_at.val is None)
  assert_true(window_hover_root.val is None)
}
