// Pills that pick and filter (筛选与计数胶囊) and a one-of list of rows, as nodes of the window's tree, made once:
// filter_pill_node, what is picked said in a capsule (its mark, its words, ▾), pressed to pick again, its × clearing
// it (concentric with the capsule's end) where something is picked; count_chip_node, one of several to choose between
// or a band's chip, its words, a state's dot and a count in figures of one width; radio_rows_node, a column of rows
// one of which is picked, one radio group (one stop of Tab's, ↑ ↓ choosing along it). What each is to the hand, the
// keyboard and a screen reader is mbui's headless parts' (button, choice, radio_group); here only their look.

///|
/// A filter's pill in `parent`: what is picked said in it (`words()`), `lead` making its mark before the words, a ▾
/// after them (`chevron`); pressed, `open` given the pill's button (what opens beside it). While `picked()`, on the
/// neutral ground, its words in the ink, and with `clear` a × at its end (read out `clear_label()`) clearing it,
/// concentric with the capsule's end; else edged alone, its words muted. Its words cut short before it runs past what
/// holds it. The pill.
#callsite(autofill(loc))
pub fn filter_pill_node(
  parent : @view.View,
  words : () -> String,
  open : (@view.View) -> Unit,
  picked? : () -> Bool = fn() { true },
  lead? : (@view.View) -> Unit,
  chevron? : Bool = true,
  clear? : () -> Unit,
  clear_label? : () -> String = fn() { "" },
  loc~ : SourceLoc,
) -> @view.View {
  let clears = fn() { clear is Some(_) && picked() }
  parent.box(made_for=loc, fn(pill) {
    style_node(pill, fn() { if picked() { filter_pill_picked } else { filter_pill } }, in_row=true)
    pill.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    let me : Ref[@view.View?] = Ref(None)
    @headless.button(pill, words, fn(_) { if me.val is Some(b) { open(b) } }, fn(btn, b) {
      me.val = Some(btn)
      style_node(btn, fn() { if clears() { filter_pill_button_cleared } else { filter_pill_button } }, in_row=true)
      btn.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      btn.focus_ring_theme() |> ignore
      hover_ground_node(btn, lit=Some(fn() { b.hovered() || b.pressed() || b.focus_shown() }))
      match lead {
        Some(f) => f(btn)
        None => ()
      }
      words_node(btn, words, fn() { if picked() { filter_pill_words } else { filter_pill_words_quiet } })
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .cuts(Is(true))
      .allow_ellipsis(Is(true))
      |> ignore
      if chevron {
        icon_node(btn, "chevron-down", filter_pill_chevron, By(fn() { theme().p.muted })) |> ignore
      }
    })
    |> ignore
    match clear {
      Some(f) =>
        pill.show(at_once=true, clears, fn(c) {
          style_node(c, fn() { filter_pill_clear_room }, in_row=true)
          c.shrink(Is(0.0)) |> ignore
          icon_button_node(c, "close", clear_label, f, size=filter_pill_clear, icon_size=13.0) |> ignore
        })
      None => ()
    }
  })
}

///|
/// How a count's chip looks: `Fill` (one of a card's pools to choose between: across its share of the row, on the
/// tint, the accent's under the one chosen, its words then its dot and count at its end); `Small` (a band's chip: as
/// wide as what it holds, 24 high, on the hover's ground); `Row` (a band's row: across it, its mark and words, on the
/// hover's ground under the hand).
#derive(Eq, Debug)
pub(all) enum ChipLook {
  Fill
  Small
  Row
}

