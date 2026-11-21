// A station's part in migrations (station/src/move/station.ts; move/AGENTS.md): the modules over this station's
// chats, accounts, jobs, connects, repositories, vaults and settings, the scheduler over them, the told steps, the
// chats' sizes, and what another station asks of them (`move.*`). In a turn, a station found gone is asked nothing
// more till it ends; a request whose connection the other's own process closed (`PeerStopped`) is asked again once.
// The hand-over of one chat is the station's (replica/handover.ts): given what it needs of this (`HandoverHooks`), it
// gives its port (`HandoverPort`).

///|
let gib : Double = 1024.0 * 1024.0 * 1024.0

///|
/// `${(n / 1024 ** 3).toFixed(1)} GB`.
pub fn gb(n : Double) -> String {
  let tenths = (n / gib * 10.0).round()
  let neg = tenths < 0.0
  let t = if neg { -tenths } else { tenths }
  let whole = (t / 10.0).floor()
  let frac = t - whole * 10.0
  "\{if neg && t != 0.0 { "-" } else { "" }}\{num_text(whole)}.\{num_text(frac)} GB"
}

///|
/// A station of a workspace's roster: its id, its name, whether it only runs tasks.
pub(all) struct RosterEntry {
  id : String
  name : String
  tasks : Bool
}

///|
/// What the station's moves read of its store (store/store.ts).
pub(all) struct MovesStore {
  /// Told each change's type ("session", "sessionRemoved", "moved", …) as the store tells it.
  subscribe : (((String) -> Unit) -> Unit)?
  handed_to : async (String) -> J?
  get_session : async (String) -> J?
  jobs_mark_of : async (Array[String]) -> Array[(String, String)]
  live_sessions_on : async (String, Int) -> Array[String]
  live_of : async (Array[String]) -> Array[String]
  jobs_up_of : async (Array[String]) -> Array[J]
  sessions_of_connect : async (String, Int, String) -> Array[String]
  session_page : async (Array[String]) -> Page
  /// A page of the chats handed from here (`{session, station, …}`), after `after`.
  handed_chats : async (String, Int) -> Array[J]
  /// By session, the connects bound to it.
  list_bindings : async () -> Array[(String, Array[String])]
}

///|
/// This station's connects (connects/workspace.ts).
pub(all) struct MovesConnects {
  kind_of : async (String) -> (String, String)?
  own_in : async (String) -> Array[OwnConnect]
  moved_away : (async (String) -> Array[OwnConnect])?
  runs_on : async (String) -> String?
  move : async (String, String, Array[String]) -> Unit
  arrived : (async (Array[String]) -> Unit)?
}

///|
/// The jobs (jobs.ts): those up (of sessions `keys`, or of `ws`'s chats, each with its `id`), one stopped, one started.
pub(all) struct MovesJobs {
  up : async (Array[String]?, String?) -> Array[J]
  stop : async (String, String) -> Unit
  start : async (J) -> Unit
  stop_named : async (String, String) -> Unit
}

///|
/// What the station's copies decide of paths and room (replica/restore.ts `moved`, `carriedTo`; replica/handover.ts
/// `floorOf`, `roomHere`; replica/carry.ts `sizesSoon`).
pub(all) struct Replica {
  moved : (String, String, String) -> String
  carried_to : (String, String, String, String?) -> String
  floor_of : (Double?) -> Double
  room_here : async () -> J
  sizes : async (Array[String], J) -> Array[Sized]
}

///|
/// The station's vault stores, the owners with secrets of a workspace here, the owners of the grants sessions hold.
pub(all) struct MovesVault {
  owners : async (String) -> Array[String]
  grant_owners : async (Array[String]) -> Map[String, Array[String]]
  stores : VaultStores
}

///|
/// What the station's moves give its hand-over of one chat (station.ts's `new Handover({...})`).
pub(all) struct HandoverHooks {
  jobs_of : async (Array[String]) -> Array[J]
  jobs_stop : async (Array[String], String) -> Unit
  jobs_start : async (J) -> Unit
  account_of : async (String) -> J?
  account_here : async (J) -> String?
  account_present : async (String) -> Bool
  arrived_stopped : async (Array[String], Waits, String) -> Unit
  shown : async (Array[String], String?) -> Unit
  went : async (Array[String]) -> Unit
  bindings_of : async (Array[String]) -> J
  /// Whether `peer` may hand chats of workspace `ws` here (the station's `answers`' own, and its roster).
  admits : (String, String) -> Bool
  ask : Ask
  told : Told
  hold : () -> (() -> Unit)
  changed : () -> Unit
}

///|
pub(all) struct MovesDeps {
  data : String
  here : () -> String?
  home : () -> String?
  roster : (String) -> Array[RosterEntry]?
  ask : Ask
  clock : Clock
  disk : Disk
  fs : Fs
  say : Say
  random : (Int) -> String
  store : MovesStore
  hub : ChatsHub
  handover : (HandoverHooks) -> HandoverPort
  connects : MovesConnects?
  jobs : MovesJobs
  profiles : async () -> Array[J]
  /// A profile's host moved to a station (share/index.ts `moveProfile`); None where no profile here is the one asked for
  /// by a move back, which the TypeScript asks all the same (its `accountHere` gives null, never undefined).
  move_profile : async (String?, String) -> J
  share_moves : ShareMoves?
  sessions_in : async (String, String, Int) -> Page
  repos_dir : String
  remove : (async (String) -> Unit)?
  room : (async () -> J)?
  git : (async (String, Array[String]) -> String)?
  changed : (() -> Unit)?
  config : Config?
  vault : MovesVault?
  move_on : (() -> Bool)?
  plan_page : Int?
  clones_elsewhere : (async () -> Array[String])?
  hold : () -> (() -> Unit)
  replica : Replica
}

///|
/// What a profile of config.json is known by across the workspace (handover.ts `AccountOf`): the share it is or is
/// a copy of; the key it runs with; one moved here keeps its id (`own`); this machine's login: None.
pub fn account_of(p : J?, station : String) -> J? {
  match p {
    None | Some(Null) => return None
    _ => ()
  }
  if is_true(get(p, "machine")) {
    return None
  }
  let id = match get(p, "id") {
    Some(Str(u)) => @jsjson.sanitize_str(u)
    Some(v) => js_string_of(v)
    None => "undefined"
  }
  let name = match text(get(p, "name")) {
    Some(n) if n != "" => n
    _ => id
  }
  match get(get(p, "share"), "id") {
    Some(Str(u)) if is_map(get(p, "share")) =>
      return Some(jo([("share", Str(u)), ("name", js(name))]))
    _ => ()
  }
  let env = get(p, "env")
  if text(get(get(p, "access"), "kind")) != Some("subscription") &&
    is_map(env) &&
    keys_of(env.unwrap()).length() > 0 {
    let ks = keys_of(env.unwrap())
    ks.sort_by(locale_compare)
    let sorted = jo(ks.map(k => (k, get(env, k).unwrap())))
    let runtime = match get(p, "runtime") {
      None | Some(Null) => js("")
      Some(r) => r
    }
    let hash = @memory.sha256_hex(@utf8.encode(stringify(ja([runtime, sorted])))[:])
    return Some(jo([("key", js(slice_to(hash, 32))), ("name", js(name))]))
  }
  Some(jo([("own", js("\{id}@\{station}")), ("name", js(name))]))
}

