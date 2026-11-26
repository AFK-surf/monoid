// Runtime Agent Bridge protocol built natively on `@view.Tree`.
//
// Lets an external or in-process agent observe and safely operate a running UI tree without screenshots:
// - Security/privacy markers (`agent_confirm`, `agent_secret`, `agent_hidden`, `agent_value_writer`) attach to
//   `@view.View` with zero layout/paint impact and clean themselves up via `View::owns` when nodes unmount.
// - `agent_snapshot` / `agent_query` / `agent_snapshot_json` export a redacted, modal-aware, structured view of
//   interactive and semantic controls.
// - `agent_act` / `agent_act_all` execute validated, ambiguity-safe, confirmation-gated actions directly on the tree.

///|
let agent_confirms : Map[@view.NodeId, String] = Map([])

///|
let agent_secrets : Set[@view.NodeId] = Set([])

///|
let agent_hiddens : Set[@view.NodeId] = Set([])

///|
let agent_writers : Map[@view.NodeId, (String) -> Unit] = Map([])

///|
fn agent_bridge_reset() -> Unit {
  agent_confirms.clear()
  agent_secrets.clear()
  agent_hiddens.clear()
  agent_writers.clear()
}

///|
fn init {
  on_reset(agent_bridge_reset)
  window_kept_map(agent_confirms)
  window_kept_set(agent_secrets)
  window_kept_set(agent_hiddens)
  window_kept_map(agent_writers)
}

///|
/// Mark `v` (and its subtree) as requiring explicit human confirmation with `reason` before any agent action runs.
pub fn agent_confirm(v : @view.View, reason : String) -> Unit {
  if !v.alive() {
    return
  }
  let id = v.id()
  if !agent_confirms.contains(id) {
    let _ = v.owns(fn() { agent_confirms.remove(id) })
  }
  agent_confirms[id] = reason
}

///|
/// Mark `v` (and its subtree) as secret: values are redacted to `"[redacted]"` in snapshots and excluded from text
/// search to prevent side-channel leaks, while `SetValue` may still write to it.
pub fn agent_secret(v : @view.View) -> Unit {
  if !v.alive() {
    return
  }
  let id = v.id()
  if !agent_secrets.contains(id) {
    agent_secrets.insert(id)
    let _ = v.owns(fn() { agent_secrets.remove(id) })
  }
}

///|
/// Hide `v` and its entire subtree from the Agent Bridge (excluded from `agent_snapshot`, `agent_query`, and `agent_act`).
pub fn agent_hidden(v : @view.View) -> Unit {
  if !v.alive() {
    return
  }
  let id = v.id()
  if !agent_hiddens.contains(id) {
    agent_hiddens.insert(id)
    let _ = v.owns(fn() { agent_hiddens.remove(id) })
  }
}

///|
/// Register a programmatic value writer on `v` so `AgentAction::SetValue` can update it directly without key synthesis.
pub fn agent_value_writer(v : @view.View, write : (String) -> Unit) -> Unit {
  if !v.alive() {
    return
  }
  let id = v.id()
  if !agent_writers.contains(id) {
    let _ = v.owns(fn() { agent_writers.remove(id) })
  }
  agent_writers[id] = write
}

///|
/// A single visible semantic control observed by an agent.
#derive(Eq, Debug)
pub(all) struct AgentEntry {
  ref_id : String
  node_id : @view.NodeId
  role : @view.Role
  label : String
  description : String
  value : String
  redacted : Bool
  check : @view.Check?
  expanded : Bool?
  selected : Bool?
  pressed : Bool?
  disabled : Bool
  range : (Double, Double, Double)?
  confirm : String?
  actions : Array[String]
  source : String
}

///|
/// Actions an agent may request on a target control.
#derive(Eq, Debug)
pub(all) enum AgentAction {
  Press
  Focus
  Increment
  Decrement
  SetValue(String)
}

///|
/// One targeted action step (`target` may be a `ref_id` like `"n:12:0"` or a human-readable label).
#derive(Eq, Debug)
pub(all) struct AgentStep {
  target : String
  action : AgentAction
}

