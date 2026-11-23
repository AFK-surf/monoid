// The slider: a value along a range (`min` … `max`, stepped by `step`), read out a slider called by its label with its
// range, value text, and Increment / Decrement actions while enabled. Moved by dragging along it (with `thumb_room`
// reserved for the knob's ends), by ←/↓ and →/↑ (a step), Page Down and Page Up (ten steps) or Home/End while it
// has the keyboard's focus, and by a screen
// reader's step (View::on_step), each telling `change` the new stepped value when it differs from what `value` says
// then. Controlled (headless.mbt, State): `value` is its caller's; nothing of the value is kept here.

///|
/// A slider as its look reads it: each a reading, followed where a binding reads it.
pub struct Slider {
  priv node : @view.View
  priv now : () -> Double
  priv min : Double
  priv max : Double
  priv off : () -> Bool
  priv hand : Ref[Bool]
}

///|
/// Its value now (clamped to its range, as its caller says).
pub fn Slider::value(self : Slider) -> Double {
  slider_clamp((self.now)(), self.min, self.max)
}

///|
/// How far along its range (`0.0` at `min` … `1.0` at `max`) its value is now.
pub fn Slider::part(self : Slider) -> Double {
  let span = self.max - self.min
  if span <= 0.0 {
    0.0
  } else {
    slider_clamp(((self.now)() - self.min) / span, 0.0, 1.0)
  }
}

///|
/// Whether it is disabled: it takes no drag, key or focus (as its caller says).
pub fn Slider::disabled(self : Slider) -> Bool {
  (self.off)()
}

///|
/// Whether a finger or the pointer is held on it now (View::pressed).
pub fn Slider::pressed(self : Slider) -> Bool {
  self.node.pressed()
}

///|
/// Whether what moved its value last was the hand on it (a press along it, a drag), not a key or a screen reader's
/// step: said before `change` is told, so a look reading it as the value changes follows the hand at once and takes a
/// step its own way (a knob gliding to End).
pub fn Slider::in_hand(self : Slider) -> Bool {
  self.hand.val
}

///|
/// Whether a pointer rests over it now (View::pointed).
pub fn Slider::hovered(self : Slider) -> Bool {
  self.node.pointed()
}

///|
/// Whether it has the keyboard's focus and that shows (it came by the keyboard: View::focus_shown).
pub fn Slider::focus_shown(self : Slider) -> Bool {
  self.node.focus_shown()
}

///|
fn slider_clamp(x : Double, lo : Double, hi : Double) -> Double {
  if x < lo {
    lo
  } else if x > hi {
    hi
  } else {
    x
  }
}

///|
/// `x` held between `min` and `max`, on the nearest step from `min` (`step > 0`; else only held).
pub fn slider_snap(x : Double, min : Double, max : Double, step : Double) -> Double {
  let clamped = slider_clamp(x, min, max)
  if step > 0.0 {
    let k = ((clamped - min) / step).round()
    slider_clamp(min + k * step, min, max)
  } else {
    clamped
  }
}

