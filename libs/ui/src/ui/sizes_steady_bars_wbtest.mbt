// Sizes steady (sizes_steady.mbt) takes the frame the system's bars round the window are said otherwise as the window's
// step, as the frame it is made another size: what is laid out by the room they leave it goes there at once, no motion of
// anything in it. A step in any other frame is judged as ever.

///|
/// A box 80 tall on a ground of its own (what sizes steady measures draws its own), as far down as the bars' top and
/// `extra` say. Sizes steady said but not held (its faults read here).
fn bars_case(extra : @signals.Signal[Double]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, words_over_held=false)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b
      .margin(By(fn() { (0.0, system_bars().top + extra.get(), 0.0, 0.0) }))
      .width(Is(Some(200.0)))
      .height(Is(Some(80.0)))
      .ground(Is(0x336699FFL))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "sizes steady: what the system's bars said otherwise move steps in that frame, none; a step in a frame they say nothing, one" {
  let extra = @signals.signal(0.0, same=fn(a, b) { a == b })
  let t = bars_case(extra)
  laid_frames(t, 4) |> ignore
  system_took("{\"bars\":{\"top\":59,\"bottom\":0,\"left\":0,\"right\":0}}")
  let at_bars = laid_frames(t, 4)
  extra.set(60.0)
  let unsaid = laid_frames(t, 4)
  system_took("{\"bars\":{\"top\":0,\"bottom\":0,\"left\":0,\"right\":0}}")
  assert_eq(at_bars, [])
  assert_true(unsaid.length() > 0, msg="a step with the bars as they were: none found")
}
