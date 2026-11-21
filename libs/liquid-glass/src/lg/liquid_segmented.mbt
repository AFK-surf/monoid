// iOS 26/27 Liquid Glass segmented control: outer floating glass capsule (r = height / 2),
// 3pt inset, equal-width segments over @headless.radio_group, and a strictly concentric
// sliding thumb (r = height / 2 - 3pt) driven by DampedDragAnimation (DampedDrag).
// At rest the thumb is an opaque optical pill (zero glass-on-glass); while held/dragged
// it cross-fades to a clear refraction loupe.

///|
/// A Liquid Glass segmented control in `parent`, displaying `labels` with `selected` active
/// and calling `on_select` when changed by tap, continuous drag, or keyboard arrows/Home/End.
#callsite(autofill(loc))
pub fn liquid_segmented_node(
  parent : @view.View,
  labels : () -> Array[String],
  selected : () -> Int,
  on_select : (Int) -> Unit,
  width? : Double,
  height? : Double = 40.0,
  drag? : DampedDrag,
  loc~ : SourceLoc,
) -> @view.View {
  let outer_r = height / 2.0
  let inner_h = height - 2.0 * ctrl_seg_pad
  let inner_r = inner_h / 2.0
  let init_count = @signals.untracked(labels).length()
  let last_init = if init_count > 1 { (init_count - 1).to_double() } else { 0.0 }
  let first = @signals.untracked(selected).to_double()
  let dd = match drag {
    Some(d) => d
    None => DampedDrag::new(first, lo=0.0, hi=last_init, held_scale=ctrl_seg_held_scale)
  }
  let current = Ref(@signals.untracked(selected))
  let last_x = Ref(0.0)
  @headless.radio_group(
    made_for=loc,
    parent,
    fn() { "Segmented Control" },
    selected,
    on_select,
    kind=Tab,
    axis=Horizontal,
    fn(g, rg) {
      dd.attach(g)
      g
      .height(Is(Some(height)))
      .shrink(Is(0.0))
      .padding(Is((ctrl_seg_pad, 0.0, ctrl_seg_pad, 0.0)))
      .radius(Is(outer_r))
      .shadow(Is(shadow_default))
      .glass(By(fn() { Some(ctrl_segmented_track_glass()) }))
      |> ignore
      match width {
        Some(w) => g.width(Is(Some(w))) |> ignore
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
        let seg_w = fn() { room.width() / count_fn().to_double() }
        // Sliding concentric thumb (behind text so labels stay razor sharp)
        inner.box(fn(thumb) {
          let size = fn() {
            let (sx, sy) = dd.jelly(thumb, 10.0)
            (seg_w() * sx, inner_h * sy)
          }
          thumb
          .over(Is(true))
          .points(Is(false))
          .width(By(fn() { Some(size().0) }))
          .height(By(fn() { Some(size().1) }))
          .radius(By(fn() { size().1 / 2.0 }))
          .offset(By(fn() {
            let (tw, th) = size()
            let sw = seg_w()
            (dd.value(thumb) * sw + (sw - tw) / 2.0, (height - th) / 2.0)
          }))
          .shadow(Is(shadow_thumb))
          |> ignore
          // Crisp optical pill at rest (fades out as clear loupe lifts on press)
          thumb.box(fn(pill) {
            pill
            .over(Is(true))
            .points(Is(false))
            .radius(By(fn() { size().1 / 2.0 }))
            .ground(By(ctrl_seg_thumb_idle))
            .alpha(By(fn() { 1.0 - clamp(dd.pressed(pill), 0.0, 1.0) }))
            |> ignore
          })
          |> ignore
          // Clear refraction loupe while held/dragged (zero blur, no hidden glass at rest)
          thumb.box(fn(gl) {
            gl
            .over(Is(true))
            .points(Is(false))
            .radius(By(fn() { size().1 / 2.0 }))
            .glass(By(fn() {
              let p = dd.pressed(gl)
              if p > 0.001 {
                Some(ctrl_segmented_lens_glass(p))
              } else {
                None
              }
            }))
            .alpha(By(fn() { clamp(dd.pressed(gl), 0.0, 1.0) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        let stopped = fn() {
          let to = clamp(dd.target().round(), 0.0, last_fn())
          let i = to.to_int()
          current.val = i
          dd.animate_to(to)
          if i != @signals.untracked(selected) {
            on_select(i)
          }
        }
        let on_drag = fn(d : @view.Drag) {
          match d.kind {
            Down | Moved => {
              let dx = d.wx - last_x.val
              last_x.val = d.wx
              let sw = seg_w()
              if sw > 0.0 {
                dd.update_value(clamp(dd.target() + dx / sw, 0.0, last_fn()))
              }
            }
            Up | Off => stopped()
          }
        }
        inner.box(fn(row) {
          row.row(Is(true)).height(Is(Some(height))) |> ignore
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
                  seg
                  .grow(Is(1.0))
                  .basis(Is(Some(0.0)))
                  .height(Is(Some(height)))
                  .padding(Is((ctrl_seg_px, 0.0, ctrl_seg_px, 0.0)))
                  .radius(Is(inner_r))
                  .lines_up(Is(Some(Middle)))
                  .lies_along(Is(Middle))
                  |> ignore
                  seg.box(fn(w) {
                    w
                    .words(By(fn() { item_sig.get().1 }), look=words_at(ctrl_type_seg, weight=weight_medium))
                    .ink(By(fn() {
                      let lit = clamp(1.0 - (dd.value(w) - idx_f).abs(), 0.0, 1.0)
                      lerp_color(ctrl_seg_inactive_ink(), colors().content, lit)
                    }))
                    |> ignore
                  })
                  |> ignore
                  // Overlay gesture target for tap + continuous drag (avoids headless-on-drag)
                  seg.box(fn(hit) {
                    hit
                    .over(Is(true))
                    .gesture(
                      @ui.touch_slop(),
                      press=fn(d) {
                        last_x.val = d.wx
                        dd.press()
                        if (idx_f - dd.target()).abs() > 0.001 {
                          dd.update_value(idx_f)
                        }
                      },
                      tap=fn(_) { stopped() },
                      drag=on_drag,
                    )
                    |> ignore
                  })
                  |> ignore
                  seg.show(fn() { it.focus_shown() }, fn(ring) {
                    ring
                    .over(Is(true))
                    .points(Is(false))
                    .radius(Is(inner_r))
                    .edge(By(fn() { (ctrl_focus_w, colors().accent) }))
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
      })
      |> ignore
    },
  )
}
