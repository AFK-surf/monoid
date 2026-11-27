// WAI-ARIA APG interaction-pattern contract checker for Tester.
//
// `Tester::check_pattern` collects all structural, state, tab-stop, focus-invariant, and live keyboard-navigation
// faults for a given `AriaPattern` without aborting on unnamed nodes. `Tester::assert_pattern` fails with every
// collected fault formatted together.

///|
/// WAI-ARIA Authoring Practices Guide (APG) widget interaction patterns checked by `Tester::check_pattern`.
#derive(Eq, Debug)
pub(all) enum AriaPattern {
  Tabs
  Menu
  Dialog
  AlertDialog
  Listbox
  RadioGroup
  Accordion
  Disclosure
  Combobox
  Slider
  Switch
  Checkbox
  Toolbar
}

///|
fn AriaPattern::name(self : AriaPattern) -> String {
  match self {
    Tabs => "Tabs"
    Menu => "Menu"
    Dialog => "Dialog"
    AlertDialog => "AlertDialog"
    Listbox => "Listbox"
    RadioGroup => "RadioGroup"
    Accordion => "Accordion"
    Disclosure => "Disclosure"
    Combobox => "Combobox"
    Slider => "Slider"
    Switch => "Switch"
    Checkbox => "Checkbox"
    Toolbar => "Toolbar"
  }
}

///|
fn pattern_blank(s : String) -> Bool {
  s.iter().all(fn(c) { c == ' ' || c == '\t' || c == '\n' || c == '\r' })
}

///|
fn pattern_tag(s : SemNode) -> String {
  let lbl = if pattern_blank(s.label) { "<empty>" } else { s.label.escape() }
  "\{s.role}(label=\{lbl}, id=\{s.id})"
}

///|
fn pattern_fault(pattern : AriaPattern, rule : String, detail : String) -> String {
  "[ARIA/\{pattern.name()}] \{rule}: \{detail}"
}

///|
/// Semantics tree read without `Tester::hold_named` aborting on unnamed nodes, so `check_pattern` can collect
/// missing-label faults directly.
fn Tester::pattern_semantics(self : Tester) -> Array[SemNode] {
  self.reads_own()
  g().semantics_tree()
}

///|
/// The currently focused semantics node, if any (without halting on unnamed nodes).
fn Tester::pattern_focused(self : Tester) -> SemNode? {
  for s in self.pattern_semantics() {
    if s.focused {
      return Some(s)
    }
  }
  None
}

///|
/// Index range `(from, until)` of `within` (inclusive of `within` itself and all of its descendants) in `tree`.
/// Returns `(0, tree.length(), true)` when `within` is `None`, or `(0, 0, false)` when `within` is not found.
fn pattern_scope_range(tree : Array[SemNode], within : SemNode?) -> (Int, Int, Bool) {
  match within {
    None => (0, tree.length(), true)
    Some(w) => {
      let mut at = -1
      if w.id != 0 {
        for k, s in tree {
          if s.id == w.id && s.role == w.role {
            at = k
            break
          }
        }
      }
      if at < 0 {
        for k, s in tree {
          if s.id == w.id && s.role == w.role && s.label == w.label && s.depth == w.depth {
            at = k
            break
          }
        }
      }
      if at < 0 {
        (0, 0, false)
      } else {
        let mut end = at + 1
        while end < tree.length() && tree[end].depth > tree[at].depth {
          end = end + 1
        }
        (at, end, true)
      }
    }
  }
}

///|
/// Subtree `(from, until)` of the node at `root_idx` in `tree` (inclusive of `root_idx`).
fn pattern_subtree_range(tree : Array[SemNode], root_idx : Int) -> (Int, Int) {
  let mut end = root_idx + 1
  while end < tree.length() && tree[end].depth > tree[root_idx].depth {
    end = end + 1
  }
  (root_idx, end)
}

///|
/// Visible nodes matching `role` in `tree[from..<until]`, returned with their indices in `tree`.
fn pattern_visible_role(tree : Array[SemNode], from : Int, until : Int, role : Role) -> Array[(Int, SemNode)] {
  let out : Array[(Int, SemNode)] = []
  for k in from..<until {
    let s = tree[k]
    if !s.hidden && s.role == role {
      out.push((k, s))
    }
  }
  out
}

///|
/// Re-find a semantics node by its `id` in a freshly read `tree`.
fn pattern_find_id(tree : Array[SemNode], id : Int) -> SemNode? {
  if id == 0 {
    return None
  }
  for s in tree {
    if s.id == id {
      return Some(s)
    }
  }
  None
}

///|
/// Whether `s` is currently in the tree's Tab focus order.
fn pattern_is_tab_stop(s : SemNode, order : Array[@view.FocusAt]) -> Bool {
  match tree_said_ids.get(s.id) {
    Some(nid) => arr_any(order, fn(f) { f.id == nid })
    None => false
  }
}

///|
/// Explicit label declared on a container node (for tree nodes, reads `@view.Said::label` directly so a container
/// with `label=""` does not accidentally inherit a child button's text as its own accessible name).
fn pattern_container_label(s : SemNode) -> String {
  match (tree_said_ids.get(s.id), view_app.val) {
    (Some(nid), Some(tree)) =>
      match tree.said_of(nid) {
        Some(said) => said.label
        None => s.label
      }
    _ => s.label
  }
}

///|
/// Whether `s` declares `target` in its accessibility actions (checks both `SemNode.actions` and `@view.Said.actions`).
fn pattern_has_action(s : SemNode, target : Action) -> Bool {
  if arr_any(s.actions, fn(a) { a == target }) {
    return true
  }
  match (tree_said_ids.get(s.id), view_app.val) {
    (Some(nid), Some(tree)) =>
      match tree.said_of(nid) {
        Some(said) => arr_any(said.actions, fn(a) { a == target })
        None => false
      }
    _ => false
  }
}

///|
/// Whether `s` is modal (checks `SemNode.modal` as well as the window tree's active modal layer `Tree::modal_top`).
fn pattern_is_modal(s : SemNode) -> Bool {
  if s.modal {
    return true
  }
  match (tree_said_ids.get(s.id), view_app.val) {
    (Some(nid), Some(tree)) =>
      match tree.modal_top() {
        Some(top) => top == nid || tree.holds(top, nid)
        None => false
      }
    _ => false
  }
}

///|
/// Whether `s` can take keyboard focus (either via Tab or programmatically, e.g. roving items / dialog ground).
fn pattern_can_focus(s : SemNode) -> Bool {
  if s.hidden || s.disabled {
    return false
  }
  match (tree_said_ids.get(s.id), view_app.val) {
    (Some(nid), Some(tree)) => tree.focus_asked_takes(nid)
    _ => s.focused
  }
}

