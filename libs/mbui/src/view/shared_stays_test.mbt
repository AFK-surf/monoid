// A shared end that stays (View::shared's `stays`, shared.mbt): a thumbnail that stays in its list while the picture it
// opens comes over everything, flown from it and back to it, drawn nowhere while the picture lives.

///|
/// A page: a list 100 tall (cut to itself, 10 in) holding thumbnails 40 square side by side by ids `ids`, each staying
/// (View::shared's `stays`), covering its picture; over all of it while `open` is said, a picture 300 by 200 at (50, 300)
/// by the id `open` says, as `flight` flies it. The thumbnails made, by id; the picture made last.
priv struct StaysScene {
  tree : @view.Tree
  open : @signals.Signal[String]
  thumbs : Map[String, @view.View]
  big : Ref[@view.View?]
}

///|
fn stays_scene(ids? : Array[String] = ["a"], flight? : @view.Flight = straight, list_top? : Double = 0.0) -> StaysScene {
  let open = @signals.signal("", same=fn(a, b) { a == b })
  let thumbs : Map[String, @view.View] = Map([])
  let big : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.box(fn(list) {
        list
        .height(Is(Some(100.0)))
        .offset(Is((0.0, list_top)))
        .row(Is(true))
        .padding(Is((10.0, 10.0, 10.0, 10.0)))
        .clips(Is(true))
        |> ignore
        for id in ids {
          list.box(fn(t) {
            thumbs[id] = t
            t
            .width(Is(Some(40.0)))
            .height(Is(Some(40.0)))
            .ground(Is(red))
            .radius(Is(8.0))
            .image_covers(Is(true))
            .shared(Is(id), flight, stays=true)
            |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      p.show(fn() { open.get() != "" }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          big.val = Some(b)
          b
          .offset(Is((50.0, 300.0)))
          .width(Is(Some(300.0)))
          .height(Is(Some(200.0)))
          .ground(Is(blue))
          .shared(By(fn() { open.get() }), flight)
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  { tree, open, thumbs, big }
}

///|
/// How opaque node `v` is drawn now (0 where it is not drawn).
fn alpha_of(t : @view.Tree, v : @view.View) -> Double {
  match t.drawn().iter().find_first(fn(d) { d.id == v.id() }) {
    Some(d) => d.alpha
    None => 0.0
  }
}

///|
test "a picture opened from a thumbnail that stays: flown from where the thumbnail was drawn, as it looked, not faded; the thumbnail kept in its room, drawn nowhere while the picture lives" {
  let p = stays_scene()
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  let thumb = p.thumbs["a"]
  assert_eq(drawn_as(p.tree, thumb), Some((10.0, 10.0, 40.0, 40.0, 1.0, red)))
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let big = p.big.val.unwrap()
  assert_true(big.flies())
  // (at its cause: where the thumbnail was, as it looked, seen whole; the thumbnail there still, drawn nowhere)
  assert_eq(drawn_as(p.tree, big), Some((10.0, 10.0, 40.0, 40.0, 1.0, red)))
  assert_true(thumb.alive())
  assert_eq(alpha_of(p.tree, thumb), 0.0)
  assert_eq(p.tree.flight_drawn("a").map(fn(f) { f.1 }), Some((8.0, 8.0, 8.0, 8.0)))
  // (half way: half way there, its corners half way)
  p.tree.frame(400.0, 800.0, now=1100.0) |> ignore
  assert_eq(drawn_as(p.tree, big).map(fn(d) { (d.0, d.1, d.2, d.3, d.4) }), Some((30.0, 155.0, 170.0, 120.0, 1.0)))
  assert_eq(p.tree.flight_drawn("a").map(fn(f) { f.1 }), Some((4.0, 4.0, 4.0, 4.0)))
  // (a picture in it drawn on the way as the thumbnail draws its own: covering its box)
  assert_eq(p.tree.drawn().iter().find_first(fn(d) { d.id == big.id() }).map(fn(d) { d.image_cover }), Some(true))
  // (there: where it is laid out; the thumbnail still drawn nowhere)
  p.tree.frame(400.0, 800.0, now=1200.0) |> ignore
  assert_false(big.flies())
  assert_eq(drawn_as(p.tree, big), Some((50.0, 300.0, 300.0, 200.0, 1.0, blue)))
  assert_eq(p.tree.drawn().iter().find_first(fn(d) { d.id == big.id() }).map(fn(d) { d.image_cover }), Some(false))
  assert_eq(alpha_of(p.tree, thumb), 0.0)
  assert_eq(p.tree.flight_drawn("a"), None)
}

///|
test "the picture closed: the thumbnail flies back from where the picture was drawn to its room, drawn as it sets out; the picture drawn no more" {
  let p = stays_scene()
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1500.0) |> ignore
  let big = p.big.val.unwrap()
  let thumb = p.thumbs["a"]
  p.tree.event(2000.0, fn() { p.open.set("") })
  p.tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_false(big.alive())
  assert_true(thumb.flies())
  assert_eq(drawn_as(p.tree, thumb), Some((50.0, 300.0, 300.0, 200.0, 1.0, blue)))
  p.tree.frame(400.0, 800.0, now=2100.0) |> ignore
  assert_eq(drawn_as(p.tree, thumb).map(fn(d) { (d.0, d.1, d.2, d.3, d.4) }), Some((30.0, 155.0, 170.0, 120.0, 1.0)))
  p.tree.frame(400.0, 800.0, now=2200.0) |> ignore
  assert_false(thumb.flies())
  assert_eq(drawn_as(p.tree, thumb), Some((10.0, 10.0, 40.0, 40.0, 1.0, red)))
}

///|
test "a flight with an end that stays drawn within that end's room as what held it cut it, opening to the window as it leaves" {
  // (the list moved up 30: the thumbnail's top 20 cut off by it)
  let p = stays_scene(list_top=-30.0)
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let big = p.big.val.unwrap()
  // (within where it is drawn: the thumbnail, 10 to 50 across, -20 to 20 down, its top 20 cut off)
  assert_eq(p.tree.lift_cut(big.id()), Some((10.0, 0.0, 50.0, 20.0)))
  p.tree.frame(400.0, 800.0, now=1100.0) |> ignore
  // (half way: the room opened to 435 down, all of where it is drawn then within it)
  assert_eq(p.tree.lift_cut(big.id()), Some((30.0, 140.0, 200.0, 260.0)))
  p.tree.frame(400.0, 800.0, now=1200.0) |> ignore
  assert_eq(p.tree.lift_cut(big.id()), None)
}

///|
test "the picture's id changed to another thumbnail's while it is open: none flies; the first drawn again at once, the other drawn nowhere; closed, back to the other" {
  let p = stays_scene(ids=["a", "b"])
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1500.0) |> ignore
  let (a, b) = (p.thumbs["a"], p.thumbs["b"])
  assert_eq((alpha_of(p.tree, a), alpha_of(p.tree, b)), (0.0, 1.0))
  p.tree.event(2000.0, fn() { p.open.set("b") })
  p.tree.frame(400.0, 800.0, now=2000.0) |> ignore
  let big = p.big.val.unwrap()
  assert_false(big.flies() || a.flies() || b.flies())
  assert_eq((alpha_of(p.tree, a), alpha_of(p.tree, b)), (1.0, 0.0))
  p.tree.event(3000.0, fn() { p.open.set("") })
  p.tree.frame(400.0, 800.0, now=3000.0) |> ignore
  assert_true(b.flies())
  assert_false(a.flies())
}

///|
test "a thumbnail cut to nothing by what holds it: none flies, the picture comes and goes as it would; nor where none of its id stays" {
  // (the list moved up past the thumbnail)
  let p = stays_scene(list_top=-60.0)
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1000.0) |> ignore
  assert_false(p.big.val.unwrap().flies())
  p.tree.event(2000.0, fn() { p.open.set("z") })
  p.tree.event(2100.0, fn() { p.open.set("") })
  p.tree.frame(400.0, 800.0, now=2100.0) |> ignore
  assert_false(p.thumbs["a"].flies())
}

///|
test "motion reduced: the picture there at once, the thumbnail drawn nowhere; closed, the thumbnail there again at once" {
  let p = stays_scene(flight=at_once)
  p.tree.frame(400.0, 800.0, now=0.0) |> ignore
  p.tree.event(1000.0, fn() { p.open.set("a") })
  p.tree.frame(400.0, 800.0, now=1000.0) |> ignore
  let big = p.big.val.unwrap()
  let thumb = p.thumbs["a"]
  assert_false(big.flies())
  assert_eq(drawn_as(p.tree, big), Some((50.0, 300.0, 300.0, 200.0, 1.0, blue)))
  assert_eq(alpha_of(p.tree, thumb), 0.0)
  p.tree.event(2000.0, fn() { p.open.set("") })
  p.tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_false(thumb.flies())
  assert_eq(drawn_as(p.tree, thumb), Some((10.0, 10.0, 40.0, 40.0, 1.0, red)))
}

///|
test "the picture made anew for another thumbnail's in one change (stepped to the one beside it): none flies; the first drawn again at once, the other drawn nowhere" {
  let open = @signals.signal("", same=fn(a, b) { a == b })
  let thumbs : Map[String, @view.View] = Map([])
  let big : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.box(fn(list) {
        list.height(Is(Some(100.0))).row(Is(true)).padding(Is((10.0, 10.0, 10.0, 10.0))).clips(Is(true)) |> ignore
        for id in ["a", "b"] {
          list.box(fn(t) {
            thumbs[id] = t
            t.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(Is(red)).shared(Is(id), straight, stays=true) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      // (a picture a key, made anew as it steps)
      p.pick(at_once=true, fn() { open.get() }, fn(o, id) {
        if id != "" {
          o.over(Is(true)) |> ignore
          o.box(fn(b) {
            big.val = Some(b)
            b
            .offset(Is((50.0, 300.0)))
            .width(Is(Some(300.0)))
            .height(Is(Some(200.0)))
            .ground(Is(blue))
            .shared(Is(id), straight)
            |> ignore
          })
          |> ignore
        }
      })
    })
    |> ignore
  })
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { open.set("a") })
  tree.frame(400.0, 800.0, now=1500.0) |> ignore
  let (a, b) = (thumbs["a"], thumbs["b"])
  assert_eq((alpha_of(tree, a), alpha_of(tree, b)), (0.0, 1.0))
  tree.event(2000.0, fn() { open.set("b") })
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_false(big.val.unwrap().flies() || a.flies() || b.flies())
  assert_eq((alpha_of(tree, a), alpha_of(tree, b)), (1.0, 0.0))
  // (closed then: back to the one it shows)
  tree.event(3000.0, fn() { open.set("") })
  tree.frame(400.0, 800.0, now=3000.0) |> ignore
  assert_true(b.flies())
  assert_false(a.flies())
}

///|
/// A thumbnail "a" that stays (none where `thumb` is false) and over all of it, while `open` is said, a picture by id "a"
/// said `with_stays`, made anew where `tier` changes (as a viewer's layer is for another tier of the window): 300 by
/// 200 at (50, 300), or 200 by 100 at (20, 100) at tier 1. The tree, open, tier, the thumbnail, the picture made last.
fn with_stays_scene(
  thumb : Bool,
) -> (@view.Tree, @signals.Signal[Bool], @signals.Signal[Int], Ref[@view.View?], Ref[@view.View?]) {
  let open = @signals.signal(false)
  let tier = @signals.signal(0)
  let th : Ref[@view.View?] = Ref(None)
  let big : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.box(fn(list) {
        list.height(Is(Some(100.0))).row(Is(true)).padding(Is((10.0, 10.0, 10.0, 10.0))) |> ignore
        if thumb {
          list.box(fn(t) {
            th.val = Some(t)
            t.width(Is(Some(40.0))).height(Is(Some(40.0))).ground(Is(red)).shared(Is("a"), straight, stays=true) |> ignore
          })
          |> ignore
        }
      })
      |> ignore
      p.pick(at_once=true, fn() { if open.get() { tier.get() } else { -1 } }, fn(o, k) {
        if k >= 0 {
          o.over(Is(true)) |> ignore
          o.box(fn(b) {
            big.val = Some(b)
            let (x, y, w, h) = if k == 0 { (50.0, 300.0, 300.0, 200.0) } else { (20.0, 100.0, 200.0, 100.0) }
            b
            .offset(Is((x, y)))
            .width(Is(Some(w)))
            .height(Is(Some(h)))
            .ground(Is(blue))
            .shared(Is("a"), straight, with_stays=true)
            |> ignore
          })
          |> ignore
        }
      })
    })
    |> ignore
  })
  (tree, open, tier, th, big)
}

