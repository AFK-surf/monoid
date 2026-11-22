// What waits in the composer to go with a message, as nodes of the window's tree (files.mbt's composer cards, made
// once): its ✕ hung on its corner (with_corner_remove's), a quote's card with the line for what is said about it
// (quote_card's `composer`), a file's card (file_card's `composer`) and a picture's tile.

///|
/// What a press on a file's card waiting in the composer was on: its card, its ↻, its ✎.
pub(all) enum WaitingPress {
  Opened
  Again
  Back
}

///|
/// A file waiting in the composer as its card in `parent` (file_card's `composer`, as nodes): its capsule as tall as a
/// picture's tile beside it (56), round as what waits in the composer is (`corner()`), on composer_card's ground (one
/// `named` by its path, none, its edge dashed in the strong line); its mark (a folder's where `dir`, red where it
/// failed), its `title` (else its name, cut short in its middle, never its extension) over what it says (`meta`; where
/// it `fails`, why, in red; going up, how far: `going`); a spinner where its mark is while it goes up and how far is not
/// known yet (`spins`); `retry` its ↻ and `restore` its ✎ at its end. `opens`: a press on it opens what it is (the hover
/// ground under the pointer). Its tip `tip`. What is pressed told `on_press`. The card's node.
#callsite(autofill(loc))
pub fn file_waiting_node(
  parent : @view.View,
  tips : @sf.TipLayer,
  name : () -> String,
  title : () -> String,
  meta : () -> String,
  corner : () -> Double,
  on_press : (WaitingPress) -> Unit,
  tip? : () -> String,
  dir? : () -> Bool = fn() { false },
  named? : () -> Bool = fn() { false },
  fails? : () -> Bool = fn() { false },
  spins? : () -> Bool = fn() { false },
  retry? : () -> Bool = fn() { false },
  restore? : () -> Bool = fn() { false },
  opens? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(card) {
    @sf.style_node(card, fn() { if named() { card_waiting_node } else { card_waiting_node.then(@sf.composer_card()) } })
    // (round as what waits is; one named by its path no ground of its own, its edge dashed in the strong line)
    card
    .radius(By(corner))
    .edge(By(fn() { if named() { (1.0, @sf.theme().p.line_strong) } else { (0.0, 0L) } }))
    .edge_dashed(By(named))
    |> ignore
    @sf.hover_ground_node(card, on=opens)
    card.says(By(fn() { Some(@view.said(Group, label=if title() != "" { title() } else { name() })) })) |> ignore
    @sf.tip_node(tips, card, match tip {
      Some(f) => f
      None => fn() { if title() != "" { meta() } else { name() } }
    })
    |> ignore
    @sf.card_presses_node(card, fn() { on_press(Opened) }, opens)
    // (its mark and its words together on the card's middle, the mark on their first line's middle, never on the middle
    // of both: apps/mbui/AGENTS.md, a mark beside a block of lines)
    let held = card.box(fn(row) {
      row.row(Is(true)).lines_up(Is(Some(Start))).gap(Is(@ui.Space::px(S2))).grow(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
    })
    @sf.first_line_node(held, Ui, leading=L6, fn(l) {
      l.pick(spins, at_once=true, fn(m, spinning) {
        @sf.style_node(m, fn() { @sf.card_mark }, in_row=true)
        if spinning {
          @sf.spinner_node(m, size=@sf.tile_going_spinner) |> ignore
        } else {
          @sf.icon_node(
            m,
            "file",
            @sf.card_mark_size,
            By(fn() { if fails() { @sf.theme().p.red } else { @sf.theme().p.muted } }),
            name_now=fn() { if dir() { "folder" } else { @sf.file_mark(name()) } },
          )
          |> ignore
        }
      })
    })
    |> ignore
    held.box(fn(w) {
      @sf.style_node(w, fn() { @sf.card_words }, in_row=true)
      w.pick(fn() { title() != "" }, at_once=true, fn(n, titled) {
        if titled {
          n.box(fn(row) {
            @sf.style_node(row, fn() { @sf.name_row })
            @sf.words_node(row, title, fn() { @sf.card_name }) |> ignore
          })
          |> ignore
        } else {
          @sf.file_name_node(n, name)
        }
      })
      @sf.words_node(w, meta, fn() { if fails() { @sf.card_failed } else { @sf.card_meta } }) |> ignore
    })
    |> ignore
    // (its button at its end on the card's middle, beside what it holds, never on its words' first line)
    card.show(retry, fn(e) {
      @sf.card_end_node(e, tips, "refresh", fn() { @sf.t("web-main.composer.retryUpload") }, fn() { on_press(Again) })
    })
    card.show(restore, fn(e) {
      @sf.card_end_node(e, tips, "edit", fn() { @sf.t("web-main.composer.expandPaste") }, fn() { on_press(Back) })
    })
  })
}





///|
/// A file's card waiting in the composer as a node (card_box's with card_waiting's, its corner the node's own: what
/// waits in the composer is round as composer_inner says): a row 56 high, 236 at most, its mark and words 16 in, 8
/// apart, on their middle.
// kept across runs: a value (no field of it changes)
let card_waiting_node : @ui.Style = @ui.style(
  row=true,
  max_w=Fixed(@sf.file_card_w),
  h=S14,
  px=S4,
  py=S2,
  gap=S2,
  align=ACenter,
)