///|
/// `String(v)` of a value that is no string.
fn js_string_of(v : J) -> String {
  match v {
    Null => "null"
    Bool(b) => if b { "true" } else { "false" }
    Num(d) => num_text(d)
    Str(u) => @jsjson.sanitize_str(u)
    Arr(xs) => xs.map(x => if x is Null { "" } else { js_string_of(x) }).join(",")
    Obj(_) => "[object Object]"
  }
}

///|
/// `a.localeCompare(b)` as the station's ICU has it for the names of variables: by the root collation's order of
/// characters first, then lower before upper case.
pub fn locale_compare(a : String, b : String) -> Int {
  @jsjson.locale_compare(a, b)
}

///|
pub struct Moves {
  priv d : MovesDeps
  handover : HandoverPort
  jobs : Jobs
  scheduler : Scheduler
  modules : Array[Module]
  repos : Repos
  vault : Vault
  settings : Settings
  sizes : Sizes
  told : Told
  priv accounts : Accounts
  /// Whether a busy chat's turn is waited for as it moves (station_move `wait`, for the request under way).
  mut wait : Bool
  priv known : Map[String, J]
  priv gone : Map[String, MoveError]
  priv suspect : Set[String]
  priv sent_again : Set[String]
  priv drop_asked : Set[String]
  priv mut in_turn : Bool
  priv unused_owed : KeptSet
  priv unused_told : Set[String]
  priv mut looking_uses : Bool
  priv planning : Map[String, PlanReads]
  priv heard_from : Array[String]
  priv mut looking : Bool
  priv mut logins_looking : Bool
  priv mut logins_again : Bool
  priv mut in_workspace : (String) -> Bool
}

///|
fn Moves::station_name(self : Moves, ws : String, station : String) -> String {
  match (self.d.roster)(ws) {
    Some(r) =>
      match r.search_by(x => x.id == station) {
        Some(i) if r[i].name != "" => r[i].name
        _ => slice_to(station, 12)
      }
    None => slice_to(station, 12)
  }
}

///|
fn Moves::here(self : Moves) -> String {
  (self.d.here)().unwrap_or("")
}

///|
fn Moves::home(self : Moves) -> String {
  (self.d.home)().unwrap_or("")
}

///|
/// What this station's moves ask of another: in a turn, a station found gone is asked nothing more until it ends.
pub async fn Moves::ask(self : Moves, station : String, request : J, bytes : Bytes_?) -> J {
  self.asked(station, request, bytes, false)
}

///|
async fn Moves::asked(
  self : Moves,
  station : String,
  request : J,
  bytes : Bytes_?,
  again : Bool,
) -> J {
  if !self.in_turn {
    return (self.d.ask.ask)(station, request, bytes)
  }
  match self.gone.get(station) {
    Some(gone) => {
      let drop = text(get(Some(request), "method")) == Some("handover.drop") &&
        !self.drop_asked.contains(station)
      if !drop {
        raise gone
      }
      self.drop_asked.add(station)
    }
    None => ()
  }
  match (try Ok((self.d.ask.ask)(station, request, bytes)) catch { e => Err(e) }) {
    Ok(answer) => {
      self.suspect.remove(station)
      answer
    }
    Err(e) => {
      if is_refused(e) {
        self.suspect.remove(station)
        raise e
      }
      let method = text(get(Some(request), "method")).unwrap_or("")
      let name = self.station_name(self.home(), station)
      if e is PeerStopped(_) && !again {
        self.d.say.log(
          "info",
          "a request met the other station's process stopping or handing over: asked again once, dialed anew",
          jo([("station", js(slice_to(station, 12))), ("method", js(method))]),
        )
        if bytes is Some(_) {
          raise AskAgain(self.d.say.tr("station.move.noAnswer", [("station", name)]))
        }
        return self.asked(station, request, bytes, true)
      }
      let message = message_of(e)
      let timed_out = message.has_prefix("peer request timed out")
      let unanswered = e is (PeerGone(_) | PeerStopped(_)) ||
        message == "the other station answered nothing"
      if unanswered && !self.sent_again.contains(station) {
        self.sent_again.add(station)
        self.suspect.add(station)
        self.d.say.log(
          "info",
          "a request met the other station's connection gone: sent again once, dialed anew",
          jo([("station", js(slice_to(station, 12))), ("error", js(message))]),
        )
        if bytes is Some(_) {
          raise AskAgain(self.d.say.tr("station.move.noAnswer", [("station", name)]))
        }
        return self.asked(station, request, bytes, again)
      }
      if unanswered || timed_out || self.suspect.contains(station) {
        let gone = Gone(self.d.say.tr("station.move.gone", [("station", name)]))
        self.gone[station] = gone
        self.d.say.log(
          "warn",
          "a station found gone in a turn: asked nothing more of it till it ends",
          jo([("station", js(slice_to(station, 12))), ("error", js(message))]),
        )
        raise gone
      }
      raise e
    }
  }
}

///|
async fn write_json_file(disk : Disk, path : String, v : J) -> Unit {
  (disk.write)(path, stringify(v))
}

