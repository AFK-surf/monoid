// A card going on to another column of the wide board (sfpages' board_node: View::shared, the board's area said
// View::flights_within) is drawn within the board all its way: never over its bar or past the window's edge round it.

///|
/// What each glyph of words `w` drawn now left of `left_of` is cut to (x0, y0, x1, y1).
fn board_glyph_cuts(t : @ui.Tester, w : String, left_of? : Double = 1.0e9) -> Array[(Double, Double, Double, Double)] {
  let out : Array[(Double, Double, Double, Double)] = []
  let glyphs = t.glyph_clips()
  for x in t.words() {
    guard x.0 == w && x.1 < left_of else { continue }
    for g in glyphs {
      if g.0.0 >= x.1 - 1.0 && g.0.0 <= x.1 + x.3 && g.0.1 >= x.2 - 2.0 && g.0.1 <= x.2 + x.4 {
        out.push(g.1)
      }
    }
  }
  out
}

///|
test "大屏: the new draft's glass has room for its outer contour on both sides" {
  for w in [1000.0, 1440.0] {
    let (t, _) = board_at("board", w, 900.0)
    t.click(Button, label="新待办")
    t.run_for(@ui.move_most_ms)
    guard t.query(TextField, label="要做什么？") is Some(field) else { fail("no draft field") }
    let (fx, fy, fw, fh) = field.rect
    let (mx, my) = (fx + fw / 2.0, fy + fh / 2.0)
    let glass = t.drawn_cut().filter(fn(g) {
      g.0 == 6 && mx >= g.1 && mx < g.1 + g.3 && my >= g.2 && my < g.2 + g.4
    })
    guard glass.length() == 1 else { fail("\{w}: expected the draft's glass, got \{Repr(glass)}") }
    let (_, x, _, width, _, (left, _, right, _)) = glass[0]
    assert_true(left <= x - 0.75 && right >= x + width + 0.75, msg="\{w}: glass \{x}..\{x + width}, clip \{left}..\{right}")
    assert_eq(board_faults(t), [])
  }
}

///|
test "大屏: a draft started flies on to 进行中 drawn within the board all its way, cut under its bar and at the window's foot" {
  let (w, h) = (1440.0, 420.0)
  let (t, src) = board_at("board", w, h)
  // (进行中 scrolled down some: its new card's place under the board's bar as it is laid out)
  guard board_words_at(t, "进行中") is Some((rx, _, _, _)) else { fail("no 进行中") }
  t.wheel(rx + 40.0, 300.0, 250.0)
  t.run_for(@ui.move_most_ms)
  guard t.query(Button, label="新待办") is Some(add) else { fail("no 新待办") }
  let bar_foot = add.rect.1 + add.rect.3
  t.click(Button, label="新待办")
  t.run_for(@ui.move_most_ms)
  t.type_text("把发布说明翻成英文")
  t.enter()
  t.run_for(@ui.move_most_ms)
  guard board_words_at(t, "把发布说明翻成英文") is Some((x, y, _, _)) else { fail("no draft") }
  guard t.all(Button, label="开始").iter().find_first(fn(n) { n.rect.0 > x && (n.rect.1 - y).abs() < 40.0 }) is Some(go) else {
    fail("no 开始 on its card")
  }
  t.tap(go.rect.0 + go.rect.2 / 2.0, go.rect.1 + go.rect.3 / 2.0)
  // (on its way, frame by frame: each of its glyphs cut within the board, under its bar, inside the window)
  let mut seen = 0
  for _ in 0..<12 {
    t.run_for(@ui.frame_period_default * 2.0)
    for c in board_glyph_cuts(t, "把发布说明翻成英文") {
      seen += 1
      assert_true(
        c.0 >= 0.0 && c.1 >= bar_foot && c.2 <= w && c.3 <= h,
        msg="a glyph of the card on its way cut to \{c.0} \{c.1} \{c.2} \{c.3}, not within the board under its bar (\{bar_foot}) in the window \{w}×\{h}",
      )
    }
  }
  assert_true(seen > 0, msg="the card never drawn on its way")
  t.run_for(@ui.move_most_ms)
  assert_eq(board_lane_now(src, "把发布说明翻成英文"), "run")
  assert_eq(board_faults(t), [])
}

///|
test "大屏: a card whose decision is made goes on to 进行中 drawn within the board all its way, under its bar" {
  let (w, h) = (1440.0, 900.0)
  let (t, src) = board_at("board", w, h)
  guard t.query(Button, label="新待办") is Some(add) else { fail("no 新待办") }
  let bar_foot = add.rect.1 + add.rect.3
  t.click(Button, label="整理发布清单")
  t.run_for(@ui.move_most_ms)
  guard board_words_at(t, "一起换") is Some((x, y, ww, hh)) else { fail("no 一起换") }
  t.tap(x + ww / 2.0, y + hh / 2.0)
  // (its card from 等你处理 on to 进行中, one thing (View::shared): each glyph cut within the board on its way, never
  // over its bar; the chat beside the board, which names it in its own bar, left out)
  let mut seen = 0
  for _ in 0..<12 {
    t.run_for(@ui.frame_period_default * 2.0)
    for c in board_glyph_cuts(t, "整理发布清单", left_of=900.0) {
      seen += 1
      assert_true(
        c.0 >= 0.0 && c.1 >= bar_foot && c.2 <= w && c.3 <= h,
        msg="a glyph of the card on its way cut to \{c.0} \{c.1} \{c.2} \{c.3}, not within the board under its bar (\{bar_foot}) in the window \{w}×\{h}",
      )
    }
  }
  assert_true(seen > 0, msg="the card never drawn on its way")
  t.run_for(@ui.move_most_ms)
  assert_eq(board_lane_now(src, "整理发布清单"), "run")
  assert_eq(board_faults(t), [])
}