///|
/// Verify that exactly one node in `items` is a Tab stop.
fn check_single_tab_stop(
  pattern : AriaPattern,
  group : SemNode,
  items : Array[SemNode],
  faults : Array[String],
) -> Unit {
  guard view_tree() is Some(tree) else { return }
  let order = tree.focus_order()
  let stops : Array[SemNode] = []
  for item in items {
    if pattern_is_tab_stop(item, order) {
      stops.push(item)
    }
  }
  if stops.length() != 1 {
    let names = stops.map(pattern_tag).join(", ")
    faults.push(
      pattern_fault(
        pattern,
        "single-tab-stop",
        "expected exactly 1 tab stop among enabled items of \{pattern_tag(group)}, found \{stops.length()} [\{names}]",
      ),
    )
  }
}

///|
/// Verify the focus invariant on `tree`: focus must never rest on a `hidden` or `disabled` node.
fn check_focus_invariant(
  pattern : AriaPattern,
  step : String,
  tree : Array[SemNode],
  faults : Array[String],
) -> SemNode? {
  let mut focused : SemNode? = None
  for s in tree {
    if s.focused {
      focused = Some(s)
      if s.hidden {
        faults.push(
          pattern_fault(pattern, "focus-invariant", "after \{step}, focus landed on hidden node \{pattern_tag(s)}"),
        )
      }
      if s.disabled {
        faults.push(
          pattern_fault(pattern, "focus-invariant", "after \{step}, focus landed on disabled node \{pattern_tag(s)}"),
        )
      }
      break
    }
  }
  focused
}

///|
/// Focus `s` via the accessibility `Focus` action and settle one frame; returns whether `s` now has focus.
fn Tester::pattern_focus_node(
  self : Tester,
  pattern : AriaPattern,
  s : SemNode,
  faults : Array[String],
) -> Bool {
  if s.id == 0 {
    faults.push(pattern_fault(pattern, "focus-target", "cannot focus \{pattern_tag(s)} (no semantic id)"))
    return false
  }
  g().ask_action(s.id, Focus)
  self.draw()
  let tree = self.pattern_semantics()
  let focused = check_focus_invariant(pattern, "focus(\{pattern_tag(s)})", tree, faults)
  match focused {
    Some(f) if f.id == s.id => true
    Some(f) => {
      faults.push(
        pattern_fault(pattern, "focus-target", "failed to focus \{pattern_tag(s)}; focus is on \{pattern_tag(f)}"),
      )
      false
    }
    None => {
      faults.push(pattern_fault(pattern, "focus-target", "failed to focus \{pattern_tag(s)}; focus is None"))
      false
    }
  }
}

///|
/// Send a key and immediately enforce the focus invariant on the resulting semantics tree.
fn Tester::pattern_press_key(
  self : Tester,
  pattern : AriaPattern,
  code : Int,
  step : String,
  faults : Array[String],
  mods? : Int = 0,
) -> (Array[SemNode], SemNode?) {
  self.key(code, mods~)
  let tree = self.pattern_semantics()
  let focused = check_focus_invariant(pattern, step, tree, faults)
  (tree, focused)
}

///|
fn pattern_in_list(items : Array[SemNode], id : Int) -> Bool {
  id != 0 && items.iter().any(fn(item) { item.id == id })
}

///|
fn radio_selected_state(s : SemNode) -> Bool? {
  match (s.check, s.selected) {
    (Some(On), _) => Some(true)
    (Some(Off), _) => Some(false)
    (Some(Mixed), _) => Some(false)
    (None, Some(v)) => Some(v)
    (None, None) => None
  }
}

///|
fn pattern_is_toolbar_control(s : SemNode) -> Bool {
  match s.role {
    Button
    | Checkbox
    | Switch
    | Radio
    | Combobox
    | Slider
    | TextField
    | Link
    | MenuItem
    | MenuItemCheckbox
    | MenuItemRadio
    | Tab
    | Option => true
    _ => pattern_can_focus(s) || !s.actions.is_empty()
  }
}

///|
fn Tester::check_tabs(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  rtl : Bool,
  faults : Array[String],
) -> Unit {
  let lists = pattern_visible_role(tree, from, until, TabList)
  if lists.is_empty() {
    faults.push(pattern_fault(Tabs, "missing-role", "no visible TabList found in scope"))
    return
  }
  let (tl_idx, tl) = lists[0]
  if pattern_blank(pattern_container_label(tl)) {
    faults.push(pattern_fault(Tabs, "missing-label", "TabList \{pattern_tag(tl)} has empty label"))
  }
  let (tl_from, tl_until) = pattern_subtree_range(tree, tl_idx)
  let tab_pairs = pattern_visible_role(tree, tl_from + 1, tl_until, Tab)
  let tabs = tab_pairs.map(fn(p) { p.1 })
  let mut selected_count = 0
  for tab in tabs {
    if pattern_blank(tab.label) {
      faults.push(pattern_fault(Tabs, "missing-label", "Tab \{pattern_tag(tab)} has empty label"))
    }
    match tab.selected {
      Some(true) => selected_count += 1
      Some(false) => ()
      None => faults.push(pattern_fault(Tabs, "missing-state", "Tab \{pattern_tag(tab)} missing selected state"))
    }
  }
  let enabled = tabs.filter(fn(t) { !t.disabled })
  if enabled.length() < 2 {
    faults.push(
      pattern_fault(
        Tabs,
        "insufficient-items",
        "TabList \{pattern_tag(tl)} requires at least 2 enabled Tab nodes, found \{enabled.length()}",
      ),
    )
  }
  if selected_count != 1 {
    faults.push(
      pattern_fault(
        Tabs,
        "selection-count",
        "TabList \{pattern_tag(tl)} must have exactly 1 selected Tab, found \{selected_count}",
      ),
    )
  }
  let panels = pattern_visible_role(tree, from, until, TabPanel)
  if panels.is_empty() {
    faults.push(pattern_fault(Tabs, "missing-role", "no visible TabPanel associated with \{pattern_tag(tl)}"))
  }
  if enabled.length() >= 1 {
    check_single_tab_stop(Tabs, tl, enabled, faults)
  }
  if enabled.length() < 2 {
    return
  }
  let start = match enabled.iter().find_first(fn(t) { t.selected == Some(true) }) {
    Some(t) => t
    None => enabled[0]
  }
  if !self.pattern_focus_node(Tabs, start, faults) {
    return
  }
  let next_key = if rtl { key_left } else { key_right }
  let prev_key = if rtl { key_right } else { key_left }
  let next_name = if rtl { "ArrowLeft (rtl next)" } else { "ArrowRight" }
  let prev_name = if rtl { "ArrowRight (rtl prev)" } else { "ArrowLeft" }
  let (after_next_tree, after_next_focus) = self.pattern_press_key(Tabs, next_key, next_name, faults)
  match after_next_focus {
    Some(f) if f.id != start.id && pattern_in_list(enabled, f.id) => {
      if f.selected != Some(true) {
        // Manual activation mode: Space or Enter must select the focused tab.
        let (_, after_space) = self.pattern_press_key(Tabs, key_space, "Space (manual tab activate)", faults)
        let selected_now = match after_space {
          Some(fs) if fs.id == f.id => fs.selected == Some(true)
          _ =>
            match pattern_find_id(self.pattern_semantics(), f.id) {
              Some(n) => n.selected == Some(true)
              None => false
            }
        }
        if !selected_now {
          let (_, after_enter) = self.pattern_press_key(Tabs, key_enter, "Enter (manual tab activate)", faults)
          let selected_enter = match after_enter {
            Some(fe) if fe.id == f.id => fe.selected == Some(true)
            _ =>
              match pattern_find_id(self.pattern_semantics(), f.id) {
                Some(n) => n.selected == Some(true)
                None => false
              }
          }
          if !selected_enter {
            faults.push(
              pattern_fault(
                Tabs,
                "keyboard-activation",
                "\{next_name} moved focus to \{pattern_tag(f)} without selecting it, and neither Space nor Enter activated it",
              ),
            )
          }
        }
      }
      let moved_id = f.id
      let (_, after_prev_focus) = self.pattern_press_key(Tabs, prev_key, prev_name, faults)
      match after_prev_focus {
        Some(fp) if fp.id != moved_id && pattern_in_list(enabled, fp.id) => ()
        _ =>
          faults.push(
            pattern_fault(
              Tabs,
              "keyboard-nav",
              "\{prev_name} from \{pattern_tag(f)} did not move focus to another enabled Tab",
            ),
          )
      }
    }
    _ => {
      ignore(after_next_tree)
      faults.push(
        pattern_fault(
          Tabs,
          "keyboard-nav",
          "\{next_name} from \{pattern_tag(start)} did not move focus to another enabled Tab",
        ),
      )
    }
  }
  let last_tab = enabled[enabled.length() - 1]
  let first_tab = enabled[0]
  let (_, after_end) = self.pattern_press_key(Tabs, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_tab.id => ()
    _ =>
      faults.push(
        pattern_fault(Tabs, "keyboard-nav", "End did not move focus to last enabled Tab \{pattern_tag(last_tab)}"),
      )
  }
  let (_, after_home) = self.pattern_press_key(Tabs, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_tab.id => ()
    _ =>
      faults.push(
        pattern_fault(Tabs, "keyboard-nav", "Home did not move focus to first enabled Tab \{pattern_tag(first_tab)}"),
      )
  }
}