///|
pub fn Moves::new(d : MovesDeps) -> Moves raise MoveError {
  let known : Map[String, J] = {}
  match (d.disk.read)(@nodepath.join("/", [d.data, "move", "accounts-known.json"])) {
    Some(t) =>
      match (try Ok(parse(t)) catch { e => Err(e) }) {
        Ok(Obj(_) as o) =>
          for k in keys_of(o) {
            known[k] = get(Some(o), k).unwrap()
          }
        _ => ()
      }
    None => ()
  }
  // (the parts are made below, each given what asks through the station: a cell filled once it is made)
  let me : Ref[Moves?] = Ref(None)
  let moves = () => me.val.unwrap()
  let here = () => (d.here)().unwrap_or("")
  let ask_j = async fn(s : String, r : J) -> J { moves().ask(s, r, None) }
  let ask : Ask = { ask: async fn(s, r, b) { moves().ask(s, r, b) } }
  let told = Told::new({ clock: d.clock, ask, hold: Some(d.hold), say: d.say })
  let sizes = Sizes::new({
    data: d.data,
    disk: d.disk,
    measure: async fn(keys) {
      (d.replica.sizes)(keys, jo([("most", ji(size_most))]))
    },
    gone: Some(async fn(key) { (d.store.handed_to)(key) is Some(_) }),
    say: d.say,
    clock: d.clock,
  })
  let name_of = fn(station : String) -> String {
    match (d.roster)((d.home)().unwrap_or("")) {
      Some(r) =>
        match r.search_by(x => x.id == station) {
          Some(i) if r[i].name != "" => r[i].name
          _ => slice_to(station, 12)
        }
      None => slice_to(station, 12)
    }
  }
  let repos = Repos::new({
    data: d.data,
    repos_dir: d.repos_dir,
    workspaces: async fn(ws) {
      let out = []
      (moves().reads(ws).pages)(async fn(page) {
        for r in page.rows {
          out.push(text(get(Some(r), "workspace")).unwrap_or(""))
        }
      })
      out
    },
    git: match d.git {
      Some(g) => g
      None => async fn(_, _) { raise Failed("no git here") }
    },
    ask,
    here,
    after: Some(d.clock.after),
    name: Some(fn(station) {
      match (d.roster)((d.home)().unwrap_or("")) {
        Some(r) =>
          match r.search_by(x => x.id == station) {
            Some(i) => r[i].name
            None => slice_to(station, 12)
          }
        None => slice_to(station, 12)
      }
    }),
    told: Some(told),
    remove: d.remove,
    fs: d.fs,
    disk: d.disk,
    clock: d.clock,
    random: d.random,
    say: d.say,
  })
  let none_stores : VaultStores = {
    plain_items: async fn(_, _) { [] },
    plain_item: async fn(_, _) { None },
    plain_put: async fn(_) {  },
    plain_forget: async fn(_, _) {  },
    vaults: async fn(_) { [] },
    vault: async fn(_, _) { None },
    items: async fn(_, _) { [] },
    item: async fn(_, _, _) { None },
    put_vault: async fn(_) {  },
    put_item: async fn(_) {  },
    forget_item: async fn(_, _, _) {  },
    forget_vault: async fn(_, _) {  },
  }
  let v : MovesVault = match d.vault {
    Some(v) => v
    None =>
      {
        owners: async fn(_) { [] },
        grant_owners: async fn(_) { {} },
        stores: none_stores,
      }
  }
  let vault = Vault::new({
    data: d.data,
    owners: v.owners,
    stores: v.stores,
    ask: ask_j,
    disk: d.disk,
  })
  let settings = Settings::new({
    data: d.data,
    ask: ask_j,
    config: match d.config {
      Some(c) => c
      None => { raw: async fn() { jo([]) }, update_soon: async fn(_) {  } }
    },
    disk: d.disk,
    say: d.say,
  })
  let jobs = Jobs::new({
    data: d.data,
    disk: d.disk,
    up: d.jobs.up,
    stop: d.jobs.stop,
    start: d.jobs.start,
    ask: async fn(s, r) {
      moves().ask(s, set(r, "fromData", js(d.data)), None)
    },
    here,
    chat_of: async fn(session) { (moves().handover.chat_of)(session) },
    clock: d.clock,
    say: d.say,
  })
  let hooks : HandoverHooks = {
    jobs_of: async fn(keys) {
      (d.jobs.up)(Some(keys), None).map(j => del(j, "id"))
    },
    jobs_stop: async fn(keys, why) { ignore(jobs.keep(keys, why)) },
    jobs_start: async fn(job) {
      jobs.start_kept([text(get(Some(job), "session")).unwrap_or("")])
    },
    account_of: async fn(id) {
      let profiles = (d.profiles)()
      let p = match profiles.search_by(x => text(get(Some(x), "id")) == Some(id)) {
        Some(i) => profiles[i]
        None => return known.get(id)
      }
      let a = account_of(Some(p), here())
      match a {
        Some(a) =>
          if !same(known.get(id), Some(a)) {
            known[id] = a
            let all = jo(known.to_array().map(p => (p.0, p.1)))
            (d.clock.spawn)(async fn() {
              write_json_file(
                d.disk,
                @nodepath.join("/", [d.data, "move", "accounts-known.json"]),
                all,
              ) catch {
                _ => ()
              }
            })
          }
        None => ()
      }
      a
    },
    account_here: async fn(a) { moves().account_here(a) },
    account_present: async fn(id) {
      (d.profiles)().iter().any(p => text(get(Some(p), "id")) == Some(id))
    },
    arrived_stopped: async fn(keys, need, ws) {
      moves().scheduler.note_stopped({ module: "chats", id: keys[0] }, need, ws)
    },
    shown: async fn(keys, from) {
      match d.connects {
        Some({ arrived: Some(arrived), .. }) => arrived(keys)
        _ => ()
      }
      match moves().accounts.module.left {
        Some(left) =>
          left(keys.map(id => { module: "chats", id })) catch {
            e =>
              d.say.log(
                "warn",
                "what was lent for a chat back here not taken back",
                jo([("error", js(message_of(e)))]),
              )
          }
        None => ()
      }
      match from {
        Some(f) =>
          (moves().accounts.look_at)(f, None) catch {
            e =>
              d.say.log(
                "warn",
                "a login lent not looked at as a chat came",
                jo([("error", js(message_of(e)))]),
              )
          }
        None => ()
      }
    },
    went: async fn(keys) {
      moves().scheduler.forget(keys.map(id => { module: "chats", id }))
    },
    bindings_of: async fn(keys) {
      let mut out = jo([])
      for b in (d.store.list_bindings)() {
        if keys.contains(b.0) {
          for c in b.1 {
            out = set(out, c, js(b.0))
          }
        }
      }
      out
    },
    admits: fn(peer, ws) {
      (moves().in_workspace)(peer) &&
      (match (d.roster)(ws) {
        Some(r) => r.iter().any(s => s.id == peer)
        None => true
      })
    },
    ask,
    told,
    hold: d.hold,
    changed: () => match d.changed {
      Some(f) => f()
      None => ()
    },
  }
  let handover = (d.handover)(hooks)
  let accounts = accounts_module({
    used: async fn(ws) {
      let out : Array[(String, J?)] = []
      let pages = match moves().planning.get(ws) {
        Some(r) if (r.loaded)().length() > 0 => (r.loaded)()
        _ => moves().pages_now(ws)
      }
      for page in pages {
        for k in page.keys {
          for a in (handover.accounts_of)([k], Some(page)) {
            match out.search_by(x => x.0 == a.0) {
              Some(i) => out[i] = a
              None => out.push(a)
            }
          }
        }
      }
      // Include own, non-machine, non-borrowed non-runtime profiles (e.g. service accounts) allowed in ws.
      let home = moves().home()
      for p in (d.profiles)() {
        if is_true(get(Some(p), "machine")) {
          continue
        }
        if is_map(get(Some(p), "share")) &&
          is_true(get(get(Some(p), "share"), "borrowed")) {
          continue
        }
        match get(Some(p), "runtimes") {
          Some(Arr(rs)) if rs.length() == 0 => ()
          _ => continue
        }
        let withheld = match get(Some(p), "withheld") {
          Some(Arr(ws_list)) => ws_list.iter().any(w => text(Some(w)) == Some(ws))
          _ => false
        }
        if ws != home && withheld {
          continue
        }
        guard text(get(Some(p), "id")) is Some(pid) else { continue }
        if out.search_by(x => x.0 == pid) is None {
          out.push((pid, account_of(Some(p), here())))
        }
      }
      out
    },
    shared: async fn(id) {
      let profiles = (d.profiles)()
      match profiles.search_by(x => text(get(Some(x), "id")) == Some(id)) {
        Some(i) => is_map(get(Some(profiles[i]), "share"))
        None => false
      }
    },
    move_profile: async fn(id, to) { (d.move_profile)(Some(id), to) },
    present: Some(async fn(id) {
      let own = if id.has_prefix("own:") {
        Some(slice(id, 4, last_index_of(id, "@")))
      } else {
        None
      }
      for p in (d.profiles)() {
        match text(get(Some(p), "id")) {
          Some(pid) =>
            if Some(pid) == own || account_item_id(pid, account_of(Some(p), here())) == id {
              return Some(pid)
            }
          None => ()
        }
      }
      None
    }),
    ask: ask_j,
    here,
    data: Some(d.data),
    profile: Some(async fn(id) {
      let profiles = (d.profiles)()
      match profiles.search_by(x => text(get(Some(x), "id")) == Some(id)) {
        Some(i) => Some(profiles[i])
        None => None
      }
    }),
    share_moves: d.share_moves.map(s => {
      ..s,
      uses_there: Some(async fn(to, share) {
        let answer = moves().ask(
          to,
          jo([("method", js("move.uses")), ("share", js(share))]),
          None,
        )
        match num(get(Some(answer), "uses")) {
          Some(n) => Some(n.to_int())
          None => None
        }
      }),
      handed_on: Some(async fn(to, pid) { moves().handed_on(to, pid) }),
    }),
    disk: d.disk,
    clock: d.clock,
    say: d.say,
  })
  let chats = chats_module({
    store: {
      handed_to: d.store.handed_to,
      jobs_mark_of: d.store.jobs_mark_of,
      get_session: d.store.get_session,
    },
    handover,
    hub: d.hub,
    name: Some(name_of),
    keep_jobs: async fn(keys, why) { ignore(jobs.keep(keys, why)) },
    start_kept: async fn(keys) { jobs.start_kept(keys) },
    ask: ask_j,
    told: Some(told),
    here,
    kind_of: async fn(id) {
      match d.connects {
        Some(c) => (c.kind_of)(id)
        None => None
      }
    },
    vaults_of: async fn(keys, ws) {
      let out : Map[String, Array[String]] = {}
      for k, owners in (v.grant_owners)(keys) {
        out[k] = owners.map(o => "\{vault_item_id(o)}@\{ws}")
      }
      out
    },
    wait: Some(() => moves().wait),
    reads: ws => moves().reads(ws),
    sizes: Some(sizes),
    random: d.random,
    say: d.say,
  })
  let connects = connects_module({
    own: async fn(ws) {
      match d.connects {
        Some(c) => {
          let out = (c.own_in)(ws)
          match c.moved_away {
            Some(m) => out.push_iter(m(ws).iter())
            None => ()
          }
          out
        }
        None => []
      }
    },
    chats_of: async fn(id) { moves().chats_of_connect(id) },
    runs_on: async fn(id) {
      match d.connects {
        Some(c) => (c.runs_on)(id)
        None => None
      }
    },
    kind_of: Some(async fn(id) {
      match d.connects {
        Some(c) => (c.kind_of)(id)
        None => None
      }
    }),
    keys_of: Some(async fn(id) {
      let out = []
      for k in moves().of_connect(id, None) {
        if (d.store.handed_to)(k) is None {
          out.push(k)
        }
      }
      out
    }),
    move: async fn(id, to, awaiting) {
      match d.connects {
        Some(c) => (c.move)(id, to, awaiting)
        None => raise Failed("the connects are not up yet")
      }
    },
    ask: ask_j,
    here,
  })
  let modules = [
    accounts.module,
    chats,
    jobs.module(),
    connects,
    repos.module(),
    vault.module(),
    settings.module(),
  ]
  let scheduler = Scheduler::new({
    data: d.data,
    disk: d.disk,
    clock: d.clock,
    say: d.say,
    modules,
    changed: Some(() => match d.changed {
      Some(f) => f()
      None => ()
    }),
    progress: Some((_, _) => match d.changed {
      Some(f) => f()
      None => ()
    }),
    tell_arrived: Some(async fn(to, item) {
      ignore(
        moves().ask(
          to,
          jo([("method", js("move.arrived")), ("item", item.to_j())]),
          None,
        ),
      )
    }),
    now: Some(() => (d.clock.now)().to_double()),
    refusal: Some(async fn(ws, station) { moves().refusal(ws, station) }),
    room_for_all: Some(async fn(ws, station, plan) {
      moves().room_for_all(ws, station, plan)
    }),
    hold: Some(d.hold),
    restarted: Some(() => d.say.tr("station.move.restarted", [])),
    reads: Some(ws => {
      let r = moves().reads(ws)
      moves().planning[ws] = r
      r
    }),
    turn: Some((on, _) => {
      let m = moves()
      m.drop_asked.clear()
      m.in_turn = on
      m.sizes.set_quiet(on)
      m.gone.clear()
      m.suspect.clear()
      m.sent_again.clear()
    }),
  })
  let m : Moves = {
    d,
    handover,
    jobs,
    scheduler,
    modules,
    repos,
    vault,
    settings,
    sizes,
    told,
    accounts,
    wait: true,
    known,
    gone: {},
    suspect: Set::new(),
    sent_again: Set::new(),
    drop_asked: Set::new(),
    in_turn: false,
    unused_owed: KeptSet::new(d.disk, @nodepath.join("/", [d.data, "move", "unused-owed.json"])),
    unused_told: Set::new(),
    looking_uses: false,
    planning: {},
    heard_from: [],
    looking: false,
    logins_looking: false,
    logins_again: false,
    in_workspace: _ => true,
  }
  me.val = Some(m)
  // (a borrowed login's last use here may end with any change of a session: looked at as one changes)
  match d.store.subscribe {
    Some(sub) =>
      sub(kind => if kind == "session" || kind == "sessionRemoved" || kind == "moved" {
        m.uses_may_end()
      })
    None => ()
  }
  m
}

