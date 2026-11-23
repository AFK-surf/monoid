// What of the window's tree's words is picked, as a page made of nodes reads it (tree_picked.mbt): a quote's pill over
// where the pointer let it go (View::beside by picked_end_piece), shown once it is let go, its press keeping what is
// picked (keeps_picked) and letting it go in its handler (picked_let_go); what each paragraph is of (picked_of); a
// finger's, the app's own item of the system's text menu over it (picked_menu).

///|
/// Two rows of words in a page whose words are picked, 40 apart from 40 down, the first's said of "m1", the second's of
/// "m2", each 300 wide; a pill 40 by 20 over where what is picked ends, 8 off, while a mouse's pick of the tree's words
/// stands, its press putting what it quotes in `took` (what is picked, what of) and letting it go; the page offering
/// 引用 in the system's text menu over a finger's pick of one row's words, doing the same. On `platform`. The Tester, the two rows' words'
/// nodes, and the pill's, once made (`pill`).
fn quote_tester(
  took : Array[(String, Array[String])],
  pill : Ref[@view.NodeId?],
  platform? : Int = 0,
) -> (Tester, @view.NodeId, @view.NodeId) {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform~)
  t.check_looks(false)
  let words : Array[@view.NodeId] = []
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((0.0, 40.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      picked_menu(page, fn(p) {
        guard p.of.length() == 1 else { return [] }
        [
          (
            "引用",
            fn() {
              match picked_now() {
                Some(p) => took.push((p.text, p.of))
                None => took.push(("", []))
              }
              picked_let_go()
            },
          ),
          ("复制链接", fn() { took.push(("link", p.of)) }),
        ]
      })
      |> ignore
      for of in ["m1", "m2"] {
        page.box(fn(row) {
          picked_of(row, of) |> ignore
          row.height(Is(Some(40.0))) |> ignore
          row.box(fn(n) {
            words.push(n.id())
            n
            .width(Is(Some(300.0)))
            .words_runs(Is(picked_runs), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      }
      page.show(fn() { picked_now() is Some(p) && !p.finger }, fn(holds) {
        guard @signals.untracked(fn() { picked_now() }) is Some(p) else { return }
        holds.box(fn(b) {
          pill.val = Some(b.id())
          keeps_picked(b)
          .width(Is(Some(40.0)))
          .height(Is(Some(20.0)))
          .ground(Is(0x112233FFL))
          .says(Is(Some(@view.said(Button, label="引用"))))
          .beside(p.ends_in, side=Top, offset=8.0, piece=picked_end_piece(p))
          .on_press(fn() {
            match picked_now() {
              Some(p) => took.push((p.text, p.of))
              None => took.push(("", []))
            }
            picked_let_go()
          })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  (t, words[0], words[1])
}

///|
test "words of the tree's dragged over with the mouse: what is picked read by a node once let go (its words, what they are of, the node it ends in), none while dragged; a pill beside where it ends; pressed, what is picked kept, and let go by its handler" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, first, _) = quote_tester(took, pill)
  let tree = view_app.val.unwrap()
  // (dragged over all the first row's words, held: none yet)
  t.fake.time = t.time()
  finger(0, 1.0, 51.0)
  t.fake.time = t.fake.time + input_step_ms
  finger(1, 300.0, 51.0)
  t.frame_at(t.fake.time)
  assert_eq(t.ctx().selected_text(), "hello wide world")
  assert_eq(picked_now(), None)
  assert_eq(pill.val, None)
  // (let go)
  t.fake.time = t.fake.time + input_step_ms
  finger(2, 300.0, 51.0)
  t.frame_at(t.fake.time)
  let p = picked_now().unwrap()
  assert_eq((p.text, p.of, p.ends_in, p.finger), ("hello wide world", ["m1"], first, false))
  // (the pill: its middle at the right end of what is drawn picked, its foot 8 over its line's top)
  let id = pill.val.unwrap()
  let d = tree.drawn_of(id).unwrap()
  let (px, py, pw, ph) = (d.x, d.y, d.w, d.h)
  let drawn = picked_drawn(t)
  assert_eq(drawn.length(), 1)
  let (rx, ry, rw, _) = drawn[0]
  assert_true(
    (px + pw / 2.0 - (rx + rw)).abs() < 0.01 && (py + ph - (ry - 8.0)).abs() < 0.01,
    msg="pill at \{Repr((px, py, pw, ph))}, picked drawn at \{Repr(drawn[0])}",
  )
  // (pressed: what is picked kept as it goes down; its handler took it and let it go)
  let (cx, cy) = (px + pw / 2.0, py + ph / 2.0)
  t.fake.time = t.fake.time + double_click_ms
  finger(0, cx, cy)
  t.frame_at(t.fake.time)
  assert_eq(t.ctx().selected_text(), "hello wide world")
  t.fake.time = t.fake.time + input_step_ms
  finger(2, cx, cy)
  t.frame_at(t.fake.time)
  assert_eq(took, [("hello wide world", ["m1"])])
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_now(), None)
  assert_eq(picked_drawn(t).length(), 0)
}

///|
test "words of the tree's dragged over from one row into the next: what each is of, in order, it ending in the second; a press elsewhere lets it go" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, _, second) = quote_tester(took, pill)
  let next = dragged_at(t, 1.0, 51.0, 300.0, 91.0, t.time(), true)
  t.frame_at(next)
  let p = picked_now().unwrap()
  assert_eq((p.text, p.of, p.ends_in), ("hello wide world\nhello wide world", ["m1", "m2"], second))
  // (pressed where nothing keeps it: let go)
  let next = dragged_at(t, 350.0, 250.0, 350.0, 250.0, next + double_click_ms, true)
  t.frame_at(next)
  assert_eq(picked_now(), None)
  assert_eq(took.length(), 0)
}

///|
test "a mouse's pick says whether it was let go at the start or end of a line" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, _, _) = quote_tester(took, pill)
  let (x, y, w, h) = t.run_rects("hello wide world")[0]
  let (start, end, mid) = (x + 1.0, x + w - 1.0, y + h / 2.0)
  let next = dragged_at(t, start, mid, end, mid, t.time(), true)
  t.frame_at(next)
  guard picked_now() is Some(forward) else { @halt.saying("no forward pick") }
  assert_true(forward.text.contains("wide"))
  assert_false(forward.ends_at_start)
  let next = dragged_at(t, end, mid, start, mid, next + double_click_ms, true)
  t.frame_at(next)
  guard picked_now() is Some(backward) else { @halt.saying("no backward pick") }
  assert_true(backward.text.contains("wide"))
  assert_true(backward.ends_at_start)
}

///|
test "words of the tree's a finger held still on: once lifted, the system's text menu over them offers the page's own item after copy and select all, and no pill; chosen, it is done and they are let go" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, first, _) = quote_tester(took, pill, platform=2)
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  t.release(60.0, 51.0)
  t.draw()
  let p = picked_now().unwrap()
  assert_eq((p.text, p.of, p.ends_in, p.finger), ("wide", ["m1"], first, true))
  let (shown, _, _, _, _, can) = t.text_menu()
  assert_true(shown)
  assert_eq(can, @hostapi.text_menu_copy | @hostapi.text_menu_select_all | @hostapi.text_menu_own_item)
  assert_eq(t.text_menu_own(), ["引用", "复制链接"])
  assert_eq(pill.val, None)
  t.key(@hostapi.key_menu_own)
  assert_eq(took, [("wide", ["m1"])])
  assert_eq(t.ctx().selected_text(), "")
  assert_eq(picked_now(), None)
  assert_false(t.text_menu().0)
}

///|
test "words of the tree's a finger picked across two rows: the page offers no item of its own for them, the system's text menu copy and select all alone" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, _, _) = quote_tester(took, pill, platform=2)
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  t.release(60.0, 51.0)
  t.draw()
  assert_eq(t.text_menu().5, @hostapi.text_menu_copy | @hostapi.text_menu_select_all | @hostapi.text_menu_own_item)
  // (all of them: the system's select all)
  t.key(key_code_select_all)
  let p = picked_now().unwrap()
  assert_eq(p.of, ["m1", "m2"])
  let (shown, _, _, _, _, can) = t.text_menu()
  assert_true(shown)
  assert_eq(can, @hostapi.text_menu_copy | @hostapi.text_menu_select_all)
  assert_eq(took.length(), 0)
}

