// What a page keeps on a reader's words (reader_node's), lent by what holds the reader (reader_marks): the passages it
// marks on each block (notes kept on them), drawn over the paragraphs that have them. Each block's words say which
// block they are (@ui.picked_of: reader_block_key), so a page reading what is picked (@ui.picked_now) knows where in
// the text it is (Book's starts) without the reader knowing what is done with it.

///|
/// What a page keeps on a reader's words: `lits(k)`, the passages marked on block `k`, each with its ground;
/// `tapped()`, a tap on the text the page takes first (true: taken, a phone's bars left as they are: a note being
/// written finished); `bars(shown, show)`, the reader's phone bars handed to the page as it is made (whether they show,
/// and to show or take them away), so what the page puts at the reader's foot keeps clear of them.
pub(all) struct ReaderMarks {
  lits : (Int) -> Array[(String, Int64)]
  tapped : () -> Bool
  bars : (() -> Bool, (Bool) -> Unit) -> Unit
}

///|
// kept across runs: what each node lends (View::lends), let go with it
let reader_marks_lent : @view.Lent[ReaderMarks] = @view.Lent::new()

///|
/// The reader `v` holds (reader_node made in it) marks what `marks` says on its words. `v`.
pub fn reader_marks(v : @view.View, marks : ReaderMarks) -> @view.View {
  v.lends(reader_marks_lent, marks)
}

///|
/// What a reader's block `k` says its words are of, for what is picked of them (WordsPicked's `of`).
pub fn reader_block_key(k : Int) -> String {
  "reader-block:\{k}"
}

///|
/// The block a WordsPicked's `of` names (reader_block_key), none where it names no reader's block.
pub fn reader_block_of(of : String) -> Int? {
  guard of.has_prefix("reader-block:") else { return None }
  let mut n = 0
  let mut any = false
  for i, c in of {
    if i >= 13 {
      guard c >= '0' && c <= '9' else { return None }
      n = n * 10 + (c.to_int() - '0'.to_int())
      any = true
    }
  }
  if any {
    Some(n)
  } else {
    None
  }
}
