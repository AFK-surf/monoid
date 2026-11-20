// The Comma connects as a part of the agents' side (station/src/comma/module.ts): the workspace's statistics and Task
// index its connections send Comma (stats.mbt), the chats of that index as the Router reads and writes in them
// (`task.read`, `task.say`), and what this station answers another's read of them, or write (peer.mbt). What the
// station gives it (its cloud's state, its readers, the mesh's bus, the store, the hub) is `LiveDeps`; the routes a
// Comma connect's pages use and the overview's entry are the station's API's (api/routes/comma.ts).

///|
/// What the Comma part is given of the station.
pub(all) struct LiveDeps {
  data : String
  /// The cloud's state: the home workspace, those the station is in (their ids), one's membership (`{workspace,
  /// workspace_name, name}`, Null where the station is not in it), the station's own id, and its changes told.
  home : () -> String?
  memberships : () -> Array[String]
  membership : (String) -> J
  station : () -> String
  cloud_listen : (() -> Unit) -> () -> Unit
  /// Where this station's pages are (sessions/page.ts): the station's own, never what the asker says.
  pages : () -> J
  /// The readers' read: `readers.read(op, args, lang, { background })`.
  read : async (String, J, String, Bool) -> String
  /// The mesh's bus: another station asked (`bus.ask(station, request)`), and a read's answer as text.
  ask : async (String, J) -> J
  ask_text : async (String, J) -> String
  /// mesh/peer.ts `member(cloud, peer, workspace)`: raises where the peer is not of the workspace now.
  member : (String, String) -> Unit raise
  /// The store's changes, by their type.
  subscribe : ((String) -> Unit) -> () -> Unit
  hub : RouterHub
  previous_exited : async () -> Unit
}

///|
pub struct CommaLive {
  priv deps : LiveDeps
  priv io : Io
  priv runtime : @effect.Runtime
  priv mut indexed : String
  priv mut scope_version_ : Int
  priv stops : Array[() -> Unit]
  /// Kept for the Router's deduplication across a downgrade; its unscoped indexes are not sent.
  legacy : CommaStats
  /// What a connect of no workspace the station is in sends: an empty epoch, so Comma also removes rows an older
  /// station already sent to it.
  empty : CommaIndexes
  priv empty_db : @sql.Db
  priv said : async (String?, RouterSay) -> Double
  priv scopes : Map[String, (CommaStats, CommaIndexes, CommaChats)]
  priv mut owner_active_at_ : Double?
  priv active_listeners : Map[Int, () -> Unit]
  priv mut next_active_listener : Int
}

///|
/// The station's workspaces, its home one first: what each connect's index and Router are of.
fn workspaces_of(deps : LiveDeps) -> String {
  let ws = (deps.memberships)().copy()
  ws.sort_by(units_cmp)
  stringify(Arr([(deps.home)().map(jstr).unwrap_or(Null)] + ws.map(jstr)))
}

