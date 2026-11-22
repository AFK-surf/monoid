// Liquid Glass feedback, navigation and structured container components:
// Toast, ProgressBar, ProgressRing, NavBar, Toolbar, List, and Disclosure.
// Zero glass-on-glass: outer shells use iOS 27 `Glass::liquid`, inner elements use subtle ink layers.

///|
/// Semantic status for `liquid_toast_node`.
#derive(Eq, Debug)
pub(all) enum LiquidStatus {
  Info
  Success
  Warning
  Error
}

///|
/// Composable single-layer Liquid Glass toast capsule shell (`liquid_toast_glass`, `shadow_outside(Is(true))`,
/// `MBUI_GLASS=solid` 1pt hairline fallback) for custom toast stacks and swipeable toaster layers.
#callsite(autofill(loc))
pub fn liquid_toast_shell_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  radius? : Double = ovl_toast_radius,
  max_width? : Double = 420.0,
  solid? : () -> Int64,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(shell) {
    shell
    .radius(Is(radius))
    .max_width(Is(Some(max_width)))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(
      By(fn() {
        let s = match solid {
          Some(f) => f()
          None => clear
        }
        Some(liquid_toast_glass(solid=s))
      }),
    )
    .edge(By(fn() { if shell.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
    |> ignore
    body(shell)
  })
}

///|
/// A Liquid Glass floating toast capsule (`r=24pt`) with vector status badge, title, optional
/// subtitle, optional action capsule, optional `×` dismiss button, horizontal swipe-to-dismiss when
/// `on_dismiss` is provided, and `MBUI_GLASS=solid` 1pt edge fallback.
#callsite(autofill(loc))
pub fn liquid_toast_node(
  parent : @view.View,
  visible : () -> Bool,
  title : () -> String,
  subtitle? : () -> String = fn() { "" },
  status? : LiquidStatus = Info,
  action_label? : () -> String = fn() { "" },
  on_action? : () -> Unit,
  on_dismiss? : () -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(h) {
    let shown_visible = ovl_transitioned_bool(h, visible)
    h.show(shown_visible, leave=@motion.pop_out_ms, fn(s) {
      let (look, _) = @motion.overlay_presence(s, enter=@motion.pop_in, exit=@motion.pop_out)
      let drag_x = @motion.NodeWay::new(0.0)
      let drag_start_wx = Ref(0.0)
      let drag_start_x = Ref(0.0)
      s
      .row(Is(true))
      .lines_up(Is(Some(Start)))
      .gap(Is(ovl_toast_gap))
      .padding(Is((ovl_toast_px, ovl_toast_py, ovl_toast_pr, ovl_toast_py)))
      .radius(Is(ovl_toast_radius))
      .shadow(Is(shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(liquid_toast_glass()) }))
      .edge(By(fn() { if s.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
      .alpha(By(fn() { look().alpha * clamp(1.0 - drag_x.shown(s).abs() / 240.0, 0.0, 1.0) }))
      .scale(By(fn() { look().sx }))
      .offset(By(fn() { (drag_x.shown(s), 0.0) }))
      .says(By(fn() { Some(@view.said(Status, label=title(), description=subtitle())) }))
      |> ignore
      match on_dismiss {
        Some(dismiss) =>
          s
          .gesture(
            @ui.touch_slop(),
            press=fn(d) {
              drag_start_wx.val = d.wx
              drag_start_x.val = drag_x.value_at(d.at)
            },
            drag=fn(d) {
              match d.kind {
                Down | Moved => drag_x.put(drag_start_x.val + (d.wx - drag_start_wx.val))
                Up | Off => {
                  let cur = drag_x.value_at(d.at)
                  let vx = d.vx()
                  let should_dismiss = d.kind is Up && (cur.abs() > 72.0 || vx.abs() > 0.45)
                  if should_dismiss {
                    let dir = if cur >= 0.0 { 1.0 } else { -1.0 }
                    drag_x.go(s, dir * 240.0, @motion.move_damped, velocity=vx)
                    dismiss()
                  } else {
                    drag_x.go(s, 0.0, @motion.move_damped, velocity=vx)
                  }
                }
              }
            },
          )
          |> ignore
        None => ()
      }
      // Vector status icon aligned to first line of title
      s.box(fn(ic) {
        ic
        .width(Is(Some(ovl_toast_icon_size)))
        .height(Is(Some(ovl_toast_icon_size)))
        .margin(Is((0.0, ovl_first_line_icon_pt, 0.0, 0.0)))
        .shrink(Is(0.0))
        .shapes(By(fn() { ovl_status_shapes(status, ovl_toast_icon_size, ovl_status_color(status)) }))
        |> ignore
      })
      |> ignore
      // Title + optional subtitle
      s.box(fn(col) {
        col.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).gap(Is(ovl_text_gap)) |> ignore
        col.box(fn(w) {
          w
          .words(By(title), look=words_at(ovl_type_body, weight=weight_medium, wrap=true))
          .ink(By(fn() { colors().content }))
          |> ignore
        })
        |> ignore
        col.show(fn() { subtitle() != "" }, fn(sub) {
          sub
          .words(By(subtitle), look=words_at(ovl_type_sub, wrap=true))
          .ink(By(ovl_muted_ink))
          |> ignore
        })
      })
      |> ignore
      // Optional action pill button
      match on_action {
        Some(act) =>
          s.show(fn() { action_label() != "" }, fn(slot) {
            @headless.button(slot, action_label, fn(_) { act() }, made_for=loc, fn(b, btn) {
              let press_scale = @motion.NodeWay::new(0.0)
              b.reacts(at_start=false, fn() { btn.pressed() }, fn(on) {
                press_scale.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
              })
              b
              .row(Is(true))
              .lines_up(Is(Some(Middle)))
              .lies_along(Is(Middle))
              .height(Is(Some(ovl_toast_action_h)))
              .padding(Is((ovl_toast_action_px, 0.0, ovl_toast_action_px, 0.0)))
              .radius(Is(ovl_toast_action_h / 2.0))
              .scale(By(fn() { 1.0 - 0.08 * clamp(press_scale.shown(b), 0.0, 1.0) }))
              |> ignore
              let hover_t = @motion.hover_fade(b, fn() { btn.hovered() })
              let press_t = @motion.hover_fade(b, fn() { btn.pressed() }, duration_ms=@motion.pointer_tap_ms)
              b
              .ground(
                By(fn() {
                  let base = ovl_action_pill_ground()
                  let h = hover_t()
                  let p = press_t()
                  let with_h = if h > 0.001 { over(base, alpha(ovl_row_hover(), h)) } else { base }
                  if p > 0.001 { over(with_h, alpha(ovl_row_press(), p)) } else { with_h }
                }),
              )
              |> ignore
              ovl_focus_ring(b, fn() { btn.focus_shown() }, ovl_toast_action_h / 2.0)
              b.box(fn(w) {
                w
                .words(By(action_label), look=words_at(ovl_type_sub, weight=weight_medium))
                .ink(By(fn() { colors().content }))
                |> ignore
              })
              |> ignore
            })
            |> ignore
          })
        None => ()
      }
      // Optional dismiss button
      match on_dismiss {
        Some(dismiss) =>
          @headless.button(s, fn() { "Dismiss" }, fn(_) { dismiss() }, made_for=loc, fn(b, btn) {
            let press_scale = @motion.NodeWay::new(0.0)
            b.reacts(at_start=false, fn() { btn.pressed() }, fn(on) {
              press_scale.go(b, if on { 1.0 } else { 0.0 }, @motion.snappy_damped)
            })
            b
            .width(Is(Some(ovl_toast_close_size)))
            .height(Is(Some(ovl_toast_close_size)))
            .shrink(Is(0.0))
            .radius(Is(ovl_toast_close_size / 2.0))
            .lines_up(Is(Some(Middle)))
            .lies_along(Is(Middle))
            .scale(By(fn() { 1.0 - 0.08 * clamp(press_scale.shown(b), 0.0, 1.0) }))
            |> ignore
            ovl_attach_row_ground(b, fn() { btn.hovered() }, fn() { btn.pressed() })
            ovl_focus_ring(b, fn() { btn.focus_shown() }, ovl_toast_close_size / 2.0)
            b.box(fn(ic) {
              ic
              .width(Is(Some(ovl_close_icon_size)))
              .height(Is(Some(ovl_close_icon_size)))
              .shapes(By(fn() { ovl_close_shapes(ovl_close_icon_size, ovl_muted_ink()) }))
              |> ignore
            })
            |> ignore
          })
          |> ignore
        None => ()
      }
    })
  })
}

///|
/// A Liquid Glass linear progress bar over `@headless.progress`.
/// Supports determinate `Some(0.0..1.0)` and smooth closed-form indeterminate `None` sweep.
#callsite(autofill(loc))
pub fn liquid_progress_bar_node(
  parent : @view.View,
  value : () -> Double?,
  label? : () -> String = fn() { "" },
  show_value? : Bool = false,
  tint? : Int64 = clear,
  height? : Double = 8.0,
  loc~ : SourceLoc,
) -> @view.View {
  @headless.progress(
    parent,
    value,
    min=0.0,
    max=1.0,
    label~,
    made_for=loc,
    fn(v, prog) {
      let fill_color = fn() { if tint != clear { tint } else { ovl_accent_ink() } }
      let prog_way = @motion.NodeWay::new(@signals.untracked(fn() { prog.part() * 100.0 }))
      v.reacts(at_start=false, fn() { if prog.indeterminate() { -1.0 } else { prog.part() * 100.0 } }, fn(pct) {
        if pct >= 0.0 {
          prog_way.go(v, pct, value_spring(0.05))
        }
      })
      v.gap(Is(ovl_progress_gap)) |> ignore
      v.show(fn() { label() != "" || (show_value && !prog.indeterminate()) }, fn(hdr) {
        hdr.row(Is(true)).lies_along(Is(Between)).lines_up(Is(Some(Middle))) |> ignore
        hdr.box(fn(w) {
          w.words(By(label), look=words_at(ovl_type_sub, weight=weight_medium)).ink(By(fn() { colors().content }))
          |> ignore
        })
        |> ignore
        hdr.show(fn() { show_value && !prog.indeterminate() }, fn(val_box) {
          val_box.row(Is(true)).width(Is(Some(38.0))).lies_along(Is(End)).lines_up(Is(Some(Middle))) |> ignore
          val_box.box(fn(w) {
            w
            .words(
              By(fn() {
                let pct = (prog.part() * 100.0).round().to_int()
                "\{pct}%"
              }),
              look=words_at(ovl_type_meta),
            )
            .ink(By(ovl_muted_ink))
            |> ignore
          })
          |> ignore
        })
      })
      v.box(fn(track) {
        track
        .height(Is(Some(height)))
        .radius(Is(height / 2.0))
        .ground(By(ovl_track_color))
        .clips(Is(true))
        |> ignore
        track.by_room(fn(inner, room) {
          let w = fn() { room.width() }
          let r = height / 2.0
          inner.show(fn() { !prog.indeterminate() }, fn(bar) {
            bar
            .over(Is(true))
            .width(By(fn() { Some(w()) }))
            .height(Is(Some(height)))
            .radius(Is(r))
            .ground(By(fill_color))
            .ground_drawn(
              By(fn() {
                let tw = w()
                let shown = clamp(prog_way.shown(bar) / 100.0, 0.0, 1.0) * tw
                { ..@view.ground_as_laid, dw: shown - tw }
              }),
            )
            |> ignore
          })
          inner.show(fn() { prog.indeterminate() }, fn(sweep) {
            sweep
            .over(Is(true))
            .width(By(fn() { Some(w()) }))
            .height(Is(Some(height)))
            .radius(Is(r))
            .ground(By(fill_color))
            .ground_drawn(
              By(fn() {
                let tw = w()
                let c = sweep.cycle(@motion.progress_sweep_ms)
                let sw = tw * ovl_progress_sweep_w
                let dx = c * (tw - sw)
                { ..@view.ground_as_laid, dx, dw: sw - tw }
              }),
            )
            |> ignore
          })
        })
        |> ignore
      })
      |> ignore
    },
  )
}

///|
/// A Liquid Glass circular progress ring over `@headless.progress` and `@paint.shape_of`.
/// Supports determinate `Some(0.0..1.0)` arc and smooth closed-form indeterminate `None` spin.
#callsite(autofill(loc))
pub fn liquid_progress_ring_node(
  parent : @view.View,
  value : () -> Double?,
  size? : Double = 36.0,
  stroke? : Double = 3.5,
  tint? : Int64 = clear,
  label? : () -> String = fn() { "Progress" },
  loc~ : SourceLoc,
) -> @view.View {
  @headless.progress(
    parent,
    value,
    min=0.0,
    max=1.0,
    label~,
    made_for=loc,
    fn(v, prog) {
      let ring_color = fn() { if tint != clear { tint } else { ovl_accent_ink() } }
      let ring_way = @motion.NodeWay::new(@signals.untracked(fn() { prog.part() * 100.0 }))
      v.reacts(at_start=false, fn() { if prog.indeterminate() { -1.0 } else { prog.part() * 100.0 } }, fn(pct) {
        if pct >= 0.0 {
          ring_way.go(v, pct, value_spring(0.05))
        }
      })
      v
      .width(Is(Some(size)))
      .height(Is(Some(size)))
      .shrink(Is(0.0))
      .shapes(
        By(fn() {
          if prog.indeterminate() {
            let phase = v.cycle(@motion.progress_sweep_ms)
            ovl_ring_shapes(size, stroke, phase, 0.28, ring_color(), ovl_track_color())
          } else {
            ovl_ring_shapes(
              size,
              stroke,
              0.0,
              clamp(ring_way.shown(v) / 100.0, 0.0, 1.0),
              ring_color(),
              ovl_track_color(),
            )
          }
        }),
      )
      |> ignore
    },
  )
}

///|
/// An iOS 26/27 floating-island navigation bar with centered title, optional subtitle, and
/// optional `leading` / `trailing` action slots.
/// By default (`glass=false`), the outer bar is transparent layout chrome so `leading` and
/// `trailing` slots can host floating Liquid Glass islands without glass-on-glass nesting.
/// Pass `glass=true` only when the bar contains zero inner glass controls.
#callsite(autofill(loc))
pub fn liquid_nav_bar_node(
  parent : @view.View,
  title : () -> String,
  subtitle? : () -> String = fn() { "" },
  leading? : (@view.View) -> Unit,
  trailing? : (@view.View) -> Unit,
  height? : Double = 56.0,
  glass? : Bool = false,
  compact? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(bar) {
    bar
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Between))
    .height(Is(Some(height)))
    .padding(By(fn() {
      let px = if compact() { 2.0 } else { ovl_nav_px }
      (px, 0.0, px, 0.0)
    }))
    .gap(By(fn() { if compact() { 6.0 } else { ovl_nav_gap } }))
    .says(By(fn() { Some(@view.said(Navigation, label=title())) }))
    |> ignore
    if glass {
      bar
      .radius(Is(height / 2.0))
      .shadow(Is(shadow_default))
      .shadow_outside(Is(true))
      .glass(By(fn() { Some(ovl_capsule_glass()) }))
      |> ignore
    }
    match leading {
      Some(draw_leading) =>
        bar.box(fn(slot) {
          slot
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(By(fn() { if compact() { 6.0 } else { ovl_toolbar_gap } }))
          |> ignore
          draw_leading(slot)
        })
        |> ignore
      None => ()
    }
    bar.box(fn(mid) {
      mid.grow(Is(1.0)).lines_up(Is(Some(Middle))).gap(Is(ovl_text_gap)) |> ignore
      mid.box(fn(w) {
        w
        .words(By(title), look=words_at(ovl_type_heading, weight=ovl_weight_semibold))
        .ink(By(fn() { colors().content }))
        |> ignore
      })
      |> ignore
      mid.show(fn() { subtitle() != "" }, fn(sub) {
        sub.words(By(subtitle), look=words_at(ovl_type_meta)).ink(By(ovl_muted_ink)) |> ignore
      })
    })
    |> ignore
    match trailing {
      Some(draw_trailing) =>
        bar.box(fn(slot) {
          slot
          .row(Is(true))
          .lines_up(Is(Some(Middle)))
          .gap(By(fn() { if compact() { 6.0 } else { ovl_toolbar_gap } }))
          |> ignore
          draw_trailing(slot)
        })
        |> ignore
      None => ()
    }
  })
}

