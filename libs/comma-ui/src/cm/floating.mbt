// Comma's floating parts as nodes of the window's tree, drawn in the layer (layer.mbt): Tooltip (tooltip/TooltipBubble),
// Menu (menu/styles.ts), Dropdown (dropdown/Dropdown, SelectItem), Popup (popup/Popup) and Dialog (dialog/styles.ts).
// Each comes as its cause says, faded and grown in from 0.97 over its own duration on surface-smooth-out, and goes the
// same way back; a menu, a dropdown's list and a popup go at a press outside them or Escape, a dialog at a press on its
// scrim or Escape. A menu and a dropdown's list are mbui's headless menu (@headless.menu), the dropdown's trigger its
// disclosure, placed beside what opened them by the tree (View::beside).

///|
/// A shadow of Comma's, light and dark (tokens_made's `shadow_*` and `shadow_dark_*`), as the appearance is now.
fn cast(light : (Double, Double, Int64), dark : (Double, Double, Int64)) -> (Double, Double, Int64) {
  if is_dark() {
    dark
  } else {
    light
  }
}

///|
/// What a floating panel looks like (menu's surface, popup's, dialog's): its corner, its ground and its shadow, the
/// primary border half a point wide; how far in it is from `e`, faded and grown in from 0.97.
fn panel_look(
  p : @view.View,
  e : Eased,
  corner : Double,
  ground : () -> Int64,
  shadow : () -> (Double, Double, Int64),
) -> Unit {
  p
  .radius(Is(corner))
  .ground(By(ground))
  .edge(By(fn() { (0.5, colors().border_primary) }))
  .shadow(By(shadow))
  .scale(By(fn() { 0.97 + 0.03 * e.shown(p) }))
  .alpha(By(fn() { seen_at(0.97 + 0.03 * e.shown(p)) * e.shown(p) }))
  |> ignore
}

///|
/// Comma's tooltip of `anchor` saying `label`, on its `side`, in `layer`: shown as the pointer rests on it `delay` ms
/// (300, Comma's) or at once as the keyboard's focus shows on it; gone as either leaves (`shown`: shown while it says so
/// too, a story's). Its bubble: the tooltip's ground in its edge half a point wide, rounded md, its words xs medium.
pub fn tooltip_node(
  layer : Layer,
  anchor : @view.View,
  label : () -> String,
  side? : @view.Side = Top,
  delay? : Double = 300.0,
  shown? : () -> Bool = fn() { false },
) -> Unit {
  let group = if (delay - 300.0).abs() < 0.001 {
    layer.tips
  } else {
    let s : @signals.Signal[@view.NodeId?] = @signals.signal(None)
    @headless.TooltipGroup::new(
      fn() { s.get() },
      fn(k) { s.set(k) },
      open_delay_ms=delay,
      warmup_ms=300.0,
    )
  }
  let key = anchor.id()
  group.trigger(anchor, key)
  let is_open = fn() { group.is_open(key) || shown() }
  let h = layer.holder(anchor)
  h.show(is_open, leave=ms_tooltip_exit, fn(slot) {
    slot.over(Is(true)).presses(Is(false)) |> ignore
    @headless.tooltip_bubble(slot, label, fn(t) {
      let e = opening(t, is_open, ms_tooltip_enter, ms_tooltip_exit)
      t.beside(anchor.id(), side~, along=Middle, offset=space_sm) |> ignore
      t
      .padding(Is((space_md, space_xs, space_md, space_xs)))
      .radius(Is(radius_md))
      .ground(By(fn() { colors().tooltip_bg }))
      .edge(By(fn() { (0.5, colors().tooltip_border) }))
      .shadow(By(fn() { cast(shadow_xs, shadow_dark_xs) }))
      .scale(By(fn() { 0.97 + 0.03 * e.shown(t) }))
      .alpha(By(fn() { e.shown(t) }))
      |> ignore
      t.box(fn(w) {
        w.words(By(label), look=words_in(type_mini, weight=weight_medium)).ink(By(fn() { colors().tooltip_text })) |> ignore
      })
      |> ignore
    })
    |> ignore
  })
}

