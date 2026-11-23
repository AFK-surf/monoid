// Number input: numeric stepper state machine with clamping, precision rounding, text parsing, keyboard stepping
// (↑/↓/PageUp/PageDown/Home/End), screen-reader Increment/Decrement, and press-and-hold auto-repeating stepper buttons
// built on `repeat_hold`. Draws nothing and lays out nothing.

///|
let ni_key_up : Int = 5

///|
let ni_key_down : Int = 6

///|
let ni_key_home : Int = 8

///|
let ni_key_end : Int = 9

///|
let ni_key_page_up : Int = 15

///|
let ni_key_page_down : Int = 16

///|
/// Headless numeric stepper controller over a controlled `Double` value.
pub struct NumberInput {
  priv value_ : () -> Double
  priv on_change_ : (Double) -> Unit
  priv min_ : Double
  priv max_ : Double
  priv step_ : Double
  priv large_step_ : Double
  priv precision_ : Int
  priv disabled_ : () -> Bool
  priv read_only_ : () -> Bool
}

///|
/// Create a `NumberInput` controller with bounds `[min, max]`, step sizes, decimal `precision`, and `disabled` /
/// `read_only` guards.
pub fn NumberInput::new(
  value : () -> Double,
  on_change : (Double) -> Unit,
  min? : Double = -1.0e15,
  max? : Double = 1.0e15,
  step? : Double = 1.0,
  large_step? : Double = 10.0,
  precision? : Int = 0,
  disabled? : () -> Bool = fn() { false },
  read_only? : () -> Bool = fn() { false },
) -> NumberInput {
  let lo = if min <= max { min } else { max }
  let hi = if min <= max { max } else { min }
  {
    value_: value,
    on_change_: on_change,
    min_: lo,
    max_: hi,
    step_: if step > 0.0 { step } else { 1.0 },
    large_step_: if large_step > 0.0 { large_step } else { 10.0 },
    precision_: if precision < 0 { 0 } else if precision > 10 { 10 } else { precision },
    disabled_: disabled,
    read_only_: read_only,
  }
}

///|
fn ni_pow10(p : Int) -> Double {
  let mut r = 1.0
  for _ in 0..<p {
    r = r * 10.0
  }
  r
}

///|
fn ni_round(x : Double, precision : Int) -> Double {
  let s = ni_pow10(precision)
  let r = (x * s).round() / s
  if r == 0.0 { 0.0 } else { r }
}

///|
fn NumberInput::normalize(self : NumberInput, x : Double) -> Double {
  let clamped = slider_clamp(x, self.min_, self.max_)
  let rounded = ni_round(clamped, self.precision_)
  slider_clamp(rounded, self.min_, self.max_)
}

///|
/// Current clamped and rounded numeric value.
pub fn NumberInput::value(self : NumberInput) -> Double {
  self.normalize((self.value_)())
}

///|
/// Whether the input is disabled.
pub fn NumberInput::disabled(self : NumberInput) -> Bool {
  (self.disabled_)()
}

///|
/// Whether the input is read-only.
pub fn NumberInput::read_only(self : NumberInput) -> Bool {
  (self.read_only_)()
}

///|
/// Whether stepping upward is currently permitted.
pub fn NumberInput::can_increment(self : NumberInput) -> Bool {
  !(self.disabled_)() && !(self.read_only_)() && self.value() < self.max_
}

///|
/// Whether stepping downward is currently permitted.
pub fn NumberInput::can_decrement(self : NumberInput) -> Bool {
  !(self.disabled_)() && !(self.read_only_)() && self.value() > self.min_
}

///|
/// Format the current value to a fixed-precision decimal string according to `precision`.
pub fn NumberInput::formatted(self : NumberInput) -> String {
  let v = self.value()
  let neg = v < 0.0
  let abs_v = if neg { -v } else { v }
  let prefix = if neg { "-" } else { "" }
  if self.precision_ == 0 {
    let n = abs_v.round().to_int64()
    if n == 0L {
      "0"
    } else {
      prefix + n.to_string()
    }
  } else {
    let scale = ni_pow10(self.precision_)
    let scaled = (abs_v * scale).round().to_int64()
    let scale_i = scale.round().to_int64()
    let whole = scaled / scale_i
    let frac = scaled % scale_i
    let frac_raw = frac.to_string()
    let pad = self.precision_ - frac_raw.length()
    let b = StringBuilder()
    if scaled != 0L {
      b.write_string(prefix)
    }
    b.write_string(whole.to_string())
    b.write_char('.')
    for _ in 0..<pad {
      b.write_char('0')
    }
    b.write_string(frac_raw)
    b.to_string()
  }
}