///|
/// A Liquid Glass floating capsule toolbar (`r = height / 2`) with `MBUI_GLASS=solid` 1pt edge fallback.
#callsite(autofill(loc))
pub fn liquid_toolbar_node(
  parent : @view.View,
  body : (@view.View) -> Unit,
  height? : Double = 48.0,
  pad? : Double = ovl_toolbar_px,
  gap? : Double = ovl_toolbar_gap,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(bar) {
    bar
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .height(Is(Some(height)))
    .padding(Is((pad, 0.0, pad, 0.0)))
    .gap(Is(gap))
    .radius(Is(height / 2.0))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(By(fn() { Some(ovl_capsule_glass()) }))
    .edge(By(fn() { if bar.glass_solid() { liquid_overlay_solid_edge() } else { (0.0, clear) } }))
    .says(Is(Some(@view.said(Toolbar, label="Toolbar"))))
    |> ignore
    body(bar)
  })
}

///|
/// One row in a `liquid_list_node`.
pub(all) struct LiquidListRow {
  title : String
  subtitle : String
  value : String
  icon : ((@view.View, () -> Int64) -> Unit)?
  chevron : Bool
  on_press : (() -> Unit)?
  active : Bool
  destructive : Bool
  disabled : Bool
}

///|
/// Convenience constructor for `LiquidListRow`.
pub fn LiquidListRow::new(
  title~ : String,
  subtitle? : String = "",
  value? : String = "",
  icon? : (@view.View, () -> Int64) -> Unit,
  chevron? : Bool = false,
  on_press? : () -> Unit,
  active? : Bool = false,
  destructive? : Bool = false,
  disabled? : Bool = false,
) -> LiquidListRow {
  { title, subtitle, value, icon, chevron, on_press, active, destructive, disabled }
}