///|
pub async fn CommaLive::new(deps : LiveDeps, io : Io, runtime : @effect.Runtime) -> CommaLive {
  CommaStats::make_dirs(io, deps.data)
  let usage = (changed : (Bool) -> Unit) => (deps.subscribe)(kind => if kind == "usage" {
    changed(false)
  } else if kind is ("session" | "thread" | "read") {
    changed(true)
  })
  let legacy = CommaStats::at(
    deps.data,
    async fn(_from, _to) { { stations: [], unread: [], valid: None } },
    usage,
    io,
    runtime,
  )
  let empty_db = (io.open_db)(":memory:", busy_ms)
  empty_db.exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
  let empty : CommaIndexes = {
    stats: RevIndex::new(empty_db, "stats_index", io),
    tasks: RevIndex::new(empty_db, "task_index", io),
    start: () => (),
  }
  // The general handover timeout can take sessions up before the older process really exits.
  let said = router_says_after(deps.hub, legacy, deps.previous_exited, io, runtime)
  let live = {
    deps,
    io,
    runtime,
    indexed: workspaces_of(deps),
    scope_version_: 0,
    stops: [],
    legacy,
    empty,
    empty_db,
    said,
    scopes: {},
    owner_active_at_: None,
    active_listeners: {},
    next_active_listener: 0,
  }
  // Any change of the station's workspaces moves `scope_version`, so that what was read or written before it is not
  // used after.
  live.stops.push(
    (deps.cloud_listen)(() => {
      let now = workspaces_of(deps)
      if now != live.indexed {
        live.indexed = now
        live.scope_version_ += 1
      }
    }),
  )
  let notify_peers : Ref[(() -> Unit)?] = Ref(None)
  let stop_store = (deps.subscribe)(kind => {
    if !(kind is ("session" | "thread" | "read")) || notify_peers.val is Some(_) {
      return
    }
    notify_peers.val = Some(
      (io.after)(fast_settle_ms, () => { // timer: burst debouncing
        notify_peers.val = None
        let seen : Set[String] = Set::new()
        let members = (deps.memberships)().copy()
        members.sort_by(units_cmp)
        let list = match (deps.home)() {
          Some(h) => [h] + members
          None => members
        }
        for ws in list {
          if ws == "" || seen.contains(ws) || !live.within(ws) {
            continue
          }
          seen.add(ws)
          let target = ws
          ignore(
            runtime.fork_daemon("comma peer notify", on_error=_ => (), async fn() {
              let peers = (live.reads_for(target).others)() catch { _ => return }
              for peer in peers {
                ignore((deps.ask)(peer, jobj([("method", jstr(changed_method)), ("workspace", jstr(target))]))) catch {
                  _ => ()
                }
              }
            }),
          )
        }
      }),
    )
  })
  let stop_active = (deps.subscribe)(kind => {
    if kind != "read" {
      return
    }
    match quantize_owner_active_at(Some((io.now)())) {
      Some(bucket) if live.owner_active_at_ != Some(bucket) => {
        live.owner_active_at_ = Some(bucket)
        let cbs = []
        for _, cb in live.active_listeners {
          cbs.push(cb)
        }
        for cb in cbs {
          cb()
        }
      }
      _ => ()
    }
  })
  live.stops.push(stop_active)
  live.stops.push(stop_store)
  live.stops.push(() => match notify_peers.val {
    Some(stop) => {
      stop()
      notify_peers.val = None
    }
    None => ()
  })
  live
}

///|
pub fn CommaLive::scope_version(self : CommaLive) -> Int {
  self.scope_version_
}

///|
/// Whether the station is in `workspace` now.
pub fn CommaLive::within(self : CommaLive, workspace : String) -> Bool {
  !((self.deps.membership)(workspace) is Null)
}

///|
/// A chat's link in the app is made by the reader, of where this station's pages are.
fn CommaLive::linked(self : CommaLive, op : String, args : J) -> J {
  if op == "outflowChats" {
    with_fields(args, [("pages", (self.deps.pages)())])
  } else {
    args
  }
}

///|
/// What answers another station of the workspace reading this one's statistics, for the Comma connect there.
pub fn CommaLive::peer_read(self : CommaLive) -> async (String, J, String?) -> PeerAnswer {
  peer_read(
    async fn(op, args, lang) { (self.deps.read)(op, self.linked(op, args), lang, false) },
    self.deps.home,
    self.io.lang,
    () => self.scope_version_,
    self.deps.member,
  )
}