///|
/// A row of a menu: its words, what it does, whether it destroys (in the error's words), whether it is the chosen one
/// (a tick at its end), a line over it (a new group).
pub(all) struct MenuRow {
  label : String
  press : () -> Unit
  danger : Bool
  checked : Bool
  divided : Bool
}

///|
/// A row of a menu (MenuRow).
pub fn menu_item(
  label : String,
  press : () -> Unit,
  danger? : Bool = false,
  checked? : Bool = false,
  divided? : Bool = false,
) -> MenuRow {
  { label, press, danger, checked, divided }
}

///|
/// The rows of a menu, its items of mbui's headless menu (@headless.menu: what it is to the keys and a screen reader,
/// ↓ ↑ Home End among its items, around its ends, Enter, Space or a press doing one, Escape closing it), in `m`, its
/// node: each 6 in from the menu's sides, rounded sm, 8 in and 6 over and under its words (small, medium, the
/// secondary's), lit in quaternary where the keys are on it (the pointer moving onto it brings them there); done, it
/// closes the menu. One chosen says so (a tick at its end, read out checked: a radio of the menu's where `radios`, else a
/// check), one that destroys in the error's words. The focus its ground's as it opens, the keys going from there to the
/// first (`first`: to the first item that says it is checked, where one does), given back as it goes. Read out a menu
/// named `label`.
#callsite(autofill(loc))
fn menu_rows(
  m : @view.View,
  items : () -> Array[MenuRow],
  label : String,
  close : () -> Unit,
  on_escape : () -> Unit,
  radios? : Bool = false,
  first? : Bool = false,
  loc~ : SourceLoc,
) -> Unit {
  let mn = @headless.menu(m, made_for=loc, label=fn() { label }, on_close=on_escape, fn(mn, menu) {
    let all = @signals.untracked(items)
    for item in all {
      if item.divided {
        mn.box(fn(d) {
          d.height(Is(Some(0.5))).margin(Is((0.0, space_xs, 0.0, space_xs))).ground(By(fn() { colors().border_primary }))
          |> ignore
        })
        |> ignore
      }
      mn.box(fn(g) {
        g.padding(Is((space_sm, 0.0, space_sm, 0.0))) |> ignore
        let act = fn(_ : @view.View) {
          (item.press)()
          close()
        }
        let look = fn(r : @view.View, it : @headless.MenuItem) {
          let on = fn() { it.focused() || lit(r, fn() { !it.disabled() }) }
          let hand = eased_by(r, on, ms_feedback_out, ease_smooth_out)
          r
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(Is(space_lg))
          .padding(Is((space_md, space_sm, space_md, space_sm)))
          .radius(Is(radius_sm))
          .ground(By(fn() { alpha(colors().bg_quaternary, hand.shown(r)) }))
          // (the pointer moving onto it: the keys' too, one row lit)
          .on_pointer_moved(fn() { if !it.focused() { r.ask_focus() |> ignore } })
          |> ignore
          r.box(fn(w) {
            w
            .grow(Is(1.0))
            .words(Is(item.label), look=words_in(type_small, weight=weight_medium))
            .ink(By(fn() {
              let c = colors()
              if item.danger {
                c.text_error_primary
              } else if on() {
                c.sidebar_text_highlight
              } else {
                c.text_secondary
              }
            }))
            |> ignore
          })
          |> ignore
          if item.checked {
            icon_node(r, icon_check, 20.0, fn() { colors().fg_brand_primary }) |> ignore
          }
        }
        if radios {
          menu.radio_item(g, fn() { item.label }, fn() { item.checked }, act, look) |> ignore
        } else if item.checked {
          menu.check_item(g, fn() { item.label }, fn() { true }, act, look) |> ignore
        } else {
          menu.item(g, fn() { item.label }, act, look) |> ignore
        }
      })
      |> ignore
    }
  })
  // (the focus its ground's as it opens, or the one chosen's: the keys from there; given back as it goes)
  if first {
    mn.focus_opens_first(takes=fn(s) { s.check == Some(On) }) |> ignore
  } else {
    mn.focus_opens_first(takes=fn(_) { false }) |> ignore
  }
}

