// The tooltip: a few words about what is pointed at, shown after the pointer has rested on it a while, and at once
// as the pointer goes on to its neighbour (a toolbar's icon buttons, one after another: Radix's Tooltip and its
// Provider's `skipDelayDuration`, WAI-ARIA's tooltip pattern). Of a group of triggers (`TooltipGroup[K]`) one tip
// shows at a time: the one its caller keeps (`shown`) and is told to change (`show`), as a combobox's active option
// is (headless.mbt, State); the group keeps only when one last closed and what is waited for.
//
// When it opens. A trigger (any node: a button's, a toggle's, a status mark's) is told as the pointer comes over it
// (View::pointed: a mouse's, never a finger's, so a tap or a long press on a phone shows no tip: what a finger holds
// up is the control's own `Hold`, button.mbt). Its tip opens `open_delay_ms` after that moment (View::at_moment),
// unless the group is warm: another trigger's tip shows now, or one closed no more than `warmup_ms` before: then at
// once. The keyboard's focus coming to it so that it shows (View::focus_shown: by Tab, not by a press) opens it at
// once.
//
// When it closes, at once, the group made warm from that moment: the pointer leaving it (and the focus, where that
// opened it), a press on it going down (View::pressed: it does not open again till the pointer leaves and comes back),
// Escape (`tooltip_close`, the keymap's `tooltip_keys`: taken only while a tip shows, else left to what is under it),
// its trigger disabled, its trigger let go. What it waits for is called off by each of these: nothing of a trigger let
// go is kept by the group or comes due after it (View::owns, View::at_moment's own).
//
// Where it comes from. A tip opened at once because the group was warm comes from the trigger whose tip showed last,
// where that is another (`TooltipGroup::glided_from`): its look may glide the bubble from beside that one to beside this
// one, as a toolbar's tip goes along from button to button, where a tip opened cold, or the same trigger's again, comes
// from nowhere and only shows. The group keeps which trigger's tip showed last, let go with that trigger.
//
// What it says. `tooltip_bubble` makes the tip's node, read out a `Tooltip` called by its words and taking no press
// (the pointer passes through it to what it is over: it never takes the hand from its trigger). Where it goes is its
// look's, beside the trigger by `anchor_place`, and so is whether it is in a layer of its own.

///|
/// What Escape does where a tip shows, by name (View::on_action's): the tip closed.
pub let tooltip_close : String = "tooltip.close"

///|
/// The keys of a tooltip's actions (ui's key codes: Escape 17), none held, anywhere: an app with tooltips puts these in
/// its keymap (View::keymap). Taken only while a tip shows.
pub let tooltip_keys : Array[@view.Binding] = [
  { keys: [{ code: 17, mods: 0 }], action: tooltip_close, when: Always },
]

///|
/// A group of triggers whose tips show one at a time, warm for a while after one closed: made once by its caller and
/// handed to each trigger (`TooltipGroup::trigger`).
pub struct TooltipGroup[K] {
  priv shown : () -> K?
  priv show : (K?) -> Unit
  priv open_delay_ms : Double
  priv warmup_ms : Double
  /// (the moment a tip of the group last closed; none since it was made)
  priv closed_at : Ref[Double?]
  /// (the trigger whose tip shows now or showed last; none since it was made, or since that trigger was let go)
  priv last : Ref[@view.NodeId?]
  /// (where the tip shown now came from, as it opened: the trigger before it and the moment, where it opened warm from
  /// another's)
  priv glided : Ref[(@view.NodeId, Double)?]
}

///|
/// A group whose tip shown now is the one `shown` says (the caller's to keep: what its looks read), `show` told the one
/// to show (none: none); a tip opening `open_delay_ms` after the pointer came to rest on its trigger, at once within
/// `warmup_ms` of one closing.
pub fn[K] TooltipGroup::new(
  shown : () -> K?,
  show : (K?) -> Unit,
  open_delay_ms? : Double = 400.0,
  warmup_ms? : Double = 300.0,
) -> TooltipGroup[K] {
  { shown, show, open_delay_ms, warmup_ms, closed_at: Ref(None), last: Ref(None), glided: Ref(None) }
}

///|
/// The tip shown now (as its caller says). Followed where a binding reads it.
pub fn[K] TooltipGroup::shown(self : TooltipGroup[K]) -> K? {
  (self.shown)()
}

///|
/// Whether the tip of `key` shows now. Followed where a binding reads it.
pub fn[K : Eq] TooltipGroup::is_open(self : TooltipGroup[K], key : K) -> Bool {
  (self.shown)() == Some(key)
}

///|
/// Where the tip shown now came from: the trigger whose tip showed before it and the moment it opened, where it opened
/// at once as the group was warm (the pointer or the focus gone on to it from that one's, or come to it within
/// `warmup_ms` of that one's closing) and that trigger is another; none where it opened cold, came back to the same
/// trigger, or none shows. A look reads it with `shown` as the tip opens: a bubble glided from beside that trigger to
/// beside this one (its node found by its id), from that moment. Followed as `shown` is, where a binding reads both.
pub fn[K] TooltipGroup::glided_from(self : TooltipGroup[K]) -> (@view.NodeId, Double)? {
  match (self.shown)() {
    Some(_) => self.glided.val
    None => None
  }
}

