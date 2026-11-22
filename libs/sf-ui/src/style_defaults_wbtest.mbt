// `style_node` defaults for first-line/baseline alignment (`AFirstLine`, `ABaseline`) and concentric corners
// (`Radius::Inner`, `Radius::InnerOr`) inside containers (`group_node`, `wide_group_node`, `overlay_card_node`).

///|
fn first_run_of(runs : Array[@ui.TextRun], words : String) -> (@ui.TextRun, Int) {
  let of = runs.filter(fn(r) { r.text != "" && words.contains(r.text) })
  let mut first = of[0]
  for r in of {
    if r.top < first.top {
      first = r
    }
  }
  (first, of.length())
}

///|
fn box_radius_of(t : @ui.Tester, color : Int64) -> Double {
  let found = t.drawn_rect_corners().filter(fn(b) { b.4 == color })
  found[0].5.0
}

///|
test "style_node: align=AFirstLine centers a mark on the first line with zero first-line faults" {
  let title = "a title long enough to be wrapped onto two lines"
  let note = "and a note under it, wrapped onto its own lines as well"
  let row_style = @ui.css("row gap=S2 align=AFirstLine")
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0, corners_held=false)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(row) {
      style_node(row, fn() { row_style })
      row.box(fn(m) {
        m.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x3366FFFFL)) |> ignore
      })
      |> ignore
      row.box(fn(col) {
        col.width(Is(Some(160.0))) |> ignore
        words_node(col, fn() { title }, fn() { @ui.text_style(size=Ui, weight=Semibold, wrap=true) }) |> ignore
        words_node(col, fn() { note }, fn() { @ui.text_style(size=Meta, wrap=true) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let (first, lines) = first_run_of(t.text_runs(), title)
  assert_true(lines >= 2, msg="title wrapped onto \{lines} lines")
  let marks = t.drawn_rects().filter(fn(r) { r.4 == 0x3366FFFFL })
  assert_eq(marks.length(), 1)
  let (_, my, _, mh, _) = marks[0]
  let line_mid = (first.top + first.bottom) / 2.0
  assert_true(
    (my + mh / 2.0 - line_mid).abs() <= 0.01,
    msg="mark middle \{my + mh / 2.0}, first line middle \{line_mid}",
  )
  assert_eq(t.first_line_faults(), [])
  assert_eq(t.audit(), [])
}

///|
test "style_node: align=ABaseline aligns Ui and Meta text across web_lines and font scales" {
  let long = "a title long enough to be wrapped onto three lines or more"
  let row_style = @ui.css("row gap=S2 align=ABaseline")
  for web in [true, false] {
    @ui.set_web_lines(web)
    for scale in [1.0, 1.3] {
      let t = @ui.Tester::new(fn(_c) {  }, w=200.0, h=400.0, platform=if web { 0 } else { 2 }, corners_held=false)
      t.check_looks(false)
      @ui.set_view_app(fn(root) {
        @ui.set_tree_theme(ui_theme_now)
        root.box(fn(row) {
          style_node(row, fn() { row_style })
          row.width(Is(Some(200.0))) |> ignore
          row.box(fn(w) {
            w.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
            words_node(w, fn() { long }, fn() { @ui.text_style(size=Ui, weight=Semibold, wrap=true) }) |> ignore
          })
          |> ignore
          words_node(row, fn() { "12 min" }, fn() { @ui.text_style(size=Meta, wrap=false) }) |> ignore
        })
        |> ignore
      })
      if scale != 1.0 {
        t.set_font_scale(scale)
      }
      t.draw()
      let runs = t.text_runs()
      let (title, lines) = first_run_of(runs, long)
      let (meta, _) = first_run_of(runs, "12 min")
      assert_true(lines >= 3, msg="web=\{web} scale=\{scale}: title on \{lines} lines")
      assert_true(
        (title.base - meta.base).abs() < 0.01,
        msg="web=\{web} scale=\{scale}: title base \{title.base}, meta base \{meta.base}",
      )
      assert_eq(t.audit(), [])
    }
  }
  @ui.set_web_lines(false)
}

///|
test "style_node: dynamic switching between AFirstLine, ACenter, and AStart updates layout" {
  let title = "a title long enough to be wrapped onto three lines or more"
  let mode : @signals.Signal[Int] = @signals.signal(0)
  let s_first = @ui.css("row gap=S2 align=AFirstLine")
  let s_center = @ui.css("row gap=S2 align=ACenter")
  let s_start = @ui.css("row gap=S2 align=AStart")
  let t = @ui.Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=0, corners_held=false)
  t.check_looks(false)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.box(fn(row) {
      style_node(row, fn() {
        match mode.get() {
          0 => s_first
          1 => s_center
          _ => s_start
        }
      })
      row.box(fn(m) {
        m.width(Is(Some(12.0))).height(Is(Some(12.0))).ground(Is(0x3366FFFFL)) |> ignore
      })
      |> ignore
      row.box(fn(w) {
        w.width(Is(Some(120.0))) |> ignore
        words_node(w, fn() { title }, fn() { @ui.text_style(size=Ui, weight=Semibold, wrap=true) }) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  t.draw()
  let mark_y = fn() { t.drawn_rects().filter(fn(r) { r.4 == 0x3366FFFFL })[0].1 }
  let (first, lines) = first_run_of(t.text_runs(), title)
  assert_true(lines >= 3, msg="title on \{lines} lines")
  let y_first = mark_y()
  let line_mid = (first.top + first.bottom) / 2.0
  assert_true((y_first + 6.0 - line_mid).abs() <= 0.01)

  mode.set(1)
  t.draw()
  let y_center = mark_y()
  assert_true(y_center > y_first + 8.0, msg="ACenter \{y_center} should sit below AFirstLine \{y_first}")

  mode.set(2)
  t.draw()
  let y_start = mark_y()
  assert_true(y_start < y_first - 1.0, msg="AStart \{y_start} should sit above AFirstLine \{y_first}")

  mode.set(0)
  t.draw()
  let y_back = mark_y()
  assert_true((y_back - y_first).abs() <= 0.01, msg="back to AFirstLine \{y_back} vs \{y_first}")
}

///|
test "style_node: radius=Inner and InnerOr resolve concentrically inside group_node and overlay_card_node" {
  let s_inner = @ui.css("h=S12 radius=Inner")
  let s_inner_or = @ui.css("h=S12 radius=InnerOr(Md)")
  let c1 : Int64 = 0x112233FFL
  let c2 : Int64 = 0x223344FFL
  let c3 : Int64 = 0x334455FFL
  let c4 : Int64 = 0x445566FFL
  let c6 : Int64 = 0x667788FFL
  let c7 : Int64 = 0x778899FFL
  let c8 : Int64 = 0x8899AAFFL

  // Narrow group_node (list_card_corner - list_pad)
  let t = @ui.Tester::new(fn(_c) {  }, w=390.0, h=600.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    group_node(root, fn(g) {
      g.gap(Is(list_pad)) |> ignore
      g.box(fn(b) {
        style_node(b, fn() { s_inner })
        b.ground(Is(c1)) |> ignore
      })
      |> ignore
      g.box(fn(b) {
        style_node(b, fn() { s_inner_or })
        b.ground(Is(c2)) |> ignore
      })
      |> ignore
    })
  })
  t.draw()
  let want_narrow = list_card_corner - list_pad
  assert_eq(box_radius_of(t, c1), want_narrow)
  assert_eq(box_radius_of(t, c2), want_narrow)
  assert_eq(t.corner_faults(), [])
  assert_eq(t.audit(), [])

  // Wide group_node (list card and card=true)
  let card_corner_got : Ref[(Double, Double)?] = Ref(None)
  let t2 = @ui.Tester::new(fn(_c) {  }, w=900.0, h=600.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.lends(part_at, { ..part_of(root), look: Wide }) |> ignore
    group_node(root, fn(g) {
      g.box(fn(b) {
        style_node(b, fn() { s_inner })
        b.ground(Is(c3)) |> ignore
      })
      |> ignore
      g.box(fn(b) {
        style_node(b, fn() { s_inner_or })
        b.ground(Is(c4)) |> ignore
      })
      |> ignore
    })
    group_node(root, card=true, fn(g) {
      g.box(fn(b) {
        card_corner_got.val = match b.container_corner() {
          Some(cc) => Some(@signals.untracked(fn() { ((cc.radius)(), (cc.inset)()) }))
          None => None
        }
        style_node(b, fn() { s_inner_or })
      })
      |> ignore
    })
  })
  t2.draw()
  let want_wide_list = list_card_corner - list_pad
  assert_eq(box_radius_of(t2, c3), want_wide_list)
  assert_eq(box_radius_of(t2, c4), want_wide_list)
  assert_eq(card_corner_got.val, Some((ui_theme_now().corner(Xl3), card_pad)))
  assert_eq(t2.corner_faults(), [])
  assert_eq(t2.audit(), [])

  // overlay_card_node (small_panel_node: r_menu - panel_pad == row_corner)
  let t3 = @ui.Tester::new(fn(_c) {  }, w=600.0, h=400.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    overlay_card_node(
      root,
      fn(_) {  },
      place=fn(v) { v.width(Is(Some(240.0))) |> ignore },
      fn(card, _) {
        card.gap(Is(panel_pad)) |> ignore
        card.box(fn(b) {
          style_node(b, fn() { s_inner })
          b.ground(Is(c6)) |> ignore
        })
        |> ignore
        card.box(fn(b) {
          style_node(b, fn() { s_inner_or })
          b.ground(Is(c7)) |> ignore
        })
        |> ignore
      },
    )
    |> ignore
  })
  t3.draw()
  assert_eq(box_radius_of(t3, c6), row_corner)
  assert_eq(box_radius_of(t3, c7), row_corner)
  assert_eq(t3.corner_faults(), [])
  assert_eq(t3.audit(), [])

  // Outside any container: Inner -> 0.0, InnerOr(Lg) -> Lg
  let s_inner_lg = @ui.css("h=S12 radius=InnerOr(Lg)")
  let t4 = @ui.Tester::new(fn(_c) {  }, w=390.0, h=300.0, platform=0)
  @ui.set_view_app(fn(root) {
    @ui.set_tree_theme(ui_theme_now)
    root.gap(Is(8.0)) |> ignore
    root.box(fn(b) {
      style_node(b, fn() { s_inner })
      b.ground(Is(c1)) |> ignore
    })
    |> ignore
    root.box(fn(b) {
      style_node(b, fn() { s_inner_lg })
      b.ground(Is(c8)) |> ignore
    })
    |> ignore
  })
  t4.draw()
  assert_eq(box_radius_of(t4, c1), 0.0)
  assert_eq(box_radius_of(t4, c8), ui_theme_now().corner(Lg))
  assert_eq(t4.audit(), [])
}
