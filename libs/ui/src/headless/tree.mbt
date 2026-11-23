// Hierarchical tree control (`Tree[K]`) and pure tri-state cascade check logic (`tree_checked_states`,
// `toggle_tree_check`). Read out a `Listbox` of `Option` items with `expanded`, `selected`, optional `check`, and
// `description="level N"`. Reuses `RovingFocus`, `FocusRecovery` (recovering to the collapsing parent/ancestor when a
// focused descendant unmounts), `Typeahead`, and `SelectionModel`. Nothing here is drawn or laid out.

///|
/// Tri-state checkbox value for a tree node.
#derive(Eq, Debug)
pub(all) enum TreeCheckState {
  Unchecked
  Checked
  Indeterminate
}

///|
/// Strategy for computing and toggling tree check states: `Cascade` aggregates enabled descendant leaves upward and
/// toggles entire enabled subtrees; `Independent` checks each node on its own.
#derive(Eq, Debug)
pub(all) enum TreeCheckStrategy {
  Cascade
  Independent
}

///|
/// Minimal structural description of a node for pure tri-state check calculations.
#derive(Eq, Debug)
pub(all) struct TreeCheckNode[K] {
  key : K
  children : Array[K]
  disabled : Bool
}

///|
/// Find a `TreeCheckNode` by `key` in `nodes`.
fn[K : Eq] find_check_node(nodes : Array[TreeCheckNode[K]], key : K) -> TreeCheckNode[K]? {
  nodes.iter().find_first(fn(n) { n.key == key })
}

///|
/// Collect all enabled (non-disabled) leaf keys under `key` into `out`, tracking `visited` to guard against cycles.
fn[K : Eq] collect_enabled_leaves(
  nodes : Array[TreeCheckNode[K]],
  key : K,
  visited : Array[K],
  out : Array[K],
) -> Unit {
  if visited.contains(key) {
    return
  }
  visited.push(key)
  match find_check_node(nodes, key) {
    None => out.push(key)
    Some(n) => {
      if n.disabled {
        return
      }
      if n.children.is_empty() {
        out.push(n.key)
      } else {
        for c in n.children {
          collect_enabled_leaves(nodes, c, visited, out)
        }
      }
    }
  }
}

///|
/// Collect all enabled node keys in the subtree rooted at `key` (including `key` itself when not disabled).
fn[K : Eq] collect_enabled_subtree(
  nodes : Array[TreeCheckNode[K]],
  key : K,
  visited : Array[K],
  out : Array[K],
) -> Unit {
  if visited.contains(key) {
    return
  }
  visited.push(key)
  match find_check_node(nodes, key) {
    None => out.push(key)
    Some(n) => {
      if n.disabled {
        return
      }
      out.push(n.key)
      for c in n.children {
        collect_enabled_subtree(nodes, c, visited, out)
      }
    }
  }
}

///|
/// Compute the tri-state check status `(key, TreeCheckState)` for every node in `nodes` given `checked` keys.
/// In `Cascade` mode, parent states aggregate upward from enabled descendant leaves (all checked -> `Checked`,
/// some checked -> `Indeterminate`, none checked -> `Unchecked`; disabled leaves are skipped).
pub fn[K : Eq] tree_checked_states(
  nodes : Array[TreeCheckNode[K]],
  checked : Array[K],
  strategy? : TreeCheckStrategy = Cascade,
) -> Array[(K, TreeCheckState)] {
  let out : Array[(K, TreeCheckState)] = []
  for n in nodes {
    let state = match strategy {
      Independent => if checked.contains(n.key) { Checked } else { Unchecked }
      Cascade =>
        if n.children.is_empty() {
          if checked.contains(n.key) {
            Checked
          } else {
            Unchecked
          }
        } else {
          let leaves : Array[K] = []
          let visited : Array[K] = [n.key]
          for c in n.children {
            collect_enabled_leaves(nodes, c, visited, leaves)
          }
          if leaves.is_empty() {
            if checked.contains(n.key) {
              Checked
            } else {
              Unchecked
            }
          } else {
            let mut hit = 0
            for leaf in leaves {
              if checked.contains(leaf) {
                hit = hit + 1
              }
            }
            if hit == 0 {
              Unchecked
            } else if hit == leaves.length() {
              Checked
            } else {
              Indeterminate
            }
          }
        }
    }
    out.push((n.key, state))
  }
  out
}

