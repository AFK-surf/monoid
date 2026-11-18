// A secret's value and the lines safe mode and the vault say beside it, shared (vault_item.mbt's, security.mbt's,
// vault.mbt's and lock_wait_node.mbt's before, drawn by each page): a secret's field (its name over its value, masked
// until shown, its keys at its end, concentric with the card's corner where it stands in it), a state on its line (its
// dot, what it is), a point (its mark on its first line, its words and the rest under them), words in the code face,
// and a use of something on its row (what, how, when on its first line).

///|
/// A secret's keys (show, copy) at its line's end, as a small icon button is (icon_button_side's 32).
pub let secret_key_side : Double = 32.0

///|
/// Their corner: the ladder's small block's (10), concentric with the card's where one stands in its corner
/// (card_end_out).
fn secret_key_corner() -> @ui.CornerOf? {
  Some(Own(small_corner))
}

///|
/// How long a secret copied stays on the clipboard (copySecret: 30 s).
pub let secret_copied_life : Double = 30000.0

///|
/// A secret's value masked: a dot a letter, 8 at least, 20 at most (how long it is not said exactly).
pub fn secret_mask(value : String) -> String {
  "•".repeat(@cmp.minimum(@cmp.maximum(value.length(), 8), 20))
}

///|
/// A secret's field in `row` (the node it is made in, a column: its name over its line, 4 apart): its `label`, then on
/// its line its `value` (masked till `shown()`, in the code face where `mono()`; on as many lines as it takes, or on
/// one, `one_line`, as a value masked by who keeps it is) growing from its start, and what `ends` makes at its end (its
/// keys: secret_key_node, secret_copy_node), the line reaching into the card's end corner (card_end_out).
#callsite(autofill(loc))
pub fn secret_value_row_node(
  row : @view.View,
  label : () -> String,
  value : () -> String,
  ends : (@view.View) -> Unit,
  shown? : () -> Bool = fn() { true },
  mono? : () -> Bool = fn() { false },
  one_line? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  style_node(row, fn() { secret_row }, loc~)
  words_node(row, label, fn() { secret_label }, loc~) |> ignore
  row.box(made_for=loc, fn(l) {
    style_node(l, fn() { secret_line }, loc~)
    l.box(fn(w) {
      w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
      if one_line {
        // (on one line: its words in a box of their own, as wide as they are)
        w.box(fn(o) {
          let look = fn() { @ui.style_words(secret_value) }
          o
          .words_runs(By(fn() { [@ui.span(value(), mono=mono())] }), look=@signals.untracked(look))
          .words_look(By(look))
          .ink(By(fn() { @ui.style_ink(secret_value) }))
          |> ignore
        })
        |> ignore
      } else {
        // (its look as the theme's is now: followed, the system's size of words changed)
        let look = fn() { @ui.style_words(secret_value_lines) }
        w
        .words_runs(By(fn() {
          let words = if shown() { value() } else { secret_mask(value()) }
          [@ui.span(words, mono=mono())]
        }), look=@signals.untracked(look))
        .words_look(By(look))
        .ink(By(fn() { @ui.style_ink(secret_value) }))
        |> ignore
      }
    })
    |> ignore
    ends(l)
  })
  |> ignore
}

///|
/// A key at a secret's line's end (show, hide: `icon`, or `icon_now()` as it changes) read out `label`, `press` done as
/// it is pressed: a small icon button, its corner concentric with the card's. The node.
#callsite(autofill(loc))
pub fn secret_key_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  icon_now? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  icon_button_node(loc~, parent, icon, label, press, size=secret_key_side, linked=secret_key_corner, icon_now?)
}

///|
/// 复制 at a secret's line's end: `value()` as it is put on the clipboard, a secret's (`secret()`) taken off it again
/// `secret_copied_life` later. The node.
#callsite(autofill(loc))
pub fn secret_copy_node(parent : @view.View, value : () -> String, secret : () -> Bool, loc~ : SourceLoc) -> @view.View {
  secret_key_node(loc~, parent, "copy", fn() { t("common.copy") }, fn() {
    let v = @signals.untracked(value)
    if @signals.untracked(secret) {
      @ui.clipboard_secret(v, clear_ms=secret_copied_life)
    } else {
      @ui.clipboard_set(v)
    }
  })
}

///|
/// A state on its line in `parent` (安全模式's: on or off): its dot (green while `on()`, else amber; state_dot_node's
/// 7) and what it is (`words()`, the body's 14 in 500 on one line), 8 apart, across its middle.
#callsite(autofill(loc))
pub fn status_banner_line_node(parent : @view.View, on : () -> Bool, words : () -> String, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(l) {
    style_node(l, fn() { status_banner_line }, loc~)
    state_dot_node(l, fn() { if on() { "up" } else { "restart" } }, loc~)
    words_node(l, words, fn() { status_banner_words }, loc~) |> ignore
  })
  |> ignore
}

