// Liquid Glass Detached Floating Sheet and ActionSheet components over `@headless.dialog`.
// Follows Apple iOS 26/27 detached floating sheet geometry (Sheet r=36pt, ActionSheet r=28pt)
// with zero glass-on-glass nesting and concentric close/action buttons.

///|
/// A Liquid Glass detached floating sheet in `parent`, open while `open()` holds.
/// Features a `36pt` concentric liquid glass card, top grabber pill, title/subtitle header with
/// vector `×` close button, body slot, optional footer slot, and `@headless.dialog` modal focus
/// trapping + Escape / scrim dismissal.
#callsite(autofill(loc))
pub fn liquid_sheet_node(
  parent : @view.View,
  open : () -> Bool,
  on_close : () -> Unit,
  title : () -> String,
  body : (@view.View) -> Unit,
  subtitle? : () -> String = fn() { "" },
  footer? : (@view.View) -> Unit,
  width? : Double = 520.0,
  max_height? : Double = 560.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    let shown_open = ovl_transitioned_bool(h, open)
    h.show(shown_open, leave=@motion.dialog_out_ms, fn(s) {
      let (look, _) = @motion.overlay_presence(s, enter=@motion.dialog_in, exit=@motion.dialog_out)
      s.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
      // Dimmed backdrop scrim; clicking outside the sheet card closes via @headless.dialog.
      s.box(fn(scrim) {
        scrim
        .over(Is(true))
        .ground(By(fn() { colors().scrim }))
        .alpha(By(fn() { look().alpha }))
        |> ignore
      })
      |> ignore
      s.box(fn(room) {
        room
        .width(Is(Some(width + 2.0 * ovl_sheet_inset)))
        .max_width(Is(Some(width + 2.0 * ovl_sheet_inset)), within=true)
        .padding(Is((ovl_sheet_inset, ovl_sheet_inset, ovl_sheet_inset, ovl_sheet_inset)))
        |> ignore
        @headless.dialog(
          room,
          title,
          open,
          on_close,
          description=subtitle,
          made_for=loc,
          fn(card, dlg) {
            card
            .max_height(Is(Some(max_height)))
            .radius(Is(ovl_sheet_radius))
            .shadow(Is(shadow_default))
            .shadow_outside(Is(true))
            .glass(By(fn() { Some(ovl_sheet_glass()) }))
            .alpha(By(fn() { look().alpha }))
            .offset(By(fn() { (0.0, look().dy) }))
            |> ignore
            // Top drag-indicator capsule
            card.box(fn(grab_wrap) {
              grab_wrap
              .padding(Is((0.0, ovl_sheet_grabber_pt, 0.0, 0.0)))
              .lines_up(Is(Some(Middle)))
              |> ignore
              grab_wrap.box(fn(grab) {
                grab
                .width(Is(Some(ovl_sheet_grabber_w)))
                .height(Is(Some(ovl_sheet_grabber_h)))
                .radius(Is(ovl_sheet_grabber_h / 2.0))
                .ground(By(ovl_grabber_color))
                |> ignore
              })
              |> ignore
            })
            |> ignore
            // Header row: title + optional subtitle + concentric circular close button (inset=20pt, r=16pt -> 36pt)
            card.box(fn(hdr) {
              hdr
              .row(Is(true))
              .lines_up(Is(Some(Start)))
              .lies_along(Is(Between))
              .gap(Is(ovl_sheet_gap))
              .padding(Is((ovl_sheet_pad, ovl_sheet_hdr_pt, ovl_sheet_hdr_pr, ovl_sheet_gap)))
              |> ignore
              hdr.box(fn(titles) {
                titles.grow(Is(1.0)).gap(Is(ovl_text_gap)) |> ignore
                titles.box(fn(w) {
                  w
                  .words(By(title), look=words_at(ovl_type_title, weight=ovl_weight_semibold, wrap=true))
                  .ink(By(fn() { colors().content }))
                  |> ignore
                })
                |> ignore
                titles.show(fn() { subtitle() != "" }, fn(sub) {
                  sub
                  .words(By(subtitle), look=words_at(ovl_type_sub, wrap=true))
                  .ink(By(ovl_muted_ink))
                  |> ignore
                })
              })
              |> ignore
              @headless.button(hdr, fn() { "Close" }, fn(_) { dlg.close() }, made_for=loc, fn(btn_v, btn) {
                btn_v
                .width(Is(Some(ovl_close_btn_size)))
                .height(Is(Some(ovl_close_btn_size)))
                .shrink(Is(0.0))
                .radius(Is(ovl_close_btn_size / 2.0))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                |> ignore
                let hover_t = @motion.hover_fade(btn_v, fn() { btn.hovered() })
                let press_t = @motion.hover_fade(btn_v, fn() { btn.pressed() }, duration_ms=@motion.pointer_tap_ms)
                btn_v
                .ground(
                  By(fn() {
                    let base = ovl_close_ground()
                    let h = hover_t()
                    let p = press_t()
                    let with_h = if h > 0.001 { over(base, alpha(ovl_row_hover(), h)) } else { base }
                    if p > 0.001 { over(with_h, alpha(ovl_row_press(), p)) } else { with_h }
                  }),
                )
                |> ignore
                ovl_focus_ring(btn_v, fn() { btn.focus_shown() }, ovl_close_btn_size / 2.0)
                btn_v.box(fn(ic) {
                  ic
                  .width(Is(Some(ovl_close_icon_size)))
                  .height(Is(Some(ovl_close_icon_size)))
                  .shapes(By(fn() { ovl_close_shapes(ovl_close_icon_size, colors().content) }))
                  |> ignore
                })
                |> ignore
              })
              |> ignore
            })
            |> ignore
            // Body slot
            card.box(fn(b) {
              b.padding(Is((ovl_sheet_pad, 0.0, ovl_sheet_pad, ovl_sheet_pad))) |> ignore
              body(b)
            })
            |> ignore
            // Optional footer slot
            match footer {
              Some(draw_footer) =>
                card.box(fn(f) {
                  f.box(fn(sep) {
                    sep.height(Is(Some(ovl_hairline_h))).ground(By(ovl_hairline)) |> ignore
                  })
                  |> ignore
                  f.box(fn(inner) {
                    inner.padding(Is((ovl_sheet_footer_pad, ovl_sheet_footer_pad, ovl_sheet_footer_pad, ovl_sheet_footer_pad)))
                    |> ignore
                    draw_footer(inner)
                  })
                  |> ignore
                })
                |> ignore
              None => ()
            }
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
}

///|
/// One action item in a `liquid_action_sheet_node`.
pub(all) struct LiquidActionSheetItem {
  label : String
  destructive : Bool
  disabled : Bool
  on_select : () -> Unit
}

///|
/// Convenience constructor for `LiquidActionSheetItem`.
pub fn LiquidActionSheetItem::new(
  label~ : String,
  on_select~ : () -> Unit,
  destructive? : Bool = false,
  disabled? : Bool = false,
) -> LiquidActionSheetItem {
  { label, destructive, disabled, on_select }
}

///|
/// A Liquid Glass ActionSheet in `parent`: upper floating glass group (`r=28pt`) for header +
/// actions with hairline dividers strictly between rows, plus a detached bottom Cancel glass
/// capsule (`r=28pt`), managed by `@headless.dialog`.
#callsite(autofill(loc))
pub fn liquid_action_sheet_node(
  parent : @view.View,
  open : () -> Bool,
  on_close : () -> Unit,
  items : () -> Array[LiquidActionSheetItem],
  title? : () -> String = fn() { "" },
  message? : () -> String = fn() { "" },
  cancel_label? : () -> String = fn() { "Cancel" },
  width? : Double = 380.0,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    let shown_open = ovl_transitioned_bool(h, open)
    h.show(shown_open, leave=@motion.dialog_out_ms, fn(s) {
      let (look, _) = @motion.overlay_presence(s, enter=@motion.dialog_in, exit=@motion.dialog_out)
      s.over(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
      s.box(fn(scrim) {
        scrim
        .over(Is(true))
        .ground(By(fn() { colors().scrim }))
        .alpha(By(fn() { look().alpha }))
        |> ignore
      })
      |> ignore
      s.box(fn(room) {
        room
        .width(Is(Some(width + 2.0 * ovl_sheet_inset)))
        .max_width(Is(Some(width + 2.0 * ovl_sheet_inset)), within=true)
        .padding(Is((ovl_sheet_inset, ovl_sheet_inset, ovl_sheet_inset, ovl_sheet_inset)))
        |> ignore
        @headless.dialog(
          room,
          fn() {
            let t = title()
            if t != "" { t } else { "Actions" }
          },
          open,
          on_close,
          description=message,
          made_for=loc,
          fn(stack, dlg) {
            stack
            .gap(Is(ovl_action_gap))
            .alpha(By(fn() { look().alpha }))
            .offset(By(fn() { (0.0, look().dy) }))
            |> ignore
            // Upper glass card: optional header + action rows
            stack.box(fn(card) {
              card
              .padding(Is((ovl_action_pad, ovl_action_pad, ovl_action_pad, ovl_action_pad)))
              .radius(Is(ovl_action_radius))
              .shadow(Is(shadow_default))
              .shadow_outside(Is(true))
              .glass(By(fn() { Some(ovl_sheet_glass()) }))
              |> ignore
              let has_header = title() != "" || message() != ""
              if has_header {
                card.box(fn(hdr) {
                  hdr
                  .padding(Is((ovl_action_hdr_px, ovl_action_hdr_py, ovl_action_hdr_px, ovl_action_hdr_py)))
                  .gap(Is(ovl_text_gap))
                  .lines_up(Is(Some(Middle)))
                  |> ignore
                  if title() != "" {
                    hdr.box(fn(w) {
                      w
                      .words(By(title), look=words_at(ovl_type_sub, weight=ovl_weight_semibold, wrap=true))
                      .words_centered(Is(true))
                      .ink(By(ovl_muted_ink))
                      |> ignore
                    })
                    |> ignore
                  }
                  if message() != "" {
                    hdr.box(fn(w) {
                      w
                      .words(By(message), look=words_at(ovl_type_meta, wrap=true))
                      .words_centered(Is(true))
                      .ink(By(ovl_muted_ink))
                      |> ignore
                    })
                    |> ignore
                  }
                })
                |> ignore
              }
              card.each(
                fn() { items().mapi(fn(i, it) { (i, it.label, it.destructive, it.disabled) }) },
                fn(k) { k },
                fn(slot, k) {
                  let (idx, lbl, destructive, disabled) = k.untracked()
                  if idx > 0 || has_header {
                    slot.box(fn(sep) {
                      sep.padding(Is((ovl_list_sep_inset, 0.0, ovl_list_sep_inset, 0.0))) |> ignore
                      sep.box(fn(line) {
                        line.height(Is(Some(ovl_hairline_h))).ground(By(ovl_hairline)) |> ignore
                      })
                      |> ignore
                    })
                    |> ignore
                  }
                  @headless.button(
                    slot,
                    fn() { lbl },
                    fn(_) {
                      if !disabled {
                        match @signals.untracked(items).get(idx) {
                          Some(it) if !it.disabled => {
                            (it.on_select)()
                            dlg.close()
                          }
                          _ => ()
                        }
                      }
                    },
                    disabled=fn() { disabled },
                    made_for=loc,
                    fn(b, btn) {
                      b
                      .row(Is(true))
                      .lines_up(Is(Some(Middle)))
                      .lies_along(Is(Middle))
                      .min_height(Is(Some(ovl_action_item_h)))
                      .padding(Is((ovl_action_hdr_px, 0.0, ovl_action_hdr_px, 0.0)))
                      .radius(Is(ovl_action_item_radius))
                      .alpha(By(fn() { if btn.disabled() { ovl_disabled_alpha } else { 1.0 } }))
                      |> ignore
                      ovl_attach_row_ground(
                        b,
                        fn() { btn.hovered() },
                        fn() { btn.pressed() },
                        disabled=fn() { btn.disabled() },
                      )
                      ovl_focus_ring(b, fn() { btn.focus_shown() }, ovl_action_item_radius)
                      b.box(fn(w) {
                        w
                        .words(Is(lbl), look=words_at(ovl_type_heading, weight=weight_medium))
                        .ink(By(fn() { if destructive { ovl_destructive() } else { colors().content } }))
                        |> ignore
                      })
                      |> ignore
                    },
                  )
                  |> ignore
                },
              )
            })
            |> ignore
            // Detached bottom Cancel glass capsule
            @headless.button(
              stack,
              cancel_label,
              fn(_) { dlg.close() },
              made_for=loc,
              fn(cancel_v, btn) {
                cancel_v
                .row(Is(true))
                .lines_up(Is(Some(Middle)))
                .lies_along(Is(Middle))
                .height(Is(Some(ovl_action_item_h)))
                .padding(Is((ovl_action_hdr_px, 0.0, ovl_action_hdr_px, 0.0)))
                .radius(Is(ovl_action_radius))
                .shadow(Is(shadow_default))
                .shadow_outside(Is(true))
                .glass(By(fn() { Some(ovl_sheet_glass()) }))
                |> ignore
                ovl_focus_ring(cancel_v, fn() { btn.focus_shown() }, ovl_action_radius)
                cancel_v.box(fn(w) {
                  w
                  .words(By(cancel_label), look=words_at(ovl_type_heading, weight=ovl_weight_semibold))
                  .ink(By(fn() { colors().content }))
                  |> ignore
                })
                |> ignore
              },
            )
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
}
