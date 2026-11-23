// The default button (AppKit's: the button whose key equivalent is Return; HTML's implicit submission): a node said
// to be pressed by Enter that nothing with the focus takes (View::default_press). Enter goes first to what has the
// focus (a button or a toggle it presses, a field's own Enter: View::focusable's `keys`, ui's field), then to the
// nodes that take keys and the keymap's actions (Tree::key_at, Tree::stroke), and only what none of them took comes
// here: the default of the topmost modal layer (a dialog, a sheet, a panel), the focus in it or in none of the tree; a
// page has none. A dialog says its primary button is its default; a confirm of what cannot be undone says
// none, so that Enter does not do it (the owner, 2026-11-16: 「危险操作回车不执行」, after Apple's: a destructive button
// is not the default). Where a layer holds more than one that would take it, none is pressed: which was meant is not
// known. A default is pressed as a press on it is taken (Tree::run_press_at's conditions: living, taking presses, under
// no modal layer that does not hold it, not leaving), as one event of the key's moment.

///|
/// Pressed by Enter that nothing with the focus takes, in its layer, while `on` holds (see the file's head). Said as
/// the change saying it is committed.
pub fn View::default_press(self : View, on : Live[Bool]) -> View {
  guard self.live() is Some(n) else { return self }
  n.prop_stop(Prop::DefaultPress.ord())
  let set = fn(on : Bool) {
    guard self.live() is Some(n) else { return }
    guard n.default_press != on else { return }
    n.default_press = on
    if on {
      self.tree.defaults_set += 1
    } else {
      self.tree.defaults_set -= 1
    }
  }
  match on {
    Is(v) => set(v)
    By(f) =>
      self.owning(fn() {
        let stop = self.tree.structured(f, fn(v) { self.owning(fn() { set(v) }) })
        n.prop_set(Prop::DefaultPress.ord(), stop)
      })
  }
  self
}

///|
/// The default that Enter at `at` presses (see the file's head), `from` the node the focus is in (None: in none of the
/// tree): the one of the topmost modal layer (the focus in it or in none) that takes a press then, where it is the only
/// one.
pub fn Tree::default_of(self : Tree, from : NodeId?) -> NodeId? {
  if self.defaults_set <= 0 || self.nodes.length() == 0 || !self.nodes[0].live {
    return None
  }
  // (a modal layer's alone: a dialog, a sheet, a panel; a page has no default, its primaries many and Enter its own)
  guard self.modal_top() is Some(m) else { return None }
  let top = self.top_of(m.at)
  guard top > 0 else { return None }
  // (the focus in another layer than it, over it: that layer's Enter, none of this one's)
  match from {
    Some(id) if self.alive_id(id) && self.top_of(id.at) != top => return None
    _ => ()
  }
  let found : Array[Int] = []
  self.topmost_from(top, fn(n) { n.default_press }, found)
  let taking = found.filter(fn(i) { self.nodes[i].on_press is Some(_) && !self.pressless_at(i) })
  match taking {
    [one] => Some({ at: one, gen: self.nodes[one].gen })
    _ => None
  }
}

///|
/// Enter that nothing with the focus took, at `at`, `from` the node the focus is in (None: none of the tree's): the
/// default it presses (Tree::default_of), as one event of that moment, its press run as a press on it is (what it
/// opens or shuts held where it is). Whether one was pressed.
pub fn Tree::press_default_at(self : Tree, at : Double, from~ : NodeId?) -> Bool {
  let pressed = Ref(false)
  self.event(at, fn() {
    // (what it says as of then: its bindings marked worked out first, Tree::pull)
    self.pull()
    guard self.default_of(from) is Some(id) else { return }
    match self.nodes[id.at].on_press {
      Some(f) => {
        pressed.val = true
        let held = self.press_stays(id)
        f()
        held()
      }
      None => ()
    }
  })
  pressed.val
}