///|
fn Tester::check_radio_group(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  rtl : Bool,
  faults : Array[String],
) -> Unit {
  let groups = pattern_visible_role(tree, from, until, RadioGroup)
  if groups.is_empty() {
    faults.push(pattern_fault(RadioGroup, "missing-role", "no visible RadioGroup found in scope"))
    return
  }
  let (rg_idx, rg) = groups[0]
  if pattern_blank(pattern_container_label(rg)) {
    faults.push(pattern_fault(RadioGroup, "missing-label", "RadioGroup \{pattern_tag(rg)} has empty label"))
  }
  let (rg_from, rg_until) = pattern_subtree_range(tree, rg_idx)
  let radios = pattern_visible_role(tree, rg_from + 1, rg_until, Radio).map(fn(p) { p.1 })
  let mut selected_count = 0
  for r in radios {
    if pattern_blank(r.label) {
      faults.push(pattern_fault(RadioGroup, "missing-label", "Radio \{pattern_tag(r)} has empty label"))
    }
    match radio_selected_state(r) {
      Some(true) => selected_count += 1
      Some(false) => ()
      None =>
        faults.push(
          pattern_fault(RadioGroup, "missing-state", "Radio \{pattern_tag(r)} missing both check and selected state"),
        )
    }
  }
  if selected_count > 1 {
    faults.push(
      pattern_fault(
        RadioGroup,
        "selection-count",
        "RadioGroup \{pattern_tag(rg)} may have at most 1 selected Radio, found \{selected_count}",
      ),
    )
  }
  let enabled = radios.filter(fn(r) { !r.disabled })
  if enabled.length() < 2 {
    faults.push(
      pattern_fault(
        RadioGroup,
        "insufficient-items",
        "RadioGroup \{pattern_tag(rg)} requires at least 2 enabled Radio nodes, found \{enabled.length()}",
      ),
    )
  }
  if enabled.length() >= 1 {
    check_single_tab_stop(RadioGroup, rg, enabled, faults)
  }
  if enabled.length() < 2 {
    return
  }
  let start = match enabled.iter().find_first(fn(r) { radio_selected_state(r) == Some(true) }) {
    Some(r) => r
    None => enabled[0]
  }
  if !self.pattern_focus_node(RadioGroup, start, faults) {
    return
  }
  let h_next = if rtl { key_left } else { key_right }
  let h_prev = if rtl { key_right } else { key_left }
  let h_next_name = if rtl { "ArrowLeft (rtl next)" } else { "ArrowRight" }
  let h_prev_name = if rtl { "ArrowRight (rtl prev)" } else { "ArrowLeft" }
  // Auto-detect horizontal vs vertical orientation.
  let (_, try_h) = self.pattern_press_key(RadioGroup, h_next, h_next_name, faults)
  let (moved, prev_key, prev_name) : (SemNode?, Int, String) = match try_h {
    Some(f) if f.id != start.id && pattern_in_list(enabled, f.id) => (Some(f), h_prev, h_prev_name)
    _ => {
      let (_, try_v) = self.pattern_press_key(RadioGroup, key_down, "ArrowDown", faults)
      match try_v {
        Some(f) if f.id != start.id && pattern_in_list(enabled, f.id) => (Some(f), key_up, "ArrowUp")
        _ => (None, h_prev, h_prev_name)
      }
    }
  }
  match moved {
    Some(f) => {
      if radio_selected_state(f) != Some(true) {
        faults.push(
          pattern_fault(
            RadioGroup,
            "keyboard-selection",
            "arrow navigation moved focus to \{pattern_tag(f)} without selecting it",
          ),
        )
      }
      let (_, after_prev) = self.pattern_press_key(RadioGroup, prev_key, prev_name, faults)
      match after_prev {
        Some(fp) if fp.id != f.id && pattern_in_list(enabled, fp.id) =>
          if radio_selected_state(fp) != Some(true) {
            faults.push(
              pattern_fault(
                RadioGroup,
                "keyboard-selection",
                "\{prev_name} moved focus to \{pattern_tag(fp)} without selecting it",
              ),
            )
          }
        _ =>
          faults.push(
            pattern_fault(
              RadioGroup,
              "keyboard-nav",
              "\{prev_name} from \{pattern_tag(f)} did not move focus to another enabled Radio",
            ),
          )
      }
    }
    None =>
      faults.push(
        pattern_fault(
          RadioGroup,
          "keyboard-nav",
          "neither \{h_next_name} nor ArrowDown moved focus from \{pattern_tag(start)} to another enabled Radio",
        ),
      )
  }
  let last_r = enabled[enabled.length() - 1]
  let first_r = enabled[0]
  let (_, after_end) = self.pattern_press_key(RadioGroup, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_r.id =>
      if radio_selected_state(fe) != Some(true) {
        faults.push(pattern_fault(RadioGroup, "keyboard-selection", "End focused \{pattern_tag(fe)} without selecting it"))
      }
    _ =>
      faults.push(
        pattern_fault(RadioGroup, "keyboard-nav", "End did not move focus to last enabled Radio \{pattern_tag(last_r)}"),
      )
  }
  let (_, after_home) = self.pattern_press_key(RadioGroup, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_r.id =>
      if radio_selected_state(fh) != Some(true) {
        faults.push(
          pattern_fault(RadioGroup, "keyboard-selection", "Home focused \{pattern_tag(fh)} without selecting it"),
        )
      }
    _ =>
      faults.push(
        pattern_fault(
          RadioGroup,
          "keyboard-nav",
          "Home did not move focus to first enabled Radio \{pattern_tag(first_r)}",
        ),
      )
  }
}

