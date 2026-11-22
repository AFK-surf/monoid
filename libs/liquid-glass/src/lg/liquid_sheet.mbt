// Liquid Glass Detached Floating Sheet and ActionSheet components over `@headless.dialog`.
// Follows Apple iOS 26/27 detached floating sheet geometry (Sheet r=36pt, ActionSheet r=28pt)
// with zero glass-on-glass nesting and concentric close/action buttons.

///|
/// Decorates an existing bottom-sheet glass layer node `g` in place (zero wrapper nodes) with single-layer
/// `liquid_sheet_glass`, `active` gating (returns `None` glass, zero edge, and zero shadow when vanished/inactive),
/// dynamic `solid` fallback (e.g. scrim-composited solid under `MBUI_GLASS=solid`), `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` hairline fallback, and optional `radius`. Returns `g` for chaining.
pub fn liquid_sheet_surface_decorate(
  g : @view.View,
  radius? : Double,
  active? : () -> Bool = fn() { true },
  solid? : () -> Int64,
  shadow? : () -> (Double, Double, Int64) = fn() { shadow_default },
  solid_edge? : () -> (Double, Int64) = liquid_overlay_solid_edge,
) -> @view.View {
  match radius {
    Some(r) => g.radius(Is(r)) |> ignore
    None => ()
  }
  g
  .glass(
    By(fn() {
      if !active() {
        return None
      }
      let s = match solid {
        Some(f) => f()
        None => clear
      }
      Some(liquid_sheet_glass(solid=s))
    }),
  )
  .edge(
    By(fn() {
      if active() && g.glass_solid() {
        solid_edge()
      } else {
        (0.0, clear)
      }
    }),
  )
  .shadow(
    By(fn() {
      if active() {
        shadow()
      } else {
        shadow_none
      }
    }),
  )
  .shadow_outside(Is(true))
}

