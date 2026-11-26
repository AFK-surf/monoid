// Words picked in a page's list's rows (View::scrolls_window) are known by the rows' keys (View::row_place, its list
// and its key's number there), not by the nodes the rows are made in: what the list makes again where a row was (its
// slot let go as it is far out of sight, made again as it comes back) shows the same words picked, copied in the same
// order (tree_select.mbt's tree_place: a row's place among the list's keys, View::row_order).

///|
/// A page 300 wide and 200 high of `n` blocks of words in pieces picked with the mouse, the second words of each bold.
fn row_picked_tester(n : Int) -> (Tester, @view.Scroll) {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.scrolls_window(s, fn() { Array::makei(n, fn(i) { i }) }, est=22.0, fn(b, i) {
        b.box(fn(w) {
          w
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
/// The first two rows' words picked, from the first's start to the second's end: what is copied of them.
fn row_picked_two(t : Tester) -> String {
  let next = dragged_at(t, 1.0, 11.0, 1.0 + 299.0 * 6.0 / 5.0, 11.0 + 26.0 * 6.0 / 5.0, t.time(), true)
  t.frame_at(next)
  t.ctx().selected_text()
}

///|
test "words picked in a page's list, scrolled three screens away and back (the rows made again where they were): picked as they were, drawn picked under the same words" {
  let (t, _) = row_picked_tester(40)
  let said = row_picked_two(t)
  assert_true(said.contains("第 0 段") && said.contains("第 1 段 hello"), msg="\{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 2, msg="drawn picked: \{Repr(drawn)}")
  t.wheel(150.0, 100.0, 600.0)
  t.run_for(move_most_ms)
  assert_eq(picked_drawn(t).length(), 0, msg="none shows")
  t.wheel(150.0, 100.0, -600.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
}

///|
test "words picked over two rows of a page's list, scrolled a thousand rows away and back: the same words picked, copied in the same order, drawn picked under the same words" {
  let (t, s) = row_picked_tester(1200)
  let said = row_picked_two(t)
  let first = said.find("第 0 段").unwrap_or(-1)
  let second = said.find("第 1 段 hello").unwrap_or(-1)
  assert_true(first >= 0 && second > first, msg="copied: \{said}")
  let drawn = picked_drawn(t)
  // (a thousand rows down, 22 each, then back to its top)
  t.wheel(150.0, 100.0, 22000.0)
  t.run_for(move_most_ms)
  match view_app.val {
    Some(tree) => assert_true(s.at(tree) > 20000.0, msg="at \{s.at(tree)}")
    None => fail("no window's tree")
  }
  t.wheel(150.0, 100.0, -22000.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
}

///|
/// A page as row_picked_tester's whose blocks are all of one kind another may take (`reused`): each put by as it no
/// more shows and taken by the next to show, given that one's key (answering.mbt), its words by its key.
fn row_picked_reused_tester(n : Int, made : Ref[Int]) -> Tester {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.scrolls_window(
        s,
        fn() { Array::makei(n, fn(i) { i }) },
        est=22.0,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made.val = made.val + 1
          b.box(fn(w) {
            w
            .words_runs(By(fn() { [plain("第 \{key()} 段 "), bold("hello")] }), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t
}

///|
test "words picked in a page's list's row, its block put by and taken for another key: nothing drawn picked on that one; back to the first key's row, drawn picked there as they were" {
  let made = Ref(0)
  let t = row_picked_reused_tester(40, made)
  let said = row_picked_two(t)
  assert_true(said.contains("第 0 段") && said.contains("第 1 段 hello"), msg="\{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 2, msg="drawn picked: \{Repr(drawn)}")
  // (down so far that the blocks of 0 and 1 are put by and taken by rows come into sight)
  t.wheel(150.0, 100.0, 400.0)
  t.run_for(move_most_ms)
  // (as many blocks made as show at once, and a few: those of 0 and 1 taken by rows come into sight)
  assert_true(made.val < 18, msg="blocks made: \{made.val}")
  assert_eq(picked_drawn(t), [], msg="drawn picked on the rows that took their blocks: \{Repr(picked_drawn(t))}, made \{made.val}, \{Repr(t.drawn_words_found().map(fn(d) { (d.3, d.0.y) }))}")
  assert_eq(t.ctx().selected_text(), said)
  // (back: the first keys' rows show again, in whatever blocks, the same words drawn picked)
  t.wheel(150.0, 100.0, -400.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
}

///|
test "table inside scrolls_window with nested each and two 4-row slices: survives 3-screen scroll, zero ghost highlight on reuse, and preserves order after prepending rows" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=260.0, platform=0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let look : @view.WordsLook = { size: 13.0, weight: 400, line: 18.0, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
  // Keys: 0 = table slice 0 (rows 0..3), 1 = table slice 1 (rows 4..8), 2..29 = other messages with same-shape 2-col table
  let keys = @signals.signal(Array::makei(30, fn(i) { i }))
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(320.0))) |> ignore
      words_picked(page)
      page.scrolls_window(
        s,
        fn() { keys.get() },
        est=80.0,
        fn(_, _) { @halt.saying("all reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          // Two nested View::each levels (table rows -> table cells), like table_frame_node
          let row_range = fn() {
            let k = key()
            if k == 0 {
              [0, 1, 2, 3]
            } else if k == 1 {
              [4, 5, 6, 7, 8]
            } else {
              [0, 1, 2, 3]
            }
          }
          b.each(row_range, fn(r) { r }, at_once=true, fn(tr, r_sig) {
            let r = r_sig.untracked()
            tr.row(Is(true)).gap(Is(8.0)) |> ignore
            tr.each(fn() { [0, 1] }, fn(c) { c }, at_once=true, fn(td, c_sig) {
              let c = c_sig.untracked()
              words_hit_box(td)
              words_shaped(td, fn() { Cell(100, r, c, r == 0) }) |> ignore
              td.width(Is(Some(120.0))) |> ignore
              td.box(fn(w) {
                w.words_runs(By(fn() { [plain("k\{key()}r\{r}c\{c}")] }), ink=0x333333FFL, look~) |> ignore
              })
              |> ignore
            })
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Drag across slice 0 (rows 0..3, y=0..72) into slice 1 (row 4, y=72..90); 5/6 of drag reaches (217, 84)
  let next = dragged_at(t, 2.0, 6.0, 260.0, 100.0, t.time(), true)
  t.frame_at(next)
  let said = t.ctx().selected_text()
  assert_true(said.contains("k0r0c0\tk0r0c1") && said.contains("k1r4c0\tk1r4c1"), msg="cross-slice TSV: \{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 8, msg="drawn cells: \{drawn.length()}")
  // Scroll 3 screens down so blocks 0 and 1 are recycled for later keys: zero ghost highlights!
  t.wheel(150.0, 100.0, 800.0)
  t.run_for(move_most_ms)
  assert_eq(picked_drawn(t), [], msg="ghost highlight on recycled table blocks")
  assert_eq(t.ctx().selected_text(), said)
  // Prepend 3 history rows above while selection is off-screen: order & copied text must stay identical!
  let prepended = [-3, -2, -1]
  prepended.append(keys.untracked())
  keys.set(prepended)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  // Scroll back to top (past prepended rows), then down past the 3 prepended rows (3 * 72 = 216px) so keys 0 & 1 are in the 200px viewport
  t.wheel(150.0, 100.0, -1200.0)
  t.run_for(move_most_ms)
  t.wheel(150.0, 100.0, 220.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_true(picked_drawn(t).length() >= 8, msg="re-highlighted after scroll back: \{picked_drawn(t).length()}")
}

///|
test "words picked in a page's list with reused blocks: picked_now and quote pill hide when scrolled away and recycled, selected_text stays intact, and scrolling back restores highlight, picked_now, and quote pill" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let pill : Ref[@view.NodeId?] = Ref(None)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.scrolls_window(
        s,
        fn() { Array::makei(40, fn(i) { i }) },
        est=22.0,
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          b.reacts(key, fn(k) { picked_of(b, "msg-\{k}", whole=true) |> ignore })
          b.box(fn(w) {
            w.words_runs(By(fn() { [plain("第 \{key()} 段 "), bold("hello")] }), ink=0x333333FFL, look~) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
      page.pick(fn() { picked_now().map(fn(p) { (p.made, p.ends_in) }) }, fn(holds, cur) {
        guard cur is Some(_) && @signals.untracked(picked_now) is Some(p) else {
          pill.val = None
          return
        }
        holds.box(fn(b) {
          pill.val = Some(b.id())
          keeps_picked(b)
          .width(Is(Some(40.0)))
          .height(Is(Some(20.0)))
          .ground(Is(0x112233FFL))
          .beside(p.ends_in, side=Top, offset=4.0, piece=picked_end_piece(p), while_seen=true)
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let tree = view_app.val.unwrap()
  let next = dragged_at(t, 1.0, 11.0, 299.0, 11.0, t.time(), true)
  t.frame_at(next)
  let said = t.ctx().selected_text()
  assert_true(said.contains("第 0 段"), msg="selected: \{said}")
  let drawn = picked_drawn(t)
  assert_true(drawn.length() >= 1, msg="drawn picked: \{Repr(drawn)}")
  guard picked_now() is Some(p0) else { fail("expected picked_now after drag") }
  assert_eq(p0.of, ["msg-0"])
  assert_true(pill.val.bind(fn(id) { tree.drawn_of(id) }) is Some(_), msg="pill drawn initially")
  // Scroll 3 screens down so row 0's block is recycled for incoming rows
  t.wheel(150.0, 100.0, 600.0)
  t.run_for(move_most_ms)
  assert_eq(picked_now(), None, msg="picked_now hidden while row 0 is recycled off-screen")
  assert_eq(picked_drawn(t), [], msg="no ghost highlight on recycled rows")
  assert_true(pill.val.bind(fn(id) { tree.drawn_of(id) }) is None, msg="pill hidden while off-screen")
  assert_eq(t.ctx().selected_text(), said, msg="selected_text preserved while scrolled away")
  // Scroll back to top: selection, highlight, picked_now, and pill all return
  t.wheel(150.0, 100.0, -600.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), said)
  assert_eq(picked_drawn(t), drawn)
  guard picked_now() is Some(p1) else { fail("picked_now did not restore after scrolling back") }
  assert_eq((p1.text, p1.of), (said, ["msg-0"]))
  assert_true(pill.val.bind(fn(id) { tree.drawn_of(id) }) is Some(_), msg="pill restored after scrolling back")
}

///|
test "finger pick in a picked_bar list scrolled away and back: system text menu stays suppressed, selected_text kept, and picked_now restores" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2, pointing=Finger)
  t.check_looks(false)
  let s = @view.Scroll::list()
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.height(Is(Some(200.0))).width(Is(Some(300.0))) |> ignore
      words_picked(page)
      picked_bar(page) |> ignore
      page.scrolls_window(
        s,
        fn() { Array::makei(40, fn(i) { i }) },
        est=22.0,
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          b.reacts(key, fn(k) { picked_of(b, "msg-\{k}", whole=true) |> ignore })
          b.box(fn(w) {
            w.words_runs(By(fn() { [plain("row\{key()} alpha beta")] }), ink=0x333333FFL, look~) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  t.press_at(10.0, 11.0)
  t.run_for(long_press_ms)
  t.release(10.0, 11.0)
  t.draw()
  guard picked_now() is Some(p0) else { fail("expected finger pick") }
  assert_true(p0.finger && p0.text != "", msg="finger pick: \{Repr(p0)}")
  assert_false(t.text_menu().0, msg="system menu suppressed by picked_bar")
  t.wheel(150.0, 100.0, 600.0)
  t.run_for(move_most_ms)
  assert_eq(picked_now(), None)
  assert_eq(t.ctx().selected_text(), p0.text)
  assert_false(t.text_menu().0, msg="system menu still suppressed while scrolled away")
  t.wheel(150.0, 100.0, -600.0)
  t.run_for(move_most_ms)
  assert_eq(t.ctx().selected_text(), p0.text)
  assert_eq(picked_now().map(fn(p) { (p.text, p.finger) }), Some((p0.text, true)))
  assert_false(t.text_menu().0)
}
