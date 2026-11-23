// A host's text kept and given again under a Tester (textrec.mbt).

///|
test "kept text lays words out as the host shaped them; what it lacks is said" {
  let view = fn(c : @ui.Ctx) { c.box(dir=Row, fn() { c.text("ab", size=10.0) |> ignore }) |> ignore }
  // the fake host: half an em a letter
  let (_, _, w0, _) = @ui.Tester::new(view, w=200.0, h=100.0).rect_of("ab").unwrap()
  assert_eq(w0, 10.0)
  let kept =
    #|TEXTREC {"m":[10,400,0],"r":[9,3,13]}
    #|TEXTREC {"s":[10,400,0,"ab"],"r":[0,1,7.5,97,1,1,4.25,98]}
  let t = @ui.Tester::new(view, w=200.0, h=100.0, text=kept)
  let (_, _, w1, h1) = t.rect_of("ab").unwrap()
  assert_eq(w1, 11.75)
  assert_eq(h1, 13.0)
  // its glyphs' boxes were not kept: said, and drawn as the fake host would
  assert_true(t.text_missing().contains("glyph 97"))
  assert_true(t.text_missing().contains("glyph 98"))
  assert_eq(t.text_missing().filter(fn(m) { m.has_prefix("shape") }), [])
}

///|
test "a Tester after one that kept text has the fake host's own again" {
  let t = @ui.Tester::new(fn(c) { c.box(dir=Row, fn() { c.text("ab", size=10.0) |> ignore }) |> ignore }, w=200.0, h=100.0)
  let (_, _, w, _) = t.rect_of("ab").unwrap()
  assert_eq(w, 10.0)
  assert_eq(t.text_missing(), [])
}

///|
test "a draw list over a host's kept text that lacks what was drawn: said (drawlist_said), not drawn as other glyphs" {
  // (kept text with nothing in it: the words below were never shaped by the host)
  let t = @ui.Tester::new(fn(c) { c.text("never kept", wrap=false) |> ignore }, text="")
  assert_true(t.text_missing().length() > 0)
  assert_eq(
    t.drawlist_said(),
    Some(
      "Tester::drawlist: the host's kept text lacks 2 of what was drawn (record its text again): shape 15|400|0|never kept, metrics 15|400|0",
    ),
  )
}

///|
test "FakeHost fallback glyph keys for unrecorded shapes do not collide with recorded textrec glyph IDs" {
  // Recorded textrec contains glyph ID 51 (ASCII code point of '3') with a huge 27x27 box (top=-23),
  // but no recorded shape for "3".
  let kept =
    #|TEXTREC {"g":51,"r":[0,0,27,27,0,-23,0]}
  let t = @ui.Tester::new(
    fn(c) { c.text("3", size=12.0, wrap=false) |> ignore },
    w=200.0,
    h=100.0,
    text=kept,
  )
  let glyphs = t.glyphs_shown()
  assert_eq(glyphs.length(), 1)
  let (_, y, w, h) = glyphs[0]
  assert_true(w < 20.0 && h < 20.0, msg="fallback glyph collided with textrec glyph 51: w=\{w}, h=\{h}, y=\{y}")
  assert_true(y >= 0.0, msg="fallback glyph used textrec glyph 51 top=-23: y=\{y}")
}
