// Liquid Glass Menu and Select components over `@headless.Popover` and `@headless.menu`.
// Concentric corner ladder: outer panel r=22pt, pad=6pt -> inner items r=16pt.
// Zero glass-on-glass: rows, highlights and separators use subtle translucent ink layers.

///|
/// One entry in a `liquid_menu_node`: an action item, a toggleable check item, or a separator.
pub(all) enum LiquidMenuEntry {
  Item(
    label~ : String,
    shortcut~ : String,
    icon~ : ((@view.View, () -> Int64) -> Unit)?,
    destructive~ : Bool,
    disabled~ : Bool,
    on_select~ : () -> Unit
  )
  Check(
    label~ : String,
    shortcut~ : String,
    checked~ : () -> Bool,
    disabled~ : Bool,
    on_toggle~ : () -> Unit
  )
  Separator
}

///|
/// Convenience constructor for a menu action item.
pub fn LiquidMenuEntry::item(
  label~ : String,
  on_select~ : () -> Unit,
  shortcut? : String = "",
  icon? : (@view.View, () -> Int64) -> Unit,
  destructive? : Bool = false,
  disabled? : Bool = false,
) -> LiquidMenuEntry {
  Item(label~, shortcut~, icon~, destructive~, disabled~, on_select~)
}

///|
/// Convenience constructor for a checkable menu item.
pub fn LiquidMenuEntry::check(
  label~ : String,
  checked~ : () -> Bool,
  on_toggle~ : () -> Unit,
  shortcut? : String = "",
  disabled? : Bool = false,
) -> LiquidMenuEntry {
  Check(label~, shortcut~, checked~, disabled~, on_toggle~)
}

///|
/// Convenience constructor for a menu separator.
pub fn LiquidMenuEntry::separator() -> LiquidMenuEntry {
  Separator
}

///|
/// Filter leading, trailing and consecutive duplicate separators so a menu never draws
/// dangling or double dividers.
fn ovl_clean_menu_entries(entries : Array[LiquidMenuEntry]) -> Array[LiquidMenuEntry] {
  let out : Array[LiquidMenuEntry] = []
  let mut last_sep = true
  for entry in entries {
    match entry {
      Separator =>
        if !last_sep {
          out.push(Separator)
          last_sep = true
        }
      _ => {
        out.push(entry)
        last_sep = false
      }
    }
  }
  while out.length() > 0 {
    match out[out.length() - 1] {
      Separator => out.pop() |> ignore
      _ => break
    }
  }
  out
}

///|
/// Entry kind tag for `View::each` keying: 0 separator, 1 item, 2 check.
fn ovl_menu_entry_kind(entry : LiquidMenuEntry) -> Int {
  match entry {
    Separator => 0
    Item(..) => 1
    Check(..) => 2
  }
}

///|
/// Whether any entry in the menu needs a leading check or icon column.
fn ovl_menu_has_lead(entries : Array[LiquidMenuEntry]) -> Bool {
  for e in entries {
    match e {
      Check(..) => return true
      Item(icon=Some(_), ..) => return true
      _ => ()
    }
  }
  false
}

