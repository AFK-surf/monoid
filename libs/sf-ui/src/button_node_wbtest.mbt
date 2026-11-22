// The library's button as a node of the window's tree (button_node): at rest, its
// words its content's width or as wide as a column (its own height kept); at work, its spinner's room opening and the
// spinner turning, then closing; its words changed, going to their place; nothing turning at rest, before or after.

///|
/// What a button draws: its ground's rects (x, y, w, h) and its glyphs' places.
fn button_drawn(t : @ui.Tester) -> (Array[(Double, Double, Double, Double)], Array[(Double, Double)]) {
  (t.drawn_rects().map(fn(r) { (r.0, r.1, r.2, r.3) }), t.drawn_glyphs().map(fn(g) { (g.0, g.1) }))
}

///|
/// A button in a column 300 wide and 200 tall at the window's top left, its words `words`, `tone`, at work as `busy`
/// says, as wide as the column where `across`. The Tester.
fn button_case(
  words : @signals.Signal[String],
  busy : @signals.Signal[Bool],
  tone? : Tone = Plain,
  across? : Bool = false,
  there? : @signals.Signal[Bool] = @signals.signal(true),
  start? : Bool = true,
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(200.0))).lines_up(Is(if start { Some(Start) } else { None })) |> ignore
      col.show(at_once=true, fn() { there.get() }, fn(at) {
        // (what it is shown in as wide as the column and lining it up as the column does: the button laid out as
        // in the column itself)
        at.width_share(Is(1.0)).lines_up(Is(if start { Some(Start) } else { None })) |> ignore
        button_node(at, fn() { words.get() }, fn() {  }, tone~, busy=fn() { busy.get() }, across~) |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "the button as a node at rest, its words its width or as wide as a column, plain or the one thing to do: its height its own" {
  // (its tone, whether as wide as a column, whether at the column's start or stretched across it)
  let cases : Array[(Tone, Bool, Bool)] = [
    (Plain, false, true),
    (Primary, false, true),
    (Plain, true, true),
    (Primary, true, true),
    (Plain, false, false),
    (Primary, true, false),
  ]
  for k in cases {
    let (tone, across, start) = k
    let tag = "across=\{across} start=\{start}"
    let t = button_case(@signals.signal("Join"), @signals.signal(false), tone~, across~, start~)
    let (rects, glyphs) = button_drawn(t)
    assert_eq(rects.length(), 1, msg="\{tag}: \{Repr(rects)}")
    assert_eq(rects[0].3, button_height(), msg="\{tag}: height")
    if across || !start {
      assert_eq(rects[0].2, 300.0, msg="\{tag}: across width")
    } else {
      assert_true(rects[0].2 > 0.0 && rects[0].2 < 300.0, msg="\{tag}: hug width \{rects[0].2}")
    }
    assert_true(glyphs.length() >= 4, msg="\{tag}: glyphs")
  }
}

///|
test "the button as a node idle: nothing turning; at work, its spinner turning; at rest again once its room has closed, nothing turning" {
  let busy = @signals.signal(false, same=fn(a, b) { a == b })
  let t = button_case(@signals.signal("Join"), busy)
  let tree = @ui.view_tree().unwrap()
  let idle = tree.cycle_read()
  busy.set(true)
  t.frame()
  t.run_for(past_button_ms)
  let turn_a = t.drawn_instances().filter(fn(i) { i[5] == 10.0 }).map(fn(i) { i[32] })
  t.frame_at(t.time() + 100.0)
  let turn_b = t.drawn_instances().filter(fn(i) { i[5] == 10.0 }).map(fn(i) { i[32] })
  let working = tree.cycle_read()
  busy.set(false)
  t.frame()
  t.run_for(past_button_ms)
  let rested = tree.cycle_read()
  assert_eq((idle, turn_a.length() > 0, turn_a != turn_b, working, rested), (false, true, true, true, false))
}

///|
test "quiet buttons show their ground while busy, then return to words alone" {
  for tone in [Ghost, GhostDanger] {
    let busy = @signals.signal(false, same=fn(a, b) { a == b })
    let t = button_case(@signals.signal("Join"), busy, tone~)
    assert_true(t.drawn_rects().is_empty())
    busy.set(true)
    t.frame()
    t.run_for(past_button_ms)
    assert_true(t.drawn_rects().iter().any(fn(r) { r.4 == theme().p.hover }))
    assert_true(t.find("Join") is Some(_))
    assert_true(t.drawn_instances().iter().any(fn(i) { i[5] == 10.0 }))
    busy.set(false)
    t.frame()
    t.run_for(past_button_ms)
    assert_true(t.drawn_rects().is_empty())
    let already_busy = button_case(@signals.signal("Join"), @signals.signal(true), tone~)
    assert_true(already_busy.drawn_rects().iter().any(fn(r) { r.4 == theme().p.hover }))
  }
}

///|
test "the button as a node let go at work, its spinner's room opening: none of it left, drawn or turning" {
  let busy = @signals.signal(false, same=fn(a, b) { a == b })
  let there = @signals.signal(true, same=fn(a, b) { a == b })
  let t = button_case(@signals.signal("Join"), busy, there~)
  let tree = @ui.view_tree().unwrap()
  busy.set(true)
  t.frame()
  t.run_for(button_half_ms)
  let (alive, turning) = (tree.alive(), tree.cycle_read())
  there.set(false)
  t.frame()
  let pieces = t.drawn_instances().filter(fn(i) { i[5] == 10.0 }).length()
  let left = tree.alive()
  t.run_for(past_button_ms)
  assert_eq(
    (turning, tree.cycle_read(), pieces, t.drawn_rects().length(), alive > left, tree.alive() == left),
    (true, false, 0, 0, true, true),
  )
}

///|
/// Less than a button's spinner's room takes to open.
let button_half_ms : Double = 60.0

///|
/// Longer than any of a button's ways takes.
let past_button_ms : Double = 1000.0

///|
/// The pieces of lines a button draws (its spinner's: kind 10), each but how far it is turned (which the clock says,
/// spinner_node_wbtest): where and how big, its ends, its colour and opacity, the point it turns about, whether what
/// cuts it stays.
fn button_pieces(t : @ui.Tester) -> Array[Array[Double]] {
  t
  .drawn_instances()
  .filter(fn(i) { i[5] == 10.0 })
  .map(fn(i) { [i[0], i[1], i[2], i[3], i[4], i[8], i[9], i[10], i[11], i[12], i[13], i[14], i[15], i[33], i[34], i[35]] })
}

///|
/// What a button draws (its ground, its words, its spinner's pieces) on the way after each of `steps` at each of
/// `moments`: its words `words`, at work as `busy` says.
fn button_along(
  words : @signals.Signal[String],
  busy : @signals.Signal[Bool],
  steps : Array[() -> Unit],
  moments : Array[Double],
) -> Array[((Array[(Double, Double, Double, Double)], Array[(Double, Double)]), Array[Array[Double]])] {
  let t = button_case(words, busy)
  let out = [(button_drawn(t), button_pieces(t))]
  for step in steps {
    let t0 = t.time()
    step()
    t.frame_at(t0 + 16.0)
    for at in moments {
      t.frame_at(t0 + at)
      out.push((button_drawn(t), button_pieces(t)))
    }
  }
  out
}

///|
/// Moments on a button's ways: early, about half way, near the end, past all of them.
let button_moments : Array[Double] = [40.0, 100.0, 200.0, past_button_ms]

///|
test "the button as a node, its words longer and shorter again: its ground eases to each width and returns" {
  let words = @signals.signal("Join", same=fn(a, b) { a == b })
  let busy = @signals.signal(false, same=fn(a, b) { a == b })
  let frames = button_along(words, busy, [fn() { words.set("Join the chat") }, fn() { words.set("Join") }], button_moments)
  let w0 = frames[0].0.0[0].2
  let w_mid_grow = frames[2].0.0[0].2
  let w_long = frames[4].0.0[0].2
  let w_mid_shrink = frames[6].0.0[0].2
  let w_back = frames[8].0.0[0].2
  assert_true(w_long > w0 + 10.0, msg="grew: \{w0} -> \{w_long}")
  assert_true(w_mid_grow > w0 && w_mid_grow < w_long, msg="mid grow: \{w0} < \{w_mid_grow} < \{w_long}")
  assert_true(w_mid_shrink < w_long && w_mid_shrink > w0, msg="mid shrink: \{w_long} > \{w_mid_shrink} > \{w0}")
  assert_true((w_back - w0).abs() < 1.0e-6, msg="back: \{w_back} vs \{w0}")
}

///|
test "the button as a node set to work and back: its spinner's room opens and closes" {
  let words = @signals.signal("Join", same=fn(a, b) { a == b })
  let busy = @signals.signal(false, same=fn(a, b) { a == b })
  let frames = button_along(words, busy, [fn() { busy.set(true) }, fn() { busy.set(false) }], button_moments)
  // (no spinner at rest, before or after; none yet while it is under half its size, one past that and at work)
  let spun = frames.map(fn(k) { k.1.length() > 0 })
  let w_rest = frames[0].0.0[0].2
  let w_busy = frames[4].0.0[0].2
  let w_back = frames[8].0.0[0].2
  assert_eq((spun[0], spun[1], spun[2], spun[4], spun[8]), (false, false, true, true, false))
  assert_true(w_busy > w_rest + button_icon, msg="wider while busy: \{w_rest} -> \{w_busy}")
  assert_true((w_back - w_rest).abs() < 1.0e-6, msg="back to rest width: \{w_back} vs \{w_rest}")
}

///|
/// A button's ground's colours at `moments` after the pointer comes onto it, and after it goes, by `on` and `off`.
fn button_answers(
  on : (@ui.Tester, Double, Double) -> Unit,
  off : (@ui.Tester, Double, Double) -> Unit,
) -> Array[Array[Int64]] {
  let t = button_case(@signals.signal("Join"), @signals.signal(false))
  let (x, y) = {
    let r = t.drawn_rects()[0]
    (r.0 + r.2 / 2.0, r.1 + r.3 / 2.0)
  }
  let out = [t.drawn_rects().map(fn(r) { r.4 })]
  for go in [on, off] {
    let t0 = t.time()
    go(t, x, y)
    for at in button_moments {
      t.frame_at(t0 + at)
      out.push(t.drawn_rects().map(fn(r) { r.4 }))
    }
  }
  out
}

///|
test "the button as a node, the pointer come onto it and gone: its ground eases to hover and back" {
  let on = fn(t : @ui.Tester, x, y) { t.move_to(x, y) }
  let off = fn(t : @ui.Tester, _x, _y) { t.move_to(390.0, 290.0) }
  let colors = button_answers(on, off)
  assert_true(colors[0] != colors[4], msg="hovered: \{Repr(colors)}")
  assert_eq(colors[8], colors[0], msg="returned: \{Repr(colors)}")
}

///|
test "the button as a node pressed and let go: its ground eases to pressed and back" {
  let on = fn(t : @ui.Tester, x, y) { t.press_at(x, y) }
  let off = fn(t : @ui.Tester, x, y) {
    t.release(x, y)
    t.move_to(390.0, 290.0)
  }
  let colors = button_answers(on, off)
  assert_true(colors[0] != colors[4], msg="pressed: \{Repr(colors)}")
  assert_eq(colors[8], colors[0], msg="returned: \{Repr(colors)}")
}

///|
test "a button with an icon at work: the spinner in the icon's place, never the two side by side" {
  let busy = @signals.signal(false, same=fn(a, b) { a == b })
  let t = @ui.Tester::new(fn(_) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(200.0))).lines_up(Is(Some(Start))) |> ignore
      button_node(col, fn() { "刷新" }, fn() {  }, icon="refresh", busy=fn() { busy.get() }) |> ignore
    })
    |> ignore
  })
  t.draw()
  let words_at = fn() { t.drawn_glyphs()[0].0 }
  let rest = words_at()
  busy.set(true)
  t.frame()
  t.run_for(past_button_ms)
  let working = words_at()
  // (the words where they were, give or take the icon's ink against the spinner's whole square: before, an icon's
  // room and a spinner's both before them)
  assert_true((working - rest).abs() < button_icon / 2.0, msg="words at \{rest} at rest, \{working} at work")
  busy.set(false)
  t.frame()
  t.run_for(past_button_ms)
  assert_eq(words_at(), rest)
}

