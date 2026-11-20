// The popover and the hover card: what floats beside what opened it, open while its caller says so.
//
// A popover (`Popover`): opened and closed by its trigger, a disclosure (disclosure.mbt: a button read out expanded while
// it is open, pressed by the pointer, Enter or Space, a screen reader's Activate); its content (`Popover::content`) read
// out a `Dialog` called by its label (not modal: what is beside it stays the hand's). As it opens the focus goes to the
// first of what the content holds that takes it (its own ground where none does), and as it goes back to the trigger
// (View::opened_by). Escape with the focus in it, on its trigger or nowhere (`close_on_escape`), and a press that goes
// down anywhere in the window but on the content or on its trigger (`close_on_outside`) close it. From the cause that
// closes it, at once, it takes no press and is not read out, however long its look's way out takes.
//
// A hover card (`HoverCard`): what the pointer resting on a trigger (a link, a name) shows more of. It opens
// `open_delay_ms` after the pointer came over the trigger (View::pointed_in: a mouse's, never a finger's, so a finger
// opens none and nothing waits on one) and closes `close_delay_ms` after the pointer left both the trigger and the card,
// so the pointer crossing from the one to the other keeps it open (the pointer's bridge: what was waited for to close
// it called off as the pointer comes onto the card). The keyboard's focus coming to the trigger so that it shows
// (View::focus_shown: by Tab, not by a press) opens it at once; the focus leaving both closes it at once, as Escape
// does. Every wait is a moment of the one clock (View::at_moment), called off by what supersedes it: nothing is
// counted by frames.
//
// Controlled (headless.mbt, State): whether either is open is its caller's (`open`), told what it is to be (`set_open`).

///|
/// A popover's trigger and content, made once by its caller and handed to each (`Popover::trigger`, `Popover::content`).
pub struct Popover {
  priv now : () -> Bool
  priv set : (Bool) -> Unit
  priv esc : Bool
  priv outside : Bool
  /// (its trigger's node, while it is made)
  priv opener : Ref[@view.View?]
}

///|
/// A popover open while `open` says so, `set_open` told what it is to be; closed by Escape (`close_on_escape`) and by a
/// press outside it and its trigger (`close_on_outside`).
pub fn Popover::new(
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  close_on_escape? : Bool = true,
  close_on_outside? : Bool = true,
) -> Popover {
  { now: open, set: set_open, esc: close_on_escape, outside: close_on_outside, opener: Ref(None) }
}

///|
/// Whether it is open now (as its caller says).
pub fn Popover::open(self : Popover) -> Bool {
  (self.now)()
}

///|
/// Closed, for what a look adds that closes it (its ✕): `set_open` told false, while it is open.
pub fn Popover::close(self : Popover) -> Unit {
  if @signals.untracked(self.now) {
    (self.set)(false)
  }
}

///|
/// Its trigger's node while it is made, or `None` when none is mounted.
pub fn Popover::opener(self : Popover) -> @view.View? {
  self.opener.val
}

