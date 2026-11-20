// The connects of one chat platform on the station (connects/connects.ts `makeConnects`; Slack's, Feishu's, the group
// connect's): their connections as config.json and the station's workspace say, connected while the station is in the
// connect's workspace and following config edits, disconnected out of it; what the platform calls people and chats (a
// names book in the data directory); and what each connected connect is known by (its bot's name and picture, its
// workspace), kept in config.json so that it shows by them while it is not connected too. Each connected connect's
// surface is the hub's (`chats`), and what the platform says reaches the hub through `receive`.

///|
/// config.json as these parts read and edit it (ops/config.ts `ConfigFile`).
pub(all) struct Config {
  /// What it holds now.
  raw : () -> J
  /// Edited by `f` (given what it holds, giving what it is to hold), written soon after: resolves once written.
  update_soon : async ((J) -> J) -> Unit
  /// Hears each change of it; gives the function that stops it.
  listen : (() -> Unit) -> () -> Unit
  /// Once what was asked of it is written.
  written : async () -> Unit
}

///|
/// The store, as far as a platform's connects use it.
pub(all) struct ConnectsStore {
  /// `liveSessions()`' keys.
  live_sessions : () -> Array[String]
  notify : (String) -> Unit
}

///|
pub(all) struct ConnectsOptions {
  data : String
  store : ConnectsStore
  config : Config
  /// Takes what a connect's platform says (the hub's `receive`); resolves once it is kept, and only then is the
  /// platform told it arrived.
  receive : async (String, J) -> Unit
  /// Whether the station is in its workspace: only then are connects connected.
  bound : () -> Bool
  /// Whether the station is in a connect's workspace (None: its home one) now. Absent: every one.
  in_workspace : ((String?) -> Bool)?
  fs : Fs
  clock : Clock
  log : Log
}

///|
/// A platform, as its connects are kept (`Platform`).
pub(all) struct Platform {
  /// config.json's `kind` of its connects, what the log calls it.
  kind : String
  /// Its names book, in the data directory.
  names : String
  /// Its connects in config.json.
  connects : (J) -> Array[J]
  credentials : (J) -> String?
  /// A connect's connection.
  create : async (J, NameBook) -> Connection
  /// What a connected connect is known by now, written into its config.json entry: None when that is what it has.
  seen : (J, J) -> ((J) -> J)?
}

///|
pub struct Connects {
  connections : Connections
  names : NameBook
  priv platform : Platform
  priv options : ConnectsOptions
  priv mut closed : Bool
  priv mut remembering : Bool
  /// The identities' last edit of config.json, waited for as it closes (nothing written into a directory gone).
  priv mut remembered : @effect.Deferred[Unit]?
  priv listeners : Listeners
  priv unlisten : () -> Unit
}

///|
pub async fn make_connects(options : ConnectsOptions, platform : Platform) -> Connects {
  let fs = options.fs
  // What the platform calls people and chats, kept on disk; learning new ones refreshes what shows them. Saved before
  // the pages are told: the readers read the names from the file.
  let names = NameBook::open(fs.join([options.data, platform.names]), fs, options.clock, options.log, options={ save_after_ms: 200.0, learn_after_ms: 400.0 })
  // (The sessions shown: an archived one's summary is read again as it is shown, names and all.)
  names.on_learn(() => for key in (options.store.live_sessions)() { (options.store.notify)(key) })
  let made : Ref[Connects?] = Ref(None)
  let connections = Connections::new(platform.kind, async fn(c) { (platform.create)(c, names) }, options.receive, platform.credentials, options.log)
  let unlisten = (options.config.listen)(() => match made.val {
    // Edits apply as they are saved.
    Some(c) => spawn(async fn() { c.reconcile() catch { e => options.log.warn(platform.kind, "connects not brought in line with the config", jo([("error", js(thrown_message(e)))])) } })
    None => ()
  })
  let c : Connects = {
    connections,
    names,
    platform,
    options,
    closed: false,
    remembering: false,
    remembered: None,
    listeners: Listeners::new(),
    unlisten,
  }
  made.val = Some(c)
  ignore(connections.on_change(() => {
    c.tell()
    if c.remembering || c.closed {
      return
    }
    c.remembering = true
    spawn(async fn() {
      @effect.pause()
      c.remembering = false
      if !c.closed {
        let d : @effect.Deferred[Unit] = @effect.Deferred::new()
        c.remembered = Some(d)
        c.remember_identities()
        ignore(d.succeed(()))
      }
    })
  }))
  c
}

