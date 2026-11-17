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
