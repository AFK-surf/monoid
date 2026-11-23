// Range slider: dual-thumb range selector enforcing `min <= low <= high - min_gap` and `low + min_gap <= high <= max`.
// Exposes two independent focusable `Role::Slider` thumbs (`RangeSlider::thumb`) with LTR/RTL arrow keys,
// PageUp/PageDown, Home/End, screen-reader Increment/Decrement, and track dragging that automatically picks the nearest
// thumb. Draws nothing and lays out nothing.

///|
let rs_key_left : Int = 3

///|
let rs_key_right : Int = 4

///|
let rs_key_up : Int = 5

///|
let rs_key_down : Int = 6

///|
let rs_key_home : Int = 8

///|
let rs_key_end : Int = 9

///|
let rs_key_page_up : Int = 15

///|
let rs_key_page_down : Int = 16

///|
/// Identifies one of the two thumbs of a `RangeSlider`.
#derive(Eq, Debug)
pub(all) enum RangeThumb {
  Low
  High
}

///|
/// A dual-thumb range slider as its look reads it and creates its thumbs by (`RangeSlider::thumb`).
pub struct RangeSlider {
  priv now : () -> (Double, Double)
  priv min_ : Double
  priv max_ : Double
  priv step_ : Double
  priv step_by : Double
  priv min_gap_ : Double
  priv rtl_ : Bool
  priv off : () -> Bool
  priv text_of : (Double) -> String
  priv on_change_ : (Double, Double) -> Unit
  priv dragging_ : @signals.Signal[RangeThumb?]
  priv low_node : Ref[@view.View?]
  priv high_node : Ref[@view.View?]
}

///|
/// State of one thumb of a `RangeSlider`, as its look reads it.
pub struct RangeThumbState {
  priv slider : RangeSlider
  priv which_ : RangeThumb
  priv node : @view.View
}

///|
fn rs_norm(vals : (Double, Double), min : Double, max : Double, gap : Double) -> (Double, Double) {
  let lo = slider_clamp(vals.0, min, max - gap)
  let hi = slider_clamp(vals.1, lo + gap, max)
  (lo, hi)
}

///|
fn rs_snap_low(target : Double, min : Double, hi_limit : Double, step : Double) -> Double {
  let hi = if hi_limit < min { min } else { hi_limit }
  let c = slider_clamp(target, min, hi)
  if step > 0.0 {
    let k = ((c - min) / step).round()
    let snapped = min + k * step
    if snapped > hi {
      let kf = ((hi - min) / step).floor()
      slider_clamp(min + kf * step, min, hi)
    } else {
      slider_clamp(snapped, min, hi)
    }
  } else {
    c
  }
}

///|
fn rs_snap_high(target : Double, lo_limit : Double, min : Double, max : Double, step : Double) -> Double {
  let lo = if lo_limit > max { max } else { lo_limit }
  let c = slider_clamp(target, lo, max)
  if step > 0.0 {
    let k = ((c - min) / step).round()
    let snapped = min + k * step
    if snapped < lo {
      let kc = ((lo - min) / step).ceil()
      slider_clamp(min + kc * step, lo, max)
    } else {
      slider_clamp(snapped, lo, max)
    }
  } else {
    c
  }
}

///|
/// Clamped `(low, high)` values satisfying `min <= low <= high - min_gap` and `low + min_gap <= high <= max`.
pub fn RangeSlider::values(self : RangeSlider) -> (Double, Double) {
  rs_norm((self.now)(), self.min_, self.max_, self.min_gap_)
}

///|
/// Clamped low thumb value.
pub fn RangeSlider::low(self : RangeSlider) -> Double {
  self.values().0
}

///|
/// Clamped high thumb value.
pub fn RangeSlider::high(self : RangeSlider) -> Double {
  self.values().1
}

///|
fn RangeSlider::part_of(self : RangeSlider, v : Double) -> Double {
  let span = self.max_ - self.min_
  if span <= 0.0 {
    0.0
  } else {
    slider_clamp((v - self.min_) / span, 0.0, 1.0)
  }
}

///|
/// Normalized low thumb position in `[0.0, 1.0]`.
pub fn RangeSlider::low_part(self : RangeSlider) -> Double {
  self.part_of(self.low())
}

///|
/// Normalized high thumb position in `[0.0, 1.0]`.
pub fn RangeSlider::high_part(self : RangeSlider) -> Double {
  self.part_of(self.high())
}

