// A table's columns sized by what their cells say (View::tracks): each cell measured as the tree measures the words it
// draws (Tree's `measure_runs`, `measure_runs_least`: their pieces, how they are set, at the node's size of words),
// once as what the cells say or the size of words changes, never as the room does; the room shared out among the
// columns by its caller's rule from those measures, again only as the room or they change. Rows a page's list makes
// a few a block are sized by all of them, made or not.

///|
/// What one cell of a table says, for how wide its column is (View::tracks): words in pieces as the cell draws them
/// (View::words_runs: the pieces, how the words are set, how the pieces are), or a width of its own (pictures in a row).
#derive(Eq, Debug)
pub(all) enum TrackCell {
  Said(Array[@text.Run], WordsLook, RunsLook)
  Wide(Double)
}

///|
/// How wide a cell of a table may be (View::tracks): `least` wrapped (the widest of what lies between two places its
/// lines may break), `whole` on one line; `wide` where it is a width of its own that does not wrap.
#derive(Eq, Debug)
pub(all) struct TrackExtent {
  least : Double
  whole : Double
  wide : Bool
}

///|
/// A table's columns' widths (View::tracks): `widths`, as they change; `of`, another table's cells' (a row each, a
/// cell each) measured and shared out now, in the room as it is now, followed by nothing.
pub(all) struct Tracks {
  widths : () -> (Array[Double], Double)
  of : (Array[Array[TrackCell]]) -> (Array[Double], Double)
}

///|
/// The widths of a table's columns and all of them together, as `share` gives them of each cell's extent (`cells`, as
/// they change: a row each, the head's first, a cell each; measured at the size of words `self` is at, again as that
/// changes) and the room (`room`, as it changes). Each cell is measured once as the cells or the size of words change
/// (each counted as one measure, Tree's work: its words shaped once for both), never as the room does; `share` works again as either changes.
pub fn View::tracks(
  self : View,
  cells : () -> Array[Array[TrackCell]],
  room : () -> Double,
  share : (Array[Array[TrackExtent]], Double) -> (Array[Double], Double),
) -> Tracks {
  let tree = self.tree
  let measured = fn(rows : Array[Array[TrackCell]], scale : Double) {
    rows.map(fn(row) {
      row.map(fn(cell) {
        match cell {
          Said(runs, look, set) => {
            tree.work.measured = tree.work.measured + 1
            {
              least: (tree.measure_runs_least)(runs, look, set, scale),
              whole: (tree.measure_runs)(runs, look, set, -1.0, scale).0,
              wide: false,
            }
          }
          Wide(w) => { least: w, whole: w, wide: true }
        }
      })
    })
  }
  // (worked out again only as what the cells say, their size of words or how words are shaped comes to be otherwise:
  // what they read told again the same, or this read anew after what read it let go of it as it was parked, measures
  // nothing again)
  let extents = @signals.computed(fn(
    last : (Array[Array[TrackCell]], Double, Int, Array[Array[TrackExtent]])?,
  ) {
    let rows = cells()
    let scale = self.words_scale()
    let shaped = self.tree.words_redone.get()
    match last {
      Some((r, s, d, _) as same) if r == rows && s == scale && d == shaped => same
      _ => (rows, scale, shaped, measured(rows, scale))
    }
  })
  let widths = @signals.computed(fn(_) { share(extents.get().3, room()) })
  {
    widths: fn() { widths.get() },
    of: fn(rows) { @signals.untracked(fn() { share(measured(rows, self.words_scale()), room()) }) },
  }
}