///|
test "words of the tree's that take no press over an old view whose box takes a press there (a page's message over 小屏's shell): a finger held still on them picks the word, the old view's press called off, nothing of it pressed" {
  let pressed = Ref(0)
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  t.check_looks(false)
  set_view_app(fn(root) {
    root.box(fn(b) {
      b.over(Is(true)).width(Is(Some(400.0))).height(Is(Some(300.0))) |> ignore
      old(b, fn(c) {
        let here = c.id("old box")
        c.on_press(here, fn() { pressed.val = pressed.val + 1 })
        c.box(id=here, w=Fill(1.0), h=Fill(1.0), fn() { c.text("old words") |> ignore }) |> ignore
      }).grow(Is(1.0))
      |> ignore
    })
    |> ignore
    root.box(fn(page) {
      page.over(Is(true)).width(Is(Some(400.0))).height(Is(Some(300.0))).ground(Is(0xFFFFFFFFL)) |> ignore
      page.padding(Is((0.0, 40.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      page.box(fn(n) {
        n
        .width(Is(Some(300.0)))
        .words_runs(Is(picked_runs), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let tree = view_app.val.unwrap()
  assert_true(tree.target_at(60.0, 51.0) is Hosted(_), msg="the press there the old view's")
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  assert_eq(t.ctx().selected_text(), "wide")
  t.release(60.0, 51.0)
  t.draw()
  assert_eq(picked_now().map(fn(p) { (p.text, p.finger) }), Some(("wide", true)))
  assert_true(t.text_menu().0)
  assert_eq(pressed.val, 0)
}

///|
test "words a finger held still on the space between two words: the word before it picked, as a phone's text picks it; before the first word, the one after it; only space, none" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, _, _) = quote_tester(took, pill, platform=2)
  // (on the space after "hello", just past its "o": the space's own, not the start of "wide")
  let glyphs = t.drawn_instances().filter(fn(a) { a[5] == 1.0 && a[1] < 70.0 }).map(fn(a) { (a[0], a[2]) })
  glyphs.sort_by(fn(a, b) { a.0.compare(b.0) })
  let x = glyphs[4].0 + glyphs[4].1 + 0.5
  t.press_at(x, 51.0)
  t.run_for(long_press_ms)
  t.release(x, 51.0)
  t.draw()
  assert_eq(picked_now().map(fn(p) { p.text }), Some("hello"))
  // (the same rule on its own, in the text's units)
  assert_eq(finger_word_at("hello wide", 5), (0, 5))
  assert_eq(finger_word_at("  hi there", 0), (2, 4))
  assert_eq(finger_word_at("   ", 1), (0, 0))
  assert_eq(finger_word_at("hello wide", 7), (6, 10))
}

///|
test "words of the tree's a finger picked: the page's items in the system's text menu in its order, each chosen by its own key, the second doing its own, what is picked kept where it keeps it" {
  let took : Array[(String, Array[String])] = []
  let pill : Ref[@view.NodeId?] = Ref(None)
  let (t, _, _) = quote_tester(took, pill, platform=2)
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  t.release(60.0, 51.0)
  t.draw()
  assert_eq(t.text_menu_own(), ["引用", "复制链接"])
  t.key(@hostapi.key_menu_own + 1)
  assert_eq(took, [("link", ["m1"])])
  assert_eq(t.ctx().selected_text(), "wide")
  // (one the page does not offer: nothing)
  t.key(@hostapi.key_menu_own + 2)
  assert_eq(took.length(), 1)
  t.key(@hostapi.key_menu_own)
  assert_eq(took, [("link", ["m1"]), ("wide", ["m1"])])
  assert_eq(picked_now(), None)
}

///|
test "words of the tree's a finger picked, then a press under them tapped: the tap lets go of what is picked and presses nothing; the next tap presses it" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2)
  t.check_looks(false)
  let pressed = Ref(0)
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.padding(Is((0.0, 40.0, 0.0, 0.0))).lines_up(Is(Some(Start))) |> ignore
      words_picked(page)
      page.box(fn(row) {
        picked_of(row, "m1") |> ignore
        row.height(Is(Some(40.0))) |> ignore
        row.box(fn(n) {
          n
          .width(Is(Some(300.0)))
          .words_runs(Is(picked_runs), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      page.box(fn(b) {
        b
        .width(Is(Some(120.0)))
        .height(Is(Some(60.0)))
        .ground(Is(0x112233FFL))
        .says(Is(Some(@view.said(Button, label="打开"))))
        .on_press(fn() { pressed.val = pressed.val + 1 })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.press_at(60.0, 51.0)
  t.run_for(long_press_ms)
  t.release(60.0, 51.0)
  t.draw()
  assert_true(picked_now() is Some(p) && p.finger, msg="the word a finger held still on picked")
  // (the press, under what is picked: 40 down, the row's 40, then its own 60)
  t.tap(60.0, 110.0)
  t.draw()
  assert_eq(picked_now(), None)
  assert_eq(pressed.val, 0)
  t.tap(60.0, 110.0)
  t.draw()
  assert_eq(pressed.val, 1)
}

///|
test "words of the tree's a finger picked in a column it scrolls, then a finger dragged up over a press there: the column scrolled, nothing pressed" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2, pointing=Finger)
  t.check_looks(false)
  let scroll = @view.Scroll::new()
  let pressed = Ref(0)
  set_view_app(fn(root) {
    root.box(fn(v) {
      words_picked(v)
      v
      .width(Is(Some(400.0)))
      .height(Is(Some(300.0)))
      .scrolls(scroll, slop=touch_slop(), fn(col) {
        col.box(fn(row) {
          picked_of(row, "m1") |> ignore
          row.height(Is(Some(40.0))) |> ignore
          row.box(fn(n) {
            n
            .width(Is(Some(300.0)))
            .words_runs(Is(picked_runs), ink=0x333333FFL, look={ size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 })
            |> ignore
          })
          |> ignore
        })
        |> ignore
        for i in 0..<10 {
          col.box(fn(r) {
            r
            .width(Is(Some(400.0)))
            .height(Is(Some(60.0)))
            .says(Is(Some(@view.said(Button, label="行 \{i}"))))
            .on_press(fn() { pressed.val += 1 })
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.press_at(60.0, 11.0)
  t.run_for(long_press_ms)
  t.release(60.0, 11.0)
  t.draw()
  assert_true(picked_now() is Some(p) && p.finger, msg="the word a finger held still on picked")
  // (a finger down on a row that is pressed, under what is picked, then dragged up past the slop)
  t.touch(0, 150.0, 200.0)
  t.run_for(finger_menu_tap_ms)
  t.touch(1, 150.0, 170.0)
  t.touch(1, 150.0, 120.0)
  t.run_for(finger_menu_tap_ms)
  t.touch(2, 150.0, 120.0)
  t.run_for(long_press_ms)
  assert_true(scroll.at(view_tree().unwrap()) > 0.0, msg="the column scrolled: \{scroll.at(view_tree().unwrap())}")
  assert_eq(pressed.val, 0)
}

///|
test "WordsPicked.within and strays: single message plus unowned paragraph reports strays > 0; hiding or destroying scope root drops picked_now and scope copy while keeping released selection until click elsewhere" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  let show_scope = @signals.signal(true)
  let hide_scope = @signals.signal(false)
  let left_view : Ref[@view.View?] = Ref(None)
  let right_view : Ref[@view.View?] = Ref(None)
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(400.0))) |> ignore
      row.show(at_once=true, fn() { show_scope.get() }, fn(slot) {
        slot.box(fn(left) {
          left.width(Is(Some(200.0))).laid_nowhere(By(fn() { hide_scope.get() })) |> ignore
          words_picked(left)
          left_view.val = Some(left)
          left.box(fn(m1) {
            picked_of(m1, "m1") |> ignore
            m1.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("owned msg")]), ink=0x333333FFL, look~) |> ignore })
            |> ignore
          })
          |> ignore
          left.box(fn(stray) {
            stray.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("unowned notice")]), ink=0x333333FFL, look~) |> ignore })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      row.box(fn(right) {
        right.width(Is(Some(200.0))) |> ignore
        words_picked(right)
        right_view.val = Some(right)
        right.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("other pane")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  let lv = left_view.val.unwrap()
  let rv = right_view.val.unwrap()
  // Drag across owned msg + unowned notice
  let next1 = dragged_at(t, 2.0, 10.0, 160.0, 34.0, t.time(), true)
  t.frame_at(next1)
  guard picked_now_in(lv) is Some(p) else { fail("expected picked_now_in(left)") }
  assert_eq(p.of, ["m1"])
  assert_eq(p.strays, 1)
  assert_eq(picked_now_in(rv), None)
  assert_eq(picked_words_in(rv), "")
  assert_true(picked_words_in(lv).contains("owned msg"))
  let kept1 = t.ctx().selected_text()
  assert_true(kept1.contains("owned msg"))
  // Hide scope root via laid_nowhere: drops picked_now and scope/point copy, keeps released selection until click elsewhere
  hide_scope.set(true)
  t.draw()
  assert_eq(picked_now(), None)
  assert_eq(picked_now_in(lv), None)
  assert_eq(picked_words_in(lv), "")
  assert_eq(picked_words_at(50.0, 10.0), "")
  assert_eq(t.ctx().selected_text(), kept1)
  t.tap(300.0, 150.0)
  t.draw()
  assert_eq(t.ctx().selected_text(), "")
  // Re-show, select again, then destroy scope root: drops picked_now and scope/point copy, keeps released selection until click elsewhere
  hide_scope.set(false)
  t.draw()
  let next2 = dragged_at(t, 2.0, 10.0, 80.0, 10.0, t.time(), true)
  t.frame_at(next2)
  assert_true(picked_now() is Some(_))
  let kept2 = t.ctx().selected_text()
  assert_true(kept2.length() > 0)
  show_scope.set(false)
  t.draw()
  assert_eq(picked_now(), None)
  assert_eq(picked_now_in(lv), None)
  assert_eq(picked_words_in(lv), "")
  assert_eq(picked_words_at(50.0, 10.0), "")
  assert_eq(t.ctx().selected_text(), kept2)
  t.tap(300.0, 150.0)
  t.draw()
  assert_eq(t.ctx().selected_text(), "")
}

///|
test "finger_select_all stays within scope, drops stale spans outside target set, and respects inner picked_of(whole=false)" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2, pointing=Finger)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(row) {
      row.row(Is(true)).width(Is(Some(400.0))) |> ignore
      row.box(fn(left) {
        left.width(Is(Some(200.0))) |> ignore
        words_picked(left)
        left.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("alpha beta")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
        left.box(fn(outer_whole) {
          picked_of(outer_whole, "outer", whole=true) |> ignore
          outer_whole.box(fn(inner_not_whole) {
            picked_of(inner_not_whole, "inner", whole=false) |> ignore
            inner_not_whole.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("gamma delta")]), ink=0x333333FFL, look~) |> ignore })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
      row.box(fn(right) {
        right.width(Is(Some(200.0))) |> ignore
        words_picked(right)
        right.box(fn(n) { n.width(Is(Some(180.0))).words_runs(Is([plain("neighbor words")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Long press on "gamma" (in inner picked_of whole=false nested under whole=true)
  t.press_at(16.0, 32.0)
  t.run_for(long_press_ms)
  t.release(16.0, 32.0)
  t.draw()
  assert_eq(t.ctx().selected_text(), "gamma")
  // Select all: because inner is whole=false, selects all of left scope (alpha beta + gamma delta) and NEVER neighbor words
  picked_select_all()
  t.draw()
  assert_eq(t.ctx().selected_text(), "alpha beta\ngamma delta")
  assert_true(!t.ctx().selected_text().contains("neighbor"))
}

///|
test "finger_select_all on a whole=true message drops stale spans from other paragraphs outside the message" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=2, pointing=Finger)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(page) {
      page.width(Is(Some(300.0))) |> ignore
      words_picked(page)
      page.box(fn(m1) {
        picked_of(m1, "m1", whole=true) |> ignore
        m1.box(fn(n) { n.width(Is(Some(280.0))).words_runs(Is([plain("first part")]), ink=0x333333FFL, look~) |> ignore }) |> ignore
        m1.box(fn(n) { n.width(Is(Some(280.0))).words_runs(Is([plain("second part")]), ink=0x333333FFL, look~) |> ignore }) |> ignore
      })
      |> ignore
      page.box(fn(stray) {
        stray.box(fn(n) { n.width(Is(Some(280.0))).words_runs(Is([plain("stray outside")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  // Long press on "second" in m1 (y=32) and slide down into "stray outside" (y=54)
  t.press_at(16.0, 32.0)
  t.run_for(long_press_ms)
  t.move_to(120.0, 54.0)
  t.draw()
  t.release(120.0, 54.0)
  t.draw()
  assert_true(t.ctx().selected_text().contains("stray"), msg="before select_all: \{t.ctx().selected_text()}")
  // Select all: m1 is whole=true, so only m1's paragraphs stay and stale "stray outside" span is dropped
  picked_select_all()
  t.draw()
  assert_eq(t.ctx().selected_text(), "first part\nsecond part")
}

///|
test "picked_words_at returns empty inside a nested apart=true sub-scope even though the point lies inside the outer scope rect" {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=300.0, platform=0)
  t.check_looks(false)
  let look : @view.WordsLook = { size: 15.0, weight: 400, line: 22.0, wrap: true, tracking: @view.letters_own, balance: false, max_lines: 0 }
  set_view_app(fn(root) {
    root.box(fn(outer) {
      outer.width(Is(Some(360.0))).height(Is(Some(200.0))).gap(Is(8.0)) |> ignore
      words_picked(outer)
      outer.box(fn(n) { n.width(Is(Some(300.0))).words_runs(Is([plain("outer words here")]), ink=0x333333FFL, look~) |> ignore })
      |> ignore
      outer.box(fn(sub) {
        sub.width(Is(Some(300.0))).height(Is(Some(80.0))).ground(Is(0xEEEEEEFFL)) |> ignore
        words_picked(sub, apart=true)
        sub.box(fn(n) { n.width(Is(Some(280.0))).words_runs(Is([plain("nested apart words")]), ink=0x333333FFL, look~) |> ignore })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.drawn_now()
  // Select in outer scope (y=0..22)
  let next = dragged_at(t, 1.0, 10.0, 160.0, 10.0, t.time(), true)
  t.frame_at(next)
  let sel = t.ctx().selected_text()
  assert_true(sel.contains("outer"), msg="selected outer: \{sel}")
  // Point inside outer scope (y=10) returns selection
  assert_eq(picked_words_at(50.0, 10.0), sel)
  // Point inside nested apart=true sub-scope (y=50, still inside outer's 0..200 rect) must return ""
  assert_eq(picked_words_at(50.0, 50.0), "")
}
