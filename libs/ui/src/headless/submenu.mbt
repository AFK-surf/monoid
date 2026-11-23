// The submenu: an item of a menu (`Menu::sub_trigger`) that opens a menu of its own beside it (`Submenu::menu`), open
// while its caller says so (`open`), told what it is to be (`set_open`; headless.mbt, State). The trigger is read out a
// `MenuItem` expanded while it is open; the submenu a `Menu`.
//
// Keys (WAI-ARIA's menu). On the trigger, `open_key` (→ by default: the side it opens on is its caller's, its look
// given the same, headless.mbt), Enter and Space open it and give the keys to its first enabled item, shown; with it
// open already they go there. In the submenu, Escape and `close_key` (← by default) close it and give the keys back to
// its trigger, shown. The keys leaving the trigger for another item of its menu (↓, ↑), not into the submenu, close it
// at once.
//
// The pointer. A press on the trigger opens it, the keys staying where they are (a pointer's press, a finger's tap). The
// pointer resting on the trigger opens it `open_delay_ms` after it came there (View::pointed_in: a mouse's, never a
// finger's, so a finger opens it by its tap alone and nothing waits on one), and leaving both the trigger and the
// submenu closes it `close_delay_ms` after (the pointer crossing from the trigger to the submenu, over what lies between,
// keeps it open: what was waited for to close it called off as the pointer comes onto the submenu), unless the keys are
// in it. Every wait is a moment of the one clock (View::at_moment), called off by what supersedes it: nothing is counted
// by frames. Disabled (the trigger or its menu), it opens nothing, an open one closed as that comes.

///|
/// A submenu's trigger and menu, made once by its caller and handed to each (`Menu::sub_trigger`, `Submenu::menu`).
pub struct Submenu {
  priv now : () -> Bool
  priv set : (Bool) -> Unit
  priv open_delay_ms : Double
  priv close_delay_ms : Double
  /// (what is waited for: its opening or its closing, called off by whatever supersedes it)
  priv waiting : Ref[() -> Unit]
  /// (its trigger's node and its menu's node, while each is made)
  priv opener : @signals.Signal[@view.View?]
  priv shown : @signals.Signal[@view.View?]
  /// (its menu, while it is made: what the keys go into)
  priv inner : Ref[Menu?]
  /// (opened by the keys, its menu not made yet: the keys given to its first item as it is)
  priv enter : Ref[Bool]
}

///|
/// A submenu open while `open` says so, `set_open` told what it is to be; opening `open_delay_ms` after the pointer came
/// onto its trigger, closing `close_delay_ms` after it left the trigger and the submenu.
pub fn Submenu::new(
  open : () -> Bool,
  set_open : (Bool) -> Unit,
  open_delay_ms? : Double = 180.0,
  close_delay_ms? : Double = 150.0,
) -> Submenu {
  {
    now: open,
    set: set_open,
    open_delay_ms,
    close_delay_ms,
    waiting: Ref(fn() {  }),
    // (nodes, kept by their ids: a node is no value to compare)
    opener: @signals.signal_by(None, same=same_node),
    shown: @signals.signal_by(None, same=same_node),
    inner: Ref(None),
    enter: Ref(false),
  }
}

///|
/// Whether it is open now (as its caller says).
pub fn Submenu::open(self : Submenu) -> Bool {
  (self.now)()
}

///|
/// Closed, for what a look adds that closes it: `set_open` told false, while it is open; what was waited for called off.
pub fn Submenu::close(self : Submenu) -> Unit {
  self.now_to(false)
}

///|
/// What was waited for called off.
fn Submenu::call_off(self : Submenu) -> Unit {
  (self.waiting.val)()
  self.waiting.val = fn() {  }
}

///|
/// Opened or closed at once (`set_open` told where it changes), what was waited for called off.
fn Submenu::now_to(self : Submenu, on : Bool) -> Unit {
  self.call_off()
  if !on {
    self.enter.val = false
  }
  if @signals.untracked(self.now) != on {
    (self.set)(on)
  }
}