///|
fn NumberInput::set_to(self : NumberInput, target : Double) -> Unit {
  if @signals.untracked(self.disabled_) || @signals.untracked(self.read_only_) {
    return
  }
  let cur = self.normalize(@signals.untracked(self.value_))
  let next = self.normalize(target)
  if next != cur {
    (self.on_change_)(next)
  }
}

///|
/// Step the value up by `step` (or `large_step` when `large` is true).
pub fn NumberInput::step_up(self : NumberInput, large? : Bool = false) -> Unit {
  let delta = if large { self.large_step_ } else { self.step_ }
  self.set_to(@signals.untracked(self.value_) + delta)
}

///|
/// Step the value down by `step` (or `large_step` when `large` is true).
pub fn NumberInput::step_down(self : NumberInput, large? : Bool = false) -> Unit {
  let delta = if large { self.large_step_ } else { self.step_ }
  self.set_to(@signals.untracked(self.value_) - delta)
}

///|
/// Jump the value to `min`.
pub fn NumberInput::to_min(self : NumberInput) -> Unit {
  self.set_to(self.min_)
}

///|
/// Jump the value to `max`.
pub fn NumberInput::to_max(self : NumberInput) -> Unit {
  self.set_to(self.max_)
}

///|
/// Parse a decimal/scientific number string without external package dependencies.
fn ni_parse_double(raw : String) -> Double? {
  let len = raw.length()
  let mut i = 0
  while i < len {
    let cu = raw.code_unit_at(i).to_int()
    if cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D {
      i = i + 1
    } else {
      break
    }
  }
  let mut end = len
  while end > i {
    let cu = raw.code_unit_at(end - 1).to_int()
    if cu == 0x20 || cu == 0x09 || cu == 0x0A || cu == 0x0D {
      end = end - 1
    } else {
      break
    }
  }
  if i >= end {
    return None
  }
  let mut neg = false
  let first = raw.code_unit_at(i).to_int()
  if first == 0x2D {
    neg = true
    i = i + 1
  } else if first == 0x2B {
    i = i + 1
  }
  let mut int_part = 0.0
  let mut frac_part = 0.0
  let mut frac_scale = 1.0
  let mut digits = 0
  while i < end {
    let cu = raw.code_unit_at(i).to_int()
    if cu >= 0x30 && cu <= 0x39 {
      int_part = int_part * 10.0 + (cu - 0x30).to_double()
      digits = digits + 1
      i = i + 1
    } else {
      break
    }
  }
  if i < end && raw.code_unit_at(i).to_int() == 0x2E {
    i = i + 1
    while i < end {
      let cu = raw.code_unit_at(i).to_int()
      if cu >= 0x30 && cu <= 0x39 {
        frac_scale = frac_scale * 10.0
        frac_part = frac_part + (cu - 0x30).to_double() / frac_scale
        digits = digits + 1
        i = i + 1
      } else {
        break
      }
    }
  }
  if digits == 0 {
    return None
  }
  let mut exp_val = 0
  if i < end {
    let cu = raw.code_unit_at(i).to_int()
    if cu == 0x65 || cu == 0x45 {
      i = i + 1
      let mut exp_neg = false
      if i < end {
        let sc = raw.code_unit_at(i).to_int()
        if sc == 0x2D {
          exp_neg = true
          i = i + 1
        } else if sc == 0x2B {
          i = i + 1
        }
      }
      let mut exp_digits = 0
      while i < end {
        let dc = raw.code_unit_at(i).to_int()
        if dc >= 0x30 && dc <= 0x39 {
          if exp_val < 1000 {
            exp_val = exp_val * 10 + (dc - 0x30)
          }
          exp_digits = exp_digits + 1
          i = i + 1
        } else {
          break
        }
      }
      if exp_digits == 0 {
        return None
      }
      if exp_neg {
        exp_val = -exp_val
      }
    }
  }
  if i != end {
    return None
  }
  let mut result = int_part + frac_part
  if exp_val > 0 {
    for _ in 0..<exp_val {
      result = result * 10.0
    }
  } else if exp_val < 0 {
    for _ in 0..<(-exp_val) {
      result = result / 10.0
    }
  }
  if neg {
    result = -result
  }
  if result.is_nan() || result.is_inf() {
    None
  } else {
    Some(result)
  }
}

