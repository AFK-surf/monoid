// Floating liquid glass text field and search bar built over @headless.TextField + @ui.field.
// Clear buttons use View::show (never alpha=0) with pure @paint.shape_of vector icons.

///|
/// Internal circular clear `×` button shown only when the field has text.
#callsite(autofill(loc))
fn ctrl_clear_button(
  parent : @view.View,
  field : @ui.Field,
  on_clear : (() -> Unit)?,
  loc~ : SourceLoc,
) -> Unit {
  @headless.button(
    made_for=loc,
    parent,
    fn() { "Clear" },
    fn(_) {
      field.set("")
      match on_clear {
        Some(f) => f()
        None => ()
      }
      field.focus()
    },
    fn(b, btn) {
      let hover_way = @motion.NodeWay::new(0.0)
      b.reacts(at_start=false, fn() { btn.hovered() || btn.pressed() }, fn(on) {
        hover_way.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
      })
      b
      .width(Is(Some(ctrl_clear_size)))
      .height(Is(Some(ctrl_clear_size)))
      .shrink(Is(0.0))
      .radius(Is(ctrl_clear_size / 2.0))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(ctrl_clear_bg))
      |> ignore
      b.box(fn(hov) {
        hov
        .over(Is(true))
        .points(Is(false))
        .radius(Is(ctrl_clear_size / 2.0))
        .ground(By(ctrl_hover_ink))
        .alpha(By(fn() { clamp(hover_way.shown(hov), 0.0, 1.0) * ctrl_hover_alpha }))
        |> ignore
      })
      |> ignore
      b.box(fn(ic) {
        ic
        .width(Is(Some(ctrl_clear_icon_size)))
        .height(Is(Some(ctrl_clear_icon_size)))
        .shrink(Is(0.0))
        .shapes(By(fn() { ctrl_close_shapes(ctrl_clear_icon_size, ctrl_clear_ink()) }))
        |> ignore
      })
      |> ignore
      b.show(fn() { btn.focus_shown() }, fn(ring) {
        ring
        .over(Is(true))
        .points(Is(false))
        .radius(Is(ctrl_clear_size / 2.0))
        .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
        |> ignore
      })
    },
  )
  |> ignore
}

