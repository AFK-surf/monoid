// Profiles batch management page (批量管理, `Route::ProfilesManage(only)`):
// Dedicated workspace-wide (`only == ""`) or single-station (`only != ""`) page where workspace managers filter
// accounts by host station and sharing policy, edit a single account's policy via an authoritative on-demand
// `station` TopicLease, or tick multiple accounts to batch share, move, refresh quota, stop sharing, or delete
// via the floating liquid-glass action bar.

///|
/// Concise sharing status summary for manageable single-host own accounts, shown under 批量管理 in the sidebar
/// and list. Includes offline hosts (`why == "" || why == "offline"`) so the denominator stays stable across
/// station offline/online transitions.
pub fn profiles_sharing_summary(rows : Array[Json]) -> String {
  let manageable = rows.filter(fn(r) {
    let why = text(Some(r), "batchShareWhy")
    why == "" || why == "offline"
  })
  let total = manageable.length()
  if total == 0 {
    return ""
  }
  let shared = manageable.filter(fn(r) { flag(Some(r), "shared") }).length()
  let unshared = total - shared
  if unshared == 0 {
    @sf.t("web-pages.profiles.sharing.summaryAllShared")
  } else if shared == 0 {
    @sf.t("web-pages.profiles.sharing.summaryUnshared", args=[("n", unshared.to_string())])
  } else {
    @sf.t("web-pages.profiles.sharing.summarySharedCount", args=[("shared", shared.to_string()), ("total", total.to_string())])
  }
}

///|
/// Short policy button label for a shareable row.
fn pm_policy_label(ev : Json?) -> String {
  if !flag(ev, "shared") {
    @sf.t("web-pages.profiles.sharing.policy.unshared")
  } else if flag(ev, "shareAuto") {
    @sf.t("web-pages.profiles.sharing.policy.whitelist")
  } else {
    match field(ev, "shareStationCount") {
      Some(Number(n, ..)) =>
        @sf.t("web-pages.profiles.sharing.policy.stations", args=[("n", n.to_int().to_string())])
      _ => @sf.t("web-pages.profiles.sharing.policy.all")
    }
  }
}

///|
/// Concise status label and semantic tone (`"red"` / `"amber"` / `"ok"`) for the table's `状态` column.
/// Delegates quota severity to core's `window.level` (`"red"` / `"amber"` / `"ok"`), preferring account-wide
/// windows (`scope == ""`) so a single-model limit does not mark the whole account.
fn pm_status_of(ev : Json?) -> (String, String) {
  let st = field(ev, "state")
  let st_text = text(st, "text")
  if st_text != "" {
    let tone = match text(st, "tone") {
      "red" => "red"
      "amber" => "amber"
      _ => "ok"
    }
    return (st_text, tone)
  }
  if !flag(ev, "usable") {
    return (@sf.t("web-pages.profiles.manage.statusIssue"), "red")
  }
  let quota = field(field(ev, "profile"), "quota")
  if text(quota, "state") == "ok" {
    let all_ws = items(quota, "windows")
    let acct_ws = all_ws.filter(fn(w) { text(Some(w), "scope") == "" })
    let ws = if acct_ws.is_empty() { all_ws } else { acct_ws }
    if !ws.is_empty() {
      let mut best_rank = -1
      let mut low_left = 101
      let mut low_mark = ""
      let mut low_tone = "ok"
      for w in ws {
        let wv = Some(w)
        let left = match field(wv, "left") {
          Some(Number(n, ..)) => n.to_int()
          _ => 101
        }
        let tone = match text(wv, "level") {
          "red" => "red"
          "amber" => "amber"
          "ok" => "ok"
          _ => if left <= 0 { "red" } else { "ok" }
        }
        let rank = match tone {
          "red" => 2
          "amber" => 1
          _ => 0
        }
        if rank > best_rank || (rank == best_rank && left < low_left) {
          best_rank = rank
          low_left = left
          low_mark = text(wv, "mark")
          low_tone = tone
        }
      }
      if low_left <= 100 {
        let short_mark = if low_mark.length() > 4 {
          let parts = low_mark.split(" ").collect()
          if parts.length() > 0 {
            parts[parts.length() - 1].to_owned()
          } else {
            ""
          }
        } else {
          low_mark
        }
        let lbl = if short_mark != "" && short_mark.length() <= 4 {
          short_mark + " " + low_left.to_string() + "%"
        } else {
          low_left.to_string() + "%"
        }
        return (lbl, low_tone)
      }
    }
  }
  if flag(ev, "look") {
    return (@sf.t("web-pages.profiles.manage.statusIssue"), "amber")
  }
  if text(quota, "state") == "ok" && text(quota, "creditsText") != "" {
    let credits = text(quota, "creditsText")
    let detail = text(quota, "detail")
    let lbl = if detail != "" { credits + " · " + detail } else { credits }
    return (lbl, "ok")
  }
  let grp = text(ev, "group")
  if grp != "" && grp != "key" {
    if quota is (None | Some(Null)) {
      return (@sf.t("web-main.quota.unchecked"), "ok")
    } else if text(quota, "detail") != "" {
      return (text(quota, "detail"), "ok")
    } else if text(quota, "state") == "unsupported" {
      return (@sf.t("android-settings.quota.none"), "ok")
    } else if text(quota, "state") != "ok" {
      return (@sf.t("web-main.quota.unknown"), "ok")
    }
  }
  (@sf.t("web-pages.profiles.manage.statusOk"), "ok")
}

///|
/// Whether a batch-management row should render live compact quota chips in its `状态` cell
/// (usable account without an overriding error/login state text, and at least one quota window).
fn pm_shows_quota_chips(ev : Json?) -> Bool {
  text(field(ev, "state"), "text") == "" &&
  flag(ev, "usable") &&
  @sfbase.has_quota(field(field(ev, "profile"), "quota"))
}

///|
/// An entry in the grouped batch-management table: either a provider group subheader (`"g/<group>"`) or an account
/// row (`"r/<key>"`), each carrying its narrow card piece.
#derive(Eq)
priv enum PmTableItem {
  PmGroup(String, @sf.CardPiece)
  PmRow(Json, @sf.CardPiece)
}

///|
fn pm_item_same(a : (String, PmTableItem), b : (String, PmTableItem)) -> Bool {
  a.0 == b.0 &&
  (match (a.1, b.1) {
    (PmGroup(ta, pa), PmGroup(tb, pb)) => ta == tb && pa == pb
    (PmRow(ra, pa), PmRow(rb, pb)) => pa == pb && json_same(ra, rb)
    _ => false
  })
}

///|
/// Groups `base` by `(group, groupTitle)` in first-seen order (matching the sidebar and profile list), sorting rows
/// within each group when `sort` is active so profile groups stay intact under sorting.
fn pm_grouped_rows(
  base : Array[Json],
  sort : @sf.TableSort?,
  stations : Array[Json],
) -> Array[(String, String, Array[Json])] {
  let groups : Array[(String, String, Array[Json])] = []
  for r in base {
    let g = text(Some(r), "group")
    match groups.search_by(fn(x) { x.0 == g }) {
      Some(i) => groups[i].2.push(r)
      None => groups.push((g, text(Some(r), "groupTitle"), [r]))
    }
  }
  match sort {
    None => groups
    Some(ts) => {
      let sts = if ts.col == "station" { stations } else { [] }
      groups.map(fn(grp) {
        let indexed : Array[(Int, Json)] = []
        for i, r in grp.2 {
          indexed.push((i, r))
        }
        indexed.sort_by(fn(a, b) { pm_compare_rows(a, b, ts.col, ts.dir, sts) })
        (grp.0, grp.1, indexed.map(fn(x) { x.1 }))
      })
    }
  }
}

