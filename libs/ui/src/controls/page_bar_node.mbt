// A page's bar (page_bar.mbt's: a web service's, PreviewBar) as nodes of the window's tree, made once: its row of keys
// a press's room apart, a key of it, and the capsule of where the page is (its place in the bar), each bound to what it
// is worked out of and doing what it does in a handler at its press.

///|
/// The bar in `parent` (page_bar's): a row, 8 in and 6 over and under, its keys as far apart as makes each a press's
/// room across, a press's room high at least; in a panel of its own (`corners`: its top's left and right corners), as
/// high as its room over and under its keys makes it, its first and last keys concentric with those corners. `body`
/// makes what is in it. The row.
#callsite(autofill(loc))
pub fn page_bar_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  corners? : (Double, Double)? = None,
  end_pad? : () -> Double,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(row) {
    style_node(row, fn() {
      let key = theme().bars.key
      let look = page_bar_box.then(@ui.style(gap=keys_gap(size=key)))
      match corners {
        Some((left, right)) => {
          let base_pr = @ui.capsule_in(dmax(right, tape_corner), key)
          let pr = match end_pad {
            Some(f) => dmax(base_pr, f())
            None => base_pr
          }
          look.then(
            @ui.style(
              pt=room_of(@ui.capsule_in(tape_corner, key) - pane_edge),
              pl=room_of(@ui.capsule_in(dmax(left, tape_corner), key)),
              pr=room_of(pr),
            ),
          )
        }
        None => look.then(@ui.style(min_h=Fixed(@ui.room_least())))
      }
    })
    body(row)
  })
}

///|
/// A key of a bar in `parent` (bar_key's, PreviewBar's iconBtn): round, as big as the theme's bar keys, its icon
/// (`icon()`, as it changes) in the ink, faint and taking no press while `enabled()` holds not, the hover grey under
/// the hand; `lit()`: what it turns on is on, the accent's 14% under it and its icon in the accent's ink (marking's
/// key). Named `label()` (its tip in `tips`, where there are tips); `press` as it is pressed. `ripples`: a finger's
/// press ripples over it. The node.
#callsite(autofill(loc))
pub fn bar_key_node(
  parent : @view.View,
  icon : () -> String,
  label : () -> String,
  press : () -> Unit,
  enabled? : () -> Bool = fn() { true },
  lit? : () -> Bool = fn() { false },
  ripples? : Bool = false,
  tips? : TipLayer,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.toggle(
    made_for=loc,
    parent,
    Button,
    label,
    lit,
    fn(_) { press() },
    disabled=fn() { !enabled() },
    fn(v, b) {
      let side = fn() { theme().bars.key }
      v
      .width(By(fn() { Some(side()) }))
      .height(By(fn() { Some(side()) }))
      .radius(By(fn() { side() / 2.0 }))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .alpha(By(fn() { if enabled() { 1.0 } else { bar_key_faint } }))
      .ground(By(fn() { if lit() { @ui.tree_theme().color(mark_key_on) } else { no_ground } }))
      |> ignore
      hover_ground_node(v, on=fn() { enabled() && !lit() && !ripples }, lit=Some(fn() {
        b.hovered() || b.pressed() || b.focus_shown()
      }))
      v.box(fn(i) {
        i
        .width(By(fn() { Some(theme().bars.icon) }))
        .height(By(fn() { Some(theme().bars.icon) }))
        .shapes(By(fn() {
          match icon_numbers(icon()) {
            Some(d) => icon_shapes(d, theme().bars.icon / 24.0, 0x000000FFL)
            None => []
          }
        }))
        .drawn_as(By(fn() { "/icon/" + icon() + "/" }))
        .tint(By(fn() { if lit() { theme().p.accent_text } else { theme().p.text } }))
        |> ignore
      })
      |> ignore
      if ripples {
        press_look(v, By(fn() { side() / 2.0 }), fn() { false }) |> ignore
      }
      match tips {
        Some(tl) => tip_node(tl, v, label) |> ignore
        None => ()
      }
    },
  )
}

///|
/// How faint a bar's key that cannot be pressed is (bar_key_off's O35).
let bar_key_faint : Double = 0.35

///|
/// The place's capsule in `parent` (bar_field's): taking what the bar leaves, 160 at least, as high as the theme's bar
/// field, round, on the faint ground (typed in: the card's, the accent's half round it); what `body` makes in it, at its
/// end what `end` makes in a press's room (reload), how far the page came along its foot (`part`: its share and colour,
/// none: nothing). The capsule. `least`: how narrow its room comes to where nothing beside it leaves the bar (its
/// words cut short then), the place's 168 elsewhere. `framed`: on a bar of the canvas's own ground, where the faint
/// ground would not stand out, on the card's with its line round it.
#callsite(autofill(loc))
pub fn bar_field_node(
  parent : @view.View,
  editing : () -> Bool,
  body : (@view.View) -> Unit,
  end? : ((@view.View) -> Unit)? = None,
  part? : () -> (Double, @ui.Color)? = fn() { None },
  least? : Double = bar_field_least,
  framed? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(room) {
    style_node(room, fn() { if least == bar_field_least { bar_field_room } else { bar_field_room.then(@ui.style(min_w=Fixed(least))) } }, in_row=true)
    room.box(fn(cap) {
      style_node(cap, fn() {
        let look = (
          if editing() {
            bar_field_editing
          } else if framed {
            bar_field_framed
          } else {
            bar_field_box
          }
        ).then(@ui.style(h=Fixed(theme().bars.field)))
        if end is Some(_) {
          look.then(bar_field_ended)
        } else {
          look
        }
      })
      match end {
        None => body(cap)
        Some(e) => {
          cap.box(fn(w) {
            style_node(w, fn() { bar_field_words }, in_row=true)
            body(w)
          })
          |> ignore
          cap.box(fn(k) {
            style_node(k, fn() { bar_field_end.then(@ui.style(w=Fixed(@ui.room_least()))) }, in_row=true)
            e(k)
          })
          |> ignore
        }
      }
      // how far it came, along its foot, cut to its round
      cap.show(at_once=true, fn() { part() is Some(_) }, fn(line) {
        line
        .over(Is(true))
        .lines_up(Is(None))
        .presses(Is(false))
        |> ignore
        line.box(fn(g) { g.grow(Is(1.0)) |> ignore }) |> ignore
        line.box(fn(l) {
          l
          .height(Is(Some(@ui.Space::S0_5.px())))
          .width_share(By(fn() {
            match part() {
              Some((k, _)) => dmin(1.0, dmax(0.0, k))
              None => 0.0
            }
          }))
          .ground(By(fn() {
            match part() {
              Some((_, color)) => @ui.tree_theme().color(color)
              None => no_ground
            }
          }))
          |> ignore
        })
        |> ignore
      })
    })
    |> ignore
  })
}