///|
/// A count's chip in `parent`: `label()` its words, `count()` a count after them in figures of one width (none where
/// it says "" or is not given), a state's dot (`dot()`: state_dot_node's state) before the count (in Small, before the words), `lead` a
/// mark before the words; `alarm()`: its words in the danger's colour. With `chosen`, one of several to choose between
/// (@headless.choice), read out selected while it is; else a plain button (@headless.button). Pressed, `choose` given
/// the chip (what opens beside it). `look`: ChipLook's; `corner()`: Fill's corner (concentric with what holds it).
/// `named()`: what a screen reader calls it where that is not its words and count (what it opens, not what it shows).
/// The chip.
#callsite(autofill(loc))
pub fn count_chip_node(
  parent : @view.View,
  label : () -> String,
  choose : (@view.View) -> Unit,
  count? : () -> String,
  chosen? : () -> Bool,
  dot? : () -> String,
  lead? : (@view.View) -> Unit,
  alarm? : () -> Bool = fn() { false },
  look? : ChipLook = Fill,
  corner? : () -> Double = fn() { 1.0e6 },
  named? : () -> String,
  loc~ : SourceLoc,
) -> @view.View {
  let said = fn() {
    match named {
      Some(f) => return f()
      None => ()
    }
    let n = match count {
      Some(f) => f()
      None => ""
    }
    if n == "" {
      label()
    } else {
      label() + " " + n
    }
  }
  let is_chosen = fn() {
    match chosen {
      Some(f) => f()
      None => false
    }
  }
  let body = fn(chip : @view.View, lit : () -> Bool) {
    match look {
      Fill => {
        style_node(chip, fn() { count_chip_fill }, in_row=true)
        chip
        .padding(Is((12.0, 7.0, 12.0, 7.0)))
        .basis(Is(Some(0.0)))
        .min_width(Is(Some(0.0)))
        .min_height(By(fn() { Some(theme().items.least) }))
        .radius(By(corner))
        .ground(By(fn() {
          let t = theme()
          if is_chosen() {
            alpha(t.p.accent, if t.dark { 0.18 } else { 0.11 })
          } else {
            @ui.tree_theme().color(Tint)
          }
        }))
        |> ignore
      }
      Small => style_node(chip, fn() { count_chip_small }, in_row=true)
      Row => {
        style_node(chip, fn() { count_chip_row }, in_row=true)
        chip.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      }
    }
    chip.focus_ring_theme() |> ignore
    hover_ground_node(chip, on=fn() { !is_chosen() }, lit=Some(lit))
    match lead {
      Some(f) => f(chip)
      None => ()
    }
    // (in Small, the dot before the words: a band's chip says its state first)
    if look is Small {
      match dot {
        Some(d) => state_dot_node(chip, d)
        None => ()
      }
    }
    let w = words_node(chip, label, fn() {
      if alarm() {
        count_chip_words_alarm
      } else if look is Fill && is_chosen() {
        count_chip_words_chosen
      } else if look is Fill {
        count_chip_words_fill
      } else if look is Row {
        count_chip_words_row
      } else {
        count_chip_words
      }
    })
    w.shrink(Is(1.0)).min_width(Is(Some(0.0))).allow_ellipsis(Is(true)) |> ignore
    if look is (Fill | Row) {
      w.grow(Is(1.0)).basis(Is(Some(0.0))) |> ignore
      match dot {
        Some(d) => state_dot_node(chip, d)
        None => ()
      }
    }
    // (a count's words only where the chip has one: no structure for it where it never does)
    match count {
      Some(f) =>
        chip.show(at_once=true, fn() { f() != "" }, fn(n) {
          n.shrink(Is(0.0)) |> ignore
          words_node(n, f, fn() { count_chip_count }) |> ignore
        })
      None => ()
    }
  }
  match chosen {
    Some(now) =>
      @headless.choice(made_for=loc, parent, Button, said, now, choose, fn(chip, c) {
        body(chip, fn() { c.hovered() || c.pressed() || c.focus_shown() })
      })
    None =>
      @headless.button(made_for=loc, parent, said, choose, fn(chip, b) {
        body(chip, fn() { b.hovered() || b.pressed() || b.focus_shown() })
      })
  }
}