///|
/// Payload passed to the `allow` confirmation callback when a control is protected by `agent_confirm`.
#derive(Eq, Debug)
pub(all) struct AgentApproval {
  entry : AgentEntry
  action : AgentAction
  reason : String
}

///|
/// Structured error returned when an agent action cannot be executed safely.
#derive(Eq, Debug)
pub(all) enum AgentActError {
  NotFound(String)
  Ambiguous(Array[String])
  Disabled(String)
  NeedsConfirm(String)
  UnsupportedAction(String)
}

///|
/// Result of executing an `AgentStep` (`Ok(AgentEntry)` or `Err(AgentActError)`).
pub type AgentActResult = Result[AgentEntry, AgentActError]

///|
pub impl Show for AgentActError with output(self, logger) {
  match self {
    NotFound(t) => logger.write_string("NotFound(\{t})")
    Ambiguous(refs) => logger.write_string("Ambiguous([" + refs.join(", ") + "])")
    Disabled(r) => logger.write_string("Disabled(\{r})")
    NeedsConfirm(reason) => logger.write_string("NeedsConfirm(\{reason})")
    UnsupportedAction(detail) => logger.write_string("UnsupportedAction(\{detail})")
  }
}

///|
pub impl Show for AgentEntry with output(self, logger) {
  logger.write_string("AgentEntry(\{self.ref_id}, \{self.role}, label=\{self.label})")
}

///|
fn agent_ref_id(id : @view.NodeId) -> String {
  "n:\{id.at}:\{id.gen}"
}

///|
fn agent_is_hidden(tree : @view.Tree, id : @view.NodeId) -> Bool {
  if agent_hiddens.is_empty() {
    return false
  }
  if agent_hiddens.contains(id) {
    return true
  }
  for h in agent_hiddens {
    if tree.holds(h, id) {
      return true
    }
  }
  false
}

///|
fn agent_is_secret(tree : @view.Tree, id : @view.NodeId) -> Bool {
  if agent_secrets.is_empty() {
    return false
  }
  if agent_secrets.contains(id) {
    return true
  }
  for s in agent_secrets {
    if tree.holds(s, id) {
      return true
    }
  }
  false
}

///|
fn agent_confirm_of(tree : @view.Tree, id : @view.NodeId) -> String? {
  if agent_confirms.is_empty() {
    return None
  }
  match agent_confirms.get(id) {
    Some(reason) => return Some(reason)
    None => ()
  }
  let mut best : (@view.NodeId, String)? = None
  for cid, reason in agent_confirms {
    if tree.holds(cid, id) {
      match best {
        None => best = Some((cid, reason))
        Some((prev_id, _)) => if tree.holds(prev_id, cid) { best = Some((cid, reason)) }
      }
    }
  }
  match best {
    Some((_, reason)) => Some(reason)
    None => None
  }
}

///|
fn agent_ascii_lower(s : String) -> String {
  let sb = StringBuilder()
  for ch in s {
    let code = ch.to_int()
    if code >= 65 && code <= 90 {
      sb.write_char(Int::unsafe_to_char(code + 32))
    } else {
      sb.write_char(ch)
    }
  }
  sb.to_string()
}

///|
fn agent_action_name(action : AgentAction) -> String {
  match action {
    Press => "press"
    Focus => "focus"
    Increment => "increment"
    Decrement => "decrement"
    SetValue(_) => "set_value"
  }
}

///|
fn agent_push_unique(arr : Array[String], item : String) -> Unit {
  if !arr.contains(item) {
    arr.push(item)
  }
}

///|
fn agent_tree_moment(tree : @view.Tree) -> Double {
  match tree.moment() {
    Some(m) => m
    None =>
      match view_app.val {
        Some(_) => view_moment()
        None => 0.0
      }
  }
}

