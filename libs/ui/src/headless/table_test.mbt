// The headless table (@headless.table, Table::row, TableRow::header, TableRow::cell), under a look of the tests' own:
// read out a Table of Rows, the head's row of ColumnHeaders and the rest of Cells, each row and cell read by the words
// it holds unless it is given a label, the table by its label alone; its rows and cells made by View::each too, the row or cell the structure made itself said
// to be one (`in_node`), coming and going as the rows do. Each window is made by `window` (window_test.mbt), which
// holds that table.mbt draws and lays out nothing.

///|
/// What the table's parts are read out as, in order: a line each, its depth under the window's root shown by two spaces
/// a step, its role and its name (a row's and a cell's the words they hold; the table's its label alone).
fn table_read(t : @ui.Tester) -> Array[String] {
  let parts : Array[@view.Role] = [Table, Row, ColumnHeader, Cell]
  t
  .semantics()
  .filter(fn(s) { !s.hidden && parts.contains(s.role) })
  .map(fn(s) { "  ".repeat(s.depth) + "\{s.role} \{s.label}" })
}

///|
/// A cell's look in the tests: as wide as said, its words in it.
fn table_cell_look(v : @view.View, words : () -> String) -> Unit {
  v.width(Is(Some(80.0))) |> ignore
  v.box(fn(w) { w.words(By(words)) |> ignore }) |> ignore
}

///|
test "a table: read out a Table of Rows, its head's cells ColumnHeaders, the rest Cells, each by the words it holds" {
  let t = window(fn(root) {
    @headless.table(root, fn(v, tb) {
      v.width(Is(Some(160.0))) |> ignore
      for r, row in [["名称", "价格"], ["苹果", "3"]] {
        tb.row(v, fn(line, tr) {
          line.row(Is(true)) |> ignore
          for words in row {
            let look = fn(c) { table_cell_look(c, fn() { words }) }
            if r == 0 {
              tr.header(line, look) |> ignore
            } else {
              tr.cell(line, look) |> ignore
            }
          }
        })
        |> ignore
      }
    })
    |> ignore
  })
  assert_eq(table_read(t), [
    "Table ", "  Row 名称 价格", "    ColumnHeader 名称", "    ColumnHeader 价格", "  Row 苹果 3", "    Cell 苹果", "    Cell 3",
  ])
}

///|
test "a table given labels: found by them, the table, a row and a cell; a cell's label as it changes" {
  let price = @signals.signal("3")
  let t = window(fn(root) {
    @headless.table(root, label=fn() { "价目" }, fn(v, tb) {
      tb.row(v, label=fn() { "苹果一行" }, fn(line, tr) {
        line.row(Is(true)) |> ignore
        tr.cell(line, label=fn() { "价格 \{price.get()}" }, fn(c) { table_cell_look(c, fn() { price.get() }) })
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  let first = (
    t.query(Table, label="价目") is Some(_),
    t.query(Row, label="苹果一行") is Some(_),
    t.query(Cell, label="价格 3") is Some(_),
  )
  price.set("4")
  t.frame()
  assert_eq((first, t.query(Cell, label="价格 4") is Some(_)), ((true, true, true), true))
}

///|
test "a table's rows and cells made by View::each, the row and the cell it made said to be them (in_node): rows come and go as the rows do" {
  let rows = @signals.signal([["名称"], ["苹果"]])
  let t = window(fn(root) {
    @headless.table(root, fn(v, tb) {
      v.each(fn() { Array::makei(rows.get().length(), fn(i) { i }) }, fn(i) { i }, fn(line, r) {
        let r = r.untracked()
        tb.row(line, in_node=true, fn(line, tr) {
          line.row(Is(true)) |> ignore
          line.each(fn() { Array::makei(rows.get().get(r).map_or(0, fn(c) { c.length() }), fn(k) { k }) }, fn(k) { k }, fn(
            cell,
            k,
          ) {
            let k = k.untracked()
            let words = fn() { rows.get().get(r).bind(fn(c) { c.get(k) }).unwrap_or("") }
            let look = fn(c) { table_cell_look(c, words) }
            if r == 0 {
              tr.header(cell, in_node=true, look) |> ignore
            } else {
              tr.cell(cell, in_node=true, look) |> ignore
            }
          })
        })
        |> ignore
      })
    })
    |> ignore
  })
  let two = table_read(t)
  rows.set([["名称", "价格"], ["苹果", "3"], ["梨", "5"]])
  t.frame()
  let three = table_read(t)
  rows.set([["名称", "价格"]])
  // (the rows gone closing their way out as rows of a column do: gone once that is over)
  t.run_for(@ui.move_most_ms)
  let one = table_read(t)
  assert_eq(two, ["Table ", "  Row 名称", "    ColumnHeader 名称", "  Row 苹果", "    Cell 苹果"])
  assert_eq(three, [
    "Table ", "  Row 名称 价格", "    ColumnHeader 名称", "    ColumnHeader 价格", "  Row 苹果 3", "    Cell 苹果", "    Cell 3",
    "  Row 梨 5", "    Cell 梨", "    Cell 5",
  ])
  assert_eq(one, ["Table ", "  Row 名称 价格", "    ColumnHeader 名称", "    ColumnHeader 价格"])
}

///|
test "a sortable column header reflects sort direction reactively in ColumnHeader semantics" {
  let dir : @signals.Signal[@headless.TableSortDir?] = @signals.signal(None)
  let t = window(fn(root) {
    @headless.table(root, fn(v, tb) {
      v.width(Is(Some(160.0))) |> ignore
      tb.row(v, fn(line, tr) {
        line.row(Is(true)) |> ignore
        tr.sort_header(line, fn() { "名称" }, fn() { dir.get() }, fn(c) { table_cell_look(c, fn() { "名称" }) })
        |> ignore
        tr.sort_header(
          line,
          fn() { "价格" },
          fn() { None },
          fn(c) { table_cell_look(c, fn() { "价格" }) },
          sort_label=fn(d) {
            match d {
              Asc => "升序"
              Desc => "降序"
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  })
  assert_true(t.query(ColumnHeader, label="名称") is Some(_))
  dir.set(Some(Asc))
  t.frame()
  assert_true(t.query(ColumnHeader, label="名称, ascending") is Some(_))
  dir.set(Some(Desc))
  t.frame()
  assert_true(t.query(ColumnHeader, label="名称, descending") is Some(_))
  dir.set(None)
  t.frame()
  assert_true(t.query(ColumnHeader, label="名称") is Some(_))
}
