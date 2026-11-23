// A key coming by data whose block holds what flies in from outside the tree (View::flies_in: one's own words sent,
// a picture from the composer's tile) is carried by that flight: the list's one way of that moment goes on the
// flight's rise, as long as it, and the block is drawn whole all the way, nothing said of it by the page (the user,
// 2026-11-10: 「字离开输入框的那一刻，消息行开始长、输入框开始收，同一条曲线同一时长」; 2026-11-15: a cause says where
// it comes from, the list does the rest). Looked at in one jump and at 60, 120, 24 and 7 a second (rc_walk).

///|
/// A flight `ms` long, linear: there at `ms`, half way at half of it.
fn cr_flight(ms : Double) -> @view.Flight {
  { way: fn(_) { (ms, fn(t) { if t >= ms { 1.0 } else { t / ms } }) } }
}

///|
/// A page's list 300 by 400 of rows 0 to 9 (40 each) following its foot; key 70 (60 high) comes by data, its words
/// in a box that flies in from the window's foot when `flies` (else nothing of it flies). Drawn once, at 0.
fn cr_case(flies : Bool, ms : Double, up_late : Double, flips? : Bool = false) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips~, fn(b, k) {
        if k == 70 {
          b.box(fn(w) {
            w.height(Is(Some(60.0))).words(Is("行70")) |> ignore
            if flies {
              w.flies_in(cr_flight(ms), fn(to) { Some((0.0, 380.0, to.2, to.3)) }, up_late~) |> ignore
            }
          })
          |> ignore
        } else {
          b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
test "a key whose block flies in is carried by its flight: what is over it goes up on the flight's rise, as long, at every rate" {
  let ms = 400.0
  for flips in [false, true] {
  for late in [0.0, 0.25] {
    for rate in rc_rates {
      let at = "flips \{flips}, rise \{late} late, at \{rate} a second"
      let (t, keys) = cr_case(true, ms, late, flips~)
      let looks = [rc_at, rc_at + ms * late / 2.0, rc_at + ms * (late + (1.0 - late) / 2.0), rc_at + ms, rc_at + ms + 200.0]
      let ys = rc_walk(t, [(rc_at, fn() { keys.set(rc_ten_and([70])) })], looks, rate, fn() { rc_y(t, "行8") })
      let rise = ys[0] - ys[4]
      assert_true((rise - 60.0).abs() < 1.0, msg="\{at}: 行8 up \{rise}, 60 wanted")
      // (none of its rise while the flight goes across alone)
      assert_true((ys[0] - ys[1]).abs() < 0.5, msg="\{at}: 行8 up \{ys[0] - ys[1]} before the flight's rise sets out")
      let half = (ys[0] - ys[2]) / rise
      assert_true((half - 0.5).abs() < 0.05, msg="\{at}: half way through its rise, \{half} of it")
      assert_true((ys[3] - ys[4]).abs() < 0.5, msg="\{at}: not at rest at the flight's end")
    }
  }
}
}

///|
test "flips: the words that fly in go only up and across to where they rest, never back down, at every rate" {
  let ms = 400.0
  for rate in rc_rates {
    let (t, keys) = cr_case(true, ms, 0.12, flips=true)
    let ys = rc_walk(t, [(rc_at, fn() { keys.set(rc_ten_and([70])) })], rc_looks(rc_at + ms + 100.0), rate, fn() {
      rc_y(t, "行70")
    })
    let mut last = 1.0e9
    for j, y in ys {
      if y != rc_none {
        assert_true(y <= last + 0.01, msg="at \{rate} a second, look \{j}: 行70 down from \{last} to \{y}")
        last = y
      }
    }
  }
}

///|
/// How opaque the words `w` are drawn now: 0 where none are drawn.
fn cr_alpha(t : @view.Tree, w : String) -> Double {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => d.alpha
    _ => 0.0
  }
}

///|
/// A page's list as cr_case's, flips on, keys 70 and 71 coming by data, each a box of its words that flies in from the
/// window's foot (`ms` long) over a line of its own that does not fly ("时k").
fn cr_two() -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        if k >= 70 {
          b.box(fn(w) {
            w.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
            w.flies_in(cr_flight(400.0), fn(to) { Some((0.0, 380.0, to.2, to.3)) }, up_late=0.12) |> ignore
          })
          |> ignore
          b.box(fn(l) { l.height(Is(Some(20.0))).words(Is("时\{k}")) |> ignore }) |> ignore
        } else {
          b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
test "flips: two flown in close together, the first's whole once its own flight is done, not hidden under the second's, at every rate" {
  let ms = 400.0
  for rate in rc_rates {
    let (t, keys) = cr_two()
    // (the second 150 into the first's flight; looked at past the first's end, before the second's)
    let looks = [rc_at + ms + 20.0, rc_at + ms + 60.0, rc_at + ms + 100.0, rc_at + 150.0 + ms + 100.0]
    let seen = rc_walk(
      t,
      [(rc_at, fn() { keys.set(rc_ten_and([70])) }), (rc_at + 150.0, fn() { keys.set(rc_ten_and([70, 71])) })],
      looks,
      rate,
      fn() { (cr_alpha(t, "行70"), cr_alpha(t, "时70")) },
    )
    for i, s in seen {
      assert_true((s.0 - 1.0).abs() < 0.001, msg="at \{rate} a second, look \{i}: 行70 drawn at \{s.0}, its flight done")
    }
    assert_true((seen[3].1 - 1.0).abs() < 0.001, msg="at \{rate} a second: 时70 at \{seen[3].1} once both are done")
  }
}

///|
test "flips: a flight longer than a Move, its list's first way, carries what is over it all the way, none of it let go part way, at every rate" {
  // (the first way set out binds the blocks, and that commit may carry the flight from within the way being told: its
  // rest is the flight's, never the Move's sooner one put back over it once that returns)
  let ms = 560.0
  for rate in rc_rates {
    let (t, keys) = cr_case(true, ms, 0.0, flips=true)
    let looks = [rc_at, rc_at + 350.0, rc_at + 450.0, rc_at + ms]
    let ys = rc_walk(t, [(rc_at, fn() { keys.set(rc_ten_and([70])) })], looks, rate, fn() { rc_y(t, "行8") })
    for j in [1, 2, 3] {
      let want = 60.0 * (looks[j] - rc_at) / ms
      let up = ys[0] - ys[j]
      assert_true((up - want).abs() < 1.0, msg="at \{rate} a second, \{looks[j] - rc_at} in: 行8 up \{up}, \{want} wanted")
    }
  }
  // (followed every 10: up only, by no more than the flight's own pace, never at once to where it rests)
  for rate in rc_rates {
    let (t, keys) = cr_case(true, ms, 0.0, flips=true)
    let ys = rc_walk(t, [(rc_at, fn() { keys.set(rc_ten_and([70])) })], rc_looks(rc_at + ms + 100.0), rate, fn() {
      rc_y(t, "行8")
    })
    for j in 1..<ys.length() {
      let step = ys[j - 1] - ys[j]
      assert_true(step >= -0.01, msg="at \{rate} a second, look \{j}: 行8 down by \{-step}")
      assert_true(step < 2.5, msg="at \{rate} a second, look \{j}: 行8 up \{step} at once")
    }
  }
}

///|
/// A page's list as cr_case's, flips on: key 60 (40 high) comes by data and does not fly; key 70 (60 high) comes by
/// data after it, its words in a box that flies in from the window's foot (`ms` long, its rise `up_late` late).
fn cr_after_move(ms : Double, up_late : Double) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, flips=true, fn(b, k) {
        if k == 70 {
          b.box(fn(w) {
            w.height(Is(Some(60.0))).words(Is("行70")) |> ignore
            w.flies_in(cr_flight(ms), fn(to) { Some((0.0, 380.0, to.2, to.3)) }, up_late~) |> ignore
          })
          |> ignore
        } else {
          b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
test "flips: words sent while the list's Move of a row come before is still going ride the flight's rise with what is over them, the gap between them only opening to where it rests, never closed again, at every rate" {
  // (the Move's tail taken up by the flight's way from where each is drawn, as a ComeGroup's curve takes all of its
  // group's way: never a Move of its own pulling the row over the words up while they wait out the rise's late start)
  let ms = 520.0
  for later in [65.0, 260.0] {
    for rate in rc_rates {
      let at = "sent \{later} into the Move, at \{rate} a second"
      let (t, keys) = cr_after_move(ms, 0.12)
      let sent = rc_at + later
      let seen = rc_walk(
        t,
        [(rc_at, fn() { keys.set(rc_ten_and([60])) }), (sent, fn() { keys.set(rc_ten_and([60, 70])) })],
        rc_looks(sent + ms + 100.0),
        rate,
        fn() { (rc_y(t, "行60"), rc_y(t, "行70")) },
      )
      let mut last = rc_none
      for j, s in seen {
        if s.0 == rc_none || s.1 == rc_none {
          continue
        }
        let gap = s.1 - s.0
        if last != rc_none {
          assert_true(gap >= last - 0.01, msg="\{at}, look \{j}: the gap under 行60 closed again from \{last} to \{gap}")
        }
        last = gap
      }
      assert_true((last - 40.0).abs() < 0.5, msg="\{at}: the gap under 行60 \{last} at rest, 40 wanted")
    }
  }
}
