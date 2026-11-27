// Profiles batch selection state, row eligibility helpers, and floating liquid-glass action bar
// (used by profiles_manage.mbt).

///|
/// Selection state for the batch management page: which selectable accounts are ticked (by row key) and whether a
/// batch operation is currently in flight.
pub struct ProfilesBatch {
  chosen : @sf.LiveMap[String, Bool]
  busy : @signals.Signal[Bool]
}

///|
pub fn ProfilesBatch::new() -> ProfilesBatch {
  { chosen: @sf.LiveMap::new(), busy: @signals.signal(false) }
}

///|
/// Clears all selected rows.
pub fn ProfilesBatch::clear(self : ProfilesBatch) -> Unit {
  self.chosen.clear()
}

///|
/// Whether the account of key `key` is picked.
pub fn ProfilesBatch::picked(self : ProfilesBatch, key : String) -> Bool {
  self.chosen.get(key).unwrap_or(false)
}

///|
/// Whether a row can be ticked on the batch management page: any online, single-host, non-borrowed own account
/// (including `unshareable`, `unsupported`, and `machine` logins, which can still be refreshed or deleted).
pub fn can_select_row(r : Json, stations? : Array[Json] = []) -> Bool {
  let rv = Some(r)
  let why = text(rv, "batchShareWhy")
  if flag(rv, "several") || why == "borrowed" || why == "offline" {
    return false
  }
  if !stations.is_empty() {
    let addr = text(rv, "station")
    if addr != "" {
      let mut online = false
      for i = 0; i < stations.length(); i = i + 1 {
        let st = Some(stations[i])
        if text(st, "station") == addr && flag(st, "online") {
          online = true
          break
        }
      }
      if !online {
        return false
      }
    }
  }
  true
}

///|
/// Whether a row's sharing policy can be edited in batch or inline (`canBatchShare`).
pub fn can_share_row(r : Json) -> Bool {
  flag(Some(r), "canBatchShare")
}

///|
/// Whether a row can be moved to another station (`profile.move`): selectable, station supports sharing/move
/// (not `unsupported`), and not a machine login (`machine != true`).
pub fn can_move_row(r : Json, stations? : Array[Json] = []) -> Bool {
  let rv = Some(r)
  can_select_row(r, stations~) && text(rv, "batchShareWhy") != "unsupported" && !flag(rv, "machine")
}

///|
/// Of the list's rows (`rows`, ProfileRows or rows made by `profiles_batch_row`), those picked that are selectable.
pub fn ProfilesBatch::rows(self : ProfilesBatch, rows : Array[Json], stations? : Array[Json] = []) -> Array[Json] {
  rows.filter(fn(r) { can_select_row(r, stations~) && self.picked(text(Some(r), "key")) })
}

///|
/// Projects a station's own profile `p` (on station `address`, overview `o`, station row `s`, workspace `stations`)
/// into the same row shape as `ProfileRow`. `group` and `group_title` come from the station's `profileGroups` when
/// available so workspace filtering and section headings stay accurate.
pub fn profiles_batch_row(
  address : String,
  p : Json,
  o : Json?,
  s : Json?,
  stations? : Array[Json] = [],
  group? : String = "",
  group_title? : String = "",
) -> Json {
  let pv = Some(p)
  let share = field(pv, "share")
  let why = if text(share, "role") == "user" {
    "borrowed"
  } else if !flag(s, "online") {
    "offline"
  } else if !flag(o, "sharing") {
    "unsupported"
  } else if !(share is Some(Object(_))) && field(pv, "shareable") is Some(False) {
    "unshareable"
  } else {
    ""
  }
  let shared = share is Some(Object(_))
  let share_auto = flag(share, "allowAuto")
  let g = if group != "" { group } else { text(pv, "group") }
  let gt = if group_title != "" { group_title } else { text(pv, "groupTitle") }
  let out : Map[String, Json] = {
    "key": str(text(pv, "id")),
    "group": str(g),
    "groupTitle": str(gt),
    "station": str(address),
    "profile": p,
    "title": str(text(pv, "name")),
    "shared": Json::boolean(shared),
    "shareAuto": Json::boolean(share_auto),
    "canBatchShare": Json::boolean(why == ""),
    "batchShareAllowAuto": Json::boolean(flag(o, "shareAllowAuto")),
  }
  if flag(pv, "machine") {
    out["machine"] = Json::boolean(true)
  }
  if why == "" && shared && !share_auto && !stations.is_empty() {
    match field(share, "allow") {
      Some(Array(allow_list)) => {
        let host_id = share_station_id(address)
        let allow_ids = allow_list.filter_map(fn(x) {
          match x {
            String(id) => Some(id)
            _ => None
          }
        })
        let n = stations
          .filter(fn(st) {
            let sid = text(Some(st), "id")
            sid == host_id || allow_ids.contains(sid)
          })
          .length()
        out["shareStationCount"] = Json::number(n.to_double())
      }
      _ => ()
    }
  }
  if why != "" {
    out["batchShareWhy"] = str(why)
  }
  Json::object(out)
}