///|
/// A Liquid Glass dropdown menu in `parent` (its trigger) with its floating glass panel mounted
/// in `host`, positioned relative to the trigger via `placement`.
#callsite(autofill(loc))
pub fn liquid_menu_node(
  parent : @view.View,
  host : @view.View,
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  trigger_label : () -> String,
  trigger_look : (@view.View, @headless.Disclosure) -> Unit,
  entries : () -> Array[LiquidMenuEntry],
  menu_label? : () -> String = fn() { "Menu" },
  placement? : @headless.Placement = BelowStart,
  min_width? : Double = 212.0,
  anchor_size? : (Double, Double) = (40.0, 40.0),
  trigger_face? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let shown_open = ovl_transitioned_bool(host, open)
  let set_open_tx = fn(v : Bool) { @view.transition(within=host, fn() { set_open(v) }) }
  let pop = @headless.Popover::new(shown_open, set_open_tx)
  let cleaned = fn() { ovl_clean_menu_entries(entries()) }
  let (side, along) = ovl_beside_of(placement)
  let trigger = pop.trigger(parent, trigger_label, trigger_look, made_for=loc)
  let handoff = ovl_setup_trigger_handoff(trigger, shown_open, side, anchor_size, trigger_face)
  pop.layer(
    host,
    menu_label,
    leave=ovl_morph_leave_ms,
    made_for=loc,
    fn(v, opener) {
      let live = fn() { !v.leaving() }
      match opener {
        Some(op) => v.beside(op.id(), side~, along~, offset=ovl_float_gap, padding=ovl_float_pad) |> ignore
        None => ()
      }
      @headless.menu(
        v,
        label=menu_label,
        on_close=fn() {
          if @signals.untracked(live) {
            set_open_tx(false)
          }
        },
        takes_focus=true,
        roving=true,
        made_for=loc,
        fn(panel, menu) {
          panel.min_width(Is(Some(min_width))) |> ignore
          ovl_attach_liquid_morph(v, panel, side, along, ovl_menu_radius, handoff, fn(content_box) {
            content_box
            .padding(Is((ovl_menu_pad, ovl_menu_pad, ovl_menu_pad, ovl_menu_pad)))
            .gap(Is(ovl_menu_item_gap_y))
            |> ignore
            let has_lead = fn() { ovl_menu_has_lead(cleaned()) }
            let list = cleaned()
            for idx, entry in list {
              let _ = ovl_menu_entry_kind(entry)
              let _ = idx
              match entry {
                Separator =>
                  content_box.box(fn(sep) {
                    sep.padding(Is((ovl_menu_sep_px, ovl_menu_sep_py, ovl_menu_sep_px, ovl_menu_sep_py))) |> ignore
                    sep.box(fn(line) {
                      line
                      .height(Is(Some(ovl_hairline_h)))
                      .ground(By(ovl_hairline))
                      .says(Is(Some(@view.said(Separator))))
                      |> ignore
                    })
                    |> ignore
                  })
                  |> ignore
                Item(label~, shortcut~, icon~, destructive~, disabled~, on_select~) =>
                  menu.item(
                    content_box,
                    fn() { label },
                    fn(_) {
                      if !disabled {
                        set_open_tx(false)
                        on_select()
                      }
                    },
                    disabled=fn() { disabled },
                    made_for=loc,
                    fn(r, item) {
                      let ink = fn() {
                        if destructive {
                          ovl_destructive()
                        } else {
                          colors().content
                        }
                      }
                      r
                      .row(Is(true))
                      .lines_up(Is(Some(Middle)))
                      .min_height(Is(Some(ovl_menu_item_h)))
                      .padding(Is((ovl_menu_item_px, ovl_menu_item_py, ovl_menu_item_px, ovl_menu_item_py)))
                      .gap(Is(ovl_menu_item_gap))
                      .radius(Is(ovl_menu_item_radius))
                      .alpha(By(fn() { if item.disabled() { ovl_disabled_alpha } else { 1.0 } }))
                      |> ignore
                      ovl_attach_row_ground(
                        r,
                        fn() { item.hovered() || (item.focused() && item.focus_shown()) },
                        fn() { item.pressed() },
                        disabled=fn() { item.disabled() },
                      )
                      ovl_focus_ring(r, fn() { item.focus_shown() }, ovl_menu_item_radius)
                      r.show(has_lead, fn(col) {
                        col
                        .width(Is(Some(ovl_menu_check_w)))
                        .height(Is(Some(ovl_menu_icon_size)))
                        .lines_up(Is(Some(Middle)))
                        .lies_along(Is(Middle))
                        |> ignore
                        match icon {
                          Some(draw_icon) => draw_icon(col, ink)
                          None => ()
                        }
                      })
                      r.box(fn(w) {
                        w.grow(Is(1.0)).words(Is(label), look=words_at(ovl_type_body)).ink(By(ink)) |> ignore
                      })
                      |> ignore
                      if shortcut != "" {
                        r.box(fn(sc) {
                          sc.words(Is(shortcut), look=words_at(ovl_type_meta)).ink(By(ovl_muted_ink)) |> ignore
                        })
                        |> ignore
                      }
                    },
                  )
                  |> ignore
                Check(label~, shortcut~, checked~, disabled~, on_toggle~) =>
                  menu.check_item(
                    content_box,
                    fn() { label },
                    checked,
                    fn(_) {
                      if !disabled {
                        on_toggle()
                      }
                    },
                    disabled=fn() { disabled },
                    made_for=loc,
                    fn(r, item) {
                      r
                      .row(Is(true))
                      .lines_up(Is(Some(Middle)))
                      .min_height(Is(Some(ovl_menu_item_h)))
                      .padding(Is((ovl_menu_item_px, ovl_menu_item_py, ovl_menu_item_px, ovl_menu_item_py)))
                      .gap(Is(ovl_menu_item_gap))
                      .radius(Is(ovl_menu_item_radius))
                      .alpha(By(fn() { if item.disabled() { ovl_disabled_alpha } else { 1.0 } }))
                      |> ignore
                      ovl_attach_row_ground(
                        r,
                        fn() { item.hovered() || (item.focused() && item.focus_shown()) },
                        fn() { item.pressed() },
                        disabled=fn() { item.disabled() },
                      )
                      ovl_focus_ring(r, fn() { item.focus_shown() }, ovl_menu_item_radius)
                      r.box(fn(col) {
                        col
                        .width(Is(Some(ovl_menu_check_w)))
                        .height(Is(Some(ovl_menu_icon_size)))
                        .lines_up(Is(Some(Middle)))
                        .lies_along(Is(Middle))
                        |> ignore
                        col.show(fn() { item.checked() }, fn(chk) {
                          chk
                          .width(Is(Some(ovl_menu_icon_size)))
                          .height(Is(Some(ovl_menu_icon_size)))
                          .shapes(By(fn() { ovl_check_shapes(ovl_menu_icon_size, colors().content) }))
                          |> ignore
                        })
                      })
                      |> ignore
                      r.box(fn(w) {
                        w.grow(Is(1.0)).words(Is(label), look=words_at(ovl_type_body)).ink(By(fn() { colors().content }))
                        |> ignore
                      })
                      |> ignore
                      if shortcut != "" {
                        r.box(fn(sc) {
                          sc.words(Is(shortcut), look=words_at(ovl_type_meta)).ink(By(ovl_muted_ink)) |> ignore
                        })
                        |> ignore
                      }
                    },
                  )
                  |> ignore
              }
            }
          })
          |> ignore
        },
      )
      |> ignore
    },
  )
  trigger
}

