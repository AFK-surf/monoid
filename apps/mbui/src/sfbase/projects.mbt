// Workspace chat classification foundation (PR 3 Step 0):
// - 3-state capability probe (`ProjectsCap`) reading ONLY fixed-params `chats_topic(src, ws)` (cycle-free)
// - Workspace list grouping preference (`prefs.listGroups`) with optimistic override & rollback
// - Per-workspace in-memory list filters (`ProjectFilter`, `tag`) and group collapse state
// - Client-side validation matching `station/src/store/rows.ts:129-134`
// - Park-safe paginated chains (`ProjectListChain`, `TagListChain`, `ProjectDetailChain`) bound to `View::on_rest`
// - 6 command wrappers: `chat_classify`, `proposal_resolve`, `preset_set_project`,
//   `project_update_info`, `project_rename`, `project_merge`

///|
/// Workspace `projects` feature capability, derived strictly from fixed-params `chats_topic(src, ws)` ("all", time mode).
#derive(Eq)
pub(all) enum ProjectsCap {
  /// The `"all"` chats topic has not answered yet.
  Unknown
  /// At least one non-rig station in this workspace advertises `"projects"`.
  On
  /// No non-rig station in this workspace advertises `"projects"`.
  Off
}

///|
/// Project filter applied to a workspace's chat list or board (in-memory per workspace).
#derive(Eq)
pub(all) enum ProjectFilter {
  All
  Unclassified
  Named(String)
}

///|
/// Unified chat list query combining list tab filter, optional project grouping, and optional project/tag filters.
#derive(Eq)
pub(all) struct ListQuery {
  /// "all" | "mine" | "watching" | "hidden"
  filter : String
  /// "" (time mode) | "project"
  group_by : String
  project : ProjectFilter
  tag : String?
}

///|
/// Default time-mode unfiltered list query for `filter`.
pub fn default_list_query(filter : String) -> ListQuery {
  { filter, group_by: "", project: All, tag: None }
}

///|
/// Independent reactive ticks for in-memory project UI state so clicking a proposal never wakes list filters or collapse.
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let projects_filter_tick : @signals.Signal[Int] = @signals.signal(0)

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let projects_collapse_tick : @signals.Signal[Int] = @signals.signal(0)

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let projects_proposal_tick : @signals.Signal[Int] = @signals.signal(0)

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let projects_prefs_tick : @signals.Signal[Int] = @signals.signal(0)

///|
fn bump_filter_tick() -> Unit {
  projects_filter_tick.set(projects_filter_tick.untracked() + 1)
}

///|
fn bump_collapse_tick() -> Unit {
  projects_collapse_tick.set(projects_collapse_tick.untracked() + 1)
}

///|
fn bump_proposal_tick() -> Unit {
  projects_proposal_tick.set(projects_proposal_tick.untracked() + 1)
}

///|
fn bump_prefs_tick() -> Unit {
  projects_prefs_tick.set(projects_prefs_tick.untracked() + 1)
}

///|
/// Optimistic `listGroups` override per workspace: `(value, generation, settled)`.
// kept across runs: cleared by projects_reset (pages.mbt reset)
let list_group_overrides : Map[String, (String, Int, Bool)] = Map([])

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let list_group_gen_seq : Ref[Int] = Ref(0)

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let project_filters : Map[String, ProjectFilter] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let tag_filters : Map[String, String] = Map([])

///|
/// Serialized per-workspace group collapse state (`prefs.groupCollapsed[ws]`), matching `client/core-ts/src/prefs.ts`:
/// `def` = default collapsed for all groups (including groups loaded later via `near_foot`);
/// `exc` = sorted deduplicated exception group keys whose collapsed state is `!def`.
#derive(Eq)
priv struct CollapseState {
  def : Bool
  exc : Array[String]
}

///|
/// Optimistic `groupCollapsed` override per workspace: `(state, settled)`.
// kept across runs: cleared by projects_reset (pages.mbt reset)
let group_collapse_overrides : Map[String, (CollapseState, Bool)] = Map([])

///|
/// Serial per-workspace persistence state so rapid collapse toggles never race or roll back to an uncommitted override.
// kept across runs: cleared by projects_reset (pages.mbt reset)
let group_collapse_inflight : Map[String, Bool] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let group_collapse_queued : Map[String, CollapseState] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let group_collapse_confirmed : Map[String, CollapseState] = Map([])

///|
/// Per-workspace decode cache `(raw_json, parsed_state)` so reading collapse state across N groups parses once.
// kept across runs: cleared by projects_reset (pages.mbt reset)
let group_collapse_parse_cache : Map[String, (String, CollapseState)] = Map([])

///|
/// Monotonic run id incremented by `projects_reset` so stale in-flight callbacks from a previous test/run are ignored.
// kept across runs: incremented by projects_reset (pages.mbt reset)
let group_collapse_run_seq : Ref[Int] = Ref(0)

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let grouped_collapse_hooks : Map[String, (Int, () -> Bool, (Bool) -> Unit)] = Map([])

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let grouped_collapse_hook_seq : Ref[Int] = Ref(0)

///|
// kept across runs: reset to 0 in projects_reset (pages.mbt reset)
let grouped_collapse_hooks_tick : @signals.Signal[Int] = @signals.signal(0)

///|
/// Reset all in-memory classification UI state, optimistic overrides, and pending queues.
pub fn projects_reset() -> Unit {
  list_group_overrides.clear()
  list_group_gen_seq.val = 0
  project_filters.clear()
  tag_filters.clear()
  group_collapse_overrides.clear()
  group_collapse_inflight.clear()
  group_collapse_queued.clear()
  group_collapse_confirmed.clear()
  group_collapse_parse_cache.clear()
  group_collapse_run_seq.val += 1
  grouped_collapse_hooks.clear()
  grouped_collapse_hook_seq.val = 0
  grouped_collapse_hooks_tick.set(0)
  classify_queues.clear()
  classify_inflight.clear()
  classify_desired_tags.clear()
  classify_tag_visits.clear()
  classify_visit_seq.val = 0
  proposal_pending.clear()
  proposal_optimistic.clear()
  projects_filter_tick.set(0)
  projects_collapse_tick.set(0)
  projects_proposal_tick.set(0)
  projects_prefs_tick.set(0)
}

// ── Capability & List Grouping Preference ──

///|
/// 3-state capability probe reading ONLY from fixed-params `"all"` time-mode `chats_topic(src, ws)`.
/// Never reads `list_group_by` or filtered `chats_of_query`, breaking any potential subscription cycle.
pub fn projects_cap(src : Source, ws : String) -> ProjectsCap {
  if ws == "" {
    return Off
  }
  let t = chats_topic(src, ws)
  match t.value {
    Some(Object(_)) as v => if flag(v, "projects") { On } else { Off }
    _ => Unknown
  }
}

///|
/// True iff this workspace has at least one non-rig station advertising the `projects` feature.
pub fn workspace_projects_on(src : Source, ws : String) -> Bool {
  projects_cap(src, ws) == On
}

///|
/// True iff this workspace has at least one online, non-rig, non-viewer station advertising `projects`.
pub fn workspace_projects_writable(src : Source, ws : String) -> Bool {
  if ws == "" {
    return false
  }
  let t = chats_topic(src, ws)
  match t.value {
    Some(Object(_)) as v => flag(v, "projectsWritable")
    _ => false
  }
}

///|
/// Active list grouping mode for workspace `ws`: `"project"` or `""` (time mode).
/// Returns `""` whenever `projects_cap(src, ws) != On`.
/// Unloads settled optimistic override once authoritative `prefs` matches it.
pub fn list_group_by(src : Source, ws : String) -> String {
  projects_prefs_tick.get() |> ignore
  if projects_cap(src, ws) != On {
    return ""
  }
  let prefs = src.topic("prefs", {}).get().value
  let live = match field(field(prefs, "listGroups"), ws) {
    Some(String("project")) => "project"
    _ => ""
  }
  let raw = match list_group_overrides.get(ws) {
    Some((g, _, settled)) => {
      if settled && live == g {
        list_group_overrides.remove(ws)
      }
      g
    }
    None => live
  }
  if raw == "project" { "project" } else { "" }
}

