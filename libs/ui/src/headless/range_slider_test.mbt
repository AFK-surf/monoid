// Tests for headless RangeSlider: dual independent Role::Slider thumbs, min_gap invariant, LTR/RTL keyboard stepping,
// screen-reader Increment/Decrement, and track drag nearest-thumb selection. All windows use `window`.

///|
test "RangeSlider: two Role::Slider thumbs enforce min_gap across keys, a11y steps, and track drag" {
  let vals = @signals.signal((20.0, 80.0))
  let told : Array[(Double, Double)] = []
  let rs_ref : Ref[@headless.RangeSlider?] = Ref(None)
  let t = window(fn(root) {
    @headless.range_slider(
      root,
      fn() { "价格区间" },
      fn() { vals.get() },
      min=0.0,
      max=100.0,
      step=5.0,
      min_gap=10.0,
      fn(lo, hi) {
        told.push((lo, hi))
        vals.set((lo, hi))
      },
      fn(v, rs) {
        rs_ref.val = Some(rs)
        v.width(Is(Some(200.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
        rs.thumb(v, Low, fn() { "最低价" }, fn(tv, _) {
          tv.width(Is(Some(16.0))).height(Is(Some(16.0))) |> ignore
        })
        |> ignore
        rs.thumb(v, High, fn() { "最高价" }, fn(tv, _) {
          tv.width(Is(Some(16.0))).height(Is(Some(16.0))) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
  })
  let low0 = t.get(Slider, label="最低价")
  let high0 = t.get(Slider, label="最高价")
  assert_eq((low0.value, low0.range), ("20", Some((0.0, 20.0, 70.0))))
  assert_eq((high0.value, high0.range), ("80", Some((30.0, 80.0, 100.0))))
  // Step Low with a11y Increment and End (clamped to high - min_gap = 70)
  t.act(Slider, Increment, label="最低价")
  t.act(Slider, Focus, label="最低价")
  t.key(@ui.key_code_end)
  // Step High with Home (clamped to low + min_gap = 80) and PageUp (+50 -> 100)
  t.act(Slider, Focus, label="最高价")
  t.key(@ui.key_code_home)
  t.key(@ui.key_code_page_up)
  // Track drag near x=30 (value=15) picks Low thumb (closer to 70 than High=100)
  t.press_at(30.0, 24.0)
  t.release(30.0, 24.0)
  // Track drag near x=180 (value=90) picks High thumb
  t.press_at(180.0, 24.0)
  t.release(180.0, 24.0)
  assert_eq(told, [(25.0, 80.0), (70.0, 80.0), (70.0, 100.0), (15.0, 100.0), (15.0, 90.0)])
  let rs = rs_ref.val.unwrap()
  assert_eq((rs.low_part(), rs.high_part()), (0.15, 0.9))
}

///|
test "RangeSlider: RTL flips horizontal arrow keys and track drag direction" {
  let vals = @signals.signal((30.0, 70.0))
  let t = window(fn(root) {
    @headless.range_slider(
      root,
      fn() { "区间" },
      fn() { vals.get() },
      min=0.0,
      max=100.0,
      step=10.0,
      rtl=true,
      fn(lo, hi) { vals.set((lo, hi)) },
      fn(v, rs) {
        v.width(Is(Some(200.0))).height(Is(Some(32.0))).ground(Is(c_rest)) |> ignore
        rs.thumb(v, Low, fn() { "低" }, fn(tv, _) {
          tv.width(Is(Some(16.0))).height(Is(Some(16.0))) |> ignore
        })
        |> ignore
        rs.thumb(v, High, fn() { "高" }, fn(tv, _) {
          tv.width(Is(Some(16.0))).height(Is(Some(16.0))) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
  })
  t.act(Slider, Focus, label="低")
  // In RTL, Left increments Low (30 -> 40), Right decrements (40 -> 30)
  t.key(@ui.key_code_left)
  let after_left = vals.get()
  t.key(@ui.key_code_right)
  let after_right = vals.get()
  // Track press near left edge (x=20 -> raw=0.1 -> rtl=0.9 -> 90) moves High
  t.press_at(20.0, 24.0)
  t.release(20.0, 24.0)
  assert_eq((after_left, after_right, vals.get()), ((40.0, 70.0), (30.0, 70.0), (30.0, 90.0)))
}
