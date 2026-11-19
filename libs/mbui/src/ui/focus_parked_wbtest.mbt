// The focus in what is laid out nowhere waits for it (Tree::outs_told's focus_parked): laid out again, nothing having
// taken the focus meanwhile, it has it again (a sidebar hidden while the device waits in the lock, its 新建对话);
// the focus come meanwhile to an old view's field, it stays there as that comes back.

///|
/// A tree's button 树的按钮 in a box laid out nowhere while `hidden`, beside an old view's field 旧字段.
fn parked_tester(hidden : @signals.Signal[Bool]) -> Tester {
  let field = Field::new()
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    old(root, fn(c) { c.editor("parked/field", placeholder="旧字段", field~) |> ignore }).height(Is(Some(60.0))) |> ignore
    root.box(fn(side) {
      side.laid_nowhere(By(fn() { hidden.get() })) |> ignore
      side.box(fn(x) {
        x
        .width(Is(Some(80.0)))
        .height(Is(Some(40.0)))
        .presses(Is(true))
        .focusable(Is(true))
        .says(Is(Some(@view.said(Button, label="树的按钮"))))
        .on_press(fn() {  })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
fn focus_named(t : Tester) -> String {
  t.focused().map(fn(s) { "\{s.role} \{s.label}" }).unwrap_or("none")
}

///|
test "the focus in what is laid out nowhere: back on it as it is laid out again, nothing having taken it meanwhile" {
  let hidden = @signals.signal(false)
  let t = parked_tester(hidden)
  t.key(key_tab)
  t.key(key_tab)
  t.draw()
  let was = focus_named(t)
  assert_eq(was, "Button 树的按钮")
  hidden.set(true)
  t.draw()
  let gone = focus_named(t)
  hidden.set(false)
  t.draw()
  assert_eq((gone, focus_named(t)), ("none", "Button 树的按钮"))
}

///|
test "the focus in what is laid out nowhere, come meanwhile to an old view's field: on the field still as that is laid out again" {
  let hidden = @signals.signal(false)
  let t = parked_tester(hidden)
  t.key(key_tab)
  t.key(key_tab)
  t.draw()
  assert_eq(focus_named(t), "Button 树的按钮")
  hidden.set(true)
  t.draw()
  t.tap_text("旧字段")
  t.draw()
  let on_field = focus_named(t)
  hidden.set(false)
  t.draw()
  assert_eq((on_field, focus_named(t)), ("TextField 旧字段", "TextField 旧字段"))
}

// The same of an old view's field: laid out nowhere as it has the focus, none of it built, the focus let go of (the
// soft keyboard put away, nothing typed into it); laid out again, nothing having taken the focus meanwhile, the focus
// back on it. A part over it in its place, giving the focus back as it goes (View::focus_returns), as one change with it.

///|
/// An old view's field 旧字段 in a box laid out nowhere while `hidden`, and, where `cover`, a part in its place while
/// `hidden` that gives the focus back as it goes, with a button 盖上的按钮; beside it, a tree's button 外面的按钮.
/// `present`: whether the old view is there at all.
fn old_parked_tester(
  hidden : @signals.Signal[Bool],
  field : Field,
  cover? : Bool = false,
  present? : @signals.Signal[Bool] = @signals.signal(true),
) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(x) {
      x
      .width(Is(Some(80.0)))
      .height(Is(Some(40.0)))
      .presses(Is(true))
      .focusable(Is(true))
      .says(Is(Some(@view.said(Button, label="外面的按钮"))))
      .on_press(fn() {  })
      |> ignore
    })
    |> ignore
    if cover {
      root.show(fn() { hidden.get() }, at_once=true, fn(g) {
        g.grow(Is(1.0)).focus_returns() |> ignore
        g.box(fn(x) {
          x
          .width(Is(Some(80.0)))
          .height(Is(Some(40.0)))
          .presses(Is(true))
          .focusable(Is(true))
          .says(Is(Some(@view.said(Button, label="盖上的按钮"))))
          .on_press(fn() {  })
          |> ignore
        })
        |> ignore
      })
    }
    root.box(fn(s) {
      s.grow(Is(1.0)).laid_nowhere(By(fn() { hidden.get() })) |> ignore
      s.show(fn() { present.get() }, at_once=true, fn(p) {
        old(p, fn(c) { c.editor("old-parked/field", placeholder="旧字段", field~) |> ignore }).height(Is(Some(60.0)))
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "an old view's field with the focus laid out nowhere, a part in its place giving the focus back: the keyboard put away, nothing typed into it, pressed beside or not; laid out again, the focus back on it, typed into" {
  let hidden = @signals.signal(false)
  let field = Field::new()
  let t = old_parked_tester(hidden, field, cover=true)
  t.tap_text("旧字段")
  t.draw()
  let was = (focus_named(t), t.ime().0)
  hidden.set(true)
  t.draw()
  let gone = (focus_named(t), t.ime().0)
  t.type_text("zq")
  t.draw()
  let typed_unpressed = field.text()
  t.tap(300.0, 250.0)
  t.draw()
  t.type_text("zq")
  t.draw()
  let typed_pressed = field.text()
  hidden.set(false)
  t.draw()
  let back = (focus_named(t), t.ime().0, t.ime().1)
  t.type_text("ok")
  t.draw()
  assert_eq(
    (was, gone, typed_unpressed, typed_pressed, back, field.text()),
    (("TextField 旧字段", true), ("none", false), "", "", ("TextField 旧字段", true, ""), "ok"),
  )
}

///|
test "an old view's field with the focus laid out nowhere, the focus come to the part in its place: that part gone and the field laid out again in one change, the focus back on the field" {
  let hidden = @signals.signal(false)
  let field = Field::new()
  let t = old_parked_tester(hidden, field, cover=true)
  t.tap_text("旧字段")
  t.draw()
  hidden.set(true)
  t.draw()
  t.key(key_tab)
  t.draw()
  if focus_named(t) != "Button 盖上的按钮" {
    t.key(key_tab)
    t.draw()
  }
  let on_cover = focus_named(t)
  hidden.set(false)
  t.draw()
  let back = (focus_named(t), t.ime().0)
  t.type_text("ok")
  t.draw()
  assert_eq((on_cover, back, field.text()), ("Button 盖上的按钮", ("TextField 旧字段", true), "ok"))
}

///|
test "an old view's field with the focus laid out nowhere: the keyboard put away, nothing typed into it; laid out again, the focus back on it" {
  let hidden = @signals.signal(false)
  let field = Field::new()
  let t = old_parked_tester(hidden, field)
  t.tap_text("旧字段")
  t.draw()
  hidden.set(true)
  t.draw()
  let gone = (focus_named(t), t.ime().0)
  t.type_text("zq")
  t.draw()
  let typed = field.text()
  hidden.set(false)
  t.draw()
  let back = (focus_named(t), t.ime().0)
  assert_eq((gone, typed, back), (("none", false), "", ("TextField 旧字段", true)))
}

///|
test "an old view's field with the focus laid out nowhere, the focus come meanwhile to a tree's button beside it: on the button still as the field is laid out again" {
  let hidden = @signals.signal(false)
  let field = Field::new()
  let t = old_parked_tester(hidden, field)
  t.tap_text("旧字段")
  t.draw()
  hidden.set(true)
  t.draw()
  t.key(key_tab)
  t.draw()
  let on_button = focus_named(t)
  hidden.set(false)
  t.draw()
  t.type_text("zq")
  t.draw()
  assert_eq((on_button, focus_named(t), field.text()), ("Button 外面的按钮", "Button 外面的按钮", ""))
}

///|
test "an old view's field with the focus laid out nowhere for frames, then let go of: laid out again, nothing has the focus, the keyboard put away" {
  let hidden = @signals.signal(false)
  let present = @signals.signal(true)
  let field = Field::new()
  let t = old_parked_tester(hidden, field, present~)
  t.tap_text("旧字段")
  t.draw()
  hidden.set(true)
  t.draw()
  t.frame()
  t.frame()
  t.frame()
  present.set(false)
  t.draw()
  hidden.set(false)
  t.draw()
  t.type_text("zq")
  t.draw()
  assert_eq((g().focus, t.ime().0, focus_named(t), field.text()), (0, false, "none", ""))
}