///|
/// Switch workspace `ws` list grouping (`""` for time mode, `"project"` for project grouping).
/// Optimistically updates local override with monotonic generation and persists via `prefs.set`;
/// rolls back + toasts on error only if no newer switch superseded this generation.
pub fn set_list_group_by(src : Source, ws : String, group : String) -> Unit {
  let next = if group == "project" { "project" } else { "" }
  if list_group_by(src, ws) == next {
    return
  }
  let prev = list_group_overrides.get(ws)
  list_group_gen_seq.val += 1
  let gen = list_group_gen_seq.val
  list_group_overrides[ws] = (next, gen, false)
  bump_prefs_tick()
  let patch_val : Json = if next == "project" { Json::string("project") } else { Json::null() }
  let body = Json::object({ "listGroups": Json::object(Map::from_array([(ws, patch_val)])) })
  (src.call)("prefs.set", body, fn(res) {
    match res {
      Ok(_) =>
        match list_group_overrides.get(ws) {
          Some((g, cur_gen, _)) if cur_gen == gen => {
            list_group_overrides[ws] = (g, gen, true)
            bump_prefs_tick()
          }
          _ => ()
        }
      Err(e) => {
        match list_group_overrides.get(ws) {
          Some((_, cur_gen, _)) if cur_gen == gen => {
            match prev {
              Some(p) => list_group_overrides[ws] = p
              None => list_group_overrides.remove(ws)
            }
            bump_prefs_tick()
          }
          _ => ()
        }
        let msg = text(Some(e), "message")
        toast_later(if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") })
      }
    }
  })
}

// ── Per-Workspace Filter & Group Collapse State ──

///|
pub fn project_filter_of(ws : String) -> ProjectFilter {
  projects_filter_tick.get() |> ignore
  project_filters.get(ws).unwrap_or(All)
}

///|
pub fn set_project_filter(ws : String, f : ProjectFilter) -> Unit {
  if project_filters.get(ws).unwrap_or(All) == f {
    return
  }
  match f {
    All => project_filters.remove(ws)
    _ => project_filters[ws] = f
  }
  bump_filter_tick()
}

///|
pub fn tag_filter_of(ws : String) -> String? {
  projects_filter_tick.get() |> ignore
  tag_filters.get(ws)
}

///|
pub fn set_tag_filter(ws : String, tag : String?) -> Unit {
  let next = match tag {
    Some(t) if t != "" => Some(t)
    _ => None
  }
  if tag_filters.get(ws) == next {
    return
  }
  match next {
    Some(t) => tag_filters[ws] = t
    None => tag_filters.remove(ws)
  }
  bump_filter_tick()
}

///|
pub fn clear_list_filters(ws : String) -> Unit {
  let changed = project_filters.contains(ws) || tag_filters.contains(ws)
  project_filters.remove(ws)
  tag_filters.remove(ws)
  if changed {
    bump_filter_tick()
  }
}

///|
pub fn has_active_list_filters(ws : String) -> Bool {
  projects_filter_tick.get() |> ignore
  project_filters.get(ws).unwrap_or(All) != All || tag_filters.contains(ws)
}

///|
/// Unified query constructor for a workspace's chat list pane (`sidebar_node.mbt` & `rows.mbt` `list_opens`).
/// Single-project filters automatically fall back to time grouping so there are no redundant single-group headers.
pub fn pane_list_query(src : Source, ws : String, filter : String) -> ListQuery {
  if projects_cap(src, ws) != On {
    return default_list_query(filter)
  }
  let pf = project_filter_of(ws)
  let group_by = match pf {
    All => list_group_by(src, ws)
    _ => ""
  }
  {
    filter,
    group_by,
    project: pf,
    tag: tag_filter_of(ws),
  }
}

///|
/// Active `ListQuery` for workspace `ws`'s chat list (sidebar / Home).
pub fn active_list_query(src : Source, ws : String) -> ListQuery {
  pane_list_query(src, ws, filter_of(src, ws))
}

///|
/// Single source of truth for the sidebar chat list key (`shown_days`, `list_scroll`, `held_order`, `sfdesk/keys.mbt` neighbour).
pub fn pane_scroll_key(src : Source, ws : String, filter : String) -> String {
  "chats/" + chats_query_cache_key(ws, pane_list_query(src, ws, filter))
}

///|
/// Active `ListQuery` for workspace `ws`'s board view (inherits project/tag filters without `groupBy`).
pub fn board_list_query(src : Source, ws : String) -> ListQuery {
  let filter = board_filter_of(src, ws)
  if projects_cap(src, ws) != On {
    return default_list_query(filter)
  }
  {
    filter,
    group_by: "",
    project: project_filter_of(ws),
    tag: tag_filter_of(ws),
  }
}

///|
let group_collapsed_kept : Int = 200

///|
let group_collapsed_key_max : Int = 120

///|
let group_collapsed_json_max : Int = 16384

///|
fn utf8_byte_len(s : String) -> Int {
  let mut n = 0
  for c in s {
    let cp = c.to_int()
    if cp <= 0x7F {
      n += 1
    } else if cp <= 0x7FF {
      n += 2
    } else if cp <= 0xFFFF {
      n += 3
    } else {
      n += 4
    }
  }
  n
}

///|
fn collapse_state_encode_str(def : Bool, exc : Array[String]) -> String {
  Json::object({
    "d": Json::boolean(def),
    "x": Json::array(exc.map(Json::string)),
  }).stringify()
}

///|
/// Normalize a `CollapseState` identically to `client/core-ts/src/prefs.ts` `groupCollapsedOf`:
/// valid non-empty keys <= 120 chars, deduplicated, capped at last 200 keys & <= 16384 UTF-8 JSON bytes, sorted for equality.
fn normalize_collapse_state(def : Bool, raw_exc : Array[String]) -> CollapseState {
  let seen : Map[String, Bool] = Map([])
  let uniq : Array[String] = []
  for k in raw_exc {
    if k == "" || k.length() > group_collapsed_key_max {
      continue
    }
    if !seen.contains(k) {
      seen[k] = true
      uniq.push(k)
    }
  }
  let kept = if uniq.length() > group_collapsed_kept {
    uniq[uniq.length() - group_collapsed_kept:].to_owned()
  } else {
    uniq
  }
  while !kept.is_empty() && utf8_byte_len(collapse_state_encode_str(def, kept)) > group_collapsed_json_max {
    kept.remove(0) |> ignore
  }
  kept.sort()
  { def, exc: kept }
}

///|
fn parse_group_collapsed(raw : String) -> CollapseState {
  if raw == "" || utf8_byte_len(raw) > group_collapsed_json_max {
    return { def: false, exc: [] }
  }
  let parsed : Json? = try Some(@json.parse(raw)) catch { _ => None }
  match parsed {
    Some(Object(_)) as v => {
      let def = flag(v, "d")
      let xs : Array[String] = []
      for item in items(v, "x") {
        match item {
          String(k) if k != "" && k.length() <= group_collapsed_key_max => xs.push(k)
          _ => ()
        }
      }
      normalize_collapse_state(def, xs)
    }
    _ => { def: false, exc: [] }
  }
}

///|
fn encode_group_collapsed(st : CollapseState) -> Json {
  if !st.def && st.exc.is_empty() {
    Json::null()
  } else {
    Json::string(collapse_state_encode_str(st.def, st.exc))
  }
}

///|
fn live_group_collapsed(src : Source, ws : String) -> CollapseState {
  let prefs = src.topic("prefs", {}).get().value
  let raw = match field(field(prefs, "groupCollapsed"), ws) {
    Some(String(s)) => s
    _ => ""
  }
  if raw == "" {
    group_collapse_parse_cache.remove(ws)
    return { def: false, exc: [] }
  }
  match group_collapse_parse_cache.get(ws) {
    Some((cached_raw, cached_st)) if cached_raw == raw => cached_st
    _ => {
      let parsed = parse_group_collapsed(raw)
      group_collapse_parse_cache[ws] = (raw, parsed)
      parsed
    }
  }
}

///|
/// Effective collapse state for workspace `ws`, reading live `prefs.groupCollapsed[ws]`
/// and unloading settled optimistic overrides once authoritative `prefs` catches up.
fn collapse_state_of(src : Source, ws : String) -> CollapseState {
  projects_collapse_tick.get() |> ignore
  let live = live_group_collapsed(src, ws)
  match group_collapse_overrides.get(ws) {
    Some((st, settled)) => {
      if settled && live == st {
        group_collapse_overrides.remove(ws)
        group_collapse_confirmed.remove(ws)
      }
      st
    }
    None => live
  }
}

///|
fn collapse_state_has_exc(st : CollapseState, group_key : String) -> Bool {
  st.exc.contains(group_key)
}

///|
/// Send one `prefs.set { groupCollapsed: { ws } }` at a time per workspace, coalescing newer intents while in flight.
/// On failure with no newer queued intent, rolls back cleanly to the last confirmed state (if ahead of `live`) or drops
/// the override so authoritative `prefs` takes over — never restoring an uncommitted failed override.
fn flush_group_collapse(src : Source, ws : String, state : CollapseState, run_id : Int) -> Unit {
  group_collapse_inflight[ws] = true
  let patch_val = encode_group_collapsed(state)
  let body = Json::object({ "groupCollapsed": Json::object(Map::from_array([(ws, patch_val)])) })
  (src.call)("prefs.set", body, fn(res) {
    if group_collapse_run_seq.val != run_id {
      return
    }
    match res {
      Ok(_) => {
        group_collapse_confirmed[ws] = state
        match group_collapse_queued.get(ws) {
          Some(queued) => {
            group_collapse_queued.remove(ws)
            flush_group_collapse(src, ws, queued, run_id)
          }
          None => {
            group_collapse_inflight.remove(ws)
            group_collapse_overrides[ws] = (state, true)
            bump_collapse_tick()
          }
        }
      }
      Err(e) => {
        let msg = text(Some(e), "message")
        toast_later(if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") })
        match group_collapse_queued.get(ws) {
          Some(queued) => {
            group_collapse_queued.remove(ws)
            flush_group_collapse(src, ws, queued, run_id)
          }
          None => {
            group_collapse_inflight.remove(ws)
            let live = @signals.untracked(fn() { live_group_collapsed(src, ws) })
            match group_collapse_confirmed.get(ws) {
              Some(conf) if conf != live => group_collapse_overrides[ws] = (conf, true)
              _ => {
                group_collapse_overrides.remove(ws)
                group_collapse_confirmed.remove(ws)
              }
            }
            bump_collapse_tick()
          }
        }
      }
    }
  })
}

///|
/// Optimistically update workspace `ws` group collapse state and serialize persistence via `prefs.set`.
fn commit_group_collapse(src : Source, ws : String, next_raw : CollapseState) -> Unit {
  let next = normalize_collapse_state(next_raw.def, next_raw.exc)
  let cur = @signals.untracked(fn() { collapse_state_of(src, ws) })
  if cur == next {
    return
  }
  group_collapse_overrides[ws] = (next, false)
  bump_collapse_tick()
  if group_collapse_inflight.get(ws).unwrap_or(false) {
    group_collapse_queued[ws] = next
  } else {
    flush_group_collapse(src, ws, next, group_collapse_run_seq.val)
  }
}

///|
pub fn group_collapsed(src : Source, ws : String, group_key : String) -> Bool {
  let st = collapse_state_of(src, ws)
  st.def != collapse_state_has_exc(st, group_key)
}

///|
pub fn toggle_group_collapsed(src : Source, ws : String, group_key : String) -> Unit {
  let cur = @signals.untracked(fn() { collapse_state_of(src, ws) })
  let next_exc : Array[String] = []
  let mut had = false
  for k in cur.exc {
    if k == group_key {
      had = true
    } else {
      next_exc.push(k)
    }
  }
  if !had {
    next_exc.push(group_key)
  }
  commit_group_collapse(src, ws, { def: cur.def, exc: next_exc })
}

///|
pub fn set_group_collapsed(src : Source, ws : String, group_key : String, collapsed : Bool) -> Unit {
  let cur = @signals.untracked(fn() { collapse_state_of(src, ws) })
  let want_exc = cur.def != collapsed
  let had = collapse_state_has_exc(cur, group_key)
  if had == want_exc {
    return
  }
  let next_exc : Array[String] = []
  for k in cur.exc {
    if k != group_key {
      next_exc.push(k)
    }
  }
  if want_exc {
    next_exc.push(group_key)
  }
  commit_group_collapse(src, ws, { def: cur.def, exc: next_exc })
}

///|
/// Collapse or expand all project groups in workspace `ws` at once by setting `def = collapsed`
/// and clearing per-group exceptions for `ws`, so groups loaded later via `near_foot` inherit the same state,
/// and persisting via `prefs.groupCollapsed`.
pub fn set_all_groups_collapsed(src : Source, ws : String, collapsed : Bool) -> Unit {
  commit_group_collapse(src, ws, { def: collapsed, exc: [] })
}

///|
/// True iff every group in `group_keys` is currently collapsed (or `def` when empty).
pub fn all_groups_collapsed(src : Source, ws : String, group_keys : Array[String]) -> Bool {
  let st = collapse_state_of(src, ws)
  if group_keys.is_empty() {
    return st.def
  }
  for gk in group_keys {
    let exc = collapse_state_has_exc(st, gk)
    if st.def == exc {
      return false
    }
  }
  true
}

///|
/// Register the active grouped chat list pane's collapse-all hooks for workspace `ws` so panels can trigger
/// collapse/expand inside the list's `@view.transition(within=list_view, ...)` with curtain planning.
/// Returns an ownership token that must be passed to `unregister_grouped_collapse_hook` so an older lane's
/// teardown can never remove a newer active lane's registration.
pub fn register_grouped_collapse_hook(
  ws : String,
  all_collapsed : () -> Bool,
  set_all : (Bool) -> Unit,
) -> Int {
  grouped_collapse_hook_seq.val += 1
  let token = grouped_collapse_hook_seq.val
  grouped_collapse_hooks[ws] = (token, all_collapsed, set_all)
  grouped_collapse_hooks_tick.set(grouped_collapse_hooks_tick.untracked() + 1)
  token
}

///|
pub fn unregister_grouped_collapse_hook(ws : String, token : Int) -> Unit {
  match grouped_collapse_hooks.get(ws) {
    Some((cur_token, _, _)) if cur_token == token => {
      grouped_collapse_hooks.remove(ws)
      grouped_collapse_hooks_tick.set(grouped_collapse_hooks_tick.untracked() + 1)
    }
    _ => ()
  }
}

///|
pub fn has_grouped_collapse_hook(ws : String) -> Bool {
  grouped_collapse_hooks_tick.get() |> ignore
  grouped_collapse_hooks.contains(ws)
}

///|
pub fn grouped_collapse_all_collapsed(src : Source, ws : String) -> Bool {
  grouped_collapse_hooks_tick.get() |> ignore
  match grouped_collapse_hooks.get(ws) {
    Some((_, all_col, _)) => all_col()
    None => collapse_state_of(src, ws).def
  }
}

///|
pub fn trigger_all_groups_collapse(src : Source, ws : String, collapsed : Bool) -> Unit {
  match grouped_collapse_hooks.get(ws) {
    Some((_, _, set_all)) => set_all(collapsed)
    None => set_all_groups_collapsed(src, ws, collapsed)
  }
}

// ── Client-side Validation (matches station/src/store/rows.ts:129-134) ──

///|
pub let project_name_max : Int = 80

///|
pub let tag_name_max : Int = 48

///|
pub let tags_max : Int = 3

///|
/// True if `s` contains `,` or ASCII control characters (`0x00..=0x1f`, `0x7f`).
pub fn has_forbidden_class_chars(s : String) -> Bool {
  for ch in s {
    let cp = ch.to_int()
    if cp == 44 || cp <= 0x1f || cp == 0x7f {
      return true
    }
  }
  false
}

///|
/// Validate and trim a project name (non-empty, <= 80 code units, no `,` or control chars).
pub fn validate_project_name(raw : String) -> Result[String, String] {
  let s = raw.trim().to_owned()
  if s == "" {
    return Err(@sf.t("web-main.projects.err_name_empty"))
  }
  if s.length() > project_name_max {
    return Err(@sf.t("web-main.projects.err_name_long"))
  }
  if has_forbidden_class_chars(s) {
    return Err(@sf.t("web-main.projects.err_forbidden_chars"))
  }
  Ok(s)
}

///|
/// Validate and trim a single tag name (non-empty, <= 48 code units, no `,` or control chars).
pub fn validate_tag_name(raw : String) -> Result[String, String] {
  let s = raw.trim().to_owned()
  if s == "" {
    return Err(@sf.t("web-main.projects.err_tag_empty"))
  }
  if s.length() > tag_name_max {
    return Err(@sf.t("web-main.projects.err_tag_long"))
  }
  if has_forbidden_class_chars(s) {
    return Err(@sf.t("web-main.projects.err_forbidden_chars"))
  }
  Ok(s)
}

///|
/// Trim, deduplicate (preserving order), validate each tag, and enforce <= 3 tags.
pub fn normalize_tags(raw : Array[String]) -> Result[Array[String], String] {
  let out : Array[String] = []
  let seen : Map[String, Bool] = Map([])
  for r in raw {
    let trimmed = r.trim().to_owned()
    if trimmed == "" {
      continue
    }
    match validate_tag_name(trimmed) {
      Err(e) => return Err(e)
      Ok(valid) =>
        if !seen.contains(valid) {
          seen[valid] = true
          out.push(valid)
        }
    }
  }
  if out.length() > tags_max {
    return Err(@sf.t("web-main.projects.err_tags_max"))
  }
  Ok(out)
}

// ── Paginated Topic Models (`projects`, `tags`, `project`) ──

///|
#derive(Eq)
pub(all) struct ProjectRow {
  name : String
  chat_count : Int
  running_count : Int
  alert_count : Int
  asking_count : Int
  unread_count : Int
  last_active_at : Double
  has_note : Bool
  refs_count : Int
  stations : Array[String]
}

///|
#derive(Eq)
pub(all) struct TagRow {
  tag : String
  chat_count : Int
  last_active_at : Double
}

///|
#derive(Eq)
pub(all) struct ProjectDetail {
  name : String
  note : String
  refs : Array[String]
  updated_at : Double?
  info_revision : String
  chat_count : Int
  running_count : Int
  asking_count : Int
  unread_count : Int
  /// True when every page loaded cleanly with consistent `infoRevision` and no remaining `nextCursor` (cached or live).
  complete : Bool
  /// True ONLY when `complete` AND every page received a live (non-kept, `version >= 0`) answer on this subscription.
  editable : Bool
  loading : Bool
  error : String?
}

///|
#derive(Eq)
pub(all) struct ProjectsSnapshot {
  items : Array[ProjectRow]
  total : Int
  unclassified_count : Int
  cross_count : Int
  has_more : Bool
  loading : Bool
  error : String?
}

///|
#derive(Eq)
pub(all) struct TagsSnapshot {
  items : Array[TagRow]
  total : Int
  has_more : Bool
  loading : Bool
  error : String?
}

///|
fn project_row_of(j : Json) -> ProjectRow {
  let s = Some(j)
  {
    name: text(s, "name"),
    chat_count: number(s, "chatCount").to_int(),
    running_count: number(s, "runningCount").to_int(),
    alert_count: number(s, "alertCount").to_int(),
    asking_count: number(s, "askingCount").to_int(),
    unread_count: number(s, "unreadCount").to_int(),
    last_active_at: number(s, "latestActiveAt"),
    has_note: flag(s, "hasInfo"),
    refs_count: number(s, "refsCount").to_int(),
    stations: items(s, "stations").filter_map(fn(x) {
      match x {
        String(st) => Some(st)
        _ => None
      }
    }),
  }
}

///|
fn tag_row_of(j : Json) -> TagRow {
  let s = Some(j)
  {
    tag: text(s, "name"),
    chat_count: number(s, "chatCount").to_int(),
    last_active_at: number(s, "latestActiveAt"),
  }
}

///|
/// Planned side-effect action for a paginated chain, computed purely from tracked topic reads and applied in `reacts`.
#derive(Eq)
priv enum ChainAction {
  Noop
  Lease(Array[String?])
  LeaseAndAdvance(Array[String?], Array[String?])
  Reset
  SetCursors(Array[String?], Bool)
}

///|
/// Park-safe paginated reader for the `projects` topic, bound to a `@view.View`'s `on_rest` / `owns` / `reacts`.
pub struct ProjectListChain {
  priv scope : String
  priv q : String
  priv cursors : @signals.Signal[Array[String?]]
  priv retry_tick : @signals.Signal[Int]
  priv mut generation : Int
  priv mut resting : Bool
  priv leases : Array[TopicLease]
  priv lease_keys : Map[String, Bool]
}

///|
pub fn ProjectListChain::new(scope : String, q? : String = "") -> ProjectListChain {
  {
    scope,
    q,
    cursors: @signals.signal([None]),
    retry_tick: @signals.signal(0),
    generation: 0,
    resting: false,
    leases: [],
    lease_keys: Map([]),
  }
}

///|
/// Bind this chain's lifecycle to `view`: releases all leases when parked (`on_rest`) or unmounted (`owns`),
/// resets to page 1 with a bumped generation when woken, and applies lease/stale/fork mutations inside `reacts`
/// so `read()` remains 100% pure (zero signal writes inside tracked bindings).
pub fn ProjectListChain::bind(self : ProjectListChain, view : @view.View, src : Source) -> Unit {
  view.on_rest(fn() { self.park() }, wake=fn() { self.wake() }) |> ignore
  view.owns(fn() { self.release() }) |> ignore
  view.reacts(fn() { self.plan(src) }, fn(act) { self.apply_plan(src, act) })
}

///|
pub fn ProjectListChain::generation(self : ProjectListChain) -> Int {
  self.generation
}

///|
pub fn ProjectListChain::release(self : ProjectListChain) -> Unit {
  self.generation += 1
  for l in self.leases {
    l.release()
  }
  self.leases.clear()
  self.lease_keys.clear()
}

///|
/// Release leases, explicitly refresh page 1 on the core client (sending a new subscribe request even when observed),
/// and re-subscribe from page 1 after an error.
pub fn ProjectListChain::retry(self : ProjectListChain, src : Source) -> Unit {
  if self.resting || self.scope == "" {
    return
  }
  self.release()
  (src.refresh)("projects", self.page_params(None))
  self.cursors.set([None])
  self.retry_tick.set(self.retry_tick.untracked() + 1)
}

///|
fn ProjectListChain::park(self : ProjectListChain) -> Unit {
  self.resting = true
  self.release()
}

///|
fn ProjectListChain::wake(self : ProjectListChain) -> Unit {
  self.resting = false
  self.generation += 1
  self.cursors.set([None])
  self.retry_tick.set(self.retry_tick.untracked() + 1)
}

///|
fn ProjectListChain::page_params(self : ProjectListChain, cursor : String?) -> Map[String, Json] {
  let p : Map[String, Json] = { "scope": Json::string(self.scope) }
  if self.q != "" {
    p["q"] = Json::string(self.q)
  }
  match cursor {
    Some(c) if c != "" => p["cursor"] = Json::string(c)
    _ => ()
  }
  p
}

///|
fn ProjectListChain::plan(self : ProjectListChain, src : Source) -> ChainAction {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" {
    return Noop
  }
  let cs = self.cursors.get()
  let missing : Array[String?] = []
  for i, cur in cs {
    let k = cur.unwrap_or("")
    if !self.lease_keys.contains(k) {
      missing.push(cur)
    }
    let ts = src.topic("projects", self.page_params(cur)).get()
    match ts.value {
      Some(_) as v => {
        if flag(v, "staleCursor") {
          return Reset
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 && page_nc != cs[i + 1] {
          return SetCursors(cs[:i + 1].to_owned(), true)
        }
      }
      None => ()
    }
  }
  if !missing.is_empty() {
    Lease(missing)
  } else {
    Noop
  }
}

///|
fn ProjectListChain::apply_plan(self : ProjectListChain, src : Source, act : ChainAction) -> Unit {
  if self.resting || self.scope == "" {
    return
  }
  match act {
    Noop => ()
    Lease(missing) =>
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("projects", self.page_params(cur)))
        }
      }
    LeaseAndAdvance(missing, next) => {
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("projects", self.page_params(cur)))
        }
      }
      self.cursors.set(next)
    }
    Reset => {
      self.release()
      self.cursors.set([None])
    }
    SetCursors(next, do_release) => {
      if do_release {
        self.release()
      }
      self.cursors.set(next)
    }
  }
}