///|
/// Internal reactive entry for `liquid_list_node`'s `View::each`.
priv struct LiquidListItem {
  key : String
  idx : Int
  has_press : Bool
  has_icon : Bool
  row : LiquidListRow
}

///|
impl Eq for LiquidListItem with equal(self, other) {
  self.key == other.key &&
  self.idx == other.idx &&
  self.has_press == other.has_press &&
  self.has_icon == other.has_icon &&
  self.row.title == other.row.title &&
  self.row.subtitle == other.row.subtitle &&
  self.row.value == other.row.value &&
  self.row.chevron == other.row.chevron &&
  self.row.active == other.row.active &&
  self.row.destructive == other.row.destructive &&
  self.row.disabled == other.row.disabled
}

///|
/// Wrap rows with unique stable keys and current indices for reactive `View::each`.
fn ovl_list_items(rows : Array[LiquidListRow]) -> Array[LiquidListItem] {
  let seen : Map[String, Int] = Map([])
  let out : Array[LiquidListItem] = []
  for idx, row in rows {
    let n = seen.get(row.title).unwrap_or(0)
    seen.set(row.title, n + 1)
    let has_press = row.on_press is Some(_)
    let has_icon = row.icon is Some(_)
    let press_tag = if has_press { "p" } else { "s" }
    let key = if n == 0 { "\{press_tag}:\{row.title}" } else { "\{press_tag}:\{row.title}#\{n}" }
    out.push({ key, idx, has_press, has_icon, row })
  }
  out
}