///|
/// Toggle `key` in `checked` according to `strategy`. Disabled nodes are no-ops.
/// In `Cascade` mode, toggling a branch node checks all its enabled descendant leaves (unless all are already checked,
/// in which case all enabled descendants are unchecked).
pub fn[K : Eq] toggle_tree_check(
  nodes : Array[TreeCheckNode[K]],
  checked : Array[K],
  key : K,
  strategy? : TreeCheckStrategy = Cascade,
) -> Array[K] {
  let target = find_check_node(nodes, key)
  if target is Some(n) && n.disabled {
    return checked.copy()
  }
  match strategy {
    Independent =>
      if checked.contains(key) {
        checked.filter(fn(k) { k != key })
      } else {
        checked + [key]
      }
    Cascade =>
      match target {
        Some(n) if !n.children.is_empty() => {
          let leaves : Array[K] = []
          let visited_l : Array[K] = [n.key]
          for c in n.children {
            collect_enabled_leaves(nodes, c, visited_l, leaves)
          }
          if leaves.is_empty() {
            return checked.copy()
          }
          let all_checked = leaves.iter().all(fn(k) { checked.contains(k) })
          let subtree : Array[K] = []
          let visited_s : Array[K] = []
          collect_enabled_subtree(nodes, n.key, visited_s, subtree)
          let base = checked.filter(fn(k) { !subtree.contains(k) })
          if all_checked {
            base
          } else {
            let next = base.copy()
            for leaf in leaves {
              if !next.contains(leaf) {
                next.push(leaf)
              }
            }
            next
          }
        }
        _ =>
          if checked.contains(key) {
            checked.filter(fn(k) { k != key })
          } else {
            checked + [key]
          }
      }
  }
}

///|
/// One registered item of a `Tree[K]`.
priv struct TreeEntry[K] {
  node : @view.View
  key : K
  parent_key : K?
  has_children : () -> Bool
  off : () -> Bool
  text : () -> String
}

///|
/// A hierarchical tree handed to its look to register visible tree items via `Tree::item`.
pub struct Tree[K] {
  priv is_selected : (K) -> Bool
  priv pick : (K) -> Unit
  priv is_expanded : (K) -> Bool
  priv set_expanded : (K, Bool) -> Unit
  priv multiple : Bool
  priv off : () -> Bool
  priv rove : RovingFocus
  priv recovery : FocusRecovery
  priv entries : Array[TreeEntry[K]]
  priv typeahead : Typeahead
  priv selection : SelectionModel[@view.NodeId]
}

///|
/// Whether the whole tree is disabled (as its caller says).
pub fn[K] Tree::disabled(self : Tree[K]) -> Bool {
  (self.off)()
}

///|
/// Whether several tree items may be selected at once.
pub fn[K] Tree::multiple(self : Tree[K]) -> Bool {
  self.multiple
}

///|
/// Ask keyboard focus onto the tree's current Tab stop, shown where `visible`. Returns whether an item took focus.
pub fn[K] Tree::focus_stop(self : Tree[K], visible? : Bool = true) -> Bool {
  self.rove.focus_stop(visible~)
}

///|
/// Ask keyboard focus onto the visible enabled item matching `key`, shown where `visible`.
pub fn[K : Eq] Tree::focus_key(self : Tree[K], key : K, visible? : Bool = true) -> Bool {
  match self.entries.iter().find_first(fn(e) { e.key == key && e.node.takes_input() && !(e.off)() }) {
    Some(e) => e.node.ask_focus(visible~)
    None => false
  }
}

///|
/// One item of a `Tree[K]` as its look reads it: each a reading, followed where a binding reads it.
pub struct TreeItem {
  priv node : @view.View
  priv on : () -> Bool
  priv exp : () -> Bool
  priv has_kids : () -> Bool
  priv lvl : Int
  priv chk : () -> TreeCheckState?
  priv off : () -> Bool
}

///|
/// Whether this item is selected now (as its caller says).
pub fn TreeItem::selected(self : TreeItem) -> Bool {
  (self.on)()
}

