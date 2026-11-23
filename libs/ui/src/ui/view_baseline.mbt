// Where the first line of a node's words is, told the layout as they are measured (@flex.first_line_told), so a row
// lining up what it holds by their first lines (View::lines_up_baseline, View::lines_up_first_line) puts them where
// they are drawn: the baseline set_line sets that line on (as browsers set lines too, set_web_lines; at the words' own
// size, View::words_scale), and that line's middle, from the top of the words.

///|
/// A node's words laid out as `tl` (view_words_measure_set, as they are drawn): their first line's, told.
fn view_words_first_told(tl : TextLayout) -> Unit {
  @flex.first_line_told(tl.ascent, tl.line_h / 2.0)
}

///|
/// A node's words in pieces laid out as `lay` (view_runs_measure_set, as they are drawn): their first line's, told;
/// none where they come to no line.
fn view_runs_first_told(lay : RichLayout) -> Unit {
  if lay.line_y.length() > 0 {
    @flex.first_line_told(lay.line_y[0] + lay.line_base[0], lay.line_y[0] + lay.line_h[0] / 2.0)
  }
}
