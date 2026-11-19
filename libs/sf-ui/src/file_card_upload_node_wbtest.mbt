// A file's card going up (file_card_node's `pending`, `progress`, `open`): its mark a ring in its place, how far it has
// come where that is known (the accent's arc, not turning), turning where it is not or every byte is gone; its mark
// again once it is sent or failed (red then); nothing pressed on it while it has nothing to open.

///|
/// Long past the ring going once its file is sent (its mark back, the ring's leaving over).
let upload_gone_ms : Double = 1000.0

///|
/// Long past a tap: what it opens, opened.
let upload_tapped_ms : Double = 500.0

///|
/// A card in a column 400 wide, going up as `pending` says, `progress` as far, opening as `open` says; what pressing it
/// opened counted.
fn upload_card(
  pending : @signals.Signal[Bool],
  progress : @signals.Signal[Double?],
  open : Bool,
  opened : Ref[Int],
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=480.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lines_up(Is(Some(Start))) |> ignore
    let tips = TipLayer::new(fn() { None })
    root.box(fn(col) {
      col.width(Is(Some(400.0))) |> ignore
      file_card_node(
        col,
        tips,
        fn() { "季度报告.pdf" },
        fn() { "上传中" },
        fn() { false },
        fn() { false },
        fn() { false },
        fn() { "" },
        fn() { "" },
        fn(_) { opened.val += 1 },
        pending=fn() { pending.get() },
        progress=fn() { progress.get() },
        open=fn() { open },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// The ring's pieces of line drawn now (kind 10), and how far the first is turned.
fn upload_ring(t : @ui.Tester) -> (Int, Double) {
  let lines = t.drawn_instances().filter(fn(i) { i[5] == 10.0 })
  (lines.length(), lines.get(0).map_or(0.0, fn(i) { i[32] }))
}

///|
test "a file's card going up: a ring in its mark's place, not turning where how far is known, turning where it is not; its mark again once it is sent" {
  let pending = @signals.signal(true)
  let progress : @signals.Signal[Double?] = @signals.signal(Some(0.4))
  let t = upload_card(pending, progress, false, Ref(0))
  let (n, turned) = upload_ring(t)
  assert_true(n > 0, msg="a ring")
  t.frame_at(t.time() + 300.0)
  assert_eq(upload_ring(t), (n, turned))
  // (every byte gone, its station still to say so: turning)
  progress.set(Some(1.0))
  t.draw()
  let (_, a) = upload_ring(t)
  t.frame_at(t.time() + 300.0)
  let (m, b) = upload_ring(t)
  assert_true(m > 0 && a != b, msg="turning: \{a} \{b}")
  // (sent: no ring)
  pending.set(false)
  t.draw()
  t.run_for(upload_gone_ms)
  assert_eq(upload_ring(t).0, 0)
}

///|
test "a file's card with nothing to open takes no press; one that opens, opens" {
  for open in [false, true] {
    let opened = Ref(0)
    let t = upload_card(@signals.signal(false), @signals.signal(None), open, opened)
    t.tap(100.0, 20.0)
    t.run_for(upload_tapped_ms)
    assert_eq(opened.val, if open { 1 } else { 0 }, msg="open \{open}")
  }
}