///|
/// Apply any pending stale-cursor reset / link-fork truncation outside tracked reads (useful in headless tests).
pub fn ProjectListChain::sync(self : ProjectListChain, src : Source) -> Unit {
  self.apply_plan(src, @signals.untracked(fn() { self.plan(src) }))
}

///|
/// Pure tracked read of the merged snapshot across all currently requested pages (zero signal writes).
pub fn ProjectListChain::read(self : ProjectListChain, src : Source) -> ProjectsSnapshot {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" {
    return { items: [], total: 0, unclassified_count: 0, cross_count: 0, has_more: false, loading: false, error: None }
  }
  let cs = self.cursors.get()
  let out : Array[ProjectRow] = []
  let seen : Map[String, Bool] = Map([])
  let mut total = 0
  let mut unclassified_count = 0
  let mut cross_count = 0
  let mut loading = false
  let mut error : String? = None
  let mut next_cursor : String? = None
  let mut stale = false
  for i, cur in cs {
    let p = self.page_params(cur)
    let ts = src.topic("projects", p).get()
    match ts.error {
      Some(e) => if error is None { error = Some(text(Some(e), "message")) }
      None => ()
    }
    match ts.value {
      None => loading = true
      Some(_) as v => {
        if flag(v, "staleCursor") {
          stale = true
          break
        }
        if i == 0 {
          total = number(v, "total").to_int()
          unclassified_count = number(v, "unclassifiedCount").to_int()
          cross_count = number(v, "crossCount").to_int()
        }
        for raw in items(v, "items") {
          let row = project_row_of(raw)
          if row.name != "" && !seen.contains(row.name) {
            seen[row.name] = true
            out.push(row)
          }
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 {
          if page_nc != cs[i + 1] {
            next_cursor = page_nc
            break
          }
        } else {
          next_cursor = page_nc
        }
      }
    }
  }
  if stale {
    return { items: [], total: 0, unclassified_count: 0, cross_count: 0, has_more: false, loading: true, error: None }
  }
  let has_more = match next_cursor {
    Some(nc) if nc != "" => !cs.contains(Some(nc))
    _ => false
  }
  {
    items: out,
    total,
    unclassified_count,
    cross_count,
    has_more,
    loading,
    error,
  }
}