///|
fn Tester::check_listbox(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let boxes = pattern_visible_role(tree, from, until, Listbox)
  if boxes.is_empty() {
    faults.push(pattern_fault(Listbox, "missing-role", "no visible Listbox found in scope"))
    return
  }
  let (lb_idx, lb) = boxes[0]
  if pattern_blank(pattern_container_label(lb)) {
    faults.push(pattern_fault(Listbox, "missing-label", "Listbox \{pattern_tag(lb)} has empty label"))
  }
  let (lb_from, lb_until) = pattern_subtree_range(tree, lb_idx)
  let opts = pattern_visible_role(tree, lb_from + 1, lb_until, Option).map(fn(p) { p.1 })
  for opt in opts {
    if pattern_blank(opt.label) {
      faults.push(pattern_fault(Listbox, "missing-label", "Option \{pattern_tag(opt)} has empty label"))
    }
    if opt.selected is None {
      faults.push(pattern_fault(Listbox, "missing-state", "Option \{pattern_tag(opt)} missing selected state"))
    }
  }
  let enabled = opts.filter(fn(o) { !o.disabled })
  if enabled.length() < 2 {
    faults.push(
      pattern_fault(
        Listbox,
        "insufficient-items",
        "Listbox \{pattern_tag(lb)} requires at least 2 enabled Option nodes, found \{enabled.length()}",
      ),
    )
  }
  if enabled.length() >= 1 {
    check_single_tab_stop(Listbox, lb, enabled, faults)
  }
  if enabled.length() < 2 {
    return
  }
  let first_opt = enabled[0]
  let second_opt = enabled[1]
  let last_opt = enabled[enabled.length() - 1]
  if !self.pattern_focus_node(Listbox, first_opt, faults) {
    return
  }
  let (_, after_down) = self.pattern_press_key(Listbox, key_down, "ArrowDown", faults)
  match after_down {
    Some(fd) if fd.id == second_opt.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Listbox,
          "keyboard-nav",
          "ArrowDown from \{pattern_tag(first_opt)} did not move focus to \{pattern_tag(second_opt)}",
        ),
      )
  }
  let (_, after_up) = self.pattern_press_key(Listbox, key_up, "ArrowUp", faults)
  match after_up {
    Some(fu) if fu.id == first_opt.id => ()
    _ =>
      faults.push(
        pattern_fault(Listbox, "keyboard-nav", "ArrowUp did not move focus back to \{pattern_tag(first_opt)}"),
      )
  }
  let (_, after_end) = self.pattern_press_key(Listbox, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_opt.id => ()
    _ =>
      faults.push(
        pattern_fault(Listbox, "keyboard-nav", "End did not move focus to last enabled Option \{pattern_tag(last_opt)}"),
      )
  }
  let (_, after_home) = self.pattern_press_key(Listbox, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_opt.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Listbox,
          "keyboard-nav",
          "Home did not move focus to first enabled Option \{pattern_tag(first_opt)}",
        ),
      )
  }
  // Pick an unselected enabled option (if any) and verify Space or Enter can select it.
  let fresh_tree = self.pattern_semantics()
  let mut candidate : SemNode? = None
  for o in enabled {
    match pattern_find_id(fresh_tree, o.id) {
      Some(cur) if cur.selected == Some(false) => {
        candidate = Some(cur)
        break
      }
      _ => ()
    }
  }
  match candidate {
    Some(target) =>
      if self.pattern_focus_node(Listbox, target, faults) {
        let (t1, _) = self.pattern_press_key(Listbox, key_space, "Space (listbox select)", faults)
        let ok_space = match pattern_find_id(t1, target.id) {
          Some(n) => n.selected == Some(true)
          None => false
        }
        if !ok_space {
          let (t2, _) = self.pattern_press_key(Listbox, key_enter, "Enter (listbox select)", faults)
          let ok_enter = match pattern_find_id(t2, target.id) {
            Some(n) => n.selected == Some(true)
            None => false
          }
          if !ok_enter {
            faults.push(
              pattern_fault(
                Listbox,
                "keyboard-activation",
                "neither Space nor Enter selected Option \{pattern_tag(target)}",
              ),
            )
          }
        }
      }
    None => ()
  }
}

///|
fn Tester::check_menu(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let menus = pattern_visible_role(tree, from, until, Menu)
  if menus.is_empty() {
    faults.push(pattern_fault(Menu, "missing-role", "no visible Menu found in scope"))
    return
  }
  let (m_idx, m) = menus[0]
  let (m_from, m_until) = pattern_subtree_range(tree, m_idx)
  let items : Array[SemNode] = []
  for k in (m_from + 1)..<m_until {
    let s = tree[k]
    if !s.hidden && s.role is (MenuItem | MenuItemCheckbox | MenuItemRadio) {
      items.push(s)
    }
  }
  for item in items {
    if pattern_blank(item.label) {
      faults.push(pattern_fault(Menu, "missing-label", "menu item \{pattern_tag(item)} has empty label"))
    }
    if item.role is (MenuItemCheckbox | MenuItemRadio) && item.check is None {
      faults.push(pattern_fault(Menu, "missing-state", "menu item \{pattern_tag(item)} missing check state"))
    }
  }
  let enabled = items.filter(fn(i) { !i.disabled })
  if enabled.is_empty() {
    faults.push(
      pattern_fault(Menu, "insufficient-items", "Menu \{pattern_tag(m)} requires at least 1 enabled menu item"),
    )
    return
  }
  let first_item = enabled[0]
  if !self.pattern_focus_node(Menu, first_item, faults) {
    return
  }
  if enabled.length() == 1 {
    ignore(self.pattern_press_key(Menu, key_down, "ArrowDown", faults))
    ignore(self.pattern_press_key(Menu, key_up, "ArrowUp", faults))
    ignore(self.pattern_press_key(Menu, key_end, "End", faults))
    ignore(self.pattern_press_key(Menu, key_home, "Home", faults))
    return
  }
  let second_item = enabled[1]
  let last_item = enabled[enabled.length() - 1]
  // Traverse enabled items via ArrowDown (verifies skipping disabled items as well as focus movement).
  let (_, after_down) = self.pattern_press_key(Menu, key_down, "ArrowDown", faults)
  match after_down {
    Some(fd) if fd.id == second_item.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Menu,
          "keyboard-nav",
          "ArrowDown from \{pattern_tag(first_item)} did not move focus to next enabled item \{pattern_tag(second_item)}",
        ),
      )
  }
  let (_, after_up) = self.pattern_press_key(Menu, key_up, "ArrowUp", faults)
  match after_up {
    Some(fu) if fu.id == first_item.id => ()
    _ =>
      faults.push(
        pattern_fault(Menu, "keyboard-nav", "ArrowUp did not move focus back to \{pattern_tag(first_item)}"),
      )
  }
  let (_, after_end) = self.pattern_press_key(Menu, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_item.id => ()
    _ =>
      faults.push(
        pattern_fault(Menu, "keyboard-nav", "End did not move focus to last enabled item \{pattern_tag(last_item)}"),
      )
  }
  let (_, after_home) = self.pattern_press_key(Menu, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_item.id => ()
    _ =>
      faults.push(
        pattern_fault(Menu, "keyboard-nav", "Home did not move focus to first enabled item \{pattern_tag(first_item)}"),
      )
  }
}

