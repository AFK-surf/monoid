// A node's words edged (View::words_edge): they drawn again in its colour as far off each of the eight ways, under
// them, by the one node; moved with it as one; none said, none drawn; read as one node's words.

///|
/// Words `text` edged as `edge` says (how far out, its colour), in black, at (`at`, 20).
fn edged_words(edge : @signals.Signal[(Double, Int64)], at : @signals.Signal[Double]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  set_view_app(fn(root) {
    root.box(fn(v) {
      v
      .over(Is(true))
      .offset(By(fn() { (at.get(), 20.0) }))
      .words(Is("Hi"), look={ ..@view.words_plain, size: 13.0, line: 18.0, wrap: false })
      .ink(Is(0x000000FFL))
      .words_edge(By(fn() { edge.get() }))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "words edged: drawn eight times in its colour, each as far off one way, under them; moved with them; none said, none" {
  let edge = @signals.signal((1.5, 0xFF0000FFL), same=fn(a, b) { a == b })
  let at = @signals.signal(20.0, same=fn(a, b) { a == b })
  let t = edged_words(edge, at)
  let gs = t.drawn_glyphs()
  let red = gs.filter(fn(g) { g.2 == 0xFF0000FFL })
  let black = gs.filter(fn(g) { g.2 == 0x000000FFL })
  // (the first glyph of each: the eight edges' round the words' own, in their order, then the words over them)
  let first_x = black[0].0
  let first_y = black[0].1
  let offs = red.filter(fn(g) { (g.0 - first_x).abs() < 2.0 && (g.1 - first_y).abs() < 2.0 }).map(fn(g) {
    ((g.0 - first_x).round(), (g.1 - first_y).round())
  })
  assert_eq(
    (black.length(), red.length(), gs.length() - black.length() == red.length(), gs[gs.length() - 1].2, offs.length()),
    (2, 16, true, 0x000000FFL, 8),
    msg="glyphs \{Repr(gs)}",
  )
  // (moved, all of it with them)
  at.set(60.0)
  t.draw()
  let moved = t.drawn_glyphs()
  assert_eq(moved.map(fn(g) { (g.0 - 40.0).round() }), gs.map(fn(g) { g.0.round() }))
  // (none said: the words alone)
  edge.set((0.0, 0xFF0000FFL))
  t.draw()
  assert_eq(t.drawn_glyphs().length(), 2)
  // (read as one node's words)
  assert_eq(t.words().filter(fn(w) { w.0 == "Hi" }).length(), 1)
}
