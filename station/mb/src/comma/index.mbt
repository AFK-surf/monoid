// Comma on the station (station/src/comma/index.ts): its connects as every platform's are kept (connected as
// config.json and the station's workspace say), and the Comma Tasks their agents work in (<data>/comma-tasks.json). A
// Comma connect is made of the line Comma's still.fail plugin shows: `comma <server> <token>`. What every platform's
// connects share (their reconciling with config.json, their sockets) is the connects' (connects/connects.ts).

///|
/// A Comma connect as config.json has it, as far as its connection goes.
pub(all) struct CommaConnect {
  id : String
  enabled : Bool
  server : String
  token : String
  workspace : String?
}

///|
pub fn CommaConnect::to_j(self : CommaConnect) -> J {
  jobj([
    ("id", jstr(self.id)),
    ("enabled", Bool(self.enabled)),
    ("server", jstr(self.server)),
    ("token", jstr(self.token)),
    ("workspace", self.workspace.map(jstr).unwrap_or(Null)),
  ])
}

///|
/// One with the workspace it is of now (its own, else the home one) and the version of the station's workspaces then.
pub(all) struct ScopedConnect {
  connect : CommaConnect
  scope : String?
  scope_version : Int
}

///|
pub fn ScopedConnect::to_j(self : ScopedConnect) -> J {
  match self.connect.to_j() {
    Obj(entries) => {
      let out = entries.copy()
      out.push(("scope", self.scope.map(jstr).unwrap_or(Null)))
      out.push(("scopeVersion", ji(self.scope_version)))
      Obj(out)
    }
    v => v
  }
}

///|
fn non_empty(v : J?) -> String? {
  match v {
    Some(Str(u)) if u.length() > 0 => Some(u)
    _ => None
  }
}

///|
/// config.json's Comma connects.
pub fn comma_connects(raw : J) -> Array[CommaConnect] {
  let all = match prop(Some(raw), "connects") {
    Some(Arr(items)) => items
    _ => []
  }
  all
  .filter(c => str_of(prop(Some(c), "kind")) == Some("comma"))
  .map(c => {
    let cc = Some(c)
    {
      id: js_text(or_null(nullish(prop(cc, "id"), Some(jstr(""))))),
      enabled: !(prop(cc, "enabled") is Some(Bool(false))),
      server: non_empty(prop(prop(cc, "comma"), "server")).unwrap_or(""),
      token: non_empty(prop(prop(cc, "comma"), "token")).unwrap_or(""),
      workspace: non_empty(prop(cc, "workspace")),
    }
  })
}

///|
/// What makes Comma's connects on the station.
pub(all) struct CommaOptions {
  data : String
  /// config.json as it is now (read again where another process may have edited it), and its changes told.
  config_raw : () -> J
  config_listen : ((J) -> Unit) -> () -> Unit
  /// Whether a connect of `workspace` is the station's to serve now (`ConnectsOptions.inWorkspace`).
  in_workspace : ((String?) -> Bool)?
  store : SurfaceStore
  /// The models a connect's sessions can run.
  models : (String) -> Array[J]
  /// The index and Router of a workspace the station is in, its home one or one it joined. Called only after the
  /// previous station has exited.
  scope : (String) -> (CommaIndexes, CommaChats) raise
  /// What a connect of a workspace the station is not in sends: an empty reset, clearing rows older stations may have
  /// sent to it.
  empty : CommaIndexes
  home : () -> String?
  /// Whether the station is in `workspace` now.
  within : (String) -> Bool
  /// Moves whenever the station's workspaces change (its home one, those it is in).
  scope_version : () -> Int
  on_scope_change : (() -> Unit) -> () -> Unit
  previous_exited : async () -> Unit
  /// What the station calls itself to Comma for a connect of a workspace (None: the home one).
  name : ((String?) -> String)?
  /// The connects brought in line with config.json and the workspaces again, and let go.
  reconcile : async () -> Unit
  close_connects : async () -> Unit
}

///|
/// Comma's part of the station's connects.
pub struct CommaParts {
  tasks : CommaTasks
  priv options : CommaOptions
  priv io : Io
  priv runtime : @effect.Runtime
  priv mut closing : Bool
  priv mut configured : Map[String, CommaConnect]
  priv mut previous_ready : Bool
  priv stops : Array[() -> Unit]
}

///|
fn configured_of(raw : J) -> Map[String, CommaConnect] {
  let m : Map[String, CommaConnect] = {}
  for c in comma_connects(raw) {
    m[c.id] = c
  }
  m
}

