// Where lines under a marked line start (line_start.mbt, Tester::line_start_faults): a line under a row of a mark and
// words found starting between the two (a profile's row, its state line under the middle of its logo, 2026-11-15);
// one under the mark or under the words not, nor one under a row with no mark, nor lines centred in their column (a
// button of an icon and words over another button).

///|
/// The rule's faults on a column: a row of a mark (16, or none where `mark` is false) and words 8 after it, and under
/// it a line of words `under` in from the column's left.
fn line_start_column(under : Double, mark? : Bool = true, centred? : Bool = false) -> Array[String] {
  let t = Tester::new(fn(_c) {  }, w=400.0, h=200.0, platform=0, corners_held=false)
  set_view_app(fn(root) {
    root.box(fn(col) {
      col.width(Is(Some(300.0))).pad(Is(16.0)) |> ignore
      if centred {
        col.lines_up(Is(Some(Middle))) |> ignore
      }
      col.box(fn(row) {
        row.row(Is(true)).gap(Is(8.0)) |> ignore
        if mark {
          row.box(fn(m) {
            m.width(Is(Some(16.0))).height(Is(Some(16.0))).ground(Is(0x3366FFFFL)).radius(Is(4.0)) |> ignore
          })
          |> ignore
        }
        row.box(fn(w) { w.words(Is("Claude subscription")) |> ignore }) |> ignore
      })
      |> ignore
      col.box(fn(w) { w.margin(Is((under, 0.0, 0.0, 0.0))).words(Is("Needs signing in again")) |> ignore }) |> ignore
    })
    |> ignore
  })
  t.draw()
  t.line_start_faults()
}

///|
test "line start: a line under a marked line starting between its mark and its words found" {
  let off = line_start_column(8.0)
  assert_eq(off.length(), 1, msg=off.join("\n"))
  assert_true(off[0].has_prefix("line start: ") && off[0].contains("starts at 24"), msg=off[0])
}

///|
test "line start: under the mark, under the words, or under a row with no mark, nothing" {
  assert_eq(line_start_column(0.0), [])
  assert_eq(line_start_column(24.0), [])
  assert_eq(line_start_column(8.0, mark=false), [])
  assert_eq(line_start_column(0.0, centred=true), [])
}
