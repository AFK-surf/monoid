// What goes with what flies in (View::flies_in: a reply's time under one's own bubble sent) reads how far across its way
// that flight is where it is drawn (View::flight_across_now) and whether it is still on it (View::flying_now): one curve,
// one length, one clock, never a way of its own. A flight whose length its flight says by how far it goes
// (@motion.flight_scaled) is as long as it goes where it is laid out once its list's pinned foot's old view is built
// (Tree::flights_refresh_now: the composer giving its room back as the words leave it), not as it was before. And what in
// that foot said its height goes its way (View::resizes, `foot`) on no way of its own goes on the flight's rise with the
// rows over it, as long (Tree::feet_carried: the user, 2026-11-17, 发送回缩 on the rows' own curve).

///|
/// A flight `ms` long, linear.
fn fnw_flight(ms : Double) -> @view.Flight {
  { way: fn(_) { (ms, fn(t) { if t >= ms { 1.0 } else { t / ms } }) } }
}

///|
/// A flight as long as twice how far it goes (ms a point), linear.
fn fnw_far_flight() -> @view.Flight {
  { way: fn(far) { (2.0 * far, fn(t) { if t >= 2.0 * far { 1.0 } else { t / (2.0 * far) } }) } }
}

///|
/// How opaque the words `w` are drawn now (-1 where they are not drawn).
fn fnw_alpha(t : @view.Tree, w : String) -> Double {
  match t.drawn().filter(fn(d) { d.words == w }) {
    [d, ..] => d.alpha
    _ => -1.0
  }
}