///|
/// Snapshot all agent-visible controls in `tree`, skipping hidden, modal-occluded, and `agent_hidden` subtrees,
/// redacting `agent_secret` values, and inheriting the nearest `agent_confirm` reason.
pub fn agent_snapshot(tree : @view.Tree) -> Array[AgentEntry] {
  let out : Array[AgentEntry] = []
  for sn in tree.said_order() {
    if sn.hidden || !sn.allowed {
      continue
    }
    guard sn.said is Some(s) else { continue }
    if agent_is_hidden(tree, sn.id) {
      continue
    }
    let label = if s.label != "" || !s.role.named_by_held() {
      s.label
    } else {
      tree.words_within(sn.id, fn(_) { "" })
    }
    let redacted = agent_is_secret(tree, sn.id)
    let value = if redacted { "[redacted]" } else { s.value }
    let confirm = agent_confirm_of(tree, sn.id)
    let actions : Array[String] = []
    if !sn.disabled {
      if tree.presses_do(sn.id) || s.actions.contains(Activate) {
        agent_push_unique(actions, "press")
      }
      if tree.can_focus(sn.id) || s.actions.contains(Focus) {
        agent_push_unique(actions, "focus")
      }
      if s.actions.contains(Increment) || (s.role == Slider && s.range is Some(_)) {
        agent_push_unique(actions, "increment")
      }
      if s.actions.contains(Decrement) || (s.role == Slider && s.range is Some(_)) {
        agent_push_unique(actions, "decrement")
      }
      let has_set_text = s.actions.iter().any(fn(a) { a is SetText(_) })
      if agent_writers.contains(sn.id) || tree_fields.contains(sn.id) || has_set_text {
        agent_push_unique(actions, "set_value")
      }
    }
    let source = match tree.sources_of(sn.id) {
      [first, ..] => if first.made_for != "" { first.made_for } else { first.made }
      [] => ""
    }
    out.push({
      ref_id: agent_ref_id(sn.id),
      node_id: sn.id,
      role: s.role,
      label,
      description: s.description,
      value,
      redacted,
      check: s.check,
      expanded: s.expanded,
      selected: s.selected,
      pressed: s.pressed,
      disabled: sn.disabled,
      range: s.range,
      confirm,
      actions,
      source,
    })
  }
  out
}

///|
fn agent_find_within(entries : Array[AgentEntry], within : String) -> Array[@view.NodeId] {
  for e in entries {
    if e.ref_id == within {
      return [e.node_id]
    }
  }
  let needle = agent_ascii_lower(within)
  let exact : Array[@view.NodeId] = []
  for e in entries {
    if agent_ascii_lower(e.label) == needle {
      exact.push(e.node_id)
    }
  }
  if !exact.is_empty() {
    return exact
  }
  let sub : Array[@view.NodeId] = []
  for e in entries {
    if agent_ascii_lower(e.label).contains(needle) {
      sub.push(e.node_id)
    }
  }
  sub
}

///|
/// Query visible controls in `tree` by case-insensitive `text` (matching label, description, or non-redacted value),
/// optional `role`, and optional ancestor `within` (`ref_id` or label).
pub fn agent_query(
  tree : @view.Tree,
  text? : String = "",
  role? : @view.Role,
  within? : String = "",
) -> Array[AgentEntry] {
  let entries = agent_snapshot(tree)
  let scopes : Array[@view.NodeId]? = if within == "" {
    None
  } else {
    let found = agent_find_within(entries, within)
    if found.is_empty() {
      return []
    }
    Some(found)
  }
  let needle = agent_ascii_lower(text)
  let out : Array[AgentEntry] = []
  for e in entries {
    match scopes {
      Some(ws) => {
        let mut inside = false
        for w in ws {
          if tree.holds(w, e.node_id) {
            inside = true
            break
          }
        }
        if !inside {
          continue
        }
      }
      None => ()
    }
    match role {
      Some(r) if e.role != r => continue
      _ => ()
    }
    if needle != "" {
      let hit_label = agent_ascii_lower(e.label).contains(needle)
      let hit_desc = agent_ascii_lower(e.description).contains(needle)
      let hit_val = !e.redacted && agent_ascii_lower(e.value).contains(needle)
      if !hit_label && !hit_desc && !hit_val {
        continue
      }
    }
    out.push(e)
  }
  out
}

