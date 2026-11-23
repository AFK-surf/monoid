// A page's list told as it follows its foot (Scroll::follows_now) and as it glides back to it (Scroll::glides_to_foot):
// on its glide back to its foot (ListPlace::to_end) it follows it, and at its end; stopped on its way (put, the hand,
// the wheel), it follows it no more, from that moment, the glide's notch let go of as it is at its end told apart by
// the moment it is let go at. And a block asked to be brought while its pinned foot holds an old view not built yet (the
// chat's composer, as tall as nothing till then) is brought where it asks once that view is built, never taken for good
// where the list ends short of where it will (View::scrolls_window's foot_unbuilt).

///|
/// A page's list 300 by 100 of keys 0 to 9 (40 each: 400 tall, its foot 300 down), not following its foot, put 150
/// down. Drawn at 0.
fn fn_case() -> (@view.Tree, @view.Scroll, @view.ListPlace[Int]) {
  let place = @view.ListPlace::new()
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(100.0))) |> ignore
      o.scrolls_window(scroll, fn() { Array::makei(10, fn(i) { i }) }, est=40.0, place~, fn(b, k) {
        b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  scroll.put(150.0)
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  (tree, scroll, place)
}

///|
test "follows_now: on its glide back to its foot it follows it; stopped on its way, it follows it no more, at once" {
  let (t, scroll, place) = fn_case()
  assert_false(scroll.follows_now(), msg="150 off its foot, following it")
  t.event(100.0, fn() { place.to_end() })
  t.frame(390.0, 844.0, now=104.0) |> ignore
  assert_true(scroll.glides_to_foot(), msg="not told gliding back to its foot")
  assert_true(scroll.follows_now(), msg="on its glide back to its foot, not following it")
  // (stopped on its way, short of its foot, before any fill takes where it stopped)
  let told = Ref((true, true))
  let stopped = Ref(0.0)
  t.event(106.0, fn() {
    stopped.val = scroll.at(t)
    scroll.put(stopped.val)
    told.val = (scroll.follows_now(), scroll.glides_to_foot())
  })
  assert_true(stopped.val < 299.0, msg="stopped at \{stopped.val}: at its foot already")
  assert_false(told.val.0, msg="stopped on its glide, still following its foot")
  assert_false(told.val.1, msg="stopped on its glide, still told gliding")
  t.frame(390.0, 844.0, now=2000.0) |> ignore
  assert_false(scroll.follows_now(), msg="stopped short of its foot (\{stopped.val}, now \{scroll.at(t)}), following it")
}

///|
test "follows_now: its glide back to its foot come to its end: following it there" {
  let (t, scroll, place) = fn_case()
  t.event(100.0, fn() { place.to_end() })
  t.frame(390.0, 844.0, now=116.0) |> ignore
  t.frame(390.0, 844.0, now=2000.0) |> ignore
  assert_eq(scroll.at(t), 300.0)
  assert_false(scroll.glides_to_foot(), msg="at rest at its foot, told gliding")
  assert_true(scroll.follows_now(), msg="at its foot, not following it")
}

///|
/// A page's list 300 by 300 of keys 0 to 9 (40 each), from its top, not following its foot; its pinned foot an old
/// view hosted in the tree, as tall as `foot` once it is built (Tree::old_views_built), nothing before. Drawn at 0.
fn fu_case(foot : @signals.Signal[Double]) -> (@view.Tree, @view.Scroll, @view.ListPlace[Int]) {
  let place = @view.ListPlace::new()
  let scroll = @view.Scroll::list()
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      o.scrolls_window(
        scroll,
        fn() { Array::makei(10, fn(i) { i }) },
        est=40.0,
        place~,
        foot=fn(f) {
          f.hosted(make=fn(v) { v.height(By(fn() { Some(foot.get()) })).shrink(Is(0.0)) |> ignore }) |> ignore
        },
        fn(b, k) { b.height(Is(Some(40.0))).words(Is("行\{k}")) |> ignore },
      )
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0, now=0.0) |> ignore
  (tree, scroll, place)
}

///|
test "a block asked to be brought while its pinned foot's old view is not built yet: brought where it asks once it is" {
  for glide in [false, true] {
    let foot = @signals.signal(0.0, same=fn(a, b) { a == b })
    let (t, scroll, place) = fu_case(foot)
    // (行9's top 360 down: past where the list ends with its foot as tall as nothing, 100)
    t.event(100.0, fn() { place.bring(9, glide~) })
    t.frame(390.0, 844.0, now=100.0) |> ignore
    t.frame(390.0, 844.0, now=1000.0) |> ignore
    // (the old view built, as tall as it is: 200; where all ends 300 down now)
    t.event(1000.0, fn() {
      t.old_views_building()
      foot.set(200.0)
      t.old_views_built()
    })
    t.frame(390.0, 844.0, now=1000.0) |> ignore
    t.frame(390.0, 844.0, now=3000.0) |> ignore
    assert_eq(scroll.at(t), 300.0, msg="glide \{glide}: at \{scroll.at(t)}, its foot (300) wanted, as far as 行9 goes")
  }
}
