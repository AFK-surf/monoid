// Folder-read error cards (for pages on `Bg` and panels on `Surface`) and narrow empty/crumb parts as nodes of the
// window's tree, shared across the files page, column view, chat files tab, and station files picker.

///|
/// Shared header + body lines for folder-read error surfaces: leading `info` icon aligned to the first line of `title`
/// (or directly to `words` when `title` is empty, e.g. stale refresh notices), followed by readable wrapping copy.
fn drive_err_lines_node(parent : @view.View, title : () -> String, words : () -> String) -> Unit {
  parent.pick(fn() { title() != "" }, at_once=true, fn(slot, titled) {
    @sf.style_node(slot, fn() { drive_err_body })
    if titled {
      slot.box(fn(head) {
        @sf.style_node(head, fn() { drive_err_head })
        @sf.first_line_node(head, Body, fn(m) {
          @sf.icon_node(m, "info", drive_err_icon, By(fn() { @sf.theme().p.red })) |> ignore
        })
        |> ignore
        head.box(fn(w) {
          @sf.style_node(w, fn() { drive_err_words_grow }, in_row=true)
          @sf.words_node(w, title, fn() { drive_err_title }) |> ignore
        })
        |> ignore
      })
      |> ignore
      slot.show(fn() {
        let w = words()
        w != "" && w != title()
      }, at_once=true, fn(n) {
        @sf.words_node(n, words, fn() { drive_err_note }) |> ignore
      })
    } else {
      slot.box(fn(head) {
        @sf.style_node(head, fn() { drive_err_head })
        @sf.first_line_node(head, Ui, leading=L5, fn(m) {
          @sf.icon_node(m, "info", drive_err_stale_icon, By(fn() { @sf.theme().p.red })) |> ignore
        })
        |> ignore
        head.box(fn(w) {
          @sf.style_node(w, fn() { drive_err_words_grow }, in_row=true)
          @sf.words_node(w, words, fn() { drive_err_stale_words }) |> ignore
        })
        |> ignore
      })
      |> ignore
    }
  })
}

///|
/// A folder-read error card on a page ground (`Bg`): surface card (`page_card_node(footed=true, layered=true)`) with a
/// leading `info` icon aligned to the first line of `title` (or of `words` when `title` is empty, e.g. stale refresh
/// failures), wrapping explanation in readable ink, and a concentric footer Retry button (`button_node`, `icon="retry"`).
pub fn drive_error_card_node(
  parent : @view.View,
  words : () -> String,
  retry : () -> Unit,
  title? : () -> String = fn() { @sf.t("web-pages.drive.cantOpen") },
  busy? : () -> Bool = fn() { false },
  tone? : @sf.Tone = Primary,
) -> Unit {
  @sf.page_card_node(parent, footed=true, layered=true, fn(k) {
    drive_err_lines_node(k, title, words)
    @sf.card_foot_node(k, fn(f) {
      @sf.button_node(f, fn() { @sf.t("web-pages.drive.retry") }, retry, tone~, icon="retry", busy~) |> ignore
    })
  })
}

///|
/// A folder-read error block inside a panel (`Surface`, e.g. chat files tab or station files picker): sits directly on
/// the panel's surface without nesting a second card, with the same icon-aligned title, readable wrapping explanation,
/// and standard Retry button. `compact`: aligns with a chat side-panel tab's compact rows (`px=S2_5` inside its `S2`
/// pad, matching `ftab_row_in`).
pub fn drive_panel_error_node(
  parent : @view.View,
  words : () -> String,
  retry : () -> Unit,
  title? : () -> String = fn() { @sf.t("web-pages.drive.cantOpen") },
  busy? : () -> Bool = fn() { false },
  tone? : @sf.Tone = Primary,
  compact? : Bool = false,
) -> Unit {
  parent.box(fn(b) {
    @sf.style_node(b, fn() {
      if compact {
        drive_panel_err_compact
      } else if @sf.panel_parts_gap_node(b) > 0.0 {
        @sf.panel_words_in_node(b).then(drive_panel_err_panel)
      } else {
        drive_panel_err_box
      }
    })
    drive_err_lines_node(b, title, words)
    b.box(fn(act) {
      @sf.style_node(act, fn() { drive_panel_err_act })
      @sf.button_node(act, fn() { @sf.t("web-pages.drive.retry") }, retry, tone~, icon="retry", busy~) |> ignore
    })
    |> ignore
  })
  |> ignore
}

///|
/// What could not be read in a narrow picker panel (`words`), and 重试: `retry` as it is pressed.
fn narrow_retry_node(
  v : @view.View,
  words : () -> String,
  retry : () -> Unit,
  busy? : () -> Bool = fn() { false },
) -> Unit {
  drive_panel_error_node(v, words, retry, busy~)
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
/// Leading icon size for folder-read error titles and stale notices.
let drive_err_icon : Double = 18.0

///|
let drive_err_stale_icon : Double = 16.0

///|
/// Text block inside a folder-read error card or panel block: full width, 6pt between title and explanation.
// kept across runs: a value (no field of it changes)
let drive_err_body : @ui.Style = @ui.css("w=Full gap=S1_5")

///|
/// First row (leading `info` mark + title or stale notice): top-aligned so the mark aligns with the first line.
// kept across runs: a value (no field of it changes)
let drive_err_head : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
/// Wrapping text column beside the leading mark: shrinks cleanly inside narrow columns and 320px screens.
// kept across runs: a value (no field of it changes)
let drive_err_words_grow : @ui.Style = @ui.style(w=@sf.grow, min_w=S0)

///|
// kept across runs: a value (no field of it changes)
let drive_err_title : @ui.TextStyle = @ui.text_style(size=Body, weight=Semibold, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let drive_err_note : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let drive_err_stale_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, w=Full)

///|
/// Folder-read error block inside a panel (`Surface`): aligned with the panel's words (`S5` = 20pt in picker panels;
/// `S2_5` = 10pt inside a chat side-panel tab's `S2` = 8pt padding, matching `ftab_row_in`), 14pt above its action.
// kept across runs: a value (no field of it changes)
let drive_panel_err_box : @ui.Style = @ui.css("w=Full px=S5 py=S3_5 gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let drive_panel_err_panel : @ui.Style = @ui.css("w=Full py=S3_5 gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let drive_panel_err_compact : @ui.Style = @ui.css("w=Full px=S2_5 py=S3 gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let drive_panel_err_act : @ui.Style = @ui.css("row w=Full align=ACenter")

///|
/// The crumbs (mCrumbs): 20 in, a crumb 4 round, the way's muted, where it is in the words' colour.
// kept across runs: a value (no field of it changes)
let narrow_crumbs_row : @ui.Style = @ui.css("row pl=S5 pr=S5 pt=S0_5 pb=S1 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb : @ui.Style = @ui.css("px=S1 py=S1 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let narrow_crumb_here : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let narrow_empty_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Muted, center=true, w=Full)