///|
/// The tip of `key` (its trigger `node`) shown, opened at `now`: warm (`warm`, as the group was before it) from another
/// trigger's, it came from that one (`glided_from`); else from nowhere.
fn[K] TooltipGroup::open(self : TooltipGroup[K], node : @view.View, key : K, now : Double, warm : Bool) -> Unit {
  let id = node.id()
  self.glided.val = match self.last.val {
    Some(from) if warm && from != id => Some((from, now))
    _ => None
  }
  self.last.val = Some(id)
  (self.show)(Some(key))
}

///|
/// Whether a tip opening at `now` opens at once: another shows (the pointer gone on from it to here), or one closed no
/// more than `warmup_ms` before.
fn[K] TooltipGroup::warm(self : TooltipGroup[K], now : Double) -> Bool {
  if (self.shown)() is Some(_) {
    return true
  }
  match self.closed_at.val {
    Some(at) => now - at <= self.warmup_ms
    None => false
  }
}

///|
/// The tip of `key` closed at `now`, where it is the one shown (another's is left as it is), the group warm from then.
fn[K : Eq] TooltipGroup::close(self : TooltipGroup[K], key : K, now : Double) -> Unit {
  if (self.shown)() == Some(key) {
    self.closed_at.val = Some(now)
    (self.show)(None)
  }
}

///|
/// `node` made a trigger of the group, its tip `key`'s; `disabled` while it opens none (one showing closed as that
/// comes). Nothing is said of the node that is drawn, laid out or read out (its look and its component say those):
/// the group follows its pointer, its press and its focus (View::reacts), and does `tooltip_close` for it
/// (View::on_action); all of it let go with the node, its tip closed then.
pub fn[K : Eq] TooltipGroup::trigger(
  self : TooltipGroup[K],
  node : @view.View,
  key : K,
  disabled? : () -> Bool = fn() { false },
) -> Unit {
  // (what is waited for: the tip's opening, called off by whatever closes it)
  let waiting : Ref[() -> Unit] = Ref(fn() {  })
  let call_off = fn() {
    (waiting.val)()
    waiting.val = fn() {  }
  }
  let close = fn() {
    call_off()
    self.close(key, node.cause_at())
  }
  let open_now = fn() {
    call_off()
    if !disabled() {
      let now = node.cause_at()
      self.open(node, key, now, self.warm(now))
    }
  }
  node.reacts(fn() { node.pointed() }, at_start=false, fn(over) {
    if !over {
      close()
    } else if !disabled() {
      let now = node.cause_at()
      if self.warm(now) {
        open_now()
      } else {
        call_off()
        waiting.val = node.at_moment(now + self.open_delay_ms, fn() {
          waiting.val = fn() {  }
          if !disabled() {
            self.open(node, key, now + self.open_delay_ms, false)
          }
        })
      }
    }
  })
  node.reacts(fn() { node.pressed() }, at_start=false, fn(down) { if down { close() } })
  node.reacts(fn() { node.focus_shown() }, at_start=false, fn(on) {
    if on {
      open_now()
    } else {
      close()
    }
  })
  node.reacts(disabled, at_start=false, fn(off) { if off { close() } })
  node
  .on_action(
    tooltip_close,
    fn(_ : @view.ActionAt) {
      close()
      true
    },
    can=fn() { self.is_open(key) },
  )
  .owns(fn() {
    call_off()
    self.close(key, node.cause_at())
    // (a trigger let go is where no tip comes from)
    if self.last.val == Some(node.id()) {
      self.last.val = None
    }
  })
  |> ignore
}

///|
/// A tip's node in `parent`, read out a `Tooltip` called `label`, taking no press (the pointer passes through it to
/// what is under it). `look` is given its node once as it is made: all that is drawn of it and where it goes (beside
/// its trigger by `anchor_place`). Its caller makes it while the group says its key is shown (View::show). Its node.
#callsite(autofill(loc))
pub fn tooltip_bubble(
  parent : @view.View,
  label : () -> String,
  look : (@view.View) -> Unit,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  parent.box(loc~, made_for=made_for.unwrap_or(loc), fn(v) {
    look(v)
    v.presses(Is(false)).says(By(fn() { Some(@view.said(Tooltip, label=label())) })) |> ignore
  })
}

///|
/// How long a mouse rests on a tooltip's trigger before it shows (ms), and how soon after another tooltip closed one
/// shows at once: the old controls' (`mbui/kit`'s `tooltip`) defaults, which still.fail's tips go by.
pub let tooltip_delay_ms : Double = 700.0

///|
pub let tooltip_skip_ms : Double = 300.0

///|
/// How long a tooltip a finger held open stays once it is lifted (Android's: 1500 ms).
pub let tooltip_lifted_ms : Double = 1500.0