///|
/// A phone's window with a button saying `label` in a column `w` wide (as wide as its words and their ends where
/// None), as wide as that column where `across`, the system's size of words `fs`. The Tester, drawn.
fn narrow_button_case(label : String, fs : Double, across : Bool, w : Double?) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=200.0, platform=1)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  if fs != 1.0 {
    t.set_font_scale(fs)
  }
  @ui.set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(w)).lines_up(Is(Some(Start))) |> ignore
      button_node(col, fn() { label }, fn() {  }, tone=Primary, across~) |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a button across a column narrower than its words and their ends: its ends come down alike, its words whole in its middle" {
  for fs in [1.0, 1.3] {
    let label = "Save to Photos"
    // (as wide as its words and their ends, not across)
    let t = narrow_button_case(label, fs, false, None)
    let ((_, _, bw, _), (_, _, ww, _)) = pill_and_words(t, label)
    assert_eq(bw, ww + 2.0 * button_padx, msg="not across, words at \{fs}")
    // (across a column a half of its ends narrower than that, as 保存到相册 in a foot's half at 1.3)
    let w = ww + button_padx
    let t = narrow_button_case(label, fs, true, Some(w))
    let ((bx, _, bw, _), (wx, _, ww2, _)) = pill_and_words(t, label)
    let at = "across \{w}, words at \{fs}: pill \{bx} \{bw}, words \{wx} \{ww2}"
    assert_eq(bw, w, msg=at)
    assert_eq(ww2, ww, msg=at)
    assert_true(wx >= bx - 0.01 && wx + ww2 <= bx + bw + 0.01, msg=at)
    assert_true(((wx - bx) - (bx + bw - wx - ww2)).abs() < 0.5, msg=at)
    // (across one wider: as before, its words in its middle)
    let t = narrow_button_case(label, fs, true, Some(300.0))
    let ((bx, _, bw, _), (wx, _, ww3, _)) = pill_and_words(t, label)
    assert_eq(bw, 300.0, msg="across 300, words at \{fs}")
    assert_true(((wx - bx) - (bx + bw - wx - ww3)).abs() < 0.5, msg="across 300, words at \{fs}")
  }
}