///|
/// Sort key `(severity_rank, remaining_pct)` for the `状态` column:
/// `0 = red` (most urgent) -> `1 = amber` -> `2 = ok` with quota window (lowest % first) -> `3 = ok` without window.
fn pm_status_sort_key(ev : Json?) -> (Int, Int) {
  let st = field(ev, "state")
  if text(st, "text") != "" {
    let rank = match text(st, "tone") {
      "red" => 0
      "amber" => 1
      _ => 2
    }
    return (rank, if rank == 2 { 100 } else { 0 })
  }
  if !flag(ev, "usable") {
    return (0, 0)
  }
  let quota = field(field(ev, "profile"), "quota")
  if text(quota, "state") == "ok" {
    let all_ws = items(quota, "windows")
    let acct_ws = all_ws.filter(fn(w) { text(Some(w), "scope") == "" })
    let ws = if acct_ws.is_empty() { all_ws } else { acct_ws }
    if !ws.is_empty() {
      let mut best_rank = 3
      let mut low_left = 101
      for w in ws {
        let wv = Some(w)
        let left = match field(wv, "left") {
          Some(Number(n, ..)) => n.to_int()
          _ => 101
        }
        let rank = match text(wv, "level") {
          "red" => 0
          "amber" => 1
          "ok" => 2
          _ => if left <= 0 { 0 } else { 2 }
        }
        if rank < best_rank || (rank == best_rank && left < low_left) {
          best_rank = rank
          low_left = left
        }
      }
      if low_left <= 100 {
        return (best_rank, low_left)
      }
    }
  }
  if flag(ev, "look") {
    return (1, 101)
  }
  (3, 101)
}

///|
/// Sort key for the `共享` column: `0 = unshared`, `1 = whitelist`, `100 + N = N stations`, `100000 = all stations`,
/// `None = unshareable/unsupported` (always sinks to the bottom regardless of sort direction).
fn pm_share_sort_key(ev : Json?) -> Int? {
  if !flag(ev, "canBatchShare") {
    return None
  }
  if !flag(ev, "shared") {
    Some(0)
  } else if flag(ev, "shareAuto") {
    Some(1)
  } else {
    match field(ev, "shareStationCount") {
      Some(Number(n, ..)) => Some(100 + n.to_int())
      _ => Some(100000)
    }
  }
}

///|
/// Lexicographical UTF-16 code-unit comparison (unlike MoonBit's shortlex `String::compare`).
fn pm_lexical_compare(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let n = if la < lb { la } else { lb }
  for i = 0; i < n; i = i + 1 {
    let ca = a.code_unit_at(i).to_int()
    let cb = b.code_unit_at(i).to_int()
    if ca != cb {
      return ca - cb
    }
  }
  la - lb
}

///|
/// Compares two indexed rows `(orig_idx, row)` by `sort` column and direction, preserving original order on ties.
fn pm_compare_rows(
  a : (Int, Json),
  b : (Int, Json),
  col : String,
  dir : @sf.SortDir,
  stations : Array[Json],
) -> Int {
  let asc = dir is Asc
  let ra = Some(a.1)
  let rb = Some(b.1)
  let primary = match col {
    "account" => {
      let c = pm_lexical_compare(profiles_batch_name(ra).to_lower(), profiles_batch_name(rb).to_lower())
      if asc { c } else { -c }
    }
    "station" => {
      let sa = pm_station_name(stations, text(ra, "station")).to_lower()
      let sb = pm_station_name(stations, text(rb, "station")).to_lower()
      let c = pm_lexical_compare(sa, sb)
      if asc { c } else { -c }
    }
    "status" => {
      let (ka0, ka1) = pm_status_sort_key(ra)
      let (kb0, kb1) = pm_status_sort_key(rb)
      let c = if ka0 != kb0 { ka0 - kb0 } else { ka1 - kb1 }
      if asc { c } else { -c }
    }
    "sharing" =>
      match (pm_share_sort_key(ra), pm_share_sort_key(rb)) {
        (None, None) => 0
        (None, Some(_)) => 1
        (Some(_), None) => -1
        (Some(x), Some(y)) => {
          let c = x - y
          if asc { c } else { -c }
        }
      }
    _ => 0
  }
  if primary != 0 {
    primary
  } else {
    a.0 - b.0
  }
}

///|
/// Whether a row has an active issue: aligned 1:1 with `pm_status_of` tone and core's `look` flag.
fn pm_row_has_issue(r : Json) -> Bool {
  let rv = Some(r)
  pm_status_of(rv).1 != "ok" || flag(rv, "look")
}

///|
/// Whether a row matches the selected health status filter: 0=All, 1=Healthy, 2=Needs attention.
fn pm_matches_status(r : Json, filter : Int) -> Bool {
  match filter {
    1 => !pm_row_has_issue(r)
    2 => pm_row_has_issue(r)
    _ => true
  }
}

///|
/// Whether a row matches the selected sharing policy filter: 0=All, 1=Unshared, 2=Whitelist, 3=Manual.
fn pm_matches_share(r : Json, filter : Int) -> Bool {
  let rv = Some(r)
  match filter {
    1 => !flag(rv, "shared")
    2 => flag(rv, "shared") && flag(rv, "shareAuto")
    3 => flag(rv, "shared") && !flag(rv, "shareAuto")
    _ => true
  }
}

///|
/// Station display name for a row's `station` address, looked up from the workspace's `stations` list.
fn pm_station_name(stations : Array[Json], address : String) -> String {
  for s in stations {
    if text(Some(s), "station") == address {
      let n = text(Some(s), "name")
      if n != "" {
        return n
      }
    }
  }
  @settings.station_name(address)
}

///|
/// Projects a single station's `station` topic value (`profileGroups` + `overview.profiles`) into workspace-filtered
/// batch rows. Falls back to `overview.profiles` (excluding non-serving borrowed copies) only when `profileGroups` is
/// absent.
fn pm_station_rows(only : String, st : Json?, one : Json?, stations : Array[Json]) -> Array[Json] {
  let ov = field(st, "overview")
  let profs = items(ov, "profiles")
  if profs.is_empty() {
    return []
  }
  let by_id : Map[String, Json] = Map([])
  for p in profs {
    let id = text(Some(p), "id")
    if id != "" {
      by_id[id] = p
    }
  }
  match field(st, "profileGroups") {
    Some(Array(groups)) => {
      let out : Array[Json] = []
      for g in groups {
        let gv = Some(g)
        let g_kind = text(gv, "group")
        let g_title = text(gv, "title")
        for id in strings(gv, "profiles") {
          match by_id.get(id) {
            Some(p) => out.push(profiles_batch_row(only, p, ov, one, stations~, group=g_kind, group_title=g_title))
            None => ()
          }
        }
      }
      out
    }
    _ =>
      // Fallback when profileGroups is absent: exclude borrowed copies (`role == "user"`).
      profs.filter_map(fn(p) {
        let sh = field(Some(p), "share")
        if text(sh, "role") == "user" {
          None
        } else {
          Some(profiles_batch_row(only, p, ov, one, stations~))
        }
      })
  }
}

