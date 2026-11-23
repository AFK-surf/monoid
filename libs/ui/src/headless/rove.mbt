// Roving focus: manages keyboard navigation (arrow keys along `axis`, Home/End, optional wrapping and RTL horizontal
// flipping), single-Tab-stop roving tabindex, and automatic focus recovery when a focused member is removed or
// disabled. Used by accordion, toggle group, listbox, radio group, menu, toolbar, and custom composite controls.
// Nothing here is drawn, laid out or read out.

///|
/// One member of a `RovingFocus`: its node, whether it is disabled, and whether Tab prefers it when nothing had focus.
priv struct RoveEntry {
  node : @view.View
  off : () -> Bool
  first : () -> Bool
}

///|
/// Composable roving focus behavior for multi-item composite controls.
pub struct RovingFocus {
  priv items : Array[RoveEntry]
  priv axis : GroupAxis
  priv roving : Bool
  priv wraps : Bool
  priv rtl : Bool
  /// (the last member that had focus; none yet)
  priv last : @signals.Signal[@view.NodeId?]
  /// (incremented on each add/remove so stop_at() re-evaluates)
  priv made : @signals.Signal[Int]
  priv recovery : FocusRecovery
}

///|
/// Create a new `RovingFocus` along `axis`. When `roving` is true, Tab stops on a single member (last focused live
/// member, else first preferred, else first enabled). When `rtl` is true, horizontal arrow keys (`←`/`→`) are flipped.
pub fn RovingFocus::new(
  axis? : GroupAxis = Vertical,
  roving? : Bool = true,
  wraps? : Bool = false,
  rtl? : Bool = false,
) -> RovingFocus {
  {
    items: [],
    axis,
    roving,
    wraps,
    rtl,
    last: @signals.signal(None),
    made: @signals.signal(0),
    recovery: FocusRecovery::new(),
  }
}

///|
/// Register `v` as a member, disabled while `disabled` returns true and preferred by Tab while `preferred` returns
/// true. Automatically removed when `v` unmounts (`View::owns`), with `FocusRecovery` handing focus to the next live
/// enabled member (or previous if at the end) if `v` held focus when removed or disabled.
pub fn RovingFocus::add(
  self : RovingFocus,
  v : @view.View,
  disabled? : () -> Bool = fn() { false },
  preferred? : () -> Bool = fn() { false },
) -> Unit {
  let removed_pos : Ref[Int?] = Ref(None)
  self.items.push({ node: v, off: disabled, first: preferred })
  self.made.set(self.made.untracked() + 1)
  let fallback = fn() -> @view.View? {
    let n = self.items.length()
    if n == 0 {
      return None
    }
    let (start_fwd, start_bwd) = match self.items.search_by(fn(e) { e.node.id() == v.id() }) {
      Some(idx) => (idx + 1, idx - 1)
      None => {
        let p = removed_pos.val.unwrap_or(0)
        (p, p - 1)
      }
    }
    for i in start_fwd..<n {
      let e = self.items[i]
      if e.node.id() != v.id() && e.node.takes_input() && !(e.off)() {
        return Some(e.node)
      }
    }
    let mut i = if start_bwd < n { start_bwd } else { n - 1 }
    while i >= 0 {
      let e = self.items[i]
      if e.node.id() != v.id() && e.node.takes_input() && !(e.off)() {
        return Some(e.node)
      }
      i = i - 1
    }
    None
  }
  self.recovery.track_with(v, fallback, false)
  v.owns(fn() {
    removed_pos.val = self.items.search_by(fn(e) { e.node.id() == v.id() })
    self.items.retain(fn(e) { e.node.id() != v.id() })
    if self.items.is_empty() {
      self.items.shrink_to_fit()
    }
    self.made.set(self.made.untracked() + 1)
  })
  |> ignore
  if self.roving {
    v.tab_stop(By(fn() { self.stop_at() == Some(v.id()) })) |> ignore
    v.reacts(fn() { v.focused() }, fn(f) { if f { self.last.set(Some(v.id())) } })
  }
}