///|
/// A phone's window 360 wide with a viewer's foot (viewer_frame_act_node) of 取消 (Cancel) and the doing (Save to
/// Photos), 复制 (Copy) between them where `copy`, the system's size of words `fs`. The Tester, drawn.
fn viewer_foot_case(fs : Double, copy : Bool) -> @ui.Tester {
  set_viewer_host(viewer_host_default())
  set_words(fn(key, _) { if key == "common.cancel" { "Cancel" } else { key } })
  let t = @ui.Tester::new(fn(_c) {  }, w=360.0, h=800.0, platform=1)
  t.check_looks(false)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  if fs != 1.0 {
    t.set_font_scale(fs)
  }
  let tips = TipLayer::new(fn() { None })
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(360.0))).height(Is(Some(800.0))) |> ignore
      viewer_frame_act_node(
        page,
        fn() { "Back" },
        fn() { "picture.png" },
        fn() { "" },
        fn() { page_viewer_ink() },
        fn() { "Save to Photos" },
        fn() { 360.0 },
        tips,
        copy?=if copy { Some(fn() { "Copy" }) } else { None },
        on_close=fn() {  },
        on_act=fn() {  },
      )
    })
    |> ignore
  })
  t.draw()
  t
}

///|
test "a viewer's foot in a small window without 复制, 取消 and the doing: each half while both fit; at 1.3 the doing's words whole with their ends, 取消 giving way" {
  let prev = words_of.val
  for fs in [1.0, 1.3] {
    let t = viewer_foot_case(fs, false)
    let ((cx, _, cw, _), (cwx, _, cww, _)) = pill_and_words(t, "Cancel")
    let ((sx, _, sw, _), (swx, _, sww, _)) = pill_and_words(t, "Save to Photos")
    let at = "words at \{fs}: Cancel \{cx} \{cw} (words \{cwx} \{cww}), Save to Photos \{sx} \{sw} (words \{swx} \{sww})"
    // (both in the window, side by side)
    assert_true(cx >= 0.0 && cx + cw <= sx && sx + sw <= 360.0, msg=at)
    // (each one's words whole with their ends in it, in its middle)
    assert_true(cw >= cww + 2.0 * button_padx - 0.01, msg=at)
    assert_true(sw >= sww + 2.0 * button_padx - 0.01, msg=at)
    assert_true(((cwx - cx) - (cx + cw - cwx - cww)).abs() < 0.5, msg=at)
    assert_true(((swx - sx) - (sx + sw - swx - sww)).abs() < 0.5, msg=at)
    // (each half while both fit)
    if fs == 1.0 {
      assert_true((cw - sw).abs() < 0.5, msg=at)
    }
    assert_eq(t.audit(), [], msg=at)
  }
  set_words(prev)
}

