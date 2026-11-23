// The table: rows of cells, read out as one (WAI-ARIA's table, not its grid: nothing in it takes the keys as a whole,
// what is pressed in a cell pressed as anywhere). The table says it is a `Table` called by its label (none: read by what
// it holds); each row made by `Table::row` a `Row`; each cell made by `TableRow::header` a `ColumnHeader` (a cell of
// the head's row: what names its column) and by `TableRow::cell` a `Cell`, each read out by the words it holds unless
// it is given a label. It takes no press and no focus of its own, and draws and lays out nothing: its rows and cells,
// how wide each is, what rules them and how they scroll are all its look's.
//
// Each part made at its caller's place (`loc~`; `made_for`, where a library's part over it was asked for) in the node
// it is given, or that node itself where it is said to be one already (`in_node`: a row or a cell a structure makes,
// View::each's, the part what it made, no node more), handed to its look once and then said to be what it is: said
// after the look has run, so it stands whatever the look said (headless.mbt).

///|
/// A table as its look reads it, to make its rows by (`Table::row`).
pub struct Table {
  priv node : @view.View
}

///|
/// The table's own node: what its rows are made in, where they are not made in a part of it.
pub fn Table::node(self : Table) -> @view.View {
  self.node
}

///|
/// A row of a table as its look reads it, to make its cells by (`TableRow::header`, `TableRow::cell`).
pub struct TableRow {
  priv node : @view.View
}

///|
/// The row's own node: what its cells are made in, where they are not made in a part of it.
pub fn TableRow::node(self : TableRow) -> @view.View {
  self.node
}

///|
/// What a part of a table says it is: its role, called by `label` where it is given one (as that changes), else by
/// nothing (read by what it holds), said once.
fn table_said(role : @view.Role, label : (() -> String)?) -> @view.Live[@view.Said?] {
  match label {
    Some(f) => By(fn() { Some(@view.said(role, label=f())) })
    None => Is(Some(@view.said(role)))
  }
}

///|
/// The node of a part of a table in `parent` (`parent` itself, `in_node`), handed to `look` and then said `role`.
fn table_part(
  parent : @view.View,
  role : @view.Role,
  label : (() -> String)?,
  in_node : Bool,
  made_for : SourceLoc?,
  loc : SourceLoc,
  look : (@view.View) -> Unit,
) -> @view.View {
  let setup = fn(v : @view.View) {
    look(v)
    v.says(table_said(role, label)) |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}

///|
/// A table in `parent` (`parent` itself where `in_node`), called `label` where it is given one (what a screen reader
/// says of it; none: read by what it holds). `look` is given its node and the `Table` its rows are made by
/// (`Table::row`, directly or inside `View::each`), once as it is made: all that is drawn of it and how it is laid out.
/// Its node.
#callsite(autofill(loc))
pub fn table(
  parent : @view.View,
  look : (@view.View, Table) -> Unit,
  label? : () -> String,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  table_part(parent, Table, label, in_node, made_for, loc, fn(v) { look(v, { node: v }) })
}

///|
/// A row of `self` in `parent` (`parent` itself where `in_node`: the row a structure made), called `label` where it is
/// given one. `look` is given its node and the `TableRow` its cells are made by, once as it is made. Its node.
#callsite(autofill(loc))
pub fn Table::row(
  self : Table,
  parent : @view.View,
  look : (@view.View, TableRow) -> Unit,
  label? : () -> String,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  ignore(self)
  table_part(parent, Row, label, in_node, made_for, loc, fn(v) { look(v, { node: v }) })
}

///|
/// A cell of the head's row of `self`'s table, naming its column, in `parent` (`parent` itself where `in_node`), called
/// `label` where it is given one (none: read by the words it holds). `look` is given its node once as it is made. Its
/// node.
#callsite(autofill(loc))
pub fn TableRow::header(
  self : TableRow,
  parent : @view.View,
  look : (@view.View) -> Unit,
  label? : () -> String,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  ignore(self)
  table_part(parent, ColumnHeader, label, in_node, made_for, loc, look)
}

///|
/// A cell of `self` in `parent` (`parent` itself where `in_node`), called `label` where it is given one (none: read by
/// the words it holds). `look` is given its node once as it is made. Its node.
#callsite(autofill(loc))
pub fn TableRow::cell(
  self : TableRow,
  parent : @view.View,
  look : (@view.View) -> Unit,
  label? : () -> String,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  ignore(self)
  table_part(parent, Cell, label, in_node, made_for, loc, look)
}