///|
/// A toggleable filter chip in `parent`: outer `@headless.toggle` keeps a >=44pt touch target (`items.least`, no
/// ground/edge/radius on the outer box so floating panel corners stay concentric) while an inner 30pt full-capsule
/// pill carries the bounded width (`max_w`) with ellipsis, neutral tint ground at rest, and accent fill + edge while
/// `on()`. Pressed, calls `toggle`. The chip.
#callsite(autofill(loc))
pub fn filter_toggle_chip_node(
  parent : @view.View,
  label : () -> String,
  on : () -> Bool,
  toggle : () -> Unit,
  max_w? : Double = 124.0,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(made_for=loc, parent, Button, label, on, fn(_) { toggle() }, fn(chip, b) {
    chip
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .max_width(Is(Some(max_w)))
    .min_width(Is(Some(0.0)))
    .min_height(By(fn() { Some(theme().items.least) }))
    .focus_ring_theme()
    |> ignore
    chip.box(made_for=loc, fn(pill) {
      pill
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .max_width(Is(Some(max_w)))
      .min_width(Is(Some(0.0)))
      .min_height(Is(Some(30.0)))
      .padding(Is((10.0, 4.0, 10.0, 4.0)))
      .radius(By(fn() { @ui.tree_theme().corner(Full) }))
      .edge(By(fn() {
        let t = theme()
        (control_edge_w, if on() { alpha(t.p.accent, 0.35) } else { t.p.line })
      }))
      .ground(By(fn() {
        let t = theme()
        if on() {
          alpha(t.p.accent, if t.dark { 0.18 } else { 0.11 })
        } else {
          @ui.tree_theme().color(Tint)
        }
      }))
      |> ignore
      hover_ground_node(pill, on=fn() { !on() }, lit=Some(fn() { b.hovered() || b.pressed() || b.focus_shown() }))
      words_node(pill, label, fn() { if on() { toggle_chip_words_on } else { count_chip_words } })
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .cuts(Is(true))
      .allow_ellipsis(Is(true))
      |> ignore
    })
    |> ignore
  })
}

///|
/// A row of a one-of list as its look reads it: whether it is picked, whether the hand or the keyboard is on it.
pub struct RadioRow {
  priv item : @headless.RadioItem
  priv node : @view.View
}

///|
/// Whether the row is the one picked now.
pub fn RadioRow::picked(self : RadioRow) -> Bool {
  self.item.chosen()
}

///|
/// Whether the hand or the keyboard is on the row now (lit_node's).
pub fn RadioRow::lit(self : RadioRow) -> Bool {
  lit_node(self.node)
}

///|
/// A one-of list of rows in `parent`, a radio group called `label()`: a row each of `choices()` (its value and its
/// words), the one picked `now()`; a press, Space, or ↑ ↓ Home End along it (round from its ends) telling `pick` the
/// value it comes to. One stop of Tab's (the one picked, else the first). `row` makes a row's look in its node, given
/// its words and how it is now; `gap` the room between rows (the column's it stands in). The list.
#callsite(autofill(loc))
pub fn radio_rows_node(
  parent : @view.View,
  label : () -> String,
  choices : () -> Array[(String, String)],
  now : () -> String,
  pick : (String) -> Unit,
  row : (@view.View, () -> String, RadioRow) -> Unit,
  gap? : Double = 0.0,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.radio_group(made_for=loc, parent, label, now, pick, axis=Vertical, fn(g, rg) {
    style_node(g, fn() { radio_rows_list })
    g.gap(Is(gap)) |> ignore
    let by_value = g.keyed_by(choices, fn(c) { c.0 })
    g.each(fn() { by_value.keys() }, fn(v) { v }, fn(slot, v) {
      let v = v.untracked()
      let words = fn() { by_value.get(v).map(fn(c) { c.1 }).unwrap_or("") }
      rg.item(slot, fn() { v }, words, space_only=true, fn(r, item) {
        r.focus_ring_theme() |> ignore
        row(r, words, { item, node: r })
      })
      |> ignore
    })
  })
}