///|
/// How a point is drawn (icon_point_row_node's): `Told`, a point of what something changes or gives up (its mark 18
/// muted in a column of 20, 8 from its words, the body's 14 on 28, growing; the rest the meta's under them); `Listed`, a
/// thing listed (a device: its mark 18 muted, 12 from its words, the UI's 13 on 24, as wide as they are and giving way
/// where the row has not the room).
#derive(Eq, Debug)
pub(all) enum PointLook {
  Told
  Listed
}

///|
/// A point in `parent`: its mark (`icon`, or `icon_now()` as it changes) on the first line of its words (`words()`,
/// and `rest()` quieter under them where given), never across the middle of their lines, as `look` says.
#callsite(autofill(loc))
pub fn icon_point_row_node(
  parent : @view.View,
  icon : String,
  words : () -> String,
  rest? : () -> String,
  icon_now? : () -> String,
  look? : PointLook = Told,
  loc~ : SourceLoc,
) -> Unit {
  let muted : @view.Live[Int64] = By(fn() { theme().p.muted })
  parent.box(made_for=loc, fn(l) {
    match look {
      Told => {
        style_node(l, fn() { point_told_line }, loc~)
        // (on its first line, across its middle: point_told_words')
        first_line_node(loc~, l, Body, leading=L7, fn(i) {
          i.width(Is(Some(point_told_column))) |> ignore
          icon_node(loc~, i, icon, point_glyph, muted, name_now?=icon_now) |> ignore
        })
        |> ignore
        l.box(fn(w) {
          style_node(w, fn() { point_told_box }, in_row=true, loc~)
          words_node(w, words, fn() { point_told_words }, loc~) |> ignore
          match rest {
            Some(r) => words_node(w, r, fn() { point_told_rest }, loc~) |> ignore
            None => ()
          }
        })
        |> ignore
      }
      Listed => {
        style_node(l, fn() { point_listed_line }, loc~)
        // (on its first line, across its middle: point_listed_words')
        first_line_node(loc~, l, Ui, leading=L6, fn(i) {
          icon_node(loc~, i, icon, point_glyph, muted, name_now?=icon_now) |> ignore
        })
        |> ignore
        l.box(fn(w) {
          // (as wide as its words, giving way where the row has not the room: they go on in another line)
          w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
          words_node(w, words, fn() { point_listed_words }, loc~) |> ignore
          match rest {
            Some(r) => words_node(w, r, fn() { point_told_rest }, loc~) |> ignore
            None => ()
          }
        })
        |> ignore
      }
    }
  })
  |> ignore
}

///|
/// Points one under another in `parent` (what `make` makes in it: icon_point_row_node's), 10 apart.
#callsite(autofill(loc))
pub fn icon_points_node(parent : @view.View, make : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(p) {
    style_node(p, fn() { icon_points }, loc~)
    make(p)
  })
  |> ignore
}

///|
/// Words in the code face (`words()` as they are now) in `parent`, of `style`.
#callsite(autofill(loc))
pub fn mono_words_node(parent : @view.View, words : () -> String, style : @ui.TextStyle, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(w) {
    let look = fn() { @ui.style_words(style) }
    w
    .words_runs(By(fn() { [@ui.span(words(), mono=true)] }), look=@signals.untracked(look))
    .words_look(By(look))
    .ink(By(fn() { @ui.style_ink(style) }))
    |> ignore
  })
  |> ignore
}

///|
/// Words in the code face on one line in `parent`, `words()` as they are now, of the theme's `size` as it is now
/// (followed: the system's size of words changed), in `ink()`; the letters as their face spaces them.
#callsite(autofill(loc))
pub fn mono_line_node(parent : @view.View, words : () -> String, size : @ui.TextSize, ink : () -> Int64, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(w) {
    let look = fn() -> @view.WordsLook {
      let (px, line) = @ui.tree_theme().text_size(size)
      { size: px, weight: 400, line, wrap: false, tracking: @view.letters_own, balance: false, max_lines: 0 }
    }
    w
    .words_runs(By(fn() { [@ui.span(words(), mono=true)] }), look=@signals.untracked(look))
    .words_look(By(look))
    .ink(By(ink))
    |> ignore
  })
  |> ignore
}

///|
/// Uses of something one under another in `parent` (what `make` makes in it: record_row_node's), 14 apart.
#callsite(autofill(loc))
pub fn record_rows_node(parent : @view.View, make : (@view.View) -> Unit, loc~ : SourceLoc) -> Unit {
  parent.box(made_for=loc, fn(l) {
    style_node(l, fn() { record_rows }, loc~)
    make(l)
  })
  |> ignore
}