///|
/// Advance by one page if the last page returned a non-looping `nextCursor`.
pub fn ProjectListChain::load_more(self : ProjectListChain, src : Source) -> Unit {
  if self.resting || self.scope == "" {
    return
  }
  let cs = self.cursors.untracked()
  let last_cur = cs[cs.length() - 1]
  let ts = src.topic("projects", self.page_params(last_cur)).untracked()
  match opt_text(ts.value, "nextCursor") {
    Some(nc) if nc != "" && !cs.contains(Some(nc)) => {
      let next = cs.copy()
      next.push(Some(nc))
      self.cursors.set(next)
    }
    _ => ()
  }
}

///|
/// Park-safe paginated reader for the `tags` topic.
pub struct TagListChain {
  priv scope : String
  priv q : String
  priv cursors : @signals.Signal[Array[String?]]
  priv retry_tick : @signals.Signal[Int]
  priv mut generation : Int
  priv mut resting : Bool
  priv leases : Array[TopicLease]
  priv lease_keys : Map[String, Bool]
}

///|
pub fn TagListChain::new(scope : String, q? : String = "") -> TagListChain {
  {
    scope,
    q,
    cursors: @signals.signal([None]),
    retry_tick: @signals.signal(0),
    generation: 0,
    resting: false,
    leases: [],
    lease_keys: Map([]),
  }
}

