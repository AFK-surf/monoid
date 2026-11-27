// A table of data laid out by its page (数据表格) as nodes of the window's tree, made once: its rows, its heads' row
// and their cells naming their columns, each laid out by the page that makes it (as wide as its columns are worked
// out by its room, stacked where it is narrow: a station's 进程). What it is to a screen reader is mbui's headless
// table's (@headless.table: a table, its rows, its column heads); here its shell, the page's its look. What is pressed
// in it (a head that sorts, a row that opens its group) is action_box_node's.

///|
/// A table as its rows are made in it (grid_table_node's).
pub struct GridTable {
  priv tb : @headless.Table
}

///|
/// A row of a table as its cells are made in it (GridTable::row's).
pub struct GridRow {
  priv tr : @headless.TableRow
}

///|
/// A table in `parent` (`parent` itself where `in_node`: a node a structure made), `look` given its node and the
/// table its rows are made by (GridTable::row, directly or in what a list makes), once as it is made. Its node.
#callsite(autofill(loc))
pub fn grid_table_node(
  parent : @view.View,
  look : (@view.View, GridTable) -> Unit,
  in_node? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.table(made_for=loc, parent, in_node~, fn(v, tb) { look(v, { tb, }) })
}

///|
/// A row of `self` in `parent` (`parent` itself where `in_node`: the row a list made), `look` given its node and the
/// row its heads are made by (GridRow::head), once as it is made. Its node.
#callsite(autofill(loc))
pub fn GridTable::row(
  self : GridTable,
  parent : @view.View,
  look : (@view.View, GridRow) -> Unit,
  in_node? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  self.tb.row(made_for=loc, parent, in_node~, fn(v, tr) { look(v, { tr, }) })
}

///|
/// A cell of `self`, the heads' row, naming its column in `parent`, read by the words `look` puts in it, given its
/// node once as it is made. Its node.
#callsite(autofill(loc))
pub fn GridRow::head(self : GridRow, parent : @view.View, look : (@view.View) -> Unit, loc~ : SourceLoc) -> @view.View {
  self.tr.header(made_for=loc, parent, look)
}

///|
/// A sortable column header cell of `self` in `parent`, announcing `label()` together with `sort()` in `ColumnHeader`
/// semantics. Its node.
#callsite(autofill(loc))
pub fn GridRow::sort_head(
  self : GridRow,
  parent : @view.View,
  label : () -> String,
  sort : () -> @headless.TableSortDir?,
  look : (@view.View) -> Unit,
  sort_label? : (@headless.TableSortDir) -> String,
  in_node? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  self.tr.sort_header(made_for=loc, parent, label, sort, look, sort_label?, in_node~)
}

///|
/// A data cell of `self` in `parent`, read by the words `look` puts in it. Its node.
#callsite(autofill(loc))
pub fn GridRow::cell(
  self : GridRow,
  parent : @view.View,
  look : (@view.View) -> Unit,
  in_node? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  self.tr.cell(made_for=loc, parent, in_node~, look)
}
