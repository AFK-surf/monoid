// A sheet's form on a phone: a column of the window's tree that scrolls (View::scrolls) down to the window's foot, its
// field low in it given the focus; the soft keyboard coming up as a host says it (Tester::set_ime_inset), the window's
// own size the same (a sheet over it, not laid out above the keyboard), nothing of the app reading the keyboard: the
// field brought over the keyboard's top by the frame that took it, the keyboard up before or after the focus came.

///|
/// The window, the keyboard, and a row of the form (row 12 the field: 720..780, in sight with the keyboard down).
let ims_w : Double = 390.0

///|
let ims_h : Double = 844.0

///|
let ims_kb : Double = 300.0

///|
/// A Tester drawing the form, the field it holds.
fn ims_form() -> (Tester, @view.View) {
  let field : Ref[@view.View?] = Ref(None)
  let t = Tester::new(fn(_c) {  }, w=ims_w, h=ims_h, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(ims_w))).height(Is(Some(ims_h))) |> ignore
      o.scrolls(@view.Scroll::new(), fn(held) {
        for i in 0..<30 {
          held.box(fn(r) {
            r.width(Is(Some(ims_w))).height(Is(Some(60.0))) |> ignore
            if i == 12 {
              field.val = Some(r)
              r
              .presses(Is(true))
              .focusable(Is(true))
              .says(Is(Some(@view.said(TextField, label="备注"))))
              .on_press(fn() {  })
              |> ignore
            }
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, field.val.unwrap())
}

///|
/// Where the field's foot is drawn in the window.
fn ims_foot(f : @view.View) -> Double {
  let (_, y, _, h) = f.rect()
  y + h
}

///|
test "a sheet's form down to the window's foot, the keyboard up, its field low in it given the focus: brought over the keyboard's top" {
  let (t, f) = ims_form()
  t.set_ime_inset(ims_kb)
  t.frame()
  assert_true(f.ask_focus(), msg="the field took no focus")
  t.frame()
  let foot = ims_foot(f)
  assert_true((foot - (ims_h - ims_kb)).abs() < 0.5, msg="the field's foot at \{foot}, the keyboard's top at \{ims_h - ims_kb}")
}

///|
test "a sheet's form down to the window's foot, its field low in it given the focus, then the keyboard up with nothing reading it: the field brought over the keyboard's top by the frame that took it" {
  let (t, f) = ims_form()
  assert_true(f.ask_focus(), msg="the field took no focus")
  t.frame()
  let before = ims_foot(f)
  assert_true((before - 780.0).abs() < 0.5, msg="in sight with the keyboard down: not moved, its foot at \{before}")
  t.set_ime_inset(ims_kb)
  t.frame()
  let foot = ims_foot(f)
  assert_true((foot - (ims_h - ims_kb)).abs() < 0.5, msg="the field's foot at \{foot}, the keyboard's top at \{ims_h - ims_kb}")
}