///|
fn agent_resolve_target(entries : Array[AgentEntry], target : String) -> Result[AgentEntry, AgentActError] {
  if target == "" {
    return Err(NotFound(""))
  }
  for e in entries {
    if e.ref_id == target {
      return Ok(e)
    }
  }
  let exact : Array[AgentEntry] = []
  for e in entries {
    if e.label == target {
      exact.push(e)
    }
  }
  if exact.length() == 1 {
    return Ok(exact[0])
  }
  if exact.length() > 1 {
    return Err(Ambiguous(exact.map(fn(e) { e.ref_id })))
  }
  let needle = agent_ascii_lower(target)
  let ci_exact : Array[AgentEntry] = []
  for e in entries {
    if agent_ascii_lower(e.label) == needle {
      ci_exact.push(e)
    }
  }
  if ci_exact.length() == 1 {
    return Ok(ci_exact[0])
  }
  if ci_exact.length() > 1 {
    return Err(Ambiguous(ci_exact.map(fn(e) { e.ref_id })))
  }
  if needle != "" {
    let sub : Array[AgentEntry] = []
    for e in entries {
      if agent_ascii_lower(e.label).contains(needle) {
        sub.push(e)
      }
    }
    if sub.length() == 1 {
      return Ok(sub[0])
    }
    if sub.length() > 1 {
      return Err(Ambiguous(sub.map(fn(e) { e.ref_id })))
    }
  }
  Err(NotFound(target))
}

///|
fn agent_refetch(tree : @view.Tree, fallback : AgentEntry) -> AgentEntry {
  for e in agent_snapshot(tree) {
    if e.node_id == fallback.node_id {
      return e
    }
  }
  fallback
}

///|
fn agent_mark_frame_owed(tree : @view.Tree) -> Unit {
  match view_app.val {
    Some(vt) if physical_equal(vt, tree) => h_frame_owed()
    _ => ()
  }
}

///|
/// Execute one `AgentStep` on `tree` with ambiguity checks, disabled/action validation, and `agent_confirm` gating.
pub fn agent_act(
  tree : @view.Tree,
  step : AgentStep,
  allow? : (AgentApproval) -> Bool,
) -> AgentActResult {
  let entries = agent_snapshot(tree)
  let entry = match agent_resolve_target(entries, step.target) {
    Ok(e) => e
    Err(err) => return Err(err)
  }
  if entry.disabled {
    return Err(Disabled(entry.ref_id))
  }
  let action_name = agent_action_name(step.action)
  if !entry.actions.contains(action_name) {
    return Err(UnsupportedAction("\{entry.ref_id}: \{action_name}"))
  }
  match entry.confirm {
    Some(reason) => {
      let approved = match allow {
        Some(f) => f({ entry, action: step.action, reason })
        None => false
      }
      if !approved {
        return Err(NeedsConfirm(reason))
      }
    }
    None => ()
  }
  let at = agent_tree_moment(tree)
  let ok = match step.action {
    Press => {
      let ran = tree.activate_at(entry.node_id, at)
      if ran {
        agent_mark_frame_owed(tree)
      }
      ran
    }
    Focus => {
      let ran = tree.focus_to(Some(entry.node_id), visible=true)
      if ran {
        agent_mark_frame_owed(tree)
      }
      ran
    }
    Increment => {
      let ran = tree.step_at(entry.node_id, 1, at)
      if ran {
        agent_mark_frame_owed(tree)
      }
      ran
    }
    Decrement => {
      let ran = tree.step_at(entry.node_id, -1, at)
      if ran {
        agent_mark_frame_owed(tree)
      }
      ran
    }
    SetValue(val) =>
      match agent_writers.get(entry.node_id) {
        Some(write) => {
          tree.event(at, fn() { write(val) })
          agent_mark_frame_owed(tree)
          true
        }
        None => {
          let ran = Ref(false)
          tree.event(at, fn() { ran.val = tree_field_asked(entry.node_id, SetText(val)) })
          if ran.val {
            agent_mark_frame_owed(tree)
          }
          ran.val
        }
      }
  }
  if !ok {
    return Err(UnsupportedAction("\{entry.ref_id}: \{action_name}"))
  }
  Ok(agent_refetch(tree, entry))
}