///|
/// A row of tab chips in `parent` itself (`@headless.radio_group` with `kind=Tab`, `in_node=true`, no box of its own),
/// called `label`: one tab per key in `keys`, `chosen()` the key active now and `choose` told the key picked by a press
/// or ← → Home End. `said` gives each tab's screen-reader label; `look` lays out each tab's node, given the node, its
/// key and its `RadioRow` state (`picked`, `lit`); `on_item` (when given) is told each tab's key and node as it is made.
/// The group's node (`parent`).
#callsite(autofill(loc))
pub fn chip_tabs_node(
  parent : @view.View,
  label : () -> String,
  keys : Array[String],
  chosen : () -> String,
  choose : (String) -> Unit,
  said : (String) -> String,
  look : (@view.View, String, RadioRow) -> Unit,
  on_item? : (String, @view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.radio_group(
    made_for=loc,
    parent,
    label,
    chosen,
    choose,
    kind=Tab,
    in_node=true,
    fn(g, rg) {
      for key in keys {
        let chip = rg.item(g, fn() { key }, fn() { said(key) }, fn(c, item) {
          look(c, key, { item, node: c })
        })
        if on_item is Some(f) {
          f(key, chip)
        }
      }
    },
  )
}

///|
/// The pill's height (preset capsules', a press's room) and its ×, concentric with its end.
let filter_pill_clear : Double = 32.0

///|
let filter_pill_chevron : Double = 12.0

///|
/// The pill (the presets' capsule): a capsule edged in the line, 44 high; picked, on the neutral ground.
// kept across runs: a value (no field of it changes)
let filter_pill : @ui.Style = @ui.css("row min_h=S11 min_w=S0 align=ACenter radius=Full border=B0_5 border_color=Line")

///|
// kept across runs: a value (no field of it changes)
let filter_pill_picked : @ui.Style = filter_pill.then(@ui.css("bg=Neutral"))

///|
/// What opens it: its mark, words and ▾ 12 in, 6 apart, round as the pill.
// kept across runs: a value (no field of it changes)
let filter_pill_button : @ui.Style = @ui.css("row min_h=S11 min_w=S0 px=S3 gap=S1_5 align=ACenter radius=Full")

///|
/// With the × after it: as close to it as the × to the pill's end.
// kept across runs: a value (no field of it changes)
let filter_pill_button_cleared : @ui.Style = @ui.css("row min_h=S11 min_w=S0 pl=S3 pr=S1 gap=S1_5 align=ACenter radius=Full")

///|
/// The ×'s room: as far in from the pill's end as makes it concentric with it ((44 - 32) / 2).
// kept across runs: a value (no field of it changes)
let filter_pill_clear_room : @ui.Style = @ui.css("row pr=S1_5 align=ACenter")

///|
// kept across runs: a value (no field of it changes)
let filter_pill_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let filter_pill_words_quiet : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, w=Cut)

///|
/// Fill: across its share, 12 by 7 in, its parts 6 apart.
// kept across runs: a value (no field of it changes)
let count_chip_fill : @ui.Style = @ui.style(row=true, w=grow, gap=S1_5, align=ACenter)

///|
/// Small: 24 high, 8 in, on the hover's ground, round.
// kept across runs: a value (no field of it changes)
let count_chip_small : @ui.Style = @ui.css("row min_h=S6 px=S2 py=S0_5 gap=S1_5 align=ACenter bg=Hover radius=Full")

///|
/// Row: across the band, 32 high at least, 10 in, a side row's corner.
// kept across runs: a value (no field of it changes)
let count_chip_row : @ui.Style = @ui.css("row w=Full min_h=S8 px=S2_5 gap=S2 align=ACenter").then(@ui.style(radius=side_row_radius))

///|
// kept across runs: a value (no field of it changes)
let count_chip_words : @ui.TextStyle = @ui.text_style(size=Meta, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let toggle_chip_words_on : @ui.TextStyle = @ui.text_style(size=Meta, weight=Medium, color=AccentText, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let count_chip_words_fill : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Medium, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let count_chip_words_chosen : @ui.TextStyle = @ui.text_style(size=Ui, leading=L6, weight=Semibold, color=AccentText, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let count_chip_words_row : @ui.TextStyle = @ui.text_style(size=Ui, color=Fg, wrap=false, w=Cut)

///|
// kept across runs: a value (no field of it changes)
let count_chip_words_alarm : @ui.TextStyle = @ui.text_style(size=Ui, color=Danger, wrap=false, w=Cut)

///|
/// A count: figures of one width, muted.
// kept across runs: a value (no field of it changes)
let count_chip_count : @ui.TextStyle = @ui.text_style(size=Meta, leading=L5, color=Muted, wrap=false, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let radio_rows_list : @ui.Style = @ui.css("w=Full")
