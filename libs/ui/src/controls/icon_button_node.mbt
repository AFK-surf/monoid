// The library's icon button (icon_button's) as a node of the window's tree, made once: round, `size` across, its icon
// in its middle; where the hand is on it (or the keyboard's focus shows) its ground the ink's hover tint as far as that
// has eased (dur_ms, eased out, from the moment it changed), its icon the ink's once that is past half, the muted ink's
// before; named by its label (read out a button, its tip shown by it); pressed as an old view's box with an id is.
// Its look over mbui's headless button (@headless.button), as button_node's.

///|
/// The icon button in `parent` showing icon `icon`, `size` across (round), its icon `icon_size`; named `label` (read
/// out, and its tip in `tips`); `press` done as it is pressed. While `disabled()`, faded (icon_button's: 0.45), taking
/// no press nor the focus. `linked`: its corner where that comes from, as it is worked out where it stands now (a bar's
/// buttons' at the window's corner: @sf.bar_keys_link; icon_button's `linked`), else round. `shortcut`: the action that
/// does what it does, its keys said in its tip after its label (icon_button's). `ink`: its icon's ink under the hand
/// (icon_button's `ink`), the words' where not said. `on`: what it says is so now (a folder starred, the preview shown:
/// icon_button's `on`), its ground the ink's lit tint and its icon the ink's at rest too. The node.
#callsite(autofill(loc))
pub fn icon_button_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : () -> Unit,
  tips? : TipLayer,
  size? : Double = icon_button_side,
  icon_size? : Double = 16.0,
  icon_now? : () -> String,
  disabled? : () -> Bool = fn() { false },
  linked? : () -> @ui.CornerOf?,
  shortcut? : String = "",
  ink? : () -> Int64,
  grounded? : Bool = true,
  on? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  icon_button_by(loc~, parent, icon, label, fn(_) { press() }, tips, size, icon_size, icon_now, disabled, linked?=linked, shortcut~, ink?, grounded~, on~)
}

///|
/// icon_button_node's button that opens what goes beside it (a menu under it): `open` given the button itself as it is
/// pressed, where it is placed then.
#callsite(autofill(loc))
pub fn icon_button_opens_node(
  parent : @view.View,
  icon : String,
  label : () -> String,
  open : (@view.View) -> Unit,
  size? : Double = icon_button_side,
  loc~ : SourceLoc,
) -> @view.View {
  icon_button_by(loc~, parent, icon, label, open, None, size, 16.0, None, fn() { false })
}

