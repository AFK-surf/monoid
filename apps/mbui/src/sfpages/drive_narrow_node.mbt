// The narrow files' saying what could not be read and that nothing is here (narrow_retry_node, narrow_empty_node) as
// nodes of the window's tree, for what is made once (the station files picker: station_pick.mbt).

///|
/// What could not be read (`words`, in `look`), and 重试 after it in the link's ink: `retry` as it is pressed
/// (narrow_retry's).
fn narrow_retry_node(v : @view.View, words : () -> String, look : @ui.TextStyle, retry : () -> Unit) -> Unit {
  v.box(fn(b) {
    @sf.style_node(b, fn() { narrow_problem })
    b.box(fn(w) {
      @sf.style_node(w, fn() { narrow_problem_words }, in_row=true)
      @sf.words_node(w, words, fn() { look }) |> ignore
    })
    |> ignore
    @sf.action_box_node(b, fn() { @sf.t("web-pages.drive.retry") }, fn(_) { retry() }, fn(l) {
      @sf.style_node(l, fn() { narrow_link }, in_row=true)
      @sf.words_node(l, fn() { @sf.t("web-pages.drive.retry") }, fn() { narrow_link_words }) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// Nothing here (narrow_empty's): a folder's mark (40), why (`words`), and what can be done about it (`action`: its
/// words, what it does).
fn narrow_empty_node(v : @view.View, words : () -> String, action : (() -> String, () -> Unit)?) -> Unit {
  v.box(fn(b) {
    // (its words as wide as it, their lines in its middle, narrow_empty_words' w=Full and center; its mark and its
    // button in its middle, narrow_empty_box's align)
    @sf.style_node(b, fn() { narrow_empty_across })
    b.box(fn(m) {
      @sf.style_node(m, fn() { narrow_in_middle })
      @sf.icon_node(m, "folder", narrow_empty_icon, By(fn() { @sf.theme().p.subtle })) |> ignore
    })
    |> ignore
    @sf.words_node(b, words, fn() { narrow_empty_words }).words_centered(Is(true)) |> ignore
    match action {
      Some((label, go)) =>
        b.box(fn(m) {
          @sf.style_node(m, fn() { narrow_in_middle })
          @sf.button_node(m, label, go, tone=Ghost) |> ignore
        })
        |> ignore
      None => ()
    }
  })
  |> ignore
}

///|
/// narrow_empty_box, what it holds as wide as it.
// kept across runs: a value (no field of it changes)
let narrow_empty_across : @ui.Style = @ui.css("w=Full px=S8 py=S14 gap=S3")

///|
/// What it holds in its middle across.
// kept across runs: a value (no field of it changes)
let narrow_in_middle : @ui.Style = @ui.css("align=ACenter")


///|
/// The crumbs (mCrumbs): 20 in, a crumb 4 round, the way's muted, where it is in the words' colour, the chevrons
/// subtle.
fn narrow_way() -> @sf.WayLook {
  {
    line: narrow_crumbs_row,
    step: narrow_crumb,
    words: narrow_crumb_words,
    here: narrow_crumb_here,
    chevron: narrow_crumb_chevron,
    chevron_ink: @sf.theme().p.subtle,
  }
}

///|
let narrow_crumb_chevron : Double = 12.0

///|
let narrow_empty_icon : Double = 40.0

///|
/// Why it could not be read (mProblem): 20 in, 12 over and under, its 重试 in the link's ink.
// kept across runs: a value (no field of it changes)
let narrow_problem : @ui.Style = @ui.css("row w=Full px=S5 py=S3 gap=S3 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let narrow_problem_words : @ui.Style = @ui.style(w=@sf.grow)

///|
// kept across runs: a value (no field of it changes)
let narrow_link : @ui.Style = @ui.css("p=S1 radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let narrow_link_words : @ui.TextStyle = @ui.text_style(size=Body, color=Link, wrap=false)

///|
/// What could not be read (a station's folders): in red, as wide as the line.
// kept across runs: a value (no field of it changes)
let narrow_failed_words : @ui.TextStyle = @ui.text_style(size=Body, color=Danger, w=Full)

///|
/// The crumbs (mCrumbs): 20 in, a crumb 4 round, the way's muted, where it is in the words' colour.
// kept across runs: a value (no field of it changes)
let narrow_crumbs_row : @ui.Style = @ui.css("row pl=S5 pr=S5 pt=S0_5 pb=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb : @ui.Style = @ui.css("px=S1 py=S1 radius=Lg")

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb_here : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let narrow_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, w=Full)
