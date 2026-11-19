// Rows lining up what they hold by their first lines as the frame draws them (View::lines_up_baseline,
// View::lines_up_first_line; view_baseline.mbt telling the layout where a node's words' first line is): words of two
// sizes on one baseline however many lines the larger wraps on, and a mark on the middle of a title's first line
// above a note, lines as the web's or the host's, the system's size of words 1 or 1.3.

///|
fn baseline_look(size : Double, line : Double, wrap : Bool, weight? : Int = 400) -> @view.WordsLook {
  { size, weight, line, wrap, tracking: @view.letters_own, balance: false, max_lines: 0 }
}

///|
/// The first line `words` are drawn on (the topmost of those drawn of them), and how many lines that is.
fn baseline_first(runs : Array[TextRun], words : String) -> (TextRun, Int) {
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
test "lines_up_baseline: words of two sizes on one baseline, the larger wrapped on lines, lines as the web's or the host's, the system's size of words 1 or 1.3" {
  let long = "a title long enough to be wrapped onto three lines or more"
  for web in [true, false] {
    set_web_lines(web)
    for scale in [1.0, 1.3] {
      let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=if web { 0 } else { 2 }, corners_held=false)
      t.check_looks(false)
      set_view_app(fn(root) {
        root.box(fn(row) {
          row.row(Is(true)).gap(Is(8.0)).lines_up_baseline(Is(true)) |> ignore
          row.box(fn(w) {
            w.width(Is(Some(140.0))).words(Is(long), look=baseline_look(19.0, 26.0, true, weight=600)) |> ignore
          })
          |> ignore
          row.box(fn(w) { w.words(Is("12 min"), look=baseline_look(12.0, 16.0, false)) |> ignore })
          |> ignore
        })
        |> ignore
      })
      if scale != 1.0 {
        t.set_font_scale(scale)
      }
      t.draw()
      let runs = t.text_runs()
      let (title, lines) = baseline_first(runs, long)
      let (meta, _) = baseline_first(runs, "12 min")
      assert_true(lines >= 3, msg="web=\{web} scale=\{scale}: the title on \{lines} lines")
      assert_true(
        (title.base - meta.base).abs() <= 0.01,
        msg="web=\{web} scale=\{scale}: title base \{title.base}, meta base \{meta.base}",
      )
      // (off: at their starts, the meta's top at the title's, not on its baseline)
      assert_true(meta.top > title.top + 0.5, msg="web=\{web} scale=\{scale}: the meta not dropped to the baseline")
      assert_eq(t.audit(), [])
    }
  }
  set_web_lines(false)
}

///|
test "lines_up_first_line: a mark on the middle of a title's first line above a note, never the block's, lines as the web's or the host's, the system's size of words 1 or 1.3" {
  let title = "a title long enough to be wrapped onto two lines"
  let note = "and a note under it, wrapped as well onto its own lines"
  for web in [true, false] {
    set_web_lines(web)
    for scale in [1.0, 1.3] {
      let t = Tester::new(fn(_c) {  }, w=400.0, h=400.0, platform=if web { 0 } else { 2 }, corners_held=false)
      t.check_looks(false)
      set_view_app(fn(root) {
        root.box(fn(row) {
          row.row(Is(true)).gap(Is(8.0)).lines_up_first_line(Is(true)) |> ignore
          row.box(fn(m) {
            m.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x3366FFFFL)) |> ignore
          })
          |> ignore
          row.box(fn(col) {
            col.width(Is(Some(160.0))) |> ignore
            col.box(fn(w) { w.words(Is(title), look=baseline_look(16.0, 24.0, true, weight=600)) |> ignore }) |> ignore
            col.box(fn(w) { w.words(Is(note), look=baseline_look(13.0, 18.0, true)) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
      })
      if scale != 1.0 {
        t.set_font_scale(scale)
      }
      t.draw()
      let (first, lines) = baseline_first(t.text_runs(), title)
      assert_true(lines >= 2, msg="web=\{web} scale=\{scale}: the title on \{lines} lines")
      let marks = t.drawn_rects().filter(fn(r) { r.4 == 0x3366FFFFL })
      assert_eq(marks.length(), 1)
      let (_, my, _, mh, _) = marks[0]
      let line_mid = (first.top + first.bottom) / 2.0
      assert_true(
        (my + mh / 2.0 - line_mid).abs() <= 0.01,
        msg="web=\{web} scale=\{scale}: the mark's middle \{my + mh / 2.0}, the first line's \{line_mid}",
      )
      assert_eq(t.first_line_faults(), [])
      assert_eq(t.audit(), [])
    }
  }
  set_web_lines(false)
}