///|
/// What a build reads of `workspace`'s stations.
pub fn CommaLive::reads_for(self : CommaLive, workspace : String) -> WorkspaceReads {
  {
    of: () => Some((workspace, Some(workspace) == (self.deps.home)())),
    here: async fn(op, args) {
      let lang = (self.io.lang)()
      (self.deps.read)(op, self.linked(op, with_fields(args, [("lang", jstr(lang))])), lang, true)
    },
    others: async fn() {
      let roster = (self.deps.ask)("", jobj([("method", jstr("peers")), ("workspace", jstr(workspace))]))
      if !(prop(Some(roster), "current") is Some(Bool(true))) {
        raise fail_("the roster is not current")
      }
      let here = (self.deps.station)()
      arr_of(prop(Some(roster), "stations"))
      .unwrap_or([])
      .filter_map(e => match prop(Some(e), "id") {
        Some(Str(u)) if u.length() > 0 && u != here => Some(u)
        _ => None
      })
    },
    there: async fn(station, op, args) {
      (self.deps.ask_text)(
        station,
        jobj([
          ("method", jstr(read_method)),
          ("workspace", jstr(workspace)),
          ("op", jstr(op)),
          ("args", args),
          ("whole", Bool(true)),
        ]),
      )
    },
  }
}

///|
/// Another station of the workspace writing in one of this one's chats, for the Router of the Comma connect there.
pub async fn CommaLive::say_handler(self : CommaLive, _peer : String, request : J, workspace : String?) -> J {
  guard workspace is Some(ws) && self.within(ws) else { raise fail_("not this workspace") }
  let w = prop(Some(request), "say")
  let thread = match prop(w, "thread") {
    Some(Num(n)) => n
    _ => raise fail_("no such write")
  }
  let text = match prop(w, "text") {
    Some(Str(u)) if js_trim(u) != "" => u
    _ => raise fail_("no such write")
  }
  let field = (key : String, default : String) => js_text(or_null(nullish(prop(w, key), Some(jstr(default)))))
  let seq = (self.said)(Some(ws), {
    thread,
    text,
    key: field("key", ""),
    requester: field("requester", "Router"),
    connect: field("connect", "comma"),
  })
  jobj([("seq", Num(seq))])
}

///|
/// Another station telling that one of its chats moved, so any Comma connect here rebuilds its Task index within a second.
pub fn CommaLive::changed_handler(self : CommaLive, peer : String, workspace : String?) -> J raise {
  guard workspace is Some(ws) && self.within(ws) else { raise fail_("not this workspace") }
  (self.deps.member)(peer, ws)
  match self.scopes.get(ws) {
    Some((stats, _, _)) => stats.nudge()
    None => ()
  }
  jobj([("ok", Bool(true))])
}

///|
/// The index and Router of a workspace the station is in.
pub fn CommaLive::scope(self : CommaLive, workspace : String) -> (CommaIndexes, CommaChats) raise {
  match self.scopes.get(workspace) {
    Some((_, indexes, chats)) => return (indexes, chats)
    None => ()
  }
  let reads = self.reads_for(workspace)
  let (stats, indexes) = workspace_index(
    self.deps.data,
    workspace,
    () => self.within(workspace),
    () => self.scope_version_,
    workspace_read(reads),
    changed => (self.deps.subscribe)(kind => if kind == "usage" {
      changed(false)
    } else if kind is ("session" | "thread" | "read") {
      changed(true)
    }),
    self.io,
    self.runtime,
  )
  let chats : CommaChats = {
    read: async fn(ref_, after, limit) { router_reads(stats, reads, ref_, after, limit) },
    say: async fn(ref_, text, key, requester, connect) {
      if !self.within(workspace) {
        raise fail_("the workspace changed while writing")
      }
      let (thread, station) = match chat_of(ref_) {
        Some(c) => c
        None => raise fail_("no such chat")
      }
      let w : RouterSay = {
        thread,
        text,
        key: if key == "" { "" } else { "\{connect}:\{key}" },
        requester,
        connect,
      }
      match station {
        None => jobj([("seq", Num((self.said)(Some(workspace), w)))])
        Some(s) => {
          let got = (self.deps.ask)(
            s,
            jobj([
              ("method", jstr(say_method)),
              ("workspace", jstr(workspace)),
              (
                "say",
                jobj([
                  ("thread", Num(w.thread)),
                  ("text", jstr(w.text)),
                  ("key", jstr(w.key)),
                  ("requester", jstr(w.requester)),
                  ("connect", jstr(w.connect)),
                ]),
              ),
            ]),
          )
          jo([("seq", prop(Some(got), "seq"))])
        }
      }
    },
  }
  self.scopes[workspace] = (stats, indexes, chats)
  (indexes, chats)
}