///|
/// The Profiles batch management page (`Route::ProfilesManage(only)`) in node `v`.
pub fn profiles_manage_node(
  v : @view.View,
  src : Source,
  core : Core,
  here : () -> Here,
  only : String,
  on_back~ : () -> Unit,
  frame~ : () -> PageFrame,
  said? : (@sf.PageSaid) -> Unit,
  width? : () -> Double,
  tips? : @sf.TipLayer,
  in_place? : Bool = false,
  active? : () -> Bool = fn() { true },
) -> Unit {
  let tips = match tips {
    Some(t) => t
    None => @sf.TipLayer::new(fn() { Some(v) })
  }
  let batch = ProfilesBatch::new()
  let status_filter : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let share_filter : @signals.Signal[Int] = @signals.signal(0, same=fn(a, b) { a == b })
  let group_filter : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
  let station_filter : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
  let sort_state : @signals.Signal[@sf.TableSort?] = @signals.signal(None)
  let loading_key : @signals.Signal[String] = @signals.signal("", same=fn(a, b) { a == b })
  let pending_edit : Ref[(@sfbase.PressWait, @sfbase.TopicLease)?] = Ref(None)
  let alive : Ref[Bool] = Ref(true)
  let ws_at_build : Ref[String] = Ref(@signals.untracked(fn() { here().workspace }))
  let cancel_pending = fn() {
    match pending_edit.val {
      Some((pw, lease)) => {
        pending_edit.val = None
        loading_key.set("")
        pw.give_up()
        lease.release()
      }
      None => loading_key.set("")
    }
  }
  v.on_leaving(fn() {
    alive.val = false
    cancel_pending()
  })
  |> ignore
  let profiles_topic = fn() { (core.topic)("profiles", { "scope": str(here().workspace) }).get() }
  let stations_topic = fn() { @settings.stations_of(core, here()) }
  let stations_now = @signals.computed(fn(_) {
    match stations_topic().value {
      Some(Array(a)) => a
      _ => []
    }
  }, same=jsons_same)
  let stations_list = fn() { stations_now.get() }
  let one_now = @signals.computed(fn(_) {
    if only == "" {
      None
    } else {
      stations_list().iter().find_first(fn(x) { text(Some(x), "station") == only })
    }
  }, same=json_opt_same)
  let station_read_opt = fn() {
    if only == "" {
      None
    } else {
      Some(@settings.station_read(core, here(), only))
    }
  }
  let station_topic = fn() {
    match station_read_opt() {
      Some(r) =>
        match r.value {
          Some(Object(_)) as s => s
          _ => None
        }
      None => None
    }
  }
  let manages_state = fn() -> Bool? {
    if only == "" {
      match profiles_topic().value {
        Some(_) as pv => Some(flag(pv, "manages"))
        None => None
      }
    } else {
      @settings.manager_of(core, here())
    }
  }
  let still_here = fn() {
    let live_ws = match @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) {
      Some(w) => w.id == ws_at_build.val
      None => false
    }
    alive.val &&
    @signals.untracked(active) &&
    live_ws &&
    @signals.untracked(manages_state) == Some(true)
  }
  // Reset state and cancel any in-flight single-row read on workspace switch.
  v.reacts(fn() { here().workspace }, fn(ws) {
    ws_at_build.val = ws
    cancel_pending()
    batch.clear()
    status_filter.set(0)
    share_filter.set(0)
    group_filter.set("")
    station_filter.set("")
    sort_state.set(None)
  }, at_start=false)
  // Cancel pending single-row edit if wide sidebar switches away from Manage.
  v.reacts(active, fn(on) { if !on { cancel_pending() } }, at_start=false)
  // Auto-reset station filter if the filtered station disappears from the workspace list.
  if only == "" {
    v.reacts(stations_list, fn(sts) {
      let cur = @signals.untracked(fn() { station_filter.get() })
      if cur != "" && !sts.iter().any(fn(s) { text(Some(s), "station") == cur }) {
        station_filter.set("")
      }
    })
  }
  // Demotion handling: cancel pending edit, clear selection, and pop non-place stack pages.
  v.reacts(fn() { manages_state() == Some(false) }, fn(no) {
    if no {
      cancel_pending()
      batch.clear()
      if !in_place {
        on_back()
      }
    }
  })
  // Authoritative single-row policy edit via TopicLease (no raw reader leak, no open_hold_ms fallback).
  let open_single_policy = fn(row : Json) {
    cancel_pending()
    let rv = Some(row)
    let row_key = text(rv, "key")
    let address = text(rv, "station")
    let p = field(rv, "profile")
    let id = text(p, "id")
    if address == "" || id == "" {
      return
    }
    let ws = @signals.untracked(fn() { here().workspace })
    let station_params : Map[String, Json] = {
      "scope": Json::string(@sfbase.account_scope(ws, address)),
      "station": Json::string(address),
    }
    let lease = src.lease_topic("station", station_params)
    loading_key.set(row_key)
    let opened = Ref(false)
    let open_now = fn() {
      if opened.val {
        return
      }
      opened.val = true
      let st_opt = lease.read()
      pending_edit.val = None
      if @signals.untracked(fn() { loading_key.get() }) == row_key {
        loading_key.set("")
      }
      lease.release()
      if !@signals.untracked(still_here) {
        return
      }
      let sts = @signals.untracked(stations_list)
      let st_val = match st_opt {
        Some(st) if st.error is None => st.value
        _ => None
      }
      let ov = field(st_val, "overview")
      let full_p = match ov {
        Some(Object(_)) => items(ov, "profiles").iter().find_first(fn(x) { text(Some(x), "id") == id })
        _ => None
      }
      if sts.is_empty() || !(full_p is Some(_)) {
        (core.say)(@sf.t("web-pages.profiles.manage.singleUnavailable"))
        return
      }
      let pv = full_p
      let share = field(pv, "share")
      let is_shared = share is Some(Object(_))
      let access_kind = text(field(pv, "access"), "kind")
      let sub = access_kind == "subscription" || flag(field(pv, "access"), "login")
      let claude = access_kind == "subscription" && text(pv, "runtime") == "claude"
      let auto_ok = flag(ov, "shareAllowAuto")
      let follow = if is_shared { flag(share, "allowAuto") } else { auto_ok }
      let allowed : Array[String]? = if is_shared && !follow {
        match field(share, "allow") {
          Some(Array(a)) =>
            Some(
              a.filter_map(fn(x) {
                match x {
                  String(s) => Some(s)
                  _ => None
                }
              }),
            )
          _ => None
        }
      } else {
        None
      }
      pick_stations(
        core,
        address,
        id,
        sts,
        share_station_id(address),
        allowed,
        initial=!is_shared,
        subscription=sub,
        claude~,
        follow~,
        auto_ok~,
        stop=true,
        still_here~,
      )
    }
    let pw = @sfbase.press_wait(
      fn() {
        match lease.follow() {
          Some(st) => st.error is Some(_) || (st.value is Some(_) && st.version >= 0)
          None => false
        }
      },
      open_now,
      let_go=fn() {
        lease.release()
        if @signals.untracked(fn() { loading_key.get() }) == row_key {
          loading_key.set("")
        }
      },
      holds=false,
    )
    if pw.waiting() {
      pending_edit.val = Some((pw, lease))
    }
  }
  // Workspace-wide: rows from `profiles`; single-station: workspace-filtered via `profileGroups` + `overview.profiles`.
  let all_rows_now : @signals.Computed[Array[Json]] = @signals.computed(fn(_) {
    if only == "" {
      items(profiles_topic().value, "items")
    } else {
      pm_station_rows(only, station_topic(), one_now.get(), stations_list())
    }
  }, same=jsons_same)
  let all_rows = fn() { all_rows_now.get() }
  let filtered_rows_now = @signals.computed(fn(_) {
    let stf = status_filter.get()
    let shf = share_filter.get()
    let gf = group_filter.get()
    let sf = if only == "" { station_filter.get() } else { "" }
    all_rows().filter(fn(r) {
      (sf == "" || text(Some(r), "station") == sf) &&
      (gf == "" || text(Some(r), "group") == gf) &&
      pm_matches_status(r, stf) &&
      pm_matches_share(r, shf)
    })
  }, same=jsons_same)
  let group_choices = fn() -> Array[(String, String)] {
    let out : Array[(String, String)] = []
    let seen : Map[String, Bool] = Map([])
    for r in all_rows() {
      let g = text(Some(r), "group")
      let gt = text(Some(r), "groupTitle")
      if g != "" && !seen.contains(g) {
        seen[g] = true
        out.push((g, if gt != "" { gt } else { g }))
      }
    }
    out
  }
  v.reacts(all_rows, fn(_) {
    let cur = @signals.untracked(fn() { group_filter.get() })
    if cur != "" && !@signals.untracked(group_choices).iter().any(fn(x) { x.0 == cur }) {
      group_filter.set("")
    }
  }, at_start=false)
  let filtered_rows = fn() { filtered_rows_now.get() }
  let grouped_rows_now = @signals.computed(fn(_) {
    let base = filtered_rows()
    let st = sort_state.get()
    let sts = match st {
      Some(ts) if ts.col == "station" => stations_list()
      _ => []
    }
    pm_grouped_rows(base, st, sts)
  })
  let sorted_rows_now = @signals.computed(fn(_) {
    let out : Array[Json] = []
    for grp in grouped_rows_now.get() {
      out.append(grp.2)
    }
    out
  }, same=jsons_same)
  let sorted_rows = fn() { sorted_rows_now.get() }
  let on_sort = fn(col : String) { @sf.toggle_table_sort(sort_state, col, allow_clear=true) }
  let visible_selectable = fn() {
    let sts = stations_list()
    sorted_rows().filter(fn(r) { can_select_row(r, stations=sts) })
  }
  let visible_selectable_keys = @signals.computed(fn(_) {
    visible_selectable().map(fn(r) { text(Some(r), "key") })
  }, same=fn(a, b) { a == b })
  // Live pruning: drop any selected key that disappears or loses eligibility on filter change or live push.
  // Never touch `batch.chosen` when empty or unchanged so live updates do not dirty every row's checkbox binding.
  v.reacts(fn() { visible_selectable_keys.get() }, fn(keys) {
    if @signals.untracked(fn() { batch.chosen.is_empty() }) {
      return
    }
    let valid : Map[String, Bool] = Map([])
    for k in keys {
      valid[k] = true
    }
    let stale : Array[String] = []
    @signals.untracked(fn() {
      for kv in batch.chosen.iter() {
        let (k, on) = kv
        if on && !valid.contains(k) {
          stale.push(k)
        }
      }
    })
    for k in stale {
      batch.chosen.remove(k)
    }
  })
  let all_selected = fn() {
    let c = visible_selectable()
    c.length() > 0 && c.iter().all(fn(r) { batch.picked(text(Some(r), "key")) })
  }
  let has_selected = fn() { batch.rows(sorted_rows(), stations=stations_list()).length() > 0 }
  let on_toggle_all = fn(to : Bool) {
    for r in @signals.untracked(visible_selectable) {
      batch.chosen.set(text(Some(r), "key"), to)
    }
  }
  let master_disabled = fn() { batch.busy.get() || visible_selectable().is_empty() }
  let whitelist_empty = fn() {
    match stations_topic().value {
      Some(Array(sts)) => sts.length() > 0 && !sts.iter().any(share_on_whitelist)
      _ => false
    }
  }
  let show_whitelist_hint = fn() {
    whitelist_empty() &&
    (share_filter.get() == 2 || all_rows().iter().any(fn(r) { flag(Some(r), "shared") && flag(Some(r), "shareAuto") }))
  }
  // Grouped table items: `"g/<group>"` subheaders interleaved with `"r/<key>"` account rows for both wide and narrow views.
  let table_items : @signals.KeyedList[String, (String, PmTableItem)] = v.keyed_by(
    fn() {
      let groups = grouped_rows_now.get()
      let raw : Array[(String, PmTableItem)] = []
      let seen : Map[String, Bool] = Map([])
      for grp in groups {
        let (g, gt, rows) = grp
        let grp_rows : Array[(String, Json)] = []
        for e in rows {
          let rk = "r/" + text(Some(e), "key")
          if !seen.contains(rk) {
            seen[rk] = true
            grp_rows.push((rk, e))
          }
        }
        if !grp_rows.is_empty() {
          if gt != "" {
            raw.push(("g/" + g, PmGroup(gt, CardBetween)))
          }
          for item in grp_rows {
            raw.push((item.0, PmRow(item.1, CardBetween)))
          }
        }
      }
      let n = raw.length()
      let out : Array[(String, PmTableItem)] = []
      for i, item in raw {
        let piece : @sf.CardPiece = if i + 1 == n { CardFoot } else { CardBetween }
        let tagged = match item.1 {
          PmGroup(t, _) => PmGroup(t, piece)
          PmRow(e, _) => PmRow(e, piece)
        }
        out.push((item.0, tagged))
      }
      out
    },
    fn(e) { e.0 },
    same=pm_item_same,
  )
  let page_state = fn() -> String {
    if manages_state() is None {
      return "waiting"
    }
    if only == "" {
      let pv = profiles_topic().value
      match pv {
        None => return "waiting"
        Some(_) => {
          let wait = field(pv, "wait")
          if all_rows().is_empty() && (flag(wait, "reading") || items(wait, "failing").length() > 0) {
            return "waiting"
          }
        }
      }
    } else {
      match stations_topic().value {
        None => return "waiting"
        Some(Array(_)) =>
          match one_now.get() {
            None => return "station-gone"
            Some(_) as one => {
              let st_val = station_topic()
              if !flag(one, "online") && field(st_val, "overview") is None {
                return "station-offline"
              }
              if st_val is None || (flag(one, "online") && field(st_val, "overview") is None) {
                return "waiting"
              }
            }
          }
        _ => return "waiting"
      }
    }
    if all_rows().is_empty() { "empty" } else { "ready" }
  }
  let build_waiting = fn(b : @view.View) {
    @sf.waiting_node(
      b,
      fn(s) {
        @sf.group_node(s, fn(g) {
          g.each(fn() { profiles_sample }, fn(e) { text(Some(e), "key") }, fn(r, e) {
            @sf.link_row_node(r, fn() { text(field(Some(e.get()), "profile"), "name") }, fn() {  }, goes=false)
          })
        })
      },
      error=fn() {
        let e = if only == "" {
          profiles_topic().error
        } else {
          match stations_topic().error {
            Some(_) as se => se
            None =>
              match station_read_opt() {
                Some(r) => r.error
                None => None
              }
          }
        }
        match e {
          Some(x) => error_text(x)
          None => ""
        }
      },
      note=fn() {
        if only == "" {
          let failing = @settings.failing_of(field(profiles_topic().value, "wait"))
          { reading: failing.length() == 0, text: "", failing }
        } else {
          { reading: true, text: "", failing: [] }
        }
      },
    )
  }
  let build_controls = fn(b : @view.View) {
    b.box(fn(bar) {
      @sf.style_node(bar, fn() { pm_controls_bar })
      bar.wraps(Is(Some(8.0))) |> ignore
      if only == "" {
        bar.box(fn(st_wrap) {
          st_wrap.shrink(Is(0.0)) |> ignore
          let st_lbl = fn() {
            let sf = station_filter.get()
            if sf == "" {
              @sf.t("web-pages.profiles.manage.allStations")
            } else {
              pm_station_name(stations_list(), sf)
            }
          }
          @sf.action_box_node(
            st_wrap,
            st_lbl,
            fn(at) {
              let cur = @signals.untracked(fn() { station_filter.get() })
              let sts = @signals.untracked(stations_list)
              let items : Array[@sf.MenuItem?] = [
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.manage.allStations"),
                    fn() { station_filter.set("") },
                    checked=cur == "",
                  ),
                ),
              ]
              for s in sts {
                let addr = text(Some(s), "station")
                let sname = text(Some(s), "name")
                if addr != "" && sname != "" {
                  items.push(
                    Some(
                      @sf.menu_item_of(sname, fn() { station_filter.set(addr) }, checked=cur == addr),
                    ),
                  )
                }
              }
              @sf.menu(items, from=@sf.Beside::Node(at))
            },
            fn(btn) {
              @sf.style_node(btn, fn() { pm_station_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
              @sf.hover_ground_node(btn)
              @sf.words_node(btn, st_lbl, fn() { pm_station_words }) |> ignore
              @sf.icon_node(btn, "chevron-down", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
            },
          )
          |> ignore
        })
        |> ignore
      }
      bar.box(fn(grp_wrap) {
        grp_wrap.shrink(Is(0.0)) |> ignore
        let grp_lbl = fn() {
          let gf = group_filter.get()
          if gf == "" {
            @sf.t("web-pages.profiles.manage.allTypes")
          } else {
            match group_choices().iter().find_first(fn(x) { x.0 == gf }) {
              Some((_, t)) => t
              None => gf
            }
          }
        }
        @sf.action_box_node(
          grp_wrap,
          grp_lbl,
          fn(at) {
            let cur = @signals.untracked(fn() { group_filter.get() })
            let choices = @signals.untracked(group_choices)
            let items : Array[@sf.MenuItem?] = [
              Some(
                @sf.menu_item_of(
                  @sf.t("web-pages.profiles.manage.allTypes"),
                  fn() { group_filter.set("") },
                  checked=cur == "",
                ),
              ),
            ]
            for g in choices {
              let (gk, gt) = g
              items.push(Some(@sf.menu_item_of(gt, fn() { group_filter.set(gk) }, checked=cur == gk)))
            }
            @sf.menu(items, from=@sf.Beside::Node(at))
          },
          fn(btn) {
            @sf.style_node(btn, fn() { pm_station_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
            @sf.hover_ground_node(btn)
            @sf.words_node(btn, grp_lbl, fn() { pm_station_words }) |> ignore
            @sf.icon_node(btn, "chevron-down", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
      bar.box(fn(flt_wrap) {
        flt_wrap.shrink(Is(0.0)) |> ignore
        let flt_lbl = fn() {
          match status_filter.get() {
            1 => @sf.t("web-pages.profiles.manage.statusOk")
            2 => @sf.t("web-pages.profiles.manage.statusIssue")
            _ => @sf.t("web-pages.profiles.manage.allStatus")
          }
        }
        @sf.action_box_node(
          flt_wrap,
          flt_lbl,
          fn(at) {
            let cur = @signals.untracked(fn() { status_filter.get() })
            @sf.menu(
              [
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.manage.allStatus"),
                    fn() { status_filter.set(0) },
                    checked=cur == 0,
                  ),
                ),
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.manage.statusOk"),
                    fn() { status_filter.set(1) },
                    checked=cur == 1,
                  ),
                ),
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.manage.statusIssue"),
                    fn() { status_filter.set(2) },
                    checked=cur == 2,
                  ),
                ),
              ],
              from=@sf.Beside::Node(at),
            )
          },
          fn(btn) {
            @sf.style_node(btn, fn() { pm_station_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
            @sf.hover_ground_node(btn)
            @sf.words_node(btn, flt_lbl, fn() { pm_station_words }) |> ignore
            @sf.icon_node(btn, "chevron-down", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
      bar.box(fn(sh_wrap) {
        sh_wrap.shrink(Is(0.0)) |> ignore
        let sh_lbl = fn() {
          match share_filter.get() {
            1 => @sf.t("web-pages.profiles.sharing.filter.unshared")
            2 => @sf.t("web-pages.profiles.sharing.filter.whitelist")
            3 => @sf.t("web-pages.profiles.sharing.filter.custom")
            _ => @sf.t("web-pages.profiles.manage.allSharing")
          }
        }
        @sf.action_box_node(
          sh_wrap,
          sh_lbl,
          fn(at) {
            let cur = @signals.untracked(fn() { share_filter.get() })
            @sf.menu(
              [
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.manage.allSharing"),
                    fn() { share_filter.set(0) },
                    checked=cur == 0,
                  ),
                ),
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.sharing.filter.unshared"),
                    fn() { share_filter.set(1) },
                    checked=cur == 1,
                  ),
                ),
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.sharing.filter.whitelist"),
                    fn() { share_filter.set(2) },
                    checked=cur == 2,
                  ),
                ),
                Some(
                  @sf.menu_item_of(
                    @sf.t("web-pages.profiles.sharing.filter.custom"),
                    fn() { share_filter.set(3) },
                    checked=cur == 3,
                  ),
                ),
              ],
              from=@sf.Beside::Node(at),
            )
          },
          fn(btn) {
            @sf.style_node(btn, fn() { pm_station_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
            @sf.hover_ground_node(btn)
            @sf.words_node(btn, sh_lbl, fn() { pm_station_words }) |> ignore
            @sf.icon_node(btn, "chevron-down", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          },
        )
        |> ignore
      })
      |> ignore
    })
    |> ignore
  }
  let build_whitelist_hint = fn(b : @view.View) {
    @sf.group_node(b, fn(g) {
      @sf.link_row_node(
        g,
        fn() { @sf.t("web-pages.profiles.sharing.whitelistEmpty") },
        fn() { ws_auto_chats_panel(core, @signals.untracked(here), Unanchored) },
        note=fn() { @sf.t("web-pages.profiles.sharing.whitelistEmptyNote") },
        lead=LeadLine(fn(l) { @sf.icon_node(l, "info", 18.0, By(fn() { @sf.theme().p.muted })) |> ignore }),
      )
    })
  }
  // Narrow layout reserves bottom room for the floating batch dock; wide uses a flow-child dock below the table.
  let framed = fn() {
    let f = frame()
    if !@sf.width_is_wide(width) && has_selected() {
      { ..f, foot: f.foot + profiles_batch_room(narrow=true) }
    } else {
      f
    }
  }
  @sf.page_fixed_node(
    v,
    fn() { @sf.t("web-pages.profiles.sharing.title") },
    fn(s) {
      match said {
        Some(f) => s.said(f)
        None => ()
      }
      s.tips(tips)
      // Wide layout: fixed title + fixed filter bar + scrollable `data_table_node` + flow-child bottom batch bar
      s.wide_body(fn(body) {
        body.pick(page_state, fn(pane, st) {
          pane.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
          match st {
            "waiting" => build_waiting(pane)
            "station-gone" =>
              @sf.group_node(pane, fn(g) {
                @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.manage.stationGone") }, fn() {  }, goes=false)
              })
            "station-offline" =>
              @sf.group_node(pane, fn(g) {
                @sf.link_row_node(g, fn() { @sf.t("android-settings.profiles.stationOffline") }, fn() {  }, goes=false)
              })
            "empty" =>
              @sf.group_node(pane, fn(g) {
                @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.sharing.empty") }, fn() {  }, goes=false)
              })
            _ => {
              pane.box(fn(ctrl) {
                ctrl.shrink(Is(0.0)) |> ignore
                build_controls(ctrl)
              })
              |> ignore
              pane.show(show_whitelist_hint, fn(wb) {
                wb.shrink(Is(0.0)).padding(Is((0.0, 0.0, 0.0, 12.0))) |> ignore
                build_whitelist_hint(wb)
              })
              pane.pick(fn() { table_items.keys().is_empty() }, fn(area, is_empty) {
                if is_empty {
                  area.shrink(Is(0.0)) |> ignore
                  @sf.group_node(area, fn(g) {
                    @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.sharing.filterEmpty") }, fn() {  }, goes=false)
                  })
                } else {
                  area.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
                  // Single table-level `by_room` drives responsive column widths and floating dock `end_room` via `By` bindings.
                  area.by_room(fn(tw, room) {
                    tw.grow(Is(1.0)).shrink(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
                    let st_w = fn() -> Double? { Some(if room.width() >= 760.0 { 112.0 } else { 76.0 }) }
                    let status_w = fn() -> Double? { Some(if room.width() >= 760.0 { 244.0 } else { 200.0 }) }
                    let share_w = fn() -> Double? { Some(120.0) }
                    let dock_end_room = fn() -> Double {
                      if !has_selected() {
                        return 0.0
                      }
                      let need = profiles_batch_room(narrow=false)
                      let mut est_h = 56.0
                      for k in table_items.keys() {
                        est_h += if k.has_prefix("g/") { 36.0 } else { 44.0 }
                      }
                      match room.height() {
                        Some(avail) if est_h > avail - need => need
                        _ => 0.0
                      }
                    }
                    @sf.data_table_node(tw, surface=Card, fn(dt) {
                      dt.head(fn(h) {
                        h.lead(fn(l) {
                          @sf.check_node_of(
                            l,
                            all_selected,
                            on_toggle_all,
                            fn() {
                              if all_selected() {
                                @sf.t("web-pages.profiles.batch.none")
                              } else {
                                @sf.t("web-pages.profiles.batch.all")
                              }
                            },
                            disabled=master_disabled,
                          )
                          |> ignore
                        })
                        h.col(
                          fn() { @sf.t("web-pages.profiles.account") },
                          sort_key="account",
                          sort=fn() { sort_state.get() },
                          on_sort~,
                        )
                        if only == "" {
                          h.col(
                            fn() { @sf.t("web-pages.connect.station") },
                            width=st_w,
                            sort_key="station",
                            sort=fn() { sort_state.get() },
                            on_sort~,
                          )
                        }
                        h.col(
                          fn() { @sf.t("web-pages.profiles.manage.statusCol") },
                          width=status_w,
                          sort_key="status",
                          sort=fn() { sort_state.get() },
                          on_sort~,
                        )
                        h.col(
                          fn() { @sf.t("web-pages.profiles.sharing.column") },
                          width=share_w,
                          align=End,
                          sort_key="sharing",
                          sort=fn() { sort_state.get() },
                          on_sort~,
                        )
                      })
                      dt.group_header(
                        fn(k) { k.has_prefix("g/") },
                        fn(g, k_fn) {
                          let title = fn() {
                            match table_items.get(k_fn()) {
                              Some((_, PmGroup(t, _))) => t
                              _ => ""
                            }
                          }
                          @sf.words_node(g, title, fn() { @sf.theme().chat_list.heading_words }) |> ignore
                        },
                      )
                      dt.virtual_rows(
                        fn() { table_items.keys() },
                        fn(tr, k) {
                          pm_wide_table_row(
                            tr,
                            core,
                            only == "",
                            table_items,
                            fn() { k },
                            batch,
                            stations_list,
                            open_single_policy,
                            loading_key,
                            tips,
                            st_w,
                            status_w,
                            share_w,
                          )
                        },
                        est=48.0,
                        reused=fn(_) { Some(0) },
                        make_reused=fn(tr, _, key) {
                          pm_wide_table_row(
                            tr,
                            core,
                            only == "",
                            table_items,
                            key,
                            batch,
                            stations_list,
                            open_single_policy,
                            loading_key,
                            tips,
                            st_w,
                            status_w,
                            share_w,
                          )
                        },
                        end_room=dock_end_room,
                      )
                    })
                    |> ignore
                  })
                  .grow(Is(1.0))
                  .shrink(Is(1.0))
                  .min_height(Is(Some(0.0)))
                  |> ignore
                }
              })
            }
          }
        })
      })
  // Narrow layout: delegates directly to `narrow_page_node` (full-page scroll + floating dock)
  s.narrow_blocks(
    fn() {
      match page_state() {
        "ready" => {
          let out : Array[String] = ["controls"]
          if show_whitelist_hint() {
            out.push("whitelist-empty")
          }
          let vis = table_items.keys()
          if vis.is_empty() {
            out.push("filter-empty")
          } else {
            out.push("table-head")
            out.append(vis)
          }
          out
        }
        st => [st]
      }
    },
    fn(b, key) {
      match key {
        "waiting" => build_waiting(b)
        "station-gone" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.manage.stationGone") }, fn() {  }, goes=false)
          })
        "station-offline" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("android-settings.profiles.stationOffline") }, fn() {  }, goes=false)
          })
        "empty" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.sharing.empty") }, fn() {  }, goes=false)
          })
        "controls" => build_controls(b)
        "whitelist-empty" => build_whitelist_hint(b)
        "filter-empty" =>
          @sf.group_node(b, fn(g) {
            @sf.link_row_node(g, fn() { @sf.t("web-pages.profiles.sharing.filterEmpty") }, fn() {  }, goes=false)
          })
        "table-head" =>
          pm_narrow_head_block(b, all_selected, on_toggle_all, master_disabled, sort_state, on_sort)
        k if k.has_prefix("g/") =>
          pm_narrow_group_block(b, table_items, fn() { k })
        k if k.has_prefix("r/") =>
          pm_narrow_row_block(b, core, table_items, fn() { k }, batch, stations_list, open_single_policy, loading_key, tips)
        _ => ()
      }
    },
    reused=fn(k) {
      if k.has_prefix("g/") {
        Some(1)
      } else if k.has_prefix("r/") {
        Some(0)
      } else {
        None
      }
    },
    make_reused=fn(b, kind, key) {
      if kind == 1 {
        pm_narrow_group_block(b, table_items, key)
      } else {
        pm_narrow_row_block(b, core, table_items, key, batch, stations_list, open_single_policy, loading_key, tips)
      }
    },
  )
    },
    on_back~,
    frame=framed,
    width?,
    max_width=920.0,
  )
  profiles_batch_foot_node(
    v,
    core,
    batch,
    sorted_rows,
    stations_list,
    on_edit_one=open_single_policy,
    foot=fn() { frame().foot },
    width?,
    still_here~,
  )
}

