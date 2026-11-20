// Pure-tree Tester guards and zero-redraw lightweight audit:
// - Tester::unnamed_press_faults: visible interactive tree nodes without accessible label or visible text.
// - Tester::light_audit / Tester::assert_clean: zero-extra-frame audit combining layout, a11y, fanout and hold checks.
// - Tester::hold_fanout / Tester::hold_unseen_press: default Tester::tree frame-end guards.

///|
/// Whether fan-out limit violations fail the test at frame end (enabled by default on Tester::tree).
// kept across runs: reset by reset_globals
let fanout_hold : Ref[Bool] = Ref(false)

///|
/// Whether unseen pressable targets at rest fail the test at frame end (enabled by default on Tester::tree).
// kept across runs: reset by reset_globals
let unseen_press_hold : Ref[Bool] = Ref(false)

///|
fn is_blank_text(s : String) -> Bool {
  for ch in s {
    if ch != ' ' && ch != '\t' && ch != '\n' && ch != '\r' {
      return false
    }
  }
  true
}

///|
fn role_interactive(role : @view.Role) -> Bool {
  match role {
    Button
    | Link
    | Checkbox
    | Switch
    | Radio
    | Slider
    | Tab
    | MenuItem
    | MenuItemCheckbox
    | MenuItemRadio
    | Option
    | Combobox
    | TextField => true
    _ => false
  }
}

///|
fn drawn_has_visible_text(d : @view.Drawn) -> Bool {
  if d.alpha <= unseen_alpha || d.bones != 0L {
    return false
  }
  if !is_blank_text(view_words_found(d)) {
    return true
  }
  for r in d.runs {
    if !is_blank_text(r.text) {
      return true
    }
  }
  false
}

///|
/// Visible interactive nodes in the window's tree that have neither a non-empty `says` label nor any visible text
/// drawn in their subtree. Pure containers and `View::as_ground` backdrops are excluded.
pub fn Tester::unnamed_press_faults(self : Tester) -> Array[String] {
  self.reads_own()
  guard view_tree() is Some(tree) else { return [] }
  let drawn = tree.drawn()
  let text_nodes : Array[@view.NodeId] = []
  for d in drawn {
    if drawn_has_visible_text(d) {
      text_nodes.push(d.id)
    }
  }
  let seen : Map[Int, Bool] = Map([])
  let candidates : Array[(@view.NodeId, Double, Double, Double, Double)] = []
  // Pressable non-ground nodes (Tree::press_boxes already filters out hidden, alpha<=0.01, hosted, as_ground, pressless).
  for pb in tree.press_boxes() {
    let id = pb.0
    if tree.presses_do(id) && !seen.contains(id.at) {
      seen[id.at] = true
      let b = pb.1
      candidates.push((id, b.0, b.1, b.2 - b.0, b.3 - b.1))
    }
  }
  // Visible nodes declaring an interactive role that take presses (even without on_press).
  for d in drawn {
    if seen.contains(d.id.at) || d.alpha <= unseen_alpha || d.w <= 0.0 || d.h <= 0.0 || d.hosted {
      continue
    }
    if !tree.takes_presses(d.id) {
      continue
    }
    match tree.said_of(d.id) {
      Some(s) if role_interactive(s.role) => {
        seen[d.id.at] = true
        candidates.push((d.id, d.x, d.y, d.w, d.h))
      }
      _ => ()
    }
  }
  let out : Array[String] = []
  for c in candidates {
    let (id, x, y, w, h) = c
    if !is_blank_text(tree.said_label(id)) {
      continue
    }
    let mut has_text = false
    for tid in text_nodes {
      if tree.holds(id, tid) {
        has_text = true
        break
      }
    }
    if has_text {
      continue
    }
    out.push(
      "[UNNAMED_PRESS] interactive node at \{x.round()},\{y.round()} \{w.round()}×\{h.round()}" +
      tree_source_said(id) +
      " has no accessible label or visible text; add .says(...) or use @headless.*",
    )
  }
  out
}

///|
/// Lightweight audit of the current frame with zero extra frames drawn (skips unasked_faults and contrast_faults).
pub fn Tester::light_audit(self : Tester) -> Array[String] {
  self.tree_room_faults() +
  self.squeeze_faults() +
  self.corner_faults() +
  self.first_line_faults() +
  self.unseen_press_faults() +
  self.fixed_outgrown() +
  self.unnamed_press_faults() +
  self.fanout_faults() +
  self.hold_faults() +
  self.waterfall_faults()
}

///|
#callsite(autofill(loc))
fn Tester::assert_clean_said(self : Tester, loc~ : SourceLoc) -> String? {
  let faults = self.light_audit()
  if faults.is_empty() {
    None
  } else {
    Some("Tester::assert_clean failed at \{loc} (\{faults.length()} fault(s)):\n" + faults.join("\n"))
  }
}

///|
/// Assert that `light_audit()` reports no faults on the current frame.
#callsite(autofill(loc))
pub fn Tester::assert_clean(self : Tester, loc~ : SourceLoc) -> Unit {
  match self.assert_clean_said(loc~) {
    Some(msg) => @halt.saying(msg)
    None => ()
  }
}

///|
fn Tester::hold_fanout_said(self : Tester) -> String? {
  if !fanout_hold.val || @signals.fanout_limit.val <= 0 {
    return None
  }
  let faults = self.fanout_faults()
  if faults.is_empty() {
    None
  } else {
    Some(
      "fan-out limit exceeded on a frame drawn at \{self.fake.time}, the Tester made at \{looks_made_at.val}:\n" +
      faults.join("\n"),
    )
  }
}

///|
fn Tester::hold_fanout(self : Tester) -> Unit {
  match self.hold_fanout_said() {
    Some(msg) => @halt.saying(msg)
    None => ()
  }
}

///|
fn Tester::hold_unseen_press_said(self : Tester) -> String? {
  if !unseen_press_hold.val || !g().frame_rest || self.fake.wants || posted_left() != "" {
    return None
  }
  let faults = self.unseen_press_faults()
  if faults.is_empty() {
    None
  } else {
    Some(
      "unseen press target found at rest on a frame drawn at \{self.fake.time}, the Tester made at \{looks_made_at.val}:\n" +
      faults.join("\n"),
    )
  }
}

///|
fn Tester::hold_unseen_press(self : Tester) -> Unit {
  match self.hold_unseen_press_said() {
    Some(msg) => @halt.saying(msg)
    None => ()
  }
}