///|
test "one that moves said with_stays made anew in the place of another of its id (a viewer's layer for another tier): there at once, no flight between; the thumbnail drawn nowhere still; closed, back to it" {
  let (tree, open, tier, th, big) = with_stays_scene(true)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  assert_true(big.val.unwrap().flies(), msg="flown from the thumbnail")
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  let first = big.val.unwrap()
  assert_eq(drawn_as(tree, first), Some((50.0, 300.0, 300.0, 200.0, 1.0, blue)))
  tree.event(3000.0, fn() { tier.set(1) })
  tree.frame(400.0, 800.0, now=3000.0) |> ignore
  let again = big.val.unwrap()
  assert_true(!physical_equal(again, first) && !first.alive(), msg="made anew, the other let go of")
  assert_true(!again.flies(), msg="no flight between the two")
  assert_eq(drawn_as(tree, again), Some((20.0, 100.0, 200.0, 100.0, 1.0, blue)))
  assert_eq(alpha_of(tree, th.val.unwrap()), 0.0, msg="the thumbnail drawn nowhere still")
  tree.event(4000.0, fn() { open.set(false) })
  tree.frame(400.0, 800.0, now=4000.0) |> ignore
  assert_true(th.val.unwrap().flies(), msg="closed: the thumbnail flown back to")
  tree.frame(400.0, 800.0, now=5000.0) |> ignore
  assert_eq(drawn_as(tree, th.val.unwrap()), Some((10.0, 10.0, 40.0, 40.0, 1.0, red)))
}