///|
/// A session changed here: the borrowed logins looked at, once a turn of the loop.
fn Moves::uses_may_end(self : Moves) -> Unit {
  if self.looking_uses {
    return
  }
  self.looking_uses = true
  (self.d.clock.spawn)(async fn() {
    @effect.pause()
    self.looking_uses = false
    for p in (self.d.profiles)() {
      let s = get(Some(p), "share")
      let (share, host, pid) = match (text(get(s, "id")), text(get(s, "host")), text(get(Some(p), "id"))) {
        (Some(a), Some(b), Some(c)) if is_true(get(s, "borrowed")) => (a, b, c)
        _ => continue
      }
      let key = "\{share}\n\{host}"
      if (self.d.store.live_sessions_on)(pid, 1).length() > 0 {
        self.unused_told.remove(key)
        if self.unused_owed.has(key) {
          let owed = self.unused_owed
          (self.d.clock.spawn)(async fn() { owed.delete(key) catch { _ => () } })
        }
        continue
      }
      if self.unused_told.contains(key) || self.unused_owed.has(key) {
        continue
      }
      let owed = self.unused_owed
      (self.d.clock.spawn)(async fn() {
        owed.add(key) catch {
          _ => return
        }
        self.tell_unused(host)
      })
    }
  })
}

///|
/// What is owed to `host` of the borrowed logins' last uses told.
fn Moves::tell_unused(self : Moves, host : String) -> Unit {
  for key in self.unused_owed.values() {
    let nl = index_of(key, "\n")
    let share = slice(key, 0, nl)
    let to = slice_from(key, nl + 1)
    if to != host {
      continue
    }
    (self.d.clock.spawn)(async fn() {
      match
        (try Ok(
          self.ask(host, jo([("method", js("move.unused")), ("share", js(share))]), None),
        ) catch { e => Err(e) }) {
        Ok(_) => {
          self.unused_told.add(key)
          self.unused_owed.delete(key) catch {
            _ => ()
          }
        }
        Err(_) => ()
      }
    })
  }
}