///|
/// Render the reactive interior content of a `LiquidListRow`.
#callsite(autofill(loc))
fn ovl_list_row_inner(r : @view.View, item_sig : @signals.Signal[LiquidListItem], loc~ : SourceLoc) -> Unit {
  let row = fn() { item_sig.get().row }
  let title_ink = fn() {
    let cur = row()
    if cur.destructive {
      ovl_destructive()
    } else {
      colors().content
    }
  }
  r.show(fn() { item_sig.get().has_icon }, fn(ic) {
    ic
    .width(Is(Some(ovl_toast_icon_size)))
    .height(Is(Some(ovl_toast_icon_size)))
    .margin(Is((0.0, ovl_first_line_icon_pt, 0.0, 0.0)))
    .shrink(Is(0.0))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    |> ignore
    match item_sig.untracked().row.icon {
      Some(draw_icon) => draw_icon(ic, title_ink)
      None => ()
    }
  })
  r.box(made_for=loc, fn(col) {
    col.grow(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))).gap(Is(ovl_text_gap)) |> ignore
    col.box(fn(w) {
      w.words(By(fn() { row().title }), look=words_at(ovl_type_body, wrap=true)).ink(By(title_ink)) |> ignore
    })
    |> ignore
    col.show(fn() { row().subtitle != "" }, fn(sub) {
      sub.words(By(fn() { row().subtitle }), look=words_at(ovl_type_sub, wrap=true)).ink(By(ovl_muted_ink)) |> ignore
    })
  })
  |> ignore
  r.show(fn() { row().value != "" }, fn(v) {
    v
    .margin(Is((0.0, ovl_first_line_sub_pt, 0.0, 0.0)))
    .words(By(fn() { row().value }), look=words_at(ovl_type_sub))
    .ink(By(ovl_muted_ink))
    |> ignore
  })
  r.show(fn() { row().chevron }, fn(ch) {
    ch
    .width(Is(Some(ovl_list_chevron)))
    .height(Is(Some(ovl_list_chevron)))
    .margin(Is((0.0, ovl_first_line_chevron_pt, 0.0, 0.0)))
    .shrink(Is(0.0))
    .shapes(By(fn() { ovl_chevron_right_shapes(ovl_list_chevron, ovl_muted_ink()) }))
    |> ignore
  })
}

