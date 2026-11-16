// A button said its layer's default (@headless.button's `default_on`, view's View::default_press), under a look of the
// tests' own: Enter that nothing with the focus takes presses it; a button with the focus takes its own Enter; a
// default that cannot be pressed, or two of them, none; a field that gives up its words to nobody hands its Enter on
// to it, one that gives them to its caller keeps it. Each window is made by `window` (window_test.mbt).

///|
/// What a case keeps: its window, what was pressed (by name, in order), what a field gave up, the default's state.
struct DefaultCase {
  t : @ui.Tester
  pressed : Array[String]
  given : Array[String]
  off : @signals.Signal[Bool]
}

///|
/// A window 400 by 300 holding a modal panel (one layer): a ground that takes the focus and no key ("底"), a button
/// "取消",
/// a button "确认" its default while `on` (and not disabled: `off`), with `twice` another default "也确认", and a
/// one-line field "名字" that gives its words up to its caller where `takes`.
fn default_case(twice? : Bool = false, takes? : Bool = false) -> DefaultCase raise {
  let pressed : Array[String] = []
  let given : Array[String] = []
  let off = @signals.signal(false)
  let field = @ui.Field::new(text="")
  let t = window(fn(root) {
    root.box(fn(panel) {
      panel
      .says(Is(Some(@view.said(Dialog, label="面板"))))
      .modal(Is(true))
      .presses(Is(true))
      .focusable(Is(true), keys=0, tab=false)
      |> ignore
      let look = fn(v : @view.View, _ : @headless.Button) {
        v.width(Is(Some(80.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
      }
      @headless.button(panel, fn() { "取消" }, fn(_) { pressed.push("取消") }, look) |> ignore
      @headless.button(
        panel,
        fn() { "确认" },
        fn(_) { pressed.push("确认") },
        look,
        disabled=fn() { off.get() },
        default_on=fn() { true },
      )
      |> ignore
      if twice {
        @headless.button(panel, fn() { "也确认" }, fn(_) { pressed.push("也确认") }, look, default_on=fn() { true })
        |> ignore
      }
      if takes {
        @ui.field(panel, field, label="名字", max_lines=1, submitted=fn(w) { given.push(w) }) |> ignore
      } else {
        @ui.field(panel, field, label="名字", max_lines=1) |> ignore
      }
    })
    |> ignore
  })
  { t, pressed, given, off }
}

///|
test "Enter with the focus on the panel's ground presses its default; Enter on another button presses that one" {
  let k = default_case()
  k.t.act(Dialog, Focus, label="面板")
  k.t.enter()
  let on_ground = k.pressed.copy()
  k.t.act(Button, Focus, label="取消")
  k.t.enter()
  assert_eq((on_ground, k.pressed), (["确认"], ["确认", "取消"]))
}

///|
test "a default that cannot be pressed, or two defaults in one layer: Enter presses none" {
  let k = default_case()
  k.off.set(true)
  k.t.frame()
  k.t.act(Dialog, Focus, label="面板")
  k.t.enter()
  let two = default_case(twice=true)
  two.t.act(Dialog, Focus, label="面板")
  two.t.enter()
  assert_eq((two.pressed, k.pressed), ([], []))
}

///|
test "a one-line field giving its words up to nobody hands Enter to the default; one giving them to its caller keeps it" {
  let k = default_case()
  k.t.act(TextField, Focus, label="名字")
  k.t.type_text("甲")
  k.t.enter()
  let handed = (k.pressed.copy(), k.given.copy())
  let kept = default_case(takes=true)
  kept.t.act(TextField, Focus, label="名字")
  kept.t.type_text("乙")
  kept.t.enter()
  assert_eq((handed, (kept.pressed, kept.given)), ((["确认"], []), ([], ["乙"])))
}