///|
/// Helper to render the right-aligned sharing policy action cell (shared between wide and narrow rows).
fn pm_build_share_action(
  parent : @view.View,
  core : Core,
  row_val : () -> Json?,
  row_key : () -> String,
  name : () -> String,
  shareable : () -> Bool,
  batch : ProfilesBatch,
  on_edit_one : (Json) -> Unit,
  loading_key : @signals.Signal[String],
) -> Unit {
  parent.pick(
    fn() {
      if shareable() {
        1
      } else if text(row_val(), "batchShareWhy") == "several" {
        2
      } else {
        0
      }
    },
    fn(act, mode) {
      if mode == 1 {
        let lbl = fn() { pm_policy_label(row_val()) }
        let a11y_lbl = fn() { name() + " · " + lbl() }
        let row_loading = fn() { loading_key.get() == row_key() }
        @sf.action_box_node(
          act,
          a11y_lbl,
          fn(_) {
            match @signals.untracked(row_val) {
              Some(r) => on_edit_one(r)
              None => ()
            }
          },
          fn(btn) {
            @sf.style_node(btn, fn() { pm_policy_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
            @sf.hover_ground_node(btn)
            @sf.words_node(btn, lbl, fn() { pm_policy_words }) |> ignore
            @sf.icon_node(btn, "chevron-right", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          },
          disabled=fn() { batch.busy.get() || row_loading() },
        )
        |> ignore
      } else if mode == 2 {
        let lbl = fn() { @sf.t("web-pages.profiles.sharing.severalAction") }
        let a11y_lbl = fn() { name() + " · " + lbl() }
        @sf.action_box_node(
          act,
          a11y_lbl,
          fn(_) {
            let k = @signals.untracked(row_key)
            if k != "" {
              (core.push)(ProfileAccount(k))
            }
          },
          fn(btn) {
            @sf.style_node(btn, fn() { pm_policy_btn.then(@ui.style(min_h=Fixed(@sf.button_height()))) }, in_row=true)
            @sf.hover_ground_node(btn)
            @sf.words_node(btn, lbl, fn() { pm_policy_words }) |> ignore
            @sf.icon_node(btn, "chevron-right", 14.0, By(fn() { @sf.theme().p.subtle })) |> ignore
          },
        )
        |> ignore
      }
    },
  )
}

///|
fn pm_first_line_top(v : @view.View, pad : Double) -> Double {
  v.words_redone() |> ignore
  let w = @ui.style_words(@sf.theme().rows.title)
  let lh = (if w.line > 0.0 { w.line } else { -w.line * w.size }) * @ui.font_scale()
  let off = (lh - pl_logo) / 2.0
  if off > 0.0 { pad + off } else { pad }
}

///|
fn pm_first_line_btn_top(v : @view.View, pad : Double) -> Double {
  v.words_redone() |> ignore
  let w = @ui.style_words(@sf.theme().rows.title)
  let lh = (if w.line > 0.0 { w.line } else { -w.line * w.size }) * @ui.font_scale()
  let off = pad + (lh - @sf.button_height()) / 2.0
  if off > 0.0 { off } else { 0.0 }
}

///|
/// Wide virtualized `data_table_node` row (reused across keys via reactive `key()`).
fn pm_wide_table_row(
  tr : @sf.DataTableRow,
  core : Core,
  show_station_col : Bool,
  table_items : @signals.KeyedList[String, (String, PmTableItem)],
  key : () -> String,
  batch : ProfilesBatch,
  stations : () -> Array[Json],
  on_edit_one : (Json) -> Unit,
  loading_key : @signals.Signal[String],
  tips : @sf.TipLayer,
  st_w : () -> Double?,
  status_w : () -> Double?,
  share_w : () -> Double?,
) -> Unit {
  let last : Ref[Json?] = Ref(None)
  let ev = @signals.computed(fn(_) {
    match table_items.get(key()) {
      Some((_, PmRow(e, _))) => last.val = Some(e)
      _ => ()
    }
    last.val
  }, same=json_opt_same)
  let row_val = fn() { ev.get() }
  let row_key = fn() { text(row_val(), "key") }
  let selectable = fn() {
    match row_val() {
      Some(r) => can_select_row(r, stations=stations())
      None => false
    }
  }
  let shareable = fn() { flag(row_val(), "canBatchShare") }
  let p = fn() { field(row_val(), "profile") }
  let quota = fn() { field(p(), "quota") }
  let show_chips_c = @signals.computed(fn(_) { pm_shows_quota_chips(row_val()) }, same=fn(a, b) { a == b })
  let show_chips = fn() { show_chips_c.get() }
  let name = fn() { profiles_batch_name(row_val()) }
  let plan = fn() { text(p(), "plan") }
  let station_text = fn() { pm_station_name(stations(), text(row_val(), "station")) }
  let why_text = fn() { if shareable() { "" } else { profiles_batch_why(row_val()) } }
  let has_why = fn() { why_text() != "" }
  let multi_line_c = @signals.computed(fn(_) { has_why() || (show_chips() && @sfbase.quota_is_pooled(quota())) }, same=fn(a, b) {
    a == b
  })
  let multi_line = fn() { multi_line_c.get() }
  let status_now = @signals.computed(fn(_) { pm_status_of(row_val()) }, same=fn(a, b) { a.0 == b.0 && a.1 == b.1 })
  let toggle_pick = fn() {
    let k = @signals.untracked(row_key)
    if @signals.untracked(selectable) && !@signals.untracked(fn() { batch.busy.get() }) {
      batch.chosen.set(k, !@signals.untracked(fn() { batch.picked(k) }))
    }
  }
  tr.view().lines_up(By(fn() { Some(if multi_line() { Start } else { Middle }) })) |> ignore
  // Lead: row checkbox (aligned to first line when multi-line)
  tr.lead(fn(l) {
    let cb = @sf.check_node_of(
      l,
      fn() { selectable() && batch.picked(row_key()) },
      fn(on) {
        let k = @signals.untracked(row_key)
        if @signals.untracked(selectable) && !batch.busy.get() {
          batch.chosen.set(k, on)
        }
      },
      name,
      disabled=fn() { !selectable() || batch.busy.get() },
    )
    cb.margin(By(fn() { if multi_line() { (0.0, pm_first_line_top(cb, 10.0), 0.0, 0.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
    |> ignore
  })
  // Col 1: Account (icon + name + plan / unshareable note)
  tr.cell(fn(mid) {
    mid
    .lines_up(By(fn() { Some(if multi_line() { Start } else { Middle }) }))
    .padding(By(fn() { if multi_line() { (0.0, 10.0, 0.0, 10.0) } else { (0.0, 6.0, 0.0, 6.0) } }))
    .gap(Is(8.0))
    .alpha(By(fn() { if selectable() { 1.0 } else { pl_away } }))
    .on_press(toggle_pick)
    |> ignore
    mid.box(fn(mk) {
      mk
      .margin(By(fn() { if multi_line() { (0.0, pm_first_line_top(mk, 0.0), 0.0, 0.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
      .shrink(Is(0.0))
      |> ignore
      @sfbase.provider_mark_node(
        mk,
        fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) },
        pl_logo,
      )
    })
    |> ignore
    mid.box(fn(txt) {
      txt.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
      let acct_lbl = fn() {
        let n = name()
        let pl = plan()
        if pl == "" { n } else { n + " · " + pl }
      }
      let acct_cell = @sf.words_node(txt, acct_lbl, fn() { pm_account_cell_words })
      acct_cell.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.tip_node(tips, acct_cell, acct_lbl, repeats=true) |> ignore
      txt.show(has_why, fn(nt) {
        @sf.words_node(nt, why_text, fn() { @sf.theme().rows.note }) |> ignore
      })
    })
    |> ignore
  })
  // Col 2: Station (workspace mode only)
  if show_station_col {
    tr.cell(width=st_w, fn(c) {
      c
      .margin(By(fn() { if multi_line() { (0.0, 10.0, 0.0, 0.0) } else { (0.0, 0.0, 0.0, 0.0) } }))
      .alpha(By(fn() { if selectable() { 1.0 } else { pl_away } }))
      .on_press(toggle_pick)
      |> ignore
      let st_cell = @sf.words_node(c, station_text, fn() { pm_station_cell_words })
      st_cell.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      @sf.tip_node(tips, st_cell, station_text, repeats=true) |> ignore
    })
  }
  // Col 3: Status / live quota capsules (matching sidebar & profile list)
  tr.cell(width=status_w, fn(c) {
    c
    .padding(By(fn() {
      if multi_line() {
        (0.0, if show_chips() { pm_first_line_top(c, 10.0) } else { 10.0 }, 0.0, 10.0)
      } else {
        (0.0, 6.0, 0.0, 6.0)
      }
    }))
    .alpha(By(fn() { if selectable() { 1.0 } else { pl_away } }))
    .on_press(toggle_pick)
    |> ignore
    c.pick(at_once=true, show_chips, fn(slot, chips_on) {
      slot.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
      if chips_on {
        @sfbase.quota_table_chips_node(slot, quota, tips~)
      } else {
        slot.row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        let status_cell = @sf.words_node(
          slot,
          fn() { status_now.get().0 },
          fn() {
            match status_now.get().1 {
              "red" => pm_status_bad_words
              "amber" => pm_status_warn_words
              _ => pm_station_cell_words
            }
          },
        )
        status_cell.shrink(Is(1.0)).min_width(Is(Some(0.0))) |> ignore
        @sf.tip_node(tips, status_cell, fn() { status_now.get().0 }, repeats=true) |> ignore
      }
    })
  })
  // Col 4: Sharing policy button
  tr.cell(width=share_w, align=End, fn(c) {
    c.padding(By(fn() { if multi_line() { (0.0, pm_first_line_btn_top(c, 10.0), 0.0, 2.0) } else { (0.0, 2.0, 0.0, 2.0) } }))
    |> ignore
    pm_build_share_action(c, core, row_val, row_key, name, shareable, batch, on_edit_one, loading_key)
  })
}

///|
/// Narrow table header row (`CardTop`): master select-all checkbox + sortable `账号` and `共享` column headers,
/// followed by a single 1px hairline divider matching the wide table header.
fn pm_narrow_head_block(
  b : @view.View,
  all_selected : () -> Bool,
  on_toggle_all : (Bool) -> Unit,
  disabled : () -> Bool,
  sort_state : @signals.Signal[@sf.TableSort?],
  on_sort : (String) -> Unit,
) -> Unit {
  b.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(b, fn() { @sf.CardPiece::CardTop }, wide_group=true, fn(card) {
    card.box(fn(row) {
      @sf.style_node(row, fn() { pm_head_row_style.then(@ui.style(min_h=Fixed(@sf.theme().items.least))) })
      row.row(Is(true)).lines_up(Is(Some(Middle))).gap(Is(8.0)) |> ignore
      row.box(fn(l) {
        l.shrink(Is(0.0)).row(Is(true)).lines_up(Is(Some(Middle))) |> ignore
        @sf.check_node_of(
          l,
          all_selected,
          on_toggle_all,
          fn() {
            if all_selected() {
              @sf.t("web-pages.profiles.batch.none")
            } else {
              @sf.t("web-pages.profiles.batch.all")
            }
          },
          disabled~,
        )
        |> ignore
      })
      |> ignore
      let sort_col_btn = fn(parent : @view.View, col_key : String, lbl : () -> String, grow_col : Bool) {
        parent.box(fn(wrap) {
          wrap.row(Is(true)).lines_up(Is(Some(Middle))).lies_along(Is(if grow_col { Start } else { End })) |> ignore
          if grow_col {
            wrap.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
          } else {
            wrap.shrink(Is(0.0)) |> ignore
          }
          @sf.sort_head_button_node(
            wrap,
            lbl,
            col_key,
            fn() { sort_state.get() },
            on_sort,
            align=if grow_col { Start } else { End },
          )
          |> ignore
        })
        |> ignore
      }
      sort_col_btn(row, "account", fn() { @sf.t("web-pages.profiles.account") }, true)
      sort_col_btn(row, "sharing", fn() { @sf.t("web-pages.profiles.sharing.column") }, false)
    })
    |> ignore
    card.box(fn(div) {
      div.padding(Is((0.0, 0.0, 0.0, 2.0))) |> ignore
      div.box(fn(ln) { @sf.style_node(ln, fn() { @sf.rule_line }) }) |> ignore
    })
    |> ignore
  })
}

///|
/// Narrow group subheader block inside the table card (reused across `"g/..."` keys).
fn pm_narrow_group_block(
  b : @view.View,
  table_items : @signals.KeyedList[String, (String, PmTableItem)],
  key : () -> String,
) -> Unit {
  let title = fn() {
    match table_items.get(key()) {
      Some((_, PmGroup(t, _))) => t
      _ => ""
    }
  }
  b.grow(Is(1.0)) |> ignore
  @sf.card_piece_node(b, fn() { @sf.CardPiece::CardBetween }, wide_group=true, fn(card) {
    card.box(fn(row) {
      row
      .width_share(Is(1.0))
      .padding(Is((18.0, 12.0, 12.0, 2.0)))
      |> ignore
      @sf.words_node(row, title, fn() { @sf.theme().chat_list.heading_words }) |> ignore
    })
    |> ignore
  })
}

///|
/// Narrow virtualized table row block: compact row `[checkbox] [icon + name / station + quota chips or status] [共享 >]`.
fn pm_narrow_row_block(
  b : @view.View,
  core : Core,
  table_items : @signals.KeyedList[String, (String, PmTableItem)],
  key : () -> String,
  batch : ProfilesBatch,
  stations : () -> Array[Json],
  on_edit_one : (Json) -> Unit,
  loading_key : @signals.Signal[String],
  tips : @sf.TipLayer,
) -> Unit {
  let last : Ref[(Json, @sf.CardPiece)?] = Ref(None)
  let now = @signals.computed(fn(_) {
    match table_items.get(key()) {
      Some((_, PmRow(e, piece))) => last.val = Some((e, piece))
      _ => ()
    }
    last.val
  }, same=fn(a, b) {
    match (a, b) {
      (Some((x, px)), Some((y, py))) => px == py && json_same(x, y)
      (None, None) => true
      _ => false
    }
  })
  let ev = @signals.computed(fn(_) { now.get().map(fn(n) { n.0 }) }, same=json_opt_same)
  let row_val = fn() { ev.get() }
  let row_key = fn() { text(row_val(), "key") }
  let selectable = fn() {
    match row_val() {
      Some(r) => can_select_row(r, stations=stations())
      None => false
    }
  }
  let shareable = fn() { flag(row_val(), "canBatchShare") }
  let p = fn() { field(row_val(), "profile") }
  let quota = fn() { field(p(), "quota") }
  let show_chips_c = @signals.computed(fn(_) { pm_shows_quota_chips(row_val()) }, same=fn(a, b) { a == b })
  let show_chips = fn() { show_chips_c.get() }
  let name = fn() { profiles_batch_name(row_val()) }
  let station_text = fn() { pm_station_name(stations(), text(row_val(), "station")) }
  let why_text = fn() { if shareable() { "" } else { profiles_batch_why(row_val()) } }
  let status_now = @signals.computed(fn(_) { pm_status_of(row_val()) }, same=fn(a, b) { a.0 == b.0 && a.1 == b.1 })
  b.grow(Is(1.0)) |> ignore
  let toggle_pick = fn() {
    let k = @signals.untracked(row_key)
    if @signals.untracked(selectable) && !@signals.untracked(fn() { batch.busy.get() }) {
      batch.chosen.set(k, !@signals.untracked(fn() { batch.picked(k) }))
    }
  }
  @sf.card_piece_node(b, fn() { now.get().map(fn(n) { n.1 }).unwrap_or(@sf.CardPiece::CardFoot) }, wide_group=true, fn(card) {
    card.box(fn(row) {
      @sf.style_node(row, fn() { pm_row_style.then(@ui.style(min_h=Fixed(@sf.theme().items.least))) })
      row.row(Is(true)).lines_up(Is(Some(Start))).gap(Is(8.0)) |> ignore
      // Col 1: row checkbox aligned with line 1 (Tab stop #1)
      let cb = @sf.check_node_of(
        row,
        fn() { selectable() && batch.picked(row_key()) },
        fn(on) {
          let k = @signals.untracked(row_key)
          if @signals.untracked(selectable) && !batch.busy.get() {
            batch.chosen.set(k, on)
          }
        },
        name,
        disabled=fn() { !selectable() || batch.busy.get() },
      )
      cb.margin(By(fn() { (0.0, pm_first_line_top(cb, 10.0), 0.0, 0.0) })).shrink(Is(0.0)) |> ignore
      // Right of checkbox: top line `[icon + name/station] [共享 >]` and full-width quota chips below so the action
      // button stays pinned to the top-right instead of dropping under multi-chip quota rows.
      row.box(fn(col) {
        col.grow(Is(1.0)).shrink(Is(1.0)).basis(Is(Some(0.0))).min_width(Is(Some(0.0))) |> ignore
        col.box(fn(body) {
          body
          .row(Is(true))
          .wraps(Is(Some(4.0)))
          .lies_along(Is(Between))
          .lines_up(Is(Some(Start)))
          .gap(Is(8.0))
          .width_share(Is(1.0))
          |> ignore
          body.box(fn(mid) {
            mid
            .row(Is(true))
            .lines_up(Is(Some(Start)))
            .padding(By(fn() { (0.0, 10.0, 0.0, if show_chips() { 4.0 } else { 10.0 }) }))
            .gap(Is(8.0))
            .grow(Is(1.0))
            .shrink(Is(1.0))
            .min_width(Is(Some(0.0)))
            .alpha(By(fn() { if selectable() { 1.0 } else { pl_away } }))
            .on_press(toggle_pick)
            |> ignore
            mid.box(fn(mk) {
              mk.margin(By(fn() { (0.0, pm_first_line_top(mk, 0.0), 0.0, 0.0) })).shrink(Is(0.0)) |> ignore
              @sfbase.provider_mark_node(
                mk,
                fn() { (text(p(), "runtime"), text(field(p(), "access"), "kind"), text(p(), "providerMark")) },
                pl_logo,
              )
            })
            |> ignore
            mid.box(fn(txt) {
              txt.grow(Is(1.0)).shrink(Is(1.0)).min_width(Is(Some(0.0))).gap(Is(2.0)) |> ignore
              @sf.words_node(txt, name, fn() { @sf.theme().rows.title }) |> ignore
              txt.show(
                fn() { why_text() != "" || station_text() != "" || (!show_chips() && status_now.get().0 != "") },
                fn(nt) {
                  nt.row(Is(true)).wraps(Is(Some(2.0))).lines_up(Is(Some(Middle))) |> ignore
                  let prefix = fn() {
                    let st_name = station_text()
                    let w = why_text()
                    if w != "" {
                      if st_name == "" { w } else { st_name + " · " + w }
                    } else if !show_chips() && st_name != "" && status_now.get().0 != "" {
                      st_name + " · "
                    } else {
                      st_name
                    }
                  }
                  nt.show(fn() { prefix() != "" }, fn(pbox) {
                    @sf.words_node(pbox, prefix, fn() { @sf.theme().rows.note }) |> ignore
                  })
                  nt.show(fn() { why_text() == "" && !show_chips() && status_now.get().0 != "" }, fn(sbox) {
                    @sf.words_node(
                      sbox,
                      fn() { status_now.get().0 },
                      fn() {
                        match status_now.get().1 {
                          "red" => pm_sub_bad_words
                          "amber" => pm_sub_warn_words
                          _ => @sf.theme().rows.note
                        }
                      },
                    )
                    |> ignore
                  })
                },
              )
            })
            |> ignore
          })
          |> ignore
          body.box(fn(right) {
            right
            .row(Is(true))
            .lies_along(Is(End))
            .lines_up(Is(Some(Middle)))
            .shrink(Is(0.0))
            .padding(Is((0.0, 3.0, 0.0, 2.0)))
            |> ignore
            pm_build_share_action(right, core, row_val, row_key, name, shareable, batch, on_edit_one, loading_key)
          })
          |> ignore
        })
        |> ignore
        col.show(at_once=true, show_chips, fn(qbox) {
          qbox
          .padding(Is((0.0, 2.0, 8.0, 10.0)))
          .width_share(Is(1.0))
          .alpha(By(fn() { if selectable() { 1.0 } else { pl_away } }))
          .on_press(toggle_pick)
          |> ignore
          @sfbase.quota_table_chips_node(qbox, quota, tips~)
        })
      })
      |> ignore
    })
    |> ignore
  })
}

///|
// kept across runs: a value (no field of it changes)
let pm_controls_bar : @ui.Style = @ui.css("row w=Full align=ACenter gap=S2 pl=S2 pb=S2")

///|
// kept across runs: a value (no field of it changes)
let pm_station_btn : @ui.Style = @ui.css("row align=ACenter gap=S1 px=S2_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let pm_sub_bad_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=Danger, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let pm_sub_warn_words : @ui.TextStyle = @ui.text_style(size=Meta, leading=L4, color=WarnInk, tabular=true)

///|
// kept across runs: a value (no field of it changes)
let pm_account_cell_words : @ui.TextStyle = @ui.text_style(
  size=Ui,
  leading=L5,
  weight=Medium,
  color=Fg,
  wrap=false,
  max_lines=1,
  w=Cut,
)

///|
// kept across runs: a value (no field of it changes)
let pm_station_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pm_station_cell_words : @ui.TextStyle = @ui.text_style(
  size=Ui,
  leading=L5,
  color=Muted,
  wrap=false,
  max_lines=1,
  w=Cut,
  tabular=true,
)

///|
// kept across runs: a value (no field of it changes)
let pm_status_bad_words : @ui.TextStyle = @ui.text_style(
  size=Ui,
  leading=L5,
  color=Danger,
  wrap=false,
  max_lines=1,
  w=Cut,
  tabular=true,
)

///|
// kept across runs: a value (no field of it changes)
let pm_status_warn_words : @ui.TextStyle = @ui.text_style(
  size=Ui,
  leading=L5,
  color=WarnInk,
  wrap=false,
  max_lines=1,
  w=Cut,
  tabular=true,
)

///|
// kept across runs: a value (no field of it changes)
let pm_policy_btn : @ui.Style = @ui.css("row align=ACenter gap=S1 px=S2_5 radius=Full")

///|
// kept across runs: a value (no field of it changes)
let pm_policy_words : @ui.TextStyle = @ui.text_style(size=Ui, leading=L5, color=Muted, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pm_head_row_style : @ui.Style = @ui.css("w=Full pl=S4_5 pr=S2")

///|
// kept across runs: a value (no field of it changes)
let pm_row_style : @ui.Style = @ui.css("w=Full pl=S4_5 pr=S2")