///|
pub fn TagListChain::bind(self : TagListChain, view : @view.View, src : Source) -> Unit {
  view.on_rest(fn() { self.park() }, wake=fn() { self.wake() }) |> ignore
  view.owns(fn() { self.release() }) |> ignore
  view.reacts(fn() { self.plan(src) }, fn(act) { self.apply_plan(src, act) })
}

///|
pub fn TagListChain::generation(self : TagListChain) -> Int {
  self.generation
}

///|
pub fn TagListChain::release(self : TagListChain) -> Unit {
  self.generation += 1
  for l in self.leases {
    l.release()
  }
  self.leases.clear()
  self.lease_keys.clear()
}

///|
fn TagListChain::park(self : TagListChain) -> Unit {
  self.resting = true
  self.release()
}

///|
fn TagListChain::wake(self : TagListChain) -> Unit {
  self.resting = false
  self.generation += 1
  self.cursors.set([None])
  self.retry_tick.set(self.retry_tick.untracked() + 1)
}

///|
fn TagListChain::page_params(self : TagListChain, cursor : String?) -> Map[String, Json] {
  let p : Map[String, Json] = { "scope": Json::string(self.scope) }
  if self.q != "" {
    p["q"] = Json::string(self.q)
  }
  match cursor {
    Some(c) if c != "" => p["cursor"] = Json::string(c)
    _ => ()
  }
  p
}

///|
fn TagListChain::plan(self : TagListChain, src : Source) -> ChainAction {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" {
    return Noop
  }
  let cs = self.cursors.get()
  let missing : Array[String?] = []
  for i, cur in cs {
    let k = cur.unwrap_or("")
    if !self.lease_keys.contains(k) {
      missing.push(cur)
    }
    let ts = src.topic("tags", self.page_params(cur)).get()
    match ts.value {
      Some(_) as v => {
        if flag(v, "staleCursor") {
          return Reset
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 && page_nc != cs[i + 1] {
          return SetCursors(cs[:i + 1].to_owned(), true)
        }
      }
      None => ()
    }
  }
  if !missing.is_empty() {
    Lease(missing)
  } else {
    Noop
  }
}

///|
fn TagListChain::apply_plan(self : TagListChain, src : Source, act : ChainAction) -> Unit {
  if self.resting || self.scope == "" {
    return
  }
  match act {
    Noop => ()
    Lease(missing) =>
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("tags", self.page_params(cur)))
        }
      }
    LeaseAndAdvance(missing, next) => {
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("tags", self.page_params(cur)))
        }
      }
      self.cursors.set(next)
    }
    Reset => {
      self.release()
      self.cursors.set([None])
    }
    SetCursors(next, do_release) => {
      if do_release {
        self.release()
      }
      self.cursors.set(next)
    }
  }
}

///|
pub fn TagListChain::sync(self : TagListChain, src : Source) -> Unit {
  self.apply_plan(src, @signals.untracked(fn() { self.plan(src) }))
}

///|
pub fn TagListChain::read(self : TagListChain, src : Source) -> TagsSnapshot {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" {
    return { items: [], total: 0, has_more: false, loading: false, error: None }
  }
  let cs = self.cursors.get()
  let out : Array[TagRow] = []
  let seen : Map[String, Bool] = Map([])
  let mut total = 0
  let mut loading = false
  let mut error : String? = None
  let mut next_cursor : String? = None
  let mut stale = false
  for i, cur in cs {
    let p = self.page_params(cur)
    let ts = src.topic("tags", p).get()
    match ts.error {
      Some(e) => if error is None { error = Some(text(Some(e), "message")) }
      None => ()
    }
    match ts.value {
      None => loading = true
      Some(_) as v => {
        if flag(v, "staleCursor") {
          stale = true
          break
        }
        if i == 0 {
          total = number(v, "total").to_int()
        }
        for raw in items(v, "items") {
          let row = tag_row_of(raw)
          if row.tag != "" && !seen.contains(row.tag) {
            seen[row.tag] = true
            out.push(row)
          }
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 {
          if page_nc != cs[i + 1] {
            next_cursor = page_nc
            break
          }
        } else {
          next_cursor = page_nc
        }
      }
    }
  }
  if stale {
    return { items: [], total: 0, has_more: false, loading: true, error: None }
  }
  let has_more = match next_cursor {
    Some(nc) if nc != "" => !cs.contains(Some(nc))
    _ => false
  }
  {
    items: out,
    total,
    has_more,
    loading,
    error,
  }
}

///|
pub fn TagListChain::load_more(self : TagListChain, src : Source) -> Unit {
  if self.resting || self.scope == "" {
    return
  }
  let cs = self.cursors.untracked()
  let last_cur = cs[cs.length() - 1]
  let ts = src.topic("tags", self.page_params(last_cur)).untracked()
  match opt_text(ts.value, "nextCursor") {
    Some(nc) if nc != "" && !cs.contains(Some(nc)) => {
      let next = cs.copy()
      next.push(Some(nc))
      self.cursors.set(next)
    }
    _ => ()
  }
}

///|
/// Park-safe paginated reader for `project` detail (`n:` / `r:` chunks + `infoRevision` consistency check).
/// Collects BOTH `note` and `refs` on every page (including transition & final page).
/// `complete` is true when all pages share `infoRevision` and the final page has no `nextCursor` (allows read-only display);
/// `editable` is true ONLY when `complete` AND every page has received a live answer (`!ts.kept() && ts.version >= 0`).
pub struct ProjectDetailChain {
  priv scope : String
  priv name : String
  priv cursors : @signals.Signal[Array[String?]]
  priv retry_tick : @signals.Signal[Int]
  priv mut generation : Int
  priv mut resting : Bool
  priv leases : Array[TopicLease]
  priv lease_keys : Map[String, Bool]
}

///|
pub fn ProjectDetailChain::new(scope : String, name : String) -> ProjectDetailChain {
  {
    scope,
    name,
    cursors: @signals.signal([None]),
    retry_tick: @signals.signal(0),
    generation: 0,
    resting: false,
    leases: [],
    lease_keys: Map([]),
  }
}

///|
pub fn ProjectDetailChain::bind(self : ProjectDetailChain, view : @view.View, src : Source) -> Unit {
  view.on_rest(fn() { self.park() }, wake=fn() { self.wake() }) |> ignore
  view.owns(fn() { self.release() }) |> ignore
  view.reacts(fn() { self.plan(src) }, fn(act) { self.apply_plan(src, act) })
}

///|
pub fn ProjectDetailChain::generation(self : ProjectDetailChain) -> Int {
  self.generation
}

///|
pub fn ProjectDetailChain::release(self : ProjectDetailChain) -> Unit {
  self.generation += 1
  for l in self.leases {
    l.release()
  }
  self.leases.clear()
  self.lease_keys.clear()
}

///|
pub fn ProjectDetailChain::retry(self : ProjectDetailChain, src : Source) -> Unit {
  if self.resting || self.scope == "" || self.name == "" {
    return
  }
  self.release()
  (src.refresh)("project", self.page_params(None))
  self.cursors.set([None])
  self.retry_tick.set(self.retry_tick.untracked() + 1)
}

///|
fn ProjectDetailChain::park(self : ProjectDetailChain) -> Unit {
  self.resting = true
  self.release()
}

///|
fn ProjectDetailChain::wake(self : ProjectDetailChain) -> Unit {
  self.resting = false
  self.generation += 1
  self.cursors.set([None])
  self.retry_tick.set(self.retry_tick.untracked() + 1)
}

///|
fn ProjectDetailChain::page_params(self : ProjectDetailChain, cursor : String?) -> Map[String, Json] {
  let p : Map[String, Json] = {
    "scope": Json::string(self.scope),
    "name": Json::string(self.name),
  }
  match cursor {
    Some(c) if c != "" => p["cursor"] = Json::string(c)
    _ => ()
  }
  p
}

///|
fn ProjectDetailChain::plan(self : ProjectDetailChain, src : Source) -> ChainAction {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" || self.name == "" {
    return Noop
  }
  let cs = self.cursors.get()
  let missing : Array[String?] = []
  let mut first_rev = ""
  let mut loading = false
  let mut has_error = false
  let mut next_cursor : String? = None
  for i, cur in cs {
    let k = cur.unwrap_or("")
    if !self.lease_keys.contains(k) {
      missing.push(cur)
    }
    let ts = src.topic("project", self.page_params(cur)).get()
    if ts.error is Some(_) {
      has_error = true
    }
    match ts.value {
      None => loading = true
      Some(_) as v => {
        let rev = text(v, "infoRevision")
        if i == 0 {
          first_rev = rev
        } else if rev == "" || rev != first_rev {
          // Cursor link is still intact: keep the existing tail subscription alive (whether cached or previous live
          // version A) and wait for version B to arrive instead of Reset/Advance thrashing. Only cursor fork resets.
          loading = true
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 {
          if page_nc != cs[i + 1] {
            let kept = cs[:i + 1].to_owned()
            match page_nc {
              Some(nc) if nc != "" && !kept.contains(Some(nc)) => kept.push(Some(nc))
              _ => ()
            }
            return SetCursors(kept, true)
          }
        } else {
          next_cursor = page_nc
        }
      }
    }
  }
  let advance_next : Array[String?]? = match next_cursor {
    Some(nc) if nc != "" && !loading && !has_error && !cs.contains(Some(nc)) => {
      let next = cs.copy()
      next.push(Some(nc))
      Some(next)
    }
    _ => None
  }
  match (missing.is_empty(), advance_next) {
    (false, Some(next)) => LeaseAndAdvance(missing, next)
    (false, None) => Lease(missing)
    (true, Some(next)) => SetCursors(next, false)
    (true, None) => Noop
  }
}