///|
/// What one plan of `ws` reads once for its modules (module.ts `PlanReads`).
pub fn Moves::reads(self : Moves, ws : String) -> PlanReads {
  let size = self.d.plan_page.unwrap_or(plan_page)
  let pages : Array[Page] = []
  let done = Ref(false)
  let clones : Ref[Map[String, Array[(String, String)]]?] = Ref(None)
  let d = self.d
  let iterate = async fn(each : async (Page) -> Unit) -> Unit {
    let mut i = 0
    while true {
      if i > 0 {
        @effect.pause()
      }
      if i >= pages.length() {
        if done.val {
          return
        }
        let after = match pages.last() {
          Some(p) => p.keys.last().unwrap_or("")
          None => ""
        }
        let page = (d.sessions_in)(ws, after, size)
        pages.push(page)
        if page.keys.length() < size {
          done.val = true
        }
      }
      each(pages[i])
      i += 1
    }
  }
  {
    pages: iterate,
    load: async fn() { iterate(async fn(_) {  }) },
    loaded: () => pages,
    worktrees: async fn(dir) {
      let map = match clones.val {
        Some(m) => m
        None => {
          let elsewhere = match d.clones_elsewhere {
            Some(f) => f()
            None => []
          }
          let m = worktrees_of_clones(d.fs, d.repos_dir, elsewhere, d.data)
          clones.val = Some(m)
          m
        }
      }
      map.get(dir).unwrap_or([])
    },
  }
}

///|
/// Every page of `ws`'s chats at once, for what plans outside a plan's reads.
async fn Moves::pages_now(self : Moves, ws : String) -> Array[Page] {
  let size = self.d.plan_page.unwrap_or(plan_page)
  let out = []
  let mut after = ""
  while true {
    let page = (self.d.sessions_in)(ws, after, size)
    out.push(page)
    if page.keys.length() < size {
      return out
    }
    after = page.keys.last().unwrap()
  }
  out
}

///|
/// The sessions that came through connect `id`, every one, a page at a time.
async fn Moves::of_connect(
  self : Moves,
  id : String,
  each : (async (Array[String]) -> Unit)?,
) -> Array[String] {
  let out = []
  let mut after = ""
  while true {
    let keys = (self.d.store.sessions_of_connect)(id, plan_page, after)
    out.push_iter(keys.iter())
    match each {
      Some(f) => f(keys)
      None => ()
    }
    if keys.length() < plan_page {
      return out
    }
    after = keys.last().unwrap()
    @effect.pause()
  }
  out
}

///|
async fn Moves::chats_of_connect(self : Moves, id : String) -> Array[String] {
  let out = []
  ignore(
    self.of_connect(
      id,
      Some(async fn(keys) {
        let reads = (self.d.store.session_page)(keys)
        for r in keys {
          let k = match (self.handover.together)(r, Some(reads)).get(0) {
            Some(k) => k
            None => r
          }
          if !out.contains(k) {
            out.push(k)
          }
        }
      }),
    ),
  )
  out
}

///|
/// The profile here of an account known so (handover.ts `AccountOf`; None: none).
pub async fn Moves::account_here(self : Moves, a : J) -> String? {
  for p in (self.d.profiles)() {
    let pid = match text(get(Some(p), "id")) {
      Some(id) => id
      None => continue
    }
    if is_true(get(Some(p), "machine")) {
      continue
    }
    let it = match account_of(Some(p), self.here()) {
      Some(it) => it
      None => continue
    }
    match text(get(Some(a), "share")) {
      Some(s) => if text(get(Some(it), "share")) == Some(s) || pid == s { return Some(pid) }
      None => ()
    }
    match text(get(Some(a), "key")) {
      Some(k) => if text(get(Some(it), "key")) == Some(k) { return Some(pid) }
      None => ()
    }
    match text(get(Some(a), "own")) {
      Some(o) => {
        let first = match o.find("@") {
          Some(i) => slice(o, 0, i)
          None => o
        }
        if first == pid {
          return Some(pid)
        }
      }
      None => ()
    }
  }
  None
}