///|
/// Whether this item is expanded now (as its caller says).
pub fn TreeItem::expanded(self : TreeItem) -> Bool {
  (self.exp)()
}

///|
/// Whether this item has children (as its caller says).
pub fn TreeItem::has_children(self : TreeItem) -> Bool {
  (self.has_kids)()
}

///|
/// The 1-based depth level of this item in the tree.
pub fn TreeItem::level(self : TreeItem) -> Int {
  self.lvl
}

///|
/// The tri-state check state of this item, if any.
pub fn TreeItem::check(self : TreeItem) -> TreeCheckState? {
  (self.chk)()
}

///|
/// Whether this item is disabled (either the tree or the item itself).
pub fn TreeItem::disabled(self : TreeItem) -> Bool {
  (self.off)()
}

///|
/// Whether this item has the keyboard's focus (View::focused).
pub fn TreeItem::focused(self : TreeItem) -> Bool {
  self.node.focused()
}

///|
/// Whether this item has the keyboard's focus and that shows (View::focus_shown).
pub fn TreeItem::focus_shown(self : TreeItem) -> Bool {
  self.node.focus_shown()
}

///|
/// Whether a pointer rests over this item now (View::pointed).
pub fn TreeItem::hovered(self : TreeItem) -> Bool {
  self.node.pointed()
}

///|
/// Whether a finger or the pointer is held on this item now (View::pressed).
pub fn TreeItem::pressed(self : TreeItem) -> Bool {
  self.node.pressed()
}

///|
/// Map a list of item NodeIds back to their caller keys in order.
fn[K] Tree::keys_of(self : Tree[K], ids : Array[@view.NodeId]) -> Array[K] {
  let out : Array[K] = []
  for id in ids {
    match self.entries.iter().find_first(fn(e) { e.node.id() == id }) {
      Some(e) => out.push(e.key)
      None => ()
    }
  }
  out
}

///|
/// All living item NodeIds in registration order, currently selected IDs, and a disabled predicate on NodeId.
fn[K] Tree::selection_inputs(
  self : Tree[K],
) -> (Array[@view.NodeId], Array[@view.NodeId], (@view.NodeId) -> Bool) {
  let all_ids : Array[@view.NodeId] = []
  let cur_ids : Array[@view.NodeId] = []
  for e in self.entries {
    if e.node.alive() {
      let id = e.node.id()
      all_ids.push(id)
      if @signals.untracked(fn() { (self.is_selected)(e.key) }) {
        cur_ids.push(id)
      }
    }
  }
  let is_off = fn(id : @view.NodeId) -> Bool {
    match self.entries.iter().find_first(fn(e) { e.node.id() == id }) {
      Some(e) => !e.node.takes_input() || @signals.untracked(e.off)
      None => true
    }
  }
  (all_ids, cur_ids, is_off)
}

///|
/// Find the nearest living enabled ancestor node of `start_parent` by walking `parent_key` links.
fn[K : Eq] Tree::living_ancestor(self : Tree[K], start_parent : K?, exclude_id : @view.NodeId) -> @view.View? {
  let visited : Array[K] = []
  let mut cur = start_parent
  while cur is Some(pk) {
    if visited.contains(pk) {
      break
    }
    visited.push(pk)
    match self.entries.iter().find_first(fn(e) { e.key == pk }) {
      Some(e) =>
        if e.node.id() != exclude_id &&
          e.node.alive() &&
          @signals.untracked(fn() { e.node.takes_input() && !(e.off)() }) {
          return Some(e.node)
        } else {
          cur = e.parent_key
        }
      None => break
    }
  }
  None
}

///|
/// Convert `TreeCheckState?` to `@view.Check?` for screen-reader `Said`.
fn tree_check_to_said(state : TreeCheckState?) -> @view.Check? {
  match state {
    Some(Unchecked) => Some(@view.Check::Off)
    Some(Checked) => Some(@view.Check::On)
    Some(Indeterminate) => Some(@view.Check::Mixed)
    None => None
  }
}

