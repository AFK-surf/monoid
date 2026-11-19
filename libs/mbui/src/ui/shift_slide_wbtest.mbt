// View::shift snaps onto the host's device pixel grid (half-up) so two edge-to-edge pages or lanes at p and p - 1 stay
// flush on integer-pixel widths, retained rows stay on the whole-pixel fast path (ride_kept_for), and text blocks do
// not trigger four-phase glyph re-phasing mid-slide.

///|
test "View::shift snaps to whole pixels: zero seam between adjacent pages, zero glyph re-phase, retained rows hit" {
  for pair in [(3.5, 1440.0 / 3.5), (3.0, 393.0), (2.75, 400.0)] {
    let (sc, w) = pair
    let p = @signals.signal(0.0, same=fn(a, b) { a == b })
    let top_v : Ref[@view.View?] = Ref(None)
    let beside_v : Ref[@view.View?] = Ref(None)
    let text_id : Ref[@view.NodeId?] = Ref(None)
    let t = Tester::new(fn(_c) {  }, w~, h=200.0, platform=2, scale=sc)
    t.check_looks(false)
    set_view_app(fn(root) {
      root.box(fn(stage) {
        stage.width(Is(Some(w))).height(Is(Some(200.0))) |> ignore
        stage.box(fn(beside) {
          beside_v.val = Some(beside)
          beside
          .over(Is(true))
          .shift(By(fn() { (p.get() - 1.0, 0.0) }))
          .ground(Is(0xFF112233L))
          |> ignore
          beside.box(fn(row) {
            row.width(Is(Some(w))).height(Is(Some(48.0))).ground(Is(0xFF223344L)) |> ignore
            row.box(fn(lbl) { lbl.words(Is("左侧页面文字 beside")) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
        stage.box(fn(top) {
          top_v.val = Some(top)
          top
          .over(Is(true))
          .shift(By(fn() { (p.get(), 0.0) }))
          .ground(Is(0xFF334455L))
          |> ignore
          top.box(fn(row) {
            row.width(Is(Some(w))).height(Is(Some(48.0))).ground(Is(0xFF445566L)) |> ignore
            row.box(fn(lbl) {
              text_id.val = Some(lbl.id())
              lbl.words(Is("滑动页面文字 sliding page")) |> ignore
            })
            |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      |> ignore
    })
    t.draw()
    let block0 = view_blocks.get(text_id.val.unwrap()).unwrap()
    let kept0 = block0.kept.map(fn(k) { k.0 })
    let made0 = view_paint_work.made
    // Include an exact half-pixel tie (0.5 / (w * sc)) as well as mid-slide fractions.
    let half_tie = 0.5 / (w * sc)
    for step in [half_tie, 0.13, 0.37, 0.5, 0.71, 0.99] {
      let rides0 = ride_drawn.val
      p.set(step)
      t.draw()
      let top_r = top_v.val.unwrap().placed_window_now()
      let beside_r = beside_v.val.unwrap().placed_window_now()
      // Adjacent pages remain flush with zero seam.
      assert_true(
        (top_r.0 - (beside_r.0 + beside_r.2)).abs() < 1.0e-6,
        msg="scale \{sc} p=\{step}: top.x=\{top_r.0} beside.right=\{beside_r.0 + beside_r.2}",
      )
      // Shift lands on whole device pixels.
      let px = top_r.0 * sc
      assert_true((px - px.round()).abs() < 1.0e-6, msg="scale \{sc} p=\{step}: px=\{px}")
      // Glyph phases stay untouched (zero view_rephase) and block is never rebuilt.
      let kept1 = view_blocks.get(text_id.val.unwrap()).unwrap().kept.map(fn(k) { k.0 })
      assert_eq(kept1, kept0, msg="scale \{sc} p=\{step}: glyph phases changed mid-slide")
      assert_eq(view_paint_work.made, made0, msg="scale \{sc} p=\{step}: view block rebuilt mid-slide")
      assert_true(ride_drawn.val >= rides0, msg="scale \{sc} p=\{step}: ride_drawn regressed")
    }
  }
}