///|
/// Tells `changed` whenever the station's workspaces moved; what it answers stops it.
pub fn CommaLive::on_scope_change(self : CommaLive, changed : () -> Unit) -> () -> Unit {
  let seen = Ref(self.scope_version_)
  (self.deps.cloud_listen)(() => if seen.val != self.scope_version_ {
    seen.val = self.scope_version_
    changed()
  })
}

///|
/// What the station calls itself to Comma for a connect of workspace `ws` (None: the home one): that workspace's name
/// and its own there, so the still.fail stations Comma lists say which workspace each is.
pub fn CommaLive::name(self : CommaLive, ws : String?) -> String {
  let m = (self.deps.membership)(
    match ws {
      Some(w) => w
      None => (self.deps.home)().unwrap_or("")
    },
  )
  if m is Null {
    return self.io.hostname
  }
  let own = match prop(Some(m), "name") {
    Some(Str("")) => self.io.hostname
    Some(v) => js_text(v)
    None => "undefined"
  }
  "\{js_text(or_null(prop(Some(m), "workspace_name")))} · \{own}"
}

///|
/// Metadata of workspace `ws` (None: the home one) reported in capabilities.stillfail_workspace.
pub fn CommaLive::workspace_meta(self : CommaLive, ws : String?) -> J? {
  let target = match ws {
    Some(w) => Some(w)
    None => (self.deps.home)()
  }
  guard target is Some(t) else { return None }
  let m = (self.deps.membership)(t)
  if m is Null {
    None
  } else {
    Some(workspace_meta_of(m, (self.deps.station)(), self.io.hostname))
  }
}

///|
/// Comma's connects made with this part's scopes (index.mbt `make_comma`).
pub fn CommaLive::make_comma(
  self : CommaLive,
  data : String,
  config_raw : () -> J,
  config_listen : ((J) -> Unit) -> () -> Unit,
  in_workspace : ((String?) -> Bool)?,
  store : SurfaceStore,
  models : (String) -> Array[J],
  reconcile : async () -> Unit,
  close_connects : async () -> Unit,
) -> CommaParts {
  make_comma(
    {
      data,
      config_raw,
      config_listen,
      in_workspace,
      store,
      models,
      scope: ws => self.scope(ws),
      empty: self.empty,
      home: self.deps.home,
      within: ws => self.within(ws),
      scope_version: () => self.scope_version_,
      on_scope_change: f => self.on_scope_change(f),
      previous_exited: self.deps.previous_exited,
      name: Some(ws => self.name(ws)),
      workspace_meta: Some(ws => self.workspace_meta(ws)),
      on_workspace_meta_change: Some(changed => (self.deps.cloud_listen)(changed)),
      owner_active_at: Some((_, _) => self.owner_active_at_),
      on_owner_active_change: Some(changed => {
        let id = self.next_active_listener
        self.next_active_listener += 1
        self.active_listeners[id] = changed
        () => self.active_listeners.remove(id)
      }),
      reconcile,
      close_connects,
    },
    self.io,
    self.runtime,
  )
}

///|
/// The part let go: its listening, its scopes' indexes, the empty index and the legacy one.
pub fn CommaLive::close(self : CommaLive) -> Unit {
  for stop in self.stops {
    stop()
  }
  for _, scope in self.scopes {
    scope.0.close()
  }
  self.empty_db.close()
  self.legacy.close()
}
