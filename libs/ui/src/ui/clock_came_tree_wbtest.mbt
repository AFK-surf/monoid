// What only the clock brings on the window's tree (a moment said `later`: a count's next second, a time on screen run
// out) is told apart from what a cause sets going, as an old view's wait said `later` is (Tester::clock_came): a judge
// that leaves out a number running while it is seen (an app's switches still) sees it by its kind.

///|
/// A window whose root says a moment `ms` on, `later` or not, and whether the clock brought something by the frame
/// drawn at it: (before it, at it, at it again).
fn clock_came_tree(later : Bool, ms : Double) -> (Bool, Bool, Bool) {
  let root_v : Ref[@view.View?] = Ref(None)
  let n = @signals.signal(0)
  let t = Tester::new(fn(_c) {  }, w=200.0, h=200.0, platform=0)
  set_view_app(fn(root) {
    root_v.val = Some(root)
    root.box(fn(b) { b.words(By(fn() { "第\{n.get()}秒" })) |> ignore }) |> ignore
  })
  t.draw()
  let t0 = t.time()
  t.clock_came(t0) |> ignore
  match root_v.val {
    Some(root) => root.at_moment(t0 + ms, fn() { n.set(n.untracked() + 1) }, later~) |> ignore
    None => ()
  }
  t.frame_at(t0 + ms / 2.0)
  let before = t.clock_came(t.time())
  t.frame_at(t0 + ms)
  let at = t.clock_came(t.time())
  let again = t.clock_came(t.time())
  (before, at, again)
}

///|
test "a moment of the window's tree said later, come due, is the clock's: told once, by the frame it comes in" {
  assert_eq(clock_came_tree(true, 1000.0), (false, true, false))
}

///|
test "a moment of the window's tree not said later is a cause's own, not the clock's" {
  assert_eq(clock_came_tree(false, 1000.0), (false, false, false))
}