///|
test "a viewer's foot on a phone with 复制: at 1.3 the doing keeps its words and ends, 取消 and 复制 giving their ends alike, nothing past the window" {
  let prev = words_of.val
  for fs in [1.0, 1.3] {
    let t = viewer_foot_case(fs, true)
    let placed : Array[(Double, Double, Double, Double)] = []
    let mut at = "words at \{fs}:"
    for label in ["Cancel", "Copy", "Save to Photos"] {
      let ((bx, _, bw, _), (wx, _, ww, _)) = pill_and_words(t, label)
      at = at + " \{label} \{bx} \{bw} (words \{wx} \{ww})"
      placed.push((bx, bw, wx, ww))
    }
    // (side by side in the window)
    assert_true(placed[0].0 >= 0.0, msg=at)
    assert_true(placed[0].0 + placed[0].1 <= placed[1].0, msg=at)
    assert_true(placed[1].0 + placed[1].1 <= placed[2].0, msg=at)
    assert_true(placed[2].0 + placed[2].1 <= 360.0, msg=at)
    // (each one's words whole in it, in its middle; the doing's with their ends)
    for p in placed {
      let (bx, bw, wx, ww) = p
      assert_true(wx >= bx - 0.01 && wx + ww <= bx + bw + 0.01, msg=at)
      assert_true(((wx - bx) - (bx + bw - wx - ww)).abs() < 0.5, msg=at)
    }
    assert_true(placed[2].1 >= placed[2].3 + 2.0 * button_padx - 0.01, msg=at)
    assert_eq(t.audit(), [], msg=at)
  }
  set_words(prev)
}

