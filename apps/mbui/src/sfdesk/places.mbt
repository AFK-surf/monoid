// The rail's places beyond the chats and the files, as the web's (still.fail web/src/cloud/workspace.tsx StationsSidebar,
// ProfilesSidebar; cloud/StationPage.tsx StationsNav, StationRow; ProfilesNav.tsx): Station and Profile each a list of
// their own in the sidebar (添加 in the band over it), the one picked its page beside it (the first to begin with); 连接
// and 用量 a page across the pane, no sidebar. A page merged for every frame is made once as nodes in its place
// (pane_made); the others still the settings' package's (@settings.page).

///|
fn places_reset() -> Unit {
  place_pick.clear()
}

///|
/// The page picked in a place (the stations' or the profiles' list) of the workspace `w`; none: the first.
fn place_route(src : Source, w : Workspace, place : String) -> @settings.Route? {
  match place_pick.get(place_key(w.id, place)) {
    // (a station or profile gone from the list: the first, not its page waiting for it; one just made a rig stays, its
    // workspace listing it so before the rigs' topic first answers)
    Some(Station(a)) => {
      let mut has_station = false
      for s in stations_listed(src, w) {
        if text(Some(s), "station") == a {
          has_station = true
          break
        }
      }
      if !has_station && place_rig_at(src, w, a) is None && !workspace_lists_rig(src, w, a) {
        place_route_first(src, w, place)
      } else {
        Some(Station(a))
      }
    }
    Some(ProfilesOverview | Profiles("")) =>
      match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
        Some(_) as v if items(v, "items").length() == 0 => None
        _ => Some(Route::ProfilesOverview)
      }
    Some(ProfilesManage(_)) =>
      match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
        Some(_) as v if !flag(v, "manages") || items(v, "items").length() == 0 => place_route_first(src, w, place)
        _ => Some(Route::ProfilesManage(""))
      }
    Some(Profile(_, _) as r) =>
      match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
        Some(_) as v if !has_profile_route(items(v, "items"), r) => place_route_first(src, w, place)
        _ => Some(r)
      }
    Some(r) => Some(r)
    None => place_route_first(src, w, place)
  }
}

///|
/// Whether the workspace's view lists `address` among its rigs (a station made one a moment ago, before the rigs'
/// topic, which the station page reads, first answers).
fn workspace_lists_rig(src : Source, w : Workspace, address : String) -> Bool {
  let v = src.topic("workspace", { "workspace": Json::string(w.id) }).get().value
  items(v, "rigs").iter().any(fn(r) { w.id + "/" + text(Some(r), "id") == address })
}

///|
/// The page a place shows with none picked in it: the first station; the profiles' overview once any profile is listed.
fn place_route_first(src : Source, w : Workspace, place : String) -> @settings.Route? {
  match place {
    "stations" =>
      match stations_listed(src, w).get(0) {
        Some(s) => Some(Route::Station(text(Some(s), "station")))
        None => None
      }
    // (the overview by default once any profile is in the list; once a profile is shown, it stays while the list still
    // has it, the list sorted anew under it taking nothing the person reads away from them)
    "profiles" =>
      profiles_first_kept.read(
        src,
        w.id,
        fn(was) {
          let v = src.topic("profiles", { "scope": Json::string(w.id) }).get().value
          let list = items(v, "items")
          if list.length() == 0 {
            return None
          }
          match was {
            Some(Some(ProfilesOverview | Profiles(""))) => Some(Route::ProfilesOverview)
            Some(Some(ProfilesManage(_))) if flag(v, "manages") => Some(Route::ProfilesManage(""))
            Some(Some(r)) if has_profile_route(list, r) => Some(r)
            _ => Some(Route::ProfilesOverview)
          }
        },
        same=fn(a, b) { a == b },
      )
    _ => None
  }
}