///|
/// One option in a `liquid_select_node`.
pub(all) struct LiquidSelectOption {
  label : String
  detail : String
  disabled : Bool
}

///|
/// Convenience constructor for `LiquidSelectOption`.
pub fn LiquidSelectOption::new(
  label~ : String,
  detail? : String = "",
  disabled? : Bool = false,
) -> LiquidSelectOption {
  { label, detail, disabled }
}

///|
/// A Liquid Glass select control: capsule glass trigger with vector downward chevron and a
/// floating refractive option menu with checkmarks for the selected option.
#callsite(autofill(loc))
pub fn liquid_select_node(
  parent : @view.View,
  host : @view.View,
  options : () -> Array[LiquidSelectOption],
  selected : () -> Int,
  on_select : (Int) -> Unit,
  placeholder? : String = "Select...",
  label? : () -> String = fn() { "Select" },
  width? : Double = 220.0,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let open = @signals.signal(false)
  let open_fn = ovl_transitioned_bool(host, fn() { open.get() })
  let set_open_tx = fn(v : Bool) { @view.transition(within=host, fn() { open.set(v) }) }
  let pop = @headless.Popover::new(open_fn, set_open_tx)
  let current_text = fn() {
    let opts = options()
    let i = selected()
    if i >= 0 && i < opts.length() {
      opts[i].label
    } else {
      placeholder
    }
  }
  let chev_way = @motion.NodeWay::new(if @signals.untracked(open_fn) { ovl_turn_half } else { 0.0 })
  let draw_select_face = fn(box : @view.View) {
    box
    .lies_along(Is(Between))
    .padding(Is((ovl_select_px, 0.0, ovl_select_px, 0.0)))
    .gap(Is(ovl_select_gap))
    |> ignore
    box.box(fn(w) {
      w
      .grow(Is(1.0))
      .words(By(current_text), look=words_at(ovl_type_body))
      .ink(
        By(fn() {
          let opts = options()
          let i = selected()
          if i >= 0 && i < opts.length() {
            colors().content
          } else {
            ovl_muted_ink()
          }
        }),
      )
      |> ignore
    })
    |> ignore
    box.box(fn(chev) {
      chev
      .width(Is(Some(ovl_select_chevron)))
      .height(Is(Some(ovl_select_chevron)))
      .turn(By(fn() { chev_way.shown(chev) }))
      .shapes(By(fn() { ovl_chevron_down_shapes(ovl_select_chevron, ovl_muted_ink()) }))
      |> ignore
    })
    |> ignore
  }
  let trigger = pop.trigger(
    parent,
    fn() {
      let l = label()
      let cur = current_text()
      if l != "" && l != cur {
        "\{l}: \{cur}"
      } else {
        cur
      }
    },
    disabled~,
    made_for=loc,
    fn(t, disc) {
      let press_way = @motion.NodeWay::new(0.0)
      t.reacts(at_start=false, fn() { !disc.disabled() && disc.pressed() }, fn(on) {
        press_way.go(t, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
      })
      t.reacts(at_start=false, open_fn, fn(is_open) {
        chev_way.go(t, if is_open { ovl_turn_half } else { 0.0 }, @motion.snappy_damped)
      })
      t
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .width(Is(Some(width)))
      .height(Is(Some(ovl_select_h)))
      .radius(Is(ovl_select_radius))
      .shadow(Is(shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(ovl_morph_bridge_glass(merge=0.0)) }))
      .scale(By(fn() { 1.0 - 0.02 * clamp(press_way.shown(t), 0.0, 1.0) }))
      |> ignore
      ovl_focus_ring(t, fn() { disc.focus_shown() }, ovl_select_radius)
      draw_select_face(t)
    },
  )
  let handoff = ovl_setup_trigger_handoff(
    trigger,
    open_fn,
    Bottom,
    (width, ovl_select_h),
    Some(draw_select_face),
    attach_recoil=false,
  )
  trigger.alpha(
    By(fn() {
      if disabled() {
        ovl_disabled_alpha
      } else if handoff.is_bridging(trigger) {
        0.0
      } else {
        1.0
      }
    }),
  )
  |> ignore
  pop.layer(
    host,
    label,
    leave=ovl_morph_leave_ms,
    made_for=loc,
    fn(v, opener) {
      let live = fn() { !v.leaving() }
      match opener {
        Some(op) => v.beside(op.id(), side=Bottom, along=Start, offset=ovl_float_gap, padding=ovl_float_pad) |> ignore
        None => ()
      }
      @headless.menu(
        v,
        label~,
        on_close=fn() {
          if @signals.untracked(live) {
            set_open_tx(false)
          }
        },
        takes_focus=true,
        roving=true,
        made_for=loc,
        fn(panel, menu) {
          panel.min_width(Is(Some(width))) |> ignore
          ovl_attach_liquid_morph(v, panel, Bottom, Start, ovl_menu_radius, handoff, fn(content_box) {
            content_box
            .padding(Is((ovl_menu_pad, ovl_menu_pad, ovl_menu_pad, ovl_menu_pad)))
            .gap(Is(ovl_menu_item_gap_y))
            |> ignore
            let opts = options()
            for idx, opt in opts {
              let opt_idx = idx
              let opt_val = opt
              menu.radio_item(
                content_box,
                fn() { opt_val.label },
                fn() { selected() == opt_idx },
                fn(_) {
                  if !opt_val.disabled {
                    on_select(opt_idx)
                    set_open_tx(false)
                  }
                },
                disabled=fn() { opt_val.disabled },
                made_for=loc,
                fn(r, item) {
                  r
                  .row(Is(true))
                  .lines_up(Is(Some(Middle)))
                  .min_height(Is(Some(ovl_menu_item_h)))
                  .padding(Is((ovl_menu_item_px, ovl_menu_item_py, ovl_menu_item_px, ovl_menu_item_py)))
                  .gap(Is(ovl_menu_item_gap))
                  .radius(Is(ovl_menu_item_radius))
                  .alpha(By(fn() { if item.disabled() { ovl_disabled_alpha } else { 1.0 } }))
                  |> ignore
                  ovl_attach_row_ground(
                    r,
                    fn() { item.hovered() || (item.focused() && item.focus_shown()) },
                    fn() { item.pressed() },
                    selected=fn() { item.checked() },
                    disabled=fn() { item.disabled() },
                  )
                  ovl_focus_ring(r, fn() { item.focus_shown() }, ovl_menu_item_radius)
                  r.box(fn(col) {
                    col
                    .width(Is(Some(ovl_menu_check_w)))
                    .height(Is(Some(ovl_menu_icon_size)))
                    .lines_up(Is(Some(Middle)))
                    .lies_along(Is(Middle))
                    |> ignore
                    col.show(fn() { item.checked() }, fn(chk) {
                      chk
                      .width(Is(Some(ovl_menu_icon_size)))
                      .height(Is(Some(ovl_menu_icon_size)))
                      .shapes(By(fn() { ovl_check_shapes(ovl_menu_icon_size, ovl_accent_ink()) }))
                      |> ignore
                    })
                  })
                  |> ignore
                  r.box(fn(col) {
                    col.grow(Is(1.0)).gap(Is(ovl_text_gap)) |> ignore
                    col.box(fn(w) {
                      w.words(Is(opt_val.label), look=words_at(ovl_type_body)).ink(By(fn() { colors().content })) |> ignore
                    })
                    |> ignore
                    if opt_val.detail != "" {
                      col.box(fn(d) {
                        d.words(Is(opt_val.detail), look=words_at(ovl_type_meta)).ink(By(ovl_muted_ink)) |> ignore
                      })
                      |> ignore
                    }
                  })
                  |> ignore
                },
              )
              |> ignore
            }
          })
          |> ignore
        },
      )
      |> ignore
    },
  )
  trigger
}