///|
fn ProjectDetailChain::apply_plan(self : ProjectDetailChain, src : Source, act : ChainAction) -> Unit {
  if self.resting || self.scope == "" || self.name == "" {
    return
  }
  match act {
    Noop => ()
    Lease(missing) =>
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("project", self.page_params(cur)))
        }
      }
    LeaseAndAdvance(missing, next) => {
      for cur in missing {
        let k = cur.unwrap_or("")
        if !self.lease_keys.contains(k) {
          self.lease_keys[k] = true
          self.leases.push(src.lease_topic("project", self.page_params(cur)))
        }
      }
      self.cursors.set(next)
    }
    Reset => {
      self.release()
      self.cursors.set([None])
    }
    SetCursors(next, do_release) => {
      if do_release {
        self.release()
      }
      self.cursors.set(next)
    }
  }
}

///|
/// Apply any pending page advance / reset / fork truncation outside tracked reads (useful in headless tests).
pub fn ProjectDetailChain::sync(self : ProjectDetailChain, src : Source) -> Unit {
  self.apply_plan(src, @signals.untracked(fn() { self.plan(src) }))
}

///|
/// Pure tracked read of the assembled `ProjectDetail` (zero signal writes).
pub fn ProjectDetailChain::read(self : ProjectDetailChain, src : Source) -> ProjectDetail {
  self.retry_tick.get() |> ignore
  if self.resting || self.scope == "" || self.name == "" {
    return {
      name: self.name,
      note: "",
      refs: [],
      updated_at: None,
      info_revision: "",
      chat_count: 0,
      running_count: 0,
      asking_count: 0,
      unread_count: 0,
      complete: false,
      editable: false,
      loading: false,
      error: None,
    }
  }
  let cs = self.cursors.get()
  let note_buf = StringBuilder()
  let refs : Array[String] = []
  let mut updated_at : Double? = None
  let mut first_rev = ""
  let mut rev_ok = true
  let mut all_live = true
  let mut chat_count = 0
  let mut running_count = 0
  let mut asking_count = 0
  let mut unread_count = 0
  let mut loading = false
  let mut error : String? = None
  let mut next_cursor : String? = None
  let mut links_ok = true
  for i, cur in cs {
    let p = self.page_params(cur)
    let ts = src.topic("project", p).get()
    if ts.kept() || ts.version < 0 {
      all_live = false
    }
    match ts.error {
      Some(e) => if error is None { error = Some(text(Some(e), "message")) }
      None => ()
    }
    match ts.value {
      None => loading = true
      Some(_) as v => {
        let rev = text(v, "infoRevision")
        if i == 0 {
          first_rev = rev
          updated_at = opt_number(v, "updatedAt")
          chat_count = number(v, "chatCount").to_int()
          running_count = number(v, "runningCount").to_int()
          asking_count = number(v, "askingCount").to_int()
          unread_count = number(v, "unreadCount").to_int()
        } else if rev == "" || rev != first_rev {
          rev_ok = false
          loading = true
        }
        match field(v, "note") {
          Some(String(chunk)) => note_buf.write_string(chunk)
          _ => ()
        }
        for r in items(v, "refs") {
          match r {
            String(u) => refs.push(u)
            _ => ()
          }
        }
        let page_nc = opt_text(v, "nextCursor")
        if i < cs.length() - 1 {
          if page_nc != cs[i + 1] {
            links_ok = false
            break
          }
        } else {
          next_cursor = page_nc
        }
      }
    }
  }
  if !links_ok {
    return {
      name: self.name,
      note: "",
      refs: [],
      updated_at: None,
      info_revision: "",
      chat_count,
      running_count,
      asking_count,
      unread_count,
      complete: false,
      editable: false,
      loading: true,
      error: None,
    }
  }
  let has_more = match next_cursor {
    Some(nc) if nc != "" => !cs.contains(Some(nc))
    _ => false
  }
  if has_more && error is None {
    loading = true
  }
  let complete = !loading &&
    error is None &&
    next_cursor is None &&
    rev_ok &&
    links_ok &&
    first_rev != ""
  let editable = complete && all_live
  {
    name: self.name,
    note: note_buf.to_string(),
    refs,
    updated_at,
    info_revision: first_rev,
    chat_count,
    running_count,
    asking_count,
    unread_count,
    complete,
    editable,
    loading,
    error,
  }
}

// ── Command Wrappers (6 Core-TS Commands) ──

///|
/// Partial failure detail returned by `project.rename` / `project.merge`.
#derive(Eq)
pub(all) struct ProjectPeerOutcome {
  station : String
  name : String
  status : String
  ok : Bool
  error : String
}

///|
/// Structured result for `project.rename` and `project.merge`.
#derive(Eq)
pub(all) struct ProjectMutationResult {
  ok : Bool
  status : Int
  error : String
  info_error : String
  roster_error : String
  peers : Array[ProjectPeerOutcome]
}

///|
/// Structured result for `chat.classify`.
#derive(Eq)
pub(all) struct ClassifyResult {
  ok : Bool
  error : String
  info_error : String
}

///|
/// Structured result for `proposal.resolve`.
#derive(Eq)
pub(all) struct ProposalResolveResult {
  ok : Bool
  already_resolved : Bool
  status : String
  resolved_project : String?
  error : String
}

///|
/// Structured result for `preset.setProject`.
#derive(Eq)
pub(all) struct PresetProjectResult {
  ok : Bool
  synced : Bool
  forbidden : Bool
  error : String
}

///|
/// Per-chat FIFO serialization queue for `chat.classify` so rapid tag edits never race out-of-order.
// kept across runs: cleared by projects_reset (pages.mbt reset)
let classify_queues : Map[String, Array[(Json, (ClassifyResult) -> Unit)]] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let classify_inflight : Map[String, Bool] = Map([])

///|
/// Per-chat desired tag state tied to the chat visit generation (`visit`) and sent intermediate history so we distinguish:
/// - stale desired state from an ended/reopened chat visit (`st.visit != cur_visit`) -> drop & adopt fresh live tags;
/// - same-visit late intermediate echoes from our own prior writes (`live in sent_sets` or `live == base_live`) -> keep `desired`;
/// - same-visit authoritative writes from another member (`live != base_live && live not in sent_sets`) -> accept `live`!
priv struct DesiredTagsState {
  desired : Array[String]
  base_live : Array[String]
  sent_sets : Array[Array[String]]
  visit : Int
}

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let classify_desired_tags : Map[String, DesiredTagsState] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let classify_tag_visits : Map[String, Int] = Map([])

///|
// kept across runs: reset to 0 by projects_reset (pages.mbt reset)
let classify_visit_seq : Ref[Int] = Ref(0)

///|
/// Mark that a chat page has opened (or woken from rest) with a fresh live subscription for `(station, thread)`.
/// Immediately clears any completed desired tag state left over from a previous visit while preserving in-flight writes.
pub fn classify_enter_chat(station : String, thread : Double) -> Int {
  let key = station + "\u{1}" + thread.to_int().to_string()
  classify_visit_seq.val += 1
  let v = classify_visit_seq.val
  classify_tag_visits[key] = v
  if !classify_is_busy(key) {
    classify_desired_tags.remove(key)
  }
  v
}

///|
/// Mark that a chat page visit (`visit`) has left or gone to rest.
/// Clears any completed desired tag state for that chat; if a write is still in-flight, `classify_drain` clears it on completion.
pub fn classify_leave_chat(station : String, thread : Double, visit : Int) -> Unit {
  let key = station + "\u{1}" + thread.to_int().to_string()
  if classify_tag_visits.get(key) == Some(visit) {
    classify_tag_visits.remove(key)
  }
  if !classify_is_busy(key) {
    classify_desired_tags.remove(key)
  }
}

///|
fn classify_drain(src : Source, key : String) -> Unit {
  if classify_inflight.get(key).unwrap_or(false) {
    return
  }
  match classify_queues.get(key) {
    Some(q) if !q.is_empty() => {
      let (body, done) = q.remove(0)
      classify_inflight[key] = true
      (src.call)("chat.classify", body, fn(res) {
        classify_inflight.remove(key)
        match res {
          Ok(v) => {
            let info_error = text(Some(v), "infoError")
            if info_error != "" {
              toast_later(info_error)
            }
            done({ ok: true, error: "", info_error })
          }
          Err(e) => {
            let msg = text(Some(e), "message")
            let remaining = classify_queues.get(key).map_or(0, fn(qq) { qq.length() })
            if remaining == 0 {
              classify_desired_tags.remove(key)
            }
            done({
              ok: false,
              error: if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") },
              info_error: "",
            })
          }
        }
        classify_drain(src, key)
        if !classify_is_busy(key) {
          match classify_desired_tags.get(key) {
            Some(st) if st.visit != 0 && classify_tag_visits.get(key) != Some(st.visit) =>
              classify_desired_tags.remove(key)
            _ => ()
          }
        }
      })
    }
    _ => classify_queues.remove(key)
  }
}