///|
/// Comma's menu of `anchor` in `layer`, open while `open` says: `items` (MenuRow), 240 wide (`width`), under `anchor`
/// at its start, 4 off. Its surface: popup-secondary, rounded xl, the primary border half a point, the lg shadow, 6
/// over and under its rows. Gone at a press outside it, Escape, or a row done (`open` set false). Read out a menu named
/// `label`.
pub fn menu_node(
  layer : Layer,
  anchor : @view.View,
  open : @signals.Signal[Bool],
  items : () -> Array[MenuRow],
  label? : String = "Menu",
  width? : Double = 240.0,
  side? : @view.Side = Bottom,
) -> Unit {
  let close = fn() { open.set(false) }
  let is_open = fn() { open.get() }
  let h = layer.holder(anchor)
  h.box(fn(room) {
    // (inset 8pt horizontally to match View::beside's default window padding so max_width(..., within=true) fits)
    room.over(Is(true)).margin(Is((space_md, 0.0, space_md, 0.0))) |> ignore
    room.show(is_open, leave=ms_menu_exit, fn(slot) {
      slot.over(Is(true)) |> ignore
      @headless.overlay(
        slot,
        fn(_) { close() },
        modal=false,
        dismiss_on_escape=true,
        dismiss_on_outside=true,
        inert=fn() { !is_open() },
        anchor~,
        auto_focus=false,
        return_focus=true,
        fn(m, ov) {
          let e = opening(m, is_open, ms_menu_enter, ms_menu_exit)
          m.beside(anchor.id(), side~, along=Start, offset=space_xs) |> ignore
          m
          .width(Is(Some(width)))
          .max_width(Is(Some(width)), within=true)
          .padding(Is((0.0, space_sm, 0.0, space_sm)))
          |> ignore
          panel_look(m, e, radius_xl, fn() { colors().bg_popup_secondary }, fn() { cast(shadow_lg, shadow_dark_lg) })
          menu_rows(m, items, label, close, fn() { ov.escape() |> ignore })
        },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// Comma's dropdown in `parent`: a trigger like an input (40 high, rounded md, the primary edge, the xs shadow, its
/// words small: the chosen option, else `placeholder` in the placeholder's colour, a chevron at its end), opening under
/// it as wide as it a menu of `options`, a radio each, a tick by the chosen one, the keys on it as it opens. Choosing
/// sets `chosen` (its index). The trigger mbui's headless disclosure (@headless.disclosure: what opens a menu), read out
/// by `label` and the option chosen. The trigger's node.
#callsite(autofill(loc))
pub fn dropdown_node(
  parent : @view.View,
  layer : Layer,
  options : Array[String],
  chosen : @signals.Signal[Int],
  label? : String = "",
  placeholder? : String = "Select",
  open? : @signals.Signal[Bool] = @signals.signal(false),
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let value = fn() {
    let i = chosen.get()
    if i >= 0 && i < options.length() {
      options[i]
    } else {
      ""
    }
  }
  let trigger = @headless.disclosure(
    parent,
    made_for=loc,
    fn() {
      let v = value()
      if v == "" {
        label
      } else if label == "" {
        v
      } else {
        label + ": " + v
      }
    },
    fn() { open.get() },
    fn(_) { open.set(!open.untracked()) },
    disabled~,
    fn(t, _) {
      t
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .gap(Is(space_md))
      .min_height(Is(Some(40.0)))
      .padding(Is((space_lg + space_xxs, space_md, space_lg, space_md)))
      .radius(Is(radius_md))
      .ground(By(fn() { if disabled() { colors().bg_disabled } else { colors().bg_primary } }))
      .edge(By(fn() {
        let c = colors()
        (1.0, if open.get() { c.border_brand } else { c.border_primary })
      }))
      .shadow(By(fn() { cast(shadow_xs, shadow_dark_xs) }))
      |> ignore
      t.box(fn(w) {
        w
        .grow(Is(1.0))
        .words(By(fn() { if value() == "" { placeholder } else { value() } }), look=words_in(type_small))
        .ink(By(fn() {
          let c = colors()
          if disabled() {
            c.text_disabled
          } else if chosen.get() >= 0 {
            c.text_primary
          } else {
            c.text_placeholder
          }
        }))
        |> ignore
      })
      |> ignore
      icon_node(t, icon_chevron_down_small, 20.0, fn() { colors().fg_quaternary }).turn(By(fn() {
        if open.get() {
          3.141592653589793
        } else {
          0.0
        }
      }))
      |> ignore
      ring_node(t, fn() { radius_md })
    },
  )
  let close = fn() { open.set(false) }
  let is_open = fn() { open.get() }
  let h = layer.holder(trigger)
  h.show(is_open, leave=ms_menu_exit, fn(slot) {
    slot.over(Is(true)) |> ignore
    @headless.overlay(
      slot,
      fn(_) { close() },
      modal=false,
      dismiss_on_escape=true,
      dismiss_on_outside=true,
      inert=fn() { !is_open() },
      anchor=trigger,
      auto_focus=false,
      return_focus=true,
      fn(m, ov) {
        let e = opening(m, is_open, ms_menu_enter, ms_menu_exit)
        m.beside(trigger.id(), side=Bottom, along=Start, offset=space_xs, width=Anchor) |> ignore
        m.padding(Is((0.0, space_sm, 0.0, space_sm))) |> ignore
        panel_look(m, e, radius_xl, fn() { colors().bg_popup_secondary }, fn() { cast(shadow_lg, shadow_dark_lg) })
        let items = fn() {
          let i = chosen.get()
          options.mapi(fn(j, o) { menu_item(o, fn() { chosen.set(j) }, checked=j == i) })
        }
        menu_rows(m, items, label, close, fn() { ov.escape() |> ignore }, radios=true, first=true)
      },
    )
    |> ignore
  })
  trigger
}

///|
/// Comma's popup of `anchor` in `layer`, open while `open` says: a card `width` wide (280, 360 or 480: Popup's sizes),
/// popup-primary, rounded 2xl, the primary border half a point, 16 in, the sm shadow, holding what `body` makes; under
/// `anchor` at its start, 8 off. Gone at a press outside it or Escape. Read out a dialog named `label`.
pub fn popup_node(
  layer : Layer,
  anchor : @view.View,
  open : @signals.Signal[Bool],
  body : (@view.View) -> Unit,
  label? : String = "Popup",
  width? : Double = 360.0,
) -> Unit {
  let close = fn() { open.set(false) }
  let is_open = fn() { open.get() }
  let h = layer.holder(anchor)
  h.box(fn(room) {
    // (inset 8pt horizontally to match View::beside's default window padding so max_width(..., within=true) fits)
    room.over(Is(true)).margin(Is((space_md, 0.0, space_md, 0.0))) |> ignore
    room.show(is_open, leave=ms_hover_card_exit, fn(slot) {
      slot.over(Is(true)) |> ignore
      @headless.overlay(
        slot,
        fn(_) { close() },
        modal=false,
        dismiss_on_escape=true,
        dismiss_on_outside=true,
        inert=fn() { !is_open() },
        anchor~,
        auto_focus=true,
        return_focus=true,
        label=fn() { label },
        fn(p, _) {
          let e = opening(p, is_open, ms_hover_card_enter, ms_hover_card_exit)
          p.beside(anchor.id(), side=Bottom, along=Start, offset=space_md) |> ignore
          p
          .width(Is(Some(width)))
          .max_width(Is(Some(width)), within=true)
          .padding(Is((space_xl, space_xl, space_xl, space_xl)))
          |> ignore
          panel_look(p, e, radius_2xl, fn() { colors().bg_popup_primary }, fn() { cast(shadow_sm, shadow_dark_sm) })
          body(p)
        },
      )
      |> ignore
    })
  })
  |> ignore
}

///|
/// Comma's dialog in `layer`, open while `open` says: over a scrim of the overlay's colour, in the window's middle, a
/// panel up to 400 wide (popup-primary, rounded xl, the primary border half a point, 16 in, the md shadow), 20 between
/// its parts: `title` (md, semibold, the primary's) with `description` under it (xs, the quaternary's), what `body`
/// makes, and its actions at its foot's end (`actions`: Comma's buttons). Taking all input while open (modal); gone at
/// a press on the scrim or Escape. Read out a dialog named `title`.
pub fn dialog_node(
  layer : Layer,
  open : @signals.Signal[Bool],
  title : () -> String,
  description? : () -> String = fn() { "" },
  body? : (@view.View) -> Unit = fn(_) {  },
  actions? : (@view.View) -> Unit = fn(_) {  },
  width? : Double = 400.0,
) -> Unit {
  let close = fn() { open.set(false) }
  let is_open = fn() { open.get() }
  match layer.at.val {
    None => @halt.saying("cm: a dialog made before its layer (layer_node)")
    Some(l) =>
      l.box(fn(h) {
        h.over(Is(true)) |> ignore
        h.show(is_open, leave=ms_dialog_exit, fn(s) {
          let e = opening(s, is_open, ms_dialog_enter, ms_dialog_exit)
          s
          .over(Is(true))
          .lines_up(Is(Some(Middle)))
          .lies_along(Is(Middle))
          .padding(Is((space_xl, space_xl, space_xl, space_xl)))
          |> ignore
          s.box(fn(c) {
            c
            .over(Is(true))
            // (Comma's bg-overlay-scrim: the overlay's colour at 60%, generate-css.ts)
            .ground(By(fn() { alpha(colors().bg_overlay, 0.6) }))
            .alpha(By(fn() { e.shown(c) }))
            .presses(Is(false))
            |> ignore
          })
          |> ignore
          @headless.overlay(
            s,
            fn(_) { close() },
            modal=true,
            dismiss_on_escape=true,
            dismiss_on_outside=true,
            inert=fn() { !is_open() },
            auto_focus=true,
            return_focus=true,
            label=title,
            fn(p, _) {
              p
              .width(Is(Some(width)))
              .max_width(Is(Some(width)), within=true)
              .gap(Is(space_2xl))
              .padding(Is((space_xl, space_xl, space_xl, space_xl)))
              .clips(Is(true))
              |> ignore
              panel_look(p, e, radius_xl, fn() { colors().bg_popup_primary }, fn() { cast(shadow_md, shadow_dark_md) })
              p.box(fn(head) {
                head.gap(Is(space_xxs)) |> ignore
                head.box(fn(w) {
                  w
                  .words(By(title), look=words_in(type_regular, weight=weight_semibold, wrap=true))
                  .ink(By(fn() { colors().text_primary }))
                  |> ignore
                })
                |> ignore
                head.show(fn() { description() != "" }, fn(d) {
                  d.words(By(description), look=words_in(type_mini, wrap=true)).ink(By(fn() { colors().text_quaternary }))
                  |> ignore
                })
              })
              |> ignore
              body(p)
              p.box(fn(f) {
                f.row(Is(true)).wraps(Is(Some(space_md)), reverse=true).lies_along(Is(End)).lines_up(Is(Some(Middle))).gap(Is(space_md))
                |> ignore
                actions(f)
              })
              |> ignore
            },
          )
          |> ignore
        })
      })
      |> ignore
  }
}