///|
/// Whether a busy chat's turn is waited for as it moves (station_move `wait`).
pub fn Moves::set_wait(self : Moves, wait : Bool) -> Unit {
  self.wait = wait
}

///|
pub async fn Moves::start(self : Moves) -> Unit {
  (self.handover.start)()
  self.scheduler.start()
}

///|
pub async fn Moves::close(self : Moves) -> Unit {
  self.told.close()
  (self.handover.close)()
}

///|
/// Share `share` hosted here again, from `from`: what a trip of this station's shared for it undone.
pub async fn Moves::share_came_home(self : Moves, share : String, from : String) -> Unit {
  (self.accounts.came_home)(share, from)
}

///|
/// Whether moving is switched on here.
pub fn Moves::on(self : Moves) -> Bool {
  match self.d.move_on {
    Some(f) => f()
    None => true
  }
}

///|
/// The chats handed from here to station `to` whose login is profile `pid`.
async fn Moves::handed_on(self : Moves, to : String, pid : String) -> Array[String] {
  let out = []
  let mut page = (self.d.store.handed_chats)("", 500)
  while page.length() > 0 {
    for h in page {
      let session = text(get(Some(h), "session")).unwrap_or("")
      if text(get(Some(h), "station")) == Some(to) &&
        text(get((self.d.store.get_session)(session), "profile")) == Some(pid) {
        out.push(session)
      }
    }
    let after = text(get(page.last(), "session")).unwrap_or("")
    page = (self.d.store.handed_chats)(after, 500)
  }
  out
}

///|
/// What station `to` says of its disk (`move.open`): None where it says none or does not answer.
pub async fn Moves::room_there(self : Moves, ws : String, to : String) -> (Double, Double?)? {
  let open = self.ask(
    to,
    jo([("method", js("move.open")), ("workspace", js(ws))]),
    None,
  ) catch {
    _ => return None
  }
  match num(get(Some(open), "free")) {
    Some(free) => Some((free, num(get(Some(open), "total"))))
    None => None
  }
}

///|
/// What moving all of chats `ids` would add to station `to`'s disk (None: it cannot be known).
pub async fn Moves::adds_there(
  self : Moves,
  ws : String,
  to : String,
  ids : Array[String],
) -> (Double, Int)? {
  self.sizes.settled()
  let mut adds = 0.0
  let mut chats = 0
  let mut i = 0
  while i < ids.length() {
    let end = if i + sizes_batch > ids.length() { ids.length() } else { i + sizes_batch }
    let places = []
    for id in ids[i:end] {
      places.push_iter(self.sizes.places_of(id).iter())
    }
    i += sizes_batch
    if places.length() == 0 {
      continue
    }
    let answer = self.ask(
      to,
      jo([
        ("method", js("move.sizes")),
        ("workspace", js(ws)),
        ("places", ja(places)),
        ("fromData", js(self.d.data)),
      ]),
      None,
    ) catch {
      e => {
        self.d.say.log(
          "warn",
          "what the other station has of the chats' rooms not known: no whole move refused by their sum",
          jo([("station", js(slice_to(to, 12))), ("error", js(message_of(e)))]),
        )
        return None
      }
    }
    let there : Map[String, Double] = {}
    for x in arr(get(Some(answer), "sized")).unwrap_or([]) {
      match (text(get(Some(x), "key")), num(get(Some(x), "bytes"))) {
        (Some(k), Some(b)) => there[k] = b
        _ => ()
      }
    }
    for p in places {
      let key = text(get(Some(p), "key")).unwrap_or("")
      let here = num(get(self.sizes.line(key), "bytes")).unwrap_or(0.0)
      let d = here - there.get(key).unwrap_or(here)
      adds += if d > 0.0 { d } else { 0.0 }
      chats += 1
    }
  }
  Some((adds, chats))
}

///|
/// Why moving all of `plan` to `to` does not fit there (None: it fits, or it cannot be known).
pub async fn Moves::room_for_all(self : Moves, ws : String, to : String, plan : J) -> String? {
  let ids = arr(get(Some(plan), "items"))
    .unwrap_or([])
    .filter(x => item_module(x) == "chats" &&
      state_name(x) != "there" &&
      item_cannot(x) is None)
    .map(item_id)
  if ids.length() == 0 {
    return None
  }
  let (free, total) = match self.room_there(ws, to) {
    Some(t) => t
    None => return None
  }
  let (adds, chats) = match self.adds_there(ws, to, ids) {
    Some(s) => s
    None => return None
  }
  let need = adds + (adds / 20.0).ceil()
  let floor = (self.d.replica.floor_of)(total)
  let left = free - need
  self.d.say.log(
    "info",
    "a whole move's room there",
    jo([
      ("station", js(slice_to(to, 12))),
      ("chats", ji(chats)),
      ("adds", jn(adds)),
      ("free", jn(free)),
      ("floor", jn(floor)),
    ]),
  )
  if left >= floor {
    return None
  }
  let name = self.station_name(ws, to)
  Some(
    self.d.say.tr("station.move.why.allNoRoom", [
      ("station", name),
      ("free", gb(free)),
      ("adds", gb(need)),
      ("floor", gb(floor)),
      ("short", gb(floor - left)),
      ("n", ids.length().to_string()),
    ]),
  )
}

///|
/// What a move to `to` would send of chats `ids` here and what is free there (the tool's summary).
pub async fn Moves::room(self : Moves, ws : String, to : String, ids : Array[String]) -> J {
  let sum = self.sizes.sum(ids)
  let there = if to == "" { None } else { self.room_there(ws, to) }
  let pairs = [
    ("sends", js("\{if sum.at_least { "at least " } else { "" }}\{gb(sum.bytes)}")),
    ("sendsBytes", jn(sum.bytes)),
    ("known", ji(sum.known)),
    ("of", ji(sum.of)),
    ("measuring", ji(sum.measuring)),
  ]
  match there {
    Some((free, total)) => {
      pairs.push(("freeThere", js(gb(free))))
      pairs.push(("floorThere", js(gb((self.d.replica.floor_of)(total)))))
    }
    None => ()
  }
  jo(pairs)
}

