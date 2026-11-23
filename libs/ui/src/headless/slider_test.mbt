// The headless slider (@headless.slider), under a look of the tests' own: read out a slider with its range and value,
// stepped by Increment/Decrement, arrow/Page Up/Page Down/Home/End keys and dragging along its track; disabled, none
// of these. Each window is made by `window` (window_test.mbt), which holds that the slider's own file draws and lays
// out nothing.

///|
test "a slider is read out with its range and stepped by a screen reader, keys, and drag" {
  let val = @signals.signal(50.0, same=fn(a : Double, b : Double) { a == b })
  let told : Array[Double] = []
  let state : Ref[@headless.Slider?] = Ref(None)
  let t = window(fn(root) {
    @headless.slider(
      root,
      fn() { "音量" },
      fn() { val.get() },
      min=0.0,
      max=100.0,
      step=5.0,
      thumb_room=20.0,
      fn(next) {
        told.push(next)
        val.set(next)
      },
      fn(v, s) {
        state.val = Some(s)
        v.width(Is(Some(220.0))).height(Is(Some(30.0))).ground(Is(c_rest)) |> ignore
      },
    )
    |> ignore
  })
  let s0 = t.get(Slider, label="音量")
  assert_eq((s0.value, s0.range, state.val.unwrap().part()), ("50", Some((0.0, 50.0, 100.0)), 0.5))
  t.act(Slider, Increment, label="音量")
  t.act(Slider, Focus, label="音量")
  t.key(@ui.key_code_right)
  t.key(@ui.key_code_page_down)
  t.key(@ui.key_code_page_up)
  t.key(@ui.key_code_home)
  t.key(@ui.key_code_end)
  // Drag to middle of 220 wide slider (x=110 -> part=0.5 -> 50)
  t.press_at(110.0, 15.0)
  t.release(110.0, 15.0)
  assert_eq(told, [55.0, 60.0, 10.0, 60.0, 0.0, 100.0, 50.0])
}

///|
test "a vertical slider runs up its height: a press near its foot is near min, near its top near max" {
  let val = @signals.signal(50.0, same=fn(a : Double, b : Double) { a == b })
  let told : Array[Double] = []
  let t = window(fn(root) {
    @headless.slider(
      root,
      fn() { "音量" },
      fn() { val.get() },
      min=0.0,
      max=100.0,
      step=10.0,
      thumb_room=20.0,
      vertical=true,
      fn(next) {
        told.push(next)
        val.set(next)
      },
      fn(v, _) { v.width(Is(Some(30.0))).height(Is(Some(220.0))).ground(Is(c_rest)) |> ignore },
    )
    |> ignore
  })
  let (x, y, _, h) = t.get(Slider, label="音量").rect
  // 30 over its foot: 20 along the 200 past its thumb room, 10; 30 under its top: 90
  t.press_at(x + 15.0, y + h - 30.0)
  t.release(x + 15.0, y + h - 30.0)
  t.press_at(x + 15.0, y + 30.0)
  t.release(x + 15.0, y + 30.0)
  assert_eq(told, [10.0, 90.0])
}

///|
test "slider_snap holds a value between its ends, on the nearest step from min" {
  assert_eq(@headless.slider_snap(-5.0, 0.0, 100.0, 10.0), 0.0)
  assert_eq(@headless.slider_snap(104.0, 0.0, 100.0, 10.0), 100.0)
  assert_eq(@headless.slider_snap(14.0, 0.0, 100.0, 10.0), 10.0)
  assert_eq(@headless.slider_snap(98.0, 3.0, 100.0, 10.0), 100.0)
  assert_eq(@headless.slider_snap(12.5, 0.0, 100.0, 0.0), 12.5)
}

///|
test "an RTL horizontal slider flips ←/→ stepping and horizontal drag mapping" {
  let val = @signals.signal(50.0, same=fn(a : Double, b : Double) { a == b })
  let told : Array[Double] = []
  let t = window(fn(root) {
    @headless.slider(
      root,
      fn() { "进度" },
      fn() { val.get() },
      min=0.0,
      max=100.0,
      step=10.0,
      thumb_room=20.0,
      rtl=true,
      fn(next) {
        told.push(next)
        val.set(next)
      },
      fn(v, _) { v.width(Is(Some(220.0))).height(Is(Some(30.0))).ground(Is(c_rest)) |> ignore },
    )
    |> ignore
  })
  t.act(Slider, Focus, label="进度")
  // Left increments (+10 -> 60), Right decrements (-10 -> 50)
  t.key(@ui.key_code_left)
  t.key(@ui.key_code_right)
  // Press near left edge (x=30 -> raw=0.1 -> rtl=0.9 -> 90), near right edge (x=190 -> raw=0.9 -> rtl=0.1 -> 10)
  t.press_at(30.0, 15.0)
  t.release(30.0, 15.0)
  t.press_at(190.0, 15.0)
  t.release(190.0, 15.0)
  assert_eq(told, [60.0, 50.0, 90.0, 10.0])
}
