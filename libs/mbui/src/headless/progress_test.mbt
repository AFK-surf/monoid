// The headless progress bar (@headless.progress), under a look of the tests' own: read out a ProgressBar by its name
// with its range and its words as its caller's value changes; with no number while indeterminate; whole while finishing;
// taking no press and no focus. Each window is made by `window` (window_test.mbt), which holds that progress.mbt draws
// and lays out nothing.

///|
/// What a case keeps: its window, the value and whether it is finishing (the caller's), and what its look read.
struct ProgressCase {
  t : @ui.Tester
  value : @signals.Signal[Double?]
  done : @signals.Signal[Bool]
  state : Ref[@headless.Progress?]
}

///|
/// A window with a button "别处" and a progress bar "上传" over 0 … 200 at `value`, finishing while `done`, its look a
/// bar 200 by 8 whose width follows its part.
fn progress_case(value_text? : (Double) -> String) -> ProgressCase raise {
  let value : @signals.Signal[Double?] = @signals.signal(Some(50.0))
  let done = @signals.signal(false)
  let state = Ref(None)
  let t = window(fn(root) {
    root.box(fn(e) {
      e
      .width(Is(Some(50.0)))
      .height(Is(Some(30.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="别处"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    @headless.progress(
      root,
      fn() { value.get() },
      label=fn() { "上传" },
      max=200.0,
      value_text?,
      finishing=fn() { done.get() },
      fn(v, p) {
        state.val = Some(p)
        v.width(Is(Some(200.0))).height(Is(Some(8.0))).ground(By(fn() { if p.indeterminate() { c_hovered } else { c_rest } })) |> ignore
      },
    )
    |> ignore
  })
  { t, value, done, state }
}

///|
test "a progress bar is read out a ProgressBar by its name, its range and its percent; its look reads its part" {
  let k = progress_case()
  k.t.set_a11y(true)
  let s0 = k.t.get(ProgressBar, label="上传")
  let p = k.state.val.unwrap()
  let read0 = (p.value(), p.part(), p.indeterminate(), p.finishing())
  k.value.set(Some(150.0))
  k.t.frame()
  let s1 = k.t.get(ProgressBar, label="上传")
  // (past its most: held at its most)
  k.value.set(Some(500.0))
  k.t.frame()
  let s2 = k.t.get(ProgressBar, label="上传")
  assert_eq(
    (s0.value, s0.range, read0, s1.value, s1.range, p.part(), s2.value, s2.range),
    (
      "25%",
      Some((0.0, 50.0, 200.0)),
      (Some(50.0), 0.25, false, false),
      "75%",
      Some((0.0, 150.0, 200.0)),
      1.0,
      "100%",
      Some((0.0, 200.0, 200.0)),
    ),
  )
}

///|
test "indeterminate: read out with no number and no range, its part 0; finishing: read out whole, its part 1, whatever the value said" {
  let k = progress_case()
  k.value.set(None)
  k.t.frame()
  let s0 = k.t.get(ProgressBar, label="上传")
  let p = k.state.val.unwrap()
  let read0 = (p.value(), p.part(), p.indeterminate())
  k.done.set(true)
  k.t.frame()
  let s1 = k.t.get(ProgressBar, label="上传")
  assert_eq(
    (s0.value, s0.range, read0, s1.value, s1.range, p.part(), p.indeterminate(), p.finishing()),
    ("", None, (None, 0.0, true), "100%", Some((0.0, 200.0, 200.0)), 1.0, false, true),
  )
}

///|
test "a progress bar's words are its caller's; it takes no press and no focus: it says no action, nor disabled" {
  let k = progress_case(value_text=fn(v) { "已传 \{v.to_int()} 个" })
  let s = k.t.get(ProgressBar, label="上传")
  assert_eq((s.value, s.actions, s.disabled, s.focused), ("已传 50 个", [], false, false))
}