///|
/// The live enabled members that currently take input, in registration order. Tracked when read inside a binding.
pub fn RovingFocus::live(self : RovingFocus) -> Array[@view.View] {
  self.items.filter_map(fn(e) { if e.node.takes_input() && !(e.off)() { Some(e.node) } else { None } })
}

///|
/// The member Tab stops on: the last that had focus while still live and enabled, else the first preferred live member,
/// else the first live member; `None` when none can take focus. Tracked when read inside a binding.
pub fn RovingFocus::stop_at(self : RovingFocus) -> @view.NodeId? {
  self.made.get() |> ignore
  let live = self.items.filter(fn(e) { e.node.takes_input() && !(e.off)() })
  match self.last.get() {
    Some(id) if live.iter().any(fn(e) { e.node.id() == id }) => Some(id)
    _ =>
      match live.iter().find_first(fn(e) { (e.first)() }) {
        Some(e) => Some(e.node.id())
        None =>
          match live {
            [e, ..] => Some(e.node.id())
            [] => None
          }
      }
  }
}

///|
/// Ask focus onto the current Tab stop (`stop_at`), shown where `visible`. Returns whether a member took focus.
pub fn RovingFocus::focus_stop(self : RovingFocus, visible? : Bool = true) -> Bool {
  match @signals.untracked(fn() { self.stop_at() }) {
    Some(id) =>
      match self.items.iter().find_first(fn(e) { e.node.id() == id }) {
        Some(e) => e.node.ask_focus(visible~)
        None => false
      }
    None => false
  }
}

///|
/// Ask focus onto the first live enabled member, shown where `visible`. Returns whether one took focus.
pub fn RovingFocus::focus_first(self : RovingFocus, visible? : Bool = true) -> Bool {
  match self.live() {
    [first, ..] => first.ask_focus(visible~)
    [] => false
  }
}

///|
/// Ask focus onto the last live enabled member, shown where `visible`. Returns whether one took focus.
pub fn RovingFocus::focus_last(self : RovingFocus, visible? : Bool = true) -> Bool {
  match self.live() {
    [.., last] => last.ask_focus(visible~)
    [] => false
  }
}

///|
/// The arrow keys that step backward and forward along `axis`, flipping horizontal keys when `rtl` is true.
fn axis_keys(axis : GroupAxis, rtl : Bool) -> (Array[Int], Array[Int]) {
  let (h_prev, h_next) = if rtl { (group_key_right, group_key_left) } else { (group_key_left, group_key_right) }
  match axis {
    Horizontal => ([h_prev], [h_next])
    Vertical => ([group_key_up], [group_key_down])
    Both => ([h_prev, group_key_up], [h_next, group_key_down])
  }
}

///|
/// Handle navigation key `code` when one of the live members has focus: step backward or forward along `axis`
/// (respecting `wraps` and `rtl`), or jump to first (`Home`) / last (`End`). Moves visible focus and returns the
/// target node, or `None` if unhandled.
pub fn RovingFocus::step(self : RovingFocus, code : Int) -> @view.View? {
  let live = self.live()
  let n = live.length()
  guard n > 0 && live.search_by(fn(v) { v.focused() }) is Some(i) else { return None }
  let (prev, next) = axis_keys(self.axis, self.rtl)
  let to = if prev.contains(code) {
    Some(if i > 0 { i - 1 } else if self.wraps { n - 1 } else { 0 })
  } else if next.contains(code) {
    Some(if i + 1 < n { i + 1 } else if self.wraps { 0 } else { n - 1 })
  } else if code == group_key_home {
    Some(0)
  } else if code == group_key_end {
    Some(n - 1)
  } else {
    None
  }
  match to {
    Some(j) => {
      live[j].ask_focus(visible=true) |> ignore
      Some(live[j])
    }
    None => None
  }
}