///|
/// A floating liquid glass text field capsule (44pt high, 22pt radius) built over
/// `@headless.TextField` + `@ui.field`. Supports top label, bottom description/error,
/// optical focus/invalid border, leading icon slot, and a `show`-gated clear button.
#callsite(autofill(loc))
pub fn liquid_text_field_node(
  parent : @view.View,
  field : @ui.Field,
  placeholder? : String = "",
  label? : () -> String = fn() { "" },
  description? : () -> String = fn() { "" },
  error? : () -> String = fn() { "" },
  invalid? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  read_only? : () -> Bool = fn() { false },
  secret? : Bool = false,
  lead? : (@view.View, () -> Int64) -> Unit,
  clearable? : Bool = false,
  on_clear? : () -> Unit,
  submitted? : (String) -> Unit,
  edited? : (String) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let tf = @headless.TextField::new(label, description~, error~, invalid~, disabled~, read_only~)
  let prev_text = Ref(@signals.untracked(fn() { field.text() }))
  parent.box(made_for=loc, fn(col) {
    col.gap(Is(ctrl_field_gap)) |> ignore
    col.reacts(at_start=false, fn() { field.text() }, fn(s) {
      if !@signals.untracked(read_only) {
        prev_text.val = s
      }
    })
    col.reacts(at_start=false, read_only, fn(is_ro) {
      if is_ro {
        prev_text.val = @signals.untracked(fn() { field.text() })
      }
    })
    col.show(
      fn() { tf.label_text() != "" },
      fn(lbl_slot) {
        tf.label(made_for=loc, lbl_slot, fn(l) {
          l
          .words(By(fn() { tf.label_text() }), look=words_at(ctrl_type_label, weight=weight_medium))
          .ink(By(fn() { colors().content }))
          |> ignore
        })
        |> ignore
      },
      at_once=true,
    )
    col.box(fn(cap) {
      cap
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .height(Is(Some(ctrl_input_h)))
      .padding(Is((ctrl_input_px, 0.0, ctrl_input_px, 0.0)))
      .gap(Is(ctrl_input_gap))
      .radius(Is(ctrl_input_r))
      .shadow(Is(shadow_default))
      .glass(By(fn() { Some(ctrl_input_glass()) }))
      .edge(By(fn() {
        if tf.invalid() {
          (ctrl_input_focus_edge_w, ctrl_danger_ink())
        } else if tf.focused() {
          (ctrl_input_focus_edge_w, colors().accent)
        } else {
          (ctrl_hairline_w, ctrl_input_edge_ink())
        }
      }))
      .alpha(By(fn() { if tf.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
      |> ignore
      match lead {
        Some(draw_lead) =>
          cap.box(fn(l) {
            l.shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
            draw_lead(l, ctrl_muted_ink)
          })
          |> ignore
        None => ()
      }
      let on_edited = fn(s : String) {
        if @signals.untracked(read_only) {
          if s != prev_text.val {
            field.set(prev_text.val)
          }
          return
        }
        prev_text.val = s
        match edited {
          Some(f) => f(s)
          None => ()
        }
      }
      let typed = @ui.field(
        cap,
        field,
        placeholder~,
        font_size=ctrl_type_body,
        max_lines=1,
        enter_sends=true,
        secret~,
        label=@signals.untracked(label),
        submitted?,
        edited=on_edited,
        colors_by=fn() { (colors().content, ctrl_placeholder_ink(), colors().accent) },
      )
      typed
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .shrink(Is(1.0))
      .presses(By(fn() { !tf.disabled() }))
      .focusable(By(fn() { !tf.disabled() }), keys=0)
      |> ignore
      tf.control_node(typed)
      cap.show(
        fn() { clearable && !tf.disabled() && !tf.read_only() && field.text() != "" },
        fn(cl) { ctrl_clear_button(loc~, cl, field, on_clear) },
        at_once=true,
      )
    })
    |> ignore
    col.show(
      fn() { tf.error_text() != "" },
      fn(err_slot) {
        tf.error(made_for=loc, err_slot, fn(e) {
          e
          .words(By(fn() { tf.error_text() }), look=words_at(ctrl_type_caption, wrap=true))
          .ink(By(ctrl_danger_ink))
          |> ignore
        })
        |> ignore
      },
      at_once=true,
    )
    col.show(
      fn() { tf.error_text() == "" && tf.description_text() != "" },
      fn(desc_slot) {
        tf.description(made_for=loc, desc_slot, fn(d) {
          d
          .words(By(fn() { tf.description_text() }), look=words_at(ctrl_type_caption, wrap=true))
          .ink(By(ctrl_muted_ink))
          |> ignore
        })
        |> ignore
      },
      at_once=true,
    )
  })
}

///|
/// An iOS 26/27 floating liquid glass search bar capsule with built-in vector magnifying
/// glass icon, `@ui.field`, `show`-gated clear button, and optional trailing slot.
#callsite(autofill(loc))
pub fn liquid_search_bar_node(
  parent : @view.View,
  field : @ui.Field,
  placeholder? : String = "Search",
  label? : () -> String = fn() { "Search" },
  disabled? : () -> Bool = fn() { false },
  submitted? : (String) -> Unit,
  edited? : (String) -> Unit,
  on_clear? : () -> Unit,
  trailing? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let tf = @headless.TextField::new(label, disabled~)
  parent.box(made_for=loc, fn(row) {
    row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(ctrl_search_trailing_gap)) |> ignore
    row.box(fn(cap) {
      cap
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .height(Is(Some(ctrl_input_h)))
      .padding(Is((ctrl_input_px, 0.0, ctrl_input_px, 0.0)))
      .gap(Is(ctrl_input_gap))
      .radius(Is(ctrl_input_r))
      .shadow(Is(shadow_default))
      .glass(By(fn() { Some(ctrl_input_glass()) }))
      .edge(By(fn() {
        if tf.focused() {
          (ctrl_input_focus_edge_w, colors().accent)
        } else {
          (ctrl_hairline_w, ctrl_input_edge_ink())
        }
      }))
      .alpha(By(fn() { if tf.disabled() { ctrl_disabled_alpha } else { 1.0 } }))
      |> ignore
      cap.box(fn(ic) {
        ic
        .width(Is(Some(ctrl_search_icon_size)))
        .height(Is(Some(ctrl_search_icon_size)))
        .shrink(Is(0.0))
        .shapes(By(fn() { ctrl_search_shapes(ctrl_search_icon_size, ctrl_muted_ink()) }))
        |> ignore
      })
      |> ignore
      let typed = @ui.field(
        cap,
        field,
        placeholder~,
        font_size=ctrl_type_body,
        max_lines=1,
        enter_sends=true,
        label=@signals.untracked(label),
        submitted?,
        edited?,
        colors_by=fn() { (colors().content, ctrl_placeholder_ink(), colors().accent) },
      )
      typed
      .grow(Is(1.0))
      .basis(Is(Some(0.0)))
      .shrink(Is(1.0))
      .presses(By(fn() { !tf.disabled() }))
      .focusable(By(fn() { !tf.disabled() }), keys=0)
      |> ignore
      tf.control_node(typed)
      cap.show(
        fn() { !tf.disabled() && field.text() != "" },
        fn(cl) { ctrl_clear_button(loc~, cl, field, on_clear) },
        at_once=true,
      )
    })
    |> ignore
    match trailing {
      Some(draw_trail) =>
        row.box(fn(tr) {
          tr.shrink(Is(0.0)).lines_up(Is(Some(Middle))).lies_along(Is(Middle)) |> ignore
          draw_trail(tr)
        })
        |> ignore
      None => ()
    }
  })
}