///|
test "one said with_stays, none of its id staying: made anew in the place of another, there at once, as without an id" {
  let (tree, open, tier, _, big) = with_stays_scene(false)
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  tree.event(1000.0, fn() { open.set(true) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  assert_true(!big.val.unwrap().flies())
  tree.event(2000.0, fn() { tier.set(1) })
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_true(!big.val.unwrap().flies(), msg="no flight between the two")
  assert_eq(drawn_as(tree, big.val.unwrap()), Some((20.0, 100.0, 200.0, 100.0, 1.0, blue)))
}

///|
test "a thumbnail that stays let go of with the picture of its id in one change: no departure of its own, let go of at once, no fault" {
  let thumbs_on = @signals.signal(true, same=fn(a, b) { a == b })
  let open = @signals.signal(true, same=fn(a, b) { a == b })
  let gone = Ref(0)
  let thumb : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.show(fn() { thumbs_on.get() }, at_once=true, fn(b) {
        b.box(fn(t) {
          thumb.val = Some(t)
          t
          .width(Is(Some(40.0)))
          .height(Is(Some(40.0)))
          .ground(Is(red))
          .shared(Is("a"), straight, stays=true)
          .owns(fn() { gone.val = gone.val + 1 })
          |> ignore
        })
        |> ignore
      })
      p.show(fn() { open.get() }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          b
          .offset(Is((50.0, 300.0)))
          .width(Is(Some(300.0)))
          .height(Is(Some(200.0)))
          .ground(Is(blue))
          .shared(Is("a"), straight)
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  assert_true(thumb.val.unwrap().alive())
  // (both closed at once: the one that moves the only departure of "a" (one that stays never flies out as it goes),
  // the thumbnail's branch let go of in the change itself, not put by for a flight it is never part of)
  tree.event(1000.0, fn() {
    thumbs_on.set(false)
    open.set(false)
  })
  assert_eq(gone.val, 1)
  assert_false(thumb.val.unwrap().alive())
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  tree.frame(400.0, 800.0, now=2000.0) |> ignore
  assert_eq(gone.val, 1)
}

///|
test "a container said By an id that says none as it goes: what holds it let go of at once, not put by for good" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let gone = Ref(0)
  let made : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.show(fn() { on.get() }, at_once=true, fn(b) {
        b.box(fn(c) {
          made.val = Some(c)
          c
          .width(Is(Some(40.0)))
          .height(Is(Some(40.0)))
          .ground(Is(red))
          .shared(By(fn() { "" }), straight, container=true)
          .owns(fn() { gone.val = gone.val + 1 })
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(400.0, 800.0, now=0.0) |> ignore
  assert_true(made.val.unwrap().alive())
  tree.event(1000.0, fn() { on.set(false) })
  tree.frame(400.0, 800.0, now=1000.0) |> ignore
  assert_eq(gone.val, 1)
  assert_false(made.val.unwrap().alive())
}

///|
test "a stays thumbnail with nested filling children (through pick slot and boxes, with full-box and letterbox image_in): closing from a differently shaped big view fits lift_rect on first and mid frames and restores on landing" {
  let open = @signals.signal("", same=fn(a, b) { a == b })
  let pic_full : Ref[@view.View?] = Ref(None)
  let pic_lb : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)) |> ignore
      p.box(fn(list) {
        list.height(Is(Some(300.0))).padding(Is((10.0, 10.0, 10.0, 10.0))) |> ignore
        list.box(fn(f) {
          f.width(Is(Some(360.0))).height(Is(Some(160.0))).shared(Is("full"), straight, stays=true) |> ignore
          f.pick(at_once=true, fn() { 0 }, fn(slot, _) {
            slot.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
            slot.box(fn(wrap) {
              wrap.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
              wrap.box(fn(pic) {
                pic_full.val = Some(pic)
                pic
                .width(Is(Some(360.0)))
                .height(Is(Some(160.0)))
                .image(Is(Some(("mem:full", "", 360))))
                .image_in(Is(Some(((0.0, 0.0, 360.0, 160.0), 0x000000FFL))))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
        })
        |> ignore
        list.box(fn(f) {
          f.width(Is(Some(360.0))).height(Is(Some(96.0))).shared(Is("lb"), straight, stays=true) |> ignore
          f.pick(at_once=true, fn() { 0 }, fn(slot, _) {
            slot.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
            slot.box(fn(wrap) {
              wrap.width_share(Is(1.0)).height_share(Is(1.0)) |> ignore
              wrap.box(fn(pic) {
                pic_lb.val = Some(pic)
                pic
                .width(Is(Some(360.0)))
                .height(Is(Some(96.0)))
                .image(Is(Some(("mem:lb", "", 360))))
                .image_in(Is(Some(((0.0, 28.0, 360.0, 40.0), 0x000000FFL))))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
      p.show(fn() { open.get() != "" }, fn(o) {
        o.over(Is(true)) |> ignore
        o.box(fn(b) {
          b
          .offset(By(fn() { if open.get() == "full" { (40.0, 267.0) } else { (40.0, 333.0) } }))
          .width(By(fn() { Some(1200.0) }))
          .height(By(fn() { Some(if open.get() == "full" { 266.0 } else { 133.0 }) }))
          .ground(Is(blue))
          .shared(By(fn() { open.get() }), straight)
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  let drawn_of = fn(v : @view.View) { tree.drawn().iter().find_first(fn(d) { d.id == v.id() }) }
  tree.frame(1280.0, 800.0, now=0.0) |> ignore
  let pf = pic_full.val.unwrap()
  let pl = pic_lb.val.unwrap()

  // Full-box nested filler: open, land, then close and check frame 0, mid frame, and landed frame.
  tree.event(1000.0, fn() { open.set("full") })
  tree.frame(1280.0, 800.0, now=1500.0) |> ignore
  tree.event(2000.0, fn() { open.set("") })
  tree.frame(1280.0, 800.0, now=2000.0) |> ignore
  let fl0 = tree.flight_drawn("full").unwrap().0
  let d0 = drawn_of(pf).unwrap()
  assert_true((d0.w - fl0.2).abs() < 0.5 && (d0.h - fl0.3).abs() < 0.5, msg="full frame0: \{d0.w}x\{d0.h} vs \{fl0.2}x\{fl0.3}")
  let s0 = fl0.2 / 360.0
  guard d0.image_in is Some(((ix0, iy0, iw0, ih0), _)) else { fail("full frame0 image_in missing") }
  assert_true(
    ix0.abs() < 0.5 && iy0.abs() < 0.5 && (iw0 - fl0.2 / s0).abs() < 0.5 && (ih0 - fl0.3 / s0).abs() < 0.5,
    msg="full frame0 image_in: \{ix0},\{iy0},\{iw0},\{ih0}",
  )

  tree.frame(1280.0, 800.0, now=2100.0) |> ignore
  let fl1 = tree.flight_drawn("full").unwrap().0
  let d1 = drawn_of(pf).unwrap()
  assert_true((d1.w - fl1.2).abs() < 0.5 && (d1.h - fl1.3).abs() < 0.5, msg="full mid: \{d1.w}x\{d1.h} vs \{fl1.2}x\{fl1.3}")
  let s1 = fl1.2 / 360.0
  guard d1.image_in is Some(((ix1, iy1, iw1, ih1), _)) else { fail("full mid image_in missing") }
  assert_true(
    ix1.abs() < 0.5 && iy1.abs() < 0.5 && (iw1 - fl1.2 / s1).abs() < 0.5 && (ih1 - fl1.3 / s1).abs() < 0.5,
    msg="full mid image_in: \{ix1},\{iy1},\{iw1},\{ih1}",
  )

  tree.frame(1280.0, 800.0, now=2200.0) |> ignore
  let d2 = drawn_of(pf).unwrap()
  assert_true((d2.w - 360.0).abs() < 0.5 && (d2.h - 160.0).abs() < 0.5, msg="full landed: \{d2.w}x\{d2.h}")
  guard d2.image_in is Some(((ix2, iy2, iw2, ih2), _)) else { fail("full landed image_in missing") }
  assert_true(
    ix2.abs() < 0.5 && iy2.abs() < 0.5 && (iw2 - 360.0).abs() < 0.5 && (ih2 - 160.0).abs() < 0.5,
    msg="full landed image_in: \{ix2},\{iy2},\{iw2},\{ih2}",
  )

  // Letterbox nested filler: open, land, then close and check frame 0, mid frame, and landed frame.
  tree.event(3000.0, fn() { open.set("lb") })
  tree.frame(1280.0, 800.0, now=3500.0) |> ignore
  tree.event(4000.0, fn() { open.set("") })
  tree.frame(1280.0, 800.0, now=4000.0) |> ignore
  let lfl0 = tree.flight_drawn("lb").unwrap().0
  let ld0 = drawn_of(pl).unwrap()
  assert_true((ld0.w - lfl0.2).abs() < 0.5 && (ld0.h - lfl0.3).abs() < 0.5, msg="lb frame0: \{ld0.w}x\{ld0.h} vs \{lfl0.2}x\{lfl0.3}")
  let ls0 = lfl0.2 / 360.0
  let lfw0 = lfl0.2 / ls0
  let lfh0 = lfl0.3 / ls0
  guard ld0.image_in is Some(((lix0, liy0, liw0, lih0), _)) else { fail("lb frame0 image_in missing") }
  let lk0 = if lfw0 / 360.0 < lfh0 / 40.0 { lfw0 / 360.0 } else { lfh0 / 40.0 }
  assert_true(
    (liw0 - 360.0 * lk0).abs() < 0.5 &&
    (lih0 - 40.0 * lk0).abs() < 0.5 &&
    (lix0 - (lfw0 - liw0) / 2.0).abs() < 0.5 &&
    (liy0 - (lfh0 - lih0) / 2.0).abs() < 0.5,
    msg="lb frame0 image_in: \{lix0},\{liy0},\{liw0},\{lih0} in \{lfw0}x\{lfh0}",
  )

  tree.frame(1280.0, 800.0, now=4100.0) |> ignore
  let lfl1 = tree.flight_drawn("lb").unwrap().0
  let ld1 = drawn_of(pl).unwrap()
  assert_true((ld1.w - lfl1.2).abs() < 0.5 && (ld1.h - lfl1.3).abs() < 0.5, msg="lb mid: \{ld1.w}x\{ld1.h} vs \{lfl1.2}x\{lfl1.3}")
  let ls1 = lfl1.2 / 360.0
  let lfw1 = lfl1.2 / ls1
  let lfh1 = lfl1.3 / ls1
  guard ld1.image_in is Some(((lix1, liy1, liw1, lih1), _)) else { fail("lb mid image_in missing") }
  assert_true(
    (liw1 / lih1 - 9.0).abs() < 0.05 &&
    (lix1 - (lfw1 - liw1) / 2.0).abs() < 0.5 &&
    (liy1 - (lfh1 - lih1) / 2.0).abs() < 0.5,
    msg="lb mid image_in: \{lix1},\{liy1},\{liw1},\{lih1} in \{lfw1}x\{lfh1}",
  )

  tree.frame(1280.0, 800.0, now=4200.0) |> ignore
  let ld2 = drawn_of(pl).unwrap()
  assert_true((ld2.w - 360.0).abs() < 0.5 && (ld2.h - 96.0).abs() < 0.5, msg="lb landed: \{ld2.w}x\{ld2.h}")
  guard ld2.image_in is Some(((lix2, liy2, liw2, lih2), _)) else { fail("lb landed image_in missing") }
  assert_true(
    lix2.abs() < 0.5 && (liy2 - 28.0).abs() < 0.5 && (liw2 - 360.0).abs() < 0.5 && (lih2 - 40.0).abs() < 0.5,
    msg="lb landed image_in: \{lix2},\{liy2},\{liw2},\{lih2}",
  )
}

///|
test "a container=true flight does not resize a filling child" {
  let show = @signals.signal(false, same=fn(a, b) { a == b })
  let child : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(p) {
      p.grow(Is(1.0)).padding(Is((100.0, 500.0, 0.0, 0.0))) |> ignore
      p.show(fn() { show.get() }, at_once=true, fn(box) {
        box
        .width(Is(Some(400.0)))
        .height(Is(Some(60.0)))
        .ground(Is(red))
        .flies_in(straight, fn(_) { Some((100.0, 200.0, 400.0, 140.0)) }, container=true)
        |> ignore
        box.box(fn(kid) {
          child.val = Some(kid)
          kid.width(Is(Some(400.0))).height(Is(Some(60.0))).ground(Is(blue)) |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
  tree.frame(600.0, 700.0, now=0.0) |> ignore
  tree.event(10.0, fn() { show.set(true) })
  tree.frame(600.0, 700.0, now=50.0) |> ignore
  let kd = tree.drawn().iter().find_first(fn(d) { d.id == child.val.unwrap().id() }).unwrap()
  assert_true((kd.w - 400.0).abs() < 0.5 && (kd.h - 60.0).abs() < 0.5, msg="container filling child resized: \{kd.w}x\{kd.h}")
}