///|
/// config.json's connects, as their connections read them.
pub fn Connects::connects(self : Connects) -> Array[J] {
  (self.platform.connects)((self.options.config.raw)())
}

///|
fn Connects::connect(self : Connects, id : String) -> J? {
  self.connects().iter().find_first(c => id_of(c) == id)
}

///|
/// A connected connect's surface, for the hub (HubOptions.chats).
pub fn Connects::chats(self : Connects, id : String) -> Surface? {
  self.connections.chat(id).map(c => c.surface)
}

///|
/// A connected connect's connection.
pub fn Connects::chat(self : Connects, id : String) -> Connection? {
  self.connections.chat(id)
}

///|
/// In line with config.json and the workspace now: connected while in it, disconnected out of it.
pub async fn Connects::reconcile(self : Connects) -> Unit {
  if self.closed {
    return
  }
  if (self.options.bound)() {
    let ws_of = (c : J) => match at(Some(c), "workspace") {
      Some(Str(u)) => Some(@jsjson.sanitize_str(u))
      _ => None
    }
    let wanted = self.connects().filter(c => match self.options.in_workspace { Some(f) => f(ws_of(c)); None => true })
    self.connections.reconcile(wanted)
  } else {
    self.connections.stop_all()
  }
}

///|
async fn Connects::remember_identities(self : Connects) -> Unit {
  let seen : Map[String, (J) -> J] = Map([])
  for c in self.connects() {
    let id = id_of(c)
    guard self.connections.chat(id) is Some(chat) else { continue }
    let identity = (chat.identity)()
    if identity is Null || str_of(at(Some(identity), "botUserId")).unwrap_or("") == "" {
      continue
    }
    match (self.platform.seen)(c, identity) {
      Some(write) => seen[id] = write
      None => ()
    }
  }
  if seen.length() == 0 {
    return
  }
  (self.options.config.update_soon)(raw => {
    match at(Some(raw), "connects") {
      Some(Arr(entries)) => {
        let out = entries.map(entry => {
          let kind = match at(Some(entry), "kind") {
            Some(Null) | None => "slack"
            Some(k) => js_text(Some(k))
          }
          if kind == self.platform.kind {
            match seen.get(js_text(at(Some(entry), "id"))) {
              Some(write) => write(entry)
              None => entry
            }
          } else {
            entry
          }
        })
        set_field(raw, "connects", Arr(out))
      }
      _ => raw
    }
  }) catch {
    e => self.options.log.warn(self.platform.kind, "connects' identities not kept", jo([("error", js(thrown_message(e)))]))
  }
}

///|
pub async fn Connects::stop_all(self : Connects) -> Unit {
  self.connections.stop_all()
}

///|
pub async fn Connects::refresh_identity(self : Connects, id : String) -> Unit {
  self.connections.refresh_identity(id)
}

///|
/// A connect's link to its platform as the pages show it (the overview's `connection`), by its id or its entry.
pub fn Connects::state(self : Connects, c : J) -> J? {
  let found = match c {
    Str(u) => self.connect(@jsjson.sanitize_str(u))
    other => Some(other)
  }
  found.map(f => self.connections.state(f))
}

///|
/// Hears whenever what `state` reports may have changed (the overview's events).
pub fn Connects::on_change(self : Connects, listener : () -> Unit) -> () -> Unit {
  self.listeners.add(listener)
}

///|
/// Tells those that hear of the connects that what `state` reports may have changed.
pub fn Connects::tell(self : Connects) -> Unit {
  self.listeners.tell()
}

///|
/// Stops listening, disconnects every connect, and keeps the names learned.
pub async fn Connects::close(self : Connects) -> Unit {
  self.closed = true
  (self.unlisten)()
  self.listeners.clear()
  self.connections.stop_all()
  match self.remembered {
    Some(d) => d.wait() catch { _ => () }
    None => ()
  }
  // (and what else of config.json is on its way: nothing written into a directory gone)
  (self.options.config.written)()
  self.names.close()
}