///|
test "button_node: 1.0x and 1.3x keep exact button_height; 2.0x scales height with zero fixed_outgrown or squeeze_faults" {
  let t = @ui.Tester::new(fn(_c) {  }, w=600.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(
    fn(root) {
      root.row(Is(true)).lines_up(Is(Some(Start))).padding(Is((20.0, 20.0, 20.0, 20.0))).gap(Is(8.0)) |> ignore
      button_node(root, fn() { "Update" }, fn() {  }, tone=Primary) |> ignore
      button_node(root, fn() { "Cancel" }, fn() {  }, card_words=true) |> ignore
    },
    theme=ui_theme_now,
  )
  let h0 = button_height()
  t.draw()
  assert_eq(t.get(Button, label="Update").rect.3, h0, msg="1.0x primary height")
  assert_eq(t.get(Button, label="Cancel").rect.3, h0, msg="1.0x card_words height")
  assert_eq(t.fixed_outgrown(), [], msg="1.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.0x squeeze_faults")
  t.set_font_scale(1.3)
  t.draw()
  assert_eq(t.get(Button, label="Update").rect.3, h0, msg="1.3x primary height")
  assert_eq(t.get(Button, label="Cancel").rect.3, h0, msg="1.3x card_words height")
  assert_eq(t.fixed_outgrown(), [], msg="1.3x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="1.3x squeeze_faults")
  t.set_font_scale(2.0)
  t.draw()
  let h2 = t.get(Button, label="Update").rect.3
  assert_true(h2 > h0, msg="2.0x height grew: \{h2}")
  assert_eq(t.get(Button, label="Cancel").rect.3, h2, msg="2.0x card_words height matches")
  assert_eq(t.fixed_outgrown(), [], msg="2.0x fixed_outgrown")
  assert_eq(t.squeeze_faults(), [], msg="2.0x squeeze_faults")
}
