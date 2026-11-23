// iOS 26/27 Liquid Glass segmented control: outer capsule (`glass_track=true` floating glass capsule, or
// `glass_track=false` non-glass translucent track for embedding inside glass popovers / content layers with zero
// glass-on-glass at rest), concentric sliding thumb driven by DampedDragAnimation (DampedDrag).
// At rest the thumb is an opaque optical pill (zero hidden glass instances); while held/dragged it cross-fades to a
// clear refraction loupe (`blur == 0`, `zoom = 1.22`) rendered in the paint layer via `ground_drawn` (zero relayout).

///|
/// Horizontal growth cap (pt) for wide segments so the lifted lens keeps an even optical lip without overflowing.
let ctrl_seg_max_grow_x : Double = 24.0

///|
/// A Liquid Glass segmented control in `parent`, displaying `labels` with `selected` active
/// and calling `on_select` when changed by tap, continuous drag, or keyboard arrows/Home/End.
/// Set `glass_track=false` when embedded inside a glass popover or content layer to guarantee zero glass-on-glass at rest.
#callsite(autofill(loc))
pub fn liquid_segmented_node(
  parent : @view.View,
  labels : () -> Array[String],
  selected : () -> Int,
  on_select : (Int) -> Unit,
  width? : Double,
  height? : Double = 40.0,
  drag? : DampedDrag,
  glass_track? : Bool = true,
  pad? : Double = ctrl_seg_pad,
  gap? : Double = 0.0,
  widths? : () -> Array[Double],
  height_by? : () -> Double,
  text_size? : () -> Double,
  kind? : @headless.GroupKind = Tab,
  said? : String = "Segmented Control",
  shown? : () -> Bool = fn() { true },
  in_node? : Bool = false,
  render_item? : (@view.View, Int, () -> Bool) -> Unit,
  loc~ : SourceLoc,
) -> @view.View {
  let total_h = match height_by {
    Some(f) => f
    None => fn() { height }
  }
  let inner_h = fn() { dmax(0.0, total_h() - 2.0 * pad) }
  let init_count = @signals.untracked(labels).length()
  let last_init = if init_count > 1 { (init_count - 1).to_double() } else { 0.0 }
  let first = @signals.untracked(selected).to_double()
  let dd = match drag {
    Some(d) => d
    None =>
      DampedDrag::new(
        first,
        lo=0.0,
        hi=last_init,
        held_scale=ctrl_seg_held_scale,
      )
  }
  let current = Ref(@signals.untracked(selected))
  let strip_origin_x = Ref(0.0)
  @headless.radio_group(
    made_for=loc,
    parent,
    fn() { said },
    selected,
    on_select,
    kind~,
    axis=Horizontal,
    shown~,
    in_node~,
    fn(g, rg) {
      dd.attach(g)
      g
      .height(By(fn() { Some(total_h()) }))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      .padding(Is((pad, 0.0, pad, 0.0)))
      .radius(By(fn() { total_h() / 2.0 }))
      |> ignore
      if glass_track {
        g
        .shadow(Is(shadow_default))
        .shadow_outside(Is(true))
        .glass(By(fn() { Some(ctrl_segmented_track_glass()) }))
        .edge(By(fn() { if g.glass_solid() { liquid_solid_edge() } else { (0.0, clear) } }))
        |> ignore
      } else {
        g.ground(By(fn() { if is_dark() { 0x7878803DL } else { 0x7878801FL } })) |> ignore
      }
      match width {
        Some(w) => g.width(Is(Some(w))).max_width(Is(Some(w)), within=true) |> ignore
        None => ()
      }
      // (chosen by what is not the thumb: the keys, its caller; the thumb only slides there, unpressed and unmagnified)
      g.reacts(at_start=false, selected, fn(i) {
        if i != current.val {
          current.val = i
          dd.slide_to(i.to_double())
        }
      })
      g.by_room(fn(inner, room) {
        let count_fn = fn() {
          let n = labels().length()
          if n > 0 { n } else { 1 }
        }
        let last_fn = fn() {
          let n = count_fn()
          if n > 1 { (n - 1).to_double() } else { 0.0 }
        }
        let w_of = fn(k : Int) -> Double {
          match widths {
            Some(ws_fn) => ws_fn().get(k).unwrap_or(0.0)
            None => {
              let n = count_fn()
              dmax(0.0, (room.width() - gap * (n - 1).to_double()) / n.to_double())
            }
          }
        }
        let x_of = fn(k : Int) -> Double {
          let mut x = 0.0
          for i in 0..<k {
            x = x + w_of(i) + gap
          }
          x
        }
        // Interpolate (x, w) continuously along segment index `p`, supporting both equal and unequal widths.
        let rect_at = fn(p : Double) -> (Double, Double) {
          let n = count_fn()
          if n <= 1 {
            return (0.0, w_of(0))
          }
          let i = p.floor().to_int()
          let a = if i < 0 { 0 } else if i > n - 2 { n - 2 } else { i }
          let f = p - a.to_double()
          let x0 = x_of(a)
          let x1 = x_of(a + 1)
          let w0 = w_of(a)
          let w1 = w_of(a + 1)
          (x0 + (x1 - x0) * f, dmax(0.0, w0 + (w1 - w0) * f))
        }
        // Map a strip-local x coordinate to continuous segment index [0, n - 1] via adjacent segment centers.
        let index_at = fn(lx : Double) -> Double {
          let n = count_fn()
          if n <= 1 {
            return 0.0
          }
          let mut from = x_of(0) + w_of(0) / 2.0
          if lx <= from {
            return 0.0
          }
          for k in 1..<n {
            let to = x_of(k) + w_of(k) / 2.0
            if lx < to && to > from {
              return (k - 1).to_double() + clamp((lx - from) / (to - from), 0.0, 1.0)
            }
            from = to
          }
          (n - 1).to_double()
        }
        let no_lens = fn() { inner.glass_solid() || @ui.reduced_motion() }
        let lens = fn(v : @view.View) -> Double {
          if no_lens() {
            0.0
          } else {
            dd.pressed(v)
          }
        }
        // Solid concentric pill at rest (behind text, drawn in paint layer via ground_drawn for zero relayout).
        inner.box(fn(pill) {
          pill
          .over(Is(true))
          .points(Is(false))
          .offset(Is((0.0, 0.0)))
          .width(Is(Some(0.0)))
          .height(By(fn() { Some(inner_h()) }))
          .radius(By(fn() { inner_h() / 2.0 }))
          .alpha(By(fn() { clamp(1.0 - clamp(lens(pill), 0.0, 1.0) * 1.6, 0.0, 1.0) }))
          .ground_drawn(By(fn() {
            let (rx, rw) = rect_at(dd.value(pill))
            let ih = inner_h()
            { dx: rx, dy: (total_h() - ih) / 2.0, dw: rw, dh: 0.0, corners: None }
          }))
          |> ignore
          if glass_track {
            pill
            .ground(By(ctrl_seg_thumb_idle))
            .shadow(Is(ctrl_seg_thumb_idle_shadow))
            .shadow_outside(Is(true))
            |> ignore
          } else {
            pill
            .ground(By(fn() { @ui.tree_theme().lifted }))
            .edge(By(fn() { (0.5, @ui.tree_theme().line) }))
            .shadow(By(fn() { (1.0, 0.0, @ui.tree_theme().shadow) }))
            |> ignore
          }
        })
        |> ignore
        let mount_lens = fn() {
          inner.box(fn(gl) {
            let full = fn() { clamp(lens(gl), 0.0, 1.0) }
            gl
            .over(Is(true))
            .points(Is(false))
            .offset(Is((0.0, 0.0)))
            .width(Is(Some(0.0)))
            .height(By(fn() { Some(inner_h()) }))
            .radius(Is(1.0e6))
            .shadow(By(fn() { seg_lens_shadow(full()) }))
            .shadow_outside(Is(true))
            .glass(By(fn() {
              let p = full()
              if p > 0.001 {
                Some(if glass_track { ctrl_segmented_lens_glass(p) } else { ctrl_segmented_compact_lens_glass(p) })
              } else {
                None
              }
            }))
            .alpha(By(full))
            .ground_drawn(By(fn() {
              let (rx, rw) = rect_at(dd.value(gl))
              let th = total_h()
              let ih = inner_h()
              let p = full()
              let (sx, sy) = dd.jelly(gl, 10.0)
              let press_scale = lerp(1.0, ctrl_seg_held_scale, p)
              let vel_sx = if press_scale > 0.001 { sx / press_scale } else { 1.0 }
              let vel_sy = if press_scale > 0.001 { sy / press_scale } else { 1.0 }
              let base_grow_x = lerp(0.0, 20.0, p)
              let grow_x = dmin(base_grow_x + rw * (vel_sx - 1.0), ctrl_seg_max_grow_x)
              let lw = dmax(0.0, rw + grow_x)
              let base_lh = lerp(ih, th + 12.0, p)
              let lh = dmax(0.0, base_lh * vel_sy)
              {
                dx: rx + (rw - lw) / 2.0,
                dy: (th - lh) / 2.0,
                dw: lw,
                dh: lh - ih,
                corners: Some((lh / 2.0, lh / 2.0, lh / 2.0, lh / 2.0)),
              }
            }))
            |> ignore
          })
          |> ignore
        }
        let stopped = fn() {
          let last = last_fn()
          dd.set_bounds(lo=0.0, hi=last)
          let to = clamp(dd.target().round(), 0.0, last)
          let i = to.to_int()
          current.val = i
          if no_lens() {
            dd.slide_to(to)
          } else {
            dd.animate_to(to)
          }
          if i != @signals.untracked(selected) {
            on_select(i)
          }
        }
        let on_drag = fn(d : @view.Drag) {
          let last = last_fn()
          dd.set_bounds(lo=0.0, hi=last)
          match d.kind {
            Down | Moved => {
              let p = index_at(d.wx - strip_origin_x.val)
              if no_lens() {
                dd.slide_to(p)
              } else {
                dd.update_value(p)
              }
            }
            Up => stopped()
            Off => {
              let orig = @signals.untracked(selected)
              current.val = orig
              if no_lens() {
                dd.slide_to(orig.to_double())
              } else {
                dd.cancel_to(orig.to_double())
              }
            }
          }
        }
        inner.box(fn(row) {
          row
          .row(Is(true))
          .gap(Is(gap))
          .height(By(fn() { Some(total_h()) }))
          .lines_up(Is(Some(Middle)))
          |> ignore
          row.each(
            fn() {
              let ls = labels()
              let out : Array[(Int, String)] = []
              for i, s in ls {
                out.push((i, s))
              }
              out
            },
            fn(p) { p.0 },
            fn(slot, item_sig) {
              let idx = @signals.untracked(fn() { item_sig.get().0 })
              let idx_f = idx.to_double()
              rg.item(
                made_for=loc,
                slot,
                fn() { item_sig.get().0 },
                fn() { item_sig.get().1 },
                in_node=true,
                fn(seg, it) {
                  if widths is Some(_) {
                    seg.width(By(fn() { Some(w_of(idx)) })) |> ignore
                  } else {
                    seg
                    .grow(Is(1.0))
                    .basis(Is(Some(0.0)))
                    .padding(By(fn() {
                      let sw = w_of(idx)
                      let px = if sw > 0.0 && sw < 86.0 { 4.0 } else { ctrl_seg_px }
                      (px, 0.0, px, 0.0)
                    }))
                    |> ignore
                  }
                  seg
                  .height(By(fn() { Some(if glass_track { total_h() } else { inner_h() }) }))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  |> ignore
                  match render_item {
                    Some(draw_item) => draw_item(seg, idx, fn() { it.chosen() })
                    None =>
                      seg.box(fn(w) {
                        w
                        .words(By(fn() { item_sig.get().1 }))
                        .words_look(By(fn() {
                          let sz = match text_size {
                            Some(f) => f()
                            None => ctrl_type_seg
                          }
                          if glass_track {
                            words_at(sz, weight=weight_medium)
                          } else {
                            {
                              size: sz,
                              weight: if it.chosen() { 500 } else { 400 },
                              line: -@ui.tree_theme().text_line,
                              wrap: false,
                              tracking: @view.letters_own,
                              balance: false,
                              max_lines: 0,
                            }
                          }
                        }))
                        .ink(By(fn() {
                          let lit = clamp(1.0 - (dd.value(w) - idx_f).abs(), 0.0, 1.0)
                          let (off_c, on_c) = if glass_track {
                            (ctrl_seg_inactive_ink(), colors().content)
                          } else {
                            (@ui.tree_theme().muted, @ui.tree_theme().fg)
                          }
                          if !glass_track && it.hovered() && lit < 0.5 {
                            on_c
                          } else {
                            lerp_color(off_c, on_c, lit)
                          }
                        }))
                        |> ignore
                      })
                      |> ignore
                  }
                  // Gesture target directly on the item (no nested pressable box, keeping 36pt press_room intact)
                  seg.gesture(
                    @ui.touch_slop(),
                    press=fn(d) {
                      dd.set_bounds(lo=0.0, hi=last_fn())
                      strip_origin_x.val = d.wx - (x_of(idx) + d.x)
                      if !no_lens() {
                        dd.press()
                      }
                      if (idx_f - dd.target()).abs() > 0.001 {
                        if no_lens() {
                          dd.slide_to(idx_f)
                        } else {
                          dd.update_value(idx_f)
                        }
                      }
                    },
                    tap=fn(_) { stopped() },
                    drag=on_drag,
                  )
                  |> ignore
                  seg.show(fn() { it.focus_shown() }, fn(ring) {
                    ring
                    .over(Is(true))
                    .points(Is(false))
                    .radius(By(fn() { inner_h() / 2.0 }))
                    .edge(By(fn() { (ctrl_focus_w, if glass_track { colors().accent } else { @ui.tree_theme().focus }) }))
                    |> ignore
                  })
                },
              )
              |> ignore
            },
            at_once=true,
          )
        })
        |> ignore
        // Mount the clear refraction loupe above labels for both `glass_track=true` and `glass_track=false`
        // so dragging magnifies and refracts the segment labels underneath (iOS 26/27 optical Z-order).
        mount_lens()
      })
      |> ignore
    },
  )
}