///|
/// An account's display name: its profile's name, else the account's title.
fn profiles_batch_name(e : Json?) -> String {
  match text(field(e, "profile"), "name") {
    "" => text(e, "title")
    n => n
  }
}

///|
/// The floating batch bar body in `f`: a single reactive node structure that displays as one horizontal row on
/// wide/medium viewports (`已选 N 项` + `清空`, then equal-peer `共享` / `迁移` / `刷新` / `删除` / `⋯`) and flips to
/// a balanced two-row layout on narrow viewports via attribute bindings (`row(By(wide))`), never rebuilding the tree.
pub fn profiles_batch_bar_node(
  f : @view.View,
  core : Core,
  batch : ProfilesBatch,
  rows : () -> Array[Json],
  stations : () -> Array[Json],
  on_edit_one~ : (Json) -> Unit,
  width? : () -> Double,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let picked = fn() { batch.rows(rows(), stations=stations()) }
  let shareable = fn() { picked().filter(can_share_row) }
  let movable = fn() {
    let sts = stations()
    picked().filter(fn(r) { can_move_row(r, stations=sts) })
  }
  let has_move_target = fn() {
    let mv = movable()
    if mv.is_empty() {
      return false
    }
    let sts = stations()
    for i = 0; i < sts.length(); i = i + 1 {
      let sv = Some(sts[i])
      if flag(sv, "online") {
        let st_addr = text(sv, "station")
        for j = 0; j < mv.length(); j = j + 1 {
          if text(Some(mv[j]), "station") != st_addr {
            return true
          }
        }
      }
    }
    false
  }
  let finished = fn(failed : Array[String]) {
    let valid : Map[String, Bool] = Map([])
    @signals.untracked(fn() {
      let sts = stations()
      for r in rows() {
        if can_select_row(r, stations=sts) {
          valid[text(Some(r), "key")] = true
        }
      }
    })
    batch.chosen.clear()
    for k in failed {
      if valid.contains(k) {
        batch.chosen.set(k, true)
      }
    }
  }
  let build_actions = fn(acts : @view.View) {
    @sf.button_node(
      acts,
      fn() { @sf.t("web-pages.profiles.manage.actionShare") },
      fn() {
        let all_p = @signals.untracked(picked)
        let sh = all_p.filter(can_share_row)
        if sh.is_empty() {
          return
        }
        // Single-row shareable selection reuses authoritative single-row host read so custom `allow` is preserved.
        if all_p.length() == 1 && sh.length() == 1 {
          on_edit_one(sh[0])
        } else {
          pick_stations_many(
            core,
            sh,
            @signals.untracked(stations),
            batch.busy,
            finished,
            skipped=all_p.length() - sh.length(),
            still_here~,
          )
        }
      },
      tone=Plain,
      busy=fn() { batch.busy.get() },
      disabled=fn() { shareable().is_empty() || batch.busy.get() || stations().is_empty() },
    )
    |> ignore
    @sf.button_node(
      acts,
      fn() { @sf.t("web-pages.profiles.manage.moveTo") },
      fn() {
        move_profiles_many(core, @signals.untracked(picked), @signals.untracked(stations), batch.busy, finished, still_here~)
      },
      tone=Plain,
      disabled=fn() { batch.busy.get() || !has_move_target() },
    )
    |> ignore
    @sf.button_node(
      acts,
      fn() { @sf.t("web-pages.profiles.refresh") },
      fn() {
        refresh_profiles_many(core, @signals.untracked(picked), batch.busy, finished, still_here~)
      },
      tone=Plain,
      disabled=fn() { batch.busy.get() || picked().is_empty() },
    )
    |> ignore
    @sf.button_node(
      acts,
      fn() { @sf.t("web-pages.profiles.manage.delete") },
      fn() {
        delete_profiles_many(core, @signals.untracked(picked), @signals.untracked(stations), batch.busy, finished, still_here~)
      },
      tone=Danger,
      disabled=fn() { batch.busy.get() || !picked().iter().any(fn(r) { !flag(Some(r), "machine") }) },
    )
    |> ignore
    @sf.action_box_node(
      acts,
      fn() { @sf.t("web-pages.profiles.manage.more") },
      fn(at) {
        let now = @signals.untracked(picked)
        let any_shared = now.iter().any(fn(r) { can_share_row(r) && flag(Some(r), "shared") })
        let any_cap = now.iter().any(fn(r) { profile_max_sessions(field(Some(r), "profile")) })
        @sf.menu(
          [
            Some(
              @sf.menu_item_of(
                @sf.t("web-pages.profiles.batch.stop"),
                fn() { stop_sharing_many(core, now, batch.busy, finished, still_here~) },
                icon="share",
                disabled=!any_shared,
              ),
            ),
            Some(
              @sf.menu_item_of(
                @sf.t("web-pages.profiles.maxConcurrentSessions"),
                fn() { set_max_sessions_many(core, now, batch.busy, finished, still_here~) },
                icon="settings",
                disabled=!any_cap,
                further=true,
              ),
            ),
          ],
          from=@sf.Beside::Node(at),
          side=Top,
        )
      },
      fn(btn) {
        let bh = @sf.button_height()
        @sf.style_node(btn, fn() { pb_more_btn.then(@ui.style(min_w=Fixed(bh), min_h=Fixed(bh))) }, in_row=true)
        @sf.hover_ground_node(btn)
        @sf.icon_node(btn, "more", 18.0, By(fn() { @sf.theme().p.text })) |> ignore
      },
      disabled=fn() { batch.busy.get() || picked().is_empty() },
    )
    |> ignore
  }
  let wide = fn() { @sf.width_is_wide(width) }
  f.box(fn(root) {
    root
    .row(By(wide))
    .lines_up(By(fn() { if wide() { Some(Middle) } else { None } }))
    .gap(Is(pb_gap))
    |> ignore
    root.box(fn(head) {
      head
      .row(Is(true))
      .lies_along(By(fn() { if wide() { Start } else { Between } }))
      .lines_up(Is(Some(Middle)))
      .gap(Is(pb_gap))
      .shrink(Is(0.0))
      |> ignore
      head.box(fn(cnt) {
        @sf.style_node(cnt, fn() { pb_count_box }, in_row=true)
        @sf.words_node(
          cnt,
          fn() { @sf.t("web-pages.profiles.batch.selected", args=[("n", picked().length().to_string())]) },
          fn() { pb_count_words },
        )
        |> ignore
      })
      |> ignore
      @sf.button_node(
        head,
        fn() { @sf.t("web-pages.profiles.sharing.clear") },
        fn() { batch.clear() },
        tone=Ghost,
        disabled=fn() { batch.busy.get() },
      )
      |> ignore
    })
    |> ignore
    root.box(fn(acts) {
      acts
      .row(Is(true))
      .wraps(Is(Some(pb_gap)))
      .lines_up(Is(Some(Middle)))
      .gap(Is(pb_gap))
      .shrink(Is(1.0))
      .min_width(Is(Some(0.0)))
      |> ignore
      build_actions(acts)
    })
    |> ignore
  })
  |> ignore
}

