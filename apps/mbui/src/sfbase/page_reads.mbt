// What each page and each settings' page reads of the core as it is first drawn at rest, every one of it read there
// whatever the core answers (a topic read only for some answers is not said, or is said by `then` after what decides
// it): what a page opening waits for where a card, a panel or a sheet waits for what it reads too (gates_opens,
// MBUI_OPEN_WHOLE), the screen as it was meanwhile: a press through open_answered (route_open_asks, route_open_then),
// a page come on top by any way through the pane's or the stack's wait (sfapp's page_opens_by, sfdesk's pane_opens).
// One table, matched whole: a page or a route added says what it reads here or the compiler stops it.

///|
/// What is asked first and what follows from its answers (asked_now's `then`: given how to read what was asked, the
/// asks that follow).
pub(all) struct OpenReads {
  asks : Array[(String, Map[String, Json])]
  then : ((((String, Map[String, Json])) -> Json?) -> Array[(String, Map[String, Json])])?
}

///|
fn reads_of(asks : Array[(String, Map[String, Json])]) -> OpenReads {
  { asks, then: None }
}

///|
/// `reads`, and what `more` gives of what was asked (each time all asked so far is told, as `then` is): the asks of a
/// page that follow from which one a list's answer picks.
pub fn reads_then(reads : OpenReads, more : (((String, Map[String, Json])) -> Json?) -> OpenReads?) -> OpenReads {
  {
    asks: reads.asks,
    then: Some(fn(read) {
      let out = match reads.then {
        Some(after) => after(read)
        None => []
      }
      match more(read) {
        Some(m) => {
          out.append(m.asks)
          match m.then {
            Some(after) => out.append(after(read))
            None => ()
          }
        }
        None => ()
      }
      out
    }),
  }
}

///|
/// Whether a gate takes `t` as told: a value, why not, or that it waits on a station (shown as waiting, never held for).
pub fn open_told(t : TopicState) -> Bool {
  opens_answered(t) || t.waiting
}

///|
/// Whether all `reads` says is told, each asked of `ask`: what it asks first, then each time all asked so far is told
/// what its `then` gives that is not asked yet, till it gives nothing new (asked_now's, read where the gate reads).
pub fn reads_told(reads : OpenReads, ask : (String, Map[String, Json]) -> TopicState) -> Bool {
  let key = fn(a : (String, Map[String, Json])) { a.0 + "\u{1}" + Json::object(a.1).stringify() }
  let asked = reads.asks.copy()
  let keys = asked.map(key)
  // (each asked, told or not, so all of it is asked at once, not one after another)
  let mut all = asked.fold(init=true, fn(all, a) { open_told(ask(a.0, a.1)) && all })
  while all {
    let more = match reads.then {
      Some(after) => after(fn(a) { ask(a.0, a.1).value }).filter(fn(a) { !keys.contains(key(a)) })
      None => []
    }
    if more.is_empty() {
      break
    }
    for a in more {
      if !keys.contains(key(a)) {
        keys.push(key(a))
        asked.push(a)
        all = open_told(ask(a.0, a.1)) && all
      }
    }
  }
  all
}

///|
/// Whether each picture at `urls` (a person's face) that a page shows as it opens (chat_opens') is in to be drawn,
/// each said by `waits` (Source.picture_waits): none that the device holds being read by the core, or its decode not
/// done; each asked, so all come at once. Waited for as what the page reads is, `page_local_ms` at most (2026-11-16: a
/// face came a frame after the words, from its initial to the picture); never one the device has not (the network's to
/// bring) nor one that could not be had.
fn pictures_in(waits : (String) -> Bool, urls : Array[String]) -> Bool {
  let seen : Map[String, Bool] = Map([])
  let mut all = true
  for url in urls {
    if url == "" || seen.contains(url) {
      continue
    }
    seen[url] = true
    all = !waits(url) && all
  }
  all
}

