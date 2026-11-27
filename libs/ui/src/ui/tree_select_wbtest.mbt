// Words of the window's tree picked with the pointer (tree_select.mbt): a node's words in pieces where what holds it
// says so (words_picked), dragged over with a mouse, picked as an old view's paragraph of the same pieces is; what of
// them is picked drawn under them; none where it does not say so, nor with a finger.

///|
let picked_runs : Array[Run] = [plain("hello "), bold("wide"), plain(" world")]

///|
/// A node of picked_runs 300 wide 40 down (its line in its middle where `centered`), in a page whose words are picked
/// where `picks` (words_picked), on `platform`.
fn tree_picked_tester(picks : Bool, platform? : Int = 0, centered? : Bool = false) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform~)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((0.0, 40.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      if picks {
        words_picked(page)
      }
      page.box(fn(n) {
        n
        .width(Is(Some(300.0)))
        .words_runs(Is(picked_runs), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
        .words_centered(Is(centered))
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
/// The same words as an old view's paragraph whose words are picked (Ctx::selectable), 40 down.
fn old_picked_tester() -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  set_view_app(fn(root) {
    old(root, fn(c) {
      c.mouse_drags_lists(false)
      c.column(w=Fill(1.0), h=Fill(1.0), fn() {
        c.box(w=Px(300.0), h=Px(40.0), fn() {  }) |> ignore
        c.box(w=Px(300.0), fn() {
          c.selectable(fn() { c.rich(picked_runs, size=15.0, line=22.0, color=0x333333FFL) |> ignore })
        })
        |> ignore
      })
      |> ignore
    })
    .grow(Is(1.0))
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
/// The rects drawn in the colour what is picked is drawn under (desk's sel_color).
fn picked_drawn(t : Tester) -> Array[(Double, Double, Double, Double)] {
  t
  .drawn_instances()
  .filter(fn(a) { a[5] == 0.0 && a[8] > 0.2 && a[8] < 0.25 && a[9] > 0.5 && a[9] < 0.53 && a[10] > 0.95 })
  .map(fn(a) { (a[0], a[1], a[2], a[3]) })
}

///|
test "a node's words in pieces in a page whose words are picked: dragged over with the mouse, picked as an old view's paragraph of the same pieces is (from where it went down to where it let go), drawn picked under them; a press elsewhere lets them go" {
  for case in [(1.0, 300.0, "hello wide world"), (1.0, 60.0, "hello w")] {
    let (x0, x1, _) = case
    let old = old_picked_tester()
    let next = dragged_at(old, x0, 51.0, x1, 51.0, old.time(), true)
    old.frame_at(next)
    let old_said = old.ctx().selected_text()
    let old_drawn_now = picked_drawn(old)
    let t = tree_picked_tester(true)
    let next = dragged_at(t, x0, 51.0, x1, 51.0, t.time(), true)
    t.frame_at(next)
    assert_eq(t.ctx().selected_text(), old_said, msg="\{Repr(case)}")
    assert_true(old_said != "", msg="the old one picked: \{Repr(case)}")
    // (drawn picked where the old one is, as big)
    let old_drawn = old_drawn_now
    assert_true(old_drawn.length() > 0, msg="the old one drawn picked: \{Repr(case)}")
    assert_eq(picked_drawn(t), old_drawn, msg="drawn picked: \{Repr(case)}")
    // (pressed under them, where no words are: let go)
    let next = dragged_at(t, 350.0, 250.0, 350.0, 250.0, next + double_click_ms, true)
    t.frame_at(next)
    assert_eq(t.ctx().selected_text(), "")
    assert_eq(picked_drawn(t).length(), 0)
  }
}

///|
test "a node's words in pieces picked by none where nothing says its words are, nor by a finger where something does" {
  for case in [(false, 0), (true, 2)] {
    let (picks, platform) = case
    let t = tree_picked_tester(picks, platform~)
    let next = dragged_at(t, 1.0, 51.0, 300.0, 51.0, t.time(), true)
    t.frame_at(next)
    assert_eq(t.ctx().selected_text(), "", msg="\{Repr(case)}")
  }
}

///|
test "a node's words in pieces with its line in its middle: dragged from its first glyph to where its fifth begins, those four picked, drawn picked from where its first glyph is" {
  let t = tree_picked_tester(true, centered=true)
  let glyphs = t.drawn_instances().filter(fn(a) { a[5] == 1.0 }).map(fn(a) { (a[0], a[1], a[2], a[3]) })
  glyphs.sort_by(fn(a, b) { a.0.compare(b.0) })
  assert_true(glyphs[0].0 > 20.0, msg="in its middle: \{Repr(glyphs[0])}")
  // (where its words are said to be (Tester::run_rects) where they are drawn: in its middle too)
  let rs = t.run_rects("hello")
  assert_true(rs.length() == 1 && (rs[0].0 - glyphs[0].0).abs() < 2.0, msg="run_rects: \{Repr(rs)} \{Repr(glyphs[0])}")
  // (its last move, the fifth of six (dragged_at: the sixth lets go where it is), where the fifth glyph begins)
  let (x0, to) = (glyphs[0].0 + 0.5, glyphs[4].0 + 0.5)
  let next = dragged_at(t, x0, 51.0, x0 + (to - x0) * 6.0 / 5.0, 51.0, t.time(), true)
  t.frame_at(next)
  let drawn = picked_drawn(t)
  assert_eq(t.ctx().selected_text(), "hell")
  assert_eq(drawn.length(), 1)
  assert_true((drawn[0].0 - glyphs[0].0).abs() < 2.0, msg="from its first glyph: \{Repr(drawn)} \{Repr(glyphs[0])}")
}

///|
test "words picked in a page's list scrolled away and back (the nodes that show them made anew), then a block put before them: picked as they were, drawn picked again under the same words, once each; nothing found again as frames go by" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(40, fn(i) { i }))
  // (something moving beside them all along, nothing of it theirs)
  let spin = @signals.signal(0.0)
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.scrolls_window(s, fn() { keys.get() }, est=22.0, fn(b, i) {
        b.box(fn(n) {
          n
          .words_runs(Is([plain("第 \{i} 段 "), bold("hello")]), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
    root.box(fn(m) {
      m.over(Is(true)).width(Is(Some(10.0))).height(Is(Some(10.0))).offset(By(fn() { (350.0, spin.get()) })).ground(Is(0xFF0000FFL))
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // (from the first's start to the second's end)
  let next = dragged_at(t, 1.0, 11.0, 1.0 + 299.0 * 6.0 / 5.0, 11.0 + 26.0 * 6.0 / 5.0, t.time(), true)
  t.frame_at(next)
  let said = t.ctx().selected_text()
  assert_true(said.contains("第 0 段") && said.contains("第 1 段 hello"), msg="\{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 2, msg="drawn picked: \{Repr(drawn)}")
  // (frames with something else moving: nothing found again)
  let found = tree_sels_made.val
  for k in 0..<5 {
    spin.set(k.to_double() * 10.0)
    t.frame_at(t.time() + 16.0)
  }
  assert_eq(tree_sels_made.val, found, msg="found again as frames went by")
  // (away past where they show, then back)
  t.wheel(150.0, 100.0, 600.0)
  t.run_for(move_most_ms)
  assert_eq(picked_drawn(t).length(), 0, msg="none shows")
  t.wheel(150.0, 100.0, -600.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
  // (a block put before them: the same words picked, drawn picked under the same words (the list held where it
  // showed: what is over what shows grown, the column moved with it))
  keys.set([-1] + Array::makei(40, fn(i) { i }))
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
  assert_true(t.find("第 -1 段 hello") is None, msg="the one put before them over where it shows")
}

///|
/// A page 300 wide, `height` high, of 40 blocks of words in pieces picked with the mouse, laid out nowhere while
/// `hidden`: the tester and where its list is scrolled to.
fn picked_list_tester(height : @signals.Signal[Double], hidden : @signals.Signal[Bool]) -> (Tester, @view.Scroll) {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(By(fn() { Some(height.get()) })).width(Is(Some(300.0))).laid_nowhere(By(fn() { hidden.get() })) |> ignore
      words_picked(page)
      page.scrolls_window(s, fn() { Array::makei(40, fn(i) { i }) }, est=22.0, fn(b, i) {
        b.box(fn(n) {
          n
          .words_runs(Is([plain("第 \{i} 段 "), bold("hello")]), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  (t, s)
}

///|
test "words picked held past a page's list's foot, the list shorter under a pointer that stays where it is: brought on then; the page laid out nowhere while held: still, and known no more" {
  let height = @signals.signal(300.0)
  let hidden = @signals.signal(false)
  let (t, _) = picked_list_tester(height, hidden)
  // (pressed on the first, held at 250: within the list)
  finger(0, 2.0, 11.0)
  t.frame_at(t.time() + 16.0)
  finger(1, 60.0, 250.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed: 0.0, .. }), msg="within it: still")
  // (the list made 200 high under the pointer held at 250: past its foot now, brought on)
  height.set(200.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed, .. }) && speed > 0.0, msg="past its foot: brought on")
  // (frame after frame, the pointer still: what is picked growing as the column comes on, each two frames more)
  let mut was = t.ctx().selected_text()
  for k in 0..<10 {
    t.frame_at(t.time() + 16.0)
    t.frame_at(t.time() + 16.0)
    let now = t.ctx().selected_text()
    assert_true(now.length() > was.length() && now.has_prefix(was), msg="frame \{k}: \{was} -> \{now}")
    was = now
  }
  t.frame_at(t.time() + 300.0)
  let picked = t.ctx().selected_text()
  assert_true(picked.contains("第 15 段"), msg="picking on as it came: \{picked}")
  // (laid out nowhere while held: still, the column known no more)
  hidden.set(true)
  t.frame_at(t.time() + 16.0)
  let state = match tree_edge.val {
    Some(e) =>
      match e.scroll.bind(fn(s) { s.shown_by() }) {
        Some(v) => "shown by a node, nowhere \{v.shown_nowhere()}, rect \{Repr(v.rect())}, speed \{e.speed}"
        None => "shown by none"
      }
    None => "none"
  }
  assert_true(tree_edge.val is None, msg="known no more: \{state}")
  finger(2, 60.0, 250.0)
  t.frame_at(t.time() + 16.0)
}

///|
test "words picked in a page's list, let go, then the page laid out nowhere: what was picked kept whole, nothing picking on" {
  let height = @signals.signal(300.0)
  let hidden = @signals.signal(false)
  let (t, _) = picked_list_tester(height, hidden)
  finger(0, 2.0, 11.0)
  t.frame_at(t.time() + input_step_ms)
  finger(1, 60.0, 120.0)
  t.frame_at(t.time() + input_step_ms)
  finger(1, 60.0, 250.0)
  t.frame_at(t.time() + input_step_ms)
  finger(2, 60.0, 250.0)
  t.frame_at(t.time() + input_step_ms)
  let kept = t.ctx().selected_text()
  assert_true(kept.contains("第 0 段") && kept.contains("第 9 段"), msg="\{kept}")
  assert_false(picked.dragging, msg="let go: picking no more")
  hidden.set(true)
  t.frame_at(t.time() + input_step_ms)
  t.frame_at(t.time() + move_most_ms)
  assert_eq(t.ctx().selected_text(), kept, msg="laid out nowhere")
}

///|
test "a node's words in pieces in a page whose words are picked: a finger held still on them a long press's time picks the word under it, the menu over it once lifted; a tap elsewhere lets it go" {
  let t = tree_picked_tester(true, platform=2)
  t.press_at(60.0, 51.0)
  assert_eq(t.ctx().selected_text(), "")
  t.run_for(long_press_ms)
  assert_eq(t.ctx().selected_text(), "wide")
  t.release(60.0, 51.0)
  t.draw()
  assert_true(t.text_menu().0)
  t.tap(200.0, 250.0)
  t.draw()
  assert_eq(t.ctx().selected_text(), "")
}

///|
test "words picked in a row that scrolls across (a code block's line), held past its end: the row brought on toward the pointer, picked as they come, till the line's end; held past its start, back; let go, still" {
  let line = "let total = items.map(fn(x) { x.price * x.count }).fold(init=0, fn(a, b) { a + b }) // the end"
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::across()
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      page.box(fn(b) {
        b.width(Is(Some(200.0))) |> ignore
        b.scrolls(s, fn(held) {
          held.box(fn(n) {
            n.words_runs(Is([plain(line)]), ink=0x333333FFL, look={ size: 12.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // (pressed on its first glyph, held past its end at 300)
  finger(0, 1.0, 9.0)
  t.frame_at(t.time() + 16.0)
  finger(1, 300.0, 9.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed_across, .. }) && speed_across > 0.0, msg="past its end: brought on")
  let a0 = s.at(view_app.val.unwrap())
  let p0 = t.ctx().selected_text()
  t.frame_at(t.time() + 300.0)
  let a1 = s.at(view_app.val.unwrap())
  let p1 = t.ctx().selected_text()
  assert_true(a1 > a0 + 40.0, msg="brought on: \{a0} \{a1}")
  assert_true(p1.length() > p0.length() && p1.has_prefix(p0), msg="picked on: \{p0} -> \{p1}")
  t.frame_at(t.time() + 5000.0)
  t.frame_at(t.time() + 16.0)
  assert_eq(t.ctx().selected_text(), line)
  // (held past its start: back)
  finger(1, -20.0, 9.0)
  t.frame_at(t.time() + 16.0)
  let a2 = s.at(view_app.val.unwrap())
  t.frame_at(t.time() + 300.0)
  assert_true(s.at(view_app.val.unwrap()) < a2, msg="back")
  // (let go: still)
  finger(2, -20.0, 9.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is None)
  let a3 = s.at(view_app.val.unwrap())
  t.frame_at(t.time() + 300.0)
  assert_eq(s.at(view_app.val.unwrap()), a3)
}

///|
/// Three paragraphs of words in pieces 300 wide, one under another from 40 down, in a page whose words are picked
/// (words_picked); the middle one in a block lent a picker that picks none where `none` (a quote's card in a message).
/// Dragged over with the mouse from the first's start to the last's end: what is picked then.
fn picked_past_a_block(none : Bool) -> String {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((0.0, 40.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      page.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("before")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
      page.box(fn(b) {
        if none {
          b.lends(@view.runs_picker, fn(_) { Is((0, 0)) }) |> ignore
        }
        b.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("quoted")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
      page.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("after")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // (from the first's first glyph, 40 down, to the third's end, 84 down)
  let next = dragged_at(t, 1.0, 51.0, 299.0, 95.0, t.time(), true)
  t.frame_at(next)
  t.ctx().selected_text()
}

///|
test "dragged over words in pieces past a block lent a picker that picks none: those of the block none of what is picked, nor copied; a block lent none picked with the rest" {
  assert_eq(picked_past_a_block(true), "before\nafter")
  assert_eq(picked_past_a_block(false), "before\nquoted\nafter")
}

///|
test "what a finger is picking read as it goes (Tester::picking): the word held, its two handles; its end's handle taken where only it takes the finger and moved across, the end follows it, the start where it was; none once let go by a tap" {
  let t = tree_picked_tester(true, platform=2)
  assert_eq(t.picking(), None)
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  t.release(60.0, 51.0)
  t.draw()
  guard t.picking() is Some(first) && first.ends is [Some(_), Some((ex, ey))] else {
    fail("no word picked with its handles: \{Repr(t.picking())}")
  }
  assert_eq((first.text, first.finger), ("wide", true))
  t.press_at(ex, ey)
  t.frame()
  t.move_to(ex + 60.0, ey)
  t.draw()
  guard t.picking() is Some(now) else { fail("let go as its handle moved") }
  assert_true(now.text.has_prefix("wide") && now.text.length() > 4, msg="\{Repr(now)}")
  t.release(ex + 60.0, ey)
  t.draw()
  t.tap(200.0, 250.0)
  t.draw()
  assert_eq(t.picking(), None)
}

///|
test "two side-by-side words_picked scopes in the same layer: dragging across whitespace or into neighbor stays strictly within starting scope" {
  let t = Tester::new(fn(_c) {  }, w=500.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  let right_nodes : Array[@view.View] = []
  let left_nodes : Array[@view.View] = []
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(500.0))).height(Is(Some(300.0))) |> ignore
      row.box(fn(left) {
        left.width(Is(Some(240.0))).gap(Is(30.0)) |> ignore
        words_picked(left)
        left.box(fn(n) {
          n.width(Is(Some(220.0))).words_runs(Is([plain("left first line")]), ink=0x333333FFL, look~) |> ignore
          left_nodes.push(n)
        })
        |> ignore
        left.box(fn(n) {
          n.width(Is(Some(220.0))).words_runs(Is([plain("left second line")]), ink=0x333333FFL, look~) |> ignore
          left_nodes.push(n)
        })
        |> ignore
      })
      |> ignore
      row.box(fn(right) {
        right.width(Is(Some(240.0))).gap(Is(4.0)) |> ignore
        words_picked(right)
        right.box(fn(n) {
          n.width(Is(Some(220.0))).words_runs(Is([plain("right row zero")]), ink=0x333333FFL, look~) |> ignore
          right_nodes.push(n)
        })
        |> ignore
        right.box(fn(n) {
          n.width(Is(Some(220.0))).words_runs(Is([plain("right row one")]), ink=0x333333FFL, look~) |> ignore
          right_nodes.push(n)
        })
        |> ignore
        right.box(fn(n) {
          n.width(Is(Some(220.0))).words_runs(Is([plain("right row two")]), ink=0x333333FFL, look~) |> ignore
          right_nodes.push(n)
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Drag from left first line into the 30px vertical gap between left lines (where right row one sits at same y=36)
  let next1 = dragged_at(t, 4.0, 10.0, 100.0, 36.0, t.time(), true)
  t.frame_at(next1)
  assert_true(!t.ctx().selected_text().contains("right"), msg="gap leaked right: \{t.ctx().selected_text()}")
  for n in right_nodes {
    assert_eq(n.runs_picked_now(), (0, 0), msg="right node highlighted on left gap drag")
  }
  // Drag from left first line directly into right scope (past double_click_ms so it starts a fresh drag, not a double-click)
  let next2 = dragged_at(t, 1.0, 10.0, 350.0, 40.0, next1 + double_click_ms, true)
  t.frame_at(next2)
  assert_true(t.ctx().selected_text().contains("left first"), msg="left selected: \{t.ctx().selected_text()}")
  assert_true(!t.ctx().selected_text().contains("right"), msg="drag into right leaked: \{t.ctx().selected_text()}")
  for n in right_nodes {
    assert_eq(n.runs_picked_now(), (0, 0), msg="right node highlighted on cross-pane drag")
  }
  // Reverse: drag from right scope into left scope
  let next3 = dragged_at(t, 360.0, 40.0, 10.0, 10.0, next2 + double_click_ms, true)
  t.frame_at(next3)
  assert_true(t.ctx().selected_text().contains("right"), msg="right selected: \{t.ctx().selected_text()}")
  assert_true(!t.ctx().selected_text().contains("left"), msg="drag into left leaked: \{t.ctx().selected_text()}")
  for n in left_nodes {
    assert_eq(n.runs_picked_now(), (0, 0), msg="left node highlighted on reverse cross-pane drag")
  }
}

///|
test "nested words_picked shares scope by default; apart=true creates an independent sub-scope" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(outer) {
      outer.width(Is(Some(360.0))).gap(Is(8.0)) |> ignore
      words_picked(outer)
      // idempotent repeat on same node
      words_picked(outer)
      outer.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("outer line")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
      outer.box(fn(child) {
        // nested without apart: inherits outer scope
        words_picked(child)
        child.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("shared child")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
      outer.box(fn(sub) {
        // nested with apart=true: independent scope
        words_picked(sub, apart=true)
        sub.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("apart sub")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Drag across all three vertically: outer + shared child are selected, apart sub is excluded
  let next = dragged_at(t, 2.0, 10.0, 280.0, 75.0, t.time(), true)
  t.frame_at(next)
  assert_eq(t.ctx().selected_text(), "outer line\nshared child")
}

///|
test "unequal-height Middle-centered cells with words_hit_box: vertical whitespace hits own cell first/last line and row gap hits nearest row" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 14.0, weight: 400, line: 20.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(360.0))).gap(Is(12.0)) |> ignore
      words_picked(page)
      // Row 0: short Middle-centered cell on left (height 80), tall 4-line cell on right
      page.box(fn(r0) {
        r0.row(Is(true)).width(Is(Some(360.0))) |> ignore
        r0.box(fn(c0) {
          c0.width(Is(Some(140.0))).height(Is(Some(80.0))).lies_along(Is(Middle)) |> ignore
          words_hit_box(c0)
          c0.box(fn(w) { w.words_runs(Is([plain("shortA")]), ink=0x333333FFL, look~) |> ignore }) |> ignore
        })
        |> ignore
        r0.box(fn(c1) {
          c1.width(Is(Some(200.0))).height(Is(Some(80.0))) |> ignore
          words_hit_box(c1)
          c1.box(fn(w) { w.words_runs(Is([plain("tall1\ntall2\ntall3\ntall4")]), ink=0x333333FFL, look~) |> ignore })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      // Row 1 (12px gap below row 0, y=92..152)
      page.box(fn(r1) {
        r1.row(Is(true)).width(Is(Some(360.0))) |> ignore
        r1.box(fn(c0) {
          c0.width(Is(Some(140.0))).height(Is(Some(60.0))).lies_along(Is(Middle)) |> ignore
          words_hit_box(c0)
          c0.box(fn(w) { w.words_runs(Is([plain("row1A")]), ink=0x333333FFL, look~) |> ignore }) |> ignore
        })
        |> ignore
        r1.box(fn(c1) {
          c1.width(Is(Some(200.0))).height(Is(Some(60.0))) |> ignore
          words_hit_box(c1)
          c1.box(fn(w) { w.words_runs(Is([plain("row1B1\nrow1B2\nrow1B3")]), ink=0x333333FFL, look~) |> ignore })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Drag inside top whitespace of shortA (y=8, well above its Middle-centered text at y=30..50): must hit shortA, not tall1
  let next1 = dragged_at(t, 2.0, 8.0, 100.0, 72.0, t.time(), true)
  t.frame_at(next1)
  assert_eq(t.ctx().selected_text(), "shortA")
  // Drag from start of shortA to the row gap closer to row 0 (y=83, gap is 80..92, closer to row 0 than row 1): must stay in row 0 col 0, not jump to row1B
  let next2 = dragged_at(t, 2.0, 40.0, 80.0, 83.0, next1 + double_click_ms, true)
  t.frame_at(next2)
  assert_eq(t.ctx().selected_text(), "shortA")
}

///|
test "cross-slice horizontal edge scroll stops when pointer leaves table vertical band and hands off to visible peer when start slice unmounts" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 12.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
  let parent_across = @view.Scroll::across()
  let s1 = parent_across.beside()
  let show_slice0 = @signals.signal(true)
  let line = "col0-abcdef col1-ghijkl col2-mnopqr col3-stuvwx col4-yz0123 col5-456789 col6-abcdef col7-ghijkl col8-mnopqr col9-stuvwx col10-yz0123 col11-456789"
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(220.0))).gap(Is(4.0)) |> ignore
      words_picked(page)
      page.show(at_once=true, fn() { show_slice0.get() }, fn(slot) {
        let s0 = parent_across.beside()
        slot.box(fn(b) {
          b.width(Is(Some(200.0))).height(Is(Some(30.0))) |> ignore
          b.scrolls(s0, fn(held) {
            held.box(fn(n) { n.words_runs(Is([plain(line)]), ink=0x333333FFL, look~) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      page.box(fn(b) {
        b.width(Is(Some(200.0))).height(Is(Some(30.0))) |> ignore
        b.scrolls(s1, fn(held) {
          held.box(fn(n) { n.words_runs(Is([plain(line)]), ink=0x333333FFL, look~) |> ignore }) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Start dragging on slice 0, move past right edge within slice 0's vertical band (y=12)
  finger(0, 2.0, 12.0)
  t.frame_at(t.time() + 16.0)
  finger(1, 280.0, 12.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed_across, .. }) && speed_across > 0.0, msg="scrolling right inside table band")
  t.frame_at(t.time() + 200.0)
  let x_in = s1.at(view_app.val.unwrap())
  assert_true(x_in > 10.0, msg="scrolled right: \{x_in}")
  // Move pointer vertically outside both slices (y=200): horizontal edge scroll must stop immediately
  finger(1, 280.0, 200.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed_across, .. }) && speed_across == 0.0, msg="stopped outside table vertical band")
  let x_stopped = s1.at(view_app.val.unwrap())
  t.frame_at(t.time() + 200.0)
  assert_eq(s1.at(view_app.val.unwrap()), x_stopped)
  // Unmount slice 0 (simulating virtualized slice scrolling out of view), move pointer into slice 1's vertical band (y=12 after slice0 gone) past right edge
  show_slice0.set(false)
  t.frame_at(t.time() + 16.0)
  finger(1, 280.0, 12.0)
  t.frame_at(t.time() + 16.0)
  assert_true(tree_edge.val is Some({ speed_across, .. }) && speed_across > 0.0, msg="peer slice took over horizontal edge scroll")
  t.frame_at(t.time() + 200.0)
  let x_peer = s1.at(view_app.val.unwrap())
  assert_true(x_peer > x_stopped + 10.0, msg="peer continued scrolling: \{x_stopped} -> \{x_peer}")
  finger(2, 280.0, 12.0)
  t.frame_at(t.time() + 16.0)
}

///|
test "click then Shift+click in words_picked extends forward, backward, across drags, and resets after a plain click elsewhere" {
  let t = tree_picked_tester(true)
  let wide = t.run_rects("wide")
  assert_eq(wide.length(), 1)
  let (wx, wy, ww, wh) = wide[0]
  let cy = wy + wh / 2.0
  let start_x = 1.0
  let mid_x = wx + 1.0
  let end_x = wx + ww + 80.0
  // Plain click at the start of "wide" sets the collapsed anchor without highlighting anything.
  t.tap(mid_x, cy)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_now(), None)
  // Shift+click forward to the end selects from "wide" to the end.
  t.hold_mods(mod_shift_key)
  t.tap(end_x, cy)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "wide world")
  assert_true(picked_now().map(fn(p) { (p.text, p.ends_at_start) }) == Some(("wide world", false)))
  // Another Shift+click before the anchor flips the selection backward while keeping the original anchor.
  t.hold_mods(mod_shift_key)
  t.tap(start_x, cy)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "hello ")
  assert_true(picked_now().map(fn(p) { (p.text, p.ends_at_start) }) == Some(("hello ", true)))
  // Shift+press and drag keeps the same anchor and moves the focus end continuously.
  t.hold_mods(mod_shift_key)
  t.press_at(wx + ww / 2.0, cy)
  t.frame()
  t.move_to(end_x, cy)
  t.frame()
  t.release(end_x, cy)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "wide world")
  // A plain click outside clears the anchor so a subsequent Shift+click does not resurrect it.
  t.tap(350.0, 250.0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
  t.hold_mods(mod_shift_key)
  t.tap(end_x, cy)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
}

///|
test "Shift+click spans multiple paragraphs and extends into whitespace within the same words_picked scope" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((0.0, 20.0, 0.0, 0.0))).width(Is(Some(320.0))).gap(Is(24.0)) |> ignore
      words_picked(page)
      page.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("first paragraph")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
      page.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("second paragraph")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
      page.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("third paragraph")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Paragraph 1 is at y=20..42, gap at y=42..66, paragraph 2 at y=66..88, gap at y=88..112, paragraph 3 at y=112..134.
  t.tap(1.0, 31.0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
  // Shift+click on paragraph 3 selects all three paragraphs.
  t.hold_mods(mod_shift_key)
  t.tap(299.0, 123.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "first paragraph\nsecond paragraph\nthird paragraph")
  // Shift+click in the vertical whitespace gap closer to paragraph 2 shrinks to paragraphs 1 and 2.
  t.hold_mods(mod_shift_key)
  t.tap(299.0, 92.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "first paragraph\nsecond paragraph")
}

///|
test "Shift+click never crosses between separate words_picked scopes" {
  let t = Tester::new(fn(_c) {  }, w=500.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(500.0))).height(Is(Some(300.0))) |> ignore
      row.box(fn(left) {
        left.width(Is(Some(240.0))).gap(Is(30.0)) |> ignore
        words_picked(left)
        left.box(fn(n) { n.width(Is(Some(220.0))).words_runs(Is([plain("left first line")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
        left.box(fn(n) { n.width(Is(Some(220.0))).words_runs(Is([plain("left second line")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
      row.box(fn(right) {
        right.width(Is(Some(240.0))).gap(Is(30.0)) |> ignore
        words_picked(right)
        right.box(fn(n) { n.width(Is(Some(220.0))).words_runs(Is([plain("right row zero")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
        right.box(fn(n) { n.width(Is(Some(220.0))).words_runs(Is([plain("right row one")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Click in left scope, then Shift+click in right scope's text: clears left, starts a collapsed anchor in right.
  t.tap(2.0, 11.0)
  t.frame()
  t.hold_mods(mod_shift_key)
  t.tap(360.0, 63.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
  // Now Shift+click in right scope's first line extends within right scope from that new anchor.
  t.hold_mods(mod_shift_key)
  t.tap(242.0, 11.0)
  t.hold_mods(0)
  t.frame()
  assert_true(t.ctx().selected_text().contains("right row zero"), msg="extended in right: \{t.ctx().selected_text()}")
  assert_true(!t.ctx().selected_text().contains("left"), msg="must not leak left: \{t.ctx().selected_text()}")
  // Shift+click into left scope's whitespace gap clears right selection instead of leaking.
  t.hold_mods(mod_shift_key)
  t.tap(100.0, 36.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "")
}

///|
test "Shift+click extends a legacy Ctx::selectable selection and an existing dragged selection" {
  let old = old_picked_tester()
  old.tap(1.0, 51.0)
  old.frame()
  assert_eq(old.ctx().selected_text(), "")
  old.hold_mods(mod_shift_key)
  old.tap(300.0, 51.0)
  old.hold_mods(0)
  old.frame()
  assert_eq(old.ctx().selected_text(), "hello wide world")
  // Dragging part of a tree paragraph then Shift+clicking extends from the drag anchor.
  let t = tree_picked_tester(true)
  let next = dragged_at(t, 1.0, 51.0, 60.0, 51.0, t.time(), true)
  t.frame_at(next)
  let part = t.ctx().selected_text()
  assert_true(part.has_prefix("hello") && part.length() < "hello wide world".length(), msg="dragged part: \{part}")
  t.hold_mods(mod_shift_key)
  t.tap(300.0, 51.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(t.ctx().selected_text(), "hello wide world")
}

///|
test "Shift+click updates picked_now.made, works in scrolls_window after prepending rows, and never hijacks buttons" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(10, fn(i) { i }))
  let clicks = Ref(0)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(300.0))).height(Is(Some(260.0))) |> ignore
      words_picked(page)
      page.box(fn(btn) {
        btn
        .width(Is(Some(100.0)))
        .height(Is(Some(30.0)))
        .on_press(fn() { clicks.val = clicks.val + 1 })
        |> ignore
      })
      |> ignore
      page.scrolls_window(s, fn() { keys.get() }, est=22.0, fn(b, i) {
        b.box(fn(n) { n.words_runs(Is([plain("row \{i} text")]), ink=0x333333FFL, look~) |> ignore }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Click row 0, prepend row -1 above it, then Shift+click row 2.
  let (r0x, r0y, _, r0h) = t.rect_of("row 0 text").unwrap()
  t.tap(r0x + 1.0, r0y + r0h / 2.0)
  t.frame()
  keys.set([-1] + Array::makei(10, fn(i) { i }))
  t.run_for(move_most_ms)
  let (r2x, r2y, r2w, r2h) = t.rect_of("row 2 text").unwrap()
  t.hold_mods(mod_shift_key)
  t.tap(r2x + r2w - 1.0, r2y + r2h / 2.0)
  t.hold_mods(0)
  t.frame()
  guard picked_now() is Some(p1) else { fail("expected selection after Shift+click") }
  assert_eq(p1.text, "row 0 text\nrow 1 text\nrow 2 text")
  // Shift+clicking further down advances picked.made.
  let (r3x, r3y, r3w, r3h) = t.rect_of("row 3 text").unwrap()
  t.hold_mods(mod_shift_key)
  t.tap(r3x + r3w - 1.0, r3y + r3h / 2.0)
  t.hold_mods(0)
  t.frame()
  guard picked_now() is Some(p2) else { fail("expected extended selection") }
  assert_eq(p2.text, "row 0 text\nrow 1 text\nrow 2 text\nrow 3 text")
  assert_true(p2.made > p1.made, msg="made advanced: \{p1.made} -> \{p2.made}")
  // Shift+clicking a button fires the button and clears the text selection instead of extending onto it.
  t.hold_mods(mod_shift_key)
  t.tap(50.0, 15.0)
  t.hold_mods(0)
  t.frame()
  assert_eq(clicks.val, 1)
  assert_eq(t.ctx().selected_text(), "")
}