///|
/// How tall the floating batch dock stands over a page's foot (including wrapped narrow/large-text layouts):
/// reserved in `frame().foot` while selection is non-empty so the last table row always scrolls clear of the dock.
pub fn profiles_batch_room(narrow? : Bool = false) -> Double {
  let bh = @sf.button_height()
  let rows = if narrow { 4.0 } else { 1.0 }
  pb_gap + @sf.card_foot_in(bh) * 2.0 + bh * rows + pb_gap * (rows - 1.0) + pb_gap
}

///|
/// Centered compact floating liquid-glass batch action dock over the foot of `v`, shown whenever at least one
/// selectable row in `rows()` is selected.
pub fn profiles_batch_foot_node(
  v : @view.View,
  core : Core,
  batch : ProfilesBatch,
  rows : () -> Array[Json],
  stations : () -> Array[Json],
  on_edit_one~ : (Json) -> Unit,
  foot? : () -> Double = fn() { 0.0 },
  width? : () -> Double,
  still_here? : () -> Bool = fn() { true },
) -> Unit {
  let shown = fn() { batch.rows(rows(), stations=stations()).length() > 0 }
  v.show(shown, fn(w) {
    w.padding(By(fn() { (0.0, pb_gap, 0.0, pb_gap + foot()) })) |> ignore
    w.over(Is(true), edges=(Some(0.0), None, Some(0.0), Some(0.0))) |> ignore
    @sf.page_lane_node(w, width, fn(c) {
      let wide = fn() { @sf.width_is_wide(width) }
      c.row(Is(true)).lies_along(Is(Middle)) |> ignore
      c.box(fn(dock) {
        let bh = @sf.button_height()
        let pad = @sf.card_foot_in(bh)
        dock
        .grow(By(fn() { if wide() { 0.0 } else { 1.0 } }))
        .shrink(Is(1.0))
        .min_width(Is(Some(0.0)))
        .padding(Is((pad, pad, pad, pad)))
        .radius(By(fn() { @ui.tree_theme().corner(Xl3) }))
        |> ignore
        @sf.panel_surface_decorate(dock, solid=@sf.panel_ground, clips=false) |> ignore
        @sf.floating_host_lend(dock)
        profiles_batch_bar_node(dock, core, batch, rows, stations, on_edit_one~, width?, still_here~)
      })
      |> ignore
    })
  })
}

///|
// kept across runs: a value (no field of it changes)
let pb_count_box : @ui.Style = @ui.css("row align=ACenter pl=S3 pr=S1")

///|
// kept across runs: a value (no field of it changes)
let pb_count_words : @ui.TextStyle = @ui.text_style(size=Ui, weight=Medium, leading=L5, color=Fg, wrap=false)

///|
// kept across runs: a value (no field of it changes)
let pb_more_btn : @ui.Style = @ui.css("row align=ACenter justify=JCenter radius=Full bg=Hover")

///|
// kept across runs: a value (no field of it changes)
let pb_gap : Double = 8.0
