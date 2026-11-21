// Exclusive options that need a sentence each (parts.mbt choices', parts.tsx Choices) as nodes of the window's tree,
// made once: a radio group of bordered cards (@headless.radio_group), what the chosen one holds more under its line.

///|
/// Exclusive options that need a sentence each in `parent` (choices', as nodes): bordered cards 8 apart, one an
/// option (`options()`: each value, title and description), each its `icon` (by its value) on its title's line, its
/// title (13, 600) and description (12, muted; `note_made` makes one of its own, by its value) and a radio mark at its
/// end on its title's line (never across the middle of its lines: the user, 2026-11-14); the chosen one (`value()`)
/// edged in the ink, what it holds more (`extra`, by its value: a switch of it; none, nor its room, where it has none)
/// under its words; those `disabled` faded and taking no press. A radio group named `label` (each card a radio), one
/// stop of Tab's, ↑ ↓ moving along it; a press or Space choosing the one pressed (`choose` given its value).
#callsite(autofill(loc))
pub fn choices_node(
  parent : @view.View,
  value : () -> String,
  options : () -> Array[(String, String, String)],
  choose : (String) -> Unit,
  label? : () -> String = fn() { "" },
  icon? : (@view.View, String) -> Unit,
  note_made? : (@view.View, String) -> Unit,
  extra? : (String) -> ((@view.View) -> Unit)?,
  disabled? : (String) -> Bool = fn(_) { false },
  loc~ : SourceLoc,
) -> Unit {
  // a card (its look on the radio's own node, `item` its state): bordered (in a panel's body out to `panel_card_in` from
  // its sides, a card's corner, concentric with the panel's), its mark, words and radio on a line, what it holds more
  // under them while it is chosen
  let choice_card = fn(
    card : @view.View,
    item : @headless.RadioItem,
    title : () -> String,
    note : () -> String,
    icon : ((@view.View) -> Unit)?,
    note_made : ((@view.View) -> Unit)?,
    extra : ((@view.View) -> Unit)?,
  ) {
    let on = fn() { item.chosen() }
    // (in a panel's body: a card of the panel's, its words a card's padding in: the user, 2026-11-03, 面板里可以放卡片)
    let in_panel = match card.lent(panel_in_lent) {
      Some(p) => !p.small
      None => false
    }
    let narrow = look_node(card) is Narrow
    style_node(card, fn() {
      let look = if on() {
        choice_card_on
      } else if !item.disabled() && (item.hovered() || item.pressed()) {
        choice_card_hot
      } else {
        choice_card
      }
      if in_panel {
        look.then(panel_card_out_node(card)).then(@ui.style(radius=rounded(card_corner)))
      } else {
        look
      }
    })
    card.alpha(By(fn() { if item.disabled() { choice_disabled_alpha } else { 1.0 } })) |> ignore
    // (what stands beside its words stands across its title's line's middle: choice_title's)
    let on_first_line = fn(row : @view.View, make : (@view.View) -> Unit) {
      first_line_node(row, Ui, leading=L6, make) |> ignore
    }
    card.box(fn(hit) {
      let lone = note_made is None
      style_node(
        hit,
        fn() {
          let h = if lone && note() == "" { choice_hit } else { choice_hit_top }
          if in_panel {
            h.then(choice_hit_in_panel)
          } else {
            h
          }
        },
      )
      match icon {
        Some(f) => on_first_line(hit, f)
        None => ()
      }
      hit.box(fn(w) {
        style_node(w, fn() { choice_words }, in_row=true)
        words_node(w, title, fn() { choice_title }) |> ignore
        match note_made {
          Some(f) => f(w)
          None => w.show(fn() { note() != "" }, at_once=true, fn(n) { words_node(n, note, fn() { choice_note }) |> ignore })
        }
      })
      |> ignore
      // (its radio at its end, on its title's line, clear of the card's round corner: a circle by a corner's arc
      // stands concentric with it or clear of it, and this one's corner is too square for a circle 14 in to follow it)
      on_first_line(hit, fn(m) {
        m.box(fn(r) {
          style_node(r, fn() { if on() { radio_mark_on } else { radio_mark } })
          r.margin(Is((0.0, 0.0, choice_mark_clear(in_panel), 0.0))) |> ignore
          r.show(on, at_once=true, fn(dot) { style_node(dot, fn() { radio_dot }) })
        })
        |> ignore
      })
    })
    |> ignore
    // (parts.css.ts choiceExtra: under its words while it is chosen; narrow, its rows a step of the ladder in)
    match extra {
      Some(f) =>
        card.show(on, fn(o) {
          style_node(o, fn() { if narrow { choice_extra_rows } else { choice_extra } })
          o.box(fn(i) {
            style_node(i, fn() { if narrow { choice_extra_rows_in } else { choice_extra_in } })
            f(i)
          })
          |> ignore
        })
      None => ()
    }
  }
  parent.box(made_for=loc, fn(b) {
    style_node(b, fn() { choices_list })
    @headless.radio_group(
      b,
      label,
      value,
      fn(v) { if v != @signals.untracked(value) { @view.transition(within=b.transitions_root(), fn() { choose(v) }) } },
      axis=Vertical,
      fn(g, rg) {
        style_node(g, fn() { choices_list.then(@ui.style(gap=room(choice_gap))) })
        // (by value once: each choice reads its own option, told only as that one changes)
        let by_value = g.keyed_by(options, fn(o) { o.0 })
        g.each(fn() { by_value.keys() }, fn(v) { v }, fn(slot, v) {
          let v = v.untracked()
          let option = fn() { by_value.get(v) }
          let title = fn() { option().map(fn(o) { o.1 }).unwrap_or("") }
          let note = fn() { option().map(fn(o) { o.2 }).unwrap_or("") }
          rg.item(slot, fn() { v }, title, disabled=fn() { disabled(v) }, space_only=true, made_for=loc, fn(card, item) {
            choice_card(card, item, title, note, icon.map(fn(f) { fn(m : @view.View) { f(m, v) } }), note_made.map(fn(f) {
              fn(m : @view.View) { f(m, v) }
            }), extra.bind(fn(f) { f(v) }))
          })
          |> ignore
        })
      },
    )
    |> ignore
  })
  |> ignore
}

///|
/// choices_node's cards, one under the other, as wide as where they are.
// kept across runs: a value (no field of it changes)
let choices_list : @ui.Style = @ui.css("w=Full")

///|
/// How far a disabled choice is seen (choice_card's `disabled{opacity=O55}`).
let choice_disabled_alpha : Double = 0.55

///|
/// How much further in than its words a choice's radio stands from the card's end, so that it stands as far in as the
/// card's corner is round (clear of its arc): a card's corner less a card's padding in a panel, a row's corner less
/// choice_hit's 14 elsewhere.
fn choice_mark_clear(in_panel : Bool) -> Double {
  if in_panel {
    dmax(0.0, card_corner - card_pad)
  } else {
    dmax(0.0, row_corner - @ui.Space::px(S3_5))
  }
}
