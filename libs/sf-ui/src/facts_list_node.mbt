// A list of facts (事实表) as nodes of the window's tree, made once: each fact its label, muted, in a column as wide
// as the widest label in this language (`least` at least, measured again as the system's size of words changes), then
// its value, which takes what is left of the row. A fact is there while it says something (`show`), shown or let go
// of alone, never the list made again. Each row is `fact_row_h` high at least, a line of words across its middle; a
// value of several lines starts where that line does, its label on the value's first line. A chat's info on
// 中屏 and 大屏 is the first list made of it.

///|
/// A fact's row, at least (chat_info's facts: 28).
pub let fact_row_h : Double = 28.0

///|
/// A list of facts as its rows read it: its node, and how wide its labels' column is now.
pub struct FactsList {
  priv list : @view.View
  priv label_w : () -> Double
}

///|
/// A list of facts in `parent` whose labels are `labels` (each said in a row of it by fact_row_node), their column as
/// wide as the widest of them at the theme's size of words now (`least` at least); `style` the list's own box (its
/// sides, how far apart its rows), `rows` making its rows. The list's node.
#callsite(autofill(loc))
pub fn facts_list_node(
  parent : @view.View,
  labels : Array[String],
  rows : (FactsList) -> Unit,
  least? : Double = 80.0,
  style? : () -> @ui.Style = fn() { facts_list_box },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(list) {
    style_node(list, style)
    // (words of a length known, whole: measured again as the system's size of words changes)
    let label_w = fn() {
      list.words_redone() |> ignore
      let size = node_sp(list, @ui.tree_theme().text_size(Ui).0)
      labels.fold(init=least, fn(m, l) {
        let w = node_words_w(l, size).ceil()
        if w > m {
          w
        } else {
          m
        }
      })
    }
    rows({ list, label_w })
  })
}

///|
/// A fact of `facts` while `show` says so: `label` (one of the list's labels) muted in the labels' column, then what
/// `value` makes in the rest of the row (given the value's box: a row, what it holds across its middle; as narrow as
/// it must be, never wider than what is left).
#callsite(autofill(loc))
pub fn fact_row_node(
  facts : FactsList,
  label : String,
  value : (@view.View) -> Unit,
  show? : () -> Bool = fn() { true },
  loc~ : SourceLoc,
) -> Unit {
  facts.list.show(loc~, show, fn(row) {
    style_node(row, fn() { fact_row })
    // (its label and its value each as far in from the row's top as a line of words is from a row's least's: one line
    // across a row's middle, and of several the first where the label is)
    let in_ = fn(v : @view.View) {
      v.words_redone() |> ignore
      let line = node_sp(v, @ui.tree_theme().text_size(Ui).1)
      let p = (fact_row_h - line) / 2.0
      if p > 0.0 {
        p
      } else {
        0.0
      }
    }
    row.box(fn(l) {
      style_node(l, fn() { fact_cell }, in_row=true)
      l.width(By(fn() { Some((facts.label_w)()) })).shrink(Is(0.0)).padding(By(fn() { (0.0, in_(l), 0.0, in_(l)) })) |> ignore
      words_node(l, fn() { label }, fn() { fact_label_words }) |> ignore
    })
    |> ignore
    row.box(fn(v) {
      style_node(v, fn() { fact_value }, in_row=true)
      v.shrink(Is(1.0)).padding(By(fn() { (0.0, in_(v), 0.0, in_(v)) })) |> ignore
      value(v)
    })
    |> ignore
  })
}

///|
// kept across runs: a value (no field of it changes)
let facts_list_box : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
/// A fact's row: its label and its value 12 apart, from its top (a value of several lines: its label on the first).
// kept across runs: a value (no field of it changes)
let fact_row : @ui.Style = @ui.style(row=true, w=Full, min_h=Fixed(fact_row_h), gap=S3, align=AStart)

///|
/// Its label's cell: its words across its middle.
// kept across runs: a value (no field of it changes)
let fact_cell : @ui.Style = @ui.css("row align=ACenter")

///|
/// Its value's: what is left of the row (as narrow as it must be), what it holds across its middle.
// kept across runs: a value (no field of it changes)
let fact_value : @ui.Style = @ui.style(row=true, w=grow, min_w=S0, align=ACenter)

///|
// kept across runs: a value (no field of it changes)
let fact_label_words : @ui.TextStyle = @ui.text_style(size=Ui, color=Muted, wrap=false)