///|
/// What the settings' list reads (sfpages' settings_parts_of: 小屏's settings page, the settings' sidebar on 中屏 and
/// 大屏): the workspace, its stations' rows, its connects, its vaults, its accounts (its lock is every shell's).
pub fn settings_list_asks(ws : String) -> Array[(String, Map[String, Json])] {
  let of = Json::string(ws)
  [
    ("workspace", { "workspace": of }),
    station_rows_ask(ws),
    ("connects", { "scope": of, "mine": Json::boolean(false) }),
    ("vaults", { "workspace": of }),
    ("profiles", { "scope": of }),
  ]
}

///|
/// A station's own topic (settings' station_read), of the workspace its address names.
fn station_ask(ws : String, address : String) -> (String, Map[String, Json]) {
  ("station", { "scope": Json::string(account_scope(ws, address)), "station": Json::string(address) })
}

///|
/// What the settings' route `r` reads of workspace `ws` as its page is first drawn at rest, on every screen (its page's
/// own, not the settings' sidebar beside it). None of a route that reads nothing of the core as it opens (what the
/// device keeps alone, the build's own): said so, each by name.
pub fn route_reads(src : Source, ws : String, r : @settings.Route) -> OpenReads {
  let of = Json::string(ws)
  let scope = { "scope": of }
  let stations = station_rows_ask(ws)
  let part = fn(address : String, name : String) -> (String, Map[String, Json]) {
    (
      "stationPart",
      { "scope": Json::string(account_scope(ws, address)), "station": Json::string(address), "part": Json::string(name) },
    )
  }
  match r {
    // (settings itself: its list, as 小屏's settings page draws it)
    Home => reads_of(settings_list_asks(ws))
    // (where the account is signed in, by the account the workspace is reached through: settings' here_of's)
    Me => {
      let accounts : (String, Map[String, Json]) = ("workspaces", Map([]))
      {
        asks: [accounts],
        then: Some(fn(read) {
          for a in items(read(accounts), "workspaces") {
            for w in items(Some(a), "workspaces") {
              if text(Some(w), "id") == ws {
                return [("loginSessions", { "account": Json::string(text(field(Some(a), "account"), "sub")) })]
              }
            }
          }
          []
        }),
      }
    }
    Fonts => reads_of([("fonts", Map([]))])
    // (how its members' devices reach its stations, by the workspace's id as its view says it: sfpages workspace_page)
    Workspace => {
      let view : (String, Map[String, Json]) = ("workspace", { "workspace": of })
      {
        asks: [view],
        then: Some(fn(read) {
          match read(view) {
            Some(Object(_)) as v => [("workspaceWays", { "workspace": Json::string(text(v, "id")) })]
            _ => []
          }
        }),
      }
    }
    SecurityOpen => reads_of([("lockDraft", { "workspace": of })])
    Vault => reads_of([("vaults", { "workspace": of })])
    // (how each station up is reached, sampled, is asked by its card alone; the workspace's devices are listed under
    // the stations, a block made as it comes into view: neither waited for)
    Stations => reads_of([stations, ("workspace", { "workspace": of })])
    // (its station whole, then what its part shown reads as it is first drawn: sfpages' station_open_more)
    Station(address) => {
      let ask = station_ask(ws, address)
      {
        asks: [("workspace", { "workspace": of }), ask],
        then: Some(fn(read) {
          match read(ask) {
            Some(Object(_)) as s =>
              // (the workspace's devices, its overview's last block, made as it comes into view: not waited for)
              (station_open_more.val)(src, { id: ws, name: "", emoji: "", icon: "", email: "" }, address, s.unwrap()).filter(fn(
                a,
              ) {
                a.0 != "devices"
              })
            _ => []
          }
        }),
      }
    }
    // (and the Profile overview's pools where it shows them in the list's place: 概览 switched to)
    Profiles("") =>
      reads_of(
        if @signals.untracked(fn() { @settings.profiles_narrow_overview.get() }) {
          [stations, ("profiles", scope), ("profilesOverview", scope)]
        } else {
          [stations, ("profiles", scope)]
        },
      )
    Profiles(address) => reads_of([stations, part(address, "profiles"), part(address, "machineLogins")])
    Profile(station, id) => reads_of(profile_page_asks(ws, station, id))
    Connects(_) => reads_of([("connects", { "scope": of, "mine": Json::boolean(false) }), stations])
    Connect(address, id) =>
      reads_of([
        (
          "connect",
          { "scope": Json::string(account_scope(ws, address)), "station": Json::string(address), "id": Json::string(id) },
        ),
      ])
    // (each station's memory is its row's, as it comes: never waited for)
    Memories => reads_of([stations])
    Memory(address) => reads_of([stations, ("memory", { "station": Json::string(address) })])
    MemoryDoc(address, _, _) => reads_of([("memory", { "station": Json::string(address) })])
    // (as it opens with nothing chosen in it: sfpages usage_ask's seven days)
    Usage => {
      let asks = [("usage", { "scope": of, "days": Json::number(7.0) })]
      if (src.asks_agent_rates)() { asks.push(("agentRates", { "scope": of })) }
      reads_of(asks)
    }
    UsagePrices(days) => reads_of([("usage", { "scope": of, "days": Json::number(days.to_double()) })])
    // (its first page: sfbase bars.mbt place_reads')
    Archive => reads_of([("archive", { "scope": of, "limit": Json::number(60.0) })])
    AdbShare(_) => reads_of([("adbShare", Map([]))])
    // (the draft of the account it makes is the page's own, opened as it is made: never asked ahead)
    NewProfile(address) => reads_of([stations, station_ask(ws, address)])
    ProfileAccount(key) => reads_of(account_page_asks(ws, key))
    // (the vault picked in it, the page's own choice: its items read as it is made)
    VaultItems => reads_of([("vaults", { "workspace": of }), ("profiles", scope)])
    VaultItem(vault, item) =>
      reads_of([
        ("vaults", { "workspace": of }),
        ("vaultItems", { "workspace": of, "vault": Json::string(vault) }),
        ("vaultUses", { "workspace": of, "vault": Json::string(vault), "item": Json::string(item) }),
      ])
    AutoDecisions => reads_of([("settings", scope)])
    // (the station whose rule it shows, the page's own choice among them)
    AutoCompletion => reads_of([stations])
    AutoPolicy(address) | StationArchiving(address) | StationBackup(address) => reads_of([station_ask(ws, address)])
    // (each station's archiving is its row's, as it comes)
    Archiving => reads_of([("settings", scope), stations])
    // (each station's backup summary is its row's, as it comes)
    Backup => reads_of([stations])
    // (nothing chosen to move yet, as it opens)
    StationMove(address) =>
      reads_of([
        station_ask(ws, address),
        ("stationMove", { "station": Json::string(address), "to": Json::string(""), "module": Json::string("") }),
      ])
    Changelog => reads_of([("changelog", { "limit": Json::number(30.0) })])
    Notifications => reads_of([("notices", { "workspace": of })])
    // (what this device keeps and its own settings, the build's own words, the lock every shell reads: nothing of the
    // core's waited for)
    Appearance
    | Experimental
    | Security
    | BarSettings
    | KeptFiles
    | KeptChat(_, _)
    | About
    | Shortcuts
    | Network
    | LocalStation
    | Permissions => reads_of([])
  }
}

