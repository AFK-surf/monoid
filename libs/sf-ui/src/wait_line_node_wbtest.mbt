// A wait as nodes (wait_line_node) laid out as wait_line's once its moment has come: its words where the old one's are
// (after its spinner and the gap), as wide and as high (the Ui size, L5's line), at the system's size of words as it is
// and made larger.

///|
/// Where the words of a wait are drawn a moment and a half on (x, y, w, h), at the system's size of words `fs`.
fn wait_words_at(fs : Double) -> Array[(Double, Double, Double, Double)] {
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=200.0, platform=0)
  @ui.set_view_app(fn(root) { wait_line_node(root, fn() { "正在打开" }) |> ignore })
  t.set_font_scale(fs)
  t.draw()
  t.run_for(later_ms * 1.5)
  t.words().filter(fn(w) { w.0 == "正在打开" }).map(fn(w) { (w.1, w.2, w.3, w.4) })
}

///|
test "a wait as nodes, its moment come: its words drawn after spinner and gap, scaling at 1 and 2" {
  let at1 = wait_words_at(1.0)
  let at2 = wait_words_at(2.0)
  assert_eq(at1.length(), 1, msg="at 1.0: \{Repr(at1)}")
  assert_eq(at2.length(), 1, msg="at 2.0: \{Repr(at2)}")
  assert_true(at1[0].0 > 14.0 && at1[0].2 > 0.0 && at1[0].3 > 0.0)
  assert_true(at2[0].2 > at1[0].2 && at2[0].3 > at1[0].3)
}
