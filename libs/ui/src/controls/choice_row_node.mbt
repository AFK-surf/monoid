// A row of a list of choices (choice_row's) as a node of the window's tree: one of them chosen, its check at its end;
// laid out where it stands as the old one is (a narrow page's row, a wide list's, a panel's body's: panel_in_of).

///|
/// A row of a list of choices in `parent` (choice_row's), one of them `chosen()`: what it is given (`body`: its mark,
/// its words; or `lead` before `label` with `tag` after it on its line and `note` under them, a page row's), and
/// `trail` (a part of its own, which takes its own press) before a check at its end while it is the one chosen; the rest
/// of the row takes the press (`press`, as it is let go), lit under the hand and rippling under a finger's press
/// (narrow: a page's row, square, or a card's on a group's card, as the group lends it: on_card_node; wide: a list's
/// row), not while `disabled()` (its words faint), and lit as well while `held()` (what its press put up beside it is
/// open: it is that one's, as a menu's trigger is). `ink`: its label's own (red for one that takes something away).
/// `grounded`: given the box its ground is drawn on as it is made (what is put up beside it stands by that).
/// `label_made`, `note_made`: what makes its label's words and its note's in the box given, where they are not a page
/// row's words as said (a face's name and a line of it, each drawn in that face), where those would be. Read out a
/// button named `label`, selected while chosen.
#callsite(autofill(loc))
pub fn choice_row_node(
  parent : @view.View,
  label : () -> String,
  chosen : () -> Bool,
  press? : () -> Unit,
  note? : () -> String = fn() { "" },
  body? : (@view.View) -> Unit,
  lead? : (@view.View) -> Unit,
  tag? : (@view.View) -> Unit,
  trail? : (@view.View) -> Unit,
  ink? : () -> Int64,
  note_ink? : () -> Int64,
  compact? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  held? : () -> Bool = fn() { false },
  grounded? : (@view.View) -> Unit = fn(_) { () },
  label_made? : (@view.View) -> @view.View,
  note_made? : (@view.View) -> @view.View,
  loc~ : SourceLoc,
) -> Unit {
  let t = fn() { theme() }
  let narrow = look_node(parent) is Narrow
  let at = panel_in_of(parent)
  let part = part_of(parent)
  let card = on_card_node(parent)
  let goes = fn() { !disabled() }
  // (its words as a page's row has them: the label, what follows it on its line, a note under them, its end on that
  // line where a note is under them, a `compact` panel row's too: what is beside two lines on the first of them, never
  // across their middle, the user, 2026-11-14)
  let under = fn() { body is None && note() != "" }
  let chevron = if narrow { pg_chevron } else { desk_chevron }
  // (how tall its first line is, its label's line: what is beside it there laid out across that line's middle)
  let first_line = fn(v : @view.View) {
    v.words_redone() |> ignore
    let th = @ui.tree_theme()
    node_sp(v, if narrow { th.text_size(Body).1 } else { th.leading(L6).unwrap_or(th.text_size(Ui).1) })
  }
  // (where it stands across in a panel's body, row_line's: panel_row_at, not on a card; elsewhere a page's row's; on a
  // page's list in a panel's card its ground reaching past it over and under: link_reach)
  let in_panel = panel_row_at(at, own=if narrow { card_pad - corner_inset } else { desk_list_out }, card~)
  let out = match in_panel {
    Some(p) => p.out
    None => 0.0
  }
  let reach = !narrow && part.list && in_pane_node(parent) && at.words == 0.0
  parent.box(made_for=loc, fn(o) {
    if reach {
      o
      .margin(Is((0.0, -link_pane_out, 0.0, -link_pane_out)))
      .padding(Is((0.0, link_pane_out, 0.0, link_pane_out)))
      .radius(By(fn() { list_row_corner(o) }))
      |> ignore
    }
    @headless.choice(
      o,
      Button,
      label,
      chosen,
      fn(_) {
        match press {
          Some(f) => f()
          None => ()
        }
      },
      disabled~,
      fn(r, ch) {
        let (side, over) = if compact {
          let side = match in_panel {
            Some(p) => p.side
            None => if narrow && !card { pg_room_in } else { text_in }
          }
          (side, if narrow { @ui.Space::S2_5.px() } else { menu_row_over })
        } else if in_panel is Some(p) {
          (p.side, if narrow { text_in } else { wide_row_over })
        } else if narrow {
          (if card { text_in } else { pg_room_in }, text_in)
        } else {
          (text_in, wide_row_over)
        }
        let corner = if at.small {
          small_panel_inner(r_menu)
        } else if narrow {
          // (a page's row across it square; in a panel, round where it stands in from its sides: panel_row_corner)
          if card {
            if parent.lent(panel_in_lent) is Some(p) && !p.small { dialog_row_corner } else { row_corner }
          } else if in_panel is Some(_) || at.sides > 0.5 {
            panel_row_corner(at, out)
          } else {
            0.0
          }
        } else if reach {
          0.0
        } else if part.list {
          list_row_corner(r)
        } else if parent.lent(panel_in_lent) is Some(p) && !p.small {
          dialog_row_corner
        } else {
          @signals.untracked(fn() { @ui.tree_theme().corner(Xl2) })
        }
        r
        .row(Is(true))
        .gap(Is(if compact { panel_row_gap } else { 12.0 }))
        .margin(Is((-out, 0.0, -out, 0.0)))
        .padding(Is((side, over, side, over)))
        .radius(Is(corner))
        .min_height(By(fn() { Some(t().items.least) }))
        .lines_up(By(fn() { Some(if under() { Start } else { Middle }) }))
        |> ignore
        let g = if reach { o } else { r }
        r.focus_ring_theme() |> ignore
        hover_ground_node(g, by=r, on=goes, extra=held)
        grounded(g)
        if narrow {
          // (a finger's press rippling over it, its corner the row's: row_ripple's)
          rippled_look(loc~, r, Is(corner), fn() { ch.press() })
        }
        // its end: what it has of its own, then its check while it is the one chosen; none of the row's room while it has
        // neither (the old one's end, drawing nothing)
        let ended = fn() { trail is Some(_) || chosen() }
        let end = fn(e : @view.View) {
          match trail {
            Some(f) => f(e)
            None => ()
          }
          e.show(chosen, at_once=true, fn(k) {
            k.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
            icon_node(k, "check", chevron, By(fn() { t().p.accent })) |> ignore
          })
        }
        match body {
          // (what it is given made in the row itself, as the old one's body is: its end after it)
          Some(f) => f(r)
          None => {
            match lead {
              Some(f) =>
                r.box(fn(l) {
                  // (by its first line where a note is under it: as tall as that line at least, across its middle;
                  // row_lead's)
                  l
                  .row(Is(true))
                  .lines_up(Is(Some(Middle)))
                  .min_height(By(fn() { if under() { Some(first_line(l)) } else { None } }))
                  |> ignore
                  f(l)
                })
                |> ignore
              None => ()
            }
            r.box(fn(words) {
              words.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
              if !narrow || compact {
                words.gap(Is(@ui.Space::S0_5.px())) |> ignore
              }
              words.box(fn(first) {
                first.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
                // (its label and what follows it on its line, 6 apart: choice_label_line)
                first.box(fn(line) {
                  line.row(Is(true)).gap(Is(6.0)).lines_up(Is(Some(Middle))).grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
                  let w = match label_made {
                    Some(f) => f(line)
                    None =>
                      words_node(line, label, fn() {
                        let base = if narrow { pg_row_title } else { desk_list_title }
                        if compact {
                          base.then(@ui.text_style(wrap=false, w=Cut))
                        } else {
                          base.then(in_lines)
                        }
                      })
                  }
                  // (as wide as its line leaves it narrow, pg_row_title's w=Full; wide as its words, desk_list_title's,
                  // giving way with what follows it on its line where the row has not the room for them, its words then
                  // on more lines, as an old view's words in a row do; `compact`: always cut on one line)
                  if narrow || compact {
                    w.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
                  } else {
                    w.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                  }
                  w
                  .ink(By(fn() {
                    if disabled() {
                      t().p.subtle
                    } else {
                      match ink {
                        Some(f) => f()
                        None => t().p.text
                      }
                    }
                  }))
                  |> ignore
                  match tag {
                    Some(f) if narrow => f(line)
                    // (giving way with its label, as wide as it is given: its words on more lines where that is less)
                    Some(f) =>
                      line.box(fn(g) {
                        g.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
                        f(g)
                      })
                      |> ignore
                    None => ()
                  }
                })
                |> ignore
                // (its end on its first line where a note is under it; a `compact` row's, its sides and its top
                // nearer, there by the row's top corner out of that corner's arc: as far in from the row's side as the
                // corner is round, a capsule in it not standing nearer its top than its side, unlike the row's corner)
                first.show(fn() { under() && ended() }, at_once=true, fn(e) {
                  e.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
                  if compact {
                    e.margin(Is((0.0, 0.0, dmax(0.0, corner - side), 0.0))) |> ignore
                  }
                  // (as tall as that line, what is taller in it (a button) standing over and under it alike: the line
                  // no taller for it, its label and its lead across the same middle)
                  e.height(By(fn() { Some(first_line(e)) })) |> ignore
                  end(e)
                })
              })
              |> ignore
              words.show(fn() { note() != "" }, at_once=true, fn(n) {
                let nw = match note_made {
                  Some(f) => f(n)
                  None =>
                    words_node(n, note, fn() {
                      let base = if narrow { pg_link_note } else { wide_list_note }
                      if compact {
                        base.then(@ui.text_style(wrap=false, w=Cut))
                      } else {
                        base
                      }
                    })
                }
                match note_ink {
                  Some(f) => nw.ink(By(f)) |> ignore
                  None => ()
                }
              })
            })
            |> ignore
          }
        }
        // (its end at the row's where no note is under its words)
        r.show(fn() { !under() && ended() }, at_once=true, fn(e) {
          e.row(Is(true)).gap(Is(12.0)).lines_up(Is(Some(Middle))) |> ignore
          end(e)
        })
      },
    )
    |> ignore
  })
  |> ignore
}