///|
/// A page's list 300 by 400 of rows 0 to 9 (40 each) following its foot; key 70's block holds 行70 (60 tall), flying in
/// on a linear flight `ms` long from the window's foot, and under it 时, as opaque as that flight is across its way, 态,
/// a fifth as opaque while it flies, and 参, as opaque as all of the block; the list said `flips` or not. Drawn once, at 0.
fn fnw_case(ms : Double, flips : Bool) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(@view.Scroll::list(), fn() { keys.get() }, est=40.0, follows=fn() { true }, flips~, fn(b, k) {
        if k == 70 {
          let bubble : Ref[@view.View?] = Ref(None)
          b.box(fn(w) {
            bubble.val = Some(w)
            w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
            w.flies_in(fnw_flight(ms), fn(to) { Some((0.0, 380.0, to.2, to.3)) }) |> ignore
          })
          |> ignore
          b.box(fn(w) {
            w
            .height(Is(Some(10.0)))
            .shrink(Is(0.0))
            .words(Is("时"))
            .alpha(By(fn() { bubble.val.map(fn(v) { v.flight_across_now() }).unwrap_or(1.0) }))
            |> ignore
          })
          |> ignore
          b.box(fn(w) {
            w
            .height(Is(Some(10.0)))
            .shrink(Is(0.0))
            .words(Is("态"))
            .alpha(By(fn() { if bubble.val.map(fn(v) { v.flying_now() }).unwrap_or(false) { 0.2 } else { 1.0 } }))
            |> ignore
          })
          |> ignore
          b.box(fn(w) { w.height(Is(Some(10.0))).shrink(Is(0.0)).words(Is("参")) |> ignore }) |> ignore
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
test "flight_across_now and flying_now: what goes with what flies in is drawn by that flight's way, as long, at every look, in a list said flips or not" {
  for flips in [false, true] {
    let ms = 400.0
    let (t, keys) = fnw_case(ms, flips)
    t.event(rc_at, fn() { keys.set(rc_ten_and([70])) })
    let mut looked = 0
    for look in [0.0, 0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.25] {
      t.frame(390.0, 844.0, now=rc_at + look * ms) |> ignore
      // (as opaque as its block is drawn then: unseen while the block is under half open, as any key come)
      let whole = fnw_alpha(t, "参")
      // (in one said `flips`, a key a flight carries is open all the way, what of it does not fly seen whole all the way)
      if flips {
        assert_true((whole - 1.0).abs() < 0.01, msg="flips, at \{look} of the flight: 参 at \{whole}, 1 wanted")
      }
      guard whole > 0.01 else { continue }
      if look > 0.0 && look < 1.0 {
        looked = looked + 1
      }
      let across = fnw_alpha(t, "时")
      let flying = fnw_alpha(t, "态")
      let want = if look >= 1.0 { 1.0 } else { look }
      assert_true((across - want * whole).abs() < 0.01, msg="flips \{flips}, at \{look} of the flight: 时 at \{across}, \{want * whole} wanted")
      let fly_want = if look < 1.0 { 0.2 * whole } else { whole }
      assert_true((flying - fly_want).abs() < 0.01, msg="flips \{flips}, at \{look} of the flight: 态 at \{flying}, \{fly_want} wanted")
    }
    assert_true(looked >= 3, msg="flips \{flips}: its block drawn at \{looked} looks while it flies")
  }
}

///|
/// A page's list 300 by 400 of rows 0 to 9 (40 each) following its foot, said `flips`, its pinned foot an old view
/// hosted in the tree as tall as `foot` (90 at first); key 70's block 行70 (60 tall) flying in from (0, 380) on a flight
/// as long as twice how far it goes. Drawn once, at 0, the old view built.
fn fnw_old_case(foot : @signals.Signal[Double]) -> (@view.Tree, @signals.Signal[Array[Int]]) {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        flips=true,
        foot=fn(f) {
          f.hosted(make=fn(v) { v.height(By(fn() { Some(foot.get()) })).shrink(Is(0.0)) |> ignore }) |> ignore
        },
        fn(b, k) {
          if k == 70 {
            b.box(fn(w) {
              w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
              w.flies_in(fnw_far_flight(), fn(to) { Some((0.0, 380.0, to.2, to.3)) }) |> ignore
            })
            |> ignore
          } else {
            b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.old_views_building()
  tree.old_views_built()
  tree.frame(390.0, 844.0) |> ignore
  (tree, keys)
}

///|
test "flights_refresh_now: a flight as long as it goes, its list's foot's old view built shorter after it set out: as long as it goes from there" {
  let foot = @signals.signal(90.0, same=fn(a, b) { a == b })
  let (t, keys) = fnw_old_case(foot)
  // (the words sent: the key comes as the old view begins its build, its new height (30) laid only as it is built)
  t.event(rc_at, fn() {
    t.old_views_building()
    keys.set(rc_ten_and([70]))
  })
  t.event(rc_at, fn() {
    foot.set(30.0)
    t.old_views_built()
  })
  t.frame(390.0, 844.0, now=rc_at) |> ignore
  let ys = []
  let mut m = rc_at
  while m <= rc_at + 800.0 {
    t.frame(390.0, 844.0, now=m) |> ignore
    ys.push((m, rc_y(t, "行70")))
    m = m + 1.0
  }
  // (where it rests, and how far that is from where it flies from)
  let (rx, ry) = match t.drawn().filter(fn(d) { d.words == "行70" }) {
    [d, ..] => (d.x, d.y)
    _ => (0.0, rc_none)
  }
  let far = (rx * rx + (ry - 380.0) * (ry - 380.0)).sqrt()
  let mut came = -1.0
  for s in ys {
    if came < 0.0 && (s.1 - ry).abs() < 0.01 {
      came = s.0
    }
  }
  assert_true(
    (came - (rc_at + 2.0 * far)).abs() <= 2.0,
    msg="行70 at rest \{came - rc_at} after it set out, \{2.0 * far} wanted (twice how far it goes, \{far})",
  )
}

///|
test "feet_carried: what its pinned foot says resizes (foot) at the moment a key flies in goes on that flight's rise, as long" {
  for flips in [false, true] {
  let ms = 400.0
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tall = @signals.signal(90.0, same=fn(a, b) { a == b })
  let foot_box : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        flips~,
        foot=fn(f) {
          f.box(fn(c) {
            foot_box.val = Some(c)
            c.height(By(fn() { Some(tall.get()) })).shrink(Is(0.0)).words(Is("脚")) |> ignore
          })
          |> ignore
        },
        fn(b, k) {
          if k == 70 {
            b.box(fn(w) {
              w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
              w.flies_in(fnw_flight(ms), fn(to) { Some((0.0, 380.0, to.2, to.3)) }) |> ignore
            })
            |> ignore
          } else {
            b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  let h0 = match tree.drawn().filter(fn(d) { d.words == "脚" }) {
    [d, ..] => d.h
    _ => -1.0
  }
  assert_eq(h0, 90.0)
  // (the words sent: the key comes, and the foot gives back 60 of its height, said to go its way)
  tree.event(rc_at, fn() {
    keys.set(rc_ten_and([70]))
    match foot_box.val {
      Some(c) => c.resizes(foot=true) |> ignore
      None => ()
    }
    tall.set(30.0)
  })
  for look in [0.25, 0.5, 0.75] {
    tree.frame(390.0, 844.0, now=rc_at + look * ms) |> ignore
    let h = match tree.drawn().filter(fn(d) { d.words == "脚" }) {
      [d, ..] => d.h
      _ => -1.0
    }
    let gone = (90.0 - h) / 60.0
    assert_true((gone - look).abs() < 0.03, msg="flips \{flips}, at \{look} of the flight: the foot \{gone} of its way gone, \{look} wanted")
  }
  tree.frame(390.0, 844.0, now=rc_at + ms + 1.0) |> ignore
  let h1 = match tree.drawn().filter(fn(d) { d.words == "脚" }) {
    [d, ..] => d.h
    _ => -1.0
  }
  assert_true((h1 - 30.0).abs() < 0.01, msg="flips \{flips}: the foot \{h1} tall once the flight is over, 30 wanted")
  }
}

///|
/// How far one goes by its place alone, the most of across and down (a lead's `far_of`).
fn fnw_far_by_place(
  from : (Double, Double, Double, Double),
  to : (Double, Double, Double, Double),
) -> Double {
  let dx = (from.0 - to.0).abs()
  let dy = (from.1 - to.1).abs()
  if dx > dy {
    dx
  } else {
    dy
  }
}

///|
/// The moment the words `w` are first drawn within 0.01 of where and as tall as they rest, over `ys` (moment, y, h).
fn fnw_landed(ys : Array[(Double, Double, Double)], ry : Double, rh : Double) -> Double {
  for s in ys {
    if (s.1 - ry).abs() < 0.01 && (s.2 - rh).abs() < 0.01 {
      return s.0
    }
  }
  -1.0
}

///|
test "flies_in lead: what flies in on one Flight lands on its lead's length, the list's rise too, said anew as the foot's old view is built shorter" {
  let foot = @signals.signal(90.0, same=fn(a, b) { a == b })
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  // (one Flight, as long as twice how far it goes, linear: the picture's own measure would make it the longest)
  let flight = fnw_far_flight()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        flips=true,
        foot=fn(f) {
          f.hosted(make=fn(v) { v.height(By(fn() { Some(foot.get()) })).shrink(Is(0.0)) |> ignore }) |> ignore
        },
        fn(b, k) {
          if k == 70 {
            // (a picture grown from a thumbnail 10 by 10 at the window's foot to all the width, 150 tall: led)
            b.box(fn(w) {
              w.height(Is(Some(150.0))).shrink(Is(0.0)).words(Is("图")) |> ignore
              w.flies_in(flight, fn(_) { Some((0.0, 380.0, 10.0, 10.0)) }) |> ignore
            })
            |> ignore
            // (the words, as tall as they rest, leading by how far their place goes alone)
            b.box(fn(w) {
              w.height(Is(Some(60.0))).shrink(Is(0.0)).words(Is("行70")) |> ignore
              w.flies_in(flight, fn(to) { Some((0.0, 380.0, to.2, to.3)) }, far_of=fnw_far_by_place, lead=true)
              |> ignore
            })
            |> ignore
          } else {
            b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.old_views_building()
  tree.old_views_built()
  tree.frame(390.0, 844.0) |> ignore
  // (the words sent: the key comes in the press's change; the frame after it builds the old view in the foot, as a
  // host does (ui's view_host tells the tree its build began, then that it is built), its new height (30) laid only
  // as it is built)
  tree.event(rc_at, fn() { keys.set(rc_ten_and([70])) })
  tree.event(rc_at, fn() {
    tree.old_views_building()
    foot.set(30.0)
    tree.old_views_built()
  })
  let seen : Map[String, Array[(Double, Double, Double)]] = { "图": [], "行70": [], "行9": [] }
  let mut m = rc_at
  while m <= rc_at + 1200.0 {
    tree.frame(390.0, 844.0, now=m) |> ignore
    for d in tree.drawn() {
      match seen.get(d.words) {
        Some(a) => a.push((m, d.y, d.h))
        None => ()
      }
    }
    m = m + 1.0
  }
  let rest = fn(w : String) {
    match tree.drawn().filter(fn(d) { d.words == w }) {
      [d, ..] => (d.x, d.y, d.w, d.h)
      _ => (0.0, rc_none, 0.0, 0.0)
    }
  }
  // (the lead's length: twice how far its place goes from where it set out to where it rests, the foot built shorter)
  let (lx, ly, _, _) = rest("行70")
  let lead_ms = 2.0 * fnw_far_by_place((0.0, 380.0, 0.0, 0.0), (lx, ly, 0.0, 0.0))
  // (the picture's own length, which it would have gone on unled, much longer)
  let (px, py, pw, ph) = rest("图")
  let dx = px
  let dy = py - 380.0
  let own = (dx * dx + dy * dy).sqrt()
  let own = if (pw - 10.0).abs() > own { (pw - 10.0).abs() } else { own }
  let own = if (ph - 10.0).abs() > own { (ph - 10.0).abs() } else { own }
  assert_true(2.0 * own > lead_ms + 50.0, msg="the picture's own length \{2.0 * own} not much longer than the lead's \{lead_ms}")
  for w in ["行70", "图", "行9"] {
    let (_, ry, _, rh) = rest(w)
    let came = fnw_landed(seen.get(w).unwrap_or([]), ry, rh)
    assert_true(
      (came - (rc_at + lead_ms)).abs() <= 2.0,
      msg="\{w} at rest \{came - rc_at} after the words set out, the lead's \{lead_ms} wanted",
    )
  }
}

///|
test "flies_in in one block: what is said before its lead sets out from where it says, the block carried first, its pinned foot giving its room back at that moment" {
  let keys = @signals.signal(rc_ten_and([]), same=fn(a, b) { a == b })
  let tall = @signals.signal(90.0, same=fn(a, b) { a == b })
  let foot_box : Ref[@view.View?] = Ref(None)
  let flight = fnw_flight(400.0)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(400.0))) |> ignore
      o.scrolls_window(
        @view.Scroll::list(),
        fn() { keys.get() },
        est=40.0,
        follows=fn() { true },
        flips=true,
        foot=fn(f) {
          f.box(fn(c) {
            foot_box.val = Some(c)
            c.height(By(fn() { Some(tall.get()) })).shrink(Is(0.0)).words(Is("脚")) |> ignore
          })
          |> ignore
        },
        fn(b, k) {
          if k == 70 {
            // (a quote over the picture, said first, led: the picture leads)
            b.box(fn(w) {
              w.height(Is(Some(20.0))).shrink(Is(0.0)).words(Is("引")) |> ignore
              w.flies_in(flight, fn(to) { Some((0.0, 320.0, to.2, to.3)) }) |> ignore
            })
            |> ignore
            b.box(fn(w) {
              w.height(Is(Some(50.0))).shrink(Is(0.0)).words(Is("图")) |> ignore
              w.flies_in(flight, fn(to) { Some((0.0, 380.0, to.2, to.3)) }, lead=true) |> ignore
            })
            |> ignore
          } else {
            b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
          }
        },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  // (the words sent: the key comes, and the foot gives back 60 of its height, said to go its way)
  tree.event(rc_at, fn() {
    keys.set(rc_ten_and([70]))
    match foot_box.val {
      Some(c) => c.resizes(foot=true) |> ignore
      None => ()
    }
    tall.set(30.0)
  })
  tree.frame(390.0, 844.0, now=rc_at) |> ignore
  let y = match tree.drawn().filter(fn(d) { d.words == "引" }) {
    [d, ..] => d.y
    _ => rc_none
  }
  assert_true((y - 320.0).abs() < 0.5, msg="引 drawn at \{y} as it sets out, 320 wanted (where it says it flies from)")
}

///|
test "flights_refresh_now: non-in_list carried flight refreshes l.d after carried updates slot drawn_off, staying continuous across refresh and landing" {
  let foot = @signals.signal(90.0, same=fn(a, b) { a == b })
  let (t, keys) = fnw_old_case(foot)
  t.event(rc_at, fn() {
    t.old_views_building()
    keys.set(rc_ten_and([70]))
  })
  t.frame(390.0, 844.0, now=rc_at) |> ignore
  let y0 = rc_y(t, "行70")
  assert_true((y0 - 380.0).abs() <= 0.5, msg="departure y=\{y0} != 380.0")
  // Trigger flights_refresh_now while the slot has a live non-zero drawn_off from the initial FlipWay
  t.event(rc_at + 16.0, fn() {
    foot.set(30.0)
    t.old_views_built()
  })
  t.frame(390.0, 844.0, now=rc_at + 16.0) |> ignore
  let y_ref = rc_y(t, "行70")
  assert_true(
    (y_ref - y0).abs() < 20.0,
    msg="flights_refresh_now jumped on refresh frame: y0=\{y0}, y_ref=\{y_ref}",
  )
  let ys : Array[(Double, Double)] = [(rc_at, y0), (rc_at + 16.0, y_ref)]
  let mut m = rc_at + 32.0
  while m <= rc_at + 800.0 {
    t.frame(390.0, 844.0, now=m) |> ignore
    ys.push((m, rc_y(t, "行70")))
    m = m + 16.0
  }
  t.frame(390.0, 844.0, now=rc_at + 1200.0) |> ignore
  let rest_y = rc_y(t, "行70")
  assert_true(y0 - rest_y > 20.0, msg="expected upward flight > 20pt (y0=\{y0}, rest_y=\{rest_y})")
  for i in 1..<ys.length() {
    let (ti, yi) = ys[i]
    let (_, py) = ys[i - 1]
    assert_true(yi >= rest_y - 0.5, msg="t=\{ti}: overshot above rest_y=\{rest_y} (got \{yi})")
    assert_true(yi <= py + 0.5, msg="t=\{ti}: moved downward during upward flight (prev=\{py}, now=\{yi})")
    assert_true((yi - py).abs() < 20.0, msg="t=\{ti}: single-frame snap (prev=\{py}, now=\{yi})")
  }
}
