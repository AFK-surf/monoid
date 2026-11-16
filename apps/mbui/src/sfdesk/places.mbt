// The rail's places beyond the chats and the files, as the web's (still.fail web/src/cloud/workspace.tsx StationsSidebar,
// ProfilesSidebar; cloud/StationPage.tsx StationsNav, StationRow; ProfilesNav.tsx): Station and Profile each a list of
// their own in the sidebar (添加 in the band over it), the one picked its page beside it (the first to begin with); 连接
// and 用量 a page across the pane, no sidebar. A page merged for every frame is made once as nodes in its place
// (pane_made); the others still the settings' package's (@settings.page).

///|
/// A place of the rail's in the pane: Station's and Profile's the page picked in their list, 连接's its page, the
/// others (用量) the settings' page of it across the pane.
fn place_page(c : @ui.Ctx, src : Source, w : Workspace, place : String) -> Unit {
  let core = settings_core(src, w)
  let here = @settings.here_of(core, w.id, w.name)
  // (at the stack's root: no back over its head, its own or the settings' pages')
  @settings.wide_deep.val = false
  settings_deep.val = false
  @settings.frame(core, here, root=true)
  match place {
    // (made once as nodes in every frame: stations_place_node, profiles_place_node)
    "stations" | "profiles" => ()
    _ =>
      c.box(style=place_across, fn() {
        match @settings.route_of(place) {
          Some(r) => @settings.page(c, core, here, r, root=true)
          None => ()
        }
      })
      |> ignore
  }
}

///|
fn places_reset() -> Unit {
  place_pick.clear()
}

///|
/// A page across the pane (连接, 用量: no sidebar), on the page's ground.
// kept across runs: a value (no field of it changes)
let place_across : @ui.Style = @ui.css("w=Full h=Full bg=Bg")

///|
/// The page picked in a place (the stations' or the profiles' list) of the workspace `w`; none: the first.
fn place_route(src : Source, w : Workspace, place : String) -> @settings.Route? {
  match place_pick.get(place_key(w.id, place)) {
    // (a station or profile gone from the list: the first, not its page waiting for it)
    Some(Station(a)) if !stations_listed(src, w).iter().any(fn(s) { text(Some(s), "station") == a }) && place_rig_at(src, w, a) is None =>
      place_route_first(src, w, place)
    Some(Profiles("")) =>
      match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
        Some(_) as v if items(v, "items").length() == 0 => None
        _ => Some(Route::Profiles(""))
      }
    Some(Profile(_, _) as r) =>
      match src.topic("profiles", { "scope": Json::string(w.id) }).get().value {
        Some(_) as v if !items(v, "items").iter().any(fn(e) { profile_route(Some(e)) == r }) =>
          place_route_first(src, w, place)
        _ => Some(r)
      }
    Some(r) => Some(r)
    None => place_route_first(src, w, place)
  }
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
          let list = items(src.topic("profiles", { "scope": Json::string(w.id) }).get().value, "items")
          if list.length() == 0 {
            return None
          }
          match was {
            Some(Some(Profiles(""))) => Some(Route::Profiles(""))
            Some(Some(r)) if list.iter().any(fn(e) { profile_route(Some(e)) == r }) => Some(r)
            _ => Some(Route::Profiles(""))
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
        let route = match place_pick.get(place_key(ws, place)) {
          Some(r) if routes.contains(r) => Some(r)
          _ => None
        }
        route.map(fn(r) { @sfbase.route_reads(src, ws, r) })
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
          _ => if @sfbase.station_rows(src, w.id).value is Some(_) { First } else { Reading }
        }
      None => Reading
    }
  }
  v.pick(shown, fn(p, at) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match at {
      Picked(a) => @sfpages.station_node(p, core, src, here, a, on_back=core.pop, frame~, said?, width~, tips?, stint~)
      Reading => @sfpages.stations_reading_node(p, core, src, here, on_back=core.pop, frame~, said?, width~, tips?)
      First => stations_first_node(p, core, here, frame, width, said?, tips?)
    }
  })
}

///|
/// The profiles' place in node `v` (pane_made's, tape_made's): the profile picked in its list (place_route's), made once
/// as its page is (another, another page), at the stack's root; none to pick yet, the first to add.
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
  let picked = fn() {
    match @sfbase.workspace_in_view(src).0 {
      Some(w) =>
        match place_route(src, w, "profiles") {
          Some(Profiles("")) => Some(("", ""))
          Some(Profile(a, id)) => Some((a, id))
          _ => None
        }
      None => None
    }
  }
  v.pick(picked, fn(p, at) {
    p.grow(Is(1.0)).min_height(Is(Some(0.0))) |> ignore
    match at {
      Some(("", "")) =>
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
      Some((a, id)) => @sfpages.profile_node(p, core, here, a, id, on_back=core.pop, frame~, said?, width~, tips?, stint~)
      None => @sfpages.profiles_first_node(p, core, here, on_back=core.pop, frame~, said?, width~, tips?)
    }
  })
}