///|
/// Parse `text` and commit the clamped, rounded value via `on_change`.
/// Returns `true` when `text` parses as a finite number (even if clamped to the current value), or `false` when parsing
/// fails or the input is disabled/read-only (leaving the current value unchanged).
pub fn NumberInput::commit_text(self : NumberInput, text : String) -> Bool {
  if @signals.untracked(self.disabled_) || @signals.untracked(self.read_only_) {
    return false
  }
  match ni_parse_double(text) {
    None => false
    Some(parsed) => {
      self.set_to(parsed)
      true
    }
  }
}

///|
/// Bind numeric field semantics to `v`: `Role::TextField` with formatted value, numeric range, `Increment`/`Decrement`
/// screen-reader actions, and keyboard stepping (`↑`/`↓`, `PageUp`/`PageDown`, `Home`/`End`).
pub fn NumberInput::field(self : NumberInput, v : @view.View, label : () -> String) -> Unit {
  let able = fn() { !(self.disabled_)() }
  v
  .presses(By(able))
  .focusable(By(able), keys=0)
  .says(By(fn() {
    let val = self.value()
    let acts : Array[@view.Action] = if (self.disabled_)() || (self.read_only_)() {
      []
    } else {
      [Increment, Decrement]
    }
    Some(@view.said(TextField, label=label(), value=self.formatted(), range=(self.min_, val, self.max_), actions=acts))
  }))
  .on_step(fn(by) {
    if by > 0 {
      self.step_up()
    } else if by < 0 {
      self.step_down()
    }
  })
  .on_key(fn(k) {
    if (self.disabled_)() || (self.read_only_)() || !v.focused() || k.mods != 0 {
      return false
    }
    if k.code == ni_key_up {
      self.step_up()
      true
    } else if k.code == ni_key_down {
      self.step_down()
      true
    } else if k.code == ni_key_page_up {
      self.step_up(large=true)
      true
    } else if k.code == ni_key_page_down {
      self.step_down(large=true)
      true
    } else if k.code == ni_key_home {
      self.to_min()
      true
    } else if k.code == ni_key_end {
      self.to_max()
      true
    } else {
      false
    }
  })
  |> ignore
}

///|
fn NumberInput::stepper_button(
  self : NumberInput,
  parent : @view.View,
  label : () -> String,
  look : (@view.View, Button) -> Unit,
  can_step : () -> Bool,
  do_step : () -> Unit,
  delay_ms : Double,
  interval_ms : Double,
  made_for : SourceLoc?,
  loc : SourceLoc,
) -> @view.View {
  let _ = self
  let repeated = Ref(false)
  let off = fn() { !can_step() }
  button(
    parent,
    label,
    fn(_) {
      if repeated.val {
        repeated.val = false
      } else {
        do_step()
      }
    },
    fn(v, b) {
      look(v, b)
      v.reacts(fn() { v.pressed() }, fn(p) {
        if p {
          repeated.val = false
        }
      })
      repeat_hold(
        v,
        fn() {
          repeated.val = true
          do_step()
        },
        delay_ms~,
        interval_ms~,
        disabled=off,
      )
      |> ignore
    },
    disabled=off,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
}

///|
/// An increment stepper button in `parent`, stepping up on press and auto-repeating while held via `repeat_hold`.
#callsite(autofill(loc))
pub fn NumberInput::increment_button(
  self : NumberInput,
  parent : @view.View,
  label : () -> String,
  look : (@view.View, Button) -> Unit,
  delay_ms? : Double = 400.0,
  interval_ms? : Double = 70.0,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  self.stepper_button(
    parent,
    label,
    look,
    fn() { self.can_increment() },
    fn() { self.step_up() },
    delay_ms,
    interval_ms,
    made_for,
    loc,
  )
}

///|
/// A decrement stepper button in `parent`, stepping down on press and auto-repeating while held via `repeat_hold`.
#callsite(autofill(loc))
pub fn NumberInput::decrement_button(
  self : NumberInput,
  parent : @view.View,
  label : () -> String,
  look : (@view.View, Button) -> Unit,
  delay_ms? : Double = 400.0,
  interval_ms? : Double = 70.0,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  self.stepper_button(
    parent,
    label,
    look,
    fn() { self.can_decrement() },
    fn() { self.step_down() },
    delay_ms,
    interval_ms,
    made_for,
    loc,
  )
}