///|
/// An iOS-style grouped inset content-layer list (`r=24pt`, `pad=6pt` -> rows `r=18pt`).
/// Reactive via `View::each`. With `dividers=true` (default), steady hairline dividers sit between adjacent rows (none
/// before the first or after the last) with `3pt` vertical breathing room above and below, so an active, hovered or
/// pressed row's pill keeps clear of them. With `dividers=false` (sidebar navigation mode), rows sit `4pt` apart with no
/// dividers so active and hovered pills never touch.
#callsite(autofill(loc))
pub fn liquid_list_node(
  parent : @view.View,
  rows : () -> Array[LiquidListRow],
  header? : () -> String = fn() { "" },
  footer? : () -> String = fn() { "" },
  dividers? : Bool = true,
  flat? : Bool = false,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(made_for=loc, fn(wrap) {
    wrap.show(fn() { header() != "" }, fn(h) {
      h.padding(Is((ovl_list_meta_px, 0.0, ovl_list_meta_px, ovl_list_meta_py))) |> ignore
      h.box(fn(w) {
        w
        .words(By(header), look=words_at(ovl_type_meta, weight=ovl_weight_semibold))
        .ink(By(ovl_muted_ink))
        |> ignore
      })
      |> ignore
    })
    wrap.box(fn(card) {
      card
      .padding(Is((ovl_list_pad, ovl_list_pad, ovl_list_pad, ovl_list_pad)))
      .radius(Is(ovl_list_radius))
      .says(
        By(fn() {
          let h = header()
          Some(@view.said(Group, label=if h != "" { h } else { "List" }))
        }),
      )
      |> ignore
      if flat {
        card
        .ground(By(fn() { if is_dark() { 0xFFFFFF12L } else { 0x0000000AL } }))
        .edge(By(fn() { (0.5, ovl_hairline()) }))
        |> ignore
      } else {
        card.shadow(Is(shadow_default)).shadow_outside(Is(true)).glass(By(fn() { Some(ovl_panel_glass()) })) |> ignore
      }
      if !dividers {
        card.gap(Is(ovl_list_gap_nodiv)) |> ignore
      }
      card.each(fn() { ovl_list_items(rows()) }, fn(it) { it.key }, fn(slot, item_sig) {
        if dividers {
          slot.show(fn() { item_sig.get().idx > 0 }, at_once=true, fn(sep) {
            sep.padding(Is((ovl_list_sep_inset, ovl_list_sep_py, ovl_list_sep_inset, ovl_list_sep_py))) |> ignore
            sep.box(fn(line) {
              line
              .height(Is(Some(ovl_hairline_h)))
              .ground(By(ovl_hairline))
              |> ignore
            })
            |> ignore
          })
        }
        let init_press = item_sig.untracked().has_press
        if init_press {
          @headless.button(
            slot,
            fn() { item_sig.get().row.title },
            fn(_) {
              let cur = item_sig.untracked().row
              if !cur.disabled {
                match cur.on_press {
                  Some(press) => press()
                  None => ()
                }
              }
            },
            disabled=fn() { item_sig.get().row.disabled },
            made_for=loc,
            fn(r, btn) {
              r
              .row(Is(true))
              .lines_up(Is(Some(Start)))
              .min_height(Is(Some(ovl_list_row_min_h)))
              .padding(Is((ovl_list_row_px, ovl_list_row_py, ovl_list_row_px, ovl_list_row_py)))
              .gap(Is(ovl_list_row_gap))
              .radius(Is(ovl_list_row_radius))
              .alpha(By(fn() { if btn.disabled() { ovl_disabled_alpha } else { 1.0 } }))
              |> ignore
              ovl_attach_row_ground(
                r,
                fn() { btn.hovered() },
                fn() { btn.pressed() },
                selected=fn() { item_sig.get().row.active },
                disabled=fn() { btn.disabled() },
              )
              ovl_focus_ring(r, fn() { btn.focus_shown() }, ovl_list_row_radius)
              ovl_list_row_inner(r, item_sig)
            },
          )
          |> ignore
        } else {
          slot.box(fn(r) {
            r
            .row(Is(true))
            .lines_up(Is(Some(Start)))
            .min_height(Is(Some(ovl_list_row_min_h)))
            .padding(Is((ovl_list_row_px, ovl_list_row_py, ovl_list_row_px, ovl_list_row_py)))
            .gap(Is(ovl_list_row_gap))
            .radius(Is(ovl_list_row_radius))
            .ground(By(fn() { if item_sig.get().row.active { ovl_row_selected() } else { clear } }))
            .alpha(By(fn() { if item_sig.get().row.disabled { ovl_disabled_alpha } else { 1.0 } }))
            |> ignore
            ovl_list_row_inner(r, item_sig)
          })
          |> ignore
        }
      })
    })
    |> ignore
    wrap.show(fn() { footer() != "" }, fn(f) {
      f.padding(Is((ovl_list_meta_px, ovl_list_meta_py, ovl_list_meta_px, 0.0))) |> ignore
      f.box(fn(w) {
        w.words(By(footer), look=words_at(ovl_type_meta, wrap=true)).ink(By(ovl_muted_ink)) |> ignore
      })
      |> ignore
    })
  })
}

