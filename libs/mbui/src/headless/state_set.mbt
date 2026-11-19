// The states of a control as one reading (Flutter's WidgetState set, Base UI's state prop): what a look's every
// property is chosen by, so a look says once which state wins (StateStyle) rather than each of its properties weighing
// hovered, pressed, the focus shown and disabled again. Read of a control's component (Button::state and the others),
// each field the reading of the same name there, followed where a binding reads it; what the component does not know (a
// button's `selected` among others, its `busy`) its look gives.

///|
/// A control's states as its look reads them at once: a pointer resting on it (never a finger's), a finger or the
/// pointer held on it, the keyboard's focus on it, that focus shown (it came by the keys), disabled, selected (chosen,
/// on, checked), what it opens open, at work.
#derive(Eq, Debug)
pub(all) struct ControlState {
  hovered : Bool
  pressed : Bool
  focused : Bool
  focus_shown : Bool
  disabled : Bool
  selected : Bool
  open : Bool
  busy : Bool
}

///|
/// The button's states now; `selected` and `busy` as its look says (a button knows neither).
pub fn Button::state(self : Button, selected? : Bool = false, busy? : Bool = false) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.node.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected,
    open: false,
    busy,
  }
}

///|
/// The toggle's states now: selected while it is on (or mixed); `busy` as its look says.
pub fn Toggle::state(self : Toggle, busy? : Bool = false) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.node.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected: self.on() || self.mixed(),
    open: false,
    busy,
  }
}

///|
/// The choice's states now: selected while it is the one chosen; `busy` as its look says.
pub fn Choice::state(self : Choice, busy? : Bool = false) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.node.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected: self.chosen(),
    open: false,
    busy,
  }
}

///|
/// The disclosure's states now: open while what it opens is; `busy` as its look says.
pub fn Disclosure::state(self : Disclosure, busy? : Bool = false) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.node.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected: false,
    open: self.open(),
    busy,
  }
}

///|
/// A menu item's states now: selected while it is checked, open while the submenu it opens is.
pub fn MenuItem::state(self : MenuItem) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected: self.checked(),
    open: self.open(),
    busy: false,
  }
}

///|
/// A radio item's (a tab's) states now: selected while it is the one chosen.
pub fn RadioItem::state(self : RadioItem) -> ControlState {
  {
    hovered: self.hovered(),
    pressed: self.pressed(),
    focused: self.node.focused(),
    focus_shown: self.focus_shown(),
    disabled: self.disabled(),
    selected: self.chosen(),
    open: false,
    busy: false,
  }
}

///|
/// What one property of a look is in each state, the first said that holds winning: disabled, busy, pressed, selected
/// and hovered, selected, open, hovered, the focus shown (`focused`: a ring's, by the keys), else `base`.
pub struct StateStyle[T] {
  priv base : T
  priv disabled : T?
  priv busy : T?
  priv pressed : T?
  priv selected_hovered : T?
  priv selected : T?
  priv open : T?
  priv hovered : T?
  priv focused : T?
}

///|
/// A property `base` where no state said here holds, each said one in its state.
pub fn[T] StateStyle::new(
  base~ : T,
  disabled? : T,
  busy? : T,
  pressed? : T,
  selected_hovered? : T,
  selected? : T,
  hovered? : T,
  focused? : T,
  open? : T,
) -> StateStyle[T] {
  { base, disabled, busy, pressed, selected_hovered, selected, open, hovered, focused }
}

///|
/// What it is in states `s`: the first said that holds (disabled > busy > pressed > selected and hovered > selected >
/// open > hovered > the focus shown > base).
pub fn[T] StateStyle::resolve(self : StateStyle[T], s : ControlState) -> T {
  if s.disabled && self.disabled is Some(v) {
    return v
  }
  if s.busy && self.busy is Some(v) {
    return v
  }
  if s.pressed && self.pressed is Some(v) {
    return v
  }
  if s.selected && s.hovered && self.selected_hovered is Some(v) {
    return v
  }
  if s.selected && self.selected is Some(v) {
    return v
  }
  if s.open && self.open is Some(v) {
    return v
  }
  if s.hovered && self.hovered is Some(v) {
    return v
  }
  if s.focus_shown && self.focused is Some(v) {
    return v
  }
  self.base
}