///|
/// icon_button_node's button, `press` given the button itself as it is pressed (what opens beside it: its menu).
#callsite(autofill(loc))
fn icon_button_by(
  parent : @view.View,
  icon : String,
  label : () -> String,
  press : (@view.View) -> Unit,
  tips : TipLayer?,
  size : Double,
  icon_size : Double,
  icon_now : (() -> String)?,
  disabled : () -> Bool,
  linked? : () -> @ui.CornerOf?,
  shortcut? : String = "",
  ink? : () -> Int64,
  hover_bg? : () -> Int64,
  grounded? : Bool = true,
  on? : () -> Bool = fn() { false },
  lit? : () -> Bool = fn() { false },
  loc~ : SourceLoc,
) -> @view.View {
  // (what it is to the hand, the keyboard and a screen reader is mbui's headless button's: read out a button called by
  // its label, pressed and focused only while not disabled, its tip held up by a finger's long press via Hold. Here,
  // its look)
  let tip : Ref[TipHand?] = Ref(None)
  // (its press's feel, told how big it is as the press goes down by the gesture: nothing read of its layout)
  let feel_of : Ref[@motion.PressFeel?] = Ref(None)
  @headless.button(
    made_for=loc,
    parent,
    label,
    press,
    disabled~,
    hold=@headless.Hold::new(
      @ui.touch_slop(),
      @ui.long_press_ms,
      fn() { @ui.pointing() is Finger },
      on_hold=fn() { if tip.val is Some(h) { (h.hold)() } },
      on_lift=fn() { if tip.val is Some(h) { (h.lift)() } },
      on_cancel=fn() { if tip.val is Some(h) { (h.cancel)() } },
      down=fn(d) { if feel_of.val is Some(f) { f.down(d) } },
    ),
    fn(v, b) {
      // (the hand on it: a pointer over it, a finger or the pointer held on it; the keyboard's focus shown on it. Pressed,
      // sunk a little and springing back as it is let go (@motion.press_feel); pressed where it was lit already (a
      // mouse's click under the pointer), its tint a step deeper too, where the hover alone had nothing left to show)
      let is_lit = fn() { b.focus_shown() || b.hovered() || b.pressed() || (!disabled() && lit()) }
      let hand = @motion.NodeWay::new(0.0)
      v.reacts(is_lit, fn(on) { hand.go_ms(v, if on { 1.0 } else { 0.0 }, dur_ms) })
      let in_pill = @glass.in_liquid_pill(v)
      let press_more = if in_pill { 0.45 } else { icon_button_press_more }
      bind_pill_press(v)
      let feel = @motion.press_feel(v, live=fn() { !disabled() }, hovers=false)
      feel_of.val = Some(feel)
      let deeper = lit_before_press(v, b, hand)
      let tint = fn() {
        // (its press's way followed whether or not it deepens: what deepens it is told as it goes down)
        let pressed_now = dmin(1.0, dmax(0.0, feel.pressed_on(v)))
        let pr = if deeper.val { pressed_now } else { 0.0 }
        if pr <= 0.0 {
          hand.shown(v)
        } else {
          hand.shown(v) * (1.0 + press_more * pr)
        }
      }
      let pad = (size - icon_size) / 2.0
      if in_pill {
        v.focus_ring(Is(Some((-1.5, -1.5, 0L)))) |> ignore
      } else {
        v.focus_ring_theme() |> ignore
      }
      v
      .width(Is(Some(size)))
      .height(Is(Some(size)))
      .padding(Is((pad, pad, pad, pad)))
      // (none where it has no ground: nothing of it is round to stand in a corner)
      .radius(
        match linked {
          _ if !grounded => Is(0.0)
          Some(f) =>
            By(fn() {
              match f() {
                Some(link) => link.radius(@ui.tree_corner_roots_now())
                None => size / 2.0
              }
            })
          None => Is(size / 2.0)
        },
      )
      .alpha(By(fn() { if disabled() { icon_button_disabled_alpha } else { 1.0 } }))
      // (the page's hover, as a tint of the ink it sits with: icon_button's; none where it is `grounded=false`, the
      // hand shown by its icon's ink alone: one at a row's end in a card's corner, where no circle is concentric with it)
      |> ignore
      // (its icon the ink once the hand's ground is half way there: `ink`, where said (a star lit while starred, quiet
      // while not: icon_button's `ink`), else the words'; the muted ink before; the ink at rest while it is `on`)
      let lit_ink = match ink {
        Some(f) => f
        None => fn() { theme().p.text }
      }
      // (while it is `on`, the ink's lit tint at rest, as icon_button's: else none where it is `grounded=false`)
      v.ground(By(fn() {
        if !grounded {
          0L
        } else {
          match hover_bg {
            Some(bg_fn) =>
              if on() {
                bg_fn()
              } else {
                alpha(bg_fn(), dmin(1.0, tint()))
              }
            None =>
              if in_pill {
                let dark = theme().dark
                match ink {
                  Some(_) => {
                    let base = lit_ink()
                    if on() {
                      alpha(base, if dark { 0.29 } else { 0.22 })
                    } else {
                      alpha(base, (if dark { 0.26 } else { 0.20 }) * tint())
                    }
                  }
                  None => {
                    let base = if dark { 0xFFFFFFFFL } else { 0x000000FFL }
                    if on() {
                      alpha(base, if dark { 0.18 } else { 0.12 })
                    } else {
                      alpha(base, (if dark { 0.16 } else { 0.11 }) * tint())
                    }
                  }
                }
              } else if on() {
                alpha(lit_ink(), 0.08)
              } else {
                alpha(lit_ink(), 0.065 * tint())
              }
          }
        }
      }))
      |> ignore
      icon_node(v, icon, icon_size, By(fn() { if on() || hand.shown(v) > 0.5 { lit_ink() } else { theme().p.muted } }), name_now?=icon_now, weighed=true)
      |> ignore
      tip.val = match tips {
        Some(t) => Some(tip_node(t, v, label, side=Bottom, shortcut~))
        None => None
      }
    },
  )
}

///|
/// How far a disabled icon button is seen (icon_button's `disabled`).
let icon_button_disabled_alpha : Double = 0.45

///|
/// How much deeper an icon button's tint is pressed than under the hand alone, a share of that tint.
let icon_button_press_more : Double = 0.6
