// `@ui.Align` first-line and baseline alignment through `@ui.css` and `Ctx` layout (node.mbt, layout.mbt,
// style_css.mbt): `AFirstLine` centers a mark on the first line of multi-line text beside it, and `ABaseline` puts
// words of different sizes on the same first-line baseline.

///|
test "css: align=AFirstLine and align=ABaseline parse to Align variants" {
  css_same("row align=AFirstLine", style(row=true, align=AFirstLine))
  css_same("row align=ABaseline", style(row=true, align=ABaseline))
}

///|
test "Ctx layout: align=AFirstLine centers a mark on the first line of wrapped text" {
  let title = "a title long enough to be wrapped onto two lines"
  let note = "and a note under it, wrapped as well onto its own lines"
  let row_style = css("row gap=S2 align=AFirstLine")
  let t = Tester::new(
    fn(c) {
      c.box(style=row_style, fn() {
        c.box(w=Px(16.0), h=Px(16.0), bg=0x3366FFFFL, fn() {  }) |> ignore
        c.box(w=Px(160.0), fn() {
          c.text(title, size=16.0, weight=600, line=24.0, wrap=true) |> ignore
          c.text(note, size=13.0, line=18.0, wrap=true) |> ignore
        })
        |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=400.0,
    platform=0,
    corners_held=false,
  )
  t.check_looks(false)
  t.draw()
  let (first, lines) = baseline_first(t.text_runs(), title)
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
}

///|
test "Ctx layout: align=ABaseline aligns words of different sizes on one first-line baseline" {
  let long = "a title long enough to be wrapped onto three lines or more"
  let row_style = css("row gap=S2 align=ABaseline")
  let t = Tester::new(
    fn(c) {
      c.box(style=row_style, fn() {
        c.box(w=Px(140.0), fn() {
          c.text(long, size=19.0, weight=600, line=26.0, wrap=true) |> ignore
        })
        |> ignore
        c.text("12 min", size=12.0, line=16.0, wrap=false) |> ignore
      })
      |> ignore
    },
    w=400.0,
    h=400.0,
    platform=0,
    corners_held=false,
  )
  t.check_looks(false)
  t.draw()
  let runs = t.text_runs()
  let (title, lines) = baseline_first(runs, long)
  let (meta, _) = baseline_first(runs, "12 min")
  assert_true(lines >= 3, msg="title wrapped onto \{lines} lines")
  assert_true(
    (title.base - meta.base).abs() <= 0.01,
    msg="title base \{title.base}, meta base \{meta.base}",
  )
  assert_true(meta.top > title.top + 0.5, msg="meta top \{meta.top} not dropped below title top \{title.top}")
}