///|
/// A use of something in `row` (the node it is made in, a row: a vault item's use by an agent): what used it on its
/// line (`name` makes it, in a row as wide as its column, 4 apart: its words and a mark after them), how under it (`how`
/// makes it: record_how_node), and when (`when()`, the meta's, muted) at the row's end on that first line, 12 apart.
#callsite(autofill(loc))
pub fn record_row_node(
  row : @view.View,
  name : (@view.View) -> Unit,
  how : (@view.View) -> Unit,
  when : () -> String,
  loc~ : SourceLoc,
) -> Unit {
  style_node(row, fn() { record_row }, loc~)
  row.box(made_for=loc, fn(t) {
    style_node(t, fn() { record_text }, in_row=true, loc~)
    t.grow(Is(1.0)).basis(Is(Some(0.0))).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    t.box(fn(n) {
      // (as wide as its column: what used it cut short there, what follows it kept)
      style_node(n, fn() { record_name_line }, loc~)
      n.min_width(Is(Some(0.0))) |> ignore
      name(n)
    })
    |> ignore
    how(t)
  })
  |> ignore
  // (when, on its first line)
  first_line_node(loc~, row, Ui, leading=L6, fn(w) { words_node(loc~, w, when, fn() { record_when }) |> ignore }) |> ignore
}

///|
/// How something was used (`words()`), under what used it: in the code face where it was a command (`command()`), the
/// list's note else.
#callsite(autofill(loc))
pub fn record_how_node(parent : @view.View, words : () -> String, command : () -> Bool, loc~ : SourceLoc) -> Unit {
  parent.pick(loc~, command, fn(p, is_command) {
    if is_command {
      mono_words_node(loc~, p, words, wide_list_note)
    } else {
      words_node(loc~, p, words, fn() { wide_list_note }) |> ignore
    }
  })
}

// ── styles ───────────────────────────────────────────────

///|
/// A secret's field (field: its name over its line, 4 apart).
// kept across runs: a value (no field of it changes)
let secret_row : @ui.Style = @ui.css("w=Full gap=S1")

///|
// kept across runs: a value (no field of it changes)
let secret_label : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, weight=Medium, color=Muted, w=Full)

///|
// kept across runs: a value (no field of it changes)
let secret_line : @ui.Style = @ui.css("row w=Full gap=S1 align=ACenter").then(card_end_out)

///|
// kept across runs: a value (no field of it changes)
let secret_value : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, wrap=false, w=grow, max_lines=1)

///|
// kept across runs: a value (no field of it changes)
let secret_value_lines : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=grow)

///|
/// A state's line (its dot and words: 8 apart, across its middle).
// kept across runs: a value (no field of it changes)
let status_banner_line : @ui.Style = @ui.css("row gap=S2 align=ACenter")

///|
/// The state (state: the body's 14 in 500, on one line).
// kept across runs: a value (no field of it changes)
let status_banner_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, weight=Medium, color=Fg, wrap=false)

///|
/// A point's mark across (18), in a column of 20 where it is told (sec_point_icon's w=S5).
let point_glyph : Double = 18.0

///|
let point_told_column : Double = 20.0

///|
/// Points (points: 10 apart; each its mark in a 20 column, 8 from its words, the body's 14).
// kept across runs: a value (no field of it changes)
let icon_points : @ui.Style = @ui.css("w=Full gap=S2_5")

///|
// kept across runs: a value (no field of it changes)
let point_told_line : @ui.Style = @ui.css("row w=Full gap=S2 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let point_told_box : @ui.Style = @ui.style(w=grow)

///|
// kept across runs: a value (no field of it changes)
let point_told_words : @ui.TextStyle = @ui.text_style(size=Body, leading=L7, color=Fg, w=Full)

///|
// kept across runs: a value (no field of it changes)
let point_told_rest : @ui.TextStyle = @ui.text_style(size=Meta, leading=L7, color=Muted, w=Full)

///|
/// A thing listed: its mark, 12, what it is, from the row's start, its mark on its first line.
// kept across runs: a value (no field of it changes)
let point_listed_line : @ui.Style = @ui.css("row gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let point_listed_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, color=Fg, w=Full)

///|
/// Uses (uses: 14 apart; a use what used it and how, its time at its end).
// kept across runs: a value (no field of it changes)
let record_rows : @ui.Style = @ui.css("w=Full gap=S3_5")

///|
// kept across runs: a value (no field of it changes)
let record_row : @ui.Style = @ui.css("row w=Full gap=S3 align=AStart")

///|
// kept across runs: a value (no field of it changes)
let record_text : @ui.Style = @ui.style(w=grow, gap=S0_5)

///|
// kept across runs: a value (no field of it changes)
let record_name_line : @ui.Style = @ui.css("row gap=S1 align=ACenter").then(@ui.css("w=Full"))

///|
// kept across runs: a value (no field of it changes)
let record_when : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false)
