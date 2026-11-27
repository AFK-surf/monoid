// A sidebar row's ground (nav_item_node's, nav_ground_node) with chips across its foot that show a tip each: the
// pointer gone from the row's words onto a chip, and from one chip to the next, keeps the row lit the whole way, never
// out and in again (the user, 2026-11-27: 「hover 在胶囊上的时候整个 profile 没有 hover 背景，导致左右移动会闪」).

///|
let nav_chip_marks : Array[String] = ["5h", "W"]

///|
/// A row of a sidebar with two chips that tip across its foot, a mouse's. The Tester.
fn nav_chips_tester() -> @ui.Tester {
  let t = @ui.Tester::new(fn(_c) {  }, w=320.0, h=200.0, platform=0)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    let layer : Ref[@view.View?] = Ref(None)
    let tips = TipLayer::new(fn() { layer.val })
    root.box(fn(list) {
      list.width(Is(Some(300.0))) |> ignore
      nav_item_node(
        list,
        Side,
        fn() { false },
        fn() { "账号" },
        fn(_) {  },
        fn(_) {  },
        fn(h) { nav_title_node(h, fn() { "账号" }) },
        foot=fn(f) {
          f.box(fn(r) {
            r.row(Is(true)).gap(Is(8.0)) |> ignore
            for mark in nav_chip_marks {
              fill_chip_node(r, fn() { 50 }, fn() { "ok" }, fn() { mark }, fn() { "50%" }, small=true, said=fn() {
                "剩余 50%"
              }, tips~)
              |> ignore
            }
          })
          |> ignore
        },
        foot_capsule=fill_chip_small_h,
      )
    })
    |> ignore
    layer.val = Some(root.box(fn(l) { l.over(Is(true)) |> ignore }))
  })
  t.draw()
  t
}

///|
/// How much of the pointer's ground is seen under the row (its colour's alpha against the hover's own), 0 where none.
fn nav_row_lit(t : @ui.Tester) -> Double {
  let (x, y, w, h) = t.get(Button, label="账号").rect
  let hover = theme().p.hover
  let mut most = 0.0
  for r in t.drawn_rects() {
    if (r.4 & 0xFFFFFF00L) == (hover & 0xFFFFFF00L) &&
      (r.4 & 0xFFL) > 0L &&
      (r.0 - x).abs() < 0.5 &&
      (r.1 - y).abs() < 0.5 &&
      (r.2 - w).abs() < 0.5 &&
      (r.3 - h).abs() < 0.5 {
      let a = (r.4 & 0xFFL).to_double() / (hover & 0xFFL).to_double()
      if a > most {
        most = a
      }
    }
  }
  most
}

///|
/// Where the middle of the chip marked `mark` is: its mark's words.
fn nav_chip_at(t : @ui.Tester, mark : String) -> (Double, Double) raise {
  guard t.words().iter().find_first(fn(w) { w.0 == mark }) is Some((_, x, y, w, h, _)) else {
    fail("no chip marked \{mark}")
  }
  (x + w / 2.0, y + h / 2.0)
}

///|
test "a sidebar row stays lit as the pointer goes from its words onto a chip that tips and on across the chips" {
  let t = nav_chips_tester()
  assert_eq(nav_row_lit(t), 0.0, msg="none lit")
  let (x, y, _, _) = t.get(Button, label="账号").rect
  t.move_to(x + 40.0, y + 12.0)
  t.run_for(dur_ms * 2.0)
  assert_eq(nav_row_lit(t), 1.0, msg="lit on its words")
  for mark in nav_chip_marks {
    let (cx, cy) = nav_chip_at(t, mark)
    t.move_to(cx, cy)
    // (at once and at rest: never faded out on the way)
    assert_eq(nav_row_lit(t), 1.0, msg="lit the moment the pointer is on chip \{mark}")
    t.run_for(dur_ms * 2.0)
    assert_eq(nav_row_lit(t), 1.0, msg="lit at rest on chip \{mark}")
  }
  t.move_to(310.0, 190.0)
  t.run_for(dur_ms * 2.0)
  assert_eq(nav_row_lit(t), 0.0, msg="out once the pointer is off the row")
}
