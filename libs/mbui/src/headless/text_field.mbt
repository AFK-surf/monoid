// The text field's parts as a form has them: its label, what describes it, what is wrong with it, and the control the
// words are written in, kept together by one `TextField` its caller makes once and hands to each.
//
// What a screen reader hears. The control (`TextField::control`, a node the look draws a field in) is read out a
// `TextField` called by the label, described by the error while it is invalid and the error says something, else by
// the description; its value what its caller says it holds. A control that says its own (a field of ui's, which says
// its words and takes them from a screen reader) is the caller's own node instead (`TextField::control_node`), its
// look given the label and the description to say (`TextField::label_text`, `TextField::said_description`). The label
// (`TextField::label`) is read out `Text`; what describes it (`TextField::description`) `Text`, not read out while it
// says nothing; the error (`TextField::error`) a `Status`, so that it is read out as it comes, and not read out while
// the field is valid or the error says nothing. Required and read only are no words of view's Said yet: its look
// reads them (`TextField::required`, `TextField::read_only`) and shows them.
//
// The hand and the keys. A press on the label (the pointer's, a finger's, a screen reader's Activate) gives the keys
// to the control, shown, while the field is not disabled; the label takes no focus of its own and is no stop of Tab's.
// Disabled, the control takes no press and no focus, read out disabled; read only, it still takes both (its words can
// be picked and read).
//
// Controlled (headless.mbt, State): every state is its caller's, a function followed where a binding reads it.

///|
/// A form's text field: its label, description, error and states, as its caller says them, and its control once made.
pub struct TextField {
  priv label_ : () -> String
  priv description_ : () -> String
  priv error_ : () -> String
  priv invalid_ : () -> Bool
  priv required_ : () -> Bool
  priv disabled_ : () -> Bool
  priv read_only_ : () -> Bool
  /// (its control's node, while it is made)
  priv control_ : @signals.Signal[@view.View?]
}

///|
/// A text field called `label`, described by `description`, its `error` said while `invalid`; `required`, `disabled`
/// and `read_only` as its caller says.
pub fn TextField::new(
  label : () -> String,
  description? : () -> String = fn() { "" },
  error? : () -> String = fn() { "" },
  invalid? : () -> Bool = fn() { false },
  required? : () -> Bool = fn() { false },
  disabled? : () -> Bool = fn() { false },
  read_only? : () -> Bool = fn() { false },
) -> TextField {
  {
    label_: label,
    description_: description,
    error_: error,
    invalid_: invalid,
    required_: required,
    disabled_: disabled,
    read_only_: read_only,
    // (a node, kept by its id: a node is no value to compare)
    control_: @signals.signal_by(None, same=same_node),
  }
}

///|
/// Its label's words now.
pub fn TextField::label_text(self : TextField) -> String {
  (self.label_)()
}

///|
/// What describes it now, as its caller says.
pub fn TextField::description_text(self : TextField) -> String {
  (self.description_)()
}

///|
/// What is wrong with it now: its error while it is invalid, else nothing ("").
pub fn TextField::error_text(self : TextField) -> String {
  if (self.invalid_)() {
    (self.error_)()
  } else {
    ""
  }
}

///|
/// What its control is described by to a screen reader now: its error where it says something (it is invalid), else
/// its description.
pub fn TextField::said_description(self : TextField) -> String {
  match self.error_text() {
    "" => self.description_text()
    e => e
  }
}

///|
/// Whether it is invalid now (as its caller says).
pub fn TextField::invalid(self : TextField) -> Bool {
  (self.invalid_)()
}

///|
/// Whether it must be filled in (as its caller says).
pub fn TextField::required(self : TextField) -> Bool {
  (self.required_)()
}

///|
/// Whether it is disabled now (as its caller says): its control takes no press and no focus.
pub fn TextField::disabled(self : TextField) -> Bool {
  (self.disabled_)()
}

///|
/// Whether its words can be read and picked but not changed now (as its caller says).
pub fn TextField::read_only(self : TextField) -> Bool {
  (self.read_only_)()
}

///|
/// Whether its control has the keyboard's focus now. Followed where a binding reads it.
pub fn TextField::focused(self : TextField) -> Bool {
  match self.control_.get() {
    Some(c) => c.focused()
    None => false
  }
}

///|
/// The keys given to its control, shown, while it is not disabled; whether it took them. Called from a handler (a
/// press, a key), never as something is drawn.
pub fn TextField::focus(self : TextField) -> Bool {
  if @signals.untracked(self.disabled_) {
    return false
  }
  match self.control_.untracked() {
    Some(c) if c.alive() => c.ask_focus(visible=true)
    _ => false
  }
}

///|
/// `node` made its control where its caller's control says what it is itself (a field of ui's, saying its words): the
/// label's press gives it the keys. Nothing is said of it here; its look gives it the label and the description
/// (`TextField::label_text`, `TextField::said_description`). Let go with the node.
pub fn TextField::control_node(self : TextField, node : @view.View) -> Unit {
  self.control_.set(Some(node))
  node.owns(fn() { if same_node(self.control_.untracked(), Some(node)) { self.control_.set(None) } }) |> ignore
}

///|
/// Its control in `parent` (`parent` itself where `in_node`): read out a `TextField` called by its label, described by
/// its error or its description (`TextField::said_description`), holding `value`; taking a press and the focus while it
/// is not disabled. `look` is given its node and the field once as it is made: all that is drawn of it and how it is
/// laid out, and the words written in it (its keys, its caret). Its node.
#callsite(autofill(loc))
pub fn TextField::control(
  self : TextField,
  parent : @view.View,
  look : (@view.View, TextField) -> Unit,
  value? : () -> String = fn() { "" },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    self.control_node(v)
    look(v, self)
    let able = fn() { !(self.disabled_)() }
    v
    .presses(By(able))
    .focusable(By(able), keys=0)
    .says(By(fn() {
      Some(@view.said(TextField, label=self.label_text(), description=self.said_description(), value=value()))
    }))
    .on_press(fn() { if able() { v.ask_focus() |> ignore } })
    |> ignore
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}

///|
/// Its label in `parent`: read out `Text` of its label's words; a press on it (while the field is not disabled and its
/// control is made) gives the control the keys, shown. `look` is given its node once as it is made: all that is drawn
/// of it (its words) and how it is laid out. Its node.
#callsite(autofill(loc))
pub fn TextField::label(
  self : TextField,
  parent : @view.View,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    let able = fn() { !(self.disabled_)() && self.control_.get() is Some(_) }
    v
    .presses(By(able))
    .says(By(fn() { Some(@view.said(Text, label=self.label_text())) }))
    .on_press(fn() { self.focus() |> ignore })
    |> ignore
  })
}

///|
/// What describes it, in `parent`: read out `Text` of its description, not read out while that says nothing. `look`
/// as the label's. Its node.
#callsite(autofill(loc))
pub fn TextField::description(
  self : TextField,
  parent : @view.View,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    v
    .says(By(fn() { Some(@view.said(Text, label=self.description_text())) }))
    .hides(By(fn() { self.description_text() == "" }))
    |> ignore
  })
}

///|
/// What is wrong with it, in `parent`: read out a `Status` of its error as that comes (a screen reader tells it then),
/// not read out while it is valid or its error says nothing. `look` as the label's (it shows it while
/// `TextField::error_text` says something). Its node.
#callsite(autofill(loc))
pub fn TextField::error(
  self : TextField,
  parent : @view.View,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    v
    .says(By(fn() { Some(@view.said(Status, label=self.error_text())) }))
    .hides(By(fn() { self.error_text() == "" }))
    |> ignore
  })
}
