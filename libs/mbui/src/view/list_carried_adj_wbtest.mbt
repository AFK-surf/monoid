// Regression tests for carried-in row interactions in `View::scrolls_window` (`flips=true`):
// 1. A carried-in row `m` followed in the same fresh run by a normal new row `s` must push `s`'s
//    starting y past `m` (including when `m` is paired from rest via `flip_rebuild`), without
//    pushing `s` below the viewport bottom in a full `from_end` list.
// 2. When a second carried-in row supersedes a first carried-in row (at once or mid-flight), the
//    superseded row must keep full scale (1.0) and remain unclipped and non-overlapping while the
//    second row's flight runs to completion.

///|
let ca_at : Double = 100.5

///|
let ca_flight_ms : Double = 400.0

///|
let ca_rates : Array[Double] = [0.0, 120.0, 60.0, 24.0, 7.0]

///|
fn ca_flight(ms : Double) -> Flight {
  { way: fn(_) { (ms, fn(t) { if t >= ms { 1.0 } else { t / ms } }) } }
}

///|
fn ca_drawn_of(t : Tree, words : String) -> Drawn? {
  match t.drawn().filter(fn(d) { d.words == words }) {
    [d, ..] => Some(d)
    _ => None
  }
}

///|
fn ca_slot_at(t : Tree, at : Int) -> Int {
  let mut cur = at
  while cur >= 0 {
    if t.nodes[cur].each_row {
      return cur
    }
    cur = t.nodes[cur].parent
  }
  -1
}