///|
fn check_dialog(
  pattern : AriaPattern,
  is_alert : Bool,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let role : Role = if is_alert { AlertDialog } else { Dialog }
  let dialogs = pattern_visible_role(tree, from, until, role)
  if dialogs.is_empty() {
    faults.push(pattern_fault(pattern, "missing-role", "no visible \{role} found in scope"))
    return
  }
  let (d_idx, dlg) = dialogs[0]
  if pattern_blank(pattern_container_label(dlg)) {
    faults.push(pattern_fault(pattern, "missing-label", "\{role} \{pattern_tag(dlg)} has empty label"))
  }
  if is_alert && !pattern_is_modal(dlg) {
    faults.push(pattern_fault(pattern, "missing-modal", "AlertDialog \{pattern_tag(dlg)} must set modal=true"))
  }
  let (d_from, d_until) = pattern_subtree_range(tree, d_idx)
  let subtree : Array[SemNode] = []
  for k in d_from..<d_until {
    subtree.push(tree[k])
  }
  let focused = check_focus_invariant(pattern, "dialog-open", tree, faults)
  match focused {
    Some(f) if pattern_in_list(subtree, f.id) => ()
    Some(f) =>
      faults.push(
        pattern_fault(
          pattern,
          "focus-containment",
          "open \{pattern_tag(dlg)} must contain focus, but focus is outside on \{pattern_tag(f)}",
        ),
      )
    None =>
      faults.push(
        pattern_fault(pattern, "focus-containment", "open \{pattern_tag(dlg)} must contain focus, but focus is None"),
      )
  }
  let has_focusable = arr_any(subtree, fn(n) { !n.hidden && !n.disabled && (n.focused || pattern_can_focus(n)) })
  if !has_focusable {
    faults.push(
      pattern_fault(
        pattern,
        "missing-focusable",
        "\{pattern_tag(dlg)} has neither a focusable descendant nor a focusable container itself",
      ),
    )
  }
}

///|
fn Tester::check_accordion(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let all_buttons = pattern_visible_role(tree, from, until, Button).map(fn(p) { p.1 })
  let triggers = all_buttons.filter(fn(b) { b.expanded is Some(_) })
  for trig in triggers {
    if pattern_blank(trig.label) {
      faults.push(pattern_fault(Accordion, "missing-label", "Accordion trigger \{pattern_tag(trig)} has empty label"))
    }
  }
  let enabled = triggers.filter(fn(b) { !b.disabled })
  if enabled.length() < 2 {
    faults.push(
      pattern_fault(
        Accordion,
        "insufficient-triggers",
        "Accordion requires at least 2 enabled Button triggers with expanded state, found \{enabled.length()}",
      ),
    )
    return
  }
  let first_t = enabled[0]
  let second_t = enabled[1]
  let last_t = enabled[enabled.length() - 1]
  if !self.pattern_focus_node(Accordion, first_t, faults) {
    return
  }
  let (_, after_down) = self.pattern_press_key(Accordion, key_down, "ArrowDown", faults)
  match after_down {
    Some(fd) if fd.id == second_t.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Accordion,
          "keyboard-nav",
          "ArrowDown from \{pattern_tag(first_t)} did not move focus to \{pattern_tag(second_t)}",
        ),
      )
  }
  let (_, after_up) = self.pattern_press_key(Accordion, key_up, "ArrowUp", faults)
  match after_up {
    Some(fu) if fu.id == first_t.id => ()
    _ =>
      faults.push(
        pattern_fault(Accordion, "keyboard-nav", "ArrowUp did not move focus back to \{pattern_tag(first_t)}"),
      )
  }
  let (_, after_end) = self.pattern_press_key(Accordion, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_t.id => ()
    _ =>
      faults.push(
        pattern_fault(Accordion, "keyboard-nav", "End did not move focus to last trigger \{pattern_tag(last_t)}"),
      )
  }
  let (_, after_home) = self.pattern_press_key(Accordion, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_t.id => ()
    _ =>
      faults.push(
        pattern_fault(Accordion, "keyboard-nav", "Home did not move focus to first trigger \{pattern_tag(first_t)}"),
      )
  }
  // Prefer a collapsed trigger so even non-collapsible single-open accordions can toggle.
  let cur_tree = self.pattern_semantics()
  let mut toggle_target = first_t
  for tr in enabled {
    match pattern_find_id(cur_tree, tr.id) {
      Some(n) if n.expanded == Some(false) => {
        toggle_target = n
        break
      }
      _ => ()
    }
  }
  let before = match pattern_find_id(cur_tree, toggle_target.id) {
    Some(n) => n.expanded
    None => toggle_target.expanded
  }
  if self.pattern_focus_node(Accordion, toggle_target, faults) {
    let (t1, _) = self.pattern_press_key(Accordion, key_space, "Space (accordion toggle)", faults)
    let after1 = match pattern_find_id(t1, toggle_target.id) {
      Some(n) => n.expanded
      None => None
    }
    if after1 == before {
      let (t2, _) = self.pattern_press_key(Accordion, key_enter, "Enter (accordion toggle)", faults)
      let after2 = match pattern_find_id(t2, toggle_target.id) {
        Some(n) => n.expanded
        None => None
      }
      if after2 == before {
        faults.push(
          pattern_fault(
            Accordion,
            "keyboard-toggle",
            "neither Space nor Enter toggled expanded state on \{pattern_tag(toggle_target)}",
          ),
        )
      }
    }
  }
}

