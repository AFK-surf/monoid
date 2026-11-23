// Single-cell theme+font-scale row height cache and fixed-height list row primitive:
// keeps flex list rows on fixed `h=` (avoiding `min_h=` text-measure reflows across virtualized lists) while staying
// reactive to theme and system font-scale changes (e.g. 1.0x -> 1.3x) so rows never trigger `Tester::fixed_outgrown`.

///|
/// Single-cell row height cache keyed by `(theme.dark, v.words_scale(), theme.text.ui.1, theme.text.meta.1)`.
/// Every read touches `@ui.tree_theme()` and `v.words_scale()` so signal tracking stays live; while neither theme nor
/// font scale changes, `measure` is not called again and reads return in O(1) without allocation.
pub fn cached_row_height(v : @view.View, measure : (Double) -> Double) -> () -> Double {
  let cell : Ref[((Bool, Double, Double, Double), Double)?] = Ref(None)
  fn() {
    let th = @ui.tree_theme()
    let scale = v.words_scale()
    let key = (th.dark, scale, th.text.ui.1, th.text.meta.1)
    match cell.val {
      Some((k, h)) if k == key => h
      _ => {
        let h = measure(scale)
        cell.val = Some((key, h))
        h
      }
    }
  }
}

///|
/// Standard list-row fixed height formula backed by `cached_row_height`: respects the 44x44 touch target floor
/// (56 for two-line rows, and at least `theme().items.least`), accounts for narrow (`Body` + `text_in`) vs wide
/// (`Ui`/`L6` + `wide_row_over`) row typography and vertical padding, and rounds up to whole points to avoid
/// subpixel jitter.
pub fn std_row_height(v : @view.View, two_line? : Bool = false) -> () -> Double {
  let wide = look_node(v) is Wide
  cached_row_height(v, fn(scale) {
    let th = @ui.tree_theme()
    let least = dmax(if two_line { std_two_line_least } else { std_one_line_least }, theme().items.least)
    let (pad_y, title_line, note_line, gap) = if wide {
      (wide_row_over, dmax(th.text.ui.1, th.leading.l6), dmax(th.text.meta.1, th.leading.l5), desk_list_gap)
    } else {
      (text_in, dmax(th.text.body.1, th.text.ui.1), th.text.meta.1, std_narrow_note_gap)
    }
    let content = if two_line {
      @ui.sp_at(scale, title_line) + @ui.sp_at(scale, note_line) + gap
    } else {
      @ui.sp_at(scale, title_line)
    }
    dmax(least, content + pad_y * 2.0).ceil()
  })
}

///|
/// Minimum touch-target heights for single-line and two-line standard rows, and the narrow title-to-note gap.
let std_one_line_least : Double = 44.0

///|
let std_two_line_least : Double = 56.0

///|
let std_narrow_note_gap : Double = 0.0

///|
/// A fixed-height compound list row in `parent` (for single-line or two-line rows without multi-line wrapping body):
/// sets `height(By(std_row_height(row, two_line~)))` on the outer box so virtualized lists avoid `min_h=` reflows,
/// and delegates inner layout and interaction to `row_box_node`.
#callsite(autofill(loc))
pub fn fixed_row_node(
  parent : @view.View,
  label : () -> String,
  press? : () -> Unit,
  busy? : () -> Bool,
  two_line? : Bool = false,
  body : (RowScope) -> Unit,
  loc~ : SourceLoc,
) -> Unit {
  parent.box(made_for=loc, fn(row) {
    let h = std_row_height(row, two_line~)
    row.height(By(fn() { Some(h()) })) |> ignore
    row_box_node(loc~, row, label, press?, busy?, body)
  })
  |> ignore
}
