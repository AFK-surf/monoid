// Tests for headless NumberInput: clamping, precision formatting, commit_text parsing/rollback, keyboard stepping,
// screen-reader Increment/Decrement, and press-and-hold repeat_hold stepper buttons. All windows use `window`.

///|
test "NumberInput: field a11y, keyboard stepping, screen-reader step, and commit_text" {
  let val = @signals.signal(10.0, same=fn(a : Double, b : Double) { a == b })
  let told : Array[Double] = []
  let ni = @headless.NumberInput::new(
    fn() { val.get() },
    fn(v) {
      told.push(v)
      val.set(v)
    },
    min=0.0,
    max=100.0,
    step=2.0,
    large_step=10.0,
    precision=1,
  )
  let t = window(fn(root) {
    root.box(fn(v) {
      v.width(Is(Some(160.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
      ni.field(v, fn() { "数量" })
    })
    |> ignore
  })
  let s0 = t.get(TextField, label="数量")
  assert_eq((s0.value, s0.range), ("10.0", Some((0.0, 10.0, 100.0))))
  // Screen-reader actions
  t.act(TextField, Increment, label="数量")
  t.act(TextField, Decrement, label="数量")
  // Keyboard stepping
  t.act(TextField, Focus, label="数量")
  t.key(@ui.key_code_up)
  t.key(@ui.key_code_page_up)
  t.key(@ui.key_code_down)
  t.key(@ui.key_code_page_down)
  t.key(@ui.key_code_end)
  t.key(@ui.key_code_home)
  assert_eq(told, [12.0, 10.0, 12.0, 22.0, 20.0, 10.0, 100.0, 0.0])
  // commit_text: valid with rounding & clamping, invalid rolls back
  assert_true(ni.commit_text(" 37.46 "))
  assert_eq((val.get(), ni.formatted()), (37.5, "37.5"))
  assert_true(ni.commit_text("999"))
  assert_eq((val.get(), ni.formatted()), (100.0, "100.0"))
  assert_true(!ni.commit_text("abc"))
  assert_eq(val.get(), 100.0)
}

///|
///|
let ni_repeat_delay_ms : Double = 400.0

///|
let ni_repeat_interval_ms : Double = 70.0

///|
test "NumberInput: increment_button and decrement_button click and repeat_hold auto-repeat" {
  let val = @signals.signal(5.0, same=fn(a : Double, b : Double) { a == b })
  let ni = @headless.NumberInput::new(
    fn() { val.get() },
    fn(v) { val.set(v) },
    min=0.0,
    max=20.0,
    step=1.0,
  )
  let t = window(fn(root) {
    ni.increment_button(root, fn() { "增加" }, delay_ms=ni_repeat_delay_ms, interval_ms=ni_repeat_interval_ms, fn(v, _) {
      v.width(Is(Some(60.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
    })
    |> ignore
    ni.decrement_button(root, fn() { "减少" }, delay_ms=ni_repeat_delay_ms, interval_ms=ni_repeat_interval_ms, fn(v, _) {
      v.width(Is(Some(60.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
    })
    |> ignore
  })
  // Quick click increments once
  t.click(Button, label="增加")
  let after_click = val.get()
  // Hold increment button for delay + 3 * interval -> 4 repeats, release does not double-step
  let (ix, iy, iw, ih) = t.get(Button, label="增加").rect
  let (icx, icy) = (ix + iw / 2.0, iy + ih / 2.0)
  t.press_at(icx, icy)
  t.run_for(ni_repeat_delay_ms + ni_repeat_interval_ms * 3.0)
  t.release(icx, icy)
  let after_hold = val.get()
  // Quick click decrement steps down once
  t.click(Button, label="减少")
  let after_dec = val.get()
  assert_eq((after_click, after_hold, after_dec), (6.0, 10.0, 9.0))
}