///|
fn Tester::check_disclosure(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let buttons = pattern_visible_role(tree, from, until, Button).map(fn(p) { p.1 })
  if buttons.is_empty() {
    faults.push(pattern_fault(Disclosure, "missing-role", "no visible Button trigger found in scope"))
    return
  }
  let trigger = match buttons.iter().find_first(fn(b) { b.expanded is Some(_) }) {
    Some(b) => b
    None => buttons[0]
  }
  if pattern_blank(trigger.label) {
    faults.push(pattern_fault(Disclosure, "missing-label", "Disclosure trigger \{pattern_tag(trigger)} has empty label"))
  }
  let before = match trigger.expanded {
    Some(v) => v
    None => {
      faults.push(
        pattern_fault(Disclosure, "missing-state", "Disclosure trigger \{pattern_tag(trigger)} missing expanded state"),
      )
      return
    }
  }
  if trigger.disabled {
    faults.push(pattern_fault(Disclosure, "disabled-trigger", "Disclosure trigger \{pattern_tag(trigger)} is disabled"))
    return
  }
  if !self.pattern_focus_node(Disclosure, trigger, faults) {
    return
  }
  let (t1, _) = self.pattern_press_key(Disclosure, key_space, "Space (disclosure toggle)", faults)
  let after_space = match pattern_find_id(t1, trigger.id) {
    Some(n) => n.expanded
    None => None
  }
  if after_space == Some(!before) {
    let (t2, _) = self.pattern_press_key(Disclosure, key_space, "Space (disclosure restore)", faults)
    let restored = match pattern_find_id(t2, trigger.id) {
      Some(n) => n.expanded
      None => None
    }
    if restored != Some(before) {
      faults.push(
        pattern_fault(
          Disclosure,
          "keyboard-toggle-restore",
          "second Space did not restore expanded=\{before} on \{pattern_tag(trigger)}",
        ),
      )
    }
  } else {
    let (t2, _) = self.pattern_press_key(Disclosure, key_enter, "Enter (disclosure toggle)", faults)
    let after_enter = match pattern_find_id(t2, trigger.id) {
      Some(n) => n.expanded
      None => None
    }
    if after_enter == Some(!before) {
      let (t3, _) = self.pattern_press_key(Disclosure, key_enter, "Enter (disclosure restore)", faults)
      let restored = match pattern_find_id(t3, trigger.id) {
        Some(n) => n.expanded
        None => None
      }
      if restored != Some(before) {
        faults.push(
          pattern_fault(
            Disclosure,
            "keyboard-toggle-restore",
            "second Enter did not restore expanded=\{before} on \{pattern_tag(trigger)}",
          ),
        )
      }
    } else {
      faults.push(
        pattern_fault(
          Disclosure,
          "keyboard-toggle",
          "neither Space nor Enter flipped expanded state on \{pattern_tag(trigger)}",
        ),
      )
    }
  }
}

///|
fn combobox_active_signature(tree : Array[SemNode], cb_id : Int, opt_ids : Array[Int]) -> String {
  let sb = StringBuilder()
  match pattern_find_id(tree, cb_id) {
    Some(cb) => {
      sb.write_string("v=")
      sb.write_string(cb.value)
    }
    None => ()
  }
  for id in opt_ids {
    match pattern_find_id(tree, id) {
      Some(o) => {
        if o.selected == Some(true) {
          sb.write_string("|s:\{o.id}")
        }
        if o.focused {
          sb.write_string("|f:\{o.id}")
        }
      }
      None => ()
    }
  }
  sb.to_string()
}

///|
fn Tester::check_combobox(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let cbs = pattern_visible_role(tree, from, until, Combobox)
  if cbs.is_empty() {
    faults.push(pattern_fault(Combobox, "missing-role", "no visible Combobox found in scope"))
    return
  }
  let (cb_idx, cb) = cbs[0]
  if pattern_blank(pattern_container_label(cb)) {
    faults.push(pattern_fault(Combobox, "missing-label", "Combobox \{pattern_tag(cb)} has empty label"))
  }
  let is_open = match cb.expanded {
    Some(v) => v
    None => {
      faults.push(pattern_fault(Combobox, "missing-state", "Combobox \{pattern_tag(cb)} missing expanded state"))
      return
    }
  }
  if !is_open {
    return
  }
  let listboxes = pattern_visible_role(tree, from, until, Listbox)
  if listboxes.is_empty() {
    faults.push(
      pattern_fault(Combobox, "missing-role", "expanded Combobox \{pattern_tag(cb)} has no visible Listbox in scope"),
    )
    return
  }
  let (lb_idx, lb) = listboxes[0]
  let (lb_from, lb_until) = pattern_subtree_range(tree, lb_idx)
  let opts = pattern_visible_role(tree, lb_from + 1, lb_until, Option).map(fn(p) { p.1 })
  for opt in opts {
    if pattern_blank(opt.label) {
      faults.push(pattern_fault(Combobox, "missing-label", "Combobox Option \{pattern_tag(opt)} has empty label"))
    }
  }
  let enabled = opts.filter(fn(o) { !o.disabled })
  if enabled.is_empty() {
    faults.push(
      pattern_fault(Combobox, "insufficient-items", "expanded Combobox Listbox \{pattern_tag(lb)} has no enabled Option"),
    )
    return
  }
  // Ensure focus is on the combobox (its field, itself, or its listbox) before driving ArrowDown/ArrowUp.
  let (cb_from, cb_until) = pattern_subtree_range(tree, cb_idx)
  let cb_subtree : Array[SemNode] = []
  for k in cb_from..<cb_until {
    cb_subtree.push(tree[k])
  }
  let mut focus_before = self.pattern_focused()
  let already_inside = match focus_before {
    Some(f) => pattern_in_list(cb_subtree, f.id) || f.id == lb.id || pattern_in_list(enabled, f.id)
    None => false
  }
  if !already_inside {
    let fields = pattern_visible_role(tree, cb_from, cb_until, TextField).map(fn(p) { p.1 })
    if !fields.is_empty() && pattern_can_focus(fields[0]) {
      ignore(self.pattern_focus_node(Combobox, fields[0], faults))
    } else if pattern_can_focus(cb) {
      ignore(self.pattern_focus_node(Combobox, cb, faults))
    } else if pattern_can_focus(lb) {
      ignore(self.pattern_focus_node(Combobox, lb, faults))
    }
    focus_before = self.pattern_focused()
  }
  let opt_ids = enabled.map(fn(o) { o.id })
  let sig_before = combobox_active_signature(self.pattern_semantics(), cb.id, opt_ids)
  let (t_down, focus_down) = self.pattern_press_key(Combobox, key_down, "ArrowDown", faults)
  if focus_before is Some(_) && focus_down is None {
    faults.push(
      pattern_fault(Combobox, "focus-lost", "ArrowDown in expanded Combobox \{pattern_tag(cb)} lost keyboard focus"),
    )
  }
  let sig_down = combobox_active_signature(t_down, cb.id, opt_ids)
  if enabled.length() >= 2 && sig_down == sig_before {
    faults.push(
      pattern_fault(
        Combobox,
        "keyboard-nav",
        "ArrowDown in expanded Combobox \{pattern_tag(cb)} did not change active option state",
      ),
    )
  }
  let (t_up, focus_up) = self.pattern_press_key(Combobox, key_up, "ArrowUp", faults)
  if focus_before is Some(_) && focus_up is None {
    faults.push(
      pattern_fault(Combobox, "focus-lost", "ArrowUp in expanded Combobox \{pattern_tag(cb)} lost keyboard focus"),
    )
  }
  let sig_up = combobox_active_signature(t_up, cb.id, opt_ids)
  if enabled.length() >= 2 && sig_down != sig_before && sig_up == sig_down {
    faults.push(
      pattern_fault(
        Combobox,
        "keyboard-nav",
        "ArrowUp in expanded Combobox \{pattern_tag(cb)} did not move active option back",
      ),
    )
  }
}

