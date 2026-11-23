// What a control of several parts keeps of them as the keys go among them (an accordion's headers, a toggle group's
// buttons, a list box's options): each part made, in the order made, let go with its node; which of them the keys may
// go to now (living, taking input, enabled); and, where it roves (Radix's roving focus: one stop of Tab's for all of
// them, menu.mbt's), which one Tab stops on: the last of them that had the focus while it is still one the keys may go
// to, else the first of those its caller prefers (a chosen one: `first`), else the first. Nothing here is drawn, laid
// out or read out.

///|
/// One part of a `Rove`: its node, whether it is disabled and whether Tab prefers it (where nothing had the focus).
priv struct RoveEntry {
  node : @view.View
  off : () -> Bool
  first : () -> Bool
}

///|
/// The parts of a control as the keys go among them, and where Tab stops among them where it roves.
priv struct Rove {
  items : Array[RoveEntry]
  roving : Bool
  /// (the last of them that had the focus; none yet)
  last : @signals.Signal[@view.NodeId?]
  /// (each made and let go one more: what a stop reads to follow them)
  made : @signals.Signal[Int]
}

///|
fn Rove::new(roving : Bool) -> Rove {
  { items: [], roving, last: @signals.signal(None), made: @signals.signal(0) }
}

///|
/// Part `v` made, disabled while `off` says so, preferred by Tab while `first` says so; let go with its node. Where it
/// roves, said (after `focusable`, which lets a stop go) to be Tab's stop while it is the one, and the last with the
/// focus as that comes to it.
fn Rove::add(self : Rove, v : @view.View, off : () -> Bool, first : () -> Bool) -> Unit {
  self.items.push({ node: v, off, first })
  self.made.set(self.made.untracked() + 1)
  v.owns(fn() {
    self.items.retain(fn(e) { e.node.id() != v.id() })
    self.made.set(self.made.untracked() + 1)
  })
  |> ignore
  if self.roving {
    v.tab_stop(By(fn() { self.stop_at() == Some(v.id()) })) |> ignore
    v.reacts(fn() { v.focused() }, fn(f) { if f { self.last.set(Some(v.id())) } })
  }
}

///|
/// The parts the keys may go to now, in the order made: living, taking input (not leaving, no modal layer over them),
/// enabled. Followed where a binding reads it.
fn Rove::live(self : Rove) -> Array[RoveEntry] {
  self.items.filter(fn(e) { e.node.takes_input() && !(e.off)() })
}

///|
/// The part Tab stops on: the last that had the focus while the keys may still go to it, else the first preferred,
/// else the first; none where none may be gone to. Followed where a binding reads it.
fn Rove::stop_at(self : Rove) -> @view.NodeId? {
  self.made.get() |> ignore
  let live = self.live()
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
/// The index among `live` of the part with the focus, if one has it.
fn rove_at(live : Array[RoveEntry]) -> Int? {
  live.search_by(fn(e) { e.node.focused() })
}

///|
/// Key `code` with the focus on one of its parts: to the part before (`prev`) or after (`next`) it, around the ends
/// where `wraps` (else staying at the end), Home to the first, End to the last; the focus asked there and shown. The
/// part gone to, where the key was one of these and the focus on one of its parts.
fn Rove::step(self : Rove, code : Int, prev : Array[Int], next : Array[Int], wraps : Bool) -> RoveEntry? {
  let live = self.live()
  let n = live.length()
  guard n > 0 && rove_at(live) is Some(i) else { return None }
  let to = if prev.contains(code) {
    Some(if i > 0 { i - 1 } else if wraps { n - 1 } else { 0 })
  } else if next.contains(code) {
    Some(if i + 1 < n { i + 1 } else if wraps { 0 } else { n - 1 })
  } else if code == group_key_home {
    Some(0)
  } else if code == group_key_end {
    Some(n - 1)
  } else {
    None
  }
  match to {
    Some(j) => {
      live[j].node.ask_focus(visible=true) |> ignore
      Some(live[j])
    }
    None => None
  }
}

///|
/// The arrow keys that step back and on along `axis` (GroupAxis: `Horizontal` ← →, `Vertical` ↑ ↓, `Both` all four).
fn axis_keys(axis : GroupAxis) -> (Array[Int], Array[Int]) {
  match axis {
    Horizontal => ([group_key_left], [group_key_right])
    Vertical => ([group_key_up], [group_key_down])
    Both => ([group_key_left, group_key_up], [group_key_right, group_key_down])
  }
}