///|
/// Whether the range slider is disabled.
pub fn RangeSlider::disabled(self : RangeSlider) -> Bool {
  (self.off)()
}

///|
/// Which thumb is currently being dragged along the track, or `None`. Followed.
pub fn RangeSlider::dragging(self : RangeSlider) -> RangeThumb? {
  self.dragging_.get()
}

///|
fn RangeSlider::move_thumb(self : RangeSlider, which : RangeThumb, target : Double) -> Unit {
  if @signals.untracked(self.off) {
    return
  }
  let (cur_lo, cur_hi) = rs_norm(@signals.untracked(self.now), self.min_, self.max_, self.min_gap_)
  match which {
    Low => {
      let next_lo = rs_snap_low(target, self.min_, cur_hi - self.min_gap_, self.step_)
      if next_lo != cur_lo {
        (self.on_change_)(next_lo, cur_hi)
      }
    }
    High => {
      let next_hi = rs_snap_high(target, cur_lo + self.min_gap_, self.min_, self.max_, self.step_)
      if next_hi != cur_hi {
        (self.on_change_)(cur_lo, next_hi)
      }
    }
  }
}

///|
/// Which thumb this state belongs to.
pub fn RangeThumbState::which(self : RangeThumbState) -> RangeThumb {
  self.which_
}

///|
/// Current value of this thumb.
pub fn RangeThumbState::value(self : RangeThumbState) -> Double {
  match self.which_ {
    Low => self.slider.low()
    High => self.slider.high()
  }
}

///|
/// Normalized position of this thumb in `[0.0, 1.0]`.
pub fn RangeThumbState::part(self : RangeThumbState) -> Double {
  self.slider.part_of(self.value())
}

///|
/// Whether the slider is disabled.
pub fn RangeThumbState::disabled(self : RangeThumbState) -> Bool {
  (self.slider.off)()
}

///|
/// Whether a finger or pointer is held on this thumb (or dragging it via the track).
pub fn RangeThumbState::pressed(self : RangeThumbState) -> Bool {
  self.node.pressed() || self.slider.dragging_.get() == Some(self.which_)
}

///|
/// Whether a pointer rests over this thumb.
pub fn RangeThumbState::hovered(self : RangeThumbState) -> Bool {
  self.node.pointed()
}

///|
/// Whether this thumb has keyboard focus.
pub fn RangeThumbState::focused(self : RangeThumbState) -> Bool {
  self.node.focused()
}

///|
/// Whether this thumb has keyboard focus and that focus ring should show.
pub fn RangeThumbState::focus_shown(self : RangeThumbState) -> Bool {
  self.node.focus_shown()
}

///|
/// A dual-thumb range slider in `parent`, called `label`, over `[min, max]` in steps of `step`, enforcing at least
/// `min_gap` between `low` and `high`. Dragging the track selects the nearest thumb and updates it via `on_change`.
/// Mount the two thumbs inside `look` using `RangeSlider::thumb`.
#callsite(autofill(loc))
pub fn range_slider(
  parent : @view.View,
  label : () -> String,
  values : () -> (Double, Double),
  min~ : Double,
  max~ : Double,
  step~ : Double,
  on_change : (Double, Double) -> Unit,
  look : (@view.View, RangeSlider) -> Unit,
  min_gap? : Double = 0.0,
  rtl? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  value_text? : (Double) -> String,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let lo_bound = if min <= max { min } else { max }
  let hi_bound = if min <= max { max } else { min }
  let span = hi_bound - lo_bound
  let gap = if min_gap < 0.0 { 0.0 } else if min_gap > span { span } else { min_gap }
  let step_by = if step > 0.0 { step } else { span / 100.0 }
  let whole = step >= 1.0 && step == step.round() && lo_bound == lo_bound.round()
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
  let rs : RangeSlider = {
    now: values,
    min_: lo_bound,
    max_: hi_bound,
    step_: step,
    step_by,
    min_gap_: gap,
    rtl_: rtl,
    off: disabled,
    text_of,
    on_change_: on_change,
    dragging_: @signals.signal(None),
    low_node: Ref(None),
    high_node: Ref(None),
  }
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let able = fn() { !disabled() }
    look(v, rs)
    let value_at = fn(d : @view.Drag) -> Double {
      if d.w <= 0.0 {
        lo_bound
      } else {
        let raw = slider_clamp(d.x / d.w, 0.0, 1.0)
        let frac = if rtl { 1.0 - raw } else { raw }
        lo_bound + frac * span
      }
    }
    v
    .presses(By(able))
    .says(By(fn() { Some(@view.said(Group, label=label())) }))
    .on_drag(fn(d) {
      if disabled() {
        rs.dragging_.set(None)
        return
      }
      match d.kind {
        Down => {
          let target = value_at(d)
          let (cur_lo, cur_hi) = rs_norm(@signals.untracked(values), lo_bound, hi_bound, gap)
          let d_lo = (target - cur_lo).abs()
          let d_hi = (target - cur_hi).abs()
          let picked : RangeThumb = if d_lo < d_hi {
            Low
          } else if d_hi < d_lo {
            High
          } else if target >= cur_hi {
            High
          } else {
            Low
          }
          rs.dragging_.set(Some(picked))
          rs.move_thumb(picked, target)
          let thumb_node = match picked {
            Low => rs.low_node.val
            High => rs.high_node.val
          }
          if thumb_node is Some(tn) && tn.alive() {
            tn.ask_focus() |> ignore
          }
        }
        Moved =>
          if rs.dragging_.untracked() is Some(which) {
            rs.move_thumb(which, value_at(d))
          }
        Up | Off => rs.dragging_.set(None)
      }
    }, captures=true)
    |> ignore
  })
}