///|
fn Tester::check_slider(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  rtl : Bool,
  faults : Array[String],
) -> Unit {
  let sliders = pattern_visible_role(tree, from, until, Slider)
  if sliders.is_empty() {
    faults.push(pattern_fault(Slider, "missing-role", "no visible Slider found in scope"))
    return
  }
  let (_, sl) = sliders[0]
  if pattern_blank(sl.label) {
    faults.push(pattern_fault(Slider, "missing-label", "Slider \{pattern_tag(sl)} has empty label"))
  }
  let has_inc = pattern_has_action(sl, Increment)
  let has_dec = pattern_has_action(sl, Decrement)
  if !sl.disabled && (!has_inc || !has_dec) {
    faults.push(
      pattern_fault(
        Slider,
        "missing-action",
        "enabled Slider \{pattern_tag(sl)} must declare both Increment and Decrement actions",
      ),
    )
  }
  let (lo, initial, hi) = match sl.range {
    Some((a, v, b)) => {
      if a > b || v < a - 1.0e-6 || v > b + 1.0e-6 {
        faults.push(
          pattern_fault(
            Slider,
            "invalid-range",
            "Slider \{pattern_tag(sl)} range (\{a}, \{v}, \{b}) violates min <= val <= max",
          ),
        )
        return
      }
      (a, v, b)
    }
    None => {
      faults.push(pattern_fault(Slider, "missing-range", "Slider \{pattern_tag(sl)} missing range (min, val, max)"))
      return
    }
  }
  if sl.disabled || hi <= lo {
    return
  }
  if !self.pattern_focus_node(Slider, sl, faults) {
    return
  }
  let inc_key = if rtl { key_left } else { key_right }
  let dec_key = if rtl { key_right } else { key_left }
  let inc_name = if rtl { "ArrowLeft (rtl increment)" } else { "ArrowRight" }
  let dec_name = if rtl { "ArrowRight (rtl decrement)" } else { "ArrowLeft" }
  let read_val = fn(t : Array[SemNode]) -> Double? {
    match pattern_find_id(t, sl.id) {
      Some(n) =>
        match n.range {
          Some((_, v, _)) => Some(v)
          None => None
        }
      None => None
    }
  }
  if initial < hi - 1.0e-6 {
    let (t_inc, _) = self.pattern_press_key(Slider, inc_key, inc_name, faults)
    let v_inc = read_val(t_inc)
    let ok = match v_inc {
      Some(v) => v > initial + 1.0e-6
      None => false
    }
    if !ok {
      let (t_up, _) = self.pattern_press_key(Slider, key_up, "ArrowUp", faults)
      let ok_up = match read_val(t_up) {
        Some(v) => v > initial + 1.0e-6
        None => false
      }
      if !ok_up {
        faults.push(
          pattern_fault(
            Slider,
            "keyboard-increment",
            "\{inc_name}/ArrowUp did not increment Slider \{pattern_tag(sl)} from \{initial}",
          ),
        )
      }
    }
  } else {
    // Already at max: verify decrement moves down and increment returns to max.
    let (t_dec, _) = self.pattern_press_key(Slider, dec_key, dec_name, faults)
    match read_val(t_dec) {
      Some(v) if v < initial - 1.0e-6 => {
        let (t_inc, _) = self.pattern_press_key(Slider, inc_key, inc_name, faults)
        match read_val(t_inc) {
          Some(v2) if v2 > v + 1.0e-6 => ()
          _ =>
            faults.push(
              pattern_fault(
                Slider,
                "keyboard-increment",
                "\{inc_name} did not increment Slider \{pattern_tag(sl)} back from \{v}",
              ),
            )
        }
      }
      _ =>
        faults.push(
          pattern_fault(
            Slider,
            "keyboard-decrement",
            "\{dec_name} did not decrement Slider \{pattern_tag(sl)} from max \{initial}",
          ),
        )
    }
  }
  let (t_home, _) = self.pattern_press_key(Slider, key_home, "Home", faults)
  match read_val(t_home) {
    Some(v) if (v - lo).abs() <= 1.0e-6 => ()
    Some(v) =>
      faults.push(
        pattern_fault(Slider, "keyboard-home", "Home set Slider \{pattern_tag(sl)} to \{v}, expected min \{lo}"),
      )
    None => faults.push(pattern_fault(Slider, "keyboard-home", "Home lost range on Slider \{pattern_tag(sl)}"))
  }
  let (t_end, _) = self.pattern_press_key(Slider, key_end, "End", faults)
  match read_val(t_end) {
    Some(v) if (v - hi).abs() <= 1.0e-6 => ()
    Some(v) =>
      faults.push(
        pattern_fault(Slider, "keyboard-end", "End set Slider \{pattern_tag(sl)} to \{v}, expected max \{hi}"),
      )
    None => faults.push(pattern_fault(Slider, "keyboard-end", "End lost range on Slider \{pattern_tag(sl)}"))
  }
  // Restore slider back toward its initial value.
  if (initial - lo).abs() <= 1.0e-6 {
    ignore(self.pattern_press_key(Slider, key_home, "Home (restore)", faults))
  } else if (initial - hi).abs() > 1.0e-6 {
    ignore(self.pattern_press_key(Slider, key_home, "Home (restore base)", faults))
    let mut prev = lo
    for _ in 0..<256 {
      if prev >= initial - 1.0e-6 {
        break
      }
      let (t_step, _) = self.pattern_press_key(Slider, inc_key, "\{inc_name} (restore)", faults)
      match read_val(t_step) {
        Some(v) if v > prev + 1.0e-6 => prev = v
        _ => break
      }
    }
  }
}

