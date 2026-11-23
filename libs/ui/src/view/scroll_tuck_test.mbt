// `View::scrolls` + `Scroll::tucks`: fixed-height short/long lists, adaptive-height (`AtMost`) short/long containers,
// pull-down reveal only after reaching top, staying open while focused (`kept=false`), and re-tucking when blurred.

///|
priv struct TuckCase {
  tree : @view.Tree
  scroll : @view.Scroll
  host : @view.View
  kept : @signals.Signal[Bool]
  pressed : Ref[Int]
}

///|
fn tuck_case(
  item_count : Int,
  fixed_h? : Double,
  max_h? : Double,
  search_h? : Double = 40.0,
  item_h? : Double = 50.0,
) -> TuckCase {
  let scroll = @view.Scroll::new()
  let kept = @signals.signal(true)
  let pressed = Ref(0)
  let host_ref : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(root) {
    root.box(fn(o) {
      o.width(Is(Some(300.0))) |> ignore
      match fixed_h {
        Some(h) => o.height(Is(Some(h))) |> ignore
        None => ()
      }
      match max_h {
        Some(m) => o.max_height(Is(Some(m))) |> ignore
        None => ()
      }
      host_ref.val = Some(o)
      o.scrolls(scroll, fn(s) {
        s.box(fn(sb) {
          sb.height(Is(Some(search_h))).on_press(fn() { pressed.val += 1 }) |> ignore
          scroll.tucks(sb, fn() { 0.0 }, kept=fn() { kept.get() })
        })
        |> ignore
        for _ in 0..<item_count {
          s.box(fn(it) { it.height(Is(Some(item_h))) |> ignore }) |> ignore
        }
      })
      |> ignore
    })
    |> ignore
  })
  tree.frame(390.0, 844.0) |> ignore
  tree.frame(390.0, 844.0) |> ignore
  { tree, scroll, host: host_ref.val.unwrap(), kept, pressed }
}

///|
test "scrolls tucks: fixed-height short list reserves tuck_room and tucks search above top" {
  let c = tuck_case(2, fixed_h=300.0)
  let (_, _, _, hh) = c.host.rect()
  assert_eq(hh, 300.0)
  assert_eq(c.scroll.at(c.tree), 40.0)
  assert_eq(c.scroll.overflows_past_tuck(), false)
  // Tucked search box is above top and cannot be clicked through
  assert_true(c.tree.press(150.0, 10.0) == false)
  assert_eq(c.pressed.val, 0)
  // Pulling down from held top reveals the search box
  c.tree.wheel_at(150.0, 50.0, 0.0, -40.0, 0, 20.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 0.0)
  assert_eq(c.scroll.overflows_past_tuck(), false)
  assert_true(c.tree.press(150.0, 20.0))
  assert_eq(c.pressed.val, 1)
}

///|
test "scrolls tucks: fixed-height long list stops at tucked top when scrolling up from below, reveals on second pull" {
  let c = tuck_case(10, fixed_h=200.0)
  assert_eq(c.scroll.at(c.tree), 40.0)
  assert_eq(c.scroll.overflows_past_tuck(), true)
  // Scroll down into the list
  c.tree.wheel_at(150.0, 100.0, 0.0, 100.0, 0, 10.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 140.0)
  // Scrolling back up in one gesture stops at held top (40.0), not exposing search
  c.tree.wheel_at(150.0, 100.0, 0.0, -200.0, 0, 20.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 40.0)
  // After a pause (new gesture at held top), pulling down reveals the search box
  c.tree.wheel_at(150.0, 100.0, 0.0, -40.0, 0, 500.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 0.0)
  // Scrolling back down past 40 re-tucks
  c.tree.wheel_at(150.0, 100.0, 0.0, 60.0, 0, 1000.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 60.0)
  assert_eq(c.scroll.tuck_height(), 40.0)
}

///|
test "scrolls tucks: adaptive AtMost short container sizes to items without tucked search, grows when kept=false" {
  let c = tuck_case(2, max_h=400.0)
  let (_, _, _, hh) = c.host.rect()
  // 2 items * 50 = 100, excluding 40pt tucked search
  assert_eq(hh, 100.0)
  assert_eq(c.scroll.at(c.tree), 40.0)
  assert_eq(c.scroll.overflows_past_tuck(), false)
  // Pull down reveals search inside the container
  c.tree.wheel_at(150.0, 50.0, 0.0, -40.0, 0, 20.0) |> ignore
  c.tree.frame(390.0, 844.0) |> ignore
  assert_eq(c.scroll.at(c.tree), 0.0)
  // Focusing search (`kept=false`) expands adaptive container to include search + items (140)
  c.kept.set(false)
  c.tree.frame(390.0, 844.0) |> ignore
  let (_, _, _, hh_open) = c.host.rect()
  assert_eq(hh_open, 140.0)
  assert_eq(c.scroll.tuck_height(), 0.0)
  // Clearing/blurring (`kept=true`) restores compact height (100)
  c.kept.set(true)
  c.tree.frame(390.0, 844.0) |> ignore
  let (_, _, _, hh_back) = c.host.rect()
  assert_eq(hh_back, 100.0)
}

///|
test "scrolls tucks: adaptive AtMost long container caps at max_h and overflows past tuck" {
  let c = tuck_case(10, max_h=240.0)
  let (_, _, _, hh) = c.host.rect()
  assert_eq(hh, 240.0)
  assert_eq(c.scroll.at(c.tree), 40.0)
  assert_eq(c.scroll.overflows_past_tuck(), true)
}

///|
test "scrolls tucks: grow-filling short container keeps header tucked and reveals on wheel up" {
  let s = @view.Scroll::new()
  let kept = @signals.signal(true)
  let host_ref : Ref[@view.View?] = Ref(None)
  let tree = @view.Tree::new(fn(outer) {
    outer.width(Is(Some(320.0))).height(Is(Some(500.0))) |> ignore
    outer.box(fn(head) { head.height(Is(Some(44.0))) |> ignore }) |> ignore
    outer.box(fn(wrap) {
      wrap.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_height(Is(Some(0.0))) |> ignore
      let host = wrap.scrolls(s, fn(body) {
        body.box(fn(bar) {
          bar.height(Is(Some(40.0))) |> ignore
          s.tucks(bar, fn() { 0.0 }, kept=fn() { kept.get() })
        })
        |> ignore
        for _ in 0..<2 {
          body.box(fn(row) { row.height(Is(Some(50.0))) |> ignore }) |> ignore
        }
      })
      host.grow(Is(1.0)).min_height(Is(Some(0.0))).clips(Is(true)).bounds_input(Is(true)) |> ignore
      host_ref.val = Some(host)
    })
    |> ignore
  })
  tree.frame(320.0, 500.0) |> ignore
  tree.frame(320.0, 500.0) |> ignore
  let host = host_ref.val.unwrap()
  let (_, _, _, hh) = host.rect()
  assert_eq(hh, 456.0)
  assert_eq(s.at(tree), 40.0)
  assert_eq(s.overflows_past_tuck(), false)
  tree.wheel_at(160.0, 120.0, 0.0, -80.0, 0, 20.0) |> ignore
  tree.frame(320.0, 500.0) |> ignore
  assert_eq(s.at(tree), 0.0)
  assert_eq(s.overflows_past_tuck(), false)
}