///|
/// A slider in `parent`, called `label`, at `value()` along `min` … `max` in steps of `step` (`> 0`: snapped to the
/// nearest step from `min`); `change` told the new value when a drag along it (`thumb_room` reserved for the knob's
/// ends), an arrow / Page Up / Page Down / Home / End key with the focus on it, or a screen reader's step moves it
/// to another value;
/// `disabled` while it cannot be moved; `value_text` how its value is read out (by default its integer where `step` is
/// a whole number, else its number). `drag`: what a finger or the pointer does on it, given each of its events in
/// place of moving it to where it is (a control whose press and whose drag differ: a player's timeline, a tap there
/// at once, a drag through what it plays); its keys and a screen reader's steps as ever. `vertical`: it runs up its
/// height, `min` at its foot, dragged along it (the keys as ever, ↑ and → more). `look` is run once as it is made,
/// given its node and what it reads of it. The node.
#callsite(autofill(loc))
pub fn slider(
  parent : @view.View,
  label : () -> String,
  value : () -> Double,
  min~ : Double,
  max~ : Double,
  step~ : Double,
  change : (Double) -> Unit,
  look : (@view.View, Slider) -> Unit,
  thumb_room? : Double = 0.0,
  disabled? : () -> Bool = fn() { false },
  value_text? : (Double) -> String,
  drag? : (@view.Drag) -> Unit,
  vertical? : Bool = false,
  rtl? : Bool = false,
  on_commit? : (Double) -> Unit,
  focus_on_press? : Bool = true,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let step_by = if step > 0.0 { step } else { (max - min) / 100.0 }
  let whole = step >= 1.0 && step == step.round() && min == min.round()
  let text_of = match value_text {
    Some(f) => f
    None =>
      fn(v : Double) {
        if whole {
          v.round().to_int().to_string()
        } else {
          v.to_string()
        }
      }
  }
  let go = fn(target : Double) {
    let next = slider_snap(target, min, max, step)
    let cur = slider_snap(value(), min, max, step)
    if next != cur {
      change(next)
    }
  }
  let commit = fn() {
    if on_commit is Some(f) {
      f(slider_snap(@signals.untracked(value), min, max, step))
    }
  }
  let hand = Ref(false)
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let able = fn() { !disabled() }
    look(v, { node: v, now: value, min, max, off: disabled, hand })
    v
    .presses(By(able))
    .focusable(By(able))
    .says(By(fn() {
      let now = slider_snap(value(), min, max, step)
      let acts : Array[@view.Action] = if disabled() { [] } else { [Increment, Decrement] }
      Some(@view.said(Slider, label=label(), value=text_of(now), range=(min, now, max), actions=acts))
    }))
    .on_step(fn(by) {
      if !disabled() {
        hand.val = false
        go(value() + by.to_double() * step_by)
        commit()
      }
    })
    .on_drag(fn(d) {
      hand.val = true
      if !disabled() {
        if d.kind == Down && focus_on_press {
          v.ask_focus() |> ignore
        }
        if drag is Some(f) {
          f(d)
          if d.kind == Up || d.kind == Off {
            commit()
          }
        } else {
          match d.kind {
            // (along its width, `min` at its left (or right when `rtl`); `vertical`, up its height, `min` at its foot)
            Down | Moved if !vertical && d.w > thumb_room => {
              let raw = slider_clamp((d.x - thumb_room / 2.0) / (d.w - thumb_room), 0.0, 1.0)
              let frac = if rtl { 1.0 - raw } else { raw }
              go(min + frac * (max - min))
            }
            Down | Moved if vertical && d.h > thumb_room => {
              let frac = slider_clamp(1.0 - (d.y - thumb_room / 2.0) / (d.h - thumb_room), 0.0, 1.0)
              go(min + frac * (max - min))
            }
            Up | Off => commit()
            _ => ()
          }
        }
      }
    }, captures=true)
    .on_key(fn(k) {
      if disabled() || !v.focused() || k.mods != 0 {
        return false
      }
      let cur = value()
      // 3 Left, 4 Right, 5 Up, 6 Down, 8 Home, 9 End, 15 Page Up, 16 Page Down (ui/desktop.mbt key_code_*): a page ten
      // steps, as kit's slider and Radix's; horizontal rtl flips Left/Right
      let flip_h = !vertical && rtl
      let dec_h = if flip_h { 4 } else { 3 }
      let inc_h = if flip_h { 3 } else { 4 }
      let to = if k.code == dec_h || k.code == 6 {
        Some(cur - step_by)
      } else if k.code == inc_h || k.code == 5 {
        Some(cur + step_by)
      } else if k.code == 15 {
        Some(cur + step_by * 10.0)
      } else if k.code == 16 {
        Some(cur - step_by * 10.0)
      } else if k.code == 8 {
        Some(min)
      } else if k.code == 9 {
        Some(max)
      } else {
        None
      }
      match to {
        Some(t) => {
          hand.val = false
          go(t)
          commit()
          true
        }
        None => false
      }
    })
    |> ignore
  })
}