///|
/// What place `place` of workspace `ws` reads in the wide frame's pane as it is first drawn at rest (pane_opens): the
/// stations' and the profiles' their list beside it and the page picked in it (place_route's: the one picked, else the
/// first), that page's reads following the list's answer; the others their page's (sfbase's page_reads). A station
/// picked that the list does not have (one that only runs tasks) its list's alone.
fn place_reads(src : Source, ws : String, place : String) -> @sfbase.OpenReads {
  let of = Json::string(ws)
  match place {
    "stations" => {
      let rows = @sfbase.station_rows_ask(ws)
      // (the workspace's devices under the stations in the list, as they come: not waited for)
      let side = [rows, ("workspace", { "workspace": of })]
      @sfbase.reads_then({ asks: side, then: None }, fn(read) {
        let listed = match read(rows) {
          Some(Array(a)) => a.map(fn(s) { text(Some(s), "station") })
          _ => return None
        }
        let address = match place_pick.get(place_key(ws, place)) {
          Some(Station(a)) => if listed.contains(a) { Some(a) } else { None }
          _ => listed.get(0)
        }
        address.map(fn(a) { @sfbase.route_reads(src, ws, Station(a)) })
      })
    }
    "profiles" => {
      let list : (String, Map[String, Json]) = ("profiles", { "scope": of })
      @sfbase.reads_then({ asks: [list], then: None }, fn(read) {
        let all = items(read(list), "items")
        let routes = all.map(fn(e) { profile_route(Some(e)) })
        // (none listed: no page; the overview, by default and where nothing listed is picked, with its pools)
        let overview : @sfbase.OpenReads = { asks: [("profilesOverview", { "scope": of })], then: None }
        if all.length() == 0 {
          return None
        }
        match place_pick.get(place_key(ws, place)) {
          Some(ProfilesOverview) | Some(Profiles("")) | None => Some(overview)
          Some(ProfilesManage(_)) if flag(read(list), "manages") => Some({ asks: [@sfbase.station_rows_ask(ws)], then: None })
          Some(r) if routes.contains(r) => Some(@sfbase.route_reads(src, ws, r))
          _ => Some(overview)
        }
      })
    }
    _ => @sfbase.page_reads(src, ws, Place(place), true)
  }
}

///|
/// The profile the profiles' place shows with none picked (place_route_first's), by workspace and by the source read.
// kept across runs: what it keeps is let go of by a run anew and by reset (sfbase's derived.mbt)
let profiles_first_kept : @sfbase.Kept[@settings.Route?] = @sfbase.Kept::new()

///|
/// The workspace's stations, their rows as the core lists them.
fn stations_listed(src : Source, w : Workspace) -> Array[Json] {
  match @sfbase.station_rows(src, w.id).value {
    Some(Array(a)) => a
    _ => []
  }
}

///|
/// The station at `address` picked in the stations' place of workspace `ws`, as a press on its row picks it (a made-up
/// run opened on it).
pub fn place_pick_station(ws : String, address : String) -> Unit {
  place_pick[place_key(ws, "stations")] = Route::Station(address)
}

///|
/// The workspace's station that only runs tasks at `address`, if it is one (the settings' rig_at).
fn place_rig_at(src : Source, w : Workspace, address : String) -> Json? {
  let core = settings_core(src, w)
  @settings.rig_at(core, @settings.here_of(core, w.id, w.name), address)
}

///|
/// A profile's page (the web's profilePath): the station's copy the row shows; its page lists the account's other
/// stations.
fn profile_route(e : Json?) -> @settings.Route {
  Route::Profile(text(e, "station"), text(field(e, "profile"), "id"))
}

///|
fn has_profile_route(list : Array[Json], target : @settings.Route) -> Bool {
  for e in list {
    if profile_route(Some(e)) == target {
      return true
    }
  }
  false
}

///|
/// What the stations' place shows in the pane (stations_place_node): the station picked in its list (place_route's: one
/// that only runs tasks too), none while its list is read, the first to add where it has none.
#derive(Eq)
priv enum StationsShown {
  Picked(String)
  Reading
  First
}

