// pg_blocks_read: whether a list's keys changed to another set (some come and some gone in one change: there at once)
// or only came or only went (each making its way), as page_node, wide_page_node and panel_list_node read them.

///|
test "pg_blocks_read: another set in one change, read again in it, stays another; only coming or only going, not" {
  let was : Ref[Set[String]] = Ref(Set([]))
  let other = Ref(false)
  let read = fn(now : Array[String]) {
    pg_blocks_read(was, other, now) |> ignore
    other.val
  }
  assert_eq(read(["a", "b"]), false)
  // (all of them another: another set)
  assert_eq(read(["c", "d"]), true)
  // (the same change's list reading its keys again: what the change was stays)
  assert_eq(read(["c", "d"]), true)
  assert_eq(read(["c", "d"]), true)
  // (one taken away: it goes its way)
  assert_eq(read(["c"]), false)
  // (the last one taken away: it goes its way too, not another set)
  assert_eq(read([]), false)
  assert_eq(read([]), false)
  // (one come where there was none: it comes its way)
  assert_eq(read(["e"]), false)
  // (one kept, one come and one gone: another set)
  assert_eq(read(["e", "f"]), false)
  assert_eq(read(["e", "g"]), true)
}

///|
/// A panel's list of `keys`' rows, each 40 tall saying its key, in a column 300 wide and tall.
fn blocks_read_tester(keys : @signals.Signal[Array[String]]) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=300.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    root.box(fn(h) {
      h.width(Is(Some(300.0))).height(Is(Some(300.0))) |> ignore
      panel_list_node(
        h,
        fn() { keys.get() },
        fn(b, k) {
          b.height(Is(Some(40.0))) |> ignore
          words_node(b, fn() { "row " + k }, fn() { lists_words }) |> ignore
        },
        est=40.0,
        fills=true,
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t.run_for(@ui.move_most_ms)
  t
}

///|
/// Where row `k`'s words are drawn (their top) and how seen, none where they are not drawn.
fn blocks_read_row(t : @ui.Tester, k : String) -> (Double, Double)? {
  match t.words().filter(fn(w) { w.0 == "row " + k }) {
    [w, ..] => Some((w.2, w.5))
    _ => None
  }
}

///|
test "panel_list_node: its keys another set, read more than once in the change: there at once, the old gone; its last row taken away closes its way" {
  let keys = @signals.signal(["a", "b"])
  let t = blocks_read_tester(keys)
  let a_at = blocks_read_row(t, "a")
  let b_at = blocks_read_row(t, "b")
  assert_true(a_at is Some(_) && b_at is Some(_))
  // (another folder: c and d in a's and b's places from the change's first frame, a and b gone with it)
  @ui.view_tree().unwrap().event(t.time(), fn() { keys.set(["c", "d"]) })
  t.frame()
  assert_eq(blocks_read_row(t, "a"), None)
  assert_eq(blocks_read_row(t, "b"), None)
  assert_eq(blocks_read_row(t, "c").map(fn(p) { p.0 }), a_at.map(fn(p) { p.0 }))
  assert_eq(blocks_read_row(t, "d").map(fn(p) { p.0 }), b_at.map(fn(p) { p.0 }))
  t.run_for(@ui.move_most_ms)
  assert_eq(blocks_read_row(t, "c").map(fn(p) { p.0 }), a_at.map(fn(p) { p.0 }))
  // (one taken away, then the last: each closes its way, still drawn a frame after, gone once it is over)
  @ui.view_tree().unwrap().event(t.time(), fn() { keys.set(["c"]) })
  t.frame()
  assert_true(blocks_read_row(t, "d") is Some(_), msg="d gone at once")
  t.run_for(@ui.move_most_ms)
  assert_eq(blocks_read_row(t, "d"), None)
  @ui.view_tree().unwrap().event(t.time(), fn() { keys.set([]) })
  t.frame()
  assert_true(blocks_read_row(t, "c") is Some(_), msg="the last row gone at once")
  t.run_for(@ui.move_most_ms)
  assert_eq(blocks_read_row(t, "c"), None)
}