///|
/// Its trigger in `parent`: a disclosure called `label` (disclosure.mbt), expanded while it is open, a press opening it
/// where it is closed and closing it where it is open; `disabled` while it opens nothing. `look` as the disclosure's.
/// The node.
#callsite(autofill(loc))
pub fn Popover::trigger(
  self : Popover,
  parent : @view.View,
  label : () -> String,
  look : (@view.View, Disclosure) -> Unit,
  disabled? : () -> Bool = fn() { false },
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  disclosure(
    parent,
    label,
    self.now,
    fn(_) { (self.set)(!@signals.untracked(self.now)) },
    fn(v, d) {
      self.opener.val = Some(v)
      v.owns(fn() {
        match self.opener.val {
          Some(o) if o.id() == v.id() => self.opener.val = None
          _ => ()
        }
      })
      |> ignore
      look(v, d)
    },
    disabled~,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
}

///|
/// Its content in `parent`, read out a `Dialog` called `label` while it is open. `look` is run once as it is made, given
/// its node: all that is drawn of it and where it goes (beside its trigger: View::beside). Its caller makes it while it
/// shows (View::show). The node.
#callsite(autofill(loc))
pub fn Popover::content(
  self : Popover,
  parent : @view.View,
  label : () -> String,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    v.focus_opens_first() |> ignore
    if self.opener.val is Some(o) {
      v.opened_by(ByNode(o.id())) |> ignore
    }
    let on_trigger = fn() {
      match self.opener.val {
        Some(o) => o.focused()
        None => false
      }
    }
    v
    .says(By(fn() { Some(@view.said(Dialog, label=label())) }))
    .hides(By(fn() { !(self.now)() }))
    .presses(By(self.now))
    .focusable(By(self.now), keys=0, tab=false)
    // (a press on its own ground its own, no press outside it)
    .on_drag(fn(_) {  })
    .on_key(fn(k) {
      if k.code == menu_key_escape &&
        k.mods == 0 &&
        self.esc &&
        (self.now)() &&
        (focus_in(v, true) || on_trigger()) {
        (self.set)(false)
        true
      } else {
        false
      }
    })
    |> ignore
    if self.outside {
      window_downs_while(v, self.now, fn(x, y) {
        let on_opener = match self.opener.val {
          Some(o) => press_on(o, x, y)
          None => false
        }
        if !press_on(v, x, y) && !on_opener {
          (self.set)(false)
        }
      })
    }
  })
}

