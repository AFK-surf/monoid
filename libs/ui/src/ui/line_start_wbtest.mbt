// Where lines under a marked line start (line_start.mbt, Tester::line_start_faults): a line under a row of a mark and
// words found starting between the two (a profile's row, its state line under the middle of its logo, 2026-11-15);
// one under the mark or under the words not, nor one under a row with no mark, nor lines centred in their column (a
// button of an icon and words over another button). A card's 28 mark held as a 16 is, and a line shown only by what
// is laid over it (a station's card, its offline line over its figures' room, 2026-11-15).

///|
/// The rule's faults on a column: a row of a mark (`side`, or none where `mark` is false) and words 8 after it, and
/// under it a line of words `under` in from the column's left (`laid_over`: those words in a layer over a room of 20
/// that shows nothing).
fn line_start_column(
  under : Double,
  mark? : Bool = true,
  centred? : Bool = false,
  side? : Double = 16.0,
  laid_over? : Bool = false,
) -> Array[String] {
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
            m.width(Is(Some(side))).height(Is(Some(side))).ground(Is(0x3366FFFFL)).radius(Is(4.0)) |> ignore
          })
          |> ignore
        }
        row.box(fn(w) { w.words(Is("Claude subscription")) |> ignore }) |> ignore
      })
      |> ignore
      if laid_over {
        col.box(fn(room) {
          room.height(Is(Some(20.0))) |> ignore
          room.box(fn(o) {
            o.over(Is(true)) |> ignore
            o.box(fn(w) { w.margin(Is((under, 0.0, 0.0, 0.0))).words(Is("Offline")) |> ignore }) |> ignore
          })
          |> ignore
        })
        |> ignore
      } else {
        col.box(fn(w) { w.margin(Is((under, 0.0, 0.0, 0.0))).words(Is("Needs signing in again")) |> ignore }) |> ignore
      }
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
  assert_eq(line_start_column(2.0), [])
  assert_eq(line_start_column(8.0, mark=false), [])
  assert_eq(line_start_column(0.0, centred=true), [])
}

///|
test "line start: under a card's 28 mark, and a line shown by what is laid over it, held the same" {
  let off = line_start_column(8.0, side=28.0)
  assert_eq(off.length(), 1, msg=off.join("\n"))
  assert_true(off[0].contains("starts at 24"), msg=off[0])
  let over = line_start_column(8.0, side=28.0, laid_over=true)
  assert_eq(over.length(), 1, msg=over.join("\n"))
  assert_true(over[0].contains("starts at 24"), msg=over[0])
  assert_eq(line_start_column(0.0, side=28.0), [])
  assert_eq(line_start_column(0.0, side=28.0, laid_over=true), [])
  assert_eq(line_start_column(36.0, side=28.0, laid_over=true), [])
}