///|
pub fn make_comma(options : CommaOptions, io : Io, runtime : @effect.Runtime) -> CommaParts {
  let tasks = CommaTasks::new(io.join([options.data, "comma-tasks.json"]), io, runtime)
  let parts = {
    tasks,
    options,
    io,
    runtime,
    closing: false,
    configured: configured_of((options.config_raw)()),
    previous_ready: false,
    stops: [],
  }
  // Update the guard before the connect manager begins its asynchronous reconciliation.
  parts.stops.push((options.config_listen)(raw => parts.configured = configured_of(raw)))
  ignore(
    runtime.fork_daemon("comma previous exited", on_error=_ => (), async fn() {
      (options.previous_exited)() catch {
        _ => return
      }
      parts.previous_ready = true
    }),
  )
  // Reconcile with a new snapshot even when the connection's configured token did not change.
  parts.stops.push(
    (options.on_scope_change)(() => ignore(
      runtime.fork_daemon("comma reconcile", on_error=e => io.warn("connects not brought in line with the workspace", [("error", Some(jstr(message_of(e))))]), async fn() {
        (options.reconcile)() catch {
          e =>
            io.warn("connects not brought in line with the workspace", [("error", Some(jstr(message_of(e))))])
        }
      }),
    )),
  )
  parts
}

///|
/// config.json's Comma connects as the connects keep them: each with the workspace it is of now.
pub fn CommaParts::connects(self : CommaParts, raw : J) -> Array[ScopedConnect] {
  comma_connects(raw).map(c => {
    connect: c,
    scope: match c.workspace {
      Some(w) => Some(w)
      None => (self.options.home)()
    },
    scope_version: (self.options.scope_version)(),
  })
}

///|
/// What makes a connect's connection another: a workspace edit changes what it is allowed to see, even if its token is
/// unchanged. None: it cannot connect.
pub fn credentials(c : ScopedConnect) -> String? {
  if c.connect.server == "" || c.connect.token == "" {
    return None
  }
  Some(
    stringify(
      Arr([
        jstr(c.connect.server),
        jstr(c.connect.token),
        c.connect.workspace.map(jstr).unwrap_or(Null),
        c.scope.map(jstr).unwrap_or(Null),
        ji(c.scope_version),
      ]),
    ),
  )
}

///|
/// A connect's surface: a connect of a workspace the station is not in sends the empty reset, and stops as the station
/// joins it.
pub fn CommaParts::create(self : CommaParts, c : ScopedConnect) -> CommaSurface {
  let options = self.options
  let workspace = c.scope
  let version = c.scope_version
  let within = () => match workspace {
    Some(w) => (options.within)(w)
    None => false
  }
  let is_in = within()
  let in_scope = () => {
    if self.closing {
      return false
    }
    // Also notice a config edited by another process before sending a page or answering a Router request.
    ignore((options.config_raw)())
    match self.configured.get(c.connect.id) {
      Some(now) =>
        now.enabled &&
        now.server == c.connect.server &&
        now.token == c.connect.token &&
        now.workspace == c.connect.workspace &&
        (match options.in_workspace {
          Some(f) => f(c.connect.workspace)
          None => true
        }) &&
        within() == is_in &&
        (options.scope_version)() == version
      None => false
    }
  }
  let scoped = fn() raise {
    match workspace {
      Some(w) if self.previous_ready && is_in && in_scope() => (options.scope)(w)
      _ => raise fail_("the workspace is handing over; retry")
    }
  }
  let chats : CommaChats? = if is_in {
    Some({
      read: async fn(ref_, after, limit) { (scoped().1.read)(ref_, after, limit) },
      say: async fn(ref_, text, key, requester, connect) { (scoped().1.say)(ref_, text, key, requester, connect) },
    })
  } else {
    None
  }
  let empty = options.empty
  CommaSurface::new(
    {
      connect: c.connect.id,
      server: c.connect.server,
      token: c.connect.token,
      name: match options.name {
        Some(f) => f(c.connect.workspace)
        None => self.io.hostname
      },
      workspace,
      tasks: self.tasks,
      store: options.store,
      models: () => (options.models)(c.connect.id),
      lang: None,
      stats: Some(if is_in { fn() raise { scoped().0 } } else { fn() raise { empty } }),
      chats,
      previous_exited: options.previous_exited,
      in_scope,
    },
    self.io,
    self.runtime,
  )
}

///|
pub async fn CommaParts::close(self : CommaParts) -> Unit {
  self.closing = true
  for stop in self.stops.rev() {
    stop()
  }
  (self.options.close_connects)()
  self.tasks.written()
}

///|
/// What the overview says of a Comma connect besides what all connects say.
pub fn shown(raw : J) -> J {
  let c = nullish(prop(Some(raw), "comma"), Some(Obj([])))
  jobj([
    ("name", jstr("Comma")),
    ("team", Null),
    ("botImage", Null),
    (
      "comma",
      jobj([
        ("server", jstr(non_empty(prop(c, "server")).unwrap_or(""))),
        ("token", jstr(mask_token(non_empty(prop(c, "token")).unwrap_or("")))),
      ]),
    ),
  ])
}