///|
/// Why a move or a move back with `station` of `ws` cannot begin now (None: it can), in `lang` (None: the station's).
pub async fn Moves::refusal(
  self : Moves,
  ws : String,
  station : String,
  lang? : String,
) -> String? {
  let tr = fn(key : String, args : Array[(String, String)]) -> String {
    match lang {
      Some(l) => self.d.say.tr_in(l, key, args)
      None => self.d.say.tr(key, args)
    }
  }
  if !self.on() {
    return Some(tr("station.move.off", []))
  }
  match (try Ok((self.handover.loaded_within)()) catch { e => Err(e) }) {
    Ok(_) => ()
    Err(Refused(m)) => return Some(m)
    Err(e) => raise e
  }
  let name = self.station_name(ws, station)
  let request = jo([("method", js("move.open")), ("workspace", js(ws))])
  let open = match (try Ok((self.d.ask.ask)(station, request, None)) catch { e => Err(e) }) {
    Ok(o) => Some(o)
    Err(PeerGone(_) | PeerStopped(_)) =>
      match (try Ok((self.d.ask.ask)(station, request, None)) catch { e => Err(e) }) {
        Ok(o) => Some(o)
        Err(Refused(_)) => None
        Err(_) => return Some(tr("station.move.unreachable", [("station", name)]))
      }
    Err(Refused(_)) => None
    Err(_) => return Some(tr("station.move.unreachable", [("station", name)]))
  }
  if is_true(get(open, "on")) {
    return None
  }
  Some(tr("station.move.offThere", [("station", name)]))
}

///|
/// What another station asks of this one's migrations (`handover.*` and `move.*`), each answered once the station
/// process before this one is gone, holding the station's self-update while it is.
pub fn Moves::answers(
  self : Moves,
  in_workspace : (String) -> Bool,
) -> async (String, J, String?, Bytes_?) -> J {
  self.in_workspace = in_workspace
  async fn(peer, request, workspace, bytes) {
    (self.handover.loaded_within)()
    let let_go = (self.d.hold)()
    defer let_go()
    self.answer(peer, request, workspace, bytes)
  }
}

///|
/// A station heard from: what is stopped here for what may have come from it meanwhile is looked at.
pub fn Moves::heard(self : Moves, peer : String) -> Unit {
  self.told.reached(peer)
  if self.unused_owed.size() > 0 {
    self.tell_unused(peer)
  }
  if !self.scheduler.has_stopped(at=peer) {
    return
  }
  if !self.heard_from.contains(peer) {
    self.heard_from.push(peer)
  }
  if self.looking {
    return
  }
  self.looking = true
  (self.d.clock.spawn)(async fn() {
    while self.heard_from.length() > 0 {
      let next = self.heard_from.remove(0)
      ignore(try Ok(self.scheduler.settle_stopped(from=next)) catch { e => Err(e) })
    }
    self.looking = false
  })
}

///|
/// This station's logins changed: what is stopped here for a login is looked at again.
pub fn Moves::logins_changed(self : Moves) -> Unit {
  if !self.scheduler.waits_on("accounts") {
    return
  }
  self.logins_again = true
  if self.logins_looking {
    return
  }
  self.logins_looking = true
  (self.d.clock.spawn)(async fn() {
    while self.logins_again {
      self.logins_again = false
      ignore(try Ok(self.scheduler.settle_stopped(module="accounts")) catch { e => Err(e) })
    }
    self.logins_looking = false
  })
}

///|
fn ok_j() -> J {
  jo([("ok", jb(true))])
}

