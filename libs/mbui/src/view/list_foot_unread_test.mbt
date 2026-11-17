// Whether a page's list is at its foot (Scroll::at_foot_now), asked outside any reader while the list is there and
// after it is let go: what it read (its blocks, its keys) followed by nothing once the list is gone. Its computed kept
// on what it read after such a read, and its Scroll said it by the list gone, so the keys (a core's topic, where a page
// gives them) were followed for good, till 2026-11-15.

///|
test "a page's list's foot asked outside any reader: its keys followed by nothing once it is let go" {
  let on = @signals.signal(true, same=fn(a, b) { a == b })
  let keys = @signals.signal([0, 1, 2, 3, 4, 5, 6, 7], same=fn(a, b) { a == b })
  let s = @view.Scroll::list()
  let t = @view.Tree::new(fn(root) {
    root.show(at_once=true, fn() { on.get() }, fn(v) {
      v
      .height(Is(Some(300.0)))
      .scrolls_window(s, fn() { keys.get() }, fn(b, k) {
        b.height(Is(Some(50.0))).words(Is("row \{k}")) |> ignore
      })
      |> ignore
    })
  })
  t.frame(390.0, 844.0) |> ignore
  assert_true(keys.watched())
  // (asked while it is there, by nothing that follows it)
  @signals.untracked(fn() { s.at_foot_now() }) |> ignore
  on.set(false)
  t.frame(390.0, 844.0) |> ignore
  assert_false(keys.watched())
  // (and asked again once it is gone)
  @signals.untracked(fn() { s.at_foot_now() }) |> ignore
  assert_false(keys.watched())
  t.dispose()
}