///|
/// The stations' place in node `v` (pane_made's, tape_made's): the station picked in its list made once as its page is
/// (sfpages' station_node, every frame's: another station, another page), at the stack's root; while the list is read
/// a station's page in its bones; none in the workspace, the first to add (stations_first_node).
fn stations_place_node(
  v : @view.View,
  src : Source,
  core : @settings.Core,
  here : () -> @settings.Here,
  stint : () -> Int,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  said? : (@sf.PageSaid) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  let shown = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) =>
        match place_route(src, w, "stations") {
          Some(Station(a)) => Picked(a)
          _ => if @sfbase.station_rows(src, w.id).value is Some(_) { StationsShown::First } else { StationsShown::Reading }
        }
      None => Reading
    }
  }
  v.pick_kept(
    shown,
    fn(p, at) {
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match at {
        Picked(a) => {
          // Release any ahead-read handed over by show_answered after the frame draws
          // (idempotent with station_part_read's own shown_read).
          @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfpages.station_shown_at(a)) })
          @sfpages.station_node(p, core, src, here, a, on_back=core.pop, frame~, said?, width~, tips?, stint~)
        }
        Reading => @sfpages.stations_reading_node(p, core, src, here, on_back=core.pop, frame~, said?, width~, tips?)
        First => stations_first_node(p, core, here, frame, width, said?, tips?)
      }
    },
    at_once=true,
    keeps_max=4,
    keep_if=fn(at) { at is Picked(_) },
    on_take=fn(_, at) {
      match at {
        Picked(a) => @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfpages.station_shown_at(a)) })
        _ => ()
      }
    },
  )
}

///|
/// What the profiles' place shows in the pane (`profiles_place_node`): Overview, Batch management, an account's page,
/// or First (empty state to add the first profile).
#derive(Eq)
priv enum ProfilesShown {
  Overview
  Manage(Int)
  Account(String, String)
  First
}

///|
/// The profiles' place in node `v` (pane_made's, tape_made's): the page picked in its sidebar (place_route's), made
/// once as its page is, at the stack's root; none to pick yet, the first to add.
fn profiles_place_node(
  v : @view.View,
  src : Source,
  core : @settings.Core,
  here : () -> @settings.Here,
  stint : () -> Int,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  said? : (@sf.PageSaid) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  // Epoch bumped on role demotion so re-granting admin never wakes a pre-demotion parked Manage pane.
  let manage_gen : @signals.Signal[Int] = @signals.signal(0)
  // Role demotion in wide mode: clear place_pick and bump manage_gen so re-granting never resurrects old picks.
  let manages_now = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) =>
        match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
          Some(_) as pv => flag(pv, "manages")
          None => true
        }
      None => false
    }
  }
  v.reacts(manages_now, fn(ok) {
    if !ok {
      manage_gen.set(manage_gen.untracked() + 1)
      match @signals.untracked(fn() { @sfbase.workspace_in_view(src).0 }) {
        Some(w) => {
          let k = place_key(w.id, "profiles")
          if place_pick.get(k) is Some(ProfilesManage(_)) {
            place_pick.remove(k)
          }
        }
        None => ()
      }
    }
  })
  let picked = fn() -> ProfilesShown {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) =>
        match place_route(src, w, "profiles") {
          Some(ProfilesOverview) | Some(Profiles("")) => Overview
          Some(ProfilesManage(_)) => Manage(manage_gen.get())
          Some(Profile(a, id)) => Account(a, id)
          _ => First
        }
      None => First
    }
  }
  v.pick_kept(
    picked,
    fn(p, at) {
      p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
      match at {
        Overview => {
          @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfbase.profile_shown_at("", "")) })
          @sfpages.profiles_overview_node(
            p,
            core,
            here,
            open_profile=fn(address, id) {
              let ws = here().workspace
              let route = Route::Profile(address, id)
              let at = @sfbase.profile_shown_at(address, id)
              @sfbase.show_answered(src, @sfbase.route_asks(ws, route), at, fn() {
                place_pick[place_key(ws, "profiles")] = route
                @sfbase.show_chosen()
              })
            },
            on_back=core.pop,
            frame~,
            said?,
            width~,
            tips?,
          )
        }
        Manage(_) =>
          @sfpages.profiles_manage_node(
            p,
            src,
            core,
            here,
            "",
            on_back=core.pop,
            frame~,
            said?,
            width~,
            tips?,
            in_place=true,
            active=fn() { picked() is Manage(_) },
          )
        Account(a, id) => {
          // Release any ahead-read handed over by show_answered after the frame draws
          // (idempotent with profile_node's own shown_read).
          @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfbase.profile_shown_at(a, id)) })
          @sfpages.profile_node(p, core, here, a, id, on_back=core.pop, frame~, said?, width~, tips?, stint~)
        }
        First => @sfpages.profiles_first_node(p, core, here, on_back=core.pop, frame~, said?, width~, tips?)
      }
    },
    at_once=true,
    keeps_max=4,
    keep_if=fn(k) {
      match k {
        Overview | Account(_, _) => true
        Manage(g) => @signals.untracked(manages_now) && g == manage_gen.untracked()
        First => false
      }
    },
    pin=fn(k) { k == Overview },
    on_take=fn(_, k) {
      match k {
        // Overview shares `profile_shown_at("", "")` with `places_side_node.mbt` so any overview ahead-read is released too.
        Overview => @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfbase.profile_shown_at("", "")) })
        Account(a, id) => @ui.after_drawn_frame(fn() { @sfbase.shown_read(@sfbase.profile_shown_at(a, id)) })
        Manage(_) | First => ()
      }
    },
  )
}

