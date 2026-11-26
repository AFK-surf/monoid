// A column's blocks of one kind taken by those that come to show as others no more do (View::scrolls_window's
// `reused`): 100 tall, 30 blocks of 40, 50 or 60 (by their keys) counted as 80 before they are first laid out; how many
// are made, which block holds which key, and where.

///|
priv struct ReuseCase {
  tree : @view.Tree
  scroll : @view.Scroll
  on : @signals.Signal[Bool]
  /// how many blocks were made, how many live now
  made : Ref[Int]
  live : Ref[Int]
  /// each live block with what says its key now
  blocks : Array[(@view.View, () -> Int)]
  /// what each block's width reads besides, and how many times one was worked out of it
  outside : @signals.Signal[Int]
  reads : Ref[Int]
}

///|
fn reuse_case() -> ReuseCase {
  let scroll = @view.Scroll::list()
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let made = Ref(0)
  let live = Ref(0)
  let blocks : Array[(@view.View, () -> Int)] = []
  let outside = @signals.signal(0, same=fn(a, b) { a == b })
  let reads = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.show(at_once=true, fn() { on.get() }, fn(s) {
      s.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore
        o.scrolls_window(
          scroll,
          fn() { Array::makei(30, fn(i) { i }) },
          est=80.0,
          fn(_, _) { @halt.saying("every block is of a kind another may take") },
          reused=fn(_) { Some(0) },
          make_reused=fn(b, key) {
            made.val = made.val + 1
            live.val = live.val + 1
            blocks.push((b, key))
            b.owns(fn() {
              live.val = live.val - 1
              match blocks.search_by(fn(x) { physical_equal(x.1, key) }) {
                Some(i) => blocks.remove(i) |> ignore
                None => ()
              }
            })
            |> ignore
            b.height(By(fn() { Some(reuse_tall(key())) })) |> ignore
            b.width(By(fn() {
              reads.val = reads.val + 1
              Some(200.0 + outside.get().to_double())
            }))
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
  tree.frame(390.0, 844.0) |> ignore
  { tree, scroll, on, made, live, blocks, outside, reads }
}

///|
/// How tall block `k` is.
fn reuse_tall(k : Int) -> Double {
  40.0 + (k % 3).to_double() * 10.0
}

///|
/// Where block `k` stands in the column.
fn reuse_top(k : Int) -> Double {
  let mut y = 0.0
  for i in 0..<k {
    y = y + reuse_tall(i)
  }
  y
}

///|
/// The blocks that show (held by the column, a key each), their keys in order, each where its key's block is.
fn ReuseCase::placed(self : ReuseCase) -> (Array[Int], Bool) {
  let at = self.scroll.at(self.tree)
  let keys = []
  let mut placed = true
  for b in self.blocks {
    let (v, key) = b
    guard v.parent() is Some(_) else { continue }
    let k = key()
    keys.push(k)
    let (_, y, _, h) = v.rect()
    if y != reuse_top(k) - at || h != reuse_tall(k) {
      placed = false
    }
  }
  keys.sort()
  (keys, placed)
}

///|
test "scrolls_window reused: scrolled down a block at a time, those that leave taken by those that come, each where its key's is" {
  let c = reuse_case()
  let first = (c.made.val, c.placed())
  // (a wheel's twelve turns of 40, each at its moment, each drawn)
  for t in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 110.0, 120.0] {
    c.tree.wheel_at(150.0, 50.0, 0.0, 40.0, 0, t) |> ignore
    c.tree.frame(390.0, 844.0) |> ignore
  }
  let (keys, placed) = c.placed()
  // (made: those that showed first, and no more than one put by for each that came at once)
  assert_true(c.made.val <= 6, msg="made \{c.made.val}")
  assert_eq((first.1, placed, keys.length() >= 2, keys[0] <= 11 && keys[keys.length() - 1] >= 10), (([0, 1, 2], true), true, true, true))
}

///|
test "scrolls_window reused: those put by and those that show let go with the column" {
  let c = reuse_case()
  // (a wheel's six turns of 120, each at its moment, each drawn)
  for t in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0] {
    c.tree.wheel_at(150.0, 50.0, 0.0, 120.0, 0, t) |> ignore
    c.tree.frame(390.0, 844.0) |> ignore
  }
  assert_true(c.live.val > 0)
  c.on.set(false)
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.live.val, 0)
}

///|
test "scrolls_window reused: those put by follow nothing, those that show what they bind" {
  let c = reuse_case()
  // (a wheel's turn of 40: the first, 40 tall, no more shows, put by)
  c.tree.wheel_at(150.0, 50.0, 0.0, 40.0, 0, 10.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  // (those in sight: those put by are left where they were, out of it)
  let showing = c.blocks
    .filter(fn(b) {
      let (_, y, _, h) = b.0.rect()
      y + h > 0.0 && y < 100.0
    })
    .length()
  let before = c.reads.val
  c.outside.set(1)
  c.tree.frame(390.0, 844.0) |> ignore
  // (worked out again for the two that show, none for the one put by)
  assert_eq((c.reads.val - before, showing, c.live.val), (2, 2, 3))
}

///|
test "scrolls_window reused: what a block taken for another key shows or no more shows by that key is so at once, as were the block made anew, no way made in or closed" {
  let scroll = @view.Scroll::list()
  let blocks : Array[@view.View] = []
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { Array::makei(30, fn(i) { i }) },
        est=50.0,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          blocks.push(b)
          b.box(fn(line) {
            line.height(Is(Some(40.0))) |> ignore
          })
          |> ignore
          // (a line shown by its key alone: every other block has it)
          b.show(fn() { key() % 2 == 1 }, fn(s) {
            s.box(fn(more) { more.height(Is(Some(10.0))) |> ignore }) |> ignore
          })
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  // (a wheel's twelve turns of 40, each at its moment, each drawn: blocks taken by keys odd where theirs were even)
  for t in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0, 110.0, 120.0] {
    tree.wheel_at(150.0, 50.0, 0.0, 40.0, 0, t) |> ignore
    tree.frame(390.0, 844.0) |> ignore
  }
  let ways = blocks.filter(fn(b) { b.alive() && b.comes_end() >= 0.0 }).length()
  assert_eq(ways, 0, msg="blocks whose line made its way in or closed as they were taken for another key")
}

///|
test "scrolls_window reused: blocks taken for other keys by a wheel, the mark put back with each change: a show elsewhere after them makes its way in" {
  let scroll = @view.Scroll::list()
  let more = @signals.signal(false)
  let shown : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(col) {
      col.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore
        o.scrolls_window(
          scroll,
          fn() { Array::makei(30, fn(i) { i }) },
          est=50.0,
          fn(_, _) { @halt.saying("every block is of a kind another may take") },
          reused=fn(_) { Some(0) },
          make_reused=fn(b, key) {
            b.show(fn() { key() % 2 == 1 }, fn(s) { s.box(fn(l) { l.height(Is(Some(10.0))) |> ignore }) |> ignore })
            b.box(fn(line) { line.height(Is(Some(40.0))) |> ignore }) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
      col.show(fn() { more.get() }, fn(s) {
        shown.val = Some(s)
        s.box(fn(l) { l.height(Is(Some(30.0))) |> ignore }) |> ignore
      })
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  for t in [10.0, 20.0, 30.0, 40.0, 50.0, 60.0] {
    tree.wheel_at(150.0, 50.0, 0.0, 40.0, 0, t) |> ignore
    tree.frame(390.0, 844.0) |> ignore
  }
  assert_true(!@view.answer_marks_left())
  more.set(true)
  tree.frame(390.0, 844.0) |> ignore
  let came = match shown.val {
    Some(v) => v.comes_end()
    None => -1.0
  }
  assert_true(came >= 0.0, msg="the show after the wheel's blocks made no way in: \{came}")
}

///|
test "scrolls_window reused: a block taken for another key as the column's fill runs in a frame's layout draws its new key's words in that frame" {
  let scroll = @view.Scroll::list()
  // (each block's line with what says its key)
  let lines : Array[(@view.View, () -> Int)] = []
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { Array::makei(40, fn(i) { i }) },
        est=22.0,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          b.box(fn(line) {
            lines.push((line, key))
            line.height(Is(Some(22.0))).words(By(fn() { "row \{key()}" })) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  // (one turn of 400: the window 18 rows down in one go, what it takes taken as the frame lays the column out)
  tree.wheel_at(150.0, 50.0, 0.0, 400.0, 0, 10.0) |> ignore
  tree.frame(390.0, 844.0) |> ignore
  let wrong = []
  let mut seen = 0
  for l in lines {
    let (line, key) = l
    guard line.alive() else { continue }
    let (_, y, _, h) = line.rect()
    guard y + h > 0.0 && y < 200.0 else { continue }
    seen = seen + 1
    let k = @signals.untracked(key)
    match tree.drawn_of(line.id()) {
      Some(d) if d.words == "row \{k}" => ()
      Some(d) => wrong.push("key \{k} drawn \{d.words}")
      None => wrong.push("key \{k} not drawn")
    }
  }
  assert_eq((seen > 0, wrong), (true, []))
}

///|
test "scrolls_window reused: a taller spare block in a slot whose height is forgotten on width change is parked and does not overflow est" {
  let scroll = @view.Scroll::list()
  let box_w = @signals.signal(300.0)
  let lines : Array[(@view.View, () -> Int)] = []
  let mut made_blocks = 0
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(By(fn() { Some(box_w.get()) })).height(Is(Some(100.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { [0, 1, 2, 3, 4, 5] },
        est=40.0,
        fn(_, _) { @halt.saying("every block is of a kind another may take") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made_blocks = made_blocks + 1
          b.box(fn(pad) {
            pad.height(By(fn() { Some(if key() == 0 { 90.0 } else { 10.0 }) })) |> ignore
          })
          |> ignore
          b.box(fn(line) {
            lines.push((line, key))
            line.height(Is(Some(30.0))).words(By(fn() { "row \{key()}" })) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  // (row 0 measured 120; scroll 130 so row 0 [0..120] leaves sight and sits put by in its slot while row 1..4 show)
  tree.wheel_at(150.0, 50.0, 0.0, 130.0, 0, 10.0) |> ignore
  tree.frame(390.0, 844.0) |> ignore
  let made_after_down = made_blocks
  // (width changes: unshown row 0's height 120 is forgotten, shrinking its slot to est=40 just above row 1; row 0's
  // 120-tall spare view must be parked rather than overflowing 80px out of its 40px slot over row 1 and row 2)
  box_w.set(280.0)
  tree.frame(390.0, 844.0) |> ignore
  let mut row0_drawn = false
  for l in lines {
    let (line, _) = l
    if line.alive() {
      match tree.drawn_of(line.id()) {
        Some(d) if d.words == "row 0" => row0_drawn = true
        _ => ()
      }
    }
  }
  assert_eq(row0_drawn, false)
  // (scrolling back to top reuses the parked spare block without making a new one)
  tree.wheel_at(140.0, 50.0, 0.0, -130.0, 0, 20.0) |> ignore
  tree.frame(390.0, 844.0) |> ignore
  for l in lines {
    let (line, _) = l
    if line.alive() {
      match tree.drawn_of(line.id()) {
        Some(d) if d.words == "row 0" => row0_drawn = true
        _ => ()
      }
    }
  }
  assert_eq((row0_drawn, made_blocks), (true, made_after_down))
}

///|
test "scrolls_window reused: split reorder and row deletion recycle into spare without linear block growth" {
  let scroll = @view.Scroll::list()
  let init = Array::makei(20, fn(i) { i })
  let keys = @signals.signal(init, same=fn(a, b) { a == b })
  let made = Ref(0)
  let live = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        reorders=fn(_) { true },
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made.val = made.val + 1
          live.val = live.val + 1
          b.owns(fn() { live.val = live.val - 1 }) |> ignore
          b.height(Is(Some(40.0))).words(By(fn() { "row \{key()}" })) |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  let made0 = made.val
  let mut cur = init
  // First reorder: move key 5 to index 1 (below anchor 0, inside viewport) so S_new opens in view while S_old leaves;
  // after exit completes, S_old's block recycles into spare.
  let next0 = [cur[0], 5]
  for x in cur {
    if x != cur[0] && x != 5 {
      next0.push(x)
    }
  }
  cur = next0
  keys.set(cur)
  tree.frame(390.0, 844.0, now=100.0) |> ignore
  tree.frame(390.0, 844.0, now=700.0) |> ignore
  // Row deletion: delete visible row 2 -> leaving slot disposes and recycles its block into spare.
  cur = cur.filter(fn(x) { x != 2 })
  keys.set(cur)
  tree.frame(390.0, 844.0, now=800.0) |> ignore
  tree.frame(390.0, 844.0, now=1400.0) |> ignore
  let made_after_first = made.val
  // Six more consecutive split reorders into index 1: each reuses recycled spare blocks rather than growing linearly.
  for pick_at in [(4, 1500.0), (5, 2200.0), (6, 2900.0), (3, 3600.0), (4, 4300.0), (5, 5000.0)] {
    let pick = cur[pick_at.0]
    let next = [cur[0], pick]
    for x in cur {
      if x != cur[0] && x != pick {
        next.push(x)
      }
    }
    cur = next
    keys.set(cur)
    tree.frame(390.0, 844.0, now=pick_at.1) |> ignore
    tree.frame(390.0, 844.0, now=pick_at.1 + 600.0) |> ignore
  }
  assert_true(made.val <= made_after_first + 1, msg="made0=\{made0} after_first=\{made_after_first} final=\{made.val}")
  // Verify index 1 visible row draws cur[1] at y=40
  let moved_words = "row \{cur[1]}"
  let drawn_summary = tree.drawn().map(fn(d) { "\{d.words}@\{d.y}" }).join(", ")
  assert_true(
    tree.drawn().iter().any(fn(d) { d.words == moved_words && (d.y - 40.0).abs() < 1.0 }),
    msg="expected \{moved_words} at y=40; drawn=[\{drawn_summary}]",
  )
  tree.dispose()
  assert_eq(live.val, 0)
}

///|
test "scrolls_window reused: ms <= 0 come_wake double-rest wakes cleanly for new key" {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(12, fn(i) { i }), same=fn(a, b) { a == b })
  let ext = @signals.signal(0, same=fn(a, b) { a == b })
  let made = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        reorders=fn(_) { true },
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made.val = made.val + 1
          b.height(Is(Some(40.0))) |> ignore
          b.box(fn(line) {
            line.height(Is(Some(40.0))).words(By(fn() { "k=\{key()} ext=\{ext.get()}" })) |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  // Trigger split reorder into index 1 (leaving slot closes via View::comes with ms <= 0 -> sets come_wake = Some(slot.rests())).
  keys.set([0, 3, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
  tree.frame(390.0, 844.0, now=100.0) |> ignore
  tree.frame(390.0, 844.0, now=700.0) |> ignore
  let made_before_new = made.val
  // Insert a brand new key 99 at index 1 (inside viewport) so it takes the recycled block from spare.
  keys.set([0, 99, 3, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11])
  tree.frame(390.0, 844.0, now=800.0) |> ignore
  tree.frame(390.0, 844.0, now=1400.0) |> ignore
  assert_eq(made.val, made_before_new, msg="expected new key 99 to reuse spare block")
  let drawn2 = tree.drawn().map(fn(d) { "\{d.words}@\{d.y}" }).join(", ")
  assert_true(tree.drawn().iter().any(fn(d) { d.words == "k=99 ext=0" }), msg="reused block did not draw new key; drawn=[\{drawn2}]")
  // Mutate external signal to prove both come_wake and park wake restored active subscriptions.
  ext.set(1)
  tree.frame(390.0, 844.0, now=1416.0) |> ignore
  assert_true(tree.drawn().iter().any(fn(d) { d.words == "k=99 ext=1" }), msg="reused block stayed resting after double wake")
  tree.dispose()
}

///|
test "scrolls_window reused: lives_with overlay stays hidden while parked in spare, reappears on take_in, hides on second leave" {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal([0, 1, 2, 3, 4, 5, 6, 7], same=fn(a, b) { a == b })
  let pressed = Ref(0)
  let made = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    let layer = root.box(fn(l) { l.over(Is(true)) |> ignore })
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=40.0,
        reorders=fn(_) { true },
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made.val = made.val + 1
          b.height(Is(Some(40.0))).words(By(fn() { "item-\{key()}" })) |> ignore
          layer
          .box(fn(tip) {
            tip
            .width(Is(Some(50.0)))
            .height(Is(Some(20.0)))
            .words(By(fn() { "tip-\{key()}" }))
            .presses(Is(true))
            .on_press(fn() { pressed.val = pressed.val + 1 })
            |> ignore
          })
          .lives_with(b)
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  assert_true(tree.drawn().iter().any(fn(d) { d.words == "tip-2" }), msg="tip-2 initially drawn")
  // Split reorder key 2 to index 1 -> its leaving slot closes and tells its subtree leaving -> old tip-2 hides.
  keys.set([0, 2, 1, 3, 4, 5, 6, 7])
  tree.frame(390.0, 844.0, now=100.0) |> ignore
  tree.frame(390.0, 844.0, now=116.0) |> ignore
  let tip2_mid = tree.drawn().filter(fn(d) { d.words == "tip-2" }).length()
  assert_true(tip2_mid <= 1, msg="S_old overlay must hide mid-leave, got \{tip2_mid}")
  // Finish leaving animation: S_old's block for key 2 is parked into spare with needs_back = true.
  // Its parked overlay MUST stay hidden (only S_new's single tip-2 is drawn) while parked in spare!
  tree.frame(390.0, 844.0, now=700.0) |> ignore
  tree.frame(390.0, 844.0, now=720.0) |> ignore
  let tip2_count = tree.drawn().filter(fn(d) { d.words == "tip-2" }).length()
  assert_eq(tip2_count, 1, msg="parked S_old overlay must stay hidden while parked in spare, got \{tip2_count}")
  let made_before_reuse = made.val
  // Insert new key 99 at index 1 (inside viewport): takes parked block from spare -> take_in + tell_back_reused restores overlay!
  keys.set([0, 99, 2, 1, 3, 4, 5, 6, 7])
  tree.frame(390.0, 844.0, now=800.0) |> ignore
  tree.frame(390.0, 844.0, now=1400.0) |> ignore
  assert_eq(made.val, made_before_reuse, msg="key 99 should reuse parked block")
  let drawn3 = tree.drawn().map(fn(d) { "\{d.words}@\{d.y}" }).join(", ")
  assert_true(tree.drawn().iter().any(fn(d) { d.words == "tip-99" }), msg="tip-99 must reappear after take_in; drawn=[\{drawn3}]")
  let tip99 = tree.drawn().iter().find_first(fn(d) { d.words == "tip-99" }).unwrap()
  let pressed_before = pressed.val
  assert_true(tree.press(tip99.x + 5.0, tip99.y + 5.0), msg="tip-99 must be hit-testable after take_in")
  assert_true(pressed.val > pressed_before, msg="tip-99 press handler must fire")
  // Second leave: split reorder key 99 to index 3 -> its leaving slot hides its overlay again and parks cleanly.
  keys.set([0, 2, 1, 99, 3, 4, 5, 6, 7])
  tree.frame(390.0, 844.0, now=1500.0) |> ignore
  tree.frame(390.0, 844.0, now=1516.0) |> ignore
  let tip99_mid = tree.drawn().filter(fn(d) { d.words == "tip-99" }).length()
  assert_true(tip99_mid <= 1, msg="second leave S_old overlay must hide mid-leave, got \{tip99_mid}")
  tree.frame(390.0, 844.0, now=2100.0) |> ignore
  let tip99_count = tree.drawn().filter(fn(d) { d.words == "tip-99" }).length()
  assert_eq(tip99_count, 1, msg="second leave parked overlay must stay hidden, got \{tip99_count}")
  tree.dispose()
}

///|
test "scrolls_window reused: split overlap race where S_new leaves before S_old finishes preserves S_new state, height and read_from" {
  let scroll = @view.Scroll::list()
  let keys = @signals.signal(Array::makei(20, fn(i) { i }), same=fn(a, b) { a == b })
  let block_flags : Array[(@view.View, () -> Int, @signals.Signal[Bool])] = []
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=50.0,
        reorders=fn(_) { true },
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          let flag = b.reused_bool(default=false)
          block_flags.push((b, key, flag))
          b.box(fn(pad) {
            pad.height(By(fn() { Some(if flag.get() { 30.0 } else { 10.0 }) })) |> ignore
          })
          |> ignore
          b.box(fn(body) {
            body
            .read_from()
            .height(By(fn() { Some(if flag.get() { 50.0 } else { 30.0 }) }))
            .words(By(fn() { "r-\{key()}-\{flag.get()}" }))
            |> ignore
          })
          |> ignore
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  // Reorder key 3 to index 1 (below anchor 0, inside viewport): S_old (at index 3) starts leaving while S_new (at index 1) presents key 3.
  let moved : Array[Int] = [0, 3]
  for i in 1..<20 {
    if i != 3 {
      moved.push(i)
    }
  }
  keys.set(moved)
  tree.frame(390.0, 844.0, now=100.0) |> ignore
  tree.frame(390.0, 844.0, now=116.0) |> ignore
  // Both S_old and S_new are alive for key 3; mutate S_new's flag to true (height 80, read_from 30) while S_old keeps false (height 40, read_from 10).
  let live_k3 : Array[@signals.Signal[Bool]] = []
  for entry in block_flags {
    let (v, key, flag) = entry
    if v.alive() && @signals.untracked(key) == 3 {
      live_k3.push(flag)
    }
  }
  assert_true(live_k3.length() >= 2, msg="expected both S_old and S_new alive for key 3, got \{live_k3.length()}")
  live_k3[live_k3.length() - 1].set(true)
  tree.frame(390.0, 844.0, now=132.0) |> ignore
  // Scroll far down while S_old is STILL leaving: S_new scrolls out first and saves flag=true to kept[3].
  tree.wheel_at(150.0, 100.0, 0.0, 450.0, 0, 140.0) |> ignore
  tree.frame(390.0, 844.0, now=150.0) |> ignore
  // Now let S_old finish its leaving animation AFTER S_new has already left!
  tree.frame(390.0, 844.0, now=750.0) |> ignore
  // Scroll back to top: key 3 returns (reusing from spare). It MUST have S_new's state (flag=true, height 80, read_from 30).
  tree.wheel_at(150.0, 100.0, 0.0, -450.0, 0, 760.0) |> ignore
  tree.frame(390.0, 844.0, now=780.0) |> ignore
  let drawn4 = tree.drawn().map(fn(d) { "\{d.words}@\{d.y}" }).join(", ")
  assert_true(tree.drawn().iter().any(fn(d) { d.words == "r-3-true" }), msg="S_old overwrote S_new kept state for key 3; drawn=[\{drawn4}]")
  let mut h3 = 0.0
  let mut y3 = 0.0
  for entry in block_flags {
    let (v, key, _) = entry
    if v.alive() && v.parent() is Some(_) && @signals.untracked(key) == 3 {
      let r = v.rect()
      y3 = r.1
      h3 = r.3
    }
  }
  assert_eq(h3, 80.0, msg="expected S_new height 80.0 for key 3")
  let body3 = tree.drawn().iter().find_first(fn(d) { d.words == "r-3-true" }).unwrap()
  assert_true((body3.y - y3 - 30.0).abs() < 0.5, msg="expected S_new read_from offset 30.0, got \{body3.y - y3}")
  tree.dispose()
}

///|
test "scrolls_window reused: whole-list disposal after split reorders leaks nothing" {
  let scroll = @view.Scroll::list()
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let keys = @signals.signal(Array::makei(15, fn(i) { i }), same=fn(a, b) { a == b })
  let live = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.show(at_once=true, fn() { on.get() }, fn(s) {
      s.box(fn(o) {
        o.width(Is(Some(300.0))).height(Is(Some(200.0))) |> ignore
        o.scrolls_window(
          scroll,
          fn() { keys.get() },
          est=40.0,
          reorders=fn(_) { true },
          fn(_, _) { @halt.saying("every block is reused") },
          reused=fn(_) { Some(0) },
          make_reused=fn(b, key) {
            live.val = live.val + 1
            b.owns(fn() { live.val = live.val - 1 }) |> ignore
            b.height(Is(Some(40.0))).words(By(fn() { "w-\{key()}" })) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  keys.set([4, 0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
  tree.frame(390.0, 844.0, now=100.0) |> ignore
  tree.frame(390.0, 844.0, now=700.0) |> ignore
  // Start a second split reorder and dispose whole list mid-animation while spare also holds parked blocks.
  keys.set([6, 4, 0, 1, 2, 3, 5, 7, 8, 9, 10, 11, 12, 13, 14])
  tree.frame(390.0, 844.0, now=800.0) |> ignore
  assert_true(live.val > 0)
  on.set(false)
  tree.frame(390.0, 844.0, now=816.0) |> ignore
  assert_eq(live.val, 0)
  assert_eq(tree.kept_said(), None)
  assert_true(!@view.answer_marks_left())
  tree.dispose()
}

///|
fn home_reorder_bench_once() -> (Int, Int, Int, Int) {
  let scroll = @view.Scroll::list()
  let init = Array::makei(50, fn(i) { i })
  let keys = @signals.signal(init, same=fn(a, b) { a == b })
  let made_blocks = Ref(0)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(500.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { keys.get() },
        est=56.0,
        reorders=fn(_) { true },
        fn(_, _) { @halt.saying("every block is reused") },
        reused=fn(_) { Some(0) },
        make_reused=fn(b, key) {
          made_blocks.val = made_blocks.val + 1
          let pinned = b.reused_bool(default=false)
          b.height(Is(Some(56.0))) |> ignore
          b.box(fn(r) {
            r.row(Is(true)) |> ignore
            r.box(fn(av) { av.width(Is(Some(36.0))).height(Is(Some(36.0))) |> ignore }) |> ignore
            r.box(fn(col) {
              col.box(fn(t) { t.height(Is(Some(20.0))).words(By(fn() { "Chat \{key()}" })) |> ignore }) |> ignore
              col.box(fn(sub) { sub.height(Is(Some(18.0))).words(By(fn() { "Preview \{key()} \{pinned.get()}" })) |> ignore })
              |> ignore
            })
            |> ignore
            r.box(fn(meta) {
              meta.box(fn(tm) { tm.height(Is(Some(16.0))).words(By(fn() { "\{key()}m" })) |> ignore }) |> ignore
              meta.show(fn() { key() % 3 == 0 }, fn(badge) {
                badge.width(Is(Some(18.0))).height(Is(Some(18.0))).words(Is("1")) |> ignore
              })
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
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  let w0 = tree.work()
  let m0 = made_blocks.val
  let mut cur = init
  for pick_at in [
    (6, 100.0),
    (8, 800.0),
    (2, 1500.0),
    (4, 2200.0),
    (6, 2900.0),
    (8, 3600.0),
    (2, 4300.0),
    (4, 5000.0),
    (6, 5700.0),
    (8, 6400.0),
  ] {
    let pick = cur[pick_at.0]
    let next : Array[Int] = [cur[0], pick]
    for x in cur {
      if x != cur[0] && x != pick {
        next.push(x)
      }
    }
    cur = next
    keys.set(cur)
    tree.frame(390.0, 844.0, now=pick_at.1) |> ignore
    tree.frame(390.0, 844.0, now=pick_at.1 + 16.0) |> ignore
    tree.frame(390.0, 844.0, now=pick_at.1 + 120.0) |> ignore
    tree.frame(390.0, 844.0, now=pick_at.1 + 600.0) |> ignore
  }
  let w1 = tree.work()
  let res = (made_blocks.val - m0, w1.made - w0.made, w1.let_go - w0.let_go, w1.structure - w0.structure)
  tree.dispose()
  res
}

///|
test "scrolls_window reused: 50-row Home reorder burst reuses blocks with bounded allocations" {
  let (blocks_made, nodes_made, nodes_let_go, structures) = home_reorder_bench_once()
  assert_true(
    blocks_made <= 2 && nodes_made <= 30 && nodes_let_go <= 20 && structures <= 35,
    msg="blocks_made=\{blocks_made} nodes_made=\{nodes_made} let_go=\{nodes_let_go} structures=\{structures}",
  )
}
