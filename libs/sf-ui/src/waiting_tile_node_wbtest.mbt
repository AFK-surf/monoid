// A picture waiting in the composer (waiting_tile_node): its veil and ring while it goes up, ↻ pressed trying again
// once it failed, a video's play mark only while it neither goes up nor failed; 56 square whatever it holds.

///|
/// A window holding one tile, its state as `going`, `failed` and `video` say, its tries again counted in `again`.
fn tile_tester(
  going : @signals.Signal[Bool],
  failed : @signals.Signal[Bool],
  video : @signals.Signal[Bool],
  again : Ref[Int],
) -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=160.0, platform=0)
  set_dark(Some(false))
  @ui.set_tree_theme(ui_theme_now)
  @ui.set_view_app(fn(root) {
    root.box(fn(page) {
      page.pad(Is(24.0)).lines_up(Is(Some(Start))) |> ignore
      waiting_tile_node(
        page,
        fn(p) { p.ground(Is(0x8899AAFFL)) |> ignore },
        fn() { going.get() },
        fn() { Some(0.5) },
        fn() { failed.get() },
        fn() { again.val += 1 },
        fn() { "重试" },
        video=fn() { video.get() },
      )
      |> ignore
    })
    |> ignore
  })
  t.draw()
  t
}

///|
/// What is drawn topmost in the tile's middle (24 + 28 each way), traced to where it was made.
fn tile_middle(t : @ui.Tester) -> String {
  t.sources_at(24.0 + waiting_tile_side / 2.0, 24.0 + waiting_tile_side / 2.0)
}

///|
/// Whether a veil is drawn over the tile: a fill as big as it, other than its picture's.
fn tile_veiled(t : @ui.Tester) -> Bool {
  t.drawn_rects().iter().any(fn(r) { r.2 == waiting_tile_side && r.3 == waiting_tile_side && r.4 != 0x8899AAFFL && (r.4 & 0xFFL) != 0L })
}

///|
test "waiting tile: the ring while it goes up, ↻ once it failed (pressed, tried again), a video's mark only at rest" {
  let going = @signals.signal(true, same=fn(a, b) { a == b })
  let failed = @signals.signal(false, same=fn(a, b) { a == b })
  let video = @signals.signal(true, same=fn(a, b) { a == b })
  let again = Ref(0)
  let t = tile_tester(going, failed, video, again)
  assert_true(tile_veiled(t), msg="going: no veil")
  going.set(false)
  failed.set(true)
  t.draw()
  t.click(Button, label="重试")
  t.draw()
  assert_eq(again.val, 1)
  failed.set(false)
  t.draw()
  assert_false(tile_veiled(t), msg="at rest: veiled")
  assert_true(tile_middle(t).contains("stillfail/sf/src/tool_node.mbt"), msg="video at rest: \{tile_middle(t)}")
  video.set(false)
  t.draw()
  assert_false(tile_middle(t).contains("stillfail/sf/src/tool_node.mbt"), msg="an image's: \{tile_middle(t)}")
}

///|
test "waiting tile: 56 square, as round as what waits in the composer" {
  let t = tile_tester(
    @signals.signal(false, same=fn(a, b) { a == b }),
    @signals.signal(false, same=fn(a, b) { a == b }),
    @signals.signal(false, same=fn(a, b) { a == b }),
    Ref(0),
  )
  let fills = t.drawn_rects().filter(fn(r) { r.4 == 0x8899AAFFL })
  guard fills is [f, ..] else { fail("no picture drawn") }
  assert_eq((f.2, f.3), (waiting_tile_side, waiting_tile_side))
}

///|
test "waiting tile: a hairline rim drawn over its picture, as round as it; red once it failed" {
  let failed = @signals.signal(false, same=fn(a, b) { a == b })
  let off = fn() { @signals.signal(false, same=fn(a, b) { a == b }) }
  let t = tile_tester(off(), failed, off(), Ref(0))
  let rims = t
    .drawn_rect_corners()
    .filter(fn(r) { r.2 == waiting_tile_side && r.3 == waiting_tile_side && r.4 != 0x8899AAFFL })
  guard rims is [(_, _, _, _, _, (r, _, _, _)), ..] else { fail("no rim: \{Repr(t.drawn_rect_corners())}") }
  assert_eq(r, composer_inner())
  failed.set(true)
  t.draw()
  let edged = t.drawn_rect_corners().iter().any(fn(r) { r.2 == waiting_tile_side && r.3 == waiting_tile_side })
  assert_true(edged, msg="failed: no edge")
}
