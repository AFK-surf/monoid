// A connect's live link to its chat platform (connects/connections.ts: config.json's `connects`), and one kept per
// enabled connect that has what it connects with, following the config: a new or re-credentialed connect is
// (re)connected, a removed or disabled one disconnected, the rest left alone. Rapid edits apply in order.

///|
/// The connects of one platform (`kind`: what the log calls them), each by what it connects with. A connect is its
/// config entry as its platform reads it (`{id, enabled, ...}`).
pub struct Connections {
  priv kind : String
  /// Live connections by connect id; the hub reads it on every use.
  priv chats : Map[String, Connection]
  priv unlisten : Map[String, () -> Unit]
  priv tokens : Map[String, String]
  priv errors : Map[String, String]
  priv create : async (J) -> Connection
  /// What a connect connects with, as one string (None: it has nothing to connect with yet): a change connects it again.
  priv credentials : (J) -> String?
  priv on_event : async (String, J) -> Unit
  /// Rapid edits apply in order.
  priv chain : Turns
  priv listeners : Listeners
  priv log : Log
}

///|
pub fn Connections::new(
  kind : String,
  create : async (J) -> Connection,
  on_event : async (String, J) -> Unit,
  credentials : (J) -> String?,
  log : Log,
) -> Connections {
  {
    kind,
    chats: {},
    unlisten: {},
    tokens: {},
    errors: {},
    create,
    credentials,
    on_event,
    chain: Turns::new(),
    listeners: Listeners::new(),
    log,
  }
}

///|
fn id_of(connect : J) -> String {
  js_text(at(Some(connect), "id"))
}

///|
fn enabled_of(connect : J) -> Bool {
  match at(Some(connect), "enabled") {
    Some(Bool(b)) => b
    Some(Null) | None => false
    Some(Num(n)) => n != 0.0 && !n.is_nan()
    Some(Str(u)) => u.length() > 0
    Some(_) => true
  }
}

///|
pub fn Connections::chat(self : Connections, id : String) -> Connection? {
  self.chats.get(id)
}

///|
pub fn Connections::ids(self : Connections) -> Array[String] {
  self.chats.keys().to_array()
}

///|
/// Hears whenever what `state` reports may have changed; gives the function that stops it.
pub fn Connections::on_change(self : Connections, listener : () -> Unit) -> () -> Unit {
  self.listeners.add(listener)
}

///|
fn Connections::changed(self : Connections) -> Unit {
  self.listeners.tell()
}

///|
/// Reads again who a connect's bot is (its name, its workspace), as its platform says now.
pub async fn Connections::refresh_identity(self : Connections, id : String) -> Unit {
  match self.chat(id) {
    Some(c) => (c.refresh_identity)()
    None => ()
  }
}

///|
/// A connect's link to its platform, as the pages show it (`ConnectState`).
pub fn Connections::state(self : Connections, connect : J) -> J {
  if !enabled_of(connect) {
    return jo([("state", js("disabled"))])
  }
  if (self.credentials)(connect) is None {
    return jo([("state", js("no_tokens"))])
  }
  let id = id_of(connect)
  match self.errors.get(id) {
    Some(error) => return jo([("state", js("error")), ("error", js(error))])
    None => ()
  }
  guard self.chat(id) is Some(chat) else { return jo([("state", js("starting"))]) }
  let bot_user_id = chat.surface.bot_user_id()
  let socket = (chat.socket)()
  let last_error = at(Some(socket), "lastError").unwrap_or(Null)
  // Not known yet who its bot is: the platform not reached (asked again meanwhile), or it refused once reached.
  if bot_user_id == "" {
    return match last_error {
      Null => jo([("state", js("starting"))])
      e => jo([("state", js("error")), ("error", e)])
    }
  }
  let identity = (chat.identity)()
  let connected = at(Some(socket), "connected") is Some(Bool(true))
  jo([
    ("state", js(if connected { "connected" } else { "reconnecting" })),
    ("botUserId", js(bot_user_id)),
    ("lastError", last_error),
    ("workspace", if identity is Null { Null } else { shown_identity(identity) }),
  ])
}

///|
/// Brings connections in line with `connects`. Serialized, so rapid edits apply in order.
pub async fn Connections::reconcile(self : Connections, connects : Array[J]) -> Unit {
  self.chain.run(async fn() {
    self.apply(connects)
    self.changed()
  })
}

///|
pub async fn Connections::stop_all(self : Connections) -> Unit {
  self.chain.run(async fn() {
    let chats = self.chats.to_array()
    self.chats.clear()
    self.tokens.clear()
    for c in chats {
      self.drop(c.0)
    }
    for c in chats {
      (c.1.stop)()
    }
    if chats.length() > 0 {
      self.changed()
    }
  })
}

///|
fn Connections::drop(self : Connections, id : String) -> Unit {
  match self.unlisten.get(id) {
    Some(f) => f()
    None => ()
  }
  self.unlisten.remove(id)
}

///|
async fn Connections::apply(self : Connections, connects : Array[J]) -> Unit {
  let wanted : Map[String, J] = Map([])
  for c in connects {
    if enabled_of(c) && (self.credentials)(c) is Some(_) {
      wanted[id_of(c)] = c
    }
  }
  for entry in self.chats.to_array() {
    let (id, chat) = entry
    match wanted.get(id) {
      Some(want) if self.tokens.get(id) == (self.credentials)(want) => continue
      _ => ()
    }
    self.log.info(self.kind, "disconnecting", jo([("connect", js(id))]))
    self.chats.remove(id)
    self.tokens.remove(id)
    self.drop(id)
    (chat.stop)()
  }
  for id in self.errors.keys().to_array() {
    if !wanted.contains(id) {
      self.errors.remove(id)
    }
  }
  for entry in wanted.to_array() {
    let (id, connect) = entry
    if self.chats.contains(id) {
      continue
    }
    self.errors.remove(id)
    let made : Ref[Connection?] = Ref(None)
    try {
      let chat = (self.create)(connect)
      made.val = Some(chat)
      // Its link's changes are the connects' changes.
      self.unlisten[id] = (chat.on_change)(() => self.changed())
      (chat.start)(async fn(event) { (self.on_event)(id, event) })
      self.log.info(self.kind, "connected", jo([("connect", js(id)), ("botUserId", js(chat.surface.bot_user_id()))]))
      self.chats[id] = chat
      self.tokens[id] = (self.credentials)(connect).unwrap_or("")
    } catch {
      e => {
        let error = thrown_message(e)
        self.log.error(self.kind, "failed to connect", jo([("connect", js(id)), ("error", js(error))]))
        self.drop(id)
        // Started this far: what it opened is closed again.
        match made.val {
          Some(chat) => (chat.stop)() catch { _ => () }
          None => ()
        }
        self.errors[id] = error
      }
    }
  }
}