///|
/// Build a 300x400 `flips=true` list with `initial` keys (40 tall each).
/// Keys in `carried_keys` render a 40-tall flying box ("飞k") above a 20-tall static box ("标k")
/// inside a 60-tall block; all other keys render a 40-tall static box ("行k").
fn ca_list(
  initial : Array[Int],
  carried_keys : Array[Int],
  from_end? : Bool = false,
) -> (Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(initial, same=fn(a, b) { a == b })
  let scroll = Scroll::list()
  let tree = Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(scroll, fn() { keys.get() }, est=40.0, follows=fn() { true }, from_end~, flips=true, fn(b, k) {
        if carried_keys.contains(k) {
          b.box(fn(w) {
            w.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("飞\{k}")) |> ignore
            w.flies_in(ca_flight(ca_flight_ms), fn(to) { Some((0.0, 380.0, to.2, to.3)) }, up_late=0.12) |> ignore
          })
          |> ignore
          b.box(fn(l) { l.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("标\{k}")) |> ignore }) |> ignore
        } else {
          b.height(Is(Some(40.0))).shrink(Is(0.0)).words(Is("行\{k}")) |> ignore
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
/// Step `t` from `from` through `until` at `rate` fps (0 = 10 ms sample steps), running any
/// scheduled actions at their exact times, and call `check(ms)` after every frame from `from`.
fn ca_walk(
  t : Tree,
  events : Array[(Double, () -> Unit)],
  from : Double,
  until : Double,
  rate : Double,
  check : (Double) -> Unit raise,
) -> Unit raise {
  let step = if rate > 0.0 { 1000.0 / rate } else { 10.0 }
  let mut ev = 0
  let mut ms = from
  while ms <= until + 1.0e-6 {
    while ev < events.length() && events[ev].0 <= ms + 1.0e-9 {
      t.advance(events[ev].0)
      (events[ev].1)()
      ev = ev + 1
    }
    t.frame(390.0, 844.0, now=ms) |> ignore
    check(ms)
    ms = ms + step
  }
}

///|
test "flips: carried row followed by normal fresh row in short list from rest never overlaps" {
  for rate in ca_rates {
    let (t, keys) = ca_list([0, 1], [70], from_end=false)
    let mut saw_visible_s = false
    ca_walk(
      t,
      [(ca_at, fn() { keys.set([0, 1, 70, 71]) })],
      ca_at,
      ca_at + ca_flight_ms + 120.0,
      rate,
      fn(ms) raise {
        match (ca_drawn_of(t, "标70"), ca_drawn_of(t, "行71")) {
          (Some(dm), Some(ds)) =>
            if ds.alpha > 0.01 {
              saw_visible_s = true
              assert_true(
                ds.y >= dm.y + dm.h - 0.01,
                msg="short list at \{rate} fps, t=\{ms - ca_at}: 行71 y=\{ds.y} overlaps 标70 bottom=\{dm.y + dm.h} (alpha=\{ds.alpha})",
              )
            }
          _ => ()
        }
      },
    )
    assert_true(saw_visible_s, msg="short list at \{rate} fps: 行71 never became visible")
    match (ca_drawn_of(t, "标70"), ca_drawn_of(t, "行71")) {
      (Some(dm), Some(ds)) =>
        assert_true(
          (ds.y - (dm.y + dm.h)).abs() < 0.5,
          msg="short list at \{rate} fps: resting 行71 y=\{ds.y}, want \{dm.y + dm.h}",
        )
      _ => assert_true(false, msg="short list at \{rate} fps: missing resting rows")
    }
  }
}

///|
test "flips: carried row followed by normal fresh row in full from_end list stays in viewport and never overlaps" {
  for rate in ca_rates {
    let initial = Array::makei(10, fn(i) { i })
    let next = initial.copy()
    next.push(70)
    next.push(71)
    let (t, keys) = ca_list(initial, [70], from_end=true)
    let mut saw_visible_s = false
    ca_walk(
      t,
      [(ca_at, fn() { keys.set(next) })],
      ca_at,
      ca_at + ca_flight_ms + 120.0,
      rate,
      fn(ms) raise {
        match (ca_drawn_of(t, "标70"), ca_drawn_of(t, "行71")) {
          (Some(dm), Some(ds)) =>
            if ds.alpha > 0.01 {
              saw_visible_s = true
              assert_true(
                ds.y >= dm.y + dm.h - 0.01,
                msg="full from_end at \{rate} fps, t=\{ms - ca_at}: 行71 y=\{ds.y} overlaps 标70 bottom=\{dm.y + dm.h}",
              )
              assert_true(
                ds.y <= 400.0 + 0.01,
                msg="full from_end at \{rate} fps, t=\{ms - ca_at}: 行71 y=\{ds.y} started below viewport 400",
              )
            }
          _ => ()
        }
      },
    )
    assert_true(saw_visible_s, msg="full from_end at \{rate} fps: 行71 never became visible")
    match (ca_drawn_of(t, "标70"), ca_drawn_of(t, "行71")) {
      (Some(dm), Some(ds)) =>
        assert_true(
          (ds.y - (dm.y + dm.h)).abs() < 0.5,
          msg="full from_end at \{rate} fps: resting 行71 y=\{ds.y}, want \{dm.y + dm.h}",
        )
      _ => assert_true(false, msg="full from_end at \{rate} fps: missing resting rows")
    }
  }
}

///|
test "flips: two carried rows inserted at once keep the superseded first row unscaled, unclipped, and non-overlapping" {
  for full in [false, true] {
    for rate in ca_rates {
      let initial = if full { Array::makei(10, fn(i) { i }) } else { [0, 1] }
      let prev_label = if full { "行9" } else { "行1" }
      let next = initial.copy()
      next.push(70)
      next.push(71)
      let (t, keys) = ca_list(initial, [70, 71], from_end=full)
      let prev_y0 = match ca_drawn_of(t, prev_label) {
        Some(d) => d.y
        None => -1.0
      }
      let tag = "at-once two carried (full=\{full}, rate=\{rate})"
      let mut saw_m1 = false
      ca_walk(
        t,
        [(ca_at, fn() { keys.set(next) })],
        ca_at,
        ca_at + ca_flight_ms + 120.0,
        rate,
        fn(ms) raise {
          if ca_drawn_of(t, "标70") is Some(dm1) {
            saw_m1 = true
            let slot1 = ca_slot_at(t, dm1.id.at)
            assert_true(slot1 >= 0, msg="\{tag} t=\{ms - ca_at}: missing slot for 标70")
            assert_true(
              (t.nodes[slot1].look.scale - 1.0).abs() < 1.0e-6,
              msg="\{tag} t=\{ms - ca_at}: superseded m1 scale=\{t.nodes[slot1].look.scale}, want 1.0",
            )
            assert_true(
              !t.nodes[slot1].look.clips,
              msg="\{tag} t=\{ms - ca_at}: superseded m1 slot unexpectedly clipped",
            )
            assert_true(
              (dm1.alpha - 1.0).abs() < 0.001,
              msg="\{tag} t=\{ms - ca_at}: superseded m1 alpha=\{dm1.alpha}, want 1.0",
            )
            let m1_top = dm1.y - 40.0
            if !full {
              if ca_drawn_of(t, prev_label) is Some(dp) {
                assert_true(
                  dp.y + dp.h <= m1_top + 0.01,
                  msg="\{tag} t=\{ms - ca_at}: \{prev_label} bottom=\{dp.y + dp.h} overlaps m1 top=\{m1_top}",
                )
              }
            }
            if ca_drawn_of(t, "标71") is Some(dm2) {
              let m2_top = dm2.y - 40.0
              assert_true(
                dm1.y + dm1.h <= m2_top + 0.01,
                msg="\{tag} t=\{ms - ca_at}: m1 bottom=\{dm1.y + dm1.h} overlaps m2 top=\{m2_top}",
              )
            }
          }
        },
      )
      assert_true(saw_m1, msg="\{tag}: m1 never drawn")
      match (ca_drawn_of(t, prev_label), ca_drawn_of(t, "标70"), ca_drawn_of(t, "标71")) {
        (Some(dp), Some(dm1), Some(dm2)) => {
          assert_true(
            dp.y + dp.h <= dm1.y - 40.0 + 0.01,
            msg="\{tag} rest: \{prev_label} bottom=\{dp.y + dp.h} overlaps m1 top=\{dm1.y - 40.0}",
          )
          assert_true(
            dm1.y + dm1.h <= dm2.y - 40.0 + 0.01,
            msg="\{tag} rest: m1 bottom=\{dm1.y + dm1.h} overlaps m2 top=\{dm2.y - 40.0}",
          )
          if full {
            assert_true(
              ((prev_y0 - dp.y) - 120.0).abs() < 1.0,
              msg="\{tag}: \{prev_label} rose \{prev_y0 - dp.y}, want 120.0",
            )
          }
        }
        _ => assert_true(false, msg="\{tag}: missing rows at rest")
      }
    }
  }
}

///|
test "flips: second carried row arriving back-to-back or mid-flight keeps first row unscaled and unclipped while second flight completes" {
  for full in [false, true] {
    for gap in [0.0, 80.0] {
      for rate in ca_rates {
        let initial = if full { Array::makei(10, fn(i) { i }) } else { [0, 1] }
        let prev_label = if full { "行9" } else { "行1" }
        let with_m1 = initial.copy()
        with_m1.push(70)
        let with_both = with_m1.copy()
        with_both.push(71)
        let (t, keys) = ca_list(initial, [70, 71], from_end=full)
        let prev_y0 = match ca_drawn_of(t, prev_label) {
          Some(d) => d.y
          None => -1.0
        }
        let tag = "two carried full=\{full}, gap=\{gap}, rate=\{rate}"
        let second_at = ca_at + gap
        let mut saw_m1_after = false
        let mut mid_y = -1.0
        let mid_target = second_at + ca_flight_ms * 0.5
        ca_walk(
          t,
          [(ca_at, fn() { keys.set(with_m1) }), (second_at, fn() { keys.set(with_both) })],
          ca_at,
          second_at + ca_flight_ms + 120.0,
          rate,
          fn(ms) raise {
            if ms >= second_at - 1.0e-6 {
              if full && mid_y < 0.0 && ms >= mid_target {
                if ca_drawn_of(t, prev_label) is Some(dp) {
                  mid_y = dp.y
                }
              }
              if ca_drawn_of(t, "标70") is Some(dm1) {
                saw_m1_after = true
                let slot1 = ca_slot_at(t, dm1.id.at)
                assert_true(slot1 >= 0, msg="\{tag} t=\{ms - ca_at}: missing slot for 标70")
                assert_true(
                  (t.nodes[slot1].look.scale - 1.0).abs() < 1.0e-6,
                  msg="\{tag} t=\{ms - ca_at}: superseded m1 scale=\{t.nodes[slot1].look.scale}, want 1.0",
                )
                assert_true(
                  !t.nodes[slot1].look.clips,
                  msg="\{tag} t=\{ms - ca_at}: superseded m1 slot unexpectedly clipped",
                )
                assert_true(
                  (dm1.alpha - 1.0).abs() < 0.001,
                  msg="\{tag} t=\{ms - ca_at}: superseded m1 alpha=\{dm1.alpha}, want 1.0",
                )
                let m1_top = dm1.y - 40.0
                if !full {
                  if ca_drawn_of(t, prev_label) is Some(dp) {
                    assert_true(
                      dp.y + dp.h <= m1_top + 0.01,
                      msg="\{tag} t=\{ms - ca_at}: \{prev_label} bottom=\{dp.y + dp.h} overlaps m1 top=\{m1_top}",
                    )
                  }
                  if ca_drawn_of(t, "标71") is Some(dm2) {
                    let m2_top = dm2.y - 40.0
                    assert_true(
                      dm1.y + dm1.h <= m2_top + 0.01,
                      msg="\{tag} t=\{ms - ca_at}: m1 bottom=\{dm1.y + dm1.h} overlaps m2 top=\{m2_top}",
                    )
                  }
                }
              }
            }
          },
        )
        assert_true(saw_m1_after, msg="\{tag}: m1 never drawn after second carried row")
        match (ca_drawn_of(t, prev_label), ca_drawn_of(t, "标70"), ca_drawn_of(t, "标71")) {
          (Some(dp), Some(dm1), Some(dm2)) => {
            assert_true(
              dp.y + dp.h <= dm1.y - 40.0 + 0.01,
              msg="\{tag} rest: \{prev_label} bottom=\{dp.y + dp.h} overlaps m1 top=\{dm1.y - 40.0}",
            )
            assert_true(
              dm1.y + dm1.h <= dm2.y - 40.0 + 0.01,
              msg="\{tag} rest: m1 bottom=\{dm1.y + dm1.h} overlaps m2 top=\{dm2.y - 40.0}",
            )
            if full {
              assert_true(
                ((prev_y0 - dp.y) - 120.0).abs() < 1.0,
                msg="\{tag}: \{prev_label} rose \{prev_y0 - dp.y}, want 120.0",
              )
              assert_true(
                mid_y > dp.y + 5.0 && mid_y < prev_y0 - 5.0,
                msg="\{tag}: \{prev_label} mid-flight y=\{mid_y}, start=\{prev_y0}, rest=\{dp.y}",
              )
            }
          }
          _ => assert_true(false, msg="\{tag}: missing rows at rest")
        }
      }
    }
  }
}
