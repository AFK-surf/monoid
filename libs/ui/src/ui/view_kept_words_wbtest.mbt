// A node of words kept as drawn while nothing of it changes, alone or alone in what holds it (view_ride.mbt's
// ride_holder): a message's paragraphs, what holds them gone through as another node's text updates repeatedly, each
// drawn again as kept, its glyphs not set and drawn again; what is drawn so is what drawing all of it anew draws.

///|
/// A window 240 by 400: a column of a line its words by `changing`, under it six paragraphs that do not change, the
/// first three nodes of words alone, the last three each a box holding one node of words and nothing else.
fn kept_words_tester(changing : @signals.Signal[String]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=240.0, h=400.0, scale=2.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(240.0))).height(Is(Some(400.0))) |> ignore
      o.box(fn(s) {
        s.offset(Is((10.0, 10.0))).words(By(fn() { changing.get() }), ink=0x222222FFL) |> ignore
      })
      |> ignore
      for i in 0..<6 {
        let y = 40.0 + 30.0 * i.to_double()
        let words : @view.Live[String] = Is("paragraph \{i}, its words as they were")
        if i < 3 {
          o.box(fn(p) { p.offset(Is((10.0, y))).words(words, ink=0x222222FFL) |> ignore }) |> ignore
        } else {
          o.box(fn(p) {
            p.offset(Is((10.0, y))) |> ignore
            p.box(fn(w) { w.words(words, ink=0x222222FFL) |> ignore }) |> ignore
          })
          |> ignore
        }
      }
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a paragraph's words, alone or alone in what holds it, drawn again as kept as another updates repeatedly, as drawn anew" {
  let changing = @signals.signal("a")
  let t = kept_words_tester(changing)
  let again = []
  for i in 1..=5 {
    let drawn = ride_drawn.val
    changing.set("a" + String::make(i, 'b'))
    t.draw()
    again.push(ride_drawn.val - drawn)
  }
  let kept = t.drawn_text()
  assert_eq(kept, kept_words_tester(changing).drawn_text(), msg="what changed")
  // (gone through twice running unchanged, then each of the six drawn again as kept on every update)
  assert_true(again[3] >= 6 && again[4] >= 6, msg="the six paragraphs drawn again as kept: \{Repr(again)}")
}
