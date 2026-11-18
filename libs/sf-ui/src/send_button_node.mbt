// The composer's send (the old composer's send_button) as a node of the window's tree, made once: round, the theme's
// round side across; while what is written can go, the words' ink with the canvas's arrow (a step lighter under the
// hand), while it cannot, the words' ink faint over the raised ground with the raised arrow; going from one to the other
// as a control answers (dur_ms, eased out, from the moment it changed); a turning ring in the arrow's place while a
// new chat is made for what was sent. Its look over mbui's headless button (@headless.button), as icon_button_node's.

///|
/// Send in `parent`, named `label` (read out, and its tip in `tips`, over it); `press` done as it is pressed while
/// `ready()`; while it is not, read out disabled and taking no press nor the focus, a press on it shaking it across where it is
/// drawn (refused_shake). While `starting()`, a ring turning
/// in its middle. `icon_now` changes the arrow where the same control can do another action. The node.
#callsite(autofill(loc))
pub fn send_button_node(
  parent : @view.View,
  label : () -> String,
  ready : () -> Bool,
  starting : () -> Bool,
  press : () -> Unit,
  tips? : TipLayer,
  icon_now? : () -> String = fn() { "arrow-up" },
  loc~ : SourceLoc,
) -> @view.View {
  let tip : Ref[TipHand?] = Ref(None)
  @headless.button(
    made_for=loc,
    parent,
    label,
    fn(_) { press() },
    disabled=fn() { !ready() },
    hold=@headless.Hold::new(
      @ui.touch_slop(),
      @ui.long_press_ms,
      fn() { @ui.pointing() is Finger },
      on_hold=fn() { if tip.val is Some(h) { (h.hold)() } },
      on_lift=fn() { if tip.val is Some(h) { (h.lift)() } },
      on_cancel=fn() { if tip.val is Some(h) { (h.cancel)() } },
    ),
    fn(v, b) {
      let side = @signals.untracked(fn() { theme().round.side })
      // (able: whether it can go; lit: the hand on it while it can; each eased as a control answers, from its change)
      let able = @motion.NodeWay::new(if @signals.untracked(ready) { 1.0 } else { 0.0 })
      v.reacts(ready, fn(on) { able.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
      let lit = @motion.NodeWay::new(0.0)
      v.reacts(fn() { ready() && (b.focus_shown() || b.hovered() || b.pressed()) }, fn(on) {
        lit.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms)
      })
      v
      .focus_ring_theme()
      .width(Is(Some(side)))
      .height(Is(Some(side)))
      .min_width(Is(Some(side)))
      .radius(Is(side / 2.0))
      .row(Is(true))
      .lines_up(Is(Some(Middle)))
      .lies_along(Is(Middle))
      .ground(By(fn() { send_ground(able.shown(v), lit.shown(v)) }))
      |> ignore
      // (pressed while what is written cannot go (no new chat being made for it), shaken where it is drawn:
      // refused_shake)
      refused_shake(v, fn() { !ready() && !starting() })
      v.pick(starting, fn(i, turning) {
        if turning {
          spinner_node(i, size=theme().round.glyph) |> ignore
        } else {
          icon_node(i, "arrow-up", theme().round.glyph, By(fn() {
            let p = theme().p
            mix(p.canvas, able.shown(v), p.raised)
          }), name_now=icon_now)
          |> ignore
        }
      })
      tip.val = match tips {
        Some(t) => Some(tip_node(t, v, label, side=Top))
        None => None
      }
    },
  )
}

///|
/// Send's ground, `able` of the way from cannot go to can, `lit` of the way the hand has come on it: the words' ink
/// (send_hot of it over the canvas under the hand) where it can go, send_off of it over the raised ground where not.
fn send_ground(able : Double, lit : Double) -> Int64 {
  let p = theme().p
  let on = mix(mix(p.text, send_hot, p.canvas), lit, p.text)
  mix(on, able, over(p.raised, alpha(p.text, send_off)))
}

///|
/// Send not ready: the words' ink at 18% over the raised ground; under the hand: the words' ink at 82% over the canvas
/// (the old composer's send_off, send_hot).
let send_off : Double = 0.18

///|
let send_hot : Double = 0.82