///|
/// A Liquid Glass detached floating sheet in `parent`, open while `open()` holds.
/// Features a `36pt` concentric liquid glass card, interactive vertical drag-to-dismiss with
/// upward rubber-band over-pull, optional two-detent (`detents=true`) morphing between floating
/// half-height glass (`12pt` inset, `r=36pt`) and docked full-height reading surface (`0pt` inset,
/// top `r=24pt`, bottom `r=0pt`), vector `×` close button, body/footer slots, and `@headless.dialog`
/// modal focus trapping + Escape / scrim dismissal.
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
  detents? : Bool = false,
  expanded? : () -> Bool = fn() { false },
  on_expanded? : (Bool) -> Unit = fn(_) {  },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    let shown_open = ovl_transitioned_bool(h, open)
    h.show(shown_open, leave=@motion.dialog_out_ms, fn(s) {
      let (look, _) = @motion.overlay_presence(s, enter=@motion.dialog_in, exit=@motion.dialog_out)
      let init_exp = if detents { @signals.untracked(expanded) } else { false }
      let exp_state = @signals.signal(init_exp)
      let detent_way = @motion.NodeWay::new(if init_exp { 1.0 } else { 0.0 })
      let drag_y = @motion.NodeWay::new(0.0)
      if detents {
        s.reacts(
          at_start=false,
          expanded,
          fn(on) {
            exp_state.set(on)
            detent_way.go(s, if on { 1.0 } else { 0.0 }, @motion.move_damped)
          },
        )
      }
      let detent_val = fn(n : @view.View) -> Double {
        if detents {
          clamp(detent_way.shown(n), 0.0, 1.0)
        } else {
          0.0
        }
      }
      // Narrow / phone viewports dock flush on left, right and bottom at detent=1.0;
      // wide desktop viewports remain a floating rounded island so we never get flat-bottom floating cards.
      let docks_edges = fn() -> Bool {
        let ww = s.window_w()
        ww <= 0.0 || ww <= width + 2.0 * ovl_sheet_inset + 4.0
      }
      let dock_t = fn(n : @view.View) -> Double {
        if docks_edges() {
          detent_val(n)
        } else {
          0.0
        }
      }
      let heights = fn() -> (Double, Double) {
        let wh = s.window_h()
        let half_h = if wh > 0.0 {
          clamp(wh * 0.52, 260.0, max_height)
        } else {
          max_height * 0.72
        }
        let full_h = if wh > 120.0 {
          if docks_edges() { wh - 32.0 } else { wh - 48.0 }
        } else {
          max_height
        }
        let full_clamped = if full_h > half_h + 60.0 { full_h } else { half_h + 60.0 }
        (half_h, full_clamped)
      }
      s.over(Is(true)).points(By(open)).lines_up(Is(Some(Middle))).lies_along(Is(End)) |> ignore
      // Dimmed backdrop scrim; clicking outside the sheet card closes via @headless.dialog.
      s.box(fn(scrim) {
        scrim
        .over(Is(true))
        .ground(By(fn() { colors().scrim }))
        .alpha(By(fn() {
          let drag_fade = 1.0 - clamp(drag_y.shown(scrim) / 260.0, 0.0, 1.0)
          clamp(look().alpha * drag_fade, 0.0, 1.0)
        }))
        |> ignore
      })
      |> ignore
      s.box(fn(room) {
        let cur_inset = fn() -> Double {
          if docks_edges() {
            lerp(ovl_sheet_inset, 0.0, detent_val(room))
          } else {
            ovl_sheet_wide_inset
          }
        }
        room
        .width(By(fn() {
          let ww = s.window_w()
          if docks_edges() && ww > 0.0 {
            Some(ww)
          } else {
            Some(width + 2.0 * cur_inset())
          }
        }))
        .max_width(By(fn() {
          let ww = s.window_w()
          if docks_edges() && ww > 0.0 {
            Some(ww)
          } else {
            Some(width + 2.0 * ovl_sheet_wide_inset)
          }
        }), within=true)
        .padding(By(fn() {
          let ins = cur_inset()
          (ins, ins, ins, ins)
        }))
        |> ignore
        @headless.dialog(
          room,
          title,
          open,
          on_close,
          description=subtitle,
          made_for=loc,
          fn(card, dlg) {
            let toggle_detent = fn() {
              if detents {
                let next = !exp_state.untracked()
                exp_state.set(next)
                on_expanded(next)
                detent_way.go(card, if next { 1.0 } else { 0.0 }, @motion.move_damped)
              }
            }
            if detents {
              card
              .height(By(fn() {
                let (half_h, full_h) = heights()
                Some(lerp(half_h, full_h, detent_val(card)))
              }))
              |> ignore
            } else {
              card.max_height(Is(Some(max_height))) |> ignore
            }
            card
            .radius(By(fn() { lerp(ovl_sheet_radius, ovl_sheet_expanded_top_radius, dock_t(card)) }))
            .corners(By(fn() {
              let dt = dock_t(card)
              let top_r = lerp(ovl_sheet_radius, ovl_sheet_expanded_top_radius, dt)
              let bot_r = lerp(ovl_sheet_radius, 0.0, dt)
              Some((top_r, top_r, bot_r, bot_r))
            }))
            .shadow(Is(shadow_default))
            .shadow_outside(Is(true))
            .glass(By(fn() { Some(ovl_sheet_glass_at(detent_val(card))) }))
            .edge(By(fn() { if card.glass_solid() { ovl_solid_edge() } else { (0.0, clear) } }))
            .alpha(By(fn() { look().alpha }))
            .offset(By(fn() { (0.0, look().dy + drag_y.shown(card)) }))
            |> ignore
            // Interactive grabber + header drag handle
            let drag_start_wy = Ref(0.0)
            let drag_start_dy = Ref(0.0)
            let drag_start_det = Ref(0.0)
            card.box(fn(handle) {
              handle
              .gesture(
                @ui.touch_slop(),
                press=fn(d) {
                  drag_start_wy.val = d.wy
                  drag_start_dy.val = drag_y.value_at(d.at)
                  drag_start_det.val = if detents { detent_way.value_at(d.at) } else { 0.0 }
                },
                drag=fn(d) {
                  let (half_h, full_h) = heights()
                  let span = full_h - half_h
                  match d.kind {
                    Down | Moved => {
                      let raw_dy = d.wy - drag_start_wy.val
                      if !detents {
                        let tot = drag_start_dy.val + raw_dy
                        if tot >= 0.0 {
                          drag_y.put(tot)
                        } else {
                          let over = -tot
                          drag_y.put(-(over * ovl_sheet_overpull_max / (over + ovl_sheet_overpull_max * 2.0)))
                        }
                      } else {
                        let total_up = drag_start_det.val * span - (drag_start_dy.val + raw_dy)
                        if total_up >= 0.0 && total_up <= span {
                          detent_way.put(total_up / span)
                          drag_y.put(0.0)
                        } else if total_up > span {
                          detent_way.put(1.0)
                          let over = total_up - span
                          drag_y.put(-(over * ovl_sheet_overpull_max / (over + ovl_sheet_overpull_max * 2.0)))
                        } else {
                          detent_way.put(0.0)
                          drag_y.put(-total_up)
                        }
                      }
                    }
                    Up | Off => {
                      let vy = d.vy()
                      let cur_dy = drag_y.value_at(d.at)
                      let cur_det = if detents { detent_way.value_at(d.at) } else { 0.0 }
                      let can_close = d.kind is Up &&
                        cur_det < 0.15 &&
                        (cur_dy > ovl_sheet_drag_dismiss || vy > ovl_sheet_drag_vel) &&
                        vy >= -ovl_sheet_drag_vel
                      if can_close {
                        drag_y.go(card, 320.0, @motion.move_damped, velocity=vy)
                        dlg.close()
                      } else {
                        drag_y.go(card, 0.0, @motion.move_damped, velocity=vy)
                        if detents {
                          let next = if vy <= -ovl_sheet_drag_vel {
                            true
                          } else if vy >= ovl_sheet_drag_vel {
                            false
                          } else {
                            cur_det >= 0.45
                          }
                          exp_state.set(next)
                          on_expanded(next)
                          detent_way.go(card, if next { 1.0 } else { 0.0 }, @motion.move_damped)
                        }
                      }
                    }
                  }
                },
              )
              |> ignore
              // Header row: title + optional subtitle + X/Y symmetric concentric close button
              // (floating r=28pt -> 12pt top & 12pt right; docked r=24pt -> 8pt top & 8pt right; 16pt + pad == top_r).
              handle.box(fn(hdr) {
                hdr
                .row(Is(true))
                .lines_up(Is(Some(Start)))
                .lies_along(Is(Between))
                .gap(Is(ovl_sheet_gap))
                .padding(By(fn() {
                  let corner_pad = lerp(ovl_sheet_hdr_pr, ovl_sheet_hdr_pr_expanded, dock_t(hdr))
                  (ovl_sheet_pad, corner_pad, corner_pad, ovl_sheet_gap)
                }))
                |> ignore
                hdr.box(fn(titles) {
                  // Top clearance keeps the title comfortably below the overlaid top-center grabber capsule.
                  titles.grow(Is(1.0)).gap(Is(ovl_text_gap)).padding(Is((0.0, 12.0, 0.0, 0.0))) |> ignore
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
              // Top-center drag-indicator capsule overlaid at top edge so it never pushes the close button downward.
              handle.box(fn(grab_wrap) {
                grab_wrap
                .over(Is(true))
                .points(Is(false))
                .lies_along(Is(Start))
                .lines_up(Is(Some(Middle)))
                |> ignore
                if detents {
                  @headless.button(
                    grab_wrap,
                    fn() { if exp_state.get() { "Collapse Sheet" } else { "Expand Sheet" } },
                    fn(_) { toggle_detent() },
                    made_for=loc,
                    fn(gb, btn) {
                      gb
                      .width(Is(Some(64.0)))
                      .height(Is(Some(24.0)))
                      .points(Is(true))
                      .radius(Is(12.0))
                      .lines_up(Is(Some(Middle)))
                      .lies_along(Is(Middle))
                      |> ignore
                      ovl_focus_ring(gb, fn() { btn.focus_shown() }, 12.0)
                      gb.box(fn(grab) {
                        grab
                        .width(Is(Some(ovl_sheet_grabber_w)))
                        .height(Is(Some(ovl_sheet_grabber_h)))
                        .radius(Is(ovl_sheet_grabber_h / 2.0))
                        .ground(By(ovl_grabber_color))
                        |> ignore
                      })
                      |> ignore
                    },
                  )
                  |> ignore
                } else {
                  grab_wrap.box(fn(grab_slot) {
                    grab_slot.padding(Is((0.0, 8.0, 0.0, 0.0))) |> ignore
                    grab_slot.box(fn(grab) {
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
                }
              })
              |> ignore
            })
            |> ignore
            // Body slot (grows and clips cleanly when `detents=true` expands/contracts)
            card.box(fn(b) {
              if detents {
                b.grow(Is(1.0)).min_height(Is(Some(0.0))).clips(Is(true)) |> ignore
              }
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