///|
/// Mount one focusable `Role::Slider` thumb (`Low` or `High`) of `self` in `parent`.
/// Supports LTR/RTL arrow keys, PageUp/PageDown (10 steps), Home/End (within its allowed sub-range), and screen-reader
/// `Increment`/`Decrement`.
#callsite(autofill(loc))
pub fn RangeSlider::thumb(
  self : RangeSlider,
  parent : @view.View,
  which : RangeThumb,
  label : () -> String,
  look : (@view.View, RangeThumbState) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    let able = fn() { !(self.off)() }
    match which {
      Low => self.low_node.val = Some(v)
      High => self.high_node.val = Some(v)
    }
    v.owns(fn() {
      match which {
        Low => if self.low_node.val is Some(n) && n.id() == v.id() { self.low_node.val = None }
        High => if self.high_node.val is Some(n) && n.id() == v.id() { self.high_node.val = None }
      }
    })
    |> ignore
    look(v, { slider: self, which_: which, node: v })
    v
    .presses(By(able))
    .focusable(By(able))
    .says(By(fn() {
      let (lo, hi) = self.values()
      let (r_min, val, r_max) = match which {
        Low => (self.min_, lo, hi - self.min_gap_)
        High => (lo + self.min_gap_, hi, self.max_)
      }
      let acts : Array[@view.Action] = if (self.off)() { [] } else { [Increment, Decrement] }
      Some(@view.said(Slider, label=label(), value=(self.text_of)(val), range=(r_min, val, r_max), actions=acts))
    }))
    .on_step(fn(by) {
      if !(self.off)() {
        let (lo, hi) = rs_norm(@signals.untracked(self.now), self.min_, self.max_, self.min_gap_)
        let cur = match which {
          Low => lo
          High => hi
        }
        self.move_thumb(which, cur + by.to_double() * self.step_by)
      }
    })
    .on_key(fn(k) {
      if (self.off)() || !v.focused() || k.mods != 0 {
        return false
      }
      let (lo, hi) = rs_norm(@signals.untracked(self.now), self.min_, self.max_, self.min_gap_)
      let cur = match which {
        Low => lo
        High => hi
      }
      let dec_h = if self.rtl_ { rs_key_right } else { rs_key_left }
      let inc_h = if self.rtl_ { rs_key_left } else { rs_key_right }
      let target : Double? = if k.code == dec_h || k.code == rs_key_down {
        Some(cur - self.step_by)
      } else if k.code == inc_h || k.code == rs_key_up {
        Some(cur + self.step_by)
      } else if k.code == rs_key_page_up {
        Some(cur + self.step_by * 10.0)
      } else if k.code == rs_key_page_down {
        Some(cur - self.step_by * 10.0)
      } else if k.code == rs_key_home {
        Some(match which {
          Low => self.min_
          High => lo + self.min_gap_
        })
      } else if k.code == rs_key_end {
        Some(match which {
          Low => hi - self.min_gap_
          High => self.max_
        })
      } else {
        None
      }
      match target {
        Some(t) => {
          self.move_thumb(which, t)
          true
        }
        None => false
      }
    })
    |> ignore
  })
}