///|
fn Tester::check_toggle_role(
  self : Tester,
  pattern : AriaPattern,
  role : Role,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  faults : Array[String],
) -> Unit {
  let nodes = pattern_visible_role(tree, from, until, role)
  if nodes.is_empty() {
    faults.push(pattern_fault(pattern, "missing-role", "no visible \{role} found in scope"))
    return
  }
  let (_, node) = nodes[0]
  if pattern_blank(node.label) {
    faults.push(pattern_fault(pattern, "missing-label", "\{role} \{pattern_tag(node)} has empty label"))
  }
  let before = match node.check {
    Some(c) => c
    None => {
      faults.push(pattern_fault(pattern, "missing-state", "\{role} \{pattern_tag(node)} missing check state"))
      return
    }
  }
  if node.disabled {
    return
  }
  if !self.pattern_focus_node(pattern, node, faults) {
    return
  }
  let (t1, _) = self.pattern_press_key(pattern, key_space, "Space (toggle)", faults)
  let after1 = match pattern_find_id(t1, node.id) {
    Some(n) => n.check
    None => None
  }
  match after1 {
    Some(c) if c != before => {
      let (t2, _) = self.pattern_press_key(pattern, key_space, "Space (restore)", faults)
      let after2 = match pattern_find_id(t2, node.id) {
        Some(n) => n.check
        None => None
      }
      if before is (On | Off) && after2 != Some(before) {
        faults.push(
          pattern_fault(
            pattern,
            "keyboard-toggle-restore",
            "second Space did not restore check=\{before} on \{pattern_tag(node)}",
          ),
        )
      }
    }
    _ =>
      faults.push(
        pattern_fault(pattern, "keyboard-toggle", "Space did not flip check state on \{pattern_tag(node)}"),
      )
  }
}

///|
fn Tester::check_toolbar(
  self : Tester,
  tree : Array[SemNode],
  from : Int,
  until : Int,
  rtl : Bool,
  faults : Array[String],
) -> Unit {
  let bars = pattern_visible_role(tree, from, until, Toolbar)
  if bars.is_empty() {
    faults.push(pattern_fault(Toolbar, "missing-role", "no visible Toolbar found in scope"))
    return
  }
  let (tb_idx, tb) = bars[0]
  if pattern_blank(pattern_container_label(tb)) {
    faults.push(pattern_fault(Toolbar, "missing-label", "Toolbar \{pattern_tag(tb)} has empty label"))
  }
  let (tb_from, tb_until) = pattern_subtree_range(tree, tb_idx)
  let controls : Array[SemNode] = []
  for k in (tb_from + 1)..<tb_until {
    let s = tree[k]
    if !s.hidden && pattern_is_toolbar_control(s) {
      controls.push(s)
    }
  }
  let enabled = controls.filter(fn(c) { !c.disabled })
  if enabled.length() < 2 {
    faults.push(
      pattern_fault(
        Toolbar,
        "insufficient-items",
        "Toolbar \{pattern_tag(tb)} requires at least 2 enabled child controls, found \{enabled.length()}",
      ),
    )
  }
  if enabled.length() >= 1 {
    check_single_tab_stop(Toolbar, tb, enabled, faults)
  }
  if enabled.length() < 2 {
    return
  }
  let first_c = enabled[0]
  let last_c = enabled[enabled.length() - 1]
  if !self.pattern_focus_node(Toolbar, first_c, faults) {
    return
  }
  let next_key = if rtl { key_left } else { key_right }
  let prev_key = if rtl { key_right } else { key_left }
  let next_name = if rtl { "ArrowLeft (rtl next)" } else { "ArrowRight" }
  let prev_name = if rtl { "ArrowRight (rtl prev)" } else { "ArrowLeft" }
  let (_, after_next) = self.pattern_press_key(Toolbar, next_key, next_name, faults)
  match after_next {
    Some(fn_) if fn_.id != first_c.id && pattern_in_list(enabled, fn_.id) => {
      let (_, after_prev) = self.pattern_press_key(Toolbar, prev_key, prev_name, faults)
      match after_prev {
        Some(fp) if fp.id != fn_.id && pattern_in_list(enabled, fp.id) => ()
        _ =>
          faults.push(
            pattern_fault(
              Toolbar,
              "keyboard-nav",
              "\{prev_name} from \{pattern_tag(fn_)} did not move focus to another enabled Toolbar control",
            ),
          )
      }
    }
    _ =>
      faults.push(
        pattern_fault(
          Toolbar,
          "keyboard-nav",
          "\{next_name} from \{pattern_tag(first_c)} did not move focus to another enabled Toolbar control",
        ),
      )
  }
  let (_, after_end) = self.pattern_press_key(Toolbar, key_end, "End", faults)
  match after_end {
    Some(fe) if fe.id == last_c.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Toolbar,
          "keyboard-nav",
          "End did not move focus to last enabled Toolbar control \{pattern_tag(last_c)}",
        ),
      )
  }
  let (_, after_home) = self.pattern_press_key(Toolbar, key_home, "Home", faults)
  match after_home {
    Some(fh) if fh.id == first_c.id => ()
    _ =>
      faults.push(
        pattern_fault(
          Toolbar,
          "keyboard-nav",
          "Home did not move focus to first enabled Toolbar control \{pattern_tag(first_c)}",
        ),
      )
  }
}

///|
/// Check the WAI-ARIA APG contract for `pattern` (optionally scoped to `within`, and with `rtl=true` swapping
/// horizontal arrow direction). Returns every collected fault; an empty array means the pattern passed.
pub fn Tester::check_pattern(
  self : Tester,
  pattern : AriaPattern,
  within? : SemNode,
  rtl? : Bool = false,
) -> Array[String] {
  let faults : Array[String] = []
  let tree = self.pattern_semantics()
  let (from, until, found_scope) = pattern_scope_range(tree, within)
  if !found_scope {
    match within {
      Some(w) => faults.push(pattern_fault(pattern, "missing-scope", "within node \{pattern_tag(w)} not found in tree"))
      None => ()
    }
    return faults
  }
  match pattern {
    Tabs => self.check_tabs(tree, from, until, rtl, faults)
    RadioGroup => self.check_radio_group(tree, from, until, rtl, faults)
    Listbox => self.check_listbox(tree, from, until, faults)
    Menu => self.check_menu(tree, from, until, faults)
    Dialog => check_dialog(Dialog, false, tree, from, until, faults)
    AlertDialog => check_dialog(AlertDialog, true, tree, from, until, faults)
    Accordion => self.check_accordion(tree, from, until, faults)
    Disclosure => self.check_disclosure(tree, from, until, faults)
    Combobox => self.check_combobox(tree, from, until, faults)
    Slider => self.check_slider(tree, from, until, rtl, faults)
    Switch => self.check_toggle_role(Switch, Switch, tree, from, until, faults)
    Checkbox => self.check_toggle_role(Checkbox, Checkbox, tree, from, until, faults)
    Toolbar => self.check_toolbar(tree, from, until, rtl, faults)
  }
  faults
}

///|
/// Assert the WAI-ARIA APG contract for `pattern`, failing with all collected faults if any rule is violated.
pub fn Tester::assert_pattern(
  self : Tester,
  pattern : AriaPattern,
  within? : SemNode,
  rtl? : Bool = false,
  label? : String = "",
) -> Unit raise {
  let faults = self.check_pattern(pattern, within?, rtl~)
  if !faults.is_empty() {
    let header = if label == "" {
      "ARIA pattern \{pattern.name()} failed (\{faults.length()} faults):"
    } else {
      "ARIA pattern \{pattern.name()} (\{label}) failed (\{faults.length()} faults):"
    }
    fail(header + "\n" + faults.join("\n"))
  }
}