///|
/// Execute a sequence of `AgentStep`s on `tree`, stopping immediately at the first `Err`.
pub fn agent_act_all(
  tree : @view.Tree,
  steps : Array[AgentStep],
  allow? : (AgentApproval) -> Bool,
) -> Array[AgentActResult] {
  let out : Array[AgentActResult] = []
  for step in steps {
    let res = match allow {
      Some(f) => agent_act(tree, step, allow=f)
      None => agent_act(tree, step)
    }
    out.push(res)
    if res is Err(_) {
      break
    }
  }
  out
}

///|
/// Convenience `Tester` wrapper for `agent_snapshot`.
pub fn Tester::agent_snapshot(self : Tester) -> Array[AgentEntry] {
  self.reads_own()
  match view_tree() {
    Some(tree) => agent_snapshot(tree)
    None => []
  }
}

///|
/// Convenience `Tester` wrapper for `agent_query`.
pub fn Tester::agent_query(
  self : Tester,
  text? : String = "",
  role? : @view.Role,
  within? : String = "",
) -> Array[AgentEntry] {
  self.reads_own()
  match view_tree() {
    Some(tree) => agent_query(tree, text~, role?, within~)
    None => []
  }
}

///|
/// Convenience `Tester` wrapper for `agent_act`; advances one frame with `self.draw()` when the action succeeds.
pub fn Tester::agent_act(
  self : Tester,
  step : AgentStep,
  allow? : (AgentApproval) -> Bool,
) -> AgentActResult {
  self.reads_own()
  guard view_tree() is Some(tree) else { return Err(NotFound(step.target)) }
  let res = match allow {
    Some(f) => agent_act(tree, step, allow=f)
    None => agent_act(tree, step)
  }
  match res {
    Ok(entry) => {
      self.draw()
      Ok(agent_refetch(tree, entry))
    }
    Err(_) => res
  }
}

///|
fn agent_opt_bool_json(v : Bool?) -> Json {
  match v {
    Some(b) => Json::boolean(b)
    None => Json::null()
  }
}

///|
fn agent_opt_string_json(v : String?) -> Json {
  match v {
    Some(s) => Json::string(s)
    None => Json::null()
  }
}

///|
/// Serialize `entries` to a structured JSON array string suitable for LLM tool output.
pub fn agent_snapshot_json(entries : Array[AgentEntry]) -> String {
  let arr : Array[Json] = []
  for e in entries {
    let check_json = match e.check {
      Some(c) => Json::string(Show::to_string(c))
      None => Json::null()
    }
    let range_json = match e.range {
      Some((lo, cur, hi)) =>
        Json::object({
          "min": Json::number(lo),
          "value": Json::number(cur),
          "max": Json::number(hi),
        })
      None => Json::null()
    }
    let obj : Map[String, Json] = {
      "ref_id": Json::string(e.ref_id),
      "role": Json::string(Show::to_string(e.role)),
      "label": Json::string(e.label),
      "description": Json::string(e.description),
      "value": Json::string(e.value),
      "redacted": Json::boolean(e.redacted),
      "check": check_json,
      "expanded": agent_opt_bool_json(e.expanded),
      "selected": agent_opt_bool_json(e.selected),
      "pressed": agent_opt_bool_json(e.pressed),
      "disabled": Json::boolean(e.disabled),
      "range": range_json,
      "confirm": agent_opt_string_json(e.confirm),
      "actions": Json::array(e.actions.map(Json::string)),
      "source": Json::string(e.source),
    }
    arr.push(Json::object(obj))
  }
  Json::array(arr).stringify()
}
