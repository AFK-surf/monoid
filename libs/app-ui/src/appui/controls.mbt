// The segmented control, the switch and the checkbox: mbui's headless radio group and toggle with this library's
// look. What moves in them moves as it is drawn (a thumb slid by `View::shift`, a knob by `View::offset`), on a spring
// set off by the press that chose or turned it: nothing is laid out again as it goes.

///|
/// How a thumb slides to where it is chosen, and a knob to the end it is turned to: mbui's spring for a control's
/// thumb (@motion.knob_spring: crisp, a little past it and back).
pub let slide : @motion.Spec = @motion.knob_spring

///|
/// The segmented control's track: its corner and how far in round its thumb (the thumb concentric with it).
pub let segment_track_radius : Double = 8.0

///|
pub let segment_track_inset : Space = S2

///|
/// A segmented control in `parent`, called `label`: `options` side by side, each as wide as the others, the one
/// `chosen` says on a thumb that slides to the one pressed (or stepped to by the arrow keys), `choose` told its index.
/// `height` 28 (24 in a toolbar). The node.
#callsite(autofill(loc))
pub fn segmented(
  parent : @view.View,
  label : () -> String,
  options : Array[String],
  chosen : () -> Int,
  choose : (Int) -> Unit,
  height? : Double = 28.0,
  loc~ : SourceLoc,
) -> @view.View {
  let n = if options.length() > 0 { options.length() } else { 1 }
  let inset = segment_track_inset.pt()
  let inner = concentric_radius(segment_track_radius, inset)
  @headless.radio_group(made_for=loc, parent, label, chosen, choose, fn(g, rg) {
    let at = @motion.Eased::new(@signals.untracked(chosen).to_double())
    g.reacts(chosen, fn(k) { at.go_by(g, k.to_double(), slide) })
    g
    .row(Is(true))
    .height(Is(Some(height)))
    .padding(Is(pad_all(segment_track_inset)))
    .radius(Is(segment_track_radius))
    .ground(By(fn() { palette().track }))
    |> ignore
    // (the thumb, laid over the track as wide as one option, slid by its own widths to where the choice is)
    g.box(fn(layer) {
      layer.over(Is(true)).row(Is(true)).padding(Is(pad_all(segment_track_inset))) |> ignore
      layer.box(fn(t) {
        t
        .width_share(Is(1.0 / n.to_double()))
        .height(Is(Some(height - 2.0 * inset)))
        .radius(Is(inner))
        .ground(By(fn() { palette().thumb }))
        .shadow(By(fn() { (2.0, 1.0, palette().shadow) }))
        .shift(By(fn() { (at.shown(layer), 0.0) }))
        |> ignore
      })
      |> ignore
    })
    |> ignore
    for i, o in options {
      let word = o
      let index = i
      rg.item(g, fn() { index }, fn() { word }, fn(it, item) {
        it
        .grow(Is(1.0))
        .basis(Is(Some(0.0)))
        .row(Is(true))
        .lines_up(Is(Some(Middle)))
        .lies_along(Is(Middle))
        .radius(Is(inner))
        .padding(Is(pad(S8, S0, S8, S0)))
        .focus_ring(By(fn() { Some((focus_ring_w, 0.0, palette().focus)) }))
        |> ignore
        text_node(it, fn() { word }, Ui, fn() { if item.chosen() { palette().ink } else { palette().muted } }, weight=weight_medium)
        |> ignore
      })
      |> ignore
    }
  })
}

///|
/// A switch in `parent`, on as `on` says, called `label`: a track 32 × 18, the accent's while on, its knob (14, 2 in
/// from its ends, round and so concentric with them) sprung to the end it is turned to; half seen while `disabled`.
/// Pressed, `turn` is told what it becomes. The node.
#callsite(autofill(loc))
pub fn switch_(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let (w, h, knob) = (32.0, 18.0, 14.0)
  let inset = (h - knob) / 2.0
  @headless.toggle(made_for=loc, parent, Switch, label, on, turn, disabled~, fn(b, _) {
    let across = @motion.eased_on(b, on, slide)
    let fill = @motion.eased_on(b, on, @motion.tween_to(duration=lit_ms, ease=ease_answer))
    b
    .width(Is(Some(w)))
    .height(Is(Some(h)))
    .shrink(Is(0.0))
    .radius(Is(h / 2.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .padding(Is((inset, 0.0, inset, 0.0)))
    .ground(By(fn() {
      let p = palette()
      mix(p.accent, fill.shown(b), if p.dark { p.edge } else { p.track })
    }))
    .alpha(By(fn() { if disabled() { 0.5 } else { 1.0 } }))
    .focus_ring(By(fn() { Some((focus_ring_w, 0.0, palette().focus)) }))
    |> ignore
    b.box(fn(k) {
      k
      .width(Is(Some(knob)))
      .height(Is(Some(knob)))
      .shrink(Is(0.0))
      .radius(Is(knob / 2.0))
      .offset(By(fn() { ((w - knob - 2.0 * inset) * across.shown(b), 0.0) }))
      .ground(By(fn() { palette().knob }))
      .shadow(By(fn() { (2.0, 1.0, palette().shadow) }))
      |> ignore
    })
    |> ignore
  })
}

///|
/// A checkbox in `parent`, ticked as `on` says, called `label`: 16 across, 4 round, the panel's ground in the control's
/// edge, the accent's with a tick three quarters of it across while ticked; half seen while `disabled`. Pressed, `turn`
/// is told what it becomes. The node.
#callsite(autofill(loc))
pub fn checkbox(
  parent : @view.View,
  on : () -> Bool,
  turn : (Bool) -> Unit,
  label : () -> String,
  disabled? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  let side = 16.0
  @headless.toggle(made_for=loc, parent, Checkbox, label, on, turn, disabled~, fn(b, _) {
    let fill = @motion.eased_on(b, on, @motion.tween_to(duration=lit_ms, ease=ease_answer))
    b
    .width(Is(Some(side)))
    .height(Is(Some(side)))
    .shrink(Is(0.0))
    .radius(Is(4.0))
    .row(Is(true))
    .lines_up(Is(Some(Middle)))
    .lies_along(Is(Middle))
    .ground(By(fn() {
      let p = palette()
      mix(p.accent, fill.shown(b), p.panel)
    }))
    .edge(By(fn() {
      let p = palette()
      (1.0, mix(alpha(p.accent, 0.0), fill.shown(b), p.edge))
    }))
    .alpha(By(fn() { if disabled() { 0.5 } else { 1.0 } }))
    .focus_ring(By(fn() { Some((focus_ring_w, 0.0, palette().focus)) }))
    |> ignore
    icon_node(b, Check, side * 0.75, fn() { alpha(palette().on_accent, fill.shown(b)) }, stroke=1.75) |> ignore
  })
}