///|
/// What is wrong, in its tone: amber, red, or muted (neutral).
fn trouble_ink(tone : String) -> @ui.TextStyle {
  match tone {
    "red" => place_trouble_red
    "neutral" => place_trouble_neutral
    _ => place_trouble_amber
  }
}

///|
// kept across runs: a value (no field of it changes)
let place_trouble_red : @ui.TextStyle = @ui.text_style(color=Danger)

///|
// kept across runs: a value (no field of it changes)
let place_trouble_amber : @ui.TextStyle = @ui.text_style(color=WarnInk)

///|
// kept across runs: a value (no field of it changes)
let place_trouble_neutral : @ui.TextStyle = @ui.text_style(color=Muted)

///|
/// 使用此账号 (ProfilesNav MachineLoginRow): the accent's words.
// kept across runs: a value (no field of it changes)
let place_use : @ui.TextStyle = @ui.text_style(color=AccentText)

///|
/// None in the workspace (the web's StationsFirst): its scene, 添加 station where the viewer may add one (a member one
/// that only runs tasks: settings' place_action), else that the others wait for one who may.
fn stations_first_node(
  v : @view.View,
  core : @settings.Core,
  here : () -> @settings.Here,
  frame : () -> @sf.PageFrame,
  width : () -> Double,
  said? : (@sf.PageSaid) -> Unit,
  tips? : @sf.TipLayer,
) -> Unit {
  let adds = fn() { @settings.place_action(core, here(), "stations") is Some(_) }
  @sf.page_node(v, fn() { "Station" }, on_back=core.pop, frame~, said?, width~, tips?, fn() { ["first"] }, fn(b, _) {
    @sf.first_one_node(
      b,
      fn() { @sf.t("web-pages.settings.stations.add") },
      art=fn(a) {
        a.pick(fn() { @sf.theme().dark }, fn(x, dark) {
          @sf.drawable_node(x, if dark { "illus_no_station_dark" } else { "illus_no_station" }, pl_art_w) |> ignore
        })
      },
      fn(a) {
        a.pick(adds, fn(e, can) {
          if can {
            @sf.button_opens_node(
              e,
              fn() { @sf.t("web-pages.settings.stations.add") },
              fn(button) {
                match @settings.place_action(core, here(), "stations") {
                  Some(add) => add(Node(button))
                  None => ()
                }
              },
              tone=Primary,
              icon="plus",
            )
            |> ignore
          } else {
            @sf.words_node(e, fn() { @sf.t("web-pages.settings.stations.noneYet") }, fn() { desk_muted_line }) |> ignore
          }
        })
      },
    )
  })
}

///|
let pl_art_w : Double = 240.0

///|
// kept across runs: a value (no field of it changes)
let desk_muted_line : @ui.TextStyle = @ui.text_style(size=Meta, leading=L6, color=Muted, wrap=false)
