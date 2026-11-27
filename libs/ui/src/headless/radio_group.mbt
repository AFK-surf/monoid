// The radio group and the tab list: a control of several parts, one among them chosen at a time. The group says it is a
// radio group (`RadioGroup`) or a tab list (`TabList`) called by its label; each item made by `RadioGroup::item` says it
// is a radio (`Radio`, checked `On` or `Off`) or a tab (`Tab`, `selected` true or false) called by its own label.
//
// Roving focus and keys: Tab stops at one item of the group alone — the chosen one while it is enabled, or the first
// enabled item when none matches `chosen()`. While any item of the group has the keyboard's focus, the arrow keys along
// `axis` (`Horizontal`: ← and →; `Vertical`: ↑ and ↓; `Both`: all four) step to the enabled item before or after,
// wrapping around the ends, and Home and End go to the first and the last enabled item, each choosing what it comes to
// (`choose` told its key when it is not chosen already; not with `manual`, where only a press chooses) and moving
// visible focus there. Pressing an item (by the
// pointer, by Space or Enter while it has focus, or by a screen reader's Activate) chooses it when it is not chosen
// already, and does nothing when it already is or while disabled.
//
// A tab that closes (`RadioGroup::item`'s `on_close`, a `Tab` list's alone): Delete or Backspace while it has the focus
// closes it, as what its look adds to close it does (`RadioItem::close`); one the keyboard was on hands the keyboard
// to the enabled tab then chosen (`chosen()` as its caller says after `on_close`, its node once made), or to the first
// enabled tab where what is chosen is no tab's. One closed behind, the keyboard elsewhere, takes nothing.

///|
/// What the group and its items are to a screen reader: a `Radio` group (`RadioGroup` of `Radio` items) or a `Tab`
/// list (`TabList` of `Tab` items).
#derive(Eq, Debug)
pub(all) enum GroupKind {
  Radio
  Tab
}

///|
/// Which arrow keys step along the group: `Horizontal` (← and →), `Vertical` (↑ and ↓), or `Both` (all four).
#derive(Eq, Debug)
pub(all) enum GroupAxis {
  Horizontal
  Vertical
  Both
}

///|
/// One registered item of a `RadioGroup[K]`.
priv struct GroupEntry[K] {
  node : @view.View
  key : () -> K
  off : () -> Bool
}

///|
/// A radio group or tab list handed to its look to register its items with `RadioGroup::item`.
pub struct RadioGroup[K] {
  priv kind : GroupKind
  priv selected : Bool
  priv now : () -> K
  priv choose : (K) -> Unit
  priv off : () -> Bool
  priv items : Array[GroupEntry[K]]
  priv rove : RovingFocus
  priv building : Ref[Bool]
  priv stops : Array[(@view.View, () -> Unit)]
  // (the tab closed while the keyboard was on it and its key, the keyboard waiting to be handed on)
  priv refocus : Ref[(@view.View, K)?]
}

///|
/// Whether the whole group is disabled (as its caller says).
pub fn[K] RadioGroup::disabled(self : RadioGroup[K]) -> Bool {
  (self.off)()
}

///|
/// One item of a `RadioGroup[K]` as its look reads it: each a reading, followed where a binding reads it.
pub struct RadioItem {
  priv node : @view.View
  priv now : () -> Bool
  priv off : () -> Bool
  priv close_ : () -> Unit
}

///|
/// Closes this tab, for what a look adds to close it (its ×): the item's `on_close`, the keyboard handed on to the tab
/// then chosen where it was on this one. Nothing where the item has no `on_close` or does not close now.
pub fn RadioItem::close(self : RadioItem) -> Unit {
  (self.close_)()
}

///|
/// Whether this item is the chosen one now.
pub fn RadioItem::chosen(self : RadioItem) -> Bool {
  (self.now)()
}

///|
/// Whether this item is disabled (either the group or the item itself is disabled).
pub fn RadioItem::disabled(self : RadioItem) -> Bool {
  (self.off)()
}

///|
/// Whether a finger or the pointer is held on this item now (View::pressed).
pub fn RadioItem::pressed(self : RadioItem) -> Bool {
  self.node.pressed()
}

///|
/// Whether a pointer rests over this item now (View::pointed): a mouse's, never a finger's.
pub fn RadioItem::hovered(self : RadioItem) -> Bool {
  self.node.pointed()
}

///|
/// Whether this item has the keyboard's focus and that shows (View::focus_shown).
pub fn RadioItem::focus_shown(self : RadioItem) -> Bool {
  self.node.focus_shown()
}

///|
/// Pressed now, for what a look adds that ends in a press: asked of the tree as a press delivered to the item's node
/// (View::press).
pub fn RadioItem::press(self : RadioItem) -> Unit {
  self.node.press() |> ignore
}

///|
/// The key codes that step along a group (`ui`'s `key_code_*`).
let group_key_left : Int = 3

///|
let group_key_right : Int = 4

///|
let group_key_up : Int = 5

///|
let group_key_down : Int = 6

///|
let group_key_home : Int = 8