///|
/// Opened or closed `ms` after `node`'s cause, what was waited for before called off.
fn Submenu::later_to(self : Submenu, node : @view.View, on : Bool, ms : Double) -> Unit {
  self.call_off()
  if @signals.untracked(self.now) == on {
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
/// Opened now; where `keys` (it came by the keys), the keys given to its first enabled item: at once where its menu is
/// made, else as it is (Submenu::menu).
fn Submenu::open_now(self : Submenu, keys : Bool) -> Unit {
  self.now_to(true)
  if !keys {
    return
  }
  match self.inner.val {
    Some(m) if m.node.alive() => {
      self.enter.val = false
      m.focus_first() |> ignore
    }
    _ => self.enter.val = true
  }
}

///|
/// Whether the pointer is over the trigger or the submenu now. Followed where a binding reads it.
fn Submenu::hovered(self : Submenu) -> Bool {
  let on = fn(v : @view.View?) {
    match v {
      Some(n) => n.pointed_in()
      None => false
    }
  }
  on(self.opener.get()) || on(self.shown.get())
}

///|
/// Whether the keyboard's focus is in the submenu now, as the tree is (asked as the focus leaves the trigger: not
/// followed).
fn Submenu::focus_inside(self : Submenu) -> Bool {
  match self.shown.untracked() {
    Some(n) =>
      match n.tree.focused_now().0 {
        Some(f) => n.tree.holds(n.id(), f)
        None => false
      }
    None => false
  }
}

///|
/// An item of `self` in `parent` (`parent` itself where `in_node`) that opens `sub`: read out a `MenuItem` called
/// `label`, expanded while `sub` is open; `disabled` while it alone opens nothing; `open_key` the arrow toward the side
/// it opens on (→ by default; the caller's, its look given the same). `look` is given its node and its `MenuItem` (its
/// `open` the submenu's) once as it is made. Its node.
#callsite(autofill(loc))
pub fn Menu::sub_trigger(
  self : Menu,
  parent : @view.View,
  sub : Submenu,
  label : () -> String,
  look : (@view.View, MenuItem) -> Unit,
  disabled? : () -> Bool = fn() { false },
  open_key? : Int = group_key_right,
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let off = fn() { (self.off)() || disabled() }
  // (pressed: by Enter or Space the keys go into it, as they came; by the pointer they stay where they are)
  let node = self.part(
    parent,
    MenuItem,
    label,
    None,
    Some(sub.now),
    fn(v) { sub.open_now(v.focus_shown()) },
    look,
    disabled,
    in_node,
    made_for,
    loc,
  )
  sub.opener.set(Some(node))
  node.on_key(fn(k) {
    if k.mods == 0 && k.code == open_key && !off() && node.focused() {
      sub.open_now(true)
      true
    } else {
      false
    }
  })
  |> ignore
  // (the pointer come over the trigger or the submenu, or gone from both: opened or closed after its wait)
  node.reacts(fn() { sub.hovered() }, at_start=false, fn(over) {
    if over {
      if !off() {
        sub.later_to(node, true, sub.open_delay_ms)
      }
    } else if !sub.focus_inside() {
      sub.later_to(node, false, sub.close_delay_ms)
    }
  })
  // (the keys gone from the trigger, not into the submenu, the pointer on neither: closed at once)
  node.reacts(fn() { node.focused() }, at_start=false, fn(on) {
    if !on && !sub.focus_inside() && !@signals.untracked(fn() { sub.hovered() }) && @signals.untracked(sub.now) {
      sub.now_to(false)
    }
  })
  node.reacts(off, at_start=false, fn(o) { if o { sub.now_to(false) } })
  node.owns(fn() {
    sub.call_off()
    if same_node(sub.opener.untracked(), Some(node)) {
      sub.opener.set(None)
    }
  })
  |> ignore
  node
}

///|
/// Its menu in `parent`, read out a `Menu` (called `label` where given one): a menu (menu.mbt) whose Escape and
/// `close_key` (← by default) close it and give the keys back to its trigger. `look` as a menu's: given its node and
/// the `Menu` its items are made by, once as it is made, all that is drawn of it and where it goes (beside its trigger:
/// View::beside). Its caller makes it while it shows (View::show). Opened by the keys, the keys go to its first enabled
/// item as it is made. The node.
#callsite(autofill(loc))
pub fn Submenu::menu(
  self : Submenu,
  parent : @view.View,
  look : (@view.View, Menu) -> Unit,
  label? : () -> String,
  close_key? : Int = group_key_left,
  wraps? : Bool = true,
  typeahead? : Bool = true,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let v = menu(
    parent,
    fn(v, m) {
      self.inner.val = Some(m)
      self.shown.set(Some(v))
      v.owns(fn() {
        if same_node(self.shown.untracked(), Some(v)) {
          self.shown.set(None)
          self.inner.val = None
        }
      })
      |> ignore
      look(v, m)
    },
    label?,
    on_close=fn() {
      self.now_to(false)
      match self.opener.untracked() {
        Some(o) => o.ask_focus(visible=true) |> ignore
        None => ()
      }
    },
    close_key~,
    wraps~,
    typeahead~,
    made_for=made_for.unwrap_or(loc),
    loc~,
  )
  // (opened by the keys: they go to its first item once what it holds is made and committed, at this cause's moment)
  if self.enter.val {
    v.at_moment(v.cause_at(), fn() {
      if self.enter.val {
        self.enter.val = false
        match self.inner.val {
          Some(m) => m.focus_first() |> ignore
          None => ()
        }
      }
    })
    |> ignore
  }
  v
}