///|
/// A hierarchical tree in `parent` (`parent` itself where `in_node`), called `label`, with selection (`is_selected`,
/// `pick`, optional `multiple` + `on_select_many`) and expansion (`is_expanded`, `set_expanded`). Implements WAI-ARIA
/// Tree keyboard navigation (`↓`/`↑`/`Home`/`End`, `→`/`←` expand/collapse/descend/ascend respecting `rtl`,
/// typeahead, `Enter`/`Space` activate) and parent-first focus recovery when collapsing unmounts a focused descendant.
#callsite(autofill(loc))
pub fn[K : Eq] tree(
  parent : @view.View,
  label : () -> String,
  is_selected : (K) -> Bool,
  pick : (K) -> Unit,
  is_expanded : (K) -> Bool,
  set_expanded : (K, Bool) -> Unit,
  look : (@view.View, Tree[K]) -> Unit,
  rtl? : Bool = false,
  multiple? : Bool = false,
  on_select_many? : (Array[K]) -> Unit,
  typeahead_ms? : Double = 500.0,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let tr : Tree[K] = {
    is_selected,
    pick,
    is_expanded,
    set_expanded,
    multiple,
    off: disabled,
    rove: RovingFocus::new(axis=Vertical, roving=true, wraps=false),
    recovery: FocusRecovery::new(),
    entries: [],
    typeahead: Typeahead::new(window_ms=typeahead_ms),
    selection: SelectionModel::new(multiple~),
  }
  let expand_key = if rtl { group_key_left } else { group_key_right }
  let collapse_key = if rtl { group_key_right } else { group_key_left }
  let setup = fn(v : @view.View) {
    look(v, tr)
    v
    .says(By(fn() { Some(@view.said(Listbox, label=label())) }))
    .on_key(fn(k) {
      if disabled() || !focus_in(v, false) {
        return false
      }
      if multiple && on_select_many is Some(many) {
        let is_select_all = (k.code == listbox_key_select_all && (k.mods == 0 || k.mods == mod_ctrl || k.mods == mod_cmd)) ||
          ((k.mods == mod_ctrl || k.mods == mod_cmd) &&
            (k.code == typeahead_key_char + 'a'.to_int() || k.code == typeahead_key_char + 'A'.to_int()))
        if is_select_all {
          let (all_ids, _, is_off) = tr.selection_inputs()
          let next_ids = tr.selection.select_all(all_ids, disabled=is_off)
          many(tr.keys_of(next_ids))
          return true
        }
        if k.mods == mod_shift &&
          (k.code == group_key_down || k.code == group_key_up || k.code == group_key_home || k.code == group_key_end) {
          if tr.selection.anchor() is None {
            if v.tree.focused_now().0 is Some(f) {
              tr.selection.set_anchor(Some(f))
            }
          }
          if tr.rove.step(k.code) is Some(target) {
            let (all_ids, cur_ids, is_off) = tr.selection_inputs()
            let next_ids = tr.selection.select_range(all_ids, cur_ids, target.id(), disabled=is_off)
            many(tr.keys_of(next_ids))
            return true
          }
        }
      }
      if k.mods == 0 {
        if k.code == expand_key {
          if v.tree.focused_now().0 is Some(fid) {
            match tr.entries.iter().find_first(fn(e) { e.node.id() == fid }) {
              Some(e) =>
                if (e.has_children)() {
                  if !(tr.is_expanded)(e.key) {
                    (tr.set_expanded)(e.key, true)
                    return true
                  } else {
                    match
                      tr.entries
                      .iter()
                      .find_first(fn(c) {
                        c.parent_key == Some(e.key) && c.node.takes_input() && !(c.off)()
                      }) {
                      Some(child) => {
                        child.node.ask_focus(visible=true) |> ignore
                        return true
                      }
                      None => return true
                    }
                  }
                }
              None => ()
            }
          }
          return false
        }
        if k.code == collapse_key {
          if v.tree.focused_now().0 is Some(fid) {
            match tr.entries.iter().find_first(fn(e) { e.node.id() == fid }) {
              Some(e) =>
                if (e.has_children)() && (tr.is_expanded)(e.key) {
                  (tr.set_expanded)(e.key, false)
                  return true
                } else {
                  match tr.living_ancestor(e.parent_key, fid) {
                    Some(anc) => {
                      anc.ask_focus(visible=true) |> ignore
                      return true
                    }
                    None => ()
                  }
                }
              None => ()
            }
          }
          return false
        }
        if tr.rove.step(k.code) is Some(_) {
          return true
        }
      }
      let live = tr.rove.live()
      tr.typeahead.handle_key(k, live, fn(i) {
        let id = live[i].id()
        match tr.entries.iter().find_first(fn(x) { x.node.id() == id }) {
          Some(x) => (x.text)()
          None => ""
        }
      })
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
/// Register a visible tree item of `key` in `parent` (`parent` itself where `in_node`), with `label`, optional
/// `parent_key` (used for `←` parent navigation and collapse focus recovery), `has_children`, 1-based `level`,
/// optional tri-state `check`, optional typeahead `text`, and `disabled`. Its node.
#callsite(autofill(loc))
pub fn[K : Eq] Tree::item(
  self : Tree[K],
  parent : @view.View,
  key : K,
  label : () -> String,
  look : (@view.View, TreeItem) -> Unit,
  parent_key? : K,
  has_children? : () -> Bool = fn() { false },
  level? : Int = 1,
  check? : () -> TreeCheckState?,
  text? : () -> String,
  disabled? : () -> Bool = fn() { false },
  in_node? : Bool = false,
  made_for? : SourceLoc,
  loc~ : SourceLoc,
) -> @view.View {
  let setup = fn(v : @view.View) {
    let off = fn() { (self.off)() || disabled() }
    let able = fn() { !off() }
    let on = fn() { (self.is_selected)(key) }
    let exp = fn() { (self.is_expanded)(key) }
    let chk = match check {
      Some(f) => f
      None => fn() { None }
    }
    let removed_pos : Ref[Int?] = Ref(None)
    self.entries.push({ node: v, key, parent_key, has_children, off, text: text.unwrap_or(label) })
    let ancestor_fallback = fn() -> @view.View? {
      if self.living_ancestor(parent_key, v.id()) is Some(anc) {
        return Some(anc)
      }
      let n = self.entries.length()
      if n == 0 {
        return None
      }
      let (start_fwd, start_bwd) = match self.entries.search_by(fn(e) { e.node.id() == v.id() }) {
        Some(idx) => (idx + 1, idx - 1)
        None => {
          let p = removed_pos.val.unwrap_or(0)
          (p, p - 1)
        }
      }
      for i in start_fwd..<n {
        let e = self.entries[i]
        if e.node.id() != v.id() && e.node.alive() && e.node.takes_input() && !(e.off)() {
          return Some(e.node)
        }
      }
      let mut i = if start_bwd < n { start_bwd } else { n - 1 }
      while i >= 0 {
        let e = self.entries[i]
        if e.node.id() != v.id() && e.node.alive() && e.node.takes_input() && !(e.off)() {
          return Some(e.node)
        }
        i = i - 1
      }
      None
    }
    look(v, { node: v, on, exp, has_kids: has_children, lvl: level, chk, off })
    v
    .presses(By(able))
    .focusable(By(able), tab=false)
    .says(
      By(fn() {
        let expanded : Bool? = if has_children() { Some(exp()) } else { None }
        let check_said = tree_check_to_said(chk())
        Some(
          @view.said(
            @view.Role::Option,
            label=label(),
            description="level \{level}",
            selected=on(),
            expanded?=expanded,
            check?=check_said,
          ),
        )
      }),
    )
    .on_press(fn() {
      if off() {
        return
      }
      self.selection.set_anchor(Some(v.id()))
      if self.multiple || !on() {
        (self.pick)(key)
      }
    })
    |> ignore
    // Register ancestor-first focus recovery before `rove.add` so parent collapse returns focus to the parent node
    // rather than jumping to the next sibling.
    self.recovery.track_with(v, ancestor_fallback, false)
    v.owns(fn() {
      removed_pos.val = self.entries.search_by(fn(e) { e.node.id() == v.id() })
      self.entries.retain(fn(e) { e.node.id() != v.id() })
      if self.entries.is_empty() {
        self.entries.shrink_to_fit()
      }
    })
    |> ignore
    self.rove.add(v, disabled=off, preferred=on)
  }
  if in_node {
    setup(parent)
    parent
  } else {
    parent.box(loc~, made_for=made_for.unwrap_or(loc), setup)
  }
}
