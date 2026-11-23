// A frame a Tester draws is held to `layout_passes_most` passes of the window's tree's layout, with no count of the
// test's own (tester_passes.mbt): where it ran more (here sixteen changes told one by one, each laid out as it was told
// whole, as #6525's answers each settled as a change of its own), what the frame drew is said, with what ran each pass
// and where what ran it was made; told together, one pass.

///|
/// A window's tree of a box whose width `w` binds, laid out and placed as each change is told whole
/// (View::laid_before_causes).
fn passes_tester(w : @signals.Signal[Double]) -> Tester {
  Tester::new(fn(_c) {  }, tree=fn(root) {
    root.box(fn(b) {
      b.height(Is(Some(40.0))).width(By(fn() { Some(w.get()) })) |> ignore
      b.laid_before_causes()
    })
    |> ignore
  })
}

///|
test "a moment whose window's tree was laid out over and over: said, how many times and what ran each, where it was made" {
  let w = @signals.signal(100.0)
  let t = passes_tester(w)
  t.frame()
  assert_eq(t.passes_said(), None)
  for i in 0..<16 {
    w.set(101.0 + i.to_double())
  }
  match t.passes_said() {
    Some(said) => {
      assert_true(said.contains("laid out 16 times as of the moment"), msg=said)
      assert_true(said.contains("at most 12"), msg=said)
      assert_true(said.contains("16× settled"), msg=said)
      assert_true(said.contains("bound ui/src/ui/tester_passes_wbtest.mbt:"), msg=said)
    }
    None => fail("sixteen passes at a moment, none said")
  }
}

///|
test "the same sixteen changes told together, or each an event of its own: none said" {
  let w = @signals.signal(100.0)
  let t = passes_tester(w)
  t.frame()
  @signals.start_batch()
  for i in 0..<16 {
    w.set(101.0 + i.to_double())
  }
  @signals.end_batch()
  t.frame()
  // (each an event: a cause of its own between frames, held apart, each to its own passes)
  for i in 0..<16 {
    view_event(fn() { w.set(201.0 + i.to_double()) })
  }
  assert_eq(t.passes_said(), None)
  t.frame()
}