///|
fn classify_is_busy(key : String) -> Bool {
  classify_inflight.get(key).unwrap_or(false) ||
    classify_queues.get(key).map_or(false, fn(q) { !q.is_empty() })
}

///|
fn classify_visit_stale(key : String, st : DesiredTagsState) -> Bool {
  let cur_visit = classify_tag_visits.get(key).unwrap_or(0)
  st.visit != cur_visit
}

///|
/// Reconcile a chat's desired tag state when no write is in-flight/queued:
/// - previous chat visit (`st.visit != cur_visit`): stale -> clear;
/// - `live_tags == desired`: converged -> clear;
/// - `live_tags != base_live && live_tags not in sent_sets`: external member wrote a new authoritative set -> clear;
/// - otherwise (`live_tags == base_live` or `live_tags` is one of our own earlier `sent_sets`): keep `desired`.
pub fn classify_reconcile_tags(station : String, thread : Double, live_tags : Array[String]) -> Unit {
  let key = station + "\u{1}" + thread.to_int().to_string()
  if classify_is_busy(key) {
    return
  }
  match classify_desired_tags.get(key) {
    Some(st) =>
      if classify_visit_stale(key, st) ||
        live_tags == st.desired ||
        (live_tags != st.base_live && !st.sent_sets.contains(live_tags)) {
        classify_desired_tags.remove(key)
      }
    None => ()
  }
}

///|
fn classify_tag_base(key : String, current_tags : Array[String]) -> (Array[String], Array[String], Array[Array[String]], Int) {
  let cur_visit = classify_tag_visits.get(key).unwrap_or(0)
  match classify_desired_tags.get(key) {
    Some(st) =>
      if !classify_is_busy(key) &&
        (st.visit != cur_visit ||
          current_tags == st.desired ||
          (current_tags != st.base_live && !st.sent_sets.contains(current_tags))) {
        classify_desired_tags.remove(key)
        (current_tags.copy(), current_tags.copy(), [], cur_visit)
      } else if st.visit != cur_visit {
        // Reopened chat while an older visit's write is still in-flight:
        // adopt the new visit's live baseline and assign the new edit to `cur_visit` while preserving queue serialization.
        (current_tags.copy(), current_tags.copy(), [], cur_visit)
      } else {
        (st.desired.copy(), st.base_live, st.sent_sets.copy(), st.visit)
      }
    None => (current_tags.copy(), current_tags.copy(), [], cur_visit)
  }
}

///|
/// Toggle a single tag on `(station, thread)` against the per-chat desired tag set (falling back to `current_tags`),
/// preserving rapid clicks across late echoes while adopting authoritative external member updates and fresh chat visits.
pub fn chat_toggle_tag(
  src : Source,
  station : String,
  thread : Double,
  current_tags : Array[String],
  tag : String,
  on_done? : (ClassifyResult) -> Unit = fn(_) {  },
) -> Unit {
  let key = station + "\u{1}" + thread.to_int().to_string()
  let (base, base_live, sent_sets, visit) = classify_tag_base(key, current_tags)
  let mut found = false
  let next : Array[String] = []
  for t in base {
    if t == tag {
      found = true
    } else {
      next.push(t)
    }
  }
  if !found {
    if next.length() >= tags_max {
      on_done({ ok: false, error: @sf.t("web-main.projects.err_tag_count"), info_error: "" })
      return
    }
    next.push(tag)
  }
  sent_sets.push(next.copy())
  classify_desired_tags[key] = { desired: next, base_live, sent_sets, visit }
  chat_classify(src, station, thread, tags=Some(next), on_done~)
}

///|
/// Remove a single tag on `(station, thread)` through the same per-chat desired tag queue as `chat_toggle_tag`.
pub fn chat_remove_tag(
  src : Source,
  station : String,
  thread : Double,
  current_tags : Array[String],
  tag : String,
  on_done? : (ClassifyResult) -> Unit = fn(_) {  },
) -> Unit {
  let key = station + "\u{1}" + thread.to_int().to_string()
  let (base, base_live, sent_sets, visit) = classify_tag_base(key, current_tags)
  let next = base.filter(fn(t) { t != tag })
  sent_sets.push(next.copy())
  classify_desired_tags[key] = { desired: next, base_live, sent_sets, visit }
  chat_classify(src, station, thread, tags=Some(next), on_done~)
}

///|
/// Classify a chat (serialized per `(station, thread)`).
/// Sends ONLY changed fields:
/// - `project`: `Some(Some(name))` sets named project; `Some(Some(""))` sets cross-project/other;
///   `Some(None)` clears project (`null`); `None` omits `project`.
/// - `tags`: `Some(arr)` sets tags (validated/deduped); `None` omits `tags`.
pub fn chat_classify(
  src : Source,
  station : String,
  thread : Double,
  project? : String?? = None,
  tags? : Array[String]? = None,
  on_done? : (ClassifyResult) -> Unit = fn(_) {  },
) -> Unit {
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "thread": Json::number(thread),
  }
  match project {
    None => ()
    Some(None) => params["project"] = Json::null()
    Some(Some("")) => params["project"] = Json::string("")
    Some(Some(p)) =>
      match validate_project_name(p) {
        Err(e) => {
          on_done({ ok: false, error: e, info_error: "" })
          return
        }
        Ok(valid) => params["project"] = Json::string(valid)
      }
  }
  match tags {
    None => ()
    Some(raw) =>
      match normalize_tags(raw) {
        Err(e) => {
          on_done({ ok: false, error: e, info_error: "" })
          return
        }
        Ok(valid) => params["tags"] = Json::array(valid.map(Json::string))
      }
  }
  let key = station + "\u{1}" + thread.to_int().to_string()
  let q = match classify_queues.get(key) {
    Some(existing) => existing
    None => {
      let arr = []
      classify_queues[key] = arr
      arr
    }
  }
  q.push((Json::object(params), on_done))
  classify_drain(src, key)
}

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let proposal_pending : Map[String, Bool] = Map([])

///|
// kept across runs: cleared by projects_reset (pages.mbt reset)
let proposal_optimistic : Map[String, (String, String?)] = Map([])

///|
fn proposal_key(station : String, thread : Double, seq : Double) -> String {
  station + "\u{1}" + thread.to_int().to_string() + "\u{1}" + seq.to_int().to_string()
}

///|
/// True while a `proposal.resolve` request is in-flight for `(station, thread, seq)`.
pub fn proposal_is_pending(station : String, thread : Double, seq : Double) -> Bool {
  projects_proposal_tick.get() |> ignore
  proposal_pending.get(proposal_key(station, thread, seq)).unwrap_or(false)
}

///|
/// Optimistic resolved state `(status, resolved_project)` for `(station, thread, seq)` if set locally.
pub fn proposal_optimistic_state(station : String, thread : Double, seq : Double) -> (String, String?)? {
  projects_proposal_tick.get() |> ignore
  proposal_optimistic.get(proposal_key(station, thread, seq))
}

///|
/// Clear optimistic proposal state once authoritative live non-pending status arrives.
pub fn proposal_clear_optimistic(station : String, thread : Double, seq : Double) -> Unit {
  let pk = proposal_key(station, thread, seq)
  if proposal_optimistic.contains(pk) {
    proposal_optimistic.remove(pk)
  }
}

