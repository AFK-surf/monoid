// A layer of the tree's that gives the focus nothing as it opens, giving back what had it as it goes
// (View::focus_returns: a menu a finger opens beside a field), opened in one change with one that gives the focus to
// its button over it: the focus on that button; that one closed, back on the field it was in, not on the layer under
// it; that closed too, on the field still.

///|
test "an old view's field with the focus; in one change a layer giving the focus nothing as it opens, and one over it giving the focus to its button: the focus on the button; the upper closed, back on the field; the lower closed, on the field" {
  let field = Field::new()
  let (low, up) = (@signals.signal(false), @signals.signal(false))
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    old(root, fn(c) { c.editor("returns/field", placeholder="旧字段", field~) |> ignore }).height(Is(Some(60.0))) |> ignore
    root.show(fn() { low.get() }, fn(l) {
      l.over(Is(true)).stacked(Is(2)).modal(Is(true)).leaves_typing().focus_returns() |> ignore
    })
    root.show(fn() { up.get() }, fn(l) {
      l.over(Is(true)).stacked(Is(3)).modal(Is(true)) |> ignore
      let b = l.box(fn(x) {
        x
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="上的按钮"))))
        .on_press(fn() {  })
        |> ignore
      })
      l.focus_opens(b) |> ignore
    })
  })
  t.draw()
  t.tap_text("旧字段")
  t.draw()
  let said = fn() { t.focused().map(fn(s) { "\{s.role} \{s.label}" }).unwrap_or("none") }
  let before = said()
  @signals.start_batch()
  low.set(true)
  up.set(true)
  @signals.end_batch()
  t.draw()
  let opened = said()
  up.set(false)
  t.draw()
  let upper_closed = said()
  low.set(false)
  t.draw()
  assert_eq((before, opened, upper_closed, said()), ("TextField 旧字段", "Button 上的按钮", "TextField 旧字段", "TextField 旧字段"))
}

///|
test "a tree field with the focus; in one change a lower leaves_typing layer and an upper focus_opens layer: closing upper returns focus and ime to the tree field; closing lower keeps it" {
  let f = Field::new()
  let (low, up) = (@signals.signal(false), @signals.signal(false))
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(h) {
      h.height(Is(Some(60.0))) |> ignore
      field(h, f, placeholder="树字段", label="树字段") |> ignore
    })
    |> ignore
    root.show(fn() { low.get() }, fn(l) {
      l.over(Is(true)).stacked(Is(2)).modal(Is(true)).leaves_typing().focus_returns() |> ignore
    })
    root.show(fn() { up.get() }, fn(l) {
      l.over(Is(true)).stacked(Is(3)).modal(Is(true)) |> ignore
      let b = l.box(fn(x) {
        x
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="上的按钮"))))
        .on_press(fn() {  })
        |> ignore
      })
      l.focus_opens(b) |> ignore
    })
  })
  t.draw()
  f.focus()
  t.draw()
  let said = fn() { t.focused().map(fn(s) { "\{s.role} \{s.label}" }).unwrap_or("none") }
  let before = (f.focused(), t.ime().0, said())
  @signals.start_batch()
  low.set(true)
  up.set(true)
  @signals.end_batch()
  t.draw()
  let opened = (f.focused(), said())
  up.set(false)
  t.draw()
  let upper_closed = (f.focused(), t.ime().0)
  t.type_text("hi")
  t.draw()
  low.set(false)
  t.draw()
  assert_eq(
    (before, opened, upper_closed, f.text(), f.focused(), t.ime().0),
    ((true, true, "TextField 树字段"), (false, "Button 上的按钮"), (true, true), "hi", true, true),
  )
}