///|
let group_key_end : Int = 9

///|
/// The key codes that close a tab that closes (`ui`'s `key_code_backspace`, `key_code_delete`).
let group_key_backspace : Int = 1

///|
let group_key_delete : Int = 2

///|
/// A radio group or tab list in `parent`, called `label` (what a screen reader says), `chosen` saying which key `K` is
/// chosen now and `choose` told the key chosen by a press or an arrow key; `kind` whether it is a `Radio` group or a
/// `Tab` list; `axis` which arrow keys step along it; `disabled` while the whole group takes no press and no focus;
/// `manual`: the arrow keys and Home and End move the focus alone, what has it chosen by Space or Enter (WAI-ARIA's
/// tabs with manual activation, kit's tabs' `manual`: a tab whose panel is slow to show).
/// `look` is given the group's node and the `RadioGroup[K]` with which its items are made (`RadioGroup::item`, directly
/// or inside `View::each`). The group's node.
#callsite(autofill(loc))
pub fn[K : Eq] radio_group(
  parent : @view.View,
  label : () -> String,
  chosen : () -> K,
  choose : (K) -> Unit,
  look : (@view.View, RadioGroup[K]) -> Unit,
  kind? : GroupKind = Radio,
  axis? : GroupAxis = Horizontal,
  rtl? : Bool = false,
  shown? : () -> Bool = fn() { true },
  selected? : Bool = false,
  in_node? : Bool = false,
  disabled? : () -> Bool = fn() { false },
  manual? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let items : Array[GroupEntry[K]] = []
    let rove = RovingFocus::new(axis~, roving=false, wraps=true, rtl~)
    let building = Ref(true)
    let stops : Array[(@view.View, () -> Unit)] = []
    let refocus : Ref[(@view.View, K)?] = Ref(None)
    let rg : RadioGroup[K] = { kind, selected, now: chosen, choose, off: disabled, items, rove, building, stops, refocus }
    look(v, rg)
    // (the keyboard handed on as the tab chosen after a close comes: its node made by then)
    if kind is Tab {
      v.reacts(chosen, fn(_) { rg.hand_on() }, at_start=false) |> ignore
    }
    building.val = false
    for s in stops {
      if s.0.alive() {
        (s.1)()
      }
    }
    v
    .says(By(fn() {
      if !shown() {
        None
      } else {
        Some(
          match kind {
            Radio => @view.said(RadioGroup, label=label())
            Tab => @view.said(TabList, label=label())
          },
        )
      }
    }))
    .on_key(fn(k) {
      if disabled() || k.mods != 0 {
        return false
      }
      match rove.step(k.code) {
        Some(target_node) => {
          if !manual {
            for i = 0; i < items.length(); i = i + 1 {
              let target = items[i]
              if target.node.id() == target_node.id() {
                let next_key = (target.key)()
                if next_key != chosen() {
                  choose(next_key)
                }
                break
              }
            }
          }
          true
        }
        None => false
      }
    })
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
/// The keyboard handed on after the tab it was on closed (`RadioGroup::refocus`): to the enabled item chosen now, the
/// closed one aside; where what is chosen is another key that no enabled item has, to the first enabled one. While the
/// closed one's key is still the one chosen (its caller has not said what comes in front yet), it waits.
fn[K : Eq] RadioGroup::hand_on(self : RadioGroup[K]) -> Unit {
  guard self.refocus.val is Some((gone, gone_key)) else { return }
  let cur = @signals.untracked(self.now)
  let live = self.items.filter(fn(e) { e.node.alive() && e.node.id() != gone.id() && !@signals.untracked(e.off) })
  let mut matched : GroupEntry[K]? = None
  for i = 0; i < live.length(); i = i + 1 {
    let e = live[i]
    if @signals.untracked(e.key) == cur {
      matched = Some(e)
      break
    }
  }
  let to = match matched {
    Some(e) => Some(e)
    None => if cur != gone_key { live.get(0) } else { None }
  }
  if to is Some(e) {
    self.refocus.val = None
    e.node.ask_focus(visible=true) |> ignore
  }
}

///|
/// An item of `self` in `parent` (which may be the group's node or a slot/container inside it), identified by `key`
/// and read out as `label`. `look` is given the item's node and its `RadioItem` state. `disabled` disables this item
/// alone; `space_only` limits keyboard activation on the focused item to Space (leaving Enter to a surrounding form);
/// `slop` attaches a pointer gesture of that touch slop whose tap or release on the item presses it (for sliding-thumb
/// strips where a finger moved off and back onto an item still chooses it on release). For `slide`, give a hold time
/// and a function that previews the option at a touch point and returns its key. A horizontal drag keeps sending points
/// after it leaves the group. On release, the group presses the final item and sends None to clear the preview.
/// `on_close` (a `Tab` list's item alone): the tab closes, `closes` saying while it may; Delete or Backspace on it
/// closes it, as `RadioItem::close` does, the keyboard handed on to the tab then chosen where it was on this one.
/// `in_node`: the item is `parent` itself (the slot a structure made for it: a row of `View::each`), said to be what it
/// is and no node more, as `radio_group`'s and a menu's items are. Its node.
#callsite(autofill(loc))
pub fn[K : Eq] RadioGroup::item(
  self : RadioGroup[K],
  parent : @view.View,
  key : () -> K,
  label : () -> String,
  look : (@view.View, RadioItem) -> Unit,
  disabled? : () -> Bool = fn() { false },
  space_only? : Bool = false,
  slop? : Double,
  slide? : (Double, (@view.Drag?) -> K?),
  on_close? : () -> Unit,
  closes? : () -> Bool = fn() { true },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || disabled() }
    let able = fn() { !off() }
    let on = fn() { (self.now)() == key() }
    self.items.push({ node: v, key, off: disabled })
    self.rove.add(v, disabled=off)
    v.owns(fn() {
      self.items.retain(fn(e) { e.node.id() != v.id() })
      self.stops.retain(fn(s) { s.0.id() != v.id() })
    })
    |> ignore
    let close = match on_close {
      Some(f) if self.kind is Tab =>
        fn() {
          if !off() && closes() {
            // (the keyboard handed on only where it was on this tab)
            if v.focused() {
              self.refocus.val = Some((v, key()))
            }
            f()
            self.hand_on()
          }
        }
      _ => fn() {  }
    }
    look(v, { node: v, now: on, off, close_: close })
    if on_close is Some(_) && self.kind is Tab {
      v.on_key(fn(e) {
        if e.mods == 0 && (e.code == group_key_delete || e.code == group_key_backspace) && v.focused() && !off() && closes() {
          close()
          true
        } else {
          false
        }
      })
      |> ignore
    }
    if slop is Some(s) {
      let on_it = fn(d : @view.Drag) { v.finger_target(d.wx, d.wy) }
      match slide {
        None =>
          v.gesture(
            s,
            tap=fn(d) { if on_it(d) { v.press() |> ignore } },
            drag=fn(d) { if d.kind == Up && on_it(d) { v.press() |> ignore } },
          )
          |> ignore
        Some((hold_ms, preview)) => {
          let horizontal : Ref[Bool?] = Ref(None)
          let across = fn(d : @view.Drag) { (d.x - d.ox).abs() > (d.y - d.oy).abs() }
          let tap = fn(d : @view.Drag) {
            if on_it(d) {
              v.press() |> ignore
            }
            preview(None) |> ignore
          }
          v.gesture(
            s,
            press=fn(_) { horizontal.val = None },
            tap~,
            hold=(hold_ms, fn(d) { preview(Some(d)) |> ignore }),
            hold_yields=true,
            drag=fn(d) {
              match d.kind {
                Down | Moved => {
                  if d.kind == Down {
                    horizontal.val = Some(across(d))
                  }
                  preview(if horizontal.val == Some(true) { Some(d) } else { None }) |> ignore
                }
                Up if horizontal.val.unwrap_or(across(d)) => {
                  match preview(Some(d)) {
                    Some(k) =>
                      for i = 0; i < self.items.length(); i = i + 1 {
                        let item = self.items[i]
                        if item.node.alive() && !(item.off)() && (item.key)() == k {
                          item.node.press() |> ignore
                          break
                        }
                      }
                    None => if on_it(d) { v.press() |> ignore }
                  }
                  preview(None) |> ignore
                }
                Up => tap(d)
                Off => preview(None) |> ignore
              }
            },
          )
          |> ignore
        }
      }
    }
    let stop = fn() {
      let cur = (self.now)()
      let mut any_on = false
      let mut first_id : @view.NodeId? = None
      for e in self.items {
        if e.node.alive() {
          let e_off = (e.off)()
          let e_key = (e.key)()
          if !e_off {
            if first_id is None {
              first_id = Some(e.node.id())
            }
            if e_key == cur {
              any_on = true
            }
          }
        }
      }
      if off() {
        false
      } else if on() {
        true
      } else if any_on {
        false
      } else {
        first_id == Some(v.id())
      }
    }
    let keys = if space_only { @view.focus_space } else { @view.focus_enter | @view.focus_space }
    v
    .presses(By(able))
    .focusable(By(able), keys~)
    .says(By(fn() {
      let now = on()
      Some(
        match self.kind {
          Radio =>
            if self.selected {
              @view.said(Radio, label=label(), selected=now)
            } else {
              @view.said(Radio, label=label(), check=if now { On } else { Off })
            }
          Tab => @view.said(Tab, label=label(), selected=now)
        },
      )
    }))
    .on_press(fn() {
      if !off() {
        let k = key()
        if (self.now)() != k {
          (self.choose)(k)
        }
      }
    })
    |> ignore
    let bind_stop = fn() { v.tab_stop(By(stop)) |> ignore }
    self.stops.push((v, bind_stop))
    if !self.building.val {
      for s in self.stops {
        if s.0.alive() {
          (s.1)()
        }
      }
    }
    // (the tab chosen after a close made only now: the keyboard handed on to it)
    if self.refocus.val is Some(_) && !self.building.val {
      self.hand_on()
    }
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
