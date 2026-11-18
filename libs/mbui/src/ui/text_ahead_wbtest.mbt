// What a frame hands its host to draw ahead (glyphs_ahead) as its tree is laid out: each glyph at the phase it is then
// painted at (laid_ahead), not phase 0 alone.

///|
/// A page of words as a chat's are laid out: plain words and runs of several styles, Han and Latin, wrapped, each in a
/// column at a whole number of points from the window's edge; at a size whose Han is no whole number of pixels wide at
/// any scale the test draws at, as most sizes are.
fn ahead_page(root : @view.View) -> Unit {
  root.box(fn(p) {
    p.width(Is(Some(360.0))).padding(Is((16.0, 16.0, 16.0, 16.0))) |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words(
        Is("今天把渲染的预热改成排版之后立即派发，Latin words between them, 再看一下首帧。"),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
    p.box(fn(v) {
      v
      .width(Is(Some(328.0)))
      .words_runs(
        Is([
          @view.words_run("富文本里的"),
          @view.words_run("粗体段落", weight=700),
          @view.words_run(" and a code-ish run ", weight=500),
          @view.words_run("然后又回到正文，一直写到第二行以后才结束。"),
        ]),
        look={ ..@view.words_plain, size: 15.3, line: 22.0, wrap: true },
      )
      |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// The glyphs the frame placed (their keys with their phase), and how many of them were asked ahead at that phase, and
/// how many at phase 0.
fn ahead_hits(asked : Array[Int]) -> (Int, Int, Int) {
  let at : Map[Int, Bool] = Map([])
  for k in asked {
    at[k] = true
  }
  let mut placed = 0
  let mut hit = 0
  let mut first = 0
  for k, _ in text_cache.glyphs {
    placed = placed + 1
    if at.contains(k) {
      hit = hit + 1
    }
    if (k >> 26) == 0 {
      first = first + 1
    }
  }
  (placed, hit, first)
}

///|
test "glyphs laid out are asked ahead at the phase the frame paints them at" {
  for sc in [2.75, 3.0, 2.0] {
    let asked : Array[Int] = []
    fake_ahead.val = Some(asked)
    let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, scale=sc)
    // (Latin letters of widths of a real face's, none a whole number of pixels)
    t.latin_advances(
      FixedArray::makei(95, fn(i) { 0.45 + (i % 7).to_double() * 0.037 }),
      FixedArray::makei(95, fn(i) { 0.48 + (i % 5).to_double() * 0.041 }),
    )
    set_view_app(ahead_page)
    t.draw()
    fake_ahead.val = None
    let (placed, hit, first) = ahead_hits(asked)
    assert_true(placed > 60, msg="scale \{sc}: \{placed} placed")
    // (every glyph the frame painted was asked ahead at its own phase, before it was painted: the frame's first ask
    // is its tree's layout's)
    assert_eq(hit, placed, msg="scale \{sc}: \{hit} of \{placed} asked at their phase")
    // (where phase 0 alone was asked, most would have been drawn on the frame's thread)
    assert_true(first * 2 < placed, msg="scale \{sc}: \{first} of \{placed} at phase 0")
    // (each asked once)
    let seen : Map[Int, Bool] = Map([])
    for k in asked {
      assert_true(!seen.contains(k), msg="scale \{sc}: \{k} asked twice")
      seen[k] = true
    }
  }
}

///|
test "a glyph shaped and not laid out is asked at phase 0, once; one laid out is not asked again at phase 0" {
  let asked : Array[Int] = []
  fake_ahead.val = Some(asked)
  let _t = Tester::new(fn(_c) {  }, w=200.0, h=100.0, scale=2.75)
  // shaped alone: its glyphs at phase 0
  let s = shape("只量不排", 15.0, 400)
  glyphs_ahead()
  assert_eq(asked, s.keys.filter(fn(k) { k >= 0 }))
  // laid out: at the phases of its line, none of them again at phase 0 for having been shaped
  asked.clear()
  let tl = layout_text("排版之后 laid", 15.0, 400, 300.0, false)
  glyphs_ahead()
  fake_ahead.val = None
  let want = []
  for c, k in tl.shaped.keys {
    if k >= 0 {
      want.push(glyph_sub_at(k, tl.xs[c] + tl.shaped.pad, g().scale, 1.0))
    }
  }
  let seen : Map[Int, Bool] = Map([])
  let want = want.filter(fn(k) {
    let first = !seen.contains(k)
    seen[k] = true
    first
  })
  assert_eq(asked, want)
  assert_true(asked.iter().any(fn(k) { (k >> 26) != 0 }))
}
