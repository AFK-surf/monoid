// One of a few (parts.mbt one_of's) as a node of the window's tree, made once: a few listed where it is, a row each, a
// radio group's (@kit.radio_group's roving keys); more, a select (select_node).

///|
/// One of a few in `parent` (one_of's, as a node), `value` among `options` (each value and its words) as each is now:
/// up to `one_of_listed_most` listed where it is, a row each (the theme's rows' least height and title, a row's corner,
/// the hover's ground under a mouse or a press), the chosen checked at its end (16, the accent); more, a select
/// (select_node). Listed: a radio group named `label` (each row a radio, on or off), one stop of Tab's (the chosen
/// one, else the first), ↑ ↓ moving along it round from its ends and Home, End to the first and the last, each choosing
/// what it comes to; a press or Space choosing the one pressed (`choose` given it; nothing for the one chosen already).
/// While `disabled()`, at 55% and taking no press.
#callsite(autofill(loc))
pub fn one_of_node(
  parent : @view.View,
  value : () -> String,
  options : () -> Array[(String, String)],
  choose : (String) -> Unit,
  label? : () -> String = fn() { "" },
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> Unit {
  let listed = fn() { options().length() <= one_of_listed_most }
  parent.box(made_for=loc, fn(b) {
    b.pick(fn() { listed() }, fn(p, as_list) {
      if !as_list {
        select_node(p, value, options, choose, label~, disabled~)
        return
      }
      @headless.radio_group(
        p,
        label,
        value,
        choose,
        axis=Vertical,
        disabled~,
        fn(g, rg) {
          style_node(g, fn() { one_of_list })
          // (by value once: each row reads its own option's words, told only as that one changes)
          let by_value = g.keyed_by(options, fn(o) { o.0 })
          g.each(fn() { by_value.keys() }, fn(v) { v }, fn(slot, v) {
            let v = v.untracked()
            let words = fn() { by_value.get(v).map(fn(o) { o.1 }).unwrap_or("") }
            rg.item(slot, fn() { v }, words, space_only=true, fn(r, item) {
              let on = fn() { item.chosen() }
              style_node(r, fn() { one_of_row.then(@ui.style(min_h=Fixed(theme().items.least))) })
              // (one_of_row_hot's hover ground: a mouse over any of it, or it pressed, or keyboard focus)
              r.focus_ring_theme().alpha(By(fn() { if item.disabled() { one_of_disabled_alpha } else { 1.0 } })) |> ignore
              hover_ground_node(
                r,
                on=fn() { !item.disabled() },
                lit=Some(fn() { hovered_in_node(r) || item.pressed() || r.focus_shown() }),
              )
              words_node(r, words, fn() { theme().rows.title }) |> ignore
              // (its words and its check apart: one_of_row's JBetween, what is left of the row between them)
              r.box(fn(gap) { gap.grow(Is(1.0)) |> ignore }) |> ignore
              r.show(on, at_once=true, fn(k) {
                icon_node(k, "check", one_of_check, By(fn() { theme().p.accent })) |> ignore
              })
            })
            |> ignore
          })
        },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// one_of's list: its rows one under the other, none apart (radio_group's `gap=0.0`).
// kept across runs: a value (no field of it changes)
let one_of_list : @ui.Style = @ui.css("w=Full")

///|
/// How far a disabled one_of's row is seen (one_of_row's `disabled{opacity=O55}`).
let one_of_disabled_alpha : Double = 0.55
