// A node of the window's tree's words on one line cut short where even their ellipsis has not the room in its box
// (View::ellipsis_past): cut to its box by default; said so, the ellipsis drawn past it, as an old view's `w=Cut` words
// are; what holds it that clips cutting it either way; how it is drawn only, the same node told otherwise drawn so again.

///|
/// Words 4 wide in a row (`clip`: in a box 10 wide that clips them), their ellipsis drawn past them as `past` says:
/// the window's tree.
fn past_words(past : @signals.Signal[Bool], clip : Bool) -> (Tester, @view.View?) {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  let words : Ref[@view.View?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(r) {
      r.row(Is(true)).width(Is(Some(if clip { 10.0 } else { 300.0 }))).clips(Is(clip)) |> ignore
      r.box(fn(v) {
        v
        .width(Is(Some(4.0)))
        .words(Is("abcdef"), look={ size: 13.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
        .ellipsis_past(By(fn() { past.get() }))
        |> ignore
        words.val = Some(v)
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  (t, words.val)
}

///|
/// Each glyph drawn: where it is (x, y, w, h) and how far right it is cut to.
fn glyphs_cut(t : Tester) -> Array[(Double, Double, Double, Double, Double)] {
  t.drawn_instances().filter(fn(a) { a[5] == 1.0 }).map(fn(a) { (a[0], a[1], a[2], a[3], a[18]) })
}

///|
test "words whose ellipsis has not the room in their box: cut to it; said to, drawn past it, nothing else of them changed; told otherwise, cut again" {
  let past = @signals.signal(false, same=fn(a, b) { a == b })
  let (t, words) = past_words(past, false)
  let v = words.unwrap()
  let cut = glyphs_cut(t)
  let (rect, said) = (v.rect(), t.words())
  past.set(true)
  t.draw()
  let drawn_past = glyphs_cut(t)
  past.set(false)
  t.draw()
  let again = glyphs_cut(t)
  assert_true(cut.length() > 0, msg="the ellipsis drawn")
  // (the same glyphs where they were, cut to the box's right, 4; past it, cut nowhere nearer than the window)
  assert_eq(drawn_past.map(fn(g) { (g.0, g.1, g.2, g.3) }), cut.map(fn(g) { (g.0, g.1, g.2, g.3) }))
  assert_true(cut.iter().all(fn(g) { g.4 <= 4.0 + 0.01 }), msg="cut to its box: \{Repr(cut)}")
  assert_true(drawn_past.iter().all(fn(g) { g.4 > 4.0 + 1.0 && g.0 + g.2 <= g.4 }), msg="drawn past it: \{Repr(drawn_past)}")
  assert_eq(again, cut, msg="told otherwise, cut again")
  // (laid out and read as ever)
  assert_eq(v.rect(), rect)
  assert_eq(t.words(), said)
}

///|
test "words drawn past their box where their ellipsis has not the room, in a box that clips them: cut by that box still" {
  let past = @signals.signal(true, same=fn(a, b) { a == b })
  let (t, _) = past_words(past, true)
  let g = glyphs_cut(t)
  assert_true(g.length() > 0 && g.iter().all(fn(x) { x.4 <= 10.0 + 0.01 }), msg="cut by what holds it: \{Repr(g)}")
  past.set(false)
  t.draw()
  assert_true(glyphs_cut(t).iter().all(fn(x) { x.4 <= 4.0 + 0.01 }), msg="and to its own box, said not to")
}

///|
/// Words cut short (`words_w` wide, their own box `words_h` tall) in a box that clips them, `r` round, `pad` inside it
/// (left, top, right, bottom), at (20, 20) of the window: the window's tree drawn.
fn cut_in_round(pad : (Double, Double, Double, Double), card_w : Double, words_w : Double, r : Double) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  set_view_app(fn(root) {
    root.padding(Is((20.0, 20.0, 0.0, 0.0))) |> ignore
    root.box(fn(card) {
      card.row(Is(true)).width(Is(Some(card_w))).padding(Is(pad)).radius(Is(r)).clips(Is(true)) |> ignore
      card.box(fn(v) {
        v
        .width(Is(Some(words_w)))
        .words(Is("#8075 abcdefghijklmnop"), look={ size: 13.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// Each glyph drawn: its clip (16-19), its clip's corners (24-27), its outer's rect (40-43) and corners (44-47).
fn glyph_clips(t : Tester) -> Array[Array[Double]] {
  t.drawn_instances().filter(fn(a) { a[5] == 1.0 }).map(fn(a) { a[16:20].to_owned() + a[24:28].to_owned() + a[40:48].to_owned() })
}

///|
test "words cut short in a round box that clips them: cut to their own box square, never the box's corners set on theirs" {
  // (the box 18 round, its words 10 in from its left and 8 down: their corners well inside its curves; 4 wide, their
  // ellipsis has not the room: cut to their box)
  let t = cut_in_round((10.0, 8.0, 10.0, 8.0), 200.0, 4.0, 18.0)
  let g = glyph_clips(t)
  assert_true(g.length() > 0, msg="the words drawn")
  for c in g {
    // (cut to their own box: 30..34 across, 28..46 down)
    assert_eq(c[0:4].to_owned(), [30.0, 28.0, 34.0, 46.0], msg="cut to their box: \{Repr(c)}")
    assert_eq(c[4:8].to_owned(), [0.0, 0.0, 0.0, 0.0], msg="square, not the box's 18 on an 18 tall line: \{Repr(c)}")
  }
}

///|
test "words cut short at a round box's corners: round where a corner is the box's; near its curve, cut by it as their outer" {
  // (their box the round box's own, 4 by 18: each corner its corner, as round as it has room for, 2)
  let t = cut_in_round((0.0, 0.0, 0.0, 0.0), 4.0, 4.0, 9.0)
  let g = glyph_clips(t)
  assert_true(g.length() > 0, msg="the words drawn")
  for c in g {
    assert_eq(c[0:4].to_owned(), [20.0, 20.0, 24.0, 38.0], msg="\{Repr(c)}")
    assert_eq(c[4:8].to_owned(), [2.0, 2.0, 2.0, 2.0], msg="the box's corners, theirs: \{Repr(c)}")
  }
  // (half a point in from the left, top and bottom of a box 9 round: their left corners square, past its curves, which
  // cut them as their outer)
  let t = cut_in_round((0.5, 0.5, 0.0, 0.5), 200.0, 4.0, 9.0)
  let g = glyph_clips(t)
  assert_true(g.length() > 0, msg="the words drawn")
  for c in g {
    assert_eq(c[0:4].to_owned(), [20.5, 20.5, 24.5, 38.5], msg="\{Repr(c)}")
    assert_eq(c[4:8].to_owned(), [0.0, 0.0, 0.0, 0.0], msg="their own corners square: \{Repr(c)}")
    assert_eq(c[8:12].to_owned(), [20.0, 20.0, 220.0, 39.0], msg="the round box their outer: \{Repr(c)}")
    assert_eq(c[12:16].to_owned(), [9.0, 9.0, 9.0, 9.0], msg="its curves kept: \{Repr(c)}")
  }
}

///|
/// Where `text`'s cluster `mark` ends in `tl`, and the room to cut it there with an ellipsis after it.
fn cut_after(tl : TextLayout, mark : Int, dots : Double) -> Double {
  tl.xs[mark] + tl.shaped.adv[mark] + dots
}

///|
test "words cut after a full-width mark set closer before the next one (\"），\"): with the ellipsis after it, still within the width" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.words_spaced_here()
  let s = "#8075 已合进 main（9bfb4f6f4b），CI 30 项通过"
  let lay = fn(s : String, keep_tabular : Bool) { layout_text(s, 16.0, 400, 1.0e9, false, line=18.0, keep_tabular~) }
  let full = lay(s, false)
  let mark = s.find("），").unwrap()
  let dots = lay("…", false).w
  // ("）" a half em narrower before "，" than before the ellipsis: as measured in the whole, the room for it and the dots)
  assert_eq(full.shaped.adv[mark], 8.0)
  let w = cut_after(full, mark, dots)
  let cut = ellipsized(s, full, w, lay)
  assert_true(cut.text.has_suffix("…"), msg=cut.text)
  assert_true(cut.w <= w + 0.5, msg="\{cut.text} \{cut.w} in \{w}")
  // (cut before the mark it could not keep, nothing more)
  assert_eq(cut.text, "#8075 已合进 main（9bfb4f6f4b…")
  // wrapped, cut after its first line: on that line still, within the width
  let lay_w = fn(s : String, w : Double, wrap : Bool, keep_tabular : Bool) {
    layout_text(s, 16.0, 400, w, wrap, line=18.0, keep_tabular~)
  }
  let wrapped = lay_w(s, w, true, false)
  assert_true(wrapped.line_start.length() > 1)
  let lines = lines_cut(s, wrapped, w, 1, lay_w)
  assert_true(lines.text.has_suffix("…"), msg=lines.text)
  assert_eq(lines.line_start.length(), 1, msg="\{lines.text}: one line")
  assert_true(lines.line_w[0] <= w + 0.5, msg="\{lines.text} \{lines.line_w[0]} in \{w}")
  // in pieces, on one line and wrapped: the same
  let runs = [plain("#8075 已合进 main"), bold("（9bfb4f6f4b），CI 30 项通过")]
  let one : Rich = { ..kept_rich(runs), size: 16.0, wrap: false, max_lines: 1 }
  let whole = layout_rich(one, 1.0e9)
  let mark_r = whole.text.find("），").unwrap()
  let dots_r = shape("…", 16.0, 600).adv.fold(init=0.0, fn(s, x) { s + x })
  let w_r = whole.xs[mark_r] + whole.adv[mark_r] + dots_r
  let cut_r = layout_rich(cut_rich(one, whole, w_r), 1.0e9)
  assert_true(cut_r.w <= w_r + 0.5, msg="\{cut_r.text} \{cut_r.w} in \{w_r}")
  let par : Rich = { ..kept_rich(runs), size: 16.0, max_lines: 1 }
  let laid = layout_rich(par, w_r)
  assert_true(laid.line_start.length() > 1)
  let cut_p = layout_rich(cut_rich(par, laid, w_r), w_r)
  assert_eq(cut_p.line_start.length(), 1, msg="\{cut_p.text}: one line")
  assert_true(cut_p.line_w[0] <= w_r + 0.5, msg="\{cut_p.text} \{cut_p.line_w[0]} in \{w_r}")
}
