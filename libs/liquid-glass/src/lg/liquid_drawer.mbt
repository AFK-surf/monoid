// Liquid Glass Floating Island Side Drawer (`liquid_drawer_node`) over `@headless.dialog`.
// Follows Apple iPadOS 26 / iOS 26 floating island sidebar geometry: 10pt outer inset from window edges,
// 28pt concentric outer radius (`12pt + 16pt` inner close/row radius), single-layer dense `ovl_drawer_glass()`,
// zero glass-on-glass inside, interactive horizontal drag-to-dismiss with asymptotic rubber-band over-pull,
// and velocity-continuous `@motion.move_damped` spring settle.

///|
/// Which edge of the window a `liquid_drawer_node` floats beside.
#derive(Eq)
pub(all) enum DrawerSide {
  Leading
  Trailing
}

///|
/// A Liquid Glass floating island side drawer in `parent`, open while `open()` holds.
/// Supports `Leading` and `Trailing` placement, interactive horizontal drag with rubber-band
/// over-pull (max 16pt) and velocity-continuous dismiss (> 32% width or > 0.45 pt/ms),
/// Escape / scrim tap dismissal via `@headless.dialog`, and `MBUI_GLASS=solid` 1pt edge fallback.
#callsite(autofill(loc))
pub fn liquid_drawer_node(
  parent : @view.View,
  open : () -> Bool,
  on_close : () -> Unit,
  title : () -> String,
  body : (@view.View) -> Unit,
  side? : DrawerSide = Leading,
  width? : Double = 320.0,
  subtitle? : () -> String = fn() { "" },
  footer? : (@view.View) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    h.over(Is(true)) |> ignore
    let shown_open = ovl_transitioned_bool(h, open)
    let sign = match side {
      Leading => -1.0
      Trailing => 1.0
    }
    let travel = width + ovl_drawer_inset * 2.0
    let off_x = sign * travel
    h.show(shown_open, leave=ovl_drawer_leave_ms, fn(s) {
      let slide = @motion.NodeWay::new(off_x)
      slide.go(s, 0.0, @motion.move_damped)
      s.reacts(
        at_start=false,
        open,
        fn(on) {
          if on {
            slide.go(s, 0.0, @motion.move_damped)
          } else {
            slide.go(s, off_x, @motion.move_damped)
          }
        },
      )
      let vis = fn(n : @view.View) -> Double {
        let dismiss_dist = slide.shown(n) * sign
        clamp(1.0 - dismiss_dist / travel, 0.0, 1.0)
      }
      s
      .over(Is(true))
      .points(By(open))
      .row(Is(true))
      .lies_along(Is(match side { Leading => Start; Trailing => End }))
      .fills_across(Is(true))
      |> ignore
      // Lightweight scrim whose opacity continuously tracks drawer visibility (0..0.18).
      s.box(fn(scrim) {
        scrim
        .over(Is(true))
        .ground(By(fn() { alpha(black, ovl_drawer_scrim_alpha * vis(scrim)) }))
        |> ignore
      })
      |> ignore
      s.box(fn(room) {
        room
        .width(Is(Some(width + 2.0 * ovl_drawer_inset)))
        .max_width(Is(Some(width + 2.0 * ovl_drawer_inset)), within=true)
        .padding(Is((ovl_drawer_inset, ovl_drawer_inset, ovl_drawer_inset, ovl_drawer_inset)))
        |> ignore
        @headless.dialog(
          room,
          title,
          open,
          on_close,
          description=subtitle,
          made_for=loc,
          fn(card, dlg) {
            let drag_start_wx = Ref(0.0)
            let drag_start_x = Ref(0.0)
            card
            .grow(Is(1.0))
            .radius(Is(ovl_drawer_radius))
            .shadow(Is(shadow_default))
            .shadow_outside(Is(true))
            .glass(By(fn() { Some(ovl_drawer_glass()) }))
            .edge(By(fn() { if card.glass_solid() { ovl_solid_edge() } else { (0.0, clear) } }))
            .offset(By(fn() { (slide.shown(card), 0.0) }))
            |> ignore
            // Full-card gesture container inside `@headless.dialog` (avoids `@headless.dialog`'s outer no-op `on_drag`).
            card.box(fn(pan) {
              pan
              .grow(Is(1.0))
              .min_height(Is(Some(0.0)))
              .gesture(
                @ui.touch_slop(),
                press=fn(d) {
                  drag_start_wx.val = d.wx
                  drag_start_x.val = slide.value_at(d.at)
                },
                drag=fn(d) {
                  match d.kind {
                    Down | Moved => {
                      let raw = drag_start_x.val + (d.wx - drag_start_wx.val)
                      let dismiss_raw = raw * sign
                      let mapped = if dismiss_raw >= 0.0 {
                        dismiss_raw
                      } else {
                        let over = -dismiss_raw
                        -(over * ovl_drawer_overpull_max / (over + ovl_drawer_overpull_max * 2.0))
                      }
                      slide.put(mapped * sign)
                    }
                    Up | Off => {
                      let cur = slide.value_at(d.at)
                      let dismiss_dist = cur * sign
                      let dismiss_vel = d.vx() * sign
                      let should_close = d.kind is Up &&
                        (dismiss_dist > width * ovl_drawer_dismiss_ratio || dismiss_vel > ovl_drawer_dismiss_vel) &&
                        dismiss_vel >= -ovl_drawer_dismiss_vel
                      if should_close {
                        slide.go(card, off_x, @motion.move_damped, velocity=d.vx())
                        dlg.close()
                      } else {
                        slide.go(card, 0.0, @motion.move_damped, velocity=d.vx())
                      }
                    }
                  }
                },
              )
              |> ignore
              // Header row: title + optional subtitle + concentric circular close button (12pt inset + 16pt r == 28pt)
              pan.box(fn(hdr) {
                hdr
                .row(Is(true))
                .lines_up(Is(Some(Start)))
                .lies_along(Is(Between))
                .gap(Is(ovl_drawer_pad))
                .padding(Is((ovl_drawer_hdr_pl, ovl_drawer_pad, ovl_drawer_pad, ovl_drawer_pad)))
                |> ignore
                hdr.box(fn(titles) {
                  titles.grow(Is(1.0)).gap(Is(ovl_text_gap)).padding(Is((0.0, 2.0, 0.0, 0.0))) |> ignore
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
              // Hairline separator below header
              pan.box(fn(sep) {
                sep.height(Is(Some(ovl_hairline_h))).ground(By(ovl_hairline)) |> ignore
              })
              |> ignore
              // Body slot (strictly zero glass-on-glass)
              pan.box(fn(b) {
                b
                .grow(Is(1.0))
                .min_height(Is(Some(0.0)))
                .padding(Is((ovl_drawer_pad, ovl_drawer_pad, ovl_drawer_pad, ovl_drawer_pad)))
                |> ignore
                body(b)
              })
              |> ignore
              // Optional footer slot
              match footer {
                Some(draw_footer) =>
                  pan.box(fn(f) {
                    f.box(fn(sep) {
                      sep.height(Is(Some(ovl_hairline_h))).ground(By(ovl_hairline)) |> ignore
                    })
                    |> ignore
                    f.box(fn(inner) {
                      inner.padding(Is((ovl_drawer_pad, ovl_drawer_pad, ovl_drawer_pad, ovl_drawer_pad))) |> ignore
                      draw_footer(inner)
                    })
                    |> ignore
                  })
                  |> ignore
                None => ()
              }
            })
            |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
  })
}
