// The windows of one run (window_slots.mbt): each window beside the first its own tree, drawn in its first frame,
// pressed and read apart from the first's; closed, its tree let go of and the first going on as it was.

///|
/// A Tester whose first window shows `首个窗口` and a button counting its presses in `first`, its windows opening in the
/// run, each beside it showing what it was opened for and a button counting in `beside`; `gone` counts the trees of
/// windows beside let go of.
fn windows_tester(first : Ref[Int], beside : Ref[Int], gone : Ref[Int]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  t.set_windows_in_process(true)
  let page = fn(root : @view.View, title : String, count : Ref[Int]) {
    root.box(fn(b) {
      b.width(Is(Some(200.0))).height(Is(Some(40.0))).words(Is(title)) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      b
      .width(Is(Some(120.0)))
      .height(Is(Some(44.0)))
      .says(Is(Some(@view.said(Button, label="按一下"))))
      .on_press(fn() { count.val += 1 })
      .words(Is("按一下"))
      |> ignore
    })
    |> ignore
  }
  set_window_tree(fn(_wid, what) {
    fn(root) {
      root.owns(fn() { gone.val += 1 }) |> ignore
      page(root, what, beside)
    }
  })
  set_view_app(fn(root) { page(root, "首个窗口", first) })
  t.draw()
  t
}

///|
fn shown_words(t : Tester) -> Array[String] {
  t.words().map(fn(w) { w.0 })
}

///|
test "a window opened beside the first: its tree drawn in its first frame, its words its own, the first's unchanged" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  assert_eq(wid, 1)
  t.draw()
  assert_true(shown_words(t).contains("首个窗口"), msg="\{Repr(shown_words(t))}")
  assert_false(shown_words(t).contains("屏幕窗口"), msg="\{Repr(shown_words(t))}")
  let words = Ref([])
  t.in_window(wid, fn() { words.val = shown_words(t) })
  assert_true(words.val.contains("屏幕窗口"), msg="\{Repr(words.val)}")
  assert_false(words.val.contains("首个窗口"), msg="\{Repr(words.val)}")
  assert_eq(current_window_id(), 0)
  assert_eq(t.windows_beside(), [(1, "屏幕窗口")])
}

///|
test "a press in a window beside the first is that window's: the first's button is not pressed, nor the other way" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  t.in_window(wid, fn() { t.tap_text("按一下") })
  t.draw()
  assert_eq((first.val, beside.val), (0, 1))
  t.tap_text("按一下")
  t.draw()
  assert_eq((first.val, beside.val), (1, 1))
}

///|
test "a window beside the first closed by the person: its tree let go of, the first drawn on as it was, another opening anew" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  let told = Ref([])
  when_window_closed(fn(w) { told.val.push(w) })
  t.close_window_beside(wid)
  t.draw()
  assert_eq(gone.val, 1)
  assert_eq(told.val, [wid])
  assert_eq(t.windows_beside(), [])
  assert_true(shown_words(t).contains("首个窗口"), msg="\{Repr(shown_words(t))}")
  t.tap_text("按一下")
  t.draw()
  assert_eq(first.val, 1)
  let again = window_open_here("又一个")
  t.draw()
  let words = Ref([])
  t.in_window(again, fn() { words.val = shown_words(t) })
  assert_eq(again, 2)
  assert_true(words.val.contains("又一个"), msg="\{Repr(words.val)}")
}

///|
test "a window beside the first closed by the app: let go of between frames, the host told, the first going on" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  let wid = window_open_here("屏幕窗口")
  t.draw()
  t.in_window(wid, fn() { window_close_here(wid) })
  t.draw()
  assert_eq(gone.val, 1)
  assert_eq(t.window_ids_closed(), [wid])
  assert_eq(t.windows_beside(), [])
  assert_eq(current_window_id(), 0)
}

///|
test "no window opens beside the first where the host opens them as runs of their own" {
  let (first, beside, gone) = (Ref(0), Ref(0), Ref(0))
  let t = windows_tester(first, beside, gone)
  t.set_windows_in_process(false)
  t.draw()
  assert_eq(window_open_here("屏幕窗口"), 0)
  assert_eq(t.windows_beside(), [])
}
