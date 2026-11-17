// A slider as nodes (value_slider_node): read out a slider with its value; a press along it goes there, the keys step
// it; held, its value over it in a bubble, gone as it is let go; at rest nothing of the bubble, nothing reading the clock.

///|
/// Moments the tests here look at: held long enough for its drop and bubble to be whole, past every way.
let slider_held_ms : Double = 400.0

///|
let slider_past_ms : Double = 1000.0

///|
/// A slider 300 wide at the top left of a window 390 by 300, `v` as it is, moved as it is told.
fn slider_case(v : @signals.Signal[Double], format? : (Int) -> String = fn(n) { n.to_string() }) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(b) {
      b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      b.box(fn(s) {
        s.width(Is(Some(300.0))) |> ignore
        value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, format~) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a slider as nodes: read out a slider named by its label with its value; the keys step it, End to its most" {
  let v = @signals.signal(40.0)
  let t = slider_case(v)
  let said = t.semantics().filter(fn(n) { n.role == Slider }).map(fn(n) { "\{n.label} \{n.value}" })
  t.key(@ui.key_tab)
  t.frame()
  t.key(@ui.key_code_right)
  t.frame()
  let stepped = v.get()
  t.key(@ui.key_code_end)
  t.frame()
  assert_eq((said, stepped, v.get()), (["音量 40"], 41.0, 100.0))
}

///|
test "a slider held: there where it is pressed, its value over it while held, none of it once let go and at rest" {
  let v = @signals.signal(40.0)
  let t = slider_case(v)
  let words_rest = t.words().length()
  // (pressed three quarters along: its knob's middle runs from half a knob in to as far from its end)
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let held_v = v.get()
  let bubble = t.words().filter(fn(w) { w.0 == "7" || w.0 == "5" }).length()
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((words_rest, held_v, bubble, t.words().length()), (0, 75.0, 2, 0))
}

///|
test "a slider written as it says: read out so, and so in its bubble while held" {
  let v = @signals.signal(40.0)
  let t = slider_case(v, format=fn(n) { "\{n}%" })
  let said = t.semantics().filter(fn(n) { n.role == Slider }).map(fn(n) { n.value })
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let bubble = t.words().map(fn(w) { w.0 })
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((said, bubble), (["40%"], ["7", "5", "%"]))
}

///|
test "a slider given the tips' layer: its bubble there, over the knob above the slider, whatever clips what holds it; gone as it is let go" {
  let v = @signals.signal(40.0)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(b) {
      b.padding(Is((20.0, 60.0, 20.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      b.box(fn(s) {
        // (what holds it cut to itself, its top right at the slider's: a bubble in it would be cut away)
        s.width(Is(Some(300.0))).clips(Is(true)) |> ignore
        value_slider_node(s, fn() { "音量" }, fn() { v.get() }, fn(x) { v.set(x) }, format=fn(n) { "\{n}%" }, tips~) |> ignore
      })
      |> ignore
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  let x = 20.0 + 10.0 + 0.75 * (300.0 - 20.0)
  t.press_at(x, 60.0 + 14.0)
  t.run_for(slider_held_ms)
  let bubble = t.words().filter(fn(w) { w.0 == "7" || w.0 == "5" || w.0 == "%" })
  let over_it = bubble.length() == 3 && bubble.all(fn(w) { w.2 + w.4 <= 60.0 && (w.1 - x).abs() < 30.0 })
  t.release(x, 60.0 + 14.0)
  t.run_for(slider_past_ms)
  assert_eq((v.get(), over_it, t.words().length()), (75.0, true, 0))
}