///|
/// The stations' sidebar (StationsNav): 添加 station, then a row each.
fn stations_side(c : @ui.Ctx, src : Source, w : Workspace) -> Unit {
  let core = settings_core(src, w)
  let here = @settings.here_of(core, w.id, w.name)
  let picked = place_route(src, w, "stations")
  // (a station's page in the pane once what it shows is answered, where what opens waits for what it shows: its station,
  // then what its part shown reads, the pane as it was meanwhile; sfbase's route_open_asks, route_open_then)
  let pick = fn(address : String) {
    let route = Route::Station(address)
    let show = fn() {
      place_pick[place_key(w.id, "stations")] = route
      @sfbase.show_chosen()
    }
    if !(src.gates_opens)() || @signals.untracked(fn() { place_route(src, w, "stations") }) == Some(route) {
      show()
      return
    }
    @sfbase.show_answered(
      src,
      @sfbase.route_open_asks(src, w, route),
      @sfpages.station_shown_at(address),
      show,
      then?=@sfbase.route_open_then(src, w, route),
    )
  }
  c.box(style=place_side, fn() {
    side_top(c)
    nav_action(c, "stations/add", @sf.t("web-pages.settings.stations.add"), @settings.place_action(core, here, "stations"), trailing?=update_trailing(c, src), band=update_band(), at=side_at())
    side_scroll(c, "stations-nav/" + w.id, fn() {
      let listed = stations_listed(src, w)
      for i, s in listed {
        let s = Some(s)
        let address = text(s, "station")
        let on = picked == Some(Route::Station(address))
        station_side_row(c, src, s, on, i + 1 < listed.length(), fn() { pick(address) })
      }
      // those that only run tasks after the whole ones: whose each is and how it is, in the figures' place
      for r in @settings.rigs_listed(core, here) {
        let r = Some(r)
        let address = w.id + "/" + text(r, "id")
        let t = @sf.theme()
        nav_item(
          c,
          at=side_at(),
          "stations/" + address,
          picked == Some(Route::Station(address)),
          fn() { @sf.icon(c, "boxes", size=nav_mark_side, color=t.p.text) |> ignore },
          fn() { nav_title(c, text(r, "name")) },
          lines=fn() { @sfpages.rig_figures(c, r) },
          keep_lines=2,
          more=false,
          on_press=fn() { pick(address) },
        )
      }
      // the workspace's devices under their heading (设备: attached to a station, or a person's phone), each opening
      // its panel
      let devices = @settings.devices_listed(core, here)
      if devices.length() > 0 {
        @sf.list_heading(c, @sf.t("web-pages.devices.title"), side_at())
      }
      for d in devices {
        let d = Some(d)
        let t = @sf.theme()
        nav_item(
          c,
          at=side_at(),
          "devices/" + text(d, "station") + "/" + text(d, "id"),
          false,
          fn() { @sf.icon(c, @settings.device_icon(d), size=nav_mark_side, color=t.p.text) |> ignore },
          fn() { nav_title(c, text(d, "name"), away=field(d, "online") is Some(False)) },
          lines=fn() { c.text(@settings.device_said(d), style=nav_meta(), allow_ellipsis=true) |> ignore },
          keep_lines=1,
          more=false,
          on_press=fn() { @settings.open_device(core, here, text(d, "station"), text(d, "id"), Unanchored) },
        )
      }
    })
  })
  |> ignore
}

///|
/// A station's row (StationRow): its mark and name, how it is at the end (@sfpages.station_state); while up, what is
/// left of its CPU, memory and disk and how this device reaches it (@sfpages.station_figures); those two lines' room
/// kept while it is away, every station's row as high.
fn station_side_row(c : @ui.Ctx, src : Source, s : Json?, on : Bool, more : Bool, pick : () -> Unit) -> Unit {
  let t = @sf.theme()
  nav_item(
      c,
      at=side_at(),
      "stations/" + text(s, "station"),
      on,
      fn() { @sf.station_icon(c, text(s, "emoji"), text(s, "icon"), nav_mark_side, t.p.text) },
      fn() { nav_title(c, text(s, "name")) },
      end=fn() { @sfpages.station_state(c, s) },
      lines=fn() { @sfpages.station_figures(c, src, s) },
      keep_lines=2,
      more~,
      on_press=pick,
    )
}

// ── Profile ─────────────────────────────────────────────────────────────