///|
/// A Liquid Glass collapsible disclosure card (`r=22pt`, `pad=6pt` -> header `r=16pt`) over
/// `@headless.disclosure` with a closed-form animated vector chevron.
#callsite(autofill(loc))
pub fn liquid_disclosure_node(
  parent : @view.View,
  title : () -> String,
  open : () -> Bool,
  on_toggle : (Bool) -> Unit,
  content : (@view.View) -> Unit,
  subtitle? : () -> String = fn() { "" },
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let chev_turn = @motion.NodeWay::new(if @signals.untracked(open) { ovl_turn_quarter } else { 0.0 })
  let body_way = @motion.NodeWay::new(if @signals.untracked(open) { 1.0 } else { 0.0 })
  parent.box(made_for=loc, fn(card) {
    card
    .padding(Is((ovl_disc_pad, ovl_disc_pad, ovl_disc_pad, ovl_disc_pad)))
    .radius(Is(ovl_disc_radius))
    .shadow(Is(shadow_default))
    .shadow_outside(Is(true))
    .glass(By(fn() { Some(ovl_panel_glass()) }))
    |> ignore
    card.reacts(open, at_start=false, fn(is_open) {
      chev_turn.go(card, if is_open { ovl_turn_quarter } else { 0.0 }, @motion.snappy_damped)
      body_way.go(card, if is_open { 1.0 } else { 0.0 }, @motion.snappy_damped)
    })
    @headless.disclosure(
      card,
      title,
      open,
      fn(_) { on_toggle(!@signals.untracked(open)) },
      disabled~,
      made_for=loc,
      fn(hdr, d) {
        hdr
        .row(Is(true))
        .lines_up(Is(Some(Start)))
        .lies_along(Is(Between))
        .padding(Is((ovl_disc_hdr_px, ovl_disc_hdr_py, ovl_disc_hdr_px, ovl_disc_hdr_py)))
        .gap(Is(ovl_list_row_gap))
        .radius(Is(ovl_disc_hdr_radius))
        .alpha(By(fn() { if d.disabled() { ovl_disabled_alpha } else { 1.0 } }))
        |> ignore
        ovl_attach_row_ground(
          hdr,
          fn() { d.hovered() },
          fn() { d.pressed() },
          disabled=fn() { d.disabled() },
        )
        ovl_focus_ring(hdr, fn() { d.focus_shown() }, ovl_disc_hdr_radius)
        hdr.box(fn(col) {
          col.grow(Is(1.0)).gap(Is(ovl_text_gap)) |> ignore
          col.box(fn(w) {
            w
            .words(By(title), look=words_at(ovl_type_body, weight=weight_medium, wrap=true))
            .ink(By(fn() { colors().content }))
            |> ignore
          })
          |> ignore
          col.show(fn() { subtitle() != "" }, fn(sub) {
            sub.words(By(subtitle), look=words_at(ovl_type_sub, wrap=true)).ink(By(ovl_muted_ink)) |> ignore
          })
        })
        |> ignore
        hdr.box(fn(ch) {
          ch
          .width(Is(Some(ovl_disc_chevron)))
          .height(Is(Some(ovl_disc_chevron)))
          .margin(Is((0.0, ovl_first_line_chevron_pt, 0.0, 0.0)))
          .shrink(Is(0.0))
          .turn(By(fn() { chev_turn.shown(ch) }))
          .shapes(By(fn() { ovl_chevron_right_shapes(ovl_disc_chevron, ovl_muted_ink()) }))
          |> ignore
        })
        |> ignore
      },
    )
    |> ignore
    card.show(open, fn(body) {
      body
      .alpha(By(fn() { clamp(body_way.shown(body), 0.0, 1.0) }))
      .offset(By(fn() { (0.0, lerp(-6.0, 0.0, clamp(body_way.shown(body), 0.0, 1.0))) }))
      |> ignore
      body.box(fn(sep) {
        sep.padding(Is((ovl_list_sep_inset, ovl_list_sep_py, ovl_list_sep_inset, ovl_list_sep_py))) |> ignore
        sep.box(fn(line) { line.height(Is(Some(ovl_hairline_h))).ground(By(ovl_hairline)) |> ignore }) |> ignore
      })
      |> ignore
      body.box(fn(inner) {
        inner.padding(Is((ovl_disc_body_px, ovl_disc_body_py, ovl_disc_body_px, ovl_disc_body_py))) |> ignore
        content(inner)
      })
      |> ignore
    })
  })
}