///|
/// Mount its content in `host` while it is open (`View::show`), passing `look` the content node and its trigger node
/// (`Popover::opener`) so a look can float and position it in one step.
#callsite(autofill(loc))
pub fn Popover::layer(
  self : Popover,
  host : @view.View,
  label : () -> String,
  look : (@view.View, @view.View?) -> Unit,
  leave? : Double = 0.0,
  at_once? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> Unit {
  let place = made_for.unwrap_or(loc)
  host.show(
    self.now,
    fn(s) {
      self.content(s, label, fn(v) { look(v, self.opener.val) }, made_for=place, loc~) |> ignore
    },
    leave~,
    at_once~,
    loc~,
  )
}

///|
/// A hover card's trigger and card, made once by its caller and handed to each (`HoverCard::trigger`, `HoverCard::card`).
pub struct HoverCard {
  priv now : () -> Bool
  priv set : (Bool) -> Unit
  priv open_delay_ms : Double
  priv close_delay_ms : Double
  /// (what is waited for: its opening or its closing, called off by whatever supersedes it)
  priv waiting : Ref[() -> Unit]
  /// (its trigger's node and its card's, while each is made)
  priv opener : @signals.Signal[@view.View?]
  priv shown : @signals.Signal[@view.View?]
}

///|
/// Whether two nodes, or none, are the same.
fn same_node(a : @view.View?, b : @view.View?) -> Bool {
  match (a, b) {
    (None, None) => true
    (Some(x), Some(y)) => x.id() == y.id()
    _ => false
  }
}

///|
/// A hover card open while `open` says so, `set_open` told what it is to be; opening `open_delay_ms` after the pointer
/// came onto its trigger, closing `close_delay_ms` after it left the trigger and the card.
pub fn HoverCard::new(
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  open_delay_ms? : Double = 300.0,
  close_delay_ms? : Double = 150.0,
) -> HoverCard {
  {
    now: open,
    set: set_open,
    open_delay_ms,
    close_delay_ms,
    waiting: Ref(fn() {  }),
    // (nodes, kept by their ids: a node is no value to compare)
    opener: @signals.signal_by(None, same=same_node),
    shown: @signals.signal_by(None, same=same_node),
  }
}

///|
/// Whether it is open now (as its caller says).
pub fn HoverCard::open(self : HoverCard) -> Bool {
  (self.now)()
}

///|
/// Its trigger's node while it is made, or `None` when none is mounted. Followed where a binding reads it.
pub fn HoverCard::opener(self : HoverCard) -> @view.View? {
  self.opener.get()
}

///|
/// What was waited for called off.
fn HoverCard::call_off(self : HoverCard) -> Unit {
  (self.waiting.val)()
  self.waiting.val = fn() {  }
}

///|
/// Opened or closed at once (`set_open` told where it changes), what was waited for called off.
fn HoverCard::now_to(self : HoverCard, on : Bool) -> Unit {
  self.call_off()
  if @signals.untracked(self.now) != on {
    (self.set)(on)
  }
}

///|
/// Opened or closed `ms` after `node`'s cause (at once where `ms` is none), what was waited for before called off.
fn HoverCard::later_to(self : HoverCard, node : @view.View, on : Bool, ms : Double) -> Unit {
  self.call_off()
  if @signals.untracked(self.now) == on {
    return
  }
  if ms <= 0.0 {
    (self.set)(on)
    return
  }
  self.waiting.val = node.at_moment(node.cause_at() + ms, fn() {
    self.waiting.val = fn() {  }
    if @signals.untracked(self.now) != on {
      (self.set)(on)
    }
  })
}

///|
/// Whether the pointer is over the trigger or the card now. Followed where a binding reads it.
fn HoverCard::hovered(self : HoverCard) -> Bool {
  let on = fn(v : @view.View?) {
    match v {
      Some(n) => n.pointed_in()
      None => false
    }
  }
  on(self.opener.get()) || on(self.shown.get())
}

///|
/// Whether the keyboard's focus is on the trigger or in the card now, as the tree is (asked as the focus leaves the
/// trigger: not followed).
fn HoverCard::focus_held(self : HoverCard) -> Bool {
  let held = fn(v : @view.View?) {
    match v {
      Some(n) =>
        match n.tree.focused_now().0 {
          Some(f) => n.tree.holds(n.id(), f)
          None => false
        }
      None => false
    }
  }
  held(self.opener.untracked()) || held(self.shown.untracked())
}

///|
/// `node` made its trigger (a link's, a name's: its look and its component say what is drawn and read out of it);
/// `disabled` while it opens nothing (an open card closed as that comes). Nothing is said of the node: the card follows
/// its pointer and its focus (View::reacts); all of it let go with the node, the card closed then.
pub fn HoverCard::trigger(self : HoverCard, node : @view.View, disabled? : () -> Bool = fn() { false }) -> Unit {
  self.opener.set(Some(node))
  node.reacts(fn() { self.hovered() }, at_start=false, fn(over) {
    if over {
      if !disabled() {
        self.later_to(node, true, self.open_delay_ms)
      }
    } else if !self.focus_held() {
      self.later_to(node, false, self.close_delay_ms)
    }
  })
  node.reacts(fn() { node.focus_shown() }, at_start=false, fn(on) {
    if on && !disabled() {
      self.now_to(true)
    }
  })
  // (the focus gone from the trigger, not into the card, the pointer on neither: closed at once)
  node.reacts(fn() { node.focused() }, at_start=false, fn(on) {
    if !on && !self.focus_held() && !@signals.untracked(fn() { self.hovered() }) && @signals.untracked(self.now) {
      self.now_to(false)
    }
  })
  node.reacts(disabled, at_start=false, fn(off) { if off { self.now_to(false) } })
  node.owns(fn() {
    self.call_off()
    if same_node(self.opener.untracked(), Some(node)) {
      self.opener.set(None)
    }
    if @signals.untracked(self.now) {
      (self.set)(false)
    }
  })
  |> ignore
}

///|
/// Its card in `parent`, read out a `Group` called `label` while it is open; Escape while it is open closes it at once.
/// `look` is run once as it is made, given its node: all that is drawn of it and where it goes. Its caller makes it while
/// it shows (View::show). The node.
#callsite(autofill(loc))
pub fn HoverCard::card(
  self : HoverCard,
  parent : @view.View,
  label : () -> String,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    self.shown.set(Some(v))
    v.owns(fn() { if same_node(self.shown.untracked(), Some(v)) { self.shown.set(None) } }) |> ignore
    match self.opener.untracked() {
      Some(o) => v.opened_by(ByNode(o.id())) |> ignore
      None => ()
    }
    v
    .says(By(fn() { Some(@view.said(Group, label=label())) }))
    .hides(By(fn() { !(self.now)() }))
    .presses(By(self.now))
    .on_key(fn(k) {
      if k.code == menu_key_escape && k.mods == 0 && (self.now)() {
        self.now_to(false)
        true
      } else {
        false
      }
    })
    |> ignore
  })
}
