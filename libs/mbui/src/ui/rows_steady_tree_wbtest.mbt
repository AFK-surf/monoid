// Rows steady on a page's list of the window's tree (View::scrolls_window): sizes_steady.mbt measures what is inside
// each row from the row's top, and rows_steady.mbt holds the rows' own places in the list.

///|
test "rows steady: a row in View::scrolls_window stepping height in one frame pushes the rows under it in one frame and is caught" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let tall = @signals.signal(40.0)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      col.scrolls_window(@view.Scroll::list(), fn() { [0, 1, 2] }, est=40.0, fn(b, k) {
        if k == 0 {
          b.width(Is(Some(200.0))).height(By(fn() { Some(tall.get()) })).ground(Is(0x334455FFL)).words(Is("首行")) |> ignore
        } else {
          b.width(Is(Some(200.0))).height(Is(Some(40.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  view_event(fn() { tall.set(90.0) })
  t.frame()
  t.frame()
  t.frame()
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_true(found.length() > 0, msg="expected rows_steady to catch a 1-frame row step in View::scrolls_window")
}

///|
test "rows steady: a page's list let go of and another made in its place (the pool's same index) is another list, its rows none of the one before's" {
  let which = @signals.signal(0)
  let t = Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  let lists : Array[@view.View] = []
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      // (a page replaced by another at once, as a stack's or a pane's are: the first's rows under a tall head, the
      // second's from its top)
      col.pick(at_once=true, fn() { which.get() }, fn(p, w) {
        p.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
        lists.push(
          p.scrolls_window(@view.Scroll::list(), fn() { [0, 1, 2] }, est=40.0, fn(b, k) {
            let h = if w == 0 && k == 0 { 160.0 } else { 40.0 }
            b.width(Is(Some(200.0))).height(Is(Some(h))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore
          }),
        )
      })
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  view_event(fn() { which.set(1) })
  t.frame()
  t.frame()
  t.frame()
  // (what this asks: the second list at the first's index, made anew)
  assert_eq(lists.length(), 2)
  assert_eq((lists[1].at == lists[0].at, lists[1].gen != lists[0].gen), (true, true))
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="a list made anew where one was let go of judged as that one")
}

///|
test "rows steady: a page's list held at its foot, its top pushed down from outside a little more each frame (what is over it opening its own way): its rows held where they show, no step of theirs" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let over = @signals.signal(0.0, same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      // (over the list, outside it: as tall as `over` says, each frame)
      col.box(fn(b) { b.width(Is(Some(300.0))).height(By(fn() { Some(over.get()) })) |> ignore }) |> ignore
      col.box(fn(lb) {
        lb.width(Is(Some(300.0))).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        lb.scrolls_window(
          @view.Scroll::list(),
          fn() { [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] },
          est=60.0,
          from_end=true,
          follows=fn() { true },
          fn(b, k) { b.width(Is(Some(200.0))).height(Is(Some(60.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  // (eased out from still: fast at first, as a way's first frames are)
  for h in [14.0, 26.0, 36.0, 44.0, 50.0, 54.0, 56.0, 56.0, 56.0] {
    view_event(fn() { over.set(h) })
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="rows held at the list's foot as its top is pushed down judged a step: \{Repr(found)}")
}

///|
test "rows steady: a page's list's rows out of sight guessed at a height, measured anew as they come into sight while the list grows over its foot: followed from the frame each shows, no step of theirs" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let over = @signals.signal(200.0, same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      // (over the list, outside it: shorter each frame, the list taller over its foot, its rows over those shown coming
      // into sight)
      col.box(fn(b) { b.width(Is(Some(300.0))).height(By(fn() { Some(over.get()) })) |> ignore }) |> ignore
      col.box(fn(lb) {
        lb.width(Is(Some(300.0))).grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
        lb.scrolls_window(
          @view.Scroll::list(),
          fn() { Array::makei(30, fn(i) { i }) },
          // (guessed at half as tall as each comes to be)
          est=40.0,
          from_end=true,
          follows=fn() { true },
          fn(b, k) { b.width(Is(Some(200.0))).height(Is(Some(80.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  for h in [186.0, 160.0, 130.0, 100.0, 72.0, 48.0, 28.0, 14.0, 6.0, 2.0, 0.0, 0.0] {
    view_event(fn() { over.set(h) })
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="rows coming into sight judged by where they were guessed out of sight: \{Repr(found)}")
}

///|
test "rows steady: a row's way come to rest (9 a frame, then none and none) is no stop on its way, whatever crumb of a point its sums leave" {
  let p = 1000.0 / 60.0
  let seen = [(0.0, 0.0, 503.0), (p, p, 512.0), (2.0 * p, 2.0 * p, 511.99999999999994), (3.0 * p, 3.0 * p, 512.0)]
  let (fault, _) = rows_steady_fault(seen, p, set_out=-1.0e9, turned=-1.0e9)
  assert_eq(fault, None)
}

///|
test "rows steady: keys that stay moved among a page's list's keys by data (reorders) close where they were and open where they are, taken again on their way going on from there, judged with no step at 60, 120 and 24 a second" {
  for rate in [60.0, 120.0, 24.0] {
    let keys = @signals.signal(Array::makei(10, fn(i) { i }), same=fn(a, b) { a == b })
    let t = Tester::new(fn(_c) {  }, w=300.0, h=400.0, platform=0)
    t.set_frame_period(1000.0 / rate)
    rows_steady_bars[rows_steady.file] = 0
    sizes_steady_bars[sizes_steady.file] = 99
    set_view_app(fn(root) {
      root.box(fn(col) {
        col.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
        col.scrolls_window(@view.Scroll::list(), fn() { keys.get() }, est=40.0, reorders=fn(_) { true }, fn(b, k) {
          b.width(Is(Some(200.0))).height(Is(Some(40.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    t.run_for(row_size_ms * 2.0)
    // (第0行 seen on its way: where it is drawn after each frame)
    let ys : Array[Double] = []
    t.each_frame(Some(fn() {
      match t.find("第0行") {
        Some((_, y)) => ys.push(y)
        None => ()
      }
    }))
    let up = fn(k : Int) {
      let now = keys.untracked()
      let out = [k]
      for x in now {
        if x != k {
          out.push(x)
        }
      }
      out
    }
    view_event(fn() { keys.set(up(5)) })
    // (the next while it is still on its way: two chats written in one after another)
    t.run_for(reorder_again_ms)
    view_event(fn() { keys.set(up(7)) })
    // (both ways over, and a while at rest)
    t.run_for(move_most_ms * 1.4)
    t.each_frame(None)
    let found : Array[String] = rows_steady.found.iter().collect()
    assert_eq(found, [], msg="at \{rate}: keys moved on their way judged a step: \{Repr(found)}")
    // (the rows it pushed went: 第0行 drawn at many places on its way, not at two)
    let places : Array[Double] = []
    for y in ys {
      if !places.iter().any(fn(p) { (p - y).abs() < 0.5 }) {
        places.push(y)
      }
    }
    assert_true(places.length() >= 4, msg="at \{rate}: 第0行 drawn at \{Repr(places)} only")
  }
}

///|
/// How long after one key is moved among a page's list's keys the next is, in the test of two (the first still on its
/// way then).
let reorder_again_ms : Double = 120.0

///|
test "rows steady: a list's way set out on a frame's own moment takes its speed up from rest over the frames from it, and a whole step in its frames is a step all the same" {
  let p = 1000.0 / 60.0
  let t0 = 3383.3333333333335
  // (a way set out at rest on the first frame's moment: 1.54, then 17.13 and 13.65 a frame as its curve has it)
  let seen = [(t0, t0, 482.65), (3400.0, 3400.0, 481.11), (3416.6666666666665, 3416.6666666666665, 463.98), (
    3433.3333333333335, 3433.3333333333335, 450.33,
  )]
  let (fault, _) = rows_steady_fault(seen, p, set_out=seen[0].1, turned=-1.0)
  assert_eq(fault, None)
  // (one frame going 34 between 1 and 2, the way set out on the first frame's moment all the same: a step)
  let step = [(t0, t0, 480.0), (3400.0, 3400.0, 479.0), (3416.6666666666665, 3416.6666666666665, 445.0), (
    3433.3333333333335, 3433.3333333333335, 443.0,
  )]
  let (fault, _) = rows_steady_fault(step, p, set_out=step[0].1, turned=-1.0)
  assert_true(fault is Some(_), msg="a step as the way set out")
}

///|
test "rows steady: a short list held at its foot (less than a screen of rows, nothing to scroll), its foot grown a little more each frame from outside (a composer opening its own way): the rows going up with it followed, no step of theirs" {
  // (frames it walks itself, judged by the default run alone: at a rate none of them is judged, test_at_a_rate)
  if test_at_a_rate() {
    return
  }
  let tall = @signals.signal(40.0, same=fn(a, b) { a == b })
  let t = Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  rows_steady_bars[rows_steady.file] = 99
  sizes_steady_bars[sizes_steady.file] = 99
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      col.scrolls_window(
        @view.Scroll::list(),
        fn() { [0, 1, 2] },
        est=40.0,
        from_end=true,
        follows=fn() { true },
        foot=fn(f) {
          f.box(fn(c) {
            c.width(Is(Some(300.0))).height(By(fn() { Some(tall.get()) })).shrink(Is(0.0)).words(Is("脚")) |> ignore
          })
          |> ignore
        },
        fn(b, k) { b.width(Is(Some(200.0))).height(Is(Some(40.0))).ground(Is(0x445566FFL)).words(Is("第\{k}行")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(row_size_ms * 2.0)
  t.frame()
  t.frame()
  // (eased out from still: fast at first, as a way's first frames are)
  for h in [54.0, 66.0, 76.0, 84.0, 90.0, 94.0, 96.0, 96.0, 96.0] {
    view_event(fn() { tall.set(h) })
    t.frame_as_host() |> ignore
  }
  let found : Array[String] = rows_steady.found.iter().collect()
  assert_eq(found, [], msg="rows going up with a short list's foot judged a step: \{Repr(found)}")
}