///|
async fn Moves::answer(
  self : Moves,
  peer : String,
  request : J,
  workspace : String?,
  bytes : Bytes_?,
) -> J {
  let method = text(get(Some(request), "method")).unwrap_or("")
  let ws = workspace.unwrap_or("")
  if method == "handover.begin" && !self.on() {
    raise Refused(
      self.d.say.tr("station.move.offThere", [("station", self.station_name(ws, self.here()))]),
    )
  }
  if method.has_prefix("handover.") {
    return (self.handover.answer)(peer, request, workspace, bytes)
  }
  if !(self.in_workspace)(peer) {
    raise Refused("not a station of this workspace")
  }
  if method.has_prefix("move.repo.") {
    return self.repos.answer(peer, request, bytes)
  }
  if method.has_prefix("move.setting.") {
    return self.settings.answer(peer, request)
  }
  if method.has_prefix("move.vault.") {
    return self.vault.answer(request)
  }
  match method {
    "move.told" => self.told.heard(peer, request)
    "move.open" => {
      let room = match self.d.room {
        Some(r) => r
        None => self.d.replica.room_here
      }
      let got = room() catch {
        _ => jo([])
      }
      spread(jo([("on", jb(self.on()))]), got)
    }
    "move.unused" => {
      let share = match text(get(Some(request), "share")) {
        Some(s) => s
        None => raise Refused("move.unused: which share")
      }
      (self.accounts.look_at)(peer, Some((share, 0)))
      ok_j()
    }
    "move.uses" => {
      let share = text(get(Some(request), "share")).unwrap_or("")
      let mut uses = 0
      for p in (self.d.profiles)() {
        if text(get(get(Some(p), "share"), "id")) == Some(share) {
          match text(get(Some(p), "id")) {
            Some(pid) => uses += (self.d.store.live_sessions_on)(pid, 1).length()
            None => ()
          }
        }
      }
      jo([("uses", ji(uses))])
    }
    "move.sizes" => {
      let from = text(get(Some(request), "fromData")).unwrap_or("")
      let asked = arr(get(Some(request), "places")).unwrap_or([])
      if from == "" || asked.length() > sizes_batch {
        raise Refused("move.sizes: at most a batch of places, and where they are there")
      }
      let places = []
      for p in asked {
        let key = match text(get(Some(p), "key")) {
          Some(k) => k
          None => continue
        }
        let room = match text(get(Some(p), "room")) {
          Some(r) => Some((self.d.replica.moved)(r, from, self.d.data))
          None => None
        }
        let ts = arr(get(Some(p), "transcripts")).unwrap_or([])
        let ts = if ts.length() > sized_transcripts {
          ts[0:sized_transcripts].to_array()
        } else {
          ts
        }
        let transcripts = ts
          .filter_map(t => text(Some(t)))
          .map(t => (self.d.replica.carried_to)(t, from, self.d.data, room))
        places.push(
          jo([
            ("key", js(key)),
            (
              "room",
              match room {
                Some(r) => js(r)
                None => Null
              },
            ),
            ("transcripts", jstrs(transcripts)),
          ]),
        )
      }
      let sized = (self.d.replica.sizes)(
        [],
        jo([("most", ji(size_most)), ("places", ja(places))]),
      )
      jo([
        (
          "sized",
          ja(
            sized.map(x => jo([
              ("key", js(x.key)),
              ("bytes", jn(x.bytes)),
              ("complete", jb(x.complete)),
            ])),
          ),
        ),
      ])
    }
    "move.accounts" => {
      let mut out = jo([])
      let mut hosts = jo([])
      let accounts = get(Some(request), "accounts").unwrap_or(jo([]))
      for id in keys_of(accounts) {
        let a = get(Some(accounts), id).unwrap()
        let pid = self.account_here(a)
        out = set(out, id, match pid {
          Some(p) => js(p)
          None => Null
        })
        match pid {
          Some(p) => {
            let profiles = (self.d.profiles)()
            let borrowed = match profiles.search_by(x => text(get(Some(x), "id")) == Some(p)) {
              Some(i) => is_true(get(get(Some(profiles[i]), "share"), "borrowed"))
              None => false
            }
            hosts = set(hosts, id, jb(!borrowed))
          }
          None => ()
        }
      }
      jo([("here", out), ("hosts", hosts)])
    }
    "move.back" => {
      if text(get(Some(request), "to")) != Some(peer) {
        raise Refused("an item goes back only to the station asking")
      }
      if !self.on() {
        raise Refused(
          self.d.say.tr("station.move.offThere", [("station", self.station_name(ws, self.here()))]),
        )
      }
      let id = key_text(get(Some(request), "id"))
      match text(get(Some(request), "module")) {
        Some("chats") => {
          let sf = get(Some(request), "stoppedFor")
          let stopped_for = match (text(get(sf, "module")), text(get(sf, "id"))) {
            (Some(m), Some(i)) => Some({ module: m, id: i, label: text(get(sf, "label")), at: None })
            _ => None
          }
          let back = async fn() -> J? {
            match (self.handover.out_of)(id) {
              Some(o) if text(get(Some(o), "to")) == Some(peer) &&
                !is_true(get(Some(o), "ended")) &&
                (text(get(Some(o), "step")) == Some("gone") || text(get(Some(o), "step")) == Some("done")) =>
                return Some(ok_j())
              _ => ()
            }
            ignore((self.handover.hand_over)(id, peer, true, None, stopped_for))
            Some(ok_j())
          }
          match text(get(Some(request), "told")) {
            Some(t) if t.length() <= 300 => self.told.run(peer, t, _ => back())
            _ => back().unwrap_or(ok_j())
          }
        }
        Some("accounts") => {
          let profiles = (self.d.profiles)()
          let mut pid : String? = None
          for p in profiles {
            match text(get(Some(p), "id")) {
              Some(i) =>
                if account_item_id(i, account_of(Some(p), self.here())) == id {
                  pid = Some(i)
                  break
                }
              None => ()
            }
          }
          if pid is None {
            pid = self.account_here(
              if id.has_prefix("own:") {
                jo([("own", js(slice_from(id, 4))), ("name", js(id))])
              } else {
                jo([("name", js(id))])
              },
            )
          }
          // (none found is no refusal: the TypeScript's `accountHere` says null, which its `undefined` check lets by)
          let p = match pid {
            Some(pid) =>
              match profiles.search_by(x => text(get(Some(x), "id")) == Some(pid)) {
                Some(i) => Some(profiles[i])
                None => None
              }
            None => None
          }
          if is_true(get(get(p, "share"), "borrowed")) {
            let host = key_text(get(get(p, "share"), "host"))
            let name = self.station_name(ws, host)
            raise Refused(
              "account \{id} is not on this station to move back: this station only borrows it, its login is on \{name}\{if host == peer { " (the station asking)" } else { "" }}",
            )
          }
          let moved = (self.d.move_profile)(pid, peer)
          spread(ok_j(), if moved is Obj(_) { moved } else { jo([]) })
        }
        Some("connects") => {
          let here = self.here()
          let local = if id.has_suffix("@\{here}") {
            slice(id, 0, id.length() - here.length() - 1)
          } else {
            id
          }
          match self.d.connects {
            Some(c) => (c.move)(local, peer, [])
            None => raise Refused("the connects are not up yet")
          }
          ok_j()
        }
        m =>
          raise Refused(
            "module \{match m { Some(x) => x; None => match get(Some(request), "module") { Some(v) => js_string_of(v); None => "undefined" } }} moves nothing back this way",
          )
      }
    }
    "move.job.start" => {
      let j = get(Some(request), "job").unwrap_or(Null)
      let (session, name, command) = match (text(get(Some(j), "session")), text(get(Some(j), "name")), text(get(Some(j), "command"))) {
        (Some(s), Some(n), Some(c)) => (s, n, c)
        _ => raise Refused("not a job")
      }
      let row = match (self.d.store.get_session)(session) {
        Some(r) => r
        None => raise Refused("its chat is not here")
      }
      let cwd = match text(get(Some(j), "cwd")) {
        Some(c) => js((self.d.replica.moved)(c, key_text(get(Some(request), "fromData")), self.d.data))
        None => get(Some(row), "workspace").unwrap_or(Null)
      }
      if (self.d.store.jobs_up_of)([session]).iter().any(x => text(get(Some(x), "name")) == Some(name) &&
          text(get(Some(x), "command")) == Some(command)) {
        return ok_j()
      }
      (self.d.jobs.start)(set(j, "cwd", cwd))
      ok_j()
    }
    "move.arrived" => {
      let item = get(Some(request), "item")
      let n = match (text(get(item, "module")), text(get(item, "id"))) {
        (Some(m), Some(i)) => { module: m, id: i }
        _ => raise Refused("no item named")
      }
      let resumed = self.scheduler.arrived(n)
      jo([("ok", jb(true)), ("resumed", ja(resumed.map(x => x.to_j())))])
    }
    "move.chats.live" => {
      let keys = arr(get(Some(request), "keys")).unwrap_or([]).filter_map(k => text(Some(k)))
      let keys = if keys.length() > plan_page * 4 {
        keys[0:plan_page * 4].to_array()
      } else {
        keys
      }
      let live = (self.d.store.live_of)(keys)
      let name = match (self.d.roster)(ws) {
        Some(r) =>
          match r.search_by(x => x.id == self.here()) {
            Some(i) => r[i].name
            None => ""
          }
        None => ""
      }
      jo([("live", jstrs(live)), ("name", js(name))])
    }
    "move.job.stop" => {
      (self.d.jobs.stop_named)(
        key_text(get(Some(request), "session")),
        key_text(get(Some(request), "name")),
      )
      ok_j()
    }
    _ => raise Refused("no such move request")
  }
}

///|
/// The most transcripts a session's places name (replica/carry.ts `SIZED_TRANSCRIPTS`).
pub let sized_transcripts : Int = 64