///|
/// The profiles' sidebar (ProfilesNav): 添加 Profile, a section each kind of account, a row an account; then each
/// station's own logins not made profiles yet.
fn profiles_side(c : @ui.Ctx, src : Source, w : Workspace) -> Unit {
  let t = @sf.theme()
  let core = settings_core(src, w)
  let here = @settings.here_of(core, w.id, w.name)
  let picked = place_route(src, w, "profiles")
  let list = items(src.topic("profiles", { "scope": Json::string(w.id) }).get().value, "items")
  c.box(style=place_side, fn() {
    side_top(c)
    nav_action(c, "profiles/add", @sf.t("web-pages.settings.profiles.add"), @settings.place_action(core, here, "profiles"), trailing?=update_trailing(c, src), band=update_band(), at=side_at())
    side_scroll(c, "profiles-nav/" + w.id, fn() {
      if list.length() > 0 {
        let (sum_line, sum_tone) = @sfpages.profiles_side_summary(list)
        let ov_label = if @sf.language() == "en" { "Overview" } else { "概览" }
        nav_item(
          c,
          at=side_at(),
          "profiles/overview",
          picked == Some(Route::Profiles("")),
          fn() { @sf.icon(c, "quota", size=nav_mark_side, color=t.p.text) |> ignore },
          fn() { nav_title(c, ov_label) },
          lines=fn() {
            if sum_line != "" {
              @sf.list_row_line(c, fn() { c.text(sum_line, style=nav_meta().then(trouble_ink(sum_tone)).then(place_fill)) |> ignore })
            }
          },
          more=false,
          on_press=fn() {
            place_pick[place_key(w.id, "profiles")] = Route::Profiles("")
            @sfbase.show_chosen()
          },
        )
      }
      let mut group = ""
      // each station's own logins, not profiles yet (under the profiles: each station up that offers one)
      let offered = @settings.profiles_offers(src.topic("profiles", { "scope": Json::string(w.id) }).get().value).map(fn(o) {
        (o.0, o.1.filter(fn(l) { flag(Some(l), "offered") && text(field(Some(l), "quota"), "state") != "blocked" }))
      })
      // (the room the widest allowance's chips of each provider need: one way for every row of a vendor's, a profile's
      // or an offered login's, nav_quota_chips; the user, 2026-11-13: 「按账号类型来搞，不要所有全用同一种」「相同供应商的
      // 账号用同一种就行」)
      let kind_of = fn(e : Json?) {
        let g = text(e, "group")
        if g != "key" {
          g
        } else {
          let a = field(field(e, "profile"), "access")
          let pv = text(a, "provider")
          if pv != "" { pv } else { text(a, "kind") }
        }
      }
      let offer_kind = fn(l : Json?) {
        let rt = text(l, "runtime")
        if rt == "codex" { "chatgpt" } else { rt }
      }
      let chips : Map[String, Double] = Map([])
      for e in list {
        let e = Some(e)
        let k = kind_of(e)
        let w = @sf.nav_quota_line(c, field(field(e, "profile"), "quota"))
        chips[k] = dmax(chips.get(k).unwrap_or(0.0), w)
      }
      for o in offered {
        for l in o.1 {
          let l = Some(l)
          let k = offer_kind(l)
          let w = @sf.nav_quota_line(c, field(l, "quota"))
          chips[k] = dmax(chips.get(k).unwrap_or(0.0), w)
        }
      }
      for i, e in list {
        let e = Some(e)
        // (another row under it: the next of its group)
        let more = i + 1 < list.length() && text(Some(list[i + 1]), "group") == text(e, "group")
        if text(e, "group") != group {
          group = text(e, "group")
          @sf.list_heading(c, text(e, "groupTitle"), side_at())
        }
        let p = field(e, "profile")
        let route = profile_route(e)
        let usable = flag(e, "usable")
        // how it is where that is not simply fine, as the core says it, in its tone: what
        // needs a look in colour
        let trouble = text(field(e, "state"), "text")
        let tone = text(field(e, "state"), "tone")
        // its name and its allowance: its plan, where it can be used and which connects use it are its page's (the user,
        // 2026-11-14: 「额度的第二行感觉现在就一个有效信息」; the plan beside the name cut the name short in the narrowest
        // sidebar); the line under the name is only for what is wrong, and a balance where it has no windows.
        let quota = field(p, "quota")
        let ok = text(quota, "state") == "ok"
        let windows = ok && items(quota, "windows").length() > 0
        let credits = ok && !windows && text(quota, "creditsText") != ""
        nav_item(
            c,
            at=side_at(),
            "profiles/" + text(e, "key"),
            picked == Some(route),
            fn() { @sf.provider_logo(c, text(p, "runtime"), text(field(p, "access"), "kind"), nav_mark_side, text(p, "providerMark")) },
            // (a subscription by its account, a key by its name: the core's)
            fn() { nav_title(c, if text(p, "name") != "" { text(p, "name") } else { text(e, "title") }, away=!usable) },
            lines=fn() {
              if trouble != "" {
                @sf.list_row_line(c, fn() { c.text(trouble, style=nav_meta().then(trouble_ink(tone)).then(place_fill)) |> ignore })
              }
              let sub_line = if credits {
                text(quota, "creditsText")
              } else if usable && trouble == "" && !windows && text(e, "group") != "key" {
                if quota is (None | Some(Null)) {
                  @sf.t("web-main.quota.unchecked")
                } else if text(quota, "detail") != "" {
                  text(quota, "detail")
                } else if text(quota, "state") == "unsupported" {
                  @sf.t("android-settings.quota.none")
                } else if text(quota, "state") != "ok" {
                  @sf.t("web-main.quota.unknown")
                } else {
                  ""
                }
              } else {
                ""
              }
              if sub_line != "" {
                @sf.list_row_line(c, fn() { c.text(sub_line, style=nav_meta()) |> ignore })
              }
            },
            more~,
            foot?=if windows {
              let widest = chips.get(kind_of(e)).unwrap_or(0.0)
              Some(fn() { @sf.nav_quota_chips(c, quota, key="profiles/" + text(e, "key"), at=side_at(), widest~) })
            } else {
              None
            },
            foot_capsule?=if windows { Some(@sf.fill_chip_small_h) } else { None },
            // (its page in the pane once what it shows is answered, the pane as it was meanwhile, what it asked handed
            // to that page: sfbase's account_open.mbt)
            on_press=fn() {
              // (the one shown already: nothing to ask, nothing made anew to take it)
              if @signals.untracked(fn() { place_route(src, w, "profiles") }) == Some(route) {
                @sfbase.show_chosen()
                return
              }
              let at = match route {
                Route::Profile(station, id) => @sfbase.profile_shown_at(station, id)
                _ => ""
              }
              @sfbase.show_answered(src, @sfbase.route_asks(w.id, route), at, fn() {
                place_pick[place_key(w.id, "profiles")] = route
                @sfbase.show_chosen()
              })
            },
          )
      }
      // as the profiles' list says them; its allowance under each as a profile's row has it (the same chips), so an
      // account not added yet shows what is left of its week as well
      for o in offered {
        let s = Some(o.0)
        let station = text(s, "station")
        let offers = o.1
        if offers.length() == 0 {
          continue
        }
        @sf.list_heading(c, @sf.t("web-pages.profiles.machineSignedIn", args=[("station", text(s, "name"))]), side_at())
        for j, l in offers {
          let l = Some(l)
          let quota = field(l, "quota")
          let windows = text(quota, "state") == "ok" && items(quota, "windows").length() > 0
          let key = "profiles/machine/" + station + "/" + text(l, "runtime")
          nav_item(
              c,
              at=side_at(),
              key,
              false,
              fn() { @sf.maker_mark(c, "", text(l, "runtime"), nav_mark_side) |> ignore },
              fn() { nav_title(c, @settings.runtime_label(text(l, "runtime"))) },
              lines=fn() {
                @sf.list_row_line(c, fn() {
                  c.box(style=place_grow, fn() { c.text(text(l, "email"), style=nav_meta(), allow_ellipsis=true) |> ignore }) |> ignore
                  c.text(@sf.t("android-settings.machine.use"), style=nav_meta().then(place_use)) |> ignore
                })
              },
              more=j + 1 < offers.length(),
              foot?=if windows {
                let widest = chips.get(offer_kind(l)).unwrap_or(0.0)
                Some(fn() { @sf.nav_quota_chips(c, quota, key~, at=side_at(), widest~) })
              } else {
                None
              },
              foot_capsule?=if windows { Some(@sf.fill_chip_small_h) } else { None },
              // (once what it shows is answered, the screen as it was meanwhile, as the page's own choice of a station
              // opens it: sfpages' open_new_profile)
              on_press=fn() {
                @sfpages.open_new_profile(src, core, here, station, fn() {
                  @sfbase.history_push()
                  app.nav.push(Setting(Route::NewProfile(station)))
                  @sfbase.show_chosen()
                })
              },
            )
        }
      }
      ignore(t)
    })
  })
  |> ignore
}

///|
// kept across runs: a value (no field of it changes)
let place_side : @ui.Style = @ui.css("w=Full h=Full")

///|
// kept across runs: a value (no field of it changes)
let place_grow : @ui.Style = @ui.style(w=@sf.grow, clip=true)

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
/// The words that give way first.
// kept across runs: a value (no field of it changes)
let place_fill : @ui.TextStyle = @ui.text_style(w=Cut)

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
