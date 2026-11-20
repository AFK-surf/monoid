// Ported from Kyant0/AndroidLiquidGlass (Apache-2.0): catalog/components/LiquidSlider.kt. A track 6 high across all of
// its width, a capsule in the track's grey, filled in the accent up to its value; its thumb a white capsule 40 × 24 over
// it, its middle at the value, held within a quarter of itself of the track's ends. Held, the thumb turns to glass (its
// white and blur of 8 receding as its lens comes up, 10 deep bending by up to 14, the colours split, its Ambient
// highlight and its InnerShadow of 4), grows by half again and is squeezed as it goes by how fast (velocity / 10). The
// thumb is dragged by as much as the finger moves; a tap on the track sends it there as a hand would (pressed, sent,
// let go). Its keys and a screen reader's steps are mbui's headless slider's.
//
// The catalog's lens also sees the track scaled under it (a combined backdrop): mbui's glass sees the track as it is.

///|
/// The thumb's glass, held `p` (iOS 27 clear loupe).
fn slider_glass(p : Double) -> @paint.Glass {
  let p = clamp(p, 0.0, 1.0)
  @paint.Glass::liquid(
    blur=0.0,
    tint=0xFFFFFF00L,
    solid=white,
    saturation=1.0,
    rim=0.6 * p,
    bezel=10.0 * p,
    refraction=14.0 * p,
    chroma=-0.06 * p,
    merge=0.0,
    adaptive=false,
  )
}

///|
/// Where the thumb's left is along a track `w` wide at `progress` (0-1) of it: its middle there, held within a quarter
/// of itself of the ends.
fn slider_thumb_x(w : Double, progress : Double) -> Double {
  let hi = w - thumb_w * 3.0 / 4.0
  let lo = -thumb_w / 4.0
  if hi < lo {
    lo
  } else {
    clamp(-thumb_w / 2.0 + w * progress, lo, hi)
  }
}

///|
/// A LiquidSlider in `parent`, at `value` along `least` … `most`; moved (its thumb dragged, its track tapped, a key, a
/// screen reader's step), `change` is told the new value. Read out a slider named `label`. As wide as what holds it
/// gives it, 24 high. The node.
#callsite(autofill(loc))
pub fn liquid_slider_node(
  parent : @view.View,
  value : () -> Double,
  change : (Double) -> Unit,
  label : () -> String,
  least? : Double = 0.0,
  most? : Double = 100.0,
  threshold? : Double = 0.01,
  disabled? : () -> Bool = fn() { false },
  drag? : DampedDrag,
  loc~ : SourceLoc,
) -> @view.View {
  let dd = match drag {
    Some(d) => d
    None => DampedDrag::new(@signals.untracked(value), lo=least, hi=most, threshold~, held_scale=thumb_held_scale)
  }
  let span = most - least
  let on_thumb = Ref(false)
  let did_drag = Ref(false)
  let last_x = Ref(0.0)
  let hand = fn(d : @view.Drag) {
    if disabled() || d.w <= 0.0 {
      return
    }
    match d.kind {
      Down => {
        let tx = slider_thumb_x(d.w, (dd.target() - least) / span)
        let hit_thumb = d.x >= tx && d.x <= tx + thumb_w
        on_thumb.val = true
        did_drag.val = false
        last_x.val = d.wx
        dd.press()
        if !hit_thumb {
          let to = clamp(least + span * (d.x / d.w), least, most)
          dd.update_value(to)
          change(to)
        }
      }
      Moved =>
        if on_thumb.val {
          let dx = d.wx - last_x.val
          last_x.val = d.wx
          if dx != 0.0 {
            did_drag.val = true
          }
          change(clamp(dd.target() + span * (dx / d.w), least, most))
        }
      Up =>
        if on_thumb.val {
          if did_drag.val {
            change(dd.target())
          }
          on_thumb.val = false
          dd.release()
        }
      Off =>
        if on_thumb.val {
          on_thumb.val = false
          dd.release()
        }
    }
  }
  @headless.slider(
    made_for=loc,
    parent,
    label,
    value,
    min=least,
    max=most,
    step=0.0,
    change,
    disabled~,
    drag=hand,
    fn(s, sl) {
      dd.attach(s)
      s.height(Is(Some(thumb_h))).alpha(By(fn() { if sl.disabled() { 0.5 } else { 1.0 } })) |> ignore
      // (moved by what is not this hand's drag: its value followed, LaunchedEffect's updateValue)
      s.reacts(at_start=false, value, fn(v) { if dd.target() != v { dd.update_value(v) } })
      s.by_room(fn(inner, room) {
        let w = fn() { room.width() }
        inner.box(fn(track) {
          track
          .over(Is(true))
          .width(By(fn() { Some(w()) }))
          .height(Is(Some(slider_track_h)))
          .offset(Is((0.0, (thumb_h - slider_track_h) / 2.0)))
          .radius(Is(slider_track_h / 2.0))
          .ground(By(fn() { colors().track }))
          |> ignore
        })
        |> ignore
        inner.box(fn(fill) {
          fill
          .over(Is(true))
          .width(By(fn() { Some(w()) }))
          .height(Is(Some(slider_track_h)))
          .offset(Is((0.0, (thumb_h - slider_track_h) / 2.0)))
          .radius(Is(slider_track_h / 2.0))
          .ground(By(fn() { colors().accent }))
          .ground_drawn(By(fn() {
            let shown = clamp(dd.progress(fill), 0.0, 1.0) * w()
            { ..@view.ground_as_laid, dw: shown - w() }
          }))
          |> ignore
        })
        |> ignore
        inner.box(fn(thumb) {
          let size = fn() {
            let (sx, sy) = dd.jelly(thumb, 10.0)
            (thumb_w * sx, thumb_h * sy)
          }
          thumb
          .over(Is(true))
          .width(By(fn() { Some(size().0) }))
          .height(By(fn() { Some(size().1) }))
          .radius(By(fn() { size().1 / 2.0 }))
          .offset(By(fn() {
            let (tw, th) = size()
            let x = slider_thumb_x(w(), dd.progress(thumb))
            (x + (thumb_w - tw) / 2.0, (thumb_h - th) / 2.0)
          }))
          .shadow(Is(shadow_thumb))
          |> ignore
          thumb.box(fn(solid) {
            solid
            .over(Is(true))
            .radius(By(fn() { size().1 / 2.0 }))
            .ground(Is(white))
            .alpha(By(fn() { 1.0 - clamp(dd.pressed(solid), 0.0, 1.0) }))
            |> ignore
          })
          |> ignore
          thumb.box(fn(gl) {
            gl
            .over(Is(true))
            .radius(By(fn() { size().1 / 2.0 }))
            .glass(By(fn() { Some(slider_glass(dd.pressed(gl))) }))
            .alpha(By(fn() { clamp(dd.pressed(gl), 0.0, 1.0) }))
            |> ignore
          })
          |> ignore
        })
        |> ignore
        inner.show(fn() { sl.focus_shown() }, fn(ring) {
          ring
          .over(Is(true))
          .width(Is(Some(thumb_w + 6.0)))
          .height(Is(Some(thumb_h + 6.0)))
          .radius(Is(thumb_h / 2.0 + 3.0))
          .offset(By(fn() { (slider_thumb_x(w(), dd.progress(ring)) - 3.0, -3.0) }))
          .edge(By(fn() { (2.0, colors().accent) }))
          |> ignore
        })
      })
      |> ignore
    },
  )
}