///|
/// Resolve a silent project proposal bar (`action`: `"accept"` | `"reassign"` | `"dismiss"`).
/// - `"accept"`: optional `name` (renamed), optional `note`, optional `refs`
/// - `"reassign"`: `target` (existing project name, or `""` for cross-project/other)
/// - `"dismiss"`: optional `mark_cross` (true => sets `markCross: true`)
/// Sends `entryN` (matching `calls.ts:475`), unlocks pending state on 200 (including `alreadyResolved: true`),
/// and converges optimistic state (`"accepted" | "reassigned" | "dismissed"`).
pub fn proposal_resolve(
  src : Source,
  station : String,
  thread : Double,
  entry_n : Double,
  action : String,
  name? : String? = None,
  note? : String? = None,
  refs? : Array[String]? = None,
  target? : String? = None,
  mark_cross? : Bool = false,
  on_done? : (ProposalResolveResult) -> Unit = fn(_) {  },
) -> Unit {
  let pk = proposal_key(station, thread, entry_n)
  if proposal_pending.get(pk).unwrap_or(false) {
    return
  }
  let params : Map[String, Json] = {
    "station": Json::string(station),
    "thread": Json::number(thread),
    "entryN": Json::number(entry_n),
    "action": Json::string(action),
  }
  if action == "accept" {
    match name {
      Some(raw) =>
        match validate_project_name(raw) {
          Err(e) => {
            on_done({ ok: false, already_resolved: false, status: "", resolved_project: None, error: e })
            return
          }
          Ok(valid) => params["name"] = Json::string(valid)
        }
      None => ()
    }
    match note {
      Some(n) => params["note"] = Json::string(n)
      None => ()
    }
    match refs {
      Some(rs) => params["refs"] = Json::array(rs.map(Json::string))
      None => ()
    }
  } else if action == "reassign" {
    match target {
      Some(raw) if raw.trim().to_owned() != "" =>
        match validate_project_name(raw) {
          Err(e) => {
            on_done({ ok: false, already_resolved: false, status: "", resolved_project: None, error: e })
            return
          }
          Ok(valid) => params["target"] = Json::string(valid)
        }
      _ => {
        on_done({
          ok: false,
          already_resolved: false,
          status: "",
          resolved_project: None,
          error: @sf.t("web-main.projects.err_name_empty"),
        })
        return
      }
    }
  } else if action == "dismiss" && mark_cross {
    params["markCross"] = Json::boolean(true)
  }
  proposal_pending[pk] = true
  bump_proposal_tick()
  (src.call)("proposal.resolve", Json::object(params), fn(res) {
    proposal_pending.remove(pk)
    match res {
      Ok(v) => {
        let s = Some(v)
        let already_resolved = flag(s, "alreadyResolved")
        // Station returns `{ proposal: { status, resolvedProject, ... }, thread, alreadyResolved, infoError? }`;
        // fall back to top-level fields only for flat test mocks.
        let (p_obj, has_nested) = match field(s, "proposal") {
          Some(Object(_)) as p => (p, true)
          _ => (s, false)
        }
        let st = match text(p_obj, "status") {
          "" =>
            if action == "accept" {
              "accepted"
            } else if action == "reassign" {
              "reassigned"
            } else {
              "dismissed"
            }
          other => other
        }
        let rp = match field(p_obj, "resolvedProject") {
          Some(String(p)) => Some(p)
          Some(Null) => None
          _ =>
            if has_nested {
              // Authoritative nested `proposal` omitted `resolvedProject`: keep `None`
              // (never fabricate `Some("")` from local `mark_cross`).
              None
            } else if action == "accept" {
              name
            } else if action == "reassign" {
              target
            } else if mark_cross {
              Some("")
            } else {
              None
            }
        }
        let info_err = text(s, "infoError")
        if info_err != "" {
          // PROJECTS.jsonl registration failed after DB resolution: keep the bar retryable so the user
          // can replay the idempotent `proposal.resolve` request once shared file storage recovers.
          proposal_optimistic.remove(pk)
          bump_proposal_tick()
          on_done({ ok: false, already_resolved, status: st, resolved_project: rp, error: info_err })
        } else {
          proposal_optimistic[pk] = (st, rp)
          bump_proposal_tick()
          on_done({ ok: true, already_resolved, status: st, resolved_project: rp, error: "" })
        }
      }
      Err(e) => {
        bump_proposal_tick()
        let msg = text(Some(e), "message")
        on_done({
          ok: false,
          already_resolved: false,
          status: "",
          resolved_project: None,
          error: if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") },
        })
      }
    }
  })
}

///|
/// Bind or unbind a preset's default project (`project = Some(name)` or `None` to clear).
/// Sends `presetId` (matching `calls.ts:462`), handles 403 (read-only viewer) and `synced: false`.
pub fn preset_set_project(
  src : Source,
  scope : String,
  preset_id : String,
  project : String?,
  on_done? : (PresetProjectResult) -> Unit = fn(_) {  },
) -> Unit {
  let proj_json : Json = match project {
    None => Json::null()
    Some("") => Json::string("")
    Some(raw) =>
      match validate_project_name(raw) {
        Err(e) => {
          on_done({ ok: false, synced: false, forbidden: false, error: e })
          return
        }
        Ok(valid) => Json::string(valid)
      }
  }
  let body = Json::object({
    "scope": Json::string(scope),
    "presetId": Json::string(preset_id),
    "project": proj_json,
  })
  (src.call)("preset.setProject", body, fn(res) {
    match res {
      Ok(v) => {
        let synced = match field(Some(v), "synced") {
          Some(False) => false
          _ => true
        }
        on_done({ ok: true, synced, forbidden: false, error: "" })
      }
      Err(e) => {
        let s = Some(e)
        let code = text(s, "code")
        let status = number(s, "status").to_int()
        let forbidden = status == 403 || code == "http_403" || code == "forbidden"
        let msg = text(s, "message")
        on_done({
          ok: false,
          synced: false,
          forbidden,
          error: if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") },
        })
      }
    }
  })
}

///|
/// Update project metadata (`note` and/or `refs`) in workspace `scope`.
/// Sends ONLY changed fields (`Some(...)` writes the field; `None` omits it so concurrent edits to the other field
/// are preserved). Explicit `Some("")` / `Some([])` clears the respective field.
/// Callers MUST ensure `ProjectDetail.complete == true` before saving to avoid overwriting truncated content.
pub fn project_update_info(
  src : Source,
  scope : String,
  name : String,
  note? : String? = None,
  refs? : Array[String]? = None,
  on_done? : (Result[Unit, String]) -> Unit = fn(_) {  },
) -> Unit {
  let valid_name = match validate_project_name(name) {
    Err(e) => {
      on_done(Err(e))
      return
    }
    Ok(v) => v
  }
  let body : Map[String, Json] = {
    "scope": Json::string(scope),
    "name": Json::string(valid_name),
  }
  match note {
    Some(n) => body["note"] = Json::string(n)
    None => ()
  }
  match refs {
    Some(rs) => body["refs"] = Json::array(rs.map(Json::string))
    None => ()
  }
  (src.call)("project.updateInfo", Json::object(body), fn(res) {
    match res {
      Ok(_) => on_done(Ok(()))
      Err(e) => {
        let msg = text(Some(e), "message")
        on_done(Err(if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") }))
      }
    }
  })
}

///|
fn parse_mutation_ok(v : Json) -> ProjectMutationResult {
  let s = Some(v)
  let peers : Array[ProjectPeerOutcome] = items(s, "peers").map(fn(p) {
    let ps = Some(p)
    let st = text(ps, "status")
    let station = text(ps, "station")
    let pname = match text(ps, "name") {
      "" => station
      n => n
    }
    let peer_ok = if st != "" { st == "ok" } else { flag(ps, "ok") }
    {
      station,
      name: pname,
      status: st,
      ok: peer_ok,
      error: text(ps, "error"),
    }
  })
  {
    ok: true,
    status: 200,
    error: "",
    info_error: text(s, "infoError"),
    roster_error: text(s, "rosterError"),
    peers,
  }
}

///|
fn parse_mutation_err(e : Json) -> ProjectMutationResult {
  let s = Some(e)
  let code = text(s, "code")
  let status = match field(s, "status") {
    Some(Number(n, ..)) => n.to_int()
    _ => if code == "http_409" || code == "conflict" { 409 } else { 0 }
  }
  let msg = text(s, "message")
  {
    ok: false,
    status,
    error: if msg != "" { msg } else { @sf.t("web-main.projects.save_failed") },
    info_error: "",
    roster_error: "",
    peers: [],
  }
}

///|
/// Rename a project across all online stations in workspace `scope`.
/// Parses `peers[]`, `rosterError`, `infoError`, and 409 conflict status.
pub fn project_rename(
  src : Source,
  scope : String,
  from : String,
  to : String,
  on_done? : (ProjectMutationResult) -> Unit = fn(_) {  },
) -> Unit {
  let valid_to = match validate_project_name(to) {
    Err(e) => {
      on_done({ ok: false, status: 400, error: e, info_error: "", roster_error: "", peers: [] })
      return
    }
    Ok(v) => v
  }
  let body = Json::object({
    "scope": Json::string(scope),
    "from": Json::string(from),
    "to": Json::string(valid_to),
  })
  (src.call)("project.rename", body, fn(res) {
    match res {
      Ok(v) => on_done(parse_mutation_ok(v))
      Err(e) => on_done(parse_mutation_err(e))
    }
  })
}

///|
/// Merge project `from` into `to` (supports `to == ""` for cross-project/other).
/// Parses `peers[]`, `rosterError`, `infoError`, and 409 conflict status.
pub fn project_merge(
  src : Source,
  scope : String,
  from : String,
  to : String,
  on_done? : (ProjectMutationResult) -> Unit = fn(_) {  },
) -> Unit {
  let valid_to = if to == "" {
    ""
  } else {
    match validate_project_name(to) {
      Err(e) => {
        on_done({ ok: false, status: 400, error: e, info_error: "", roster_error: "", peers: [] })
        return
      }
      Ok(v) => v
    }
  }
  let body = Json::object({
    "scope": Json::string(scope),
    "from": Json::string(from),
    "to": Json::string(valid_to),
  })
  (src.call)("project.merge", body, fn(res) {
    match res {
      Ok(v) => on_done(parse_mutation_ok(v))
      Err(e) => on_done(parse_mutation_err(e))
    }
  })
}