///|
/// What page `p` of workspace `ws` reads of `src` as it is first drawn at rest, `wide` in the wide frame's pane (中屏,
/// 大屏) else 小屏's stack: a chat's, Home's and an agent's history's are their shells' own (chat_opens, sfapp's
/// home_opens), not said here. A page drawn over the whole window or beside a chat reads nothing the pane waits for.
pub fn page_reads(src : Source, ws : String, p : Page, wide : Bool) -> OpenReads {
  let of = Json::string(ws)
  let stations = station_rows_ask(ws)
  let drive = fn(at : DriveAt) -> Array[(String, Map[String, Json])] {
    match at.root {
      Some(root) =>
        [("drive", { "station": Json::string(at.station), "root": Json::string(root), "path": Json::string(at.path) })]
      // (its roots, the first as the station lists them: what decides it the page's own)
      None => []
    }
  }
  match p {
    Settings =>
      // (中屏 and 大屏: beside the list, its first row's page: sfdesk's settings_landing, the account's)
      if wide {
        let me = route_reads(src, ws, Me)
        { asks: [..settings_list_asks(ws), ..me.asks], then: me.then }
      } else {
        reads_of(settings_list_asks(ws))
      }
    Setting(r) => {
      let own = route_reads(src, ws, r)
      // (中屏 and 大屏: the settings' list beside it)
      if wide {
        { asks: [..settings_list_asks(ws), ..own.asks], then: own.then }
      } else {
        own
      }
    }
    // (a place of the rail's that is a settings' page: that page's; the stations' and the profiles' with what is picked
    // in them are the wide frame's own, sfdesk's pane_opens)
    // (小屏's Profile place on 概览: its pools as well)
    Place("profiles") if !wide && @signals.untracked(fn() { @settings.profiles_place_overview.get() }) =>
      reads_of([stations, ("profiles", { "scope": of }), ("profilesOverview", { "scope": of })])
    Place("remote") => {
      let terms_on = (src.asks_terminals)()
      {
        asks: [stations, ..if wide { [("prefs", {})] } else { [] }],
        then: Some(fn(read) {
          let out : Array[(String, Map[String, Json])] = []
          match read(stations) {
            Some(Array(all)) =>
              for s in all {
                if field(Some(s), "online") == Some(Json::boolean(true)) && field(Some(s), "station") is Some(String(address)) {
                  out.push(("screens", { "station": Json::string(address) }))
                  if terms_on {
                    out.push(("terminals", { "station": Json::string(address) }))
                  }
                }
              }
            _ => ()
          }
          out
        }),
      }
    }
    Place(name) =>
      match @settings.route_of(name) {
        Some(r) => route_reads(src, ws, r)
        None => reads_of([])
      }
    Archived => route_reads(src, ws, Archive)
    Files =>
      reads_of(
        if wide {
          [("filesTabs", { "workspace": of }), stations, ("workspace", { "workspace": of })]
        } else {
          [("workspace", { "workspace": of }), stations]
        },
      )
    Drive(at) =>
      reads_of(
        if wide {
          [..drive(at), stations, ("filesTabs", { "workspace": of }), ("workspace", { "workspace": of })]
        } else {
          [..drive(at), stations, ("workspace", { "workspace": of })]
        },
      )
    NewChat => reads_of([("newChat", { "scope": of })])
    // (on 小屏 a page of the stack; in the wide frame beside its chat, shown already, what is beside it waited for in
    // its tab: sfdesk's service_tab.mbt beside_follow)
    Service(station, job) =>
      reads_of(if wide { [] } else { [("job", { "station": Json::string(station), "id": Json::string(job) }), stations] })
    PreviewFile(_, _, _, _) => reads_of(if wide { [] } else { [stations] })
    DriveRead(at) =>
      reads_of(
        match at.root {
          Some(root) if !wide =>
            [
              stations,
              (
                "drivePlace",
                { "station": Json::string(at.station), "root": Json::string(root), "path": Json::string(at.path) },
              ),
            ]
          _ => []
        },
      )
    // (a film played, a station's screen or terminal: over the whole window, each showing its own wait as its stream
    // comes; their shells' own, as are Home, a chat and an agent's history: chat_opens, home_opens; a chat's tab in a
    // window of its own, what it shows the tab's as it was beside the chat, handed over)
    DrivePlay(_) | Screen(_) | Terminal(_) | SideTab(_) | Home | Chat(_) | History(_, _, _) => reads_of([])
  }
}
